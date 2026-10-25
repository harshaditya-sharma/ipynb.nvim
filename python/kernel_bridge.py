#!/usr/bin/env python3
"""
Jupyter kernel bridge for ipynb.nvim

Talks to Neovim with one JSON object per line on stdin/stdout and to a Jupyter
kernel through jupyter_client.

Everything that touches the kernel's ZeroMQ sockets runs on a single asyncio
event loop (sockets are not thread-safe). A plain thread only reads stdin and
hands lines to the loop, so a long-running cell, a slow completion or a pending
inspect never blocks an interrupt.
"""

import asyncio
import inspect
import json
import sys
import threading
import uuid
from datetime import datetime
from typing import Any, Dict, Optional

from inspect_parsers import get_parser

try:
    from jupyter_client import AsyncKernelManager
except ImportError:
    print(json.dumps({
        "type": "error",
        "error": "jupyter_client not installed. Install with: pip install jupyter_client ipykernel",
    }), flush=True)
    sys.exit(1)

REQUEST_TIMEOUT = 10.0
READY_TIMEOUT = 60.0


def _iso(value: Any) -> Optional[str]:
    """Header dates arrive as datetime objects; send ISO strings."""
    if isinstance(value, datetime):
        return value.isoformat()
    return value if isinstance(value, str) else None


def _json_default(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


class KernelBridge:
    """One kernel connection plus routing of its messages to notebook cells."""

    def __init__(self, loop: asyncio.AbstractEventLoop):
        self.loop = loop
        self.km: Optional[AsyncKernelManager] = None
        self.kc = None
        self.owns_kernel = False
        self.kernel_name = "python3"
        self.language: Optional[str] = None
        self.executions: Dict[str, Dict[str, Any]] = {}  # execute msg_id -> {cell_id}
        self.replies: Dict[str, asyncio.Future] = {}  # shell msg_id -> reply future
        self.inputs: Dict[str, str] = {}  # input request_id -> execute msg_id
        self.tasks: list = []

    # -- output -----------------------------------------------------------------

    def send(self, msg: Dict[str, Any]) -> None:
        line = json.dumps(msg, default=_json_default)
        sys.stdout.write(line + "\n")
        sys.stdout.flush()

    def error(self, text: str, **extra: Any) -> None:
        self.send({"type": "error", "error": text, **extra})

    # -- lifecycle --------------------------------------------------------------

    async def _attach(self) -> None:
        self.kc = self.km.client()
        self.kc.start_channels()
        await self.kc.wait_for_ready(timeout=READY_TIMEOUT)
        try:
            self.language = self.km.kernel_spec.language
        except Exception:
            self.language = None
        self.tasks = [
            asyncio.ensure_future(self._pump(self.kc.get_iopub_msg, self._on_iopub)),
            asyncio.ensure_future(self._pump(self.kc.get_shell_msg, self._on_shell)),
            asyncio.ensure_future(self._pump(self.kc.get_stdin_msg, self._on_stdin)),
        ]

    async def start(self, kernel_name: str) -> None:
        if self.kc:
            self.error("Kernel already running")
            return
        try:
            self.kernel_name = kernel_name
            self.km = AsyncKernelManager(kernel_name=kernel_name)
            await self.km.start_kernel()
            self.owns_kernel = True
            await self._attach()
            self.send({
                "type": "kernel_started",
                "kernel_name": kernel_name,
                "kernel_id": getattr(self.km, "kernel_id", None) or "unknown",
                "language": self.language,
            })
        except Exception as e:
            self.error(f"Failed to start kernel: {e}")

    async def connect(self, connection_file: str) -> None:
        if self.kc:
            self.error("Kernel already running")
            return
        try:
            self.km = AsyncKernelManager(connection_file=connection_file)
            self.km.load_connection_file()
            self.owns_kernel = False
            await self._attach()
            self.send({
                "type": "kernel_connected",
                "connection_file": connection_file,
                "language": self.language,
            })
        except Exception as e:
            self.error(f"Failed to connect to kernel: {e}")

    async def interrupt(self) -> None:
        if not self.km:
            return
        try:
            if self.owns_kernel:
                await self.km.interrupt_kernel()
            else:
                # Not our process: ask the kernel itself over the control channel
                msg = self.kc.session.msg("interrupt_request", {})
                self.kc.control_channel.send(msg)
            self.inputs.clear()
            self.send({"type": "interrupted"})
        except Exception as e:
            self.error(f"Failed to interrupt: {e}")

    async def restart(self) -> None:
        if not self.km or not self.owns_kernel:
            self.error("Restart is only available for kernels started by ipynb.nvim")
            return
        try:
            self._drop_pending()
            await self.km.restart_kernel(now=False)
            await self._wait_ready()
            self.send({"type": "restarted"})
        except Exception as e:
            self.error(f"Failed to restart: {e}")

    async def shutdown(self) -> None:
        for task in self.tasks:
            task.cancel()
        self.tasks = []
        self._drop_pending()
        if self.kc:
            self.kc.stop_channels()
        if self.km and self.owns_kernel:
            try:
                await self.km.shutdown_kernel(now=True)
            except Exception:
                pass
        self.kc = None
        self.km = None
        self.send({"type": "shutdown"})

    async def _wait_ready(self) -> None:
        # The shell pump owns the shell socket now, so poll with kernel_info
        # requests instead of kc.wait_for_ready (which reads the socket itself).
        deadline = self.loop.time() + READY_TIMEOUT
        while self.loop.time() < deadline:
            future = self.loop.create_future()
            msg_id = self.kc.kernel_info()
            self.replies[msg_id] = future
            try:
                await asyncio.wait_for(future, 2)
                return
            except asyncio.TimeoutError:
                self.replies.pop(msg_id, None)
        raise TimeoutError("kernel did not become ready after restart")

    def _drop_pending(self) -> None:
        for future in self.replies.values():
            if not future.done():
                future.cancel()
        self.replies.clear()
        self.executions.clear()
        self.inputs.clear()

    # -- kernel channels --------------------------------------------------------

    async def _pump(self, getter, handler) -> None:
        while True:
            try:
                msg = await getter(timeout=1)
            except asyncio.CancelledError:
                raise
            except Exception:
                # queue.Empty on timeout, or a socket closing during restart
                await asyncio.sleep(0)
                continue
            try:
                handler(msg)
            except Exception as e:
                self.error(f"Failed to handle {msg.get('msg_type', '?')}: {e}")

    def _cell_for(self, msg: Dict[str, Any]) -> Optional[str]:
        parent_id = msg.get("parent_header", {}).get("msg_id", "")
        return self.executions.get(parent_id, {}).get("cell_id")

    def _on_iopub(self, msg: Dict[str, Any]) -> None:
        msg_type = msg.get("msg_type", "")
        content = msg.get("content", {})
        cell_id = self._cell_for(msg)
        date = _iso(msg.get("header", {}).get("date"))

        if msg_type == "status":
            self.send({"type": "status", "state": content.get("execution_state", ""),
                       "cell_id": cell_id, "date": date})
        elif msg_type == "execute_input":
            self.send({"type": "execute_input", "cell_id": cell_id,
                       "execution_count": content.get("execution_count"), "date": date})
        elif msg_type == "stream":
            self.send({"type": "output", "cell_id": cell_id, "output": {
                "output_type": "stream",
                "name": content.get("name", "stdout"),
                "text": content.get("text", ""),
            }})
        elif msg_type in ("execute_result", "display_data", "update_display_data"):
            output = {
                "output_type": "display_data" if msg_type == "update_display_data" else msg_type,
                "data": content.get("data", {}),
                "metadata": content.get("metadata", {}),
            }
            if msg_type == "execute_result":
                output["execution_count"] = content.get("execution_count")
            display_id = (content.get("transient") or {}).get("display_id")
            if msg_type == "update_display_data":
                # Updates may target any cell that showed this display id
                self.send({"type": "update_display", "display_id": display_id, "output": output})
                return
            if display_id:
                output["transient"] = {"display_id": display_id}
            self.send({"type": "output", "cell_id": cell_id, "output": output})
        elif msg_type == "error":
            self.send({"type": "output", "cell_id": cell_id, "output": {
                "output_type": "error",
                "ename": content.get("ename", "Error"),
                "evalue": content.get("evalue", ""),
                "traceback": content.get("traceback", []),
            }})
        elif msg_type == "clear_output":
            self.send({"type": "clear_output", "cell_id": cell_id, "wait": bool(content.get("wait"))})

    def _on_shell(self, msg: Dict[str, Any]) -> None:
        parent_id = msg.get("parent_header", {}).get("msg_id", "")
        future = self.replies.pop(parent_id, None)
        if future and not future.done():
            future.set_result(msg)
        if msg.get("msg_type") == "execute_reply":
            info = self.executions.pop(parent_id, None)
            for request_id in [r for r, m in self.inputs.items() if m == parent_id]:
                self.inputs.pop(request_id, None)
            if info:
                content = msg.get("content", {})
                self.send({
                    "type": "execute_reply",
                    "cell_id": info["cell_id"],
                    "status": content.get("status", "ok"),
                    "execution_count": content.get("execution_count"),
                    "date": _iso(msg.get("header", {}).get("date")),
                })

    def _on_stdin(self, msg: Dict[str, Any]) -> None:
        if msg.get("msg_type") != "input_request":
            return
        content = msg.get("content", {})
        parent_id = msg.get("parent_header", {}).get("msg_id", "")
        request_id = uuid.uuid4().hex
        self.inputs[request_id] = parent_id
        self.send({
            "type": "input_request",
            "request_id": request_id,
            "cell_id": self._cell_for(msg),
            "prompt": content.get("prompt", ""),
            "password": bool(content.get("password", False)),
        })

    async def _request(self, msg_id: str) -> Optional[Dict[str, Any]]:
        future = self.loop.create_future()
        self.replies[msg_id] = future
        try:
            return await asyncio.wait_for(future, REQUEST_TIMEOUT)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            self.replies.pop(msg_id, None)
            return None

    # -- requests from Neovim ---------------------------------------------------

    def execute(self, code: str, cell_id: str, stop_on_error: bool = True) -> None:
        if not self.kc:
            self.error("No kernel connected", cell_id=cell_id)
            return
        msg_id = self.kc.execute(code, stop_on_error=stop_on_error)
        self.executions[msg_id] = {"cell_id": cell_id}
        self.send({"type": "execute_request", "cell_id": cell_id, "msg_id": msg_id})

    def input_reply(self, request_id: str, value: str) -> None:
        if not self.kc:
            self.error("No kernel connected")
        elif request_id not in self.inputs:
            self.error(f"Unknown input request_id: {request_id}")
        else:
            self.inputs.pop(request_id, None)
            self.kc.input(value)

    async def complete(self, code: str, cursor_pos: int, request_id: Optional[str]) -> None:
        reply = await self._request(self.kc.complete(code, cursor_pos)) if self.kc else None
        content = (reply or {}).get("content", {})
        self.send({
            "type": "complete_reply",
            "request_id": request_id,
            "matches": content.get("matches", []),
            "cursor_start": content.get("cursor_start", cursor_pos),
            "cursor_end": content.get("cursor_end", cursor_pos),
            "metadata": content.get("metadata", {}),
        })

    async def inspect(self, code: str, cursor_pos: int, detail_level: int, request_id: Optional[str]) -> None:
        reply = await self._request(self.kc.inspect(code, cursor_pos, detail_level)) if self.kc else None
        content = (reply or {}).get("content", {})
        data = content.get("data", {})
        self.send({
            "type": "inspect_reply",
            "request_id": request_id,
            "found": bool(content.get("found", False)),
            "sections": get_parser(self.language, self.kernel_name)(data) if data else {},
            "data": data,
            "metadata": content.get("metadata", {}),
        })

    async def kernel_info(self) -> None:
        reply = await self._request(self.kc.kernel_info()) if self.kc else None
        self.send({"type": "kernel_info", "info": (reply or {}).get("content"), "connected": self.kc is not None})

    async def is_alive(self) -> None:
        alive = False
        if self.km and self.owns_kernel:
            alive = self.km.is_alive()
        elif self.kc:
            alive = self.kc.is_alive()
        if inspect.isawaitable(alive):
            alive = await alive
        self.send({"type": "is_alive", "alive": bool(alive)})

    async def handle(self, cmd: Dict[str, Any]) -> bool:
        """Run one command. Returns False when the bridge should exit."""
        action = cmd.get("action", "")
        if action == "start":
            await self.start(cmd.get("kernel_name") or "python3")
        elif action == "connect":
            if cmd.get("connection_file"):
                await self.connect(cmd["connection_file"])
            else:
                self.error("Missing connection_file parameter")
        elif action == "execute":
            cell_id = cmd.get("cell_id")
            if not isinstance(cell_id, str) or not cell_id:
                self.error("Missing required cell_id for execute action")
            else:
                self.execute(cmd.get("code", ""), cell_id, cmd.get("stop_on_error", True) is not False)
        elif action == "interrupt":
            await self.interrupt()
        elif action == "restart":
            await self.restart()
        elif action == "shutdown":
            await self.shutdown()
            return False
        elif action == "info":
            await self.kernel_info()
        elif action == "is_alive":
            await self.is_alive()
        elif action == "complete":
            code = cmd.get("code", "")
            asyncio.ensure_future(self.complete(code, cmd.get("cursor_pos", len(code)), cmd.get("request_id")))
        elif action == "inspect":
            code = cmd.get("code", "")
            asyncio.ensure_future(self.inspect(code, cmd.get("cursor_pos", len(code)),
                                               cmd.get("detail_level", 0), cmd.get("request_id")))
        elif action == "input_reply":
            request_id = cmd.get("request_id")
            if not isinstance(request_id, str) or not request_id:
                self.error("Missing required request_id for input_reply action")
            else:
                self.input_reply(request_id, str(cmd.get("value", "")))
        elif action == "ping":
            self.send({"type": "pong"})
        else:
            self.error(f"Unknown action: {action}")
        return True


def _read_stdin(loop: asyncio.AbstractEventLoop, lines: asyncio.Queue) -> None:
    for line in sys.stdin:
        loop.call_soon_threadsafe(lines.put_nowait, line)
    loop.call_soon_threadsafe(lines.put_nowait, None)


async def main() -> None:
    loop = asyncio.get_running_loop()
    bridge = KernelBridge(loop)
    lines: asyncio.Queue = asyncio.Queue()
    threading.Thread(target=_read_stdin, args=(loop, lines), daemon=True).start()
    bridge.send({"type": "ready"})

    running = True
    while running:
        line = await lines.get()
        if line is None:  # Neovim closed our stdin
            break
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            bridge.error(f"Invalid JSON: {e}")
            continue
        try:
            running = await bridge.handle(cmd)
        except Exception as e:
            bridge.error(f"{cmd.get('action', '?')} failed: {e}")

    if bridge.kc or bridge.km:
        await bridge.shutdown()


def run() -> None:
    # Keep the protocol stream UTF-8 regardless of the Windows console code page
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        sys.stdin.reconfigure(encoding="utf-8")
    if sys.platform == "win32":
        # pyzmq's asyncio integration needs a selector loop on Windows
        loop = asyncio.SelectorEventLoop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(main())
        finally:
            loop.close()
    else:
        asyncio.run(main())


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        pass

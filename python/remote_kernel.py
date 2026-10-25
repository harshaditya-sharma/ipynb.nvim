"""
Kernels on a Jupyter server (JupyterLab, JupyterHub, `jupyter server`, ...).

Talks to the server's REST API and the kernel websocket
(/api/kernels/<id>/channels, JSON messages with a "channel" field), using
tornado, which jupyter_client already depends on. Exposes the same small
client surface the bridge uses for local kernels (execute, complete, inspect,
kernel_info, input) and hands incoming messages to the bridge's handlers.
"""

import json
import os
from typing import Any, Callable, Dict, Optional
from urllib.parse import parse_qs, quote, urlencode, urlsplit, urlunsplit

from jupyter_client.jsonutil import json_default
from jupyter_client.session import Session
from tornado.httpclient import AsyncHTTPClient, HTTPClientError, HTTPRequest
from tornado.websocket import websocket_connect


def parse_server_url(url: str):
    """Split "http://host:8888/lab?token=abc" into (base_url, token)."""
    parts = urlsplit(url.strip())
    if parts.scheme not in ("http", "https"):
        raise ValueError("server URL must start with http:// or https://")
    # A token in the URL wins; otherwise JUPYTER_TOKEN (keeps it out of command history)
    token = (parse_qs(parts.query).get("token") or [""])[0] or os.environ.get("JUPYTER_TOKEN", "")
    path = parts.path
    # Strip frontend paths people copy from the browser
    for suffix in ("/lab", "/tree", "/notebooks"):
        idx = path.find(suffix)
        if idx != -1:
            path = path[:idx]
    base = urlunsplit((parts.scheme, parts.netloc, path.rstrip("/"), "", ""))
    return base, token


class RemoteKernel:
    """One kernel on a Jupyter server."""

    def __init__(self, base_url: str, token: str, on_message: Callable[[str, Dict[str, Any]], None]):
        self.base_url = base_url
        self.token = token
        self.on_message = on_message
        self.session = Session(key=b"")  # the server signs/verifies; ws JSON messages are unsigned
        self.kernel_id: Optional[str] = None
        self.kernel_name: Optional[str] = None
        self.owned = False
        self.ws = None
        self.http = AsyncHTTPClient()

    # -- REST -------------------------------------------------------------------

    def _headers(self) -> Dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"token {self.token}"
        return headers

    async def _rest(self, method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Any:
        request = HTTPRequest(
            self.base_url + path,
            method=method,
            headers=self._headers(),
            body=json.dumps(body) if body is not None else (b"" if method == "POST" else None),
            request_timeout=60,
        )
        try:
            response = await self.http.fetch(request)
        except HTTPClientError as e:
            detail = ""
            if e.response is not None and e.response.body:
                detail = e.response.body.decode("utf-8", "replace")[:200]
            raise RuntimeError(f"{method} {path} failed: HTTP {e.code} {detail}".strip()) from None
        return json.loads(response.body) if response.body else None

    async def list_kernels(self):
        return await self._rest("GET", "/api/kernels")

    async def kernel_language(self) -> Optional[str]:
        try:
            specs = await self._rest("GET", "/api/kernelspecs")
            spec = specs.get("kernelspecs", {}).get(self.kernel_name or "", {})
            return spec.get("spec", {}).get("language")
        except Exception:
            return None

    async def start(self, kernel_name: str) -> None:
        info = await self._rest("POST", "/api/kernels", {"name": kernel_name})
        self.kernel_id, self.kernel_name, self.owned = info["id"], info.get("name", kernel_name), True
        await self._open_ws()

    async def attach(self, kernel_id: str) -> None:
        info = await self._rest("GET", "/api/kernels/" + quote(kernel_id))
        self.kernel_id, self.kernel_name, self.owned = info["id"], info.get("name"), False
        await self._open_ws()

    async def interrupt(self) -> None:
        await self._rest("POST", f"/api/kernels/{self.kernel_id}/interrupt")

    async def restart(self) -> None:
        await self._rest("POST", f"/api/kernels/{self.kernel_id}/restart")

    async def close(self) -> None:
        """Disconnect; only shut the kernel down if we started it."""
        if self.ws is not None:
            self.ws.close()
            self.ws = None
        if self.owned and self.kernel_id:
            try:
                await self._rest("DELETE", "/api/kernels/" + self.kernel_id)
            except Exception:
                pass

    # -- websocket --------------------------------------------------------------

    async def _open_ws(self) -> None:
        parts = urlsplit(self.base_url)
        scheme = "wss" if parts.scheme == "https" else "ws"
        query = urlencode({"session_id": self.session.session})
        url = urlunsplit((scheme, parts.netloc, f"{parts.path}/api/kernels/{self.kernel_id}/channels", query, ""))
        self.ws = await websocket_connect(HTTPRequest(url, headers=self._headers()), max_message_size=1 << 30)

    async def run(self) -> None:
        """Read messages until the socket closes."""
        while self.ws is not None:
            raw = await self.ws.read_message()
            if raw is None:
                break
            if isinstance(raw, bytes):
                continue  # binary (v1.kernel.websocket.jupyter.org) frames are not requested
            msg = json.loads(raw)
            self.on_message(msg.pop("channel", ""), msg)

    def _send(self, channel: str, msg_type: str, content: Dict[str, Any]) -> str:
        if self.ws is None:
            raise RuntimeError("not connected")
        msg = self.session.msg(msg_type, content)
        msg["channel"] = channel
        self.ws.write_message(json.dumps(msg, default=json_default))
        return msg["header"]["msg_id"]

    # Same call shapes as jupyter_client's KernelClient
    def execute(self, code: str, stop_on_error: bool = True) -> str:
        return self._send("shell", "execute_request", {
            "code": code, "silent": False, "store_history": True,
            "user_expressions": {}, "allow_stdin": True, "stop_on_error": stop_on_error,
        })

    def complete(self, code: str, cursor_pos: int) -> str:
        return self._send("shell", "complete_request", {"code": code, "cursor_pos": cursor_pos})

    def inspect(self, code: str, cursor_pos: int, detail_level: int = 0) -> str:
        return self._send("shell", "inspect_request", {"code": code, "cursor_pos": cursor_pos, "detail_level": detail_level})

    def kernel_info(self) -> str:
        return self._send("shell", "kernel_info_request", {})

    def input(self, value: str) -> None:
        self._send("stdin", "input_reply", {"value": value})

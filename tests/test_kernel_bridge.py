#!/usr/bin/env python3
"""
Tests for the ipynb.nvim kernel bridge against a real ipykernel.

Run with: python -m pytest tests/test_kernel_bridge.py -v
(needs jupyter_client and ipykernel in the Python that runs pytest)
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time

import pytest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_DIR = os.path.dirname(SCRIPT_DIR)
BRIDGE_PATH = os.path.join(PLUGIN_DIR, "python", "kernel_bridge.py")


class Bridge:
    """Drives kernel_bridge.py the way kernel.lua does. Works on Windows too
    (a reader thread instead of select(), which only supports sockets there)."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, BRIDGE_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.messages: "queue.Queue[dict]" = queue.Queue()
        self.seen: list = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            if line.strip():
                self.messages.put(json.loads(line))

    def send(self, **cmd):
        self.proc.stdin.write(json.dumps(cmd) + "\n")
        self.proc.stdin.flush()

    def next(self, timeout=10.0):
        try:
            msg = self.messages.get(timeout=timeout)
        except queue.Empty:
            return None
        self.seen.append(msg)
        return msg

    def wait(self, pred, timeout=20.0):
        """Return the first message matching pred, or None on timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.next(timeout=max(0.05, deadline - time.time()))
            if msg and pred(msg):
                return msg
        return None

    def collect_until(self, pred, timeout=20.0):
        """All messages up to and including the first that matches pred."""
        out = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.next(timeout=max(0.05, deadline - time.time()))
            if msg:
                out.append(msg)
                if pred(msg):
                    return out
        raise AssertionError(f"timed out; got {[m.get('type') for m in out]}")

    def run(self, code, cell_id, timeout=20.0):
        """Execute code and return all messages until the cell's execute_reply."""
        self.send(action="execute", code=code, cell_id=cell_id)
        return self.collect_until(lambda m: m.get("type") == "execute_reply" and m.get("cell_id") == cell_id, timeout)

    def close(self):
        try:
            self.send(action="shutdown")
            self.proc.wait(timeout=15)
        except Exception:
            self.proc.kill()


def outputs(msgs, cell_id=None):
    return [m["output"] for m in msgs if m.get("type") == "output" and (cell_id is None or m.get("cell_id") == cell_id)]


def stdout_text(msgs, cell_id=None):
    return "".join(o.get("text", "") for o in outputs(msgs, cell_id) if o["output_type"] == "stream")


@pytest.fixture(scope="module")
def bridge():
    b = Bridge()
    assert b.next()["type"] == "ready"
    b.send(action="start", kernel_name="python3")
    started = b.wait(lambda m: m["type"] in ("kernel_started", "error"), timeout=90)
    assert started and started["type"] == "kernel_started", started
    yield b
    b.close()


def test_ping_pong(bridge):
    bridge.send(action="ping")
    assert bridge.wait(lambda m: m["type"] == "pong", timeout=5)


def test_kernel_started_reports_language(bridge):
    started = next(m for m in bridge.seen if m["type"] == "kernel_started")
    assert started["kernel_name"] == "python3"
    assert started["language"] == "python"
    assert started["kernel_id"]


def test_execute_stream_and_result(bridge):
    msgs = bridge.run("print('hello')\n40 + 2", "c-basic")
    assert "hello" in stdout_text(msgs, "c-basic")
    result = [o for o in outputs(msgs, "c-basic") if o["output_type"] == "execute_result"]
    assert result and result[0]["data"]["text/plain"] == "42"
    count = next(m for m in msgs if m["type"] == "execute_input")["execution_count"]
    assert isinstance(count, int) and count >= 1


def test_execute_reply_reports_status_and_times(bridge):
    msgs = bridge.run("import time; time.sleep(0.3)", "c-time")
    started = next(m for m in msgs if m["type"] == "execute_input")
    reply = msgs[-1]
    assert reply["status"] == "ok"
    assert started["date"] and reply["date"] and reply["date"] > started["date"]


def test_error_output_and_reply_status(bridge):
    msgs = bridge.run("undefined_variable_xyz", "c-err")
    errors = [o for o in outputs(msgs, "c-err") if o["output_type"] == "error"]
    assert errors and errors[0]["ename"] == "NameError"
    assert msgs[-1]["status"] == "error"


def test_cells_queued_after_error_are_aborted_not_run(bridge):
    bridge.send(action="execute", code="raise ValueError('stop')", cell_id="q1")
    bridge.send(action="execute", code="print('should not run')", cell_id="q2")
    msgs = bridge.collect_until(lambda m: m.get("type") == "execute_reply" and m.get("cell_id") == "q2")
    assert not stdout_text(msgs, "q2")
    assert msgs[-1]["status"] == "aborted"


def test_clear_output_is_forwarded(bridge):
    msgs = bridge.run("from IPython.display import clear_output\nprint('old')\nclear_output(wait=True)\nprint('new')", "c-clear")
    clears = [m for m in msgs if m["type"] == "clear_output"]
    assert clears and clears[0]["cell_id"] == "c-clear" and clears[0]["wait"] is True


def test_display_updates_are_forwarded(bridge):
    msgs = bridge.run("from IPython.display import display\nh = display('a', display_id='disp-1')\nh.update('b')", "c-disp")
    shown = [o for o in outputs(msgs, "c-disp") if o["output_type"] == "display_data"]
    assert shown and shown[0]["transient"]["display_id"] == "disp-1"
    update = next(m for m in msgs if m["type"] == "update_display")
    assert update["display_id"] == "disp-1"
    assert update["output"]["data"]["text/plain"] == "'b'"


def test_rich_mime_bundles_are_passed_through(bridge):
    code = "from IPython.display import Markdown, Latex, HTML, display\ndisplay(Markdown('**b**'))\ndisplay(Latex('$x$'))\nHTML('<b>h</b>')"
    mimes = {k for o in outputs(bridge.run(code, "c-mime"), "c-mime") for k in o.get("data", {})}
    assert {"text/markdown", "text/latex", "text/html"} <= mimes


def test_magics_and_shell_commands(bridge):
    msgs = bridge.run("%time x = 1\n!echo shell-ok", "c-magic")
    text = stdout_text(msgs, "c-magic")
    assert "shell-ok" in text and "Wall time" in text


def test_completion_queued_behind_a_cell_gets_its_own_reply(bridge):
    # The kernel answers shell requests in order, so completion waits for the
    # running cell; neither reply may be mistaken for the other.
    bridge.send(action="execute", code="import time; time.sleep(1.5)", cell_id="c-busy")
    bridge.send(action="complete", code="pri", cursor_pos=3, request_id="r1")
    msgs = bridge.collect_until(lambda m: m.get("type") == "complete_reply", timeout=15)
    reply = msgs[-1]
    assert reply["request_id"] == "r1" and "print" in reply["matches"]
    assert any(m.get("type") == "execute_reply" and m.get("cell_id") == "c-busy" for m in msgs + [
        bridge.wait(lambda m: m.get("type") == "execute_reply" and m.get("cell_id") == "c-busy", timeout=5) or {}
    ])


def test_inspect_returns_sections(bridge):
    bridge.run("value_to_inspect = [1, 2, 3]", "c-insp")
    bridge.send(action="inspect", code="value_to_inspect", cursor_pos=16, request_id="i1")
    reply = bridge.wait(lambda m: m["type"] == "inspect_reply", timeout=10)
    assert reply and reply["request_id"] == "i1" and reply["found"] is True
    assert "list" in json.dumps(reply["sections"])


def test_stdin_input_request_reply(bridge):
    bridge.send(action="execute", code="name = input('Name: ')\nprint('hi', name)", cell_id="c-in")
    req = bridge.wait(lambda m: m["type"] == "input_request", timeout=10)
    assert req and "Name:" in req["prompt"] and req["cell_id"] == "c-in"
    bridge.send(action="input_reply", request_id=req["request_id"], value="Ada")
    msgs = bridge.collect_until(lambda m: m.get("type") == "execute_reply" and m.get("cell_id") == "c-in")
    assert "hi Ada" in stdout_text(msgs, "c-in")


def test_interrupt_stops_running_cell_quickly(bridge):
    bridge.send(action="execute", code="import time\nfor _ in range(100): time.sleep(0.2)", cell_id="c-int")
    assert bridge.wait(lambda m: m.get("type") == "execute_input" and m.get("cell_id") == "c-int")
    t0 = time.time()
    bridge.send(action="interrupt")
    msgs = bridge.collect_until(lambda m: m.get("type") == "execute_reply" and m.get("cell_id") == "c-int", timeout=15)
    assert any(o.get("ename") == "KeyboardInterrupt" for o in outputs(msgs, "c-int"))
    assert time.time() - t0 < 5


def test_unicode_output_round_trips(bridge):
    msgs = bridge.run("print('μs ✓ 日本')", "c-uni")
    assert "μs ✓ 日本" in stdout_text(msgs, "c-uni")


def test_restart_clears_state(bridge):
    bridge.run("restart_marker = 1", "c-pre")
    bridge.send(action="restart")
    assert bridge.wait(lambda m: m["type"] in ("restarted", "error"), timeout=60)["type"] == "restarted"
    msgs = bridge.run("restart_marker", "c-post")
    assert any(o.get("ename") == "NameError" for o in outputs(msgs, "c-post"))


def test_connect_to_existing_kernel_and_disconnect_leaves_it_running(tmp_path):
    from jupyter_client import KernelManager

    km = KernelManager(kernel_name="python3", connection_file=str(tmp_path / "kernel.json"))
    km.start_kernel()
    try:
        b = Bridge()
        assert b.next()["type"] == "ready"
        b.send(action="connect", connection_file=km.connection_file)
        connected = b.wait(lambda m: m["type"] in ("kernel_connected", "error"), timeout=60)
        assert connected and connected["type"] == "kernel_connected", connected
        assert "connected-ok" in stdout_text(b.run("print('connected-ok')", "c-conn"), "c-conn")
        b.close()
        time.sleep(1)
        assert km.is_alive(), "disconnecting must not shut down a kernel we did not start"
    finally:
        km.shutdown_kernel(now=True)


def test_bad_commands_report_errors_without_crashing(bridge):
    bridge.proc.stdin.write("not json\n")
    bridge.proc.stdin.flush()
    assert bridge.wait(lambda m: m["type"] == "error" and "Invalid JSON" in m["error"], timeout=5)
    bridge.send(action="execute", code="1")
    assert bridge.wait(lambda m: m["type"] == "error" and "cell_id" in m["error"], timeout=5)
    bridge.send(action="ping")
    assert bridge.wait(lambda m: m["type"] == "pong", timeout=5)

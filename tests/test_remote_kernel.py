#!/usr/bin/env python3
"""
Bridge against kernels on a real Jupyter server (as with JupyterLab/JupyterHub).

Run with: python -m pytest tests/test_remote_kernel.py -v
(needs jupyter_server, jupyter_client and ipykernel; skipped otherwise)
"""

import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

import pytest

pytest.importorskip("jupyter_server")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "python"))
from test_kernel_bridge import Bridge, outputs, stdout_text  # noqa: E402
from remote_kernel import parse_server_url  # noqa: E402

TOKEN = "ipynb-nvim-test-token"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def api(base, path, method="GET"):
    req = urllib.request.Request(base + path, method=method, headers={"Authorization": f"token {TOKEN}"})
    with urllib.request.urlopen(req, timeout=10) as r:
        body = r.read()
        return json.loads(body) if body else None


@pytest.fixture(scope="module")
def server(tmp_path_factory):
    port = free_port()
    root = tmp_path_factory.mktemp("server")
    proc = subprocess.Popen(
        [sys.executable, "-m", "jupyter", "server", "--no-browser", f"--port={port}", "--ip=127.0.0.1",
         f"--IdentityProvider.token={TOKEN}", f"--ServerApp.root_dir={root}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    base = f"http://127.0.0.1:{port}"
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            api(base, "/api/status")
            break
        except Exception:
            time.sleep(0.5)
    else:
        proc.kill()
        pytest.fail("jupyter server did not start")
    yield base
    proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()


def connect(base, kernel=None, url=None):
    b = Bridge()
    assert b.next()["type"] == "ready"
    b.send(action="connect_server", url=url or f"{base}/lab?token={TOKEN}", kernel=kernel)
    msg = b.wait(lambda m: m["type"] in ("kernel_connected", "error"), timeout=90)
    assert msg and msg["type"] == "kernel_connected", msg
    return b, msg


def test_parse_server_url():
    assert parse_server_url("http://localhost:8888/lab?token=abc") == ("http://localhost:8888", "abc")
    assert parse_server_url("https://hub.example.com/user/me/lab/tree/x.ipynb?token=t") == ("https://hub.example.com/user/me", "t")
    assert parse_server_url("http://localhost:8888/") == ("http://localhost:8888", "")
    with pytest.raises(ValueError):
        parse_server_url("localhost:8888")


def test_start_run_and_shutdown_remote_kernel(server):
    b, info = connect(server)
    try:
        assert info["language"] == "python"
        assert info["attached"] is False
        assert TOKEN not in json.dumps(info), "token must never be echoed back"
        msgs = b.run("print('remote hi')\n6 * 7", "r1")
        assert "remote hi" in stdout_text(msgs, "r1")
        assert any(o.get("data", {}).get("text/plain") == "42" for o in outputs(msgs, "r1"))
        assert msgs[-1]["status"] == "ok"
        assert any(k["id"] == info["kernel_id"] for k in api(server, "/api/kernels"))
    finally:
        b.close()
    time.sleep(1)
    assert all(k["id"] != info["kernel_id"] for k in api(server, "/api/kernels")), "kernel we started is shut down"


def test_remote_interrupt_input_and_completion(server):
    b, _ = connect(server)
    try:
        b.send(action="complete", code="pri", cursor_pos=3, request_id="c1")
        reply = b.wait(lambda m: m["type"] == "complete_reply", timeout=10)
        assert reply and "print" in reply["matches"]
        b.send(action="execute", code="import time\nfor _ in range(100): time.sleep(0.2)", cell_id="r2")
        assert b.wait(lambda m: m.get("type") == "execute_input" and m.get("cell_id") == "r2")
        b.send(action="interrupt")
        msgs = b.collect_until(lambda m: m.get("type") == "execute_reply" and m.get("cell_id") == "r2", timeout=20)
        assert any(o.get("ename") == "KeyboardInterrupt" for o in outputs(msgs, "r2"))

        b.send(action="execute", code="v = input('Value: ')\nprint('got', v)", cell_id="r3")
        req = b.wait(lambda m: m["type"] == "input_request", timeout=10)
        assert req and "Value:" in req["prompt"]
        b.send(action="input_reply", request_id=req["request_id"], value="42")
        msgs = b.collect_until(lambda m: m.get("type") == "execute_reply" and m.get("cell_id") == "r3")
        assert "got 42" in stdout_text(msgs, "r3")
    finally:
        b.close()


def test_remote_restart(server):
    b, _ = connect(server)
    try:
        b.run("marker = 1", "r4")
        b.send(action="restart")
        assert b.wait(lambda m: m["type"] in ("restarted", "error"), timeout=60)["type"] == "restarted"
        msgs = b.run("marker", "r5")
        assert any(o.get("ename") == "NameError" for o in outputs(msgs, "r5"))
    finally:
        b.close()


def test_attach_to_running_kernel_leaves_it_running(server):
    kernel = urllib.request.Request(server + "/api/kernels", data=b'{"name": "python3"}', method="POST",
                                    headers={"Authorization": f"token {TOKEN}", "Content-Type": "application/json"})
    with urllib.request.urlopen(kernel, timeout=30) as r:
        kernel_id = json.loads(r.read())["id"]
    try:
        b, info = connect(server, kernel=kernel_id)
        assert info["attached"] is True and info["kernel_id"] == kernel_id
        assert "attached-ok" in stdout_text(b.run("print('attached-ok')", "r6"), "r6")
        b.close()
        time.sleep(1)
        assert any(k["id"] == kernel_id for k in api(server, "/api/kernels")), "someone else's kernel keeps running"
    finally:
        api(server, "/api/kernels/" + kernel_id, method="DELETE")


def test_list_server_kernels(server):
    b = Bridge()
    try:
        assert b.next()["type"] == "ready"
        b.send(action="list_server_kernels", url=f"{server}/?token={TOKEN}")
        msg = b.wait(lambda m: m["type"] in ("server_kernels", "error"), timeout=20)
        assert msg["type"] == "server_kernels" and isinstance(msg["kernels"], list)
    finally:
        b.close()


def test_bad_token_reports_error(server):
    b = Bridge()
    try:
        assert b.next()["type"] == "ready"
        b.send(action="connect_server", url=f"{server}/?token=wrong")
        msg = b.wait(lambda m: m["type"] in ("kernel_connected", "error"), timeout=20)
        assert msg["type"] == "error" and "403" in msg["error"]
        assert "wrong" not in msg["error"]
    finally:
        b.close()

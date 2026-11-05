# SPDX-License-Identifier: Apache-2.0
"""The hermetic guard in tests/conftest.py holds: a test cannot reach a socket, and a source with no test transport
reads unreachable at once instead of waiting on a real connection."""
import socket
import time

import httpx
import pytest


def test_a_planted_test_that_opens_a_socket_fails():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        with pytest.raises(RuntimeError, match="hermetic test"):
            s.connect(("192.0.2.1", 9))          # TEST-NET-1: never routed; the guard refuses before any packet
    finally:
        s.close()


def test_a_client_without_a_transport_is_unreachable_at_once():
    t0 = time.monotonic()
    with pytest.raises(httpx.ConnectError, match="hermetic test"):
        httpx.get("https://kube.test/api", timeout=30)
    assert time.monotonic() - t0 < 1.0


def test_a_mock_transport_still_answers():
    c = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"ok": True})))
    assert c.get("http://x.test/").json() == {"ok": True}


def test_loopback_stays_open_for_in_process_servers():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        c.connect(srv.getsockname())                     # allowed: a test's own server
    finally:
        c.close()
        srv.close()

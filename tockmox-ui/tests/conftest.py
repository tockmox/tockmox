# SPDX-License-Identifier: Apache-2.0
"""Every UI test is hermetic: no test reaches a real network.

The suite was the CI floor (about 245 s) partly because a source built without a test transport (a KubeClient, a feed
or a probe that a test did not mock) really tried to connect and waited for the failure, and every httpx client built
a fresh TLS context (about 25 ms each). Here, for every test:

  - httpx's real transport answers ConnectError at once for any host but loopback, so "unreachable" reads exactly as
    it did, instantly; a test that mocks an upstream passes its own transport (httpx.MockTransport) and is unaffected,
    and the runner's and telemetry's tests keep their in-process servers on 127.0.0.1
  - opening an internet socket to anything but loopback fails the test, so a new test cannot quietly reach the network
  - ssl.create_default_context hands out one context per set of arguments, built once

Nothing here changes what the app does; it changes what a test may touch. Opt out for one test with the marker
`real_network` (no test uses it today).
"""
import socket
import ssl

import httpx
import pytest

_REAL_CTX = ssl.create_default_context
_CTX_CACHE = {}


def _cached_ctx(purpose=ssl.Purpose.SERVER_AUTH, *, cafile=None, capath=None, cadata=None):
    key = (purpose, cafile, capath, cadata if not isinstance(cadata, (bytes, bytearray)) else bytes(cadata))
    if key not in _CTX_CACHE:
        _CTX_CACHE[key] = _REAL_CTX(purpose, cafile=cafile, capath=capath, cadata=cadata)
    return _CTX_CACHE[key]


LOOPBACK = ("127.0.0.1", "::1", "localhost")
_REAL_HANDLE = httpx.HTTPTransport.handle_request


def _no_network(self, request):
    if request.url.host in LOOPBACK:
        return _REAL_HANDLE(self, request)          # a test's own in-process server
    raise httpx.ConnectError("hermetic test: no real network (tests/conftest.py)", request=request)


_REAL_CONNECT = socket.socket.connect
_REAL_CONNECT_EX = socket.socket.connect_ex


def _guard(real):
    def connect(self, address):
        host = address[0] if isinstance(address, tuple) and address else None
        if self.family in (socket.AF_INET, socket.AF_INET6) and host not in LOOPBACK:
            raise RuntimeError(f"hermetic test: a test opened an internet socket to {address!r} (tests/conftest.py)")
        return real(self, address)
    return connect


def pytest_configure(config):
    config.addinivalue_line("markers", "real_network: this test may reach the network (none should)")


@pytest.fixture(autouse=True)
def _hermetic(request, monkeypatch):
    if request.node.get_closest_marker("real_network"):
        yield
        return
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _no_network)
    monkeypatch.setattr(ssl, "create_default_context", _cached_ctx)
    monkeypatch.setattr(socket.socket, "connect", _guard(_REAL_CONNECT))
    monkeypatch.setattr(socket.socket, "connect_ex", _guard(_REAL_CONNECT_EX))
    yield

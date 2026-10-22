# SPDX-License-Identifier: Apache-2.0
"""Port 8000 on a Mac: oMLX, vllm-mlx and vllm-metal share it. vLLM is told by its signature; the others are not guessed."""
import socket
import sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.probe import Prober  # noqa: E402

IP = "192.0.2.40"


def prober(handler):
    return Prober(["192.0.2.0/24"], timeout=1, transport=httpx.MockTransport(handler),
                  resolver=lambda host, port, *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (IP, 0))])


def only(handler, port=8000):
    def h(req):
        if req.url.port != port:
            raise httpx.ConnectError("refused", request=req)
        return handler(req)
    return h


def probe(handler):
    r = prober(only(handler)).probe(IP, "apple-silicon-mac", [])
    return next(f for f in r.findings if f.port == 8000)


def test_a_plain_openai_server_on_8000_is_not_named_but_the_page_says_why():
    f = probe(lambda req: httpx.Response(200, json={"object": "list", "data": [{"id": "mlx-community/Example-4bit", "object": "model"}]})
              if req.url.path == "/v1/models" else httpx.Response(404, json={}))
    assert f.engine == "openai-compatible" and not f.suggested
    assert "oMLX" in f.hint and "vllm-mlx" in f.hint


def test_vllm_is_still_recognised_by_its_signature():
    def h(req):
        if req.url.path == "/version":
            return httpx.Response(200, json={"version": "0.11.0"})
        if req.url.path == "/v1/models":
            return httpx.Response(200, json={"object": "list", "data": [{"id": "m", "object": "model", "owned_by": "vllm"}]})
        return httpx.Response(404, json={})
    f = probe(h)
    assert f.engine == "vllm" and f.version == "0.11.0"

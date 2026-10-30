# SPDX-License-Identifier: Apache-2.0
"""TM-1249: the data-class rails' pieces outside a whole run (tests/test_runner.py runs them end to end): the client
reads the gateway's tiers and tags its requests, and the eval gateway's entries are fenced by tier the same way in the
UI as in the chart (tools/check-inference-nodes.sh holds the chart to tests/golden)."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from app import models as ml
from app import nodes as nm
from app.runner import client as cl


def _serve(status, body):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            b = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def test_model_info_reads_litellms_shape_and_fails_closed():
    rows = {"data": [{"model_name": "a-next", "litellm_params": {"tags": ["open"]}, "model_info": {"endpoint_tier": "external"}},
                     {"model_name": "a", "model_info": {"endpoint_tier": "local"}}, {"model_name": 7}, "junk"]}
    srv, url = _serve(200, rows)
    try:
        got = cl.model_info(url, "k")
    finally:
        srv.shutdown()
    assert got == {"a-next": {"endpoint_tier": "external", "tags": ["open"]}, "a": {"endpoint_tier": "local"}}
    for status, body in ((404, {"data": rows["data"]}), (200, b"not json"), (200, {"data": "x"})):
        srv, url = _serve(status, body)
        try:
            assert cl.model_info(url, "k") == {}
        finally:
            srv.shutdown()
    assert cl.model_info("http://127.0.0.1:9", "k") == {}           # nothing listening: cannot tell


def test_tagged_sets_the_tag_for_every_thread_and_restores_it():
    assert cl._TAGS == []
    with cl.tagged(["internal"]):
        seen = []
        t = threading.Thread(target=lambda: seen.append(list(cl._TAGS)))
        t.start()
        t.join()
        assert seen == [["internal"]]
        with pytest.raises(RuntimeError):
            with cl.tagged(["open"]):
                raise RuntimeError
        assert cl._TAGS == ["internal"]
    assert cl._TAGS == []


@pytest.mark.parametrize("info,lp,want_tags,want_tier", [
    ({}, {}, ["restricted", "internal", "open"], "local"),                       # a node route: local, every class
    ({"endpoint_tier": "local"}, {"tags": ["open"]}, ["open"], "local"),          # its own tags are kept
    ({"endpoint_tier": "external"}, {}, ["open"], "external"),
])
def test_the_eval_fence_fills_tier_and_tags(info, lp, want_tags, want_tier):
    nm.eval_class_fence("r", lp, info)
    assert lp["tags"] == want_tags and info["endpoint_tier"] == want_tier


def test_the_eval_fence_refuses_an_external_route_tagged_for_more_and_an_unknown_tier():
    with pytest.raises(nm.NodeError, match="may carry only the tag open"):
        nm.eval_class_fence("r", {"tags": ["open", "internal"]}, {"endpoint_tier": "external"})
    with pytest.raises(nm.NodeError, match="must be local or external"):
        nm.eval_class_fence("r", {}, {"endpoint_tier": "cloud"})


def test_only_the_eval_gateway_is_fenced_and_hosted_candidates_are_tagged_open():
    inv = nm.parse_inventory({"nodes": [{"id": "n", "name": "N", "type": "apple-silicon-mac", "address": "192.0.2.1",
                                         "endpoints": [{"id": "e", "engine": "mlx-lm", "url": "http://192.0.2.1:8080"}]}],
                              "routes": [{"alias": "a", "node": "n", "endpoint": "e", "model": "m/one"},
                                         {"alias": "a-next", "node": "n", "endpoint": "e", "model": "m/two"}]})
    prod = nm.render_model_list(inv, "production")
    assert all("tags" not in e["litellm_params"] and "endpoint_tier" not in e["model_info"] for e in prod)
    ev = nm.render_model_list(inv, "eval")
    assert {e["model_name"] for e in ev} == {"a", "a-next"}
    assert all(e["litellm_params"]["tags"] == ["restricted", "internal", "open"] for e in ev)
    lc = ml.parse({"catalog": [{"id": "h", "model": "anthropic/x-9", "source": {"kind": "hosted", "ref": "anthropic/x-9"},
                                "stage": "candidate"}]})
    [h] = ml.hosted_candidate_entries(lc)
    assert h["litellm_params"]["tags"] == ["open"] and h["model_info"]["endpoint_tier"] == "external"

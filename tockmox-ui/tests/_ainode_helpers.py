# SPDX-License-Identifier: Apache-2.0
"""Shared fixtures for the enrolled-node tests: a fake Prometheus and an app that reads it."""
import html
import re
import sys
import time
from pathlib import Path

import httpx
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import nodes as nm  # noqa: E402
from app import sources  # noqa: E402

NOW = 1_800_000_000.0
P = "tockmox_ai_node_converge_"
SHA = "0123456789abcdef0123456789abcdef01234567"

MAC_READY = list(nm.READINESS_CHECKS)


def row(name, value, now=NOW, **labels):
    return {"metric": {"__name__": name, **labels}, "value": [now, str(value)]}


def converge_rows(node="studio", *, now=NOW, success_ago=120, run_ago=60, exit_code=0, phase=None, changed=0, ok=12, signature=1,
                  commit=SHA, ref="v0.9.0", mode="warn", with_exit=True, **info):
    """Every converge series the contract names, for one node."""
    r = [row(P + "last_run_timestamp_seconds", now - run_ago, now, ai_node=node),
         row(P + "last_success_timestamp_seconds", now - success_ago, now, ai_node=node),
         row(P + "duration_seconds", 41, now, ai_node=node),
         row(P + "signature_ok", signature, now, ai_node=node),
         row(P + "tasks", ok, now, ai_node=node, state="ok"),
         row(P + "tasks", changed, now, ai_node=node, state="changed"),
         row(P + "tasks", 1 if exit_code else 0, now, ai_node=node, state="failed"),
         row(P + "info", 1, now, ai_node=node, site_commit=commit, toolkit_ref=ref, desired_sha256="a" * 64, signing_mode=mode)]
    if with_exit:
        r.append(row(P + "last_exit_code", exit_code, now, ai_node=node))
    for ph in ("fetch", "verify", "decrypt", "load", "run"):
        r.append(row(P + "phase", 1 if ph == phase else 0, now, ai_node=node, phase=ph))
    return r


def readiness_rows(node="studio", *, now=NOW, bad=(), missing=()):
    return [row("tockmox_ai_node_readiness", 0 if c in bad else 1, now, ai_node=node, check=c)
            for c in MAC_READY if c not in missing]


def info_row(node="studio", *, now=NOW, **over):
    lab = {"chip": "Apple M5 Ultra", "memory_gib": "256", "gpu_cores": "80", "os": "macOS", "os_version": "27.0",
           "os_build": "27A5000", "arch": "arm64", **over}
    return row("tockmox_ai_node_info", 1, now, ai_node=node, **lab)


class FakeProm:
    """Answers /api/v1/query. `ai` is the tockmox_ai_node_* set; `flap` maps a window-query function name to its rows."""

    def __init__(self, ai=(), flap=None, up=(), fail=False):
        self.ai, self.flap, self.up, self.fail = list(ai), flap or {}, list(up), fail
        self.queries = []

    def handler(self, request):
        if self.fail:
            return httpx.Response(503)
        q = request.url.params["query"]
        self.queries.append(q)
        if q == sources.AI_NODE_SERIES:
            res = self.ai
        elif q == "up":
            res = self.up
        elif q.startswith("min_over_time("):
            res = self.flap.get("changed", [])
        elif q.startswith("changes("):
            res = self.flap.get("runs", [])
        elif q.startswith("count by (ai_node) (last_over_time("):
            res = self.flap.get("inputs", [])
        else:
            res = []
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": res}})

    def transport(self):
        return httpx.MockTransport(self.handler)


def flap_rows(node="studio", *, changed=3, runs=2, inputs=1, now=NOW):
    return {"changed": [row("", changed, now, ai_node=node, state="changed")],
            "runs": [row("", runs, now, ai_node=node)],
            "inputs": [row("", inputs, now, ai_node=node)]}


def inventory(*nodes, ai=None):
    doc = {"nodes": list(nodes)}
    if ai:
        doc["aiNodes"] = ai
    return nm.parse_inventory(doc)


def mac(nid="studio", *, enrolled=True, address="10.0.0.5", memory=None, source="preset", **extra):
    d = {"id": nid, "name": nid.title(), "type": "apple-silicon-mac", "address": address,
         "metrics": {"node_exporter": 9100}, "endpoints": [{"id": "mlx-lm-8080", "engine": "mlx-lm", "url": f"http://{address}:8080"}], **extra}
    if enrolled:
        d["management"] = {"enrolled": True}
    if memory:
        d["hardware"] = {"memory_gib": {"value": memory, "source": source}}
    return d


def read(inv, prom, **kw):
    src = sources.InferenceNodesSource("http://prom.test", inv, 1.0, prom.transport(), ttl=0)
    r = src.read(lambda: NOW)
    return r, {x["id"]: x for x in (r.data or [])}


# ---- the app

def make_app(tmp_path, nodes_block, prom=None, ttl=0.0):
    """An app whose inference-node source does not cache (ttl 0), so a changed fake Prometheus shows on the next request."""
    from fastapi.testclient import TestClient
    from app import config
    from app.auth import Sessions
    from app.main import Transports, create_app
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["inferenceNodes"] = nodes_block
    s = config.parse(doc)
    tp = Transports(prometheus=(prom or FakeProm()).transport())
    from app import main
    real = main.InferenceNodesSource
    main.InferenceNodesSource = lambda *a, **k: real(*a, **{**k, "ttl": ttl})
    try:
        app = create_app(s, tp, notes_path=str(tmp_path / "none.md"))
    finally:
        main.InferenceNodesSource = real
    c = TestClient(app)
    sess = Sessions(s.session_secret, 3600, s.admin_group, False)
    c.cookies.set(sess.session_cookie, sess.issue("a", "Admin", [s.admin_group]))
    return c


def csrf(c):
    t = c.get("/nodes/add/apple-silicon-mac").text
    return re.search(r'name="csrf" value="([^"]+)"', t).group(1)


def draft_of(page_html):
    m = re.search(r'name="draft"[^>]*value="([^"]+)"', page_html)
    return html.unescape(m.group(1)) if m else None

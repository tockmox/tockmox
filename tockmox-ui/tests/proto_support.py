# SPDX-License-Identifier: Apache-2.0
import base64
import json
import os
import sys
import time

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from app import config as cfgmod  # noqa: E402
from app.auth import Sessions  # noqa: E402
from app.main import Transports, create_app  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

FIX = os.path.join(ROOT, "tests", "fixtures")
ISSUER = "https://auth.int.example.com/application/o/tockmox-ui"
SECRET = "x" * 48


def _iso(ts):
    import datetime
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def app_obj(name, rev="v0.7.2", sync="Synced", health="Healthy", repo="https://github.com/tockmox/tockmox", reconciled_ago=30):
    return {"metadata": {"name": name},
            "spec": {"sources": [{"repoURL": repo, "targetRevision": rev}, {"repoURL": "https://forgejo.example/site", "targetRevision": "main"}]},
            "status": {"sync": {"status": sync}, "health": {"status": health},
                       **({"reconciledAt": _iso(time.time() - reconciled_ago)} if reconciled_ago is not None else {})}}


class World:
    """Mutable upstream state the mock transports serve. Tests change it."""

    def __init__(self):
        self.apps = [app_obj("tockmox-platform"), app_obj("tockmox-observability"), app_obj("tockmox-ai"),
                     app_obj("site-apps", rev="main", repo="https://forgejo.example/site")]
        self.nodes = [{"metadata": {"name": "node-1"}, "status": {"conditions": [{"type": "Ready", "status": "True"}],
                                                                  "nodeInfo": {"kubeletVersion": "v1.36.5+k3s1"}}}]
        self.up = [("prometheus", "1"), ("node-exporter", "1")]
        self.alerts = [{"labels": {"alertname": "Watchdog", "severity": "none"}, "annotations": {}}]   # heartbeat
        self.series = {}           # extra Prometheus series: query -> [(labels, value)]
        self.down = set()          # names of upstreams that refuse connections
        self.requests = []         # every request any upstream saw

    def handler(self, which):
        def h(req: httpx.Request):
            self.requests.append((which, req))
            if which in self.down:
                raise httpx.ConnectError("refused", request=req)
            p = req.url.path
            if which == "kube":
                if p.endswith("/applications"):
                    return httpx.Response(200, json={"items": self.apps})
                if p == "/api/v1/nodes":
                    return httpx.Response(200, json={"items": self.nodes})
                return httpx.Response(403, json={})
            if which == "prometheus":
                q = req.url.params.get("query", "")
                res = [{"metric": {"job": j, "instance": j + ":9090"}, "value": [time.time(), v]} for j, v in self.up] if q == "up" else []
                res += [{"metric": dict(lab), "value": [time.time(), str(v)]} for lab, v in self.series.get(q, [])]
                return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": res}})
            if which == "alertmanager":
                return httpx.Response(200, json=self.alerts)
            return httpx.Response(404)
        return h


@pytest.fixture
def world():
    return World()


@pytest.fixture
def feed_keys():
    sk = ed25519.Ed25519PrivateKey.generate()
    pub = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return sk, base64.b64encode(pub).decode()


def sign(sk, body: bytes) -> bytes:
    return base64.b64encode(sk.sign(body))


def base_doc(**over):
    doc = {
        "site": {"name": "Example Site", "domain": "int.example.com", "accountUrl": "https://auth.int.example.com/if/user/"},
        "roles": {"adminGroup": "tockmox-admins"},
        "apps": [
            {"id": "chat", "name": "Chat", "url": "https://chat.int.example.com", "description": "Open WebUI", "icon": "chat", "groups": ["*"]},
            {"id": "grafana", "name": "Grafana", "url": "https://grafana.int.example.com", "icon": "chart", "groups": ["tockmox-users", "tockmox-admins"]},
            {"id": "workflows", "name": "Workflows", "url": "https://workflows.int.example.com", "icon": "flow", "groups": ["tockmox-admins"]},
        ],
        "sources": {"kubernetes": {"url": "https://kube.test", "tokenFile": "/nonexistent", "caFile": "/nonexistent"},
                    "prometheus": {"url": "http://prom.test"}, "alertmanager": {"url": "http://am.test"},
                    "timeoutSeconds": 1},
        "features": {"posture": {"enabled": True, "reportFile": os.path.join(FIX, "posture-report.json")},
                     "scanning": {"enabled": False}, "agents": {"enabled": False}},
        "updateCheck": {"enabled": False, "feedUrl": "https://releases.tockmox.test/feed.json"},
        "oidc": {"issuer": ISSUER, "clientId": "tockmox-ui", "redirectUrl": "https://tockmox.int.example.com/auth/callback"},
        "session": {"maxAgeSeconds": 3600, "secureCookies": False},
    }
    for k, v in over.items():
        doc[k] = v
    return doc


@pytest.fixture(autouse=True)
def _secret(monkeypatch):
    monkeypatch.setenv("TOCKMOX_UI_SESSION_SECRET", SECRET)
    monkeypatch.setenv("TOCKMOX_UI_OIDC_CLIENT_SECRET", "client-secret")


def make_client(world, doc=None, feed_transport=None, oidc_transport=None, probe_transport=None, resolver=None):
    s = cfgmod.parse(doc or base_doc())
    tp = Transports(kube=httpx.MockTransport(world.handler("kube")),
                    prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")),
                    oidc=oidc_transport, feed=feed_transport, probe=probe_transport, resolver=resolver)
    app = create_app(s, tp, notes_path=os.path.join(ROOT, "tests", "fixtures", "none.md"))
    return TestClient(app, follow_redirects=False), app, s


def login_as(client, s, groups, sub="u1", name="Test User"):
    ses = Sessions(s.session_secret, s.session_max_age_s, s.admin_group, s.secure_cookies)
    client.cookies.set(ses.session_cookie, ses.issue(sub, name, groups))
    return ses.read(client.cookies.get(ses.session_cookie))


# ---------------------------------------------------------------- mock IdP

class MockIdP:
    def __init__(self, groups=("tockmox-admins",), nonce_override=None, aud="tockmox-ui", iss=None,
                 disc_iss=None, groups_in_token=True, userinfo_sub="u-admin", azp=None):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.groups, self.nonce_override, self.aud = list(groups), nonce_override, aud
        self.iss, self.disc_iss, self.groups_in_token = iss or ISSUER, disc_iss or ISSUER, groups_in_token
        self.userinfo_sub, self.azp = userinfo_sub, azp
        self.last_auth = None
        self.token_requests = []

    def jwk(self):
        pub = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(self.key.public_key()))
        pub.update(kid="k1", use="sig", alg="RS256")
        return {"keys": [pub]}

    def handler(self, req: httpx.Request):
        p = req.url.path
        base = "/application/o/tockmox-ui"
        if p == base + "/.well-known/openid-configuration":
            return httpx.Response(200, json={"issuer": self.disc_iss, "authorization_endpoint": "https://auth.int.example.com/application/o/authorize/",
                                             "token_endpoint": "https://auth.int.example.com/application/o/token/",
                                             "jwks_uri": "https://auth.int.example.com/application/o/tockmox-ui/jwks/",
                                             "userinfo_endpoint": "https://auth.int.example.com/application/o/userinfo/"})
        if p.endswith("/jwks/"):
            return httpx.Response(200, json=self.jwk())
        if p == "/application/o/token/":
            form = dict(x.split("=", 1) for x in req.content.decode().split("&"))
            self.token_requests.append(form)
            now = int(time.time())
            claims = {"iss": self.iss, "aud": self.aud, "sub": "u-admin", "iat": now, "exp": now + 300,
                      "nonce": self.nonce_override or self.last_nonce, "name": "Admin"}
            if self.groups_in_token:
                claims["groups"] = self.groups
            if self.azp:
                claims["azp"] = self.azp
            idt = jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": "k1"})
            return httpx.Response(200, json={"id_token": idt, "access_token": "at", "token_type": "Bearer"})
        if p == "/application/o/userinfo/":
            return httpx.Response(200, json={"sub": self.userinfo_sub, "groups": self.groups})
        return httpx.Response(404)


# ---------------------------------------------------------------- inference nodes (REQ-0047)

REFERENCE_CM = os.path.join(FIX, "reference-litellm-configmap.yaml")
STUDIO, MINI = "192.0.2.9", "192.0.2.14"


def reference_model_list():
    import yaml
    cm = yaml.safe_load(open(REFERENCE_CM, encoding="utf-8"))
    return yaml.safe_load(cm["data"]["config.yaml"])["model_list"]


def reference_inventory_doc():
    """The two Macs as an admin would commit them after importing the fixture."""
    from app import nodes as nm
    res = nm.import_model_list(reference_model_list(), {STUDIO: "Mac Studio M4 Max", MINI: "Mac mini M4 Pro"})
    doc = nm.inventory_to_doc(res.inventory)
    for n in doc["nodes"]:
        n["type"] = "apple-silicon-mac"
        n["metrics"] = {"node_exporter": 9100, "macmon": 9101}
        chip = "Apple M4 Max" if n["address"] == STUDIO else "Apple M4 Pro"
        n["hardware"] = {"chip": {"value": chip, "source": "preset"}, "memory_gib": {"value": 64, "source": "preset"}}
    return doc


GIB = 1 << 30


def mac_series(world, healthy=True, probes=True, used_gib=(42.0, 30.0)):
    """What the reference site's exporters say (shapes and values captured 2026-10-06)."""
    up, probe = [], []
    for host, used, chip in ((STUDIO, used_gib[0], "Apple M4 Max"), (MINI, used_gib[1], "Apple M4 Pro")):
        for port, job in ((9100, "ai-node-exporter"), (9101, "ai-macmon-exporter")):
            up.append(({"job": job, "instance": f"{host}:{port}"}, "1" if healthy else "0"))
        world.series.setdefault("macmon_memory_ram_total_bytes", []).append(({"instance": f"{host}:9101", "chip": chip}, 64 * GIB))
        world.series.setdefault("macmon_memory_ram_used_bytes", []).append(({"instance": f"{host}:9101", "chip": chip}, int(used * GIB)))
        world.series.setdefault("node_memory_total_bytes", []).append(({"instance": f"{host}:9100"}, 64 * GIB))
    world.series["up"] = up
    if probes:
        from app import nodes as nm
        inv = nm.parse_inventory(reference_inventory_doc())
        world.series["probe_success"] = [({"instance": e.url + ("/v1/models" if e.engine != "ollama" else "/api/version"), "job": "blackbox"}, "1")
                                         for n in inv.nodes for e in n.endpoints]


def nodes_doc(probe_cidrs=None, inventory=True, **extra):
    d = base_doc()
    inf = reference_inventory_doc() if inventory else {}
    if probe_cidrs is not None:
        inf["probe"] = {"allowedCidrs": probe_cidrs, "timeoutSeconds": 1}
    inf["gateway"] = {"sourceCidrs": ["192.0.2.51/32", "192.0.2.52/32"]}
    inf.update(extra)
    d["inferenceNodes"] = inf
    return d


class FakeNode:
    """A node on the wire for the probe: engines by port, answering the real APIs' shapes."""

    def __init__(self, engines=None, token=None):
        self.engines = engines or {}     # port -> engine name
        self.token = token
        self.requests = []
        self.redirect_port = None
        self.huge_port = None
        self.digests = {}                # ollama model name -> digest /api/tags reports (TM-0934)
        self.model_path = None           # llama-server /props model_path (TM-0934)

    def handler(self, req: httpx.Request):
        self.requests.append(req)
        port, path = req.url.port, req.url.path
        if port == self.redirect_port:
            return httpx.Response(302, headers={"Location": "http://169.254.169.254/latest/meta-data/"})
        if port == self.huge_port:
            return httpx.Response(200, content=b"[" + b"0," * (2 << 20) + b"0]")
        eng = self.engines.get(port)
        if eng is None:
            raise httpx.ConnectError("refused", request=req)
        if self.token and req.headers.get("authorization") != "Bearer " + self.token:
            return httpx.Response(401, json={"error": "unauthorized"})
        J = lambda b: httpx.Response(200, json=b)  # noqa: E731
        if eng == "ollama":
            if path == "/api/version":
                return J({"version": "0.31.2"})
            if path == "/api/tags":
                models = [
                    {"name": "qwen3-coder:30b", "size": 18556699604, "details": {"parameter_size": "30.5B", "quantization_level": "Q4_K_M"}},
                    {"name": "nomic-embed-text:latest", "size": 274302450, "details": {"parameter_size": "137M", "quantization_level": "F16"}}]
                for m in models:
                    if m["name"] in self.digests:
                        m["digest"] = self.digests[m["name"]]
                return J({"models": models})
            if path == "/api/ps":
                return J({"models": [{"name": "qwen3-coder:30b", "size_vram": 19000000000}]})
        if eng == "llama-server":
            if path == "/props":
                return J({"default_generation_settings": {"n_ctx": 8192}, "build_info": "b6900-abc",
                          **({"model_path": self.model_path} if self.model_path else {})})
            if path == "/v1/models":
                return J({"object": "list", "data": [{"id": "Qwen3-Embedding-4B-Q8_0.gguf", "object": "model", "owned_by": "llamacpp"}]})
        if eng == "mlx-lm" and path == "/v1/models":
            return J({"object": "list", "data": [{"id": "mlx-community/Qwen3.8-27B-4bit", "object": "model", "created": 1}]})
        if eng == "vllm":
            if path == "/version":
                return J({"version": "0.11.0"})
            if path == "/v1/models":
                return J({"object": "list", "data": [{"id": "Qwen/Qwen3-32B-AWQ", "object": "model", "owned_by": "vllm"}]})
        if eng == "lm-studio" and path == "/api/v0/models":
            return J({"data": [{"id": "qwen3-8b", "state": "loaded", "arch": "qwen3", "quantization": "Q4_K_M"}]})
        if eng == "html":
            return httpx.Response(200, text="<html>router login</html>")
        return httpx.Response(404, json={})


def fake_resolver(table):
    """table: name -> [ip, ...]"""
    import socket

    def r(host, port, *a, **k):
        if host not in table:
            raise socket.gaierror("no such name")
        return [(socket.AF_INET6 if ":" in ip else socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0)) for ip in table[host]]
    return r


# ---------------------------------------------------------------- model lifecycle (REQ-0048)

SHA_OLD = "1111111111111111111111111111111111111111"
SHA_NEW = "2222222222222222222222222222222222222222"
OLLAMA_OLD = "sha256:" + "a" * 64
OLLAMA_NEW = "sha256:" + "b" * 64


def lifecycle_doc(**extra):
    d = {"catalog": [
        {"id": "qwen3-8-27b-4bit", "model": "mlx-community/Qwen3.8-27B-4bit", "family": "qwen3.8", "baseModel": "Qwen/Qwen3.8-27B",
         "quant": "4bit", "sizeGiB": 17.1, "source": {"kind": "huggingface", "ref": "mlx-community/Qwen3.8-27B-4bit", "revision": SHA_OLD},
         "track": ["revision", "quants", "successors"], "adopted": "2026-10-07"},
        {"id": "qwen3-coder-30b", "model": "qwen3-coder:30b", "sizeGiB": 18.0, "adopted": "2026-10-07",
         "source": {"kind": "ollama", "ref": "qwen3-coder:30b", "revision": OLLAMA_OLD}, "track": ["revision"]},
        {"id": "qwen2-5-32b-4bit", "model": "mlx-community/Qwen2.5-32B-Instruct-4bit", "sizeGiB": 18.4, "adopted": "2026-10-07",
         "source": {"kind": "huggingface", "ref": "mlx-community/Qwen2.5-32B-Instruct-4bit"}},
    ],
        "profiles": [{"id": "weekday", "name": "Weekday", "classes": {
            "chat": {"alias": "local-medium-next", "priority": 1, "residency": "pinned"},
            "agent": {"alias": "local-agent", "priority": 2, "residency": "pinned"},
            "coding": {"alias": "ops-agent-30b", "priority": 4, "residency": "on-demand"}}}],
        "activeProfile": "weekday",
        "frontier": {"providers": {"anthropic": {"keyEnv": "ANTHROPIC_API_KEY"}}},
    }
    d.update(extra)
    return d


def lifecycle_full_doc(report=None, **extra):
    d = nodes_doc()
    for i in (0, 2, 3):                                                     # the Studio's 8080/8082/8083 are mlx-lm
        d["inferenceNodes"]["nodes"][1]["endpoints"][i]["engine"] = "mlx-lm"
    d["modelLifecycle"] = lifecycle_doc(**extra)
    if report:
        d["modelLifecycle"]["reportFile"] = report
    return d


def write_report(tmp_path, candidates, sources=None, generated=None):
    import datetime
    p = tmp_path / "report.json"
    p.write_text(json.dumps({"schema": 1, "generatedAt": generated or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "sources": sources if sources is not None else {"huggingface": {"ok": True}, "ollama": {"ok": True}},
                             "candidates": candidates}))
    return str(p)


def verdict_record(model, alias, verdict="pass", run="r1", date="2026-10-07", klass="chat", incumbent="", revision="",
                   eval_version="v1", grader="rule"):
    """A REQ-0045 comparative verdict record (proposed AC-45.9), as the eval runner would write it."""
    d = {"schema": "comparative-verdict/1", "run_id": run, "date": date, "class": klass, "alias": alias,
         "candidate": {"model": model, **({"revision": revision} if revision else {})},
         "eval_set": {"id": f"{klass}-set", "version": eval_version}, "grader": grader,
         "criterion": "design-6/" + klass, "verdict": verdict, "results": [], "methodology": "m.md"}
    if incumbent:
        d["incumbent"] = {"model": incumbent}
    return json.dumps(d)


def verdicts(*records):
    from app import models as ml
    return [ml.parse_verdict(t, f"evals/verdicts/{i}.json") for i, t in enumerate(records)]


def write_verdicts(tmp_path, *records, name="verdicts"):
    d = tmp_path / name
    d.mkdir(exist_ok=True)
    for i, t in enumerate(records):
        (d / f"{i:03d}.json").write_text(t)
    return str(d)

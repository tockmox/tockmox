# SPDX-License-Identifier: Apache-2.0
"""TM-0934: the catalog's pinned build against what the node serving it actually holds.

Git holds the intended build, the node holds the actual one. A mismatch is a finding on /models; a
comparison that cannot be made reads Unknown with its reason, never current. Reading the node rides the
probe's fences (REQ-0047 AC-47.3): nothing is read from an address the probe would refuse.
Run from tockmox-ui/: python -m pytest tests
"""
import datetime
import re
import socket
import sys
from pathlib import Path

import httpx
import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import models as ml  # noqa: E402
from app import nodes as nm  # noqa: E402
from app.probe import BuildReading, Prober, Refused  # noqa: E402

LAN = ["192.0.2.0/24"]
STUDIO_IP = "192.0.2.9"
OLLAMA_OLD = "sha256:" + "a" * 64        # the catalog's pin
OLLAMA_NEW = "sha256:" + "b" * 64        # what a hand-pulled node holds
SHA_NEW = "2" * 40
HF_SNAP = "/Users/ai/.cache/huggingface/hub/models--Qwen--Qwen3-Embedding-4B-GGUF/snapshots/{}/Qwen3-Embedding-4B-Q8_0.gguf"


def lifecycle_doc():
    return {"catalog": [
        {"id": "qwen3-coder-30b", "model": "qwen3-coder:30b", "sizeGiB": 18.0, "adopted": "2026-10-07",
         "source": {"kind": "ollama", "ref": "qwen3-coder:30b", "revision": OLLAMA_OLD}, "track": ["revision"]},
        {"id": "qwen3-8-27b-4bit", "model": "mlx-community/Qwen3.8-27B-4bit", "sizeGiB": 17.1, "adopted": "2026-10-07",
         "source": {"kind": "huggingface", "ref": "mlx-community/Qwen3.8-27B-4bit", "revision": "1" * 40}},
        {"id": "qwen2-5-32b-4bit", "model": "mlx-community/Qwen2.5-32B-Instruct-4bit", "sizeGiB": 18.4, "adopted": "2026-10-07",
         "source": {"kind": "huggingface", "ref": "mlx-community/Qwen2.5-32B-Instruct-4bit"}},   # no pin
    ]}


def inventory_doc(probe=True):
    d = {"nodes": [{"id": "studio", "name": "Studio", "type": "apple-silicon-mac", "address": STUDIO_IP,
                    "endpoints": [{"id": "ollama-11434", "engine": "ollama", "url": f"http://{STUDIO_IP}:11434"},
                                  {"id": "http-8082", "engine": "mlx-lm", "url": f"http://{STUDIO_IP}:8082"}]}],
         "routes": [{"alias": "ops-agent-30b", "model": "qwen3-coder:30b", "node": "studio", "endpoint": "ollama-11434",
                     "params": {"num_ctx": 16384}},
                    {"alias": "local-medium", "model": "mlx-community/Qwen3.8-27B-4bit", "node": "studio", "endpoint": "http-8082"},
                    {"alias": "local-big", "model": "mlx-community/Qwen2.5-32B-Instruct-4bit", "node": "studio", "endpoint": "http-8082"}]}
    if probe:
        d["probe"] = {"allowedCidrs": LAN, "timeoutSeconds": 1}
    return d


def world_lc():
    return ml.parse(lifecycle_doc()), nm.parse_inventory(inventory_doc())


def ollama_reading(digest):
    return BuildReading(f"http://{STUDIO_IP}:11434", "ollama", {"qwen3-coder:30b": digest.split(":")[-1]}, "Ollama /api/tags digest")


def row_for(rows, alias):
    return next(r for r in rows if r.alias == alias)


class FakeNode:
    """A node on the wire: Ollama's /api/tags, llama-server's /props and /v1/models, in the real shapes."""

    def __init__(self, engines):
        self.engines = engines           # port -> engine
        self.requests = []
        self.digests = {}                # ollama model name -> digest /api/tags reports
        self.model_path = None           # llama-server /props model_path

    def handler(self, req: httpx.Request):
        self.requests.append(req)
        eng, path = self.engines.get(req.url.port), req.url.path
        if eng is None:
            raise httpx.ConnectError("refused", request=req)
        if eng == "ollama" and path == "/api/tags":
            models = [{"name": "qwen3-coder:30b", "size": 18556699604}, {"name": "nomic-embed-text:latest", "size": 274302450}]
            for m in models:
                if m["name"] in self.digests:
                    m["digest"] = self.digests[m["name"]]
            return httpx.Response(200, json={"models": models})
        if eng == "llama-server" and path == "/props":
            return httpx.Response(200, json={"build_info": "b6900-abc", **({"model_path": self.model_path} if self.model_path else {})})
        if eng == "llama-server" and path == "/v1/models":
            return httpx.Response(200, json={"object": "list", "data": [{"id": "Qwen3-Embedding-4B-Q8_0.gguf", "object": "model"}]})
        if eng == "mlx-lm" and path == "/v1/models":
            return httpx.Response(200, json={"object": "list", "data": [{"id": "mlx-community/Qwen3.8-27B-4bit", "object": "model"}]})
        return httpx.Response(404, json={})


def fake_resolver(table):
    def r(host, port, *a, **k):
        if host not in table:
            raise socket.gaierror("no such name")
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0)) for ip in table[host]]
    return r


def builds_prober(node, allowed=LAN):
    return Prober(allowed, timeout=1, transport=httpx.MockTransport(node.handler),
                  resolver=fake_resolver({"studio.lan": [STUDIO_IP]}))


# ------------------------------------------------------------ the comparison (pure)

def test_a_hand_pulled_different_ollama_build_reads_as_drift():
    lc, inv = world_lc()
    rows = ml.build_drift(lc, inv, {("studio", "ollama-11434"): ollama_reading(OLLAMA_NEW)})
    r = row_for(rows, "ops-agent-30b")
    assert r.state == "drift" and r.actual == "b" * 64
    assert ml.drift_findings(rows) == [f"ops-agent-30b on studio serves qwen3-coder:30b build {'b' * 12}, "
                                       f"but the catalog pins {'a' * 12}"]


def test_the_pinned_ollama_build_reads_current_whatever_the_sha256_prefix():
    lc, inv = world_lc()
    rows = ml.build_drift(lc, inv, {("studio", "ollama-11434"): ollama_reading(OLLAMA_OLD)})   # node omits "sha256:"
    assert row_for(rows, "ops-agent-30b").state == "current" and ml.drift_findings(rows) == []


def test_a_short_pin_matches_the_full_digest():
    assert ml.same_build("sha256:aaaaaaa", "a" * 64) and not ml.same_build("aaaaaab", "a" * 64)
    assert not ml.same_build("", "a" * 64) and not ml.same_build("a" * 64, "") and not ml.same_build("PENDING", "PENDING")


def test_an_unread_node_reads_unknown_never_current():
    lc, inv = world_lc()
    rows = ml.build_drift(lc, inv, {})
    assert rows and all(r.state == "unknown" and r.reason == "not checked yet" for r in rows)
    rows = ml.build_drift(lc, inv, {("studio", "ollama-11434"): "refused or unreachable"})
    assert row_for(rows, "ops-agent-30b").state == "unknown"
    assert row_for(rows, "ops-agent-30b").reason == "refused or unreachable"


def test_mlx_lm_cannot_say_which_revision_so_the_hf_pin_reads_unknown():
    lc, inv = world_lc()
    got = BuildReading(f"http://{STUDIO_IP}:8082", "mlx-lm", reason="mlx-lm does not report which build it loaded")
    r = row_for(ml.build_drift(lc, inv, {("studio", "http-8082"): got}), "local-medium")
    assert r.state == "unknown" and "does not report" in r.reason


def test_a_model_the_node_does_not_list_reads_unknown():
    lc, inv = world_lc()
    got = BuildReading(f"http://{STUDIO_IP}:11434", "ollama", {"other:7b": "c" * 64}, "Ollama /api/tags digest")
    r = row_for(ml.build_drift(lc, inv, {("studio", "ollama-11434"): got}), "ops-agent-30b")
    assert r.state == "unknown" and "did not list" in r.reason


def test_a_listed_model_without_a_digest_reads_unknown():
    lc, inv = world_lc()
    got = BuildReading(f"http://{STUDIO_IP}:11434", "ollama", {"qwen3-coder:30b": ""}, "Ollama /api/tags digest")
    r = row_for(ml.build_drift(lc, inv, {("studio", "ollama-11434"): got}), "ops-agent-30b")
    assert r.state == "unknown" and "not which build" in r.reason


def test_unpinned_and_retired_models_are_not_compared():
    lc, inv = world_lc()
    models = {r.entry.model for r in ml.build_drift(lc, inv, {})}
    assert "mlx-community/Qwen2.5-32B-Instruct-4bit" not in models          # no pinned revision
    doc = lifecycle_doc()
    doc["catalog"][0]["stage"] = "retired"
    assert "qwen3-coder:30b" not in {r.entry.model for r in ml.build_drift(ml.parse(doc), inv, {})}


# ------------------------------------------------------------ reading the node (rides the probe's fences)

def test_ollama_digest_is_read_from_api_tags():
    node = FakeNode({11434: "ollama"})
    node.digests = {"qwen3-coder:30b": "b" * 64}
    got = builds_prober(node).read_builds("http://studio.lan:11434", "ollama")
    assert got.reason == "" and got.builds["qwen3-coder:30b"] == "b" * 64
    assert got.builds["nomic-embed-text:latest"] == ""                  # listed, no digest: not a build
    assert {(r.method, r.url.path) for r in node.requests} == {("GET", "/api/tags")}
    assert {r.url.host for r in node.requests} == {STUDIO_IP}


def test_llama_server_revision_is_read_from_the_snapshot_path():
    node = FakeNode({8090: "llama-server"})
    node.model_path = HF_SNAP.format(SHA_NEW)
    got = builds_prober(node).read_builds(f"http://{STUDIO_IP}:8090", "llama-server")
    assert got.builds == {"Qwen3-Embedding-4B-Q8_0.gguf": SHA_NEW}
    node.model_path = "/models/Qwen3-Embedding-4B-Q8_0.gguf"            # not a Hugging Face cache path
    got = builds_prober(node).read_builds(f"http://{STUDIO_IP}:8090", "llama-server")
    assert got.builds == {"Qwen3-Embedding-4B-Q8_0.gguf": ""}


@pytest.mark.parametrize("url", ["http://10.9.9.9:11434", "http://127.0.0.1:11434", "http://169.254.169.254:11434"])
def test_the_build_read_is_fenced_like_the_probe(url):
    node = FakeNode({11434: "ollama"})
    with pytest.raises(Refused):
        builds_prober(node).read_builds(url, "ollama")
    assert node.requests == []


def test_the_build_read_is_off_when_probing_is_off():
    node = FakeNode({11434: "ollama"})
    with pytest.raises(Refused, match="probing is off"):
        builds_prober(node, allowed=[]).read_builds(f"http://{STUDIO_IP}:11434", "ollama")
    assert node.requests == []


def test_an_engine_that_reports_no_build_is_not_asked():
    node = FakeNode({8082: "mlx-lm"})
    got = builds_prober(node).read_builds(f"http://{STUDIO_IP}:8082", "mlx-lm")
    assert "does not report" in got.reason and node.requests == []


# ------------------------------------------------------------ /models, through the real app

def models_client(tmp_path, node, probe=True, groups=None):
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
    doc["inferenceNodes"] = inventory_doc(probe)
    doc["modelLifecycle"] = lifecycle_doc()
    s = config.parse(doc)
    app = create_app(s, Transports(probe=httpx.MockTransport(node.handler)), notes_path=str(tmp_path / "none.md"))
    c = TestClient(app, follow_redirects=False)
    sess = Sessions(s.session_secret, 3600, s.admin_group, False)
    c.cookies.set(sess.session_cookie, sess.issue("a", "Admin", groups if groups is not None else [s.admin_group]))
    return c, sess.read(c.cookies.get(sess.session_cookie))


def studio_node(digest=OLLAMA_NEW):
    node = FakeNode({11434: "ollama", 8082: "mlx-lm"})
    node.digests = {"qwen3-coder:30b": digest}
    return node


def drift_section(t):
    """The node page's build check, from its heading to the next section."""
    return t.split('id="builds-h"', 1)[1].split('id="hw-h"', 1)[0]


def test_the_node_page_reads_unknown_until_checked_then_shows_drift_as_a_finding(tmp_path):
    node = studio_node()
    c, u = models_client(tmp_path, node)
    t = c.get("/nodes/studio").text
    s = drift_section(t)
    assert "Builds on this node" in t and "Not checked" in s and "Drift" not in s
    assert 'name="next" value="studio"' in s and 'action="/models/builds"' in s
    assert node.requests == []                                     # GET /nodes/<id> never reaches a node
    r = c.post("/models/builds", data={"csrf": u.csrf, "next": "studio"})
    assert r.status_code == 303 and r.headers["location"] == "/nodes/studio#builds-h"
    s = drift_section(c.get("/nodes/studio").text)
    assert "Build drift" in s and f"serves qwen3-coder:30b build {'b' * 12}" in s
    assert "does not report which build it loaded" in s            # the mlx-lm pin reads Unknown, with why
    assert {req.method for req in node.requests} == {"GET"}


def test_the_models_page_shows_the_build_state_briefly_and_links_to_the_node_page(tmp_path):
    node = studio_node()
    c, u = models_client(tmp_path, node)
    t = c.get("/models").text
    assert "Build not checked" in t and 'href="/nodes/studio#builds-h"' in t
    assert "Builds on the nodes" not in t and "Pinned build against the build" not in t     # the table is on the node page
    c.post("/models/builds", data={"csrf": u.csrf})
    t = c.get("/models").text
    assert "Serves another build" in t and "Build unknown" in t          # ops-agent-30b drifted, local-medium reads Unknown
    assert "Pinned build against the build" not in t and 'action="/models/builds"' not in t
    # a drift is an exception: it is on the Needs-you strip, with its action going to the node page
    strip = t.split('id="needs-h"', 1)[1].split("</section>", 1)[0]
    assert "Build drift" in strip and "1 route on" in re.sub(r"<[^>]+>", "", strip) and 'href="/nodes/studio#builds-h"' in strip


def test_the_check_goes_back_to_where_it_was_asked_from(tmp_path):
    node = studio_node()
    c, u = models_client(tmp_path, node)
    assert c.post("/models/builds", data={"csrf": u.csrf, "next": "nope"}).headers["location"] == "/nodes/studio#builds-h"   # the first node with a pin
    assert c.post("/models/builds", data={"csrf": u.csrf, "next": "//evil.example"}).headers["location"] == "/nodes/studio#builds-h"


def test_the_pinned_build_reads_current(tmp_path):
    node = studio_node(OLLAMA_OLD)
    c, u = models_client(tmp_path, node)
    c.post("/models/builds", data={"csrf": u.csrf})
    s = drift_section(c.get("/nodes/studio").text)
    assert "Holds the pinned build" in s and "Build drift" not in s
    t = c.get("/models").text
    assert "Holds the pinned build" in t and "Build drift" not in t        # nothing on the strip either


def test_with_probing_off_the_check_says_so_and_reads_unknown(tmp_path):
    node = studio_node()
    c, u = models_client(tmp_path, node, probe=False)
    s = drift_section(c.get("/nodes/studio").text)
    assert "probing is off" in s and 'action="/models/builds"' not in s
    assert 'action="/models/builds"' not in c.get("/models").text
    c.post("/models/builds", data={"csrf": u.csrf})
    assert node.requests == [] and "Build drift" not in c.get("/models").text and "Build drift" not in drift_section(c.get("/nodes/studio").text)


def test_the_build_check_is_admin_only_and_needs_csrf(tmp_path):
    node = studio_node()
    c, u = models_client(tmp_path, node)
    assert c.post("/models/builds", data={"csrf": "nope"}).status_code == 400
    c2, _ = models_client(tmp_path, node, groups=["tockmox-users"])
    assert c2.post("/models/builds", data={"csrf": u.csrf}).status_code == 403
    assert node.requests == []


def test_an_old_check_does_not_vouch_for_today(tmp_path, monkeypatch):
    node = studio_node(OLLAMA_OLD)
    c, u = models_client(tmp_path, node)
    c.post("/models/builds", data={"csrf": u.csrf})
    from app import build_checks
    later = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=build_checks.MAX_AGE_S + 60)
    monkeypatch.setattr(build_checks, "_now", lambda: later)
    s = drift_section(c.get("/nodes/studio").text)
    assert "Holds the pinned build" not in s and "last checked over" in s
    assert "Holds the pinned build" not in c.get("/models").text

# SPDX-License-Identifier: Apache-2.0
"""TM-0958: every Ollama route the UI proposes carries params.num_ctx.

The chart (charts/tockmox-ai/templates/_inference-nodes.tpl, TM-0957) refuses an Ollama route with no
params.num_ctx, so a block the UI writes must already have one. Run from tockmox-ui/: python -m pytest tests
"""
import html
import json
import re
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import nodes as nm  # noqa: E402
from app import nodes_routes  # noqa: E402
from app.probe import Finding, Model, ProbeResult  # noqa: E402

OLLAMA_LIST = [
    {"model_name": "local-llama", "litellm_params": {"model": "ollama_chat/llama3.1:8b", "api_base": "http://10.0.0.5:11434"}},
    {"model_name": "local-embed", "litellm_params": {"model": "ollama/nomic-embed-text", "api_base": "http://10.0.0.5:11434"}},
]


def _num_ctx_of(inv, engine="ollama"):
    out = {}
    for r in inv.routes:
        n = inv.node(r.node)
        if n.endpoint(r.endpoint).engine == engine:
            out[r.alias] = r.params.get("num_ctx")
    return out


def test_default_params_adds_num_ctx_for_ollama_only():
    assert nm.default_params("ollama") == {"num_ctx": nm.DEFAULT_OLLAMA_NUM_CTX}
    assert nm.default_params("llama-server") == {}
    assert nm.default_params("ollama", {"num_ctx": 32768, "keep_alive": -1}) == {"num_ctx": 32768, "keep_alive": -1}


def test_import_from_gateway_proposes_num_ctx_and_says_so():
    res = nm.import_model_list(OLLAMA_LIST)
    got = _num_ctx_of(res.inventory)
    assert got == {"local-llama": 16384, "local-embed": 16384}
    assert any("num_ctx" in n for n in res.notes)


def test_import_keeps_an_operators_own_num_ctx():
    lst = json.loads(json.dumps(OLLAMA_LIST))
    lst[0]["litellm_params"]["num_ctx"] = 8192
    got = _num_ctx_of(nm.import_model_list(lst).inventory)
    assert got["local-llama"] == 8192


def test_probe_draft_proposes_num_ctx_on_ollama_routes():
    f = Finding(port=11434, engine="ollama", url="http://10.0.0.5:11434", models=[Model("llama3.1:8b", 4.9)])
    res = ProbeResult("10.0.0.5", "10.0.0.5", [f])
    inv = nodes_routes._draft_from_probe(res, "mac-studio" if "mac-studio" in nm.CATALOG else next(iter(nm.CATALOG)),
                                         "studio", "", "", "")
    assert _num_ctx_of(inv) == {"local-llama3.1-8b": 16384}


def test_a_non_ollama_probe_draft_adds_no_num_ctx():
    f = Finding(port=8080, engine="llama-server", url="http://10.0.0.5:8080", models=[Model("qwen.gguf", 4.0)])
    inv = nodes_routes._draft_from_probe(ProbeResult("10.0.0.5", "10.0.0.5", [f]),
                                         next(iter(nm.CATALOG)), "box", "", "", "")
    assert all("num_ctx" not in r.params for r in inv.routes)


# ---- the place-a-model route, through the real app (nodes_routes._placement_preview)

@pytest.fixture
def client(tmp_path):
    from fastapi.testclient import TestClient
    from app import config
    from app.main import create_app
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["inferenceNodes"] = {
        "nodes": [{"id": "studio", "name": "Studio", "type": "apple-silicon-mac", "address": "10.0.0.5",
                   "endpoints": [{"id": "ollama-11434", "engine": "ollama", "url": "http://10.0.0.5:11434"}]}],
        "routes": []}
    s = config.parse(doc)
    app = create_app(s, notes_path=str(tmp_path / "none.md"))
    c = TestClient(app)
    from app.auth import Sessions
    sess = Sessions(s.session_secret, 3600, s.admin_group, False)
    c.cookies.set(sess.session_cookie, sess.issue("a", "Admin", [s.admin_group]))
    return c


def test_placing_a_model_on_an_ollama_endpoint_proposes_num_ctx(client):
    r = client.get("/nodes/studio", params={"model": "llama3.1:8b", "endpoint": "ollama-11434",
                                            "alias": "local-llama", "kind": "chat"})
    assert r.status_code == 200, r.text[:300]
    page = html.unescape(r.text)
    m = re.search(r'name="draft"[^>]*value="([^"]+)"', r.text)
    assert m, "no generated draft in the preview"
    draft = json.loads(html.unescape(m.group(1)))
    assert draft["routes"][0]["params"]["num_ctx"] == 16384
    assert "num_ctx: 16384" in page


# ---- TM-0980 (lab F-L1-11): the UI never writes a size its own parser refuses

def test_a_model_an_engine_lists_at_a_few_bytes_still_makes_an_acceptable_draft():
    """The lab's stub Ollama listed a 123-byte model; the draft carried sizeGiB 0.0 and /nodes/change refused it
    with "sizeGiB must be a positive number", with no field on the probe page to correct. Now the probe's size
    has a 0.1 GiB floor, so the draft round-trips through parse_inventory, which is what /nodes/change runs."""
    from app.probe import _gib
    assert _gib(123) == 0.1 and _gib(45 * 1024 * 1024) == 0.1 and _gib(4.7 * (1 << 30)) == 4.7
    assert _gib(0) is None and _gib("x") is None
    f = Finding(port=11434, engine="ollama", url="http://10.0.0.5:11434", models=[Model("lab-coder:7b", _gib(123))])
    inv = nodes_routes._draft_from_probe(ProbeResult("10.0.0.5", "10.0.0.5", [f]), next(iter(nm.CATALOG)), "box", "", "", "")
    doc = nm.inventory_to_doc(inv)
    assert doc["routes"][0]["sizeGiB"] == 0.1
    back = nm.parse_inventory(doc)          # the same parse /nodes/change applies to the posted draft
    assert back.routes[0].size_gib == 0.1


def test_a_route_whose_size_rounds_to_zero_is_written_without_a_size():
    """Belt to the braces above: a Route built elsewhere with size 0.0 (or an estimate that rounds to it) is written
    with no sizeGiB rather than one the parser refuses."""
    box = nm.Node("box", "Box", next(iter(nm.CATALOG)), "10.0.0.5",
                  [nm.Endpoint("ollama-11434", "ollama", "http://10.0.0.5:11434")], {}, {})
    inv = nm.Inventory([box], [nm.Route("tiny", "box", "ollama-11434", "tiny:latest", "chat", "", {"num_ctx": 16384}, {}, 0.0)])
    doc = nm.inventory_to_doc(inv)
    assert "sizeGiB" not in doc["routes"][0]
    assert nm.parse_inventory(doc).routes[0].size_gib is None
    assert nm.estimate_size_gib("tiny-0.01b-q4") in (None, 0.1)


def test_an_operators_tiny_size_is_floored_not_refused(client):
    r = client.get("/nodes/studio", params={"model": "all-minilm", "endpoint": "ollama-11434",
                                            "alias": "local-minilm", "kind": "embedding", "size": "0.04"})
    assert r.status_code == 200, r.text[:300]
    m = re.search(r'name="draft"[^>]*value="([^"]+)"', r.text)
    assert m, "no generated draft in the preview"
    draft = json.loads(html.unescape(m.group(1)))
    assert draft["routes"][0]["sizeGiB"] == 0.1
    nm.parse_inventory(draft)               # what /nodes/change does with it; must not raise

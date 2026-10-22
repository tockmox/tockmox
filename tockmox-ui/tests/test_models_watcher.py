# SPDX-License-Identifier: Apache-2.0
"""REQ-0048: the watcher reaches only its upstreams, records every failure, and changes nothing."""
import json

import httpx
import pytest

from tests.proto_support import OLLAMA_NEW, SHA_NEW, lifecycle_doc
from app import watcher as wm


class Upstream:
    def __init__(self, fail=()):
        self.reqs, self.fail = [], set(fail)

    def handler(self, req):
        self.reqs.append(req)
        h, p = req.url.host, req.url.path
        if h in self.fail:
            raise httpx.ConnectError("down", request=req)
        if h == "huggingface.co":
            if p == "/api/models/mlx-community/Qwen3.8-27B-4bit":
                return httpx.Response(200, json={"id": "mlx-community/Qwen3.8-27B-4bit", "sha": SHA_NEW, "lastModified": "2026-10-05T00:00:00.000Z"})
            if p == "/api/models" and "base_model" in str(req.url):
                return httpx.Response(200, json=[{"id": "mlx-community/Qwen3.8-27B-8bit"}])
            if p == "/api/models" and "author=Qwen" in str(req.url):
                return httpx.Response(200, json=[{"id": "Qwen/Qwen3.9-27B", "createdAt": "2026-10-06T00:00:00.000Z"}])
        if h == "registry.ollama.ai" and req.method == "HEAD":
            return httpx.Response(200, headers={"ollama-content-digest": OLLAMA_NEW, "ollama-push-time": "2026-10-01"})
        if h == "openrouter.ai":
            return httpx.Response(200, json={"data": [{"id": "anthropic/claude-opus-5.5", "created": 1790000000},
                                                      {"id": "openai/gpt-6", "expiration_date": None}]})
        if h == "api.anthropic.com":
            return httpx.Response(200, json={"data": [{"id": "claude-opus-5-5", "created_at": "2026-09-30T00:00:00Z"}]})
        if h == "evil.example":
            return httpx.Response(200, json={})
        return httpx.Response(404)


def cfg(**providers):
    d = {"modelLifecycle": lifecycle_doc(watch={"enabled": True, "providers": providers or {"openrouter": {"allow": ["anthropic/*"]}}})}
    d["gatewayModelList"] = [{"model_name": "claude-opus-5", "litellm_params": {"model": "anthropic/claude-opus-5"}}]
    return d


def run(up, c=None, env=None):
    return wm.run(c or cfg(), wm.Fetcher(transport=httpx.MockTransport(up.handler)), env=env or {})


def test_finds_every_kind():
    up = Upstream()
    rep = run(up)
    kinds = {c["kind"] for c in rep["candidates"]}
    assert kinds >= {"revision", "quant", "successor", "digest", "frontier"}
    assert all(v["ok"] for v in rep["sources"].values())
    assert {r.url.host for r in up.reqs} <= wm.WATCH_HOSTS
    assert all(r.method in ("GET", "HEAD") for r in up.reqs)


def test_only_watched_hosts():
    f = wm.Fetcher(transport=httpx.MockTransport(Upstream().handler))
    for url in ("https://evil.example/x", "http://huggingface.co/api/models", "https://169.254.169.254/latest"):
        with pytest.raises(wm.Refused):
            f.json(url)


def test_a_failed_upstream_is_recorded_not_silent():
    rep = run(Upstream(fail={"huggingface.co"}))
    assert rep["sources"]["huggingface"]["ok"] is False and "unreachable" in rep["sources"]["huggingface"]["reason"]
    assert rep["sources"]["ollama"]["ok"] is True


def test_provider_key_goes_to_its_provider_only():
    up = Upstream()
    run(up, cfg(anthropic={"keyEnv": "ANTHROPIC_API_KEY"}), env={"ANTHROPIC_API_KEY": "sk-ant-TEST"})
    with_key = [r for r in up.reqs if r.headers.get("x-api-key") == "sk-ant-TEST"]
    assert with_key and all(r.url.host == "api.anthropic.com" for r in with_key)
    assert all("sk-ant-TEST" not in str(r.headers) for r in up.reqs if r.url.host != "api.anthropic.com")


def test_missing_key_is_a_recorded_gap():
    rep = run(Upstream(), cfg(anthropic={}))
    assert rep["sources"]["anthropic"] == {"ok": False, "reason": "no key configured"}


def test_known_hosted_models_are_not_candidates():
    rep = run(Upstream(), cfg(anthropic={}), env={"ANTHROPIC_API_KEY": "k"})
    assert not any(c["model"] == "anthropic/claude-opus-5" for c in rep["candidates"])
    assert any(c["model"] == "anthropic/claude-opus-5-5" for c in rep["candidates"])


def test_off_means_no_request(tmp_path, monkeypatch):
    import socket
    tried = []
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: tried.append(a) or (_ for _ in ()).throw(OSError("blocked")))
    p = tmp_path / "c.yaml"
    p.write_text(json.dumps({"modelLifecycle": lifecycle_doc()}))
    assert wm.main(["w", str(p), str(tmp_path / "r.json")]) == 0
    assert tried == [] and not (tmp_path / "r.json").exists()


def test_report_round_trips_through_the_ui_parser(tmp_path):
    from app import models as ml
    rep = run(Upstream())
    wm.write_atomic(str(tmp_path / "r.json"), rep)
    back = ml.parse_report(json.load(open(tmp_path / "r.json")))
    assert len(back.candidates) == len(rep["candidates"])


def test_quants_are_asked_per_trusted_publisher():
    """Lab finding 2026-10-07: one global query sorted by date returned only other people's fine-tunes."""
    up = Upstream()
    run(up)
    q = [str(r.url) for r in up.reqs if "base_model" in str(r.url)]
    assert q and all("author=" in u and "base_model%3Aquantized%3A" in u.replace(":", "%3A") for u in q)
    assert {u.split("author=")[1].split("&")[0] for u in q} == {"mlx-community", "lmstudio-community", "unsloth", "bartowski"}


def test_quants_without_a_base_model_is_a_gap_not_an_answer():
    # lab finding F13 (2026-10-08): the lab's catalog entry tracked [quants] with no baseModel. The watcher made no
    # request, reported "sources ok: ['huggingface']" and no gap, and the page read the model as current.
    up = Upstream()
    c = cfg()
    c["modelLifecycle"]["catalog"] = [{"id": "lab-c", "model": "mlx-community/Qwen3.8-27B-4bit", "adopted": "2026-10-07",
                                       "source": {"kind": "huggingface", "ref": "mlx-community/Qwen3.8-27B-4bit"},
                                       "track": ["quants"]}]
    c["modelLifecycle"]["watch"]["providers"] = {}
    # Ported with one change: the sizes duty (fit v2) reads every catalogued repo's file sizes, which is a request to
    # huggingface.co by design. This test is about the quants TRACK making none, so the sizes duty is off here.
    c["modelLifecycle"]["watch"]["sizes"] = {"enabled": False}
    rep = run(up, c)
    assert not [r for r in up.reqs if r.url.host == "huggingface.co"]
    assert "huggingface" not in rep["sources"]
    assert any("lab-c: tracks quants but has no baseModel" in g for g in rep["gaps"])


def test_quants_with_a_base_model_still_answers():
    up = Upstream()
    c = cfg()
    c["modelLifecycle"]["catalog"] = [{"id": "lab-c", "model": "mlx-community/Qwen3.8-27B-4bit", "adopted": "2026-10-07",
                                       "baseModel": "Qwen/Qwen3.8-27B",
                                       "source": {"kind": "huggingface", "ref": "mlx-community/Qwen3.8-27B-4bit"},
                                       "track": ["quants"]}]
    c["modelLifecycle"]["watch"]["providers"] = {}
    rep = run(up, c)
    assert [r for r in up.reqs if r.url.host == "huggingface.co"]
    assert rep["sources"]["huggingface"]["ok"] and not rep["gaps"]

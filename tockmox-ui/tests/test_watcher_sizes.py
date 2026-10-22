# SPDX-License-Identifier: Apache-2.0
"""The watcher's sizes duty (AC-48.14): HF `?blobs=true` plus config.json at the pinned revision, inside the same fixed-host,
no-redirect, size-capped client. Recorded fixtures (tests/fixtures/hf); no live network."""
import json
from pathlib import Path

import httpx
import pytest

from tests.models_support import SHA_A
from app import fit as fx
from app import models as ml
from app import watcher as wm

HF = Path(__file__).parent / "fixtures" / "hf"
DENSE, HYBRID, SWA = "Qwen/Qwen3-32B", "Qwen/Qwen3-Next-80B-A3B-Instruct", "openai/gpt-oss-120b"


def fx_json(ref, kind):
    return json.loads((HF / (ref.replace("/", "_") + f".{kind}.json")).read_text())


class HFUpstream:
    """Serves the recorded model answers and configs the way huggingface.co does, including the measured 307 for
    resolve/<sha>/config.json. Everything else is a 404."""

    def __init__(self, hop="same-host", configs=True, refs=(DENSE, HYBRID, SWA)):
        self.reqs, self.hop, self.configs = [], hop, configs
        self.by_ref = {r: fx_json(r, "model") for r in refs}

    def handler(self, req):
        self.reqs.append(req)
        p = req.url.path
        if req.url.host != "huggingface.co":
            return httpx.Response(404)
        for ref, info in self.by_ref.items():
            if p == f"/api/models/{ref}/revision/{info['sha']}" and req.url.params.get("blobs") == "true":
                return httpx.Response(200, json=info)
            if p == f"/api/models/{ref}" and req.url.params.get("blobs") == "true":
                return httpx.Response(200, json=info)
            if p == f"/{ref}/resolve/{info['sha']}/config.json":
                if not self.configs:
                    return httpx.Response(404, json={})
                loc = {"same-host": f"/api/resolve-cache/models/{ref}/{info['sha']}/config.json",
                       "twice": f"/api/resolve-cache/models/{ref}/{info['sha']}/config.json",
                       "cdn": "https://cdn-lfs.example.com/config.json",
                       "other-path": f"/somewhere/else/{ref}.json",
                       "http": f"http://huggingface.co/api/resolve-cache/models/{ref}/{info['sha']}/config.json"}.get(self.hop)
                if loc:
                    return httpx.Response(307, headers={"location": loc})
                return httpx.Response(200, json=fx_json(ref, "config"))
            if p == f"/api/resolve-cache/models/{ref}/{info['sha']}/config.json":
                if self.hop == "twice":
                    return httpx.Response(307, headers={"location": "/api/resolve-cache/models/again"})
                return httpx.Response(200, json=fx_json(ref, "config"))
        return httpx.Response(404)


def fetcher(up):
    return wm.Fetcher(transport=httpx.MockTransport(up.handler))


def lifecycle(refs, revisions=True, **extra):
    cat = []
    for i, ref in enumerate(refs):
        e = {"id": f"m{i}", "model": ref, "adopted": "2026-10-07", "source": {"kind": "huggingface", "ref": ref}}
        if revisions:
            e["source"]["revision"] = fx_json(ref, "model")["sha"]
        cat.append(e)
    return {"catalog": cat, **extra}


def collect(up, refs=(DENSE, HYBRID, SWA), watch=None, recommend=None, revisions=True):
    d = lifecycle(refs, revisions)
    if watch:
        d["watch"] = watch
    if recommend:
        d["recommend"] = recommend
    cfg = {"modelLifecycle": d}
    return wm.collect_sizes(cfg, ml.parse(d), [], fetcher(up), "2026-10-21T00:00:00Z")


# ------------------------------------------------------------ what the watcher asks and what it records

def test_it_reads_file_sizes_at_the_pinned_revision_and_config_json_and_records_exact_figures():
    up = HFUpstream()
    sizes, gaps = collect(up)
    assert gaps == [] and set(sizes) == {DENSE, HYBRID, SWA}
    r, _ = fx.parse_sizes(sizes)
    d = r[DENSE]
    assert d.revision == fx_json(DENSE, "model")["sha"] and d.size_bytes == 65524328560 and d.files_counted == 17
    assert d.kv_bytes_per_token == 262144 and (d.full_attention_layers, d.total_layers) == (64, 64)
    assert d.license == "apache-2.0" and d.format == "safetensors" and d.params_b == 32.0 and not d.moe and d.fetched_at == "2026-10-21T00:00:00Z"
    h = r[HYBRID]
    assert h.moe and h.active_params_b == 3.0 and h.kv_bytes_per_token == 24576 and h.recurrent_state_bytes == 79036416
    s = r[SWA]
    assert s.sliding_window_tokens == 128 and s.sliding_window_bytes == 4718592 and any("sub-folders" in n for n in s.notes)
    paths = [r.url.path + ("?blobs=true" if r.url.params.get("blobs") else "") for r in up.reqs]
    assert f"/api/models/{DENSE}/revision/{d.revision}?blobs=true" in paths and f"/{DENSE}/resolve/{d.revision}/config.json" in paths


def test_every_request_is_a_get_to_the_fixed_host_and_stays_there():
    up = HFUpstream()
    collect(up)
    assert {r.url.host for r in up.reqs} == {"huggingface.co"} and {r.method for r in up.reqs} == {"GET"}
    assert all(r.url.scheme == "https" for r in up.reqs)
    assert "authorization" not in {k.lower() for r in up.reqs for k in r.headers}          # no credential is ever sent


def test_an_unpinned_entry_reads_the_current_build_and_records_its_sha():
    up = HFUpstream()
    sizes, _ = collect(up, refs=(DENSE,), revisions=False)
    assert sizes[DENSE]["revision"] == fx_json(DENSE, "model")["sha"]
    assert [r.url.path for r in up.reqs][0] == f"/api/models/{DENSE}"                      # no revision in the path: the current build


def test_a_config_that_cannot_be_read_keeps_the_weights_and_says_what_is_missing():
    up = HFUpstream(configs=False)
    sizes, gaps = collect(up, refs=(DENSE,))
    r, _ = fx.parse_sizes(sizes)
    assert r[DENSE].size_bytes == 65524328560 and r[DENSE].kv_bytes_per_token is None          # None, never zero
    assert any("config.json not read" in g and "no KV figure" in g for g in gaps)
    assert "kvBytesPerToken" not in sizes[DENSE]


def test_a_repo_that_cannot_be_sized_is_a_gap_not_a_missing_key_that_reads_as_zero():
    sizes, gaps = collect(HFUpstream(refs=()), refs=(DENSE,))
    assert sizes == {} and any("not sized" in g and DENSE in g for g in gaps)


def test_the_cap_bounds_the_run_and_says_what_it_skipped():
    up = HFUpstream()
    sizes, gaps = collect(up, watch={"enabled": True, "sizes": {"maxRepos": 2}})
    assert len(sizes) == 2 and any("1 more repo(s) were not sized: over watch.sizes.maxRepos (2)" in g for g in gaps)


def test_the_duty_can_be_switched_off_and_then_makes_no_request():
    up = HFUpstream()
    assert collect(up, watch={"enabled": True, "sizes": {"enabled": False}}) == ({}, [])
    assert up.reqs == []


def test_retired_and_non_huggingface_entries_are_not_sized_and_seeds_and_candidates_are():
    up = HFUpstream()
    d = lifecycle((DENSE,))
    d["catalog"].append({"id": "gone", "model": HYBRID, "stage": "retired", "source": {"kind": "huggingface", "ref": HYBRID,
                                                                                    "revision": fx_json(HYBRID, "model")["sha"]}})
    d["catalog"].append({"id": "oll", "model": "tiny:1b", "adopted": "2026-10-07", "source": {"kind": "ollama", "ref": "tiny:1b",
                                                                                          "revision": "sha256:" + "a" * 64}})
    d["recommend"] = {"seeds": [{"ref": SWA}]}
    cand = ml.Candidate("c1", "successor", "m0", "Qwen/Qwen3-Next-80B-A3B-Instruct", ml.Source("huggingface", HYBRID, fx_json(HYBRID, "model")["sha"]), "x")
    sizes, _ = wm.collect_sizes({"modelLifecycle": d}, ml.parse(d), [cand], fetcher(up), "t")
    assert set(sizes) == {DENSE, HYBRID, SWA}
    assert not [r for r in up.reqs if "tiny" in r.url.path]
    d["catalog"].pop(0)
    sizes, _ = wm.collect_sizes({"modelLifecycle": d}, ml.parse(d), [], HFUpstream() and fetcher(HFUpstream()), "t")
    assert set(sizes) == {SWA}                                                           # the retired entry is not sized


# ------------------------------------------------------------ the redirect fence

def test_the_one_same_host_cache_hop_is_followed_exactly_once_and_only_where_asked():
    up = HFUpstream()
    f = fetcher(up)
    url = f"https://huggingface.co/{DENSE}/resolve/{fx_json(DENSE, 'model')['sha']}/config.json"
    assert f.json(url, follow_cache_hop=True)["num_hidden_layers"] == 64
    assert [c[1].split("huggingface.co")[1] for c in f.calls][-1].startswith("/api/resolve-cache/")
    with pytest.raises(wm.Refused, match="redirect"):
        fetcher(up).json(url)                                                            # the default never follows


@pytest.mark.parametrize("hop,match", [("cdn", "cdn-lfs.example.com"), ("other-path", "huggingface.co"), ("http", "huggingface.co"),
                                       ("twice", "second redirect")])
def test_any_other_redirect_is_refused_a_cdn_included(hop, match):
    up = HFUpstream(hop=hop)
    url = f"https://huggingface.co/{DENSE}/resolve/{fx_json(DENSE, 'model')['sha']}/config.json"
    with pytest.raises(wm.Refused, match=match):
        fetcher(up).json(url, follow_cache_hop=True)
    assert not [r for r in up.reqs if r.url.host != "huggingface.co"]                    # the other host was never contacted


def test_a_refused_hop_leaves_the_weights_and_records_the_reason():
    sizes, gaps = collect(HFUpstream(hop="cdn"), refs=(DENSE,))
    assert sizes[DENSE]["sizeBytes"] == 65524328560 and any("config.json not read" in g and "redirect" in g for g in gaps)


def test_an_oversize_answer_is_refused_before_it_is_parsed():
    class Big(HFUpstream):
        def handler(self, req):
            if req.url.path.endswith("config.json") or "/api/resolve-cache/" in req.url.path:
                return httpx.Response(200, content=b"[" + b"0," * (wm.MAX_BYTES // 2 + 10) + b"0]")
            return super().handler(req)
    sizes, gaps = collect(Big(), refs=(DENSE,))
    assert any("over the cap" in g for g in gaps) and sizes[DENSE]["sizeBytes"] == 65524328560


# ------------------------------------------------------------ the weights arithmetic

def test_gguf_repos_are_summed_per_quantisation_never_across_them():
    sib = [{"rfilename": "m-Q4_K_M.gguf", "size": 4_000_000_000}, {"rfilename": "m-Q8_0.gguf", "size": 8_000_000_000},
           {"rfilename": "mmproj-m.gguf", "size": 600_000_000}, {"rfilename": "README.md", "size": 10}]
    assert wm.sum_weights(sib, "Q4_K_M")[:3] == (4_000_000_000, 1, "gguf")
    assert wm.sum_weights(sib, "q8_0")[0] == 8_000_000_000
    none, n, fmt, notes = wm.sum_weights(sib, "")
    assert none is None and "weights not summed" in notes[-1]                            # the sum of both is no file anyone loads
    assert wm.sum_weights(sib, "Q5_K_M")[0] is None
    shards = [{"rfilename": f"big-Q4_K_M-0000{i}-of-00003.gguf", "size": 10} for i in (1, 2, 3)]
    assert wm.sum_weights(shards, "Q4_K_M")[:2] == (30, 3)


def test_safetensors_drop_a_consolidated_copy_and_a_missing_size_is_not_zero():
    sib = [{"rfilename": "model-00001-of-00002.safetensors", "size": 5}, {"rfilename": "model-00002-of-00002.safetensors", "size": 6},
           {"rfilename": "consolidated.safetensors", "size": 11}]
    sz, n, fmt, notes = wm.sum_weights(sib)
    assert (sz, n, fmt) == (11, 2, "safetensors") and any("consolidated" in x for x in notes)
    assert wm.sum_weights([{"rfilename": "a.safetensors"}])[0] is None
    assert wm.sum_weights([{"rfilename": "README.md", "size": 1}])[0] is None


def test_lfs_sizes_and_the_mlx_format_tag_are_read():
    info = fx_json(DENSE, "model")
    assert wm.size_record(fetcher(HFUpstream()), DENSE, info["sha"], "", "t")[0].format == "safetensors"

    class Mlx(HFUpstream):
        def handler(self, req):
            r = super().handler(req)
            if req.url.path.startswith("/api/models/"):
                d = json.loads(r.content)
                d["library_name"] = "mlx"
                d["siblings"] = [{"rfilename": "model.safetensors", "lfs": {"size": 123}}]
                return httpx.Response(200, json=d)
            return r
    rec = wm.size_record(fetcher(Mlx()), DENSE, info["sha"], "", "t")[0]
    assert rec.format == "mlx" and rec.size_bytes == 123


# ------------------------------------------------------------ in the report

def test_run_writes_sizes_and_size_gaps_and_the_ui_reads_them_back():
    up = HFUpstream()
    d = lifecycle((DENSE, HYBRID))
    d["watch"] = {"enabled": True, "providers": {}}
    rep = wm.run({"modelLifecycle": d}, fetcher(up), env={})
    assert set(rep["sizes"]) == {DENSE, HYBRID} and rep["sizeGaps"] == []
    parsed = ml.parse_report(json.loads(json.dumps(rep)))
    assert parsed.sizes[DENSE].kv_bytes_per_token == 262144 and parsed.size_gaps == []
    assert not [g for g in parsed.gaps if "sized" in g or "config.json" in g]                 # a sizing failure must not turn the report amber


def test_a_malformed_sizes_section_is_dropped_with_a_reason_not_trusted():
    good = {"revision": SHA_A, "sizeBytes": 10, "filesCounted": 1}
    sizes, bad = fx.parse_sizes({"a/b": good, "not a repo": good, "c/d": "str", "e/f": {"sizeBytes": -5, "kvBytesPerToken": "big"}})
    assert set(sizes) == {"a/b", "e/f"} and len(bad) == 2
    assert sizes["e/f"].size_bytes is None and sizes["e/f"].kv_bytes_per_token is None
    assert fx.parse_sizes(None) == ({}, []) and fx.parse_sizes([1]) == ({}, [])
    rep = ml.parse_report({"schema": 1, "sizes": {"x": {}}, "sizeGaps": ["one"]})
    assert rep.sizes == {} and any("not a repo id" in g for g in rep.size_gaps) and "one" in rep.size_gaps

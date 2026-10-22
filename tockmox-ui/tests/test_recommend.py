# SPDX-License-Identifier: Apache-2.0
"""AC-48.14, the Recommend tab. A hypothesis generator: per alias class a shortlist ranked by fit then predicted decode speed,
with licence and known-issue flags, and a button that renders the existing propose / propose_new / propose_replacement change.
It never admits anything and writes nothing."""
import datetime
import json
import os
from pathlib import Path

import pytest

from tests.models_support import SHA_A, inventory_doc, lifecycle_doc, models_client, result_text, world
from app import fit as fx
from app import models as ml
from app import nodes as nm
from app import recommend as rc
from app import results as rs

HF = Path(__file__).parent / "fixtures" / "hf"
DENSE, HYBRID, SWA = "Qwen/Qwen3-32B", "Qwen/Qwen3-Next-80B-A3B-Instruct", "openai/gpt-oss-120b"
GIB = 1 << 30


def info(ref):
    return json.loads((HF / (ref.replace("/", "_") + ".model.json")).read_text())


def record(ref, **over):
    from app import watcher as wm
    i = info(ref)
    size, n, fmt, _ = wm.sum_weights(i["siblings"])
    kv = fx.kv_from_config(json.loads((HF / (ref.replace("/", "_") + ".config.json")).read_text()))
    total, active = fx.params_from_name(ref)
    d = dict(ref=ref, revision=i["sha"], size_bytes=size, files_counted=n, kv_bytes_per_token=kv.get("kv_bytes_per_token"),
             full_attention_layers=kv.get("full_attention_layers"), total_layers=kv.get("total_layers"),
             recurrent_state_bytes=kv.get("recurrent_state_bytes"), sliding_window_bytes=kv.get("sliding_window_bytes"),
             sliding_window_tokens=kv.get("sliding_window_tokens"), params_b=total, active_params_b=active, moe=bool(kv.get("moe")),
             license="apache-2.0", pipeline_tag="text-generation", format=fmt)
    d.update(over)
    return fx.SizeRecord(**d)


def synthetic(ref, gib, params_b, **over):
    d = dict(ref=ref, revision="a" * 40, size_bytes=int(gib * GIB), files_counted=4, kv_bytes_per_token=65536, full_attention_layers=32,
             total_layers=32, params_b=params_b, license="apache-2.0", pipeline_tag="text-generation", format="safetensors")
    d.update(over)
    return fx.SizeRecord(**d)


def report_doc(records=(), candidates=()):
    return {"schema": 1, "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "sources": {"huggingface": {"ok": True}}, "candidates": list(candidates), "sizes": {r.ref: r.as_dict() for r in records}}


def seeds(*recs):
    return [{"ref": r.ref, "revision": r.revision} for r in recs]


def setup(records, cfg_raw=None, inv=None, lc_doc=None, results=(), facts=None, node="alpha"):
    lc = ml.parse(lc_doc or lifecycle_doc())
    inv = nm.parse_inventory(inv or inventory_doc())
    raw = {"seeds": seeds(*records), **(cfg_raw or {})}
    cfg = rc.parse_config(raw)
    rep = ml.parse_report(report_doc(records))
    return rc.recommend(node, lc, inv, rep, cfg, results, facts), lc, inv, cfg, rep


def rows(rec, cls):
    return next(c for c in rec.classes if c.spec.name == cls).rows


def by_model(rec, cls, model):
    return next(r for r in rows(rec, cls) if r.option.model == model)


# ------------------------------------------------------------ configuration

def test_defaults_are_the_eight_classes_the_ladder_names_and_a_narrow_licence_list():
    cfg = rc.parse_config(None)
    assert list(cfg.classes) == ["router", "fast", "classify", "agent", "medium", "large", "embed", "rerank"]
    assert cfg.licence_allow == ("apache-2.0", "mit") and cfg.exceptions == {} and cfg.shortlist == 4
    assert (cfg.classes["agent"].context, cfg.classes["agent"].slots, cfg.classes["agent"].tools) == (65536, 4, True)
    assert (cfg.classes["embed"].kind, cfg.classes["rerank"].kind) == ("embedding", "rerank")
    assert any(i["id"] == "mlx-lm-4bit-moe-tool-calls" for i in cfg.issues)


def test_no_licence_exception_is_a_default_and_the_flash_next_case_is_site_data():
    assert rc.parse_config({}).exceptions == {}
    cfg = rc.parse_config({"licenceExceptions": [{"model": "example-org/Flash-Next", "reason": "reviewed 2026-10; weights licence allows our use"}]})
    assert cfg.exceptions == {"example-org/Flash-Next": "reviewed 2026-10; weights licence allows our use"}
    src = (Path(__file__).parent.parent / "app" / "recommend.py").read_text().lower()
    assert "flash" not in src                                                       # not in code, not in defaults


def test_a_site_redefines_adds_and_removes_classes():
    cfg = rc.parse_config({"classes": {"agent": {"context": 131072}, "vision": {"kind": "chat", "context": 4096, "slots": 1, "params": [7, 40]},
                                       "rerank": None}})
    assert cfg.classes["agent"].context == 131072 and cfg.classes["agent"].slots == 4          # a partial override keeps the rest
    assert "vision" in cfg.classes and "rerank" not in cfg.classes


@pytest.mark.parametrize("bad,match", [
    ({"nope": 1}, "unknown key"), ("text", "must be a mapping"), ({"classes": {"Bad Name": {}}}, "not a class slug"),
    ({"classes": {"agent": {"kind": "image"}}}, "kind"), ({"classes": {"agent": {"params": [1]}}}, "params"),
    ({"classes": {"agent": {"context": 10}}}, "context"), ({"classes": {"agent": {"slots": 0}}}, "slots"),
    ({"licenceAllow": "mit"}, "licenceAllow"), ({"licenceExceptions": [{"model": "a/b"}]}, "a decision on record"),
    ({"licenceExceptions": [{"model": "a/b", "reason": " "}]}, "a decision on record"),
    ({"knownIssues": [{"text": "t", "severity": "loud"}]}, "severity"), ({"knownIssues": [{"text": "t", "match": {"model": "("}}]}, "bad model pattern"),
    ({"benchmarkHints": [{"match": "(", "text": "t"}]}, "bad pattern"), ({"seeds": [{"ref": "not a repo"}]}, "Hugging Face repo id"),
    ({"seeds": [{"ref": "a/b", "revision": "main"}]}, "40-character commit"), ({"shortlistSize": 0}, "shortlistSize"),
])
def test_a_misspelt_or_unsafe_setting_is_refused_naming_the_key(bad, match):
    with pytest.raises(ml.LifecycleError, match=match):
        rc.parse_config(bad)


# ------------------------------------------------------------ the shortlist

def test_each_class_gets_models_in_its_size_band_and_kind():
    rec, *_ = setup([record(DENSE), record(HYBRID), record(SWA)])
    assert {r.option.model for r in rows(rec, "agent")} == {DENSE, "example-org/Example-27B-4bit"}      # 14 to 70B, catalog included
    assert {r.option.model for r in rows(rec, "large")} == {HYBRID, SWA}            # 70B and up
    assert rows(rec, "router") == [] and rows(rec, "rerank") == []
    assert [r.option.model for r in rows(rec, "embed")] == ["example-embed-4b-q8"]  # the catalog's embedding model, by kind
    assert next(c for c in rec.classes if c.spec.name == "agent").considered >= 3


def test_ranking_is_licence_then_fit_then_predicted_speed_then_size():
    a = synthetic("o/Alpha-30B", 18, 30)                       # fits, slower
    b = synthetic("o/Bravo-30B", 12, 30)                       # fits, faster (fewer bytes per token)
    c = synthetic("o/Charlie-30B", 400, 30)                    # over
    d = synthetic("o/Delta-30B", 8, 30, license="cc-by-nc-4.0")  # fastest, but outside the allow list
    rec, *_ = setup([a, b, c, d])
    order = [r.option.model for r in rows(rec, "agent")]
    own = [m for m in order if m.startswith("o/")]
    assert own[:2] == ["o/Bravo-30B", "o/Alpha-30B"]                       # licence-compliant and fitting, faster first
    assert own.index("o/Delta-30B") > own.index("o/Alpha-30B")            # fastest, but outside the licence list: after every compliant row
    assert own.index("o/Charlie-30B") > own.index("o/Alpha-30B") and by_model(rec, "agent", "o/Charlie-30B").fit.state == "over"
    tps = [by_model(rec, "agent", m).tps for m in ("o/Bravo-30B", "o/Alpha-30B")]
    assert tps[0] > tps[1] > 0


def test_the_shortlist_is_capped_and_the_cap_is_configurable():
    recs = [synthetic(f"o/Model{i}-30B", 10 + i, 30) for i in range(8)]
    assert len(rows(setup(recs)[0], "agent")) == 4
    assert len(rows(setup(recs, {"shortlistSize": 2})[0], "agent")) == 2
    assert len(rows(setup(recs, {"shortlistSize": 8})[0], "agent")) == 8


def test_every_row_carries_the_arithmetic_and_labels_a_speed_as_predicted():
    rec, *_ = setup([record(DENSE)])
    r = by_model(rec, "agent", DENSE)
    assert r.fit.state == "fits" and r.fit.provenance == "exact" and r.fit.footprint.kv_known
    assert any("KiB/token x 65,536 tokens" in l for l in r.fit.lines) and any("x 4 slots" in l for l in r.fit.lines)
    assert r.tps and "GB/s x 0.7" in r.tps_how and rec.bandwidth_gbps == 1228.0 and rec.bandwidth_from == "preset"
    assert rec.usable.provenance == "preset" and rec.constants["eta_dense"] == fx.ETA_DENSE


def test_fit_is_judged_beside_what_is_already_routed_on_the_node():
    rec_alpha, *_ = setup([record(DENSE)])
    rec_beta, *_ = setup([record(DENSE)], node="beta")
    a, b = by_model(rec_alpha, "agent", DENSE), by_model(rec_beta, "agent", DENSE)
    assert a.fit.beside_gib == 0.0 and b.fit.beside_gib > 15                         # beta already serves a 15 GiB model and a 4 GiB one
    assert b.fit.state == "over" and not b.admissible and "does not fit" in b.why_not
    assert "already routed there" in b.fit.lines[-1]


def test_a_measured_peak_replaces_the_arithmetic_when_it_covers_the_plan():
    res = rs.parse(result_text(node="alpha", model=DENSE, memory={"peak_resident_gib": 90.0, "context_tokens": 65536, "parallel_slots": 4}),
                   "evals/results/alpha/x.json")
    rec, *_ = setup([record(DENSE)], results=[res])
    r = by_model(rec, "agent", DENSE)
    assert r.fit.provenance == "measured" and r.fit.footprint.total_gib == 90.0


def test_the_nodes_measured_wired_limit_replaces_the_planning_fraction():
    rec, *_ = setup([record(DENSE)], facts={"wired_limit_mib": 100 * 1024})
    assert rec.usable.provenance == "measured" and rec.usable.gib == 100.0
    rec, *_ = setup([record(DENSE)], {"nodes": {"alpha": {"wiredLimitGiB": 120, "bandwidthGBps": 800}}})
    assert rec.usable.provenance == "operator" and rec.usable.gib == 120.0 and (rec.bandwidth_gbps, rec.bandwidth_from) == (800.0, "operator")


def test_without_a_sizes_section_everything_is_an_estimate_and_the_page_says_so():
    lc, inv = world()
    cfg = rc.parse_config({"seeds": [{"ref": "o/Unsized-30B"}]})
    rec = rc.recommend("alpha", lc, nm.parse_inventory(inventory_doc()), None, cfg)
    assert any("no sizes section" in n for n in rec.notes)
    assert rec.classes and rec.stack_state in ("unknown", "fits", "tight", "over")


def test_a_moe_with_no_active_parameter_count_gets_no_speed_instead_of_a_wrong_one():
    mystery = synthetic("o/Mystery-90B", 50, 90, moe=True)
    rec, *_ = setup([mystery])
    r = by_model(rec, "large", "o/Mystery-90B")
    assert r.tps is None and "no active-parameter figure" in r.tps_how
    assert any("mixture of experts" in f.text for f in r.flags)


# ------------------------------------------------------------ flags

def test_licence_outside_the_allow_list_or_unknown_is_flagged_and_cannot_be_admitted():
    odd = synthetic("o/Odd-30B", 18, 30, license="cc-by-nc-4.0")
    blank = synthetic("o/Blank-30B", 18, 30, license="")
    rec, *_ = setup([odd, blank, record(DENSE)])
    o, b, ok = (by_model(rec, "agent", m) for m in ("o/Odd-30B", "o/Blank-30B", DENSE))
    assert not o.admissible and "not on this site's allow list" in o.why_not and "licenceExceptions" in o.why_not
    assert not b.admissible and "licence unknown" in b.why_not
    assert ok.admissible and ok.flags[0].kind == "licence" and ok.flags[0].severity == "info"
    assert o.flags[0].severity == "warn"


def test_a_site_exception_admits_it_and_still_flags_it_with_the_reason():
    odd = synthetic("o/Odd-30B", 18, 30, license="other")
    rec, *_ = setup([odd], {"licenceExceptions": [{"model": "o/Odd-30B", "reason": "legal reviewed on 2026-10-01"}]})
    r = by_model(rec, "agent", "o/Odd-30B")
    assert r.admissible and r.flags[0].severity == "warn" and "site exception: legal reviewed on 2026-10-01" in r.flags[0].text


def test_the_licence_allow_list_is_configurable():
    odd = synthetic("o/Odd-30B", 18, 30, license="llama3.3")
    assert not by_model(setup([odd])[0], "agent", "o/Odd-30B").admissible
    assert by_model(setup([odd], {"licenceAllow": ["apache-2.0", "llama3.3"]})[0], "agent", "o/Odd-30B").admissible


def four_bit_moe(ref="o/Example-80B-A3B-4bit"):
    return synthetic(ref, 42, 80, moe=True, active_params_b=3.0, format="mlx")


def test_the_4bit_moe_tool_call_drift_flag_is_data_and_fires_only_where_it_applies():
    rec, *_ = setup([four_bit_moe()])
    assert not [f for f in by_model(rec, "large", "o/Example-80B-A3B-4bit").flags if f.kind == "issue"]      # large: not a tool class
    flags = lambda rec: [f for f in by_model(rec, "agent", "o/Example-80B-A3B-4bit").flags if f.kind == "issue"]  # noqa: E731
    rec, *_ = setup([four_bit_moe()], {"classes": {"agent": {"params": [14, 100]}}})
    assert len(flags(rec)) == 1 and "tool calls" in flags(rec)[0].text and flags(rec)[0].severity == "warn"
    eight = four_bit_moe("o/Example-80B-A3B-8bit")
    rec, *_ = setup([eight], {"classes": {"agent": {"params": [14, 100]}}})
    assert not [f for f in by_model(rec, "agent", "o/Example-80B-A3B-8bit").flags if f.kind == "issue"]
    rec, *_ = setup([four_bit_moe()], {"classes": {"agent": {"params": [14, 100]}}, "knownIssues": []})
    assert flags(rec) == []                                                        # a site can empty the list
    rec, *_ = setup([four_bit_moe()], {"classes": {"agent": {"params": [14, 100]}},
                                        "knownIssues": [{"id": "x", "severity": "hint", "text": "site note", "match": {"model": "(?i)example"}}]})
    assert [f.text for f in flags(rec)] == ["site note"] and flags(rec)[0].severity == "hint"


def test_public_benchmark_figures_are_hints_and_the_page_labels_them_so():
    r = record(DENSE, eval_results=({"name": "accuracy", "value": "81.2", "dataset": "ExampleBench"},))
    rec, *_ = setup([r], {"benchmarkHints": [{"match": "Qwen3", "text": "tops a public leaderboard for tool use", "source": "example.com/board"}]})
    hints = by_model(rec, "agent", DENSE).hints
    assert any("tops a public leaderboard for tool use (example.com/board)" in h for h in hints)
    assert any("self-reported on the model card: accuracy 81.2 on ExampleBench" in h for h in hints)


# ------------------------------------------------------------ what a button does

def test_a_new_class_alias_is_admitted_as_a_new_alias_with_absolute_bars():
    rec, lc, inv, cfg, rep = setup([record(DENSE)])
    r = by_model(rec, "agent", DENSE)
    assert (r.action, r.alias, r.admissible) == ("new", "local-agent", True)
    spec = next(c.spec for c in rec.classes if c.spec.name == "agent")
    add_lc, add_inv, notes = rc.build_change("new", r.alias, r.option, "alpha", r.endpoints[0][0], spec, lc, inv)
    (e,) = add_lc.catalog
    assert (e.model, e.stage, e.source.revision) == (DENSE, "candidate", info(DENSE)["sha"])
    (route,) = add_inv.routes
    assert (route.alias, route.node) == ("local-agent-next", "alpha") and route.model_info["max_input_tokens"] == 65536
    assert any("absolute bars" in n for n in notes)
    new_lc = ml.merge(lc, add_lc)
    new_inv = nm.merge(inv, add_inv)
    assert ml.check_promotions(new_lc, new_inv) == []


def test_a_class_with_a_live_alias_compares_against_it_and_sets_the_context_limit():
    cand = synthetic("o/Better-27B", 15, 27, format="mlx")
    rec, lc, inv, cfg, rep = setup([cand])
    r = by_model(rec, "medium", "o/Better-27B")
    assert (r.action, r.alias) == ("compare", "local-medium") and r.admissible
    spec = next(c.spec for c in rec.classes if c.spec.name == "medium")
    ep = next(e for e, g in r.endpoints if g == "mlx-lm")
    add_lc, add_inv, notes = rc.build_change("compare", r.alias, r.option, "alpha", ep, spec, lc, inv)
    (route,) = add_inv.routes
    assert route.alias == "local-medium-next" and route.node == "alpha" and route.model == "o/Better-27B"
    assert route.model_info["max_input_tokens"] == 32768
    assert any("compared against example-org/Example-27B-4bit" in n for n in notes)
    assert ml.check_promotions(ml.merge(lc, add_lc), nm.merge(inv, add_inv)) == []


def test_the_same_model_on_another_node_is_offered_as_a_replacement_and_the_incumbent_has_no_button():
    rec, lc, inv, cfg, rep = setup([], node="alpha")
    r = by_model(rec, "medium", "example-org/Example-27B-4bit")
    assert (r.action, r.admissible) == ("replace", True) and r.in_service == "beta"
    spec = next(c.spec for c in rec.classes if c.spec.name == "medium")
    add_lc, add_inv, notes = rc.build_change("replace", "local-medium", r.option, "alpha", r.endpoints[0][0], spec, lc, inv)
    assert add_lc.catalog == [] and add_inv.routes[0].alias == "local-medium-next" and any("class perf" in n for n in notes)
    rec_b, *_ = setup([], node="beta")
    inc = by_model(rec_b, "medium", "example-org/Example-27B-4bit")
    assert inc.action == "incumbent" and not inc.admissible and "already serves local-medium on Beta" in inc.why_not


def test_a_comparison_already_running_for_the_alias_is_not_offered_again():
    inv = inventory_doc()
    inv["routes"].append({"alias": "local-medium-next", "model": "o/Other-27B", "node": "alpha", "endpoint": "mlx-lm-8080", "sizeGiB": 15})
    rec, *_ = setup([synthetic("o/Better-27B", 15, 27, format="mlx")], inv=inv)
    r = by_model(rec, "medium", "o/Better-27B")
    assert r.action == "none" and not r.admissible and "already a comparison in progress" in r.why_not


def test_an_unpinned_or_uncatalogued_incumbent_cannot_be_admitted():
    unpinned = synthetic("o/Floating-30B", 18, 30, revision="")
    rec, *_ = setup([unpinned])
    r = by_model(rec, "agent", "o/Floating-30B")
    assert not r.admissible and "no pinned revision" in r.why_not
    lc = lifecycle_doc()
    lc["catalog"] = lc["catalog"][1:]                                              # local-medium now serves an uncatalogued model
    rec, *_ = setup([synthetic("o/Better-27B", 15, 27, format="mlx")], lc_doc=lc)
    r = by_model(rec, "medium", "o/Better-27B")
    assert not r.admissible and "not in the catalog" in r.why_not


def test_a_format_the_nodes_engines_cannot_load_is_not_offered_for_admission():
    gguf = synthetic("o/Plain-30B-GGUF", 18, 30, format="gguf")
    inv = inventory_doc()
    inv["nodes"][0]["endpoints"] = [e for e in inv["nodes"][0]["endpoints"] if e["engine"] == "mlx-lm"]
    rec, *_ = setup([gguf], inv=inv)
    r = by_model(rec, "agent", "o/Plain-30B-GGUF")
    assert r.endpoints == [] and not r.admissible and "no endpoint on Alpha can serve" in r.why_not


def test_build_change_refuses_nothing_to_admit_and_a_bad_endpoint():
    rec, lc, inv, cfg, rep = setup([record(DENSE)])
    r = by_model(rec, "agent", DENSE)
    spec = next(c.spec for c in rec.classes if c.spec.name == "agent")
    with pytest.raises(ml.LifecycleError, match="nothing to admit"):
        rc.build_change("none", "local-agent", r.option, "alpha", "mlx-lm-8080", spec, lc, inv)
    with pytest.raises(ml.LifecycleError, match="no endpoint"):
        rc.build_change("new", "local-agent", r.option, "alpha", "nope", spec, lc, inv)


def test_an_unknown_node_is_an_error_not_an_empty_page():
    with pytest.raises(ml.LifecycleError, match="no node"):
        setup([], node="nowhere")


def test_the_cumulative_line_adds_the_first_choice_of_each_class():
    rec, *_ = setup([record(DENSE), record(HYBRID)])
    assert rec.stack_gib and rec.stack_state in ("fits", "tight", "over") and "against 192.0 GiB usable" in rec.stack_line
    assert "agent" in rec.stack_line and "large" in rec.stack_line


# ------------------------------------------------------------ the page: read only, admin only, nothing written

def client_with(tmp_path, records, recommend=None, results=False, **kw):
    rep = tmp_path / "report.json"
    rep.write_text(json.dumps(report_doc(records)))
    extra = {"reportFile": str(rep), "recommend": {"seeds": seeds(*records), **(recommend or {})}}
    if results:
        d = tmp_path / "evals" / "results" / "alpha"
        d.mkdir(parents=True)
        (d / "x.json").write_text(result_text(node="alpha", model=DENSE, environment={"macos": "26.2"},
                                              memory={"peak_resident_gib": 61.0, "context_tokens": 65536, "parallel_slots": 4}))
        extra["resultsDir"] = str(tmp_path / "evals" / "results")
    return models_client(tmp_path, lifecycle=lifecycle_doc(**extra), **kw)


def tree(path):
    return sorted(str(p.relative_to(path)) for p in Path(path).rglob("*"))


def test_the_page_lists_classes_candidates_flags_and_the_anti_claim(tmp_path):
    c, u = client_with(tmp_path, [record(DENSE), synthetic("o/Odd-30B", 18, 30, license="cc-by-nc-4.0")])
    r = c.get("/models/recommend?node=alpha")
    assert r.status_code == 200
    t = r.text
    assert "Tockmox does not pick your models" in t and "proposes candidates and makes the evaluation and the change easy to review" in t
    for cls in ("router", "fast", "classify", "agent", "medium", "large", "embed", "rerank"):
        assert f'id="k-{cls}-h"' in t
    assert DENSE in t and "Fit: fits" in t and "predicted" in t and "The arithmetic" in t
    assert "Not offered for admission" in t and "cc-by-nc-4.0" in t
    assert t.count("Admit for evaluation") >= 1 and 'action="/models/recommend/admit"' in t


def test_viewing_the_page_writes_nothing_and_changes_nothing(tmp_path):
    c, u = client_with(tmp_path, [record(DENSE)])
    before = tree(tmp_path)
    for _ in range(2):
        assert c.get("/models/recommend?node=alpha").status_code == 200
    assert tree(tmp_path) == before
    assert c.get("/models").text.count("/models/recommend?node=") >= 2                 # linked from the Models page, one per node


def test_the_page_is_admin_only_and_unknown_nodes_are_a_404(tmp_path):
    c, u = client_with(tmp_path, [record(DENSE)])
    assert c.get("/models/recommend?node=nowhere").status_code == 404
    assert c.get("/models/recommend", follow_redirects=False).headers["location"] == "/models/recommend?node=alpha"
    (tmp_path / "u").mkdir()
    cu, uu = client_with(tmp_path / "u", [record(DENSE)], groups=[])
    assert cu.get("/models/recommend?node=alpha").status_code == 403
    assert cu.post("/models/recommend/admit", data={"csrf": uu.csrf, "node": "alpha", "cls": "agent", "model": DENSE}).status_code == 403


def test_admit_needs_the_csrf_token_and_renders_a_change_without_writing(tmp_path):
    c, u = client_with(tmp_path, [record(DENSE)])
    data = {"node": "alpha", "cls": "agent", "model": DENSE, "endpoint": "mlx-lm-8080"}
    assert c.post("/models/recommend/admit", data={**data, "csrf": "wrong"}).status_code == 400
    before = tree(tmp_path)
    r = c.post("/models/recommend/admit", data={**data, "csrf": u.csrf})
    assert r.status_code == 200 and "Nothing has changed yet" in r.text
    assert "local-agent-next" in r.text and info(DENSE)["sha"] in r.text and 'action="/models/recommend/admit"' in r.text
    assert "this came from the Recommend list" in r.text
    assert tree(tmp_path) == before
    y = c.post("/models/recommend/admit", data={**data, "csrf": u.csrf, "fmt": "yaml"})
    assert y.headers["content-type"].startswith("application/yaml") and "local-agent-next" in y.text
    assert "recommend:" in y.text                                                      # the operator's own settings are carried through


def test_admit_takes_the_action_from_the_server_not_from_the_form(tmp_path):
    c, u = client_with(tmp_path, [record(DENSE), synthetic("o/Odd-30B", 18, 30, license="cc-by-nc-4.0")])
    base = {"csrf": u.csrf, "node": "alpha", "cls": "agent", "endpoint": "mlx-lm-8080"}
    r = c.post("/models/recommend/admit", data={**base, "model": "o/Odd-30B", "action": "replace", "alias": "local-medium"})
    assert r.status_code == 400 and "cannot be admitted" in r.text and "allow list" in r.text           # tampered fields change nothing
    assert c.post("/models/recommend/admit", data={**base, "model": "o/Not-On-The-List-30B"}).status_code == 404
    assert c.post("/models/recommend/admit", data={**base, "model": DENSE, "cls": "nonexistent"}).status_code == 404
    assert c.post("/models/recommend/admit", data={**base, "model": DENSE, "endpoint": "ollama-11434"}).status_code in (200, 400)
    assert c.post("/models/recommend/admit", data={**base, "model": DENSE, "endpoint": "nope"}).status_code == 400
    assert c.post("/models/recommend/admit", data={**base, "model": DENSE, "node": "nowhere"}).status_code == 404


def test_the_page_reads_measured_results_and_labels_them(tmp_path):
    c, u = client_with(tmp_path, [record(DENSE)], results=True)
    t = c.get("/models/recommend?node=alpha").text
    assert "measured peak 61.0 GiB at 65,536 tokens x 4 slots" in t and "mlx-lm 0.32.2" in t


def test_a_bad_recommend_block_is_an_error_page_naming_the_key(tmp_path):
    c, u = client_with(tmp_path, [record(DENSE)], recommend={"shortlistSize": 99})
    r = c.get("/models/recommend?node=alpha")
    assert r.status_code == 400 and "modelLifecycle.recommend.shortlistSize" in r.text


def test_the_page_works_with_no_report_at_all(tmp_path):
    c, u = models_client(tmp_path)
    t = c.get("/models/recommend?node=alpha").text
    assert "no sizes section" in t and "Nothing in the catalog, the watcher" in t


def test_watcher_candidates_join_the_pool_with_their_sizes(tmp_path):
    cand = {"id": "successor:x", "kind": "successor", "subject": "example-27b-4bit", "model": "o/Next-27B-4bit",
            "source": {"kind": "huggingface", "ref": "o/Next-27B-4bit", "revision": "b" * 40}, "detail": "newer"}
    rep = ml.parse_report(report_doc([synthetic("o/Next-27B-4bit", 15, 27, revision="b" * 40, format="mlx")], [cand]))
    rec = rc.recommend("alpha", ml.parse(lifecycle_doc()), nm.parse_inventory(inventory_doc()), rep, rc.parse_config({}))
    r = by_model(rec, "medium", "o/Next-27B-4bit")
    assert r.option.origin == "watcher" and r.fit.provenance == "exact" and (r.action, r.admissible) == ("compare", True)


def test_the_wired_limit_is_read_from_the_newest_result_that_recorded_one_and_the_live_figure_wins():
    def res(date, mib, path):
        env = {"macos": "26.2", "wired_limit_mb": mib} if mib else {"macos": "26.2"}
        return rs.parse(result_text(node="alpha", date=date, model="o/x", environment=env), path)
    results = [res("2026-09-01", 131072, "evals/a.json"), res("2026-10-10", 229376, "evals/b.json"), res("2026-10-20", None, "evals/c.json")]
    assert rc.facts_from_results(results, "alpha") == {"wired_limit_mib": 229376.0, "wired_limit_from": "evals/b.json (2026-10-10)"}
    assert rc.facts_from_results(results, "beta") == {} and rc.facts_from_results([], "alpha") == {}
    rec, *_ = setup([record(DENSE)], results=results)
    assert rec.usable.gib == 224.0 and rec.usable.provenance == "measured" and "read from evals/b.json (2026-10-10)" in rec.usable.line
    rec, *_ = setup([record(DENSE)], results=results, facts={"wired_limit_mib": 100 * 1024})
    assert rec.usable.gib == 100.0 and "read from" not in rec.usable.line


def test_the_page_labels_hints_as_hints(tmp_path):
    r = record(DENSE, eval_results=({"name": "accuracy", "value": "81.2", "dataset": "ExampleBench"},))
    c, u = client_with(tmp_path, [r])
    t = c.get("/models/recommend?node=alpha").text
    assert "Hints, not measurements" in t and "self-reported on the model card: accuracy 81.2 on ExampleBench" in t


def test_text_from_a_model_card_is_escaped_on_the_page(tmp_path):
    hostile = record(DENSE, license="<img src=x onerror=alert(1)>",
                     eval_results=({"name": "<script>alert(1)</script>", "value": "1", "dataset": "\"><svg onload=alert(2)>"},))
    c, u = client_with(tmp_path, [hostile])
    t = c.get("/models/recommend?node=alpha").text
    assert "<script>alert(1)" not in t and "<img src=x" not in t and "<svg onload" not in t
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in t and "&lt;img src=x onerror=alert(1)&gt;" in t

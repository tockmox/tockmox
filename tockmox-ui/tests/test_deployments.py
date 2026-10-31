# SPDX-License-Identifier: Apache-2.0
"""TM-1299: app/deployments.py, the deployment rows (tunings, planned memory) and the node's memory bar.

Run from tockmox-ui/: python -m pytest tests
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import deployments as dp  # noqa: E402
from app import fit as fx  # noqa: E402
from app import models as ml  # noqa: E402
from app import nodes as nm  # noqa: E402
from tests.models_support import SHA_A, lifecycle_doc  # noqa: E402

GIB = 1 << 30


def node_doc(engines=("mlx-lm", "mlx-lm"), memory=256, nid="alpha"):
    eps = [{"id": f"e{i}", "engine": e, "url": f"http://192.0.2.10:{8080 + i}"} for i, e in enumerate(engines)]
    return {"id": nid, "name": nid.title(), "type": "apple-silicon-mac", "address": "192.0.2.10", "endpoints": eps,
            "hardware": {"chip": {"value": "Apple M5 Ultra", "source": "preset"},
                         "memory_gib": {"value": memory, "source": "preset"}}}


def route(alias, ep="e0", model="example-org/Example-27B-4bit", size=15.0, node="alpha", **extra):
    d = {"alias": alias, "node": node, "endpoint": ep, "model": model, **extra}
    if size is not None:
        d["sizeGiB"] = size
    return d


def inv_of(routes, engines=("mlx-lm", "mlx-lm"), memory=256):
    return nm.parse_inventory({"nodes": [node_doc(engines, memory)], "routes": routes})


def rows(routes, **kw):
    inv = inv_of(routes, kw.pop("engines", ("mlx-lm", "mlx-lm")), kw.pop("memory", 256))
    return {d.alias: d for d in dp.deployment_rows(inv, kw.pop("lc", None), kw.pop("fit_inputs", None))}


# ---------------------------------------------------------------- tunings: route, default, unknown

def test_every_field_can_come_from_the_route():
    d = rows([route("local-a", modelInfo={"max_input_tokens": 131072},
                    params={"max_tokens": 16384, "extra_body": {"chat_template_kwargs": {"enable_thinking": True}}})],
             fit_inputs={"slots_by_alias": {"local-a": 4}})["local-a"]
    t = d.tunings
    assert (t.context.value, t.context.source, t.context.text) == (131072, "route", "128K")
    assert (t.slots.value, t.slots.source, t.slots.text) == (4, "route", "4")
    assert (t.max_output.value, t.max_output.source, t.max_output.text) == (16384, "route", "16K")
    assert (t.thinking.value, t.thinking.source, t.thinking.text) == (True, "route", "On")


def test_thinking_false_reads_off_and_ollama_context_comes_from_num_ctx():
    d = rows([route("local-o", ep="e0", model="llama3.1:8b", size=4.9, params={"num_ctx": 32768, "max_completion_tokens": 2048,
                                                                          "extra_body": {"chat_template_kwargs": {"enable_thinking": False}}})],
             engines=("ollama",))["local-o"]
    assert d.tunings.context.value == 32768 and d.tunings.context.source == "route"
    assert d.tunings.max_output.value == 2048 and d.tunings.max_output.source == "route"
    assert d.tunings.thinking.value is False and d.tunings.thinking.text == "Off"


def test_a_value_the_route_does_not_state_shows_the_engines_default_where_the_repo_documents_one():
    d = rows([route("local-a"), route("local-l", ep="e1", model="example-org/Example-27B-Q4")], engines=("mlx-lm", "llama-server"))
    mlx, llama = d["local-a"].tunings, d["local-l"].tunings
    # mlx-lm has no context setting and takes the request's max_tokens: documented, so "default", with the sentence
    assert mlx.context.source == "default" and mlx.context.value is None and mlx.context.text == "engine default"
    assert "no context setting" in mlx.context.note
    assert mlx.max_output.source == "default" and "request" in mlx.max_output.note
    # llama-server's -c 0 is the model's full trained context
    assert llama.context.source == "default" and "full trained context" in llama.context.note
    # thinking: not stated is the model template's own setting; never guessed per model
    assert mlx.thinking.source == "default" and mlx.thinking.value is None and mlx.thinking.text == "engine default"


def test_a_value_nothing_knows_is_unknown_never_invented():
    d = rows([route("local-o", model="llama3.1:8b", size=4.9)], engines=("ollama",))["local-o"]
    t = d.tunings
    for f in (t.context, t.max_output, t.slots):
        assert f.source == "unknown" and f.value is None and f.text == "engine default, not reported"
    # and the same for slots on every engine: Tockmox keeps no per-route slot count
    assert rows([route("local-a")])["local-a"].tunings.slots.source == "unknown"


def test_a_route_value_beats_the_default_and_a_bad_value_is_not_a_route_value():
    d = rows([route("local-a", modelInfo={"max_input_tokens": -5}, params={"max_tokens": 0})])["local-a"]
    assert d.tunings.context.source == "default" and d.tunings.max_output.source == "default"


def test_more_lists_the_other_route_params_without_the_key_the_tags_or_what_is_already_a_column():
    d = rows([route("local-a", params={"api_key": "os.environ/X", "tags": ["open"], "max_tokens": 8, "num_ctx": 4096, "temperature": 0.2,
                                       "extra_body": {"top_k": 20, "chat_template_kwargs": {"enable_thinking": False, "preserve": True}}})])["local-a"]
    assert d.more == {"temperature": 0.2, "extra_body.top_k": 20, "extra_body.chat_template_kwargs.preserve": True}
    assert rows([route("local-b")])["local-b"].more == {}


# ---------------------------------------------------------------- identity: build, gateway, candidate

def test_build_gateway_and_candidate_flag():
    lc = ml.parse(lifecycle_doc())
    d = rows([route("local-a"), route("local-a-next", ep="e1", model="example-org/Example-27B-4bit")], lc=lc)
    assert d["local-a"].build == SHA_A[:7] and d["local-a"].build_full == SHA_A
    assert (d["local-a"].gateway, d["local-a"].is_candidate, d["local-a"].state) == ("production", False, "Live")
    assert (d["local-a-next"].gateway, d["local-a-next"].is_candidate, d["local-a-next"].state) == ("eval", True, "Candidate -next")
    assert d["local-a"].endpoint.engine == "mlx-lm" and d["local-a"].endpoint.port == 8080 and d["local-a"].endpoint.label == "mlx-lm server :8080"
    assert rows([route("local-x", model="example-org/not-catalogued-7B")], lc=lc)["local-x"].build == ""


def test_the_routes_of_one_node_only():
    inv = nm.parse_inventory({"nodes": [node_doc(nid="alpha"), node_doc(nid="beta")],
                              "routes": [route("local-a", node="alpha"), route("local-b", node="beta")]})
    assert [d.alias for d in dp.deployment_rows(inv, node="beta")] == ["local-b"]
    assert [d.alias for d in dp.deployment_rows(inv)] == ["local-a", "local-b"]


# ---------------------------------------------------------------- planned memory is fit's arithmetic

def test_planned_is_fits_own_footprint_for_the_routes_context_and_slots():
    rec = fx.SizeRecord("example-org/Example-27B-4bit", size_bytes=int(15 * GIB), files_counted=3, kv_bytes_per_token=100 * 1024,
                        full_attention_layers=10, total_layers=10)
    fi = {"sizes": {"example-org/Example-27B-4bit": rec}, "slots_by_alias": {"local-a": 3}}
    d = rows([route("local-a", modelInfo={"max_input_tokens": 32768})], fit_inputs=fi)["local-a"]
    expect = fx.footprint(rec, 15.0, fx.Need(32768, 3), note_measured_miss=False)
    assert d.planned_gib == expect.total_gib and d.provenance == "exact"
    assert d.planned_at == "32K x 3 slots"
    # one slot is fit's default when nothing says otherwise, and the cell says what it planned at
    d1 = rows([route("local-a", modelInfo={"max_input_tokens": 32768})], fit_inputs={"sizes": fi["sizes"]})["local-a"]
    assert d1.planned_gib == fx.footprint(rec, 15.0, fx.Need(32768, 1), note_measured_miss=False).total_gib
    assert d1.planned_at == "32K x 1 slot"
    # no context stated: planned at fit's default context, as the Recommend page plans a route that pins none
    assert rows([route("local-b")])["local-b"].planned_at == f"{dp.short_count(fx.Need().context_tokens)} x 1 slot"


def test_the_node_total_agrees_with_the_fit_the_node_page_already_shows():
    """resident models count, only the largest on-demand one counts, two aliases on one model cost one copy."""
    routes = [route("local-a", size=15.0), route("local-a2", size=15.0), route("local-b", ep="e1", model="example-org/B", size=40.0),
              route("local-o1", ep="e2", model="o:1", size=5.0), route("local-o2", ep="e2", model="o:2", size=9.0)]
    inv = inv_of(routes, engines=("mlx-lm", "mlx-lm", "ollama"))
    deps = dp.deployment_rows(inv)
    bar = dp.memory_bar(inv.node("alpha"), deps)
    f = nm.fit(inv.node("alpha"), inv.routes, 0.0)
    v2 = fx.fit_compat(inv.node("alpha"), inv.routes, None, need=fx.Need())
    assert bar.planned_gib == v2.placed_gib == pytest.approx(round((15.0 + 40.0) * 1.1 + 9.0 * 1.1, 1), abs=0.1)
    assert f.placed_gib == pytest.approx(15.0 + 40.0 + 9.0)            # v1 is weights only; v2 adds the overhead
    d = {x.alias: x for x in deps}
    assert d["local-a2"].shares_with == "local-a" and not d["local-a2"].in_bar
    assert d["local-o1"].in_bar is False and "largest" in d["local-o1"].bar_note and d["local-o2"].in_bar


def test_a_size_that_is_unknown_is_listed_and_left_out_of_the_bar_with_a_note():
    d = rows([route("local-a"), route("local-m", ep="e1", model="example-org/mystery-4bit", size=None)])
    assert d["local-m"].size_unknown and d["local-m"].planned_gib is None and not d["local-m"].in_bar
    assert "size unknown" in d["local-m"].bar_note
    inv = inv_of([route("local-a"), route("local-m", ep="e1", model="example-org/mystery-4bit", size=None)])
    bar = dp.memory_bar(inv.node("alpha"), dp.deployment_rows(inv))
    assert [s.alias for s in bar.segments] == ["local-a"]
    assert bar.left_out == [("local-m", "size unknown: not in the bar")]


# ---------------------------------------------------------------- the memory bar

def test_the_bar_totals_pinned_candidate_and_free_in_gib_and_places_the_usable_line():
    inv = inv_of([route("local-a", size=60.0), route("local-b", ep="e1", model="example-org/B", size=20.0),
                  route("local-a-next", ep="e1", model="example-org/C", size=40.0)])
    bar = dp.memory_bar(inv.node("alpha"), dp.deployment_rows(inv))
    assert bar.total_gib == 256
    assert (bar.pinned_gib, bar.candidate_gib, bar.planned_gib) == (88.0, 44.0, 132.0)       # each x 1.1 for engine overhead
    assert bar.free_gib == 124.0
    assert bar.usable.gib == 192.0 and bar.usable.provenance == "preset" and bar.usable_pct == 75.0
    assert [(s.alias, s.kind) for s in bar.segments] == [("local-a", "pinned"), ("local-b", "pinned"), ("local-a-next", "candidate")]
    assert [s.pct for s in bar.segments] == [25.78, 8.59, 17.19] and bar.segments[1].x == 25.78 and bar.segments[2].x == 34.37
    assert not bar.over_usable and not bar.over_total and bar.drawn


def test_the_usable_figure_is_the_measured_wired_limit_then_the_operators_then_the_planning_fraction():
    inv = inv_of([route("local-a", size=100.0)])
    n = inv.node("alpha")
    assert dp.usable_for_node(n, {"operator_usable": {"alpha": 200}}).gib == 200 and dp.usable_for_node(n).gib == 192.0
    bar = dp.memory_bar(n, dp.deployment_rows(inv), fx.Usable(100.0, "operator", "100.0 GiB usable (set by the operator)"))
    assert bar.over_usable and not bar.over_total and bar.usable_pct == pytest.approx(100.0 / 256 * 100, abs=0.01)


def test_a_plan_bigger_than_the_node_widens_the_scale_instead_of_overflowing_the_bar():
    inv = inv_of([route("local-a", size=200.0), route("local-b", ep="e1", model="example-org/B", size=200.0)], memory=256)
    bar = dp.memory_bar(inv.node("alpha"), dp.deployment_rows(inv))
    assert bar.over_total and bar.free_gib == 0.0 and bar.scale_gib == 440.0
    assert sum(s.pct for s in bar.segments) == pytest.approx(100.0, abs=0.05)


def test_a_node_with_no_memory_figure_has_no_bar_but_still_a_total():
    doc = node_doc()
    doc["hardware"] = {}
    inv = nm.parse_inventory({"nodes": [doc], "routes": [route("local-a", size=10.0)]})
    bar = dp.memory_bar(inv.node("alpha"), dp.deployment_rows(inv))
    assert bar.total_gib is None and bar.planned_gib == 11.0 and not bar.drawn and bar.usable.provenance == "unknown"


def test_fit_inputs_take_the_operators_overhead_and_say_when_the_recommend_block_is_not_valid():
    class S:                                  # Settings.lifecycle, as far as the module reads it
        lifecycle = ml.parse(lifecycle_doc())
        raw = {"recommend": {"nodes": {"alpha": {"overhead": {"mlx-lm": 0.2}, "wiredLimitGiB": 200}}}}
    fi = dp.fit_inputs_for(S, None, [])
    assert fi["overhead"] == {"alpha": {"mlx-lm": 0.2}} and fi["operator_usable"] == {"alpha": 200} and fi["notes"] == []
    inv = inv_of([route("local-a", size=10.0)])
    assert dp.deployment_rows(inv, None, fi)[0].planned_gib == 12.0                  # 10 x 1.2
    S.raw = {"recommend": {"bogus": 1}}
    bad = dp.fit_inputs_for(S, None, [])
    assert bad["overhead"] == {} and "not valid" in bad["notes"][0]

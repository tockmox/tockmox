# SPDX-License-Identifier: Apache-2.0
"""REQ-0048 model lifecycle, second pass: the retire bug, re-placement (ruling 6), a brand-new alias with no incumbent,
and the evaluation request for each. Pure functions plus the gate."""
import pytest

from tests.models_support import apply_change, lifecycle_doc, verdict_record, verdicts, world
from app import models as ml
from app import nodes as nm

EMBED = "example-embed-4b-q8"
MOVE = {"from_node": "beta", "to_node": "alpha"}


def with_replacement_next(inv, endpoint="llama-8081"):
    """local-embed (beta) plus local-embed-next: the SAME model on alpha."""
    nxt = nm.Route("local-embed-next", "alpha", endpoint, EMBED, "embedding", "", {}, {}, 4.0)
    return nm.Inventory(inv.nodes, inv.routes + [nxt])


def perf_verdicts(n=1, **kw):
    kw = {"incumbent": EMBED, "klass": "perf", "placement": MOVE, **kw}
    return verdicts(*[verdict_record(EMBED, "local-embed", run=f"r{i}", **kw) for i in range(n)])


# ------------------------------------------------------------ the retire bug (design 3.3 case 3)

def legacy_would_retire(lc, inv, alias_next):
    """The condition promote() used before the fix, copied here so the regression is visible: retire the old model when no
    OTHER live alias routes it. It compared route aliases, not nodes, so a model that is both the old and the new model
    looked like an orphan the moment the alias moved."""
    nxt = next(r for r in inv.routes if r.alias == alias_next)
    alias = alias_next[: -len(ml.NEXT)]
    live = next(r for r in inv.routes if r.alias == alias)
    old = live.model
    still = sorted(r.alias for r in inv.routes if r.model == old and r.alias not in (alias, alias_next) and not r.alias.endswith(ml.NEXT))
    return bool(old and lc.by_model(old) and not still), nxt


def test_the_old_rule_retired_a_model_that_a_replacement_still_serves():
    lc, inv = world()
    would, nxt = legacy_would_retire(lc, with_replacement_next(inv), "local-embed-next")
    assert would, "the pre-fix condition retires the model"
    assert nxt.model == lc.by_model(EMBED).model            # ... which is the very model the new route serves


def test_a_replacement_does_not_retire_the_model_and_the_gate_passes():
    lc, inv = world()
    inv = with_replacement_next(inv)
    new_lc, new_inv, notes = ml.promote("local-embed-next", perf_verdicts(), lc, inv)
    e = new_lc.by_model(EMBED)
    assert e.stage == "promoted"                           # NOT retired
    assert not [n for n in notes if "is marked retired" in n]
    assert ml.check_promotions(new_lc, new_inv) == []      # the gate that refused the pre-fix result is happy
    live = next(r for r in new_inv.routes if r.alias == "local-embed")
    assert (live.node, live.endpoint, live.model) == ("alpha", "llama-8081", EMBED)
    assert not [r for r in new_inv.routes if r.alias.endswith(ml.NEXT)]
    p = e.promotion
    assert p["placement"] == {"from_node": "beta", "to_node": "alpha", "from_endpoint": "llama-8081", "to_endpoint": "llama-8081"}
    assert p["class"] == "perf" and p["required"] == 1 and p["from"] == EMBED
    assert any("same model" in n and "stays promoted" in n for n in notes)


def test_a_different_model_is_still_retired_when_nothing_else_routes_it():
    lc, inv = world()
    inv2 = nm.Inventory(inv.nodes, inv.routes + [nm.Route("local-medium-next", "alpha", "mlx-lm-8080", "example-org/Example-30B-4bit", "chat",
                                                          "", {}, {}, 17.0)])
    d = lifecycle_doc()
    d["catalog"].append({"id": "example-30b", "model": "example-org/Example-30B-4bit", "stage": "candidate",
                         "source": {"kind": "huggingface", "ref": "example-org/Example-30B-4bit", "revision": "4" * 40}})
    lc2 = ml.parse(d)
    vs = verdicts(*[verdict_record("example-org/Example-30B-4bit", "local-medium", run=f"r{i}", incumbent="example-org/Example-27B-4bit")
                    for i in range(3)])
    new_lc, new_inv, notes = ml.promote("local-medium-next", vs, lc2, inv2)
    assert new_lc.by_model("example-org/Example-27B-4bit").stage == "retired"
    assert new_lc.by_model("example-org/Example-30B-4bit").stage == "promoted"
    assert ml.check_promotions(new_lc, new_inv) == []
    assert "placement" not in new_lc.by_model("example-org/Example-30B-4bit").promotion


def test_a_model_other_aliases_still_use_is_not_retired_either():
    lc, inv = world()
    d = lifecycle_doc()
    d["catalog"].append({"id": "example-30b", "model": "example-org/Example-30B-4bit", "stage": "candidate",
                         "source": {"kind": "huggingface", "ref": "example-org/Example-30B-4bit", "revision": "4" * 40}})
    lc2 = ml.parse(d)
    routes = inv.routes + [nm.Route("local-fast", "beta", "mlx-lm-8080", "example-org/Example-27B-4bit", "chat", "", {}, {}, 15.0),
                           nm.Route("local-medium-next", "alpha", "mlx-lm-8080", "example-org/Example-30B-4bit", "chat", "", {}, {}, 17.0)]
    vs = verdicts(*[verdict_record("example-org/Example-30B-4bit", "local-medium", run=f"r{i}", incumbent="example-org/Example-27B-4bit")
                    for i in range(3)])
    new_lc, _, notes = ml.promote("local-medium-next", vs, lc2, nm.Inventory(inv.nodes, routes))
    assert new_lc.by_model("example-org/Example-27B-4bit").stage != "retired"
    assert any("still route" in n for n in notes)


# ------------------------------------------------------------ re-placement rules

def test_a_replacement_must_name_the_move_and_be_class_perf():
    lc, inv = world()
    inv = with_replacement_next(inv)
    with pytest.raises(ml.LifecycleError, match="no passing comparison"):
        ml.promote("local-embed-next", perf_verdicts(placement=None), lc, inv)                      # no move named
    with pytest.raises(ml.LifecycleError, match="no passing comparison"):
        ml.promote("local-embed-next", perf_verdicts(placement={"from_node": "beta", "to_node": "gamma"}), lc, inv)
    with pytest.raises(ml.LifecycleError, match="no passing comparison"):
        ml.promote("local-embed-next", perf_verdicts(klass="chat"), lc, inv)                          # a quality class does not decide a move
    counted, notes = ml.count_passes(perf_verdicts(klass="chat"), "local-embed", EMBED, "", EMBED, MOVE)
    assert counted == [] and any("decided by class perf" in n for n in notes)


def test_the_perf_default_of_one_applies_only_to_a_replacement():
    lc, inv = world()
    assert lc.required_for("perf", replacement=True) == 1
    assert lc.required_for("perf") == 3                                  # a perf pass is not a quality verdict
    assert lc.required_for("chat", replacement=True) == 3
    lc2 = ml.parse(lifecycle_doc(promotion={"requiredPasses": 3, "requiredPassesByClass": {"perf": 2}}))
    assert lc2.required_for("perf", replacement=True) == 2               # the operator's number always wins
    with pytest.raises(ml.LifecycleError, match="1 of 2"):
        ml.promote("local-embed-next", perf_verdicts(1), lc2, with_replacement_next(inv))
    new_lc, _, _ = ml.promote("local-embed-next", perf_verdicts(2), lc2, with_replacement_next(inv))
    assert new_lc.by_model(EMBED).promotion["required"] == 2


def test_one_perf_pass_cannot_move_an_alias_to_a_different_model():
    lc, inv = world()
    d = lifecycle_doc()
    d["catalog"].append({"id": "example-30b", "model": "example-org/Example-30B-4bit", "stage": "candidate",
                         "source": {"kind": "huggingface", "ref": "example-org/Example-30B-4bit", "revision": "4" * 40}})
    inv2 = nm.Inventory(inv.nodes, inv.routes + [nm.Route("local-medium-next", "alpha", "mlx-lm-8080", "example-org/Example-30B-4bit", "chat",
                                                          "", {}, {}, 17.0)])
    vs = verdicts(verdict_record("example-org/Example-30B-4bit", "local-medium", klass="perf", incumbent="example-org/Example-27B-4bit"))
    with pytest.raises(ml.LifecycleError, match="1 of 3"):
        ml.promote("local-medium-next", vs, ml.parse(d), inv2)


def test_the_same_server_on_both_sides_is_nothing_to_move():
    lc, inv = world()
    same = nm.Route("local-embed-next", "beta", "llama-8081", EMBED, "embedding", "", {}, {}, 4.0)
    with pytest.raises(ml.LifecycleError, match="nothing to move"):
        ml.promote("local-embed-next", perf_verdicts(), lc, nm.Inventory(inv.nodes, inv.routes + [same]))


def test_check_promotions_accepts_a_replacement_record_and_refuses_a_stale_or_broken_one():
    lc, inv = world()
    new_lc, new_inv, _ = ml.promote("local-embed-next", perf_verdicts(), lc, with_replacement_next(inv))
    assert ml.check_promotions(new_lc, new_inv) == []
    # the alias later moves again without a new record: the old placement no longer says where it routes
    moved = nm.Inventory(new_inv.nodes, [nm.Route(r.alias, "beta", r.endpoint, r.model, r.kind, r.provider, r.params, r.model_info, r.size_gib)
                                         if r.alias == "local-embed" else r for r in new_inv.routes])
    assert any("says it moved to alpha, but the alias routes to beta" in p for p in ml.check_promotions(new_lc, moved))
    e = new_lc.by_model(EMBED)
    for bad, match in (({"from_node": "beta"}, "without from_node and to_node"),
                       ({"from_node": "alpha", "to_node": "alpha", "from_endpoint": "x", "to_endpoint": "x"}, "from a place to itself")):
        broken = ml.merge(new_lc, ml.Lifecycle([ml.replace(e, promotion={**e.promotion, "placement": bad})]))
        assert any(match in p for p in ml.check_promotions(broken, new_inv))


def test_propose_replacement_adds_only_a_next_route_on_the_eval_gateway():
    lc, inv = world()
    add_lc, add_inv, notes = ml.propose_replacement("local-embed", "alpha", "llama-8081", lc, inv)
    assert add_lc.catalog == []                                          # the catalog does not change
    (r,) = add_inv.routes
    assert (r.alias, r.node, r.model) == ("local-embed-next", "alpha", EMBED)
    assert r.alias not in {x.alias for x in nm.gateway_routes(nm.Inventory(add_inv.nodes, add_inv.routes), "production")}
    assert any("class perf" in n and "beta to alpha" in n for n in notes)
    new_lc, new_inv = apply_change(lc, inv, add_lc, add_inv)
    assert ml.check_promotions(new_lc, new_inv) == []
    for bad, match in ((("local-embed", "beta", "llama-8081"), "already runs"), (("local-embed", "alpha", "nope"), "no endpoint"),
                       (("local-nothing", "alpha", "llama-8081"), "not a live route")):
        with pytest.raises(ml.LifecycleError, match=match):
            ml.propose_replacement(bad[0], bad[1], bad[2], lc, inv)


def test_propose_replacement_refuses_a_candidate_model_and_an_unpinned_one():
    lc, inv = world()
    d = lifecycle_doc()
    d["catalog"][1]["stage"] = "candidate"
    with pytest.raises(ml.LifecycleError, match="only a promoted model is moved"):
        ml.propose_replacement("local-embed", "alpha", "llama-8081", ml.parse(d), inv)


# ------------------------------------------------------------ a brand-new alias, no incumbent (case 2)

SRC = ml.Source("huggingface", "example-org/Example-8B-4bit", "5" * 40)
NEW = "example-org/Example-8B-4bit"


def test_propose_new_adds_a_candidate_and_a_next_route_and_no_live_route():
    lc, inv = world()
    add_lc, add_inv, notes = ml.propose_new("local-fast", NEW, SRC, "alpha", "mlx-lm-8080", "chat", lc, inv, size_gib=5.0, context_tokens=8192)
    (e,) = add_lc.catalog
    assert (e.model, e.stage, e.source.revision) == (NEW, "candidate", "5" * 40) and e.adopted == ""
    (r,) = add_inv.routes
    assert r.alias == "local-fast-next" and r.model_info == {"max_input_tokens": 8192, "endpoint_tier": "local"}      # TM-1119: a node route says it is local
    assert "local-fast" not in {x.alias for x in add_inv.routes}
    assert all("local-fast-next" not in str(x.alias) for x in nm.gateway_routes(nm.Inventory(add_inv.nodes, add_inv.routes), "production"))
    assert any("absolute bars" in n for n in notes) and any("no agent can call it" in n for n in notes)
    new_lc, new_inv = apply_change(lc, inv, add_lc, add_inv)
    assert ml.check_promotions(new_lc, new_inv) == []                    # a -next route is never gated


def test_propose_new_refuses_what_is_not_a_new_alias_or_cannot_be_pulled():
    lc, inv = world()
    cases = [(dict(alias="local-medium"), "already routes to"),
             (dict(alias="local-fast-next"), "no -next suffix"),
             (dict(source=ml.Source("huggingface", "example-org/Example-8B-4bit", "")), "no pinned revision"),
             (dict(node="nope"), "no endpoint"),
             (dict(kind="embedding", endpoint="mlx-lm-8080"), "does not serve")]
    for over, match in cases:
        args = dict(alias="local-fast", model=NEW, source=SRC, node="alpha", endpoint="mlx-lm-8080", kind="chat")
        args.update(over)
        with pytest.raises(ml.LifecycleError, match=match):
            ml.propose_new(args["alias"], args["model"], args["source"], args["node"], args["endpoint"], args["kind"], lc, inv)


def test_propose_new_with_a_comparison_already_running_is_refused():
    lc, inv = world()
    add_lc, add_inv, _ = ml.propose_new("local-fast", NEW, SRC, "alpha", "mlx-lm-8080", "chat", lc, inv)
    new_lc, new_inv = apply_change(lc, inv, add_lc, add_inv)
    with pytest.raises(ml.LifecycleError, match="already exists"):
        ml.propose_new("local-fast", NEW, SRC, "alpha", "mlx-lm-8082", "chat", new_lc, new_inv)


def new_alias_world():
    lc, inv = world()
    add_lc, add_inv, _ = ml.propose_new("local-fast", NEW, SRC, "alpha", "mlx-lm-8080", "chat", lc, inv, size_gib=5.0)
    return apply_change(lc, inv, add_lc, add_inv)


def test_count_passes_with_an_empty_incumbent_counts_only_no_incumbent_records():
    vs = verdicts(
        verdict_record(NEW, "local-fast", run="a1"),
        verdict_record(NEW, "local-fast", run="a2"),
        verdict_record(NEW, "local-fast", run="b1", incumbent="example-org/Example-27B-4bit"),   # compared to something: not this case
        verdict_record(NEW, "local-fast", run="a3", verdict="inconclusive"))
    counted, notes = ml.count_passes(vs, "local-fast", NEW, "5" * 40, "")
    assert [v.run_id for v in counted] == ["a1", "a2"]
    assert any("b1" in n and "compared against example-org/Example-27B-4bit, not the current nothing" in n for n in notes)
    assert all(v.absolute for v in counted)
    # an incumbent-bearing run is the ONLY thing counted when there is an incumbent, and a fail resets either way
    counted, _ = ml.count_passes(verdicts(verdict_record(NEW, "local-fast", run="a1"), verdict_record(NEW, "local-fast", run="a2", verdict="fail")),
                                 "local-fast", NEW, "", "")
    assert counted == []


def test_a_new_alias_promotes_on_absolute_bars_and_records_no_predecessor():
    lc, inv = new_alias_world()
    vs = verdicts(*[verdict_record(NEW, "local-fast", run=f"r{i}", revision="5" * 40, criterion="absolute-bars/chat") for i in range(3)])
    assert all(v.absolute for v in vs)
    new_lc, new_inv, notes = ml.promote("local-fast-next", vs, lc, inv)
    e = new_lc.by_model(NEW)
    assert e.stage == "promoted" and e.promotion["from"] == "" and e.promotion["alias"] == "local-fast"
    assert ml.check_promotions(new_lc, new_inv) == []
    assert next(r for r in new_inv.routes if r.alias == "local-fast").model == NEW
    assert not [n for n in notes if "retired" in n]
    with pytest.raises(ml.LifecycleError, match="2 of 3"):
        ml.promote("local-fast-next", vs[:2], lc, inv)
    with pytest.raises(ml.LifecycleError, match="no passing comparison"):             # a run against an incumbent that is not there
        ml.promote("local-fast-next", verdicts(verdict_record(NEW, "local-fast", incumbent="example-org/Example-27B-4bit")), lc, inv)


# ------------------------------------------------------------ the evaluation request

def test_eval_request_for_each_case():
    now = "2026-10-21T00:00:00Z"
    new = ml.eval_request("local-fast", "chat", 3, {"model": NEW, "revision": "5" * 40}, {}, "ada", now)
    assert new["criterion"] == "absolute-bars" and new["incumbent"] == {}
    rep = ml.eval_request("local-embed", "perf", 1, {"model": EMBED}, {"model": EMBED}, "ada", now, MOVE)
    assert rep["placement"] == MOVE and "criterion" not in rep
    with pytest.raises(ml.LifecycleError, match="re-placement"):
        ml.eval_request("local-embed", "chat", 1, {"model": EMBED}, {"model": EMBED}, "ada", now, MOVE)
    with pytest.raises(ml.LifecycleError, match="must name the move"):
        ml.eval_request("local-embed", "perf", 1, {"model": EMBED}, {"model": EMBED}, "ada", now)


# ------------------------------------------------------------ through the UI

def test_the_models_page_shows_a_replacement_for_what_it_is(tmp_path):
    from tests.models_support import inventory_doc, models_client
    inv = inventory_doc()
    inv["routes"].append({"alias": "local-embed-next", "model": EMBED, "node": "alpha", "endpoint": "llama-8081", "kind": "embedding", "sizeGiB": 4.0})
    c, u = models_client(tmp_path, inventory=inv)
    t = c.get("/models").text
    assert "Re-placement" in t and "from beta to alpha" in t
    ev = c.get("/models/evaluate?alias=local-embed-next").text
    assert 'value="perf"' in ev and "beta to alpha" in ev
    r = c.post("/models/evaluate", data={"csrf": u.csrf, "alias": "local-embed-next", "klass": "perf"})
    assert r.status_code == 200 and "from_node: beta" in r.text and "to_node: alpha" in r.text

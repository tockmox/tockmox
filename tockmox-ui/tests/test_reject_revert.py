# SPDX-License-Identifier: Apache-2.0
"""TM-1258 (specified by the REQ-0048 amendment, TM-1254): the `rejected` stage, the reject change and the revert change (DESIGN-2026-10-29-eval-runner sections 3
and 8). A failing candidate leaves the eval gateway and is never offered again at that revision; a promoted build
that breaches its health rules goes back to what the alias served before, in one reviewed change."""
import pytest

from app import models as ml
from app import nodes as nm
from tests.models_support import inventory_doc, lifecycle_doc, verdict_record, verdicts

OLD, NEW = "example-org/Example-27B-4bit", "example-org/Example-30B-4bit"
REV = "4" * 40


def candidate_world():
    d = lifecycle_doc()
    d["catalog"].append({"id": "example-30b", "model": NEW, "stage": "candidate", "sizeGiB": 17.0,
                         "source": {"kind": "huggingface", "ref": NEW, "revision": REV}})
    lc = ml.parse(d)
    inv = nm.parse_inventory(inventory_doc())
    inv.routes.append(nm.Route("local-medium-next", "alpha", "mlx-lm-8080", NEW, "chat", "", {}, {}, 17.0))
    return lc, inv


def promoted_world():
    lc, inv = candidate_world()
    vs = verdicts(*[verdict_record(NEW, "local-medium", run=f"r{i}", incumbent=OLD) for i in range(3)])
    new_lc, new_inv, _ = ml.promote("local-medium-next", vs, lc, inv)
    return new_lc, new_inv


def test_a_rejected_entry_needs_a_reason_and_a_date():
    d = lifecycle_doc()
    d["catalog"].append({"id": "x", "model": NEW, "stage": "rejected", "source": {"kind": "huggingface", "ref": NEW, "revision": REV}})
    with pytest.raises(ml.LifecycleError, match="rejection.reason and rejection.date"):
        ml.parse(d)
    d["catalog"][-1]["rejection"] = {"reason": "worse on tools", "date": "2026-10-29"}
    e = ml.parse(d).by_model(NEW)
    assert e.stage == "rejected" and e.as_dict()["rejection"]["reason"] == "worse on tools"
    d["catalog"][-1]["stage"] = "candidate"
    with pytest.raises(ml.LifecycleError, match="rejection is set but the stage is candidate"):
        ml.parse(d)


def test_reject_removes_the_next_route_and_records_why():
    lc, inv = candidate_world()
    new_lc, new_inv, notes = ml.reject("local-medium-next", "Worse: 4 wins, 19 losses on agent-v1", "2026-10-29T03:10", lc, inv)
    e = new_lc.by_model(NEW)
    assert e.stage == "rejected"
    assert e.rejection == {"reason": "Worse: 4 wins, 19 losses on agent-v1", "date": "2026-10-29", "alias": "local-medium",
                           "revision": REV}
    assert not [r for r in new_inv.routes if r.alias == "local-medium-next"]
    assert [r.model for r in new_inv.routes if r.alias == "local-medium"] == [OLD]       # the live alias is untouched
    assert ml.check_promotions(new_lc, new_inv) == []
    assert any("only at a revision other than" in n for n in notes)
    # and the parse round trip keeps it
    assert ml.parse(ml.to_doc(new_lc)).by_model(NEW).rejection["reason"].startswith("Worse")


def test_reject_refuses_what_it_must():
    lc, inv = candidate_world()
    with pytest.raises(ml.LifecycleError, match="reject a -next route"):
        ml.reject("local-medium", "x", "2026-10-29", lc, inv)
    with pytest.raises(ml.LifecycleError, match="say why"):
        ml.reject("local-medium-next", "  ", "2026-10-29", lc, inv)
    with pytest.raises(ml.LifecycleError, match="when must start with a date"):
        ml.reject("local-medium-next", "x", "tonight", lc, inv)
    live_lc, live_inv = promoted_world()
    live_inv.routes.append(nm.Route("local-medium-next", "alpha", "mlx-lm-8082", NEW, "chat", "", {}, {}, 17.0))
    with pytest.raises(ml.LifecycleError, match="serves local-medium: rejecting it would leave a live alias"):
        ml.reject("local-medium-next", "x", "2026-10-29", live_lc, live_inv)


def test_a_route_to_a_rejected_build_fails_the_gate_on_either_gateway():
    lc, inv = candidate_world()
    new_lc, _, _ = ml.reject("local-medium-next", "control failed twice", "2026-10-29", lc, inv)
    problems = ml.check_promotions(new_lc, inv)              # the -next route put back by hand
    assert problems and "was rejected (2026-10-29: control failed twice)" in problems[0]


def test_a_rejected_build_cannot_be_promoted():
    lc, inv = candidate_world()
    new_lc, _, _ = ml.reject("local-medium-next", "worse", "2026-10-29", lc, inv)
    vs = verdicts(*[verdict_record(NEW, "local-medium", run=f"r{i}", incumbent=OLD) for i in range(3)])
    with pytest.raises(ml.LifecycleError, match="is rejected"):
        ml.promote("local-medium-next", vs, new_lc, inv)


def test_promotion_records_the_previous_route_and_revert_restores_it():
    lc, inv = promoted_world()
    p = lc.by_model(NEW).promotion
    assert p["previous"] == {"model": OLD, "node": "beta", "endpoint": "mlx-lm-8080", "kind": "chat",
                             "modelInfo": {"max_input_tokens": 32768}, "sizeGiB": 15.0}
    assert lc.by_model(OLD).stage == "retired"
    back_lc, back_inv, notes = ml.revert("local-medium", "tool-call parse failures 3.1x baseline for 40 min", "2026-10-30",
                                         lc, inv)
    live = [r for r in back_inv.routes if r.alias == "local-medium"]
    assert len(live) == 1 and (live[0].model, live[0].node, live[0].endpoint) == (OLD, "beta", "mlx-lm-8080")
    assert live[0].model_info == {"max_input_tokens": 32768}
    assert back_lc.by_model(OLD).stage == "promoted"
    d = back_lc.by_model(NEW)
    assert d.stage == "rejected" and d.rejection["demoted"] is True and d.rejection["revision"] == REV
    assert ml.check_promotions(back_lc, back_inv) == []
    assert any("files must be on beta" in n for n in notes)


def test_revert_refuses_what_it_must():
    lc, inv = promoted_world()
    with pytest.raises(ml.LifecycleError, match="say why"):
        ml.revert("local-medium", "", "2026-10-30", lc, inv)
    with pytest.raises(ml.LifecycleError, match="no live alias"):
        ml.revert("local-nope", "x", "2026-10-30", lc, inv)
    # an alias that was adopted, never promoted through evidence: nothing on record to go back to
    with pytest.raises(ml.LifecycleError, match="has no promotion for local-embed"):
        ml.revert("local-embed", "x", "2026-10-30", lc, inv)
    # the demoted build also serves another live alias
    inv.routes.append(nm.Route("local-fast", "alpha", "mlx-lm-8082", NEW, "chat", "", {}, {}, 17.0))
    with pytest.raises(ml.LifecycleError, match="also serves local-fast"):
        ml.revert("local-medium", "x", "2026-10-30", lc, inv)


def test_a_promotion_from_before_previous_was_recorded_is_refused_by_name():
    lc, inv = promoted_world()
    e = lc.by_model(NEW)
    rec = {k: v for k, v in e.promotion.items() if k != "previous"}
    from dataclasses import replace
    lc = ml.merge(lc, ml.Lifecycle([replace(e, promotion=rec)]))
    with pytest.raises(ml.LifecycleError, match="records no previous route"):
        ml.revert("local-medium", "x", "2026-10-30", lc, inv)

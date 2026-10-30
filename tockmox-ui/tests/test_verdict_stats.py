# SPDX-License-Identifier: Apache-2.0
"""TM-1248: the statistics a verdict rests on, and the counting rule that stops reruns of one frozen set from
counting as independent evidence (AIX-1 of the 2026-10-29 council, verified against count_passes)."""
import json

import pytest

from app import models as ml
from app import verdict_stats as vs
from tests.proto_support import verdict_record, verdicts

NEW, OLD = "mlx-community/New-32B-6bit", "mlx-community/Old-27B-4bit"


# ---------------------------------------------------------------- primitives

def test_sign_test_exact_values():
    assert vs.sign_test(0, 0) == 1.0
    assert vs.sign_test(5, 5) == 1.0
    assert vs.sign_test(8, 0) == pytest.approx(2 / 256)        # all eight discordant pairs one way
    assert vs.sign_test(6, 1) == pytest.approx(2 * 8 / 128)


def test_wilson_matches_the_textbook_bound():
    lo, hi = vs.wilson(8, 8)
    assert lo == pytest.approx(0.6756, abs=1e-3) and hi == 1.0   # 8 of 8 bounds the failure rate only to about 32%
    lo, hi = vs.wilson(0, 10)
    assert lo == 0.0 and hi == pytest.approx(0.2775, abs=1e-3)


def test_bootstrap_is_deterministic_for_a_seed():
    d = [1, 0, 0, -1, 1, 1, 0, 0, 1, 0]
    assert vs.paired_bootstrap(d, seed=7) == vs.paired_bootstrap(d, seed=7)


# ---------------------------------------------------------------- decide

def _pairs(wins, losses, ties_pass, ties_fail=0):
    return [(True, False)] * wins + [(False, True)] * losses + [(True, True)] * ties_pass + [(False, False)] * ties_fail


def test_a_clear_improvement_on_a_real_set_is_better():
    r = vs.decide(_pairs(31, 6, 3), margin=0.05, min_effect=0.05)
    assert r["label"] == "better" and r["verdict"] == "pass" and not r["screening"]
    assert (r["wins"], r["losses"], r["ties"], r["n"]) == (31, 6, 3, 40)
    assert r["interval"][0] > 0.05 and r["p_value"] < 0.001


def test_a_screening_set_cannot_say_better():
    r = vs.decide(_pairs(8, 0, 0), margin=0.05, min_effect=0.05)
    assert r["screening"] and r["label"] != "better"
    assert r["verdict"] in ("pass", "inconclusive")


def test_identical_answers_are_same():
    r = vs.decide(_pairs(0, 0, 38, 2), margin=0.05, min_effect=0.05)
    assert r["label"] == "same" and r["verdict"] == "pass" and r["interval"] == [0.0, 0.0]


def test_a_clear_regression_is_worse_and_a_safety_fail_is_always_worse():
    assert vs.decide(_pairs(2, 25, 13), margin=0.05, min_effect=0.05)["label"] == "worse"
    assert vs.decide(_pairs(0, 0, 40), margin=0.05, min_effect=0.05, safety_fails=1)["label"] == "worse"


def test_a_noisy_split_is_inconclusive_and_says_how_much_more_would_settle_it():
    r = vs.decide(_pairs(9, 7, 24), margin=0.05, min_effect=0.05)
    assert r["label"] == "inconclusive" and r["verdict"] == "inconclusive" and r["more_cases"] > 0


def test_epochs_reduce_to_a_per_case_rate():
    r = vs.decide([([True, True, False, True], [True, False, False, False])] * 30, margin=0.05, min_effect=0.05)
    assert r["wins"] == 30 and r["label"] == "better"


def test_absolute_bars_use_the_wilson_floor():
    assert vs.decide_absolute(40, 40, bar=0.9)["label"] == "same"
    assert vs.decide_absolute(8, 8, bar=0.9)["label"] == "inconclusive"     # 8 of 8 cannot show 90%
    assert vs.decide_absolute(2, 40, bar=0.9)["label"] == "worse"


def test_bad_input_is_refused():
    with pytest.raises(vs.StatsError):
        vs.decide([], margin=0.05, min_effect=0.05)
    with pytest.raises(vs.StatsError):
        vs.decide([(2, 0)], margin=0.05, min_effect=0.05)
    with pytest.raises(vs.StatsError):
        vs.decide(_pairs(1, 0, 0), margin=1.5, min_effect=0.05)


# ---------------------------------------------------------------- the verdict fields

def test_the_new_fields_parse_and_disagreement_is_refused():
    t = verdict_record(NEW, "local-agent", incumbent=OLD, extras={
        "n": 40, "discordant": {"b": 31, "c": 6}, "method": "sign-test+bootstrap", "interval": [0.4, 0.8],
        "margin": 0.05, "min_effect": 0.05, "label": "better", "screening": False,
        "engine": {"id": "mlx-lm", "version": "0.32.2"}, "node": "mac-studio-m5", "judge": None,
        "control": {"passed": False, "cases": 4}})
    v = ml.parse_verdict(t)
    assert v.extras["label"] == "better" and v.extras["engine"]["id"] == "mlx-lm" and v.advisories == []
    for bad, why in [({"label": "worse"}, "means verdict fail"),
                     ({"label": "better", "screening": True}, "screening"),
                     ({"interval": [0.5, 0.1]}, "interval"),
                     ({"discordant": {"b": -1, "c": 0}}, "discordant"),
                     ({"method": "vibes"}, "method"),
                     ({"control": {"passed": "no"}}, "control")]:
        with pytest.raises(ml.LifecycleError, match=why):
            ml.parse_verdict(verdict_record(NEW, "local-agent", incumbent=OLD, extras=bad))


def test_a_pass_without_a_control_carries_an_advisory_not_a_refusal():
    v = ml.parse_verdict(verdict_record(NEW, "local-agent", incumbent=OLD))
    assert any("known-bad control" in a for a in v.advisories)
    assert not any("control" in w for w in v.warnings)          # an advisory never blocks an evidence PR


# ---------------------------------------------------------------- the counting rule (the planted rerun)

def _rerun(n, sampling, **kw):
    return [verdict_record(NEW, "local-agent", run=f"r{i}", date=f"2026-10-{i + 1:02d}", incumbent=OLD,
                           sampling=sampling, **kw) for i in range(n)]


def test_three_reruns_of_one_frozen_set_are_one_piece_of_evidence():
    """The planted defect: before TM-1248 count_passes deduplicated on run_id only, and a producer that stamps the
    run id from a clock (compare.py) turned three reruns of the same eight cases into three passes."""
    counted, notes = ml.count_passes(verdicts(*_rerun(3, {"temperature": 0, "seed": 1})), "local-agent", NEW, "", OLD)
    assert len(counted) == 1
    assert sum("same evidence twice" in n for n in notes) == 2


def test_independent_evidence_still_counts():
    texts = [verdict_record(NEW, "local-agent", run="a", date="2026-10-01", incumbent=OLD, sampling={"seed": 1}),
             verdict_record(NEW, "local-agent", run="b", date="2026-10-02", incumbent=OLD, sampling={"seed": 2}),
             verdict_record(NEW, "local-agent", run="c", date="2026-10-03", incumbent=OLD, sampling={"seed": 1},
                            extras={"node": "mac-studio-m4"})]
    assert [v.run_id for v in ml.count_passes(verdicts(*texts), "local-agent", NEW, "", OLD)[0]] == ["a", "b", "c"]


def test_a_pass_whose_control_also_passed_does_not_count():
    t = verdict_record(NEW, "local-agent", incumbent=OLD, extras={"control": {"passed": True}})
    counted, notes = ml.count_passes(verdicts(t), "local-agent", NEW, "", OLD)
    assert counted == [] and any("control passed" in n for n in notes)


def test_the_default_bar_is_one_piece_of_evidence_per_class():
    assert ml.parse({}).required_passes == 1
    assert ml.parse({"promotion": {"requiredPasses": 3}}).required_passes == 3


def test_a_site_that_asks_for_three_cannot_meet_it_with_reruns():
    from tests.models_support import world
    L, I = world()
    assert L.required_passes == 3
    with pytest.raises(ml.LifecycleError, match="1 of 3"):
        ml._passed("local-agent", NEW, verdicts(*_rerun(3, {"seed": 9})), L, incumbent=OLD)

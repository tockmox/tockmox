# SPDX-License-Identifier: Apache-2.0
"""TM-1262: the PR opener's `reject` and `revert` kinds. Same lane as admit and promote: one model-lifecycle PR open at a time, built by
the UI's own functions, and a refusal in the words models.reject / models.revert use."""
import pytest
import yaml

from app import config as cfgmod
from app import models as ml
from app import nodes as nm
from app import pr_opener as po
from tests.proto_support import _secret  # noqa: F401  (autouse fixture: the session secret the config needs)
from tests.proto_support import lifecycle_full_doc
from tests.test_pr_opener import NEW, PATH, cfg, forge_for, passes, values

WHEN = "2026-10-29"


def promoted_values():
    """Values after the count was reached and the promote PR merged: local-agent serves NEW and remembers what it served before."""
    v = values(with_next=True)
    old = next(r for r in v["inferenceNodes"]["routes"] if r["alias"] == "local-agent")["model"]
    if not any(e["model"] == old for e in v["modelLifecycle"]["catalog"]):                     # a revert needs the previous model on record
        v["modelLifecycle"]["catalog"].append({"id": "previous", "model": old, "adopted": "2026-09-01", "stage": "promoted",
                                               "source": {"kind": "huggingface", "ref": old}})
    vs = [ml.parse_verdict(t, f"evals/verdicts/{i}.json") for i, t in enumerate(passes(v))]
    p = po.plan(v, None, vs)
    assert p.prs[0].kind == "promote"
    return yaml.safe_load(p.prs[0].text)


def gate(doc):
    """What the UI would accept on its next start."""
    full = lifecycle_full_doc()
    full["modelLifecycle"], full["inferenceNodes"] = doc["modelLifecycle"], doc["inferenceNodes"]
    cfgmod.parse(full)


# ------------------------------------------------------------ reject

def test_a_reject_pr_takes_the_candidate_off_the_eval_gateway_and_records_why():
    v = values(with_next=True)
    spec = po.plan_reject(v, "local-agent-next", "worse on tool calls", WHEN)
    assert spec.kind == "reject" and spec.branch == "tockmox/reject/local-agent-next" and spec.subject == "local-agent-next"
    assert spec.title == f"Reject {NEW} on local-agent-next" and "Why: worse on tool calls" in spec.body
    doc = yaml.safe_load(spec.text)
    assert "local-agent-next" not in [r["alias"] for r in doc["inferenceNodes"]["routes"]]
    e = next(x for x in doc["modelLifecycle"]["catalog"] if x["model"] == NEW)
    assert e["stage"] == "rejected" and e["rejection"]["reason"] == "worse on tool calls" and e["rejection"]["date"] == WHEN
    po.check_values_file(doc)
    gate(doc)
    assert "moves no live alias" in spec.body


def test_reject_is_refused_in_models_rejects_own_words():
    v = values(with_next=True)
    cases = [("local-agent-next", "  ", "say why: the reason is what keeps the build from being offered again by accident"),
             ("local-agent", "x", "reject a -next route: a live alias is reverted, not rejected"),
             ("local-nope-next", "x", "no route local-nope-next")]
    for alias, reason, words in cases:
        with pytest.raises(po.Refused) as e:
            po.plan_reject(v, alias, reason, WHEN)
        assert str(e.value) == words, alias


# ------------------------------------------------------------ revert

def test_a_revert_pr_puts_the_alias_back_and_marks_the_demoted_build_rejected():
    v = promoted_values()
    before = next(r for r in values()["inferenceNodes"]["routes"] if r["alias"] == "local-agent")["model"]
    spec = po.plan_revert(v, "local-agent", "latency regressed in production", WHEN)
    assert spec.kind == "revert" and spec.branch == "tockmox/revert/local-agent" and spec.title == f"Revert local-agent from {NEW}"
    assert "Why: latency regressed in production" in spec.body and "changes what the production gateway serves" in spec.body
    doc = yaml.safe_load(spec.text)
    assert {r["alias"]: r["model"] for r in doc["inferenceNodes"]["routes"]}["local-agent"] == before
    assert next(x for x in doc["modelLifecycle"]["catalog"] if x["model"] == NEW)["stage"] == "rejected"
    po.check_values_file(doc)
    gate(doc)


def test_revert_is_refused_in_models_reverts_own_words():
    with pytest.raises(po.Refused) as e:
        po.plan_revert(promoted_values(), "local-agent", "  ", WHEN)
    with pytest.raises(ml.LifecycleError) as want:
        lc, inv = ml.parse(promoted_values()["modelLifecycle"]), nm.parse_inventory(promoted_values()["inferenceNodes"])
        ml.revert("local-agent", "  ", WHEN, lc, inv)
    assert str(e.value) == str(want.value)
    with pytest.raises(po.Refused) as e2:                       # never promoted: nothing to go back to
        po.plan_revert(values(), "local-agent", "x", WHEN)
    lc, inv = ml.parse(values()["modelLifecycle"]), nm.parse_inventory(values()["inferenceNodes"])
    with pytest.raises(ml.LifecycleError) as want2:
        ml.revert("local-agent", "x", WHEN, lc, inv)
    assert str(e2.value) == str(want2.value)


# ------------------------------------------------------------ the same lane as admit and promote

@pytest.mark.parametrize("open_branch", ["tockmox/admit/x", "tockmox/promote/y", "tockmox/reject/z", "tockmox/revert/w"])
def test_one_model_lifecycle_pr_at_a_time(open_branch):
    with pytest.raises(po.Refused, match="already open") as e:
        po.plan_reject(values(with_next=True), "local-agent-next", "x", WHEN, open_branches={open_branch})
    assert open_branch in str(e.value) and "one at a time" in str(e.value)
    with pytest.raises(po.Refused, match="one at a time"):
        po.plan_revert(promoted_values(), "local-agent", "x", WHEN, open_branches={open_branch})


def test_an_open_evidence_pr_does_not_block_a_reject():
    spec = po.plan_reject(values(with_next=True), "local-agent-next", "x", WHEN, open_branches={po.EVIDENCE_BRANCH + "r1"})
    assert spec.kind == "reject"


def test_a_reject_or_revert_pr_blocks_the_next_admit_and_promote():
    assert po.plan(values(), {"schema": 1, "candidates": []}, [], open_branches={"tockmox/reject/local-agent-next"}).prs == []
    p = po.plan(values(), None, [], open_branches={"tockmox/revert/local-agent"})
    assert p.prs == []


def test_a_values_file_with_other_content_is_refused_for_reject_too():
    v = values(with_next=True)
    v["openWebui"] = {"image": "x"}
    with pytest.raises(po.Refused, match="only modelLifecycle, inferenceNodes"):
        po.plan_reject(v, "local-agent-next", "x", WHEN)


# ------------------------------------------------------------ opening them

@pytest.mark.parametrize("kind", ["github", "forgejo"])
def test_run_change_opens_a_reject_pr_and_the_next_one_waits(kind):
    files = {PATH: yaml.safe_dump(values(with_next=True))}
    f, forge = forge_for(kind, files)
    spec, url = po.run_change(cfg(kind), "reject", "local-agent-next", "worse on tool calls", forge, apply=True, when=WHEN, log=lambda *_: None)
    assert spec.kind == "reject" and url.startswith("https://forge.example/o/r/pull/") and f.prs == ["tockmox/reject/local-agent-next"]
    assert "Tockmox-Origin: model-watcher" in f.last_message and f.files["main"][PATH] == files[PATH]          # main untouched
    with pytest.raises(po.Refused, match="one at a time"):
        po.run_change(cfg(kind), "reject", "local-agent-next", "again", forge, apply=True, when=WHEN, log=lambda *_: None)
    assert len(f.prs) == 1


def test_run_change_without_apply_writes_nothing():
    f, forge = forge_for("github", {PATH: yaml.safe_dump(values(with_next=True))})
    said = []
    spec, url = po.run_change(cfg(), "reject", "local-agent-next", "x", forge, apply=False, when=WHEN, log=said.append)
    assert url == "" and said and said[0].startswith("would open") and all(r.method == "GET" for r in f.requests)


def test_run_change_opens_a_revert_pr():
    f, forge = forge_for("github", {PATH: yaml.safe_dump(promoted_values())})
    spec, url = po.run_change(cfg(), "revert", "local-agent", "latency", forge, apply=True, when=WHEN, log=lambda *_: None)
    assert spec.kind == "revert" and f.prs == ["tockmox/revert/local-agent"]


def test_run_change_refuses_other_kinds_and_a_config_without_a_values_path():
    f, forge = forge_for("github", {PATH: yaml.safe_dump(values())})
    with pytest.raises(po.Refused, match="not a change this opener makes by request"):
        po.run_change(cfg(), "promote", "local-agent", "x", forge)
    with pytest.raises(po.Refused, match="valuesPath is not set"):
        po.run_change(cfg(valuesPath=""), "reject", "local-agent-next", "x", forge)


def test_the_cli_reject_takes_a_reason_and_prints_a_refusal(tmp_path, monkeypatch, capsys):
    f, forge = forge_for("github", {PATH: yaml.safe_dump(values(with_next=True))})
    conf = tmp_path / "c.yaml"
    conf.write_text(yaml.safe_dump(cfg()))
    monkeypatch.setattr(po, "_forge_from", lambda c, p: forge)
    assert po.main(["opener", "reject", str(conf), "local-agent-next", "--reason", "worse on tool calls"]) == 0
    assert "would open  tockmox/reject/local-agent-next" in capsys.readouterr().out
    assert po.main(["opener", "reject", str(conf), "local-agent-next"]) == 1                      # no reason: models.reject refuses
    assert "refused: say why" in capsys.readouterr().err
    assert po.main(["opener", "reject", str(conf)]) == 2

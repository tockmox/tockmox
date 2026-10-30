# SPDX-License-Identifier: Apache-2.0
"""TM-1262: the Reject button on the Compare page. Offered for a fail, worse or tradeoff comparison while `<alias>-next` still routes
the candidate; the reason is required; it renders models.reject's change and writes nothing."""
import html

import pytest
import yaml

from app import models as ml
from tests.models_support import inventory_doc, lifecycle_doc
from tests.pages_support import with_next
from tests.test_models_compare_alias import FULL, NEW, OLD, REV, client, rec


def world(nxt=True, live_new=False):
    lc = lifecycle_doc()
    lc["catalog"].append({"id": "example-30b-4bit", "model": NEW, "stage": "promoted" if live_new else "candidate", **({"adopted": "2026-10-07"} if live_new else {}),
                          "source": {"kind": "huggingface", "ref": NEW, "revision": REV}})
    inv = with_next(inventory_doc(), model=NEW) if nxt else inventory_doc()
    if live_new:                                            # a live alias serves the candidate's model: that is a revert, not a reject
        inv["routes"].append({"alias": "local-other", "model": NEW, "node": "beta", "endpoint": "mlx-lm-8082", "sizeGiB": 17.0})
    return lc, inv


def comparison(tmp_path, label="worse", verdict="fail", nxt=True, live_new=False, groups=None, run="r1"):
    lc, inv = world(nxt, live_new)
    extras = {k: v for k, v in {**FULL, "label": label}.items() if k != "label" or label}          # label None: an older runner's pass / fail
    if label == "tradeoff":         # TM-1269: a tradeoff is an inconclusive verdict resting on a speed criterion
        extras["speed_criterion"] = {"decode_tok_s_min_ratio": 0.9}
    return client(tmp_path, rec(run=run, verdict=verdict, extras=extras), lifecycle=lc, inventory=inv, groups=groups)


def t(r):
    return html.unescape(r.text)


def tradeoff_label_exists():
    try:
        ml.parse_verdict(rec(verdict="inconclusive", extras={**FULL, "label": "tradeoff",
                                                             "speed_criterion": {"decode_tok_s_min_ratio": 0.9}}), "x.json")
        return True
    except ml.LifecycleError:
        return False


needs_tradeoff = pytest.mark.skipif(not tradeoff_label_exists(), reason="verdict label 'tradeoff' (TM-1269) lands with the runner/stats agent; this base's parse_verdict does not know it yet")


@pytest.mark.parametrize("label,verdict", [("worse", "fail"), (None, "fail"),
                                           pytest.param("tradeoff", "inconclusive", marks=needs_tradeoff)])
def test_reject_is_offered_for_fail_worse_and_tradeoff(tmp_path, label, verdict):
    c, u = comparison(tmp_path, label, verdict)
    body = t(c.get("/models/v/r1"))
    assert "Reject this candidate" in body and 'action="/models/v/r1/reject"' in body and 'name="reason"' in body and "required" in body


def test_reject_is_not_offered_for_a_better_or_a_passing_same_verdict(tmp_path):
    c, u = comparison(tmp_path, "better", "pass")
    body = t(c.get("/models/v/r1"))
    assert "Reject this candidate" not in body and "/reject" not in body


@needs_tradeoff
def test_the_tradeoff_label_does_not_break_the_page(tmp_path):
    c, u = comparison(tmp_path, "tradeoff", "inconclusive")
    r = c.get("/models/v/r1")
    assert r.status_code == 200 and "Tradeoff" in t(r)


def test_reject_renders_models_reject_and_writes_nothing(tmp_path):
    c, u = comparison(tmp_path)
    before = sorted(p.name for p in tmp_path.rglob("*"))
    r = c.post("/models/v/r1/reject", data={"csrf": u.csrf, "reason": "slower on long prompts, worse on tools", "fmt": "yaml"})
    assert r.status_code == 200
    doc = yaml.safe_load(r.text)
    routes = [x["alias"] for x in doc["inferenceNodes"]["routes"]]
    assert "local-medium-next" not in routes and "local-medium" in routes
    entry = next(e for e in doc["modelLifecycle"]["catalog"] if e["model"] == NEW)
    assert entry["stage"] == "rejected" and entry["rejection"]["reason"] == "slower on long prompts, worse on tools"
    assert entry["rejection"]["alias"] == "local-medium" and entry["rejection"]["revision"] == REV
    page = t(c.post("/models/v/r1/reject", data={"csrf": u.csrf, "reason": "worse"}))
    assert "Reject " + NEW + " on local-medium-next" in page and "Nothing has changed yet" in page and "follows comparison r1" in page
    assert sorted(p.name for p in tmp_path.rglob("*")) == before


def test_a_reason_is_required_and_the_page_comes_back_with_the_refusal(tmp_path):
    c, u = comparison(tmp_path)
    r = c.post("/models/v/r1/reject", data={"csrf": u.csrf, "reason": "   "})
    assert r.status_code == 400 and "say why: the reason is what keeps the build from being offered again by accident" in t(r)
    assert "Reject this candidate" in t(r)                                    # the form is still there to try again
    r2 = c.post("/models/v/r1/reject", data={"csrf": u.csrf, "reason": "<b>bad</b>"})
    assert r2.status_code == 200 and "<b>bad</b>" not in r2.text.replace("&lt;b&gt;", "")


def test_reject_needs_admin_and_the_csrf_token(tmp_path):
    c, u = comparison(tmp_path)
    assert c.post("/models/v/r1/reject", data={"csrf": "wrong", "reason": "x"}).status_code == 400
    (tmp_path / "b").mkdir()
    c2, u2 = comparison(tmp_path / "b", groups=["tockmox-users"])
    assert c2.post("/models/v/r1/reject", data={"csrf": u2.csrf, "reason": "x"}).status_code == 403


def test_reject_of_a_better_comparison_is_refused(tmp_path):
    c, u = comparison(tmp_path, "better", "pass")
    r = c.post("/models/v/r1/reject", data={"csrf": u.csrf, "reason": "x"})
    assert r.status_code == 400 and "failed, came out worse or was a tradeoff" in t(r)


def test_an_unknown_run_is_a_404(tmp_path):
    c, u = comparison(tmp_path)
    assert c.post("/models/v/nope/reject", data={"csrf": u.csrf, "reason": "x"}).status_code == 404


def test_when_the_next_route_is_gone_the_button_is_replaced_by_the_reason(tmp_path):
    c, u = comparison(tmp_path, nxt=False)
    body = t(c.get("/models/v/r1"))
    assert "does not route " + NEW + " now" in body and 'action="/models/v/r1/reject"' not in body
    r = c.post("/models/v/r1/reject", data={"csrf": u.csrf, "reason": "x"})
    assert r.status_code == 400 and "does not route" in t(r)


def test_a_candidate_that_serves_a_live_alias_gets_models_rejects_own_refusal(tmp_path):
    c, u = comparison(tmp_path, live_new=True)
    body = t(c.get("/models/v/r1"))
    assert "serves local-other: rejecting it would leave a live alias on a rejected build. Revert that alias first" in body
    assert 'action="/models/v/r1/reject"' not in body

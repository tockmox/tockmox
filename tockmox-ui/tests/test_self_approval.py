# SPDX-License-Identifier: Apache-2.0
"""Separation of duties on Platform > Changes (Jeff's ruling 2026-11-06, NIST SP 800-53 AC-5).

  record     every change the console opens (a page's change, Make an administrator, a revert) carries
             Tockmox-Requested-By: <the identity provider username of the person who asked>, so the person is never
             hidden behind the change bot; the merge commit carries Requested-by beside Approved-by
  refuse     the person who asked does not approve: Approve is refused before any review is posted, naming who else
             in the approvers team can
  exception  selfApproval: sole-approver-only (the default): when the asker is the ONLY member of the approvers team,
             the approval goes through and the merge says "Self-approved: sole approver"; a second approver turns the
             exception off by itself; selfApproval: never refuses even then
  fail       a team the person's token cannot read is not a team of one: refused
  show       Recently applied names who asked, and a self-approved merge carries a badge

Run from tockmox-ui/: python -m pytest tests/test_self_approval.py
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402
from app import forge as forge_mod  # noqa: E402
from tests import test_actions as base  # noqa: E402
from tests import test_changes as tc  # noqa: E402
from tests import test_open_change as oc  # noqa: E402


def asked_by(fg, n, login):
    fg.pulls[n]["body"] += f"\n\nTockmox-Requested-By: {login}\nTockmox-Origin: console"


# ---------------------------------------------------------------- record

def test_a_change_the_console_opens_records_who_asked_for_it(tmp_path):
    s, fg, _ = oc.service(tmp_path)
    t = {"what": "models", "draft": s.stage_draft(oc.draft()), "title": "Require two passes to promote", "applied": oc.AP}
    code, out = oc.confirm_and_open(s, "open-change", t, preferred_username="jeff")
    assert code == 200 and out["result"] == "done", out
    _, b, _, _ = oc.opened(fg)
    _, pr = fg.opened[-1]
    assert "\nTockmox-Requested-By: jeff\n" in b["message"] and "Tockmox-Requested-By: jeff" in pr["body"]
    assert forge_mod.requester_of(pr) == "jeff"
    assert "Requested-By" not in forge_mod.summary_of(pr["body"]), "a trailer is never part of the summary"


def test_a_revert_records_who_asked_for_it(tmp_path):
    s, fg, _ = tc.service(tmp_path)
    it = act.intent("revert-change", {"number": 5, "title": "Add model a", "merge": tc.M0}, {}, "a")
    code, out = tc.go(s, fg, it)
    assert code == 200 and out["result"] == "done", out
    _, pr = fg.opened[-1]
    assert forge_mod.requester_of(pr) == "jeff"


# ---------------------------------------------------------------- refuse / exception

def test_the_asker_is_refused_when_another_approver_could_approve(tmp_path):
    s, fg, _ = tc.service(tmp_path)
    fg.approvers = {"jeff", "dawn"}
    asked_by(fg, 7, "jeff")
    code, out = tc.go(s, fg, tc.approve())
    assert code == 403 and out["result"] == "refused", out
    assert "you asked for #7" in out["reason"] and "dawn" in out["reason"], out["reason"]
    assert fg.reviews == [] and fg.merges == [], "refused before anything is posted"


def test_another_approver_approves_and_the_merge_names_who_asked(tmp_path):
    s, fg, _ = tc.service(tmp_path)
    fg.approvers = {"jeff", "dawn"}
    asked_by(fg, 7, "jeff")
    code, out = tc.go(s, fg, tc.approve(), login="dawn", name="Dawn", email="dawn@example.com",
                      claims={"preferred_username": "dawn"})
    assert code == 200 and out["result"] == "done", out
    msg = fg.merges[0]["message"]
    assert "Requested-by: jeff\nApproved-by: Dawn <dawn@example.com>" in msg and "Self-approved" not in msg, msg


def test_the_only_approver_may_approve_their_own_change_and_the_merge_says_so(tmp_path):
    s, fg, _ = tc.service(tmp_path)
    asked_by(fg, 7, "jeff")                                      # fg.approvers == {"jeff"}
    code, out = tc.go(s, fg, tc.approve())
    assert code == 200 and out["result"] == "done", out
    msg = fg.merges[0]["message"]
    assert msg.rstrip().endswith("Requested-by: jeff\nApproved-by: Jeff <jeff@example.com>\nSelf-approved: sole approver"), msg
    assert "Self-approved" in fg.reviews[0][2]["body"] and "Self-approved: sole approver" in out["detail"]
    row = next(r for r in s.forge.changes()["applied"] if r["number"] == 7)
    assert row["requested_by"] == "jeff" and row["self_approved"] is True


def test_never_refuses_even_the_only_approver(tmp_path):
    s, fg, _ = tc.service(tmp_path, selfApproval="never")
    asked_by(fg, 7, "jeff")
    code, out = tc.go(s, fg, tc.approve())
    assert code == 403 and "selfApproval: never" in out["reason"], out
    assert fg.reviews == [] and fg.merges == []


def test_a_team_that_cannot_be_read_is_not_a_team_of_one(tmp_path):
    s, fg, _ = tc.service(tmp_path)
    fg.teams_readable = False
    asked_by(fg, 7, "jeff")
    code, out = tc.go(s, fg, tc.approve())
    assert code == 403 and "could not read who is in the approvers team" in out["reason"], out
    assert fg.reviews == [] and fg.merges == []


def test_a_change_no_person_asked_for_is_approved_as_before(tmp_path):
    s, fg, _ = tc.service(tmp_path)
    fg.teams_readable = False                                    # never consulted: the model watcher asked
    code, out = tc.go(s, fg, tc.approve())
    assert code == 200 and out["result"] == "done", out
    assert "Requested-by" not in fg.merges[0]["message"] and "Self-approved" not in fg.merges[0]["message"]


def test_the_asker_is_matched_without_regard_to_case(tmp_path):
    s, fg, _ = tc.service(tmp_path)
    fg.approvers = {"jeff", "dawn"}
    asked_by(fg, 7, "Jeff")
    code, out = tc.go(s, fg, tc.approve())
    assert code == 403 and "you asked for #7" in out["reason"], out


@pytest.mark.parametrize("bad", ["always", "yes", True])
def test_self_approval_takes_only_its_two_values(tmp_path, bad):
    with pytest.raises(ValueError, match="selfApproval"):
        act.parse(tc.actions_on(tmp_path, selfApproval=bad))


def test_the_default_is_sole_approver_only(tmp_path):
    assert act.parse(tc.actions_on(tmp_path)).changes_self_approval == "sole-approver-only"


# ---------------------------------------------------------------- show

def test_recently_applied_names_who_asked_and_badges_a_self_approval(tmp_path):
    c, csrf, idp, fg, sent = tc.wire(tmp_path)
    fg.pulls[5]["body"] += "\n\nTockmox-Requested-By: jeff\nTockmox-Origin: console"   # merged_by jeff (the fake)
    t = c.get("/platform/changes").text
    assert "(asked for by jeff)" in t and "Self-approved: sole approver" in t, t[-1500:]
    fg.pulls[5]["merged_by"] = {"login": "dawn", "full_name": "Dawn"}
    t = c.get("/platform/changes").text
    assert "(asked for by jeff)" in t and "Self-approved" not in t

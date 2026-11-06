# SPDX-License-Identifier: Apache-2.0
"""Platform > Capabilities, Console features; and Platform > Overview, Give to a role.

  set-feature   Platform Management turned on or off as one key in the AI layer's values
                (tockmoxUi.config.features.platform.enabled), the rest of the file kept; main already saying it opens
                nothing; only a feature the console knows, and only true or false
  assign-job    a scheduled job with no owner given to a role as features.platform.assign.<job>: <role> in the same
                file; the page offers it only for work listed with no owner now and only to a role in the catalog
  owner         the workload's tockmox.com/practice label first, then the assignment, then the catalog's patterns;
                an assignment naming no role is passed over

Run from tockmox-ui/: python -m pytest tests/test_console_features.py
"""
import base64
import copy
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402
from app import platform as pm  # noqa: E402
from tests import test_actions as base  # noqa: E402
from tests import test_changes as tc  # noqa: E402
from tests import test_open_change as oc  # noqa: E402
from tests.proto_support import _secret, world  # noqa: E402,F401  (fixtures)

AI = "site/values/ai.yaml"
AI_TEXT = """# The AI layer's own values.
tockmoxUi:
  enabled: true
  config:
    features:
      platform:
        timezone: America/Chicago   # the page's zone
open-webui:
  enableOpenaiApi: true
"""


def forge(text=AI_TEXT):
    fg = tc.Forge()
    fg.files["main"].update({AI: text, "site/values/global.yaml": "global: {}\n"})
    return fg


def written(fg):
    who, b = fg.contents_posts[-1]
    f = b["files"][0]
    return who, b, f, base64.b64decode(f["content"]).decode()


def item(**kw):
    b = {"kind": "CronJob", "namespace": "ns", "name": "job", "schedule": "0 * * * *", "timezone": "UTC",
         "suspended": False, "active": False, "last_run": None, "last_success": None, "next_run": None,
         "last_failed": None, "practice": None}
    return dict(b, **kw)


# ---------------------------------------------------------------- set-feature

def test_turning_platform_management_on_sets_one_key_in_ai_yaml(tmp_path):
    s, fg, _ = tc.service(tmp_path, forge())
    code, out = oc.confirm_and_open(s, "set-feature", {"feature": "platform", "enabled": True}, preferred_username="jeff")
    assert code == 200 and out["result"] == "done", out
    who, b, f, text = written(fg)
    assert who == "tockmox-change-bot" and f["path"] == AI
    assert yaml.safe_load(text)["tockmoxUi"]["config"]["features"]["platform"] == {"timezone": "America/Chicago",
                                                                                   "enabled": True}
    assert "# The AI layer's own values." in text and "# the page's zone" in text and "enableOpenaiApi: true" in text
    _, pr = fg.opened[-1]
    assert pr["title"] == "Turn Platform Management on" and "Tockmox-Requested-By: jeff" in pr["body"]


def test_main_already_saying_it_opens_nothing(tmp_path):
    s, fg, _ = tc.service(tmp_path, forge(AI_TEXT.replace("timezone: America/Chicago", "enabled: false")))
    code, out = oc.confirm_and_open(s, "set-feature", {"feature": "platform", "enabled": False}, preferred_username="jeff")
    assert code == 403 and "already says this" in out["reason"], out
    assert fg.opened == []


@pytest.mark.parametrize("t", [{"feature": "posture", "enabled": True}, {"feature": "platform", "enabled": "yes"},
                               {"feature": "platform", "enabled": True, "x": 1}, {}])
def test_check_refuses_what_is_not_a_known_feature_on_or_off(tmp_path, t):
    with pytest.raises(act.Refused, match="console feature"):
        act.check(act.parse(tc.actions_on(tmp_path)), act.intent("set-feature", t, {}, "a"))


def test_the_wording_says_what_appears_and_what_goes():
    on = act.describe(act.intent("set-feature", {"feature": "platform", "enabled": True}, {}, "a"))
    off = act.describe(act.intent("set-feature", {"feature": "platform", "enabled": False}, {}, "a"))
    assert "tockmoxUi.config.features.platform.enabled" in on["effect"] and "Overview" in on["effect"]
    assert "404" in off["effect"] and "turn Platform Management on again" in off["undo"]


# ---------------------------------------------------------------- assign-job

def test_giving_a_job_to_a_role_adds_one_line_and_keeps_the_rest(tmp_path):
    s, fg, _ = tc.service(tmp_path, forge())
    code, out = oc.confirm_and_open(s, "assign-job", {"job": "mystery-thing", "role": "continuity"},
                                    preferred_username="jeff")
    assert code == 200 and out["result"] == "done", out
    _, _, f, text = written(fg)
    plat = yaml.safe_load(text)["tockmoxUi"]["config"]["features"]["platform"]
    assert plat == {"timezone": "America/Chicago", "assign": {"mystery-thing": "continuity"}}
    assert "# the page's zone" in text
    assert fg.opened[-1][1]["title"] == "Give mystery-thing to continuity"


def test_a_second_job_joins_the_existing_map(tmp_path):
    text = AI_TEXT.replace("timezone: America/Chicago   # the page's zone",
                           "timezone: America/Chicago   # the page's zone\n        assign:\n          a-job: security")
    s, fg, _ = tc.service(tmp_path, forge(text))
    code, out = oc.confirm_and_open(s, "assign-job", {"job": "b-job", "role": "continuity"}, preferred_username="jeff")
    assert code == 200, out
    _, _, _, after = written(fg)
    assert yaml.safe_load(after)["tockmoxUi"]["config"]["features"]["platform"]["assign"] == {
        "a-job": "security", "b-job": "continuity"}


@pytest.mark.parametrize("t", [{"job": "Bad_Name", "role": "continuity"}, {"job": "ok", "role": "No Such"},
                               {"job": "ok", "role": "continuity", "ns": "x"}, {"job": "", "role": "continuity"},
                               {"job": "ok", "role": 3}])
def test_check_refuses_what_is_not_one_job_and_one_role(tmp_path, t):
    with pytest.raises(act.Refused, match="one scheduled job and one role"):
        act.check(act.parse(tc.actions_on(tmp_path)), act.intent("assign-job", t, {}, "a"))


# ---------------------------------------------------------------- who owns a job

def test_the_label_then_the_assignment_then_the_pattern():
    cat = pm.load_catalog()
    given = {"nightly-backup": "security", "mystery-thing": "continuity", "ghost": "no-such-role"}
    assert pm.owner_of(item(name="mystery-thing"), cat) is None
    assert pm.owner_of(item(name="mystery-thing"), cat, given) == "continuity"
    assert pm.owner_of(item(name="nightly-backup"), cat, given) == "security", "an assignment beats a pattern"
    assert pm.owner_of(item(name="nightly-backup", practice="continuity"), cat, given) == "continuity", "a label wins"
    assert pm.owner_of(item(name="ghost"), cat, given) is None, "a role the catalog lacks is passed over"


# ---------------------------------------------------------------- pages

def features_with_platform():
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    return {"features": dict(copy.deepcopy(doc["features"]), platform={"enabled": True})}


def test_capabilities_lists_platform_management_with_its_switch(tmp_path):
    c, *_ = base.console(tmp_path, actions=tc.actions_on(tmp_path), forge=forge().handler)
    t = c.get("/capabilities").text
    assert "Console features" in t and "Platform Management" in t
    assert "kind=set-feature&amp;feature=platform&amp;enabled=true" in t
    r = c.get("/actions/confirm?kind=set-feature&feature=platform&enabled=true")
    assert r.status_code == 200 and "+        enabled: true" in r.text, r.text[:800]


def test_with_platform_on_the_switch_turns_it_off(tmp_path):
    c, *_ = base.console(tmp_path, actions=tc.actions_on(tmp_path), forge=forge().handler, extra=features_with_platform())
    assert "kind=set-feature&amp;feature=platform&amp;enabled=false" in c.get("/capabilities").text


def test_with_changes_off_there_is_no_switch(tmp_path):
    c, *_ = base.console(tmp_path)
    t = c.get("/capabilities").text
    assert "Platform Management" in t and "kind=set-feature" not in t


@pytest.fixture
def platform_console(tmp_path):
    c, *_ = base.console(tmp_path, actions=tc.actions_on(tmp_path), forge=forge().handler, extra=features_with_platform())
    c.app.state.platform["unowned"] = lambda: ["mystery-thing"]
    return c


def test_the_confirm_panel_shows_the_line_for_unowned_work(platform_console):
    r = platform_console.get("/actions/confirm?kind=assign-job&job=mystery-thing&role=continuity")
    assert r.status_code == 200, r.text[:800]
    assert "+        assign:" in r.text and "+          mystery-thing: continuity" in r.text


@pytest.mark.parametrize("q,why", [("job=mystery-thing&role=no-such", "no role"),
                                   ("job=nightly-backup&role=continuity", "no owner now")])
def test_only_unowned_work_and_only_a_catalog_role(platform_console, q, why):
    r = platform_console.get(f"/actions/confirm?kind=assign-job&{q}")
    assert r.status_code == 409 and why in r.text, r.text[:800]


def test_without_platform_management_there_is_nothing_to_give(tmp_path):
    c, *_ = base.console(tmp_path, actions=tc.actions_on(tmp_path), forge=forge().handler)
    r = c.get("/actions/confirm?kind=assign-job&job=mystery-thing&role=continuity")
    assert r.status_code == 409 and "Platform Management is not on" in r.text


def test_the_overview_offers_give_to_a_role_beside_unowned_work(world, tmp_path):
    from tests.test_platform import NOW, add_cronjob, client_for, doc_with_platform, healthy_signals, login_as
    from app.cronexpr import Cron
    healthy_signals(world)
    prev = Cron("0 3 * * *").prev_before(NOW)
    add_cronjob(world, "x", "mystery-thing", "0 3 * * *", last_run=prev, last_ok=prev + 60, nxt=prev + 86400)
    for on in (True, False):
        doc = doc_with_platform()
        if on:
            doc["actions"] = dict(tc.actions_on(tmp_path), url="http://actions.test")
        c, app, s = client_for(world, doc, cronworkflows=[])
        login_as(c, s, ["tockmox-admins"])
        o = c.get("/platform").text
        assert "mystery-thing" in o
        assert ('name="kind" value="assign-job"' in o and 'value="mystery-thing"' in o
                and '<option value="continuity">' in o) is on, o[-3000:]
        assert app.state.platform["unowned"]() == ["mystery-thing"]


def test_an_assignment_moves_the_job_off_the_unowned_list(world):
    from tests.test_platform import NOW, add_cronjob, client_for, doc_with_platform, healthy_signals, login_as
    from app.cronexpr import Cron
    healthy_signals(world)
    prev = Cron("0 3 * * *").prev_before(NOW)
    add_cronjob(world, "x", "mystery-thing", "0 3 * * *", last_run=prev, last_ok=prev + 60, nxt=prev + 86400)
    c, app, s = client_for(world, doc_with_platform(assign={"mystery-thing": "continuity"}), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    assert "Scheduled work with no owner" not in c.get("/platform").text
    assert "mystery-thing" in c.get("/platform/agents/continuity").text

# SPDX-License-Identifier: Apache-2.0
"""Platform > Capabilities: turn a capability on or off as a change to the site values.

  plan     the change sets only capabilities.<name>.enabled in site/values/global.yaml (the file every layer reads),
           keeps the rest of the file and its comments, records who asked, and waits for an approval
  refuse   a layer's own values file that also sets the capability (that layer reads it after global.yaml, so the
           change would say one thing while the site did another); main already saying it; single sign-on OFF (the
           console signs in through it, so that change would lock out whoever approves it); a name that is not one
           of the eight; anything but true or false
  page     an administrator sees Turn on or Turn off per row when the change kinds are on; never Turn off for single
           sign-on; nothing when they are off; the confirm panel shows the diff before anyone confirms

Run from tockmox-ui/: python -m pytest tests/test_set_capability.py
"""
import base64
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402
from tests import test_actions as base  # noqa: E402
from tests import test_changes as tc  # noqa: E402
from tests import test_open_change as oc  # noqa: E402

GLOBAL = "site/values/global.yaml"
GLOBAL_TEXT = """# Written by tockmox-install.sh; every layer reads this file.
global:
  internalDomain: example.com   # the site's own domain
  siteForge: built-in
capabilities:
  hardwareTelemetry:
    enabled: false   # a VM: nothing to poll
"""


def forge(**files):
    fg = tc.Forge()
    fg.files["main"].update({GLOBAL: GLOBAL_TEXT, "site/values/ai.yaml": "tockmoxUi:\n  enabled: true\n"}, **files)
    return fg


def setcap(s, cap, enabled, **tok):
    return oc.confirm_and_open(s, "set-capability", {"capability": cap, "enabled": enabled},
                               preferred_username="jeff", **tok)


def written(fg):
    who, b = fg.contents_posts[-1]
    f = b["files"][0]
    return who, b, f, base64.b64decode(f["content"]).decode()


# ---------------------------------------------------------------- plan

def test_turning_one_on_edits_only_its_switch_in_global_yaml(tmp_path):
    s, fg, _ = tc.service(tmp_path, forge())
    code, out = setcap(s, "hardwareTelemetry", True)
    assert code == 200 and out["result"] == "done", out
    who, b, f, text = written(fg)
    assert who == "tockmox-change-bot" and f["path"] == GLOBAL and b["new_branch"].startswith("tockmox/console-capability-hardwaretelemetry-")
    # Only the switch's own line changes; its old comment described the old value and goes with it.
    assert text == GLOBAL_TEXT.replace("    enabled: false   # a VM: nothing to poll", "    enabled: true"), text
    assert "# Written by tockmox-install.sh" in text and "internalDomain: example.com   # the site's own domain" in text
    assert yaml.safe_load(text)["global"] == yaml.safe_load(GLOBAL_TEXT)["global"]
    _, pr = fg.opened[-1]
    assert pr["title"] == "Turn Hardware telemetry on" and "Tockmox-Requested-By: jeff" in pr["body"]
    assert fg.reviews == [] and fg.merges == []


def test_turning_one_off_adds_its_switch_when_global_yaml_has_none(tmp_path):
    s, fg, _ = tc.service(tmp_path, forge())
    code, out = setcap(s, "dataProtection", False)
    assert code == 200 and out["result"] == "done", out
    _, _, _, text = written(fg)
    doc = yaml.safe_load(text)
    assert doc["capabilities"] == {"hardwareTelemetry": {"enabled": False}, "dataProtection": {"enabled": False}}
    assert "# a VM: nothing to poll" in text


def test_a_layer_file_that_also_sets_it_is_refused_and_named(tmp_path):
    fg = forge(**{"site/values/platform.yaml": "capabilities:\n  dataProtection:\n    enabled: true\n"})
    s, fg, _ = tc.service(tmp_path, fg)
    code, out = setcap(s, "dataProtection", False)
    assert code == 403 and "site/values/platform.yaml" in out["reason"], out
    assert fg.contents_posts == [] and fg.opened == []


def test_a_layer_file_setting_another_capability_does_not_block_this_one(tmp_path):
    fg = forge(**{"site/values/platform.yaml": "capabilities:\n  observability:\n    enabled: true\n"})
    s, fg, _ = tc.service(tmp_path, fg)
    code, out = setcap(s, "dataProtection", False)
    assert code == 200 and out["result"] == "done", out


def test_what_main_already_says_opens_nothing(tmp_path):
    s, fg, _ = tc.service(tmp_path, forge())
    code, out = setcap(s, "hardwareTelemetry", False)
    assert code == 403 and "nothing to change" in out["reason"], out
    assert fg.opened == []


def test_single_sign_on_is_never_turned_off_from_the_console(tmp_path):
    s, fg, _ = tc.service(tmp_path, forge())
    code, out = setcap(s, "identity", False)
    assert code == 403 and "lock out" in out["reason"], out
    assert fg.opened == []
    fg.files["main"][GLOBAL] = GLOBAL_TEXT + "  identity:\n    enabled: false\n"
    code, out = setcap(s, "identity", True)
    assert code == 200 and out["result"] == "done", out


@pytest.mark.parametrize("target", [
    {"capability": "backups", "enabled": True},
    {"capability": "dataProtection", "enabled": "false"},
    {"capability": "dataProtection", "enabled": True, "layer": "platform"},
    {"capability": "dataProtection"},
])
def test_check_refuses_anything_but_one_of_the_eight_and_true_or_false(tmp_path, target):
    with pytest.raises(act.Refused, match="one of the eight"):
        act.check(act.parse(tc.actions_on(tmp_path)), act.intent("set-capability", target, {}, "a"))


def test_it_is_a_change_kind_and_no_step_up(tmp_path):
    on = act.parse(tc.actions_on(tmp_path))
    assert on.on("set-capability") and not act.step_up("set-capability")
    assert not act.parse(dict(base.ACTIONS, url="http://a.test")).on("set-capability")


# ---------------------------------------------------------------- page

def page(tmp_path, on=True, caps=None):
    fg = forge()
    a = tc.actions_on(tmp_path) if on else None
    c, csrf, idp, am, kube, sent = base.console(tmp_path, actions=a, forge=fg.handler,
                                                extra={"capabilities": caps or {"identity": True, "dataProtection": True,
                                                                                "hardwareTelemetry": False}})
    return c, fg


def test_the_page_offers_turn_on_and_turn_off_but_never_sso_off(tmp_path):
    c, _ = page(tmp_path)
    t = c.get("/capabilities").text
    assert "kind=set-capability&amp;capability=dataProtection&amp;enabled=false\">Turn off" in t
    assert "kind=set-capability&amp;capability=hardwareTelemetry&amp;enabled=true\">Turn on" in t
    assert "capability=identity&amp;enabled=false" not in t
    assert "waits on Platform › Changes" in t


def test_off_means_no_buttons(tmp_path):
    c, _ = page(tmp_path, on=False)
    t = c.get("/capabilities").text
    assert "set-capability" not in t and "this page changes nothing" in t


def test_the_confirm_panel_shows_the_diff_before_anything_is_opened(tmp_path):
    c, fg = page(tmp_path)
    r = c.get("/actions/confirm?kind=set-capability&capability=hardwareTelemetry&enabled=true")
    assert r.status_code == 200, r.text[:500]
    assert "Turn Hardware telemetry on?" in r.text and "+    enabled: true" in r.text
    assert fg.opened == [], "previewing opens nothing"

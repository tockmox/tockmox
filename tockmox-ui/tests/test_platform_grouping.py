# SPDX-License-Identifier: Apache-2.0
"""Platform's rail and pages (specs/tockmox-ui/SPEC.md section 8 in the planning repo).

  grouping      Needs you groups by alert name and what it asks; 13 cases for one alert on 6 hosts are one row
  filters       a group opens the Cases page filtered to exactly its cases
  organization  the roles one team at a time, "Not started" folded; the Overview keeps one line per team
  rail          Organization joins the rail; Capabilities carries a warning when a switch and the deployment disagree,
                and Unknown when Argo CD does not answer
  notes         Updates renders the release notes in folded sections, never raw markdown

Run from tockmox-ui/: python -m pytest tests
"""
import copy
import re

import pytest

from tests.proto_support import _secret, world  # noqa: F401  (fixtures)
from tests.test_platform_cases import FIX, Host, cases_client
from app import platform_cases as pc


def rec(rid, alert, host, on="jeff", ask="no_target", since="2026-10-31T10:00:00.000Z"):
    r = copy.deepcopy(FIX["list"]["records"][1])
    r.update({"id": rid, "trace_id": rid, "service": host, "title": f"{alert} on {host}" if alert else "a single",
              "facts": {"alertname": alert} if alert else {}})
    r["waiting"] = {"on": on, "ask": ask, "reason": "decision", "since": since}
    return r


def oct31():
    """The 2026-10-31 shape: 19 cases waiting on Jeff read as 5 groups."""
    rows = []
    n = 0
    for i in range(13):                                         # node-exporter, 6 hosts
        n += 1
        rows.append(rec(f"INC-{n:04d}", "NodeFilesystemSpaceFillingUp", f"node-{i % 6}"))
    for i in range(3):                                          # kube-state-metrics
        n += 1
        rows.append(rec(f"INC-{n:04d}", "KubeDeploymentReplicasMismatch", f"ns/app{i}", ask="cannot_explain"))
    for i in range(3):                                          # singles: no alert name
        n += 1
        rows.append(rec(f"INC-{n:04d}", "", "", ask="decision"))
    return rows


def clean(rows):
    return [pc.clean_summary(r) for r in rows]


def test_nineteen_cases_read_as_five_groups_and_thirteen_on_six_hosts_is_one_row():
    groups = pc.group_cases(clean(oct31()))
    assert len(groups) == 5
    node = next(g for g in groups if g["alert"] == "NodeFilesystemSpaceFillingUp")
    assert node["count"] == 13 and len(node["hosts"]) == 6
    assert node["href"] == "/platform/cases?alert=NodeFilesystemSpaceFillingUp&wait=jeff&ask=no_target"
    singles = [g for g in groups if g["count"] == 1]
    assert len(singles) == 3 and all(g["href"].startswith("/platform/cases/INC-") for g in singles)


def test_the_same_alert_asking_two_different_things_is_two_groups():
    rows = clean([rec("INC-0001", "X", "a"), rec("INC-0002", "X", "b", ask="cannot_explain")])
    assert len(pc.group_cases(rows)) == 2


def test_a_group_opens_exactly_its_cases(world):
    fix = copy.deepcopy(FIX)
    fix["list"]["records"] = oct31()
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases?alert=NodeFilesystemSpaceFillingUp&wait=jeff&ask=no_target").text
    assert t.count("NodeFilesystemSpaceFillingUp on node-") == 13
    assert "KubeDeploymentReplicasMismatch on" not in t
    assert "Showing 13 of 19 cases" in t and "Clear the filters" in t


def test_an_unknown_filter_value_shows_nothing_and_says_so(world):
    fix = copy.deepcopy(FIX)
    fix["list"]["records"] = oct31()
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases?team=no-such-team").text
    assert "Showing 0 of 19 cases" in t


def test_a_group_keyed_on_its_reason_or_on_nothing_still_opens_exactly_its_cases(world):
    # Fresh-eyes review B (claude-sonnet-5-5), finding 1: the link must carry the whole key, or the list widens.
    def r(rid, host, on="jeff", reason="decision"):
        x = rec(rid, "X", host, on=on, ask="")
        x["waiting"]["reason"] = reason
        return x
    a, b = r("INC-0001", "h1"), r("INC-0002", "h2")                     # no ask: grouped on the reason
    other = r("INC-0003", "h3", on="agent")                              # same alert, waits on someone else
    paged = r("INC-0004", "h4", reason="paged")                          # same alert and wait, another reason
    blank1, blank2 = r("INC-0005", "h5", on="", reason=""), r("INC-0006", "h6", on="", reason="")  # says nothing
    rows = clean([a, b, other, paged, blank1, blank2])
    groups = {g["href"]: g for g in pc.group_cases(rows) if g["count"] > 1}
    assert set(groups) == {"/platform/cases?alert=X&wait=jeff&ask=decision", "/platform/cases?alert=X&wait=unknown&ask=-"}
    fix = copy.deepcopy(FIX)
    fix["list"]["records"] = [a, b, other, paged, blank1, blank2]
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases?alert=X&wait=jeff&ask=decision").text
    assert "Showing 2 of 6 cases" in t and "X on h1" in t and "X on h2" in t
    assert not any(f"X on h{i}" in t for i in (3, 4, 5, 6))
    t = c.get("/platform/cases?alert=X&wait=unknown&ask=-").text
    assert "Showing 2 of 6 cases" in t and "X on h5" in t and "X on h6" in t and "X on h1" not in t
    assert '<option value="unknown" selected>unknown</option>' in t     # the form keeps the filter it has no word for


def test_odd_filter_values_match_nothing_rather_than_everything(world):
    # Fresh-eyes review B, findings 2 and 5: a long value is not dropped, an unknown state is not ignored.
    fix = copy.deepcopy(FIX)
    fix["list"]["records"] = oct31()
    c, _ = cases_client(world, Host(fix))
    assert "Showing 0 of 19 cases" in c.get("/platform/cases?state=garbage").text
    assert "not a state this page knows" in c.get("/platform/cases?state=garbage").text
    long = "A" * 200
    t = c.get(f"/platform/cases?alert={long}").text
    assert "Showing 0 of 19 cases" in t and f"<code>{long}</code>" in t
    t = c.get("/platform/cases?alert=%3Cscript%3E&wait=%C3%A9").text
    assert "<script>" not in t and "&lt;script&gt;" in t and "Showing 0 of 19 cases" in t


def test_the_overview_shows_groups_and_one_line_per_team(world):
    fix = copy.deepcopy(FIX)
    fix["list"]["records"] = oct31()
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform").text
    table = t.split('<table class="cases grouped">', 1)[1].split("</table>", 1)[0]
    assert table.count("<tr>") == 6                              # header + 5 groups
    assert re.search(r"<code>NodeFilesystemSpaceFillingUp</code></a></th>\s*<td class=\"num\">13 <span class=\"muted small\">on 6 hosts", table)
    assert 'class="team-lines plain"' in t and '<table class="team">' not in t
    assert t.count('href="/platform/organization?team=') >= 3


def test_organization_shows_one_team_and_folds_not_started(world):
    c, _ = cases_client(world)
    t = c.get("/platform/organization").text
    assert t.count('<section class="team-block"') == 1 and 'aria-current="page"' in t.split('aria-label="Teams"', 1)[1]
    assert "Not started" in t
    assert c.get("/platform/organization?team=nope").status_code == 404


def test_the_rail_has_organization(world):
    c, _ = cases_client(world)
    rail = re.search(r'<nav class="rail".*?</nav>', c.get("/platform/cases").text, re.S).group(0)
    assert "Organization" in rail and rail.index(">Cases<") < rail.index(">Organization<") < rail.index(">Schedule<")


def test_the_capabilities_rail_item_warns_on_disagreement_and_is_unknown_without_argo_cd(tmp_path):
    from tests.test_status_api import World, admin, app_obj
    from tests.test_testing_feedback import CONF, with_resources
    world = World()
    world.apps = [app_obj(n, rev="v0.8.0", path=f"charts/{n}") for n in ("tockmox-platform", "tockmox-observability")]
    with_resources(world, "tockmox-observability", [("Prometheus", "tockmox-observability-kube-prometheus"),
                                                    ("Deployment", "tockmox-ntfy")])
    with_resources(world, "tockmox-platform", [("Deployment", "tockmox-platform-traefik")])   # dataProtection on, no garage

    def item():
        c = admin(tmp_path, world, tweak=lambda d: d.update({"capabilities": CONF}))
        rail = re.search(r'<nav class="rail".*?</nav>', c.get("/capabilities").text, re.S).group(0)
        return re.search(r'<a href="/capabilities"[^>]*>.*?</a>', rail, re.S).group(0)
    assert 'class="rs st-warning"' in item() and "not what is deployed" in item()
    world.down.add("kube")
    assert 'class="rs st-unknown"' in item() and "Argo CD did not answer" in item()


def test_updates_folds_the_release_notes_and_renders_no_raw_markdown(world, tmp_path):
    from tests.test_status_api import World, make_client
    notes = tmp_path / "CHANGELOG.md"
    notes.write_text("# Changelog\n\n## [Unreleased]\n\n### Added\n\n- **Bold thing** with `code` and [a link](https://example.com).\n\n### Fixed\n\n- A fix.\n")
    w = World()
    for a in w.apps:                                            # a commit, not a release: the notes this build carries
        a["spec"]["source"]["targetRevision"] = "0123456789abcdef0123456789abcdef01234567"
    t = make_client(tmp_path, w, groups=["tockmox-admins"], notes_path=str(notes)).get("/platform/updates").text
    sec = t.split('id="notes-h"', 1)[1].split("</section>", 1)[0]
    assert sec.count('<details class="fold">') == 2
    assert "<strong>Bold thing</strong>" in sec and "<code>code</code>" in sec
    assert "**" not in sec and "](" not in sec

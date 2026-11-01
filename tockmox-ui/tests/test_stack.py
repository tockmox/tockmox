# SPDX-License-Identifier: Apache-2.0
"""TM-1305: Status draws the stack (specs/tockmox-ui/SPEC.md section 5 in the planning repo).

  placing    every signal on exactly one part: app globs, layer claims, site apps, alert labels and
             globs, namespaces, Unplaced last and shown first
  counting   four signals about one backup are one part, everywhere (pill, summary, Status)
  absence    a part nothing reports on, or whose source did not answer, is Unknown, never OK
  showing    a band or part the install does not deploy is absent; while Argo CD cannot be read, it shows
  the page   /status/<part> opens the drawer without JavaScript; List and Only problems; Go to buttons
  the site   `stack:` in the config extends the shipped stack, and a bad one stops the UI at start

Run from tockmox-ui/: python -m pytest tests
"""
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import stack  # noqa: E402
from app.config import ConfigError  # noqa: E402
from app.sources import Reading  # noqa: E402
from tests.test_status_api import World, app_obj, make_client  # noqa: E402

NOW = time.time()


def R(source, state="ok", data=None, reason=""):
    return Reading(source, state, data, reason, NOW, NOW)


def layer(name, health="Healthy", sync="Synced", resources=(), namespace=""):
    return {"name": f"tockmox-{name}", "path": f"charts/tockmox-{name}", "sync": sync, "health": health,
            "namespace": namespace, "resources": tuple(resources), "reconciledAt": NOW}


def site(name, health="Healthy", sync="Synced", namespace=""):
    return {"name": name, "path": "apps/" + name, "sync": sync, "health": health, "namespace": namespace,
            "resources": (), "reconciledAt": NOW}


ALL = ["crds", "policy", "platform", "observability", "exporters", "identity", "ai", "selfcheck"]


def readings(apps=None, alerts=None, nodes=None, targets=None, am_state="ok", apps_state="ok"):
    apps = [layer(x) for x in ALL] if apps is None else apps
    return {
        "apps": R("Argo CD applications", apps_state, apps) if apps_state != "unread" else Reading("Argo CD applications", "unknown", None, "refused", None, None),
        "nodes": R("Nodes", "ok", nodes if nodes is not None else [{"name": "n1", "ready": "Ready", "version": "v1"}]),
        "prometheus": R("Prometheus", "ok", targets if targets is not None else [{"job": "prometheus", "instance": "p:9090", "namespace": "tockmox-monitoring", "up": True}]),
        "alertmanager": R("Alertmanager", am_state, [{"name": "Watchdog", "severity": "none", "namespace": "", "component": ""}] + (alerts or []),
                          "no Watchdog heartbeat" if am_state == "unknown" else ""),
    }


def alert(name, ns="", sev="warning", comp="", summary="x"):
    return {"name": name, "severity": sev, "namespace": ns, "component": comp, "summary": summary, "startsAt": ""}


def place(rd, s=None, **kw):
    return stack.place(s or stack.load(), rd, ("Watchdog", "TockmoxHeartbeat", "InfoInhibitor"), **kw)


# ------------------------------------------------------------ the shipped stack

def test_the_shipped_stack_loads_and_every_part_id_is_unique():
    s = stack.load()
    ids = [p.id for p in s.side] + [p.id for b in s.bands for p in b.parts]
    assert len(ids) == len(set(ids)) and "unplaced" not in ids
    assert [b.id for b in s.bands][0] == "site" and [b.id for b in s.bands][-1] == "hosts"


def test_every_runbook_in_the_shipped_stack_exists():
    docs = Path(__file__).resolve().parent.parent.parent / "docs"
    s = stack.load()
    for p in list(s.side) + [p for b in s.bands for p in b.parts]:
        if p.runbook:
            assert (docs / p.runbook).is_file(), (p.id, p.runbook)


def test_a_healthy_install_is_every_part_ok():
    pl = place(readings())
    assert pl.counts()["ok"] == len(pl.all()) and pl.state() == "ok"
    assert stack.summary(pl).startswith("Every part is OK")
    assert stack.pill(pl)["parts"] == ["All healthy"]


# ------------------------------------------------------------ placing and counting

def test_four_signals_about_one_backup_are_one_part():
    apps = [layer(x) for x in ALL] + [site("forgejo", namespace="forgejo"),
                                      site("forgejo-backup", health="Degraded", namespace="forgejo")]
    rd = readings(apps, alerts=[alert("ForgejoBackupMissed", "forgejo"), alert("KubeJobFailed", "forgejo"),
                                alert("KubePodNotReady", "forgejo")])
    pl = place(rd)
    fj = pl.by_id["site-forgejo"]
    assert fj.state == "critical" and len(fj.wrong) == 4 and fj.count == "4"
    assert pl.counts() == {"critical": 1, "warning": 0, "unknown": 0, "ok": len(pl.all()) - 1}
    assert stack.pill(pl)["parts"] == ["1 problem"]
    assert stack.summary(pl).startswith("1 part needs a look: 1 problem.")
    assert fj.part.site and fj.band_name == "Site apps"


def test_an_alert_can_name_its_part_outright():
    pl = place(readings(alerts=[alert("AnythingAtAll", "kube-system", comp="databases")]))
    assert pl.by_id["databases"].state == "warning"
    assert "unplaced" not in pl.by_id


def test_an_alert_glob_beats_the_namespace():
    pl = place(readings(alerts=[alert("TockmoxLonghornVolumeDegraded", "tockmox-platform")]))
    assert pl.by_id["storage"].state == "warning"
    assert pl.by_id["layer-platform"].state == "ok"


def test_an_alert_in_a_layer_namespace_lands_on_that_layer():
    pl = place(readings(alerts=[alert("KubePodCrashLooping", "tockmox-platform")]))
    assert pl.by_id["layer-platform"].state == "warning"


def test_an_alert_no_part_claims_is_unplaced_and_shown_first():
    pl = place(readings(alerts=[alert("SomethingNew", "kube-system")]))
    assert pl.bands[0].band.id == "unplaced" and pl.by_id["unplaced"].state == "warning"


def test_a_degraded_layer_lands_on_the_part_that_claims_it():
    apps = [layer(x) for x in ALL if x != "identity"] + [layer("identity", health="Degraded")]
    pl = place(readings(apps))
    assert pl.by_id["authentik"].state == "critical"


def test_a_stale_application_is_a_warning_with_its_last_known_state():
    pl = place(readings(), stale_apps={"tockmox-crds"})
    crd = pl.by_id["crds"]
    assert crd.state == "warning" and "not reconciled recently" in crd.wrong[0]["detail"]


def test_a_node_not_ready_is_a_problem_on_cluster_nodes():
    pl = place(readings(nodes=[{"name": "n1", "ready": "Ready"}, {"name": "n2", "ready": "NotReady"}]))
    cn = pl.by_id["cluster-nodes"]
    assert cn.state == "critical" and cn.count == "1/2"


def test_a_scrape_target_down_lands_by_namespace():
    t = [{"job": "authentik", "instance": "a:9300", "namespace": "tockmox-authentik", "up": False}]
    pl = place(readings(targets=t))
    # tockmox-authentik is the identity band's namespace; Authentik claims the identity layer
    assert pl.by_id["authentik"].state == "warning"


def test_site_apps_group_under_the_app_they_extend():
    assert stack.site_groups(["forgejo", "forgejo-backup", "paperless", "site-monitoring"]) == \
        {"forgejo": "forgejo", "forgejo-backup": "forgejo", "paperless": "paperless", "site-monitoring": "site-monitoring"}


def test_site_apps_and_site_secrets_belong_to_argo_cd():
    apps = [layer(x) for x in ALL] + [site("site-apps"), site("site-secrets", sync="OutOfSync")]
    pl = place(readings(apps))
    assert pl.by_id["argocd"].state == "warning" and "site-site-secrets" not in pl.by_id


# ------------------------------------------------------------ absence is not green

def test_without_the_alert_pipeline_alert_only_parts_are_unknown_never_ok():
    pl = place(readings(am_state="unknown"))
    for pid in ("ingress", "certificates", "identity-database", "logs"):
        assert pl.by_id[pid].state == "unknown", pid
        assert "Watchdog" in pl.by_id[pid].reason
    assert stack.pill(pl)["state"] == "unknown"


def test_argo_cd_unreadable_shows_every_band_as_unknown_rather_than_hiding_it():
    pl = place(readings(apps_state="unread"))
    ids = {b.band.id for b in pl.bands}
    assert {"services", "platform", "foundation"} <= ids
    assert pl.by_id["crds"].state == "unknown"


def test_a_part_with_nothing_reporting_on_it_is_unknown():
    s = stack.parse({"version": 1, "bands": [{"id": "x", "name": "X", "parts": [{"id": "lonely", "name": "Lonely"}]}]})
    pl = place(readings(), s)
    assert pl.by_id["lonely"].state == "unknown" and pl.by_id["lonely"].reason == "Nothing reports on this part."


# ------------------------------------------------------------ what this install deploys

def test_a_band_whose_layers_are_absent_is_not_drawn():
    pl = place(readings([layer(x) for x in ALL if x not in ("identity",)]))
    assert "identity" not in {b.band.id for b in pl.bands}


def test_a_part_whose_component_is_not_deployed_is_absent_not_locked():
    apps = [layer(x) for x in ALL if x != "platform"] + [layer("platform", resources=[("StatefulSet", "garage")])]
    pl = place(readings(apps))
    assert "object-store" in pl.by_id and "reboots" not in pl.by_id


def test_inference_nodes_appear_only_when_the_source_is_configured():
    assert "inference-nodes" not in place(readings()).by_id
    rd = readings()
    rd["inference_nodes"] = R("Inference nodes", "ok", [{"id": "m5", "name": "M5", "state": "ok"}])
    pl = place(rd)
    assert pl.by_id["inference-nodes"].count == "1/1"


# ------------------------------------------------------------ the site's extension

def test_a_site_adds_a_part_and_a_band():
    s = stack.load(site={"bands": [{"id": "platform", "parts": [{"id": "dns", "name": "DNS", "alerts": ["CoreDNS*"]}]},
                                   {"id": "addons", "name": "Add-ons", "parts": [{"id": "posture", "name": "Posture probe", "alerts": ["Posture*"]}]}]})
    assert [b.id for b in s.bands][:2] == ["site", "addons"]
    pl = place(readings(alerts=[alert("CoreDNSDown", "kube-system")]), s)
    assert pl.by_id["dns"].state == "warning"


@pytest.mark.parametrize("bad", [
    {"bands": [{"id": "Bad Id"}]},
    {"bands": [{"id": "x", "parts": [{"id": "storage"}]}]},        # duplicates a shipped part
    {"bands": [{"id": "x", "parts": [{"id": "y", "source": "dns"}]}]},
    {"bands": [{"id": "x", "parts": [{"id": "y", "runbook": "/etc/passwd"}]}]},
    {"bands": [{"id": "x", "parts": [{"id": "y", "when": [["ai", "Deployment"]]}]}]},
    {"colour": "red"},
    {"bands": 5},
    {"bands": [{"id": "x", "parts": [{"id": "y", "when": 5}]}]},
    {"bands": [{"id": "x", "parts": [{"id": "y", "alerts": {"a": 1}}]}]},
    {"bands": [{"id": "x", "parts": [{"id": "y", "alerts": ["A*"], "trend": "part-volum"}]}]},   # TM-1306: a typo
    {"bands": [{"id": "x", "parts": [{"id": "y", "alerts": ["A*"], "trend": "alerts-firing"}]}]},  # not a part panel
])
def test_a_malformed_site_stack_stops_the_ui_at_start(tmp_path, bad):
    with pytest.raises(ConfigError):
        make_client(tmp_path, World(), tweak=lambda d: d.update({"stack": bad}))


# ------------------------------------------------------------ the page

@pytest.fixture
def world():
    w = World()
    w.apps = [app_obj(f"tockmox-{x}", path=f"charts/tockmox-{x}") for x in ALL] + \
             [app_obj("forgejo"), app_obj("forgejo-backup", health="Degraded")]
    for a in w.apps[-2:]:
        a["spec"]["destination"] = {"namespace": "forgejo"}
    return w


def adm(tmp_path, world, **kw):
    return make_client(tmp_path, world, groups=["tockmox-admins"], **kw)


def test_status_draws_every_band_and_each_part_links_to_its_drawer(tmp_path, world):
    t = adm(tmp_path, world).get("/status").text
    for band in ("Site apps", "Services", "Identity", "Observability", "Platform", "Foundation", "Hosts"):
        assert f">{band}</h2>" in t, band
    assert '<a class="part st-critical" href="/status/site-forgejo">' in t
    assert 'data-roving' in t and 'class="side part' in t
    assert "1 part needs a look: 1 problem." in t


def test_the_drawer_opens_at_its_own_url_without_javascript(tmp_path, world):
    t = adm(tmp_path, world).get("/status/site-forgejo").text
    aside = t.split('<aside class="drawer', 1)[1].split("</aside>", 1)[0]
    assert '<h2 id="drawer-h">Forgejo</h2>' in aside and "forgejo-backup application" in aside
    assert "Synced · Degraded" in aside and 'href="/status"' in aside          # Close goes back to the stack
    assert 'aria-current="true"' in t.split('<aside', 1)[0]


def test_an_unknown_part_is_404(tmp_path, world):
    assert adm(tmp_path, world).get("/status/no-such-part").status_code == 404


def test_status_parts_are_for_admins(tmp_path, world):
    assert make_client(tmp_path, world, groups=["tockmox-users"]).get("/status/site-forgejo").status_code == 403


def test_list_view_is_the_same_content_worst_first(tmp_path, world):
    t = adm(tmp_path, world).get("/status?view=list").text
    body = t.split('<table class="parts-table">', 1)[1].split("</tbody>", 1)[0]
    rows = body.split("<tr>")[2:]
    assert "Forgejo" in rows[0] and "st-critical" in rows[0]
    assert body.count("<tr>") - 1 == len(rows)
    assert 'aria-current="page">List' in t


def test_only_problems_folds_ok_parts_to_a_count_per_band(tmp_path, world):
    t = adm(tmp_path, world).get("/status?only=problems").text
    stack_html = t.split('<div class="bands">', 1)[1].split('<section class="panel', 1)[0]
    assert "site-forgejo" in stack_html and "/status/storage" not in stack_html
    assert '<li class="folded muted small">' in stack_html and 'class="toggle on"' in t and "Only problems<span class=\"visually-hidden\">: on" in t
    # the drawer keeps the view and the filter
    assert 'href="/status/site-forgejo?only=problems"' in t


def test_go_to_shows_only_what_the_viewer_can_open(tmp_path, world):
    t = adm(tmp_path, world).get("/status/storage").text
    aside = t.split('<aside', 1)[1].split("</aside>", 1)[0]
    assert 'href="https://grafana.int.example.com/d/tockmox-storage-contract"' in aside
    assert 'href="https://longhorn.int.example.com"' in aside
    assert "docs/administration/storage.md" in aside
    assert "Argo CD app" not in aside                       # no argocd console configured in the example
    assert "<code>TockmoxLonghorn*</code>" in aside          # what the part watches, so "Nothing is wrong" can be checked


def test_go_to_argo_cd_names_the_failing_application(tmp_path, world):
    add = {"id": "argocd", "name": "Argo CD", "url": "https://argocd.int.example.com", "icon": "sync", "groups": ["tockmox-admins"]}
    t = adm(tmp_path, world, tweak=lambda d: d["apps"].append(add)).get("/status/site-forgejo").text
    assert 'href="https://argocd.int.example.com/applications/argocd/forgejo-backup"' in t


def test_the_pill_counts_parts_on_every_admin_page(tmp_path, world):
    world.alerts.append({"labels": {"alertname": "ForgejoBackupMissed", "severity": "warning", "namespace": "forgejo"},
                         "annotations": {"summary": "x"}})
    t = adm(tmp_path, world).get("/models").text
    pill = t.split('class="hpill', 1)[1].split("</a>", 1)[0]
    words = pill.split(">", 1)[1]
    assert pill.startswith(' st-critical"') and "1 problem" in words and "warning" not in words   # four signals, one part


# ------------------------------------------------------------ fresh-eyes review (claude-sonnet-5-5 via the gateway)

def test_review_a_silent_source_outranks_a_warning():
    rd = readings(targets=[{"job": "x", "instance": "x:1", "namespace": "", "up": False}], am_state="unknown")
    m = place(rd).by_id["metrics"]
    assert m.state == "unknown" and "Watchdog" in m.reason and m.wrong


def test_review_an_empty_whole_reading_is_unknown():
    pl = place(readings(nodes=[]))
    assert pl.by_id["cluster-nodes"].state == "unknown" and "empty" in pl.by_id["cluster-nodes"].reason


def test_review_a_source_the_ui_does_not_read_is_not_a_pass():
    rd = readings()
    del rd["alertmanager"]
    assert place(rd).by_id["authentik"].state == "unknown"


def test_review_an_odd_inference_state_does_not_crash():
    rd = readings()
    rd["inference_nodes"] = R("Inference nodes", "ok", [{"id": "m5", "name": "M5", "state": "degraded"}])
    assert place(rd).by_id["inference-nodes"].state == "unknown"


def test_review_the_worst_signal_leads():
    apps = [layer(x) for x in ALL] + [site("forgejo", sync="OutOfSync", namespace="forgejo")]
    pv = place(readings(apps, alerts=[alert("ForgejoDown", "forgejo", sev="critical")])).by_id["site-forgejo"]
    assert pv.wrong[0]["state"] == "critical"


def test_review_unplaced_names_the_sources_of_its_signals():
    pv = place(readings(alerts=[alert("SomethingNew", "kube-system")])).by_id["unplaced"]
    assert pv.deps == ("alertmanager",)


def test_review_the_drawer_says_each_state_in_words(tmp_path, world):
    t = adm(tmp_path, world).get("/status/site-forgejo").text
    assert '<span class="visually-hidden">Problem: </span>' in t.split("<aside", 1)[1]

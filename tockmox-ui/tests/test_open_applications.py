# SPDX-License-Identifier: Apache-2.0
"""Applications open to every signed-in user, on Status (the identity layer's sso.access.report).

The identity layer's CronJob writes the list to one ConfigMap; this console reads it (app/sources.py,
OpenApplicationsSource), puts one warning per application the site did not declare open on the "Open applications"
part of the Identity band (app/stack.py), and counts them in Home's verdict (app/views.py).

The fixtures under fixtures/open_applications/ are the ConfigMap as the job leaves it, written by running the job's
own script on stand-ins (tests/identity-open-applications/standin.py --write, at the repository root), and checked
against it by that directory's tests. They are not written by hand.

  unbound     Argo CD made by hand with no binding (warns); a handbook the site declared open (does not)
  bound       the same after Argo CD is bound to the admin group: nothing warns
  all-bound   nothing open at all

Run from tockmox-ui/: python -m pytest tests
"""
import copy
import json
import sys
import time
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import stack  # noqa: E402
from app.config import ConfigError  # noqa: E402
from app.sources import KubeClient, OpenApplicationsSource, Reading  # noqa: E402
from tests.test_status_api import World, app_obj, make_client  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "open_applications"
NS, CM = "tockmox-authentik", "tockmox-identity-open-applications"
PATH = f"/api/v1/namespaces/{NS}/configmaps/{CM}"


def cm(name):
    return json.loads((FIX / f"{name}.json").read_text())


def written_at(doc):
    from datetime import datetime
    rep = json.loads(doc["data"]["report.json"])
    return datetime.fromisoformat(rep["generatedAt"].replace("Z", "+00:00")).timestamp()


def source(answer, *, age=60.0, stale_s=3600.0):
    """The source over a mock API that answers `answer` (a ConfigMap dict, or an int status) at PATH only."""
    seen = []

    def h(req: httpx.Request):
        seen.append(req.url.path)
        if req.url.path != PATH:
            return httpx.Response(404)
        if isinstance(answer, int):
            return httpx.Response(answer, json={"kind": "Status", "code": answer})
        return httpx.Response(200, json=answer)
    base = written_at(cm("unbound"))
    kube = KubeClient("https://kube.test", "/nonexistent", "/nonexistent", 1, httpx.MockTransport(h))
    src = OpenApplicationsSource(kube, NS, CM, stale_s=stale_s, clock=lambda: base + age)
    return src, seen


# ------------------------------------------------------------ the source

def test_an_application_nobody_declared_open_warns():
    src, seen = source(cm("unbound"))
    r = src.read()
    assert seen == [PATH]
    assert r.state == "warning" and r.reason == "1 application is open to every signed-in user"
    assert [a["slug"] for a in r.data["open"]] == ["argocd", "handbook"]


def test_binding_it_clears_the_warning_and_a_declared_one_never_warns():
    r = source(cm("bound"))[0].read()
    assert r.state == "ok" and "declared open (1)" in r.reason


def test_nothing_open_is_ok():
    r = source(cm("all-bound"))[0].read()
    assert r.state == "ok" and r.reason == "every application is bound to a group or user"


def test_a_missing_configmap_is_unknown_with_the_reason():
    r = source(404)[0].read()
    assert r.state == "unknown" and "does not exist" in r.reason and NS in r.reason


def test_a_configmap_the_job_has_not_written_is_unknown():
    shell = copy.deepcopy(cm("unbound"))
    del shell["data"]
    r = source(shell)[0].read()
    assert r.state == "unknown" and "has not run" in r.reason


def test_an_old_list_is_unknown_not_its_last_state():
    r = source(cm("unbound"), age=3601)[0].read()
    assert r.state == "unknown" and "1h" in r.reason and "has not written since" in r.reason


def test_a_refused_read_is_unknown():
    r = source(403)[0].read()
    assert r.state == "unknown" and r.reason == "HTTP 403"


@pytest.mark.parametrize("body", ["not json", json.dumps({"version": 1}), json.dumps([1, 2])])
def test_an_unreadable_list_is_unknown(body):
    doc = copy.deepcopy(cm("unbound"))
    doc["data"]["report.json"] = body
    r = source(doc)[0].read()
    assert r.state == "unknown" and r.reason == "unusable answer"


def test_a_list_version_it_does_not_know_is_unknown():
    doc = copy.deepcopy(cm("unbound"))
    rep = json.loads(doc["data"]["report.json"])
    rep["version"] = 2
    doc["data"]["report.json"] = json.dumps(rep)
    r = source(doc)[0].read()
    assert r.state == "unknown" and "version 2" in r.reason


# ------------------------------------------------------------ the part

def _reading(name):
    src = source(cm(name))[0]
    return src.read()


def _base():
    now = time.time()
    return {"nodes": Reading("Nodes", "ok", [{"name": "n1", "ready": "Ready", "version": "v1"}], "", now, now)}


def test_the_part_names_each_undeclared_application():
    rd = _base() | {"open_applications": _reading("unbound")}
    pl = stack.place(stack.load(), rd)
    pv = pl.by_id["open-applications"]
    assert pv.state == "warning" and pv.band_name == "Identity" and pv.count == "1"
    assert [w["what"] for w in pv.wrong] == ["Argo CD is open to every signed-in user"]
    assert pv.wrong[0]["detail"] == "Authentik application argocd: no group or user binding"
    assert "sso.access.everyone" in pv.part.about and "grants nothing" in pv.part.about
    assert not any("handbook" in w["detail"] for w in pv.wrong)


def test_the_part_is_ok_once_bound():
    pl = stack.place(stack.load(), _base() | {"open_applications": _reading("bound")})
    assert pl.by_id["open-applications"].state == "ok" and not pl.by_id["open-applications"].wrong


def test_the_part_is_unknown_when_the_list_is():
    r = source(404)[0].read()
    pl = stack.place(stack.load(), _base() | {"open_applications": r})
    pv = pl.by_id["open-applications"]
    assert pv.state == "unknown" and "does not exist" in pv.reason


def test_no_reading_no_part():
    pl = stack.place(stack.load(), _base())
    assert "open-applications" not in pl.by_id


# ------------------------------------------------------------ the pages

class OpenWorld(World):
    def __init__(self, fixture="unbound"):
        super().__init__()
        self.apps.append(app_obj("tockmox-identity"))      # the Identity band shows only with its layer
        self.cm = cm(fixture)

    def handler(self, which):
        inner = super().handler(which)

        def h(req: httpx.Request):
            if which == "kube" and req.url.path == PATH:
                self.requests.append((which, req.method, req.url.path))
                return httpx.Response(200, json=self.cm)
            return inner(req)
        return h


def _on(doc):
    doc["sources"]["openApplications"] = {"enabled": True}


def client(tmp_path, world, tweak=_on):
    c = make_client(tmp_path, world, groups=["tockmox-admins"], tweak=tweak)
    src = c.app.state.sources.get("open_applications")
    if src is not None:
        src.clock = lambda: written_at(world.cm) + 60
    return c


def test_status_shows_the_warning_part_and_its_drawer_names_the_application(tmp_path):
    w = OpenWorld("unbound")
    c = client(tmp_path, w)
    page = c.get("/status").text
    assert 'href="/status/open-applications"' in page and "Open applications" in page
    drawer = c.get("/status/open-applications")
    assert drawer.status_code == 200
    assert "Argo CD is open to every signed-in user" in drawer.text
    assert "Staff handbook" not in drawer.text
    assert ("kube", "GET", PATH) in w.requests


def test_home_leads_with_it_for_an_administrator_and_counts_it_for_everyone_else(tmp_path):
    w = OpenWorld("unbound")
    c = client(tmp_path, w)
    assert "Open applications needs a look: Argo CD is open to every signed-in user" in c.get("/").text
    u = make_client(tmp_path, w, groups=["tockmox-users"], tweak=_on)
    u.app.state.sources["open_applications"].clock = lambda: written_at(w.cm) + 60
    home = u.get("/").text
    assert "1 application is open to every signed-in user" in home and "Argo CD" not in home


def test_once_bound_nothing_warns(tmp_path):
    c = client(tmp_path, OpenWorld("bound"))
    drawer = c.get("/status/open-applications").text
    assert "open to every signed-in user" not in drawer.replace("Applications any signed-in user can open", "")
    assert "open to every signed-in user" not in c.get("/").text


def test_it_needs_no_identity_actions(tmp_path):
    c = client(tmp_path, OpenWorld("unbound"))
    s = c.app.state.settings
    assert not (s.actions and s.actions.on("identity"))
    assert c.app.state.sources["open_applications"].read().state == "warning"


def test_off_by_default_reads_nothing_and_shows_no_part(tmp_path):
    w = OpenWorld("unbound")
    c = client(tmp_path, w, tweak=None)
    assert "open_applications" not in c.app.state.sources
    assert 'href="/status/open-applications"' not in c.get("/status").text
    assert c.get("/status/open-applications").status_code == 404
    assert not any(p == PATH for _, _, p in w.requests)


@pytest.mark.parametrize("bad", [{"enabled": True, "namespace": "Not A Namespace"},
                                 {"enabled": True, "configMap": "x/y"},
                                 {"enabled": True, "staleSeconds": 0}])
def test_a_bad_setting_stops_the_ui_at_start(tmp_path, bad):
    with pytest.raises(ConfigError, match="openApplications"):
        make_client(tmp_path, OpenWorld(), tweak=lambda d: d["sources"].__setitem__("openApplications", bad))


def test_switched_off_explicitly_reads_nothing(tmp_path):
    w = OpenWorld("unbound")
    c = client(tmp_path, w, tweak=lambda d: d["sources"].__setitem__("openApplications", {"enabled": False}))
    assert "open_applications" not in c.app.state.sources
    assert not any(p == PATH for _, _, p in w.requests)

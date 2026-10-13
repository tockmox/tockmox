# SPDX-License-Identifier: Apache-2.0
"""TM-0841: the read-only status API, GET /api/v1/status, provisional.

Same session cookie as the pages, admins only; every write verb under /api/ is refused with 405 for
everyone. The lab finding that binds it (TM-0901 D4): Argo CD Application CRs keep their last sync and
health when the application controller stops, so an application not reconciled within
argocdStaleSeconds reads `unknown` here whatever the CR says. Run from tockmox-ui/: python -m pytest tests
"""
import datetime
import sys
import time
from pathlib import Path

import httpx
import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import status_api  # noqa: E402

TOCKMOX_REPO = "https://github.com/tockmox/tockmox"


def _iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def app_obj(name, rev="v0.7.2", sync="Synced", health="Healthy", repo=TOCKMOX_REPO, reconciled_ago=30, path=None):
    return {"metadata": {"name": name},
            "spec": {"source": {"repoURL": repo, "targetRevision": rev,
                                **({"path": path} if path is not None else {})}},
            "status": {"sync": {"status": sync}, "health": {"status": health},
                       **({"reconciledAt": _iso(time.time() - reconciled_ago)} if reconciled_ago is not None else {})}}


class World:
    """What the cluster, Prometheus and Alertmanager answer. Tests change it between requests."""

    def __init__(self):
        self.apps = [app_obj("tockmox-platform"), app_obj("tockmox-observability"), app_obj("tockmox-ai"),
                     app_obj("site-apps", rev="main", repo="https://forgejo.example/site")]
        self.nodes = [{"metadata": {"name": "node-1"}, "status": {"conditions": [{"type": "Ready", "status": "True"}],
                                                                  "nodeInfo": {"kubeletVersion": "v1.36.5+k3s1"}}}]
        self.alerts = [{"labels": {"alertname": "Watchdog", "severity": "none"}, "annotations": {}}]
        self.down = set()
        self.requests = []

    def handler(self, which):
        def h(req: httpx.Request):
            self.requests.append((which, req.method, req.url.path))
            if which in self.down:
                raise httpx.ConnectError("refused", request=req)
            p = req.url.path
            if which == "kube" and p.endswith("/applications"):
                return httpx.Response(200, json={"items": self.apps})
            if which == "kube" and p == "/api/v1/nodes":
                return httpx.Response(200, json={"items": self.nodes})
            if which == "prometheus":
                res = [{"metric": {"job": "prometheus", "instance": "prometheus:9090"}, "value": [time.time(), "1"]}]
                return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": res}})
            if which == "alertmanager":
                return httpx.Response(200, json=self.alerts)
            return httpx.Response(404)
        return h


@pytest.fixture
def world():
    return World()


def make_client(tmp_path, world, groups=None, stale_s=600, tweak=None, notes_path=None):
    from fastapi.testclient import TestClient
    from app import config
    from app.auth import Sessions
    from app.main import Transports, create_app
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    if tweak:
        tweak(doc)
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["sources"]["kubernetes"].update({"url": "https://kube.test", "tokenFile": "/nonexistent", "caFile": "/nonexistent",
                                         "argocdStaleSeconds": stale_s})
    doc["sources"]["timeoutSeconds"] = 1
    s = config.parse(doc)
    tp = Transports(kube=httpx.MockTransport(world.handler("kube")), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")))
    app = create_app(s, tp, notes_path=notes_path or str(tmp_path / "none.md"))
    c = TestClient(app, follow_redirects=False)
    if groups is not None:
        sess = Sessions(s.session_secret, 3600, s.admin_group, False)
        c.cookies.set(sess.session_cookie, sess.issue("a", "Someone", groups))
    return c


def admin(tmp_path, world, **kw):
    return make_client(tmp_path, world, groups=["tockmox-admins"], **kw)


def by_name(body, name):
    return next(a for a in body["applications"] if a["name"] == name)


# ------------------------------------------------------------ who may call it, and with which verbs

def test_anonymous_gets_401_json_not_a_redirect(tmp_path, world):
    r = make_client(tmp_path, world).get("/api/v1/status")
    assert r.status_code == 401 and r.headers["content-type"].startswith("application/json")
    assert "error" in r.json() and "location" not in r.headers


def test_a_signed_in_non_admin_gets_403(tmp_path, world):
    r = make_client(tmp_path, world, groups=["tockmox-users"]).get("/api/v1/status")
    assert r.status_code == 403 and r.json()["error"]


@pytest.mark.parametrize("verb", ["POST", "PUT", "PATCH", "DELETE"])
@pytest.mark.parametrize("path", ["/api/v1/status", "/api/v1/anything", "/api/"])
def test_every_write_verb_under_api_is_refused_for_admins_and_strangers_alike(tmp_path, world, verb, path):
    for c in (admin(tmp_path, world), make_client(tmp_path, world)):
        r = c.request(verb, path, data={"csrf": "x"})
        assert r.status_code == 405, (verb, path, r.status_code)
        assert r.headers["allow"] == "GET, HEAD"
    assert world.requests == []          # a refused write reads nothing from any source


def test_an_unknown_api_path_is_404_json(tmp_path, world):
    r = admin(tmp_path, world).get("/api/v1/nope")
    assert r.status_code == 404 and r.json()["error"]


def test_the_answer_is_never_cached_and_carries_the_pages_headers(tmp_path, world):
    r = admin(tmp_path, world).get("/api/v1/status")
    assert r.headers["cache-control"] == "no-store" and r.headers["x-content-type-options"] == "nosniff"


# ------------------------------------------------------------ the body

def test_a_healthy_cluster_reads_ok_with_every_layer_fresh(tmp_path, world):
    r = admin(tmp_path, world).get("/api/v1/status")
    assert r.status_code == 200
    b = r.json()
    assert b["schema"] == status_api.SCHEMA and b["provisional"] is True
    assert b["verdict"] == "ok"
    assert {k for k in b["sources"]} == {"apps", "nodes", "prometheus", "alertmanager"}
    assert all(v["state"] == "ok" and v["fetchedAt"] for v in b["sources"].values())
    assert [a["name"] for a in b["applications"]] == ["site-apps", "tockmox-ai", "tockmox-observability", "tockmox-platform"]
    assert by_name(b, "tockmox-ai") == {"name": "tockmox-ai", "tockmoxLayer": True, "repo": TOCKMOX_REPO, "revision": "v0.7.2",
                                        "sync": "Synced", "health": "Healthy", "reconciledAt": by_name(b, "tockmox-ai")["reconciledAt"],
                                        "state": "ok", "reason": ""}
    assert by_name(b, "site-apps")["tockmoxLayer"] is False
    assert b["version"] == {"state": "single", "version": "v0.7.2"}
    assert b["nodes"] == [{"name": "node-1", "ready": "Ready", "version": "v1.36.5+k3s1"}]
    assert b["alerts"] == [{"name": "Watchdog", "severity": "none", "namespace": "", "summary": "", "startsAt": ""}]
    assert b["inferenceNodes"] is None    # none configured: nothing to say, not "all healthy"
    assert "layers" not in b["version"]   # the per-app detail lives under applications, once


# ------------------------------------------------------------ which Applications are the Tockmox layers (TM-0979)

MIRROR = "git://site-git.tockmox-harness.svc.cluster.local/tockmox.git"


def _mirrored(world):
    """A site that serves the product tree from a mirror: every lab, and every air-gapped site."""
    world.apps = [app_obj("tockmox-platform", rev="v0.8.0-hm1", repo=MIRROR, path="charts/tockmox-platform"),
                  app_obj("tockmox-ai", rev="v0.8.0-hm1", repo=MIRROR, path="charts/tockmox-ai"),
                  app_obj("site-apps", rev="main", repo="https://forgejo.example/site", path="apps")]


def test_with_tockmox_repo_unset_the_layers_are_the_charts_tockmox_paths_whatever_serves_them(tmp_path, world):
    """Lab finding F-L1-8: on a mirrored product repository the UI said "Version unknown ... No Argo CD
    application points at the Tockmox repository" with tockmoxLayer false on every layer, because the
    default tockmoxRepo was github.com and nothing on the site matched it. Unset, the match is the source
    path charts/tockmox-<layer>, which the installer writes into every layer Application."""
    _mirrored(world)
    b = admin(tmp_path, world, tweak=lambda d: d.pop("tockmoxRepo")).get("/api/v1/status").json()
    assert by_name(b, "tockmox-ai")["tockmoxLayer"] is True and by_name(b, "tockmox-platform")["tockmoxLayer"] is True
    assert by_name(b, "site-apps")["tockmoxLayer"] is False
    assert b["version"] == {"state": "single", "version": "v0.8.0-hm1"}


def test_with_tockmox_repo_set_only_that_repository_counts(tmp_path, world):
    """The key stays as a pin: set to github.com on a mirrored site, nothing matches, and the reason names the
    rule that was applied rather than a repository the reader never configured."""
    _mirrored(world)
    b = admin(tmp_path, world).get("/api/v1/status").json()       # config.example.yaml pins github.com
    assert all(a["tockmoxLayer"] is False for a in b["applications"])
    assert b["version"]["state"] == "unknown" and TOCKMOX_REPO in b["version"]["reason"]


def test_the_shipped_default_is_unset_not_github(tmp_path):
    """config.parse with no tockmoxRepo derives; the old default pinned github.com and broke every mirror."""
    from app import config
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    doc.pop("tockmoxRepo")
    (tmp_path / "ss").write_text("s" * 40); (tmp_path / "cs").write_text("x")
    doc["session"]["secretFile"] = str(tmp_path / "ss"); doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    assert config.parse(doc).tockmox_repo == ""


def test_a_degraded_layer_reads_critical(tmp_path, world):
    world.apps[2] = app_obj("tockmox-ai", health="Degraded")
    b = admin(tmp_path, world).get("/api/v1/status").json()
    assert by_name(b, "tockmox-ai")["state"] == "critical" and b["verdict"] == "critical"


# ------------------------------------------------------------ the stale-controller case (TM-0901 D4)

def test_a_stopped_argocd_controller_reads_unknown_not_healthy(tmp_path, world):
    # The CRs still say Synced/Healthy; only reconciledAt gives the stopped controller away.
    world.apps = [app_obj(n, reconciled_ago=3600) for n in ("tockmox-platform", "tockmox-observability", "tockmox-ai")]
    b = admin(tmp_path, world).get("/api/v1/status").json()
    assert all(a["sync"] == "Synced" and a["health"] == "Healthy" for a in b["applications"])
    assert all(a["state"] == "unknown" and "not reconciled" in a["reason"] for a in b["applications"])
    assert b["sources"]["apps"]["state"] == "unknown" and "stopped reconciling" in b["sources"]["apps"]["reason"]
    assert b["verdict"] == "unknown"
    assert b["version"]["state"] == "unknown" and b["version"]["version"] is None


def test_one_stale_application_reads_unknown_while_the_fresh_ones_still_vouch(tmp_path, world):
    world.apps[0] = app_obj("tockmox-platform", reconciled_ago=3600)
    b = admin(tmp_path, world).get("/api/v1/status").json()
    assert by_name(b, "tockmox-platform")["state"] == "unknown"
    assert by_name(b, "tockmox-ai")["state"] == "ok"
    assert b["verdict"] != "ok"          # one layer unvouched-for is not a healthy platform


def test_an_application_with_no_reconciledat_reads_unknown(tmp_path, world):
    world.apps[0] = app_obj("tockmox-platform", reconciled_ago=None)
    b = admin(tmp_path, world).get("/api/v1/status").json()
    a = by_name(b, "tockmox-platform")
    assert a["state"] == "unknown" and a["reconciledAt"] is None and "never reconciled" in a["reason"]


def test_the_staleness_window_is_argocdstaleseconds(tmp_path, world):
    world.apps = [app_obj("tockmox-platform", reconciled_ago=120)]
    assert by_name(admin(tmp_path, world, stale_s=60).get("/api/v1/status").json(), "tockmox-platform")["state"] == "unknown"
    assert by_name(admin(tmp_path, world, stale_s=600).get("/api/v1/status").json(), "tockmox-platform")["state"] == "ok"


# ------------------------------------------------------------ a source that did not answer

def test_a_dead_alertmanager_gives_null_not_an_empty_list(tmp_path, world):
    world.down.add("alertmanager")
    b = admin(tmp_path, world).get("/api/v1/status").json()
    assert b["alerts"] is None
    assert b["sources"]["alertmanager"] == {"name": "Alertmanager", "state": "unknown", "reason": "unreachable",
                                            "fetchedAt": None, "lastOkAt": None}
    assert b["verdict"] == "unknown"


def test_a_cached_answer_never_vouches_after_the_source_dies(tmp_path, world):
    c = admin(tmp_path, world)
    assert c.get("/api/v1/status").json()["applications"] is not None
    world.down.add("kube")
    from app import sources
    for src in c.app.state.sources.values():
        src._c.t = 0                      # the pages' 15 s cache has expired
    b = c.get("/api/v1/status").json()
    assert b["applications"] is None and b["nodes"] is None
    assert b["sources"]["apps"]["state"] == "unknown" and b["sources"]["apps"]["lastOkAt"]
    assert b["version"]["state"] == "unknown"
    assert sources.UNKNOWN == "unknown"   # the literal the schema documents


def test_an_empty_alert_list_without_the_heartbeat_reads_unknown(tmp_path, world):
    world.alerts = []
    b = admin(tmp_path, world).get("/api/v1/status").json()
    assert b["alerts"] == [] and b["sources"]["alertmanager"]["state"] == "unknown"
    assert "Watchdog" in b["sources"]["alertmanager"]["reason"]

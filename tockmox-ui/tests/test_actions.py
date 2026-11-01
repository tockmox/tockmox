# SPDX-License-Identifier: Apache-2.0
"""TM-1311 and TM-1313: actions from the console (specs/tockmox-ui/SPEC.md section 7 in the planning repo).

  shared     the kinds, the intent, the nonce that binds a sign-in to one intent, the checks both sides run
  service    tockmox-actions: the token is the issuer's or nothing; a disabled kind is refused; a replayed key does
             nothing twice; step-up for sync and restart; each kind does exactly its one thing; one audit line each
  console    the button is absent when its kind is off; the confirm panel; CSRF; the round trip through the issuer
             with nonce and max_age; the result page; Activity; a console silence stays on Status, marked

A fake identity provider signs real RS256 ID tokens (its JWKS served through httpx.MockTransport), so the service's
verification is the real code path, and the console's callback is wired to the real service in-process.
Run from tockmox-ui/: python -m pytest tests
"""
import base64
import copy
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
import jwt
import pytest
import yaml
from cryptography.hazmat.primitives.asymmetric import rsa

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402
from app import actions_service as svcmod  # noqa: E402
from tests.test_status_api import World  # noqa: E402

ISS = "https://auth.int.example.com/application/o/tockmox-ui"
CID = "tockmox-ui"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _b64u(n: int) -> str:
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


PUB = KEY.public_key().public_numbers()
JWKS = {"keys": [{"kty": "RSA", "kid": "k1", "use": "sig", "alg": "RS256", "n": _b64u(PUB.n), "e": _b64u(PUB.e)}]}


def token(nonce, sub="a", groups=("tockmox-admins",), aud=CID, iat=None, auth_time=None, name="Jeff", key=KEY, **extra):
    now = time.time()
    c = {"iss": ISS, "aud": aud, "sub": sub, "iat": int(iat if iat is not None else now), "exp": int(now + 300),
         "nonce": nonce, "name": name, "auth_time": int(auth_time if auth_time is not None else now), **extra}
    if groups is not None:
        c["groups"] = list(groups)
    return jwt.encode(c, key, algorithm="RS256", headers={"kid": "k1"})


class IdP:
    """Discovery, JWKS, and a token endpoint that answers whatever the test queued (the nonce comes from the
    authorization request the console made, as a real issuer would echo it)."""

    def __init__(self):
        self.auth_requests = []
        self.next_claims = {}

    def handler(self, req: httpx.Request):
        p = req.url.path
        if p.endswith("/.well-known/openid-configuration"):
            return httpx.Response(200, json={"issuer": ISS, "authorization_endpoint": ISS + "/authorize",
                                             "token_endpoint": ISS + "/token", "jwks_uri": ISS + "/jwks"})
        if p.endswith("/jwks"):
            return httpx.Response(200, json=JWKS)
        if p.endswith("/token"):
            return httpx.Response(200, json={"id_token": token(**self.next_claims), "access_token": "x"})
        return httpx.Response(404)


class AM:
    def __init__(self):
        self.silences, self.alerts_posted, self.calls = {}, [], []
        self.alerts = [{"labels": {"alertname": "Watchdog", "severity": "none"}, "annotations": {}, "status": {}}]

    def handler(self, req: httpx.Request):
        p, m = req.url.path, req.method
        self.calls.append((m, p))
        if p == "/api/v2/silences" and m == "POST":
            body = json.loads(req.content)
            sid = f"0000000{len(self.silences)}-0000-4000-8000-000000000000"
            self.silences[sid] = dict(body, id=sid, status={"state": "active"})
            return httpx.Response(200, json={"silenceID": sid})
        if p == "/api/v2/silences" and m == "GET":
            return httpx.Response(200, json=list(self.silences.values()))
        if p.startswith("/api/v2/silence/"):
            sid = p.rsplit("/", 1)[1]
            if sid not in self.silences:
                return httpx.Response(404)
            if m == "DELETE":
                self.silences[sid]["status"] = {"state": "expired"}
            return httpx.Response(200, json=self.silences[sid])
        if p == "/api/v2/alerts" and m == "POST":
            self.alerts_posted += json.loads(req.content)
            return httpx.Response(200, json={})
        if p == "/api/v2/alerts" and m == "GET":          # silencedBy as Alertmanager computes it, from the matchers
            out = []
            for a in self.alerts:
                lab = a.get("labels", {})
                by = list((a.get("status") or {}).get("silencedBy") or [])
                for sid, x in self.silences.items():
                    if x.get("matchers") and (x.get("status") or {}).get("state") == "active" and all(
                            (re.fullmatch(mm["value"], lab.get(mm["name"], "")) if mm["isRegex"] else
                             lab.get(mm["name"], "") == mm["value"]) for mm in x["matchers"]):
                        by.append(sid)
                out.append(dict(a, status=dict(a.get("status") or {}, silencedBy=by)))
            return httpx.Response(200, json=out)
        return httpx.Response(404)


class Kube:
    def __init__(self):
        self.cronjobs = {("tockmox-ai", "tockmox-model-watch"): {
            "metadata": {"name": "tockmox-model-watch", "uid": "u-1"},
            "spec": {"jobTemplate": {"metadata": {"labels": {"app": "w"}}, "spec": {"template": {"spec": {"containers": []}}}}}}}
        self.cm = None
        self.calls = []
        self.jobs = []
        self.patches = []

    def handler(self, req: httpx.Request):
        p, m = req.url.path, req.method
        self.calls.append((m, p))
        mt = re.fullmatch(r"/apis/batch/v1/namespaces/([^/]+)/cronjobs/([^/]+)", p)
        if mt and m == "GET":
            cj = self.cronjobs.get(mt.groups())
            return httpx.Response(200, json=cj) if cj else httpx.Response(404, json={"message": "not found"})
        if re.fullmatch(r"/apis/batch/v1/namespaces/[^/]+/jobs", p) and m == "POST":
            self.jobs.append(json.loads(req.content))
            return httpx.Response(201, json=self.jobs[-1])
        if "/configmaps" in p:
            if m == "GET":
                return httpx.Response(200, json=self.cm) if self.cm else httpx.Response(404, json={})
            body = json.loads(req.content)
            body.setdefault("metadata", {})["resourceVersion"] = str(len(self.calls))
            self.cm = body
            return httpx.Response(200, json=body)
        mt = re.fullmatch(r"/apis/apps/v1/namespaces/([^/]+)/(deployments|statefulsets)/([^/]+)", p)
        if mt and m == "PATCH":
            self.patches.append((mt.groups(), req.headers.get("content-type"), json.loads(req.content)))
            return httpx.Response(200, json={})
        return httpx.Response(404, json={"message": "no"})


ACTIONS = {"silence": {"enabled": True}, "testAlert": {"enabled": True},
           "runJob": {"enabled": True, "allow": [{"namespace": "tockmox-ai", "name": "tockmox-model-watch", "part": "layer-ai"}]},
           "restart": {"enabled": True, "allow": [{"namespace": "tockmox-ai", "kind": "Deployment", "name": "tockmox-ui",
                                                   "part": "layer-ai"}]},
           "argocd": {"enabled": False}}


def service(actions=None, am=None, kube=None, idp=None):
    am, kube, idp = am or AM(), kube or Kube(), idp or IdP()
    doc = {"oidc": {"issuer": ISS, "clientId": CID}, "roles": {"adminGroup": "tockmox-admins"},
           "sources": {"alertmanager": {"url": "http://am.test"}, "kubernetes": {"url": "https://kube.test",
                       "tokenFile": "/nonexistent", "caFile": "/nonexistent"}},
           "actions": dict(copy.deepcopy(actions or ACTIONS), namespace="tockmox-ai")}
    s = svcmod.Service(doc, {"oidc": httpx.MockTransport(idp.handler), "alertmanager": httpx.MockTransport(am.handler),
                             "kube": httpx.MockTransport(kube.handler)})
    return s, am, kube


def cfg():
    return act.parse(dict(ACTIONS, url="http://actions.test"))


def silence_intent(**kw):
    t = {"part": "forgejo", "label": "Forgejo", "alerts": [{"alertname": "ForgejoBackupMissed", "namespace": "forgejo"},
                                                          {"alertname": "KubeJobFailed", "namespace": "forgejo"}]}
    return act.intent("silence", t, {"hours": 4, "reason": "re-running the backup"}, "a", **kw)


# ---------------------------------------------------------------- shared

def test_off_by_default_and_a_malformed_block_stops_the_process():
    assert act.parse(None).enabled == frozenset() and not act.parse({}).any
    with pytest.raises(ValueError, match="unknown key"):
        act.parse({"silences": {"enabled": True}})
    with pytest.raises(ValueError, match="runJob.allow"):
        act.parse({"runJob": {"enabled": True, "allow": [{"namespace": "Bad NS", "name": "x"}]}})
    with pytest.raises(ValueError, match="restart.allow"):
        act.parse({"restart": {"enabled": True, "allow": [{"namespace": "a", "kind": "DaemonSet", "name": "x"}]}})


def test_the_nonce_binds_one_intent_and_any_change_breaks_it():
    it = silence_intent()
    n = act.nonce_for(it)
    for change in ({"params": {"hours": 24, "reason": "re-running the backup"}}, {"key": act.new_key()}, {"sub": "b"},
                   {"target": dict(it["target"], alerts=it["target"]["alerts"][:1])}):
        assert act.nonce_for(dict(it, **change)) != n
    assert act.nonce_for(json.loads(json.dumps(it))) == n            # a round trip through JSON keeps it


@pytest.mark.parametrize("change, why", [
    ({"kind": "argocd-sync"}, "no such action"),
    ({"kind": "sync", "target": {"app": "x"}}, "not turned on"),
    ({"key": "not-a-uuid"}, "idempotency key"),
    ({"params": {"hours": 169, "reason": "x"}}, "1 to 168 hours"),
    ({"params": {"hours": 4, "reason": "  "}}, "needs a reason"),
    ({"target": {"part": "p", "alerts": [{"alertname": "Watchdog"}]}}, "never silenced"),
    ({"target": {"part": "p", "alerts": [{"alertname": "TockmoxHeartbeat"}]}}, "never silenced"),
    ({"target": {"part": "p", "alerts": [{"alertname": "a{b}"}]}}, "not a Prometheus alert name"),
    ({"target": {"part": "p", "alerts": []}}, "between 1 and 20"),
])
def test_check_refuses(change, why):
    with pytest.raises(act.Refused, match=why):
        act.check(cfg(), dict(silence_intent(), **change))


def test_check_holds_the_allowlists():
    c = cfg()
    act.check(c, act.intent("run-job", {"namespace": "tockmox-ai", "name": "tockmox-model-watch"}, {}, "a"))
    with pytest.raises(act.Refused, match="allowlist"):
        act.check(c, act.intent("run-job", {"namespace": "kube-system", "name": "anything"}, {}, "a"))
    with pytest.raises(act.Refused, match="allowlist"):
        act.check(c, act.intent("restart", {"namespace": "tockmox-ai", "kind": "StatefulSet", "name": "tockmox-ui"}, {}, "a"))


def test_one_silence_per_namespace_and_no_namespace_means_absent_not_every_namespace():
    m = act.silence_matchers({"alerts": [{"alertname": "A", "namespace": "x"}, {"alertname": "B", "namespace": "x"},
                                         {"alertname": "C", "namespace": ""}]})
    assert m[0] == [{"name": "alertname", "value": "C", "isRegex": False, "isEqual": True},
                    {"name": "namespace", "value": "", "isRegex": False, "isEqual": True}]
    assert m[1][0] == {"name": "alertname", "value": "A|B", "isRegex": True, "isEqual": True}
    assert m[1][1]["value"] == "x"


# ---------------------------------------------------------------- the service

def test_a_confirmed_silence_is_made_once_and_recorded(capsys):
    s, am, kube = service()
    it = silence_intent()
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 200 and out["result"] == "done" and len(out["ref"]) == 1
    sil = next(iter(am.silences.values()))
    assert sil["createdBy"] == "Jeff (Tockmox UI)" and it["key"] in sil["comment"]
    assert {x["value"] for x in sil["matchers"]} == {"ForgejoBackupMissed|KubeJobFailed", "forgejo"}
    rows = json.loads(kube.cm["data"]["activity.json"])
    assert rows[0]["key"] == it["key"] and rows[0]["who"] == "Jeff" and rows[0]["summary"].startswith("Silenced 2 alerts on Forgejo")
    # the same key again: nothing twice
    code, again = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 200 and again["repeat"] and len(am.silences) == 1
    lines = [json.loads(x) for x in capsys.readouterr().out.splitlines() if '"tockmox.action"' in x]
    assert [x["result"] for x in lines] == ["done", "repeat"] and lines[0]["sub"] == "a" and lines[0]["action"] == "silence"


@pytest.mark.parametrize("tok, why", [
    (lambda it: token("some-other-nonce"), "not made for this action"),
    (lambda it: token(act.nonce_for(it), groups=("tockmox-users",)), "only platform administrators"),
    (lambda it: token(act.nonce_for(it), groups=None), "names no groups"),
    (lambda it: token(act.nonce_for(it), iat=time.time() - 900), "too old"),
    (lambda it: token(act.nonce_for(it), aud="grafana"), "could not be verified"),
    (lambda it: token(act.nonce_for(it), sub="someone-else"), "different person"),
    (lambda it: token(act.nonce_for(it), key=rsa.generate_private_key(public_exponent=65537, key_size=2048)), "could not be verified"),
    (lambda it: "", "no ID token"),
])
def test_nothing_is_trusted_but_what_the_issuer_signed_for_this_intent(tok, why, capsys):
    s, am, _ = service()
    it = silence_intent()
    code, out = s.handle({"intent": it, "id_token": tok(it)})
    assert code == 403 and why in out["reason"] and not am.silences
    assert '"result":"refused"' in capsys.readouterr().out


def test_a_disabled_kind_is_refused_whatever_the_token():
    s, am, _ = service(actions={"silence": {"enabled": False}, "testAlert": {"enabled": True}})
    it = silence_intent()
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 403 and "not turned on" in out["reason"] and not am.silences


def test_restart_needs_a_recent_sign_in_and_patches_only_the_annotation():
    s, _, kube = service()
    it = act.intent("restart", {"namespace": "tockmox-ai", "kind": "Deployment", "name": "tockmox-ui"}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it), auth_time=time.time() - 3600)})
    assert code == 403 and "sign-in from the last 5 minutes" in out["reason"] and not kube.patches
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it), auth_time=time.time() - 60)})
    assert code == 200, out
    (where, ctype, body), = kube.patches
    assert where == ("tockmox-ai", "deployments", "tockmox-ui") and ctype == "application/strategic-merge-patch+json"
    assert list(body) == ["spec"] and list(body["spec"]["template"]["metadata"]["annotations"]) == ["kubectl.kubernetes.io/restartedAt"]


def test_run_now_makes_one_job_from_the_cronjob_owned_by_it():
    s, _, kube = service()
    it = act.intent("run-job", {"namespace": "tockmox-ai", "name": "tockmox-model-watch"}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 200, out
    (job,) = kube.jobs
    md = job["metadata"]
    assert md["name"].startswith("tockmox-model-watch-run-") and len(md["name"]) <= 63
    assert md["ownerReferences"][0] == {"apiVersion": "batch/v1", "kind": "CronJob", "name": "tockmox-model-watch",
                                        "uid": "u-1", "controller": True}
    assert md["labels"] == {"app": "w", "tockmox.com/run-now": "true"} and md["annotations"]["cronjob.kubernetes.io/instantiate"] == "manual"
    assert job["spec"] == {"template": {"spec": {"containers": []}}}
    kube.cronjobs.clear()
    it = act.intent("run-job", {"namespace": "tockmox-ai", "name": "tockmox-model-watch"}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 403 and "no CronJob" in out["reason"]


def test_expire_only_touches_a_console_silence():
    s, am, _ = service()
    am.silences["11111111-1111-4111-8111-111111111111"] = {"id": "11111111-1111-4111-8111-111111111111",
                                                           "createdBy": "jeff", "status": {"state": "active"}}
    it = act.intent("expire", {"silence": "11111111-1111-4111-8111-111111111111"}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 403 and "not made from the console" in out["reason"]
    assert am.silences["11111111-1111-4111-8111-111111111111"]["status"]["state"] == "active"
    it = silence_intent()
    s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    sid = next(k for k, v in am.silences.items() if v.get("createdBy", "").endswith("(Tockmox UI)"))
    it = act.intent("expire", {"silence": sid}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 200 and am.silences[sid]["status"]["state"] == "expired"


def test_a_test_alert_goes_down_the_alert_path_and_resolves_itself():
    s, am, _ = service()
    it = act.intent("test-alert", {}, {}, "a")
    code, _ = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    (a,) = am.alerts_posted
    assert code == 200 and a["labels"]["alertname"] == "TockmoxTestAlert" and a["labels"]["severity"] == "warning"
    start = svcmod.datetime.fromisoformat(a["startsAt"].replace("Z", "+00:00"))
    end = svcmod.datetime.fromisoformat(a["endsAt"].replace("Z", "+00:00"))
    assert (end - start).total_seconds() == 300


def test_argocd_without_the_sites_account_is_refused_not_attempted():
    s, _, _ = service(actions=dict(ACTIONS, argocd={"enabled": True}))
    it = act.intent("sync", {"app": "forgejo"}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 403 and "no Argo CD account" in out["reason"]


def test_the_service_will_not_start_without_an_issuer_or_namespace():
    with pytest.raises(ValueError, match="issuer"):
        svcmod.Service({"actions": {"namespace": "x"}})
    with pytest.raises(ValueError, match="namespace"):
        svcmod.Service({"oidc": {"issuer": ISS}, "actions": {}})


# ---------------------------------------------------------------- the console

def console(tmp_path, actions=None, groups=("tockmox-admins",), down=False, authentik=None):
    """The UI with actions on, its callback wired to a real Service in-process (authentik: a fake Authentik's
    handler, for the identity kinds, TM-1315)."""
    from fastapi.testclient import TestClient
    from app import config
    from app.auth import Sessions
    from app.main import Transports, create_app
    idp, am, kube, world = IdP(), AM(), Kube(), World()
    world.alerts = am.alerts
    svc, _, _ = service(actions=actions, am=am, kube=kube, idp=idp)
    if authentik is not None:
        svc.authentik.transport = httpx.MockTransport(authentik)
    sent = []

    def bridge(req: httpx.Request):
        if down:
            raise httpx.ConnectError("refused", request=req)
        if req.url.path == "/v1/intents":
            body = json.loads(req.content)
            sent.append(body)
            code, out = svc.handle(body)
            return httpx.Response(code, json=out)
        if req.url.path == "/v1/activity":
            rows, _ = svc.activity.read()
            return httpx.Response(200, json={"rows": rows})
        if req.url.path == "/v1/identity/users":         # as app.actions_service serves it
            if not svc.cfg.on("recovery-link"):
                return httpx.Response(404, json={"error": "the identity actions are not turned on here"})
            people, why = svc.authentik.users()
            if why:
                return httpx.Response(503, json={"error": why})
            return httpx.Response(200, json={"users": people, "userGroup": svc.cfg.user_group,
                                             "adminGroup": svc.admin_group})
        return httpx.Response(404)

    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["sources"]["kubernetes"].update({"url": "https://kube.test", "tokenFile": "/nonexistent", "caFile": "/nonexistent"})
    doc["sources"]["timeoutSeconds"] = 1
    doc["actions"] = dict(copy.deepcopy(actions or ACTIONS), url="http://actions.test")
    s = config.parse(doc)
    tp = Transports(kube=httpx.MockTransport(world.handler("kube")), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(am.handler), oidc=httpx.MockTransport(idp.handler),
                    actions=httpx.MockTransport(bridge))
    app = create_app(s, tp, notes_path=str(tmp_path / "none.md"))
    app.state.sources["alertmanager"]._c.ttl = 0                 # each page reads Alertmanager afresh
    c = TestClient(app, follow_redirects=False)
    sess = Sessions(s.session_secret, 3600, s.admin_group, False)
    c.cookies.set(sess.session_cookie, sess.issue("a", "Jeff", list(groups)))
    csrf = sess.read(c.cookies.get(sess.session_cookie)).csrf
    return c, csrf, idp, am, kube, sent


def firing(am, *names, ns="tockmox-ai"):
    am.alerts += [{"labels": {"alertname": n, "severity": "warning", "namespace": ns}, "annotations": {"summary": n},
                   "status": {"state": "active", "silencedBy": []}, "startsAt": "2026-10-31T10:00:00Z"} for n in names]


def drawer_of(c, am):
    firing(am, "KubeJobFailed", "TockmoxModelWatchStale")
    t = c.get("/status?view=list").text
    pid = next(p for p in re.findall(r'href="/status/([a-z0-9-]+)', t) if "KubeJobFailed" in c.get(f"/status/{p}").text)
    return pid, c.get(f"/status/{pid}").text


def test_the_drawer_offers_only_what_is_turned_on_and_allowlisted(tmp_path):
    c, _, _, am, _, _ = console(tmp_path)
    pid, t = drawer_of(c, am)
    acts = t.split("<h3>Actions</h3>", 1)[1].split("</p>", 1)[0]
    assert "Silence 2 alerts" in acts and "Restart tockmox-ui" in acts and "Sync " not in acts
    c2, _, _, am2, _, _ = console(tmp_path, actions={"testAlert": {"enabled": True}})
    _, t2 = drawer_of(c2, am2)
    assert "<h3>Actions</h3>" not in t2 and "Silence" not in t2                 # off means absent, not disabled
    assert "Send a test alert to your phone" in c2.get("/status").text


def test_members_get_no_actions(tmp_path):
    c, csrf, *_ = console(tmp_path, groups=("tockmox-users",))
    assert c.get("/actions/confirm?kind=test-alert").status_code == 403
    assert c.post("/actions/go", data={"csrf": csrf, "kind": "test-alert", "target": "{}"}).status_code == 403
    assert c.get("/platform/activity").status_code == 403


def test_confirm_go_and_back_end_to_end(tmp_path):
    c, csrf, idp, am, kube, sent = console(tmp_path)
    pid, _ = drawer_of(c, am)
    t = c.get(f"/actions/confirm?kind=silence&part={pid}").text
    assert "Silence 2 alerts on" in t and "Undo" in t and "Expire the silence" in t and 'name="reason"' in t
    form = {k: v for k, v in re.findall(r'<input type="hidden" name="([a-z]+)" value="([^"]*)"', t)}
    form = {k: v.replace("&#34;", '"').replace("&quot;", '"') for k, v in form.items()}
    assert c.post("/actions/go", data=dict(form, csrf="wrong", hours="4", reason="x")).status_code == 400
    r = c.post("/actions/go", data=dict(form, hours="4", reason="re-running it"))
    assert r.status_code == 303
    q = parse_qs(urlsplit(r.headers["location"]).query)
    assert "max_age" not in q                                                # low risk: no step-up
    idp.next_claims = {"nonce": q["nonce"][0]}
    r = c.get(f"/auth/callback?code=c&state={q['state'][0]}")
    assert r.status_code == 200, r.text
    assert "Done" in r.text and "Silenced 2 alerts" in r.text and len(am.silences) == 1
    assert act.nonce_for(sent[0]["intent"]) == q["nonce"][0]                 # the token was minted for this intent
    # it stays on Status, marked; the drawer offers Expire
    _, t = pid, c.get(f"/status/{pid}").text
    assert "Silenced by Jeff until" in t and "kind=expire" in t and "Silence 2 alerts" not in t
    a = c.get("/platform/activity").text
    assert "Silenced 2 alerts on" in a and "Jeff" in a and "Expire" in a


def test_restart_asks_the_issuer_for_a_fresh_sign_in(tmp_path):
    c, csrf, idp, am, kube, sent = console(tmp_path)
    tgt = json.dumps({"namespace": "tockmox-ai", "kind": "Deployment", "name": "tockmox-ui"})
    r = c.post("/actions/go", data={"csrf": csrf, "kind": "restart", "target": tgt, "key": act.new_key(), "back": "/status"})
    q = parse_qs(urlsplit(r.headers["location"]).query)
    assert q["max_age"] == ["300"]
    idp.next_claims = {"nonce": q["nonce"][0], "auth_time": time.time() - 3600}   # the issuer did not re-ask: refused
    r = c.get(f"/auth/callback?code=c&state={q['state'][0]}")
    assert "Not done" in r.text and "sign-in from the last 5 minutes" in r.text and not kube.patches


def test_a_callback_that_is_not_an_actions_is_still_a_sign_in(tmp_path):
    c, csrf, idp, *_ = console(tmp_path)
    r = c.post("/actions/go", data={"csrf": csrf, "kind": "test-alert", "target": "{}", "key": act.new_key(), "back": "/"})
    r = c.get("/auth/callback?code=c&state=some-other-state")
    assert r.status_code == 400 and "Sign-in did not complete" in r.text


def test_activity_lists_nothing_yet_and_says_unknown_when_the_service_is_down(tmp_path):
    c, *_ = console(tmp_path)
    assert "Nothing has been done from the console yet" in c.get("/platform/activity").text
    c2, *_ = console(tmp_path, down=True)
    t = c2.get("/platform/activity").text
    assert "Unknown" in t and "did not answer" in t and "not the same as nothing having been done" in t


def test_a_person_silence_is_still_hidden_and_a_console_silence_is_shown(tmp_path):
    from app.sources import AlertmanagerSource
    am = AM()
    am.silences["s-person"] = {"id": "s-person", "createdBy": "jeff", "status": {"state": "active"}, "endsAt": "2026-11-01T00:00:00Z"}
    am.silences["s-console"] = {"id": "s-console", "createdBy": "Jeff (Tockmox UI)", "status": {"state": "active"},
                                "endsAt": "2026-11-01T00:00:00Z"}
    am.alerts += [{"labels": {"alertname": "A", "severity": "warning"}, "status": {"silencedBy": ["s-person"]}},
                  {"labels": {"alertname": "B", "severity": "warning"}, "status": {"silencedBy": ["s-console"]}},
                  {"labels": {"alertname": "C", "severity": "warning"}, "status": {"silencedBy": []}}]
    rows = AlertmanagerSource("http://am.test", 1, httpx.MockTransport(am.handler)).fetch()
    names = {r["name"]: r for r in rows}
    assert "A" not in names and names["B"]["silenced"]["by"] == "Jeff" and names["C"]["silenced"] is None


# ---------------------------------------------------------------- fresh-eyes review C (claude-sonnet-5-5 via the
# gateway): each test red before its fix

def test_review_1_a_key_is_reserved_first_and_bound_to_its_intent():
    s, am, kube = service()
    it = silence_intent()
    s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    other = dict(silence_intent(), key=it["key"], params={"hours": 24, "reason": "x"})   # the same key, another intent
    code, out = s.handle({"intent": other, "id_token": token(act.nonce_for(other))})
    assert code == 403 and "belongs to another action" in out["reason"] and len(am.silences) == 1


def test_review_1_no_record_no_action():
    s, am, kube = service()

    def refuse_writes(req):
        if "/configmaps" in req.url.path and req.method != "GET":
            return httpx.Response(500, json={"message": "etcd is unhappy"})
        return kube.handler(req)
    s.kube.transport = httpx.MockTransport(refuse_writes)
    it = silence_intent()
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 403 and "could not be recorded first" in out["reason"] and not am.silences


def test_review_1_a_lost_row_still_does_nothing_twice():
    s, am, kube = service()
    it = silence_intent()
    s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    kube.cm = None                                                      # the record is gone (pruned, or 300 later)
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 200 and out["repeat"] and len(am.silences) == 1


def test_review_6_a_silence_that_fails_part_way_leaves_none_behind():
    s, am, _ = service()
    real = am.handler
    n = {"posts": 0}

    def second_fails(req):
        if req.url.path == "/api/v2/silences" and req.method == "POST":
            n["posts"] += 1
            if n["posts"] == 2:
                return httpx.Response(500, text="no")
        return real(req)
    s.tp_am = httpx.MockTransport(second_fails)
    t = {"part": "p", "label": "P", "alerts": [{"alertname": "A", "namespace": "x"}, {"alertname": "B", "namespace": "y"}]}
    it = act.intent("silence", t, {"hours": 1, "reason": "r"}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 403 and all(v["status"]["state"] == "expired" for v in am.silences.values()) and am.silences
    rows = json.loads(_cm_rows(s))
    assert rows[0]["result"] == "failed"
    d = act.describe(it)
    assert "every alert of these names in namespace x, namespace y" in d["effect"]


def _cm_rows(s):
    rows, _ = s.activity.read()
    return json.dumps(rows)


def test_review_5_a_job_that_was_not_created_is_not_reported():
    s, _, kube = service()
    real = kube.handler

    def gone(req):
        if req.url.path.endswith("/jobs") and req.method == "POST":
            return httpx.Response(404, json={"message": "namespaces \"tockmox-ai\" not found"})
        return real(req)
    s.kube.transport = httpx.MockTransport(gone)
    it = act.intent("run-job", {"namespace": "tockmox-ai", "name": "tockmox-model-watch"}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert code == 403 and "404" in out["reason"]


def test_review_4_the_job_does_not_ask_to_block_its_owners_deletion():
    s, _, kube = service()
    it = act.intent("run-job", {"namespace": "tockmox-ai", "name": "tockmox-model-watch"}, {}, "a")
    s.handle({"intent": it, "id_token": token(act.nonce_for(it))})
    assert "blockOwnerDeletion" not in kube.jobs[0]["metadata"]["ownerReferences"][0]


@pytest.mark.parametrize("bad", ["/\t/evil.example", "/\n/evil.example", "//evil.example", "https://evil.example/",
                                 "/ok/../\\evil", "/a b", "javascript:alert(1)"])
def test_review_3_back_is_a_path_on_this_console(bad):
    from app.actions_routes import _back
    assert _back(bad) == "/status"
    assert _back("/status/forgejo?view=list") == "/status/forgejo?view=list"


def test_review_7_a_target_that_is_not_an_object_is_a_400_not_a_crash(tmp_path):
    c, csrf, *_ = console(tmp_path)
    for t in ("[1]", "5", '"x"'):
        r = c.post("/actions/go", data={"csrf": csrf, "kind": "test-alert", "target": t, "key": act.new_key()})
        assert r.status_code == 400, t



# ---------------------------------------------------------------- the lab run (a k3s lab cluster, 2026-11-01): the
# first start crashed on int("tcp://10.43.x.x:8081"), Kubernetes' service-link variable for the Service tockmox-actions.
# Explicit container env wins over a service link, so the risk is a variable the code reads with a default and the
# chart does not set. The scan covers every literal name any module in app/ reads, against every Service the AI
# layer's templates name.

import pathlib
import re

_REPO = pathlib.Path(__file__).resolve().parents[2]
_READS = re.compile(r"""(?:environ\.get|getenv|environ\[)\(?\s*["']([A-Z][A-Z0-9_]+)["']""")


def _service_names() -> set:
    out = set()
    for f in (_REPO / "charts" / "tockmox-ai" / "templates").glob("*.yaml"):
        out |= set(re.findall(r"(?m)^kind: Service\s*\nmetadata:\s*\n\s+name: ([a-z0-9-]+)\s*$", f.read_text()))
    return out


def _is_service_link(var: str, services: set) -> bool:
    for s in services:
        p = re.escape(s.upper().replace("-", "_"))
        if re.fullmatch(p + r"_(SERVICE_HOST|SERVICE_PORT(_[A-Z0-9_]+)?|PORT(_\d+_(TCP|UDP|SCTP)(_PROTO|_PORT|_ADDR)?)?)", var):
            return True
    return False


def _env_reads() -> set:
    app = _REPO / "tockmox-ui" / "app"
    names = set()
    for f in app.glob("*.py"):
        names |= set(_READS.findall(f.read_text()))
    return names | {svcmod.CONFIG_ENV, svcmod.LISTEN_PORT_ENV}


def test_lab_no_variable_the_code_reads_is_a_service_link_name():
    services = _service_names()
    assert {"tockmox-ui", "tockmox-actions"} <= services, services       # the scan sees the Services
    assert _is_service_link("TOCKMOX_ACTIONS_PORT", services)            # and the predicate can go red: the old name
    assert _is_service_link("TOCKMOX_UI_PORT_8080_TCP_ADDR", services)
    assert not _is_service_link("TOCKMOX_ACTIONS_LISTEN_PORT", services)
    reads = _env_reads()
    assert "TOCKMOX_UI_CONFIG" in reads and "TOCKMOX_ACTIONS_LISTEN_PORT" in reads   # the scan sees the reads
    assert not {v for v in reads if _is_service_link(v, services)}


def _start(tmp_path, monkeypatch, listen=None):
    cfg = tmp_path / "c.yaml"
    cfg.write_text(yaml.safe_dump({"oidc": {"issuer": ISS}, "actions": dict(copy.deepcopy(ACTIONS), namespace="tockmox-ai")}))
    monkeypatch.setenv("TOCKMOX_ACTIONS_CONFIG", str(cfg))
    monkeypatch.setenv("TOCKMOX_ACTIONS_PORT", "tcp://10.43.116.205:8081")      # what Kubernetes sets
    if listen is None:
        monkeypatch.delenv("TOCKMOX_ACTIONS_LISTEN_PORT", raising=False)
    else:
        monkeypatch.setenv("TOCKMOX_ACTIONS_LISTEN_PORT", listen)
    seen = {}
    import uvicorn
    monkeypatch.setattr(uvicorn, "run", lambda app, **kw: seen.update(kw))
    svcmod.main()
    return seen["port"]


def test_lab_main_starts_with_the_service_link_variable_set(tmp_path, monkeypatch):
    assert _start(tmp_path, monkeypatch) == 8081


def test_lab_main_listens_where_its_own_variable_says(tmp_path, monkeypatch):
    assert _start(tmp_path, monkeypatch, listen="9000") == 9000

# SPDX-License-Identifier: Apache-2.0
"""TM-1315: identity actions from the console. A recovery link for a person who is not an administrator, and
membership of the user group, through a narrow Authentik service account held by tockmox-actions.

  shared     the identity kinds' targets and parameters; every one is a step-up kind
  service    a link goes back once, to the person who asked, and is in no record, log line or replay; an
             administrator, a superuser, a service account or a deactivated account is refused before Authentik is
             asked; Authentik's own refusal is reported; membership names the user group and nothing else
  console    the Identity page offers no recovery link for an administrator; the round trip asks for a fresh sign-in;
             the page holding the link is not stored; off means absent

The fake Authentik enforces what the identity layer's blueprint and reconciler grant the service account: users are
visible, a recovery link only for a granted user, add and remove on the user group only (the admin group is not even
visible to it). Run from tockmox-ui/: python -m pytest tests
"""
import copy
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402
from tests import test_actions as base  # noqa: E402

TOKEN = "t" * 96
LINK = "https://auth.int.example.com/if/flow/tockmox-recovery/?flow_token=SECRET-FLOW-TOKEN"


class Authentik:
    def __init__(self):
        self.users = {
            7: {"pk": 7, "username": "dawn", "name": "Dawn", "email": "dawn@example.com", "is_active": True,
                "type": "internal", "is_superuser": False, "groups_obj": [{"name": "tockmox-users"}], "last_login": None},
            8: {"pk": 8, "username": "jeff", "name": "Jeff", "email": "jeff@example.com", "is_active": True,
                "type": "internal", "is_superuser": False, "groups_obj": [{"name": "tockmox-admins"}, {"name": "tockmox-users"}],
                "last_login": "2026-10-31T10:00:00Z"},
            9: {"pk": 9, "username": "kid", "name": "", "email": "", "is_active": True, "type": "internal",
                "is_superuser": False, "groups_obj": [], "last_login": None},
            10: {"pk": 10, "username": "akadmin", "name": "authentik Default Admin", "email": "", "is_active": True,
                 "type": "internal", "is_superuser": True, "groups_obj": [{"name": "authentik Admins"}], "last_login": None},
            11: {"pk": 11, "username": "tockmox-console-actions", "name": "", "email": "", "is_active": True,
                 "type": "service_account", "is_superuser": False, "groups_obj": [], "last_login": None},
            12: {"pk": 12, "username": "gone", "name": "", "email": "", "is_active": False, "type": "internal",
                 "is_superuser": False, "groups_obj": [{"name": "tockmox-users"}], "last_login": None},
        }
        self.granted = {7, 9}                     # what the reconciler grants: active people outside the admin group
        self.groups = {"g-users": "tockmox-users", "g-admins": "tockmox-admins"}
        self.calls = []

    def handler(self, req: httpx.Request):
        p, m = req.url.path, req.method
        self.calls.append((m, p))
        if req.headers.get("authorization") != "Bearer " + TOKEN:
            return httpx.Response(403, json={"detail": "Authentication credentials were not provided."})
        if p == "/api/v3/core/users/" and m == "GET":
            return httpx.Response(200, json={"pagination": {"next": 0}, "results": list(self.users.values())})
        mt = re.fullmatch(r"/api/v3/core/users/(\d+)/", p)
        if mt and m == "GET":
            u = self.users.get(int(mt.group(1)))
            return httpx.Response(200, json=u) if u else httpx.Response(404, json={"detail": "Not found."})
        mt = re.fullmatch(r"/api/v3/core/users/(\d+)/recovery/", p)
        if mt and m == "POST":
            if int(mt.group(1)) not in self.granted:
                return httpx.Response(403, json={"detail": "You do not have permission to perform this action."})
            return httpx.Response(200, json={"link": LINK})
        if p == "/api/v3/core/groups/" and m == "GET":       # view_group on the user group only
            name = req.url.params.get("name")
            res = [{"pk": "g-users", "name": "tockmox-users"}] if name in (None, "tockmox-users") else []
            return httpx.Response(200, json={"pagination": {"next": 0}, "results": res})
        mt = re.fullmatch(r"/api/v3/core/groups/([^/]+)/(add_user|remove_user)/", p)
        if mt and m == "POST":
            gid, op = mt.groups()
            if gid != "g-users":
                return httpx.Response(403, json={"detail": "You do not have permission to perform this action."})
            pk = json.loads(req.content)["pk"]
            u = self.users[pk]
            names = [g["name"] for g in u["groups_obj"] if g["name"] != "tockmox-users"]
            u["groups_obj"] = [{"name": n} for n in names + (["tockmox-users"] if op == "add_user" else [])]
            return httpx.Response(204)
        return httpx.Response(404, json={"detail": "Not found."})


def actions_on(tmp_path, **identity):
    tf = tmp_path / "ak-token"
    tf.write_text(TOKEN + "\n")
    a = copy.deepcopy(base.ACTIONS)
    a["identity"] = dict({"enabled": True, "tokenFile": str(tf)}, **identity)
    return a


def service(tmp_path, ak=None, **identity):
    ak = ak or Authentik()
    s, am, kube = base.service(actions=actions_on(tmp_path, **identity))
    s.authentik.transport = httpx.MockTransport(ak.handler)
    return s, ak, kube


def intent(kind, pk, username, params=None):
    return act.intent(kind, {"user": pk, "username": username}, params if params is not None else
                      ({"hours": 24} if kind == "recovery-link" else {}), "a")


def go(s, it, **tok):
    return s.handle({"intent": it, "id_token": base.token(act.nonce_for(it), **tok)})


# ---------------------------------------------------------------- shared

def test_identity_kinds_are_step_up_and_off_unless_turned_on():
    assert all(act.step_up(k) for k in act.IDENTITY_KINDS)
    off = act.parse(dict(base.ACTIONS, url="http://a.test"))
    with pytest.raises(act.Refused, match="not turned on"):
        act.check(off, intent("recovery-link", 7, "dawn"))


@pytest.mark.parametrize("target, params, why", [
    ({"user": True, "username": "dawn"}, {"hours": 24}, "one user"),
    ({"user": "7", "username": "dawn"}, {"hours": 24}, "one user"),
    ({"user": 7, "username": "da\nwn"}, {"hours": 24}, "one user"),
    ({"user": 7, "username": "x" * 151}, {"hours": 24}, "one user"),
    ({"user": 7, "username": "dawn", "group": "tockmox-admins"}, {"hours": 24}, "one user"),
    ({"user": 7, "username": "dawn"}, {"hours": 2}, "1, 24 or 72 hours"),
    ({"user": 7, "username": "dawn"}, {"hours": 24, "email": True}, "1, 24 or 72 hours"),
])
def test_check_refuses_a_malformed_identity_intent(tmp_path, target, params, why):
    c = act.parse(dict(actions_on(tmp_path), url="http://a.test"))
    with pytest.raises(act.Refused, match=why):
        act.check(c, act.intent("recovery-link", target, params, "a"))
    with pytest.raises(act.Refused, match="no parameters"):
        act.check(c, act.intent("add-member", {"user": 7, "username": "dawn"}, {"group": "tockmox-admins"}, "a"))


# ---------------------------------------------------------------- the service

def test_a_recovery_link_goes_back_once_and_is_kept_nowhere(tmp_path, capsys):
    s, ak, kube = service(tmp_path)
    it = intent("recovery-link", 7, "dawn")
    code, out = go(s, it)
    assert code == 200 and out["result"] == "done" and out["secret"] == LINK
    assert ("POST", "/api/v3/core/users/7/recovery/") in ak.calls
    assert "SECRET-FLOW-TOKEN" not in json.dumps(kube.cm)                       # not in the record
    code, again = go(s, it)                                                      # a replay: not again, and no link
    assert code == 200 and again["repeat"] and "secret" not in again
    assert sum(1 for c in ak.calls if c[1].endswith("/recovery/")) == 1
    assert "SECRET-FLOW-TOKEN" not in capsys.readouterr().out                    # not in any log line


@pytest.mark.parametrize("pk, name, why", [
    (8, "jeff", "is an administrator"),
    (10, "akadmin", "is an administrator"),
    (11, "tockmox-console-actions", "not a person's account"),
    (12, "gone", "is deactivated"),
    (7, "someone-else", "is now 'dawn'"),
    (99, "nobody", "no such user"),
])
def test_no_recovery_link_for_who_must_not_have_one(tmp_path, pk, name, why):
    s, ak, _ = service(tmp_path)
    code, out = go(s, intent("recovery-link", pk, name))
    assert code == 403 and why in out["reason"]
    assert not [c for c in ak.calls if c[1].endswith("/recovery/")]             # refused before Authentik is asked


def test_authentiks_own_refusal_is_reported(tmp_path):
    ak = Authentik()
    ak.granted = set()                       # the reconciler has not run yet, or took the grant back
    s, ak, _ = service(tmp_path, ak)
    code, out = go(s, intent("recovery-link", 7, "dawn"))
    assert code == 403 and "Authentik refused the recovery link (403)" in out["reason"]
    rows, _ = s.activity.read()
    assert rows[0]["result"] == "failed"


def test_an_identity_action_needs_a_recent_sign_in(tmp_path):
    s, ak, _ = service(tmp_path)
    code, out = go(s, intent("add-member", 9, "kid"), auth_time=time.time() - 3600)
    assert code == 403 and "sign-in from the last 5 minutes" in out["reason"] and not ak.calls


def test_membership_changes_the_user_group_only_and_says_when_nothing_changed(tmp_path):
    s, ak, _ = service(tmp_path)
    code, out = go(s, intent("add-member", 9, "kid"))
    assert code == 200 and out["detail"] == "added" and ("POST", "/api/v3/core/groups/g-users/add_user/") in ak.calls
    assert {"name": "tockmox-users"} in ak.users[9]["groups_obj"]
    n = len(ak.calls)
    code, out = go(s, intent("add-member", 9, "kid"))
    assert code == 200 and out["detail"] == "already a member" and not any("add_user" in c[1] for c in ak.calls[n:])
    code, out = go(s, intent("remove-member", 8, "jeff"))          # an administrator's user-group membership is not admin
    assert code == 200 and out["detail"] == "removed" and {"name": "tockmox-admins"} in ak.users[8]["groups_obj"]
    assert not any("g-admins" in c[1] for c in ak.calls)


def test_a_group_the_account_cannot_see_is_refused_in_words(tmp_path):
    s, ak, _ = service(tmp_path, userGroup="tockmox-admins")       # a misconfigured site: Authentik shows it nothing
    code, out = go(s, intent("add-member", 9, "kid"))
    assert code == 403 and "cannot see a group named tockmox-admins" in out["reason"]


def test_no_token_is_a_refusal_with_the_reason(tmp_path):
    s, ak, _ = service(tmp_path, tokenFile=str(tmp_path / "missing"))
    code, out = go(s, intent("recovery-link", 7, "dawn"))
    assert code == 403 and "no Authentik account is configured" in out["reason"] and not ak.calls


def test_the_api_is_the_issuers_origin_unless_set(tmp_path):
    s, _, _ = service(tmp_path)
    assert s.authentik.url == "https://auth.int.example.com"
    s2, _, _ = service(tmp_path, apiUrl="http://authentik.test/")
    assert s2.authentik.url == "http://authentik.test"


# ---------------------------------------------------------------- the console

def wire(tmp_path, identity=True):
    """The console with its actions service's Authentik pointed at a fake."""
    ak = Authentik()
    a = actions_on(tmp_path) if identity else copy.deepcopy(base.ACTIONS)
    c, csrf, idp, am, kube, sent = base.console(tmp_path, actions=a, authentik=ak.handler)
    return c, csrf, idp, ak, sent, kube


def test_the_identity_page_offers_no_recovery_link_for_an_administrator(tmp_path):
    c, csrf, idp, ak, sent, kube = wire(tmp_path)
    t = c.get("/platform/identity").text
    assert "dawn" in t and "jeff" in t and "Administrator" in t
    assert "kind=recovery-link&amp;user=7" in t and "kind=recovery-link&amp;user=8" not in t
    assert "tockmox-console-actions" not in t                                   # a service account is not a person
    assert "kind=recovery-link&amp;user=10" not in t and "kind=recovery-link&amp;user=12" not in t   # superuser, deactivated
    assert 'href="/platform/identity"' in c.get("/platform/activity").text                  # on the rail


def test_off_means_no_identity_page_and_no_rail_item(tmp_path):
    c, *_ = wire(tmp_path, identity=False)
    assert c.get("/platform/identity").status_code == 404
    assert 'href="/platform/identity"' not in c.get("/platform/activity").text


def test_a_recovery_link_end_to_end(tmp_path):
    c, csrf, idp, ak, sent, kube = wire(tmp_path)
    t = c.get("/actions/confirm?kind=recovery-link&user=7&username=dawn").text
    assert "Make a recovery link for dawn?" in t and "shown to you once" in t and 'name="hours"' in t
    form = {k: v.replace("&#34;", '"').replace("&quot;", '"')
            for k, v in re.findall(r'<input type="hidden" name="([a-z]+)" value="([^"]*)"', t)}
    r = c.post("/actions/go", data=dict(form, hours="72"))
    assert r.status_code == 303
    q = parse_qs(urlsplit(r.headers["location"]).query)
    assert q["max_age"] == ["300"]                                                   # a fresh sign-in
    idp.next_claims = {"nonce": q["nonce"][0]}
    r = c.get(f"/auth/callback?code=c&state={q['state'][0]}")
    assert r.status_code == 200, r.text
    assert LINK.replace("&", "&amp;") in r.text or LINK in r.text
    assert r.headers.get("cache-control") == "no-store"
    assert sent[0]["intent"]["params"] == {"hours": 72}
    a = c.get("/platform/activity").text
    assert "Made a recovery link for dawn" in a and "SECRET-FLOW-TOKEN" not in a


def test_review_the_identity_users_endpoint_is_off_when_the_kind_is(tmp_path):
    from fastapi.testclient import TestClient
    from app.actions_service import create_service
    doc = {"oidc": {"issuer": base.ISS}, "actions": dict(copy.deepcopy(base.ACTIONS), namespace="tockmox-ai")}
    r = TestClient(create_service(doc)).get("/v1/identity/users")
    assert r.status_code == 404


# ---------------------------------------------------------------- fresh-eyes review D (claude-sonnet-5-5 via the
# gateway): each test red before its fix

def test_review_d2_a_person_in_a_group_the_console_does_not_know_gets_no_link(tmp_path):
    ak = Authentik()
    ak.users[9]["groups_obj"] = [{"name": "ops"}]          # ops may sit under the admin group: groups_obj cannot say
    ak.granted.add(9)
    s, ak, _ = service(tmp_path, ak)
    code, out = go(s, intent("recovery-link", 9, "kid"))
    assert code == 403 and "in ops, a group the console does not know" in out["reason"]
    assert not [c for c in ak.calls if c[1].endswith("/recovery/")]
    s2, ak2, _ = service(tmp_path, ak, recoveryGroups=["ops"])                # a site that names it
    code, out = go(s2, intent("recovery-link", 9, "kid"))
    assert code == 200 and out["secret"] == LINK


def test_review_d2_the_page_says_why_there_is_no_link(tmp_path):
    from tests.test_actions import console as base_console
    ak = Authentik()
    ak.users[9]["groups_obj"] = [{"name": "ops"}]
    c, *_ = base_console(tmp_path, actions=actions_on(tmp_path), authentik=ak.handler)
    t = c.get("/platform/identity").text
    assert "kind=recovery-link&amp;user=9" not in t and "No link here: in ops" in t


def test_review_d4_a_username_authentik_allows_is_one_the_console_can_name(tmp_path):
    ak = Authentik()
    ak.users[9]["username"] = "corp/jane doe"
    s, ak, _ = service(tmp_path, ak)
    code, out = go(s, intent("recovery-link", 9, "corp/jane doe"))
    assert code == 200, out


def test_review_d8_a_link_on_another_address_is_refused(tmp_path):
    ak = Authentik()
    real = ak.handler

    def internal_host(req):
        r = real(req)
        if req.url.path.endswith("/recovery/") and r.status_code == 200:
            return httpx.Response(200, json={"link": "http://authentik-server.tockmox-authentik.svc/if/flow/x/?flow_token=T"})
        return r
    s, _, _ = service(tmp_path, ak, apiUrl="http://authentik-server.tockmox-authentik.svc")
    s.authentik.transport = httpx.MockTransport(internal_host)
    code, out = go(s, intent("recovery-link", 7, "dawn"))
    assert code == 403 and "another address than https://auth.int.example.com" in out["reason"] and "secret" not in out

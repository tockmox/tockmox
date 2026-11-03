# SPDX-License-Identifier: Apache-2.0
"""tockmox-actions: the one process that acts. The Tockmox UI stays write-free.

    python -m app.actions_service            reads TOCKMOX_ACTIONS_CONFIG (default /etc/tockmox-actions/config.yaml) and
                                             listens on TOCKMOX_ACTIONS_LISTEN_PORT (default 8081)

A separate Deployment on the UI's image, with its own ServiceAccount and one narrow credential per kind: Alertmanager
(by NetworkPolicy) for silences and the test alert; a Role that creates Jobs only in the run-now allowlist's
namespaces; a Role that patches only the restart allowlist's workloads, bounded by a ValidatingAdmissionPolicy to the
restartedAt annotation; when the site gives it one, an Argo CD account with get and sync only; and, with the identity
kinds on, an Authentik service account whose role can see users, make a recovery link only for a user the identity
layer's reconciler has granted it (never an administrator), and change membership of the user group only.

API (reachable from the UI pod only, by NetworkPolicy):
  POST /v1/intents   {"intent": {...}, "id_token": "..."}   carry out one intent; 200 with the result
  GET  /v1/activity  the last actions, newest first
  GET  /v1/identity/users   the people Authentik knows, for the Identity page (identity kinds on only)
  GET  /healthz

Nothing is trusted from the caller but what the identity provider signed. Each intent arrives with an ID token the
issuer minted for THIS intent (its nonce is actions.nonce_for(intent)); the service checks the signature, issuer,
audience (the UI's client), expiry, that it was issued in the last ten minutes, the admin group, the nonce, and for a
step-up kind auth_time within actions.stepUpMaxAgeSeconds. The intent's idempotency key makes a replay, or a double
click, do nothing twice: the first result is returned again.

Audit: one JSON line per intent on stdout (`"event": "tockmox.action"`: the person's sub and name, the action, the
target, the result, the reference it made), which Loki keeps, and a row in the activity ConfigMap the Activity page
reads. A recovery link is a secret: it goes back to the person who asked, once, in the answer to that intent, and is
never written to the record, the log line or a replay's answer.
"""
from __future__ import annotations

import json
import logging
import os
import secrets
import ssl
import sys
import threading
import time
from datetime import datetime, timezone

import httpx
import jwt
import yaml
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse

from . import actions as act
from .auth import OIDC

log = logging.getLogger("tockmox.actions")
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
ACTIVITY_MAX = 300
TOKEN_MAX_AGE = 600           # an ID token older than this is not a fresh confirmation, whatever its exp says
CONFIG_ENV = "TOCKMOX_ACTIONS_CONFIG"
LISTEN_PORT_ENV = "TOCKMOX_ACTIONS_LISTEN_PORT"


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class Kube:
    """The few verbs the allowlists need, against the API server, with this pod's token."""

    def __init__(self, url="https://kubernetes.default.svc", token_file=SA + "/token", ca_file=SA + "/ca.crt",
                 timeout=8.0, transport=None):
        self.url, self.token_file, self.ca_file, self.timeout, self.transport = url, token_file, ca_file, timeout, transport

    def _c(self):
        verify = True
        if self.transport is None and os.path.exists(self.ca_file):
            verify = ssl.create_default_context(cafile=self.ca_file)
        h = {}
        if os.path.exists(self.token_file):
            with open(self.token_file, encoding="utf-8") as fh:
                h["Authorization"] = "Bearer " + fh.read().strip()
        return httpx.Client(base_url=self.url, timeout=self.timeout, verify=verify, headers=h, transport=self.transport)

    def call(self, method, path, body=None, ctype="application/json", allow_404=False):
        """The answer's JSON; None for a 404 only when the caller asked (a GET for something that may not exist)."""
        with self._c() as c:
            r = c.request(method, path, content=None if body is None else json.dumps(body),
                          headers={"Content-Type": ctype} if body is not None else {})
        if r.status_code == 404 and allow_404:
            return None
        if r.status_code >= 400:
            msg = ""
            try:
                msg = r.json().get("message", "")
            except Exception:  # noqa: BLE001
                pass
            if msg:                                     # the API's own words are for the operator, not the caller
                log.warning("Kubernetes API %s %s answered %s: %s", method, path, r.status_code, str(msg)[:300])
            raise act.Refused(f"the Kubernetes API answered {r.status_code}")
        return r.json()


class Activity:
    """The last ACTIVITY_MAX actions, newest first, in one ConfigMap this service creates and owns. Its idempotency
    keys outlive a restart for the same reason."""

    def __init__(self, kube: Kube, namespace: str, name: str):
        self.kube, self.ns, self.name = kube, namespace, name
        self.lock = threading.Lock()

    def _path(self, named=True):
        return f"/api/v1/namespaces/{self.ns}/configmaps" + (f"/{self.name}" if named else "")

    def read(self) -> tuple[list, dict | None]:
        cm = self.kube.call("GET", self._path(), allow_404=True)
        if cm is None:
            return [], None
        try:
            rows = json.loads((cm.get("data") or {}).get("activity.json") or "[]")
        except ValueError:
            rows = []
        return (rows if isinstance(rows, list) else []), cm

    def find(self, key: str) -> dict | None:
        rows, _ = self.read()
        return next((r for r in rows if r.get("key") == key), None)

    def add(self, row: dict):
        with self.lock:
            for _ in range(3):
                rows, cm = self.read()
                rows = ([row] + [r for r in rows if r.get("key") != row.get("key")])[:ACTIVITY_MAX]
                data = {"activity.json": json.dumps(rows, separators=(",", ":"))}
                try:
                    if cm is None:
                        self.kube.call("POST", self._path(False), {
                            "apiVersion": "v1", "kind": "ConfigMap",
                            "metadata": {"name": self.name, "namespace": self.ns,
                                         "labels": {"app.kubernetes.io/name": "tockmox-actions",
                                                    "app.kubernetes.io/part-of": "tockmox"}},
                            "data": data})
                    else:
                        cm["data"] = data           # resourceVersion kept: a concurrent write is a 409, retried
                        self.kube.call("PUT", self._path(), cm)
                    return
                except act.Refused as e:
                    if "409" not in str(e):
                        raise
            raise act.Refused("the activity record kept changing underneath; the action ran but its row may be missing")


class Authentik:
    """The identity kinds' one credential: an Authentik API token for the service account the identity layer's
    blueprint makes (sso.consoleActions). What it may do is Authentik's to enforce, not this code's: its role sees
    users, makes a recovery link only for users the reconciler granted it (no administrator), and adds to or removes
    from the user group only. The checks here say why in words before Authentik would refuse."""

    PAGE = 200
    MAX_USERS = 2000

    def __init__(self, url: str, token_file: str, admin_group: str, user_group: str, timeout=8.0, transport=None,
                 public_origin: str = "", recovery_groups=()):
        self.url, self.token_file, self.timeout, self.transport = url.rstrip("/"), token_file, timeout, transport
        self.admin_group, self.user_group = admin_group, user_group
        self.public_origin = (public_origin or url).rstrip("/")
        self.known = frozenset({user_group, *recovery_groups})

    NOT_CONFIGURED = ("no Authentik account is configured for identity actions (tockmoxUi.actions.identity, and "
                      "sso.consoleActions in the identity layer)")
    TOKEN_EMPTY = "the identity actions' Authentik token is empty"

    def _token(self) -> str:
        if not (self.url and self.token_file and os.path.exists(self.token_file)):
            return ""
        with open(self.token_file, encoding="utf-8") as fh:
            return fh.read().strip()

    def unready(self) -> str:
        """Why no call can be made, in fixed words, or "" (the Identity page says it without an exception's text)."""
        if not (self.url and self.token_file and os.path.exists(self.token_file)):
            return self.NOT_CONFIGURED
        return "" if self._token() else self.TOKEN_EMPTY

    def _c(self):
        why = self.unready()
        if why:
            raise act.Refused(why)
        tok = self._token()
        return httpx.Client(base_url=self.url + "/api/v3", timeout=self.timeout, transport=self.transport,
                            headers={"Authorization": "Bearer " + tok, "Accept": "application/json"})

    @staticmethod
    def _err(r, what):
        detail = ""
        try:
            j = r.json()
            detail = str(j.get("detail") or j.get("non_field_errors") or "")[:200]
        except Exception:  # noqa: BLE001
            pass
        if detail:                                  # Authentik's own words are for the operator, not the caller
            log.warning("Authentik refused %s (%s): %s", what, r.status_code, detail)
        return act.Refused(f"Authentik refused {what} ({r.status_code})")

    def person(self, u: dict) -> dict:
        """One user as the Identity page and the checks see them. `groups_obj` is direct membership only, so a group
        nested under the admin group would not read as admin: a recovery link is offered only to a person whose every
        group is one this side knows (the user group, and identity.recoveryGroups), which fails closed on any other,
        a nested admin group included (review D-2). Authentik's own grant is the second, independent bound."""
        groups = sorted({str(g.get("name", "")) for g in (u.get("groups_obj") or []) if isinstance(g, dict)})
        p = {"pk": u.get("pk"), "username": str(u.get("username", "")), "name": str(u.get("name", "")),
             "email": str(u.get("email", "")), "active": bool(u.get("is_active")), "type": str(u.get("type", "")),
             "superuser": bool(u.get("is_superuser")), "admin": self.admin_group in groups,
             "member": self.user_group in groups, "last_login": u.get("last_login"), "groups": groups}
        other = [g for g in groups if g not in self.known]
        why = ("an administrator" if p["admin"] or p["superuser"] else
               "deactivated" if not p["active"] else
               f"in {', '.join(other)}, a group the console does not know" if other else "")
        p["recoverable"], p["why_not"] = not why, why
        return p

    def users(self) -> tuple[list[dict], str]:
        """(people, "") or ([], why). The why is fixed words and Authentik's status code, never an exception's text:
        it goes back over HTTP to the UI (CodeQL py/stack-trace-exposure on the first PR of this endpoint)."""
        why = self.unready()
        if why:
            return [], why
        out, page = [], 1
        with self._c() as c:
            while len(out) < self.MAX_USERS:
                r = c.get("/core/users/", params={"page": page, "page_size": self.PAGE, "include_roles": "false",
                                                  "ordering": "username"})
                if r.status_code >= 300:
                    return [], f"Authentik refused the user list ({r.status_code})"
                j = r.json()
                out += [self.person(u) for u in j.get("results") or [] if u.get("type") in ("internal", "external")]
                if not (j.get("pagination") or {}).get("next"):
                    break
                page += 1
        return out, ""

    def user(self, c, pk: int, username: str) -> dict:
        r = c.get(f"/core/users/{pk}/", params={"include_roles": "false"})
        if r.status_code == 404:
            raise act.Refused("Authentik has no such user")
        if r.status_code >= 300:
            raise self._err(r, "the user")
        p = self.person(r.json())
        if p["username"] != username:
            raise act.Refused(f"user {pk} is now {p['username']!r}, not {username!r}; open the Identity page again")
        if p["type"] not in ("internal", "external"):
            raise act.Refused(f"{username} is not a person's account")
        return p

    def recovery_link(self, pk: int, username: str, hours: int) -> str:
        with self._c() as c:
            p = self.user(c, pk, username)
            if not p["recoverable"]:
                raise act.Refused(f"{username} is {p['why_not']}; make their recovery link in Authentik's own console")
            r = c.post(f"/core/users/{pk}/recovery/", json={"token_duration": f"hours={int(hours)}"})
            if r.status_code >= 300:
                raise self._err(r, "the recovery link")
            link = str((r.json() or {}).get("link", ""))
        # Authentik builds the link from the Host it was asked on: one that is not the issuer's public origin would
        # be dead (or plain http) in the person's hands (review D-8)
        if not link.startswith(self.public_origin + "/"):
            raise act.Refused(f"Authentik made a link on another address than {self.public_origin}; set "
                              "identity.apiUrl to Authentik's public address (or leave it empty)")
        return link

    def _group(self, c) -> str:
        r = c.get("/core/groups/", params={"name": self.user_group, "include_users": "false",
                                            "include_children": "false", "include_parents": "false"})
        if r.status_code >= 300:
            raise self._err(r, "the user group")
        hit = [g for g in (r.json().get("results") or []) if g.get("name") == self.user_group]
        if not hit:
            raise act.Refused(f"the service account cannot see a group named {self.user_group}")
        return str(hit[0]["pk"])

    def membership(self, pk: int, username: str, add: bool) -> str:
        with self._c() as c:
            p = self.user(c, pk, username)
            if p["member"] == add:
                return "already a member" if add else "was not a member"
            gid = self._group(c)
            r = c.post(f"/core/groups/{gid}/{'add_user' if add else 'remove_user'}/", json={"pk": pk})
            if r.status_code >= 300:
                raise self._err(r, "the membership change")
        return "added" if add else "removed"


class Service:
    def __init__(self, doc: dict, transports: dict | None = None, now=time.time):
        tp = transports or {}
        self.cfg = act.parse(doc.get("actions"))
        oidc = doc.get("oidc") or {}
        self.issuer = str(oidc.get("issuer", "")).rstrip("/")
        self.client_id = str(oidc.get("clientId", "tockmox-ui"))
        self.admin_group = str((doc.get("roles") or {}).get("adminGroup", "tockmox-admins"))
        src = doc.get("sources") or {}
        self.am_url = str((src.get("alertmanager") or {}).get("url", "")).rstrip("/")
        kube = src.get("kubernetes") or {}
        self.timeout = float(src.get("timeoutSeconds", 8))
        self.oidc = OIDC(self.issuer, self.client_id, "", "", timeout=self.timeout, transport=tp.get("oidc"))
        self.kube = Kube(str(kube.get("url", "https://kubernetes.default.svc")).rstrip("/"),
                         str(kube.get("tokenFile", SA + "/token")), str(kube.get("caFile", SA + "/ca.crt")),
                         self.timeout, tp.get("kube"))
        self.tp_am, self.tp_argo = tp.get("alertmanager"), tp.get("argocd")
        self.now = now
        if not self.cfg.namespace:
            raise ValueError("actions.namespace: the namespace the activity record lives in is required")
        if not self.issuer:
            raise ValueError("oidc.issuer is required: every intent is checked against the issuer's own signature")
        self.activity = Activity(self.kube, self.cfg.namespace, self.cfg.activity_configmap)
        public = self.issuer.split("/application/")[0]
        self.authentik = Authentik(self.cfg.identity_api or public, self.cfg.identity_token_file, self.admin_group,
                                   self.cfg.user_group, self.timeout, tp.get("authentik"), public_origin=public,
                                   recovery_groups=self.cfg.recovery_groups)
        self.inflight: set = set()
        self.inflight_lock = threading.Lock()
        self.seen: dict = {}            # key -> (nonce, row, at): this process's memory, for a record that lost a row

    # ------------------------------------------------------------ who is asking

    def verify(self, it: dict, id_token: str) -> dict:
        if not id_token or len(id_token) > 16384:
            raise act.Refused("no ID token came with the intent")
        try:
            d = self.oidc.discovery()
            claims = jwt.decode(id_token, self.oidc._key_for(id_token), algorithms=["RS256", "ES256", "EdDSA"],
                                audience=self.client_id, issuer=d["issuer"], leeway=30,
                                options={"require": ["exp", "iat", "sub", "aud", "iss", "nonce"]})
        except act.Refused:
            raise
        except Exception as e:  # noqa: BLE001
            raise act.Refused(f"the ID token could not be verified ({type(e).__name__})") from e
        now = self.now()
        if claims.get("nonce") != act.nonce_for(it):
            raise act.Refused("the sign-in was not made for this action")
        if claims["sub"] != it.get("sub"):
            raise act.Refused("the intent names a different person than the sign-in")
        if now - float(claims["iat"]) > TOKEN_MAX_AGE:
            raise act.Refused("the confirmation is too old; confirm again")
        groups = claims.get("groups")
        if not isinstance(groups, list):
            raise act.Refused("the ID token names no groups; the identity provider must include the groups claim in it")
        if self.admin_group not in groups:
            raise act.Refused("only platform administrators may act from the console")
        if act.step_up(it["kind"]):
            at = claims.get("auth_time")
            if not isinstance(at, (int, float)) or now - float(at) > self.cfg.step_up_max_age + 30:
                raise act.Refused(f"this action needs a sign-in from the last {self.cfg.step_up_max_age // 60} minutes")
        return claims

    # ------------------------------------------------------------ the kinds

    def _am(self):
        if not self.am_url:
            raise act.Refused("no Alertmanager is configured")
        return httpx.Client(base_url=self.am_url, timeout=self.timeout, transport=self.tp_am)

    def do_silence(self, it, who):
        t, p = it["target"], it["params"]
        start = self.now()
        end = start + int(p["hours"]) * 3600
        ids = []
        with self._am() as c:
            try:
                for m in act.silence_matchers(t):
                    r = c.post("/api/v2/silences", json={
                        "matchers": m, "startsAt": _iso(start), "endsAt": _iso(end),
                        "createdBy": f"{who}{act.CREATED_BY_SUFFIX}",
                        "comment": f"{str(p['reason']).strip()} [tockmox-action {it['key']}]"})
                    if r.status_code >= 300:
                        log.warning("Alertmanager refused a silence for %s (%s): %s", it["key"], r.status_code, r.text[:200])
                        raise act.Refused(f"Alertmanager refused the silence ({r.status_code})")
                    ids.append(str(r.json().get("silenceID", "")))
            except Exception:
                for sid in ids:                     # all or none: expire what was made before the failure
                    try:
                        c.delete(f"/api/v2/silence/{sid}")
                    except Exception:  # noqa: BLE001 - the audit line names them either way
                        log.warning("could not expire partial silence %s", sid)
                raise
        return {"ref": ids, "until": end, "detail": f"until {_iso(end)}"}

    def do_expire(self, it, who):
        sid = it["target"]["silence"]
        with self._am() as c:
            r = c.get(f"/api/v2/silence/{sid}")
            if r.status_code == 404:
                raise act.Refused("Alertmanager has no such silence")
            r.raise_for_status()
            s = r.json()
            if not str(s.get("createdBy", "")).endswith(act.CREATED_BY_SUFFIX):
                raise act.Refused("that silence was not made from the console; expire it in Alertmanager")
            if (s.get("status") or {}).get("state") == "expired":
                return {"ref": [sid], "detail": "already expired"}
            r = c.delete(f"/api/v2/silence/{sid}")
            if r.status_code >= 300:
                raise act.Refused(f"Alertmanager did not expire it ({r.status_code})")
        return {"ref": [sid], "detail": "expired"}

    def do_run_job(self, it, who):
        ns, name = it["target"]["namespace"], it["target"]["name"]
        cj = self.kube.call("GET", f"/apis/batch/v1/namespaces/{ns}/cronjobs/{name}", allow_404=True)
        if cj is None:
            raise act.Refused(f"there is no CronJob {ns}/{name}")
        jt = (cj.get("spec") or {}).get("jobTemplate") or {}
        suffix = secrets.token_hex(3)
        jname = f"{name[:63 - 8]}-run-{suffix}"[:63]
        meta = jt.get("metadata") or {}
        labels = dict(meta.get("labels") or {})
        labels["tockmox.com/run-now"] = "true"
        ann = dict(meta.get("annotations") or {})
        ann.update({"cronjob.kubernetes.io/instantiate": "manual", "tockmox.com/requested-by": who,
                    "tockmox.com/action": it["key"]})
        job = {"apiVersion": "batch/v1", "kind": "Job",
               "metadata": {"name": jname, "namespace": ns, "labels": labels, "annotations": ann,
                            "ownerReferences": [{"apiVersion": "batch/v1", "kind": "CronJob", "name": name,
                                                 "uid": cj["metadata"]["uid"], "controller": True}]},
               "spec": jt.get("spec") or {}}
        self.kube.call("POST", f"/apis/batch/v1/namespaces/{ns}/jobs", job)
        return {"ref": [jname], "detail": f"Job {jname} started"}

    def _argo(self):
        if not (self.cfg.argocd_url and self.cfg.argocd_token_file and os.path.exists(self.cfg.argocd_token_file)):
            raise act.Refused("no Argo CD account is configured for actions (actions.argocd)")
        with open(self.cfg.argocd_token_file, encoding="utf-8") as fh:
            tok = fh.read().strip()
        return httpx.Client(base_url=self.cfg.argocd_url, timeout=self.timeout, transport=self.tp_argo,
                            headers={"Authorization": "Bearer " + tok})

    def do_refresh(self, it, who):
        app = it["target"]["app"]
        with self._argo() as c:
            r = c.get(f"/api/v1/applications/{app}", params={"refresh": "normal"})
            if r.status_code >= 300:
                raise act.Refused(f"Argo CD did not refresh it ({r.status_code})")
        return {"ref": [app], "detail": "refresh requested"}

    def do_sync(self, it, who):
        app = it["target"]["app"]
        with self._argo() as c:
            r = c.post(f"/api/v1/applications/{app}/sync", json={"prune": False, "dryRun": False})
            if r.status_code >= 300:
                log.warning("Argo CD did not start a sync of %s for %s (%s): %s", app, it["key"], r.status_code, r.text[:200])
                raise act.Refused(f"Argo CD did not start a sync ({r.status_code})")
        return {"ref": [app], "detail": "sync started"}

    def do_restart(self, it, who):
        t = it["target"]
        plural = {"Deployment": "deployments", "StatefulSet": "statefulsets"}[t["kind"]]
        patch = {"spec": {"template": {"metadata": {"annotations": {
            "kubectl.kubernetes.io/restartedAt": datetime.fromtimestamp(self.now(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}}}}}
        r = self.kube.call("PATCH", f"/apis/apps/v1/namespaces/{t['namespace']}/{plural}/{t['name']}", patch,
                           ctype="application/strategic-merge-patch+json", allow_404=True)
        if r is None:
            raise act.Refused(f"there is no {t['kind']} {t['namespace']}/{t['name']}")
        return {"ref": [t["name"]], "detail": "restart started"}

    def do_test_alert(self, it, who):
        start = self.now()
        alert = {"labels": {"alertname": "TockmoxTestAlert", "severity": "warning", "namespace": self.cfg.namespace,
                            "tockmox_test": "true"},
                 "annotations": {"summary": f"Test alert from the Tockmox console, sent by {who}",
                                 "description": "Sent from the Tockmox UI to prove the alert path reaches this phone. "
                                                "It resolves by itself after five minutes. Nothing is wrong."},
                 "startsAt": _iso(start), "endsAt": _iso(start + 300)}
        with self._am() as c:
            r = c.post("/api/v2/alerts", json=[alert])
            if r.status_code >= 300:
                raise act.Refused(f"Alertmanager refused the test alert ({r.status_code})")
        return {"ref": [], "detail": "sent; resolves in five minutes"}

    def do_recovery_link(self, it, who):
        t = it["target"]
        link = self.authentik.recovery_link(t["user"], t["username"], int(it["params"]["hours"]))
        return {"ref": [t["username"]], "detail": f"link made, good once for {it['params']['hours']}h", "secret": link}

    def do_add_member(self, it, who):
        t = it["target"]
        return {"ref": [t["username"]], "detail": self.authentik.membership(t["user"], t["username"], True)}

    def do_remove_member(self, it, who):
        t = it["target"]
        return {"ref": [t["username"]], "detail": self.authentik.membership(t["user"], t["username"], False)}

    # ------------------------------------------------------------ one intent

    def handle(self, body) -> tuple[int, dict]:
        if not isinstance(body, dict):
            return 400, {"result": "refused", "reason": "not an intent"}
        it, tok = body.get("intent"), str(body.get("id_token") or "")
        who, sub = "", ""
        try:
            act.check(self.cfg, it)
            claims = self.verify(it, tok)
            sub = claims["sub"]
            who = str(claims.get("name") or claims.get("preferred_username") or sub)[:80]
            with self.inflight_lock:                                # two clicks at once: the second does nothing
                if it["key"] in self.inflight:
                    raise act.Refused("this action is already running; its result will be in Activity")
                self.inflight.add(it["key"])
            try:
                return self._once(it, sub, who)
            finally:
                with self.inflight_lock:
                    self.inflight.discard(it["key"])
        except act.Refused as e:                    # e.reason: the sentence written for a person, never str(e)
            self.audit(it if isinstance(it, dict) else {}, sub, who, "refused", [], e.reason)
            return 403, {"result": "refused", "reason": e.reason}
        except Exception as e:  # noqa: BLE001 - the result is in words, never a stack trace to the browser
            log.warning("action failed: %s: %s", type(e).__name__, e)
            self.audit(it if isinstance(it, dict) else {}, sub, who, "failed", [], type(e).__name__)
            return 502, {"result": "failed", "reason": f"the action did not complete ({type(e).__name__})"}

    def _once(self, it, sub, who) -> tuple[int, dict]:
        """Carry out a verified intent once. The key is RESERVED in the record before anything is done (no record,
        no action), and a key is bound to the intent it was first used for: the same key with another intent is
        refused, a replay of the same intent returns its first result."""
        nonce = act.nonce_for(it)
        now = self.now()
        self.seen = {k: v for k, v in self.seen.items() if now - v[2] < 3600}
        prior = self.activity.find(it["key"]) or (self.seen.get(it["key"]) or (None, None, 0))[1]
        if prior is not None:
            if prior.get("nonce") != nonce:
                raise act.Refused("that idempotency key belongs to another action")
            if prior.get("result") == "running":
                raise act.Refused("this action is already running; its result will be in Activity")
            self.audit(it, sub, who, "repeat", prior.get("ref") or [], "already " + str(prior.get("result")))
            return 200, dict(prior, repeat=True)
        d = act.describe(it, fmt_time=_iso)
        row = {"key": it["key"], "nonce": nonce, "at": now, "sub": sub, "who": who, "kind": it["kind"],
               "target": it["target"], "summary": d["summary"], "result": "running", "detail": "", "ref": [],
               "until": None}
        try:
            self.activity.add(row)
        except Exception as e:  # noqa: BLE001 - fail closed: an action that cannot be recorded is not run
            raise act.Refused(f"the action could not be recorded first ({type(e).__name__}), so it was not run") from e
        self.seen[it["key"]] = (nonce, row, now)
        try:
            res = getattr(self, "do_" + it["kind"].replace("-", "_"))(it, who)
        except Exception as e:
            reason = e.reason if isinstance(e, act.Refused) else type(e).__name__
            self._finish(dict(row, result="failed", detail=reason[:300]))
            raise
        row = dict(row, result="done", detail=res.get("detail", ""), ref=res.get("ref") or [], until=res.get("until"))
        self.audit(it, sub, who, "done", row["ref"], row["detail"])
        self._finish(row)
        if res.get("secret"):                    # to the person who asked, once: never the record, the log or a replay
            return 200, dict(row, secret=res["secret"])
        return 200, row

    def _finish(self, row):
        self.seen[row["key"]] = (row["nonce"], row, row["at"])
        try:
            self.activity.add(row)
        except Exception as e:  # noqa: BLE001 - it ran (or failed): the reserved row stays, and the log line is the record
            log.warning("activity row not updated: %s: %s", type(e).__name__, e)
            row["detail"] += " (Activity may still say running: " + type(e).__name__ + ")"

    def audit(self, it, sub, who, result, ref, detail):
        line = {"event": "tockmox.action", "sub": sub, "who": who, "action": it.get("kind", ""),
                "target": it.get("target", {}), "key": it.get("key", ""), "result": result, "ref": ref,
                "detail": str(detail)[:300]}
        print(json.dumps(line, separators=(",", ":"), sort_keys=True), flush=True)


def create_service(doc: dict, transports: dict | None = None, now=time.time) -> FastAPI:
    svc = Service(doc, transports, now)
    app = FastAPI(title="tockmox-actions", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.service = svc

    @app.get("/healthz", response_class=PlainTextResponse)
    def healthz():
        return "ok"

    @app.post("/v1/intents")
    async def intents(request: Request):
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001
            return JSONResponse({"result": "refused", "reason": "not JSON"}, status_code=400)
        code, out = svc.handle(body)
        return JSONResponse(out, status_code=code)

    @app.get("/v1/activity")
    def activity(limit: int = 50):
        try:
            rows, _ = svc.activity.read()
        except Exception as e:  # noqa: BLE001
            return JSONResponse({"error": f"the activity record could not be read ({type(e).__name__})"}, status_code=503)
        return {"rows": rows[:max(1, min(limit, ACTIVITY_MAX))]}

    @app.get("/v1/identity/users")
    def identity_users():
        if not svc.cfg.on("recovery-link"):
            return JSONResponse({"error": "the identity actions are not turned on here"}, status_code=404)
        try:
            people, why = svc.authentik.users()
        except Exception:  # noqa: BLE001 - a transport failure; its text stays in this pod (CodeQL py/stack-trace-exposure)
            log.warning("identity users: Authentik did not answer", exc_info=True)
            people, why = [], "Authentik did not answer"
        if why:
            return JSONResponse({"error": why}, status_code=503)
        return {"users": people, "userGroup": svc.cfg.user_group, "adminGroup": svc.admin_group}

    return app


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    path = os.environ.get(CONFIG_ENV, "/etc/tockmox-actions/config.yaml")
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    import uvicorn
    # Not TOCKMOX_ACTIONS_PORT: Kubernetes sets that, for the Service named tockmox-actions, to tcp://<ip>:8081 in
    # every pod of the namespace (a k3s lab cluster, 2026-11-01: the first start crashed on int("tcp://...")). The
    # chart also turns service links off for this pod.
    uvicorn.run(create_service(doc), host="0.0.0.0", port=int(os.environ.get(LISTEN_PORT_ENV, "8081")),
                log_level="warning", access_log=False)


if __name__ == "__main__":
    main()

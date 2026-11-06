# SPDX-License-Identifier: Apache-2.0
"""The console's side of actions: the buttons, the confirm panel, the sign-in that binds a
confirmation to one intent, and Platform > Activity. Nothing here writes: the intent goes to tockmox-actions
(app/actions_service.py) with the ID token the issuer minted for it, and that service decides and acts.

  GET  /actions/confirm        the confirm panel: target, effect, undo (and the silence's length and reason)
  POST /actions/go             CSRF, then off to the issuer with nonce = actions.nonce_for(intent)
  (GET /auth/callback)         finish(): the ID token and the intent go to the service; the result is a page
  GET  /platform/activity      what was done, by whom, and how it ended
  GET  /platform/identity      the people Authentik knows, with a recovery link and user-group membership
  GET  /platform/changes       the changes waiting on the site forge: summary, checks, the diff behind a fold, and
                               Approve and apply, Decline and (for an applied change) Revert
  GET  /platform/changes/<n>/diff   one change's diff, as text (the fold loads it)
  POST /actions/site-copy      Download a copy: the service makes main's bundle; the page names its SHA-256, and
                               /platform/history/copy/<sha256>/site.bundle(.sha256) hand the two files over
  GET  /platform/history       Site history: where the history lives, the off-site copy (matches, pending, behind, none),
                               the last rebuild drill, recently applied changes with Revert, and Copy now
  (app.state.open_change)      a page that renders a change (models, inference nodes) stages it with the service and
                               sends the browser to the confirm panel, which shows the exact diff against main
  GET  /actions/forge/callback for approve and decline only: the forge's own sign-in comes back here BEFORE the
                               identity provider's step-up, so the service can act as that person in the forge
"""
from __future__ import annotations

import base64
import hashlib
import json
import secrets
import time
from urllib.parse import quote, urlencode, urlsplit

import httpx
from fastapi import Form, Request
from fastapi.responses import RedirectResponse

from . import actions as act

ACT_COOKIE = "__Host-tockmox_ui_act"
DEV_ACT_COOKIE = "tockmox_ui_act"
FORGE_COOKIE = "__Host-tockmox_ui_forge"
DEV_FORGE_COOKIE = "tockmox_ui_forge"
COOKIE_MAX = 3800
SILENCE_CHOICES = ((1, "1 hour"), (4, "4 hours"), (24, "24 hours"), (168, "7 days"))
RECOVERY_CHOICES = ((1, "1 hour"), (24, "24 hours"), (72, "3 days"))


def _back(v: str, default: str = "/status") -> str:
    """A path on this console, or the default. No scheme, no host, no control character or whitespace (a browser
    drops a tab or newline from a URL, so "/\t/evil.example" would read as "//evil.example")."""
    from urllib.parse import urlsplit
    v = str(v or "")
    if not v.startswith("/") or len(v) >= 300 or "\\" in v or any(ord(c) < 33 or ord(c) == 127 for c in v):
        return default
    u = urlsplit(v)
    return v if not (u.scheme or u.netloc) and not v.startswith("//") else default


def part_actions(cfg: act.Config, pv, cron_known=None) -> list[dict]:
    """The drawer's Actions for one part, as links to their confirm panels. Only kinds that are on, only targets the
    allowlists name. cron_known: the CronJobs Prometheus knows, as {(ns, name)}, or None when it could not say."""
    if cfg is None or not cfg.any:
        return []
    out = []
    pid = quote(pv.part.id, safe="")
    nss = set(pv.part.namespaces)

    def mine(ns, part):                  # an entry naming its part goes there; one without goes by namespace
        return part == pv.part.id if part else ns in nss
    if cfg.on("run-job"):
        for ns, name, part in cfg.jobs:
            if mine(ns, part) and (cron_known is None or (ns, name) in cron_known):
                out.append({"kind": "run-job", "label": f"Run {name} now",
                            "href": f"/actions/confirm?kind=run-job&part={pid}&ns={quote(ns)}&name={quote(name)}"})
    apps = [x["what"].removesuffix(" application") for x in pv.signals if x["source"] == "apps"]
    if cfg.on("sync"):
        for a in [a for a in apps if act.DNS_NAME.fullmatch(a)][:3]:
            out.append({"kind": "sync", "label": f"Sync {a}", "href": f"/actions/confirm?kind=sync&part={pid}&app={quote(a)}"})
            out.append({"kind": "refresh", "label": f"Refresh {a}", "href": f"/actions/confirm?kind=refresh&part={pid}&app={quote(a)}"})
    live = [x for x in pv.signals if x["source"] == "alertmanager" and x.get("alert") and not x.get("silenced")]
    if cfg.on("silence") and live:
        n = len({(x["alert"], x.get("namespace", "")) for x in live})
        out.append({"kind": "silence", "label": f"Silence {n} alert{'s' if n != 1 else ''}…",
                    "href": f"/actions/confirm?kind=silence&part={pid}"})
    if cfg.on("restart"):
        for ns, kind, name, part in cfg.workloads:
            if mine(ns, part):
                out.append({"kind": "restart", "label": f"Restart {name}…",
                            "href": f"/actions/confirm?kind=restart&part={pid}&ns={quote(ns)}&wkind={quote(kind)}&name={quote(name)}"})
    return out


def silences_on(pv) -> list[dict]:
    """The console's silences on a part's alerts: one row each, with the alerts it covers."""
    by: dict = {}
    for x in pv.signals:
        s = x.get("silenced")
        if x["source"] == "alertmanager" and s:
            row = by.setdefault(s["id"], dict(s, alerts=[]))
            row["alerts"].append(x["alert"])
    return sorted(by.values(), key=lambda r: r.get("until") or 0)


def register(app, s, render, user_of, need_login, forbidden, csrf_ok, sessions, oidc, placed_now, transport=None,
             active_silences=lambda: {}, forge_jobs=None, alerts_now=None, site_revision=None, upgrade_plan=None):
    cfg: act.Config = s.actions or act.Config()

    def site_time(ts):
        """A time in the confirm and result words, in the site's zone with its abbreviation (site.timezone)."""
        from datetime import datetime
        from zoneinfo import ZoneInfo
        return datetime.fromtimestamp(ts, ZoneInfo(s.timezone)).strftime("%H:%M %Z")
    cookie = ACT_COOKIE if s.secure_cookies else DEV_ACT_COOKIE
    fcookie = FORGE_COOKIE if s.secure_cookies else DEV_FORGE_COOKIE
    _o = urlsplit(s.oidc_redirect_url or "")
    forge_redirect = f"{_o.scheme}://{_o.netloc}/actions/forge/callback" if _o.scheme and _o.netloc else ""

    def service_get(path, params=None):
        """(status, json) from tockmox-actions, or (0, {"error": ...}) when it did not answer."""
        try:
            with httpx.Client(base_url=cfg.url, timeout=max(s.source_timeout_s, 10), transport=transport) as c:
                r = c.get(path, params=params)
            return r.status_code, r.json()
        except Exception as e:  # noqa: BLE001
            return 0, {"error": f"the actions service did not answer ({type(e).__name__})"}

    def service_post(path, body):
        """(status, json) from tockmox-actions, or (0, {"error": ...}) when it did not answer."""
        try:
            with httpx.Client(base_url=cfg.url, timeout=max(s.source_timeout_s, 10), transport=transport) as c:
                r = c.post(path, content=json.dumps(body, default=str), headers={"Content-Type": "application/json"})
            return r.status_code, r.json()
        except Exception as e:  # noqa: BLE001
            return 0, {"error": f"the actions service did not answer ({type(e).__name__})"}

    def forge_sign_in() -> dict:
        """The forge's authorize URL and the console's client id, from the service (which reads what bootstrap-forge
        registered); {} when there is none or the service did not answer."""
        code, j = service_get("/v1/changes")
        si = j.get("sign_in") if code == 200 else None
        return si if isinstance(si, dict) and si.get("authorize_url", "").startswith(("https://", "http://")) \
            and si.get("client_id") else {}

    def change_row(number: int, applied: bool = False) -> dict:
        code, j = service_get("/v1/changes")
        if code != 200:
            raise act.Refused("the site forge is not answering, so changes are paused" if j.get("paused")
                              else str(j.get("error") or "the changes could not be read"))
        row = next((x for x in j.get("applied" if applied else "open") or [] if x.get("number") == number), None)
        if row is None:
            raise act.Refused(f"#{number} is not {'among the applied changes' if applied else 'waiting'} any more")
        return row

    def admin(request):
        u = user_of(request)
        if not u:
            return None, need_login(request)
        if not u.is_admin:
            return None, forbidden(request, u)
        return u, None

    def nope(request, u, msg, code=404):
        return render(request, "error.html", u, status_code=code, title="Not available", message=msg)

    def target_for(request, u, kind: str, q) -> tuple[dict, str, str]:
        """The intent's target, built here from what the page shows now, plus where Cancel goes."""
        part = str(q.get("part", ""))
        back = f"/status/{quote(part, safe='')}" if act.PART_ID.fullmatch(part) else _back(q.get("back", ""))
        if kind == "test-alert":
            return {}, _back(q.get("back", ""), "/status"), ""
        if kind in act.CHANGE_KINDS:
            n = str(q.get("number", ""))
            n = int(n) if n.isdigit() and len(n) < 9 else 0
            if kind == "revert-change":
                row = change_row(n, applied=True)
                return {"number": n, "title": row.get("title", ""), "merge": str(row.get("merge", ""))}, "/platform/changes", ""
            row = change_row(n)
            head = str(q.get("head", ""))
            if head != row.get("head"):
                raise act.Refused(f"#{n} changed since the page was drawn; look at it again")
            return {"number": n, "title": row.get("title", ""), "head": head}, "/platform/changes", ""
        if kind == "open-change":
            return {"what": str(q.get("what", "")), "draft": str(q.get("draft", "")), "title": str(q.get("title", "")),
                    "applied": str(q.get("applied", ""))}, _back(q.get("back", ""), "/platform/changes"), ""
        if kind == "add-admin":
            return {"username": str(q.get("username", ""))}, "/platform/identity", ""
        if kind == "bump-release":
            return bump_target(str(q.get("to", "")))
        if kind == "set-feature":
            en = str(q.get("enabled", ""))
            return {"feature": str(q.get("feature", "")), "enabled": en == "true" if en in ("true", "false") else en}, \
                "/capabilities", ""
        if kind == "assign-job":
            job, role = str(q.get("job", "")), str(q.get("role", ""))
            pl = getattr(request.app.state, "platform", None) or {}
            if "unowned" not in pl:
                raise act.Refused("Platform Management is not on here, so there is no unowned work to give")
            if not pl["catalog"].get(role):
                raise act.Refused(f"there is no role {role!r} in this platform's catalog")
            if job not in pl["unowned"]():
                raise act.Refused(f"{job} is not listed as scheduled work with no owner now; see Platform > Overview")
            return {"job": job, "role": role}, "/platform", ""
        if kind == "set-capability":
            en = str(q.get("enabled", ""))
            return {"capability": str(q.get("capability", "")), "enabled": en == "true" if en in ("true", "false") else en}, \
                "/capabilities", ""
        if kind in act.IDENTITY_KINDS:
            uid = str(q.get("user", ""))
            return {"user": int(uid) if uid.isdigit() else 0, "username": str(q.get("username", ""))}, "/platform/identity", ""
        if kind in ("run-job",):
            return {"namespace": str(q.get("ns", "")), "name": str(q.get("name", ""))}, back, ""
        if kind in ("refresh", "sync"):
            return {"app": str(q.get("app", ""))}, back, ""
        if kind == "restart":
            return {"namespace": str(q.get("ns", "")), "kind": str(q.get("wkind", "")), "name": str(q.get("name", ""))}, back, ""
        if kind == "expire" and not part:                       # from Activity: the service checks it is the console's
            sid = str(q.get("silence", ""))
            return {"silence": sid, "label": f"silence {sid[:8]}"}, "/platform/activity", ""
        pv = placed_now().by_id.get(part)
        if pv is None:
            raise act.Refused("there is no such part on Status")
        if kind == "silence":
            alerts = sorted({(x["alert"], x.get("namespace", "")) for x in pv.signals
                             if x["source"] == "alertmanager" and x.get("alert") and not x.get("silenced")})
            if not alerts:
                raise act.Refused(f"nothing on {pv.part.name} is firing unsilenced now")
            return {"part": pv.part.id, "label": pv.part.name,
                    "alerts": [{"alertname": a, "namespace": n} for a, n in alerts]}, back, ""
        if kind == "expire":
            sid = str(q.get("silence", ""))
            row = next((r for r in silences_on(pv) if r["id"] == sid), None)
            if row is None:
                raise act.Refused("that silence is not on this part now")
            return {"silence": sid, "label": f"{', '.join(sorted(set(row['alerts'])))} (silenced by {row['by']})"}, back, ""
        raise act.Refused(f"no such action {kind!r}")

    def bump_target(to: str):
        """The upgrade change's target, from the Upgrade page's own preflight drawn now. Offered only when the release
        feed is verified, the preflight is green, and no release on the way lists a breaking change (those edits go
        in the same commit by hand, which a console cannot write). What only a person can check is carried as such."""
        if upgrade_plan is None:
            raise act.Refused("this console has no upgrade preflight to carry")
        pl = upgrade_plan(to)
        cur, tgt = pl.get("cur_rev"), pl.get("tgt_rev")
        if not pl.get("verified"):
            raise act.Refused("the release feed is not verified here, so the console does not open an upgrade")
        if not (cur and tgt and act.RELEASE_TAG.fullmatch(cur) and act.RELEASE_TAG.fullmatch(tgt)):
            raise act.Refused("the running release or the one to move to is not known")
        if pl.get("breaking"):
            raise act.Refused("a release on the way lists breaking changes, whose edits go in the same commit as the "
                              "bump; follow the steps on the Upgrade page by hand")
        if not pl.get("ready") or pl.get("kind") not in act.BUMP_KINDS:
            raise act.Refused("the preflight is not green; see the Upgrade page")
        pf = [{"label": str(c["label"])[:200], "state": str(c["state"]) if c["state"] in act.PREFLIGHT_STATES else "unknown",
               "manual": bool(c.get("manual"))} for c in pl["checks"]]
        hand = [f"The release notes read for every release on the way (the guide's step 1)",
                f"The built-in forge is upgraded to {tgt}'s pinned Forgejo first: tockmox-install.sh upgrade-forge from "
                f"a clone at {tgt} (the guide's step 2)",
                {"patch": "A backup taken if the release notes move a bundled application that migrates its own "
                          "database (the guide's step 2)",
                 "minor": "A backup taken and your customisations checked (the guide's steps 2 and 3)",
                 "major": "A backup taken, your customisations checked, the render diffed and the migration notes "
                          "followed (the guide's steps 2 to 4)"}[pl["kind"]]]
        pf += [{"label": h, "state": "unknown", "manual": True} for h in hand]
        return {"from": cur, "to": tgt, "kind": pl["kind"], "preflight": pf[:12]}, f"/upgrade?to={quote(tgt, safe='')}", ""

    @app.get("/actions/confirm")
    def confirm(request: Request, kind: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        if not cfg.on(kind):
            return nope(request, u, "That action is not turned on here.")
        try:
            target, back, _ = target_for(request, u, kind, request.query_params)
            draft = {"hours": 4, "reason": "-"} if kind == "silence" else {"hours": 24} if kind == "recovery-link" else {}
            if kind in act.FORGE_PERSON_KINDS and not (forge_sign_in() and forge_redirect):
                raise act.Refused("the console has no sign-in to the site forge configured (actions.changes.oauth)")
            it = act.check(cfg, act.intent(kind, target, draft, u.sub))
            preview = None
            if kind in act.OPEN_KINDS:
                # the exact edit, against main now: a refusal (main already says it, the file moved since it was
                # applied, a layout the console cannot edit) is said here, before anyone signs in
                code, preview = service_post("/v1/changes/preview", {"kind": kind, "target": target})
                if code != 200:
                    raise act.Refused(str(preview.get("error") or "the change could not be previewed"))
        except act.Refused as e:
            return nope(request, u, f"This action cannot be offered: {e.reason}.", 409)
        d = act.describe(it, fmt_time=site_time, choosing=True)
        return render(request, "action_confirm.html", u, kind=kind, d=d, target_json=json.dumps(target, sort_keys=True),
                      preview=preview,
                      key=it["key"], back=back, step_up=act.step_up(kind), max_age_min=cfg.step_up_max_age // 60,
                      choices=SILENCE_CHOICES, recovery_choices=RECOVERY_CHOICES, target=target)

    @app.post("/actions/go")
    def go(request: Request, csrf: str = Form(""), kind: str = Form(""), target: str = Form(""), key: str = Form(""),
           back: str = Form(""), hours: str = Form(""), reason: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return nope(request, u, "The form expired. Open the action again.", 400)
        if not cfg.on(kind):
            return nope(request, u, "That action is not turned on here.")
        try:
            if len(target) > 3000:
                raise act.Refused("the target is too large")
            t = json.loads(target or "{}")
            if not isinstance(t, dict):
                raise act.Refused("the target is not an object")
            params = {}
            if kind == "silence":
                h = int(hours) if hours.isdigit() else 0
                if h not in {c[0] for c in SILENCE_CHOICES}:
                    raise act.Refused("choose how long the silence lasts")
                params = {"hours": h, "reason": reason.strip()[:300]}
            elif kind == "recovery-link":
                h = int(hours) if hours.isdigit() else 0
                if h not in {c[0] for c in RECOVERY_CHOICES}:
                    raise act.Refused("choose how long the link lasts")
                params = {"hours": h}
            elif kind == "decline-change":
                params = {"reason": reason.strip()[:300]}
            it = act.check(cfg, act.intent(kind, t, params, u.sub, key=key))
        except (ValueError, TypeError, act.Refused) as e:
            return nope(request, u, f"Not sent: {e}.", 400)
        if kind in act.FORGE_PERSON_KINDS:
            return to_forge(request, u, it, _back(back))
        return to_idp(request, u, it, _back(back))

    def to_forge(request, u, it, back):
        """The forge's own sign-in first (Authentik behind it), with PKCE; the code comes back to forge_callback,
        which then asks the identity provider for the step-up that binds the intent."""
        si = forge_sign_in()
        if not (si and forge_redirect):
            return nope(request, u, "Not sent: the console has no sign-in to the site forge configured.", 409)
        verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
        state = secrets.token_urlsafe(24)
        q = {"response_type": "code", "client_id": si["client_id"], "redirect_uri": forge_redirect,
             "state": state, "code_challenge_method": "S256",
             "code_challenge": base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()}
        val = sessions.l.dumps({"state": state, "verifier": verifier, "intent": it, "back": back})
        if len(val) > COOKIE_MAX:
            return nope(request, u, "Not sent: this action names too much to carry through sign-in.", 400)
        resp = RedirectResponse(si["authorize_url"] + "?" + urlencode(q), status_code=303)
        resp.set_cookie(fcookie, val, max_age=600, **sessions.cookie_args())
        return resp

    @app.get("/actions/forge/callback")
    def forge_callback(request: Request, code: str = "", state: str = "", error: str = ""):
        import hmac
        u, deny = admin(request)
        if deny:
            return deny
        raw = request.cookies.get(fcookie)
        try:
            st = sessions.l.loads(raw, max_age=600) if raw else None
        except Exception:  # noqa: BLE001
            st = None
        if not st or not hmac.compare_digest(str(st.get("state", "")).encode(), str(state).encode()):
            return nope(request, u, "This sign-in to the forge was not started here, or took too long. Nothing was done.", 400)
        if error or not code or len(code) > 512:
            r = render(request, "action_result.html", u, status_code=400, ok=False, d=None, back=st.get("back") or "/platform/changes",
                       reason="the sign-in to the site forge was cancelled or refused")
            r.delete_cookie(fcookie, path="/", secure=s.secure_cookies, httponly=True)
            return r
        it = st.get("intent") or {}
        if it.get("sub") != u.sub:
            return nope(request, u, "This action was started by someone else. Nothing was done.", 403)
        resp = to_idp(request, u, it, st.get("back") or "/platform/changes",
                      forge={"code": code, "verifier": st.get("verifier", ""), "redirect_uri": forge_redirect})
        resp.delete_cookie(fcookie, path="/", secure=s.secure_cookies, httponly=True)
        return resp

    def to_idp(request, u, it, back, forge=None):
        kind = it["kind"]
        try:
            url, st = oidc.begin(nonce=act.nonce_for(it), max_age=cfg.step_up_max_age if act.step_up(kind) else None)
        except Exception:  # noqa: BLE001
            return render(request, "error.html", u, status_code=503, title="Sign-in is unavailable",
                          message="The identity provider did not answer, so this action cannot be confirmed. Nothing was done.")
        st.update(intent=it, back=back)
        if forge:
            st["forge"] = forge
        val = sessions.l.dumps(st)
        if len(val) > COOKIE_MAX:
            return nope(request, u, "Not sent: this action names too much to carry through sign-in. Silence fewer alerts at a time.", 400)
        resp = RedirectResponse(url, status_code=303)
        resp.set_cookie(cookie, val, max_age=600, **sessions.cookie_args())
        return resp

    def finish(request: Request, code: str, state: str, error: str):
        """Called from /auth/callback first: None when this callback is not an action's, so sign-in proceeds."""
        import hmac
        raw = request.cookies.get(cookie)
        if not raw:
            return None
        try:
            st = sessions.l.loads(raw, max_age=600)
        except Exception:  # noqa: BLE001
            return None
        if not hmac.compare_digest(str(st.get("state", "")).encode(), str(state).encode()):
            return None
        u = user_of(request)

        def done(page, code_=200, **kw):
            r = render(request, page, u, status_code=code_, back=st.get("back") or "/status", **kw)
            r.delete_cookie(cookie, path="/", secure=s.secure_cookies, httponly=True)
            return r
        if u is None or not u.is_admin:
            return done("error.html", 403, title="Not available", message="Sign in as an administrator to act. Nothing was done.")
        if error or not code:
            return done("action_result.html", 400, ok=False, reason="the sign-in was cancelled or refused", d=None)
        it = st.get("intent") or {}
        try:
            claims = oidc.finish(code, st)
        except Exception:  # noqa: BLE001
            return done("action_result.html", 502, ok=False, reason="the identity provider's answer could not be verified", d=None)
        if claims.get("sub") != u.sub:
            return done("action_result.html", 403, ok=False, reason="you signed in as someone else than this session", d=None)
        d = act.describe(it, fmt_time=site_time)
        try:
            with httpx.Client(base_url=cfg.url, timeout=max(s.source_timeout_s, 10), transport=transport) as c:
                body = {"intent": it, "id_token": claims.get("_id_token", "")}
                if st.get("forge"):
                    body["forge"] = st["forge"]
                r = c.post("/v1/intents", json=body)
            out = r.json()
        except Exception as e:  # noqa: BLE001
            return done("action_result.html", 502, ok=False, d=d,
                        reason=f"the actions service did not answer ({type(e).__name__}); nothing is known to have been done")
        ok = out.get("result") == "done"
        # a recovery link is shown on this page once; every page here is sent no-store (main.py)
        return done("action_result.html", 200 if ok else (r.status_code or 502), ok=ok, d=d, out=out,
                    reason=out.get("reason", ""), secret=out.get("secret", ""))

    app.state.action_finish = finish

    def open_change(request, u, what: str, title: str, summary: str, edits: list):
        """A page that renders a change hands it here instead of as a download: it is staged with the service and the
        browser goes to the confirm panel. The page was drawn from what Argo CD applied, so the commit it applied for
        the AI layer travels with it, and the service refuses if the file moved on main since."""
        if not cfg.on("open-change"):
            return nope(request, u, "Opening changes from the console is not turned on here; download the change instead.")
        applied = (site_revision() if site_revision else "") or ""
        if not act.SHA.fullmatch(applied):
            return nope(request, u, "Not opened: the commit Argo CD last applied for the AI layer could not be read, so "
                                    "this change could undo one merged since. Download it instead, or try again in a minute.", 409)
        code, j = service_post("/v1/changes/drafts", {"what": what, "title": title[:200], "summary": summary[:2000],
                                                       "edits": [{"path": list(p), "value": v} for p, v in edits]})
        if code != 200 or not act.DIGEST.fullmatch(str(j.get("draft", ""))):
            return nope(request, u, f"Not opened: {j.get('error') or 'the actions service did not take the change'}.", 409)
        q = urlencode({"kind": "open-change", "what": what, "draft": j["draft"], "title": title[:200].strip(),
                       "applied": applied, "back": "/models" if what == "models" else "/nodes"})
        return RedirectResponse("/actions/confirm?" + q, status_code=303)

    app.state.open_change = open_change

    @app.get("/platform/activity")
    def activity(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        if not cfg.any:
            return nope(request, u, "No actions are turned on here, so there is no activity to show.")
        rows, err = [], ""
        try:
            with httpx.Client(base_url=cfg.url, timeout=s.source_timeout_s, transport=transport) as c:
                r = c.get("/v1/activity", params={"limit": 100})
                r.raise_for_status()
                rows = r.json().get("rows") or []
        except Exception as e:  # noqa: BLE001
            err = f"the actions service did not answer ({type(e).__name__})"
        active = set()
        if cfg.on("expire") and any(r.get("kind") == "silence" for r in rows):
            try:
                active = set(active_silences())        # a failed read offers no Expire here; Status still does
            except Exception:  # noqa: BLE001
                active = set()
        return render(request, "platform_activity.html", u, rows=rows, err=err, now=time.time(),
                      expire_on=cfg.on("expire"), active=active)

    @app.get("/platform/identity")
    def identity(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        people_on, admin_on = cfg.on("recovery-link"), cfg.on("add-admin")
        if not (people_on or admin_on):
            return nope(request, u, "The identity actions are not turned on here (tockmoxUi.actions.identity).")
        people, err, groups = [], "", {}
        if not people_on:
            return render(request, "platform_identity.html", u, people=[], err="", groups={}, admin_url="",
                          people_on=False, admin_on=admin_on)
        try:
            with httpx.Client(base_url=cfg.url, timeout=max(s.source_timeout_s, 10), transport=transport) as c:
                r = c.get("/v1/identity/users")
                j = r.json()
            if r.status_code >= 300:
                err = str(j.get("error") or f"the actions service answered {r.status_code}")
            people, groups = j.get("users") or [], {"user": j.get("userGroup", ""), "admin": j.get("adminGroup", "")}
        except Exception as e:  # noqa: BLE001
            err = f"the actions service did not answer ({type(e).__name__})"
        admin_url = (s.oidc_issuer.split("/application/")[0] + "/if/admin/#/identity/users") if s.oidc_issuer else ""
        return render(request, "platform_identity.html", u, people=people, err=err, groups=groups, admin_url=admin_url,
                      people_on=True, admin_on=admin_on)

    @app.get("/platform/changes")
    def changes(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        if not cfg.on("approve-change"):
            return nope(request, u, "The change actions are not turned on here (tockmoxUi.actions.changes).")
        code, j = service_get("/v1/changes")
        paused = bool(j.get("paused"))
        err = "" if code == 200 else ("" if paused else str(j.get("error") or f"the actions service answered {code}"))
        opened = j.get("open") or []
        for row in opened[:10]:                 # the diff behind each fold, read now (a waiting change is rarely large)
            dc, dj = service_get(f"/v1/changes/{int(row.get('number', 0))}/diff")
            row["diff"], row["diff_cut"] = (str(dj.get("diff", "")), bool(dj.get("cut"))) if dc == 200 else ("", False)
            row["diff_err"] = "" if dc == 200 else str(dj.get("error") or "the diff could not be read")
        return render(request, "platform_changes.html", u, paused=paused, err=err, opened=opened,
                      applied=j.get("applied") or [], repo=j.get("repo", ""), base=j.get("base", ""),
                      person_ok=bool(isinstance(j.get("sign_in"), dict) and j["sign_in"].get("client_id") and forge_redirect))

    @app.get("/platform/history")
    def history(request: Request):
        from . import site_history
        u, deny = admin(request)
        if deny:
            return deny
        if not cfg.on("approve-change"):
            return nope(request, u, "Site history needs the built-in forge's change actions (tockmoxUi.actions.changes).")
        code, st = service_get("/v1/forge/state")
        err = "" if code == 200 else str(st.get("error") or f"the actions service answered {code}")
        jobs, jobs_known = [], False
        if forge_jobs is not None:
            rd = forge_jobs()
            jobs, jobs_known = rd.data or [], rd.fetched_at is not None   # last good data is not this answer
        alerts, alerts_known = [], False
        if alerts_now is not None:
            ra = alerts_now()
            alerts, alerts_known = (ra.data or [], True) if ra.fetched_at is not None else ([], False)
        v = site_history.view(st if code == 200 else None, jobs, alerts, time.time(), jobs_known, alerts_known)
        ccode, ch = service_get("/v1/changes")
        applied = (ch.get("applied") or []) if ccode == 200 else []
        ns = (st or {}).get("jobs_namespace", "")
        runnable = {(a, b) for a, b, _ in cfg.jobs} if cfg.on("run-job") else set()
        copy_now = (st.get("copy") or {}).get("name") if code == 200 and st.get("copy") else ""
        drill_now = (st.get("drill") or {}).get("name") if code == 200 and st.get("drill") else ""
        return render(request, "platform_history.html", u, v=v, st=st if code == 200 else {}, err=err,
                      applied=applied, ns=ns,
                      copy_now=copy_now if (ns, copy_now) in runnable else "",
                      drill_now=drill_now if (ns, drill_now) in runnable else "")

    @app.post("/actions/site-copy")
    def history_copy(request: Request, csrf: str = Form("")):
        """Download a copy: the service makes main's bundle now; this page names its SHA-256 and links the two files
        `--restore-from file:` wants side by side (site.bundle and site.bundle.sha256)."""
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return nope(request, u, "The form expired. Open Site history again.", 400)
        if not cfg.on("approve-change"):
            return nope(request, u, "Site history is not turned on here.")
        try:
            with httpx.Client(base_url=cfg.url, timeout=max(s.source_timeout_s, 120), transport=transport) as c:
                r = c.post("/v1/forge/bundle")
            j = r.json()
        except Exception as e:  # noqa: BLE001
            return nope(request, u, f"The actions service did not answer ({type(e).__name__}). No copy was made.", 502)
        if r.status_code != 200 or not str(j.get("sha256", "")).isalnum():
            return nope(request, u, f"No copy was made: {j.get('error') or r.status_code}.", 502)
        return render(request, "platform_history_copy.html", u, c=j)

    @app.get("/platform/history/copy/{digest}/site.bundle")
    def history_copy_file(request: Request, digest: str):
        from fastapi.responses import StreamingResponse
        import re as _re
        u, deny = admin(request)
        if deny:
            return deny
        if not cfg.on("approve-change") or not _re.fullmatch(r"[0-9a-f]{64}", digest):
            return nope(request, u, "No such copy.")
        c = httpx.Client(base_url=cfg.url, timeout=max(s.source_timeout_s, 120), transport=transport)
        r = c.send(c.build_request("GET", f"/v1/forge/bundle/{digest}"), stream=True)
        if r.status_code != 200:
            r.close(); c.close()
            return nope(request, u, "That copy is gone (only the newest is kept). Make another from Site history.")

        def body():
            try:
                yield from r.iter_bytes()
            finally:
                r.close(); c.close()
        return StreamingResponse(body(), media_type="application/octet-stream",
                                 headers={"Content-Disposition": 'attachment; filename="site.bundle"'})

    @app.get("/platform/history/copy/{digest}/site.bundle.sha256")
    def history_copy_sum(request: Request, digest: str):
        from fastapi.responses import PlainTextResponse
        import re as _re
        u, deny = admin(request)
        if deny:
            return deny
        if not _re.fullmatch(r"[0-9a-f]{64}", digest):
            return nope(request, u, "No such copy.")
        return PlainTextResponse(f"{digest}  site.bundle\n",
                                 headers={"Content-Disposition": 'attachment; filename="site.bundle.sha256"'})

    @app.get("/platform/changes/{number}/diff")
    def change_diff(request: Request, number: int):
        from fastapi.responses import PlainTextResponse
        u, deny = admin(request)
        if deny:
            return deny
        if not cfg.on("approve-change") or not 1 <= number <= 10_000_000:
            return nope(request, u, "No such change.")
        code, j = service_get(f"/v1/changes/{number}/diff")
        if code != 200:
            return PlainTextResponse("The diff could not be read: " + str(j.get("error") or code) + ".", status_code=502)
        text = str(j.get("diff", "")) + ("\n[cut here: open the change in the forge for the rest]\n" if j.get("cut") else "")
        return PlainTextResponse(text, headers={"Content-Disposition": "inline", "X-Content-Type-Options": "nosniff"})

    return finish

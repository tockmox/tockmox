# SPDX-License-Identifier: Apache-2.0
"""The console's side of actions (TM-1311, TM-1313): the buttons, the confirm panel, the sign-in that binds a
confirmation to one intent, and Platform > Activity. Nothing here writes: the intent goes to tockmox-actions
(app/actions_service.py) with the ID token the issuer minted for it, and that service decides and acts.

  GET  /actions/confirm        the confirm panel: target, effect, undo (and the silence's length and reason)
  POST /actions/go             CSRF, then off to the issuer with nonce = actions.nonce_for(intent)
  (GET /auth/callback)         finish(): the ID token and the intent go to the service; the result is a page
  GET  /platform/activity      what was done, by whom, and how it ended
"""
from __future__ import annotations

import json
import time
from urllib.parse import quote

import httpx
from fastapi import Form, Request
from fastapi.responses import RedirectResponse

from . import actions as act

ACT_COOKIE = "__Host-tockmox_ui_act"
DEV_ACT_COOKIE = "tockmox_ui_act"
COOKIE_MAX = 3800
SILENCE_CHOICES = ((1, "1 hour"), (4, "4 hours"), (24, "24 hours"), (168, "7 days"))


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


def register(app, s, render, user_of, need_login, forbidden, csrf_ok, sessions, oidc, placed_now, transport=None):
    cfg: act.Config = s.actions or act.Config()
    cookie = ACT_COOKIE if s.secure_cookies else DEV_ACT_COOKIE

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

    @app.get("/actions/confirm")
    def confirm(request: Request, kind: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        if not cfg.on(kind):
            return nope(request, u, "That action is not turned on here.")
        try:
            target, back, _ = target_for(request, u, kind, request.query_params)
            it = act.check(cfg, act.intent(kind, target, {"hours": 4, "reason": "-"} if kind == "silence" else {}, u.sub))
        except act.Refused as e:
            return nope(request, u, f"This action cannot be offered: {e}.", 409)
        d = act.describe(it, fmt_time=lambda ts: time.strftime("%H:%M", time.localtime(ts)))
        return render(request, "action_confirm.html", u, kind=kind, d=d, target_json=json.dumps(target, sort_keys=True),
                      key=it["key"], back=back, step_up=act.step_up(kind), max_age_min=cfg.step_up_max_age // 60,
                      choices=SILENCE_CHOICES, target=target)

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
            it = act.check(cfg, act.intent(kind, t, params, u.sub, key=key))
        except (ValueError, TypeError, act.Refused) as e:
            return nope(request, u, f"Not sent: {e}.", 400)
        try:
            url, st = oidc.begin(nonce=act.nonce_for(it), max_age=cfg.step_up_max_age if act.step_up(kind) else None)
        except Exception:  # noqa: BLE001
            return render(request, "error.html", u, status_code=503, title="Sign-in is unavailable",
                          message="The identity provider did not answer, so this action cannot be confirmed. Nothing was done.")
        st.update(intent=it, back=_back(back))
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
        d = act.describe(it, fmt_time=lambda ts: time.strftime("%H:%M", time.localtime(ts)))
        try:
            with httpx.Client(base_url=cfg.url, timeout=max(s.source_timeout_s, 10), transport=transport) as c:
                r = c.post("/v1/intents", json={"intent": it, "id_token": claims.get("_id_token", "")})
            out = r.json()
        except Exception as e:  # noqa: BLE001
            return done("action_result.html", 502, ok=False, d=d,
                        reason=f"the actions service did not answer ({type(e).__name__}); nothing is known to have been done")
        ok = out.get("result") == "done"
        return done("action_result.html", 200 if ok else (r.status_code or 502), ok=ok, d=d, out=out,
                    reason=out.get("reason", ""))

    app.state.action_finish = finish

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
        return render(request, "platform_activity.html", u, rows=rows, err=err, now=time.time(),
                      expire_on=cfg.on("expire"))

    return finish

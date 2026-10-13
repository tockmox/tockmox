# SPDX-License-Identifier: Apache-2.0
"""Tockmox UI v0: the front door. Read-only by construction.

Route map (DESIGN-2026-10-04-tockmox-ui.md §2):
  /            home: verdict + your apps            (signed in)
  /status      per-layer sync/health, nodes, alerts (admins)
  /version     version, notes, update notice        (admins)
  /upgrade     instructions + live preflight        (admins; performs nothing)
  /tabs/<id>   first-party feature tabs             (installed features only)
  /models/...  model lifecycle: catalog, watcher candidates, gated promotion, residency (admins; REQ-0048;
               the watcher that looks upstream is a separate opt-in process, app/watcher.py)
  /nodes/...   inference nodes: inventory, import, add, place (admins; REQ-0047; writes nothing,
               every flow ends in a site-values change for the admin to commit)
  /recovery    what to do when this UI or SSO is down (no login, no data)
  /api/v1/status  the status pages as JSON, read-only, provisional (admins; app/status_api.py)
  /<app>[/..]  302 to the console's own host        (configured ids only)

There is deliberately no route that writes to the cluster, to git, to the gateway or to a node.
The one route that opens a connection to an address an admin typed is POST /nodes/probe,
and it is off until the operator names a range (app/probe.py).
"""
from __future__ import annotations

import hmac
import os
import time
from dataclasses import dataclass
from urllib.parse import quote, urlsplit

import httpx
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.base import BaseHTTPMiddleware

from . import feed as feedmod
from . import models_routes
from . import nodes_routes
from . import redirects
from . import sources as sources_mod
from . import status_api
from . import capabilities as capmod
from . import telemetry
from .auth import IDT_MAX_BYTES, OIDC, Sessions, User
from .config import Settings, load
from .notes import ReleaseNotes
from .probe import Prober
from .sources import (CRIT, OK, UNKNOWN, WARN, AlertmanagerSource, ApplicationsSource,
                      DemandSource, InferenceNodesSource, KubeClient, ModelReportSource, NodesSource, PostureSource, PrometheusSource,
                      VerdictSource)

HERE = os.path.dirname(os.path.abspath(__file__))
APP_VERSION = "0.0.1-proto"

CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
       "font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; "
       "form-action 'self'; frame-ancestors 'none'")


def csp_for(issuer: str, end_session: bool) -> str:
    """form-action 'self' also governs where a form's REDIRECT may go, and Sign out is a form
    whose answer is a 303 to the issuer's end-session endpoint. With 'self' alone the browser
    blocked that redirect: the click did nothing visible, a second click found the local session
    already gone, and the Authentik session survived (reference site, 0.8.0 testing 2026-10-11).
    The issuer's origin is allowed for that one purpose; nothing else is widened."""
    if not (end_session and issuer.startswith(("https://", "http://"))):
        return CSP
    parts = urlsplit(issuer)
    return CSP.replace("form-action 'self'", f"form-action 'self' {parts.scheme}://{parts.netloc}")

VERDICT_TEXT = {
    OK: ("All systems healthy", "Every check answered and reported healthy."),
    WARN: ("Some things need a look", "Nothing is down, but something is out of sync or degraded."),
    CRIT: ("Needs attention", "At least one check reports a problem."),
    UNKNOWN: ("Status can't be confirmed", "At least one check did not answer, so this page will not call it healthy."),
}


def verdict(states) -> str:
    """Critical beats unknown beats warning beats ok. OK needs EVERY check to answer healthy."""
    states = list(states)
    if not states:
        return UNKNOWN
    for s in (CRIT, UNKNOWN, WARN):
        if s in states:
            return s
    return OK


class SecurityHeaders(BaseHTTPMiddleware):
    def __init__(self, app, hsts: bool, csp: str = CSP):
        super().__init__(app)
        self.hsts, self.csp = hsts, csp

    async def dispatch(self, request, call_next):
        try:
            resp = await call_next(request)
        except Exception:  # noqa: BLE001 - a crash still gets every header (A10)
            resp = PlainTextResponse("Something went wrong. See /recovery.", status_code=500)
        h = resp.headers
        h["Content-Security-Policy"] = self.csp
        h["X-Frame-Options"] = "DENY"
        h["X-Content-Type-Options"] = "nosniff"
        h["Referrer-Policy"] = "same-origin"
        h["Cross-Origin-Opener-Policy"] = "same-origin"
        h["Cross-Origin-Resource-Policy"] = "same-origin"
        h["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), interest-cohort=()"
        if not request.url.path.startswith("/static/"):
            h["Cache-Control"] = "no-store"
        if self.hsts:
            h["Strict-Transport-Security"] = "max-age=31536000"
        return resp


@dataclass
class Transports:
    """Test seam: one httpx transport per upstream. None means the real network."""
    kube: httpx.BaseTransport | None = None
    prometheus: httpx.BaseTransport | None = None
    alertmanager: httpx.BaseTransport | None = None
    oidc: httpx.BaseTransport | None = None
    feed: httpx.BaseTransport | None = None
    posture: httpx.BaseTransport | None = None
    probe: httpx.BaseTransport | None = None      # inference-node probe (REQ-0047)
    resolver: object = None                       # DNS for the probe; None = socket.getaddrinfo


def create_app(settings: Settings | None = None, transports: Transports | None = None,
               notes_path: str | None = None) -> FastAPI:
    s = settings or load()
    tp = transports or Transports()
    telemetry.setup_logging()
    telemetry.serve_from_env()
    app = FastAPI(title="Tockmox UI", docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(SecurityHeaders, hsts=s.secure_cookies, csp=csp_for(s.oidc_issuer, s.oidc_end_session))
    app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")
    tpl = Jinja2Templates(directory=os.path.join(HERE, "templates"))
    tpl.env.autoescape = True

    def _ago(ts):
        if not ts:
            return "never"
        d = int(time.time() - ts)
        return f"{d}s ago" if d < 60 else (f"{d // 60}m ago" if d < 3600 else f"{d // 3600}h ago")

    tpl.env.filters["ago"] = _ago

    sessions = Sessions(s.session_secret, s.session_max_age_s, s.admin_group, s.secure_cookies)
    oidc = OIDC(s.oidc_issuer, s.oidc_client_id, s.oidc_client_secret, s.oidc_redirect_url,
                timeout=s.source_timeout_s, transport=tp.oidc, scopes=s.oidc_scopes)
    kube = KubeClient(s.kube_url, s.kube_token_file, s.kube_ca_file, s.source_timeout_s, tp.kube)
    src_apps = ApplicationsSource(kube, s.argocd_namespace, s.tockmox_repo, stale_after_s=s.argocd_stale_s)
    src_nodes = NodesSource(kube)
    src_prom = PrometheusSource(s.prometheus_url, s.source_timeout_s, tp.prometheus)
    src_am = AlertmanagerSource(s.alertmanager_url, s.source_timeout_s, tp.alertmanager,
                                heartbeat=s.alertmanager_heartbeat)
    posture_f = s.feature("posture")
    src_posture = PostureSource(posture_f.options if posture_f else {}, s.source_timeout_s, tp.posture)
    checker = feedmod.UpdateChecker(s.update_enabled, s.update_feed_url, s.update_public_keys,
                                    s.update_interval_s, s.source_timeout_s, tp.feed)
    notes = ReleaseNotes(notes_path or os.environ.get("TOCKMOX_UI_NOTES",
                                                      os.path.join(HERE, "..", "notes", "CHANGELOG.md")))
    app.state.settings, app.state.checker, app.state.oidc = s, checker, oidc
    src_inodes = InferenceNodesSource(s.prometheus_url, s.nodes.inventory, s.source_timeout_s, tp.prometheus)
    prober_kw = {"resolver": tp.resolver} if tp.resolver else {}
    prober = Prober(s.nodes.probe_allowed, s.nodes.probe_denied, s.nodes.probe_timeout_s,
                    s.nodes.probe_max_bytes, tp.probe, **prober_kw)
    app.state.sources = {"apps": src_apps, "nodes": src_nodes, "prometheus": src_prom,
                         "alertmanager": src_am, "posture": src_posture}
    if s.nodes.inventory.nodes:
        # configured nodes join the verdict (AC-47.7); none configured, nothing to say
        app.state.sources["inference_nodes"] = src_inodes

    # ------------------------------------------------------------ helpers

    def user_of(request: Request) -> User | None:
        u = sessions.read(request.cookies.get(sessions.session_cookie))
        if u is not None and u.sid in revoked:
            return None
        return u

    revoked: set = set()   # logged-out session ids; per process (one replica in v0), bounded by session max-age

    def tabs_for(u: User):
        return [f for f in s.features if f.enabled and (u.is_admin or not f.admin_only)]

    def docs_repo_link() -> str:
        """The docs folder in the source repository AT THE RUNNING RELEASE, so the page a reader
        lands on matches what is installed; main when the version is not a release. Read through
        the cached Applications source; a failure reads as main, never as an error."""
        ref = "main"
        try:
            ver = running_version(src_apps.read())
            if ver.get("version"):
                ref = "v" + str(ver["version"]).lstrip("v")
        except Exception:  # noqa: BLE001
            pass
        return f"{s.docs_repo_url}/tree/{ref}/docs"

    def footer_version(u: User | None) -> dict | None:
        """What the footer says about the version (TM-1014): the RUNNING Tockmox release, read
        from the layers' Argo CD revision through the same cached source as the pages, never the
        UI's own build number. Signed-in only, so an anonymous page never reaches Argo CD; the
        "new version" pill is the admins' (the update check is theirs)."""
        if u is None:
            return None
        try:
            ver = running_version(src_apps.read())
        except Exception:  # noqa: BLE001 - a footer never breaks a page
            return None
        out = {"state": ver["state"], "version": ver.get("version"), "ref": ver.get("ref"), "newer": None}
        if u.is_admin and ver.get("version"):
            lt = _latest_target(ver["version"])
            out["newer"] = lt["version"] if lt else None
        return out

    def render(request, name, u: User | None, status_code=200, **ctx):
        ctx.update(request=request, user=u, site=s, tabs=tabs_for(u) if u else [],
                   app_version=APP_VERSION, path=request.url.path, verdict_text=VERDICT_TEXT,
                   footer=footer_version(u))
        return tpl.TemplateResponse(request, name, ctx, status_code=status_code)

    def need_login(request: Request):
        nxt = request.url.path + (("?" + request.url.query) if request.url.query else "")
        return RedirectResponse("/login?next=" + quote(nxt, safe=""), status_code=302)

    def forbidden(request, u):
        return render(request, "error.html", u, status_code=403, title="Not available",
                      message="This page is for platform administrators.")

    def csrf_ok(u: User, token: str) -> bool:
        return bool(token) and hmac.compare_digest(u.csrf.encode(), token.encode())

    def readings():
        return {k: v.read() for k, v in app.state.sources.items()
                if k != "posture"}

    def running_version(apps_reading):
        # Stale data never vouches for the running version (fresh-eyes review,
        # finding 2) ... but the data that has to be fresh is the TOCKMOX LAYERS'.
        # Until TM-0904 any stale application, a drill leftover included, made
        # this refuse while every layer was fresh and on one release.
        apps = apps_reading.data
        if apps is None or apps_reading.fetched_at is None:
            # No answer this time: what `data` holds is the last good answer,
            # kept for display, and a cached answer never vouches.
            return {"state": "unknown", "version": None, "layers": [],
                    "reason": f"Argo CD could not be read just now ({apps_reading.reason or 'no answer'})."}
        layers = src_apps.tockmox_layers(apps)
        stale_layers = [a["name"] for a in src_apps.stale(layers)]
        if stale_layers:
            return {"state": "unknown", "version": None, "layers": layers,
                    "reason": f"{len(stale_layers)} Tockmox layer(s) not reconciled recently: "
                              f"{', '.join(stale_layers)}. Their revision is the last one Argo CD recorded, "
                              "so it does not vouch for what is running."}
        if not layers:
            return {"state": "unknown", "version": None, "layers": [],
                    "reason": f"No Argo CD application matches {src_apps.layer_rule()}."}
        revs = sorted({a["revision"] for a in layers if a["revision"]})
        if not revs:
            return {"state": "unknown", "version": None, "layers": layers,
                    "reason": "The Tockmox layers name no target revision."}
        if len(revs) > 1:
            return {"state": "mixed", "version": None, "layers": layers, "revisions": revs}
        if not feedmod.parse_version(revs[0]):
            # a floating ref ("main") is not a release: no comparison, no upgrade arithmetic
            return {"state": "floating", "version": None, "ref": revs[0], "layers": layers}
        return {"state": "single", "version": revs[0], "layers": layers}

    # ------------------------------------------------------------ public routes

    @app.get("/healthz", response_class=PlainTextResponse)
    def healthz():
        return "ok"

    @app.get("/recovery", response_class=HTMLResponse)
    def recovery(request: Request):
        return render(request, "recovery.html", user_of(request), argocd_ns=s.argocd_namespace)

    @app.get("/login")
    def login(request: Request, next: str = "/"):
        if not next.startswith("/") or next.startswith("//") or "\\" in next:
            next = "/"
        try:
            url, st = oidc.begin()
        except Exception as e:  # noqa: BLE001
            telemetry.oidc_failure("discovery", e)
            return render(request, "error.html", None, status_code=503, title="Sign-in is unavailable",
                          message="The identity provider did not answer. If you were already signed in, "
                                  "your session still works. Otherwise see the recovery page.")
        st["next"] = next
        resp = RedirectResponse(url, status_code=302)
        resp.set_cookie(sessions.login_cookie, sessions.l.dumps(st), max_age=600, **sessions.cookie_args())
        return resp

    @app.get("/auth/callback")
    def callback(request: Request, code: str = "", state: str = "", error: str = ""):
        raw = request.cookies.get(sessions.login_cookie)
        try:
            st = sessions.l.loads(raw or "", max_age=600)
        except Exception:  # noqa: BLE001
            st = None
        if error or not st or not code or not hmac.compare_digest(str(st.get("state", "")).encode(), state.encode()):
            return render(request, "error.html", None, status_code=400, title="Sign-in did not complete",
                          message="The sign-in response could not be matched to a request from this browser. "
                                  "Start again from the home page.")
        try:
            claims = oidc.finish(code, st)
        except Exception as e:  # noqa: BLE001
            telemetry.oidc_failure("token", e)
            return render(request, "error.html", None, status_code=502, title="Sign-in did not complete",
                          message="The identity provider's answer could not be verified.")
        name = claims.get("name") or claims.get("preferred_username") or claims["sub"]
        resp = RedirectResponse(st.get("next") or "/", status_code=302)
        resp.set_cookie(sessions.session_cookie, sessions.issue(claims["sub"], name, claims["groups"]),
                        max_age=s.session_max_age_s, **sessions.cookie_args())
        idt = claims.get("_id_token") or ""
        if s.oidc_end_session and idt and len(idt) <= IDT_MAX_BYTES:
            resp.set_cookie(sessions.idt_cookie, idt, max_age=s.session_max_age_s, **sessions.cookie_args())
        resp.delete_cookie(sessions.login_cookie, path="/", secure=s.secure_cookies, httponly=True)
        return resp

    @app.post("/logout")
    def logout(request: Request, csrf: str = Form("")):
        u = user_of(request)
        if u and not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        if u:
            revoked.add(u.sid)
        # SIGN OUT ENDS THE IDENTITY PROVIDER'S SESSION TOO (TM-1014, 0.8.0 testing 2026-10-11):
        # RP-initiated logout at the issuer's end_session_endpoint. Whether that ends the whole
        # Authentik session or only this application's is the provider's invalidation flow
        # (default-invalidation-flow ends it; default-provider-invalidation-flow, Authentik's default
        # for new providers, does not), docs/administration/tockmox-ui.md. The local session is
        # gone either way; an issuer that cannot be reached leaves the user on our own page.
        dest = None
        if u and s.oidc_end_session and s.oidc_issuer:
            dest = oidc.end_session_url(s.oidc_post_logout_url, request.cookies.get(sessions.idt_cookie, ""))
        if dest:
            resp = RedirectResponse(dest, status_code=303)
        else:
            resp = render(request, "signed_out.html", None)
        resp.delete_cookie(sessions.session_cookie, path="/", secure=s.secure_cookies, httponly=True)
        resp.delete_cookie(sessions.idt_cookie, path="/", secure=s.secure_cookies, httponly=True)
        return resp

    # ------------------------------------------------------------ signed-in routes

    @app.get("/", response_class=HTMLResponse)
    def home(request: Request):
        u = user_of(request)
        if not u:
            return need_login(request)
        r = readings()
        v = verdict(x.state for x in r.values())
        apps = [a for a in s.apps if a.visible_to(set(u.groups))]
        ver = running_version(r["apps"]) if u.is_admin else None
        if u.is_admin:
            checker.check()
        return render(request, "home.html", u, verdict=v, readings=r, apps=apps, version=ver,
                      target=_latest_target(ver.get("version")) if ver else None,
                      docs_repo_link=docs_repo_link())

    @app.get("/status", response_class=HTMLResponse)
    def status(request: Request):
        u = user_of(request)
        if not u:
            return need_login(request)
        if not u.is_admin:
            return forbidden(request, u)
        r = readings()
        g = s.app("grafana")
        return render(request, "status.html", u, readings=r, verdict=verdict(x.state for x in r.values()),
                      now=time.time(), heartbeat=s.alertmanager_heartbeat or "Watchdog",
                      pipeline=list(sources_mod.pipeline_alerts(s.alertmanager_heartbeat)),
                      hb_purpose=sources_mod.HEARTBEAT_PURPOSE,
                      grafana=g if g and g.visible_to(set(u.groups)) else None)

    def _latest_target(cur):
        st = checker.state
        if st.verified and cur:
            lt = st.latest()
            if lt and feedmod.newer(lt["version"], cur):
                return lt
        return None

    def capability_rows():
        rd = src_apps.read()
        apps = rd.data if rd.fetched_at is not None else None
        stale = {a["name"] for a in src_apps.stale(apps)} if apps else set()
        return rd, capmod.evaluate(dict(s.capabilities), apps, stale)

    @app.get("/capabilities", response_class=HTMLResponse)
    def capabilities(request: Request):
        u = user_of(request)
        if not u:
            return need_login(request)
        if not u.is_admin:
            return forbidden(request, u)
        rd, rows = capability_rows()
        return render(request, "capabilities.html", u, rows=rows, apps_reading=rd)

    @app.get("/version", response_class=HTMLResponse)
    def version(request: Request):
        u = user_of(request)
        if not u:
            return need_login(request)
        if not u.is_admin:
            return forbidden(request, u)
        r = {"apps": src_apps.read()}
        ver = running_version(r["apps"])
        st = checker.check()
        cur = ver.get("version")
        return render(request, "version.html", u, ver=ver, apps_reading=r["apps"], feed=st,
                      target=_latest_target(cur), notes=notes.get(cur) if cur else notes.first(),
                      notes_of_build=not cur)

    @app.post("/check-updates")
    def check_updates(request: Request, csrf: str = Form("")):
        u = user_of(request)
        if not u:
            return need_login(request)
        if not u.is_admin:
            return forbidden(request, u)
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        checker.check(force=True)
        return RedirectResponse("/version", status_code=303)

    @app.get("/upgrade", response_class=HTMLResponse)
    def upgrade(request: Request, to: str = ""):
        u = user_of(request)
        if not u:
            return need_login(request)
        if not u.is_admin:
            return forbidden(request, u)
        r = readings()
        ver = running_version(r["apps"])
        cur = ver.get("version")
        st = checker.state
        tgt = to.strip()
        if tgt and not feedmod.parse_version(tgt):
            tgt = ""
        if not tgt:
            lt = _latest_target(cur)
            tgt = lt["version"] if lt else ""
        apps = r["apps"].data or []
        layers = ver.get("layers") or []
        alerts = [a for a in (r["alertmanager"].data or []) if a["severity"] == "critical"
                  and a["name"] not in sources_mod.pipeline_alerts(s.alertmanager_heartbeat)]

        def chk(label, state, detail, manual=False):
            return {"label": label, "state": state, "detail": detail, "manual": manual}

        fresh_apps = r["apps"].state != UNKNOWN
        checks = [
            chk("Every layer is Synced",
                (OK if all(a["sync"] == "Synced" for a in apps) else CRIT) if fresh_apps and apps else UNKNOWN,
                r["apps"].reason or ""),
            chk("Every layer is Healthy",
                (OK if all(a["health"] == "Healthy" for a in apps) else CRIT) if fresh_apps and apps else UNKNOWN,
                ""),
            chk("All Tockmox layers are on one revision",
                {"single": OK, "mixed": CRIT}.get(ver["state"], UNKNOWN),
                ", ".join(ver.get("revisions", [])) if ver["state"] == "mixed" else (cur or "")),
            chk("No critical alerts are firing",
                (OK if not alerts else CRIT) if r["alertmanager"].state != UNKNOWN else UNKNOWN,
                ", ".join(a["name"] for a in alerts[:5]) or r["alertmanager"].reason),
        ]
        rel = st.release(tgt) if (st.verified and tgt) else None
        path = st.between(cur, tgt) if (st.verified and cur and tgt) else []
        if rel and rel.get("minUpgradeFrom") and cur:
            ok = not feedmod.newer(rel["minUpgradeFrom"], cur)
            checks.append(chk(f"This release can be reached from {cur}", OK if ok else CRIT,
                              f"needs {rel['minUpgradeFrom']} or later"))
        checks.append(chk("You have restored a backup at least once (the upgrade page requires it)",
                          UNKNOWN, "This UI cannot see your restore drills yet. Check it yourself.", manual=True))
        if cur and tgt:
            checks.insert(4, chk(f"{tgt} is newer than {cur}", OK if feedmod.newer(tgt, cur) else CRIT,
                                 "" if feedmod.newer(tgt, cur) else "this would be a downgrade or a no-op; the guide does not cover it"))
        kind = feedmod.bump_kind(cur or "", tgt) if tgt else "unknown"
        steps = {"patch": [0, 1, 5, 6, 7], "minor": [0, 1, 2, 3, 4, 5, 6, 7],
                 "major": [0, 1, 2, 3, 4, 5, 6, 7]}.get(kind, [0, 1, 2, 3, 4, 5, 6, 7])
        breaking = []
        for rr in path:
            for b in rr.get("breaking") or []:
                breaking.append((rr["version"], str(b)))
        return render(request, "upgrade.html", u, cur=cur, tgt=tgt, kind=kind, steps=steps,
                      checks=checks, ready=all(c["state"] == OK for c in checks if not c["manual"]),
                      breaking=breaking, feed=st, ver=ver, argocd_ns=s.argocd_namespace,
                      cur_rev=("v" + cur.lstrip("v")) if cur and feedmod.parse_version(cur) else None,
                      tgt_rev=("v" + tgt.lstrip("v")) if tgt and not tgt.startswith("v") else tgt)

    @app.get("/tabs/{fid}", response_class=HTMLResponse)
    def tab(request: Request, fid: str):
        u = user_of(request)
        if not u:
            return need_login(request)
        f = next((t for t in tabs_for(u) if t.id == fid), None)
        if f is None:
            # absent, not locked (council C1): an uninstalled feature has no page
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message="There is no such page.")
        if fid == "posture":
            rd = src_posture.read()
            age = None
            try:
                started = sources_mod._parse_ts(((rd.data or {}).get("run") or {}).get("startedAt"))
                if started is not None:
                    sec = max(0, int(time.time() - started))
                    age = f"{sec // 86400}d {sec % 86400 // 3600}h" if sec >= 86400 else f"{sec // 3600}h {sec % 3600 // 60}m" if sec >= 3600 else f"{sec // 60}m"
            except Exception:  # noqa: BLE001
                age = None
            return render(request, "tab_posture.html", u, feature=f, reading=rd, report_age=age)
        return render(request, "tab_generic.html", u, feature=f)

    # ------------------------------------------------------------ inference nodes (REQ-0047)

    nodes_routes.register(app, s, render, user_of, need_login, forbidden, csrf_ok, src_inodes, prober, APP_VERSION)

    # ------------------------------------------------------------ model lifecycle (REQ-0048)

    src_report = ModelReportSource(s.lifecycle.report_file, s.lifecycle.report_max_age_s)
    src_demand = DemandSource(s.prometheus_url, s.lifecycle.demand_query, s.source_timeout_s, tp.prometheus)
    src_verdicts = VerdictSource(s.lifecycle.verdicts_dir, s.lifecycle.verdicts_repo_path)
    models_routes.register(app, s, render, user_of, need_login, forbidden, csrf_ok, src_report, src_demand, APP_VERSION,
                           src_verdicts, prober)

    # ------------------------------------------------------------ read-only status API (TM-0841)

    status_api.register(app, user_of, readings, verdict, running_version, src_apps, APP_VERSION,
                        capabilities=lambda: capability_rows()[1])

    # ------------------------------------------------------------ short-path redirects (LAST)

    @app.get("/{app_id}", include_in_schema=False)
    @app.get("/{app_id}/{rest:path}", include_in_schema=False)
    def short(request: Request, app_id: str, rest: str = ""):
        # Signed-in only, and only to apps this user may see: an anonymous probe must not
        # learn which admin consoles exist (fresh-eyes review, finding 7). Unknown and
        # not-yours look identical (404).
        u = user_of(request)
        a = s.app(app_id)
        if a is not None and u is None:
            return need_login(request)
        if a is None or not a.visible_to(set(u.groups)):
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message="There is no such page or app.")
        raw_path = request.scope.get("raw_path", b"").decode("latin-1")
        prefix = "/" + app_id
        rest_raw = raw_path[len(prefix):] if raw_path.startswith(prefix) else ("/" + rest if rest else "")
        try:
            dest = redirects.target(a.url, rest_raw, request.url.query)
        except redirects.Refused:
            return PlainTextResponse("refused", status_code=400)
        return RedirectResponse(dest, status_code=302)

    return app

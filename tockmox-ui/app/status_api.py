# SPDX-License-Identifier: Apache-2.0
"""The read-only status API (TM-0841). Provisional: the shape may change in a minor release.

  GET /api/v1/status     what the home and status pages show, as JSON (admins)

Nothing under /api/ accepts a write verb: POST, PUT, PATCH and DELETE answer 405 whoever asks,
before any authentication, so the refusal itself tells nothing. The API reads the same sources,
through the same cache, as the pages, and inherits their rule: ABSENCE IS NOT GREEN. A source
that did not answer this time is reported as `unknown` with its reason, and the lists it would
have filled are null, not empty, so a consumer cannot read "no alerts" off a dead Alertmanager.

Argo CD Application CRs keep their last sync and health when the application controller stops
(lab, TM-0901 D4), so an application whose status.reconciledAt is older than
sources.kubernetes.argocdStaleSeconds reads `unknown` here, whatever the CR says.
"""
from __future__ import annotations

import datetime
import time

from fastapi import Request
from fastapi.responses import JSONResponse

from .sources import CRIT, OK, UNKNOWN, WARN

SCHEMA = "tockmox-status/1"
WRITE_VERBS = ["POST", "PUT", "PATCH", "DELETE"]
ALLOW = "GET, HEAD"


def _iso(ts) -> str | None:
    if ts is None:
        return None
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def app_state(a: dict, stale: bool, stale_after_s: float) -> tuple[str, str]:
    """One application's state. Staleness wins: a CR nobody reconciled recently vouches for nothing."""
    if stale:
        age = "never reconciled" if a.get("reconciledAt") is None else f"not reconciled in {int(stale_after_s)}s"
        return UNKNOWN, f"{age}; its sync and health are the last values Argo CD recorded"
    if a["health"] in ("Degraded", "Missing"):
        return CRIT, f"health {a['health']}"
    if a["health"] in ("Unknown", "") or a["sync"] in ("Unknown", ""):
        return UNKNOWN, "no sync or health status"
    if a["sync"] == "OutOfSync" or a["health"] in ("Progressing", "Suspended"):
        return WARN, f"sync {a['sync']}, health {a['health']}"
    return OK, ""


def build(readings: dict, verdict: str, version: dict, src_apps, app_version: str, now=time.time) -> dict:
    """The response body. `readings` is the pages' dict of source name -> Reading."""
    sources = {k: {"name": r.source, "state": r.state, "reason": r.reason,
                   "fetchedAt": _iso(r.fetched_at), "lastOkAt": _iso(r.last_ok_at)}
               for k, r in readings.items()}
    apps_r = readings.get("apps")
    applications = None
    if apps_r is not None and apps_r.fetched_at is not None and apps_r.data is not None:
        apps = apps_r.data
        stale_names = {a["name"] for a in src_apps.stale(apps)}
        layer_names = {a["name"] for a in src_apps.tockmox_layers(apps)}
        applications = []
        for a in apps:
            st, why = app_state(a, a["name"] in stale_names, src_apps.stale_after_s)
            applications.append({"name": a["name"], "tockmoxLayer": a["name"] in layer_names,
                                 "repo": a["repo"], "revision": a["revision"],
                                 "sync": a["sync"], "health": a["health"],
                                 "reconciledAt": _iso(a.get("reconciledAt")), "state": st, "reason": why})

    def fresh(key):
        r = readings.get(key)
        return r.data if (r is not None and r.fetched_at is not None) else None

    nodes = fresh("nodes")
    alerts = fresh("alertmanager")
    inodes = fresh("inference_nodes") if "inference_nodes" in readings else None
    ver = {k: v for k, v in version.items() if k != "layers"}
    return {
        "schema": SCHEMA,
        "provisional": True,
        "generatedAt": _iso(now()),
        "ui": {"version": app_version},
        "verdict": verdict,
        "sources": sources,
        "applications": applications,
        "version": ver,
        "nodes": [{"name": n["name"], "ready": n["ready"], "version": n["version"]} for n in nodes] if nodes is not None else None,
        "alerts": [{"name": a["name"], "severity": a["severity"], "namespace": a["namespace"],
                    "summary": a["summary"], "startsAt": a["startsAt"]} for a in alerts] if alerts is not None else None,
        "inferenceNodes": [{"id": n["id"], "state": n["state"], "reason": n["why"],
                            "checks": [{"what": c["what"], "state": c["state"], "reason": c["why"]} for c in n["checks"]],
                            "memory": n["memory"]} for n in inodes] if inodes is not None else None,
    }


def register(app, user_of, readings, verdict, running_version, src_apps, app_version: str, capabilities=None):
    """Mount the API. Call before the short-path catch-all, which would otherwise swallow /api/."""

    @app.api_route("/api/{rest:path}", methods=WRITE_VERBS, include_in_schema=False)
    def refuse_write(rest: str = ""):
        # A write verb is refused for everyone, signed in or not: there is no write path (TM-0814 line 5).
        return JSONResponse({"error": "this API is read-only"}, status_code=405, headers={"Allow": ALLOW})

    @app.get("/api/v1/status")
    def status(request: Request):
        u = user_of(request)
        if not u:
            return JSONResponse({"error": "sign in at /login and send the session cookie"}, status_code=401)
        if not u.is_admin:
            return JSONResponse({"error": "this API is for platform administrators"}, status_code=403)
        r = readings()
        body = build(r, verdict(x.state for x in r.values()), running_version(r["apps"]), src_apps, app_version)
        # Additive within tockmox-status/1 (TM-1017): what each capability is set to and whether its
        # layer deploys it, the rows the /capabilities page shows.
        body["capabilities"] = [{"key": c["key"], "configured": c["configured"], "deployed": c["deployed"],
                                 "agree": c["agree"], "evidence": c["evidence"]}
                                for c in capabilities()] if capabilities else None
        return JSONResponse(body)

    @app.get("/api/{rest:path}", include_in_schema=False)
    def no_such(rest: str = ""):
        return JSONResponse({"error": "no such endpoint"}, status_code=404)

# SPDX-License-Identifier: Apache-2.0
"""A demo server for looking at the Platform Management pages: mock upstreams shaped like a real
reference site (its CronJobs, CronWorkflows and signal values as read 2026-10-23), no network.

    python3 tests/demo_platform.py [port]     then sign in with GET /__demo_login
Not part of the product; a design aid and the screenshot source for the design doc.
"""
import os
import sys
import time

import httpx
import uvicorn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.environ.setdefault("TOCKMOX_UI_SESSION_SECRET", "d" * 48)
os.environ.setdefault("TOCKMOX_UI_OIDC_CLIENT_SECRET", "demo")

from app import config as cfgmod  # noqa: E402
from app import platform as pm  # noqa: E402
from app.auth import Sessions  # noqa: E402
from app.cronexpr import Cron  # noqa: E402
from app.main import Transports, create_app  # noqa: E402
from tests.proto_support import World, base_doc  # noqa: E402
from fastapi.responses import RedirectResponse  # noqa: E402

NOW = time.time()
CT = "America/Chicago"
# (namespace, name, schedule, tz, state) as the reference site ran them; state shapes the demo
JOBS = [
    ("forgejo", "forgejo-backup", "15 21 * * *", CT, "up"),
    ("harbor", "harbor-postgres-backup", "5 21 * * *", CT, "up"),
    ("site-identity", "authentik-postgres-backup", "0 21 * * *", CT, "up"),
    ("site-monitoring", "capacity-drift-snapshot", "0 3 * * *", CT, "up"),
    ("site-monitoring", "forgejo-label-reconciler", "*/2 * * * *", "UTC", "up"),
    ("site-paperless", "paperless-drill-b", "30 11 * * 6", CT, "up"),
    ("site-paperless", "paperless-exporter", "45 20 * * *", CT, "up"),
    ("site-paperless", "paperless-postgres-backup", "10 21 * * *", CT, "up"),
    ("site-paperless", "paperless-weekly-digest", "5 8 * * 1", CT, "up"),
    ("site-tish", "tish-db-drill", "30 4 * * 5", CT, "never"),
    ("site-tish", "tish-sched-daily-brief", "35 9 * * *", CT, "up"),
    ("site-tish", "tish-sched-daily-capacity-alerts", "30 9 * * *", CT, "paused"),
    ("site-tish", "tish-sched-weekly-catches", "0 9 * * 0", CT, "never"),
    ("tockmox-agent", "r4-drill-rehearsal", "0 10 * * 3", CT, "up"),
    ("tockmox-ai", "owui-db-drill", "30 4 * * 3", CT, "up"),
    ("tockmox-ai", "tockmox-litellm-db-drill", "30 4 * * 1", CT, "up"),
    ("tockmox-platform", "backup-daily", "0 2 * * *", "UTC", "up"),
    ("tockmox-platform", "backup-weekly", "0 3 * * 0", "UTC", "up"),
    ("tockmox-platform", "snapshot-hourly", "0 * * * *", "UTC", "up"),
    ("tockmox-selfcheck", "tockmox-heartbeat", "*/15 * * * *", CT, "up"),
    ("tockmox-ai", "tockmox-console-key-check", "*/15 * * * *", "UTC", "failed"),
]
SIGNALS = {"critical": 0, "warnings": 3, "heartbeat": 1, "probes": 1.0, "distinct-7d": 11, "outofsync": 0,
           "degraded": 0, "memory": .21, "cpu": .18, "volume": .71, "local-share": .243, "spend-24h": .63, "spend-30d": 23.45,
           "budget-left": .62, "nodes-not-ready": 0, "ai-node-unverified": 0,
           "drill-age": .01, "backups-overdue": 0, "cert": 48.3, "vulns": 74}


def build_world():
    w = World()
    for ns, name, sch, tz, state in JOBS:
        c = Cron(sch, tz)
        prev, nxt = c.prev_before(NOW), c.next_after(NOW)
        lab = {"namespace": ns, "cronjob": name}
        w.series.setdefault("kube_cronjob_info", []).append((dict(lab, schedule=sch, timezone=tz), 1))
        w.series.setdefault("kube_cronjob_next_schedule_time", []).append((lab, nxt))
        w.series.setdefault("kube_cronjob_spec_suspend", []).append((lab, 1 if state == "paused" else 0))
        w.series.setdefault("kube_cronjob_status_active", []).append((lab, 0))
        if state in ("up", "failed", "paused"):
            w.series.setdefault("kube_cronjob_status_last_schedule_time", []).append((lab, prev))
            ok = prev + 40 if state == "up" else prev - 7 * 86400
            w.series.setdefault("kube_cronjob_status_last_successful_time", []).append((lab, ok))
            jl = {"namespace": ns, "job_name": f"{name}-1"}
            w.series.setdefault('kube_job_owner{owner_kind="CronJob"}', []).append((dict(jl, owner_name=name), 1))
            w.series.setdefault("kube_job_status_start_time", []).append((jl, prev))
            w.series.setdefault("kube_job_status_failed", []).append((jl, 1 if state == "failed" else 0))
    for a in pm.load_catalog().all():
        for s in a.signals:
            w.series[s.query] = [({}, SIGNALS[s.id])]
    w.series['up{job=~".*kube-state-metrics.*"} == 1'] = [({"job": "kube-state-metrics"}, 1)]
    return w


def cronworkflows():
    out = []
    for ns, name, sch in [("restore-drill", f"restore-drill-{n}", s) for n, s in
                          [("authentik", "0 5 * * 2"), ("etcd", "30 5 * * 2"), ("forgejo", "0 5 * * 4"),
                           ("harbor", "30 5 * * 4"), ("litellm", "0 6 * * 4"), ("openwebui-block", "0 5 * * 6")]] + \
            [("site-monitoring", "capacity-drift", "30 3 * * *")]:
        prev = Cron(sch, CT).prev_before(NOW)
        out.append({"metadata": {"name": name, "namespace": ns}, "spec": {"schedules": [sch], "timezone": CT},
                    "status": {"lastScheduledTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(prev))}})
    return out


def make_app(ledger_jobs=None):
    w = build_world()
    doc = base_doc()
    doc["site"]["name"] = "Maaks Home"
    doc["apps"][1]["url"] = "https://grafana.int.example.com"
    doc["features"] = dict(doc["features"], platform={"enabled": True, "timezone": CT,
                                                      **({"ledgerUrl": "http://ledger.test", "interfaceUrl": "https://chat.int.example.com"} if ledger_jobs is not None else {}),
                                                      "workflowSuccessQuery": "demo_cronworkflow_last_success"})
    cws = cronworkflows()
    for cw in cws:
        prev = Cron(cw["spec"]["schedules"][0], CT).prev_before(NOW)
        w.series.setdefault("demo_cronworkflow_last_success", []).append(
            ({"namespace": cw["metadata"]["namespace"], "cronworkflow": cw["metadata"]["name"]}, prev + 300))
    s = cfgmod.parse(doc)
    kube_h = w.handler("kube")

    def kube(req):
        if req.url.path.endswith("/cronworkflows"):
            return httpx.Response(200, json={"items": cws})
        return kube_h(req)

    def ledger(req):
        return httpx.Response(200, json={"jobs": ledger_jobs or []})
    tp = Transports(kube=httpx.MockTransport(kube), prometheus=httpx.MockTransport(w.handler("prometheus")),
                    alertmanager=httpx.MockTransport(w.handler("alertmanager")), ledger=httpx.MockTransport(ledger))
    app = create_app(s, tp, notes_path=os.path.join(ROOT, "tests", "fixtures", "none.md"))
    ses = Sessions(s.session_secret, s.session_max_age_s, s.admin_group, s.secure_cookies)

    @app.get("/__demo_login", include_in_schema=False)
    def demo_login(to: str = "/platform"):
        r = RedirectResponse(to, status_code=302)
        r.set_cookie(ses.session_cookie, ses.issue("demo", "Jeff", ["tockmox-admins"]), httponly=True)
        return r
    # the catch-all short-path route was registered first; move the demo route ahead of it
    app.router.routes.insert(0, app.router.routes.pop())
    return app


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    jobs = None
    if "--ledger" in sys.argv:
        jobs = [{"id": "j-7f3a", "profile": "change", "status": "input_required", "created": NOW - 3 * 3600, "cost_usd": 0.0},
                {"id": "j-7f19", "profile": "capacity", "status": "completed", "created": NOW - 9 * 3600, "cost_usd": 0.0},
                {"id": "j-7e88", "profile": "incident", "status": "completed", "created": NOW - 20 * 3600, "cost_usd": 0.04},
                {"id": "j-7e02", "profile": "platform-manager", "status": "completed", "created": NOW - 18 * 3600, "cost_usd": 0.11},
                {"id": "j-7d55", "profile": "security", "status": "failed", "created": NOW - 26 * 3600, "cost_usd": 0.02}]
    uvicorn.run(make_app(jobs), host="127.0.0.1", port=port, log_level="warning")

# SPDX-License-Identifier: Apache-2.0
"""Platform Management (DESIGN-2026-10-23-platform-management.md): the operations team, read-only."""
import calendar
import os
import time
import types
from zoneinfo import ZoneInfo

import httpx
import pytest

from tests.proto_support import ROOT, base_doc, login_as, make_client, World  # noqa: F401
from tests.proto_support import _secret, world  # noqa: F401  (fixtures)
from app import platform as pm
from app.cronexpr import Cron, describe
from app.main import Transports, create_app
from app import config as cfgmod
from fastapi.testclient import TestClient

NOW = time.time()


def doc_with_platform(**opts):
    d = base_doc()
    d["features"] = dict(d["features"], platform=dict({"enabled": True, "timezone": "America/Chicago"}, **opts))
    return d


def add_cronjob(world, ns, name, schedule="0 * * * *", tz="UTC", last_run=None, last_ok=None, nxt=None,
                suspended=0, active=0, job_failed=None):
    lab = {"namespace": ns, "cronjob": name}
    world.series.setdefault("kube_cronjob_info", []).append((dict(lab, schedule=schedule, timezone=tz), 1))
    for q, v in (("kube_cronjob_status_last_schedule_time", last_run), ("kube_cronjob_status_last_successful_time", last_ok),
                 ("kube_cronjob_next_schedule_time", nxt), ("kube_cronjob_spec_suspend", suspended),
                 ("kube_cronjob_status_active", active)):
        if v is not None:
            world.series.setdefault(q, []).append((lab, v))
    if job_failed is not None and last_run:
        jl = {"namespace": ns, "job_name": f"{name}-1"}
        world.series.setdefault('kube_job_owner{owner_kind="CronJob"}', []).append((dict(jl, owner_name=name), 1))
        world.series.setdefault("kube_job_status_start_time", []).append((jl, last_run))
        world.series.setdefault("kube_job_status_failed", []).append((jl, 1 if job_failed else 0))


def healthy_signals(world):
    """Every signal in the shipped catalog answers inside its thresholds."""
    cat = pm.load_catalog()
    vals = {"critical": 0, "warnings": 0, "heartbeat": 1, "probes": 1, "distinct-7d": 4, "outofsync": 0,
            "degraded": 0, "memory": .4, "cpu": .2, "volume": .5, "local-share": .3, "spend-24h": 1.25,
            "spend-30d": 23.4, "budget-left": .8, "drill-age": 2, "backups-overdue": 0, "cert": 60, "vulns": 0,
            "nodes-not-ready": 0, "ai-node-unverified": 0}
    for a in cat.all():
        for s in a.signals:
            world.series[s.query] = [({}, vals[s.id])]
    world.series['up{job=~".*kube-state-metrics.*"} == 1'] = [({"job": "kube-state-metrics"}, 1)]


class Ledger:
    def __init__(self, jobs=None, down=False):
        self.jobs, self.down, self.seen = jobs or [], down, []

    def handler(self, req):
        self.seen.append(req)
        if self.down:
            raise httpx.ConnectError("refused", request=req)
        return httpx.Response(200, json={"jobs": self.jobs})


def client_for(world, doc, ledger=None, cronworkflows=None):
    s = cfgmod.parse(doc)
    kube_h = world.handler("kube")

    def kube(req):
        if req.url.path.endswith("/cronworkflows") and cronworkflows is not None:
            return httpx.Response(200, json={"items": cronworkflows})
        return kube_h(req)
    tp = Transports(kube=httpx.MockTransport(kube), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")),
                    ledger=httpx.MockTransport(ledger.handler) if ledger else None)
    app = create_app(s, tp, notes_path=os.path.join(ROOT, "tests", "fixtures", "none.md"))
    return TestClient(app, follow_redirects=False), app, s


# ---------------------------------------------------------------- the feature gate

def test_absent_when_not_enabled(world):
    c, app, s = make_client(world)
    login_as(c, s, ["tockmox-admins"])
    r = c.get("/platform")
    assert r.status_code == 404
    assert 'href="/platform"' not in c.get("/").text


def test_admins_only(world):
    c, app, s = client_for(world, doc_with_platform())
    assert c.get("/platform").status_code == 302                      # anonymous: sign in first
    login_as(c, s, ["tockmox-users"])
    assert c.get("/platform").status_code == 403
    assert c.get("/platform/agents/incident").status_code == 403
    login_as(c, s, ["tockmox-admins"])
    r = c.get("/platform")
    assert r.status_code == 200 and 'href="/platform"' in r.text and "Content-Security-Policy" in r.headers


def test_platform_is_a_reserved_launcher_id_only_while_the_feature_is_on():
    d = base_doc()
    d["apps"].append({"id": "platform", "name": "x", "url": "https://x.int.example.com"})
    cfgmod.parse(d)                                   # feature off: an existing app called platform still parses
    d["features"] = dict(d["features"], platform={"enabled": True})
    with pytest.raises(cfgmod.ConfigError, match="reserved"):
        cfgmod.parse(d)


def test_platform_is_never_a_generic_feature_tab(world):
    c, app, s = client_for(world, doc_with_platform())
    login_as(c, s, ["tockmox-admins"])
    assert c.get("/tabs/platform").status_code == 404


def test_no_write_routes(world):
    c, app, s = client_for(world, doc_with_platform())
    u = login_as(c, s, ["tockmox-admins"])
    for path in ("/platform", "/platform/schedule", "/platform/agents/incident"):
        assert c.post(path, data={"csrf": u.csrf}).status_code in (404, 405)
    methods = {m for r in app.routes if getattr(r, "path", "").startswith("/platform") for m in r.methods}
    assert methods <= {"GET", "HEAD"}


# ---------------------------------------------------------------- absence is not green

def test_nothing_answers_reads_unknown_never_healthy(world):
    world.down.add("prometheus")
    c, app, s = client_for(world, doc_with_platform())
    login_as(c, s, ["tockmox-admins"])
    t = c.get("/platform").text
    assert "Not every practice can be confirmed healthy" in t
    assert "Every running practice reports healthy" not in t
    assert "Not connected" in t and "not the same as nothing waiting" in t


# The same scenario with the page's clock pinned, including just after the top of an hour (TM-1134). The page
# reads its clock through app.platform's `time`, so pinning is one monkeypatch on that module; nothing else in
# the process sees it. The fixture below is staged from the SAME instant the page reads, so the scenario cannot
# straddle an hour boundary between the test's clock and the page's, which a module-level NOW read at import
# time and a page clock read a request later could.
HEARTBEAT_CLOCKS = [
    pytest.param(None, id="clock-at-import"),
    pytest.param(calendar.timegm((2026, 10, 24, 4, 0, 8)), id="hh-00-08"),
    pytest.param(calendar.timegm((2026, 10, 24, 4, 0, 29)), id="hh-00-29"),
]


@pytest.mark.parametrize("pinned", HEARTBEAT_CLOCKS)
def test_healthy_world_is_ok_and_says_what_is_not_started(world, monkeypatch, pinned):
    now = NOW if pinned is None else pinned
    monkeypatch.setattr(pm, "time", types.SimpleNamespace(time=lambda: now))
    healthy_signals(world)
    hour = 3600
    prev = Cron("0 * * * *").prev_before(now)
    # Never stage the success after the clock the page reads: at hh:00:08, prev + 30 is 22 s in the future
    # (TM-1134). The clamp keeps the staged job's times at or before `now` at every second of the hour.
    ok = max(prev, min(prev + 30, now - 1))
    add_cronjob(world, "tockmox-selfcheck", "tockmox-heartbeat", "0 * * * *", last_run=prev, last_ok=ok, nxt=prev + hour)
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    t = c.get("/platform").text
    assert "Every running practice reports healthy" in t, t[:3000]
    assert "not started yet" in t                     # roles with no live check: said, not hidden
    assert "Not started" in t


def test_one_breached_signal_names_itself(world):
    healthy_signals(world)
    cat = pm.load_catalog()
    q = next(s.query for s in cat.get("capacity").signals if s.id == "volume")
    world.series[q] = [({}, 0.95)]
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    t = c.get("/platform").text
    assert "A practice has a problem" in t and "Fullest volume" in t
    a = c.get("/platform/agents/capacity").text
    assert "95%" in a and "problem above 90%" in a


def test_one_bad_query_is_that_signals_unknown_not_the_page(world):
    healthy_signals(world)
    cat = pm.load_catalog()
    q = next(s.query for s in cat.get("change").signals if s.id == "degraded")
    del world.series[q]                               # answers with an empty vector
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    a = c.get("/platform/agents/change").text
    assert "no answer" in a
    o = c.get("/platform").text
    assert "Not every practice can be confirmed healthy" in o


def test_optional_signal_absent_is_not_installed_and_not_counted(world):
    healthy_signals(world)
    cat = pm.load_catalog()
    q = next(s.query for s in cat.get("security").signals if s.id == "vulns")
    del world.series[q]
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    assert "Not installed" in c.get("/platform/agents/security").text
    assert "Every running practice reports healthy" in c.get("/platform").text


# ---------------------------------------------------------------- the schedule state model

def item(**kw):
    base = {"kind": "CronJob", "namespace": "ns", "name": "job", "schedule": "0 * * * *", "timezone": "UTC",
            "suspended": False, "active": False, "last_run": None, "last_success": None, "next_run": None,
            "last_failed": None, "practice": None}
    return dict(base, **kw)


@pytest.mark.parametrize("kw,expect", [
    ({}, "never"),
    ({"suspended": True}, "paused"),
    ({"active": True, "last_run": "prev"}, "running"),
    ({"active": True, "last_run": "prev-10800"}, "stuck"),    # 3h into an hourly job: longer than it allows
    ({"last_run": "prev", "last_success": "prev+30"}, "up"),
    ({"last_run": "prev", "last_success": "prev-3600"}, "failed"),
    ({"last_run": "prev", "last_success": "prev+30", "last_failed": True}, "failed"),
    ({"last_run": "prev-3600", "last_success": "prev-3570"}, "missed"),
    ({"last_run": "prev"}, "unknown"),                 # ran, outcome not visible (a CronWorkflow without a metric)
])
def test_schedule_states(kw, expect):
    now = Cron("0 * * * *").prev_before(NOW) + 1800  # half an hour after the last fire: past the grace
    prev = Cron("0 * * * *").prev_before(now)
    sub = {"prev": prev, "prev+30": prev + 30, "prev-3600": prev - 3600, "prev-3570": prev - 3570,
           "prev-10800": prev - 10800}
    kw = {k: sub.get(v, v) if isinstance(v, str) else v for k, v in kw.items()}
    assert pm.schedule_state(item(**kw), now)[0] == expect


def test_late_inside_grace_then_missed():
    prev = Cron("0 * * * *").prev_before(NOW)
    it = item(last_run=prev - 3600, last_success=prev - 3570)
    assert pm.schedule_state(it, prev + 120)[0] == "late"
    assert pm.schedule_state(it, prev + 1200)[0] == "missed"


def test_unowned_work_is_listed_and_owned_work_is_routed(world):
    healthy_signals(world)
    prev = Cron("0 3 * * *").prev_before(NOW)
    add_cronjob(world, "x", "nightly-backup", "0 3 * * *", last_run=prev, last_ok=prev + 60, nxt=prev + 86400)
    add_cronjob(world, "x", "mystery-thing", "0 3 * * *", last_run=prev, last_ok=prev + 60, nxt=prev + 86400)
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    o = c.get("/platform").text
    assert "Scheduled work with no owner" in o and "mystery-thing" in o
    assert "nightly-backup" in c.get("/platform/agents/continuity").text


def test_practice_label_beats_the_name_pattern(world):
    cat = pm.load_catalog()
    assert pm.owner_of(item(name="nightly-backup"), cat) == "continuity"
    assert pm.owner_of(item(name="nightly-backup", practice="security"), cat) == "security"
    assert pm.owner_of(item(name="nightly-backup", practice="no-such"), cat) == "continuity"


def test_cronworkflows_without_a_success_metric_read_unknown(world):
    healthy_signals(world)
    prev = Cron("30 3 * * *", "America/Chicago").prev_before(NOW)
    cw = [{"metadata": {"name": "capacity-drift", "namespace": "site-monitoring"},
           "spec": {"schedules": ["30 3 * * *"], "timezone": "America/Chicago"},
           "status": {"lastScheduledTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(prev))}}]
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=cw)
    login_as(c, s, ["tockmox-admins"])
    a = c.get("/platform/agents/capacity").text
    assert "capacity-drift" in a and "outcome is not visible here" in a


def test_cronworkflows_unreadable_makes_owning_practices_unknown(world):
    healthy_signals(world)
    c, app, s = client_for(world, doc_with_platform())     # kube answers 403 for cronworkflows
    login_as(c, s, ["tockmox-admins"])
    o = c.get("/platform").text
    assert "Not every practice can be confirmed healthy" in o
    assert "Scheduled workflows (Argo)" in o and "HTTP 403" in o
    # lab finding D2: the Unknown names its cause on the role's own row, not only in the sources list
    assert "Its scheduled work cannot be read (Scheduled workflows (Argo): HTTP 403)" in c.get("/platform/agents/continuity").text


# ---------------------------------------------------------------- the agent ledger

def test_ledger_waiting_and_failing(world):
    healthy_signals(world)
    jobs = [{"id": "j-1", "profile": "change", "status": "input_required", "created": NOW - 600, "cost_usd": 0.02,
             "answer": "SECRET MODEL PROSE"},
            {"id": "j-2", "profile": "incident", "status": "failed", "created": NOW - 60, "cost_usd": 0.10}]
    led = Ledger(jobs)
    c, app, s = client_for(world, doc_with_platform(ledgerUrl="http://ledger.test", interfaceUrl="https://ui.int.example.com"),
                           ledger=led, cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    o = c.get("/platform").text
    assert "Waiting on you" in o and "Failing" in o
    assert "https://ui.int.example.com/jobs/j-1" in o
    assert "SECRET MODEL PROSE" not in o                    # no model output in the admin origin
    a = c.get("/platform/agents/change").text
    assert "SECRET MODEL PROSE" not in a and "j-1" in a
    assert led.seen and led.seen[0].url.path == "/v1/jobs"


def test_ledger_down_is_unknown_not_quiet(world):
    healthy_signals(world)
    c, app, s = client_for(world, doc_with_platform(ledgerUrl="http://ledger.test"), ledger=Ledger(down=True), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    a = c.get("/platform/agents/incident").text
    assert "agent ledger: unreachable" in a.lower() or "Agent ledger: unreachable" in a


# ---------------------------------------------------------------- catalog and pages

def test_catalog_loads_and_refuses_nonsense(tmp_path):
    cat = pm.load_catalog()
    assert [t.lead.id for t in cat.teams] == ["platform-manager", "project-manager", "improvement-manager"]
    assert {a.id for a in cat.all()} >= {"incident", "change", "capacity", "continuity", "security", "scrum-master", "assets", "finance"}
    bad = tmp_path / "c.yaml"
    bad.write_text("version: 2\nteams: [{id: t, lead: {id: m, mode: act-wildly}}]\n")
    with pytest.raises(pm.CatalogError):
        pm.load_catalog(str(bad))
    bad.write_text("version: 2\nteams: [{id: t, lead: {id: m}, members: [{id: a, schedules: {planned: [{name: x, cron: 'L * * * *'}]}}]}]\n")
    with pytest.raises(ValueError):
        pm.load_catalog(str(bad))


def test_every_page_renders_with_the_shipped_catalog(world):
    healthy_signals(world)
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    for a in pm.load_catalog().all():
        r = c.get(f"/platform/agents/{a.id}")
        assert r.status_code == 200 and a.name in r.text
    assert c.get("/platform/agents/nobody").status_code == 404
    sch = c.get("/platform/schedule").text
    assert "daily-platform-report" in sch and "Planned" in sch
    assert "The next seven days" in sch


def test_rail_has_a_text_twin(world):
    healthy_signals(world)
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    t = c.get("/platform").text
    assert 'class="rail-grid" aria-hidden="true"' in t
    assert 'class="runlist"' in t and "daily-platform-report" in t


def test_no_inline_style_attributes(world):
    """CSP is style-src 'self': an inline style attribute would be blocked, silently."""
    healthy_signals(world)
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    for p in ("/platform", "/platform/schedule", "/platform/agents/capacity"):
        assert " style=" not in c.get(p).text


# ---------------------------------------------------------------- cron

def test_cron_basics():
    c = Cron("35 9 * * *", "America/Chicago")
    n = c.next_after(NOW)
    p = c.prev_before(NOW)
    assert p < NOW < n and 86400 - 3700 <= n - p <= 86400 + 3700
    assert describe("35 9 * * *") == "daily at 09:35"
    assert describe("*/15 * * * *") == "every 15 minutes"
    assert describe("0 9 * * 0") == "Sundays at 09:00"
    assert Cron("CRON_TZ=America/Chicago 30 3 * * *", "UTC").tz == ZoneInfo("America/Chicago")
    with pytest.raises(ValueError):
        Cron("0 9 * *")
    with pytest.raises(ValueError):
        Cron("0 9 L * *")


def test_cron_dom_dow_or_semantics():
    c = Cron("0 0 13 * 5")          # the 13th OR any Friday
    t = c.next_after(NOW)
    import datetime
    d = datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
    assert d.day == 13 or d.isoweekday() == 5


@pytest.mark.parametrize("key", ["ledgerUrl", "interfaceUrl"])
def test_platform_urls_must_be_absolute_http(key):
    doc = base_doc()
    doc["features"] = {"platform": {"enabled": True, key: "file:///etc/passwd"}}
    with pytest.raises(cfgmod.ConfigError, match=key):
        cfgmod.parse(doc)
    doc["features"]["platform"][key] = "http://orchestrator.example.svc:8080/"
    assert cfgmod.parse(doc).feature("platform").options[key] == "http://orchestrator.example.svc:8080"


def test_a_broken_site_catalog_does_not_take_the_ui_down(world, tmp_path):
    bad = tmp_path / "catalog.yaml"
    bad.write_text("version: 1\nteams: []\n")
    c, app, s = client_for(world, doc_with_platform(catalogFile=str(bad)))
    login_as(c, s, ["tockmox-users"])
    assert c.get("/platform").status_code == 403
    login_as(c, s, ["tockmox-admins"])
    assert c.get("/").status_code == 200                               # the rest of the UI is up
    r = c.get("/platform")
    assert r.status_code == 503 and "did not load" in r.text and "catalog version must be 2" in r.text
    assert c.get("/platform/agents/incident").status_code == 503



# ---------------------------------------------------------------- review findings (2026-10-23)

def test_cron_follows_robfig_day_semantics_and_refuses_empty_items():
    import datetime as dt
    c = Cron("0 0 */2 * 1")                      # starred day-of-month: AND, so only Mondays on odd days
    t = dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc).timestamp()
    days = []
    for _ in range(3):
        t = c.next_after(t)
        days.append(dt.datetime.fromtimestamp(t, dt.timezone.utc).day)
    assert days == [5, 19, 9]
    c = Cron("0 0 1,15 * 1")                     # both restricted: OR
    t = c.next_after(dt.datetime(2026, 10, 1, 1, tzinfo=dt.timezone.utc).timestamp())
    assert dt.datetime.fromtimestamp(t, dt.timezone.utc).day == 5
    for bad in ("5, * * * *", ",5 * * * *"):
        with pytest.raises(ValueError):
            Cron(bad)


def test_several_schedules_are_all_evaluated():
    now = Cron("30 * * * *").prev_before(NOW) + 1200    # 20 minutes after a :30 fire, past its grace
    it = item(schedule="0 * * * *", schedules=["0 * * * *", "30 * * * *"], last_run=now - 1200 - 1800,
              last_success=now - 1200 - 1800 + 30)
    st, why, exp, nxt = pm.schedule_state(it, now)
    assert st == "missed" and exp == Cron("30 * * * *").prev_before(now)
    assert nxt == min(Cron("0 * * * *").next_after(now), Cron("30 * * * *").next_after(now))


def test_never_run_and_paused_jobs_keep_a_practice_from_reading_healthy(world):
    healthy_signals(world)
    add_cronjob(world, "backups", "nightly-backup", schedule="0 2 * * *")              # never ran
    add_cronjob(world, "restore-drill", "restore-drill-db", suspended=1, last_run=NOW - 90 * 86400,
                last_ok=NOW - 90 * 86400)
    c, app, s = client_for(world, doc_with_platform(), cronworkflows=[])
    login_as(c, s, ["tockmox-admins"])
    h = c.get("/platform/agents/continuity").text
    assert "every signal and scheduled job is healthy" not in h.lower()
    low = h.lower()
    assert "nightly-backup (never run)" in low and "restore-drill-db (paused)" in low
    assert "Every running practice reports healthy" not in c.get("/platform").text


def test_a_job_whose_pods_failed_once_then_succeeded_is_not_a_failed_run(world):
    healthy_signals(world)
    last = Cron("0 * * * *").prev_before(NOW) + 5
    add_cronjob(world, "ns", "hourly-backup", last_run=last, last_ok=last + 60)
    jl = {"namespace": "ns", "job_name": "hourly-backup-1"}
    world.series.setdefault('kube_job_owner{owner_kind="CronJob"}', []).append((dict(jl, owner_name="hourly-backup"), 1))
    world.series.setdefault("kube_job_status_start_time", []).append((jl, last))
    world.series.setdefault("kube_job_status_failed", []).append((jl, 1))       # one retry
    world.series.setdefault("kube_job_status_succeeded", []).append((jl, 1))    # then it worked
    src = pm.CronJobsSource("http://prom", 5, httpx.MockTransport(world.handler("prometheus")))
    rows = {r["name"]: r for r in src.fetch()}
    assert rows["hourly-backup"]["last_failed"] is False


@pytest.mark.parametrize("raw", [float("nan")])
def test_nan_reads_unknown_never_ok(raw):
    sig = pm.Signal("x", "X", "q", unit="ratio", good="above", warn=.8, crit=.9)
    assert pm.signal_state(sig, raw)[0] == "unknown"
    assert pm.signal_state(pm.Signal("x", "X", "q", warn=.8, crit=.9), raw)[0] == "unknown"


def test_an_optional_signal_that_stops_answering_is_unknown_not_absent():
    sig = pm.Signal("cert", "Cert", "q", optional=True, presence="p")
    assert pm.signal_state(sig, None, seen=False)[0] == "absent"
    assert pm.signal_state(sig, None, seen=True)[0] == "unknown"


def test_no_shipped_health_query_turns_a_missing_metric_into_zero():
    for a in pm.load_catalog().all():
        for s in a.signals:
            assert "or on() vector(0)" not in s.query, (a.id, s.id)


def test_ledger_down_never_says_nothing_is_waiting(world):
    healthy_signals(world)
    c, app, s = client_for(world, doc_with_platform(ledgerUrl="http://orch.test:8080"), ledger=Ledger(down=True))
    login_as(c, s, ["tockmox-admins"])
    h = c.get("/platform").text
    assert "Nothing is waiting on you" not in h and "did not answer" in h


def test_ledger_answer_of_the_wrong_shape_is_unknown(world):
    healthy_signals(world)
    led = Ledger()
    led.handler = lambda req: httpx.Response(200, json={"jobs": {"detail": "nope"}})
    c, app, s = client_for(world, doc_with_platform(ledgerUrl="http://orch.test:8080"), ledger=led)
    login_as(c, s, ["tockmox-admins"])
    h = c.get("/platform").text
    assert "Nothing is waiting on you" not in h and "did not answer" in h


def test_ledger_odd_statuses_bad_costs_and_stray_profiles(world):
    healthy_signals(world)
    now = time.time()
    jobs = [{"id": "a1", "profile": "incident", "status": "cancelled", "created": now - 60, "cost_usd": "n/a"},
            {"id": "b/../x?y", "profile": "orchestrator", "status": "input_required", "created": now - 30}]
    c, app, s = client_for(world, doc_with_platform(ledgerUrl="http://orch.test:8080", interfaceUrl="https://chat.test"),
                           ledger=Ledger(jobs))
    login_as(c, s, ["tockmox-admins"])
    r = c.get("/platform")
    assert r.status_code == 200
    assert "orchestrator" in r.text and "no role in this catalog" in r.text           # not dropped
    assert "/jobs/b%2F..%2Fx%3Fy" in r.text                                            # url-encoded
    a = c.get("/platform/agents/incident").text
    assert "Healthy" not in a.split("Agent")[1][:400] if "Agent" in a else True
    views, _ = pm.build(pm.load_catalog(), {k: v.read() for k, v in app.state.platform["sources"].items()},
                        ledger_configured=True)
    inc = next(v for v in views if v.agent.id == "incident")
    assert inc.agent_state == "unknown" and "cancelled" in inc.agent_reason and inc.cost == 0


@pytest.mark.parametrize("body", [
    "version: 2\nteams:\n  - id: run\n    lead: {id: lead, signals: [{id: s, label: S}]}\n",            # no query
    "version: 2\nteams:\n  - id: run\n    lead: {id: lead, schedules: {planned: [{name: p, cron: '61 * * * *'}]}}\n",
    "version: 2\nteams:\n  - id: run\n    lead: {id: lead, schedules: {planned: [{name: p, cron: ''}]}}\n",
    "- just\n- a list\n",
    "version: 2\nteams:\n  - id: run\n    lead: {id: lead, signals: [{id: s, label: S, query: up, warn: high}]}\n",
])
def test_any_catalog_mistake_is_the_pages_503_not_a_crash(world, tmp_path, body):
    bad = tmp_path / "catalog.yaml"
    bad.write_text(body)
    c, app, s = client_for(world, doc_with_platform(catalogFile=str(bad)))
    login_as(c, s, ["tockmox-admins"])
    assert c.get("/").status_code == 200
    r = c.get("/platform")
    assert r.status_code == 503 and "did not load" in r.text


def test_an_unknown_timezone_is_the_pages_503_not_every_requests_500(world):
    c, app, s = client_for(world, doc_with_platform(timezone="Chicago"))
    login_as(c, s, ["tockmox-admins"])
    assert c.get("/").status_code == 200
    r = c.get("/platform")
    assert r.status_code == 503 and "time zone" in r.text


def test_a_cronjob_without_a_time_zone_uses_the_cluster_zone_not_unknown(world):
    healthy_signals(world)
    add_cronjob(world, "ns", "local-job", schedule="0 3 * * *", tz="local", last_run=NOW - 3600, last_ok=NOW - 3500)
    src = pm.CronJobsSource("http://prom", 5, httpx.MockTransport(world.handler("prometheus")), cluster_tz="America/Chicago")
    row = {r["name"]: r for r in src.fetch()}["local-job"]
    assert row["timezone"] == "America/Chicago"
    assert pm.schedule_state(row, NOW)[0] != "unknown"
    src = pm.CronJobsSource("http://prom", 5, httpx.MockTransport(world.handler("prometheus")))
    assert {r["name"]: r for r in src.fetch()}["local-job"]["timezone"] == "UTC"

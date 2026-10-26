# SPDX-License-Identifier: Apache-2.0
"""Platform Management: the operations team as a read-only view (DESIGN-2026-10-23-platform-management.md).

What this module shows, and from where:

  the team        the catalog (platform_catalog.yaml, or features.platform.catalogFile): DATA, no code
  scheduled work  CronJobs through kube-state-metrics in Prometheus (no new Kubernetes permission),
                  Argo CronWorkflows through the Kubernetes API (one new read: cronworkflows, list)
  practice health each manager's signals: PromQL instant queries with thresholds
  agent runs      the agent ledger (features.platform.ledgerUrl, GET /v1/jobs); unset, every agent
                  reads "Not connected", which is Unknown and never healthy
  cases           the Service Desk on the specialist host (features.platform.specialistsUrl, caller
                  client/tockmox-ui, reads only): what the operations agents worked on and what waits on
                  whom (platform_cases.py)
  specialists     each role's specialists (the agents that do its work) from the catalog's generated
                  specialists field, and what the host serves from its /v1/index
  needs you       the ledger's jobs waiting on a person; approving happens in the conversation
                  surface (features.platform.interfaceUrl), never here

The rules it keeps, from the UI design:
  - It writes nothing and renders no model output. A run's answer lives in the conversation surface;
    this page shows its status, cost and a link.
  - Absence is not green. A schedule that never ran, a signal that did not answer, an agent with no
    ledger, work this page cannot observe: each reads Unknown (or Planned), with the reason.
  - Two facts per manager, never merged: how its PRACTICE is doing (signals and schedules, live today)
    and how its AGENT is doing (the ledger). An agent that is only planned cannot make a practice look
    healthy or broken.
"""
from __future__ import annotations

import logging
import math
import os
import re
import time
from dataclasses import dataclass, field
from typing import Any

import httpx
import yaml
from fastapi import Request
from zoneinfo import ZoneInfo

from . import platform_cases
from .cronexpr import Cron, describe
from .sources import CRIT, OK, UNKNOWN, WARN, KubeClient, Reading, Source, _parse_ts, worst

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CATALOG = os.path.join(HERE, "platform_catalog.yaml")
log = logging.getLogger("tockmox_ui.platform")

MODES = {
    "observe": ("Observe", "Reads and reports. Changes nothing."),
    "propose": ("Propose", "Drafts changes as a pull request or a card. A person approves them in the conversation."),
    "act": ("Act", "May run named, reversible actions on its own."),
}
PRACTICE_LABEL = "tockmox.com/practice"
SPECIALIST_STATES = ("built", "specced", "proposed")
SPECIALIST_WORDS = {"built": "Built", "specced": "Specified, not built", "proposed": "Proposed"}

# Schedule states, after the cron-monitor model (Healthchecks.io): last SUCCESS is a different fact
# from last RUN, a missed run is its own failure class, and nothing is healthy before it has run.
SCHED_WORDS = {
    "up": ("On schedule", OK), "running": ("Running", OK), "late": ("Late", WARN),
    "stuck": ("Running too long", WARN),
    "failed": ("Last run failed", CRIT), "missed": ("Missed its run", CRIT),
    "paused": ("Paused", UNKNOWN), "never": ("Never run", UNKNOWN), "unknown": ("Unknown", UNKNOWN),
    "planned": ("Planned", UNKNOWN), "external": ("Not observable here", UNKNOWN),
}


class CatalogError(ValueError):
    pass


# ---------------------------------------------------------------- catalog

@dataclass(frozen=True)
class Signal:
    id: str
    label: str
    query: str
    unit: str = "count"
    good: str = "below"
    warn: float | None = None
    crit: float | None = None
    informational: bool = False
    optional: bool = False
    presence: str = ""     # optional signals: PromQL that answers while the component is installed


@dataclass(frozen=True)
class Agent:
    id: str
    name: str
    mission: str
    mode: str
    reference: dict
    may_read: tuple = ()
    may_propose: tuple = ()
    never: tuple = ()
    data_class: str = "internal"
    grafana: str = ""
    match: tuple = ()
    planned: tuple = ()
    external: tuple = ()
    signals: tuple = ()
    is_lead: bool = False
    team: str = ""
    lead: str = ""          # the id of the lead this role reports to ("" for a lead)
    agent_role: str = ""    # its id in the specialists' roles file, which the Service Desk uses (generated)
    specialists: tuple = () # ({id, state}, ...): the agents that do its work, built | specced | proposed (generated)

    @property
    def is_manager(self):   # kept for templates: a team lead
        return self.is_lead

    @property
    def mode_word(self):
        return MODES[self.mode][0]

    @property
    def mode_text(self):
        return MODES[self.mode][1]


@dataclass(frozen=True)
class Team:
    id: str
    name: str
    purpose: str
    lead: Agent
    members: tuple


@dataclass(frozen=True)
class Catalog:
    teams: tuple
    specialists_source: dict = field(default_factory=dict)   # {file, sha256} the specialists field came from

    def all(self):
        out = []
        for t in self.teams:
            out.append(t.lead)
            out.extend(t.members)
        return tuple(out)

    def get(self, aid):
        return next((a for a in self.all() if a.id == aid), None)

    def team(self, tid):
        return next((t for t in self.teams if t.id == tid), None)


_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


def _agent(raw: dict, is_lead=False, team="", lead="") -> Agent:
    aid = str(raw.get("id", ""))
    if not _ID.match(aid):
        raise CatalogError(f"agent id {aid!r} must match {_ID.pattern}")
    mode = str(raw.get("mode", "observe"))
    if mode not in MODES:
        raise CatalogError(f"{aid}: mode must be one of {', '.join(MODES)}")
    sch = raw.get("schedules") or {}
    pats = []
    for p in sch.get("match") or []:
        try:
            pats.append(re.compile(str(p)))
        except re.error as e:
            raise CatalogError(f"{aid}: schedule pattern {p!r}: {e}") from None
    planned = []
    for p in sch.get("planned") or []:
        cron = str(p.get("cron", ""))
        if cron != "event":
            Cron(cron)   # refuse an expression the page could not evaluate
        planned.append({"name": str(p["name"]), "cron": cron, "what": str(p.get("what", ""))})
    external = [{"name": str(p["name"]), "cron": str(p.get("cron", "")), "where": str(p.get("where", "")),
                 "what": str(p.get("what", ""))} for p in sch.get("external") or []]
    sigs = []
    for s in raw.get("signals") or []:
        if not isinstance(s, dict):
            raise CatalogError(f"{aid}: each signal must be a mapping")
        for k in ("id", "label", "query"):
            if not str(s.get(k) or "").strip():
                raise CatalogError(f"{aid}: a signal needs {k}")
        if s.get("good", "below") not in ("below", "above"):
            raise CatalogError(f"{aid}.{s.get('id')}: good must be below or above")
        lim = {}
        for k in ("warn", "crit"):
            v = s.get(k)
            if v is not None and (isinstance(v, bool) or not isinstance(v, (int, float))):
                raise CatalogError(f"{aid}.{s['id']}: {k} must be a number")
            lim[k] = None if v is None else float(v)
        sigs.append(Signal(id=str(s["id"]), label=str(s["label"]), query=str(s["query"]),
                           unit=str(s.get("unit", "count")), good=str(s.get("good", "below")),
                           warn=lim["warn"], crit=lim["crit"],
                           informational=bool(s.get("informational", False)),
                           optional=bool(s.get("optional", False)), presence=str(s.get("presence") or "")))
    specs = []
    for sp in raw.get("specialists") or []:
        sid, st = str((sp or {}).get("id", "")) if isinstance(sp, dict) else "", (sp or {}).get("state") if isinstance(sp, dict) else None
        if not re.fullmatch(r"[a-z][a-z0-9-]{1,47}", sid) or st not in SPECIALIST_STATES:
            raise CatalogError(f"{aid}: each specialist needs an id and a state in {', '.join(SPECIALIST_STATES)}")
        specs.append({"id": sid, "state": st})
    agent_role = str(raw.get("agentRole") or "")
    if agent_role and not re.fullmatch(r"[a-z][a-z0-9-]{1,47}", agent_role):
        raise CatalogError(f"{aid}: agentRole {agent_role!r} is not a role id")
    return Agent(id=aid, name=str(raw.get("name", aid)), mission=" ".join(str(raw.get("mission", "")).split()),
                 mode=mode, reference=dict(raw.get("reference") or {}),
                 may_read=tuple(raw.get("mayRead") or ()), may_propose=tuple(raw.get("mayPropose") or ()),
                 never=tuple(raw.get("never") or ()), data_class=str(raw.get("dataClass", "internal")),
                 grafana=str(raw.get("grafana", "")), match=tuple(pats), planned=tuple(planned),
                 external=tuple(external), signals=tuple(sigs), is_lead=is_lead, team=team, lead=lead,
                 agent_role=agent_role, specialists=tuple(specs))


def load_catalog(path: str | None = None) -> Catalog:
    """The catalog, or CatalogError naming what is wrong: any mistake in a site's file (a missing key, a
    cron the page cannot evaluate, a value of the wrong type) is a CatalogError, never a crash."""
    try:
        return _load_catalog(path)
    except CatalogError:
        raise
    except Exception as e:  # noqa: BLE001 - reported to the admin on /platform, the UI stays up
        raise CatalogError(f"{type(e).__name__}: {e}") from None


def _load_catalog(path: str | None = None) -> Catalog:
    with open(path or DEFAULT_CATALOG, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    if not isinstance(doc, dict):
        raise CatalogError("the catalog must be a mapping with version and teams")
    if doc.get("version") != 2:
        raise CatalogError("catalog version must be 2")
    teams = []
    for t in doc.get("teams") or []:
        tid = str(t.get("id", ""))
        if not _ID.match(tid):
            raise CatalogError(f"team id {tid!r} must match {_ID.pattern}")
        if not t.get("lead"):
            raise CatalogError(f"team {tid}: a team needs a lead")
        lead = _agent(t["lead"], is_lead=True, team=tid)
        members = tuple(_agent(m, team=tid, lead=lead.id) for m in t.get("members") or [])
        teams.append(Team(tid, str(t.get("name", tid)), " ".join(str(t.get("purpose", "")).split()), lead, members))
    if not teams:
        raise CatalogError("the catalog needs at least one team")
    src = doc.get("specialistsSource") or {}
    if not isinstance(src, dict):
        raise CatalogError("specialistsSource must be a mapping with file and sha256")
    cat = Catalog(tuple(teams), {k: str(v) for k, v in src.items() if k in ("file", "sha256")})
    ids = [a.id for a in cat.all()]
    if len(ids) != len(set(ids)):
        raise CatalogError("role ids must be unique")
    if len({t.id for t in teams}) != len(teams):
        raise CatalogError("team ids must be unique")
    return cat


# ---------------------------------------------------------------- reading the scheduled work

def _prom_vector(client: httpx.Client, query: str) -> list:
    r = client.get("/api/v1/query", params={"query": query})
    r.raise_for_status()
    doc = r.json()
    if doc.get("status") != "success":
        raise ValueError("query failed")
    return doc["data"]["result"]


class CronJobsSource(Source):
    """Every CronJob, through kube-state-metrics. Needs nothing beyond the Prometheus read the UI
    already has. Last run outcome = the newest Job the CronJob owns."""
    name = "Scheduled jobs (kube-state-metrics)"

    def __init__(self, url, timeout, transport=None, ttl=30.0, cluster_tz="UTC"):
        super().__init__(ttl)
        self.url, self.timeout, self.transport = url, timeout, transport
        # A CronJob without spec.timeZone runs in the controller manager's own zone; kube-state-metrics
        # labels it timezone="local" (older versions leave the label out). That zone is the site's to state.
        self.cluster_tz = cluster_tz or "UTC"

    def configured(self):
        return bool(self.url)

    def fetch(self):
        with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport) as c:
            info = _prom_vector(c, "kube_cronjob_info")
            if not info:
                # No CronJobs and no kube-state-metrics look the same from here. Only a live
                # kube-state-metrics turns the empty answer into "there are none".
                if not _prom_vector(c, 'up{job=~".*kube-state-metrics.*"} == 1'):
                    raise ValueError("kube-state-metrics is not answering, so CronJobs cannot be listed")
                return []

            def by_cj(q):
                return {(m["metric"].get("namespace"), m["metric"].get("cronjob")): float(m["value"][1])
                        for m in _prom_vector(c, q)}
            last_sched = by_cj("kube_cronjob_status_last_schedule_time")
            last_ok = by_cj("kube_cronjob_status_last_successful_time")
            nxt = by_cj("kube_cronjob_next_schedule_time")
            susp = by_cj("kube_cronjob_spec_suspend")
            active = by_cj("kube_cronjob_status_active")
            owners = {(m["metric"].get("namespace"), m["metric"].get("job_name")): m["metric"].get("owner_name")
                      for m in _prom_vector(c, 'kube_job_owner{owner_kind="CronJob"}')}
            starts = {(m["metric"].get("namespace"), m["metric"].get("job_name")): float(m["value"][1])
                      for m in _prom_vector(c, "kube_job_status_start_time")}
            def by_job(q):
                return {(m["metric"].get("namespace"), m["metric"].get("job_name")): float(m["value"][1])
                        for m in _prom_vector(c, q)}
            # A Job's status.failed counts failed PODS, retries included, so a Job that failed once and
            # then succeeded is not a failed run. Failed = no success, and either the Failed condition or
            # failed pods with nothing still active.
            pods_failed = by_job("kube_job_status_failed")
            succeeded = by_job("kube_job_status_succeeded")
            job_active = by_job("kube_job_status_active")
            cond_failed = by_job('kube_job_failed{condition="true"}')
            failed = {k: (succeeded.get(k, 0) == 0 and (cond_failed.get(k, 0) > 0
                                                         or (pods_failed.get(k, 0) > 0 and job_active.get(k, 0) == 0)))
                      for k in set(pods_failed) | set(cond_failed)}
        newest: dict = {}
        for (ns, job), owner in owners.items():
            st = starts.get((ns, job))
            if st is None:
                continue
            k = (ns, owner)
            if k not in newest or st > newest[k][0]:
                newest[k] = (st, bool(failed.get((ns, job), False)))
        out = []
        for m in info:
            lab = m["metric"]
            k = (lab.get("namespace"), lab.get("cronjob"))
            nw = newest.get(k)
            out.append({"kind": "CronJob", "namespace": k[0], "name": k[1], "schedule": lab.get("schedule", ""),
                        "timezone": (lab.get("timezone") if lab.get("timezone") not in (None, "", "local") else self.cluster_tz),
                        "suspended": susp.get(k, 0) > 0,
                        "active": active.get(k, 0) > 0, "last_run": last_sched.get(k),
                        "last_success": last_ok.get(k), "next_run": nxt.get(k),
                        "last_failed": (nw[1] if nw else None), "practice": None})
        return out


class CronWorkflowsSource(Source):
    """Argo CronWorkflows through the Kubernetes API (list cronworkflows, cluster-wide). Argo's
    status says when it last scheduled a run, not how the run ended; the outcome comes from an
    optional success metric (features.platform.workflowSuccessQuery), else it reads Unknown."""
    name = "Scheduled workflows (Argo)"

    def __init__(self, kube: KubeClient, prom_url, timeout, success_query="", transport=None, ttl=30.0):
        super().__init__(ttl)
        self.kube, self.prom_url, self.timeout = kube, prom_url, timeout
        self.success_query, self.transport = success_query, transport

    def fetch(self):
        doc = self.kube.get("/apis/argoproj.io/v1alpha1/cronworkflows")
        ok_by_name = {}
        if self.success_query and self.prom_url:
            try:
                with httpx.Client(base_url=self.prom_url, timeout=self.timeout, transport=self.transport) as c:
                    for m in _prom_vector(c, self.success_query):
                        nm = m["metric"].get("cronworkflow") or m["metric"].get("name")
                        if nm:
                            ok_by_name[(m["metric"].get("namespace"), nm)] = float(m["value"][1])
            except Exception:  # noqa: BLE001 - outcomes stay Unknown; the schedule list still shows
                ok_by_name = {}
        out = []
        for it in doc.get("items", []):
            md, sp, st = it.get("metadata", {}), it.get("spec", {}), it.get("status", {})
            scheds = sp.get("schedules") or ([sp["schedule"]] if sp.get("schedule") else [])
            k = (md.get("namespace"), md.get("name"))
            out.append({"kind": "CronWorkflow", "namespace": k[0], "name": k[1],
                        "schedule": scheds[0] if scheds else "", "schedules": list(scheds),
                        "timezone": sp.get("timezone") or "UTC",
                        "suspended": bool(sp.get("suspend")), "active": bool(st.get("active")),
                        "last_run": _parse_ts(st.get("lastScheduledTime")),
                        "last_success": ok_by_name.get(k), "next_run": None, "last_failed": None,
                        "practice": (md.get("labels") or {}).get(PRACTICE_LABEL)})
        return out

    def evaluate(self, items):
        return OK, f"{len(items)} found"


class SignalsSource(Source):
    """Every signal in the catalog, one instant query each, cached together."""
    name = "Practice signals (Prometheus)"

    def __init__(self, url, timeout, catalog: Catalog, transport=None, ttl=30.0):
        super().__init__(ttl)
        self.url, self.timeout, self.catalog, self.transport = url, timeout, catalog, transport

    def configured(self):
        return bool(self.url)

    def fetch(self):
        out = {}
        with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport) as c:
            for a in self.catalog.all():
                for s in a.signals:
                    try:
                        res = _prom_vector(c, s.query)
                        v = float(res[0]["value"][1]) if res else None
                        if v is not None and math.isnan(v):
                            v = None        # 0/0 and friends: no answer, never a healthy number
                        seen = None
                        if v is None and s.optional and s.presence:
                            seen = bool(_prom_vector(c, s.presence))
                        out[(a.id, s.id)] = {"value": v, "error": "", "seen": seen}
                    except httpx.TransportError:
                        raise   # Prometheus itself is gone: the whole source is Unknown
                    except Exception as e:  # noqa: BLE001 - one bad query is that signal's Unknown, not the page's
                        out[(a.id, s.id)] = {"value": None, "error": type(e).__name__}
        return out


class LedgerSource(Source):
    """The agent ledger's read API: GET <ledgerUrl>/v1/jobs. Jobs carry profile, status (MCP tasks
    vocabulary: queued, working, input_required, completed, failed, cancelled), created, updated,
    cost_usd and an id. Nothing else is read; a job's brief and answer never enter this page."""
    name = "Agent ledger"
    FIELDS = ("id", "profile", "status", "created", "updated", "cost_usd", "summary_ref")
    LIMIT = 200

    def __init__(self, url, timeout, token_file="", transport=None, ttl=15.0):
        super().__init__(ttl)
        self.url, self.timeout, self.token_file, self.transport = url, timeout, token_file, transport

    def configured(self):
        return bool(self.url)

    def fetch(self):
        headers = {}
        if self.token_file and os.path.exists(self.token_file):
            with open(self.token_file, encoding="utf-8") as fh:
                headers["Authorization"] = "Bearer " + fh.read().strip()
        with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport, headers=headers) as c:
            r = c.get("/v1/jobs", params={"limit": self.LIMIT})
            r.raise_for_status()
            doc = r.json()
        jobs = doc.get("jobs") if isinstance(doc, dict) else doc
        if not isinstance(jobs, list):
            raise ValueError("the ledger answered without a list of jobs")
        return [{k: j.get(k) for k in self.FIELDS} for j in jobs if isinstance(j, dict)]

    def evaluate(self, jobs):
        if len(jobs) >= self.LIMIT:
            return WARN, f"answered its newest {self.LIMIT} jobs only; an older item waiting on you may not show"
        return OK, f"{len(jobs)} jobs"


# ---------------------------------------------------------------- evaluation

def _usd(v) -> float:
    try:
        f = float(v or 0)
    except (TypeError, ValueError):
        return 0.0
    return 0.0 if math.isnan(f) else f


def owner_of(item: dict, cat: Catalog) -> str | None:
    if item.get("practice") and cat.get(item["practice"]):
        return item["practice"]
    for a in cat.all():
        if any(p.fullmatch(item["name"]) for p in a.match):
            return a.id
    return None


def schedule_state(item: dict, now: float) -> tuple[str, str, float | None, float | None]:
    """(state, why, expected_last, next). Expected_last is the fire time a run should exist for."""
    exprs = item.get("schedules") or [item["schedule"]]
    try:
        crons = [Cron(e, item.get("timezone") or "UTC") for e in exprs]
    except Exception as e:  # noqa: BLE001
        return "unknown", f"cannot read schedule {item['schedule']!r} ({e})", None, None
    # Several schedules (an Argo CronWorkflow's spec.schedules): the run due is the latest one any of
    # them called for, the next is the soonest, and the cadence is the tightest.
    nexts = [n for n in (c.next_after(now) for c in crons) if n]
    nxt = item.get("next_run")
    if not nxt or nxt < now - 60:      # kube-state-metrics can trail a fire by a scrape; never show a past "next"
        nxt = min(nexts) if nexts else None
    prevs = [p for p in (c.prev_before(now) for c in crons) if p]
    expected = max(prevs) if prevs else None
    hints = [h for h in (c.interval_hint(now) for c in crons) if h]
    interval = min(hints) if hints else 86400
    grace = min(max(interval * 0.1, 600), 7200)
    last_run, last_ok = item.get("last_run"), item.get("last_success")
    if item.get("suspended"):
        return "paused", "suspended in its manifest", expected, None
    if item.get("active"):
        # A run that outlives its own cadence is not "running fine": with concurrencyPolicy Forbid it
        # silently blocks every later run.
        limit = max(2 * interval, 3600)
        if last_run and now - last_run > limit:
            return "stuck", f"a run has been going for {_dur(now - last_run)}, longer than its schedule allows", expected, nxt
        return "running", "a run is in progress", expected, nxt
    if last_run is None and last_ok is None:
        return "never", "no run recorded yet", expected, nxt
    if expected is not None and (last_run or 0) < expected - 60:
        if now - expected < grace:
            return "late", "due and not started yet (inside the grace period)", expected, nxt
        return "missed", "the last scheduled run did not happen", expected, nxt
    if item.get("last_failed"):
        return "failed", "the newest run failed", expected, nxt
    if last_ok is None:
        return "unknown", "it ran, but its outcome is not visible here", expected, nxt
    if last_run and last_ok + 60 < last_run:
        return "failed", "the newest run did not succeed", expected, nxt
    return "up", "the last scheduled run succeeded", expected, nxt


def _dur(sec: float) -> str:
    h = sec / 3600
    return f"{h:.0f}h" if h < 48 else f"{h / 24:.0f} days"


def signal_state(sig: Signal, value: float | None, error: str = "", seen: bool | None = None) -> tuple[str, str]:
    if value is not None and math.isnan(value):
        value = None
    if value is None:
        if sig.optional and not seen:
            return "absent", ("no data: not installed" if sig.presence else
                              "no data: not installed, or nothing has used it yet")
        if sig.optional and seen:
            return UNKNOWN, "no answer, though the component is installed"
        return UNKNOWN, f"no answer{(' (' + error + ')') if error else ''}"
    if sig.informational:
        return "info", ""
    above = sig.good == "above"
    def breach(t):
        return t is not None and (value < t if above else value > t)
    if breach(sig.crit):
        return CRIT, ""
    if breach(sig.warn):
        return WARN, ""
    return OK, ""


def fmt_value(sig: Signal, v: float | None) -> str:
    if v is None:
        return "no data"
    if sig.unit == "ratio":
        return f"{v * 100:.0f}%"
    if sig.unit == "usd":
        return f"${v:,.2f}"
    if sig.unit == "days":
        return f"{v:.1f} days"
    if sig.unit == "bool":
        return "present" if v > 0 else "absent"
    return f"{v:,.0f}" if float(v).is_integer() else f"{v:,.2f}"


def fmt_threshold(sig: Signal) -> str:
    def f(t):
        return fmt_value(Signal("", "", "", unit=sig.unit), t) if sig.unit != "bool" else ""
    if sig.informational:
        return "no threshold"
    word = "under" if sig.good == "below" else "over"
    if sig.unit == "bool":
        return "must be present"
    parts = []
    if sig.warn is not None:
        parts.append(f"needs a look {('above' if sig.good == 'below' else 'below')} {f(sig.warn)}")
    if sig.crit is not None:
        parts.append(f"problem {('above' if sig.good == 'below' else 'below')} {f(sig.crit)}")
    return "; ".join(parts) if parts else f"healthy {word} any value"


@dataclass
class AgentView:
    agent: Agent
    practice_state: str = UNKNOWN
    practice_reason: str = ""
    agent_state: str = UNKNOWN
    agent_word: str = "Not connected"
    agent_reason: str = ""
    signals: list = field(default_factory=list)
    schedules: list = field(default_factory=list)
    runs: list = field(default_factory=list)
    waiting: list = field(default_factory=list)
    last_run: float | None = None
    last_success: float | None = None
    next_run: float | None = None
    cost: float | None = None


def build(cat: Catalog, readings: dict, now: float | None = None, ledger_configured: bool = False, tz: str = "UTC"):
    """Assemble one AgentView per manager plus the unowned scheduled work."""
    now = now or time.time()
    views = {a.id: AgentView(a) for a in cat.all()}
    sched_readings = [readings["cronjobs"], readings["cronworkflows"]]
    items = []
    for r in sched_readings:
        if r.fetched_at is not None and r.data:
            items.extend(r.data)
    unowned = []
    for it in items:
        st, why, exp, nxt = schedule_state(it, now)
        row = dict(it, state=st, why=why, expected=exp, next=nxt,
                   cadence="; ".join(describe(e) for e in (it.get("schedules") or [it["schedule"]])),
                   owner=owner_of(it, cat), source="cluster")
        (views[row["owner"]].schedules if row["owner"] else unowned).append(row)
    for a in cat.all():
        v = views[a.id]
        for p in a.planned:
            nxt = None if p["cron"] == "event" else Cron(p["cron"], tz).next_after(now)
            v.schedules.append({"name": p["name"], "kind": "Agent task", "timezone": tz, "state": "planned", "why": p["what"],
                                "cadence": "on an event" if p["cron"] == "event" else describe(p["cron"]),
                                "schedule": p["cron"], "next": None, "planned_next": nxt, "source": "planned",
                                "namespace": "", "last_run": None, "last_success": None})
        for p in a.external:
            v.schedules.append({"name": p["name"], "kind": "External task", "timezone": tz, "state": "external",
                                "why": f"runs in {p['where'] or 'another tool'}: {p['what']}",
                                "cadence": describe(p["cron"]) if p["cron"] else "", "schedule": p["cron"],
                                "next": None, "source": "external", "namespace": "",
                                "last_run": None, "last_success": None})
    # signals
    sig_r = readings["signals"]
    for a in cat.all():
        v = views[a.id]
        for s in a.signals:
            got = (sig_r.data or {}).get((a.id, s.id)) if sig_r.fetched_at is not None else None
            val = got["value"] if got else None
            st, why = signal_state(s, val, got["error"] if got else "", got.get("seen") if got else None)
            if got is None:
                st, why = UNKNOWN, f"{sig_r.source}: {sig_r.reason or 'no answer'}"
            v.signals.append({"sig": s, "value": val, "text": fmt_value(s, val), "state": st, "why": why,
                              "threshold": fmt_threshold(s)})
    # practice state: signals that count, plus cluster-observed schedules
    sched_known = all(r.fetched_at is not None for r in sched_readings)
    for a in cat.all():
        v = views[a.id]
        counted = [x["state"] for x in v.signals if x["state"] in (OK, WARN, CRIT, UNKNOWN)]
        live = [x for x in v.schedules if x["source"] == "cluster"]
        # every deployed job counts: one never run or paused cannot be confirmed healthy (Unknown)
        counted += [SCHED_WORDS[x["state"]][1] for x in live]
        sched_gap = ""
        if not sched_known and a.match:
            counted.append(UNKNOWN)
            down = [r for r in sched_readings if r.fetched_at is None]
            sched_gap = "its scheduled work cannot be read (" + "; ".join(f"{r.source}: {r.reason or 'no answer'}" for r in down) + ")"
        if a.is_lead and not a.signals and not live:
            continue        # a lead with nothing of its own is judged by its team, below
        if not counted:
            # Nothing live to judge: every signal is informational or absent and no scheduled job of
            # its is deployed. That is a practice not started, not a practice failing or healthy, and
            # it stays out of every verdict so one unbuilt role cannot pin the page to Unknown.
            v.practice_state, v.practice_reason = "planned", "not started yet: no live check or scheduled job of its own"
        else:
            v.practice_state = worst(counted)
            bad = [x["sig"].label for x in v.signals if x["state"] == v.practice_state] + \
                  [f'{x["name"]} ({SCHED_WORDS[x["state"]][0].lower()})' if x["state"] in ("never", "paused", "stuck") else x["name"]
                   for x in live if SCHED_WORDS[x["state"]][1] == v.practice_state]
            if sched_gap and v.practice_state == UNKNOWN:
                bad.append(sched_gap)     # lab finding D2 (2026-10-23): an Unknown with no reason named
            v.practice_reason = (", ".join(bad[:3]) + (f" and {len(bad) - 3} more" if len(bad) > 3 else "")) \
                if v.practice_state != OK else "every signal and scheduled job is healthy"
        lr = [x["last_run"] for x in live if x.get("last_run")]
        ls = [x["last_success"] for x in live if x.get("last_success")]
        nx = [x["next"] for x in live if x.get("next")]
        v.last_run, v.last_success, v.next_run = (max(lr) if lr else None), (max(ls) if ls else None), (min(nx) if nx else None)
    # a lead's practice is its team's: the worst of the roles that have started (its own included)
    team_state = {}
    for t in cat.teams:
        lv = views[t.lead.id]
        sub = [views[m.id].practice_state for m in t.members if views[m.id].practice_state != "planned"]
        if lv.practice_state not in ("planned", UNKNOWN) or lv.agent.signals:
            sub.append(lv.practice_state)
        n_planned = sum(1 for m in t.members if views[m.id].practice_state == "planned")
        n_bad = sum(1 for x in sub if x != OK)
        tail = f"; {n_planned} not started yet" if n_planned else ""
        if not sub:
            lv.practice_state, lv.practice_reason = "planned", f"no role on this team has a live check yet ({len(t.members)} planned)"
        else:
            lv.practice_state = worst(sub)
            lv.practice_reason = (f"every running practice is healthy ({len(sub)} of {len(t.members) + 1}){tail}" if lv.practice_state == OK
                                  else f"{n_bad} of {len(sub)} running practices are not confirmed healthy{tail}")
        team_state[t.id] = lv.practice_state
    # agents: the ledger
    led = readings["ledger"]
    for a in cat.all():
        v = views[a.id]
        if not ledger_configured:
            v.agent_state, v.agent_word = UNKNOWN, "Not connected"
            v.agent_reason = "no agent ledger is configured, so this page cannot see agent runs"
            continue
        if led.fetched_at is None:
            v.agent_state, v.agent_word, v.agent_reason = UNKNOWN, "Unknown", f"agent ledger: {led.reason or 'no answer'}"
            continue
        runs = sorted([j for j in led.data or [] if j.get("profile") == a.id], key=lambda j: _ts(j.get("created")) or 0, reverse=True)
        v.runs = runs[:20]
        v.waiting = [j for j in runs if j.get("status") == "input_required"]
        v.cost = sum(_usd(j.get("cost_usd")) for j in runs if (_ts(j.get("created")) or 0) > now - 30 * 86400)
        newest = (runs[0].get("status") or "") if runs else ""
        if not runs:
            v.agent_state, v.agent_word, v.agent_reason = UNKNOWN, "Never run", "the ledger holds no run for this agent"
        elif newest == "failed":
            v.agent_state, v.agent_word, v.agent_reason = CRIT, "Failing", "its newest run failed"
        elif v.waiting:
            v.agent_state, v.agent_word, v.agent_reason = WARN, "Waiting on you", (f"{len(v.waiting)} items need a decision" if len(v.waiting) != 1 else "1 item needs a decision")
        elif newest in ("working", "queued"):
            v.agent_state, v.agent_word, v.agent_reason = OK, "Running", "a run is in progress"
        elif newest == "completed":
            v.agent_state, v.agent_word, v.agent_reason = OK, "Healthy", "its newest run completed"
        else:
            v.agent_state, v.agent_word = UNKNOWN, "Unknown"
            v.agent_reason = f"its newest run reads {newest!r}" if newest else "its newest run has no status"
    # Waiting items whose profile is no role in this catalog still need a person: they go to the lead of
    # the first team (the one you talk to), marked, rather than vanish.
    if ledger_configured and led.fetched_at is not None and cat.teams:
        known = {a.id for a in cat.all()}
        stray = [dict(j, unrouted=True) for j in led.data or []
                 if j.get("status") == "input_required" and j.get("profile") not in known]
        if stray:
            views[cat.teams[0].lead.id].waiting.extend(stray)
    return [views[a.id] for a in cat.all()], unowned


def org_verdict(cat: Catalog, views) -> tuple[str, str]:
    """The organization's verdict: the worst team that has started. Teams with nothing live yet are
    named, never counted."""
    by = {v.agent.id: v for v in views}
    started = [(t, by[t.lead.id].practice_state) for t in cat.teams if by[t.lead.id].practice_state != "planned"]
    idle = [t.name for t in cat.teams if by[t.lead.id].practice_state == "planned"]
    if not started:
        return UNKNOWN, "no team has a live check yet"
    st = worst(x for _, x in started)
    bad = [t.name for t, x in started if x != OK]
    why = (f"{', '.join(t.name for t, _ in started)} report every running practice healthy" if st == OK
           else f"{' and '.join(bad)} cannot confirm every running practice is healthy")
    if idle:
        why += f"; {', '.join(idle)} not started yet"
    return st, why


def _ts(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return _parse_ts(v)


def day_rail(views, unowned, now: float, tz: str, hours: int = 24):
    """The next `hours` of scheduled work, per manager, as positions on a rail (0..1) plus the same
    facts as a list. The rail is a picture of the list; the list is the content (WCAG 1.1.1)."""
    from datetime import datetime
    from zoneinfo import ZoneInfo
    z = ZoneInfo(tz)
    end = now + hours * 3600
    lanes, rows = [], []
    for v in list(views) + ([None] if unowned else []):
        name = v.agent.name if v else "No owner"
        aid = v.agent.id if v else ""
        scheds = v.schedules if v else unowned
        ticks = []
        for s in scheds:
            expr = s.get("schedule") or ""
            if not expr or expr == "event" or s.get("state") == "paused":
                continue
            try:
                c = Cron(expr, s.get("timezone") or tz)
            except Exception:  # noqa: BLE001
                continue
            planned = s.get("source") != "cluster"
            gap = c.interval_hint(now) or 86400
            if gap < 3600:
                # every few minutes: a band on the rail and one line in the list, not hundreds of ticks
                ticks.append({"band": True, "planned": planned, "name": s["name"]})
                rows.append({"t": now, "when": "all day", "name": s["name"], "owner": name, "owner_id": aid,
                             "planned": planned, "kind": s.get("kind", ""), "every": describe(expr), "frequent": True})
                continue
            t = c.next_after(now - 1)
            n = 0
            while t and t <= end and n < 96:
                planned = s.get("source") != "cluster"
                ticks.append({"x": (t - now) / (end - now), "planned": planned, "name": s["name"], "t": t})
                rows.append({"t": t, "when": datetime.fromtimestamp(t, z).strftime("%a %H:%M"),
                             "name": s["name"], "owner": name, "owner_id": aid, "planned": planned,
                             "kind": s.get("kind", "")})
                t = c.next_after(t)
                n += 1
        if ticks:   # a role with nothing in this window gets no lane; the list says what does run
            lanes.append({"name": name, "id": aid, "ticks": ticks})
    rows.sort(key=lambda r: (not r.get("frequent"), r["t"]))
    # collisions: two or more DIFFERENT jobs, each hourly or slower, starting in the same five minutes
    clashes = {}
    for r in rows:
        if not r.get("frequent"):
            clashes.setdefault(int(r["t"] // 300), {}).setdefault(r["name"], r)
    clash_list = [list(g.values()) for g in clashes.values() if len(g) > 1]
    step = 6 if hours <= 24 else 24
    fmt = "%H:%M" if hours <= 24 else "%a %d"
    marks = []
    for h in range(0, hours, step):   # one label per segment, at its left edge
        t = now + h * 3600
        marks.append({"x": h / hours, "label": datetime.fromtimestamp(t, z).strftime(fmt)})
    return {"lanes": lanes, "rows": rows, "clashes": clash_list, "marks": marks, "segments": len(marks)}


# ---------------------------------------------------------------- routes

def register(app, s, render, user_of, need_login, forbidden, kube: KubeClient, transports):
    f = s.feature("platform")
    if not (f and f.enabled):
        return None    # absent, not locked: no route, no nav entry (council C1)
    opt = f.options
    try:
        cat = load_catalog(opt.get("catalogFile") or None)
        for k in ("timezone", "clusterTimezone"):       # an unknown zone would fail every request instead
            ZoneInfo(str(opt.get(k, "UTC")))
    except Exception as e:  # noqa: BLE001 - any mistake here is the page's 503, never the whole UI's crash
        # A broken site catalog must not take the rest of the UI down with it: the page stays, admin
        # only, and says what is wrong and where. Nothing on it reads healthy.
        log.error("platform: catalog %s did not load: %s", opt.get("catalogFile") or "(default)", e)
        reason = (f"The Platform Management catalog ({opt.get('catalogFile') or 'the product default'}) did not load: {e}"
                  if isinstance(e, CatalogError) else f"Platform Management could not start: a time zone in features.platform: {e!r}")

        def broken(request: Request, aid: str = "", rid: str = ""):
            u = user_of(request)
            if not u:
                return need_login(request)
            if not u.is_admin:
                return forbidden(request, u)
            return render(request, "error.html", u, status_code=503, title="Platform Management is unavailable",
                          message=reason)
        for path in ("/platform", "/platform/schedule", "/platform/agents/{aid}", "/platform/cases",
                     "/platform/cases/{rid}", "/platform/specialists"):
            app.get(path)(broken)
        return None
    tp = transports
    srcs = {
        "cronjobs": CronJobsSource(s.prometheus_url, s.source_timeout_s, tp.prometheus,
                                   cluster_tz=str(opt.get("clusterTimezone", "UTC"))),
        "cronworkflows": CronWorkflowsSource(kube, s.prometheus_url, s.source_timeout_s,
                                             str(opt.get("workflowSuccessQuery", "")), tp.prometheus),
        "signals": SignalsSource(s.prometheus_url, s.source_timeout_s, cat, tp.prometheus),
        "ledger": LedgerSource(str(opt.get("ledgerUrl", "")), s.source_timeout_s,
                               str(opt.get("ledgerTokenFile", "")), getattr(tp, "ledger", None)),
        "desk": platform_cases.DeskSource(str(opt.get("specialistsUrl", "")), s.source_timeout_s,
                                          str(opt.get("specialistsTokenFile", "")), getattr(tp, "specialists", None)),
        "index": platform_cases.IndexSource(str(opt.get("specialistsUrl", "")), s.source_timeout_s,
                                            getattr(tp, "specialists", None)),
    }
    interface_url = str(opt.get("interfaceUrl", "")).rstrip("/")
    tz = str(opt.get("timezone", "UTC"))
    grafana = s.app("grafana")
    app.state.platform = {"catalog": cat, "sources": srcs}

    def snapshot():
        r = {k: v.read() for k, v in srcs.items() if k not in ("desk", "index")}
        views, unowned = build(cat, r, ledger_configured=srcs["ledger"].configured(), tz=tz)
        if not srcs["ledger"].configured() and srcs["index"].configured():
            # No orchestrator ledger, but the specialist host answers: say which of the role's built specialists it
            # serves instead of a bare Not connected. Served is not healthy (their call health is not read here),
            # so the state stays Unknown.
            idx = srcs["index"].read()
            served = ((idx.data or {}).get("served") or {}) if idx.fetched_at is not None else None
            for v in views:
                built = [x["id"] for x in v.agent.specialists if x["state"] == "built"]
                if not built or served is None:
                    continue
                n = sum(1 for x in built if x in served)
                v.agent_state, v.agent_word = (UNKNOWN, "Served") if n == len(built) else (WARN, f"{n} of {len(built)} served")
                v.agent_reason = (f"the specialist host serves {n} of its {len(built)} built specialists; "
                                  "how their calls are going is not read on this page yet")
        return r, views, unowned

    def common(u):
        g = grafana if (grafana and grafana.visible_to(set(u.groups))) else None
        return {"interface_url": interface_url, "grafana": g, "modes": MODES, "sched_words": SCHED_WORDS,
                "tz": tz, "now": time.time(), "spec_words": SPECIALIST_WORDS, "ask_words": platform_cases.ASK_WORDS,
                "wait_words": platform_cases.WAIT_WORDS, "reason_words": platform_cases.REASON_WORDS,
                "state_words": platform_cases.STATE_WORDS, "type_words": platform_cases.TYPE_WORDS,
                "cases_on": srcs["desk"].configured(), "by_agent_role": platform_cases.roles_by_agent_role(cat),
                "spec_roles": platform_cases.specialist_roles(cat)}

    def desk():
        r = srcs["desk"].read()
        return r, ((r.data or {}).get("records") or []) if r.fetched_at is not None else []

    def guard(request):
        u = user_of(request)
        if not u:
            return None, need_login(request)
        if not u.is_admin:
            return None, forbidden(request, u)
        return u, None

    @app.get("/platform")
    def overview(request: Request):
        u, deny = guard(request)
        if deny:
            return deny
        r, views, unowned = snapshot()
        by = {v.agent.id: v for v in views}
        teams = [{"team": t, "lead": by[t.lead.id], "members": [by[m.id] for m in t.members]} for t in cat.teams]
        verdict, why = org_verdict(cat, views)
        waiting = [(v, j) for v in views for j in v.waiting]
        rail = day_rail([v for v in views if v.schedules], unowned, time.time(), tz)
        dr, rows = desk()
        pending, _ = platform_cases.split(rows)
        yours = [x for x in pending if x["waiting"] and x["waiting"]["on"] in ("jeff", "attention")]
        return render(request, "platform_overview.html", u, readings=r, views=views, teams=teams,
                      org_state=verdict, org_why=why, unowned=unowned, waiting=waiting, rota=rail,
                      ledger_on=srcs["ledger"].configured(), desk=dr, case_counts=platform_cases.summarize(rows),
                      yours=yours, **common(u))

    @app.get("/platform/schedule")
    def schedule(request: Request):
        u, deny = guard(request)
        if deny:
            return deny
        r, views, unowned = snapshot()
        rows = [(v.agent, x) for v in views for x in v.schedules] + [(None, x) for x in unowned]
        order = {"failed": 0, "missed": 1, "stuck": 2, "late": 2, "unknown": 3, "never": 4, "paused": 5,
                 "running": 6, "up": 7, "external": 8, "planned": 9}
        rows.sort(key=lambda ax: (order.get(ax[1]["state"], 9), ax[1]["name"]))
        rail = day_rail(views, unowned, time.time(), tz, hours=24 * 7)
        return render(request, "platform_schedule.html", u, readings=r, rows=rows, rota=rail, **common(u))

    @app.get("/platform/agents/{aid}")
    def agent(request: Request, aid: str):
        u, deny = guard(request)
        if deny:
            return deny
        if not cat.get(aid):
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message="There is no such role in this platform's organization.")
        r, views, unowned = snapshot()
        by = {x.agent.id: x for x in views}
        v = by[aid]
        t = cat.team(v.agent.team)
        team = [by[m.id] for m in t.members] if v.agent.is_lead else []
        dr, rows = desk()
        mine = platform_cases.role_cases(v.agent, rows) if (v.agent.agent_role or v.agent.specialists) else []
        pending, done = platform_cases.split(mine)
        idx = srcs["index"].read()
        served = ((idx.data or {}).get("served") or {}) if idx.fetched_at is not None else None
        return render(request, "platform_agent.html", u, readings=r, v=v, team=team, team_obj=t,
                      lead=by[t.lead.id], desk=dr, pending=pending, done=done, served=served, index=idx,
                      drift=platform_cases.drift(cat, idx), **common(u))

    platform_cases.register(app, cat, srcs, guard, render, common)
    return srcs

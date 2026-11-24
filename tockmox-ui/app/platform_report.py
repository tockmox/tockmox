# SPDX-License-Identifier: Apache-2.0
"""Platform Management: each role reports on its area in four blocks, and the Overview's tiles.

A role's page opens on four blocks, the same four for every role:

  what it watches       its signals, each by name, with the value now
  what it logged        what its cases, its agent runs and its scheduled jobs did since the viewer last looked
  its open items        its open cases, the items its agent waits on you for, its failing scheduled jobs
  its health            how its practice is doing and how its agent is doing, two facts, never merged

The Overview opens on a row of tiles, each a count with the source it comes from.

The rule every block and tile keeps: a source that is not connected or did not answer says so in words, by name and
with its reason, and the block or tile never reads as empty or healthy because of it. "Nothing logged" and "no open
item" are said only when every source the block reads answered.

"Since you last looked" is kept in a cookie in the viewer's own browser, one per role page, path /platform: the time
the page was last opened there. It is the viewer's own state, not the platform's: the page still writes nothing.
"""
from __future__ import annotations

import re
import time

from . import platform_cases
from .sources import CRIT, OK, UNKNOWN, WARN, _parse_ts, worst

SEEN_PREFIX = "tmx_seen_"
SEEN_MAX_AGE = 90 * 86400          # a cookie older than this, or from the future, is ignored
FIRST_LOOK_S = 24 * 3600           # a first look shows the last day
LOG_LIMIT = 12
OPEN_LIMIT = 12
BAD_SCHED = ("failed", "missed", "stuck")
RUN_WORDS = {"completed": "Completed", "failed": "Failed", "input_required": "Waiting on you", "working": "Running",
             "queued": "Queued", "cancelled": "Cancelled"}
RUN_STATES = {"completed": OK, "failed": CRIT, "input_required": WARN, "working": OK}
_ROLE_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")


# ---------------------------------------------------------------- since you last looked

def seen_cookie(aid: str) -> str:
    """The cookie that holds when this browser last opened a role's page. Role ids are already cookie-safe."""
    if not _ROLE_ID.fullmatch(aid or ""):
        raise ValueError("not a role id")
    return SEEN_PREFIX + aid


def since(raw, now: float) -> tuple[float, bool]:
    """(the time to report from, whether this is a first look). A missing, malformed, future or stale cookie is a
    first look: the last day, said as such, never a silent empty block."""
    try:
        t = float(str(raw or "").strip())
    except ValueError:
        t = None
    if t is None or t != t or t > now + 60 or t < now - SEEN_MAX_AGE:
        return now - FIRST_LOOK_S, True
    return t, False


# ---------------------------------------------------------------- one role: four blocks

def _ts(v) -> float | None:
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return _parse_ts(v)


def _down(reading, what) -> str:
    return f"{reading.source} did not answer ({reading.reason or 'no answer'}), so {what}"


def _sched_sources_down(readings) -> list:
    return [readings[k] for k in ("cronjobs", "cronworkflows") if readings[k].fetched_at is None]


def role_report(v, readings: dict, desk, cases: list, *, cases_on: bool, ledger_on: bool, seen_from: float,
                first_look: bool, now: float | None = None) -> dict:
    """The four blocks for one role (an AgentView from platform.build). `cases` are this role's cases from the desk
    (platform_cases.role_cases), already read; `desk` is the desk's Reading. Every block carries `gaps`: one sentence
    per source it could not read, in words."""
    now = now or time.time()
    a = v.agent
    has_cases = bool(a.agent_role or a.specialists)
    owns_cluster_work = bool(a.match) or any(x.get("source") == "cluster" for x in v.schedules)
    sched_down = _sched_sources_down(readings)

    # ---- what it watches
    sig_r = readings["signals"]
    watches = {"signals": list(v.signals), "gaps": [],
               "deployed": [x for x in v.schedules if x.get("source") == "cluster"],
               "planned": [x for x in v.schedules if x.get("source") == "planned"],
               "deployed_known": not sched_down}
    if a.signals and sig_r.fetched_at is None:
        watches["gaps"].append(_down(sig_r, "none of its signals can be read now. That is not the same as healthy."))
    if owns_cluster_work:
        for r in sched_down:
            watches["gaps"].append(_down(r, "its scheduled jobs cannot be listed now."))

    # ---- what it logged since the viewer last looked
    log, gaps = [], []
    if has_cases:
        if not cases_on:
            gaps.append("No Service Desk is connected, so what its cases recorded cannot be read here.")
        elif desk.fetched_at is None:
            gaps.append(_down(desk, "what its cases recorded since then cannot be read."))
        else:
            for r in cases:
                t = r.get("updated_ts")
                if t and t > seen_from:
                    log.append({"t": t, "kind": "case", "id": r["id"], "type": r["type"], "state": r["state"],
                                "title": r.get("title") or "", "closed": r["closed"]})
    if not ledger_on:
        gaps.append("No agent ledger is connected, so its agent's runs cannot be read here.")
    elif readings["ledger"].fetched_at is None:
        gaps.append(_down(readings["ledger"], "its agent's runs since then cannot be read."))
    else:
        for j in v.runs:
            t = _ts(j.get("created"))
            if t and t > seen_from:
                st = str(j.get("status") or "")
                log.append({"t": t, "kind": "run", "id": str(j.get("id") or ""),
                            "word": RUN_WORDS.get(st, st or "Unknown"), "state": RUN_STATES.get(st, UNKNOWN)})
    if owns_cluster_work:
        for r in sched_down:
            gaps.append(_down(r, "the runs of its scheduled jobs cannot be read."))
    for x in watches["deployed"]:
        t = x.get("last_run")
        if t and t > seen_from:
            log.append({"t": t, "kind": "job", "id": x["name"], "job": x, "sched_state": x["state"]})
    log.sort(key=lambda e: e["t"], reverse=True)
    logged = {"entries": log[:LOG_LIMIT], "more": max(0, len(log) - LOG_LIMIT), "gaps": gaps,
              "since": seen_from, "first_look": first_look}

    # ---- its open items
    items, gaps = [], []
    if has_cases:
        if not cases_on:
            gaps.append("No Service Desk is connected, so its open cases cannot be read here.")
        elif desk.fetched_at is None:
            gaps.append(_down(desk, "its open cases cannot be read. That is not the same as none."))
        else:
            pend, _done = platform_cases.split(cases)
            for r in pend:
                items.append(dict(r, kind="case", rank=(0,) + platform_cases.pending_order(r)))
            if desk.state != OK:
                gaps.append(f"The Service Desk's answer is incomplete ({desk.reason or 'no reason given'}), "
                            "so this list may not be everything.")
    if ledger_on:
        if readings["ledger"].fetched_at is None:
            gaps.append(_down(readings["ledger"], "what its agent waits on you for cannot be read."))
        else:
            for j in v.waiting:
                items.append({"kind": "decision", "id": str(j.get("id") or ""), "unrouted": bool(j.get("unrouted")),
                              "rank": (0, -1, 0, 0)})
    else:
        gaps.append("No agent ledger is connected, so what its agent waits on you for cannot be read here.")
    if owns_cluster_work:
        for r in sched_down:
            gaps.append(_down(r, "a failing scheduled job of its cannot be seen."))
    for x in watches["deployed"]:
        if x["state"] in BAD_SCHED:
            items.append({"kind": "job", "id": x["name"], "job": x, "sched_state": x["state"], "rank": (1, 0, 0, 0)})
    items.sort(key=lambda i: i["rank"])
    open_items = {"rows": items[:OPEN_LIMIT], "more": max(0, len(items) - OPEN_LIMIT), "gaps": gaps}

    # ---- its health: the practice and the agent, as build() decided them, with the sources that held them back
    health = {"practice_state": v.practice_state, "practice_reason": v.practice_reason,
              "agent_state": v.agent_state, "agent_word": v.agent_word, "agent_reason": v.agent_reason,
              "gaps": list(watches["gaps"])}
    return {"watches": watches, "logged": logged, "open": open_items, "health": health}


# ---------------------------------------------------------------- the Overview's tiles

def _tile(tid, label, value, state, source, gaps=(), note=""):
    return {"id": tid, "label": label, "value": value, "state": state, "source": source, "gaps": list(gaps),
            "note": note}


def overview_tiles(views, unowned, readings: dict, desk, rows: list, *, cases_on: bool, ledger_on: bool) -> list:
    """Four counts, each with where it comes from. A count whose source is down or not connected reads Unknown or
    Not connected, with the reason in words; a zero is shown only when its sources answered."""
    tiles = []
    sched_down = _sched_sources_down(readings)

    # 1. practices: the roles that have started, how many are confirmed healthy
    started = [v for v in views if v.practice_state != "planned"
               and not (v.agent.is_lead and not v.agent.signals
                        and not any(x.get("source") == "cluster" for x in v.schedules))]
    gaps = []
    if readings["signals"].fetched_at is None:
        gaps.append(_down(readings["signals"], "no practice can be confirmed healthy."))
    for r in sched_down:
        gaps.append(_down(r, "no scheduled job can be confirmed on time."))
    if not started:
        tiles.append(_tile("practices", "Practices healthy", "None started", UNKNOWN,
                           "the role catalog, live signals and scheduled jobs", gaps,
                           "No role has a live check or a deployed job of its own yet."))
    elif gaps:
        tiles.append(_tile("practices", "Practices healthy", "Unknown", UNKNOWN,
                           "live signals and scheduled jobs", gaps))
    else:
        n_ok = sum(1 for v in started if v.practice_state == OK)
        tiles.append(_tile("practices", "Practices healthy", f"{n_ok} of {len(started)}",
                           worst(v.practice_state for v in started), "live signals and scheduled jobs",
                           note=f"{len(views) - len(started)} not started yet" if len(views) > len(started) else ""))

    # 2. waiting on you: cases asking a person, and items the agents wait on you for
    gaps, parts, n = [], [], 0
    if cases_on:
        if desk.fetched_at is None:
            gaps.append(_down(desk, "the cases waiting on you cannot be counted."))
        else:
            k = len(platform_cases.needs_you(rows))
            n += k
            parts.append(f"{k} from the Service Desk")
            if desk.state != OK:
                gaps.append(f"The Service Desk's answer is incomplete ({desk.reason or 'no reason given'}), "
                            "so the count may be short.")
    if ledger_on:
        if readings["ledger"].fetched_at is None:
            gaps.append(_down(readings["ledger"], "what the agents wait on you for cannot be counted."))
        else:
            k = sum(len(v.waiting) for v in views)
            n += k
            parts.append(f"{k} from the agent ledger")
    if not cases_on and not ledger_on:
        tiles.append(_tile("waiting", "Waiting on you", "Not connected", UNKNOWN, "the Service Desk and the agent ledger",
                           ["Neither a Service Desk nor an agent ledger is connected, so nothing here can say what "
                            "waits on you. That is not the same as nothing waiting."]))
    elif gaps and not parts:
        tiles.append(_tile("waiting", "Waiting on you", "Unknown", UNKNOWN, "the Service Desk and the agent ledger", gaps))
    elif gaps:
        tiles.append(_tile("waiting", "Waiting on you", f"{n} or more", UNKNOWN,
                           "the Service Desk and the agent ledger", gaps, "; ".join(parts)))
    else:
        tiles.append(_tile("waiting", "Waiting on you", str(n), WARN if n else OK,
                           " and ".join(p.split(" from ", 1)[1] for p in parts), note="; ".join(parts)))

    # 3. open cases
    if not cases_on:
        tiles.append(_tile("cases", "Open cases", "Not connected", UNKNOWN, "the Service Desk",
                           ["No Service Desk is connected, so open cases cannot be counted here."]))
    elif desk.fetched_at is None:
        tiles.append(_tile("cases", "Open cases", "Unknown", UNKNOWN, "the Service Desk",
                           [_down(desk, "open cases cannot be counted. That is not the same as none.")]))
    else:
        c = platform_cases.summarize(rows)
        gaps = ([f"The Service Desk's answer is incomplete ({desk.reason or 'no reason given'})."]
                if desk.state != OK else [])
        tiles.append(_tile("cases", "Open cases", str(c["open"]) + (" or more" if gaps else ""),
                           UNKNOWN if gaps else "info", "the Service Desk", gaps,
                           f"{c['closed']} closed in the last 30 days"))

    # 4. scheduled jobs failing, missed or stuck, owned or not
    if sched_down:
        tiles.append(_tile("jobs", "Scheduled jobs failing", "Unknown", UNKNOWN, "kube-state-metrics and Argo",
                           [_down(r, "failing jobs cannot be counted.") for r in sched_down]))
    else:
        rows_live = [x for v in views for x in v.schedules if x.get("source") == "cluster"] + list(unowned)
        bad = [x for x in rows_live if x["state"] in BAD_SCHED]
        tiles.append(_tile("jobs", "Scheduled jobs failing", str(len(bad)), CRIT if bad else OK,
                           "kube-state-metrics and Argo",
                           note=f"of {len(rows_live)} deployed" + (": " + ", ".join(x["name"] for x in bad[:3])
                                                                   + (" and more" if len(bad) > 3 else "") if bad else "")))
    return tiles

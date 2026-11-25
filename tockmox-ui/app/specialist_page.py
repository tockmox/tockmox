# SPDX-License-Identifier: Apache-2.0
"""Platform Management: one page per specialist, /platform/specialists/<id>, and its Health.

The page is written for the person the specialist works for. It opens on three blocks shaped like a role page's (what
it did since you last looked, its open items, its health), then five plain sections: what it does, who it works for,
who can ask it, what it may call, what stays yours.

Where each fact comes from:

  the specialist host's index   title, summary, version, mode (its status), callers, what it may call, operations and
                                their outcomes, the data class it may see; owner_keeps, triggers, per-operation callers
                                and model steps once the host's index renders them. A field the index does not carry
                                yet reads "not in the index yet", never an empty list.
  Prometheus                    Health (below) and what it did: specialist_calls_total by operation and outcome since
                                the viewer last looked, and specialist_model_cost_usd_total.
  the Service Desk              its open items: open cases it is handed, or that it worked.
  the role catalog              who it works for.

Health is one of five words, decided in this order; no rule ever falls through to Up:

  Down          the host does not answer (its index is unreachable), every `up` series of the host's scrape job is
                0, or its Deployment has no ready replica
  Not served    the host answers but does not serve this specialist
  Unknown       Prometheus did not answer, has no `up` series for the host, or the failed share cannot be read
  Degraded      5% or more of its calls in the last hour failed, with at least 20 calls; or fewer ready replicas
                than desired; or some of the host's instances are down
  Up            served, and none of the above

Idle is never a health state: no calls in the last hour is Up when everything else answered. Nothing on the page is
rendered from model output; the index carries a spec's own words, and Prometheus labels are shown only in their own
shape.
"""
from __future__ import annotations

import logging
import math
import re
import time

import httpx
from fastapi import Request

from . import platform_cases, platform_report
from .sources import CRIT, OK, UNKNOWN, WARN, Source

log = logging.getLogger("tockmox_ui.platform")

UP, DEGRADED, DOWN, NOT_SERVED, UNKNOWN_H = "up", "degraded", "down", "not_served", "unknown"
HEALTH_WORDS = {UP: ("Up", OK), DEGRADED: ("Degraded", WARN), DOWN: ("Down", CRIT),
                NOT_SERVED: ("Not served", WARN), UNKNOWN_H: ("Unknown", UNKNOWN)}
FAILED_SHARE = 0.05        # the share of failed calls in the last hour that makes a specialist Degraded
MIN_CALLS = 20             # below this many calls in the hour the share says nothing
SEEN_SP = platform_report.SEEN_PREFIX + "sp_"
SPEC_ID = platform_cases.SPEC_ID
WORD = platform_cases.WORD
# The optional index fields this page reads when the host's index renders them
OPTIONAL = ("owner_keeps", "triggers", "model_steps", "reporting")


def _num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return None if math.isnan(f) or math.isinf(f) else f


def _vector(c: httpx.Client, q: str) -> list:
    r = c.get("/api/v1/query", params={"query": q})
    r.raise_for_status()
    doc = r.json()
    if not isinstance(doc, dict) or doc.get("status") != "success":
        raise ValueError("query failed")
    res = (doc.get("data") or {}).get("result")
    if not isinstance(res, list):
        raise ValueError("no result list")
    return res


class HealthSource(Source):
    """The four Prometheus reads Health needs, cached together: the host's `up`, every specialist's calls in the last
    hour by outcome, and the host Deployment's ready and desired replicas. A query that answers badly leaves its part
    None (that fact reads Unknown); Prometheus being gone makes the whole reading Unknown."""
    name = "Specialist health (Prometheus)"

    def __init__(self, url, timeout, job="specialist-host", deployment="specialist-host", transport=None, ttl=30.0):
        super().__init__(ttl)
        self.url, self.timeout, self.transport = url, timeout, transport
        self.job, self.deployment = job, deployment

    def configured(self):
        return bool(self.url)

    def queries(self):
        return {"up": f'up{{job="{self.job}"}}',
                "calls": 'sum by (specialist, outcome) (increase(specialist_calls_total[1h]))',
                "ready": f'kube_deployment_status_replicas_available{{deployment="{self.deployment}"}}',
                "desired": f'kube_deployment_spec_replicas{{deployment="{self.deployment}"}}'}

    def fetch(self):
        out = {}
        with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport) as c:
            for k, q in self.queries().items():
                try:
                    out[k] = _vector(c, q)
                except httpx.TransportError:
                    raise
                except Exception as e:  # noqa: BLE001 - one bad query is that fact's Unknown, not the page's
                    log.warning("platform: specialist health query %s failed: %s", k, type(e).__name__)
                    out[k] = None
        calls = None
        if out["calls"] is not None:
            calls = {}
            for row in out["calls"]:
                m = row.get("metric") or {}
                sid, oc = str(m.get("specialist") or ""), str(m.get("outcome") or "")
                v = _num((row.get("value") or [None, None])[1])
                if SPEC_ID.fullmatch(sid) and WORD.fullmatch(oc) and v is not None:
                    calls.setdefault(sid, {})[oc] = calls.get(sid, {}).get(oc, 0.0) + v

        def vals(k):
            if out[k] is None:
                return None
            return [x for x in (_num((r.get("value") or [None, None])[1]) for r in out[k]) if x is not None]
        return {"up": vals("up"), "calls": calls, "ready": vals("ready"), "desired": vals("desired")}

    def evaluate(self, data):
        return OK, "answered"


def health(sid: str, entry: dict | None, idx, idx_on: bool, prom, prom_on: bool, planned: bool = False) -> dict:
    """Health for one specialist: {state, word, badge, reasons}. `entry` is its row in the host's index (None when the
    host does not serve it); `idx` and `prom` are the index and Prometheus Readings. Every reason is a sentence."""
    def out(state, *reasons):
        w, b = HEALTH_WORDS[state]
        return {"state": state, "word": w, "badge": b, "reasons": [r for r in reasons if r]}
    if not idx_on:
        return out(UNKNOWN_H, "No specialist host is connected, so whether it is served is unknown.")
    if idx.fetched_at is None:
        return out(DOWN, f"The specialist host did not answer ({idx.reason or 'no answer'}).")
    if entry is None or entry.get("served") is False:
        if planned:
            return out(NOT_SERVED, "It is planned and not built yet, so the host does not serve it.")
        return out(NOT_SERVED, "The specialist host answers but does not serve it.")
    served = f"Served by the host, version {entry.get('version') or 'unknown'}."
    if not prom_on:
        return out(UNKNOWN_H, "No Prometheus is connected, so health is unknown.", served)
    if prom.fetched_at is None:
        return out(UNKNOWN_H, f"Prometheus did not answer ({prom.reason or 'no answer'}), so health is unknown.",
                   served)
    d = prom.data or {}
    up = d.get("up")
    if up is None:
        return out(UNKNOWN_H, "Prometheus could not answer whether the specialist host is up, so health is unknown.",
                   served)
    if not up:
        return out(UNKNOWN_H, "Prometheus has no up series for the specialist host, so health is unknown.", served)
    if all(v == 0 for v in up):
        return out(DOWN, "Prometheus reads the specialist host as down (up is 0).")
    ready, desired = d.get("ready") or [], d.get("desired") or []
    if ready and sum(ready) == 0:
        return out(DOWN, "The specialist host's Deployment has no ready replica.")
    calls = d.get("calls")
    if calls is None:
        return out(UNKNOWN_H, "Prometheus could not answer how its calls went, so health is unknown.", served)
    mine = calls.get(sid) or {}
    n, failed = sum(mine.values()), mine.get("failed", 0.0)
    share_text = f"{round(failed)} failed of {round(n)} calls in the last hour"
    degraded = []
    if n >= MIN_CALLS and failed / n >= FAILED_SHARE:
        degraded.append(f"{share_text} ({failed / n:.0%}; Degraded from {FAILED_SHARE:.0%} with at least {MIN_CALLS} calls).")
    if any(v == 0 for v in up):
        degraded.append(f"{sum(1 for v in up if v == 0)} of the specialist host's {len(up)} instances are down.")
    if ready and desired and sum(ready) < sum(desired):
        degraded.append(f"{round(sum(ready))} of {round(sum(desired))} replicas of the specialist host are ready.")
    if degraded:
        return out(DEGRADED, *degraded, served)
    if n == 0:
        return out(UP, served, "No calls in the last hour. That is idle, not a fault.")
    return out(UP, served, share_text + ".")


# ---------------------------------------------------------------- the index entry, cleaned

def _text(v, n=600) -> str:
    return " ".join(str(v).split())[:n] if isinstance(v, (str, int, float)) and not isinstance(v, bool) else ""


def _caller(c) -> dict | None:
    """A caller id in words, and a link when it is a specialist."""
    c = str(c or "")
    if c.startswith("specialist/") and SPEC_ID.fullmatch(c[11:]):
        return {"words": c[11:].replace("-", " ").title(), "href": f"/platform/specialists/{c[11:]}", "id": c}
    if c == "client/tockmox-ui":
        return {"words": "This console", "href": "", "id": c}
    if c.startswith("client/") and platform_cases.NAMEISH.fullmatch(c[7:]):
        return {"words": f"A client ({c[7:]})", "href": "", "id": c}
    if c == "schedule":
        return {"words": "The schedule", "href": "", "id": c}
    if c.startswith("event/") and platform_cases.NAMEISH.fullmatch(c[6:]):
        return {"words": f"An event source ({c[6:]})", "href": "", "id": c}
    if platform_cases.NAMEISH.fullmatch(c):
        return {"words": c, "href": "", "id": c}
    return None


def _keep(x) -> str:
    """One owner_keeps entry: a sentence, or {what: why} from the spec, as 'what: why'."""
    if isinstance(x, dict) and len(x) == 1:
        k, v = next(iter(x.items()))
        return f"{_text(k, 300)}: {_text(v, 300)}".strip(": ")
    return _text(x, 600)


def _triggers(t) -> list:
    """Schedules and events that start it, in words."""
    out = []
    if isinstance(t, dict):
        for s in t.get("schedules") or []:
            if isinstance(s, dict):
                when = _text(s.get("cron") or s.get("every") or s.get("at"), 80)
                op = _text(s.get("op"), 60)
                if when:
                    out.append(f"On a schedule ({when})" + (f": {op}" if op else ""))
        for e in t.get("events") or []:
            if isinstance(e, dict):
                src = _text(e.get("source") or e.get("event") or e.get("on") or e.get("kind"), 80)
                op = _text(e.get("op"), 60)
                if src:
                    out.append(f"On an event ({src})" + (f": {op}" if op else ""))
            elif _text(e, 120):
                out.append(f"On an event ({_text(e, 120)})")
    elif isinstance(t, list):
        out = [_text(x, 200) for x in t if _text(x, 200)]
    return out


def _model_steps(m) -> list:
    """{name: {alias, caps: {usd}, shadow}} or a list of the same with a name: each as words."""
    rows = []
    items = m.items() if isinstance(m, dict) else ((str((x or {}).get("name") or ""), x) for x in m or [] if isinstance(x, dict))
    for name, st in items:
        if not isinstance(st, dict) or not WORD.fullmatch(str(name or "")):
            continue
        caps = st.get("caps") if isinstance(st.get("caps"), dict) else {}
        usd = _num(caps.get("usd") if caps else st.get("usd"))
        rows.append({"name": str(name), "alias": _text(st.get("alias"), 60),
                     "usd": usd, "shadow": _text(st.get("shadow"), 200)})
    return rows


def clean_entry(s: dict) -> dict:
    """One specialist from the host's index, every field in its own shape. `present` names the optional fields the
    index carried, so a field it does not carry yet reads as such and never as an empty list."""
    ops = []
    for o in s.get("operations") or []:
        if not isinstance(o, dict) or not WORD.fullmatch(str(o.get("name") or "")):
            continue
        callers = o.get("callers")
        ops.append({"name": o["name"], "kind": str(o.get("kind") or "") if WORD.fullmatch(str(o.get("kind") or "")) else "",
                    "summary": _text(o.get("summary"), 600),
                    "outcomes": [x for x in (o.get("outcomes") or []) if isinstance(x, str) and WORD.fullmatch(x)][:20],
                    "model_step": str(o.get("model_step") or "") if WORD.fullmatch(str(o.get("model_step") or "")) else "",
                    "callers": None if callers is None else [x for x in (_caller(c) for c in callers or []) if x]})
    may = []
    for m in s.get("may_call") or []:
        if isinstance(m, str) and SPEC_ID.fullmatch(m):
            may.append({"id": m, "ops": None})
        elif isinstance(m, dict) and SPEC_ID.fullmatch(str(m.get("specialist") or "")):
            may.append({"id": m["specialist"], "ops": [x for x in m.get("ops") or [] if isinstance(x, str) and WORD.fullmatch(x)]})
    present = {k for k in OPTIONAL if k in s}
    rep = s.get("reporting") if isinstance(s.get("reporting"), dict) else {}
    # reporting: {to_caller, to_<person>, to_owner}; a person-facing line of needs_you_only reads as one sentence
    quiet = any(v == "needs_you_only" for v in rep.values())
    return {"id": s["id"], "title": _text(s.get("title"), 80), "summary": _text(s.get("summary"), 1200),
            "version": _text(s.get("version"), 20), "status": _text(s.get("status"), 20),
            "owner_role": _text(s.get("owner_role"), 60), "served": s.get("served") if isinstance(s.get("served"), bool) else None,
            "callers": [x for x in (_caller(c) for c in s.get("callers") or []) if x], "may_call": may,
            "operations": ops, "data_class_max": _text(s.get("data_class_max"), 40),
            "owner_keeps": [k for k in (_keep(x) for x in s.get("owner_keeps") or []) if k] if "owner_keeps" in present else [],
            "triggers": _triggers(s.get("triggers")) if "triggers" in present else [],
            "model_steps": _model_steps(s.get("model_steps")) if "model_steps" in present else [],
            "tells_you": ("only when it needs you" if quiet else "") if "reporting" in present else None,
            "present": sorted(present)}


# ---------------------------------------------------------------- what it did since you last looked

def seen_cookie(sid: str) -> str:
    if not SPEC_ID.fullmatch(sid or ""):
        raise ValueError("not a specialist id")
    return SEEN_SP + sid


def activity(url, timeout, transport, sid: str, seen_from: float, now: float) -> dict:
    """Calls since seen_from by operation and outcome, and model spend, from Prometheus. {rows, calls, spend, gap}:
    gap is a sentence when Prometheus did not answer, and then nothing else is said (unknown is not idle)."""
    if not url:
        return {"rows": [], "calls": None, "spend": None, "minutes": 0,
                "gap": "No Prometheus is connected, so its calls are unknown. That is not the same as idle."}
    minutes = max(1, int(math.ceil((now - seen_from) / 60)))
    q_calls = f'sum by (op, outcome) (increase(specialist_calls_total{{specialist="{sid}"}}[{minutes}m]))'
    q_spend = f'sum(increase(specialist_model_cost_usd_total{{specialist="{sid}"}}[{minutes}m]))'
    try:
        with httpx.Client(base_url=url, timeout=timeout, transport=transport) as c:
            res = _vector(c, q_calls)
            try:
                sp = _vector(c, q_spend)
                spend = _num((sp[0].get("value") or [None, None])[1]) if sp else 0.0
            except httpx.TransportError:
                raise
            except Exception:  # noqa: BLE001 - spend alone unknown
                spend = None
    except Exception as e:  # noqa: BLE001 - the block says why, in words
        log.warning("platform: specialist activity for %s failed: %s", sid, type(e).__name__)
        return {"rows": [], "calls": None, "spend": None, "minutes": minutes,
                "gap": f"Prometheus did not answer ({type(e).__name__}), so its calls are unknown. "
                       "That is not the same as idle."}
    by = {}
    for row in res:
        m = row.get("metric") or {}
        op, oc = str(m.get("op") or ""), str(m.get("outcome") or "")
        v = _num((row.get("value") or [None, None])[1])
        if WORD.fullmatch(op) and WORD.fullmatch(oc) and v is not None and round(v) > 0:
            by.setdefault(op, {})[oc] = by.get(op, {}).get(oc, 0) + round(v)
    rows = [{"op": op, "n": sum(o.values()), "outcomes": sorted(o.items(), key=lambda x: -x[1])}
            for op, o in sorted(by.items(), key=lambda x: -sum(x[1].values()))]
    return {"rows": rows, "calls": sum(r["n"] for r in rows), "spend": spend, "minutes": minutes, "gap": ""}


def its_cases(sid: str, rows: list) -> list:
    """Open cases it is handed (the desk waits on it) or that it worked, in pending order."""
    mine = [r for r in rows if not r["closed"] and ((r.get("waiting") or {}).get("specialist") == sid
                                                    or sid in (r.get("worked_by") or []))]
    return sorted(mine, key=platform_cases.pending_order)


# ---------------------------------------------------------------- the route

def register(app, cat, srcs, guard, render, common, *, prometheus_url, timeout, prom_transport, secure_cookies):

    def page(request: Request, sid: str):
        u, deny = guard(request)
        if deny:
            return deny
        if not SPEC_ID.fullmatch(sid or ""):
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message="That is not a specialist id.")
        idx = srcs["index"].read()
        idx_on = srcs["index"].configured()
        raw = ((idx.data or {}).get("entries") or {}) if idx.fetched_at is not None else {}
        roles = platform_cases.specialist_roles(cat)
        in_cat = sid in roles
        if not in_cat and sid not in raw:
            if idx_on and idx.fetched_at is None:
                msg = (f"This platform's catalog names no specialist {sid}, and the specialist host did not answer, "
                       "so whether the host serves one by that name is unknown.")
            else:
                msg = f"There is no specialist {sid}: this platform's catalog does not name it and the host does not serve it."
            return render(request, "error.html", u, status_code=404, title="Not found", message=msg)
        entry = raw.get(sid)
        state = next((s["state"] for a in cat.all() for s in a.specialists if s["id"] == sid), None)
        planned = state in ("specced", "proposed")
        prom = srcs["health"].read()
        h = health(sid, entry, idx, idx_on, prom, srcs["health"].configured(), planned=planned)
        now = time.time()
        cookie = seen_cookie(sid)
        seen_from, first = platform_report.since(request.cookies.get(cookie), now)
        act = activity(prometheus_url, timeout, prom_transport, sid, seen_from, now) if entry else None
        dr = srcs["desk"].read()
        desk_on = srcs["desk"].configured()
        rows = ((dr.data or {}).get("records") or []) if dr.fetched_at is not None else []
        open_rows = platform_cases.with_act(its_cases(sid, rows), common(u).get("interface_url", ""))
        open_gaps = []
        if not desk_on:
            open_gaps.append("No Service Desk is connected, so its open items cannot be read here.")
        elif dr.fetched_at is None:
            open_gaps.append(f"The Service Desk did not answer ({dr.reason or 'no answer'}), so its open items cannot "
                             "be read. That is not the same as none.")
        owner = (entry or {}).get("owner_role") or ""
        by_role = platform_cases.roles_by_agent_role(cat)
        works_for = list(roles.get(sid, []))
        acc = by_role.get(owner)
        if acc:
            works_for = [(acc.id, acc.name)] + [w for w in works_for if w[0] != acc.id]
        title = (entry or {}).get("title") or sid.replace("-", " ").title()
        resp = render(request, "platform_specialist.html", u, sid=sid, title=title, entry=entry, health=h, act=act,
                      seen_from=seen_from, first_look=first, open_rows=open_rows, open_gaps=open_gaps, desk=dr,
                      index=idx, index_on=idx_on, prom=prom, prom_on=srcs["health"].configured(), in_catalog=in_cat,
                      catalog_state=state, planned=planned, works_for=works_for, accountable=acc,
                      drift=platform_cases.drift(cat, idx), **common(u))
        resp.set_cookie(cookie, str(int(now)), max_age=platform_report.SEEN_MAX_AGE, path="/platform",
                        httponly=True, secure=secure_cookies, samesite="lax")
        return resp

    app.get("/platform/specialists/{sid}")(page)


__all__ = ["HealthSource", "health", "clean_entry", "activity", "its_cases", "seen_cookie", "register",
           "HEALTH_WORDS", "UP", "DEGRADED", "DOWN", "NOT_SERVED", "UNKNOWN_H"]

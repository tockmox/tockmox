# SPDX-License-Identifier: Apache-2.0
"""Page composition helpers for the UI standard (DESIGN-2026-10-23-ui-standard, TM-1127).

Exceptions first: every page opens with the problems, as rows that link to their page, and folds
what is healthy to one line. These functions turn the sources' readings into those rows and
sentences so the templates stay declarative. Pure functions over Reading objects; no I/O.
"""
from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Any

_RANK = {"critical": 0, "warning": 1, "unknown": 2, "ok": 3}

# Which "Your apps" group a tile belongs to, by the icon the site chose for it. A site may also set
# `group:` on an app in its values; that wins. Everything else lands in Everyday.
_GROUP_BY_ICON = {
    "chat": "Everyday", "book": "Everyday", "news": "Everyday",
    "chart": "Operate", "sync": "Operate", "disk": "Operate", "bell": "Operate", "flow": "Operate", "key": "Operate",
    "git": "Build", "gateway": "Build",
}
_GROUP_ORDER = ("Everyday", "Operate", "Build")


def _since(iso: str) -> str:
    """'41 min', '2 d', or '' when the timestamp is missing or unreadable."""
    if not iso:
        return ""
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return ""
    d = int(time.time() - t.astimezone(timezone.utc).timestamp())
    if d < 0:
        return ""
    if d < 3600:
        return f"{max(d // 60, 1)} min"
    if d < 86400:
        return f"{d // 3600} h"
    return f"{d // 86400} d"


def problems(readings: dict, pipeline: list | None = None) -> list[dict]:
    """Every non-healthy fact as a row: state, what (and where it links), kind, detail, since, action.
    A source that did not answer is a row too: absence is never green."""
    pipeline = set(pipeline or [])
    rows: list[dict] = []

    r = readings.get("apps")
    if r is not None and r.data:
        for a in r.data:
            sync, health = a.get("sync", ""), a.get("health", "")
            if sync == "Synced" and health == "Healthy":
                continue
            bad = health in ("Degraded", "Missing")
            rows.append({"state": "critical" if bad else "warning", "what": a.get("name", "?"), "href": None,
                         "kind": "application", "detail": f"{sync or '?'} · {health or '?'}", "since": "",
                         "action": None, "action_href": None})

    r = readings.get("nodes")
    if r is not None and r.data:
        for n in r.data:
            if n.get("ready") == "Ready":
                continue
            rows.append({"state": "critical" if n.get("ready") == "NotReady" else "unknown", "what": n.get("name", "?"),
                         "href": None, "kind": "node", "detail": f"{n.get('ready') or 'Unknown'} · kubelet {n.get('version') or '?'}",
                         "since": "", "action": None, "action_href": None})

    r = readings.get("alertmanager")
    if r is not None and r.data:
        for a in r.data:
            if a.get("name") in pipeline:
                continue
            sev = a.get("severity", "")
            if sev in ("info", "none"):
                continue
            rows.append({"state": "critical" if sev == "critical" else "warning", "what": a.get("name", "?"), "href": None,
                         "kind": a.get("namespace") or "alert", "detail": a.get("summary", ""), "since": _since(a.get("startsAt", "")),
                         "action": None, "action_href": None})

    r = readings.get("prometheus")
    if r is not None and r.data:
        for t in r.data:
            if t.get("up"):
                continue
            rows.append({"state": "warning", "what": t.get("job", "?"), "href": None, "kind": "scrape target",
                         "detail": f"{t.get('instance', '')} is not answering scrapes", "since": "", "action": None, "action_href": None})

    r = readings.get("inference_nodes")
    if r is not None and r.data:
        for x in r.data:
            if x.get("state") == "ok":
                continue
            rows.append({"state": x.get("state", "unknown"), "what": x.get("name") or x.get("id", "?"),
                         "href": f"/nodes/{x.get('id', '')}", "kind": "inference node", "detail": x.get("why", ""),
                         "since": "", "action": "Open", "action_href": f"/nodes/{x.get('id', '')}"})

    for key, r in readings.items():
        if r is None or r.state != "unknown":
            continue
        rows.append({"state": "unknown", "what": r.source, "href": "/status", "kind": "source",
                     "detail": (r.reason or "did not answer") + f" · last answered {r.age_text()}", "since": "",
                     "action": "Status", "action_href": "/status"})

    rows.sort(key=lambda x: (_RANK.get(x["state"], 9), x["what"]))
    return rows


def _n(count: int, one: str, many: str) -> str:
    return f"{count} {one if count == 1 else many}"


def verdict_sentence(verdict: str, probs: list[dict], readings: dict) -> str:
    """The first line of the page: the state in words, naming what is wrong by kind and count."""
    if not probs:
        if verdict == "ok":
            return "The platform is OK."
        return "Nothing is reporting a problem."
    kinds: dict[str, list[dict]] = {}
    for p in probs:
        kinds.setdefault(p["kind"] if p["kind"] in ("application", "node", "scrape target", "inference node", "source") else "alert", []).append(p)
    parts: list[str] = []
    if "inference node" in kinds:
        parts.append(_n(len(kinds["inference node"]), "inference node is", "inference nodes are") + " failing probes")
    if "node" in kinds:
        parts.append(_n(len(kinds["node"]), "node is", "nodes are") + " not ready")
    if "application" in kinds:
        parts.append(_n(len(kinds["application"]), "application is", "applications are") + " out of sync or unhealthy")
    if "alert" in kinds:
        crit = sum(1 for p in kinds["alert"] if p["state"] == "critical")
        warn = len(kinds["alert"]) - crit
        bits = []
        if crit:
            bits.append(_n(crit, "critical alert", "critical alerts"))
        if warn:
            bits.append(_n(warn, "warning", "warnings"))
        parts.append(" and ".join(bits) + (" is firing" if len(kinds["alert"]) == 1 else " are firing"))
    if "scrape target" in kinds:
        parts.append(_n(len(kinds["scrape target"]), "scrape target is", "scrape targets are") + " down")
    if "source" in kinds:
        parts.append(_n(len(kinds["source"]), "source", "sources") + " did not answer")
    s = "; ".join(parts)
    return s[0].upper() + s[1:] + "."


def sources_sentence(readings: dict) -> str:
    """'All 5 sources answered within 13 s.' or how many did not."""
    rs = [r for r in readings.values() if r is not None]
    if not rs:
        return "No sources are configured."
    answered = [r for r in rs if r.fetched_at]
    if len(answered) == len(rs):
        age = max(int(time.time() - r.fetched_at) for r in answered)
        within = f"{age} s" if age < 60 else (f"{age // 60} min" if age < 3600 else f"{age // 3600} h")
        return f"All {len(rs)} sources answered within {within}."
    missing = [r.source for r in rs if not r.fetched_at]
    return f"{len(answered)} of {len(rs)} sources answered; not answering: {', '.join(missing)}."


def healthy_parts(readings: dict, pipeline: list | None = None) -> list[str]:
    """One short phrase per healthy reading, for the folded line under the problems."""
    out: list[str] = []
    r = readings.get("apps")
    if r is not None and r.state == "ok" and r.data is not None:
        out.append(_n(len(r.data), "application", "applications") + " synced and healthy")
    r = readings.get("nodes")
    if r is not None and r.state == "ok" and r.data is not None:
        out.append(_n(len(r.data), "node", "nodes") + " ready")
    r = readings.get("prometheus")
    if r is not None and r.state == "ok" and r.data is not None:
        out.append(f"{len(r.data)} of {len(r.data)} scrape targets up")
    r = readings.get("alertmanager")
    if r is not None and r.state == "ok":
        out.append("nothing firing")
    if r is not None and r.data is not None and pipeline and any(a.get("name") in set(pipeline) for a in r.data):
        out.append("alerting pipeline alive")
    r = readings.get("inference_nodes")
    if r is not None and r.state == "ok" and r.data is not None:
        out.append(_n(len(r.data), "inference node", "inference nodes") + " healthy")
    for key, r in readings.items():
        if key in ("apps", "nodes", "prometheus", "alertmanager", "inference_nodes") or r is None or r.state != "ok":
            continue
        out.append(f"{r.source}: {r.reason}" if r.reason else r.source)
    return out


def app_groups(apps: list[Any]) -> list[tuple[str, list[Any]]]:
    """Group tiles as Everyday / Operate / Build; an app's own `group` wins over the icon rule.
    Groups come back in a fixed order and only when non-empty."""
    buckets: dict[str, list[Any]] = {}
    for a in apps:
        g = getattr(a, "group", None) or _GROUP_BY_ICON.get(getattr(a, "icon", ""), "Everyday")
        buckets.setdefault(g, []).append(a)
    ordered = [(g, buckets[g]) for g in _GROUP_ORDER if g in buckets]
    ordered += [(g, v) for g, v in buckets.items() if g not in _GROUP_ORDER]
    return ordered


def not_main(revision: str) -> str:
    """The Revision cell: empty for a branch head, the value otherwise (ninety 'main's say nothing)."""
    if not revision or revision in ("main", "master", "HEAD"):
        return ""
    return revision


def short_ref(ref: str, n: int = 7) -> str:
    """A git SHA or digest cut for a table cell; the template puts the whole value in title."""
    if not ref:
        return ""
    return ref[:n] if len(ref) > n + 2 else ref

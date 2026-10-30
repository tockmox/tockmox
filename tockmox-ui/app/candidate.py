# SPDX-License-Identifier: Apache-2.0
"""The candidate page's content (TM-1258): what an evaluation of `<alias>-next` will run, and how far each run has got.

Pure except read_runs(), which reads the run-status/1 files the eval runner writes (app/runner/status.py). A run strip shows
state and partial numbers and never a winner: a half-finished run says nothing about which model is better, and the page says
so. The verdict is the Compare page.
"""
from __future__ import annotations

import datetime
import os

DEFAULT_LEGS = ("control", "smoke", "perf", "prefill", "tool_reliability", "quality")
LEG_WORDS = {
    "control": "Known-bad control",
    "smoke": "Smoke",
    "perf": "Performance",
    "prefill": "Long-context prefill",
    "tool_reliability": "Tool-call reliability",
    "quality": "Quality",
}
RUN_WORDS = {"queued": "Queued", "waiting": "Waiting", "running": "Running", "done": "Done", "aborted": "Aborted", "failed": "Failed"}
LEG_STATE_WORDS = {"queued": "Queued", "running": "Running", "done": "Done", "failed": "Failed", "skipped": "Skipped"}
STALE_RUNNING_S = 3600                    # a run that says "running" and has not been written for an hour may have died
DEFAULT_QUIET = {"minutes": 10, "maxProductionRequests": 0}
MAX_METRICS = 12


def status_dir(raw_lifecycle) -> str:
    from .runner import status as st
    return str((raw_lifecycle or {}).get("statusDir", "") or st.DEFAULT_STATUS_DIR)


def read_runs(directory: str):
    """(runs, problem). runs: the run-status/1 documents, newest first. problem: "" or why they cannot be trusted as a complete list
    (no directory here, or a file in it that could not be read). Never raises."""
    from .runner import status as st
    runs_dir = os.path.join(directory, "runs")
    if not os.path.isdir(runs_dir):
        return [], (f"{runs_dir} is not there: the eval runner is off, or its status volume is not mounted in this pod "
                    "(modelLifecycle.runner.enabled, modelLifecycle.statusDir)")
    try:
        runs = st.read_statuses(directory)
        files = [n for n in os.listdir(runs_dir) if n.endswith(".json") and not n.startswith(".")]
    except Exception as e:  # noqa: BLE001  a status read must not take the page down
        return [], f"the run status files could not be read ({type(e).__name__})"
    bad = len(files) - len(runs)
    return runs, (f"{bad} run status file(s) could not be read and are not listed" if bad > 0 else "")


def runs_for(runs, alias: str) -> list:
    base = alias[: -len("-next")] if alias.endswith("-next") else alias
    return [r for r in runs if isinstance(r, dict) and str(r.get("alias", "")) in (base, base + "-next")]


def _ts(v):
    try:
        return datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None


def ago(then, now) -> str:
    t = _ts(then)
    if t is None:
        return "an unknown time ago"
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    s = int((now - t).total_seconds())
    if s < 0:
        return "in the future (clock skew)"
    if s < 60:
        return "just now"
    if s < 3600:
        return f"{s // 60} min ago"
    if s < 86400:
        return f"{s // 3600} h ago"
    return f"{s // 86400} d ago"


def duration(seconds) -> str:
    if not isinstance(seconds, (int, float)) or isinstance(seconds, bool) or seconds <= 0:
        return ""
    m = int(round(seconds / 60))
    return f"about {m // 60} h {m % 60:02d} min" if m >= 60 else f"about {m} min"


def _flat(d, prefix="", out=None):
    out = [] if out is None else out
    if isinstance(d, dict):
        for k, v in d.items():
            if len(out) >= MAX_METRICS:
                break
            if isinstance(v, dict):
                _flat(v, f"{prefix}{k}.", out)
            elif isinstance(v, (str, int, float, bool)) or v is None:
                out.append((f"{prefix}{k}", "not recorded" if v is None else (f"{v:g}" if isinstance(v, float) else str(v)[:80])))
    return out


def strip(status: dict, now) -> dict:
    """One run as the page shows it: overall state, why, the plan, each leg with its state and partial numbers, and what the
    page must not claim. Every field is optional in the file; a missing one is None here and the template says so."""
    state = str(status.get("state", ""))
    plan = status.get("plan") if isinstance(status.get("plan"), dict) else {}
    planned = [str(x) for x in plan.get("legs") or [] if isinstance(x, str)]
    legs_by = {str(l.get("name")): l for l in status.get("legs") or [] if isinstance(l, dict)}
    names = planned + [n for n in legs_by if n not in planned]
    legs = []
    for n in names:
        l = legs_by.get(n, {})
        ls = str(l.get("state", "queued" if n in planned else ""))
        legs.append({"name": n, "word": LEG_WORDS.get(n, n.replace("_", " ").capitalize()), "state": ls if ls in LEG_STATE_WORDS else "unknown",
                     "state_word": LEG_STATE_WORDS.get(ls, "Unknown"), "summary": str(l.get("summary", "") or ""),
                     "metrics": _flat(l.get("metrics")), "started": l.get("started"), "finished": l.get("finished")})
    updated = status.get("updated") or status.get("created")
    stale = False
    if state in ("running", "waiting", "queued"):
        t = _ts(updated)
        if t is not None:
            if t.tzinfo is None:
                t = t.replace(tzinfo=datetime.timezone.utc)
            stale = (now - t).total_seconds() > (STALE_RUNNING_S if state == "running" else 6 * STALE_RUNNING_S)
        else:
            stale = True
    partial = any(l["metrics"] for l in legs)
    node, eng, st_set = status.get("node"), status.get("engine"), status.get("set")
    return {
        "run_id": str(status.get("run_id", "")), "state": state, "state_word": RUN_WORDS.get(state, "Unknown"),
        "reason": str(status.get("reason", "") or ""), "trigger": str(status.get("trigger", "") or ""),
        "legs": legs, "partial": partial, "stale": stale, "updated": updated, "updated_ago": ago(updated, now) if updated else "",
        "created": status.get("created"),
        "node": node if isinstance(node, str) else None,
        "engine": (f"{eng.get('id', '')} {eng.get('version', '')}".strip() if isinstance(eng, dict) else None) or None,
        "set": (f"{st_set.get('id', '')} {st_set.get('version', '')}".strip() if isinstance(st_set, dict) else None) or None,
        "estimated": duration(plan.get("estimated_seconds")), "window": str(plan.get("window", "") or ""),
        "disk_gib": plan.get("disk_gib") if isinstance(plan.get("disk_gib"), (int, float)) else None,
        "label": status.get("label") if isinstance(status.get("label"), str) else None,
        "verdict_path": status.get("verdict_path") if isinstance(status.get("verdict_path"), str) else None,
        "evidence_pr": status.get("evidence_pr") if isinstance(status.get("evidence_pr"), str) and str(status.get("evidence_pr")).startswith("https://") else None,
        "candidate": status.get("candidate") if isinstance(status.get("candidate"), dict) else {},
        "incumbent": status.get("incumbent") if isinstance(status.get("incumbent"), dict) else None,
    }


def quiet_window(raw_lifecycle) -> dict:
    """modelLifecycle.runner.quietWindow as the chart passes it, else the contract's default (10 minutes, no production requests)."""
    q = (((raw_lifecycle or {}).get("runner") or {}).get("quietWindow")) or {}
    out = dict(DEFAULT_QUIET)
    for k in out:
        v = q.get(k) if isinstance(q, dict) else None
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0:
            out[k] = int(v)
    return out

# SPDX-License-Identifier: Apache-2.0
"""The candidate page's content (TM-1258): what an evaluation of `<alias>-next` will run, and how far each run has got.

Pure except read_runs(), which reads the run-status/1 files the eval runner writes (app/runner/status.py). A run strip shows
state and partial numbers and never a winner: a half-finished run says nothing about which model is better, and the page says
so. The verdict is the Compare page.
"""
from __future__ import annotations

import datetime
import os
import re

DEFAULT_LEGS = ("control", "smoke", "perf", "prefill", "tool_reliability", "quality")
LEG_WORDS = {
    "control": "Known-bad control",
    "smoke": "Smoke",
    "perf": "Performance",
    "perf_incumbent": "Performance, incumbent",
    "prefill": "Long-context prefill",
    "tool_reliability": "Tool-call reliability",
    "quality": "Quality",
    "quality_incumbent": "Quality, incumbent",
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


# ---------------------------------------------------------------- the run as a pipeline of stages (TM-1301)

# (key, name on the page, the legs it folds). A stage whose legs are in neither the plan nor the run's legs is left out.
STAGES = (("control", "Control", ("control",)), ("smoke", "Smoke", ("smoke",)),
          ("perf", "Perf", ("perf", "perf_incumbent")), ("prefill", "Prefill", ("prefill",)),
          ("tool_reliability", "Tool calls", ("tool_reliability",)), ("quality", "Quality", ("quality", "quality_incumbent")))
SUMMARY_MAX = 80
FINISHED = ("done", "failed")             # run states that can be measured again (aborted ones the runner retries by itself)
IN_PROGRESS = ("queued", "waiting", "running")


def clip(text, limit=SUMMARY_MAX) -> str:
    t = " ".join(str(text or "").split())
    return t if len(t) <= limit else t[: limit - 3].rstrip() + "..."


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _g(v) -> str:
    """A measured number as a reader wants it: whole from 10 up, one decimal below (no trailing .0)."""
    return f"{v:.0f}" if abs(v) >= 10 else f"{v:.1f}".removesuffix(".0")


def _tokens(n: int) -> str:
    return f"{n // 1024}K" if n >= 1024 and n % 1024 == 0 else str(n)


def _stage_state(cand, inc):
    """The stage's state from its candidate leg and its incumbent leg (either may be None): running if either runs, failed if
    either failed, otherwise the candidate leg's own (done when the candidate's leg is done)."""
    if "running" in (cand, inc):
        return "running"
    if "failed" in (cand, inc):
        return "failed"
    return cand or inc or "unknown"


def key_number(key: str, metrics, summary: str) -> dict:
    """The figure a done stage shows: {big, unit, cap, spoken}. Read from the leg's metrics as the runner recorded them (run.py
    pg.done calls); a metric that is absent falls back to the leg's summary text, clipped. Nothing is invented or derived beyond
    a ratio shown as a percent."""
    m = metrics if isinstance(metrics, dict) else {}
    out = None
    if key == "control" and _num(m.get("control_pass_rate")) is not None:
        pct = f"{m['control_pass_rate']:.0%}"
        out = {"big": pct, "unit": "", "cap": "known-bad cases passed", "spoken": f"known-bad passed {pct}"}
    elif key == "smoke":
        checks = {k: v for k, v in m.items() if str(k).startswith("smoke_") and _num(v) is not None}
        if checks:
            ok = sum(1 for v in checks.values() if v == 1.0)
            out = {"big": f"{ok}/{len(checks)}", "unit": "", "cap": "checks passed", "spoken": f"{ok} of {len(checks)} checks"}
    elif key == "perf":
        by_c = {}
        for k, v in m.items():
            hit = re.fullmatch(r"decode_tps_p50@c(\d+)", str(k))
            if hit and _num(v) is not None:
                by_c[int(hit.group(1))] = v
        if by_c:
            c = min(by_c)
            out = {"big": _g(by_c[c]), "unit": "tok/s", "cap": f"decode at concurrency {c}",
                   "spoken": f"{_g(by_c[c])} tokens per second decoding at concurrency {c}"}
    elif key == "prefill":
        by_ctx = {}
        for k, v in m.items():
            hit = re.fullmatch(r"ttft_ms_at_(\d+)", str(k))
            if hit and _num(v) is not None:
                by_ctx[int(hit.group(1))] = v
        if by_ctx:
            ctx = max(by_ctx)
            ms = by_ctx[ctx]
            big, unit = (_g(ms / 1000), "s") if ms >= 1000 else (_g(ms), "ms")
            out = {"big": big, "unit": unit, "cap": f"time to first token at {_tokens(ctx)}",
                   "spoken": f"{big} {'seconds' if unit == 's' else 'milliseconds'} to first token at {_tokens(ctx)} tokens"}
    elif key == "tool_reliability":
        rate, n = _num(m.get("parse_failure_rate")), _num(m.get("n"))
        if rate is not None:
            pct = f"{1 - rate:.0%}"
            out = {"big": pct, "unit": "", "cap": f"of {int(n)} calls parsed" if n is not None else "of calls parsed",
                   "spoken": f"{pct} of {int(n)} calls parsed" if n is not None else f"{pct} of calls parsed"}
        elif n is not None:
            out = {"big": str(int(n)), "unit": "", "cap": "calls", "spoken": f"{int(n)} calls"}
    elif key == "quality" and _num(m.get("quality_pass_rate")) is not None:
        pct = f"{m['quality_pass_rate']:.0%}"
        n = _num(m.get("n"))
        out = {"big": pct, "unit": "", "cap": f"pass rate over {int(n)} cases" if n is not None else "pass rate",
               "spoken": f"pass rate {pct}" + (f" over {int(n)} cases" if n is not None else "")}
    if out is None:
        t = clip(summary)
        return {"big": "", "unit": "", "cap": t or "no numbers recorded", "spoken": t or "no numbers recorded"}
    return out


def verdict_stage(status: dict, label, verdict_path) -> dict:
    """The last stage, from the run itself. A done run with a label shows it; a failed or aborted run never wrote a verdict;
    anything else has none yet. The label is the runner's own word for the comparison, shown only once the run is done."""
    state = str(status.get("state", ""))
    if state == "done" and (label or verdict_path):
        word = label.capitalize() if label else "Written"
        return {"state": "done", "big": word, "unit": "", "tone": "ok" if label in ("better", "same") else "warning",
                "cap": "the verdict record is written" if not label else "the runner's label for this run",
                "spoken": f"label {label}" if label else "verdict written"}
    if state in ("failed", "aborted"):
        return {"state": "failed", "big": "", "unit": "", "tone": "critical", "cap": "no verdict was written",
                "spoken": "no verdict was written"}
    return {"state": "pending", "big": "", "unit": "", "tone": "unknown", "cap": "written when every leg is done",
            "spoken": "written when every leg is done"}


def pipeline(status: dict, legs_by: dict, planned: list, label, verdict_path) -> list:
    """The run as stages left to right: Control, Smoke, Perf, Prefill, Tool calls, Quality, then Verdict. Each is
    {key, name, state, word, big, unit, cap, spoken, aria, done_of, tone}. A leg named by neither the plan nor the run is not a
    stage; a leg the run lists as skipped is a skipped stage even when the plan did not name it."""
    out = []
    for key, name, members in STAGES:
        present = [n for n in members if n in legs_by or n in planned]
        if not present:
            continue
        st = {n: (str(legs_by.get(n, {}).get("state", "queued" if n in planned else "")) or None) for n in present}
        st = {n: (v if v in LEG_STATE_WORDS else "unknown") for n, v in st.items()}
        cand_leg = key if key in st else None
        inc_leg = next((n for n in present if n != key), None)
        state = _stage_state(st.get(cand_leg), st.get(inc_leg))
        # the leg that speaks for the stage: the one running, else the failed one, else the candidate's
        speaking = next((n for n in present if st[n] == state), cand_leg or inc_leg)
        leg = legs_by.get(speaking, {})
        summary = str(leg.get("summary", "") or "")
        big, unit, cap, spoken, progress = "", "", "", "", None
        if state == "done":
            k = key_number(key, legs_by.get(key, {}).get("metrics"), summary)
            big, unit, cap, spoken = k["big"], k["unit"], k["cap"], k["spoken"]
        elif state == "running":
            hit = re.search(r"(\d+)\s+of\s+(\d+)", summary)
            if hit and int(hit.group(2)) > 0 and int(hit.group(1)) <= int(hit.group(2)):
                big, unit = hit.group(1), f"of {hit.group(2)}"
                progress = round(100 * int(hit.group(1)) / int(hit.group(2)))
                cap = clip(summary[hit.end():].strip(" ,.:;") or "so far")
            else:
                cap = clip(summary) or "in progress"
            spoken = clip(summary) or "in progress"
        elif state in ("failed", "skipped"):
            cap = clip(summary) or ("no reason was recorded" if state == "failed" else "not run")
            spoken = cap
        elif state == "queued":
            cap, spoken = "waiting for its turn", ""
        else:
            cap, spoken = "state not recognised", ""
        word = LEG_STATE_WORDS.get(state, "Unknown")
        out.append({"key": key, "name": name, "state": state, "word": word, "big": big, "unit": unit, "cap": cap,
                    "spoken": spoken, "progress": progress,
                    "aria": f"{name}: {word.lower()}" + (f", {spoken}" if spoken else "")})
    v = verdict_stage(status, label, verdict_path)
    word = {"done": "Done", "failed": "Failed", "pending": "Pending"}[v["state"]]
    out.append({"key": "verdict", "name": "Verdict", "state": "verdict-" + v["state"], "word": word, "big": v["big"], "unit": v["unit"],
                "cap": v["cap"], "spoken": v["spoken"], "tone": v["tone"], "progress": None,
                "aria": f"Verdict: {word.lower()}" + (f", {v['spoken']}" if v["state"] == "done" else "")})
    return out


def stamp(v) -> str:
    """A status timestamp as 2026-10-28 14:10 UTC, or "" when it is missing or not a time."""
    t = _ts(v) if v else None
    if t is None:
        return ""
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t.astimezone(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def rerun_ids(raw_lifecycle) -> list:
    """modelLifecycle.runner.rerun as the site set it: the run ids already listed (strings only)."""
    r = (((raw_lifecycle or {}).get("runner")) or {})
    ids = r.get("rerun") if isinstance(r, dict) else None
    return [str(x) for x in ids] if isinstance(ids, list) else []


def rerun_offer(latest, listed) -> dict:
    """What the Re-run control says for the latest run: {offer, listed, why}. Offered only for a run that is done or failed; a run
    in progress cannot be measured again, and an aborted one the runner tries again by itself."""
    if latest is None:
        return {"offer": False, "listed": False, "why": ""}
    state = latest["state"]
    if state in FINISHED:
        if latest["run_id"] in listed:
            return {"offer": False, "listed": True,
                    "why": f"A re-run of {latest['run_id']} is requested (it is listed in modelLifecycle.runner.rerun) and has not started: the runner queues it on its next pass."}
        return {"offer": True, "listed": False, "why": "Starts a new run with the same plan, under a new run id. The numbers of an earlier run stay as they are."}
    if state in IN_PROGRESS:
        return {"offer": False, "listed": False, "why": "A run is in progress, so there is nothing to re-run until it finishes."}
    if state == "aborted":
        return {"offer": False, "listed": False, "why": "This run was aborted: the runner tries an aborted run again by itself."}
    return {"offer": False, "listed": False, "why": ""}


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
    label = status.get("label") if isinstance(status.get("label"), str) else None
    verdict_path = status.get("verdict_path") if isinstance(status.get("verdict_path"), str) else None
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
        "label": label, "verdict_path": verdict_path,
        "pipeline": pipeline(status, legs_by, planned, label, verdict_path), "when": stamp(status.get("created") or updated),
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

# SPDX-License-Identifier: Apache-2.0
"""run-status/1: one JSON file per evaluation run, <statusDir>/runs/<run_id>.json.

The scheduler writes a run as `queued` or `waiting`, the Job moves it through `running` to `done`, `aborted` or `failed`,
and updates one entry of `legs` as each leg starts and finishes. The Tockmox UI reads the directory (read-only mount) and
shows what is going on; nothing here is a verdict. A status never names a winner: the verdict file, written by the
runner and counted by the promotion gate, is the only record of that.

Writes are atomic (a temporary file in the same directory, then rename), so a reader sees the old file or the new one,
never half of one. The reader skips what it cannot trust and says why, instead of refusing the whole directory.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import tempfile

SCHEMA = "run-status/1"
DEFAULT_DIR = "/var/lib/tockmox/evals"
DEFAULT_STATUS_DIR = DEFAULT_DIR       # the name the UI pages read (app/candidate.py); the chart mounts the volume here
RUNS = "runs"
STATES = ("queued", "waiting", "running", "done", "aborted", "failed")
TERMINAL = ("done", "aborted", "failed")
LEG_STATES = ("queued", "running", "done", "failed", "skipped")
TRIGGERS = ("admitted", "engine-upgrade", "request")
LEG_NAMES = ("control", "smoke", "perf", "prefill", "tool_reliability", "quality")
LABELS = ("better", "same", "worse", "inconclusive", "tradeoff")
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")
MAX_BYTES = 256 * 1024


class StatusError(ValueError):
    pass


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def runs_dir(status_dir: str) -> str:
    return os.path.join(status_dir, RUNS)


def path_for(status_dir: str, run_id: str) -> str:
    if not RUN_ID_RE.match(run_id or ""):
        raise StatusError(f"run_id {run_id!r} is not a safe file name")
    return os.path.join(runs_dir(status_dir), run_id + ".json")


def validate(d) -> list[str]:
    """Why this is not a run-status/1, as a list of sentences (empty = valid)."""
    if not isinstance(d, dict):
        return ["not a JSON object"]
    bad = []
    if d.get("schema") != SCHEMA:
        bad.append(f'schema must be "{SCHEMA}"')
    if not RUN_ID_RE.match(str(d.get("run_id") or "")):
        bad.append("run_id is missing or not a safe file name")
    if not d.get("alias") or not isinstance(d.get("alias"), str):
        bad.append("alias is missing")
    if d.get("state") not in STATES:
        bad.append(f"state must be one of {STATES}")
    if d.get("trigger") not in TRIGGERS:
        bad.append(f"trigger must be one of {TRIGGERS}")
    c = d.get("candidate")
    if not (isinstance(c, dict) and c.get("model")):
        bad.append("candidate needs a model")
    if d.get("incumbent") is not None and not (isinstance(d["incumbent"], dict) and d["incumbent"].get("model")):
        bad.append("incumbent must be null or carry a model")
    legs = d.get("legs", [])
    if not isinstance(legs, list):
        bad.append("legs must be a list")
    else:
        for lg in legs:
            if not (isinstance(lg, dict) and lg.get("name") and lg.get("state") in LEG_STATES):
                bad.append(f"a leg needs a name and a state from {LEG_STATES}")
                break
    for k in ("created", "updated"):
        if not isinstance(d.get(k), str) or not d.get(k):
            bad.append(f"{k} is missing")
    if d.get("label") is not None and d["label"] not in LABELS:
        bad.append(f"label must be null or one of {LABELS}")
    return bad


def write_status(path: str, doc: dict) -> None:
    """Validate, then write atomically. `updated` is set here, so a caller cannot forget it."""
    doc = dict(doc)
    doc.setdefault("schema", SCHEMA)
    doc.setdefault("created", now())
    doc["updated"] = now()
    bad = validate(doc)
    if bad:
        raise StatusError("; ".join(bad))
    if os.path.basename(path) != doc["run_id"] + ".json":
        raise StatusError(f"{os.path.basename(path)} is not named for run_id {doc['run_id']}")
    text = json.dumps(doc, indent=2, sort_keys=False) + "\n"
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_status(path: str) -> dict:
    if os.path.getsize(path) > MAX_BYTES:
        raise StatusError(f"larger than {MAX_BYTES >> 10} KB")
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    bad = validate(d)
    if bad:
        raise StatusError("; ".join(bad))
    if os.path.basename(path) != d["run_id"] + ".json":
        raise StatusError(f"file name does not match run_id {d['run_id']}")
    return d


def read_statuses(status_dir: str, warnings: list | None = None) -> list[dict]:
    """Every valid run-status/1 under <status_dir>/runs, newest first (by `updated`, then `created`, then run_id).
    A file that is unreadable, not JSON, over the size cap or invalid is skipped, and a sentence about it is appended
    to `warnings` when the caller passes a list. A missing directory is an empty list: nothing has run yet."""
    out = []
    d = runs_dir(status_dir)
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json") and not n.startswith("."))
    except OSError:
        return []
    for n in names:
        try:
            out.append(read_status(os.path.join(d, n)))
        except (OSError, ValueError) as e:      # json.JSONDecodeError and StatusError are ValueErrors
            if warnings is not None:
                warnings.append(f"{n}: {e}")
    out.sort(key=lambda s: (s["updated"], s["created"], s["run_id"]), reverse=True)
    return out


def new_status(run_id: str, alias: str, klass: str, candidate: dict, incumbent: dict | None, node: str, engine: dict,
               set_: dict, trigger: str, plan: dict, state: str = "queued", reason: str = "") -> dict:
    """A fresh status with every planned leg `queued`."""
    t = now()
    return {"schema": SCHEMA, "run_id": run_id, "alias": alias, "class": klass,
            "candidate": candidate, "incumbent": incumbent, "node": node, "engine": engine, "set": set_,
            "trigger": trigger, "state": state, "reason": reason, "plan": plan,
            "legs": [{"name": n, "state": "queued", "started": None, "finished": None, "summary": "", "metrics": {}}
                     for n in plan.get("legs", [])],
            "created": t, "updated": t, "verdict_path": None, "label": None, "evidence_pr": None}


def set_leg(doc: dict, name: str, state: str, summary: str = "", metrics: dict | None = None) -> dict:
    """Move one leg (added if the plan did not name it), stamping started/finished."""
    if state not in LEG_STATES:
        raise StatusError(f"leg state must be one of {LEG_STATES}")
    leg = next((x for x in doc["legs"] if x["name"] == name), None)
    if leg is None:
        leg = {"name": name, "state": "queued", "started": None, "finished": None, "summary": "", "metrics": {}}
        doc["legs"].append(leg)
    leg["state"] = state
    if state == "running":
        leg["started"] = now()
    elif state in ("done", "failed", "skipped"):
        leg["started"] = leg["started"] or now()
        leg["finished"] = now()
    if summary:
        leg["summary"] = summary
    if metrics:
        leg["metrics"] = dict(metrics)
    return doc


# ---------------------------------------------------------------- engine-upgrade comparison (TM-1264)

# How far a figure may move before an engine upgrade is called a regression. Wide on purpose: perf figures from a
# couple of dozen requests move on their own, and a status line that cries wolf teaches the reader to ignore it.
LATENCY_UP = 0.25         # ttft/complete p95 more than 25% higher
THROUGHPUT_DOWN = 0.20    # decode tokens per second more than 20% lower


def leg_metrics(doc: dict, name: str) -> dict:
    leg = next((x for x in doc.get("legs", []) if x.get("name") == name), None)
    return dict((leg or {}).get("metrics") or {})


def perf_regressions(prev: dict, cur: dict) -> list[str]:
    """Sentences about what got worse between two runs of the same build, from the smoke and perf legs' `metrics`
    (keys `smoke_*` as 0/1, and `<figure>@c<concurrency>`). Empty = nothing crossed the tolerances. A statement of fact:
    the caller records it in the status reason and never acts on it."""
    out = []
    for k in sorted(cur):
        if k.startswith("smoke_") and cur[k] != 1.0 and prev.get(k) == 1.0:
            out.append(f"{k} passed before the upgrade and fails now")
    for k in sorted(cur):
        if "@c" not in k or k not in prev or not prev[k] or not isinstance(cur[k], (int, float)):
            continue
        name = k.split("@", 1)[0]
        change = (cur[k] - prev[k]) / prev[k]
        if name in ("ttft_p95_s", "complete_p95_s") and change > LATENCY_UP:
            out.append(f"{k} {prev[k]:g} -> {cur[k]:g} ({change:+.0%})")
        elif name == "decode_tps_p50" and change < -THROUGHPUT_DOWN:
            out.append(f"{k} {prev[k]:g} -> {cur[k]:g} ({change:+.0%})")
    return out

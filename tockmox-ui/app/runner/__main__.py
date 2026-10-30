# SPDX-License-Identifier: Apache-2.0
"""python -m app.runner run REQUEST.yaml --set DIR --gateway URL --key-env VAR --node ID --engine ID
--engine-version V --out SITE_ROOT [--steps 1,2] [--perf-requests 20] [--workers 2] [--seed 1] [--health-url URL]
[--status-dir DIR --run-id ID] [--route NAME] [--legs smoke,perf,quality]
[--tool-reliability-calls 100] [--prefill-contexts 4096,16384,32768,65536] [--prefill-requests 3] [--max-input-tokens N]

python -m app.runner schedule --config /etc/tockmox-eval/config.yaml     (the scheduler CronJob; scheduler.py)
python -m app.runner evidence-pr --config C --status-dir D --run-id ID   (opens the evidence PR, records its URL)

With --status-dir and --run-id, `run` keeps <status-dir>/runs/<run-id>.json up to date (run-status/1): running when it
starts, each leg as it starts and ends, then done, aborted or failed."""
from __future__ import annotations

import argparse
import contextlib
import inspect
import io
import json
import os
import re
import sys

import httpx

from . import evalset
from . import legs
from . import status as st
from .run import RunError, load_request, run

LABEL_OF = {"better": "better", "same": "same", "worse": "worse", "inconclusive": "inconclusive", "tradeoff": "tradeoff"}


def _supported(fn, opts: dict) -> dict:
    """Only the options `fn` takes. run() takes tool_calls and prefill_contexts once the tool-reliability and prefill legs
    are in it; a run() without them still accepts the flags here and drops them instead of failing the Job."""
    names = inspect.signature(fn).parameters
    if any(p.kind is inspect.Parameter.VAR_KEYWORD for p in names.values()):
        return opts
    return {k: v for k, v in opts.items() if k in names}


class Tracker:
    """The run's status file, moved by run()'s progress callback. A no-op without --status-dir."""

    def __init__(self, status_dir, run_id):
        self.path = st.path_for(status_dir, run_id) if status_dir and run_id else ""
        self.doc = st.read_status(self.path) if self.path and os.path.exists(self.path) else None
        self.current = None

    def save(self):
        if self.doc is not None:
            st.write_status(self.path, self.doc)

    def start(self):
        if self.doc is not None:
            self.doc.update(state="running", reason="")
            self.save()

    def leg(self, name, state, summary="", metrics=None):
        self.current = name if state == "running" else None
        if self.doc is not None:
            st.set_leg(self.doc, name, state, summary, metrics)
            self.save()

    def finish(self, state, reason="", result=None):
        if self.doc is None:
            return
        d = self.doc
        if self.current and state != "done":
            st.set_leg(d, self.current, "failed", reason)
        for lg in d["legs"]:
            if lg["state"] == "queued":
                st.set_leg(d, lg["name"], "skipped", "not run: " + (reason or "this runner build has no such leg"))
        d["state"] = state
        d["reason"] = reason
        if result is not None:
            d["verdict_path"] = result.get("verdict_path")
            d["label"] = LABEL_OF.get(result.get("label") or "")
        self.save()


def _engine_upgrade_note(tr: Tracker, status_dir: str) -> str:
    """TM-1264: compare this run's smoke and perf figures with the last done run of the alias on the node. Facts only."""
    d = tr.doc
    prev = next((s for s in st.read_statuses(status_dir) if s["state"] == "done" and s["alias"] == d["alias"]
                 and s["node"] == d["node"] and s["candidate"]["model"] == d["candidate"]["model"]
                 and s["run_id"] != d["run_id"]), None)
    if prev is None:
        return "no earlier done run to compare with"
    now_m = {**st.leg_metrics(d, "smoke"), **st.leg_metrics(d, "perf")}
    was_m = {**st.leg_metrics(prev, "smoke"), **st.leg_metrics(prev, "perf")}
    pe, ce = prev.get("engine") or {}, d.get("engine") or {}
    head = f"engine {pe.get('id')} {pe.get('version')} -> {ce.get('id')} {ce.get('version')}, compared with {prev['run_id']}"
    bad = st.perf_regressions(was_m, now_m)
    return head + ("; regression: " + "; ".join(bad) if bad else "; no regression beyond the tolerances")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="python -m app.runner")
    sub = p.add_subparsers(dest="cmd", required=True)
    sc = sub.add_parser("schedule", help="decide what to evaluate next and start it (the scheduler CronJob)")
    sc.add_argument("--config", required=True)
    sc.add_argument("--dry-run", action="store_true")
    ev = sub.add_parser("evidence-pr", help="open the evidence PR for <status-dir>/site and record its URL in the run's status")
    ev.add_argument("--config", required=True)
    ev.add_argument("--status-dir", required=True)
    ev.add_argument("--run-id", required=True)
    r = sub.add_parser("run", help="run one evaluation request")
    r.add_argument("request")
    r.add_argument("--set", required=True, help="the eval-set/1 directory")
    r.add_argument("--gateway", required=True, help="the eval gateway base URL")
    r.add_argument("--key-env", default="EVAL_GATEWAY_KEY", help="environment variable holding the eval gateway key")
    r.add_argument("--node", required=True)
    r.add_argument("--engine", required=True)
    r.add_argument("--engine-version", required=True)
    r.add_argument("--quant", default="")
    r.add_argument("--out", required=True, help="the site repository root the evidence is written under")
    r.add_argument("--steps", default="1,2")
    r.add_argument("--perf-requests", type=int, default=20)
    r.add_argument("--workers", type=int, default=2)
    r.add_argument("--seed", type=int, default=1)
    r.add_argument("--tool-reliability-calls", type=int, default=100,
                   help="tool-call reliability leg: how many calls (0 switches the leg off)")
    r.add_argument("--prefill-contexts", default=",".join(str(x) for x in legs.DEFAULT_PREFILL_CONTEXTS),
                   help="prefill leg: comma-separated context lengths in tokens (empty switches the leg off)")
    r.add_argument("--prefill-requests", type=int, default=3, help="prefill leg: requests per context length")
    r.add_argument("--max-input-tokens", type=int, default=None,
                   help="the candidate route's max input tokens: longer prefill steps are skipped with the reason")
    r.add_argument("--health-url", action="append", default=[], help="GET that must answer 2xx before each leg")
    r.add_argument("--status-dir", default="", help="keep <dir>/runs/<run-id>.json (run-status/1) up to date")
    r.add_argument("--run-id", default="", help="the run's id (the scheduler's); default <class>-<alias>-<date>-<seed>")
    r.add_argument("--route", default="", help="the gateway route that serves the build under test; default <alias>-next")
    r.add_argument("--legs", default="", help="comma list of smoke,perf,quality; default all. Without quality: no verdict")
    a, _unknown = p.parse_known_args(argv)
    if a.cmd == "schedule":
        from . import scheduler
        return scheduler.main(["--config", a.config] + (["--dry-run"] if a.dry_run else []))
    if a.cmd == "evidence-pr":
        return _evidence_pr(a)
    key = os.environ.get(a.key_env, "")
    if not key:
        print(f"runner: {a.key_env} is empty", file=sys.stderr)
        return 2

    def health():
        for u in a.health_url:
            try:
                ok = httpx.get(u, timeout=10, follow_redirects=False).status_code < 300
            except httpx.HTTPError:
                ok = False
            if not ok:
                raise legs.Aborted(f"{u} is not healthy: the node is not fit to measure, so the run stops")
    try:
        contexts = tuple(int(x) for x in a.prefill_contexts.split(",") if x.strip())
    except ValueError:
        print(f"runner: --prefill-contexts must be whole numbers, got {a.prefill_contexts!r}", file=sys.stderr)
        return 2
    if a.tool_reliability_calls < 0 or a.prefill_requests < 1 or any(c < 1 for c in contexts):
        print("runner: --tool-reliability-calls must be 0 or more, --prefill-requests 1 or more, contexts above 0", file=sys.stderr)
        return 2
    tr = Tracker(a.status_dir, a.run_id)
    try:
        tr.start()
        req = load_request(a.request)
        es = evalset.load(a.set)
        opts = {"run_id": a.run_id or None, "progress": tr.leg, "route": a.route or None,
                "only": set(x for x in a.legs.split(",") if x) or None}
        opts.update(tool_calls=a.tool_reliability_calls, prefill_contexts=contexts, prefill_requests=a.prefill_requests,
                    route_info={"max_input_tokens": a.max_input_tokens} if a.max_input_tokens else None)
        res = run(req, es, gateway=a.gateway, key=key, node=a.node, engine=a.engine, engine_version=a.engine_version,
                  out=a.out, steps=tuple(int(x) for x in a.steps.split(",")), perf_requests=a.perf_requests,
                  workers=a.workers, seed=a.seed, health=health if a.health_url else None, quant=a.quant,
                  **_supported(run, opts))
    except legs.Aborted as e:
        print(f"runner: {e}", file=sys.stderr)
        tr.finish("aborted", str(e))
        return 1
    except (RunError, evalset.SetError, legs.BudgetSpent) as e:
        print(f"runner: {e}", file=sys.stderr)
        tr.finish("failed", str(e))
        return 1
    except Exception as e:      # a crash must still leave a status that says so
        tr.finish("failed", f"{type(e).__name__}: {e}"[:300])
        raise
    note = ""
    if tr.doc is not None and tr.doc["trigger"] == "engine-upgrade":
        note = _engine_upgrade_note(tr, a.status_dir)
    tr.finish("done", note, res)
    d = res["decision"]
    out = {"verdict": res["verdict"], "label": res["label"], "summary": res.get("summary"), "control": res["control"],
           "verdict_path": res["verdict_path"], "twins": [p for p, _ in res["twins"]]}
    if d:
        out.update(n=d["n"], wins=d.get("wins"), losses=d.get("losses"), ties=d.get("ties"), interval=d["interval"],
                   screening=d["screening"])
    print(json.dumps(out, indent=2))
    return 0


_OPENED = re.compile(r"^opened\s+\S+\s+(https?://\S+)", re.M)


def _evidence_pr(a) -> int:
    """`python -m app.pr_opener evidence CONFIG <status-dir>/site --apply`, and the URL it prints into the run's status."""
    from .. import pr_opener
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = pr_opener.main(["pr_opener", "evidence", a.config, os.path.join(a.status_dir, "site"), "--apply"])
    sys.stdout.write(buf.getvalue())
    m = _OPENED.search(buf.getvalue())
    if m and a.run_id:
        tr = Tracker(a.status_dir, a.run_id)
        if tr.doc is not None:
            tr.doc["evidence_pr"] = m.group(1)
            tr.save()
    return rc


if __name__ == "__main__":
    sys.exit(main())

# SPDX-License-Identifier: Apache-2.0
"""The eval runner v0 (HL-0917; DESIGN-2026-10-29-eval-runner): one evaluation request in, one evidence bundle out.

    python -m app.runner run REQUEST.yaml --set evals/sets/<class>/<version> --gateway http://tockmox-litellm-eval:4000 \
        --key-env EVAL_KEY --node <node> --engine mlx-lm --engine-version 0.32.2 --out <site repo root>

What it does, in order, and what stops it:

  1. reads the eval-request/1 and the eval-set/1; refuses a set whose classification is above `internal` (the safety
     rails, TM-1249: until a data class is enforced end to end, nothing above internal is sent to any route) and a
     request that names a hosted candidate (hosted candidates wait for the rails too);
  2. runs the KNOWN-BAD CONTROL: the set's graders against a responder that is always wrong. If the control passes,
     the run stops: graders that cannot fail prove nothing;
  3. smoke, perf and quality legs against the eval gateway (candidate as <alias>-next, incumbent as <alias>), checking
     health before each leg (aborting if the node is not fit to measure);
  4. writes one capability-result/1 twin per leg (results.write_new: immutable, dated) and one comparative-verdict/1
     whose statistics come from verdict_stats.decide (paired) or decide_absolute (no incumbent), citing every twin
     by path and sha256, with the TM-1248 fields (n, interval, label, sampling, engine, node, control).

It writes files under --out and nothing else; opening the evidence PR is `python -m app.pr_opener evidence`.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re

import yaml

from .. import models as ml
from .. import results as rs
from .. import verdict_stats as vs
from . import legs
from .evalset import EvalSet

ALLOWED_CLASSIFICATIONS = ("public", "internal")
METHOD_PATH = "evals/methodology/runner-v0.md"
METHOD_TEXT = """# Eval runner v0: methodology

Written by the Tockmox eval runner (HL-0917). Every result twin and verdict that cites this file was produced so:

- **Where.** Every request goes to the eval gateway: the candidate as `<alias>-next`, the incumbent as `<alias>`.
  Nothing reaches the production gateway.
- **The known-bad control.** Before any leg, the set's graders run against a responder that is always wrong. If half
  or more of the cases pass it, the run stops: the graders cannot tell good from bad.
- **Smoke.** Five checks, each 0 or 1: finish reason `stop`; exactly one parseable call to an offered tool; a JSON
  reply; a stream with a usage chunk, `[DONE]` and nothing after it; a random canary repeated verbatim.
- **Perf.** Streamed requests at each concurrency step, fixed prompt and `max_tokens`; time to first token p50 and
  p95, complete answer p95, decode tokens per second p50. Each figure carries its `n`. A percentile from fewer than
  100 requests is indicative only.
- **Quality.** Every case of the eval set, graded deterministically (exact, contains, regex, JSON schema, tool call,
  no tool call). Epoch 0 at temperature 0; further epochs at 0.7 with their own seeds, so epochs measure sampling
  noise and epoch 0 is the deterministic answer.
- **The verdict.** Paired per case (candidate and incumbent answer the same cases): wins, losses, ties; the exact
  sign test on the discordant pairs; a seeded paired bootstrap interval on the difference in pass rate; labels Better,
  Same, Worse, Inconclusive by fixed rules against the set's margin and minimum effect. With no incumbent, a Wilson
  lower bound on the pass rate against the set's bar. A set under 30 cases is screening: it cannot say Better.
"""


class RunError(ValueError):
    pass


def _today():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


def load_request(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        req = yaml.safe_load(f) or {}
    if req.get("schema") != "eval-request/1":
        raise RunError(f"{path}: not an eval-request/1")
    for k in ("alias", "class", "candidate"):
        if not req.get(k):
            raise RunError(f"{path}: missing {k}")
    if not ml.ALIAS_RE.match(req["alias"]) or req["alias"].endswith(ml.NEXT):
        raise RunError(f"{path}: alias must be the live alias, not a -next one")
    return req


def guard(req: dict, es: EvalSet):
    """The rails that hold until TM-1249 enforces a data class end to end."""
    if es.classification not in ALLOWED_CLASSIFICATIONS:
        raise RunError(f"eval set {es.id} is classified {es.classification}: this runner sends only public or internal "
                       "sets to any route until the data class is enforced at the eval gateway (TM-1249)")
    model = (req.get("candidate") or {}).get("model", "")
    if re.match(r"^(anthropic|openai|openrouter|google|gemini|mistral|cohere)/", model):
        raise RunError(f"{model} is a hosted candidate: hosted candidates wait for the safety rails (TM-1249)")
    if req["class"] != es.klass and req["class"] != ml.PERF:
        raise RunError(f"the request is for class {req['class']}, the set is class {es.klass}")


def run(req: dict, es: EvalSet, *, gateway: str, key: str, node: str, engine: str, engine_version: str,
        out: str, steps=(1, 2), perf_requests=20, workers=2, seed=1, health=None, today=None,
        environment=None, quant="") -> dict:
    """Run the bundle. Returns {"verdict_path", "verdict", "twins": [(path, sha)], "control", "decision"}."""
    guard(req, es)
    today = today or _today()
    alias = req["alias"]
    cand = req["candidate"]
    inc = req.get("incumbent") or {}
    absolute = not inc or req.get("criterion") == "absolute-bars"
    cand_route, inc_route = alias + ml.NEXT, alias
    env = dict(environment or {"runner": "tockmox-eval v0"})

    ctl = legs.control(es)
    if ctl["passed"]:
        raise RunError(f"the known-bad control passed {ctl['pass_rate']:.0%} of set {es.id}: its graders cannot tell "
                       "good from bad, so nothing this run measured would mean anything. Fix the set.")

    twins = []
    base = dict(date=today, node=node, model=cand["model"], revision=cand.get("revision", ""), quant=quant,
                engine_id=engine, engine_version=engine_version, plane="gateway", methodology=METHOD_PATH,
                environment=env, gateway={"route": cand_route}, tool={"id": "tockmox-eval", "version": "0"},
                workload={"seed": seed})

    sm = legs.smoke(gateway, key, cand_route, health=health)
    twins.append(rs.Result(kind="smoke", klass=es.klass, metrics=[rs.Metric(m["name"], m["value"], m["unit"], m["n"])
                                                                   for m in sm], **base))
    pm = legs.perf(gateway, key, cand_route, steps=steps, requests_per_step=perf_requests, health=health)
    twins.append(rs.Result(kind="perf", klass=es.klass, metrics=[rs.Metric(m["name"], m["value"], m["unit"], m["n"],
                                                                            m.get("concurrency")) for m in pm],
                           parallel_slots=max(steps), **base))

    cq = legs.quality(gateway, key, cand_route, es, workers=workers, seed=seed, health=health)
    cand_rate = sum(sum(x) / len(x) for x in cq) / len(cq)
    twins.append(rs.Result(kind="quality", klass=es.klass, metrics=[
        rs.Metric("quality_pass_rate", round(cand_rate, 6), "ratio", len(cq))], **base))
    if absolute:
        passed = sum(1 for x in cq if x[0])
        decision = vs.decide_absolute(passed, len(cq), es.bar)
    else:
        iq = legs.quality(gateway, key, inc_route, es, workers=workers, seed=seed, health=health)
        inc_rate = sum(sum(x) / len(x) for x in iq) / len(iq)
        ib = dict(base, model=inc["model"], revision=inc.get("revision", ""), gateway={"route": inc_route})
        twins.append(rs.Result(kind="quality", klass=es.klass, metrics=[
            rs.Metric("quality_pass_rate", round(inc_rate, 6), "ratio", len(iq))], **ib))
        decision = vs.decide(list(zip(cq, iq)), es.margin, es.min_effect, seed=seed)
    smoke_ok = all(m["value"] == 1.0 for m in sm)
    verdict = decision["verdict"]
    label = decision["label"]
    if not smoke_ok and verdict == "pass":
        verdict, label = "fail", "worse"

    written = []
    for t in twins:
        written.append(_write_twin(out, t))
    _write_method(out)
    run_id = f"{es.klass}-{alias}-{today.replace('-', '')}-{seed}"
    rec = {"schema": ml.VERDICT_SCHEMA, "run_id": run_id, "date": today, "class": es.klass, "alias": alias,
           "candidate": {k: v for k, v in cand.items() if k in ("model", "revision") and v},
           "eval_set": {"id": es.id, "version": es.version, "sha256": es.sha256}, "grader": "rule",
           "criterion": es.criterion + ("" if smoke_ok else " (smoke failed: " +
                                        ", ".join(m["name"] for m in sm if m["value"] != 1.0) + ")"),
           "verdict": verdict, "label": label, "results": [{"path": p, "sha256": h} for p, h in written],
           "methodology": METHOD_PATH, "n": decision["n"], "method": decision["method"],
           "interval": decision["interval"], "screening": decision["screening"],
           "sampling": {"temperature": 0.0, "seed": seed, "epochs": es.epochs, "max_tokens": es.max_tokens},
           "engine": {"id": engine, "version": engine_version}, "node": node, "judge": None,
           "control": {"passed": ctl["passed"], "cases": ctl["cases"]}}
    if not absolute:
        rec["incumbent"] = {k: v for k, v in inc.items() if k in ("model", "revision") and v}
        rec["discordant"] = decision["discordant"]
        rec["margin"], rec["min_effect"] = decision["margin"], decision["min_effect"]
    else:
        rec["bar"] = decision["bar"]
    if req.get("placement"):
        rec["placement"] = req["placement"]
    text = json.dumps(rec, indent=2) + "\n"
    ml.parse_verdict(text)          # a writer must never emit what the reader would refuse
    vpath = f"evals/verdicts/{run_id}.json"
    full = os.path.join(out, vpath)
    if os.path.exists(full):
        raise RunError(f"{vpath} exists: a verdict is written once")
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write(text)
    return {"verdict_path": vpath, "verdict": verdict, "label": label, "twins": written, "control": ctl,
            "decision": decision, "smoke": sm}


def _write_twin(out, r: rs.Result):
    """results.write_new, with a run-unique path for a quality leg (two classes, or the incumbent's leg, on one day)."""
    rel = rs.repo_path(r)
    if r.kind == "quality":
        rel = rel.replace("-quality-", f"-quality-{r.klass}-")
    text = rs.dumps(r)
    full = os.path.join(out, rel)
    if os.path.exists(full):
        with open(full, encoding="utf-8") as f:
            if f.read() != text:
                raise RunError(f"{rel} exists with other contents: a result is never edited, measure on another day "
                               "or with another seed")
    else:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)
    import hashlib
    return rel, hashlib.sha256(text.encode("utf-8")).hexdigest()


def _write_method(out):
    full = os.path.join(out, METHOD_PATH)
    if not os.path.exists(full):
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(METHOD_TEXT)

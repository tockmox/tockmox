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
  3. smoke, perf, prefill, tool-call reliability and quality legs against the eval gateway (candidate as
     <alias>-next, incumbent as <alias>), checking health before each leg (aborting if the node is not fit to
     measure). Prefill (TM-1268) times the first token at several context lengths; tool-call reliability (TM-1267)
     runs only for a set whose cases offer tools or class agent, and a parse-failure rate above the set's
     `tool_parse_bar` fails the verdict whatever the quality. When the set or the request carries a
     `speed_criterion` the incumbent's perf is measured too, and a quality pass that breaks the criterion reads
     "tradeoff" (TM-1269);
  4. writes one capability-result/1 twin per leg (results.write_new: immutable, dated) and one comparative-verdict/1
     whose statistics come from verdict_stats.decide (paired) or decide_absolute (no incumbent), citing every twin
     by path and sha256, with the TM-1248 fields (n, interval, label, sampling, engine, node, control) and a
     one-line `summary`.

It writes files under --out and nothing else; opening the evidence PR is `python -m app.pr_opener evidence`.
"""
from __future__ import annotations

import contextlib
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

MAX_CONTEXT_STEP = 1_000_000

ALLOWED_CLASSIFICATIONS = ("public", "internal")
METHOD_PATH = "evals/methodology/runner-v1.md"
METHOD_TEXT = """# Eval runner v1: methodology

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
- **Prefill.** Time to first token at several context lengths (default 4096, 16384, 32768, 65536), a few streamed
  requests per length, one at a time, `max_tokens` 16. The prompt is filler text sized by an estimate of four
  characters per token, not a tokenizer count, and it opens with a per-request nonce so no prefix cache can answer
  it; where the engine reports `prompt_tokens` that figure is recorded beside the estimate. A length over the
  route's maximum input is skipped and the twin says why. The figure is the median of the requests that answered,
  with its `n`.
- **Tool-call reliability.** Only for a set whose cases offer tools, or class agent. N calls (default 100) cycle
  through the set's tool-bearing cases at temperature 0.7, each with its own seed, so the figure measures variance.
  `parse_failure_rate`: a tool call whose arguments are not a JSON object, or a call printed into the reply text
  (`<tool_call>`, `[TOOL_CALLS]`, a `{"name", "arguments"}` object). `wrong_tool_rate`: the case expects a tool and the
  reply called another, an unoffered one, or none. `schema_violation_rate`: valid JSON arguments that break the
  tool's own parameters schema. Each carries its `n`. A parse-failure rate above the set's `tool_parse_bar`
  (default 0.02) fails the verdict whatever the quality, and the criterion says so.
- **Speed.** When the set or request carries a `speed_criterion` (`decode_tok_s_min_ratio`), the incumbent's perf
  leg runs too; a quality pass whose candidate decodes slower than that ratio of the incumbent's is labelled
  Tradeoff, which counts for nothing toward a promotion and resets nothing. A person decides.
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
    check_request_extras(req, path)
    return req


def check_request_extras(req: dict, path: str = "the request"):
    """The optional fields added with the prefill, tool-reliability and tradeoff legs, checked when present."""
    if req.get("speed_criterion") is not None:
        try:
            vs.check_speed_criterion(req["speed_criterion"])
        except vs.StatsError as e:
            raise RunError(f"{path}: {e}") from None
    m = req.get("max_input_tokens")
    if m is not None and (isinstance(m, bool) or not isinstance(m, int) or not 1 <= m <= MAX_CONTEXT_STEP * 10):
        raise RunError(f"{path}: max_input_tokens must be a whole number of tokens")
    t = req.get("chat_template")
    if t is not None and not (isinstance(t, str) and re.match(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,63}$", t)):
        raise RunError(f"{path}: chat_template must be a short identifier (a template name or digest)")


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
        environment=None, quant="", run_id=None, progress=None, only=None, route=None, tool_calls=100,
        prefill_contexts=legs.DEFAULT_PREFILL_CONTEXTS, prefill_requests=3, route_info=None) -> dict:
    """Run the bundle. Returns {"verdict_path", "verdict", "label", "twins": [(path, sha)], "control", "decision",
    "smoke", "perf", "summary", "tool_reliability", "prefill", "run_id"}.

    run_id      the id the scheduler gave this run (its run-status/1 file carries it); default <class>-<alias>-<date>-<seed>.
    only        a set of leg names ("smoke", "perf", "quality"); default all. Without "quality" the run writes the smoke
                and perf twins and NO verdict: there is nothing to decide (the engine-upgrade re-evaluation, TM-1264).
                The control, prefill and tool-reliability legs ride with "quality".
    route       the gateway route that serves the build under test; default <alias>-next.
    tool_calls  0 switches the tool-reliability leg off; `prefill_contexts` () switches the prefill leg off.
    route_info  the candidate route's model_info (its max_input_tokens bounds the prefill steps).

    `progress(leg, state, summary="", metrics=None)` is told how the run goes (run-status/1 legs): legs in order control,
    smoke, perf, [perf_incumbent], prefill, tool_reliability, quality, [quality_incumbent]; state "running" at a leg's
    start, "done" at its end (summary one plain line, never a winner; metrics the partial numbers), "skipped" with the
    reason in `summary`, "failed" with the reason just before the exception propagates. A callback that raises is
    ignored."""
    guard(req, es)
    check_request_extras(req)
    today = today or _today()
    alias = req["alias"]
    cand = req["candidate"]
    inc = req.get("incumbent") or {}
    absolute = not inc or req.get("criterion") == "absolute-bars"
    cand_route, inc_route = route or alias + ml.NEXT, alias
    env = dict(environment or {"runner": "tockmox-eval v0"})
    only = set(only or ("smoke", "perf", "quality"))
    pg = _Progress(progress)
    run_id = run_id or f"{es.klass}-{alias}-{today.replace('-', '')}-{seed}"
    # TM-1295: a run id that already has a verdict is refused before any leg runs, not after an hour of them
    if "quality" in only and os.path.exists(os.path.join(out, "evals", "verdicts", f"{run_id}.json")):
        raise RunError(f"evals/verdicts/{run_id}.json already exists: a run id is used once (give this run another id, "
                       "or another seed)")

    if "quality" in only:
        with pg.leg("control"):
            ctl = legs.control(es)
            if ctl["passed"]:
                raise RunError(f"the known-bad control passed {ctl['pass_rate']:.0%} of set {es.id}: its graders cannot "
                               "tell good from bad, so nothing this run measured would mean anything. Fix the set.")
            pg.done("control", f"the known-bad control passed {ctl['pass_rate']:.0%} of {ctl['cases']} cases (it must not)",
                    {"control_pass_rate": ctl["pass_rate"], "cases": ctl["cases"]})
    else:
        ctl = {"passed": False, "cases": 0, "pass_rate": 0.0}
        pg.emit("control", "skipped", "no quality leg in this run: nothing is graded")

    twins = []
    base = dict(date=today, node=node, model=cand["model"], revision=cand.get("revision", ""), quant=quant,
                engine_id=engine, engine_version=engine_version, plane="gateway", methodology=METHOD_PATH,
                environment=env, gateway={"route": cand_route}, tool={"id": "tockmox-eval", "version": "1"},
                workload={"seed": seed}, run=run_id)

    sm, pm = [], []
    if "smoke" in only:
        with pg.leg("smoke"):
            sm = legs.smoke(gateway, key, cand_route, health=health)
            twins.append(rs.Result(kind="smoke", klass=es.klass, metrics=[rs.Metric(m["name"], m["value"], m["unit"], m["n"])
                                                                           for m in sm], **base))
            bad = [m["name"] for m in sm if m["value"] != 1.0]
            pg.done("smoke", f"{len(sm) - len(bad)} of {len(sm)} checks passed" + (f"; failed: {', '.join(bad)}" if bad else ""),
                    {m["name"]: m["value"] for m in sm})
    else:
        pg.emit("smoke", "skipped", "not asked for in this run")
    if "perf" in only:
        with pg.leg("perf"):
            pm = legs.perf(gateway, key, cand_route, steps=steps, requests_per_step=perf_requests, health=health)
            twins.append(rs.Result(kind="perf", klass=es.klass, metrics=[rs.Metric(m["name"], m["value"], m["unit"], m["n"],
                                                                                    m.get("concurrency")) for m in pm],
                                   parallel_slots=max(steps), **base))
            pg.done("perf", _perf_line(pm, steps, perf_requests), _perf_metrics(pm))
    else:
        pg.emit("perf", "skipped", "not asked for in this run")
    if "quality" not in only:
        for leg in ("prefill", "tool_reliability", "quality"):
            pg.emit(leg, "skipped", "an engine re-evaluation: smoke and perf only, no verdict")
        written = [_write_twin(out, t) for t in twins]
        _write_method(out)
        return {"verdict_path": None, "verdict": None, "label": None, "twins": written, "control": ctl,
                "decision": None, "smoke": sm, "perf": pm, "summary": None, "tool_reliability": None, "prefill": None,
                "run_id": run_id}
    speed_criterion = vs.check_speed_criterion(req.get("speed_criterion") or es.speed_criterion) \
        if (req.get("speed_criterion") or es.speed_criterion) else {}
    inc_pm = None
    if speed_criterion and not absolute:
        with pg.leg("perf_incumbent"):
            inc_pm = legs.perf(gateway, key, inc_route, steps=steps, requests_per_step=perf_requests, health=health)
            ib0 = dict(base, model=inc["model"], revision=inc.get("revision", ""), gateway={"route": inc_route})
            twins.append(rs.Result(kind="perf", klass=es.klass, metrics=[rs.Metric(m["name"], m["value"], m["unit"], m["n"],
                                                                                    m.get("concurrency")) for m in inc_pm],
                                   parallel_slots=max(steps), **ib0))
            pg.done("perf_incumbent", _perf_line(inc_pm, steps, perf_requests), _perf_metrics(inc_pm))

    max_in = req.get("max_input_tokens") or (route_info or {}).get("max_input_tokens")
    pf = None
    if not prefill_contexts:
        pg.emit("prefill", "skipped", "turned off: no context lengths were asked for")
    else:
        with pg.leg("prefill"):
            pf = legs.prefill(gateway, key, cand_route, contexts=tuple(prefill_contexts), requests_per_step=prefill_requests,
                              max_input_tokens=max_in, seed=seed, health=health)
            done = [x for x in pf if x["state"] == "measured"]
            if done:
                pm_rows = [rs.Metric(f"ttft_ms_at_{x['context']}", x["ttft_ms_p50"], "ms", x["n"], context_tokens=x["context"])
                           for x in done]
                pm_rows += [rs.Metric(f"prompt_tokens_at_{x['context']}", x["prompt_tokens"], "tokens", x["n"], context_tokens=x["context"])
                            for x in done if x.get("prompt_tokens")]
                penv = dict(env, context_estimate=f"{legs.CHARS_PER_TOKEN} characters per token (approximate, not a tokenizer count)",
                            requests_per_step=prefill_requests, **_engine_env(engine, engine_version, req))
                for x in pf:
                    if x["state"] != "measured":
                        penv[f"{x['state']}_at_{x['context']}"] = x["reason"][:200]
                twins.append(rs.Result(kind="prefill", klass=es.klass, metrics=pm_rows,
                                       **dict(base, environment=penv)))
            left = [f"{x['context']} {x['state']}" for x in pf if x["state"] != "measured"]
            pg.done("prefill", f"{len(done)} of {len(pf)} context lengths measured" + (f" ({', '.join(left)})" if left else ""),
                    {f"ttft_ms_at_{x['context']}": x["ttft_ms_p50"] for x in done})

    tr, tr_source = None, ""
    if not tool_calls:
        pg.emit("tool_reliability", "skipped", "turned off: 0 calls were asked for")
    elif not (es.tool_cases() or req["class"] == "agent" or es.klass == "agent"):
        pg.emit("tool_reliability", "skipped", "the set offers no tools and the class is not agent")
    else:
        with pg.leg("tool_reliability"):
            tcases = es.tool_cases()
            tr_source = "set" if tcases else "built-in"
            tr = legs.tool_reliability(gateway, key, cand_route, tcases or legs.builtin_tool_cases(), calls=tool_calls,
                                       workers=workers, seed=seed, max_tokens=es.max_tokens, health=health)
            tenv = dict(env, tool_parse_bar=es.tool_parse_bar, temperature=0.7, cases_from=tr_source,
                        calls=tr["n"], **_engine_env(engine, engine_version, req))
            twins.append(rs.Result(kind="tool_reliability", klass=es.klass, metrics=[
                rs.Metric("parse_failure_rate", tr["parse_failure_rate"], "ratio", tr["answered"]),
                rs.Metric("wrong_tool_rate", tr["wrong_tool_rate"], "ratio", tr["n_expected"]),
                rs.Metric("schema_violation_rate", tr["schema_violation_rate"], "ratio", tr["n_parsed"]),
                rs.Metric("call_error_rate", round(tr["errors"] / tr["n"], 6), "ratio", tr["n"])],
                **dict(base, environment=tenv, workload={"seed": seed, "temperature": 0.7})))
            pg.done("tool_reliability", f"{tr['n']} calls: tool-call parse failures {tr['parse_failure_rate']:.1%}, "
                    f"wrong tool {tr['wrong_tool_rate']:.1%}, schema violations {tr['schema_violation_rate']:.1%}",
                    {k: tr[k] for k in ("n", "parse_failure_rate", "wrong_tool_rate", "schema_violation_rate")})

    with pg.leg("quality"):
        cq = legs.quality(gateway, key, cand_route, es, workers=workers, seed=seed, health=health)
        cand_rate = sum(sum(x) / len(x) for x in cq) / len(cq)
        twins.append(rs.Result(kind="quality", klass=es.klass, metrics=[
            rs.Metric("quality_pass_rate", round(cand_rate, 6), "ratio", len(cq))], **base))
        pg.done("quality", f"{len(cq)} cases, pass rate {cand_rate:.3f}", {"quality_pass_rate": round(cand_rate, 6), "n": len(cq)})
    if absolute:
        passed = sum(1 for x in cq if x[0])
        decision = vs.decide_absolute(passed, len(cq), es.bar)
    else:
        with pg.leg("quality_incumbent"):
            iq = legs.quality(gateway, key, inc_route, es, workers=workers, seed=seed, health=health)
            inc_rate = sum(sum(x) / len(x) for x in iq) / len(iq)
            ib = dict(base, model=inc["model"], revision=inc.get("revision", ""), gateway={"route": inc_route})
            twins.append(rs.Result(kind="quality", klass=es.klass, metrics=[
                rs.Metric("quality_pass_rate", round(inc_rate, 6), "ratio", len(iq))], **ib))
            pg.done("quality_incumbent", f"{len(iq)} cases, pass rate {inc_rate:.3f}",
                    {"quality_pass_rate": round(inc_rate, 6), "n": len(iq)})
        decision = vs.decide(list(zip(cq, iq)), es.margin, es.min_effect, seed=seed)
    cand_tps = _decode_tps(pm, min(steps))
    inc_tps = _decode_tps(inc_pm, min(steps)) if inc_pm else None
    decision = vs.apply_speed(decision, speed_criterion if not absolute else None, cand_tps, inc_tps)
    smoke_ok = all(m["value"] == 1.0 for m in sm)
    verdict = decision["verdict"]
    label = decision["label"]
    if not smoke_ok and verdict == "pass":
        verdict, label = "fail", "worse"
    tool_bad = tr is not None and tr["parse_failure_rate"] > es.tool_parse_bar
    if tool_bad and verdict != "fail":
        verdict, label = "fail", "worse"
    notes = ""
    if tool_bad:
        k = round(tr["parse_failure_rate"] * tr["answered"])
        notes += (f" (tool-call parse failures {tr['parse_failure_rate']:.1%} ({k} of {tr['answered']} calls) are above this set's "
                  f"bar of {es.tool_parse_bar:.1%}: the candidate fails whatever its quality)")
    if speed_criterion and absolute:
        notes += " (speed criterion not applied: there is no incumbent to compare decode speed with)"
    if decision.get("speed_note"):
        notes += f" ({decision['speed_note']})"
    summary = vs.summary_line(decision, tr, es.tool_parse_bar if tr else None)

    written = []
    for t in twins:
        written.append(_write_twin(out, t))
    _write_method(out)
    rec = {"schema": ml.VERDICT_SCHEMA, "run_id": run_id, "date": today, "class": es.klass, "alias": alias,
           "candidate": {k: v for k, v in cand.items() if k in ("model", "revision") and v},
           "eval_set": {"id": es.id, "version": es.version, "sha256": es.sha256}, "grader": "rule",
           "criterion": es.criterion + ("" if smoke_ok else " (smoke failed: " +
                                        ", ".join(m["name"] for m in sm if m["value"] != 1.0) + ")") + notes,
           "verdict": verdict, "label": label, "summary": summary, "results": [{"path": p, "sha256": h} for p, h in written],
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
    if tr is not None:
        rec["tool_reliability"] = {"parse_failure_rate": tr["parse_failure_rate"], "wrong_tool_rate": tr["wrong_tool_rate"],
                                   "schema_violation_rate": tr["schema_violation_rate"], "n": tr["n"], "bar": es.tool_parse_bar}
    if speed_criterion and not absolute:
        rec["speed_criterion"] = speed_criterion
    if decision.get("speed"):
        rec["speed"] = decision["speed"]
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
            "decision": decision, "smoke": sm, "perf": pm, "summary": summary, "tool_reliability": tr, "prefill": pf,
            "run_id": run_id}


class _Progress:
    """Calls the caller's progress callback and never lets it break a run."""
    def __init__(self, cb):
        self.cb = cb

    def emit(self, leg, state, summary="", metrics=None):
        if self.cb is None:
            return
        try:
            self.cb(leg, state, summary, metrics)
        except Exception:
            pass

    def done(self, leg, summary, metrics=None):
        self.emit(leg, "done", summary, metrics)

    @contextlib.contextmanager
    def leg(self, name):
        self.emit(name, "running")
        try:
            yield
        except BaseException as e:
            self.emit(name, "failed", (str(e) or type(e).__name__)[:300])
            raise


def _perf_metrics(pm) -> dict:
    return {f"{m['name']}@c{m['concurrency']}": m["value"] for m in pm}


def _perf_line(pm, steps, requests) -> str:
    t = _decode_tps(pm, min(steps))
    return f"{requests} requests at each of concurrency {', '.join(str(c) for c in steps)}" + \
        (f"; decode {t:g} tokens/s at concurrency {min(steps)}" if t else "")


def _engine_env(engine, version, req) -> dict:
    """What a leg's twin names about the serving stack: the engine and version, and the chat template when the request
    says which one the build was served with (a template change moves tool-call behaviour more than most engine flags)."""
    e = {"engine": f"{engine} {version}"}
    if req.get("chat_template"):
        e["chat_template"] = req["chat_template"]
    return e


def _decode_tps(metrics, concurrency):
    m = next((x for x in metrics or [] if x["name"] == "decode_tps_p50" and x.get("concurrency") == concurrency), None)
    return m["value"] if m and m["value"] > 0 else None


def _write_twin(out, r: rs.Result):
    """results.write_new's rule (a twin is never edited) at results.repo_path's name, which carries the run id."""
    rel = rs.repo_path(r)
    text = rs.dumps(r)
    full = os.path.join(out, rel)
    if os.path.exists(full):
        with open(full, encoding="utf-8") as f:
            if f.read() != text:
                raise RunError(f"{rel} exists with other contents: a result is never edited (this run id already wrote "
                               "it; give the run another id)")
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

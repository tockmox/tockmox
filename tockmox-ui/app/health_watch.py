# SPDX-License-Identifier: Apache-2.0
"""The production health watch (REQ-0048 AC-48.19, TM-1263, TM-1274): is a promoted alias doing worse than what it replaced?

    python -m app.health_watch CONFIG.yaml            # judge every promoted alias, print the status, touch nothing
    python -m app.health_watch CONFIG.yaml --apply    # and, on a breach, open the revert PR and send the ntfy message

A small CronJob in the UI image (modelLifecycle.healthWatch, off by default) runs this every 15 minutes. It reads the
gateway's metrics from Prometheus and, for each promoted alias that records promotion.previous, compares the alias
now with the alias before the promotion, on three signals:

    error rate               non-2xx share of litellm_proxy_total_requests_metric_total{requested_model=<alias>}
    p95 latency              histogram_quantile(0.95) of litellm_request_total_latency_metric_bucket{requested_model=<alias>}
    tool-call parse failures UNKNOWN until the gateway hook counts them (see TOOL_PARSE_TODO); a site that adds the two
                             counters names them in healthWatch.rules.toolParseMetrics and it is judged like error rate
    thumbs                   UNKNOWN: neither the console nor Prometheus exposes them today (THUMBS_TODO)

Metrics are LiteLLM's own, the names the alert pack already uses (charts/tockmox-observability alert-pack.yaml). The alias
IS the history: requested_model=<alias> before the promotion is what the previous model did, so there is no per-model
series to join. When the promotion time is not recorded (promotion.promotedAt; nothing writes it yet) it is found in
Prometheus as the first hour in which the gateway's `model` label on the alias's latency histogram names the promoted model.

HOW A JUDGEMENT IS MADE (the rules are values, rules.*):
  - Every instant is a trailing window (rules.windowMinutes, default 60) ending on a 15-minute grid. The alias is judged at
    the last forMinutes/15 + 1 instants, and a breach must hold at ALL of them (rules.forMinutes, default 30).
  - LIKE HOURS (TM-1274; rules.likeHours, default on): the baseline of an instant is the same window at the same time of
    day on each of the baselineDays before the promotion, pooled (sum of errors over sum of requests), not a flat mean
    over the week. A model that is busier and slower at 14:00 than at 03:00 is not worse at 14:00. Off, the baseline is
    every window before the promotion.
  - PROVISIONAL: when the alias has no history before the promotion (a new alias, or Prometheus retention shorter than
    the promotion), the alias's own first 24 hours are the baseline, windows within an hour of the same time of day, and
    nothing is judged until those 24 hours are over. Every line says "provisional".
  - minRequests: a window or baseline with fewer requests is never judged (insufficient-data), whatever its ratio.
  - A breach needs the current value above ratio x the baseline, and the baseline is floored (errorRateFloor) so a
    baseline of zero failures does not make one failure a breach.
  - Only inside soakDays of the promotion.

PER ALIAS, ONE OF: ok | breach | inconclusive | insufficient-data, with reasons.
  breach            every judged window held the breach for forMinutes and no signal is inconclusive
  inconclusive      a signal cannot be trusted this run (Prometheus did not answer, the series has a hole, or the breach
                    has not yet held for forMinutes). It PAUSES: nothing is rendered, nothing is reverted (AC-48.19)
  insufficient-data too few requests, no baseline yet, no promotion time, or no promotion.previous. Never a breach
  ok                judged and within the limits, or past the soak window

A BREACH renders models.revert's change (AC-48.18) for the alias. With healthWatch.pullRequests it opens that change as a
PR through app.pr_opener's Forge (the watcher's opener config and secrets), and with notify.ntfyUrl it sends an ntfy message.
Nothing merges anything: autoRevert.<alias> only marks the PR (title, commit trailer, a label on GitHub) as one the site's
auto-merge may take. It is off for every alias unless the site turns it on, and an inconclusive or insufficient alias is
never marked. The status goes to the job log (and, with pullRequests, into the PR body): the CronJob has no volume.

Stdlib, httpx and PyYAML; reuses app.models (revert, change_doc), app.pr_opener (Forge, PRSpec) and app.nodes.
"""
from __future__ import annotations

import json
import math
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

import httpx
import yaml

from . import models as ml
from . import nodes as nm
from . import pr_opener as po

SCHEMA = "health-watch/1"
OK, BREACH, INCONCLUSIVE, INSUFFICIENT = "ok", "breach", "inconclusive", "insufficient-data"
UNKNOWN = "unknown"       # a signal that does not exist (metric level only; never changes an alias's state)
STEP = 900                # the grid of instants, seconds (the CronJob's own period)
DAY = 86400

REQUESTS = "litellm_proxy_total_requests_metric_total"
LATENCY = "litellm_request_total_latency_metric"

TOOL_PARSE_TODO = ("tool-call parse failures are not judged: nothing at the gateway hook counts them (the policy gate, "
                   "charts/tockmox-ai/files/policy-gate/tockmox_gate.py, exports only tockmox_gate_decisions_total and "
                   "tockmox_audit_emit_failures_total). TODO: a hook counter of responses whose tool_calls arguments are not "
                   "valid JSON, and one of tool-using responses, both labelled requested_model; name them in "
                   "modelLifecycle.healthWatch.rules.toolParseMetrics.{failures,total}")
THUMBS_TODO = ("thumbs are not judged: the console does not expose them to Prometheus or to this job. TODO: a gauge or counter "
               "of up and down votes per requested_model from the console (Open WebUI feedback)")


# ---------------------------------------------------------------- rules

@dataclass
class Rules:
    error_rate_ratio: float = 2.0
    p95_ratio: float = 1.5
    tool_parse_failure_ratio: float = 2.0
    min_requests: int = 50
    for_minutes: int = 30
    like_hours: bool = True
    window_minutes: int = 60
    baseline_days: int = 7
    error_rate_floor: float = 0.01
    tool_parse_failures: str = ""
    tool_parse_total: str = ""

    @property
    def window(self) -> int:
        return self.window_minutes * 60

    @property
    def instants(self) -> int:
        return max(0, -(-self.for_minutes * 60 // STEP)) + 1


def parse_rules(raw: dict | None) -> Rules:
    r = Rules()
    raw = raw or {}

    def num(key, attr, lo, integer=False):
        if key in raw:
            try:
                v = float(raw[key])
            except (TypeError, ValueError):
                raise ValueError(f"healthWatch.rules.{key} must be a number") from None
            if not (v >= lo) or math.isinf(v):
                raise ValueError(f"healthWatch.rules.{key} must be at least {lo}")
            setattr(r, attr, int(v) if integer else v)

    num("errorRateRatio", "error_rate_ratio", 1.0)
    num("p95Ratio", "p95_ratio", 1.0)
    num("toolParseFailureRatio", "tool_parse_failure_ratio", 1.0)
    num("minRequests", "min_requests", 1, True)
    num("forMinutes", "for_minutes", 0, True)
    num("windowMinutes", "window_minutes", 15, True)
    num("baselineDays", "baseline_days", 1, True)
    num("errorRateFloor", "error_rate_floor", 0.0)
    if r.window_minutes % 15:
        raise ValueError("healthWatch.rules.windowMinutes must be a multiple of 15")
    if "likeHours" in raw:
        r.like_hours = bool(raw["likeHours"])
    tp = raw.get("toolParseMetrics") or {}
    r.tool_parse_failures, r.tool_parse_total = str(tp.get("failures") or ""), str(tp.get("total") or "")
    if bool(r.tool_parse_failures) != bool(r.tool_parse_total):
        raise ValueError("healthWatch.rules.toolParseMetrics needs both failures and total, or neither")
    for n in (r.tool_parse_failures, r.tool_parse_total):
        if n and not re.match(r"^[a-zA-Z_:][a-zA-Z0-9_:]*$", n):
            raise ValueError(f"healthWatch.rules.toolParseMetrics: {n!r} is not a metric name")
    return r


# ---------------------------------------------------------------- Prometheus

class PromError(RuntimeError):
    pass


class Prom:
    """Range queries only, returning {timestamp: value} per series. Any failure is a PromError, which a judgement turns
    into `inconclusive`: a watch that cannot read Prometheus must not read that as health, or as a breach."""

    def __init__(self, url: str, timeout: float = 20.0, transport=None):
        self.url, self.timeout, self.transport = url.rstrip("/"), timeout, transport

    def range(self, query: str, start: int, end: int, step: int) -> list[tuple[dict, dict[int, float]]]:
        try:
            with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport, follow_redirects=False) as c:
                r = c.get("/api/v1/query_range", params={"query": query, "start": start, "end": end, "step": step})
                r.raise_for_status()
                doc = r.json()
            if doc.get("status") != "success":
                raise PromError(f"Prometheus said {doc.get('status')!r}: {str(doc.get('error', ''))[:120]}")
            out = []
            for s in doc["data"]["result"]:
                vals = {}
                for ts, v in s.get("values") or []:
                    f = float(v)
                    if not math.isnan(f):
                        vals[int(round(float(ts)))] = f
                out.append((s.get("metric") or {}, vals))
            return out
        except PromError:
            raise
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as e:
            raise PromError(f"{type(e).__name__}: {str(e)[:160]}") from None


def _lbl(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _sum(series) -> dict[int, float]:
    out: dict[int, float] = {}
    for _, vals in series:
        for ts, v in vals.items():
            out[ts] = out.get(ts, 0.0) + v
    return out


def _le(s) -> float:
    return math.inf if s in ("+Inf", "Inf", "inf") else float(s)


@dataclass
class Data:
    total: dict = field(default_factory=dict)
    errors: dict = field(default_factory=dict)
    buckets: dict = field(default_factory=dict)       # le -> {ts: cumulative count in the window}
    tool_fail: dict | None = None
    tool_total: dict | None = None


def fetch(prom: Prom, alias: str, start: int, end: int, rules: Rules) -> Data:
    w, a = f"{rules.window_minutes}m", _lbl(alias)
    d = Data()
    d.total = _sum(prom.range(f'sum(increase({REQUESTS}{{requested_model="{a}"}}[{w}]))', start, end, STEP))
    d.errors = _sum(prom.range(f'sum(increase({REQUESTS}{{requested_model="{a}",status_code!~"2.."}}[{w}]))', start, end, STEP))
    for m, vals in prom.range(f'sum by (le) (increase({LATENCY}_bucket{{requested_model="{a}"}}[{w}]))', start, end, STEP):
        try:
            d.buckets[_le(m["le"])] = vals
        except (KeyError, ValueError):
            continue
    if rules.tool_parse_failures:
        d.tool_fail = _sum(prom.range(f'sum(increase({rules.tool_parse_failures}{{requested_model="{a}"}}[{w}]))', start, end, STEP))
        d.tool_total = _sum(prom.range(f'sum(increase({rules.tool_parse_total}{{requested_model="{a}"}}[{w}]))', start, end, STEP))
    return d


def detect_promotion(prom: Prom, alias: str, model: str, now: int, soak_days: int) -> tuple[int | None, bool]:
    """(start of the first hour in which `model` served `alias`, True when that is older than the look-back).
    Reads the gateway's `model` label on the alias's latency histogram: it must contain the promoted model's id
    (the route's model, with or without a provider prefix)."""
    if "`" in model:
        return None, False
    end = now - now % 3600
    start = end - (soak_days + 1) * DAY
    rx = re.escape(model)
    q = f'sum(increase({LATENCY}_count{{requested_model="{_lbl(alias)}",model=~`(.+/)?{rx}`}}[1h]))'
    vals = _sum(prom.range(q, start, end, 3600))
    seen = sorted(ts for ts, v in vals.items() if v > 0)
    if not seen:
        return None, False
    if seen[0] - start <= 3600:
        return start, True
    return seen[0] - 3600, False


# ---------------------------------------------------------------- the arithmetic (pure)

def quantile(q: float, cum: dict[float, float]) -> float | None:
    """histogram_quantile over cumulative bucket counts {le: count}; None when the histogram is empty."""
    items = sorted(cum.items())
    if not items or items[-1][0] != math.inf or items[-1][1] <= 0:
        return None
    rank = q * items[-1][1]
    prev_le, prev_c = 0.0, 0.0
    for le, c in items:
        if c >= rank:
            if le == math.inf:
                return prev_le
            return le if c == prev_c else prev_le + (le - prev_le) * (rank - prev_c) / (c - prev_c)
        prev_le, prev_c = le, c
    return prev_le


def baseline_stamps(t: int, promoted: int, mode: str, rules: Rules) -> list[int]:
    """The end times of the baseline windows for the instant t. `promoted` is on the grid. Windows never overlap the
    promoted model's traffic (previous) or the current window (provisional)."""
    w = rules.window
    if mode == "previous":
        lo = promoted - rules.baseline_days * DAY
        if rules.like_hours:
            out, d = [], 1
            while t - d * DAY > lo:
                x = t - d * DAY
                if x <= promoted:
                    out.append(x)
                d += 1
            return out
        return [promoted - j * w for j in range(0, (promoted - lo) // w)]
    first, last = promoted + w, promoted + DAY
    if rules.like_hours:
        # one day of history: the windows within an hour of the same time of day, side by side
        base = t - ((t - promoted) // DAY) * DAY
        cand = {base + j * w for j in (-1, 0, 1)} | {base - DAY + j * w for j in (-1, 0, 1)}
        return sorted(x for x in cand if first <= x <= last)
    return [x for x in range(first, last + 1, w)]


def _ratio_instant(num: dict, den: dict, t: int, stamps: list[int], limit: float, rules: Rules):
    cd = den.get(t)
    if cd is None:
        return "missing", {}
    bd = sum(den.get(s, 0.0) for s in stamps)
    if cd < rules.min_requests or bd < rules.min_requests:
        return "nodata", {"requests": cd, "baselineRequests": bd}
    cur, base = num.get(t, 0.0) / cd, sum(num.get(s, 0.0) for s in stamps) / bd
    info = {"value": cur, "baseline": base, "requests": cd, "baselineRequests": bd}
    return ("breach" if cur > limit * max(base, rules.error_rate_floor) else "ok"), info


def _p95_instant(buckets: dict, t: int, stamps: list[int], limit: float, rules: Rules):
    inf = buckets.get(math.inf)
    if inf is None or t not in inf:
        return "missing", {}
    cur = {le: v[t] for le, v in buckets.items() if t in v}
    base = {le: sum(v.get(s, 0.0) for s in stamps) for le, v in buckets.items()}
    cd, bd = cur.get(math.inf, 0.0), base.get(math.inf, 0.0)
    if cd < rules.min_requests or bd < rules.min_requests:
        return "nodata", {"requests": cd, "baselineRequests": bd}
    cq, bq = quantile(0.95, cur), quantile(0.95, base)
    if cq is None or not bq:
        return "nodata", {"requests": cd, "baselineRequests": bd}
    return ("breach" if cq > limit * bq else "ok"), {"value": cq, "baseline": bq, "requests": cd, "baselineRequests": bd}


def metric_state(instants: list[tuple[str, dict]]) -> tuple[str, str]:
    """(state, why) from the judgements at the instants, oldest first.

    breach needs every instant to breach. A breach at the newest instant that has not held is `inconclusive` (it waits);
    a hole in the series is `inconclusive`; no data at all, or none at the newest instant, is `insufficient-data`."""
    st = [s for s, _ in instants]
    if "missing" in st and any(s != "missing" for s in st):
        return INCONCLUSIVE, "the series has a hole in the judged window (a scrape gap, or traffic stopped)"
    if all(s == "missing" for s in st):
        return INSUFFICIENT, "no requests reached the alias in the judged window"
    newest = st[-1]
    if newest == "breach":
        if all(s == "breach" for s in st):
            return BREACH, ""
        held = sum(1 for s in st if s == "breach")
        return INCONCLUSIVE, f"over the limit now but not yet held (the limit was exceeded at {held} of {len(st)} judged windows)"
    if newest == "ok":
        return OK, ""
    return INSUFFICIENT, "fewer than minRequests in the window or its baseline"


def _fmt(kind: str, v: float) -> str:
    return f"{v * 100:.1f}%" if kind != "p95" else f"{v:.1f}s"


# ---------------------------------------------------------------- one alias

def _combine(metrics: dict) -> tuple[str, list[str]]:
    judged = {k: m for k, m in metrics.items() if m["state"] != UNKNOWN}
    reasons = []
    for k, m in judged.items():
        if m["state"] != OK:
            reasons.append(f"{k}: {m['reason']}")
    for k, m in metrics.items():
        if m["state"] == UNKNOWN:
            reasons.append(f"{k}: unknown ({m['reason'].split(':')[0]})")
    states = {m["state"] for m in judged.values()}
    if INCONCLUSIVE in states:
        return INCONCLUSIVE, reasons                      # AC-48.19: an inconclusive signal pauses and never reverts
    if BREACH in states:
        return BREACH, reasons
    if states and states == {INSUFFICIENT}:
        return INSUFFICIENT, reasons
    if OK in states:
        return OK, reasons
    return INSUFFICIENT, reasons or ["no signal could be judged"]


def evaluate(alias: str, model: str, rec: dict, prom: Prom, rules: Rules, soak_days: int, now: int) -> dict:
    prev = rec.get("previous")
    out = {"alias": alias, "model": model, "previous": (prev or {}).get("model"), "state": INSUFFICIENT, "reasons": [],
           "baseline": "none", "promotedAt": None, "metrics": {}}

    def done(state, *reasons):
        out["state"], out["reasons"] = state, list(reasons)
        return out

    if not isinstance(prev, dict) or not prev.get("model"):
        return done(INSUFFICIENT, "the promotion records no previous route (it predates promotion.previous, or the alias was new): "
                                  "there is nothing to compare with and nothing to revert to")
    try:
        if rec.get("promotedAt"):
            promoted, older = _parse_time(rec["promotedAt"]), False
        else:
            promoted, older = detect_promotion(prom, alias, model, now, soak_days)
    except PromError as e:
        return done(INCONCLUSIVE, f"Prometheus did not answer when looking for the promotion time: {e}")
    except ValueError as e:
        return done(INSUFFICIENT, f"promotion.promotedAt is not a time: {e}")
    if promoted is None:
        return done(INSUFFICIENT, f"no request has reached {model} through {alias} in the last {soak_days + 1} days "
                                  "(the gateway's `model` label on the latency histogram must name the promoted model)")
    if older or now > promoted + soak_days * DAY:
        return done(OK, f"past the {soak_days}-day soak window: {alias} is no longer watched")
    out["promotedAt"] = datetime.fromtimestamp(promoted, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    pg = promoted - promoted % STEP
    w = rules.window
    t_now = now - now % STEP
    ts = [t_now - j * STEP for j in range(rules.instants)][::-1]
    try:
        d = fetch(prom, alias, pg - rules.baseline_days * DAY, t_now, rules)
    except PromError as e:
        return done(INCONCLUSIVE, f"Prometheus did not answer: {e}")

    # previous history: enough requests in non-overlapping windows before the promotion
    prior = sum(d.total.get(pg - j * w, 0.0) for j in range(0, rules.baseline_days * DAY // w))
    mode = "previous" if prior >= rules.min_requests else "provisional"
    out["baseline"] = mode
    if mode == "previous" and not any(s <= pg for s in baseline_stamps(ts[-1], pg, mode, rules)):
        mode = out["baseline"] = "provisional"
    if mode == "provisional" and ts[0] - w < pg + DAY:
        return done(INSUFFICIENT, "provisional baseline: the first 24 hours of the promoted model are the only history "
                                  f"{alias} has, and they are not over (judging starts {_when(pg + DAY + w)})")
    if mode == "previous" and ts[0] - w < pg:
        return done(INSUFFICIENT, f"the judged windows would still hold the previous model's requests (judging starts {_when(pg + w)})")
    label = "previous model" if mode == "previous" else "provisional baseline (the alias's own first 24h)"

    def run(name, judge, limit_name, kind):
        res = [judge(t, baseline_stamps(t, pg, mode, rules)) for t in ts]
        state, why = metric_state(res)
        last = res[-1][1]
        m = {"state": state, "reason": why, "baseline": mode}
        if "value" in last:
            m.update(value=round(last["value"], 6), baselineValue=round(last["baseline"], 6), requests=last["requests"])
        if state == BREACH:
            m["reason"] = (f"{_fmt(kind, last['value'])} against {_fmt(kind, last['baseline'])} at like hours on the {label}, over "
                           f"{limit_name} for {rules.for_minutes} min ({len(ts)} windows)" if rules.like_hours else
                           f"{_fmt(kind, last['value'])} against {_fmt(kind, last['baseline'])} on the {label}, over {limit_name} "
                           f"for {rules.for_minutes} min")
        elif state == OK and "value" in last:
            m["reason"] = f"{_fmt(kind, last['value'])} against {_fmt(kind, last['baseline'])} on the {label}"
        out["metrics"][name] = m

    lim = rules.error_rate_ratio
    run("errorRate", lambda t, s: _ratio_instant(d.errors, d.total, t, s, lim, rules), f"{lim:g}x", "rate")
    run("p95Latency", lambda t, s: _p95_instant(d.buckets, t, s, rules.p95_ratio, rules), f"{rules.p95_ratio:g}x", "p95")
    if d.tool_fail is not None:
        tl = rules.tool_parse_failure_ratio
        run("toolParseFailures", lambda t, s: _ratio_instant(d.tool_fail, d.tool_total, t, s, tl, rules), f"{tl:g}x", "rate")
    else:
        out["metrics"]["toolParseFailures"] = {"state": UNKNOWN, "reason": TOOL_PARSE_TODO}
    out["metrics"]["thumbs"] = {"state": UNKNOWN, "reason": THUMBS_TODO}
    out["state"], out["reasons"] = _combine(out["metrics"])
    if mode == "provisional":
        out["reasons"].insert(0, "provisional: judged against the alias's own first 24 hours, not against the previous model")
    return out


def _parse_time(v) -> int:
    if isinstance(v, (int, float)):
        return int(v)
    s = str(v).strip()
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError(repr(s)) from None
    return int((dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).timestamp())


def _when(ts: int) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%MZ")


# ---------------------------------------------------------------- the whole watch

def watched(lc: ml.Lifecycle, inv: nm.Inventory):
    """(alias, route, promotion record) for each live alias whose model is promoted FOR that alias."""
    for r in inv.routes:
        if r.alias.endswith(ml.NEXT):
            continue
        e = lc.by_model(r.model)
        if e is not None and e.stage == "promoted" and e.promotion and e.serves(r.alias) and not e.promotion.get("placement"):
            yield r.alias, r, e.promotion


def watch(lc: ml.Lifecycle, inv: nm.Inventory, prom: Prom, rules: Rules, soak_days: int = 14, now: int | None = None) -> dict:
    now = int(time.time()) if now is None else now
    aliases = {}
    for alias, route, rec in watched(lc, inv):
        aliases[alias] = evaluate(alias, route.model, rec, prom, rules, soak_days, now)
    return {"schema": SCHEMA, "generated": datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "soakDays": soak_days, "aliases": aliases}


# ---------------------------------------------------------------- a breach: the revert change, the PR, the message

HEADER = ["Generated by the Tockmox health watch. Machine-owned: edit through the Tockmox UI or a PR like this one."]
AUTO_TRAILER = "Tockmox-Auto-Merge: requested"
AUTO_LABEL = "tockmox/auto-merge"


def breach_reason(res: dict) -> str:
    return "; ".join(f"{k} {m['reason']}" for k, m in res["metrics"].items() if m["state"] == BREACH)[:380]


def build_revert(res: dict, values: dict, when: str, auto: bool = False) -> po.PRSpec:
    """The revert change for a breached alias, as a PR spec. models.revert does the work and its refusals
    (no previous route, the demoted build serves another alias ...) propagate as LifecycleError."""
    alias = res["alias"]
    po.check_values_file(values)
    lc_raw, in_raw = values.get("modelLifecycle") or {}, values.get("inferenceNodes") or {}
    lc, inv = ml.parse(lc_raw), nm.parse_inventory(in_raw)
    new_lc, new_inv, notes = ml.revert(alias, "health watch: " + breach_reason(res), when, lc, inv)
    if ml.check_promotions(new_lc, new_inv):
        raise ml.LifecycleError("the revert would fail the promotion gate")
    status = json.dumps({"schema": SCHEMA, "generated": when, "aliases": {alias: res}}, indent=2, sort_keys=True)
    body = (f"The health watch found `{alias}` doing worse on `{res['model']}` than it did on `{res['previous']}`, "
            f"after the promotion of {res['promotedAt']}. Baseline: {res['baseline']}.\n\n"
            + "".join(f"- {r}\n" for r in res["reasons"] if "unknown" not in r) + "\n"
            + "".join(f"- {n}\n" for n in notes)
            + ("\n**Auto-merge requested** (modelLifecycle.healthWatch.autoRevert." + alias + "): the site's own auto-merge may take "
               "this PR. Nothing in Tockmox merges it.\n" if auto else
               "\nMerging this reverts the alias (the revert change of AC-48.18). Nothing was changed on the gateway.\n")
            + f"\nStatus at the time:\n\n```json\n{status}\n```\n")
    title = f"Revert {alias} to {res['previous']} (health watch)" + (" [auto-merge requested]" if auto else "")
    return po.PRSpec(f"{po.REVERT_BRANCH}{po.branch_slug(alias)}", title[:120], body,   # the opener's revert lane
                     po._values_text(ml.change_doc(lc_raw, in_raw, new_lc, new_inv), HEADER), "revert", alias)


class Ntfy:
    """POST to <url>[/<topic>] the way the alert bridge does (Title/Priority/Tags headers, optional bearer token). The
    sequence id makes a repeat for the same alias REPLACE the earlier notification on the phone instead of stacking."""

    def __init__(self, url: str, topic: str = "", token: str = "", transport=None, timeout: float = 10.0):
        u = url.rstrip("/") + (("/" + topic.strip("/")) if topic else "")
        if not re.match(r"^https?://[^/]+", u):
            raise ValueError("notify.ntfyUrl must be an http(s) URL")
        self.url, self.token, self.transport, self.timeout = u, token, transport, timeout

    def send(self, title: str, message: str, alias: str, priority: str = "high") -> str:
        """"" on success, else why not."""
        h = {"Title": title.encode("ascii", "replace").decode(), "Priority": priority, "Tags": "rotating_light",
             "X-Sequence-ID": "tockmox-health-" + re.sub(r"[^A-Za-z0-9_-]", "-", alias)}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        try:
            with httpx.Client(timeout=self.timeout, transport=self.transport, follow_redirects=False) as c:
                r = c.post(self.url, content=message.encode("utf-8"), headers=h)
            return "" if r.status_code < 300 else f"ntfy answered HTTP {r.status_code}"
        except httpx.HTTPError as e:
            return f"{type(e).__name__}: {str(e)[:120]}"


def act(report: dict, forge, ntfy: Ntfy | None, hw: dict, pr_cfg: dict, apply: bool = False, log=print) -> dict:
    """Do what the breaches in `report` call for. Returns {alias: {"spec": PRSpec|None, "url": str, "notified": bool, "note": str}}.
    Only a `breach` ever reaches here with work to do: an inconclusive or insufficient alias renders nothing, opens
    nothing, and sends nothing."""
    breaches = [r for r in report["aliases"].values() if r["state"] == BREACH]
    out: dict = {}
    if not breaches:
        return out
    auto_cfg = hw.get("autoRevert") or {}
    values = file_sha = None
    busy: set = set()
    base, path = pr_cfg.get("baseBranch", "main"), pr_cfg.get("valuesPath", "")
    if forge is not None and hw.get("pullRequests"):
        try:
            if not path:
                raise po.Refused("modelLifecycle.watch.pullRequests.valuesPath is not set")
            text, file_sha = forge.read_file(path, base)
            values = yaml.safe_load(text) or {}
            busy = {b for b in forge.open_branches() if not b.startswith(po.EVIDENCE_BRANCH)}
        except (po.Refused, httpx.HTTPError, yaml.YAMLError) as e:
            values, out["_forge"] = None, {"note": f"could not read the site repo: {e}"}
    trailers = [str(t) for t in pr_cfg.get("commitTrailers") or []]
    for res in breaches:
        alias = res["alias"]
        auto = bool(auto_cfg.get(alias))
        row = out[alias] = {"spec": None, "url": "", "notified": False, "note": ""}
        if forge is not None and hw.get("pullRequests") and values is None:
            row["note"] = out.get("_forge", {}).get("note", "no values file")
        elif values is not None:
            try:
                spec = build_revert(res, values, report["generated"][:10], auto)
                row["spec"] = spec
                if spec.branch in busy:
                    row["note"] = "a revert PR for it is already open"
                elif busy:
                    row["note"] = f"another model-lifecycle PR is open ({', '.join(sorted(busy))}): one at a time, the next run tries again"
                    row["spec"] = None
                elif not apply:
                    log(f"would open  {spec.branch}  {spec.title}")
                else:
                    msg = spec.title + "\n\n" + "\n".join(trailers + ([AUTO_TRAILER] if auto else []))
                    row["url"] = forge.open_pr(base, spec, path, file_sha, msg.strip())
                    log(f"opened      {spec.branch}  {row['url']}")
                    if auto:
                        _label(forge, row["url"], log)
            except (ml.LifecycleError, nm.NodeError, po.Refused, httpx.HTTPError) as e:
                row["note"] = f"no revert PR: {e}"
        # a message once per breach: when the PR is newly open, when there is no PR lane, or when the PR could not be opened
        already = row["note"] == "a revert PR for it is already open"
        if ntfy is not None and apply and not already:
            what = (f"Revert PR: {row['url']}" if row["url"] else
                    (row["note"] or "Revert it from the Models page (no PR lane is configured)."))
            err = ntfy.send(f"Health watch: {alias} is worse on {res['model']}", f"{breach_reason(res)}\n{what}", alias)
            row["notified"] = not err
            if err:
                log(f"ntfy failed: {err}")
    out.pop("_forge", None)
    return out


def _label(forge, pr_url: str, log) -> None:
    """Best effort, GitHub only (Forgejo labels are by id): the PR carries tockmox/auto-merge for the site's own automation."""
    m = re.search(r"/pull/(\d+)$", pr_url or "")
    if forge.kind != "github" or not m:
        return
    try:
        forge._req("POST", f"/issues/{m.group(1)}/labels", {"labels": [AUTO_LABEL]})
    except Exception as e:  # noqa: BLE001 - the trailer and the title already say it
        log(f"could not label the PR {AUTO_LABEL}: {type(e).__name__}")


# ---------------------------------------------------------------- command line

def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    apply = "--apply" in argv
    if len(args) != 1:
        print("usage: python -m app.health_watch CONFIG.yaml [--apply]", file=sys.stderr)
        return 2
    cfg = yaml.safe_load(open(args[0], encoding="utf-8")) or {}
    lc_raw, in_raw = cfg.get("modelLifecycle") or {}, cfg.get("inferenceNodes") or {}
    hw = lc_raw.get("healthWatch") or {}
    if not hw.get("enabled", False):
        print("the health watch is off (modelLifecycle.healthWatch.enabled is false)", file=sys.stderr)
        return 0
    try:
        rules = parse_rules(hw.get("rules"))
        lc, inv = ml.parse(lc_raw), nm.parse_inventory(in_raw)
        soak = int(hw.get("soakDays", 14))
    except (ValueError, ml.LifecycleError, nm.NodeError) as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2
    url = str(hw.get("prometheusUrl") or "")
    if not url:
        print("refused: modelLifecycle.healthWatch.prometheusUrl is empty", file=sys.stderr)
        return 2
    report = watch(lc, inv, Prom(url), rules, soak)
    forge, pr_cfg = None, ((lc_raw.get("watch") or {}).get("pullRequests")) or {}
    if apply and hw.get("pullRequests"):
        forge = po._forge_from(cfg, pr_cfg)
        if forge is None:
            return 2
    ntfy = None
    nt = hw.get("notify") or {}
    if nt.get("ntfyUrl"):
        ntfy = Ntfy(str(nt["ntfyUrl"]), os.environ.get("NTFY_TOPIC", "") or "alerts", os.environ.get("NTFY_TOKEN", ""))
    acted = act(report, forge, ntfy, hw, pr_cfg, apply)
    for row in acted.values():
        if row.get("note"):
            print(f"note: {row['note']}")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if any(m["reason"].startswith("Prometheus did not answer") for a in report["aliases"].values()
                    for m in [{"reason": r} for r in a["reasons"]]) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

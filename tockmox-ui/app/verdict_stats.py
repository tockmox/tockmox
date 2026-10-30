# SPDX-License-Identifier: Apache-2.0
"""The statistics a comparative verdict rests on (TM-1248; REQ-0045 AC-45.9; DESIGN-2026-10-29-eval-runner §4.4).

Pure: no network, no clock, no randomness the caller did not seed. The eval runner calls `decide` to turn paired
per-case outcomes into a verdict; the UI and CI call `check_extras` to read the optional fields a verdict carries.

Why paired, and why these tests. A candidate and an incumbent answer the SAME cases, so the useful signal is in the
cases where they disagree (the discordant pairs). With the small sets a homelab has (8 to 50 cases), a normal
approximation to a standard error is meaningless, so:

  - wins / losses / ties are reported first, always;
  - the exact sign test (McNemar's exact form) on the discordant pairs gives the p-value;
  - a paired bootstrap, seeded, gives the interval on the mean difference in pass rate;
  - a Wilson lower bound gives the floor on an absolute pass rate (no incumbent: absolute bars).

Labels, fixed rules (the thresholds are the class's policy, passed in, never invented here):
  Better        the interval's lower end exceeds +min_effect
  Worse         the interval's upper end is below -margin, or any safety failure
  Same          the whole interval sits inside [-margin, +margin] (non-inferiority holds)
  Inconclusive  anything else, with an estimate of how many more cases would settle it

A set under SCREENING_FLOOR cases is "screening": it may say Same, Worse or Inconclusive, never Better, because a
small frozen set cannot show an improvement worth moving an alias for. The verdict a label maps to:
Better or Same -> pass, Worse -> fail, Inconclusive -> inconclusive.

Tradeoff (TM-1269) is a fifth label that only `apply_speed` produces: the quality pass held, but the candidate broke the
set's speed criterion (for example decode under half the incumbent's tokens per second). It maps to verdict
"inconclusive", so it neither counts toward a promotion nor resets the count (models.count_passes also skips it by
label): a person decides whether the quality is worth the speed. A summary line says it in one sentence.
"""
from __future__ import annotations

import math
import random

SCREENING_FLOOR = 30
LABELS = ("better", "same", "worse", "inconclusive", "tradeoff")
LABEL_VERDICT = {"better": "pass", "same": "pass", "worse": "fail", "inconclusive": "inconclusive",
                 "tradeoff": "inconclusive"}
SPEED_KEYS = ("decode_tok_s_min_ratio",)
DEFAULT_TOOL_PARSE_BAR = 0.02
METHODS = ("sign-test+bootstrap", "wilson", "rule")
BOOT_ITERS = 4000


class StatsError(ValueError):
    pass


# ---------------------------------------------------------------- primitives


def binom_tail(k: int, n: int) -> float:
    """P(X >= k) for X ~ Binomial(n, 1/2). Exact; n is small."""
    if n <= 0:
        return 1.0
    return sum(math.comb(n, i) for i in range(k, n + 1)) / 2 ** n


def sign_test(wins: int, losses: int) -> float:
    """Two-sided exact sign test on the discordant pairs (ties dropped). 1.0 when there are none."""
    n = wins + losses
    if n == 0:
        return 1.0
    k = max(wins, losses)
    return min(1.0, 2 * binom_tail(k, n))


def wilson(k: int, n: int, z: float = 1.959964) -> tuple[float, float]:
    """Wilson score interval for k successes in n trials."""
    if n <= 0:
        return (0.0, 1.0)
    p = k / n
    den = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return (max(0.0, centre - half), min(1.0, centre + half))


def paired_bootstrap(diffs: list[float], seed: int = 1, iters: int = BOOT_ITERS, level: float = 0.95) -> tuple[float, float]:
    """Percentile bootstrap interval on the mean of per-case differences (candidate minus incumbent)."""
    n = len(diffs)
    if n == 0:
        return (-1.0, 1.0)
    rng = random.Random(seed)
    means = []
    for _ in range(iters):
        s = 0.0
        for _ in range(n):
            s += diffs[rng.randrange(n)]
        means.append(s / n)
    means.sort()
    lo = means[int((1 - level) / 2 * iters)]
    hi = means[min(iters - 1, int((1 + level) / 2 * iters))]
    return (lo, hi)


# ---------------------------------------------------------------- the decision


def _case_rate(x) -> float:
    """A case's outcome as a pass rate in [0, 1]: a bool, or a list of per-epoch bools, or a number."""
    if isinstance(x, bool):
        return 1.0 if x else 0.0
    if isinstance(x, (int, float)):
        if not 0 <= x <= 1:
            raise StatsError(f"a case score must be in [0, 1], got {x}")
        return float(x)
    if isinstance(x, (list, tuple)) and x and all(isinstance(e, bool) for e in x):
        return sum(1 for e in x if e) / len(x)
    raise StatsError(f"a case outcome must be a bool, a list of bools (epochs) or a rate, got {x!r}")


def more_cases_needed(diffs: list[float], margin: float, min_effect: float) -> int:
    """A rough estimate of how many cases would make the interval narrow enough to land in one label: the interval
    half-width scales with 1/sqrt(n), so n * (current half-width / target half-width)^2, less what is already run."""
    n = len(diffs)
    if n < 2:
        return SCREENING_FLOOR
    mean = sum(diffs) / n
    var = sum((d - mean) ** 2 for d in diffs) / (n - 1)
    if var == 0:
        return 0
    target = max(1e-6, max(abs(mean) - min_effect, margin) / 2)
    half = 1.96 * math.sqrt(var / n)
    need = math.ceil(n * (half / target) ** 2)
    return max(0, need - n)


def decide(pairs, margin: float, min_effect: float, seed: int = 1, safety_fails: int = 0) -> dict:
    """Paired outcomes [(candidate, incumbent), ...] to the verdict fields. Each side is a bool, a list of per-epoch
    bools, or a pass rate. margin is the non-inferiority band (for example 0.05 = five points of pass rate);
    min_effect is the improvement a Better label needs (for example 0.05).

    Returns {"label", "verdict", "n", "wins", "losses", "ties", "discordant": {"b", "c"}, "p_value",
    "interval": [lo, hi], "margin", "min_effect", "screening", "method", "more_cases"}."""
    if not 0 <= margin < 1 or not 0 <= min_effect < 1:
        raise StatsError("margin and min_effect must be fractions in [0, 1)")
    rows = [(_case_rate(c), _case_rate(i)) for c, i in pairs]
    n = len(rows)
    if n == 0:
        raise StatsError("no cases: a verdict needs at least one paired case")
    diffs = [c - i for c, i in rows]
    wins = sum(1 for d in diffs if d > 0)
    losses = sum(1 for d in diffs if d < 0)
    ties = n - wins - losses
    lo, hi = paired_bootstrap(diffs, seed=seed)
    screening = n < SCREENING_FLOOR
    if safety_fails:
        label = "worse"
    elif hi < -margin:
        label = "worse"
    elif lo > min_effect and not screening:
        label = "better"
    elif lo >= -margin and hi <= margin:
        label = "same"
    elif lo >= -margin and screening and wins >= losses:
        # A screening set whose interval clears the margin on the low side but cannot show Better: non-inferior.
        label = "same"
    else:
        label = "inconclusive"
    out = {"label": label, "verdict": LABEL_VERDICT[label], "n": n, "wins": wins, "losses": losses, "ties": ties,
           "effect": round(sum(diffs) / n, 6),
           "discordant": {"b": wins, "c": losses}, "p_value": round(sign_test(wins, losses), 6),
           "interval": [round(lo, 6), round(hi, 6)], "margin": margin, "min_effect": min_effect,
           "screening": screening, "method": "sign-test+bootstrap",
           "more_cases": more_cases_needed(diffs, margin, min_effect) if label == "inconclusive" else 0}
    if safety_fails:
        out["safety_fails"] = int(safety_fails)
    return out


def decide_absolute(passed: int, n: int, bar: float) -> dict:
    """No incumbent (a brand-new alias): the Wilson lower bound on the pass rate must clear the bar."""
    if n <= 0:
        raise StatsError("no cases")
    lo, hi = wilson(passed, n)
    screening = n < SCREENING_FLOOR
    if lo >= bar:
        label = "same"          # "meets the bar": there is nothing to be better than
    elif hi < bar:
        label = "worse"
    else:
        label = "inconclusive"
    return {"label": label, "verdict": LABEL_VERDICT[label], "n": n, "wins": passed, "losses": n - passed, "ties": 0,
            "rate": round(passed / n, 6), "interval": [round(lo, 6), round(hi, 6)], "bar": bar,
            "screening": screening, "method": "wilson"}


# ---------------------------------------------------------------- speed, tool reliability, and the one-line summary

def check_speed_criterion(sc) -> dict:
    """A speed criterion is {"decode_tok_s_min_ratio": r}: the candidate's decode tokens per second over the
    incumbent's must be at least r (0 < r <= 10). Raises StatsError; returns a clean copy."""
    if not isinstance(sc, dict) or not sc or not set(sc) <= set(SPEED_KEYS):
        raise StatsError(f"speed_criterion must be a map of {list(SPEED_KEYS)}")
    r = sc.get("decode_tok_s_min_ratio")
    if isinstance(r, bool) or not isinstance(r, (int, float)) or not 0 < r <= 10:
        raise StatsError("speed_criterion.decode_tok_s_min_ratio must be a number above 0 and at most 10")
    return {"decode_tok_s_min_ratio": float(r)}


def apply_speed(decision: dict, speed_criterion: dict | None, cand_tps: float | None, inc_tps: float | None) -> dict:
    """Fold the speed comparison into a paired decision. Returns the decision with `quality_label` (what quality alone
    said), `speed` ({candidate_tok_s, incumbent_tok_s, ratio}) when both were measured, and, when the criterion is
    broken by a quality pass, label "tradeoff" and verdict "inconclusive". A criterion that cannot be evaluated (a
    side with no decode figure) turns a pass into inconclusive too: an unmeasured speed is not a met one. A fail,
    or an inconclusive, stays what it was."""
    d = dict(decision)
    d["quality_label"] = d["label"]
    ratio = None
    if cand_tps and inc_tps and cand_tps > 0 and inc_tps > 0:
        ratio = cand_tps / inc_tps
        d["speed"] = {"candidate_tok_s": round(cand_tps, 3), "incumbent_tok_s": round(inc_tps, 3), "ratio": round(ratio, 4)}
    if speed_criterion and d["verdict"] == "pass":
        need = check_speed_criterion(speed_criterion)["decode_tok_s_min_ratio"]
        if ratio is None:
            d["label"], d["verdict"] = "inconclusive", "inconclusive"
            d["speed_note"] = "decode speed could not be measured on both sides, so the speed criterion could not be judged"
        elif ratio < need:
            d["label"], d["verdict"] = "tradeoff", "inconclusive"
            d["speed_note"] = (f"decode at {ratio:.2f}x the incumbent's is below the criterion of {need:g}x: "
                               "quality held, speed did not")
    return d


def summary_line(decision: dict, tool: dict | None = None, bar: float | None = None) -> str:
    """One line a person reads first: "Better on quality (+0.12 pass rate), 4.3x slower decode, tool parse 0.0%".
    `decision` is a decide / decide_absolute / apply_speed result; `tool` is the tool-reliability figures."""
    q = decision.get("quality_label", decision["label"])
    eff = decision.get("effect")
    if decision.get("method") == "wilson":
        rate = decision.get("rate")
        part = {"same": "Meets the quality bar", "worse": "Below the quality bar"}.get(q, "Quality bar not settled")
        if rate is not None:
            part += f" (pass rate {rate:.2f}, bar {decision.get('bar', 0):.2f})"
    else:
        word = {"better": "Better on quality", "same": "Same quality", "worse": "Worse on quality",
                "inconclusive": "Quality inconclusive"}.get(q, "Quality " + q)
        part = word + (f" ({eff:+.2f} pass rate)" if eff is not None else "")
    parts = [part]
    sp = decision.get("speed")
    if sp:
        r = sp["ratio"]
        if r < 0.95:
            parts.append(f"{1 / r:.1f}x slower decode")
        elif r > 1.05:
            parts.append(f"{r:.1f}x faster decode")
        else:
            parts.append("decode speed about the same")
    if tool and tool.get("parse_failure_rate") is not None:
        t = f"tool parse {tool['parse_failure_rate'] * 100:.1f}%"
        if bar is not None and tool["parse_failure_rate"] > bar:
            t += f" (over the {bar * 100:.1f}% bar)"
        parts.append(t)
    return ", ".join(parts)


# ---------------------------------------------------------------- reading the optional verdict fields

def _pos(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and x > 0


_SAMPLING_KEYS = {"temperature", "top_p", "thinking", "max_tokens", "seed", "epochs"}


def check_extras(d: dict) -> tuple[dict, list[str]]:
    """The optional comparative-verdict/1 fields added by TM-1248, validated. Returns (extras, problems). An absent
    field is fine (older producers); a present one must be well-formed, and the label must agree with the verdict."""
    ex, problems = {}, []
    if "n" in d:
        if isinstance(d["n"], bool) or not isinstance(d["n"], int) or d["n"] < 1:
            problems.append("n must be a positive whole number")
        else:
            ex["n"] = d["n"]
    if "discordant" in d:
        dc = d["discordant"]
        if not (isinstance(dc, dict) and all(isinstance(dc.get(k), int) and not isinstance(dc.get(k), bool)
                                              and dc[k] >= 0 for k in ("b", "c"))):
            problems.append("discordant must be {b, c}, whole numbers")
        else:
            ex["discordant"] = {"b": dc["b"], "c": dc["c"]}
    if "method" in d:
        if d["method"] not in METHODS:
            problems.append(f"method must be one of {METHODS}")
        else:
            ex["method"] = d["method"]
    if "interval" in d:
        iv = d["interval"]
        if not (isinstance(iv, list) and len(iv) == 2 and all(isinstance(x, (int, float)) and not isinstance(x, bool)
                                                               for x in iv) and iv[0] <= iv[1]):
            problems.append("interval must be [low, high]")
        else:
            ex["interval"] = [float(iv[0]), float(iv[1])]
    for k in ("margin", "min_effect", "bar"):
        if k in d:
            if not isinstance(d[k], (int, float)) or isinstance(d[k], bool) or not 0 <= d[k] < 1:
                problems.append(f"{k} must be a fraction in [0, 1)")
            else:
                ex[k] = float(d[k])
    if "label" in d:
        if d["label"] not in LABELS:
            problems.append(f"label must be one of {LABELS}")
        else:
            ex["label"] = d["label"]
            if d.get("verdict") and LABEL_VERDICT[d["label"]] != d["verdict"]:
                problems.append(f"label {d['label']} means verdict {LABEL_VERDICT[d['label']]}, not {d['verdict']}")
    if "screening" in d:
        if not isinstance(d["screening"], bool):
            problems.append("screening must be true or false")
        else:
            ex["screening"] = d["screening"]
            if d["screening"] and d.get("label") == "better":
                problems.append("a screening set cannot be labelled better")
    if "sampling" in d:
        s = d["sampling"]
        if not isinstance(s, dict) or not set(s) <= _SAMPLING_KEYS:
            problems.append(f"sampling must be a map of {sorted(_SAMPLING_KEYS)}")
        else:
            ex["sampling"] = dict(s)
    if "engine" in d:
        e = d["engine"]
        if not (isinstance(e, dict) and isinstance(e.get("id"), str) and e["id"] and isinstance(e.get("version", ""), str)):
            problems.append("engine must be {id, version, flags?}")
        else:
            ex["engine"] = {"id": e["id"], "version": e.get("version", ""), "flags": str(e.get("flags", ""))}
    if "judge" in d:
        j = d["judge"]
        if j is not None and not (isinstance(j, dict) and isinstance(j.get("model"), str) and j["model"]):
            problems.append("judge must be null or {model, prompt_version}")
        else:
            ex["judge"] = j
    if "node" in d:
        if not isinstance(d["node"], str) or not d["node"]:
            problems.append("node must be a node id")
        else:
            ex["node"] = d["node"]
    if "control" in d:
        c = d["control"]
        if not (isinstance(c, dict) and isinstance(c.get("passed"), bool)):
            problems.append("control must be {passed: bool, cases?}")
        else:
            ex["control"] = {"passed": c["passed"], "cases": c.get("cases")}
    if "summary" in d:
        if not isinstance(d["summary"], str) or not d["summary"].strip() or len(d["summary"]) > 300 or "\n" in d["summary"]:
            problems.append("summary must be one line of at most 300 characters")
        else:
            ex["summary"] = d["summary"]
    if "speed_criterion" in d:
        try:
            ex["speed_criterion"] = check_speed_criterion(d["speed_criterion"])
        except StatsError as e:
            problems.append(str(e))
    if "speed" in d:
        sp = d["speed"]
        if not (isinstance(sp, dict) and all(_pos(sp.get(k)) for k in ("candidate_tok_s", "incumbent_tok_s", "ratio"))):
            problems.append("speed must be {candidate_tok_s, incumbent_tok_s, ratio}, positive numbers")
        else:
            ex["speed"] = {k: float(sp[k]) for k in ("candidate_tok_s", "incumbent_tok_s", "ratio")}
    if "tool_reliability" in d:
        tr = d["tool_reliability"]
        rates = ("parse_failure_rate", "wrong_tool_rate", "schema_violation_rate")
        ok = isinstance(tr, dict) and isinstance(tr.get("n"), int) and not isinstance(tr.get("n"), bool) and tr["n"] >= 1 \
            and all(isinstance(tr.get(k), (int, float)) and not isinstance(tr.get(k), bool) and 0 <= tr[k] <= 1 for k in rates) \
            and (tr.get("bar") is None or (isinstance(tr["bar"], (int, float)) and not isinstance(tr["bar"], bool) and 0 <= tr["bar"] < 1))
        if not ok:
            problems.append("tool_reliability must be {parse_failure_rate, wrong_tool_rate, schema_violation_rate (0 to 1), n, bar?}")
        else:
            ex["tool_reliability"] = {**{k: float(tr[k]) for k in rates}, "n": tr["n"],
                                      **({"bar": float(tr["bar"])} if tr.get("bar") is not None else {})}
    if ex.get("label") == "tradeoff" and "speed_criterion" not in ex:
        problems.append("a tradeoff label needs the speed_criterion it rests on")
    es = d.get("eval_set")
    if isinstance(es, dict) and "sha256" in es:
        if not (isinstance(es["sha256"], str) and len(es["sha256"]) == 64 and all(ch in "0123456789abcdef" for ch in es["sha256"])):
            problems.append("eval_set.sha256 must be 64 hex characters")
        else:
            ex["set_sha256"] = es["sha256"]
    return ex, problems


def evidence_key(candidate_revision: str, eval_set: tuple, extras: dict) -> tuple:
    """What makes two verdicts independent pieces of evidence. Two runs that share the candidate build, the eval set
    (version, and content hash when given), the sampling configuration, the engine and the node measured the same
    thing twice: the second adds sampling noise, not evidence, so it counts once (AIX-1)."""
    eng = extras.get("engine") or {}
    sampling = extras.get("sampling") or {}
    return ((candidate_revision or "").replace("sha256:", ""), tuple(eval_set), extras.get("set_sha256", ""),
            tuple(sorted((k, str(v)) for k, v in sampling.items())), eng.get("id", ""), eng.get("version", ""),
            extras.get("node", ""))

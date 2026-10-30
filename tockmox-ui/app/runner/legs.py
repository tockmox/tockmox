# SPDX-License-Identifier: Apache-2.0
"""The legs of an evidence bundle (DESIGN-2026-10-29-eval-runner §4.1): the known-bad control, smoke, perf, prefill,
tool-call reliability and quality. Each leg returns plain data; run.py turns it into capability-result/1 twins and
the verdict."""
from __future__ import annotations

import json
import random
import re
import secrets
import statistics
import threading
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import client as cl
from .evalset import Case, EvalSet, grade


class Aborted(RuntimeError):
    """A leg stopped because the node or the gateway was not fit to measure (health, load, a production request)."""


class BudgetSpent(ValueError):
    """TM-1295: the answers came back empty because the token budget ran out first (finish_reason length, no content,
    no tool call), usually spent on reasoning. That measures the route's settings, not the model, so the run stops with
    the cause and writes no verdict. It is a refusal, not a transient: the scheduler does not retry it until the route
    changes (its params are part of the run key)."""


def budget_spent(r: dict) -> bool:
    """A reply cut at max_tokens before any answer: finish_reason length, empty content, no tool call."""
    return r.get("finish_reason") == "length" and not (r.get("content") or "").strip() and not r.get("tool_calls")


def budget_sentence(model: str, n: int, of: int, reasoning: bool) -> str:
    why = ("the model spent the whole token budget reasoning (the engine returned reasoning text and no answer)"
           if reasoning else "the reply was cut at max_tokens before any answer")
    return (f"{n} of {of} replies from {model} came back empty with finish_reason length: {why}. This measures the "
            "route's settings, not the model. Turn thinking off on the -next route (for Qwen3.x on mlx-lm: params "
            "extra_body.chat_template_kwargs.enable_thinking false) or raise max_tokens there; the next scheduler pass "
            "re-runs once the route changes.")


# ---------------------------------------------------------------- the known-bad control

class _Bad(BaseHTTPRequestHandler):
    """Answers every completion with a fixed wrong reply and no tool calls. A grader that passes it cannot tell good
    from bad, so the run stops before its numbers are believed."""
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunk = {"choices": [{"index": 0, "delta": {"content": "known-bad control"}, "finish_reason": "stop"}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\ndata: [DONE]\n\n")
            return
        b = json.dumps({"choices": [{"index": 0, "message": {"role": "assistant", "content": "known-bad control"},
                                     "finish_reason": "stop"}], "usage": {"prompt_tokens": 1, "completion_tokens": 3}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


def control(es: EvalSet) -> dict:
    """Run the set's graders against the known-bad responder. {"passed": bool, "cases": n, "pass_rate": r}.
    `passed` true means the control was NOT caught: half or more of the cases passed a responder that is wrong."""
    srv = ThreadingHTTPServer(("127.0.0.1", 0), _Bad)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        url = f"http://127.0.0.1:{srv.server_address[1]}"
        ok = 0
        for case in es.cases:
            reply = cl.complete(url, "control", "control", case.messages, tools=case.tools or None,
                                response_format=case.response_format, max_tokens=case.max_tokens or es.max_tokens)
            ok += grade(case, reply)[0]
    finally:
        srv.shutdown()
    rate = ok / len(es.cases)
    return {"passed": rate >= 0.5, "cases": len(es.cases), "pass_rate": round(rate, 4)}


# ---------------------------------------------------------------- smoke

_TOOL = [{"type": "function", "function": {"name": "get_time", "description": "Return the current time in a timezone",
                                           "parameters": {"type": "object", "properties": {"tz": {"type": "string"}},
                                                          "required": ["tz"]}}}]


def smoke(base, key, model, health=None) -> list[dict]:
    """Five checks, each a 0/1 metric: finish reason stop, one tool call parses, a JSON reply, a well-formed stream
    with a usage chunk and [DONE], and a verbatim canary."""
    out = []
    replies = []

    def check(name, fn):
        if health:
            health()
        try:
            ok, why = fn()
        except cl.GatewayError as e:
            ok, why = False, str(e)[:160]
        out.append({"name": name, "value": 1.0 if ok else 0.0, "unit": "bool", "n": 1, "why": why})

    def call(*a, **k):
        r = cl.complete(*a, **k)
        replies.append(r)
        return r

    def stop():
        r = call(base, key, model, [{"role": "user", "content": "Say hello in one word."}], max_tokens=32)
        return r["finish_reason"] == "stop", f"finish_reason {r['finish_reason']}"

    def tool():
        r = call(base, key, model, [{"role": "user", "content": "What time is it in Chicago? Use the tool."}],
                        tools=_TOOL, max_tokens=256)
        calls = r["tool_calls"]
        if len(calls) != 1 or calls[0]["name"] != "get_time":
            return False, f"{len(calls)} tool call(s)"
        try:
            args = json.loads(calls[0]["arguments"] or "{}")
        except ValueError:
            return False, "arguments are not JSON"
        return isinstance(args.get("tz"), str), "tz argument missing" if not isinstance(args.get("tz"), str) else ""

    def jsonr():
        r = call(base, key, model, [{"role": "user", "content": 'Reply with a JSON object {"ok": true} and nothing else.'}],
                        response_format={"type": "json_object"}, max_tokens=64)
        try:
            return json.loads(r["content"].strip().strip("`").removeprefix("json").strip()).get("ok") is True, ""
        except (ValueError, AttributeError):
            return False, "not JSON"

    def stream():
        r = call(base, key, model, [{"role": "user", "content": "Count from one to five."}], max_tokens=64, stream=True)
        s = r["stream"]
        ok = s["done"] and s["usage_chunk"] and s["order_ok"] and s["events"] > 0 and r["finish_reason"] == "stop"
        return ok, "" if ok else f"stream {s}"

    def canary():
        token = "canary-" + secrets.token_hex(6)
        r = call(base, key, model, [{"role": "user", "content": f"Repeat exactly, with nothing else: {token}"}], max_tokens=64)
        return token in r["content"], "" if token in r["content"] else "the canary was not repeated verbatim"

    for name, fn in (("smoke_finish_stop", stop), ("smoke_tool_call_parses", tool), ("smoke_json_reply", jsonr),
                     ("smoke_stream_well_formed", stream), ("smoke_verbatim_canary", canary)):
        check(name, fn)
    spent = [r for r in replies if budget_spent(r)]
    if spent and any(m["value"] != 1.0 for m in out):
        raise BudgetSpent(budget_sentence(model, len(spent), len(replies), any(r.get("reasoning_chars") for r in spent)))
    return out


# ---------------------------------------------------------------- perf

def _pct(xs, p):
    if not xs:
        return 0.0
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1)))))
    return xs[k]


def perf(base, key, model, steps=(1, 2), requests_per_step=20, max_tokens=128, health=None) -> list[dict]:
    """Streamed requests at each concurrency step: TTFT p50/p95, complete p95, decode tok/s p50, each with its n and
    concurrency. A percentile from fewer than 100 requests is reported with its n; the reader decides what it is worth."""
    prompt = [{"role": "user", "content": "Write three sentences about the sea."}]
    metrics = []
    for c in steps:
        if health:
            health()
        rows = []

        def one(_):
            r = cl.complete(base, key, model, prompt, max_tokens=max_tokens, stream=True)
            toks = (r["usage"] or {}).get("completion_tokens") or 0
            gen = max(1e-6, r["total_s"] - r["ttft_s"])
            return r["ttft_s"], r["total_s"], (toks / gen) if toks else 0.0
        with ThreadPoolExecutor(max_workers=c) as ex:
            rows = list(ex.map(one, range(requests_per_step)))
        ttft = [r[0] for r in rows]
        total = [r[1] for r in rows]
        tps = [r[2] for r in rows if r[2] > 0]
        n = len(rows)
        metrics += [{"name": "ttft_p50_s", "value": round(_pct(ttft, 50), 4), "unit": "s", "n": n, "concurrency": c},
                    {"name": "ttft_p95_s", "value": round(_pct(ttft, 95), 4), "unit": "s", "n": n, "concurrency": c},
                    {"name": "complete_p95_s", "value": round(_pct(total, 95), 4), "unit": "s", "n": n, "concurrency": c},
                    {"name": "decode_tps_p50", "value": round(statistics.median(tps), 3) if tps else 0.0, "unit": "tok/s",
                     "n": len(tps), "concurrency": c}]
    return metrics


# ---------------------------------------------------------------- quality

def quality(base, key, model, es: EvalSet, workers=2, seed=1, health=None) -> list[list[bool]]:
    """Per case, per epoch: passed or not. temperature 0 for epoch 0, 0.7 for the rest, each epoch its own seed, so
    epochs measure sampling noise and the first epoch is the deterministic answer."""
    if health:
        health()

    spent, answered, thought, lock = [0], [0], [False], threading.Lock()

    def run_case(case):
        out = []
        for ep in range(es.epochs):
            try:
                r = cl.complete(base, key, model, case.messages, tools=case.tools or None,
                                response_format=case.response_format, max_tokens=case.max_tokens or es.max_tokens,
                                temperature=0.0 if ep == 0 else 0.7, seed=seed + ep)
                with lock:
                    answered[0] += 1
                    if budget_spent(r):
                        spent[0] += 1
                        thought[0] = thought[0] or bool(r.get("reasoning_chars"))
                out.append(grade(case, r)[0])
            except cl.GatewayError:
                out.append(False)
        return out
    with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
        res = list(ex.map(run_case, es.cases))
    # TM-1295: when at least half the answers are empty for want of tokens, the pass rate measures the route's
    # settings; stop with the cause rather than write a Worse verdict about the model
    if answered[0] and spent[0] * 2 >= answered[0]:
        raise BudgetSpent(budget_sentence(model, spent[0], answered[0], thought[0]))
    return res


# ---------------------------------------------------------------- prefill (TM-1268)

CHARS_PER_TOKEN = 4          # the filler is sized by this estimate; the twin says so, and records the engine's own count
DEFAULT_PREFILL_CONTEXTS = (4096, 16384, 32768, 65536)
_WORDS = ("amber basin cobalt dune ember fjord garnet harbor indigo juniper kelp lantern meadow nectar orchid pebble "
          "quartz ridge sparrow thistle umber valley willow yarrow zephyr anchor bridge candle delta engine forest "
          "glacier hollow island jungle kettle ledger marble north oasis prairie quill river summit timber upland "
          "vessel wander yonder").split()


def filler(tokens: int, nonce: str, seed: int = 1) -> str:
    """About `tokens` tokens of text (CHARS_PER_TOKEN characters each, an estimate, not a tokenizer count). It opens
    with a per-request nonce so no engine can answer from a prefix cache: this leg measures prefill, not cache hits."""
    rng = random.Random(f"{seed}:{tokens}:{nonce}")
    target = tokens * CHARS_PER_TOKEN
    parts, size = [f"Request {nonce}. Read the notes below and answer in one word.\n"], 0
    while size < target:
        w = " ".join(rng.choice(_WORDS) for _ in range(12)) + ".\n"
        parts.append(w)
        size += len(w)
    return "".join(parts)[:target] + "\nNow reply with the single word: ok"


def prefill(base, key, model, contexts=DEFAULT_PREFILL_CONTEXTS, requests_per_step=3, max_input_tokens=None, seed=1,
            health=None, timeout=1800.0) -> list[dict]:
    """Time to first token at each context length. One entry per step, in order:
    {"context": ctx, "state": "measured" | "skipped" | "failed", "reason", "ttft_ms_p50", "n", "prompt_tokens"}.
    A step over the route's max input tokens is skipped with the reason, never sent (an error there would read as a
    slow engine). Requests of one step run one after another: concurrency would measure queueing, not prefill."""
    out = []
    for ctx in contexts:
        if max_input_tokens and ctx > max_input_tokens:
            out.append({"context": ctx, "state": "skipped", "n": 0,
                        "reason": f"{ctx} tokens is over the route's max input of {max_input_tokens} tokens"})
            continue
        if health:
            health()
        ttfts, ptoks, err = [], [], ""
        for i in range(requests_per_step):
            nonce = secrets.token_hex(6)
            try:
                r = cl.complete(base, key, model, [{"role": "user", "content": filler(ctx, nonce, seed)}], max_tokens=16,
                                temperature=0.0, seed=seed + i, stream=True, timeout=timeout)
            except cl.GatewayError as e:
                err = str(e)[:160]
                continue
            ttfts.append(r["ttft_s"] * 1000.0)
            pt = (r["usage"] or {}).get("prompt_tokens")
            if isinstance(pt, int) and pt > 0:
                ptoks.append(pt)
        if not ttfts:
            out.append({"context": ctx, "state": "failed", "n": 0, "reason": err or "no request answered"})
            continue
        out.append({"context": ctx, "state": "measured", "n": len(ttfts), "ttft_ms_p50": round(statistics.median(ttfts), 2),
                    "prompt_tokens": int(statistics.median(ptoks)) if ptoks else None,
                    "reason": f"{requests_per_step - len(ttfts)} of {requests_per_step} requests failed: {err}"
                    if len(ttfts) < requests_per_step else ""})
    return out


# ---------------------------------------------------------------- tool-call reliability (TM-1267)

def _tool(name, desc, props, required):
    return {"type": "function", "function": {"name": name, "description": desc,
                                              "parameters": {"type": "object", "properties": props, "required": required}}}


_TOOLBOX = [
    _tool("get_weather", "Current weather for a city", {"city": {"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}}, ["city"]),
    _tool("search_docs", "Search the knowledge base", {"query": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 20}}, ["query"]),
    _tool("create_event", "Add a calendar event", {"title": {"type": "string"}, "start": {"type": "string"},
                                                     "attendees": {"type": "array", "items": {"type": "string"}}}, ["title", "start"]),
    _tool("calculate", "Evaluate an arithmetic expression", {"expression": {"type": "string"}}, ["expression"]),
]
_BUILTIN = [("What is the weather in Chicago right now? Use a tool.", "get_weather"),
            ("Look up our onboarding checklist in the docs and give me the top 5 hits.", "search_docs"),
            ("Put a design review on the calendar for 2026-11-03 at 14:00 with ana@example.com and bo@example.com.", "create_event"),
            ("What is 17 * 23 + 9? Use the calculator.", "calculate"),
            ("Is it cold in Oslo today? I want Fahrenheit.", "get_weather"),
            ("Find the incident runbook for disk pressure.", "search_docs")]


def builtin_tool_cases() -> list[Case]:
    """Used only for class agent when the set itself has no case that offers tools: six prompts over four common tool
    shapes (a string, an enum, a bounded integer, a list). Each expects one specific tool."""
    return [Case(f"builtin-tool-{i}", [{"role": "user", "content": text}], {"type": "tool_call", "name": want},
                 tools=list(_TOOLBOX), max_tokens=400) for i, (text, want) in enumerate(_BUILTIN)]


_TEXTUAL_CALL = re.compile(
    r"<tool_call>|<\|tool_call|\[TOOL_CALLS\]|<function_call>|<function=|<\|python_tag\|>"
    r"|\{\s*\"name\"\s*:\s*\"[^\"]+\"\s*,\s*\"(?:arguments|parameters)\"\s*:"
    r"|\{\s*\"(?:arguments|parameters)\"\s*:\s*[\{\"].*\"name\"\s*:", re.S)


def printed_as_text(content: str) -> bool:
    """A tool call the engine failed to lift out of the text: the model wrote it into `content` instead."""
    return bool(content) and _TEXTUAL_CALL.search(content) is not None


def classify_call(case: Case, reply: dict) -> dict:
    """What one reply says about tool-call reliability. {"parse_failure", "wrong_tool", "schema_violation"} as
    booleans, plus "parsed" (a well-formed call to an offered tool, so the schema check applied) and "why".
    parse_failure: a tool call whose arguments are not a JSON object, or a call printed into the text.
    wrong_tool: the case expects tool X and the reply called another, an unoffered one, or none.
    schema_violation: valid JSON arguments that break the tool's own parameters schema."""
    calls = reply.get("tool_calls") or []
    want = case.grade.get("name") if case.grade.get("type") == "tool_call" else None
    offered = {(t.get("function") or {}).get("name"): (t.get("function") or {}).get("parameters") or {} for t in case.tools}
    res = {"parse_failure": False, "wrong_tool": False, "schema_violation": False, "parsed": False, "expected": bool(want), "why": ""}
    if not calls:
        if printed_as_text(reply.get("content") or ""):
            res.update(parse_failure=True, why="a tool call was printed as text")
        if want:
            res.update(wrong_tool=True, why=res["why"] or f"expected {want}, no tool call")
        return res
    import jsonschema
    for c in calls:
        raw = c.get("arguments")
        try:
            args = json.loads(raw) if isinstance(raw, str) and raw.strip() else (raw if isinstance(raw, dict) else {})
        except ValueError:
            args = None
        if not isinstance(args, dict):
            res.update(parse_failure=True, why="arguments are not a JSON object")
            continue
        name = c.get("name")
        if name not in offered:
            res.update(wrong_tool=True, why=f"called {name!r}, which was not offered")
            continue
        res["parsed"] = True
        try:
            jsonschema.validate(args, offered[name])
        except jsonschema.ValidationError as e:
            res.update(schema_violation=True, why=f"schema: {e.message[:100]}")
        except jsonschema.SchemaError:
            pass                       # the case's own schema is broken: not the model's fault
    if want and not any(c.get("name") == want for c in calls):
        res.update(wrong_tool=True, why=res["why"] or f"called {calls[0].get('name')}, expected {want}")
    return res


def tool_reliability(base, key, model, cases, calls=100, workers=2, seed=1, max_tokens=512, health=None) -> dict:
    """`calls` completions at temperature 0.7, cycling through `cases`, each with its own seed, so the figure is the
    variance a deployment sees and not one deterministic draw. Returns {"n", "answered", "errors", "parse_failure_rate",
    "wrong_tool_rate", "schema_violation_rate", "n_expected", "n_parsed", "examples"}: parse failure over answered
    calls, wrong tool over answered calls that had an expected tool, schema violation over calls that parsed.
    If more than half the calls got no answer the route is not fit to measure and the leg aborts (a gateway that
    cannot answer must not read as a clean 0%)."""
    if not cases:
        raise ValueError("tool_reliability needs cases that offer tools")
    if health:
        health()

    def one(i):
        case = cases[i % len(cases)]
        try:
            r = cl.complete(base, key, model, case.messages, tools=case.tools, max_tokens=case.max_tokens or max_tokens,
                            temperature=0.7, seed=seed * 100_000 + i)
        except cl.GatewayError as e:
            return {"error": str(e)[:120], "case": case.id}
        out = classify_call(case, r)
        out["case"] = case.id
        return out
    with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
        rows = list(ex.map(one, range(calls)))
    ok = [r for r in rows if "error" not in r]
    errors = len(rows) - len(ok)
    if errors * 2 > len(rows):
        raise Aborted(f"{errors} of {len(rows)} tool-reliability calls to {model} got no answer ({rows[0].get('error', '')}): "
                      "the route is not fit to measure")
    n_exp = sum(1 for r in ok if r["expected"])
    n_parsed = sum(1 for r in ok if r["parsed"])

    def rate(k, den):
        return round(sum(1 for r in ok if r[k]) / den, 6) if den else 0.0
    return {"n": len(rows), "answered": len(ok), "errors": errors,
            "parse_failure_rate": rate("parse_failure", len(ok)), "wrong_tool_rate": rate("wrong_tool", n_exp),
            "schema_violation_rate": rate("schema_violation", n_parsed), "n_expected": n_exp, "n_parsed": n_parsed,
            "examples": [f"{r['case']}: {r['why']}" for r in ok if r["why"]][:5]}

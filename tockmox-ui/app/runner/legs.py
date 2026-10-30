# SPDX-License-Identifier: Apache-2.0
"""The legs of an evidence bundle (DESIGN-2026-10-29-eval-runner §4.1): the known-bad control, smoke, perf and
quality. Each leg returns plain data; run.py turns it into capability-result/1 twins and the verdict."""
from __future__ import annotations

import json
import secrets
import statistics
import threading
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import client as cl
from .evalset import EvalSet, grade


class Aborted(RuntimeError):
    """A leg stopped because the node or the gateway was not fit to measure (health, load, a production request)."""


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

    def check(name, fn):
        if health:
            health()
        try:
            ok, why = fn()
        except cl.GatewayError as e:
            ok, why = False, str(e)[:160]
        out.append({"name": name, "value": 1.0 if ok else 0.0, "unit": "bool", "n": 1, "why": why})

    def stop():
        r = cl.complete(base, key, model, [{"role": "user", "content": "Say hello in one word."}], max_tokens=32)
        return r["finish_reason"] == "stop", f"finish_reason {r['finish_reason']}"

    def tool():
        r = cl.complete(base, key, model, [{"role": "user", "content": "What time is it in Chicago? Use the tool."}],
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
        r = cl.complete(base, key, model, [{"role": "user", "content": 'Reply with a JSON object {"ok": true} and nothing else.'}],
                        response_format={"type": "json_object"}, max_tokens=64)
        try:
            return json.loads(r["content"].strip().strip("`").removeprefix("json").strip()).get("ok") is True, ""
        except (ValueError, AttributeError):
            return False, "not JSON"

    def stream():
        r = cl.complete(base, key, model, [{"role": "user", "content": "Count from one to five."}], max_tokens=64, stream=True)
        s = r["stream"]
        ok = s["done"] and s["usage_chunk"] and s["order_ok"] and s["events"] > 0 and r["finish_reason"] == "stop"
        return ok, "" if ok else f"stream {s}"

    def canary():
        token = "canary-" + secrets.token_hex(6)
        r = cl.complete(base, key, model, [{"role": "user", "content": f"Repeat exactly, with nothing else: {token}"}], max_tokens=64)
        return token in r["content"], "" if token in r["content"] else "the canary was not repeated verbatim"

    for name, fn in (("smoke_finish_stop", stop), ("smoke_tool_call_parses", tool), ("smoke_json_reply", jsonr),
                     ("smoke_stream_well_formed", stream), ("smoke_verbatim_canary", canary)):
        check(name, fn)
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

    def run_case(case):
        out = []
        for ep in range(es.epochs):
            try:
                r = cl.complete(base, key, model, case.messages, tools=case.tools or None,
                                response_format=case.response_format, max_tokens=case.max_tokens or es.max_tokens,
                                temperature=0.0 if ep == 0 else 0.7, seed=seed + ep)
                out.append(grade(case, r)[0])
            except cl.GatewayError:
                out.append(False)
        return out
    with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
        return list(ex.map(run_case, es.cases))

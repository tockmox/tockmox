# SPDX-License-Identifier: Apache-2.0
"""TM-1267 tool-call reliability, TM-1268 prefill, TM-1269 tradeoff: the runner's newer legs against stub gateways.
Each stub model has a behaviour (route name -> model name), as in test_runner.py."""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
import yaml

from app import models as ml
from app import results as rs
from app import verdict_stats as vs
from app.runner import __main__ as cli
from app.runner import evalset, legs
from app.runner.run import RunError, load_request, run
from tests.proto_support import verdict_record, verdicts
from tests.test_runner import REQ, WORD, _answer, make_set

TOOLS = [{"type": "function", "function": {"name": "get_time", "description": "time in a zone",
                                           "parameters": {"type": "object", "properties": {"tz": {"type": "string"}},
                                                          "required": ["tz"], "additionalProperties": False}}}]
GOOD_ARGS = json.dumps({"tz": "America/Chicago"})


def stub(behaviour, seen=None):
    """Models: good-* answer words right; half-* every other one. Suffixes: -flaky (arguments cut off on every 20th seed),
    -text (a <tool_call> printed in the reply on every 20th seed), -wrongtool, -badschema, -slow (0.4 s between stream
    chunks, else 0.1 s). A stream's first byte waits 0.0002 s per estimated prompt token (the prefill curve)."""
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            model = behaviour.get(body["model"], body["model"])
            msgs = body["messages"]
            prompt = " ".join(str(m.get("content", "")) for m in msgs)
            if seen is not None:
                seen.append(len(prompt))
            if body.get("tools") and "Use the tool" not in prompt:
                text, call = self.tool_reply(model, body)
            else:
                text, call = _answer(model.replace("-slow", ""), msgs, body)
            if body.get("stream"):
                time.sleep(len(prompt) / 4 * 0.0002)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                gap = 0.4 if "-slow" in model else 0.1
                for i, part in enumerate((text[: len(text) // 2], text[len(text) // 2:])):
                    if i:
                        time.sleep(gap)
                    ch = {"choices": [{"index": 0, "delta": {"content": part or " "}, "finish_reason": None}]}
                    self.wfile.write(b"data: " + json.dumps(ch).encode() + b"\n\n")
                    self.wfile.flush()
                self.wfile.write(b"data: " + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}).encode() + b"\n\n")
                self.wfile.write(b"data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": len(prompt) // 4, "completion_tokens": 12}}).encode() + b"\n\n")
                self.wfile.write(b"data: [DONE]\n\n")
                return
            msg = {"role": "assistant", "content": text}
            if call:
                msg["tool_calls"] = [{"id": "c1", "type": "function", "function": call}]
            b = json.dumps({"choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if call else "stop"}],
                            "usage": {"prompt_tokens": 5, "completion_tokens": 3}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def tool_reply(self, model, body):
            broken = body.get("seed", 1) % 20 == 0
            if "-flaky" in model and broken:
                return "", {"name": "get_time", "arguments": '{"tz": "Chic'}
            if "-text" in model and broken:
                return '<tool_call>{"name": "get_time", "arguments": {"tz": "x"}}</tool_call>', None
            if "-wrongtool" in model:
                return "", {"name": "get_date", "arguments": GOOD_ARGS}
            if "-badschema" in model:
                return "", {"name": "get_time", "arguments": json.dumps({"tz": 5})}
            return "", {"name": "get_time", "arguments": GOOD_ARGS}
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def tool_set(tmp_path, n=40, klass="agent", **meta):
    """A set whose cases offer get_time and expect it called (the quality leg grades the same calls)."""
    d = tmp_path / "tsets" / klass / "v1"
    d.mkdir(parents=True)
    (d / "set.yaml").write_text(yaml.safe_dump({"schema": "eval-set/1", "id": f"{klass}-tools", "version": "v1", "class": klass,
                                                "classification": "public", "criterion": f"tools/{klass}", "bar": 0.9, **meta}))
    rows = [{"id": f"t{i}", "messages": [{"role": "user", "content": f"Case {i}: what time is it in Chicago? Call get_time."}],
             "tools": TOOLS, "grade": {"type": "tool_call", "name": "get_time", "arguments": {}}} for i in range(n)]
    (d / "cases.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    return evalset.load(str(d))


ABS = {k: v for k, v in REQ.items() if k != "incumbent"}


def go(tmp_path, es, behaviour, req=None, seen=None, **kw):
    srv, url = stub(behaviour, seen)
    try:
        kw.setdefault("prefill_contexts", ())
        return run(req or ABS, es, gateway=url, key="k", node="mac-studio-m5", engine="mlx-lm", engine_version="0.32.2",
                   out=str(tmp_path / "site"), steps=(1,), perf_requests=3, today="2026-10-30", **kw)
    finally:
        srv.shutdown()


def twin(tmp_path, res, kind):
    for p, _ in res["twins"]:
        t = rs.parse((tmp_path / "site" / p).read_text(), p)
        if t.kind == kind:
            return t
    return None


def verdict(tmp_path, res):
    return json.loads((tmp_path / "site" / res["verdict_path"]).read_text())


# ---------------------------------------------------------------- TM-1267 tool-call reliability

def test_a_clean_candidate_passes_the_reliability_bar(tmp_path):
    res = go(tmp_path, tool_set(tmp_path), {"local-agent-next": "good"}, tool_calls=100)
    t = twin(tmp_path, res, "tool_reliability")
    m = {x.name: x for x in t.metrics}
    assert (m["parse_failure_rate"].value, m["parse_failure_rate"].n) == (0.0, 100)
    assert m["wrong_tool_rate"].value == 0.0 and m["schema_violation_rate"].value == 0.0 and m["schema_violation_rate"].n == 100
    assert t.environment["engine"] == "mlx-lm 0.32.2" and t.environment["tool_parse_bar"] == 0.02
    assert res["verdict"] == "pass"
    v = verdict(tmp_path, res)
    assert v["tool_reliability"]["n"] == 100 and v["tool_reliability"]["bar"] == 0.02 and "tool parse 0.0%" in v["summary"]


def test_five_percent_broken_tool_calls_fail_the_bar_and_the_verdict(tmp_path):
    res = go(tmp_path, tool_set(tmp_path), {"local-agent-next": "good-flaky"}, tool_calls=100)
    m = {x.name: x for x in twin(tmp_path, res, "tool_reliability").metrics}
    assert m["parse_failure_rate"].value == 0.05 and m["parse_failure_rate"].n == 100
    assert res["decision"]["verdict"] == "pass"                      # quality alone would have passed it ...
    assert res["verdict"] == "fail" and res["label"] == "worse"      # ... the bar fails it regardless
    v = verdict(tmp_path, res)
    assert "tool-call parse failures 5.0% (5 of 100 calls) are above this set's bar of 2.0%" in v["criterion"]
    assert "over the 2.0% bar" in v["summary"]
    ml.parse_verdict(json.dumps(v))                                   # the reader accepts what the writer wrote
    assert ml.count_passes(verdicts(json.dumps(v)), "local-agent", "good-model")[0] == []


def test_a_tool_call_printed_as_text_is_a_parse_failure(tmp_path):
    res = go(tmp_path, tool_set(tmp_path), {"local-agent-next": "good-text"}, tool_calls=100)
    assert res["tool_reliability"]["parse_failure_rate"] == 0.05 and res["verdict"] == "fail"
    for txt, want in [('<tool_call>{"name":"f"}</tool_call>', True), ('[TOOL_CALLS][{"name": "f"}]', True),
                      ('{"name": "get_time", "arguments": {"tz": "x"}}', True), ("The time is noon.", False),
                      ('{"name": "Ana", "age": 3}', False)]:
        assert legs.printed_as_text(txt) is want


def test_wrong_tool_and_schema_violations_are_measured_but_only_parse_failures_hold_the_bar(tmp_path):
    res = go(tmp_path, tool_set(tmp_path), {"local-agent-next": "good-wrongtool"}, tool_calls=20)
    r = res["tool_reliability"]
    assert r["wrong_tool_rate"] == 1.0 and r["parse_failure_rate"] == 0.0
    res2 = go(tmp_path / "b", tool_set(tmp_path / "b"), {"local-agent-next": "good-badschema"}, tool_calls=20)
    assert res2["tool_reliability"]["schema_violation_rate"] == 1.0 and res2["tool_reliability"]["n_parsed"] == 20


def test_the_sets_own_tool_parse_bar_is_the_bar(tmp_path):
    res = go(tmp_path, tool_set(tmp_path, tool_parse_bar=0.10), {"local-agent-next": "good-flaky"}, tool_calls=100)
    assert res["tool_reliability"]["parse_failure_rate"] == 0.05 and res["verdict"] == "pass"
    for bad in (1.5, -0.1, "high"):
        with pytest.raises(evalset.SetError, match="tool_parse_bar"):
            tool_set(tmp_path / f"x{bad}", tool_parse_bar=bad)


def test_the_leg_runs_for_tool_sets_and_class_agent_only(tmp_path):
    chat = make_set(tmp_path / "c", name="chat")
    req = dict(ABS, alias="local-chat", **{"class": "chat"})
    res = go(tmp_path / "c", chat, {"local-chat-next": "good"}, req=req, tool_calls=100)
    assert res["tool_reliability"] is None and twin(tmp_path / "c", res, "tool_reliability") is None
    agent = make_set(tmp_path / "a", name="agent")                    # class agent, no tool cases: the built-in battery
    res = go(tmp_path / "a", agent, {"local-agent-next": "good"}, tool_calls=12)
    assert res["tool_reliability"]["n"] == 12
    assert twin(tmp_path / "a", res, "tool_reliability").environment["cases_from"] == "built-in"
    res = go(tmp_path / "t", tool_set(tmp_path / "t", klass="chat"), {"local-chat-next": "good"}, req=req, tool_calls=10)
    assert res["tool_reliability"]["n"] == 10                          # a chat set whose cases offer tools


def test_a_route_that_answers_nothing_aborts_instead_of_reading_clean():
    srv, url = stub({})
    srv.shutdown()
    srv.server_close()
    case = legs.builtin_tool_cases()[0]
    with pytest.raises(Exception):
        legs.tool_reliability(url, "k", "m", [case], calls=4)


def test_the_chat_template_id_is_named_in_the_twin(tmp_path):
    res = go(tmp_path, tool_set(tmp_path), {"local-agent-next": "good"}, req=dict(ABS, chat_template="qwen3-tools-v2"),
             tool_calls=10, prefill_contexts=(64,), prefill_requests=1)
    assert twin(tmp_path, res, "tool_reliability").environment["chat_template"] == "qwen3-tools-v2"
    assert twin(tmp_path, res, "prefill").environment["chat_template"] == "qwen3-tools-v2"


# ---------------------------------------------------------------- TM-1268 prefill

def test_a_context_dependent_delay_gives_a_prefill_curve(tmp_path):
    res = go(tmp_path, make_set(tmp_path), {"local-agent-next": "good"}, prefill_contexts=(256, 1024, 4096), prefill_requests=2,
             tool_calls=0)
    t = twin(tmp_path, res, "prefill")
    m = {x.name: x for x in t.metrics}
    a, b, c = (m[f"ttft_ms_at_{k}"] for k in (256, 1024, 4096))
    assert a.value < b.value < c.value and c.value > 3 * a.value and a.n == b.n == c.n == 2
    assert (a.unit, c.context_tokens) == ("ms", 4096)
    assert abs(m["prompt_tokens_at_4096"].value - 4096) < 120          # the engine's count beside the 4-chars-per-token estimate
    assert "4 characters per token" in t.environment["context_estimate"]
    assert res["prefill"][0]["state"] == "measured"


def test_a_step_over_the_routes_limit_is_skipped_with_the_reason_and_never_sent(tmp_path):
    seen = []
    res = go(tmp_path, make_set(tmp_path), {"local-agent-next": "good"}, req=dict(ABS, max_input_tokens=2048), seen=seen,
             prefill_contexts=(256, 1024, 4096), prefill_requests=1, tool_calls=0)
    st = {x["context"]: x for x in res["prefill"]}
    assert st[4096]["state"] == "skipped" and "over the route's max input of 2048" in st[4096]["reason"]
    assert max(seen) < 4096 * 4 and not any(x.name == "ttft_ms_at_4096" for x in twin(tmp_path, res, "prefill").metrics)
    assert "over the route's max input" in twin(tmp_path, res, "prefill").environment["skipped_at_4096"]
    res = go(tmp_path / "b", make_set(tmp_path / "b"), {"local-agent-next": "good"}, route_info={"max_input_tokens": 300},
             prefill_contexts=(256, 1024), prefill_requests=1, tool_calls=0)       # the route's model_info works too
    assert [x["state"] for x in res["prefill"]] == ["measured", "skipped"]


def test_each_prefill_request_is_unique_so_a_prefix_cache_cannot_answer_it():
    assert legs.filler(512, "aaa") != legs.filler(512, "bbb")
    assert abs(len(legs.filler(512, "aaa")) - 512 * legs.CHARS_PER_TOKEN) < 60


# ---------------------------------------------------------------- TM-1269 tradeoff

PAIR = {"local-agent-next": "good-slow", "local-agent": "half"}


def test_better_but_four_times_slower_with_a_speed_criterion_reads_tradeoff_and_is_not_counted(tmp_path):
    req = dict(REQ, speed_criterion={"decode_tok_s_min_ratio": 0.5})
    res = go(tmp_path, make_set(tmp_path), PAIR, req=req)
    assert res["decision"]["quality_label"] == "better"
    assert res["label"] == "tradeoff" and res["verdict"] == "inconclusive"
    v = verdict(tmp_path, res)
    assert v["speed_criterion"] == {"decode_tok_s_min_ratio": 0.5} and 0.1 < v["speed"]["ratio"] < 0.4
    assert v["summary"].startswith("Better on quality (+0.50 pass rate), ") and "x slower decode" in v["summary"]
    assert any(rs.parse((tmp_path / "site" / r["path"]).read_text()).kind == "perf" and
               rs.parse((tmp_path / "site" / r["path"]).read_text()).model == "half-model" for r in v["results"])   # the incumbent was timed too
    pv = verdicts(json.dumps(v))
    counted, notes = ml.count_passes(pv, "local-agent", "good-model", "a" * 40, "half-model")
    assert counted == [] and any("tradeoff" in n for n in notes)


def test_the_same_pair_without_a_speed_criterion_is_a_counted_better(tmp_path):
    res = go(tmp_path, make_set(tmp_path), PAIR, req=REQ)
    assert res["label"] == "better" and res["verdict"] == "pass"
    v = verdict(tmp_path, res)
    assert "speed" not in v and "speed_criterion" not in v and v["summary"].startswith("Better on quality")
    assert len(ml.count_passes(verdicts(json.dumps(v)), "local-agent", "good-model", "a" * 40, "half-model")[0]) == 1


def test_a_candidate_that_meets_the_speed_criterion_stays_better(tmp_path):
    req = dict(REQ, speed_criterion={"decode_tok_s_min_ratio": 0.5})
    res = go(tmp_path, make_set(tmp_path), {"local-agent-next": "good", "local-agent": "half-slow"}, req=req)
    assert res["label"] == "better" and verdict(tmp_path, res)["speed"]["ratio"] > 1


def test_the_sets_speed_criterion_applies_and_a_request_may_override_it(tmp_path):
    es = make_set(tmp_path)
    d = tmp_path / "sets" / "agent" / "v1"
    (d / "set.yaml").write_text((d / "set.yaml").read_text() + "speed_criterion: {decode_tok_s_min_ratio: 0.5}\n")
    es = evalset.load(str(d))
    assert es.speed_criterion == {"decode_tok_s_min_ratio": 0.5}
    assert go(tmp_path, es, PAIR, req=REQ)["label"] == "tradeoff"
    assert go(tmp_path / "o", es, PAIR, req=dict(REQ, speed_criterion={"decode_tok_s_min_ratio": 0.05}))["label"] == "better"


def test_a_tool_bar_failure_beats_a_tradeoff(tmp_path):
    req = dict(REQ, speed_criterion={"decode_tok_s_min_ratio": 0.5})
    res = go(tmp_path, tool_set(tmp_path), {"local-agent-next": "good-flaky-slow", "local-agent": "half"}, req=req, tool_calls=100)
    assert res["verdict"] == "fail"


def test_summary_line_forms():
    d = vs.decide([(True, False)] * 31 + [(True, True)] * 9, 0.05, 0.05)
    assert vs.summary_line(d) == "Better on quality (+0.78 pass rate)"
    d = vs.apply_speed(d, {"decode_tok_s_min_ratio": 0.5}, 10.0, 43.0)
    assert d["label"] == "tradeoff" and vs.summary_line(d, {"parse_failure_rate": 0.0}, 0.02) == \
        "Better on quality (+0.78 pass rate), 4.3x slower decode, tool parse 0.0%"
    assert vs.apply_speed(vs.decide([(True, False)] * 31 + [(True, True)] * 9, 0.05, 0.05), {"decode_tok_s_min_ratio": 0.5}, 10, None)["verdict"] == "inconclusive"
    w = vs.apply_speed(vs.decide([(False, True)] * 20, 0.05, 0.05), {"decode_tok_s_min_ratio": 0.5}, 1.0, 40.0)
    assert w["label"] == "worse" and w["verdict"] == "fail"          # a fail is never softened into a tradeoff
    assert vs.summary_line(vs.decide_absolute(40, 40, 0.9)).startswith("Meets the quality bar")


# ---------------------------------------------------------------- the fields are checked when present; old verdicts still parse

BASE = dict(incumbent="old/Model-7B")


@pytest.mark.parametrize("extras,why", [
    ({"summary": "two\nlines"}, "summary"), ({"summary": ""}, "summary"), ({"summary": "x" * 400}, "summary"),
    ({"speed_criterion": {"decode_tok_s_min_ratio": 0}}, "speed_criterion"),
    ({"speed_criterion": {"min": 1}}, "speed_criterion"), ({"speed_criterion": 3}, "speed_criterion"),
    ({"speed": {"candidate_tok_s": 1, "incumbent_tok_s": 0, "ratio": 1}}, "speed must be"),
    ({"tool_reliability": {"parse_failure_rate": 2, "wrong_tool_rate": 0, "schema_violation_rate": 0, "n": 5}}, "tool_reliability"),
    ({"tool_reliability": {"parse_failure_rate": 0.1, "wrong_tool_rate": 0, "schema_violation_rate": 0, "n": 0}}, "tool_reliability"),
    ({"tool_reliability": {"parse_failure_rate": 0.1}}, "tool_reliability"),
    ({"label": "tradeoff"}, "needs the speed_criterion"),
])
def test_a_malformed_new_field_is_refused(extras, why):
    with pytest.raises(ml.LifecycleError, match=why):
        ml.parse_verdict(verdict_record("n/New-7B", "local-agent", verdict="inconclusive", **BASE, extras=extras))


def test_a_tradeoff_verdict_parses_only_as_inconclusive_and_old_records_parse_as_before():
    ok = {"label": "tradeoff", "speed_criterion": {"decode_tok_s_min_ratio": 0.5}, "summary": "Better on quality (+0.12 pass rate), 4.3x slower decode",
          "speed": {"candidate_tok_s": 10, "incumbent_tok_s": 43, "ratio": 0.23},
          "tool_reliability": {"parse_failure_rate": 0.0, "wrong_tool_rate": 0.0, "schema_violation_rate": 0.01, "n": 100, "bar": 0.02}}
    v = ml.parse_verdict(verdict_record("n/New-7B", "local-agent", verdict="inconclusive", **BASE, extras=ok))
    assert v.extras["label"] == "tradeoff" and v.extras["tool_reliability"]["n"] == 100 and v.extras["speed"]["ratio"] == 0.23
    with pytest.raises(ml.LifecycleError, match="means verdict inconclusive"):
        ml.parse_verdict(verdict_record("n/New-7B", "local-agent", verdict="pass", **BASE, extras=ok))
    old = ml.parse_verdict(verdict_record("n/New-7B", "local-agent", **BASE, extras={"label": "better", "n": 40}))
    assert old.extras["label"] == "better" and old.extras["n"] == 40 and old.verdict == "pass"
    assert all(k not in ml.parse_verdict(verdict_record("n/New-7B", "local-agent", **BASE)).extras
               for k in ("summary", "speed", "speed_criterion", "tool_reliability"))


def test_malformed_request_fields_are_refused(tmp_path):
    for bad, why in [({"speed_criterion": {"decode_tok_s_min_ratio": -1}}, "speed_criterion"), ({"max_input_tokens": "big"}, "max_input_tokens"),
                     ({"max_input_tokens": 0}, "max_input_tokens"), ({"chat_template": "has space"}, "chat_template")]:
        p = tmp_path / "r.yaml"
        p.write_text(yaml.safe_dump(dict(ABS, **bad)))
        with pytest.raises(RunError, match=why):
            load_request(str(p))
    p = tmp_path / "ok.yaml"
    p.write_text(yaml.safe_dump(dict(ABS, max_input_tokens=32768, chat_template="qwen3-v2", speed_criterion={"decode_tok_s_min_ratio": 0.5})))
    assert load_request(str(p))["max_input_tokens"] == 32768


def test_the_results_module_takes_the_new_kinds():
    assert {"prefill", "tool_reliability"} <= set(rs.KINDS)


# ---------------------------------------------------------------- the command line

def test_the_cli_flags_reach_the_legs(tmp_path, monkeypatch, capsys):
    es = make_set(tmp_path)
    rq = tmp_path / "req.yaml"
    rq.write_text(yaml.safe_dump(ABS))
    srv, url = stub({"local-agent-next": "good"})
    monkeypatch.setenv("EVAL_GATEWAY_KEY", "k")
    try:
        rc = cli.main(["run", str(rq), "--set", es.path, "--gateway", url, "--node", "mac-studio-m5", "--engine", "mlx-lm",
                       "--engine-version", "0.32.2", "--out", str(tmp_path / "site"), "--steps", "1", "--perf-requests", "2",
                       "--tool-reliability-calls", "8", "--prefill-contexts", "128,512,4096", "--prefill-requests", "1",
                       "--max-input-tokens", "1000"])
    finally:
        srv.shutdown()
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["summary"] and len(out["twins"]) == 5
    pf = next(rs.parse((tmp_path / "site" / p).read_text()) for p in out["twins"] if "-prefill-" in p)
    assert [m.name for m in pf.metrics if m.name.startswith("ttft")] == ["ttft_ms_at_128", "ttft_ms_at_512"]
    tr = next(rs.parse((tmp_path / "site" / p).read_text()) for p in out["twins"] if "-tool_reliability-" in p)
    assert tr.metric("call_error_rate").n == 8
    monkeypatch.setattr("sys.argv", ["x"])
    assert cli.main(["run", str(rq), "--set", es.path, "--gateway", url, "--node", "n", "--engine", "e", "--engine-version", "1",
                     "--out", str(tmp_path / "s2"), "--prefill-contexts", "4k"]) == 2


def test_the_compare_page_renders_a_tradeoff_verdict_and_says_it_did_not_count(tmp_path):
    from tests.test_models_compare_alias import FULL, client, rec
    ex = {**FULL, "label": "tradeoff", "speed_criterion": {"decode_tok_s_min_ratio": 0.5},
          "summary": "Better on quality (+0.12 pass rate), 4.3x slower decode"}
    c, u = client(tmp_path, rec(extras=ex, verdict="inconclusive"))
    r = c.get("/models/v/r1")
    assert r.status_code == 200 and "inconclusive" in r.text.lower()


# ---------------------------------------------------------------- the progress hook

def _states(events):
    return [(e[0], e[1]) for e in events]


def test_progress_reports_every_leg_in_order_with_plain_summaries(tmp_path):
    ev = []
    req = dict(REQ, speed_criterion={"decode_tok_s_min_ratio": 0.5})
    res = go(tmp_path, tool_set(tmp_path), {"local-agent-next": "good", "local-agent": "half"}, req=req, tool_calls=10,
             prefill_contexts=(64, 128), prefill_requests=1, progress=lambda *a: ev.append(a))
    legs_in_order = ["control", "smoke", "perf", "perf_incumbent", "prefill", "tool_reliability", "quality", "quality_incumbent"]
    assert _states(ev) == [(l, s) for l in legs_in_order for s in ("running", "done")]
    done = {e[0]: e for e in ev if e[1] == "done"}
    assert "5 of 5 checks passed" in done["smoke"][2] and done["smoke"][3]["smoke_finish_stop"] == 1.0
    assert done["prefill"][3].keys() == {"ttft_ms_at_64", "ttft_ms_at_128"} and done["tool_reliability"][3]["n"] == 10
    assert done["perf"][3]["decode_tps_p50@c1"] > 0 and done["quality"][3]["n"] == 40
    low = " ".join(e[2] for e in ev).lower()
    assert "better" not in low and "worse" not in low and "winner" not in low and res["label"]


def test_progress_says_skipped_for_legs_that_do_not_run(tmp_path):
    ev = []
    go(tmp_path, make_set(tmp_path, name="chat"), {"local-chat-next": "good"}, req=dict(ABS, alias="local-chat", **{"class": "chat"}),
       tool_calls=100, prefill_contexts=(), progress=lambda *a: ev.append(a))
    assert _states(ev) == [("control", "running"), ("control", "done"), ("smoke", "running"), ("smoke", "done"),
                           ("perf", "running"), ("perf", "done"), ("prefill", "skipped"), ("tool_reliability", "skipped"),
                           ("quality", "running"), ("quality", "done")]
    skipped = {e[0]: e[2] for e in ev if e[1] == "skipped"}
    assert "turned off" in skipped["prefill"] and "offers no tools" in skipped["tool_reliability"]
    ev2 = []
    go(tmp_path / "b", make_set(tmp_path / "b"), {"local-agent-next": "good"}, tool_calls=0, progress=lambda *a: ev2.append(a))
    assert [e[2] for e in ev2 if e[0] == "tool_reliability"] == ["turned off: 0 calls were asked for"]


def test_progress_reports_failed_before_an_abort_propagates(tmp_path):
    ev, calls = [], []

    def health():
        calls.append(1)
        if len(calls) > 6:                       # five smoke checks, one perf step, then the tool leg's check is the seventh
            raise legs.Aborted("node unhealthy")
    with pytest.raises(legs.Aborted):
        go(tmp_path, make_set(tmp_path), {"local-agent-next": "good"}, health=health, progress=lambda *a: ev.append(a))
    assert _states(ev)[-2:] == [("tool_reliability", "running"), ("tool_reliability", "failed")] \
        and ev[-1][2] == "node unhealthy"
    assert ("perf", "done") in _states(ev)
    assert ("quality", "running") not in _states(ev)
    ev = []                                       # a control that does not fail stops the run at the first leg
    bad = make_set(tmp_path / "c", grade={"type": "contains", "all": ["control"]})
    with pytest.raises(RunError):
        go(tmp_path / "c", bad, {"local-agent-next": "good"}, progress=lambda *a: ev.append(a))
    assert _states(ev) == [("control", "running"), ("control", "failed")] and "known-bad control" in ev[-1][2]


def test_a_progress_callback_that_raises_does_not_break_the_run(tmp_path):
    seen = []

    def boom(*a):
        seen.append(a[:2])
        raise RuntimeError("status disk full")
    res = go(tmp_path, make_set(tmp_path), {"local-agent-next": "good"}, progress=boom)
    assert res["verdict"] == "pass" and ("quality", "done") in seen

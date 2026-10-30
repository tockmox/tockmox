# SPDX-License-Identifier: Apache-2.0
"""HL-0917: the eval runner v0 against stub OpenAI-compatible gateways. Each stub model has a behaviour, so every
outcome the runner can produce is produced here: better, worse, absolute bars, a control that does not fail, a
broken stream, the data-class rails (TM-1249), and an unhealthy node."""
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
import yaml

from app import models as ml
from app import results as rs
from app.runner import evalset, legs
from app.runner.run import RunError, run

WORD = re.compile(r"the word (\w+)")


def _answer(model, messages, body):
    """What each stub model says. `good` is always right; `half` is right on even-numbered words only; `broken-stream`
    is right but streams without [DONE]."""
    text = " ".join(str(m.get("content", "")) for m in messages)
    if "Repeat exactly" in text:
        return text.split(":", 1)[1].strip(), None
    if body.get("tools") and "Use the tool" in text:
        return "", {"name": "get_time", "arguments": json.dumps({"tz": "America/Chicago"})}
    if body.get("response_format"):
        return '{"ok": true}', None
    m = WORD.search(text)
    if m:
        w = m.group(1)
        if model.startswith("half") or model.endswith("local-x"):
            n = int(re.sub(r"\D", "", w) or 0)
            return (w if n % 2 == 0 else "wrong"), None
        return w, None
    return "hello", None


def gateway(behaviour):
    """A stub gateway. `behaviour` maps a route name to a stub model name. `_tiers` ({route: tier}) answers GET
    /model/info as LiteLLM does; `_seen` (a list) collects every chat request's tags (TM-1249)."""
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path.startswith("/model/info") and "_tiers" in behaviour:
                b = json.dumps({"data": [{"model_name": k, "model_info": {"endpoint_tier": v}}
                                         for k, v in behaviour["_tiers"].items()]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
                return
            self.send_response(200 if behaviour.get("_healthy", True) else 503)
            self.end_headers()

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            if "_seen" in behaviour:
                behaviour["_seen"].append(body.get("tags"))
            model = behaviour.get(body["model"], body["model"])
            text, call = _answer(model, body["messages"], body)
            if model.startswith("thinker"):
                self.think(body)
                return
            if body.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for part in (text[: len(text) // 2], text[len(text) // 2:]):
                    ch = {"choices": [{"index": 0, "delta": {"content": part}, "finish_reason": None}]}
                    self.wfile.write(b"data: " + json.dumps(ch).encode() + b"\n\n")
                self.wfile.write(b"data: " + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}).encode() + b"\n\n")
                self.wfile.write(b"data: " + json.dumps({"choices": [], "usage": {"completion_tokens": 12}}).encode() + b"\n\n")
                if model != "broken-stream":
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
        def think(self, body):
            """TM-1295: a thinking model whose route did not turn thinking off. It reasons until max_tokens and answers
            nothing: finish_reason length, empty content, the reasoning beside it (as mlx-lm and LiteLLM return it)."""
            if body.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for d, fin in (({"reasoning_content": "Let me think about"}, None), ({"reasoning_content": " this carefully."}, None),
                               ({}, "length")):
                    ch = {"choices": [{"index": 0, "delta": d, "finish_reason": fin}]}
                    self.wfile.write(b"data: " + json.dumps(ch).encode() + b"\n\n")
                self.wfile.write(b"data: " + json.dumps({"choices": [], "usage": {"completion_tokens": body["max_tokens"]}}).encode() + b"\n\n")
                self.wfile.write(b"data: [DONE]\n\n")
                return
            msg = {"role": "assistant", "content": "", "reasoning_content": "Let me think about this carefully."}
            b = json.dumps({"choices": [{"index": 0, "message": msg, "finish_reason": "length"}],
                            "usage": {"prompt_tokens": 5, "completion_tokens": body["max_tokens"]}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def make_set(tmp_path, n=40, classification="public", grade=None, name="agent"):
    d = tmp_path / "sets" / name / "v1"
    d.mkdir(parents=True)
    (d / "set.yaml").write_text(yaml.safe_dump({"schema": "eval-set/1", "id": f"{name}-words", "version": "v1", "class": name,
                                                "classification": classification, "criterion": f"words/{name}",
                                                "margin": 0.05, "min_effect": 0.05, "bar": 0.9, "epochs": 1}))
    rows = [{"id": f"c{i}", "messages": [{"role": "user", "content": f"Answer with the word w{i} and nothing else."}],
             "grade": grade or {"type": "exact", "value": f"w{i}"}} for i in range(n)]
    (d / "cases.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    return evalset.load(str(d))


REQ = {"schema": "eval-request/1", "alias": "local-agent", "class": "agent", "runs": 1,
       "candidate": {"model": "good-model", "revision": "a" * 40}, "incumbent": {"model": "half-model"}}


def _run(tmp_path, es, behaviour, req=None, **kw):
    srv, url = gateway(behaviour)
    try:
        kw.setdefault("tool_calls", 0)              # the prefill and tool-reliability legs have their own tests
        kw.setdefault("prefill_contexts", ())       # (tests/test_runner_legs.py); here they stay off
        return run(req or REQ, es, gateway=url, key="k", node="mac-studio-m5", engine="mlx-lm", engine_version="0.32.2",
                   out=str(tmp_path / "site"), steps=(1,), perf_requests=4, today="2026-10-29", **kw)
    finally:
        srv.shutdown()


def test_a_better_candidate_gets_a_passing_verdict_with_hashed_twins(tmp_path):
    es = make_set(tmp_path)
    res = _run(tmp_path, es, {"local-agent-next": "good", "local-agent": "half"})
    assert res["verdict"] == "pass" and res["label"] == "better" and not res["control"]["passed"]
    d = res["decision"]
    assert (d["wins"], d["losses"], d["n"]) == (20, 0, 40)
    site = tmp_path / "site"
    text = (site / res["verdict_path"]).read_text()
    v = ml.parse_verdict(text, res["verdict_path"])
    assert v.extras["label"] == "better" and v.extras["control"] == {"passed": False, "cases": 40}
    assert v.extras["engine"] == {"id": "mlx-lm", "version": "0.32.2", "flags": ""} and v.extras["set_sha256"] == es.sha256
    kinds = set()
    import hashlib
    for r in v.results:
        body = (site / r["path"]).read_text()
        assert hashlib.sha256(body.encode()).hexdigest() == r["sha256"]
        kinds.add(rs.parse(body).kind)
    assert kinds == {"smoke", "perf", "quality"}
    assert (site / "evals/methodology/runner-v1.md").exists()
    counted, _ = ml.count_passes([v], "local-agent", "good-model", "a" * 40, "half-model")
    assert len(counted) == 1


def test_a_worse_candidate_fails(tmp_path):
    es = make_set(tmp_path)
    req = dict(REQ, candidate={"model": "half-model"}, incumbent={"model": "good-model"})
    res = _run(tmp_path, es, {"local-agent-next": "half", "local-agent": "good"}, req=req)
    assert res["verdict"] == "fail" and res["label"] == "worse"


def test_no_incumbent_is_judged_on_absolute_bars(tmp_path):
    es = make_set(tmp_path)
    req = {k: v for k, v in REQ.items() if k != "incumbent"}
    res = _run(tmp_path, es, {"local-agent-next": "good"}, req=req)
    assert res["decision"]["method"] == "wilson" and res["verdict"] == "pass"
    v = ml.parse_verdict((tmp_path / "site" / res["verdict_path"]).read_text())
    assert v.absolute and v.extras["bar"] == 0.9


def test_a_control_that_does_not_fail_stops_the_run(tmp_path):
    es = make_set(tmp_path, grade={"type": "contains", "all": ["control"]})   # the known-bad reply contains "control"
    with pytest.raises(RunError, match="known-bad control passed"):
        _run(tmp_path, es, {"local-agent-next": "good", "local-agent": "half"})
    assert not (tmp_path / "site").exists()            # nothing written: no numbers from graders that cannot fail


def test_a_broken_stream_fails_smoke_and_the_verdict(tmp_path):
    es = make_set(tmp_path)
    res = _run(tmp_path, es, {"local-agent-next": "broken-stream", "local-agent": "half"})
    assert any(m["name"] == "smoke_stream_well_formed" and m["value"] == 0.0 for m in res["smoke"])
    assert res["verdict"] == "fail" and "smoke failed" in json.loads((tmp_path / "site" / res["verdict_path"]).read_text())["criterion"]


@pytest.mark.parametrize("classification", ["internal", "confidential", "restricted"])
def test_data_above_public_goes_to_no_route_the_gateway_does_not_report_as_local(tmp_path, classification):
    """TM-1249: unknown tier counts as not local, so a gateway that says nothing gets public data only."""
    es = make_set(tmp_path, classification=classification)
    with pytest.raises(RunError, match="not known to be local"):
        _run(tmp_path, es, {})
    with pytest.raises(RunError, match="route local-agent-next is external"):
        _run(tmp_path, es, {"_tiers": {"local-agent-next": "external", "local-agent": "local"}})
    with pytest.raises(RunError, match="route local-agent is external"):       # the incumbent's route is held too
        _run(tmp_path, es, {"_tiers": {"local-agent-next": "local", "local-agent": "external"}})


@pytest.mark.parametrize("classification,tag", [("public", "open"), ("internal", "internal"), ("confidential", "restricted"),
                                                ("restricted", "restricted")])
def test_on_local_routes_every_request_carries_the_sets_class_as_a_tag(tmp_path, classification, tag):
    es = make_set(tmp_path, classification=classification)
    seen = []
    res = _run(tmp_path, es, {"local-agent-next": "good", "local-agent": "half", "_seen": seen,
                              "_tiers": {"local-agent-next": "local", "local-agent": "local"}})
    assert res["verdict"] == "pass" and seen and all(t == [tag] for t in seen)


def test_a_hosted_candidate_gets_public_data_only(tmp_path):
    """The hosted-candidate refusal that held until TM-1249 is now the class rail: an external route takes public sets."""
    tiers = {"local-agent-next": "external", "local-agent": "local"}
    es = make_set(tmp_path)
    seen = []
    res = _run(tmp_path, es, {"local-agent-next": "good", "local-agent": "half", "_tiers": tiers, "_seen": seen},
               req=dict(REQ, candidate={"model": "anthropic/claude-x"}))
    assert res["verdict"] == "pass" and all(t == ["open"] for t in seen)


def test_one_row_above_its_sets_class_raises_the_whole_run(tmp_path):
    es = make_set(tmp_path)
    rows = [json.loads(x) for x in open(os.path.join(es.path, "cases.jsonl"))]
    rows[3]["classification"] = "restricted"
    open(os.path.join(es.path, "cases.jsonl"), "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
    es = evalset.load(es.path)
    assert evalset.run_class(es) == "restricted" and es.cases[3].classification == "restricted"
    with pytest.raises(RunError, match=r"carries restricted data \(1 of 40 cases above public\)"):
        _run(tmp_path, es, {"_tiers": {"local-agent-next": "external", "local-agent": "local"}})
    rows[3]["classification"] = "secret"
    open(os.path.join(es.path, "cases.jsonl"), "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
    with pytest.raises(evalset.SetError, match="classification must be one of"):
        evalset.load(es.path)


def test_an_unhealthy_node_aborts(tmp_path):
    es = make_set(tmp_path)

    def health():
        raise legs.Aborted("node unhealthy")
    with pytest.raises(legs.Aborted):
        _run(tmp_path, es, {"local-agent-next": "good", "local-agent": "half"}, health=health)


def test_a_screening_set_cannot_say_better(tmp_path):
    es = make_set(tmp_path, n=8)
    res = _run(tmp_path, es, {"local-agent-next": "good", "local-agent": "half"})
    assert res["decision"]["screening"] and res["label"] != "better"


def test_an_unclassified_set_does_not_load(tmp_path):
    d = tmp_path / "s"
    d.mkdir()
    (d / "set.yaml").write_text("schema: eval-set/1\nid: x\nversion: v1\nclass: agent\ncriterion: c\n")
    (d / "cases.jsonl").write_text(json.dumps({"id": "a", "messages": [{"role": "user", "content": "x"}],
                                               "grade": {"type": "exact", "value": "x"}}) + "\n")
    with pytest.raises(evalset.SetError, match="classification is required"):
        evalset.load(str(d))


def test_graders(tmp_path):
    c = evalset.Case("t", [{"role": "user", "content": "x"}], {"type": "tool_call", "name": "f", "arguments": {"a": 1}},
                     tools=[{"type": "function", "function": {"name": "f"}}])
    assert evalset.grade(c, {"tool_calls": [{"name": "f", "arguments": '{"a": 1, "b": 2}'}]})[0]
    assert not evalset.grade(c, {"tool_calls": [{"name": "f", "arguments": '{"a": 2}'}]})[0]
    assert not evalset.grade(c, {"tool_calls": []})[0]
    j = evalset.Case("j", [{"role": "user", "content": "x"}], {"type": "json_schema", "schema": {"type": "object", "required": ["ok"]}})
    assert evalset.grade(j, {"content": '```json\n{"ok": 1}\n```'})[0] and not evalset.grade(j, {"content": "nope"})[0]

# SPDX-License-Identifier: Apache-2.0
"""TM-1295: a thinking model behind a route that leaves thinking on answers nothing within max_tokens. The runner must
say so and write no verdict (a Worse verdict there measures the route, not the model), and fixing the route must
schedule a new run (the route's provider and params are part of the run key)."""
import os

import pytest
import yaml

from app.runner import __main__ as cli
from app.runner import client as cl
from app.runner import legs
from app.runner import scheduler as sch
from app.runner import status as st

from .test_runner import REQ, gateway, make_set
from .test_runner_scheduler import config, run_once, statuses


@pytest.fixture(autouse=True)
def fixture_sets(monkeypatch):
    monkeypatch.setattr(sch, "builtin_sets_dir", lambda: os.path.join(os.path.dirname(__file__), "fixtures", "evalsets"))


# ------------------------------------------------------------------ the client counts reasoning

@pytest.mark.parametrize("stream", [False, True])
def test_the_client_reports_reasoning_beside_an_empty_answer(stream):
    srv, url = gateway({"m": "thinker"})
    try:
        r = cl.complete(url, "k", "m", [{"role": "user", "content": "Say hello."}], max_tokens=32, stream=stream)
    finally:
        srv.shutdown()
    assert r["finish_reason"] == "length" and r["content"] == "" and r["reasoning_chars"] > 0


def test_a_plain_answer_has_no_reasoning():
    srv, url = gateway({"m": "good"})
    try:
        r = cl.complete(url, "k", "m", [{"role": "user", "content": "Say hello."}], max_tokens=32)
    finally:
        srv.shutdown()
    assert r["reasoning_chars"] == 0 and r["content"]


@pytest.mark.parametrize("reply,spent", [
    ({"finish_reason": "length", "content": "", "tool_calls": []}, True),
    ({"finish_reason": "length", "content": "  \n", "tool_calls": []}, True),
    ({"finish_reason": "length", "content": "a long answer cut short", "tool_calls": []}, False),   # cut, but it answered
    ({"finish_reason": "length", "content": "", "tool_calls": [{"name": "get_time"}]}, False),
    ({"finish_reason": "stop", "content": "", "tool_calls": []}, False),                            # an empty answer, not the budget
])
def test_budget_spent_is_an_empty_reply_cut_at_max_tokens(reply, spent):
    assert legs.budget_spent(reply) is spent


# ------------------------------------------------------------------ the legs refuse

def test_smoke_stops_with_the_cause_when_the_model_only_thinks():
    srv, url = gateway({"m": "thinker"})
    try:
        with pytest.raises(legs.BudgetSpent) as e:
            legs.smoke(url, "k", "m")
    finally:
        srv.shutdown()
    msg = str(e.value)
    assert "5 of 5 replies from m" in msg and "reasoning" in msg and "enable_thinking false" in msg and "max_tokens" in msg


def test_smoke_still_passes_a_model_that_answers():
    srv, url = gateway({"m": "good"})
    try:
        out = legs.smoke(url, "k", "m")
    finally:
        srv.shutdown()
    assert all(m["value"] == 1.0 for m in out)


def _quality_with(monkeypatch, tmp_path, spent_ids):
    """quality() over 10 cases where the cases in spent_ids come back empty at max_tokens with reasoning."""
    es = make_set(tmp_path, n=10)

    def fake(base, key, model, messages, **kw):
        n = int(messages[0]["content"].split("word w", 1)[1].split()[0])
        if n in spent_ids:
            return {"content": "", "tool_calls": [], "finish_reason": "length", "reasoning_chars": 40}
        return {"content": f"w{n}", "tool_calls": [], "finish_reason": "stop", "reasoning_chars": 0}
    monkeypatch.setattr(legs.cl, "complete", fake)
    return legs.quality("http://unused", "k", "m", es, workers=3)


def test_quality_stops_when_half_the_answers_ran_out_of_tokens(monkeypatch, tmp_path):
    with pytest.raises(legs.BudgetSpent, match=r"5 of 10 replies from m .*reasoning"):
        _quality_with(monkeypatch, tmp_path, set(range(5)))


def test_quality_grades_a_few_cut_answers_as_failures(monkeypatch, tmp_path):
    res = _quality_with(monkeypatch, tmp_path, {0, 1, 2})
    assert [all(r) for r in res] == [False] * 3 + [True] * 7


def test_the_run_fails_with_the_cause_and_writes_no_verdict(tmp_path, monkeypatch):
    run_id = "agent-local-agent-20261030-1"
    d = st.new_status(run_id, "local-agent", "agent", {"model": "good-model"}, {"model": "half-model"}, "mac-studio-m5",
                      {"id": "mlx-lm", "version": "0.32.2"}, {"id": "agent-words", "version": "v1", "sha256": "0" * 64},
                      "admitted", {"legs": ["control", "smoke", "perf", "quality"], "estimated_seconds": 1, "disk_gib": None,
                                   "window": "next quiet window"}, "queued")
    st.write_status(st.path_for(str(tmp_path / "evals"), run_id), d)
    es = make_set(tmp_path)
    srv, url = gateway({"local-agent-next": "thinker", "local-agent": "half"})
    (tmp_path / "req.yaml").write_text(yaml.safe_dump(REQ))
    monkeypatch.setenv("EVAL_GATEWAY_KEY", "k")
    try:
        rc = cli.main(["run", str(tmp_path / "req.yaml"), "--set", es.path, "--gateway", url, "--node", "mac-studio-m5",
                       "--engine", "mlx-lm", "--engine-version", "0.32.2", "--out", str(tmp_path / "evals" / "site"),
                       "--steps", "1", "--perf-requests", "4", "--status-dir", str(tmp_path / "evals"), "--run-id", run_id])
    finally:
        srv.shutdown()
    d = st.read_status(st.path_for(str(tmp_path / "evals"), run_id))
    assert rc == 1 and d["state"] == "failed" and d["verdict_path"] is None and d["label"] is None
    assert "spent the whole token budget reasoning" in d["reason"] and "enable_thinking" in d["reason"]
    by = {lg["name"]: lg["state"] for lg in d["legs"]}
    assert by["smoke"] == "failed" and by["quality"] == "skipped"
    assert not (tmp_path / "evals" / "site" / "evals" / "verdicts").exists() or \
        not os.listdir(tmp_path / "evals" / "site" / "evals" / "verdicts")


# ------------------------------------------------------------------ a route change schedules a new run

def _finish_all(tmp_path, state="failed"):
    for s in statuses(tmp_path):
        st.write_status(st.path_for(str(tmp_path / "evals"), s["run_id"]), dict(s, state=state, reason="measured the route"))


def _next(cfg):
    return next(r for r in cfg["inferenceNodes"]["routes"] if r["alias"] == "local-large-next")


def test_a_route_without_params_keeps_the_digest_every_earlier_status_had(tmp_path):
    assert sch.route_digest(type("R", (), {"params": {}, "provider": ""})()) == ""
    cfg = config(tmp_path)
    run_once(cfg)
    [s] = statuses(tmp_path)
    assert s["route_digest"] == ""
    _finish_all(tmp_path)
    kube, _ = run_once(cfg)
    assert kube.created == [] and len(statuses(tmp_path)) == 1          # a failed run is still not retried by itself


def test_turning_thinking_off_on_the_route_schedules_a_new_run(tmp_path):
    cfg = config(tmp_path)
    run_once(cfg)
    _finish_all(tmp_path)
    _next(cfg).update(provider="openai", params={"max_tokens": 8192,
                                                 "extra_body": {"chat_template_kwargs": {"enable_thinking": False}}})
    kube, _ = run_once(cfg)
    assert len(kube.created) == 1
    new = next(s for s in statuses(tmp_path) if s["state"] == "queued")
    assert len(new["route_digest"]) == 16 and new["run_id"].endswith("-2")
    _finish_all(tmp_path, "done")
    kube, _ = run_once(cfg)
    assert kube.created == []                                             # the same params again: done, nothing new
    _next(cfg)["params"]["max_tokens"] = 16384
    kube, _ = run_once(cfg)
    assert len(kube.created) == 1                                         # any param change counts


def test_the_digest_ignores_key_order_and_rejects_a_bad_status_value():
    a = type("R", (), {"params": {"a": 1, "b": {"x": 1, "y": 2}}, "provider": "openai"})()
    b = type("R", (), {"params": {"b": {"y": 2, "x": 1}, "a": 1}, "provider": "openai"})()
    assert sch.route_digest(a) == sch.route_digest(b)
    d = st.new_status("r", "a", "c", {"model": "m"}, None, "n", {"id": "e", "version": "1"},
                      {"id": "s", "version": "v1", "sha256": "0" * 64}, "admitted",
                      {"legs": ["smoke"], "estimated_seconds": 1, "disk_gib": None, "window": "w"}, "queued")
    assert st.validate(dict(d, route_digest="ab12")) == []
    assert any("route_digest" in b for b in st.validate(dict(d, route_digest="not hex!")))

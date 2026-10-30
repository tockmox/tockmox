# SPDX-License-Identifier: Apache-2.0
"""TM-1261, TM-1264: `python -m app.runner run --status-dir --run-id` keeps the run-status/1 file true leg by leg, the
engine-upgrade run writes twins and no verdict, and a regression is a sentence in the reason."""
import json

import yaml

from app.runner import __main__ as cli
from app.runner import status as st

from .test_runner import REQ, gateway, make_set


def seed(tmp_path, run_id, legs, trigger="admitted", engine="0.32.2", alias="local-agent", model="good-model", **kw):
    d = st.new_status(run_id, alias, "agent", {"model": model}, {"model": "half-model"}, "mac-studio-m5",
                      {"id": "mlx-lm", "version": engine}, {"id": "agent-words", "version": "v1", "sha256": "0" * 64}, trigger,
                      {"legs": legs, "estimated_seconds": 1, "disk_gib": None, "window": "next quiet window"}, "queued")
    d.update(kw)
    st.write_status(st.path_for(str(tmp_path / "evals"), run_id), d)


def invoke(tmp_path, monkeypatch, behaviour, run_id, extra=(), req=None):
    es = make_set(tmp_path)
    srv, url = gateway(behaviour)
    (tmp_path / "req.yaml").write_text(yaml.safe_dump(req or REQ))
    monkeypatch.setenv("EVAL_GATEWAY_KEY", "k")
    try:
        rc = cli.main(["run", str(tmp_path / "req.yaml"), "--set", es.path, "--gateway", url, "--node", "mac-studio-m5",
                       "--engine", "mlx-lm", "--engine-version", "0.32.2", "--out", str(tmp_path / "evals" / "site"),
                       "--steps", "1", "--perf-requests", "4", "--status-dir", str(tmp_path / "evals"), "--run-id", run_id,
                       *extra])
    finally:
        srv.shutdown()
    return rc, st.read_status(st.path_for(str(tmp_path / "evals"), run_id))


def test_a_full_run_moves_the_status_through_its_legs_to_done_with_the_verdict_and_label(tmp_path, monkeypatch):
    seed(tmp_path, "agent-local-agent-20261030-1", ["control", "smoke", "perf", "prefill", "tool_reliability", "quality"])
    rc, d = invoke(tmp_path, monkeypatch, {"local-agent-next": "good", "local-agent": "half"}, "agent-local-agent-20261030-1",
                   extra=["--tool-reliability-calls", "7", "--prefill-contexts", "4096,8192", "--some-future-flag", "x"])
    assert rc == 0 and d["state"] == "done" and d["label"] == "better"
    assert d["verdict_path"] == "evals/verdicts/agent-local-agent-20261030-1.json"          # the scheduler's run id, not the default
    assert (tmp_path / "evals" / "site" / d["verdict_path"]).exists()
    by = {lg["name"]: lg for lg in d["legs"]}
    assert [by[n]["state"] for n in ("control", "smoke", "perf", "quality")] == ["done"] * 4
    assert by["prefill"]["state"] == "done" and by["tool_reliability"]["state"] == "done"          # the A1 legs, merged
    assert by["tool_reliability"]["metrics"]["n"] == 7
    assert by["smoke"]["metrics"]["smoke_finish_stop"] == 1.0 and "ttft_p95_s@c1" in by["perf"]["metrics"]
    assert all(lg["started"] and lg["finished"] for lg in d["legs"] if lg["state"] == "done")
    assert "winner" not in json.dumps(by["quality"]["summary"]).lower()


def test_an_unhealthy_node_aborts_the_run_and_the_status_says_which_leg(tmp_path, monkeypatch):
    seed(tmp_path, "r1", ["smoke", "perf", "quality"])
    rc, d = invoke(tmp_path, monkeypatch, {"_healthy": False}, "r1", extra=["--health-url", "http://127.0.0.1:9/never"])
    assert rc == 1 and d["state"] == "aborted" and "not healthy" in d["reason"]
    assert [lg["state"] for lg in d["legs"]][0] in ("failed", "skipped")


def test_a_failed_control_marks_the_run_failed(tmp_path, monkeypatch):
    seed(tmp_path, "r2", ["control", "quality"])
    es = make_set(tmp_path, grade={"type": "contains", "all": ["control"]})
    srv, url = gateway({})
    (tmp_path / "req.yaml").write_text(yaml.safe_dump(REQ))
    monkeypatch.setenv("EVAL_GATEWAY_KEY", "k")
    try:
        rc = cli.main(["run", str(tmp_path / "req.yaml"), "--set", es.path, "--gateway", url, "--node", "n", "--engine", "mlx-lm",
                       "--engine-version", "1", "--out", str(tmp_path / "evals" / "site"), "--status-dir", str(tmp_path / "evals"),
                       "--run-id", "r2"])
    finally:
        srv.shutdown()
    d = st.read_status(st.path_for(str(tmp_path / "evals"), "r2"))
    assert rc == 1 and d["state"] == "failed" and "known-bad control passed" in d["reason"] and d["verdict_path"] is None
    assert d["legs"][0]["state"] == "failed"


def test_the_engine_upgrade_run_writes_twins_and_no_verdict_and_states_a_regression_in_the_reason(tmp_path, monkeypatch):
    # the earlier done run of the same build, on the old engine, with figures the live stub cannot meet
    old = st.new_status("agent-local-agent-20261001-1", "local-agent", "agent", {"model": "good-model"}, None, "mac-studio-m5",
                        {"id": "mlx-lm", "version": "0.31.0"}, {"id": "agent-words", "version": "v1", "sha256": "0" * 64},
                        "request", {"legs": ["smoke", "perf"]}, "done")
    old["legs"][0]["metrics"] = {"smoke_finish_stop": 1.0}
    old["legs"][1]["metrics"] = {"ttft_p95_s@c1": 0.0001, "decode_tps_p50@c1": 1e9}
    st.write_status(st.path_for(str(tmp_path / "evals"), old["run_id"]), old)
    seed(tmp_path, "agent-local-agent-20261030-1", ["smoke", "perf"], trigger="engine-upgrade", engine="0.32.2")
    rc, d = invoke(tmp_path, monkeypatch, {"local-agent": "good"}, "agent-local-agent-20261030-1",
                   extra=["--route", "local-agent", "--legs", "smoke,perf"], req={k: v for k, v in REQ.items() if k != "incumbent"})
    assert rc == 0 and d["state"] == "done"
    assert d["verdict_path"] is None and d["label"] is None                       # never a verdict, never a promotion
    assert "engine mlx-lm 0.31.0 -> mlx-lm 0.32.2, compared with agent-local-agent-20261001-1" in d["reason"]
    assert "regression:" in d["reason"] and "ttft_p95_s@c1" in d["reason"] and "decode_tps_p50@c1" in d["reason"]
    assert not (tmp_path / "evals" / "site" / "evals" / "verdicts").exists()
    kinds = [json.loads(p.read_text())["kind"] for p in (tmp_path / "evals" / "site" / "evals" / "results").rglob("*.json")]
    assert sorted(kinds) == ["perf", "smoke"]


def test_without_a_status_dir_the_runner_behaves_as_before(tmp_path, monkeypatch):
    es = make_set(tmp_path)
    srv, url = gateway({"local-agent-next": "good", "local-agent": "half"})
    (tmp_path / "req.yaml").write_text(yaml.safe_dump(REQ))
    monkeypatch.setenv("EVAL_GATEWAY_KEY", "k")
    try:
        rc = cli.main(["run", str(tmp_path / "req.yaml"), "--set", es.path, "--gateway", url, "--node", "n", "--engine", "mlx-lm",
                       "--engine-version", "1", "--out", str(tmp_path / "site"), "--steps", "1", "--perf-requests", "4"])
    finally:
        srv.shutdown()
    assert rc == 0 and not (tmp_path / "evals").exists()


def test_the_runner_values_reach_run_as_tool_calls_and_prefill_contexts_when_run_takes_them(tmp_path, monkeypatch):
    seen = {}

    def fake_run(req, es, *, gateway, key, node, engine, engine_version, out, tool_calls=None, prefill_contexts=None, progress=None, **kw):
        seen.update(tool_calls=tool_calls, prefill_contexts=prefill_contexts, progress=progress)
        progress("smoke", "running")
        progress("prefill", "done", "4 contexts", {"prefill_tps@4096": 1.0})
        return {"verdict": None, "label": None, "control": {}, "verdict_path": None, "twins": [], "decision": None}
    monkeypatch.setattr(cli, "run", fake_run)
    seed(tmp_path, "r9", ["smoke", "prefill"])
    rc, d = invoke(tmp_path, monkeypatch, {}, "r9", extra=["--tool-reliability-calls", "7", "--prefill-contexts", "4096,16384"])
    assert rc == 0 and seen["tool_calls"] == 7 and seen["prefill_contexts"] == (4096, 16384)
    by = {lg["name"]: lg for lg in d["legs"]}
    assert by["prefill"]["state"] == "done" and by["prefill"]["metrics"] == {"prefill_tps@4096": 1.0}

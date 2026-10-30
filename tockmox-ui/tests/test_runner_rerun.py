# SPDX-License-Identifier: Apache-2.0
"""TM-1295 and TM-1295's explicit re-run: two runs of one build on one day write their own twins (the second run on
prod, 2026-10-30, measured for 75 minutes and then refused to write a smoke twin the morning's run had written), a run
id is used once and refused before any leg, the evidence PR accepts every twin a run writes, and runner.rerun queues a
finished run again."""
import json
import os

import pytest

from app import pr_opener as po
from app import results as rs
from app.runner import scheduler as sch
from app.runner import status as st
from app.runner.run import RunError

from .test_runner import REQ, _run, make_set
from .test_runner_scheduler import config, run_once, statuses


@pytest.fixture(autouse=True)
def fixture_sets(monkeypatch):
    monkeypatch.setattr(sch, "builtin_sets_dir", lambda: os.path.join(os.path.dirname(__file__), "fixtures", "evalsets"))


BEH = {"local-agent-next": "good", "local-agent": "half"}


def _twins(tmp_path):
    root = tmp_path / "site" / "evals" / "results"
    return sorted(os.path.relpath(os.path.join(d, f), tmp_path / "site") for d, _, fs in os.walk(root) for f in fs)


# ------------------------------------------------------------------ twin names carry the run

def test_two_runs_of_one_build_on_one_day_write_their_own_twins(tmp_path):
    es = make_set(tmp_path)
    a = _run(tmp_path, es, BEH, run_id="agent-local-agent-20261029-1")
    b = _run(tmp_path, es, BEH, run_id="agent-local-agent-20261029-2", seed=2)   # another day's numbers would differ too
    pa, pb = {p for p, _ in a["twins"]}, {p for p, _ in b["twins"]}
    assert pa and pb and not (pa & pb)
    assert all(p.endswith("-agent-local-agent-20261029-1.json") for p in pa)
    assert all(p.endswith("-agent-local-agent-20261029-2.json") for p in pb)
    assert {a["verdict_path"], b["verdict_path"]} == {"evals/verdicts/agent-local-agent-20261029-1.json",
                                                      "evals/verdicts/agent-local-agent-20261029-2.json"}
    for p, sha in a["twins"]:
        r = rs.parse((tmp_path / "site" / p).read_text(), p)
        assert r.run == "agent-local-agent-20261029-1" and rs.repo_path(r) == p and r.sha256 == sha


def test_a_run_id_with_a_verdict_is_refused_before_any_leg_runs(tmp_path):
    es = make_set(tmp_path)
    _run(tmp_path, es, BEH, run_id="r-1")
    seen = []
    with pytest.raises(RunError, match="evals/verdicts/r-1.json already exists"):
        _run(tmp_path, es, BEH, run_id="r-1", progress=lambda *a, **k: seen.append(a))
    assert seen == []


def test_every_twin_a_run_writes_is_accepted_by_the_evidence_pr(tmp_path):
    """The quality twin's name used to carry the class only in the runner, so the evidence PR refused it."""
    es = make_set(tmp_path)
    res = _run(tmp_path, es, BEH, run_id="agent-local-agent-20261029-1")
    site = tmp_path / "site"
    files = {p: (site / p).read_bytes() for p, _ in res["twins"]}
    files[res["verdict_path"]] = (site / res["verdict_path"]).read_bytes()
    spec = po.plan_evidence(files, lambda _p: None, "site/values/models.yaml")
    assert sorted(spec.files) == sorted(files)
    assert any("-quality-agent-gateway-" in p for p in spec.files)


def test_a_twin_without_a_run_keeps_the_name_it_always_had():
    base = dict(date="2026-10-22", node="beta", model="org/M-4bit", revision="", quant="", engine_id="mlx-lm",
                engine_version="0.32.2", plane="gateway", methodology="evals/results/beta/method.md",
                environment={"x": "y"}, gateway={"route": "a-next"}, metrics=[rs.Metric("m", 1.0, "bool", 1)])
    assert rs.repo_path(rs.Result(kind="smoke", **base)) == "evals/results/beta/2026-10-22-m-4bit-mlx-lm-smoke-gateway.json"
    assert rs.repo_path(rs.Result(kind="perf", **base)) == "evals/results/beta/2026-10-22-m-4bit-mlx-lm-gateway.json"
    r = rs.Result(kind="quality", klass="large", run="large-x-20261022-3", **base)
    assert rs.repo_path(r) == "evals/results/beta/2026-10-22-m-4bit-mlx-lm-quality-large-gateway-large-x-20261022-3.json"
    back = rs.parse(rs.dumps(r))
    assert back.run == r.run and json.loads(rs.dumps(r))["run"] == r.run


def test_a_run_field_that_is_not_a_run_id_is_refused():
    base = dict(date="2026-10-22", node="beta", model="org/M-4bit", revision="", quant="", engine_id="mlx-lm",
                engine_version="0.32.2", plane="engine", methodology="evals/results/beta/method.md",
                environment={"x": "y"}, metrics=[rs.Metric("m", 1.0, "bool", 1)])
    d = json.loads(rs.dumps(rs.Result(kind="smoke", **base)))
    d["run"] = "../escape"
    with pytest.raises(rs.ResultError, match="run must be a run id"):
        rs.parse(json.dumps(d))


# ------------------------------------------------------------------ runner.rerun

def _finish(tmp_path, state="failed"):
    for s in statuses(tmp_path):
        if s["state"] not in ("done", "failed"):
            st.write_status(st.path_for(str(tmp_path / "evals"), s["run_id"]), dict(s, state=state, reason="x"))


def test_runner_rerun_queues_a_finished_run_again_once(tmp_path):
    cfg = config(tmp_path)
    run_once(cfg)
    [first] = statuses(tmp_path)
    _finish(tmp_path)
    kube, _ = run_once(cfg)
    assert kube.created == []                                         # failed stays failed
    cfg["modelLifecycle"]["runner"]["rerun"] = [first["run_id"]]
    kube, log = run_once(cfg)
    assert len(kube.created) == 1 and any("re-run requested" in m for m in log)
    new = next(s for s in statuses(tmp_path) if s["run_id"] != first["run_id"])
    assert new["state"] == "queued" and new["run_id"].endswith("-2")
    kube, log = run_once(cfg, kube)                                    # still queued: no second Job, no repeated log
    assert len(kube.created) == 1 and not any("re-run requested" in m for m in log)
    _finish(tmp_path, "done")
    kube, _ = run_once(cfg)
    assert kube.created == []                                         # the newer finished run settles it


def test_runner_rerun_names_run_ids_and_the_schema_says_so():
    s = sch.parse_settings({"modelLifecycle": {"runner": {"rerun": ["large-local-large-20261030-2"]}}})
    assert s.rerun == ["large-local-large-20261030-2"]
    schema = json.load(open(os.path.join(os.path.dirname(__file__), "..", "..", "charts", "tockmox-ai", "values.schema.json")))
    rr = schema["properties"]["modelLifecycle"]["properties"]["runner"]["properties"]["rerun"]
    assert rr["type"] == "array" and rr["items"]["pattern"] == rs._RUN.pattern

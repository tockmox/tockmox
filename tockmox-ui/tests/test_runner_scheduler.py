# SPDX-License-Identifier: Apache-2.0
"""TM-1261, TM-1264: the eval scheduler. Work discovery (admitted candidates, engine upgrades), the quiet window, one Job
per node, the request it writes, and the Kubernetes client, with Prometheus, the node and the API server mocked."""
import copy
import os

import httpx
import pytest
import yaml

from app.runner import scheduler as sch
from app.runner import status as st

FIX = os.path.join(os.path.dirname(__file__), "fixtures", "evalsets")
OLD, NEW = "mlx-community/Old-120B-4bit", "mlx-community/New-122B-4bit"
REV = "e9c67b08" + "0" * 32


@pytest.fixture(autouse=True)
def fixture_sets(monkeypatch):
    monkeypatch.setattr(sch, "builtin_sets_dir", lambda: FIX)


TEMPLATE = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"labels": {"x": "y"}},
            "spec": {"backoffLimit": 0, "template": {"metadata": {"labels": {"tockmox.com/eval-client": "true"}},
                     "spec": {"restartPolicy": "Never", "initContainers": [{"name": "runner", "image": "ui:1", "command": ["python", "-m", "app.runner"]}],
                              "containers": [{"name": "evidence-pr", "image": "ui:1", "command": ["python", "-m", "app.runner"]}]}}}}


def config(tmp_path, *, engine_version="0.32.2", next_route=True, stage="candidate", max_requests=0, profile=True, extra_alias=True):
    routes = [{"alias": "local-large", "node": "studio", "endpoint": "mlx-lm-8080", "model": OLD, "kind": "chat"}]
    if next_route:
        routes.append({"alias": "local-large-next", "node": "studio", "endpoint": "mlx-lm-8080", "model": NEW, "kind": "chat"})
    if extra_alias:
        routes.append({"alias": "local-chat", "node": "studio", "endpoint": "mlx-lm-8080", "model": "mlx-community/Chat-27B-4bit", "kind": "chat"})
    lc = {"catalog": [
        {"id": "old", "model": OLD, "source": {"kind": "huggingface", "ref": OLD, "revision": "1" * 40}, "stage": "promoted"},
        {"id": "new", "model": NEW, "source": {"kind": "huggingface", "ref": NEW, "revision": REV}, "stage": stage},
        {"id": "chat", "model": "mlx-community/Chat-27B-4bit", "source": {"kind": "huggingface", "ref": "mlx-community/Chat-27B-4bit", "revision": "2" * 40}}],
        "runner": {"enabled": True, "prometheusUrl": "http://prom:9090", "statusDir": str(tmp_path / "evals"),
                   "quietWindow": {"minutes": 10, "maxProductionRequests": max_requests},
                   "nodes": {"studio": {"engineVersion": engine_version}}, "setsDir": str(tmp_path / "nosets"),
                   "jobTemplate": str(tmp_path / "job.yaml")}}
    if profile:
        lc["profiles"] = [{"id": "main", "classes": {"large": {"alias": "local-large"}}}]
        lc["activeProfile"] = "main"
    (tmp_path / "job.yaml").write_text(yaml.safe_dump(TEMPLATE))
    return {"modelLifecycle": lc, "inferenceNodes": {"nodes": [
        {"id": "studio", "name": "Studio", "type": "apple-silicon-mac", "address": "192.0.2.10",
         "endpoints": [{"id": "mlx-lm-8080", "engine": "mlx-lm", "url": "http://192.0.2.10:8080"}]}], "routes": routes}}


class FakeKube:
    def __init__(self, jobs=()):
        self.jobs, self.created = list(jobs), []

    def list_jobs(self):
        return self.jobs

    def create_job(self, job):
        self.created.append(job)
        return job


def prom(value=0.0, status=200, queries=None):
    def h(req: httpx.Request):
        if queries is not None:
            queries.append(req.url.params["query"])
        if status != 200:
            return httpx.Response(status, text="no")
        res = [{"metric": {}, "value": [0, str(value)]}] if value is not None else []
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": res}})
    return httpx.MockTransport(h)


def health(code=200):
    return httpx.MockTransport(lambda r: httpx.Response(code))


def run_once(cfg, kube=None, *, p=None, h=None, today="2026-10-30"):
    kube = kube or FakeKube()
    log = []
    sch.schedule(cfg, kube, prom_transport=p or prom(0), health_transport=h or health(), today=today, log=log.append)
    return kube, log


def statuses(tmp_path):
    return st.read_statuses(str(tmp_path / "evals"))


# ------------------------------------------------------------------ work discovery

def test_an_admitted_candidate_starts_a_job_with_a_request_built_from_the_route_and_catalog(tmp_path):
    cfg = config(tmp_path)
    kube, _ = run_once(cfg)
    assert len(kube.created) == 1
    job = kube.created[0]
    assert job["metadata"]["labels"]["tockmox.com/eval-node"] == "studio"
    assert job["spec"]["template"]["metadata"]["labels"]["tockmox.com/eval-client"] == "true"     # kept from the chart's template
    [s] = statuses(tmp_path)
    assert (s["run_id"], s["alias"], s["class"], s["trigger"], s["state"]) == ("large-local-large-20261030-1", "local-large", "large", "admitted", "queued")
    assert s["candidate"] == {"model": NEW, "revision": REV} and s["incumbent"] == {"model": OLD, "revision": "1" * 40}
    assert s["set"]["id"] == "large-fixture" and s["set"]["version"] == "v2"                      # the latest version of the class
    assert s["engine"] == {"id": "mlx-lm", "version": "0.32.2"} and s["plan"]["legs"][0] == "control"
    req = yaml.safe_load(open(tmp_path / "evals" / "requests" / "large-local-large-20261030-1.yaml"))
    assert req["schema"] == "eval-request/1" and req["alias"] == "local-large" and req["class"] == "large"
    assert req["candidate"] == {"model": NEW, "revision": REV} and req["incumbent"] == {"model": OLD, "revision": "1" * 40}
    assert "criterion" not in req and req["gateway"] == "eval"
    args = job["spec"]["template"]["spec"]["initContainers"][0]["args"]
    assert args[0] == "run" and args[args.index("--run-id") + 1] == s["run_id"]
    assert args[args.index("--route") + 1] == "local-large-next" and args[args.index("--legs") + 1] == "control,smoke,perf,prefill,tool_reliability,quality"
    assert args[args.index("--health-url") + 1] == "http://192.0.2.10:8080/health"
    assert args[args.index("--out") + 1].endswith("/evals/site") and args[args.index("--tool-reliability-calls") + 1] == "100"
    assert job["spec"]["template"]["spec"]["containers"][0]["args"][:1] == ["evidence-pr"]


def test_no_incumbent_makes_an_absolute_bars_request(tmp_path):
    cfg = config(tmp_path, extra_alias=False)
    cfg["inferenceNodes"]["routes"] = [r for r in cfg["inferenceNodes"]["routes"] if r["alias"] != "local-large"]
    cfg["modelLifecycle"]["catalog"] = [e for e in cfg["modelLifecycle"]["catalog"] if e["id"] != "old"]
    run_once(cfg)
    [s] = statuses(tmp_path)
    assert s["incumbent"] is None
    req = yaml.safe_load(open(tmp_path / "evals" / "requests" / f"{s['run_id']}.yaml"))
    assert req["criterion"] == "absolute-bars" and req["incumbent"] == {}


def test_the_same_model_on_another_node_is_a_replacement_request_of_class_perf(tmp_path):
    cfg = config(tmp_path)
    cfg["inferenceNodes"]["nodes"].append({"id": "spark", "name": "Spark", "type": "nvidia-dgx-spark", "address": "192.0.2.20",
                                           "endpoints": [{"id": "vllm-8000", "engine": "vllm", "url": "http://192.0.2.20:8000"}]})
    nxt = next(r for r in cfg["inferenceNodes"]["routes"] if r["alias"] == "local-large-next")
    nxt.update(node="spark", endpoint="vllm-8000", model=OLD)
    cfg["modelLifecycle"]["catalog"] = [e for e in cfg["modelLifecycle"]["catalog"] if e["id"] != "new"]
    cfg["modelLifecycle"]["catalog"][0]["stage"] = "candidate"        # the entry is the one that is being placed
    cfg["modelLifecycle"]["catalog"][0].pop("promotion", None)
    run_once(cfg)
    [s] = statuses(tmp_path)
    req = yaml.safe_load(open(tmp_path / "evals" / "requests" / f"{s['run_id']}.yaml"))
    assert req["class"] == "perf" and req["placement"] == {"from_node": "studio", "to_node": "spark"}


def test_a_next_route_that_is_not_an_admitted_candidate_is_not_work(tmp_path):
    for stage in ("promoted", "rejected"):
        cfg = config(tmp_path, stage=stage) if stage != "rejected" else config(tmp_path)
        if stage == "rejected":
            cfg["modelLifecycle"]["catalog"][1].update(stage="rejected", rejection={"reason": "worse", "date": "2026-10-01"})
        kube, log = run_once(cfg)
        assert kube.created == [] and statuses(tmp_path) == []
        assert any("not an admitted candidate" in m for m in log)
    cfg = config(tmp_path)
    cfg["modelLifecycle"]["catalog"] = cfg["modelLifecycle"]["catalog"][:1] + cfg["modelLifecycle"]["catalog"][2:]
    kube, log = run_once(cfg)
    assert kube.created == [] and any("no catalog entry" in m for m in log)           # a hand-made -next route is not consent


def test_a_done_or_failed_run_for_the_same_key_is_not_run_again_but_a_new_build_or_set_or_engine_is(tmp_path):
    cfg = config(tmp_path)
    run_once(cfg)
    [first] = statuses(tmp_path)
    for state in ("done", "failed"):
        d = dict(first, state=state)
        st.write_status(st.path_for(str(tmp_path / "evals"), first["run_id"]), d)
        kube, _ = run_once(cfg)
        assert kube.created == [], state
    kube, _ = run_once(config(tmp_path, engine_version="0.33.0"))          # another engine version is another evidence key
    assert len(kube.created) == 1
    c2 = config(tmp_path)
    c2["modelLifecycle"]["catalog"][1]["source"]["revision"] = "a" * 40         # a newer build of the candidate
    kube, _ = run_once(c2)
    assert len(kube.created) == 1


def test_an_aborted_run_is_tried_again_with_a_new_id(tmp_path):
    cfg = config(tmp_path)
    run_once(cfg)
    [first] = statuses(tmp_path)
    st.write_status(st.path_for(str(tmp_path / "evals"), first["run_id"]), dict(first, state="aborted", reason="node unhealthy"))
    kube, _ = run_once(cfg)
    assert len(kube.created) == 1
    assert {s["run_id"] for s in statuses(tmp_path)} == {first["run_id"], "large-local-large-20261030-2"}


def test_a_class_with_no_set_or_no_known_class_waits_with_the_reason_and_starts_nothing(tmp_path, monkeypatch):
    from app.runner import scheduler as sch
    real = sch.builtin_sets_dir
    (tmp_path / "noshipped").mkdir()
    monkeypatch.setattr(sch, "builtin_sets_dir", lambda: str(tmp_path / "noshipped"))     # no class from the alias name either
    cfg = config(tmp_path, profile=False)
    kube, _ = run_once(cfg)
    [s] = statuses(tmp_path)
    assert kube.created == [] and s["state"] == "waiting" and "no workload class is known for local-large" in s["reason"]
    monkeypatch.setattr(sch, "builtin_sets_dir", real)
    cfg = config(tmp_path)
    cfg["modelLifecycle"]["profiles"][0]["classes"] = {"huge": {"alias": "local-large"}}
    for f in os.listdir(tmp_path / "evals" / "runs"):
        os.unlink(tmp_path / "evals" / "runs" / f)
    kube, _ = run_once(cfg)
    [s] = statuses(tmp_path)
    assert kube.created == [] and s["state"] == "waiting" and "no eval set for class huge" in s["reason"]


def test_a_site_set_from_the_extra_configmap_wins_at_a_higher_version_and_is_copied_to_the_status_volume(tmp_path):
    cfg = config(tmp_path)
    extra = tmp_path / "nosets"
    extra.mkdir()
    for suffix, src in (("set.yaml", "set.yaml"), ("cases.jsonl", "cases.jsonl")):
        (extra / f"large__v3__{suffix}").write_text(open(os.path.join(FIX, "large", "v2", src)).read().replace("version: v2", "version: v3"))
    kube, _ = run_once(cfg)
    [s] = statuses(tmp_path)
    assert s["set"]["version"] == "v3"
    assert os.path.isfile(tmp_path / "evals" / "sets" / "large" / "v3" / "cases.jsonl")
    args = kube.created[0]["spec"]["template"]["spec"]["initContainers"][0]["args"]
    assert args[args.index("--set") + 1] == str(tmp_path / "evals" / "sets" / "large" / "v3")


# ------------------------------------------------------------------ the quiet window

def test_production_requests_over_the_limit_wait_with_the_count_and_exit_cleanly(tmp_path):
    q = []
    kube, _ = run_once(config(tmp_path), p=prom(3.0, queries=q))
    [s] = statuses(tmp_path)
    assert kube.created == [] and s["state"] == "waiting"
    assert s["reason"] == "node busy: 3 production request(s) in the last 10 min (at most 0 allowed)"
    # the query names the node's live aliases (not the -next route) and the window
    assert 'requested_model=~"local-chat|local-large"' in q[0] and "[10m]" in q[0] and "litellm_proxy_total_requests_metric_total" in q[0]
    assert "-next" not in q[0]


def test_requests_at_or_under_the_limit_start_the_run(tmp_path):
    kube, _ = run_once(config(tmp_path, max_requests=2), p=prom(2.1))        # increase() extrapolates: 2.1 is 2 requests
    assert len(kube.created) == 1
    for f in os.listdir(tmp_path / "evals" / "runs"):
        os.unlink(tmp_path / "evals" / "runs" / f)
    kube, _ = run_once(config(tmp_path, max_requests=2), p=prom(2.9), today="2026-10-31")
    assert kube.created == [] and statuses(tmp_path)[0]["reason"].startswith("node busy: 3 production")


def test_no_series_means_no_traffic_and_a_prometheus_that_fails_means_cannot_tell(tmp_path):
    kube, _ = run_once(config(tmp_path), p=prom(None))
    assert len(kube.created) == 1
    cfg = config(tmp_path)
    for f in os.listdir(tmp_path / "evals" / "runs"):
        os.unlink(tmp_path / "evals" / "runs" / f)
    kube, _ = run_once(cfg, p=prom(status=500))
    assert kube.created == [] and "cannot tell whether studio is idle" in statuses(tmp_path)[0]["reason"]


def test_an_unhealthy_node_waits(tmp_path):
    kube, _ = run_once(config(tmp_path), h=health(503))
    s = statuses(tmp_path)[0]
    assert kube.created == [] and s["state"] == "waiting" and "node not healthy" in s["reason"] and "HTTP 503" in s["reason"]


def test_a_waiting_status_keeps_its_id_and_is_not_rewritten_while_nothing_changes(tmp_path):
    cfg = config(tmp_path)
    run_once(cfg, p=prom(5))
    [a] = statuses(tmp_path)
    run_once(cfg, p=prom(5))
    [b] = statuses(tmp_path)
    assert a["run_id"] == b["run_id"] and a["updated"] == b["updated"]
    kube, _ = run_once(cfg, p=prom(0))                  # the window opens: the same run id starts
    assert len(kube.created) == 1 and statuses(tmp_path)[0]["run_id"] == a["run_id"]


# ------------------------------------------------------------------ one Job per node

def job(node="studio", run="x", **status):
    return {"metadata": {"name": "j", "labels": {"app.kubernetes.io/name": "tockmox-eval-run", "tockmox.com/eval-node": node,
                                                 "tockmox.com/eval-run": sch.run_label(run)}}, "status": status}


def test_a_node_with_an_unfinished_job_gets_no_second_job_and_its_work_is_queued(tmp_path):
    kube = FakeKube([job(active=1)])
    kube, _ = run_once(config(tmp_path), kube)
    [s] = statuses(tmp_path)
    assert kube.created == [] and s["state"] == "queued" and "another run is in progress on studio" in s["reason"]


def test_a_finished_job_does_not_block_the_node(tmp_path):
    kube, _ = run_once(config(tmp_path), FakeKube([job(succeeded=1)]))
    assert len(kube.created) == 1


def test_two_works_on_one_node_start_one_job_in_a_pass(tmp_path):
    cfg = config(tmp_path)
    cfg["modelLifecycle"]["catalog"].append({"id": "chat2", "model": "m/Chat-2", "stage": "candidate",
                                             "source": {"kind": "huggingface", "ref": "m/Chat-2", "revision": "3" * 40}})
    cfg["inferenceNodes"]["routes"].append({"alias": "local-chat-next", "node": "studio", "endpoint": "mlx-lm-8080", "model": "m/Chat-2", "kind": "chat"})
    cfg["modelLifecycle"]["profiles"][0]["classes"]["agent"] = {"alias": "local-chat"}
    kube, _ = run_once(cfg)
    assert len(kube.created) == 1
    assert {s["alias"]: s["state"] for s in statuses(tmp_path)} == {"local-large": "queued", "local-chat": "queued"}
    states = {s["alias"]: s["reason"] for s in statuses(tmp_path)}
    assert "Job tockmox-eval" in states["local-chat"] and "another run is in progress" in states["local-large"]   # alias order


def test_a_queued_run_whose_job_exists_is_left_alone_and_one_whose_job_vanished_fails(tmp_path):
    cfg = config(tmp_path)
    kube, _ = run_once(cfg)
    [s] = statuses(tmp_path)
    j = job(run=s["run_id"], active=1)
    kube2 = FakeKube([j])
    kube2, _ = run_once(cfg, kube2)
    assert kube2.created == [] and statuses(tmp_path)[0]["state"] == "queued"
    run_once(cfg, FakeKube([]))                        # the Job was deleted while the status still said queued
    s = next(x for x in statuses(tmp_path) if x["run_id"] == s["run_id"])
    assert s["state"] == "failed" and "the Job is gone before the run wrote a result" == s["reason"]


# ------------------------------------------------------------------ TM-1264: engine upgrade

def done_run(tmp_path, version="0.32.2", metrics=None, **kw):
    d = st.new_status("large-local-large-20261001-1", "local-large", "large", {"model": OLD, "revision": "1" * 40}, None, "studio",
                      {"id": "mlx-lm", "version": version}, {"id": "large-fixture", "version": "v2", "sha256": "0" * 64},
                      "request", {"legs": ["smoke", "perf"]}, "done")
    d["legs"][1]["metrics"] = metrics or {}
    d.update(kw)
    st.write_status(st.path_for(str(tmp_path / "evals"), d["run_id"]), d)
    return d


def upgrade_cfg(tmp_path, **kw):
    cfg = config(tmp_path, next_route=True, **kw)
    return cfg


def test_a_changed_engine_version_since_the_last_done_run_schedules_the_incumbent_for_smoke_and_perf(tmp_path):
    done_run(tmp_path, "0.32.2")
    cfg = config(tmp_path, engine_version="0.33.0")
    kube, _ = run_once(cfg)
    up = [s for s in statuses(tmp_path) if s["trigger"] == "engine-upgrade"]
    assert len(up) == 1 and up[0]["alias"] == "local-large"
    assert up[0]["candidate"] == {"model": OLD, "revision": "1" * 40} and up[0]["incumbent"] is None
    assert [x["name"] for x in up[0]["legs"]] == ["smoke", "perf"] and up[0]["engine"]["version"] == "0.33.0"
    # the admitted candidate (also on that node) goes first; the upgrade re-evaluation queues behind it
    assert len(kube.created) == 1
    assert [s["state"] for s in statuses(tmp_path) if s["trigger"] == "admitted"] == ["queued"]
    assert up[0]["state"] == "queued" and "another run is in progress" in up[0]["reason"]


def test_the_engine_upgrade_job_measures_the_live_alias_with_smoke_and_perf_only(tmp_path):
    done_run(tmp_path, "0.32.2")
    cfg = config(tmp_path, engine_version="0.33.0", next_route=True)
    kube, _ = run_once(cfg, FakeKube([job(node="studio", succeeded=1)]))
    # admitted first...
    admitted = kube.created[0]["spec"]["template"]["spec"]["initContainers"][0]["args"]
    assert admitted[admitted.index("--route") + 1] == "local-large-next"
    # ...and with the candidate done, the upgrade run starts next pass
    [adm] = [s for s in statuses(tmp_path) if s["trigger"] == "admitted"]
    st.write_status(st.path_for(str(tmp_path / "evals"), adm["run_id"]), dict(adm, state="done"))
    kube, _ = run_once(cfg)
    up = kube.created[0]["spec"]["template"]["spec"]["initContainers"][0]["args"]
    assert up[up.index("--route") + 1] == "local-large" and up[up.index("--legs") + 1] == "smoke,perf"
    req = yaml.safe_load(open(tmp_path / "evals" / "requests" / f"{up[up.index('--run-id') + 1]}.yaml"))
    assert req["candidate"]["model"] == OLD


def test_no_engine_upgrade_when_the_version_is_unchanged_unknown_or_there_is_no_earlier_done_run(tmp_path):
    cfg = config(tmp_path, next_route=False)
    run_once(cfg)
    assert statuses(tmp_path) == []                                      # no earlier done run: nothing to compare with
    done_run(tmp_path, "0.32.2")
    run_once(config(tmp_path, next_route=False, engine_version="0.32.2"))
    assert statuses(tmp_path)[0]["state"] == "done" and len(statuses(tmp_path)) == 1
    run_once(config(tmp_path, next_route=False, engine_version=""))    # the site did not declare a version
    assert len(statuses(tmp_path)) == 1


def test_an_engine_upgrade_for_an_alias_the_eval_gateway_does_not_serve_waits_and_says_why(tmp_path):
    done_run(tmp_path, "0.32.2")
    kube, _ = run_once(config(tmp_path, next_route=False, engine_version="0.33.0"))
    [s] = [x for x in statuses(tmp_path) if x["trigger"] == "engine-upgrade"]
    assert kube.created == [] and s["state"] == "waiting" and "serves local-large only while an local-large-next candidate" in s["reason"]


def test_an_engine_upgrade_that_has_run_is_not_scheduled_again(tmp_path):
    done_run(tmp_path, "0.32.2")
    cfg = config(tmp_path, next_route=False, engine_version="0.33.0")
    run_once(cfg)
    [up] = statuses(tmp_path)[:1] if False else [x for x in statuses(tmp_path) if x["trigger"] == "engine-upgrade"]
    st.write_status(st.path_for(str(tmp_path / "evals"), up["run_id"]), dict(up, state="done"))
    run_once(cfg)
    assert [x["trigger"] for x in statuses(tmp_path)].count("engine-upgrade") == 1


# ------------------------------------------------------------------ the Kubernetes client and the Job

def test_kube_client_lists_jobs_by_label_with_the_bearer_token_and_creates_in_its_namespace():
    seen = []

    def h(req: httpx.Request):
        seen.append((req.method, req.url.path, req.url.params.get("labelSelector"), req.headers["authorization"]))
        return httpx.Response(200, json={"items": [{"metadata": {"name": "a"}}]})
    k = sch.KubeClient("https://kube", "tok", "tockmox-ai", transport=httpx.MockTransport(h))
    assert k.list_jobs() == [{"metadata": {"name": "a"}}]
    k.create_job({"kind": "Job"})
    assert seen[0] == ("GET", "/apis/batch/v1/namespaces/tockmox-ai/jobs", "app.kubernetes.io/name=tockmox-eval-run", "Bearer tok")
    assert seen[1][:2] == ("POST", "/apis/batch/v1/namespaces/tockmox-ai/jobs")
    bad = sch.KubeClient("https://kube", "tok", "ns", transport=httpx.MockTransport(lambda r: httpx.Response(403, text="forbidden")))
    with pytest.raises(sch.SchedulerError, match="HTTP 403"):
        bad.list_jobs()


def test_a_job_the_api_refuses_leaves_the_run_waiting_not_lost(tmp_path):
    class Refusing(FakeKube):
        def create_job(self, job):
            raise sch.SchedulerError("the Kubernetes API refused creating the Job: HTTP 422")
    kube, _ = run_once(config(tmp_path), Refusing())
    s = statuses(tmp_path)[0]
    assert s["state"] == "waiting" and "could not start the Job" in s["reason"]


def test_build_job_names_labels_and_arguments_and_refuses_a_template_without_a_runner(tmp_path):
    cfg = config(tmp_path)
    s = sch.parse_settings(cfg)
    w = sch.Work("local-large", "large", "admitted", {"model": NEW}, None, "studio", {"id": "mlx-lm", "version": "1"}, "local-large-next", True)
    j = sch.build_job(TEMPLATE, w, s, "Large.Run_1", ["run"])
    assert j["metadata"]["name"].startswith("tockmox-eval-large-run-1-") and len(j["metadata"]["name"]) <= 63
    assert j["metadata"]["annotations"]["tockmox.com/run-id"] == "Large.Run_1"
    assert j["spec"]["template"]["metadata"]["labels"]["tockmox.com/eval-run"] == sch.run_label("Large.Run_1")
    assert TEMPLATE["spec"]["template"]["spec"]["initContainers"][0].get("args") is None          # the template is not mutated
    t = copy.deepcopy(TEMPLATE)
    t["spec"]["template"]["spec"]["initContainers"][0]["name"] = "other"
    with pytest.raises(sch.SchedulerError, match="no container named runner"):
        sch.build_job(t, w, s, "r", [])


def test_settings_reject_a_zero_minute_window():
    with pytest.raises(sch.SchedulerError):
        sch.parse_settings({"modelLifecycle": {"runner": {"quietWindow": {"minutes": 0}}}})


def test_an_unclassed_alias_named_for_a_shipped_class_takes_that_class():
    from app.runner import scheduler as sch
    from app import models as ml
    lc = ml.parse({})
    assert sch.alias_class("local-large", lc) == "large"          # the prod first run: no profile, no promotion record
    assert sch.alias_class("agent", lc) == "agent"
    assert sch.alias_class("local-chatty", lc) == ""              # no shipped set for it: still waits for a class
    assert sch.alias_class("local-perf", lc) == ""


def test_runner_aliases_limits_which_candidates_are_scheduled(tmp_path):
    from app.runner import scheduler as sch
    cfg = config(tmp_path)
    cfg["modelLifecycle"]["runner"]["aliases"] = ["local-nothing"]
    kube, _ = run_once(cfg)
    assert kube.created == [] and statuses(tmp_path) == []          # nothing listed is in flight: nothing starts, nothing waits
    cfg["modelLifecycle"]["runner"]["aliases"] = ["local-large"]
    kube, _ = run_once(cfg)
    assert len(kube.created) == 1
    cfg["modelLifecycle"]["runner"]["aliases"] = ["local-large-next"]
    try:
        sch.parse_settings(cfg)
        raise AssertionError("a -next name in runner.aliases must be refused")
    except sch.SchedulerError as e:
        assert "live aliases" in str(e)


def test_production_aliases_the_inventory_does_not_route_count_in_the_quiet_window(tmp_path):
    seen = []

    def handler(request):
        seen.append(request.url.params["query"])
        return httpx.Response(200, json={"status": "success", "data": {"result": [{"value": [0, "4"]}]}})
    cfg = config(tmp_path, extra_alias=False)
    cfg["modelLifecycle"]["runner"]["nodes"] = {"studio": {"engineVersion": "0.32.2", "productionAliases": ["local-medium"]}}
    kube, _ = run_once(cfg, p=httpx.MockTransport(handler))
    [s] = statuses(tmp_path)
    assert kube.created == [] and s["state"] == "waiting" and "node busy: 4" in s["reason"]
    assert "local-medium" in seen[0] and "local-large" in seen[0]

# SPDX-License-Identifier: Apache-2.0
"""The eval scheduler (TM-1261, TM-1264): decides what the runner should evaluate next and starts it, one Job per node.

    python -m app.runner schedule --config /etc/tockmox-eval/config.yaml

It runs as a CronJob (charts/tockmox-ai/templates/eval-runner.yaml), reads the same rendered config the chart gives the
watcher (modelLifecycle and inferenceNodes), and does four things in a pass:

  1. WORK. Every live `<alias>-next` route served on the eval gateway whose catalog entry is at stage `candidate` is an
     admitted candidate: merging the admit PR was the consent to evaluate it. It is work unless a run-status/1 for the same
     (alias, candidate model and revision, eval set sha256, engine id and version, node, route digest) is already `done` or
     `failed`. A failed run is not retried by itself: change the build, the set, the engine or the route's provider and
     params (TM-1295: turning thinking off on a -next route re-runs it), or list its run id in runner.rerun.
     TM-1264: a node whose engine (id or version) differs from the one in the last `done` run of the build an alias serves gets
     a re-evaluation of the incumbent, trigger `engine-upgrade`, smoke and perf legs only. It decides nothing: a
     regression is written into the status `reason`, and no verdict, label or promotion follows from it.
  2. QUIET. A run starts only when production has been quiet on the node: the requests that reached the node's live
     aliases through the production gateway in the last quietWindow.minutes (Prometheus) must be at most
     maxProductionRequests, and the node's health URL must answer 2xx. Otherwise the status is `waiting`, with the reason,
     and the pass still exits 0: not quiet is an answer, not a failure. A Prometheus that does not answer is "cannot tell",
     which waits too.
  3. ONE JOB PER NODE. A node with an unfinished Job (found by label) gets no second one; its other work is `queued`.
  4. START. The eval-request/1 is written beside the status files, the Job is created from the template the chart rendered
     (the pod spec stays in the chart), and the Job's own process (`python -m app.runner run ... --status-dir`) moves the
     status through its legs. This pass also marks a status `failed` when its Job is gone or ended without a result.

Only this process holds a Kubernetes token (create/get/list/delete Jobs and get/list Pods in the release namespace, nothing
else). It uses httpx against the API server directly: no client library.
"""
from __future__ import annotations

import copy
import datetime as dt
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass, field

import httpx
import yaml

from .. import models as ml
from .. import nodes as nm
from . import evalset
from . import status as st

SERVICE_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
JOB_NAME_LABEL = "tockmox-eval-run"
NODE_LABEL = "tockmox.com/eval-node"
RUN_LABEL = "tockmox.com/eval-run"
RUN_ANNOTATION = "tockmox.com/run-id"
REQUESTS = "requests"
DEFAULT_GATEWAY = "http://tockmox-litellm-eval:4000"
ALL_LEGS = ["control", "smoke", "perf", "prefill", "tool_reliability", "quality"]
UPGRADE_LEGS = ["smoke", "perf"]
HEALTH_PATH = {"ollama": "/api/version", "mlx-lm": "/health"}      # as the chart's blackbox probes; others /v1/models
# The metric the production gateway already exports and the alert pack already uses (alert-pack.yaml
# TockmoxLiteLLMHighErrorRate): LiteLLM's litellm_proxy_total_requests_metric, one series per requested_model. The eval
# gateway sets no Prometheus callback, so what this counts is production traffic only. `increase` cannot see the first
# sample of a brand-new series, so a model's very first request after a gateway restart can read as 0; the node-health
# check and the one-Job rule are the other guards.
REQUESTS_METRIC = "litellm_proxy_total_requests_metric_total"


class SchedulerError(RuntimeError):
    pass


class SetUnavailable(RuntimeError):
    pass


# ---------------------------------------------------------------- settings

@dataclass
class Settings:
    status_dir: str = st.DEFAULT_DIR
    gateway_url: str = DEFAULT_GATEWAY
    prometheus_url: str = ""
    quiet_minutes: int = 10
    max_requests: int = 0
    steps: list = field(default_factory=lambda: [1, 2])
    perf_requests: int = 20
    workers: int = 2
    tool_calls: int = 100
    prefill_contexts: list = field(default_factory=lambda: [4096, 16384, 32768, 65536])
    nodes: dict = field(default_factory=dict)
    aliases: list = field(default_factory=list)      # runner.aliases: only these live aliases' candidates; empty = all
    rerun: list = field(default_factory=list)        # runner.rerun: finished run ids to measure again (TM-1295)
    sets_dir: str = "/etc/tockmox-eval/sets"
    job_template: str = "/etc/tockmox-eval/job-template.yaml"
    namespace: str = ""


def parse_settings(cfg: dict) -> Settings:
    lc = cfg.get("modelLifecycle") or {}
    r = lc.get("runner") or {}
    q = r.get("quietWindow") or {}
    s = Settings()
    s.status_dir = str(r.get("statusDir") or st.DEFAULT_DIR).rstrip("/") or st.DEFAULT_DIR
    s.gateway_url = str(r.get("gatewayUrl") or DEFAULT_GATEWAY)
    s.prometheus_url = str(r.get("prometheusUrl") or "")
    s.quiet_minutes = int(q.get("minutes", 10))
    s.max_requests = int(q.get("maxProductionRequests", 0))
    s.steps = [int(x) for x in r.get("steps") or [1, 2]]
    s.perf_requests = int(r.get("perfRequests", 20))
    s.workers = int(r.get("workers", 2))
    s.tool_calls = int(r.get("toolReliabilityCalls", 100))
    s.prefill_contexts = [int(x) for x in r.get("prefillContexts") or [4096, 16384, 32768, 65536]]
    s.nodes = {str(k): dict(v or {}) for k, v in (r.get("nodes") or {}).items()}
    s.aliases = [str(a) for a in r.get("aliases") or []]
    if any(a.endswith(ml.NEXT) for a in s.aliases):
        raise SchedulerError("runner.aliases names live aliases (local-large), not their -next routes")
    s.rerun = [str(x) for x in r.get("rerun") or []]
    s.sets_dir = str(r.get("setsDir") or s.sets_dir)
    s.job_template = str(r.get("jobTemplate") or s.job_template)
    s.namespace = str(r.get("namespace") or "")
    if s.quiet_minutes < 1 or s.max_requests < 0:
        raise SchedulerError("runner.quietWindow needs minutes >= 1 and maxProductionRequests >= 0")
    return s


# ---------------------------------------------------------------- eval sets

def builtin_sets_dir() -> str:
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "evalsets")


def _version_key(v: str):
    m = re.match(r"^v?(\d+)", v)
    return (1, int(m.group(1)), v) if m else (0, 0, v)


def find_set(klass: str, builtin: str, extra: str, work: str) -> tuple[evalset.EvalSet, str]:
    """The latest version of the class's set: the product's (app/evalsets/<class>/<version>/) and the site's
    (extraSetsConfigMap mounted at `extra`, flat keys <class>__<version>__set.yaml and __cases.jsonl). The highest
    version wins; at the same version the site's wins. A site's set is copied to <work>/sets/<class>/<version>/ so the Job
    can read it from the status volume. Raises SetUnavailable with a sentence."""
    found = {}                    # version -> directory
    cdir = os.path.join(builtin, klass)
    if os.path.isdir(cdir):
        for v in os.listdir(cdir):
            if os.path.isfile(os.path.join(cdir, v, "set.yaml")) and os.path.isfile(os.path.join(cdir, v, "cases.jsonl")):
                found[v] = os.path.join(cdir, v)
    if extra and os.path.isdir(extra):
        names = set(os.listdir(extra))
        for n in sorted(names):
            m = re.match(rf"^{re.escape(klass)}__(.+)__set\.yaml$", n)
            if m and f"{klass}__{m.group(1)}__cases.jsonl" in names:
                v = m.group(1)
                dest = os.path.join(work, "sets", klass, v)
                os.makedirs(dest, exist_ok=True)
                for src, dst in ((n, "set.yaml"), (f"{klass}__{v}__cases.jsonl", "cases.jsonl")):
                    with open(os.path.join(extra, src), "rb") as a, open(os.path.join(dest, dst), "wb") as b:
                        b.write(a.read())
                found[v] = dest
    if not found:
        raise SetUnavailable(f"there is no eval set for class {klass}: the product ships none for it and the site has not "
                             f"added one (extraSetsConfigMap keys {klass}__<version>__set.yaml and __cases.jsonl)")
    v = max(found, key=_version_key)
    try:
        es = evalset.load(found[v])
    except evalset.SetError as e:
        raise SetUnavailable(f"eval set {klass}/{v} cannot be loaded: {e}") from None
    return es, found[v]


# ---------------------------------------------------------------- work

@dataclass
class Work:
    alias: str
    klass: str
    trigger: str
    candidate: dict
    incumbent: dict | None
    node: str
    engine: dict
    route: str                       # the eval-gateway route that serves the build under test
    served: bool                     # the eval gateway serves that route
    placement: dict | None = None
    es: object = None
    setdir: str = ""
    set_problem: str = ""
    route_digest: str = ""           # TM-1295: the route's provider and params; a change schedules a new run

    @property
    def legs(self):
        return list(UPGRADE_LEGS) if self.trigger == "engine-upgrade" else list(ALL_LEGS)

    def set_ref(self) -> dict:
        if self.es is None:
            return {"id": "", "version": "", "sha256": ""}
        return {"id": self.es.id, "version": self.es.version, "sha256": self.es.sha256}

    def key(self) -> tuple:
        return (self.alias, self.candidate["model"], self.candidate.get("revision", ""), self.set_ref()["sha256"],
                self.engine.get("id", ""), self.engine.get("version", ""), self.node, self.trigger, self.route_digest)


def status_key(s: dict) -> tuple:
    return (s["alias"], s["candidate"]["model"], s["candidate"].get("revision", ""), (s.get("set") or {}).get("sha256", ""),
            (s.get("engine") or {}).get("id", ""), (s.get("engine") or {}).get("version", ""), s.get("node", ""),
            s["trigger"], s.get("route_digest", ""))


def route_digest(route) -> str:
    """TM-1295: what the gateway sends the engine besides the model (the route's provider and params, e.g. a thinking
    switch or an output cap). Part of the run key, so fixing a route re-runs its evaluation instead of the scheduler
    skipping it as done. A route with neither has the empty digest, which every status written before this had."""
    params, provider = dict(getattr(route, "params", None) or {}), str(getattr(route, "provider", "") or "")
    if not params and not provider:
        return ""
    return hashlib.sha256(json.dumps({"provider": provider, "params": params}, sort_keys=True, default=str).encode()).hexdigest()[:16]


def alias_class(alias: str, lc: ml.Lifecycle, *entries) -> str:
    """The workload class an alias is judged in: the active profile's class that names the alias, else any profile's,
    else the class on a catalog entry's promotion record, else the alias's own name when it is local-<class> (or <class>)
    and the product ships a set for that class (a first candidate on a site with no profile and no promotion yet: the
    shipped aliases are named for their class). "" when nothing says."""
    profs = ([lc.profile(lc.active_profile)] if lc.active_profile and lc.profile(lc.active_profile) else []) + list(lc.profiles)
    for p in profs:
        for c in p.classes:
            if c.alias == alias:
                return c.name
    for e in entries:
        k = ((e.promotion or {}).get("class") if e else "") or ""
        if k and k != ml.PERF:
            return str(k)
    m = re.match(r"^(?:local-)?([a-z][a-z0-9]*)$", alias)
    if m and m.group(1) != ml.PERF and os.path.isdir(os.path.join(builtin_sets_dir(), m.group(1))):
        return m.group(1)
    return ""


def engine_for(inv: nm.Inventory, node_id: str, endpoint_id: str, settings: Settings) -> dict:
    n = inv.node(node_id)
    ep = n.endpoint(endpoint_id) if n else None
    over = settings.nodes.get(node_id, {})
    eid = over.get("engine") or (ep.engine if ep else "")
    return {"id": eid, "version": str(over.get("engineVersion") or "")}


def health_url(inv: nm.Inventory, node_id: str, endpoint_id: str, settings: Settings) -> str:
    over = (settings.nodes.get(node_id) or {}).get("healthUrl")
    if over:
        return str(over)
    n = inv.node(node_id)
    ep = n.endpoint(endpoint_id) if n else None
    if not ep:
        return ""
    return ep.url.rstrip("/") + HEALTH_PATH.get(ep.engine, "/v1/models")


def _pin(lc: ml.Lifecycle, model: str) -> dict:
    e = lc.by_model(model)
    d = {"model": model}
    if e is not None and e.source.revision:
        d["revision"] = e.source.revision
    return d


def discover(cfg: dict, settings: Settings, statuses: list, work_dir: str, log=lambda m: None) -> list[Work]:
    """Every run the current config and statuses ask for, in the order they are started: admitted candidates, then
    engine-upgrade re-evaluations. Does no I/O besides reading eval sets."""
    lc_raw = cfg.get("modelLifecycle") or {}
    lc = ml.parse(lc_raw)
    inv = nm.parse_inventory(cfg.get("inferenceNodes") or {})
    served = {r.alias for r in nm.gateway_routes(inv, "eval")}
    by_alias = {r.alias: r for r in inv.routes}
    out = []

    def attach_set(w: Work):
        if not w.klass:
            w.set_problem = (f"no workload class is known for {w.alias}: name it in a profile "
                             "(modelLifecycle.profiles.<id>.classes) or on its catalog entry's promotion record")
            return
        try:
            w.es, w.setdir = find_set(w.klass, builtin_sets_dir(), settings.sets_dir, work_dir)
        except SetUnavailable as e:
            w.set_problem = str(e)

    for r in sorted((x for x in inv.routes if x.alias.endswith(nm.NEXT)), key=lambda x: x.alias):
        alias = r.alias[: -len(nm.NEXT)]
        if settings.aliases and alias not in settings.aliases:
            log(f"{r.alias}: not scheduled (runner.aliases lists {', '.join(settings.aliases)})")
            continue
        entry = lc.by_model(r.model)
        if entry is None or entry.stage != "candidate":
            log(f"{r.alias}: not scheduled ({'no catalog entry for ' + r.model if entry is None else 'catalog stage is ' + entry.stage}, "
                "not an admitted candidate)")
            continue
        live = by_alias.get(alias)
        inc = _pin(lc, live.model) if live else None
        klass = alias_class(alias, lc, entry, lc.by_model(live.model) if live else None)
        placement = None
        if live and live.model == r.model:
            # the same model on another node or endpoint: a re-placement, decided by class perf (models.eval_request)
            placement = {"from_node": live.node, "to_node": r.node}
        w = Work(alias, klass, "admitted", _pin(lc, r.model), inc, r.node, engine_for(inv, r.node, r.endpoint, settings),
                 r.alias, r.alias in served, placement)
        w.route_digest = route_digest(r)
        attach_set(w)
        out.append(w)

    done = [s for s in statuses if s["state"] == "done"]     # newest first
    for r in sorted((x for x in inv.routes if not x.alias.endswith(nm.NEXT)), key=lambda x: (x.node, x.alias)):
        eng = engine_for(inv, r.node, r.endpoint, settings)
        # the baseline is the last done run that measured THIS build on this node: an admitted candidate's run measured the
        # candidate, so it says nothing about how the incumbent fares on the new engine
        prev = next((s for s in done if s["alias"] == r.alias and s["node"] == r.node and s["candidate"]["model"] == r.model), None)
        if prev is None or not eng["version"]:
            continue
        pe = prev.get("engine") or {}
        if not pe.get("version") or pe["version"] == "unknown" or (pe.get("id"), pe["version"]) == (eng["id"], eng["version"]):
            continue
        entry = lc.by_model(r.model)
        w = Work(r.alias, alias_class(r.alias, lc, entry) or prev.get("class", ""), "engine-upgrade", _pin(lc, r.model), None,
                 r.node, eng, r.alias, r.alias in served)
        w.route_digest = route_digest(r)
        attach_set(w)
        out.append(w)
    return out


# ---------------------------------------------------------------- the request, the plan, the Job

def build_request(w: Work, when: str) -> dict:
    """The eval-request/1 for a run (models.eval_request, so a request the UI would refuse is refused here too)."""
    if w.trigger == "engine-upgrade":
        # nothing is being decided: the live alias is measured as it stands. The request names no incumbent, which the
        # runner reads as absolute bars, but with no quality leg there is no verdict to hold a bar.
        return ml.eval_request(w.alias, w.klass, 1, w.candidate, {}, "tockmox-eval-scheduler", when)
    klass = ml.PERF if w.placement else w.klass
    return ml.eval_request(w.alias, klass, 1, w.candidate, w.incumbent or {}, "tockmox-eval-scheduler", when, w.placement)


def estimate_seconds(w: Work, s: Settings) -> int:
    """A rough figure for the Runs page, not a promise: 8 s a perf request, 2 min a prefill context, 6 s a tool call,
    8 s a quality case (twice with an incumbent)."""
    t = 60 + len(s.steps) * s.perf_requests * 8
    if w.trigger == "engine-upgrade":
        return t
    t += len(s.prefill_contexts) * 120 + s.tool_calls * 6
    cases = len(w.es.cases) * w.es.epochs if w.es is not None else 0
    return t + cases * 8 * (1 if not w.incumbent else 2) + 5


def new_run_id(klass: str, alias: str, today: str, taken: set) -> str:
    base = f"{klass or 'unclassed'}-{alias}-{today.replace('-', '')}"
    n = 1
    while f"{base}-{n}" in taken:
        n += 1
    return f"{base}-{n}"


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9-]+", "-", s.lower()).strip("-")


def run_label(run_id: str) -> str:
    return hashlib.sha256(run_id.encode()).hexdigest()[:16]


def job_args(w: Work, s: Settings, run_id: str, request_path: str, health: str) -> list[str]:
    a = ["run", request_path, "--set", w.setdir, "--gateway", s.gateway_url, "--key-env", "EVAL_GATEWAY_KEY",
         "--node", w.node, "--engine", w.engine["id"], "--engine-version", w.engine["version"] or "unknown",
         "--out", os.path.join(s.status_dir, "site"), "--status-dir", s.status_dir, "--run-id", run_id,
         "--steps", ",".join(str(x) for x in s.steps), "--perf-requests", str(s.perf_requests), "--workers", str(s.workers),
         "--route", w.route, "--legs", ",".join(w.legs),
         "--tool-reliability-calls", str(s.tool_calls), "--prefill-contexts", ",".join(str(x) for x in s.prefill_contexts)]
    if health:
        a += ["--health-url", health]
    return a


def build_job(template: dict, w: Work, s: Settings, run_id: str, args: list[str]) -> dict:
    """The Job to create: the chart's template with the name, labels and the `runner` container's arguments filled in."""
    job = copy.deepcopy(template)
    name = f"tockmox-eval-{_slug(run_id)[:40]}-{run_label(run_id)[:6]}"
    meta = job.setdefault("metadata", {})
    meta["name"] = name
    lab = {"app.kubernetes.io/name": JOB_NAME_LABEL, NODE_LABEL: w.node, RUN_LABEL: run_label(run_id)}
    meta.setdefault("labels", {}).update(lab)
    meta.setdefault("annotations", {})[RUN_ANNOTATION] = run_id
    pod = job.setdefault("spec", {}).setdefault("template", {})
    pod.setdefault("metadata", {}).setdefault("labels", {}).update(lab)
    spec = pod.setdefault("spec", {})
    runner = next((c for c in (spec.get("initContainers") or []) + (spec.get("containers") or []) if c.get("name") == "runner"), None)
    if runner is None:
        raise SchedulerError("the Job template has no container named runner")
    runner["args"] = args
    for c in (spec.get("initContainers") or []) + (spec.get("containers") or []):
        if c.get("name") == "evidence-pr":
            c["args"] = ["evidence-pr", "--config", "/config/config.yaml", "--status-dir", s.status_dir, "--run-id", run_id]
    return job


# ---------------------------------------------------------------- Kubernetes (the scheduler's own token) and Prometheus

class KubeClient:
    """Just enough of the Kubernetes API: list and create Jobs in one namespace. Token and CA from the pod's service
    account volume; nothing here can touch any other kind."""

    def __init__(self, base: str, token: str, namespace: str, verify=True, transport=None):
        self.ns = namespace
        self.http = httpx.Client(base_url=base, headers={"Authorization": f"Bearer {token}"}, verify=verify,
                                 timeout=20.0, follow_redirects=False, transport=transport)

    @classmethod
    def in_cluster(cls, namespace: str = ""):
        host, port = os.environ.get("KUBERNETES_SERVICE_HOST"), os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        if not host:
            raise SchedulerError("not running in a cluster: KUBERNETES_SERVICE_HOST is not set")
        try:
            token = open(os.path.join(SERVICE_DIR, "token"), encoding="utf-8").read().strip()
            ns = namespace or open(os.path.join(SERVICE_DIR, "namespace"), encoding="utf-8").read().strip()
        except OSError as e:
            raise SchedulerError(f"no service account token in the pod ({e})") from None
        h = f"[{host}]" if ":" in host else host
        return cls(f"https://{h}:{port}", token, ns, verify=os.path.join(SERVICE_DIR, "ca.crt"))

    def _check(self, r: httpx.Response, what: str):
        if r.status_code not in (200, 201):
            raise SchedulerError(f"the Kubernetes API refused {what}: HTTP {r.status_code} {r.text[:200]}")
        return r.json()

    def list_jobs(self) -> list[dict]:
        try:
            r = self.http.get(f"/apis/batch/v1/namespaces/{self.ns}/jobs", params={"labelSelector": f"app.kubernetes.io/name={JOB_NAME_LABEL}"})
        except httpx.HTTPError as e:
            raise SchedulerError(f"the Kubernetes API did not answer ({type(e).__name__})") from None
        return self._check(r, "listing Jobs").get("items") or []

    def create_job(self, job: dict) -> dict:
        try:
            r = self.http.post(f"/apis/batch/v1/namespaces/{self.ns}/jobs", json=job)
        except httpx.HTTPError as e:
            raise SchedulerError(f"the Kubernetes API did not answer ({type(e).__name__})") from None
        return self._check(r, "creating the Job")


def job_finished(job: dict) -> bool:
    s = job.get("status") or {}
    if s.get("succeeded") or (s.get("failed") and not s.get("active")):
        return True
    return any(c.get("type") in ("Complete", "Failed") and c.get("status") == "True" for c in s.get("conditions") or [])


def job_failure(job: dict) -> str:
    for c in (job.get("status") or {}).get("conditions") or []:
        if c.get("type") == "Failed" and c.get("status") == "True":
            return f"{c.get('reason', '')}: {c.get('message', '')}".strip(": ")
    return ""


class PromError(RuntimeError):
    pass


def promql_alias_regex(aliases) -> str:
    # an alias is [A-Za-z0-9._:/-]: the dot is the one regex metacharacter, and in a PromQL double-quoted string a literal
    # backslash is written twice
    return "|".join(a.replace(".", "\\\\.") for a in sorted(aliases))


def production_requests(prom_url: str, aliases, minutes: int, transport=None) -> float:
    """Requests that reached these aliases through the production gateway in the last `minutes`. No series = 0."""
    if not aliases:
        return 0.0
    q = f'sum(increase({REQUESTS_METRIC}{{requested_model=~"{promql_alias_regex(aliases)}"}}[{minutes}m]))'
    try:
        with httpx.Client(timeout=15.0, follow_redirects=False, transport=transport) as c:
            r = c.get(prom_url.rstrip("/") + "/api/v1/query", params={"query": q})
        doc = r.json()
    except (httpx.HTTPError, ValueError) as e:
        raise PromError(f"Prometheus did not answer ({type(e).__name__})") from None
    if r.status_code != 200 or doc.get("status") != "success":
        raise PromError(f"Prometheus refused the query (HTTP {r.status_code})")
    res = doc.get("data", {}).get("result") or []
    try:
        return float(res[0]["value"][1]) if res else 0.0
    except (KeyError, IndexError, ValueError, TypeError):
        raise PromError("Prometheus answered in a shape this scheduler cannot read") from None


def node_healthy(url: str, transport=None) -> tuple[bool, str]:
    if not url:
        return False, "no health URL is known for the node"
    try:
        with httpx.Client(timeout=10.0, follow_redirects=False, transport=transport) as c:
            r = c.get(url)
    except httpx.HTTPError as e:
        return False, f"{url} did not answer ({type(e).__name__})"
    return (200 <= r.status_code < 300), ("" if 200 <= r.status_code < 300 else f"{url} answered HTTP {r.status_code}")


# ---------------------------------------------------------------- one pass

def _save(path_dir: str, doc: dict, prev: dict | None):
    """Write only when something a reader would see changed, so a run that waits all night does not look new every pass."""
    if prev is not None and all(prev.get(k) == doc.get(k) for k in doc if k not in ("updated",)):
        return
    st.write_status(st.path_for(path_dir, doc["run_id"]), doc)


def schedule(cfg: dict, kube, *, prom_transport=None, health_transport=None, dry_run=False, today=None, log=print) -> list[dict]:
    """One pass. Returns the statuses it wrote or started (for the log and the tests)."""
    s = parse_settings(cfg)
    if not s.prometheus_url:
        raise SchedulerError("runner.prometheusUrl is empty: the quiet-window check has nothing to ask")
    today = today or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    when = st.now()
    # Jobs first, statuses second: a Job that finished has already written its status, so a status read afterwards
    # that still says running is stale, not racing.
    jobs = kube.list_jobs()
    statuses = st.read_statuses(s.status_dir)
    by_run = {j["metadata"].get("labels", {}).get(RUN_LABEL): j for j in jobs}
    unfinished_nodes = {j["metadata"]["labels"].get(NODE_LABEL): j for j in jobs if not job_finished(j)}
    written = []

    for d in statuses:
        if d["state"] in ("queued", "running") and d.get("job"):
            j = by_run.get(run_label(d["run_id"]))
            if j is None or job_finished(j):
                why = "the Job is gone" if j is None else (job_failure(j) or "the Job ended")
                d = dict(d, state="failed", reason=f"{why} before the run wrote a result")
                for lg in d["legs"]:
                    if lg["state"] == "running":
                        lg["state"] = "failed"
                st.write_status(st.path_for(s.status_dir, d["run_id"]), d)
                written.append(d)
                log(f"{d['run_id']}: failed ({d['reason']})")
    statuses = st.read_statuses(s.status_dir)

    works = discover(cfg, s, statuses, s.status_dir, lambda m: log(m))
    lc = ml.parse(cfg.get("modelLifecycle") or {})
    inv = nm.parse_inventory(cfg.get("inferenceNodes") or {})
    taken = {d["run_id"] for d in statuses}
    vdir = os.path.join(s.status_dir, "site", "evals", "verdicts")
    if os.path.isdir(vdir):
        taken |= {n[:-5] for n in os.listdir(vdir) if n.endswith(".json")}
    started = set(unfinished_nodes)
    order = {"admitted": 0, "engine-upgrade": 1}
    for w in sorted(works, key=lambda x: order[x.trigger]):
        existing = [d for d in statuses if status_key(d) == w.key()]
        finished = [d for d in existing if d["state"] in ("done", "failed")]
        live = next((d for d in existing if d["state"] in ("queued", "running", "waiting")), None)
        # TM-1295: runner.rerun names finished runs to measure again; a newer finished run of the same work settles it
        if finished and not all(d["run_id"] in s.rerun for d in finished):
            continue
        if finished and live is None:
            log(f"{w.alias}: re-run requested (runner.rerun lists {', '.join(sorted(d['run_id'] for d in finished))})")
        if live and live["state"] == "running":
            continue
        if live and live.get("job") and run_label(live["run_id"]) in by_run:
            continue
        run_id = live["run_id"] if live else new_run_id(w.klass, w.alias, today, taken)
        taken.add(run_id)
        plan = {"legs": w.legs, "estimated_seconds": estimate_seconds(w, s), "disk_gib": None, "window": "next quiet window"}
        doc = live or st.new_status(run_id, w.alias, w.klass or "unclassed", w.candidate, w.incumbent, w.node, w.engine,
                                    w.set_ref(), w.trigger, plan)
        doc = dict(doc, plan=plan, route_digest=w.route_digest)

        def hold(state: str, reason: str):
            nonlocal doc
            doc = dict(doc, state=state, reason=reason)
            _save(s.status_dir, doc, live)
            written.append(doc)
            log(f"{run_id}: {state} ({reason})")

        if w.set_problem:
            hold("waiting", w.set_problem)
            continue
        if not w.served:
            hold("waiting", f"the eval gateway serves {w.alias} only while an {w.alias}-next candidate is in flight, so this "
                            "re-evaluation has no route to measure through yet")
            continue
        if w.node in started:
            hold("queued", f"another run is in progress on {w.node}; one run at a time per node")
            continue
        names = {r.alias for r in inv.routes_on(w.node) if not r.alias.endswith(nm.NEXT)}
        # a production alias the inventory does not route (a hand-written model_list while inferenceNodes.render is off)
        names |= {str(a) for a in (s.nodes.get(w.node) or {}).get("productionAliases") or []}
        try:
            n = production_requests(s.prometheus_url, names, s.quiet_minutes, prom_transport)
        except PromError as e:
            hold("waiting", f"cannot tell whether {w.node} is idle: {e}")
            continue
        if round(n) > s.max_requests:
            hold("waiting", f"node busy: {round(n)} production request(s) in the last {s.quiet_minutes} min "
                            f"(at most {s.max_requests} allowed)")
            continue
        ep_id = next((r.endpoint for r in inv.routes if r.alias == w.route), "")
        hu = health_url(inv, w.node, ep_id, s)
        ok, why = node_healthy(hu, health_transport)
        if not ok:
            hold("waiting", f"node not healthy: {why}")
            continue
        if dry_run:
            hold("queued", "dry run: would start now")
            continue
        req_path = os.path.join(s.status_dir, REQUESTS, run_id + ".yaml")
        os.makedirs(os.path.dirname(req_path), exist_ok=True)
        with open(req_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(build_request(w, when), f, sort_keys=False)
        with open(s.job_template, encoding="utf-8") as f:
            tmpl = yaml.safe_load(f)
        job = build_job(tmpl, w, s, run_id, job_args(w, s, run_id, req_path, hu))
        try:
            kube.create_job(job)
        except SchedulerError as e:
            hold("waiting", f"could not start the Job: {e}")
            continue
        started.add(w.node)
        doc = dict(doc, job=job["metadata"]["name"])
        hold("queued", f"Job {job['metadata']['name']} created; it starts when its pod is scheduled")
    return written


def main(argv) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="python -m app.runner schedule")
    p.add_argument("--config", required=True)
    p.add_argument("--dry-run", action="store_true", help="decide and write statuses, create no Job")
    a = p.parse_args(argv)
    try:
        with open(a.config, encoding="utf-8") as f:
            cfg = yaml.safe_load(f) or {}
        s = parse_settings(cfg)
        kube = KubeClient.in_cluster(s.namespace)
        schedule(cfg, kube, dry_run=a.dry_run)
    except (SchedulerError, ml.LifecycleError, nm.NodeError, OSError, st.StatusError, yaml.YAMLError) as e:
        print(f"scheduler: {e}", file=sys.stderr)
        return 1
    return 0

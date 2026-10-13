# SPDX-License-Identifier: Apache-2.0
"""Read-only sources. Every read records when it last succeeded and why it last failed.

The rule this module exists to enforce: ABSENCE IS NOT GREEN. A source that is
unconfigured, unreachable, slow, or answers with nothing usable produces
state "unknown" with a reason. Only a source that answered, and whose answer
was healthy, can contribute "ok" to the verdict.
"""
from __future__ import annotations

import json
import os
import ssl
import time
from dataclasses import dataclass, field
from typing import Any, Callable

import httpx

from . import telemetry

OK, WARN, CRIT, UNKNOWN = "ok", "warning", "critical", "unknown"
_RANK = {OK: 0, WARN: 1, CRIT: 2, UNKNOWN: 3}


def worst(states) -> str:
    states = list(states)
    if not states:
        return UNKNOWN
    return max(states, key=lambda s: _RANK[s])


@dataclass
class Reading:
    source: str
    state: str                      # ok | warning | critical | unknown
    data: Any = None
    reason: str = ""
    fetched_at: float | None = None  # this answer
    last_ok_at: float | None = None  # last time the source answered at all

    def age_text(self, now: float | None = None) -> str:
        ts = self.last_ok_at
        if ts is None:
            return "never"
        s = int((now or time.time()) - ts)
        if s < 60:
            return f"{s}s ago"
        if s < 3600:
            return f"{s // 60}m ago"
        return f"{s // 3600}h ago"


@dataclass
class _Cache:
    ttl: float
    value: Reading | None = None
    last_ok_at: float | None = None
    last_data: Any = None
    t: float = 0.0


class Source:
    name = "source"

    def __init__(self, ttl: float = 15.0):
        self._c = _Cache(ttl=ttl)
        telemetry.declare("tockmox_ui_source_failures_total", source=self.name)

    def fetch(self) -> Any:  # pragma: no cover - abstract
        raise NotImplementedError

    def evaluate(self, data: Any) -> tuple[str, str]:
        return OK, ""

    def configured(self) -> bool:
        return True

    def read(self, now: Callable[[], float] = time.time) -> Reading:
        t = now()
        c = self._c
        if c.value is not None and t - c.t < c.ttl:
            return c.value
        if not self.configured():
            r = Reading(self.name, UNKNOWN, reason="not configured")
        else:
            try:
                data = self.fetch()
                state, reason = self.evaluate(data)
                c.last_ok_at, c.last_data = t, data
                r = Reading(self.name, state, data, reason, t, t)
            except Exception as e:  # noqa: BLE001 - every failure is "unknown", by design
                telemetry.source_failure(self.name, e)
                # Keep last good data for display, but never its state.
                r = Reading(self.name, UNKNOWN, c.last_data, _why(e), None, c.last_ok_at)
        c.value, c.t = r, t
        return r


def _why(e: Exception) -> str:
    if isinstance(e, httpx.TimeoutException):
        return "timed out"
    if isinstance(e, httpx.ConnectError):
        return "unreachable"
    if isinstance(e, httpx.HTTPStatusError):
        return f"HTTP {e.response.status_code}"
    if isinstance(e, (ValueError, KeyError, TypeError)):
        return "unusable answer"
    return type(e).__name__


# ---------------------------------------------------------------- Kubernetes

class KubeClient:
    """Two GETs and nothing else. No client library, so the surface is visible."""

    def __init__(self, url: str, token_file: str, ca_file: str, timeout: float,
                 transport: httpx.BaseTransport | None = None):
        self.url, self.token_file, self.ca_file, self.timeout = url, token_file, ca_file, timeout
        self.transport = transport

    def _client(self) -> httpx.Client:
        verify: Any = True
        if self.transport is None and os.path.exists(self.ca_file):
            verify = ssl.create_default_context(cafile=self.ca_file)
        headers = {}
        if os.path.exists(self.token_file):
            with open(self.token_file, encoding="utf-8") as fh:
                headers["Authorization"] = "Bearer " + fh.read().strip()
        return httpx.Client(base_url=self.url, timeout=self.timeout, verify=verify,
                            headers=headers, transport=self.transport)

    def get(self, path: str) -> dict:
        with self._client() as c:
            r = c.get(path)
            r.raise_for_status()
            return r.json()


def _parse_ts(v):
    from datetime import datetime
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


class ApplicationsSource(Source):
    """Argo CD Application CRs.

    The CRs keep their LAST status when the application controller stops, so a
    reader that trusts sync/health alone reports a frozen cluster as healthy.
    Found in the lab (TM-0901, 2026-10-05): controller scaled to 0 and a layer's
    workload scaled to 0, and the UI still said "All systems healthy". Every app
    must therefore carry a recent status.reconciledAt, or it reads Unknown.
    """
    name = "Argo CD applications"

    def __init__(self, kube: KubeClient, namespace: str, tockmox_repo: str, ttl=15.0,
                 stale_after_s: float = 600.0, clock=time.time):
        super().__init__(ttl)
        self.kube, self.ns, self.repo = kube, namespace, tockmox_repo
        self.stale_after_s, self.clock = stale_after_s, clock

    def fetch(self):
        doc = self.kube.get(f"/apis/argoproj.io/v1alpha1/namespaces/{self.ns}/applications")
        out = []
        for it in doc["items"]:
            spec, st = it.get("spec", {}), it.get("status", {})
            srcs = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
            first = srcs[0] if srcs else {}
            out.append({
                "name": it["metadata"]["name"],
                "repo": str(first.get("repoURL", "")),
                "path": str(first.get("path", "")),
                "revision": str(first.get("targetRevision", "")),
                "sync": (st.get("sync") or {}).get("status") or "Unknown",
                "health": (st.get("health") or {}).get("status") or "Unknown",
                "reconciledAt": _parse_ts(st.get("reconciledAt")),
                # What the application manages, as Argo CD lists it: kind and name only. The
                # capabilities page (TM-1017) reads which components a layer really deployed
                # from this, so it needs no Kubernetes permission beyond the Applications.
                "resources": tuple(sorted({(str(r.get("kind", "")), str(r.get("name", "")))
                                           for r in (st.get("resources") or []) if isinstance(r, dict)})),
            })
        return sorted(out, key=lambda a: a["name"])

    def stale(self, apps):
        """The applications whose status is too old to trust, oldest first."""
        now = self.clock()
        out = [a for a in apps if a.get("reconciledAt") is None or now - a["reconciledAt"] > self.stale_after_s]
        return sorted(out, key=lambda a: a.get("reconciledAt") or 0)

    def _age(self, a):
        if a.get("reconciledAt") is None:
            return "never reconciled"
        s = self.clock() - a["reconciledAt"]
        return f"{s / 86400:.1f} days" if s >= 86400 else f"{int(s // 3600)}h" if s >= 3600 else f"{int(s // 60)}m"

    def evaluate(self, apps):
        if not apps:
            return UNKNOWN, "no applications found"
        stale = self.stale(apps)
        stale_names = {a["name"] for a in stale}
        layers = self.tockmox_layers(apps)
        # STALENESS IS JUDGED PER APPLICATION (TM-0904). It used to be all or
        # nothing: ONE stale application read "Argo CD has stopped reconciling"
        # and, through running_version, blanked the version, as a drill leftover
        # stuck deleting did in the first browser walk while all ten layers were
        # fresh. The controller-stopped reading is kept for what it means: every
        # application stale, or every Tockmox layer stale. A stale application's
        # sync and health are its last known values, so it is left out of them.
        if len(stale) == len(apps) or (layers and all(a["name"] in stale_names for a in layers)):
            oldest = min((a["reconciledAt"] for a in stale if a.get("reconciledAt")), default=None)
            age = f", oldest reconcile {int((self.clock() - oldest) // 60)}m ago" if oldest else ""
            return UNKNOWN, f"Argo CD has stopped reconciling ({len(stale)} of {len(apps)} applications stale{age})"
        fresh = [a for a in apps if a["name"] not in stale_names]
        bad_h = [a["name"] for a in fresh if a["health"] in ("Degraded", "Missing")]
        unk = [a["name"] for a in fresh if a["health"] in ("Unknown", "") or a["sync"] in ("Unknown", "")]
        drift = [a["name"] for a in fresh if a["sync"] == "OutOfSync"]
        prog = [a["name"] for a in fresh if a["health"] in ("Progressing", "Suspended")]
        if bad_h:
            return CRIT, f"{len(bad_h)} degraded or missing"
        if unk:
            return UNKNOWN, f"{len(unk)} without a sync or health status"
        if stale:
            noun = "application" if len(stale) == 1 else "applications"
            names = ", ".join(a["name"] for a in stale[:3]) + (f" and {len(stale) - 3} more" if len(stale) > 3 else "")
            return WARN, f"{len(stale)} {noun} not reconciled in {self._age(stale[0])}: {names}"
        if drift or prog:
            return WARN, f"{len(drift)} out of sync, {len(prog)} progressing"
        return OK, f"{len(apps)} synced and healthy"

    # The product's layer charts all live at this path in the Tockmox tree, and
    # the installer writes exactly that path into each layer Application
    # (install/tockmox-install.sh, `path: charts/tockmox-${l}`).
    LAYER_PATH = "charts/tockmox-"

    def tockmox_layers(self, apps):
        """The Applications that deploy Tockmox's own layers.

        With tockmoxRepo set, the ones whose first source is that repository.
        Unset (the shipped default), the ones whose first source path is
        charts/tockmox-<layer>, so a site that serves the product tree from a
        mirror, a forge of its own or an in-cluster git daemon (every
        air-gapped site) is read the same as one on github.com (TM-0979).
        """
        if self.repo:
            norm = lambda u: u.rstrip("/").removesuffix(".git").lower()
            return [a for a in apps if norm(a["repo"]) == norm(self.repo)]
        return [a for a in apps if a.get("path", "").strip("/").startswith(self.LAYER_PATH)]

    def layer_rule(self):
        """One sentence for a reader: what made an Application a Tockmox layer."""
        return (f"the Tockmox repository ({self.repo})" if self.repo
                else f"a source path under {self.LAYER_PATH}<layer> (tockmoxRepo is unset)")


class NodesSource(Source):
    name = "Nodes"

    def __init__(self, kube: KubeClient, ttl=15.0):
        super().__init__(ttl)
        self.kube = kube

    def fetch(self):
        doc = self.kube.get("/api/v1/nodes")
        out = []
        for it in doc["items"]:
            ready = "Unknown"
            for c in it.get("status", {}).get("conditions", []):
                if c.get("type") == "Ready":
                    ready = {"True": "Ready", "False": "NotReady"}.get(c.get("status"), "Unknown")
            out.append({"name": it["metadata"]["name"], "ready": ready,
                        "version": it.get("status", {}).get("nodeInfo", {}).get("kubeletVersion", "")})
        return out

    def evaluate(self, nodes):
        if not nodes:
            return UNKNOWN, "no nodes reported"
        nr = [n for n in nodes if n["ready"] != "Ready"]
        if nr:
            return CRIT, f"{len(nr)} of {len(nodes)} not ready"
        return OK, f"{len(nodes)} ready"


# ---------------------------------------------------------------- Prometheus / Alertmanager

class _HttpSource(Source):
    def __init__(self, url: str, timeout: float, transport=None, ttl=15.0):
        super().__init__(ttl)
        self.url, self.timeout, self.transport = url, timeout, transport

    def configured(self):
        return bool(self.url)

    def _get(self, path, params=None):
        with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport) as c:
            r = c.get(path, params=params)
            r.raise_for_status()
            return r.json()


class PrometheusSource(_HttpSource):
    name = "Prometheus"

    def fetch(self):
        doc = self._get("/api/v1/query", {"query": "up"})
        if doc.get("status") != "success":
            raise ValueError("query failed")
        res = doc["data"]["result"]
        targets = [{"job": r["metric"].get("job", "?"), "instance": r["metric"].get("instance", "?"),
                    "up": r["value"][1] == "1"} for r in res]
        return targets

    def evaluate(self, targets):
        if not targets:
            return UNKNOWN, "no scrape targets"
        down = [t for t in targets if not t["up"]]
        if down:
            return WARN, f"{len(down)} of {len(targets)} targets down"
        return OK, f"{len(targets)} targets up"


# Alerts that fire ALWAYS, on purpose, to prove a path works: never a problem, never a row in
# "Alerts firing" (TM-1014). Watchdog is kube-prometheus-stack's (Prometheus to Alertmanager);
# TockmoxHeartbeat is tockmox-selfcheck's (the cluster to the off-cluster dead-man's switch);
# InfoInhibitor is upstream's inhibition helper. The configured heartbeat joins them.
ALWAYS_FIRING = ("Watchdog", "TockmoxHeartbeat", "InfoInhibitor")
HEARTBEAT_PURPOSE = {
    "Watchdog": "Prometheus can reach Alertmanager",
    "TockmoxHeartbeat": "the self-check is reporting to its dead-man's switch",
}


def pipeline_alerts(heartbeat: str = "") -> tuple:
    return tuple(dict.fromkeys(([heartbeat] if heartbeat else []) + list(ALWAYS_FIRING)))


class AlertmanagerSource(_HttpSource):
    """Active alerts. An EMPTY list is not proof of health: it is also what a broken
    Prometheus-to-Alertmanager path looks like. The always-firing heartbeat (Watchdog,
    shipped by the Tockmox monitoring rules) must be present, or the source reads
    Unknown (fresh-eyes review 2026-10-05, finding 1)."""
    name = "Alertmanager"

    def __init__(self, url, timeout, transport=None, ttl=15.0, heartbeat: str = "Watchdog"):
        super().__init__(url, timeout, transport, ttl)
        self.heartbeat = heartbeat

    def fetch(self):
        doc = self._get("/api/v2/alerts", {"active": "true", "silenced": "false", "inhibited": "false"})
        if not isinstance(doc, list):
            raise ValueError("not a list")
        out = []
        for a in doc:
            lab = a.get("labels", {})
            ann = a.get("annotations", {})
            out.append({"name": lab.get("alertname", "?"), "severity": lab.get("severity", ""),
                        "namespace": lab.get("namespace", ""),
                        "summary": ann.get("summary") or ann.get("description", ""),
                        "startsAt": a.get("startsAt", "")})
        order = {"critical": 0, "warning": 1}
        return sorted(out, key=lambda x: (order.get(x["severity"], 2), x["name"]))

    def evaluate(self, alerts):
        if self.heartbeat and not any(a["name"] == self.heartbeat for a in alerts):
            return UNKNOWN, f"no {self.heartbeat} heartbeat: the alert pipeline cannot be shown to work"
        real = [a for a in alerts if a["name"] not in pipeline_alerts(self.heartbeat)]
        crit = [a for a in real if a["severity"] == "critical"]
        # info/none are informational; any OTHER severity (page, high, missing...) counts as a warning
        warn = [a for a in real if a["severity"] not in ("critical", "info", "none")]
        if crit:
            return CRIT, f"{len(crit)} critical, {len(warn)} warning"
        if warn:
            return WARN, f"{len(warn)} warning"
        return OK, "no alerts firing"


# ---------------------------------------------------------------- posture probe

class PostureSource(Source):
    """Reads the probe's summary from its read API, or a mounted report file."""
    name = "Security posture"

    def __init__(self, options: dict, timeout: float, transport=None, ttl=60.0, clock=time.time):
        super().__init__(ttl)
        self.max_age_s = float(options.get("maxAgeSeconds", 7 * 86400))
        self.clock = clock
        self.url = str(options.get("apiUrl", "")).rstrip("/")
        self.file = str(options.get("reportFile", ""))
        self.timeout, self.transport = timeout, transport

    def configured(self):
        return bool(self.url or self.file)

    def fetch(self):
        if self.url:
            with httpx.Client(timeout=self.timeout, transport=self.transport) as c:
                r = c.get(self.url + "/api/v0/reports/latest")
                r.raise_for_status()
                rep = r.json()
        else:
            with open(self.file, encoding="utf-8") as fh:
                rep = json.load(fh)
        s = rep["summary"]
        drift = [d for d in rep.get("differential", []) if d.get("bucket") in ("drift", "unintended-deny")]
        return {"summary": s, "run": rep.get("run", {}), "findings": drift,
                "schemaVersion": rep.get("schemaVersion")}

    def evaluate(self, d):
        g = d["summary"].get("gateExit")
        started = _parse_ts(d.get("run", {}).get("startedAt"))
        if started is None or self.clock() - started > self.max_age_s:
            return UNKNOWN, "the latest probe report is too old (or undated) to vouch for today"
        if not isinstance(g, int) or isinstance(g, bool):
            return UNKNOWN, "the report carries no usable gate result"
        if g == 0:
            return OK, f"{d['summary'].get('confirmedSafeCount', 0)} confirmed safe, no drift"
        if g == 2:
            return CRIT, f"{d['summary'].get('driftCount', 0)} drift, {d['summary'].get('unintendedDenyCount', 0)} unintended deny"
        return UNKNOWN, "last probe run could not complete"


# ---------------------------------------------------------------- inference nodes (REQ-0047 AC-47.7)

class InferenceNodesSource(_HttpSource):
    """Health and memory of the inference nodes, READ FROM PROMETHEUS. The UI never polls a node.

    Per node, every measurement it has to offer is a state:
      * each exporter listed under the node's `metrics` (up == 1),
      * each endpoint's blackbox probe (probe_success == 1), when one exists.
    A measurement with no series is Unknown, not OK: a host whose exporter answers has
    not proven its engine serves (the reference homelab once lost the series while GitOps read
    green). A node with nothing measuring it at all is Unknown with that reason.
    """
    name = "Inference Nodes"
    QUERIES = {"up": "up", "probe": "probe_success",
               "mac_used": "macmon_memory_ram_used_bytes", "mac_total": "macmon_memory_ram_total_bytes",
               "node_total": "node_memory_total_bytes",            # node_exporter on macOS (Darwin)
               "linux_total": "node_memory_MemTotal_bytes",        # node_exporter on Linux
               "node_avail": "node_memory_MemAvailable_bytes"}

    def __init__(self, url: str, inventory, timeout: float, transport=None, ttl=15.0):
        super().__init__(url, timeout, transport, ttl)
        self.inventory = inventory

    def configured(self):
        return bool(self.url) and bool(self.inventory.nodes)

    def _q(self, expr):
        doc = self._get("/api/v1/query", {"query": expr})
        if doc.get("status") != "success":
            raise ValueError("query failed")
        return doc["data"]["result"]

    def fetch(self):
        series = {k: self._q(v) for k, v in self.QUERIES.items()}
        return [self._node(n, series) for n in self.inventory.nodes]

    @staticmethod
    def _host_of(instance: str) -> str:
        s = instance.split("://", 1)[-1].split("/", 1)[0]
        if s.startswith("["):
            return s[1:s.index("]")]
        return s.rsplit(":", 1)[0] if s.count(":") == 1 else s

    def _node(self, n, series):
        checks = []
        for exp, port in n.metrics.items():
            inst = f"{n.address}:{port}"
            hit = [r for r in series["up"] if r["metric"].get("instance") == inst]
            if not hit:
                checks.append({"what": f"{exp} exporter ({inst})", "state": UNKNOWN, "why": "no series in Prometheus"})
            else:
                ok = all(r["value"][1] == "1" for r in hit)
                checks.append({"what": f"{exp} exporter ({inst})", "state": OK if ok else CRIT,
                               "why": "" if ok else "scrape failing"})
        for e in n.endpoints:
            hit = [r for r in series["probe"] if (r["metric"].get("instance", "") + "/").startswith(e.url + "/")]
            if not hit:
                checks.append({"what": f"{e.engine} on :{e.port}", "state": UNKNOWN,
                               "why": "no blackbox probe for this endpoint"})
            else:
                ok = all(r["value"][1] == "1" for r in hit)
                checks.append({"what": f"{e.engine} on :{e.port}", "state": OK if ok else CRIT,
                               "why": "" if ok else "probe failing"})
        mine = lambda key: [r for r in series[key] if self._host_of(r["metric"].get("instance", "")) == n.address]  # noqa: E731
        used = total = None
        chip = ""
        if mine("mac_total"):
            r = mine("mac_total")[0]
            total, chip = float(r["value"][1]), r["metric"].get("chip", "")
            if mine("mac_used"):
                used = float(mine("mac_used")[0]["value"][1])
        elif mine("node_total") or mine("linux_total"):
            # Darwin's exporter has no MemAvailable; Linux's names its total MemTotal (lab finding 2026-10-07:
            # the first Linux node showed no memory at all because only the Darwin name was asked for)
            total = float((mine("node_total") or mine("linux_total"))[0]["value"][1])
            if mine("node_avail"):
                used = total - float(mine("node_avail")[0]["value"][1])
        mem = None
        if total:
            mem = {"total_gib": round(total / (1 << 30), 1),
                   "used_gib": round(used / (1 << 30), 1) if used is not None else None}
            if used is not None and used / total > 0.92:
                checks.append({"what": "memory", "state": WARN, "why": f"{used / total:.0%} of memory in use"})
        measured = [c for c in checks if not (c["state"] == UNKNOWN and c["why"] == "no blackbox probe for this endpoint")]
        if not n.metrics and not measured:
            state, why = UNKNOWN, "nothing measures this node: add its exporter ports under metrics, or a blackbox probe"
        else:
            # A known failure outranks an unknown (the platform verdict's order). Ranking unknown first hid a
            # stopped engine behind an absent DCGM exporter in the lab (2026-10-07).
            sts = [c["state"] for c in checks]
            state = next((x for x in (CRIT, UNKNOWN, WARN) if x in sts), OK)
            why = "; ".join(f"{c['what']}: {c['why']}" for c in checks if c["state"] != OK and c["why"])
        disagree = ""
        conf = n.memory_gib()
        if mem and conf and n.hardware["memory_gib"].source != "metrics" and abs(conf - mem["total_gib"]) > 1:
            disagree = (f"the node's memory is recorded as {conf:g} GiB ({n.hardware['memory_gib'].source}) "
                        f"but its exporter reports {mem['total_gib']:g} GiB")
        return {"id": n.id, "state": state, "why": why, "checks": checks, "memory": mem, "chip": chip,
                "disagree": disagree}

    def evaluate(self, nodes):
        if not nodes:
            return UNKNOWN, "no nodes"
        sts = [x["state"] for x in nodes]
        st = next((x for x in (CRIT, UNKNOWN, WARN) if x in sts), OK)
        counts = {}
        for x in nodes:
            counts[x["state"]] = counts.get(x["state"], 0) + 1
        words = {OK: "healthy", WARN: "need a look", CRIT: "failing", UNKNOWN: "unknown"}
        return st, ", ".join(f"{v} {words[k]}" for k, v in counts.items())


# ---------------------------------------------------------------- model lifecycle (REQ-0048)

class ModelReportSource(Source):
    """The watcher's report. Missing, unreadable or older than max age is Unknown: a watcher that
    stopped running looks exactly like a quiet upstream, and the page must not say "up to date"."""
    name = "Model watcher"

    def __init__(self, path: str, max_age_s: float, clock=time.time, ttl=30.0):
        super().__init__(ttl)
        self.path, self.max_age_s, self.clock = path, max_age_s, clock

    def configured(self):
        return bool(self.path)

    def fetch(self):
        from . import models as ml
        if os.path.getsize(self.path) > 8 << 20:
            raise ValueError("report too large")
        with open(self.path, encoding="utf-8") as fh:
            return ml.parse_report(json.load(fh))

    def evaluate(self, rep):
        t = _parse_ts(rep.generated_at)
        if t is None or self.clock() - t > self.max_age_s:
            return UNKNOWN, f"the last report is from {rep.generated_at or 'an unknown time'}; the watcher may have stopped"
        if t > self.clock() + 300:
            # review finding: a future timestamp (clock skew or tampering) used to read current for ever
            return UNKNOWN, f"the report claims to be from {rep.generated_at}, which is in the future"
        bad = [k for k, v in rep.sources.items() if not v.get("ok")]
        if bad:
            return UNKNOWN, "not every upstream answered: " + ", ".join(f"{k} ({rep.sources[k].get('reason', '')})" for k in bad)
        if not rep.sources:
            return UNKNOWN, "the report checked nothing"
        if rep.gaps:
            return WARN, f"{len(rep.gaps)} catalog entr{'y is' if len(rep.gaps) == 1 else 'ies are'} watched for nothing: " + "; ".join(rep.gaps[:3])
        n = len(rep.candidates)
        return (WARN, f"{n} candidate(s) to review") if n else (OK, "everything watched is current")


class VerdictSource(Source):
    """REQ-0045 comparative verdict records (proposed AC-45.9), one JSON file per comparison run, read from a
    directory the eval runner writes. A file that does not parse is listed, never dropped: a verdict that
    silently vanished could be the fail that resets a count."""
    name = "Eval verdicts"
    MAX_FILES = 2000

    def __init__(self, path: str, repo_path: str = "evals/verdicts", ttl=30.0):
        super().__init__(ttl)
        self.path, self.repo_path = path, repo_path.strip("/")

    def configured(self):
        return bool(self.path)

    def fetch(self):
        from . import models as ml
        names = sorted(n for n in os.listdir(self.path) if n.endswith(".json"))
        if len(names) > self.MAX_FILES:
            raise ValueError(f"more than {self.MAX_FILES} verdict files")
        out, bad = [], []
        for n in names:
            full = os.path.join(self.path, n)
            try:
                if os.path.getsize(full) > 256 * 1024:
                    raise ml.LifecycleError("larger than 256 KB")
                with open(full, encoding="utf-8") as fh:
                    out.append(ml.parse_verdict(fh.read(), f"{self.repo_path}/{n}"))
            except (OSError, UnicodeDecodeError, ml.LifecycleError) as e:
                bad.append(f"{n}: {e}")
        return {"verdicts": out, "bad": bad}

    def evaluate(self, d):
        if d["bad"]:
            return WARN, f"{len(d['bad'])} file(s) could not be read, so a count may be wrong: " + "; ".join(d["bad"][:3])
        return OK, f"{len(d['verdicts'])} comparison record(s)"


class DemandSource(_HttpSource):
    """Requests per gateway alias over the query's window, from Prometheus (for workload profiles)."""
    name = "Gateway demand"

    def __init__(self, url, query, timeout, transport=None, ttl=60.0):
        super().__init__(url, timeout, transport, ttl)
        self.query = query

    def fetch(self):
        doc = self._get("/api/v1/query", {"query": self.query})
        if doc.get("status") != "success":
            raise ValueError("query failed")
        out = {}
        for r in doc["data"]["result"]:
            m = r["metric"]
            k = m.get("model_group") or m.get("requested_model") or m.get("model") or "?"
            out[k] = out.get(k, 0.0) + float(r["value"][1])
        return out

    def evaluate(self, d):
        if not d:
            return UNKNOWN, "no request series: is the gateway's Prometheus callback on?"
        return OK, f"{len(d)} alias(es) with traffic"

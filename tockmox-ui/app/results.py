# SPDX-License-Identifier: Apache-2.0
"""The capability-result/1 twin (REQ-0045 AC-45.6): one JSON file per measurement leg, written by the eval runner,
committed to the site repo under evals/results/, read by the UI (capability panel, fit v2's measured sizes) and
re-hashed by CI (verdict_check, through the comparative verdict's results[]). One schema module for all three, so
the runner, the page and the gate can never disagree about what a result is.

Pure: no network, no clock. Files are read and written only by the functions that take a root directory.

    {"schema": "capability-result/1", "kind": "perf" | "smoke" | "quality" | "prefill" | "tool_reliability", "date": "2026-10-22", "node": "<node id>",
     "model": "<model id as a route calls it>", "revision": "<40-hex | sha256:...>", "quant": "8bit",
     "engine": {"id": "mlx-lm", "version": "0.32.2"}, "plane": "engine" | "gateway",
     "gateway": {"litellm": "1.106.2", "route": "<alias>-next"},        # required when plane is gateway
     "tool": {"id": "guidellm", "version": "0.8.1"},                    # optional
     "workload": {"profile": "evals/profiles/<alias>.workload.json", "mode": "cold" | "warm", "seed": 1},   # optional
     "class": "chat",                                                   # optional: the workload class the run used
     "metrics": [{"name": "decode_tps_stream_p50", "value": 31.2, "unit": "tok/s", "n": 120, "concurrency": 4}, ...],
     "memory": {"peak_resident_gib": 29.4, "predicted_gib": 33.9, "context_tokens": 32768, "parallel_slots": 3},
     "power": {"tokens_per_joule": 0.42, "watts_mean": 71.0},           # optional
     "environment": {"macos": "26.2", "chip": "Apple M5 Ultra", "memory_gib": 256, "wired_limit_mb": 229376, ...},
     "methodology": "evals/results/<node>/method.md"}

Differences from research D's sketch, all deliberate: `points[]` (one object per concurrency) is a flat `metrics[]`
with an optional `concurrency` per row, so one reader serves perf, smoke and quality legs; `hardware` is folded into
`environment`; `memory` also records the context and slots the peak was measured at, because fit v2 may only use a
measured peak for a plan that asks for no more than was tested.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
from dataclasses import dataclass, field

SCHEMA = "capability-result/1"
KINDS = ("perf", "smoke", "quality", "prefill", "tool_reliability")
PLANES = ("engine", "gateway")
MAX_BYTES = 1 << 20
MAX_METRICS = 500

_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
_SLUG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_METRIC = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_HEX = re.compile(r"^(sha256:)?[0-9a-f]{7,64}$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_PATH = re.compile(r"^evals/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")


class ResultError(ValueError):
    pass


@dataclass
class Metric:
    name: str
    value: float
    unit: str
    n: int
    concurrency: int | None = None
    context_tokens: int | None = None

    def as_dict(self) -> dict:
        d = {"name": self.name, "value": self.value, "unit": self.unit, "n": self.n}
        if self.concurrency is not None:
            d["concurrency"] = self.concurrency
        if self.context_tokens is not None:
            d["context_tokens"] = self.context_tokens
        return d


@dataclass
class Result:
    kind: str
    date: str
    node: str
    model: str
    revision: str
    quant: str
    engine_id: str
    engine_version: str
    plane: str
    metrics: list = field(default_factory=list)
    methodology: str = ""
    environment: dict = field(default_factory=dict)
    klass: str = ""
    gateway: dict = field(default_factory=dict)
    tool: dict = field(default_factory=dict)
    workload: dict = field(default_factory=dict)
    peak_resident_gib: float | None = None
    predicted_gib: float | None = None
    context_tokens: int | None = None
    parallel_slots: int | None = None
    tokens_per_joule: float | None = None
    watts_mean: float | None = None
    sha256: str = ""            # of the file bytes, set by parse()
    path: str = ""              # where it sits in the site repo, set by load_dir()

    def metric(self, name: str, concurrency: int | None = None):
        return next((m for m in self.metrics if m.name == name and (concurrency is None or m.concurrency == concurrency)), None)

    def as_dict(self) -> dict:
        d = {"schema": SCHEMA, "kind": self.kind, "date": self.date, "node": self.node, "model": self.model}
        if self.revision:
            d["revision"] = self.revision
        if self.quant:
            d["quant"] = self.quant
        d["engine"] = {"id": self.engine_id, "version": self.engine_version}
        d["plane"] = self.plane
        for k, v in (("gateway", self.gateway), ("tool", self.tool), ("workload", self.workload)):
            if v:
                d[k] = dict(v)
        if self.klass:
            d["class"] = self.klass
        d["metrics"] = [m.as_dict() for m in self.metrics]
        mem = {k: v for k, v in (("peak_resident_gib", self.peak_resident_gib), ("predicted_gib", self.predicted_gib),
                                 ("context_tokens", self.context_tokens), ("parallel_slots", self.parallel_slots)) if v is not None}
        if mem:
            d["memory"] = mem
        pw = {k: v for k, v in (("tokens_per_joule", self.tokens_per_joule), ("watts_mean", self.watts_mean)) if v is not None}
        if pw:
            d["power"] = pw
        d["environment"] = dict(self.environment)
        d["methodology"] = self.methodology
        return d


def _num(v, what, positive=False, integer=False):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise ResultError(f"{what} must be a finite number")
    if integer and (isinstance(v, float) and not v.is_integer()):
        raise ResultError(f"{what} must be a whole number")
    if positive and v <= 0:
        raise ResultError(f"{what} must be positive")
    return int(v) if integer else float(v)


def _opt(d, key, what, **kw):
    return _num(d[key], what, **kw) if d.get(key) is not None else None


def parse(text: str, path: str = "") -> Result:
    """Validate one twin. Refuses what a reader could misread: a non-finite number, a missing unit, a gateway leg
    that names no route, a methodology pointer outside evals/. Raises ResultError with the reason."""
    if len(text.encode("utf-8")) > MAX_BYTES:
        raise ResultError("result larger than 1 MiB")
    try:
        d = json.loads(text)
    except ValueError:
        raise ResultError("result is not JSON") from None
    if not isinstance(d, dict) or d.get("schema") != SCHEMA:
        raise ResultError(f'result needs "schema": "{SCHEMA}"')
    kind = d.get("kind", "perf")
    if kind not in KINDS:
        raise ResultError(f"kind must be one of {KINDS}")
    if not isinstance(d.get("date"), str) or not _DATE.match(d["date"]):
        raise ResultError("date must be YYYY-MM-DD")
    if not isinstance(d.get("node"), str) or not _ID.match(d["node"]):
        raise ResultError("node must be a node id")
    model = d.get("model")
    if not isinstance(model, str) or not model or len(model) > 200 or any(c.isspace() for c in model):
        raise ResultError("model must be the model id a route uses")
    rev = d.get("revision", "") or ""
    if rev and not (isinstance(rev, str) and _HEX.match(rev)):
        raise ResultError("revision must be a commit sha or a digest")
    quant = d.get("quant", "") or ""
    if not isinstance(quant, str) or len(quant) > 40:
        raise ResultError("quant must be a short string")
    eng = d.get("engine")
    if not (isinstance(eng, dict) and isinstance(eng.get("id"), str) and _SLUG.match(eng["id"])
            and isinstance(eng.get("version"), str) and eng["version"] and len(eng["version"]) <= 64):
        raise ResultError("engine must be {id, version}: a result without the engine version cannot be told stale")
    plane = d.get("plane")
    if plane not in PLANES:
        raise ResultError(f"plane must be one of {PLANES}")
    gw = d.get("gateway") or {}
    if plane == "gateway" and not (isinstance(gw, dict) and isinstance(gw.get("route"), str) and gw["route"]):
        raise ResultError("a gateway-plane result must name gateway.route")
    for key in ("gateway", "tool", "workload", "environment"):
        v = d.get(key)
        if v is not None and (not isinstance(v, dict) or not all(isinstance(k, str) and len(k) <= 64 and
                                                                     isinstance(x, (str, int, float, bool)) and len(str(x)) <= 256
                                                                     for k, x in v.items())):
            raise ResultError(f"{key} must be a flat map of short strings and numbers")
    env = d.get("environment")
    if not env:
        raise ResultError("environment (the versions the numbers were measured on) must not be empty")
    klass = d.get("class", "") or ""
    if klass and not (isinstance(klass, str) and _ID.match(klass)):
        raise ResultError("class must be a slug")
    raw_m = d.get("metrics")
    if not isinstance(raw_m, list) or not raw_m or len(raw_m) > MAX_METRICS:
        raise ResultError(f"metrics must be a list of 1 to {MAX_METRICS} {{name, value, unit, n}}")
    metrics = []
    for i, m in enumerate(raw_m):
        if not (isinstance(m, dict) and isinstance(m.get("name"), str) and _METRIC.match(m["name"])
                and isinstance(m.get("unit"), str) and 0 < len(m["unit"]) <= 16):
            raise ResultError(f"metrics[{i}] needs a name (snake_case) and a unit")
        n = _num(m.get("n"), f"metrics[{i}].n", integer=True)
        if n < 0:
            raise ResultError(f"metrics[{i}].n must not be negative")
        metrics.append(Metric(m["name"], _num(m.get("value"), f"metrics[{i}].value"), m["unit"], n,
                              _opt(m, "concurrency", f"metrics[{i}].concurrency", positive=True, integer=True),
                              _opt(m, "context_tokens", f"metrics[{i}].context_tokens", positive=True, integer=True)))
    meth = d.get("methodology")
    if not (isinstance(meth, str) and _PATH.match(meth) and ".." not in meth.split("/")):
        raise ResultError("methodology must point at a file under evals/ (a number with no method beside it is not a result)")
    mem, pw = d.get("memory") or {}, d.get("power") or {}
    if not isinstance(mem, dict) or not isinstance(pw, dict):
        raise ResultError("memory and power must be maps")
    return Result(kind, d["date"], d["node"], model, rev, quant, eng["id"], eng["version"], plane, metrics, meth,
                  dict(env), klass, dict(gw), dict(d.get("tool") or {}), dict(d.get("workload") or {}),
                  _opt(mem, "peak_resident_gib", "memory.peak_resident_gib", positive=True),
                  _opt(mem, "predicted_gib", "memory.predicted_gib", positive=True),
                  _opt(mem, "context_tokens", "memory.context_tokens", positive=True, integer=True),
                  _opt(mem, "parallel_slots", "memory.parallel_slots", positive=True, integer=True),
                  _opt(pw, "tokens_per_joule", "power.tokens_per_joule", positive=True),
                  _opt(pw, "watts_mean", "power.watts_mean", positive=True),
                  hashlib.sha256(text.encode("utf-8")).hexdigest(), path)


def dumps(r: Result) -> str:
    """The one way a twin is serialised: fixed key order, two-space indent, trailing newline. Deterministic, so the
    same measurement always hashes the same and a diff shows only what changed."""
    text = json.dumps(r.as_dict(), indent=2, ensure_ascii=False) + "\n"
    parse(text)      # a writer must never emit what the reader would refuse
    return text


def model_slug(model: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", model.lower().split("/")[-1]).strip("-")[:48].strip("-") or "model"


def repo_path(r: Result) -> str:
    """Where the twin lives in the site repo: evals/results/<node>/<date>-<model>-<engine>-<plane>.json for a perf leg,
    with `smoke-` or `quality-` before the plane for the others (so legs of one run never share a name)."""
    mid = "" if r.kind == "perf" else f"{r.kind}-"
    return f"evals/results/{r.node}/{r.date}-{model_slug(r.model)}-{re.sub(r'[^a-z0-9]+', '-', r.engine_id.lower()).strip('-')}-{mid}{r.plane}.json"


def write_new(root: str, r: Result) -> tuple[str, str]:
    """Write the twin under `root` and return (repo path, sha256). A twin is immutable: writing a path that exists
    with other bytes is refused (a re-measurement is a new dated file); the same bytes again is a no-op."""
    text = dumps(r)
    rel = repo_path(r)
    full = os.path.join(root, rel)
    if os.path.exists(full):
        with open(full, encoding="utf-8") as fh:
            if fh.read() != text:
                raise ResultError(f"{rel} exists with other contents; a result is never edited, measure again under a new date")
    else:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)
    return rel, hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_dir(root: str, rel: str = "evals/results", limit: int = 5000, prefix: str | None = None) -> tuple[list, list]:
    """Every twin under root/rel, as (results, problems). A file that does not parse is listed, never dropped.
    `prefix` is the repo path of `root/rel` when the directory was mounted somewhere else (the UI reads
    modelLifecycle.resultsDir, which is the site's evals/results wherever it is mounted)."""
    out, bad = [], []
    base = os.path.join(root, rel)
    if not os.path.isdir(base):
        return out, bad
    n = 0
    for dp, _dn, fns in sorted(os.walk(base)):
        for fn in sorted(fns):
            if not fn.endswith(".json"):
                continue
            n += 1
            if n > limit:
                bad.append(f"more than {limit} result files: the rest were not read")
                return out, bad
            full = os.path.join(dp, fn)
            relp = os.path.relpath(full, root).replace(os.sep, "/") if prefix is None else \
                prefix.strip("/") + "/" + os.path.relpath(full, base).replace(os.sep, "/")
            try:
                if os.path.getsize(full) > MAX_BYTES:
                    raise ResultError("larger than 1 MiB")
                with open(full, encoding="utf-8") as fh:
                    out.append(parse(fh.read(), relp))
            except (OSError, UnicodeDecodeError, ResultError) as e:
                bad.append(f"{relp}: {e}")
    return out, bad


def is_stale(r: Result, engine_version: str = "", macos: str = "") -> str:
    """"" when the row still describes the node, else why it does not. An engine or OS that differs from the row's
    is "Unknown, re-measure", never "current" (AC-48.4's rule)."""
    if engine_version and engine_version != r.engine_version:
        return f"measured on {r.engine_id} {r.engine_version}; the node runs {engine_version}"
    row_os = str(r.environment.get("macos", ""))
    if macos and row_os and macos != row_os:
        return f"measured on macOS {row_os}; the node runs {macos}"
    return ""


def newest(results, node: str, model: str, engine: str = "", kind: str = "perf"):
    """The latest result with a measured peak for this model on this node (and engine, when named), or None."""
    rows = [r for r in results if r.node == node and r.model == model and r.kind == kind and r.peak_resident_gib
            and (not engine or r.engine_id == engine)]
    return max(rows, key=lambda r: (r.date, r.path), default=None)

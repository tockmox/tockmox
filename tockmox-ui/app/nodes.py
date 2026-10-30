# SPDX-License-Identifier: Apache-2.0
"""Inference nodes (REQ-0047): the catalog, the inventory, import, routes and the fit estimate.

An inference node is a host OUTSIDE the cluster that serves models over HTTP through
one or more engines. This module is pure: no I/O, no network, no clock. The probe
(app/probe.py) and the health read (app/sources.py:InferenceNodesSource) are separate
so that nothing here can open a socket.

The inventory lives in site values under `inferenceNodes` (AC-47.1). The gateway's
`model_list` entries for node routes are DERIVED from it by render_model_list(), which
is the reference implementation the chart helper ports (TM-0920).
"""
from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass, field
from urllib.parse import urlsplit

import yaml

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}$")
KINDS = ("chat", "embedding", "rerank")
FACT_SOURCES = ("preset", "operator", "metrics", "engine", "measured")   # measured: tockmox_ai_node_info from an enrolled node
RESERVED_NODE_IDS = frozenset({"add", "import", "probe", "change"})   # /nodes/<id> must not shadow a page


class NodeError(ValueError):
    pass


# ---------------------------------------------------------------- engines
#
# provider: the LiteLLM provider prefix per route kind. base_path: what the gateway's
# api_base carries after host:port for that provider. Ollama's native provider wants
# the bare origin; every OpenAI-compatible server wants /v1; LiteLLM's infinity/
# rerank provider posts to <api_base>/rerank, so it also wants the bare origin.

ENGINES: dict[str, dict] = {
    "ollama": {
        "loading": "on-demand",
        "name": "Ollama", "port": 11434, "auth": "none",
        "provider": {"chat": "ollama_chat", "embedding": "ollama", "rerank": None},
        "base_path": {"chat": "", "embedding": "", "rerank": ""},
        "pull": "ollama pull {model}",
        "note": "No built-in authentication: restrict the port to the gateway with the host firewall, or front it with a proxy that checks a bearer token.",
    },
    "mlx-lm": {
        "name": "mlx-lm server", "port": 8080, "auth": "none",
        "provider": {"chat": "openai", "embedding": None, "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "huggingface-cli download {model}",
        "note": "Upstream calls it unsuitable for production exposure; restrict the port to the gateway with the host firewall.",
    },
    "llama-server": {
        "name": "llama.cpp llama-server", "port": 8080, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": "infinity"},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "llama-server -hf {model}",
        "note": "Supports --api-key; set it and give the gateway the same key.",
    },
    "vllm": {
        "name": "vLLM", "port": 8000, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "vllm serve {model}",
        "note": "The cross-platform id: vLLM on CUDA (DGX Spark, GPU workstations) and vllm-metal on Apple silicon share the API server and "
                "its flags. Supports --api-key; one model per server process.",
    },
    "omlx": {
        # Swappable: its engine pool loads models on demand and evicts the least recently used, with per-model pin and TTL
        # (research C 2.1). A pinned model is resident in practice; the fit check plans the safe side (largest swappable one).
        "loading": "on-demand",
        "name": "oMLX", "port": 8000, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "(oMLX loads models from its --model-dir; download them there first)",
        "note": "Apple silicon only. Serves several models from one process and swaps them least-recently-used; pin the ones that must stay resident. "
                "Refuses to listen beyond loopback without --api-key, so give the gateway the same key. No Prometheus metrics of its own: the "
                "blackbox probe is what shows it is up.",
    },
    "vllm-mlx": {
        "name": "vllm-mlx", "port": 8000, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "vllm-mlx serve {model}",
        "note": "Apple silicon only; a different project from vllm-metal (which is the id vllm). Supports --api-key. A server process holds its "
                "model resident. Releases to date pin mlx-lm below 0.32, so it wants its own Python environment beside mlx-lm.",
    },
    "sglang": {
        "name": "SGLang", "port": 30000, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "python -m sglang.launch_server --model-path {model}",
        "note": "One model per server process.",
    },
    "lm-studio": {
        "loading": "on-demand",
        "name": "LM Studio (llmster)", "port": 1234, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "lms get {model}",
        "note": "Enable API authentication in its server settings.",
    },
    "nim": {
        "name": "NVIDIA NIM", "port": 8000, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "docker pull nvcr.io/nim/{model}",
        "note": "One model per container; the NGC key is for pulling, not for serving.",
    },
    "tgi": {
        "name": "Text Generation Inference", "port": 8080, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": None, "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "docker run ghcr.io/huggingface/text-generation-inference --model-id {model}",
        "note": "One model per server process.",
    },
    "exo": {
        "loading": "on-demand",
        "name": "exo cluster", "port": 52415, "auth": "none",
        "provider": {"chat": "openai", "embedding": None, "rerank": None},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "(exo downloads on first request)",
        "note": "Register the whole exo cluster as one node; Tockmox does not manage placement inside it.",
    },
    "openai-compatible": {
        "name": "OpenAI-compatible server", "port": 8080, "auth": "bearer",
        "provider": {"chat": "openai", "embedding": "openai", "rerank": "infinity"},
        "base_path": {"chat": "/v1", "embedding": "/v1", "rerank": ""},
        "pull": "(see the server's own documentation)",
        "note": "Anything that answers GET /v1/models. Tockmox could not tell which engine this is.",
    },
}


# ---------------------------------------------------------------- the catalog (AC: node types)
#
# usable: the fraction of memory a model may plan to occupy. It is a planning default,
# not a measurement, and it is shown wherever it is used. Unified-memory machines lose
# memory to the OS and (macOS) to the GPU wired-memory limit; discrete-GPU machines
# are planned against VRAM, so `memory` there means GPU memory.

CATALOG: dict[str, dict] = {
    "apple-silicon-mac": {
        "name": "Apple silicon Mac", "examples": "Mac Studio, Mac mini, MacBook Pro (M-series)",
        "os": "macOS", "memory_kind": "unified", "usable": 0.75, "onboarding": "mac",
        # `vllm` here is vllm-metal (the same id as vLLM on CUDA, by design: one table for both platforms).
        "engines": ["mlx-lm", "omlx", "vllm-mlx", "vllm", "ollama", "llama-server", "lm-studio"],
        "metrics": {"node_exporter": 9100, "macmon": 9101},
        # Presets carry no memory-bandwidth figure: a hardware fact is chip, memory or accelerator (parse_inventory), and
        # nothing here reads a bandwidth. The decode prior of fit v2 will want one; it adds the field then.
        "presets": [
            {"id": "m5-ultra-96", "label": "Mac Studio M5 Ultra, 96 GB", "chip": "Apple M5 Ultra", "memory_gib": 96},
            {"id": "m5-ultra-256", "label": "Mac Studio M5 Ultra, 256 GB", "chip": "Apple M5 Ultra", "memory_gib": 256},
            {"id": "m5-ultra-512", "label": "Mac Studio M5 Ultra, 512 GB", "chip": "Apple M5 Ultra", "memory_gib": 512},
            {"id": "m5-max-128", "label": "Mac Studio M5 Max, 128 GB", "chip": "Apple M5 Max", "memory_gib": 128},
            {"id": "m4-max-64", "label": "Mac Studio M4 Max, 64 GB", "chip": "Apple M4 Max", "memory_gib": 64},
            {"id": "m4-pro-64", "label": "Mac mini M4 Pro, 64 GB", "chip": "Apple M4 Pro", "memory_gib": 64},
            {"id": "m3-ultra-512", "label": "Mac Studio M3 Ultra, 512 GB", "chip": "Apple M3 Ultra", "memory_gib": 512},
        ],
    },
    "nvidia-dgx-spark": {
        "name": "NVIDIA DGX Spark", "examples": "DGX Spark and OEM GB10 systems",
        "os": "DGX OS (Ubuntu, arm64)", "memory_kind": "unified", "usable": 0.85, "onboarding": "linux",
        "engines": ["nim", "vllm", "ollama", "llama-server"],
        "metrics": {"node_exporter": 9100, "dcgm": 9400},
        "presets": [{"id": "gb10-128", "label": "DGX Spark (GB10), 128 GB", "chip": "NVIDIA GB10", "memory_gib": 128}],
    },
    "nvidia-gpu-linux": {
        "name": "Linux with NVIDIA GPUs", "examples": "RTX / RTX PRO workstation or server",
        "os": "Linux (Ubuntu or similar)", "memory_kind": "gpu", "usable": 0.9, "onboarding": "linux",
        "engines": ["vllm", "ollama", "llama-server", "sglang"],
        "metrics": {"node_exporter": 9100, "dcgm": 9400},
        "presets": [
            {"id": "rtx-pro-6000-96", "label": "1x RTX PRO 6000 (96 GB)", "chip": "NVIDIA RTX PRO 6000", "memory_gib": 96},
            {"id": "rtx-5090-32", "label": "1x RTX 5090 (32 GB)", "chip": "NVIDIA RTX 5090", "memory_gib": 32},
            {"id": "rtx-4090-24", "label": "1x RTX 4090 (24 GB)", "chip": "NVIDIA RTX 4090", "memory_gib": 24},
        ],
    },
    "amd-strix-halo": {
        "name": "AMD Ryzen AI Max (Strix Halo)", "examples": "Framework Desktop and other Ryzen AI Max+ 395 mini PCs",
        "os": "Linux", "memory_kind": "unified", "usable": 0.8, "onboarding": "strix",
        "engines": ["llama-server", "ollama", "lm-studio"],
        "metrics": {"node_exporter": 9100},
        "presets": [{"id": "ai-max-395-128", "label": "Ryzen AI Max+ 395, 128 GB", "chip": "AMD Ryzen AI Max+ 395", "memory_gib": 128}],
    },
    "openai-compatible": {
        "name": "Other OpenAI-compatible server", "examples": "Any host that answers GET /v1/models",
        "os": "any", "memory_kind": "unknown", "usable": 0.8, "onboarding": "generic",
        "engines": ["openai-compatible", "ollama", "llama-server", "vllm"], "metrics": {}, "presets": [],
    },
}


# ---------------------------------------------------------------- the inventory

@dataclass
class Fact:
    value: object
    source: str            # preset | operator | metrics | engine

    def as_dict(self):
        return {"value": self.value, "source": self.source}


@dataclass
class Endpoint:
    id: str
    engine: str
    url: str               # scheme://host:port (the origin; base paths come from the engine)
    auth_secret: str = ""  # name of a Secret holding the bearer token, never the token
    note: str = ""

    @property
    def host(self) -> str:
        return urlsplit(self.url).hostname or ""

    @property
    def port(self) -> int:
        u = urlsplit(self.url)
        return u.port or (443 if u.scheme == "https" else 80)


@dataclass
class Node:
    id: str
    name: str
    type: str
    address: str
    endpoints: list[Endpoint] = field(default_factory=list)
    hardware: dict[str, Fact] = field(default_factory=dict)   # chip, memory_gib, accelerator
    metrics: dict[str, int] = field(default_factory=dict)     # exporter name -> port on `address`
    labels: dict[str, str] = field(default_factory=dict)
    management: dict = field(default_factory=dict)            # {"enrolled": True} when tockmox-ai-node converges it

    @property
    def enrolled(self) -> bool:
        """True only for a node the admin enrolled for GitOps convergence (`management.enrolled: true`). An import-only
        node, the default and a first-class path, is not: it has no convergence or readiness to report, so the UI shows
        neither for it (design 0 A14)."""
        return self.management.get("enrolled") is True

    @property
    def kind(self) -> dict:
        return CATALOG.get(self.type, CATALOG["openai-compatible"])

    def endpoint(self, eid: str) -> Endpoint | None:
        return next((e for e in self.endpoints if e.id == eid), None)

    def memory_gib(self) -> float | None:
        f = self.hardware.get("memory_gib")
        try:
            return float(f.value) if f else None
        except (TypeError, ValueError):
            return None


@dataclass
class Route:
    alias: str
    node: str
    endpoint: str
    model: str                      # the upstream model id the engine knows
    kind: str = "chat"
    provider: str = ""              # LiteLLM provider prefix; empty = derived from engine + kind
    params: dict = field(default_factory=dict)      # extra litellm_params, carried verbatim
    model_info: dict = field(default_factory=dict)  # carried verbatim
    size_gib: float | None = None   # what the fit check plans with, when known


DEFAULT_CONVERGE_INTERVAL_S = 900     # ai-nodes/fleet.yaml defaults.convergeIntervalSeconds (CONTRACT)
SIGNING_MODES = ("warn", "enforce")
# Shell-safe by construction: these two values reach an operator's terminal in the enroll one-liner, so they are
# matched against an allow list (no quote, space, $, `, ;, &, |, newline) and set by SITE VALUES ONLY, never by a link.
_REPO_RE = re.compile(r"^(https://[A-Za-z0-9][A-Za-z0-9._~/:%+@-]{0,299}|[a-z][a-z0-9_-]{0,31}@[A-Za-z0-9][A-Za-z0-9.-]{0,252}:[A-Za-z0-9._~/+-]{1,299})$")
_REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/+-]{0,99}$")


@dataclass
class AiNodeSettings:
    """`inferenceNodes.aiNodes`: what the fleet shares, from site values. Everything is optional."""
    site_repo: str = ""                 # where the nodes pull the site repo from (the bootstrap's --site-repo)
    toolkit_ref: str = ""               # the tockmox release tag the nodes pin (the bootstrap's --toolkit-ref)
    signing_mode: str = ""              # warn | enforce, as ai-nodes/fleet.yaml says; informational
    converge_interval_s: int = DEFAULT_CONVERGE_INTERVAL_S
    admin_cidrs: tuple = ()             # offered to the ai-node.yaml skeleton as access.adminCidrs


def parse_ai_settings(raw) -> AiNodeSettings:
    if raw in (None, {}):
        return AiNodeSettings()
    if not isinstance(raw, dict):
        raise NodeError("aiNodes must be a map")
    extra = set(raw) - {"siteRepo", "toolkitRef", "signingMode", "convergeIntervalSeconds", "adminCidrs"}
    if extra:
        raise NodeError(f"aiNodes: unknown key(s) {sorted(extra)}")
    repo = str(raw.get("siteRepo", "") or "")
    if repo and not _REPO_RE.match(repo):
        raise NodeError("aiNodes.siteRepo must be an https:// URL or user@host:path, with no spaces or shell characters")
    ref = str(raw.get("toolkitRef", "") or "")
    if ref and not _REF_RE.match(ref):
        raise NodeError("aiNodes.toolkitRef must be a tag or branch name")
    mode = str(raw.get("signingMode", "") or "")
    if mode and mode not in SIGNING_MODES:
        raise NodeError(f"aiNodes.signingMode must be one of {SIGNING_MODES}")
    iv = raw.get("convergeIntervalSeconds", DEFAULT_CONVERGE_INTERVAL_S)
    if isinstance(iv, bool) or not isinstance(iv, int) or not (60 <= iv <= 86400):
        raise NodeError("aiNodes.convergeIntervalSeconds must be a whole number of seconds from 60 to 86400")
    cidrs = []
    for c in raw.get("adminCidrs") or []:
        try:
            cidrs.append(str(ipaddress.ip_network(str(c), strict=False)))
        except ValueError:
            raise NodeError(f"aiNodes.adminCidrs: {c!r} is not a CIDR") from None
    return AiNodeSettings(repo, ref, mode, iv, tuple(cidrs))


@dataclass
class Inventory:
    nodes: list[Node] = field(default_factory=list)
    routes: list[Route] = field(default_factory=list)
    ai: AiNodeSettings = field(default_factory=AiNodeSettings)

    def node(self, nid: str) -> Node | None:
        return next((n for n in self.nodes if n.id == nid), None)

    def routes_on(self, nid: str) -> list[Route]:
        return [r for r in self.routes if r.node == nid]

    def aliases(self) -> set[str]:
        return {r.alias for r in self.routes}


def _host_ok(h: str) -> bool:
    if not h or len(h) > 253:
        return False
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        return bool(re.match(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*$", h))


def check_origin(url: str) -> str:
    """An endpoint URL is an origin: http(s)://host[:port], nothing after it."""
    u = urlsplit(url or "")
    if u.scheme not in ("http", "https") or not _host_ok(u.hostname or ""):
        raise NodeError(f"endpoint url must be http(s)://host[:port]: {url!r}")
    if u.path not in ("", "/") or u.query or u.fragment or u.username or u.password:
        raise NodeError(f"endpoint url must be an origin with no path, query or credentials: {url!r}")
    try:
        u.port
    except ValueError:
        raise NodeError(f"endpoint url has a bad port: {url!r}") from None
    host = u.hostname
    if ":" in host:
        host = f"[{host}]"
    return f"{u.scheme}://{host}" + (f":{u.port}" if u.port else "")


def parse_inventory(doc: dict | None) -> Inventory:
    doc = doc or {}
    inv = Inventory(ai=parse_ai_settings(doc.get("aiNodes")))
    seen = set()
    for raw in doc.get("nodes") or []:
        nid = str(raw.get("id", ""))
        if not ID_RE.match(nid):
            raise NodeError(f"node id {nid!r} must match {ID_RE.pattern}")
        if nid in seen:
            raise NodeError(f"node id {nid!r} is duplicated")
        if nid in RESERVED_NODE_IDS:
            raise NodeError(f"node id {nid!r} is reserved by the UI")
        seen.add(nid)
        ntype = str(raw.get("type", "openai-compatible"))
        if ntype not in CATALOG:
            raise NodeError(f"node {nid}: unknown type {ntype!r}")
        addr = str(raw.get("address", ""))
        if not _host_ok(addr):
            raise NodeError(f"node {nid}: address {addr!r} is not a host name or IP")
        eps, eseen = [], set()
        for e in raw.get("endpoints") or []:
            eid = str(e.get("id", ""))
            if not ID_RE.match(eid) or eid in eseen:
                raise NodeError(f"node {nid}: endpoint id {eid!r} invalid or duplicated")
            eseen.add(eid)
            eng = str(e.get("engine", "openai-compatible"))
            if eng not in ENGINES:
                raise NodeError(f"node {nid}: endpoint {eid}: unknown engine {eng!r}")
            sec = str((e.get("auth") or {}).get("secretRef", "") or "")
            if sec and not ID_RE.match(sec):
                raise NodeError(f"node {nid}: endpoint {eid}: secretRef {sec!r} must be a Secret name")
            eps.append(Endpoint(eid, eng, check_origin(str(e.get("url", ""))), sec, str(e.get("note", ""))))
        hw = {}
        for k, v in (raw.get("hardware") or {}).items():
            if k not in ("chip", "memory_gib", "accelerator"):
                raise NodeError(f"node {nid}: unknown hardware fact {k!r}")
            if not isinstance(v, dict) or v.get("source") not in FACT_SOURCES:
                raise NodeError(f"node {nid}: hardware.{k} needs a value and a source in {FACT_SOURCES}")
            hw[k] = Fact(_pos(v.get("value"), f"node {nid}: hardware.{k}") if k == "memory_gib" else v.get("value"), v["source"])
        metrics = {}
        for k, p in (raw.get("metrics") or {}).items():
            if not re.match(r"^[a-z0-9_]{1,32}$", str(k)) or not (isinstance(p, int) and 0 < p < 65536):
                raise NodeError(f"node {nid}: metrics.{k} must be a port number")
            metrics[str(k)] = p
        labels = {str(k): str(v) for k, v in (raw.get("labels") or {}).items()}
        mgmt = raw.get("management")
        if mgmt is not None:
            if not isinstance(mgmt, dict) or set(mgmt) - {"enrolled"} or not isinstance(mgmt.get("enrolled", False), bool):
                raise NodeError(f"node {nid}: management must be {{enrolled: true|false}}")
        inv.nodes.append(Node(nid, str(raw.get("name", nid)), ntype, addr, eps, hw, metrics, labels,
                              {"enrolled": True} if (mgmt or {}).get("enrolled") else {}))
    aliases = set()
    for raw in doc.get("routes") or []:
        r = _route_from(raw)
        if r.alias in aliases:
            raise NodeError(f"route alias {r.alias!r} is duplicated")
        n = inv.node(r.node)
        if n is None or n.endpoint(r.endpoint) is None:
            raise NodeError(f"route {r.alias}: no endpoint {r.node}/{r.endpoint}")
        aliases.add(r.alias)
        inv.routes.append(r)
    return inv


def _route_from(raw: dict) -> Route:
    alias = str(raw.get("alias", ""))
    if not ALIAS_RE.match(alias):
        raise NodeError(f"route alias {alias!r} is not a valid gateway alias")
    kind = str(raw.get("kind", "chat"))
    if kind not in KINDS:
        raise NodeError(f"route {alias}: kind must be one of {KINDS}")
    model = str(raw.get("model", ""))
    if not model or len(model) > 200 or any(c.isspace() for c in model):
        raise NodeError(f"route {alias}: model id {model!r} is invalid")
    prov = str(raw.get("provider", "") or "")
    if prov and not re.match(r"^[a-z0-9_]{1,32}$", prov):
        raise NodeError(f"route {alias}: provider {prov!r} is invalid")
    params = raw.get("params") or {}
    info = raw.get("modelInfo") or {}
    if not isinstance(params, dict) or not isinstance(info, dict):
        raise NodeError(f"route {alias}: params and modelInfo must be maps")
    for reserved in ("model", "api_base"):
        if reserved in params:
            raise NodeError(f"route {alias}: params may not set {reserved!r}; it is derived")
    if strip_secrets(params)[1] or strip_secrets(info)[1]:
        raise NodeError(f"route {alias}: a credential-named param holds a literal value; use os.environ/<VAR> "
                        "or the endpoint's auth.secretRef")
    size = _pos(raw.get("sizeGiB"), f"route {alias}: sizeGiB")
    return Route(alias, str(raw.get("node", "")), str(raw.get("endpoint", "")), model, kind, prov,
                 dict(params), dict(info), size)


def _pos(v, what):
    """A positive, finite number, or None. NaN and negatives used to slip through and read "fits"."""
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise NodeError(f"{what} must be a number") from None
    if not (f > 0 and f < 1e6):
        raise NodeError(f"{what} must be a positive number")
    return f


# ---------------------------------------------------------------- derivation (AC-47.1)

def provider_for(engine: str, kind: str) -> str:
    p = ENGINES.get(engine, ENGINES["openai-compatible"])["provider"].get(kind)
    if not p:
        raise NodeError(f"{ENGINES[engine]['name']} does not serve {kind} through the gateway")
    return p


def _base_path(provider: str, engine: str, kind: str) -> str:
    if provider in ("ollama", "ollama_chat", "infinity"):
        return ""
    return ENGINES.get(engine, ENGINES["openai-compatible"])["base_path"].get(kind, "/v1") or "/v1"


def api_base(route: Route, ep: Endpoint) -> str:
    prov = route.provider or provider_for(ep.engine, route.kind)
    return ep.url + _base_path(prov, ep.engine, route.kind)


NEXT = "-next"
GATEWAYS = ("production", "eval", "all")


def gateway_routes(inv: Inventory, gateway: str = "production") -> list:
    """Which routes each gateway serves (REQ-0048 as revised after TM-0936).

    production: every route except `-next` ones. A candidate is never in the production gateway, because
                inside one LiteLLM an access group fails open for a key with no model list.
    eval:       every `-next` route plus the live route it is compared against (the runner calls both).
    all:        everything (a single route being placed by hand on a node page)."""
    if gateway not in GATEWAYS:
        raise NodeError(f"gateway must be one of {GATEWAYS}")
    if gateway == "all":
        return list(inv.routes)
    if gateway == "production":
        return [r for r in inv.routes if not r.alias.endswith(NEXT)]
    bases = {r.alias[: -len(NEXT)] for r in inv.routes if r.alias.endswith(NEXT)}
    return [r for r in inv.routes if r.alias.endswith(NEXT) or r.alias in bases]


# EVERY OLLAMA ROUTE PINS ITS CONTEXT (TM-0957, TM-0958). The chart refuses an Ollama route with no params.num_ctx,
# because Ollama then sizes the context from the node's memory (256k tokens at 48 GiB or more). 16384 is the floor the
# reference lab runs; the operator edits it before committing. docs/administration/inference-nodes.md, "Context length".
DEFAULT_OLLAMA_NUM_CTX = 16384


def default_params(engine: str, params: dict | None = None) -> dict:
    """The route params to propose: what the caller gave, plus num_ctx when the engine is Ollama and none is set."""
    out = dict(params or {})
    if engine == "ollama" and "num_ctx" not in out:
        out["num_ctx"] = DEFAULT_OLLAMA_NUM_CTX
    return out


NO_AUTH_KEY = "no-auth"
KEY_REQUIRED_PROVIDERS = ("openai",)


def render_model_list(inv: Inventory, gateway: str = "production") -> list[dict]:
    """The gateway entries for node routes, for one gateway. The ONE place this mapping lives."""
    out = []
    for r in gateway_routes(inv, gateway):
        n = inv.node(r.node)
        ep = n.endpoint(r.endpoint) if n else None
        if ep is None:
            raise NodeError(f"route {r.alias}: no endpoint {r.node}/{r.endpoint}")
        prov = r.provider or provider_for(ep.engine, r.kind)
        lp = {"model": f"{prov}/{r.model}", "api_base": api_base(r, ep)}
        if ep.auth_secret and "api_key" not in r.params:
            lp["api_key"] = f"os.environ/{_env_name(ep.auth_secret)}"
        elif prov in KEY_REQUIRED_PROVIDERS and "api_key" not in r.params:
            # LiteLLM's openai provider refuses to send a request with no api_key at all ("The api_key client
            # option must be set"), even to a server that checks none: measured on 1.100.1 (TM-0920 lab). A
            # placeholder goes out as "Bearer no-auth", which a no-auth engine ignores.
            lp["api_key"] = NO_AUTH_KEY
        lp.update(r.params)
        entry = {"model_name": r.alias, "litellm_params": lp}
        info = dict(r.model_info)
        info.setdefault("tockmox_node", r.node)
        if gateway == "eval":
            eval_class_fence(r.alias, lp, info)
        entry["model_info"] = info
        out.append(entry)
    return out


EVAL_LOCAL_TAGS = ("restricted", "internal", "open")
# TM-1249: an eval set's class, as the tag the runner sends with every request to the eval gateway
EVAL_CLASS_TAG = {"public": "open", "internal": "internal", "confidential": "restricted", "restricted": "restricted"}


def eval_class_fence(alias: str, lp: dict, info: dict) -> None:
    """TM-1249: the eval gateway filters by tag. A node route is local unless it says otherwise and may serve every class;
    an external route may serve open (public data) only. Fills the defaults in place; refuses an external route tagged
    for more. The chart applies the same (templates/_inference-nodes.tpl)."""
    tier = info.get("endpoint_tier") or "local"
    if tier not in ("local", "external"):
        raise NodeError(f"route {alias} has model_info.endpoint_tier {tier!r}; it must be local or external")
    info["endpoint_tier"] = tier
    if "tags" not in lp:
        lp["tags"] = list(EVAL_LOCAL_TAGS) if tier == "local" else ["open"]
    if tier == "external" and any(t != "open" for t in lp["tags"]):
        raise NodeError(f"route {alias} is external but its tags {lp['tags']} let the eval gateway send it data above "
                        "public; an external route may carry only the tag open (TM-1249)")


def _env_name(secret: str) -> str:
    return "NODE_KEY_" + re.sub(r"[^A-Z0-9]", "_", secret.upper())


# ---------------------------------------------------------------- import from the gateway (AC-47.2)

PUBLIC_HINT = re.compile(r"(^|\.)(openai\.com|anthropic\.com|googleapis\.com|azure\.com|amazonaws\.com|mistral\.ai|groq\.com|"
                         r"together\.xyz|together\.ai|openrouter\.ai|deepseek\.com|x\.ai|nvidia\.com|fireworks\.ai|cerebras\.ai|"
                         r"cohere\.(com|ai)|perplexity\.ai|huggingface\.co|replicate\.com|deepinfra\.com|anyscale\.com|sambanova\.ai)$")


@dataclass
class ImportResult:
    inventory: Inventory
    skipped: list[tuple[str, str]]     # (alias, why)
    notes: list[str]


def _is_local_host(h: str) -> bool:
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_private or ip.is_loopback or ip.is_link_local
    except ValueError:
        # A name. The import makes no DNS lookup (no I/O), so a name is proposed as a node
        # unless it is a known hosted provider; the admin confirms every proposed node.
        return not PUBLIC_HINT.search(h.lower())


_SECRET_KEY = re.compile(r"(?i)(key|secret|token|password|passwd|credential|authorization|auth|cookie|bearer)")


PLACEHOLDERS = frozenset({"local-no-auth", "no-auth", "none", "empty", "dummy", "not-needed", "sk-no-key-required", ""})


def looks_secret(v) -> bool:
    """A literal that could be a credential. References (os.environ/...) and known placeholders never are."""
    if not isinstance(v, str) or v.startswith("os.environ/"):
        return False
    return v.strip().lower() not in PLACEHOLDERS


def strip_secrets(d, path="") -> tuple[dict, list[str]]:
    """Copy of d with every literal under a credential-named key removed, at any depth (review finding:
    nested extra_headers.Authorization and short passwords were carried into the change)."""
    out, dropped = {}, []
    for k, v in (d or {}).items():
        here = f"{path}{k}"
        if isinstance(v, dict):
            sub, dr = strip_secrets(v, here + ".")
            out[k] = sub
            dropped += dr
        elif _SECRET_KEY.search(str(k)) and looks_secret(v):
            dropped.append(here)
        else:
            out[k] = v
    return out, dropped


def _engine_from_route(provider: str, port: int) -> str:
    if provider in ("ollama", "ollama_chat") or port == 11434:
        return "ollama"
    if port == 52415:
        return "exo"
    if port == 1234:
        return "lm-studio"
    # 8080 is mlx-lm's AND llama-server's AND TGI's default; 8000 is vLLM's AND NIM's.
    # Guessing would put a wrong word on the page, so say what we know.
    return "openai-compatible"


def _slug(s: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return (s or "node")[:40].strip("-") or "node"


def import_model_list(model_list, names: dict[str, str] | None = None) -> ImportResult:
    """Group a LiteLLM model_list's local routes by host into proposed nodes. No I/O."""
    names = names or {}
    if not isinstance(model_list, list):
        raise NodeError("expected a model_list: a YAML list of {model_name, litellm_params}")
    inv, skipped, notes = Inventory(), [], []
    by_host: dict[str, Node] = {}
    for i, m in enumerate(model_list[:500]):
        if not isinstance(m, dict) or not isinstance(m.get("litellm_params"), dict):
            skipped.append((f"entry {i + 1}", "not a model_list entry"))
            continue
        alias = str(m.get("model_name", ""))
        lp = dict(m["litellm_params"])
        base = lp.pop("api_base", None)
        full = str(lp.pop("model", ""))
        if not base:
            skipped.append((alias, "no api_base: a hosted provider, not a node"))
            continue
        try:
            u = urlsplit(str(base))
            host = u.hostname or ""
            u.port                                      # raises on a bad port
        except ValueError:
            skipped.append((alias, f"api_base {base!r} is not a usable URL"))
            continue
        if u.scheme not in ("http", "https") or not _host_ok(host):
            skipped.append((alias, f"api_base {base!r} is not a usable http(s) URL"))
            continue
        if not _is_local_host(host):
            skipped.append((alias, f"{host} looks like a hosted service, not a node"))
            continue
        if "/" not in full:
            skipped.append((alias, f"model {full!r} has no provider prefix"))
            continue
        provider, model = full.split("/", 1)
        port = u.port or (443 if u.scheme == "https" else 80)
        node = by_host.get(host)
        if node is None:
            nid = _unique(_slug(names.get(host, host)), {n.id for n in inv.nodes})
            node = Node(nid, names.get(host, host), "openai-compatible", host)
            by_host[host] = node
            inv.nodes.append(node)
        origin = f"{u.scheme}://{host if ':' not in host else '[' + host + ']'}:{port}"
        ep = next((e for e in node.endpoints if e.url == origin), None)
        if ep is None:
            eng = _engine_from_route(provider, port)
            ep = Endpoint(f"{eng if eng != 'openai-compatible' else u.scheme}-{port}" + ("-tls" if u.scheme == "https" and eng != "openai-compatible" else ""),
                          eng, origin)
            node.endpoints.append(ep)
        elif ep.engine == "openai-compatible" and _engine_from_route(provider, port) != "openai-compatible":
            ep.engine = _engine_from_route(provider, port)
        kind = "rerank" if provider == "infinity" else ("embedding" if (lp.get("mode") == "embedding" or (provider == "ollama" and "embed" in model)) else "chat")
        expected_path = _base_path(provider, ep.engine, kind)
        if (u.path.rstrip("/") or "") != expected_path:
            notes.append(f"{alias}: api_base path {u.path or '/'} differs from the {provider}/ default {expected_path or '/'}; kept as a provider override")
        if alias in inv.aliases():
            skipped.append((alias, "duplicate alias in the source list"))
            continue
        lp, dropped = strip_secrets(lp)            # never carry a literal credential into a change committed to git
        for k in dropped:
            notes.append(f"{alias}: {k} was a literal value and was left out; put it in a Secret and name "
                         "the Secret on the endpoint (auth.secretRef)")
        info = m.get("model_info") if isinstance(m.get("model_info"), dict) else {}
        info, dr = strip_secrets(info)
        notes += [f"{alias}: model_info.{k} was a literal value and was left out" for k in dr]
        if ep.engine == "ollama" and "num_ctx" not in lp:
            notes.append(f"{alias}: sets no num_ctx, so {DEFAULT_OLLAMA_NUM_CTX} was proposed; the chart refuses an Ollama "
                         "route without one. Set the context you want before committing")
        lp = default_params(ep.engine, lp)
        inv.routes.append(Route(alias, node.id, ep.id, model, kind, provider, lp, info, estimate_size_gib(model)))
    # Macs are recognisable from the engine mix; say so, never assert it.
    for n in inv.nodes:
        if any(e.engine == "ollama" for e in n.endpoints) and any("mlx-community/" in r.model for r in inv.routes_on(n.id)):
            n.type = "apple-silicon-mac"
            notes.append(f"{n.name}: serves mlx-community models, so proposed as an Apple silicon Mac (check it)")
    return ImportResult(inv, skipped, notes)


def _unique(base: str, taken: set[str]) -> str:
    taken = set(taken) | RESERVED_NODE_IDS
    if base not in taken:
        return base
    i = 2
    while f"{base}-{i}"[:40] in taken:
        i += 1
    return f"{base}-{i}"[:40]


# ---------------------------------------------------------------- fit (AC-47.5)

_PARAMS = re.compile(r"(?<![A-Za-z0-9.])(\d+(?:\.\d+)?)\s*[bB](?![A-Za-z])")

# Bits per weight, scales included. ORDER MATTERS: the first match wins, so the specific formats come before the
# generic "q8" / "q4" markers. "gpt-oss-120b-MXFP4-Q8" used to match q8 (8.5 bits) before mxfp4 and read 2.4x too big
# (research D 1.3). MXFP4 is 4 bits plus an 8-bit scale per 32 weights. NVFP4 is nominally 4.5 (a scale per 16), but
# nothing has measured an NVFP4 file, so it takes the MXFP4 figure the design names; fit v2 replaces both with bytes.
_QUANT = [
    (re.compile(r"(?i)(mxfp4|nvfp4)"), 4.25),
    (re.compile(r"(?i)(bf16|fp16|f16)"), 16.0),
    (re.compile(r"(?i)(fp8|8bit|q8_0|q8|int8)"), 8.5),
    (re.compile(r"(?i)(6bit|q6_k|q6\b)"), 6.6),
    (re.compile(r"(?i)(5bit|q5_k_m|q5)"), 5.7),
    (re.compile(r"(?i)(4bit|q4_k_m|q4_0|q4|int4|awq|gptq)"), 4.6),
    (re.compile(r"(?i)(3bit|q3)"), 3.6),
]

# Weights a name cannot see, each FITTED TO ONE ROW of research D's measured table (one model each), so they are
# narrow on purpose and are not a model of the families. The estimate stays an estimate; the watcher's exact byte
# count (fit v2) is what retires them.
#   gemma: a vision tower and a 262k-token vocabulary on top of the language model (gemma-3-27b-it-4bit: +0.35 bit).
#   gpt-oss MXFP4 up to 30B: attention and embeddings kept at 8 bits are a larger share of a small model
#   (gpt-oss-20b-MXFP4-Q8: +0.55 bit; the 120b has no such residual).
_RESIDUAL_BITS = [   # (name pattern, extra bits per weight, applies up to this many billion parameters, only with this quant)
    (re.compile(r"(?i)gemma"), 0.35, None, None),
    (re.compile(r"(?i)gpt-oss"), 0.55, 30.0, re.compile(r"(?i)(mxfp4|nvfp4)")),
]

# The figure is gigabytes (1e9 bytes, what parameters x bits / 8 gives) and the planner's unit is GiB (2^30). The
# 1.1 this used to multiply by was meant as overhead but landed on top of a 4.6-bit figure that already carries the
# group scales, and 8-bit read about 15% high and 4-bit 9 to 21% high (research D 1.3). Nothing is added now; the
# conversion alone is the correction.
GB_TO_GIB = 1e9 / (1 << 30)


# The smallest size a route may carry. parse_route refuses sizeGiB unless it is positive, so every size
# the UI itself writes into a draft goes through planning_size: a model an engine lists at a few bytes
# (a stub) or a few megabytes (a small embedding model) used to round to 0.0 and the UI refused its
# own draft with "sizeGiB must be a positive number" and no field to correct it (TM-0980, lab F-L1-11).
MIN_SIZE_GIB = 0.1


def planning_size(gib) -> float | None:
    """A size the planner and parse_route both accept: rounded to a tenth with a 0.1 floor, or None
    when there is nothing to plan with (unknown, zero, negative, not a number)."""
    try:
        f = float(gib)
    except (TypeError, ValueError):
        return None
    if not (f > 0 and f < 1e6):
        return None
    return max(MIN_SIZE_GIB, round(f, 1))


def estimate_size_gib(model_id: str, default_bits: float = 4.6) -> float | None:
    """Weights only, from the model's name: parameters x bits / 8, in GiB. An ESTIMATE.

    Checked against research D's measured table (tests/test_nodes_fit.py): every MLX 4-bit, 8-bit and MXFP4 repo in it
    within 5%. The name cannot see a model's real parameter count or its non-quantised parts, so a model outside that
    table can be off by more; the page says "estimate" wherever it shows this.

    MoE names ("35B-A3B") count total parameters, because every expert is resident.
    Returns None when the name carries no parameter count; the fit check then says so.
    """
    s = model_id.replace("_", "-")
    q = model_id                                       # quant markers use underscores (q6_K, q8_0): match the original
    sizes = [float(x) for x in _PARAMS.findall(s.split(":")[-1] if ":" in s and not s.startswith("http") else s)]
    if not sizes and ":" in s:
        sizes = [float(x) for x in _PARAMS.findall(s)]
    if not sizes:
        return None
    params_b = max(sizes)
    bits = None
    for rx, b in _QUANT:
        if rx.search(q):
            bits = b
            break
    if bits is None:
        # No quant in the name. An Ollama tag (name:size) defaults to a 4-bit-class quant; a bare
        # Hugging Face repo id is the publisher's weights, which vLLM, NIM and SGLang serve in bf16
        # (review finding: Qwen/Qwen3-32B read as 20 GiB, about 3.5x under).
        bits = default_bits if (":" in model_id or "gguf" in model_id.lower()) else 16.0
    for rx, extra, max_b, only_quant in _RESIDUAL_BITS:
        if rx.search(q) and (max_b is None or params_b <= max_b) and (only_quant is None or only_quant.search(q)):
            bits += extra
            break
    return planning_size(params_b * bits / 8 * GB_TO_GIB)


def loading(engine: str) -> str:
    """resident: the server holds its model all the time (mlx-lm, llama-server, vLLM ...).
    on-demand: the engine loads a model when asked and can unload it (Ollama, LM Studio)."""
    return ENGINES.get(engine, {}).get("loading", "resident")


# ---------------------------------------------------------------- enrolled nodes (tockmox-ai-node)
#
# A node is ENROLLED when the admin has asked tockmox-ai-node to converge it from the site repo
# (`management.enrolled: true`). Only an enrolled node has a convergence or readiness to report; an import-only node
# (register it, probe it, Tockmox converges nothing) is a first-class path and shows neither.

# The engines tockmox-ai-node v1 converges (CONTRACT, ai-node.yaml `engines`). Any other engine id is still a valid
# endpoint to record and route to; the admin starts it themselves.
CONVERGED_ENGINES = ("mlx-lm", "llama-server", "ollama")

# The facts exporter's checks on macOS, in the order the readiness panel lists them (CONTRACT, metrics).
READINESS_CHECKS = {
    "os_min_version": "macOS is at or above the declared minimum",
    "filevault_posture": "FileVault matches the declared posture",
    "remote_login": "Remote Login (SSH) is on",
    "wired_limit": "The GPU wired-memory limit is set",
    "pf_anchor": "The firewall anchor is loaded",
    "converge_loaded": "The converge job is loaded",
    "spotlight_off": "Spotlight indexing is off",
    "autoinstall_off": "Automatic macOS installs are off",
    "macmon_up": "macmon is running",
    "apple_account_signed_out": "No Apple Account is signed in",
}

_SSH_USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_SSH_HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*$")


@dataclass
class EnrollCommand:
    text: str                  # the copy-paste one-liner, placeholders where a value is unknown or was refused
    complete: bool             # True when the node id and the host are real values, so a change can be generated
    notes: list = field(default_factory=list)   # why a value was replaced; never the value itself (nothing is echoed back)


def enroll_command(node_id: str, host: str, site_repo: str = "", toolkit_ref: str = "", admin_user: str = "admin") -> EnrollCommand:
    """The bootstrap one-liner, built so that NO value can carry shell syntax into the operator's terminal.

    A value that arrives in a link (node id, host, admin user) is matched against an allow list and replaced by a
    visible placeholder when it fails; it is never echoed back. The site repository and the toolkit ref are not taken
    from a link at all: a link that could name them would let a stranger point a node at a repository of theirs. They
    come from site values (`inferenceNodes.aiNodes`), which are validated the same way. Each value that survives is also
    shell-quoted, at both levels (the remote command, then the whole of it for the local shell)."""
    import shlex
    notes = []

    def pick(value, ok, placeholder, what, rule):
        v = (value or "").strip()
        if v and ok(v):
            return v, True
        if v:
            notes.append(f"{what} was not used: {rule}")
        return placeholder, False

    nid, nid_ok = pick(node_id, lambda v: bool(ID_RE.match(v)) and v not in RESERVED_NODE_IDS, "NODE_ID", "The node id",
                       "lowercase letters, digits and dashes, up to 40 characters")
    hst, hst_ok = pick(host, lambda v: bool(_SSH_HOST_RE.match(v)) and len(v) <= 253, "HOST", "The host",
                       "a host name or an IPv4 address")
    usr, _ = pick(admin_user, lambda v: bool(_SSH_USER_RE.match(v)), "ADMIN_USER", "The admin user",
                  "a short account name in lowercase letters, digits, dashes and underscores")
    if not (admin_user or "").strip():
        usr = "admin"
    repo, _ = pick(site_repo, lambda v: bool(_REPO_RE.match(v)), "SITE_REPO", "The site repository", "set it in inferenceNodes.aiNodes.siteRepo")
    ref, _ = pick(toolkit_ref, lambda v: bool(_REF_RE.match(v)), "TOOLKIT_REF", "The toolkit ref", "set it in inferenceNodes.aiNodes.toolkitRef")

    def q(v, real):
        return shlex.quote(v) if real else v

    remote = " ".join(["bash", "/tmp/bootstrap-node.sh", "--ai-node-id", q(nid, nid_ok),
                       "--site-repo", q(repo, repo != "SITE_REPO"), "--toolkit-ref", q(ref, ref != "TOOLKIT_REF")])
    target = f"{q(usr, usr != 'ADMIN_USER')}@{q(hst, hst_ok)}"
    text = f"scp ai-node/bootstrap-node.sh {target}:/tmp/ && ssh -t {target} {shlex.quote(remote)}"
    return EnrollCommand(text, nid_ok and hst_ok, notes)


def enroll_inventory(node_id: str, host: str, name: str, preset: str, engine: str) -> Inventory:
    """The inferenceNodes record an enrolment adds: a Mac, its exporters, one endpoint for the engine it will run, and
    `management.enrolled`. No routes yet: placing a model on the node is the next step, from its page."""
    kind = CATALOG["apple-silicon-mac"]
    if engine not in kind["engines"]:
        raise NodeError(f"{engine!r} is not an engine for {kind['name']}")
    hw = {}
    p = next((x for x in kind["presets"] if x["id"] == preset), None)
    if p:
        hw["chip"] = Fact(p["chip"], "preset")
        hw["memory_gib"] = Fact(p["memory_gib"], "preset")
    port = ENGINES[engine]["port"]
    n = Node(node_id, (name.strip() or node_id)[:80], "apple-silicon-mac", host,
             [Endpoint(f"{engine}-{port}", engine, f"http://{host}:{port}")], hw, dict(kind["metrics"]), {}, {"enrolled": True})
    return parse_inventory(inventory_to_doc(Inventory([n], [])))      # the same validation the change applies


@dataclass
class Fit:
    state: str                 # fits | tight | over | unknown
    usable_gib: float | None
    placed_gib: float          # resident models + the largest on-demand one (the worst moment)
    new_gib: float | None
    unknown_sizes: list[str]
    basis: str
    resident_gib: float = 0.0
    on_demand_max_gib: float = 0.0
    new_on_demand: bool = False

    @property
    def total(self) -> float:
        if self.new_on_demand:
            return round(self.resident_gib + max(self.on_demand_max_gib, self.new_gib or 0), 1)
        return round(self.placed_gib + (self.new_gib or 0), 1)


def fit(node: Node, routes: list[Route], new_size: float | None, new_engine: str = "", v2: dict | None = None) -> Fit:
    """Plan against the worst moment: every resident model, plus the largest on-demand one.

    Two aliases on one model on one endpoint cost one copy. The figure is weights only
    (estimate_size_gib); context comes on top. It never blocks a placement.

    `v2` (REQ-0048 AC-48.14) plans with exact sizes instead: {"sizes": {model: SizeRecord}, "facts": {"wired_limit_mib": ...},
    "need": fit.Need, "new_record": SizeRecord, "new_measured": fit.Measured, "overhead": {engine: fraction}}. See
    app/fit.py fit_compat, which returns this same Fit. Without it the answer is unchanged."""
    if v2 is not None:
        from . import fit as fitmod        # imported here: app/fit.py imports this module
        return fitmod.fit_compat(node, routes, new_size, new_engine, **v2)
    mem = node.memory_gib()
    usable = round(mem * node.kind["usable"], 1) if mem else None
    resident, od_max, unknown, seen = 0.0, 0.0, [], set()
    for r in routes:
        key = (r.endpoint, r.model)
        if key in seen:
            continue
        seen.add(key)
        if r.size_gib is None:
            unknown.append(r.alias)
            continue
        ep = node.endpoint(r.endpoint)
        if ep is not None and loading(ep.engine) == "on-demand":
            od_max = max(od_max, r.size_gib)
        else:
            resident += r.size_gib
    placed = round(resident + od_max, 1)
    basis = (f"{mem:g} GiB x {node.kind['usable']:.0%} usable ({node.kind['memory_kind']} memory planning default); "
             f"planned = resident {resident:.1f} GiB + largest on-demand {od_max:.1f} GiB"
             if mem else "no memory figure for this node")
    nod = loading(new_engine) == "on-demand" if new_engine else False
    f = Fit("unknown", usable, placed, new_size, unknown, basis, round(resident, 1), od_max, nod)
    if usable is None:
        return f
    if new_size is None:
        f.basis += "; the new model's size is not known"
        return f
    total = f.total
    f.state = "over" if total > usable else ("tight" if total > 0.85 * usable else "fits")
    return f


# ---------------------------------------------------------------- the change (AC-47.8)

def inventory_to_doc(inv: Inventory) -> dict:
    nodes = []
    for n in inv.nodes:
        d = {"id": n.id, "name": n.name, "type": n.type, "address": n.address}
        if n.hardware:
            d["hardware"] = {k: f.as_dict() for k, f in n.hardware.items()}
        if n.metrics:
            d["metrics"] = dict(n.metrics)
        if n.labels:
            d["labels"] = dict(n.labels)
        if n.enrolled:
            d["management"] = {"enrolled": True}
        d["endpoints"] = []
        for e in n.endpoints:
            ed = {"id": e.id, "engine": e.engine, "url": e.url}
            if e.auth_secret:
                ed["auth"] = {"secretRef": e.auth_secret}
            if e.note:
                ed["note"] = e.note
            d["endpoints"].append(ed)
        nodes.append(d)
    routes = []
    for r in inv.routes:
        d = {"alias": r.alias, "node": r.node, "endpoint": r.endpoint, "model": r.model, "kind": r.kind}
        if r.provider:
            d["provider"] = r.provider
        if planning_size(r.size_gib) is not None:   # never write a size parse_route would refuse
            d["sizeGiB"] = planning_size(r.size_gib)
        if r.params:
            d["params"] = r.params
        if r.model_info:
            d["modelInfo"] = r.model_info
        routes.append(d)
    return {"nodes": nodes, "routes": routes}


def merge_node(old: Node, new: Node) -> Node:
    """Re-probing or re-importing a node must not erase what the probe cannot know (review finding:
    labels, operator memory, metrics, endpoints and secretRefs were dropped on a re-probe)."""
    eps = {e.id: e for e in old.endpoints}
    for e in new.endpoints:
        prev = eps.get(e.id)
        eps[e.id] = Endpoint(e.id, e.engine, e.url, e.auth_secret or (prev.auth_secret if prev else ""), e.note or (prev.note if prev else ""))
    hw = dict(old.hardware)
    hw.update(new.hardware)
    # Enrolment is only ever added by a merge: a re-probe or re-import (which cannot know) must not un-enrol a node.
    # Taking it out is an edit to the values, made on purpose.
    mgmt = {"enrolled": True} if (new.enrolled or old.enrolled) else {}
    return Node(new.id, new.name or old.name, new.type if new.type != "openai-compatible" else old.type, new.address,
                list(eps.values()), hw, new.metrics or dict(old.metrics), {**old.labels, **new.labels}, mgmt)


def merge(base: Inventory, add: Inventory) -> Inventory:
    """`add` wins per alias and per field it states; everything else in `base` is kept."""
    out = parse_inventory(inventory_to_doc(base))
    out.ai = base.ai
    for n in add.nodes:
        old = out.node(n.id)
        out.nodes = [x for x in out.nodes if x.id != n.id] + [merge_node(old, n) if old else n]
    for r in add.routes:
        out.routes = [x for x in out.routes if x.alias != r.alias] + [r]
    res = parse_inventory(inventory_to_doc(out))     # re-validate the whole result
    res.ai = base.ai
    return res


class _Dumper(yaml.SafeDumper):
    """Every values file the UI or the PR opener writes. No anchors or aliases, ever: a reviewer reads these
    files, and `*id001` hides which route a list belongs to (TM-0939)."""

    def ignore_aliases(self, data):
        return True


def _str(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


_Dumper.add_representer(str, _str)


def change_yaml(inv: Inventory, header: str, raw: dict | None = None) -> str:
    """The whole inferenceNodes block: the operator's other keys (probe, cluster, gateway, valuesFile)
    carried as they are, nodes and routes replaced (review finding: a change used to drop them)."""
    block = {k: v for k, v in (raw or {}).items() if k not in ("nodes", "routes")}
    block.update(inventory_to_doc(inv))
    body = yaml.dump({"inferenceNodes": block, "litellm": roll_block(inv)}, Dumper=_Dumper, sort_keys=False,
                     default_flow_style=False, allow_unicode=False, width=120)
    lines = "".join(f"# {h}\n" for h in header.splitlines())
    return lines + body


def go_json_hash(obj) -> str:
    """The first 16 hex of sha256 over obj as Helm's `toJson` writes it (Go encoding/json: keys sorted, no
    spaces, <, > and & escaped, U+2028/2029 escaped). The chart (tockmox-ai litellm-config.yaml) refuses to
    render unless litellm.podAnnotations carries this hash of the derived routes, which is what rolls the
    gateway when they change; the UI and the PR opener write it beside inferenceNodes."""
    import hashlib
    import json
    text = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    for a, b in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), ("\u2028", "\\u2028"), ("\u2029", "\\u2029")):
        text = text.replace(a, b)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def routes_hash(inv: Inventory) -> str:
    return go_json_hash(render_model_list(inv, "production"))


ROLL_ANNOTATION = "tockmox.com/node-routes"


def roll_block(inv: Inventory) -> dict:
    """The litellm values a node-route change carries in the same file and commit: the one pod annotation that
    rolls the gateway (LiteLLM reads its config only at start-up). podAnnotations is a map, so Helm merges it
    with the site's own litellm values; this block holds nothing else."""
    return {"podAnnotations": {ROLL_ANNOTATION: routes_hash(inv)}}


def model_list_yaml(inv: Inventory, gateway: str = "production") -> str:
    return yaml.dump({"model_list": render_model_list(inv, gateway)}, Dumper=_Dumper, sort_keys=False,
                     default_flow_style=False, width=120)

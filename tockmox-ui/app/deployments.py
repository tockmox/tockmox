# SPDX-License-Identifier: Apache-2.0
"""Deployments (TM-1299): every gateway route read as "a model served by an engine on a node", with its tunings, the
memory it is planned at, and a node's memory bar. The node page builds on it now; the Models page (TM-1296) reuses it.

  deployment_rows(inv, lc=None, fit_inputs=None, node=None) -> [Deployment]
  memory_bar(node, deployments, usable) -> MemoryBar
  fit_inputs_for(lifecycle_settings, report=None, results=None) -> dict     what fit v2 needs, as the Recommend page reads it

TUNINGS. Four settings per deployment, each {value, source}: source is `route` (the route states it), `default` (the route
does not, and the engine's own default is known: the value, or a sentence when it is not a number) or `unknown` (the
route does not state it and nothing here knows the engine's default: shown as "engine default, not reported"). Nothing is
guessed. Where each one is read:

  context     modelInfo.max_input_tokens, params.num_ctx (Ollama), params.max_input_tokens
  slots       fit_inputs["slots_by_alias"], the same map fit.fit_compat takes. Tockmox keeps no per-route slot count, so
              without it the slots are unknown
  max output  params.max_tokens, params.max_completion_tokens
  thinking    params.extra_body.chat_template_kwargs.enable_thinking (false is Off, true is On); not stated is the
              engine's (the model template's) own setting, which is not guessed per model

MEMORY. The planned figure is fit.py's own arithmetic (fit.footprint: weights, plus the cache for context x slots, plus
engine overhead), with the same inputs the Recommend page gives it, so the node page and the fit pages agree. A route
that does not state its context is planned at fit.Need's default context, and slots at one unless the map says
otherwise: the Planned column says so rather than leaving it to be assumed. Two aliases on one model on one endpoint cost
one copy, and only the largest on-demand model (Ollama, LM Studio) counts, as in fit: the others are listed, and left out
of the bar with the reason. A deployment whose size is unknown is listed and left out of the bar, with a note.

Pure: it reads the inventory and the catalog it is given and imports no web code.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from . import fit as fx
from . import models as ml
from . import nodes as nm
from . import recommend as rc
from . import results as rs

SOURCES = ("route", "default", "unknown")

# What an engine does when the route says nothing, for the cases the repo documents (docs/administration/inference-nodes.md,
# "Context length"; docs/administration/ai-nodes.md, the mlx-lm request guard). A sentence, never a number made up.
ENGINE_DEFAULTS: dict[str, dict[str, str]] = {
    "mlx-lm": {"context": "the engine has no context setting; the prompt is capped at the gateway or not at all",
               "max_output": "the request's own value, unless the node sets a ceiling"},
    "llama-server": {"context": "the model's full trained context (-c 0)"},
}

_NOT_REPORTED = "engine default, not reported"
_HIDDEN_PARAMS = ("api_key", "tags")
_STATED = {"context": ("num_ctx", "max_input_tokens"), "max_output": ("max_tokens", "max_completion_tokens")}


def _pos_int(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return v if isinstance(v, int) and v > 0 else None


def short_count(n: int) -> str:
    """131072 -> 128K, 16384 -> 16K, 100000 -> 100,000."""
    return f"{n // 1024}K" if n >= 1024 and n % 1024 == 0 else f"{n:,}"


@dataclass(frozen=True)
class Tuning:
    """One setting of one deployment. `text` is what the page shows; `default` and `unknown` say why it is not a route value."""
    value: object = None            # int, bool or None
    source: str = "unknown"         # route | default | unknown
    note: str = ""                  # what the default is, when it is not a number
    kind: str = "count"             # count | flag

    @property
    def text(self) -> str:
        if self.source == "unknown":
            return _NOT_REPORTED
        if self.value is None:
            return "engine default"
        if self.kind == "flag":
            return "On" if self.value else "Off"
        return short_count(self.value) if self.value >= 1024 else str(self.value)

    @property
    def label(self) -> str:
        """The word that sits beside a value that is not the route's: "default"."""
        return "default" if self.source == "default" and self.value is not None else ""

    def as_dict(self) -> dict:
        d = {"value": self.value, "source": self.source}
        if self.note:
            d["note"] = self.note
        return d


@dataclass(frozen=True)
class Tunings:
    context: Tuning
    slots: Tuning
    max_output: Tuning
    thinking: Tuning

    def as_dict(self) -> dict:
        return {k: getattr(self, k).as_dict() for k in ("context", "slots", "max_output", "thinking")}


@dataclass(frozen=True)
class EndpointRef:
    id: str
    engine: str
    engine_name: str
    port: int
    url: str

    @property
    def label(self) -> str:
        return f"{self.engine_name} :{self.port}"


@dataclass
class Deployment:
    alias: str
    node: str
    node_name: str
    endpoint: EndpointRef
    model: str
    kind: str                       # chat | embedding | rerank
    build: str                      # catalog revision, 7 characters, or "" when the model is not in the catalog or unpinned
    build_full: str
    gateway: str                    # production | eval (a -next route is served by the eval gateway only)
    is_candidate: bool
    tunings: Tunings
    more: dict                      # every other route param, flattened: {"extra_body.top_k": 20}; no api_key, no tags
    planned_gib: float | None = None        # fit.footprint total, or None when the size is unknown
    planned_at: str = ""                    # "128K x 1 slot", what the figure was planned at
    provenance: str = "unknown"             # measured | exact | estimate | unknown (fit's)
    shares_with: str = ""                   # the alias whose copy of the same model on the same endpoint this one rides on
    on_demand: bool = False
    in_bar: bool = False
    bar_note: str = ""                      # why it is not in the bar
    size_unknown: bool = False

    @property
    def state(self) -> str:
        return "Candidate -next" if self.is_candidate else "Live"


def _flatten(prefix: str, v, out: dict) -> None:
    if isinstance(v, dict):
        for k in sorted(v, key=str):
            _flatten(f"{prefix}.{k}" if prefix else str(k), v[k], out)
    elif v is not None:
        out[prefix] = v


def _tunings(route: nm.Route, engine: str, slots: int | None) -> tuple[Tunings, dict]:
    params, info = route.params or {}, route.model_info or {}
    defaults = ENGINE_DEFAULTS.get(engine, {})

    def stated(field_name, sources):
        for src in sources:
            v = _pos_int(src[0].get(src[1]))
            if v is not None:
                return Tuning(v, "route")
        note = defaults.get(field_name)
        return Tuning(None, "default", note) if note else Tuning()

    context = stated("context", ((info, "max_input_tokens"), (params, "num_ctx"), (params, "max_input_tokens")))
    max_output = stated("max_output", ((params, "max_tokens"), (params, "max_completion_tokens")))
    ntok = _pos_int(slots)
    n_slots = Tuning(ntok, "route") if ntok else Tuning()
    eb0 = params.get("extra_body")
    kw = eb0.get("chat_template_kwargs") if isinstance(eb0, dict) else None
    kw = kw if isinstance(kw, dict) else {}
    think = kw.get("enable_thinking")
    if isinstance(think, bool):
        thinking = Tuning(think, "route", kind="flag")
    else:
        thinking = Tuning(None, "default", "the model template's own setting; the route does not state it", "flag")
    more: dict = {}
    rest = {k: v for k, v in params.items() if k not in _HIDDEN_PARAMS and k not in _STATED["context"]
            and k not in _STATED["max_output"] and not nm._SECRET_KEY.search(str(k))}
    if isinstance(rest.get("extra_body"), dict):
        eb = {k: v for k, v in rest["extra_body"].items() if k != "chat_template_kwargs"}
        ctk = {k: v for k, v in kw.items() if k != "enable_thinking"}
        if ctk:
            eb["chat_template_kwargs"] = ctk
        rest = {**rest, "extra_body": eb}
    _flatten("", rest, more)
    return Tunings(context, n_slots, max_output, thinking), more


def _need(t: Tunings, slots: int | None) -> fx.Need:
    default = fx.Need()
    ctx = t.context.value if t.context.source == "route" else default.context_tokens
    return fx.Need(ctx, _pos_int(slots) or default.slots)


def _short(rev: str) -> str:
    return (rev or "").replace("sha256:", "")[:7]


def deployment_rows(inv: nm.Inventory, lc: ml.Lifecycle | None = None, fit_inputs: dict | None = None,
                    node: str | None = None) -> list[Deployment]:
    """One Deployment per route, in inventory order (or the routes of one node). `lc` joins a route's model to the
    catalog for its build. `fit_inputs` is {"sizes": {model: SizeRecord}, "overhead": {node id: {engine: fraction}},
    "slots_by_alias": {alias: int}}; without it a route is planned from its own sizeGiB, at fit's default need."""
    fi = fit_inputs or {}
    sizes, overhead, slots_by_alias = fi.get("sizes") or {}, fi.get("overhead") or {}, fi.get("slots_by_alias") or {}
    out: list[Deployment] = []
    seen: dict = {}
    for r in inv.routes:
        if node is not None and r.node != node:
            continue
        n = inv.node(r.node)
        ep = n.endpoint(r.endpoint) if n else None
        engine = ep.engine if ep else ""
        meta = nm.ENGINES.get(engine, {})
        ref = EndpointRef(r.endpoint, engine, meta.get("name", engine or "unknown engine"),
                          ep.port if ep else 0, ep.url if ep else "")
        slots = slots_by_alias.get(r.alias)
        tunings, more = _tunings(r, engine, slots)
        need = _need(tunings, slots)
        entry = lc.by_model(r.model) if lc is not None else None
        rev = entry.source.revision if entry else ""
        cand = r.alias.endswith(nm.NEXT)
        d = Deployment(r.alias, r.node, n.name if n else r.node, ref, r.model, r.kind, _short(rev), rev,
                       "eval" if cand else "production", cand, tunings, more,
                       planned_at=f"{short_count(need.context_tokens)} x {need.slots} slot{'s' if need.slots != 1 else ''}",
                       on_demand=bool(ep) and nm.loading(engine) == "on-demand")
        key = (r.node, r.endpoint, r.model)
        if key in seen:
            d.planned_gib, d.shares_with, d.provenance = 0.0, seen[key], "exact"
            d.bar_note = f"the same model on the same endpoint as {seen[key]}: one copy in memory"
        else:
            seen[key] = r.alias
            fp = fx.footprint(sizes.get(r.model), r.size_gib, need,
                              (overhead.get(r.node) or {}).get(engine, fx.ENGINE_OVERHEAD_FRACTION), note_measured_miss=False)
            d.provenance = fp.provenance
            if fp.total_gib is None:
                d.size_unknown, d.bar_note = True, "size unknown: not in the bar"
            else:
                d.planned_gib, d.in_bar = fp.total_gib, True
        out.append(d)
    # fit counts every resident model, and only the largest on-demand one (the worst moment)
    for nid in {d.node for d in out}:
        od = [d for d in out if d.node == nid and d.on_demand and d.in_bar]
        if len(od) > 1:
            big = max(od, key=lambda d: d.planned_gib)
            for d in od:
                if d is not big:
                    d.in_bar, d.bar_note = False, "on demand: the node holds one at a time, so only the largest counts"
    return out


@dataclass
class Segment:
    alias: str
    gib: float
    kind: str                       # pinned | candidate
    pct: float                      # width, of the bar's scale
    x: float = 0.0                  # start, of the bar's scale


@dataclass
class MemoryBar:
    total_gib: float | None         # the node's memory
    usable: fx.Usable
    segments: list = field(default_factory=list)
    pinned_gib: float = 0.0
    candidate_gib: float = 0.0
    planned_gib: float = 0.0
    free_gib: float | None = None
    usable_pct: float | None = None         # position of the usable line, of the bar's scale
    planned_pct: float = 0.0                # where the segments end, of the bar's scale
    scale_gib: float = 0.0
    over_usable: bool = False
    over_total: bool = False
    left_out: list = field(default_factory=list)    # [(alias, reason)]

    @property
    def drawn(self) -> bool:
        return bool(self.total_gib) and bool(self.segments or self.free_gib is not None)


def memory_bar(node: nm.Node, deps: list, usable: fx.Usable | None = None) -> MemoryBar:
    """The node's memory against what is planned on it. Pinned (live) and candidate (-next) deployments are separate
    segments; free is what is left of the node's memory; the usable line is the node's usable figure."""
    usable = usable or fx.usable_for(node)
    total = node.memory_gib()
    bar = MemoryBar(total, usable)
    mine = [d for d in deps if d.node == node.id]
    bar.left_out = [(d.alias, d.bar_note) for d in mine if not d.in_bar and d.bar_note and not d.shares_with]
    live = [d for d in mine if d.in_bar and d.planned_gib]
    bar.pinned_gib = round(sum(d.planned_gib for d in live if not d.is_candidate), 1)
    bar.candidate_gib = round(sum(d.planned_gib for d in live if d.is_candidate), 1)
    bar.planned_gib = round(sum(d.planned_gib for d in live), 1)
    if not total:
        return bar
    scale = max(total, bar.planned_gib)
    bar.scale_gib = scale
    bar.free_gib = round(max(total - bar.planned_gib, 0.0), 1)
    bar.over_total = bar.planned_gib > total
    bar.over_usable = usable.gib is not None and bar.planned_gib > usable.gib
    bar.usable_pct = round(usable.gib / scale * 100, 2) if usable.gib is not None else None
    ordered = [d for d in live if not d.is_candidate] + [d for d in live if d.is_candidate]
    x = 0.0
    for d in ordered:
        pct = round(d.planned_gib / scale * 100, 2)
        bar.segments.append(Segment(d.alias, d.planned_gib, "candidate" if d.is_candidate else "pinned", pct, round(x, 2)))
        x += pct
    bar.planned_pct = round(min(x, 100.0), 2)
    return bar


def results_for(settings) -> list:
    """The capability-result/1 twins under modelLifecycle.resultsDir (the site's evals/results, mounted), or []."""
    raw = settings.raw or {}
    d = str(raw.get("resultsDir", "") or "")
    if not d:
        return []
    return rs.load_dir(d, "", prefix=str(raw.get("resultsRepoPath", "evals/results") or "evals/results"))[0]


def fit_inputs_for(settings, report=None, results=None) -> dict:
    """What fit v2 plans from, gathered as the Recommend page gathers it: the watcher's sizes joined to the catalog, each
    node's measured wired limit (newest capability-result/1 that recorded one) and the operator's figures from
    modelLifecycle.recommend.nodes. `settings` is Settings.lifecycle; `results` defaults to results_for(settings). A
    malformed recommend block is not fatal here: it is returned as a note and the defaults are used."""
    lc = settings.lifecycle
    notes: list[str] = []
    try:
        cfg = rc.parse_config((settings.raw or {}).get("recommend"))
    except ml.LifecycleError as e:
        cfg = None
        notes.append(f"modelLifecycle.recommend is not valid, so the operator's overhead and wired-limit figures are not used: {e}")
    nodes_cfg = cfg.nodes if cfg else {}
    return {"sizes": rc.sizes_by_model(lc, report),
            "overhead": {nid: (nc.get("overhead") or {}) for nid, nc in nodes_cfg.items()},
            "operator_usable": {nid: nc["wiredLimitGiB"] for nid, nc in nodes_cfg.items() if nc.get("wiredLimitGiB")},
            "results": results_for(settings) if results is None else list(results), "slots_by_alias": {}, "notes": notes}


def usable_for_node(node: nm.Node, fit_inputs: dict | None = None) -> fx.Usable:
    """The node's usable memory, as the Recommend page reads it: measured wired limit, else the operator's figure, else the
    node type's planning fraction."""
    fi = fit_inputs or {}
    facts = rc.facts_from_results(fi.get("results") or (), node.id)
    return fx.usable_for(node, facts.get("wired_limit_mib"), (fi.get("operator_usable") or {}).get(node.id))

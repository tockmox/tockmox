# SPDX-License-Identifier: Apache-2.0
"""Recommend for a node (REQ-0048 AC-48.14): per alias class, a shortlist of candidates a person may admit for
evaluation. A HYPOTHESIS GENERATOR and nothing more:

  * Tockmox does not pick your models; it proposes candidates and makes the evaluation and the change easy to review.
  * It never admits anything and writes nothing. Its output is a page and, on a button press, a change to commit
    (the same propose / propose_new / propose_replacement changes the rest of /models produces). REQ-0045 supplies the
    evidence a model is judged on; this module chooses nothing.
  * Every number carries its provenance (measured > exact > estimate), every predicted speed is labelled predicted,
    every public benchmark figure is a labelled hint.

Where candidates come from: catalog entries (not retired), the watcher's quant and successor candidates, and
operator-named seeds (modelLifecycle.recommend.seeds), each joined to the watcher's `sizes` record. There is no
open-ended discovery: a model nobody named is not on the list.

Ranking, within a class: licence-compliant before the rest, then fit (fits, tight, unknown, over), then predicted decode
tokens/s (bandwidth x eta / bytes read per token), then the smaller model. The class definitions, the licence policy, the
licence exceptions and the known-issue list are configuration with defaults; none of them is a judgement about quality.

Pure: no I/O. The route (models_routes.py) reads the report, the results directory and the node facts and passes them in.
"""
from __future__ import annotations

import copy
import re
from dataclasses import dataclass, field, replace

from . import fit as fx
from . import models as ml
from . import nodes as nm

# ---------------------------------------------------------------- policy defaults (all overridable in configuration)

# Class needs. context and slots follow the ladder in research C 3.6 (router and fast 8k, classify 16k, medium 32k, large
# 128k) and its memory-budget table (agent 4 x 64k). params is the TOTAL-parameter band, in billions, a model must fall in
# to be offered for the class: a hypothesis about size, not quality. A site redefines any class under
# modelLifecycle.recommend.classes.
DEFAULT_CLASSES = {
    "router":   {"kind": "chat", "context": 8192, "slots": 4, "params": [0, 5], "tools": False,
                 "about": "tiny, always resident, picks what handles a request"},
    "fast":     {"kind": "chat", "context": 8192, "slots": 4, "params": [3, 14], "tools": False,
                 "about": "low latency answers"},
    "classify": {"kind": "chat", "context": 16384, "slots": 4, "params": [3, 14], "tools": False,
                 "about": "closed-label output; wants constrained decoding or a decision model"},
    "agent":    {"kind": "chat", "context": 65536, "slots": 4, "params": [14, 70], "tools": True,
                 "about": "multi-step tool loops; decode speed matters"},
    "medium":   {"kind": "chat", "context": 32768, "slots": 3, "params": [14, 40], "tools": False,
                 "about": "the general interactive model"},
    "large":    {"kind": "chat", "context": 131072, "slots": 2, "params": [70, 1000], "tools": False,
                 "about": "the biggest generalist that fits beside the others"},
    "embed":    {"kind": "embedding", "context": 8192, "slots": 1, "params": [0, 100], "tools": False,
                 "about": "embeddings"},
    "rerank":   {"kind": "rerank", "context": 8192, "slots": 1, "params": [0, 100], "tools": False,
                 "about": "reranking"},
}
DEFAULT_LICENCE_ALLOW = ("apache-2.0", "mit")
DEFAULT_SHORTLIST = 4

# Known issues, as data. `match` keys (all that are present must hold): model (regex on the model id), quantBitsMax, moe,
# engine, format, classes. severity "warn" is shown as a warning, "hint" as a hypothesis not yet measured here.
DEFAULT_KNOWN_ISSUES = (
    {"id": "mlx-lm-4bit-moe-tool-calls", "severity": "warn",
     "match": {"moe": True, "quantBitsMax": 4, "engine": "mlx-lm", "classes": ["agent"]},
     "text": "4-bit mixture-of-experts models have drifted on tool calls under mlx-lm (community reports against mlx-lm; a hypothesis until measured here); "
             "prefer 6-bit or 8-bit for a tool-calling class, or measure first"},
)

# Which engines can serve which weights format (mlx-lm loads standard safetensors checkpoints as well as MLX conversions). A candidate with no known format is offered on any endpoint, and says so.
ENGINE_FORMATS = {
    "mlx-lm": {"mlx", "safetensors"}, "exo": {"mlx", "safetensors"}, "lm-studio": {"mlx", "gguf"}, "llama-server": {"gguf"}, "ollama": {"ollama"},
    "vllm": {"safetensors"}, "sglang": {"safetensors"}, "nim": {"safetensors"}, "tgi": {"safetensors"},
}

FIT_RANK = {"fits": 0, "tight": 1, "unknown": 2, "over": 3}


# ---------------------------------------------------------------- configuration

@dataclass
class ClassSpec:
    name: str
    kind: str
    context: int
    slots: int
    params: tuple
    tools: bool
    about: str = ""

    @property
    def need(self) -> fx.Need:
        return fx.Need(self.context, self.slots)


@dataclass
class Config:
    classes: dict
    licence_allow: tuple
    exceptions: dict               # model id or repo -> reason
    issues: list
    hints: list                    # [{match, text, source}]
    seeds: list                    # [{ref, revision, quant}]
    shortlist: int
    nodes: dict                    # node id -> {bandwidthGBps, wiredLimitGiB, overhead, eta}
    problems: list = field(default_factory=list)


def _num(v, what, lo, hi):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi:
        raise ml.LifecycleError(f"modelLifecycle.recommend.{what} must be a number from {lo} to {hi}")
    return v


def parse_config(raw) -> Config:
    """modelLifecycle.recommend, validated. Raises LifecycleError naming the key. Unknown keys are refused, so a typo
    in a licence exception cannot silently leave a model excluded or admitted."""
    raw = raw or {}
    if not isinstance(raw, dict):
        raise ml.LifecycleError("modelLifecycle.recommend must be a mapping")
    unknown = sorted(set(raw) - {"classes", "licenceAllow", "licenceExceptions", "knownIssues", "benchmarkHints", "seeds",
                                  "shortlistSize", "nodes"})
    if unknown:
        raise ml.LifecycleError(f"modelLifecycle.recommend: unknown key(s) {unknown}")
    classes = {}
    merged = {k: dict(v) for k, v in DEFAULT_CLASSES.items()}
    for k, v in (raw.get("classes") or {}).items():
        if not ml.CLASS_RE.match(str(k)):
            raise ml.LifecycleError(f"modelLifecycle.recommend.classes: {k!r} is not a class slug")
        if v is None:
            merged.pop(str(k), None)      # a null removes a default class
            continue
        if not isinstance(v, dict):
            raise ml.LifecycleError(f"modelLifecycle.recommend.classes.{k} must be a mapping (or null to remove it)")
        merged[str(k)] = {**merged.get(str(k), {"kind": "chat", "context": 8192, "slots": 1, "params": [0, 1000], "tools": False}), **v}
    for name, c in merged.items():
        kind = c.get("kind", "chat")
        if kind not in nm.KINDS:
            raise ml.LifecycleError(f"modelLifecycle.recommend.classes.{name}.kind must be one of {nm.KINDS}")
        pr = c.get("params", [0, 1000])
        if not (isinstance(pr, (list, tuple)) and len(pr) == 2):
            raise ml.LifecycleError(f"modelLifecycle.recommend.classes.{name}.params must be [min, max] billions")
        classes[name] = ClassSpec(name, kind, int(_num(c.get("context", 8192), f"classes.{name}.context", 256, 4_000_000)),
                                  int(_num(c.get("slots", 1), f"classes.{name}.slots", 1, 256)),
                                  (_num(pr[0], f"classes.{name}.params", 0, 1e5), _num(pr[1], f"classes.{name}.params", 0, 1e5)),
                                  bool(c.get("tools", False)), str(c.get("about", "")))
    allow = raw.get("licenceAllow", list(DEFAULT_LICENCE_ALLOW))
    if not isinstance(allow, list) or not all(isinstance(x, str) and x for x in allow):
        raise ml.LifecycleError("modelLifecycle.recommend.licenceAllow must be a list of licence ids (for example apache-2.0)")
    exc = {}
    for x in raw.get("licenceExceptions") or []:
        if not (isinstance(x, dict) and isinstance(x.get("model"), str) and x["model"] and isinstance(x.get("reason"), str) and x["reason"].strip()):
            raise ml.LifecycleError("modelLifecycle.recommend.licenceExceptions entries need a model and a reason: an exception is a decision on record")
        exc[x["model"]] = x["reason"].strip()[:300]
    issues = [dict(i) for i in (raw["knownIssues"] if "knownIssues" in raw else DEFAULT_KNOWN_ISSUES)]
    for i in issues:
        if not (isinstance(i, dict) and isinstance(i.get("text"), str) and isinstance(i.get("match", {}), dict)
                and i.get("severity", "warn") in ("warn", "hint")):
            raise ml.LifecycleError("modelLifecycle.recommend.knownIssues entries need text, a match map and severity warn or hint")
        if i.get("match", {}).get("model"):
            try:
                re.compile(i["match"]["model"])
            except re.error as e:
                raise ml.LifecycleError(f"modelLifecycle.recommend.knownIssues: bad model pattern ({e})") from None
    hints = [dict(h) for h in raw.get("benchmarkHints") or []]
    for h in hints:
        if not (isinstance(h, dict) and isinstance(h.get("match"), str) and isinstance(h.get("text"), str)):
            raise ml.LifecycleError("modelLifecycle.recommend.benchmarkHints entries need match (a regex) and text")
        try:
            re.compile(h["match"])
        except re.error as e:
            raise ml.LifecycleError(f"modelLifecycle.recommend.benchmarkHints: bad pattern ({e})") from None
    seeds = []
    for sd in raw.get("seeds") or []:
        if not (isinstance(sd, dict) and ml.HF_REPO.match(str(sd.get("ref", "")))):
            raise ml.LifecycleError("modelLifecycle.recommend.seeds entries need ref: a Hugging Face repo id")
        rev = str(sd.get("revision", "") or "")
        if rev and not re.match(r"^[0-9a-f]{40}$", rev):
            raise ml.LifecycleError(f"modelLifecycle.recommend.seeds: {sd['ref']} revision must be a 40-character commit")
        seeds.append({"ref": sd["ref"], "revision": rev, "quant": str(sd.get("quant", "") or "")})
    size = int(_num(raw.get("shortlistSize", DEFAULT_SHORTLIST), "shortlistSize", 1, 10))
    nodes = {}
    for nid, nv in (raw.get("nodes") or {}).items():
        if not isinstance(nv, dict):
            raise ml.LifecycleError(f"modelLifecycle.recommend.nodes.{nid} must be a mapping")
        nodes[str(nid)] = {k: nv[k] for k in ("bandwidthGBps", "wiredLimitGiB", "overhead", "eta") if k in nv}
    return Config(classes, tuple(x.lower() for x in allow), exc, issues, hints, seeds, size, nodes)


# ---------------------------------------------------------------- the model, as the recommender sees it

@dataclass
class Option:
    model: str                      # the id a route would call
    source: ml.Source
    origin: str                     # catalog | watcher | seed
    entry: ml.Entry | None = None
    record: fx.SizeRecord | None = None
    detail: str = ""


@dataclass
class Flag:
    kind: str                       # licence | issue | hint | note
    severity: str                   # warn | hint | info
    text: str


def speed_range(tps: float | None) -> tuple[int, int] | None:
    """A predicted decode speed as a whole-number range, never a decimal (TM-1274): the prediction is bandwidth over
    bytes read, good to perhaps a tenth either way, and one decimal place says otherwise. Plus or minus 12%, widened
    outward to a step of 10 tokens/s from 100, 5 from 20, else 1. 125 reads as 110 to 140."""
    if tps is None or tps <= 0:
        return None
    step = 10 if tps >= 100 else 5 if tps >= 20 else 1
    lo = max(1, int(tps * 0.88 // step) * step)
    hi = max(lo + step, -int(-(tps * 1.12) // step) * step)
    return lo, hi


def measured_decode(results, node_id: str, model: str):
    """(tokens/s, date) from the newest perf twin for this model on this node that carries a single-stream decode
    figure, else None. A measurement replaces the prediction on the page."""
    best = None
    for r in results or ():
        if r.kind != "perf" or r.node != node_id or r.model != model:
            continue
        ms = [m for m in r.metrics if m.name in ("decode_tps_p50", "decode_tps_stream_p50") and m.value > 0]
        if not ms:
            continue
        m = min(ms, key=lambda x: x.concurrency or 1)
        if best is None or (r.date, r.path) > (best[1], best[2]):
            best = (m.value, r.date, r.path)
    return (best[0], best[1]) if best else None


@dataclass
class Row:
    option: Option
    alias: str                      # the alias the change would be for
    action: str                     # new | compare | replace | incumbent | none
    fit: fx.FitV2
    tps: float | None
    tps_how: str
    flags: list
    hints: list
    endpoints: list                 # [(endpoint id, engine)] on the node that can serve it
    admissible: bool
    why_not: str
    in_service: str = ""            # where the model serves the class alias now, when it does
    tps_range: tuple | None = None  # (low, high) whole tokens/s: how a predicted speed is shown (TM-1274)
    tps_measured: tuple | None = None   # (tokens/s, date) once a perf twin has measured it: replaces the range


@dataclass
class ClassResult:
    spec: ClassSpec
    live_alias: str                 # the live alias the class maps to, "" when none
    live_model: str
    rows: list
    considered: int
    excluded: int


@dataclass
class Recommendation:
    node: nm.Node
    usable: fx.Usable
    bandwidth_gbps: float | None
    bandwidth_from: str
    classes: list
    stack_gib: float | None
    stack_state: str
    stack_line: str
    constants: dict
    notes: list


def _fmt(opt: Option) -> str:
    if opt.source.kind == "ollama":
        return "ollama"
    if opt.record and opt.record.format:
        return opt.record.format
    name = f"{opt.source.ref} {opt.model}".lower()          # the repo name is the only hint when the card was not read
    for tag, fmt in (("gguf", "gguf"), ("mlx", "mlx")):
        if tag in name:
            return fmt
    return ""


def _bits(opt: Option) -> int | None:
    text = f"{opt.entry.quant if opt.entry else ''} {opt.model}".lower()
    if re.search(r"(mxfp4|nvfp4|q4|4bit|int4|awq|gptq)", text):
        return 4
    for pat, b in ((r"(q8|8bit|fp8|int8)", 8), (r"(q6|6bit)", 6), (r"(q5|5bit)", 5), (r"(q3|3bit)", 3), (r"(bf16|fp16|f16)", 16)):
        if re.search(pat, text):
            return b
    return None


def _lic(rec: fx.SizeRecord | None) -> str:
    return (rec.license if rec else "").lower().strip()


def licence_state(opt: Option, cfg: Config) -> tuple[str, str]:
    """('allowed' | 'exception' | 'outside' | 'unknown', text). Exceptions are matched on the model id or the repo; they are
    a site decision with a reason on record, never a default."""
    for key in (opt.model, opt.source.ref):
        if key in cfg.exceptions:
            return "exception", f"outside the licence allow list ({_lic(opt.record) or 'unknown'}), admitted by a site exception: {cfg.exceptions[key]}"
    lic = _lic(opt.record)
    if not lic:
        return "unknown", "licence unknown (the watcher has not read this model's card): not on the allow list until it is"
    if lic in cfg.licence_allow:
        return "allowed", f"licence {lic}"
    return "outside", (f"licence {lic} is not on this site's allow list ({', '.join(cfg.licence_allow)}); "
                       "to admit it deliberately, add a modelLifecycle.recommend.licenceExceptions entry with the reason")


def _issues(opt: Option, spec: ClassSpec, engine: str, cfg: Config) -> list:
    out = []
    for i in cfg.issues:
        m = i.get("match", {})
        if m.get("classes") and spec.name not in m["classes"]:
            continue
        if m.get("model") and not re.search(m["model"], opt.model):
            continue
        if "moe" in m and bool(opt.record and opt.record.moe) != bool(m["moe"]):
            continue
        if m.get("engine") and m["engine"] != engine:
            continue
        if m.get("format") and m["format"] != _fmt(opt):
            continue
        if m.get("quantBitsMax") is not None:
            b = _bits(opt)
            if b is None or b > m["quantBitsMax"]:
                continue
        out.append(Flag("issue", i.get("severity", "warn"), i["text"]))
    return out


def sizes_by_model(lc: ml.Lifecycle, report) -> dict:
    """{model id: SizeRecord} for catalog entries whose repo the watcher sized."""
    sizes = (report.sizes if report else {}) or {}
    return {e.model: sizes[e.source.ref] for e in lc.catalog if e.source.kind == "huggingface" and e.source.ref in sizes}


def pool(lc: ml.Lifecycle, report, cfg: Config) -> list:
    """Every model the recommender may offer, once each. Catalog entries first (they are the ones the site already
    knows), then the watcher's quant and successor candidates, then seeds."""
    sizes = (report.sizes if report else {}) or {}
    out, seen = [], set()

    def add(opt):
        if opt.model not in seen:
            seen.add(opt.model)
            out.append(opt)

    for e in lc.catalog:
        if e.stage not in ("retired", "rejected") and e.source.kind != "hosted":
            add(Option(e.model, e.source, "catalog", e, sizes.get(e.source.ref) if e.source.kind == "huggingface" else None))
    for c in (report.candidates if report else []):
        if c.kind in ("quant", "successor") and c.source.kind == "huggingface":
            rec = sizes.get(c.source.ref)
            src = ml.Source("huggingface", c.source.ref, c.source.revision or (rec.revision if rec else ""))
            add(Option(c.model, src, "watcher", None, rec, c.detail))
    for sd in cfg.seeds:
        rec = sizes.get(sd["ref"])
        add(Option(sd["ref"], ml.Source("huggingface", sd["ref"], sd["revision"] or (rec.revision if rec else "")), "seed", None, rec,
                   "named by the site"))
    return out


def _kind_of(opt: Option) -> str:
    name = opt.model.lower()
    tag = (opt.record.pipeline_tag if opt.record else "").lower()
    if "rerank" in name or tag == "text-ranking":
        return "rerank"
    if "embed" in name or tag in ("feature-extraction", "sentence-similarity"):
        return "embedding"
    return "chat"


def _params_b(opt: Option) -> float | None:
    if opt.record and opt.record.params_b:
        return opt.record.params_b
    return fx.params_from_name(opt.model)[0]


def live_alias_for(inv: nm.Inventory, cls: str):
    """The live (non -next) route a class maps to: the alias is the class name or ends with -<class>."""
    for r in inv.routes:
        if not r.alias.endswith(nm.NEXT) and (r.alias == cls or r.alias.endswith("-" + cls)):
            return r
    return None


def decide(alias: str, opt: Option, node_id: str, lc: ml.Lifecycle, inv: nm.Inventory):
    """(action, reason-it-cannot-be-done) for putting `opt` on `node_id` as `alias`."""
    if not nm.ALIAS_RE.match(alias or "") or alias.endswith(nm.NEXT):
        return "none", f"{alias!r} is not an alias"
    if alias + nm.NEXT in inv.aliases():
        return "none", f"{alias}{nm.NEXT} is already a comparison in progress: promote or remove it first"
    live = next((r for r in inv.routes if r.alias == alias), None)
    if live is None:
        return "new", ""
    if live.model == opt.model:
        return ("incumbent", "") if live.node == node_id else ("replace", "")
    if lc.by_model(live.model) is None:
        return "none", f"{alias} serves {live.model}, which is not in the catalog: catalogue it first"
    return "compare", ""


def _compatible(node: nm.Node, opt: Option, kind: str) -> list:
    fmt = _fmt(opt)
    out = []
    for ep in node.endpoints:
        try:
            nm.provider_for(ep.engine, kind)
        except ml.NodeError:
            continue
        ok = ENGINE_FORMATS.get(ep.engine)
        if ok is None or not fmt or fmt in ok:
            out.append((ep.id, ep.engine))
    return out


def facts_from_results(results, node_id: str) -> dict:
    """{"wired_limit_mib", "wired_limit_from"} from the newest capability-result/1 for this node that recorded
    environment.wired_limit_mb (sysctl iogpu.wired_limit_mb, MiB). A measurement taken when the result was written, so it is
    labelled with its date; the live figure (node_facts) wins when the caller has one."""
    best = None
    for r in results or ():
        try:
            v = float(r.environment.get("wired_limit_mb", 0) or 0)
        except (TypeError, ValueError):
            continue
        if r.node == node_id and v > 0 and (best is None or (r.date, r.path) > (best[0].date, best[0].path)):
            best = (r, v)
    return {"wired_limit_mib": best[1], "wired_limit_from": f"{best[0].path or 'a result'} ({best[0].date})"} if best else {}


def recommend(node_id: str, lc: ml.Lifecycle, inv: nm.Inventory, report, cfg: Config, results=(), facts: dict | None = None) -> Recommendation:
    """The Recommend page's content for one node. `facts` is {"wired_limit_mib": ...} from the node's metrics when known;
    results are capability-result/1 rows (measured peaks)."""
    from . import results as rs
    node = inv.node(node_id)
    if node is None:
        raise ml.LifecycleError(f"no node {node_id!r}")
    nc = cfg.nodes.get(node_id, {})
    facts = facts or {}
    if not facts.get("wired_limit_mib"):
        facts = {**facts, **facts_from_results(results, node_id)}
    usable = fx.usable_for(node, facts.get("wired_limit_mib"), nc.get("wiredLimitGiB"))
    if facts.get("wired_limit_from") and usable.provenance == "measured":
        usable = replace(usable, line=usable.line[:-1] + f"; read from {facts['wired_limit_from']})")
    chip = str((node.hardware.get("chip").value if node.hardware.get("chip") else "") or "")
    bw, bw_from = fx.bandwidth_for(chip, nc.get("bandwidthGBps"))
    overhead = nc.get("overhead") or {}
    by_model = sizes_by_model(lc, report)
    options = pool(lc, report, cfg)
    notes = []
    classes, tops = [], []
    for spec in cfg.classes.values():
        live = live_alias_for(inv, spec.name)
        alias_default = live.alias if live else f"local-{spec.name}"
        # what is already on this node, apart from this class's own routes: the memory this model lands beside
        beside = 0.0
        for r in inv.routes_on(node_id):
            if r.alias in (alias_default, alias_default + nm.NEXT):
                continue
            ep = node.endpoint(r.endpoint)
            fp = fx.footprint(by_model.get(r.model), r.size_gib, fx.route_need(r), overhead.get(ep.engine if ep else "", fx.ENGINE_OVERHEAD_FRACTION),
                              note_measured_miss=False)
            beside += fp.total_gib or 0.0
        rows, excluded = [], 0
        for opt in options:
            kind = _kind_of(opt)
            in_service = live is not None and live.model == opt.model
            if kind != spec.kind:
                excluded += 1
                continue
            pb = _params_b(opt)
            if not in_service and spec.kind == "chat" and (pb is None or not spec.params[0] <= pb <= spec.params[1]):
                excluded += 1
                continue
            eps = _compatible(node, opt, spec.kind)
            engine = eps[0][1] if eps else ""
            est = opt.entry.size_gib if opt.entry and opt.entry.size_gib else nm.estimate_size_gib(opt.model)
            meas = fx.measured_from(rs.newest(results, node_id, opt.model, engine)) if results else None
            fp = fx.footprint(opt.record, est, spec.need, overhead.get(engine, fx.ENGINE_OVERHEAD_FRACTION), meas)
            fit = fx.judge(fp, usable, beside)
            tps, how = (None, "not a generation model") if spec.kind != "chat" else fx.predict_decode_tps(bw, opt.record, est, nc.get("eta"))
            lic, lic_text = licence_state(opt, cfg)
            flags = [Flag("licence", "info" if lic in ("allowed", "exception") else "warn", lic_text)]
            if lic == "exception":
                flags[0].severity = "warn"
            if opt.record and opt.record.gated:
                flags.append(Flag("note", "info", "the repo is gated: the node needs a token that has accepted its terms to pull it"))
            if opt.record and opt.record.moe:
                flags.append(Flag("note", "info", "mixture of experts: every expert stays resident, so memory follows total parameters while speed follows active ones"))
            if opt.record and opt.record.full_attention_layers is not None and opt.record.total_layers \
                    and opt.record.full_attention_layers < opt.record.total_layers:
                flags.append(Flag("note", "info", f"hybrid attention: {opt.record.full_attention_layers} of {opt.record.total_layers} layers grow a cache with context"))
            if not fp.kv_known and fp.provenance != "measured":
                flags.append(Flag("note", "warn", "the cache size is unknown (no config.json read), so this fit leaves headroom instead of counting it"))
            if eps and len(eps) and not _fmt(opt):
                flags.append(Flag("note", "info", "the weights format is unknown, so every endpoint is offered: check the engine can load it"))
            flags += _issues(opt, spec, engine, cfg)
            hints = [f"{h['text']}" + (f" ({h['source']})" if h.get("source") else "") for h in cfg.hints if re.search(h["match"], opt.model)]
            if opt.record and opt.record.eval_results:
                hints.append("self-reported on the model card: " + "; ".join(
                    f"{x['name'] or 'metric'} {x['value']}" + (f" on {x['dataset']}" if x['dataset'] else "") for x in opt.record.eval_results[:4]))
            alias = alias_default
            action, why = decide(alias, opt, node_id, lc, inv)
            adm, why_not = action in ("new", "compare", "replace"), why
            if adm and action != "replace" and lic in ("outside", "unknown"):          # moving a model already in service admits nothing new
                adm, why_not = False, lic_text
            if adm and action != "replace":
                why_pin = ml._pinned(opt.source)
                if why_pin:
                    adm, why_not = False, why_pin
            if adm and action == "replace":
                e = lc.by_model(opt.model)
                if e is None or e.stage != "promoted":
                    adm, why_not = False, f"{opt.model} is not a promoted catalog entry"
                elif ml._pinned(e.source):
                    adm, why_not = False, ml._pinned(e.source)
            if adm and not eps:
                adm, why_not = False, f"no endpoint on {node.name} can serve a {_fmt(opt) or 'this'} model through the gateway"
            if adm and fit.state == "over":
                adm, why_not = False, "it does not fit on this node at the class's context and slots"
            if action == "incumbent":
                why_not = f"already serves {alias} on {node.name}"
            rows.append(Row(opt, alias, action, fit, tps, how, flags, hints, eps, adm, why_not,
                            f"{live.node}" if in_service else "", speed_range(tps),
                            measured_decode(results, node_id, opt.model) if spec.kind == "chat" else None))
        rows.sort(key=lambda r: (0 if licence_state(r.option, cfg)[0] in ("allowed", "exception") else 1, FIT_RANK[r.fit.state],
                                 -(r.tps if r.tps is not None else -1.0), r.fit.footprint.weights_gib or 1e9))
        classes.append(ClassResult(spec, live.alias if live else "", live.model if live else "", rows[:cfg.shortlist], len(rows) + excluded, excluded))
        top = next((r for r in rows if r.admissible or r.action == "incumbent"), None)
        if top and top.fit.footprint.total_gib:
            tops.append((spec.name, top.fit.footprint.total_gib))
    stack = round(sum(g for _, g in tops), 1) if tops else None
    if stack is None or usable.gib is None:
        state, line = "unknown", "no sizes to add up"
    else:
        state = "over" if stack > usable.gib else ("tight" if stack > fx.FITS_FRACTION * usable.gib else "fits")
        line = (f"the first choice of each class is {stack:.1f} GiB together ({', '.join(f'{n} {g:.1f}' for n, g in tops)}) "
                f"against {usable.gib:.1f} GiB usable: {state}. Each row above is judged beside what is routed on the node today, not beside the "
                "other classes' picks; this line is that sum.")
    if report is None or not report.sizes:
        notes.append("the watcher's report has no sizes section (the watcher is off, or has not run since sizes were added): every figure below is an estimate from the model name")
    return Recommendation(node, usable, bw, bw_from, classes, stack, state, line,
                          {"engine_overhead_fraction": fx.ENGINE_OVERHEAD_FRACTION, "eta_dense": fx.ETA_DENSE, "eta_moe": fx.ETA_MOE,
                           "kv_dtype_bytes": fx.KV_DTYPE_BYTES, "fits_fraction": fx.FITS_FRACTION}, notes)


# ---------------------------------------------------------------- the change a button generates

def build_change(action: str, alias: str, opt: Option, node_id: str, endpoint: str, spec: ClassSpec, lc: ml.Lifecycle,
                 inv: nm.Inventory, taken=()):
    """(add_lifecycle, add_inventory, notes) for 'Admit for evaluation': propose_new, propose or propose_replacement, then
    the route's context limit set for the class on the target engine. Nothing is written; the caller renders the change."""
    n = inv.node(node_id)
    ep = n.endpoint(endpoint) if n else None
    if ep is None:
        raise ml.LifecycleError(f"no endpoint {node_id}/{endpoint}")
    size = (opt.record.weights_gib if opt.record and opt.record.weights_gib else None) or (opt.entry.size_gib if opt.entry else None)
    if action == "replace":
        add_lc, add_inv, notes = ml.propose_replacement(alias, node_id, endpoint, lc, inv, taken, spec.context)
    elif action == "new":
        add_lc, add_inv, notes = ml.propose_new(
            alias, opt.model, opt.source, node_id, endpoint, spec.kind, lc, inv, taken, size_gib=size, context_tokens=spec.context,
            base_model=opt.entry.base_model if opt.entry else "", quant=opt.entry.quant if opt.entry else "")
    elif action == "compare":
        why = ml._pinned(opt.source)
        if why:
            raise ml.LifecycleError(why)
        live = next(r for r in inv.routes if r.alias == alias)
        base = lc.by_model(live.model)
        cand = ml.Candidate(f"recommend:{opt.model}", "successor", base.id, opt.model, opt.source,
                            f"recommended for {alias} on {n.name}", "", size, "")
        add_lc, add_inv, notes = ml.propose(cand, lc, inv, node_id, endpoint, taken, alias)
        if lc.by_model(opt.model) is not None:
            add_lc = ml.Lifecycle([])                              # already catalogued: only the route is new
            notes = notes + [f"{opt.model} is already in the catalog; only the route is added"]
        for r in add_inv.routes:                                   # propose() copies the incumbent's params: re-pin for this engine
            r.params = {k: v for k, v in r.params.items() if k != "num_ctx"}
            r.model_info = {k: v for k, v in r.model_info.items() if k != "max_input_tokens"}
            p, info = ml._route_limits(ep.engine, r.params, spec.context)
            r.params, r.model_info = p, {**r.model_info, **info}
            r.provider = ""
        notes = notes + [f"{opt.model} is compared against {live.model} on {alias}; the verdict decides, not this page"]
    else:
        raise ml.LifecycleError(f"nothing to admit ({action})")
    return add_lc, add_inv, notes


def find_option(lc, report, cfg, model: str) -> Option | None:
    return next((o for o in pool(lc, report, cfg) if o.model == model), None)

# SPDX-License-Identifier: Apache-2.0
"""Fit v2 (REQ-0048 AC-48.14, REQ-0047 AC-47.5): will this model, at this context and concurrency, fit this node.

Fit v1 (nodes.fit) plans from the model's NAME: parameters x bits / 8 x 1.1, weights only, against a flat fraction
of memory. It cannot see the KV cache, a hybrid or sliding-window model, a context pin or the node's real wired
limit. This module plans from numbers, says where each one came from, and shows its arithmetic:

  provenance, best first     measured  a capability-result/1 twin recorded the peak resident memory (results.py), and
                                       the plan asks for no more context x slots than was tested
                             exact     the watcher read the file sizes and config.json at the pinned revision
                                       (watcher.py `sizes`): weights bytes, KV bytes per token, fixed per-sequence state
                             estimate  the name regex of fit v1 (nodes.estimate_size_gib)

  weights                    sizeBytes (exact) | measured peak | estimate
  KV                         per sequence: kvBytesPerToken x context + recurrent state + sliding-window cap; x slots
  engine overhead            ENGINE_OVERHEAD_FRACTION of weights + KV (activation and compile buffers), unless a
                             calibrated figure for the node and engine is passed in (evals/fit/<node>.json)
  usable memory              the node's measured wired limit | an operator-set figure | the node type's planning fraction

States: fits (total <= 85% of usable), tight (<= 100%), over, unknown (no size or no memory figure). When the KV size
is not known (no config.json read), "fits" needs <= 70%: 15 points of headroom stand in for the cache nobody sized.

Decode speed is a PRIOR, not a measurement: bandwidth x eta / bytes read per token (research C 1.4). Predicted rows
are labelled predicted wherever they appear.

Pure, and it imports only nodes.py and results.py: models.py imports it to parse the watcher's report.
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field

from . import nodes as nm

GIB = 1 << 30
KIB = 1 << 10

KV_DTYPE_BYTES = 2                 # f16/bf16 cache. A quantised cache (llama-server -ctk q8_0, mlx --kv-bits) is smaller:
                                   # the plan is then conservative, never optimistic.
RECURRENT_DTYPE_BYTES = 4          # fp32 recurrent state (Gated DeltaNet, Mamba2)
ENGINE_OVERHEAD_FRACTION = 0.10    # of weights + KV: activation, compile and allocator buffers. Research C 3.6 [E];
                                   # calibrated per node and engine from evals/fit/<node>.json once measured.
FITS_FRACTION = 0.85               # same threshold as fit v1: above it, "tight"
FITS_FRACTION_KV_UNKNOWN = 0.70    # when the KV cache was not sized
ETA_DENSE = 0.70                   # achieved fraction of memory bandwidth, dense decode: midpoint of research C 1.4's 0.65 to 0.78
ETA_MOE = 0.35                     # MoE decode (expert routing, small matmuls): midpoint of 0.25 to 0.47

PROVENANCE_ORDER = ("measured", "exact", "estimate", "unknown")

# Published peak memory bandwidth, GB/s, by chip name (substring, lower case). Preset figures, never measured here:
# an operator with a measured or different figure sets modelLifecycle.recommend.nodes.<id>.bandwidthGBps.
CHIP_BANDWIDTH_GBPS = (
    ("m5 ultra", 1228.0), ("m5 max", 614.0), ("m5 pro", 307.0), ("m5", 153.0),
    ("m4 max", 546.0), ("m4 pro", 273.0), ("m4", 120.0),
    ("m3 ultra", 819.0), ("m3 max", 400.0), ("m3 pro", 150.0),
    ("gb10", 273.0), ("rtx pro 6000", 1792.0), ("rtx 5090", 1792.0), ("rtx 4090", 1008.0),
    ("ryzen ai max", 256.0),
)


def worst(*provs: str) -> str:
    return max(provs, key=lambda p: PROVENANCE_ORDER.index(p) if p in PROVENANCE_ORDER else len(PROVENANCE_ORDER))


# ---------------------------------------------------------------- KV and state from config.json

def _int(v):
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v > 0 else None


def _layer_kinds(c: dict, n: int, notes: list) -> list | None:
    """Per layer: 'full' (cache grows with context), 'sliding' (capped at a window), 'recurrent' (fixed state),
    'none' (no cache). From layer_types, a hybrid pattern string, an interval key, or all-full."""
    lt = c.get("layer_types")
    if isinstance(lt, list) and len(lt) == n and all(isinstance(x, str) for x in lt):
        out = []
        for x in lt:
            x = x.lower()
            if "full" in x or x in ("attention", "global", "global_attention"):
                out.append("full")
            elif "slid" in x or "local" in x or "chunk" in x:
                out.append("sliding")
            elif any(k in x for k in ("linear", "mamba", "recurrent", "ssm", "delta", "conv")):
                out.append("recurrent")
            else:
                out.append("full")
                notes.append(f"layer type {x!r} not recognised: counted as full attention")
        return out
    pat = c.get("hybrid_override_pattern")
    if isinstance(pat, str) and len(pat) == n:
        return ["full" if ch == "*" else "recurrent" if ch.upper() == "M" else "none" for ch in pat]
    k = _int(c.get("full_attention_interval"))
    if k:
        return ["full" if (i + 1) % k == 0 else "recurrent" for i in range(n)]
    sw = _int(c.get("sliding_window"))
    every = _int(c.get("sliding_window_pattern")) or _int(c.get("global_attn_every_n_layers"))
    if sw and every:
        return ["full" if (i + 1) % every == 0 else "sliding" for i in range(n)]
    return ["full"] * n


def kv_from_config(cfg: dict) -> dict:
    """Cache sizes from a Hugging Face config.json, as plain numbers plus notes on every assumption.

      kv_bytes_per_token       2 x full-attention layers x kv heads x head_dim x KV_DTYPE_BYTES  (MLA: layers x
                               (kv_lora_rank + qk_rope_head_dim) x bytes). Only layers whose cache GROWS with context.
      full_attention_layers    how many layers that is
      recurrent_state_bytes    fixed per sequence: Gated-DeltaNet / Mamba2 layers (None when the keys are missing)
      sliding_window_bytes     fixed per sequence once the window is full; sliding_window_tokens is the window

    Returns {} (with a note) when the layer count or head sizes cannot be read: the caller then has no KV figure and
    says so, rather than inventing one."""
    notes: list = []
    c = cfg if isinstance(cfg, dict) else {}
    if "num_hidden_layers" not in c and isinstance(c.get("text_config"), dict):
        c = c["text_config"]
        notes.append("read from text_config")
    n = _int(c.get("num_hidden_layers") or c.get("n_layer") or c.get("num_layers"))
    if not n:
        return {"notes": ["config.json has no layer count"]}
    heads = _int(c.get("num_attention_heads") or c.get("n_head"))
    kvh = c.get("num_key_value_heads", c.get("num_attention_heads"))
    hd = _int(c.get("head_dim")) or (_int(c.get("hidden_size")) // heads if heads and _int(c.get("hidden_size")) else None)
    kinds = _layer_kinds(c, n, notes)
    full = [i for i, k in enumerate(kinds) if k == "full"]
    sliding = [i for i, k in enumerate(kinds) if k == "sliding"]
    rec = [i for i, k in enumerate(kinds) if k == "recurrent"]
    mla = _int(c.get("kv_lora_rank"))
    out = {"total_layers": n, "full_attention_layers": len(full), "notes": notes}

    def per_layer(i):          # K and V bytes for one token in layer i
        if mla:
            return (mla + (_int(c.get("qk_rope_head_dim")) or 0)) * KV_DTYPE_BYTES
        h = kvh[i] if isinstance(kvh, list) and len(kvh) == n else kvh
        h = _int(h)
        return 2 * h * hd * KV_DTYPE_BYTES if h and hd else None

    sample = per_layer(0)
    if mla:
        notes.append("multi-head latent attention: cache is kv_lora_rank + qk_rope_head_dim per layer")
    if sample is None and (full or sliding):
        notes.append("kv heads or head size unreadable: no KV figure")
        out.update(kv_bytes_per_token=None)
    else:
        out["kv_bytes_per_token"] = sum(per_layer(i) for i in full) if full else 0
        if sliding:
            window = _int(c.get("sliding_window")) or _int(c.get("attention_window_size"))
            if window:
                out["sliding_window_bytes"] = sum(per_layer(i) for i in sliding) * window
                out["sliding_window_tokens"] = window
            else:
                notes.append("sliding layers with no window size: their cache is not counted")
    if rec:
        nv, nk = _int(c.get("linear_num_value_heads")), _int(c.get("linear_num_key_heads"))
        dk, dv = _int(c.get("linear_key_head_dim")), _int(c.get("linear_value_head_dim"))
        kc = _int(c.get("linear_conv_kernel_dim")) or 4
        mh, mhd, ms = _int(c.get("mamba_num_heads")), _int(c.get("mamba_head_dim")), _int(c.get("ssm_state_size"))
        if nv and nk and dk and dv:
            per = nv * dk * dv * RECURRENT_DTYPE_BYTES + (2 * nk * dk + nv * dv) * (kc - 1) * RECURRENT_DTYPE_BYTES
            out["recurrent_state_bytes"] = per * len(rec)
            notes.append(f"recurrent state: {len(rec)} linear-attention layers, fp32 state computed from config")
        elif mh and mhd and ms:
            g = _int(c.get("n_groups")) or 1
            ck = _int(c.get("conv_kernel")) or 4
            per = mh * mhd * ms * RECURRENT_DTYPE_BYTES + (mh * mhd + 2 * g * ms) * (ck - 1) * RECURRENT_DTYPE_BYTES
            out["recurrent_state_bytes"] = per * len(rec)
            notes.append(f"recurrent state: {len(rec)} Mamba2 layers, fp32 state computed from config")
        else:
            out["recurrent_state_bytes"] = None
            notes.append(f"{len(rec)} recurrent layers whose state size the config does not give: their fixed state is not counted")
    experts = _int(c.get("num_experts") or c.get("num_local_experts") or c.get("n_routed_experts"))
    if experts and experts > 1:
        out["moe"] = True
        out["experts"] = experts
        out["experts_per_token"] = _int(c.get("num_experts_per_tok") or c.get("top_k"))
    return out


_ACTIVE = re.compile(r"(?i)(\d+(?:\.\d+)?)b[-_]a(\d+(?:\.\d+)?)b")
_PARAMS = re.compile(r"(?i)(?<![A-Za-z0-9.])(\d+(?:\.\d+)?)b(?![A-Za-z])")


def params_from_name(model_id: str) -> tuple[float | None, float | None]:
    """(total, active) billions of parameters from a name such as Example-35B-A3B; (n, None) for 27B; (None, None) else."""
    name = model_id.split("/")[-1]
    m = _ACTIVE.search(name)
    if m:
        return float(m.group(1)), float(m.group(2))
    sizes = [float(x) for x in _PARAMS.findall(name)]
    return (max(sizes), None) if sizes else (None, None)


# ---------------------------------------------------------------- what the watcher records

@dataclass(frozen=True)
class SizeRecord:
    """One repo, at one revision, as the watcher read it (the report's `sizes` section). Every figure is optional:
    None means the watcher could not read it, never zero."""
    ref: str
    revision: str = ""
    size_bytes: int | None = None
    files_counted: int = 0
    kv_bytes_per_token: int | None = None
    full_attention_layers: int | None = None
    total_layers: int | None = None
    recurrent_state_bytes: int | None = None
    sliding_window_bytes: int | None = None
    sliding_window_tokens: int | None = None
    params_b: float | None = None
    active_params_b: float | None = None
    moe: bool = False
    license: str = ""
    pipeline_tag: str = ""
    format: str = ""                 # mlx | gguf | safetensors
    gated: bool = False
    eval_results: tuple = ()         # ({"name","value","dataset"}), self-reported on the model card: a hint
    notes: tuple = ()
    fetched_at: str = ""

    def as_dict(self) -> dict:
        d = {"revision": self.revision, "filesCounted": self.files_counted, "license": self.license,
             "pipelineTag": self.pipeline_tag, "format": self.format, "gated": self.gated, "moe": self.moe,
             "fetchedAt": self.fetched_at}
        for k, v in (("sizeBytes", self.size_bytes), ("kvBytesPerToken", self.kv_bytes_per_token),
                     ("fullAttentionLayers", self.full_attention_layers), ("totalLayers", self.total_layers),
                     ("recurrentStateBytes", self.recurrent_state_bytes), ("slidingWindowBytes", self.sliding_window_bytes),
                     ("slidingWindowTokens", self.sliding_window_tokens), ("paramsB", self.params_b),
                     ("activeParamsB", self.active_params_b)):
            if v is not None:
                d[k] = v
        if self.eval_results:
            d["evalResults"] = [dict(x) for x in self.eval_results]
        if self.notes:
            d["notes"] = list(self.notes)
        return d

    @property
    def weights_gib(self) -> float | None:
        return self.size_bytes / GIB if self.size_bytes else None

    @property
    def active_fraction(self) -> float | None:
        if self.active_params_b and self.params_b:
            return min(1.0, self.active_params_b / self.params_b)
        return None


def _pos_int(v):
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0 else None


def parse_sizes(raw) -> tuple[dict, list]:
    """The report's `sizes` section -> ({repo: SizeRecord}, problems). A malformed record is dropped with a reason,
    not trusted: a wrong size would put a model where it does not fit."""
    out, bad = {}, []
    if not isinstance(raw, dict):
        return out, bad
    for ref, d in list(raw.items())[:3000]:
        if not isinstance(ref, str) or not isinstance(d, dict) or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$", ref):
            bad.append(f"sizes: {str(ref)[:60]!r} is not a repo id")
            continue
        size = _pos_int(d.get("sizeBytes"))
        if size is not None and size <= 0:
            size = None
        pb, ab = d.get("paramsB"), d.get("activeParamsB")
        evals = tuple({"name": str(x.get("name", ""))[:60], "value": str(x.get("value", ""))[:20], "dataset": str(x.get("dataset", ""))[:60]}
                      for x in (d.get("evalResults") or [])[:8] if isinstance(x, dict))
        out[ref] = SizeRecord(
            ref, str(d.get("revision", "") or "")[:80], size, int(_pos_int(d.get("filesCounted")) or 0),
            _pos_int(d.get("kvBytesPerToken")), _pos_int(d.get("fullAttentionLayers")), _pos_int(d.get("totalLayers")),
            _pos_int(d.get("recurrentStateBytes")), _pos_int(d.get("slidingWindowBytes")), _pos_int(d.get("slidingWindowTokens")),
            float(pb) if isinstance(pb, (int, float)) and not isinstance(pb, bool) and pb > 0 else None,
            float(ab) if isinstance(ab, (int, float)) and not isinstance(ab, bool) and ab > 0 else None,
            bool(d.get("moe", False)), str(d.get("license", "") or "")[:80], str(d.get("pipelineTag", "") or "")[:60],
            str(d.get("format", "") or "")[:20], bool(d.get("gated", False)), evals,
            tuple(str(n)[:200] for n in (d.get("notes") or [])[:12]), str(d.get("fetchedAt", "") or "")[:30])
    return out, bad


# ---------------------------------------------------------------- the arithmetic

@dataclass(frozen=True)
class Need:
    context_tokens: int = 8192
    slots: int = 1


@dataclass(frozen=True)
class Measured:
    """A measured peak resident memory (from a capability-result/1 twin) and what it was measured at."""
    peak_gib: float
    context_tokens: int
    slots: int
    engine: str = ""
    engine_version: str = ""
    date: str = ""
    path: str = ""

    def covers(self, need: Need) -> bool:
        return self.context_tokens * self.slots >= need.context_tokens * need.slots and self.slots >= need.slots


def measured_from(result) -> Measured | None:
    """A Measured row from a results.Result, when it recorded the peak AND the context and slots it was taken at.
    A peak with no stated context says nothing about any other plan, so it is not used."""
    if result is None or not result.peak_resident_gib or not result.context_tokens or not result.parallel_slots:
        return None
    return Measured(result.peak_resident_gib, result.context_tokens, result.parallel_slots, result.engine_id,
                    result.engine_version, result.date, result.path)


@dataclass
class Footprint:
    total_gib: float | None
    provenance: str
    weights_gib: float | None = None
    kv_gib: float | None = None
    overhead_gib: float = 0.0
    kv_known: bool = False
    lines: list = field(default_factory=list)


def footprint(size: SizeRecord | None, estimate_gib: float | None, need: Need, overhead_fraction: float = ENGINE_OVERHEAD_FRACTION,
              measured: Measured | None = None, note_measured_miss: bool = True) -> Footprint:
    """Memory one model occupies for `need`, with the arithmetic. measured > exact > estimate."""
    lines: list = []
    ctx_s = f"{need.context_tokens:,} tokens x {need.slots} slot{'s' if need.slots != 1 else ''}"
    if measured is not None and measured.covers(need):
        lines.append(f"measured peak {measured.peak_gib:.1f} GiB at {measured.context_tokens:,} tokens x {measured.slots} slots "
                     f"({measured.engine} {measured.engine_version}, {measured.date}); the plan asks for {ctx_s}, which that covers")
        return Footprint(round(measured.peak_gib, 2), "measured", size.weights_gib if size else None, None, 0.0, True, lines)
    if measured is not None and note_measured_miss:
        lines.append(f"a measured peak exists ({measured.peak_gib:.1f} GiB at {measured.context_tokens:,} tokens x {measured.slots} slots) "
                     f"but the plan asks for {ctx_s}, more than was tested: planned from sizes instead")
    # weights
    if size is not None and size.weights_gib is not None:
        w, wprov = size.weights_gib, "exact"
        lines.append(f"weights {w:.2f} GiB (exact: {size.size_bytes:,} bytes in {size.files_counted} file(s) at {size.revision[:12] or 'an unpinned revision'})")
    elif estimate_gib is not None:
        w, wprov = float(estimate_gib), "estimate"
        lines.append(f"weights {w:.2f} GiB (estimate from the model name; the watcher has not read the file sizes)")
    else:
        lines.append("weights: size unknown (no file sizes, and the name carries no parameter count)")
        return Footprint(None, "unknown", None, None, 0.0, False, lines)
    # KV and fixed per-sequence state
    kv, kprov, known = 0.0, wprov, False
    if size is not None and size.kv_bytes_per_token is not None:
        known = True
        per_seq = size.kv_bytes_per_token * need.context_tokens
        parts = [f"{size.kv_bytes_per_token / KIB:g} KiB/token x {need.context_tokens:,} tokens"]
        if size.sliding_window_bytes:
            win = size.sliding_window_tokens or need.context_tokens
            sl = size.sliding_window_bytes * min(1.0, need.context_tokens / win)
            per_seq += sl
            parts.append(f"{sl / GIB:.2f} GiB sliding-window cap")
        if size.recurrent_state_bytes:
            per_seq += size.recurrent_state_bytes
            parts.append(f"{size.recurrent_state_bytes / (1 << 20):.0f} MiB recurrent state")
        elif size.recurrent_state_bytes is None and size.total_layers and size.full_attention_layers is not None \
                and size.full_attention_layers < size.total_layers and any("recurrent" in n for n in size.notes):
            parts.append("recurrent state not sized")
        kv = per_seq * need.slots / GIB
        kprov = "exact" if wprov == "exact" else "estimate"
        lines.append(f"KV {kv:.2f} GiB = ({' + '.join(parts)}) x {need.slots} slot{'s' if need.slots != 1 else ''}"
                     f" ({size.full_attention_layers} of {size.total_layers} layers grow with context)")
    else:
        lines.append(f"KV: not sized (no config.json read for this model), so the plan has no cache term for {ctx_s}")
    over = (w + kv) * overhead_fraction
    total = w + kv + over
    lines.append(f"engine overhead {over:.2f} GiB ({overhead_fraction:.0%} of weights + KV)")
    lines.append(f"total {total:.2f} GiB")
    return Footprint(round(total, 2), worst(wprov, kprov) if known else wprov, round(w, 2), round(kv, 2) if known else None,
                     round(over, 2), known, lines)


@dataclass(frozen=True)
class Usable:
    gib: float | None
    provenance: str            # measured | operator | preset | unknown
    line: str


def usable_for(node: nm.Node, wired_limit_mib: float | None = None, operator_gib: float | None = None) -> Usable:
    """What a node may fill: its measured GPU wired limit; else a figure the operator set; else the node type's
    planning fraction of memory (75% for a Mac), the v1 default."""
    if wired_limit_mib and wired_limit_mib > 0:
        g = wired_limit_mib / 1024
        return Usable(round(g, 1), "measured", f"{g:.1f} GiB usable (the node's measured wired limit, {wired_limit_mib:,.0f} MiB)")
    if operator_gib and operator_gib > 0:
        return Usable(round(operator_gib, 1), "operator", f"{operator_gib:.1f} GiB usable (set by the operator)")
    mem = node.memory_gib()
    if mem:
        frac = node.kind["usable"]
        return Usable(round(mem * frac, 1), "preset", f"{mem * frac:.1f} GiB usable ({mem:g} GiB x {frac:.0%}, the planning default for "
                                                      f"{node.kind['memory_kind']} memory; a measured wired limit replaces it)")
    return Usable(None, "unknown", "no memory figure for this node")


@dataclass
class FitV2:
    state: str                      # fits | tight | over | unknown
    provenance: str                 # of the size behind the verdict: measured | exact | estimate | unknown
    usable: Usable
    footprint: Footprint
    beside_gib: float
    total_gib: float | None
    headroom_gib: float | None
    lines: list = field(default_factory=list)


def judge(fp: Footprint, usable: Usable, beside_gib: float = 0.0) -> FitV2:
    """fits / tight / over / unknown, with the whole sum written out."""
    lines = list(fp.lines) + [usable.line]
    if fp.total_gib is None or usable.gib is None:
        lines.append("state unknown: " + ("no size for the model" if fp.total_gib is None else "no memory figure for the node"))
        return FitV2("unknown", fp.provenance, usable, fp, beside_gib, None, None, lines)
    total = beside_gib + fp.total_gib
    frac = FITS_FRACTION if (fp.kv_known or fp.provenance == "measured") else FITS_FRACTION_KV_UNKNOWN
    state = "over" if total > usable.gib else ("tight" if total > FITS_FRACTION * usable.gib else "fits")
    if state == "fits" and total > frac * usable.gib:
        state = "tight"
    beside = f"{beside_gib:.1f} GiB already routed there + " if beside_gib else ""
    lines.append(f"{beside}{fp.total_gib:.1f} GiB for this model = {total:.1f} GiB, {total / usable.gib:.0%} of usable: {state}"
                 + ("" if frac == FITS_FRACTION else f" (the cache is unsized, so 'fits' needs {FITS_FRACTION_KV_UNKNOWN:.0%} or less)"))
    return FitV2(state, fp.provenance, usable, fp, round(beside_gib, 2), round(total, 2), round(usable.gib - total, 2), lines)


# ---------------------------------------------------------------- decode prior

def bandwidth_for(chip: str, override_gbps: float | None = None) -> tuple[float | None, str]:
    """(GB/s, 'operator' | 'preset' | 'unknown') for a node. The table is published peak figures by chip name."""
    if override_gbps and override_gbps > 0:
        return float(override_gbps), "operator"
    c = (chip or "").lower()
    for key, gbps in CHIP_BANDWIDTH_GBPS:
        if key in c:
            return gbps, "preset"
    return None, "unknown"


def predict_decode_tps(bandwidth_gbps: float | None, size: SizeRecord | None, estimate_gib: float | None = None,
                       eta: float | None = None) -> tuple[float | None, str]:
    """(tokens/s, how) for single-stream decode: bandwidth x eta / bytes read per token. An MoE model reads only its
    active experts, so it needs an active-parameter figure; without one the answer is None rather than the dense
    figure (which would understate it several-fold). Ignores KV reads: optimistic at long context."""
    if not bandwidth_gbps:
        return None, "no bandwidth figure for this node"
    moe = bool(size and size.moe)
    if size is not None and size.weights_gib is not None:
        wbytes = size.size_bytes
    elif estimate_gib:
        wbytes = estimate_gib * GIB
    else:
        return None, "no size"
    frac = 1.0
    if moe:
        frac = size.active_fraction
        if not frac:
            return None, "an MoE model with no active-parameter figure"
    e = eta if eta else (ETA_MOE if moe else ETA_DENSE)
    tps = bandwidth_gbps * 1e9 * e / (wbytes * frac)
    return round(tps, 1), f"{bandwidth_gbps:g} GB/s x {e:g} / {wbytes * frac / 1e9:.1f} GB read per token"


# ---------------------------------------------------------------- the nodes.fit() bridge

def route_need(route: nm.Route, default: Need = Need(), slots: int | None = None) -> Need:
    """The context a route pins (Ollama num_ctx, or modelInfo.max_input_tokens at the gateway) and its slots."""
    ctx = None
    for v in (route.params.get("num_ctx"), (route.model_info or {}).get("max_input_tokens")):
        if _int(v):
            ctx = _int(v)
            break
    return Need(ctx or default.context_tokens, slots or default.slots)


def fit_compat(node: nm.Node, routes: list, new_size: float | None, new_engine: str = "", *, sizes: dict | None = None,
               facts: dict | None = None, need: Need = Need(), new_record: SizeRecord | None = None,
               new_measured: Measured | None = None, overhead: dict | None = None, slots_by_alias: dict | None = None) -> nm.Fit:
    """nodes.fit()'s answer, planned by fit v2. Same shape (nm.Fit), so every caller of v1 can take it.

      sizes   {model id: SizeRecord} for the models already routed (join catalog entry.model to the report's sizes)
      facts   {"wired_limit_mib": float, "operator_usable_gib": float}
      need    the NEW model's context x slots; routes already placed use the context they pin (route_need)
      overhead {engine: fraction} calibrated for this node

    The resident/on-demand split is v1's: resident models plus the largest on-demand one is the worst moment."""
    facts, sizes, overhead, slots_by_alias = facts or {}, sizes or {}, overhead or {}, slots_by_alias or {}
    usable = usable_for(node, facts.get("wired_limit_mib"), facts.get("operator_usable_gib"))
    resident, od_max, unknown, seen, lines = 0.0, 0.0, [], set(), []
    prov = "exact"
    for r in routes:
        key = (r.endpoint, r.model)
        if key in seen:
            continue
        seen.add(key)
        ep = node.endpoint(r.endpoint)
        eng = ep.engine if ep else ""
        fp = footprint(sizes.get(r.model), r.size_gib, route_need(r, need, slots_by_alias.get(r.alias)),
                       overhead.get(eng, ENGINE_OVERHEAD_FRACTION), note_measured_miss=False)
        if fp.total_gib is None:
            unknown.append(r.alias)
            continue
        prov = worst(prov, fp.provenance)
        if ep is not None and nm.loading(ep.engine) == "on-demand":
            od_max = max(od_max, fp.total_gib)
        else:
            resident += fp.total_gib
        lines.append(f"{r.alias}: {fp.total_gib:.1f} GiB ({fp.provenance})")
    placed = round(resident + od_max, 1)
    nfp = footprint(new_record, new_size, need, overhead.get(new_engine, ENGINE_OVERHEAD_FRACTION), new_measured)
    nod = nm.loading(new_engine) == "on-demand" if new_engine else False
    f = nm.Fit("unknown", usable.gib, placed, nfp.total_gib, unknown, "", round(resident, 1), od_max, nod)
    basis = [usable.line, f"planned = resident {resident:.1f} GiB + largest on-demand {od_max:.1f} GiB"]
    if lines:
        basis.append("routed: " + "; ".join(lines))
    basis += [f"new model: {x}" for x in nfp.lines]
    f.basis = "; ".join(basis) + f" [sizes: {worst(prov, nfp.provenance)}]"
    if usable.gib is None:
        return f
    if nfp.total_gib is None:
        f.basis += "; the new model's size is not known"
        return f
    f.new_gib = nfp.total_gib
    total = f.total
    thr = FITS_FRACTION if (nfp.kv_known or nfp.provenance == "measured") else FITS_FRACTION_KV_UNKNOWN
    f.state = "over" if total > usable.gib else ("tight" if total > thr * usable.gib else "fits")
    return f

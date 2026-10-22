# SPDX-License-Identifier: Apache-2.0
"""Fit v2 (AC-48.14): exact weights bytes and KV per token from the watcher's report, context x slots, an engine overhead
constant, the node's measured wired limit. Provenance order measured > exact > estimate. Real recorded Hugging Face
answers (tests/fixtures/hf), no live network."""
import json
from pathlib import Path

import pytest

from tests.models_support import inventory_doc, result_text, world
from app import fit as fx
from app import nodes as nm
from app import results as rs
from app import watcher as wm

HF = Path(__file__).parent / "fixtures" / "hf"
GIB = 1 << 30
DENSE, HYBRID, SWA = "Qwen/Qwen3-32B", "Qwen/Qwen3-Next-80B-A3B-Instruct", "openai/gpt-oss-120b"


def cfg_of(ref):
    return json.loads((HF / (ref.replace("/", "_") + ".config.json")).read_text())


def record(ref):
    """A SizeRecord built the way the watcher builds one: the recorded model answer and config.json, nothing live."""
    info = json.loads((HF / (ref.replace("/", "_") + ".model.json")).read_text())
    size, n, fmt, _ = wm.sum_weights(info["siblings"])
    kv = fx.kv_from_config(cfg_of(ref))
    total, active = fx.params_from_name(ref)
    return fx.SizeRecord(ref, info["sha"], size, n, kv.get("kv_bytes_per_token"), kv.get("full_attention_layers"), kv.get("total_layers"),
                         kv.get("recurrent_state_bytes"), kv.get("sliding_window_bytes"), kv.get("sliding_window_tokens"), total, active,
                         bool(kv.get("moe")), "apache-2.0", "text-generation", fmt, False)


def node(chip="Apple M5 Ultra", mem=256, **kw):
    d = inventory_doc()["nodes"][0]
    d = {**d, "hardware": {"chip": {"value": chip, "source": "preset"}, "memory_gib": {"value": mem, "source": "preset"}}}
    return nm.parse_inventory({"nodes": [d], "routes": []}).nodes[0]


# ------------------------------------------------------------ KV per token, from the recorded configs

def test_dense_model_kv_is_2_x_layers_x_kv_heads_x_head_dim_x_2_bytes():
    kv = fx.kv_from_config(cfg_of(DENSE))
    assert kv["kv_bytes_per_token"] == 2 * 64 * 8 * 128 * 2 == 262144           # 256 KiB per token
    assert (kv["total_layers"], kv["full_attention_layers"]) == (64, 64) and "moe" not in kv


def test_hybrid_model_counts_only_the_layers_whose_cache_grows():
    kv = fx.kv_from_config(cfg_of(HYBRID))
    assert (kv["total_layers"], kv["full_attention_layers"]) == (48, 12)
    assert kv["kv_bytes_per_token"] == 2 * 12 * 2 * 256 * 2 == 24576            # a tenth of what 48 full layers would be
    assert kv["recurrent_state_bytes"] > 0 and kv["moe"] and kv["experts"] == 512
    assert any("recurrent state" in n for n in kv["notes"])


def test_sliding_window_layers_are_capped_at_the_window_not_counted_per_token():
    kv = fx.kv_from_config(cfg_of(SWA))
    assert (kv["total_layers"], kv["full_attention_layers"]) == (36, 18)
    assert kv["kv_bytes_per_token"] == 2 * 18 * 8 * 64 * 2 == 36864             # the growing layers only
    assert kv["sliding_window_tokens"] == 128 and kv["sliding_window_bytes"] == 18 * 2 * 8 * 64 * 2 * 128


def test_mla_caches_the_latent_not_the_heads():
    kv = fx.kv_from_config({"num_hidden_layers": 61, "num_attention_heads": 128, "kv_lora_rank": 512, "qk_rope_head_dim": 64,
                            "hidden_size": 7168})
    assert kv["kv_bytes_per_token"] == 61 * (512 + 64) * 2
    assert any("latent" in n for n in kv["notes"])


def test_text_config_nesting_per_layer_heads_and_mamba_hybrids():
    nested = fx.kv_from_config({"text_config": {"num_hidden_layers": 4, "num_attention_heads": 8, "num_key_value_heads": 2, "head_dim": 64}})
    assert nested["kv_bytes_per_token"] == 2 * 4 * 2 * 64 * 2 and "read from text_config" in nested["notes"]
    per_layer = fx.kv_from_config({"num_hidden_layers": 2, "num_attention_heads": 8, "num_key_value_heads": [2, 4], "head_dim": 64})
    assert per_layer["kv_bytes_per_token"] == (2 * 2 * 64 * 2) + (2 * 4 * 64 * 2)
    mamba = fx.kv_from_config({"num_hidden_layers": 4, "hybrid_override_pattern": "M*M-", "num_attention_heads": 8, "num_key_value_heads": 2,
                               "head_dim": 64, "mamba_num_heads": 8, "mamba_head_dim": 64, "ssm_state_size": 128})
    assert mamba["full_attention_layers"] == 1 and mamba["kv_bytes_per_token"] == 2 * 2 * 64 * 2 and mamba["recurrent_state_bytes"] > 0


def test_a_config_it_cannot_read_gives_no_figure_rather_than_a_guess():
    assert fx.kv_from_config({}) == {"notes": ["config.json has no layer count"]}
    assert fx.kv_from_config("not a dict") == {"notes": ["config.json has no layer count"]}
    bad = fx.kv_from_config({"num_hidden_layers": 4})
    assert bad["kv_bytes_per_token"] is None and any("unreadable" in n for n in bad["notes"])
    no_win = fx.kv_from_config({"num_hidden_layers": 4, "num_attention_heads": 8, "head_dim": 64, "layer_types": ["sliding_attention"] * 4})
    assert any("no window size" in n for n in no_win["notes"])
    hostile = fx.kv_from_config({"num_hidden_layers": float("inf"), "num_attention_heads": True})
    assert hostile == {"notes": ["config.json has no layer count"]}


def test_params_from_the_name():
    assert fx.params_from_name("org/Example-35B-A3B") == (35.0, 3.0)
    assert fx.params_from_name("org/Qwen3-32B") == (32.0, None)
    assert fx.params_from_name("org/Example-Embedding-0.6B-GGUF")[0] == 0.6
    assert fx.params_from_name("org/NoNumbers") == (None, None)


# ------------------------------------------------------------ the footprint, with the arithmetic shown

def test_exact_footprint_adds_weights_kv_and_overhead_and_says_how():
    r = record(DENSE)
    fp = fx.footprint(r, 30.0, fx.Need(32768, 1))
    w, kv = r.size_bytes / GIB, 262144 * 32768 / GIB
    assert fp.provenance == "exact" and fp.kv_known
    assert fp.weights_gib == pytest.approx(w, abs=0.01) and fp.kv_gib == pytest.approx(kv, abs=0.01) == pytest.approx(8.0, abs=0.01)
    assert fp.total_gib == pytest.approx((w + kv) * (1 + fx.ENGINE_OVERHEAD_FRACTION), abs=0.02)
    text = "\n".join(fp.lines)
    assert "(exact:" in text and "256 KiB/token x 32,768 tokens" in text and "64 of 64 layers" in text and "engine overhead" in text and "total" in text


def test_context_and_slots_scale_the_cache_not_the_weights():
    r = record(DENSE)
    one = fx.footprint(r, None, fx.Need(32768, 1))
    four = fx.footprint(r, None, fx.Need(32768, 4))
    long = fx.footprint(r, None, fx.Need(131072, 1))
    assert four.weights_gib == one.weights_gib and four.kv_gib == pytest.approx(4 * one.kv_gib, abs=0.02)
    assert long.kv_gib == pytest.approx(4 * one.kv_gib, abs=0.02)
    assert "x 4 slots" in "\n".join(four.lines)


def test_a_hybrid_model_at_long_context_costs_a_tenth_of_the_cache_a_dense_one_would():
    h, d = record(HYBRID), record(DENSE)
    hk = fx.footprint(h, None, fx.Need(131072, 2)).kv_gib
    dk = fx.footprint(d, None, fx.Need(131072, 2)).kv_gib
    assert hk < dk / 8
    assert "12 of 48 layers grow with context" in "\n".join(fx.footprint(h, None, fx.Need(131072, 2)).lines)
    assert "recurrent state" in "\n".join(fx.footprint(h, None, fx.Need(131072, 2)).lines)


def test_sliding_window_cache_is_capped_whatever_the_context():
    r = record(SWA)
    a, b = fx.footprint(r, None, fx.Need(8192, 1)), fx.footprint(r, None, fx.Need(131072, 1))
    grow = (36864 * (131072 - 8192)) / GIB
    assert b.kv_gib - a.kv_gib == pytest.approx(grow, abs=0.02)                 # only the full layers grew
    assert "sliding-window cap" in "\n".join(b.lines)


def test_estimate_is_used_only_when_there_is_no_exact_size_and_says_so():
    fp = fx.footprint(None, 18.0, fx.Need(8192, 1))
    assert fp.provenance == "estimate" and not fp.kv_known and fp.kv_gib is None
    assert fp.total_gib == pytest.approx(18.0 * 1.1, abs=0.01)
    assert "estimate from the model name" in "\n".join(fp.lines) and "KV: not sized" in "\n".join(fp.lines)
    none = fx.footprint(None, None, fx.Need())
    assert none.total_gib is None and none.provenance == "unknown"
    weights_only = fx.SizeRecord("o/m", "", None, 0)                              # a record with no size is not a size
    assert fx.footprint(weights_only, 9.0, fx.Need()).provenance == "estimate"


def test_measured_beats_exact_when_it_covers_the_plan_and_is_ignored_when_it_does_not():
    r = record(DENSE)
    res = rs.parse(result_text(model=DENSE, memory={"peak_resident_gib": 70.0, "context_tokens": 32768, "parallel_slots": 2}), "evals/r.json")
    m = fx.measured_from(res)
    covered = fx.footprint(r, None, fx.Need(16384, 2), measured=m)
    assert covered.provenance == "measured" and covered.total_gib == 70.0 and "which that covers" in "\n".join(covered.lines)
    over = fx.footprint(r, None, fx.Need(32768, 4), measured=m)
    assert over.provenance == "exact" and "more than was tested" in "\n".join(over.lines)
    assert fx.footprint(r, None, fx.Need(32768, 4), measured=m, note_measured_miss=False).provenance == "exact"
    no_ctx = rs.parse(result_text(model=DENSE, memory={"peak_resident_gib": 70.0}), "evals/r.json")
    assert fx.measured_from(no_ctx) is None                                       # a peak with no stated plan says nothing about another
    assert fx.measured_from(None) is None
    assert fx.worst("measured", "exact", "estimate") == "estimate" and fx.worst("measured", "exact") == "exact"


# ------------------------------------------------------------ the verdict against the node

def test_usable_memory_prefers_the_measured_wired_limit():
    n = node()
    assert fx.usable_for(n, 229376).provenance == "measured" and fx.usable_for(n, 229376).gib == 224.0
    assert fx.usable_for(n, None, 200).provenance == "operator"
    pre = fx.usable_for(n)
    assert pre.provenance == "preset" and pre.gib == 192.0 and "planning default" in pre.line
    assert fx.usable_for(nm.parse_inventory({"nodes": [{"id": "n", "name": "n", "type": "openai-compatible", "address": "192.0.2.50",
                                                        "endpoints": []}], "routes": []}).nodes[0]).provenance == "unknown"


def test_judge_fits_tight_over_unknown_with_the_sum_written_out():
    r = record(DENSE)
    fp = fx.footprint(r, None, fx.Need(32768, 1))                                 # about 76 GiB
    fits = fx.judge(fp, fx.Usable(192.0, "preset", "192.0 GiB usable"))
    assert fits.state == "fits" and fits.headroom_gib == pytest.approx(192.0 - fp.total_gib, abs=0.02)
    assert "of usable: fits" in fits.lines[-1]
    tight = fx.judge(fp, fx.Usable(85.0, "preset", "85 usable"))
    assert tight.state == "tight"
    over = fx.judge(fp, fx.Usable(60.0, "measured", "60 usable"))
    assert over.state == "over" and over.headroom_gib < 0
    beside = fx.judge(fp, fx.Usable(192.0, "preset", "u"), beside_gib=130.0)
    assert beside.state == "over" and "130.0 GiB already routed there +" in beside.lines[-1]
    assert fx.judge(fx.footprint(None, None, fx.Need()), fx.Usable(192.0, "preset", "u")).state == "unknown"
    assert fx.judge(fp, fx.Usable(None, "unknown", "no memory")).state == "unknown"


def test_an_unsized_cache_needs_more_headroom_before_it_says_fits():
    est = fx.footprint(None, 40.0, fx.Need(8192, 1))                              # 44 GiB, cache unknown
    ex = fx.footprint(fx.SizeRecord("o/m", "", int(40 * GIB), 1, 0, 0, 0), None, fx.Need(8192, 1))
    u = fx.Usable(60.0, "preset", "60 usable")                                    # 44 / 60 = 73%
    assert fx.judge(est, u).state == "tight" and "the cache is unsized" in fx.judge(est, u).lines[-1]
    assert fx.judge(ex, u).state == "fits"                                         # the same bytes with the cache sized: 73% is fine
    assert fx.judge(est, fx.Usable(70.0, "preset", "70")).state == "fits"        # 44 / 70 = 63%


# ------------------------------------------------------------ decode prior

def test_decode_is_bandwidth_x_eta_over_bytes_per_token():
    r = record(DENSE)
    tps, how = fx.predict_decode_tps(1228.0, r)
    assert tps == pytest.approx(1228e9 * fx.ETA_DENSE / r.size_bytes, abs=0.1)
    assert "1228 GB/s x 0.7" in how
    assert fx.predict_decode_tps(1228.0, r, eta=0.5)[0] == pytest.approx(1228e9 * 0.5 / r.size_bytes, abs=0.1)


def test_a_moe_model_reads_only_its_active_experts_and_needs_the_figure_to_say_so():
    r = record(HYBRID)                                                            # 80B-A3B
    assert r.active_fraction == pytest.approx(3 / 80)
    tps, _ = fx.predict_decode_tps(1228.0, r)
    assert tps == pytest.approx(1228e9 * fx.ETA_MOE / (r.size_bytes * 3 / 80), abs=0.5) and tps > 50
    nameless = fx.SizeRecord("o/Mystery", "", 60 * GIB, 8, moe=True)
    assert fx.predict_decode_tps(1228.0, nameless) == (None, "an MoE model with no active-parameter figure")


def test_decode_with_no_bandwidth_or_size_says_why():
    assert fx.predict_decode_tps(None, record(DENSE))[0] is None
    assert fx.predict_decode_tps(1228.0, None, None) == (None, "no size")
    assert fx.predict_decode_tps(1228.0, None, 18.0)[0] == pytest.approx(1228e9 * 0.7 / (18.0 * GIB), abs=0.1)


def test_bandwidth_comes_from_the_chip_or_the_operator():
    assert fx.bandwidth_for("Apple M5 Ultra") == (1228.0, "preset")
    assert fx.bandwidth_for("Apple M4 Max") == (546.0, "preset")
    assert fx.bandwidth_for("Apple M4 Max", 600) == (600.0, "operator")
    assert fx.bandwidth_for("Unknown Chip")[0] is None


# ------------------------------------------------------------ the nodes.fit() bridge

def test_fit_compat_has_nodes_fit_shape_and_agrees_with_v1_where_v1_can_speak():
    lc, inv = world()
    n = inv.node("beta")
    routes = inv.routes_on("beta")
    v1 = nm.fit(n, routes, 20.0, "mlx-lm")
    v2 = fx.fit_compat(n, routes, 20.0, "mlx-lm")
    assert isinstance(v2, nm.Fit) and v2.usable_gib == v1.usable_gib == 48.0
    assert v2.state in ("fits", "tight", "over") and "[sizes: estimate]" in v2.basis
    assert v2.new_gib == pytest.approx(22.0, abs=0.01)                            # 20 GiB + 10% overhead; v1 had weights only
    assert v2.unknown_sizes == []


def test_fit_compat_uses_exact_sizes_and_the_measured_wired_limit():
    lc, inv = world()
    n = inv.node("beta")
    rec = record(DENSE)
    loose = fx.fit_compat(n, [], None, "mlx-lm", new_record=rec, need=fx.Need(32768, 1))
    assert loose.state == "over" and "[sizes: exact]" in loose.basis                # 76 GiB on a 48 GiB-usable node
    big = fx.fit_compat(n, [], None, "mlx-lm", new_record=rec, need=fx.Need(32768, 1), facts={"wired_limit_mib": 85 * 1024})
    assert big.usable_gib == 85.0 and big.state == "tight" and "measured wired limit" in big.basis
    unknown = fx.fit_compat(n, [], None, "mlx-lm")
    assert unknown.state == "unknown" and "size is not known" in unknown.basis

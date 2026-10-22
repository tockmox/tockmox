# SPDX-License-Identifier: Apache-2.0
"""The fit estimate (AC-47.5) against research D's MEASURED table (design 0 A8, 3.4).

The estimate reads a model's name; the table is what the files on Hugging Face actually weigh (safetensors bytes,
2026-10-21). Run from tockmox-ui/: python -m pytest tests
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import nodes as nm  # noqa: E402

# (repo, real GiB) from research D section 1.3. The old estimator read 1.09 to 1.21 on the first eight and 2.08, 2.37 on the last two.
MEASURED = [
    ("mlx-community/Qwen3-8B-4bit", 4.3),
    ("mlx-community/Qwen3-32B-4bit", 17.2),
    ("mlx-community/Qwen3-32B-8bit", 32.4),
    ("mlx-community/Qwen3-30B-A3B-4bit", 16.0),
    ("mlx-community/gemma-3-27b-it-4bit", 15.7),
    ("mlx-community/Llama-3.3-70B-Instruct-4bit", 37.0),
    ("mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit", 41.8),
    ("mlx-community/Qwen3-235B-A22B-4bit", 123.2),
    ("mlx-community/gpt-oss-20b-MXFP4-Q8", 11.2),
    ("mlx-community/gpt-oss-120b-MXFP4-Q8", 59.0),
]


@pytest.mark.parametrize("repo,real", MEASURED)
def test_estimate_is_within_five_percent_of_the_measured_size(repo, real):
    est = nm.estimate_size_gib(repo)
    assert est is not None
    assert abs(est / real - 1) <= 0.05, f"{repo}: estimated {est} GiB, measured {real} GiB ({est / real - 1:+.1%})"


def test_the_old_overshoot_is_gone():
    """Every row used to read 9 to 21% high (and 2.4x on the MXFP4 pair). None may read high by more than 5% now."""
    ratios = [nm.estimate_size_gib(r) / real for r, real in MEASURED]
    assert max(ratios) < 1.05


def test_mxfp4_is_matched_before_8_bit():
    """'MXFP4-Q8' carries q8 in its name; the 8.5-bit pattern used to win and the 120B read 140 GiB."""
    assert nm.estimate_size_gib("mlx-community/gpt-oss-120b-MXFP4-Q8") < 65
    mx = nm.estimate_size_gib("somebody/Example-70B-MXFP4")
    q8 = nm.estimate_size_gib("somebody/Example-70B-8bit")
    assert mx is not None and q8 is not None and mx < q8 * 0.6
    assert nm.estimate_size_gib("somebody/Example-70B-NVFP4") == mx        # same 4.25 bits as MXFP4


def test_no_global_overhead_factor_remains():
    """The figure is parameters x bits / 8 in GB, converted to the planner's GiB, and nothing else is multiplied in."""
    assert nm.GB_TO_GIB == pytest.approx(1e9 / 2 ** 30)
    # 10B at the 4.6-bit default for a 4-bit name: 10 * 4.6 / 8 = 5.75 GB = 5.36 GiB (it read 6.3 with the old 1.1)
    assert nm.estimate_size_gib("example-10b-4bit") == pytest.approx(10 * 4.6 / 8 * nm.GB_TO_GIB, abs=0.06)


def test_other_quants_use_the_same_unit():
    assert nm.estimate_size_gib("Qwen/Qwen3-32B") == pytest.approx(32 * 16 / 8 * nm.GB_TO_GIB, abs=0.06)   # bf16 by default
    assert nm.estimate_size_gib("llama3.1:8b") == pytest.approx(8 * 4.6 / 8 * nm.GB_TO_GIB, abs=0.06)      # an Ollama tag


def test_a_name_with_no_parameter_count_is_still_unknown():
    assert nm.estimate_size_gib("mlx-community/mystery-4bit") is None


def test_the_page_still_calls_it_an_estimate(tmp_path):
    """Wherever the size is shown it is labelled: the node page says 'estimated from the model's name'."""
    src = (Path(__file__).resolve().parent.parent / "app" / "nodes_routes.py").read_text()
    assert "estimated from the model's name" in src
    tpl = (Path(__file__).resolve().parent.parent / "app" / "templates" / "node_detail.html").read_text()
    assert "An estimate of the weights only" in tpl and "10% for overhead" not in tpl

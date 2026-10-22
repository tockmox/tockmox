# SPDX-License-Identifier: Apache-2.0
"""Engine descriptors (omlx, vllm-mlx), the Mac presets, and the places that list engine ids (design 2.5 D7)."""
import json
import re
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import nodes as nm  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


def test_omlx_and_vllm_mlx_are_described():
    o, v = nm.ENGINES["omlx"], nm.ENGINES["vllm-mlx"]
    assert (o["port"], v["port"]) == (8000, 8000)
    for e in (o, v):
        assert e["auth"] == "bearer"                                   # both take --api-key
        assert e["provider"] == {"chat": "openai", "embedding": "openai", "rerank": None}
        assert e["base_path"]["chat"] == "/v1" and e["base_path"]["embedding"] == "/v1"
        assert e["pull"] and e["note"]
    assert nm.loading("omlx") == "on-demand"           # swappable: its engine pool evicts least recently used
    assert nm.loading("vllm-mlx") == "resident"        # a server process holds its model
    assert nm.loading("vllm") == "resident" and nm.loading("mlx-lm") == "resident"


def test_vllm_stays_the_cross_platform_id_and_says_so():
    assert "vllm" in nm.ENGINES
    note = nm.ENGINES["vllm"]["note"]
    assert "vllm-metal" in note and "CUDA" in note
    for t in ("apple-silicon-mac", "nvidia-dgx-spark", "nvidia-gpu-linux"):
        assert "vllm" in nm.CATALOG[t]["engines"]


def test_the_mac_offers_the_new_engines_and_the_catalog_names_only_known_ones():
    eng = nm.CATALOG["apple-silicon-mac"]["engines"]
    assert eng[0] == "mlx-lm" and {"omlx", "vllm-mlx", "vllm"} <= set(eng)
    for t, k in nm.CATALOG.items():
        assert set(k["engines"]) <= set(nm.ENGINES), t


def test_a_route_to_the_new_engines_derives_the_gateway_entry():
    inv = nm.parse_inventory({
        "nodes": [{"id": "m", "type": "apple-silicon-mac", "address": "10.0.0.5", "endpoints": [
            {"id": "omlx-8000", "engine": "omlx", "url": "http://10.0.0.5:8000"},
            {"id": "vllm-mlx-8001", "engine": "vllm-mlx", "url": "http://10.0.0.5:8001"}]}],
        "routes": [{"alias": "a", "node": "m", "endpoint": "omlx-8000", "model": "mlx-community/X-8bit"},
                   {"alias": "b", "node": "m", "endpoint": "vllm-mlx-8001", "model": "mlx-community/Y-4bit"}]})
    got = {e["model_name"]: e["litellm_params"] for e in nm.render_model_list(inv)}
    assert got["a"]["model"] == "openai/mlx-community/X-8bit" and got["a"]["api_base"] == "http://10.0.0.5:8000/v1"
    assert got["b"]["api_base"] == "http://10.0.0.5:8001/v1"
    with pytest.raises(nm.NodeError):                        # no rerank through the gateway, as for mlx-lm
        nm.provider_for("omlx", "rerank")


def test_mac_presets_carry_the_m5_family():
    ids = {p["id"]: p for p in nm.CATALOG["apple-silicon-mac"]["presets"]}
    for pid, mem in (("m5-ultra-96", 96), ("m5-ultra-256", 256), ("m5-ultra-512", 512), ("m5-max-128", 128)):
        assert ids[pid]["memory_gib"] == mem and ids[pid]["chip"].startswith("Apple M5")
    assert len(ids) == len(nm.CATALOG["apple-silicon-mac"]["presets"])      # ids are unique


def test_the_chart_schema_enum_is_the_engine_table_in_order():
    schema = json.loads((REPO / "charts/tockmox-ai/values.schema.json").read_text())
    item = schema["properties"]["inferenceNodes"]["properties"]["nodes"]["items"]["properties"]
    assert item["endpoints"]["items"]["properties"]["engine"]["enum"] == list(nm.ENGINES)
    assert item["type"]["enum"] == list(nm.CATALOG)


def test_the_chart_engines_file_matches_the_engine_table():
    """charts/tockmox-ai/files/inference-engines.yaml is generated from ENGINES: providers and base paths, per engine."""
    got = yaml.safe_load((REPO / "charts/tockmox-ai/files/inference-engines.yaml").read_text())
    want = {k: {"base_path": dict(e["base_path"]), "provider": {a: b for a, b in e["provider"].items() if b}}
            for k, e in nm.ENGINES.items()}
    assert got == want


def test_the_check_script_holds_the_two_enums_equal():
    """tools/check-inference-nodes.sh F4 compares the schema's enum with the keys of ENGINES: still true, and still asserted."""
    sh = (REPO / "tools/check-inference-nodes.sh").read_text()
    assert re.search(r'enum"\) == dict_keys\("ENGINES"\)', sh)


def test_the_operator_doc_lists_every_engine_id():
    doc = (REPO / "docs/administration/inference-nodes.md").read_text()
    line = doc.split("**Engines:**", 1)[1].split("\n\n", 1)[0]
    for e in nm.ENGINES:
        assert f"`{e}`" in line, f"{e} missing from the Engines list in docs/administration/inference-nodes.md"

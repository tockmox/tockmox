# SPDX-License-Identifier: Apache-2.0
"""TM-1119: a -next route made by the admit flow carries what the policy gate reads. The gate treats a deployment with
no model_info.endpoint_tier as external (fail closed), and with tag filtering on an untagged deployment serves no class,
so a -next route copied without them looked like an off-site model. Node routes are local by definition, and the tags are
the live alias's."""
import json

import yaml

from app import models as ml
from app import nodes as nm
from tests.models_support import inventory_doc, lifecycle_doc, models_client, world

CAND_MODEL = "example-org/Example-30B-4bit"
REV = "4" * 40


def candidate(kind="quant"):
    return ml.Candidate(f"{kind}:{CAND_MODEL}", kind, "example-27b-4bit", CAND_MODEL,
                        ml.Source("huggingface", CAND_MODEL, REV), "another quantisation", "", 17.0)


def tagged_world(tags=("internal", "open"), tier=None):
    lc, inv = world()
    live = next(r for r in inv.routes if r.alias == "local-medium")
    if tags is not None:
        live.params["tags"] = list(tags)
    if tier:
        live.model_info["endpoint_tier"] = tier
    return lc, inv


def next_route(add_inv, alias="local-medium-next"):
    return next(r for r in add_inv.routes if r.alias == alias)


def test_a_next_route_is_local_tier_even_when_the_live_route_never_said_so():
    lc, inv = tagged_world(tags=None)
    _lc, add_inv, _n = ml.propose(candidate(), lc, inv)
    assert next_route(add_inv).model_info["endpoint_tier"] == "local"


def test_a_next_route_copies_the_live_routes_tags_not_the_list_itself():
    lc, inv = tagged_world()
    _lc, add_inv, _n = ml.propose(candidate(), lc, inv)
    r = next_route(add_inv)
    live = next(x for x in inv.routes if x.alias == "local-medium")
    assert r.params["tags"] == ["internal", "open"] and r.params["tags"] is not live.params["tags"]


def test_tags_that_only_the_gateway_list_holds_are_copied_too():
    lc, inv = tagged_world(tags=None)
    gw = [{"model_name": "local-medium", "litellm_params": {"model": "openai/x", "tags": ["restricted", "internal"]},
           "model_info": {"endpoint_tier": "local"}}]
    _lc, add_inv, _n = ml.propose(candidate(), lc, inv, gateway=gw)
    assert next_route(add_inv).params["tags"] == ["restricted", "internal"]


def test_an_explicit_tier_on_the_live_route_is_kept_not_overwritten():
    lc, inv = tagged_world(tier="external")
    _lc, add_inv, _n = ml.propose(candidate(), lc, inv)
    assert next_route(add_inv).model_info["endpoint_tier"] == "external"


def test_the_eval_gateway_entry_renders_with_tier_and_tags():
    lc, inv = tagged_world()
    add_lc, add_inv, _n = ml.propose(candidate(), lc, inv)
    new_inv = nm.merge(inv, add_inv)
    entry = next(m for m in nm.render_model_list(new_inv, "eval") if m["model_name"] == "local-medium-next")
    assert entry["model_info"]["endpoint_tier"] == "local" and entry["litellm_params"]["tags"] == ["internal", "open"]
    text = yaml.dump(nm.inventory_to_doc(new_inv), Dumper=nm._Dumper, sort_keys=False)
    assert "&id" not in text and "*id" not in text            # the shared-list anchor of site PR #114 stays fixed


def test_a_new_alias_and_a_re_placement_are_local_tier_too():
    lc, inv = tagged_world()
    src = ml.Source("huggingface", CAND_MODEL, REV)
    _l, add_inv, _n = ml.propose_new("local-fresh", CAND_MODEL, src, "alpha", "mlx-lm-8080", "chat", lc, inv)
    assert next_route(add_inv, "local-fresh-next").model_info["endpoint_tier"] == "local"
    _l, add_inv, _n = ml.propose_replacement("local-medium", "alpha", "mlx-lm-8080", lc, inv)
    r = next_route(add_inv)
    assert r.model_info["endpoint_tier"] == "local" and r.params["tags"] == ["internal", "open"]


def test_the_admit_button_writes_both(tmp_path):
    inv = inventory_doc()
    for r in inv["routes"]:
        if r["alias"] == "local-medium":
            r["params"] = {"tags": ["internal", "open"]}
    lcd = lifecycle_doc()
    rep = tmp_path / "report.json"
    rep.write_text(json.dumps({"schema": 1, "generatedAt": "2099-01-01T00:00:00Z", "sources": {"huggingface": {"ok": True}},
                               "candidates": [{"id": "quant:x", "kind": "quant", "subject": "example-27b-4bit", "model": CAND_MODEL,
                                               "source": {"kind": "huggingface", "ref": CAND_MODEL, "revision": REV},
                                               "detail": "another quantisation"}]}))
    c, u = models_client(tmp_path, lifecycle={**lcd, "reportFile": str(rep)}, inventory=inv)
    r = c.post("/models/propose", data={"csrf": u.csrf, "cid": "quant:x", "fmt": "yaml"})
    routes = {x["alias"]: x for x in yaml.safe_load(r.text)["inferenceNodes"]["routes"]}
    assert routes["local-medium-next"]["modelInfo"]["endpoint_tier"] == "local"
    assert routes["local-medium-next"]["params"]["tags"] == ["internal", "open"]


def test_the_admit_button_takes_tags_from_the_gateway_list_the_ui_was_given(tmp_path):
    inv = inventory_doc()
    inv["gateway"] = {"modelList": [{"model_name": "local-medium", "litellm_params": {"model": "openai/x", "tags": ["restricted", "internal"]},
                                     "model_info": {"endpoint_tier": "local"}}]}
    rep = tmp_path / "report.json"
    rep.write_text(json.dumps({"schema": 1, "generatedAt": "2099-01-01T00:00:00Z", "sources": {"huggingface": {"ok": True}},
                               "candidates": [{"id": "quant:x", "kind": "quant", "subject": "example-27b-4bit", "model": CAND_MODEL,
                                               "source": {"kind": "huggingface", "ref": CAND_MODEL, "revision": REV}, "detail": "d"}]}))
    c, u = models_client(tmp_path, lifecycle={**lifecycle_doc(), "reportFile": str(rep)}, inventory=inv)
    r = c.post("/models/propose", data={"csrf": u.csrf, "cid": "quant:x", "fmt": "yaml"})
    routes = {x["alias"]: x for x in yaml.safe_load(r.text)["inferenceNodes"]["routes"]}
    assert routes["local-medium-next"]["params"]["tags"] == ["restricted", "internal"]


def test_the_pr_opener_writes_both_too():
    from app import pr_opener as po
    inv = inventory_doc()
    inv["gateway"] = {"modelList": [{"model_name": "local-medium", "litellm_params": {"tags": ["internal"]}}]}
    values = {"modelLifecycle": lifecycle_doc(), "inferenceNodes": inv}
    cand = {"id": "quant:x", "kind": "quant", "subject": "example-27b-4bit", "model": CAND_MODEL,
            "source": {"kind": "huggingface", "ref": CAND_MODEL, "revision": REV}, "detail": "d"}
    p = po.plan(values, {"schema": 1, "candidates": [cand]}, [])
    assert [x.kind for x in p.prs] == ["admit"], p.skipped
    routes = {x["alias"]: x for x in yaml.safe_load(p.prs[0].text)["inferenceNodes"]["routes"]}
    assert routes["local-medium-next"]["modelInfo"]["endpoint_tier"] == "local"
    assert routes["local-medium-next"]["params"]["tags"] == ["internal"]

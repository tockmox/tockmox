# SPDX-License-Identifier: Apache-2.0
"""REQ-0048: catalog, detectors, the promotion gate, proposals and residency (pure functions)."""
import json

import pytest

from tests.proto_support import _secret  # noqa: F401  (autouse fixture: the session secret the config needs)
from tests.proto_support import (OLLAMA_NEW, OLLAMA_OLD, SHA_NEW, SHA_OLD, reference_inventory_doc, lifecycle_doc, lifecycle_full_doc,
                      verdict_record, verdicts)
from app import models as ml
from app import nodes as nm
from app.config import ConfigError, parse


def lc():
    return ml.parse(lifecycle_doc())


def inv():
    d = lifecycle_full_doc()["inferenceNodes"]
    return nm.parse_inventory(d)


# ------------------------------------------------------------ parse

@pytest.mark.parametrize("bad,match", [
    ({"catalog": [{"id": "x", "model": "m", "source": {"kind": "ftp", "ref": "r"}}]}, "source.kind"),
    ({"catalog": [{"id": "x", "model": "m", "source": {"kind": "huggingface", "ref": "r", "revision": "main"}}]}, "commit sha"),
    ({"catalog": [{"id": "x", "model": "m", "stage": "beta", "source": {"kind": "hosted", "ref": "a/b"}}]}, "stage"),
    ({"catalog": [{"id": "x", "model": "m", "track": ["vibes"], "source": {"kind": "hosted", "ref": "a/b"}}]}, "track"),
    ({"frontier": {"tags": ["open"]}}, "withdrawn"),
    ({"promotion": {"requiredPasses": 0}}, "1 to 20"),
    ({"promotion": {"requiredPasses": "3"}}, "1 to 20"),
    ({"promotion": {"requiredPassesByClass": {"Chat!": 1}}}, "class slug"),
    ({"profiles": [{"id": "p", "classes": {"c": {"alias": "a", "residency": "always"}}}]}, "residency"),
    ({"activeProfile": "nope"}, "activeProfile"),
])
def test_bad_lifecycle_is_refused(bad, match):
    with pytest.raises(ml.LifecycleError, match=match):
        ml.parse(bad)


# ------------------------------------------------------------ rule 2: the gate

def test_candidate_on_a_live_alias_fails_the_gate_and_the_ui_will_not_start():
    d = lifecycle_full_doc()
    d["modelLifecycle"]["catalog"][0]["stage"] = "candidate"          # local-medium-next is a -next: fine
    assert ml.check_promotions(ml.parse(d["modelLifecycle"]), nm.parse_inventory(d["inferenceNodes"])) == []
    d["modelLifecycle"]["catalog"][2]["stage"] = "candidate"          # local-medium (live) serves Qwen2.5-32B
    probs = ml.check_promotions(ml.parse(d["modelLifecycle"]), nm.parse_inventory(d["inferenceNodes"]))
    assert any("local-medium points at" in p and "still a candidate" in p for p in probs)
    with pytest.raises(ConfigError, match="promotion gate"):
        parse(d)


def _ev(n, sha="f" * 64):
    return [{"path": f"evals/verdicts/{i}.json", "sha256": sha, "runId": f"r{i}", "date": "2026-10-07", "verdict": "pass"}
            for i in range(n)]


def test_a_promotion_without_enough_passing_comparisons_fails_the_gate():
    d = lifecycle_full_doc()
    e = d["modelLifecycle"]["catalog"][2]
    e.pop("adopted")
    e["promotion"] = {"aliases": ["local-medium", "ops-32b"], "from": "x", "class": "chat", "required": 3, "evidence": _ev(2)}
    with pytest.raises(ConfigError, match="2 passing comparison"):
        parse(d)
    e["promotion"]["evidence"] = _ev(3, sha="nothex")
    with pytest.raises(ConfigError, match="0 passing comparison"):
        parse(d)
    e["promotion"]["evidence"] = _ev(2) + [dict(_ev(1)[0])]           # a run id twice is one run
    with pytest.raises(ConfigError, match="2 passing comparison"):
        parse(d)
    e["promotion"].pop("required")
    e["promotion"]["evidence"] = _ev(3)
    with pytest.raises(ConfigError, match="how many"):
        parse(d)
    e["promotion"]["required"] = 3
    parse(d)


def test_raising_the_bar_flags_older_promotions_without_stopping_the_ui():
    d = lifecycle_full_doc()
    e = d["modelLifecycle"]["catalog"][2]
    e.pop("adopted")
    e["promotion"] = {"aliases": ["local-medium", "ops-32b"], "from": "x", "class": "chat", "required": 3, "evidence": _ev(3)}
    d["modelLifecycle"]["promotion"] = {"requiredPasses": 5}
    s = parse(d)
    assert any("now requires 5" in n for n in ml.promotion_notes(s.lifecycle.lifecycle))


# ------------------------------------------------------------ detectors

def test_hf_revision_quant_and_successor():
    e = lc().entry("qwen3-8-27b-4bit")
    info = {"id": e.source.ref, "sha": SHA_NEW, "lastModified": "2026-10-05T10:00:00.000Z"}
    sib = [{"id": "mlx-community/Qwen3.8-27B-8bit", "lastModified": "2026-10-01"},
           {"id": "lmstudio-community/Qwen3.8-27B-MLX-4bit"},           # same quant, other publisher: not news
           {"id": "randomuser/Qwen3.8-27B-q2"},                         # not a trusted quant author
           {"id": e.source.ref}]
    newer = [{"id": "Qwen/Qwen3.9-27B", "createdAt": "2026-10-06"}, {"id": "Qwen/Qwen3.9-235B-A22B"},
             {"id": "Qwen/Qwen3.7-27B"}, {"id": "Qwen/Qwen3.8-27B"}]
    got = {c.kind: c for c in ml.detect_hf(e, info, sib, newer, ("mlx-community", "lmstudio-community"))}
    assert got["revision"].source.revision == SHA_NEW and got["revision"].model == e.model
    quants = [c.model for c in ml.detect_hf(e, None, sib, [], ("mlx-community", "lmstudio-community"))]
    assert quants == ["mlx-community/Qwen3.8-27B-8bit"]
    succ = [c.model for c in ml.detect_hf(e, None, [], newer)]
    assert succ == ["Qwen/Qwen3.9-27B"]                               # newer, same size only


def test_hf_same_revision_is_quiet():
    e = lc().entry("qwen3-8-27b-4bit")
    assert ml.detect_hf(e, {"sha": SHA_OLD}, [], []) == []


def test_ollama_digest():
    e = lc().entry("qwen3-coder-30b")
    assert ml.detect_ollama(e, OLLAMA_OLD) == []
    c = ml.detect_ollama(e, OLLAMA_NEW, "2026-10-01")
    assert c[0].kind == "digest" and c[0].source.revision == OLLAMA_NEW


def test_frontier_new_and_retiring():
    listed = [{"id": "claude-opus-5"}, {"id": "claude-opus-5-5", "created": "2026-09-30"}, {"id": "gpt-x", "shutdown": None},
              {"id": "claude-haiku-4-5", "shutdown": "2026-12-01"}]
    got = ml.detect_frontier("anthropic", listed, {"claude-opus-5", "claude-haiku-4-5"}, ["claude-*"])
    kinds = {(c.kind, c.model) for c in got}
    assert ("frontier", "anthropic/claude-opus-5-5") in kinds and ("deprecation", "anthropic/claude-haiku-4-5") in kinds
    assert not any("gpt-x" in m for _, m in kinds)                    # filtered by allow


# ------------------------------------------------------------ rule 1: propose beside, never over

def test_successor_is_proposed_as_next_beside_the_live_route():
    L, I = lc(), inv()
    cand = ml.Candidate("successor:Qwen/Qwen3.9-27B", "successor", "qwen3-8-27b-4bit", "mlx-community/Qwen3.9-27B-4bit",
                        ml.Source("huggingface", "mlx-community/Qwen3.9-27B-4bit"), "newer", size_gib=17.5)
    # the live route for that model in the fixture is local-medium-next itself; give it a live alias
    I.routes.append(nm.Route("local-chat", "mac-studio-m4-max", "http-8082", "mlx-community/Qwen3.8-27B-4bit", size_gib=17.1))
    add_lc, add_inv, notes = ml.propose(cand, L, I)
    assert [r.alias for r in add_inv.routes] == ["local-chat-next"]    # a live -next alias (local-medium-next) gets none
    assert add_lc.catalog[0].stage == "candidate"
    new_L, new_I = ml.merge(L, add_lc), nm.merge(I, add_inv)
    assert ml.check_promotions(new_L, new_I) == []
    assert next(r for r in new_I.routes if r.alias == "local-chat").model == "mlx-community/Qwen3.8-27B-4bit"   # untouched


def test_frontier_proposal_lands_on_the_eval_gateway_untagged_and_as_a_candidate():
    """Ruling 2 (2026-10-07): new models, local or hosted, are unusable until explicitly approved."""
    L, I = lc(), inv()
    cand = ml.Candidate("frontier:anthropic/claude-opus-5-5", "frontier", "anthropic", "anthropic/claude-opus-5-5",
                        ml.Source("hosted", "anthropic/claude-opus-5-5"), "new")
    add_lc, add_inv, notes = ml.propose(cand, L, I)
    assert add_lc.production_gateway_entries == [] and len(add_lc.eval_gateway_entries) == 1
    g = add_lc.eval_gateway_entries[0]
    assert "tags" not in g["litellm_params"] and g["litellm_params"]["api_key"] == "os.environ/ANTHROPIC_API_KEY"
    assert add_lc.catalog[0].stage == "candidate" and add_inv.routes == []
    new_L = ml.merge(L, add_lc)
    assert ml.check_promotions(new_L, I) == []                         # a hosted candidate is not a gate failure


def test_next_routes_never_reach_the_production_gateway():
    """TM-0936: inside one gateway an access group fails open, so a candidate must not be in it at all."""
    I = inv()
    prod = {e["model_name"] for e in nm.render_model_list(I)}
    ev = {e["model_name"] for e in nm.render_model_list(I, "eval")}
    assert "local-medium-next" not in prod and "local-medium" in prod
    assert {"local-medium-next", "local-medium"} <= ev                  # the candidate and what it is compared against
    assert all(a.endswith("-next") or a + "-next" in ev for a in ev) and not any(a.endswith("-next") for a in prod)
    assert "local-medium-next" in {e["model_name"] for e in nm.render_model_list(I, "all")}


def test_deprecation_is_a_notice_not_a_proposal():
    with pytest.raises(ml.LifecycleError, match="notice"):
        ml.propose(ml.Candidate("d", "deprecation", "anthropic", "anthropic/x", ml.Source("hosted", "anthropic/x"), ""), lc(), inv())


# ------------------------------------------------------------ promotion

NEW = "mlx-community/Qwen3.9-27B-4bit"
OLD = "mlx-community/Qwen3.8-27B-4bit"          # what local-agent serves in the fixture


def _with_next():
    d = lifecycle_full_doc()
    d["modelLifecycle"]["catalog"].append({"id": "qwen3-9-27b-4bit", "model": NEW, "stage": "candidate",
                                           "source": {"kind": "huggingface", "ref": NEW}})
    d["inferenceNodes"]["routes"].append({"alias": "local-agent-next", "node": "mac-studio-m4-max", "endpoint": "http-8082",
                                          "model": NEW, "kind": "chat"})
    return ml.parse(d["modelLifecycle"]), nm.parse_inventory(d["inferenceNodes"])


def _incumbent(I):
    return next(r for r in I.routes if r.alias == "local-agent").model


def _passes(I, n, start=0, **kw):
    return [verdict_record(NEW, "local-agent", run=f"r{i}", date=f"2026-10-{i + 1:02d}", incumbent=_incumbent(I), **kw)
            for i in range(start, start + n)]


def test_count_passes_rules():
    L, I = _with_next()
    inc = _incumbent(I)
    v = verdicts(*_passes(I, 2), verdict_record(NEW, "local-agent", "fail", run="f1", date="2026-10-03", incumbent=inc),
                 *_passes(I, 2, start=3))
    counted, notes = ml.count_passes(v, "local-agent", NEW, "", inc)
    assert [x.run_id for x in counted] == ["r3", "r4"] and any("no longer count" in n for n in notes)   # a fail resets
    v = verdicts(*_passes(I, 1), verdict_record(NEW, "local-agent", "inconclusive", run="i1", date="2026-10-02", incumbent=inc),
                 *_passes(I, 1, start=2))
    assert len(ml.count_passes(v, "local-agent", NEW, "", inc)[0]) == 2                             # inconclusive is neutral
    v = verdicts(*_passes(I, 1), *_passes(I, 1))
    assert len(ml.count_passes(v, "local-agent", NEW, "", inc)[0]) == 1                             # a run id counts once
    v = verdicts(*_passes(I, 2, eval_version="v1"), *_passes(I, 1, start=2, eval_version="v2"))
    assert len(ml.count_passes(v, "local-agent", NEW, "", inc)[0]) == 1                             # newest eval set only
    v = verdicts(*_passes(I, 3))
    assert ml.count_passes(v, "local-agent", NEW, "", "someone-else")[0] == []                     # against another incumbent
    v = verdicts(*_passes(I, 3, revision=SHA_NEW))
    assert ml.count_passes(v, "local-agent", NEW, SHA_OLD, inc)[0] == []                           # another build


@pytest.mark.parametrize("records,match", [
    (lambda I: _passes(I, 2), "2 of 3"),
    (lambda I: [verdict_record(NEW, "local-agent", "fail", incumbent=_incumbent(I))], "no passing comparison"),
    (lambda I: [verdict_record("mlx-community/Other-27B-4bit", "local-agent", incumbent=_incumbent(I))], "no passing comparison"),
    (lambda I: [verdict_record(NEW, "local-medium", run=f"x{i}") for i in range(3)], "no passing comparison"),
])
def test_promotion_refusals(records, match):
    L, I = _with_next()
    with pytest.raises(ml.LifecycleError, match=match):
        ml.promote("local-agent-next", verdicts(*records(I)), L, I)


def test_promotion_moves_the_alias_records_every_counted_run_and_passes_the_gate():
    L, I = _with_next()
    texts = _passes(I, 3)
    new_L, new_I, notes = ml.promote("local-agent-next", verdicts(*texts), L, I)
    live = next(r for r in new_I.routes if r.alias == "local-agent")
    assert live.model == NEW and live.endpoint == "http-8082"
    assert not any(r.alias == "local-agent-next" for r in new_I.routes)
    e = new_L.by_model(NEW)
    import hashlib
    assert e.stage == "promoted" and e.promotion["required"] == 3 and e.promotion["class"] == "chat"
    assert [x["sha256"] for x in e.promotion["evidence"]] == [hashlib.sha256(t.encode()).hexdigest() for t in texts]
    assert ml.check_promotions(new_L, new_I) == []
    assert NEW in {x["litellm_params"]["model"].split("/", 1)[1] for x in nm.render_model_list(new_I)}   # now in production


def test_required_passes_is_configurable_per_class():
    d = lifecycle_full_doc(promotion={"requiredPasses": 3, "requiredPassesByClass": {"chat": 1}})
    d["modelLifecycle"]["catalog"].append({"id": "qwen3-9-27b-4bit", "model": NEW, "stage": "candidate",
                                           "source": {"kind": "huggingface", "ref": NEW}})
    d["inferenceNodes"]["routes"].append({"alias": "local-agent-next", "node": "mac-studio-m4-max", "endpoint": "http-8082",
                                          "model": NEW, "kind": "chat"})
    L, I = ml.parse(d["modelLifecycle"]), nm.parse_inventory(d["inferenceNodes"])
    new_L, _, _ = ml.promote("local-agent-next", verdicts(*_passes(I, 1, grader="jeff")), L, I)
    assert new_L.by_model(NEW).promotion["required"] == 1
    with pytest.raises(ml.LifecycleError, match="1 of 3"):
        ml.promote("local-agent-next", verdicts(*_passes(I, 1, klass="classify")), L, I)


def test_hosted_promotion_needs_passes_and_tags():
    L, I = lc(), inv()
    cand = ml.Candidate("f", "frontier", "anthropic", "anthropic/claude-opus-5-5", ml.Source("hosted", "anthropic/claude-opus-5-5"), "")
    L = ml.merge(L, ml.propose(cand, L, I)[0])
    eid = L.by_model("anthropic/claude-opus-5-5").id
    recs = verdicts(*[verdict_record("anthropic/claude-opus-5-5", "frontier-chat", run=f"h{i}") for i in range(3)])
    with pytest.raises(ml.LifecycleError, match="tag"):
        ml.promote_hosted(eid, "frontier-chat", [], recs, L)
    with pytest.raises(ml.LifecycleError, match="1 of 3"):
        ml.promote_hosted(eid, "frontier-chat", ["open"], recs[:1], L)
    new_L, notes = ml.promote_hosted(eid, "frontier-chat", ["open", "internal"], recs, L, {"frontier-chat"})
    g = new_L.production_gateway_entries[0]
    assert g["model_name"] == "frontier-chat" and g["litellm_params"]["tags"] == ["open", "internal"]
    assert new_L.entry(eid).stage == "promoted" and ml.check_promotions(new_L, I) == []
    assert any("already has frontier-chat" in n for n in notes)
    d = ml.to_doc(new_L)                                               # a hand-flipped hosted model fails the gate
    h = next(x for x in d["catalog"] if x["id"] == eid)
    h["promotion"]["evidence"] = h["promotion"]["evidence"][:1]
    assert any("hosted model" in p for p in ml.check_promotions(ml.parse(d), I))


@pytest.mark.parametrize("text,match", [("nope", "not JSON"), ('{"schema": 1}', "comparative-verdict/1"),
    (verdict_record("m", "a").replace('"pass"', '"maybe"'), "verdict one of"),
    (verdict_record("m", "a").replace('"rule"', '"vibes"'), "grader"),
    (verdict_record("m", "a").replace('"v1"', '""'), "eval_set"),
    (verdict_record("m", "a", revision="main"), "commit sha")])
def test_verdict_shape(text, match):
    with pytest.raises(ml.LifecycleError, match=match):
        ml.parse_verdict(text)


def test_eval_request_shape():
    r = ml.eval_request("local-agent", "chat", 3, {"model": NEW, "revision": ""}, {"model": OLD}, "jeff", "2026-10-07T13:00:00Z")
    assert r["gateway"] == "eval" and r["candidate"] == {"model": NEW} and r["runs"] == 3
    for bad in (("local-agent-next", "chat", 3), ("local-agent", "Chat!", 3), ("local-agent", "chat", 0)):
        with pytest.raises(ml.LifecycleError):
            ml.eval_request(*bad, {"model": NEW}, {}, "jeff", "t")


# ------------------------------------------------------------ residency

def test_residency_pins_by_priority_and_demotes_what_does_not_fit():
    L, I = lc(), inv()
    studio = I.node("mac-studio-m4-max")
    plan = ml.plan_residency(studio, I.routes_on(studio.id), L.profile("weekday"))
    got = {p.alias: p.got for p in plan.placements}
    assert got["local-medium-next"] == "pinned"                       # priority 1, 17.1 GiB
    assert got["local-agent"] == "on-demand"                          # priority 2 would not fit beside the largest on-demand
    assert any("local-agent wanted pinned" in w for w in plan.warnings)
    assert got["ops-agent-30b"] == "on-demand" and got["local-medium"] == "unprofiled"


def test_llama_swap_and_ollama_render():
    L, I = lc(), inv()
    studio = I.node("mac-studio-m4-max")
    plan = ml.plan_residency(studio, I.routes_on(studio.id), L.profile("weekday"))
    sw = ml.render_llama_swap(plan)
    assert sw["routing"]["router"]["use"] == "group"
    g = sw["routing"]["router"]["settings"]["groups"]
    assert g["pinned"]["persistent"] is True and "local-medium-next" in g["pinned"]["members"]
    assert sw["hooks"]["on_startup"]["preload"] == g["pinned"]["members"]
    assert sw["models"]["local-medium-next"]["cmd"].startswith("mlx_lm.server") and "${PORT}" in sw["models"]["local-medium-next"]["cmd"]
    oll = ml.render_ollama(plan)
    assert oll["routeParams"]["ops-agent-30b"]["keep_alive"] == "10m"


def test_a_successor_without_a_size_is_not_an_upgrade():
    """Lab finding 2026-10-07: 'Qwen3.8-Flash-Next' was offered as the successor of a 7B."""
    e = ml.Entry("q7", "mlx-community/Qwen2.5-7B-Instruct-4bit", ml.Source("huggingface", "mlx-community/Qwen2.5-7B-Instruct-4bit"),
                 base_model="Qwen/Qwen2.5-7B-Instruct", track=("successors",))
    newer = [{"id": "Qwen/Qwen3.8-Flash-Next"}, {"id": "Qwen/Qwen3-Coder-Next-FP8"}, {"id": "Qwen/Qwen3.5-7B-Instruct"}]
    assert [c.model for c in ml.detect_hf(e, None, [], newer)] == ["Qwen/Qwen3.5-7B-Instruct"]


# ------------------------------------------------------------ where a model comes from (TM-0938)

def test_source_links_per_kind():
    L = lc()
    hf = dict(ml.source_links(L.entry("qwen3-8-27b-4bit")))
    assert hf["Model card"] == "https://huggingface.co/mlx-community/Qwen3.8-27B-4bit"
    assert hf[f"Files at the pinned build ({SHA_OLD[:12]})"].endswith(f"/tree/{SHA_OLD}")
    assert "https://huggingface.co/Qwen/Qwen3.8-27B" in hf.values()                       # the base model's card
    ol = dict(ml.source_links(L.entry("qwen3-coder-30b")))
    assert ol == {"Library page": "https://ollama.com/library/qwen3-coder", "Tags and builds": "https://ollama.com/library/qwen3-coder/tags"}
    user = ml.Entry("u", "jeff/tiny:1b", ml.Source("ollama", "jeff/tiny:1b"))
    assert dict(ml.source_links(user))["Library page"] == "https://ollama.com/jeff/tiny"
    ant = ml.Entry("a", "anthropic/claude-x", ml.Source("hosted", "anthropic/claude-x"))
    assert ml.source_links(ant)[0][1].startswith("https://platform.claude.com/")
    orr = ml.Entry("o", "openrouter/anthropic/claude-x", ml.Source("hosted", "openrouter/anthropic/claude-x"))
    assert ml.source_links(orr)[0][1] == "https://openrouter.ai/anthropic/claude-x"
    assert ml.source_links(ant, {"anthropic": "https://docs.example/models/{model}"})[0][1] == "https://docs.example/models/claude-x"
    assert ml.source_links(ml.Entry("k", "kit", ml.Source("modelkit", "harbor.example/ai/kit:1"))) == []   # nothing derivable: no guess


REG = {"harbor.example": "https://harbor.example/harbor/projects/{repository}/artifacts/{reference}",
       "reg.lan:5000": "https://reg.lan:5000/ui/{repository}?tag={reference}"}


def _kit(ref):
    return ml.source_links(ml.Entry("k", "kit", ml.Source("modelkit", ref)), None, REG)


def test_modelkit_links_only_for_a_registry_the_site_named():
    assert _kit("harbor.example/ai/qwen-kit:1.2") == [("Registry page", "https://harbor.example/harbor/projects/ai/qwen-kit/artifacts/1.2")]
    d = "sha256:" + "a" * 64
    assert _kit(f"harbor.example/ai/kit@{d}")[0][1].endswith("/artifacts/" + d)
    assert _kit("harbor.example/ai/kit")[0][1].endswith("/artifacts/latest")
    assert _kit("reg.lan:5000/team/kit:v3") == [("Registry page", "https://reg.lan:5000/ui/team/kit?tag=v3")]
    assert _kit("other.example/ai/kit:1") == []                    # a host the site did not name: no guess
    assert _kit("harbor.example/AI/kit:1") == []                   # not an OCI repository name
    assert _kit("harbor.example/ai/kit:bad tag") == []
    assert _kit("harbor.example/ai/kit@sha256:short") == []
    assert _kit('harbor.example/ai/x"onmouseover=1:1') == []
    assert _kit("kit:1") == []


def test_modelkit_registries_config_is_validated(tmp_path):
    from app import config as cfgmod
    from app import nodes as nm
    inv = nm.parse_inventory({"nodes": [], "routes": []})
    base = {"catalog": []}
    for bad in ({"harbor.example": "http://harbor.example/{repository}"}, {"Bad Host": "https://x.example/{repository}"},
                {"harbor.example": "javascript:alert(1)"}, ["harbor.example"]):
        with pytest.raises(cfgmod.ConfigError, match="modelkitRegistries"):
            cfgmod._parse_lifecycle({**base, "modelkitRegistries": bad}, inv)
    ok = cfgmod._parse_lifecycle({**base, "modelkitRegistries": REG}, inv)
    assert ok.modelkit_registries == REG
    assert ml.source_links(ml.Entry("w", "x", ml.Source("hosted", "unknownco/x"))) == []


@pytest.mark.parametrize("links,match", [
    ([{"title": "Notes", "url": "javascript:alert(1)"}], "https://"),
    ([{"title": "Notes", "url": "http://example.com/notes"}], "https://"),
    ([{"title": "Notes", "url": "https://example.com/a b"}], "https://"),
    ([{"title": "", "url": "https://example.com"}], "title"),
    ([{"title": "n", "url": "https://example.com"}] * 11, "at most 10"),
    ("https://example.com", "list"),
])
def test_operator_links_are_https_only(links, match):
    d = lifecycle_doc()
    d["catalog"][0]["links"] = links
    with pytest.raises(ml.LifecycleError, match=match):
        ml.parse(d)


def test_operator_links_round_trip():
    d = lifecycle_doc()
    d["catalog"][0]["links"] = [{"title": "Release notes", "url": "https://qwenlm.github.io/blog/qwen3.8/"}]
    assert ml.to_doc(ml.parse(d))["catalog"][0]["links"] == d["catalog"][0]["links"]

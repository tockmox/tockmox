# SPDX-License-Identifier: Apache-2.0
"""TM-1297 (rulings D1 and D2, 2026-10-30): frontier generations. A hosted family keeps up to
modelLifecycle.frontier.keepGenerations generations, each under a pinned alias that never moves (claude-sonnet-5-5), and has
one floating family alias (claude-sonnet) that only a promotion moves. A generation leaves only on provider retirement or by
falling off the list through a change a person commits.

The tests: the name rules and ordering; keepGenerations from the values; a promotion moves only the family alias; a pinned
entry is never rewritten; a fourth generation renders the change that drops the oldest; the retire change and its refusal;
the family alias page, the pinned alias page, the Inbox action. Documentation names only."""
import copy
import html
import json
import re

import pytest
import yaml

from app import frontier as fz
from app import models as ml
from tests.models_support import lifecycle_doc, verdict_record, verdicts
from tests.pages_support import cand, day, page_client, write_report
from tests.proto_support import write_verdicts

# ------------------------------------------------------------ names and order

FAMILIES = [
    ("anthropic/claude-sonnet-5-5", "claude-sonnet", "claude-sonnet-5-5", (5, 5)),
    ("anthropic/claude-sonnet-5", "claude-sonnet", "claude-sonnet-5", (5,)),
    ("anthropic/claude-sonnet-4-5", "claude-sonnet", "claude-sonnet-4-5", (4, 5)),
    ("claude-haiku-4-5", "claude-haiku", "claude-haiku-4-5", (4, 5)),
    ("anthropic/claude-opus-5", "claude-opus", "claude-opus-5", (5,)),
    ("openai/gpt-5.1", "gpt", "gpt-5.1", (5, 1)),
    ("google/gemini-2.5-pro", "gemini-pro", "gemini-2.5-pro", (2, 5)),
    ("google/gemini-2.5-flash", "gemini-flash", "gemini-2.5-flash", (2, 5)),
    ("openai/gpt-5-mini", "gpt-mini", "gpt-5-mini", (5,)),
    ("anthropic/claude-3-5-sonnet", "claude-sonnet", "claude-3-5-sonnet", (3, 5)),                    # the older name order
    ("anthropic/claude-sonnet-4-5-20250929", "claude-sonnet", "claude-sonnet-4-5-20250929", (4, 5)),    # a dated snapshot
    ("openai/gpt-5-2025-08-07", "gpt", "gpt-5-2025-08-07", (5,)),
    ("openrouter/anthropic/claude-sonnet-5-5", "claude-sonnet", "claude-sonnet-5-5", (5, 5)),         # a router's extra segment
    ("anthropic/claude-sonnet-5-0", "claude-sonnet", "claude-sonnet-5-0", (5,)),                      # 5.0 is generation 5
]
UNRECOGNISED = ["openai/gpt-4o", "openai/o3", "openai/o3-mini", "anthropic/claude-sonnet", "example/model", "example/Model-X-latest"]


@pytest.mark.parametrize("model,family,gen,version", FAMILIES)
def test_family_and_generation_alias(model, family, gen, version):
    assert fz.family_of(model) == family
    assert fz.generation_alias(model) == gen
    assert fz.version_of(model) == version
    assert fz.has_family(model) is True


@pytest.mark.parametrize("model", UNRECOGNISED)
def test_an_unrecognised_name_is_its_own_family(model):
    name = model.rsplit("/", 1)[-1]
    assert fz.family_of(model) == name and fz.generation_alias(model) == name and fz.has_family(model) is False


def test_the_family_alias_is_never_a_generation_alias():
    for model, *_ in FAMILIES:
        assert fz.family_of(model) != fz.generation_alias(model)


def test_generations_order_newest_first_by_version_numbers():
    models = ["anthropic/claude-sonnet-4-5", "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-5-5", "anthropic/claude-sonnet-3-7",
              "anthropic/claude-sonnet-10"]
    assert fz.newest_first(models) == ["anthropic/claude-sonnet-10", "anthropic/claude-sonnet-5-5", "anthropic/claude-sonnet-5",
                                       "anthropic/claude-sonnet-4-5", "anthropic/claude-sonnet-3-7"]
    assert fz.newest_first(list(reversed(models))) == fz.newest_first(models)           # the input order never decides


def test_a_tie_in_version_is_broken_by_the_adopted_date_then_the_snapshot():
    a, b = "anthropic/claude-sonnet-5", "openrouter/claude-sonnet-5"
    adopted = {a: "2026-09-01", b: "2026-10-01"}
    assert fz.newest_first([a, b], adopted=lambda m: adopted[m]) == [b, a]
    assert fz.newest_first([b, a], adopted=lambda m: adopted[m]) == [b, a]
    snaps = ["anthropic/claude-sonnet-5-20251101", "anthropic/claude-sonnet-5-20250929"]
    assert fz.newest_first(list(reversed(snaps))) == snaps
    assert fz.generation_key("anthropic/claude-sonnet-5-5") > fz.generation_key("anthropic/claude-sonnet-5", "2030-01-01")   # the version wins


# ------------------------------------------------------------ fixtures

SON = "anthropic/claude-sonnet-"
GENS = {"4-5": "2026-02-01", "5": "2026-06-01", "5-5": "2026-09-01"}
TWO = {"5": "2026-06-01", "5-5": "2026-09-01"}              # within the default of three even after one more


def hosted_entry(name, model, tags=("open", "internal"), cat=None):
    return {"model_name": name, "litellm_params": {"model": model, "api_key": "os.environ/ANTHROPIC_API_KEY", "tags": list(tags)},
            "model_info": {"endpoint_tier": "external", "tockmox_catalog": cat or model.replace("/", "-")}}


def gateway(gens=GENS, current="5-5", extra=()):
    """The production gateway: a floating claude-sonnet on `current`, one pinned entry per generation, and an unrelated local route."""
    g = [{"model_name": "local-medium", "litellm_params": {"model": "openai/example", "api_base": "http://192.0.2.10:8080/v1"},
          "model_info": {"endpoint_tier": "local"}},
         hosted_entry("claude-sonnet", SON + current)]
    g += [hosted_entry("claude-sonnet-" + v, SON + v) for v in sorted(gens, key=lambda v: fz.generation_key(SON + v))]
    return g + list(extra)


def catalog_doc(gens=GENS, candidate=None, keep=None):
    cat = [{"id": "anthropic-claude-sonnet-" + v, "model": SON + v, "adopted": d, "source": {"kind": "hosted", "ref": SON + v}}
           for v, d in gens.items()]
    if candidate:
        cat.append({"id": "anthropic-claude-sonnet-" + candidate, "model": SON + candidate, "stage": "candidate",
                    "source": {"kind": "hosted", "ref": SON + candidate}, "track": ["deprecation"]})
    d = lifecycle_doc()
    d["catalog"] += cat
    d["promotion"] = {"requiredPasses": 1}
    if keep is not None:
        d["frontier"] = {"keepGenerations": keep}
    return d


def passes(model, alias="claude-sonnet", n=1):
    return verdicts(*[verdict_record(model, alias, run=f"f{i}") for i in range(n)])


def promote(candidate="6", gens=GENS, keep=None, gw=None, current="5-5", tags=("open",), when="2026-10-30"):
    lc = ml.parse(catalog_doc(gens, candidate, keep))
    gw = gateway(gens, current) if gw is None else gw
    out, notes = ml.promote_hosted("anthropic-claude-sonnet-" + candidate, "claude-sonnet", list(tags), passes(SON + candidate), lc, gw, when)
    return lc, gw, out, notes


def by_name(entries):
    return {e["model_name"]: e for e in entries}


def dump(x):
    return json.dumps(x, sort_keys=True)


# ------------------------------------------------------------ keepGenerations

def test_keep_generations_defaults_to_three_and_comes_from_the_values():
    assert ml.parse({}).keep_generations == 3 and ml.parse({}).keep_generations_set is False
    lc = ml.parse({"frontier": {"keepGenerations": 5}})
    assert lc.keep_generations == 5 and lc.keep_generations_set is True
    assert ml.to_doc(lc)["frontier"] == {"keepGenerations": 5}                            # a change writes back what the site wrote
    assert ml.parse(ml.to_doc(lc)).keep_generations == 5
    assert "frontier" not in ml.to_doc(ml.parse({}))                                       # and invents nothing
    assert ml.parse({"frontier": {"providers": {"anthropic": {"keyEnv": "K"}}, "keepGenerations": 2}}).frontier_providers == {"anthropic": {"keyEnv": "K"}}


@pytest.mark.parametrize("bad", [0, -1, True, "3", 2.5, None])
def test_keep_generations_must_be_a_whole_number_of_one_or_more(bad):
    with pytest.raises(ml.LifecycleError, match="keepGenerations"):
        ml.parse({"frontier": {"keepGenerations": bad}})


def test_keep_generations_survives_a_merge():
    lc = ml.parse(catalog_doc(keep=2))
    assert ml.merge(lc, ml.Lifecycle([])).keep_generations == 2


# ------------------------------------------------------------ promotion: only the family alias moves

def test_a_promotion_moves_only_the_family_alias_and_adds_the_pinned_one():
    lc, gw, out, notes = promote(gens=TWO)
    ents = by_name(out.production_gateway_entries)
    assert set(ents) == {"claude-sonnet-6", "claude-sonnet"} and out.production_gateway_removed == []
    assert ents["claude-sonnet-6"]["litellm_params"]["model"] == SON + "6"
    assert ents["claude-sonnet"]["litellm_params"]["model"] == SON + "6"
    for e in ents.values():
        assert e["litellm_params"]["tags"] == ["open"] and e["litellm_params"]["api_key"] == "os.environ/ANTHROPIC_API_KEY"
        assert e["model_info"]["tockmox_catalog"] == "anthropic-claude-sonnet-6"
    after = by_name(ml.gateway_after(gw, out))
    assert after["claude-sonnet"]["litellm_params"]["model"] == SON + "6"
    moved = [n for n in by_name(gw) if dump(by_name(gw)[n]) != dump(after.get(n))]
    assert moved == ["claude-sonnet"]                                                      # the one existing entry that changed
    assert [n for n in after if n not in by_name(gw)] == ["claude-sonnet-6"]               # plus the one new pinned alias
    assert any("only existing entry whose model changes" in n for n in notes)
    e = out.entry("anthropic-claude-sonnet-6")
    assert e.stage == "promoted" and e.promotion["alias"] == "claude-sonnet" and e.promotion["generation"] == "claude-sonnet-6"
    assert e.promotion["from"] == SON + "5-5" and e.promotion["date"] == "2026-10-30" and e.promotion["tags"] == ["open"]
    assert ml.check_promotions(out, __import__("app.nodes", fromlist=["x"]).parse_inventory({"nodes": [], "routes": []})) == []


def test_a_pinned_entry_is_never_rewritten():
    gw = gateway(TWO)
    planted = copy.deepcopy(gw)
    lc, _gw, out, _notes = promote(gens=TWO, gw=gw)
    after = ml.gateway_after(gw, out)
    for name in ("claude-sonnet-5-5", "claude-sonnet-5", "local-medium"):
        assert dump(by_name(after)[name]) == dump(by_name(planted)[name])                  # byte-identical
        assert by_name(after)[name] is by_name(gw)[name]                                   # the very same entry
    assert gw == planted                                                                   # and the input was not touched
    assert not {"claude-sonnet-5-5", "claude-sonnet-5"} & {e["model_name"] for e in out.production_gateway_entries}
    # and when a fourth generation drops the oldest, the generations that stay are still byte-identical
    gw3 = gateway()
    planted3 = copy.deepcopy(gw3)
    _lc, _g, out3, _n = promote(gw=gw3)
    after3 = by_name(ml.gateway_after(gw3, out3))
    assert "claude-sonnet-4-5" not in after3
    for name in ("claude-sonnet-5-5", "claude-sonnet-5"):
        assert dump(after3[name]) == dump(by_name(planted3)[name])


def test_a_planted_pinned_entry_for_the_promoted_model_is_kept_as_it_is():
    planted = hosted_entry("claude-sonnet-6", SON + "6", tags=("internal",))
    gw = gateway(TWO) + [planted]
    lc, _gw, out, notes = promote(gens=TWO, gw=gw, tags=("open",))
    assert [e["model_name"] for e in out.production_gateway_entries] == ["claude-sonnet"]
    assert dump(by_name(ml.gateway_after(gw, out))["claude-sonnet-6"]) == dump(planted)
    assert any("already on the production gateway and stays exactly as it is" in n for n in notes)


def test_a_pinned_alias_that_names_another_model_is_refused_not_rewritten():
    gw = gateway(TWO) + [hosted_entry("claude-sonnet-6", SON + "5")]
    with pytest.raises(ml.LifecycleError, match="never moves"):
        promote(gens=TWO, gw=gw)


def test_the_first_promotion_of_a_family_creates_both_entries():
    lc, gw, out, notes = promote(gens={}, gw=[], current="6")
    assert by_name(out.production_gateway_entries).keys() == {"claude-sonnet", "claude-sonnet-6"}
    assert any("claude-sonnet is new" in n for n in notes) and out.production_gateway_removed == []


def test_the_family_alias_keeps_what_the_operator_wrote_on_it():
    gw = gateway(TWO)
    by_name(gw)["claude-sonnet"]["litellm_params"]["rpm"] = 120
    lc, _gw, out, notes = promote(gens=TWO, gw=gw, tags=("open", "internal"))
    fam = by_name(out.production_gateway_entries)["claude-sonnet"]
    assert fam["litellm_params"]["rpm"] == 120 and fam["litellm_params"]["model"] == SON + "6"
    assert "rpm" not in by_name(out.production_gateway_entries)["claude-sonnet-6"]["litellm_params"]


def test_a_different_set_of_tags_on_the_family_alias_is_said():
    lc, gw, out, notes = promote(gens=TWO, tags=("open",))
    assert any("carried the tags open, internal and now carries open" in n for n in notes)


def test_promoting_under_the_pinned_alias_is_refused():
    lc = ml.parse(catalog_doc(candidate="6"))
    with pytest.raises(ml.LifecycleError, match="never moves"):
        ml.promote_hosted("anthropic-claude-sonnet-6", "claude-sonnet-6", ["open"], passes(SON + "6", "claude-sonnet-6"), lc, gateway())


def test_the_comparison_and_tag_gates_still_apply_to_a_family_promotion():
    lc = ml.parse(catalog_doc(candidate="6"))
    eid = "anthropic-claude-sonnet-6"
    with pytest.raises(ml.LifecycleError, match="tag"):
        ml.promote_hosted(eid, "claude-sonnet", [], passes(SON + "6"), lc, gateway())
    with pytest.raises(ml.LifecycleError, match="no passing comparison"):
        ml.promote_hosted(eid, "claude-sonnet", ["open"], [], lc, gateway())
    lc.required_passes = 3
    with pytest.raises(ml.LifecycleError, match="1 of 3"):
        ml.promote_hosted(eid, "claude-sonnet", ["open"], passes(SON + "6"), lc, gateway())


def test_an_older_generation_promoted_under_the_family_alias_says_it_moves_back():
    lc = ml.parse(catalog_doc({"5": "2026-06-01", "5-5": "2026-09-01"}, candidate="4-5"))
    out, notes = ml.promote_hosted("anthropic-claude-sonnet-4-5", "claude-sonnet", ["open"], passes(SON + "4-5"), lc, gateway({"5": "", "5-5": ""}))
    assert any("moves claude-sonnet back" in n for n in notes) and out.production_gateway_removed == []


def test_other_aliases_are_promoted_the_way_they_always_were():
    lc = ml.parse(catalog_doc(candidate="6"))
    out, notes = ml.promote_hosted("anthropic-claude-sonnet-6", "frontier-chat", ["open"], passes(SON + "6", "frontier-chat"), lc,
                                   gateway() + [hosted_entry("frontier-chat", SON + "5")])
    assert [e["model_name"] for e in out.production_gateway_entries] == ["frontier-chat"] and out.production_gateway_removed == []
    assert any("already has frontier-chat" in n for n in notes)
    out2, _ = ml.promote_hosted("anthropic-claude-sonnet-6", "frontier-chat", ["open"], passes(SON + "6", "frontier-chat"), lc, {"frontier-chat"})
    assert [e["model_name"] for e in out2.production_gateway_entries] == ["frontier-chat"]       # a bare set of names still works


# ------------------------------------------------------------ promotion: keepGenerations, a fourth generation

def test_a_fourth_generation_renders_the_change_that_drops_the_oldest():
    lc, gw, out, notes = promote(candidate="6")
    assert out.production_gateway_removed == ["claude-sonnet-4-5"]
    old = out.entry("anthropic-claude-sonnet-4-5")
    assert old.stage == "retired" and old.retirement == {"reason": "fell off keepGenerations", "date": "2026-10-30"}
    assert old.as_dict()["retirement"]["reason"] == "fell off keepGenerations"
    after = by_name(ml.gateway_after(gw, out))
    assert set(after) == {"local-medium", "claude-sonnet", "claude-sonnet-6", "claude-sonnet-5-5", "claude-sonnet-5"}
    assert after["claude-sonnet"]["litellm_params"]["model"] == SON + "6"                  # never the one being promoted
    joined = " | ".join(notes)
    assert "claude-sonnet keeps 3 generation(s)" in joined and "claude-sonnet-4-5 falls off the end of the list" in joined
    assert "fell off keepGenerations, 2026-10-30" in joined
    assert "anything that calls claude-sonnet-4-5 by name will fail" in joined and "move those callers to a newer generation first" in joined
    for n in ("5-5", "5"):                                                                  # the others stay promoted, untouched
        assert out.entry("anthropic-claude-sonnet-" + n).stage == "promoted"
    assert ml.parse(ml.to_doc(out)).entry("anthropic-claude-sonnet-4-5").retirement["date"] == "2026-10-30"      # it round-trips through the values


def test_three_generations_and_a_promotion_within_the_limit_drops_nothing():
    lc, gw, out, notes = promote(gens={"5": "2026-06-01", "5-5": "2026-09-01"}, candidate="6")
    assert out.production_gateway_removed == [] and not any("falls off" in n for n in notes)


def test_keep_generations_from_the_values_sets_where_the_list_ends():
    _lc, _gw, out, _n = promote(keep=4)
    assert out.production_gateway_removed == []                                              # 3 kept + 1 = 4, within 4
    _lc, gw, out, notes = promote(keep=2)
    assert out.production_gateway_removed == ["claude-sonnet-4-5", "claude-sonnet-5"]       # oldest first; two leave to keep two
    assert {n for n in by_name(ml.gateway_after(gw, out)) if n.startswith("claude-sonnet-")} == {"claude-sonnet-5-5", "claude-sonnet-6"}
    assert sum("falls off the end of the list" in n for n in notes) == 2
    _lc, gw, out, _n = promote(keep=1)
    assert [n for n in by_name(ml.gateway_after(gw, out)) if n.startswith("claude-sonnet-")] == ["claude-sonnet-6"]


def test_the_oldest_is_decided_by_version_not_by_the_order_of_the_list():
    gw = list(reversed(gateway()))
    _lc, _gw, out, _n = promote(gw=gw)
    assert out.production_gateway_removed == ["claude-sonnet-4-5"]


def test_the_generation_being_promoted_is_never_the_one_dropped():
    lc = ml.parse(catalog_doc({"5": "2026-06-01", "5-5": "2026-09-01", "6": "2026-10-01"}, candidate="4-5", keep=3))
    out, notes = ml.promote_hosted("anthropic-claude-sonnet-4-5", "claude-sonnet", ["open"], passes(SON + "4-5"), lc,
                                   gateway({"5": "", "5-5": "", "6": ""}, current="6"))
    assert out.production_gateway_removed == ["claude-sonnet-5"]                            # the oldest of the others, not the one promoted
    assert by_name(ml.gateway_after(gateway({"5": "", "5-5": "", "6": ""}, current="6"), out))["claude-sonnet"]["litellm_params"]["model"] == SON + "4-5"


def test_a_dropped_generation_with_no_catalog_entry_is_dropped_and_said():
    lc = ml.parse(catalog_doc({"5": "2026-06-01", "5-5": "2026-09-01"}, candidate="6", keep=2))
    out, notes = ml.promote_hosted("anthropic-claude-sonnet-6", "claude-sonnet", ["open"], passes(SON + "6"), lc, gateway({"4-5": "", "5": "", "5-5": ""}))
    assert out.production_gateway_removed == ["claude-sonnet-4-5", "claude-sonnet-5"]
    assert any("has no catalog entry to mark" in n for n in notes)


def test_a_family_is_counted_alone():
    other = [hosted_entry("claude-haiku-4-5", "anthropic/claude-haiku-4-5"), hosted_entry("claude-haiku-4", "anthropic/claude-haiku-4"),
             hosted_entry("claude-haiku-3-5", "anthropic/claude-haiku-3-5"), hosted_entry("claude-haiku", "anthropic/claude-haiku-4-5")]
    _lc, gw, out, _n = promote(gw=gateway(extra=other))
    assert out.production_gateway_removed == ["claude-sonnet-4-5"]                          # no haiku entry is a candidate to drop


# ------------------------------------------------------------ the retire change

def retire(alias, gw=None, lc=None, **kw):
    lc = lc or ml.parse(catalog_doc())
    return ml.retire_generation(alias, lc, gateway() if gw is None else gw, kw.pop("when", "2026-10-30"), **kw)


def test_retiring_a_generation_removes_its_entry_and_marks_it_retired():
    out, notes = retire("claude-sonnet-4-5", provider_date="2026-11-10")
    assert out.production_gateway_removed == ["claude-sonnet-4-5"] and out.production_gateway_entries == []
    e = out.entry("anthropic-claude-sonnet-4-5")
    assert e.stage == "retired" and e.retirement == {"reason": "retired by its provider (2026-11-10)", "date": "2026-10-30"}
    after = by_name(ml.gateway_after(gateway(), out))
    assert "claude-sonnet-4-5" not in after and after["claude-sonnet"]["litellm_params"]["model"] == SON + "5-5"      # the family is untouched
    for n in ("claude-sonnet-5", "claude-sonnet-5-5"):
        assert dump(after[n]) == dump(by_name(gateway())[n])
    assert any("claude-sonnet is not touched and still points at " + SON + "5-5" in n for n in notes)
    assert any("move those callers to a newer generation first" in n for n in notes)


def test_the_generation_the_family_alias_points_at_is_not_retired_until_a_newer_one_is_promoted():
    lc = ml.parse(catalog_doc(candidate="6"))
    with pytest.raises(ml.LifecycleError) as ex:
        ml.retire_generation("claude-sonnet-5-5", lc, gateway(), "2026-10-30")
    msg = str(ex.value)
    assert "claude-sonnet currently points at " + SON + "5-5" in msg and "promote " + SON + "6 first" in msg
    assert "/models/promote-hosted?entry=anthropic-claude-sonnet-6" in msg
    with pytest.raises(ml.LifecycleError, match="promote anthropic/claude-sonnet-6 first"):
        ml.retire_generation("claude-sonnet-5-5", ml.parse(catalog_doc()), gateway(), "2026-10-30", replacement="anthropic/claude-sonnet-6")
    with pytest.raises(ml.LifecycleError, match="promote a newer generation of claude-sonnet first"):
        retire("claude-sonnet-5-5")
    # once the family alias has moved, the same retire is allowed
    out, _ = retire("claude-sonnet-5-5", gw=gateway(current="6", gens={**GENS, "6": "2026-10-30"}))
    assert out.production_gateway_removed == ["claude-sonnet-5-5"]


def test_only_a_pinned_generation_can_be_retired():
    with pytest.raises(ml.LifecycleError, match="family alias"):
        retire("claude-sonnet")
    with pytest.raises(ml.LifecycleError, match="not a pinned generation alias"):
        retire("frontier-chat", gw=gateway(extra=[hosted_entry("frontier-chat", SON + "5")]))
    with pytest.raises(ml.LifecycleError, match="no entry"):
        retire("nope")
    with pytest.raises(ml.LifecycleError, match="not a pinned generation alias"):
        retire("local-medium")


def test_retiring_a_generation_with_no_catalog_entry_says_so():
    out, notes = retire("claude-sonnet-4-5", lc=ml.parse(lifecycle_doc()))
    assert out.production_gateway_removed == ["claude-sonnet-4-5"] and any("no catalog entry" in n for n in notes)


# ------------------------------------------------------------ the pages

def gw_lifecycle(candidate=None, keep=None, extra_gens=None):
    d = catalog_doc({**GENS, **(extra_gens or {})}, candidate, keep)
    return d


def report(tmp_path, when, model=SON + "4-5", replacement=SON + "6"):
    dep = cand("deprecation", model, subject="anthropic", detail="anthropic retires claude-sonnet-4-5", when=when, replacement=replacement)
    return write_report(tmp_path, [dep])


def text(r):
    return html.unescape(r.text)


def plain(r):
    """The page as a reader sees it, a space where a tag was, so cells and spans do not run together."""
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(re.sub(r"<svg.*?</svg>", "", r.text, flags=re.S)))).strip()


def test_the_family_alias_page_shows_where_it_points_the_generations_kept_and_how_to_pin(tmp_path):
    d = gw_lifecycle()
    d["catalog"][-1]["promotion"] = {"alias": "claude-sonnet", "from": SON + "5", "class": "chat", "required": 1, "date": "2026-10-14",
                                     "pr": "https://forge.example/o/r/pull/152",
                                     "evidence": [{"path": "evals/verdicts/r1.json", "sha256": "a" * 64, "runId": "r1", "date": "2026-10-13",
                                                   "verdict": "pass", "grader": "rule"}]}
    c, u = page_client(tmp_path, lifecycle=d, gateway=gateway())
    r = c.get("/models/a/claude-sonnet")
    assert r.status_code == 200
    t = plain(r)
    assert "What it points to now" in t and "Floating alias claude-sonnet" in t and "Current generation claude-sonnet-5-5" in t
    assert "Since 2026-10-14" in t and 'href="https://forge.example/o/r/pull/152"' in r.text and "Moved from " + SON + "5" in t
    assert "Generations kept" in t and "up to 3 per family" in t and "modelLifecycle.frontier.keepGenerations" in t
    pos = [t.index(a) for a in ("claude-sonnet-5-5 " + SON, "claude-sonnet-5 " + SON + "5 ", "claude-sonnet-4-5 " + SON + "4-5")]
    assert pos == sorted(pos)                                                               # newest first
    assert "not recorded yet" not in t and "Spend this month" not in t                       # TM-1298: figures, or unknown with why
    assert "Price per 1M tokens, in / out" in t and t.count("unknown") >= 10 and "never an estimate" in t
    assert "Current" in t and "Kept" in t
    for g in ("claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-5"):
        assert f'href="/models/a/{g}"' in r.text
    assert "Pin a generation" in t and "That alias never moves" in t and 'model = "claude-sonnet-4-5"' in t and 'model = "claude-sonnet"' in t
    assert "floating: today claude-sonnet-5-5" in t
    assert "Promotion record" in t and "Class chat" in t and 'href="/models/v/r1"' in r.text
    assert "style=" not in r.text and "onclick" not in r.text and "<script" not in r.text


def test_the_family_alias_page_counts_down_a_retiring_generation_and_offers_the_retire_change(tmp_path):
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gateway(), report=report(tmp_path, day(12)), candidates=[])
    r = c.get("/models/a/claude-sonnet")
    t = plain(r)
    assert "Retiring" in t and "retires in 12 days" in t
    assert 'action="/models/a/claude-sonnet-4-5/retire"' in r.text and "Show the retire change" in t
    assert 'action="/models/a/claude-sonnet-5/retire"' not in r.text


def test_the_current_generation_retiring_asks_for_a_promotion_first(tmp_path):
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gateway(), report=report(tmp_path, day(12), model=SON + "5-5"), candidates=[])
    t = plain(c.get("/models/a/claude-sonnet"))
    assert "retires in 12 days" in t and "Promote a newer generation before this one can be retired" in t
    assert 'action="/models/a/claude-sonnet-5-5/retire"' not in c.get("/models/a/claude-sonnet").text


def test_the_family_page_says_when_more_generations_are_on_the_gateway_than_are_kept(tmp_path):
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(keep=2), gateway=gateway())
    t = plain(c.get("/models/a/claude-sonnet"))
    assert "up to 2 per family" in t and "Over the limit" in t and "3 pinned generations are on the gateway and 2 are kept" in t


def test_generations_that_left_are_listed_with_why(tmp_path):
    d = gw_lifecycle()
    d["catalog"].append({"id": "anthropic-claude-sonnet-4", "model": SON + "4", "stage": "retired", "source": {"kind": "hosted", "ref": SON + "4"},
                         "retirement": {"reason": "fell off keepGenerations", "date": "2026-10-20"}})
    c, u = page_client(tmp_path, lifecycle=d, gateway=gateway())
    t = plain(c.get("/models/a/claude-sonnet"))
    assert "Generations that left" in t and SON + "4 fell off keepGenerations 2026-10-20" in t


def test_a_pinned_alias_page_says_which_family_it_belongs_to_and_that_it_never_moves(tmp_path):
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gateway())
    t = plain(c.get("/models/a/claude-sonnet-5"))
    assert "Pinned generation" in t and "never moves" in t and 'href="/models/a/claude-sonnet"' in c.get("/models/a/claude-sonnet-5").text
    assert "claude-sonnet follows " + SON + "5-5 today, not this one" in t
    assert "claude-sonnet follows it today" in plain(c.get("/models/a/claude-sonnet-5-5"))
    assert "Show the retire change" not in t                                                  # no countdown, no action


def test_a_plain_hosted_alias_is_not_a_family_or_a_pinned_page(tmp_path):
    gw = [hosted_entry("frontier-chat", SON + "5")]
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gw)
    r = c.get("/models/a/frontier-chat")
    assert r.status_code == 200 and "Routes to the hosted model" in r.text and "Pinned generation" not in r.text and "Generations kept" not in r.text


def test_the_retire_change_for_a_pinned_generation(tmp_path):
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gateway(), report=report(tmp_path, day(12)), candidates=[])
    a = text(c.get("/models/a/claude-sonnet-4-5"))
    assert "Show the retire change" in a and "retires in 12 days" in a
    r = c.post("/models/a/claude-sonnet-4-5/retire", data={"csrf": u.csrf})
    assert r.status_code == 200
    t = text(r)
    assert "Retire claude-sonnet-4-5" in t and "Nothing has changed yet" in t and "Remove this entry" in t and "<li><code>claude-sonnet-4-5</code></li>" in t
    assert "marked retired" in t and "move those callers to a newer generation first" in t
    y = yaml.safe_load(c.post("/models/a/claude-sonnet-4-5/retire", data={"csrf": u.csrf, "fmt": "yaml"}).text)
    e = next(x for x in y["modelLifecycle"]["catalog"] if x["id"] == "anthropic-claude-sonnet-4-5")
    assert e["stage"] == "retired" and e["retirement"]["reason"].startswith("retired by its provider (") and re.match(r"\d{4}-\d{2}-\d{2}$", e["retirement"]["date"])


def test_the_retire_change_refuses_the_current_generation_and_says_what_to_promote(tmp_path):
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(candidate="6"), gateway=gateway(), report=report(tmp_path, day(12), model=SON + "5-5"), candidates=[])
    r = c.post("/models/a/claude-sonnet-5-5/retire", data={"csrf": u.csrf})
    assert r.status_code == 400
    t = plain(r)
    assert "Not retired" in t and "claude-sonnet currently points at " + SON + "5-5" in t and "promote " + SON + "6 first" in t


def test_the_retire_route_is_admin_only_csrf_checked_and_hosted_only(tmp_path):
    c, u = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gateway())
    assert c.post("/models/a/claude-sonnet-4-5/retire", data={"csrf": "wrong"}).status_code == 400
    assert c.post("/models/a/nope/retire", data={"csrf": u.csrf}).status_code == 404
    assert c.post("/models/a/local-medium/retire", data={"csrf": u.csrf}).status_code == 404
    assert c.post("/models/a/claude-sonnet/retire", data={"csrf": u.csrf}).status_code == 400            # a family alias is moved, not retired
    c2, u2 = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gateway(), groups=["tockmox-users"])
    assert c2.post("/models/a/claude-sonnet-4-5/retire", data={"csrf": u2.csrf}).status_code == 403


def test_the_inbox_row_for_a_retiring_pinned_generation_offers_the_retire_change(tmp_path):
    dep = cand("deprecation", SON + "4-5", subject="anthropic", detail="anthropic retires claude-sonnet-4-5", when=day(12), replacement=SON + "6")
    c, u = page_client(tmp_path, candidates=[dep], lifecycle=gw_lifecycle(), gateway=gateway())
    r = c.get("/models/inbox")
    assert 'action="/models/a/claude-sonnet-4-5/retire"' in r.text and "Retire claude-sonnet-4-5" in plain(r)
    dep2 = cand("deprecation", "anthropic/example-old-3", subject="anthropic", detail="x", when=day(12))
    c2, _u = page_client(tmp_path, candidates=[dep2], lifecycle=gw_lifecycle(), gateway=gateway())
    assert "/retire" not in c2.get("/models/inbox").text                                          # a model that is not a pinned generation


def test_the_promote_page_defaults_to_the_family_alias_and_explains_what_it_does(tmp_path):
    d = gw_lifecycle(candidate="6")
    d["verdictsDir"] = write_verdicts(tmp_path, *[verdict_record(SON + "6", "claude-sonnet", run="h0")])
    c, u = page_client(tmp_path, lifecycle=d, gateway=gateway())
    t = plain(c.get("/models/promote-hosted?entry=anthropic-claude-sonnet-6"))
    assert 'value="claude-sonnet"' in c.get("/models/promote-hosted?entry=anthropic-claude-sonnet-6").text
    assert "Under the family alias claude-sonnet" in t and "adds the pinned alias claude-sonnet-6" in t and "A family keeps 3 generation(s)" in t
    assert "1 of 1" in t


def gateway_section(t):
    """What the change page says the production gateway will get (the values blocks below it carry the site's own list unchanged)."""
    return t.split("What the production gateway will get", 1)[1].split("The values blocks", 1)[0]


def test_a_fourth_generation_through_the_promote_page_renders_the_drop(tmp_path):
    d = gw_lifecycle(candidate="6")
    d["verdictsDir"] = write_verdicts(tmp_path, verdict_record(SON + "6", "claude-sonnet", run="h0"))
    c, u = page_client(tmp_path, lifecycle=d, gateway=gateway())
    form = {"csrf": u.csrf, "entry": "anthropic-claude-sonnet-6", "target": "claude-sonnet", "tags": "open"}
    t = text(c.post("/models/promote-hosted", data=form))
    assert "What the production gateway will get" in t and "model_name: claude-sonnet-6" in t and "model_name: claude-sonnet\n" in t
    assert "Remove this entry" in t and "<li><code>claude-sonnet-4-5</code></li>" in t
    assert "falls off the end of the list" in t and "move those callers to a newer generation first" in t
    g = gateway_section(t)
    assert "model_name: claude-sonnet-5-5" not in g and "model_name: claude-sonnet-5\n" not in g           # the kept pinned entries are not in the change
    y = yaml.safe_load(c.post("/models/promote-hosted", data={**form, "fmt": "yaml"}).text)
    cat = {x["id"]: x for x in y["modelLifecycle"]["catalog"]}
    assert cat["anthropic-claude-sonnet-4-5"]["stage"] == "retired" and cat["anthropic-claude-sonnet-4-5"]["retirement"]["reason"] == "fell off keepGenerations"
    assert cat["anthropic-claude-sonnet-6"]["stage"] == "promoted" and cat["anthropic-claude-sonnet-5-5"]["stage"] == "promoted"
    assert "keepGenerations" not in json.dumps(y["modelLifecycle"].get("frontier", {}))                       # the site never wrote it, the change does not either


def test_the_change_carries_keep_generations_when_the_site_wrote_it(tmp_path):
    d = gw_lifecycle(candidate="6", keep=2)
    d["verdictsDir"] = write_verdicts(tmp_path, verdict_record(SON + "6", "claude-sonnet", run="h0"))
    c, u = page_client(tmp_path, lifecycle=d, gateway=gateway())
    y = yaml.safe_load(c.post("/models/promote-hosted", data={"csrf": u.csrf, "entry": "anthropic-claude-sonnet-6", "target": "claude-sonnet",
                                                              "tags": "open", "fmt": "yaml"}).text)
    assert y["modelLifecycle"]["frontier"]["keepGenerations"] == 2
    t = text(c.post("/models/promote-hosted", data={"csrf": u.csrf, "entry": "anthropic-claude-sonnet-6", "target": "claude-sonnet", "tags": "open"}))
    assert "These entries" not in t and t.count("falls off the end of the list") == 2 and "Remove these entries" in t

# SPDX-License-Identifier: Apache-2.0
"""TM-1296, the Models page revision 2: a Needs-you strip (exceptions only, one action each), Local models grouped by inference node
with each deployment's tunings, Frontier models grouped by provider and family, and the catalog and the upstream sources folded to one
line each. Build drift is on the node page (test_models_drift.py). Run from tockmox-ui/: python -m pytest tests"""
import html
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import frontier as fr  # noqa: E402
from tests.models_support import SHA_A, inventory_doc, lifecycle_doc, verdict_record  # noqa: E402
from tests.pages_support import (CANDIDATES, HOSTED_GATEWAY, HOSTED_NEW, HOSTED_OLD, REPO, SUCC, day, iso, leg, page_client, status,  # noqa: E402
                                 write_status)
from tests.proto_support import write_verdicts  # noqa: E402

FRONTIER_CHAT = {"model_name": "frontier-chat", "litellm_params": {"model": "anthropic/claude-sonnet-5-5", "api_key": "os.environ/K"},
                 "model_info": {"endpoint_tier": "external"}}


def plain(r):
    """The page as a reader sees it: no tags, one space between words."""
    t = r.text if hasattr(r, "text") else r
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", html.unescape(re.sub(r"<svg.*?</svg>", "", t, flags=re.S)))).strip()


def spaced(t):
    """Like plain(), with a space where a tag was: for a line of badges and spans, read word by word."""
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(re.sub(r"<svg.*?</svg>", "", t, flags=re.S)))).strip()


def inventory(extra_routes=()):
    """alpha (256 GiB): local-medium live on mlx-lm :8080 with tunings, local-medium-next beside it on :8082, a llama-server embedding
    with nothing stated; beta (64 GiB): local-embed. A second candidate moves the embedding model from beta to alpha."""
    d = inventory_doc()
    d["routes"] = [
        {"alias": "local-medium", "model": REPO, "node": "alpha", "endpoint": "mlx-lm-8080", "sizeGiB": 15.0,
         "modelInfo": {"max_input_tokens": 32768},
         "params": {"max_tokens": 8192, "extra_body": {"chat_template_kwargs": {"enable_thinking": False}}}},
        {"alias": "local-medium-next", "model": SUCC, "node": "alpha", "endpoint": "mlx-lm-8082", "sizeGiB": 17.0},
        {"alias": "local-embed", "model": "example-embed-4b-q8", "node": "beta", "endpoint": "llama-8081", "kind": "embedding", "sizeGiB": 4.0},
        *extra_routes]
    return d


def lifecycle(**extra):
    d = lifecycle_doc()
    d["catalog"] = d["catalog"] + [
        {"id": "claude-sonnet-5-5", "model": "anthropic/claude-sonnet-5-5", "adopted": "2026-10-07", "stage": "promoted",
         "source": {"kind": "hosted", "ref": "anthropic/claude-sonnet-5-5"}},
        {"id": "claude-sonnet-5", "model": "anthropic/claude-sonnet-5", "adopted": "2026-10-07", "stage": "promoted",
         "source": {"kind": "hosted", "ref": "anthropic/claude-sonnet-5"}},
        {"id": "claude-opus-5-5", "model": "anthropic/claude-opus-5-5", "stage": "candidate", "track": ["deprecation"],
         "source": {"kind": "hosted", "ref": "anthropic/claude-opus-5-5"}},
        {"id": "gpt-5-1", "model": "openai/gpt-5.1", "adopted": "2026-10-07", "stage": "promoted",
         "source": {"kind": "hosted", "ref": "openai/gpt-5.1"}},
    ]
    d.update(extra)
    return d


def rich_client(tmp_path, *, passes=1, candidates=None, running=True, gateway=(FRONTIER_CHAT,), inv=None, **lc_extra):
    """Every kind of exception at once: candidates in the Inbox, a hosted model retiring, a candidate short of its count, and a run in
    progress, with local models on two nodes and hosted models from three providers."""
    cands = candidates if candidates is not None else [CANDIDATES["quant"], CANDIDATES["successor"],
                                                       {**CANDIDATES["deprecation"], "model": "anthropic/claude-sonnet-5-5",
                                                        "source": {"kind": "hosted", "ref": "anthropic/claude-sonnet-5-5"},
                                                        "when": day(12), "replacement": HOSTED_NEW}]
    extra = dict(lc_extra)
    extra["verdictsDir"] = write_verdicts(tmp_path, *[
        verdict_record(SUCC, "local-medium", run=f"r{i}", date=f"2026-10-0{i + 1}", incumbent=REPO) for i in range(passes)])
    sdir = tmp_path / "status"
    if running:
        write_status(sdir, status(state="running", legs=[leg("control", "done"), leg("smoke", "done"), leg("perf", "running"),
                                                         leg("quality", "queued")]))
    return page_client(tmp_path, candidates=cands, lifecycle=lifecycle(), inventory={**(inv or inventory()), "gateway": {"modelList": list(gateway)}},
                       status_dir=sdir, **extra)


def strip_items(t):
    """{kind: <li> html} for the Needs-you strip, in page order."""
    sec = t.split('id="needs-h"', 1)[1].split("</section>", 1)[0]
    return {m.group(1): m.group(0) for m in re.finditer(r'<li class="need-(\w+)">.*?</li>', sec, re.S)}


def actions(li):
    return re.findall(r'<a class="btn-ghost" href="([^"]+)">(.*?)</a>', li, re.S)


# ------------------------------------------------------------ Needs you

def test_the_strip_lists_each_exception_with_its_one_action(tmp_path):
    c, u = rich_client(tmp_path)
    t = c.get("/models").text
    items = strip_items(t)
    assert list(items) == ["retiring", "inbox", "count", "running"]
    assert "3 new candidates" in plain(items["inbox"]) and actions(items["inbox"]) == [("/models/inbox", "Review")]
    ret = plain(items["retiring"])
    assert "anthropic/claude-sonnet-5-5 retires in 12 days" in ret
    assert actions(items["retiring"])[0][0] == "/models/inbox" and "Evaluate the replacement" in actions(items["retiring"])[0][1]
    assert "local-medium-next: 1 of 3 passing comparisons" in plain(items["count"])
    assert actions(items["count"])[0][0] == "/models/promote?alias=local-medium-next" and "See the count" in actions(items["count"])[0][1]
    run = plain(items["running"])
    assert "local-medium-next: evaluation running, leg 3 of 4 (Performance)" in run
    assert actions(items["running"])[0][0] == "/models/c/local-medium" and "Watch" in actions(items["running"])[0][1]
    assert "Running" in plain(items["running"]) and 'class="ico spin"' in items["running"]
    for kind, li in items.items():
        assert len(actions(li)) == 1, kind                                  # one action each
    assert "4 items" in plain(t.split('id="needs-h"', 1)[1].split("</div>", 1)[0])


def test_a_candidate_with_enough_passes_is_ready_to_promote(tmp_path):
    c, u = rich_client(tmp_path, passes=3, running=False)
    items = strip_items(c.get("/models").text)
    assert "Ready to promote" in plain(items["ready"]) and "count" not in items and "running" not in items
    assert actions(items["ready"])[0][0] == "/models/promote?alias=local-medium-next" and "Promote" in actions(items["ready"])[0][1]


def test_a_retired_model_and_a_hosted_model_with_no_replacement_each_get_one_action(tmp_path):
    dep = {**CANDIDATES["deprecation"], "model": "anthropic/claude-sonnet-5-5", "when": day(-2), "replacement": "",
           "source": {"kind": "hosted", "ref": "anthropic/claude-sonnet-5-5"}}
    c, u = rich_client(tmp_path, candidates=[dep], running=False)
    li = strip_items(c.get("/models").text)["retiring"]
    assert "retired on " + day(-2) in plain(li) and "Retired" in plain(li)
    assert actions(li)[0][0] == "/models/a/frontier-chat" and len(actions(li)) == 1       # the alias page, where the countdown also is


def test_an_empty_strip_renders_nothing(tmp_path):
    # a fresh report with nothing in it, no candidate under evaluation, a passing gate: nothing needs the operator
    c, u = page_client(tmp_path, candidates=[])
    t = c.get("/models").text
    assert 'id="needs-h"' not in t and "Needs you" not in t and 'class="panel needs"' not in t and "needs-head" not in t
    assert 'id="loc-h"' in t and 'id="fr-h"' in t                           # the groups still render


def test_a_failing_promotion_gate_is_on_the_strip_and_opens_the_catalog(tmp_path, monkeypatch):
    # the UI refuses to start on values that fail the gate, so a failure can only be one that appears while it runs: fake the check
    from app import models as ml
    c, u = page_client(tmp_path, candidates=[])
    monkeypatch.setattr(ml, "check_promotions", lambda lc, inv: ["alias local-medium moved without a passing eval"])
    t = c.get("/models").text
    li = strip_items(t).get("gate")
    assert li and "The promotion gate fails. alias local-medium moved without a passing eval" in plain(li)
    assert actions(li) == [("#catalog", "See the catalog")]
    assert '<details class="fold" id="catalog" open>' in t and "Promotion gate fails" in t and "Problem" in spaced(t.split('id="catalog"', 1)[1].split("</summary>", 1)[0])


def test_an_unreadable_inbox_setting_is_an_exception_with_one_action(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], inbox={"snoozed": [{"id": "x", "until": "soon"}]})
    li = strip_items(c.get("/models").text)["inbox_settings"]
    assert "modelLifecycle.inbox.snoozed[0].until must be a date" in plain(li) and actions(li) == [("/models/inbox", "Open the Inbox")]


# ------------------------------------------------------------ Local models, by node

def cards_of(t):
    """{node id: card html} in page order."""
    loc = t.split('id="loc-h"', 1)[1].split('id="fr-h"', 1)[0]
    return {m.group(1): m.group(0) for m in re.finditer(r'<section class="panel flush" aria-labelledby="node-([\w-]+)-h">.*?</section>', loc, re.S)}


def row(card, alias):
    return re.search(r'<tr[^>]*>\s*<th scope="row" class="alias">\s*<a href="[^"]*"><code>' + re.escape(alias) + r'</code>.*?</tr>', card, re.S).group(0)


def test_local_models_are_grouped_by_inference_node_with_counts_and_node_links(tmp_path):
    c, u = rich_client(tmp_path)
    t = c.get("/models").text
    assert list(cards_of(t)) == ["alpha", "beta"]
    assert re.search(r"3 deployments on 2 nodes · 2 serving, 1 candidate", plain(t.split('id="loc-h"', 1)[1].split("</div>", 1)[0]))
    a, b = cards_of(t)["alpha"], cards_of(t)["beta"]
    assert 'href="/nodes/alpha"><code>alpha</code>' in a and 'href="/nodes/beta"><code>beta</code>' in b      # the node id links to its page
    assert "Node details" in a and "Apple M5 Ultra" not in a                                                  # the card names the node type, not the chip
    assert "local-medium" in a and "local-embed" not in a and "local-embed" in b and "local-medium" not in b
    # the memory: planned of total, drawn without a style attribute
    assert "35.2 / 256 GiB" in plain(a) and 'class="mini-bar"' in a and "style=" not in a
    assert 'aria-label="35.2 of 256.0 GiB planned on Alpha' in a


def test_each_deployment_shows_alias_model_build_engine_context_slots_max_output_thinking_and_state(tmp_path):
    c, u = rich_client(tmp_path)
    a = cards_of(c.get("/models").text)["alpha"]
    for h in ("Alias", "Model", "Build", "Engine : port", "Context", "Slots", "Max output", "Thinking", "State"):
        assert f">{h}</th>" in a
    live = row(a, "local-medium")
    cells = [plain(x) for x in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", live, re.S)]
    assert cells[0] == "local-medium" and cells[1] == REPO and cells[2] == SHA_A[:7]
    assert cells[3].endswith(":8080") and cells[4] == "32K" and cells[6] == "8K" and cells[7] == "Off" and cells[8].startswith("Serving")
    assert 'href="/models/a/local-medium"' in live


def test_an_unstated_setting_shows_the_engine_default_labelled_as_one(tmp_path):
    odd = {"alias": "local-plain", "model": "example-org/plain-4bit", "node": "alpha", "endpoint": "llama-8081", "sizeGiB": 8.0}
    c, u = rich_client(tmp_path, inv=inventory([odd]))
    a = cards_of(c.get("/models").text)["alpha"]
    cells = [x for x in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", row(a, "local-plain"), re.S)]
    # llama-server's own context default is known and is shown with what it is; the thinking switch is the template's; slots are not recorded
    assert "engine default" in plain(cells[4]) and "model&#39;s full trained context (-c 0)" in cells[4]
    assert 'class="muted"' in cells[4] and "engine default" in plain(cells[7]) and "template" in cells[7]
    assert plain(cells[5]) == "engine default, not reported"
    # a value the route states is plain, never labelled default
    live = [x for x in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", row(a, "local-medium"), re.S)]
    assert "default" not in live[4] and "default" not in live[6] and "default" not in live[7]
    assert "engine default, not reported" in live[5]                       # slots: Tockmox records none, whoever the route is


def test_a_next_candidate_row_is_marked_and_links_to_the_candidate_page(tmp_path):
    c, u = rich_client(tmp_path)
    a = cards_of(c.get("/models").text)["alpha"]
    cand = row(a, "local-medium-next")
    assert re.search(r'<tr class="cand">\s*<th scope="row" class="alias">\s*<a href="/models/c/local-medium"><code>local-medium-next</code>', cand)
    assert "Candidate -next" in plain(cand) and "candidate for local-medium" in plain(cand) and 'href="/models/a/local-medium"' in cand
    assert SUCC in cand and "Serving" not in plain(cand)
    live = row(a, "local-medium")
    assert 'class="cand"' not in live.split("<th")[0]
    # the live alias comes first, its candidate right after it
    assert a.index("local-medium</code>") < a.index("local-medium-next</code>")


def test_a_replacement_candidate_says_it_moves_the_same_model(tmp_path):
    inv = inventory()
    inv["routes"].append({"alias": "local-embed-next", "model": "example-embed-4b-q8", "node": "alpha", "endpoint": "llama-8081",
                          "kind": "embedding", "sizeGiB": 4.0})
    c, u = rich_client(tmp_path, inv=inv)
    a = cards_of(c.get("/models").text)["alpha"]
    assert "Re-placement" in a and "moving from beta to alpha" in plain(row(a, "local-embed-next"))


def test_the_page_links_to_what_the_settings_mean(tmp_path):
    c, u = rich_client(tmp_path)
    t = c.get("/models").text
    m = re.search(r'<a href="([^"]+)" rel="noopener">What these settings mean</a>', t)
    assert m and m.group(1).endswith("/administration/model-lifecycle.md#tunings")


def test_a_node_with_no_routes_still_has_its_card(tmp_path):
    inv = inventory()
    inv["routes"] = [r for r in inv["routes"] if r["node"] != "beta"]
    c, u = rich_client(tmp_path, inv=inv)
    t = c.get("/models").text
    assert "No model is routed to this node yet." in cards_of(t)["beta"]


# ------------------------------------------------------------ Frontier models, by provider and family

@pytest.mark.parametrize("model,family", [
    ("anthropic/claude-sonnet-5-5", "claude-sonnet"), ("anthropic/claude-sonnet-5", "claude-sonnet"),
    ("anthropic/claude-sonnet-4-5", "claude-sonnet"), ("claude-haiku-4-5", "claude-haiku"), ("anthropic/claude-opus-5-5", "claude-opus"),
    ("anthropic/claude-3-5-sonnet-20241022", "claude-sonnet"),
    ("openai/gpt-5.1", "gpt"), ("openai/gpt-5", "gpt"), ("gemini-2.5-pro", "gemini-pro"), ("google/gemini-2.5-flash", "gemini-flash"),
    # when no part reads as a version, or the name is not made of words and versions, the family is the model id itself
    ("openai/gpt-4o", "gpt-4o"), ("openai/o3-mini", "o3-mini"), ("mistral/mistral-large-latest", "mistral-large-latest"),
    ("anthropic/example-model-9", "example-model"), ("anthropic/example-old-3", "example-old"), ("42", "42"), ("", ""),
])
def test_the_family_is_the_model_id_without_its_version(model, family):
    assert fr.family_of(model) == family


def test_provider_and_ordering_helpers():
    assert fr.provider_of("anthropic/claude-sonnet-5-5") == "anthropic" and fr.provider_of("gemini-2.5-pro") == "other"
    assert fr.provider_name("openai") == "OpenAI" and fr.provider_name("example") == "example"
    ids = ["anthropic/claude-sonnet-4-5", "anthropic/claude-sonnet-5-5", "anthropic/claude-sonnet-5"]
    assert sorted(ids, key=fr.version_key, reverse=True) == ["anthropic/claude-sonnet-5-5", "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4-5"]


def frontier_of(t):
    return t.split('id="fr-h"', 1)[1].split('class="panel folds"', 1)[0]


def test_frontier_models_are_grouped_by_provider_then_family_newest_first(tmp_path):
    c, u = rich_client(tmp_path)
    t = c.get("/models").text
    fp = frontier_of(t)
    heads = re.findall(r'<h3 id="prov-\d+-h">(.*?)</h3>', fp)
    assert heads == ["Anthropic", "OpenAI"]
    anth = fp.split('id="prov-1-h"', 1)[1].split('id="prov-2-h"', 1)[0]
    assert re.findall(r'<tr class="fam"><th scope="rowgroup" colspan="6"><code>([\w-]+)</code>', anth) == ["claude-opus", "claude-sonnet"]
    assert re.findall(r'<tr class="gen">\s*<th scope="row" class="alias">.*?<code>(anthropic/[\w.-]+)</code>', anth, re.S) == [
        "anthropic/claude-opus-5-5", "anthropic/claude-sonnet-5-5", "anthropic/claude-sonnet-5"]
    assert "openai/gpt-5.1" in fp.split('id="prov-2-h"', 1)[1]
    assert "4 models in 3 families · 2 providers" in plain(fp.split("</div>", 1)[0])
    assert "Price and spend are not recorded yet." not in plain(fp)                              # TM-1298 records them


def frow(fp, model):
    """The <tr> of one frontier model: the row whose first <code> (its name) is the model."""
    return next(r for r in re.findall(r'<tr class="gen">.*?</tr>', fp, re.S) if re.search(r"<code>([^<]*)</code>", r).group(1) == model)


def test_a_frontier_row_shows_stage_alias_countdown_and_unknown_price_spend_and_calls(tmp_path):
    c, u = rich_client(tmp_path)
    fp = frontier_of(c.get("/models").text)
    sonnet = frow(fp, "anthropic/claude-sonnet-5-5")
    cells = [plain(x) for x in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", sonnet, re.S)]
    assert cells[1] == "frontier-chat" and 'href="/models/a/frontier-chat"' in sonnet                 # the gateway alias that routes it
    assert "Promoted" in cells[2] and "retires in 12 days" in cells[2]                              # the countdown the page already computes
    assert [x.split(":")[0] for x in cells[3:]] == ["unknown"] * 3                                  # nothing configured: unknown, never 0 (test_frontier_cost.py)
    assert 'href="/models/m/claude-sonnet-5-5"' in sonnet
    assert "not routed" in plain(frow(fp, "anthropic/claude-sonnet-5"))
    for h in ("Price per 1M tokens, in / out", "Spend", "Calls (7 d)"):                              # no spend query is set, so Spend names no window
        assert h in plain(fp)
    assert "Spend this month" not in fp and "Spend (" not in plain(fp)


def test_a_hosted_candidate_row_says_so_and_offers_its_two_actions(tmp_path):
    c, u = rich_client(tmp_path)
    fp = frontier_of(c.get("/models").text)
    opus = frow(fp, "anthropic/claude-opus-5-5")
    assert "Candidate" in plain(opus) and "hosted candidate on the eval gateway, tagged open (public eval data only)" in plain(opus)
    assert 'href="/models/evaluate?entry=claude-opus-5-5"' in opus and 'href="/models/promote-hosted?entry=claude-opus-5-5"' in opus


def test_a_gateway_hosted_model_the_catalog_does_not_know_still_shows(tmp_path):
    gw = [{"model_name": "wild-chat", "litellm_params": {"model": "mistral/mistral-large-latest", "api_key": "os.environ/K"},
           "model_info": {"endpoint_tier": "external"}}]
    c, u = rich_client(tmp_path, gateway=gw)
    fp = frontier_of(c.get("/models").text)
    row_ = frow(fp, "mistral/mistral-large-latest")
    assert "Mistral AI" in fp and "Not in the catalog" in plain(row_) and 'href="/models/a/wild-chat"' in row_


def test_with_no_hosted_model_the_group_says_so(tmp_path):
    c, u = page_client(tmp_path, candidates=[])
    assert "No hosted model is in the catalog or routed by the production gateway." in c.get("/models").text


# ------------------------------------------------------------ the folds

def test_the_catalog_and_the_sources_fold_to_one_line_each(tmp_path):
    c, u = rich_client(tmp_path)
    t = c.get("/models").text
    folds = t.split('class="panel folds"', 1)[1]
    cat, up = folds.split('<details class="fold" id="upstream">', 1)
    # closed unless the gate fails, one summary line each
    assert '<details class="fold" id="catalog">' in cat and "open" not in cat.split(">", 1)[0]
    s_cat = spaced(re.search(r"<summary>.*?</summary>", cat, re.S).group(0))
    assert re.fullmatch(r"OK Catalog \(6 entries\) 5 promoted, 1 candidate", s_cat)
    s_up = spaced(re.search(r"<summary>.*?</summary>", up, re.S).group(0))
    assert s_up.startswith("Answered Upstream sources: 2 answered, last just now") and "huggingface, anthropic" in s_up
    # the detail is inside, unchanged: the table, the gate sentence, the sources
    assert "Promotion gate passes" in cat and 'id="cat-cap"' in cat
    assert '<table>' in cat and "example-27b-4bit" in cat
    assert "last answered" in up and "Report written" in up and "huggingface" in up


def test_a_source_that_did_not_answer_changes_the_sources_line(tmp_path):
    c, u = page_client(tmp_path, candidates=[], sources={"huggingface": {"ok": True}, "anthropic": {"ok": False, "reason": "unreachable"}})
    up = c.get("/models").text.split('<details class="fold" id="upstream">', 1)[1]
    s = spaced(re.search(r"<summary>.*?</summary>", up, re.S).group(0))
    assert s.startswith("No answer Upstream sources: 1 of 2 answered") and "unreachable" in up and "not every upstream answered" in up


def test_no_report_folds_to_not_watching(tmp_path):
    c, u = page_client(tmp_path)
    up = c.get("/models").text.split('<details class="fold" id="upstream">', 1)[1]
    assert spaced(re.search(r"<summary>.*?</summary>", up, re.S).group(0)).startswith("Not watching Upstream sources: not watching")
    assert "No watcher report is configured" in up


# ------------------------------------------------------------ what left the page

def test_the_old_sections_are_gone_from_the_landing_page(tmp_path):
    c, u = rich_client(tmp_path)
    t = c.get("/models").text
    for gone in ("Comparisons in progress", "Builds on the nodes", "Check builds on the nodes", 'class="cands"', "New revisions of models you run",
                 "Newer models in families you run", "Other quantisations of models you run", 'id="watch-h"', 'id="next-h"', 'id="builds-h"'):
        assert gone not in t, gone
    assert 'href="/models/inbox"' in t and 'href="/models/budget"' in t and 'href="/models/profiles"' in t
    assert t.count("/models/recommend?node=") == 2                          # still linked, one per node


def test_the_page_draws_without_inline_styles_scripts_or_handlers(tmp_path):
    c, u = rich_client(tmp_path)
    r = c.get("/models")
    main = r.text.split("<main", 1)[1].split("</main>", 1)[0]
    assert "style=" not in main and "<script" not in main and not re.search(r"\son[a-z]+=", main)
    assert "script-src 'self'" in r.headers["content-security-policy"]


def test_a_stale_run_is_flagged_on_the_strip(tmp_path):
    c, u = rich_client(tmp_path, running=False)
    sdir = tmp_path / "status"
    write_status(sdir, status(state="running", updated=iso(delta_s=-3 * 3600), legs=[leg("control", "running")]))
    items = strip_items(c.get("/models").text)
    assert "it may have stopped" in plain(items["running"])

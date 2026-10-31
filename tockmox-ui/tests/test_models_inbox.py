# SPDX-License-Identifier: Apache-2.0
"""TM-1258 (the Inbox), TM-1265 (the retirement countdown), TM-1300 (Inbox revision 2): the watcher's candidates as one scannable
row each (reason, model and one sentence, best fit, size, one primary action, a menu) with the per-node fit, licence, labelled hints
and admit PR open under the row; filters split local and frontier and show snoozed and dismissed; source health is one line at the
foot. Evaluate, Snooze and Dismiss each render a change and write nothing; a snoozed or dismissed candidate is hidden from the
default view, the Models page, the watcher's report and the PR opener's plan."""
import datetime
import html
import json
import re

import httpx
import pytest
import yaml

from app import inbox as ib
from app import models as ml
from app import pr_opener as po
from app import watcher as wm
from tests.models_support import SHA_B, SHA_C, inventory_doc, lifecycle_doc, models_client
from tests.pages_support import (CANDIDATES, HOSTED_GATEWAY, HOSTED_NEW, HOSTED_OLD, NEW_Q, REPO, SUCC, cand, day, iso, page_client,
                                 size_rec, write_report)

ALL = list(CANDIDATES.values())


def hosted_lifecycle():
    d = lifecycle_doc()
    d["catalog"].append({"id": "example-old-3", "model": HOSTED_OLD, "adopted": "2026-10-07", "source": {"kind": "hosted", "ref": HOSTED_OLD}})
    return d


def text(r):
    return html.unescape(r.text)


def plain(r):
    """The page as a reader sees it: no tags, one space between words."""
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", html.unescape(re.sub(r"<svg.*?</svg>", "", r.text, flags=re.S)))).strip()


# ------------------------------------------------------------ who may see it

def test_every_new_page_is_admin_only_and_posts_need_the_csrf_token(tmp_path):
    c, u = page_client(tmp_path, candidates=ALL, groups=["tockmox-users"])
    for path in ("/models/inbox", "/models/c/local-medium", "/models/budget"):
        assert c.get(path).status_code == 403, path
    for path in ("/models/inbox/snooze", "/models/inbox/dismiss", "/models/v/r1/reject"):
        assert c.post(path, data={"csrf": u.csrf, "cid": ALL[0]["id"], "reason": "x"}).status_code == 403, path
    c2, u2 = page_client(tmp_path, candidates=ALL)
    for path in ("/models/inbox/snooze", "/models/inbox/dismiss"):
        assert c2.post(path, data={"csrf": "wrong", "cid": ALL[0]["id"]}).status_code == 400, path
    anon, _u = page_client(tmp_path, candidates=ALL)
    anon.cookies.clear()
    assert anon.get("/models/inbox").status_code in (302, 303, 307)


# ------------------------------------------------------------ the report's states

def test_no_report_says_not_watching_and_offers_nothing(tmp_path):
    c, u = page_client(tmp_path)
    t = text(c.get("/models/inbox"))
    assert "Not watching" in t and 'class="inbox-row"' not in t and "/models/propose" not in t
    assert "To decide" in t and "(0)" in t


def test_a_stale_report_is_unknown_and_an_empty_list_is_not_called_clean(tmp_path):
    c, u = page_client(tmp_path, candidates=[], generated="2026-01-01T00:00:00Z")
    t = text(c.get("/models/inbox"))
    assert "the watcher may have stopped" in t and "may be out of date or incomplete" in t
    assert "Nothing is listed, but the report is missing, old or incomplete" in t and "Nothing to decide. Everything" not in t


def test_a_fresh_empty_report_says_nothing_to_decide(tmp_path):
    c, u = page_client(tmp_path, candidates=[])
    assert "Nothing to decide. Everything the watcher found is already handled." in text(c.get("/models/inbox"))


def test_a_report_where_a_source_did_not_answer_is_unknown(tmp_path):
    c, u = page_client(tmp_path, candidates=[], sources={"huggingface": {"ok": False, "reason": "unreachable"}})
    assert "Not every upstream answered: huggingface (unreachable)" in text(c.get("/models/inbox"))


# ------------------------------------------------------------ one row per candidate

def rows_of(t):
    """The <li> rows of the list, as text: one per candidate."""
    return t.split('<ul role="list" class="inbox-list">')[1].split("</ul>")[0].split('<li class="inbox-row">')[1:]


def row_of(t, model):
    """The one row that names `model`."""
    return next(li for li in rows_of(t) if f"<code>{model}</code>" in li)


def detail_of(row):
    """What opens under the row."""
    return row.split('class="in-detail"')[1].split('<div class="in-acts">')[0]


def acts_of(row):
    return row.split('<div class="in-acts">')[1]


def models_in(t):
    return re.findall(r"<code>([^<]+)</code><span class=\"in-sentence\"", t)


@pytest.mark.parametrize("kind,tag", [("revision", "New revision"), ("quant", "Other quant"), ("successor", "Successor"),
                                      ("frontier", "Hosted, new"), ("deprecation", "Hosted, retiring")])
def test_each_reason_has_its_tag(tmp_path, kind, tag):
    c, u = page_client(tmp_path, candidates=[CANDIDATES[kind]])
    t = text(c.get("/models/inbox"))
    rows = rows_of(t)
    assert len(rows) == 1 and f'<span class="badge st-info">{tag}</span>' in rows[0] and f"<code>{CANDIDATES[kind]['model']}</code>" in rows[0]
    assert CANDIDATES[kind]["detail"] in rows[0].split('class="in-detail"')[0]          # the one sentence is on the row, not under it
    assert f'name="cid" value="{CANDIDATES[kind]["id"]}"' in rows[0]


def test_the_page_has_real_headings_a_list_role_and_no_inline_script_or_handler(tmp_path):
    c, u = page_client(tmp_path, candidates=ALL)
    t = text(c.get("/models/inbox"))
    assert t.count("<h1>") == 1 and '<h2 id="cards-h">' in t and 'role="list"' in t and 'aria-label="Filter the inbox"' in t
    assert "<script" not in t.lower() and not re.search(r"\son[a-z]+\s*=", t) and "style=" not in t.lower()
    for row in rows_of(t):                                                     # menu and expander are native, so the keyboard works
        assert row.count("<details") == 2 and row.count("<summary") == 2 and "aria-label=\"More actions for " in row


def test_a_row_is_scannable_and_its_details_hold_fit_per_node_licence_and_self_reported_hints(tmp_path):
    sizes = {NEW_Q: size_rec(NEW_Q, 17.0, "apache-2.0", evals=[{"name": "MMLU", "value": "0.81", "dataset": "mmlu"}])}
    c, u = page_client(tmp_path, candidates=[dict(CANDIDATES["quant"], sizeGiB=17.0)], sizes=sizes)
    t = text(c.get("/models/inbox"))
    row = row_of(t, NEW_Q)
    line, detail = row.split('class="in-detail"')[0], detail_of(row)
    assert "Other quant" in line and "another quantisation of example-org/Example-27B" in line and "17.0 GiB" in line
    assert re.search(r"Alpha <span class=\"m\">· fits · ~\d+ tok/s", line)           # the best node, its state and a predicted speed
    for chip in ("Fit: Alpha: fits", "Fit: Beta: ", "Licence: apache-2.0", "Self-reported <em>MMLU 0.81 on mmlu</em>"):
        assert chip in detail and chip not in line
    assert detail.count('class="fchip"') == 2 and re.search(r"model \d+\.\d GiB · 32K x 1 · ~\d+ tok/s predicted", detail)   # GiB, context x slots, speed
    assert "a hint and not a measurement" in detail and "Admit PR" in detail and "None open" in detail


def test_the_best_fit_is_fits_over_tight_over_over_and_then_the_faster_node(tmp_path):
    cq = dict(CANDIDATES["quant"], sizeGiB=17.0)
    sizes = {NEW_Q: size_rec(NEW_Q, 17.0)}
    c, u = page_client(tmp_path, candidates=[cq], sizes=sizes)
    line = row_of(text(c.get("/models/inbox")), NEW_Q).split('class="in-detail"')[0]
    assert "Alpha <span" in line and "Beta <span" not in line                  # both fit: Alpha is faster
    inv = inventory_doc()
    inv["nodes"][0]["hardware"]["memory_gib"]["value"] = 16                    # Alpha is now too small, and still the faster chip
    c, u = page_client(tmp_path, candidates=[cq], sizes=sizes, inventory=inv)
    t = text(c.get("/models/inbox"))
    line, detail = row_of(t, NEW_Q).split('class="in-detail"')[0], detail_of(row_of(t, NEW_Q))
    assert "Beta <span" in line and "· tight ·" in line and "Alpha <span" not in line                # tight beats over, though Alpha is faster
    assert "Fit: Alpha: over" in detail and "Fit: Beta: tight" in detail
    small = dict(CANDIDATES["quant"], sizeGiB=12.0)
    c, u = page_client(tmp_path, candidates=[small], sizes={NEW_Q: size_rec(NEW_Q, 12.0)}, inventory=inv)
    t = text(c.get("/models/inbox"))
    line, detail = row_of(t, NEW_Q).split('class="in-detail"')[0], detail_of(row_of(t, NEW_Q))
    assert "Beta <span" in line and "· fits ·" in line and "Alpha <span" not in line                # fits beats over, though Alpha is faster
    assert "Fit: Alpha: over" in detail and "Fit: Beta: fits" in detail
    big = dict(CANDIDATES["successor"], sizeGiB=400.0)
    c, u = page_client(tmp_path, candidates=[big], sizes={SUCC: size_rec(SUCC, 400.0)})
    line = row_of(text(c.get("/models/inbox")), SUCC).split('class="in-detail"')[0]
    assert re.search(r"Alpha <span class=\"m\">· over", line) and "400.0 GiB" in line   # nothing fits: the best of the overs, said as over


def test_an_unsized_candidate_says_not_sized_yet_a_hosted_one_says_no_node_and_no_size_is_n_a(tmp_path):
    mystery = cand("quant", "example-org/Mystery-model")
    rec = size_rec(mystery["model"], 1.0)
    for k in ("sizeBytes", "paramsB"):
        rec.pop(k, None)
    c, u = page_client(tmp_path, candidates=[mystery, CANDIDATES["frontier"]], sizes={mystery["model"]: rec})
    t = text(c.get("/models/inbox"))
    m, h = row_of(t, mystery["model"]), row_of(t, HOSTED_NEW)
    assert "not sized yet" in m.split('class="in-detail"')[0] and 'class="muted">n/a</span>' in m
    assert "hosted, no node" in h.split('class="in-detail"')[0] and 'class="muted">n/a</span>' in h and "tok/s" not in h


def test_fit_says_over_when_it_does_not_fit_and_unknown_when_it_cannot_say(tmp_path):
    big = cand("quant", "example-org/Example-405B-8bit")
    mystery = cand("quant", "example-org/Mystery-model")
    sizes = {big["model"]: size_rec(big["model"], 400.0), mystery["model"]: size_rec(mystery["model"], 1.0)}
    for k in ("sizeBytes", "paramsB"):                                           # nothing in the record or the name says how big it is
        sizes[mystery["model"]].pop(k, None)
    c, u = page_client(tmp_path, candidates=[big, mystery], sizes=sizes)
    t = text(c.get("/models/inbox"))
    big_fit = detail_of(row_of(t, big["model"])).split('class="chips-row"')[1].split("</p>")[0]
    assert "Fit: Alpha: over" in big_fit and "Fit: Beta: over" in big_fit and big_fit.count("st-critical") == 2 and "st-ok" not in big_fit
    fit_part = detail_of(row_of(t, mystery["model"])).split('class="chips-row"')[1].split("</p>")[0]
    assert "Fit: Alpha: Unknown, its size is not known" in fit_part and "Fit: Beta: Unknown" in fit_part
    assert "st-ok" not in fit_part and "st-unknown" in fit_part and "fits" not in fit_part


def test_a_licence_off_the_allow_list_is_a_problem_and_no_licence_is_unknown(tmp_path):
    a, b = cand("quant", "example-org/Example-9B-4bit"), cand("quant", "example-org/Example-8B-4bit")
    sizes = {a["model"]: size_rec(a["model"], 5.0, "cc-by-nc-4.0"), b["model"]: size_rec(b["model"], 5.0, "")}
    c, u = page_client(tmp_path, candidates=[a, b], sizes=sizes)
    t = text(c.get("/models/inbox"))
    ca, cb = detail_of(row_of(t, a["model"])), detail_of(row_of(t, b["model"]))
    assert "Licence: cc-by-nc-4.0" in ca and "is not on this site's allow list" in ca
    assert "Licence: unknown" in cb and "not on the allow list until it is" in cb


def test_a_hosted_row_says_the_data_class_rails_give_it_public_data_only_in_its_details(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["frontier"]])
    t = text(c.get("/models/inbox"))
    row = row_of(t, HOSTED_NEW)
    line, detail = row.split('class="in-detail"')[0], detail_of(row)
    assert "Hosted: public data only" in detail and "the data-class rails, TM-1249" in detail and "Fit:" not in t
    assert "the data-class rails" not in line and "Licence" not in detail          # no node, no licence chip for a hosted model


def test_an_open_admit_pr_replaces_evaluate_with_review_pr_and_a_non_https_link_is_not_linked(tmp_path):
    a = dict(CANDIDATES["quant"], pr="https://forge.example/o/r/pull/7")
    b = dict(CANDIDATES["successor"], pr="javascript:alert(1)")
    c, u = page_client(tmp_path, candidates=[a, b])
    t = text(c.get("/models/inbox"))
    ra, rb = row_of(t, NEW_Q), row_of(t, SUCC)
    assert 'href="https://forge.example/o/r/pull/7"' in acts_of(ra) and "Review PR #7" in acts_of(ra)
    assert "Evaluate" not in acts_of(ra).split('class="in-menu"')[0] and "/models/propose" not in ra       # the PR is the one primary action
    assert "Admit PR" in detail_of(ra) and "Open" in detail_of(ra) and "#7" in detail_of(ra) and "waiting for your review" in detail_of(ra)
    assert "Evaluate" in rb and "/models/propose" in rb and "Review PR" not in rb                            # a bad link is dropped, Evaluate stays
    assert "javascript:" not in t and t.count("pull/7") == 2                                                 # the button and the detail line


def test_each_row_has_one_primary_action_and_a_menu_with_snooze_dismiss_and_the_upstream_page(tmp_path):
    cq = dict(CANDIDATES["quant"], url="https://huggingface.co/example-org/Example-27B-8bit")
    c, u = page_client(tmp_path, candidates=[cq])
    t = text(c.get("/models/inbox"))
    acts = acts_of(row_of(t, NEW_Q))
    primary, menu = acts.split('<details class="in-menu">')
    assert primary.count("<button") == 1 and "Evaluate" in primary and 'action="/models/propose"' in primary
    assert 'aria-label="More actions for ' + NEW_Q in menu and "Snooze 30 days" in menu and "Dismiss" in menu
    assert 'action="/models/inbox/snooze"' in menu and 'action="/models/inbox/dismiss"' in menu and menu.count(f'name="csrf" value="{u.csrf}"') == 2
    assert 'href="https://huggingface.co/example-org/Example-27B-8bit"' in menu and "Upstream page" in menu
    assert "Upstream page" not in text(page_client(tmp_path, candidates=[CANDIDATES["quant"]])[0].get("/models/inbox"))      # no link, no item


# ------------------------------------------------------------ filters, snoozed and dismissed

def filter_counts(t):
    nav = t.split('aria-label="Filter the inbox"')[1].split("</nav>")[0]
    return {m[0]: int(m[1]) for m in re.findall(r'<a href="[^"]*"[^>]*>(\w+) <span class="n">(\d+)', nav)}, re.findall(r'aria-current="page">(\w+)', nav)


def filter_fixture(tmp_path):
    inbox = {"snoozed": [{"id": CANDIDATES["quant"]["id"], "until": day(10)}], "dismissed": [{"id": CANDIDATES["successor"]["id"], "date": day(-3)}]}
    return page_client(tmp_path, candidates=ALL, inbox=inbox)


def test_the_all_filter_lists_every_live_candidate_and_counts_each_filter(tmp_path):
    c, u = filter_fixture(tmp_path)
    t = text(c.get("/models/inbox"))
    counts, current = filter_counts(t)
    assert counts == {"All": 3, "Local": 1, "Frontier": 2, "Snoozed": 1, "Dismissed": 1} and current == ["All"]
    assert set(models_in(t)) == {REPO, HOSTED_NEW, HOSTED_OLD} and NEW_Q not in t.split('id="cards-h"')[1] and SUCC not in t.split('id="cards-h"')[1]
    assert "To decide" in t and "(3)" in t.split('id="cards-h"')[1]
    assert filter_counts(text(c.get("/models/inbox?show=nonsense")))[1] == ["All"]                       # an unknown filter is All


def test_the_local_and_frontier_filters_split_by_where_the_model_runs(tmp_path):
    c, u = filter_fixture(tmp_path)
    t = text(c.get("/models/inbox?show=local"))
    assert models_in(t) == [REPO] and filter_counts(t)[1] == ["Local"] and "To decide, local" in t and "(1)" in t
    t = text(c.get("/models/inbox?show=frontier"))
    assert sorted(models_in(t)) == sorted([HOSTED_NEW, HOSTED_OLD]) and filter_counts(t)[1] == ["Frontier"] and "To decide, frontier" in t
    assert filter_counts(t)[0]["All"] == 3                                      # the counts do not change with the filter


def test_the_snoozed_filter_lists_what_is_snoozed_with_its_date_and_no_actions(tmp_path):
    c, u = filter_fixture(tmp_path)
    t = text(c.get("/models/inbox?show=snoozed"))
    assert models_in(t) == [NEW_Q] and filter_counts(t)[1] == ["Snoozed"]
    row = row_of(t, NEW_Q)
    assert f"Snoozed, back on {day(10)}" in acts_of(row) and "Fit: Alpha" in detail_of(row)           # still expandable
    assert "/models/propose" not in row and "/models/inbox/snooze" not in row and "Evaluate" not in row
    assert "To bring one back, delete its line from modelLifecycle.inbox" in plain(c.get("/models/inbox?show=snoozed"))


def test_the_dismissed_filter_lists_what_is_dismissed(tmp_path):
    c, u = filter_fixture(tmp_path)
    t = text(c.get("/models/inbox?show=dismissed"))
    assert models_in(t) == [SUCC] and filter_counts(t)[1] == ["Dismissed"] and "Dismissed " + day(-3) in acts_of(row_of(t, SUCC))
    assert "/models/propose" not in t and "/models/inbox/dismiss" not in t and "To bring one back" in t


def test_an_empty_filter_says_nothing_here(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]])
    for show in ("frontier", "snoozed", "dismissed"):
        t = text(c.get(f"/models/inbox?show={show}"))
        assert "Nothing here." in t and "<li" not in t.split('id="cards-h"')[1].split('id="source-health"')[0]


def test_snoozed_and_dismissed_are_hidden_from_the_default_view_and_the_models_page(tmp_path):
    inbox = {"snoozed": [{"id": CANDIDATES["quant"]["id"], "until": day(10)}], "dismissed": [{"id": CANDIDATES["successor"]["id"], "date": day(-3)}]}
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"], CANDIDATES["successor"], CANDIDATES["revision"]], inbox=inbox)
    t = text(c.get("/models/inbox"))
    cards = t.split('id="cards-h"')[1]
    assert "To decide" in t and "(1)" in cards and REPO in cards and NEW_Q not in cards and SUCC not in cards
    m = text(c.get("/models"))
    assert "2 candidate(s) are snoozed or dismissed" in m and "Inbox (1)" in m and NEW_Q not in m.split('id="next-h"')[0]


def test_a_snooze_that_has_run_out_offers_the_candidate_again(tmp_path):
    inbox = {"snoozed": [{"id": CANDIDATES["quant"]["id"], "until": day(-1)}]}
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], inbox=inbox)
    t = text(c.get("/models/inbox"))
    assert models_in(t) == [NEW_Q] and filter_counts(t)[0]["Snoozed"] == 0 and "Nothing here." in text(c.get("/models/inbox?show=snoozed"))


def test_a_malformed_inbox_is_shown_and_refuses_snooze_and_dismiss(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], inbox={"snoozed": [{"id": "x", "until": "soon"}]})
    t = text(c.get("/models/inbox"))
    assert "modelLifecycle.inbox.snoozed[0].until must be a date" in t and "Snooze 30 days" not in t and "Evaluate" in t
    assert "Dismiss<" not in t.split('id="cards-h"')[1]
    r = c.post("/models/inbox/snooze", data={"csrf": u.csrf, "cid": CANDIDATES["quant"]["id"]})
    assert r.status_code == 400 and "cannot be extended" in r.text
    assert "Inbox settings" in c.get("/models").text


# ------------------------------------------------------------ source health, one line at the foot

def foot_of(t):
    return plain_html(t.split('id="source-health"')[1].split("</p>")[0])


def plain_html(fragment):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(fragment))).strip()


def test_source_health_is_one_line_after_the_list_and_names_who_answered_and_when(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], generated=iso(delta_s=-360),
                       sources={"huggingface": {"ok": True}, "ollama": {"ok": True}, "anthropic": {"ok": True}})
    t = text(c.get("/models/inbox"))
    assert t.count('id="source-health"') == 1 and t.index('id="source-health"') > t.index("</ul>") and 'id="watch-h"' not in t
    foot = foot_of(t)
    assert "OK" in foot and "huggingface, ollama, anthropic answered 6 min ago." in foot
    assert foot.count("answered") == 1 and "Not every upstream answered" not in foot and "predicted from bandwidth" in foot


def test_source_health_names_the_source_that_failed_and_the_report_it_failed_in(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], generated=iso(delta_s=-3 * 3600),
                       sources={"huggingface": {"ok": False, "reason": "unreachable"}, "anthropic": {"ok": True}})
    foot = foot_of(text(c.get("/models/inbox")))
    assert "Unknown" in foot and "Not every upstream answered: huggingface (unreachable), in the report from 3 h ago." in foot
    assert "anthropic answered 3 h ago." in foot


def test_a_stale_report_and_a_missing_one_are_said_in_the_same_line(tmp_path):
    c, u = page_client(tmp_path, candidates=[], generated="2026-01-01T00:00:00Z")
    foot = foot_of(text(c.get("/models/inbox")))
    assert "Unknown" in foot and "the watcher may have stopped" in foot and "may be out of date or incomplete" in foot
    c, u = page_client(tmp_path)
    t = text(c.get("/models/inbox"))
    foot = foot_of(t)
    assert "Not watching" in foot and "modelLifecycle.reportFile" in foot and "Nothing is listed because no watcher report is configured" in t


# ------------------------------------------------------------ the three buttons

def test_evaluate_renders_the_existing_admit_change(tmp_path):
    sizes = {NEW_Q: size_rec(NEW_Q)}
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], sizes=sizes)
    r = c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDIDATES["quant"]["id"]})
    t = text(r)
    assert r.status_code == 200 and "Nothing has changed yet" in t and f"Admit {NEW_Q} for evaluation" in t and "local-medium-next" in t


def snooze_doc(c, u, cid, which="snooze"):
    r = c.post(f"/models/inbox/{which}", data={"csrf": u.csrf, "cid": cid, "fmt": "yaml"})
    assert r.status_code == 200, r.text
    return yaml.safe_load(r.text)


def test_snooze_renders_a_values_change_for_thirty_days_and_writes_nothing(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]])
    cid = CANDIDATES["quant"]["id"]
    before = (tmp_path / "report.json").read_text()
    doc = snooze_doc(c, u, cid)
    until = day(30)
    assert doc["modelLifecycle"]["inbox"] == {"snoozed": [{"id": cid, "until": until}]}
    assert doc["modelLifecycle"]["reportFile"].endswith("report.json")                  # every key the operator set is carried
    assert [e["id"] for e in doc["modelLifecycle"]["catalog"]] == ["example-27b-4bit", "example-embed"]   # and the catalog is untouched
    page = text(c.post("/models/inbox/snooze", data={"csrf": u.csrf, "cid": cid}))
    assert "Snooze " + NEW_Q + " for 30 days" in page and "Nothing has changed yet" in page and f"hidden until {until}" in page
    assert (tmp_path / "report.json").read_text() == before


def test_dismiss_renders_a_dismissed_entry_and_keeps_the_others(tmp_path):
    inbox = {"snoozed": [{"id": CANDIDATES["successor"]["id"], "until": day(5)}], "dismissed": [{"id": "revision:old", "date": "2026-10-01"}]}
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"], CANDIDATES["successor"]], inbox=inbox)
    doc = snooze_doc(c, u, CANDIDATES["quant"]["id"], "dismiss")
    got = doc["modelLifecycle"]["inbox"]
    assert got["dismissed"] == [{"id": "revision:old", "date": "2026-10-01"}, {"id": CANDIDATES["quant"]["id"], "date": day(0)}]
    assert got["snoozed"] == [{"id": CANDIDATES["successor"]["id"], "until": day(5)}]
    page = text(c.post("/models/inbox/dismiss", data={"csrf": u.csrf, "cid": CANDIDATES["quant"]["id"]}))
    assert "a NEW candidate for the same model" in page


def test_snoozing_a_dismissed_candidate_moves_it_and_an_unknown_one_is_refused(tmp_path):
    cid = CANDIDATES["quant"]["id"]
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], inbox={"dismissed": [{"id": cid, "date": "2026-10-01"}]})
    r = c.post("/models/inbox/snooze", data={"csrf": u.csrf, "cid": cid, "fmt": "yaml"})
    got = yaml.safe_load(r.text)["modelLifecycle"]["inbox"]
    assert got["snoozed"][0]["id"] == cid and "dismissed" not in got
    assert c.post("/models/inbox/dismiss", data={"csrf": u.csrf, "cid": "nope"}).status_code == 404


# ------------------------------------------------------------ the pure parts

def test_inbox_parse_rules():
    assert ib.parse(None) == ib.Inbox()
    assert ib.parse({"dismissed": ["a:b"]}).dismissed == {"a:b": ""}
    for bad in ({"snoozed": [{"id": "a"}]}, {"snoozed": "x"}, {"dismissed": [{"id": ""}]}, {"dismissed": [{"id": "has space"}]}, "x"):
        with pytest.raises(ml.LifecycleError):
            ib.parse(bad)
    today = datetime.date(2026, 10, 30)
    inbox = ib.parse({"snoozed": [{"id": "a", "until": "2026-10-31"}, {"id": "b", "until": "2026-10-30"}], "dismissed": [{"id": "c", "date": "2026-10-01"}]})
    assert ib.skipped_ids(inbox, today) == {"a", "c"}                    # a snooze ends ON its date


@pytest.mark.parametrize("when,state,text_", [
    (day(12), "upcoming", "retires in 12 days"), (day(1), "upcoming", "retires in 1 day ("), (day(0), "upcoming", "retires today"),
    (day(-4), "retired", "retired on"), ("", "unknown", "retirement date not understood"), ("next spring", "unknown", "not understood (next spring)"),
    (str(int((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=40)).timestamp())), "upcoming", "retires in 4")])
def test_retirement_countdown(when, state, text_):
    r = ib.retirement(when, datetime.datetime.now(datetime.timezone.utc).date())
    assert r["state"] == state and text_ in r["text"]
    assert ib.retire_state(r) == {"upcoming": "warning", "retired": "critical", "unknown": "unknown"}[state]


# ------------------------------------------------------------ TM-1265: the countdown on the pages, and the replacement

def retiring(when, **kw):
    return dict(CANDIDATES["deprecation"], when=when, **kw)


def test_the_inbox_card_for_a_retiring_model_counts_down_and_offers_the_replacement(tmp_path):
    c, u = page_client(tmp_path, candidates=[retiring(day(12))])
    t = plain(c.get("/models/inbox"))
    assert "retires in 12 days" in t and f"Replacement named: {HOSTED_NEW}" in t and "Evaluate the replacement" in t
    assert "the data-class rails, TM-1249" in t                             # public data only, on the card
    r = c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDIDATES["deprecation"]["id"]})
    t2 = text(r)
    assert r.status_code == 200 and f"Admit {HOSTED_NEW} for evaluation" in t2 and "eval gateway" in t2 and "endpoint_tier: external" in t2


def test_a_retiring_row_keeps_its_action_wording_shows_the_countdown_on_the_row_and_the_replacement_under_it(tmp_path):
    c, u = page_client(tmp_path, candidates=[retiring(day(12))])
    row = row_of(text(c.get("/models/inbox")), HOSTED_OLD)
    line, detail = row.split('class="in-detail"')[0], detail_of(row)
    assert "retires in 12 days" in line and "hosted, no node" in line
    assert f"Replacement named: <code>{HOSTED_NEW}</code>" in detail and "the data-class rails, TM-1249" in detail
    assert "Evaluate the replacement" in acts_of(row) and 'action="/models/propose"' in acts_of(row)
    pr = dict(retiring(day(12)), pr="https://forge.example/o/r/pull/12")                     # the replacement's admit PR is already open
    c, u = page_client(tmp_path, candidates=[pr])
    row = row_of(text(c.get("/models/inbox")), HOSTED_OLD)
    assert "Review PR #12" in acts_of(row) and "Evaluate the replacement" not in row and "#12" in detail_of(row)
    lc = hosted_lifecycle()
    lc["catalog"].append({"id": "example-model-9", "model": HOSTED_NEW, "stage": "candidate", "source": {"kind": "hosted", "ref": HOSTED_NEW}})
    c, u = page_client(tmp_path, candidates=[retiring(day(12))], lifecycle=lc)
    row = row_of(text(c.get("/models/inbox")), HOSTED_OLD)
    assert "See the replacement" in acts_of(row) and "/models/m/example-model-9" in acts_of(row) and "Evaluate the replacement" not in row


def test_a_retired_model_reads_retired_and_a_missing_replacement_is_said(tmp_path):
    dep = retiring(day(-3))
    del dep["replacement"]
    c, u = page_client(tmp_path, candidates=[dep])
    t = plain(c.get("/models/inbox"))
    assert "retired on " + day(-3) in t and "retires in -" not in t and "The report names no replacement" in t and "Evaluate the replacement" not in t
    r = c.post("/models/propose", data={"csrf": u.csrf, "cid": dep["id"]})
    assert r.status_code == 400 and "names no replacement" in text(r)


def test_a_replacement_already_in_the_catalog_is_not_admitted_twice(tmp_path):
    lc = hosted_lifecycle()
    lc["catalog"].append({"id": "example-model-9", "model": HOSTED_NEW, "stage": "candidate", "source": {"kind": "hosted", "ref": HOSTED_NEW}})
    c, u = page_client(tmp_path, candidates=[retiring(day(12))], lifecycle=lc)
    t = text(c.get("/models/inbox"))
    assert "The replacement is already in the catalog (stage candidate)" in t and "Evaluate the replacement" not in t
    assert "is already in the catalog (stage candidate)" in text(c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDIDATES["deprecation"]["id"]}))


def test_the_models_catalog_and_the_alias_page_carry_the_countdown(tmp_path):
    c, u = page_client(tmp_path, candidates=[retiring(day(12))], lifecycle=hosted_lifecycle(), gateway=HOSTED_GATEWAY)
    m = text(c.get("/models"))
    row = m.split("example-old-3")[-1]
    assert "retires in 12 days" in m and 'href="/models/a/big-hosted-chat"' in m
    a = c.get("/models/a/big-hosted-chat")
    ta = plain(a)
    assert a.status_code == 200 and "Routes to the hosted model" in ta and "retires in 12 days" in ta and f"Replacement named: {HOSTED_NEW}" in ta
    assert "Revert to previous" not in ta and 'name="reason"' not in ta
    c2, u2 = page_client(tmp_path, candidates=[retiring(day(-2))], lifecycle=hosted_lifecycle(), gateway=HOSTED_GATEWAY)
    assert "retired on " + day(-2) in plain(c2.get("/models/a/big-hosted-chat"))
    assert "retired on " + day(-2) in plain(c2.get("/models"))


def test_the_alias_page_for_a_hosted_model_is_unknown_when_nothing_says(tmp_path):
    c, u = page_client(tmp_path, lifecycle=hosted_lifecycle(), gateway=HOSTED_GATEWAY)           # no watcher report at all
    t = plain(c.get("/models/a/big-hosted-chat"))
    assert "nothing says whether this model is being retired" in t and "no retirement for this model" not in t
    c, u = page_client(tmp_path, candidates=[], lifecycle=hosted_lifecycle(), gateway=HOSTED_GATEWAY)
    assert "lists no retirement for this model" in text(c.get("/models/a/big-hosted-chat"))
    assert c.get("/models/a/nope").status_code == 404


def test_an_unreadable_date_is_unknown_not_a_countdown(tmp_path):
    c, u = page_client(tmp_path, candidates=[retiring("someday")], lifecycle=hosted_lifecycle(), gateway=HOSTED_GATEWAY)
    t = plain(c.get("/models/a/big-hosted-chat"))
    assert "retirement date not understood (someday)" in t and "retires in" not in t


# ------------------------------------------------------------ the watcher and the opener skip what is hidden

class Upstream:
    def handler(self, req):
        h, p = req.url.host, req.url.path
        if h == "huggingface.co" and p == "/api/models/example-org/Example-27B-4bit":
            return httpx.Response(200, json={"id": REPO, "sha": SHA_C, "lastModified": "2026-10-05T00:00:00.000Z"})
        if h == "huggingface.co" and p == "/api/models" and "base_model" in str(req.url):
            return httpx.Response(200, json=[{"id": "mlx-community/Example-27B-8bit"}])
        if h == "openrouter.ai":
            return httpx.Response(200, json={"data": [{"id": "anthropic/example-old-3", "expiration_date": day(30)},
                                                      {"id": "anthropic/example-model-9", "created": 1790000000}]})
        return httpx.Response(404)


def watcher_cfg(**inbox):
    lc = lifecycle_doc(watch={"enabled": True, "providers": {"openrouter": {"allow": ["anthropic/*"],
                                                                            "replacements": {"anthropic/example-old-3": "anthropic/example-model-9"}}}})
    if inbox:
        lc["inbox"] = inbox
    return {"modelLifecycle": lc, "gatewayModelList": [{"model_name": "x", "litellm_params": {"model": "openrouter/anthropic/example-old-3"}}]}


def watch(cfg):
    return wm.run(cfg, wm.Fetcher(transport=httpx.MockTransport(Upstream().handler)), env={})


def test_the_watcher_leaves_out_snoozed_and_dismissed_candidates():
    ids = {c["id"] for c in watch(watcher_cfg())["candidates"]}
    assert any(i.startswith("revision:") for i in ids) and any(i.startswith("quant:") for i in ids)
    rev = next(i for i in ids if i.startswith("revision:"))
    quant = next(i for i in ids if i.startswith("quant:"))
    got = {c["id"] for c in watch(watcher_cfg(snoozed=[{"id": rev, "until": day(5)}], dismissed=[{"id": quant, "date": day(-1)}]))["candidates"]}
    assert rev not in got and quant not in got and got < ids and got                      # only those two went
    back = {c["id"] for c in watch(watcher_cfg(snoozed=[{"id": rev, "until": day(-1)}]))["candidates"]}
    assert rev in back                                                                      # an ended snooze offers it again


def test_the_watcher_refuses_a_malformed_inbox_loudly():
    with pytest.raises(ml.LifecycleError, match="inbox.snoozed"):
        watch(watcher_cfg(snoozed="soon"))


def test_the_watcher_records_the_replacement_it_was_told():
    dep = [c for c in watch(watcher_cfg())["candidates"] if c["kind"] == "deprecation"]
    assert dep and dep[0]["replacement"] == "openrouter/anthropic/example-model-9" or dep[0]["replacement"].endswith("example-model-9")


def test_a_pr_link_survives_the_next_watcher_run_only_while_the_candidate_is_found():
    doc = {"candidates": [{"id": "a"}, {"id": "b"}]}
    wm.carry_pr_links(doc, {"candidates": [{"id": "a", "pr": "https://forge.example/pull/1"}, {"id": "gone", "pr": "https://forge.example/pull/2"},
                                           {"id": "b", "pr": "javascript:x"}]})
    assert doc["candidates"] == [{"id": "a", "pr": "https://forge.example/pull/1"}, {"id": "b"}]


def test_the_opener_does_not_plan_a_hidden_candidate_and_records_the_pr_link(tmp_path):
    cand_q = {"id": "quant:example-org/Example-27B-8bit", "kind": "quant", "subject": "example-27b-4bit", "model": NEW_Q,
              "source": {"kind": "huggingface", "ref": NEW_Q, "revision": "5" * 40}, "detail": "d"}
    lc = lifecycle_doc()
    values = {"modelLifecycle": lc, "inferenceNodes": inventory_doc()}
    assert [x.kind for x in po.plan(values, {"schema": 1, "candidates": [cand_q]}, []).prs] == ["admit"]
    lc["inbox"] = {"snoozed": [{"id": cand_q["id"], "until": day(3)}]}
    p = po.plan(values, {"schema": 1, "candidates": [cand_q]}, [])
    assert p.prs == [] and any("snoozed or dismissed" in why for _w, why in p.skipped)
    rep = tmp_path / "r.json"
    rep.write_text(json.dumps({"schema": 1, "candidates": [cand_q]}))
    assert po.record_pr_links(str(rep), {cand_q["id"]: "https://forge.example/o/r/pull/9", "other": "https://x"})
    assert json.loads(rep.read_text())["candidates"][0]["pr"] == "https://forge.example/o/r/pull/9"
    assert ml.parse_report(json.loads(rep.read_text())).candidates[0].pr == "https://forge.example/o/r/pull/9"

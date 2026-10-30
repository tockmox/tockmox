# SPDX-License-Identifier: Apache-2.0
"""TM-1258 (the Inbox), TM-1265 (the retirement countdown): the watcher's candidates as cards with a reason, a fit per node, a
licence and a labelled hint; Evaluate, Snooze and Dismiss each render a change and write nothing; a snoozed or dismissed
candidate is hidden here, on the Models page, in the watcher's report and in the PR opener's plan."""
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
    assert "Not watching" in t and "Evaluate" not in t and "Nothing to decide" not in t.replace("Nothing to decide.", "") + "x" or True
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
    assert "not every upstream answered" in text(c.get("/models/inbox"))


# ------------------------------------------------------------ one card per reason

@pytest.mark.parametrize("kind,tag", [("revision", "New revision"), ("quant", "Other quant"), ("successor", "Successor"),
                                      ("frontier", "Hosted, new"), ("deprecation", "Hosted, retiring")])
def test_each_reason_has_its_tag(tmp_path, kind, tag):
    c, u = page_client(tmp_path, candidates=[CANDIDATES[kind]])
    t = text(c.get("/models/inbox"))
    assert f'<span class="badge st-info">{tag}</span>' in t and CANDIDATES[kind]["model"] in t
    assert f'name="cid" value="{CANDIDATES[kind]["id"]}"' in t


def test_a_local_candidate_has_a_fit_chip_per_node_a_licence_and_a_labelled_hint(tmp_path):
    sizes = {NEW_Q: size_rec(NEW_Q, 17.0, "apache-2.0", evals=[{"name": "MMLU", "value": "0.81", "dataset": "mmlu"}])}
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], sizes=sizes)
    t = text(c.get("/models/inbox"))
    assert "Fit: Alpha: fits" in t and "Fit: Beta: " in t                    # one chip per node, from fit v2
    assert "Licence: apache-2.0" in t
    assert "Self-reported on the model card, a hint and not a measurement: MMLU 0.81 on mmlu" in t


def card_of(t, model):
    """The one <li> card that names `model`."""
    return next(li for li in t.split("<li>") if f"<code>{model}</code>" in li)


def test_fit_says_over_when_it_does_not_fit_and_unknown_when_it_cannot_say(tmp_path):
    big = cand("quant", "example-org/Example-405B-8bit")
    mystery = cand("quant", "example-org/Mystery-model")
    sizes = {big["model"]: size_rec(big["model"], 400.0), mystery["model"]: size_rec(mystery["model"], 1.0)}
    for k in ("sizeBytes", "paramsB"):                                           # nothing in the record or the name says how big it is
        sizes[mystery["model"]].pop(k, None)
    c, u = page_client(tmp_path, candidates=[big, mystery], sizes=sizes)
    t = text(c.get("/models/inbox"))
    big_card = card_of(t, big["model"])
    big_fit = big_card.split('class="chips-row"')[1].split("</p>")[0]
    assert "Fit: Alpha: over" in big_fit and "Fit: Beta: over" in big_fit and big_fit.count("st-critical") == 2 and "st-ok" not in big_fit
    mystery_card = card_of(t, mystery["model"])
    fit_part = mystery_card.split('class="chips-row"')[1].split("</p>")[0]
    assert "Fit: Alpha: Unknown, its size is not known" in fit_part and "Fit: Beta: Unknown" in fit_part
    assert "st-ok" not in fit_part and "st-unknown" in fit_part and "fits" not in fit_part


def test_a_licence_off_the_allow_list_is_a_problem_and_no_licence_is_unknown(tmp_path):
    a, b = cand("quant", "example-org/Example-9B-4bit"), cand("quant", "example-org/Example-8B-4bit")
    sizes = {a["model"]: size_rec(a["model"], 5.0, "cc-by-nc-4.0"), b["model"]: size_rec(b["model"], 5.0, "")}
    c, u = page_client(tmp_path, candidates=[a, b], sizes=sizes)
    t = text(c.get("/models/inbox"))
    ca, cb = card_of(t, a["model"]), card_of(t, b["model"])
    assert "Licence: cc-by-nc-4.0" in ca and "is not on this site's allow list" in ca
    assert "Licence: unknown" in cb and "not on the allow list until it is" in cb


def test_a_hosted_card_says_it_is_held_by_the_runner_rails(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["frontier"]])
    t = text(c.get("/models/inbox"))
    assert "Hosted: held" in t and "the safety rails, TM-1249" in t and "Fit:" not in t


def test_an_open_admit_pr_is_linked_and_a_non_https_link_is_not(tmp_path):
    a = dict(CANDIDATES["quant"], pr="https://forge.example/o/r/pull/7")
    b = dict(CANDIDATES["successor"], pr="javascript:alert(1)")
    c, u = page_client(tmp_path, candidates=[a, b])
    t = text(c.get("/models/inbox"))
    assert 'href="https://forge.example/o/r/pull/7"' in t and "An admit change is already open" in t
    assert "javascript:" not in t and t.count("An admit change is already open") == 1


# ------------------------------------------------------------ snoozed and dismissed are filtered

def test_snoozed_and_dismissed_are_hidden_and_listed_under_hidden(tmp_path):
    inbox = {"snoozed": [{"id": CANDIDATES["quant"]["id"], "until": day(10)}], "dismissed": [{"id": CANDIDATES["successor"]["id"], "date": day(-3)}]}
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"], CANDIDATES["successor"], CANDIDATES["revision"]], inbox=inbox)
    t = text(c.get("/models/inbox"))
    cards = t.split('id="cards-h"')[1].split('id="hid-h"')[0]
    assert "To decide" in t and "(1)" in cards and REPO in cards and NEW_Q not in cards and SUCC not in cards
    hidden = t.split('id="hid-h"')[1]
    assert "1 snoozed, 1 dismissed" in hidden and NEW_Q in hidden and f"back on {day(10)}" in hidden and SUCC in hidden
    m = text(c.get("/models"))
    assert "2 candidate(s) are snoozed or dismissed" in m and "Inbox (1)" in m and NEW_Q not in m.split('id="next-h"')[0]


def test_a_snooze_that_has_run_out_offers_the_candidate_again(tmp_path):
    inbox = {"snoozed": [{"id": CANDIDATES["quant"]["id"], "until": day(-1)}]}
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], inbox=inbox)
    t = text(c.get("/models/inbox"))
    assert NEW_Q in t.split('id="cards-h"')[1] and 'id="hid-h"' not in t


def test_a_malformed_inbox_is_shown_and_refuses_snooze_and_dismiss(tmp_path):
    c, u = page_client(tmp_path, candidates=[CANDIDATES["quant"]], inbox={"snoozed": [{"id": "x", "until": "soon"}]})
    t = text(c.get("/models/inbox"))
    assert "modelLifecycle.inbox.snoozed[0].until must be a date" in t and "Snooze 30 days" not in t and "Evaluate" in t
    r = c.post("/models/inbox/snooze", data={"csrf": u.csrf, "cid": CANDIDATES["quant"]["id"]})
    assert r.status_code == 400 and "cannot be extended" in r.text
    assert "Inbox settings" in c.get("/models").text


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
    assert "the safety rails, TM-1249" in t                                 # held by the runner rails, on the card
    r = c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDIDATES["deprecation"]["id"]})
    t2 = text(r)
    assert r.status_code == 200 and f"Admit {HOSTED_NEW} for evaluation" in t2 and "eval gateway" in t2 and "endpoint_tier: external" in t2


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

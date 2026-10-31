# SPDX-License-Identifier: Apache-2.0
"""TM-1298: frontier cost. The watcher records each hosted model's list price per 1M tokens (LiteLLM's price map) with the day it
was read; the Models page shows price, spend and calls (spend and calls from the gateway's own metrics, over the window each query
names); a missing figure reads unknown, never an estimate. Run from tockmox-ui/: python -m pytest tests"""
import html
import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import budget as bg  # noqa: E402
from app import frontier_cost as fc  # noqa: E402
from app import models as ml  # noqa: E402
from app import prices as pm  # noqa: E402
from app import watcher as wm  # noqa: E402
from app.sources import Reading  # noqa: E402
from app import nodes as nm  # noqa: E402
from tests.models_support import inventory_doc, lifecycle_doc  # noqa: E402
from tests.pages_support import page_client  # noqa: E402
from tests.test_models_page_v2 import FRONTIER_CHAT, frontier_of, frow, rich_client  # noqa: E402

DAY = "2026-10-30"

# LiteLLM's price map, in the shape the real file has: some keys prefixed, some not, a litellm_provider on each, USD per token
PRICE_MAP = {
    "sample_spec": {"input_cost_per_token": 0.0, "litellm_provider": "one of https://docs.litellm.ai/docs/providers"},
    "claude-sonnet-5-5": {"litellm_provider": "anthropic", "input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05},
    "claude-opus-5-5": {"litellm_provider": "anthropic", "input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05},
    "gpt-5.1": {"litellm_provider": "openai", "input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05},
    "azure/gpt-5.1": {"litellm_provider": "azure", "input_cost_per_token": 9e-06, "output_cost_per_token": 9e-05},
    "gemini/gemini-2.5-pro": {"litellm_provider": "gemini", "input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05},
    "mistral/mistral-small": {"litellm_provider": "mistral", "input_cost_per_token": 1e-07, "output_cost_per_token": 3e-07},
    "bedrock/anthropic.claude-sonnet-5-5": {"litellm_provider": "bedrock", "input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05},
    "only-in": {"litellm_provider": "anthropic", "input_cost_per_token": 1e-06},                       # no output price: no price at all
    "claude-free": {"litellm_provider": "anthropic", "input_cost_per_token": "free", "output_cost_per_token": 0.0},
    "mistral-large-2": {"litellm_provider": "azure_ai", "input_cost_per_token": 2e-06, "output_cost_per_token": 6e-06},  # another provider's
}


# ---------------------------------------------------------------- the price map

def test_per_token_dollars_become_per_million_tokens():
    assert pm.lookup(PRICE_MAP, "anthropic/claude-sonnet-5-5") == {"inPer1M": 3.0, "outPer1M": 15.0}
    assert pm.lookup(PRICE_MAP, "openai/gpt-5.1") == {"inPer1M": 1.25, "outPer1M": 10.0}
    assert pm.lookup(PRICE_MAP, "mistral/mistral-small") == {"inPer1M": 0.1, "outPer1M": 0.3}          # no float noise (0.30000000000000004)


def test_a_prefixed_key_matches_exactly_and_an_unprefixed_one_only_for_its_own_provider():
    assert pm.lookup(PRICE_MAP, "azure/gpt-5.1") == {"inPer1M": 9.0, "outPer1M": 90.0}                    # the prefixed key, not openai's
    assert pm.lookup(PRICE_MAP, "bedrock/anthropic.claude-sonnet-5-5")["inPer1M"] == 3.0
    assert pm.lookup(PRICE_MAP, "openai/claude-sonnet-5-5") is None                                      # an anthropic model under openai: no price
    assert pm.lookup(PRICE_MAP, "mistral/mistral-large-2") is None                                       # that key is azure_ai's


def test_google_models_are_found_under_litellms_gemini_prefix():
    assert pm.lookup(PRICE_MAP, "google/gemini-2.5-pro") == {"inPer1M": 1.25, "outPer1M": 10.0}
    assert pm.lookup(PRICE_MAP, "gemini/gemini-2.5-pro") == {"inPer1M": 1.25, "outPer1M": 10.0}


@pytest.mark.parametrize("model", ["anthropic/claude-nowhere-9", "anthropic/only-in", "anthropic/claude-free", "claude-sonnet-5-5", "", "anthropic/",
                                   "anthropic/sample_spec"])
def test_a_model_the_map_does_not_price_is_absent_never_zero(model):
    assert pm.lookup(PRICE_MAP, model) is None


def test_collect_records_source_label_and_day_without_a_version_number():
    got = pm.collect(PRICE_MAP, ["anthropic/claude-sonnet-5-5", "anthropic/claude-nowhere-9"], DAY)
    assert got == {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "source": "LiteLLM price map", "readAt": DAY}}
    assert pm.SOURCE_LABEL == "LiteLLM price map" and not re.search(r"\d", pm.SOURCE_LABEL)


def test_the_last_good_price_is_kept_when_a_read_fails_under_its_own_date():
    prev = {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "source": "LiteLLM price map", "readAt": "2026-10-20"},
            "openai/gone": {"inPer1M": 1.0, "outPer1M": 2.0, "source": "LiteLLM price map", "readAt": "2026-10-20"}}
    kept = pm.carry({}, prev, ["anthropic/claude-sonnet-5-5", "openai/gpt-5.1"], ok=False)
    assert kept == {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "source": "LiteLLM price map", "readAt": "2026-10-20",
                                                    "stale": True}}                                      # not today's date; a model no longer wanted is dropped
    assert pm.carry({"a/b": {"readAt": DAY}}, prev, ["anthropic/claude-sonnet-5-5"], ok=True) == {"a/b": {"readAt": DAY}}   # a good read replaces


# ---------------------------------------------------------------- the watcher

class Upstream:
    """The hosts the watcher may reach, answering the price map from `price_map` (or failing)."""

    def __init__(self, price_map=PRICE_MAP, fail=False, status=200, body=None):
        self.reqs, self.price_map, self.fail, self.status, self.body = [], price_map, fail, status, body

    def handler(self, req):
        self.reqs.append(req)
        if req.url.host == "raw.githubusercontent.com":
            if self.fail:
                raise httpx.ConnectError("down", request=req)
            if self.status != 200:
                return httpx.Response(self.status)
            return httpx.Response(200, content=self.body if self.body is not None else json.dumps(self.price_map).encode())
        return httpx.Response(404)

    def price_reqs(self):
        return [r for r in self.reqs if r.url.host == "raw.githubusercontent.com"]


def cfg(prices=None, **watch):
    w = {"enabled": True, **watch}
    if prices is not None:
        w["prices"] = prices
    d = {"modelLifecycle": lifecycle_doc(watch=w, catalog=[
        {"id": "claude-sonnet-5-5", "model": "anthropic/claude-sonnet-5-5", "stage": "promoted", "adopted": "2026-10-07",
         "source": {"kind": "hosted", "ref": "anthropic/claude-sonnet-5-5"}},
        {"id": "claude-nowhere", "model": "anthropic/claude-nowhere-9", "stage": "candidate",
         "source": {"kind": "hosted", "ref": "anthropic/claude-nowhere-9"}}])}
    d["gatewayModelList"] = [{"model_name": "big-chat", "litellm_params": {"model": "openai/gpt-5.1"}}]
    return d


def run(up, c=None, previous=None):
    return wm.run(c or cfg(), wm.Fetcher(transport=httpx.MockTransport(up.handler)), env={}, previous=previous)


def test_the_price_map_host_is_a_watched_host_and_nothing_else_widened():
    assert "raw.githubusercontent.com" in wm.WATCH_HOSTS and pm.PRICE_MAP_URL.startswith("https://raw.githubusercontent.com/BerriAI/litellm/")
    assert wm.WATCH_HOSTS == {"huggingface.co", "registry.ollama.ai", "openrouter.ai", "api.anthropic.com", "api.openai.com",
                              "raw.githubusercontent.com"}
    f = wm.Fetcher(transport=httpx.MockTransport(Upstream().handler))
    with pytest.raises(wm.Refused):
        f.json("https://raw.githubusercontent.com.evil.example/x")
    with pytest.raises(wm.Refused):
        f.json("http://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")


def test_every_hosted_catalog_and_gateway_model_is_priced_with_the_day_it_was_read():
    up = Upstream()
    rep = run(up, previous=None)
    assert [r.url.path for r in up.price_reqs()] == ["/BerriAI/litellm/main/model_prices_and_context_window.json"]
    assert rep["priceSource"] == {"ok": True, "reason": "", "readAt": rep["generatedAt"][:10]}
    day = rep["generatedAt"][:10]
    assert rep["prices"] == {
        "anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "source": "LiteLLM price map", "readAt": day},
        "openai/gpt-5.1": {"inPer1M": 1.25, "outPer1M": 10.0, "source": "LiteLLM price map", "readAt": day}}      # the gateway's route is priced too
    assert "anthropic/claude-nowhere-9" not in rep["prices"]                                             # the map has no entry: absent, so unknown


def test_a_failed_read_is_recorded_and_the_last_good_price_stays_under_its_date():
    prev = {"prices": {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "source": "LiteLLM price map", "readAt": "2026-10-20"}}}
    for bad in (Upstream(fail=True), Upstream(status=503), Upstream(body=b"<html>not json</html>"), Upstream(body=b"[1, 2]")):
        rep = run(bad, previous=prev)
        assert rep["priceSource"]["ok"] is False and rep["priceSource"]["reason"] and rep["priceSource"]["readAt"] == "2026-10-20"
        assert rep["prices"] == {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "source": "LiteLLM price map",
                                                                 "readAt": "2026-10-20", "stale": True}}
    nothing = run(Upstream(fail=True), previous=None)
    assert nothing["prices"] == {} and nothing["priceSource"]["ok"] is False                            # nothing earlier: nothing to show


def test_a_price_failure_does_not_turn_the_report_unknown_or_hide_candidates():
    rep = run(Upstream(fail=True))
    assert "raw.githubusercontent.com" not in json.dumps(rep["sources"]) and all(v["ok"] for v in rep["sources"].values())


def test_prices_off_makes_no_request_and_records_nothing():
    up = Upstream()
    rep = run(up, cfg(prices={"enabled": False}))
    assert up.price_reqs() == [] and "prices" not in rep and "priceSource" not in rep


def test_with_no_hosted_model_the_price_map_is_not_fetched():
    up = Upstream()
    c = {"modelLifecycle": lifecycle_doc(watch={"enabled": True})}
    rep = run(up, c)
    assert up.price_reqs() == [] and "priceSource" not in rep


def test_a_price_map_bigger_than_the_usual_cap_is_still_read():
    big = dict(PRICE_MAP, padding={"litellm_provider": "x", "note": "y" * (5 << 20)})                   # the real file is 3 MB and grows
    rep = run(Upstream(price_map=big))
    assert rep["priceSource"]["ok"] is True and "anthropic/claude-sonnet-5-5" in rep["prices"]
    huge = Upstream(body=b'{"x": "' + b"y" * (pm.MAX_MAP_BYTES + 10) + b'"}')
    assert run(huge)["priceSource"]["ok"] is False


def test_main_with_the_watcher_off_makes_no_price_request(tmp_path, monkeypatch):
    import socket
    tried = []
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: tried.append(a) or (_ for _ in ()).throw(OSError("blocked")))
    p = tmp_path / "c.yaml"
    c = cfg()
    c["modelLifecycle"]["watch"]["enabled"] = False
    p.write_text(json.dumps(c))
    assert wm.main(["w", str(p), str(tmp_path / "r.json")]) == 0 and tried == []


def test_main_reads_the_previous_report_to_keep_a_last_good_price(tmp_path, monkeypatch):
    out = tmp_path / "r.json"
    out.write_text(json.dumps({"schema": 1, "prices": {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "source": "LiteLLM price map",
                                                                                         "readAt": "2026-10-20"}}}))
    p = tmp_path / "c.yaml"
    p.write_text(json.dumps(cfg()))
    up = Upstream(fail=True)
    real = wm.Fetcher
    monkeypatch.setattr(wm, "Fetcher", lambda timeout=10.0: real(timeout, transport=httpx.MockTransport(up.handler)))
    assert wm.main(["w", str(p), str(out)]) == 0
    doc = json.loads(out.read_text())
    assert doc["prices"]["anthropic/claude-sonnet-5-5"]["readAt"] == "2026-10-20" and doc["prices"]["anthropic/claude-sonnet-5-5"]["stale"] is True


def test_the_report_the_watcher_writes_round_trips_through_the_ui_parser():
    rep = ml.parse_report(json.loads(json.dumps(run(Upstream()))))
    assert rep.prices["anthropic/claude-sonnet-5-5"] == {"inPer1M": 3.0, "outPer1M": 15.0, "readAt": rep.generated_at[:10], "stale": False}
    assert rep.price_source["ok"] is True


def test_the_ui_drops_a_report_price_that_is_not_two_numbers_and_a_day():
    good = {"inPer1M": 1, "outPer1M": 2, "readAt": DAY}
    rep = ml.parse_report({"schema": 1, "prices": {"a/ok": good, "a/neg": {**good, "inPer1M": -1}, "a/nodate": {"inPer1M": 1, "outPer1M": 2},
                                                   "a/str": {**good, "outPer1M": "2"}, "a/bool": {**good, "inPer1M": True}, "a/baddate": {**good, "readAt": "yesterday"}},
                           "priceSource": {"ok": True, "readAt": DAY}})
    assert list(rep.prices) == ["a/ok"]
    assert ml.parse_report({"schema": 1}).prices == {} and ml.parse_report({"schema": 1}).price_source == {}


# ---------------------------------------------------------------- the site's own price

SITE = {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "date": DAY}}


def test_site_prices_parse_and_survive_a_generated_change():
    lc = ml.parse(lifecycle_doc(frontier={"providers": {"anthropic": {"keyEnv": "K"}}, "prices": SITE}))
    assert lc.frontier_prices == SITE
    doc = ml.to_doc(lc)
    assert doc["frontier"]["prices"] == SITE and doc["frontier"]["providers"] == {"anthropic": {"keyEnv": "K"}}
    inv = nm.parse_inventory(inventory_doc())
    changed = ml.change_doc({"frontier": {"prices": SITE}, "watch": {"enabled": True}}, inventory_doc(), lc, inv)["modelLifecycle"]
    assert changed["frontier"]["prices"] == SITE and changed["watch"] == {"enabled": True}              # a UI-generated change keeps the site's prices
    assert ml.parse(ml.to_doc(ml.merge(lc, ml.parse(lifecycle_doc())))).frontier_prices == SITE
    only = ml.parse(lifecycle_doc(frontier={"prices": SITE}))
    assert ml.to_doc(only)["frontier"] == {"prices": SITE}                                               # prices alone are kept, not dropped with the providers


def test_the_ui_refuses_to_start_on_a_bad_site_price(tmp_path):
    from app.config import ConfigError
    with pytest.raises(ConfigError, match=r"modelLifecycle: frontier.prices.a/b.inPer1M must be a number of dollars"):
        page_client(tmp_path, lifecycle=lifecycle_doc(frontier={"prices": {"a/b": {"inPer1M": -1, "outPer1M": 1, "date": DAY}}}))


def test_an_unquoted_yaml_date_is_a_date():
    import datetime
    import yaml
    doc = yaml.safe_load("frontier:\n  prices:\n    a/b: {inPer1M: 1, outPer1M: 2, date: 2026-10-30}\n")
    assert isinstance(doc["frontier"]["prices"]["a/b"]["date"], datetime.date)
    assert ml.parse(doc).frontier_prices["a/b"]["date"] == DAY


@pytest.mark.parametrize("bad", [
    {"a/b": {"inPer1M": -1, "outPer1M": 2, "date": DAY}},
    {"a/b": {"inPer1M": "3", "outPer1M": 2, "date": DAY}},
    {"a/b": {"inPer1M": True, "outPer1M": 2, "date": DAY}},
    {"a/b": {"inPer1M": float("nan"), "outPer1M": 2, "date": DAY}},
    {"a/b": {"inPer1M": 1, "outPer1M": 2}},                                   # a price with no date is not a fact the page can show
    {"a/b": {"inPer1M": 1, "outPer1M": 2, "date": "2026-13-45"}},
    {"a/b": {"inPer1M": 1, "outPer1M": 2, "date": "30 Oct"}},
    {"a/b": {"inPer1M": 1, "date": DAY}},
    {"a/b": {"inPer1M": 1, "outPer1M": 2, "date": DAY, "currency": "EUR"}},
    {"a b": {"inPer1M": 1, "outPer1M": 2, "date": DAY}},
    {"a/b": 3}, [1, 2], "free",
])
def test_a_bad_site_price_is_refused(bad):
    with pytest.raises(ml.LifecycleError):
        ml.parse({"frontier": {"prices": bad}})


# ---------------------------------------------------------------- costs_for

def report(prices=None, source=None):
    return SimpleNamespace(prices=prices or {}, price_source=source if source is not None else {})


def reading(data, state="ok", reason=""):
    return Reading("src", state, data, reason)


MODELS = {"anthropic/claude-sonnet-5-5": ["frontier-chat"], "anthropic/claude-opus-5-5": [], "openai/gpt-5.1": []}
SPEND_Q = "sum by (model_group) (increase(litellm_spend_metric_total[7d]))"
DEMAND_Q = "sum by (model_group) (increase(litellm_deployment_success_responses_total[7d]))"
MAP_PRICE = {"inPer1M": 3.0, "outPer1M": 15.0, "readAt": "2026-10-29", "stale": False}


def lc_with(prices=None):
    return ml.parse(lifecycle_doc(frontier={"prices": prices} if prices else {}))


def costs(lc=None, rep=None, spend=None, demand=None, **kw):
    return fc.costs_for(lc or lc_with(), rep, spend, demand, MODELS, spend_query=kw.pop("spend_query", SPEND_Q),
                        demand_query=kw.pop("demand_query", DEMAND_Q), **kw)


def test_a_price_map_price_carries_its_label_and_the_day_it_was_read():
    c = costs(rep=report({"anthropic/claude-sonnet-5-5": MAP_PRICE}, {"ok": True, "readAt": "2026-10-29"}))["anthropic/claude-sonnet-5-5"]
    assert (c.price_in, c.price_out, c.price_text) == (3.0, 15.0, "$3.00 / $15.00")
    assert c.price_source == "LiteLLM price map" and c.price_date == "2026-10-29" and c.price_note == "LiteLLM price map, read 2026-10-29"
    assert "price" not in c.reasons


def test_a_price_whose_last_read_failed_says_last_read():
    c = costs(rep=report({"anthropic/claude-sonnet-5-5": {**MAP_PRICE, "stale": True}}, {"ok": False, "reason": "unreachable"}))["anthropic/claude-sonnet-5-5"]
    assert c.price_note == "LiteLLM price map, last read 2026-10-29" and c.price_stale


def test_the_sites_price_wins_and_is_labelled_set_by_this_site():
    site = {"anthropic/claude-sonnet-5-5": {"inPer1M": 2.5, "outPer1M": 12.0, "date": "2026-10-30"}}
    c = costs(lc=lc_with(site), rep=report({"anthropic/claude-sonnet-5-5": MAP_PRICE}, {"ok": True}))["anthropic/claude-sonnet-5-5"]
    assert c.price_text == "$2.50 / $12.00" and c.price_source == "set by this site" and c.price_note == "set by this site, 2026-10-30"


def test_a_site_price_works_with_no_watcher_report_at_all():
    c = costs(lc=lc_with(SITE), rep=None)
    assert c["anthropic/claude-sonnet-5-5"].price_known and not c["openai/gpt-5.1"].price_known


@pytest.mark.parametrize("rep,why", [
    (None, "no watcher report is available"),
    (report(), "the watcher did not read prices"),                                                       # an older watcher, or watch.prices.enabled false
    (report(source={"ok": False, "reason": "unreachable"}), "could not be read (unreachable) and no earlier price is recorded"),
    (report(source={"ok": True, "readAt": DAY}), "has no price for this model"),
])
def test_a_missing_price_reads_unknown_with_the_reason(rep, why):
    c = costs(rep=rep)["openai/gpt-5.1"]
    assert not c.price_known and c.price_text == "unknown" and c.price_note == "" and why in c.reasons["price"]
    assert c.price_in is None and c.price_out is None


def test_prices_with_cents_and_fractions():
    assert [fc.price_text(v) for v in (0, 0.075, 0.1, 3, 15, 1250, 0.00005, 2.5)] == ["$0.00", "$0.075", "$0.10", "$3.00", "$15.00", "$1,250.00",
                                                                                    "$0.0001", "$2.50"]


def test_spend_and_calls_come_from_the_gateways_series_with_the_window_each_query_names():
    c = costs(spend=reading({"frontier-chat": 12.5}), demand=reading({"frontier-chat": 1234.4}),
              spend_query=SPEND_Q.replace("7d", "30d"))["anthropic/claude-sonnet-5-5"]
    assert (c.spend, c.spend_window, c.spend_text) == (12.5, "30 d", "$12.50")
    assert (c.calls, c.calls_window, c.calls_text) == (1234.4, "7 d", "1,234")
    assert "spend" not in c.reasons and "calls" not in c.reasons


def test_a_series_keyed_by_the_model_matches_with_or_without_its_provider():
    for key in ("claude-sonnet-5-5", "anthropic/claude-sonnet-5-5"):
        c = costs(spend=reading({key: 3.0}), demand=reading({key: 7}))
        assert c["anthropic/claude-sonnet-5-5"].spend == 3.0 and c["anthropic/claude-sonnet-5-5"].calls == 7
        assert c["anthropic/claude-opus-5-5"].spend is None                                              # nobody counted it


def test_spend_and_calls_unknown_never_zero_and_the_reason_says_why():
    c = costs(spend=None, demand=None)["anthropic/claude-sonnet-5-5"]
    assert c.spend is None and c.calls is None and c.spend_text == "unknown" and c.calls_text == "unknown"
    assert "modelLifecycle.budget.spendQuery" in c.reasons["spend"] and "modelLifecycle.demandQuery" in c.reasons["calls"]
    down = costs(spend=reading({"frontier-chat": 9.0}, "unknown", "HTTP 500"), demand=reading({}, "unknown", "timed out"))["anthropic/claude-sonnet-5-5"]
    assert down.spend is None and down.calls is None                                                     # an Unknown reading keeps last data, but not as today's
    assert "HTTP 500" in down.reasons["spend"] and "timed out" in down.reasons["calls"]
    none_for_it = costs(spend=reading({"other-alias": 1.0}), demand=reading({"other-alias": 4}))["anthropic/claude-sonnet-5-5"]
    assert none_for_it.spend is None and "no series for this model" in none_for_it.reasons["spend"]
    assert "never called, or not counted" in none_for_it.reasons["calls"]


def test_a_measured_zero_is_zero_and_is_not_unknown():
    c = costs(spend=reading({"frontier-chat": 0.0}), demand=reading({"frontier-chat": 0.0}))["anthropic/claude-sonnet-5-5"]
    assert c.spend == 0.0 and c.spend_text == "$0.00" and c.calls == 0.0 and c.calls_text == "0"


def test_a_query_that_names_no_window_has_no_window_text():
    assert bg.window_text("sum(litellm_spend_metric_total)") == "" and bg.window_text("x[30d]") == "30 d" and bg.window_text("x[2w]") == "2 w"
    assert bg.window_text("x[90m]") == "90 min" and bg.window_text("") == ""


def test_the_price_footer_names_the_source_and_the_day():
    mixed = costs(lc=lc_with({"openai/gpt-5.1": {"inPer1M": 1.0, "outPer1M": 2.0, "date": DAY}}),
                  rep=report({"anthropic/claude-sonnet-5-5": MAP_PRICE}, {"ok": True}))
    assert fc.price_footer(mixed) == "Prices: LiteLLM price map, read 2026-10-29; set by this site for 1 model; unknown for 1 model."
    stale = costs(rep=report({"anthropic/claude-sonnet-5-5": {**MAP_PRICE, "stale": True}}, {"ok": False, "reason": "unreachable"}))
    assert "LiteLLM price map, last read 2026-10-29" in fc.price_footer(stale) and "latest read failed" in fc.price_footer(stale)
    none = fc.price_footer(costs(rep=None))
    assert none.startswith("Prices: unknown. No watcher report is available") and "LiteLLM price map, read" not in none


# ---------------------------------------------------------------- top callers

CALLERS = [
    {"labels": {"api_key_alias": "ci-bot", "model": "claude-sonnet-5-5"}, "value": 40.0},
    {"labels": {"api_key_alias": "ci-bot", "model": "claude-opus-5-5"}, "value": 25.0},
    {"labels": {"api_key_alias": "alice", "model": "claude-sonnet-5-5"}, "value": 60.0},
    {"labels": {"api_key_alias": "None", "team_alias": "platform", "model": "claude-sonnet-5-5"}, "value": 5.0},
    {"labels": {"api_key_alias": "", "team_alias": "", "model": "claude-sonnet-5-5"}, "value": 1.25},
    {"labels": {"hashed_api_key": "abc123", "model": "claude-sonnet-5-5"}, "value": 2.0},
    {"labels": {"api_key_alias": "zero", "model": "claude-sonnet-5-5"}, "value": 0.0},
    {"labels": {"api_key_alias": "bob", "model": "gpt-5.1"}, "value": 99.0},
    {"labels": {"api_key_alias": "carol", "model": "claude-sonnet-5-5"}, "value": 3.0},
    {"labels": {"api_key_alias": "dave", "model": "claude-sonnet-5-5"}, "value": 0.5},
]
CALLER_Q = "sum by (api_key_alias, team_alias, hashed_api_key, model) (increase(litellm_spend_metric_total[7d]))"


def test_top_callers_adds_a_callers_series_and_ranks_the_top_five_by_cost():
    keys = fc.model_keys("anthropic/claude-sonnet-5-5", ["frontier-chat"])
    t = fc.top_callers(reading(CALLERS), keys, query=CALLER_Q)
    assert [(x["caller"], x["usd"]) for x in t.callers] == [("alice", 60.0), ("ci-bot", 40.0), ("platform", 5.0), ("carol", 3.0), ("abc123", 2.0)]
    assert t.window == "7 d" and t.reason == "" and t.callers[0]["text"] == "$60.00" and t.callers[2]["label"] == "team_alias"
    assert not any(x["caller"] in ("bob", "zero") for x in t.callers)                                    # another model's caller; a zero is not a caller


def test_top_callers_for_a_family_adds_its_models():
    keys = set(fc.model_keys("anthropic/claude-sonnet-5-5", [])) | set(fc.model_keys("anthropic/claude-opus-5-5", []))
    t = fc.top_callers(reading(CALLERS), keys, limit=2)
    assert [(x["caller"], x["usd"]) for x in t.callers] == [("ci-bot", 65.0), ("alice", 60.0)]          # ci-bot: sonnet 40 + opus 25


def test_a_caller_with_no_label_is_listed_as_such_not_dropped():
    t = fc.top_callers(reading(CALLERS), fc.model_keys("anthropic/claude-sonnet-5-5", []), limit=10)
    assert ("no key alias or team", 1.25) in [(x["caller"], x["usd"]) for x in t.callers]


def test_top_callers_unknown_with_a_reason():
    keys = fc.model_keys("anthropic/claude-sonnet-5-5", [])
    assert "spendByCallerQuery" in fc.top_callers(None, keys).reason and fc.top_callers(None, keys).callers == ()
    assert "HTTP 500" in fc.top_callers(reading([], "unknown", "HTTP 500"), keys).reason
    assert "no spend for these models" in fc.top_callers(reading(CALLERS), fc.model_keys("openai/nothing", [])).reason


def test_the_budget_settings_accept_the_caller_query():
    cfg_, problems = bg.parse_budget({"spendByCallerQuery": CALLER_Q, "spendQuery": SPEND_Q})
    assert cfg_["spendByCallerQuery"] == CALLER_Q and problems == []
    assert bg.parse_budget({"spendByCallerQuery": 7})[1] == ["modelLifecycle.budget.spendByCallerQuery must be a PromQL string"]
    assert bg.parse_budget(None)[0]["spendByCallerQuery"] == ""


# ---------------------------------------------------------------- the Models page

def prom_h(demand=None, spend=None, callers=None, fail=False):
    def h(req):
        if fail:
            return httpx.Response(500)
        q = req.url.params.get("query", "")
        if "api_key_alias" in q:
            res = [{"metric": r["labels"], "value": [0, str(r["value"])]} for r in (callers or [])]
        else:
            src = spend if "spend" in q else demand
            res = [{"metric": {"model_group": k}, "value": [0, str(v)]} for k, v in (src or {}).items()]
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": res}})
    return h


def plain(t):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(t))).strip()


def cells(row):
    return [plain(x) for x in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", row, re.S)]


MAP_REPORT = {"prices": {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "readAt": "2026-10-29"}},
              "price_source": {"ok": True, "reason": "", "readAt": "2026-10-29"}}


def page(tmp_path, **kw):
    c, _u = rich_client(tmp_path, **kw)
    return c.get("/models").text


def test_the_frontier_rows_show_price_spend_and_calls_with_the_source_footer(tmp_path):
    t = page(tmp_path, prometheus=prom_h(demand={"frontier-chat": 1234}, spend={"frontier-chat": 12.5}),
             budget={"spendQuery": SPEND_Q}, **MAP_REPORT,
             frontier={"prices": {"openai/gpt-5.1": {"inPer1M": 1.25, "outPer1M": 10.0, "date": DAY}}})
    fp = frontier_of(t)
    heads = [plain(x) for x in re.findall(r'<th scope="col"[^>]*>(.*?)</th>', fp.split("</thead>", 1)[0])]
    assert heads[:6] == ["Model", "Gateway alias", "Stage", "Price per 1M tokens, in / out", "Spend (7 d)", "Calls (7 d)"]
    sonnet = cells(frow(fp, "anthropic/claude-sonnet-5-5"))
    assert sonnet[3:] == ["$3.00 / $15.00 LiteLLM price map, read 2026-10-29", "$12.50", "1,234"]
    gpt = cells(frow(fp, "openai/gpt-5.1"))
    assert gpt[3] == "$1.25 / $10.00 set by this site, 2026-10-30"                                       # the site's own price, labelled
    assert gpt[4].startswith("unknown") and gpt[5].startswith("unknown")                                 # not routed: no series, never 0
    opus = cells(frow(fp, "anthropic/claude-opus-5-5"))
    assert opus[3].startswith("unknown") and "has no price for this model" in opus[3] and "$0" not in " ".join(opus[3:])
    foot = plain(fp.split('class="srcline"', 1)[1].split("</p>", 1)[0])
    assert "Prices: LiteLLM price map, read 2026-10-29; set by this site for 1 model; unknown for 2 models." in foot
    assert "not what was paid" in foot and "never an estimate" in foot
    assert "Price and spend are not recorded yet." not in t and "Spend this month" not in t


def test_the_headers_carry_the_window_the_queries_cover(tmp_path):
    t = page(tmp_path, prometheus=prom_h(demand={"frontier-chat": 5}, spend={"frontier-chat": 1.0}),
             budget={"spendQuery": SPEND_Q.replace("7d", "30d")}, demandQuery=DEMAND_Q.replace("7d", "30d"))
    fp = plain(frontier_of(t))
    assert "Spend (30 d)" in fp and "Calls (30 d)" in fp and "Spend (7 d)" not in fp and "this month" not in fp


def test_with_nothing_configured_every_figure_is_unknown_with_its_reason_on_hover(tmp_path):
    t = page(tmp_path, prometheus=prom_h(fail=True))
    fp = frontier_of(t)
    row_ = frow(fp, "anthropic/claude-sonnet-5-5")
    assert cells(row_)[3].startswith("unknown") and "$" not in " ".join(cells(row_)[3:])
    assert 'title="no watcher report is available' not in row_                                          # a report is configured here, with no prices:
    assert 'title="the watcher did not read prices' in row_
    assert 'title="no spend query is configured (modelLifecycle.budget.spendQuery)"' in row_
    assert "the request query did not answer, or returned nothing" in row_
    assert "Prices: unknown." in plain(fp)
    assert "Spend" in plain(fp) and "Spend (" not in plain(fp)                                           # no spend query, so no window to name


def test_a_failed_price_read_shows_last_read_and_the_footer_says_so(tmp_path):
    t = page(tmp_path, prices={"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "readAt": "2026-10-20", "stale": True}},
             price_source={"ok": False, "reason": "unreachable", "readAt": "2026-10-20"})
    fp = frontier_of(t)
    assert cells(frow(fp, "anthropic/claude-sonnet-5-5"))[3] == "$3.00 / $15.00 LiteLLM price map, last read 2026-10-20"
    assert "could not be read (unreachable)" in frow(fp, "openai/gpt-5.1") and "LiteLLM price map, last read 2026-10-20" in plain(fp)


def test_a_site_price_shows_with_no_watcher_report_at_all(tmp_path):
    lcd = lifecycle_doc(frontier={"prices": SITE}, catalog=[{"id": "claude-sonnet-5-5", "model": "anthropic/claude-sonnet-5-5", "stage": "promoted",
                                                             "adopted": "2026-10-07", "source": {"kind": "hosted", "ref": "anthropic/claude-sonnet-5-5"}}])
    c, _u = page_client(tmp_path, lifecycle=lcd, gateway=[FRONTIER_CHAT])
    fp = frontier_of(c.get("/models").text)
    assert cells(frow(fp, "anthropic/claude-sonnet-5-5"))[3] == "$3.00 / $15.00 set by this site, 2026-10-30"
    assert "Prices: set by this site for 1 model." in plain(fp)


def test_top_callers_show_on_the_family_row_only_when_the_query_is_set(tmp_path):
    t = page(tmp_path, prometheus=prom_h(callers=CALLERS), budget={"spendByCallerQuery": CALLER_Q})
    sonnet = frontier_of(t).split("<code>claude-sonnet</code>", 1)[1].split('<tr class="gen">', 1)[0]
    assert '<details class="callers"><summary>Top callers by cost (7 d)</summary>' in sonnet
    rows = [cells(r) for r in re.findall(r"<tr><th scope=\"row\">.*?</tr>", sonnet, re.S)]
    assert rows[:3] == [["alice", "$60.00"], ["ci-bot", "$40.00"], ["platform", "$5.00"]]                # the family's models only: opus is another family
    assert "bob" not in sonnet                                                                           # that caller used gpt-5.1


def test_no_callers_table_when_the_caller_query_is_not_set(tmp_path):
    assert 'class="callers"' not in page(tmp_path, prometheus=prom_h(callers=CALLERS))


def test_top_callers_unknown_when_the_query_answers_nothing(tmp_path):
    t = page(tmp_path, prometheus=prom_h(callers=[]), budget={"spendByCallerQuery": CALLER_Q})
    sonnet = frontier_of(t).split("<code>claude-sonnet</code>", 1)[1].split('<tr class="gen">', 1)[0]
    assert "unknown: the caller spend query did not answer, or returned nothing" in plain(sonnet)


def test_the_frontier_section_has_no_inline_style_script_or_handler(tmp_path):
    t = page(tmp_path, prometheus=prom_h(demand={"frontier-chat": 5}, spend={"frontier-chat": 1.0}, callers=CALLERS),
             budget={"spendQuery": SPEND_Q, "spendByCallerQuery": CALLER_Q}, **MAP_REPORT)
    fp = frontier_of(t)
    assert "style=" not in fp and "<script" not in fp and not re.search(r"\son[a-z]+\s*=", fp)


def test_a_caller_name_is_escaped(tmp_path):
    evil = [{"labels": {"api_key_alias": "<img src=x onerror=alert(1)>", "model": "claude-sonnet-5-5"}, "value": 5.0}]
    t = page(tmp_path, prometheus=prom_h(callers=evil), budget={"spendByCallerQuery": CALLER_Q})
    assert "<img src=x" not in t and "&lt;img src=x" in t


# ---------------------------------------------------------------- the family alias page (TM-1297's page, TM-1298's figures)

def family_page(tmp_path, **kw):
    from tests.test_models_frontier import gateway, gw_lifecycle
    c, _u = page_client(tmp_path, lifecycle=gw_lifecycle(), gateway=gateway(), candidates=[], **kw)
    return c.get("/models/a/claude-sonnet").text


def gen_row(t, alias):
    body = t.split('id="gens-cap"', 1)[1].split("</tbody>", 1)[0]
    return next(r for r in re.findall(r"<tr>.*?</tr>", body, re.S) if f'href="/models/a/{alias}"' in r)


def test_the_family_page_prices_each_generation_and_counts_the_floating_alias_on_the_current_one(tmp_path):
    t = family_page(tmp_path, prometheus=prom_h(demand={"claude-sonnet": 100, "claude-sonnet-5-5": 20, "claude-sonnet-4-5": 3},
                                                spend={"claude-sonnet": 9.0, "claude-sonnet-5-5": 1.0},
                                                callers=[{"labels": {"api_key_alias": "alice", "model": "claude-sonnet"}, "value": 7.0},
                                                         {"labels": {"api_key_alias": "ci-bot", "model": "claude-sonnet-4-5"}, "value": 2.0},
                                                         {"labels": {"api_key_alias": "eve", "model": "gpt-5.1"}, "value": 50.0}]),
                    budget={"spendQuery": SPEND_Q, "spendByCallerQuery": CALLER_Q},
                    prices={"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0, "readAt": "2026-10-29"}},
                    price_source={"ok": True, "reason": "", "readAt": "2026-10-29"},
                    frontier={"prices": {"anthropic/claude-sonnet-4-5": {"inPer1M": 3.0, "outPer1M": 15.0, "date": DAY}}})
    heads = [plain(x) for x in re.findall(r'<th scope="col"[^>]*>(.*?)</th>', t.split('id="gens-cap"', 1)[1].split("</thead>", 1)[0])]
    assert heads == ["Pinned alias", "Price per 1M tokens, in / out", "Spend (7 d)", "Calls (7 d)", "Status"]
    cur = cells(gen_row(t, "claude-sonnet-5-5"))
    assert cur[1:4] == ["$3.00 / $15.00 LiteLLM price map, read 2026-10-29", "$10.00", "120"]          # its own calls plus the floating alias's
    old = cells(gen_row(t, "claude-sonnet-4-5"))
    assert old[1:4] == ["$3.00 / $15.00 set by this site, 2026-10-30", "unknown" + old[2][7:], "3"] and old[2].startswith("unknown")
    mid = cells(gen_row(t, "claude-sonnet-5"))
    assert mid[1].startswith("unknown") and "has no price for this model" in mid[1] and "$0" not in " ".join(mid[1:4])
    p = plain(t)
    assert "Price per 1M tokens, in / out $3.00 / $15.00 LiteLLM price map, read 2026-10-29" in p          # what it points to now
    assert "Top callers by cost (7 d)" in p and "alice $7.00" in p and "ci-bot $2.00" in p and "eve $" not in p
    assert "not what was paid" in p and "never an estimate" in p and "not recorded yet" not in p
    assert "LiteLLM 1." not in p and "v1." not in p                                                     # no version in the label


def test_the_family_page_with_nothing_configured_reads_unknown_with_why_and_no_callers_panel(tmp_path):
    t = family_page(tmp_path)
    for g in ("claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-5"):
        row = cells(gen_row(t, g))
        assert all(x.startswith("unknown") for x in row[1:4]) and "$0" not in " ".join(row)
    assert "no spend query is configured (modelLifecycle.budget.spendQuery)" in html.unescape(t)
    assert "Top callers by cost" not in t
    assert "style=" not in t and "onclick" not in t and "<script" not in t

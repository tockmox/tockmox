# SPDX-License-Identifier: Apache-2.0
"""TM-1258: /models/budget. Requests per alias, the local share, and what hosted routes cost. A figure nobody has is Unknown,
never 0: an alias with no series may have had no traffic or may not be counted, and the page cannot tell which."""
import html
import re

from app import budget as bg
from tests.models_support import inventory_doc
from tests.pages_support import HOSTED_GATEWAY, page_client, prom


def plain(r):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(re.sub(r"<svg.*?</svg>", "", r.text, flags=re.S)))).strip()


DEMAND_Q = "sum by (model_group) (increase(litellm_deployment_success_responses_total[7d]))"
SPEND_Q = "sum by (model_group) (increase(litellm_spend_metric_total[7d]))"


def client(tmp_path, demand=None, spend=None, fail=False, budget=None, hosted=True, **kw):
    lc = {"demandQuery": DEMAND_Q}
    if budget is not None:
        lc["budget"] = budget
    from tests.models_support import lifecycle_doc
    return page_client(tmp_path, lifecycle=lifecycle_doc(**lc), gateway=HOSTED_GATEWAY if hosted else None,
                       prometheus=prom(demand, spend, fail), **kw)


def test_the_page_is_admin_only(tmp_path):
    c, _u = client(tmp_path, groups=["tockmox-users"])
    assert c.get("/models/budget").status_code == 403


def test_requests_and_the_local_share(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 750, "local-embed": 50, "big-hosted-chat": 200})
    r = c.get("/models/budget")
    t = plain(r)
    assert r.status_code == 200
    assert "750" in t and "200" in t and "50" in t and "1,000" in t
    assert "Local share 80.0% of 1,000 requests were served by your own nodes (800 local)" in t
    assert "75.0%" in t and "no per-request charge" in t


def test_hosted_cost_is_an_estimate_when_the_operator_gave_a_price(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100, "big-hosted-chat": 1000}, budget={"usdPerRequest": {"big-hosted-chat": 0.012}})
    t = plain(c.get("/models/budget"))
    assert "$12.00" in t and "estimate: 1,000 requests x $0.012 per request, as the operator set" in t


def test_hosted_cost_is_measured_when_the_spend_query_answers(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100, "big-hosted-chat": 1000}, spend={"big-hosted-chat": 9.5},
                   budget={"spendQuery": SPEND_Q, "usdPerRequest": {"big-hosted-chat": 0.5}})
    t = plain(c.get("/models/budget"))
    assert "$9.50" in t and "measured: the spend query's series 'big-hosted-chat'" in t and "$500.00" not in t       # measured beats an estimate


def test_hosted_cost_with_no_source_is_unknown_not_zero(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100, "big-hosted-chat": 1000})
    r = c.get("/models/budget")
    t = plain(r)
    assert "Unknown" in t and "no spend query is configured (modelLifecycle.budget.spendQuery)" in t
    assert "$0" not in t and "$0.00" not in t


def test_an_alias_with_no_series_is_unknown_not_zero_requests(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100})                                    # big-hosted-chat has no series
    t = plain(c.get("/models/budget"))
    assert "no series for this alias in the window (never called, or not counted)" in t
    assert "Unknown" in t and "big-hosted-chat" in t
    assert "Local share 100.0% of 100 requests" in t or "100.0%" in t                          # of what was counted


def test_when_prometheus_does_not_answer_every_figure_is_unknown(tmp_path):
    c, _u = client(tmp_path, fail=True, budget={"usdPerRequest": {"big-hosted-chat": 0.012}})
    r = c.get("/models/budget")
    t = plain(r)
    assert r.status_code == 200
    assert "$0" not in t and "0%" not in t.replace("100%", "")
    assert t.count("Unknown") >= 3 and "estimate:" not in t                                    # a price cannot make a cost out of a missing count


def test_a_price_with_an_unknown_request_count_is_unknown(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100}, budget={"usdPerRequest": {"big-hosted-chat": 0.012}})
    t = plain(c.get("/models/budget"))
    assert "a price is set but the request count is Unknown" in t


def test_a_malformed_budget_setting_is_reported_and_the_page_still_works(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100, "big-hosted-chat": 10},
                   budget={"spendQuery": 7, "usdPerRequest": {"big-hosted-chat": "free", "x": -1}})
    r = c.get("/models/budget")
    t = plain(r)
    assert r.status_code == 200
    assert "modelLifecycle.budget.spendQuery must be a PromQL string" in t
    assert "usdPerRequest.big-hosted-chat must be a number of dollars" in t and "usdPerRequest.x must be a number" in t


def test_a_page_with_no_hosted_route_says_there_is_nothing_to_price(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100}, hosted=False)
    t = plain(c.get("/models/budget"))
    assert "big-hosted-chat" not in t and "100" in t


def test_the_models_page_links_the_budget(tmp_path):
    c, _u = client(tmp_path, demand={"local-medium": 100})
    assert 'href="/models/budget"' in c.get("/models").text


# ------------------------------------------------------------ the pure build

class R:
    def __init__(self, data, state="ok"):
        self.data, self.state = data, state


def inv():
    from app import nodes as nm
    return nm.parse_inventory(inventory_doc())


def test_build_does_not_use_a_reading_that_is_unknown():
    out = bg.build(R({"local-medium": 100}, "unknown"), None, inv(), [], {})              # last good data, but the source is down now
    assert out["total_requests"] is None and out["local_share"] is None
    assert all(r["requests"] is None for r in out["rows"])


def test_build_share_counts_only_what_was_counted():
    out = bg.build(R({"local-medium": 30, "big-hosted-chat": 10}), None, inv(), HOSTED_GATEWAY, {})
    assert out["local_share"] == 0.75 and out["unknown_aliases"] == ["local-embed"]
    by = {r["alias"]: r for r in out["rows"]}
    assert by["local-embed"]["requests"] is None and by["local-embed"]["requests_text"] == "Unknown"


def test_build_a_partial_hosted_cost_is_flagged():
    gw = HOSTED_GATEWAY + [{"model_name": "other-hosted", "litellm_params": {"model": "openai/example-x", "api_key": "os.environ/K"}}]
    out = bg.build(R({"big-hosted-chat": 10, "other-hosted": 5}), None, inv(), gw, {"usdPerRequest": {"big-hosted-chat": 1.0}})
    assert out["hosted_cost"] == 10.0 and out["hosted_cost_partial"] is True and out["hosted_unknown"] == ["other-hosted"]


def test_hosted_model_is_a_provider_route_without_our_api_base():
    h = bg.hosted_model
    assert h({"litellm_params": {"model": "anthropic/x"}}) == "anthropic/x"
    assert h({"litellm_params": {"model": "openai/x", "api_base": "http://192.0.2.5:8080/v1"}}) == ""
    assert h({"litellm_params": {"model": "anthropic/x"}, "model_info": {"endpoint_tier": "local"}}) == ""
    assert h({"litellm_params": {"model": "plain-name"}}) == ""


def test_money_never_rounds_a_real_cost_to_zero():
    assert bg.money(0.004) == "under $0.01" and bg.money(0) == "$0.00" and bg.money(1234.5) == "$1,234.50"

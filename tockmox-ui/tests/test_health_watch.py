# SPDX-License-Identifier: Apache-2.0
"""TM-1263 / TM-1274 (REQ-0048 AC-48.19): the production health watch.

A fake Prometheus (an httpx MockTransport) serves synthetic gateway series for one promoted alias, and the tests
plant the cases the acceptance criterion names: a breach renders the revert, an inconclusive signal renders nothing,
too little data never breaches, and a time-of-day shift that is normal at like hours is not a breach."""
import json
import math
from datetime import datetime, timezone

import httpx
import pytest
import yaml

from app import health_watch as hw
from app import models as ml
from app import nodes as nm
from tests.test_reject_revert import NEW, OLD, promoted_world

ALIAS = "local-medium"
DAY = 86400
NOW = int(datetime(2026, 10, 29, 14, 7, tzinfo=timezone.utc).timestamp())        # 14:07Z, inside the busy hours below
PROMOTED = int(datetime(2026, 10, 26, 9, 0, tzinfo=timezone.utc).timestamp())    # three days earlier
LES = [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, math.inf]


def busy(ts):
    """The window ending at ts sits mostly inside 12:00-15:00Z, when this site's traffic peaks."""
    return 12 <= datetime.fromtimestamp(ts - 1800, timezone.utc).hour < 15


class Scn:
    """One synthetic alias. Every function takes (ts, after) with after = the window ends after the promotion."""

    def __init__(self, promoted=PROMOTED, history=True):
        self.promoted, self.history = promoted, history
        self.reqs = lambda ts, after: 400.0 if busy(ts) else 100.0
        self.err = lambda ts, after: 0.10 if busy(ts) else 0.005             # errors are worse at the peak, before and after
        self.lat = lambda ts, after: 2                                        # index into LES where 96% of requests land
        self.tool = lambda ts, after: 0.02
        self.drop = lambda ts: False
        self.fail = False
        self.queries = []

    def total(self, ts):
        after = ts > self.promoted
        if not self.history and not after:
            return None
        return None if self.drop(ts) else self.reqs(ts, after)

    def handler(self, request: httpx.Request) -> httpx.Response:
        if self.fail:
            return httpx.Response(500, text="boom")
        q = request.url.params["query"]
        self.queries.append(q)
        start, end, step = (int(float(request.url.params[k])) for k in ("start", "end", "step"))
        stamps = range(start, end + 1, step)

        def series(fn, labels=None):
            vals = [[ts, str(v)] for ts in stamps if (v := fn(ts)) is not None]
            return [{"metric": labels or {}, "values": vals}] if vals else []

        if "model=~" in q:                                                    # when did the promoted model first serve
            res = series(lambda ts: 5.0 if ts > self.promoted else None)
        elif "_bucket" in q:
            res = []
            for i, le in enumerate(LES):
                def cum(ts, i=i):
                    n = self.total(ts)
                    if n is None:
                        return None
                    k = self.lat(ts, ts > self.promoted)
                    return n * (0.0 if i < k else 0.96 if i == k else 1.0)
                res += series(cum, {"le": "+Inf" if le == math.inf else str(le)})
        elif "tool_parse_fail" in q:
            res = series(lambda ts: None if self.total(ts) is None else self.total(ts) * self.tool(ts, ts > self.promoted))
        elif "tool_calls_total" in q:
            res = series(self.total)
        elif "status_code!~" in q:
            res = series(lambda ts: None if self.total(ts) is None else self.total(ts) * self.err(ts, ts > self.promoted))
        else:
            res = series(self.total)
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "matrix", "result": res}})

    def prom(self):
        return hw.Prom("http://prometheus.test:9090", transport=httpx.MockTransport(self.handler))


def world(promoted_at=None):
    lc, inv = promoted_world()
    if promoted_at is not None:
        lc.by_model(NEW).promotion["promotedAt"] = promoted_at
    return lc, inv


def judge(scn, rules=None, lc_inv=None, now=NOW, soak=14):
    lc, inv = lc_inv or world()
    return hw.watch(lc, inv, scn.prom(), rules or hw.Rules(), soak, now)["aliases"][ALIAS]


# ---------------------------------------------------------------- planted breach, planted inconclusive

def planted_breach():
    s = Scn()
    s.err = lambda ts, after: (0.30 if after else 0.10) if busy(ts) else 0.005       # triple the peak error rate
    return s


class FakeForge:
    kind = "github"

    def __init__(self, values, open_branches=()):
        self.values, self.branches, self.opened, self.labelled = values, set(open_branches), [], []

    def read_file(self, path, ref):
        return yaml.safe_dump(self.values), "filesha"

    def open_branches(self):
        return self.branches

    def open_pr(self, base, spec, path, file_sha, message):
        self.opened.append((spec, message))
        return "https://forge.test/acme/site/pull/42"

    def _req(self, method, path, body=None, ok=(200, 201)):
        self.labelled.append((method, path, body))
        return {}


class Phone:
    def __init__(self):
        self.posts = []
        self.ntfy = hw.Ntfy("http://ntfy.test", "alerts", "tok", transport=httpx.MockTransport(self.handle))

    def handle(self, request):
        self.posts.append((str(request.url), dict(request.headers), request.content.decode()))
        return httpx.Response(200, json={})


def values_doc():
    lc, inv = promoted_world()
    return {"modelLifecycle": ml.to_doc(lc), "inferenceNodes": nm.inventory_to_doc(inv)}


PR_CFG = {"baseBranch": "main", "valuesPath": "site/values/models.yaml", "commitTrailers": ["Tockmox-Origin: health-watch"]}


def run_act(res, hwcfg=None, forge=None, phone=None, apply=True):
    forge = forge or FakeForge(values_doc())
    phone = phone or Phone()
    report = {"generated": "2026-10-29T14:07:00Z", "aliases": {ALIAS: res}}
    cfg = {"pullRequests": True, **(hwcfg or {})}
    return hw.act(report, forge, phone.ntfy, cfg, PR_CFG, apply=apply, log=lambda *_: None), forge, phone


def test_a_planted_breach_is_judged_a_breach_and_renders_the_revert():
    res = judge(planted_breach())
    assert res["state"] == hw.BREACH and res["baseline"] == "previous"
    assert res["metrics"]["errorRate"]["state"] == hw.BREACH
    assert "30.0%" in res["metrics"]["errorRate"]["reason"] and "10.0%" in res["metrics"]["errorRate"]["reason"]
    acted, forge, phone = run_act(res)
    spec = acted[ALIAS]["spec"]
    assert spec is not None and spec.kind == "revert" and spec.branch == "tockmox/revert/local-medium"
    new = yaml.safe_load(spec.text)
    routes = {r["alias"]: r["model"] for r in new["inferenceNodes"]["routes"]}
    assert routes[ALIAS] == OLD                                              # the alias is back on what it served before
    stages = {e["model"]: e["stage"] for e in new["modelLifecycle"]["catalog"]}
    assert stages[NEW] == "rejected" and stages[OLD] == "promoted"
    rej = next(e for e in new["modelLifecycle"]["catalog"] if e["model"] == NEW)["rejection"]
    assert rej["reason"].startswith("health watch: errorRate") and rej["demoted"] is True
    assert ml.check_promotions(ml.parse(new["modelLifecycle"]), nm.parse_inventory(new["inferenceNodes"])) == []
    assert "```json" in spec.body and '"state": "breach"' in spec.body
    assert len(forge.opened) == 1 and acted[ALIAS]["url"].endswith("/pull/42")


def test_a_breach_sends_one_ntfy_message_that_replaces_the_last_for_the_alias():
    acted, forge, phone = run_act(judge(planted_breach()))
    assert len(phone.posts) == 1 and acted[ALIAS]["notified"] is True
    url, headers, body = phone.posts[0]
    assert url == "http://ntfy.test/alerts" and headers["authorization"] == "Bearer tok"
    assert headers["x-sequence-id"] == "tockmox-health-local-medium"
    assert "pull/42" in body and "errorRate" in body


def test_a_breach_with_no_pr_lane_still_tells_a_person():
    res = judge(planted_breach())
    phone = Phone()
    acted = hw.act({"generated": "2026-10-29T14:07:00Z", "aliases": {ALIAS: res}}, None, phone.ntfy, {}, PR_CFG, apply=True, log=lambda *_: None)
    assert acted[ALIAS]["spec"] is None and len(phone.posts) == 1
    assert "Revert it from the Models page" in phone.posts[0][2]


def test_a_planted_inconclusive_renders_nothing():
    # the newest window is over the limit but has not held: 1 of 3 judged windows. It waits.
    s = Scn()
    s.err = lambda ts, after: (0.40 if (after and ts >= NOW - NOW % 900) else 0.10) if busy(ts) else 0.005
    res = judge(s)
    assert res["state"] == hw.INCONCLUSIVE and "not yet held" in res["metrics"]["errorRate"]["reason"]
    acted, forge, phone = run_act(res)
    assert acted == {} and forge.opened == [] and phone.posts == []


def test_a_hole_in_the_series_is_inconclusive_and_renders_nothing():
    s = planted_breach()
    s.drop = lambda ts: ts == NOW - NOW % 900 - 900                           # one missing sample in the judged windows
    res = judge(s)
    assert res["state"] == hw.INCONCLUSIVE and "hole" in res["metrics"]["errorRate"]["reason"]
    acted, forge, phone = run_act(res, {"autoRevert": {ALIAS: True}})
    assert acted == {} and forge.opened == [] and phone.posts == []


def test_prometheus_down_is_inconclusive_never_a_breach_and_never_ok():
    s = Scn()
    s.fail = True
    res = judge(s, lc_inv=world(promoted_at="2026-10-26T09:00:00Z"))
    assert res["state"] == hw.INCONCLUSIVE and "did not answer" in res["reasons"][0]
    s2 = Scn()
    s2.fail = True
    res2 = judge(s2)                                                          # and when looking for the promotion time
    assert res2["state"] == hw.INCONCLUSIVE
    acted, forge, phone = run_act(res)
    assert acted == {} and forge.opened == [] and phone.posts == []


def test_one_inconclusive_signal_pauses_a_breach_on_another():
    s = planted_breach()
    s.lat = lambda ts, after: 3 if (after and ts == NOW - NOW % 900) else 2   # p95 over the limit only at the newest window
    res = judge(s)
    assert res["metrics"]["errorRate"]["state"] == hw.BREACH
    assert res["metrics"]["p95Latency"]["state"] == hw.INCONCLUSIVE
    assert res["state"] == hw.INCONCLUSIVE
    assert run_act(res)[0] == {}


# ---------------------------------------------------------------- insufficient data never breaches

def test_too_few_requests_never_breach_whatever_the_ratio():
    s = Scn()
    s.reqs = lambda ts, after: 10.0                                           # under minRequests (50) every window
    s.err = lambda ts, after: 1.0 if after else 0.0                           # every request fails after the promotion
    res = judge(s)
    assert res["state"] == hw.INSUFFICIENT
    assert run_act(res)[0] == {}


def test_a_thin_baseline_is_insufficient_even_when_the_current_traffic_is_large():
    s = Scn()
    s.reqs = lambda ts, after: 400.0 if after else 5.0                        # 7 like-hour windows x 5 = 35, under minRequests
    s.err = lambda ts, after: 0.5 if after else 0.0
    res = judge(s)
    assert res["state"] == hw.INSUFFICIENT and res["baseline"] == "previous"


def test_no_promotion_previous_is_insufficient_and_says_why():
    lc, inv = world()
    del lc.by_model(NEW).promotion["previous"]
    res = judge(Scn(), lc_inv=(lc, inv))
    assert res["state"] == hw.INSUFFICIENT and "no previous route" in res["reasons"][0]


def test_no_traffic_for_the_promoted_model_is_insufficient_and_names_the_label():
    s = Scn(promoted=NOW + DAY)                                               # the model never serves in the look-back
    res = judge(s)
    assert res["state"] == hw.INSUFFICIENT and "`model` label" in res["reasons"][0]


def test_just_promoted_means_the_windows_would_still_hold_the_previous_model():
    s = Scn(promoted=NOW - 1800)
    res = judge(s)
    assert res["state"] == hw.INSUFFICIENT and "previous model's requests" in res["reasons"][0]


# ---------------------------------------------------------------- like hours (TM-1274)

def shifted():
    """Identical behaviour before and after the promotion: the peak is simply worse than the quiet hours, as it always was."""
    return Scn()


def test_a_peak_hour_shift_that_is_normal_at_like_hours_is_not_a_breach():
    res = judge(shifted())
    assert res["state"] == hw.OK, res
    m = res["metrics"]["errorRate"]
    assert m["value"] == pytest.approx(0.10) and m["baselineValue"] == pytest.approx(0.10)


def test_the_same_series_compared_with_a_flat_mean_WOULD_breach():
    res = judge(shifted(), hw.Rules(like_hours=False))
    assert res["state"] == hw.BREACH, res                                     # 10% at the peak against a flat ~3.9%: the false alarm
    assert res["metrics"]["errorRate"]["baselineValue"] < 0.05


def test_latency_is_compared_at_like_hours_too():
    s = Scn()
    s.reqs = lambda ts, after: 100.0 if busy(ts) else 400.0                   # a quiet peak: few slow requests in a flat pool
    s.lat = lambda ts, after: 4 if busy(ts) else 1                            # the peak's p95 is 8s-ish before and after
    assert judge(s)["metrics"]["p95Latency"]["state"] == hw.OK
    assert judge(s, hw.Rules(like_hours=False))["metrics"]["p95Latency"]["state"] == hw.BREACH


def test_a_baseline_of_zero_failures_does_not_make_a_few_failures_a_breach():
    s = Scn()
    s.err = lambda ts, after: 0.005 if after else 0.0                         # 2 failures in 400 against none before
    res = judge(s)
    assert res["metrics"]["errorRate"]["state"] == hw.OK and res["state"] == hw.OK
    s.err = lambda ts, after: 0.05 if after else 0.0                          # 5% against none: that is a breach
    assert judge(s)["state"] == hw.BREACH


def test_p95_over_the_ratio_is_a_breach_and_names_seconds():
    s = Scn()
    s.lat = lambda ts, after: 3 if after else 2
    res = judge(s)
    assert res["state"] == hw.BREACH and res["metrics"]["p95Latency"]["state"] == hw.BREACH
    assert res["metrics"]["errorRate"]["state"] == hw.OK and "s against" in res["metrics"]["p95Latency"]["reason"]


# ---------------------------------------------------------------- provisional baseline

def test_without_history_the_first_day_is_the_baseline_and_is_called_provisional():
    s = Scn(history=False)                                                    # nothing before the promotion in range
    res = judge(s)
    assert res["baseline"] == "provisional" and res["state"] == hw.OK
    assert res["reasons"][0].startswith("provisional")
    assert "first 24h" in res["metrics"]["errorRate"]["reason"]


def test_a_provisional_baseline_can_breach_once_its_first_day_is_over():
    s = Scn(history=False)
    s.err = lambda ts, after: (0.10 if ts < PROMOTED + DAY else 0.40) if busy(ts) else 0.005
    res = judge(s)
    assert res["state"] == hw.BREACH and res["baseline"] == "provisional"
    assert "provisional baseline" in res["metrics"]["errorRate"]["reason"]


def test_nothing_is_judged_inside_the_first_24_hours_of_a_provisional_baseline():
    s = Scn(promoted=NOW - 18 * 3600, history=False)
    res = judge(s)
    assert res["state"] == hw.INSUFFICIENT and "provisional baseline" in res["reasons"][0] and "not over" in res["reasons"][0]


# ---------------------------------------------------------------- soak, tool-call parse failures, thumbs

def test_past_the_soak_window_the_alias_is_not_watched():
    res = judge(Scn(promoted=NOW - 20 * DAY), soak=14)
    assert res["state"] == hw.OK and "no longer watched" in res["reasons"][0] and res["metrics"] == {}
    res2 = judge(Scn(), lc_inv=world(promoted_at="2026-09-01T00:00:00Z"))
    assert res2["state"] == hw.OK and "no longer watched" in res2["reasons"][0]


def test_tool_parse_failures_and_thumbs_are_unknown_until_there_is_a_metric():
    res = judge(Scn())
    assert res["metrics"]["toolParseFailures"]["state"] == hw.UNKNOWN and "tockmox_gate.py" in res["metrics"]["toolParseFailures"]["reason"]
    assert "toolParseMetrics" in res["metrics"]["toolParseFailures"]["reason"]
    assert res["metrics"]["thumbs"]["state"] == hw.UNKNOWN and "TODO" in res["metrics"]["thumbs"]["reason"]
    assert res["state"] == hw.OK                                              # unknown signals neither pass nor fail an alias


def test_tool_parse_failures_above_twice_the_baseline_for_30_minutes_breach_when_the_site_counts_them():
    rules = hw.parse_rules({"toolParseMetrics": {"failures": "site_tool_parse_fail_total", "total": "site_tool_calls_total"}})
    rules.tool_parse_failures, rules.tool_parse_total = "tool_parse_fail_total", "tool_calls_total"
    s = Scn()
    s.tool = lambda ts, after: 0.09 if after else 0.02                        # 4.5x
    res = judge(s, rules)
    assert res["metrics"]["toolParseFailures"]["state"] == hw.BREACH and res["state"] == hw.BREACH
    assert judge(Scn(), rules)["metrics"]["toolParseFailures"]["state"] == hw.OK
    s.tool = lambda ts, after: 0.03 if after else 0.02                        # 1.5x: under the 2x rule
    assert judge(s, rules)["metrics"]["toolParseFailures"]["state"] == hw.OK


# ---------------------------------------------------------------- autoRevert, the PR lane

def test_auto_revert_is_off_by_default_for_every_alias():
    acted, forge, phone = run_act(judge(planted_breach()))
    spec, (_, message) = acted[ALIAS]["spec"], forge.opened[0]
    assert "auto-merge" not in spec.title and hw.AUTO_TRAILER not in message and "Auto-merge requested" not in spec.body
    assert forge.labelled == []
    assert "Tockmox-Origin: health-watch" in message


def test_auto_revert_on_for_an_alias_only_flags_the_pr():
    acted, forge, phone = run_act(judge(planted_breach()), {"autoRevert": {ALIAS: True}})
    spec, (_, message) = acted[ALIAS]["spec"], forge.opened[0]
    assert spec.title.endswith("[auto-merge requested]") and hw.AUTO_TRAILER in message and "Auto-merge requested" in spec.body
    assert forge.labelled == [("POST", "/issues/42/labels", {"labels": [hw.AUTO_LABEL]})]
    assert not hasattr(forge, "merge")                                         # the watch has no merge call to make
    other, forge2, _ = run_act(judge(planted_breach()), {"autoRevert": {"some-other-alias": True}})
    assert hw.AUTO_TRAILER not in forge2.opened[0][1]


def test_a_dry_run_opens_and_sends_nothing():
    acted, forge, phone = run_act(judge(planted_breach()), apply=False)
    assert acted[ALIAS]["spec"] is not None and forge.opened == [] and phone.posts == []


def test_a_revert_pr_already_open_is_not_opened_or_announced_again():
    acted, forge, phone = run_act(judge(planted_breach()), forge=FakeForge(values_doc(), {"tockmox/revert/local-medium"}))
    assert forge.opened == [] and phone.posts == [] and "already open" in acted[ALIAS]["note"]


def test_another_lifecycle_pr_open_defers_the_revert_but_still_tells_a_person():
    acted, forge, phone = run_act(judge(planted_breach()), forge=FakeForge(values_doc(), {"tockmox/promote/other"}))
    assert forge.opened == [] and acted[ALIAS]["spec"] is None and "one at a time" in acted[ALIAS]["note"]
    assert len(phone.posts) == 1 and "one at a time" in phone.posts[0][2]


def test_a_revert_the_repo_cannot_make_is_reported_not_forced():
    v = values_doc()
    for e in v["modelLifecycle"]["catalog"]:
        e.get("promotion", {}).pop("previous", None)
    acted, forge, phone = run_act(judge(planted_breach()), forge=FakeForge(v))
    assert forge.opened == [] and acted[ALIAS]["spec"] is None and "records no previous route" in acted[ALIAS]["note"]
    assert len(phone.posts) == 1


# ---------------------------------------------------------------- the pieces

def test_quantile_matches_histogram_quantile():
    cum = {0.5: 0.0, 1.0: 0.0, 2.0: 96.0, 4.0: 100.0, math.inf: 100.0}
    assert hw.quantile(0.95, cum) == pytest.approx(1.0 + 1.0 * 95 / 96)
    assert hw.quantile(0.95, {1.0: 0.0, math.inf: 0.0}) is None
    assert hw.quantile(0.95, {1.0: 50.0, math.inf: 100.0}) == 1.0              # the +Inf bucket answers with the top finite bound


def test_rules_have_the_contract_defaults_and_refuse_nonsense():
    r = hw.parse_rules({})
    assert (r.error_rate_ratio, r.p95_ratio, r.tool_parse_failure_ratio, r.min_requests, r.for_minutes, r.like_hours) == \
        (2.0, 1.5, 2.0, 50, 30, True)
    assert r.instants == 3
    with pytest.raises(ValueError, match="errorRateRatio"):
        hw.parse_rules({"errorRateRatio": 0.5})
    with pytest.raises(ValueError, match="multiple of 15"):
        hw.parse_rules({"windowMinutes": 20})
    with pytest.raises(ValueError, match="both failures and total"):
        hw.parse_rules({"toolParseMetrics": {"failures": "x_total"}})
    assert hw.parse_rules({"likeHours": False}).like_hours is False


def test_the_queries_are_the_gateway_metrics_the_alert_pack_uses():
    s = planted_breach()
    judge(s)
    joined = "\n".join(s.queries)
    assert 'litellm_proxy_total_requests_metric_total{requested_model="local-medium"}' in joined
    assert 'status_code!~"2.."' in joined and "litellm_request_total_latency_metric_bucket" in joined


def test_main_is_a_no_op_when_off_and_prints_the_status_when_on(tmp_path, monkeypatch, capsys):
    lc, inv = promoted_world()
    cfg = {"modelLifecycle": {**ml.to_doc(lc), "healthWatch": {"enabled": False}}, "inferenceNodes": nm.inventory_to_doc(inv)}
    p = tmp_path / "c.yaml"
    p.write_text(yaml.safe_dump(cfg))
    assert hw.main(["x", str(p)]) == 0 and "is off" in capsys.readouterr().err
    cfg["modelLifecycle"]["healthWatch"] = {"enabled": True, "prometheusUrl": "http://prometheus.test:9090"}
    p.write_text(yaml.safe_dump(cfg))
    s = planted_breach()
    real = hw.Prom
    monkeypatch.setattr(hw, "Prom", lambda url: real(url, transport=httpx.MockTransport(s.handler)))
    monkeypatch.setattr(hw.time, "time", lambda: NOW)
    assert hw.main(["x", str(p)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["schema"] == "health-watch/1" and out["aliases"][ALIAS]["state"] == "breach"
    cfg["modelLifecycle"]["healthWatch"]["prometheusUrl"] = ""
    p.write_text(yaml.safe_dump(cfg))
    assert hw.main(["x", str(p)]) == 2

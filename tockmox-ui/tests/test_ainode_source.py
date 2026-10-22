# SPDX-License-Identifier: Apache-2.0
"""Convergence and readiness read from Prometheus (design 3.4; ABSENCE IS NOT GREEN)."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _ainode_helpers import (FakeProm, NOW, P, SHA, converge_rows, flap_rows, info_row, inventory, mac, read,  # noqa: E402
                             readiness_rows, row)
from app import nodes as nm  # noqa: E402
from app import sources  # noqa: E402
from app.sources import CRIT, OK, UNKNOWN, WARN  # noqa: E402

UP = [row("up", 1, instance="10.0.0.5:9100")]


def one(prom, *nodes, ai=None):
    _, got = read(inventory(*nodes, ai=ai), prom)
    return got[nodes[0]["id"]]


def check(node, what):
    return next((c for c in node["checks"] if c["what"] == what), None)


# ---- absence is not green

def test_an_enrolled_node_with_no_converge_series_is_unknown_never_healthy():
    n = one(FakeProm(ai=[], up=UP), mac())
    assert n["convergence"]["state"] == UNKNOWN
    assert n["convergence"]["why"] == "this node has not reported a converge"
    assert check(n, "convergence")["state"] == UNKNOWN
    assert n["state"] != OK                       # the exporter is up, and that does not make the node healthy


def test_unknown_even_when_its_exporter_and_engine_probe_are_green():
    prom = FakeProm(ai=[], up=UP, )
    prom_rows = [row("probe_success", 1, instance="http://10.0.0.5:8080/v1/models")]
    orig = prom.handler

    def h(req):
        if req.url.params["query"] == "probe_success":
            import httpx
            return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": prom_rows}})
        return orig(req)
    prom.handler = h
    n = one(prom, mac())
    assert check(n, "mlx-lm on :8080")["state"] == OK
    assert n["state"] == UNKNOWN


def test_info_alone_is_not_a_converge():
    n = one(FakeProm(ai=[info_row()], up=UP), mac())
    assert n["convergence"]["state"] == UNKNOWN


def test_a_run_with_no_exit_code_cannot_be_called_healthy():
    n = one(FakeProm(ai=converge_rows(with_exit=False), up=UP), mac())
    assert n["convergence"]["state"] == UNKNOWN and "exit code" in n["convergence"]["why"]


def test_an_import_only_node_has_no_convergence_row_at_all():
    n = one(FakeProm(ai=[], up=UP), mac(enrolled=False))
    assert n["enrolled"] is False and n["convergence"] is None and n["readiness"] is None
    assert [c["what"] for c in n["checks"] if c["what"] in ("convergence", "readiness")] == []


def test_an_import_only_node_that_reports_is_hinted_not_judged():
    n = one(FakeProm(ai=converge_rows() + readiness_rows(), up=UP), mac(enrolled=False))
    assert n["convergence"] is None and n["reports_unenrolled"] is True
    assert check(n, "convergence") is None


# ---- the states

def test_healthy_when_the_last_success_is_recent_and_exit_is_zero():
    n = one(FakeProm(ai=converge_rows() + readiness_rows(), up=UP, flap=flap_rows(changed=0)), mac())
    c = n["convergence"]
    assert c["state"] == OK and c["exit_code"] == 0
    assert c["site_commit"] == SHA and c["site_commit_short"] == SHA[:8]
    assert c["toolkit_ref"] == "v0.9.0" and c["signing_mode"] == "warn"
    assert c["last_run_ago"] == "1 minute ago" or c["last_run_ago"].endswith("ago")


@pytest.mark.parametrize("ago,want", [(1799, OK), (1801, WARN), (2699, WARN), (2701, CRIT)])
def test_age_thresholds_are_two_and_three_intervals(ago, want):
    n = one(FakeProm(ai=converge_rows(success_ago=ago), up=UP), mac())
    assert n["convergence"]["state"] == want


def test_the_interval_follows_the_site_setting():
    prom = lambda: FakeProm(ai=converge_rows(success_ago=700), up=UP)  # noqa: E731
    assert one(prom(), mac(), ai={"convergeIntervalSeconds": 300})["convergence"]["state"] == WARN     # 700 > 2 x 300
    assert one(prom(), mac())["convergence"]["state"] == OK                                              # default 900


def test_a_non_zero_exit_is_a_problem_naming_the_phase():
    n = one(FakeProm(ai=converge_rows(exit_code=2, phase="verify"), up=UP), mac())
    c = n["convergence"]
    assert c["state"] == CRIT and "exited 2" in c["why"] and "verify" in c["why"] and c["failing_phase"] == "verify"
    assert n["state"] == CRIT


def test_a_non_zero_exit_with_no_phase_says_so():
    n = one(FakeProm(ai=converge_rows(exit_code=1), up=UP), mac())
    assert n["convergence"]["state"] == CRIT and "not reported" in n["convergence"]["why"]


def test_an_old_success_with_exit_zero_is_not_healthy():
    # the last run may be fresh and exit 0; if success timestamp is old the node is not healthy
    n = one(FakeProm(ai=converge_rows(success_ago=10_000, run_ago=30), up=UP), mac())
    assert n["convergence"]["state"] == CRIT


def test_an_unverified_signature_needs_a_look_in_warn_mode():
    n = one(FakeProm(ai=converge_rows(signature=0), up=UP), mac())
    assert n["convergence"]["state"] == WARN and "did not verify" in n["convergence"]["why"]
    assert "warn" in n["convergence"]["why"]


def test_flapping_needs_a_look():
    n = one(FakeProm(ai=converge_rows(changed=4), up=UP, flap=flap_rows(changed=4, runs=2, inputs=1)), mac())
    assert n["convergence"]["state"] == WARN and "undoing" in n["convergence"]["why"]


@pytest.mark.parametrize("flap", [
    flap_rows(changed=0, runs=2, inputs=1),     # some sample in the window changed nothing
    flap_rows(changed=3, runs=0, inputs=1),     # only one run seen
    flap_rows(changed=3, runs=2, inputs=2),     # the site commit moved: new work, not flapping
    {},                                         # no window readings at all
])
def test_not_flapping(flap):
    n = one(FakeProm(ai=converge_rows(changed=3), up=UP, flap=flap), mac())
    assert n["convergence"]["state"] == OK


def test_the_window_queries_use_three_intervals_and_only_run_when_a_node_is_enrolled():
    prom = FakeProm(ai=converge_rows(), up=UP)
    read(inventory(mac(), ai={"convergeIntervalSeconds": 300}), prom)
    win = [q for q in prom.queries if "[" in q]
    assert len(win) == 3 and all("[900s]" in q for q in win)
    prom = FakeProm(ai=[], up=UP)
    read(inventory(mac(enrolled=False)), prom)
    assert not [q for q in prom.queries if "[" in q]


def test_the_ai_node_label_is_the_only_match_so_another_nodes_series_does_not_leak():
    ai = converge_rows("other", success_ago=10) + readiness_rows("other")
    inv = inventory(mac("studio"), mac("other", address="10.0.0.6"))
    _, got = read(inv, FakeProm(ai=ai, up=UP))
    assert got["studio"]["convergence"]["state"] == UNKNOWN
    assert got["studio"]["readiness"]["state"] == UNKNOWN
    assert got["other"]["convergence"]["state"] == OK


# ---- readiness

def test_readiness_is_one_line_per_check():
    n = one(FakeProm(ai=readiness_rows(bad=("pf_anchor",)), up=UP), mac())
    r = n["readiness"]
    states = {i["check"]: i["state"] for i in r["items"]}
    assert set(states) == set(nm.READINESS_CHECKS) and states["pf_anchor"] == "problem"
    assert all(v == "ok" for k, v in states.items() if k != "pf_anchor")
    assert r["state"] == WARN and "pf_anchor" in r["why"]


def test_a_check_that_was_not_reported_is_unknown_by_name():
    miss = list(nm.READINESS_CHECKS)[:2]
    n = one(FakeProm(ai=readiness_rows(missing=miss), up=UP), mac())
    r = n["readiness"]
    assert {i["check"]: i["state"] for i in r["items"]}[miss[0]] == "unknown"
    assert r["state"] == UNKNOWN and miss[0] in r["why"]


def test_all_ok_readiness_is_ok_and_none_reported_is_unknown():
    assert one(FakeProm(ai=readiness_rows(), up=UP), mac())["readiness"]["state"] == OK
    r = one(FakeProm(ai=[], up=UP), mac())["readiness"]
    assert r["state"] == UNKNOWN and "has not reported" in r["why"]
    assert all(i["state"] == "unknown" for i in r["items"])


def test_the_readiness_check_list_has_ten_labelled_checks():
    assert len(nm.READINESS_CHECKS) == 10 and all(nm.READINESS_CHECKS.values())


# ---- measured facts

def test_measured_hardware_comes_from_the_info_series():
    n = one(FakeProm(ai=[info_row()], up=UP), mac())
    m = n["measured"]
    assert m["chip"] == "Apple M5 Ultra" and m["memory_gib"] == 256.0 and m["gpu_cores"] == "80" and m["os_version"] == "27.0"
    assert nm.FACT_SOURCES.count("measured") == 1


def test_disagreement_note_covers_recorded_vs_measured_memory():
    n = one(FakeProm(ai=[info_row(memory_gib="256")], up=UP), mac(memory=128, source="preset"))
    assert "128 GiB (preset)" in n["disagree"] and "measured 256 GiB" in n["disagree"]
    # within 1 GiB: silent
    assert one(FakeProm(ai=[info_row(memory_gib="128.5")], up=UP), mac(memory=128))["disagree"] == ""
    # a fact recorded from the same reporter cannot disagree with itself
    assert one(FakeProm(ai=[info_row(memory_gib="256")], up=UP), mac(memory=128, source="measured"))["disagree"] == ""


def test_the_evaluation_clock_is_the_series_timestamp_not_the_ui_clock():
    # the same numbers read at a very different wall clock still judge by what Prometheus evaluated
    n = one(FakeProm(ai=converge_rows(now=NOW + 5_000_000), up=UP), mac())
    assert n["convergence"]["state"] == OK


def test_assess_convergence_is_pure():
    rows = {}
    for r in converge_rows():
        rows.setdefault(r["metric"]["__name__"], []).append(r)
    a = sources.assess_convergence(rows, 900, None)
    b = sources.assess_convergence(rows, 900, None)
    assert a == b and a["state"] == OK

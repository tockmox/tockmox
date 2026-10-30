# SPDX-License-Identifier: Apache-2.0
"""TM-1258: the candidate page /models/c/<alias>: the plan for an evaluation and a strip of its run-status/1 files. A leg that
has not finished shows its numbers as partial and the page says nothing yet tells which model is better."""
import html
import json
import re

from app import candidate as cd
from tests.models_support import inventory_doc
from tests.pages_support import SUCC, REPO, iso, leg, page_client, status, with_next, write_status

NOT_BETTER = "Nothing here says which model is better until the verdict"


def plain(r):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(re.sub(r"<svg.*?</svg>", "", r.text, flags=re.S)))).strip()


def client(tmp_path, *docs, nxt=True, **kw):
    d = tmp_path / "status"
    (d / "runs").mkdir(parents=True, exist_ok=True)                                    # the runner has started, and has run nothing
    for x in docs:
        write_status(d, x)
    return page_client(tmp_path, inventory=with_next() if nxt else None, status_dir=d, **kw)


def test_the_page_is_admin_only(tmp_path):
    c, _u = client(tmp_path, groups=["tockmox-users"])
    assert c.get("/models/c/local-medium").status_code == 403


def test_an_alias_with_no_candidate_and_no_runs_is_a_404(tmp_path):
    c, _u = client(tmp_path, nxt=False)
    r = c.get("/models/c/local-medium")
    assert r.status_code == 404 and "has no candidate" in r.text


def test_the_plan_names_the_alias_the_incumbent_the_defaults_and_the_quiet_window(tmp_path):
    c, _u = client(tmp_path)
    r = c.get("/models/c/local-medium")
    t = plain(r)
    assert r.status_code == 200
    assert f"Competes for local-medium" in t and f"Candidate {SUCC}" in t and f"Incumbent {REPO} on beta" in t
    assert "Estimated wall time Unknown: no run has estimated it yet" in t
    for word in ("Known-bad control", "Smoke", "Performance", "Long-context prefill", "Tool-call reliability", "Quality"):
        assert word in t
    assert "The runner's default legs" in t
    assert "after 10 minute(s) with no production requests on the node" in t
    assert "No run is on record for local-medium" in t                                # no runs: said, not blank
    assert c.get("/models/c/local-medium-next").status_code == 200                      # either spelling


def test_the_quiet_window_is_the_one_the_chart_passes(tmp_path):
    c, _u = client(tmp_path, runner={"quietWindow": {"minutes": 25, "maxProductionRequests": 3}})
    t = plain(c.get("/models/c/local-medium"))
    assert "after 25 minute(s) with at most 3 production request(s)" in t


def test_a_queued_run_shows_its_plan_and_every_leg_queued(tmp_path):
    c, _u = client(tmp_path, status(state="queued"))
    t = plain(c.get("/models/c/local-medium"))
    assert "Estimated wall time about 2 h 10 min" in t and "Queued" in t and "next quiet window" in t
    assert "The legs the latest run planned." in t and "Long-context prefill" not in t       # the run planned four legs; the defaults are not shown
    assert NOT_BETTER in t and "nothing yet" in t


def test_a_waiting_run_says_why(tmp_path):
    c, _u = client(tmp_path, status(state="waiting", reason="production traffic on beta in the last 10 minutes"))
    t = plain(c.get("/models/c/local-medium"))
    assert "Waiting" in t and "Why production traffic on beta in the last 10 minutes" in t and NOT_BETTER in t


def test_a_running_run_shows_partial_numbers_under_the_banner_and_no_winner(tmp_path):
    legs = [leg("control", "done", "the control failed as it should"), leg("smoke", "done"),
            leg("perf", "running", "12 of 40 cases", {"tokens_per_second": 31.25, "ttft_ms": {"p50": 412}}), leg("quality", "queued")]
    c, _u = client(tmp_path, status(state="running", legs=legs))
    r = c.get("/models/c/local-medium")
    t = plain(r)
    assert "Running" in t and "12 of 40 cases" in t and "tokens_per_second 31.25" in t and "ttft_ms.p50 412" in t
    assert "Not finished" in t and NOT_BETTER in t and "a good start is not a result" in t
    assert "So far" in t and "What it measured" not in t
    assert "runner's label" not in t and "Read the comparison" not in t                 # no label, no comparison, no winner while it runs


def test_a_running_run_that_has_not_been_written_for_hours_is_unknown_not_running(tmp_path):
    c, _u = client(tmp_path, status(state="running", updated=iso(delta_s=-3 * 3600)))
    t = plain(c.get("/models/c/local-medium"))
    assert "This run says running but its status was last written 3 h ago. The runner may have stopped; this page cannot tell." in t


def test_a_done_run_with_a_label_links_the_comparison_only_when_the_verdict_is_there(tmp_path):
    legs = [leg(n, "done", f"{n} ok") for n in ("control", "smoke", "perf", "quality")]
    doc = status(run_id="r-done", state="done", legs=legs, label="worse", verdict_path="verdicts/r-done.json", evidence_pr="https://forge.example/o/r/pull/12")
    c, _u = client(tmp_path, doc)
    t = plain(c.get("/models/c/local-medium"))
    assert "The runner's label for this run: Worse" in t and "What it measured" in t and NOT_BETTER not in t
    assert "verdict record is not among the records this page reads yet" in t
    assert 'href="https://forge.example/o/r/pull/12"' in c.get("/models/c/local-medium").text


def test_an_aborted_run_shows_its_reason(tmp_path):
    legs = [leg("control", "done"), leg("smoke", "failed", "the endpoint stopped answering"), leg("perf", "skipped"), leg("quality", "skipped")]
    c, _u = client(tmp_path, status(state="aborted", reason="node beta went down mid-run", legs=legs))
    t = plain(c.get("/models/c/local-medium"))
    assert "Aborted" in t and "Why node beta went down mid-run" in t and "Failed" in t and "Skipped" in t
    assert NOT_BETTER in t and "the endpoint stopped answering" in t


def test_an_aborted_run_without_a_reason_says_none_was_recorded(tmp_path):
    c, _u = client(tmp_path, status(state="aborted"))
    assert "Why no reason was recorded" in plain(c.get("/models/c/local-medium"))


def test_a_failed_run_is_critical_and_earlier_runs_are_listed(tmp_path):
    old = status(run_id="r-old", state="done", label="better", created=iso(delta_s=-90000), updated=iso(delta_s=-86400))
    new = status(run_id="r-new", state="failed", reason="the grader was unreachable", created=iso(delta_s=-900), updated=iso(delta_s=-60))
    c, _u = client(tmp_path, old, new)
    r = c.get("/models/c/local-medium")
    t = plain(r)
    assert "r-new" in t and "Failed" in t and "Why the grader was unreachable" in t
    assert "Earlier runs (1)" in t and "r-old" in t and "label better" in t
    assert "st-critical" in r.text


def test_runs_for_another_alias_are_not_shown(tmp_path):
    c, _u = client(tmp_path, status(run_id="other-run", alias="local-large", state="running"))
    t = plain(c.get("/models/c/local-medium"))
    assert "other-run" not in t and "No run is on record" in t


def test_a_missing_status_directory_is_unknown_not_an_empty_list(tmp_path):
    c, _u = page_client(tmp_path, inventory=with_next(), status_dir=tmp_path / "not-there")
    t = plain(c.get("/models/c/local-medium"))
    assert "Unknown" in t and "is not there: the eval runner is off, or its status volume is not mounted" in t
    assert "No run can be listed" in t and "No run is on record" not in t


def test_an_unreadable_status_file_is_counted_and_the_rest_still_show(tmp_path):
    d = tmp_path / "status"
    write_status(d, status(run_id="r-good", state="queued"))
    (d / "runs" / "r-bad.json").write_text("{not json")
    c, _u = page_client(tmp_path, inventory=with_next(), status_dir=d)
    t = plain(c.get("/models/c/local-medium"))
    assert "1 run status file(s) could not be read and are not listed" in t and "r-good" in t


def test_a_run_with_no_candidate_route_left_still_has_a_page(tmp_path):
    c, _u = client(tmp_path, status(state="done", label="worse"), nxt=False)
    r = c.get("/models/c/local-medium")
    t = plain(r)
    assert r.status_code == 200 and "There is no local-medium-next route now" in t and "Start an evaluation" not in t


def test_a_run_status_with_nothing_in_it_does_not_break_the_page(tmp_path):
    d = tmp_path / "status"
    write_status(d, {"schema": "run-status/1", "run_id": "r-min", "alias": "local-medium", "state": "running"})
    c, _u = page_client(tmp_path, inventory=with_next(), status_dir=d)
    r = c.get("/models/c/local-medium")
    t = plain(r)
    # the runner's reader refuses a status missing its required fields: the page says so rather than guessing
    assert r.status_code == 200 and "1 run status file(s) could not be read and are not listed" in t


def test_html_in_a_status_file_is_escaped(tmp_path):
    c, _u = client(tmp_path, status(state="aborted", reason="<script>alert(1)</script>"))
    assert "<script>alert(1)" not in c.get("/models/c/local-medium").text


def test_the_models_page_links_the_plan_and_runs(tmp_path):
    c, _u = client(tmp_path, status(state="running"))
    assert 'href="/models/c/local-medium"' in c.get("/models").text


# ------------------------------------------------------------ the pure strip

def test_strip_marks_stale_by_state_and_age():
    import datetime
    now = datetime.datetime.now(datetime.timezone.utc)
    mk = lambda state, secs: cd.strip(status(state=state, updated=iso(delta_s=-secs)), now)["stale"]   # noqa: E731
    assert mk("running", 3500) is False and mk("running", 3700) is True
    assert mk("waiting", 3700) is False and mk("waiting", 7 * 3600) is True
    assert mk("done", 99 * 3600) is False and mk("aborted", 99 * 3600) is False
    assert cd.strip(status(state="running", updated=None, created=None), now)["stale"] is True      # no timestamp: nothing says it is alive


def test_strip_caps_the_metrics_and_drops_a_non_https_evidence_link():
    import datetime
    now = datetime.datetime.now(datetime.timezone.utc)
    l = leg("perf", "running", "x", {f"m{i}": i for i in range(40)})
    s = cd.strip(status(legs=[l], evidence_pr="javascript:alert(1)"), now)
    perf = next(x for x in s["legs"] if x["name"] == "perf")
    assert len(perf["metrics"]) == cd.MAX_METRICS and s["evidence_pr"] is None

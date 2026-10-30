"""TM-1301: the candidate page draws a run as connected stages (Control, Smoke, Perf, Prefill, Tool calls, Quality, Verdict)
with an arrow between each, earlier runs list with the reason each ended, and Re-run renders the runner.rerun values change
naming the run id. Nothing here is written: Re-run is a change to review and commit."""
import datetime
import html
import re

from app import candidate as cd
from tests.pages_support import iso, leg, page_client, status, with_next, write_status

FULL = ["control", "smoke", "perf", "prefill", "tool_reliability", "quality"]
SMOKE = {f"smoke_{n}": 1.0 for n in ("finish_stop", "tool_call_parses", "json_reply", "stream_well_formed", "verbatim_canary")}


def client(tmp_path, *docs, **kw):
    d = tmp_path / "status"
    (d / "runs").mkdir(parents=True, exist_ok=True)
    for x in docs:
        write_status(d, x)
    return page_client(tmp_path, inventory=with_next(), status_dir=d, **kw)


def run(run_id="r-1", state="running", legs=None, plan_legs=None, **over):
    doc = status(run_id=run_id, state=state, legs=legs, **over)
    doc["plan"] = dict(doc["plan"], legs=plan_legs or FULL)
    return doc


def done_legs():
    return [leg("control", "done", "ctl", {"control_pass_rate": 0.0, "cases": 5}),
            leg("smoke", "done", "5 of 5 checks passed", SMOKE),
            leg("perf", "done", "perf line", {"decode_tps_p50@c1": 71.3, "decode_tps_p50@c2": 90.0, "ttft_p50_s@c1": 0.4}),
            leg("prefill", "done", "pf line", {"ttft_ms_at_4096": 900, "ttft_ms_at_65536": 41000}),
            leg("tool_reliability", "done", "tc line", {"n": 20, "parse_failure_rate": 0.05}),
            leg("quality", "done", "q line", {"quality_pass_rate": 0.8125, "n": 48})]


def stages(r, which=0):
    """[(aria-label, state class)] of the stages of the which-th pipeline on the page, in page order."""
    pipes = re.findall(r'<ol class="pipe".*?</ol>', r.text, flags=re.S)
    return [(html.unescape(a), c) for a, c in re.findall(
        r'<li class="pipe-item" role="listitem" aria-label="([^"]*)">\s*<div class="stage ([^"]*)">', pipes[which])]


def pipe_html(r):
    return re.findall(r'<ol class="pipe".*?</ol>', r.text, flags=re.S)[0]


def test_a_done_run_draws_every_stage_in_order_with_an_arrow_between_each_and_the_key_number(tmp_path):
    c, _u = client(tmp_path, run(state="done", legs=done_legs(), label="same", verdict_path="verdicts/r-1.json"))
    r = c.get("/models/c/local-medium")
    st = stages(r)
    assert [a.split(":")[0] for a, _c in st] == ["Control", "Smoke", "Perf", "Prefill", "Tool calls", "Quality", "Verdict"]
    assert [a for a, _c in st] == [
        "Control: done, known-bad passed 0%", "Smoke: done, 5 of 5 checks", "Perf: done, 71 tokens per second decoding at concurrency 1",
        "Prefill: done, 41 seconds to first token at 64K tokens", "Tool calls: done, 95% of 20 calls parsed",
        "Quality: done, pass rate 81% over 48 cases", "Verdict: done, label same"]
    h = pipe_html(r)
    assert h.count('class="arrow"') == 6 and 'role="list"' in h and h.count('role="listitem"') == 7
    assert h.index("Control") < h.index("Smoke") < h.index("Perf") < h.index("Prefill") < h.index("Tool calls") < h.index("Quality") < h.index("Verdict")
    assert '<div class="fig">5/5</div>' in h and '<div class="fig">71<small> tok/s</small></div>' in h and '<div class="fig">41<small> s</small></div>' in h


def test_running_queued_failed_and_skipped_stages_each_render_with_their_arrows(tmp_path):
    legs = [leg("control", "done", "ctl", {"control_pass_rate": 0.0}), leg("smoke", "failed", "the stream never closed"),
            leg("perf", "skipped", "not run: smoke failed"), leg("prefill", "queued"), leg("tool_reliability", "running", "3 of 10 calls"),
            leg("quality", "queued")]
    c, _u = client(tmp_path, run(state="running", legs=legs))
    r = c.get("/models/c/local-medium")
    st = dict((a.split(":")[0], (a, cl)) for a, cl in stages(r))
    assert st["Control"][1] == "done" and st["Smoke"][1] == "failed" and st["Perf"][1] == "skipped"
    assert st["Prefill"][1] == "queued" and st["Tool calls"][1] == "running" and st["Quality"][1] == "queued"
    assert st["Smoke"][0] == "Smoke: failed, the stream never closed" and st["Perf"][0] == "Perf: skipped, not run: smoke failed"
    assert st["Prefill"][0] == "Prefill: queued" and st["Tool calls"][0] == "Tool calls: running, 3 of 10 calls"
    assert pipe_html(r).count('class="arrow"') == 6
    h = pipe_html(r)
    assert '<progress class="prog" max="100" value="30"' in h                       # 3 of 10, from the leg's own summary
    assert "waiting for its turn" in h and "state-key" in r.text


def test_a_failed_leg_with_no_reason_says_so_and_a_done_leg_without_metrics_shows_its_summary_clipped(tmp_path):
    long = "x" * 200
    legs = [leg("control", "done", long), leg("smoke", "failed"), leg("perf", "done", "")]
    c, _u = client(tmp_path, run(state="failed", legs=legs, plan_legs=["control", "smoke", "perf"], reason="smoke failed"))
    h = pipe_html(c.get("/models/c/local-medium"))
    assert "x" * 77 + "..." in h and "x" * 81 not in h                                # clipped, never invented
    assert "no reason was recorded" in h and "no numbers recorded" in h
    assert "known-bad passed" not in h and "5/5" not in h


def test_perf_and_quality_fold_their_incumbent_legs(tmp_path):
    legs = [leg("perf", "done", "p", {"decode_tps_p50@c1": 40.0}), leg("perf_incumbent", "running", "9 of 20 requests"),
            leg("quality", "failed", "grader down"), leg("quality_incumbent", "queued")]
    c, _u = client(tmp_path, run(state="running", legs=legs, plan_legs=["perf", "perf_incumbent", "quality", "quality_incumbent"]))
    st = dict((a.split(":")[0], (a, cl)) for a, cl in stages(c.get("/models/c/local-medium")))
    assert list(st) == ["Perf", "Quality", "Verdict"]                                  # the incumbent legs are not stages of their own
    assert st["Perf"][1] == "running" and st["Quality"][1] == "failed"
    legs = [leg("perf", "done", "p", {"decode_tps_p50@c1": 40.0}), leg("perf_incumbent", "queued")]
    c, _u = client(tmp_path / "b", run(state="running", legs=legs, plan_legs=["perf", "perf_incumbent"]))
    assert dict((a.split(":")[0], cl) for a, cl in stages(c.get("/models/c/local-medium")))["Perf"] == "done"   # done when the candidate's leg is


def test_legs_not_in_the_plan_are_omitted_and_a_skipped_leg_outside_it_is_drawn_skipped(tmp_path):
    legs = [leg("control", "done"), leg("smoke", "done"), leg("prefill", "skipped", "turned off")]
    c, _u = client(tmp_path, run(state="done", legs=legs, plan_legs=["control", "smoke"]))
    names = [a.split(":")[0] for a, _c in stages(c.get("/models/c/local-medium"))]
    assert names == ["Control", "Smoke", "Prefill", "Verdict"]
    c, _u = client(tmp_path / "b", run(state="done", legs=[leg("control", "done")], plan_legs=["control"]))
    assert [a.split(":")[0] for a, _c in stages(c.get("/models/c/local-medium"))] == ["Control", "Verdict"]


def test_the_verdict_stage_shows_the_label_when_done_failed_when_failed_and_pending_otherwise(tmp_path):
    c, _u = client(tmp_path, run(state="done", legs=done_legs(), label="worse", verdict_path="v.json"))
    assert stages(c.get("/models/c/local-medium"))[-1] == ("Verdict: done, label worse", "verdict-done")
    assert 'class="stage verdict-done"' in c.get("/models/c/local-medium").text
    c, _u = client(tmp_path / "b", run(state="failed", legs=done_legs()[:2], reason="the grader was unreachable"))
    assert stages(c.get("/models/c/local-medium"))[-1] == ("Verdict: failed", "verdict-failed")
    c, _u = client(tmp_path / "c", run(state="running", legs=done_legs()[:2]))
    assert stages(c.get("/models/c/local-medium"))[-1] == ("Verdict: pending", "verdict-pending")
    c, _u = client(tmp_path / "d", run(state="done", legs=done_legs()))                # done, but no label and no record: nothing to show
    assert stages(c.get("/models/c/local-medium"))[-1] == ("Verdict: pending", "verdict-pending")


def test_no_one_is_named_ahead_while_a_run_is_running(tmp_path):
    c, _u = client(tmp_path, run(state="running", legs=done_legs()[:5] + [leg("quality", "running", "12 of 48 cases")], label="better"))
    r = c.get("/models/c/local-medium")
    assert "winner" not in r.text.lower() and stages(r)[-1][0] == "Verdict: pending"
    assert "Better" not in re.sub(r"<[^>]+>", " ", pipe_html(r))                       # even a stray label is not shown before the run is done


def test_earlier_runs_list_with_date_state_reason_and_a_mini_pipeline(tmp_path):
    a = run("r-a", "done", done_legs(), plan_legs=FULL, label="worse", verdict_path="v/a.json", created=iso(delta_s=-200000), updated=iso(delta_s=-190000))
    b = run("r-b", "failed", done_legs()[:3], reason="result file name collision", created=iso(delta_s=-100000), updated=iso(delta_s=-90000))
    new = run("r-c", "queued", created=iso(delta_s=-60), updated=iso(delta_s=-30))
    c, _u = client(tmp_path, a, b, new)
    r = c.get("/models/c/local-medium")
    t = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", r.text))
    assert "Earlier runs (2)" in t and "r-a" in t and "r-b" in t
    assert "result file name collision" in t and "verdict label worse" in t and "UTC" in t
    minis = re.findall(r'<ol class="mini".*?</ol>', r.text, flags=re.S)
    assert len(minis) == 2 and all(m.count('class="a"') == m.count('role="listitem"') - 1 and 'role="list"' in m for m in minis)
    assert 'aria-label="Verdict: failed"' in minis[0] and 'aria-label="Verdict: done, label worse"' in minis[1]
    assert 'aria-label="Perf: done, 71 tokens per second decoding at concurrency 1"' in minis[1]


# ------------------------------------------------------------ Re-run

def post(c, u, run_id, csrf=True, alias="local-medium", **extra):
    data = {"run_id": run_id, **extra}
    if csrf:
        data["csrf"] = u.csrf
    return c.post(f"/models/c/{alias}/rerun", data=data)


def test_re_run_is_offered_for_a_finished_run_as_a_csrf_form(tmp_path):
    for i, state in enumerate(("done", "failed")):
        c, u = client(tmp_path / str(i), run("r-fin", state, done_legs()))
        t = c.get("/models/c/local-medium").text
        assert 'action="/models/c/local-medium/rerun"' in t and 'name="run_id" value="r-fin"' in t and f'name="csrf" value="{u.csrf}"' in t
        assert ">Re-run<" in t


def test_re_run_is_not_offered_while_a_run_is_in_progress(tmp_path):
    for i, state in enumerate(("queued", "waiting", "running")):
        c, _u = client(tmp_path / str(i), run("r-live", state))
        t = c.get("/models/c/local-medium").text
        assert ">Re-run<" not in t and "/rerun" not in t and "A run is in progress" in t


def test_re_run_renders_the_values_change_naming_the_run_id(tmp_path):
    c, u = client(tmp_path, run("r-fin", "failed", done_legs(), reason="the grader was unreachable"), runner={"enabled": True, "schedule": "*/15 * * * *"})
    r = post(c, u, "r-fin")
    t = html.unescape(r.text)
    assert r.status_code == 200 and "Run r-fin again" in t and "Nothing has changed yet" in t
    assert re.search(r"rerun:\s*\n\s*- r-fin", t)
    assert "enabled: true" in t and "modelLifecycle.runner.enabled is off" not in t     # the runner's other keys are carried
    assert "counts once toward promotion" in t
    y = post(c, u, "r-fin", fmt="yaml")
    assert y.status_code == 200 and "application/yaml" in y.headers["content-type"] and "- r-fin" in y.text


def test_re_run_appends_to_the_ids_the_site_already_lists_and_does_not_list_one_twice(tmp_path):
    c, u = client(tmp_path, run("r-fin", "done", done_legs()), runner={"enabled": True, "rerun": ["older-run"]})
    t = html.unescape(post(c, u, "r-fin").text)
    assert re.search(r"rerun:\s*\n\s*- older-run\s*\n\s*- r-fin", t)
    c, u = client(tmp_path / "b", run("r-fin", "done", done_legs()), runner={"enabled": True, "rerun": ["r-fin"]})
    t = html.unescape(post(c, u, "r-fin").text)
    assert t.count("- r-fin") == 1 and "it already was" in t
    page = html.unescape(c.get("/models/c/local-medium").text)
    assert "A re-run of r-fin is requested" in page and ">Re-run<" not in page          # listed already: the page says so, not offers it again


def test_re_run_says_when_the_runner_is_off(tmp_path):
    c, u = client(tmp_path, run("r-fin", "done", done_legs()))
    assert "modelLifecycle.runner.enabled is off here" in html.unescape(post(c, u, "r-fin").text)


def test_re_run_is_refused_without_the_csrf_token_for_a_non_admin_and_for_a_bad_run(tmp_path):
    c, u = client(tmp_path, run("r-fin", "done", done_legs()), run("r-live", "running"), run("other", "done", alias="local-large"))
    assert post(c, u, "r-fin", csrf=False).status_code == 400
    assert c.post("/models/c/local-medium/rerun", data={"run_id": "r-fin", "csrf": "wrong"}).status_code == 400
    r = post(c, u, "r-live")
    assert r.status_code == 400 and "only a run that is done or failed" in r.text
    assert post(c, u, "nope").status_code == 404
    assert post(c, u, "").status_code == 404
    assert post(c, u, "other").status_code == 404                                       # a finished run of another alias
    nc, nu = client(tmp_path / "n", run("r-fin", "done", done_legs()), groups=["tockmox-users"])
    assert post(nc, nu, "r-fin").status_code == 403


def test_an_aborted_run_is_not_re_run_by_hand_and_cannot_be_posted(tmp_path):
    c, u = client(tmp_path, run("r-ab", "aborted", done_legs()[:2], reason="node went down"))
    t = c.get("/models/c/local-medium").text
    assert ">Re-run<" not in t and "tries an aborted run again by itself" in t
    assert post(c, u, "r-ab").status_code == 400


# ------------------------------------------------------------ the pure parts

def test_key_number_reads_only_recorded_metrics_and_falls_back_to_the_clipped_summary():
    assert cd.key_number("smoke", {**SMOKE, "smoke_json_reply": 0.0}, "s")["big"] == "4/5"
    assert cd.key_number("perf", {"decode_tps_p50@c4": 30.0, "decode_tps_p50@c2": 55.5}, "s")["cap"] == "decode at concurrency 2"
    assert cd.key_number("prefill", {"ttft_ms_at_4096": 250}, "s") == {"big": "250", "unit": "ms", "cap": "time to first token at 4K", "spoken": "250 milliseconds to first token at 4K tokens"}
    assert cd.key_number("tool_reliability", {"n": 100}, "s")["big"] == "100"
    for key in ("control", "smoke", "perf", "prefill", "tool_reliability", "quality"):
        k = cd.key_number(key, {}, "a plain summary")
        assert k["big"] == "" and k["cap"] == "a plain summary"                          # absent metric: the summary, no number
    assert cd.key_number("perf", None, "")["cap"] == "no numbers recorded"
    assert cd.key_number("quality", {"quality_pass_rate": True}, "s")["big"] == ""      # a bool is not a number


def test_rerun_offer_and_ids():
    assert cd.rerun_ids({"runner": {"rerun": ["a", 3]}}) == ["a", "3"] and cd.rerun_ids({"runner": None}) == [] and cd.rerun_ids(None) == []
    assert cd.rerun_ids({"runner": {"rerun": "x"}}) == []
    assert cd.rerun_offer(None, [])["offer"] is False
    now = datetime.datetime.now(datetime.timezone.utc)
    done = cd.strip(status(run_id="r", state="done"), now)
    assert cd.rerun_offer(done, [])["offer"] is True and cd.rerun_offer(done, ["r"]) == {"offer": False, "listed": True, "why": cd.rerun_offer(done, ["r"])["why"]}

# SPDX-License-Identifier: Apache-2.0
"""TM-1261: run-status/1. Atomic writes, a reader that skips what it cannot trust, newest first, and the engine-upgrade
comparison (TM-1264) that states a regression and nothing more."""
import json
import os

import pytest

from app.runner import status as st


def doc(run_id="large-local-large-20261030-1", state="queued", **kw):
    d = st.new_status(run_id, "local-large", "large", {"model": "m/new", "revision": "abc"}, {"model": "m/old"}, "studio",
                      {"id": "mlx-lm", "version": "0.32.2"}, {"id": "large", "version": "v1", "sha256": "f" * 64},
                      "admitted", {"legs": ["smoke", "perf"], "estimated_seconds": 60, "disk_gib": None,
                                   "window": "next quiet window"}, state)
    d.update(kw)
    return d


def test_write_then_read_roundtrip_and_layout(tmp_path):
    p = st.path_for(str(tmp_path), "large-local-large-20261030-1")
    assert p == str(tmp_path / "runs" / "large-local-large-20261030-1.json")
    st.write_status(p, doc())
    d = st.read_status(p)
    assert d["schema"] == "run-status/1" and d["state"] == "queued"
    assert [x["name"] for x in d["legs"]] == ["smoke", "perf"] and all(x["state"] == "queued" for x in d["legs"])
    assert d["verdict_path"] is None and d["label"] is None and d["evidence_pr"] is None


def test_write_is_atomic_no_temp_file_left_and_a_failed_write_keeps_the_old_file(tmp_path, monkeypatch):
    p = st.path_for(str(tmp_path), "r1")
    st.write_status(p, doc("r1"))
    assert [n for n in os.listdir(tmp_path / "runs")] == ["r1.json"]
    before = open(p).read()
    real = os.replace

    def boom(a, b):
        raise OSError("disk gone")
    monkeypatch.setattr(os, "replace", boom)
    with pytest.raises(OSError):
        st.write_status(p, doc("r1", state="running"))
    monkeypatch.setattr(os, "replace", real)
    assert open(p).read() == before                       # the reader still sees the old, whole file
    assert os.listdir(tmp_path / "runs") == ["r1.json"]   # and the temp file was cleaned up


def test_write_refuses_an_invalid_status_and_a_name_that_is_not_the_run_id(tmp_path):
    with pytest.raises(st.StatusError, match="state must be"):
        st.write_status(st.path_for(str(tmp_path), "r1"), doc("r1", state="nearly"))
    with pytest.raises(st.StatusError, match="not named for run_id"):
        st.write_status(str(tmp_path / "runs" / "other.json"), doc("r1"))
    with pytest.raises(st.StatusError, match="safe file name"):
        st.path_for(str(tmp_path), "../x")


def test_reader_skips_invalid_files_with_warnings_and_orders_newest_first(tmp_path):
    d = str(tmp_path)
    a, b = doc("run-a"), doc("run-b")
    a["updated"] = "2026-10-30T01:00:00Z"
    b["updated"] = "2026-10-30T02:00:00Z"
    os.makedirs(tmp_path / "runs")
    for x in (a, b):                                      # write directly: write_status would stamp `updated` itself
        (tmp_path / "runs" / f"{x['run_id']}.json").write_text(json.dumps(x))
    (tmp_path / "runs" / "broken.json").write_text("{not json")
    (tmp_path / "runs" / "wrong.json").write_text(json.dumps({"schema": "run-status/2"}))
    (tmp_path / "runs" / "mismatch.json").write_text(json.dumps(doc("someone-else")))
    (tmp_path / "runs" / "huge.json").write_text(" " * (st.MAX_BYTES + 1))
    (tmp_path / "runs" / ".tmp-x.json").write_text("{}")  # a temp file mid-write is not a status
    (tmp_path / "runs" / "notes.txt").write_text("hi")
    warnings = []
    got = st.read_statuses(d, warnings)
    assert [x["run_id"] for x in got] == ["run-b", "run-a"]
    assert sorted(w.split(":")[0] for w in warnings) == ["broken.json", "huge.json", "mismatch.json", "wrong.json"]
    assert st.read_statuses(str(tmp_path / "nowhere")) == []      # nothing has run yet


def test_set_leg_stamps_times_and_adds_unplanned_legs():
    d = doc()
    st.set_leg(d, "smoke", "running")
    assert d["legs"][0]["started"] and d["legs"][0]["finished"] is None
    st.set_leg(d, "smoke", "done", "5 of 5 checks passed", {"smoke_finish_stop": 1.0})
    assert d["legs"][0]["finished"] and d["legs"][0]["metrics"] == {"smoke_finish_stop": 1.0}
    st.set_leg(d, "control", "done")
    assert d["legs"][-1]["name"] == "control"
    with pytest.raises(st.StatusError):
        st.set_leg(d, "smoke", "paused")


def test_regressions_are_stated_with_numbers_and_small_moves_are_not_regressions():
    was = {"smoke_finish_stop": 1.0, "ttft_p95_s@c1": 1.0, "decode_tps_p50@c1": 40.0, "complete_p95_s@c1": 4.0}
    ok = {"smoke_finish_stop": 1.0, "ttft_p95_s@c1": 1.2, "decode_tps_p50@c1": 35.0, "complete_p95_s@c1": 4.5}
    assert st.perf_regressions(was, ok) == []
    bad = {"smoke_finish_stop": 0.0, "ttft_p95_s@c1": 1.6, "decode_tps_p50@c1": 20.0, "complete_p95_s@c1": 4.0}
    out = st.perf_regressions(was, bad)
    assert len(out) == 3
    assert any("smoke_finish_stop passed before" in x for x in out)
    assert any("ttft_p95_s@c1 1 -> 1.6 (+60%)" in x for x in out)
    assert any("decode_tps_p50@c1 40 -> 20 (-50%)" in x for x in out)

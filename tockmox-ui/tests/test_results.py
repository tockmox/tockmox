# SPDX-License-Identifier: Apache-2.0
"""capability-result/1 (REQ-0045 AC-45.6): one schema module for the runner, the UI and CI."""
import json

import pytest

from tests.models_support import SHA_A, result_doc, result_text
from app import results as rs


def test_a_valid_result_parses_with_every_field_the_spec_names():
    r = rs.parse(result_text(), "evals/results/beta/x.json")
    assert (r.date, r.node, r.model, r.quant) == ("2026-10-20", "beta", "example-org/Example-27B-4bit", "4bit")
    assert (r.engine_id, r.engine_version, r.plane, r.klass) == ("mlx-lm", "0.32.2", "engine", "chat")
    assert r.metric("decode_tps_stream_p50").value == 31.2 and r.metric("ttft_p95", 4).unit == "s" and r.metric("ttft_p95", 1) is None
    assert (r.peak_resident_gib, r.context_tokens, r.parallel_slots, r.tokens_per_joule) == (21.4, 32768, 3, 0.42)
    assert r.environment["macos"] == "26.2" and r.methodology == "evals/results/beta/method.md" and len(r.sha256) == 64


@pytest.mark.parametrize("over,match", [
    ({"schema": "capability-result/2"}, "schema"),
    ({"kind": "vibes"}, "kind"),
    ({"date": "20 Oct"}, "date"),
    ({"node": "Beta Node"}, "node id"),
    ({"model": "has space"}, "model"),
    ({"revision": "main"}, "revision"),
    ({"engine": {"id": "mlx-lm"}}, "engine"),                                   # no version: cannot be told stale
    ({"plane": "cloud"}, "plane"),
    ({"plane": "gateway"}, "gateway.route"),
    ({"environment": {}}, "environment"),
    ({"metrics": []}, "metrics"),
    ({"metrics": [{"name": "Decode", "value": 1, "unit": "s", "n": 1}]}, "snake_case"),
    ({"metrics": [{"name": "a", "value": 1, "unit": "", "n": 1}]}, "unit"),
    ({"metrics": [{"name": "a", "value": float("nan"), "unit": "s", "n": 1}]}, "finite"),
    ({"metrics": [{"name": "a", "value": 1, "unit": "s", "n": -1}]}, "negative"),
    ({"methodology": "../etc/passwd"}, "methodology"),
    ({"methodology": "https://example.com/m.md"}, "methodology"),
    ({"memory": {"peak_resident_gib": -3}}, "positive"),
    ({"memory": {"peak_resident_gib": float("inf")}}, "finite"),
])
def test_a_result_a_reader_could_misread_is_refused(over, match):
    with pytest.raises(rs.ResultError, match=match):
        rs.parse(json.dumps(result_doc(**over), allow_nan=True))


def test_not_json_and_too_large_are_refused():
    with pytest.raises(rs.ResultError, match="not JSON"):
        rs.parse("{nope")
    with pytest.raises(rs.ResultError, match="1 MiB"):
        rs.parse(result_text(environment={"note": "x" * 200, "pad": "y" * 200}) + " " * (1 << 20))


def test_a_gateway_leg_names_its_route():
    r = rs.parse(result_text(plane="gateway", gateway={"litellm": "1.106.2", "route": "local-medium-next"}))
    assert r.plane == "gateway" and r.gateway["route"] == "local-medium-next"


def test_the_writer_is_deterministic_and_round_trips(tmp_path):
    r = rs.parse(result_text())
    t1, t2 = rs.dumps(r), rs.dumps(rs.parse(rs.dumps(r)))
    assert t1 == t2                                                           # same measurement, same bytes, same hash
    rel, sha = rs.write_new(str(tmp_path), r)
    assert rel == "evals/results/beta/2026-10-20-example-27b-4bit-mlx-lm-engine.json"
    assert rs.write_new(str(tmp_path), r) == (rel, sha)                      # the same bytes again is a no-op
    assert rs.parse((tmp_path / rel).read_text()).sha256 == sha


def test_a_twin_is_never_edited_in_place(tmp_path):
    r = rs.parse(result_text())
    rs.write_new(str(tmp_path), r)
    changed = rs.parse(result_text(metrics=[{"name": "decode_tps_stream_p50", "value": 99.0, "unit": "tok/s", "n": 120}]))
    with pytest.raises(rs.ResultError, match="measure again under a new date"):
        rs.write_new(str(tmp_path), changed)


def test_the_writer_will_not_emit_what_the_reader_refuses(tmp_path):
    r = rs.parse(result_text())
    r.metrics[0].value = float("nan")
    with pytest.raises(rs.ResultError):
        rs.dumps(r)


def test_kinds_get_distinct_paths_so_legs_of_one_run_never_collide():
    base = rs.parse(result_text())
    paths = {rs.repo_path(rs.parse(result_text(kind=k, plane=p, **({"gateway": {"route": "a"}} if p == "gateway" else {}))))
             for k in rs.KINDS for p in rs.PLANES}
    assert len(paths) == 2 * len(rs.KINDS) == 10 and rs.repo_path(base).startswith("evals/results/beta/")


def test_load_dir_lists_a_file_that_does_not_parse_instead_of_dropping_it(tmp_path):
    d = tmp_path / "evals" / "results" / "beta"
    d.mkdir(parents=True)
    (d / "good.json").write_text(result_text())
    (d / "bad.json").write_text('{"schema": "capability-result/1"}')
    (d / "big.json").write_text(" " * ((1 << 20) + 1))
    (d / "note.md").write_text("not json, not read")
    out, bad = rs.load_dir(str(tmp_path))
    assert [r.path for r in out] == ["evals/results/beta/good.json"]
    assert len(bad) == 2 and any("bad.json" in b for b in bad) and any("larger than 1 MiB" in b for b in bad)
    out, _ = rs.load_dir(str(d), "", prefix="evals/results/beta")           # a mount of the results directory elsewhere
    assert out[0].path == "evals/results/beta/good.json"


def test_newest_measured_peak_and_staleness():
    old = rs.parse(result_text(date="2026-09-01", memory={"peak_resident_gib": 18.0, "context_tokens": 8192, "parallel_slots": 1}), "a.json")
    new = rs.parse(result_text(), "b.json")
    smoke = rs.parse(result_text(kind="smoke", date="2026-10-21"), "c.json")
    assert rs.newest([old, new, smoke], "beta", "example-org/Example-27B-4bit", "mlx-lm") is new
    assert rs.newest([old, new], "alpha", "example-org/Example-27B-4bit") is None
    assert rs.is_stale(new, "0.32.2", "26.2") == ""
    assert "the node runs 0.33.0" in rs.is_stale(new, "0.33.0")
    assert "macOS 26.2" in rs.is_stale(new, "0.32.2", "26.3")

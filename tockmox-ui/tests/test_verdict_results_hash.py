# SPDX-License-Identifier: Apache-2.0
"""comparative-verdict/1 results[] is [{path, sha256}] and CI recomputes every hash (REQ-0048 AC-48.6, TM-0930 extended).
The planted-defect tests at the bottom are the proof the check can go red: each one edits a committed file after the
fact and expects the gate to say so."""
import json

import pytest

from tests.models_support import lifecycle_doc, result_text, sha, verdict_record, verdicts, world
from app import models as ml
from app import nodes as nm
from app import verdict_check as vc

MODEL, INC = "example-org/Example-30B-4bit", "example-org/Example-27B-4bit"
TWIN = "evals/results/beta/2026-10-20-candidate-mlx-lm-engine.json"
TWIN2 = "evals/results/beta/2026-10-20-incumbent-mlx-lm-engine.json"


def repo(tmp_path, results_mode="hashed", twin_model=MODEL):
    """A site repo on disk: two result twins, three verdicts citing them, and the values that promote on those three."""
    for rel, model in ((TWIN, twin_model), (TWIN2, INC)):
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(result_text(model=model))
    refs = [{"path": TWIN, "sha256": sha(result_text(model=twin_model))}, {"path": TWIN2, "sha256": sha(result_text(model=INC))}]
    if results_mode == "bare":
        refs = [TWIN, TWIN2]
    vdir = tmp_path / "evals" / "verdicts"
    vdir.mkdir(parents=True)
    for i in range(3):
        (vdir / f"r{i}.json").write_text(verdict_record(MODEL, "local-medium", run=f"r{i}", incumbent=INC, results=refs))
    return tmp_path


def promoted_values(root):
    lc, inv = world()
    d = lifecycle_doc()
    d["catalog"].append({"id": "example-30b", "model": MODEL, "stage": "candidate",
                         "source": {"kind": "huggingface", "ref": MODEL, "revision": "4" * 40}})
    lc = ml.parse(d)
    inv = nm.Inventory(inv.nodes, inv.routes + [nm.Route("local-medium-next", "alpha", "mlx-lm-8080", MODEL, "chat", "", {}, {}, 17.0)])
    vs = [ml.parse_verdict((root / "evals" / "verdicts" / f"r{i}.json").read_text(), f"evals/verdicts/r{i}.json") for i in range(3)]
    new_lc, new_inv, _ = ml.promote("local-medium-next", vs, lc, inv)
    return {"modelLifecycle": ml.to_doc(new_lc)}


# ------------------------------------------------------------ the shape

def test_results_are_path_and_sha256_and_the_bare_form_is_accepted_with_a_warning():
    h = "a" * 64
    v = ml.parse_verdict(verdict_record(MODEL, "local-medium", results=[{"path": TWIN, "sha256": h}]))
    assert v.results == [{"path": TWIN, "sha256": h}] and v.warnings == []
    old = ml.parse_verdict(verdict_record(MODEL, "local-medium", results=[TWIN]))
    assert old.results == [{"path": TWIN, "sha256": ""}]
    assert len(old.warnings) == 1 and "bare path with no sha256" in old.warnings[0] and "one release" in old.warnings[0]


@pytest.mark.parametrize("bad", [
    [{"path": TWIN}], [{"sha256": "a" * 64}], [{"path": TWIN, "sha256": "nothex"}], [{"path": "../x.json", "sha256": "a" * 64}],
    [{"path": "/etc/passwd", "sha256": "a" * 64}], ["../escape.json"], ["not-under-evals.json"], [42], "evals/x.json",
    [{"path": f"evals/{i}.json", "sha256": "a" * 64} for i in range(201)],
])
def test_a_malformed_results_list_is_refused(bad):
    with pytest.raises(ml.LifecycleError, match="results"):
        ml.parse_verdict(verdict_record(MODEL, "local-medium", results=bad))


# ------------------------------------------------------------ CI recomputes

def test_an_honest_repo_is_green_and_the_promotion_cites_the_verdicts(tmp_path):
    root = repo(tmp_path)
    values = promoted_values(root)
    problems, warnings = vc.check_all(values, str(root))
    assert problems == [] and warnings == []
    e = next(x for x in values["modelLifecycle"]["catalog"] if x["model"] == MODEL)
    assert len(e["promotion"]["evidence"]) == 3


def test_planted_defect_an_edited_twin_goes_red(tmp_path):
    root = repo(tmp_path)
    values = promoted_values(root)
    assert vc.check(values, str(root)) == []
    (root / TWIN).write_text(result_text(model=MODEL, metrics=[{"name": "decode_tps_stream_p50", "value": 99.9, "unit": "tok/s", "n": 120}]))
    problems = vc.check(values, str(root))
    assert problems and all("sha256 does not match the verdict" in p and TWIN in p for p in problems if TWIN in p)
    assert any(TWIN in p for p in problems)
    assert len([p for p in problems if "does not match the verdict" in p]) == 3        # every verdict that rests on it says so


def test_planted_defect_a_missing_twin_goes_red(tmp_path):
    root = repo(tmp_path)
    values = promoted_values(root)
    (root / TWIN2).unlink()
    assert any("not committed" in p and TWIN2 in p for p in vc.check(values, str(root)))


def test_planted_defect_a_twin_about_another_model_goes_red(tmp_path):
    root = repo(tmp_path, twin_model="example-org/Some-Other-Model")
    values = promoted_values(root)
    assert any("the result is about example-org/Some-Other-Model" in p for p in vc.check(values, str(root)))


def test_planted_defect_an_invented_hash_on_a_verdict_goes_red(tmp_path):
    root = repo(tmp_path)
    p = root / "evals" / "verdicts" / "r0.json"
    d = json.loads(p.read_text())
    d["results"][0]["sha256"] = "0" * 64                                   # a hash nobody computed
    p.write_text(json.dumps(d))
    problems = vc.check({"modelLifecycle": lifecycle_doc()}, str(root))     # not cited by any promotion: still checked
    assert any("r0.json" in x and "does not match" in x for x in problems)


def test_a_verdict_not_yet_cited_by_any_promotion_is_still_checked(tmp_path):
    root = repo(tmp_path)
    assert vc.check({"modelLifecycle": lifecycle_doc()}, str(root)) == []
    (root / TWIN).write_text(result_text(model=MODEL, date="2026-10-21"))
    assert len(vc.check({"modelLifecycle": lifecycle_doc()}, str(root))) == 3


def test_a_corrupted_verdict_file_is_a_problem_not_a_silent_skip(tmp_path):
    root = repo(tmp_path)
    (root / "evals" / "verdicts" / "r1.json").write_text("{ torn")
    assert any("r1.json" in p and "not a verdict record" in p for p in vc.check({"modelLifecycle": lifecycle_doc()}, str(root)))


def test_the_bare_path_form_warns_but_does_not_fail_and_still_requires_the_file(tmp_path):
    root = repo(tmp_path, results_mode="bare")
    problems, warnings = vc.check_all({"modelLifecycle": lifecycle_doc()}, str(root))
    assert problems == [] and len(warnings) == 6 and all("bare path with no sha256" in w for w in warnings)
    (root / TWIN).unlink()
    assert any("not committed" in p for p in vc.check({"modelLifecycle": lifecycle_doc()}, str(root)))


def test_a_path_that_leaves_the_repo_cannot_be_used_to_hash_an_outside_file(tmp_path):
    root = repo(tmp_path)
    outside = tmp_path.parent / "outside.json"
    outside.write_text("x")
    link = root / "evals" / "results" / "beta" / "link.json"
    link.symlink_to(outside)
    p = root / "evals" / "verdicts" / "r0.json"
    d = json.loads(p.read_text())
    d["results"] = [{"path": "evals/results/beta/link.json", "sha256": sha("x")}]
    p.write_text(json.dumps(d))
    assert any("link.json" in x and "inside the site repo" in x for x in vc.check({"modelLifecycle": lifecycle_doc()}, str(root)))


def test_the_command_line_prints_warnings_and_exits_by_the_problems(tmp_path, capsys):
    import yaml
    root = repo(tmp_path, results_mode="bare")
    f = tmp_path / "values.yaml"
    f.write_text(yaml.safe_dump({"modelLifecycle": lifecycle_doc()}))
    assert vc.main([str(f), str(root)]) == 0
    assert "warning:" in capsys.readouterr().out
    (root / TWIN).unlink()
    assert vc.main([str(f), str(root)]) == 1

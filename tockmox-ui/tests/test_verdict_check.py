# SPDX-License-Identifier: Apache-2.0
"""TM-0930: CI opens the verdict files a promotion cites; the record alone can be invented."""
import hashlib
import json

import yaml

from tests.proto_support import lifecycle_full_doc, verdict_record
from app import models as ml
from app import nodes as nm
from app import verdict_check as vc

NEW = "mlx-community/Qwen3.9-27B-4bit"


def _site(tmp_path):
    d = lifecycle_full_doc()
    d["modelLifecycle"]["catalog"].append({"id": "q39", "model": NEW, "stage": "candidate", "source": {"kind": "huggingface", "ref": NEW}})
    d["inferenceNodes"]["routes"].append({"alias": "local-agent-next", "node": "mac-studio-m4-max", "endpoint": "http-8082",
                                          "model": NEW, "kind": "chat"})
    L, I = ml.parse(d["modelLifecycle"]), nm.parse_inventory(d["inferenceNodes"])
    old = next(r for r in I.routes if r.alias == "local-agent").model
    vdir = tmp_path / "evals" / "verdicts"
    vdir.mkdir(parents=True)
    texts = [verdict_record(NEW, "local-agent", run=f"r{i}", date=f"2026-10-0{i + 1}", incumbent=old) for i in range(3)]
    vs = []
    for i, t in enumerate(texts):
        (vdir / f"{i}.json").write_text(t)
        vs.append(ml.parse_verdict(t, f"evals/verdicts/{i}.json"))
    new_L, new_I, _ = ml.promote("local-agent-next", vs, L, I)
    d["modelLifecycle"] = ml.to_doc(new_L)
    d["inferenceNodes"].update(nm.inventory_to_doc(new_I))
    return d, vdir


def test_committed_files_that_match_pass(tmp_path):
    d, _ = _site(tmp_path)
    assert vc.check(d, str(tmp_path)) == []


def test_a_tampered_missing_or_escaping_file_fails(tmp_path):
    d, vdir = _site(tmp_path)
    (vdir / "1.json").write_text((vdir / "1.json").read_text().replace('"r1"', '"r1 "'))
    (vdir / "2.json").unlink()
    e = next(x for x in d["modelLifecycle"]["catalog"] if x["model"] == NEW)
    e["promotion"]["evidence"][0]["path"] = "../../etc/passwd"
    probs = vc.check(d, str(tmp_path))
    assert any("sha256 does not match" in p for p in probs)
    assert any("not committed" in p for p in probs)
    assert any("inside the site repo" in p for p in probs)


def test_a_record_rehashed_onto_a_failing_file_is_caught(tmp_path):
    """The gate reads only the record; someone who rewrites a fail file's hash into it passes the gate, not CI."""
    d, vdir = _site(tmp_path)
    t = (vdir / "0.json").read_text().replace('"pass"', '"fail"')
    (vdir / "0.json").write_text(t)
    e = next(x for x in d["modelLifecycle"]["catalog"] if x["model"] == NEW)
    e["promotion"]["evidence"][0]["sha256"] = hashlib.sha256(t.encode()).hexdigest()
    probs = vc.check(d, str(tmp_path))
    assert any("the file says fail" in p for p in probs)


def test_cli(tmp_path, capsys):
    d, _ = _site(tmp_path)
    (tmp_path / "values.yaml").write_text(yaml.safe_dump(d))
    assert vc.main([str(tmp_path / "values.yaml"), str(tmp_path)]) == 0
    assert "3 cited verdict file(s)" in capsys.readouterr().out

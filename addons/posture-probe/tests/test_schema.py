#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""TM-0882: the report schema and the gate exit-code contract are a published,
versioned interface, and the code that writes reports is held to them.

Proves, against the REAL pilot reports (tests/fixtures/pilot-report-*.json, from
the 2026-10-04 throwaway-cluster pilot) and against reports the engine writes now:
  - every report validates against schema/report-v0.schema.json, with both the
    image's stdlib validator and, when installed, the jsonschema library;
  - the two validators agree on every mutation below (the stdlib subset is not
    quietly weaker than the contract it enforces);
  - each mutation that breaks the contract is REJECTED (red-first: a schema that
    accepts everything would pass the first half alone);
  - the process exit code equals summary.gateExit on clean, drift and
    could-not-run inputs, and is 0, 2 and 1 respectively.
"""
import copy, json, os, subprocess, sys, tempfile, unittest
from _common import FIX, ROOT, SCHEMA
from posture_probe import schema as ppschema, differential

try:
    import jsonschema  # optional: CI has it; the image does not
except ImportError:  # pragma: no cover
    jsonschema = None

REAL = ["pilot-report-r2-drift.json", "pilot-report-r3-clean.json"]


def full_errors(doc):
    if jsonschema is None:
        return None
    # 2020-12 where the library has it; the keywords this schema uses mean the same in draft 7.
    cls = getattr(jsonschema, "Draft202012Validator", None) or jsonschema.Draft7Validator
    v = cls(json.load(open(SCHEMA)))
    return [e.message for e in v.iter_errors(doc)]


def mutations(doc):
    """(label, mutated report) pairs, each of which breaks the v0 contract."""
    out = []
    def m(label, fn):
        d = copy.deepcopy(doc); fn(d); out.append((label, d))
    m("schemaVersion bumped without a new schema", lambda d: d.__setitem__("schemaVersion", "v1"))
    m("summary dropped", lambda d: d.pop("summary"))
    m("gateExit outside the contract", lambda d: d["summary"].__setitem__("gateExit", 3))
    m("gateExit as a string", lambda d: d["summary"].__setitem__("gateExit", "2"))
    m("driftCount missing", lambda d: d["summary"].pop("driftCount"))
    m("bucket repurposed", lambda d: d["differential"][0].__setitem__("bucket", "warning"))
    m("intent repurposed", lambda d: d["differential"][0].__setitem__("intent", "maybe"))
    m("observed renamed", lambda d: d["differential"][0].pop("observed"))
    m("cause outside the enum", lambda d: d["differential"][0].__setitem__("cause", "cosmic-ray"))
    m("run.mode outside the enum", lambda d: d["run"].__setitem__("mode", "red-team"))
    m("run.id missing", lambda d: d["run"].pop("id"))
    m("differential not a list", lambda d: d.__setitem__("differential", {}))
    m("wrong schema id", lambda d: d.__setitem__("schema", "urn:tockmox:posture-probe:report:v9"))
    return out


class Schema(unittest.TestCase):
    def test_schema_is_versioned_and_states_the_contract(self):
        s = json.load(open(SCHEMA))
        self.assertEqual(s["$id"], differential.SCHEMA_ID)
        self.assertEqual(s["properties"]["schemaVersion"]["const"], differential.SCHEMA_VERSION)
        self.assertEqual(s["properties"]["summary"]["properties"]["gateExit"]["enum"], [0, 1, 2])
        for phrase in ("0 clean", "1 could not run", "2 drift", "only ADDED"):
            self.assertIn(phrase, s["description"])

    def test_real_pilot_reports_validate(self):
        for name in REAL:
            doc = json.load(open(os.path.join(FIX, name)))
            self.assertEqual(ppschema.errors(doc, json.load(open(SCHEMA))), [], name)
            if jsonschema is not None:
                self.assertEqual(full_errors(doc), [], name)

    def test_real_reports_are_the_cases_they_claim(self):
        r2 = json.load(open(os.path.join(FIX, REAL[0])))
        r3 = json.load(open(os.path.join(FIX, REAL[1])))
        self.assertEqual((r2["summary"]["driftCount"], r2["summary"]["gateExit"]), (4, 2))
        self.assertEqual((r3["summary"]["driftCount"], r3["summary"]["gateExit"]), (0, 0))

    def test_every_contract_break_is_rejected_by_both_validators(self):
        base = json.load(open(os.path.join(FIX, REAL[0])))
        base["schema"] = differential.SCHEMA_ID
        self.assertEqual(ppschema.errors(base, json.load(open(SCHEMA))), [])
        for label, doc in mutations(base):
            mine = ppschema.errors(doc, json.load(open(SCHEMA)))
            self.assertTrue(mine, "stdlib validator ACCEPTED: " + label)
            full = full_errors(doc)
            if full is not None:
                self.assertTrue(full, "jsonschema ACCEPTED: " + label)

    def test_new_reports_carry_the_schema_id_and_validate(self):
        intents = differential.load_intents(os.path.join(FIX, "intent.yaml"))
        for obs in ("observed-clean.json", "observed-drift.json"):
            rep, _ = differential.build(json.load(open(os.path.join(FIX, obs))), intents)
            self.assertEqual(rep["schema"], differential.SCHEMA_ID)
            self.assertEqual(ppschema.validate(rep, SCHEMA), [], obs)
            if jsonschema is not None:
                self.assertEqual(full_errors(rep), [], obs)


class GateContract(unittest.TestCase):
    """The exit code is the interface a CI runner depends on; summary.gateExit must equal it."""

    def gate(self, observed, intent):
        p = subprocess.run([sys.executable, "-m", "posture_probe", "gate", observed, intent],
                           cwd=ROOT, capture_output=True, text=True)
        rep = json.loads(p.stdout) if p.stdout.strip() else None
        return p.returncode, rep

    def test_clean_is_0(self):
        rc, rep = self.gate(os.path.join(FIX, "observed-clean.json"), os.path.join(FIX, "intent.yaml"))
        self.assertEqual((rc, rep["summary"]["gateExit"]), (0, 0))

    def test_drift_is_2(self):
        rc, rep = self.gate(os.path.join(FIX, "observed-drift.json"), os.path.join(FIX, "intent.yaml"))
        self.assertEqual((rc, rep["summary"]["gateExit"]), (2, 2))

    def test_unobserved_is_1_not_clean(self):
        # A private directory, not a fixed name under /tmp: check-all runs this
        # gate and its selftest at the same time, both run this suite, and a
        # shared file let one run truncate it while the other's gate read it.
        with tempfile.TemporaryDirectory() as d:
            empty = os.path.join(d, "empty-observed.json")
            with open(empty, "w") as f:
                json.dump({"observations": []}, f)
            rc, rep = self.gate(empty, os.path.join(FIX, "intent.yaml"))
        self.assertEqual((rc, rep and rep["summary"]["gateExit"]), (1, 1))

    def test_unreadable_intent_is_1(self):
        rc, rep = self.gate(os.path.join(FIX, "observed-clean.json"), "/nonexistent/intent.yaml")
        self.assertEqual((rc, rep), (1, None))

    def test_validate_command(self):
        ok = subprocess.run([sys.executable, "-m", "posture_probe", "validate", os.path.join(FIX, REAL[1])],
                            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout)


if __name__ == "__main__":
    unittest.main()

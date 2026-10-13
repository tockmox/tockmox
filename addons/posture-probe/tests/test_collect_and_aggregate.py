#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The in-cluster path, against a fake API server: no cluster needed.

Covers the two things only the add-on adds over the pilot:
  - the collector's termination-message transport (fits 4096 bytes, sheds detail
    before observations, refuses rather than truncates);
  - the differential Job: refuses a write-capable identity, reads each collector's
    report from pod status, turns a missing collector into could-not-run, finds
    drift, stores the report 0600 under its retention and never prints a finding.
"""
import io, json, os, stat, tempfile, unittest
from contextlib import redirect_stdout
from _common import FIX
from posture_probe import aggregate, blackbox, differential


def obs_doc(ns, ip, rows):
    return {"schemaVersion": "v0", "mode": "black-box",
            "namespace": {"name": ns, "podIP": ip, "identity": {"serviceAccount": "default", "tokenMounted": False},
                          "exposure": {}, "reachability": [{"endpoint": "x", "result": r[2]} for r in rows]},
            "observations": [{"subject": "%s->%s" % (ns, r[0]), "dimension": "ns-to-ns", "observed": r[1], "raw": r[2]}
                             for r in rows]}


class Termination(unittest.TestCase):
    def test_round_trip(self):
        d = obs_doc("a", "10.42.0.5", [("b", "denied", "refused")])
        msg, shed = blackbox.encode_termination(d)
        self.assertTrue(msg.startswith(blackbox.TERM_PREFIX))
        self.assertEqual(shed, [])
        self.assertEqual(blackbox.decode_termination(msg)["observations"], d["observations"])

    def test_sheds_detail_before_observations(self):
        d = obs_doc("a", "10.42.0.5", [("t%d" % i, "denied", "refused") for i in range(20)])
        d["namespace"]["identity"]["resolvedRules"] = [os.urandom(40).hex() for _ in range(200)]
        msg, shed = blackbox.encode_termination(d)
        self.assertIsNotNone(msg)
        self.assertLessEqual(len(msg), blackbox.TERM_LIMIT)
        self.assertIn("namespace.identity.resolvedRules", shed)
        back = blackbox.decode_termination(msg)
        self.assertEqual(len(back["observations"]), 20)
        self.assertEqual(back["shed"], shed)

    def test_refuses_rather_than_truncates(self):
        d = obs_doc("a", "10.42.0.5", [(os.urandom(40).hex(), "denied", "refused") for _ in range(300)])
        msg, _ = blackbox.encode_termination(d)
        self.assertIsNone(msg)

    def test_decode_rejects_foreign_text(self):
        for bad in (None, "", "PPv0:too-large", "hello"):
            with self.assertRaises(Exception):
                blackbox.decode_termination(bad)


# ----------------------------------------------------------------- fake API
NSS = ["a", "b"]
POLS = [  # b denies ingress from everyone; a has no policy
    {"metadata": {"namespace": "b", "name": "default-deny-ingress"}, "spec": {"podSelector": {}, "policyTypes": ["Ingress"]}},
]


class FakeApi:
    def __init__(self, allowed=(), collectors=None, standins=True):
        self.allowed = set(allowed)      # (verb, resource, namespace) the oracle says yes to
        self.collectors = collectors or {}
        self.standins = standins
        self.calls = []

    def call(self, method, path, body=None, accept=None):
        self.calls.append((method, path))
        if method == "POST" and path.endswith("selfsubjectaccessreviews"):
            a = body["spec"]["resourceAttributes"]
            res = a["resource"] + ("/" + a["subresource"] if a.get("subresource") else "")
            return 201, {"status": {"allowed": (a["verb"], res, a.get("namespace", "")) in self.allowed}}
        if method != "GET":
            raise AssertionError("the differential issued a %s to %s" % (method, path))
        if path == "/api/v1/namespaces":
            return 200, {"items": [{"metadata": {"name": n, "labels": {"kubernetes.io/metadata.name": n}}}
                                   for n in NSS + ["other"]]}
        if "/networkpolicies" in path:
            ns = path.split("/namespaces/")[1].split("/")[0]
            return 200, {"items": [p for p in POLS if p["metadata"]["namespace"] == ns]}
        if "/pods" in path:
            ns = path.split("/namespaces/")[1].split("/")[0]
            if "labelSelector=" in path:
                job = path.split("job-name%3D")[1]
                msg = self.collectors.get((ns, job))
                if msg is None:
                    return 200, {"items": []}
                return 200, {"items": [{"metadata": {"name": job + "-x", "creationTimestamp": "t"},
                                        "status": {"phase": "Succeeded", "containerStatuses": [
                                            {"name": "probe", "state": {"terminated": {"message": msg}}}]}}]}
            items = []
            if self.standins:
                items.append({"metadata": {"name": "s", "labels": {"app.kubernetes.io/name": "posture-standin"}},
                              "status": {"phase": "Running", "podIP": "10.42.0.%d" % (10 + NSS.index(ns))}})
            return 200, {"items": items}
        raise AssertionError("unexpected GET " + path)


TARGETS = {"probeLabels": {"app.kubernetes.io/name": "posture-probe"},
           "targets": {n: {"namespace": n, "port": 8080, "labels": {"app.kubernetes.io/name": "posture-standin"}}
                       for n in NSS}}
INTENTS = [{"subject": "a->b", "dimension": "ns-to-ns", "intent": "deny"},
           {"subject": "b->a", "dimension": "ns-to-ns", "intent": "allow"}]
CONF = {"namespaces": NSS, "identityVantages": [], "clusterIdentifier": "fake", "keep": 2}


def term(ns, ip, rows):
    return blackbox.encode_termination(obs_doc(ns, ip, rows))[0]


class Differential(unittest.TestCase):
    def go(self, api, run_id="r1"):
        out = tempfile.mkdtemp()
        buf = io.StringIO()
        with redirect_stdout(buf):
            gate, rep = aggregate.run(aggregate.Cluster(api), CONF, INTENTS, TARGETS, run_id,
                                      deadline=0, out_dir=out, sleep=lambda s: None, now=lambda: 1)
        return gate, rep, out, buf.getvalue()

    def collectors(self, a_to_b="denied", raw="refused"):
        return {("a", "posture-probe-collect-r1"): term("a", "10.42.0.20", [("b", a_to_b, raw)]),
                ("b", "posture-probe-collect-r1"): term("b", "10.42.0.21", [("a", "allowed", "open")])}

    def test_clean(self):
        gate, rep, out, log = self.go(FakeApi(collectors=self.collectors()))
        self.assertEqual(gate, 0)
        self.assertEqual(rep["summary"]["confirmedSafeCount"], 2)
        path = os.path.join(out, "report-r1.json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(open(os.path.join(out, "latest")).read().strip(), "report-r1.json")

    def test_enforcement_drift_is_2_and_never_printed(self):
        gate, rep, _, log = self.go(FakeApi(collectors=self.collectors("allowed", "open")))
        self.assertEqual(gate, 2)
        row = [r for r in rep["differential"] if r["bucket"] == "drift"][0]
        self.assertEqual((row["subject"], row["config"], row["cause"]), ("a->b", "denied", "enforcement"))
        self.assertIn("drift=1", log)
        self.assertNotIn("a->b", log)          # counts only: the finding stays in the store

    def test_missing_collector_is_could_not_run(self):
        c = self.collectors(); c.pop(("b", "posture-probe-collect-r1"))
        gate, rep, _, log = self.go(FakeApi(collectors=c))
        self.assertEqual(gate, 1)
        self.assertEqual(rep["run"]["notObserved"], ["b/posture-probe-collect-r1"])
        self.assertIn("not observed: b", log)

    def test_unreadable_termination_message_is_could_not_run(self):
        c = self.collectors(); c[("b", "posture-probe-collect-r1")] = "PPv0:too-large"
        gate, _, _, _ = self.go(FakeApi(collectors=c))
        self.assertEqual(gate, 1)

    def test_unsettled_collector_is_could_not_run_with_its_reason(self):
        c = self.collectors()
        d = obs_doc("b", "10.42.0.21", [("a", "allowed", "open")])
        d["observations"] = []
        d["namespace"]["settle"] = {"settled": False, "seconds": 60, "reason": "control internet read allowed, expected denied"}
        c[("b", "posture-probe-collect-r1")] = blackbox.encode_termination(d)[0]
        gate, rep, _, log = self.go(FakeApi(collectors=c))
        self.assertEqual(gate, 1)
        self.assertIn("did not settle", log)
        self.assertNotIn("internet", log)          # which control read what is a finding: report only
        self.assertIn("control internet", rep["run"]["notSettled"]["b/posture-probe-collect-r1"])

    def test_write_capable_identity_refuses_before_reading_anything(self):
        for grant in [("patch", "networkpolicies", "b"), ("create", "pods/exec", "a"),
                      ("delete", "pods", ""), ("list", "secrets", ""), ("get", "pods/log", "a")]:
            api = FakeApi(allowed=[grant], collectors=self.collectors())
            gate, rep, _, log = self.go(api)
            self.assertEqual((gate, rep), (1, None), grant)
            self.assertIn("REFUSING", log)
            self.assertFalse([c for c in api.calls if c[0] == "GET"], "read state after refusing: %s" % (grant,))

    def test_only_gets_and_review_posts(self):
        api = FakeApi(collectors=self.collectors())
        self.go(api)
        for m, p in api.calls:
            self.assertTrue(m == "GET" or p.endswith("selfsubjectaccessreviews"), (m, p))

    def test_retention_keeps_n(self):
        out = tempfile.mkdtemp()
        for i in range(4):
            c = {("a", "posture-probe-collect-r%d" % i): term("a", "10.42.0.20", [("b", "denied", "refused")]),
                 ("b", "posture-probe-collect-r%d" % i): term("b", "10.42.0.21", [("a", "allowed", "open")])}
            with redirect_stdout(io.StringIO()):
                aggregate.run(aggregate.Cluster(FakeApi(collectors=c)), CONF, INTENTS, TARGETS, "r%d" % i,
                              deadline=0, out_dir=out, sleep=lambda s: None, now=lambda: 1)
            os.utime(os.path.join(out, "report-r%d.json" % i), (1000 + i, 1000 + i))
        self.assertEqual(sorted(p for p in os.listdir(out) if p.endswith(".json")), ["report-r2.json", "report-r3.json"])

    def test_run_id_from_job_name(self):
        os.environ["POSTURE_RUN_JOB"] = "something-else"
        os.environ.pop("POSTURE_RUN_ID", None)
        with redirect_stdout(io.StringIO()) as b:
            self.assertEqual(aggregate.main(), 1)
        self.assertIn("cannot tell which run", b.getvalue())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Regression tests for the Security Posture Probe differential engine (stdlib only).

Run:  python3 -m unittest discover -s addons/posture-probe/tests   (from the repository root)
"""
import json, os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "posture_probe"))
from differential import Declared, build, classify  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")


def ns(n, **l):
    return {"metadata": {"name": n, "labels": {"kubernetes.io/metadata.name": n, **l}}}


def pol(n, name, spec):
    return {"metadata": {"namespace": n, "name": name}, "spec": spec}


BUNDLE = {
    "namespaces": [ns("a"), ns("b"), ns("mon"), ns("plat")],
    "networkpolicies": [
        pol("b", "default-deny-ingress", {"podSelector": {}, "policyTypes": ["Ingress"]}),
        pol("b", "allow-intra", {"podSelector": {}, "ingress": [{"from": [{"podSelector": {}}]}]}),
        pol("b", "allow-scrape", {"podSelector": {}, "ingress": [{"from": [{"namespaceSelector": {
            "matchLabels": {"kubernetes.io/metadata.name": "mon"}}}], "ports": [{"port": 9090}]}]}),
        pol("a", "default-deny-egress", {"podSelector": {}, "policyTypes": ["Egress"]}),
        pol("a", "allow-dns", {"podSelector": {}, "policyTypes": ["Egress"],
                               "egress": [{"ports": [{"port": 53, "protocol": "UDP"}]}]}),
        # The shape of tockmox-platform's allow-from-node-network: an ipBlock over the pod CIDR.
        pol("plat", "default-deny-ingress", {"podSelector": {}, "policyTypes": ["Ingress"]}),
        pol("plat", "allow-from-node-network", {"podSelector": {}, "ingress": [{"from": [
            {"ipBlock": {"cidr": "10.0.2.0/24"}}, {"ipBlock": {"cidr": "10.42.0.0/16"}}]}]}),
    ],
    "pods": [{"name": "s", "namespace": "plat", "labels": {"app": "s"}, "ip": "10.42.0.99"}],
}
D = Declared(BUNDLE)
src = lambda n, ip=None: {"ns": n, "labels": {}, "ip": ip}
dst = lambda n, port, ip=None: {"ns": n, "labels": {}, "ip": ip, "port": port}


class Evaluator(unittest.TestCase):
    def test_scrape_port_scoped(self):
        self.assertEqual(D.verdict(src("mon"), dst("b", 8080))[0], "denied")
        self.assertEqual(D.verdict(src("mon"), dst("b", 9090))[0], "allowed")

    def test_intra_namespace(self):
        self.assertEqual(D.verdict(src("b"), dst("b", 8080))[0], "allowed")

    def test_egress_default_deny(self):
        self.assertEqual(D.verdict(src("a"), dst("b", 8080))[0], "denied")
        self.assertEqual(D.verdict(src("a"), dst(None, 443, "1.1.1.1"))[0], "denied")

    def test_no_egress_policy_is_open(self):
        self.assertEqual(D.verdict(src("mon"), dst(None, 443, "1.1.1.1"))[0], "allowed")

    def test_ipblock_over_pod_cidr_admits_a_pod(self):
        """Regression, 2026-10-04: the source pod IP was None, so no ipBlock could
        ever match a pod and the engine reported ENFORCEMENT drift that was really
        CONFIG drift. With the measured source IP, the rule admits it, and the row
        says the semantics are CNI-dependent."""
        v, why = D.verdict(src("mon", "10.42.0.17"), dst("plat", 8080, "10.42.0.99"))
        self.assertEqual(v, "allowed")
        self.assertIn("CNI-dependent", why)

    def test_unknown_source_ip_cannot_match_ipblock(self):
        self.assertEqual(D.verdict(src("mon", None), dst("plat", 8080))[0], "denied")


class Differential(unittest.TestCase):
    def test_classify(self):
        self.assertEqual(classify("deny", "allowed"), "drift")
        self.assertEqual(classify("allow", "denied"), "unintended-deny")
        self.assertEqual(classify("deny", "denied"), "confirmed-safe")
        self.assertEqual(classify("deny", "unknown"), "unknown")

    def _run(self, observed, intents):
        targets = {"plat": {"namespace": "plat", "labels": {"app": "s"}, "port": 8080},
                   "b": {"namespace": "b", "labels": {}, "port": 8080}}
        return build(observed, intents, D, targets, {})

    def test_cause_config_when_policy_allows(self):
        obs = {"namespaces": [{"name": "mon", "podIP": "10.42.0.17", "reachability": [{}]}],
               "observations": [{"subject": "mon->plat", "dimension": "ns-to-ns", "observed": "allowed"}]}
        rep, gate = self._run(obs, [{"subject": "mon->plat", "dimension": "ns-to-ns", "intent": "deny"}])
        row = rep["differential"][0]
        self.assertEqual((row["bucket"], row["config"], row["cause"], gate), ("drift", "allowed", "config", 2))

    def test_cause_enforcement_when_policy_denies(self):
        obs = {"namespaces": [{"name": "mon", "podIP": "10.42.0.17", "reachability": [{}]}],
               "observations": [{"subject": "mon->b", "dimension": "ns-to-ns", "observed": "allowed"}]}
        rep, _ = self._run(obs, [{"subject": "mon->b", "dimension": "ns-to-ns", "intent": "deny"}])
        row = rep["differential"][0]
        self.assertEqual((row["config"], row["cause"], row["severity"]), ("denied", "enforcement", "critical"))

    def test_rbac_rows_are_oracle_evaluated(self):
        obs = {"observations": [{"subject": "d:sa", "dimension": "rbac:list secrets @*", "observed": "denied"}]}
        rep, gate = build(obs, [{"subject": "d:sa", "dimension": "rbac:list secrets @*", "intent": "deny", "tier": "claimed"}], D, {}, {})
        row = rep["differential"][0]
        self.assertEqual((row["bucket"], row["config"], row["tier"], gate), ("confirmed-safe", "oracle", "claimed", 0))

    def test_no_observations_is_could_not_run_not_clean(self):
        """Proven 2026-10-04 by prove-the-gate M3: zero observations used to exit 0."""
        rep, gate = build({"observations": []}, [{"subject": "a->b", "dimension": "ns-to-ns", "intent": "deny"}])
        self.assertEqual((rep["differential"][0]["bucket"], gate), ("unknown", 1))

    def test_drift_outranks_unknown(self):
        obs = {"observations": [{"subject": "a->b", "dimension": "ns-to-ns", "observed": "allowed"}]}
        _, gate = build(obs, [{"subject": "a->b", "dimension": "ns-to-ns", "intent": "deny"},
                              {"subject": "a->c", "dimension": "ns-to-ns", "intent": "deny"}])
        self.assertEqual(gate, 2)

    def test_v0_fixtures_still_gate(self):
        from differential import load_intents
        intents = load_intents(os.path.join(FIX, "intent.yaml"))
        _, g_clean = build(json.load(open(os.path.join(FIX, "observed-clean.json"))), intents)
        _, g_drift = build(json.load(open(os.path.join(FIX, "observed-drift.json"))), intents)
        self.assertEqual((g_clean, g_drift), (0, 2))


if __name__ == "__main__":
    unittest.main()

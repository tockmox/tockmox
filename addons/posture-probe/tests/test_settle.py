#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Settling (lab, 2026-10-08): a collector must not measure inside the window in which
the cluster has not yet applied NetworkPolicy to its brand-new pod.

Measured on a single-node k3s lab (embedded kube-router, 2026-10-08): for about the
first second of a pod's life its egress default-deny does not hold (a fresh pod
in an egress-denied namespace reached the internet, 3/3) and allow rules naming
it do not hold either (2/2 refused at t+0, allowed at t+1). The single-shot
collector measured inside that window: it missed an injected allow and reported
enforcement drift that the settled cluster does not have.

These tests drive the collector with a fake clock and a fake network that
reproduces that window, and assert it reports the SETTLED state, or says it
could not settle (never the window's reading).
"""
import unittest
from unittest import mock
from _common import FIX  # noqa: F401  (puts the add-on on sys.path)
from posture_probe import blackbox


class Clock:
    def __init__(self):
        self.t = 0.0

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.t += s


EPS = [{"target": "internet", "host": "1.1.1.1", "port": 443, "dst_namespace": None, "dimension": "egress", "listener": True},
       {"target": "tockmox-ai", "host": "posture-standin.tockmox-ai.svc.cluster.local", "port": 8080,
        "dst_namespace": "tockmox-ai", "dimension": "ns-to-ns", "listener": True}]


def window_network(clock, window=1.0, internet_window=None):
    """As measured: egress deny and an allow rule both lag the pod's start."""
    iw = window if internet_window is None else internet_window

    def connect(host, port, timeout):
        clock.t += 0.05
        if host == "1.1.1.1":
            return ("open", 5, host) if clock.t < iw else ("timeout", None, host)
        return ("refused", 1, "10.42.0.46") if clock.t < window else ("open", 1, "10.42.0.46")
    return connect


def observed(obs):
    return {o["subject"]: o["observed"] for o in obs}


class Settle(unittest.TestCase):
    def go(self, connect, clock, settle=None):
        fake_time = mock.Mock(monotonic=clock.monotonic, sleep=clock.sleep)
        with mock.patch.object(blackbox, "connect_only", connect), mock.patch.object(blackbox, "time", fake_time), \
                mock.patch.object(blackbox.os.path, "exists", return_value=False):
            if settle is None:
                return blackbox.run("tockmox-diagnostic", EPS, 2)
            return blackbox.run("tockmox-diagnostic", EPS, 2, settle=settle)

    def test_default_reports_the_settled_state_not_the_first_second(self):
        c = Clock()
        report, obs = self.go(window_network(c), c)
        self.assertEqual(observed(obs), {"tockmox-diagnostic->internet": "denied",
                                         "tockmox-diagnostic->tockmox-ai": "allowed"})
        self.assertTrue(report["settle"]["settled"])
        self.assertGreaterEqual(report["settle"]["rounds"], 3)

    def test_control_must_read_denied_before_measurement_counts(self):
        # Egress deny lags 4 s here, longer than the stability span alone would wait.
        c = Clock()
        settle = dict(blackbox.SETTLE_DEFAULTS, controls=[{"target": "internet", "expect": "denied"}])
        report, obs = self.go(window_network(c, window=1.0, internet_window=4.0), c, settle)
        self.assertEqual(observed(obs)["tockmox-diagnostic->internet"], "denied")
        self.assertGreaterEqual(c.t, 4.0)
        self.assertTrue(report["settle"]["settled"])

    def test_a_control_that_never_holds_is_could_not_settle(self):
        c = Clock()
        settle = dict(blackbox.SETTLE_DEFAULTS, controls=[{"target": "internet", "expect": "denied"}], maxSeconds=20)
        report, obs = self.go(window_network(c, internet_window=1e9), c, settle)
        self.assertFalse(report["settle"]["settled"])
        self.assertIn("control internet", report["settle"]["reason"])
        self.assertEqual(obs, [])               # nothing measured in an unsettled pod is reported
        self.assertLessEqual(c.t, 20 + 3)       # bounded

    def test_a_flapping_path_is_could_not_settle(self):
        c = Clock()

        def flap(host, port, timeout):   # a path whose verdict changes every second, forever
            c.t += 0.05
            return ("open", 1, host) if int(c.t) % 2 == 0 else ("timeout", None, host)
        report, obs = self.go(flap, c, dict(blackbox.SETTLE_DEFAULTS, maxSeconds=15))
        self.assertFalse(report["settle"]["settled"])
        self.assertEqual(obs, [])

    def test_an_identity_vantage_ignores_its_namespaces_network_controls(self):
        # Lab N2 (2026-10-08): autoControls are per NAMESPACE, so the identity vantage in tockmox-diagnostic
        # received that namespace's `internet` deny control. It measures no endpoint at all (endpoints-empty.json),
        # refused at once with "control internet is not a declared endpoint", and the default install's gate was 1
        # on every run. A vantage with nothing to measure has nothing to settle.
        settle = dict(blackbox.SETTLE_DEFAULTS, controls=[{"target": "internet", "expect": "denied"}])

        def no_network(host, port, timeout):
            raise AssertionError("an identity vantage must not connect anywhere")
        with mock.patch.object(blackbox, "connect_only", no_network):
            res, info = blackbox.settle_rounds("tockmox-diagnostic", [], 2, settle)
        self.assertEqual(res, [])
        self.assertTrue(info["settled"], info)
        self.assertEqual(info["controls"], [])

    def test_a_network_collector_still_refuses_an_undeclared_control(self):
        settle = dict(blackbox.SETTLE_DEFAULTS, controls=[{"target": "kube-api", "expect": "denied"}])
        res, info = blackbox.settle_rounds("tockmox-diagnostic", EPS, 2, settle)
        self.assertFalse(info["settled"])
        self.assertIn("control kube-api is not a declared endpoint", info["reason"])

    def test_unsettled_collector_writes_its_reason_and_exits_1(self):
        doc = {"schemaVersion": "v0", "mode": "black-box",
               "namespace": {"name": "a", "settle": {"settled": False, "reason": "x"}}, "observations": []}
        msg, _ = blackbox.encode_termination(doc)
        self.assertFalse(blackbox.decode_termination(msg)["namespace"]["settle"]["settled"])


if __name__ == "__main__":
    unittest.main()

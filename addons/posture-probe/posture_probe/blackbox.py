#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Security Posture Probe ... black-box collector (v0, stdlib only).

Runs INSIDE a source namespace, as that namespace's real ServiceAccount, under
that namespace's real NetworkPolicies: the vantage of an arbitrary workload
there. Observe-and-report only:

  identity    reads the authorization oracle (SelfSubjectRulesReview /
              SelfSubjectAccessReview). It records the VERDICT; it never
              performs the verb.
  exposure    whether a token is mounted; which Secrets are visible, fetched as
              METADATA ONLY (PartialObjectMetadataList), so no secret value is
              ever transferred to the probe.
  reach       connect-only TCP against a DECLARED endpoint list. The socket is
              opened and closed; no byte is sent, no protocol spoken, no auth.

Output, two forms:
  PROBE_OUTPUT=termination (the add-on)  the document, gzipped and base64'd, in the
      container's termination message, which the differential Job reads from pod
      status. Nothing about what was found is printed: the report is sensitive and
      a log line travels to wherever the cluster ships logs (threat model s5).
  otherwise (the pilot)  one JSON document on stdout between PROBE-REPORT-BEGIN/END.
"""
import base64, gzip, json, os, socket, ssl, sys, time, urllib.request, urllib.error

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
MARK_B, MARK_E = "PROBE-REPORT-BEGIN", "PROBE-REPORT-END"

# Access checks: questions asked of the oracle. Each is answered allowed/denied;
# none is attempted. Chosen to cover the blast-radius questions that matter.
ACCESS_CHECKS = [
    ("list", "", "secrets", "{ns}"), ("list", "", "secrets", ""),
    ("get", "", "secrets", "kube-system"), ("create", "", "pods", "{ns}"),
    ("create", "", "pods/exec", "{ns}"), ("list", "", "pods", ""),
    ("list", "", "nodes", ""), ("list", "", "namespaces", ""),
    ("create", "networking.k8s.io", "networkpolicies", "{ns}"),
    ("delete", "networking.k8s.io", "networkpolicies", "{ns}"),
    ("create", "rbac.authorization.k8s.io", "rolebindings", "{ns}"),
    ("create", "rbac.authorization.k8s.io", "clusterrolebindings", ""),
    ("impersonate", "", "serviceaccounts", ""),
    ("escalate", "rbac.authorization.k8s.io", "clusterroles", ""),
    ("create", "apps", "deployments", "{ns}"),
]


def jwt_claims(token):
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part))
    except Exception:
        return {}


def connect_only(host, port, timeout):
    """Open and close a TCP socket. Nothing is sent. Returns (result, ms, ip)."""
    t0 = time.monotonic()
    try:
        infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror:
        return "dns-fail", None, None
    ip = infos[0][4][0]
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((ip, port))
        return "open", round((time.monotonic() - t0) * 1000), ip
    except socket.timeout:
        return "timeout", None, ip
    except ConnectionRefusedError:
        return "refused", round((time.monotonic() - t0) * 1000), ip
    except OSError as e:
        return "error:%s" % e.errno, None, ip
    finally:
        s.close()


class Api:
    def __init__(self, timeout):
        self.host = os.environ.get("KUBERNETES_SERVICE_HOST")
        self.port = int(os.environ.get("KUBERNETES_SERVICE_PORT", "443"))
        self.token = open(os.path.join(SA_DIR, "token")).read().strip()
        self.ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
        self.timeout = timeout

    def call(self, method, path, body=None, accept="application/json"):
        url = "https://%s:%d%s" % (self.host, self.port, path)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json", "Accept": accept})
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, None
        except Exception as e:  # network-level: the API is not reachable from here
            return "unreachable:%s" % type(e).__name__, None


# ---------------------------------------------------------------- settling
# A brand-new pod is not policed at once. Measured on k3s's embedded kube-router
# (lab, 2026-10-08): for about its first second, egress default-deny does not
# hold and allow rules naming the pod do not hold either. A collector that measures
# at once reports that window, not the cluster. So it measures in ROUNDS and
# reports only once:
#   1. every CONTROL reads what it must (a target the namespace's own policy denies
#      must read denied: proof the pod's egress rules are programmed), and
#   2. every declared endpoint has read the same in `stableRounds` consecutive
#      rounds spanning at least `minSpanSeconds` (the allow side has no control that
#      works for every namespace; a flip out of the window shows up as a change).
# If that has not happened by `maxSeconds`, the collector says it could not settle
# and exits 1: could-not-run, never a reading from the window.
SETTLE_DEFAULTS = {"controls": [], "stableRounds": 3, "intervalSeconds": 1.0,
                   "minSpanSeconds": 3.0, "maxSeconds": 60.0}


def classify_connect(result, listener):
    if result == "open":
        return "allowed"
    if result == "timeout" or (result == "refused" and listener):
        return "denied"   # refused on a KNOWN listener is a policy reject
    return "unknown"      # refused with no known listener proves nothing


def measure(endpoints, timeout):
    """One round: every endpoint, concurrently, so a round costs one timeout, not N."""
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(16, len(endpoints)))) as ex:
        futs = [ex.submit(connect_only, ep["host"], int(ep["port"]), timeout) for ep in endpoints]
        out = []
        for ep, f in zip(endpoints, futs):
            result, ms, ip = f.result()
            out.append((ep, (result, ms, ip, classify_connect(result, bool(ep.get("listener"))))))
        return out


def settle_rounds(ns, endpoints, timeout, settle=None):
    cfg = dict(SETTLE_DEFAULTS, **(settle or {}))
    if not endpoints:
        # An identity vantage (endpoints-empty.json): it opens no connection, so nothing it reports can come from
        # the unpoliced window and there is nothing to settle. The namespace's controls (autoControls included)
        # are for the network collector beside it, which measures those targets; applied here they named an
        # endpoint this vantage never declares and the default install's gate was 1 on every run (lab N2).
        return [], {"settled": True, "rounds": 0, "seconds": 0, "controls": []}
    eps = [ep for ep in endpoints if not (ep.get("dst_namespace") == ns and ep.get("skip_self", True))]
    controls = cfg.get("controls") or []
    by_target = {ep["target"]: ep for ep in endpoints}
    for c in controls:
        if c["target"] not in by_target:
            return [], {"settled": False, "rounds": 0, "seconds": 0,
                        "reason": "control %s is not a declared endpoint" % c["target"]}
    ctl_eps = [by_target[c["target"]] for c in controls]
    if not eps and not ctl_eps:   # only self-targets declared: nothing reachable is measured, nothing to wait for
        return [], {"settled": True, "rounds": 0, "seconds": 0, "controls": []}
    t0 = time.monotonic()
    rounds, streak, streak_t0, last, ctl_ok_at = 0, 0, None, None, None
    reason = "no round completed"
    while True:
        r_t0 = time.monotonic()
        res = measure(eps, timeout) if eps else []
        ctl = measure([ep for ep in ctl_eps if ep not in eps], timeout) if ctl_eps else []
        rounds += 1
        seen = {ep["target"]: v[3] for ep, v in res + ctl}
        bad = [c for c in controls if seen.get(c["target"]) != c.get("expect", "denied")]
        if bad:
            streak, last = 0, None
            reason = "control %s read %s, expected %s" % (bad[0]["target"], seen.get(bad[0]["target"]),
                                                        bad[0].get("expect", "denied"))
        else:
            if ctl_ok_at is None:
                ctl_ok_at = rounds
            key = tuple(v[3] for _, v in res)
            if key == last:
                streak += 1
            else:
                streak, streak_t0, last = 1, r_t0, key
            reason = "endpoint readings still changing (%d stable of %d rounds needed)" % (streak, cfg["stableRounds"])
            if streak >= cfg["stableRounds"] and time.monotonic() - streak_t0 >= cfg["minSpanSeconds"]:
                return res, {"settled": True, "rounds": rounds, "seconds": round(time.monotonic() - t0, 2),
                             "controls": [c["target"] for c in controls], "controlsHeldFromRound": ctl_ok_at}
        if time.monotonic() - t0 >= cfg["maxSeconds"]:
            return [], {"settled": False, "rounds": rounds, "seconds": round(time.monotonic() - t0, 2),
                        "reason": reason}
        time.sleep(cfg["intervalSeconds"])


def run(ns, endpoints, timeout, settle=None):
    token = open(os.path.join(SA_DIR, "token")).read().strip() if os.path.exists(os.path.join(SA_DIR, "token")) else ""
    claims = jwt_claims(token) if token else {}
    sa = (claims.get("sub") or "none").split(":")[-1]
    report = {"name": ns, "podIP": os.environ.get("PROBE_POD_IP"),
              "identity": {"serviceAccount": sa, "tokenMounted": bool(token)},
              "exposure": {}, "reachability": []}

    # ---- identity + exposure via the oracle (only if a token exists and the API answers)
    api_state = "no-token"
    ident_obs = []
    if token:
        api = Api(timeout)
        res, _, _ = connect_only(api.host, api.port, timeout)
        api_state = {"open": "reachable"}.get(res, "unreachable(%s)" % res)
        if res == "open":
            st, rr = api.call("POST", "/apis/authorization.k8s.io/v1/selfsubjectrulesreviews",
                              {"apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectRulesReview",
                               "spec": {"namespace": ns}})
            rules = []
            if isinstance(rr, dict):
                for r in rr.get("status", {}).get("resourceRules", []):
                    rules.append("%s %s" % (",".join(r.get("verbs", [])),
                                            ",".join(r.get("resources", [])) or "*"))
            report["identity"]["resolvedRules"] = sorted(set(rules))
            checks = []
            for verb, group, res_, cns in ACCESS_CHECKS:
                cns = cns.format(ns=ns)
                st, ar = api.call("POST", "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews",
                                  {"apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview",
                                   "spec": {"resourceAttributes": {"verb": verb, "group": group,
                                                                   "resource": res_, "namespace": cns}}})
                allowed = bool(isinstance(ar, dict) and ar.get("status", {}).get("allowed"))
                checks.append({"verb": verb, "resource": (group + "/" if group else "") + res_,
                               "namespace": cns or "*", "allowed": allowed})
            report["identity"]["accessChecks"] = checks
            # Oracle verdicts become differential observations too. For RBAC the
            # API server is both the declared config and the enforcer, so these
            # rows can drift against INTENT but never against config.
            for c in checks:
                ident_obs.append({"subject": "%s:%s" % (ns, sa),
                                  "dimension": "rbac:%s %s @%s" % (c["verb"], c["resource"], c["namespace"]),
                                  "observed": "allowed" if c["allowed"] else "denied", "raw": "oracle"})
            # Secret NAMES only, as metadata; values are never requested.
            st, ml = api.call("GET", "/api/v1/namespaces/%s/secrets" % ns,
                              accept="application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1")
            if st == 200 and isinstance(ml, dict):
                report["exposure"]["visibleSecrets"] = sorted(i["metadata"]["name"] for i in ml.get("items", []))
            else:
                report["exposure"]["visibleSecrets"] = "denied(%s)" % st
    report["identity"]["apiServer"] = api_state

    # ---- connect-only reachability against the declared list, once the pod is policed
    rounds, info = settle_rounds(ns, endpoints, timeout, settle)
    report["settle"] = info
    if not info["settled"]:
        # Nothing measured in a pod the cluster may not have policed yet is reported:
        # a reading from that window is neither config nor enforcement (the settling window).
        return report, []
    obs = []
    for ep, (result, ms, ip, observed) in rounds:
        report["reachability"].append({"endpoint": "%s:%s" % (ep["host"], ep["port"]), "ip": ip,
                                       "dstNamespace": ep.get("dst_namespace"),
                                       "dimension": ep["dimension"], "result": result,
                                       "observed": observed, "latencyMs": ms})
        obs.append({"subject": "%s->%s" % (ns, ep["target"]), "dimension": ep["dimension"],
                    "observed": observed, "raw": result})
    return report, obs + ident_obs


# Kubernetes caps a container's termination message at 4096 bytes. The marker
# says which encoding follows, so the reader never guesses.
TERM_LIMIT = 4096
TERM_PREFIX = "PPv0:gz:"


def encode_termination(doc, limit=TERM_LIMIT):
    """Encode a collector document to fit a termination message.

    Observations are the measurement and are never dropped. If the full document
    does not fit, the detail blocks are shed in a fixed order and the document
    says which were shed. Returns (message, shed); message is None if even the
    observations alone do not fit, which the caller must treat as a failed run.
    """
    shed = []
    steps = [("namespace.identity.resolvedRules", lambda d: d["namespace"]["identity"].pop("resolvedRules", None)),
             ("namespace.exposure", lambda d: d["namespace"].pop("exposure", None)),
             ("namespace.identity.accessChecks", lambda d: d["namespace"]["identity"].pop("accessChecks", None)),
             ("namespace.reachability", lambda d: d["namespace"].pop("reachability", None))]
    doc = json.loads(json.dumps(doc))
    while True:
        if shed:
            doc["shed"] = list(shed)
        raw = json.dumps(doc, separators=(",", ":"), sort_keys=True).encode()
        msg = TERM_PREFIX + base64.b64encode(gzip.compress(raw, mtime=0)).decode()
        if len(msg) <= limit:
            return msg, shed
        if not steps:
            return None, shed
        name, fn = steps.pop(0)
        fn(doc)
        shed.append(name)


def decode_termination(msg):
    if not msg or not msg.startswith(TERM_PREFIX):
        raise ValueError("not a posture-probe termination message")
    return json.loads(gzip.decompress(base64.b64decode(msg[len(TERM_PREFIX):])))


def main():
    # The Downward API is the reliable source: a tokenless pod (automount off, the
    # Tockmox default) has no ServiceAccount mount and so no namespace file.
    ns = os.environ.get("PROBE_NAMESPACE")
    if not ns and os.path.exists(os.path.join(SA_DIR, "namespace")):
        ns = open(os.path.join(SA_DIR, "namespace")).read().strip()
    if not ns:
        sys.stderr.write("REFUSING: no namespace. Set PROBE_NAMESPACE from the Downward API (metadata.namespace).\n")
        sys.exit(1)
    endpoints = json.load(open(os.environ.get("PROBE_ENDPOINTS", "/etc/probe/endpoints.json")))
    timeout = float(os.environ.get("PROBE_TIMEOUT", "2"))
    settle = None
    sp = os.environ.get("PROBE_SETTLE")
    if sp and os.path.exists(sp):
        settle = json.load(open(sp)).get(ns, json.load(open(sp)).get("*"))
    report, obs = run(ns, endpoints, timeout, settle)
    out = {"schemaVersion": "v0", "mode": "black-box", "namespace": report, "observations": obs}
    if os.environ.get("PROBE_OUTPUT") == "termination":
        path = os.environ.get("PROBE_TERMINATION_PATH", "/dev/termination-log")
        msg, shed = encode_termination(out)
        if msg is None:
            sys.stderr.write("posture-probe collect: %d observations do not fit a termination message; "
                             "declare fewer endpoints per namespace\n" % len(obs))
            with open(path, "w") as f:
                f.write("PPv0:too-large")
            sys.exit(1)
        with open(path, "w") as f:
            f.write(msg)
        st = report.get("settle", {})
        # Counts only. What was reachable is the sensitive part and stays out of logs.
        print("posture-probe collect: namespace=%s observations=%d message-bytes=%d shed=%s settled=%s rounds=%s seconds=%s"
              % (ns, len(obs), len(msg), ",".join(shed) or "none", st.get("settled"), st.get("rounds"), st.get("seconds")))
        if st and not st.get("settled"):
            # Which control read what is a finding: it travels in the termination message, not the log.
            sys.stderr.write("posture-probe collect: could not settle within %ss; the reason is in the report\n"
                             % st.get("seconds"))
            sys.exit(1)
        return
    print(MARK_B); print(json.dumps(out)); print(MARK_E)
    sys.stdout.flush()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Security Posture Probe ... differential engine (v1, stdlib only).

Three columns per declared intent row:

  intent    what the operator DECLARED (intent file)            allow | deny
  config    what the NetworkPolicies SAY (white-box evaluation)  allowed | denied | n/a
  observed  what the cluster DID (black-box connect-only result) allowed | denied | unknown

Buckets: confirmed-safe, drift (intent deny, observed allowed), unintended-deny
(intent allow, observed denied), unknown (no usable observation).

A drift row is given a CAUSE, which is the point of running both modes:
  config       the policies allow it too ... the declared config never expressed
               the intent. A config scan plus an intent file could find this.
  enforcement  the policies DENY it but the cluster allowed it ... config and
               reality disagree. No config scanner can see this class.

Gate exit code: 0 clean / 1 error / 2 drift. unintended-deny is reported, not gated (v0 policy).

Usage:
  differential.py OBSERVED INTENT                                (v0, fixtures)
  differential.py --observed O --intent I [--declared D --targets T]   (v1)

Observe-and-report only: reads files, writes a report. Contacts no cluster.
"""
import argparse, datetime, ipaddress, json, sys

GATE_CLEAN, GATE_ERROR, GATE_DRIFT = 0, 1, 2
# The report's published contract (TM-0882): schema/report-v0.schema.json. A
# report names the schema it was written against, so an integrator can refuse a
# major it does not know rather than misread it.
SCHEMA_VERSION = "v0"
SCHEMA_ID = "urn:tockmox:posture-probe:report:v0"
PROBE_VERSION = "0.1.0"
SEV = {"drift": "high", "unintended-deny": "medium", "confirmed-safe": "info", "unknown": "low"}


# ------------------------------------------------------------------ intent IO
def load_intents(path):
    if path.endswith(".json"):
        return json.load(open(path))["intents"]
    rows, cur = [], None
    for raw in open(path):
        s = raw.split("#", 1)[0].strip() if not raw.strip().startswith('"') else raw.strip()
        if not s or s.startswith("version:") or s.startswith("intents:"):
            continue
        if s.startswith("- "):
            if cur:
                rows.append(cur)
            cur, s = {}, s[2:].strip()
        if ":" in s and cur is not None:
            k, v = s.split(":", 1)
            cur[k.strip()] = v.strip().strip('"')
    if cur:
        rows.append(cur)
    return rows


# --------------------------------------------------- NetworkPolicy evaluation
def sel_match(sel, labels):
    """LabelSelector semantics. None/{} matches everything."""
    if not sel:
        return True
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get("matchExpressions") or []:
        k, op, vals = e["key"], e["operator"], e.get("values") or []
        if op == "In" and labels.get(k) not in vals: return False
        if op == "NotIn" and labels.get(k) in vals: return False
        if op == "Exists" and k not in labels: return False
        if op == "DoesNotExist" and k in labels: return False
    return True


def ports_match(ports, port, port_name, proto="TCP"):
    if not ports:
        return True
    for p in ports:
        if (p.get("protocol") or "TCP") != proto:
            continue
        pv = p.get("port")
        if pv is None:
            return True
        if isinstance(pv, int) or (isinstance(pv, str) and pv.isdigit()):
            lo = int(pv); hi = int(p.get("endPort") or lo)
            if lo <= port <= hi:
                return True
        elif port_name and pv == port_name:
            return True
    return False


def ip_in_block(ip, block):
    if not ip:
        return False
    a = ipaddress.ip_address(ip)
    if a not in ipaddress.ip_network(block["cidr"], strict=False):
        return False
    return not any(a in ipaddress.ip_network(x, strict=False) for x in block.get("except") or [])


class Declared:
    def __init__(self, bundle):
        self.ns_labels = {n["metadata"]["name"]: n["metadata"].get("labels") or {}
                          for n in bundle["namespaces"]}
        self.pols = bundle["networkpolicies"]
        self.pods = bundle.get("pods", [])
        self._notes = []

    def pod_ip(self, ns, labels):
        for p in self.pods:
            if p["namespace"] == ns and all(p["labels"].get(k) == v for k, v in (labels or {}).items()):
                return p.get("ip")
        return None

    def _types(self, p):
        t = p["spec"].get("policyTypes")
        if t:
            return t
        return ["Ingress"] + (["Egress"] if "egress" in p["spec"] else [])

    def _peer_match(self, peer, pol_ns, other):
        """other: {ns, labels, ip}. A peer with only podSelector means the policy's own ns."""
        if "ipBlock" in peer:
            hit = ip_in_block(other.get("ip"), peer["ipBlock"])
            if hit and other.get("ns") is not None:
                # The spec leaves ipBlock-vs-pod-IP implementation-defined: kube-router and
                # Calico match pod IPs, Cilium by default does not. Say so on the row.
                self._notes.append("ipBlock %s admitted an in-cluster pod (CNI-dependent)" % peer["ipBlock"]["cidr"])
            return hit
        if other.get("ns") is None:          # an off-cluster address only matches ipBlock
            return False
        nsel, psel = peer.get("namespaceSelector"), peer.get("podSelector")
        if nsel is None and psel is not None:
            return other["ns"] == pol_ns and sel_match(psel, other["labels"])
        ok_ns = sel_match(nsel, self.ns_labels.get(other["ns"], {}))
        return ok_ns and sel_match(psel, other["labels"])

    def egress_allowed(self, src, dst):
        sel = [p for p in self.pols if p["metadata"]["namespace"] == src["ns"]
               and "Egress" in self._types(p) and sel_match(p["spec"].get("podSelector"), src["labels"])]
        if not sel:
            return True, "no egress policy selects the source"
        for p in sel:
            for rule in p["spec"].get("egress") or []:
                peers = rule.get("to")
                if (not peers or any(self._peer_match(x, src["ns"], dst) for x in peers)) and \
                        ports_match(rule.get("ports"), dst["port"], dst.get("portName")):
                    return True, "egress allowed by %s" % p["metadata"]["name"]
        return False, "egress denied (%d selecting policies, no matching rule)" % len(sel)

    def ingress_allowed(self, src, dst):
        sel = [p for p in self.pols if p["metadata"]["namespace"] == dst["ns"]
               and "Ingress" in self._types(p) and sel_match(p["spec"].get("podSelector"), dst["labels"])]
        if not sel:
            return True, "no ingress policy selects the destination"
        for p in sel:
            for rule in p["spec"].get("ingress") or []:
                peers = rule.get("from")
                if (not peers or any(self._peer_match(x, dst["ns"], src) for x in peers)) and \
                        ports_match(rule.get("ports"), dst["port"], dst.get("portName")):
                    return True, "ingress allowed by %s" % p["metadata"]["name"]
        return False, "ingress denied (%d selecting policies, no matching rule)" % len(sel)

    def verdict(self, src, dst):
        self._notes = []
        ok_e, why_e = self.egress_allowed(src, dst)
        if dst.get("ns") is None:            # off-cluster: egress only
            v, why = ("allowed" if ok_e else "denied"), why_e
        else:
            ok_i, why_i = self.ingress_allowed(src, dst)
            v, why = ("allowed" if (ok_e and ok_i) else "denied"), "%s; %s" % (why_e, why_i)
        if self._notes:
            why += " [" + "; ".join(sorted(set(self._notes))) + "]"
        return v, why


# ------------------------------------------------------------- differential
def classify(intent, observed):
    if observed not in ("allowed", "denied"):
        return "unknown"
    if intent == "deny" and observed == "allowed":
        return "drift"
    if intent == "allow" and observed == "denied":
        return "unintended-deny"
    return "confirmed-safe"


def build(observed_doc, intents, declared=None, targets=None, probe_labels=None):
    obs = {}
    for o in observed_doc.get("observations", []):
        obs[(o["subject"], o["dimension"])] = o
    # Source IP per namespace, from the REACH vantage that actually measured: the
    # white-box must evaluate the same pod the black-box connected from.
    src_ip = {n["name"]: n.get("podIP") for n in observed_doc.get("namespaces", [])
              if n.get("reachability") and n.get("podIP")}
    rows = []
    for it in intents:
        o = obs.get((it["subject"], it["dimension"]), {})
        observed = o.get("observed", "unknown")
        row = {"subject": it["subject"], "dimension": it["dimension"], "intent": it["intent"],
               "observed": observed, "raw": o.get("raw"), "bucket": classify(it["intent"], observed)}
        if it["dimension"].startswith("rbac:"):
            row["config"] = "oracle"   # the API server is both the declared RBAC and its enforcer
        elif declared and targets and "->" in it["subject"]:
            src_ns, tgt = it["subject"].split("->", 1)
            t = targets.get(tgt)
            if t and t.get("evaluate") is False:
                # The operator did not say what address a NetworkPolicy sees for
                # this target (the API server after DNAT, say). Guessing one is how
                # a false ENFORCEMENT drift is born, so the config column is n/a.
                row["config"] = "n/a"
                row["configWhy"] = "not evaluated: %s" % t.get("why", "no policy-visible address declared for this target")
            elif t:
                src = {"ns": src_ns, "labels": probe_labels or {}, "ip": src_ip.get(src_ns)}
                dip = declared.pod_ip(t["namespace"], t.get("labels")) if t.get("namespace") else None
                dst = {"ns": t.get("namespace"), "labels": t.get("labels") or {},
                       "ip": dip or t.get("policyIp"), "port": int(t.get("policyPort", t["port"])),
                       "portName": t.get("portName")}
                if src["ip"] is None:
                    row["configNote"] = "source pod IP unknown: ipBlock peers cannot be evaluated for this row"
                row["config"], row["configWhy"] = declared.verdict(src, dst)
        if row["bucket"] == "drift" and row.get("config") in ("allowed", "denied", "oracle"):
            row["cause"] = "enforcement" if row["config"] == "denied" else "config"
        for k, v in it.items():        # carry tier / basis / notes through to the report
            row.setdefault(k, v)
        row["severity"] = SEV[row["bucket"]]
        if row.get("cause") == "enforcement":
            row["severity"] = "critical"
        rows.append(row)
    order = {"drift": 0, "unintended-deny": 1, "unknown": 2, "confirmed-safe": 3}
    rows.sort(key=lambda r: (order[r["bucket"]], r["subject"]))
    n = lambda b: sum(1 for r in rows if r["bucket"] == b)
    # THREE outcomes, because the world has three. An intent row with no usable
    # observation means the probe did not measure it: the gate cannot vouch for
    # posture it never saw, so that is COULD-NOT-RUN (1), never clean (0).
    # Proven 2026-10-04: with zero observations this gate used to exit 0.
    if n("drift"):
        gate = GATE_DRIFT
    elif n("unknown"):
        gate = GATE_ERROR
        sys.stderr.write("GATE: no usable observation for %d of %d declared intent rows. "
                         "The gate cannot vouch for posture it did not measure; exit 1 is "
                         "could-not-run, not clean.\n" % (n("unknown"), len(rows)))
    else:
        gate = GATE_CLEAN
    return {
        "schemaVersion": SCHEMA_VERSION, "schema": SCHEMA_ID, "probeVersion": PROBE_VERSION,
        "run": {"id": observed_doc.get("runId", "run"), "mode": "differential",
                "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "clusterIdentifier": observed_doc.get("clusterIdentifier", "unknown")},
        "namespaces": observed_doc.get("namespaces", []),
        "differential": rows,
        "summary": {"driftCount": n("drift"), "unintendedDenyCount": n("unintended-deny"),
                    "confirmedSafeCount": n("confirmed-safe"), "unknownCount": n("unknown"),
                    "enforcementDriftCount": sum(1 for r in rows if r.get("cause") == "enforcement"),
                    "gateExit": gate},
    }, gate


def main(argv):
    if len(argv) == 3 and not argv[1].startswith("-"):   # v0 positional form
        a = argparse.Namespace(observed=argv[1], intent=argv[2], declared=None, targets=None)
    else:
        ap = argparse.ArgumentParser()
        ap.add_argument("--observed", required=True); ap.add_argument("--intent", required=True)
        ap.add_argument("--declared"); ap.add_argument("--targets")
        a = ap.parse_args(argv[1:])
    try:
        observed = json.load(open(a.observed))
        intents = load_intents(a.intent)
        declared = Declared(json.load(open(a.declared))) if a.declared else None
        tdoc = json.load(open(a.targets)) if a.targets else {}
        targets, plabels = tdoc.get("targets"), tdoc.get("probeLabels")
    except Exception as e:
        sys.stderr.write("error: %s\n" % e)
        return GATE_ERROR
    report, gate = build(observed, intents, declared, targets, plabels)
    json.dump(report, sys.stdout, indent=2); sys.stdout.write("\n")
    return gate


if __name__ == "__main__":
    sys.exit(main(sys.argv))

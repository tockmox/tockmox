"""Report NetworkPolicies whose podSelector matches no rendered pod in their namespace.

Called by tools/check-policy-selects.sh with the directory it rendered into: <layer>.yaml is a render and
<layer>.ns the namespace that layer was rendered into (the layout tools/check-no-ghost-policies.sh uses), plus
the exception file as the second argument.

The ghost-policy gate asks "does anything live in the namespace this policy guards". This asks the next
question down: "does anything this policy SELECTS exist". A policy whose podSelector matches no pod applies
cleanly, reports Synced, and protects nothing; an egress allow that selects nothing strands the pod it was
written for, and a default-deny exemption that selects nothing fails open. Both read as protection.

What counts as a rendered pod: the pod template of every Deployment, StatefulSet, DaemonSet, ReplicaSet, Job
and CronJob, a bare Pod, and, because an operator makes them from a resource rather than a template, the
instance pods of a CloudNativePG Cluster (cnpg.io/cluster, cnpg.io/podRole: instance). Anything else a policy
may select (pods an operator makes, pods a site deploys) is an EXCEPTION, listed by namespace and policy name
with the reason, in tools/policy-selects-exceptions.txt. An exception that no longer matches a policy is itself
a failure, so the list cannot rot into a blanket.

Documents PyYAML refuses (the CRD renders carry YAML 1.1 constructs it will not read) are skipped one by one:
neither a NetworkPolicy nor a workload is among them, and the count of skipped documents is printed.
"""
import glob
import os
import sys

import yaml

POD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}


def pod_labels(doc):
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind in POD_KINDS:
        return [((spec.get("template") or {}).get("metadata") or {}).get("labels") or {}]
    if kind == "CronJob":
        jt = ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}
        return [(jt.get("metadata") or {}).get("labels") or {}]
    if kind == "Pod":
        return [(doc.get("metadata") or {}).get("labels") or {}]
    if kind == "Cluster" and str(doc.get("apiVersion", "")).startswith("postgresql.cnpg.io/"):
        name = doc["metadata"]["name"]
        return [{"cnpg.io/cluster": name, "cnpg.io/podRole": "instance", "cnpg.io/instanceRole": "primary",
                 "role": "primary"},
                {"cnpg.io/cluster": name, "cnpg.io/podRole": "instance", "cnpg.io/instanceRole": "replica",
                 "role": "replica"}]
    api = str(doc.get("apiVersion", ""))
    if api.startswith("monitoring.coreos.com/") and kind in ("Prometheus", "Alertmanager"):
        # prometheus-operator labels the pods it makes with the CR's kind and name
        name = doc["metadata"]["name"]
        lower = kind.lower()
        return [{"app.kubernetes.io/name": lower, "app.kubernetes.io/managed-by": "prometheus-operator",
                 "app.kubernetes.io/instance": name, lower: name}]
    return []


def matches(selector, labels):
    selector = selector or {}
    for k, v in (selector.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in selector.get("matchExpressions") or []:
        k, op, vals = e.get("key"), e.get("operator"), e.get("values") or []
        if op == "In" and labels.get(k) not in vals:
            return False
        if op == "NotIn" and k in labels and labels[k] in vals:
            return False
        if op == "Exists" and k not in labels:
            return False
        if op == "DoesNotExist" and k in labels:
            return False
    return True


def load_exceptions(path):
    out = {}
    if not path or not os.path.exists(path):
        return out
    with open(path) as fh:
        for n, line in enumerate(fh, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split(None, 2)
            if len(parts) < 3:
                sys.exit(f"{path}:{n}: want `<namespace> <policy> <reason>`, got {line!r}")
            out[(parts[0], parts[1])] = parts[2]
    return out


def main(work, exceptions_path, used_out=None):
    pods = {}            # ns -> [labels]
    policies = []        # (ns, name, selector, source)
    skipped = 0
    for path in sorted(glob.glob(os.path.join(work, "*.yaml"))):
        with open(path[:-5] + ".ns") as fh:
            release_ns = fh.read().strip()
        with open(path) as fh:
            body = fh.read()
        for chunk in body.split("\n---"):
            try:
                doc = yaml.safe_load(chunk)
            except yaml.YAMLError:
                skipped += 1
                continue
            if not isinstance(doc, dict) or "kind" not in doc:
                continue
            ns = (doc.get("metadata") or {}).get("namespace") or release_ns
            if doc["kind"] == "NetworkPolicy":
                policies.append((ns, doc["metadata"]["name"], (doc.get("spec") or {}).get("podSelector"),
                                 os.path.basename(path)))
            for labels in pod_labels(doc):
                pods.setdefault(ns, []).append(labels)

    exceptions = load_exceptions(exceptions_path)
    used = set()
    bad = []
    checked = 0
    for ns, name, sel, src in policies:
        checked += 1
        if any(matches(sel, labels) for labels in pods.get(ns, [])):
            continue
        if (ns, name) in exceptions:
            used.add((ns, name))
            continue
        bad.append(f"  SELECTS NOTHING  {ns}/{name}  ({src})  podSelector {sel}")
    print(f"  {checked} NetworkPolicies, {sum(len(v) for v in pods.values())} pod templates, "
          f"{len(used)} excepted, {skipped} unparseable document(s) skipped")
    for line in bad:
        print(line)
    if used_out:
        with open(used_out, "a") as fh:
            for ns, name in sorted(used):
                fh.write(f"{ns} {name}\n")
    return 1 if bad else 0


def stale(exceptions_path, used_files):
    """An exception no pass needed: its policy selects a rendered pod now, or it no longer renders."""
    used = set()
    for f in used_files:
        if os.path.exists(f):
            with open(f) as fh:
                used |= {tuple(line.split()) for line in fh if line.strip()}
    gone = [k for k in load_exceptions(exceptions_path) if k not in used]
    for ns, name in gone:
        print(f"  STALE EXCEPTION  {ns} {name}: no pass needed it (it selects a rendered pod now, or no such policy renders)")
    return 1 if gone else 0


if __name__ == "__main__":
    if sys.argv[1] == "--stale":
        sys.exit(stale(sys.argv[2], sys.argv[3:]))
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None, sys.argv[3] if len(sys.argv) > 3 else None))

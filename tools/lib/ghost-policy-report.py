#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Report namespaces whose NetworkPolicies guard no shipped workload.

Called by tools/check-no-ghost-policies.sh with one argument: a directory of
rendered manifests, where <layer>.yaml is the render and <layer>.ns holds the
release namespace that layer was rendered into.

Exits 1 if any namespace holds NetworkPolicies and no workload.

Deliberately parses with regex rather than PyYAML: the CRD render contains
YAML 1.1 constructs PyYAML refuses (a bare `=` key), and a validation tool
that cannot read the thing it validates is worse than no tool. Only three
fields are needed and they are all top-level.
"""
import collections
import glob
import os
import re
import sys

# Cluster-scoped kinds cannot count as a namespace's tenant.
CLUSTER_SCOPED = {
    "Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition",
    "PriorityClass", "StorageClass", "ValidatingAdmissionPolicy",
    "ValidatingAdmissionPolicyBinding", "ValidatingWebhookConfiguration",
    "MutatingWebhookConfiguration", "APIService", "IngressClass",
    "ClusterIssuer", "CSIDriver", "RuntimeClass", "PodSecurityPolicy",
    "ClusterRoleBindingList", "IPAddressPool", "L2Advertisement",
}

# Objects that describe policy or wiring rather than a running workload. A
# namespace holding only these is still empty in the sense that matters.
NON_TENANT = {"NetworkPolicy"}


def main(work: str) -> int:
    guarded = collections.defaultdict(list)
    tenants = collections.defaultdict(collections.Counter)

    for path in sorted(glob.glob(os.path.join(work, "*.yaml"))):
        with open(path[:-5] + ".ns") as fh:
            release_ns = fh.read().strip()
        with open(path) as fh:
            body = fh.read()
        for chunk in re.split(r"(?m)^---\s*$", body):
            kind_m = re.search(r"(?m)^kind:\s*(\S+)", chunk)
            if not kind_m:
                continue
            kind = kind_m.group(1)
            if kind in CLUSTER_SCOPED:
                continue
            ns_m = re.search(r'(?m)^  namespace:\s*"?([^"\s]+)"?', chunk)
            ns = ns_m.group(1) if ns_m else release_ns
            name_m = re.search(r"(?m)^  name:\s*(\S+)", chunk)
            if kind in NON_TENANT:
                guarded[ns].append(name_m.group(1) if name_m else "?")
            else:
                tenants[ns][kind] += 1

    if not guarded:
        print("  no NetworkPolicies rendered at all, which is itself suspicious")
        return 1

    width = max(len(n) for n in guarded)
    ghosts = []
    print(f"  {'namespace'.ljust(width)}  netpols  tenants  verdict")
    for ns in sorted(guarded):
        total = sum(tenants[ns].values())
        ok = total > 0
        if not ok:
            ghosts.append(ns)
        print(f"  {ns.ljust(width)}  {len(guarded[ns]):>7}  {total:>7}  "
              f"{'ok' if ok else 'GUARDS NOTHING'}")

    for ns in ghosts:
        print(f"::error::NetworkPolicies in {ns} guard no shipped workload: "
              + ", ".join(sorted(guarded[ns])))
    return 1 if ghosts else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: ghost-policy-report.py <render-dir>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))

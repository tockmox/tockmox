#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Does the throwaway VM this run is about to create FIT on the substrate?

Reads four JSON documents that provision/profiles/capacity-preflight.sh fetched
with kubectl, plus the size of the VM the run declared, and prints one verdict
line per failed check. Creates nothing and reads nothing itself.

    capacity-check.py --disk 250Gi --memory 24Gi --stop-percent 85 --replicas 1 \\
        --vm NAME --longhorn F --nodes F --pods F --vms F

EXIT CODE, and it is the contract with the shell:

    0   fits. One `OK:` line per check, nothing else.
    4   BLOCKED. One `BLOCKED: <check>: <numbers>` line per check that failed.
    5   INFRA_ERROR. A source could not be READ or made no sense. Never a pass:
        a capacity rule that passes because it could not see anything is the
        failure this file exists to refuse.
    2   a bad argument (a malformed size, a percentage outside 1..100).

THE CHECKS.

  storage   Longhorn places a replica on ONE disk, so N bytes fit only when some
            single schedulable disk has headroom >= N, where
            headroom = floor(stop% * storageMaximum) - storageScheduled.
            The node-level sum is reported and never decides: two half-full
            disks do not make one disk that holds a 250Gi replica. With
            --replicas R, R distinct disks must each fit it.
  memory    Per node: allocatable memory minus the memory REQUESTS of every
            non-terminated pod on it, which is the figure the scheduler uses and
            needs no metrics API. A VM's virt-launcher pod requests the VM's
            memory, so this is what decides whether a new VM lands.
  harness   Another VM carrying the harness label in the run's own namespace is
            a stray (a crashed run's leftover still holds its disk and memory,
            and two runs compete for the same capacity). The run's own VM name
            is not a stray. --allow-other-vms turns the check off.

WHAT MAKES A READ UNREADABLE (INFRA_ERROR), because each is a way a rule goes
quietly green:

  - a document that is not JSON, or has no `items` list;
  - no Longhorn disk at all, or none with a storageMaximum;
  - no node;
  - every pod memory request summing to ZERO. A node always runs pods that
    request memory, so zero means the pod list was empty or filtered for this
    identity. Some API front ends answer an all-namespace list a credential may
    not make with an EMPTY list rather than Forbidden, and an empty list would
    read as "nothing is using any memory".
"""

import argparse
import json
import re
import sys

GIB = 1024 ** 3

_QTY = re.compile(r"^([0-9]+(?:\.[0-9]+)?)(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|k|K|m)?$")
_MULT = {"": 1, "m": 0.001, "k": 1000, "K": 1000, "M": 1000 ** 2, "G": 1000 ** 3,
         "T": 1000 ** 4, "P": 1000 ** 5, "E": 1000 ** 6, "Ki": 1024, "Mi": 1024 ** 2,
         "Gi": 1024 ** 3, "Ti": 1024 ** 4, "Pi": 1024 ** 5, "Ei": 1024 ** 6}


class Infra(Exception):
    pass


def qty(value):
    """A Kubernetes quantity ("250Gi", "24Gi", "32768Mi", "8589934592") in bytes."""
    m = _QTY.match(str(value).strip())
    if not m:
        raise ValueError("not a quantity: %r" % (value,))
    return int(float(m.group(1)) * _MULT[m.group(2) or ""])


def gib(b):
    return round(b / GIB, 1)


def load(path, what):
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        raise Infra("%s: unreadable (%s)" % (what, str(e)[:120]))
    if not isinstance(doc, dict) or not isinstance(doc.get("items"), list):
        raise Infra("%s: not a list document" % what)
    return doc["items"]


def disks_of(items):
    rows = []
    for n in items:
        spec = n.get("spec") or {}
        status = n.get("status") or {}
        node_ok = spec.get("allowScheduling", True) is not False
        node_conds = {c.get("type"): c.get("status") for c in status.get("conditions") or []}
        node_ok = node_ok and node_conds.get("Ready", "True") == "True" \
            and node_conds.get("Schedulable", "True") == "True"
        sdisks = spec.get("disks") or {}
        for name, st in sorted((status.get("diskStatus") or {}).items()):
            mx = int(st.get("storageMaximum") or 0)
            if mx <= 0:
                continue
            conds = {c.get("type"): c.get("status") for c in st.get("conditions") or []}
            ok = node_ok and sdisks.get(name, {}).get("allowScheduling", False) is True \
                and conds.get("Ready") == "True" and conds.get("Schedulable") == "True"
            rows.append({"node": (n.get("metadata") or {}).get("name", "?"), "disk": name,
                         "max": mx, "scheduled": int(st.get("storageScheduled") or 0), "ok": ok})
    return rows


def storage_check(disks, need, pct, replicas):
    for d in disks:
        d["stop"] = d["max"] * pct // 100
        d["headroom"] = d["stop"] - d["scheduled"]
    fit = [d for d in disks if d["ok"] and d["headroom"] >= need]
    best = max((d["headroom"] for d in disks if d["ok"]), default=0)
    node_sched = sum(d["scheduled"] for d in disks)
    node_stop = sum(d["stop"] for d in disks)
    nums = ("need %s GiB x %d replica(s) on one disk each, best disk headroom %s GiB under its %d%% stop line, "
            "%d of %d disk(s) fit" % (gib(need), replicas, gib(best), pct, len(fit), len(disks)))
    if len(fit) < replicas and node_sched + need <= node_stop:
        nums += "; the node-level sum would have passed, which is the wrong rule"
    return len(fit) >= replicas, nums


def memory_check(nodes, pods, need):
    req = {}
    for p in pods:
        node = (p.get("spec") or {}).get("nodeName")
        if not node or (p.get("status") or {}).get("phase") in ("Succeeded", "Failed"):
            continue
        for c in (p.get("spec") or {}).get("containers") or []:
            m = ((c.get("resources") or {}).get("requests") or {}).get("memory")
            if m is not None:
                try:
                    req[node] = req.get(node, 0) + qty(m)
                except ValueError:
                    raise Infra("pods: a memory request that is not a quantity: %r" % (m,))
    if sum(req.values()) == 0:
        raise Infra("pods: no pod memory request on any node (an empty or filtered pod list reads as an idle rig)")
    avail = []
    for n in nodes:
        name = (n.get("metadata") or {}).get("name", "?")
        conds = {c.get("type"): c.get("status") for c in (n.get("status") or {}).get("conditions") or []}
        if (n.get("spec") or {}).get("unschedulable") or conds.get("Ready") != "True":
            continue
        a = ((n.get("status") or {}).get("allocatable") or {}).get("memory")
        if a is None:
            raise Infra("nodes: %s has no allocatable memory" % name)
        avail.append((qty(a) - req.get(name, 0), name))
    best = max(avail, default=(0, None))
    return best[0] >= need, ("need %s GiB on one node, best node has %s GiB available "
                             "(allocatable minus pod memory requests), %d schedulable node(s)"
                             % (gib(need), gib(best[0]), len(avail)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--disk", required=True)
    ap.add_argument("--memory", required=True)
    ap.add_argument("--stop-percent", default="85")
    ap.add_argument("--replicas", default="1")
    ap.add_argument("--vm", required=True)
    ap.add_argument("--allow-other-vms", action="store_true")
    for k in ("longhorn", "nodes", "pods", "vms"):
        ap.add_argument("--" + k, required=True)
    a = ap.parse_args()
    try:
        need_disk, need_mem = qty(a.disk), qty(a.memory)
        pct, replicas = int(a.stop_percent), int(a.replicas)
    except ValueError as e:
        print("REFUSING: %s" % e, file=sys.stderr)
        return 2
    if not 1 <= pct <= 100 or replicas < 1:
        print("REFUSING: stop percent must be 1..100 and replicas at least 1, got %s and %s"
              % (a.stop_percent, a.replicas), file=sys.stderr)
        return 2
    try:
        disks = disks_of(load(a.longhorn, "longhorn nodes"))
        if not disks:
            raise Infra("longhorn nodes: no disk with a storageMaximum")
        nodes = load(a.nodes, "nodes")
        if not nodes:
            raise Infra("nodes: none")
        pods = load(a.pods, "pods")
        vms = load(a.vms, "harness VMs")
        s_ok, s_nums = storage_check(disks, need_disk, pct, replicas)
        m_ok, m_nums = memory_check(nodes, pods, need_mem)
    except Infra as e:
        print("INFRA_ERROR: capacity-source: %s" % e)
        return 5
    strays = sorted((v.get("metadata") or {}).get("name", "?") for v in vms
                    if (v.get("metadata") or {}).get("name") != a.vm)
    h_ok = a.allow_other_vms or not strays
    rows = [("storage", s_ok, s_nums), ("memory", m_ok, m_nums),
            ("harness", h_ok, "other harness VM(s) in the namespace: %s" % (", ".join(strays) or "none"))]
    bad = [r for r in rows if not r[1]]
    for name, ok, nums in rows:
        print(("OK: %s: %s" if ok else "BLOCKED: %s: %s") % (name, nums))
    return 4 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

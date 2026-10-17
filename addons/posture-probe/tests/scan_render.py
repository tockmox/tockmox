#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Assertions over a RENDERED posture-probe add-on. Used by tools/check-posture-probe.sh.

usage: scan_render.py RENDER.yaml RELEASE_NAMESPACE
Prints one line per finding and exits 1 if there is any, 0 otherwise.
"""
import json, os, sys
import yaml

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from posture_probe import blackbox  # noqa: E402

READ = {"get", "list", "watch"}
ORACLES = {"selfsubjectaccessreviews", "selfsubjectrulesreviews"}
# Kinds whose read is still too much for this identity: values, exec, logs.
NEVER_RESOURCES = {"secrets", "pods/exec", "pods/attach", "pods/log", "pods/portforward", "pods/proxy",
                   "nodes/proxy", "services/proxy", "serviceaccounts/token", "tokenreviews",
                   "subjectaccessreviews", "certificatesigningrequests"}
CLUSTER_READS = {"namespaces"}
NS_READS = {"pods", "networkpolicies"}
POD_KINDS = {"Deployment", "CronJob", "Job", "Pod", "StatefulSet", "DaemonSet"}


def pod_spec(o):
    s = o.get("spec") or {}
    if o["kind"] == "CronJob":
        s = s["jobTemplate"]["spec"]
    if o["kind"] != "Pod":
        s = s["template"]["spec"]
    return s


def scan(docs, rel_ns):
    errs = []
    roles = {}
    for o in docs:
        k, md = o["kind"], o["metadata"]
        where = "%s %s/%s" % (k, md.get("namespace", "-"), md["name"])
        if k in ("Role", "ClusterRole"):
            roles[(k, md.get("namespace"), md["name"])] = o
            if o.get("aggregationRule"):
                errs.append("%s aggregates other roles: its verb set is no longer readable here" % where)
            for r in o.get("rules") or []:
                verbs, res, groups = set(r.get("verbs") or []), set(r.get("resources") or []), set(r.get("apiGroups") or [])
                if r.get("nonResourceURLs"):
                    errs.append("%s grants nonResourceURLs" % where)
                if "*" in verbs | res | groups:
                    errs.append("%s uses a wildcard (%s)" % (where, sorted(verbs | res | groups)))
                if r.get("resourceNames"):
                    errs.append("%s uses resourceNames, which this role never needs" % where)
                bad_res = res & NEVER_RESOURCES
                if bad_res:
                    errs.append("%s names %s, which the probe must never touch" % (where, sorted(bad_res)))
                subres = [x for x in res if "/" in x]
                if subres:
                    errs.append("%s grants a subresource %s" % (where, sorted(subres)))
                if res and res <= ORACLES and groups <= {"authorization.k8s.io"}:
                    if verbs != {"create"}:
                        errs.append("%s grants %s on the review oracles; only create is a read there" % (where, sorted(verbs)))
                    continue
                writes = verbs - READ
                if writes:
                    errs.append("%s holds WRITE verb(s) %s on %s" % (where, sorted(writes), sorted(res)))
                allowed = CLUSTER_READS if k == "ClusterRole" else NS_READS
                extra = res - allowed
                if extra:
                    errs.append("%s reads %s, outside the declared read set %s" % (where, sorted(extra), sorted(allowed)))
        if k == "NetworkPolicy":
            if md.get("namespace") != rel_ns:
                errs.append("%s sits in a MEASURED namespace: it would change what the probe measures" % where)
            sp = o["spec"]
            if sp.get("ingress"):
                errs.append("%s admits ingress; nothing should reach the add-on" % where)
            for rule in sp.get("egress") or []:
                peers, ports = rule.get("to") or [], rule.get("ports") or []
                if not peers or not ports:
                    errs.append("%s has an egress rule with no peer or no port (allows too much)" % where)
                for p in peers:
                    ib = p.get("ipBlock")
                    if ib and (ib["cidr"].endswith("/0") or int(ib["cidr"].split("/")[1]) < 8):
                        errs.append("%s allows egress to %s" % (where, ib["cidr"]))
                    if p.get("namespaceSelector") is not None:
                        ok = (p["namespaceSelector"].get("matchLabels") == {"kubernetes.io/metadata.name": "kube-system"}
                              and {x.get("port") for x in ports} == {53})
                        if not ok:
                            errs.append("%s allows egress to a namespace other than DNS in kube-system" % where)
        if k in POD_KINDS:
            spec = pod_spec(o)
            if spec.get("hostNetwork") or spec.get("hostPID") or spec.get("hostIPC"):
                errs.append("%s shares a host namespace" % where)
            psc = spec.get("securityContext") or {}
            if psc.get("runAsNonRoot") is not True:
                errs.append("%s does not set runAsNonRoot" % where)
            for c in spec.get("containers", []) + spec.get("initContainers", []):
                sc = c.get("securityContext") or {}
                if sc.get("allowPrivilegeEscalation") is not False or sc.get("readOnlyRootFilesystem") is not True \
                        or "ALL" not in ((sc.get("capabilities") or {}).get("drop") or []) or sc.get("privileged"):
                    errs.append("%s container %s is not restricted (escalation, read-only root, drop ALL)" % (where, c["name"]))
                if not ((c.get("resources") or {}).get("limits") or {}).get("memory"):
                    errs.append("%s container %s has no memory limit" % (where, c["name"]))
            comp = (o["metadata"].get("labels") or {}).get("app.kubernetes.io/component")
            if comp == "collector":
                c = spec["containers"][0]
                env = {e["name"]: e.get("value") for e in c.get("env", [])}
                if env.get("PROBE_SETTLE") != "/etc/probe/settle.json":
                    errs.append("%s: a collector without PROBE_SETTLE measures inside the window before its pod is policed" % where)
                eps = [x for x in docs if x["kind"] == "ConfigMap" and x["metadata"]["name"] == "posture-probe-endpoints"
                       and x["metadata"].get("namespace") == md.get("namespace")]
                st = json.loads(eps[0]["data"].get("settle.json", "{}")).get(md.get("namespace")) if eps else None
                deadline = o["spec"]["jobTemplate"]["spec"].get("activeDeadlineSeconds", 0)
                if not st or int(st.get("stableRounds", 0)) < 2:
                    errs.append("%s: no settle config with stableRounds >= 2 for its namespace" % where)
                elif float(st["maxSeconds"]) + 30 > deadline:
                    errs.append("%s: settle.maxSeconds + 30 exceeds the Job deadline %s" % (where, deadline))
                if c.get("terminationMessagePolicy") != "File":
                    errs.append("%s: a collector must use terminationMessagePolicy File (FallbackToLogsOnError puts output in logs)" % where)
                if md["name"] == "posture-probe-collect" and spec.get("serviceAccountName"):
                    errs.append("%s: a reach collector must run as the namespace's default account, not %s"
                                % (where, spec["serviceAccountName"]))
            if comp == "differential" and spec.get("serviceAccountName") != "posture-probe":
                errs.append("%s: the differential must run as posture-probe" % where)
        if k in ("RoleBinding", "ClusterRoleBinding"):
            ref = o["roleRef"]
            if not any(r[0] == ref["kind"] and r[2] == ref["name"] for r in roles) and \
                    not any(x["kind"] == ref["kind"] and x["metadata"]["name"] == ref["name"] for x in docs):
                errs.append("%s binds %s %s, which this chart does not render (a built-in role is not a contract we can read)"
                            % (where, ref["kind"], ref["name"]))
            for s in o.get("subjects") or []:
                if (s.get("kind"), s.get("name"), s.get("namespace")) != ("ServiceAccount", "posture-probe", rel_ns):
                    errs.append("%s binds %s %s, not the probe's own account" % (where, s.get("kind"), s.get("name")))
    # A claim only a CronJob mounts is Pending until the first scheduled run on a
    # WaitForFirstConsumer StorageClass (k3s local-path), so `helm --wait` fails the
    # release and Argo CD never reaches Healthy. Something that runs at install
    # (a Job, never a CronJob) has to mount every claim.
    for pvc in (o for o in docs if o["kind"] == "PersistentVolumeClaim"):
        name, ns = pvc["metadata"]["name"], pvc["metadata"].get("namespace")
        binders = [o for o in docs if o["kind"] in ("Job", "Deployment", "StatefulSet", "Pod")
                   and o["metadata"].get("namespace") == ns
                   and any((v.get("persistentVolumeClaim") or {}).get("claimName") == name
                           for v in pod_spec(o).get("volumes") or [])]
        if not binders:
            errs.append("PersistentVolumeClaim %s/%s has no consumer that runs at install: on a WaitForFirstConsumer "
                        "StorageClass it stays Pending until the first scheduled run, so helm --wait fails" % (ns, name))
    # Intent rows the collectors can actually answer.
    cms = [o for o in docs if o["kind"] == "ConfigMap" and o["metadata"]["name"] == "posture-probe-config"]
    if not cms:
        errs.append("no posture-probe-config ConfigMap rendered")
    else:
        intents = json.loads(cms[0]["data"]["intent.json"])["intents"]
        asked = set()
        for verb, group, res, ns in blackbox.ACCESS_CHECKS:
            asked.add((verb, (group + "/" if group else "") + res, ns))
        for r in intents:
            if r["dimension"].startswith("rbac:"):
                verb, rest = r["dimension"][5:].split(" ", 1)
                res, scope = rest.split(" @")
                vns = r["subject"].split(":")[0]
                key = (verb, res, "{ns}" if scope == vns else ("" if scope == "*" else scope))
                if key not in asked:
                    errs.append("intent row %s / %s asks a question the collector never asks the oracle; it would read unknown forever"
                                % (r["subject"], r["dimension"]))
    kinds = sorted({o["kind"] for o in docs})
    return errs, kinds


def main():
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
    errs, kinds = scan(docs, sys.argv[2])
    for e in errs:
        print("  FAIL " + e)
    if not errs:
        print("  ok %d objects (%s): role read-only, policy confined to the add-on namespace, pods restricted, intent answerable"
              % (len(docs), ", ".join(kinds)))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())

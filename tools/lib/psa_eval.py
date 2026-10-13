#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Evaluate rendered pod templates against the Pod Security Standards.

Called by tools/check-pod-security.sh. Arguments:

    psa_eval.py WORKDIR [--table] [--json]   evaluate rendered manifests
    psa_eval.py --selftest                   check the rules themselves

WORKDIR holds <pass>__<layer>.yaml (a `helm template` render) and
<pass>__<layer>.ns (the release namespace that layer was rendered into), plus
namespaces__<pass>.yaml (the policy layer's render, which carries the
Namespace objects and therefore the pod-security labels under test).

WHAT IS IMPLEMENTED. The Pod Security Standards as published at
https://kubernetes.io/docs/concepts/security/pod-security-standards/ (v1.x, the
`latest` policy version at the time of writing, Kubernetes 1.34). Each rule
below cites the section of that page it comes from. The reference
implementation is k8s.io/pod-security-admission/policy; where the docs page and
the code differ on a detail, this file follows the docs page and says so.

WHAT IS NOT. Three things this evaluator cannot see, all stated in the report
it prints:

  - Pods that an OPERATOR creates from a custom resource (a CNPG Cluster, a
    Longhorn instance manager, a MetalLB speaker's children). The custom
    resource is listed, the pods it will produce are not evaluated.
  - Mutating admission that runs before Pod Security (Kyverno mutate rules, a
    service mesh injecting a sidecar). Pod Security sees the pod AFTER those.
  - Windows-only fields beyond hostProcess (this repo ships no Windows pods).

Parses with PyYAML. The CRD layer is skipped: it renders YAML 1.1 constructs
PyYAML refuses (see ghost-policy-report.py) and ships no pods.
"""
import collections
import glob
import json
import os
import sys

try:
    import yaml
except ImportError:  # the wrapper turns this into exit 2 (skipped)
    print("psa_eval: PyYAML missing", file=sys.stderr)
    sys.exit(2)

LEVELS = ["privileged", "baseline", "restricted"]
RANK = {n: i for i, n in enumerate(LEVELS)}

# Kinds that embed a pod template, and where it lives.
POD_KINDS = {
    "Pod": lambda o: o.get("spec"),
    "Deployment": lambda o: (o.get("spec") or {}).get("template", {}).get("spec"),
    "StatefulSet": lambda o: (o.get("spec") or {}).get("template", {}).get("spec"),
    "DaemonSet": lambda o: (o.get("spec") or {}).get("template", {}).get("spec"),
    "ReplicaSet": lambda o: (o.get("spec") or {}).get("template", {}).get("spec"),
    "Job": lambda o: (o.get("spec") or {}).get("template", {}).get("spec"),
    "CronJob": lambda o: ((o.get("spec") or {}).get("jobTemplate", {}).get("spec", {})
                          .get("template", {}).get("spec")),
}
# Custom resources whose controller creates pods this evaluator cannot see.
OPERATOR_KINDS = {"Cluster", "Pooler", "Rollout", "Prometheus", "Alertmanager",
                  "ThanosRuler", "Kustomization", "HelmChart"}
OPERATOR_GROUPS = ("postgresql.cnpg.io", "monitoring.coreos.com", "longhorn.io",
                   "argoproj.io", "helm.cattle.io")

# ---- baseline tables -------------------------------------------------------
# "Capabilities" (Baseline): allowed additions.
BASELINE_CAPS = {"AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL",
                 "MKNOD", "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP",
                 "SETUID", "SYS_CHROOT"}
# "SELinux" (Baseline): allowed spec.securityContext.seLinuxOptions.type values.
SELINUX_TYPES = {"", "container_t", "container_init_t", "container_kvm_t",
                 "container_engine_t"}
# "Sysctls" (Baseline): the safe set that may be set.
SAFE_SYSCTLS = {"kernel.shm_rmid_forced", "net.ipv4.ip_local_port_range",
                "net.ipv4.ip_unprivileged_port_start", "net.ipv4.tcp_syncookies",
                "net.ipv4.ping_group_range", "net.ipv4.ip_local_reserved_ports",
                "net.ipv4.tcp_keepalive_time", "net.ipv4.tcp_fin_timeout",
                "net.ipv4.tcp_keepalive_intvl", "net.ipv4.tcp_keepalive_probes"}
# "Volume Types" (Restricted): the only volume sources allowed.
RESTRICTED_VOLUMES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral",
                      "persistentVolumeClaim", "projected", "secret"}
APPARMOR_ANN = "container.apparmor.security.beta.kubernetes.io/"


def containers(spec):
    """(kind, container) for containers, initContainers, ephemeralContainers."""
    for key, label in (("containers", "container"),
                       ("initContainers", "initContainer"),
                       ("ephemeralContainers", "ephemeralContainer")):
        for c in spec.get(key) or []:
            yield label, c


def sc(obj):
    return (obj or {}).get("securityContext") or {}


def evaluate_spec(spec, annotations=None):
    """Return (baseline_violations, restricted_extra_violations) for a PodSpec.

    Restricted includes Baseline, so a pod's level is: restricted if both lists
    are empty, baseline if only the first is, privileged otherwise.
    """
    annotations = annotations or {}
    base, extra = [], []
    psc = spec.get("securityContext") or {}
    cs = list(containers(spec))

    # Baseline: "Host Namespaces"
    for f in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(f):
            base.append(f"{f}=true (Host Namespaces)")
    # Baseline: "HostProcess" (Windows)
    if (psc.get("windowsOptions") or {}).get("hostProcess"):
        base.append("windowsOptions.hostProcess=true (HostProcess)")
    # Baseline: "HostPath Volumes"
    for v in spec.get("volumes") or []:
        if "hostPath" in v:
            base.append(f"volume {v.get('name')}: hostPath {v['hostPath'].get('path')} (HostPath Volumes)")
    # Baseline: "Sysctls"
    for s in psc.get("sysctls") or []:
        if s.get("name") not in SAFE_SYSCTLS:
            base.append(f"sysctl {s.get('name')} not in the safe set (Sysctls)")
    # Baseline: "SELinux" (pod level)
    def selinux(where, opts):
        opts = opts or {}
        if opts.get("type", "") not in SELINUX_TYPES:
            base.append(f"{where}: seLinuxOptions.type={opts['type']} (SELinux)")
        for k in ("user", "role"):
            if opts.get(k):
                base.append(f"{where}: seLinuxOptions.{k}={opts[k]} (SELinux)")
    selinux("pod", psc.get("seLinuxOptions"))
    # Baseline: "AppArmor"
    def apparmor_ok(t):
        return t in ("RuntimeDefault", "Localhost")
    for k, val in annotations.items():
        if k.startswith(APPARMOR_ANN) and not (val == "runtime/default" or val.startswith("localhost/")):
            base.append(f"annotation {k}={val} (AppArmor)")
    if psc.get("appArmorProfile") and not apparmor_ok(psc["appArmorProfile"].get("type")):
        base.append(f"pod: appArmorProfile.type={psc['appArmorProfile'].get('type')} (AppArmor)")
    # Baseline: "Seccomp" (pod level)
    st = (psc.get("seccompProfile") or {}).get("type")
    if st == "Unconfined":
        base.append("pod: seccompProfile.type=Unconfined (Seccomp)")

    for label, c in cs:
        n = f"{label} {c.get('name')}"
        csc = sc(c)
        # Baseline: "Privileged Containers"
        if csc.get("privileged"):
            base.append(f"{n}: privileged=true (Privileged Containers)")
        # Baseline: "Capabilities"
        for cap in (csc.get("capabilities") or {}).get("add") or []:
            if cap not in BASELINE_CAPS:
                base.append(f"{n}: capabilities.add {cap} (Capabilities)")
        # Baseline: "Host Ports"
        for p in c.get("ports") or []:
            if p.get("hostPort"):
                base.append(f"{n}: hostPort {p['hostPort']} (Host Ports)")
        # Baseline: "/proc Mount Type"
        if csc.get("procMount") not in (None, "Default"):
            base.append(f"{n}: procMount={csc['procMount']} (/proc Mount Type)")
        # Baseline: SELinux, AppArmor, Seccomp (container level)
        selinux(n, csc.get("seLinuxOptions"))
        if csc.get("appArmorProfile") and not apparmor_ok(csc["appArmorProfile"].get("type")):
            base.append(f"{n}: appArmorProfile.type={csc['appArmorProfile'].get('type')} (AppArmor)")
        if (csc.get("seccompProfile") or {}).get("type") == "Unconfined":
            base.append(f"{n}: seccompProfile.type=Unconfined (Seccomp)")

    # ---- Restricted, on top of Baseline ------------------------------------
    # "Volume Types"
    for v in spec.get("volumes") or []:
        srcs = [k for k in v if k != "name"]
        bad = [k for k in srcs if k not in RESTRICTED_VOLUMES]
        if bad and "hostPath" not in bad:  # hostPath is already a baseline hit
            extra.append(f"volume {v.get('name')}: type {','.join(bad)} (Volume Types)")
    for label, c in cs:
        n = f"{label} {c.get('name')}"
        csc = sc(c)
        # "Privilege Escalation": must be explicitly false.
        if csc.get("allowPrivilegeEscalation") is not False:
            extra.append(f"{n}: allowPrivilegeEscalation not false (Privilege Escalation)")
        # "Running as Non-root": container value wins, else pod value.
        rnr = csc.get("runAsNonRoot", psc.get("runAsNonRoot"))
        if rnr is not True:
            extra.append(f"{n}: runAsNonRoot not true (Running as Non-root)")
        # "Running as Non-root user": uid 0 forbidden where set.
        if csc.get("runAsUser", psc.get("runAsUser")) == 0:
            extra.append(f"{n}: runAsUser=0 (Running as Non-root user)")
        # "Seccomp": RuntimeDefault or Localhost, container value wins.
        cst = (csc.get("seccompProfile") or {}).get("type", st)
        if cst not in ("RuntimeDefault", "Localhost"):
            extra.append(f"{n}: seccompProfile not RuntimeDefault/Localhost (Seccomp)")
        # "Capabilities": drop ALL; add only NET_BIND_SERVICE.
        caps = csc.get("capabilities") or {}
        if "ALL" not in (caps.get("drop") or []):
            extra.append(f"{n}: capabilities.drop lacks ALL (Capabilities)")
        for cap in caps.get("add") or []:
            if cap != "NET_BIND_SERVICE":
                extra.append(f"{n}: capabilities.add {cap} (Capabilities)")
    return base, extra


def level_of(base, extra):
    if base:
        return "privileged"
    if extra:
        return "baseline"
    return "restricted"


def load_docs(path):
    with open(path) as fh:
        return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]


def is_test_hook(meta):
    """`helm.sh/hook: test` objects run only on an explicit `helm test`, which
    the GitOps loop does not do (INFERRED for Argo CD: it does not sync helm test
    hooks). They are listed in the report and excluded from the measurement."""
    hooks = str((meta.get("annotations") or {}).get("helm.sh/hook", ""))
    return any(h.strip().startswith("test") for h in hooks.split(","))


def collect(work):
    """-> (pods, operators, namespace_labels, errors)

    pods: list of dicts {pass, layer, ns, kind, name, level, base, extra}
    """
    pods, operators, labels, errors = [], [], {}, []
    tests = []
    for path in sorted(glob.glob(os.path.join(work, "*__*.yaml"))):
        stem = os.path.basename(path)[:-5]
        pas, layer = stem.split("__", 1)
        if layer == "crds":
            continue
        try:
            docs = load_docs(path)
        except yaml.YAMLError as e:
            errors.append(f"{stem}: cannot parse render: {e}")
            continue
        if layer == "namespaces":
            for d in docs:
                if d.get("kind") == "Namespace":
                    labels.setdefault(pas, {})[d["metadata"]["name"]] = d["metadata"].get("labels") or {}
            continue
        with open(os.path.join(work, stem + ".ns")) as fh:
            rel_ns = fh.read().strip()
        for d in docs:
            kind = d.get("kind")
            meta = d.get("metadata") or {}
            ns = meta.get("namespace") or rel_ns
            if kind in POD_KINDS:
                if is_test_hook(meta):
                    tests.append(dict(pas=pas, layer=layer, ns=ns, kind=kind, name=meta.get("name", "?")))
                    continue
                spec = POD_KINDS[kind](d)
                if not spec:
                    errors.append(f"{stem}: {kind}/{meta.get('name')} has no pod spec")
                    continue
                if kind == "CronJob":
                    ann = (((d.get("spec") or {}).get("jobTemplate") or {}).get("spec", {})
                           .get("template", {}).get("metadata", {}) or {}).get("annotations") or {}
                elif kind == "Pod":
                    ann = meta.get("annotations") or {}
                else:
                    ann = ((d.get("spec") or {}).get("template", {}).get("metadata", {}) or {}).get("annotations") or {}
                b, e = evaluate_spec(spec, ann)
                pods.append(dict(pas=pas, layer=layer, ns=ns, kind=kind,
                                 name=meta.get("name", "?"), level=level_of(b, e),
                                 base=b, extra=e))
            elif kind in OPERATOR_KINDS and str(d.get("apiVersion", "")).split("/")[0] in OPERATOR_GROUPS:
                operators.append(dict(pas=pas, layer=layer, ns=ns, kind=kind,
                                      name=meta.get("name", "?"),
                                      group=d["apiVersion"].split("/")[0]))
    collect.tests = tests
    return pods, operators, labels, errors


def namespace_levels(pods):
    """namespace -> (measured level, [(kind/name, level, violations)])"""
    by = collections.defaultdict(list)
    for p in pods:
        by[p["ns"]].append(p)
    out = {}
    for ns, ps in by.items():
        lvl = min((p["level"] for p in ps), key=lambda x: RANK[x])
        out[ns] = (lvl, ps)
    return out


def report(work, table=True):
    pods, ops, labels, errors = collect(work)
    nl = namespace_levels(pods)
    if table:
        print(f"  {'namespace'.ljust(22)} pods  measured     enforce      warn/audit")
    fails = list(errors)
    # labels from the first pass that has them; all passes checked below
    for ns in sorted(set(nl) | {n for l in labels.values() for n in l}):
        measured = nl[ns][0] if ns in nl else "(no pods)"
        row = {}
        for pas, ls in labels.items():
            if ns in ls:
                lab = ls[ns]
                enf = lab.get("pod-security.kubernetes.io/enforce", "")
                wrn = lab.get("pod-security.kubernetes.io/warn", "")
                aud = lab.get("pod-security.kubernetes.io/audit", "")
                row[pas] = (enf, wrn, aud)
                # A namespace with no rendered pod cannot violate anything, so its cap is restricted.
                cap = RANK[measured] if ns in nl else RANK["restricted"]
                if enf and RANK.get(enf, 99) > cap:
                    fails.append(f"{ns} ({pas}): enforce={enf} is stricter than the measured "
                                 f"{measured}; pods in it would be refused")
                if enf not in ("", "privileged", "baseline", "restricted"):
                    fails.append(f"{ns} ({pas}): enforce={enf} is not a Pod Security level")
                # warn and audit must exist and never sit below enforce
                for nm, v in (("warn", wrn), ("audit", aud)):
                    if v != "restricted":
                        fails.append(f"{ns} ({pas}): {nm}={v or '(absent)'}; expected restricted everywhere")
        if table:
            enfs = sorted({r[0] or "(none)" for r in row.values()}) or ["(not created here)"]
            wa = sorted({f"{r[1]}/{r[2]}" for r in row.values()}) or ["-"]
            npods = len({(p['layer'], p['kind'], p['name']) for p in nl[ns][1]}) if ns in nl else 0
            print(f"  {ns.ljust(22)} {npods:>4}  {measured.ljust(12)} {','.join(enfs).ljust(12)} {','.join(wa)}")
    if table:
        print()
        for ns in sorted(nl):
            groups = collections.OrderedDict()
            for p in nl[ns][1]:
                if p["level"] == "restricted":
                    continue
                groups.setdefault((p["kind"], p["name"], p["layer"]), []).append(p)
            for (kind, name, layer), ps in groups.items():
                p = ps[0]
                vs = (p["base"] + p["extra"]) if p["level"] == "privileged" else p["extra"]
                print(f"  {ns}: {kind}/{name} passes {p['level']} only ({layer}; {'+'.join(sorted(x['pas'] for x in ps))})")
                for v in vs:
                    print(f"      - {v}")
        if collect.tests:
            print("\n  helm test hooks excluded from the measurement (run only on `helm test`):")
            for k in sorted({(t['ns'], t['kind'], t['name']) for t in collect.tests}):
                print(f"    {k[0]}: {k[1]}/{k[2]}")
        if ops:
            print("\n  Operator-created pods NOT evaluated (the custom resource is listed, its pods are not):")
            for k in sorted({(o['ns'], o['group'], o['kind'], o['name']) for o in ops}):
                print(f"    {k[0]}: {k[1]} {k[2]}/{k[3]}")
    if not pods:
        fails.append("no pod templates found at all: the render is empty, which is a broken gate")
    for f in fails:
        print(f"::error::{f}")
    return 1 if fails else 0


# ---------------------------------------------------------------------------
def selftest():
    """The rules themselves, on synthetic specs. Each case names the rule it
    must trip, so a rule that was deleted turns this red."""
    good_c = {"name": "a", "image": "x",
              "securityContext": {"allowPrivilegeEscalation": False, "runAsNonRoot": True,
                                  "capabilities": {"drop": ["ALL"]},
                                  "seccompProfile": {"type": "RuntimeDefault"}}}
    def spec(**kw):
        s = {"containers": [json.loads(json.dumps(good_c))]}
        s.update(kw)
        return s
    def with_c(**over):
        c = json.loads(json.dumps(good_c))
        c["securityContext"].update(over)
        return {"containers": [c]}
    cases = [
        ("compliant pod is restricted", spec(), "restricted"),
        ("pod-level context can satisfy restricted",
         {"securityContext": {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}},
          "containers": [{"name": "a", "securityContext": {"allowPrivilegeEscalation": False,
                                                         "capabilities": {"drop": ["ALL"]}}}]},
         "restricted"),
        ("empty securityContext is baseline only", {"containers": [{"name": "a"}]}, "baseline"),
        ("allowPrivilegeEscalation true", with_c(allowPrivilegeEscalation=True), "baseline"),
        ("runAsNonRoot false", with_c(runAsNonRoot=False), "baseline"),
        ("runAsUser 0", with_c(runAsUser=0), "baseline"),
        ("no drop ALL", with_c(capabilities={"drop": ["KILL"]}), "baseline"),
        ("add NET_BIND_SERVICE keeps restricted",
         with_c(capabilities={"drop": ["ALL"], "add": ["NET_BIND_SERVICE"]}), "restricted"),
        ("add CHOWN is baseline (not restricted)",
         with_c(capabilities={"drop": ["ALL"], "add": ["CHOWN"]}), "baseline"),
        ("add SYS_ADMIN is privileged",
         with_c(capabilities={"drop": ["ALL"], "add": ["SYS_ADMIN"]}), "privileged"),
        ("seccomp Unconfined is privileged", with_c(seccompProfile={"type": "Unconfined"}), "privileged"),
        ("seccomp unset is baseline",
         {"containers": [{"name": "a", "securityContext": {"allowPrivilegeEscalation": False,
                          "runAsNonRoot": True, "capabilities": {"drop": ["ALL"]}}}]}, "baseline"),
        ("privileged container", with_c(privileged=True), "privileged"),
        ("procMount Unmasked", with_c(procMount="Unmasked"), "privileged"),
        ("hostNetwork", spec(hostNetwork=True), "privileged"),
        ("hostPID", spec(hostPID=True), "privileged"),
        ("hostIPC", spec(hostIPC=True), "privileged"),
        ("hostPath volume", spec(volumes=[{"name": "v", "hostPath": {"path": "/"}}]), "privileged"),
        ("hostPort", {"containers": [dict(good_c, ports=[{"containerPort": 1, "hostPort": 1}])]}, "privileged"),
        ("nfs volume is baseline", spec(volumes=[{"name": "v", "nfs": {"server": "s", "path": "/"}}]), "baseline"),
        ("secret+emptyDir+pvc+projected stay restricted",
         spec(volumes=[{"name": "a", "secret": {}}, {"name": "b", "emptyDir": {}},
                       {"name": "c", "persistentVolumeClaim": {"claimName": "x"}},
                       {"name": "d", "projected": {}}]), "restricted"),
        ("unsafe sysctl", spec(securityContext={"runAsNonRoot": True,
                               "sysctls": [{"name": "vm.max_map_count", "value": "1"}]}), "privileged"),
        ("safe sysctl", spec(securityContext={"sysctls": [{"name": "net.ipv4.ip_unprivileged_port_start",
                             "value": "0"}]}), "restricted"),
        ("SELinux custom type", spec(securityContext={"seLinuxOptions": {"type": "spc_t"}}), "privileged"),
        ("SELinux container_t ok", spec(securityContext={"seLinuxOptions": {"type": "container_t"}}), "restricted"),
        ("init container is checked",
         spec(initContainers=[{"name": "i", "securityContext": {"privileged": True}}]), "privileged"),
        ("init container missing fields drops to baseline",
         spec(initContainers=[{"name": "i"}]), "baseline"),
        ("AppArmor appArmorProfile Unconfined", with_c(appArmorProfile={"type": "Unconfined"}), "privileged"),
    ]
    bad = 0
    for name, sp, want in cases:
        got = level_of(*evaluate_spec(sp))
        ok = got == want
        bad += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {got}" + ("" if ok else f" (wanted {want})"))
    b, e = evaluate_spec(spec(), {APPARMOR_ANN + "a": "unconfined"})
    ok = bool(b)
    bad += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} AppArmor annotation unconfined")
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a == ["--selftest"]:
        sys.exit(selftest())
    if not a:
        print(__doc__)
        sys.exit(2)
    sys.exit(report(a[0]))

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Console actions, on the rendered artifact (TM-1311, TM-1313; docs/administration/tockmox-ui.md, "Taking action").

    python3 tools/check-actions.py              the gate (renders tockmox-ai three ways)
    python3 tools/check-actions.py --selftest   prove each assertion goes red on a planted render, then green

WHAT IT ASSERTS:
  1. THE UI HOLDS NO WRITE CREDENTIAL. Every Role and ClusterRole bound to the tockmox-ui ServiceAccount grants only
     get, list and watch. The actions are a separate ServiceAccount.
  2. tockmox-actions holds exactly its narrow grants: no ClusterRole or ClusterRoleBinding names it; in its Roles,
     create only on jobs and configmaps, get only, update only on its own record by name, patch only on deployments
     and statefulsets by name, and every rule on a named resource carries resourceNames.
  3. Every kind it can write to is bound: a jobs grant has the tockmox-actions-jobs ValidatingAdmissionPolicy and a
     Deny binding; a restart grant has tockmox-actions-restart-<kind>, also Deny, matching only this identity.
     Two forms the API server's CEL refuses or mis-evaluates are refused here too (both found on a k3s lab cluster,
     2026-11-01): `request.subResource` read without has() (absent on the main resource, so every restart errored),
     and `has(x) ? x : {}` on a typed object (it does not type-check, and an expression that does not compile denies).
  4. Only the UI reaches it: its NetworkPolicy admits ingress from the tockmox-ui pod and nothing else.
  5. Off means absent: with every kind off, nothing called tockmox-actions renders and the UI's config has no
     `actions` block; with argocd turned on and no account, the render fails with the reason.
Exit 2 (skipped) when helm or PyYAML is absent.
"""
import copy
import os
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("check-actions: PyYAML missing", file=sys.stderr)
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHART = os.path.join(ROOT, "charts", "tockmox-ai")
READ = {"get", "list", "watch"}
ON = {"global": {"internalDomain": "int.example.com", "lanCIDR": "10.0.0.0/24"},
      "tockmoxUi": {"enabled": True, "image": "registry.example/tockmox-ui:check",
                    "config": {"oidc": {"issuer": "https://auth.int.example.com/application/o/tockmox-ui"}},
                    "actions": {"restart": {"enabled": True, "allow": [
                        {"namespace": "tockmox-monitoring", "kind": "Deployment", "name": "tockmox-observability-grafana"}]}}}}
OFF = {"tockmoxUi": {"actions": {k: {"enabled": False} for k in ("silence", "testAlert", "runJob", "restart", "argocd")}}}
ARGO_NO_ACCOUNT = {"tockmoxUi": {"actions": {"argocd": {"enabled": True}}}}


def render(*overlays):
    with tempfile.TemporaryDirectory() as d:
        args = ["helm", "template", "tockmox-ai", CHART, "--namespace", "tockmox-ai", "-f", os.path.join(ROOT, "ci", "values.yaml")]
        for i, o in enumerate(overlays):
            p = os.path.join(d, f"o{i}.yaml")
            with open(p, "w") as fh:
                yaml.safe_dump(o, fh)
            args += ["-f", p]
        r = subprocess.run(args, capture_output=True, text=True)
    return r.returncode, [x for x in yaml.safe_load_all(r.stdout) if x] if r.returncode == 0 else r.stderr


def bound_to(docs, sa):
    """The Roles and ClusterRoles any binding gives `sa`, as (kind, name, namespace)."""
    out = []
    for b in docs:
        if b["kind"] in ("RoleBinding", "ClusterRoleBinding") and any(
                s.get("kind") == "ServiceAccount" and s.get("name") == sa for s in b.get("subjects") or []):
            out.append((b["roleRef"]["kind"], b["roleRef"]["name"], b["metadata"].get("namespace"), b["kind"]))
    return out


def role(docs, kind, name, ns):
    return next((d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name
                 and (kind == "ClusterRole" or d["metadata"].get("namespace") == ns)), None)


def check_on(docs) -> list:
    errs = []
    for kind, name, ns, _ in bound_to(docs, "tockmox-ui"):
        r = role(docs, kind, name, ns)
        for rule in (r or {}).get("rules") or []:
            if set(rule.get("verbs") or []) - READ:
                errs.append(f"1: the UI's {kind} {name} grants {sorted(set(rule['verbs']) - READ)} on {rule.get('resources')}")
    grants = bound_to(docs, "tockmox-actions")
    if not grants:
        errs.append("2: nothing binds tockmox-actions (is the service rendered?)")
    writes = set()
    for kind, name, ns, bkind in grants:
        if kind == "ClusterRole" or bkind == "ClusterRoleBinding":
            errs.append(f"2: tockmox-actions is bound cluster-wide ({bkind} -> {kind} {name})")
            continue
        for rule in (role(docs, kind, name, ns) or {}).get("rules") or []:
            res, verbs, names = set(rule.get("resources") or []), set(rule.get("verbs") or []), rule.get("resourceNames")
            for v in verbs:
                ok = (v == "create" and res <= {"jobs", "configmaps"} and not names) or \
                     (v == "get" and names) or \
                     (v == "update" and res == {"configmaps"} and names == ["tockmox-actions-activity"]) or \
                     (v == "patch" and res <= {"deployments", "statefulsets"} and names)
                if not ok:
                    errs.append(f"2: tockmox-actions Role {ns}/{name} grants {v} on {sorted(res)}"
                                f"{' without resourceNames' if not names else ''}")
                if v in ("create", "patch") and res & {"jobs", "deployments", "statefulsets"}:
                    writes |= res
    vaps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ValidatingAdmissionPolicy"}
    binds = {d["spec"]["policyName"]: d for d in docs if d["kind"] == "ValidatingAdmissionPolicyBinding"}
    for res in sorted(writes):
        pol = "tockmox-actions-jobs" if res == "jobs" else f"tockmox-actions-restart-{res}"
        v = vaps.get(pol)
        if v is None or binds.get(pol, {}).get("spec", {}).get("validationActions") != ["Deny"]:
            errs.append(f"3: {res} is writable by tockmox-actions but {pol} is missing or not bound with Deny")
            continue
        exprs = [x["expression"] for x in v["spec"].get("validations") or []] + [x["expression"] for x in v["spec"].get("variables") or []]
        for e in exprs:
            if "request.subResource" in e and "has(request.subResource)" not in e:
                errs.append(f"3: {pol} reads request.subResource without has(): it is absent on the main resource")
            if re.search(r"\?\s*(object|oldObject)\.spec\.(strategy|updateStrategy|persistentVolumeClaimRetentionPolicy|ordinals)\s*:\s*\{\}", e):
                errs.append(f"3: {pol} compares a typed object with {{}} in a ternary, which does not type-check")
        conds = " ".join(c["expression"] for c in v["spec"].get("matchConditions") or [])
        if "system:serviceaccount:tockmox-ai:tockmox-actions" not in conds or v["spec"].get("failurePolicy") != "Fail":
            errs.append(f"3: {pol} does not match exactly the tockmox-actions identity, or fails open")
    np = next((d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "tockmox-actions"), None)
    if np is None:
        errs.append("4: tockmox-actions has no NetworkPolicy")
    else:
        froms = [f for rule in np["spec"].get("ingress") or [] for f in rule.get("from") or []]
        if not froms or any(f != {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "tockmox-ui"}}} for f in froms):
            errs.append(f"4: tockmox-actions admits ingress from more than the UI pod: {froms}")
    return errs


def check_off(docs) -> list:
    errs = [f"5: {d['kind']} {d['metadata']['name']} renders with every kind off" for d in docs
            if "tockmox-actions" in d["metadata"]["name"]]
    ui = next((d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-ui"), None)
    if ui and "actions" in (yaml.safe_load(ui["data"]["config.yaml"]) or {}):
        errs.append("5: the UI's config has an actions block with every kind off")
    return errs


def selftest(docs) -> int:
    fails = 0

    def planted(label, mutate, check, want):
        nonlocal fails
        d = copy.deepcopy(docs)
        mutate(d)
        got = [e for e in check(d) if e.startswith(want)]
        print(("  ok    " if got else "  FAIL  ") + label + ("" if got else f": expected an error starting {want!r}"))
        fails += not got

    def ui_writes(d):
        next(x for x in d if x["kind"] == "ClusterRole" and x["metadata"]["name"] == "tockmox-ui-read")["rules"].append(
            {"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["patch"]})

    def actions_wide(d):
        r = next(x for x in d if x["kind"] == "Role" and x["metadata"]["name"] == "tockmox-actions-restart")
        r["rules"][0].pop("resourceNames")

    def no_vap(d):
        d[:] = [x for x in d if not (x["kind"] == "ValidatingAdmissionPolicyBinding" and x["spec"]["policyName"] == "tockmox-actions-jobs")]

    def open_ingress(d):
        np = next(x for x in d if x["kind"] == "NetworkPolicy" and x["metadata"]["name"] == "tockmox-actions")
        np["spec"]["ingress"][0]["from"].append({"namespaceSelector": {}})

    def cluster(d):
        d.append({"kind": "ClusterRoleBinding", "metadata": {"name": "x"}, "roleRef": {"kind": "ClusterRole", "name": "edit"},
                  "subjects": [{"kind": "ServiceAccount", "name": "tockmox-actions", "namespace": "tockmox-ai"}]})

    def bare_subresource(d):
        v = next(x for x in d if x["kind"] == "ValidatingAdmissionPolicy" and x["metadata"]["name"] == "tockmox-actions-restart-deployments")
        v["spec"]["validations"][0]["expression"] = "request.operation == 'UPDATE' && request.subResource == ''"

    def leaks(d):
        d.append({"kind": "Deployment", "metadata": {"name": "tockmox-actions"}})
    planted("the UI granted patch", ui_writes, check_on, "1:")
    planted("a restart grant without resourceNames", actions_wide, check_on, "2:")
    planted("tockmox-actions bound cluster-wide", cluster, check_on, "2:")
    planted("the jobs policy unbound", no_vap, check_on, "3:")
    planted("request.subResource read without has()", bare_subresource, check_on, "3:")
    planted("ingress from any namespace", open_ingress, check_on, "4:")
    planted("an object rendered with every kind off", leaks, check_off, "5:")
    clean = check_on(docs)
    print(("  ok    " if not clean else "  FAIL  ") + "the real render is green" + ("" if not clean else f": {clean}"))
    return 1 if fails or clean else 0


def main():
    if subprocess.run(["helm", "version"], capture_output=True).returncode != 0:
        print("check-actions: helm missing", file=sys.stderr)
        return 2
    rc, on = render(ON)
    if rc:
        print(f"check-actions: the render with actions on failed:\n{on}")
        return 1
    if "--selftest" in sys.argv:
        return selftest(on)
    errs = check_on(on)
    rc, off = render(ON, OFF)
    errs += [f"render with every kind off failed: {off}"] if rc else check_off(off)
    rc, out = render(ON, ARGO_NO_ACCOUNT)
    if rc == 0 or "argocd.url" not in out:
        errs.append("5: argocd turned on with no account rendered, instead of failing with the reason")
    for e in errs:
        print("  FAIL  " + e)
    print("check-actions: " + ("ok (the UI is read-only; tockmox-actions is narrow, bounded and reachable from the UI only)"
                               if not errs else f"{len(errs)} problem(s)"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())

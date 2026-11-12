#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Console actions, on the rendered artifact (docs/administration/tockmox-ui.md, "Taking action").

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
  4. Only the UI reaches it: its NetworkPolicy admits ingress from the tockmox-ui pod and nothing else. Its pod has
     service links off (Kubernetes would set TOCKMOX_ACTIONS_PORT=tcp://... for its own Service; a k3s lab cluster,
     2026-11-01, crashed on it).
  5. Off means absent: with every kind off, nothing called tockmox-actions renders and the UI's config has no
     `actions` block; with argocd turned on and no account, the render fails with the reason.
  6. THE IDENTITY KINDS' TOKEN is mounted into tockmox-actions and into no pod of the UI.
  7. THE IDENTITY LAYER'S SIDE (tockmox-identity rendered with sso.consoleActions on, and off): the role grants
     `authentik_core.view_user` globally and nothing else; object permissions sit on the user group only, and are
     only view_group, add_user_to_group and remove_user_from_group, each to the console role; the service account is a
     service account with no groups and exactly the console role; the blueprint makes no token (the CronJob owns it:
     an !Env token entry was skipped on a lab run, 2026-11-01, and never re-applied); the CronJob reads the token's
     Secret, sets a non-expiring API token from it and removes it while empty, and neither Authentik's server nor its
     worker is given that Secret; the recovery-grant CronJob runs with no ServiceAccount token, grants
     exactly reset_user_password and the recovery endpoint's object-level add_user, excludes groups under the admin
     group and fails closed; the recovery flow signs nobody in and is refused without a link. Off: no console
     blueprint, no CronJob. With identity on, tockmox-actions may reach the issuer's host (Traefik).
  8. THE CHANGE KINDS HOLD NO FORGE ADMIN CREDENTIAL (Forgejo 15.0.11 lets its admin merge past the branch
     rule). With changes on: no pod in the AI layer names the forge's admin Secret (any Secret whose name holds
     "forge-admin"); the change bot's token and the console's OAuth2 client are mounted into tockmox-actions and
     into no other pod; the UI's own config carries the switch and nothing else of the forge (no token file, no
     client secret: the UI asks the service for the sign-in URL); tockmox-actions may reach the forge's namespace
     on port 3000 and nothing else of it.
  9. THE CHANGE KINDS' DEFAULT FOLLOWS THE SITE'S FORGE: on with global.siteForge built-in and nothing set, off with
     it external or empty, and an explicit tockmoxUi.actions.changes.enabled wins either way.
 10. MOVE TO MY OWN FORGE (moveForge, on with the change kinds) starts a Job that runs as a ServiceAccount able to
     patch Argo CD's root, so its grant and its policies are checked whole: the Role tockmox-actions-move in the
     forge's namespace is exactly get on the one move CronJob, create/get/list on Jobs, list on pods, get on their
     logs, create on Secrets and get/delete on the one request Secret; tockmox-actions-move-job (Deny, fails closed,
     this identity only) pins the owner, the ServiceAccount, one container, the image the chart pins, the command,
     the arguments and the volumes; tockmox-actions-move-secret admits only the request Secret, owned by a Job; the
     run-now policy steps aside for a move Job and for nothing else. Off (moveForge.enabled false): none of it renders.
 11. RUN-NOW IN THE FORGE'S NAMESPACE IS THE OFF-SITE COPY'S OWN SHAPE. That namespace holds the forge's admin Secret
     and the move ServiceAccount, and tockmox-actions-jobs looks at nothing in the pod. So wherever this identity may
     create Jobs there (the change kinds add the forge's two CronJobs to run-now; a site can add its own),
     tockmox-actions-forge-jobs is rendered, bound with Deny, fails closed, and matches this identity in that
     namespace and steps aside for a move Job only. It pins: no ServiceAccount of its own (either field) and no
     token, one container and no init container, the copy script as the command, no environment read from a Secret
     or a ConfigMap, and only the copy's script, Secret, CA and scratch volumes. It does not pin the image. With no
     Jobs grant in that namespace it does not render. It stands on its own: the owner (exactly the CronJobs run-now
     lists in that namespace) and the label are checked here too, because the move's Role grants create on Jobs
     there even with run-now off, where tockmox-actions-jobs does not render; then it admits nothing but a move.
     Measured on a real API server (k3s v1.36.4, 2026-11-11): the product's own run-now of both CronJobs is admitted;
     twenty requests with one thing changed in the pod, four with the owner or the label changed, and the request
     that found the gap are refused; each pod rule dropped admits exactly its own; and with run-now off, a Job with
     no owner that the unfixed chart admitted is refused.
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
    print("SKIPPED: python3 has no PyYAML", file=sys.stderr)
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
IDENTITY_ON = {"tockmoxUi": {"actions": {"identity": {"enabled": True}}}}
CHANGES_ON = {"global": {"siteForge": "built-in"}}           # the default on a built-in-forge site
FORGE_SECRETS = ("tockmox-forge-actions-bot", "tockmox-forge-console-oauth")
ID_CHART = os.path.join(ROOT, "charts", "tockmox-identity")
CONSOLE_ON = {"sso": {"consoleActions": {"enabled": True}}}
ROLE_GLOBAL = ["authentik_core.view_user"]
GROUP_OBJECT = {"authentik_core.view_group", "authentik_core.add_user_to_group", "authentik_core.remove_user_from_group"}
GRANTS = '["authentik_core.reset_user_password", "authentik_core.add_user"]'


def render(*overlays, chart=CHART, release="tockmox-ai", ns="tockmox-ai"):
    with tempfile.TemporaryDirectory() as d:
        args = ["helm", "template", release, chart, "--namespace", ns, "-f", os.path.join(ROOT, "ci", "values.yaml")]
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
        if name == "tockmox-actions-move":
            continue                                   # checked whole by check_move (10)
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
    dep = next((d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "tockmox-actions"), None)
    if dep is None:
        errs.append("4: the on render has no tockmox-actions Deployment")
    elif dep["spec"]["template"]["spec"].get("enableServiceLinks") is not False:
        errs.append("4: tockmox-actions has service links on: TOCKMOX_ACTIONS_PORT would be tcp://<ip>:8081 in its pod")
    np = next((d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "tockmox-actions"), None)
    if np is None:
        errs.append("4: tockmox-actions has no NetworkPolicy")
    else:
        froms = [f for rule in np["spec"].get("ingress") or [] for f in rule.get("from") or []]
        if not froms or any(f != {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "tockmox-ui"}}} for f in froms):
            errs.append(f"4: tockmox-actions admits ingress from more than the UI pod: {froms}")
    return errs


IDENTITY_TOKEN_NAME = "tockmox-console-actions-token"   # the Secret's name, not a secret


def check_identity_mount(docs) -> list:
    errs = []
    secret = IDENTITY_TOKEN_NAME
    for d in docs:
        if d["kind"] not in ("Deployment", "StatefulSet", "Job", "CronJob"):
            continue
        spec = d["spec"]["jobTemplate"]["spec"]["template"]["spec"] if d["kind"] == "CronJob" else d["spec"]["template"]["spec"]
        names = {(v.get("secret") or {}).get("secretName") for v in spec.get("volumes") or []}
        names |= {(e.get("secretRef") or {}).get("name") for c in spec.get("containers") or [] for e in c.get("envFrom") or []}
        if secret in names and d["metadata"]["name"] != "tockmox-actions":
            errs.append(f"6: {d['kind']} {d['metadata']['name']} mounts the identity actions' token")
    dep = next((d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "tockmox-actions"), None)
    if dep is None or secret not in {(v.get("secret") or {}).get("secretName") for v in dep["spec"]["template"]["spec"].get("volumes") or []}:
        errs.append("6: identity actions are on but tockmox-actions does not mount their token")
    np = next((d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "tockmox-actions"), None)
    tos = [t for r in ((np or {}).get("spec") or {}).get("egress") or [] for t in r.get("to") or []]
    if not any(((t.get("podSelector") or {}).get("matchLabels") or {}).get("app.kubernetes.io/name") == "traefik" for t in tos):
        errs.append("6: identity actions are on but tockmox-actions cannot reach the issuer's host (Traefik)")
    return errs


def _pods(docs):
    for d in docs:
        if d["kind"] in ("Deployment", "StatefulSet", "Job", "CronJob", "DaemonSet"):
            yield d, (d["spec"]["jobTemplate"]["spec"]["template"]["spec"] if d["kind"] == "CronJob" else d["spec"]["template"]["spec"])


def _secrets_of(spec) -> set:
    names = {(v.get("secret") or {}).get("secretName") for v in spec.get("volumes") or []}
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        names |= {(e.get("secretRef") or {}).get("name") for e in c.get("envFrom") or []}
        names |= {((e.get("valueFrom") or {}).get("secretKeyRef") or {}).get("name") for e in c.get("env") or []}
    return names - {None}


def check_changes(docs) -> list:
    errs = []
    for d, spec in _pods(docs):
        held = _secrets_of(spec)
        admin = sorted(n for n in held if "forge-admin" in n)
        if admin:
            errs.append(f"8: {d['kind']} {d['metadata']['name']} names the forge's admin Secret {admin}")
        mine = held & set(FORGE_SECRETS)
        if mine and d["metadata"]["name"] != "tockmox-actions":
            errs.append(f"8: {d['kind']} {d['metadata']['name']} mounts {sorted(mine)}, the change kinds' credentials")
    dep = next((d for d, _ in _pods(docs) if d["kind"] == "Deployment" and d["metadata"]["name"] == "tockmox-actions"), None)
    if dep is None or not set(FORGE_SECRETS) <= _secrets_of(dep["spec"]["template"]["spec"]):
        errs.append("8: changes are on but tockmox-actions does not mount the bot's token and the OAuth2 client")
    ui = next((d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-ui"), None)
    uich = (((yaml.safe_load((ui or {}).get("data", {}).get("config.yaml", "")) or {}).get("actions") or {}).get("changes")) or {}
    if uich != {"enabled": True}:
        errs.append(f"8: the UI's config carries more of the forge than the switch: {sorted(uich)}")
    svc = next((d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-actions"), None)
    sch = (((yaml.safe_load((svc or {}).get("data", {}).get("config.yaml", "")) or {}).get("actions") or {}).get("changes")) or {}
    if not (sch.get("botTokenFile") and (sch.get("oauth") or {}).get("clientSecretFile") and
            str(sch.get("apiUrl", "")).endswith(".svc:3000/api/v1")):
        errs.append("8: the service's config has no in-cluster forge API, bot token file or client secret file")
    np = next((d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "tockmox-actions"), None)
    to_forge = [r for r in ((np or {}).get("spec") or {}).get("egress") or [] for t in r.get("to") or []
                if ((t.get("namespaceSelector") or {}).get("matchLabels") or {}).get("kubernetes.io/metadata.name") == "tockmox-forge"]
    if not to_forge or any(r.get("ports") != [{"port": 3000, "protocol": "TCP"}] for r in to_forge):
        errs.append("8: tockmox-actions cannot reach the forge on port 3000, or may reach more of it")
    return errs


MOVE_RULES = [
    {"apiGroups": ["batch"], "resources": ["cronjobs"], "resourceNames": ["tockmox-forge-move"], "verbs": ["get"]},
    {"apiGroups": ["batch"], "resources": ["jobs"], "verbs": ["create", "get", "list"]},
    {"apiGroups": [""], "resources": ["pods"], "verbs": ["list"]},
    {"apiGroups": [""], "resources": ["pods/log"], "verbs": ["get"]},
    {"apiGroups": [""], "resources": ["secrets"], "verbs": ["create"]},
    {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["tockmox-forge-move-request"], "verbs": ["get", "delete"]},
]
MOVE_PINS = ("serviceAccountName == 'tockmox-forge-move'", "image == 'alpine/k8s:", "command == ['bash', '/opt/move/forge-move.sh']",
             "'--request', '/run/move/request'", "v.configMap.name == 'tockmox-forge-move-script'",
             "v.secret.secretName == 'tockmox-forge-move-request'", "ownerReferences[0].name == 'tockmox-forge-move'",
             "e.name in ['HOME', 'NO_COLOR']", "!has(variables.pod.initContainers)")


def check_move(docs, want_on=True) -> list:
    errs = []
    r = role(docs, "Role", "tockmox-actions-move", "tockmox-forge")
    vaps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ValidatingAdmissionPolicy"}
    binds = {d["spec"]["policyName"]: d for d in docs if d["kind"] == "ValidatingAdmissionPolicyBinding"}
    if not want_on:
        left = [n for n in ("tockmox-actions-move-job", "tockmox-actions-move-secret") if n in vaps] + (["the Role"] if r else [])
        return [f"10: moveForge is off but {left} rendered"] if left else []
    if r is None:
        return ["10: moveForge is on but the Role tockmox-actions-move is missing in the forge's namespace"]
    if r.get("rules") != MOVE_RULES:
        errs.append(f"10: the Role tockmox-actions-move is not exactly the move's grant: {r.get('rules')}")
    for pol in ("tockmox-actions-move-job", "tockmox-actions-move-secret"):
        v = vaps.get(pol)
        if v is None or binds.get(pol, {}).get("spec", {}).get("validationActions") != ["Deny"] or v["spec"].get("failurePolicy") != "Fail":
            errs.append(f"10: {pol} is missing, not bound with Deny, or fails open")
            continue
        conds = " ".join(c["expression"] for c in v["spec"].get("matchConditions") or [])
        if "system:serviceaccount:tockmox-ai:tockmox-actions" not in conds:
            errs.append(f"10: {pol} does not match the tockmox-actions identity")
    job = " ".join(x["expression"] for x in ((vaps.get("tockmox-actions-move-job") or {}).get("spec") or {}).get("validations") or [])
    for pin in MOVE_PINS:
        if pin not in job:
            errs.append(f"10: tockmox-actions-move-job does not pin {pin!r}")
    sec = " ".join(x["expression"] for x in ((vaps.get("tockmox-actions-move-secret") or {}).get("spec") or {}).get("validations") or [])
    for pin in ("request.operation == 'CREATE'", "object.metadata.name == 'tockmox-forge-move-request'", "ownerReferences[0].kind == 'Job'"):
        if pin not in sec:
            errs.append(f"10: tockmox-actions-move-secret does not pin {pin!r}")
    rn = vaps.get("tockmox-actions-jobs")
    if rn is not None:
        conds = [c["expression"] for c in rn["spec"].get("matchConditions") or []]
        if conds[1:] != ["!(has(object.metadata.labels) && 'tockmox.com/move-forge' in object.metadata.labels)"]:
            errs.append(f"10: the run-now policy steps aside for more than a move Job: {conds[1:]}")
    svc = next((d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-actions"), None)
    mv = (((yaml.safe_load((svc or {}).get("data", {}).get("config.yaml", "")) or {}).get("actions") or {}).get("moveForge")) or {}
    if (mv.get("cronJob"), mv.get("requestSecret")) != ("tockmox-forge-move", "tockmox-forge-move-request"):
        errs.append(f"10: the service's config does not name the move CronJob and its request Secret: {mv}")
    return errs


FORGE_PINS = ("request.operation == 'CREATE'", "object.metadata.ownerReferences[0].kind == 'CronJob'",
              "object.metadata.labels['tockmox.com/run-now'] == 'true'",
              "variables.pod.serviceAccountName in ['', 'default']", "variables.pod.serviceAccount in ['', 'default']",
              "!variables.pod.automountServiceAccountToken", "size(variables.pod.containers) == 1",
              "!has(variables.pod.initContainers)", "!has(variables.pod.ephemeralContainers)",
              "command == ['/bin/sh', '/opt/offsite/forge-offsite-copy.sh']", "!has(variables.pod.containers[0].args)",
              "!has(variables.pod.containers[0].envFrom)", "!has(e.valueFrom)",
              "v.configMap.name in ['tockmox-forge-offsite-script', 'tockmox-forge-offsite-ca']",
              "v.secret.secretName == 'tockmox-forge-offsite'")
NOT_A_MOVE = "!(has(object.metadata.labels) && 'tockmox.com/move-forge' in object.metadata.labels)"


def check_forge_jobs(docs, forge_ns="tockmox-forge") -> list:
    name = "tockmox-actions-forge-jobs"
    vaps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ValidatingAdmissionPolicy"}
    binds = {d["spec"]["policyName"]: d for d in docs if d["kind"] == "ValidatingAdmissionPolicyBinding"}
    mine = {(n, ns) for kind, n, ns, _ in bound_to(docs, "tockmox-actions") if kind == "Role"}
    grant = any(d["kind"] == "Role" and d["metadata"].get("namespace") == forge_ns and (d["metadata"]["name"], forge_ns) in mine
                and any("jobs" in (r.get("resources") or []) and "create" in (r.get("verbs") or []) for r in d.get("rules") or [])
                for d in docs)
    v = vaps.get(name)
    if not grant:
        return [f"11: {name} rendered with no Jobs grant in {forge_ns}"] if v is not None or name in binds else []
    if v is None:
        return [f"11: tockmox-actions may create Jobs in {forge_ns} but {name} is missing"]
    errs = []
    if binds.get(name, {}).get("spec", {}).get("validationActions") != ["Deny"] or v["spec"].get("failurePolicy") != "Fail":
        errs.append(f"11: {name} is not bound with Deny, or fails open")
    rules = (v["spec"].get("matchConstraints") or {}).get("resourceRules") or []
    if not any("jobs" in r.get("resources", []) and {"CREATE", "UPDATE"} <= set(r.get("operations", [])) for r in rules):
        errs.append(f"11: {name} does not match the creation and update of Jobs")
    conds = [c["expression"] for c in v["spec"].get("matchConditions") or []]
    want = ["request.userInfo.username == 'system:serviceaccount:tockmox-ai:tockmox-actions'", f"request.namespace == '{forge_ns}'"]
    if "tockmox-actions-move-job" in vaps:
        want.append(NOT_A_MOVE)
    if conds != want:
        errs.append(f"11: {name} matches something other than every Job from this identity in {forge_ns} that is not a move: {conds}")
    body = " ".join(x["expression"] for x in v["spec"].get("validations") or [])
    for pin in FORGE_PINS:
        if pin not in body:
            errs.append(f"11: {name} does not pin {pin!r}")
    # The owners it admits are exactly the CronJobs run-now may read in this namespace: none with run-now off.
    listed = sorted(n for d in docs if d["kind"] == "Role" and (d["metadata"]["name"], d["metadata"].get("namespace")) == ("tockmox-actions-run-now", forge_ns)
                    for r in d.get("rules") or [] if "cronjobs" in (r.get("resources") or []) for n in r.get("resourceNames") or [])
    m = re.search(r"ownerReferences\[0\]\.name in (\[[^\]]*\])", body)
    if not m or sorted(yaml.safe_load(m.group(1))) != listed:
        errs.append(f"11: {name} admits owners {m.group(1) if m else None}, not the CronJobs run-now lists in {forge_ns}: {listed}")
    return errs


class _Tag(str):
    """A YAML tag in an Authentik blueprint (!KeyOf, !Env), kept as '!Name value' for the assertions."""


def _bp_loader():
    class L(yaml.SafeLoader):
        pass
    L.add_multi_constructor("!", lambda loader, suffix, node: _Tag(f"!{suffix} {getattr(node, 'value', '')}"))
    return L


def blueprint(docs, name):
    cm = next((d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-sso-blueprints"), None)
    raw = ((cm or {}).get("data") or {}).get(name)
    return yaml.load(raw, Loader=_bp_loader()) if raw else None


def check_identity_layer(docs) -> list:
    errs = []
    bp = blueprint(docs, "tockmox-console-identity.yaml")
    if bp is None:
        return ["7: sso.consoleActions is on but the tockmox-console-identity blueprint is missing"]
    ents = bp.get("entries") or []
    roles = [e for e in ents if e.get("model") == "authentik_rbac.role"]
    if len(roles) != 1 or (roles[0].get("attrs") or {}).get("permissions") != ROLE_GLOBAL:
        errs.append(f"7: the console role's global permissions are not exactly {ROLE_GLOBAL}: "
                    f"{[(r.get('attrs') or {}).get('permissions') for r in roles]}")
    held = 0
    for e in ents:
        for p in e.get("permissions") or []:
            held += 1
            if e.get("model") != "authentik_core.group" or (e.get("identifiers") or {}).get("name") != "tockmox-users":
                errs.append(f"7: an object permission on {e.get('model')} {e.get('identifiers')}, not the user group")
            if p.get("permission") not in GROUP_OBJECT:
                errs.append(f"7: object permission {p.get('permission')} on {e.get('identifiers')}")
            if p.get("role") != "!KeyOf console-role" or p.get("user") is not None:
                errs.append(f"7: object permission {p.get('permission')} goes to {p.get('role') or p.get('user')}, not the console role")
        if (e.get("attrs") or {}).get("is_superuser") is True:
            errs.append(f"7: {e.get('model')} {e.get('identifiers')} sets is_superuser")
    if not held:
        errs.append("7: the console role holds nothing on the user group")
    acct = [e for e in ents if e.get("model") == "authentik_core.user"]
    aa = (acct[0].get("attrs") or {}) if len(acct) == 1 else {}
    if aa.get("type") != "service_account" or "groups" in aa or aa.get("roles") != ["!KeyOf console-role"]:
        errs.append("7: the console account is not one service account with no groups and only the console role")
    if any(e.get("model") == "authentik_core.token" for e in ents):
        errs.append("7: the console blueprint makes a token: the grants CronJob owns it (an !Env entry is skipped when "
                    "the worker starts before the Secret, and an unchanged blueprint is never re-applied)")
    for d in docs:
        if d["kind"] in ("Deployment", "StatefulSet") and "authentik" in d["metadata"]["name"]:
            ps_ = d["spec"]["template"]["spec"]
            cs_ = (ps_.get("containers") or []) + (ps_.get("initContainers") or [])
            refs = {(e.get("secretRef") or {}).get("name") for c in cs_ for e in c.get("envFrom") or []}
            refs |= {((e.get("valueFrom") or {}).get("secretKeyRef") or {}).get("name") for c in cs_ for e in c.get("env") or []}
            if IDENTITY_TOKEN_NAME in refs:
                errs.append(f"7: Authentik's {d['metadata']['name']} is given the console token: one owner, the grants CronJob")
    rec = blueprint(docs, "tockmox-recovery.yaml")
    if rec is None:
        errs.append("7: sso.recoveryFlow is on by default but the tockmox-recovery blueprint is missing")
    else:
        re_ = rec.get("entries") or []
        if any(e.get("model") == "authentik_stages_user_login.userloginstage" for e in re_):
            errs.append("7: the recovery flow signs the person in, past their second factor")
        pol = [e for e in re_ if e.get("model") == "authentik_policies_expression.expressionpolicy"
               and "pending_user" in str((e.get("attrs") or {}).get("expression", ""))]
        bound = [e for e in re_ if e.get("model") == "authentik_policies.policybinding"
                 and (e.get("identifiers") or {}).get("target") == "!KeyOf recovery-flow"]
        if not (pol and bound):
            errs.append("7: the recovery flow is not refused without a link")
    cj = next((d for d in docs if d["kind"] == "CronJob" and d["metadata"]["name"] == "tockmox-console-identity-grants"), None)
    if cj is None:
        errs.append("7: the recovery-grant CronJob is missing")
    else:
        ps = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        script = "\n".join(ps["containers"][0].get("args") or [])
        if ps.get("automountServiceAccountToken") is not False:
            errs.append("7: the recovery-grant CronJob mounts a ServiceAccount token")
        if GRANTS not in script or "change_user" in script or "view_group" in script:
            errs.append("7: the recovery-grant CronJob grants something other than the recovery link")
        if "with_descendants()" not in script or "raise SystemExit(1)" not in script or "revoke_all(" not in script:
            errs.append("7: the recovery-grant CronJob does not exclude groups under the admin group, or does not fail closed")
        refs = {(e.get("secretRef") or {}).get("name") for e in ps["containers"][0].get("envFrom") or []}
        optional = any((e.get("secretRef") or {}).get("name") == IDENTITY_TOKEN_NAME and (e.get("secretRef") or {}).get("optional") is True
                       for e in ps["containers"][0].get("envFrom") or [])
        if IDENTITY_TOKEN_NAME in refs and not optional:
            errs.append("7: the grants CronJob needs the token's Secret: with it absent no run starts, and no grant is taken back")
        sets = 'Token.objects.create(identifier="tockmox-console-actions"'
        if (IDENTITY_TOKEN_NAME not in refs or sets not in script or "tok.save()" not in script or '"expiring": False' not in script
                or "TokenIntents.INTENT_API" not in script or "UserTypes.SERVICE_ACCOUNT" not in script
                or 'Token.objects.filter(identifier="tockmox-console-actions").delete()' not in script):
            errs.append("7: the recovery-grant CronJob does not keep the console token: read its Secret, set one "
                        "non-expiring API token on the service account, remove it while empty")
    return errs


def check_identity_off(docs) -> list:
    errs = []
    if blueprint(docs, "tockmox-console-identity.yaml") is not None:
        errs.append("7: the console blueprint renders with sso.consoleActions off")
    if any(d["kind"] == "CronJob" and d["metadata"]["name"] == "tockmox-console-identity-grants" for d in docs):
        errs.append("7: the recovery-grant CronJob renders with sso.consoleActions off")
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

    def links_on(d):
        x = next(y for y in d if y["kind"] == "Deployment" and y["metadata"]["name"] == "tockmox-actions")
        x["spec"]["template"]["spec"].pop("enableServiceLinks", None)

    def leaks(d):
        d.append({"kind": "Deployment", "metadata": {"name": "tockmox-actions"}})

    def wide_role(d):
        cm = next(x for x in d if x["kind"] == "ConfigMap" and x["metadata"]["name"] == "tockmox-sso-blueprints")
        cm["data"]["tockmox-console-identity.yaml"] = cm["data"]["tockmox-console-identity.yaml"].replace(
            "- authentik_core.view_user", "- authentik_core.view_user\n            - authentik_core.change_user")

    def admin_group(d):
        cm = next(x for x in d if x["kind"] == "ConfigMap" and x["metadata"]["name"] == "tockmox-sso-blueprints")
        cm["data"]["tockmox-console-identity.yaml"] = cm["data"]["tockmox-console-identity.yaml"].replace(
            "name: tockmox-users\n", "name: tockmox-admins\n")

    def ui_mounts(d):
        ui = next(x for x in d if x["kind"] == "Deployment" and x["metadata"]["name"] == "tockmox-ui")
        ui["spec"]["template"]["spec"].setdefault("volumes", []).append(
            {"name": "x", "secret": {"secretName": "tockmox-console-actions-token"}})
    planted("the UI granted patch", ui_writes, check_on, "1:")
    planted("a restart grant without resourceNames", actions_wide, check_on, "2:")
    planted("tockmox-actions bound cluster-wide", cluster, check_on, "2:")
    planted("the jobs policy unbound", no_vap, check_on, "3:")
    planted("request.subResource read without has()", bare_subresource, check_on, "3:")
    planted("ingress from any namespace", open_ingress, check_on, "4:")
    planted("service links on for tockmox-actions", links_on, check_on, "4:")
    planted("an object rendered with every kind off", leaks, check_off, "5:")
    rc, iddocs = render(ON, IDENTITY_ON)
    rc2, layer = render(CONSOLE_ON, chart=ID_CHART, release="tockmox-identity", ns="tockmox-authentik")
    if rc or rc2:
        print(f"  FAIL  the identity renders failed: {iddocs if rc else layer}")
        return 1
    docs[:] = iddocs
    planted("the UI mounts the identity token", ui_mounts, check_identity_mount, "6:")
    rc, chdocs = render(ON, CHANGES_ON)
    if rc:
        print(f"  FAIL  the changes render failed: {chdocs}")
        return 1
    docs[:] = chdocs

    def actions_admin(d):
        x = next(y for y in d if y["kind"] == "Deployment" and y["metadata"]["name"] == "tockmox-actions")
        x["spec"]["template"]["spec"]["volumes"].append({"name": "a", "secret": {"secretName": "tockmox-forge-admin"}})

    def ui_oauth(d):
        x = next(y for y in d if y["kind"] == "Deployment" and y["metadata"]["name"] == "tockmox-ui")
        x["spec"]["template"]["spec"].setdefault("volumes", []).append({"name": "o", "secret": {"secretName": "tockmox-forge-console-oauth"}})

    def ui_config_secret(d):
        cm = next(y for y in d if y["kind"] == "ConfigMap" and y["metadata"]["name"] == "tockmox-ui")
        c = yaml.safe_load(cm["data"]["config.yaml"])
        c["actions"]["changes"]["oauth"] = {"clientSecretFile": "/x"}
        cm["data"]["config.yaml"] = yaml.safe_dump(c)

    def forge_wide(d):
        np = next(y for y in d if y["kind"] == "NetworkPolicy" and y["metadata"]["name"] == "tockmox-actions")
        for r in np["spec"]["egress"]:
            if any(((t.get("namespaceSelector") or {}).get("matchLabels") or {}).get("kubernetes.io/metadata.name") == "tockmox-forge"
                   for t in r.get("to") or []):
                r.pop("ports")
    planted("tockmox-actions mounts the forge's admin Secret", actions_admin, check_changes, "8:")
    planted("the UI mounts the console's OAuth2 client", ui_oauth, check_changes, "8:")
    planted("the UI's config carries the client secret file", ui_config_secret, check_changes, "8:")
    planted("tockmox-actions may reach every port of the forge", forge_wide, check_changes, "8:")

    def move_role_wide(d):
        next(y for y in d if y["kind"] == "Role" and y["metadata"]["name"] == "tockmox-actions-move")["rules"].append(
            {"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]})

    def move_image_free(d):
        v = next(y for y in d if y["kind"] == "ValidatingAdmissionPolicy" and y["metadata"]["name"] == "tockmox-actions-move-job")
        v["spec"]["validations"] = [x for x in v["spec"]["validations"] if "image ==" not in x["expression"]]

    def move_secret_unbound(d):
        d[:] = [y for y in d if not (y["kind"] == "ValidatingAdmissionPolicyBinding" and y["spec"]["policyName"] == "tockmox-actions-move-secret")]

    def run_now_steps_aside(d):
        v = next(y for y in d if y["kind"] == "ValidatingAdmissionPolicy" and y["metadata"]["name"] == "tockmox-actions-jobs")
        v["spec"]["matchConditions"].append({"name": "x", "expression": "request.namespace != 'tockmox-ai'"})
    planted("the move Role may read every Secret in the forge's namespace", move_role_wide, check_move, "10:")
    planted("the move Job policy admits any image", move_image_free, check_move, "10:")
    planted("the request Secret's policy is not bound", move_secret_unbound, check_move, "10:")
    if any(y["kind"] == "ValidatingAdmissionPolicy" and y["metadata"]["name"] == "tockmox-actions-jobs" for y in docs):
        planted("the run-now policy steps aside for more than a move", run_now_steps_aside, check_move, "10:")

    def _pin(d):
        return next(y for y in d if y["kind"] == "ValidatingAdmissionPolicy" and y["metadata"]["name"] == "tockmox-actions-forge-jobs")

    def pin_gone(d):
        d[:] = [y for y in d if not (y["kind"].startswith("ValidatingAdmissionPolicy") and "tockmox-actions-forge-jobs" in (y["metadata"]["name"], y["spec"].get("policyName")))]

    def pin_unbound(d):
        d[:] = [y for y in d if not (y["kind"] == "ValidatingAdmissionPolicyBinding" and y["spec"]["policyName"] == "tockmox-actions-forge-jobs")]

    def pin_fails_open(d):
        _pin(d)["spec"]["failurePolicy"] = "Ignore"

    def pin_any_account(d):
        _pin(d)["spec"]["validations"] = [x for x in _pin(d)["spec"]["validations"] if "serviceAccountName" not in x["expression"]]

    def pin_any_volume(d):
        _pin(d)["spec"]["validations"] = [x for x in _pin(d)["spec"]["validations"] if "v.secret" not in x["expression"]]

    def pin_any_command(d):
        _pin(d)["spec"]["validations"] = [x for x in _pin(d)["spec"]["validations"] if "command ==" not in x["expression"]]

    def pin_steps_aside(d):
        _pin(d)["spec"]["matchConditions"].append({"name": "x", "expression": "!has(object.metadata.labels) || !('skip' in object.metadata.labels)"})

    def pin_other_namespace(d):
        _pin(d)["spec"]["matchConditions"][1]["expression"] = "request.namespace == 'elsewhere'"
    planted("run-now reaches the forge's namespace with no pin on the pod", pin_gone, check_forge_jobs, "11:")
    planted("the forge run-now pin is not bound", pin_unbound, check_forge_jobs, "11:")
    planted("the forge run-now pin fails open", pin_fails_open, check_forge_jobs, "11:")
    planted("the forge run-now pin admits any ServiceAccount", pin_any_account, check_forge_jobs, "11:")
    planted("the forge run-now pin admits any volume", pin_any_volume, check_forge_jobs, "11:")
    planted("the forge run-now pin admits any command", pin_any_command, check_forge_jobs, "11:")
    planted("the forge run-now pin steps aside for a label of the caller's choosing", pin_steps_aside, check_forge_jobs, "11:")
    planted("the forge run-now pin watches another namespace", pin_other_namespace, check_forge_jobs, "11:")

    def pin_any_owner(d):
        for x in _pin(d)["spec"]["validations"]:
            x["expression"] = re.sub(r"name in \[[^\]]*\]", "name in ['tockmox-forge-offsite', 'tockmox-forge-drill-check', 'tockmox-forge-move']", x["expression"])
    planted("the forge run-now pin admits an owner run-now does not list", pin_any_owner, check_forge_jobs, "11:")
    docs[:] = layer
    planted("the console role granted change_user", wide_role, check_identity_layer, "7:")
    planted("the console may change the admin group", admin_group, check_identity_layer, "7:")

    def signs_in(d):
        cm = next(x for x in d if x["kind"] == "ConfigMap" and x["metadata"]["name"] == "tockmox-sso-blueprints")
        cm["data"]["tockmox-recovery.yaml"] += "  - model: authentik_stages_user_login.userloginstage\n    identifiers: {name: x}\n"

    def fails_open(d):
        cj = next(x for x in d if x["kind"] == "CronJob" and x["metadata"]["name"] == "tockmox-console-identity-grants")
        a = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["args"]
        a[-1] = a[-1].replace("raise SystemExit(1)", "pass")
    planted("the recovery flow signs the person in", signs_in, check_identity_layer, "7:")
    planted("the grants CronJob fails open", fails_open, check_identity_layer, "7:")

    def token_in_blueprint(d):
        cm = next(x for x in d if x["kind"] == "ConfigMap" and x["metadata"]["name"] == "tockmox-sso-blueprints")
        cm["data"]["tockmox-console-identity.yaml"] += (
            "  - model: authentik_core.token\n    identifiers: {identifier: tockmox-console-actions}\n"
            "    attrs: {key: !Env TOCKMOX_CONSOLE_ACTIONS_TOKEN}\n")

    def cronjob_no_token(d):
        cj = next(x for x in d if x["kind"] == "CronJob" and x["metadata"]["name"] == "tockmox-console-identity-grants")
        c = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        c["envFrom"] = [e for e in c["envFrom"] if (e.get("secretRef") or {}).get("name") != IDENTITY_TOKEN_NAME]

    def worker_gets_token(d):
        w = next(x for x in d if x["kind"] == "Deployment" and "authentik-worker" in x["metadata"]["name"])
        w["spec"]["template"]["spec"]["containers"][0].setdefault("envFrom", []).append({"secretRef": {"name": IDENTITY_TOKEN_NAME}})
    planted("the blueprint makes the console token", token_in_blueprint, check_identity_layer, "7:")
    planted("the grants CronJob does not read the token", cronjob_no_token, check_identity_layer, "7:")
    planted("the Authentik worker is given the token", worker_gets_token, check_identity_layer, "7:")

    def server_gets_token(d):
        w = next(x for x in d if x["kind"] == "Deployment" and "authentik-server" in x["metadata"]["name"])
        w["spec"]["template"]["spec"]["containers"][0].setdefault("env", []).append(
            {"name": "T", "valueFrom": {"secretKeyRef": {"name": IDENTITY_TOKEN_NAME, "key": "TOCKMOX_CONSOLE_ACTIONS_TOKEN"}}})

    def token_required(d):
        cj = next(x for x in d if x["kind"] == "CronJob" and x["metadata"]["name"] == "tockmox-console-identity-grants")
        for e in cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["envFrom"]:
            if (e.get("secretRef") or {}).get("name") == IDENTITY_TOKEN_NAME:
                e["secretRef"].pop("optional", None)
    planted("the Authentik server is given the token by key", server_gets_token, check_identity_layer, "7:")
    planted("the grants CronJob requires the token's Secret", token_required, check_identity_layer, "7:")
    clean = (check_on(iddocs) + check_identity_mount(iddocs) + check_identity_layer(layer) + check_changes(chdocs)
             + check_forge_jobs(chdocs))
    print(("  ok    " if not clean else "  FAIL  ") + "the real renders are green" + ("" if not clean else f": {clean}"))
    return 1 if fails or clean else 0


def main():
    if subprocess.run(["helm", "version"], capture_output=True).returncode != 0:
        print("check-actions: helm missing", file=sys.stderr)
        print("SKIPPED: helm is not on PATH", file=sys.stderr)
        return 2
    rc, on = render(ON)
    if rc:
        print(f"check-actions: the render with actions on failed:\n{on}")
        return 1
    if "--selftest" in sys.argv:
        return selftest(on)
    errs = check_on(on) + check_forge_jobs(on)
    rc, off = render(ON, OFF)
    errs += [f"render with every kind off failed: {off}"] if rc else check_off(off)
    rc, out = render(ON, ARGO_NO_ACCOUNT)
    if rc == 0 or "argocd.url" not in out:
        errs.append("5: argocd turned on with no account rendered, instead of failing with the reason")
    rc, ident = render(ON, IDENTITY_ON)
    errs += [f"render with identity on failed: {ident}"] if rc else check_on(ident) + check_identity_mount(ident)
    rc, ch = render(ON, CHANGES_ON)
    errs += [f"render with changes on failed: {ch}"] if rc else check_on(ch) + check_changes(ch) + check_move(ch) + check_forge_jobs(ch)
    rc, nomv = render(ON, CHANGES_ON, {"tockmoxUi": {"actions": {"moveForge": {"enabled": False}}}})
    errs += [f"render with moveForge off failed: {nomv}"] if rc else check_move(nomv, want_on=False) + check_forge_jobs(nomv)
    # Run-now off, the move on: the move's Role still grants create on Jobs there, and nothing but a move is admitted.
    rc, norun = render(ON, CHANGES_ON, {"tockmoxUi": {"actions": {"runJob": {"enabled": False}}}})
    errs += [f"render with run-now off and the move on failed: {norun}"] if rc else check_forge_jobs(norun) + check_move(norun)
    if not rc and "ownerReferences[0].name in []" not in " ".join(
            x["expression"] for d in norun if d["kind"] == "ValidatingAdmissionPolicy" and d["metadata"]["name"] == "tockmox-actions-forge-jobs"
            for x in d["spec"]["validations"]):
        errs.append("11: with run-now off and the move on, tockmox-actions-forge-jobs is missing or admits an owner")
    # A site that lists a CronJob of its own in the forge's namespace, with the change kinds off, gets the pin too.
    rc, own = render(ON, {"tockmoxUi": {"actions": {"runJob": {"allow": [{"namespace": "tockmox-forge", "name": "my-job", "part": "site-repository"}]}}}})
    errs += [f"render with a run-now CronJob of the site's own in the forge's namespace failed: {own}"] if rc else check_forge_jobs(own)
    if not rc and not any(d["kind"] == "ValidatingAdmissionPolicy" and d["metadata"]["name"] == "tockmox-actions-forge-jobs" for d in own):
        errs.append("11: a run-now CronJob of the site's own in the forge's namespace rendered without tockmox-actions-forge-jobs")
    for label, overlays, want in (
            ("built-in, nothing set", (CHANGES_ON,), True),
            ("built-in, set off", (CHANGES_ON, {"tockmoxUi": {"actions": {"changes": {"enabled": False}}}}), False),
            ("external, nothing set", ({"global": {"siteForge": "external"}},), False),
            ("no siteForge, nothing set", (), False),
            ("external, set on", ({"global": {"siteForge": "external"}}, {"tockmoxUi": {"actions": {"changes": {"enabled": True}}}}), True)):
        rc, d = render(ON, *overlays)
        if rc:
            errs.append(f"9: the render with siteForge {label} failed: {d}")
            continue
        got = any(n == "tockmox-forge-console-oauth" for x, spec in _pods(d) for n in _secrets_of(spec))
        if got != want:
            errs.append(f"9: with siteForge {label}, the change kinds are {'on' if got else 'off'}, not {'on' if want else 'off'}")
    rc, layer = render(CONSOLE_ON, chart=ID_CHART, release="tockmox-identity", ns="tockmox-authentik")
    errs += [f"the identity layer with sso.consoleActions on failed to render: {layer}"] if rc else check_identity_layer(layer)
    rc, layer_off = render(chart=ID_CHART, release="tockmox-identity", ns="tockmox-authentik")
    errs += [f"the identity layer failed to render: {layer_off}"] if rc else check_identity_off(layer_off)
    for e in errs:
        print("  FAIL  " + e)
    print("check-actions: " + ("ok (the UI is read-only; tockmox-actions is narrow, bounded and reachable from the UI only; "
                               "the identity account is bounded by Authentik to non-administrators and the user group)"
                               if not errs else f"{len(errs)} problem(s)"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())

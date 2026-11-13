# SPDX-License-Identifier: Apache-2.0
"""The open-applications report as the identity layer renders it (charts/tockmox-identity/templates/
open-applications.yaml): one ConfigMap with no data, a Role that may only patch it, a Role that may only read it
bound to the console, and a CronJob that runs the shipped script with the server's credentials and no other
Kubernetes authority. `scope_errors` is the assertion; the planted renders below prove each part of it goes red."""
import copy
import json
import os
import shutil
import subprocess
import tempfile

import pytest
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHART = os.path.join(ROOT, "charts", "tockmox-identity")
SCRIPT = os.path.join(CHART, "files", "open-applications.py")
NS, CM, UI_NS = "tockmox-authentik", "tockmox-identity-open-applications", "tockmox-ai"
NAMES = ("tockmox-open-applications", "tockmox-open-applications-write", "tockmox-open-applications-read", CM)

if shutil.which("helm") is None:
    pytest.skip("helm is not on PATH", allow_module_level=True)


def render(*overlays):
    with tempfile.TemporaryDirectory() as d:
        args = ["helm", "template", "tockmox-identity", CHART, "--namespace", NS,
                "-f", os.path.join(ROOT, "ci", "values.yaml")]
        for i, o in enumerate(overlays):
            p = os.path.join(d, f"o{i}.yaml")
            with open(p, "w") as fh:
                yaml.safe_dump(o, fh)
            args += ["-f", p]
        r = subprocess.run(args, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return [x for x in yaml.safe_load_all(r.stdout) if x]


def ours(docs):
    return [d for d in docs if d["metadata"]["name"] in NAMES]


def find(docs, kind, name):
    return next((d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name), None)


def scope_errors(docs):
    errs = []
    cm = find(docs, "ConfigMap", CM)
    if cm is None or cm["metadata"].get("namespace") != NS:
        errs.append(f"no ConfigMap {NS}/{CM}")
    elif set(cm) - {"apiVersion", "kind", "metadata"}:
        errs.append("the chart renders the ConfigMap's content; Argo CD would revert what the Job writes")
    want = {"tockmox-open-applications-write": ("tockmox-open-applications", NS, ["patch"]),
            "tockmox-open-applications-read": ("tockmox-ui", UI_NS, ["get"])}
    for role, (sa, sa_ns, verbs) in want.items():
        r = find(docs, "Role", role)
        if r is None or r["metadata"].get("namespace") != NS:
            errs.append(f"no Role {NS}/{role}")
            continue
        if r["rules"] != [{"apiGroups": [""], "resources": ["configmaps"], "resourceNames": [CM], "verbs": verbs}]:
            errs.append(f"Role {role} is not exactly {verbs} on configmaps/{CM}: {r['rules']}")
        b = find(docs, "RoleBinding", role)
        if b is None or b["metadata"].get("namespace") != NS:
            errs.append(f"no RoleBinding {NS}/{role}")
            continue
        if b["roleRef"] != {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": role}:
            errs.append(f"RoleBinding {role} refers to {b['roleRef']}")
        if b["subjects"] != [{"kind": "ServiceAccount", "name": sa, "namespace": sa_ns}]:
            errs.append(f"RoleBinding {role} binds {b['subjects']}, not exactly {sa_ns}/{sa}")
    for d in docs:
        if d["kind"] in ("ClusterRoleBinding", "RoleBinding") and d["metadata"]["name"] not in want and any(
                s.get("name") == "tockmox-open-applications" for s in d.get("subjects") or []):
            errs.append(f"{d['kind']} {d['metadata']['name']} also grants the Job's ServiceAccount")
    cj = find(docs, "CronJob", "tockmox-open-applications")
    if cj is None:
        errs.append("no CronJob tockmox-open-applications")
        return errs
    pod = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    if pod.get("serviceAccountName") != "tockmox-open-applications":
        errs.append(f"the CronJob runs as {pod.get('serviceAccountName')!r}")
    if len(pod["containers"]) != 1 or pod.get("initContainers"):
        errs.append("the CronJob runs more than its one container")
    c = pod["containers"][0]
    with open(SCRIPT) as fh:
        if c.get("args") != ["shell", "-c", fh.read()]:
            errs.append("the CronJob does not run files/open-applications.py as shipped")
    env = {e["name"]: e.get("value") for e in c.get("env") or []}
    if env.get("TOCKMOX_REPORT_NAMESPACE") != NS or env.get("TOCKMOX_REPORT_CONFIGMAP") != CM:
        errs.append(f"the CronJob writes somewhere else: {env.get('TOCKMOX_REPORT_NAMESPACE')}/{env.get('TOCKMOX_REPORT_CONFIGMAP')}")
    names = {(e.get("secretRef") or {}).get("name") for e in c.get("envFrom") or []}
    if "tockmox-console-actions-token" in names:
        errs.append("the CronJob is given the console's token")
    return errs


@pytest.fixture(scope="module")
def on():
    return render()


def test_the_default_render_is_exactly_scoped(on):
    assert scope_errors(on) == []


def test_it_renders_with_the_consoles_identity_actions_off_and_on(on):
    assert render({"sso": {"consoleActions": {"enabled": False}}}) and scope_errors(on) == []
    both = render({"sso": {"consoleActions": {"enabled": True}}})
    assert scope_errors(both) == []
    assert find(both, "CronJob", "tockmox-console-identity-grants") is not None


def test_the_declared_slugs_reach_the_job():
    docs = render({"sso": {"access": {"everyone": ["handbook", "status-page"]}}})
    c = find(docs, "CronJob", "tockmox-open-applications")["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e.get("value") for e in c["env"]}
    assert json.loads(env["TOCKMOX_OPEN_TO_EVERYONE"]) == ["handbook", "status-page"]
    c0 = _pod(render())["containers"][0]
    assert json.loads({e["name"]: e.get("value") for e in c0["env"]}["TOCKMOX_OPEN_TO_EVERYONE"]) == []


def test_the_console_namespace_follows_the_value():
    docs = render({"sso": {"access": {"report": {"consoleNamespace": "ai-plane"}}}})
    b = find(docs, "RoleBinding", "tockmox-open-applications-read")
    assert b["subjects"] == [{"kind": "ServiceAccount", "name": "tockmox-ui", "namespace": "ai-plane"}]


@pytest.mark.parametrize("overlay", [
    {"sso": {"access": {"report": {"enabled": False}}}},
    {"apps": {"authentik": {"enabled": False}}},
    {"capabilities": {"identity": {"enabled": False}}},
], ids=["report-off", "authentik-off", "identity-off"])
def test_off_means_absent(overlay):
    assert ours(render(overlay)) == []


@pytest.mark.parametrize("bad", [
    {"sso": {"access": {"report": {"enable": True}}}},
    {"sso": {"access": {"everyone": "handbook"}}},
    {"sso": {"access": {"everyone": ["two words"]}}},
    {"sso": {"access": {"report": {"consoleNamespace": "Not_A_Namespace"}}}},
], ids=["typo", "not-a-list", "not-a-slug", "bad-namespace"])
def test_the_schema_refuses_a_wrong_value(bad):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "o.yaml")
        with open(p, "w") as fh:
            yaml.safe_dump(bad, fh)
        r = subprocess.run(["helm", "template", "tockmox-identity", CHART, "--namespace", NS,
                            "-f", os.path.join(ROOT, "ci", "values.yaml"), "-f", p], capture_output=True, text=True)
    assert r.returncode != 0 and "schema" in r.stderr.lower(), r.stderr[-400:]


# ---------------------------------------------------------------------------------- planted reds
def _role(docs, name):
    return find(docs, "Role", name)


def _pod(docs):
    return find(docs, "CronJob", "tockmox-open-applications")["spec"]["jobTemplate"]["spec"]["template"]["spec"]


PLANTS = {
    "write-role-gains-a-verb": lambda d: _role(d, "tockmox-open-applications-write")["rules"][0]["verbs"].append("update"),
    "write-role-loses-its-name": lambda d: _role(d, "tockmox-open-applications-write")["rules"][0].pop("resourceNames"),
    "write-role-gains-a-resource": lambda d: _role(d, "tockmox-open-applications-write")["rules"][0]["resources"].append("secrets"),
    "write-role-gains-a-rule": lambda d: _role(d, "tockmox-open-applications-write")["rules"].append(
        {"apiGroups": [""], "resources": ["configmaps"], "verbs": ["create"]}),
    "read-role-gains-list": lambda d: _role(d, "tockmox-open-applications-read")["rules"][0]["verbs"].append("list"),
    "read-role-loses-its-name": lambda d: _role(d, "tockmox-open-applications-read")["rules"][0].pop("resourceNames"),
    "read-binding-gains-a-subject": lambda d: find(d, "RoleBinding", "tockmox-open-applications-read")["subjects"].append(
        {"kind": "ServiceAccount", "name": "default", "namespace": UI_NS}),
    "write-binding-to-a-clusterrole": lambda d: find(d, "RoleBinding", "tockmox-open-applications-write").__setitem__(
        "roleRef", {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "edit"}),
    "job-sa-gains-a-clusterrolebinding": lambda d: d.append(
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": "x"},
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "view"},
         "subjects": [{"kind": "ServiceAccount", "name": "tockmox-open-applications", "namespace": NS}]}),
    "configmap-gains-data": lambda d: find(d, "ConfigMap", CM).__setitem__("data", {"report.json": "{}"}),
    "configmap-missing": lambda d: d.remove(find(d, "ConfigMap", CM)),
    "job-runs-as-another-account": lambda d: _pod(d).__setitem__("serviceAccountName", "tockmox-console-identity-grants"),
    "job-script-edited": lambda d: _pod(d)["containers"][0]["args"].__setitem__(2, "print('hi')"),
    "job-writes-elsewhere": lambda d: [e.__setitem__("value", "other") for e in _pod(d)["containers"][0]["env"]
                                       if e["name"] == "TOCKMOX_REPORT_CONFIGMAP"],
    "job-given-the-console-token": lambda d: _pod(d)["containers"][0]["envFrom"].append(
        {"secretRef": {"name": "tockmox-console-actions-token", "optional": True}}),
}


@pytest.mark.parametrize("plant", sorted(PLANTS))
def test_each_planted_widening_goes_red(on, plant):
    docs = copy.deepcopy(on)
    PLANTS[plant](docs)
    assert scope_errors(docs), f"{plant} was not caught"


# ---------------------------------------------------------------------------------- the console's side
def _ui_sources(*overlays):
    base = {"global": {"internalDomain": "int.example.com", "lanCIDR": "192.0.2.0/24"},
            "tockmoxUi": {"enabled": True, "image": "registry.example/tockmox-ui:check",
                          "config": {"oidc": {"issuer": "https://auth.int.example.com/application/o/tockmox-ui"}}}}
    with tempfile.TemporaryDirectory() as d:
        args = ["helm", "template", "tockmox-ai", os.path.join(ROOT, "charts", "tockmox-ai"), "--namespace", UI_NS,
                "-f", os.path.join(ROOT, "ci", "values.yaml")]
        for i, o in enumerate((base,) + overlays):
            p = os.path.join(d, f"o{i}.yaml")
            with open(p, "w") as fh:
                yaml.safe_dump(o, fh)
            args += ["-f", p]
        r = subprocess.run(args, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    cm = next(x for x in yaml.safe_load_all(r.stdout) if x and x["kind"] == "ConfigMap" and x["metadata"]["name"] == "tockmox-ui")
    return yaml.safe_load(next(iter(cm["data"].values())))["sources"]


def test_the_console_reads_the_list_with_the_identity_capability_and_a_site_can_turn_it_off():
    assert _ui_sources()["openApplications"] == {"enabled": True}
    assert _ui_sources({"capabilities": {"identity": {"enabled": False}}})["openApplications"] == {"enabled": False}
    off = {"tockmoxUi": {"config": {"sources": {"openApplications": {"enabled": False}}}}}
    assert _ui_sources(off)["openApplications"] == {"enabled": False}

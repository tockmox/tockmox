#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, the site-facing seams added for 0.7.1 that
# no other gate covers. Each one was a gap a site worked around in its own
# values or manifests (TM-0820), and each renders cleanly when it is wrong.
#
#   ./tools/check-platform-seams.sh             run the assertions
#   ./tools/check-platform-seams.sh --selftest  prove each can go red
#
# S1  global.namespaceLabels lands on EVERY Namespace the policy and platform
#     layers create, and a label the chart owns is refused (TM-0816).
# S2  garage.credentialsNamespaceLabels lands on that one namespace only,
#     including pod-security.kubernetes.io/* (TM-0815).
# S3  The consoles Probe follows ingress.apps.<app>.host, and still derives
#     <svc>.<domain> when unset (TM-0820, last row).
# S4  Every chart dashboard ConfigMap key is prefixed `tockmox-`.
# S5  The CNPG operator PodMonitor renders by default.
# S6  apps.etcdScrapeConfig renders a ScrapeConfig job kube-etcd with the listed
#     targets, and refuses an empty list.
# S7  platformNetpol.extraPrometheusNamespaces adds a peer to the devops and
#     platform scrape rules (TM-0820, inventory-devops 4.10 item 4).
# S8  The shipped Longhorn StorageClass reclaims with Retain (TM-0789).
# S9  platformNetpol.extraMonitoringClientNamespaces renders allow-from-site-clients
#     in the monitoring namespace (observability-cutover A1).
# S10 kube-prometheus-stack.prometheus.service.sessionAffinity=ClientIP renders on
#     the Prometheus Service (the one that selects the Prometheus pods) with its
#     timeout, beside prometheusSpec.replicas 2; and the DEFAULT render keeps one
#     replica and no affinity, so the knob stays opt-in (TM-0781).
#
# S11 The default Prometheus image is v3.15.0 or newer, not the subchart's
#     v3.14.0 (TM-0820 A5; default change).
# S12 The consoles Probe uses a module that accepts 401 (and 200/301/302), and
#     http_2xx is NOT widened for everyone (TM-0820 A6; default change).
# S13 devops renders the argo-workflows CRDs inline and no crd-install hook Job
#     that downloads them (crds.full false, TM-0820; default change).
# S14 The workflow controller ServiceMonitor renders honorLabels: true
#     (TM-0820; default change).
# S15 The workflow controller and server both set the infrastructure
#     PriorityClass, and tockmox-policy renders a PriorityClass of that name
#     (TM-0820; default change).
#
# S18 The node agents (node-exporter, Alloy's log DaemonSet, the SMART exporter) render in
#     the node-agents namespace and no pod that reads the host is left in the monitoring
#     namespace; the policy layer labels the first privileged and the second baseline, and
#     the two crossings (Alloy to the Loki gateway, Prometheus to the SMART exporter) have
#     allow rules (TM-0799).
#
# S19 The Garage bootstrap Job provisions the restore-drill register (TM-0459): a bucket
#     of its own (never the backup bucket), a key with read and write and NOT owner on it,
#     a Secret of its own, and a copy of that Secret into the model gateway's and the
#     identity namespaces, with the Role in each that lets the Job create it there. The
#     drills' side of the same wire (the bucket and Secret names they read) is
#     tools/check-notify-and-drill.sh D4.
#
# `--selftest` feeds each assertion the render it must refuse (the same chart
# with the seam left unset, or the value reverted) and requires a non-zero
# answer, so a check that could never fail is found here and not in review.
#
# LIMIT: render only. No API server sees these objects, so admission of the
# labels, the CRDs for PodMonitor and ScrapeConfig, and Prometheus actually
# scraping are the live window's to prove.
# shellcheck disable=SC2329  # each s_N check is called by name, through must_hold and must_refuse and the run list
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-platform-seams: helm missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-platform-seams: python3 PyYAML missing" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
r() { local out="$1" chart="$2"; shift 2; helm template t "charts/tockmox-$chart" -f ci/values.yaml "$@" > "$T/$out" 2>"$T/$out.err" || { cat "$T/$out.err" >&2; return 1; }; }
have() { grep -qE -- "$2" "$1"; }

# Each s_N takes the render file(s) and returns 0 (holds) or 1 (violated).
ns_labels() { python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
f, key, val = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(f)) if d and d.get("kind") == "Namespace"]
if not docs: sys.exit(1)
sys.exit(0 if all(str(d["metadata"].get("labels", {}).get(key)) == val for d in docs) else 1)
PY
}
ns_one() { python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys, yaml
f, name, key, val = sys.argv[1:5]
docs = {d["metadata"]["name"]: d for d in yaml.safe_load_all(open(f)) if d and d.get("kind") == "Namespace"}
d = docs.get(name)
if not d: sys.exit(1)
ok = str(d["metadata"].get("labels", {}).get(key)) == val
others = [n for n, o in docs.items() if n != name and key in o["metadata"].get("labels", {})]
sys.exit(0 if ok and not others else 1)
PY
}
s1() { ns_labels "$1" zarf.dev/agent ignore && ns_labels "$2" zarf.dev/agent ignore; }
s2() { ns_one "$1" site-x pod-security.kubernetes.io/warn restricted; }
s3() { have "$1" '"https://ai\.example\.org"' && have "$1" '"https://auth\.int\.example\.com(/-/health/ready/)?"' && ! have "$1" '"https://chat\.'; }
s4() { python3 - "$1" <<'PY'
import sys, yaml
cms = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"].startswith("tockmox-dashboard-")]
sys.exit(0 if cms and all(k.startswith("tockmox-") for d in cms for k in d["data"]) else 1)
PY
}
s5() { have "$1" '^kind: PodMonitor' && have "$1" 'name: t-cloudnative-pg'; }
s6() { have "$1" '^kind: ScrapeConfig' && have "$1" 'jobName: kube-etcd' && have "$1" '"10\.0\.0\.1:2381"' && have "$1" '"10\.0\.0\.2:2381"'; }
s7() { [ "$(grep -c 'kubernetes.io/metadata.name: site-monitoring' "$1")" -ge 2 ]; }
s9() { have "$1" 'name: allow-from-site-clients' && have "$1" 'kubernetes.io/metadata.name: site-ai'; }
s10_docs() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
svc = [x for x in d if x.get("kind") == "Service" and x["spec"].get("selector", {}).get("app.kubernetes.io/name") == "prometheus"]
prom = [x for x in d if x.get("kind") == "Prometheus"]
if len(svc) != 1 or len(prom) != 1: sys.exit(1)
sp = svc[0]["spec"]
ok = sp.get("sessionAffinity") == "ClientIP" and sp.get("sessionAffinityConfig", {}).get("clientIP", {}).get("timeoutSeconds") == 10800
sys.exit(0 if ok and prom[0]["spec"].get("replicas") == 2 else 1)
PY
}
s10_default() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
svc = [x for x in d if x.get("kind") == "Service" and x["spec"].get("selector", {}).get("app.kubernetes.io/name") == "prometheus"]
prom = [x for x in d if x.get("kind") == "Prometheus"]
if len(svc) != 1 or len(prom) != 1: sys.exit(1)
sys.exit(0 if svc[0]["spec"].get("sessionAffinity") in (None, "None") and prom[0]["spec"].get("replicas") == 1 else 1)
PY
}
s8() { have "$1" 'reclaimPolicy: "Retain"' && ! have "$1" 'reclaimPolicy: "Delete"'; }

s11() { python3 - "$1" <<'PY'
import sys, re, yaml
p = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x and x.get("kind") == "Prometheus"]
if len(p) != 1: sys.exit(1)
def ver(t):
    m = re.search(r"v(\d+)\.(\d+)\.(\d+)", t or "")
    return tuple(int(i) for i in m.groups()) if m else (0, 0, 0)
sp = p[0]["spec"]
sys.exit(0 if ver(sp.get("image")) >= (3, 15, 0) and ver(sp.get("version")) >= (3, 15, 0) else 1)
PY
}
s12() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
probe = [x for x in d if x.get("kind") == "Probe" and x["metadata"]["name"] == "tockmox-consoles"]
cm = [x for x in d if x.get("kind") == "ConfigMap" and "blackbox.yaml" in x.get("data", {})]
if len(probe) != 1 or len(cm) != 1: sys.exit(1)
mods = yaml.safe_load(cm[0]["data"]["blackbox.yaml"])["modules"]
m = mods.get(probe[0]["spec"]["module"])
if not m: sys.exit(1)
codes = set(m.get("http", {}).get("valid_status_codes") or [])
shared = set(mods.get("http_2xx", {}).get("http", {}).get("valid_status_codes") or [])
sys.exit(0 if {200, 301, 302, 401} <= codes and 401 not in shared and m["http"].get("follow_redirects") is True else 1)
PY
}
# S16 (TM-0905): Authentik's console is probed at its readiness endpoint, not at
# `/`, which redirects into whatever onboarding flow it is in (on the lab,
# `/setup`, answering 500). Every other console target keeps no path.
s16() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
probe = [x for x in d if x.get("kind") == "Probe" and x["metadata"]["name"] == "tockmox-consoles"]
if len(probe) != 1: sys.exit(1)
t = probe[0]["spec"]["targets"]["staticConfig"]["static"]
auth = [u for u in t if "://auth." in u]
rest = [u for u in t if "://auth." not in u]
ok = len(auth) == 1 and auth[0].endswith("/-/health/ready/") and rest and all(u.count("/") == 2 for u in rest)
sys.exit(0 if ok else 1)
PY
}
# S17 (2026-10-06, inverted 2026-10-08): the LiteLLM console probe follows the
# gateway's switch as every layer sees it. Through 0.7.x the AI layer shipped
# `apps.litellm.enabled: false`, a default this layer could not see, so the
# probe fell back to the aiPlane capability and paged TockmoxConsoleUnreachable
# for llm.<domain> on every install that never deployed LiteLLM (TM-0910).
# Since 0.8.0 the gateway follows the capability (TM-0460), so the smallest
# real site, which never mentions LiteLLM, IS probed; and a site that turns the
# gateway off in a values file this layer reads is NOT. Both halves, because
# either one alone holds on a probe that ignores the switch.
s17() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
probe = [x for x in d if x.get("kind") == "Probe" and x["metadata"]["name"] == "tockmox-consoles"]
if len(probe) != 1: sys.exit(1)
t = probe[0]["spec"]["targets"]["staticConfig"]["static"]
sys.exit(0 if t and any("://llm." in u for u in t) else 1)
PY
}
s17_off() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
probe = [x for x in d if x.get("kind") == "Probe" and x["metadata"]["name"] == "tockmox-consoles"]
if len(probe) != 1: sys.exit(1)
t = probe[0]["spec"]["targets"]["staticConfig"]["static"]
sys.exit(0 if t and not any("://llm." in u for u in t) else 1)
PY
}
s13() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
crds = [x for x in d if x.get("kind") == "CustomResourceDefinition" and x["spec"]["group"] == "argoproj.io"]
jobs = [x for x in d if x.get("kind") == "Job" and x["metadata"]["name"].endswith("crd-install")]
sys.exit(0 if len(crds) >= 8 and not jobs else 1)
PY
}
s14() { python3 - "$1" <<'PY'
import sys, yaml
sm = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x and x.get("kind") == "ServiceMonitor" and x["metadata"]["name"].endswith("workflow-controller")]
if len(sm) != 1: sys.exit(1)
ep = sm[0]["spec"]["endpoints"]
sys.exit(0 if ep and all(e.get("honorLabels") is True for e in ep) else 1)
PY
}
s15() { python3 - "$1" "$2" <<'PY'
import sys, yaml
dev = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x and x.get("kind") == "Deployment" and "argo-workflows" in x["metadata"]["name"]]
pcs = {x["metadata"]["name"] for x in yaml.safe_load_all(open(sys.argv[2])) if x and x.get("kind") == "PriorityClass"}
names = {x["metadata"]["name"]: x["spec"]["template"]["spec"].get("priorityClassName") for x in dev}
want = "tockmox-infrastructure"
ok = len(names) == 2 and all(v == want for v in names.values()) and want in pcs
sys.exit(0 if ok else 1)
PY
}

# S18 (TM-0799): the privileged node agents live in their own namespace. Arguments: the
# observability render, the exporters render (both with -n tockmox-monitoring, so an object
# without a namespace lands there as it does under Argo CD), the policy render.
s18() { python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
MON, NODE = "tockmox-monitoring", "tockmox-node-agents"
def docs(f): return [x for x in yaml.safe_load_all(open(f)) if x]
obs, exp, pol = (docs(a) for a in sys.argv[1:4])
def ns(d): return d["metadata"].get("namespace") or MON
def podspec(d):
    if d.get("kind") in ("Deployment", "StatefulSet", "DaemonSet", "Job"): return d["spec"]["template"]["spec"]
    if d.get("kind") == "CronJob": return d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None
def reads_host(sp):
    if sp.get("hostNetwork") or sp.get("hostPID") or sp.get("hostIPC"): return True
    if any("hostPath" in v for v in sp.get("volumes") or []): return True
    return any((c.get("securityContext") or {}).get("privileged") for c in (sp.get("containers") or []) + (sp.get("initContainers") or []))
bad = []
for d in obs + exp:
    sp = podspec(d)
    if sp and reads_host(sp) and ns(d) == MON:
        bad.append("%s/%s reads the host and is in %s" % (d["kind"], d["metadata"]["name"], MON))
agents = {"node-exporter": False, "alloy": False, "smartctl-exporter": False}
for d in obs + exp:
    if d.get("kind") == "DaemonSet":
        for a in agents:
            if a in d["metadata"]["name"]:
                agents[a] = (ns(d) == NODE)
bad += ["%s DaemonSet is not rendered in %s" % (a, NODE) for a, ok in agents.items() if not ok]
for d in obs:
    if d.get("kind") == "ConfigMap" and d["metadata"]["name"].endswith("-alloy"):
        txt = "".join(d.get("data", {}).values())
        if "loki-gateway.%s.svc" % MON not in txt:
            bad.append("Alloy pushes to a Loki gateway address that does not name %s" % MON)
names = {d["metadata"]["name"]: d for d in pol if d.get("kind") == "Namespace"}
lab = lambda n: ((names.get(n) or {}).get("metadata", {}).get("labels") or {}).get("pod-security.kubernetes.io/enforce")
if lab(NODE) != "privileged": bad.append("%s is not labelled enforce privileged (%r)" % (NODE, lab(NODE)))
if lab(MON) not in ("baseline", "restricted"): bad.append("%s does not enforce baseline or restricted (%r)" % (MON, lab(MON)))
np = {(d["metadata"]["namespace"], d["metadata"]["name"]) for d in pol if d.get("kind") == "NetworkPolicy"}
for want in ((NODE, "default-deny-ingress"), (NODE, "allow-from-prometheus"), (MON, "allow-from-node-agents")):
    if want not in np: bad.append("NetworkPolicy %s/%s is not rendered" % want)
for b in bad: print("   ", b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

s19() { python3 - "$1" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
job = [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"] == "tockmox-garage-bootstrap"]
if len(job) != 1: sys.exit(1)
c = job[0]["spec"]["template"]["spec"]["containers"][0]
env = {e["name"]: e.get("value") for e in c["env"]}
bad = []
if not env.get("DR_BUCKET") or env["DR_BUCKET"] == env.get("BUCKET"): bad.append("the register is not in a bucket of its own: %r vs %r" % (env.get("DR_BUCKET"), env.get("BUCKET")))
if not env.get("DR_SEC") or env["DR_SEC"] == env.get("CREDS"): bad.append("the register has no Secret of its own")
copy = (env.get("DR_COPY_TO") or "").split()
for ns in ("tockmox-ai", "tockmox-authentik"):
    if ns not in copy: bad.append("the register Secret is not copied to %s" % ns)
sc = c["args"][0]
i, j = sc.find("5b. the restore-drill register"), sc.find("---- 6. hand the credentials")
step = sc[i:j] if 0 <= i < j else ""
for need in ('GetBucketInfo?globalAlias=$DR_BUCKET', 'CreateBucket', 'v2/CreateKey', '\\"name\\":\\"tockmox-drill-register\\"', 'AllowBucketKey', '\\"read\\":true,\\"write\\":true,\\"owner\\":false', 'create secret generic "$DR_SEC"', 'create secret generic "$DR_SEC"'):
    if need not in step: bad.append("step 5b lacks %r" % need)
if '\\"owner\\":true' in step: bad.append("step 5b grants owner")
role = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in docs if d.get("kind") == "Role"}
def named(ns):
    r = role.get((ns, "tockmox-garage-bootstrap"))
    out = set()
    for rule in (r or {}).get("rules", []):
        if "secrets" in rule.get("resources", []): out |= set(rule.get("resourceNames", []))
    return out
rel = job[0]["metadata"]["namespace"]
for ns in [rel] + [n for n in copy if n != rel]:
    if env.get("DR_SEC") not in named(ns): bad.append("the Job's Role in %s cannot read the register Secret" % ns)
for b in bad: print("   ", b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

# Renders. "good" has the seam in use; "bad" is what the assertion must refuse.
LAB=(--set 'global.namespaceLabels.zarf\.dev/agent=ignore')
r pol.good policy "${LAB[@]}"
r plat.good platform "${LAB[@]}" --set 'garage.credentialsNamespaces={tockmox-ai,tockmox-authentik,site-x,site-y}' --set 'garage.createCredentialsNamespaces={site-x,site-y}' \
  --set 'garage.credentialsNamespaceLabels.site-x.pod-security\.kubernetes\.io/warn=restricted'
r pol.bad policy
r plat.noreg platform --set garage.drillRegister.enabled=false
r plat.bad platform --set 'garage.credentialsNamespaces={tockmox-ai,tockmox-authentik,site-x,site-y}' --set 'garage.createCredentialsNamespaces={site-x,site-y}'
r probe.good exporters --set ingress.apps.openWebui.host=ai.example.org
r probe.bad exporters
r probe.allon exporters -f ci/values-all-on.yaml
# The smallest real site, which never mentions LiteLLM (S17): since 0.8.0 the
# gateway follows the capability, so this render must probe it. Not through
# r(): r() layers ci/values.yaml, which sets the switch explicitly.
helm template t charts/tockmox-exporters -f ci/values-site-minimal.yaml > "$T/probe.nollm" 2>"$T/probe.nollm.err" || { cat "$T/probe.nollm.err" >&2; exit 1; }
# The same site with the gateway turned off where this layer can see it.
helm template t charts/tockmox-exporters -f ci/values-site-minimal.yaml --set apps.litellm.enabled=false > "$T/probe.llmoff" 2>"$T/probe.llmoff.err" || { cat "$T/probe.llmoff.err" >&2; exit 1; }
r dash.good observability
r pm.good platform
r etcd.good observability --set apps.etcdScrapeConfig.enabled=true --set 'apps.etcdScrapeConfig.targets={10.0.0.1:2381,10.0.0.2:2381}'
r etcd.bad observability
r np.good policy -f ci/values-all-on.yaml --set 'platformNetpol.extraPrometheusNamespaces={site-monitoring}'
r np.bad policy -f ci/values-all-on.yaml
r lh.good platform
r aff.good observability --set kube-prometheus-stack.prometheus.prometheusSpec.replicas=2 --set kube-prometheus-stack.prometheus.service.sessionAffinity=ClientIP
r aff.bad observability --set kube-prometheus-stack.prometheus.prometheusSpec.replicas=2
r prom.bad observability --set kube-prometheus-stack.prometheus.prometheusSpec.image.tag=v3.14.0-distroless
r bb.bad exporters --set probes.module=http_2xx
r argo.good devops --api-versions monitoring.coreos.com/v1
r argo.bad devops --api-versions monitoring.coreos.com/v1 --set argo-workflows.crds.full=true \
  --set argo-workflows.controller.metricsConfig.honorLabels=false \
  --set argo-workflows.controller.priorityClassName= --set argo-workflows.server.priorityClassName=
r mc.good policy -f ci/values-all-on.yaml --set 'platformNetpol.extraMonitoringClientNamespaces={site-ai}'
# S18 (TM-0799): rendered into the monitoring namespace, as Argo CD does, with every shipped app on.
rn() { local out="$1" chart="$2"; shift 2; helm template t "charts/tockmox-$chart" -n tockmox-monitoring -f ci/values.yaml -f ci/values-all-on.yaml "$@" > "$T/$out" 2>"$T/$out.err" || { cat "$T/$out.err" >&2; return 1; }; }
rn na.obs observability
rn na.exp exporters
rn na.pol policy
{ cat "$T/na.obs"; printf '%s\n' '---' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata:' '  name: planted' 'spec:' '  template:' '    spec:' '      containers: [{name: x, image: x}]' '      volumes: [{name: h, hostPath: {path: /}}]'; } > "$T/na.planted"
# The old layout restored: the two overrides emptied, so both DaemonSets land in the monitoring namespace.
rn na.obs.bad observability --set kube-prometheus-stack.prometheus-node-exporter.namespaceOverride= --set alloy.namespaceOverride=
# The policy layer without the namespace: no label, no allow rules.
rn na.pol.bad policy --set namespaces.node_agents= --set podSecurity.enforce.monitoring=

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  must_hold()   { "$@" || { echo "selftest FAIL: $1 did not hold on the good render"; fail=1; }; }
  must_refuse() { local n="$1"; shift; if "$@"; then echo "selftest FAIL: $n passed on a render it must refuse"; fail=1; else echo "selftest ok: $n goes red"; fi; }
  must_hold s1 "$T/pol.good" "$T/plat.good"
  must_hold s2 "$T/plat.good"
  must_hold s19 "$T/plat.good"
  must_hold s3 "$T/probe.good"
  must_hold s4 "$T/dash.good"
  must_hold s5 "$T/pm.good"
  must_hold s6 "$T/etcd.good"
  must_hold s7 "$T/np.good"
  must_hold s8 "$T/lh.good"
  must_hold s9 "$T/mc.good"
  must_hold s10_docs "$T/aff.good"
  must_hold s10_default "$T/dash.good"
  must_hold s11 "$T/dash.good"
  must_hold s12 "$T/probe.bad"
  must_hold s13 "$T/argo.good"
  must_hold s14 "$T/argo.good"
  must_hold s15 "$T/argo.good" "$T/pol.bad"
  must_hold s16 "$T/probe.allon"
  must_hold s18 "$T/na.obs" "$T/na.exp" "$T/na.pol" 2>/dev/null
  must_refuse S1 s1 "$T/pol.bad" "$T/plat.bad"
  must_refuse S2 s2 "$T/plat.bad"
  must_refuse "S19 (garage.drillRegister.enabled false)" s19 "$T/plat.noreg"
  sed '/5b. the restore-drill register/,/---- 6. hand the credentials/ s/\\"owner\\":false/\\"owner\\":true/' "$T/plat.good" > "$T/plat.owner"; must_refuse "S19 (the register key granted owner)" s19 "$T/plat.owner"
  sed 's/DR_SEC,    value: "tockmox-drill-register-credentials"/DR_SEC,    value: "tockmox-garage-credentials"/' "$T/plat.good" > "$T/plat.sharedsec"; must_refuse "S19 (the register sharing the backups' Secret)" s19 "$T/plat.sharedsec"
  sed 's/DR_COPY_TO, value: "tockmox-ai tockmox-authentik"/DR_COPY_TO, value: "tockmox-ai"/' "$T/plat.good" > "$T/plat.nocopy"; must_refuse "S19 (the Secret not copied to the identity namespace)" s19 "$T/plat.nocopy"
  must_refuse S3 s3 "$T/probe.bad"
  # S4: a bare key must trip it
  printf 'kind: ConfigMap\nmetadata:\n  name: tockmox-dashboard-authentik\ndata:\n  authentik.json: x\n' > "$T/dash.bad"; must_refuse S4 s4 "$T/dash.bad"
  # S5: the old default rendered no PodMonitor
  helm template t charts/tockmox-platform -f ci/values.yaml --set cloudnative-pg.monitoring.podMonitorEnabled=false > "$T/pm.bad"; must_refuse S5 s5 "$T/pm.bad"
  must_refuse S6 s6 "$T/etcd.bad"
  must_refuse S7 s7 "$T/np.bad"
  helm template t charts/tockmox-platform -f ci/values.yaml --set longhorn.persistence.reclaimPolicy=Delete > "$T/lh.bad"; must_refuse S8 s8 "$T/lh.bad"
  must_refuse S9 s9 "$T/np.bad"
  must_refuse S10 s10_docs "$T/aff.bad"
  must_refuse "S10 default (replicas 2 is not the default)" s10_default "$T/aff.bad"
  # S11-S15 are default changes: the "bad" render is the old default restored.
  must_refuse S11 s11 "$T/prom.bad"
  must_refuse S12 s12 "$T/bb.bad"
  must_refuse S13 s13 "$T/argo.bad"
  must_refuse S14 s14 "$T/argo.bad"
  must_refuse S15 s15 "$T/argo.bad" "$T/pol.bad"
  sed 's#/-/health/ready/##' "$T/probe.allon" > "$T/probe.rootauth"; must_refuse S16 s16 "$T/probe.rootauth"
  must_refuse "S18 (the agents back in the monitoring namespace)" s18 "$T/na.obs.bad" "$T/na.exp" "$T/na.pol" 2>/dev/null
  must_refuse "S18 (no node-agents namespace in the policy layer)" s18 "$T/na.obs" "$T/na.exp" "$T/na.pol.bad" 2>/dev/null
  must_refuse "S18 (a hostPath pod planted in the monitoring namespace)" s18 "$T/na.planted" "$T/na.exp" "$T/na.pol" 2>/dev/null
  must_refuse "S17 (default probes the gateway)" s17 "$T/probe.llmoff"
  must_refuse "S17 (apps.litellm.enabled false drops the probe)" s17_off "$T/probe.nollm"
  # The refusals (a chart-owned label; an empty etcd target list) must be errors.
  if r x policy --set 'global.namespaceLabels.tockmox\.com/layer=evil' 2>/dev/null; then echo "selftest FAIL: owned label accepted"; fail=1; else echo "selftest ok: an owned namespace label is refused"; fi
  if r x observability --set apps.etcdScrapeConfig.enabled=true 2>/dev/null; then echo "selftest FAIL: empty etcd targets accepted"; fail=1; else echo "selftest ok: empty etcd targets are refused"; fi
  if rn x exporters --set namespaces.nodeAgents= 2>/dev/null; then echo "selftest FAIL: an empty namespaces.nodeAgents rendered the SMART exporter"; fail=1; else echo "selftest ok: an empty namespaces.nodeAgents is refused when the SMART exporter is on"; fi
  if rn x observability --set namespaces.nodeAgents=elsewhere 2>/dev/null; then echo "selftest FAIL: a node agents namespace that differs from the subcharts' override was accepted"; fail=1; else echo "selftest ok: a node agents namespace that differs from the subcharts' override is refused"; fi
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

rc=0
chk() { local n="$1"; shift; if "$@"; then echo "  ok $n"; else echo "FAIL $n"; rc=1; fi; }
chk "S1 global.namespaceLabels on every policy and platform Namespace" s1 "$T/pol.good" "$T/plat.good"
chk "S2 per-namespace labels (Pod Security) on one credentials namespace only" s2 "$T/plat.good"
chk "S19 the Garage bootstrap provisions the restore-drill register: own bucket, own read/write key, own Secret, copied to the drill namespaces" s19 "$T/plat.good"
chk "S3 console probes follow ingress.apps.<app>.host" s3 "$T/probe.good"
chk "S4 dashboard ConfigMap keys are prefixed tockmox-" s4 "$T/dash.good"
chk "S5 CNPG operator PodMonitor renders by default" s5 "$T/pm.good"
chk "S6 etcd ScrapeConfig renders with the listed targets" s6 "$T/etcd.good"
chk "S7 extraPrometheusNamespaces reaches the devops and platform scrape rules" s7 "$T/np.good"
chk "S8 Longhorn StorageClass reclaims with Retain" s8 "$T/lh.good"
chk "S9 extraMonitoringClientNamespaces renders allow-from-site-clients" s9 "$T/mc.good"
chk "S10 sessionAffinity ClientIP renders on the Prometheus Service beside replicas 2" s10_docs "$T/aff.good"
chk "S10 the default render keeps one Prometheus replica and no affinity" s10_default "$T/dash.good"
chk "S11 default Prometheus image is v3.15.0 or newer" s11 "$T/dash.good"
chk "S12 consoles Probe module accepts 401 and http_2xx is not widened" s12 "$T/probe.bad"
chk "S13 devops renders the Argo CRDs inline and no crd-install Job" s13 "$T/argo.good"
chk "S14 workflow controller ServiceMonitor honors labels" s14 "$T/argo.good"
chk "S15 workflow controller and server use the infrastructure PriorityClass" s15 "$T/argo.good" "$T/pol.bad"
chk "S16 Authentik's console probe targets its readiness endpoint, not its onboarding redirect" s16 "$T/probe.allon"
chk "S17 the smallest real site probes the gateway (it follows the capability since 0.8.0)" s17 "$T/probe.nollm"
chk "S17 apps.litellm.enabled false in a file this layer reads drops the gateway probe" s17_off "$T/probe.llmoff"
chk "S18 the node agents run in the node-agents namespace; nothing that reads the host is left in the monitoring namespace; the crossings are allowed" s18 "$T/na.obs" "$T/na.exp" "$T/na.pol"
# Owned labels and empty targets must fail the render, not pass quietly.
if r x policy --set 'global.namespaceLabels.tockmox\.com/layer=evil' 2>/dev/null; then echo "FAIL S1 owned label accepted"; rc=1; else echo "  ok S1 an owned namespace label is refused"; fi
if r x observability --set apps.etcdScrapeConfig.enabled=true 2>/dev/null; then echo "FAIL S6 empty targets accepted"; rc=1; else echo "  ok S6 empty etcd targets are refused"; fi
exit $rc

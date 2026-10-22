#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The model gateway is the shipped default, and the console goes through it
# (TM-0460; REQ-0004 AC-4.1 under the D1 reading ruled 2026-10-08: the shipped
# default routes the console through the gateway, and a site may override).
# Asserted ON THE RENDERED ARTIFACT, because every one of these renders clean
# when it is wrong: a console pointed at nothing, a Job with a Role wider than
# one Secret, a profile that quietly keeps the 0.7.x default.
#
#   ./tools/check-gateway-default.sh             run the assertions
#   ./tools/check-gateway-default.sh --selftest  prove each can go red
#
# G1  The smallest real site (ci/values-site-minimal.yaml, which never
#     mentions LiteLLM) renders the gateway Deployment, and the console's
#     OPENAI_API_BASE_URL is that release's gateway Service with the key read
#     from the console-key Secret.
# G2  profiles/minimal.yaml and profiles/household-sso.yaml render the same
#     way (ruling C1: the gateway is on in every profile).
# G3  The console-key Job renders (ruling B1): it waits for the gateway's
#     readiness before it calls /key/generate, reads the master key from the
#     gateway's own Secret, is an ordinary resource (no hook, no TTL,
#     OnFailure, the migrations Job's retry budget), its Role is `get` and
#     `update` on the one Secret name plus `create` on secrets plus `delete`
#     on the console's pod names and nothing else, the RoleBinding binds its
#     ServiceAccount, and the policy layer renders the egress rule that lets
#     it reach the API. And (TM-0977) an existing Secret is checked against
#     the gateway, GET /v1/models with its key, before the Job trusts it: a
#     401 replaces the key in place and restarts the console's pods, so a
#     gateway turned off and on again (its database pruned with it) does not
#     leave the console on a dead key with every layer Healthy.
# G4  A site may override (ruling D1): `apps.litellm.enabled: false` alone is
#     refused with a sentence that names the two ways out; with
#     `open-webui.enableOpenaiApi: false` it renders with no gateway and no
#     Job; with a direct model-host URL it renders pointed there.
# G5  Declining capabilities.aiPlane renders no console, no gateway and no
#     Job; modelGateway.consoleKey.enabled false renders no Job; enabled true
#     with a Secret name the console does not read is refused.
# G6  tools/mint-secrets.sh with no credential flag mints the gateway's master
#     key and database credential (step 1 of the design); --without-litellm
#     does not.
# G7  The console-key check (TM-0982) renders beside the Job: a CronJob on a
#     schedule, Forbid, backoffLimit 0, a podFailurePolicy that fails the Job
#     on exit 1 alone, a pod with no token (automountServiceAccountToken
#     false on the pod and its own ServiceAccount), no Role at all, the
#     console's key through secretKeyRef on the one Secret and NO master key
#     reference, the script sending GET /v1/models with it, the pod labelled
#     tockmox.com/isolated, the policy layer's egress rule for it reaching
#     the gateway's pods on 4000 and nothing else, and the
#     TockmoxConsoleKeyRejected rule in the newest-failure-vs-newest-success
#     shape with the reason selector that keeps a gateway outage out of it.
#     And (lab L5, F-L5-4) the request is retried while it got no HTTP
#     answer, bounded so the bound fits the Job's deadline, with the first
#     answer deciding: a single curl lost most slots to k3s's new-pod policy
#     window; and (F-L5-6) failedJobsHistoryLimit is at least 24, so the
#     failed Job that records a rejection outlives six hours of outage
#     failures behind it; and (F-L5-7) no ignore-healthcheck annotation, so a
#     failed check reads as a Degraded AI layer in Argo CD on purpose. Off
#     with the Job (G5's renders) and off alone with check.enabled false.
#
# The exporters half (the gateway's uptime probe follows the same switch) is
# check-platform-seams.sh S17.
#
# LIMIT: render only. That the Job's pod reaches the gateway and the API
# server, that LiteLLM answers /key/generate, and that the console then lists
# models are the lab's to prove (the card's two legs).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-gateway-default: helm missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-gateway-default: python3 PyYAML missing" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SITE=ci/values-site-minimal.yaml
ROOT=.
# r <out> <layer> [helm args...]: render charts under $ROOT into $T/<out>.
r() { local out="$1" chart="$2"; shift 2; helm template t "$ROOT/charts/tockmox-$chart" -f "$SITE" "$@" > "$T/$out" 2>"$T/$out.err"; }
# refuses <needle> <layer> [helm args...]: the render must fail and say <needle>.
refuses() { local needle="$1"; shift; if r x "$@"; then return 1; fi; grep -q -- "$needle" "$T/x.err"; }

# ---- the assertions. Each takes render files and exits 0 (holds) or 1.
g1() { python3 - "$1" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
dep = [x for x in d if x.get("kind") == "Deployment" and x["metadata"]["name"] == "t-litellm"]
sts = [x for x in d if x.get("kind") == "StatefulSet" and x["metadata"]["name"] == "t-open-webui"]
if len(dep) != 1 or len(sts) != 1: sys.exit(1)
env = {}
for c in sts[0]["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "open-webui":
        env = {e["name"]: e for e in c.get("env", [])}
url = env.get("OPENAI_API_BASE_URL", {}).get("value")
key = env.get("OPENAI_API_KEY", {}).get("valueFrom", {}).get("secretKeyRef", {})
ok = url == "http://t-litellm:4000/v1" and key.get("name") == "tockmox-openwebui-gateway" and key.get("key") == "api-key" \
     and env.get("ENABLE_OPENAI_API", {}).get("value", "True") != "False"
sys.exit(0 if ok else 1)
PY
}
g3() { python3 - "$1" "$2" <<'PY'
import sys, yaml
ai = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
pol = [x for x in yaml.safe_load_all(open(sys.argv[2])) if x]
jobs = [x for x in ai if x.get("kind") == "Job" and x["metadata"]["name"].startswith("t-gateway-key-")]
roles = [x for x in ai if x.get("kind") == "Role" and x["metadata"]["name"] == "tockmox-gateway-key"]
rbs = [x for x in ai if x.get("kind") == "RoleBinding" and x["metadata"]["name"] == "tockmox-gateway-key"]
sas = [x for x in ai if x.get("kind") == "ServiceAccount" and x["metadata"]["name"] == "tockmox-gateway-key"]
if not (len(jobs) == 1 and len(roles) == 1 and len(rbs) == 1 and len(sas) == 1): sys.exit(1)
j = jobs[0]; spec = j["spec"]; pod = spec["template"]["spec"]
ann = j["metadata"].get("annotations") or {}
if any(k.startswith("argocd.argoproj.io/hook") or k == "helm.sh/hook" for k in ann): sys.exit(1)
if "ttlSecondsAfterFinished" in spec: sys.exit(1)
if pod.get("restartPolicy") != "OnFailure" or pod.get("serviceAccountName") != "tockmox-gateway-key": sys.exit(1)
if spec.get("backoffLimit", 0) < 20 or spec.get("activeDeadlineSeconds", 0) < 1800: sys.exit(1)
if j["metadata"].get("labels", {}).get("app.kubernetes.io/name") != "tockmox-gateway-key": sys.exit(1)
c = pod["containers"][0]
env = {e["name"]: e for e in c.get("env", [])}
mk = env.get("PROXY_MASTER_KEY", {}).get("valueFrom", {}).get("secretKeyRef", {})
if mk.get("name") != "tockmox-litellm" or mk.get("key") != "masterkey": sys.exit(1)
if env.get("GATEWAY", {}).get("value") != "http://t-litellm:4000": sys.exit(1)
if env.get("SECRET_NAME", {}).get("value") != "tockmox-openwebui-gateway": sys.exit(1)
script = "\n".join(c.get("args", []))
i_ready, i_check, i_gen, i_create = script.find('"$GATEWAY/health/readiness"'), script.find('"$GATEWAY/v1/models"'), script.find('POST "$GATEWAY/key/generate"'), script.find("create secret generic")
if not (0 <= i_ready < i_check < i_gen < i_create): sys.exit(1)
if 'get secret "$SECRET_NAME"' not in script: sys.exit(1)   # the idempotence check
# TM-0977: the existing key is sent to the gateway; 401 replaces it in place
# and restarts the console's pods; a working key (200) is left alone.
if "-H \"Authorization: Bearer $have\"" not in script: sys.exit(1)
if "401)" not in script or "200)" not in script: sys.exit(1)
if "replace -f -" not in script or "delete pod $CONSOLE_PODS" not in script: sys.exit(1)
if env.get("CONSOLE_PODS", {}).get("value") != "t-open-webui-0": sys.exit(1)
# The Role: get+update on the one Secret name, create on secrets, delete on
# the console's pod names, nothing else.
rules = roles[0]["rules"]
want = [
    {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["tockmox-openwebui-gateway"], "verbs": ["get", "update"]},
    {"apiGroups": [""], "resources": ["secrets"], "verbs": ["create"]},
    {"apiGroups": [""], "resources": ["pods"], "resourceNames": ["t-open-webui-0"], "verbs": ["delete"]},
]
norm = lambda rs: sorted(yaml.safe_dump(x, sort_keys=True) for x in rs)
if norm(rules) != norm(want): sys.exit(1)
rb = rbs[0]
if rb["roleRef"]["kind"] != "Role" or rb["roleRef"]["name"] != "tockmox-gateway-key": sys.exit(1)
if [(s["kind"], s["name"]) for s in rb["subjects"]] != [("ServiceAccount", "tockmox-gateway-key")]: sys.exit(1)
# The policy layer lets the Job's pod reach the API server.
np = [x for x in pol if x.get("kind") == "NetworkPolicy" and x["metadata"]["name"] == "allow-egress-gateway-key"]
if len(np) != 1: sys.exit(1)
sel = np[0]["spec"]["podSelector"].get("matchLabels", {})
if sel.get("app.kubernetes.io/name") != "tockmox-gateway-key" or np[0]["spec"].get("policyTypes") != ["Egress"]: sys.exit(1)
ports = {p.get("port") for e in np[0]["spec"]["egress"] for p in e.get("ports", [])}
sys.exit(0 if {443, 6443} <= ports else 1)
PY
}
g7() { python3 - "$1" "$2" <<'PY'
import sys, yaml, re
ai = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
pol = [x for x in yaml.safe_load_all(open(sys.argv[2])) if x]
N = "tockmox-console-key-check"
cjs = [x for x in ai if x.get("kind") == "CronJob" and x["metadata"]["name"] == N]
sas = [x for x in ai if x.get("kind") == "ServiceAccount" and x["metadata"]["name"] == N]
if len(cjs) != 1 or len(sas) != 1: sys.exit(1)
if sas[0].get("automountServiceAccountToken") is not False: sys.exit(1)
# No Role of its own, and nothing binds its account.
if any(x.get("kind") in ("Role", "ClusterRole") and x["metadata"]["name"] == N for x in ai): sys.exit(1)
for x in ai:
    if x.get("kind") in ("RoleBinding", "ClusterRoleBinding"):
        if any(s.get("name") == N for s in x.get("subjects", [])): sys.exit(1)
cj = cjs[0]; spec = cj["spec"]; js = spec["jobTemplate"]["spec"]; pod = js["template"]["spec"]; meta = js["template"]["metadata"]
if not re.match(r"^[-*/0-9, ]+$", spec.get("schedule", "")): sys.exit(1)
if spec.get("concurrencyPolicy") != "Forbid": sys.exit(1)
if "successfulJobsHistoryLimit" not in spec or "failedJobsHistoryLimit" not in spec: sys.exit(1)
# Lab L5 (F-L5-6): the rejection lives in a failed Job, and a limit of 3 let
# three outage failures prune it and clear the alert by garbage collection.
# 24 is six hours of failed slots at the default schedule.
if spec["failedJobsHistoryLimit"] < 24: sys.exit(1)
# Lab L5 (F-L5-7): Argo CD reads a failed check as a Degraded AI layer, and
# that is kept on purpose; an ignore-healthcheck annotation would silence it.
for md in (cj["metadata"], spec["jobTemplate"].get("metadata") or {}, meta):
    if (md.get("annotations") or {}).get("argocd.argoproj.io/ignore-healthcheck"): sys.exit(1)
if js.get("backoffLimit") != 0 or not js.get("activeDeadlineSeconds"): sys.exit(1)
rules = (js.get("podFailurePolicy") or {}).get("rules") or []
if len(rules) != 1 or rules[0].get("action") != "FailJob": sys.exit(1)
oec = rules[0].get("onExitCodes") or {}
if oec.get("containerName") != "check" or oec.get("operator") != "In" or oec.get("values") != [1]: sys.exit(1)
if pod.get("restartPolicy") != "Never" or pod.get("serviceAccountName") != N: sys.exit(1)
if pod.get("automountServiceAccountToken") is not False: sys.exit(1)
if meta.get("labels", {}).get("app.kubernetes.io/name") != N: sys.exit(1)
if meta.get("labels", {}).get("tockmox.com/isolated") != "true": sys.exit(1)
if len(pod["containers"]) != 1: sys.exit(1)
c = pod["containers"][0]
if c["name"] != "check": sys.exit(1)
sc = c.get("securityContext", {})
if not (sc.get("readOnlyRootFilesystem") is True and sc.get("allowPrivilegeEscalation") is False and sc.get("capabilities", {}).get("drop") == ["ALL"]): sys.exit(1)
env = {e["name"]: e for e in c.get("env", [])}
ck = env.get("CONSOLE_KEY", {}).get("valueFrom", {}).get("secretKeyRef", {})
if ck.get("name") != "tockmox-openwebui-gateway" or ck.get("key") != "api-key": sys.exit(1)
# No master key, by reference or by name, anywhere in the pod.
if "PROXY_MASTER_KEY" in env: sys.exit(1)
if any((e.get("valueFrom") or {}).get("secretKeyRef", {}).get("name") == "tockmox-litellm" for e in c.get("env", [])): sys.exit(1)
if "masterkey" in yaml.safe_dump(pod): sys.exit(1)
if env.get("GATEWAY", {}).get("value") != "http://t-litellm:4000": sys.exit(1)
script = "\n".join(c.get("args", []))
if '"$GATEWAY/v1/models"' not in script or '-H "Authorization: Bearer $CONSOLE_KEY"' not in script: sys.exit(1)
if "kubectl" in script or "/key/generate" in script: sys.exit(1)
# 401 and 403 exit 1; a gateway that does not answer exits with another code.
m = re.search(r"401\|403\)(.*?)exit (\d+)", script, re.S)
if not m or m.group(2) != "1": sys.exit(1)
m = re.search(r'000\|""\)(.*?)exit (\d+)', script, re.S)
if not m or m.group(2) in ("0", "1"): sys.exit(1)
if "$why" not in m.group(1) or "$attempts" not in m.group(1): sys.exit(1)
# The policy window (lab L5: a new pod's egress is refused for its first
# second or two on k3s, and a single curl lost most slots to it): the
# request is retried while it got no HTTP answer, the first answer decides,
# the loop is bounded, and the bound fits the Job's deadline.
m = re.search(r"while :; do\n(.*?)\n\s*done", script, re.S)
if not m: sys.exit(1)
loop = m.group(1)
if "curl -s" not in loop or "sleep " not in loop or script.count("curl -s") != 1: sys.exit(1)
if not re.search(r'\[ "\$code" != "000" \].*break', loop): sys.exit(1)
b = re.search(r'\[ "\$attempts" -ge (\d+) \] && break', loop)
if not b: sys.exit(1)
mt = re.search(r"--max-time (\d+)", loop); sl = re.search(r"sleep (\d+)", loop)
if not mt or not sl or int(b.group(1)) * (int(mt.group(1)) + int(sl.group(1))) > js["activeDeadlineSeconds"]: sys.exit(1)
# The policy layer: an egress rule selecting this pod, to the gateway's pods
# on 4000 and nothing else.
np = [x for x in pol if x.get("kind") == "NetworkPolicy" and x["metadata"]["name"] == "allow-egress-console-key-check"]
if len(np) != 1: sys.exit(1)
sel = np[0]["spec"]["podSelector"].get("matchLabels", {})
if sel.get("app.kubernetes.io/name") != N or np[0]["spec"].get("policyTypes") != ["Egress"]: sys.exit(1)
eg = np[0]["spec"]["egress"]
if len(eg) != 1 or len(eg[0]["to"]) != 1: sys.exit(1)
to = eg[0]["to"][0]
if set(to) != {"podSelector"} or to["podSelector"].get("matchLabels") != {"app.kubernetes.io/name": "litellm"}: sys.exit(1)
if [(p.get("protocol"), p.get("port")) for p in eg[0].get("ports", [])] != [("TCP", 4000)]: sys.exit(1)
# The rule: newest rejection against newest success, rejection only.
prs = [x for x in ai if x.get("kind") == "PrometheusRule" and x["metadata"]["name"] == N]
if len(prs) != 1: sys.exit(1)
rules = [r for g in prs[0]["spec"]["groups"] for r in g.get("rules", []) if r.get("alert") == "TockmoxConsoleKeyRejected"]
if len(rules) != 1: sys.exit(1)
r = rules[0]; e = " ".join(r["expr"].split())
if 'reason!~"BackoffLimitExceeded|DeadlineExceeded|Evicted"' not in e: sys.exit(1)
if "kube_job_status_start_time" not in e or "kube_job_status_completion_time" not in e or "or on () vector(0)" not in e: sys.exit(1)
if not re.search(r"kube_job_status_failed\{[^}]*\} > 0", e) or not re.search(r"kube_job_status_succeeded\{[^}]*\} > 0", e): sys.exit(1)
if 'job_name=~"tockmox-console-key-check-.*"' not in e: sys.exit(1)
if not r.get("for") or r.get("labels", {}).get("severity") not in ("warning", "critical"): sys.exit(1)
d = r.get("annotations", {}).get("description", "")
if "ai-plane.md" not in d or "delete job -l app.kubernetes.io/name=tockmox-gateway-key" not in d: sys.exit(1)
sys.exit(0)
PY
}
# none <render> <kind> <name-prefix>: no object of that kind with that prefix.
none() { python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
sys.exit(1 if any(x.get("kind") == sys.argv[2] and x["metadata"]["name"].startswith(sys.argv[3]) for x in d) else 0)
PY
}
console_url() { python3 - "$1" "$2" <<'PY'
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x]
sts = [x for x in d if x.get("kind") == "StatefulSet" and x["metadata"]["name"] == "t-open-webui"]
if len(sts) != 1: sys.exit(1)
for c in sts[0]["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "open-webui":
        env = {e["name"]: e.get("value") for e in c.get("env", [])}
        sys.exit(0 if env.get("OPENAI_API_BASE_URL") == sys.argv[2] else 1)
sys.exit(1)
PY
}
# G6: mint-secrets with a fake kubeseal, offline. Prints the files minted.
mint_files() { # [mint flags...]
  local bin out; bin=$(mktemp -d); out=$(mktemp -d); echo x > "$bin/cert.pem"
  printf '#!/bin/sh\ncat >/dev/null; echo "kind: SealedSecret"\n' > "$bin/kubeseal"; chmod +x "$bin/kubeseal"
  PATH="$bin:$PATH" bash "$ROOT/tools/mint-secrets.sh" --cert "$bin/cert.pem" --out "$out" --no-prompt --no-next -y "$@" >/dev/null 2>&1 || true
  ls "$out" 2>/dev/null | sort | tr '\n' ' '
  rm -rf "$bin" "$out"
}
g6() { local f; f=$(mint_files); case "$f" in *"litellm-db.sealed.yaml "*"litellm.sealed.yaml "*) return 0 ;; esac; return 1; }
g6_without() { local f; f=$(mint_files --without-litellm); case "$f" in *litellm*) return 1 ;; esac; return 0; }

renders() {
  r ai.default ai
  r pol.default policy
  r ai.minimal ai -f "$ROOT/profiles/minimal.yaml"
  r ai.household ai -f "$ROOT/profiles/household-sso.yaml"
  r ai.off ai --set apps.litellm.enabled=false --set open-webui.enableOpenaiApi=false
  r ai.direct ai --set apps.litellm.enabled=false --set open-webui.openaiBaseApiUrl=http://models.example.internal:8080/v1 --set open-webui.openaiApiKeyExistingSecret=
  r ai.noplane ai --set capabilities.aiPlane.enabled=false
  r ai.nokey ai --set modelGateway.consoleKey.enabled=false
  r ai.nocheck ai --set modelGateway.consoleKey.check.enabled=false
}

# ---- selftest: a mutated copy of the tree, and every assertion must go red.
if [ "${1:-}" = "--selftest" ]; then
  fail=0
  must_refuse() { local n="$1"; shift; if "$@"; then echo "selftest FAIL: $n stayed green"; fail=1; else echo "selftest ok: $n goes red"; fi; }
  M="$T/mut"; mkdir -p "$M"; cp -R charts ci profiles tools "$M/"
  # Portable in-place edit (TM-0996). BSD sed on macOS reads a bare -i's next
  # argument as a backup suffix, so `sed -i 's/x/y/' f` dies there with "invalid
  # command code". Write and move instead, the way install/tockmox-install.sh does.
  sedi() { local e="$1" f rc=0; shift; for f in "$@"; do if sed "$e" "$f" > "$f.sedi"; then mv "$f.sedi" "$f"; else rm -f "$f.sedi"; rc=1; fi; done; return $rc; }
  ROOT="$M"
  # G1/G2: the 0.7.x default restored (gateway off; the console at nothing).
  sedi 's/^  litellm:   {}.*$/  litellm:   { enabled: false }/' "$M/charts/tockmox-ai/values.yaml"
  sedi 's/^  enableOpenaiApi: true$/  enableOpenaiApi: false/; s|^  openaiBaseApiUrl: "http://{{ .Release.Name }}-litellm:4000/v1"$|  openaiBaseApiUrl: ""|' "$M/charts/tockmox-ai/values.yaml"
  r m1 ai; must_refuse "G1 gateway off and console at nothing" g1 "$T/m1"
  r m2 ai -f "$M/profiles/minimal.yaml"; must_refuse "G2 minimal profile on the 0.7.x default" g1 "$T/m2"
  r m3 ai -f "$M/profiles/household-sso.yaml"; must_refuse "G2 household-sso profile on the 0.7.x default" g1 "$T/m3"
  # G4: with the old default, apps.litellm.enabled false alone renders (nothing to refuse).
  must_refuse "G4 the override refusal (nothing points at the gateway, so nothing is refused)" refuses "apps.litellm.enabled is false so nothing renders it" ai --set apps.litellm.enabled=false
  rm -rf "$M"; mkdir -p "$M"; cp -R charts ci profiles tools "$M/"
  # G3: the Role widened by one verb; the readiness wait removed; the policy rule gone.
  r pol.m policy
  sedi 's/    verbs: \["get", "update"\]/    verbs: ["get", "update", "list"]/' "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  r m4 ai; must_refuse "G3 Role gains list" g3 "$T/m4" "$T/pol.m"
  cp charts/tockmox-ai/templates/gateway-key.yaml "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  sedi 's/    verbs: \["delete"\]/    verbs: ["delete", "patch"]/' "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  r m4b ai; must_refuse "G3 Role gains patch on the console's pods" g3 "$T/m4b" "$T/pol.m"
  cp charts/tockmox-ai/templates/gateway-key.yaml "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  sedi 's/    resourceNames: {{ \$consolePods | toJson }}/    resourceNames: []/' "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  r m4c ai; must_refuse "G3 the pod rule loses its names" g3 "$T/m4c" "$T/pol.m"
  cp charts/tockmox-ai/templates/gateway-key.yaml "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  sedi 's/    resourceNames: \[{{ \$secretName | quote }}\]/    resourceNames: []/' "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  r m5 ai; must_refuse "G3 Role loses its resourceNames" g3 "$T/m5" "$T/pol.m"
  cp charts/tockmox-ai/templates/gateway-key.yaml "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  sedi 's|"$GATEWAY/health/readiness"|"$GATEWAY/nothing"|' "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  r m6 ai; must_refuse "G3 the Job no longer waits for the gateway" g3 "$T/m6" "$T/pol.m"
  cp charts/tockmox-ai/templates/_gateway-key.tpl "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  sedi 's/  restartPolicy: OnFailure/  restartPolicy: Never/' "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  r m7 ai; must_refuse "G3 restartPolicy Never" g3 "$T/m7" "$T/pol.m"
  cp charts/tockmox-ai/templates/_gateway-key.tpl "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  # G3 (TM-0977): the 0.8.0-rc shape restored, an existing Secret trusted unchecked.
  sedi 's|"$GATEWAY/v1/models"|"$GATEWAY/nothing"|' "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  r m7b ai; must_refuse "G3 an existing Secret is no longer checked against the gateway" g3 "$T/m7b" "$T/pol.m"
  cp charts/tockmox-ai/templates/_gateway-key.tpl "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  sedi 's/^              401) echo/              418) echo/' "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  r m7c ai; must_refuse "G3 a 401 no longer replaces the key" g3 "$T/m7c" "$T/pol.m"
  cp charts/tockmox-ai/templates/_gateway-key.tpl "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  sedi 's/delete pod \$CONSOLE_PODS/delete pod nothing/' "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  r m7d ai; must_refuse "G3 the console is no longer restarted after a replaced key" g3 "$T/m7d" "$T/pol.m"
  cp charts/tockmox-ai/templates/_gateway-key.tpl "$M/charts/tockmox-ai/templates/_gateway-key.tpl"
  sedi 's/  name: allow-egress-gateway-key/  name: allow-egress-gateway-key-x/' "$M/charts/tockmox-policy/templates/ai-egress-namespace.yaml"
  r pol.m2 policy; r m8 ai; must_refuse "G3 the policy layer drops the Job's API egress" g3 "$T/m8" "$T/pol.m2"
  cp charts/tockmox-policy/templates/ai-egress-namespace.yaml "$M/charts/tockmox-policy/templates/ai-egress-namespace.yaml"
  # G4: the preflight refusal removed.
  python3 - "$M/charts/tockmox-ai/templates/preflight.yaml" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r'\{\{- if contains \$expected \$url -\}\}\n\{\{- fail \(printf "open-webui\.openaiBaseApiUrl points at.*?\n\{\{- end -\}\}\n', '', s, count=1, flags=re.S)
assert s2 != s
open(p, "w").write(s2)
PY
  must_refuse "G4 the override refusal removed" refuses "apps.litellm.enabled is false so nothing renders it" ai --set apps.litellm.enabled=false
  cp charts/tockmox-ai/templates/preflight.yaml "$M/charts/tockmox-ai/templates/preflight.yaml"
  # G5: the Job rendered whatever the capability says.
  sedi 's/^{{- if \$on }}$/{{- if true }}/' "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  r m9 ai --set capabilities.aiPlane.enabled=false; must_refuse "G5 the Job ignores a declined aiPlane" none "$T/m9" Job t-gateway-key-
  r m10 ai --set modelGateway.consoleKey.enabled=false; must_refuse "G5 the Job ignores consoleKey.enabled false" none "$T/m10" Job t-gateway-key-
  cp charts/tockmox-ai/templates/gateway-key.yaml "$M/charts/tockmox-ai/templates/gateway-key.yaml"
  # G7 (TM-0982): the check gains a Role; the master key referenced; the
  # schedule dropped; the rule removed; the reason selector dropped; the token
  # mounted; exit 1 no longer failing the Job by policy; the policy rule
  # widened to the API port; check.enabled false ignored.
  CK="$M/charts/tockmox-ai/templates/console-key-check.yaml"
  r pol.m policy
  python3 - "$CK" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("automountServiceAccountToken: false\n---\napiVersion: batch/v1", "automountServiceAccountToken: false\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: tockmox-console-key-check\n  namespace: {{ $ns }}\nrules:\n  - apiGroups: [\"\"]\n    resources: [\"secrets\"]\n    verbs: [\"get\"]\n---\napiVersion: batch/v1", 1)
open(p, "w").write(s)
PY
  r m11 ai; must_refuse "G7 the check gains a Role" g7 "$T/m11" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  python3 - "$CK" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("              command: [\"sh\", \"-c\"]", "                - name: PROXY_MASTER_KEY\n                  valueFrom:\n                    secretKeyRef:\n                      name: tockmox-litellm\n                      key: masterkey\n              command: [\"sh\", \"-c\"]", 1)
open(p, "w").write(s)
PY
  r m12 ai; must_refuse "G7 the check references the master key" g7 "$T/m12" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  sedi 's|  schedule: {{ \$check.schedule \| default "\*/15 \* \* \* \*" \| quote }}|  schedule: ""|' "$CK"
  r m13 ai; must_refuse "G7 the schedule is missing" g7 "$T/m13" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  sedi 's/        - alert: TockmoxConsoleKeyRejected/        - alert: TockmoxConsoleKeyRejectedX/' "$CK"
  r m14 ai; must_refuse "G7 the rule is removed" g7 "$T/m14" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  sedi 's/, reason!~"BackoffLimitExceeded|DeadlineExceeded|Evicted"}/}/' "$CK"
  r m15 ai; must_refuse "G7 the rule counts a gateway outage as a rejection" g7 "$T/m15" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  sedi 's/          automountServiceAccountToken: false/          automountServiceAccountToken: true/' "$CK"
  r m16 ai; must_refuse "G7 the check mounts a token" g7 "$T/m16" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  sedi 's/            onExitCodes:/            onPodConditions: []\n            onExitCodesX:/' "$CK"
  r m17 ai; must_refuse "G7 exit 1 no longer fails the Job by policy" g7 "$T/m17" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  python3 - "$M/charts/tockmox-policy/templates/ai-egress-namespace.yaml" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
i = s.index("  name: allow-egress-console-key-check")
port = "        - protocol: TCP\n          port: 4000\n"
j = s.index(port, i)
s = s[:j] + port + "        - protocol: TCP\n          port: 6443\n" + s[j + len(port):]
open(p, "w").write(s)
PY
  r pol.m3 policy; r m18 ai; must_refuse "G7 the policy rule lets the check reach more than the gateway's port" g7 "$T/m18" "$T/pol.m3"
  cp charts/tockmox-policy/templates/ai-egress-namespace.yaml "$M/charts/tockmox-policy/templates/ai-egress-namespace.yaml"
  sedi 's/^{{- if \$on }}$/{{- if true }}/' "$CK"
  r m19 ai --set modelGateway.consoleKey.check.enabled=false; must_refuse "G7 the check ignores check.enabled false" none "$T/m19" CronJob tockmox-console-key-check
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  # Lab L5 (F-L5-4): the retry loop collapsed back to a single curl; the
  # bound widened past the Job's deadline.
  python3 - "$CK" <<'PY'
import sys, re; p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r"                  while :; do\n.*?\n                  done\n", "                  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \"$GATEWAY/v1/models\" -H \"Authorization: Bearer $CONSOLE_KEY\" 2>/dev/null); rc=$?\n", s, count=1, flags=re.S)
assert s2 != s
open(p, "w").write(s2)
PY
  r m20 ai; must_refuse "G7 the check sends one curl with no retry across the policy window" g7 "$T/m20" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  sedi 's/\[ "\$attempts" -ge 10 \] && break/[ "$attempts" -ge 20 ] \&\& break/' "$CK"
  r m21 ai; must_refuse "G7 the retry bound no longer fits the Job's deadline" g7 "$T/m21" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  sedi 's/  failedJobsHistoryLimit: 24/  failedJobsHistoryLimit: 3/' "$CK"
  r m22 ai; must_refuse "G7 the failed-Job history no longer outlives an outage after a rejection" g7 "$T/m22" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  python3 - "$CK" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s2 = s.replace("kind: CronJob\nmetadata:\n  name: {{ $name }}\n  namespace: {{ $ns }}\n", "kind: CronJob\nmetadata:\n  name: {{ $name }}\n  namespace: {{ $ns }}\n  annotations:\n    argocd.argoproj.io/ignore-healthcheck: \"true\"\n", 1)
assert s2 != s
open(p, "w").write(s2)
PY
  r m23 ai; must_refuse "G7 a failed check no longer degrades the AI layer in Argo CD" g7 "$T/m23" "$T/pol.m"
  cp charts/tockmox-ai/templates/console-key-check.yaml "$CK"
  # G6: the mint default restored to 0.7.x. Green on the untouched copy first, and red because it
  # minted the others without the gateway's: a copy that crashed mints nothing and reads as red too.
  g6 || { echo "selftest FAIL: G6 is red on the unmutated copy, so the mutation below proves nothing"; fail=1; }
  sedi 's/DRY=false; WITH_LITELLM=true;/DRY=false; WITH_LITELLM=false;/' "$M/tools/mint-secrets.sh"
  must_refuse "G6 mint-secrets no longer mints the gateway credentials by default" g6
  case "$(mint_files)" in ""|*litellm*) echo "selftest FAIL: G6 the mutated copy did not mint the other credentials and leave out the gateway's"; fail=1 ;; esac
  sedi 's/    --without-litellm) WITH_LITELLM=false; shift ;;/    --without-litellm) WITH_LITELLM=true; shift ;;/' "$M/tools/mint-secrets.sh"
  must_refuse "G6 --without-litellm no longer leaves them out" g6_without
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

rc=0
chk() { local n="$1"; shift; if "$@"; then echo "  ok $n"; else echo "FAIL $n"; rc=1; fi; }
renders || { echo "check-gateway-default: a render failed:"; cat "$T"/*.err >&2; exit 1; }
chk "G1 the smallest real site renders the gateway and the console at http://<release>-litellm:4000/v1 on the console-key Secret" g1 "$T/ai.default"
chk "G2 profiles/minimal.yaml keeps the gateway on and the console through it" g1 "$T/ai.minimal"
chk "G2 profiles/household-sso.yaml keeps the gateway on and the console through it" g1 "$T/ai.household"
chk "G3 the console-key Job: waits for readiness, checks an existing key against the gateway and replaces a rejected one, mints with the master key, Role on one Secret name and the console pod names, API egress in the policy layer" g3 "$T/ai.default" "$T/pol.default"
chk "G4 apps.litellm.enabled false alone is refused, naming the two ways out" refuses "apps.litellm.enabled is false so nothing renders it" ai --set apps.litellm.enabled=false
chk "G4 the override with enableOpenaiApi false renders no gateway" none "$T/ai.off" Deployment t-litellm
chk "G4 the override with enableOpenaiApi false renders no console-key Job" none "$T/ai.off" Job t-gateway-key-
chk "G4 the override with a direct model-host URL renders the console pointed there" console_url "$T/ai.direct" http://models.example.internal:8080/v1
chk "G4 the override with a direct model-host URL renders no console-key Job" none "$T/ai.direct" Job t-gateway-key-
chk "G5 capabilities.aiPlane off renders no gateway" none "$T/ai.noplane" Deployment t-litellm
chk "G5 capabilities.aiPlane off renders no console" none "$T/ai.noplane" StatefulSet t-open-webui
chk "G5 capabilities.aiPlane off renders no console-key Job" none "$T/ai.noplane" Job t-gateway-key-
chk "G5 modelGateway.consoleKey.enabled false renders no Job" none "$T/ai.nokey" Job t-gateway-key-
chk "G5 consoleKey.enabled true with a Secret name the console does not read is refused" refuses "the console would never read the key it mints" ai --set modelGateway.consoleKey.enabled=true --set modelGateway.consoleKey.secretName=other
chk "G7 the console-key check: a CronJob with no token, no Role and no master key, the console's key by reference, exit 1 on 401/403 alone failing the Job by policy, isolated with an egress rule to the gateway's port only, and the TockmoxConsoleKeyRejected rule in the newest-rejection-vs-newest-success shape" g7 "$T/ai.default" "$T/pol.default"
chk "G7 the check is off with the Job (consoleKey.enabled false)" none "$T/ai.nokey" CronJob tockmox-console-key-check
chk "G7 the check is off with the Job (aiPlane off)" none "$T/ai.noplane" CronJob tockmox-console-key-check
chk "G7 the check is off with the Job (the direct model-host override)" none "$T/ai.direct" CronJob tockmox-console-key-check
chk "G7 check.enabled false renders no CronJob" none "$T/ai.nocheck" CronJob tockmox-console-key-check
chk "G7 check.enabled false renders no rule" none "$T/ai.nocheck" PrometheusRule tockmox-console-key-check
chk "G6 mint-secrets.sh with no credential flag mints the gateway's master key and database credential" g6
chk "G6 mint-secrets.sh --without-litellm mints neither" g6_without
exit $rc

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2015  # `ok ... || bad ...`: ok and bad are printf wrappers that return 0, so C runs only when A or B failed
#
# THE CONTEXT ANALYZER ADD-ON, AT RENDER. Off by default and absent; on, with
# what a site supplies, it renders the service, its database, its policy, its
# scrape, its rules, its dashboard and the hook in the gateway's hooks
# ConfigMap; and every refusal in preflight.yaml fires. Each refusal guards a
# configuration that renders cleanly and then captures nothing or stops the
# proxy at start-up. Each case changes ONE thing from the passing fixture, so a
# refusal that stops firing turns this red rather than passing for some other
# reason. The loader the hook runs through is tested on its own in
# test_loader.py, against the files this render produces.
#
#   tests/context-analyzer/render.sh     (needs helm and python3 with PyYAML)
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$root/charts/tockmox-ai"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
render() { helm template t "$chart" -f "$root/ci/values.yaml" "$@" > "$tmp/out.yaml" 2> "$tmp/err"; }
fixture="$root/ci/values-context-analyzer.yaml"

# 0. off by default: nothing rendered, and the hooks ConfigMap carries none of it
if render -f "$root/ci/values-policy-gate.yaml"; then
  python3 - "$tmp/out.yaml" <<'PY' && ok "0 off: no Context Analyzer objects or hook files by default" || bad "0 off: Context Analyzer content rendered by default"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
hit = [d["metadata"]["name"] for d in docs if "context-analyzer" in d["metadata"]["name"]]
hooks = [k for d in docs if d["metadata"]["name"] == "tockmox-litellm-hooks" for k in d.get("data", {}) if "context_analyzer" in k]
sys.exit(1 if hit or hooks else 0)
PY
else bad "0 default render failed: $(tail -1 "$tmp/err")"; fi

# 1. the passing fixture
if render -f "$fixture"; then
  python3 - "$tmp/out.yaml" "$tmp" <<'PY' && ok "1 on: hook files, Deployment, CNPG database, dashboard, rules, scrape and fenced policy, as designed" || bad "1 on: see above"
import json, os, sys, yaml
docs = {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
errs = []
name = "tockmox-context-analyzer"
secret = "tockmox-ctxa"
def need(kind, n):
    d = docs.get((kind, n))
    if d is None: errs.append(f"no {kind}/{n}")
    return d or {}
hooks = need("ConfigMap", "tockmox-litellm-hooks").get("data", {})
want = {"tockmox_context_analyzer.py", "tockmox_context_analyzer.json"} | {f"tockmox_context_analyzer_{m}.py" for m in ("compat", "segmentation", "actuation", "hooks")}
if not want <= set(hooks): errs.append(f"hook files missing: {sorted(want - set(hooks))}")
if "tockmox_gate.py" not in hooks: errs.append("the policy gate's file is gone from the hooks ConfigMap")
env = json.loads(hooks.get("tockmox_context_analyzer.json", "{}")).get("env", {})
if env.get("CTXA_SINK_URL") != f"http://{name}.default.svc:8000": errs.append(f"sink URL {env.get('CTXA_SINK_URL')!r}")
# Tockmox mode and the class source come as a pair, or not at all (the card's decision 4)
if (env.get("CTXA_TOCKMOX_MODE"), env.get("CTXA_POLICY_HOOK"), env.get("CTXA_CLASSIFICATION_PATH")) != ("1", "TockmoxPolicyGate", "tockmox.class"):
    errs.append(f"Tockmox mode and class source not wired as a pair: {env}")
for k in ("CTXA_TOKEN", "CTXA_HASH_SALT"):
    if k in env: errs.append(f"{k} in a ConfigMap: a secret belongs in the gateway's environment")
# the gateway reads the token Secret
lit = [d for (k, n), d in docs.items() if k == "Deployment" and d["spec"]["template"]["metadata"]["labels"].get("app.kubernetes.io/name") == "litellm"]
if not lit or {"secretRef": {"name": secret}} not in (lit[0]["spec"]["template"]["spec"]["containers"][0].get("envFrom") or []):
    errs.append("the gateway does not read the token Secret")
dep = need("Deployment", name)
spec = dep.get("spec", {}).get("template", {}).get("spec", {})
labels = dep.get("spec", {}).get("template", {}).get("metadata", {}).get("labels", {})
if labels.get("tockmox.com/isolated") != "true": errs.append("Analyzer pod not isolated: the namespace-wide allows would widen its policy")
if spec.get("automountServiceAccountToken") is not False: errs.append("service account token mounted")
c = (spec.get("containers") or [{}])[0]
if c.get("image") != "registry.example.com/site/context-analyzer:0.0.0-ci": errs.append(f"image {c.get('image')!r}")
cenv = {e["name"]: e for e in c.get("env", [])}
if cenv.get("CTXA_TOKEN", {}).get("valueFrom", {}).get("secretKeyRef") != {"name": secret, "key": "CTXA_TOKEN"}: errs.append("Analyzer token not from the Secret")
if "tockmox-context-analyzer-db-rw:5432/context_analyzer" not in cenv.get("DATABASE_URL", {}).get("value", ""): errs.append("DATABASE_URL does not name the CNPG read-write Service")
if not c.get("resources", {}).get("limits", {}).get("memory"): errs.append("no memory limit")
db = need("Cluster", "tockmox-context-analyzer-db")
if db and db["spec"]["bootstrap"]["initdb"]["database"] != "context_analyzer": errs.append("database name")
np = need("NetworkPolicy", name)
if np:
    peers = np["spec"]["ingress"][0]["from"]
    if {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "litellm"}}} not in peers: errs.append("the gateway may not reach the Analyzer")
    if np["spec"]["podSelector"] != {"matchLabels": {"app.kubernetes.io/name": name}}: errs.append("policy selects the wrong pods")
dash = need("ConfigMap", f"{name}-dashboard")
if dash and (dash["metadata"]["labels"].get("grafana_dashboard") != "1" or json.loads(dash["data"]["context-analyzer.json"])["uid"] != "ctxa-ci"):
    errs.append("dashboard ConfigMap not labelled or not the source's dashboard")
rule = need("PrometheusRule", name)
if rule:
    r = rule["spec"]["groups"][0]["rules"][0]
    if r.get("alert") != "CtxaEventStreamStale" or "{{ $labels.instance }}" not in r["annotations"]["summary"]:
        errs.append("alert rules not the source's, or their label references were templated away")
sm = need("ServiceMonitor", name)
if sm and sm["spec"]["endpoints"][0].get("authorization", {}).get("credentials") != {"name": secret, "key": "CTXA_TOKEN"}:
    errs.append("scrape carries no bearer token, and /metrics is authenticated")
# hand the hook files to test_loader.py
out = os.path.join(sys.argv[2], "hooks"); os.makedirs(out, exist_ok=True)
for k, v in hooks.items():
    open(os.path.join(out, k), "w").write(v)
for e in errs: print("   ", e)
sys.exit(1 if errs else 0)
PY
  if python3 -I "$root/tests/context-analyzer/test_loader.py" "$tmp/hooks"; then ok "1b loader: the rendered hook files load as a package, with the chart's settings"
  else bad "1b loader: the rendered hook files do not load"; fi
else bad "1 fixture render failed: $(grep -o 'execution error.*' "$tmp/err" | head -c 300)"; fi

# 1c. without the policy gate, neither Tockmox mode nor the class source is set
cat > "$tmp/nogate.yaml" <<'Y'
modelGateway: { policyGate: { enabled: false } }
litellm: { proxy_config: { litellm_settings: { callbacks: [hooks.tockmox_context_analyzer.analyzer_hook] } } }
Y
if render -f "$fixture" -f "$tmp/nogate.yaml"; then
  python3 - "$tmp/out.yaml" <<'PY' && ok "1c gate off: neither Tockmox mode nor the class source is set" || bad "1c gate off: half of the Tockmox-mode pair is set"
import json, sys, yaml
d = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["metadata"]["name"] == "tockmox-litellm-hooks")
env = json.loads(d["data"]["tockmox_context_analyzer.json"])["env"]
sys.exit(1 if {"CTXA_TOCKMOX_MODE", "CTXA_POLICY_HOOK", "CTXA_CLASSIFICATION_PATH"} & set(env) else 0)
PY
else bad "1c gate-off render failed: $(grep -o 'execution error.*' "$tmp/err" | head -c 300)"; fi

refuse() {   # $1 label, $2 expected message fragment, rest: extra args
  local label="$1" want="$2"; shift 2
  if render -f "$fixture" "$@"; then bad "$label: rendered, expected a refusal"
  elif grep -q -- "$want" "$tmp/err"; then ok "$label"
  else bad "$label: refused, but not for this reason: $(grep -o 'execution error.*' "$tmp/err" | head -c 300)"; fi
}
refuse "2a no image"                         "contextAnalyzer.image is empty" --set contextAnalyzer.image=
refuse "2b a source file missing"            "contextAnalyzer.source has no hooks.py" --set contextAnalyzer.source.hooks\\.py=
refuse "2c callback not registered"          "does not list hooks.tockmox_context_analyzer.analyzer_hook" --set 'litellm.proxy_config.litellm_settings.callbacks={hooks.tockmox_gate.tockmox_gate}'
refuse "2d analyzer before the gate"         "before hooks.tockmox_gate.tockmox_gate" --set 'litellm.proxy_config.litellm_settings.callbacks={hooks.tockmox_context_analyzer.analyzer_hook,hooks.tockmox_gate.tockmox_gate}'
refuse "2e token Secret not in the gateway"  "litellm.environmentSecrets does not list" --set 'litellm.environmentSecrets=null'
refuse "2f gateway off"                      "the model gateway is not enabled" --set apps.litellm.enabled=false --set modelGateway.policyGate.enabled=false --set open-webui.openaiBaseApiUrl=http://model-host.example:8000/v1
refuse "2g registered with the add-on off"   "apps.contextAnalyzer.enabled is false" --set apps.contextAnalyzer.enabled=false
refuse "2h on under a declined aiPlane"      "apps.contextAnalyzer.enabled is true but the aiPlane capability is off" --set capabilities.aiPlane.enabled=false --set apps.litellm.enabled=null
cat > "$tmp/clash.yaml" <<'Y'
modelGateway: { hooks: { files: { tockmox_context_analyzer.py: "x = 1\n" } } }
Y
refuse "2i a site hook file with the loader's name" "and so does the Context Analyzer" -f "$tmp/clash.yaml"

[ "$fail" = 0 ] && { echo "context-analyzer render: PASSED"; exit 0; }
echo "context-analyzer render: FAILED"; exit 1

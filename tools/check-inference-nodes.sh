#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, the inference-node routes (REQ-0047) and the
# eval gateway (REQ-0048) in tockmox-ai (TM-0920).
#
#   ./tools/check-inference-nodes.sh
#
# WHY THIS IS A GATE. The gateway's node routes are derived in Helm templates,
# and the Tockmox UI derives the same list in Python to show an admin what a
# change will do. If the two drift, the UI shows one gateway and the cluster runs
# another. Every drift renders cleanly. And the eval gateway's whole point is
# who can NOT reach it, which no exit code shows.
#
# WHAT IT PROVES, from ci/values.yaml + ci/values-inference-nodes.yaml:
#   - the production config's derived routes equal tests/golden (the UI's output),
#     hand-written entries kept first; the routes hash and the config hash match
#     the golden's and sit on the ConfigMap;
#   - no -next route reaches the production config; the eval config holds exactly
#     the golden's eval routes plus its hosted candidates, untagged;
#   - the eval gateway pod carries tockmox.com/isolated, mounts its own config, and
#     its NetworkPolicy admits only the fixture's peer, on 4000;
#   - the policy layer's namespace-wide allows skip isolated pods;
#   - the default render has none of it;
#   - one scrape target per node exporter and one blackbox target per engine endpoint, with the
#     instance labels the Tockmox UI matches on;
#   - default models for new production keys render into the config and change its hash;
#   - the model watcher and the Tockmox UI have exactly the authority and egress documented;
#   - eighteen wrong configurations are refused with a sentence naming the cause;
#   - an Ollama route with no num_ctx is refused, naming the node, the endpoint and the route (TM-0957);
#   - the policy layer's aiEgress.*.extraEgress refuses providerAllow's {cidr, ports} shape at render and
#     accepts a NetworkPolicy egress rule, and the four pages that send a reader there show that rule (TM-0978).
# WHAT IT DOES NOT PROVE: that LiteLLM loads the config or that the policy blocks
# a real connection. The lab proof does that (TM-0920 evidence).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-inference-nodes: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-inference-nodes: python3 PyYAML missing" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
AI=charts/tockmox-ai
BASE=ci/values.yaml
FIX=ci/values-inference-nodes.yaml

helm template t "$AI" -f "$BASE" > "$tmp/default.yaml"
helm template t "$AI" -f "$BASE" -f "$FIX" > "$tmp/nodes.yaml"
helm template t charts/tockmox-policy -f "$BASE" > "$tmp/policy.yaml"

refuse() {  # name, expected substring, extra helm args...
  local name="$1" want="$2"; shift 2
  if out=$(helm template t "$AI" -f "$BASE" -f "$FIX" "$@" 2>&1); then
    echo "FAIL refused case rendered: $name"; return 1
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    echo "FAIL $name: refused, but without naming the cause ($want)"; echo "$out" | tail -2; return 1
  fi
  echo "  ok refused: $name"
}

rc=0
refuse "subchart still renders its own config" "litellm.proxyConfigMap.create: false" \
  --set litellm.proxyConfigMap.create=true || rc=1
refuse "derived alias collides with a hand-written entry" "is also a hand-written entry" \
  --set 'litellm.proxy_config.model_list[0].model_name=local-chat' \
  --set 'litellm.podAnnotations.tockmox\.com/gateway-config=x' || rc=1
refuse "routes changed without the rolling annotation" 'tockmox.com/node-routes' \
  --set 'litellm.podAnnotations.tockmox\.com/node-routes=stale' || rc=1
refuse "hand config changed without its annotation" 'tockmox.com/gateway-config' \
  --set 'litellm.proxy_config.general_settings.extra=1' || rc=1
refuse "a route names a node that does not exist" "which is not in inferenceNodes.nodes" \
  --set 'inferenceNodes.routes[0].node=nope' || rc=1
refuse "a route sets a derived param" "which is derived from the node" \
  --set 'inferenceNodes.routes[0].params.api_base=http://x' || rc=1
refuse "default key models empty (means every model)" "reads an empty list as EVERY model" \
  --set-json 'modelLifecycle.productionKeys={"defaultModels":[]}' || rc=1
refuse "default key models naming all-proxy-models" "which means every model" \
  --set 'modelLifecycle.productionKeys.defaultModels={all-proxy-models}' || rc=1
refuse "default key models naming a model production does not serve" "is not a model or access group on the production gateway" \
  --set 'modelLifecycle.productionKeys.defaultModels={local-chat-next}' || rc=1
refuse "default key models set twice (by hand and by key)" "keep one of them" \
  --set 'modelLifecycle.productionKeys.defaultModels={local-chat}' \
  --set 'litellm.proxy_config.litellm_settings.default_key_generate_params.models={local-chat}' || rc=1
refuse "default key models without the chart rendering the config" "needs inferenceNodes.render.enabled" \
  --set 'modelLifecycle.productionKeys.defaultModels={local-chat}' --set 'inferenceNodes.render.enabled=false' || rc=1
refuse "the watcher on with no image" "modelLifecycle.watch.image is empty" \
  --set 'modelLifecycle.watch.image=' || rc=1
refuse "GitHub pull requests with no App and no token" "has no way to authenticate" \
  --set 'modelLifecycle.watch.pullRequests.githubApp=null' || rc=1
refuse "Forgejo pull requests with no token Secret" "needs the bot's token" \
  --set 'modelLifecycle.watch.pullRequests.forge=forgejo' || rc=1
refuse "the UI on with no image" "tockmoxUi.image is empty" \
  --set 'tockmoxUi.image=' || rc=1
refuse "the UI with no API server address" "name the Kubernetes API server address" \
  --set 'global.lanCIDR=' || rc=1
refuse "monitoring on for a node with no address" "has no address" \
  --set 'inferenceNodes.nodes[1].address=' || rc=1
refuse "the blackbox prober written with a scheme" "blackboxProber" \
  --set 'inferenceNodes.monitoring.blackboxProber=http://bb:9115' || rc=1

python3 - "$tmp/default.yaml" "$tmp/nodes.yaml" "$tmp/policy.yaml" tests/golden/inference-nodes.yaml "$FIX" <<'PY' || rc=1
import sys, yaml

def docs(path):
    return [d for d in yaml.safe_load_all(open(path)) if isinstance(d, dict) and d.get("kind")]

def find(ds, kind, name):
    return next((d for d in ds if d["kind"] == kind and d["metadata"]["name"] == name), None)

bad = 0
def check(cond, msg):
    global bad
    print(("  ok " if cond else "FAIL ") + msg)
    bad += (not cond)

default, nodes, policy = docs(sys.argv[1]), docs(sys.argv[2]), docs(sys.argv[3])
golden, fix = yaml.safe_load(open(sys.argv[4])), yaml.safe_load(open(sys.argv[5]))

check(not any(d["metadata"]["name"].startswith(("tockmox-litellm-config", "tockmox-litellm-eval", "tockmox-inference-nodes",
                                                  "tockmox-model-watch", "tockmox-ui"))
              for d in default),
      "the default render carries no node-route config, no eval gateway and no node monitoring")

# MONITORING (AC-47.7): the instance labels are the UI's contract (app/sources.py InferenceNodesSource)
sc = find(nodes, "ScrapeConfig", "tockmox-inference-nodes")
want_sc = {f"{n['address']}:{p}" for n in fix["inferenceNodes"]["nodes"] for p in (n.get("metrics") or {}).values()}
got_sc = {t for c in (sc or {}).get("spec", {}).get("staticConfigs", []) for t in c["targets"]}
# the API versions the vendored prometheus-operator CRDs serve (tockmox-crds; the etcd ScrapeConfig uses the same)
check(sc is not None and sc["apiVersion"] == "monitoring.coreos.com/v1alpha1", "ScrapeConfig is monitoring.coreos.com/v1alpha1")
check(sc is not None and got_sc == want_sc, "one scrape target per node exporter, at <address>:<port> (the UI's instance match)")
check(sc is not None and all("instance" not in c.get("labels", {}) for c in sc["spec"]["staticConfigs"])
      and not sc["spec"].get("relabelings"), "the scrape keeps Prometheus' own instance label (no relabel)")
pr = find(nodes, "Probe", "tockmox-inference-nodes")
eps = [e for n in fix["inferenceNodes"]["nodes"] for e in n["endpoints"]]
got_pr = (pr or {}).get("spec", {}).get("targets", {}).get("staticConfig", {}).get("static", [])
check(pr is not None and len(got_pr) == len(eps) and all(
          any(t == e["url"].rstrip("/") + ("/api/version" if e["engine"] == "ollama" else "/v1/models") for t in got_pr)
          and any(t.startswith(e["url"] + "/") for t in got_pr) for e in eps),
      "one blackbox target per engine endpoint: <url>/api/version for Ollama, <url>/v1/models otherwise")
check(pr is not None and pr["apiVersion"] == "monitoring.coreos.com/v1", "Probe is monitoring.coreos.com/v1")
check(pr is not None and "://" not in pr["spec"]["prober"]["url"] and pr["spec"]["module"] == "http_inference",
      "the probe goes through the exporters layer's blackbox, module http_inference (401 and HTTP/1.0 read as up)")

cm = find(nodes, "ConfigMap", "tockmox-litellm-config")
check(cm is not None, "the production gateway config renders as tockmox-litellm-config")
cfg = yaml.safe_load(cm["data"]["config.yaml"]) if cm else {}
hand = fix["litellm"]["proxy_config"]["model_list"]
ml = cfg.get("model_list", [])
check(ml[:len(hand)] == hand, "hand-written model_list entries are kept, first and unchanged")
check(ml[len(hand):] == golden["production"], "derived production routes equal the UI's (tests/golden)")
check(not any(e["model_name"].endswith("-next") for e in ml), "no -next candidate reaches the production gateway")
ann = (cm or {}).get("metadata", {}).get("annotations", {})
check(ann.get("tockmox.com/node-routes") == golden["routesHash"], "the routes hash equals the UI's (it rolls the gateway)")
check(ann.get("tockmox.com/gateway-config") == golden["gatewayConfigHash"], "the hand-config hash equals the UI's")

ecm = find(nodes, "ConfigMap", "tockmox-litellm-eval-config")
ecfg = yaml.safe_load(ecm["data"]["config.yaml"]) if ecm else {}
check(ecfg.get("model_list") == golden["eval"] + golden["hostedCandidates"],
      "the eval gateway serves exactly the -next routes, what they are compared against, and hosted candidates")
check(all("tags" not in e["litellm_params"] for e in golden["hostedCandidates"]) and golden["hostedCandidates"],
      "hosted candidates carry no data-class tags")

dep = find(nodes, "Deployment", "tockmox-litellm-eval")
pod = (dep or {}).get("spec", {}).get("template", {})
check(pod.get("metadata", {}).get("labels", {}).get("tockmox.com/isolated") == "true", "the eval gateway pod is labelled isolated")
vols = pod.get("spec", {}).get("volumes", [])
check(any(v.get("configMap", {}).get("name") == "tockmox-litellm-eval-config" for v in vols), "it mounts its own config")
check(pod.get("spec", {}).get("automountServiceAccountToken") is False, "it has no Kubernetes credentials")

np = find(nodes, "NetworkPolicy", "tockmox-litellm-eval")
check(np is not None and np["spec"]["podSelector"] == {"matchLabels": {"app.kubernetes.io/name": "tockmox-litellm-eval"}},
      "a NetworkPolicy selects the eval gateway pod")
ing = (np or {}).get("spec", {}).get("ingress", [])
check(len(ing) == 1 and ing[0]["from"] == fix["modelLifecycle"]["evalGateway"]["allowedClients"]
      and ing[0]["ports"] == [{"port": 4000, "protocol": "TCP"}], "it admits only the configured peer, on 4000")

iso = {"matchExpressions": [{"key": "tockmox.com/isolated", "operator": "DoesNotExist"}]}
for name in ("allow-intra-namespace", "allow-from-traefik", "allow-prometheus-scrape"):
    p = find(policy, "NetworkPolicy", name)
    check(p is not None and p["spec"]["podSelector"] == iso, f"policy layer {name} skips isolated pods")
# THE MODEL WATCHER (REQ-0048): no Kubernetes authority, internet HTTPS only
PRIVATE = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"}
cj = find(nodes, "CronJob", "tockmox-model-watch")
wpod = (cj or {}).get("spec", {}).get("jobTemplate", {}).get("spec", {}).get("template", {})
wsp = wpod.get("spec", {})
wct = wsp.get("initContainers", []) + wsp.get("containers", [])
check(cj is not None and wsp.get("automountServiceAccountToken") is False
      and find(nodes, "ServiceAccount", "tockmox-model-watch").get("automountServiceAccountToken") is False,
      "the watcher has no Kubernetes credentials")
check([c["name"] for c in wct] == ["watcher", "opener"], "the watcher runs first, the PR opener after it (pullRequests on)")
check(all(c["securityContext"].get("readOnlyRootFilesystem") and c["resources"].get("limits", {}).get("memory") for c in wct)
      and wsp.get("securityContext", {}).get("runAsNonRoot"), "watcher containers: non-root, read-only root, memory limit")
check(wpod.get("metadata", {}).get("labels", {}).get("tockmox.com/isolated") == "true", "the watcher pod is labelled isolated")
wcfg = yaml.safe_load(find(nodes, "ConfigMap", "tockmox-model-watch")["data"]["config.yaml"])["modelLifecycle"]["watch"]
check(wcfg.get("enabled") is True and wcfg["pullRequests"]["githubApp"]["privateKeyFile"] == "/bot/private-key.pem"
      and not set(wcfg) & {"image", "secrets", "egress", "schedule"}, "the watcher's config: on, key path pinned to the mount, no chart-only keys")
wnp = find(nodes, "NetworkPolicy", "tockmox-model-watch")
eg = (wnp or {}).get("spec", {}).get("egress", [])
dns = [r for r in eg if any(p["port"] == 53 for p in r.get("ports", []))]
web = [r for r in eg if r.get("ports") == [{"port": 443, "protocol": "TCP"}]]
check(wnp is not None and wnp["spec"]["policyTypes"] == ["Ingress", "Egress"] and wnp["spec"]["ingress"] == []
      and len(eg) == 2 and len(dns) == 1 and len(web) == 1
      and web[0]["to"][0]["ipBlock"]["cidr"] == "0.0.0.0/0" and PRIVATE <= set(web[0]["to"][0]["ipBlock"]["except"]),
      "the watcher's policy: no ingress; egress DNS and HTTPS to the internet only, every private range excepted")

# THE TOCKMOX UI: least authority, and egress exactly as documented
dep = find(nodes, "Deployment", "tockmox-ui")
usp = (dep or {}).get("spec", {}).get("template", {}).get("spec", {})
check(dep is not None and usp.get("serviceAccountName") == "tockmox-ui" and usp.get("automountServiceAccountToken") is True
      and all(c["securityContext"].get("readOnlyRootFilesystem") and c["resources"].get("limits", {}).get("memory") for c in usp["containers"]),
      "the UI: its own service account, non-root, read-only root, memory limit")
check(dep["spec"]["template"]["metadata"]["labels"].get("tockmox.com/isolated") == "true", "the UI pod is labelled isolated")
cr = find(nodes, "ClusterRole", "tockmox-ui-read"); ro = find(nodes, "Role", "tockmox-ui-read-applications")
check(cr["rules"] == [{"apiGroups": [""], "resources": ["nodes"], "verbs": ["get", "list"]}]
      and ro["rules"] == [{"apiGroups": ["argoproj.io"], "resources": ["applications"], "verbs": ["get", "list"]}],
      "the UI's Kubernetes authority is get/list on nodes and Argo CD applications, nothing else")
ucfg = yaml.safe_load(find(nodes, "ConfigMap", "tockmox-ui")["data"]["config.yaml"])
check(all(ucfg["inferenceNodes"].get(k) == v for k, v in fix["inferenceNodes"].items() if k != "monitoring")
      and ucfg["modelLifecycle"]["catalog"] == fix["modelLifecycle"]["catalog"]
      and ucfg["modelLifecycle"].get("reportFile") == "/var/lib/tockmox/model-watch/report.json"
      and ucfg["session"]["secretFile"] == "/etc/tockmox-ui/session/secret"
      and ucfg["oidc"]["clientSecretFile"] == "/etc/tockmox-ui/oidc/client-secret",
      "the UI reads the same inferenceNodes and modelLifecycle the gateway renders from, and the watcher's report")
mounts = {m["mountPath"]: m.get("readOnly") for m in usp["containers"][0]["volumeMounts"]}
check(mounts.get("/var/lib/tockmox/model-watch") is True, "the UI mounts the watcher's report read-only")
unp = find(nodes, "NetworkPolicy", "tockmox-ui")
ue = unp["spec"]["egress"]
ui_in = unp["spec"]["ingress"]
check(unp["spec"]["policyTypes"] == ["Ingress", "Egress"] and len(ui_in) == 2
      and ui_in[0]["ports"] == [{"port": 8080, "protocol": "TCP"}]
      and ui_in[0]["from"][0]["podSelector"] == {"matchLabels": {"app.kubernetes.io/name": "traefik"}}
      and ui_in[1]["ports"] == [{"port": 9464, "protocol": "TCP"}]
      and ui_in[1]["from"] == [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "tockmox-monitoring"}},
                                "podSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}}}],
      "the UI admits Traefik only on 8080, and Prometheus only on the metrics port 9464 (TM-1013)")
uports = {p["name"]: p["containerPort"] for p in usp["containers"][0]["ports"]}
uenv = {e["name"]: e.get("value") for e in usp["containers"][0]["env"]}
usvc = find(nodes, "Service", "tockmox-ui")
check(uports == {"http": 8080, "metrics": 9464} and uenv.get("TOCKMOX_UI_METRICS_PORT") == "9464"
      and {p["name"]: p["port"] for p in usvc["spec"]["ports"]} == {"http": 8080, "metrics": 9464},
      "the UI serves /metrics on its own port 9464 (TOCKMOX_UI_METRICS_PORT), which the Service names and the Ingress does not route")
ing_ports = {p["backend"]["service"]["port"].get("number") for r in find(nodes, "Ingress", "tockmox-ui")["spec"]["rules"] for p in r["http"]["paths"]}
check(ing_ports == {8080}, "the UI's Ingress routes the app port only, never the metrics port")
blocks = [p["ipBlock"]["cidr"] for r in ue for p in r.get("to", []) if "ipBlock" in p]
check(len(ue) == 4 and "0.0.0.0/0" not in blocks and blocks == ["10.0.0.0/16"],
      "with probing and the update check off, the UI's egress is DNS, the API (lanCIDR:6443), Prometheus/Alertmanager and Traefik; no node, no internet")
sys.exit(1 if bad else 0)
PY

# DEFAULT KEY MODELS: rendered into the production config, and it changes the config hash (so it rolls)
out=$(helm template t "$AI" -f "$BASE" -f "$FIX" --set 'modelLifecycle.productionKeys.defaultModels={local-chat,hosted-chat}' 2>&1 || true)
h=$( (grep -o 'tockmox.com/gateway-config": "[0-9a-f]\{16\}' <<<"$out" || true) | grep -o '[0-9a-f]\{16\}$' | head -1 || true)
if [ -z "$h" ]; then echo "FAIL default key models did not ask for a new gateway-config hash"; rc=1; else
helm template t "$AI" -f "$BASE" -f "$FIX" --set 'modelLifecycle.productionKeys.defaultModels={local-chat,hosted-chat}' \
  --set "litellm.podAnnotations.tockmox\.com/gateway-config=$h" > "$tmp/keys.yaml"
python3 - "$tmp/keys.yaml" <<'PY' || rc=1
import sys, yaml
cm = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "tockmox-litellm-config")
cfg = yaml.safe_load(cm["data"]["config.yaml"])
ok = cfg.get("litellm_settings", {}).get("default_key_generate_params") == {"models": ["local-chat", "hosted-chat"]}
print(("  ok " if ok else "FAIL ") + "default key models render as litellm_settings.default_key_generate_params, under a new config hash")
sys.exit(0 if ok else 1)
PY
fi

# THE UI'S CONDITIONAL EGRESS: the probe ranges appear only when set; the internet only with the update check
helm template t "$AI" -f "$BASE" -f "$FIX" --set 'inferenceNodes.probe.allowedCidrs={192.0.2.0/24}' \
  --set 'tockmoxUi.config.updateCheck.enabled=true' --set 'tockmoxUi.config.updateCheck.feedUrl=https://feed.example/releases.json' > "$tmp/ui-open.yaml"
python3 - "$tmp/ui-open.yaml" <<'PY' || rc=1
import sys, yaml
np = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "NetworkPolicy" and d["metadata"]["name"] == "tockmox-ui")
blocks = [p["ipBlock"] for r in np["spec"]["egress"] for p in r.get("to", []) if "ipBlock" in p]
ok = any(b["cidr"] == "192.0.2.0/24" for b in blocks) and any(b["cidr"] == "0.0.0.0/0" and "10.0.0.0/8" in b.get("except", []) for b in blocks)
print(("  ok " if ok else "FAIL ") + "probe ranges and HTTPS out appear in the UI's egress only when switched on")
sys.exit(0 if ok else 1)
PY

# A FEED FROM A CONFIGMAP (TM-1027): mounted at /feed, and NO HTTPS out for a file feed.
helm template t "$AI" -f "$BASE" -f "$FIX" --set 'tockmoxUi.config.updateCheck.enabled=true' \
  --set 'tockmoxUi.config.updateCheck.feedUrl=file:///feed/releases.json' --set 'tockmoxUi.updateFeed.configMap=site-feed' > "$tmp/ui-filefeed.yaml"
python3 - "$tmp/ui-filefeed.yaml" <<'PY' || rc=1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
np = next(d for d in docs if d.get("kind") == "NetworkPolicy" and d["metadata"]["name"] == "tockmox-ui")
dep = next(d for d in docs if d.get("kind") == "Deployment" and d["metadata"]["name"] == "tockmox-ui")
blocks = [p["ipBlock"] for r in np["spec"]["egress"] for p in r.get("to", []) if "ipBlock" in p]
pod = dep["spec"]["template"]["spec"]
mount = any(m["name"] == "update-feed" and m["mountPath"] == "/feed" and m.get("readOnly") for m in pod["containers"][0]["volumeMounts"])
vol = any(v["name"] == "update-feed" and v.get("configMap", {}).get("name") == "site-feed" for v in pod["volumes"])
ok = mount and vol and not any(b["cidr"] == "0.0.0.0/0" for b in blocks)
print(("  ok " if ok else "FAIL ") + "a ConfigMap feed is mounted read-only at /feed and opens no HTTPS out")
sys.exit(0 if ok else 1)
PY

# THE UI'S INGRESS: on by default, and OFF when turned off (Helm's `default` reads false as empty)
n_on=$(helm template t "$AI" -f "$BASE" -f "$FIX" --show-only templates/tockmox-ui.yaml | grep -c '^kind: Ingress' || true)
n_off=$(helm template t "$AI" -f "$BASE" -f "$FIX" --set tockmoxUi.ingress.enabled=false --show-only templates/tockmox-ui.yaml | grep -c '^kind: Ingress' || true)
if [ "$n_on" = 1 ] && [ "$n_off" = 0 ]; then echo "  ok the UI's Ingress renders by default and not when tockmoxUi.ingress.enabled is false"
else echo "FAIL the UI's Ingress: default $n_on, disabled $n_off (want 1 and 0)"; rc=1; fi

# EMPTY allowedClients MEANS NOBODY: the policy still renders, with no ingress rule.
helm template t "$AI" -f "$BASE" -f "$FIX" --set 'modelLifecycle.evalGateway.allowedClients=null' > "$tmp/none.yaml"
python3 - "$tmp/none.yaml" <<'PY' || rc=1
import sys, yaml
np = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "NetworkPolicy" and d["metadata"]["name"] == "tockmox-litellm-eval")
ok = np["spec"]["ingress"] == [] and np["spec"]["policyTypes"] == ["Ingress"]
print(("  ok " if ok else "FAIL ") + "with no allowedClients the eval gateway admits nobody")
sys.exit(0 if ok else 1)
PY

# THE REPORT VOLUME HAS TWO PODS (TM-0902). The watcher writes it, the UI reads it. ReadWriteOnce attaches to one
# node, so with both on the watcher must be required onto the UI's node and the UI must roll WITHOUT A SURGE
# (RollingUpdate, maxSurge 0: the old pod goes before the new one needs the volume). NOT `type: Recreate`: switching a
# live RollingUpdate Deployment to Recreate is refused under ServerSideApply (lab N1, 2026-10-08: tockmox-ai sat
# OutOfSync on "spec.strategy.rollingUpdate: Forbidden"; the same lesson as the Loki gateway, 2026-09-30);
# ReadWriteMany needs neither; ReadWriteOncePod cannot serve two pods and is refused.
colo() { helm template t "$AI" -f "$BASE" -f "$FIX" "$@" | python3 -c '
import sys, yaml
d = [x for x in yaml.safe_load_all(sys.stdin) if x]
cj = [x for x in d if x["kind"] == "CronJob" and x["metadata"]["name"] == "tockmox-model-watch"]
ui = [x for x in d if x["kind"] == "Deployment" and x["metadata"]["name"] == "tockmox-ui"]
aff = bool(cj) and "podAffinity" in (cj[0]["spec"]["jobTemplate"]["spec"]["template"]["spec"].get("affinity") or {})
st = (ui[0]["spec"].get("strategy") or {}) if ui else {}
ru = st.get("rollingUpdate") or {}
if st.get("type") == "Recreate":
    print("RECREATE")                    # never: refused over a live RollingUpdate Deployment
rec = bool(ui) and st.get("type") == "RollingUpdate" and str(ru.get("maxSurge")) == "0" and str(ru.get("maxUnavailable")) == "1"
print("%s %s" % (aff, rec))'; }
got=$(colo); if [ "$got" = "True True" ]; then echo "  ok RWO report volume: the watcher is required onto the UI's node and the UI rolls with maxSurge 0 (not Recreate)"
else echo "FAIL RWO report volume with the UI on: affinity/no-surge = $got (want True True): a surge would wait on Multi-Attach, Recreate is refused over a live Deployment"; rc=1; fi
got=$(colo --set 'modelLifecycle.watch.report.accessModes={ReadWriteMany}'); if [ "$got" = "False False" ]; then echo "  ok RWX report volume: no co-scheduling forced"
else echo "FAIL RWX report volume: affinity/no-surge = $got (want False False)"; rc=1; fi
refuse "a ReadWriteOncePod report volume" "has ReadWriteOncePod: the watcher writes the report" --set 'modelLifecycle.watch.report.accessModes={ReadWriteOncePod}' || rc=1

# ---- LAB FINDINGS 2026-10-08 (TM-0920 lab rehearsal, agent C; F4 F5 F6 F7 F8 F10 and the pages) -------------
# Each of these rendered cleanly and failed on a cluster. The assertions below evaluate the rendered NetworkPolicies
# the way the API server would for pod-to-pod traffic (selectors and ports; ipBlock rules are not evaluated, since a
# pod address is not known at render time), so a reach the pages deny cannot hide behind a tidy render.
helm template t charts/tockmox-exporters -f "$BASE" > "$tmp/exporters.yaml"
helm template t "$AI" -f "$BASE" -f "$FIX" --set global.certIssuer= > "$tmp/nodes-noca.yaml"
python3 - "$tmp/nodes.yaml" "$tmp/policy.yaml" "$tmp/exporters.yaml" "$AI/values.schema.json" tockmox-ui/app/nodes.py \
  charts/tockmox-exporters/values.yaml "$tmp/nodes-noca.yaml" "$tmp" <<'PY' || rc=1
import ast, json, os, re, subprocess, sys, yaml

def docs(path):
    return [d for d in yaml.safe_load_all(open(path)) if isinstance(d, dict) and d.get("kind")]
def find(ds, kind, name):
    return next((d for d in ds if d["kind"] == kind and d["metadata"]["name"] == name), None)
bad = 0
def check(cond, msg):
    global bad
    print(("  ok " if cond else "FAIL ") + msg)
    bad += (not cond)

nodes, policy, exporters = docs(sys.argv[1]), docs(sys.argv[2]), docs(sys.argv[3])
schema, uisrc, expvals, noca, tmp = json.load(open(sys.argv[4])), sys.argv[5], yaml.safe_load(open(sys.argv[6])), docs(sys.argv[7]), sys.argv[8]
AI_NS, MON_NS = "tockmox-ai", "tockmox-monitoring"

def sel(s, labels):
    if s is None:
        return False
    for k, v in (s.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in s.get("matchExpressions") or []:
        k, op, vals = e["key"], e["operator"], e.get("values") or []
        if op == "In" and labels.get(k) not in vals: return False
        if op == "NotIn" and k in labels and labels[k] in vals: return False
        if op == "Exists" and k not in labels: return False
        if op == "DoesNotExist" and k in labels: return False
    return True

def nsof(p):
    return p["metadata"].get("namespace") or AI_NS          # the AI layer's objects land in its release namespace
POLS = [p for p in nodes + policy if p["kind"] == "NetworkPolicy"]

def allows(direction, ns, labels, peer_ns, peer_labels, port):
    """True when some policy selecting (ns, labels) admits the peer on port, in that direction."""
    key, peers = ("ingress", "from") if direction == "Ingress" else ("egress", "to")
    for p in POLS:
        sp = p["spec"]
        if nsof(p) != ns or direction not in sp.get("policyTypes", []) or not sel(sp["podSelector"], labels):
            continue
        for r in sp.get(key) or []:
            if r.get("ports") and not any(x.get("port") == port for x in r["ports"]):
                continue
            if peers not in r:
                return True
            for q in r[peers]:
                if "ipBlock" in q:
                    continue
                nsok = sel(q["namespaceSelector"], {"kubernetes.io/metadata.name": peer_ns}) if "namespaceSelector" in q else peer_ns == ns
                if nsok and ("podSelector" not in q or sel(q["podSelector"], peer_labels)):
                    return True
    return False

def podlabels(kind, name):
    d = find(nodes, kind, name) or find(nodes, "StatefulSet", name)
    t = d["spec"]["jobTemplate"]["spec"]["template"] if kind == "CronJob" else d["spec"]["template"]
    return t["metadata"]["labels"]
UI, WATCH, EVAL = podlabels("Deployment", "tockmox-ui"), podlabels("CronJob", "tockmox-model-watch"), podlabels("Deployment", "tockmox-litellm-eval")
GW, OWUI = podlabels("Deployment", "t-litellm"), podlabels("Deployment", "t-open-webui")
PROM, AM = {"app.kubernetes.io/name": "prometheus"}, {"app.kubernetes.io/name": "alertmanager"}

# F8: the UI reads Prometheus and Alertmanager, and tockmox-monitoring is default-deny ingress
check(allows("Ingress", MON_NS, PROM, AI_NS, UI, 9090) and allows("Ingress", MON_NS, AM, AI_NS, UI, 9093),
      "F8 tockmox-monitoring admits the Tockmox UI to Prometheus :9090 and Alertmanager :9093")
check(not allows("Ingress", MON_NS, AM, AI_NS, OWUI, 9093) and not allows("Ingress", MON_NS, PROM, AI_NS, GW, 9090),
      "F8 ... and nothing else in tockmox-ai (Open WebUI, the gateway)")
# F10: isolated pods reach nothing in their own namespace through the policy layer's namespace-wide allow
for name, lab in (("the UI", UI), ("the watcher", WATCH), ("the eval gateway", EVAL)):
    check(not allows("Egress", AI_NS, lab, AI_NS, GW, 4000), f"F10 {name} cannot reach the model gateway (tockmox-ai-litellm:4000)")
check(allows("Egress", AI_NS, OWUI, AI_NS, GW, 4000), "F10 ... while Open WebUI still can (the namespace allow still serves non-isolated pods)")
# F5: the eval gateway gets the production gateway's provider and node egress
gwp = find(policy, "NetworkPolicy", "allow-egress-litellm")
check(gwp is not None and sel(gwp["spec"]["podSelector"], GW) and sel(gwp["spec"]["podSelector"], EVAL),
      "F5 allow-egress-litellm (providerAllow + extraEgress) selects the eval gateway as well as the production gateway")
check(not sel(gwp["spec"]["podSelector"], UI) and not sel(gwp["spec"]["podSelector"], WATCH) and not sel(gwp["spec"]["podSelector"], OWUI),
      "F5 ... and no other pod")

# F6: mlx-lm (Python http.server) answers HTTP/1.0; the inference-node Probe must accept it
mods = expvals["prometheus-blackbox-exporter"]["config"]["modules"]
pr = find(nodes, "Probe", "tockmox-inference-nodes")
im = mods.get(pr["spec"]["module"]) if pr else None
check(im is not None and "HTTP/1.0" in im["http"]["valid_http_versions"] and 401 in im["http"]["valid_status_codes"],
      f"F6 the inference-node Probe's module ({pr['spec']['module']}) exists in the exporters layer and accepts HTTP/1.0 and 401")
check("HTTP/1.0" not in mods["http_console"]["http"]["valid_http_versions"], "F6 ... and the consoles' http_console module is unchanged")
bb = "\n".join(d["data"].get("blackbox.yaml", "") for d in exporters if d["kind"] == "ConfigMap" and "data" in d)
check(pr is not None and pr["spec"]["module"] + ":" in bb, "F6 ... and that module is in the blackbox exporter's rendered config")

# F4: the UI refuses a node type or engine outside its catalogue (CrashLoopBackOff), so the schema must too
tree = ast.parse(open(uisrc).read())
def dict_keys(name):
    for n in tree.body:
        if isinstance(n, (ast.Assign, ast.AnnAssign)):
            tgt = n.targets[0] if isinstance(n, ast.Assign) else n.target
            if getattr(tgt, "id", None) == name:
                return [k.value for k in n.value.keys]
    return None
item = schema["properties"]["inferenceNodes"]["properties"]["nodes"]["items"]["properties"]
check(item.get("type", {}).get("enum") == dict_keys("CATALOG"), "F4 nodes[].type's schema enum is the UI's CATALOG, in order")
check(item["endpoints"]["items"]["properties"]["engine"].get("enum") == dict_keys("ENGINES"),
      "F4 nodes[].endpoints[].engine's schema enum is the UI's ENGINES, in order")
mtree = ast.parse(open(os.path.join(os.path.dirname(uisrc), "models.py")).read())
tracks = next((ast.literal_eval(n.value) for n in mtree.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", None) == "TRACKS"), None)
cat = schema["properties"]["modelLifecycle"]["properties"]["catalog"]["items"].get("properties", {})
check(cat.get("track", {}).get("items", {}).get("enum") == list(tracks or ()) and "baseModel" in cat,
      "F9 modelLifecycle.catalog[].track's schema enum is the UI's TRACKS, and baseModel is declared")

# F7: the UI does its OIDC exchange itself; with certIssuer it must trust the Tockmox CA AND the public roots
def ui_pod(ds):
    return find(ds, "Deployment", "tockmox-ui")["spec"]["template"]["spec"]
sp = ui_pod(nodes)
inits = [c for c in sp.get("initContainers") or [] if c["name"] == "tockmox-trust-bundle"]
main = sp["containers"][0]
env = {e["name"]: e.get("value") for e in main.get("env") or []}
vols = {v["name"]: v for v in sp["volumes"]}
ing = find(nodes, "Ingress", "tockmox-ui")
tls = ing["spec"]["tls"][0]["secretName"] if ing and ing["spec"].get("tls") else None
check(len(inits) == 1 and inits[0]["image"] == main["image"], "F7 the UI has a tockmox-trust-bundle initContainer on its own image")
check(env.get("SSL_CERT_FILE") == env.get("REQUESTS_CA_BUNDLE") == "/etc/tockmox/trust/ca-bundle.crt"
      and any(m["name"] == "tockmox-trust" and m["mountPath"] == "/etc/tockmox/trust" for m in main["volumeMounts"]),
      "F7 SSL_CERT_FILE and REQUESTS_CA_BUNDLE point at the bundle the application mounts")
cav = vols.get("tockmox-ca", {}).get("secret", {})
check(tls is not None and cav.get("secretName") == tls and cav.get("optional") is True and "emptyDir" in vols.get("tockmox-trust", {}),
      "F7 the CA comes from the UI's own Ingress certificate Secret (optional), the bundle is an emptyDir")
ienv = lambda ds: {e["name"]: e.get("value") for e in (ui_pod(ds).get("initContainers") or [{}])[0].get("env") or []}
check(ienv(nodes).get("TOCKMOX_EXPECT_CA") == "true" and ienv(noca).get("TOCKMOX_EXPECT_CA") == "false",
      "F7 the initContainer waits for the CA only when global.certIssuer is set")
# run the initContainer's script against a fake store and CA: the bundle is the store plus the CA, never the CA alone
if inits:
    script = inits[0]["args"][0]
    for d in ("store", "ca", "trust"):
        os.makedirs(f"{tmp}/f7/{d}", exist_ok=True)
    open(f"{tmp}/f7/store/ca-certificates.crt", "w").write("PUBLIC-ROOTS\n")
    open(f"{tmp}/f7/ca/ca.crt", "w").write("TOCKMOX-CA\n")
    s = (script.replace("/etc/ssl/certs/ca-certificates.crt", f"{tmp}/f7/store/ca-certificates.crt")
               .replace("/tockmox-ca/", f"{tmp}/f7/ca/").replace("/trust/", f"{tmp}/f7/trust/"))
    r = subprocess.run(["sh", "-c", s], env={"PATH": os.environ["PATH"], "TOCKMOX_EXPECT_CA": "true"}, capture_output=True, text=True, timeout=20)
    got = open(f"{tmp}/f7/trust/ca-bundle.crt").read() if os.path.exists(f"{tmp}/f7/trust/ca-bundle.crt") else ""
    check(r.returncode == 0 and got == "PUBLIC-ROOTS\nTOCKMOX-CA\n", "F7 the script writes the image's public roots plus the Tockmox CA")
else:
    check(False, "F7 the script writes the image's public roots plus the Tockmox CA (no initContainer to run)")
sys.exit(1 if bad else 0)
PY
refuse "F4 a node type the UI does not know (the lab's 'workstation')" "/inferenceNodes/nodes/0/type" \
  --set 'inferenceNodes.nodes[0].type=workstation' || rc=1
refuse "F4 an engine the UI does not know" "/inferenceNodes/nodes/0/endpoints/0/engine" \
  --set 'inferenceNodes.nodes[0].endpoints[0].engine=koboldcpp' || rc=1
refuse "F9 a catalog track the UI does not know" "/modelLifecycle/catalog/0/track/0" \
  --set 'modelLifecycle.catalog[0].track={quant}' || rc=1

# ---- EVERY OLLAMA ROUTE PINS ITS CONTEXT (TM-0957) -----------------------------------------------------------------
# A request with no num_ctx gets Ollama's default context, which current Ollama sizes from the node's memory: 256k
# tokens on 48 GiB or more. Qwen3-Coder-30B at 256k is a 24 GiB KV cache on top of 19 GiB of weights; that is how a
# lab route reached a 64 GiB node with none (2026-10-08). It renders cleanly, so the render must refuse it. Helm
# replaces a list given with --set, so each case is a values file holding the fixture's routes with one change, and
# the routes hash the UI computes for them: without it every case is refused as a stale annotation, which proves nothing.
python3 - "$FIX" "$tmp" <<'PY' || rc=1
import sys, yaml
sys.path.insert(0, "tockmox-ui")
from app.nodes import parse_inventory, roll_block
fix, tmp = yaml.safe_load(open(sys.argv[1])), sys.argv[2]
def case(name, alias, change):
    block = yaml.safe_load(yaml.safe_dump(fix["inferenceNodes"]))
    change(next(r for r in block["routes"] if r["alias"] == alias).setdefault("params", {}))
    yaml.safe_dump({"inferenceNodes": {"routes": block["routes"]}, "litellm": roll_block(parse_inventory(block))},
                   open(f"{tmp}/{name}.yaml", "w"))
case("ctx-chat", "local-coder", lambda p: p.pop("num_ctx"))
case("ctx-embed", "local-embed", lambda p: p.pop("num_ctx"))
case("ctx-string", "local-coder", lambda p: p.update(num_ctx="16k"))
case("ctx-zero", "local-coder", lambda p: p.update(num_ctx=0))
PY
refuse "TM-0957 an Ollama chat route with no num_ctx" "route local-coder on studio/ollama-11434 sets no params.num_ctx" \
  -f "$tmp/ctx-chat.yaml" || rc=1
refuse "TM-0957 an Ollama embedding route with no num_ctx" "route local-embed on studio/ollama-11434 sets no params.num_ctx" \
  -f "$tmp/ctx-embed.yaml" || rc=1
refuse "TM-0957 num_ctx that is not a whole number" "/inferenceNodes/routes/2/params/num_ctx" \
  -f "$tmp/ctx-string.yaml" || rc=1
refuse "TM-0957 num_ctx of zero" "/inferenceNodes/routes/2/params/num_ctx" \
  -f "$tmp/ctx-zero.yaml" || rc=1

# ---- THE PAGES THE LAB NEEDED (F2 F3 F4 F9 F12, O1, F14) ---------------------------------------------------------
# A reader built a site from these pages and it did not work. Each line is a fact the page must state.
python3 - "$AI/values.schema.json" <<'PY' || rc=1
import json, re, sys
bad = 0
def has(page, needle, why):
    global bad
    txt = open(page).read()
    ok = needle in txt
    print(("  ok " if ok else "FAIL ") + f"{page}: {why}")
    bad += (not ok)
def section(page, lead):
    # from the paragraph that opens with **<lead> to the next bold-led paragraph or heading
    txt = open(page).read()
    m = re.search(r"^\*\*" + re.escape(lead) + r"(.*?)(?=^\*\*|^#+ |^For |\Z)", txt, re.S | re.M)
    return m.group(1) if m else ""
item = json.load(open(sys.argv[1]))["properties"]["inferenceNodes"]["properties"]["nodes"]["items"]["properties"]
for t in item.get("type", {}).get("enum") or ["<no enum>"]:
    has("docs/administration/inference-nodes.md", f"`{t}`", f"F4 lists node type {t}")
for n, why in (("`track`", "F9 documents a catalog entry's track"), ("`baseModel`", "F9 documents baseModel"),
               ("`quants`", "F9 names the quants track"), ("`successors`", "F9 names the successors track"),
               ("`revision`", "F9 names the revision track"), ("--with-eval-gateway", "F3 gives the command that mints the eval key"),
               ("allow-egress-litellm", "F5 says the eval gateway shares the gateway's egress")):
    has("docs/administration/model-lifecycle.md", n, why)
for n, why in (("adding-an-application.md", "F2 says how to register the UI with Authentik"),
               ("--with-tockmox-ui", "F3 gives the command that mints both UI Secrets"),
               ("tockmox-trust-bundle", "F7 says how the UI trusts the Tockmox CA")):
    has("docs/administration/tockmox-ui.md", n, why)
s = section("docs/deployment/upgrade.md", "For 0.8.0")
ok = "apps.litellm.enabled" in s
print(("  ok " if ok else "FAIL ") + "docs/deployment/upgrade.md: F12 the 0.8.0 section names apps.litellm.enabled where the exporters layer reads it")
bad += (not ok)
has("docs/deployment/install.md", "productionKeys.defaultModels", "O1 the console key it mints sees only productionKeys.defaultModels when set")
has("tools/mint-secrets.sh", "tockmox-ui-session", "F3 mints tockmox-ui-session")
has("tools/mint-secrets.sh", "tockmox-sso-tockmox-ui", "F3 mints tockmox-sso-tockmox-ui")
has("tools/mint-secrets.sh", "tockmox-litellm-eval", "F3 mints tockmox-litellm-eval")
sys.exit(1 if bad else 0)
PY

# ---- F13 (TM-0978, 0.8.0 upgrade and greenfield labs 2026-10-08): the node's path through the policy layer -------
# Four pages say "put the node's address and ports in aiEgress.litellm.extraEgress" and none showed the shape; the
# natural one, providerAllow's {cidr, ports} documented directly above it, rendered clean and failed at the Argo apply
# (".spec.egress[1].cidr: field not declared in schema"). The schema now types the items, so the wrong shape is refused
# at render with a sentence, and every page that names the key shows one correct entry.
POL=charts/tockmox-policy
cat > "$tmp/eg-wrong.yaml" <<'EOF2'
aiEgress:
  litellm:
    extraEgress:
      - cidr: 192.0.2.10/32
        ports: [11434]
EOF2
cat > "$tmp/eg-right.yaml" <<'EOF2'
aiEgress:
  litellm:
    extraEgress:
      - to: [{ipBlock: {cidr: 192.0.2.10/32}}]
        ports: [{protocol: TCP, port: 11434}]
  openWebui:
    extraEgress:
      - to: [{ipBlock: {cidr: 192.0.2.10/32}}]
        ports: [{protocol: TCP, port: 11434}]
  cnpg:
    extraEgress:
      - to: [{ipBlock: {cidr: 192.0.2.20/32}}]
        ports: [{protocol: TCP, port: 9000}]
EOF2
for comp in litellm openWebui cnpg; do
  if out=$(helm template t "$POL" -f "$BASE" --set "aiEgress.$comp.extraEgress[0].cidr=192.0.2.10/32" --set "aiEgress.$comp.extraEgress[0].ports[0]=11434" 2>&1); then
    echo "FAIL F13 aiEgress.$comp.extraEgress accepted providerAllow's {cidr, ports} shape (it fails at apply, not render)"; rc=1
  elif grep -q "extraEgress/0.*missing property 'to'" <<<"$out"; then echo "  ok F13 aiEgress.$comp.extraEgress refuses {cidr, ports} at render, naming the missing 'to'"
  else echo "FAIL F13 aiEgress.$comp.extraEgress refused {cidr, ports} without naming 'to'"; echo "$out" | tail -3; rc=1; fi
done
if helm template t "$POL" -f "$BASE" -f "$tmp/eg-wrong.yaml" >/dev/null 2>&1; then echo "FAIL F13 the wrong shape from a values file renders"; rc=1
else echo "  ok F13 the wrong shape from a values file is refused"; fi
if helm template t "$POL" -f "$BASE" -f "$tmp/eg-right.yaml" > "$tmp/eg-right.out" 2>"$tmp/eg-right.err"; then
  n=$(grep -c "cidr: 192.0.2.10/32" "$tmp/eg-right.out" || true)
  if [ "$n" -ge 2 ]; then echo "  ok F13 a NetworkPolicy egress rule renders into the gateway's and the console's policies ($n ipBlocks)"
  else echo "FAIL F13 the right shape rendered but reached $n policies (want 2)"; rc=1; fi
else echo "FAIL F13 the right shape (to + ports) is refused:"; tail -3 "$tmp/eg-right.err"; rc=1; fi
for page in docs/administration/inference-nodes.md docs/deployment/upgrade.md docs/administration/model-lifecycle.md docs/administration/external-integrations.md; do
  if grep -q "ipBlock: {cidr:" "$page" && grep -q "policy.yaml" "$page"; then echo "  ok F13 $page shows the extraEgress shape and names policy.yaml"
  else echo "FAIL F13 $page sends a reader to aiEgress.litellm.extraEgress without the shape or the file"; rc=1; fi
done

[ "$rc" -eq 0 ] && echo "check-inference-nodes: ok" || echo "check-inference-nodes: FAILED"
exit "$rc"

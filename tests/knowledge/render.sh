#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2015  # `ok ... || bad ...`: ok and bad are printf wrappers that return 0, so C runs only when A or B failed
#
# KNOWLEDGE MODE, AT RENDER (TM-1256). What the chart renders when knowledge is
# on, and that every refusal in templates/knowledge.yaml fires: each one guards
# a failure that is quiet otherwise (documents embedded off-site, restricted
# material on a shared console, records and vectors restored at two points).
# Each refusal case flips ONE value from the passing fixture, so a refusal that
# stops firing turns this red rather than passing for some other reason.
#
#   tests/knowledge/render.sh            (needs helm and python3 with PyYAML)
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$root/charts/tockmox-ai"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
base=(-f "$root/ci/values.yaml" -f "$root/ci/values-inference-nodes.yaml")
render() { helm template t "$chart" "${base[@]}" "$@" > "$tmp/out.yaml" 2> "$tmp/err"; }

# 0. off by default: nothing rendered (the console's optional envFrom ref names a ConfigMap that does not exist: harmless)
if render; then
  python3 - "$tmp/out.yaml" <<'PY' && ok "0 off: no Knowledge objects render by default" || bad "0 off: Knowledge objects rendered by default"
import sys, yaml
names = [d["metadata"]["name"] for d in yaml.safe_load_all(open(sys.argv[1])) if d]
sys.exit(1 if any(n in ("tockmox-ai-knowledge-env", "tockmox-knowledge-sync") for n in names) else 0)
PY
else bad "0 default render failed: $(tail -1 "$tmp/err")"; fi

# 1. the passing fixture
if render -f "$root/ci/values-knowledge.yaml"; then
  python3 - "$tmp/out.yaml" <<'PY' && ok "1 on: env, sync config, hardened Deployment and fenced NetworkPolicy, as designed" || bad "1 on: see above"
import sys, yaml
docs = {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
errs = []
env = docs[("ConfigMap", "tockmox-ai-knowledge-env")]["data"]
want = {"RAG_EMBEDDING_ENGINE": "openai", "RAG_EMBEDDING_MODEL": "local-embed", "ENABLE_RAG_HYBRID_SEARCH": "true",
        "ENABLE_KNOWLEDGE_FILE_RETENTION": "false", "VECTOR_DB": "chroma"}
for k, v in want.items():
    if env.get(k) != v: errs.append(f"env {k}={env.get(k)!r}, want {v!r}")
# Open WebUI 0.12.4 defaults the RAG URL to https://api.openai.com/v1, not to the console's gateway: it must be explicit
if env.get("RAG_OPENAI_API_BASE_URL") != "http://t-litellm:4000/v1": errs.append(f"RAG URL {env.get('RAG_OPENAI_API_BASE_URL')!r}, want the gateway")
if env.get("BYPASS_RETRIEVAL_ACCESS_CONTROL") != "false": errs.append("retrieval access control not asserted")
for k in ("RAG_OPENAI_API_KEY", "OPENAI_API_KEY", "RAG_EXTERNAL_RERANKER_API_KEY"):
    if k in env: errs.append(f"env ConfigMap carries {k}: a key belongs in a Secret")
if "RAG_RERANKING_ENGINE" in env: errs.append("reranking configured with no rerankModel")
# sync on: API keys on, and limited to the endpoints oikb calls
if (env.get("ENABLE_API_KEYS"), env.get("ENABLE_API_KEYS_ENDPOINT_RESTRICTIONS"), env.get("API_KEYS_ALLOWED_ENDPOINTS")) != \
        ("true", "true", "/api/v1/knowledge,/api/v1/files"):
    errs.append("console API keys not on, or not limited to the Knowledge and file endpoints")
ow = docs[("StatefulSet", "t-open-webui")]["spec"]["template"]["spec"]["containers"][0]["envFrom"]
if {"configMapRef": {"name": "tockmox-ai-knowledge-env", "optional": True}} not in ow: errs.append("console does not read the env ConfigMap")
if {"secretRef": {"name": "tockmox-ai-knowledge-key", "optional": True}} not in ow: errs.append("console does not read the key Secret")
cfg = yaml.safe_load(docs[("ConfigMap", "tockmox-knowledge-sync")]["data"][".oikb.yaml"])
if cfg["sources"] != [{"name": "handbook", "source": "/data/handbook/current/docs", "kb-id": "11111111-2222-3333-4444-555555555555"}]:
    errs.append(f"oikb sources {cfg['sources']}")
pod = docs[("Deployment", "tockmox-knowledge-sync")]["spec"]["template"]
spec = pod["spec"]
if spec.get("automountServiceAccountToken") is not False: errs.append("service account token mounted")
if pod["metadata"]["labels"].get("tockmox.com/isolated") != "true": errs.append("not isolated")
for c in spec["containers"]:
    sc = c.get("securityContext", {})
    if sc.get("readOnlyRootFilesystem") is not True or sc.get("capabilities", {}).get("drop") != ["ALL"] or sc.get("allowPrivilegeEscalation") is not False:
        errs.append(f"container {c['name']} not hardened")
    if "@sha256:" not in c["image"]: errs.append(f"container {c['name']} image not pinned by digest")
oikb = [c for c in spec["containers"] if c["name"] == "oikb"][0]
if [m for m in oikb["volumeMounts"] if m["name"] == "data" and not m.get("readOnly")]: errs.append("oikb can write the git checkout")
url = [e for e in oikb["env"] if e["name"] == "OPEN_WEBUI_URL"][0]["value"]
if oikb["args"][-2:] != ["--config", "/config/.oikb.yaml"]: errs.append(f"oikb args {oikb['args']}")
oenv = {e["name"]: e.get("value") for e in oikb["env"]}
if oenv.get("OIKB_CONFIG_DIR") != "/state" or not [m for m in oikb["volumeMounts"] if m["mountPath"] == "/state" and not m.get("readOnly")]:
    errs.append("oikb has no writable state directory for its history (the root filesystem is read-only)")
if url != "http://t-open-webui:80": errs.append(f"OPEN_WEBUI_URL {url}")
np = docs[("NetworkPolicy", "tockmox-knowledge-sync")]["spec"]
if np["ingress"] != [] or set(np["policyTypes"]) != {"Ingress", "Egress"}: errs.append("sync pod reachable or egress unfenced")
peers = [t for e in np["egress"] for t in e.get("to", [])]
if {"podSelector": {"matchLabels": {"app.kubernetes.io/component": "open-webui"}}} not in peers: errs.append("no egress to the console")
if {"ipBlock": {"cidr": "192.0.2.30/32"}} not in peers: errs.append("no egress to the source host")
if any("ipBlock" in t and t["ipBlock"].get("cidr") == "0.0.0.0/0" for t in peers): errs.append("egress to the internet")
for e in errs: print("       " + e)
sys.exit(1 if errs else 0)
PY
else bad "1 on: render failed: $(tail -1 "$tmp/err")"; fi

# 2. the refusals: one value flipped from the passing fixture each, and the message that must say why
refuse() {   # $1 label, $2 expected message fragment, rest: --set args
  local label="$1" want="$2"; shift 2
  if render -f "$root/ci/values-knowledge.yaml" "$@"; then bad "$label: rendered, expected a refusal"
  elif grep -q -- "$want" "$tmp/err"; then ok "$label"
  else bad "$label: refused, but not for this reason: $(grep -o 'execution error.*' "$tmp/err" | head -c 300)"; fi
}
refuse "2a restricted source refused"            "public or internal material only" --set 'knowledge.sync.sources[0].classification=restricted'
refuse "2b confidential source refused"          "public or internal material only" --set 'knowledge.sync.sources[0].classification=confidential'
refuse "2c hosted embedding model refused"       "not a model on the production gateway" --set knowledge.embeddingModel=text-embedding-3-large
cat > "$tmp/ext.yaml" <<'Y'
litellm:
  proxy_config:
    model_list:
      - {model_name: cloud-embed, litellm_params: {model: openai/text-embedding-3-large}, model_info: {endpoint_tier: external}}
Y
# a hand-written route changes the gateway config, whose hash a render-mode site restates (litellm-config.yaml): take it
render -f "$root/ci/values-knowledge.yaml" -f "$tmp/ext.yaml" --set knowledge.embeddingModel=local-embed
h=$(grep -o 'gateway-config": "[0-9a-f]*"' "$tmp/err" | grep -o '[0-9a-f]\{16\}' | head -1)
refuse "2d external-tier embedding route refused" "is not a local-tier route" -f "$tmp/ext.yaml" --set knowledge.embeddingModel=cloud-embed \
  ${h:+--set-string "litellm.podAnnotations.tockmox\.com/gateway-config=$h"}
refuse "2e pgvector without CNPG refused"        "the console is not on CNPG" --set knowledge.vectorStore=pgvector
refuse "2f source without a Knowledge base id"   "knowledgeId" --set 'knowledge.sync.sources[0].knowledgeId='
cat > "$tmp/dup.yaml" <<'Y'
knowledge:
  sync:
    sources:
      - {name: a, repo: "https://forge.example/a.git", knowledgeId: same, classification: public}
      - {name: b, repo: "https://forge.example/b.git", knowledgeId: same, classification: public}
Y
refuse "2g two sources on one Knowledge base"    "both write Knowledge base" -f "$tmp/dup.yaml"
refuse "2h sync with no source egress"           "sourceEgress is empty" --set 'knowledge.sync.sourceEgress=null'
refuse "2i no embedding model"                   "embeddingModel is empty" --set knowledge.embeddingModel=
refuse "2j rerank model not on the gateway"      "knowledge.rerankModel \"nope\" is not a model" --set knowledge.rerankModel=nope
refuse "2k gateway off refused"                  "the gateway (apps.litellm) is off" --set apps.litellm.enabled=false --set open-webui.openaiBaseApiUrl=http://model-host.example:8000/v1

# 3. the positive control for 2e: pgvector with the console on CNPG renders, with the extension left to CNPG
if render -f "$root/ci/values-knowledge.yaml" --set knowledge.vectorStore=pgvector --set modelGateway.upgradeBackup.openWebuiClusterName=owui-pg; then
  grep -q 'PGVECTOR_CREATE_EXTENSION: "false"' "$tmp/out.yaml" && grep -q 'VECTOR_DB: "pgvector"' "$tmp/out.yaml" \
    && ok "3 pgvector on CNPG renders, extension creation left to the cluster" || bad "3 pgvector env missing"
else bad "3 pgvector on CNPG: render failed: $(grep -o 'execution error.*' "$tmp/err" | head -c 300)"; fi

# 4. reranking through the gateway, on the node route local-rerank
if render -f "$root/ci/values-knowledge.yaml" --set knowledge.rerankModel=local-rerank; then
  grep -q 'RAG_RERANKING_ENGINE: "external"' "$tmp/out.yaml" && grep -q 'RAG_EXTERNAL_RERANKER_URL: "http://t-litellm:4000/v1/rerank"' "$tmp/out.yaml" \
    && ok "4 rerank: external engine at the gateway's /v1/rerank" || bad "4 rerank env missing"
else bad "4 rerank: render failed: $(grep -o 'execution error.*' "$tmp/err" | head -c 300)"; fi

[ "$fail" = 0 ] && { echo "knowledge render: PASSED"; exit 0; }
echo "knowledge render: FAILED"; exit 1

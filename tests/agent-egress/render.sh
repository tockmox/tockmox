#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2015  # `ok ... || bad ...`: ok and bad are printf wrappers that return 0, so C runs only when A or B failed
#
# PER-TOOL EGRESS, AT RENDER (TM-1251). What the policy layer renders for the
# two tiers in ci/values-agent-egress.yaml, and that every refusal in
# templates/agent-egress.yaml fires. Each refusal case changes ONE value from
# the passing fixture, so a refusal that stops firing turns this red rather
# than passing for some other reason.
#
# The proxy's own behaviour (the ACL and the private-range refusal, against a
# real Smokescreen) is tests/agent-egress/proxy-proof.sh; the network fence on
# kube-router is the lab proof.
#
#   tests/agent-egress/render.sh         (needs helm and python3 with PyYAML)
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$root/charts/tockmox-policy"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
render() { helm template t "$chart" -n argocd -f "$root/ci/values.yaml" "$@" > "$tmp/out.yaml" 2> "$tmp/err"; }

# 0. off by default
if render; then
  grep -qE "namespace: tockmox-agents|agent-default-deny-egress" "$tmp/out.yaml" && bad "0 off: agent egress rendered by default" \
    || ok "0 off: nothing renders by default"
else bad "0 default render failed: $(tail -1 "$tmp/err")"; fi

# 1. the passing fixture
if render -f "$root/ci/values-agent-egress.yaml"; then
  python3 - "$tmp/out.yaml" <<'PY' && ok "1 on: deny + DNS, the CIDR tool verbatim, the hostname tool fenced to its own proxy, as designed" || bad "1 on: see above"
import sys, yaml
docs = {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(sys.argv[1]))
        if d and d["metadata"].get("namespace") == "tockmox-agents"}
errs = []
deny = docs[("NetworkPolicy", "agent-default-deny-egress")]["spec"]
if deny != {"podSelector": {}, "policyTypes": ["Egress"]}: errs.append(f"default deny {deny}")
cidr = docs[("NetworkPolicy", "allow-egress-tool-k8s-ro")]["spec"]
if cidr["podSelector"] != {"matchLabels": {"app.kubernetes.io/name": "example-k8s-mcp"}}: errs.append("CIDR tool selector")
if cidr["egress"] != [{"to": [{"ipBlock": {"cidr": "192.0.2.10/32"}}], "ports": [{"protocol": "TCP", "port": 6443}]}]:
    errs.append(f"CIDR tool egress not verbatim: {cidr['egress']}")
tool = docs[("NetworkPolicy", "allow-egress-tool-web-fetch")]["spec"]
if tool["egress"] != [{"to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "agent-egress-proxy-web-fetch"}}}],
                       "ports": [{"protocol": "TCP", "port": 4750}]}]:
    errs.append(f"hostname tool may reach more than its proxy: {tool['egress']}")
px = docs[("NetworkPolicy", "agent-egress-proxy-web-fetch")]["spec"]
froms = [f for r in px["ingress"] for f in r["from"]]
if {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "example-web-mcp"}}} not in froms: errs.append("proxy not reachable by its tool")
if len(px["ingress"]) != 2: errs.append("proxy reachable by more than its tool and Prometheus")
eg = px["egress"]
if len(eg) != 1 or eg[0]["ports"] != [{"protocol": "TCP", "port": 443}]: errs.append(f"proxy egress {eg}")
ex = set(eg[0]["to"][0]["ipBlock"]["except"])
for need in ("10.42.0.0/16", "10.43.0.0/16", "169.254.0.0/16"):
    if need not in ex: errs.append(f"proxy egress does not except {need}")
cm = docs[("ConfigMap", "agent-egress-proxy-web-fetch")]["data"]
acl = yaml.safe_load(cm["acl.yaml"]); cfg = yaml.safe_load(cm["config.yaml"])
if acl["default"]["action"] != "enforce" or acl["default"]["allowed_domains"] != ["docs.example.org", "*.example.com"]:
    errs.append(f"ACL {acl}")
if acl["services"]: errs.append("ACL has service rules: with no client certificate only the default rule applies")
if cfg.get("allow_missing_role") is not True or cfg.get("unsafe_allow_private_ranges"): errs.append(f"proxy config {cfg}")
dep = docs[("Deployment", "agent-egress-proxy-web-fetch")]["spec"]["template"]["spec"]
c = dep["containers"][0]
if dep.get("automountServiceAccountToken") is not False: errs.append("proxy mounts a token")
sc = c["securityContext"]
if sc.get("readOnlyRootFilesystem") is not True or sc.get("capabilities", {}).get("drop") != ["ALL"]: errs.append("proxy not hardened")
if "@sha256:" not in c["image"]: errs.append("proxy image not pinned")
for e in errs: print("       " + e)
sys.exit(1 if errs else 0)
PY
else bad "1 on: render failed: $(tail -1 "$tmp/err")"; fi

# 2. the refusals: one value changed from the passing fixture each, and the sentence that must say why
refuse() {
  local label="$1" want="$2"; shift 2
  if render -f "$root/ci/values-agent-egress.yaml" "$@"; then bad "$label: rendered, expected a refusal"
  elif grep -qE -- "$want" "$tmp/err"; then ok "$label"
  else bad "$label: refused, but not for this reason: $(grep -oE 'execution error.*|agentEgress.*' "$tmp/err" | head -c 300)"; fi
}
y() { printf '%s\n' "$2" > "$tmp/$1.yaml"; echo "$tmp/$1.yaml"; }
refuse "2a no namespace"                 "agentEgress.namespace is empty"        --set agentEgress.namespace=
refuse "2b a Tockmox namespace"          "is Tockmox's ai namespace"             --set agentEgress.namespace=tockmox-ai
refuse "2c no tools"                     "agentEgress.tools is empty"            --set agentEgress.tools=null
refuse "2d empty podSelector"            "podSelector is empty|web-fetch[./]podSelector(: |': )"  --set agentEgress.tools.web-fetch.podSelector=null
refuse "2e empty label value"            "is empty or not a string|podSelector[./]app.kubernetes.io(/|~1)name(: |': )"  --set-string 'agentEgress.tools.web-fetch.podSelector.app\.kubernetes\.io/name='
refuse "2f both tiers"                   "sets both extraEgress and allowHosts"  -f "$(y both 'agentEgress: {tools: {k8s-ro: {allowHosts: [a.example.com]}}}')"
refuse "2g neither tier"                 "sets neither extraEgress|web-fetch[./]allowHosts(: |': )"  -f "$(y neither 'agentEgress: {tools: {web-fetch: {allowHosts: null}}}')"
# shellcheck disable=SC2016  # a literal backtick in the message to match
refuse "2h the {cidr, ports} shape"      'has `cidr` at the top|k8s-ro[./]extraEgress[./]0(: |'"'"': )'  -f "$(y shape 'agentEgress: {tools: {k8s-ro: {extraEgress: [{cidr: 192.0.2.10/32, ports: [6443]}]}}}')"
# shellcheck disable=SC2016  # the same
refuse "2i an entry with no to"          'has no `to`'                           -f "$(y noto 'agentEgress: {tools: {k8s-ro: {extraEgress: [{ports: [{port: 6443}]}]}}}')"
refuse "2j an IP literal host"           "is an address, not a hostname"         -f "$(y ip 'agentEgress: {tools: {web-fetch: {allowHosts: ["203.0.113.7"]}}}')"
refuse "2k a bare * host"                "a bare [*] would allow everything"  -f "$(y star 'agentEgress: {tools: {web-fetch: {allowHosts: ["*"]}}}')"
refuse "2l hostname tier, no image"      "agentEgress.proxy.image is empty"  --set agentEgress.proxy.image=
refuse "2m a tool name that is no label" "is not a lowercase DNS label"          -f "$(y name 'agentEgress: {tools: {Web_Fetch: {podSelector: {a: b}, allowHosts: [a.example.com]}}}')"

[ "$fail" = 0 ] && { echo "agent egress render: PASSED"; exit 0; }
echo "agent egress render: FAILED"; exit 1

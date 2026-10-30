#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE POLICY GATE'S CONFIG INVARIANT, ON THE RENDER (TM-0383; REQ-0003 AC-3.2).
#
# The gate is a generic engine and every decision it makes comes from config:
# the model list's tags and endpoint tiers, and the policy rendered from
# modelGateway.policyGate. So the invariant "a restricted request has no route
# to an external tier" is a property of the config, provable with no model
# invoked, and templates/preflight.yaml refuses to render a config that breaks
# it. This proves that refusal happens, case by case, with the sentence that
# names the cause, and that the default render carries no gate at all.
#
# The forced-failure half, a real proxy with the local backend killed, is
# tests/policy-gate/run.sh (.github/workflows/policy-gate.yaml).
set -uo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-policy-gate: helm not on PATH; refusing rather than guessing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-policy-gate: python3 PyYAML missing"; exit 2; }

CHART=charts/tockmox-ai; BASE=(-f ci/values.yaml); FX=(-f ci/values-policy-gate.yaml)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }

# The default render ships no gate.
if out="$(helm template t "$CHART" "${BASE[@]}" 2>&1)"; then
  grep -E -q 'tockmox_gate|tockmox_policy' <<<"$out" \
    && bad "the default render carries gate files" || ok "the default render carries no gate files"
else bad "the default render failed: $(printf '%s' "$out" | head -2)"; fi

# The fixture renders, with the module, the policy and the registration.
if out="$(helm template t "$CHART" "${BASE[@]}" "${FX[@]}" 2>&1)"; then
  for want in 'tockmox_gate.py:' 'tockmox_policy.yaml:' 'hooks.tockmox_gate.tockmox_gate' 'enforcement: "enforce"' 'default_class: "restricted"'; do
    grep -qF -- "$want" <<<"$out" && ok "fixture renders $want" || bad "fixture render lacks $want"
  done
else bad "the fixture does not render: $(printf '%s' "$out" | grep -m1 -o 'execution error.*' | cut -c1-200)"; fi

# Each poison must REFUSE, naming the cause. One mutation per case, on top of
# the fixture, so a refusal cannot be blamed on anything else.
refuse() { # name, expected-substring, yaml-patch-python
  local name="$1" want="$2" patch="$3" out
  python3 - "$patch" > "$tmp/p.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open("ci/values-policy-gate.yaml"))
exec(sys.argv[1])
print(yaml.safe_dump(d))
PY
  if out="$(helm template t "$CHART" "${BASE[@]}" -f "$tmp/p.yaml" 2>&1)"; then
    bad "$name: rendered, expected a refusal"
  elif grep -qF -- "$want" <<<"$out"; then
    ok "$name: refused, naming it"
  else
    bad "$name: refused, but not for the expected reason: $(printf '%s' "$out" | grep -m1 -o 'execution error.*' | cut -c1-220)"
  fi
}
ml='d["litellm"]["proxy_config"]["model_list"]'
refuse "callback missing"              "does not list hooks.tockmox_gate.tockmox_gate"  'd["litellm"]["proxy_config"]["litellm_settings"]["callbacks"]=[]'
refuse "restricted may use external"   "classes.restricted must be exactly [local]"     'd["modelGateway"]["policyGate"]["classes"]={"open":["local","external"],"internal":["local"],"restricted":["local","external"]}'
refuse "tag filtering off"             "enable_tag_filtering is not true"               'd["litellm"]["proxy_config"]["router_settings"]["enable_tag_filtering"]=False'
refuse "a fallback edge in config"     "carries a fallback key"                         'd["litellm"]["proxy_config"]["router_settings"]["fallbacks"]=[{"local-chat":["frontier-x"]}]'
refuse "an entry with no tier"         "has no model_info.endpoint_tier"                "$ml"'[0]["model_info"]={}'
refuse "an untagged entry"             "has no litellm_params.tags"                     "$ml"'[0]["litellm_params"].pop("tags")'
refuse "restricted tag on external"    "is tagged \"restricted\" but is a external-tier" "$ml"'[1]["litellm_params"]["tags"]=["open","restricted"]'
refuse "an unknown class tag"          "is not a policy class"                          "$ml"'[0]["litellm_params"]["tags"]=["secret"]'
refuse "local entry with a cloud key"  "is local-tier but reads a provider key"         "$ml"'[0]["litellm_params"]["api_key"]="os.environ/ANTHROPIC_API_KEY"'
refuse "external entry with no key"    "is external-tier with no os.environ/ key"       "$ml"'[1]["litellm_params"]["api_key"]="none"'
refuse "an alias with no posture"      "has no entry in modelGateway.policyGate.routePosture" 'd["modelGateway"]["policyGate"]["routePosture"].pop("frontier-x")'
refuse "posture not among the tags"    "but the model is not tagged"                    'd["modelGateway"]["policyGate"]["routePosture"]["frontier-x"]="internal"'
refuse "posture for a missing alias"   "which is not a model_name"                      'd["modelGateway"]["policyGate"]["routePosture"]["ghost"]="restricted"'
refuse "a site file named like the gate" "and so does the policy gate"                  'd.setdefault("modelGateway",{}).setdefault("hooks",{})["files"]={"tockmox_gate.py":"x = 1\n"}'
refuse "gate on, gateway off"          "the model gateway is not enabled"               'd["apps"]["litellm"]["enabled"]=False'

echo
[ "$fail" = 0 ] && { echo "check-policy-gate: PASSED"; exit 0; }
echo "check-policy-gate: FAILED"; exit 1

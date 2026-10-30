#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# EVERY NETWORKPOLICY SELECTS SOMETHING (TM-1251, K4).
#
# A policy whose podSelector matches no pod applies cleanly, reports Synced and
# protects nothing. An egress allow that selects nothing strands the pod it was
# written for; a default-deny exemption that selects nothing fails open. Both
# read as protection on review. check-netpol-selectors.sh catches a selector
# that CANNOT match (an empty label value), and check-no-ghost-policies.sh a
# namespace with policies and no workload. This is the level below both: does
# a rendered pod carry the labels this policy selects.
#
# Renders every layer into the namespace the installer gives it (the
# ghost-policy gate's mapping), three passes: the shipped defaults, every
# shipped application on, and the optional surfaces whose policies select pods
# of their own (Knowledge sync, the agent-egress proxy). Pods a site or an
# operator makes at run time are in tools/policy-selects-exceptions.txt, each
# with its reason; an exception no pass needs fails the run, so the list
# cannot rot into a blanket.
#
# The agent-egress tools themselves are site workloads, so the third pass adds
# stand-in tool Deployments carrying the fixture's labels: what is checked is
# that the policies select what the fixture says the tools are, which is the
# mistake a typo in a label makes.
#
#   tools/check-policy-selects.sh           (helm, python3 with PyYAML)
#   tools/check-policy-selects.sh --selftest   plant a mismatch, expect red
set -euo pipefail
cd "$(dirname "$0")/.."

report=tools/lib/policy-selects-report.py
exceptions=tools/policy-selects-exceptions.txt

render_ns() {
  case "$1" in
    tockmox-ai)                              echo tockmox-ai ;;
    tockmox-observability|tockmox-exporters) echo tockmox-monitoring ;;
    tockmox-platform)                        echo tockmox-platform ;;
    tockmox-identity)                        echo tockmox-authentik ;;
    tockmox-devops)                          echo tockmox-devops ;;
    tockmox-selfcheck)                       echo tockmox-selfcheck ;;
    *)                                       echo argocd ;;
  esac
}

used=$(mktemp); trap 'rm -f "$used"' EXIT

# pass <label> <extra values for every layer> <extra for the ai layer> <extra for the policy layer> [stand-in manifest]
pass() {
  local label="$1" all_extra="$2" ai_extra="$3" policy_extra="$4" standin="${5:-}"
  local work; work=$(mktemp -d)
  for c in charts/tockmox-*; do
    local n; n=$(basename "$c")
    [ "$n" = "tockmox-common" ] && continue
    local extra=() own=()
    [ -n "$all_extra" ] && read -r -a extra <<< "$all_extra"
    [ "$n" = tockmox-ai ] && [ -n "$ai_extra" ] && read -r -a own <<< "$ai_extra"
    [ "$n" = tockmox-policy ] && [ -n "$policy_extra" ] && read -r -a own <<< "$policy_extra"
    helm template t "$c" -n "$(render_ns "$n")" -f ci/values.yaml "${extra[@]}" "${own[@]}" > "$work/$n.yaml"
    render_ns "$n" > "$work/$n.ns"
  done
  if [ -n "$standin" ]; then cp "$standin" "$work/zz-standin.yaml"; echo argocd > "$work/zz-standin.ns"; fi
  echo "== pass: $label"
  local rc=0
  python3 "$report" "$work" "$exceptions" "$used" || rc=$?
  rm -rf "$work"
  return $rc
}

standin_tools() {   # stand-in Deployments carrying each agent-egress tool's labels, from the fixture itself
  python3 - "$1" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["agentEgress"]
for name, t in (v.get("tools") or {}).items():
    print(yaml.safe_dump({"apiVersion": "apps/v1", "kind": "Deployment",
                          "metadata": {"name": f"standin-{name}", "namespace": v["namespace"]},
                          "spec": {"template": {"metadata": {"labels": t["podSelector"]}}}}) + "---")
PY
}

run() {
  local fixture="$1" rc=0 st; st=$(mktemp)
  standin_tools "$fixture" > "$st"
  : > "$used"
  pass "shipped defaults" "" "" "" || rc=1
  pass "every shipped application enabled" "-f ci/values-all-on.yaml" "" "" || rc=1
  pass "optional surfaces (Knowledge sync, agent egress)" "" \
       "-f ci/values-inference-nodes.yaml -f ci/values-knowledge.yaml" "-f $fixture" "$st" || rc=1
  echo "== exceptions"
  python3 "$report" --stale "$exceptions" "$used" || rc=1
  rm -f "$st"
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  # A label typo in the fixture's tool selector: the policy renders, selects nothing, and must turn this red.
  bad=$(mktemp); sed 's/app.kubernetes.io\/name: example-web-mcp}/app.kubernetes.io\/name: example-web-mpc}/' \
    ci/values-agent-egress.yaml > "$bad"
  grep -q example-web-mpc "$bad" || { echo "selftest: could not plant the mismatch"; exit 1; }
  # the stand-ins are built from the CORRECT fixture: the site's tool still carries the right label
  st=$(mktemp); standin_tools ci/values-agent-egress.yaml > "$st"
  work_rc=0
  : > "$used"
  pass "planted: a tool selector with a typo" "" "" "-f $bad" "$st" > "$st.out" 2>&1 || work_rc=$?
  rm -f "$bad"
  if [ "$work_rc" -ne 0 ] && grep -q "SELECTS NOTHING  tockmox-agents/allow-egress-tool-web-fetch" "$st.out"; then
    echo "selftest: ok, the planted mismatch is caught"; rm -f "$st" "$st.out"; exit 0
  fi
  echo "selftest: FAILED, the planted mismatch was not caught"; cat "$st.out"; rm -f "$st" "$st.out"; exit 1
fi

if run ci/values-agent-egress.yaml; then
  echo "check-policy-selects: PASSED"
  exit 0
fi
cat <<'MSG'
check-policy-selects: FAILED
A NetworkPolicy above selects no pod any layer renders. Fix the selector, or,
if the pods are made at run time by an operator or by the site, add the policy
to tools/policy-selects-exceptions.txt with the reason.
MSG
exit 1

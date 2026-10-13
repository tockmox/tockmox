#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail if any shipped NetworkPolicy guards a namespace no shipped workload
# lands in.
#
#   ./tools/check-no-ghost-policies.sh
#
# WHY THIS EXISTS: four NetworkPolicy bundles shipped enabled for months
# guarding nothing ... a Forgejo, a Tailscale subnet router and a syslog
# receiver that were never ported, plus a Harbor bundle aimed at
# `namespaces.harbor` when Harbor is a subchart of tockmox-devops and lands in
# `namespaces.devops`. Nothing failed. `helm lint` passed, kubeconform passed,
# the cluster synced green, and `kubectl get netpol` showed a tidy default-deny
# posture over empty namespaces. A policy whose podSelector matches no pod is
# scaffolding, and it reads as protection to whoever audits the cluster next.
#
# The check renders every layer INTO THE DESTINATION NAMESPACE the installer
# assigns it, then asserts that each namespace holding a NetworkPolicy also
# holds at least one namespaced workload resource. A resource with no explicit
# metadata.namespace lands in its release's namespace, so attribution follows
# that rule rather than reading metadata.namespace alone ... several upstream
# subcharts emit none at all, which is exactly how the Harbor case hid.
#
# Two passes, because a gate that only sees the default render cannot catch a
# policy staged for a component you have to switch on:
#   1. shipped defaults
#   2. every shipped application enabled
# The site-supplied bundles (forgejo, tailscale, syslog_ingest, harbor ...
# harbor is now one of them, since 0.1.0 ships no registry) stay
# OFF in both passes, deliberately. They are opt-in, documented as guarding
# workloads Tockmox does not ship, and turning one on without its workload is
# the operator's call to make. There is no allowlist here on purpose: if you
# need one, you are about to ship a fifth ghost.
#
# This is a render-time check. It proves the shipped defaults are coherent. It
# does not prove any policy is CORRECT, and it says nothing about a site's own
# values. Both of those are the operator's.
set -euo pipefail
cd "$(dirname "$0")/.."

# Must match dest_ns() in install/tockmox-install.sh. Layers absent from this
# map are cluster-scoped or name their namespaces explicitly (crds, policy).
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

pass() {
  local label="$1"; shift
  local work; work=$(mktemp -d)
  for c in charts/tockmox-*; do
    local n; n=$(basename "$c")
    [ "$n" = "tockmox-common" ] && continue
    helm template t "$c" -n "$(render_ns "$n")" -f ci/values.yaml "$@" > "$work/$n.yaml"
    printf '%s\n' "$(render_ns "$n")" > "$work/$n.ns"
  done
  echo "== pass: $label"
  local rc=0
  python3 tools/lib/ghost-policy-report.py "$work" || rc=$?
  rm -rf "$work"
  echo
  return $rc
}

rc=0
pass "shipped defaults"                                    || rc=1
# The second pass was byte-identical to the first until 2026-08-19, because
# nothing flipped anything ... a gate pass that claims coverage it does not
# render. The overlay is what makes the label true.
pass "every shipped application enabled" -f ci/values-all-on.yaml || rc=1

if [ "$rc" -ne 0 ]; then
  echo "Either ship the workload, or default its policy bundle off and say so"
  echo "in the values comments and in the docs. Both are honest; a policy that"
  echo "silently guards an empty namespace is not."
  exit 1
fi
echo "no ghost policies in either pass"

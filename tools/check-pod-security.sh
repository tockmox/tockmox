#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that no namespace's Pod Security `enforce`
# label is stricter than the profile every pod rendered into it passes.
#
#   ./tools/check-pod-security.sh            the gate
#   ./tools/check-pod-security.sh --table    the same render, table only, never fails on labels
#
# WHY THIS SHAPE. The failure to prevent is an install that cannot schedule: a
# namespace labelled `enforce: restricted` while one pod in it does not meet
# `restricted` is refused at admission, and the symptom is a Deployment stuck at
# zero replicas with the reason buried in a ReplicaSet event. Nothing at render
# time, `helm lint` or kubeconform notices. So the gate renders every layer,
# evaluates every pod template (Deployments, StatefulSets, DaemonSets, Jobs,
# CronJobs, hook Jobs, subchart pods) against the actual Pod Security Standards
# rules (tools/lib/psa_eval.py, each rule cites its section of the upstream
# page), groups the results by the namespace each pod lands in, and compares
# that with the labels the policy layer renders.
#
# Two passes, like the sibling gates: CI defaults, then the all-on overlay, so a
# pod that only renders on a non-default path is measured too. A namespace's
# measured profile is the LOWEST any pod in either pass reaches.
#
# WHAT IT DOES NOT PROVE. Admission on a live cluster: no API server sees these
# labels here. Pods an operator creates from a custom resource (CNPG, Longhorn
# instance managers) are listed, not evaluated. A site's own workloads, and a
# site values overlay that turns on something CI does not, are the operator's to
# measure with `--table` against their own values. Exit 2 (skipped) when helm or
# PyYAML is absent, never a green report over an empty render.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-pod-security: helm missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-pod-security: python3 PyYAML missing" >&2; exit 2; }

echo "-- rules (selftest)"
python3 tools/lib/psa_eval.py --selftest | grep -v '^  ok' || true
python3 tools/lib/psa_eval.py --selftest >/dev/null || { echo "::error::Pod Security rule selftest failed"; exit 1; }

# Must match dest_ns() in install/tockmox-install.sh (same map as
# check-no-ghost-policies.sh).
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
render_pass() {
  local pass="$1"; shift
  for c in charts/tockmox-*; do
    local n; n=$(basename "$c")
    [ "$n" = "tockmox-common" ] && continue
    local out="$work/${pass}__${n#tockmox-}"
    [ "$n" = "tockmox-policy" ] && out="$work/${pass}__namespaces"
    helm template t "$c" -n "$(render_ns "$n")" -f ci/values.yaml "$@" > "$out.yaml"
    printf '%s\n' "$(render_ns "$n")" > "$out.ns"
  done
}
render_pass defaults
render_pass allon -f ci/values-all-on.yaml

echo "-- namespaces: measured profile vs rendered labels"
rc=0
python3 tools/lib/psa_eval.py "$work" || rc=$?
if [ "$rc" -ne 0 ] && [ "${1:-}" != "--table" ]; then
  echo
  echo "An enforce label stricter than the pods it guards makes them unschedulable."
  echo "Lower the label (podSecurity.enforce.<namespace> in tockmox-policy values) or fix the pod."
  exit 1
fi
[ "${1:-}" = "--table" ] && exit 0
echo "every enforce label is within what its pods pass"

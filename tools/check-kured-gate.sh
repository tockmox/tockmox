#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Every alert Tockmox authors has a decision about the kured reboot gate.
#
#   ./tools/check-kured-gate.sh                run the check on the rendered layers
#   ./tools/check-kured-gate.sh --print-regexp print the alertFilterRegexp the decisions imply
#   ./tools/check-kured-gate.sh --selftest     prove it goes red, and stays green where it should
#
# WHY. kured holds a reboot only for the alerts a site names. Name too many and
# patching stops on noise (it did, repeatedly, on the first site to
# run it). Name only the ones that matter and the failure moves: an alert added
# later that DOES matter is simply not on the list, nothing errors, and the first
# symptom is a reboot that should not have happened. The decision for each alert
# is in tools/kured-gate.txt; this gate fails when an alert has none.
#
# WHAT IS CHECKED, on `helm template` of every layer that carries a
# PrometheusRule, with ci/values.yaml and ci/values-all-on.yaml (and the identity
# layer once more with the bundled server kept, TM-0788):
#   - every Tockmox-authored alert has a line in tools/kured-gate.txt or a
#     `kured_gate: block|pass` annotation, and not both
#   - every line names an alert that still renders
#   - every upstream alert the gate names is still shipped by a subchart
#   - the alertFilterRegexp printed in docs/operations/monitoring.md is the one
#     the decisions imply, matches every block and no pass, and sits beside
#     alertFilterMatchOnly: true
#
# NOT CHECKED: that a SITE's own regexp contains these names (a site repository
# is not this tree), and that a classified alert can fire (tools/check-alert-rules.sh).
#
# EXIT 2 is skipped, not passed, as everywhere in this directory.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tools/lib/tool-runs.sh
. tools/lib/tool-runs.sh

LEDGER=tools/kured-gate.txt
DOC=docs/operations/monitoring.md
LIB=tools/lib/kured_gate.py

for t in python3 helm; do
  if [ "$(tool_state "$t")" != ok ]; then echo "check-kured-gate: SKIPPED ... $(tool_why "$t")" >&2; exit 2; fi
done
# Probe the way the gate runs (-I, isolated): a PyYAML found only through the user site or PYTHONPATH passes a
# plain probe and then fails the -I run with a traceback instead of a skip.
python3 -I -c 'import yaml' 2>/dev/null || { echo "check-kured-gate: SKIPPED ... python3 -I (isolated, as this gate runs it) has no PyYAML" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# THE LAYER LIST IS DERIVED, as in check-alert-rules.sh: a hard-coded list is
# escaped by the next chart that ships a rule.
LAYERS="$(grep -rl 'kind: PrometheusRule' charts/*/templates/ 2>/dev/null | cut -d/ -f2 | sort -u)"
[ -n "$LAYERS" ] || { echo "check-kured-gate: REFUSING ... no chart carries a PrometheusRule; the scan is wrong" >&2; exit 1; }

RENDERED=()
for chart in $LAYERS; do
  helm template "$chart" "charts/$chart" -f ci/values.yaml -f ci/values-all-on.yaml > "$T/$chart.yaml" 2> "$T/$chart.err" \
    || { echo "check-kured-gate: REFUSING ... charts/$chart did not render: $(head -c 300 "$T/$chart.err")" >&2; exit 1; }
  RENDERED+=("$T/$chart.yaml")
  # Alerts that render only under a PROFILE (TM-0597: the resilient profile's
  # drill alarm) are invisible to the render above, so they would reach a
  # cluster with no kured decision, and a ledger line for them would be
  # reported as naming an alert that no longer renders. The profile is passed
  # with the values a site supplies after it (ci/values-profile-<name>-<chart>.yaml).
  for ov in ci/values-profile-*-"$chart".yaml; do
    [ -f "$ov" ] || continue
    pn="${ov#ci/values-profile-}"; pn="${pn%-"$chart".yaml}"
    helm template "$chart" "charts/$chart" -f ci/values.yaml -f ci/values-all-on.yaml -f "profiles/$pn.yaml" -f "$ov" > "$T/$chart-profile-$pn.yaml" 2> "$T/$chart-profile-$pn.err" \
      || { echo "check-kured-gate: REFUSING ... charts/$chart did not render under profiles/$pn.yaml: $(head -c 300 "$T/$chart-profile-$pn.err")" >&2; exit 1; }
    RENDERED+=("$T/$chart-profile-$pn.yaml")
  done
done
# THE BUNDLED-SERVER SHAPE OF THE IDENTITY LAYER (TM-0788). From 0.9.0 Authentik
# runs on CNPG by default, and an install that keeps the bundled server (two
# keys, docs/deployment/upgrade.md) renders the pg_dump bridge and its two
# freshness alerts, which neither overlay above renders any more. Those alerts
# still fire on real clusters, so they still need a decision here.
if [ -f "$T/tockmox-identity.yaml" ]; then
  helm template tockmox-identity charts/tockmox-identity -f ci/values.yaml -f ci/values-all-on.yaml \
    --set identity.database.enabled=false --set authentik.postgresql.enabled=true > "$T/tockmox-identity-bundled.yaml" 2> "$T/tockmox-identity-bundled.err" \
    || { echo "check-kured-gate: REFUSING ... charts/tockmox-identity with the bundled server did not render: $(head -c 300 "$T/tockmox-identity-bundled.err")" >&2; exit 1; }
  RENDERED+=("$T/tockmox-identity-bundled.yaml")
fi

case "${1:-}" in
  --print-regexp) exec python3 -I "$LIB" regexp "$LEDGER" "${RENDERED[@]}" ;;
  --selftest)     exec python3 -I "$LIB" selftest "$LEDGER" "$DOC" "${RENDERED[@]}" ;;
  "") ;;
  *) echo "usage: $0 [--print-regexp | --selftest]" >&2; exit 2 ;;
esac

python3 -I "$LIB" check "$LEDGER" "$DOC" "${RENDERED[@]}"

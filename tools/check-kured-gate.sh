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
# PrometheusRule, with ci/values.yaml and ci/values-all-on.yaml:
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
cd "$(dirname "$0")/.."
# shellcheck source=tools/lib/tool-runs.sh
. tools/lib/tool-runs.sh

LEDGER=tools/kured-gate.txt
DOC=docs/operations/monitoring.md
LIB=tools/lib/kured_gate.py

for t in python3 helm; do
  if [ "$(tool_state "$t")" != ok ]; then echo "check-kured-gate: SKIPPED ... $(tool_why "$t")" >&2; exit 2; fi
done
python3 -c 'import yaml' 2>/dev/null || { echo "check-kured-gate: SKIPPED ... python3 has no PyYAML" >&2; exit 2; }

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
done

case "${1:-}" in
  --print-regexp) exec python3 -I "$LIB" regexp "$LEDGER" "${RENDERED[@]}" ;;
  --selftest)     exec python3 -I "$LIB" selftest "$LEDGER" "$DOC" "${RENDERED[@]}" ;;
  "") ;;
  *) echo "usage: $0 [--print-regexp | --selftest]" >&2; exit 2 ;;
esac

python3 -I "$LIB" check "$LEDGER" "$DOC" "${RENDERED[@]}"

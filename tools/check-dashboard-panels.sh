#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Refuse a shipped table panel whose organize transformation hides columns
# without saying which columns come first.
#
#   ./tools/check-dashboard-panels.sh              every dashboard the chart ships
#   ./tools/check-dashboard-panels.sh --selftest   prove the rule actually trips
#   ./tools/check-dashboard-panels.sh FILE...      specific dashboard JSON files
#
# WHY THIS EXISTS (TM-0559, and it is the THIRD instance of one failure).
#
# Three shipped dashboards have now been correct in JSON, correct in the data
# they query, and misleading on screen: a red count that never happened and a
# table of metric plumbing (TM-0532), then the ArgoCD board's Application
# status table rendering `dest_namespace / cluster / exported_namespace` in its
# visible width while `name`, `sync_status` and `health_status` sat off the
# right edge (TM-0559). Every one was caught by a human looking at the board.
# None was caught by a gate, and a CLI pre-check the same day reported the
# ArgoCD panel as "12 series, ok" ... which was true and was the wrong question.
# A check that reads the data can never catch a presentation defect.
#
# THE MECHANISM IS ONE FIELD. Grafana's `organize` transformation takes
# `excludeByName` (drop these columns), `renameByName` (relabel these) and
# `indexByName` (put these FIRST, in this order). When `excludeByName` is set
# and `indexByName` is not, column order falls out of the label order the query
# happened to return, alphabetically as it turns out, so the columns that
# answer the panel's question land wherever the alphabet puts them. On the
# ArgoCD board that was last.
#
# SO THE RULE IS STATIC AND CHEAP: a table panel that hides columns MUST also
# say which columns lead. `excludeByName` without `indexByName` is refused.
# It would have caught all three instances, and the day it was written it
# found two more (cert-manager "Days to expiry", MetalLB "Pool utilization")
# that nobody had looked at closely enough to notice.
#
# SCOPE. Table panels only. A time series panel has no column order to get
# wrong; a stat panel shows one value. Both dashboards directories are
# examined, because `dashboards-optional/` ships too, just behind a switch.
# Every file is also required to parse as JSON, since a dashboard that does
# not parse is a ConfigMap the sidecar imports and Grafana rejects, silently.
#
# WHAT THIS DOES NOT CLAIM. That the order `indexByName` names is the right
# one. It asserts that somebody chose an order, which is the property whose
# absence produced all three defects. The right order is still a human
# looking at the rendered board, and the release gate's N10 row is where that
# happens.
#
#   exit 0  every table panel that hides columns also orders them
#   exit 1  at least one does not, a file did not parse, or nothing was examined
#   exit 2  could not run: no python3
#
# PORTABILITY: bash 3.2 (macOS). No mapfile, no associative arrays. The work
# is in python3 (stdlib json only) so the recursion into row panels is not
# written in awk.

set -euo pipefail
cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "check-dashboard-panels: SKIPPED ... no python3 on PATH"; exit 2; }

# The checker. Prints one line per violation to stdout, a summary line last,
# and exits 1 on any violation or on zero panels examined.
check_files() {
  "$PY" - "$@" <<'PY'
import json, sys

files = sys.argv[1:]
violations = 0
tables = 0
parsed = 0

def walk(panels):
    for p in panels or []:
        yield p
        # Row panels nest their children; collapsed rows keep them here too.
        for c in walk(p.get("panels")):
            yield c

for f in files:
    try:
        with open(f) as fh:
            d = json.load(fh)
    except Exception as e:  # noqa: BLE001 - the message is the finding
        print(f"{f}: DOES NOT PARSE AS JSON: {e}")
        violations += 1
        continue
    parsed += 1
    for p in walk(d.get("panels")):
        if p.get("type") != "table":
            continue
        tables += 1
        title = p.get("title", "<untitled>")
        for t in p.get("transformations") or []:
            if t.get("id") != "organize":
                continue
            o = t.get("options") or {}
            hides = {k for k, v in (o.get("excludeByName") or {}).items() if v}
            orders = o.get("indexByName") or {}
            if hides and not orders:
                print(f"{f}: table panel {title!r} sets excludeByName ({len(hides)} columns hidden) "
                      f"with no indexByName ... the columns that answer the question will land "
                      f"wherever the label order puts them")
                violations += 1

print(f"examined {parsed} dashboard(s), {tables} table panel(s), {violations} violation(s)")
if parsed == 0:
    print("examined no dashboards -- refusing to report success")
    sys.exit(1)
sys.exit(1 if violations else 0)
PY
}

selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # The ArgoCD board as it shipped in rc3: hides thirteen labels, orders none.
  cat > "$tmp/bad.json" <<'EOF'
{"panels":[{"type":"table","title":"Application status","transformations":[
  {"id":"organize","options":{"excludeByName":{"Time":true,"pod":true},"renameByName":{"dest_server":"cluster"}}}]}]}
EOF
  # The same panel with the fix.
  cat > "$tmp/good.json" <<'EOF'
{"panels":[{"type":"table","title":"Application status","transformations":[
  {"id":"organize","options":{"excludeByName":{"Time":true,"pod":true},"indexByName":{"name":0,"sync_status":1},"renameByName":{"dest_server":"cluster"}}}]}]}
EOF
  # excludeByName present but every entry false: nothing is hidden, so no
  # order is owed. Grafana writes this shape when a column is toggled twice.
  cat > "$tmp/all-false.json" <<'EOF'
{"panels":[{"type":"table","title":"t","transformations":[
  {"id":"organize","options":{"excludeByName":{"Time":false},"renameByName":{}}}]}]}
EOF
  # A time series panel with the bad shape is out of scope.
  cat > "$tmp/timeseries.json" <<'EOF'
{"panels":[{"type":"timeseries","title":"t","transformations":[
  {"id":"organize","options":{"excludeByName":{"Time":true}}}]}]}
EOF
  # The bad panel INSIDE a row: the walk must recurse or this passes.
  cat > "$tmp/nested.json" <<'EOF'
{"panels":[{"type":"row","title":"r","panels":[{"type":"table","title":"inner","transformations":[
  {"id":"organize","options":{"excludeByName":{"Time":true}}}]}]}]}
EOF
  printf '{"panels": [' > "$tmp/broken.json"

  local f expect got
  for f in bad:1 good:0 all-false:0 timeseries:0 nested:1 broken:1; do
    name="${f%%:*}"; expect="${f##*:}"
    got=0
    check_files "$tmp/$name.json" >/dev/null || got=1
    if [ "$got" = "$expect" ]; then
      printf '  ok   selftest %s: exit %s, expected %s\n' "$name" "$got" "$expect"
    else
      printf '  FAIL selftest %s: exit %s, expected %s\n' "$name" "$got" "$expect" >&2
      check_files "$tmp/$name.json" >&2 || true
      status=1
    fi
  done
  return $status
}

main() {
  if [ $# -gt 0 ] && [ "$1" = "--selftest" ]; then
    echo "== selftest"
    selftest || exit 1
    echo "  the rule trips as designed"
    exit 0
  fi
  if [ $# -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
  fi

  echo "== dashboard panels"
  if [ $# -gt 0 ]; then
    check_files "$@"
  else
    # Both directories, enumerated by glob rather than by a list of names, so
    # the next dashboard somebody adds is examined without editing this file.
    check_files charts/tockmox-observability/dashboards/*.json \
                charts/tockmox-observability/dashboards-optional/*.json
  fi
}

main "$@"

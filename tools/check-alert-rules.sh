#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run `promtool test rules` against the alert rules THIS TREE RENDERS.
#
#   ./tools/check-alert-rules.sh
#
# WHY THIS EXISTS. Tockmox ships alert rules as its safety net, and until
# 2026-09-12 not one of them had a test. The alert-series-churn family is nine
# separate mechanisms by which an alert reads green and cannot fire, and every
# one of them was found by a human noticing, never by a gate. An alert nobody
# has watched fire is a claim, not a control.
#
# TM-0519 is the case that forced it. `StaticSATokenRotationOverdue` assumed a
# static ServiceAccount-token Secret in a `tockmox-*` namespace could only be one
# WE minted for an off-cluster consumer. kube-prometheus-stack 90.1.1 broke that
# by shipping its own, so the rule would have fired on a chart-managed Secret
# 90 days after every install, with a description telling the operator to delete
# it and update a consumer that does not exist. The scope was narrowed; this
# gate is what keeps the narrowing honest in BOTH directions.
#
# TEST THE RENDERED EXPRESSION, NEVER A COPY OF IT. The test cases here point at
# rules extracted from `helm template`, not at hand-written PromQL. A test
# against a copy proves the copy works. The 2026-09-12 measurement that settled
# TM-0519 was re-run against the rendered rule for exactly this reason, and the
# escaping differs between the template source and the rendered output.
#
# EVERY CASE MUST ASSERT BOTH DIRECTIONS. A firing test alone admits a rule that
# fires on everything; a silent test alone admits a rule that fires on nothing.
# Each case here pairs "fires on the thing it is for" with "does not fire on the
# thing it must ignore", which is the same pass-on-the-edit-and-fail-on-HEAD
# discipline the handoff sentinels use.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v python3  >/dev/null 2>&1 || { echo "check-alert-rules: REFUSING ... python3 is not on PATH" >&2; exit 2; }

# EXIT 2 IS SKIPPED, not passed ... the repository's convention. promtool is not
# a build dependency of the chart, so a workstation without it skips rather than
# fails; CI pins it and therefore always runs it.
#
# PARTITION, NOT REFUSE (TM-0713, 2026-09-17). Until then a missing helm or
# promtool stopped the whole gate, so a tests/rules/ case could be authored and
# never once parsed until CI saw it, and a chart that no longer renders its
# rules went unnoticed on any machine without promtool. Now every step that
# needs a missing binary is SKIPPED BY NAME and never run (nothing is guessed:
# no render is faked, no rule is linted without promtool), every step that
# does not need it runs, and both counts print. Exit 1 on a finding, else 2
# while anything was skipped. A partial run is never a pass.
HAVE_HELM=1; HAVE_PROMTOOL=1; miss=""
command -v helm     >/dev/null 2>&1 || { HAVE_HELM=0;     miss="$miss helm"; }
command -v promtool >/dev/null 2>&1 || { HAVE_PROMTOOL=0; miss="$miss promtool"; }
nrun=0; nskip=0
skip() { printf '  SKIPPED  %s\n' "$*"; nskip=$((nskip + 1)); }
if [ -n "$miss" ]; then
  echo "check-alert-rules: PARTIAL RUN ... not on PATH:$miss (CI pins HELM_VERSION and PROMTOOL_VERSION)"
  echo "  every step that needs it is SKIPPED by name below; the rest run. This run cannot pass."
  echo
fi

CASES_DIR="tests/rules"
[ -d "$CASES_DIR" ] || { echo "check-alert-rules: REFUSING ... $CASES_DIR does not exist" >&2; exit 2; }

# partial_report -- the tail of a run with helm or promtool missing. Names
# every remaining step as skipped, runs the one check on the case files that
# needs neither binary, prints both counts and exits 1 or 2. Never 0.
partial_report() {
  local c rc=0
  shopt -s nullglob
  local cases=("$CASES_DIR"/*.yaml)
  [ "${#cases[@]}" -gt 0 ] || { echo "check-alert-rules: REFUSING ... no cases in $CASES_DIR" >&2; exit 2; }
  echo
  echo "=== skipped: these need${miss} ==="
  if [ "$HAVE_HELM" -eq 0 ]; then
    skip "render each layer carrying a PrometheusRule: $(echo $LAYERS | tr '\n' ' ')(needs helm)"
    skip "extract the rendered rules and find ours (needs helm)"
  fi
  skip "promtool check rules: OURS, full lint (needs${miss})"
  skip "promtool check rules: everything, syntax only (needs${miss})"
  for c in "${cases[@]}"; do skip "promtool test rules: $(basename "$c") (needs${miss})"; done

  echo
  echo "=== case files parse and leave rule_files to the gate (python3 only) ==="
  # The same assertion the promtool loop makes before injecting the rendered
  # rules, run here because that loop is skipped: a case that does not parse
  # is caught on this machine rather than first in CI.
  for c in "${cases[@]}"; do
    printf '  %-46s ' "$(basename "$c")"
    if out="$(python3 - "$c" 2>&1 <<'PY'
import sys, yaml
case = sys.argv[1]
try:
    doc = yaml.safe_load(open(case))
except yaml.YAMLError as e:
    sys.exit(f"{case}: does not parse: {e}")
if not isinstance(doc, dict):
    sys.exit(f"{case}: not a YAML mapping")
if doc.get("rule_files"):
    sys.exit(f"{case}: must NOT set rule_files ... the gate injects the rendered rules")
PY
)"; then
      echo "parses"; nrun=$((nrun + 1))
    else
      echo "FAIL"; printf '%s\n' "$out" | sed 's/^/      /'; rc=1; nrun=$((nrun + 1))
    fi
  done

  echo
  echo "check-alert-rules: $nrun check(s) run, $nskip skipped (named above; missing:$miss)"
  if [ "$rc" -ne 0 ]; then
    echo "check-alert-rules: FAILED" >&2
    exit 1
  fi
  echo "check-alert-rules: INCOMPLETE ... nothing run failed; exit 2, not a pass"
  exit 2
}

WORK="$(mktemp -d)"
trap 'rm -f "$WORK"/*.yaml 2>/dev/null; rmdir "$WORK" 2>/dev/null || true' EXIT

echo "=== extracting rendered alert rules ==="

# Render every layer that can carry a PrometheusRule, under the all-on values,
# so a rule that only renders on a non-default path is still extracted.
#
# THE LIST IS DERIVED, NOT TYPED. Until 2026-09-13 this loop read
#
#   for layer in policy observability exporters platform
#
# while SEVEN charts ship a PrometheusRule. The comment directly above it said
# "every layer that can carry a PrometheusRule", and it had been wrong for as
# long as identity, ai and selfcheck have had rules ... including
# tockmox-selfcheck, whose whole job is the watchdog that notices when the rest
# of the platform has gone quiet. Those alerts were never rendered, never
# linted, never unit-tested. A hard-coded list is escaped by the next chart
# somebody adds, which is the argument this repository already makes for
# self-declaring scopes in check-pasteable-blocks.sh RULE 2.
#
# AND THE ALL-ON OVERLAY IS NOW ACTUALLY APPLIED. The comment claimed it;
# `grep -n values-all-on` found the phrase only in prose. Any rule behind a
# non-default flag ... the ai layer's restore-drill alerts are the live example,
# gated on modelGateway.database.backup.enabled ... was excluded by the very
# argument the comment used to include it.
LAYERS="$(grep -rl 'kind: PrometheusRule' charts/*/templates/ 2>/dev/null \
          | cut -d/ -f2 | sed 's/^tockmox-//' | sort -u)"
[ -n "$LAYERS" ] || { echo "check-alert-rules: REFUSING ... no chart carries a PrometheusRule; the scan is wrong" >&2; exit 1; }
echo "  layers carrying a PrometheusRule: $(echo $LAYERS | tr '\n' ' ')"
nrun=$((nrun + 1))
[ "$HAVE_HELM" -eq 1 ] || partial_report
for layer in $LAYERS; do
  helm template "tockmox-$layer" "charts/tockmox-$layer" \
    -f ci/values.yaml -f ci/values-all-on.yaml \
    > "$WORK/render-$layer.yaml" 2>/dev/null \
    || { echo "check-alert-rules: REFUSING ... charts/tockmox-$layer did not render" >&2; exit 1; }
done

python3 - "$WORK" <<'PY'
import sys, glob, os, yaml
work = sys.argv[1]

# SPLIT OURS FROM THE SUBCHARTS'. `tockmox.com/managed-by: tockmox` is stamped
# by our own templates and by nothing upstream ships, so it is the discriminator.
#
# WHY THE SPLIT EXISTS (2026-09-12). Linting everything failed on
# `code_verb:apiserver_request_total:increase1h`, which kube-prometheus-stack
# emits four times in kube-apiserver-availability.rules. That is upstream's
# design and not ours to fix, so a gate that fails on it is a gate that can
# never be green ... which is how a suite learns to be ignored. We lint what we
# author and syntax-check what we ship, and those are honestly different bars.
ours, theirs, n_ours, n_theirs = [], [], 0, 0
for f in sorted(glob.glob(os.path.join(work, "render-*.yaml"))):
    for d in yaml.safe_load_all(open(f)):
        if not (isinstance(d, dict) and d.get("kind") == "PrometheusRule"):
            continue
        mine = (d["metadata"].get("labels") or {}).get("tockmox.com/managed-by") == "tockmox"
        for g in d["spec"]["groups"]:
            g = dict(g)
            # Namespace the group so two layers cannot collide on a name.
            g["name"] = f"{d['metadata']['name']}::{g['name']}"
            if mine:
                ours.append(g);   n_ours   += len(g.get("rules", []))
            else:
                theirs.append(g); n_theirs += len(g.get("rules", []))

for name, groups in (("rendered-rules.yaml", ours + theirs), ("ours.yaml", ours)):
    with open(os.path.join(work, name), "w") as fh:
        yaml.safe_dump({"groups": groups}, fh, default_flow_style=False, width=10000)

print(f"  ours       {len(ours):3d} group(s), {n_ours:4d} rule(s)   (tockmox.com/managed-by: tockmox)")
print(f"  subcharts  {len(theirs):3d} group(s), {n_theirs:4d} rule(s)")
if not ours:
    sys.exit("check-alert-rules: REFUSING ... no Tockmox-authored PrometheusRule rendered at all")
PY
nrun=$((nrun + 2))   # every layer rendered; the rules extracted and ours found
[ "$HAVE_PROMTOOL" -eq 1 ] || partial_report

echo
echo "=== promtool check rules: OURS, full lint ==="
promtool check rules "$WORK/ours.yaml" || {
  echo "check-alert-rules: a Tockmox-authored rule failed lint" >&2; exit 1; }

echo
echo "=== promtool check rules: everything, syntax only ==="
# --lint none still parses and type-checks every expression, which is the part
# that catches a broken render. It skips the style findings that belong to
# upstream.
promtool check rules --lint none "$WORK/rendered-rules.yaml" >/dev/null || {
  echo "check-alert-rules: the RENDERED rules do not parse" >&2; exit 1; }
echo "  all rendered rules parse"

echo
echo "=== promtool test rules ==="
rc=0
shopt -s nullglob
cases=("$CASES_DIR"/*.yaml)
[ "${#cases[@]}" -gt 0 ] || { echo "check-alert-rules: REFUSING ... no cases in $CASES_DIR" >&2; exit 2; }

for case_file in "${cases[@]}"; do
  # Each case declares its own rule_files: none. The rendered file is injected
  # here so a case can never accidentally test a hand-written copy.
  python3 - "$case_file" "$WORK" <<'PY'
import sys, yaml, os
case, work = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(case))
if doc.get("rule_files"):
    sys.exit(f"{case}: must NOT set rule_files ... the gate injects the rendered rules")
doc["rule_files"] = [os.path.join(work, "rendered-rules.yaml")]
yaml.safe_dump(doc, open(os.path.join(work, "case.yaml"), "w"), default_flow_style=False)
PY
  printf '  %-46s ' "$(basename "$case_file")"
  if out="$(promtool test rules "$WORK/case.yaml" 2>&1)"; then
    echo "PASS"
  else
    echo "FAIL"; printf '%s\n' "$out" | sed 's/^/      /'; rc=1
  fi
done

echo
if [ "$rc" -eq 0 ]; then
  echo "check-alert-rules: clean (${#cases[@]} case file(s))"
else
  echo "check-alert-rules: FAILED" >&2
fi
exit "$rc"

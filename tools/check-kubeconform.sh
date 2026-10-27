#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# KUBECONFORM OVER THE RENDERED CHARTS, ONE DEFINITION FOR CI AND A LAPTOP (TM-0584).
#
# Until this script, ci.yaml's "kubeconform rendered output" step was the only
# place kubeconform ran, and tools/check-all.sh carried a SKIP line for it in
# both branches, because the line it replaced on 2026-09-13 printed a green
# "kubeconform" from a hardcoded `exit 0` and could not fail under any tree
# state. Now both call this file, so the step and the laptop run the same
# pipeline: every layer chart rendered with ci/values.yaml, piped to
# `kubeconform -strict -summary -ignore-missing-schemas`.
#
# A VACUOUS GREEN IS REFUSED. `-ignore-missing-schemas` is needed for the CRDs
# the charts render (no upstream schema for them), and it also turns a schema
# fetch that failed (no network, a proxy) into "skipped", which exits 0. So each
# run must report at least one resource Valid across the charts (one chart alone
# may validate nothing: tockmox-crds renders only CRDs, which kubeconform skips). The selftest
# also needs the schemas: if it cannot see an invalid Deployment rejected, it
# fails rather than letting the main run be believed.
#
#   tools/check-kubeconform.sh              every layer chart (run tools/helm-deps.sh first)
#   tools/check-kubeconform.sh --selftest   a valid and an invalid fixture through the same pipeline
#
# Exit 0 pass, 1 a finding, 2 skipped (helm or kubeconform absent or unable to
# run). Bash 3.2 compatible.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tools/lib/tool-runs.sh
. tools/lib/tool-runs.sh

KC_FLAGS="-strict -summary -ignore-missing-schemas"
# KUBECONFORM_SCHEMA_DIR (HL-0675): validate against a local copy of the
# schemas instead of fetching them, for a run with no network (an airgap, the
# QA lane's test pod). The directory mirrors kubernetes-json-schema's layout,
# <dir>/master-standalone-strict/<kind>[-<group>]-<version>.json; a schema it
# does not hold (a CRD) is skipped exactly as an unpublished one is online, and
# the vacuous-green refusal still fails a run that validated nothing.
# Without it, every fetch fails offline and is an error, not a skip.
if [ -n "${KUBECONFORM_SCHEMA_DIR:-}" ]; then
  [ -d "$KUBECONFORM_SCHEMA_DIR" ] || { echo "  SKIPPED: KUBECONFORM_SCHEMA_DIR=$KUBECONFORM_SCHEMA_DIR is not a directory, so nothing can be validated"; exit 2; }
  KC_FLAGS="$KC_FLAGS -schema-location $KUBECONFORM_SCHEMA_DIR/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
fi

# Reads manifests on stdin; prints kubeconform's output; returns kubeconform's
# status. Sets VALID to the summary's Valid count (empty when there is no summary).
VALID=""
validate() {
  local out rc
  # shellcheck disable=SC2086
  out="$(kubeconform $KC_FLAGS 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  VALID="$(printf '%s\n' "$out" | sed -n 's/.*Valid: \([0-9][0-9]*\).*/\1/p' | tail -1)"
  return "$rc"
}

# As validate, and also fails when nothing validated: for the selftest's
# fixtures, where zero Valid can only mean the pipeline checked nothing.
validate_some() {
  validate || return $?
  if [ -z "$VALID" ] || [ "$VALID" -eq 0 ]; then
    echo "  FAIL $1: kubeconform validated no resource; a pass here would mean nothing"
    return 1
  fi
}

need() {
  local t
  for t in "$@"; do
    if [ "$(tool_state "$t")" != ok ]; then
      echo "  SKIPPED: $(tool_why "$t")"
      exit 2
    fi
  done
}

if [ "${1:-}" = "--selftest" ]; then
  need kubeconform
  fails=0
  good='apiVersion: apps/v1
kind: Deployment
metadata:
  name: selftest
spec:
  replicas: 1
  selector:
    matchLabels: {app: selftest}
  template:
    metadata:
      labels: {app: selftest}
    spec:
      containers:
        - name: c
          image: example.invalid/selftest:1'
  if printf '%s\n' "$good" | validate_some "valid fixture" >/dev/null; then
    echo "  selftest ok: a valid Deployment passes"
  else
    echo "  SELFTEST FAIL: a valid Deployment did not pass (are the kubernetes schemas reachable?)"; fails=1
  fi
  # Three rejections -strict must make, each a defect `helm template` renders
  # happily. Each fixture is written out whole (no sed: a broken substitution
  # yields an empty fixture, which the vacuous-input refusal would then count as
  # a rejection), and each must fail for its OWN reason: kubeconform's output has
  # to name the offending key, not just exit non-zero.
  reject() {
    local name="$1" want="$2" fixture="$3" out
    if out="$(printf '%s\n' "$fixture" | validate_some "$name" 2>&1)"; then
      echo "  SELFTEST FAIL: a Deployment with $name passed"; fails=1
    elif printf '%s\n' "$out" | grep "$want" >/dev/null; then
      echo "  selftest ok: a Deployment with $name is rejected, naming $want"
    else
      echo "  SELFTEST FAIL: a Deployment with $name was rejected, but not for $want:"
      printf '%s\n' "$out" | head -5; fails=1
    fi
  }
  reject "an unknown field" "replicaz" "$(printf '%s\n' "$good" | awk '{print} /^  replicas: 1$/ {print "  replicaz: 1"}')"
  reject "a wrong type" "replicas" "$(printf '%s\n' "$good" | awk '/^  replicas: 1$/ {print "  replicas: \"one\""; next} {print}')"
  reject "a misspelt container key" "imagee" "$(printf '%s\n' "$good" | awk '{sub(/^          image: /, "          imagee: ")} {print}')"
  # The vacuous case: nothing to validate must not read as a pass.
  if printf '' | validate_some "empty input" >/dev/null; then
    echo "  SELFTEST FAIL: empty input passed"; fails=1
  else
    echo "  selftest ok: empty input is refused, not passed"
  fi
  [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
  echo "selftest FAILED"; exit 1
fi

need helm kubeconform
bad=0; n=0; total=0
for c in charts/tockmox-*; do
  [ "$c" = "charts/tockmox-common" ] && continue
  [ -f "$c/Chart.yaml" ] || continue
  n=$((n + 1))
  echo "  $c"
  if ! rendered="$(helm template t "$c" -f ci/values.yaml 2>&1)"; then
    echo "  FAIL $c: helm template failed"; printf '%s\n' "$rendered" | head -5 | sed 's/^/    /'; bad=1; continue
  fi
  # A chart may validate nothing by itself (tockmox-crds renders only
  # CustomResourceDefinitions, which kubeconform skips); the run as a whole may not.
  # A here-string, not a pipe: a pipe runs validate in a subshell and VALID
  # never reaches this loop (the first version of this gate summed zero).
  if validate <<< "$rendered"; then total=$((total + ${VALID:-0}))
  else echo "  FAIL $c"; bad=1; fi
done
[ "$n" -gt 0 ] || { echo "  FAIL: no layer charts found under charts/"; exit 1; }
if [ "$total" -eq 0 ]; then
  echo "  FAIL: kubeconform validated no resource across $n charts; a pass here would mean nothing"; exit 1
fi
[ "$bad" -eq 0 ] && echo "  ok: $n charts, $total resources validated"
exit "$bad"

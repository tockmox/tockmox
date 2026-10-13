#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Contract tests for the outcome model. A model that cannot be shown to refuse
# is a model nobody should trust, and the specific refusal that matters is the
# one that would have caught 2026-09-13's three-passes-over-nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export ASSERT_REPORT="${TMPDIR:-/tmp}/outcome-contract-$$.txt"
. "${HERE}/lib/assert.sh"

pass=0; fail=0
check() {
  local name="$1" expect="$2" got="$3"
  if [ "$expect" = "$got" ]; then printf '  ok   %-46s rc=%s\n' "$name" "$got"; pass=$((pass+1))
  else printf '  FAIL %-46s rc=%s expected %s\n' "$name" "$got" "$expect"; fail=$((fail+1)); fi
}

# Stronger than check(): also reads the "OUTCOME:  <LABEL>" line path_outcome
# emits, so a scenario cannot pass by accident on rc alone (INFRA_ERROR,
# PRODUCT_FAIL and ABORTED all return rc=1; only the label tells them apart).
check_outcome() {
  local name="$1" expect_rc="$2" expect_label="$3" out="$4" rc="$5" label
  label="$(printf '%s\n' "$out" | sed -n 's/^OUTCOME:  \([A-Z_]*\).*/\1/p' | head -1)"
  if [ "$rc" = "$expect_rc" ] && [ "$label" = "$expect_label" ]; then
    printf '  ok   %-46s rc=%s outcome=%s\n' "$name" "$rc" "$label"; pass=$((pass+1))
  else
    printf '  FAIL %-46s rc=%s outcome=%s expected rc=%s outcome=%s\n' \
      "$name" "$rc" "$label" "$expect_rc" "$expect_label"; fail=$((fail+1))
  fi
}

# 1. PASS is REFUSED when the execute phase never ran. This is the 2026-09-13 case.
EXEC_PHASE_STARTED=0; EXEC_PHASE_COMPLETED=0
path_outcome PASS >/dev/null 2>&1; check "PASS refused with no execute phase" 1 $?

# 2. PASS is REFUSED when execute began but never completed (interrupted).
EXEC_PHASE_STARTED=1; EXEC_PHASE_COMPLETED=0
path_outcome PASS >/dev/null 2>&1; check "PASS refused when execute never completed" 1 $?

# 3. PASS is ALLOWED once the phase is complete.
execute_begin "a documented command" >/dev/null 2>&1
execute_end 0 >/dev/null 2>&1
path_outcome PASS >/dev/null 2>&1; check "PASS allowed after a complete phase" 0 $?

# 4. A non-zero exit does not veto the outcome -- but it must be DECLARED.
#
#    This test was rewritten 2026-09-13 after a real run caught what the old
#    version allowed. It read "a NON-ZERO exit does not by itself prevent PASS"
#    and asserted exactly that, with nothing distinguishing a documented guard
#    firing correctly (127) from an install that simply failed. P05 then
#    reported PASS, 3 assertions of 3, with its `helm install` recorded at
#    exit=1: the assertions held only because sealed-secrets was already on the
#    cluster from an earlier path. The contract test PASSED throughout, because
#    it encoded the permissive half of the rule and never the limit.
#
#    So the rule is now explicit rather than implied: nonzero refuses PASS
#    unless the path said beforehand that nonzero is correct here.
EXEC_NONZERO_DECLARED=0
execute_begin "a command whose guard fires" >/dev/null 2>&1
execute_end 127 >/dev/null 2>&1
execute_expect_nonzero "a documented \${VAR:?} guard exits 127 when it fires" >/dev/null 2>&1
path_outcome PASS >/dev/null 2>&1; check "a DECLARED nonzero exit does not veto PASS" 0 $?

# 4b. The half that was missing. An UNDECLARED nonzero refuses PASS, whatever
#     the assertions found, because the state asserted on was not demonstrably
#     produced by this run.
EXEC_NONZERO_DECLARED=0
execute_begin "an install that simply failed" >/dev/null 2>&1
execute_end 1 >/dev/null 2>&1
path_outcome PASS >/dev/null 2>&1; check "an UNDECLARED nonzero exit refuses PASS" 1 $?

# 4c. And the refusal must not leak into the next path: a fresh execute phase
#     that exits 0 passes normally.
EXEC_NONZERO_DECLARED=0
execute_begin "a clean command" >/dev/null 2>&1
execute_end 0 >/dev/null 2>&1
path_outcome PASS >/dev/null 2>&1; check "a clean phase after a refusal still passes" 0 $?

# 5. Each non-PASS outcome carries its own distinct code.
path_outcome SKIPPED "profile excludes" >/dev/null 2>&1; check "SKIPPED is distinct" 2 $?
path_outcome BLOCKED "no inbound SSH"   >/dev/null 2>&1; check "BLOCKED is distinct" 3 $?
path_outcome INFRA_ERROR "no kubeseal"  >/dev/null 2>&1; check "INFRA_ERROR is a failure" 1 $?
path_outcome PRODUCT_FAIL "claim false" >/dev/null 2>&1; check "PRODUCT_FAIL is a failure" 1 $?

# 6. An invented outcome is refused outright rather than coerced.
path_outcome DEFINITELY_FINE >/dev/null 2>&1; check "unknown outcome refused" 2 $?

# 7. execute_end without execute_begin is a harness defect, not a silent pass.
EXEC_PHASE_STARTED=0
execute_end 0 >/dev/null 2>&1; check "execute_end without begin refused" 1 $?

# --- the RECEIPT, which is what makes the outcome model binding on the RUNNER
# rather than only on this library. Added after an outside critique observed
# that the runner aggregated on exit codes, so a path that never adopted this
# model returned 0 and counted as green.
RD="$(mktemp -d)"; export OUTCOME_RECEIPT_DIR="$RD"

EXEC_PHASE_STARTED=0; EXEC_PHASE_COMPLETED=0
TOCKMOX_PATH_NAME=r-refused path_outcome PASS >/dev/null 2>&1
[ -f "$RD/r-refused" ] && got=1 || got=0
check "a REFUSED PASS leaves no receipt" 0 "$got"

execute_begin x >/dev/null 2>&1; execute_end 0 >/dev/null 2>&1
TOCKMOX_PATH_NAME=r-pass path_outcome PASS >/dev/null 2>&1
[ -f "$RD/r-pass" ] && got=1 || got=0
check "a declared PASS leaves a receipt" 1 "$got"

TOCKMOX_PATH_NAME=r-infra path_outcome INFRA_ERROR "no kubeseal" >/dev/null 2>&1
[ -f "$RD/r-infra" ] && got=1 || got=0
check "a non-PASS outcome also leaves a receipt" 1 "$got"

TOCKMOX_PATH_NAME=r-bogus path_outcome NOPE >/dev/null 2>&1
[ -f "$RD/r-bogus" ] && got=1 || got=0
check "an invalid outcome leaves no receipt" 0 "$got"

rm -rf "$RD"

# --- FIVE NAMED SCENARIOS (TM-0571 DoD) --------------------------------------
#
# The 16 checks above are generic state-machine assertions on the model; none
# of them drives it through the shape of an actual failure a path hits. The
# 2026-09-14 overnight verification found that gap: grepping this tree for the
# five scenario phrases the DoD names returned nothing. These five do, each
# through the real mechanism a path would use, not a hand-set flag standing in
# for one, and each maps to the outcome named in TM-0571's own table.

# 1. MISSING BINARY -> INFRA_ERROR. The general shape of P07's kubeseal guard:
#    a dependency this path is not testing, absent from PATH, is a runner/
#    dependency failure, not a product finding.
_SCEN_BIN="tockmox-definitely-absent-binary-9f3c1a"
if command -v "$_SCEN_BIN" >/dev/null 2>&1; then
  # Should be unreachable, ever: the name is a random suffix chosen not to
  # collide with anything real. Fail loudly rather than silently mis-scoring.
  SCEN_A_OUT="OUTCOME:  INVALID (sentinel binary name exists on this PATH)"
  SCEN_A_RC=9
else
  SCEN_A_OUT="$(path_outcome INFRA_ERROR "missing binary: ${_SCEN_BIN} not on PATH" 2>&1)"
  SCEN_A_RC=$?
fi
check_outcome "SCENARIO missing binary -> INFRA_ERROR" 1 INFRA_ERROR "$SCEN_A_OUT" "$SCEN_A_RC"

# 2. BROKEN KUBECONFIG -> INFRA_ERROR. Hermetic: this contract test must not
#    require a real cluster or even a real kubectl on PATH, so a fake client
#    stands in for one, fed a KUBECONFIG that is not valid YAML -- the actual
#    shape of "broken kubeconfig", not a hand-set flag claiming it.
fake_kubectl_version() {
  # Mirrors kubectl's own behaviour reading an unparseable config: nonzero
  # exit, an error naming the config load, no cluster ever contacted. A
  # bracket-balance check stands in for a real YAML parser here (bash 3.2,
  # no assumption that PyYAML or any other library is installed) -- it is
  # enough to tell well-formed from the deliberately-malformed file this
  # scenario constructs below, which is all this contract test needs.
  local opens closes
  opens="$(tr -cd '[' <"$1" | wc -c | tr -d ' ')"
  closes="$(tr -cd ']' <"$1" | wc -c | tr -d ' ')"
  if [ "$opens" != "$closes" ]; then
    echo "error: error loading config file \"$1\": invalid Kubeconfig" >&2
    return 1
  fi
}
BROKEN_KC="$(mktemp "${TMPDIR:-/tmp}/tockmox-broken-kubeconfig.XXXXXX")"
printf 'not: [valid, yaml\n' >"$BROKEN_KC"
if fake_kubectl_version "$BROKEN_KC" >/dev/null 2>&1; then
  SCEN_B_OUT="OUTCOME:  INVALID (fake client accepted a broken kubeconfig)"
  SCEN_B_RC=9
else
  SCEN_B_OUT="$(path_outcome INFRA_ERROR "broken kubeconfig: client refused to load ${BROKEN_KC}" 2>&1)"
  SCEN_B_RC=$?
fi
rm -f "$BROKEN_KC"
check_outcome "SCENARIO broken kubeconfig -> INFRA_ERROR" 1 INFRA_ERROR "$SCEN_B_OUT" "$SCEN_B_RC"

# 3. DENIED IMAGE PULL -> INFRA_ERROR. The registry-rate-limit case from
#    TM-0571's own log ("nearly attributed it to the product"): classify a pod
#    status line the way a path reading `kubectl get pods` would, off the
#    actual text a denied pull produces, not an invented label.
classify_pod_status() {
  case "$1" in
    *ImagePullBackOff*|*ErrImagePull*) printf 'denied-pull' ;;
    *) printf 'other' ;;
  esac
}
FAKE_POD_STATUS="tockmox-ai-worker-0   0/1   ImagePullBackOff   0   45s"
if [ "$(classify_pod_status "$FAKE_POD_STATUS")" = "denied-pull" ]; then
  SCEN_C_OUT="$(path_outcome INFRA_ERROR "denied image pull: ${FAKE_POD_STATUS}" 2>&1)"
  SCEN_C_RC=$?
else
  SCEN_C_OUT="OUTCOME:  INVALID (classifier missed a denied pull)"
  SCEN_C_RC=9
fi
check_outcome "SCENARIO denied image pull -> INFRA_ERROR" 1 INFRA_ERROR "$SCEN_C_OUT" "$SCEN_C_RC"

# 4. PREMATURE SENTINEL -> ABORTED. The exact TM-0562/TM-0571 mechanism: a
#    documented `${VAR:?}` guard fires before the value it wants exists, exits
#    127 under `bash -c` (identical to command-not-found), and the exit is
#    UNDECLARED, so outcome_pass_allowed refuses PASS. Runs the real guard
#    rather than hard-coding 127, so a change to bash's own exit code for this
#    case would be caught here too.
EXEC_PHASE_STARTED=0; EXEC_PHASE_COMPLETED=0; EXEC_NONZERO_DECLARED=0
execute_begin "a documented \${VAR:?} guard, fired before the value it wants exists" >/dev/null 2>&1
bash -c ': "${TOCKMOX_SCENARIO_SENTINEL:?fires before the real target ran}"' >/dev/null 2>&1
_sentinel_rc=$?
execute_end "$_sentinel_rc" >/dev/null 2>&1
SCEN_D_OUT="$(path_outcome PASS 2>&1)"; SCEN_D_RC=$?
check_outcome "SCENARIO premature sentinel -> ABORTED" 1 ABORTED "$SCEN_D_OUT" "$SCEN_D_RC"

# 5. ZERO TESTS COLLECTED -> ABORTED. A path that ran a command and asserted
#    nothing about it has no standing to report anything about the product --
#    assert_summary's own rc=2 arm, driven through path_finish exactly as a
#    real path would reach it, with the real counters saved and restored so
#    this scenario cannot leak into (or borrow from) the checks around it.
_save_total=$ASSERT_TOTAL; _save_pass=$ASSERT_PASS
_save_fail=$ASSERT_FAIL; _save_xfail=$ASSERT_XFAIL
ASSERT_TOTAL=0; ASSERT_PASS=0; ASSERT_FAIL=0; ASSERT_XFAIL=0
EXEC_PHASE_STARTED=0; EXEC_PHASE_COMPLETED=0; EXEC_NONZERO_DECLARED=0
execute_begin "a documented command this scenario deliberately never asserts on" >/dev/null 2>&1
execute_end 0 >/dev/null 2>&1
SCEN_E_OUT="$(path_finish 2>&1)"; SCEN_E_RC=$?
check_outcome "SCENARIO zero tests collected -> ABORTED" 1 ABORTED "$SCEN_E_OUT" "$SCEN_E_RC"
ASSERT_TOTAL=$_save_total; ASSERT_PASS=$_save_pass
ASSERT_FAIL=$_save_fail; ASSERT_XFAIL=$_save_xfail

rm -f "$ASSERT_REPORT"
printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

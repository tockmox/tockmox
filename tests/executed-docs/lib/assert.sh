#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assertion helpers for the executed-documentation harness.
#
# The whole library exists to make one rule mechanical rather than aspirational:
# docs/testing-standard.md rule 1, "assert on the artefact, not the exit code".
# Every assertion here NAMES the artefact it reads and the value it expects, and
# prints both alongside what it actually found. There is deliberately no
# assert_succeeds. If you want to know whether a documented command worked, read
# the thing it was supposed to create.
#
# Sourced, not executed:  . "$(dirname "$0")/../lib/assert.sh"

if [ -z "${BASH_VERSION:-}" ]; then
  echo "assert.sh: must run under bash" >&2
  exit 2
fi
_bash_major="${BASH_VERSINFO[0]:-0}"
if [ "$_bash_major" -lt 3 ]; then
  echo "assert.sh: needs bash 3.2 or newer, found ${BASH_VERSION:-unknown}" >&2
  exit 2
fi

# Counters. Plain integers, not associative arrays: this file has to run on
# macOS bash 3.2, and a bash-4 construct here would fail in exactly the way
# testing-standard rule 1 was written about.
ASSERT_PASS=0
ASSERT_FAIL=0
ASSERT_TOTAL=0
ASSERT_XFAIL=0
ASSERT_REPORT="${ASSERT_REPORT:-}"

_emit() {
  printf '%s\n' "$*"
  if [ -n "$ASSERT_REPORT" ]; then printf '%s\n' "$*" >>"$ASSERT_REPORT"; fi
}

path_begin() {
  # path_begin <path-id> <one-line description>
  _emit ""
  _emit "================================================================"
  _emit "PATH:     $1"
  _emit "WHAT:     $2"
  _emit "================================================================"
}

# Record where the command text came from, so a reader of the log can confirm
# the harness ran the page rather than a copy of it.
provenance() {
  # provenance <ref> <page> <section> <block-n> <sha256>
  _emit "SOURCE:   ${2} @ ${1}"
  _emit "SECTION:  ${3}  (block ${4})"
  _emit "SHA256:   ${5}"
}

verbatim() {
  # verbatim <command text> ... echo exactly what is about to run
  _emit "--- verbatim from the page -------------------------------------"
  printf '%s\n' "$1" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
  _emit "----------------------------------------------------------------"
}

# The core assertion. Runs a READ command, compares its stdout to an expected
# value, and reports artefact / expected / actual whatever happens.
#
#   assert_artifact "crd applicationsets.argoproj.io Established" \
#                   "kubectl get crd applicationsets.argoproj.io -o jsonpath=..." \
#                   "True"
assert_artifact() {
  _assert_impl "$1" "$2" "$3" "must-pass"
}

# Same, but the expected outcome is failure: used to pin a KNOWN DEFECT so that
# the day it is fixed, this harness goes red and someone has to notice. An xfail
# that starts passing is a signal, not a nuisance.
assert_artifact_xfail() {
  _assert_impl "$1" "$2" "$3" "known-defect"
}

_assert_impl() {
  artefact="$1"; readcmd="$2"; expected="$3"; mode="$4"
  ASSERT_TOTAL=$((ASSERT_TOTAL + 1))

  # Capture, then compare. Never `cmd | grep -q`: under `set -o pipefail` that
  # pattern inverts the meaning of the test when the producer fails.
  actual="$(eval "$readcmd" 2>&1 || true)"
  [ -n "$actual" ] || actual="<empty>"

  _emit "ARTEFACT: ${artefact}"
  _emit "READ:     ${readcmd}"
  _emit "EXPECTED: ${expected}"
  _emit "ACTUAL:   ${actual}"

  if [ "$actual" = "$expected" ]; then
    if [ "$mode" = "known-defect" ]; then
      ASSERT_FAIL=$((ASSERT_FAIL + 1))
      _emit "RESULT:   FAIL ... a known defect has started passing. Re-read the"
      _emit "          card behind it before deleting this assertion."
    else
      ASSERT_PASS=$((ASSERT_PASS + 1))
      _emit "RESULT:   PASS"
    fi
  else
    if [ "$mode" = "known-defect" ]; then
      ASSERT_XFAIL=$((ASSERT_XFAIL + 1))
      _emit "RESULT:   XFAIL (expected ... this is the defect under card)"
    else
      ASSERT_FAIL=$((ASSERT_FAIL + 1))
      _emit "RESULT:   FAIL"
    fi
  fi
  _emit ""
}

# documentation-standard rule 4: every step states how the reader knows it
# worked. A path script records whether the page under test states success
# conditions at all, because a page that states none is a documentation defect
# before it is a testing gap (README, "Adding a path", step 2).
#
# The record is a COUNT OF ACCEPTED PHRASINGS, and there are two, both named
# in documentation-standard rule 4: "Success condition" and "Passes when".
# Earlier path scripts inlined `grep -c -i 'success condition'`, which reported
# docs/deployment/existing-cluster.md ... six checks, every one with a stated
# "Passes when:" ... as stating none. That is the bad failure direction: the
# harness would have written a documentation defect into the divergence list
# against a page that was correct (TM-0351). Use this, never a bare grep, and
# add a phrasing HERE and in rule 4 together if the standard ever admits a
# third.
#
#   success_condition_count <page file>           prints the count
#   record_success_conditions <page file> [label]  emits it into the run log
#
# The optional label is what the log names as the page. Path scripts read the
# page bytes at a ref into a temp file, and a log line naming
# /tmp/tockmox-p07-page.XXXXXX tells a reader nothing; pass "<page> @ <ref>".
SUCCESS_CONDITION_FORMS='success condition|passes when'

success_condition_count() {
  # Case-insensitive, so "Success condition:", "success conditions" and
  # "**Passes when:**" all count. Lines, not occurrences: one line stating one
  # condition twice is still one condition.
  [ -f "$1" ] || { echo "success_condition_count: no such file: $1" >&2; return 2; }
  grep -c -i -E "$SUCCESS_CONDITION_FORMS" "$1" || true
}

record_success_conditions() {
  # record_success_conditions <page file> [label]
  n="$(success_condition_count "$1")" || return 2
  _emit "SUCCESS CONDITIONS STATED: ${n} on ${2:-$1} (accepted forms: ${SUCCESS_CONDITION_FORMS})"
  if [ "$n" -eq 0 ]; then
    _emit "          The page states no success condition in any accepted form."
    _emit "          That is a documentation defect before it is a testing gap;"
    _emit "          record it as a divergence, do not invent one."
  fi
}

# testing-standard rule 4: state what each gate does NOT prove, alongside what
# it checks. Making this a function rather than a comment means it lands in the
# run log, where the person reading a green result actually sees it.
does_not_prove() {
  _emit "DOES NOT PROVE:"
  for line in "$@"; do _emit "  - ${line}"; done
  _emit ""
}

# testing-standard rule 5: a pass on a different architecture or OS family than
# the target is evidence WITH A CAVEAT, and the caveat is part of the result.
parity_caveat() {
  _emit "PARITY CAVEAT:"
  for line in "$@"; do _emit "  - ${line}"; done
  _emit ""
}

assert_summary() {
  _emit "----------------------------------------------------------------"
  _emit "ASSERTIONS: ${ASSERT_TOTAL} total, ${ASSERT_PASS} pass, ${ASSERT_FAIL} fail, ${ASSERT_XFAIL} xfail"
  _emit "----------------------------------------------------------------"
  # An assertion count of zero is a failure. A path that asserted nothing has
  # not been executed, however cleanly its commands exited.
  if [ "$ASSERT_TOTAL" -eq 0 ]; then
    _emit "REFUSING: this path made no assertions. A step that exits zero having"
    _emit "          examined nothing is worse than a failing step."
    return 2
  fi
  [ "$ASSERT_FAIL" -eq 0 ]
}

# declare_absence REASON
#
# Say, before exiting 3, that this path's absence at this ref is a RECORDED
# DECISION rather than drift. The runner reports declared and undeclared
# absences differently: undeclared means coverage left and nobody noticed, and
# stays loud. A declaration is a claim like any other ... it should name where
# the decision is written down and, if the path is still exercisable, at which
# ref.
declare_absence() {
  _emit "ABSENCE:  DECLARED ... ${1:-no reason given}"
  if [ -n "${ABSENCE_RECEIPT_DIR:-}" ]; then
    mkdir -p "$ABSENCE_RECEIPT_DIR" 2>/dev/null || true
    printf '%s\n' "${1:-no reason given}" \
      > "${ABSENCE_RECEIPT_DIR}/${TOCKMOX_PATH_NAME:-unknown}" 2>/dev/null || true
  fi
}

# path_finish -- assert_summary, then declare the canonical outcome.
#
# WHY THIS EXISTS RATHER THAN NINE HAND-WRITTEN path_outcome CALLS. Every path
# ended in a bare `assert_summary`, whose return value the runner read as the
# path's exit status ... which is precisely the "exit code as outcome" the
# model above rejects. Converting each path by hand would have meant nine
# chances to map the states differently, and the first one to get it wrong
# would look identical to the eight that got it right.
#
# The mapping, and each arm is deliberate:
#   assert_summary rc=2  no assertions were made  -> ABORTED. Not a product
#                        finding: the path examined nothing, so it has no
#                        standing to say anything about the product.
#   assert_summary rc=0  all assertions passed    -> PASS, which path_outcome
#                        REFUSES unless an execute phase completed. A path that
#                        forgot execute_begin therefore downgrades itself to
#                        ABORTED instead of quietly reporting a green.
#   assert_summary rc=1  an assertion failed      -> PRODUCT_FAIL. The command
#                        ran and the documented claim did not hold.
#
# A path with an environmental constraint calls path_outcome BLOCKED or
# INFRA_ERROR directly and does not reach here.
path_finish() {
  # `|| rc=$?`, never `; rc=$?`. P01, P02 and P03 re-enable `set -e` after
  # their execute phase, and under errexit a failing assert_summary on its own
  # line exits the script right here ... before the case below, so a path with
  # a real failed assertion reported UNCONVERTED instead of PRODUCT_FAIL
  # (tockmox/tockmox run 36363942977, 2026-09-28, P02). The run then said
  # "cannot report success" for the wrong reason, and the real finding was
  # one line further up where nobody reads.
  local rc=0
  assert_summary || rc=$?
  case "$rc" in
    2) path_outcome ABORTED "no assertions were made" ;;
    0) path_outcome PASS ;;
    *) path_outcome PRODUCT_FAIL "an assertion failed" ;;
  esac
}

# --------------------------------------------------------------- session model
#
# run_block_carrying_exports BLOCK_TEXT
#
# Run one documented block in its own shell, then carry any variable it
# EXPORTED into this path's environment so the next block sees it.
#
# WHY (2026-09-13). The documentation moved to a session model and this harness
# did not. TM-0484 ruled that a derived value is derived once and reused ...
# `export ARGOCD_CHART_VERSION="$(helm search ...)"` in one block, then
# `: "${ARGOCD_CHART_VERSION:?run the block above first}"` in the next. A reader
# runs both in one terminal, so that works. The harness ran every block in a
# fresh `bash -c`, so the export evaporated and the next block died on its own
# guard.
#
# **AND THE FAILURE WAS INVISIBLE**, which is the part worth carrying: an unset
# `${var:?}` under `bash -c` exits **127**, the same code as command-not-found,
# so the first reading of it was "helm is missing". Measured, not reasoned:
#   bash -c ': "${NOPE:?x}"'; echo $?   ->  127
#
# Carrying only EXPORTED names is deliberate. A block that sets a plain shell
# variable is not promising the next block anything; one that exports it is.
# The denylist keeps a documented block from reaching into the harness itself.
run_block_carrying_exports() {
  _rb_block="$1"
  _rb_env="$(mktemp "${TMPDIR:-/tmp}/exdocs-env.XXXXXX")"
  bash -c "${_rb_block}"$'\n''__rc=$?; export -p > "'"${_rb_env}"$'"; exit $__rc'
  _rb_rc=$?
  while IFS= read -r _rb_line; do
    case "$_rb_line" in
      "declare -x "*|"export "*) : ;;
      *) continue ;;
    esac
    _rb_nv="${_rb_line#declare -x }"; _rb_nv="${_rb_nv#export }"
    _rb_name="${_rb_nv%%=*}"
    case "$_rb_name" in
      PATH|PWD|OLDPWD|HOME|SHLVL|IFS|_|BASH*|KUBECONFIG|ASSERT_REPORT|TOCKMOX_*) continue ;;
      *[!A-Za-z0-9_]*|"") continue ;;
    esac
    [ "$_rb_nv" = "$_rb_name" ] && continue
    eval "export ${_rb_nv}"
  done < "$_rb_env"
  rm -f "$_rb_env"
  return $_rb_rc
}

# ------------------------------------------------------------ outcome model
#
# SIX canonical outcomes, because one Unix exit code cannot carry the meaning
# this harness needs. Added 2026-09-13 after three confusions in one day that
# were all the same missing distinction:
#
#   * A path run with no kubeseal reported two FAILs that read as "the sealing
#     documentation is broken" ... which it genuinely was once, so a reader
#     would reasonably believe it had regressed. That is INFRA_ERROR.
#   * A documented `${var:?}` guard firing correctly exits **127** under
#     `bash -c`, identical to command-not-found. The first reading was a
#     missing binary. That is a completed execute phase whose acceptance
#     contract decides, not an exit code to interpret.
#   * A registry rate limit surfaced as a storage layer failing to go healthy
#     and was nearly attributed to the product. That is INFRA_ERROR.
#
#   PASS          target ran, acceptance criteria satisfied
#   PRODUCT_FAIL  target ran, the documented claim was falsified  -> blocks release
#   BLOCKED       a declared environmental constraint prevented execution
#   INFRA_ERROR   runner, dependency, registry, API or harness failed
#   SKIPPED       the profile excludes this claim, by reviewed rule
#   ABORTED       started, never reached a trustworthy terminal state
#
# **The command's exit code is data, not the test outcome.**
#
# THE HALF THAT MATTERS MOST: PASS is unrepresentable without a completed
# execute phase. On 2026-09-13 a path reported three passes while the command
# it exists to test exited 127 having installed nothing, because every artefact
# it asserted on had been created by an earlier path on the same cluster.
# `outcome_pass_allowed` is what refuses that.

OUTCOME_VALID="PASS PRODUCT_FAIL BLOCKED INFRA_ERROR SKIPPED ABORTED"
EXEC_PHASE_STARTED=0
EXEC_PHASE_COMPLETED=0
EXEC_TARGET_DESC=""
EXEC_LAST_RC=0
EXEC_NONZERO_DECLARED=0

# Call immediately BEFORE running the documented command.
execute_begin() {
  EXEC_TARGET_DESC="$1"
  EXEC_PHASE_STARTED=1
  EXEC_PHASE_COMPLETED=0
  _emit "PHASE:    execute STARTED  (${EXEC_TARGET_DESC})"
}

# Call immediately AFTER it returns, with its raw exit status. The status is
# recorded as evidence and deliberately does NOT decide the outcome.
execute_end() {
  local rc="${1:-0}"
  [ "$EXEC_PHASE_STARTED" -eq 1 ] || {
    _emit "PHASE:    execute END WITHOUT BEGIN ... harness defect"; return 1; }
  EXEC_PHASE_COMPLETED=1
  EXEC_LAST_RC="$rc"
  _emit "PHASE:    execute COMPLETED exit=${rc}  (exit status is evidence, not the outcome)"
}

# execute_expect_nonzero REASON
#
# Declare, BEFORE the fact, that this path's documented command is expected to
# exit nonzero and that this is not a failure. The canonical case is a
# documented `${VAR:?...}` guard firing correctly, which exits 127.
execute_expect_nonzero() {
  EXEC_NONZERO_DECLARED=1
  _emit "PHASE:    nonzero exit is EXPECTED here ... ${1:-no reason given}"
}

# Returns 0 only when a PASS is representable.
#
# THE SECOND CLAUSE WAS ADDED 2026-09-13, AFTER A RUN CAUGHT IT. P05 reported
# OUTCOME PASS with "3 total, 3 pass" while the execute phase recorded exit=1:
# the documented `helm install` had FAILED, and every assertion still passed
# because sealed-secrets was already on the cluster from an earlier path. The
# phase model was satisfied ... a command really did run ... so PASS was
# representable, and the run reported green over a failed install.
#
# "The exit code is data, not the outcome" was written to stop a correct 127
# guard being read as a failure. It was never meant to let a failed install
# pass. So: a nonzero execute REFUSES PASS unless the path declared beforehand
# that nonzero is expected, via execute_expect_nonzero.
outcome_pass_allowed() {
  [ "$EXEC_PHASE_STARTED" -eq 1 ] && [ "$EXEC_PHASE_COMPLETED" -eq 1 ] || return 1
  [ "$EXEC_LAST_RC" -eq 0 ] || [ "$EXEC_NONZERO_DECLARED" -eq 1 ]
}

# Emit the path's canonical outcome. Refuses an unknown value, and refuses PASS
# without a completed execute phase.
path_outcome() {
  local o="$1" reason="${2:-}"
  case " $OUTCOME_VALID " in
    *" $o "*) : ;;
    *) _emit "OUTCOME:  INVALID '${o}' ... harness defect"; return 2 ;;
  esac
  if [ "$o" = "PASS" ] && ! outcome_pass_allowed; then
    if [ "$EXEC_PHASE_STARTED" -eq 1 ] && [ "$EXEC_PHASE_COMPLETED" -eq 1 ]; then
      _emit "OUTCOME:  ABORTED (refused PASS: the documented command exited ${EXEC_LAST_RC})"
      _emit "          Every assertion passed, but the command this path exists to"
      _emit "          test FAILED. The state asserted on was therefore not"
      _emit "          demonstrably produced by this run. If the nonzero exit is"
      _emit "          correct behaviour, declare it with execute_expect_nonzero."
      return 1
    fi
    _emit "OUTCOME:  ABORTED (refused PASS: execute phase never completed)"
    _emit "          A PASS here would be asserting on state this path did not"
    _emit "          demonstrably produce. See the outcome model in lib/assert.sh."
    return 1
  fi
  _emit "OUTCOME:  ${o}${reason:+  reason=${reason}}"
  # THE RECEIPT. Emitting an outcome into the report is not enough: the report
  # is prose and the runner cannot tell "this path declared an outcome" from
  # "this path printed something that looks like one". A receipt file is a fact
  # the aggregator can require.
  #
  # WHY (2026-09-13, from the outside critique of the design): the runner's
  # aggregate was `[ "$FAILED" -eq 0 ]`, so a path that never adopted this model
  # returned 0 and counted as green. PASS was therefore unrepresentable only
  # INSIDE this library, and the harness as a whole could still report green
  # through an older path. The receipt is what lets the runner refuse that.
  if [ -n "${OUTCOME_RECEIPT_DIR:-}" ]; then
    mkdir -p "$OUTCOME_RECEIPT_DIR" 2>/dev/null || true
    printf '%s %s\n' "$o" "${reason:-}" \
      > "${OUTCOME_RECEIPT_DIR}/${TOCKMOX_PATH_NAME:-unknown}" 2>/dev/null || true
  fi
  case "$o" in
    PASS) return 0 ;;
    SKIPPED) return 2 ;;
    BLOCKED) return 3 ;;
    *) return 1 ;;
  esac
}

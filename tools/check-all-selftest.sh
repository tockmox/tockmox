#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Proof that check-all.sh books a gate as skipped only when the gate SAYS it skipped.
#
# Exit 2 is the repository's "could not run", and check-all.sh used to book every exit 2 as skipped. A bash
# syntax error, a grep on a file that is not there and an argparse usage error exit 2 too, so a gate that
# never ran was counted as skipped and the run ended "All runnable static gates passed". The rule now:
#
#   exit 2 AND a line starting "SKIPPED: <reason>"   skip
#   exit 2 without it                                fail
#   exit 0 (token or not), exit 1 (token or not)     pass, fail
#
# This builds a copy of check-all.sh from the real file (its header, functions and result section, with the
# real gates swapped for planted ones) in a scratch repository and runs it one gate at a time and in
# parallel. Then mutated copies, one that books every exit 2 as skipped and one that reads the token
# anywhere in the output, must go red here. No network, no tools beyond bash, git, awk and python3.
#
#   bash tools/check-all-selftest.sh
#   CHECK_ALL_SH=/path/to/check-all.sh bash tools/check-all-selftest.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # the planted gates and the copy's lines are literal text
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${CHECK_ALL_SH:-${HERE}/check-all.sh}"
T="$(mktemp -d)" || { echo "check-all-selftest: cannot make a temp dir" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: git and python3 are needed to build the scratch repository"; exit 2; }

mut() { # IN OUT OLD NEW ... a copy with OLD replaced by NEW; refuses an edit that changes nothing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
t = s.replace(old, new)
assert t != s, "the edit changed nothing: %r" % old
open(dst, "w", encoding="utf-8").write(t)
PY
}

# The pieces of the real script this test needs: everything before `PLAN=""` (options, tally, run_gate) and
# from the result banner on (the report, the results file, the exit status).
[ "$(grep -c '^PLAN=""$' "$SRC")" = 1 ] && [ "$(grep -c '^# -* result$' "$SRC")" = 1 ] \
  || { echo "check-all-selftest: cannot find the PLAN and result markers in ${SRC}"; exit 1; }

W="${T}/repo"; mkdir -p "$W/tools" "$W/planted"
build() { # SRC-FILE OUT ... check-all.sh with the planted gates in place of the real ones
  {
    awk '/^PLAN=""$/ {exit} {print}' "$1"
    printf 'PLAN=""\nTREE_BEFORE="$(tree_fingerprint)"\n'
    # shellcheck disable=SC2016  # literal text for the copy
    printf 'for f in planted/*.sh; do run_gate "planted $(basename "$f" .sh)" bash "$f"; done\n'
    awk '/^# -* result$/ {on=1} on {print}' "$1"
  } > "$2"
}

plant() { # NAME BODY
  printf '%s\n' "$2" > "${W}/planted/${1}.sh"
}
reset_planted() { rm -f "${W}"/planted/*.sh; }
git -C "$W" init -q

all_planted() {
  reset_planted
  plant a-skip                 'echo "SKIPPED: no widget tool on PATH"; exit 2'
  plant b-bare-exit-2          'echo "something went wrong"; exit 2'
  plant c-syntax-error         'if then fi'
  plant d-pass                 'echo fine; exit 0'
  plant e-token-but-pass       'echo "SKIPPED: not really"; exit 0'
  plant f-token-but-fail       'echo "SKIPPED: but it failed"; exit 1'
  plant g-empty-reason         'echo "SKIPPED: "; exit 2'
  plant h-indented-token       'echo "  SKIPPED: indented"; exit 2'
  plant i-token-on-stderr      'echo "SKIPPED: said on stderr" >&2; exit 2'
  plant j-grep-missing-file    'grep needle /no/such/file/anywhere; exit $?'
}
commit_planted() {
  git -C "$W" add -A >/dev/null 2>&1
  git -C "$W" -c user.name=fixture -c user.email=fixture@example.com commit -q --allow-empty -m planted
}

# run_copy JOBS TAG ... status in $RC, output in $OUT, results in $TSV
run_copy() {
  commit_planted
  TSV="${T}/results-${2}.tsv"
  OUT="$( cd "$W" && CHECK_ALL_JOBS="$1" CHECK_ALL_RESULTS="$TSV" CHECK_ALL_GATE_TIMEOUT=60 bash tools/check-all.sh 2>&1 )"
  RC=$?
}
row_of() { awk -F'\t' -v n="planted $1" '$6 == n {print $3 " " $4}' "$TSV"; }
expect_row() { # NAME "STATUS RC" WHY
  local got; got="$(row_of "$1")"
  [ "$got" = "$2" ] && ok "$3" || bad "$3" "results row for $1 is '${got}', wanted '$2'"
}

suite() { # SOURCE-FILE LABEL
  local src="$1" label="$2" jobs
  build "$src" "${W}/tools/check-all.sh"
  for jobs in 1 2; do
    all_planted
    run_copy "$jobs" "${label}${jobs}"
    local p="${label}jobs=${jobs}: "
    expect_row a-skip              "skip 2"  "${p}exit 2 with a SKIPPED: line is a skip"
    expect_row i-token-on-stderr   "skip 2"  "${p}the SKIPPED: line may be on standard error"
    expect_row b-bare-exit-2       "fail 2"  "${p}exit 2 with no SKIPPED: line is a failure, rc kept as 2"
    expect_row c-syntax-error      "fail 2"  "${p}a bash syntax error (exit 2) is a failure"
    expect_row j-grep-missing-file "fail 2"  "${p}grep on a file that is not there (exit 2) is a failure"
    expect_row g-empty-reason      "fail 2"  "${p}SKIPPED: with no reason is a failure"
    expect_row h-indented-token    "fail 2"  "${p}an indented SKIPPED: line is not the token"
    expect_row d-pass              "pass 0"  "${p}exit 0 is a pass"
    expect_row e-token-but-pass    "pass 0"  "${p}the token with exit 0 is a pass, the token is ignored"
    expect_row f-token-but-fail    "fail 1"  "${p}the token with exit 1 is a failure"
    [ "$RC" = 1 ] && ok "${p}the run exits 1" || bad "${p}the run exits 1" "rc=${RC}"
    printf '%s\n' "$OUT" | grep -F '2 skipped' >/dev/null && printf '%s\n' "$OUT" | grep -F '6 failed' >/dev/null \
      && ok "${p}the totals read 2 skipped and 6 failed" || bad "${p}the totals" "$(printf '%s' "$OUT" | grep 'passed,' )"
    printf '%s\n' "$OUT" | grep -F 'planted a-skip: no widget tool on PATH' >/dev/null \
      && ok "${p}a skip is listed with its reason" || bad "${p}the skip list" "$(printf '%s' "$OUT" | tail -22 | tr '\n' ';')"
    printf '%s\n' "$OUT" | grep -F 'planted b-bare-exit-2 (exited 2 without' >/dev/null \
      && ok "${p}a bare exit 2 is named as such in the FAILED list" || bad "${p}the FAILED list" "$(printf '%s' "$OUT" | tail -12 | tr '\n' ';')"
    printf '%s\n' "$OUT" | grep -F 'All runnable static gates passed' >/dev/null \
      && bad "${p}no 'All runnable static gates passed' over failures" "it printed it" || ok "${p}no 'All runnable static gates passed' over failures"

    # only skips and passes: green, and the skip is still named
    reset_planted
    plant a-skip           'echo "SKIPPED: no widget tool on PATH"; exit 2'
    plant d-pass           'exit 0'
    plant e-token-but-pass 'echo "SKIPPED: not really"; exit 0'
    run_copy "$jobs" "${label}${jobs}b"
    [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -F 'All runnable static gates passed' >/dev/null \
      && ok "${p}skips and passes alone: exit 0" || bad "${p}skips and passes alone: exit 0" "rc=${RC} $(printf '%s' "$OUT" | tail -5 | tr '\n' ';')"
    printf '%s\n' "$OUT" | grep -F 'planted a-skip: no widget tool on PATH' >/dev/null \
      && ok "${p}... and the skip is named with its reason" || bad "${p}skip named" "$(printf '%s' "$OUT" | tail -8 | tr '\n' ';')"

    # one bare exit 2 turns that run red
    plant b-bare-exit-2 'exit 2'
    run_copy "$jobs" "${label}${jobs}c"
    [ "$RC" = 1 ] && ok "${p}one bare exit 2 among skips and passes: exit 1" || bad "${p}one bare exit 2: exit 1" "rc=${RC}"
  done
}

echo "check-all-selftest: planted gates through the real tally"
suite "$SRC" ""

# mutated copies of check-all.sh: each must go red in the suite above
mutant() { # LABEL OLD NEW
  local mf="${T}/mutant.sh" before=$fail
  if ! mut "$SRC" "$mf" "$2" "$3" 2>"${T}/mut.err"; then bad "mutation: $1 applies" "$(tail -1 "${T}/mut.err")"; return; fi
  local sp=$pass sf=$fail
  suite "$mf" "[mutant] " >"${T}/mutant.out" 2>&1
  local newfail; newfail=$(grep -c '^  FAIL' "${T}/mutant.out")
  # the mutant's own counters are not the test's: restore, then judge by whether it went red
  pass=$sp; fail=$sf
  [ "$newfail" -gt 0 ] && ok "mutation: ${1} ... caught (${newfail} case(s) go red)" || bad "mutation: ${1}" "no case went red"
  : "$before"
}
mutant "every exit 2 is booked as skipped (the old tally)" \
  '2) if [ -n "$(skip_reason_of "$2")" ]; then echo skip; else echo fail; fi ;;' '2) echo skip ;;'
mutant "the token is looked for anywhere in a line, not at its start" \
  "sed -n 's/^SKIPPED: \\([^[:space:]].*\\)\$/\\1/p'" "sed -n 's/.*SKIPPED: \\([^[:space:]].*\\)\$/\\1/p'"
mutant "a skip needs no reason" \
  "sed -n 's/^SKIPPED: \\([^[:space:]].*\\)\$/\\1/p'" "sed -n 's/^SKIPPED: *\\(.*\\)\$/x\\1/p'"
mutant "the token alone decides, whatever the exit status" \
  '    0) echo pass ;;
    2) if' '    0) if [ -n "$(skip_reason_of "$2")" ]; then echo skip; else echo pass; fi ;;
    2) if'

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof that run.sh judges a run by what each path's receipt SAYS, not by whether one exists
# and not by the path's exit status. No cluster, no network.
#
# Before this, a path that wrote `path_outcome BLOCKED ...; exit 0` left the job green with "paths failed:
# 0", and so did a PRODUCT_FAIL receipt with exit 0. The rule now: a run is green only if every path that
# ran left a PASS receipt, or a BLOCKED or SKIPPED one that expected-outcomes.txt allows for that path
# under its condition, with a reason.
#
# run.sh runs unmodified in a scratch repository against a stub kubectl and fixture paths P91.. whose
# receipts are the ones lib/assert.sh writes. Then mutated copies of run.sh that go back to presence-only
# checking, ignore the condition, apply the list to a named run, or let the list declare a failure must go
# green where they must not.
#
#   ./tests/executed-docs/expected-outcomes-test.sh
#   RUN_SH=/path/to/run.sh ./tests/executed-docs/expected-outcomes-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture bodies are literal text
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="${RUN_SH:-${HERE}/run.sh}"
LANE_SH="${HERE}/p09-lane.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
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

FXREPO="${TMP}/repo"; ED="${FXREPO}/tests/executed-docs"; mkdir -p "${ED}/paths" "${TMP}/bin"
cp -R "${HERE}/lib" "${ED}/lib"
if ! { git -C "$FXREPO" init -q && git -C "$FXREPO" -c user.name=fixture -c user.email=fixture@example.com \
    commit -q --allow-empty -m fixture; }; then
  bad "the scratch repository for run.sh" "git init/commit failed"
fi
cat > "${TMP}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"config get-contexts"*) echo fixture ;;
  *"get nodes"*) printf 'True' ;;
  *"version -o json"*) echo '{"serverVersion": {"gitVersion": "v0.0.0-fixture"}}' ;;
esac
exit 0
SH
chmod 755 "${TMP}/bin/kubectl"
echo "fixture" > "${TMP}/kubeconfig"

mkpath() { # ID BODY ... a fixture path paths/ID-fixture.sh
  printf '#!/usr/bin/env bash\n. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"\n%s\n' "$2" > "${ED}/paths/${1}-fixture.sh"
  chmod 755 "${ED}/paths/${1}-fixture.sh"
}
clearpaths() { rm -f "${ED}"/paths/*.sh; }
PASSBODY='path_begin "fx" "a fixture path that passes"
execute_begin "nothing"; execute_end 0
assert_artifact "one equals one" "printf 1" 1
path_finish'
N=0; MUI=0
# runit LISTTEXT|- [selectors...] ... the fixture run; output in $OUT, status in $RC. The list is LISTTEXT, or absent for -.
runit() {
  local list="$1"; shift
  N=$((N+1))
  if [ "$list" = - ]; then rm -f "${TMP}/list.txt"; else printf '%s\n' "$list" > "${TMP}/list.txt"; fi
  OUT="$( cd "$FXREPO" && PATH="${TMP}/bin:${PATH}" TOCKMOX_DOCS_REF=HEAD TOCKMOX_EXISTING_KUBECONFIG="${TMP}/kubeconfig" \
      KUBE_CONTEXT=fixture TOCKMOX_WORKDIR="${TMP}/work-${MUI}-${N}" TOCKMOX_EXPECTED_OUTCOMES="${TMP}/list.txt" \
      FXVAR_SET=yes bash "${ED}/run.sh" "$@" 2>&1 )"
  RC=$?
}
say() { printf '%s\n' "$OUT" | grep -F -- "$1" >/dev/null; }
tail_of() { printf '%s' "$OUT" | tail -4 | tr '\n' ' '; }
expect() { # NAME WANTED_RC [text that must appear]
  if [ "$RC" = "$2" ] && { [ -z "${3:-}" ] || say "$3"; }; then ok "$1"
  else bad "$1" "rc=${RC} (wanted ${2}); $(tail_of)"; fi
}
cases() {
  local tag="$1"   # the pass-through of what each case wants; mutated copies reuse the same text
  clearpaths; mkpath P91 'path_outcome BLOCKED "inputs missing"; exit 0'
  runit -
  expect "${tag}BLOCKED, exit 0, declared nowhere: red, status 4, and the summary does not say 'failed: 0' green" 4 "THIS RUN CANNOT REPORT SUCCESS"
  runit "P91 | BLOCKED | always | fixture: no inputs on this runner"
  expect "${tag}BLOCKED declared for the path: green, named, with the list's reason" 0 "BLOCKED P91-fixture, as declared in expected-outcomes.txt: fixture: no inputs on this runner"
  say "NOT covered" && ok "${tag}... and the summary says a declared BLOCKED is not coverage" || bad "${tag}not-coverage wording" "$(tail_of)"
  say "paths blocked, as declared : 1" && ok "${tag}... under its own heading, counted" || bad "${tag}heading" "$(tail_of)"
  runit "P91 | BLOCKED | unset:FXVAR_SET | fixture: only when the variable is unset"
  expect "${tag}BLOCKED declared for the wrong condition (the variable IS set): red, status 4" 4
  runit "P91 | BLOCKED | unset:FXVAR_SET,FXVAR_NOT_SET | fixture: any of the listed variables"
  expect "${tag}unset:A,B holds when ANY listed variable is unset: green" 0 "as declared"
  mkdir -p "${TMP}/st"; : > "${TMP}/st/marker"
  runit "P91 | BLOCKED | nofile:FXSTATE/marker | fixture: no marker"
  expect "${tag}nofile with the variable unset holds: green" 0 "as declared"
  N=$((N+1)); OUT="$( cd "$FXREPO" && PATH="${TMP}/bin:${PATH}" TOCKMOX_DOCS_REF=HEAD TOCKMOX_EXISTING_KUBECONFIG="${TMP}/kubeconfig" KUBE_CONTEXT=fixture \
      TOCKMOX_WORKDIR="${TMP}/work-${MUI}-${N}" TOCKMOX_EXPECTED_OUTCOMES="${TMP}/list.txt" FXSTATE="${TMP}/st" bash "${ED}/run.sh" 2>&1 )"; RC=$?
  expect "${tag}nofile with the file PRESENT does not hold: red, status 4" 4
  runit "P91 | SKIPPED | always | fixture: wrong outcome for this path"
  expect "${tag}a row for SKIPPED does not allow a BLOCKED receipt: red, status 4" 4
  runit "P92 | BLOCKED | always | fixture: another path"
  expect "${tag}a row for another path does not allow this one" 2 "no path P92 exists"

  clearpaths; mkpath P91 'path_outcome PRODUCT_FAIL "claim false"; exit 0'
  runit "P91 | BLOCKED | always | fixture: declared BLOCKED must not cover a PRODUCT_FAIL"
  expect "${tag}PRODUCT_FAIL receipt with exit 0: red, status 1" 1 "paths failed   : 1"

  clearpaths; mkpath P91 'path_outcome INFRA_ERROR "no tool"; exit 1'
  runit -
  expect "${tag}INFRA_ERROR with exit 1: red, status 5" 5 "INFRA_ERROR P91"
  clearpaths; mkpath P91 'path_outcome INFRA_ERROR "no tool"; exit 0'
  runit "P91 | BLOCKED | always | fixture: a BLOCKED row must not cover INFRA_ERROR"
  expect "${tag}INFRA_ERROR with exit 0, whatever the list holds: red, status 5" 5

  clearpaths; mkpath P91 "$PASSBODY"
  for o in PRODUCT_FAIL INFRA_ERROR ABORTED PASS; do
    runit "P91 | ${o} | always | fixture: an outcome that can never be declared"
    expect "${tag}a list row allowing ${o} is refused at parse time, before any path runs" 2 "cannot be declared"
  done
  runit "P91 | BLOCKED | sometimes | fixture: unknown condition"
  expect "${tag}an unknown condition is refused at parse time" 2 "is not always"
  runit "P91 | BLOCKED | always |"
  expect "${tag}a row with no reason is refused at parse time" 2 "non-empty reason"
  runit "P91 | BLOCKED | always"
  expect "${tag}a row with three fields is refused at parse time" 2 "four fields"

  clearpaths; mkpath P91 'echo "ran, said nothing"; exit 0'
  runit -
  expect "${tag}a missing receipt stays UNCONVERTED and red" 1 "UNCONVERTED P91"

  clearpaths; mkpath P91 'path_outcome BLOCKED "x"; exit 3'
  runit -
  expect "${tag}BLOCKED with exit 3 is a ran path and red (4), not an absent document" 4
  runit "P91 | BLOCKED | always | fixture: exit 3 after a BLOCKED receipt"
  expect "${tag}BLOCKED with exit 3, declared: green, and not booked as absent" 0 "paths absent   : 0"

  clearpaths; mkpath P91 'path_outcome BLOCKED "x"; exit 1'
  runit "P91 | BLOCKED | always | fixture: declared, but the path also crashed"
  expect "${tag}a declared BLOCKED with an unrelated nonzero exit is still red (1)" 1

  clearpaths; mkpath P91 "$PASSBODY"; mkpath P92 'path_outcome BLOCKED "no inputs"; exit 0'
  runit "P92 | BLOCKED | always | fixture: P92 has no inputs
P91 | BLOCKED | always | fixture: a row that never matches because P91 passes"
  expect "${tag}a PASS beside a declared BLOCKED is green" 0 "paths passed   : 1"
  say "WARNING stale row 2" && ok "${tag}a row no path used is reported stale (a warning)" || bad "${tag}stale warning" "$(tail_of)"
  say "WARNING stale row 1" && bad "${tag}a used row is not stale" "row 1 was used" || ok "${tag}... and a used row is not reported stale"

  clearpaths; mkpath P91 "$PASSBODY"
  runit -
  expect "${tag}a PASS receipt with exit 0 and no list at all: green (the control)" 0 "paths passed   : 1"

  # the lane's way in: the paths are NAMED, so the list is not read
  clearpaths; mkpath P09 'path_outcome BLOCKED "no inputs"; exit 0'
  runit "P09 | BLOCKED | always | fixture: declared for a full run" P09
  expect "${tag}the same declared BLOCKED in a run that NAMES the path (as the lane does): red, status 4" 4
  runit "P09 | BLOCKED | always | fixture: declared for a full run"
  expect "${tag}... and with no selectors it is the declared, green case" 0 "as declared"
}

cp "$RUN_SH" "${ED}/run.sh"
cases ""

# ---- the real lane against the real run.sh: a list entry cannot turn the lane green
LT="${TMP}/lane"; L="${LT}/tests/executed-docs"; mkdir -p "$L/provision" "$L/paths" "${TMP}/lbin"
cp -R "${HERE}/lib" "$L/lib"; cp "$LANE_SH" "$L/p09-lane.sh"; cp "$RUN_SH" "$L/run.sh"
git -C "$LT" init -q && git -C "$LT" -c user.name=fixture -c user.email=fixture@example.com commit -q --allow-empty -m fixture
cat > "$L/provision/throwaway-cluster.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in create) echo apiVersion: v1 > "$LANE_TMP/guest.kubeconfig"; echo "$LANE_TMP/guest.kubeconfig" ;; esac
STUB
printf '#!/usr/bin/env bash\n[ "$1" = url ] && echo http://site-repo.stub/tockmox.git\nexit 0\n' > "$L/provision/site-repo-server.sh"
for t in helm kubeseal openssl zsh curl age age-keygen; do printf '#!/bin/sh\nexit 0\n' > "${TMP}/lbin/$t"; done
cat > "${TMP}/lbin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *"config current-context"*) echo stub-guest ;;
  *"config get-contexts"*) echo stub-guest ;;
  *InternalIP*) echo 192.0.2.5 ;;
  *"get nodes"*) printf True ;;
  *"version -o json"*) echo '{"serverVersion": {"gitVersion": "v0"}}' ;;
esac
STUB
chmod +x "${TMP}/lbin"/* "$L/provision"/*.sh
printf '#!/usr/bin/env bash\n. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"\n%s\n' "$PASSBODY" > "$L/paths/P04-fixture.sh"
cp "$L/paths/P04-fixture.sh" "$L/paths/P05-fixture.sh"
for pp in P09-install-md-end-to-end P11-fresh-install-recovery P13-planted-faults; do
  printf '#!/usr/bin/env bash\n. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"\nif [ "${FX_%s:-PASS}" = BLOCKED ]; then path_outcome BLOCKED "fixture: no inputs"; exit 0; fi\n%s\n' "${pp%%-*}" "$PASSBODY" > "$L/paths/${pp}.sh"
done
chmod +x "$L"/paths/*.sh
printf 'P09 | BLOCKED | always | fixture: declared\nP11 | BLOCKED | always | fixture: declared\nP13 | BLOCKED | always | fixture: declared\n' > "$L/expected-outcomes.txt"
LN=0
run_lane() { # VAR=value... -> status in $LRC, output in $LOUT
  local lrun=$((LN+1)); LN=$lrun; mkdir -p "${LT}/h-${lrun}/home" "${LT}/h-${lrun}/work"
  LOUT="$(env "$@" HOME="${LT}/h-${lrun}/home" TOCKMOX_WORKDIR="${LT}/h-${lrun}/work" LANE_TMP="${LT}/h-${lrun}" PATH="${TMP}/lbin:$PATH" \
    KUBECONFIG="${LT}/h-${lrun}/substrate.kubeconfig" TOCKMOX_DOCS_REF=HEAD TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate TOCKMOX_TEST_VM=ed-lane \
    bash "$L/p09-lane.sh" 2>&1)"
  LRC=$?
}
run_lane FX_P09=PASS FX_P11=PASS
[ "$LRC" = 0 ] && ok "lane, real run.sh, P09 and P11 pass: exit 0 (the control; the list is in the tree)" || bad "lane control" "rc=$LRC $(printf '%s' "$LOUT" | tail -3 | tr '\n' ' ')"
run_lane FX_P09=BLOCKED FX_P11=PASS
[ "$LRC" = 4 ] && ok "lane, real run.sh, P09 BLOCKED although expected-outcomes.txt declares it: exit 4, not green" || bad "lane P09 declared" "rc=$LRC $(printf '%s' "$LOUT" | tail -3 | tr '\n' ' ')"
run_lane FX_P09=PASS FX_P11=BLOCKED
[ "$LRC" = 4 ] && ok "lane, real run.sh, P11 BLOCKED although declared: exit 4, not green" || bad "lane P11 declared" "rc=$LRC $(printf '%s' "$LOUT" | tail -3 | tr '\n' ' ')"
run_lane FX_P09=PASS FX_P11=PASS FX_P13=BLOCKED
[ "$LRC" = 4 ] && ok "lane, real run.sh, P13 BLOCKED although declared: exit 4, not green" || bad "lane P13 declared" "rc=$LRC $(printf '%s' "$LOUT" | tail -3 | tr '\n' ' ')"

# ---- the real P13 row, read from the real expected-outcomes.txt, against a fixture P13 that declares BLOCKED
# P13 declares BLOCKED when it has no P09 install to break (paths/P13-planted-faults.sh: no state directory, no
# p09-passed marker, or no install time). The row allows exactly the first two, and nothing else.
REAL_LIST="${HERE}/expected-outcomes.txt"
P13ROW="$(grep -E '^P13 \| BLOCKED \|' "$REAL_LIST" | head -1)"
[ -n "$P13ROW" ] && ok "the real list holds a BLOCKED row for P13" || bad "the real list holds a BLOCKED row for P13" "no such row in ${REAL_LIST}"
case "$P13ROW" in *"nofile:TOCKMOX_P09_STATE/p09-passed"*) ok "... and its condition is the marker P13's own gate reads" ;; *) bad "P13 row condition" "$P13ROW" ;; esac
grep -F '[ -f "${P09_STATE}/p09-passed" ]' "${HERE}/paths/P13-planted-faults.sh" >/dev/null \
  && ok "... which is the marker paths/P13-planted-faults.sh blocks on" || bad "P13's gate reads p09-passed" "the path no longer tests that marker"
clearpaths; mkpath P13 'path_outcome BLOCKED "TOCKMOX_P09_STATE is not set, so there is no P09 install on this cluster to break"; exit 0'
runit "$P13ROW"
expect "P13 BLOCKED with no P09 state, the real row: green, named, with the list's reason" 0 "BLOCKED P13-fixture, as declared in expected-outcomes.txt: It runs last in the lane"
say "WARNING stale" && bad "the used P13 row is not stale" "stale warning printed" || ok "... and the used P13 row is not reported stale"
runit "$P13ROW" P13
expect "the same BLOCKED P13 in a run that NAMES it (the lane): red, status 4" 4 "paths blocked, NOT declared: 1"
mkdir -p "${TMP}/p13st"
p13env() { # STATEDIR ... a full run with TOCKMOX_P09_STATE set; status in $RC, output in $OUT
  N=$((N+1)); printf '%s\n' "$P13ROW" > "${TMP}/list.txt"
  OUT="$( cd "$FXREPO" && PATH="${TMP}/bin:${PATH}" TOCKMOX_DOCS_REF=HEAD TOCKMOX_EXISTING_KUBECONFIG="${TMP}/kubeconfig" KUBE_CONTEXT=fixture \
      TOCKMOX_WORKDIR="${TMP}/work-${MUI}-${N}" TOCKMOX_EXPECTED_OUTCOMES="${TMP}/list.txt" TOCKMOX_P09_STATE="$1" bash "${ED}/run.sh" 2>&1 )"; RC=$?
}
p13env "${TMP}/p13st"
expect "P13 BLOCKED with a state directory but no p09-passed marker: green (P09 did not end PASS, so there is no install)" 0 "as declared"
: > "${TMP}/p13st/p09-passed"
p13env "${TMP}/p13st"
expect "P13 BLOCKED although P09 ended PASS on this state directory: red, status 4 (the install exists, so the block is a defect)" 4 "paths blocked, NOT declared: 1"
P13ALWAYS="$(printf '%s' "$P13ROW" | sed 's/nofile:TOCKMOX_P09_STATE\/p09-passed/always/')"
if [ "$P13ALWAYS" != "$P13ROW" ]; then
  N=$((N+1)); printf '%s\n' "$P13ALWAYS" > "${TMP}/list.txt"
  OUT="$( cd "$FXREPO" && PATH="${TMP}/bin:${PATH}" TOCKMOX_DOCS_REF=HEAD TOCKMOX_EXISTING_KUBECONFIG="${TMP}/kubeconfig" KUBE_CONTEXT=fixture \
      TOCKMOX_WORKDIR="${TMP}/work-${MUI}-${N}" TOCKMOX_EXPECTED_OUTCOMES="${TMP}/list.txt" TOCKMOX_P09_STATE="${TMP}/p13st" bash "${ED}/run.sh" 2>&1 )"; RC=$?
  [ "$RC" = 0 ] && ok "mutation: the P13 row made 'always' lets a BLOCKED P13 beside a passed P09 go green, so the case above would catch it" \
    || bad "mutation: the P13 row made 'always'" "rc=${RC}; still red, so the case above proves nothing about the condition"
else bad "mutation: the P13 row made 'always'" "the edit changed nothing"; fi
clearpaths; mkpath P13 "$PASSBODY"
runit "$P13ROW"
expect "a PASS P13 beside the P13 row: green, and the row is reported stale (a warning only)" 0 "WARNING stale row 1"

# ---- mutated copies of run.sh: each must go green (or refuse differently) where the real one is red
runmut() { # NAME OLD NEW CASE-FUNCTION-ARGS... ; installs the mutant over the fixture's run.sh
  mut "$RUN_SH" "${ED}/run.sh" "$2" "$3" || { bad "$1: the mutation applies" "edit failed"; return 1; }
}
MU="${TMP}/mu.out"
mutcase() { # NAME OLD NEW : the full case list must now contain at least one FAIL
  runmut "$1" "$2" "$3" || return 0
  MUI=$((MUI+1))
  ( cases "" ) > "$MU" 2>&1
  if grep '^FAIL' "$MU" >/dev/null; then ok "mutation: ${1} ... caught ($(grep -c '^FAIL' "$MU") case(s) go red, first: $(grep -m1 '^FAIL' "$MU" | cut -c6-90))"
  else bad "mutation: ${1}" "no case went red"; fi
}
mutcase "presence-only: a run that never reads the receipt's content" \
  'judge_path "$name" "$rc" "$receipt_outcome" "$receipt_reason"' ':'
mutcase "the condition is ignored" \
  'if [ "${EO_OUT[$i]}" = "$2" ] && eo_when_ok "$i"; then' 'if [ "${EO_OUT[$i]}" = "$2" ]; then'
mutcase "the list is applied to a run that names its paths (the lane's case)" \
  '[ "$FULL_RUN" = 1 ] || return 1' ':'
mutcase "a list row may declare PRODUCT_FAIL or INFRA_ERROR" \
  '      BLOCKED|SKIPPED) : ;;' '      BLOCKED|SKIPPED|PRODUCT_FAIL|INFRA_ERROR|ABORTED|PASS) : ;;'
mutcase "an INFRA_ERROR receipt is booked like a BLOCKED one" \
  '    INFRA_ERROR)
      INFRA_BAD=$((INFRA_BAD + 1));' '    INFRA_ERROR)
      BLOCKED_BAD=$((BLOCKED_BAD + 1));'
mutcase "a PRODUCT_FAIL receipt with exit 0 is not a failure" \
  '    *)
      FAILED=$((FAILED + 1)); failed_names="${failed_names}
  - ${n}  ${o}: ' '    *)
      : ; failed_names="${failed_names}
  - ${n}  ${o}: '
mutcase "the stale warning is dropped" \
  '  if [ "$FULL_RUN" = 1 ]; then
    _i=0' '  if false; then
    _i=0'
mutcase "an absent receipt with exit 3 hides a BLOCKED one (the old booking)" \
  'if [ "$rc" -eq 3 ] && [ -z "$receipt_outcome" ]; then' 'if [ "$rc" -eq 3 ]; then'
mutcase "the undeclared-BLOCKED exit is dropped" \
  '  exit 4
fi
exit 0' '  exit 0
fi
exit 0'
mut "$RUN_SH" "${ED}/run.sh" "" "" 2>/dev/null || cp "$RUN_SH" "${ED}/run.sh"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

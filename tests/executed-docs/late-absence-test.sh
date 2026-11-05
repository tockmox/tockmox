#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# A path that went missing PART WAY must not read as a path that was never there.
#
# Run 42074588954 (2026-11-05, the p09 lane): P09 recorded three failures, then a later step's
# needle matched two blocks of install.md. That step said `|| exit 3`, the runner books exit 3 as
# "not a documented path at this ref", the three failures were never replayed, and run.sh exited 0
# on `[ "$FAILED" -eq 0 ]`. Every job was green; the summary said "paths executed: 0".
#
# Two halves, both hermetic (no cluster, no network):
#   A. P09's own block_gone/finish_path, read out of the real path script and run against a
#      scratch state: a late missing block replays what was recorded and ends PRODUCT_FAIL; a
#      missing FIRST block is still exit 3 (the page or section is gone, a different thing).
#   B. run.sh itself, against a stub kubectl and fixture paths: an UNDECLARED absence fails the
#      run, a DECLARED one does not, and a passing path stays a pass.
#
#   ./tests/executed-docs/late-absence-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
P09="${HERE}/paths/P09-install-md-end-to-end.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

# ------------------------------------------------------------- A. P09's functions
# The function bodies are read out of P09 itself (from `name() {` to the first column-0 `}`), so
# this tests the code the path runs, not a copy of it. A missing function is a failure here.
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$P09"; }
FNS="${TMP}/p09-fns.sh"
: > "$FNS"
for f in record block_gone finish_path; do
  body="$(fn_of "$f")"
  if [ -z "$body" ]; then bad "P09 defines ${f}()" "not found in ${P09}"; else printf '%s\n' "$body" >> "$FNS"; fi
done

# One scenario per subshell: lib/assert.sh keeps its counters in the shell that sourced it.
p09_scenario() { # <state dir> <verdict rows as "desc|expected|actual" lines, may be empty>
  (
    export ASSERT_REPORT="${TMP}/assert-report.txt"
    . "${HERE}/lib/assert.sh"
    # shellcheck disable=SC1090  # P09's own functions, read out of the path above
    . "$FNS"
    STATE="$1"
    # shellcheck disable=SC2034  # read by the sourced record and finish_path
    PAGE=docs/deployment/install.md
    # shellcheck disable=SC2034  # read by the sourced finish_path
    WS_SHELL=bash
    mkdir -p "$STATE"
    execute_begin "the steps before the missing one" >/dev/null 2>&1
    execute_end 0 >/dev/null 2>&1
    while IFS='|' read -r d e a; do
      [ -n "$d" ] && record S01 "$d" "$e" "$a" >/dev/null 2>&1
    done <<EOF
$2
EOF
    block_gone S20-devops-log
  )
}

out="$(p09_scenario "${TMP}/stA1" "a step that failed|1|0
a step that passed|1|1" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^OUTCOME:  PRODUCT_FAIL'; then
  ok "P09: a late missing block after a recorded failure ends PRODUCT_FAIL (rc 1), not absent"
else bad "P09: a late missing block after a recorded failure ends PRODUCT_FAIL" "rc=${rc}; $(printf '%s' "$out" | grep -m1 '^OUTCOME' || echo 'no OUTCOME line')"; fi
if printf '%s' "$out" | grep -q 'a step that failed'; then
  ok "P09: the failure recorded before the missing block is replayed"
else bad "P09: the failure recorded before the missing block is replayed" "not in the output"; fi

out="$(p09_scenario "${TMP}/stA2" "a step that passed|1|1" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "block resolves to exactly one block"; then
  ok "P09: a late missing block is itself a failure even when every earlier step passed"
else bad "P09: a late missing block is itself a failure" "rc=${rc}"; fi

out="$(p09_scenario "${TMP}/stA3" "" 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then
  ok "P09: a missing FIRST block (nothing recorded yet) is still exit 3, absent at this ref"
else bad "P09: a missing first block is exit 3" "rc=${rc}"; fi

# ---------------------------------------------------------------- B. run.sh itself
# run.sh resolves the ref under test in its own repository root (two levels up), so the copy
# lives in a one-commit scratch repository.
FXREPO="${TMP}/repo"; ED="${FXREPO}/tests/executed-docs"; mkdir -p "${ED}/paths" "${TMP}/bin"
cp "${HERE}/run.sh" "${ED}/run.sh"; cp -R "${HERE}/lib" "${ED}/lib"
git -C "$FXREPO" init -q && git -C "$FXREPO" -c user.name=fixture -c user.email=fixture@example.com \
  commit -q --allow-empty -m fixture || bad "the scratch repository for run.sh" "git init/commit failed"
# A kubectl that answers the three questions run.sh asks of a reused cluster, and nothing else.
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

cat > "${ED}/paths/FXa-passes.sh" <<'SH'
#!/usr/bin/env bash
. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"
path_begin "FXa-passes" "a fixture path that passes"
execute_begin "nothing"; execute_end 0
assert_artifact "one equals one" 'printf 1' 1
path_finish
SH
cat > "${ED}/paths/FXb-undeclared.sh" <<'SH'
#!/usr/bin/env bash
exit 3
SH
cat > "${ED}/paths/FXc-declared.sh" <<'SH'
#!/usr/bin/env bash
. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"
declare_absence "fixture: absent by a recorded decision"
exit 3
SH
chmod 755 "${ED}"/paths/*.sh

run_fixture() { # <selectors...>
  ( cd "$FXREPO" && PATH="${TMP}/bin:${PATH}" TOCKMOX_DOCS_REF=HEAD TOCKMOX_EXISTING_KUBECONFIG="${TMP}/kubeconfig" \
      KUBE_CONTEXT=fixture TOCKMOX_WORKDIR="${TMP}/work-$1" bash "${ED}/run.sh" "$@" 2>&1 )
}

out="$(run_fixture FXa)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "run.sh: a passing fixture path exits 0 (the control)"
else bad "run.sh: a passing fixture path exits 0" "rc=${rc}; $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"; fi

out="$(run_fixture FXa FXb)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'THIS RUN CANNOT REPORT SUCCESS' \
   && printf '%s' "$out" | grep -q 'FXb-undeclared'; then
  ok "run.sh: an UNDECLARED absent path fails the run and names the path"
else bad "run.sh: an UNDECLARED absent path fails the run" "rc=${rc}; $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"; fi

out="$(run_fixture FXa FXc)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '(declared) fixture'; then
  ok "run.sh: a DECLARED absent path does not fail the run"
else bad "run.sh: a DECLARED absent path does not fail the run" "rc=${rc}; $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

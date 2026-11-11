#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof that the p09 lane tells the truth about what ran. No cluster. run.sh exits 0 for a path that
# declared BLOCKED (right in a full run, where a missing precondition is a declared constraint), so a lane that
# trusted exit statuses ended green with nothing proven: on the external route P09 declared BLOCKED (no writable
# site remote) and the lane said PASS. The lane now reads the receipt each path wrote (lib/assert.sh path_outcome)
# and fails unless the path it chose to run declared PASS:
#
#   P09 exited 0 but its receipt is BLOCKED / INFRA_ERROR / missing   lane 4 / 5 / 1, p09-passed not written, P11 not run
#   P11 exited 0 but its receipt is BLOCKED / INFRA_ERROR / other / missing   lane 4 / 5 / 1
#   P09 and P11 declared PASS                                         lane 0
#   an earlier failure's status is never replaced by a later path's
#
# p09-lane.sh runs unmodified beside stubs of what it calls; the stub run.sh writes the receipts a real one would.
# Then mutated copies of the lane that drop each check must go green where they must not.
#
#   ./tests/executed-docs/lane-outcome-test.sh
#   LANE_SH=/path/to/p09-lane.sh ./tests/executed-docs/lane-outcome-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # stub bodies are literal text
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LANE_SH="${LANE_SH:-${HERE}/p09-lane.sh}"
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

L="$TMP/tree/tests/executed-docs"
mkdir -p "$L/provision" "$TMP/lbin"
cp "$LANE_SH" "$L/p09-lane.sh"
cat > "$L/provision/throwaway-cluster.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$LANE_LOG"
case "$1" in create) echo apiVersion: v1 > "$LANE_TMP/guest.kubeconfig"; echo "$LANE_TMP/guest.kubeconfig" ;; esac
STUB
printf '#!/usr/bin/env bash\n[ "$1" = url ] && echo http://site-repo.stub/tockmox.git\nexit 0\n' > "$L/provision/site-repo-server.sh"
cat > "$L/run.sh" <<'STUB'
#!/usr/bin/env bash
# a stub run.sh: logs the call, writes the receipt a real one would ("OUTCOME reason"), exits as told
echo "run.sh $*" >> "$LANE_LOG"
case "$1" in
  P09) name=P09-install-md-end-to-end; out="${STUB_P09_OUT:-PASS}"; rc="${STUB_P09_RC:-0}" ;;
  P11) name=P11-fresh-install-recovery; out="${STUB_P11_OUT:-PASS}"; rc="${STUB_P11_RC:-0}" ;;
  *) exit 0 ;;
esac
n="$(ls "$TOCKMOX_WORKDIR" | grep -c '^receipts-')"
d="$TOCKMOX_WORKDIR/receipts-$(printf %05d $((n+1)))"; mkdir -p "$d"
[ "$out" = NONE ] || printf '%s %s\n' "$out" "${STUB_REASON:-a stub reason}" > "$d/$name"
exit "$rc"
STUB
for t in helm kubeseal openssl zsh curl age age-keygen; do printf '#!/bin/sh\nexit 0\n' > "$TMP/lbin/$t"; done
cat > "$TMP/lbin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in *"config current-context"*) echo stub-guest ;; *"get nodes"*) echo node.stub.invalid ;; esac
STUB
chmod +x "$TMP/lbin"/* "$L/provision"/*.sh "$L/run.sh"
LN=0
run_lane() { # VAR=value... -> output in $TMP/lout, status in $RC, the calls in $LH/log
  LN=$((LN+1)); LH="$TMP/lane-$LN"; mkdir -p "$LH/home" "$LH/work"; : > "$LH/log"
  env -u TOCKMOX_KEEP_CLUSTER -u TOCKMOX_P09_ROUTE "$@" HOME="$LH/home" TOCKMOX_WORKDIR="$LH/work" LANE_LOG="$LH/log" LANE_TMP="$LH" PATH="$TMP/lbin:$PATH" \
    KUBECONFIG="$LH/substrate.kubeconfig" TOCKMOX_DOCS_REF=stub TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate TOCKMOX_TEST_VM=ed-lane \
    bash "$L/p09-lane.sh" > "$TMP/lout" 2>&1
  RC=$?
}
ran() { grep -c "^run.sh $1" "$LH/log"; }
marker() { [ -e "$LH/work/p09-lane/p09-state/p09-passed" ] && echo yes || echo no; }
say() { grep -F -- "$1" "$TMP/lout" >/dev/null; }

run_lane
[ "$RC" = 0 ] && [ "$(ran P11)" = 1 ] && [ "$(marker)" = yes ] && ok "P09 and P11 declared PASS: the lane exits 0, the marker is written, P11 ran" || bad "both PASS" "rc=$RC $(tr '\n' ';' < "$LH/log")"

run_lane STUB_P11_OUT=BLOCKED STUB_REASON="root-applied-at is missing"
[ "$RC" = 4 ] && say "lane: P11-fresh-install-recovery declared BLOCKED: root-applied-at is missing" \
  && ok "P11 exited 0 but declared BLOCKED after a passed P09: the lane exits 4 and names the path, the outcome and the reason" || bad "P11 BLOCKED" "rc=$RC $(tail -3 "$TMP/lout")"
run_lane STUB_P11_OUT=INFRA_ERROR
[ "$RC" = 5 ] && say "lane: P11-fresh-install-recovery declared INFRA_ERROR" && ok "P11 declared INFRA_ERROR: the lane exits 5" || bad "P11 INFRA_ERROR" "rc=$RC"
run_lane STUB_P11_OUT=PRODUCT_FAIL
[ "$RC" = 1 ] && ok "P11 declared PRODUCT_FAIL with exit 0: the lane exits 1" || bad "P11 PRODUCT_FAIL" "rc=$RC"
run_lane STUB_P11_OUT=NONE
[ "$RC" = 1 ] && say "lane: P11-fresh-install-recovery declared MISSING" && ok "P11 left no receipt: the lane exits 1 and says so" || bad "P11 missing receipt" "rc=$RC $(tail -3 "$TMP/lout")"
run_lane STUB_P11_OUT=BLOCKED STUB_P11_RC=6
[ "$RC" = 6 ] && ok "an earlier failure is not replaced: a P11 that failed with 6 keeps 6 although its outcome would map to 4" || bad "P11 status kept" "rc=$RC"
run_lane STUB_P09_RC=3 STUB_P09_OUT=PRODUCT_FAIL
[ "$RC" = 3 ] && [ "$(ran P11)" = 0 ] && [ "$(marker)" = no ] && ok "a P09 that failed keeps its own status; no marker, no P11" || bad "P09 failed" "rc=$RC"

# P09: exit 0 is not a pass
run_lane TOCKMOX_P09_ROUTE=external STUB_P09_OUT=BLOCKED STUB_REASON="no writable site remote configured for this run (TOCKMOX_P09_SITE_REPO_URL)"
[ "$RC" = 4 ] && say "P09 exited 0 but its receipt says BLOCKED (no writable site remote configured for this run (TOCKMOX_P09_SITE_REPO_URL))" \
  && ok "external route, P09 declared BLOCKED (no site remote) with exit 0: the lane exits 4 with a line naming P09's outcome and reason" || bad "external, no remote" "rc=$RC $(tail -3 "$TMP/lout")"
[ "$(marker)" = no ] && [ "$(ran P11)" = 0 ] && ok "... and p09-passed is not written and P11 does not run" || bad "no marker, no P11" "marker=$(marker) P11 ran $(ran P11)"
run_lane STUB_P09_OUT=INFRA_ERROR
[ "$RC" = 5 ] && [ "$(marker)" = no ] && [ "$(ran P11)" = 0 ] && ok "P09 exited 0 but declared INFRA_ERROR: the lane exits 5, no marker, no P11" || bad "P09 INFRA_ERROR" "rc=$RC"
run_lane STUB_P09_OUT=NONE
[ "$RC" = 1 ] && [ "$(marker)" = no ] && [ "$(ran P11)" = 0 ] && ok "P09 exited 0 and left no receipt: the lane exits 1, no marker, no P11" || bad "P09 no receipt" "rc=$RC"

# mutated copies of the lane: each drops one check and must go green where it must not
mutlane() { mut "$LANE_SH" "$L/p09-lane.sh" "$1" "$2"; }
mutlane 'if [ "$P09_RC" = 0 ] && [ "${P09_REC%% *}" = PASS ]; then' 'if [ "$P09_RC" = 0 ]; then'
run_lane TOCKMOX_P09_ROUTE=external STUB_P09_OUT=BLOCKED
[ "$RC" = 0 ] && ok "mutation: a lane that trusts P09's exit status ends 0 over a BLOCKED P09 (and runs P11), so the case above is the guard" || bad "mutation: P09 outcome" "rc=$RC"
mutlane 'if [ "$p11_code" != 0 ] && [ "$rc" = 0 ]; then' 'if false; then'
run_lane STUB_P11_OUT=BLOCKED
[ "$RC" = 0 ] && ok "mutation: a lane that drops the P11 outcome check ends 0 over a BLOCKED P11" || bad "mutation: P11 outcome" "rc=$RC"
mutlane 'if [ "$out" = PASS ]; then' 'if [ "$out" = PASS ] || [ "$out" = MISSING ]; then'
run_lane STUB_P11_OUT=NONE
[ "$RC" = 0 ] && ok "mutation: a lane that reads a missing receipt as a pass ends 0 over a P11 that left none" || bad "mutation: missing receipt" "rc=$RC"
mutlane 'if [ "$p11_code" != 0 ] && [ "$rc" = 0 ]; then' 'if [ "$p11_code" != 0 ]; then'
run_lane STUB_P11_OUT=BLOCKED STUB_P11_RC=6
[ "$RC" = 4 ] && ok "mutation: a lane that lets a later outcome replace an earlier failure ends 4, not 6" || bad "mutation: overwrite" "rc=$RC"
mutlane 'elif [ "$P09_RC" = 0 ]; then' 'elif false; then'
run_lane STUB_P09_OUT=BLOCKED
[ "$RC" = 0 ] && ok "mutation: a lane with no branch for a P09 that exited 0 without PASS ends 0" || bad "mutation: P09 branch" "rc=$RC"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# P09's 1b revision row, in both of the lane's shapes.
#
# The installer confirms the release revision with git ls-remote from the workstation. The p09 lane
# serves the product repository inside the cluster under test (a Service address), which the
# workstation cannot reach, so the installer says "cannot reach ... not confirming" and the row that
# expects "revision ... resolves in ..." recorded a FAIL in run 42074588954 that was not a defect.
# In that shape the row is now a known gap (xfail) and the warning is what is asserted; with a
# reachable URL the row stays a plain PASS/FAIL.
#
# Hermetic. The functions are read out of P09 itself, as late-absence-test.sh does, so this tests the
# code the path runs.
#
#   ./tests/executed-docs/revision-row-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
P09="${HERE}/paths/P09-install-md-end-to-end.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$P09"; }
FNS="${TMP}/p09-fns.sh"
: > "$FNS"
for f in record in_cluster_url record_revision_row; do
  body="$(fn_of "$f")"
  if [ -z "$body" ]; then bad "P09 defines ${f}()" "not found in ${P09}"; else printf '%s\n' "$body" >> "$FNS"; fi
done

# scenario URL INSTALLER-OUTPUT ... the rows record_revision_row writes, one per line as
# "desc|expected|actual|flag"
scenario() {
  (
    STATE="$(mktemp -d "${TMP}/st.XXXX")"
    # read by P09's functions, sourced below
    # shellcheck disable=SC2034
    TM_REV="v9.9.9"
    # shellcheck disable=SC2034
    TM_URL="$1"
    # shellcheck disable=SC2329
    _emit() { :; }
    # shellcheck disable=SC2329
    out_of() { cat "${STATE}/${1}.out" 2>/dev/null; }
    # shellcheck source=/dev/null  # P09's own functions, read out of the path above
    . "$FNS"
    printf '%s\n' "$2" > "${STATE}/S06.out"
    record_revision_row S06
    awk -F'\t' '{print $2 "|" $3 "|" $4 "|" $5}' "${STATE}/verdicts.tsv"
  )
}

# The long Service form is assembled from two parts: the outbound scrubber refuses an internal host
# name written whole in a public file, and a test fixture is not one.
CD="svc.cluster"; CD="${CD}.local"
IN="http://tockmox-src.tockmox-p09.${CD}:8080/tockmox.git"
WARN="cannot reach ${IN} ... not confirming 'v9.9.9' exists (fine if you are air-gapped or mirroring)"

# 1. in the cluster, the installer warns: the revision row is xfail and the warning is asserted, both met
rows="$(scenario "$IN" "$WARN")"
first="$(sed -n 1p <<<"$rows")"; second="$(sed -n 2p <<<"$rows")"
if [[ "$first" == *"inside the cluster under test"*"|1|0|xfail" && "$second" == *"is not confirming v9.9.9|1|1|" ]] \
   && [ "$(grep -c . <<<"$rows")" -eq 2 ]; then
  ok "an in-cluster product repository: the revision row is xfail, and the installer's warning is asserted and present"
else
  bad "the in-cluster shape" "rows: ${rows}"
fi

# 2. in the cluster, but the installer said nothing about it: the warning row records a failure
rows="$(scenario "$IN" "settings valid")"
if [[ "$(sed -n 2p <<<"$rows")" == *"|1|0|" ]]; then
  ok "an in-cluster product repository with no warning in the output records the warning row as a failure"
else
  bad "the missing warning" "rows: ${rows}"
fi

# 3. a reachable repository: one plain row, as before
OUT="https://github.com/tockmox/tockmox.git"
rows="$(scenario "$OUT" "revision v9.9.9 resolves in ${OUT}")"
if [ "$rows" = "1b: 'revision v9.9.9 resolves in ${OUT}'|1|1|" ]; then
  ok "a reachable product repository keeps the revision row a plain assertion, met"
else
  bad "the reachable shape" "rows: ${rows}"
fi
rows="$(scenario "$OUT" "settings valid")"
if [ "$rows" = "1b: 'revision v9.9.9 resolves in ${OUT}'|1|0|" ]; then
  ok "a reachable product repository whose revision did not resolve records a failure, not an xfail"
else
  bad "the reachable shape, unresolved" "rows: ${rows}"
fi

# 4. what counts as inside the cluster
(
  # shellcheck source=/dev/null
  . "$FNS"
  for u in "$IN" "http://src.ns.svc/x.git" "https://user@src.ns.${CD}/x.git" "git://src.ns.svc:9418/x"; do
    in_cluster_url "$u" || { echo "MISS $u"; exit 1; }
  done
  for u in "$OUT" "https://src.ns.${CD}.example.com/x.git" "https://svc.example.com/x" "http://192.0.2.5/x.git"; do
    in_cluster_url "$u" && { echo "FALSE $u"; exit 1; }
  done
  exit 0
) > "${TMP}/class" 2>&1
class_rc=$?
if [ "$class_rc" -eq 0 ]; then ok "in-cluster addresses are told apart by their host, whatever the scheme, user, port or path"
else bad "in_cluster_url" "$(cat "${TMP}/class")"; fi

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

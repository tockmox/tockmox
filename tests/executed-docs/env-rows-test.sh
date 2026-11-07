#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Two P09 rows whose expectation depends on where the path runs.
#
#   S04  the public repository has the release tag: xfail on a candidate before the tag is pushed, a
#        plain PASS once it is published. A run on main after the release recorded the pass as "a
#        known defect has started passing", which was the expectation going stale.
#   S21c the forge signs people in through Authentik: on a throwaway with no resolver for the site's
#        domain the forge cannot look up auth.<domain>, so that one refusal is BLOCKED by the
#        environment (xfail). Any other answer, or the same with a resolver named, stays plain.
#
# Hermetic. The functions are read out of P09 itself, as revision-row-test.sh does.
#
#   ./tests/executed-docs/env-rows-test.sh
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
for f in record record_tag_row record_sign_in_row; do
  body="$(fn_of "$f")"
  if [ -z "$body" ]; then bad "P09 defines ${f}()" "not found in ${P09}"; else printf '%s\n' "$body" >> "$FNS"; fi
done

# rows FUNCTION OUTPUT [RESOLVER] ... the rows FUNCTION writes for a step whose output is OUTPUT,
# one per line as "desc|expected|actual|flag"
rows() {
  (
    STATE="$(mktemp -d "${TMP}/st.XXXX")"
    # read by P09's functions, sourced below
    # shellcheck disable=SC2034
    INTERNAL_DOMAIN_V="p09.internal"
    if [ -n "${3:-}" ]; then export TOCKMOX_P09_LAN_RESOLVER="$3"; else unset TOCKMOX_P09_LAN_RESOLVER; fi
    # shellcheck disable=SC2329
    _emit() { :; }
    # shellcheck disable=SC2329
    out_of() { cat "${STATE}/${1}.out" 2>/dev/null; }
    # shellcheck source=/dev/null  # P09's own functions, read out of the path above
    . "$FNS"
    printf '%s\n' "$2" > "${STATE}/S.out"
    "$1" S
    awk -F'\t' '{print $2 "|" $3 "|" $4 "|" $5}' "${STATE}/verdicts.tsv"
  )
}

SHA="0123456789abcdef0123456789abcdef01234567"

# S04
r="$(rows record_tag_row "$(printf '%s\trefs/tags/v9.9.9' "$SHA")")"
if [ "$r" = "ls-remote of the public repo prints a SHA and the tag (the tag is published)|prints|prints|" ]; then
  ok "S04: a published tag is a plain pass, not 'a known defect has started passing'"
else bad "S04 published" "rows: ${r}"; fi
r="$(rows record_tag_row "")"
if [[ "$r" == *"(xfail before the tag is pushed: this path runs on the candidate)|prints|nothing|xfail" ]]; then
  ok "S04: no tag yet (a candidate) is the known gap, xfail"
else bad "S04 candidate" "rows: ${r}"; fi
r="$(rows record_tag_row "fatal: could not read Username")"
if [[ "$r" == *"|prints|nothing|xfail" ]]; then
  ok "S04: an answer with no SHA and tag is not read as published"
else bad "S04 no SHA" "rows: ${r}"; fi

# S21c
DNS="! the forge refused the sign-in source: ... Get \"https://auth.p09.internal/application/o/tockmox-forge/.well-known/openid-configuration\": dial tcp: lookup auth.p09.internal on 192.0.2.10:53: no such host"
r="$(rows record_sign_in_row "== Connecting the forge's sign-in
  ✓ the forge signs people in through Authentik")"
if [ "$r" = "sign-in: the forge signs people in through Authentik|1|1|" ]; then
  ok "S21c: a connected sign-in is a plain pass"
else bad "S21c connected" "rows: ${r}"; fi
r="$(rows record_sign_in_row "$DNS")"
if [[ "$r" == *"BLOCKED by the environment"*"auth.p09.internal"*"|1|0|xfail" ]]; then
  ok "S21c: on a throwaway with no resolver, the forge failing to look up auth.<domain> is BLOCKED by the environment (xfail)"
else bad "S21c throwaway DNS" "rows: ${r}"; fi
r="$(rows record_sign_in_row "$DNS" 192.0.2.53)"
if [ "$r" = "sign-in: the forge signs people in through Authentik|1|0|" ]; then
  ok "S21c: the same refusal with a LAN resolver named is a real failure"
else bad "S21c with resolver" "rows: ${r}"; fi
r="$(rows record_sign_in_row "! the forge refused the sign-in source: 401 Unauthorized")"
if [ "$r" = "sign-in: the forge signs people in through Authentik|1|0|" ]; then
  ok "S21c: any other refusal on a throwaway is a real failure, not the DNS gap"
else bad "S21c other refusal" "rows: ${r}"; fi
r="$(rows record_sign_in_row "lookup auth.example.com on 192.0.2.10:53: no such host")"
if [ "$r" = "sign-in: the forge signs people in through Authentik|1|0|" ]; then
  ok "S21c: a failed lookup of some other name is a real failure"
else bad "S21c other name" "rows: ${r}"; fi

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

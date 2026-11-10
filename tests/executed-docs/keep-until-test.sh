#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for KEEP MEANS KEEP (throwaway-cluster.sh keep_until_value and sweep).
# No cluster: kubectl is a stub that prints a VM list and logs every call; the
# provisioner runs unmodified against it.
#
#   1. sweep leaves a VM alone while its tockmox.com/keep-until is in the future, and
#      sweeps it by the age rule once that has passed, when it has no label, or when
#      the label is not epoch seconds; a young VM is left alone as before
#   2. a kept create's label is now plus TOCKMOX_KEEP_HOURS (default 6); an unkept
#      create carries none; hours outside 1 to 24, or not a number, are refused
#
#   ./tests/executed-docs/keep-until-test.sh
#   TC=/path/to/throwaway-cluster.sh ./tests/executed-docs/keep-until-test.sh
#
# TC points the cases at another copy of the provisioner, to show they go red there.
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # the greps read the provisioner's source text literally
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

mkdir -p "$TMP/bin" "$TMP/work"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/bin/sh
echo "$*" >> "$KT_LOG"
case "$*" in
  *"get vm -o custom-columns"*) cat "$KT_VMS" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/kubectl"

stamp() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
now="$(date -u +%s)"
OLD="$(stamp -300)"; YOUNG="$(stamp -10)"
{
  printf 'ed-kept %s %s\n' "$OLD" "$((now + 3600))"
  printf 'ed-expired %s %s\n' "$OLD" "$((now - 60))"
  printf 'ed-unlabelled %s <none>\n' "$OLD"
  printf 'ed-young %s <none>\n' "$YOUNG"
  printf 'ed-junk %s junk\n' "$OLD"
  printf 'other-vm %s <none>\n' "$OLD"
} > "$TMP/vms"

run_tc() {  # verb args... -> stdout+stderr in $TMP/out, status in $RC
  KT_LOG="$TMP/log" KT_VMS="$TMP/vms" PATH="$TMP/bin:$PATH" TMPDIR="$TMP/work" \
    TOCKMOX_SUBSTRATE_CONTEXT=stub TOCKMOX_TEST_NAMESPACE=tockmox-test \
    bash "$TC" "$@" > "$TMP/out" 2>&1
  RC=$?
}

# 1. sweep
: > "$TMP/log"; run_tc sweep ed- 120
swept() { grep -c "sweep: $1 is [0-9]* min old; destroying it by name" "$TMP/out"; }
[ "$(grep -c 'sweep: ed-kept is kept for' "$TMP/out")" = 1 ] && [ "$(swept ed-kept)" = 0 ] \
  && ok "sweep leaves a VM alone while its keep-until is in the future" \
  || bad "sweep leaves a VM alone while its keep-until is in the future" "$(grep 'ed-kept' "$TMP/out")"
[ "$(swept ed-expired)" = 1 ] && ok "sweep takes a kept VM once its keep-until has passed" \
  || bad "sweep takes a kept VM once its keep-until has passed" "$(grep 'ed-expired' "$TMP/out")"
[ "$(swept ed-unlabelled)" = 1 ] && ok "sweep takes an old VM with no keep-until, as before" \
  || bad "sweep takes an old VM with no keep-until, as before" "$(grep 'ed-unlabelled' "$TMP/out")"
[ "$(grep -c 'sweep: ed-young is 10 min old, younger than 120; left alone' "$TMP/out")" = 1 ] \
  && ok "sweep leaves a young VM alone, as before" || bad "sweep leaves a young VM alone, as before" "$(grep 'ed-young' "$TMP/out")"
[ "$(grep -c "ed-junk has keep-until 'junk', not epoch seconds" "$TMP/out")" = 1 ] && [ "$(swept ed-junk)" = 1 ] \
  && ok "a keep-until that is not epoch seconds is named, and the age rule decides" \
  || bad "a keep-until that is not epoch seconds is named, and the age rule decides" "$(grep 'ed-junk' "$TMP/out")"
[ "$(grep -c 'other-vm' "$TMP/out")" = 0 ] && ok "a VM without the prefix is not touched" \
  || bad "a VM without the prefix is not touched" "$(grep 'other-vm' "$TMP/out")"

# 2. the label a create writes
TOCKMOX_KEEP_CLUSTER=0 run_tc keep-until
[ "$RC" = 0 ] && [ -z "$(tr -d '\n' < "$TMP/out")" ] && ok "an unkept VM carries no keep-until" \
  || bad "an unkept VM carries no keep-until" "rc=$RC out=$(cat "$TMP/out")"
t0="$(date -u +%s)"; TOCKMOX_KEEP_CLUSTER=1 run_tc keep-until; v="$(tr -d '\n' < "$TMP/out")"
case "$v" in ''|*[!0-9]*) d=x ;; *) d=$(( v - t0 - 6 * 3600 )) ;; esac
[ "$RC" = 0 ] && [ "$d" != x ] && [ "$d" -ge 0 ] && [ "$d" -le 5 ] && ok "a kept VM is kept for 6 hours by default" \
  || bad "a kept VM is kept for 6 hours by default" "rc=$RC out=$v"
t0="$(date -u +%s)"; TOCKMOX_KEEP_CLUSTER=1 TOCKMOX_KEEP_HOURS=24 run_tc keep-until; v="$(tr -d '\n' < "$TMP/out")"
case "$v" in ''|*[!0-9]*) d=x ;; *) d=$(( v - t0 - 24 * 3600 )) ;; esac
[ "$RC" = 0 ] && [ "$d" != x ] && [ "$d" -ge 0 ] && [ "$d" -le 5 ] && ok "TOCKMOX_KEEP_HOURS=24 keeps it a day" \
  || bad "TOCKMOX_KEEP_HOURS=24 keeps it a day" "rc=$RC out=$v"
for h in 0 25 six; do
  TOCKMOX_KEEP_CLUSTER=1 TOCKMOX_KEEP_HOURS="$h" run_tc keep-until
  [ "$RC" = 2 ] && grep '^REFUSING: TOCKMOX_KEEP_HOURS' "$TMP/out" >/dev/null \
    && ok "TOCKMOX_KEEP_HOURS=$h is refused" || bad "TOCKMOX_KEEP_HOURS=$h is refused" "rc=$RC out=$(cat "$TMP/out")"
done

# create's manifest carries what keep_until_value printed (a line-level read: create
# itself needs a hypervisor; handoff-secret-test.sh drives the rest of it).
grep -F 'keep_until="$(keep_until_value)"' "$TC" >/dev/null && grep -F 'tockmox.com/keep-until: "%s"' "$TC" >/dev/null \
  && ok "create writes keep-until into the VM's labels" || bad "create writes keep-until into the VM's labels" "no label line in $TC"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

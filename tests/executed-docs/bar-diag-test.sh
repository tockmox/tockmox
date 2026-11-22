#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for what P09 leaves in its log when S17's readiness bar records a FAIL: for each Application the bar
# still lists, its destination namespace's pods, PersistentVolumeClaims, last 50 events, and each container that is
# not running and why, every line "DIAG: <namespace>: ...". A lane run destroyed at the safe end is then readable
# from its log alone. No cluster: kubectl is a stub that answers from files and records what it was asked.
#
#   1. lib/p09-bar-diag.py --pods names an image that cannot be pulled (with the image), a crash loop (with its last
#      exit), a pod Pending on an unbound claim (with the scheduler's words), and an Evicted pod; a pod that Succeeded,
#      an init container that Completed and a container running and ready are not listed; unreadable input says so
#   2. --frame prefixes every line, drops blank ones, keeps at most --cap lines a namespace and says how many it cut,
#      cuts a line at --width, and takes the site repository and its host out
#   3. P09's S17 step, read out of P09 and run unmodified against the stub, on a FORCED FAIL: the DIAG block is
#      written for each not-ready Application's namespace (once per namespace), names the ImagePullBackOff image and
#      the unbound claim, keeps only the last 50 events, scrubs the site remote and the off-site host, and the step
#      records the same single FAIL row it records without the block (it adds no verdict)
#   4. every kubectl call the step makes names its cluster with $KUBE_CONTEXT and only reads (get, logs)
#   5. the same step on a PASS (the bar clean twice) writes no DIAG line and makes no pod, claim or event read
#
#   ./tests/executed-docs/bar-diag-test.sh
#   P09=/path/to/P09.sh ./tests/executed-docs/bar-diag-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # the step script is written with literal dollar signs, for the run to expand
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
P09="${P09:-${HERE}/paths/P09-install-md-end-to-end.sh}"
DIAG_PY="${DIAG_PY:-${HERE}/lib/p09-bar-diag.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { printf '%s' "$1" | grep -F -- "$2" >/dev/null; }

SITE="git://site-host.example:30999/site.git"
OFF="offsite-host.example"
IMG="registry.example/longhornio/longhorn-manager:v1.7.2"

# ------------------------------------------------------------------ fixtures
SB="${TMP}/sb"; mkdir -p "$SB"
cat > "${SB}/pods-longhorn-system.json" <<EOF
{"kind":"List","items":[
 {"metadata":{"name":"longhorn-manager-abc"},"status":{"phase":"Pending",
   "initContainerStatuses":[{"name":"wait","image":"busybox","ready":true,"state":{"terminated":{"reason":"Completed","exitCode":0}}}],
   "containerStatuses":[{"name":"manager","image":"${IMG}","ready":false,"restartCount":0,
     "state":{"waiting":{"reason":"ImagePullBackOff","message":"Back-off pulling image \"${IMG}\""}}}]}},
 {"metadata":{"name":"longhorn-ui-def"},"status":{"phase":"Running",
   "containerStatuses":[{"name":"ui","image":"ui:1","ready":true,"restartCount":0,"state":{"running":{"startedAt":"x"}}}]}},
 {"metadata":{"name":"longhorn-csi-ghi"},"status":{"phase":"Running",
   "containerStatuses":[{"name":"csi","image":"csi:2","ready":false,"restartCount":7,
     "state":{"waiting":{"reason":"CrashLoopBackOff","message":"back-off 5m0s restarting failed container"}},
     "lastState":{"terminated":{"reason":"Error","exitCode":1}}}]}},
 {"metadata":{"name":"longhorn-job-done"},"status":{"phase":"Succeeded"}},
 {"metadata":{"name":"longhorn-evicted"},"status":{"phase":"Failed","reason":"Evicted","message":"The node was low on resource: ephemeral-storage."}}
]}
EOF
cat > "${SB}/pods-tockmox-data.json" <<'EOF'
{"kind":"List","items":[
 {"metadata":{"name":"tockmox-pg-1"},"status":{"phase":"Pending","conditions":[
   {"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims."}]}}
]}
EOF
printf 'NAME                  READY   STATUS             RESTARTS   AGE   IP          NODE\nlonghorn-manager-abc  0/1     ImagePullBackOff   0          35m   pod-ip-1   node-1\n' > "${SB}/wide-longhorn-system.txt"
printf 'NAME           READY   STATUS    RESTARTS   AGE   IP       NODE\ntockmox-pg-1   0/1     Pending   0          35m   <none>   <none>\n' > "${SB}/wide-tockmox-data.txt"
printf 'No resources found in longhorn-system namespace.\n' > "${SB}/pvc-longhorn-system.txt"
printf 'NAME           STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE\ntockmox-pg-1   Pending                                      longhorn       35m\n' > "${SB}/pvc-tockmox-data.txt"
{ echo "LAST SEEN   TYPE      REASON   OBJECT                     MESSAGE"
  for i in $(seq 1 60); do echo "${i}m         Warning   Failed   pod/longhorn-manager-abc   event-${i}: Failed to pull image \"${IMG}\""; done
  echo "1m          Normal    Synced   application/x              reading ${SITE} via ${OFF}"
} > "${SB}/events-longhorn-system.txt"
printf 'LAST SEEN   TYPE      REASON             OBJECT                        MESSAGE\n2m          Warning   FailedScheduling   pod/tockmox-pg-1   0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims.\n' > "${SB}/events-tockmox-data.txt"
printf 'longhorn-system' > "${SB}/dest-tockmox-storage"
printf 'tockmox-data' > "${SB}/dest-tockmox-data"
printf 'tockmox-data' > "${SB}/dest-tockmox-data-jobs"
printf '{"kind":"List","items":[{"metadata":{"name":"tockmox-storage"},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Degraded"}}}]}' > "${SB}/applications.json"

# 1
pods_of() { python3 -I "$DIAG_PY" --pods < "$1"; }
if [ -f "$DIAG_PY" ]; then
  out="$(pods_of "${SB}/pods-longhorn-system.json")"
  has "$out" "pod longhorn-manager-abc (Pending): container manager, image ${IMG}: waiting ImagePullBackOff: Back-off pulling image \"${IMG}\"" \
    && ok "pods: an image that cannot be pulled is named, with the image" || bad "pods: an image that cannot be pulled is named, with the image" "$out"
  has "$out" "pod longhorn-csi-ghi (Running): container csi, image csi:2: waiting CrashLoopBackOff: back-off 5m0s restarting failed container; last terminated Error, exit 1" \
    && ok "pods: a crash loop is named, with its last exit" || bad "pods: a crash loop is named, with its last exit" "$out"
  has "$out" "pod longhorn-evicted (Failed): Evicted: The node was low on resource: ephemeral-storage." \
    && ok "pods: a pod with no container status gives its own reason" || bad "pods: a pod with no container status gives its own reason" "$out"
  printf '%s' "$out" | grep -E 'longhorn-ui-def|longhorn-job-done|container wait' >/dev/null \
    && bad "pods: Succeeded, a Completed init container, and running-and-ready are not listed" "$out" \
    || ok "pods: Succeeded, a Completed init container, and running-and-ready are not listed"
  out="$(pods_of "${SB}/pods-tockmox-data.json")"
  [ "$out" = "pod tockmox-pg-1 (Pending): PodScheduled False Unschedulable: 0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims." ] \
    && ok "pods: a pod Pending on an unbound claim gives the scheduler's words" || bad "pods: a pod Pending on an unbound claim gives the scheduler's words" "$out"
  out="$(printf '{"items":[]}' | python3 -I "$DIAG_PY" --pods)"
  [ "$out" = "none" ] && ok "pods: an empty namespace prints none" || bad "pods: an empty namespace prints none" "$out"
  for input in '' 'not json' '{"kind":"Status","message":"forbidden"}'; do
    out="$(printf '%s' "$input" | python3 -I "$DIAG_PY" --pods)"; rc=$?
    [ "$out" = "unreadable: not a list of pods" ] && [ "$rc" = 0 ] && ok "pods: unreadable input (${input:-empty}) says so and exits 0" \
      || bad "pods: unreadable input (${input:-empty}) says so and exits 0" "rc=${rc} ${out}"
  done

# 2
  out="$(printf 'one\n\n  \ntwo %s\n' "$SITE" | python3 -I "$DIAG_PY" --frame ns-a --scrub "$SITE")"
  [ "$out" = "$(printf 'DIAG: ns-a: one\nDIAG: ns-a: two <site repository>')" ] \
    && ok "frame: every line is DIAG: NS:, blank lines dropped, the site repository scrubbed" || bad "frame: prefix, blanks, scrub" "$out"
  out="$(printf 'via site-host.example\n' | python3 -I "$DIAG_PY" --frame ns-a --scrub "$SITE")"
  [ "$out" = "DIAG: ns-a: via <site host>" ] && ok "frame: the site host alone is scrubbed too" || bad "frame: the site host alone is scrubbed too" "$out"
  out="$(seq 1 500 | python3 -I "$DIAG_PY" --frame ns-b)"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 200 ] && [ "$(printf '%s\n' "$out" | sed -n 199p)" = "DIAG: ns-b: 199" ] \
    && [ "$(printf '%s\n' "$out" | tail -n 1)" = "DIAG: ns-b: ... 301 more line(s) cut here (at most 200 a namespace)" ] \
    && ok "frame: at most 200 lines a namespace, the last saying how many were cut" || bad "frame: at most 200 lines a namespace" "$(printf '%s\n' "$out" | tail -n 2)"
  out="$(seq 1 200 | python3 -I "$DIAG_PY" --frame ns-b | tail -n 1)"
  [ "$out" = "DIAG: ns-b: 200" ] && ok "frame: exactly 200 lines are kept whole" || bad "frame: exactly 200 lines are kept whole" "$out"
  out="$(python3 -c 'print("x" * 2000)' | python3 -I "$DIAG_PY" --frame ns-c)"
  [ "${#out}" = 400 ] && ok "frame: a line is cut at 400 characters" || bad "frame: a line is cut at 400 characters" "${#out}"
else
  bad "lib/p09-bar-diag.py exists" "not found: ${DIAG_PY}"
fi

# ------------------------------------------------------------------ the step
# A kubectl that answers from the files above and records every call.
BIN="${TMP}/bin"; mkdir -p "$BIN"
cat > "$BIN/kubectl" <<'STUB'
#!/usr/bin/env python3
import os, sys
sb = os.environ["SB"]
with open(os.path.join(sb, "calls.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
a = [x for x in sys.argv[1:] if not x.startswith("--context=") and not x.startswith("--request-timeout=")]
ns = ""
if "-n" in a:
    i = a.index("-n"); ns = a[i + 1]; del a[i:i + 2]
def put(name):
    p = os.path.join(sb, name)
    if not os.path.exists(p):
        sys.stderr.write("No resources found in %s namespace.\n" % ns); sys.exit(0)
    sys.stdout.write(open(p).read()); sys.exit(0)
if a[:1] == ["logs"]:
    sys.exit(0)
if a[:2] == ["get", "applications"] and a[-2:] == ["-o", "json"]:
    put("applications.json")
if a[:2] == ["get", "application"] and len(a) == 5 and a[3] == "-o" and a[4].startswith("jsonpath="):
    put("dest-" + a[2])
if a == ["get", "pods", "-o", "wide"]:
    put("wide-" + ns + ".txt")
if a == ["get", "pods", "-o", "json"]:
    put("pods-" + ns + ".json")
if a == ["get", "pvc"]:
    put("pvc-" + ns + ".txt")
if a[:2] == ["get", "events"]:
    put("events-" + ns + ".txt")
sys.stderr.write("stub kubectl: no answer for: %s\n" % " ".join(sys.argv[1:])); sys.exit(1)
STUB
chmod +x "$BIN/kubectl"

fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\) +\\{" {on=1; print; if ($0 ~ /\}[ \t]*$/) exit; next} on {print} on && /^}/ {exit}' "$P09"; }
STEPSH="${TMP}/s17.sh"
{
  printf '%s\n' 'set -uo pipefail'
  printf 'HERE=%q\n' "${HERE}/paths"
  printf '%s\n' '_emit() { printf "%s\n" "$*"; }' \
    'step_begin() { return 0; }' 'block_gone() { echo "block gone"; exit 9; }' 'block() { printf "the bar"; }' \
    'budget_left() { return 0; }' 'yield() { echo "yield"; exit 75; }' 'sleep() { :; }' \
    'execute_expect_nonzero() { :; }' 'execute_begin() { :; }' 'execute_end() { :; }' \
    'run_ws() { cp "${SB}/bar.out" "${STATE}/${1}.out"; }'
  printf '. %q\n' "${HERE}/lib/p09-offsite.sh"
} > "$STEPSH"
for f in done_step mark_done record note out_of bar_diag; do
  body="$(fn_of "$f")"
  if [ -z "$body" ]; then bad "P09 defines ${f}()" "not found in ${P09}"; else printf '%s\n' "$body" >> "$STEPSH"; fi
done
step="$(awk '/^S=S17-watch-waves$/ {f=1} f {print} f && /^fi$/ {exit}' "$P09")"
[ -n "$step" ] && ok "P09's S17 step is read out of P09" || bad "P09's S17 step is read out of P09" "no 'S=S17-watch-waves' ... 'fi' in ${P09}"
printf '%s\n' "$step" >> "$STEPSH"

# run_step NAME ... a fresh state, the watch already pasted, root.yaml applied long enough ago that the 40 minutes are up
run_step() {
  local st="${TMP}/state-$1"
  rm -rf "$st"; mkdir -p "$st"; : > "${SB}/calls.log"
  : > "${st}/S17-watch-waves.out"
  printf '%s' "$(( $(date +%s) - 3000 ))" > "${st}/root-applied-at"
  [ "$1" = pass ] && printf '%s' "$(( $(date +%s) - 200 ))" > "${st}/bar-first-clean"
  ( export SB STATE="$st" KUBE_CONTEXT=stub-ctx SITE_URL="$SITE" INTERNAL_DOMAIN_V=p09.internal \
           TOCKMOX_P09_OFFSITE_SCRUB="$OFF" PATH="${BIN}:${PATH}"
    bash "$STEPSH" ) > "${TMP}/out-$1" 2>&1
  printf '%s' "$?" > "${TMP}/rc-$1"
}

# 3: a forced FAIL. Two Applications land in tockmox-data, one in longhorn-system; BAD_NAME is never passed to kubectl.
printf 'BAD_NAME x y\ntockmox-data Synced Progressing\ntockmox-data-jobs Synced Degraded\ntockmox-storage OutOfSync Degraded\n' > "${SB}/bar.out"
run_step fail
out="$(cat "${TMP}/out-fail")"; diag="$(grep '^DIAG: ' "${TMP}/out-fail")"
[ "$(cat "${TMP}/rc-fail")" = 0 ] && [ -f "${TMP}/state-fail/S17-watch-waves.done" ] \
  && ok "fail: the step ends and marks itself done" || bad "fail: the step ends and marks itself done" "rc=$(cat "${TMP}/rc-fail") $(tail -3 "${TMP}/out-fail")"
rows="$(grep -c . "${TMP}/state-fail/verdicts.tsv" 2>/dev/null)"
[ "$rows" = 1 ] && grep -F 'not clean after' "${TMP}/state-fail/verdicts.tsv" >/dev/null \
  && ok "fail: the step records its one FAIL row and no other (the block adds no verdict)" || bad "fail: one FAIL row and no other" "$(cat "${TMP}/state-fail/verdicts.tsv" 2>/dev/null)"
has "$out" "NOTE:     S17: not ready, Argo CD says: tockmox-storage OutOfSync/Degraded" \
  && ok "fail: Argo CD's note is still written" || bad "fail: Argo CD's note is still written" "$(grep NOTE "${TMP}/out-fail")"
for want in "DIAG: longhorn-system: Application tockmox-storage deploys here" \
            "DIAG: longhorn-system: longhorn-manager-abc  0/1     ImagePullBackOff" \
            "DIAG: longhorn-system: No resources found in longhorn-system namespace." \
            "DIAG: longhorn-system: pod longhorn-manager-abc (Pending): container manager, image ${IMG}: waiting ImagePullBackOff" \
            "DIAG: longhorn-system: LAST SEEN   TYPE      REASON" \
            "DIAG: tockmox-data: Application tockmox-data deploys here" \
            "DIAG: tockmox-data: tockmox-pg-1   Pending                                      longhorn" \
            "DIAG: tockmox-data: pod tockmox-pg-1 (Pending): PodScheduled False Unschedulable: 0/1 nodes are available: pod has unbound immediate PersistentVolumeClaims." \
            "DIAG: tockmox-data: Application tockmox-data-jobs deploys here too (above)"; do
  has "$diag" "$want" && ok "fail: DIAG names: ${want:0:100}" || bad "fail: DIAG names: ${want}" "$(printf '%s\n' "$diag" | head -20)"
done
[ "$(printf '%s\n' "$diag" | grep -c 'deploys here$')" = 2 ] \
  && ok "fail: a namespace two Applications share is read once" || bad "fail: a namespace two Applications share is read once" "$(printf '%s\n' "$diag" | grep 'deploys here')"
ev="$(printf '%s\n' "$diag" | grep -c 'event-[0-9]*:')"
has "$diag" "event-60:" && ! has "$diag" "event-11:" && [ "$ev" = 49 ] \
  && ok "fail: only the last 50 events are kept (49 pull failures and the newest line)" || bad "fail: only the last 50 events are kept" "${ev} pull-failure events"
has "$out" "site-host.example" || has "$out" "$OFF" \
  && bad "fail: the site remote and the off-site host are scrubbed" "$(grep -E 'site-host|offsite-host' "${TMP}/out-fail" | head -3)" \
  || { has "$diag" "reading <site repository> via <off-site host>" && ok "fail: the site remote and the off-site host are scrubbed" \
       || bad "fail: the site remote and the off-site host are scrubbed" "$(grep 'reading' "${TMP}/out-fail")"; }
long="$(printf '%s\n' "$diag" | awk 'length > 400' | grep -c .)"
per="$(printf '%s\n' "$diag" | awk -F': ' '{print $2}' | sort | uniq -c | awk '$1 > 200' | grep -c .)"
[ "$long" = 0 ] && [ "$per" = 0 ] && ok "fail: no DIAG line over 400 characters, no namespace over 200 lines" || bad "fail: bounds" "long=${long} over-cap=${per}"
grep -F BAD_NAME "${SB}/calls.log" >/dev/null && bad "fail: a name that is not an Application name is never passed to kubectl" "$(grep BAD_NAME "${SB}/calls.log")" \
  || ok "fail: a name that is not an Application name is never passed to kubectl"

# 4
calls="$(cat "${SB}/calls.log")"
if [ -n "$calls" ] && ! printf '%s\n' "$calls" | grep -vE -- '^--context=stub-ctx( --request-timeout=20s)? -n [a-z0-9-]+ (get|logs) ' >/dev/null; then
  ok "fail: every kubectl call names its cluster and only reads ($(printf '%s\n' "$calls" | grep -c .) calls)"
else bad "fail: every kubectl call names its cluster and only reads" "$(printf '%s\n' "$calls" | grep -vE -- '^--context=stub-ctx( --request-timeout=20s)? -n [a-z0-9-]+ (get|logs) ' | head -3)"; fi
for want in "-n longhorn-system get pods -o wide" "-n longhorn-system get pvc" "-n longhorn-system get events --sort-by=.metadata.creationTimestamp" "-n tockmox-data get pods -o json"; do
  has "$calls" "$want" && ok "fail: reads ${want}" || bad "fail: reads ${want}" "$(printf '%s\n' "$calls" | head -12)"
done

# 5: a PASS. The bar has been clean for over three minutes.
: > "${SB}/bar.out"
run_step pass
out="$(cat "${TMP}/out-pass")"
grep -F 'clean twice' "${TMP}/state-pass/verdicts.tsv" >/dev/null 2>&1 && [ "$(grep -c . "${TMP}/state-pass/verdicts.tsv")" = 1 ] \
  && ok "pass: the step records the clean-twice row" || bad "pass: the step records the clean-twice row" "$(cat "${TMP}/state-pass/verdicts.tsv" 2>/dev/null) $(tail -3 "${TMP}/out-pass")"
grep '^DIAG: ' "${TMP}/out-pass" >/dev/null && bad "pass: no DIAG line is written" "$(grep '^DIAG: ' "${TMP}/out-pass" | head -3)" \
  || ok "pass: no DIAG line is written"
grep -E ' get (pods|pvc|events)' "${SB}/calls.log" >/dev/null && bad "pass: no pod, claim or event is read" "$(cat "${SB}/calls.log")" \
  || ok "pass: no pod, claim or event is read"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

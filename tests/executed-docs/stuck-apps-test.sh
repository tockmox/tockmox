#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for lib/p09-stuck-apps.py, what P09 notes when the readiness bar times out: each Application the bar
# lists, with Argo CD's own words for why. No cluster: the input is a fixture of `kubectl get applications -o json`.
#
#   1. a clean list (every Application Synced and Healthy, site-apps in any state) prints "none"
#   2. a stuck Application prints its sync and health, the last operation's phase and message, the resource the
#      sync failed on, its conditions, and its resources that are not Synced or not Healthy; a Synced and Healthy
#      Application beside it is not printed
#   3. more than five resources not ready prints five and "and N more"; a line is cut at 600 characters
#   4. --scrub takes the site repository's URL and its host out of every line
#   5. input that is not a list of Applications prints "unreadable: ...", exits 0, and is never "none"
#   6. P09 runs it in the bar's failing branch, with its cluster named and the off-site scrub after it
#
#   ./tests/executed-docs/stuck-apps-test.sh
#   STUCK=/path/to/p09-stuck-apps.py ./tests/executed-docs/stuck-apps-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # case 6 matches P09's own text, dollar signs and all
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STUCK="${STUCK:-${HERE}/lib/p09-stuck-apps.py}"
P09="${P09:-${HERE}/paths/P09-install-md-end-to-end.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
run() { python3 -I "$STUCK" "$@"; }

SITE="git://site-host.example:30999/site.git"
cat > "${TMP}/clean.json" <<'EOF'
{"kind":"List","items":[
 {"metadata":{"name":"tockmox-root"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
 {"metadata":{"name":"site-apps"},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Missing"}}}
]}
EOF
cat > "${TMP}/stuck.json" <<EOF
{"kind":"List","items":[
 {"metadata":{"name":"tockmox-policy"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
 {"metadata":{"name":"tockmox-ai"},"status":{
   "sync":{"status":"OutOfSync"},"health":{"status":"Degraded"},
   "operationState":{"phase":"Failed","message":"one or more objects failed to apply, reason: failed calling webhook",
     "syncResult":{"resources":[
       {"kind":"ConfigMap","name":"fine","status":"Synced"},
       {"kind":"Cluster","name":"tockmox-litellm-db","status":"SyncFailed","message":"failed calling webhook \"mcluster.cnpg.io\": connection refused"}]}},
   "conditions":[{"type":"SyncError","message":"Failed sync attempt to abc123 reading ${SITE}: one or more objects failed to apply"}],
   "resources":[
     {"kind":"Service","name":"tockmox-ai-litellm","status":"Synced","health":{"status":"Healthy"}},
     {"kind":"ConfigMap","name":"tockmox-ai-litellm-config","status":"Synced"},
     {"kind":"Cluster","name":"tockmox-litellm-db","status":"OutOfSync","health":{"status":"Missing"}},
     {"kind":"Deployment","name":"tockmox-ai-litellm","status":"Synced","health":{"status":"Degraded","message":"Deployment \"tockmox-ai-litellm\" exceeded its progress deadline"}}]}}
]}
EOF

# 1
out="$(run < "${TMP}/clean.json")"
[ "$out" = "none" ] && ok "a clean list prints none (site-apps excluded, as the bar excludes it)" || bad "a clean list prints none" "$out"

# 2
out="$(run < "${TMP}/stuck.json")"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && ok "only the stuck Application is printed" || bad "only the stuck Application is printed" "$out"
case "$out" in "tockmox-ai OutOfSync/Degraded; operation Failed: one or more objects failed to apply"*) ok "the line opens with sync/health and the operation's phase and message" ;;
  *) bad "the line opens with sync/health and the operation's phase and message" "$out" ;; esac
for want in 'failed: Cluster/tockmox-litellm-db SyncFailed/- failed calling webhook "mcluster.cnpg.io": connection refused' \
            'SyncError: Failed sync attempt' \
            'not ready: Cluster/tockmox-litellm-db OutOfSync/Missing' \
            'not ready: Deployment/tockmox-ai-litellm Synced/Degraded Deployment "tockmox-ai-litellm" exceeded its progress deadline'; do
  printf '%s' "$out" | grep -F -- "$want" >/dev/null && ok "names: ${want:0:90}" || bad "names: ${want}" "$out"
done
printf '%s' "$out" | grep -E 'ConfigMap/fine|Service/tockmox-ai-litellm|ConfigMap/tockmox-ai-litellm-config' >/dev/null \
  && bad "a resource that is Synced and Healthy (or has no health) is not listed" "$out" \
  || ok "a resource that is Synced and Healthy (or has no health) is not listed"

# 3
python3 - "${TMP}/many.json" <<'PY'
import json, sys
res = [{"kind": "Deployment", "name": "d%d" % i, "status": "Synced", "health": {"status": "Progressing", "message": "x" * 200}} for i in range(8)]
json.dump({"items": [{"metadata": {"name": "tockmox-big"}, "status": {"sync": {"status": "Synced"}, "health": {"status": "Progressing"}, "resources": res}}]}, open(sys.argv[1], "w"))
PY
out="$(run < "${TMP}/many.json")"
[ "${#out}" -le 600 ] && ok "a line is cut at 600 characters" || bad "a line is cut at 600 characters" "${#out} characters"
python3 - "${TMP}/many2.json" <<'PY'
import json, sys
res = [{"kind": "Deployment", "name": "d%d" % i, "status": "Synced", "health": {"status": "Progressing"}} for i in range(8)]
json.dump({"items": [{"metadata": {"name": "tockmox-big"}, "status": {"sync": {"status": "Synced"}, "health": {"status": "Progressing"}, "resources": res}}]}, open(sys.argv[1], "w"))
PY
out="$(run < "${TMP}/many2.json")"
[ "$(printf '%s' "$out" | grep -o 'not ready: ' | wc -l | tr -d ' ')" = 5 ] && printf '%s' "$out" | grep -F 'and 3 more' >/dev/null \
  && ok "five resources not ready are named, then 'and N more'" || bad "five resources not ready are named, then 'and N more'" "$out"

# 4
out="$(run --scrub "$SITE" < "${TMP}/stuck.json")"
printf '%s' "$out" | grep -Fi 'site-host.example' >/dev/null && bad "--scrub takes the site repository and its host out" "$out" \
  || { printf '%s' "$out" | grep -F 'reading <site repository>' >/dev/null && ok "--scrub takes the site repository and its host out" \
       || bad "--scrub takes the site repository and its host out" "$out"; }
out2="$(run --scrub "" < "${TMP}/stuck.json")"
[ "$out2" = "$(run < "${TMP}/stuck.json")" ] && ok "an empty --scrub changes nothing" || bad "an empty --scrub changes nothing" "$out2"

# 5
for input in '' 'not json' '{"kind":"Status","message":"forbidden"}' '[]'; do
  out="$(printf '%s' "$input" | run)"; rc=$?
  case "$out" in "unreadable: "*) [ "$rc" = 0 ] && ok "unreadable input (${input:-empty}) says so and exits 0" \
                    || bad "unreadable input exits 0" "rc=${rc}" ;;
    *) bad "unreadable input (${input:-empty}) is never none" "$out" ;; esac
done

# 6
blk="$(awk '/readiness bar: prints nothing, and nothing again at least three minutes later/ && /not clean after/ {f=1} f {print} f && /^    fi$/ {exit}' "$P09")"
printf '%s' "$blk" | grep -F 'kubectl --context="$KUBE_CONTEXT" -n argocd get applications -o json' >/dev/null \
  && printf '%s' "$blk" | grep -F 'p09-stuck-apps.py" --scrub "${SITE_URL}" | offsite_scrub' >/dev/null \
  && ok "P09 notes it in the bar's failing branch, its cluster named, both scrubs applied" \
  || bad "P09 notes it in the bar's failing branch, its cluster named, both scrubs applied" "$(printf '%s' "$blk" | head -12)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

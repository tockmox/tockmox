#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh after forge-restore-tests.sh and forge-dump-tests.sh, whose helpers
# it uses (rs_case, rs_run, dp_start, dp_run, dp_bucket). Groups K1-K7: the rebuild
# drill.
#
#   tockmox-install.sh rebuild-drill   install/forge-restore.sh drill: proves the three
#       refusals on the real copy and kit (stale named, corrupt refused, wrong passphrase
#       stops), runs the rebuild, and writes its record to the off-site destination.
#   TASK=drill-check                   install/forge-offsite-copy.sh, the daily CronJob:
#       reads that record and fails when the drill failed, is a quarter old, or is
#       missing on a site older than a quarter.
#
# HERMETIC. The copy and the kit are REAL (rs_case), the bucket is the loopback
# stand-in (lib/forge-stub.py), and the probes are the real script's real dry runs.
# The one stand-in is the rebuild itself (TOCKMOX_DRILL_REBUILD): it installs a forge
# and an Argo CD root on a cluster, which the lab run proves. Every assertion reads what
# the drill LEFT in the bucket, or the shims' call log, not an exit code alone.

KD_PATH="$RS_PATH"
KR=""; KS=""
# kd_start NAME: a real copy and kit (rs_case, in KR) and a stand-in bucket (dp_start, in
# KS). D, which both helpers use, is left pointing at KR; kd_check runs drill-check in KS.
kd_start() {
  rs_case "$1"; KR="$D"
  dp_start "$1-stub"; KS="$D"
  D="$KR"
}
kd_check() { D="$KS"; dp_run "$@"; D="$KR"; }

# kd_upload: put rs_case's bundle in the stand-in's bucket the way the off-site job
# does: bundles/<stamp>-<sha12>.bundle, its .sha256, and the pointer `latest`.
kd_upload() {
  local main sum key
  main="$(PATH="$KD_PATH" git -C "$D/site" rev-parse HEAD)"
  sum="$(rs_sha "$D/media/site.bundle")"
  key="lab/bundles/20261105T120000Z-${main:0:12}.bundle"
  curl -s -o /dev/null -X PUT --upload-file "$D/media/site.bundle" "http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/$key"
  curl -s -o /dev/null -X PUT --upload-file "$D/media/site.bundle.sha256" "http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/$key.sha256"
  printf 'format tockmox-site-copy v1\ncommit %s\nbundle %s\nsha256 %s\ncreated 20261105T120000Z\nrepository tockmox/site\n' \
    "$main" "$key" "$sum" > "$D/out/latest"
  curl -s -o /dev/null -X PUT --upload-file "$D/out/latest" "http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/lab/latest"
  printf 'AK\nSK\n' > "$D/inputs/s3.creds"
  KD_MAIN="$main"
}
kd_bucket() { echo MODE=bucket S3_ENDPOINT="http://127.0.0.1:$DP_PORT/s3" S3_BUCKET=tockmox-bkt S3_PREFIX=lab; }
kd_offsite() { echo --offsite-s3-endpoint "http://127.0.0.1:$DP_PORT" --offsite-s3-bucket tockmox-bkt --offsite-s3-prefix lab \
  --offsite-s3-credentials inputs/s3.creds; }
kd_record() { curl -s "http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/lab/drill/latest"; }
kd_field() { kd_record | awk -v f="$1" '$1==f{ sub(/^[^ ]+ /, ""); print; exit }'; }
# kd_put_record LINES...: a record written straight into the bucket, for drill-check's cases
kd_put_record() {
  printf '%s\n' "$@" > "$D/out/rec"
  curl -s -o /dev/null -X PUT --upload-file "$D/out/rec" "http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/lab/drill/latest"
}
kd_stamp_days_ago() { date -u -d "@$(( $(date +%s) - $1 * 86400 ))" +%Y%m%dT%H%M%SZ 2>/dev/null \
  || date -u -r "$(( $(date +%s) - $1 * 86400 ))" +%Y%m%dT%H%M%SZ; }

# ---------------------------------------------------------------------- K1
path_begin "K1" "a drill on a good copy and kit proves all three refusals, rebuilds, and writes a pass record"
kd_start k1
kd_upload
# shellcheck disable=SC2046
TOCKMOX_DRILL_REBUILD='echo rebuilt' rs_run rebuild-drill --restore-from offsite $(kd_offsite) "${RS_KIT[@]}" \
  --context lab-throwaway --drill-wait-minutes 0
assert_artifact "the drill exits 0 and says it passed" \
  "echo $RS_STATUS; grep -c 'rebuild drill PASSED' '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "the record in the bucket says pass, names the copy's commit, and lists the three refusals" \
  "kd_field format; kd_field result; [ \"\$(kd_field copy-commit)\" = '$KD_MAIN' ] && echo commit-matches; kd_field refusals" \
  "$(printf 'tockmox-rebuild-drill v1\npass\ncommit-matches\nstale,corrupt,passphrase')"
assert_artifact "a dated copy of the record sits beside drill/latest" \
  "curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/lab/drill/'\"\$(kd_field created)\"" "200"
assert_artifact "every probe was a dry run: no kubectl or helm call at all" "rs_cluster_calls" "0"

# ---------------------------------------------------------------------- K2
path_begin "K2" "the daily drill-check reads K1's record and passes"
# shellcheck disable=SC2046
kd_check TASK=drill-check $(kd_bucket)
assert_artifact "drill-check exits 0 and names the drill's refusals" \
  "echo $DP_STATUS; grep -c 'refusals proven: stale,corrupt,passphrase' '$KS/out/stdout'" "$(printf '0\n1')"
dp_stop

# ---------------------------------------------------------------------- K3
path_begin "K3" "a rebuild that fails still leaves a record, and it says fail and why"
kd_start k3
kd_upload
# shellcheck disable=SC2046
TOCKMOX_DRILL_REBUILD="echo '  ✗ the forge never answered' >&2; exit 3" rs_run rebuild-drill --restore-from offsite $(kd_offsite) \
  "${RS_KIT[@]}" --context lab-throwaway --drill-wait-minutes 0
assert_artifact "the drill exits 1" "echo $RS_STATUS" "1"
assert_artifact "the record says fail, with the rebuild's exit and its first error line" \
  "kd_field result; kd_field reason" "$(printf 'fail\nthe rebuild command failed (exit 3): the forge never answered')"
# shellcheck disable=SC2046
kd_check TASK=drill-check $(kd_bucket)
assert_artifact "and the daily drill-check fails on it, quoting the reason" \
  "echo $DP_STATUS; grep -c 'FAILED: the rebuild command failed (exit 3)' '$KS/out/stderr'" "$(printf '1\n1')"
dp_stop

# ---------------------------------------------------------------------- K4
path_begin "K4" "a drill refuses a copy on media, a missing --context and --dry-run, before it touches anything"
kd_start k4
rs_run rebuild-drill --restore-from file:media/site.bundle "${RS_KIT[@]}" --context lab-throwaway
assert_artifact "a file copy is refused: the drill reads the real latest off-site copy" \
  "echo $RS_STATUS; rs_err | grep -c 'a rebuild drill reads the real latest off-site copy'" "$(printf '1\n1')"
kd_upload
# shellcheck disable=SC2046
rs_run rebuild-drill --restore-from offsite $(kd_offsite) "${RS_KIT[@]}"
assert_artifact "no --context is refused, naming the throwaway cluster" \
  "echo $RS_STATUS; rs_err | grep -c 'a rebuild drill runs on a THROWAWAY cluster'" "$(printf '1\n1')"
# shellcheck disable=SC2046
rs_run rebuild-drill --restore-from offsite $(kd_offsite) "${RS_KIT[@]}" --context lab-throwaway --dry-run
assert_artifact "--dry-run with a drill is refused" \
  "echo $RS_STATUS; rs_err | grep -c -- '--dry-run and a drill do not go together'" "$(printf '1\n1')"
assert_artifact "and none of the three wrote a record" \
  "curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/lab/drill/latest'" "404"
assert_artifact "... or called kubectl or helm" "rs_cluster_calls" "0"
dp_stop

# ---------------------------------------------------------------------- K5
path_begin "K5" "a copy whose bundle is corrupt fails the drill at its first check, and the record says so"
kd_start k5
kd_upload
printf 'x' >> "$D/media/site.bundle"
curl -s -o /dev/null -X PUT --upload-file "$D/media/site.bundle" \
  "http://127.0.0.1:$DP_PORT/s3/tockmox-bkt/lab/bundles/20261105T120000Z-${KD_MAIN:0:12}.bundle"
# shellcheck disable=SC2046
TOCKMOX_DRILL_REBUILD='echo rebuilt' rs_run rebuild-drill --restore-from offsite $(kd_offsite) "${RS_KIT[@]}" \
  --context lab-throwaway --drill-wait-minutes 0
assert_artifact "the drill exits 1 and never reaches the rebuild" \
  "echo $RS_STATUS; grep -c 'The rebuild, on' '$D/out/stdout' || true" "$(printf '1\n0')"
assert_artifact "the record says fail at the copy-and-kit check" \
  "kd_field result; kd_field reason | grep -c '^the copy-and-kit check did not behave'" "$(printf 'fail\n1')"
dp_stop

# ---------------------------------------------------------------------- K6
path_begin "K6" "drill-check: a quarter-old pass, a missing record and a bad record each fail; a young site is given time"
dp_start k6
kd_put_record "format tockmox-rebuild-drill v1" "result pass" "created $(kd_stamp_days_ago 100)" \
  "copy-commit 0123456789012345678901234567890123456789" "seconds 900" "refusals stale,corrupt,passphrase"
# shellcheck disable=SC2046
dp_run TASK=drill-check $(kd_bucket)
assert_artifact "a pass 100 days old is overdue" \
  "echo $DP_STATUS; grep -c '100 days ago: overdue' '$D/out/stderr'" "$(printf '1\n1')"
# shellcheck disable=SC2046
dp_run TASK=drill-check DRILL_MAX_DAYS=120 $(kd_bucket)
assert_artifact "... and is not overdue when a drill is due every 120 days" "echo $DP_STATUS" "0"
kd_put_record "format tockmox-rebuild-drill v1" "result maybe" "created $(kd_stamp_days_ago 1)"
# shellcheck disable=SC2046
dp_run TASK=drill-check $(kd_bucket)
assert_artifact "a result that is neither pass nor fail is refused" \
  "echo $DP_STATUS; grep -c \"result 'maybe' is neither pass nor fail\" '$D/out/stderr'" "$(printf '1\n1')"
kd_put_record "format tockmox-rebuild-drill v1" "result pass" "created yesterday"
# shellcheck disable=SC2046
dp_run TASK=drill-check $(kd_bucket)
assert_artifact "a date that is not a stamp is refused" \
  "echo $DP_STATUS; grep -c \"created 'yesterday' is not a YYYYmmddTHHMMSSZ stamp\" '$D/out/stderr'" "$(printf '1\n1')"
dp_stop
dp_start k6b
# shellcheck disable=SC2046
dp_run TASK=drill-check $(kd_bucket)
assert_artifact "no record on a site with no install date fails, naming the drill to run" \
  "echo $DP_STATUS; grep -c 'no rebuild drill on record' '$D/out/stderr'" "$(printf '1\n1')"
# shellcheck disable=SC2046
dp_run TASK=drill-check DRILL_SINCE="$(kd_stamp_days_ago 10)" $(kd_bucket)
assert_artifact "no record on a site installed 10 days ago passes and says when the first is due" \
  "echo $DP_STATUS; grep -cE 'the first is due within 8[12] days' '$D/out/stdout'" "$(printf '0\n1')"
# shellcheck disable=SC2046
dp_run TASK=drill-check DRILL_SINCE="$(kd_stamp_days_ago 95)" $(kd_bucket)
assert_artifact "no record on a site installed 95 days ago fails" "echo $DP_STATUS" "1"
dp_run TASK=drill-check MODE=git GIT_REMOTE_URL="http://127.0.0.1:$DP_PORT/remote/site.git"
assert_artifact "a git remote with no forge-drill branch has no record" \
  "echo $DP_STATUS; grep -c 'has no forge-drill branch' '$D/out/stderr'" "$(printf '1\n1')"
# shellcheck disable=SC2046
dp_run TASK=drill-check DRILL_MAX_DAYS=0 $(kd_bucket)
assert_artifact "DRILL_MAX_DAYS 0 is a misconfiguration, exit 2" "echo $DP_STATUS" "2"
dp_stop

# ---------------------------------------------------------------------- K7
path_begin "K7" "drill-check on a git remote reads drill/latest from the forge-drill branch"
dp_start k7
(
  export PATH="$KD_PATH"
  W="$D/k7work"; git init -q "$W"; git -C "$W" checkout -q --orphan forge-drill; mkdir -p "$W/drill"
  printf 'format tockmox-rebuild-drill v1\nresult pass\ncreated %s\ncopy-commit 0123456789012345678901234567890123456789\nseconds 600\nrefusals stale,corrupt,passphrase\n' \
    "$(kd_stamp_days_ago 3)" > "$W/drill/latest"
  git -C "$W" add drill && git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q -m drill
  git -C "$W" push -q "$D/root/remote/site.git" forge-drill
)
dp_run TASK=drill-check MODE=git GIT_REMOTE_URL="http://127.0.0.1:$DP_PORT/remote/site.git"
assert_artifact "a pass three days old on forge-drill passes" \
  "echo $DP_STATUS; grep -c 'passed .* (3 days ago)' '$D/out/stdout'" "$(printf '0\n1')"
dp_stop

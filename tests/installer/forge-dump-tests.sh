#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups D1-D6: the nightly forge dump, TASK=dump of
# install/forge-offsite-copy.sh, which the CronJob <release>-dump runs at 21:15.
#
# HERMETIC, and the script under test is REAL: it runs in busybox's sh when there is
# one (the forge image's shell is busybox), with the real curl, git, tar and sha256sum,
# against a loopback stand-in (lib/forge-stub.py) that plays the forge's REST API, an
# S3 bucket and git over HTTP. What the stub does not prove is that Forgejo answers
# with these field names; the lab run does (it runs the same script against the
# pinned Forgejo and compares counts with what the forge itself lists).
#
# Every assertion reads what the dump LEFT: the pointer, the object it names, that
# object's checksum, the manifest inside it, the commits on the remote's forge-dump
# branch. None reads an exit code alone.

DP="$WORK/dump"; mkdir -p "$DP"
# run.sh puts a failing `git` stub first on PATH; the dump needs the real one.
DP_PATH="${PATH//$STUB:/}"
DP_COPY="$REPO_ROOT/install/forge-offsite-copy.sh"
DP_STUB="$HERE/lib/forge-stub.py"
DP_SH="sh"
if command -v busybox >/dev/null 2>&1; then DP_SH="busybox sh"; fi
DP_PID=""
DP_PORT=""
DP_STATUS=0

path_begin "D0" "the dump's prerequisites exist, so a missing tool fails here and not as a vague D-case failure"
assert_artifact "curl can sign S3 requests (--aws-sigv4)" \
  "PATH='$DP_PATH' curl --help all 2>/dev/null | grep -c -- '--aws-sigv4'" "1"
assert_artifact "git http-backend exists, for the stand-in's git role" \
  "test -x \"\$(PATH='$DP_PATH' git --exec-path)/git-http-backend\" && echo yes || echo no" "yes"

# dp_start NAME [ENV=VAL ...]: a fresh case directory and a stand-in server; sets D, DP_PORT, DP_PID.
dp_start() {
  D="$DP/$1"; shift
  rm -rf "$D"; mkdir -p "$D/root/tockmox" "$D/root/remote" "$D/sec" "$D/out"
  (
    export PATH="$DP_PATH"
    git init -q -b main "$D/site"
    cd "$D/site" && echo a > a.yaml && git add . \
      && git -c user.name=t -c user.email=t@example.invalid commit -q -m "site"
    git clone -q --bare "$D/site" "$D/root/tockmox/site.git"
    git init -q --bare "$D/root/remote/site.git"
    git -C "$D/root/remote/site.git" config http.receivepack true
  )
  printf 'bot\n' > "$D/sec/forge-username"; printf 'tok\n' > "$D/sec/forge-token"
  printf 'AK\n' > "$D/sec/s3-access-key-id"; printf 'SK\n' > "$D/sec/s3-secret-access-key"
  printf 'gu\n' > "$D/sec/git-username"; printf 'gp\n' > "$D/sec/git-password"
  rm -f "$D/port"
  env PATH="$DP_PATH" "$@" python3 "$DP_STUB" "$D/root" "$D/port" >/dev/null 2>&1 &
  DP_PID=$!
  local i=0
  while [ ! -s "$D/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  DP_PORT="$(cat "$D/port" 2>/dev/null || true)"
}
dp_stop() { kill "$DP_PID" 2>/dev/null || true; wait "$DP_PID" 2>/dev/null || true; }

# dp_run [ENV=VAL ...]: the script, as the CronJob runs it.
dp_run() {
  set +e
  # shellcheck disable=SC2086 # DP_SH is "busybox sh" or "sh"
  env PATH="$DP_PATH" SECRETS_DIR="$D/sec" FORGE_URL="http://127.0.0.1:$DP_PORT" REPO=tockmox/site "$@" \
    $DP_SH "$DP_COPY" >"$D/out/stdout" 2>"$D/out/stderr"
  DP_STATUS=$?
  set -e
}
dp_bucket() { echo MODE=bucket S3_ENDPOINT="http://127.0.0.1:$DP_PORT/s3" S3_BUCKET=b S3_PREFIX=lab; }
dp_get() { curl -s -o "$2" -w '%{http_code}' "http://127.0.0.1:$DP_PORT/s3/b/lab/$1"; }
# dp_pointer_field FIELD: a field of the latest-dump pointer
dp_pointer_field() { dp_get latest-dump "$D/out/pointer" >/dev/null; awk -v f="$1" '$1==f{print $2; exit}' "$D/out/pointer"; }
# dp_dump_check: the object the pointer names, fetched, checked against the pointer's sha256, and listed
dp_dump_check() {
  local key sum; key="$(dp_pointer_field dump)"; sum="$(dp_pointer_field sha256)"
  curl -s -o "$D/out/dump.tgz" "http://127.0.0.1:$DP_PORT/s3/b/${key}"
  [ "$(sha256sum "$D/out/dump.tgz" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$D/out/dump.tgz" | cut -d' ' -f1)" = "$sum" ] && echo sum-ok || echo sum-BAD
  tar -xzOf "$D/out/dump.tgz" ./MANIFEST
}

# ---------------------------------------------------------------------- D1
path_begin "D1" "a dump to a bucket leaves a pointer, a checksummed object and a manifest that counts what it holds"
dp_start d1
# shellcheck disable=SC2046
dp_run TASK=dump $(dp_bucket)
assert_artifact "the job exits 0 and says what it dumped" \
  "echo $DP_STATUS; cut -c1-71 '$D/out/stdout'" "$(printf '0\ndumped: 3 pull requests, 3 reviews, 3 review comments, 3 issue comments')"
assert_artifact "the pointer's object matches the pointer's sha256, and its manifest counts the same" \
  "dp_dump_check | grep -E '^(sum-|pull-requests|reviews|review-comments|issue-comments|format)'" \
  "$(printf 'sum-ok\nformat tockmox-forge-dump v1\npull-requests 3\nreviews 3\nreview-comments 3\nissue-comments 3')"
assert_artifact "the manifest names the forge's main at dump time" \
  "dp_dump_check | awk '\$1==\"forge-main\"{print (\$2==\"$(PATH="$DP_PATH" git -C "$D/site" rev-parse HEAD)\") ? \"matches\" : \"differs\"}'" "matches"
assert_artifact "the bundle pointer is untouched: a dump never writes the copy's keys" \
  "dp_get latest '$D/out/none'" "404"

# ---------------------------------------------------------------------- D2
path_begin "D2" "a second dump is a new object and the first is still there; the pointer moves, nothing is replaced"
first="$(dp_pointer_field dump)"
sleep 1
# shellcheck disable=SC2046
dp_run TASK=dump $(dp_bucket)
second="$(dp_pointer_field dump)"
assert_artifact "the pointer names a different object after a second dump" \
  "[ '$first' != '$second' ] && echo moved || echo SAME" "moved"
assert_artifact "the first dump's object is still readable" \
  "curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:$DP_PORT/s3/b/$first'" "200"
dp_stop

# ---------------------------------------------------------------------- D3
path_begin "D3" "a dump to a git remote is a new commit on forge-dump, pushed without force, and main is not touched"
dp_start d3
dp_run TASK=dump MODE=git GIT_REMOTE_URL="http://127.0.0.1:$DP_PORT/remote/site.git"
sleep 1
dp_run TASK=dump MODE=git GIT_REMOTE_URL="http://127.0.0.1:$DP_PORT/remote/site.git"
R="$D/root/remote/site.git"
assert_artifact "two dumps are two commits on the remote's forge-dump branch" \
  "echo $DP_STATUS; PATH='$DP_PATH' git -C '$R' rev-list --count forge-dump" "$(printf '0\n2')"
assert_artifact "the branch carries the manifest and the API's pages" \
  "PATH='$DP_PATH' git -C '$R' ls-tree -r --name-only forge-dump | LC_ALL=C sort | tr '\n' ' '" \
  "dump/MANIFEST dump/issue-comments-1.json dump/pulls-1.json dump/repository.json dump/review-comments-1-10.json dump/review-comments-2-20.json dump/review-comments-3-30.json dump/reviews-1-1.json dump/reviews-2-1.json dump/reviews-3-1.json dump/version.json "
assert_artifact "the dump never creates main on the remote: the push mirror owns it" \
  "PATH='$DP_PATH' git -C '$R' rev-parse --verify -q refs/heads/main >/dev/null && echo HAS-MAIN || echo no-main" "no-main"
dp_stop

# ---------------------------------------------------------------------- D4
path_begin "D4" "a dump that cannot be made whole fails and leaves nothing that reads as a dump"
dp_start d4a FAIL=pulls
# shellcheck disable=SC2046
dp_run TASK=dump $(dp_bucket)
assert_artifact "a forge endpoint that answers 500 fails the job and names the endpoint" \
  "echo $DP_STATUS; grep -c 'forge API /repos/tockmox/site/pulls.*HTTP 500' '$D/out/stderr'" "$(printf '1\n1')"
assert_artifact "and no pointer was written" "dp_get latest-dump '$D/out/none'" "404"
dp_stop
dp_start d4b BADREV=1
# shellcheck disable=SC2046
dp_run TASK=dump $(dp_bucket)
assert_artifact "a review format the dump cannot read fails the job instead of dumping without reviews" \
  "echo $DP_STATUS; grep -c 'review format changed' '$D/out/stderr'" "$(printf '1\n1')"
assert_artifact "and no pointer was written" "dp_get latest-dump '$D/out/none'" "404"
dp_stop
dp_start d4d CORRUPT=1
# shellcheck disable=SC2046
dp_run TASK=dump $(dp_bucket)
assert_artifact "a dump that reads back different from what was uploaded fails the job" \
  "echo $DP_STATUS; grep -c 'dump read-back checksum mismatch' '$D/out/stderr'" "$(printf '1\n1')"
assert_artifact "and the pointer, which is written last, was never written" "dp_get latest-dump '$D/out/none'" "404"
dp_stop
dp_start d4c
dp_run TASK=bogus MODE=git GIT_REMOTE_URL=http://127.0.0.1:1/x.git
assert_artifact "an unknown TASK is a misconfiguration, exit 2" \
  "echo $DP_STATUS; grep -c 'TASK must be copy or dump' '$D/out/stderr'" "$(printf '2\n1')"
dp_stop

# ---------------------------------------------------------------------- D5
path_begin "D5" "with no TASK the script is the copy it always was, and writes no dump"
dp_start d5
# shellcheck disable=SC2046
dp_run $(dp_bucket)
assert_artifact "the default run copies main as a bundle" \
  "echo $DP_STATUS; cut -c1-7 '$D/out/stdout'" "$(printf '0\ncopied:')"
assert_artifact "and writes no dump pointer" "dp_get latest-dump '$D/out/none'" "404"
dp_stop

# ---------------------------------------------------------------------- D6
path_begin "D6" "more pull requests than one page are all dumped"
dp_start d6 PRS=120
# shellcheck disable=SC2046
dp_run TASK=dump $(dp_bucket)
assert_artifact "120 pull requests are 120 pull requests, 120 reviews and their comments (three pages)" \
  "dp_dump_check | grep -E '^(pull-requests|reviews|review-comments|issue-comments)' | tr '\n' ' '" \
  "pull-requests 120 reviews 120 review-comments 120 issue-comments 120 "
dp_stop

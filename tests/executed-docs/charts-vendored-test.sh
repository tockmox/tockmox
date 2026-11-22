#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# install/charts-vendored-tag.sh puts the vendored subchart archives in the commit tockmox.revision names, or refuses.
#
# On 2026-11-21 the air-gap lane served the product tree and 9 of 10 Applications sat at sync Unknown: `.gitignore`
# excludes charts/*/charts/ and *.tgz, so no commit carried the archives tools/helm-deps.sh vendors, and Argo CD went
# to the chart repositories for every subchart under the cut. The helper makes TAG-vendored: the release commit plus
# exactly the archives each layer's Chart.lock names, and nothing else. bootstrap-forge --charts-repo runs it, and so
# does the air-gap lane, so both serve the same commit.
#
# Hermetic: a tiny charts repository built with the real git, no cluster, no network.
#
#   A. an archive a Chart.lock names is missing: refused, naming it and tools/helm-deps.sh, and no tag is made
#   B. every archive present: TAG-vendored is made; its parent is the release commit, it adds exactly the archives
#      (byte for byte) and nothing else, and the release tag does not move
#   C. a second run with the same inputs changes nothing and prints the same line
#   D. archives vendored again (new bytes, as helm package writes on every run): the tag is kept, never moved, and
#      the run says so
#   E. the same release and the same archive bytes in another clone make the same commit, so a forge that already
#      holds the tag from an earlier run compares equal
#   F. a TAG-vendored already in the checkout that lacks an archive (the release commit itself, which is what pushing
#      the release tag served) is refused, naming the archive the served tree lacks; one that changes a file outside
#      charts/*/charts/ is refused too
#   G. a release tag that is itself a vendored tag, or not a tag name, is refused
#   H. --dry-run names the tag and the commit and writes no ref
#
#   ./tests/executed-docs/charts-vendored-test.sh
#   CV_HELPER=/path/to/copy ./tests/executed-docs/charts-vendored-test.sh   another copy, to show it goes red there
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="${CV_HELPER:-${HERE}/../../install/charts-vendored-tag.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

command -v git >/dev/null 2>&1 || { printf 'FAIL git is on PATH\n     this test needs git\n'; exit 1; }
[ -f "$HELPER" ] || { printf 'FAIL the helper exists\n     no file at %s\n' "$HELPER"; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$TMP"

# mk_repo DIR: a charts repository shaped like Tockmox's, tag v9.9.9 on its one commit. tockmox-platform names a
# local and an upstream dependency in its Chart.lock; tockmox-policy names none. Nothing is vendored yet.
mk_repo() {
  local d="$1"
  mkdir -p "$d/charts/tockmox-common" "$d/charts/tockmox-platform" "$d/charts/tockmox-policy"
  printf 'charts/*/charts/\n*.tgz\n' > "$d/.gitignore"
  printf 'apiVersion: v2\nname: tockmox-common\nversion: 0.1.0\n' > "$d/charts/tockmox-common/Chart.yaml"
  printf 'apiVersion: v2\nname: tockmox-platform\nversion: 9.9.9\ndependencies:\n  - name: tockmox-common\n    version: 0.1.0\n    repository: "file://../tockmox-common"\n  - name: upstream\n    version: "1.2.3"\n    repository: "https://charts.example.invalid"\n' \
    > "$d/charts/tockmox-platform/Chart.yaml"
  printf 'dependencies:\n- name: tockmox-common\n  repository: file://../tockmox-common\n  version: 0.1.0\n- name: upstream\n  repository: https://charts.example.invalid\n  version: 1.2.3\ndigest: sha256:0\ngenerated: "2026-11-22T00:00:00Z"\n' \
    > "$d/charts/tockmox-platform/Chart.lock"
  printf 'apiVersion: v2\nname: tockmox-policy\nversion: 9.9.9\n' > "$d/charts/tockmox-policy/Chart.yaml"
  ( cd "$d" && git init -q -b main . && git add -A \
      && git -c user.name=t -c user.email=t@example.com commit -q -m 'release 9.9.9' && git tag v9.9.9 )
}
vendor() {  # DIR [suffix]: the two archives tools/helm-deps.sh would put there
  mkdir -p "$1/charts/tockmox-platform/charts"
  printf 'common-archive%s' "${2:-}" > "$1/charts/tockmox-platform/charts/tockmox-common-0.1.0.tgz"
  printf 'upstream-archive' > "$1/charts/tockmox-platform/charts/upstream-1.2.3.tgz"
}
run() { set +e; OUT="$(bash "$HELPER" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; set -e 2>/dev/null; set +e; }
A1=charts/tockmox-platform/charts/tockmox-common-0.1.0.tgz
A2=charts/tockmox-platform/charts/upstream-1.2.3.tgz

R="$TMP/repo"; mk_repo "$R"
REL="$(git -C "$R" rev-parse 'v9.9.9^{commit}')"

# ------------------------------------------------------------------------------- A
vendor "$R"; rm -f "$R/$A2"
run "$R" v9.9.9
if [ "$RC" -ne 0 ] && grep -qF "$A2" <<<"$ERR" && grep -qF 'tools/helm-deps.sh' <<<"$ERR"; then
  ok "A: a missing archive is refused, naming it and tools/helm-deps.sh"
else bad "A: a missing archive is refused, naming it and tools/helm-deps.sh" "rc=$RC: $(tail -2 <<<"$ERR")"; fi
if git -C "$R" rev-parse -q --verify refs/tags/v9.9.9-vendored >/dev/null; then bad "A: no tag is made" "v9.9.9-vendored exists"
else ok "A: no tag is made"; fi

# ------------------------------------------------------------------------------- B
vendor "$R"
run "$R" v9.9.9
VEN="$(git -C "$R" rev-parse -q --verify 'refs/tags/v9.9.9-vendored^{commit}' 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ -n "$VEN" ] && [ "$OUT" = "v9.9.9-vendored ${VEN} 2" ]; then
  ok "B: v9.9.9-vendored is made, and the run prints the tag, its commit and the archive count"
else bad "B: v9.9.9-vendored is made" "rc=$RC out='$OUT': $(tail -2 <<<"$ERR")"; fi
if [ -n "$VEN" ] && [ "$(git -C "$R" rev-parse "${VEN}^1" 2>/dev/null)" = "$REL" ] \
   && [ "$(git -C "$R" rev-parse 'v9.9.9^{commit}')" = "$REL" ]; then
  ok "B: its parent is the release commit, and the release tag has not moved"
else bad "B: its parent is the release commit, and the release tag has not moved" "vendored ${VEN:-none}, release $REL"; fi
changed="$(git -C "$R" diff-tree -r --name-only "$REL" "${VEN:-$REL}" 2>/dev/null | sort | tr '\n' ' ')"
if [ "$changed" = "$A1 $A2 " ]; then ok "B: it adds exactly the archives the Chart.lock names, and nothing else"
else bad "B: it adds exactly the archives the Chart.lock names" "changed: '${changed}'"; fi
if [ -n "$VEN" ] && [ "$(git -C "$R" show "${VEN}:${A2}" 2>/dev/null)" = upstream-archive ] \
   && [ "$(git -C "$R" show "${VEN}:${A1}" 2>/dev/null)" = common-archive ]; then
  ok "B: the archives are committed byte for byte"
else bad "B: the archives are committed byte for byte" "$(git -C "$R" show "${VEN:-HEAD}:${A2}" 2>&1 | head -1)"; fi
if [ -z "$(git -C "$R" status --porcelain)" ] && [ "$(git -C "$R" rev-parse HEAD)" = "$REL" ]; then
  ok "B: the checkout's HEAD, index and working tree are untouched"
else bad "B: the checkout is untouched" "$(git -C "$R" status --porcelain | head -3)"; fi

# ------------------------------------------------------------------------------- C
FIRST="$OUT"
run "$R" v9.9.9
if [ "$RC" -eq 0 ] && [ "$OUT" = "$FIRST" ] && [ "$(git -C "$R" rev-parse 'v9.9.9-vendored^{commit}')" = "$VEN" ]; then
  ok "C: a second run changes nothing and prints the same line"
else bad "C: a second run changes nothing" "rc=$RC out='$OUT' first='$FIRST'"; fi

# ------------------------------------------------------------------------------- D
vendor "$R" -again
run "$R" v9.9.9
if [ "$RC" -eq 0 ] && [ "$OUT" = "$FIRST" ] && [ "$(git -C "$R" rev-parse 'v9.9.9-vendored^{commit}')" = "$VEN" ] \
   && grep -qi 'kept' <<<"$ERR"; then
  ok "D: archives vendored again do not move the tag, and the run says it kept it"
else bad "D: archives vendored again do not move the tag" "rc=$RC out='$OUT': $(tail -2 <<<"$ERR")"; fi

# ------------------------------------------------------------------------------- E
R2="$TMP/clone"; git clone -q --no-tags "$R" "$R2" && git -C "$R2" fetch -q --no-tags origin 'refs/tags/v9.9.9:refs/tags/v9.9.9'
vendor "$R2"
run "$R2" v9.9.9
if [ "$RC" -eq 0 ] && [ "$OUT" = "$FIRST" ] && grep -q '^charts-vendored-tag: made ' <<<"$ERR"; then ok "E: the same release and archive bytes in another clone make the same commit"
else bad "E: the same inputs make the same commit" "rc=$RC out='$OUT' want '$FIRST': $(tail -2 <<<"$ERR")"; fi

# ------------------------------------------------------------------------------- F
R3="$TMP/old-path"; mk_repo "$R3"; vendor "$R3"
git -C "$R3" tag v9.9.9-vendored v9.9.9
run "$R3" v9.9.9
if [ "$RC" -ne 0 ] && grep -qF "$A1" <<<"$ERR" && grep -qF 'v9.9.9-vendored' <<<"$ERR"; then
  ok "F: a vendored tag whose tree lacks the archives is refused, naming what it lacks"
else bad "F: a vendored tag whose tree lacks the archives is refused" "rc=$RC: $(tail -2 <<<"$ERR")"; fi
R4="$TMP/extra"; mk_repo "$R4"; vendor "$R4"
( cd "$R4" && git checkout -q --detach v9.9.9 && git add -f "$A1" "$A2" && printf 'changed\n' >> charts/tockmox-policy/Chart.yaml \
    && git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m 'not only archives' \
    && git tag v9.9.9-vendored && git checkout -q main )
run "$R4" v9.9.9
if [ "$RC" -ne 0 ] && grep -qF 'charts/tockmox-policy/Chart.yaml' <<<"$ERR"; then
  ok "F: a vendored tag that changes a file outside charts/*/charts/ is refused, naming it"
else bad "F: a vendored tag that changes another file is refused" "rc=$RC: $(tail -2 <<<"$ERR")"; fi

# ------------------------------------------------------------------------------- G
run "$R" v9.9.9-vendored
g1=$RC; g1e="$ERR"
run "$R" 'v9 9'
if [ "$g1" -ne 0 ] && grep -qF 'release tag' <<<"$g1e" && [ "$RC" -ne 0 ]; then
  ok "G: a vendored tag given as the release tag, and a name that is not a tag, are refused"
else bad "G: a vendored tag given as the release tag is refused" "rc=$g1: $(tail -1 <<<"$g1e"); rc=$RC"; fi

# ------------------------------------------------------------------------------- H
R5="$TMP/dry"; git clone -q --no-tags "$R" "$R5" && git -C "$R5" fetch -q --no-tags origin 'refs/tags/v9.9.9:refs/tags/v9.9.9'
vendor "$R5"
run --dry-run "$R5" v9.9.9
if [ "$RC" -eq 0 ] && [ "$OUT" = "$FIRST" ] && ! git -C "$R5" rev-parse -q --verify refs/tags/v9.9.9-vendored >/dev/null; then
  ok "H: --dry-run names the tag and the commit it would make, and writes no ref"
else bad "H: --dry-run writes no ref" "rc=$RC out='$OUT' want '$FIRST'"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

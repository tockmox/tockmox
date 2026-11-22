#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# charts-vendored-tag.sh: put the vendored subchart archives in the commit tockmox.revision names.
#
#   ./install/charts-vendored-tag.sh [--dry-run] DIR TAG
#
# DIR is a git checkout of the Tockmox charts repository in which tools/helm-deps.sh has vendored the subchart
# archives; TAG is the release tag in it. This makes the tag TAG-vendored in DIR and prints one line on stdout:
#
#   TAG-vendored COMMIT N        (N: how many archives the commit carries)
#
# bootstrap-forge --charts-repo runs it and pushes that tag to the built-in forge; an operator with their own git
# server runs it and pushes the tag there (docs/deployment/airgap.md, steps 3 and 5). The air-gap lane serves the
# same commit (tests/executed-docs/airgap-lane.sh).
#
# WHY. Argo CD renders each layer from the commit tockmox.revision names. `.gitignore` excludes charts/*/charts/ and
# *.tgz, so no release commit carries the archives, and Argo CD's repo server fetches every subchart from its chart
# repository on render. Inside a boundary with no route out that fails: on 2026-11-21 the air-gap lane showed 9 of 10
# Applications at sync Unknown and the edge refusing tcp/443 to the chart repositories' hosts. Keeping the archives
# beside a clone does not put them in git; this commit does.
#
# THE COMMIT. Its one parent is the release commit. Its tree is the release tree plus exactly the archives each
# charts/<layer>/Chart.lock names at TAG, at charts/<layer>/charts/<name>-<version>.tgz (the names `helm dependency
# build` writes and tools/helm-deps.sh checks for), read byte for byte from DIR's working tree, and nothing else.
# Author, committer, both dates (the release commit's committer date) and the message are fixed, so the same release
# and the same archive bytes make the same commit in any clone: a server that already holds the tag from an earlier
# run compares equal. If the release tree already carries every archive, TAG-vendored names the release commit.
#
# THE TAG NAME IS DERIVED, NOT HASHED: TAG plus "-vendored". tockmox.revision is written into the site before the
# site is generated, which is before bootstrap-forge runs, so the operator has to know the name in advance. The
# commit id is the content hash; the tag names which release it carries.
#
# A TAG IS NEVER MOVED. When TAG-vendored is already in DIR it is kept if it is still the release plus every
# archive and only archives, and refused otherwise; the archives in DIR are not compared with it then. `helm
# package` stamps tockmox-common's archive with the time it ran, so vendoring again changes the bytes and not what
# Argo CD renders, and the tag a site's Applications read must not change under them. To make it again, delete the
# tag (in DIR and on every server that has it) and run this again.
#
# WHAT IT WRITES. Git objects in DIR, and the one ref refs/tags/TAG-vendored. Never HEAD, the index, the working
# tree or another ref. --dry-run writes no ref (the objects it hashed stay, unreferenced, until git gc).
#
# REFUSES, exit 1, writing no ref: DIR is not a git checkout; TAG is not in it, or is not the Tockmox charts
# repository; an archive a Chart.lock names is not in DIR; a layer has dependencies and no Chart.lock; an existing
# TAG-vendored lacks an archive, has another parent, or changes a file outside charts/*/charts/. Exit 2: usage.
#
# Bash 3.2 clean, as tools/helm-deps.sh is: an operator's macOS workstation runs it.
set -euo pipefail

SUFFIX="-vendored"
NAME="Tockmox charts-vendored-tag"
EMAIL="charts-vendored-tag@tockmox.invalid"

usage() {
  sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'
}
die() { printf 'charts-vendored-tag: %s\n' "$*" >&2; exit 1; }
say() { printf 'charts-vendored-tag: %s\n' "$*" >&2; }

DRY=false
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --dry-run) DRY=true; shift ;;
esac
[ $# -eq 2 ] || { usage >&2; exit 2; }
DIR="$1"; TAG="$2"

[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "not a tag name: '$TAG'"
case "$TAG" in
  *"$SUFFIX") die "'$TAG' is already a vendored tag. Name the release tag it is made from ('${TAG%"$SUFFIX"}')." ;;
esac
OUT_TAG="${TAG}${SUFFIX}"
[ -d "$DIR" ] || die "no such directory: $DIR"
g() { git -C "$DIR" "$@"; }
g rev-parse --git-dir >/dev/null 2>&1 || die "$DIR is not a git checkout"
REL="$(g rev-parse -q --verify "refs/tags/${TAG}^{commit}" 2>/dev/null)" || die "there is no tag '$TAG' in $DIR"
g cat-file -e "${REL}:charts/tockmox-platform/Chart.yaml" 2>/dev/null \
  || die "tag '$TAG' in $DIR has no charts/tockmox-platform/Chart.yaml: this is not the Tockmox charts repository"

W="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-vendored.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# ---- the archives the release names: one path per line in $W/want
: > "$W/want"
lock_deps() {  # stdin: a Chart.lock -> "name<TAB>version" per dependency (tools/helm-deps.sh reads it the same way)
  awk '
    /^dependencies:/ {d=1; next}
    d && /^[^ -]/ {d=0}
    d && /^- name: /        {if (n!="") print n "\t" v; n=$3; v=""; next}
    d && /^  version: /     {v=$2; next}
    END {if (n!="") print n "\t" v}
  ' | tr -d '"'
}
for layer in $(g ls-tree --name-only "$REL" charts/); do
  g cat-file -e "${REL}:${layer}/Chart.yaml" 2>/dev/null || continue
  if ! g cat-file -e "${REL}:${layer}/Chart.lock" 2>/dev/null; then
    yaml="$(g show "${REL}:${layer}/Chart.yaml")"
    if grep -q '^dependencies:' <<<"$yaml"; then
      die "${layer} has dependencies and no Chart.lock at ${TAG}, so which archives it needs cannot be read"
    fi
    continue
  fi
  while IFS="$(printf '\t')" read -r n v; do
    [ -n "$n" ] || continue
    [[ "$n" =~ ^[A-Za-z0-9._-]+$ && "$v" =~ ^[A-Za-z0-9._+-]+$ ]] \
      || die "${layer}/Chart.lock at ${TAG} names a dependency this cannot turn into a file name: '${n}' '${v}'"
    printf '%s/charts/%s-%s.tgz\n' "$layer" "$n" "$v" >> "$W/want"
  done <<LOCK
$(g show "${REL}:${layer}/Chart.lock" | lock_deps)
LOCK
done
N="$(grep -c . "$W/want" || true)"

# check COMMIT: is it the release plus every archive, and only archives? Prints what is wrong; non-zero if anything.
check() {
  local c="$1" parents bad=0 p
  if [ "$c" != "$REL" ]; then
    parents="$(g rev-list --parents -n 1 "$c" | cut -d' ' -f2-)"
    if [ "$parents" != "$REL" ]; then
      say "${OUT_TAG} (${c}) is not the release commit ${REL} or its one child: its parents are '${parents}'"; bad=1
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [[ "$p" =~ ^charts/[^/]+/charts/[^/]+\.tgz$ ]] || { say "${OUT_TAG} changes ${p}, which is not a vendored archive"; bad=1; }
    done <<DIFF
$(g diff-tree -r --no-commit-id --name-only "$REL" "$c")
DIFF
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    g cat-file -e "${c}:${p}" 2>/dev/null || { say "${OUT_TAG} lacks ${p}: a server that serves it sends Argo CD to the chart repository for it"; bad=1; }
  done < "$W/want"
  return "$bad"
}

# ---- an existing vendored tag is kept or refused, never moved
if CUR="$(g rev-parse -q --verify "refs/tags/${OUT_TAG}^{commit}" 2>/dev/null)"; then
  check "$CUR" || die "${OUT_TAG} in ${DIR} is not ${TAG} plus its ${N} vendored archives (above). A tag is never moved: delete it (git -C ${DIR} tag -d ${OUT_TAG}, and on any server that has it) and run this again."
  differ=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -f "$DIR/$p" ] || [ "$(g hash-object --no-filters -- "$p")" != "$(g rev-parse "${CUR}:${p}")" ]; then differ=$((differ + 1)); fi
  done < "$W/want"
  if [ "$differ" -gt 0 ]; then
    say "kept ${OUT_TAG} (${CUR}): ${differ} archive(s) in ${DIR} differ from the ones it carries (helm package stamps the time), and a tag is never moved"
  else
    say "kept ${OUT_TAG} (${CUR}): it already carries the ${N} archive(s) in ${DIR}"
  fi
  printf '%s %s %s\n' "$OUT_TAG" "$CUR" "$N"
  exit 0
fi

# ---- every archive must be on disk before anything is written
missing=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ ! -f "$DIR/$p" ] || [ -L "$DIR/$p" ] || [ ! -s "$DIR/$p" ]; then missing="${missing}
    ${p}"; fi
done < "$W/want"
[ -z "$missing" ] || die "the archives ${TAG}'s Chart.lock files name are not all in ${DIR}. Missing:${missing}
  Vendor them with tools/helm-deps.sh in ${DIR} (docs/deployment/airgap.md step 3) and run this again. Nothing was written."

# ---- the commit: the release tree plus the archives, through a throwaway index
export GIT_INDEX_FILE="$W/index"
g read-tree "$REL"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  blob="$(g hash-object -w --no-filters -- "$p")"
  g update-index --add --cacheinfo "100644,${blob},${p}"
done < "$W/want"
TREE="$(g write-tree)"
unset GIT_INDEX_FILE
if [ "$TREE" = "$(g rev-parse "${REL}^{tree}")" ]; then
  VEN="$REL"
else
  DATE="$(g log -1 --format='%ct %cz' "$REL")"
  VEN="$(printf 'Vendored subchart archives for %s\n\nThe release %s plus the %s archives its Chart.lock files name, so Argo CD renders\nevery layer without reaching a chart repository. Made by install/charts-vendored-tag.sh.\n' "$TAG" "$TAG" "$N" \
    | GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL" GIT_AUTHOR_DATE="$DATE" \
      GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL" GIT_COMMITTER_DATE="$DATE" \
      git -C "$DIR" -c commit.gpgsign=false -c i18n.commitEncoding=UTF-8 commit-tree "$TREE" -p "$REL")"
fi
check "$VEN" || die "the commit made for ${OUT_TAG} (${VEN}) is not ${TAG} plus its archives (above); no ref was written"

if $DRY; then
  say "dry run: would tag ${VEN} as ${OUT_TAG}: ${TAG} plus ${N} archive(s); no ref was written"
else
  g update-ref "refs/tags/${OUT_TAG}" "$VEN" "" || die "could not write refs/tags/${OUT_TAG} in ${DIR}"
  say "made ${OUT_TAG} (${VEN}): ${TAG} plus ${N} archive(s)"
fi
printf '%s %s %s\n' "$OUT_TAG" "$VEN" "$N"

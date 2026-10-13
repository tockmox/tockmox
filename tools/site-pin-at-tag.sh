#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Asserts, when a release tag is pushed, that tockmox-site-template's `main`
# pins that same tag (TM-0534).
#
#   tools/site-pin-at-tag.sh vX.Y.Z[-rcN]              clone the template, check it
#   tools/site-pin-at-tag.sh vX.Y.Z --dir DIR          check a checkout you already have
#   tools/site-pin-at-tag.sh --selftest                prove the comparison can go red
#
# WHY THIS EXISTS. tools/release-preflight.sh check 5 asserts the same thing,
# but an operator runs it by hand before the tag, and a skipped or forgotten
# run leaves nothing red anywhere: at 0.6.0-rc2 the re-pin was cut, pushed and
# left unmerged for three days while evaluators installed rc1. The template's
# own pin-consistency workflow only proves the template agrees with ITSELF; it
# cannot know what the product tag is. This script is the half that knows, and
# .github/workflows/release-tag.yaml runs it on every `v*` tag push.
#
# THE ORDER IT ASSUMES. RELEASING.md's sequence is re-pin and merge the
# template, run release-preflight, then tag. So at tag-push time the template's
# `main` must already name the tag being pushed. A red here means the re-pin was
# not merged (or was merged for a different tag) before the tag was cut.
# That order is a deliberate, accepted WINDOW (TM-0738): between the merged
# re-pin and the tag push the public template names a ref that does not resolve.
# RELEASING.md "The re-pin window" states its length; release-preflight.sh
# check 5 reports whether the ref resolves.
#
# RC TAGS ARE CHECKED THE SAME WAY. The process re-pins at every candidate (the
# "site-template drift check" row of the per-RC table in RELEASING.md; the rc2
# incident above was an rc), so vX.Y.Z-rcN must be pinned as vX.Y.Z-rcN and no
# exception is made. If the process ever re-pins only at the final tag, relax
# it here by one rule in `want_pin`, not by skipping the job.
#
# WHAT IT CHECKS. Every `targetRevision:` under bootstrap/applications/ that is
# not `main` (the operator's own repository stays on main) must equal the tag,
# at least one must exist, and the README's "Pinned to" line must name the tag.
# Exact string comparison: v0.7.1 is not v0.7.1-rc1.
#
# NOT CHECKED HERE: that the template's default branch is the one inspected
# (the clone takes the remote HEAD), and the diff against installer output.
#
# Portable to bash 3.2 (macOS) and the Linux runner: no arrays, no mapfile.
#
# Environment:
#   SITE_TEMPLATE_URL   clone source (default: the public template repository)

set -euo pipefail

APPS_DIR="bootstrap/applications"
TAG_RE='^v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*(-rc[0-9][0-9]*)?$'

# check_pin DIR TAG ... prints findings; 0 = template pins TAG, 1 = it does not
check_pin() {
  cp_dir="$1"; cp_tag="$2"; cp_bad=0
  cp_apps="$cp_dir/$APPS_DIR"
  [ -d "$cp_apps" ] || { echo "  no $cp_apps directory"; return 1; }

  cp_pins=$(grep -ohE 'targetRevision:[[:space:]]*[^[:space:]]+' "$cp_apps"/*.yaml 2>/dev/null \
              | sed 's/targetRevision:[[:space:]]*//' | grep -vx 'main' | sort | uniq -c || true)
  if [ -z "$cp_pins" ]; then
    echo "  no non-main targetRevision under $APPS_DIR (nothing is pinned)"
    return 1
  fi
  # one line per distinct value: "<count> <value>"
  while read -r cp_n cp_v; do
    [ -n "${cp_v:-}" ] || continue
    if [ "$cp_v" != "$cp_tag" ]; then
      echo "  $cp_n targetRevision line(s) on $cp_v, want $cp_tag"
      cp_bad=1
    fi
  done <<EOP
$cp_pins
EOP

  if [ -f "$cp_dir/README.md" ]; then
    grep -q "Pinned to \*\*${cp_tag}\*\*" "$cp_dir/README.md" || {
      echo "  README.md: $(grep -m1 'Pinned to' "$cp_dir/README.md" || echo '<no Pinned to line>')  want: Pinned to **${cp_tag}**"
      cp_bad=1
    }
  else
    echo "  no README.md in the template"; cp_bad=1
  fi
  [ "$cp_bad" -eq 0 ]
}

selftest() {
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  fails=0
  mk() { # mk DIR PIN_A PIN_B README_PIN
    mkdir -p "$1/$APPS_DIR"
    printf 'spec:\n  sources:\n  - targetRevision: %s\n  - targetRevision: main\n' "$2" > "$1/$APPS_DIR/layer-a.yaml"
    printf 'spec:\n  sources:\n  - targetRevision: %s\n  - targetRevision: main\n' "$3" > "$1/$APPS_DIR/layer-b.yaml"
    printf 'source:\n  targetRevision: main\n' > "$1/$APPS_DIR/site-apps.yaml"
    printf '# Site\n\nPinned to **%s**.\n' "$4" > "$1/README.md"
  }
  probe() { # probe LABEL pass|fail DIR TAG
    if check_pin "$3" "$4" >"$tmp/out" 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$2" ]; then echo "  ok  $1: $got as expected"
    else echo "  SELFTEST FAIL: $1 wanted $2, got $got"; sed 's/^/        /' "$tmp/out"; fails=1; fi
  }
  tagok() { printf '%s\n' "$1" | grep -Eq "$TAG_RE" && echo pass || echo fail; }

  echo "selftest: site pin at tag"
  mk "$tmp/g" v1.2.3 v1.2.3 v1.2.3;           probe "template on the pushed tag" pass "$tmp/g" v1.2.3
  mk "$tmp/rc" v1.2.3-rc2 v1.2.3-rc2 v1.2.3-rc2; probe "an rc tag pinned as that rc" pass "$tmp/rc" v1.2.3-rc2
  mk "$tmp/stale" v1.2.2 v1.2.2 v1.2.2;       probe "template left on the previous release (the TM-0534 case)" fail "$tmp/stale" v1.2.3
  mk "$tmp/rcold" v1.2.3-rc1 v1.2.3-rc1 v1.2.3-rc1; probe "template on rc1 when rc2 is pushed" fail "$tmp/rcold" v1.2.3-rc2
  mk "$tmp/final" v1.2.3-rc2 v1.2.3-rc2 v1.2.3-rc2; probe "final tag with the template still on its rc" fail "$tmp/final" v1.2.3
  mk "$tmp/half" v1.2.3 v1.2.2 v1.2.3;        probe "one layer left behind" fail "$tmp/half" v1.2.3
  mk "$tmp/readme" v1.2.3 v1.2.3 v1.2.2;      probe "README still names the previous pin" fail "$tmp/readme" v1.2.3
  mk "$tmp/nor" v1.2.3 v1.2.3 v1.2.3; rm "$tmp/nor/README.md"; probe "no README" fail "$tmp/nor" v1.2.3
  mkdir -p "$tmp/none/$APPS_DIR"; printf 'source:\n  targetRevision: main\n' > "$tmp/none/$APPS_DIR/site-apps.yaml"; printf 'Pinned to **v1.2.3**.\n' > "$tmp/none/README.md"
  probe "nothing pinned at all (all main)" fail "$tmp/none" v1.2.3
  mk "$tmp/sub" v1.2.30 v1.2.30 v1.2.30;      probe "a longer version is not a prefix match" fail "$tmp/sub" v1.2.3
  for t in v1.2.3 v1.2.3-rc1; do [ "$(tagok "$t")" = pass ] || { echo "  SELFTEST FAIL: tag $t refused"; fails=1; }; done
  for t in 1.2.3 v1.2 main v1.2.3-beta; do [ "$(tagok "$t")" = fail ] || { echo "  SELFTEST FAIL: tag $t accepted"; fails=1; }; done

  if [ "$fails" -eq 0 ]; then echo "site-pin-at-tag --selftest: PASSED"; exit 0; fi
  echo "site-pin-at-tag --selftest: FAILED"; exit 1
}

TAG=""; DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) selftest ;;
    --dir) DIR="${2:?--dir needs a path}"; shift 2 ;;
    -h|--help|"") echo "usage: tools/site-pin-at-tag.sh vX.Y.Z[-rcN] [--dir DIR] | --selftest"; exit 1 ;;
    *) TAG="${1#refs/tags/}"; shift ;;
  esac
done
printf '%s\n' "$TAG" | grep -Eq "$TAG_RE" || {
  echo "site-pin-at-tag: \"$TAG\" is not a release tag (want vX.Y.Z or vX.Y.Z-rcN)"; exit 2; }

if [ -z "$DIR" ]; then
  DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
  url="${SITE_TEMPLATE_URL:-https://github.com/tockmox/tockmox-site-template.git}"
  git clone --quiet --depth 1 "$url" "$DIR" || { echo "site-pin-at-tag: could not clone $url"; exit 2; }
fi

echo "site template ($DIR) must pin $TAG"
if check_pin "$DIR" "$TAG"; then
  echo "site-pin-at-tag: OK, the template pins $TAG"
else
  echo "site-pin-at-tag: FAILED. tockmox-site-template is not pinned to $TAG; re-pin and merge it (RELEASING.md, \"tockmox-site-template re-pin\"), then re-run this job."
  exit 1
fi

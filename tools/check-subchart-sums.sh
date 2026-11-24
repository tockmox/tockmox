#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE SUBCHART BYTE LOCK MATCHES EVERY Chart.lock, AND THE VENDORED ARCHIVES MATCH THE LOCK.
#
# Chart.lock pins each upstream subchart by name and version, and its `digest:` hashes the dependency
# list, not the archives. So a chart repository, its CDN or a lapsed domain can serve different bytes
# under a version the lock already names, and nothing in the tree notices. subcharts.sha256, at the
# repository root, closes that for every path that vendors the archives (CI, the maintainer, an
# air-gapped site): one `sha256sum` line per upstream archive, committed, so the bytes are under the
# signed tag. tools/helm-deps.sh refuses an archive whose bytes differ from its line, on its offline
# and its online path. This gate keeps the lock itself honest.
#
# WHAT IT CHECKS:
#   (a) subcharts.sha256 exists and every line is `<64 lowercase hex>  charts/<layer>/charts/<archive>.tgz`,
#       sorted, each path once;
#   (b) its paths are exactly the upstream (non-file://) dependencies across charts/*/Chart.lock, as
#       charts/<layer>/charts/<name>-<version>.tgz: a dependency with no line and a line no Chart.lock
#       names are each a failure (a version bump that was not recorded shows as both);
#   (c) every listed archive that is vendored in the tree has the bytes its line records. An archive that
#       is not vendored is counted and not judged here; tools/check-vendored-charts.sh owns presence.
# (a) and (b) read files only. (c) hashes files. No helm, no network.
#
#   tools/check-subchart-sums.sh [--tree DIR]   check the tree (default: this repository)
#   tools/check-subchart-sums.sh --selftest     red on each planted fault, green on each revert
#
# A new or bumped subchart is recorded with `tools/helm-deps.sh --record`, which adds the new line and
# drops the old one, and never rewrites the hash of a name and version already recorded.
#
# Exit 0 the lock matches; 1 a mismatch (named); 2 bad usage or no charts. Bash 3.2 and BSD tools.
set -uo pipefail

SUMS_NAME=subcharts.sha256

sha256_of() {  # <file> -> lowercase hex
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# One "name<TAB>repository<TAB>version" line per Chart.lock dependency (tools/helm-deps.sh reads it the same way).
lock_deps() {  # <Chart.lock>
  awk '
    /^dependencies:/ {d=1; next}
    d && /^[^ -]/ {d=0}
    d && /^- name: /        {if (n!="") print n "\t" r "\t" v; n=$3; r=""; v=""; next}
    d && /^  repository: /  {r=$2; next}
    d && /^  version: /     {v=$2; next}
    END {if (n!="") print n "\t" r "\t" v}
  ' "$1" | tr -d '"'
}

# The archive paths the Chart.lock files pin, sorted, one per line.
expected_paths() {  # <tree>
  local lock layer
  for lock in "$1"/charts/*/Chart.lock; do
    [ -f "$lock" ] || continue
    layer="$(basename "$(dirname "$lock")")"
    lock_deps "$lock" | while IFS="$(printf '\t')" read -r n r v; do
      [ -n "$n" ] || continue
      case "$r" in file://*) continue ;; esac
      printf 'charts/%s/charts/%s-%s.tgz\n' "$layer" "$n" "$v"
    done
  done | LC_ALL=C sort
}

check_tree() {  # <tree> -> prints what it found, returns 0 or 1
  local t="$1" sums bad=0 work
  sums="$t/$SUMS_NAME"
  ls "$t"/charts/*/Chart.yaml >/dev/null 2>&1 || { echo "check-subchart-sums: no charts under $t/charts" >&2; return 2; }
  if [ ! -f "$sums" ]; then
    echo "  FAIL: $SUMS_NAME does not exist. Record it: HELM_DEPS_ONLINE=1 tools/helm-deps.sh --record"
    return 1
  fi
  work="$(mktemp -d)" || return 2
  # (a) the format, the order, no duplicates
  # grep -E rather than awk: an interval like {64} is not in every awk a maintainer's machine has.
  grep -nvE '^[0-9a-f]{64}  charts/[a-z0-9-]+/charts/[A-Za-z0-9._+-]+\.tgz$' "$sums" > "$work/malformed"
  if [ -s "$work/malformed" ]; then
    sed -E 's/^([0-9]+):/  FAIL: malformed line \1: /' "$work/malformed"; bad=1
  fi
  awk '{print $2}' "$sums" > "$work/listed"
  if ! LC_ALL=C sort -c "$work/listed" 2>/dev/null; then
    echo "  FAIL: $SUMS_NAME is not sorted by path (LC_ALL=C sort -k2)"; bad=1
  fi
  LC_ALL=C sort "$work/listed" | uniq -d | sed 's/^/  FAIL: listed more than once: /' > "$work/dups"
  [ -s "$work/dups" ] && { cat "$work/dups"; bad=1; }
  # (b) the set, against every Chart.lock
  expected_paths "$t" > "$work/expected"
  LC_ALL=C sort -u "$work/listed" > "$work/listed.sorted"
  LC_ALL=C comm -23 "$work/expected" "$work/listed.sorted" | sed 's/^/  FAIL: a Chart.lock pins it and it has no line: /' > "$work/missing"
  LC_ALL=C comm -13 "$work/expected" "$work/listed.sorted" | sed 's/^/  FAIL: a line no Chart.lock pins: /' > "$work/stale"
  [ -s "$work/missing" ] && { cat "$work/missing"; bad=1; }
  [ -s "$work/stale" ] && { cat "$work/stale"; bad=1; }
  # (c) the bytes of what is vendored
  local h p actual checked=0 absent=0
  while read -r h p; do
    [ -n "${p:-}" ] || continue
    if [ ! -f "$t/$p" ]; then absent=$((absent + 1)); continue; fi
    actual="$(sha256_of "$t/$p")"
    checked=$((checked + 1))
    if [ "$actual" != "$h" ]; then
      echo "  FAIL: $p has other bytes than its line: expected $h, found $actual"
      bad=1
    fi
  done < "$sums"
  rm -rf "$work"
  if [ "$bad" = 0 ]; then
    echo "  ok: $(wc -l < "$sums" | tr -d ' ') line(s), one per upstream dependency across every Chart.lock"
    echo "  bytes: $checked vendored archive(s) match their line; $absent not vendored here, not judged"
  fi
  return "$bad"
}

selftest() {
  local T fail=0 rc
  T="$(mktemp -d)" || exit 2
  trap 'rm -rf "$T"' EXIT
  ok() { echo "  ok   $1"; }
  no() { echo "  FAIL $1"; fail=1; }
  mk() {  # a tree with two layers: one local dependency and three upstream archives
    rm -rf "$T/t"; mkdir -p "$T/t/charts/tockmox-a/charts" "$T/t/charts/tockmox-b/charts" "$T/t/charts/tockmox-common"
    printf 'apiVersion: v2\nname: tockmox-common\nversion: 0.1.0\n' > "$T/t/charts/tockmox-common/Chart.yaml"
    printf 'apiVersion: v2\nname: tockmox-a\nversion: 0.1.0\n' > "$T/t/charts/tockmox-a/Chart.yaml"
    printf 'apiVersion: v2\nname: tockmox-b\nversion: 0.1.0\n' > "$T/t/charts/tockmox-b/Chart.yaml"
    cat > "$T/t/charts/tockmox-a/Chart.lock" <<'Y'
dependencies:
- name: tockmox-common
  repository: file://../tockmox-common
  version: 0.1.0
- name: up-one
  repository: https://charts.example.invalid
  version: 1.0.2
- name: up-two
  repository: oci://registry.example.invalid/charts
  version: v2.0.0
digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
generated: "2026-11-24T00:00:00Z"
Y
    cat > "$T/t/charts/tockmox-b/Chart.lock" <<'Y'
dependencies:
- name: tockmox-common
  repository: file://../tockmox-common
  version: 0.1.0
- name: up-three
  repository: "https://charts.example.invalid"
  version: "3.1.0"
digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
generated: "2026-11-24T00:00:00Z"
Y
    printf 'one\n' > "$T/t/charts/tockmox-a/charts/up-one-1.0.2.tgz"
    printf 'two\n' > "$T/t/charts/tockmox-a/charts/up-two-v2.0.0.tgz"
    printf 'three\n' > "$T/t/charts/tockmox-b/charts/up-three-3.1.0.tgz"
    printf 'common\n' > "$T/t/charts/tockmox-a/charts/tockmox-common-0.1.0.tgz"
    ( cd "$T/t" && for f in charts/tockmox-a/charts/up-one-1.0.2.tgz charts/tockmox-a/charts/up-two-v2.0.0.tgz charts/tockmox-b/charts/up-three-3.1.0.tgz; do
        printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done ) > "$T/t/$SUMS_NAME"
  }
  run() { out="$(check_tree "$T/t" 2>&1)"; rc=$?; }
  red() {  # <label> <expected text>
    run
    if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -F "$2" >/dev/null; then ok "red: $1"; else no "red: $1 (rc=$rc): $(printf '%s' "$out" | tr '\n' ';')"; fi
    mk; run
    if [ "$rc" = 0 ]; then ok "green again after reverting: $1"; else no "revert of $1 is not green (rc=$rc): $(printf '%s' "$out" | tr '\n' ';')"; fi
  }
  mk; run
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep 'bytes: 3 vendored' >/dev/null; then ok "green: a lock that matches every Chart.lock and every archive"; else no "baseline (rc=$rc): $out"; fi

  rm -f "$T/t/$SUMS_NAME"
  red "no lock file" "does not exist"

  sed '/up-three/d' "$T/t/$SUMS_NAME" > "$T/s" && mv "$T/s" "$T/t/$SUMS_NAME"
  red "a dependency with no line" "has no line: charts/tockmox-b/charts/up-three-3.1.0.tgz"

  printf '%s  %s\n' "$(printf 'x' | (sha256sum 2>/dev/null || shasum -a 256) | awk '{print $1}')" charts/tockmox-b/charts/zz-9.9.9.tgz >> "$T/t/$SUMS_NAME"
  red "a line no Chart.lock pins" "a line no Chart.lock pins: charts/tockmox-b/charts/zz-9.9.9.tgz"

  sed '1s/^\(.\{63\}\)./\1/' "$T/t/$SUMS_NAME" > "$T/s" && mv "$T/s" "$T/t/$SUMS_NAME"
  red "a hash one character short" "malformed line 1"

  sed '1s/^[0-9a-f]/A/' "$T/t/$SUMS_NAME" > "$T/s" && mv "$T/s" "$T/t/$SUMS_NAME"
  red "an uppercase hash" "malformed line 1"

  head -n 1 "$T/t/$SUMS_NAME" > "$T/s" && cat "$T/s" >> "$T/t/$SUMS_NAME"
  red "a line listed twice" "listed more than once"

  awk '{l[NR]=$0} END {for (i=NR;i>=1;i--) print l[i]}' "$T/t/$SUMS_NAME" > "$T/s" && mv "$T/s" "$T/t/$SUMS_NAME"
  red "lines out of order" "not sorted"

  printf 'One\n' > "$T/t/charts/tockmox-a/charts/up-one-1.0.2.tgz"
  red "one changed byte in a vendored archive" "charts/tockmox-a/charts/up-one-1.0.2.tgz has other bytes"

  sed 's/version: "3.1.0"/version: "3.1.1"/' "$T/t/charts/tockmox-b/Chart.lock" > "$T/s" && mv "$T/s" "$T/t/charts/tockmox-b/Chart.lock"
  run
  if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -F 'has no line: charts/tockmox-b/charts/up-three-3.1.1.tgz' >/dev/null \
     && printf '%s\n' "$out" | grep -F 'a line no Chart.lock pins: charts/tockmox-b/charts/up-three-3.1.0.tgz' >/dev/null; then
    ok "red: a Chart.lock bump that was not recorded names the new version and the old line"
  else
    no "unrecorded bump (rc=$rc): $(printf '%s' "$out" | tr '\n' ';')"
  fi
  mk

  rm -f "$T/t/charts/tockmox-b/charts/up-three-3.1.0.tgz"
  run
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep '1 not vendored' >/dev/null; then ok "an archive that is not vendored is counted, not judged"; else no "absent archive (rc=$rc): $out"; fi

  [ "$fail" = 0 ] && echo "check-subchart-sums selftest: all passed" || echo "check-subchart-sums selftest: FAILED"
  exit "$fail"
}

tree="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  --selftest) selftest ;;
  --tree) [ -n "${2:-}" ] || { echo "usage: $0 [--tree DIR] | --selftest" >&2; exit 2; }; tree="$2" ;;
  "") ;;
  *) echo "usage: $0 [--tree DIR] | --selftest" >&2; exit 2 ;;
esac
echo "subchart byte lock: $tree/$SUMS_NAME"
check_tree "$tree"

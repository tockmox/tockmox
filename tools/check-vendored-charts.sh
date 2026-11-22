#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# EVERY DECLARED SUBCHART HAS ITS VENDORED ARCHIVE, AND NOTHING ELSE IS THERE.
#
# A disconnected Argo CD renders a layer from what the tree carries: the git tree plus the subchart
# archives tools/helm-deps.sh vendors into charts/<layer>/charts/. .gitignore excludes those archives,
# so a path that publishes the tree has to name them, and one that does not hands Argo CD a layer with
# no subcharts, which it then fetches upstream (and under a network cut, cannot). The air-gap lane lost
# a sitting that way: every subchart was vendored, the push dropped them all, and nothing said so until
# the guest's Argo CD went to the internet. A dependency added to a Chart.yaml without being vendored,
# or an archive left behind by a bump, is the same class one archive at a time. This gate makes each a
# build failure.
#
# WHAT IT CHECKS, in a tree whose subcharts are vendored (check-all.sh runs tools/helm-deps.sh first):
#   (a) the count: the *.tgz files under charts/*/charts/ number exactly the `repository:` lines across
#       charts/*/Chart.yaml (the local file:// dependency, tockmox-common, is packaged into each layer
#       and counts like any other);
#   (b) the names: every dependency a Chart.yaml declares has charts/<layer>/charts/<name>-<version>.tgz,
#       and every archive there is one a dependency of that layer declares. The version is the one
#       Chart.yaml pins; a range is resolved through the layer's Chart.lock, as helm-deps.sh does.
# (b) also catches what (a) cannot: an archive at the wrong version keeps the count and changes the name.
#
# HERMETIC. This gate reads files and nothing else: no helm, no network, no repository. Vendoring needs
# the network on a fresh clone, so it is not done here; check-all.sh's dependency step does it (online,
# or offline when the archives are already in place) and refuses to run any gate when it fails. Run
# alone on a tree that was never vendored (no charts/*/charts/ directory at all), this skips, exit 2
# with a SKIPPED: line, the way the other gates that need fetched dependencies do. A tree that was
# vendored and lost archives is a failure, not a skip.
#
#   tools/check-vendored-charts.sh [--tree DIR]   check the tree (default: this repository)
#   tools/check-vendored-charts.sh --selftest     red on a missing, an extra and a mis-versioned archive, green on each revert
#
# Exit 0 the archives match the declarations; 1 a missing, unknown or uncounted archive; 2 skipped (not
# vendored, with a SKIPPED: line) or bad input (no charts, a range with no lock entry, a Chart.yaml whose
# dependencies cannot be read). Bash 3.2 and BSD tools: no associative arrays, no mapfile.
set -uo pipefail

die2() { echo "check-vendored-charts: $*" >&2; exit 2; }

# One "layer<TAB>name<TAB>version<TAB>repository" line per dependency in a Chart.yaml. Keys may come in
# any order inside an item; comments and blank lines are ignored; the block ends at the next top-level key.
yaml_deps() {  # <Chart.yaml> <layer>
  awk -v layer="$2" '
    function flush() { if (n != "" || v != "" || r != "") print layer "\t" n "\t" v "\t" r; n = ""; v = ""; r = "" }
    function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s); gsub(/["'\'']/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^dependencies:/ { d = 1; ind = -1; next }
    d && /^[^[:space:]-]/ { flush(); d = 0 }
    !d { next }
    {
      s = $0
      if (match(s, /^[[:space:]]*-[[:space:]]+/)) {
        # A dash at the first item'\''s indent starts an item; a deeper one is a list inside an item.
        i = index(s, "-") - 1
        if (ind < 0) ind = i
        if (i == ind) { flush(); kind = RLENGTH; s = substr(s, RLENGTH + 1); top = 1 } else next
      } else {
        # Only keys at the item'\''s own indent are its fields; deeper ones belong to a nested value.
        match(s, /^[[:space:]]*/); top = (ind >= 0 && RLENGTH == kind)
      }
      sub(/^[[:space:]]+/, "", s)
      if (!top) next
      if (s ~ /^name:/) n = val(s)
      else if (s ~ /^version:/) v = val(s)
      else if (s ~ /^repository:/) r = val(s)
    }
    END { flush() }
  ' "$1"
}

# The version Chart.lock pins for one dependency, empty when there is none.
lock_version() {  # <Chart.lock> <name>
  [ -f "$1" ] || return 0
  awk -v want="$2" '
    /^dependencies:/ { d = 1; next }
    d && /^[^ -]/ { d = 0 }
    d && /^- name: / { n = $3; gsub(/"/, "", n); next }
    d && /^  version: / { v = $2; gsub(/"/, "", v); if (n == want) { print v; exit } }
  ' "$1"
}

check() {  # TREE
  local tree="$1" w c layer nyaml nrepo nparsed narch vendored=0 rc=0 n v lv
  [ -d "$tree" ] || die2 "no such tree: $tree"
  tree="$(cd "$tree" && pwd)"
  ls "$tree"/charts/*/Chart.yaml >/dev/null 2>&1 || die2 "no charts/*/Chart.yaml under $tree"
  for c in "$tree"/charts/*/charts; do [ -d "$c" ] && vendored=1; done
  if [ "$vendored" = 0 ]; then
    echo "check-vendored-charts: no charts/*/charts/ directory under $tree, so no subchart was ever vendored here (bash tools/helm-deps.sh; check-all.sh runs it first)" >&2
    echo "SKIPPED: chart dependencies are not fetched" >&2
    exit 2
  fi
  w="$(mktemp -d "${TMPDIR:-/tmp}/check-vendored-charts.XXXXXX")" || die2 "cannot make a temporary directory"
  # shellcheck disable=SC2064  # expand now: w is local
  trap "rm -rf '$w'" EXIT
  : > "$w/deps"; nyaml=0
  for c in "$tree"/charts/*/Chart.yaml; do
    layer="$(basename "$(dirname "$c")")"
    nyaml=$((nyaml + 1))
    yaml_deps "$c" "$layer" >> "$w/deps" || die2 "cannot read the dependencies of charts/$layer/Chart.yaml"
  done
  # The count the air-gap lane checks by eye: `repository:` lines, comments excluded.
  nrepo="$(cat "$tree"/charts/*/Chart.yaml | grep -Ec '^[[:space:]]*(-[[:space:]]+)?repository:')"
  nparsed="$(awk -F'\t' '$4 != ""' "$w/deps" | wc -l | tr -d ' ')"
  [ "$nparsed" = "$nrepo" ] \
    || die2 "read ${nparsed} dependencies with a repository from charts/*/Chart.yaml, but the files have ${nrepo} repository: lines; this reader is broken, not the tree"
  awk -F'\t' '$2 == "" || $3 == "" { print "  charts/" $1 "/Chart.yaml: a dependency with no name or no version"; bad = 1 } END { exit bad }' "$w/deps" >&2 \
    || die2 "every dependency needs a name and a version"
  # The archive each dependency vendors to, by the version Chart.yaml pins or, for a range, Chart.lock's.
  : > "$w/want"
  while IFS="$(printf '\t')" read -r layer n v _; do
    case "$v" in
      *[!0-9A-Za-z.+-]*|*.[xX]|*.[xX].*|'')
        lv="$(lock_version "$tree/charts/$layer/Chart.lock" "$n")"
        [ -n "$lv" ] || die2 "charts/$layer/Chart.yaml: $n is a range ($v) and charts/$layer/Chart.lock pins no version for it"
        v="$lv" ;;
    esac
    printf 'charts/%s/charts/%s-%s.tgz\n' "$layer" "$n" "$v" >> "$w/want"
  done < "$w/deps"
  sort "$w/want" > "$w/want.s"
  : > "$w/have"
  for c in "$tree"/charts/*/charts/*.tgz; do
    [ -f "$c" ] || continue
    printf '%s\n' "${c#"$tree"/}" >> "$w/have"
  done
  sort "$w/have" > "$w/have.s"
  narch="$(wc -l < "$w/have.s" | tr -d ' ')"
  echo "check-vendored-charts: ${narch} archives under charts/*/charts/, ${nrepo} repository: lines across ${nyaml} Chart.yaml files"
  if [ "$narch" != "$nrepo" ]; then
    echo "COUNT ${narch} archives vendored for ${nrepo} declared dependencies"; rc=1
  fi
  comm -23 "$w/want.s" "$w/have.s" | while IFS= read -r c; do
    echo "MISSING $c (declared in ${c%/charts/*}/Chart.yaml)"
  done
  comm -13 "$w/want.s" "$w/have.s" | while IFS= read -r c; do
    echo "UNKNOWN $c (no dependency in ${c%/charts/*}/Chart.yaml declares it at that version)"
  done
  [ -z "$(comm -3 "$w/want.s" "$w/have.s")" ] || rc=1
  if [ "$rc" = 0 ]; then
    echo "check-vendored-charts: ok, every declared dependency has its archive and every archive is declared"
  else
    echo "check-vendored-charts: run tools/helm-deps.sh (HELM_DEPS_ONLINE=1 after a dependency bump), remove what no Chart.yaml declares, and check that the path that publishes the tree carries charts/*/charts/*.tgz" >&2
  fi
  return "$rc"
}

# ---- selftest: a fixture tree of two layers and a local library; no helm, no network ----
ST=""; ST_FAILS=0; ST_CASES=0; ST_OUT=""; ST_RC=0
st_build() {
  local t="$ST/t"
  rm -rf "$t"; mkdir -p "$t/charts/lib" "$t/charts/one/charts" "$t/charts/two/charts"
  printf '%s\n' 'apiVersion: v2' 'name: lib' 'version: 0.1.0' > "$t/charts/lib/Chart.yaml"
  printf '%s\n' 'apiVersion: v2' 'name: one' 'version: 0.1.0' 'dependencies:' \
    '  - name: lib' '    version: 0.1.0' '    repository: "file://../lib"' '' \
    '  # a comment that names a repository: "https://example.invalid" is not a dependency' \
    '  - name: up' '    repository: "https://charts.example.invalid"' '    version: "1.2.3"' '    condition: up.enabled' \
    '  - name: oci-thing' '    version: v2.0.0' "    repository: 'oci://registry.example.invalid/charts'" \
    'annotations:' '  x: y' > "$t/charts/one/Chart.yaml"
  printf '%s\n' 'apiVersion: v2' 'name: two' 'version: 0.1.0' 'dependencies:' \
    '- name: lib' '  version: 0.1.0' '  repository: file://../lib' \
    '- name: ranged' '  version: ">=3.0.0 <4.0.0"' '  repository: https://charts.example.invalid' > "$t/charts/two/Chart.yaml"
  printf '%s\n' 'dependencies:' '- name: lib' '  repository: file://../lib' '  version: 0.1.0' \
    '- name: ranged' '  repository: https://charts.example.invalid' '  version: 3.4.5' 'digest: sha256:0' > "$t/charts/two/Chart.lock"
  : > "$t/charts/one/charts/lib-0.1.0.tgz"; : > "$t/charts/one/charts/up-1.2.3.tgz"; : > "$t/charts/one/charts/oci-thing-v2.0.0.tgz"
  : > "$t/charts/two/charts/lib-0.1.0.tgz"; : > "$t/charts/two/charts/ranged-3.4.5.tgz"
}
st_expect() {  # CODE LABEL [TEXT...]: run the checker on the fixture and want that exit and every TEXT in its output
  local want="$1" label="$2" p ok=1; shift 2
  ST_CASES=$((ST_CASES + 1))
  ST_OUT="$(bash "$ST_ME" --tree "$ST/t" 2>&1)"; ST_RC=$?
  [ "$ST_RC" = "$want" ] || ok=0
  for p in "$@"; do case "$ST_OUT" in *"$p"*) ;; *) ok=0 ;; esac; done
  if [ "$ok" = 1 ]; then echo "ok    $label (exit $ST_RC)"
  else
    ST_FAILS=$((ST_FAILS + 1)); echo "FAIL  $label: wanted exit $want and every expected text, got exit $ST_RC:"
    printf '%s\n' "$ST_OUT" | sed 's/^/        /'
  fi
}
selftest() {
  ST="$(mktemp -d "${TMPDIR:-/tmp}/check-vendored-charts-selftest.XXXXXX")" || die2 "cannot make a temporary directory"
  # shellcheck disable=SC2064
  trap "rm -rf '$ST'" EXIT
  ST_ME="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  local t="$ST/t"

  st_build; st_expect 0 "the fixture is clean: a file:// library in two layers, OCI, a v-prefixed version, a range through Chart.lock, a comment" \
    "5 archives under charts/*/charts/, 5 repository: lines across 3 Chart.yaml files" "ok, every declared dependency"
  rm "$t/charts/one/charts/up-1.2.3.tgz"
  st_expect 1 "a missing archive" "COUNT 4 archives vendored for 5 declared" "MISSING charts/one/charts/up-1.2.3.tgz"
  : > "$t/charts/one/charts/up-1.2.3.tgz"
  st_expect 0 "the missing archive put back" "ok, every declared dependency"

  : > "$t/charts/two/charts/stray-9.9.9.tgz"
  st_expect 1 "an extra archive no Chart.yaml declares" "COUNT 6 archives vendored for 5 declared" "UNKNOWN charts/two/charts/stray-9.9.9.tgz"
  rm "$t/charts/two/charts/stray-9.9.9.tgz"
  st_expect 0 "the extra archive removed" "ok, every declared dependency"

  mv "$t/charts/one/charts/up-1.2.3.tgz" "$t/charts/one/charts/up-1.2.2.tgz"
  st_expect 1 "an archive at the wrong version, the count unchanged" \
    "MISSING charts/one/charts/up-1.2.3.tgz" "UNKNOWN charts/one/charts/up-1.2.2.tgz"
  mv "$t/charts/one/charts/up-1.2.2.tgz" "$t/charts/one/charts/up-1.2.3.tgz"
  st_expect 0 "the version put back" "ok, every declared dependency"

  printf '%s\n' '- name: added' '  version: 0.0.1' '  repository: https://charts.example.invalid' >> "$t/charts/two/Chart.yaml"
  st_expect 1 "a dependency declared and never vendored" "MISSING charts/two/charts/added-0.0.1.tgz"

  st_build; rm -f "$t"/charts/*/charts/*.tgz
  st_expect 1 "a vendored tree that lost every archive (the dropped-push case)" "COUNT 0 archives vendored for 5 declared" "MISSING charts/two/charts/ranged-3.4.5.tgz"
  st_build; rm -rf "$t"/charts/*/charts
  st_expect 2 "a tree never vendored skips, and says so" "SKIPPED: chart dependencies are not fetched"
  st_build; rm "$t/charts/two/Chart.lock"
  st_expect 2 "a range with no Chart.lock to resolve it" "is a range"
  st_build; sed 's/^    condition: up.enabled$/    import-values:\
      - child: exports.data\
        name: not-a-dependency\
    tags:\
      - storage/' "$t/charts/one/Chart.yaml" > "$t/x" && mv "$t/x" "$t/charts/one/Chart.yaml"
  st_expect 0 "lists and keys nested inside a dependency are not read as dependencies" "ok, every declared dependency"
  st_build; printf '%s\n' 'dependencies:' '  - repository: https://charts.example.invalid' > "$t/charts/lib/Chart.yaml"
  st_expect 2 "a dependency the reader cannot name" "no name or no version"

  echo "check-vendored-charts selftest: ${ST_CASES} cases, ${ST_FAILS} failed"
  [ "$ST_FAILS" = 0 ]
}

TREE_ARG=""; MODE=check
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) [ $# -ge 2 ] || die2 "--tree needs a directory"; TREE_ARG="$2"; shift 2 ;;
    --selftest) MODE=selftest; shift ;;
    *) die2 "unknown argument: $1 (usage: check-vendored-charts.sh [--tree DIR] | --selftest)" ;;
  esac
done
if [ "$MODE" = selftest ]; then selftest; exit $?; fi
[ -n "$TREE_ARG" ] || TREE_ARG="$(cd "$(dirname "$0")/.." && pwd)"
check "$TREE_ARG"

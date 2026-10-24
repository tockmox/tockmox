#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# EVERY TRACKED SCRIPT THROUGH SHELLCHECK, ADVISORY, AGAINST A COMMITTED BASELINE (TM-0847).
#
# The repository ships about a hundred bash scripts and none had been linted.
# The first run found 414 findings at the linter's default severity.
# Fixing them all at once would be a large, risky diff across gates that work.
# So this records what is there today in tools/shellcheck-baseline.txt (one line
# per script and code: `path<TAB>SCxxxx<TAB>count`) and reports only what a
# change ADDS. A new finding is a (script, code) pair whose count rose above its
# baseline, so a planted unquoted `$1` (SC2086) in a script that already had one
# still shows.
#
# ADVISORY. It runs as its own job in check-all.yaml with continue-on-error and
# posts each new finding as a warning annotation on the pull request; it is not
# a run_gate line in check-all.sh, because a gate that is allowed to be red is
# not a gate. Turning it blocking is a later decision, once the baseline is small.
#
#   tools/check-shellcheck.sh             report new findings (exit 1 when there are any)
#   tools/check-shellcheck.sh --update    rewrite the baseline from the tree (commit it with the fix)
#   tools/check-shellcheck.sh --selftest  a clean fixture, a planted SC2086, and a baselined one
#
# Exit 0 nothing new, 1 new findings, 2 skipped (shellcheck absent or unable to
# run). Bash 3.2 compatible.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BASELINE="${SHELLCHECK_BASELINE:-tools/shellcheck-baseline.txt}"

have_sc() { command -v shellcheck >/dev/null 2>&1 && shellcheck --version >/dev/null 2>&1; }

# The scripts: every tracked *.sh, or the SHELLCHECK_FILES list (the selftest's).
list_files() {
  # Word splitting is the point here: SHELLCHECK_FILES is a space-separated list.
  # shellcheck disable=SC2086
  if [ -n "${SHELLCHECK_FILES:-}" ]; then printf '%s\n' $SHELLCHECK_FILES
  else git ls-files '*.sh'; fi
}

# gcc-format findings: path:line:col: severity: message [SCxxxx]
findings() { list_files | tr '\n' '\0' | xargs -0 shellcheck -f gcc 2>/dev/null; true; }

# path<TAB>code<TAB>count, sorted, from gcc-format findings on stdin
tally() {
  sed -n 's/^\([^:]*\):[0-9]*:[0-9]*: .*\[\(SC[0-9]*\)\]$/\1	\2/p' | sort | uniq -c \
    | awk '{ printf "%s\t%s\t%s\n", $2, $3, $1 }' | sort
}

report() {  # findings-file baseline-file -> prints new findings; returns 1 when any
  local all="$1" base="$2" new=0 path code count was
  while IFS="$(printf '\t')" read -r path code count; do
    was="$(awk -F '\t' -v p="$path" -v c="$code" '$1 == p && $2 == c { print $3 }' "$base")"
    [ -n "$was" ] || was=0
    if [ "$count" -gt "$was" ]; then
      new=1
      echo "  NEW: $path $code ($was in the baseline, $count now)"
      grep -F "$path:" "$all" | grep -F "[$code]" | while IFS= read -r l; do
        echo "    $l"
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
          f="${l%%:*}"; rest="${l#*:}"; line="${rest%%:*}"
          echo "::warning file=$f,line=$line,title=shellcheck $code (new)::${l#*: }"
        fi
      done
    fi
  done < <(tally < "$all")
  # Entries the tree now has fewer of than recorded (the baseline's # header is not an entry).
  fixed="$(awk -F '\t' 'NR == FNR { now[$1 FS $2] = $3; next }
    /^#/ { next }
    { k = $1 FS $2; if (!(k in now) || now[k] + 0 < $3 + 0) n++ }
    END { print n + 0 }' <(tally < "$all") "$base")"
  [ "$fixed" -eq 0 ] || echo "  $fixed baseline entr(y/ies) now lower than recorded: run --update and commit the smaller baseline"
  return "$new"
}

if [ "${1:-}" = "--selftest" ]; then
  have_sc || { echo "  SKIPPED: shellcheck is not on PATH or cannot run"; exit 2; }
  # A failed mktemp must stop the run: with an empty $tmp the fixtures land in /
  # and every case reads as a pass or fail for reasons that are not the tool's.
  tmp="$(mktemp -d)" && [ -d "$tmp" ] || { echo "  SKIPPED: cannot create a temporary directory"; exit 2; }
  trap 'rm -rf "$tmp"' EXIT
  # shellcheck disable=SC2016  # the fixture needs a literal $1
  printf '#!/usr/bin/env bash\nset -eu\nname="${1:-x}"\necho "hello $name"\n' > "$tmp/clean.sh"
  # shellcheck disable=SC2016  # the fixture needs a literal $1
  printf '#!/usr/bin/env bash\nset -eu\necho hello $1\n' > "$tmp/planted.sh"
  : > "$tmp/empty-baseline"
  fails=0
  run() { SHELLCHECK_FILES="$1" SHELLCHECK_BASELINE="$2" bash "$0" >/dev/null 2>&1; }
  if run "$tmp/clean.sh" "$tmp/empty-baseline"; then echo "  selftest ok: a clean script reports nothing"
  else echo "  SELFTEST FAIL: a clean script reported a finding"; fails=1; fi
  out="$(SHELLCHECK_FILES="$tmp/planted.sh" SHELLCHECK_BASELINE="$tmp/empty-baseline" bash "$0" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep 'NEW: .*planted.sh SC2086' >/dev/null; then
    echo "  selftest ok: a planted unquoted \$1 is a new SC2086"
  else echo "  SELFTEST FAIL: a planted unquoted \$1 was not reported as a new SC2086 (exit $rc)"; fails=1; fi
  SHELLCHECK_FILES="$tmp/planted.sh" SHELLCHECK_BASELINE="$tmp/planted-baseline" bash "$0" --update >/dev/null 2>&1
  if run "$tmp/planted.sh" "$tmp/planted-baseline"; then echo "  selftest ok: the same finding, baselined, reports nothing"
  else echo "  SELFTEST FAIL: a baselined finding was reported as new"; fails=1; fi
  # shellcheck disable=SC2016  # the fixture needs a literal $1
  printf 'echo again $2\n' >> "$tmp/planted.sh"
  if run "$tmp/planted.sh" "$tmp/planted-baseline"; then echo "  SELFTEST FAIL: a second SC2086 in a baselined script was not reported"; fails=1
  else echo "  selftest ok: a second SC2086 in a baselined script is new"; fi
  [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
  echo "selftest FAILED"; exit 1
fi

have_sc || { echo "  SKIPPED: shellcheck is not on PATH or cannot run"; exit 2; }
# A failed mktemp must stop the run: an empty path collects no findings and the
# report would read "nothing new", a pass that checked nothing.
all="$(mktemp)" && [ -f "$all" ] || { echo "  SKIPPED: cannot create a temporary file"; exit 2; }
trap 'rm -f "$all"' EXIT
findings > "$all"

if [ "${1:-}" = "--update" ]; then
  { echo "# shellcheck baseline: path<TAB>code<TAB>count. Written by tools/check-shellcheck.sh --update; see its header."
    tally < "$all"; } > "$BASELINE"
  echo "  wrote $BASELINE: $(tally < "$all" | wc -l | tr -d ' ') entries, $(wc -l < "$all" | tr -d ' ') findings"
  exit 0
fi

[ -f "$BASELINE" ] || { echo "  FAIL: no baseline at $BASELINE; run --update once and commit it"; exit 1; }
echo "  $(list_files | wc -l | tr -d ' ') scripts, $(wc -l < "$all" | tr -d ' ') findings, baseline $(grep -vc '^#' "$BASELINE") entries"
if report "$all" "$BASELINE"; then echo "  ok: nothing new against the baseline"; exit 0; fi
exit 1

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# PROSE THAT COUNTS THINGS MUST STILL BE ABLE TO COUNT THEM.
#
# Everything generated in this repository is checked. `stamp-docs.sh --check`
# catches a stale version footer, the SBOM check catches a stale SBOM, the
# schema checks catch a stale schema. Prose asserting a countable fact about the
# tree was checked by nobody, and it is the highest-value prose on the site: the
# project's whole argument is "source, not binaries, read it", so the sentences
# that name real numbers are the ones a reader quotes back.
#
# The instance that produced this gate: `docs/administration/configuration.md`
# asserted FOUR countable things in one short section ... that no contract
# document existed, that four of the nine schemas were byte-identical, that none
# of them closed the root object, and that Tockmox was at v0.1.0. All four had
# stopped being true, three of them when the values contract landed. The page's
# own footer said 0.6.0 while its body said 0.1.0. An external reviewer found
# one of the four in about four seconds; checking the section against the tree
# found the rest. Nothing had changed the page because nothing re-reads a
# paragraph, and every one of those sentences had been correct when written.
#
# WHY A GATE AND NOT A RELEASE-CHECKLIST LINE. The claims went stale over weeks,
# in ordinary commits, by people improving the tree ... nobody edited the page
# to make it wrong. A checklist item at release time asks a human to re-read
# prose for arithmetic, which is the task humans are worst at and the reason
# this class survives. A check runs on the commit that makes the sentence false,
# and names the sentence.
#
# WHAT THIS IS NOT. Not a prose linter, not a style check, not a spell check,
# and emphatically not a general "does the documentation feel current" tool.
# It reads one file, `tools/doc-claims.txt`, whose entries are hand-written
# because deciding what counts as a claim is a judgement no parser should make.
#
# TWO KINDS OF ENTRY, and the second exists because the first was not enough.
#
#   page:   a SENTENCE somebody remembered to register. Checked exactly as
#           written, on one page.
#   class:  a KIND of countable thing ("N layers", "N images"), measured once
#           from the tree and then compared against EVERY page in scope that
#           states a number for it. A page nobody thought to register is still
#           checked, because the class scans the tree, not a list.
#
# The class form was added 2026-09-04 (TM-0394) after an outside reader found
# three countable contradictions in an hour on a tree this gate was green on.
# All three were in the gate's remit; none was in its list. A registry that
# only checks the claims somebody enumerated is a gate that tests its own list.
# A page can still say "three layers" meaning a subset; that is what `waive:`
# is for, and a waiver has to match something or it fails too, so the waiver
# list cannot rot any more than the registry can.
#
# THE TWO DIRECTIONS, and the second is what stops this rotting.
#
#   1. The command disagrees with the expected value -> the TREE changed and
#      the page is now lying.
#   2. The claim text is no longer on the page -> THIS REGISTRY is lying.
#      Somebody rewrote the sentence and the assertion outlived it, passing
#      happily, guarding a page that no longer says anything of the kind.
#
# Direction 2 is the one that matters over time. An assertion registry that can
# silently detach from its own subject is worse than having none, because it is
# believed. Same failure shape as a probe that cannot distinguish its two
# hypotheses: it keeps reporting PASS and the PASS stops meaning anything.
#
# Usage:
#   tools/check-doc-claims.sh            check every claim
#   tools/check-doc-claims.sh --selftest prove the gate actually refuses
#
# Exit 0 every entry checked and true. Exit 1 something checked is false.
# Exit 2 nothing checked is false but some entries were SKIPPED because their
# test command names a tool that is not installed (see preflight). 2 is never
# a pass: check-all.sh counts it as skipped and a CI step goes red on it.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

CLAIMS="${CLAIMS:-tools/doc-claims.txt}"
# Where tools/render-counts.sh leaves the counts that the render-count claims
# read. Overridable so --selftest can point the script at a fixture.
COUNTS_FILE="${COUNTS_FILE:-build/render-counts.tsv}"
# Exported so the registry's `tools/render-counts.sh --read` tests read the
# same file the preflight verified.
export COUNTS_FILE
# shellcheck source=tools/lib/tool-runs.sh
. tools/lib/tool-runs.sh

# Space-separated tools the preflight found missing. Empty means everything is
# installed and no entry is skipped. --selftest sets it by hand.
MISSING=""
SKIP_TOTAL=0

# needs_missing CMD -> the missing tool(s) CMD names, space-separated, or empty.
# A word match on the COMMAND TEXT, deliberately crude: over-matching only
# skips an entry that could have run, which costs coverage and says so; it can
# never let a claim that needs an absent tool be measured as 0.
needs_missing() {
  local t hit=""
  for t in $MISSING; do
    if grep -qwF -- "$t" <<EOF
$1
EOF
    then hit="$hit $t"; fi
  done
  printf '%s' "${hit# }"
}

# ---------------------------------------------------------------------------
# run_claims FILE
#
# Prints a report to stdout and returns non-zero if anything failed. Kept as a
# function taking a path so --selftest can point it at a fixture rather than at
# the real registry, which is the only way to prove the failure paths without
# breaking the tree to do it.
# ---------------------------------------------------------------------------

# as_number TOKEN -> the integer it denotes, or empty if it denotes none.
# Number words are here because documentation prose spells small counts out;
# "nine layers" is the house style and "9 layers" would read as a change log.
as_number() {
  # Strip markdown emphasis and code ticks first: `**Nine**` is a nine. The
  # first version did not, and a `states:` regex whose first token was bold
  # matched, yielded no number, and asserted nothing (TM-0394 log, 09-03).
  set -- "$(printf '%s' "$1" | tr -d '*_\`')"
  case "$1" in
    zero) echo 0 ;;      one) echo 1 ;;       two) echo 2 ;;
    three) echo 3 ;;     four) echo 4 ;;      five) echo 5 ;;
    six) echo 6 ;;       seven) echo 7 ;;     eight) echo 8 ;;
    nine) echo 9 ;;      ten) echo 10 ;;      eleven) echo 11 ;;
    twelve) echo 12 ;;   thirteen) echo 13 ;; fourteen) echo 14 ;;
    fifteen) echo 15 ;;  sixteen) echo 16 ;;  seventeen) echo 17 ;;
    eighteen) echo 18 ;; nineteen) echo 19 ;; twenty) echo 20 ;;
    *[!0-9]*|'') echo "" ;;
    *) echo "$((10#$1))" ;;
  esac
}

# The pages a `class:` scans when it names no `scope:`. Prose surfaces only.
# CHANGELOG.md is deliberately absent: its numbers are dated history ("at 0.5.0
# there were eight claims"), and a gate that demands history match today's
# tree would force the record to lie.
# THE SCOPE IS A HARD-CODED LIST, AND A HARD-CODED LIST IS ESCAPED BY THE NEXT
# FILE SOMEBODY ADDS. Corrected 2026-09-13. The `class:` mechanism exists
# precisely so a countable claim is caught wherever it is written rather than
# only where it is registered ... and it was scanning a list that had drifted:
# `install/README.md` is named here and does not exist, while CLAUDE.md,
# CODE_OF_CONDUCT.md, TRADEMARKS.md and the .github templates were never in
# scope at all. Demonstrated by appending "This tree ships twelve layers today."
# to CLAUDE.md against a nine-layer tree: the gate passed and never mentioned it.
DOC_SCOPE="${DOC_SCOPE:-docs README.md ROADMAP.md CONTRIBUTING.md SUPPORT.md SECURITY.md AGENTS.md GOVERNANCE.md RELEASING.md CLAUDE.md CODE_OF_CONDUCT.md TRADEMARKS.md bootstrap/README.md charts/*/README.md .github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE tests/executed-docs tests/installer}"

# scan_class MATCH_REGEX SCOPE...
#
# Prints one line per match, tab-separated: path, line, matched text, first
# token. Prose only: fenced blocks, inline code, link targets and YAML
# frontmatter are stripped first, because a number inside a command or a URL
# is not a claim. python3 rather than grep so the fence state survives across
# lines; every other gate in this repo that reads prose does the same.
scan_class() {
  local match="$1"; shift
  MATCH_RE="$match" python3 - "$@" <<'PY'
import glob, os, re, sys
match = re.compile(os.environ['MATCH_RE'], re.I)
paths = []
for arg in sys.argv[1:]:
    for hit in sorted(glob.glob(arg)) or [arg]:
        if os.path.isdir(hit):
            paths += sorted(glob.glob(os.path.join(hit, '**', '*.md'), recursive=True))
        elif os.path.isfile(hit):
            paths.append(hit)
FENCE = re.compile(r'^\s{0,3}(```|~~~)')
for path in dict.fromkeys(paths):
    fence = None; in_fm = False
    with open(path, encoding='utf-8') as fh:
        for n, line in enumerate(fh.read().splitlines(), 1):
            if n == 1 and line.strip() == '---':
                in_fm = True; continue
            if in_fm:
                if line.strip() == '---': in_fm = False
                continue
            if FENCE.match(line):
                fence = None if fence else True; continue
            if fence:
                continue
            text = re.sub(r'`[^`]*`', ' ', line)
            text = re.sub(r'\]\([^)]*\)', '] ', text)
            for m in match.finditer(text):
                hit = m.group(0).strip()
                tok = hit.split()[0].lower() if hit.split() else ''
                print('\t'.join((path, str(n), hit, tok)))
PY
}

run_classes() {
  # CLASSES and WAIVERS are newline-separated records, fields split on the
  # unit separator (\037), filled in by run_claims as it reads the registry.
  local rec cname cmatch ctest cexpect cscope cline got status hits hit
  local path lno text tok num used offenders waived wrec wpage wmatch wwhy wline
  local nclass=0 cbad=0 cskip=0 need
  local us; us=$(printf '\037')
  [ -z "$CLASSES" ] && return 0
  echo
  echo "  classes: every page in scope is checked, registered or not"
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    nclass=$((nclass + 1))
    IFS="$us" read -r cname cmatch ctest cexpect cscope cline <<EOF
$rec
EOF
    # A class whose measuring command names a missing tool is not measured:
    # it would read 0 and flag every correct page in scope (see preflight).
    need=$(needs_missing "$ctest")
    if [ -n "$need" ]; then
      echo "  SKIPPED       class $cname (block at line $cline): test needs $need"
      nclass=$((nclass - 1)); cskip=$((cskip + 1)); continue
    fi
    got=$(eval "$ctest" 2>&1); status=$?
    got=$(printf '%s' "$got" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ "$status" -ne 0 ] && [ -z "$got" ]; then
      echo "  TEST ERROR    class $cname (block at line $cline)"
      echo "                command exited $status with no output: $ctest"
      cbad=$((cbad + 1)); continue
    fi
    if [ "$got" != "$cexpect" ]; then
      echo "  TREE MOVED    class $cname (block at line $cline)"
      echo "                expected: $cexpect   measured: $got   ($ctest)"
      echo "                fix expect: AND every page this class then flags"
      cbad=$((cbad + 1)); continue
    fi
    # shellcheck disable=SC2086
    hits=$(scan_class "$cmatch" ${cscope:-$DOC_SCOPE})
    if [ -z "$hits" ]; then
      echo "  CLASS UNMATCHED  $cname (block at line $cline)"
      echo "                the match pattern hits nothing in scope: $cmatch"
      echo "                an assertion that matches no text asserts nothing"
      cbad=$((cbad + 1)); continue
    fi
    offenders=""; waived=0; used=0
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      IFS="$(printf '\t')" read -r path lno text tok <<EOF
$hit
EOF
      num=$(as_number "$tok")
      [ -z "$num" ] && continue
      used=$((used + 1))
      [ "$num" = "$cexpect" ] && continue
      # A wrong number is acceptable only under a waiver naming the page and
      # matching the phrase. The waiver is recorded as used so an unused one
      # can be refused afterwards.
      local matched_waiver=0 i=0
      while IFS= read -r wrec; do
        i=$((i + 1))
        [ -z "$wrec" ] && continue
        IFS="$us" read -r wpage wmatch wwhy wline <<EOF
$wrec
EOF
        # Compared with emphasis stripped, so `**four** widgets` and
        # `four widgets` are one phrase to a waiver, as they are to as_number.
        # grep without -q under pipefail: -q can exit before printf has
        # finished writing and turn the pipeline red on a match (SIGPIPE),
        # the inversion check-values-tiers.sh already refuses.
        local wm
        wm=$(printf '%s' "$text" | tr -d '*_\`' | grep -iE -- "$wmatch" || true)
        if [ "$wpage" = "$path" ] && [ -n "$wm" ]; then
          matched_waiver=1
          WAIVERS_USED="$WAIVERS_USED $i"
          break
        fi
      done <<EOF
$WAIVERS
EOF
      if [ "$matched_waiver" -eq 1 ]; then waived=$((waived + 1)); continue; fi
      offenders="$offenders    $path:$lno: $text (reads as $num)
"
    done <<EOF
$hits
EOF
    if [ "$used" -eq 0 ]; then
      echo "  CLASS YIELDS NO NUMBER  $cname (block at line $cline)"
      echo "                pattern matches text but never a count: $cmatch"
      cbad=$((cbad + 1)); continue
    fi
    if [ -n "$offenders" ]; then
      echo "  PAGE CONTRADICTS THE TREE  class $cname"
      echo "                tree measures: $cexpect   ($ctest)"
      printf '%s' "$offenders"
      echo "                fix the page if the tree is right; add a waive: block"
      echo "                naming the page and phrase if the number is a subset"
      cbad=$((cbad + 1)); continue
    fi
    printf '  ok  class %-40s %s stated %s time(s), %s waived\n' "$cname" "$cexpect" "$used" "$waived"
  done <<EOF
$CLASSES
EOF
  # Direction 2 for waivers: one that matches nothing is guarding a phrase
  # that no longer exists, and the next wrong number under it would be
  # excused by accident.
  i=0
  while IFS= read -r wrec; do
    i=$((i + 1))
    [ -z "$wrec" ] && continue
    case " $WAIVERS_USED " in *" $i "*) continue ;; esac
    IFS="$us" read -r wpage wmatch wwhy wline <<EOF
$wrec
EOF
    # With a class skipped, an unused waiver may belong to that class, so
    # "unused" cannot be judged. Reported and counted as skipped, not failed
    # and not passed.
    if [ "$cskip" -gt 0 ]; then
      echo "  SKIPPED       waiver $wpage (block at line $wline): unused, but a skipped class may be its user"
      cskip=$((cskip + 1)); continue
    fi
    echo "  WAIVER UNUSED  $wpage (block at line $wline)"
    echo "                no class flagged a phrase matching: $wmatch"
    echo "                the sentence moved or the number now agrees; delete the waiver"
    cbad=$((cbad + 1))
  done <<EOF
$WAIVERS
EOF
  if [ "$cskip" -gt 0 ]; then
    echo "  $nclass class(es) checked, $cskip skipped, $cbad failing"
  else
    echo "  $nclass class(es) checked, $cbad failing"
  fi
  SKIP_TOTAL=$((SKIP_TOTAL + cskip))
  [ "$cbad" -eq 0 ] || return 1
  [ "$cskip" -eq 0 ] || return 2
  return 0
}

run_claims() {
  local file="$1"
  local page="" claim="" test_cmd="" expect="" states="" have_expect=0
  local cname="" cmatch="" cscope="" wpage="" wwhy=""
  local n=0 bad=0 skip=0 lineno=0 blockline=0
  local us; us=$(printf '\037')
  CLASSES=""; WAIVERS=""; WAIVERS_USED=""; SKIP_TOTAL=0

  # One block per claim, blank-line separated. Read with IFS= and -r so a
  # command keeps its own spacing; `|| [ -n "$line" ]` so a final block with no
  # trailing newline is not silently dropped -- that would lose the LAST entry,
  # in the passing direction.
  finish_block() {
    [ -z "$page$claim$test_cmd$expect$states$cname$cmatch$cscope$wpage$wwhy" ] && return 0
    if [ -n "$cname" ]; then
      if [ -z "$cmatch" ] || [ -z "$test_cmd" ] || [ "$have_expect" -eq 0 ]; then
        echo "  INCOMPLETE (class block at line $blockline): needs class, match, test and expect"
        bad=$((bad + 1)); return 0
      fi
      CLASSES="$CLASSES$cname$us$cmatch$us$test_cmd$us$expect$us$cscope$us$blockline
"
      return 0
    fi
    if [ -n "$wpage" ]; then
      if [ -z "$cmatch" ] || [ -z "$wwhy" ]; then
        echo "  INCOMPLETE (waive block at line $blockline): needs waive, match and why"
        bad=$((bad + 1)); return 0
      fi
      if [ ! -f "$wpage" ]; then
        echo "  MISSING PAGE  $wpage (waive block at line $blockline)"
        bad=$((bad + 1)); return 0
      fi
      WAIVERS="$WAIVERS$wpage$us$cmatch$us$wwhy$us$blockline
"
      return 0
    fi
    n=$((n + 1))

    if [ -z "$page" ] || [ -z "$claim" ] || [ -z "$test_cmd" ] || [ "$have_expect" -eq 0 ]; then
      echo "  INCOMPLETE (block at line $blockline): needs page, claim, test and expect"
      bad=$((bad + 1)); return 0
    fi

    if [ ! -f "$page" ]; then
      echo "  MISSING PAGE  $page (block at line $blockline)"
      echo "                the registry names a file that does not exist"
      bad=$((bad + 1)); return 0
    fi

    # Direction 2 first, deliberately. If the sentence is gone there is no
    # point reporting on a number nobody is claiming any more, and reporting
    # the arithmetic first would bury the real defect.
    if ! grep -qF -- "$claim" "$page"; then
      echo "  CLAIM GONE    $page"
      echo "                registry expects the page to say: \"$claim\""
      echo "                it does not. Either the sentence was rewritten and this"
      echo "                entry must follow it, or the claim was dropped and this"
      echo "                entry should be deleted. Do not just delete the entry"
      echo "                without reading what replaced the sentence."
      bad=$((bad + 1)); return 0
    fi

    # PARTITION, NOT RELAX (TM-0713). Everything above needs only the page
    # and grep, so a registry entry that has detached from its sentence is
    # still refused with the tool absent. The measurement below is what the
    # missing tool would falsify, so it alone is skipped, by name.
    local need
    need=$(needs_missing "$test_cmd")
    if [ -n "$need" ]; then
      echo "  SKIPPED       $page (block at line $blockline): test needs $need"
      echo "                claim: \"$claim\""
      n=$((n - 1)); skip=$((skip + 1)); return 0
    fi

    local got status
    got=$(eval "$test_cmd" 2>&1); status=$?
    got=$(printf '%s' "$got" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ "$status" -ne 0 ] && [ -z "$got" ]; then
      echo "  TEST ERROR    $page"
      echo "                command exited $status with no output: $test_cmd"
      bad=$((bad + 1)); return 0
    fi

    if [ "$got" != "$expect" ]; then
      echo "  FALSE CLAIM   $page"
      echo "                says:     \"$claim\""
      echo "                expected: $expect"
      echo "                measured: $got"
      echo "                command:  $test_cmd"
      bad=$((bad + 1)); return 0
    fi

    # ------------------------------------------------------------------
    # `states` -- the half that actually catches a page contradicting the tree.
    #
    # `claim` above only proves the sentence is still SOMEWHERE on the page,
    # and that is not enough. The first version of this gate had only the two
    # checks above, and it PASSED its own poison test: the headline of
    # what-you-get.md was changed from "nine layers" to "ten layers" and the
    # gate said ok, because the tree still had nine layers and the string
    # "nine layers" still occurred twice further down. A green probe that tests
    # the easy path is worse than no probe.
    #
    # `states` is a regex matched against every line of the page. The FIRST
    # TOKEN of each match is read as the number the page is asserting, and it
    # must equal what the tree measured. Every occurrence is checked, so a
    # page cannot drift in one paragraph and stay honest in another.
    #
    # A match whose first token is not a number is IGNORED -- "upstream charts"
    # is not a count. That is a deliberate hole with a floor under it: a WRONG
    # count written in digits or as a number word up to twenty is always read,
    # so nothing false escapes that way. Above twenty the floor is gone:
    # "twenty-one layers" yields no number and is skipped. The house style
    # writes counts above twenty in digits, and the YIELDS NO NUMBER guard
    # below refuses an entry that never reads a number at all. A page that says
    # "several layers" is unclaimable rather than unchecked.
    if [ -n "$states" ]; then
      local hits offenders line_out tok num
      offenders=""
      hits=$(grep -noiE -- "$states" "$page" 2>/dev/null || true)
      if [ -z "$hits" ]; then
        echo "  STATES UNMATCHED  $page"
        echo "                the states pattern matches nothing: $states"
        echo "                an assertion that matches no text asserts nothing"
        bad=$((bad + 1)); return 0
      fi
      local numeric=0
      while IFS= read -r line_out; do
        [ -z "$line_out" ] && continue
        tok=$(printf '%s' "${line_out#*:}" | awk '{print tolower($1)}')
        num=$(as_number "$tok")
        [ -z "$num" ] && continue
        numeric=$((numeric + 1))
        [ "$num" = "$expect" ] && continue
        offenders="$offenders    line ${line_out%%:*}: ${line_out#*:} (reads as $num)
"
      done <<EOF
$hits
EOF
      # Matching text is not the same as asserting a number. A pattern that
      # only ever matches "upstream layers" reads as ok while checking nothing,
      # which is the STATES UNMATCHED hole one step further in.
      if [ "$numeric" -eq 0 ]; then
        echo "  STATES YIELDS NO NUMBER  $page"
        echo "                pattern matches text but never a count: $states"
        echo "                widen the pattern so its first token is the number, or drop it"
        bad=$((bad + 1)); return 0
      fi
      if [ -n "$offenders" ]; then
        echo "  PAGE CONTRADICTS THE TREE  $page"
        echo "                tree measures: $expect   ($test_cmd)"
        printf '%s' "$offenders"
        bad=$((bad + 1)); return 0
      fi
    fi

    printf '  ok  %-46s %s\n' "$page" "$claim"
  }

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      '#'*) continue ;;
    esac
    if [ -z "${line//[[:space:]]/}" ]; then
      finish_block
      page=""; claim=""; test_cmd=""; expect=""; states=""; have_expect=0; blockline=0
      cname=""; cmatch=""; cscope=""; wpage=""; wwhy=""
      continue
    fi
    [ "$blockline" -eq 0 ] && blockline=$lineno
    # Split on the FIRST colon only: a test command routinely contains colons.
    local key val
    key="${line%%:*}"; val="${line#*:}"
    val="${val#"${val%%[![:space:]]*}"}"
    case "$key" in
      page)   page="$val" ;;
      claim)  claim="$val" ;;
      test)   test_cmd="$val" ;;
      expect) expect="$val"; have_expect=1 ;;
      states) states="$val" ;;
      class)  cname="$val" ;;
      match)  cmatch="$val" ;;
      scope)  cscope="$val" ;;
      waive)  wpage="$val" ;;
      why)    wwhy="$val" ;;
      *)      echo "  UNKNOWN KEY   line $lineno: ${key}"; bad=$((bad + 1)) ;;
    esac
  done < "$file"
  finish_block

  echo
  if [ "$skip" -gt 0 ]; then
    echo "  $n claim(s) checked, $skip skipped, $bad failing"
  else
    echo "  $n claim(s) checked, $bad failing"
  fi
  local classes_rc=0; run_classes || classes_rc=$?
  SKIP_TOTAL=$((SKIP_TOTAL + skip))
  # 1 beats 2: a finding among the entries that DID run is a finding.
  { [ "$bad" -eq 0 ] && [ "$classes_rc" -ne 1 ]; } || return 1
  { [ "$skip" -eq 0 ] && [ "$classes_rc" -eq 0 ]; } || return 2
  return 0
}

# ---------------------------------------------------------------------------
# selftest
#
# A gate that has never been observed refusing is decoration. This proves all
# three refusal paths and the accept path, against fixtures, so it costs
# nothing and needs no cluster.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  # A failed mktemp left $tmp empty and every fixture was written to / and
  # refused, so probes wanting "pass" still passed (observed 2026-09-23 on a
  # full disk). Refuse instead: a selftest with no fixtures proves nothing.
  tmp=$(mktemp -d) && [ -d "$tmp" ] || { echo "selftest: CANNOT RUN ... mktemp -d failed"; exit 2; }
  trap 'rm -rf "$tmp"' EXIT
  fails=0

  mkdir -p "$tmp/docs"
  printf 'The tree ships three widgets today.\n' > "$tmp/docs/page.md"

  # probe LABEL WANT BODY [WHY]
  #
  # WANT is pass (exit 0), fail (exit 1) or skip (exit 2), matched EXACTLY.
  # WHY, when given, is a string the report must contain. A want-fail probe
  # that only checks "non-zero" passes when run_claims dies for ANY reason,
  # including one that means the check under test never ran (TM-0713 log,
  # 2026-09-17). So a refusal must be the refusal the probe is about.
  probe() {
    local label="$1" want="$2" body="$3" why="${4:-}" out rc wrc
    printf '%s\n' "$body" > "$tmp/claims.txt"
    out=$( cd "$tmp" && run_claims claims.txt 2>&1 ); rc=$?
    case "$want" in pass) wrc=0 ;; fail) wrc=1 ;; skip) wrc=2 ;; esac
    if [ "$rc" -ne "$wrc" ]; then
      echo "  SELFTEST FAIL: '$label' wanted $want (exit $wrc), got exit $rc:"
      printf '%s\n' "$out" | sed 's/^/            /'; fails=1
    elif [ -n "$why" ] && ! printf '%s\n' "$out" | grep -F -- "$why" >/dev/null; then
      echo "  SELFTEST FAIL: '$label' exited $rc but not for the reason '$why':"
      printf '%s\n' "$out" | sed 's/^/            /'; fails=1
    else
      echo "  selftest ok: $label"
    fi
  }

  probe "a true claim passes" pass \
"page:   docs/page.md
claim:  three widgets
test:   echo 3
expect: 3"

  probe "a false count is refused" fail \
"page:   docs/page.md
claim:  three widgets
test:   echo 4
expect: 3" \
  "FALSE CLAIM"

  # The direction that keeps the registry honest.
  probe "a claim no longer on the page is refused" fail \
"page:   docs/page.md
claim:  seventeen widgets
test:   echo 3
expect: 3" \
  "CLAIM GONE"

  # THE CASE THAT CAUGHT THE FIRST VERSION OF THIS GATE OUT. The page still
  # contains the claim string further down, and the tree still measures 3, and
  # the headline has been edited to say something else. Only `states` sees it.
  printf 'Today ... four widgets, shipped.\nThe three widgets are listed below.\n' \
    > "$tmp/docs/drift.md"
  probe "a page contradicting itself and the tree is refused" fail \
"page:   docs/drift.md
claim:  three widgets
test:   echo 3
expect: 3
states: [A-Za-z0-9]+ widgets" \
  "PAGE CONTRADICTS THE TREE"

  # And the same entry must PASS once the page agrees, or the check above is
  # just a pattern that always fires.
  printf 'Today ... three widgets, shipped.\nThe three widgets are listed below.\n' \
    > "$tmp/docs/drift.md"
  probe "the same states entry passes when the page agrees" pass \
"page:   docs/drift.md
claim:  three widgets
test:   echo 3
expect: 3
states: [A-Za-z0-9]+ widgets"

  # A non-numeric first token is ignored rather than failing: "upstream charts"
  # is not a count. Proving this keeps the exemption honest and visible.
  printf 'Today ... three widgets.\nWe also use upstream widgets.\n' \
    > "$tmp/docs/drift.md"
  probe "a non-numeric match is ignored, not failed" pass \
"page:   docs/drift.md
claim:  three widgets
test:   echo 3
expect: 3
states: [A-Za-z0-9]+ widgets"

  # A states pattern that matches nothing asserts nothing, and must be refused
  # rather than passing quietly. Same class as a probe wired to nothing.
  probe "a states pattern matching nothing is refused" fail \
"page:   docs/drift.md
claim:  three widgets
test:   echo 3
expect: 3
states: [A-Za-z0-9]+ sprockets" \
  "STATES UNMATCHED"

  probe "a page that does not exist is refused" fail \
"page:   docs/gone.md
claim:  three widgets
test:   echo 3
expect: 3" \
  "MISSING PAGE"

  probe "an incomplete block is refused" fail \
"page:   docs/page.md
claim:  three widgets
test:   echo 3" \
  "INCOMPLETE"

  # A block with no trailing newline must still be checked. Dropping it would
  # lose the last entry in the file, silently, in the passing direction.
  printf 'page:   docs/page.md\nclaim:  three widgets\ntest:   echo 9\nexpect: 3' > "$tmp/claims.txt"
  if ( cd "$tmp" && run_claims claims.txt >/dev/null 2>&1 ); then
    echo "  SELFTEST FAIL: a final block with no trailing newline was skipped"; fails=1
  else
    echo "  selftest ok: the last block is checked even with no trailing newline"
  fi

  # ---- classes and waivers (2026-09-04, TM-0394) ----------------------------
  # Two pages in scope, neither registered as a page entry. The class must see
  # both, which is the whole point: a page nobody enumerated is still checked.
  printf 'The tree ships three widgets today.\n' > "$tmp/docs/page.md"
  printf '# Other\n\nAll three widgets are listed here.\n' > "$tmp/docs/other.md"
  probe "a class whose every page agrees passes" pass \
"class:  widgets
match:  [A-Za-z0-9*]+ widgets
test:   echo 3
expect: 3"

  printf '# Other\n\nWe ship **four** widgets, or was it four widgets.\n' > "$tmp/docs/other.md"
  probe "an UNREGISTERED page contradicting the class is refused" fail \
"class:  widgets
match:  [A-Za-z0-9*]+ widgets
test:   echo 3
expect: 3" \
  "docs/other.md:3"

  probe "the same page passes under a waiver naming it and the phrase" pass \
"class:  widgets
match:  [A-Za-z0-9*]+ widgets
test:   echo 3
expect: 3

waive:  docs/other.md
match:  ^four widgets$
why:    the four in the demo subset, not the shipped count"

  printf '# Other\n\nAll three widgets are listed here.\n' > "$tmp/docs/other.md"
  probe "a waiver that matches nothing is refused" fail \
"class:  widgets
match:  [A-Za-z0-9*]+ widgets
test:   echo 3
expect: 3

waive:  docs/other.md
match:  ^four widgets$
why:    a sentence that no longer exists" \
  "WAIVER UNUSED"

  probe "a class whose tree measurement moved is refused" fail \
"class:  widgets
match:  [A-Za-z0-9*]+ widgets
test:   echo 4
expect: 3" \
  "TREE MOVED"

  probe "a class matching nothing in scope is refused" fail \
"class:  sprockets
match:  [A-Za-z0-9*]+ sprockets
test:   echo 3
expect: 3" \
  "CLASS UNMATCHED"

  # Numbers inside a fence or inline code are commands, not claims.
  printf '# Other\n\n```bash\necho nine widgets\n```\n\nRun `ls nine widgets` then read the three widgets.\n' > "$tmp/docs/other.md"
  probe "a count inside a fence or inline code is not a claim" pass \
"class:  widgets
match:  [A-Za-z0-9*]+ widgets
test:   echo 3
expect: 3"

  # Emphasis around the number is still a number: **Nine** widgets reads as 9.
  printf 'The tree ships **three** widgets.\n' > "$tmp/docs/page.md"
  printf '# Other\n' > "$tmp/docs/other.md"
  probe "a bold count is read as a number, not skipped" pass \
"page:   docs/page.md
claim:  widgets
test:   echo 3
expect: 3
states: [A-Za-z0-9*]+ widgets"
  printf 'The tree ships **four** widgets.\n' > "$tmp/docs/page.md"
  probe "a bold WRONG count is refused, not skipped" fail \
"page:   docs/page.md
claim:  widgets
test:   echo 3
expect: 3
states: [A-Za-z0-9*]+ widgets" \
  "(reads as 4)"

  # A states pattern that matches text but never a number asserts nothing and
  # must say so. This is the exact shape two registry entries carried for a
  # day (`ci.yaml runs [0-9]+ gates`: first token "ci.yaml").
  printf 'The tree ships three widgets today.\n' > "$tmp/docs/page.md"
  probe "a states pattern that yields no number is refused" fail \
"page:   docs/page.md
claim:  three widgets
test:   echo 3
expect: 3
states: ships [A-Za-z0-9]+ widgets" \
  "STATES YIELDS NO NUMBER"

  # ---- a missing tool partitions, it does not refuse wholesale (TM-0713) ----
  # MISSING is set by hand: the probes must behave the same whether or not
  # the machine running --selftest has helm.
  printf 'The tree ships three widgets today.\n' > "$tmp/docs/page.md"
  printf '# Other\n\nAll three widgets are listed here.\n' > "$tmp/docs/other.md"
  MISSING="helm"
  probe "a claim whose test needs a missing tool is skipped by name, not measured" skip \
"page:   docs/page.md
claim:  three widgets
test:   helm template x 2>/dev/null | grep -c widget
expect: 3" \
  "SKIPPED       docs/page.md (block at line 1): test needs helm"

  # THE CARD'S TEST. One claim needs the absent tool, one does not and is
  # false: the gate must go red on the one it can measure.
  probe "a false claim is still refused while a sibling is skipped" fail \
"page:   docs/page.md
claim:  three widgets
test:   helm template x 2>/dev/null | grep -c widget
expect: 3

page:   docs/page.md
claim:  three widgets
test:   echo 4
expect: 3" \
  "FALSE CLAIM"

  # The registry-detached direction needs no tool, so it is not skipped.
  probe "a claim gone from its page is refused even when its test is skipped" fail \
"page:   docs/page.md
claim:  seventeen widgets
test:   helm template x 2>/dev/null | grep -c widget
expect: 3" \
  "CLAIM GONE"

  probe "a class whose test needs a missing tool is skipped, and its waiver is not judged" skip \
"class:  widgets
match:  [A-Za-z0-9*]+ widgets
test:   helm template x 2>/dev/null | grep -c widget
expect: 3

waive:  docs/other.md
match:  ^four widgets$
why:    belongs to the skipped class" \
  "unused, but a skipped class may be its user"

  # And the partition is conditional: with nothing missing, the same word in
  # a test command skips nothing.
  MISSING=""
  probe "with no tool missing, nothing is skipped" pass \
"page:   docs/page.md
claim:  three widgets
test:   echo helm >/dev/null; echo 3
expect: 3"

  # ---- the whole script, run as a user would (end to end) -------------------
  # Everything above drives run_claims with MISSING set by hand. The two cases
  # below are about what the script itself finds out about its machine before
  # run_claims starts, so they run the script, with a fixture registry and a
  # fixture PATH, and read its exit status and report.
  printf 'The tree ships three widgets today.\n' > "$tmp/docs/page.md"
  mkdir -p "$tmp/bin-empty" "$tmp/bin-broken" "$tmp/bin-noexec" "$tmp/bin-good"

  # selfprobe LABEL WANT WHY FORBIDDEN COUNTS_FILE PATH_PREFIX BODY
  #   COUNTS_FILE is where the script is told to look for the render counts.
  #   FORBIDDEN, when given, is a string the report must NOT contain.
  selfprobe() {
    local label="$1" want="$2" why="$3" forbid="$4" counts="$5" pfx="$6" body="$7" out rc wrc
    printf '%s\n' "$body" > "$tmp/self-claims.txt"
    # A fixture PATH is HERMETIC: the fixture dir, then only /usr/bin:/bin. Prepending
    # to the caller's PATH is not enough, because `command -v` skips a file that is
    # not executable and then finds the machine's own helm further along, which
    # runs and reads 0 (a Mac with Homebrew helm failed the noexec probe that way).
    local p="$PATH"; [ -n "$pfx" ] && p="$pfx:/usr/bin:/bin"
    out=$(CLAIMS="$tmp/self-claims.txt" COUNTS_FILE="$counts" PATH="$p" "$BASH" "$SELF" 2>&1); rc=$?
    case "$want" in pass) wrc=0 ;; fail) wrc=1 ;; skip) wrc=2 ;; esac
    if [ "$rc" -ne "$wrc" ]; then
      echo "  SELFTEST FAIL: '$label' wanted $want (exit $wrc), got exit $rc:"
      printf '%s\n' "$out" | sed 's/^/            /'; fails=1
    elif [ -n "$why" ] && ! printf '%s\n' "$out" | grep -F -- "$why" >/dev/null; then
      echo "  SELFTEST FAIL: '$label' exited $rc but not for the reason '$why':"
      printf '%s\n' "$out" | sed 's/^/            /'; fails=1
    elif [ -n "$forbid" ] && printf '%s\n' "$out" | grep -F -- "$forbid" >/dev/null; then
      echo "  SELFTEST FAIL: '$label' reported '$forbid', which accuses a page that is right:"
      printf '%s\n' "$out" | sed 's/^/            /'; fails=1
    else
      echo "  selftest ok: $label"
    fi
  }

  # A render-count claim, whose test reads the file tools/render-counts.sh
  # writes. The trailing comment makes the test command name that script the
  # way the real registry's entries do, and the echo stands in for the count.
  COUNT_CLAIM="page:   $tmp/docs/page.md
claim:  three widgets
test:   echo 4 # tools/render-counts.sh --read total
expect: 3"
  # A counts file that describes THIS tree (its fingerprint is the tree's), and
  # one that describes another. The preflight verifies the file, so an empty
  # stand-in would read as stale.
  printf 'total\t4\nfingerprint\t%s\n' "$("$BASH" tools/render-counts.sh --fingerprint)" > "$tmp/counts.tsv"
  printf 'total\t3\nfingerprint\tdeadbeefdeadbeef\n' > "$tmp/stale-counts.tsv"

  selfprobe "an absent render-counts file is a missing precondition, not a false claim" skip \
    "$tmp/no-such-counts.tsv" "FALSE CLAIM" "$tmp/no-such-counts.tsv" "" "$COUNT_CLAIM"
  selfprobe "a render-counts file from another tree is a missing precondition, not a false claim" skip \
    "describes another tree" "FALSE CLAIM" "$tmp/stale-counts.tsv" "" "$COUNT_CLAIM"
  selfprobe "with the render-counts file present, a changed count is still a false claim" fail \
    "FALSE CLAIM" "" "$tmp/counts.tsv" "" "$COUNT_CLAIM"
  selfprobe "an absent render-counts file does not hide a false claim that needs no file" fail \
    "FALSE CLAIM" "" "$tmp/no-such-counts.tsv" "" "$COUNT_CLAIM

page:   $tmp/docs/page.md
claim:  three widgets
test:   echo 4
expect: 3"

  # ---- a tool that is on PATH but cannot run ------------------------------
  # `command -v` says a file is there, not that it executes. A helm built for
  # another architecture passes it, every `helm template ... 2>/dev/null |
  # grep -c` then reads 0, and the report accused correct pages.
  HELM_CLAIM="page:   $tmp/docs/page.md
claim:  three widgets
test:   helm template x 2>/dev/null | grep -c widget
expect: 3"
  printf '\177ELF not a program for this machine\n' > "$tmp/bin-broken/helm"; chmod +x "$tmp/bin-broken/helm"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin-noexec/helm"; chmod -x "$tmp/bin-noexec/helm"
  printf '#!/bin/sh\n[ "$1" = version ] && { echo v3.0.0; exit 0; }\necho widget; echo widget; echo widget\n' > "$tmp/bin-good/helm"; chmod +x "$tmp/bin-good/helm"
  # Each fixture runs with a hermetic PATH (see selfprobe), so a real helm on the
  # machine can neither shadow nor be shadowed by the fixture.
  selfprobe "a helm that is on PATH and cannot execute is refused as unrunnable, not measured as 0" skip \
    "cannot run" "FALSE CLAIM" "$tmp/counts.tsv" "$tmp/bin-broken" "$HELM_CLAIM"
  selfprobe "a helm that is not executable is refused, not measured as 0" skip \
    "" "FALSE CLAIM" "$tmp/counts.tsv" "$tmp/bin-noexec" "$HELM_CLAIM"
  selfprobe "a helm that runs is measured" pass \
    "" "" "$tmp/counts.tsv" "$tmp/bin-good" "$HELM_CLAIM"

  [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
  echo "selftest FAILED"; exit 1
fi

if [ ! -f "$CLAIMS" ]; then
  echo "check-doc-claims: $CLAIMS not found"
  exit 1
fi

# ---------------------------------------------------------------- preflight
#
# A MISSING TOOL MUST NOT BE REPORTED AS A FALSE CLAIM. Measured 2026-09-13: in
# a sandbox with no `helm`, five entries reported "FALSE CLAIM ... expected 33,
# measured 0" and named three innocent pages. The `2>/dev/null` those test
# commands carry sent "helm: command not found" to the void, and a counting
# `grep -c` on the empty stream printed 0 and exited clean, so the harness had
# nothing left to distinguish a broken runner from a wrong page. Every layer of
# the pipeline behaved as written, and the result was a confident accusation
# against correct documentation.
#
# This is the INFRA_ERROR-versus-PRODUCT_FAIL distinction the executed-docs
# harness already draws in `tests/executed-docs/lib/assert.sh`, arriving here.
# Exit 2 is "could not run" and is not exit 1 -- a caller must never read this
# gate's inability to run as a finding about the documentation.
#
# PARTITION RATHER THAN REFUSE WHOLESALE (TM-0713, 2026-09-17). Until then a
# missing tool stopped the whole gate: in a sandbox with no helm not one entry
# was read, while only seven of the 32 page claims (none of the 8 classes)
# name helm. Three stale counts got past it there and were caught downstream,
# by check-all.sh on a Mac, before commit. The premise above is kept whole:
# an entry whose test names a missing tool is never measured. It is SKIPPED BY
# NAME instead, everything else runs, and both counts print. Exit is 1 if a
# checked entry is false, else 2 while anything was skipped: a partial run is
# never a pass.
# Whether a tool EXECUTES, not merely exists on PATH, is answered by
# tool_state/tool_runs in tools/lib/tool-runs.sh, shared with the other gates
# that partition on a missing tool.
preflight() {
  local t absent="" broken="" nocounts=0
  for t in $(grep '^test:' "$CLAIMS" \
             | grep -oE '\b(helm|jq|yq|python3|kubectl|awk|find|xargs)\b' \
             | sort -u); do
    if ! command -v "$t" >/dev/null 2>&1; then
      absent="$absent $t"
    elif ! tool_runs "$t"; then
      broken="$broken $t"
    fi
  done
  absent="${absent# }"; broken="${broken# }"
  # The render-count claims read a file another script writes. Run standalone
  # in a clean clone it is not there, and every one of them would read
  # "MISSING (...)" and be reported as a false claim against a correct page.
  # A file left over from an earlier tree is the same precondition, not met:
  # each read prints "STALE (...)", which was reported as a false claim too.
  # render-counts.sh --verify is the one judge of both.
  local why=""
  if grep '^test:' "$CLAIMS" | grep 'render-counts\.sh' >/dev/null \
     && ! why="$("$BASH" tools/render-counts.sh --verify 2>&1)"; then
    nocounts=1
  fi
  MISSING="$absent${absent:+${broken:+ }}$broken"
  [ "$nocounts" -eq 1 ] && MISSING="${MISSING:+$MISSING }render-counts.sh"
  [ -z "$MISSING" ] && return 0
  echo "check-doc-claims: PARTIAL RUN"
  [ -n "$absent" ] && echo "  missing tool(s), not on PATH: $absent"
  [ -n "$broken" ] && echo "  on PATH but cannot run (wrong architecture, missing interpreter, broken install): $broken"
  [ "$nocounts" -eq 1 ] && echo "  missing precondition: render counts not usable for this tree: ${why:-$COUNTS_FILE unreadable}"
  echo
  echo "  These are used by test commands in $CLAIMS, several of which redirect"
  echo "  stderr and pipe into a counting grep, or read a file another script"
  echo "  writes. Without the tool, or the file, such a test measures as 0 or as"
  echo "  MISSING and would accuse a correct page, so every entry whose test needs"
  echo "  one of them is SKIPPED below, by name. Every other entry is checked as"
  echo "  usual. This run cannot pass: it exits 1 on a finding and 2 otherwise."
  echo
}
preflight

echo "checking documented claims against the tree ($CLAIMS)"
run_claims "$CLAIMS"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "check-doc-claims: PASSED"
  exit 0
fi
if [ "$rc" -eq 2 ]; then
  echo
  echo "check-doc-claims: INCOMPLETE ... $SKIP_TOTAL skipped (named above), missing: $MISSING"
  echo
  echo "  Everything that could be checked without them is true. The SKIPPED"
  echo "  lines above name what was not checked. Exit 2: not a pass. Install"
  echo "  the tool(s), or run tools/render-counts.sh, and re-run for a full result."
  exit 2
fi
if [ "$SKIP_TOTAL" -gt 0 ]; then
  echo
  echo "  ($SKIP_TOTAL more skipped, named above, for: $MISSING)"
fi

cat <<'FAIL'

check-doc-claims: FAILED

A documentation page states something countable about this tree that the tree
contradicts, or the registry has detached from the page it claims to guard.

Fix the PAGE if the tree is right. Fix tools/doc-claims.txt if the sentence
moved. Deleting the entry is right only when the claim itself is gone from the
documentation ... and if you find yourself deleting entries to get a green
build, that is this gate working and being ignored.
FAIL
exit 1

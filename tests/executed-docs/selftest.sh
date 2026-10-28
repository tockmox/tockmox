#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic self-test for the harness's own machinery. No cluster, no network.
#
# This is the ONE part of the executed-documentation harness that belongs in the
# per-commit gate, and the split is the point of testing-standard rule 6: what
# decides cadence is hermeticity and runtime, not what layer of a pyramid
# something sits in. Extracting a code block from a markdown file is hermetic
# and takes milliseconds. Running that block against a cluster is neither.
#
# What it proves: the extractor returns the page's bytes, and REFUSES rather
# than returning nothing when it cannot. That second half is the whole reason
# this file exists. An extractor that silently yields an empty string turns
# every path in this harness into a step that exits zero having examined
# nothing, which is the exact failure testing-standard rule 1 was written about
# and which this repository has already shipped once.
#
#   ./tests/executed-docs/selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
E="${HERE}/lib/extract-block.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

FIXTURE="${TMP}/page.md"
cat >"$FIXTURE" <<'MD'
# A page

## Section one

Prose that is not a command.

```bash
first command
  continued --with-a-flag
```

Then a second block in the same section.

```bash
second command
```

### A sub-section under section one

```bash
third command, still inside section one
```

## Section one, continued after a commented block

```bash
# This comment starts with a hash and is INSIDE a fence.
# An extractor that tracks fence state only for the block it wants will read
# these as markdown headings and silently truncate the section here.
commented block command
```

```bash
the block after the commented one
```

## Section two

```bash
a command in a different section
```

## Section three

```console
$ this is a transcript, not an instruction
```

## Section four

## Section five

```bash
```
MD

# --- 1. it returns the bytes, exactly --------------------------------------
got="$(bash "$E" --file "$FIXTURE" --section '## Section one' --lang bash --block 1 2>/dev/null)"
want="$(printf 'first command\n  continued --with-a-flag')"
if [ "$got" = "$want" ]; then ok "extracts block 1 verbatim, including the continuation line"
else bad "extracts block 1 verbatim" "got: [${got}]"; fi

# --- 2. block selection is 1-based and counts within the section ------------
got="$(bash "$E" --file "$FIXTURE" --section '## Section one' --lang bash --block 2 2>/dev/null)"
if [ "$got" = "second command" ]; then ok "block 2 is the second block in the section"
else bad "block 2 selection" "got: [${got}]"; fi

# --- 3. a sub-section is part of its parent section ------------------------
# A reader following "## Section one" walks through its sub-sections too, so the
# extractor has to agree with that reading or the block numbering in every path
# script drifts the first time someone adds a heading.
got="$(bash "$E" --file "$FIXTURE" --section '## Section one' --lang bash --block 3 2>/dev/null)"
if [ "$got" = "third command, still inside section one" ]; then ok "sub-sections belong to the parent section"
else bad "sub-section containment" "got: [${got}]"; fi

# --- 3b. a '#' comment inside a code block is not a heading ----------------
# Regression test for a silent-truncation bug found 2026-09-02 while verifying a
# handover document: the extractor tracked fence state only for the block it was
# capturing, so a shell comment in ANY earlier block ended the section. It
# reported "fewer than 2 blocks" for a real page section that had three, which
# reads as "the page changed" and sends the reader off to edit a correct script.
got="$(bash "$E" --file "$FIXTURE" --section '## Section one, continued after a commented block' --lang bash --block 2 2>/dev/null)"
if [ "$got" = "the block after the commented one" ]; then
  ok "a '#' comment inside a fenced block does not end the section"
else
  bad "comment-in-fence truncation" "got: [${got}]"
fi

# And the commented block itself still extracts with its comments intact, since
# those lines are part of the command a reader would run.
got="$(bash "$E" --file "$FIXTURE" --section '## Section one, continued after a commented block' --lang bash --block 1 2>/dev/null)"
case "$got" in
  *"# This comment starts with a hash"*"commented block command") ok "comments inside a block are preserved verbatim" ;;
  *) bad "comment preservation" "got: [${got}]" ;;
esac

# --- 4 to 7. the REFUSALS -------------------------------------------------
# Each of these asserts the reason on stderr, not merely a non-zero exit. An
# earlier draft of this file checked only the exit code, and four cases passed
# while the extractor was in fact refusing for a completely unrelated reason (a
# missing argument). A non-zero exit is not evidence that the thing you meant to
# test is what failed ... which is testing-standard rule 1 pointed at the
# harness itself.
refuses_with() {
  # refuses_with <label> <expected stderr fragment> <args...>
  local label="$1" want="$2"; shift 2
  local err rc
  err="$(bash "$E" "$@" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "$label" "expected a refusal, got exit 0"; return; fi
  case "$err" in
    *"$want"*) ok "$label" ;;
    *) bad "$label" "refused, but for the wrong reason: ${err}" ;;
  esac
}

refuses_with "refuses past the end of the section rather than bleeding into the next" \
  "fewer than 4" --file "$FIXTURE" --section '## Section one' --lang bash --block 4

refuses_with "a console transcript is not offered as a bash command" \
  "fewer than 1" --file "$FIXTURE" --section '## Section three' --lang bash --block 1

refuses_with "a missing section names the section it could not find" \
  "section not found" --file "$FIXTURE" --section '## No Such Section' --lang bash --block 1

refuses_with "a section with no code blocks refuses" \
  "fewer than 1" --file "$FIXTURE" --section '## Section four' --lang bash --block 1

# A block that exists but is EMPTY. This reaches a different guard from the four
# above ... those are caught by the parser, this one only by the explicit
# is-it-empty check at the end. It is here because a mutation test showed that
# guard was unreachable from the rest of this file: breaking it deliberately did
# not turn the suite red, which means it was an untested line pretending to be a
# safety net.
refuses_with "an EMPTY fenced block refuses instead of returning an empty command" \
  "EMPTY block" --file "$FIXTURE" --section '## Section five' --lang bash --block 1

# And the refusal must produce nothing on stdout, so a caller that ignores the
# exit code still cannot end up running an empty string.
out="$(bash "$E" --file "$FIXTURE" --section '## No Such Section' --lang bash --block 1 2>/dev/null)"
if [ -z "$out" ]; then ok "a refusal writes nothing to stdout"
else bad "refusal stdout" "got: [${out}]"; fi

# --- 8. the fingerprint changes when the page changes ----------------------
# This is what makes drift visible. If a path script records a SHA and someone
# edits the command on the page, the recorded SHA no longer matches and the
# change is a thing a human has to look at rather than a silent divergence
# between the documentation and the test.
sha1="$(bash "$E" --file "$FIXTURE" --section '## Section one' --lang bash --block 1 --sha 2>/dev/null)"
sed -i.bak 's/first command/first command --now-different/' "$FIXTURE"
sha2="$(bash "$E" --file "$FIXTURE" --section '## Section one' --lang bash --block 1 --sha 2>/dev/null)"
if [ -n "$sha1" ] && [ -n "$sha2" ] && [ "$sha1" != "$sha2" ]; then
  ok "editing the page changes the block fingerprint"
else bad "fingerprint drift detection" "sha1=${sha1} sha2=${sha2}"; fi

# --- 9. the assertion library counts a zero-assertion path as a failure ----
# The harness must not be able to report success for a path that asserted
# nothing. Checked here rather than trusted, because "it exits 0" is exactly the
# claim that has been wrong before.
( . "${HERE}/lib/assert.sh"; assert_summary >/dev/null 2>&1 )
if [ $? -eq 2 ]; then ok "assert_summary refuses a path that made zero assertions"
else bad "zero-assertion guard" "assert_summary should exit 2"; fi

# --- 10. a known-defect assertion that starts passing is reported as FAIL --
out="$( . "${HERE}/lib/assert.sh"
        assert_artifact_xfail "a thing" "echo True" "True"
        printf 'fails=%s xfails=%s' "$ASSERT_FAIL" "$ASSERT_XFAIL" )"
case "$out" in
  *"fails=1 xfails=0") ok "an xfail that starts passing is raised, not swallowed" ;;
  *) bad "xfail inversion" "got: ${out}" ;;
esac

# --- 11. the success-condition census accepts BOTH documented phrasings ---
# TM-0351: an inline `grep -c -i 'success condition'` recorded a page that
# states six "Passes when:" conditions as stating none. The helper must count
# either form, and count zero only when neither is present.
SC_FIX="${TMP}/sc.md"
printf '# p\n\n**Success condition:** a\n\nPasses when: b\n\n**Passes when:** c\n\nprose\n' >"$SC_FIX"
got="$( . "${HERE}/lib/assert.sh"; success_condition_count "$SC_FIX" )"
if [ "$got" = "3" ]; then ok "success_condition_count accepts both 'Success condition' and 'Passes when'"
else bad "success-condition phrasing" "expected 3, got: [${got}]"; fi

printf '# p\n\nno conditions here\n' >"$SC_FIX"
got="$( . "${HERE}/lib/assert.sh"; success_condition_count "$SC_FIX" )"
if [ "$got" = "0" ]; then ok "success_condition_count is 0 when neither form is present"
else bad "success-condition absence" "expected 0, got: [${got}]"; fi

# The synonym ALONE, through the recorder rather than the counter. This is the
# exact shape of the TM-0351 defect: a page whose only phrasing is "Passes
# when" must produce a record with no "states no success condition" note, since
# that note is what a path script writes into the divergence list. Counting
# correctly and recording a divergence anyway would be the same defect one
# layer up, so the recorder's output is asserted, not only the number.
printf '# p\n\n## Check 1\n\n**Passes when** a.\n\n## Check 2\n\n**Passes when** b.\n' >"$SC_FIX"
out="$( . "${HERE}/lib/assert.sh"; record_success_conditions "$SC_FIX" "fixture-page" )"
case "$out" in
  *"no success condition"*) bad "synonym-only page recorded as an absence" "got: ${out}" ;;
  *"SUCCESS CONDITIONS STATED: 2 on fixture-page"*) ok "a page phrased only as 'Passes when' is recorded as stating 2, with no divergence note" ;;
  *) bad "synonym-only page record" "got: ${out}" ;;
esac

# And a page with neither form DOES get the note, so the case above is not
# passing because the note was removed.
printf '# p\n\nno conditions here\n' >"$SC_FIX"
out="$( . "${HERE}/lib/assert.sh"; record_success_conditions "$SC_FIX" "fixture-page" )"
case "$out" in
  *"no success condition in any accepted form"*) ok "a page with neither phrasing is recorded with the divergence note" ;;
  *) bad "absent-conditions record" "got: ${out}" ;;
esac

# And the shipped page that motivated the fix: it must not read as zero.
got="$( . "${HERE}/lib/assert.sh"; success_condition_count "${HERE}/../../docs/deployment/existing-cluster.md" )"
if [ "${got:-0}" -gt 0 ]; then ok "existing-cluster.md is counted as stating success conditions (${got})"
else bad "existing-cluster.md census" "got: [${got}]"; fi

# --- 12. P08 is the path written against that page (TM-0351's DoD) --------
# The citation stage of P08 needs no cluster, and the per-commit canary below
# already proves its two sections resolve. What the card asked for is the
# recorded run: it must not carry a "states no success condition" entry for a
# page that states six. Checked hermetically here by extracting the two blocks
# from the working tree and running the recorder on the page, which is exactly
# what P08 does before it looks for a cluster.
P08_PAGE="${HERE}/../../docs/deployment/existing-cluster.md"
if bash "$E" --file "$P08_PAGE" --section '## Check 1: version and node readiness' --lang bash --block 1 >/dev/null 2>&1 \
   && bash "$E" --file "$P08_PAGE" --section '## Check 3: the default StorageClass' --lang bash --block 1 >/dev/null 2>&1; then
  ok "P08's two sections on existing-cluster.md still resolve to a bash block each"
else
  bad "P08 section canary" "a section P08 depends on no longer resolves; update the path script or INVENTORY.md"
fi
out="$( . "${HERE}/lib/assert.sh"; record_success_conditions "$P08_PAGE" "docs/deployment/existing-cluster.md" )"
case "$out" in
  *"no success condition"*) bad "P08's census records existing-cluster.md as stating none" "got: ${out}" ;;
  *"SUCCESS CONDITIONS STATED: "[1-9]*) ok "P08's census on existing-cluster.md carries no 'states none' divergence" ;;
  *) bad "P08 census record" "got: ${out}" ;;
esac


# --- 13. NEGATIVE (TM-0576 / design §9): a pre-existing object must not ----
#     satisfy an assertion. The TM-0562/TM-0581 shape: on a shared cluster, a
#     sibling route's leftover must not be mistaken for THIS route's own
#     artefact. Hermetic fixture -- no cluster, a directory stands in for one.
NEG_STORE="$(mktemp -d)"
touch "${NEG_STORE}/generic-marker"   # a sibling route's leftover, present BEFORE this route ever runs

route_marker_present() {
  [ -f "${NEG_STORE}/route-a-marker" ] && printf 'present' || printf 'absent'
}
naive_marker_present() {
  # THE BUG SHAPE, kept here only to prove the negative test catches it: reads
  # a generic artefact any route could have left, not this route's own.
  [ -f "${NEG_STORE}/generic-marker" ] && printf 'present' || printf 'absent'
}

( . "${HERE}/lib/assert.sh"
  assert_artifact "route-a's own marker" "route_marker_present" "present"
  [ "$ASSERT_FAIL" -eq 1 ] && [ "$ASSERT_PASS" -eq 0 ]
)
if [ $? -eq 0 ]; then
  ok "a pre-existing sibling object does NOT satisfy the own-route assertion (correctly FAILs)"
else
  bad "own-route assertion" "should have FAILed with only the sibling's leftover present"
fi

# The negative test can fail: swap in the buggy naive read (a generic artefact
# standing in for the route's own) and show it WRONGLY reports the assertion
# satisfied against the exact same pre-existing state.
( . "${HERE}/lib/assert.sh"
  assert_artifact "route-a's own marker (BUGGY read, for the mutation proof)" "naive_marker_present" "present"
  [ "$ASSERT_PASS" -eq 1 ]
)
if [ $? -eq 0 ]; then
  ok "mutation proof: the naive generic-artefact read is WRONGLY satisfied by the pre-existing sibling object -- this is the defect the own-route read above avoids"
else
  bad "mutation proof (pre-existing object)" "expected the buggy naive read to wrongly pass here; it did not, so this fixture no longer demonstrates the defect"
fi

# Positive control: once route A genuinely runs and leaves its OWN marker, the
# same hardened assertion has a real green state (an assertion with no control
# proves nothing about the cluster, only that the harness can print FAIL).
touch "${NEG_STORE}/route-a-marker"
( . "${HERE}/lib/assert.sh"
  assert_artifact "route-a's own marker, after route A actually ran" "route_marker_present" "present"
  [ "$ASSERT_PASS" -eq 1 ]
)
if [ $? -eq 0 ]; then
  ok "the own-route assertion PASSes once route A's own marker genuinely exists (has a green state)"
else
  bad "own-route assertion control" "should PASS once route-a-marker exists"
fi
rm -rf "$NEG_STORE"

# --- 14. NEGATIVE (TM-0576 / design §9): a no-op target must not produce ---
#     PASS. A documented command that does nothing must not be scored PASS
#     merely because its assertion reads a value that happened to already be
#     true. Hermetic fixture: a counter file stands in for cluster state,
#     mirroring P03's before/after pattern rather than a single point-in-time
#     read, since "did this change" is what a no-op cannot fake.
NEG_STATE="$(mktemp -d)"
printf '0' > "${NEG_STATE}/counter"

run_noop_target() { :; }   # the documented command, as a no-op
run_real_target()  { echo $(( $(cat "${NEG_STATE}/counter") + 1 )) > "${NEG_STATE}/counter"; }
read_counter()     { cat "${NEG_STATE}/counter"; }
naive_counter_is_a_number() {
  # THE BUG SHAPE: true whether or not the target did anything -- a no-op
  # leaves the counter at its initial value, which is still "a number".
  case "$(read_counter)" in
    ''|*[!0-9]*) printf 'not-a-number' ;;
    *) printf 'a-number' ;;
  esac
}

PRE="$(read_counter)"
run_noop_target
POST_NOOP="$(read_counter)"
if [ "$POST_NOOP" != "$PRE" ]; then
  bad "no-op fixture" "the no-op target moved the counter; fixture is broken"
else
  ok "a no-op target leaves the artefact unchanged (fixture precondition holds)"
fi

( . "${HERE}/lib/assert.sh"
  assert_artifact "counter after a NO-OP target, must differ from ${PRE}" \
    "read_counter" "$(( PRE + 1 ))"
  [ "$ASSERT_FAIL" -eq 1 ] && [ "$ASSERT_PASS" -eq 0 ]
)
if [ $? -eq 0 ]; then
  ok "a no-op target does NOT satisfy the moved-artefact assertion (correctly FAILs, refuses PASS)"
else
  bad "moved-artefact assertion" "should have FAILed against a no-op target"
fi

# Mutation proof: the naive shape-only read ("is it a number") is WRONGLY
# satisfied by the very same no-op state.
( . "${HERE}/lib/assert.sh"
  assert_artifact "counter after a NO-OP target (BUGGY shape-only read, for the mutation proof)" \
    "naive_counter_is_a_number" "a-number"
  [ "$ASSERT_PASS" -eq 1 ]
)
if [ $? -eq 0 ]; then
  ok "mutation proof: the naive shape-only read is WRONGLY satisfied by a no-op target -- this is the defect the moved-artefact read above avoids"
else
  bad "mutation proof (no-op target)" "expected the buggy naive read to wrongly pass here; it did not, so this fixture no longer demonstrates the defect"
fi

# Positive control: once the real target runs, the counter genuinely moves and
# the hardened assertion has a real green state.
run_real_target
( . "${HERE}/lib/assert.sh"
  assert_artifact "counter after the REAL target" "read_counter" "$(( PRE + 1 ))"
  [ "$ASSERT_PASS" -eq 1 ]
)
if [ $? -eq 0 ]; then
  ok "the moved-artefact assertion PASSes once the target genuinely ran (has a green state)"
else
  bad "moved-artefact assertion control" "should PASS once the real target ran"
fi
rm -rf "$NEG_STATE"


# --- --under-label: selecting the block by the prose ABOVE it ---------------
#
# WHY THIS SELECTOR EXISTS (TM-0716). fresh-install.md section 4a carries two
# k3s install blocks that are byte-identical except for `--cluster-init`, and
# the page tells them apart in the prose line above each fence. `--containing`
# looks INSIDE a block and has no negation, so it cannot express "the one
# without". The page states its own reason for putting routing above the fence:
# a marker inside a code block is stripped by every copy control on every docs
# site. So the label is the page's primary organising structure, and until now
# no path could name it.
LABELFIX="${TMP}/labels.md"
cat >"$LABELFIX" <<'MD'
# A page

## Shapes

**Three nodes** ... **NODE 1**.

```bash
server --cluster-init
```

**One node** ... **NODE 1**.

```bash
server
```

**A block whose own body contains a label-shaped line.**

```bash
echo "**One node** ... this is inside a fence"
grep something
```

**Fourth shape** ... follows the block above.

```bash
fourth
```

**One label, two adjacent blocks.**

```bash
adjacent one
```

```bash
adjacent two
```
MD

got="$(bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'Three nodes' 2>/dev/null)"
if [ "$got" = "server --cluster-init" ]; then ok "--under-label picks the block beneath its own label"
else bad "--under-label picks the labelled block" "got: [${got}]"; fi

got="$(bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'One node' 2>/dev/null)"
if [ "$got" = "server" ]; then ok "--under-label distinguishes two otherwise-identical blocks"
else bad "--under-label distinguishes the shapes" "got: [${got}]"; fi

# A BODY LINE MUST NOT LEAK FORWARD AND BECOME THE NEXT BLOCK'S LABEL. Block
# three's body ends with `grep something`; block four's real label is the prose
# line between them. If the extractor ever updated its label while inside a
# fence, block four would inherit `grep something` and this returns nothing.
#
# ASSERTED AS A POSITIVE, and that detail is the point. The first version of
# this probe checked that selecting 'One node' did NOT return the in-fence text,
# which passed under a deliberate mutation that broke label matching entirely:
# nothing was returned, so nothing leaked, so it reported ok. A want-fail probe
# passes whenever the thing under test breaks badly enough, which is worthless.
# Measured 2026-09-17 by removing the fence-marker guard: three fixtures went
# red and that one stayed green.
got="$(bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'Fourth shape' 2>/dev/null)"
if [ "$got" = "fourth" ]; then ok "a body line does not leak forward as the next block's label"
else bad "body line leaked forward as a label" "got: [${got}]"; fi

# TWO ADJACENT FENCES SHARE THE LABEL ABOVE THEM, and this is the fixture that
# actually pins the no-body-leak rule. The one above does not: every block in
# this page has prose between it and the last, so a leaked body line is
# overwritten by that prose before the next fence opens and nothing observes it.
# Measured 2026-09-17 by mutating the extractor to update its label inside
# fences: the whole suite stayed green. Here there is NO prose between the two
# blocks, so the second's label can only come from the shared line above ... or,
# if the rule regresses, from `adjacent one`, at which point only one block
# carries the label and this refusal becomes a return.
if bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'One label, two adjacent' >/dev/null 2>&1; then
  bad "two adjacent blocks both inherit the label above them" "one matched; a body line became the second block's label"
else
  ok "two adjacent blocks share the label above them, so naming it is ambiguous"
fi

if bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'NODE 1' >/dev/null 2>&1; then
  bad "an ambiguous label is refused" "it returned a block instead of refusing"
else
  ok "a label carried by two blocks is refused rather than guessed"
fi

if bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'Seventeen nodes' >/dev/null 2>&1; then
  bad "an absent label is refused" "it returned a block"
else
  ok "a label no block carries is refused"
fi

# Combining the two selectors ANDs them: the label picks the shape, the content
# confirms the command. A combination matching nothing must refuse, not fall
# back to either half.
got="$(bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'One node' --containing 'server' 2>/dev/null)"
if [ "$got" = "server" ]; then ok "--under-label and --containing AND together"
else bad "--under-label + --containing" "got: [${got}]"; fi

if bash "$E" --file "$LABELFIX" --section '## Shapes' --lang bash --under-label 'One node' --containing 'cluster-init' >/dev/null 2>&1; then
  bad "a label/content combination matching nothing is refused" "it returned a block"
else
  ok "label and content that match different blocks refuse rather than pick one"
fi

# --- indented fences: a block nested in a list item (TM-0722) --------------
#
# WHY. The extractor once recognised a fence only at column 0, so a block
# nested in a list item was invisible: fresh-install section 2's timer hold
# answered EXTRACT_ERROR_NO_MATCH although the page has it, and a neighbouring
# `--containing transactional-update` looked unique only because the second
# block carrying that string could not be seen. These are NEGATIVE fixtures in
# the sense the card asked for: each asserts the extractor FINDS a block it is
# known to have, returns it with exactly the nesting indent removed, and still
# refuses what is not a fence or not a well-formed one.
NESTFIX="${TMP}/nested.md"
cat >"$NESTFIX" <<'MD'
# A page

## Nested

Prose.

- **A list item that carries its own command.**

  **NODE** ... every node, on MicroOS

  ```bash
  sudo systemctl disable --now example.timer
  if true; then
      echo "four more spaces, kept"
  fi

  echo after-an-unindented-blank-line
  ```

  ```an inline span``` opening a line is prose, not a fence.

  ```bash
  second nested
  ```

```inline at column one``` is prose too.

```bash
flush left, after the list
```

## Next section

```bash
next section block
```
MD

got="$(bash "$E" --file "$NESTFIX" --section '## Nested' --lang bash --containing 'example.timer' 2>/dev/null)"
want="$(printf '%s\n' 'sudo systemctl disable --now example.timer' 'if true; then' \
          '    echo "four more spaces, kept"' 'fi' '' 'echo after-an-unindented-blank-line')"
if [ "$got" = "$want" ]; then
  ok "a fence indented inside a list item is found, with exactly its indent removed"
else
  bad "indented fence found and de-indented" "got: [${got}]"
fi

got="$(bash "$E" --file "$NESTFIX" --section '## Nested' --lang bash --block 3 2>/dev/null)"
if [ "$got" = "flush left, after the list" ]; then
  ok "indented fences count toward the ordinal, and a column-0 fence after them still extracts"
else
  bad "ordinal across indented fences" "got: [${got}]"
fi

got="$(bash "$E" --file "$NESTFIX" --section '## Nested' --lang bash --under-label 'every node, on MicroOS' 2>/dev/null)"
if [ "$got" = "$want" ]; then ok "an indented label line labels the indented fence beneath it"
else bad "indented label" "got: [${got}]"; fi

# NOT A FENCE. Three backticks followed by more backticks on the same line is an
# inline code span. Were it read as a fence opener, fence state would invert and
# `second nested` would be read as prose. Asserted as a POSITIVE (the span line
# IS the label of the block below it), so a regression cannot pass by returning
# nothing.
got="$(bash "$E" --file "$NESTFIX" --section '## Nested' --lang bash --under-label 'is prose, not a fence' 2>/dev/null)"
if [ "$got" = "second nested" ]; then ok "an indented inline code span is prose, not a fence opener"
else bad "indented inline span read as a fence" "got: [${got}]"; fi

got="$(bash "$E" --file "$NESTFIX" --section '## Nested' --lang bash --under-label 'is prose too' 2>/dev/null)"
if [ "$got" = "flush left, after the list" ]; then ok "a column-0 inline code span is prose, not a fence opener"
else bad "column-0 inline span read as a fence" "got: [${got}]"; fi

refuses_with "indented fences do not let a section bleed into the next" \
  "fewer than 4" --file "$NESTFIX" --section '## Nested' --lang bash --block 4

# REFUSALS NAME THE INDENTATION. A body line indented less than its fence, and a
# closing marker at a different indent, both mean the block does not end where
# a reader of the markdown would think. Guessing either way returns the wrong
# bytes, so both refuse and say why.
BADFIX="${TMP}/badindent.md"
cat >"$BADFIX" <<'MD'
# A page

## Short line

- item

  ```bash
  indented as its fence is
not indented: the list item ended here
  ```

## Wrong close

  ```bash
  body
```

## After
MD
refuses_with "a body line indented less than its fence is refused, naming the indentation" \
  "does not keep its indentation" --file "$BADFIX" --section '## Short line' --lang bash --block 1
refuses_with "a closing fence at a different indent is refused, naming the indentation" \
  "does not keep its indentation" --file "$BADFIX" --section '## Wrong close' --lang bash --block 1

# THE REAL PAGE, which is the card's own verification: fresh-install section
# 2's timer hold, EXTRACT_ERROR_NO_MATCH before TM-0722.
FI_PAGE="${HERE}/../../docs/deployment/fresh-install.md"
FI_S2='## 2. Install the storage packages, on every node'
got="$(bash "$E" --file "$FI_PAGE" --section "$FI_S2" --lang bash --containing 'transactional-update.timer' 2>/dev/null)"
if [ "$got" = "sudo systemctl disable --now transactional-update.timer rebootmgr.service" ]; then
  ok "fresh-install section 2's indented timer hold extracts (TM-0722)"
else
  bad "fresh-install section 2's timer hold" "got: [${got}]"
fi
# And the post-reboot enable, selected by its label rather than its position
# (TM-0721). Before the relabel this was EXTRACT_ERROR_AMBIGUOUS by content and
# by label alike.
got="$(bash "$E" --file "$FI_PAGE" --section "$FI_S2" --lang bash --under-label 'every node, on MicroOS' --containing 'systemctl enable --now iscsid' 2>/dev/null)"
if [ "$got" = "sudo systemctl enable --now iscsid" ]; then
  ok "fresh-install section 2's post-reboot enable is selected by label (TM-0721)"
else
  bad "fresh-install section 2's post-reboot enable by label" "got: [${got}]"
fi

# ---------------------------------------------------------------------------
# credential-life.py ... the paths job's credential-expiry preflight. TM-0345.
#
# WHY IT IS TESTED HERE AND NOT LEFT TO THE JOB. The only other way to exercise
# it is to run the sixty-minute `paths` job against a credential in a state you
# would have to manufacture on the rig: expired, malformed, or an hour from
# death. Nobody will do that, so without this it ships unexercised ... which is
# the defect this whole file exists to refuse.
#
# IT HAS ALREADY EARNED ITS KEEP. The first version applied a three-day floor to
# remaining life, and both the module's own comment and a deployment's
# runner README asserted such a floor
# "can never fire" under the projected-token option. These cases said otherwise
# on the first run: a projected token carries about an hour of life BY DESIGN,
# so the floor refused every run under the option TM-0345 actually prefers. The
# `rotating` classification exists because of this test, not before it.
CL="${HERE}/lib/credential-life.py"

# Build a JWT with the given claims JSON. Header and signature are inert: this
# module reads the payload and never verifies anything, deliberately, because
# the API server is what verifies and it does so two lines later.
mkjwt() {
  python3 - "$1" <<'PY'
import base64, sys
payload = base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("=")
print("aGVhZGVy." + payload + ".c2ln")
PY
}

cl_is() {  # description, token, expected
  got="$(printf '%s' "$2" | python3 "$CL" 2>/dev/null)"
  if [ "$got" = "$3" ]; then ok "credential-life: $1"
  else bad "credential-life: $1" "expected [${3}], got [${got}]"; fi
}

NOW="$(date -u +%s)"

cl_is "an empty credential is not a JWT" "" "nojwt"
cl_is "a non-JWT string is not a JWT" "abc123" "nojwt"
cl_is "a two-part token is not a JWT" "aGVhZGVy.cGF5" "nojwt"

# Option C: a legacy service-account token carries no exp and never expires.
cl_is "a JWT with no exp claim does not expire" \
      "$(mkjwt '{"sub":"tockmox-test-agent"}')" "noexp"

# Option A, and THE CASE THAT CAUGHT THE DESIGN ERROR. A projected token is
# minted with an hour of life and replaced by kubelet. Its remaining life is
# permanently near zero, so a remaining-life floor refuses every single run.
# Built into a variable first, not inline: bash 3.2 brace-expands the {a,b}
# JSON when it sits literally inside a quoted argument of a quoted $(...)
# command substitution, splitting one argument into several. TM-0758.
J="{\"iat\":${NOW},\"exp\":$((NOW + 3600))}"
cl_is "a projected token (1h life) is rotating, not expiring" \
      "$(mkjwt "$J")" "rotating"
J="{\"iat\":$((NOW - 3000)),\"exp\":$((NOW + 600))}"
cl_is "a projected token 10 minutes from replacement is still rotating" \
      "$(mkjwt "$J")" "rotating"

# The boundary, both sides. 24h is rotating; 25h is hand-minted and gets the floor.
J="{\"iat\":${NOW},\"exp\":$((NOW + 86400))}"
cl_is "a 24h credential is rotating (boundary, inclusive)" \
      "$(mkjwt "$J")" "rotating"
J="{\"iat\":${NOW},\"exp\":$((NOW + 90000))}"
cl_is "a 25h credential is NOT rotating and gets a day count" \
      "$(mkjwt "$J")" "1"

# The 168h status quo, across its life. Day 5 is what must refuse: the run is
# sixty minutes and the credential has two days, so it survives THIS run and
# dies unattended in the middle of one two nights later.
#
# EVERY exp BELOW SITS AN HOUR PAST A WHOLE-DAY BOUNDARY, AND THAT IS NOT
# COSMETIC. `NOW` is read by `date` in this shell; the module reads the clock
# again inside python a moment later. On an exp of exactly `NOW + 7 days` those
# two readings straddle the boundary, `(exp - now) / 86400` comes to 6.9999, and
# floor division returns 6. The first version of these three cases did exactly
# that and failed on the first run ... intermittently, by construction, which is
# the worst kind of red to hand a nightly job. An hour of slack costs nothing and
# removes the race. The 2.9-day case below is the deliberate exception: it probes
# near a boundary on purpose, but from the side where a second of drift cannot
# change the answer.
J="{\"iat\":${NOW},\"exp\":$((NOW + 7 * 86400 + 3600))}"
cl_is "a fresh 168h token reports 7 days" \
      "$(mkjwt "$J")" "7"
J="{\"iat\":$((NOW - 5 * 86400)),\"exp\":$((NOW + 2 * 86400 + 3600))}"
cl_is "a 168h token on day 5 reports 2 days, under the floor" \
      "$(mkjwt "$J")" "2"
J="{\"iat\":$((NOW - 12 * 86400)),\"exp\":$((NOW - 5 * 86400 + 3600))}"
cl_is "an expired credential reports negative days" \
      "$(mkjwt "$J")" "-5"

# Floor division, not rounding. 2.9 days must read 2 and trip a `< 3` threshold;
# rounding up would clear a credential to die inside the run it was cleared for.
J="{\"iat\":$((NOW - 5 * 86400)),\"exp\":$((NOW + 250560))}"
cl_is "2.9 days floors to 2 rather than rounding to 3" \
      "$(mkjwt "$J")" "2"

# Short-lived with no iat: the two kinds cannot be told apart, so it falls to
# the day count and the floor refuses. Erring toward refusing an unknown is this
# preflight's rule everywhere else.
cl_is "a short-lived token with no iat falls through to the floor" \
      "$(mkjwt "{\"exp\":$((NOW + 3600))}")" "0"

# Anything unreadable REFUSES rather than guessing. A credential whose remaining
# life cannot be read is not one to start a sixty-minute run on.
J="{\"iat\":${NOW},\"exp\":\"soon\"}"
cl_is "an exp that is not a number is undecodable" \
      "$(mkjwt "$J")" "undecodable"
J="{\"iat\":${NOW},\"exp\":true}"
cl_is "a boolean exp is undecodable, not truthy" \
      "$(mkjwt "$J")" "undecodable"
cl_is "a payload that will not base64-decode is undecodable" \
      "aGVhZGVy.!!!!.c2ln" "undecodable"
cl_is "a payload that is valid JSON but not an object is undecodable" \
      "$(mkjwt '"not-an-object"')" "undecodable"

# ---------------------------------------------------------------------------
# The MicroOS provisioner profile's OS derivation. TM-0715.
#
# WHY THIS IS IN THE HERMETIC GATE and not left to the provisioning run: the
# guard's whole job is to refuse before a VM exists, so it can be proved
# without one, and a guard proved only by the run it is supposed to prevent is
# proved by the wrong thing.
#
# The first of these cases is the defect the guard shipped with for about ten
# minutes: the image RESOURCE is `microos-cloud` but its DISPLAY NAME is
# `openSUSE-MicroOS-ContainerHost-Cloud`, and a case-sensitive match misses the
# second. A guard blind to its own subject is worse than no guard, because it
# is trusted.

# The derivation, kept byte-identical in shape to throwaway-cluster.sh's copy.
# If that one changes, this fails and names the drift.
os_profile_for() {
  local image_name="$1" override="${2:-}" lc image_profile
  lc="$(printf '%s' "$image_name" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    *microos*|*micro-os*|*suse*) image_profile="microos" ;;
    *) image_profile="ubuntu" ;;
  esac
  if [ -n "$override" ] && [ "$override" != "$image_profile" ]; then
    echo "refused-override"; return
  fi
  echo "${override:-$image_profile}"
}

prof_is() {  # description, image, override, expected
  local got; got="$(os_profile_for "$2" "$3")"
  if [ "$got" = "$4" ]; then ok "$1"; else bad "$1" "got: [${got}], wanted [${4}]"; fi
}

prof_is "the ubuntu image resolves to the ubuntu profile" \
        "ubuntu-2204-cloud" "" "ubuntu"
prof_is "the microos image resource resolves to the microos profile" \
        "microos-cloud" "" "microos"
prof_is "the microos image DISPLAY NAME resolves too, despite its capitals" \
        "openSUSE-MicroOS-ContainerHost-Cloud" "" "microos"
prof_is "an override agreeing with the image is accepted" \
        "ubuntu-2204-cloud" "ubuntu" "ubuntu"
prof_is "an override claiming ubuntu on a MicroOS image is refused, not obeyed" \
        "microos-cloud" "ubuntu" "refused-override"
prof_is "an override claiming microos on an Ubuntu image is refused too" \
        "ubuntu-2204-cloud" "microos" "refused-override"

# The profile's extraction half: every selector must resolve against the tree,
# and a selector that does not must REFUSE rather than fall back to a
# hand-written command. That second half is the reason the profile exists.
PROFILE_LIB="$(dirname "$0")/provision/profiles/microos.sh"
if [ -f "$PROFILE_LIB" ]; then
  if bash -n "$PROFILE_LIB" 2>/dev/null; then
    ok "the microos profile parses"
  else
    bad "the microos profile parses" "bash -n failed"
  fi
  # Every guest-side script it emits must parse too. They run under `set -u` on
  # a machine with no console on this lane, so a syntax error there is an
  # hour of silence rather than an error message.
  # SOURCED IN THIS SHELL, NOT IN A SUBSHELL, and that is not a style choice.
  # The first version of this block wrapped these assertions in ( ... ). PASS
  # and FAIL are plain variables, so a subshell's increments die with it: a
  # mutation run printed six FAIL lines and reported "3 failed", and would have
  # exited 0 on a clean tree. A check that prints FAIL and still passes the gate
  # is worse than no check. Found by mutating the gate rather than by reading
  # it, which is the only way this class shows up.
  #
  # Sourcing here is safe because the profile deliberately sets no shell
  # options ... see its header.
  # shellcheck disable=SC1090
  . "$PROFILE_LIB"
  for fn in microos_driver microos_heartbeat microos_beacon; do
    if "$fn" | bash -n 2>/dev/null; then ok "${fn} emits a script that parses"
    else bad "${fn} emits a script that parses" "bash -n failed"; fi
  done
  # Every emitted script must source the runtime env before using it: they run
  # under `set -u`, so a script that reads PREFIX without sourcing $H/env dies
  # on the guest at boot, on a lane with no console. This was a real defect,
  # found by auditing the emitted scripts rather than the generator.
  for fn in microos_driver microos_heartbeat microos_beacon microos_handoff; do
    if "$fn" | grep '^\. "\$H/env"' >/dev/null; then ok "${fn} sources the runtime env"
    else bad "${fn} sources the runtime env" "it reads runtime vars without sourcing them"; fi
  done
  if microos_handoff | bash -n 2>/dev/null; then ok "microos_handoff emits a script that parses"
  else bad "microos_handoff emits a script that parses" "bash -n failed"; fi

  # ---- the wiring, 2026-09-23 (TM-0715) -----------------------------------
  # LESSON 4: every documented block runs as the unprivileged reader, never as
  # the root the per-boot hook runs as. Two defects this lane found (TM-0622,
  # TM-0630) only exist for a sudo user, so a root run would hide the class.
  # Asserted on the EMITTED driver: every line that executes a file from
  # blocks/ must go through runuser.
  mx_rootlines="$(microos_driver | grep -E 'bash[^|]*\$H/blocks/' | grep -v 'runuser -u "\$RUN_AS"' || true)"
  if [ -z "$mx_rootlines" ] && microos_driver | grep 'runuser -u "\$RUN_AS"' >/dev/null; then
    ok "the driver runs every documented block as the unprivileged user"
  else
    bad "the driver runs every documented block as the unprivileged user" "root lines: ${mx_rootlines:-<no runuser at all>}"
  fi
  # LESSON 5: the success condition is polled, then recorded once more.
  if microos_driver | grep 'grep -qw Ready' >/dev/null && microos_driver | grep 'run_block s4a-success' >/dev/null; then
    ok "the driver polls 4a's success condition before recording it"
  else
    bad "the driver polls 4a's success condition before recording it" "a point-in-time read right after install reads NotReady"
  fi
  # SELinux, measured on run tm0715-microos-05: init_t may not EXECUTE a
  # var_lib_t file, so a transient unit pointed at the script itself dies
  # 203/EXEC the instant it starts, while systemd-run reports success. The unit
  # must run the script THROUGH the shell, and the spawn must be checked.
  mx_spawn="$(microos_driver | grep 'systemd-run ' || true)"
  if printf '%s' "$mx_spawn" | grep '/bin/bash "\$H/driver.sh" await-go' >/dev/null \
     && microos_driver | grep 'systemctl is-active --quiet tockmox-harness-await' >/dev/null; then
    ok "the waiter unit runs the driver through /bin/bash and its spawn is verified"
  else
    bad "the waiter unit runs the driver through /bin/bash and its spawn is verified" "got: ${mx_spawn:-<no systemd-run>}"
  fi
  # The env file lands inside single quotes in a file the guest sources.
  if microos_env_file "p" "https://a" "ns" "u'x" "900" >/dev/null 2>&1; then
    bad "the env file refuses a value carrying a quote" "it accepted one"
  else
    ok "the env file refuses a value carrying a quote"
  fi

  # LESSON 6, proven against pages rather than read. Since TM-0721 the
  # post-reboot enable is selected by its label ANDed with its content, not by
  # ordinal: a fixture docs tree must extract it, the same tree with a block
  # inserted above it must extract the SAME block (the drift an ordinal cannot
  # survive), and a tree where it carries the section's shared label again must
  # REFUSE, which is what proves the label is load-bearing. The fixture carries
  # section 2's two list-item fences as well (TM-0722), so the shared
  # `every node, on MicroOS` label really is on three blocks here.
  MXD="${TMP}/mx-docs"
  mkdir -p "${MXD}/docs/deployment" "${MXD}/docs/operations"
  mx_fresh_install() {  # $1: extra block to insert before the enable, or empty
                        # $2: label over the enable (default: the page's)
    cat <<MD
# Fresh install

## 2. Install the storage packages, on every node

**NODE** ... every node

\`\`\`bash
sudo transactional-update --non-interactive pkg install \\
    open-iscsi nfs-client cryptsetup
sudo reboot
\`\`\`
$1
${2:-**NODE** ... every node, on MicroOS}

\`\`\`bash
sudo systemctl enable --now iscsid
\`\`\`

Three things about that sequence:

- **MicroOS updates itself on a timer.**

  **NODE** ... every node, on MicroOS

  \`\`\`bash
  sudo snapper list
  \`\`\`

  Hold both off:

  **NODE** ... every node, on MicroOS

  \`\`\`bash
  sudo systemctl disable --now transactional-update.timer rebootmgr.service
  \`\`\`

**On Debian or Ubuntu:**

\`\`\`bash
sudo apt-get install -y open-iscsi
sudo systemctl enable --now iscsid
\`\`\`

**Success condition**

\`\`\`bash
systemctl is-active iscsid && ls /usr/sbin/iscsiadm
\`\`\`

## 4. Install k3s

### Set these on each node before you start

\`\`\`bash
export K8S_API_NAME=YOUR_API_HOSTNAME
export K3S_VERSION=v0.0.0+k3s1
\`\`\`

### 4a. The first server ... BOTH SHAPES, on node 1

**Three nodes, on openSUSE MicroOS**

\`\`\`bash
: install --cluster-init
\`\`\`

**One node, on openSUSE MicroOS**

\`\`\`bash
: install one node
\`\`\`

Then, on either shape:

\`\`\`bash
sudo restorecon -R /usr/local/bin/k3s /var/lib/rancher
\`\`\`

**Success condition**

\`\`\`bash
sudo /usr/local/bin/k3s kubectl get nodes
\`\`\`

### 4e. Finish every node ... BOTH SHAPES

**Success condition ... run on EVERY SERVER.**

\`\`\`bash
sudo /usr/local/bin/k3s kubectl get nodes
sudo /usr/local/bin/k3s kubectl version
\`\`\`

## 5. Next
MD
  }
  mkdir -p "${MXD}/docs/administration"
  cat > "${MXD}/docs/administration/external-integrations.md" <<'MD'
# External integrations

### 3. Point containerd at Harbor, on every node

```bash
sudo /usr/local/bin/k3s crictl pull docker.io/library/alpine:3.21
```
MD
  cat > "${MXD}/docs/operations/uninstall.md" <<'MD'
# Uninstall

## 9. Removing k3s itself ... optional, and the reboot a transactional OS may need

```bash
sudo btrfs subvolume get-default /
```
MD
  mx_fresh_install "" > "${MXD}/docs/deployment/fresh-install.md"
  if MICROOS_PAGE_ROOT="$MXD" microos_extract_blocks fixture "${TMP}/mx-good" 2>/dev/null \
     && [ "$(cat "${TMP}/mx-good/blocks/s2-iscsid.sh")" = "sudo systemctl enable --now iscsid" ]; then
    ok "s2-iscsid extracts the post-reboot enable, not the success condition"
  else
    bad "s2-iscsid extracts the post-reboot enable, not the success condition" \
        "got: $(cat "${TMP}/mx-good/blocks/s2-iscsid.sh" 2>/dev/null || echo '<refused>')"
  fi
  # TM-0622: the 4e server success block and the crictl pull are table rows
  # now, so a page that loses either one must be a REFUSAL, and the fixture
  # must extract both.
  if grep -q 'k3s kubectl version' "${TMP}/mx-good/blocks/s4e-success.sh" 2>/dev/null \
     && grep -q 'k3s crictl pull' "${TMP}/mx-good/blocks/xi-crictl.sh" 2>/dev/null; then
    ok "s4e-success and xi-crictl extract from their own sections (TM-0622)"
  else
    bad "s4e-success and xi-crictl extract from their own sections (TM-0622)" \
        "s4e: $(cat "${TMP}/mx-good/blocks/s4e-success.sh" 2>/dev/null || echo '<none>'); xi: $(cat "${TMP}/mx-good/blocks/xi-crictl.sh" 2>/dev/null || echo '<none>')"
  fi
  # TM-0722: the timer hold comes out of the page, de-indented, and nothing in
  # provenance is declared transcribed. s2-pkg stays unique although the hold,
  # now visible, carries `transactional-update` too.
  if [ "$(cat "${TMP}/mx-good/blocks/s2-timer-hold.sh" 2>/dev/null)" = "sudo systemctl disable --now transactional-update.timer rebootmgr.service" ] \
     && grep -q $'^s2-timer-hold\t.*\textracted@fixture$' "${TMP}/mx-good/PROVENANCE.tsv" \
     && ! grep -q 'TRANSCRIBED' "${TMP}/mx-good/PROVENANCE.tsv" \
     && [ "$(head -1 "${TMP}/mx-good/blocks/s2-pkg.sh" 2>/dev/null)" = "sudo transactional-update --non-interactive pkg install \\" ]; then
    ok "the timer hold is EXTRACTED from its list-item fence, and s2-pkg stays unique beside it"
  else
    bad "the timer hold is EXTRACTED from its list-item fence, and s2-pkg stays unique beside it" \
        "hold: $(cat "${TMP}/mx-good/blocks/s2-timer-hold.sh" 2>/dev/null || echo '<none>'); $(cut -f1,7 "${TMP}/mx-good/PROVENANCE.tsv" 2>/dev/null | tr '\n' ' ')"
  fi
  mx_fresh_install $'\n```bash\nsudo zypper --non-interactive refresh\n```\n' \
    > "${MXD}/docs/deployment/fresh-install.md"
  if MICROOS_PAGE_ROOT="$MXD" microos_extract_blocks fixture "${TMP}/mx-moved" 2>/dev/null \
     && [ "$(cat "${TMP}/mx-moved/blocks/s2-iscsid.sh")" = "sudo systemctl enable --now iscsid" ]; then
    ok "a block inserted above the enable does not move what s2-iscsid extracts"
  else
    bad "a block inserted above the enable does not move what s2-iscsid extracts" \
        "s2-iscsid: $(cat "${TMP}/mx-moved/blocks/s2-iscsid.sh" 2>/dev/null || echo '<refused>')"
  fi
  # The label is load-bearing: give the enable back the section's shared label
  # and s2-iscsid must refuse. Asserted on WHICH block refused, not only on the
  # exit code: a refusal for some other selector would pass an rc check and
  # prove nothing about this one.
  mx_fresh_install "" '**NODE** ... every node' > "${MXD}/docs/deployment/fresh-install.md"
  mx_err="$(MICROOS_PAGE_ROOT="$MXD" microos_extract_blocks fixture "${TMP}/mx-relabel" 2>&1 >/dev/null)"
  mx_rc=$?
  if [ "$mx_rc" = "3" ] && printf '%s' "$mx_err" | grep 'REFUSING: extraction failed for s2-iscsid' >/dev/null; then
    ok "the enable without its MicroOS label makes s2-iscsid REFUSE, not pick a block"
  else
    bad "the enable without its MicroOS label makes s2-iscsid REFUSE, not pick a block" \
        "rc=${mx_rc}, s2-iscsid: $(cat "${TMP}/mx-relabel/blocks/s2-iscsid.sh" 2>/dev/null || echo '<none>')"
  fi
  mx_fresh_install "" > "${MXD}/docs/deployment/fresh-install.md"
  # And an ordinal row is refused outright, whatever it would have returned.
  mx_err="$( microos_block_table() { printf '%s\n' "s2-x|docs/deployment/fresh-install.md|${MICROOS_S2_SECTION}|--block|2|"; }
             MICROOS_PAGE_ROOT="$MXD" microos_extract_blocks fixture "${TMP}/mx-ordinal" 2>&1 >/dev/null )"
  mx_rc=$?
  if [ "$mx_rc" = "3" ] && printf '%s' "$mx_err" | grep 'REFUSING: s2-x is selected by --block 2' >/dev/null; then
    ok "a profile row that selects by ordinal is refused"
  else
    bad "a profile row that selects by ordinal is refused" "rc=${mx_rc}: ${mx_err}"
  fi

  # The YOU SUPPLY substitution touches exactly the page's blank.
  if microos_you_supply "${TMP}/mx-good" "t-01" 2>/dev/null \
     && grep -qx 'export K8S_API_NAME=t-01' "${TMP}/mx-good/blocks/s4-exports.sh" \
     && grep -q $'\t--you-supply\t' "${TMP}/mx-good/PROVENANCE.tsv"; then
    ok "the page's YOU SUPPLY is filled in and recorded in provenance"
  else
    bad "the page's YOU SUPPLY is filled in and recorded in provenance" "$(cat "${TMP}/mx-good/blocks/s4-exports.sh" 2>/dev/null)"
  fi

  # The cloud-config: parses, carries every block byte-for-byte, and starts the
  # driver from the per-boot hook that survives the documented reboot.
  if MX_OUTDIR="${TMP}/mx-good" MX_PREFIX=t-01 MX_API=https://api.invalid MX_NS=tockmox-test \
     MX_TOKEN=x MX_CA_B64="" MX_USER=tockmox MX_PUBKEY="ssh-ed25519 AAAA test" \
     MX_HOSTNAME=t-01 MX_MIRROR="" microos_cloud_config "${TMP}/mx-ud.yaml" 2>/dev/null \
     && python3 - "${TMP}/mx-ud.yaml" "${TMP}/mx-good" <<'PY'
# JSON, not YAML: the profile emits a JSON document (valid YAML) after the
# `#cloud-config` line, and json is in every python3, where PyYAML on a stock
# Mac is not. `create` does the YAML parse when PyYAML is present.
import base64, json, pathlib, sys
txt = open(sys.argv[1]).read()
assert txt.startswith("#cloud-config\n"), "first line must be #cloud-config"
d = json.loads(txt.split("\n", 1)[1])
files = {f["path"]: base64.b64decode(f["content"]) for f in d["write_files"]}
for b in (pathlib.Path(sys.argv[2]) / "blocks").glob("*.sh"):
    assert files["/var/lib/tockmox-harness/blocks/" + b.name] == b.read_bytes(), b.name
assert b"driver.sh per-boot" in files["/var/lib/cloud/scripts/per-boot/50-tockmox-harness.sh"]
assert d["users"][0]["name"] == "tockmox"
PY
  then
    ok "the MicroOS cloud-config parses and carries every block byte-for-byte"
  else
    bad "the MicroOS cloud-config parses and carries every block byte-for-byte" "see ${TMP}/mx-ud.yaml"
  fi
else
  bad "the microos profile is present" "not found at ${PROFILE_LIB}"
fi

# ---------------------------------------------------------------------------
# The guest kubeconfig handoff Secret. TM-0766.
#
# Its cases live in handoff-secret-test.sh because they drive the provisioner
# itself against stub kubectl/curl, and that script can be pointed (TC=) at an
# older provisioner to show each case going red. Folded in here so the
# per-commit gate runs them; every case counts as one of this file's own. A run
# that yields no case at all is a failure, not a pass over nothing.
HS_OUT="$(bash "${HERE}/handoff-secret-test.sh" 2>&1)"; HS_RC=$?
HS_CASES=0
while IFS= read -r line; do
  case "$line" in
    "ok   "*) HS_CASES=$((HS_CASES+1)); ok "handoff secret: ${line#ok   }" ;;
    "FAIL "*) HS_CASES=$((HS_CASES+1)); bad "handoff secret: ${line#FAIL }" "run tests/executed-docs/handoff-secret-test.sh for detail" ;;
  esac
done <<EOF_HS
$HS_OUT
EOF_HS
if [ "$HS_CASES" -eq 0 ] || { [ "$HS_RC" -ne 0 ] && ! printf '%s\n' "$HS_OUT" | grep '^FAIL' >/dev/null; }; then
  bad "handoff-secret-test.sh ran its cases" "rc=${HS_RC}, ${HS_CASES} case(s): $(printf '%s' "$HS_OUT" | tail -3)"
fi

# ---------------------------------------------------------------------------
# The registry-mirror modes. TM-0575.
#
# cache (the default, unchanged) and nofallback (the mirror is the only registry,
# upstream traffic denied and counted), in both provisioner lanes, plus the
# guest's mirror-proof. Folded in the same way as the handoff cases above, and for
# the same reason: the per-commit gate runs them, every case counts as one of this
# file's own, and a run that yields no case is a failure.
MM_OUT="$(bash "${HERE}/mirror-mode-test.sh" 2>&1)"; MM_RC=$?
MM_CASES=0
while IFS= read -r line; do
  case "$line" in
    "ok   "*) MM_CASES=$((MM_CASES+1)); ok "mirror mode: ${line#ok   }" ;;
    "FAIL "*) MM_CASES=$((MM_CASES+1)); bad "mirror mode: ${line#FAIL }" "run tests/executed-docs/mirror-mode-test.sh for detail" ;;
  esac
done <<EOF_MM
$MM_OUT
EOF_MM
if [ "$MM_CASES" -eq 0 ] || { [ "$MM_RC" -ne 0 ] && ! printf '%s\n' "$MM_OUT" | grep '^FAIL' >/dev/null; }; then
  bad "mirror-mode-test.sh ran its cases" "rc=${MM_RC}, ${MM_CASES} case(s): $(printf '%s' "$MM_OUT" | tail -3)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

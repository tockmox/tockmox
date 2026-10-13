#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# A STABILITY TIER NOBODY CHECKS IS A COMMENT.
#
# Every Tockmox top-level key carries `x-tockmox-stability` in its layer's
# values.schema.json: `stable`, `provisional` or `experimental`.
# docs/administration/values-contract.md tells an operator that a `stable` key
# does not move without a minor bump and a migration note at the top of the
# release notes. That sentence is a promise about future commits, and until this
# gate existed the only thing enforcing it was whoever reviewed the diff
# noticing what tier the key had carried.
#
# The failure this prevents is quiet by construction. Renaming a key is an
# ordinary refactor: the schema still validates, `helm lint` is clean, every
# render gate is green, and the tier annotation moves along with the key it
# describes without complaining. Nothing in the tree objects, because from the
# tree's point of view nothing is wrong. The thing that broke is a promise made
# in a document to somebody who is not in the room.
#
# WHY THE BASELINE IS THE PREVIOUS TAG AND NOT THE PREVIOUS COMMIT. The promise
# is scoped to releases: keys may move freely between an operator's upgrades and
# the operator will never know. What must not happen is a tag shipping a moved
# `stable` key with nothing at the top of the release notes saying so. Comparing
# HEAD to the last tag is exactly that question.
#
# TWO ASSERTIONS, and the second is the one worth having.
#
#   1. COVERAGE. Every Tockmox top-level key carries a tier, and the tier is one
#      of the three. Cheap, and it stops a new key from arriving untiered and
#      inheriting whatever a reader assumes.
#
#   1b. RULINGS (TM-0909). Every key that is NOT `stable` also carries
#      `x-tockmox-stability-ruled` (the date its tier was last decided, as
#      YYYY-MM-DD) and `x-tockmox-stability-rerule` (the release by which it is
#      decided again, as X.Y or X.Y.Z). A `provisional` tier with no ruling is a
#      tier nobody chose; it only says nobody has looked. The placeholder the
#      rulings arrive with, `PENDING-RULING`, is refused on purpose: a gate that
#      went green on a placeholder would be asserting that a decision was taken
#      when it was not. A re-rule release that is not later than the newest
#      released version in CHANGELOG.md is OVERDUE and refused too ... during a
#      release the top section carries the version about to ship, so a key due
#      at that release blocks it until it is ruled again. Stable keys need
#      neither: their promise is the drift assertion below.
#
#   2. DRIFT. Every key that was `stable` at the baseline is still present, is
#      still `stable`, and still has the same type ... or the TOP-MOST release
#      section of CHANGELOG.md names it inside a paragraph that begins
#      `**Breaking:`. That is not a new convention; CHANGELOG.md's own header
#      already says breaking changes appear at the top of their release with the
#      action required. This gate makes the file keep its word.
#
#      "Top-most" and not "[Unreleased]" by name, deliberately (TM-0410). The
#      section this gate wants is the one describing changes not yet in the
#      baseline. Before a release that heading reads `[Unreleased]`; during one,
#      the release procedure renames it to the version about to ship, and a gate
#      that looked for the old name would then report a correctly announced
#      change as unannounced ... late in a release, looking exactly like a real
#      violation, inviting the two worst fixes (demote the key, or delete the
#      paragraph). Reading the first `## [` section satisfies both spellings.
#
# WHAT THIS DELIBERATELY DOES NOT DO. It does not judge whether a tier is
# correct. Deciding that `namespaces` is stable and `garage` is not is a
# judgement made against wiring, churn and evidence, and no parser should make
# it. This gate only holds the line once the judgement is recorded.
#
# It also does not look inside a key. Leaf overrides exist ...
# `certIssuer.selfSigned.name` is `stable` inside a `provisional` block ... and
# checking those means walking arbitrary nesting for a much smaller return.
# Named here so the omission is a decision rather than an oversight.
#
# Usage:
#   tools/check-values-tiers.sh                 both assertions
#   tools/check-values-tiers.sh --coverage-only assertions 1 and 1b only
#   tools/check-values-tiers.sh --drift-only    assertion 2 only
#   tools/check-values-tiers.sh --selftest      prove the gate actually refuses
#
# WHY THE TWO HALVES SPLIT. Coverage needs nothing but the working tree, so it
# belongs on every pull request. Drift needs the tags, and a checkout that
# fetches them is a full clone ... which the `charts` job in ci.yaml deliberately
# does not do. The `render-diff` job already checks out with `fetch-depth: 0`
# "so the previous release resolves", and is already asking the same shape of
# question about the same baseline, so drift runs there.
#
# The failure mode this avoids is the one worth naming: with no tags in the
# checkout, `git describe` fails, this gate reports SKIPPED, and CI stays green
# while the drift half asserts nothing forever. That is the shape of every
# decorative gate in this directory's history.
#
# Environment:
#   BASELINE_REF  override the baseline (default: git describe --tags --abbrev=0)

set -uo pipefail

cd "$(dirname "$0")/.."

VALID_TIERS="stable provisional experimental"

# ---------------------------------------------------------------------------
# schema_tiers FILE
#
# Prints one line per Tockmox-owned top-level key:
#   key <TAB> tier <TAB> type <TAB> ruled <TAB> rerule
# Every field is "-" when absent, never empty: the readers split on a tab, and
# `read` collapses adjacent tabs, so an empty field would shift the rest.
#
# A key is Tockmox-owned when its description neither starts with "Not this
# layer" (another layer's key, accepted and ignored because one values file is
# passed to every layer) nor ends with "passed through unchanged." (an upstream
# chart's interface, which nobody here can promise anything about). The library
# chart's block is excluded by name: it has no values interface at all.
#
# A key with no annotation prints "-", which is what the coverage check reads.
# The apostrophe in "Not this layer's key" is deliberately not matched ... it
# would have to be escaped through two levels of quoting to buy nothing.
# ---------------------------------------------------------------------------
schema_tiers() {
  jq -r '
    .properties | to_entries[]
    | . as $e
    | (($e.value.description) // "") as $d
    | select(($d | startswith("Not this layer")) | not)
    | select(($d | endswith("passed through unchanged.")) | not)
    | select($e.key != "tockmox-common")
    | $e.key
      + "\t" + (($e.value["x-tockmox-stability"]) // "-")
      + "\t" + (($e.value.type // "-") | if type == "array" then join("|") else . end)
      + "\t" + ((($e.value["x-tockmox-stability-ruled"]) // "-") | tostring)
      + "\t" + ((($e.value["x-tockmox-stability-rerule"]) // "-") | tostring)
  ' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# valid_date S      true when S is YYYY-MM-DD and a real calendar date
# valid_release S   true when S is X.Y or X.Y.Z
# released_version CHANGELOG
#   Prints the newest version heading (`## [X.Y.Z]`) in the file, which is the
#   last release, or during a release cut the one about to ship. Empty if none.
# version_gt A B    true when release A sorts strictly after release B
# ---------------------------------------------------------------------------
valid_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) : ;;
    *) return 1 ;;
  esac
  # `date -d` (GNU) or `date -j -f` (BSD, macOS): either proves 2026-02-30 false.
  date -d "$1" +%F >/dev/null 2>&1 && [ "$(date -d "$1" +%F)" = "$1" ] && return 0
  [ "$(date -j -f %F "$1" +%F 2>/dev/null)" = "$1" ]
}
valid_release() {
  printf '%s\n' "$1" | awk '/^[0-9]+\.[0-9]+(\.[0-9]+)?$/ {ok=1} END {exit !ok}'
}
released_version() {
  [ -f "$1" ] || return 0
  awk 'match($0, /^## \[[0-9]+\.[0-9]+(\.[0-9]+)?\]/) {
         v = substr($0, 5, RLENGTH - 5); print v; exit }' "$1"
}
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    for (i = 1; i <= 3; i++) { p = (i <= na) ? x[i] + 0 : 0; q = (i <= nb) ? y[i] + 0 : 0
      if (p > q) exit 0; if (p < q) exit 1 }
    exit 1 }'
}

# ---------------------------------------------------------------------------
# check_coverage DIR [CHANGELOG]
#
# DIR holds charts/<layer>/values.schema.json. Returns non-zero if any
# Tockmox key has no tier, or a tier outside the three, or (TM-0909) is not
# `stable` and lacks a dated ruling and a re-rule release. CHANGELOG defaults to
# DIR/CHANGELOG.md and supplies the release a re-rule must still be ahead of;
# with no version heading in it, the overdue check has nothing to compare and
# is skipped (said, not silent).
# ---------------------------------------------------------------------------
check_coverage() {
  cov_dir="$1"
  cov_log="${2:-$1/CHANGELOG.md}"
  cov_bad=0
  cov_n=0
  cov_ruled=0
  cov_released=$(released_version "$cov_log")
  for cov_f in "$cov_dir"/charts/*/values.schema.json; do
    [ -f "$cov_f" ] || continue
    cov_layer=$(basename "$(dirname "$cov_f")")
    while IFS="$(printf '\t')" read -r cov_key cov_tier cov_type cov_on cov_at; do
      [ -n "$cov_key" ] || continue
      cov_n=$((cov_n + 1))
      if [ "$cov_tier" = "-" ]; then
        echo "  UNTIERED     $cov_layer  $cov_key"
        echo "               no x-tockmox-stability. Every Tockmox key needs one;"
        echo "               see docs/administration/values-contract.md."
        cov_bad=1
        continue
      fi
      case " $VALID_TIERS " in
        *" $cov_tier "*) : ;;
        *) echo "  BAD TIER     $cov_layer  $cov_key  = \"$cov_tier\""
           echo "               must be one of: $VALID_TIERS"
           cov_bad=1
           continue ;;
      esac
      [ "$cov_tier" = "stable" ] && continue
      cov_ruled=$((cov_ruled + 1))
      if ! valid_date "$cov_on"; then
        echo "  UNRULED      $cov_layer  $cov_key  ($cov_tier)  x-tockmox-stability-ruled = \"$cov_on\""
        echo "               this $cov_tier key needs the date its tier was ruled, as YYYY-MM-DD."
        cov_bad=1
      fi
      if ! valid_release "$cov_at"; then
        echo "  NO RE-RULE   $cov_layer  $cov_key  ($cov_tier)  x-tockmox-stability-rerule = \"$cov_at\""
        echo "               this $cov_tier key needs the release it is ruled again at, as X.Y or X.Y.Z."
        cov_bad=1
      elif [ -n "$cov_released" ] && ! version_gt "$cov_at" "$cov_released"; then
        echo "  OVERDUE      $cov_layer  $cov_key  ($cov_tier)  re-rule $cov_at, released $cov_released"
        echo "               rule it again: promote, keep with a later re-rule, or remove."
        cov_bad=1
      fi
    done <<EOF
$(schema_tiers "$cov_f")
EOF
  done
  if [ "$cov_n" -eq 0 ]; then
    echo "  NO KEYS READ ... $cov_dir holds no readable schemas."
    echo "  A gate that examines nothing must not report success."
    return 1
  fi
  if [ "$cov_bad" -eq 0 ]; then
    echo "  $cov_n Tockmox key entries across the layers, all tiered;"
    echo "  $cov_ruled not stable, each with a dated ruling and a re-rule release${cov_released:+ after $cov_released}."
  fi
  [ -n "$cov_released" ] || echo "  (no version heading in $cov_log: re-rule releases not checked for being overdue)"
  return "$cov_bad"
}

# ---------------------------------------------------------------------------
# stable_set DIR
#
# Prints "layer<TAB>key<TAB>type" for every key marked stable in DIR, sorted.
# ---------------------------------------------------------------------------
stable_set() {
  for ss_f in "$1"/charts/*/values.schema.json; do
    [ -f "$ss_f" ] || continue
    ss_layer=$(basename "$(dirname "$ss_f")")
    while IFS="$(printf '\t')" read -r ss_key ss_tier ss_type _ss_on _ss_at; do
      [ "$ss_tier" = "stable" ] || continue
      printf '%s\t%s\t%s\n' "$ss_layer" "$ss_key" "$ss_type"
    done <<EOF
$(schema_tiers "$ss_f")
EOF
  done | sort
}

# ---------------------------------------------------------------------------
# changelog_names KEY CHANGELOG
#
# True when KEY appears, in backticks, inside a paragraph of the TOP-MOST
# release section that begins with "**Breaking:", as a paragraph or as a list
# item ("- **Breaking:"). The list form is accepted because CHANGELOG.md's
# release sections are written as bullets; anchoring on the paragraph form
# alone would have made this gate blind to every breaking change in the format
# the file actually uses, which is the failure mode it exists to prevent.
#
# The top-most section is the first `## [` heading in the file, whatever it is
# called, and it ends at the next level-2 heading. It is NOT the whole file:
# a Breaking paragraph in an old release section would otherwise satisfy this
# gate forever, which is worse than the narrowness it replaced. Nothing above
# the first `## [` heading counts either; the file's preamble is not a release.
#
# Why the paragraph and not the section: a key name can appear anywhere in a
# release note for entirely benign reasons ... "adds a field under `garage`" ...
# and a matcher that accepts any mention would pass on exactly the commit it
# exists to catch. Requiring the Breaking paragraph means the author had to
# write the sentence an operator needs, not merely mention the key.
#
# `grep -q` is deliberately not used here: with `pipefail` set, a `grep -q`
# closing the pipe early makes the producer's exit status non-zero and inverts
# the test. Capture, then case.
# ---------------------------------------------------------------------------
changelog_names() {
  cn_key="$1"; cn_file="$2"
  [ -f "$cn_file" ] || return 1
  cn_para=$(awk '
    /^## \[/ && !seen { seen = 1; inrel = 1; next }
    /^## /            { inrel = 0 }
    inrel {
      if ($0 ~ /^(- )?\*\*Breaking:/) { inpara = 1 }
      else if ($0 ~ /^[[:space:]]*$/) { inpara = 0 }
      if (inpara) print
    }
  ' "$cn_file")
  case "$cn_para" in
    *"\`$cn_key\`"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# check_drift BASELINE_DIR HEAD_DIR CHANGELOG
# ---------------------------------------------------------------------------
check_drift() {
  cd_base="$1"; cd_head="$2"; cd_log="$3"
  cd_bad=0

  cd_basefile=$(mktemp); cd_headfile=$(mktemp)
  stable_set "$cd_base" > "$cd_basefile"
  stable_set "$cd_head" > "$cd_headfile"

  cd_n=$(wc -l < "$cd_basefile" | tr -d ' ')
  if [ "$cd_n" -eq 0 ]; then
    echo "  The baseline carries no stable keys, so there is nothing it could"
    echo "  have lost. This is expected on the first run after the tiers land,"
    echo "  and it means the drift half of this gate is not yet asserting"
    echo "  anything. It starts asserting at the next tag."
    rm -f "$cd_basefile" "$cd_headfile"
    return 0
  fi

  while IFS="$(printf '\t')" read -r cd_layer cd_key cd_type; do
    [ -n "$cd_key" ] || continue
    cd_now=$(awk -F'\t' -v l="$cd_layer" -v k="$cd_key" \
               '$1==l && $2==k {print $3}' "$cd_headfile")
    cd_reason=""
    if [ -z "$cd_now" ]; then
      # Present at HEAD at all, or gone entirely? The distinction is the whole
      # of what an operator has to do about it, so report which.
      cd_any=$(schema_tiers "$cd_head/charts/$cd_layer/values.schema.json" \
                 | awk -F'\t' -v k="$cd_key" '$1==k {print $2}')
      if [ -z "$cd_any" ]; then
        cd_reason="removed from $cd_layer"
      else
        cd_reason="demoted in $cd_layer from stable to $cd_any"
      fi
    elif [ "$cd_now" != "$cd_type" ]; then
      cd_reason="type changed in $cd_layer from $cd_type to $cd_now"
    fi

    [ -n "$cd_reason" ] || continue

    if changelog_names "$cd_key" "$cd_log"; then
      echo "  announced   $cd_key ... $cd_reason"
    else
      echo "  UNANNOUNCED $cd_key ... $cd_reason"
      cd_bad=1
    fi
  done < "$cd_basefile"

  [ "$cd_bad" -eq 0 ] && echo "  $cd_n stable key entries at the baseline, none moved unannounced."
  rm -f "$cd_basefile" "$cd_headfile"
  return "$cd_bad"
}

# ---------------------------------------------------------------------------
# selftest
#
# A gate that has never been observed refusing is decoration. Fixtures only ...
# no cluster, no network, and it does not touch the real tree.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  command -v jq >/dev/null 2>&1 || { echo "SELFTEST: jq is required"; exit 1; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  fails=0

  mkschema() { # mkschema DIR LAYER JSON
    mkdir -p "$1/charts/$2"
    cat > "$1/charts/$2/values.schema.json"
  }

  base="$tmp/base"; head="$tmp/head"
  mkschema "$base" tockmox-demo <<'JSON'
{ "properties": {
  "namespaces": { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "stable" },
  "garage":     { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "provisional",
                  "x-tockmox-stability-ruled": "2026-10-08", "x-tockmox-stability-rerule": "0.9.0" },
  "traefik":    { "type": "object", "description": "Upstream traefik chart values, passed through unchanged." },
  "brand":      { "description": "Not this layer's key. Owned by the identity layer." }
} }
JSON
  cp -r "$base" "$head"

  printf '## [Unreleased]\n\nNothing yet.\n\n## [0.1.0]\n' > "$tmp/CHANGELOG.clean.md"
  printf '## [Unreleased]\n\n**Breaking: `namespaces` is renamed.** Action required: rename it.\n\n## [0.1.0]\n' > "$tmp/CHANGELOG.signalled.md"
  printf '## [Unreleased]\n\nAdds a field under `namespaces`, which is not a breaking change.\n\n## [0.1.0]\n' > "$tmp/CHANGELOG.mention.md"

  # THE FIXTURES THAT WOULD HAVE CAUGHT TM-0410. The release procedure renames
  # `[Unreleased]` to the version about to ship, so the announcement must be
  # found under a version-named heading too ... and ONLY under the top-most one.
  # An announcement in an older section is history, not a signal for this
  # release, and a file whose top section carries no announcement is refused
  # whatever that section is called.
  printf '## [0.2.0] ... 2026-01-01\n\n**Breaking: `namespaces` is renamed.** Action required: rename it.\n\n## [0.1.0]\n' > "$tmp/CHANGELOG.versioned.md"
  printf '## [0.2.0] ... 2026-01-01\n\nNothing yet.\n\n## [0.1.0]\n' > "$tmp/CHANGELOG.versioned-silent.md"
  printf '## [Unreleased]\n\nNothing yet.\n\n## [0.1.0]\n\n**Breaking: `namespaces` is renamed.** Action required: rename it.\n' > "$tmp/CHANGELOG.oldsection.md"
  printf '# Changelog\n\nBreaking changes appear at the top. **Breaking: `namespaces`** is mentioned here in the preamble only.\n\n## [Unreleased]\n\nNothing yet.\n\n## [0.1.0]\n' > "$tmp/CHANGELOG.preamble.md"

  # The release sections are written as bullets, so the announcement arrives as
  # a list item rather than a paragraph. Same sentence, one "- " in front of it.
  printf '## [0.2.0] ... 2026-01-01\n\n### Breaking\n\n- **Breaking: `namespaces` is renamed.**\n  - Action required: rename it.\n\n## [0.1.0]\n' > "$tmp/CHANGELOG.bulleted.md"

  probe() { # probe LABEL pass|fail COMMAND...
    p_label="$1"; p_want="$2"; shift 2
    p_out=$("$@" 2>&1); p_rc=$?
    if [ "$p_want" = "pass" ] && [ "$p_rc" -ne 0 ]; then
      echo "  SELFTEST FAIL: '$p_label' should have passed:"
      printf '%s\n' "$p_out" | sed 's/^/            /'; fails=1
    elif [ "$p_want" = "fail" ] && [ "$p_rc" -eq 0 ]; then
      echo "  SELFTEST FAIL: '$p_label' should have been refused, and was not"; fails=1
    else
      echo "  ok  $p_label"
    fi
  }

  echo "selftest: coverage"
  probe "a fully tiered tree is accepted" pass check_coverage "$head"

  mkschema "$tmp/untiered" tockmox-demo <<'JSON'
{ "properties": {
  "namespaces": { "type": "object", "description": "Tockmox-owned block." }
} }
JSON
  probe "a Tockmox key with no tier is refused" fail check_coverage "$tmp/untiered"

  mkschema "$tmp/badtier" tockmox-demo <<'JSON'
{ "properties": {
  "namespaces": { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "frozen" }
} }
JSON
  probe "a tier outside the three is refused" fail check_coverage "$tmp/badtier"

  mkdir -p "$tmp/empty/charts"
  probe "a directory with no schemas is refused, not reported clean" fail \
        check_coverage "$tmp/empty"

  # TM-0909: a non-stable key carries a dated ruling and a re-rule release.
  # One fixture per way of not having one, including the placeholder the
  # rulings arrive with, which must never pass for a ruling.
  ruling_fixture() { # ruling_fixture NAME TIER RULED RERULE  ("" omits the field)
    rf_extra=""
    [ -n "$3" ] && rf_extra="$rf_extra, \"x-tockmox-stability-ruled\": \"$3\""
    [ -n "$4" ] && rf_extra="$rf_extra, \"x-tockmox-stability-rerule\": \"$4\""
    mkschema "$tmp/$1" tockmox-demo <<JSON
{ "properties": {
  "namespaces": { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "stable" },
  "garage": { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "$2"$rf_extra }
} }
JSON
  }
  printf '## [Unreleased]\n\nNothing yet.\n\n## [0.8.0] ... 2026-01-01\n' > "$tmp/CHANGELOG.at080.md"
  printf '## [0.9.0] ... 2026-02-01\n\nShipping.\n\n## [0.8.0] ... 2026-01-01\n' > "$tmp/CHANGELOG.cut090.md"

  ruling_fixture unruled provisional "" ""
  probe "a provisional key with no ruling at all is refused" fail check_coverage "$tmp/unruled"
  ruling_fixture placeholder provisional PENDING-RULING PENDING-RULING
  probe "the PENDING-RULING placeholder is refused, not taken for a ruling" fail check_coverage "$tmp/placeholder"
  ruling_fixture norerule experimental 2026-10-08 ""
  probe "a dated ruling with no re-rule release is refused" fail check_coverage "$tmp/norerule"
  ruling_fixture nodate experimental "" 0.9.0
  probe "a re-rule release with no ruling date is refused" fail check_coverage "$tmp/nodate"
  ruling_fixture baddate provisional 2026-02-30 0.9.0
  probe "a ruling date that is not a calendar date is refused" fail check_coverage "$tmp/baddate"
  ruling_fixture badrel provisional 2026-10-08 next
  probe "a re-rule that is not a release number is refused" fail check_coverage "$tmp/badrel"
  ruling_fixture ruled experimental 2026-10-08 0.9.0
  probe "an experimental key with a date and a re-rule is accepted" pass check_coverage "$tmp/ruled"
  probe "a re-rule later than the last release is accepted" pass \
        check_coverage "$tmp/ruled" "$tmp/CHANGELOG.at080.md"
  probe "a re-rule at the release being cut is refused as overdue" fail \
        check_coverage "$tmp/ruled" "$tmp/CHANGELOG.cut090.md"
  ruling_fixture old provisional 2026-10-08 0.7
  probe "a re-rule older than the last release is refused as overdue" fail \
        check_coverage "$tmp/old" "$tmp/CHANGELOG.at080.md"
  ruling_fixture stableonly stable "" ""
  probe "a stable key needs no ruling" pass check_coverage "$tmp/stableonly"

  echo "selftest: drift"
  probe "an unchanged tree is accepted" pass \
        check_drift "$base" "$head" "$tmp/CHANGELOG.clean.md"

  removed="$tmp/removed"; mkschema "$removed" tockmox-demo <<'JSON'
{ "properties": {
  "garage": { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "provisional" }
} }
JSON
  probe "a stable key removed with no signal is refused" fail \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.clean.md"
  probe "the same removal with a Breaking paragraph is accepted" pass \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.signalled.md"
  probe "a bare mention outside a Breaking paragraph is refused" fail \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.mention.md"
  probe "the same Breaking paragraph under a version-named top section is accepted" pass \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.versioned.md"
  probe "a version-named top section with no announcement is refused" fail \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.versioned-silent.md"
  probe "a Breaking paragraph in an OLDER section does not count" fail \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.oldsection.md"
  probe "a Breaking paragraph above the first release heading does not count" fail \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.preamble.md"
  probe "the announcement written as a BULLET is accepted" pass \
        check_drift "$base" "$removed" "$tmp/CHANGELOG.bulleted.md"

  demoted="$tmp/demoted"; mkschema "$demoted" tockmox-demo <<'JSON'
{ "properties": {
  "namespaces": { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "experimental" },
  "garage":     { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "provisional" }
} }
JSON
  probe "a stable key demoted with no signal is refused" fail \
        check_drift "$base" "$demoted" "$tmp/CHANGELOG.clean.md"

  retyped="$tmp/retyped"; mkschema "$retyped" tockmox-demo <<'JSON'
{ "properties": {
  "namespaces": { "type": "string", "description": "Tockmox-owned block.", "x-tockmox-stability": "stable" },
  "garage":     { "type": "object", "description": "Tockmox-owned block.", "x-tockmox-stability": "provisional" }
} }
JSON
  probe "a stable key whose type changed with no signal is refused" fail \
        check_drift "$base" "$retyped" "$tmp/CHANGELOG.clean.md"

  emptybase="$tmp/emptybase"; mkschema "$emptybase" tockmox-demo <<'JSON'
{ "properties": {
  "namespaces": { "type": "object", "description": "Tockmox-owned block." }
} }
JSON
  probe "a baseline with no tiers is reported, not failed" pass \
        check_drift "$emptybase" "$head" "$tmp/CHANGELOG.clean.md"

  if [ "$fails" -eq 0 ]; then
    echo "check-values-tiers --selftest: PASSED"; exit 0
  fi
  echo "check-values-tiers --selftest: FAILED"; exit 1
fi

# ---------------------------------------------------------------------------
# the real run
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || {
  echo "check-values-tiers: jq is required and is not on PATH."
  echo "A gate that cannot read the schemas must refuse rather than report clean."
  exit 1
}

WANT="${1:-both}"
case "$WANT" in
  both|--coverage-only|--drift-only) : ;;
  *) echo "check-values-tiers: unknown argument \"$WANT\""
     echo "expected one of: --coverage-only, --drift-only, --selftest, or nothing"
     exit 1 ;;
esac

echo "checking values stability tiers (docs/administration/values-contract.md)"

cov_rc=0
drift_rc=0

if [ "$WANT" != "--drift-only" ]; then
  echo
  echo "== coverage: every Tockmox key carries a tier =="
  check_coverage "." || cov_rc=1
fi

if [ "$WANT" = "--coverage-only" ]; then
  echo
  if [ "$cov_rc" -eq 0 ]; then echo "check-values-tiers (coverage): PASSED"; exit 0; fi
  echo "check-values-tiers (coverage): FAILED"
  echo
  echo "A new Tockmox key needs a tier before it ships, because a reader with no"
  echo "tier to read assumes one. docs/administration/values-contract.md says"
  echo "what the three mean."
  exit 1
fi

echo
echo "== drift: no stable key moved since the baseline, unannounced =="

# A missing baseline is a SKIP when somebody runs the whole script on a laptop
# or a shallow clone, and an ERROR under --drift-only, which is the CI spelling
# and runs in a job that checks out with fetch-depth 0 precisely so the tags are
# there. Collapsing the two would let the CI half go quietly dormant, which is
# the failure this gate is supposed to be immune to.
no_baseline() {
  if [ "$WANT" = "--drift-only" ]; then
    echo "  ERROR: $1"
    echo "  --drift-only was asked for, which means the caller believes the"
    echo "  baseline is available. Check out with fetch-depth 0, or set"
    echo "  BASELINE_REF. Refusing to report a pass on an unexamined tree."
    return 1
  fi
  echo "  SKIPPED: $1"
  echo "  Run this where the tags are, or set BASELINE_REF, to assert it."
  return 0
}

if ! command -v git >/dev/null 2>&1; then
  no_baseline "git is not on PATH, so there is no baseline to compare." || drift_rc=1
else
  BASE_REF="${BASELINE_REF:-$(git --no-optional-locks describe --tags --abbrev=0 2>/dev/null)}"
  if [ -z "$BASE_REF" ]; then
    no_baseline "no tag is reachable from HEAD (shallow clone or fresh history)." || drift_rc=1
  else
    if ! git --no-optional-locks rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null 2>&1; then
      no_baseline "\"$BASE_REF\" does not resolve to a commit." || drift_rc=1
    else
      echo "  baseline: $BASE_REF"
      basedir=$(mktemp -d)
      trap 'rm -rf "$basedir"' EXIT
      recovered=0
      for f in charts/*/values.schema.json; do
        layer=$(basename "$(dirname "$f")")
        mkdir -p "$basedir/charts/$layer"
        if git --no-optional-locks show "$BASE_REF:$f" \
             > "$basedir/charts/$layer/values.schema.json" 2>/dev/null; then
          recovered=$((recovered + 1))
        else
          rm -f "$basedir/charts/$layer/values.schema.json"
        fi
      done

      # AN EMPTY BASELINE HAS TWO CAUSES AND THEY ARE NOT THE SAME REPORT.
      # A baseline that predates the tiers genuinely has no stable set, and
      # passing is correct. A baseline nothing could be read out of ... a ref
      # that resolves but holds no charts, a path that moved ... also produces
      # an empty set, and reporting THAT as "nothing to compare" is how a gate
      # goes quietly dormant while staying green. Count what was recovered.
      if [ "$recovered" -eq 0 ]; then
        no_baseline "no values.schema.json could be read out of $BASE_REF." || drift_rc=1
      else
        echo "  recovered $recovered schema(s) from the baseline"
        check_drift "$basedir" "." CHANGELOG.md || drift_rc=1
      fi
    fi
  fi
fi

echo
if [ "$cov_rc" -eq 0 ] && [ "$drift_rc" -eq 0 ]; then
  echo "check-values-tiers: PASSED"
  exit 0
fi

echo "check-values-tiers: FAILED"
echo
echo "A key marked stable carries a promise made in values-contract.md: it does"
echo "not move without a minor bump and a migration note at the top of the"
echo "release section. Either put that paragraph in CHANGELOG.md's top-most"
echo "release section ([Unreleased], or the version about to ship if it has"
echo "already been renamed), beginning \`**Breaking:\` and naming the key in"
echo "backticks, or put the key back. Lowering a key's tier to make this green is a decision"
echo "about what Tockmox promises, not a way to pass a check."
exit 1

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Render every layer at two refs against the SAME site values, and diff.
#
#   ./tools/render-diff.sh v0.6.0-rc1 main -f ci/values-site-minimal.yaml
#   ./tools/render-diff.sh v0.6.0 WORKTREE -f SITE/site/values/global.yaml \
#                                          -f SITE/site/values/platform.yaml
#   ./tools/render-diff.sh A B -f VALUES --fail-on-diff     # exit 3 if anything moved
#   ./tools/render-diff.sh A B -f VALUES --out DIR          # keep the renders
#
# REF is anything `git archive` accepts (tag, branch, sha), or the literal
# WORKTREE for the current working tree including uncommitted edits. Repeated
# -f is passed through in order, later files winning, exactly as the
# installer's multi-source Applications do.
#
# WHAT THIS IS FOR (TM-0283). Pre-1.0, values keys can still move between
# releases, and a key that moved shows up in a render as a resource losing a
# field, gaining a default, or disappearing. That is the single most likely
# way an upgrade breaks, and it is visible before anything is applied. This
# is the cheap early warning that runs on every PR: the previous release tag
# and the candidate, rendered against one real site's values, side by side.
#
# DIFF AGAINST A REAL SITE'S VALUES, NEVER ci/values.yaml. CI's values file
# carries every layer's keys in one file, which is why a cross-layer nil can
# pass CI and fail on first deployment (the `ai-egress.yaml` header records
# that at length). ci/values-site-minimal.yaml is the smallest thing a real
# site supplies and is the right default for CI; a generated site's own
# global.yaml plus the layer file is the right thing for an operator.
#
# WHAT A CLEAN DIFF DOES NOT PROVE, printed by this script into its own output
# so a green result never reads as upgrade coverage: nothing about CRD
# migrations, ArgoCD's sync behaviour on a changed resource, StatefulSet field
# immutability, PVC retention, or data surviving. Those need an upgrade run
# against a real deployment (TM-0281). A clean render diff says the desired
# state did not move for this site's values, and nothing more.
#
# Exit codes:
#   0  both refs rendered every layer; diff reported (may be non-empty)
#   1  a layer failed to render at the CANDIDATE ref, or at both
#   2  usage, or a tool is missing
#   3  --fail-on-diff was given and at least one layer differs
#
# READ-ONLY against the repository. Refs are materialised with `git archive`
# into a temporary directory; nothing checks out, stashes or writes the index.
set -uo pipefail

REF_A=""; REF_B=""
VALUES_ARGS=()
FAIL_ON_DIFF=0
OUT=""
LAYERS=(crds policy platform observability exporters identity devops ai selfcheck)

usage() { sed -n '3,15p' "$0" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--values)
      [ $# -ge 2 ] || usage
      VALUES_ARGS+=(-f "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
    --fail-on-diff) FAIL_ON_DIFF=1; shift ;;
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --layers) [ $# -ge 2 ] || usage; IFS=' ' read -r -a LAYERS <<< "$2"; shift 2 ;;
    -h|--help) sed -n '3,45p' "$0"; exit 0 ;;
    -*) echo "render-diff: unknown option $1" >&2; usage ;;
    *)
      if [ -z "$REF_A" ]; then REF_A="$1"
      elif [ -z "$REF_B" ]; then REF_B="$1"
      else echo "render-diff: too many positional arguments" >&2; usage; fi
      shift ;;
  esac
done
[ -n "$REF_A" ] && [ -n "$REF_B" ] || { echo "render-diff: two refs are required" >&2; usage; }
[ ${#VALUES_ARGS[@]} -gt 0 ] || { echo "render-diff: at least one -f VALUES is required, and it should be a real site's values, not ci/values.yaml" >&2; usage; }
for v in "${VALUES_ARGS[@]}"; do
  case "$v" in -f) continue ;; esac
  [ -f "$v" ] || { echo "render-diff: values file not found: $v" >&2; exit 2; }
  case "$v" in */ci/values.yaml)
    echo "render-diff: refusing ci/values.yaml. It is more complete than any real site and would prove the wrong thing with a green tick." >&2; exit 2 ;;
  esac
done
command -v helm >/dev/null 2>&1 || { echo "render-diff: helm is not on PATH" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "render-diff: git is not on PATH" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-render-diff.XXXXXX")"
  trap 'rm -rf "$OUT"' EXIT
else
  # Absolute, because materialise() redirects into "$OUT/..." from inside a
  # subshell that has cd'd into the tree. A relative --out (CI passes one)
  # made that redirect resolve under the tree itself and fail "No such file".
  mkdir -p "$OUT"
  OUT="$(cd "$OUT" && pwd)"
fi

# If --out landed inside the repository, tell the WORKTREE tar to skip it. See
# the long note in materialise(): without this the output directory is copied
# into itself, once per run, and nothing ever notices because scratch output is
# not something anyone reads.
OUT_EXCLUDE=""
case "$OUT/" in
  "$ROOT"/*)
    OUT_REL="${OUT#"$ROOT"/}"
    OUT_EXCLUDE="--exclude=./${OUT_REL%%/*}"
    ;;
esac

# Materialise a ref into $OUT/tree-<label>. Read-only: `git archive` never
# touches the index or the working tree, which is why it is used instead of
# `git worktree add`.
materialise() {
  ref="$1"; dir="$2"
  mkdir -p "$dir"
  if [ "$ref" = "WORKTREE" ]; then
    # The working tree as it is, uncommitted edits included. Vendored subchart
    # archives are excluded so each tree resolves its own Chart.lock.
    #
    # $OUT IS EXCLUDED TOO, and that one is not an optimisation. With `--out`
    # pointing inside the repository, this tar copied the output directory into
    # itself: render-diff/tree-b/render-diff/tree-b/... reached THIRTY levels and
    # 281 MB before anyone looked. Worse, the copies are real markdown, so
    # check-docs-links.sh (which walked the filesystem until 2026-09-03) read
    # 6473 files instead of 73 and reported 568 broken links that exist nowhere
    # in the repository. A scratch directory silently became the largest thing
    # the gates could see.
    tar -C "$ROOT" \
      --exclude=.git \
      --exclude='charts/*/charts' \
      --exclude='*.tgz' \
      ${OUT_EXCLUDE:+"$OUT_EXCLUDE"} \
      -cf - . | tar -C "$dir" -xf -
  else
    if ! git --no-optional-locks rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
      echo "render-diff: ref not found: $ref (fetch tags first: git fetch --tags)" >&2
      return 2
    fi
    git --no-optional-locks archive "$ref" | tar -C "$dir" -xf -
  fi
  # Subcharts. helm-deps.sh is bash 3.2 clean and derives the repo list from
  # the tree it runs in, so the ref's own Chart.yaml files decide.
  if ! (cd "$dir" && ./tools/helm-deps.sh >"$dir/.helm-deps.log" 2>&1); then
    echo "render-diff: helm-deps.sh failed in the tree for $ref:" >&2
    tail -5 "$dir/.helm-deps.log" >&2
    return 1
  fi
}

# Render one layer from one tree to a file. A render failure is recorded, not
# fatal here; the caller decides what a failure at which ref means.
render() {
  tree="$1"; layer="$2"; dest="$3"
  if [ ! -d "$tree/charts/tockmox-$layer" ]; then
    echo "NO SUCH LAYER AT THIS REF" > "$dest.err"; return 1
  fi
  if ! helm template t "$tree/charts/tockmox-$layer" "${VALUES_ARGS[@]}" > "$dest" 2> "$dest.err"; then
    return 1
  fi
  rm -f "$dest.err"
}

echo "render-diff: $REF_A  ->  $REF_B"
printf 'values:'; for v in "${VALUES_ARGS[@]}"; do case "$v" in -f) ;; *) printf ' %s' "${v#$ROOT/}";; esac; done; echo
echo "layers: ${LAYERS[*]}"
echo

TREE_A="$OUT/tree-a"; TREE_B="$OUT/tree-b"
materialise "$REF_A" "$TREE_A" || exit $?
materialise "$REF_B" "$TREE_B" || exit $?

mkdir -p "$OUT/a" "$OUT/b" "$OUT/diff"
rc=0; changed=0; unchanged=0; failed_b=0; failed_a=0
SUMMARY=""
for l in "${LAYERS[@]}"; do
  ok_a=1; ok_b=1
  render "$TREE_A" "$l" "$OUT/a/$l.yaml" || ok_a=0
  render "$TREE_B" "$l" "$OUT/b/$l.yaml" || ok_b=0
  if [ "$ok_b" -eq 0 ]; then
    failed_b=$((failed_b + 1)); rc=1
    echo "== $l: FAILS TO RENDER at $REF_B"
    head -5 "$OUT/b/$l.yaml.err" | sed 's/^/     /'
    SUMMARY="${SUMMARY}$l\tRENDER FAILED at $REF_B\n"
    continue
  fi
  if [ "$ok_a" -eq 0 ]; then
    failed_a=$((failed_a + 1))
    echo "== $l: does not render at $REF_A (renders at $REF_B). Nothing to diff; the whole layer is new or was broken."
    head -3 "$OUT/a/$l.yaml.err" | sed 's/^/     /'
    SUMMARY="${SUMMARY}$l\tno render at $REF_A; $(grep -c '^kind:' "$OUT/b/$l.yaml") objects at $REF_B\n"
    continue
  fi
  if diff -u --label "$REF_A/$l" --label "$REF_B/$l" "$OUT/a/$l.yaml" "$OUT/b/$l.yaml" > "$OUT/diff/$l.diff"; then
    unchanged=$((unchanged + 1))
    SUMMARY="${SUMMARY}$l\tunchanged\n"
  else
    changed=$((changed + 1))
    add=$(grep -c '^+[^+]' "$OUT/diff/$l.diff" || true)
    del=$(grep -c '^-[^-]' "$OUT/diff/$l.diff" || true)
    ka=$(grep -c '^kind:' "$OUT/a/$l.yaml" || true); kb=$(grep -c '^kind:' "$OUT/b/$l.yaml" || true)
    echo "== $l: CHANGED  (+$add / -$del lines; $ka -> $kb objects)"
    cat "$OUT/diff/$l.diff"
    echo
    SUMMARY="${SUMMARY}$l\t+$add/-$del lines, $ka -> $kb objects\n"
  fi
done

echo "----------------------------------------------------------------"
echo "render-diff summary: $REF_A -> $REF_B"
printf "$SUMMARY" | awk -F'\t' '{ printf "  %-14s %s\n", $1, $2 }'
echo "  $changed changed, $unchanged unchanged, $failed_a absent at $REF_A, $failed_b failed at $REF_B"
echo
echo "DOES NOT PROVE THE UPGRADE APPLIES. A clean render diff says the desired"
echo "state did not move for these values. It says nothing about CRD migrations,"
echo "ArgoCD's sync behaviour on a changed resource, StatefulSet field"
echo "immutability, PVC retention, or data surviving. Only an upgrade run against"
echo "a real deployment proves those (TM-0281). Read a changed layer's diff for"
echo "a field that disappeared or a default that appeared: that is a values key"
echo "that moved, and it belongs in the release notes."
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
if [ "$FAIL_ON_DIFF" -eq 1 ] && [ "$changed" -gt 0 ]; then exit 3; fi
exit 0

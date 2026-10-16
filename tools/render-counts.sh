#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# RENDER EVERY LAYER ONCE, COUNT IT, AND LEAVE THE COUNT WHERE THE DOCS CHECK
# CAN READ IT (TM-0533).
#
#   tools/render-counts.sh               render all nine layers with
#                                        ci/values.yaml, fail on any that renders
#                                        nothing, write build/render-counts.tsv
#   tools/render-counts.sh --read KEY    print one count (a layer name, or
#                                        `total`) from that file, after proving
#                                        the file describes THIS tree
#   tools/render-counts.sh --verify      exit 0 when that file exists and
#                                        describes THIS tree, else print why
#                                        (MISSING or STALE) and exit 1
#   tools/render-counts.sh --fingerprint print this tree's fingerprint
#   tools/render-counts.sh --selftest    prove a failed render writes no file
#
# COUNTS_FILE overrides where the file is written and read (default
# build/render-counts.tsv); check-doc-claims.sh exports the path it checked.
#
# WHY A FILE. Five pages state how many resources the layers render, and every
# one of those numbers drifted: what-you-get.md said 528 and "re-derived every
# release" while the tree rendered 578, and no release re-derived anything.
# tools/doc-claims.txt can pin a number, but a nine-chart render inside the docs
# check was ruled against as duplicate work: CI already renders every layer, in
# the step this script now is. So that step writes the counts down, and the
# docs check reads them.
#
# WHY A FINGERPRINT. A counts file left over from an earlier tree would let the
# docs check pass against numbers nobody re-measured, which is the exact
# failure this exists to end. The file records a hash of everything the render
# reads (the charts, their lockfiles, ci/values.yaml), and --read refuses a file
# whose hash is not the current tree's, printing STALE so the claim fails with
# a reason instead of a wrong number.
#
# WHY NO FILE AFTER A FAILURE. A fingerprint proves which tree a file
# describes, not that the render behind it worked. Until 2026-10-16 a layer
# whose `helm template` failed counted as 0 (the `|| true` that keeps a zero
# grep from killing the script also swallowed helm's own failure), the run
# printed ::error:: and exited 1, and still wrote the file: the surviving
# layers, a short total, and a VALID fingerprint. With a helm that could not
# run at all, every layer was 0 and the file said `total 0`. The docs check
# trusted it and accused correct pages. Now a run with any failed or empty
# layer writes nothing and removes the file it would have replaced, so the
# docs check reports a missing precondition rather than a wrong count.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
# shellcheck source=tools/lib/tool-runs.sh
. tools/lib/tool-runs.sh
OUT="${COUNTS_FILE:-build/render-counts.tsv}"
VALUES=ci/values.yaml

fingerprint() {
  # Every file the render reads, except the vendored dependency archives, which
  # Chart.lock already pins and helm-deps.sh regenerates. Python rather than
  # sha256sum: macOS ships `shasum`, not `sha256sum`, and the repo already
  # requires python3.
  python3 - "$VALUES" <<'PY'
import hashlib, os, sys
paths = [sys.argv[1]]
for root, dirs, files in os.walk("charts"):
    dirs[:] = [d for d in dirs if not (root.count(os.sep) == 1 and (d == "charts" or d.startswith("tmpcharts-")))]
    paths += [os.path.join(root, f) for f in files]
h = hashlib.sha256()
for p in sorted(paths):
    h.update(p.encode() + b"\0")
    with open(p, "rb") as fh:
        h.update(hashlib.sha256(fh.read()).digest())
print(h.hexdigest()[:16])
PY
}

# verify -> 0 when $OUT exists and describes this tree; else prints why, 1.
verify() {
  [ -f "$OUT" ] || { echo "MISSING ($OUT: run tools/render-counts.sh first)"; return 1; }
  local have; have="$(awk -F'\t' '$1=="fingerprint"{print $2}' "$OUT")"
  [ "$have" = "$(fingerprint)" ] || { echo "STALE ($OUT describes another tree: run tools/render-counts.sh)"; return 1; }
}

case "${1:-}" in
  --fingerprint) fingerprint; exit 0 ;;
  --verify) verify; exit $? ;;
  --read)
    key="${2:?usage: $0 --read <layer|total>}"
    verify || exit 1
    v="$(awk -F'\t' -v k="$key" '$1==k{print $2}' "$OUT")"
    [ -n "$v" ] || { echo "NO-SUCH-KEY ($key)"; exit 1; }
    echo "$v"; exit 0 ;;
  --selftest)
    set +e   # the probes read exit statuses that are meant to be non-zero
    # Runs this script end to end with a fixture helm on a HERMETIC PATH (the
    # fixture dir, then /usr/bin:/bin; python3 is linked in for the
    # fingerprint), so a real helm on the machine can neither shadow nor be
    # shadowed by the fixture. Each failing case starts with a stale counts
    # file in place and must leave none behind.
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    py="$(command -v python3)" || { echo "selftest: python3 not on PATH; refusing"; exit 2; }
    fx() { mkdir -p "$tmp/$1"; ln -s "$py" "$tmp/$1/python3"; }
    fx good;   printf '#!/bin/sh\n[ "$1" = version ] && exit 0\nprintf "kind: A\\nkind: B\\n"\n' > "$tmp/good/helm"
    fx fails;  printf '#!/bin/sh\n[ "$1" = version ] && exit 0\necho "Error: boom" >&2; exit 1\n' > "$tmp/fails/helm"
    fx empty;  printf '#!/bin/sh\nexit 0\n' > "$tmp/empty/helm"
    fx broken; printf '\177ELF not a program for this machine\n' > "$tmp/broken/helm"
    fx onebad; printf '#!/bin/sh\n[ "$1" = version ] && exit 0\ncase "$3" in *selfcheck) exit 1;; esac\nprintf "kind: A\\n"\n' > "$tmp/onebad/helm"
    chmod +x "$tmp"/*/helm
    nlayers=0; for c in charts/tockmox-*; do [ "$c" = charts/tockmox-common ] || nlayers=$((nlayers + 1)); done
    fails=0
    probe() {
      local label="$1" dir="$2" want="$3" why="$4" out rc f="$tmp/$2.tsv"
      printf 'total\t1\nfingerprint\tdeadbeefdeadbeef\n' > "$f"
      out=$(COUNTS_FILE="$f" PATH="$tmp/$dir:/usr/bin:/bin" "$BASH" "$SELF" 2>&1); rc=$?
      if [ "$rc" -ne "$want" ]; then
        echo "  SELFTEST FAIL: '$label' wanted exit $want, got $rc:"; printf '%s\n' "$out" | sed 's/^/            /'; fails=1
      elif [ -n "$why" ] && ! printf '%s\n' "$out" | grep -F -- "$why" >/dev/null; then
        echo "  SELFTEST FAIL: '$label' exited $rc but not for the reason '$why':"; printf '%s\n' "$out" | sed 's/^/            /'; fails=1
      elif [ "$want" -ne 0 ] && [ -e "$f" ]; then
        echo "  SELFTEST FAIL: '$label' left a counts file behind:"; sed 's/^/            /' "$f"; fails=1
      elif [ "$want" -eq 0 ] && ! COUNTS_FILE="$f" "$BASH" "$SELF" --verify >/dev/null; then
        echo "  SELFTEST FAIL: '$label' wrote a file that does not verify"; fails=1
      elif [ "$want" -eq 0 ] && [ "$(COUNTS_FILE="$f" "$BASH" "$SELF" --read total)" != "$((nlayers * 2))" ]; then
        echo "  SELFTEST FAIL: '$label' total is not $((nlayers * 2))"; fails=1
      else
        echo "  selftest ok: $label"
      fi
    }
    probe "a render that works writes every layer, the total and a fingerprint" good 0 ""
    probe "a helm template that fails writes no file"                   fails  1 "helm template failed"
    probe "a layer that renders nothing writes no file"                 empty  1 "rendered ZERO"
    probe "one failed layer among good ones writes no file"             onebad 1 "tockmox-selfcheck: helm template failed"
    probe "a helm that cannot run is refused before any render"         broken 2 "cannot run"
    [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
    echo "selftest FAILED"; exit 1 ;;
esac

# Probe that helm EXECUTES, not merely that a file is there (tools/lib/tool-runs.sh).
if [ "$(tool_state helm)" != ok ]; then
  echo "render-counts: $(tool_why helm); refusing rather than guessing"
  rm -f "$OUT"; exit 2
fi
mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp)"; rend="$(mktemp)"; err="$(mktemp)"; trap 'rm -f "$tmp" "$rend" "$err"' EXIT
fail=0; total=0
for c in charts/tockmox-*; do
  [ "$c" = "charts/tockmox-common" ] && continue
  layer="${c#charts/tockmox-}"
  # helm's own exit status is read first, then the ARTIFACT: helm lint passing
  # says nothing about whether anything rendered, and a failed render is not a
  # render of zero.
  if ! helm template t "$c" -f "$VALUES" > "$rend" 2> "$err"; then
    echo "::error::$c: helm template failed"
    tail -n 5 "$err" | sed 's/^/    /'
    fail=1; continue
  fi
  n=$(grep -c '^kind:' "$rend" || true)
  printf '%-34s %s resources\n' "$c" "$n"
  if [ "$n" -gt 0 ]; then printf '%s\t%s\n' "$layer" "$n" >> "$tmp"; total=$((total + n))
  else echo "::error::$c rendered ZERO resources"; fail=1; fi
done
if [ "$fail" -ne 0 ]; then
  rm -f "$OUT"
  echo "render-counts: FAILED; no counts written, and any earlier $OUT removed so nothing reads a half measurement"
  exit 1
fi
printf 'total\t%s\n' "$total" >> "$tmp"
printf 'fingerprint\t%s\n' "$(fingerprint)" >> "$tmp"
mv "$tmp" "$OUT"
echo "total: $total resources; counts written to $OUT"
exit 0

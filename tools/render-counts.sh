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
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/render-counts.tsv
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

if [ "${1:-}" = "--read" ]; then
  key="${2:?usage: $0 --read <layer|total>}"
  [ -f "$OUT" ] || { echo "MISSING ($OUT: run tools/render-counts.sh first)"; exit 1; }
  have="$(awk -F'\t' '$1=="fingerprint"{print $2}' "$OUT")"
  [ "$have" = "$(fingerprint)" ] || { echo "STALE ($OUT describes another tree: run tools/render-counts.sh)"; exit 1; }
  v="$(awk -F'\t' -v k="$key" '$1==k{print $2}' "$OUT")"
  [ -n "$v" ] || { echo "NO-SUCH-KEY ($key)"; exit 1; }
  echo "$v"; exit 0
fi

command -v helm >/dev/null 2>&1 || { echo "render-counts: helm not on PATH; refusing rather than guessing"; exit 2; }
mkdir -p build
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
fail=0; total=0
for c in charts/tockmox-*; do
  [ "$c" = "charts/tockmox-common" ] && continue
  layer="${c#charts/tockmox-}"
  # Assert on the ARTIFACT, not the exit code: helm lint passing says nothing
  # about whether anything rendered.
  n=$(helm template t "$c" -f "$VALUES" | grep -c '^kind:' || true)
  printf '%-34s %s resources\n' "$c" "$n"
  if [ "$n" -gt 0 ]; then printf '%s\t%s\n' "$layer" "$n" >> "$tmp"; total=$((total + n))
  else echo "::error::$c rendered ZERO resources"; fail=1; fi
done
printf 'total\t%s\n' "$total" >> "$tmp"
printf 'fingerprint\t%s\n' "$(fingerprint)" >> "$tmp"
mv "$tmp" "$OUT"; trap - EXIT
echo "total: $total resources; counts written to $OUT"
exit $fail

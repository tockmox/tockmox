#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build the operator documentation site from the working tree.
#
#   ./tools/build-docs.sh [OUTDIR]     default OUTDIR is build/docs-site
#
# THE SITE IS WHAT tools/publish-docs.sh UPLOADS TO THE DOCS BUCKET (TM-0805).
# Garage serves it, so an air-gapped install has its manual at the moment it has
# no network. Tockmox publishes no image and no tarball of it (ADR-0036): the
# operator builds it from the checkout they deploy. Everything about this script
# exists to keep that true:
#
#   1. Pages are chosen by tockmox.audience frontmatter, parsed, in
#      tools/lib/stage-docs.py (which explains the rule and the link handling).
#   2. MkDocs Material builds the staged copy with the base config in
#      docs-site/mkdocs.yml. `strict: true`, so a broken link or anchor fails.
#   3. The result is NOT trusted. tools/check-docs-offline.sh reads the built
#      files for anything that would fetch from the network. Run it after this.
#
# REFUSES WITHOUT THE PINNED GENERATOR. Every line of docs-site/requirements.txt
# must be installed at exactly that version, or this exits 2 and builds nothing.
# 2 is the repo's "skipped, substrate absent" code (see check-all.sh), not a
# failure of the tree. A build with "whatever mkdocs is on PATH" would produce a
# different site on every laptop, and nobody can review a site they cannot
# reproduce.
#
#   python3 -m venv .venv-docs && . .venv-docs/bin/activate
#   pip install -r docs-site/requirements.txt
#
# DETERMINISM. Pages are staged in sorted order, the locale and timezone are
# pinned, and MkDocs writes no build timestamp into the pages it emits. Two
# builds of one tree should be byte-identical; `diff -r` two output directories
# to check, which is how this was verified (REPORT for TM-0215 has the output).
#
# OVERRIDES: TOCKMOX_DOCS_REF (default v<tockmox-common chart version>) is the
# git ref that links to files outside the docs are pointed at;
# TOCKMOX_UPSTREAM (default https://github.com/tockmox/tockmox) is the repo.
# PYTHON (default python3) is the interpreter that has the pinned packages.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/docs-site}"
PYTHON="${PYTHON:-python3}"
UPSTREAM="${TOCKMOX_UPSTREAM:-https://github.com/tockmox/tockmox}"
export LC_ALL=C TZ=UTC PYTHONHASHSEED=0 PYTHONDONTWRITEBYTECODE=1
# The theme prints a banner about MkDocs 2.0 on every build; it is about a
# framework this pin never moves to, so silence it rather than train people to skim.
export NO_MKDOCS_2_WARNING=true

command -v "$PYTHON" >/dev/null 2>&1 || { echo "SKIPPED: $PYTHON not found" >&2; exit 2; }

# ---- refuse without the pinned generator ------------------------------------
"$PYTHON" - docs-site/requirements.txt <<'PY' || exit 2
import re, sys
from importlib import metadata
def norm(n): return re.sub(r"[-_.]+", "-", n).lower()
bad = []
for line in open(sys.argv[1]):
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    name, _, want = line.partition("==")
    try:
        have = metadata.version(name)
    except metadata.PackageNotFoundError:
        have = None
    if have != want:
        bad.append("  %s: pinned %s, installed %s" % (norm(name), want, have or "NOT INSTALLED"))
if bad:
    print("SKIPPED: the pinned documentation toolchain is not installed:", file=sys.stderr)
    print("\n".join(bad[:8]) + ("\n  ... and %d more" % (len(bad) - 8) if len(bad) > 8 else ""), file=sys.stderr)
    print("  python3 -m venv .venv-docs && . .venv-docs/bin/activate && "
          "pip install -r docs-site/requirements.txt", file=sys.stderr)
    sys.exit(2)
print("toolchain: %d pinned packages match" % sum(1 for l in open(sys.argv[1]) if l.split("#",1)[0].strip()))
PY

VERSION="$(sed -n 's/^version:[[:space:]]*//p' charts/tockmox-common/Chart.yaml | head -1 | tr -d '"')"
[ -n "$VERSION" ] || { echo "cannot read the chart version from charts/tockmox-common/Chart.yaml" >&2; exit 1; }
REF="${TOCKMOX_DOCS_REF:-v$VERSION}"

# ---- refuse to delete something that is not a previous build ----------------
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  if [ ! -f "$OUT/search/search_index.json" ] || [ ! -f "$OUT/sitemap.xml" ]; then
    echo "REFUSED: $OUT exists, is not empty, and does not look like a previous docs build." >&2
    echo "         Not deleting it. Choose another OUTDIR or remove it yourself." >&2
    exit 1
  fi
  rm -rf "$OUT"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-docs-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

"$PYTHON" tools/lib/stage-docs.py --root . --stage "$STAGE/s" --ref "$REF" --upstream "$UPSTREAM"

mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
"$PYTHON" -m mkdocs build --strict --quiet -f "$STAGE/s/mkdocs.yml" -d "$OUT_ABS"

PAGES=$(find "$OUT_ABS" -name '*.html' | wc -l | tr -d ' ')
echo "built $OUT ($PAGES html files, $(du -sk "$OUT_ABS" | cut -f1) KiB) for ref $REF"

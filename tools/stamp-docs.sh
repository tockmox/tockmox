#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Stamp the brand header and the version/copyright/licence footer onto every
# documentation page. Run from anywhere; operates on the repo root.
#
#   ./tools/stamp-docs.sh            rewrite the blocks in place
#   ./tools/stamp-docs.sh --check    fail if any file is out of date (CI)
#
# WHY GENERATED. A version number typed into forty markdown files is forty
# places to forget on release day, and the failure is invisible: the docs simply
# claim a version that shipped months ago and nobody notices because nothing
# breaks. The blocks live between markers and are regenerated from Chart.yaml,
# so the release process cannot leave them behind.
#
# WHY THE VERSION COMES FROM Chart.yaml. It is the version that is actually
# published. Anything else is a second source of truth, which is another way of
# saying a source of drift. All nine layer charts must agree, and this script
# refuses to run if they do not -- a split version is a release bug worth
# catching here rather than in an issue three weeks later.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

versions=$(grep -h '^version:' charts/tockmox-*/Chart.yaml | awk '{print $2}' | sort -u)
if [ "$(printf '%s\n' "$versions" | wc -l)" -ne 1 ]; then
  echo "ERROR: layer charts disagree on version:" >&2
  printf '%s\n' "$versions" >&2
  exit 1
fi
VERSION="$versions"
YEAR=$(date -u +%Y)

VERSION="$VERSION" YEAR="$YEAR" CHECK="$CHECK" python3 - <<'PY'
import os
import pathlib
import re
import sys

VERSION = os.environ["VERSION"]
YEAR = os.environ["YEAR"]
CHECK = os.environ["CHECK"] == "1"
HOLDER = "Tockmox LLC"

ROOT = pathlib.Path(".").resolve()
HB, HE = "<!-- tockmox:header:begin -->", "<!-- tockmox:header:end -->"
FB, FE = "<!-- tockmox:footer:begin -->", "<!-- tockmox:footer:end -->"

# docs/ only. The top-level README is the project's front page and is
# hand-composed; LICENSE, NOTICE and the community files are legal texts that
# must not grow generated furniture.
targets = sorted(p for p in ROOT.joinpath("docs").rglob("*.md"))


def rel(frm: pathlib.Path, to: str) -> str:
    return os.path.relpath(ROOT / to, frm.parent)


def footer(p: pathlib.Path) -> str:
    """ONE line. Deliberately.

    The first version of this stamped a centred logo at the top of every page
    and a five-line licence block at the bottom. Both were wrong:

    - The logo was a per-page image with a relative path. The published user
      docs site copies a SUBSET of docs/ and does not carry docs/assets, so
      every one of those images was a broken-image icon. Branding belongs in
      the site theme, where it is applied once and cannot go stale per page.
    - The licence block was longer than some of the sections above it. Legal
      labelling should be present, findable and quiet. This is one line of
      <sub>, which renders small on GitHub and small in mkdocs-material.

    NO LINKS, deliberately. Relative links to LICENSE / TRADEMARKS.md resolve
    on GitHub and on the admin docs site, and 404 on the user docs site, which
    carries a subset of docs/ and none of the repo root. The line exists to
    LABEL, not to navigate: it states the version, the holder and both licence
    names, and the files themselves are one click away at the repo root. A
    label that is correct on every surface beats a link that is correct on two
    of three.
    """
    return (
        f'{FB}\n'
        f'\n---\n\n'
        f'<sub>Tockmox v{VERSION} &middot; &copy; {YEAR} {HOLDER} &middot; '
        f'code Apache-2.0, docs CC BY 4.0 &middot; '
        f'Tockmox is a trademark</sub>\n'
        f'{FE}'
    )


def strip_header(text: str) -> str:
    """Remove the retired header block, and the blank lines it left behind."""
    pattern = re.compile(
        re.escape(HB) + ".*?" + re.escape(HE) + r"\n*", re.DOTALL)
    return pattern.sub("", text)


def splice(text: str, begin: str, end: str, block: str, where: str) -> str:
    pattern = re.compile(
        re.escape(begin) + ".*?" + re.escape(end), re.DOTALL)
    if pattern.search(text):
        return pattern.sub(lambda _: block, text, count=1)
    if where == "top":
        return block + "\n\n" + text.lstrip("\n")
    return text.rstrip("\n") + "\n\n" + block + "\n"


stale = []
for p in targets:
    original = p.read_text()
    updated = strip_header(original)
    updated = splice(updated, FB, FE, footer(p), "bottom")
    if updated != original:
        stale.append(p.relative_to(ROOT))
        if not CHECK:
            p.write_text(updated)

if CHECK:
    if stale:
        print("ERROR: documentation stamps are out of date. Run ./tools/stamp-docs.sh:",
              file=sys.stderr)
        for s in stale:
            print(f"  {s}", file=sys.stderr)
        sys.exit(1)
    print(f"stamps current in {len(targets)} page(s), version {VERSION}")
else:
    print(f"stamped {len(targets)} page(s) at version {VERSION}"
          + (f", {len(stale)} changed" if stale else ", no change"))
PY

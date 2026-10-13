#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Generate the docs index surfaces, or fail when a committed one is stale.
#
#   ./tools/gen-docs-index.sh              rewrite the generated blocks
#   ./tools/gen-docs-index.sh --check      fail when a block differs from a fresh render (CI)
#   ./tools/gen-docs-index.sh --selftest   prove the checks can go red
#
# WHY GENERATED (TM-0228). Every hand-maintained count in this repo has gone
# stale at least once, and these surfaces track nine charts and some fifty
# pages. The layer table in docs/architecture.md takes its wave from each
# charts/*/Chart.yaml and asserts the installer's wave() function agrees. The
# four section READMEs take titles and descriptions from page frontmatter, in
# the reading order tools/docs-index-order.txt records. Prose outside the
# <!-- tockmox:...:begin --> markers stays hand-written. The logic and the
# editorial columns live in tools/lib/gen_docs_index.py.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 tools/lib/gen_docs_index.py "$@"

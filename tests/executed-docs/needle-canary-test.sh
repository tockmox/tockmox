#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Every block a path asks its page for resolves to exactly one block, checked per commit.
#
# Run 42074588954 (2026-11-05, the p09 lane): S20's needle matched two install.md blocks, the 3c
# first-sight block and the single read under The readiness bar. The extractor rightly refused,
# but nothing checked P09's needles before a live lab run did. lib/path-needles.py lists every
# lookup P09 makes (block, step_begin, block_sec, block_in and their _sha forms); this asks
# extract-block.sh to resolve each one against the working tree's page.
#
# Hermetic: no cluster, no network. Cases:
#   1. P09 against install.md resolves every lookup, and there are enough lookups to mean something
#   2. a second block containing S20's needle in S20's section goes red, naming the needle
#   3. a whole-page needle written into a second block goes red (ambiguous)
#   4. a needle the page no longer contains goes red (gone)
#   5. the lister refuses a needle that expands at run time instead of skipping it
#
#   ./tests/executed-docs/needle-canary-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
E="${HERE}/lib/extract-block.sh"
L="${HERE}/lib/path-needles.py"
P09="${HERE}/paths/P09-install-md-end-to-end.sh"
PAGE="${HERE}/../../docs/deployment/install.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

# unresolved PATH PAGE ... one line per lookup that does not name exactly one block. Exit 2 when the
# lister refuses the path, so a refusal is never read as "nothing unresolved".
unresolved() {
  local rows k s sel err rc
  rows="$(python3 "$L" "$1")" || return 2
  printf '%s\n' "$rows" > "${TMP}/rows"
  while IFS=$'\t' read -r k s sel; do
    [ -n "$k" ] || continue
    if [ "$k" = needle ]; then err="$(bash "$E" --file "$2" --section "$s" --lang bash --containing "$sel" 2>&1 >/dev/null)"; rc=$?
    else err="$(bash "$E" --file "$2" --section "$s" --lang bash --block "$sel" 2>&1 >/dev/null)"; rc=$?; fi
    [ "$rc" -eq 0 ] || printf 'UNRESOLVED [%s] under [%s]: %s\n' "$sel" "$s" "$(printf '%s' "$err" | head -1)"
  done < "${TMP}/rows"
  return 0
}

# 1. the shipped pair
out="$(unresolved "$P09" "$PAGE")"; rc=$?
n="$(grep -c . "${TMP}/rows" 2>/dev/null || echo 0)"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$n" -ge 30 ]; then
  ok "every block P09 asks install.md for resolves to exactly one block (${n} lookups)"
else
  bad "P09's lookups on install.md" "rc=${rc}, ${n} lookup(s); $(printf '%s' "$out" | head -3)"
fi

# shellcheck disable=SC2016  # the needle is page text, matched literally
S20='logs deploy/tockmox-devops-argo-workflows-server --tail=3'
fixture() { # NAME PYTHON-EDIT ... a copy of the page with one edit
  python3 - "$PAGE" "${TMP}/$1.md" "$2" <<'PY'
import sys
src, dst, how = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read()
s2 = eval(how, {"s": s})
assert s2 != s, "the fixture edit changed nothing"
open(dst, "w", encoding="utf-8").write(s2)
PY
}

# 2. S20-style: a second block holding S20's needle inside S20's own section
# shellcheck disable=SC2016  # a Python expression, passed whole
fixture s20dup 's.replace("### The readiness bar\n", "### The readiness bar\n\n```bash\nkubectl -n tockmox-devops \\\n  logs deploy/tockmox-devops-argo-workflows-server --tail=3\n```\n", 1)'
out="$(unresolved "$P09" "${TMP}/s20dup.md")"
hit="$(grep -F "[${S20}] under [### The readiness bar]" <<<"$out")"
if [[ "$hit" == *AMBIGUOUS* ]]; then
  ok "a second block with S20's needle in its section goes red, naming the needle (ambiguous)"
else
  bad "the S20-style duplicate" "got: $(printf '%s' "$out" | head -3)"
fi

# 3. a whole-page needle written into a second block
# shellcheck disable=SC2016  # a Python expression, passed whole
fixture dup 's + "\n## Appendix\n\n```bash\nkubeseal --version\n```\n"'
out="$(unresolved "$P09" "${TMP}/dup.md")"
hit="$(grep -F '[kubeseal --version]' <<<"$out")"
if [[ "$hit" == *AMBIGUOUS* ]]; then
  ok "a whole-page needle in a second block goes red (ambiguous)"
else
  bad "the whole-page duplicate" "got: $(printf '%s' "$out" | head -3)"
fi

# 4. a needle the page no longer contains
fixture gone 's.replace("kubeseal --version", "kubeseal version")'
out="$(unresolved "$P09" "${TMP}/gone.md")"
if [[ "$out" == *"[kubeseal --version]"* ]]; then
  ok "a needle the page no longer contains goes red"
else
  bad "the vanished needle" "got: $(printf '%s' "$out" | head -3)"
fi

# 5. the lister refuses what it cannot check
# shellcheck disable=SC2016  # the fixture's own text: these must stay unexpanded
printf '%s\n' 'SECTION="${X:-# Page}"' 'B="$(block "a $SOMETHING b")"' > "${TMP}/expands.sh"
if python3 "$L" "${TMP}/expands.sh" >/dev/null 2>&1; then
  bad "the lister refuses a needle that expands at run time" "it exited 0"
else
  ok "the lister refuses a needle that expands at run time, rather than skipping it"
fi

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

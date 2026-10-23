#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The AI-node toolkit's static and hermetic checks (ai-node/).
#
#   ./tools/check-ai-node.sh              lint and test; needs no Mac and no network
#   ./tools/check-ai-node.sh --selftest   prove the home-made lints can go red
#   ./tools/check-ai-node.sh --e2e        run only the Linux simulation (opt-in, see below)
#
# WHAT IT PROVES
#   - every shell script passes shellcheck, and the ones that run on the Mac (bootstrap-node.sh and
#     bin/) contain none of the bash 4 features macOS's bash 3.2 does not have;
#   - the playbook passes ansible-playbook --syntax-check, yamllint and ansible-lint at the
#     production profile;
#   - the Python unit tests pass (filters, model helper, pf evidence reader, templates, and the
#     repository's own rules: every role exists, every role stops on Linux with the phase 6 sentence,
#     an SPDX line on every file, no em-dash);
#   - the converger wrapper's recap parser, metrics writer, signature verification (warn and
#     enforce, a signer rotation, a rewritten history), the "another converger" refusal and a play
#     that fails to load behave as documented, against a real git repository and a fake ansible;
#   - the engine watch restarts an engine whose health path answers 503 on consecutive checks, once,
#     and counts it; a single 503, a 200, no answer or a failed kickstart restart or count nothing;
#   - the toolkit selection (the repository is pinned on the node, the ref comes only from a verified
#     head) and the root-run firewall scripts, rendered from their templates and run against a fake
#     pfctl: the boot marker, the rollback that restores the last confirmed rules (never an empty
#     anchor), the start wrapper that waits for the marker, and the script that closes the listeners;
#   - the site files as data: they reach the play only as tn_site.ai_node and tn_site.desired (marked
#     !unsafe), no role reads a schema key as a bare variable, and a file that does not match its
#     schema, at any depth, is refused before any role runs;
#   - bootstrap-node.sh, run end to end against fakes of the macOS tools it calls: the accounts, the
#     tree, the keys (only public halves printed), the questions it asks and what it pins when told
#     yes or no, a deploy key that can write being refused, adoption, a dry run that touches nothing,
#     a second run that changes nothing; and a call without its required flags is refused first.
#
# WHAT IT DOES NOT PROVE: anything that happens on a Mac. The roles call macOS tools (launchctl, pfctl,
# sysadminctl, pmset, ...). ai-node/tests/e2e/run.sh runs the whole playbook on Linux against
# shims for those tools, which tests the playbook's own logic (ordering, idempotence, refusals) and
# nothing about macOS. It changes the host (it makes empty directories such as /Library and /Users,
# and mounts tmpfs and overlays inside a private mount namespace), needs root, and takes about five
# minutes, so it runs only with --e2e (tools/check-all.sh passes it when TOCKMOX_AI_NODE_E2E=1). docs/administration/ai-nodes.md
# lists what is unproven and the command that proves each item on a Mac.
#
# Exit: 0 passed, 1 failed, 2 a required tool is missing (or --e2e could not run).
# shellcheck disable=SC2015  # "test && ok || bad" is this file's idiom; ok never fails
# shellcheck disable=SC2016  # the lint patterns and the test lines are literal on purpose
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

AI=ai-node
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /' | head -n 20; fail=1; }

# --------------------------------------------------------------------- the home-made lints
# Each takes a directory (so --selftest can feed it a broken copy) and prints offending lines.

# bash 4 features that macOS's /bin/bash 3.2 lacks. Comment lines are not scanned.
lint_bash4() {
  local dir="$1" f
  for f in "$dir/bootstrap-node.sh" "$dir"/bin/*; do
    [ -f "$f" ] || continue
    grep -nE '(^|[^#[:alnum:]_])(declare|typeset|local)[[:space:]]+-[A-Za-z]*[AnN]\b|\b(mapfile|readarray|coproc)\b|\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^|,|\^)[^}]*\}|\|&|&>>|;;&|;&|\[\[[[:space:]]+-v[[:space:]]|\$\{!?[A-Za-z_]+@[AaEPQUuLK]\}|printf[[:space:]]+-v[[:space:]]+[A-Za-z_]+\[|EPOCHSECONDS|EPOCHREALTIME|\$BASHPID|\bwait[[:space:]]+-n\b|\bread[[:space:]]+-[a-z]*t[[:space:]]+0\.[0-9]' "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
  done
}

# GNU-only options in the scripts that run on the Mac: sed -r, sort -V, grep -P, readlink -f, date -d, stat -c, xargs -r.
lint_gnu() {
  local dir="$1" f
  for f in "$dir/bootstrap-node.sh" "$dir"/bin/*; do
    [ -f "$f" ] || continue
    grep -nE '\bsed[[:space:]]+(-[A-Za-z]*r|--regexp-extended)\b|\bsort[[:space:]]+-[A-Za-z]*V|\bgrep[[:space:]]+-[A-Za-z]*P|\breadlink[[:space:]]+-f|\bdate[[:space:]]+-d\b|\bxargs[[:space:]]+-r\b|\bsed[[:space:]]+-i[[:space:]]+[^.]' "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
  done
}

# U+2014 anywhere in the toolkit or its page (the repository's style rule).
lint_emdash() {
  local d
  for d in "$@"; do
    [ -e "$d" ] || continue
    grep -rIl --exclude-dir=.cache --exclude-dir=__pycache__ "$(printf '\342\200\224')" "$d" 2>/dev/null
  done
}

# Secrets must never be echoed: no 'age-keygen' without -o/-y, no cat of a private key in the scripts.
lint_secret_print() {
  local dir="$1"
  grep -nE 'cat[[:space:]]+[^|;&]*(age\.key|deploy_key)([^.]|$)|echo[^|;&]*(AGE-SECRET-KEY|PRIVATE KEY)' "$dir/bootstrap-node.sh" "$dir"/bin/* 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#'
}

selftest() {
  local t rc=0 out; t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  mkdir -p "$t/ai-node/bin"
  printf '#!/bin/bash\necho fine\n' > "$t/ai-node/bootstrap-node.sh"
  cp "$t/ai-node/bootstrap-node.sh" "$t/ai-node/bin/x"
  [ -z "$(lint_bash4 "$t/ai-node")$(lint_gnu "$t/ai-node")$(lint_secret_print "$t/ai-node")" ] || { echo "selftest: the clean copy is not clean"; return 1; }
  try() {  # NAME LINE LINTFN
    printf '#!/bin/bash\n%s\n' "$2" > "$t/ai-node/bin/x"
    out="$($3 "$t/ai-node")"
    if [ -n "$out" ]; then echo "  ok   $1 goes red"; else echo "  FAIL selftest: $1 was not caught"; rc=1; fi
  }
  try "declare -A"            'declare -A m'                          lint_bash4
  try "mapfile"               'mapfile -t a < f'                      lint_bash4
  try "lowercasing expansion" 'x=${y,,}'                              lint_bash4
  try "uppercasing expansion" 'x=${y^^}'                              lint_bash4
  try "|&"                    'a |& b'                                lint_bash4
  try "[[ -v"                 '[[ -v x ]] && :'                       lint_bash4
  try "local -n"              'f() { local -n r=x; }'                 lint_bash4
  try "sed -r"                'sed -r s/a/b/ f'                       lint_gnu
  try "sort -V"               'sort -V f'                             lint_gnu
  try "grep -P"               'grep -P x f'                           lint_gnu
  try "readlink -f"           'readlink -f f'                         lint_gnu
  try "cat of the age key"    'cat /opt/tockmox/etc/age.key'          lint_secret_print
  printf '#!/bin/bash\n# declare -A m is only a comment\n' > "$t/ai-node/bin/x"
  if [ -z "$(lint_bash4 "$t/ai-node")" ]; then echo "  ok   a comment is not flagged"; else echo "  FAIL selftest: a comment was flagged"; rc=1; fi
  mkdir -p "$t/docs"; printf 'a %s b\n' "$(printf '\342\200\224')" > "$t/docs/p.md"
  if [ -n "$(lint_emdash "$t/docs")" ]; then echo "  ok   an em-dash goes red"; else echo "  FAIL selftest: an em-dash was not caught"; rc=1; fi
  [ "$rc" = 0 ] && echo "selftest: every home-made lint can go red" || echo "selftest: FAILED" >&2
  return "$rc"
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

if [ "${1:-}" = "--e2e" ]; then
  echo "simulation"
  bash "$AI/tests/e2e/run.sh"; rc=$?
  if [ "$rc" = 2 ]; then echo "check-ai-node: the simulation needs root, Linux and unshare -m" >&2; exit 2; fi
  [ "$rc" = 0 ] && echo "check-ai-node: the playbook converges, twice, against the macOS shims" || echo "check-ai-node: the simulation FAILED" >&2
  exit "$rc"
fi

# --------------------------------------------------------------------- tools
missing=""
for c in python3 shellcheck ansible-playbook ansible-lint yamllint git ssh-keygen shasum; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then echo "check-ai-node: missing tools:$missing" >&2; exit 2; fi
python3 -c 'import yaml, jinja2' 2>/dev/null || { echo "check-ai-node: python3 needs PyYAML and Jinja2 (they come with ansible)" >&2; exit 2; }


# --------------------------------------------------------------------- shellcheck and portability
echo "shell scripts"
if out="$(shellcheck -x "$AI/bootstrap-node.sh" "$AI"/bin/* "$AI/tests/converge-wrapper.sh" "$AI/tests/bootstrap-flow.sh" "$AI/tests/firewall-scripts.sh" "$AI/tests/engine-watch.sh" "$AI/tests/e2e/run.sh" "$AI"/tests/e2e/shims/* 2>&1 | head -n 40)"; [ -z "$out" ]; then ok "shellcheck passes on every ai-node script"; else bad "shellcheck" "$out"; fi
out="$(lint_bash4 "$AI")"; [ -z "$out" ] && ok "no bash 4 feature in the scripts that run on the Mac" || bad "bash 4 features (macOS ships bash 3.2)" "$out"
out="$(lint_gnu "$AI")";   [ -z "$out" ] && ok "no GNU-only option in the scripts that run on the Mac" || bad "GNU-only options (macOS has BSD userland)" "$out"
out="$(lint_secret_print "$AI")"; [ -z "$out" ] && ok "no script prints a private key" || bad "a script prints a private key" "$out"
for f in "$AI/bootstrap-node.sh" "$AI"/bin/*; do
  head -n 1 "$f" | grep -qE '^#!(/bin/bash|/usr/bin/env bash)$' || bad "$f has a shebang other than bash" "$(head -n 1 "$f")"
  [ -x "$f" ] || bad "$f is not executable"
done
bash -n "$AI/bootstrap-node.sh" && bash -n "$AI/bin/tockmox-ai-node-converge" && bash -n "$AI/bin/tockmox-ai-node-facts" && bash -n "$AI/bin/tockmox-ai-node-engine-watch" && ok "bash -n passes" || bad "bash -n"

# --------------------------------------------------------------------- the playbook
echo "playbook"
if out="$(cd "$AI" && ANSIBLE_CONFIG=ansible.cfg ansible-playbook -i localhost, --syntax-check playbooks/ai-node.yml 2>&1)"; then ok "ansible-playbook --syntax-check"; else bad "ansible-playbook --syntax-check" "$out"; fi
if out="$(cd "$AI" && yamllint -s . 2>&1)"; then ok "yamllint (strict)"; else bad "yamllint" "$out"; fi
if out="$(cd "$AI" && ansible-lint 2>&1 | tail -n 15)"; echo "$out" | grep -q "Passed: 0 failure(s), 0 warning(s)"; then ok "ansible-lint, production profile"; else bad "ansible-lint" "$out"; fi

# --------------------------------------------------------------------- tests
echo "tests"
if out="$(python3 -W error -m unittest discover -s "$AI/tests/unit" 2>&1 | tail -n 25)"; echo "$out" | grep -q '^OK'; then ok "python unit tests: $(echo "$out" | grep '^Ran')"; else bad "python unit tests" "$out"; fi
if out="$(bash "$AI/tests/converge-wrapper.sh" 2>&1)"; then ok "converger wrapper tests: $(echo "$out" | tail -n 1)"; else bad "converger wrapper tests" "$(echo "$out" | grep -E 'FAIL|want' | head -n 15)"; fi

if out="$(bash "$AI/tests/firewall-scripts.sh" 2>&1)"; then ok "firewall script tests: $(echo "$out" | tail -n 1)"; else bad "firewall script tests" "$(echo "$out" | grep -E 'FAIL|want' | head -n 15)"; fi

if out="$(bash "$AI/tests/engine-watch.sh" 2>&1)"; then ok "engine watch tests: $(echo "$out" | tail -n 1)"; else bad "engine watch tests" "$(echo "$out" | grep -E 'FAIL|want' | head -n 15)"; fi

if out="$(bash "$AI/tests/bootstrap-flow.sh" 2>&1)"; then ok "bootstrap flow tests: $(echo "$out" | tail -n 1)"; else bad "bootstrap flow tests" "$(echo "$out" | grep -E 'FAIL|want' | head -n 15)"; fi

# bootstrap refuses an incomplete or wrong call, before it touches anything
b="$AI/bootstrap-node.sh"
out="$(bash "$b" 2>&1)"; rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q -- '--ai-node-id is required' && ok "bootstrap: no node id is refused" || bad "bootstrap: no node id is refused" "$out"
out="$(bash "$b" --ai-node-id Bad_Id --site-repo x 2>&1)"; rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'lower-case' && ok "bootstrap: a malformed node id is refused" || bad "bootstrap: a malformed node id is refused" "$out"
out="$(bash "$b" --ai-node-id n1 --site-repo x --signing-mode lax 2>&1)"; rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'warn or enforce' && ok "bootstrap: an unknown signing mode is refused" || bad "bootstrap: an unknown signing mode is refused" "$out"
out="$(bash "$b" --bogus 2>&1)"; rc=$?
[ "$rc" = 64 ] && ok "bootstrap: an unknown option exits 64" || bad "bootstrap: an unknown option exits 64" "rc=$rc $out"
out="$(bash "$b" --help 2>&1)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q -- '--site-repo' && ok "bootstrap: --help prints the options" || bad "bootstrap: --help prints the options" "$out"
if [ "$(uname -s)" != Darwin ]; then
  out="$(bash "$b" --ai-node-id n1 --site-repo https://example.invalid/s.git --dry-run 2>&1)"; rc=$?
  [ "$rc" != 0 ] && echo "$out" | grep -q 'for macOS' && ok "bootstrap: a non-Mac stops at preflight" || bad "bootstrap: a non-Mac stops at preflight" "$out"
fi
out="$(bash "$AI/bin/tockmox-ai-node-converge" --bogus 2>&1)"; rc=$?
[ "$rc" = 64 ] && ok "converger: an unknown option exits 64" || bad "converger: an unknown option exits 64" "rc=$rc"

# examples against the renderer's schemas when the repository has them
if [ -d "$AI/schema" ]; then
  if out="$(python3 - "$AI" <<'PY' 2>&1
import json, os, sys, yaml
ai = sys.argv[1]
try:
    import jsonschema
except ImportError:
    print("SKIP no jsonschema"); sys.exit(0)
pairs = [("ai-node.v1.schema.json", "examples/site/ai-nodes/example-mac/ai-node.yaml"),
         ("desired.v1.schema.json", "examples/site/ai-nodes/example-mac/desired.yaml")]
for schema, doc in pairs:
    jsonschema.validate(yaml.safe_load(open(os.path.join(ai, doc))), json.load(open(os.path.join(ai, "schema", schema))))
    print("valid:", doc)
PY
  )"; then ok "examples validate against ai-node/schema ($(echo "$out" | tr '\n' ' '))"; else bad "examples against the schemas" "$out"; fi
fi

# --------------------------------------------------------------------- style
echo "style"
out="$(lint_emdash "$AI" docs/administration/ai-nodes.md)"
[ -z "$out" ] && ok "no em-dash in the toolkit or its page" || bad "em-dash found" "$out"

echo
if [ "$fail" = 0 ]; then echo "check-ai-node: passed"; else echo "check-ai-node: FAILED" >&2; fi
exit "$fail"

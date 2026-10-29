#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The six pages whose procedures need no cluster, executed on every commit.
# TM-0289, Jeff's ruling of 2026-10-28 (docs/QUESTION-TM-0289.md, item 3).
#
#   bash tests/executed-docs/pages-no-cluster.sh              all six pages
#   bash tests/executed-docs/pages-no-cluster.sh verify       one or more, by file name without .md
#   bash tests/executed-docs/pages-no-cluster.sh --selftest   prove this script goes red
#
# WHAT IT DOES. For every ```bash block on
#
#   docs/administration/values-contract.md   docs/administration/customising.md
#   docs/administration/capabilities.md      docs/administration/configuration.md
#   docs/administration/platform-management.md   docs/deployment/verify.md
#
# it extracts the block's bytes with tests/executed-docs/lib/extract-block.sh
# (the extractor every path in this harness uses, so "verbatim" means the same
# thing here) and runs them in bash with errexit and pipefail, from the root of
# a checkout, or, where the page says "from a clone" of something else, against a
# fixture the script builds. It then asserts on what the block PRINTED, using the
# success condition the page itself states, not only on the exit code: a render
# that fails inside `| grep` exits nonzero under pipefail, but a render that
# succeeds and prints nothing is the case the pages warn about twice.
#
# THE MANIFEST IS COMPLETE OR THE JOB IS RED. Every bash block on each page is
# one `run_block` or `skip_block` line below, and the script counts the fences on
# the page (the same pattern tools/doc-claims.txt pins: an indented fence counts)
# and refuses when the count and the manifest disagree. A block added to a page
# without a decision here is therefore a red job, not a silent gap, which is the
# exact failure testing-standard rule 2 names. A block skipped here says WHY, on
# the line, and the run prints every skip so a reviewer sees the exceptions in
# the log rather than in a file nobody opens.
#
# WHAT THE SKIPS ARE. Seven blocks across two pages run kubectl against a cluster
# (customising.md, configuration.md) or fetch a published tag over the network
# (customising.md's kustomize build). They are NOT executed here and they are NOT
# written exceptions: the ruling covers the six PAGES as no-cluster pages, and
# these blocks show the ruling is true of 24 of their 31 blocks. They stay OPEN in
# tests/executed-docs/INVENTORY.md section E until a cluster tier takes them or
# the maintainer excepts them (the pull request description asks).
#
# WHAT THIS DOES NOT PROVE.
#   - That a block pastes into the reader's shell. These run in bash; the pages
#     tell macOS readers to use zsh. tools/check-pasteable-blocks.sh holds the
#     paste rules and P09 pastes install.md into a real zsh; neither covers these
#     six pages' run behaviour, and this script does not close that gap.
#   - Anything against a real published tag. verify.md is executed against a
#     fixture repository with a throwaway key, so the COMMANDS are proved and the
#     real tag's signature is not. That belongs to the release gate.
#   - That a measured number on a page (an object count, a key count) is current.
#     Those are dated on their pages and move every release; this asserts the
#     relationships the pages state (a second count is lower; a delta of four),
#     never the dated digits.
#   - Helm 3 and Helm 4 agreeing: the job runs the version ci.yaml pins.
#
# NEEDS: bash, jq, helm with chart dependencies fetched (tools/helm-deps.sh), git,
# python3 with PyYAML, ssh-keygen (OpenSSH 8.1+), sha256sum (GNU coreutils; not on
# a stock Mac). A missing tool exits 2, "cannot run", before anything executes:
# never 0, and never a quiet skip of one block (testing-standard rules 1 and 9).
# tools/check-all.sh reports exit 2 as SKIPPED, which is what a Mac without
# coreutils should see; CI has every tool and treats any nonzero exit as red.
#
# Exit 0 every block ran or was declared skipped and every assertion held;
# 1 a block, an assertion or the manifest failed; 2 a tool this run needs is missing.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
E="${HERE}/lib/extract-block.sh"
# The pages come from PAGES_DOCS so --selftest can point the SAME script at a
# mutated copy. Everything else (charts, ci/, tools/, sbom.cdx.json) is the tree.
DOCS="${PAGES_DOCS:-${ROOT}/docs}"

SELF="${HERE}/pages-no-cluster.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# No ambient git or ssh configuration may decide a result: a runner with a signing
# key configured globally would make verify.md pass for the wrong reason.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

PASS=0; FAIL=0; RAN=0; RUNS=0; SKIPPED=0; LAST_RAN=""
SKIP_LOG="${TMP}/skips"; : >"$SKIP_LOG"

ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; return 0; }

sha_of() { # sha_of FILE
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print substr($1,1,12)}'
  else shasum -a 256 "$1" | awk '{print substr($1,1,12)}'; fi
}

# ------------------------------------------------------------------ selection
ALL_PAGES="values-contract customising capabilities configuration platform-management verify"
SELECTED=""
SELFTEST=0
for a in "$@"; do
  case "$a" in
    --selftest) SELFTEST=1 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    values-contract|customising|capabilities|configuration|platform-management|verify) SELECTED="${SELECTED} ${a}" ;;
    *) echo "pages-no-cluster.sh: unknown argument '$a'" >&2; exit 2 ;;
  esac
done
[ -n "$SELECTED" ] || SELECTED="$ALL_PAGES"
selected() { case " ${SELECTED} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- the manifest
# Per-block state, set by run_block / skip_block and read by the helpers below.
PAGE_FILE=""; PAGE_REL=""; PAGE_NAME=""; PAGE_BLOCKS=0; PAGE_DECLARED=0
BLK_ID=""; BLK_FILE=""; BLK_SHA=""; OUT="${TMP}/out"; RC=0
N=0

page() { # page NAME RELPATH
  PAGE_NAME="$1"; PAGE_REL="$2"; PAGE_FILE="${DOCS}/${2#docs/}"; PAGE_DECLARED=0
  printf '\n== %s\n' "$PAGE_REL"
  if [ ! -f "$PAGE_FILE" ]; then bad "$PAGE_REL: page not found at ${PAGE_FILE}"; PAGE_BLOCKS=0; return 1; fi
  # The fence count tools/doc-claims.txt pins: `^[ \t]*```bash$`, indented or not.
  PAGE_BLOCKS="$(grep -cE '^[[:space:]]*```bash[[:space:]]*$' "$PAGE_FILE" | tr -d ' ')"
  return 0
}

page_end() { # page_end : the manifest must account for every fence on the page
  if [ "$PAGE_DECLARED" -eq "$PAGE_BLOCKS" ]; then
    ok "${PAGE_NAME}: the manifest accounts for all ${PAGE_BLOCKS} bash blocks"
  else
    bad "${PAGE_NAME}: the page has ${PAGE_BLOCKS} bash blocks and the manifest in pages-no-cluster.sh classifies ${PAGE_DECLARED}" \
"A block was added or removed. Add a run_block or skip_block line for it (a skip must say why), or delete the line for the block that went."
  fi
}

extract() { # extract SECTION CONTAINING [LANG] -> BLK_FILE, BLK_SHA ; returns 1 and reports on refusal
  local sec="$1" needle="$2" lang="${3:-bash}" err="${TMP}/extract.err"
  N=$((N+1)); BLK_FILE="${TMP}/blk-${N}.sh"
  if ! bash "$E" --file "$PAGE_FILE" --page "$PAGE_REL" --section "$sec" --lang "$lang" --containing "$needle" >"$BLK_FILE" 2>"$err"; then
    bad "${PAGE_NAME} :: ${BLK_ID}: extraction refused (${sec} / containing: ${needle})" "$(cat "$err")"
    return 1
  fi
  # The fingerprint of the page's bytes, taken BEFORE any placeholder is replaced
  # so that it does not move with the scratch path: a page edit shows as a changed
  # fingerprint in the log, which is what extract-block.sh --sha is for.
  BLK_SHA="$(sha_of "$BLK_FILE")"
  return 0
}

subst() { # subst FROM TO : replace a placeholder the page tells the reader to replace; refuse if it is gone
  local from="$1" to="$2"
  if ! python3 -I - "$BLK_FILE" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
if a not in t:
    sys.exit(3)
open(p, "w", encoding="utf-8").write(t.replace(a, b))
PY
  then
    bad "${PAGE_NAME} :: ${BLK_ID}: the placeholder '${from}' is no longer in the block" \
"The page changed what the reader is told to replace. Update the manifest, do not drop the substitution."
    return 1
  fi
}

execute() { # execute CWD [PREFIX-FILE...] : run PREFIX blocks then this one, one bash session, record RC and OUT
  local cwd="$1"; shift
  local script="${TMP}/session-${N}.sh" f
  : >"$script"
  # Earlier blocks of the page's own session (exports, a cd) run first with their
  # stdout discarded, so this block's output is what the assertions read; a
  # failure in them still stops the session (errexit) and its stderr is kept.
  for f in "$@"; do { printf '{\n'; cat "$f"; printf '\n} >/dev/null\n'; } >>"$script"; done
  cat "$BLK_FILE" >>"$script"
  ( cd "$cwd" && bash -eo pipefail "$script" ) >"$OUT" 2>&1
  RC=$?
  # RAN counts distinct blocks; a block run twice (to show it goes red on a bad
  # fixture) is one block and two runs.
  RUNS=$((RUNS+1))
  if [ "${PAGE_NAME}/${BLK_ID}" != "$LAST_RAN" ]; then RAN=$((RAN+1)); LAST_RAN="${PAGE_NAME}/${BLK_ID}"; fi
  printf '     ran %s :: %s  [block sha256 %s, rc %s]\n' "$PAGE_NAME" "$BLK_ID" "$BLK_SHA" "$RC"
}

skip_block() { # skip_block ID SECTION CONTAINING REASON : still extracted, so a vanished block is still red
  BLK_ID="$1"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract "$2" "$3" || return 1
  SKIPPED=$((SKIPPED+1))
  printf 'SKIP %s :: %s ... %s\n' "$PAGE_NAME" "$BLK_ID" "$4"
  printf '%s :: %s :: %s\n' "$PAGE_REL" "$BLK_ID" "$4" >>"$SKIP_LOG"
}

# Assertions read OUT and RC. Each reports one line.
expect() { # expect LABEL COMMAND... : COMMAND is a predicate over OUT and RC
  local label="$1"; shift
  if "$@"; then ok "${PAGE_NAME} :: ${BLK_ID}: ${label}"
  else bad "${PAGE_NAME} :: ${BLK_ID}: ${label}" "rc=${RC}; output:
$(head -c 1500 "$OUT")"; fi
}
rc_is()      { [ "$RC" -eq "$1" ]; }
rc_not0()    { [ "$RC" -ne 0 ]; }
has()        { grep -qF -- "$1" "$OUT"; }
lacks()      { ! grep -qF -- "$1" "$OUT"; }
nonempty()   { [ -s "$OUT" ]; }
every_line() { # every_line ERE : each non-empty line matches, and there is at least one
  [ -s "$OUT" ] || return 1
  local stray; stray="$(grep -vE -- "$1" "$OUT" || true)"
  [ -z "$stray" ]; }
nlines()     { [ "$(grep -c . "$OUT")" -eq "$1" ]; }

# --------------------------------------------------------------------- fixtures
SITE_FIXTURE="${TMP}/sites"           # one site clone per page, built where needed

make_site() { # make_site NAME : a site-repo clone with the marker file the pages test for
  local d="${SITE_FIXTURE}/$1"
  mkdir -p "$d/bootstrap" "$d/site/values"
  printf '# fixture: the marker customising.md and capabilities.md test for\n' >"$d/bootstrap/root.yaml"
  printf '%s' "$d"
}

# =============================================================== values-contract
run_values_contract() {
  page values-contract docs/administration/values-contract.md || return
  local S='## Answer it for one key, from the tree' schemas
  schemas="$(find "${ROOT}/charts" -maxdepth 2 -name values.schema.json | wc -l | tr -d ' ')"

  BLK_ID="1 one key, one line per layer"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract "$S" 'modelGateway' && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints one line per layer schema (${schemas})" nlines "$schemas"
    expect "each line names its schema" every_line '^charts/[a-z-]+/values\.schema\.json  .'; }

  BLK_ID="2 every top-level key, with its owner"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract "$S" "grep -v" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "each line is key, tab, description" every_line '^[A-Za-z0-9_.-]+'"$(printf '\t')"
    expect "the filter removed the 'Not this layer' lines" lacks "Not this layer"; }

  BLK_ID="3 how many keys each schema enumerates"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract "$S" "uniq -c" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints count-then-number lines" every_line '^ *[0-9]+ [0-9]+$'
    expect "the counts add up to one number per schema (${schemas})" \
      sh -c "awk '{s+=\$1} END{exit !(s==$schemas)}' '$OUT'"; }

  BLK_ID="4 dependency names and aliases"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '### 2. Blocks named after a chart dependency ... pass-through' "alias" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints bare names" every_line '^[A-Za-z0-9._-]+$'
    expect "includes a dependency the page lists (traefik)" has "traefik"; }

  BLK_ID="5 the open blocks on the platform layer"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '### A closed root closes the root, not the blocks under it' "additionalProperties" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "lists global, the open block the page is about" has "global"; }

  BLK_ID="6 the declared global keys"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  # shellcheck disable=SC2016  # the heading contains literal backticks
  extract '### `global` stays open, and this is measured rather than lazy' "keys[]" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "lists the required globals configuration.md names" sh -c "grep -qx internalDomain '$OUT' && grep -qx lanCIDR '$OUT'"; }

  BLK_ID="7 stability tiers, then everything stable"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Not every Tockmox key carries the same promise' 'select(.value["x-tockmox-stability"] == "stable")' && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "the first query prints tier, tab, key" sh -c "grep -qE '^(stable|provisional|experimental)	' '$OUT'"
    expect "the second query prints bare key names" nonempty; }

  BLK_ID="8 every non-stable key with its ruling"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Not every Tockmox key carries the same promise' "@tsv" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "each line is key, tier, ruled, rerule (four fields)" \
      sh -c "awk -F'	' 'NF!=4{bad=1} END{exit bad||NR==0}' '$OUT'"; }

  page_end
}

# ================================================================== customising
run_customising() {
  page customising docs/administration/customising.md || return
  local site
  site="$(make_site customising)"

  # The Rung 1 values file is the page's own yaml block, not a retyped copy.
  if ! bash "$E" --file "$PAGE_FILE" --page "$PAGE_REL" --section '## Rung 1 ... values' --lang yaml --containing 'retention_period' >"${site}/site/values/observability.yaml" 2>"${TMP}/e"; then
    bad "customising :: fixture: the Rung 1 yaml block does not resolve" "$(cat "${TMP}/e")"; return
  fi

  BLK_ID="1 export SITE_REPO and test for the marker file"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Before you begin' 'export SITE_REPO=' && subst YOUR_SITE_REPO_PATH "$site" && {
    cp "$BLK_FILE" "${TMP}/customising-setup.sh"
    execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints the SITE_REPO line the page's guard expects" has "SITE_REPO: ${site}"; }
  local SETUP="${TMP}/customising-setup.sh"

  BLK_ID="2 render the layer, read retention_period back"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Rung 1 ... values' 'grep retention_period' && { execute "$ROOT" "$SETUP"
    expect "exits 0" rc_is 0
    expect "prints the 720h the page says to expect" has "retention_period: 720h"; }

  BLK_ID="3 read the compactor switch back"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Rung 1 ... values' 'grep retention_enabled' && { execute "$ROOT" "$SETUP"
    expect "exits 0" rc_is 0
    expect "prints retention_enabled: true" has "retention_enabled: true"; }

  skip_block "4 find the dashboard ConfigMap in the cluster" '### Grafana dashboards' 'grep my-dashboard' \
    "kubectl against a cluster"
  skip_block "5 find the PrometheusRule in the cluster" '### Alert rules' 'RULE_NAME' \
    "kubectl against a cluster"
  skip_block "6 kustomize build of a site repo that pulls a published tag" '## Rung 3 ... Kustomize patch' 'kustomize build' \
    "needs kustomize and the network (the base is a github.com resource at a published tag)"

  BLK_ID="7 the render shrinks when the component is disabled"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Rung 4 ... disable and replace' "grep -c '^kind:'" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints two counts" nlines 2
    expect "both are numbers above zero (the page: if both are 0, helm did not render)" every_line '^[1-9][0-9]*$'
    expect "the second is lower than the first" sh -c "awk 'NR==1{a=\$1} NR==2{b=\$1} END{exit !(b<a)}' '$OUT'"; }

  skip_block "8 kubectl edit a NetworkPolicy" '## The thing that does not work' 'kubectl edit' "kubectl against a cluster"
  skip_block "9 turn off auto-sync on the policy Application" '## The thing that does not work' 'patch application' "kubectl against a cluster"
  skip_block "10 read the Application's syncPolicy back" '## The thing that does not work' 'get application tockmox-policy' "kubectl against a cluster"

  page_end
}

# ================================================================= capabilities
run_capabilities() {
  page capabilities docs/administration/capabilities.md || return
  local site
  site="$(make_site capabilities)"
  # The page: "Measured ... using ci/values.yaml in place of a site file". A layer
  # will not render from bare defaults, so the fixture site IS that file.
  cp "${ROOT}/ci/values.yaml" "${site}/site/values/global.yaml"
  cp "${ROOT}/ci/values.yaml" "${site}/site/values/observability.yaml"

  BLK_ID="1 export SITE_REPO and test for the marker file"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Turning one off' 'export SITE_REPO=' && subst YOUR_SITE_REPO_PATH "$site" && {
    cp "$BLK_FILE" "${TMP}/capabilities-setup.sh"
    execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints the SITE_REPO line" has "SITE_REPO: ${site}"; }
  local SETUP="${TMP}/capabilities-setup.sh"

  BLK_ID="2 declining dataProtection drops the object count"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Turning one off' 'capabilities.dataProtection.enabled=false' && { execute "$ROOT" "$SETUP"
    expect "exits 0" rc_is 0
    expect "prints two counts above zero" every_line '^[1-9][0-9]*$'
    expect "the second is lower than the first (the page: 'The second number is lower')" \
      sh -c "awk 'NR==1{a=\$1} NR==2{b=\$1} END{exit !(NR==2&&b<a)}' '$OUT'"; }

  BLK_ID="3 monitors stay, Prometheus and Alertmanager go"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '### The case this design exists for: you already run Prometheus' 'ServiceMonitor' && { execute "$ROOT" "$SETUP"
    expect "exits 0" rc_is 0
    expect "ServiceMonitor appears" has "kind: ServiceMonitor"
    expect "PrometheusRule appears" has "kind: PrometheusRule"
    expect "no Prometheus object" sh -c "! grep -qE 'kind: Prometheus\$' '$OUT'"
    expect "no Alertmanager object" lacks "kind: Alertmanager"; }

  page_end
}

# ================================================================ configuration
run_configuration() {
  page configuration docs/administration/configuration.md || return

  skip_block "1 port-forward to the Traefik dashboard" '## Hostnames and TLS' 'port-forward' "kubectl against a cluster"

  BLK_ID="2 the harbor_netpol switch adds objects"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Per-app toggles' "harbor_netpol" && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints two counts above zero" every_line '^[1-9][0-9]*$'
    expect "the second is larger by 4, the Harbor bundle (the page: 'the delta of 4')" \
      sh -c "awk 'NR==1{a=\$1} NR==2{b=\$1} END{exit !(NR==2&&b-a==4)}' '$OUT'"; }

  page_end
}

# ========================================================= platform-management
run_platform_management() {
  page platform-management docs/administration/platform-management.md || return

  # The generator rewrites tockmox-ui/app/platform_catalog.yaml in place, so it
  # runs in a copy of the two files it touches, laid out as in a checkout. The
  # roles file the page calls path/to/roles/platform-roles.yaml belongs to the
  # specialists repository, which is not in this tree: it is built from the
  # catalog's own roster (the way tockmox-ui/tests/test_platform_cases.py does),
  # with one specialist's state changed so that the rewrite is observable.
  local w="${TMP}/pm"
  mkdir -p "$w/tools" "$w/tockmox-ui/app" "$w/path/to/roles"
  cp "${ROOT}/tools/gen-platform-specialists.py" "$w/tools/"
  cp "${ROOT}/tockmox-ui/app/platform_catalog.yaml" "$w/tockmox-ui/app/"
  python3 -I - "$w" <<'PY'
import sys, yaml
w = sys.argv[1]
cat = yaml.safe_load(open(w + "/tockmox-ui/app/platform_catalog.yaml"))
roles = {"schema": 1, "roles": []}
for t in cat["teams"]:
    for a in [t["lead"]] + list(t.get("members") or []):
        specs = [dict(s) for s in (a.get("specialists") or [])]
        if a["agentRole"] == "capacity-manager":
            specs = [{"id": "capacity-analyst", "state": "built"}]
        roles["roles"].append({"id": a["agentRole"], "title": a["name"], "specialists": specs})
open(w + "/path/to/roles/platform-roles.yaml", "w").write(yaml.safe_dump(roles, sort_keys=False))
PY
  local cat="$w/tockmox-ui/app/platform_catalog.yaml"

  BLK_ID="1 rewrite the catalog's specialists from the roles file"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Cases' 'gen-platform-specialists.py path/to/roles/platform-roles.yaml' && {
    execute "$w"
    expect "exits 0" rc_is 0
    expect "the catalog now carries the changed state" sh -c "grep -qF 'specialists: [{id: capacity-analyst, state: built}]' '$cat'"; }

  BLK_ID="2 --check: no drift after the rewrite, drift after a roles change"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## Cases' '--check' && { execute "$w"
    expect "exits 0 on a catalog the roles file would not change" rc_is 0
    # The page: "exit 1 when the catalog is not what the roles file makes it."
    python3 -I - "$w" <<'PY'
import sys, yaml
p = sys.argv[1] + "/path/to/roles/platform-roles.yaml"
d = yaml.safe_load(open(p))
for r in d["roles"]:
    if r["id"] == "capacity-manager":
        r["specialists"] = [{"id": "capacity-analyst", "state": "specced"}]
open(p, "w").write(yaml.safe_dump(d, sort_keys=False))
PY
    execute "$w"
    expect "exits 1 once the roles file has moved (the block can go red)" rc_is 1; }

  page_end
}

# ==================================================================== verify.md
run_verify() {
  page verify docs/deployment/verify.md || return
  local fx="${TMP}/verify" key="${TMP}/verify/key" clone="${TMP}/verify/clone"
  mkdir -p "$fx" "$clone"
  ssh-keygen -q -t ed25519 -N '' -C fixture -f "$key" >/dev/null 2>&1 || { bad "verify: cannot generate a throwaway ed25519 key"; return; }
  printf 'jeff@maaks.com %s\n' "$(cut -d' ' -f1,2 "${key}.pub")" >"${clone}/.gitsigners"
  ( cd "$clone" && git init -q . \
    && git add .gitsigners \
    && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m fixture \
    && git -c user.name=fixture -c user.email=fixture@example.invalid -c gpg.format=ssh -c "user.signingkey=${key}" tag -s -m fixture v0.0.0-fixture ) \
    >"${TMP}/verify-setup.log" 2>&1 || { bad "verify: cannot build the fixture clone with a signed tag" "$(cat "${TMP}/verify-setup.log")"; return; }

  BLK_ID="1 export TOCKMOX and TAG, find .gitsigners"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '### Set these once' 'export TOCKMOX=' && subst YOUR_TOCKMOX_CLONE_PATH "$clone" && subst YOUR_TAG v0.0.0-fixture && {
    cp "$BLK_FILE" "${TMP}/verify-b1.sh"
    execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "the allowed signers file is listed" has "${clone}/.gitsigners"
    expect "prints the verifying line" has "verifying v0.0.0-fixture in ${clone}"; }
  local B1="${TMP}/verify-b1.sh"

  BLK_ID="2 git verify-tag"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## 1. Verify the signed tag' 'git config gpg.ssh.allowedSignersFile' && {
    cp "$BLK_FILE" "${TMP}/verify-b2.sh"
    execute "$ROOT" "$B1"
    expect "exits 0" rc_is 0
    expect "names the signer by identity ('for jeff@maaks.com'), not only 'Good'" has 'Good "git" signature for jeff@maaks.com with ED25519 key SHA256:'
    # The page's trap: with a wrong allowed-signers file git still prints 'Good',
    # drops the identity, and the command fails. The same block must go red then.
    printf 'someone@example.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEZEiG9TVuwuLHJzZ+Hl2Gx+GoT2dkZ+D4X1wRVAPtQL\n' >"${clone}/.gitsigners"
    execute "$ROOT" "$B1"
    expect "with a wrong allowed-signers file the same block exits nonzero (the page: 'exits 1')" rc_not0
    expect "and says 'No principal matched.'" has "No principal matched."
    printf 'jeff@maaks.com %s\n' "$(cut -d' ' -f1,2 "${key}.pub")" >"${clone}/.gitsigners"; }
  local B2="${TMP}/verify-b2.sh"

  BLK_ID="3 verify-tag decided by the exit code"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## 1. Verify the signed tag' 'echo VERIFIED' && { execute "$ROOT" "$B1" "$B2"
    expect "exits 0" rc_is 0
    expect "prints VERIFIED" has "VERIFIED"
    expect "and not NOT VERIFIED" lacks "NOT VERIFIED"; }

  BLK_ID="4 sha256sum -c SHA256SUMS"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  if extract '## 2. Check the archive checksum' 'sha256sum -c' && subst YOUR_ARCHIVE_DIR "${fx}/archive"; then
    mkdir -p "${fx}/archive"
    printf 'fixture archive bytes\n' >"${fx}/archive/tockmox-fixture.tar"
    ( cd "${fx}/archive" && sha256sum tockmox-fixture.tar >SHA256SUMS )
    execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "every line ends in OK" every_line ': OK$'
    printf 'tampered\n' >>"${fx}/archive/tockmox-fixture.tar"
    execute "$ROOT"
    expect "a tampered archive makes the same block exit nonzero and print FAILED" sh -c "[ $RC -ne 0 ] && grep -q FAILED '$OUT'"
  fi

  BLK_ID="5 read the SBOM"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  extract '## 3. Read the deployment SBOM' 'sbom.cdx.json' && { execute "$ROOT"
    expect "exits 0" rc_is 0
    expect "prints 'N components for <name> <version>'" every_line '^[0-9]+ components for [A-Za-z0-9._-]+ [0-9A-Za-z.+-]+$'; }

  BLK_ID="6 verify the gate report's signature"; PAGE_DECLARED=$((PAGE_DECLARED+1))
  if extract '## 4. Verify the gate report' 'ssh-keygen -Y verify' && subst YOUR_GATE_REPORT_PATH "${fx}/GATE-REPORT-fixture.md"; then
    printf 'gate report fixture\n' >"${fx}/GATE-REPORT-fixture.md"
    ssh-keygen -q -Y sign -f "$key" -n file "${fx}/GATE-REPORT-fixture.md" >/dev/null 2>&1 \
      || bad "verify: cannot sign the fixture gate report"
    execute "$ROOT" "$B1"
    expect "exits 0" rc_is 0
    expect "names the signer by identity" has 'Good "file" signature for jeff@maaks.com'
  fi

  page_end
}

# ===================================================================== selftest
# The second run proves the first CAN go red. Each case copies the pages that
# need no chart render into a scratch docs tree, plants ONE mutation, runs this
# same script against it, and requires a nonzero exit AND the finding named. The
# unmutated copy must pass first, or every red below could be an artefact.
selftest() {
  local d="${TMP}/st" nfail=0 rc log
  mkdir -p "$d/docs/administration" "$d/docs/deployment"
  cp "${ROOT}/docs/administration/values-contract.md" "${ROOT}/docs/administration/platform-management.md" "$d/docs/administration/"
  cp "${ROOT}/docs/deployment/verify.md" "$d/docs/deployment/"

  st_run() { # st_run NAME EXPECT-IN-LOG PAGES... ; the page tree is $d/docs
    local name="$1" want="$2"; shift 2
    log="${TMP}/st-${name}.log"
    PAGES_DOCS="$d/docs" bash "$SELF" "$@" >"$log" 2>&1; rc=$?
    if [ "$want" = "GREEN" ]; then
      if [ "$rc" -eq 0 ]; then ok "selftest: ${name}: the unmutated pages pass"
      else bad "selftest: ${name}: unmutated pages did not pass" "$(tail -15 "$log")"; nfail=1; fi
    else
      if [ "$rc" -ne 0 ] && grep -qF -- "$want" "$log"; then ok "selftest: ${name}: red, and it names '${want}'"
      else bad "selftest: ${name}: expected a red naming '${want}' (rc=${rc})" "$(tail -15 "$log")"; nfail=1; fi
    fi
  }
  st_restore() {
    cp "${ROOT}/docs/administration/values-contract.md" "${ROOT}/docs/administration/platform-management.md" "$d/docs/administration/"
    cp "${ROOT}/docs/deployment/verify.md" "$d/docs/deployment/"
  }
  st_run baseline GREEN values-contract platform-management verify

  # 1. a command in a block stops working (the card's red proof)
  python3 -I - "$d/docs/administration/values-contract.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
a = "charts/*/values.schema.json\n```\n\nSubstitute"
assert a in t
open(p, "w").write(t.replace(a, "charts/*/values.schema.jsonx\n```\n\nSubstitute", 1))
PY
  st_run broken-command "FAIL values-contract :: 1 one key, one line per layer: exits 0" values-contract
  st_restore

  # 2. a block is added without a decision
  python3 -I - "$d/docs/administration/values-contract.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
t += "\n```bash\ntrue\n```\n"
open(p, "w").write(t)
PY
  st_run unclassified-block "FAIL values-contract: the page has 9 bash blocks and the manifest in pages-no-cluster.sh classifies 8" values-contract
  st_restore

  # 3. a block the manifest names disappears (heading renamed)
  sed 's/^## Cases$/## Cases renamed/' "$d/docs/administration/platform-management.md" >"$d/pm.tmp" && mv "$d/pm.tmp" "$d/docs/administration/platform-management.md"
  st_run vanished-section "FAIL platform-management :: 1 rewrite the catalog's specialists from the roles file: extraction refused" platform-management
  st_restore

  # 4. the page stops telling the reader to replace a placeholder
  sed 's/YOUR_ARCHIVE_DIR/ARCHIVE_DIR_HERE/' "$d/docs/deployment/verify.md" >"$d/v.tmp" && mv "$d/v.tmp" "$d/docs/deployment/verify.md"
  st_run placeholder-renamed "FAIL verify :: 4 sha256sum -c SHA256SUMS: the placeholder 'YOUR_ARCHIVE_DIR' is no longer in the block" verify
  st_restore

  # 5. a block that succeeds but prints the wrong thing (git verify-tag against a tag that does not exist)
  # shellcheck disable=SC2016  # the pattern is a literal $TAG, not an expansion
  sed 's/git verify-tag "\$TAG"$/git verify-tag "${TAG}-absent"/' "$d/docs/deployment/verify.md" >"$d/v.tmp" && mv "$d/v.tmp" "$d/docs/deployment/verify.md"
  st_run wrong-tag "FAIL verify :: 2 git verify-tag: exits 0" verify
  st_restore

  [ "$nfail" -eq 0 ]
}


# ------------------------------------------------------------------- preflight
# Exit 2 before anything runs when a tool this selection needs is absent.
preflight() {
  local miss="" t p
  for p in $SELECTED; do
    case "$p" in
      values-contract) set -- jq ;;
      customising|capabilities|configuration) set -- helm ;;
      platform-management) set -- python3 ;;
      verify) set -- git ssh-keygen python3 sha256sum ;;
    esac
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss="${miss} ${t}"; done
  done
  if [ -n "$miss" ]; then
    # shellcheck disable=SC2086  # word splitting of the list is the point
    echo "pages-no-cluster.sh: cannot run, missing:$(printf '%s\n' $miss | sort -u | tr '\n' ' ')" >&2
    echo "  (exit 2 is 'cannot run', not a pass; tools/check-all.sh reports it as skipped)" >&2
    return 2
  fi
  case " $SELECTED " in
    *" platform-management "*) python3 -I -c 'import yaml' 2>/dev/null || { echo "pages-no-cluster.sh: cannot run, PyYAML is not importable (python3 -m pip install pyyaml)" >&2; return 2; } ;;
  esac
  case " $SELECTED " in
    *" customising "*|*" capabilities "*|*" configuration "*)
      # The renders need every chart's dependencies. Without them helm says
      # "found in Chart.yaml, but missing in charts/", which reads like a page defect.
      ls "${ROOT}"/charts/tockmox-observability/charts/*.tgz >/dev/null 2>&1 \
        || { echo "pages-no-cluster.sh: cannot run, chart dependencies are not fetched (bash tools/helm-deps.sh)" >&2; return 2; } ;;
  esac
  return 0
}

# ======================================================================== main
if [ "$SELFTEST" -eq 1 ]; then
  [ -f "$E" ] || { echo "pages-no-cluster.sh: missing ${E}" >&2; exit 2; }
  # The cases need no chart render: jq, python3 and the signing tools only.
  SELECTED="values-contract platform-management verify"
  preflight || exit 2
  selftest
  printf '\n%s passed, %s failed (selftest)\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]; exit $?
fi

[ -f "$E" ] || { echo "pages-no-cluster.sh: missing ${E}" >&2; exit 2; }
preflight || exit 2
selected values-contract      && run_values_contract
selected customising          && run_customising
selected capabilities         && run_capabilities
selected configuration        && run_configuration
selected platform-management  && run_platform_management
selected verify               && run_verify

printf '\n== skipped blocks (not executed here, and not written exceptions)\n'
if [ -s "$SKIP_LOG" ]; then sed 's/^/   /' "$SKIP_LOG"; else echo "   none"; fi
printf '\n%s assertions passed, %s failed; %s blocks executed (%s runs), %s skipped\n' "$PASS" "$FAIL" "$RAN" "$RUNS" "$SKIPPED"
if [ "$RAN" -eq 0 ]; then echo "FAIL: nothing was executed" >&2; exit 1; fi
[ "$FAIL" -eq 0 ]

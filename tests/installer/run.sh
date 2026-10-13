#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The installer's own test tier. Hermetic: no cluster, no network, no shared
# state. Per-commit cadence, per testing-standard.md rule 6.
#
# WHY A NEW TIER RATHER THAN A PATH SCRIPT. tests/executed-docs asks "do the
# instructions work" by extracting commands from a page and running them against
# a live cluster. This asks a different question: "does the installer, as a
# program, behave?" It needs no cluster, so folding it into a nightly
# cluster-backed job would make a one-second check wait on a twenty-minute one
# and inherit its substrate blockers (TM-0345).
#
# The two defects this tier was written after, both found 2026-09-10 and both
# invisible to all 31 static gates:
#
#   1. The interactive path died on `DEF_SC: unbound variable` after nine
#      answered questions. README.md's quickstart lists interactive FIRST, so
#      the first command the project advertises could not complete. It survived
#      because every proof run this project has made used --config.
#   2. --no-cluster did not skip the cluster preflight when a cluster happened
#      to be reachable, so preparing a site repo ahead of a cluster failed on a
#      workstation whose kubeconfig pointed anywhere at all.
#
# Both are behaviours, not artefacts in the tree, which is why static analysis
# could not reach them. Assertions below are the executed-docs vocabulary ...
# artefact, read, expected, actual ... because one assertion vocabulary across
# the project is worth more than a second one tuned to this tier.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
INSTALLER="$REPO_ROOT/install/tockmox-install.sh"
ANSWERS="$HERE/fixtures/interactive-answers.txt"
PARITY_CFG="$HERE/fixtures/parity.yaml"
DRIVE="$HERE/lib/pty-drive.py"

# shellcheck source=../executed-docs/lib/assert.sh
. "$HERE/../executed-docs/lib/assert.sh"

command -v python3 >/dev/null 2>&1 || {
  echo "run.sh: python3 is required to drive a pty. Refusing rather than skipping:" >&2
  echo "  a tier that reports success having examined nothing is the failure" >&2
  echo "  testing-standard.md rule 1 is about." >&2
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-installer-test.XXXXXX")"
cleanup() { [ "${TOCKMOX_KEEP_WORK:-0}" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT
[ "${TOCKMOX_KEEP_WORK:-0}" = "1" ] && echo "work dir kept: $WORK"

# ---------------------------------------------------------------- hermeticity
# STUBS, so this tier makes no network call and reaches no cluster.
#
# `git` always fails. The installer resolves tockmox.revision against the remote
# and WARNS when it cannot reach it ... a documented degradation for air-gapped
# operators. Stubbing git exercises that branch and makes the run offline and
# deterministic in the same move. Without this, the result depends on whether
# the runner can reach GitHub and on whether the tag under test exists yet,
# which is two sources of flake, and "a flaky gate is worse than a missing one".
#
# `kubectl` is stubbed per-test rather than globally, because two of the tests
# below are ABOUT what happens when a cluster is or is not reachable.
STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/git"; chmod +x "$STUB/git"

stub_kubectl_reachable_without_argocd() {
  cat > "$STUB/kubectl" <<'EOF'
#!/bin/sh
# A cluster that answers, and is not the one you are about to build: no argocd
# namespace. This is the shape of a workstation with a merged kubeconfig.
case "$*" in
  *"version -o json"*)        echo '{"clientVersion":{"gitVersion":"v1.30.0"}}'; exit 0 ;;
  *"config current-context"*) echo "somebody-elses-cluster"; exit 0 ;;
  *)                          exit 1 ;;
esac
EOF
  chmod +x "$STUB/kubectl"
}
stub_kubectl_unreachable() {
  printf '#!/bin/sh\nexit 1\n' > "$STUB/kubectl"; chmod +x "$STUB/kubectl"
}
unstub_kubectl() { rm -f "$STUB/kubectl"; }

# PATH with the stubs in front. Note what is NOT inherited: a real KUBECONFIG
# cannot matter, because the stub answers before any config is read.
export PATH="$STUB:$PATH"
export NO_COLOR=1

# drive_interactive <cwd> <extra installer args...>  -> transcript on stdout,
# exit status in DRIVE_STATUS. Never `set -e`-aborts on a non-zero child: a
# refusal is a result this tier asserts on, not an accident.
DRIVE_STATUS=0
drive_interactive() {
  local cwd="$1"; shift
  mkdir -p "$cwd"
  set +e
  ( cd "$cwd" && python3 "$DRIVE" --answers "$ANSWERS" --timeout 60 -- \
      bash "$INSTALLER" "$@" ) >"$WORK/transcript.txt" 2>"$WORK/transcript.err"
  DRIVE_STATUS=$?
  set -e
  cat "$WORK/transcript.txt"
}

run_config() {
  local cwd="$1"; shift
  mkdir -p "$cwd"
  set +e
  ( cd "$cwd" && bash "$INSTALLER" "$@" ) >"$WORK/cfg-out.txt" 2>&1
  CONFIG_STATUS=$?
  set -e
}

path_begin "I1" "install/tockmox-install.sh, interactive, driven under a pty"
parity_caveat \
  "Runs on the CI runner's bash and python3, not on macOS bash 3.2 + zsh." \
  "The installer is bash and declares its own floor; this tier does not prove the floor." \
  "No cluster is involved, so nothing here is evidence that a generated site SYNCS."
does_not_prove \
  "that the generated site repository is CORRECT against the charts (the charts job renders it)" \
  "that the prompts ASK THE RIGHT QUESTIONS ... only that answering them produces a site" \
  "anything about the four steps after the installer, which are install.md's territory" \
  "that a reader understands any prompt; a fixture is not an operator"

# ---------------------------------------------------------------------- I1
# The regression that matters: a default interactive run finishes and writes a
# site. Asserted on the ARTEFACT the run is supposed to produce, not on the exit
# code, because the crash this replaces happened AFTER nine prompts succeeded.
SITE_I="$WORK/interactive"
drive_interactive "$SITE_I" --no-cluster >/dev/null

assert_artifact \
  "interactive run's generated global.yaml names the domain that was typed" \
  "awk -F': ' '/internalDomain:/ {print \$2}' '$SITE_I/tockmox-site/site/values/global.yaml' 2>/dev/null" \
  "int.example.test"

assert_artifact \
  "interactive run derives the storage class from the layers it installs" \
  "awk -F': ' '/^  storageClass:/ {print \$2}' '$SITE_I/tockmox-site/site/values/global.yaml' 2>/dev/null" \
  "longhorn"

assert_artifact \
  "interactive run writes one Application per layer plus site-apps and site-secrets" \
  "ls '$SITE_I/tockmox-site/bootstrap/applications' 2>/dev/null | wc -l | tr -d ' '" \
  "11"

# THE PLACEHOLDER COUNT IS A PUBLISHED NUMBER AND IT HAS DRIFTED TWICE.
# `install.md` prints it, tells the reader to note it, and asks them to check it
# again two sections later ... so a reader comparing their own correct output
# against a stale table concludes their site is wrong. It moved when `site-apps`
# was added and again when `site-secrets` was, and on the second occasion the
# page stated the old value in two different sentences for a day.
# It cannot be pinned in tools/doc-claims.txt: it is a property of a GENERATED
# site (one per enabled layer, plus root, site-apps, site-secrets and the
# README) rather than a constant of the tree, and no cheap shell test over this
# repository measures it. Here there IS a generated site, so here is where it
# belongs. Bump both numbers together when a layer or an Application is added.
assert_artifact \
  "every file carrying the placeholder is counted, bootstrap/ and the README alike" \
  "grep -rl PLACEHOLDER_SITE_REPO_URL '$SITE_I/tockmox-site' 2>/dev/null | wc -l | tr -d ' '" \
  "13"

assert_artifact \
  "twelve of those are under bootstrap/, so a bootstrap-scoped sed leaves one behind" \
  "grep -rl PLACEHOLDER_SITE_REPO_URL '$SITE_I/tockmox-site/bootstrap' 2>/dev/null | wc -l | tr -d ' '" \
  "12"

assert_artifact \
  "interactive run leaves no unbound-variable message in its transcript" \
  "grep -c 'unbound variable' '$WORK/transcript.txt' || true" \
  "0"

assert_artifact \
  "interactive run exits clean" \
  "echo $DRIVE_STATUS" \
  "0"

# The fixture's answer count must match the installer's prompt count, or every
# later answer is off by one and the failure reads as a validation bug.
assert_artifact \
  "fixture answers == prompts the installer asks" \
  "grep -c '^  ask ' '$INSTALLER'" \
  "$(grep -vc '^#' "$ANSWERS")"

# ---------------------------------------------------------------------- I2
path_begin "I2" "interactive and --config are equal routes, so they must agree"
SITE_C="$WORK/config"
mkdir -p "$SITE_C"
cp "$PARITY_CFG" "$SITE_C/tockmox.yaml"
run_config "$SITE_C" --config tockmox.yaml --no-cluster

assert_artifact \
  "--config route exits clean" \
  "echo $CONFIG_STATUS" \
  "0"

assert_artifact \
  "the two routes produce a byte-identical site repository" \
  "diff -r '$SITE_I/tockmox-site' '$SITE_C/tockmox-site' >/dev/null 2>&1 && echo identical || diff -rq '$SITE_I/tockmox-site' '$SITE_C/tockmox-site' 2>&1 | head -5" \
  "identical"

# ---------------------------------------------------------------------- I3
path_begin "I3" "--no-cluster means do not check the cluster, even when one answers"
stub_kubectl_reachable_without_argocd
SITE_N="$WORK/nocluster"
mkdir -p "$SITE_N"; cp "$PARITY_CFG" "$SITE_N/tockmox.yaml"
run_config "$SITE_N" --config tockmox.yaml --no-cluster

assert_artifact \
  "--no-cluster writes a site repo despite a reachable cluster with no argocd namespace" \
  "test -f '$SITE_N/tockmox-site/bootstrap/root.yaml' && echo written || echo 'NOT WRITTEN'" \
  "written"

assert_artifact \
  "--no-cluster does not consult the cluster's context at all" \
  "grep -c 'somebody-elses-cluster' '$WORK/cfg-out.txt' || true" \
  "0"

# ---------------------------------------------------------------------- I4
path_begin "I4" "refusals name the setting, and the escape hatch is discoverable"
stub_kubectl_unreachable
SITE_U="$WORK/unreachable"
mkdir -p "$SITE_U"; cp "$PARITY_CFG" "$SITE_U/tockmox.yaml"
run_config "$SITE_U" --config tockmox.yaml

assert_artifact \
  "an unreachable cluster with no flag refuses, and the message names --no-cluster" \
  "grep -c -- '--no-cluster' '$WORK/cfg-out.txt' || true" \
  "1"

unstub_kubectl

# A malformed CIDR must be rejected by name. Asserting the MESSAGE, not the exit
# code: an early draft of the executed-docs selftest had four cases passing for
# the wrong reason because it read exit status, and the lesson transfers.
SITE_B="$WORK/badcidr"
mkdir -p "$SITE_B"
sed 's|lanCIDR: 192.168.77.0/24|lanCIDR: 192.168.77.0|' "$PARITY_CFG" > "$SITE_B/tockmox.yaml"
run_config "$SITE_B" --config tockmox.yaml --no-cluster

assert_artifact \
  "a malformed CIDR is refused by value" \
  "grep -o \"not a CIDR: '192.168.77.0'\" '$WORK/cfg-out.txt' | head -1" \
  "not a CIDR: '192.168.77.0'"

assert_artifact \
  "a refused config writes no partial site repository" \
  "test -e '$SITE_B/tockmox-site' && echo 'PARTIAL SITE WRITTEN' || echo none" \
  "none"

SITE_S="$WORK/badname"
mkdir -p "$SITE_S"
sed 's|name: ci-interactive|name: Not_A_Valid_Name|' "$PARITY_CFG" > "$SITE_S/tockmox.yaml"
run_config "$SITE_S" --config tockmox.yaml --no-cluster

assert_artifact \
  "an invalid site name is refused and the rule is stated" \
  "grep -c 'site.name must be lowercase alphanumeric and hyphens' '$WORK/cfg-out.txt' || true" \
  "1"

# ---------------------------------------------------------------------- I5
path_begin "I5" "a second run over an existing site refuses; --force regenerates it byte-identically"
# TM-0277's DoD asserts that a second run "rotates nothing": the generated tree
# is a pure function of the config. That stays true under --force. WITHOUT it a
# second run now refuses (L1, 0.8.0 lab pass: a second --config, run for a grep,
# silently overwrote the policy.yaml the operator had edited by hand in install.md
# 1f, and tockmox-policy went to ComparisonError).
cp -R "$SITE_C/tockmox-site" "$WORK/config-first-run"
printf '# hand edit after the first run\n' >> "$SITE_C/tockmox-site/site/values/policy.yaml"
cp "$SITE_C/tockmox-site/site/values/policy.yaml" "$WORK/policy-edited.yaml"
run_config "$SITE_C" --config tockmox.yaml --no-cluster

assert_artifact \
  "a second run over an existing site exits non-zero" \
  "test $CONFIG_STATUS -ne 0 && echo refused || echo 'RAN ANYWAY'" \
  "refused"

assert_artifact \
  "the refusal names --force and the directory" \
  "grep -c -- 'already has files in it.*--force' '$WORK/cfg-out.txt' || true" \
  "1"

assert_artifact \
  "the refusal leaves a hand-edited values file untouched" \
  "cmp -s '$WORK/policy-edited.yaml' '$SITE_C/tockmox-site/site/values/policy.yaml' && echo untouched || echo OVERWRITTEN" \
  "untouched"

run_config "$SITE_C" --config tockmox.yaml --no-cluster --force

assert_artifact \
  "--force regenerates, and says it overwrites hand edits" \
  "grep -c -- '--force: regenerating' '$WORK/cfg-out.txt' || true" \
  "1"

assert_artifact \
  "a --force run produces a byte-identical site repository" \
  "diff -r '$WORK/config-first-run' '$SITE_C/tockmox-site' >/dev/null 2>&1 && echo identical || diff -rq '$WORK/config-first-run' '$SITE_C/tockmox-site' 2>&1 | head -5" \
  "identical"

# ---------------------------------------------------------------------- I5b
path_begin "I5b" "--dry-run counts the files that carry the placeholder as a real run does"
# L1 F-L1-1: the dry-run said 11, the real run wrote 13 (README.md and
# site-secrets.yaml were not counted). Compare the two, against a FRESH
# directory so neither refuses, and against the files on disk.
SITE_D="$WORK/dryrun"; mkdir -p "$SITE_D"; cp "$PARITY_CFG" "$SITE_D/tockmox.yaml"
run_config "$SITE_D" --config tockmox.yaml --no-cluster --dry-run
DRY_N="$(sed -n 's/.*carries PLACEHOLDER_SITE_REPO_URL in \([0-9]*\) files.*/\1/p' "$WORK/cfg-out.txt")"
SITE_R="$WORK/realrun"; mkdir -p "$SITE_R"; cp "$PARITY_CFG" "$SITE_R/tockmox.yaml"
run_config "$SITE_R" --config tockmox.yaml --no-cluster
REAL_N="$(sed -n 's/.*carries PLACEHOLDER_SITE_REPO_URL in \([0-9]*\) files.*/\1/p' "$WORK/cfg-out.txt")"
DISK_N="$(grep -rl PLACEHOLDER_SITE_REPO_URL "$SITE_R/tockmox-site" | wc -l | tr -d ' ')"

assert_artifact \
  "the dry run and the real run print the same placeholder count" \
  "test -n '$DRY_N' && test '$DRY_N' = '$REAL_N' && echo same || echo 'dry=$DRY_N real=$REAL_N'" \
  "same"

assert_artifact \
  "and that count is the number of files on disk that carry the placeholder" \
  "test '$REAL_N' = '$DISK_N' && echo '$DISK_N' || echo 'printed=$REAL_N disk=$DISK_N'" \
  "$DISK_N"

assert_artifact \
  "a dry run over an existing site writes nothing and only warns" \
  "(cd '$SITE_R' && bash '$INSTALLER' --config tockmox.yaml --no-cluster --dry-run 2>&1 | grep -c 'a real run would refuse without --force' || true)" \
  "1"

# ---------------------------------------------------------------------- I6
path_begin "I6" "the installer's publish-docs step never fails an install over documentation (TM-0807)"
# The docs are published from the operator's checkout by tools/publish-docs.sh.
# Without the pinned generator that script exits 2 and changes nothing, and the
# installer's subcommand must turn that into a warning and exit 0. PYTHON points
# at a binary that does not exist, which is how build-docs.sh sees "no
# generator" without depending on what this runner has installed. kubectl is
# stubbed unreachable: a skipped publish must not need a cluster.
stub_kubectl_unreachable
set +e
PYTHON=/nonexistent/python3 bash "$INSTALLER" publish-docs --context ci-ctx >"$WORK/pd-out.txt" 2>&1
PD_STATUS=$?
set -e

assert_artifact   "publish-docs without the generator exits 0, a warning and not a failed install"   "echo $PD_STATUS"   "0"
assert_artifact   "the skip is said aloud, with the generator named as the cause"   "grep -c 'docs not published: the pinned documentation generator is absent' '$WORK/pd-out.txt' || true"   "1"
assert_artifact   "and the two commands that would publish are printed"   "grep -c 'tools/publish-docs.sh --context ci-ctx' '$WORK/pd-out.txt' || true"   "2"
assert_artifact   "the next-steps list of a generated site ends with the publish-docs step"   "grep -c 'publish-docs --context YOUR_KUBECONTEXT' '$WORK/cfg-out.txt' || true"   "1"

# ---------------------------------------------------------------------- I7
path_begin "I7" "--lint names a credentials namespace the policy layer does not admit to S3 (TM-1032)"
# The two keys live in different layers' files, so no chart can see both; this is
# the 0.8.0-rc1 greenfield's news/miniflux-db, which archived nothing once
# nodeOriginSources was set and read healthy throughout.
lint_site() { # dir platform-yaml policy-yaml
  mkdir -p "$1/site/values"
  printf '%s\n' "$2" > "$1/site/values/platform.yaml"
  printf '%s\n' "$3" > "$1/site/values/policy.yaml"
  set +e; bash "$INSTALLER" --lint "$1" >"$1/lint-out.txt" 2>&1; echo $? > "$1/lint-rc"; set -e
}
lint_site "$WORK/lint-miss" $'garage:\n  credentialsNamespaces:\n    - tockmox-ai\n    - tockmox-authentik\n    - news   # miniflux' \
  $'platformNetpol:\n  nodeOriginSources: [10.42.0.0/31]'
lint_site "$WORK/lint-ok" $'garage:\n  credentialsNamespaces: [tockmox-ai, "tockmox-authentik", news]' \
  $'platformNetpol:\n  nodeOriginSources: [10.42.0.0/31]\n  extraS3ClientNamespaces:\n    - news'
lint_site "$WORK/lint-off" $'garage:\n  credentialsNamespaces: [tockmox-ai, news]' \
  $'apps:\n  platform_netpol:\n    enabled: false'

assert_artifact "a credentials namespace missing from extraS3ClientNamespaces fails the lint" "cat '$WORK/lint-miss/lint-rc'" "1"
assert_artifact "and the message names the namespace and the key to add it to" \
  "grep -c 'garage.credentialsNamespaces names news, which policy.yaml does not admit.*platformNetpol.extraS3ClientNamespaces' '$WORK/lint-miss/lint-out.txt' || true" "1"
assert_artifact "listed in extraS3ClientNamespaces (flow and block lists, quoted names) it passes" "cat '$WORK/lint-ok/lint-rc'" "0"
assert_artifact "with the platform rules off there is no S3 rule to miss, and it passes" "cat '$WORK/lint-off/lint-rc'" "0"

# ---------------------------------------------------------------- TM-0277
# install/bootstrap-secrets.sh. Its own file: it is long, and its shims are not
# the per-test kubectl stubs above.
# shellcheck source=bootstrap-secrets-tests.sh
. "$HERE/bootstrap-secrets-tests.sh"

assert_summary

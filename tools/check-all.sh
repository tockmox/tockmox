#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# EVERY STATIC GATE, IN ONE COMMAND.
#
# CONTRIBUTING.md tells you your pull request must pass CI. Until 2026-09-03
# there was no way to find out except by opening one, and CONTRIBUTING listed
# only a subset of the checks. An outside review predicted the resulting issue
# almost word for word: "I ran the commands in CONTRIBUTING and CI still failed
# on an undocumented gate."
#
# So this runs what `ci.yaml` runs, minus the parts that genuinely need
# something a laptop does not have ... plus, for now, eight gates that run here
# and are not yet wired into ci.yaml: the two CNPG policy gates
# (check-cnpg-netpol, check-cnpg-operator-reach), check-ingress-tls,
# check-pod-security, check-dashboard-panels, check-litellm-hooks, the two check-harness-context.sh
# runs (TM-0797; also run by executed-docs.yaml's hermetic selftest job) and the two check-docs-offline.sh
# runs (TM-0215; the second skips without the pinned MkDocs toolchain, so a run
# with no docs venv reports it as skipped), and the 0.7.1 wave's four gates with
# their selftests: check-identity-seams, check-platform-seams,
# check-immutable-fields and check-action-pins, then wave 2's
# check-capability-monitors, check-cloud-egress and check-notify-and-drill
# (2026-10-03; the count of
# check-all-only gates above is no longer eight, and this list is not
# exhaustive ... the run_gate lines below are). Adding a CI gate is its own
# multi-file change (it moves a count that four pages state and doc-claims.txt
# pins), which is why
# they wait here rather than land half-registered.
#
# WHAT IT DOES NOT COVER, stated rather than skipped silently:
#
#   - `gitleaks (full history)` needs the gitleaks binary and a full clone.
#   - `kubeconform rendered output` needs kubeconform.
#   - `every commit carries a DCO sign-off` is checked against the commits a
#     pull request adds, which a working tree does not know. Run
#     `git log --format='%B' origin/main..HEAD | grep -c '^Signed-off-by:'`
#     yourself and compare it to your commit count.
#   - `render every layer at the previous release tag and at this candidate`
#     needs both refs and is a release-time check.
#   - the executed-documentation paths need a live cluster. That is the whole
#     point of them; see tests/executed-docs/README.md.
#
# WHY EACH GATE ASSERTS ITS OWN DEPENDENCIES FIRST. On 2026-09-03,
# check-capabilities.sh was run with no helm on PATH and reported ELEVEN
# specific capability-framework defects that did not exist ... its render helper
# swallowed the missing binary, so every capability looked like a switch that
# changed nothing. A gate that invents findings when its tooling is absent is
# worse than one that refuses to run. This script therefore checks for helm
# once, up front, and REFUSES rather than producing a plausible wrong answer.

set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0; skipped=0
failed_names=""

have() { command -v "$1" >/dev/null 2>&1; }

# GATES RUN IN PARALLEL (TM-1021, Jeff 2026-10-11: "let's absolutely run the gates in parallel").
# One run was about 45 minutes on a 2-CPU runner, gate after gate, while every gate is an
# independent process that renders the charts into its own mktemp directory. Now up to
# CHECK_ALL_JOBS gates run at once (default: the CPU count), each writing its output to its own
# file, and the report is printed in the SAME ORDER and with the SAME counts as a serial run, with
# each gate's wall time beside its name and the slowest listed at the end.
#
#   CHECK_ALL_JOBS=1   the old behaviour exactly: one gate at a time, output streamed as it runs.
#
# Gates that read what another gate writes, or build into a shared directory, run alone behind a
# barrier (`serial_gate`): render-counts writes build/render-counts.tsv that doc-claims reads, and
# the docs gates build and read the one site directory. Everything else is independent by
# construction (every gate's scratch is its own mktemp), and the run asserts the tree it started
# from is the tree it ends with, so a gate that writes into the checkout is caught rather than
# raced.
cpu_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2
}
JOBS="${CHECK_ALL_JOBS:-$(cpu_count)}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac
SLOTS="$(mktemp -d)"
trap 'rm -rf "$SLOTS"' EXIT
nslot=0
tree_fingerprint() {
  # Tracked and untracked files outside build/ and the vendored subcharts, contents included.
  git status --porcelain --untracked-files=all 2>/dev/null | grep -v -e ' build/' -e '/charts/[^/]*\.tgz$' -e '__pycache__' | sort
  git diff 2>/dev/null | cksum
}

# EXIT 2 MEANS SKIPPED, and that convention is the repository's, not this
# script's: see the long note at the top of check-blueprint-discovery.sh. A gate
# that cannot run because a substrate is absent is a different report from a gate
# that ran and found a defect, and collapsing the two teaches people to skim past
# red in this directory.
tally() {
  case "$2" in
    0) pass=$((pass + 1)) ;;
    2) skipped=$((skipped + 1)) ;;
    *) fail=$((fail + 1))
       failed_names="${failed_names}
  - ${1}" ;;
  esac
}

run_gate() {
  local name="$1"; shift
  local rc=0
  if [ "$JOBS" -le 1 ]; then
    printf '\n=== %s ===\n' "$name"
    "$@" || rc=$?
    tally "$name" "$rc"
    return 0
  fi
  nslot=$((nslot + 1))
  local slot; slot="$SLOTS/$(printf '%04d' "$nslot")"
  printf '%s\n' "$name" > "$slot.name"
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.2; done
  (
    t0=$(date +%s)
    "$@" > "$slot.log" 2>&1 < /dev/null
    echo "$?" > "$slot.rc.tmp"
    echo $(( $(date +%s) - t0 )) > "$slot.secs"
    mv "$slot.rc.tmp" "$slot.rc"
  ) &
}

barrier() {
  [ "$JOBS" -le 1 ] || wait
}

# A gate that must not overlap any other (see the note at the top).
serial_gate() {
  barrier
  run_gate "$@"
  barrier
}

skip_gate() {
  if [ "$JOBS" -le 1 ]; then
    printf '\n=== %s ===\n  SKIPPED: %s\n' "$1" "$2"
    skipped=$((skipped + 1))
    return 0
  fi
  nslot=$((nslot + 1))
  local slot; slot="$SLOTS/$(printf '%04d' "$nslot")"
  printf '%s\n' "$1" > "$slot.name"
  printf '  SKIPPED: %s\n' "$2" > "$slot.log"
  echo 0 > "$slot.secs"
  echo 2 > "$slot.rc"
}

echo "Tockmox static gates, run locally."
echo "Repository: $(pwd)"

# ---------------------------------------------------------------- dependencies
missing=""
have helm || missing="${missing} helm"
have python3 || missing="${missing} python3"
# Many gates under tools/ import yaml. Without PyYAML they die mid-suite
# with a traceback that reads like a broken gate (TM-0890), so ask up front.
if have python3 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
  missing="${missing} python3-yaml"
fi
have jq || missing="${missing} jq"

if [ -n "$missing" ]; then
  echo
  echo "MISSING TOOLS:${missing}"
  echo
  echo "This script refuses to run a partial suite, because several gates cannot"
  echo "tell the difference between 'the tree is wrong' and 'the tool is absent',"
  echo "and they report the first when they mean the second."
  echo
  echo "  helm     https://helm.sh/docs/intro/install/  (v3)"
  echo "  jq       your package manager"
  echo "  python3  3.9 or newer"
  echo "  python3-yaml  python3 -m pip install pyyaml, or your package manager's python3-yaml"
  exit 1
fi

echo "helm:    $(helm version --short 2>/dev/null || echo unknown)"
echo "python3: $(python3 --version 2>&1)"

# Subchart dependencies are vendored, so no `helm dep update` is needed. This
# only rebuilds Chart.lock consistency if something is genuinely absent.
if [ -x tools/helm-deps.sh ]; then
  printf '\n=== helm dependencies ===\n'
  bash tools/helm-deps.sh || {
    echo "helm-deps failed; every render gate below would fail for that reason."
    exit 1
  }
fi

# ---------------------------------------------------------------------- gates
TREE_BEFORE="$(tree_fingerprint)"
[ "$JOBS" -le 1 ] || printf '\nRunning the gates %s at a time (CHECK_ALL_JOBS=1 for one at a time).\n' "$JOBS"
run_gate "every tool is executable" bash -c '
  bad=0
  for f in tools/*.sh; do
    [ -x "$f" ] || { echo "  NOT EXECUTABLE: $f"; bad=1; }
  done
  [ "$bad" -eq 0 ] && echo "  ok"
  exit "$bad"'

# THE TWO GUARDS THAT EXIST BECAUSE SOMETHING SHIPPED, added 2026-09-16. Both
# run here rather than by hand, because both classes travelled all the way into
# a cluster with nothing looking, and a self-test nobody invokes is the same as
# no self-test. Neither needs helm, promtool, kubectl or a cluster, so they cost
# nothing and can never be the reason this script skips.
run_gate "the image extractor handles every quoting form (TM-0646)" \
  bash tools/lib/extract-images.sh --selftest
run_gate "mint-secrets refuses a value with a control character (TM-0662)" \
  bash tools/mint-secrets.sh --selftest

# A TOOL THAT CANNOT RUN IS NOT A FINDING, added 2026-10-16. Four gates
# partition on a missing helm or promtool; each now also treats one that is on
# PATH and cannot execute as missing, and render-counts no longer leaves a
# counts file behind a failed render. Fixture tools on a hermetic PATH, so none
# of these needs a working helm either.
run_gate "the tool probe tells a tool that cannot run from one that runs" \
  bash tools/lib/tool-runs.sh --selftest
run_gate "render-counts leaves no counts file after a failed render" \
  bash tools/render-counts.sh --selftest
run_gate "check-capabilities skips rather than accuses with a helm that cannot run" \
  bash tools/check-capabilities.sh --selftest
run_gate "check-alert-rules skips rather than accuses with a helm or promtool that cannot run" \
  bash tools/check-alert-rules.sh --selftest
run_gate "check-doc-claims skips rather than accuses on a missing tool or a stale counts file" \
  bash tools/check-doc-claims.sh --selftest

# Both passes, exactly as ci.yaml runs them. A bare `helm lint` with no values
# fails EVERY chart on `global.internalDomain` being empty, which is the schema
# working correctly and says nothing whatever about the tree. This script did
# exactly that on its first run and reported nine charts broken ... the same
# defect it was written to prevent, one file later. The all-on overlay is the
# second pass because paths the defaults never render (backups, hardware
# telemetry, the consoles' ingresses) are otherwise linted by nobody, which hid
# a real lint-breaking defect for weeks.
run_gate "helm lint (all layer charts, both value sets)" bash -c '
  bad=0
  for c in charts/tockmox-*; do
    [ "$c" = "charts/tockmox-common" ] && continue
    [ -f "$c/Chart.yaml" ] || continue
    helm lint "$c" -f ci/values.yaml >/dev/null 2>&1 \
      || { echo "  LINT FAILED (defaults): $c"; bad=1; }
    helm lint "$c" -f ci/values.yaml -f ci/values-all-on.yaml >/dev/null 2>&1 \
      || { echo "  LINT FAILED (all-on): $c"; bad=1; }
  done
  [ "$bad" -eq 0 ] && echo "  ok"
  exit "$bad"'

# ci.yaml's "every layer renders against the smallest real site" step. It was
# missing here until 2026-10-06, which let a required key added by TM-0798 pass
# this script and fail CI (and render-diff, which renders the same file).
run_gate "every layer renders against ci/values-site-minimal.yaml" bash -c '
  bad=0
  for c in charts/tockmox-*; do
    [ "$c" = "charts/tockmox-common" ] && continue
    if ! out=$(helm template t "$c" -f ci/values-site-minimal.yaml 2>&1); then
      echo "  RENDER FAILED: $c"; printf "%s\n" "$out" | head -3 | sed "s/^/    /"; bad=1
    fi
  done
  [ "$bad" -eq 0 ] && echo "  ok"
  exit "$bad"'

run_gate "no duplicate top-level keys in values files" bash tools/check-values-duplicate-keys.sh
run_gate "every capability is a switch that does something" bash tools/check-capabilities.sh
run_gate "no NetworkPolicy guards an empty namespace" bash tools/check-no-ghost-policies.sh
run_gate "every NetworkPolicy selector can actually match" bash tools/check-netpol-selectors.sh
run_gate "every aggregated ClusterRole we ship is allowlisted" bash tools/check-rbac-aggregation-allowlist.sh
run_gate "the alert rules we author are tested" bash tools/check-alert-rules.sh
run_gate "every CNPG database has an ingress NetworkPolicy" bash tools/check-cnpg-netpol.sh
run_gate "every CNPG database is reachable by its operator on :8000" bash tools/check-cnpg-operator-reach.sh
run_gate "storage policy holds on the rendered claims" bash tools/check-storage-policy.sh
run_gate "no namespace enforces a Pod Security level its pods fail (TM-0135)" bash tools/check-pod-security.sh
run_gate "every rendered Ingress terminates TLS" bash tools/check-ingress-tls.sh
run_gate "every shipped table panel that hides columns also orders them" bash tools/check-dashboard-panels.sh
run_gate "every OIDC console gets a trust bundle" bash tools/check-trust-wiring.sh
run_gate "site LiteLLM hooks load through values alone (TM-0787)" bash tools/check-litellm-hooks.sh
run_gate "inference-node routes match the UI and the eval gateway is fenced (TM-0920)" bash tools/check-inference-nodes.sh
# The posture-probe add-on (TM-0874, TM-0882). Not in ci.yaml yet: wiring a CI
# gate moves the counts doc-claims.txt pins, and that is its own change.
run_gate "the posture-probe add-on stays observe-only: read-only role, confined policy, versioned report (TM-0874)" bash tools/check-posture-probe.sh
run_gate "the posture-probe gate goes red on a write verb, a widened read, a leaked output and a broken contract (TM-0874)" bash tools/check-posture-probe.sh --selftest
run_gate "the upgrade-wedging shapes from the 0.7.0 lab pass stay fixed" bash tools/check-upgrade-safety.sh
run_gate "the upgrade-safety gate goes red on a migrations Job that keeps its name or drifts from upstream" bash tools/check-upgrade-safety.sh --selftest
run_gate "no bare kubectl or helm in the executed-docs harness (TM-0797)" bash tools/check-harness-context.sh
run_gate "the harness-context gate goes red on a bare call (TM-0797)" bash tools/check-harness-context.sh --selftest
run_gate "a lanCIDR containing the clusterCIDR is refused when nodeOriginSources is set (TM-0790)" bash tools/check-lan-cidr-overlap.sh
run_gate "garage.blockSize renders block_size only when set, above the tables (TM-0782)" bash tools/check-garage-block-size.sh
run_gate "SSO blueprints are parseable YAML" bash tools/check-blueprint-discovery.sh
run_gate "every SSO application is bound to a role group" bash tools/check-sso-bindings.sh
run_gate "identity and AI seams: host, sub_mode, merge-by-email, DB recovery and backup default, Grafana email path, admin-users Job, mint --only (TM-0820, TM-0312, TM-0667)" bash tools/check-identity-seams.sh
run_gate "the identity-seams gate goes red on every assertion (TM-0820)" bash tools/check-identity-seams.sh --selftest
run_gate "platform seams: namespace labels, probe hosts, dashboard keys, CNPG PodMonitor, etcd, Retain (TM-0820)" bash tools/check-platform-seams.sh
run_gate "the platform-seams gate goes red on every assertion (TM-0820)" bash tools/check-platform-seams.sh --selftest
run_gate "no immutable field changes between the baseline tag and the tree (TM-0754)" bash tools/check-immutable-fields.sh
run_gate "no Job keeps its name when its image changes inside one version (TM-1022)" bash tools/check-immutable-fields.sh --perturb-images
run_gate "every ServiceMonitor and PodMonitor selects something the layers render (TM-1025)" bash tools/check-monitor-targets.sh
run_gate "the monitor-targets gate goes red on an unlabelled Service, a missing port and an unmatched PodMonitor (TM-1025)" bash tools/check-monitor-targets.sh --selftest
run_gate "the immutable-field gate goes red on a changed Job template (TM-0754)" bash tools/check-immutable-fields.sh --selftest
run_gate "every action is SHA-pinned and every CI download is checksummed (TM-0592)" bash tools/check-action-pins.sh
run_gate "the action-pin gate goes red on a moving tag and an unchecked download (TM-0592)" bash tools/check-action-pins.sh --selftest
run_gate "observability off: refused without the profile, zero monitors with it, bring-your-own renders (TM-0825)" bash tools/check-capability-monitors.sh
run_gate "the capability-monitors gate goes red on an ungated monitor (TM-0825)" bash tools/check-capability-monitors.sh --selftest
run_gate "the rendered tree reaches no unlisted external host, and audited phone-homes are off or listed (TM-0671)" bash tools/check-cloud-egress.sh
run_gate "the cloud-egress gate goes red on an unlisted host and a phone-home turned on (TM-0671)" bash tools/check-cloud-egress.sh --selftest
run_gate "no Tockmox-owned pod uses the default ServiceAccount or an unlisted API token (TM-0759)" bash tools/check-sa-tokens.sh
run_gate "the service-account token gate goes red on a default account, a missing field and an unlisted token (TM-0759)" bash tools/check-sa-tokens.sh --selftest
run_gate "every rendered container has a memory limit or a written reason (TM-0595)" bash tools/check-memory-limits.sh
run_gate "the memory-limit gate goes red on a dropped limit, a new container and a stale residue entry (TM-0595)" bash tools/check-memory-limits.sh --selftest
run_gate "the alert bridge logs each delivery, ntfy stays single-replica, drill rows name their backup (TM-0779/0780/0794)" bash tools/check-notify-and-drill.sh
run_gate "the notify-and-drill gate goes red on every mutation (TM-0779/0780/0794)" bash tools/check-notify-and-drill.sh --selftest
# TM-0460 (REQ-0004 AC-4.1, ruled 2026-10-08): the gateway is the shipped
# default and the console goes through it on a chart-minted key. Not in
# ci.yaml yet, for the reason at the top of this file.
run_gate "the model gateway is the shipped default, the console goes through it, the console-key Job is scoped, a site may override (TM-0460)" bash tools/check-gateway-default.sh
run_gate "the gateway-default gate goes red on every mutation (TM-0460)" bash tools/check-gateway-default.sh --selftest
run_gate "global.imageRegistry redirects every image" bash tools/check-airgap.sh
# The docs-site gates. The selftest needs only python3; the main run builds the
# site and skips (2) when the pinned MkDocs toolchain is not installed, because a
# laptop without a docs venv is not a tree with a defect. See
# tools/check-docs-offline.sh for why it reads the built files and not the config.
run_gate "the docs offline gate goes red on every external reference (TM-0215)" \
  bash tools/check-docs-offline.sh --selftest
serial_gate "the built documentation site makes no network request (TM-0215)" \
  bash tools/check-docs-offline.sh
run_gate "the committed SBOM matches the tree" bash tools/gen-sbom.sh --check
run_gate "the committed images.txt matches the charts" bash tools/gen-images.sh --check
run_gate "documentation stamps are current" bash tools/stamp-docs.sh --check
# TM-0228. The layer table and the four section READMEs are generated. The
# selftest proves the check goes red on a flipped wave, a flipped installer
# mapping, a hand-edited table and an unlisted page.
run_gate "the docs index surfaces match a fresh render (TM-0228)" bash tools/gen-docs-index.sh --check
run_gate "the docs index check goes red on drift (TM-0228)" bash tools/gen-docs-index.sh --selftest
run_gate "no site specifics in the published tree" bash tools/check-no-site-specifics.sh
run_gate "no workflow publishes a container image (ADR-0036, TM-0098)" bash tools/check-no-published-images.sh
run_gate "the no-published-images gate goes red on every push pattern (ADR-0036)" bash tools/check-no-published-images.sh --selftest
# The docs publish path (TM-0807): the content gate refuses anything that is not
# static web content, and the publish script is run against a stub kubectl.
serial_gate "the built documentation site holds only static web content (TM-0807)" bash tools/check-docs-site-contents.sh
serial_gate "the docs site-contents gate goes red on every non-static file (TM-0807)" bash tools/check-docs-site-contents.sh --selftest
serial_gate "the docs publish script refuses what it must and always removes its pod (TM-0807)" bash tools/publish-docs.sh --selftest
run_gate "documentation style" bash tools/check-docs-style.sh
run_gate "documented commands paste as-is" bash tools/check-pasteable-blocks.sh
# NEVER run_gate THIS EITHER. Reporting mode is deliberate and stays: `--enforce`
# refuses any unclassified block on the three critical-path pages, and today that
# is all 120 of them, so turning it on here would go red on day one ... which is
# exactly how a gate earns an exemption list and then stops being believed. The
# migration flips this to --enforce page by page. Until then the number belongs
# in every run's output and cannot be lost: staged enforcement is defensible,
# staged awareness is not.
#
# What changed 2026-09-15 (TM-0611) is only the ACCOUNTING. Until then this was a
# `run_gate`, so a line that reports and never tests was counted in the "passed"
# total alongside gates that can go red ... the identical defect this file already
# fixed for kubeconform fourteen lines below, for the reason written there. Found
# by mutation-testing all 24 gates: 22 went red for the right reason, 2 correctly
# refused to run, and this one could not fail under any tree state because it is
# not trying to.
#
# So: the scan still runs, its number still prints, and it counts as SKIPPED
# rather than passed. Flipping it back to a gate is the --enforce migration's
# job, not an accounting change.
# It goes through run_gate only to keep its place in a parallel run's ordered report, and it
# EXITS 2 whatever the inventory says: counted as skipped, exactly as before, never as a pass.
run_gate "every documented block is accounted for" bash -c '
  bash tools/check-block-inventory.sh || true
  printf "  NOT A GATE: reported, never enforced. No tree state changes this line.\n"
  printf "  Enforcement is per-page and carded; \`--enforce\` is the real check.\n"
  exit 2'

run_gate "docs links resolve" bash tools/check-docs-links.sh
run_gate "frontmatter contract holds" bash tools/check-frontmatter.sh
# ci.yaml's "every layer renders a non-zero number of resources", which had no
# twin here until TM-0533. It also writes build/render-counts.tsv, which the
# next gate reads, so it must stay ahead of it.
serial_gate "every layer renders a non-zero number of resources" bash tools/render-counts.sh
serial_gate "documented counts still match the tree" bash tools/check-doc-claims.sh
# Both halves here, unlike ci.yaml, which splits them across two jobs because
# only one of them fetches tags. A laptop clone usually has them, and when it
# does not this reports the drift half as skipped rather than failing the run.
run_gate "values stability tiers hold" bash tools/check-values-tiers.sh
# ci.yaml's "values schema rejects an unknown top-level key or component name"
# step. Until TM-0404 that step was inline in ci.yaml and had no twin here, so
# a contributor could pass this script and fail CI on it.
run_gate "values schema rejects a misspelt key or component" bash tools/check-values-typos.sh
run_gate "check-values-typos selftest" bash tools/check-values-typos.sh --selftest
# TM-0383. The config half runs anywhere helm does. The forced-failure half
# needs the litellm CLI (LITELLM_BIN) and reports SKIPPED without it;
# .github/workflows/policy-gate.yaml installs it and always runs both.
# ci.yaml's "the Tockmox UI's tests pass". Exit 2 (skipped) without the UI's
# packages: TOCKMOX_UI_PYTHON names a venv that has them (the script says how).
run_gate "the Tockmox UI's tests pass" bash tools/check-tockmox-ui-tests.sh
run_gate "the policy gate refuses every bad config by name" bash tools/check-policy-gate.sh
run_gate "the policy gate holds with the local backend down" bash tests/policy-gate/run.sh

# NOT a tools/check-*.sh script, and included anyway. CONTRIBUTING.md points
# contributors at this one command, so a gate that runs in ci.yaml and not here
# sends someone to a red build after a green local run. That is how a gate stops
# being believed. It is hermetic and takes about two seconds, so it belongs in
# the same breath as the static ones even though it runs a program rather than
# reading the tree. See tests/installer/README.md.
run_gate "the installer behaves, interactively and from a config file" bash tests/installer/run.sh

have gitleaks \
  && run_gate "gitleaks" gitleaks detect --source . --redact --exit-code 1 \
  || skip_gate "gitleaks" "binary not installed; CI runs it over full history"

# NEVER run_gate THIS. Until 2026-09-13 the line here was
#
#   run_gate "kubeconform" bash -c 'echo "(see ci.yaml ...)"; exit 0'
#
# which never invoked kubeconform at all. With the binary installed the suite
# printed a green "kubeconform" line produced by a hardcoded `exit 0` ... a gate
# that could not fail under any tree state, sitting in the report next to gates
# that can. Proven by putting a kubeconform stub that itself exits 1 first on
# PATH: the line still read pass.
#
# A green that cannot go red is worse than an honest absence, because it is
# counted. So this is a SKIP in both branches until the render pipeline is
# actually wired here (carded), and it names where the real check runs.
skip_gate "kubeconform" "runs in ci.yaml against the full render; NOT executed by this script"

# --------------------------------------------------------------------- result
if [ "$JOBS" -gt 1 ]; then
  barrier
  for f in "$SLOTS"/*.name; do
    [ -e "$f" ] || continue
    b="${f%.name}"; n="$(cat "$f")"
    rc="$(cat "$b.rc" 2>/dev/null || echo 1)"
    printf '\n=== %s === (%ss)\n' "$n" "$(cat "$b.secs" 2>/dev/null || echo '?')"
    cat "$b.log" 2>/dev/null
    [ -e "$b.rc" ] || echo "  (no exit status recorded: the gate's runner died)"
    tally "$n" "$rc"
  done
  printf '\nSlowest gates:\n'
  for f in "$SLOTS"/*.secs; do printf '%6ss  %s\n' "$(cat "$f")" "$(cat "${f%.secs}.name")"; done | sort -rn | head -5
fi
TREE_AFTER="$(tree_fingerprint)"
if [ "$TREE_BEFORE" != "$TREE_AFTER" ]; then
  printf '\nA GATE CHANGED THE CHECKOUT. Running gates at once is only safe when none writes into the tree;\n'
  printf 'this one did (git status before and after differ). Re-run with CHECK_ALL_JOBS=1 and fix the gate.\n'
  diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") | head -20
  fail=$((fail + 1)); failed_names="${failed_names}
  - the checkout is unchanged by the gates"
fi
printf '\n----------------------------------------------------------------\n'
printf '%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
if [ "$fail" -ne 0 ]; then
  printf 'FAILED:%s\n' "$failed_names"
  exit 1
fi
echo "All runnable static gates passed."
echo
echo "Not covered here, and not passed by this run: DCO sign-off, full-history"
echo "secret scanning, and every documented path in tests/executed-docs/."

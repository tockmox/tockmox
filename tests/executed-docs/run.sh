#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The executed-documentation harness.
#
#   TOCKMOX_DOCS_REF=v0.6.0-rc1 ./tests/executed-docs/run.sh
#   TOCKMOX_DOCS_REF=main ./tests/executed-docs/run.sh P01 P03
#
# Shape, from docs/testing-standard.md:
#   1. stand up a throwaway single-node cluster
#   2. run the documented commands VERBATIM, taken from the page at the ref
#   3. assert on artefacts
#   4. assert the CLAIMS, not only the commands
#   5. destroy the cluster
#
# CADENCE. This is not a per-commit gate and must never be made one. It needs a
# real cluster, a real network and roughly twenty minutes of wall clock, so it
# runs nightly and before every release tag, on the devtest runner. That is a
# stated property: testing-standard rule 6 says a check that is expensive and
# therefore quietly never runs is worse than one that does not exist, because it
# appears in the inventory and buys unearned confidence.
#
# WHAT A GREEN RUN OF THIS HARNESS DOES NOT MEAN. It covers the paths in
# tests/executed-docs/paths/ and nothing else. INVENTORY.md is the list of every
# documented path and is the only honest answer to "what is covered?" ... this
# script's exit code answers a much smaller question.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then echo "must run under bash" >&2; exit 2; fi
if [ "${BASH_VERSINFO[0]:-0}" -lt 3 ]; then
  echo "needs bash 3.2 or newer, found ${BASH_VERSION:-unknown}" >&2; exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CLUSTER="${HERE}/provision/throwaway-cluster.sh"
REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the git ref whose docs are under test}"

RUNDIR="${TOCKMOX_WORKDIR:-${TMPDIR:-/tmp}/executed-docs}"
mkdir -p "$RUNDIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="${RUNDIR}/report-${REF//\//_}-${STAMP}.txt"

# ---------------------------------------------------------------- resumable
#
# TOCKMOX_RUN_RESUME=<dir> makes one logical run survive several invocations.
# The reason is the agent's per-command cap (~3 minutes): a provision alone is
# ~110s and a full run with route waves is closer to an hour, so without this
# the only way to run the suite from that seat was TOCKMOX_EXISTING_KUBECONFIG,
# which collapses every route group into one cluster and therefore cannot
# exercise the very mechanism (rebuild between groups) it exists to test.
# Recorded in the harness rather than worked around, because "syntax-checked,
# never executed" was the honest status of route waves for a day (2026-09-14).
#
# What persists: the report and stamp, the guest kubeconfig of the group in
# progress, which groups and paths are done and with what rc, the counters.
# A path may exit 75 to say "call me again" (P09 does, on its own budget); the
# runner then persists and exits 75 itself WITHOUT tearing anything down. The
# EXIT trap only destroys when the run is actually finishing. A fresh run with
# the same dir starts over: delete the dir to restart.
#
# TOCKMOX_RUN_BUDGET=<seconds> (default 0 = unlimited) makes the runner yield
# 75 before STARTING a path or a rebuild once that much wall clock is spent in
# this invocation, so a call is not killed mid-path with its verdict lost.
RESUME="${TOCKMOX_RUN_RESUME:-}"
RUN_BUDGET="${TOCKMOX_RUN_BUDGET:-0}"
RUN_T0="$(date +%s)"
YIELDING=0
if [ -n "$RESUME" ]; then
  mkdir -p "$RESUME"
  if [ -s "${RESUME}/stamp" ]; then
    STAMP="$(cat "${RESUME}/stamp")"
    REPORT="${RUNDIR}/report-${REF//\//_}-${STAMP}.txt"
  else
    printf '%s' "$STAMP" > "${RESUME}/stamp"
  fi
fi
resume_get()  { [ -n "$RESUME" ] && [ -s "${RESUME}/$1" ] && cat "${RESUME}/$1"; }
resume_put()  { [ -n "$RESUME" ] && printf '%s' "$2" > "${RESUME}/$1"; }
resume_done() { [ -n "$RESUME" ] && [ -f "${RESUME}/done.$1" ]; }
resume_mark() { [ -n "$RESUME" ] && printf '%s' "${2:-0}" > "${RESUME}/done.$1"; }
budget_ok()   { [ "$RUN_BUDGET" -le 0 ] || [ $(( $(date +%s) - RUN_T0 )) -lt "$RUN_BUDGET" ]; }
# A rebuild is destroy + create, ~two minutes on the KubeVirt substrate, and a
# create interrupted by a cap leaves a guest that never reports in (its
# cloud-init token is replaced by the next create). So a rebuild is only
# started early in an invocation: TOCKMOX_RUN_REBUILD_BUDGET seconds (default:
# the run budget) is the latest point at which one may begin.
REBUILD_BUDGET="${TOCKMOX_RUN_REBUILD_BUDGET:-$RUN_BUDGET}"
rebuild_ok()  { [ "$REBUILD_BUDGET" -le 0 ] || [ $(( $(date +%s) - RUN_T0 )) -lt "$REBUILD_BUDGET" ]; }
save_counters() {
  [ -n "$RESUME" ] || return 0
  {
    printf 'RAN=%s\nFAILED=%s\nSKIPPED=%s\nUNCONVERTED=%s\n' "$RAN" "$FAILED" "$SKIPPED" "$UNCONVERTED"
    printf 'ABSENT_NAMES=%q\nunconverted_names=%q\n' "$ABSENT_NAMES" "$unconverted_names"
  } > "${RESUME}/counters"
}
yield_run() {
  YIELDING=1
  save_counters
  echo "" | tee -a "$REPORT"
  echo "YIELD: ${1} ... state in ${RESUME}; run the same command again to continue." | tee -a "$REPORT"
  exit 75
}
export ASSERT_REPORT="$REPORT"

cd "$REPO"

# The ref has to exist, and it has to be a ref rather than a branch tip that
# moved under the run. Record the resolved commit so the report names an
# immutable object even when REF is a branch.
if ! COMMIT="$(git --no-optional-locks rev-parse --verify "${REF}^{commit}" 2>/dev/null)"; then
  echo "REFUSING: '${REF}' is not a commit in this repository" >&2
  exit 2
fi

if [ -n "$RESUME" ] && [ -s "$REPORT" ]; then
  echo "" | tee -a "$REPORT"
  echo "=== resumed $(date -u +%Y%m%dT%H%M%SZ) (state: ${RESUME}) ===" | tee -a "$REPORT"
else
{
  echo "executed-documentation harness"
  echo "  ref under test : ${REF}"
  echo "  resolved commit: ${COMMIT}"
  echo "  started        : ${STAMP}"
  echo "  runner         : $(uname -s)/$(uname -m)"
  echo "  report         : ${REPORT}"
  [ -n "$RESUME" ] && echo "  resumable      : ${RESUME}  (a 75 exit means call again)"
} | tee "$REPORT"
fi

# Which paths to run. Default is every executable file in paths/, in name order,
# because the numbering encodes an ordering that some paths depend on (P02
# recovers the state P01 leaves).
PATHS=()
if [ $# -gt 0 ]; then
  for sel in "$@"; do
    for f in "${HERE}/paths/${sel}"*.sh; do
      [ -f "$f" ] && PATHS+=("$f")
    done
  done
else
  for f in "${HERE}"/paths/P*.sh; do
    [ -f "$f" ] && PATHS+=("$f")
  done
fi
if [ "${#PATHS[@]}" -eq 0 ]; then
  echo "REFUSING: no paths selected. A run that executes nothing must not report success." >&2
  exit 2
fi

# ---------------------------------------------------------------- route waves
#
# ONE CLUSTER PER INSTALL ROUTE. A path that asserts on an artifact only its own
# route could have produced is defeated by any earlier path that installed the
# same component another way ... and that is the NORMAL order of a full run, not
# an accident. Measured 2026-09-13: P04's `helm release argocd` assertion read 0
# while argocd-server was up and Healthy, because P01/P02 had installed ArgoCD
# by raw manifest first. On a virgin cluster P04 passes 4 of 4.
#
# So paths are grouped by the route they install, and each group gets a cluster
# whose prior state this run can testify to. A path declares its route with
# `# tockmox:route=<name>` in its own header; paths that install nothing share
# the default group and cost no extra cluster.
#
# Computed here, BEFORE provisioning, rather than after: TM-0581's dry-run mode
# (below) needs the derived groups and nothing else, and deriving them from the
# same function the real run uses -- never a second copy of the logic -- is
# what makes the dry run actual evidence about the real grouping rather than a
# parallel implementation that could quietly drift from it.
route_of() {
  sed -n 's/^# tockmox:route=\([A-Za-z0-9_.-]*\).*/\1/p' "$1" | head -1
}

ROUTES=""
for p in "${PATHS[@]}"; do
  r="$(route_of "$p")"; r="${r:-none}"
  case " $ROUTES " in *" $r "*) ;; *) ROUTES="${ROUTES}${ROUTES:+ }${r}" ;; esac
done
if [ -n "${TOCKMOX_EXISTING_KUBECONFIG:-}" ] && [ "$(echo $ROUTES | wc -w)" -gt 1 ]; then
  {
    echo "NOTE: reused cluster, so the ${ROUTES} route groups all share it."
    echo "      Own-route assertions in later groups are NOT provenance evidence"
    echo "      in this run. Provision per group to make them so."
  } | tee -a "$REPORT"
fi
echo "route groups: ${ROUTES}" | tee -a "$REPORT"
for route in $ROUTES; do
  members=""
  for p in "${PATHS[@]}"; do
    pr="$(route_of "$p")"; pr="${pr:-none}"
    [ "$pr" = "$route" ] || continue
    members="${members}${members:+ }$(basename "$p" .sh)"
  done
  echo "  group '${route}': ${members}" | tee -a "$REPORT"
done

# TOCKMOX_DRY_RUN=1 -- print the derived route groups and stop. No cluster is
# created, no path is executed, nothing is torn down (the cleanup trap is not
# even installed yet). This is what TM-0581 asked for: a way to prove the
# grouping mechanism itself -- reading `# tockmox:route=` headers and bucketing
# paths by name -- without needing a substrate at all. It settles the grouping
# half of the card's own DoD; it says nothing about whether a rebuilt cluster
# actually gives P04/P05 a virgin own-route artefact, which still needs a real
# run (TOCKMOX_RUN_RESUME, or a full nightly) to observe.
if [ "${TOCKMOX_DRY_RUN:-0}" = "1" ]; then
  {
    echo ""
    echo "DRY RUN: grouping only. No cluster was created and no path ran."
  } | tee -a "$REPORT"
  echo "report: ${REPORT}"
  exit 0
fi

# ---- TM-0797: NO BARE kubectl OR helm, ANYWHERE IN THIS HARNESS -------------
# Every call names its cluster. Two clusters are in play and each has its own
# variable, both REFUSED when empty (`--context=` with an empty value silently
# means the current context, which is the failure this exists to prevent):
#
#   TOCKMOX_SUBSTRATE_CONTEXT  the hypervisor cluster that hosts the throwaway
#                              VM. The operator supplies it; nothing is derived
#                              from whichever context happens to be current.
#                              Not needed when TOCKMOX_EXISTING_KUBECONFIG names
#                              a cluster this run did not create (no VM is made
#                              or destroyed), nor for TOCKMOX_DRY_RUN.
#   KUBE_CONTEXT               the cluster under test. For a cluster this run
#                              creates it is read from the kubeconfig the
#                              provisioner just wrote (one cluster in it). For
#                              TOCKMOX_EXISTING_KUBECONFIG the operator supplies
#                              it, because a file we did not write proves
#                              nothing about which of its contexts is meant.
#
# tools/check-harness-context.sh is the gate that keeps a bare call from coming
# back. It reads text; it cannot tell that the context you named is the right
# cluster, only that one is named.
if [ -z "${TOCKMOX_EXISTING_KUBECONFIG:-}" ]; then
  : "${TOCKMOX_SUBSTRATE_CONTEXT:?TOCKMOX_SUBSTRATE_CONTEXT is empty: export the kubectl context of the hypervisor cluster that hosts the throwaway VM}"
  export TOCKMOX_SUBSTRATE_CONTEXT
else
  : "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: TOCKMOX_EXISTING_KUBECONFIG names a cluster this run did not create, so say which context in it is meant}"
fi

CREATED=0
# The context a guest kubeconfig FILE names, for a file this run wrote. Reads the
# file only. Callers refuse an empty answer.
guest_context_of() { # <kubeconfig>
  # ctx-exempt-next: reads the context NAME out of a kubeconfig file this run wrote; reaches no cluster
  KUBECONFIG="$1" kubectl config current-context 2>/dev/null
}
# The guest API answers, under the context that file names.
guest_ready() { # <kubeconfig>
  local kc="$1" ctx
  ctx="$(guest_context_of "$kc")"
  [ -n "$ctx" ] || return 1
  KUBECONFIG="$kc" kubectl --context="${ctx:?the guest kubeconfig names no context}" get --raw /readyz >/dev/null 2>&1
}
# ---- the SUBSTRATE credential, kept separate from the guest's ---------------
# `create` talks to the hypervisor; everything after it talks to the guest, and
# this script exports the guest's kubeconfig over KUBECONFIG to make that work.
# Teardown talks to the HYPERVISOR again, so it has to be handed the credential
# it started with. Measured 2026-09-04: without this, `destroy` ran against the
# GUEST cluster, where `vm` is not a resource type. The delete errored into
# `|| true`, and destroy's own artefact assertions then counted VMs in a
# namespace on the wrong cluster, found zero, and printed PASS ... a teardown
# reporting success having deleted nothing, leaving the throwaway running.
SUBSTRATE_KUBECONFIG="${KUBECONFIG:-}"
cleanup() {
  rc=$?
  if [ "$YIELDING" -eq 1 ]; then
    echo "yielded; the cluster stays up for the next invocation" | tee -a "$REPORT"
    echo "report: ${REPORT}"
    exit 75
  fi
  if [ "$CREATED" -eq 1 ] && [ "${TOCKMOX_KEEP_CLUSTER:-0}" != "1" ]; then
    echo "" | tee -a "$REPORT"
    echo "=== teardown ===" | tee -a "$REPORT"
    KUBECONFIG="$SUBSTRATE_KUBECONFIG" "$CLUSTER" destroy 2>&1 | tee -a "$REPORT" || true
  elif [ "${TOCKMOX_KEEP_CLUSTER:-0}" = "1" ]; then
    echo "TOCKMOX_KEEP_CLUSTER=1 ... cluster left standing for inspection." | tee -a "$REPORT"
    echo "Tear it down with: TOCKMOX_TEST_VM=${TOCKMOX_TEST_VM:-k3s-test-01} tests/executed-docs/provision/throwaway-cluster.sh destroy (that VM only)" | tee -a "$REPORT"
  fi
  echo "report: ${REPORT}"
  exit $rc
}
trap cleanup EXIT INT TERM

echo "" | tee -a "$REPORT"
echo "=== provisioning ===" | tee -a "$REPORT"

# TOCKMOX_EXISTING_KUBECONFIG -- run against a cluster this run did NOT create.
#
# The agent driving these tests has a hard per-command time cap, and a full
# provision plus nine paths does not fit inside it. Without a reuse hook the
# only way to run the suite here is to let a call die mid-run, which produces a
# truncated report that is worse than no report.
#
# THE HOOK IS EXPLICIT, LOUD, AND DISARMS TEARDOWN, because reuse is exactly the
# shared-fixture defect this harness keeps finding in other clothes. A run that
# did not create its cluster cannot assert anything about what the cluster
# looked like beforehand, so it must never be read as provenance evidence:
# the banner below goes in the report, and PROVENANCE=reused is stamped where a
# reader cannot miss it. Teardown stays disarmed ... deleting a cluster this run
# did not create is how a throwaway carrying someone else's install disappears.
if [ -n "${TOCKMOX_EXISTING_KUBECONFIG:-}" ]; then
  if [ ! -s "$TOCKMOX_EXISTING_KUBECONFIG" ]; then
    echo "REFUSING: TOCKMOX_EXISTING_KUBECONFIG is set but empty or missing:" | tee -a "$REPORT"
    echo "          ${TOCKMOX_EXISTING_KUBECONFIG}" | tee -a "$REPORT"
    exit 1
  fi
  GUEST_KUBECONFIG="$TOCKMOX_EXISTING_KUBECONFIG"
  CREATE_RC=0
  {
    echo "PROVENANCE=reused"
    echo "  This run did NOT create its cluster. It cannot testify to the"
    echo "  cluster's prior state, so no result below is provenance evidence."
    echo "  Teardown is disarmed. Kubeconfig: ${GUEST_KUBECONFIG}"
  } | tee -a "$REPORT"
elif [ -n "$RESUME" ] && [ -s "$(resume_get guest.kubeconfig)" ] \
     && guest_ready "$(resume_get guest.kubeconfig)"; then
  GUEST_KUBECONFIG="$(resume_get guest.kubeconfig)"
  CREATE_RC=0
  echo "resumed: reusing the guest cluster this run created earlier ($(resume_get group.current))" | tee -a "$REPORT"
else
  if ! budget_ok; then yield_run "budget spent before provisioning"; fi
  GUEST_KUBECONFIG="$("$CLUSTER" create | tail -1)"
  CREATE_RC=$?
  resume_put guest.kubeconfig "$GUEST_KUBECONFIG"
fi
# CREATED is set BELOW, only once provisioning is known to have worked. It used
# to be set on this line unconditionally, so a `create` that refused ... a wrong
# substrate credential, a stale image default ... still armed the teardown, and
# the EXIT trap then ran `destroy` against whatever KUBECONFIG happened to be
# set. On 2026-09-04 that was a guest cluster carrying a completed install.
# A setup step that failed must not be able to delete anything.

# Stop here if provisioning failed. An earlier version carried on with an empty
# KUBECONFIG, which made every kubectl fall back to localhost:8080 and produced
# a page of connection-refused noise that read like the CLUSTER was broken. The
# provisioner had in fact refused cleanly, one line, at the top. Never let a
# failed setup masquerade as a failed test.
if [ "$CREATE_RC" -ne 0 ] || [ -z "$GUEST_KUBECONFIG" ] || [ ! -s "$GUEST_KUBECONFIG" ]; then
  {
    echo "REFUSING: provisioning did not produce a kubeconfig (rc=${CREATE_RC})."
    echo "          Path returned: '${GUEST_KUBECONFIG:-<empty>}'"
    echo "          The provisioner's own message above is the real error."
    echo "          Nothing below this line would have measured the documented paths."
  } | tee -a "$REPORT"
  exit 1
fi
# CREATED arms teardown. A reused cluster is never torn down by this run.
if [ -z "${TOCKMOX_EXISTING_KUBECONFIG:-}" ]; then CREATED=1; fi
export KUBECONFIG="$GUEST_KUBECONFIG"

# THE SUBSTRATE CREDENTIAL HAS TO REACH THE PATHS TOO, and until 2026-09-13 it
# did not. Teardown was given it (see the cleanup() note above, where running
# `destroy` against the GUEST once reported success having deleted nothing);
# the same reasoning was never applied to the paths themselves. P03's step 1 is
# node-local by the page's own instruction, so it calls
# `throwaway-cluster.sh exec`, which talks to the HYPERVISOR ... and it was
# inheriting the guest kubeconfig this line just exported.
#
# The failure mode is the one this harness keeps meeting: P03 read the
# unreachable node as "this section is not documented at this ref" and exited 3,
# so the run counted it under `paths absent` and still reported success. An
# environmental fault was laundered into a statement about the documentation.
export TOCKMOX_SUBSTRATE_KUBECONFIG="$SUBSTRATE_KUBECONFIG"

# TM-0469 gave fresh-install.md sections 6 and 7 a `: "${KUBE_CONTEXT:?}"`
# guard, because those sections install cluster-wide components and used to
# name no cluster at all. Five bash blocks across the two sections now open
# with it, and P04/P05 run those blocks VERBATIM through `bash -c`, so with
# KUBE_CONTEXT unset every one of them fails at its first line.
#
# The harness identified its cluster by KUBECONFIG plus current-context and
# never named a context, so the page became stricter than the harness. The fix
# is to satisfy the page's contract rather than to weaken the page: derive the
# context from the guest kubeconfig we just created, and export it so extracted
# blocks run as written. `--context=` with an EMPTY value silently means
# current-context, which is the exact failure the guard exists to prevent, so
# an empty answer here is fatal rather than something to paper over.
if [ -z "${TOCKMOX_EXISTING_KUBECONFIG:-}" ]; then
  KUBE_CONTEXT="$(guest_context_of "$GUEST_KUBECONFIG")"
fi
if [ -z "${KUBE_CONTEXT:-}" ]; then
  {
    echo "FATAL: no context names the cluster under test."
    echo "       KUBECONFIG=${GUEST_KUBECONFIG}"
    echo "       Every fresh-install.md block guarded by \${KUBE_CONTEXT:?} would"
    echo "       fail, and any command reaching a cluster would target whatever"
    echo "       the ambient config points at. Refusing to run the paths."
  } | tee -a "$REPORT"
  exit 1
fi
export KUBE_CONTEXT
# A context we were handed (or derived) must exist in the file, or every call
# below would fail with a message that reads like a cluster fault.
# ctx-exempt-next: lists context NAMES in a kubeconfig file; reaches no cluster
if ! KUBECONFIG="$GUEST_KUBECONFIG" kubectl config get-contexts -o name 2>/dev/null | grep -Fxq -- "$KUBE_CONTEXT"; then
  echo "REFUSING: context '${KUBE_CONTEXT}' is not in ${GUEST_KUBECONFIG}." | tee -a "$REPORT"
  exit 1
fi
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty}"

# Prove the cluster before running anything against it. If this is wrong, every
# assertion downstream is measuring the wrong machine, and a red result would be
# blamed on the docs.
NODE_READY="$(kubectl --context="$KUBE_CONTEXT" get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1)"
K8S_VER="$(kubectl --context="$KUBE_CONTEXT" version -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | tail -1)"
{
  echo "ARTEFACT: node[0] .status.conditions[type=Ready].status"
  echo "EXPECTED: True"
  echo "ACTUAL:   ${NODE_READY}"
  echo "CLUSTER:  ${K8S_VER:-unknown}"
} | tee -a "$REPORT"
if [ "$NODE_READY" != "True" ]; then
  echo "REFUSING: the throwaway cluster is not Ready. Nothing below would mean anything." | tee -a "$REPORT"
  exit 1
fi

# ---- THE FAIL-CLOSED AUTHORITY ---------------------------------------------
#
# Added 2026-09-13 after an outside critique of the harness design found the
# defect this block exists to close.
#
# The aggregate used to be `[ "$FAILED" -eq 0 ]`: a run was green when no path
# returned a failing exit code. The six-outcome model and its "PASS is
# unrepresentable without a completed execute phase" rule live in
# lib/assert.sh, and NOT EVERY PATH USES THEM YET. So a path that never adopted
# the model returned 0 and counted as green, which made that rule a property of
# ONE LIBRARY rather than of the harness. The critique put it exactly right:
# the system as a whole could still report green through an older path.
#
# So: every path must leave a canonical outcome RECEIPT. A path that leaves
# none is UNCONVERTED, and an unconverted path makes the run REFUSE SUCCESS
# rather than quietly counting as a pass. Deliberately fail-closed ...
# converting a path is work, and until it is done the honest report is "this
# run cannot be trusted as green", not "green".
OUTCOME_RECEIPT_DIR="${RUNDIR}/receipts-${STAMP}"
export OUTCOME_RECEIPT_DIR
if [ -n "$RESUME" ]; then
  ABSENCE_RECEIPT_DIR="${RESUME}/absence-receipts"; mkdir -p "$ABSENCE_RECEIPT_DIR"
else
  ABSENCE_RECEIPT_DIR="${WORKDIR:-/tmp}/absence-receipts.$$"
  rm -rf "$ABSENCE_RECEIPT_DIR"; mkdir -p "$ABSENCE_RECEIPT_DIR"
fi
export ABSENCE_RECEIPT_DIR
mkdir -p "$OUTCOME_RECEIPT_DIR"

FAILED=0
SKIPPED=0
ABSENT_NAMES=""
RAN=0
UNCONVERTED=0
unconverted_names=""
if [ -n "$RESUME" ] && [ -s "${RESUME}/counters" ]; then
  # shellcheck disable=SC1090
  . "${RESUME}/counters"
fi
# route_of(), ROUTES and the per-group membership are computed above, before
# provisioning (TM-0581's dry-run mode needs them there). Reuse
# (TOCKMOX_EXISTING_KUBECONFIG) forces a SINGLE group and says so, because a run
# that did not create its cluster cannot testify to any group's prior state ...
# the provenance banner already printed above applies to the whole run. That
# check ran earlier too, alongside the group derivation it depends on.

# Run group by group. Between groups, rebuild the cluster so the next group's
# own-route assertions mean something. A failure to reprovision is INFRA, not a
# product finding, and stops the run rather than silently continuing on a dirty
# cluster ... which is the defect this whole mechanism exists to remove.
reprovision() {
  echo "" | tee -a "$REPORT"
  echo "=== rebuilding the cluster for route group '$1' ===" | tee -a "$REPORT"
  KUBECONFIG="$SUBSTRATE_KUBECONFIG" "$CLUSTER" destroy >/dev/null 2>&1 || true
  local kc; kc="$(KUBECONFIG="$SUBSTRATE_KUBECONFIG" "$CLUSTER" create | tail -1)"
  if [ -z "$kc" ] || [ ! -s "$kc" ]; then
    echo "REFUSING: could not rebuild for group '$1'. INFRA, not a product finding." | tee -a "$REPORT"
    exit 1
  fi
  export KUBECONFIG="$kc"
  KUBE_CONTEXT="$(guest_context_of "$kc")"; export KUBE_CONTEXT
  : "${KUBE_CONTEXT:?the rebuilt guest kubeconfig names no context}"
}

GROUP_INDEX=0
for route in $ROUTES; do
  GROUP_INDEX=$((GROUP_INDEX + 1))
  if resume_done "group.${route}"; then
    echo "resumed: route group '${route}' already complete" | tee -a "$REPORT"
    continue
  fi
  if [ "$GROUP_INDEX" -gt 1 ] && [ -z "${TOCKMOX_EXISTING_KUBECONFIG:-}" ] \
     && [ "$(resume_get group.current)" != "$route" ]; then
    if ! rebuild_ok; then yield_run "too late in this invocation to rebuild for group '${route}'"; fi
    reprovision "$route"
    resume_put guest.kubeconfig "$KUBECONFIG"
  fi
  resume_put group.current "$route"
  echo "" | tee -a "$REPORT"
  echo "=== route group: ${route} ===" | tee -a "$REPORT"
for p in "${PATHS[@]}"; do
  pr="$(route_of "$p")"; pr="${pr:-none}"
  [ "$pr" = "$route" ] || continue
  name="$(basename "$p" .sh)"
  if resume_done "path.${name}"; then
    echo "resumed: ${name} already ran (rc=$(resume_get "done.path.${name}"))" | tee -a "$REPORT"
    continue
  fi
  if ! budget_ok; then yield_run "budget spent before ${name}"; fi
  TOCKMOX_PATH_NAME="$name" bash "$p"
  rc=$?
  if [ "$rc" -eq 75 ]; then
    yield_run "${name} asked to be called again"
  fi
  resume_mark "path.${name}" "$rc"
  case "$rc" in
    0) RAN=$((RAN + 1)) ;;
    3) SKIPPED=$((SKIPPED + 1))
       ABSENT_NAMES="${ABSENT_NAMES}${ABSENT_NAMES:+ }${name}"
       echo "SKIPPED ${name}: not a documented path at ${REF} (recorded as an exception)" | tee -a "$REPORT" ;;
    *) RAN=$((RAN + 1)); FAILED=$((FAILED + 1))
       echo "FAILED  ${name} (rc=${rc})" | tee -a "$REPORT" ;;
  esac
  # A declared exception (rc 3) is a legitimate terminal state and needs no
  # receipt. Everything else must have declared an outcome.
  if [ "$rc" -ne 3 ] && [ ! -f "${OUTCOME_RECEIPT_DIR}/${name}" ]; then
    UNCONVERTED=$((UNCONVERTED + 1))
    unconverted_names="${unconverted_names}
  - ${name}"
    echo "UNCONVERTED ${name}: exited ${rc} without declaring a canonical outcome" | tee -a "$REPORT"
  fi
  save_counters
done
  resume_mark "group.${route}" 0
done

{
  echo ""
  echo "================================================================"
  echo "RUN SUMMARY  ref=${REF}  commit=${COMMIT}"
  echo "  paths executed : ${RAN}"
  echo "  paths failed   : ${FAILED}"
  echo "  paths absent   : ${SKIPPED}  (not documented at this ref)"
  # NAME them. A count reads as routine; a name is actionable. P01 spent an
  # unknown number of runs "absent" because prerequisites.md was rewritten and
  # its '## 2. ArgoCD, 2.6 or newer' section stopped existing ... the path was
  # testing nothing, every run said so in one digit, and nobody read a digit.
  # An absent path is not a passing path: it is coverage that silently left.
  # DECLARED versus UNDECLARED absence, and the distinction is the whole point.
  #
  # The first version of this block said, of every absent path, "its documented
  # section is GONE at this ref; re-point the path or retire it." That is a
  # false accusation against a path whose absence is a recorded decision. P01 is
  # exactly that case: INVENTORY.md records (TM-0422, 2026-09-04) that the
  # raw-manifest route is not documented at main BY DESIGN, that P01 therefore
  # skips cleanly, and that it is exercised at ref 24e3a9b where the route still
  # exists. Nagging every run about a settled decision is how a report earns the
  # skim that hides the undeclared one.
  #
  # So a path declares absence by exporting TOCKMOX_<NAME>_ABSENT_OK with a
  # reason, and the runner reports the two differently. An UNDECLARED absence is
  # coverage that left without anyone noticing, and stays loud.
  if [ -n "$ABSENT_NAMES" ]; then
    for _a in $ABSENT_NAMES; do
      # Read the reason from its receipt rather than from a packed variable.
      # Packing it into a space-delimited list meant mangling the spaces out of
      # a sentence written for a human to read, which defeats the point of
      # having it say anything.
      _why=""
      [ -s "${ABSENCE_RECEIPT_DIR}/${_a}" ] && _why="$(head -1 "${ABSENCE_RECEIPT_DIR}/${_a}")"
      if [ -n "$_why" ]; then
        echo "                   - ${_a}  (declared) ${_why}"
      else
        echo "                   - ${_a}  ... UNDECLARED. Its documented section is gone at"
        echo "                     this ref and nothing records that as intended. Re-point it,"
        echo "                     retire it, or declare the absence. It is testing nothing."
      fi
    done
  fi
  echo "  UNCONVERTED    : ${UNCONVERTED}  (exited without a canonical outcome)"
  echo "================================================================"
  echo ""
  echo "Coverage is NOT what this summary reports. It reports what ran."
  echo "For what is covered and what is knowingly not, read"
  echo "  tests/executed-docs/INVENTORY.md"
} | tee -a "$REPORT"

if [ "$UNCONVERTED" -gt 0 ]; then
  {
    echo ""
    echo "THIS RUN CANNOT REPORT SUCCESS."
    echo ""
    echo "${UNCONVERTED} path(s) finished without declaring a canonical outcome:${unconverted_names}"
    echo ""
    echo "An exit code of 0 is not an outcome. Until a path calls path_outcome"
    echo "through lib/assert.sh, its green means only that its script reached the"
    echo "end ... which is exactly how a path once reported three passes while the"
    echo "command it exists to test had installed nothing."
    echo ""
    echo "Convert the path, or mark it a declared exception. Do not relax this."
  } | tee -a "$REPORT"
  exit 1
fi

[ "$FAILED" -eq 0 ]

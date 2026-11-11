#!/usr/bin/env bash
# The install.md lane: P09 end to end on ONE throwaway that already carries what install.md starts from.
#
# P09 cannot run inside a bare run.sh. It needs ArgoCD and sealed-secrets on the cluster it installs into
# (fresh-install.md 6 and 7), but run.sh gives every install route its own cluster, and P04 (ArgoCD) and
# P05 (sealed-secrets) are different routes. It also needs a git remote that the cluster can clone the
# product tree from. This script provides both on one throwaway:
#   1. create the throwaway (throwaway-cluster.sh create; its capacity gate refuses first if it does not fit)
#   2. run.sh P04 P05 against it (TOCKMOX_EXISTING_KUBECONFIG), the state install.md starts from
#   3. serve this tree from inside it (site-repo-server.sh), so the Applications read THIS tree
#   4. run.sh P09 against it, the route TOCKMOX_P09_ROUTE names (built-in or external), its blocks read from
#      this tree's install.md (TOCKMOX_P09_FROM_TREE=1)
#   5. on a kept built-in run, keep P09's recovery kit and the age identity that opens it as the Secret
#      ${TOCKMOX_TEST_VM}-kit beside the VM (throwaway-cluster.sh kit-store), because both otherwise end
#      with this job; `throwaway-cluster.sh kit DIR` fetches them, and destroy removes them with the VM
#   6. when P09 passed, run P10 on the same throwaway and the same state directory (a backup and a restore
#      drill of each database, and the migrations Job; paths/P10-fresh-install-recovery.sh). P10 has its own
#      budget, TOCKMOX_P10_BUDGET (default 5400 seconds), a yield point this lane does not call again, so a
#      P10 that yields is a failed lane. P10 does not run when P09 failed, and its result is the lane's only
#      when P09 passed
#   7. destroy it, unless TOCKMOX_KEEP_CLUSTER=1. A kept run that stopped before step 4 began is destroyed all the
#      same (there is no install to keep), unless TOCKMOX_KEEP_ON_PREP_FAILURE=1
#
# AN OFF-SITE COPY, with TOCKMOX_P09_OFFSITE=git (default none; built-in route only). Without it the
# install warns "no off-site copy" and there is nothing to rebuild the throwaway from. With it:
#   - before step 1, the settings are read from the Secret p09-offsite beside the VMs
#     (throwaway-cluster.sh offsite-check; the keys are listed there), so a credential that cannot read
#     it stops the run before a VM exists. A forge on a private CA (key ca.crt) needs this tree's
#     bootstrap-forge to take --offsite-git-ca, and the run is refused when it does not;
#   - after step 1, a repository named after the VM is created on that forge (offsite-repo) and the
#     guest is shown to reach it (offsite-reach);
#   - after step 2, the forge's CA goes into ArgoCD's argocd-tls-certs-cm on the throwaway, under the
#     forge's host name, so its ArgoCD can read that forge too;
#   - step 4 runs P09 with the destination: P09 adds --offsite-git, --offsite-git-credentials and
#     --offsite-git-ca to install.md's bootstrap-forge command, as the page says to;
#   - destroy and sweep delete the repository with the VM.
# The forge's name and the token never reach this job's log or its report: the provisioner's lines name
# the Secret and its keys, and P09 replaces the host in what it prints (lib/p09-offsite.sh).
#
# It is what the executed-docs workflow runs on a dispatch with lane=p09, and it runs the same from a
# workstation whose credential the harness accepts (a tockmox-test ServiceAccount token, on a network the
# guest can call back from). Inputs: TOCKMOX_DOCS_REF, TOCKMOX_SUBSTRATE_CONTEXT, TOCKMOX_TEST_NAMESPACE,
# TOCKMOX_TEST_VM, TOCKMOX_P09_ROUTE (default built-in); optional TOCKMOX_KEEP_CLUSTER, TOCKMOX_P09_BUDGET,
# TOCKMOX_P09_OFFSITE (none or git), TOCKMOX_P09_LAN_CIDR and TOCKMOX_P09_POOL (default: the node's /24 and
# .240-.250 in it).
# Exit: P09's own exit status, or P10's when P09 passed and P10 did not; 2 for a refused precondition; 1 when a preparation step fails, or when P09
# passed on a kept run and its kit could not be kept (the report says which).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "${HERE}/../.." && pwd)"
PROV="${HERE}/provision"
: "${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the git ref whose docs are under test}"
: "${TOCKMOX_SUBSTRATE_CONTEXT:?set TOCKMOX_SUBSTRATE_CONTEXT to the kubectl context of the hypervisor}"
: "${TOCKMOX_TEST_VM:?set TOCKMOX_TEST_VM to the VM name of this run}"
export TOCKMOX_WORKDIR="${TOCKMOX_WORKDIR:-${TMPDIR:-/tmp}/executed-docs}"
LANE="${TOCKMOX_WORKDIR}/p09-lane"
mkdir -p "$LANE"
# Step 5 keeps only a kit written from this second on: a runner that outlives its job can still hold an earlier run's.
LANE_T0="$(date -u +%s)"
SUBSTRATE_KUBECONFIG="${KUBECONFIG:-}"
KEEP="${TOCKMOX_KEEP_CLUSTER:-0}"
CREATED=0
P09_STARTED=0
# Why the lane itself stopped, before or around run.sh. run.sh writes its own report for P04, P05 and P09; a stop
# here would leave the workflow's report upload with nothing to send, so finish() writes one line in its place.
STOPPED=""
refuse() { STOPPED="REFUSING: $1"; echo "$STOPPED" >&2; exit 2; }
fail() { STOPPED="lane: $1"; echo "$STOPPED" >&2; exit 1; }
# shellcheck disable=SC2329  # invoked by the EXIT trap below
finish() {
  local rc=$?
  # The off-site directory holds the token (git-credentials); it does not outlive the job.
  [ -z "${OFFDIR:-}" ] || rm -rf "$OFFDIR"
  if [ -n "$STOPPED" ]; then
    printf 'p09 lane (%s): exit %s\n%s\n' "${TOCKMOX_DOCS_REF}" "$rc" "$STOPPED" \
      >"${TOCKMOX_WORKDIR}/report-p09-lane-$(date -u +%Y%m%dT%H%M%SZ).txt" || true
  fi
  # KEEP keeps an install. A lane that stopped before P09 began has none: there is nothing on the
  # VM to inspect, rebuild or drill, and left standing it holds the rig against the next create for
  # as long as its keep-until says (four such VMs on 2026-11-10, each destroyed by hand).
  # TOCKMOX_KEEP_ON_PREP_FAILURE=1 keeps it anyway, for looking at a preparation step itself.
  if [ "$CREATED" = 1 ] && [ "$KEEP" = 1 ] && [ "$P09_STARTED" != 1 ] && [ "$rc" != 0 ] \
     && [ "${TOCKMOX_KEEP_ON_PREP_FAILURE:-0}" != 1 ]; then
    echo "lane: stopped before P09 began, so there is no install to keep; destroying ${TOCKMOX_TEST_VM} (TOCKMOX_KEEP_ON_PREP_FAILURE=1 keeps it)"
    KEEP=0
  fi
  if [ "$CREATED" = 1 ] && [ "$KEEP" != 1 ]; then
    echo "lane: destroying ${TOCKMOX_TEST_VM}"
    KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" destroy || rc=1
  elif [ "$CREATED" = 1 ]; then
    echo "lane: TOCKMOX_KEEP_CLUSTER=1, so ${TOCKMOX_TEST_VM} stays up; destroy it with throwaway-cluster.sh destroy"
  fi
  exit "$rc"
}
trap finish EXIT

ROUTE="${TOCKMOX_P09_ROUTE:-built-in}"
[ "$ROUTE" = built-in ] || [ "$ROUTE" = external ] || refuse "TOCKMOX_P09_ROUTE must be built-in or external, not: ${ROUTE}"
# Every missing tool at once, so one install on the runner clears the check.
missing=""
for t in kubectl helm kubeseal openssl git python3 zsh curl tar age age-keygen; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
done
[ -z "$missing" ] || refuse "not on PATH:${missing}; P09's ${ROUTE} route runs them"

# The off-site copy's preconditions, before anything is created.
OFFSITE="${TOCKMOX_P09_OFFSITE:-none}"
OFFDIR=""
OFFSITE_CA=no-ca
case "$OFFSITE" in
  none) ;;
  git)
    [ "$ROUTE" = built-in ] || refuse "TOCKMOX_P09_OFFSITE=git needs TOCKMOX_P09_ROUTE=built-in: the off-site copy is bootstrap-forge's, and only that route runs it"
    OFFSITE_CA="$(bash "${PROV}/throwaway-cluster.sh" offsite-check)" \
      || refuse "TOCKMOX_P09_OFFSITE=git, and the off-site settings cannot be read or used (the provisioner's lines above say which)"
    if [ "$OFFSITE_CA" = ca ] && ! grep -e '--offsite-git-ca)' "${TREE}/install/bootstrap-forge.sh" >/dev/null 2>&1; then
      refuse "TOCKMOX_P09_OFFSITE=git: the off-site forge is on a private CA (key ca.crt), and this tree's bootstrap-forge has no --offsite-git-ca to trust it with. Run a ref that has it."
    fi ;;
  *) refuse "TOCKMOX_P09_OFFSITE must be none or git, not: ${OFFSITE}" ;;
esac

# 1. the throwaway
echo "lane 1: creating ${TOCKMOX_TEST_VM} on ${TOCKMOX_SUBSTRATE_CONTEXT}"
out="$(bash "${PROV}/throwaway-cluster.sh" create)" || fail "create failed"
CREATED=1
KC="$(printf '%s\n' "$out" | tail -1)"
[ -s "$KC" ] || fail "create printed no kubeconfig path"
# ctx-exempt-next: reads the context NAME out of the kubeconfig file create just wrote; reaches no cluster
KUBE_CONTEXT="$(KUBECONFIG="$KC" kubectl config current-context)"
: "${KUBE_CONTEXT:?the guest kubeconfig names no context}"
export TOCKMOX_EXISTING_KUBECONFIG="$KC" KUBE_CONTEXT
export TOCKMOX_SUBSTRATE_KUBECONFIG="$SUBSTRATE_KUBECONFIG"
export KUBECONFIG="$KC"
echo "lane 1: cluster under test ${KUBE_CONTEXT}"
if [ "$OFFSITE" = git ]; then
  OFFDIR="${LANE}/offsite"
  KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" offsite-repo "$OFFDIR" >/dev/null \
    || fail "the off-site repository for ${TOCKMOX_TEST_VM} could not be created"
  reach=0
  KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" offsite-reach "$OFFDIR" || reach=$?
  case "$reach" in
    0) echo "lane 1: off-site repository ready, and the guest reaches its forge" ;;
    3) echo "lane 1: off-site repository ready; whether the guest reaches its forge was not checked (above), and P09's first off-site copy will show it" ;;
    *) fail "the guest does not reach the off-site forge, so its copy job would not either" ;;
  esac
fi

# 2. what install.md starts from: fresh-install.md 6 and 7
echo "lane 2: P04 + P05 (ArgoCD, sealed-secrets)"
bash "${HERE}/run.sh" P04 P05 || fail "P04/P05 failed, so P09 would start from the wrong state"

# ArgoCD exists now. The off-site forge's CA goes into its trust store under the forge's host name: the
# guest's ArgoCD does not otherwise trust a private CA, and the steps run later against a kept throwaway
# (the rebuild among them) have it read that forge.
if [ "$OFFSITE" = git ] && [ -s "${OFFDIR}/ca.crt" ]; then
  python3 -c 'import json,sys; print(json.dumps({"data": {open(sys.argv[1]).read().strip(): open(sys.argv[2]).read()}}))' \
    "${OFFDIR}/host" "${OFFDIR}/ca.crt" > "${OFFDIR}/tls-patch.json"
  kubectl --context="$KUBE_CONTEXT" -n argocd patch configmap argocd-tls-certs-cm --type merge \
    --patch-file "${OFFDIR}/tls-patch.json" >/dev/null \
    || fail "could not add the off-site forge's CA to argocd/argocd-tls-certs-cm on the throwaway"
  echo "lane 2: the off-site forge's CA is in ArgoCD's argocd-tls-certs-cm"
fi

# 3. this tree, served from inside the throwaway
TAG="lane-${TOCKMOX_TEST_VM}"
bash "${PROV}/site-repo-server.sh" up >/dev/null
bash "${PROV}/site-repo-server.sh" push "$TREE" tockmox "$TAG" >/dev/null
TM_URL="$(bash "${PROV}/site-repo-server.sh" url tockmox)"
[ -n "$TM_URL" ] || fail "site-repo-server gave no URL"
echo "lane 3: this tree served at ${TM_URL} @ ${TAG}"

# 4. P09
NODE_IP="$(kubectl --context="$KUBE_CONTEXT" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
[ -n "$NODE_IP" ] || fail "the throwaway reports no node InternalIP"
export TOCKMOX_P09_ROUTE="$ROUTE" TOCKMOX_P09_FROM_TREE=1
export TOCKMOX_P09_TOCKMOX_REPO_URL="$TM_URL" TOCKMOX_P09_TOCKMOX_REVISION="$TAG" TOCKMOX_P09_TOCKMOX_CLONE="$TREE"
export TOCKMOX_P09_STATE="${LANE}/p09-state" TOCKMOX_P09_BUDGET="${TOCKMOX_P09_BUDGET:-3000}"
export TOCKMOX_P09_LAN_CIDR="${TOCKMOX_P09_LAN_CIDR:-${NODE_IP%.*}.0/24}"
export TOCKMOX_P09_POOL="${TOCKMOX_P09_POOL:-${NODE_IP%.*}.240-${NODE_IP%.*}.250}"
if [ "$OFFSITE" = git ]; then
  TOCKMOX_P09_OFFSITE_GIT_URL="$(cat "${OFFDIR}/git-url")"
  TOCKMOX_P09_OFFSITE_SCRUB="$(cat "${OFFDIR}/host")"
  export TOCKMOX_P09_OFFSITE_GIT_URL TOCKMOX_P09_OFFSITE_SCRUB TOCKMOX_P09_OFFSITE_GIT_CREDENTIALS="${OFFDIR}/git-credentials"
  [ ! -s "${OFFDIR}/ca.crt" ] || export TOCKMOX_P09_OFFSITE_GIT_CA="${OFFDIR}/ca.crt"
fi
echo "lane 4: P09, ${ROUTE} route (LAN ${TOCKMOX_P09_LAN_CIDR}, pool ${TOCKMOX_P09_POOL}, off-site copy ${OFFSITE})"
P09_STARTED=1
set +e
bash "${HERE}/run.sh" P09
rc=$?
set -e
echo "lane: P09 exit ${rc}"
P09_RC="$rc"

# 5. the recovery kit of a kept throwaway. P09's S14f (built-in route only) wrote the kit under this
# job's HOME and made the identity that opens it under P09's state; neither is anywhere else. A P09 that
# failed after S14f still leaves a kit worth keeping, so this does not look at rc.
if [ "$KEEP" = 1 ] && [ "$ROUTE" = built-in ]; then
  KIT="${HOME}/tockmox-backup/tockmox-recovery-kit.tar.age"
  KIT_ID="${TOCKMOX_P09_STATE}/p09-age-identity.txt"
  if [ ! -s "$KIT" ] || [ ! -s "$KIT_ID" ]; then
    echo "lane 5: P09 did not get as far as a recovery kit (S14f), so there is none to keep"
  elif [ "$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$KIT")" -lt "$LANE_T0" ]; then
    echo "lane 5: ${KIT} is older than this run, so it is an earlier run's kit and is not kept"
  elif KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" kit-store "$KIT" "$KIT_ID"; then
    echo "lane 5: recovery kit kept as ${TOCKMOX_TEST_VM}-kit; fetch it with throwaway-cluster.sh kit DIR"
  elif [ "$rc" = 0 ]; then
    STOPPED="lane: P09 passed, but its recovery kit could not be kept as ${TOCKMOX_TEST_VM}-kit (kit-store's own lines are in the job log). The VM stays up; without the kit it cannot be rebuilt or drilled."
    echo "$STOPPED" >&2
    rc=1
  else
    echo "lane 5: the recovery kit could not be kept as ${TOCKMOX_TEST_VM}-kit; the exit stays P09's" >&2
  fi
fi
# 6. P10, on the same throwaway and the same state directory, only when P09 passed. p09-passed is the marker P10
# requires: without it P10 declares BLOCKED, so a stale or foreign state directory is never read as an install.
# The kit above is kept first, so a P10 that outlives the job's time limit does not lose it.
if [ "$P09_RC" = 0 ]; then
  mkdir -p "$TOCKMOX_P09_STATE"
  : > "${TOCKMOX_P09_STATE}/p09-passed"
  export TOCKMOX_P10_BUDGET="${TOCKMOX_P10_BUDGET:-5400}"
  echo "lane 6: P10, after a P09 that passed (budget ${TOCKMOX_P10_BUDGET}s)"
  set +e
  bash "${HERE}/run.sh" P10
  p10_rc=$?
  set -e
  echo "lane: P10 exit ${p10_rc}"
  # a P10 failure becomes the lane's exit when nothing earlier (P09, the kit) already failed it
  if [ "$p10_rc" != 0 ] && [ "$rc" = 0 ]; then
    rc="$p10_rc"
  fi
else
  echo "lane 6: P09 did not pass, so P10 does not run"
fi
exit "$rc"

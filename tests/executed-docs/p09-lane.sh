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
#   6. destroy it, unless TOCKMOX_KEEP_CLUSTER=1
#
# It is what the executed-docs workflow runs on a dispatch with lane=p09, and it runs the same from a
# workstation whose credential the harness accepts (a tockmox-test ServiceAccount token, on a network the
# guest can call back from). Inputs: TOCKMOX_DOCS_REF, TOCKMOX_SUBSTRATE_CONTEXT, TOCKMOX_TEST_NAMESPACE,
# TOCKMOX_TEST_VM, TOCKMOX_P09_ROUTE (default built-in); optional TOCKMOX_KEEP_CLUSTER, TOCKMOX_P09_BUDGET,
# TOCKMOX_P09_LAN_CIDR and TOCKMOX_P09_POOL (default: the node's /24 and .240-.250 in it).
# Exit: P09's own exit status; 2 for a refused precondition; 1 when a preparation step fails, or when P09
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
# Why the lane itself stopped, before or around run.sh. run.sh writes its own report for P04, P05 and P09; a stop
# here would leave the workflow's report upload with nothing to send, so finish() writes one line in its place.
STOPPED=""
refuse() { STOPPED="REFUSING: $1"; echo "$STOPPED" >&2; exit 2; }
fail() { STOPPED="lane: $1"; echo "$STOPPED" >&2; exit 1; }
# shellcheck disable=SC2329  # invoked by the EXIT trap below
finish() {
  local rc=$?
  if [ -n "$STOPPED" ]; then
    printf 'p09 lane (%s): exit %s\n%s\n' "${TOCKMOX_DOCS_REF}" "$rc" "$STOPPED" \
      >"${TOCKMOX_WORKDIR}/report-p09-lane-$(date -u +%Y%m%dT%H%M%SZ).txt" || true
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

# 2. what install.md starts from: fresh-install.md 6 and 7
echo "lane 2: P04 + P05 (ArgoCD, sealed-secrets)"
bash "${HERE}/run.sh" P04 P05 || fail "P04/P05 failed, so P09 would start from the wrong state"

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
echo "lane 4: P09, ${ROUTE} route (LAN ${TOCKMOX_P09_LAN_CIDR}, pool ${TOCKMOX_P09_POOL})"
set +e
bash "${HERE}/run.sh" P09
rc=$?
set -e
echo "lane: P09 exit ${rc}"

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
exit "$rc"

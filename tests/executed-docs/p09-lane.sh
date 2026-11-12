#!/usr/bin/env bash
# The install.md lane: P09 end to end on ONE throwaway that already carries what install.md starts from.
#
# P09 cannot run inside a bare run.sh. It needs ArgoCD and sealed-secrets on the cluster it installs into
# (fresh-install.md 6 and 7), but run.sh gives every install route its own cluster, and P04 (ArgoCD) and
# P05 (sealed-secrets) are different routes. It also needs a git remote that the cluster can clone the
# product tree from. This script provides both on one throwaway:
#   1. create the throwaway (throwaway-cluster.sh create; its capacity gate refuses first if it does not fit)
#   2. run.sh P04 P05 against it (TOCKMOX_EXISTING_KUBECONFIG), the state install.md starts from
#   3. serve this tree from inside it (site-repo-server.sh), so the Applications read THIS tree. On the
#      external route also the site repository's remote (see "THE EXTERNAL ROUTE'S REMOTE" below)
#   4. run.sh P09 against it, the route TOCKMOX_P09_ROUTE names (built-in or external), its blocks read from
#      this tree's install.md (TOCKMOX_P09_FROM_TREE=1)
#   5. on a kept built-in run, keep P09's recovery kit and the age identity that opens it as the Secret
#      ${TOCKMOX_TEST_VM}-kit beside the VM (throwaway-cluster.sh kit-store), because both otherwise end
#      with this job; `throwaway-cluster.sh kit DIR` fetches them, and destroy removes them with the VM
#   6. when P09 passed, run P11 on the same throwaway and the same state directory (a backup and a restore
#      drill of each database, and the migrations Job; paths/P11-fresh-install-recovery.sh). P11 has its own
#      budget, TOCKMOX_P11_BUDGET (default 5400 seconds), a yield point this lane does not call again, so a
#      P11 that yields is a failed lane. P11 does not run when P09 failed, and its result is the lane's only
#      when P09 passed
#   7. destroy it, unless TOCKMOX_KEEP_CLUSTER=1. A kept run that stopped before step 4 began is destroyed all the
#      same (there is no install to keep), unless TOCKMOX_KEEP_ON_PREP_FAILURE=1
#
# THE EXTERNAL ROUTE'S REMOTE. P09's external route needs TOCKMOX_P09_SITE_REPO_URL, a git remote the
# workstation can push to and the cluster can clone at ONE URL, and without it P09 declares BLOCKED. Unless the
# caller already set that variable (their own forge: it is used as given, and nothing below runs), step 3 builds
# it, with four things that all have to hold:
#   a. throwaway-cluster.sh publish git PORT: a NodePort Service ${TOCKMOX_TEST_VM}-git on the hypervisor,
#      selecting the VM and forwarding to the guest's PORT (site-repo-server.sh nodeport). The runner reaches
#      the hypervisor's nodes and the guest is masqueraded (NAT out, nothing in), so this is the only way in.
#      It also leaves the voucher that a disposable namespace passed throwaway-cluster.sh's refusal.
#   b. site-repo-server.sh up --writable: inside the guest, git daemon with receive-pack, site.git and
#      tockmox.git pre-created, on that PORT. It refuses without the voucher from a. An unauthenticated writable
#      daemon on a NodePort is acceptable ONLY because the VM is a throwaway in an isolated lab.
#   c. the runner pushes to it (a dry run, here) and reads it, at git://host:nodePort/site.git;
#   d. a pod in the guest reads the same URL (site-repo-server.sh reach): the guest reaching its own published
#      address, by hairpin. P09 and the Applications use that one URL for the push, the placeholder and the clone.
# A failure of any of them ends the lane with 5 (INFRA_ERROR) and a line that names it; none is ever a pass.
# The product tree is served by the same daemon at the in-cluster address, as on the built-in route.
#
# A SUPPLIED CA, P12 (paths/P12-bring-your-own-ca.sh). After P11, and only when P09 passed, run the blocks of
# docs/administration/bring-your-own-ca.md on the same throwaway and state directory. It replaces the install's CA
# and makes the consoles re-issue their certificates. TOCKMOX_P09_BYO_CA picks whether it runs:
#   auto (the default, also unset or empty)  run it when the route is external AND the run is not kept
#        (TOCKMOX_KEEP_CLUSTER is 0 or unset); otherwise skip it with one logged line that says why
#   1    run it. Refused up front on the built-in route, before anything is created
#   0    never run it
#   anything else is refused.
# The reasoning: a throwaway that is destroyed at the end can be mutated freely, a kept one cannot (a kept
# install is left as the reader expects it, on the chart's CA). The external route is needed because the page's
# commit is pushed to the site repository's remote, and on the built-in forge main takes pull requests only, which
# a harness cannot approve. P12 has its own budget, TOCKMOX_P12_BUDGET (default 5400 seconds), a yield point this
# lane does not call again. A P12 failure becomes the lane's exit only when nothing earlier (P09, the kit, P11)
# already failed it.
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
# Exit: P09's own exit status, or P11's when P09 passed and P11 did not; 2 for a refused precondition; 5 when the external route's
# remote could not be provided (INFRA_ERROR); 1 when another preparation step fails, or when P09
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
# infra REASON ... what the lane could not provide is the environment's fault, not the product's and not a pass: exit 5,
# the status lane_code gives INFRA_ERROR below.
infra() { STOPPED="lane: INFRA_ERROR: $1"; echo "$STOPPED" >&2; exit 5; }
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

# A supplied CA (P12): decided here, before anything is created, so a refusal costs nothing.
BYO_CA="${TOCKMOX_P09_BYO_CA:-auto}"
BYO_RUN=0
BYO_WHY=""
case "$BYO_CA" in
  0) BYO_WHY="TOCKMOX_P09_BYO_CA=0" ;;
  1) [ "$ROUTE" = external ] || refuse "TOCKMOX_P09_BYO_CA=1 needs TOCKMOX_P09_ROUTE=external: P12 pushes the page's commit to the site repository's remote, and the built-in forge takes pull requests only"
     BYO_RUN=1 ;;
  auto)
    if [ "$ROUTE" != external ]; then
      BYO_WHY="built-in route: the page's commit cannot be delivered, because the forge's main takes pull requests only"
    elif [ "$KEEP" = 1 ]; then
      BYO_WHY="kept run: P12 replaces the install's CA and a kept install is left as the reader expects it"
    else
      BYO_RUN=1
    fi ;;
  *) refuse "TOCKMOX_P09_BYO_CA must be auto, 1 or 0, not: ${BYO_CA}" ;;
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

# 3. this tree, served from inside the throwaway; on the external route the site repository's remote beside it
TAG="lane-${TOCKMOX_TEST_VM}"
# with_timeout CMD... ... a NodePort that nothing answers on hangs a git call for minutes
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"; else "$@"; fi; }
# runner_git_check URL ... the workstation side of the one URL: it reads URL, and a push to it is accepted
# (a dry run: the daemon's receive-pack answers, nothing is stored)
runner_git_check() {
  local w rc
  w="$(mktemp -d "${LANE}/probe.XXXXXX")" || return 1
  ( cd "$w" && git init -q . \
      && git -c user.name=lane -c user.email=lane@example.invalid commit -q --allow-empty -m probe \
      && GIT_TERMINAL_PROMPT=0 with_timeout git ls-remote "$1" >/dev/null \
      && GIT_TERMINAL_PROMPT=0 with_timeout git push --dry-run "$1" HEAD:refs/heads/lane-probe >/dev/null 2>&1 )
  rc=$?
  rm -rf "$w"
  return "$rc"
}
EXT_REMOTE=0
if [ "$ROUTE" = external ]; then
  if [ -n "${TOCKMOX_P09_SITE_REPO_URL:-}" ]; then
    echo "lane 3: TOCKMOX_P09_SITE_REPO_URL is set by the caller, so the site remote is theirs and none is provided here"
  else
    EXT_REMOTE=1
  fi
fi
if [ "$EXT_REMOTE" = 1 ]; then
  GIT_NP="$(bash "${PROV}/site-repo-server.sh" nodeport)" \
    || infra "site-repo-server.sh nodeport gave no port for the git daemon, so the site remote cannot be published"
  pub="$(KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" publish git "$GIT_NP")" \
    || infra "throwaway-cluster.sh publish git ${GIT_NP} failed, so the workstation has no way to push the site repository"
  PUB_HP="$(printf '%s\n' "$pub" | tail -1)"
  case "$PUB_HP" in
    ?*:[0-9]*) ;;
    *) infra "throwaway-cluster.sh publish printed no host:port (got '${PUB_HP}')" ;;
  esac
  TOCKMOX_WRITABLE_GUARD="$(KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" guard-file)" \
    || infra "throwaway-cluster.sh guard-file gave no path"
  export TOCKMOX_WRITABLE_GUARD
  bash "${PROV}/site-repo-server.sh" up --writable >/dev/null \
    || infra "site-repo-server.sh up --writable failed, so there is no daemon the workstation can push the site repository to"
else
  bash "${PROV}/site-repo-server.sh" up >/dev/null
fi
bash "${PROV}/site-repo-server.sh" push "$TREE" tockmox "$TAG" >/dev/null
TM_URL="$(bash "${PROV}/site-repo-server.sh" url tockmox)"
[ -n "$TM_URL" ] || fail "site-repo-server gave no URL"
echo "lane 3: this tree served at ${TM_URL} @ ${TAG}"
if [ "$EXT_REMOTE" = 1 ]; then
  SITE_URL="git://${PUB_HP}/site.git"
  runner_git_check "$SITE_URL" \
    || infra "the workstation cannot read and push to ${SITE_URL} (NodePort ${PUB_HP##*:} not reachable from here, or the daemon refuses receive-pack)"
  bash "${PROV}/site-repo-server.sh" reach "$SITE_URL" >/dev/null \
    || infra "the guest cannot read its own published address ${SITE_URL}; one URL cannot serve the workstation and the cluster (the hairpin does not hold)"
  export TOCKMOX_P09_SITE_REPO_URL="$SITE_URL"
  echo "lane 3: site remote ${SITE_URL}: the workstation pushes to it and the guest reads it, at that one URL"
fi

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
# 6. P11, on the same throwaway and the same state directory, only when P09 passed. p09-passed is the marker P11
# requires: without it P11 declares BLOCKED, so a stale or foreign state directory is never read as an install.
# The kit above is kept first, so a P11 that outlives the job's time limit does not lose it.
#
# THE OUTCOME A PATH DECLARED, NOT ITS EXIT STATUS. run.sh exits 0 for a path that declared BLOCKED (right in a full
# run, where a missing precondition is a declared constraint). Here the lane itself decided to run the path, so
# anything but PASS fails the lane. The receipt is the file lib/assert.sh's path_outcome writes, named for the path,
# in the receipts-STAMP directory run.sh makes under TOCKMOX_WORKDIR; the newest such directory is the run that just
# ended, and a path's receipt only ever exists in its own run's directory, so a run that left none reads as missing.
# lane_receipt NAME prints "OUTCOME reason" ("MISSING ..." when there is no receipt).
lane_receipt() {
  local d f g outcome reason
  d=""
  for g in "${TOCKMOX_WORKDIR}"/receipts-*; do [ -d "$g" ] && d="$g"; done   # the glob sorts: the last is the newest
  f="${d:+${d}/$1}"
  if [ -n "$f" ] && [ -s "$f" ]; then
    read -r outcome reason < "$f" || true
    printf '%s %s' "${outcome:-MISSING}" "${reason:-}"
  else
    printf 'MISSING no receipt for %s in the newest run' "$1"
  fi
}
# lane_code OUTCOME ... the lane's status for an outcome that is not PASS: 4 BLOCKED, 5 INFRA_ERROR, 1 anything else
lane_code() { case "$1" in BLOCKED) echo 4 ;; INFRA_ERROR) echo 5 ;; *) echo 1 ;; esac; }
# lane_judge NAME RECEIPT ... one line naming the path, its outcome and its reason; the status to fail with, or 0 for PASS
lane_judge() {
  local out="${2%% *}" why="${2#* }"
  if [ "$out" = PASS ]; then echo 0; return 0; fi
  echo "lane: $1 declared ${out}: ${why}" >&2
  lane_code "$out"
}
P09_REC="$(lane_receipt P09-install-md-end-to-end)"
if [ "$P09_RC" = 0 ] && [ "${P09_REC%% *}" = PASS ]; then
  mkdir -p "$TOCKMOX_P09_STATE"
  : > "${TOCKMOX_P09_STATE}/p09-passed"
  export TOCKMOX_P11_BUDGET="${TOCKMOX_P11_BUDGET:-5400}"
  echo "lane 6: P11, after a P09 that passed (budget ${TOCKMOX_P11_BUDGET}s)"
  set +e
  bash "${HERE}/run.sh" P11
  p11_rc=$?
  set -e
  echo "lane: P11 exit ${p11_rc}"
  # a P11 failure becomes the lane's exit when nothing earlier (P09, the kit) already failed it
  if [ "$p11_rc" != 0 ] && [ "$rc" = 0 ]; then
    rc="$p11_rc"
  fi
  # and so does a P11 that exited 0 without declaring PASS (BLOCKED, say): it proved nothing after P09
  p11_code="$(lane_judge P11-fresh-install-recovery "$(lane_receipt P11-fresh-install-recovery)")"
  if [ "$p11_code" != 0 ] && [ "$rc" = 0 ]; then
    rc="$p11_code"
  fi
elif [ "$P09_RC" = 0 ]; then
  echo "lane 6: P09 exited 0 but its receipt says ${P09_REC%% *} (${P09_REC#* }), so p09-passed is not written and P11 does not run" >&2
  p09_code="$(lane_code "${P09_REC%% *}")"
  [ "$rc" != 0 ] || rc="$p09_code"
else
  echo "lane 6: P09 did not pass, so P11 does not run"
fi

# 7. P12, a supplied CA, when BYO_RUN says so and only when P09 passed. It runs after P11 whatever P11 did, and needs
# only p09-passed, which was written above. A P12 that cannot start declares BLOCKED and costs nothing.
if [ "$BYO_RUN" = 1 ] && [ "$P09_RC" = 0 ] && [ "${P09_REC%% *}" = PASS ]; then
  export TOCKMOX_P12_BUDGET="${TOCKMOX_P12_BUDGET:-5400}"
  echo "lane 7: P12, a supplied CA, after a P09 that passed (budget ${TOCKMOX_P12_BUDGET}s)"
  set +e
  bash "${HERE}/run.sh" P12
  p12_rc=$?
  set -e
  echo "lane: P12 exit ${p12_rc}"
  # a P12 failure becomes the lane's exit when nothing earlier already failed it
  if [ "$p12_rc" != 0 ] && [ "$rc" = 0 ]; then
    rc="$p12_rc"
  fi
  # a P12 that exited 0 without declaring PASS fails the lane too: the lane decided to run it
  p12_code="$(lane_judge P12-bring-your-own-ca "$(lane_receipt P12-bring-your-own-ca)")"
  if [ "$p12_code" != 0 ] && [ "$rc" = 0 ]; then
    rc="$p12_code"
  fi
elif [ "$BYO_RUN" = 1 ]; then
  echo "lane 7: P09 did not pass, so P12 does not run"
else
  echo "lane 7: P12 (a supplied CA) skipped: ${BYO_WHY}"
fi

# --- P13 block begin (self-contained apart from P09_REC, lane_receipt and lane_judge above; goes after the P11 block) ---
# 8. P13, last, on the same throwaway and the same state directory, only when P09 exited 0 AND its receipt says PASS.
# It plants one fault at a time (a ResourceQuota that refuses a restore drill; a drill that cannot write its register
# row) and breaks the install on purpose, so it runs after everything that reads the install healthy, and it takes each
# fault out again and reads that it is gone (paths/P13-planted-faults.sh). It does NOT wait on P11: they are independent
# proofs of one install, and a P11 that failed (or was BLOCKED) leaves the install exactly as P13 needs it; the lane's
# exit keeps the FIRST failure. It has its own budget, TOCKMOX_P13_BUDGET (default 3000 seconds), a yield point this
# lane does not call again, so a P13 that yields is a failed lane. The p09-passed marker is rewritten here only because
# P09's receipt said PASS, so this block never depends on a marker a failed P09 left.
# Like P11, anything but a PASS receipt fails the lane (4 BLOCKED, 5 INFRA_ERROR, 1 otherwise or none), with one line
# naming the path, the outcome and the reason, and never replaces an earlier failure's status.
if [ "$P09_RC" = 0 ] && [ "${P09_REC%% *}" = PASS ]; then
  mkdir -p "$TOCKMOX_P09_STATE"
  : > "${TOCKMOX_P09_STATE}/p09-passed"
  export TOCKMOX_P13_BUDGET="${TOCKMOX_P13_BUDGET:-3000}"
  echo "lane 8: P13, planted faults, after a P09 that passed (budget ${TOCKMOX_P13_BUDGET}s)"
  set +e
  bash "${HERE}/run.sh" P13
  p13_rc=$?
  set -e
  echo "lane: P13 exit ${p13_rc}"
  if [ "$p13_rc" != 0 ] && [ "$rc" = 0 ]; then
    rc="$p13_rc"
  fi
  # and so does a P13 that exited 0 without declaring PASS (BLOCKED, say): it proved nothing
  p13_code="$(lane_judge P13-planted-faults "$(lane_receipt P13-planted-faults)")"
  if [ "$p13_code" != 0 ] && [ "$rc" = 0 ]; then
    rc="$p13_code"
  fi
else
  echo "lane 8: P09 did not pass, so P13 does not run"
fi
# --- P13 block end ------------------------------------------------------------------------------------------------
exit "$rc"

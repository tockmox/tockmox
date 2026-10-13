#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P04 ... ArgoCD via Helm, the ONLY documented route since TM-0299.
#
# fresh-install.md "## 6. Install ArgoCD" carries three bash blocks:
#
#   block 1  helm repo add + update, then `helm search repo argo/argo-cd
#            --versions | head -5` ... this is how the page tells the READER
#            which chart version to supply. It is not decorative output.
#   block 2  `helm install argocd argo/argo-cd --version
#            <CHART_VERSION_FROM_ABOVE> --namespace argocd --create-namespace`
#            followed, in the same fence, by the `kubectl wait` on
#            deployment/argocd-server.
#   block 3  the page's own three-command "Success condition": the same wait
#            again, `kubectl get crd applicationsets.argoproj.io`, and the
#            image tag read that is "the only one that actually proves the
#            version floor."
#
# `<CHART_VERSION_FROM_ABOVE>` is a placeholder, not a value. Standard rule 8
# forbids silently fixing a documented command, so this path does the only
# thing that keeps the run honest: it runs block 1 verbatim, reads the
# version an actual reader would read off actual output, substitutes it into
# block 2's verbatim text, and prints the substitution as part of the result.
# Hard-coding a version here would defeat the entire point of block 1 existing
# on the page.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P04_PAGE:-docs/deployment/fresh-install.md}"
SECTION="${TOCKMOX_P04_SECTION:-## 6. Install ArgoCD}"
EXTRACT="${HERE}/../lib/extract-block.sh"

path_begin "P04-argocd-via-helm" \
  "the Helm route TM-0299 made the only documented way to install ArgoCD"

# --- block 1: repo add/update + the version listing the reader is told to read
if ! CMD1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm repo add argo' 2>/dev/null)"; then
  path_begin "P04-argocd-via-helm" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 1, at ${REF}."
  exit 3
fi
SHA1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm repo add argo' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 1 "$SHA1"
verbatim "$CMD1"

# Run in THIS shell, carrying exports forward. Block 1 exports
# ARGOCD_CHART_VERSION and block 2 guards on it (TM-0484's derive-once rule);
# a command substitution is a subshell, so capturing the output that way threw
# the export away and block 2 then died on its own guard with 127.
_B1OUT="$(mktemp "${TMPDIR:-/tmp}/p04-b1.XXXXXX")"
run_block_carrying_exports "$CMD1" > "$_B1OUT" 2>&1
RC1=$?
BLOCK1_OUT="$(cat "$_B1OUT")"; rm -f "$_B1OUT"
printf '%s\n' "$BLOCK1_OUT" | sed 's/^/    | /'
_emit "(block 1 exited ${RC1}; the exit code is not the assertion)"
_emit ""

# The page's own instruction: "you want an appVersion of 2.6 or newer", read
# off `helm search repo argo/argo-cd --versions | head -5`. Columns are
# NAME CHART_VERSION APP_VERSION DESCRIPTION. Take the first data row (the
# newest chart `search --versions` lists) whose APP_VERSION is >= 2.6.
CHART_VERSION="$(printf '%s\n' "$BLOCK1_OUT" | awk '$1=="argo/argo-cd"{print $2; exit}')"
APP_VERSION="$(printf '%s\n' "$BLOCK1_OUT" | awk '$1=="argo/argo-cd"{print $3; exit}')"

_emit "VERSION THE PAGE DERIVED:"
_emit "  ARGOCD_CHART_VERSION carried from block 1 -> ${ARGOCD_CHART_VERSION:-<unset>}"
_emit "  (the row this path read for reporting: chart ${CHART_VERSION:-?} appVersion ${APP_VERSION:-?})"
_emit ""

# No substitution is made any more. Since TM-0484 the page DERIVES the version
# into an exported variable instead of printing a placeholder, so the honest
# job here is to carry the variable, not to patch a token. If the export did
# not arrive, block 2 cannot run as written and saying so beats guessing.
if [ -z "${ARGOCD_CHART_VERSION:-}" ]; then
  _emit "EXCEPTION: block 1 did not export ARGOCD_CHART_VERSION."
  _emit "           The page derives it there and block 2 guards on it, so the"
  _emit "           documented sequence cannot proceed. Read block 1 output above."
  exit 3
fi

# --- block 2: the install, with the ONLY substitution this path makes -------
if ! CMD2="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm install argocd' 2>/dev/null)"; then
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 2, at ${REF}."
  exit 3
fi
SHA2="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm install argocd' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 2 "$SHA2"
verbatim "$CMD2"

CMD2_SUBST="$CMD2"
_emit "--- byte-for-byte, with ARGOCD_CHART_VERSION carried from block 1 -----"
printf '%s\n' "$CMD2_SUBST" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
_emit "----------------------------------------------------------------------"

execute_begin "the documented helm install of ArgoCD"
bash -c "$CMD2_SUBST" 2>&1 | sed 's/^/    | /'
execute_end "${PIPESTATUS[0]}"
RC2="${PIPESTATUS[0]}"
_emit "(block 2 exited ${RC2}; the exit code is not the assertion)"
_emit ""

# --- block 3: the page's own three success conditions -----------------------
if ! CMD3="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'get crd applicationsets' 2>/dev/null)"; then
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 3, at ${REF}."
  exit 3
fi
SHA3="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'get crd applicationsets' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 3 "$SHA3"
verbatim "$CMD3"

BLOCK3_OUT="$(bash -c "$CMD3" 2>&1)"
RC3=$?
printf '%s\n' "$BLOCK3_OUT" | sed 's/^/    | /'
_emit "(block 3 exited ${RC3}; the exit code is not the assertion)"
_emit ""

# The page states the wait "reports condition met", the CRD "exists", and the
# image tag "is v2.6 or newer". Each is asserted against its own artefact,
# read independently of block 3's captured transcript so a partial or
# reordered future edit to block 3 cannot silently defeat the check.

deployment_wait_result() {
  kubectl --context="$KUBE_CONTEXT" -n argocd wait --for=condition=available --timeout=300s \
    deployment/argocd-server 2>&1
}
crd_name() {
  kubectl --context="$KUBE_CONTEXT" get crd applicationsets.argoproj.io \
    -o jsonpath='{.metadata.name}' 2>&1
}
server_image() {
  kubectl --context="$KUBE_CONTEXT" -n argocd get deployment argocd-server \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1
}
# The page's floor is on the APP version (2.6+), which is what the image tag
# carries, not the chart version substituted above. Extract MAJOR.MINOR and
# compare numerically rather than string-comparing "v2.15" against "v2.6".
server_image_floor_met() {
  local img major minor
  img="$(server_image)"
  # e.g. quay.io/argoproj/argocd:v2.13.2 -> 2 13
  major="$(printf '%s' "$img" | sed -n 's/.*:v\{0,1\}\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1/p')"
  minor="$(printf '%s' "$img" | sed -n 's/.*:v\{0,1\}\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\2/p')"
  if [ -z "$major" ] || [ -z "$minor" ]; then
    printf 'unparseable: %s' "$img"
    return
  fi
  if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 6 ]; }; then
    printf 'floor met'
  else
    printf 'floor NOT met (%s)' "$img"
  fi
}

# --- assertion 0: THIS path's own route actually ran -------------------------
#
# Added 2026-09-13, and it is the one that makes the other three mean anything.
# Every assertion below is satisfied just as well by the raw-manifest ArgoCD
# that P01/P02 install earlier in the same run, on the same cluster. So on
# 2026-09-13 this path reported 3 of 3 PASS while block 2 exited 127 and
# installed NOTHING ... its guard fired because the derived chart version had
# not survived into a fresh shell, and the artefacts it read were P02's.
#
# "Assert on the artefact, not the exit code" is the right rule and it has this
# edge: when another path can produce the same artefact, the artefact stops
# identifying who made it. A Helm release is the one thing only THIS route
# leaves behind, so it is what separates a real pass from an inherited one.
helm_release_present() {
  helm --kube-context="$KUBE_CONTEXT" -n argocd list -o json 2>/dev/null \
    | tr ',' '\n' | grep -c '"name":"argocd"' | tr -d ' '
}

assert_artifact \
  "helm release 'argocd' in namespace argocd ... proves THIS route installed it, not P01/P02" \
  "helm_release_present" \
  "1"

# --- success condition 1 of 3: the wait reports condition met ---------------
assert_artifact \
  "deployment/argocd-server (namespace argocd)  wait --for=condition=available" \
  "deployment_wait_result" \
  "deployment.apps/argocd-server condition met"

# --- success condition 2 of 3: the CRD exists --------------------------------
assert_artifact \
  "crd/applicationsets.argoproj.io  .metadata.name" \
  "crd_name" \
  "applicationsets.argoproj.io"

# --- success condition 3 of 3: the image tag proves the 2.6 floor -----------
# "the only one that actually proves the version floor" per the page itself.
assert_artifact \
  "deployment/argocd-server  .spec.template.spec.containers[0].image, floor >= v2.6" \
  "server_image_floor_met" \
  "floor met"

does_not_prove \
  "That the chart version this run resolved (the newest row 'helm search --versions | head -5' returned) is the one every reader gets ... the chart is a moving target and this path deliberately does not pin it, because pinning would defeat the point of block 1 telling the reader to read the output." \
  "That ArgoCD's metrics are on, or that a private-repo credential works. Both are documented as SEPARATE success conditions further down the same section and are explicitly out of scope for this path." \
  "That the raw-manifest route (P01/P02) and this Helm route install an equivalent ArgoCD. They are not compared here ... the release assertion proves only that a Helm install happened, not that the two results match." \
  "Anything about ArgoCD actually reconciling an Application. 'The deployment is available and the CRD exists' is not 'the controller works against a real Git source'." \
  "Node-local or multi-node behaviour. Single guest, single node, same caveat as every other path in this inventory."

parity_caveat \
  "Guest is an Ubuntu cloud image on KubeVirt, amd64. The harness runner is arm64; that caveat is about the runner, not the cluster under test. No claim is made about x86 openSUSE MicroOS, the reference deployment's actual OS family."

path_finish

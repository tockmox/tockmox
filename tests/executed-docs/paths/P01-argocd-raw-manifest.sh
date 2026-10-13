#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-raw
#
# PATH P01 ... the raw-manifest ArgoCD install, exactly as the docs give it at
# the ref under test.
#
# WHY THIS PATH EXISTED. docs/testing-standard.md: "Where the docs offer
# alternatives as equal options, each is a path ... the untested one is the one
# a stranger picks, because it is listed first." At v0.6.0-rc1 the raw-manifest
# route WAS listed first in prerequisites.md § "2. ArgoCD, 2.6 or newer", with
# Helm introduced as "Or with Helm". The Helm route was exercised by use; this
# one was not, and it cannot succeed (TM-0288).
#
# WHAT CHANGED, and why this path is now usually an exception. On 2026-09-01
# (f2dd829) prerequisites.md was restructured into a signpost and carries zero
# fenced bash blocks. The ArgoCD material moved to administration/argocd.md,
# where the headings now read "Why Helm is the only documented route" and "If
# you install from the raw manifest anyway" ... and that section shows the
# client-side command's FAILURE OUTPUT in a plain fence while publishing only
# the server-side recovery as a runnable block. So at main there is no
# documented client-side install command to extract, and the honest result is
# an exception rather than a failure. See TM-0422.
#
# This path is still worth keeping, for two reasons. It runs against any ref
# where the route WAS documented (`TOCKMOX_DOCS_REF=24e3a9b` is the last one),
# and it is the producer of the half-applied state P02 is documented to repair
# ... so when P01 is skipped, P02 is testing server-side apply from clean
# rather than the recovery the page describes. P02 says so itself.
#
# EXPECTED RESULT where the route IS documented: XFAIL. A red run is what proves
# the harness is reading a real cluster. A brand-new executed-docs harness whose
# first run is green has told you nothing you can distinguish from a harness
# that asserts nothing.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P01_PAGE:-docs/deployment/prerequisites.md}"
SECTION="${TOCKMOX_P01_SECTION:-## 2. ArgoCD, 2.6 or newer}"
EXTRACT="${HERE}/../lib/extract-block.sh"

path_begin "P01-argocd-raw-manifest" \
  "the first ArgoCD install command a reader meets, run verbatim"

# --- the command, taken from the page rather than retyped -------------------
# A section that is not there is NOT a failure. It means the route is not
# documented at this ref, which is a fact about the docs and is recorded as an
# exception (exit 3) so run.sh counts it as SKIPPED. Exiting 2 here reported a
# page move in the same channel as a cluster defect, and did so unnoticed from
# 2026-09-01 until 2026-09-04 while the suite printed FAILED.
if ! INSTALL_CMD="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'kubectl apply -n argocd' 2>/dev/null)"; then
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section at ${REF}."
  _emit "           The raw-manifest route is not documented at this ref. At main"
  _emit "           it was deliberately retired: argocd.md says Helm is the only"
  _emit "           documented route and shows the client-side command only as"
  _emit "           failure output, never as a runnable block."
  _emit ""
  _emit "           THIS IS NOT EVIDENCE ABOUT THE PRODUCT, in either direction."
  _emit "           It is also not free: P01 is the producer of the half-applied"
  _emit "           state P02 repairs, so on this ref P02 exercises server-side"
  _emit "           apply from a CLEAN cluster rather than the recovery its page"
  _emit "           describes. Read P02's result with that narrower scope."
  _emit ""
  _emit "           To run this path against a ref where the route WAS published:"
  _emit "             TOCKMOX_DOCS_REF=24e3a9b bash \$0"
  _emit "           Or point it at another location with TOCKMOX_P01_PAGE and"
  _emit "           TOCKMOX_P01_SECTION."
  _emit ""
  # Absence here is a RECORDED DECISION, not drift. INVENTORY.md (A1a, TM-0422,
  # 2026-09-04) states that argocd.md documents Helm as the only route and shows
  # the client-side command solely as failure output, never as a runnable block,
  # so a skip at main is a fact about the docs rather than a coverage gap. The
  # route is still exercisable at 24e3a9b, which is also where P02 gets its
  # half-applied precondition. Without this call the runner would report P01 as
  # an UNDECLARED absence and tell a reader to re-point or retire it, which
  # would be a false accusation against a settled decision.
  declare_absence "by design at main (INVENTORY.md A1a, TM-0422); exercise at ref 24e3a9b"
  exit 3
fi
INSTALL_SHA="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'kubectl apply -n argocd' --sha)"
if ! WAIT_CMD="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'wait --for=condition=available' 2>/dev/null)"; then
  _emit "EXCEPTION: '${SECTION}' at ${REF} carries no third bash block."
  _emit "           Assertion 3 is the page's OWN stated success condition, taken"
  _emit "           from that block. Without it this path would be asserting a"
  _emit "           success condition the harness invented, which is the one thing"
  _emit "           it must not do."
  _emit ""
  exit 3
fi
WAIT_SHA="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'wait --for=condition=available' --sha)"

provenance "$REF" "$PAGE" "$SECTION" 1 "$INSTALL_SHA"
verbatim "$INSTALL_CMD"

# Record WHICH upstream the floating `stable` ref resolved to on this run. The
# manifest behind that URL is a moving target, so a result that does not name
# the version it tested is not reproducible.
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
curl -sfL "$MANIFEST_URL" -o "${TMPDIR:-/tmp}/argocd-install.yaml" || true
ARGOCD_VER="$(awk -F'app.kubernetes.io/version: ' '/app.kubernetes.io\/version: /{print $2; exit}' \
  "${TMPDIR:-/tmp}/argocd-install.yaml" 2>/dev/null | tr -d ' ')"
MANIFEST_BYTES="$(wc -c < "${TMPDIR:-/tmp}/argocd-install.yaml" 2>/dev/null | tr -d ' ')"
_emit "UPSTREAM: argo-cd ${ARGOCD_VER:-unknown} via the floating 'stable' ref, ${MANIFEST_BYTES:-?} bytes"
_emit ""

# --- run it verbatim. The exit code is logged and then ignored. -------------
# The whole point of rule 1 is that this number is not the evidence.
set +e
execute_begin "the documented raw-manifest kubectl apply for ArgoCD"
bash -c "$INSTALL_CMD" 2>&1 | sed 's/^/    | /'
INSTALL_RC="${PIPESTATUS[0]}"
execute_end "$INSTALL_RC"
set -e
_emit "(documented command exited ${INSTALL_RC}; the exit code is not the assertion)"
_emit ""

crd_established() {
  kubectl --context="$KUBE_CONTEXT" get crd "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="Established")]}{.status}{end}' 2>&1
}
deploy_available() {
  kubectl --context="$KUBE_CONTEXT" -n argocd get deployment "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>&1
}

# --- assertion 1: the artefact the defect destroys -------------------------
# applicationsets.argoproj.io is the single object in the upstream manifest that
# exceeds the 262144-byte ceiling on the last-applied-configuration annotation
# that client-side `kubectl apply` writes. Measured against argo-cd stable on
# 2026-09-02: 343248 bytes serialised, 81104 over. Every other object in the
# manifest is under the limit, which is precisely why this fails PARTWAY.
assert_artifact_xfail \
  "crd/applicationsets.argoproj.io  .status.conditions[type=Established].status" \
  "crd_established applicationsets.argoproj.io" \
  "True"

# --- assertion 2: the artefact the defect leaves standing ------------------
# This is the assertion that explains why "did the command exit 0?" is the wrong
# question, and why a naive smoke test over this path would have gone green.
# 58 of the 59 objects apply. ArgoCD comes up. It just cannot do ApplicationSets,
# and Tockmox's generated Applications are multi-source, so the failure lands
# later and reads as something else entirely.
assert_artifact \
  "crd/applications.argoproj.io  .status.conditions[type=Established].status" \
  "crd_established applications.argoproj.io" \
  "True"

# --- assertion 3: the page's OWN stated success condition ------------------
# prerequisites.md block 3 tells the reader to wait for this deployment, so this
# is the success condition the page itself publishes. A procedure with no stated
# success condition cannot be tested; this one has one, so it gets asserted.
provenance "$REF" "$PAGE" "$SECTION" 3 "$WAIT_SHA"
verbatim "$WAIT_CMD"
bash -c "$WAIT_CMD" >/dev/null 2>&1 || true
assert_artifact \
  "deployment/argocd-server in ns/argocd  .status.conditions[type=Available].status" \
  "deploy_available argocd-server" \
  "True"

does_not_prove \
  "That the Helm route beside it works. That is P04, a separate path. (This line named P02 until 2026-09-04; P02 is the server-side recovery, not the Helm route.)" \
  "That ArgoCD can sync anything. Nothing here creates an Application." \
  "That the 2.6 floor the page states is correct. This runs whatever 'stable' resolves to today and never tests an older release." \
  "That the same result holds for a pinned upstream ref. The URL under test floats." \
  "Anything about the annotation ceiling on a cluster with a raised --max-request-bytes or an admission layer that strips annotations."

parity_caveat \
  "The documented command is issued from the harness runner, not from the target node. Client-side apply builds the annotation client-side, so the failure is a property of the object and the API server, not of the runner's architecture ... but that reasoning is an argument, not a measurement." \
  "The target node is Ubuntu cloud-image k3s. The reference deployment is x86 openSUSE MicroOS. Nothing in this path touches the immutable-OS behaviours (transactional-update, reboot-before-effect) that differ there."

path_finish

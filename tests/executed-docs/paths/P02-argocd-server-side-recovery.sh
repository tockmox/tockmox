#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-raw
#
# PATH P02 ... the server-side recovery for the raw-manifest install.
#
# TWO JOBS, and they are worth separating.
#
# 1. It converts an UNVERIFIED published claim into evidence.
#    docs/administration/argocd.md carries the corrected command under an
#    explicit admonition: "The failure above was measured. The corrected command
#    was not re-run to completion here." The page even names the check it wants
#    ... `kubectl get crd applicationsets.argoproj.io` reporting established ...
#    which makes it a procedure with a stated success condition, and therefore
#    testable. Publishing a fix nobody ran is the same class of gap as
#    publishing a command nobody ran.
#
# 2. It is the CONTROL for P01. P01's headline assertion is an xfail, and an
#    xfail on its own is indistinguishable from an assertion that can never
#    pass. Running the same read against a cluster where the CRD really is
#    established proves the assertion has a green state. Without this, P01
#    proves nothing about the cluster ... only that the harness said "FAIL".
#
# Run AFTER P01 on the same cluster: --force-conflicts exists precisely for the
# half-applied state P01 leaves behind, so the ordering is the documented one.
#
# BUT P01 CAN LEGITIMATELY SKIP, and when it does this path quietly narrows.
# The raw-manifest route was retired from the docs on 2026-09-01, so at main P01
# exits 3 and there is no half-applied state. This path then measures a
# server-side apply against a CLEAN cluster ... which is a real thing to
# measure, and is NOT the recovery the page describes. Between 2026-09-01 and
# 2026-09-04 that substitution happened silently and nobody noticed, because P01
# was exiting 2 and its red line read as a defect rather than as a missing
# precondition (TM-0422). Check P01's result before reading this one.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P02_PAGE:-docs/administration/argocd.md}"
SECTION="${TOCKMOX_P02_SECTION:-## If you install from the raw manifest anyway}"
EXTRACT="${HERE}/../lib/extract-block.sh"

path_begin "P02-argocd-server-side-recovery" \
  "the published fix for TM-0288, which the page itself marks unverified"

# The page must actually carry this route at the ref under test. At v0.6.0-rc1
# it does not ... administration/argocd.md was written later. Say so and stop,
# rather than silently testing a command the harness invented, which is the
# failure mode this whole harness exists to prevent.
if ! CMD="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'server-side --force-conflicts' 2>/dev/null)"; then
  path_begin "P02-argocd-server-side-recovery" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section at ${REF}."
  _emit "           The server-side recovery is documented from the commit that"
  _emit "           added administration/argocd.md onward. Against an earlier ref"
  _emit "           this path is correctly absent, and P01's xfail therefore has"
  _emit "           NO CONTROL: treat P01's result on that ref as unconfirmed."
  _emit ""
  exit 3
fi
SHA="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'server-side --force-conflicts' --sha)"

provenance "$REF" "$PAGE" "$SECTION" 1 "$SHA"
verbatim "$CMD"

set +e
execute_begin "the documented server-side-apply recovery command"
bash -c "$CMD" 2>&1 | sed 's/^/    | /'
execute_end "${PIPESTATUS[0]}"
RC="${PIPESTATUS[0]}"
set -e
_emit "(documented command exited ${RC}; the exit code is not the assertion)"
_emit ""

crd_established() {
  kubectl --context="$KUBE_CONTEXT" get crd "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="Established")]}{.status}{end}' 2>&1
}
crd_has_lastapplied() {
  # Capture, then decide in the shell. Piping into awk cannot express "absent":
  # an empty jsonpath result is ZERO LINES, so awk's main block never runs and
  # the function emits nothing at all. The assertion then compares "absent"
  # against an empty string and reports a failure that is entirely the probe's,
  # not the cluster's. A probe that cannot express its own negative case is
  # broken in the direction that looks like a real defect.
  local v
  v="$(kubectl --context="$KUBE_CONTEXT" get crd "$1" \
       -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' 2>/dev/null)"
  if [ -n "$v" ]; then printf 'present'; else printf 'absent'; fi
}

# --- GLUE (not page text): give the CRD time to become Established ---------
# The API server sets Established asynchronously after the create returns, so a
# read in the same second can see False on a CRD that is about to succeed. The
# first real run of this path (run 36363942977, 2026-09-28) read False
# immediately after the apply. A reader running the page's check by hand does so
# seconds later. Wait up to 60s, then assert on what the page asks for; a CRD
# that is still not Established after that is a finding, not a race.
_emit "GLUE (not page text): kubectl wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=60s"
kubectl --context="$KUBE_CONTEXT" wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=60s 2>&1 | sed 's/^/    | /' || true
_emit ""

# --- the assertion the page asks for, in the page's own words --------------
assert_artifact \
  "crd/applicationsets.argoproj.io  .status.conditions[type=Established].status" \
  "crd_established applicationsets.argoproj.io" \
  "True"

# --- the assertion that proves the MECHANISM, not just the outcome ---------
# The page's explanation is that server-side apply does not write the
# last-applied-configuration annotation, and that the annotation is the thing
# that breaches the ceiling. Asserting the annotation is absent tests that
# reasoning. If the CRD were established for some other reason ... a retry, a
# pre-existing object, an operator ... this assertion would catch it and the
# established-True one would not.
assert_artifact \
  "crd/applicationsets.argoproj.io  metadata.annotations[kubectl.kubernetes.io/last-applied-configuration]" \
  "crd_has_lastapplied applicationsets.argoproj.io" \
  "absent"

does_not_prove \
  "That ArgoCD installed this way is equivalent to the Helm-installed one the docs recommend. It is not version-pinned, and nothing here compares them." \
  "That a reader who hit the client-side failure recovers cleanly from EVERY half-applied state. This tests one such state: the one P01 just produced." \
  "That a RECOVERY happened at all, on any ref where P01 skipped. With no prior client-side attempt there is nothing to force-conflict against, so what ran was a first server-side install. Read P01's line in the same report before treating this as evidence about the documented recovery." \
  "That --force-conflicts is safe against an ArgoCD someone else manages. It overwrites field ownership by design." \
  "Anything about ApplicationSet behaviour. The CRD being established is not the controller working."

parity_caveat \
  "Same runner and same guest OS caveat as P01: Ubuntu cloud-image k3s, not x86 openSUSE MicroOS."

path_finish

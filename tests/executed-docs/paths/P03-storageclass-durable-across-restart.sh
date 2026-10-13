#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# PATH P03 ... the durable local-path un-default, asserted ACROSS A RESTART.
#
# This is the path that justifies the whole harness. docs/testing-standard.md
# step 4: "Assert the claims, not only the commands. Where a page says a change
# survives a restart, the harness restarts and re-checks. That single assertion
# would have caught one of the two defects above."
#
# TM-0287 was a page that said a patch held, checked immediately after the patch,
# published with a date on it, and wrong. Every command on that page exited zero.
# No arrangement of exit codes could have caught it, and no static gate could
# either, because the tree was internally consistent about it. The only thing
# that catches it is restarting the machine and reading the value again.
#
# The page now carries the corrected mechanism AND an explicit admonition that
# the correction is itself unverified: "the procedure above has not been executed
# on a Tockmox cluster. Confirm by applying it, restarting k3s, and re-reading
# `kubectl get sc` ... `local-path` must still be un-defaulted after the restart,
# not merely after the patch." That sentence is this path's specification.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P03_PAGE:-docs/administration/storage.md}"
SECTION="${TOCKMOX_P03_SECTION:-### Making it durable: skip the addon, then patch}"
EXTRACT="${HERE}/../lib/extract-block.sh"
CLUSTER="${HERE}/../provision/throwaway-cluster.sh"

path_begin "P03-storageclass-durable-across-restart" \
  "the recommended durable un-default, re-read after a node restart"

if ! CMD="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'local-storage.yaml.skip' 2>/dev/null)"; then
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section at ${REF}."
  _emit "           The durable procedure was written after the defect was found."
  _emit "           Against an earlier ref, set TOCKMOX_P03_PAGE and"
  _emit "           TOCKMOX_P03_SECTION to that ref's un-default block, and expect"
  _emit "           the post-restart assertion to FAIL ... which is TM-0287."
  exit 3
fi
SHA="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'local-storage.yaml.skip' --sha)"

# This path needs IN-GUEST execution: the page's step 1 is "on EVERY k3s server
# node, sudo touch ...". Check that first, and record an exception rather than a
# failure if the node cannot be reached. A network topology that blocks inbound
# SSH is a reason this path did not run; it is not evidence that the documented
# procedure is wrong, and reporting it as FAIL would be a false accusation
# against the page.
if ! "$CLUSTER" exec 'true' >/dev/null 2>&1; then
  _emit "EXCEPTION: the node is not reachable for in-guest execution."
  _emit "           This path's step 1 is node-local by the page's own instruction"
  _emit "           ('on EVERY k3s server node'), so it cannot be run from the"
  _emit "           cluster side without substituting something else for it, which"
  _emit "           is the one thing this harness must not do."
  _emit "           NOT a defect in the documented procedure. NOT evidence about it"
  _emit "           either way. Re-run from a host with an inbound path to the"
  _emit "           guest, or on the devtest runner once it is on that network."
  _emit ""
  # BLOCKED, not exit 3. Exit 3 is "this section is not documented at this ref",
  # and the run counts it under `paths absent`. An unreachable node is an
  # environmental constraint, and reporting it as an absent DOCUMENT is the same
  # laundering this harness keeps finding: on 2026-09-13 this path was counted
  # absent for that reason while its section sat in storage.md the whole time.
  # BLOCKED says the claim is NOT verified and keeps it in the denominator.
  path_outcome BLOCKED "node not reachable for in-guest execution"
  exit 0
fi

provenance "$REF" "$PAGE" "$SECTION" 1 "$SHA"
verbatim "$CMD"

sc_default() {
  # The artefact is the annotation, read back off the object. Not `kubectl get
  # sc` output parsed for the word "(default)", which is a rendering of the
  # annotation and could change shape without the annotation changing.
  kubectl --context="$KUBE_CONTEXT" get storageclass "$1" \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>&1 \
    | awk '{ if (length($0) == 0) print "<unset>"; else print $0 }'
}
sc_resourceversion() {
  kubectl --context="$KUBE_CONTEXT" get storageclass "$1" -o jsonpath='{.metadata.resourceVersion}' 2>&1
}
skip_file_present() {
  "$CLUSTER" exec 'test -f /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip && echo present || echo absent' 2>&1 | tr -d '\r'
}

# --- precondition: local-path must have deployed BEFORE the skip file -------
# The page is emphatic that the order is the opposite of the k3s documentation's
# own example, and that getting it backwards leaves you with no local-path class
# at all. Assert the precondition, so a failure downstream is not misread as the
# procedure being wrong when it was the setup.
assert_artifact \
  "storageclass/local-path exists before the procedure runs" \
  "kubectl --context=\"$KUBE_CONTEXT\" get storageclass local-path -o jsonpath='{.metadata.name}' 2>&1" \
  "local-path"

_emit "PRE-STATE:"
_emit "  local-path is-default-class = $(sc_default local-path)"
_emit "  local-path resourceVersion  = $(sc_resourceversion local-path)"
_emit ""

# --- run the block verbatim, ON THE NODE -----------------------------------
# Both of the page's steps are run as one unit on a k3s server node. Step 1 is
# node-local by the page's own instruction; step 2 the page places "once, from
# anywhere", and a server node is somewhere. Splitting the block to route each
# half would be the harness editing the procedure.
set +e
execute_begin "the documented node-local storage block, run on the node"
"$CLUSTER" exec "$CMD" 2>&1 | sed 's/^/    | /'
RC="${PIPESTATUS[0]}"
execute_end "$RC"
set -e
_emit "(documented block exited ${RC} on the node; the exit code is not the assertion)"
_emit ""

# --- assertion 1: it worked at all -----------------------------------------
assert_artifact \
  "storageclass/local-path  annotations[storageclass.kubernetes.io/is-default-class]  (immediately after the patch)" \
  "sc_default local-path" \
  "false"

# --- assertion 2: the mechanism is in place --------------------------------
assert_artifact \
  "/var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip on the server node" \
  "skip_file_present" \
  "present"

# --- THE ASSERTION THAT MATTERS: re-read it after a restart ----------------
# A node reboot rather than `systemctl restart k3s`, deliberately. The page's
# own list of things that revert the annotation is "every restart, k3s upgrade,
# kured cycle or node rebuild", and a rebuild is the harshest member of that
# set. Passing the harshest one covers the others; passing the mildest would
# not.
_emit ">>> restarting the node. This is the step TM-0287 did not have."
"$CLUSTER" reboot

assert_artifact \
  "storageclass/local-path  annotations[storageclass.kubernetes.io/is-default-class]  AFTER a node restart" \
  "sc_default local-path" \
  "false"

# --- assertion 4: exactly one default, which is the reader's actual goal ---
# The un-default is a means. What the page is protecting is the invariant that
# one class is default and it is the one you meant. Asserting the invariant
# catches ways of being wrong that asserting the annotation alone does not ...
# for instance local-path staying false while nothing else is true.
count_defaults() {
  kubectl --context="$KUBE_CONTEXT" get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>&1 \
    | grep -c . | tr -d ' '
}
_emit "NOTE: on a bare k3s node with no Tockmox platform layer there is no"
_emit "      Longhorn class to become the new default, so the expected count of"
_emit "      default StorageClasses here is ZERO, not one. On a cluster carrying"
_emit "      the platform layer the expected value is 1 and the name is longhorn."
assert_artifact \
  "count of StorageClasses carrying is-default-class=true, after restart" \
  "count_defaults" \
  "${TOCKMOX_EXPECTED_DEFAULT_COUNT:-0}"

does_not_prove \
  "That the annotation survives a k3s UPGRADE. An upgrade rewrites the packaged manifests; the .skip file's behaviour against a version change is untested here." \
  "That it holds on a MULTI-SERVER cluster. The page says the file must exist on every server node and that k3s does not sync it. This is one node, so the failure mode the page warns about cannot occur and is therefore not tested." \
  "That a node added LATER gets the file. That is the same untested claim, from the other direction." \
  "That class-less PVCs bind where the reader wants. Longhorn is not installed on this node, so the binding half of the page's claim is out of scope for this gate ... see the inventory for where that is covered." \
  "That the orphaned local-path provisioner keeps working once k3s stops managing it. Nothing here ages the cluster."

parity_caveat \
  "Ubuntu cloud-image k3s on the Harvester rig. The reference deployment is x86 openSUSE MicroOS, where a package install takes effect only after a reboot and the k3s installer enables the service without starting it. Nothing about that difference is exercised here, and a pass on this node is NOT evidence for MicroOS." \
  "A node reboot on a VM is not identical to a physical power cycle. Firmware and disk-attach ordering differ."

path_finish

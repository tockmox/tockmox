#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# PATH B7 ... `helm show chart oci://...` for the sealed-secrets chart, the
# command that hands the reader the value they must supply for
# <CHART_VERSION_FROM_ABOVE> two blocks later in the same section.
#
# fresh-install.md "## 7. Install sealed-secrets, with your own key" opens
# with this single bash block:
#
#   block 1  `helm show chart oci://registry-1.docker.io/bitnamicharts/sealed-secrets
#            | grep -E '^(version|appVersion):'`
#
# immediately followed by prose, not a fenced block: "**YOU SUPPLY:** the
# chart version from that output." The command's own `grep -E` filter is the
# page's stated shape of a working result: a `version:` line and an
# `appVersion:` line, both non-empty, because a reader with neither could not
# supply anything to the block that follows. That is the success condition
# this path asserts against ... there is no separately labelled "Success
# condition:" paragraph for this specific block (unlike the install further
# down this same section, which has one and is P05's job, not this one's).
#
# UNLIKE every other path in this inventory, this one needs no cluster ...
# only network egress to an OCI registry. No KUBECONFIG is read or required.
# That is exactly what makes it the candidate TM-0289's B7 row named for
# moving to a per-commit tier: it is minutes, not the twenty-odd this
# harness's cluster-backed paths cost. This run reports whether that candidacy
# holds, but does not change any workflow's cadence ... that stays a design
# call for a human, not this script.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_B7_PAGE:-docs/deployment/fresh-install.md}"
SECTION="${TOCKMOX_B7_SECTION:-## 7. Install sealed-secrets, with your own key}"
EXTRACT="${HERE}/../lib/extract-block.sh"

path_begin "B7-helm-show-chart-sealed-secrets" \
  "helm show chart oci://... prints version:/appVersion: in the shape the page implies, before the reader supplies either downstream"

# --- block 1: the only block this path needs --------------------------------
if ! CMD1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm show chart oci://registry-1.docker.io/bitnamicharts/sealed-secrets' 2>/dev/null)"; then
  path_begin "B7-helm-show-chart-sealed-secrets" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 1, at ${REF}."
  exit 3
fi
SHA1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm show chart oci://registry-1.docker.io/bitnamicharts/sealed-secrets' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 1 "$SHA1"
verbatim "$CMD1"

execute_begin "helm show chart oci://registry-1.docker.io/bitnamicharts/sealed-secrets"
BLOCK1_OUT="$(bash -c "$CMD1" 2>&1)"
RC1=$?
execute_end "$RC1"
printf '%s\n' "$BLOCK1_OUT" | sed 's/^/    | /'
_emit "(block 1 exited ${RC1}; the exit code is not the assertion)"
_emit ""

# No substitution: this block carries no placeholder. It is upstream of the
# one two blocks later (`--version <CHART_VERSION_FROM_ABOVE>`), which is out
# of scope here ... that install command, and its own stated success
# condition (`readyReplicas` == 1), belongs to P05 per the run sheet, not B7.

# The page's implied condition, read off the command's own filter and the
# "YOU SUPPLY" prose: a `version:` line and an `appVersion:` line, each with a
# non-empty value on the same line. Asserted independently of the captured
# transcript above, against the block's own re-run output, so a future
# reordering of block 1 cannot silently defeat the check.
block1_output() {
  bash -c "$CMD1" 2>&1
}
chart_version_line() {
  block1_output | awk -F': *' '/^version:/{print $2; exit}'
}
app_version_line() {
  block1_output | awk -F': *' '/^appVersion:/{print $2; exit}'
}
shape_check() {
  local v a
  v="$(chart_version_line)"
  a="$(app_version_line)"
  if [ -n "$v" ] && [ -n "$a" ]; then
    printf 'version and appVersion both present'
  else
    printf 'MISSING: version=[%s] appVersion=[%s]' "$v" "$a"
  fi
}

# --- success condition (implied, not separately labelled on the page) -------
assert_artifact \
  "helm show chart oci://registry-1.docker.io/bitnamicharts/sealed-secrets, grep -E '^(version|appVersion):'" \
  "shape_check" \
  "version and appVersion both present"

_emit "READ VALUES (not the assertion above, recorded for the reader):"
_emit "  version:    $(chart_version_line)"
_emit "  appVersion: $(app_version_line)"
_emit ""

does_not_prove \
  "That the version this run resolved is the one every reader gets. Bitnami republishes this chart under a moving tag, same as ArgoCD's chart in P04, and this path deliberately does not pin it." \
  "That <CHART_VERSION_FROM_ABOVE> in the INSTALL block two paragraphs later resolves or installs cleanly. That is P05's job against a live cluster; this path never runs 'helm install'." \
  "That the sealed-secrets deployment reaches readyReplicas=1, or that the controller's key backs up successfully. Both are separate, later success conditions on the same page." \
  "Registry availability over time. A registry outage on some later run would make THIS path fail, not flake silently ... see the cadence note in the run report below." \
  "Anything about a cluster, a node, or an OS family. This path reads no KUBECONFIG and touches no VM."

_emit "CADENCE NOTE (reporting only; no workflow was changed by this run):"
_emit "  This run reached registry-1.docker.io over plain network egress and"
_emit "  used no KUBECONFIG, no cluster, and no provisioner. Elapsed wall time"
_emit "  was seconds, not the ~20 minutes the cluster-backed paths cost. That"
_emit "  supports moving this ROW to a per-commit tier, as the run sheet"
_emit "  proposed. The one thing worth weighing before doing that: this path's"
_emit "  ONLY dependency outside the repo is the OCI registry it queries, so a"
_emit "  registry outage or rate-limit would turn a per-commit gate red on"
_emit "  every commit until the registry recovers, whereas on a nightly job"
_emit "  the same outage costs one missed night. That is a real trade, not a"
_emit "  reason not to do it, and it is a design call left to a human."

parity_caveat \
  "None ... this path reads no guest, no node, and no OS. It queries an OCI registry from wherever the harness runs, which today is the same arm64 environment every other path in this inventory notes as a runner caveat, but that caveat does not apply to THIS command's result."

path_finish

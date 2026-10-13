#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# PATH P08 ... INVENTORY rows D7 and D9: the two read-only checks on
# `deployment/existing-cluster.md` that any cluster the harness stands up can
# answer, run verbatim from the page and asserted against the page's own
# "Passes when" conditions.
#
# WHY THIS PAGE, AND WHY THE CENSUS COMES FIRST (TM-0351). Every path script
# records whether the page it tests states success conditions at all, because
# a page that states none is a documentation defect before it is a testing gap.
# The first shape of that record was an inline `grep -c -i 'success condition'`,
# and `existing-cluster.md` labels every one of its six checks "Passes when"
# ... so the first path written against it would have recorded, into the
# divergence list and from there into INVENTORY.md, that a page stating six
# conditions states none. That is the bad failure direction: the harness
# manufacturing a defect against a correct page. `lib/assert.sh` now counts
# both phrasings rule 4 of docs/documentation-standard.md names, and this
# script is the path the card asked for: one written against the page that
# would have been misreported, asserting on the census as an artefact so a
# regression of the helper goes red HERE rather than into the inventory.
#
# WHAT IT RUNS, verbatim from the page at the ref under test:
#   Check 1, block 1:  kubectl version / kubectl get nodes
#   Check 3, block 1:  kubectl get storageclass
#
# WHAT IT ASSERTS, all against the page's own text:
#   0. the census: the page states at least one success condition in an
#      accepted form. Not "exactly six" ... a seventh check added to the page
#      is a page change, visible as a changed count in the log, not a harness
#      failure.
#   1. Check 1 "Passes when the server is 1.30 or newer and every node reports
#      `Ready`": two reads, the server minor version floor and the set of Ready
#      conditions across all nodes collapsing to the single value `True`.
#   2. Check 3 "Passes when exactly one class is marked `(default)`": the count
#      of `(default)` markers in the block's OWN output. On a stock k3s
#      throwaway that is `local-path`, count 1. If P03 has un-defaulted it
#      earlier in the same run, the page's condition legitimately reads 0 and
#      says "zero defaults is worth fixing for your own sake" ... set
#      TOCKMOX_P08_EXPECTED_DEFAULT_COUNT=0 for that ordering, the same knob
#      P03 carries for the same reason.
#
# WHAT IT DOES NOT RUN. Checks 2 (blocks 2 and 3), 4, 5 and 6. Check 2's
# remaining blocks and Check 4 write to or read from the node itself and share
# B5/D1's blocker; Checks 5 and 6 cross-reference fresh-install.md §6 and §7,
# which P04/P05 already execute (row D11, "EXECUTED by reference"). Check 2
# block 1 is read-only and could join this script; it is left out for now so
# the row D8 split (one third reachable, two thirds node-local) stays visible
# rather than being half-closed silently.
#
# NO CLUSTER IS AN EXCEPTION, NOT A FAILURE. Under run.sh a cluster is always
# there (it refuses to start otherwise). Run by hand with no reachable API,
# this script completes the citation stage ... the census is the part TM-0351
# is about and it needs no cluster ... then records an exception and exits 3,
# which is the harness's "recorded as an exception" code. A red result here
# would be a false accusation against the page.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P08_PAGE:-docs/deployment/existing-cluster.md}"
SECTION1="${TOCKMOX_P08_SECTION1:-## Check 1: version and node readiness}"
SECTION3="${TOCKMOX_P08_SECTION3:-## Check 3: the default StorageClass}"
EXPECTED_DEFAULTS="${TOCKMOX_P08_EXPECTED_DEFAULT_COUNT:-1}"
EXTRACT="${HERE}/../lib/extract-block.sh"

path_begin "P08-existing-cluster-checks" \
  "run existing-cluster.md Check 1 and Check 3 verbatim and assert their own 'Passes when' conditions; first, record that the page states success conditions at all"

# --- the two blocks, extracted verbatim ----------------------------------------
if ! CMD1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION1" --lang bash --containing 'kubectl get nodes' 2>/dev/null)"; then
  path_begin "P08-existing-cluster-checks" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION1}' section, block 1, at ${REF}."
  exit 3
fi
if ! CMD3="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION3" --lang bash --containing 'kubectl get storageclass' 2>/dev/null)"; then
  path_begin "P08-existing-cluster-checks" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION3}' section, block 1, at ${REF}."
  exit 3
fi
SHA1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION1" --lang bash --containing 'kubectl get nodes' --sha)"
SHA3="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION3" --lang bash --containing 'kubectl get storageclass' --sha)"
provenance "$REF" "$PAGE" "$SECTION1" 1 "$SHA1"
verbatim "$CMD1"
provenance "$REF" "$PAGE" "$SECTION3" 1 "$SHA3"
verbatim "$CMD3"

# --- the census: assertion 0, no cluster needed ------------------------------
PAGE_BYTES="$(mktemp "${TMPDIR:-/tmp}/tockmox-p08-page.XXXXXX")"
git --no-optional-locks show "${REF}:${PAGE}" >"$PAGE_BYTES" 2>/dev/null
record_success_conditions "$PAGE_BYTES" "${PAGE} @ ${REF}"
census_verdict() {
  # Prints `stated` or `none`. The exact count is already in the log line
  # above; this assertion is about the direction the harness reads it in.
  local n
  n="$(success_condition_count "$PAGE_BYTES")"
  if [ "${n:-0}" -gt 0 ]; then printf 'stated'; else printf 'none'; fi
}
assert_artifact \
  "success-condition census of ${PAGE} @ ${REF}, accepted forms: ${SUCCESS_CONDITION_FORMS} (the page labels every check 'Passes when')" \
  "census_verdict" \
  "stated"
rm -f "$PAGE_BYTES"

# --- is there a cluster? -------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1 \
   || ! kubectl --context="$KUBE_CONTEXT" get nodes >/dev/null 2>&1; then
  _emit "EXCEPTION: no cluster is reachable from this shell (kubectl absent, or"
  _emit "           the API did not answer). The citation stage above ran; the two"
  _emit "           documented checks did not. Under run.sh this cannot happen ..."
  _emit "           it refuses to start without a Ready throwaway. Run it there."
  assert_summary >/dev/null 2>&1 || true
  exit 3
fi

# --- Check 1, run exactly as printed -------------------------------------------
_emit "--- run exactly as printed on the page (Check 1) --------------------------"
execute_begin "the documented existing-cluster checks (Check 1)"
OUT1="$(bash -c "$CMD1" 2>&1)"
execute_end "$?"
printf '%s\n' "$OUT1" | sed 's/^/    | /'
_emit "(output above; the exit code is not the assertion)"
_emit ""

server_floor() {
  # "the server is 1.30 or newer". Reads the server's gitVersion, not the
  # client's: `kubectl version` prints both and the page's condition names the
  # server. The minor may carry a `+` suffix on some builds; strip non-digits.
  local v minor
  v="$(kubectl --context="$KUBE_CONTEXT" version -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\(v[^"]*\)".*/\1/p' | tail -1)"
  minor="$(printf '%s' "$v" | sed -n 's/^v1\.\([0-9]*\).*/\1/p')"
  if [ -n "$minor" ] && [ "$minor" -ge 30 ]; then
    printf 'server >= 1.30'
  else
    printf 'server %s is below 1.30' "${v:-<unreadable>}"
  fi
}
assert_artifact \
  "kubectl version: server gitVersion minor, against the page's floor of 1.30 (Check 1, 'Passes when')" \
  "server_floor" \
  "server >= 1.30"

ready_set() {
  # The set of Ready-condition statuses across every node, deduplicated. A
  # cluster where every node is Ready collapses to the single line `True`; one
  # NotReady node makes it two lines and the equality fails, naming the value.
  kubectl --context="$KUBE_CONTEXT" get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}
assert_artifact \
  "kubectl get nodes: every node's Ready condition, as a deduplicated set (Check 1, 'every node reports Ready')" \
  "ready_set" \
  "True"

# --- Check 3, run exactly as printed -------------------------------------------
_emit "--- run exactly as printed on the page (Check 3) --------------------------"
OUT3="$(bash -c "$CMD3" 2>&1)"
printf '%s\n' "$OUT3" | sed 's/^/    | /'
_emit "(output above; the assertion reads the '(default)' marker in it)"
_emit ""

default_marker_count() {
  # `grep -c` prints a count and still exits 1 on zero matches: capture, then
  # print once (the P07 lesson).
  local n
  n="$(printf '%s\n' "$OUT3" | grep -c '(default)' 2>/dev/null)"
  printf '%s' "${n:-0}"
}
assert_artifact \
  "count of '(default)' markers in the Check 3 block's own output (Check 3, 'exactly one class is marked (default)')" \
  "default_marker_count" \
  "$EXPECTED_DEFAULTS"

does_not_prove \
  "Checks 2, 4, 5 and 6. Check 2's config-file and restart blocks and Check 4's package check are node-local (rows B5, D1, D8, D10); Checks 5 and 6 are covered by reference through P04/P05 (row D11). Check 2 block 1 is read-only and not yet run." \
  "That the page's conditions hold on a cluster this project does not control, which the page's own 'What is not certified here' names as the case it exists for. The throwaway is stock k3s with traefik and servicelb disabled, one node." \
  "That the version floor is the real constraint. The assertion reads the floor the page states; it does not install 1.29 and watch anything fail (row B9's shape)." \
  "That '(default)' in kubectl's table output is the only way a default class is marked. It is what the page's own block shows a reader, so it is what is asserted; the annotation itself is not read." \
  "Anything about the count of success conditions beyond 'more than zero'. The exact figure is logged, not asserted, so a page gaining a seventh check moves the log and not this path."

parity_caveat \
  "Guest is an Ubuntu cloud image on KubeVirt, amd64, k3s at the version fresh-install.md pins (K3S_VERSION), unless the run set TOCKMOX_K3S_VERSION. The reference deployment is openSUSE MicroOS on x86; nothing here is evidence for the storage-package check on that platform (Check 4, not run)."

path_finish

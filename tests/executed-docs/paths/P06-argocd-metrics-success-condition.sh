#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P06 ... run sheet item 4 (B6), the riskiest of the ten (now thirteen,
# see below) success-condition commands `fresh-install.md` states: whether
# `kubectl -n argocd get svc | grep metrics` lists three services once ArgoCD
# metrics are turned on.
#
# THE COUNT, ESTABLISHED BEFORE WRITING THIS SCRIPT, PER THE RUN SHEET'S OWN
# INSTRUCTION NOT TO TRUST "ten". `grep -n 'Success condition' fresh-install.md`
# on this ref returns THIRTEEN paragraphs, not ten:
#
#   L143  §2  iscsid/iscsiadm active, on every node               NODE-LOCAL
#   L267  §4a node 1 `Ready`                                      NODE-LOCAL
#   L306  §4c nodes 2/3 `Ready` after each, FOUR-NODE ONLY         NODE-LOCAL, multi-node
#   L331  §4d agent node `Ready`, FOUR-NODE ONLY                   NODE-LOCAL, multi-node
#   L365  §4e every node: Ready/MountFlags/no traefik-svclb/version NODE-LOCAL
#   L393  §4f three nodes stay Ready across a killed server, 4N-ONLY NODE-LOCAL, multi-node
#   L453  §5  the `.skip` file exists and `local-path` stays default NODE-LOCAL (this is B5's shape)
#   L495  §6  ArgoCD, "all three": wait/CRD/image-tag floor         COVERED -- P04 / B1 / A1b
#   L521  §6  "you hold a token ... scoped to one repository"       NO COMMAND -- human judgement
#   L529  §6  `kubectl -n argocd get svc | grep metrics`            THIS PATH
#   L557  §7  sealed-secrets `readyReplicas` prints `1`              COVERED -- P05 / A2
#   L583  §7  key backup count >= 1, AND moved off-cluster           COVERED (first clause) -- P05 / A2
#   L619  §8  "you can write all four [site values] down"            NO COMMAND -- human judgement
#
# THE TABLE ABOVE IS THE RECORD OF THIS RUN AND IS LEFT AS IT WAS WRITTEN.
# 2026-09-02, AFTER this run: `fresh-install.md` was restructured from a
# four-node path (3 servers + 1 agent) to three servers with an OPTIONAL worker
# node at §4d. Read every "FOUR-NODE ONLY" above as "MULTI-NODE ONLY", and
# every line number as against the pre-restructure page. The count of thirteen
# and each row's EXCEPTION/COVERED verdict are unaffected: the same conditions
# survive the restructure, relabelled. §4f's stated outcome DID change ... it
# read "three nodes stay Ready" when four existed and now reads "every node
# except the one you killed", which on the recommended shape is two.
# Re-derive the line numbers before trusting them; do not trust this note's
# arithmetic either.
#
# Seven are node-local (SSH into a guest masquerade forbids inbound to, or a
# 2nd/3rd/4th node the substrate does not provision) and are recorded below as
# WRITTEN EXCEPTIONS, the same shape as P03/B5. Two state a condition with no
# accompanying command anywhere on the page -- a human reads their own token
# scope or their own notes, and no artefact exists for a machine to read. Three
# are already EXECUTED by earlier paths this session (P04, P05) and are cited,
# not re-run, so this path does not inflate B6's count with duplicate coverage.
# That leaves exactly ONE new, cluster-testable, not-yet-covered command: this
# one. The true B6 figure to carry forward is 13, not 10, and INVENTORY.md's B6
# row is updated with the breakdown above rather than a single revised number,
# because the breakdown is the part a reader needs.
#
# REWRITTEN AT 0.6.1 (TM-0628), AND THE REWRITE DELETED MORE THAN IT ADDED.
# Everything below this line supersedes the accounting above where they differ;
# the text above is left as the record of the 2026-09-02 run.
#
# WHAT THE PAGE FIXED, WHICH IS WHAT THIS PATH EXISTED TO REPORT. This script
# used to carry three apologies, and TM-0628 retired all three at once by
# moving ArgoCD's metrics values into section 6's own `helm install` block as
# six `--set` flags:
#
#   1. THE COMMAND IS NOW IN A FENCED BLOCK. It used to be prose with a single
#      inline code span, which `lib/extract-block.sh` has no mechanism for --
#      it walks fences, not inline spans. This path therefore pulled the bytes
#      between the backticks out of `git show`, anchored on a literal substring
#      of the surrounding prose, with a CI canary asserting that substring
#      still matched character for character. The success condition is now a
#      labelled ```bash fence, so the inline hack and its canary are both
#      GONE and this path calls extract-block.sh like every other path.
#   2. THE HARNESS GLUE IS GONE. The page used to give values in
#      `administration/argocd.md` with no command anywhere applying them, so
#      this path authored its own `helm upgrade ... -f` and flagged it as
#      not-page-text. The documented install now applies them itself, so there
#      is nothing left to glue. That documentation defect, carded by this path
#      on 2026-09-02 and recorded in INVENTORY.md row B6 as "suggested
#      wording, not applied", is fixed -- by a better option than the one
#      suggested there, since values on the install command cannot be missed
#      by a reader who never opens the second page.
#   3. THE ORDINAL IS GONE, AND THIS ONE WAS A LATENT DEFECT IN THIS SCRIPT.
#      Block 2 was extracted with `--block 2` and called "install ArgoCD
#      verbatim, stock". On 2026-09-13 a reachability check was inserted at
#      the top of section 6, shifting every ordinal by one -- the incident
#      extract-block.sh's own awk comment records, where P04 ran the
#      reachability check believing it was the version listing. P04 was
#      converted to `--containing` in that pass; THIS PATH WAS NOT. So
#      `--block 2` has resolved to `helm repo add argo` since 2026-09-13,
#      which is the same block CMD1 already extracts, and this path has not
#      run the documented install at all. It never reported a false PASS only
#      because the `paths` job needs a self-hosted runner that has never
#      completed a run (every executed-docs run to date is cancelled, queued
#      or pending). It would have bitten on the first real execution. Every
#      extraction here now names its command instead of its position.
#
# ONE CLAIM NOW, NOT TWO, AND THE DROPPED ONE IS DROPPED HONESTLY. The old
# claim (a) asserted that a STOCK install shows zero metrics services, which
# the page still states as a parenthetical ("A stock install, without those
# `--set` flags, lists none"). It is no longer testable from the page, because
# the documented install no longer produces the stock state: reaching it would
# need a second install WITHOUT the flags, which is not a documented command,
# and authoring one is the glue this rewrite just removed. So it moves to
# `does_not_prove` rather than being tested against a counterfactual nobody
# follows. What remains is the claim the run sheet actually called risky, and
# it is now reachable by following the page top to bottom: does the documented
# install produce exactly three Services whose names contain "metrics"?

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P06_PAGE:-docs/deployment/fresh-install.md}"
SECTION="${TOCKMOX_P06_SECTION:-## 6. Install ArgoCD}"
# PAGE2/SECTION2 (administration/argocd.md's values block) are gone at 0.6.1:
# this path no longer applies those values itself, because section 6's own
# install block does. The section canary still asserts that yaml block exists,
# which is where that page's coverage belongs.
EXTRACT="${HERE}/../lib/extract-block.sh"

path_begin "P06-argocd-metrics-success-condition" \
  "does 'kubectl -n argocd get svc | grep metrics' list three services once ArgoCD's own documented metrics values are applied, as the page's success condition claims"

# --- block 1: resolve the chart version, live, same discipline as P04/P05 ---
if ! CMD1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm repo add argo' 2>/dev/null)"; then
  path_begin "P06-argocd-metrics-success-condition" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 1, at ${REF}."
  exit 3
fi
SHA1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm repo add argo' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 1 "$SHA1"
verbatim "$CMD1"

_B1OUT="$(mktemp "${TMPDIR:-/tmp}/p06-b1.XXXXXX")"
run_block_carrying_exports "$CMD1" > "$_B1OUT" 2>&1
BLOCK1_OUT="$(cat "$_B1OUT")"; rm -f "$_B1OUT"
RC1=$?
printf '%s\n' "$BLOCK1_OUT" | sed 's/^/    | /'
_emit "(block 1 exited ${RC1}; the exit code is not the assertion)"
_emit ""

CHART_VERSION="$(printf '%s\n' "$BLOCK1_OUT" | awk '$1=="argo/argo-cd"{print $2; exit}')"
_emit "SUBSTITUTION MADE:"
_emit "  ARGOCD_CHART_VERSION carried from block 1 -> ${ARGOCD_CHART_VERSION:-<unset>}"
_emit ""
if [ -z "$CHART_VERSION" ]; then
  _emit "EXCEPTION: could not parse a chart version out of block 1's own output."
  exit 3
fi

# --- the documented install, selected BY CONTENT not by ordinal -------------
# `--containing 'helm install argocd'` rather than `--block 2`: see item 3 in
# the header. The ordinal drifted on 2026-09-13 and again at 0.6.1, and both
# times it kept resolving to a real block, which is what makes an ordinal
# dangerous rather than merely fragile. Rerun rather than assumed present,
# same reasoning P05 gives for rereading B7's block live.
if ! CMD2="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm install argocd' 2>/dev/null)"; then
  _emit "EXCEPTION: no bash block under '${SECTION}' in ${PAGE} at ${REF}"
  _emit "           contains 'helm install argocd'. The documented install"
  _emit "           command moved or changed shape; this path hands back"
  _emit "           rather than running a block it guessed at."
  exit 3
fi
SHA2="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm install argocd' --sha)"
provenance "$REF" "$PAGE" "$SECTION" "containing:helm install argocd" "$SHA2"
verbatim "$CMD2"

CMD2_SUBST="$CMD2"   # the page derives and exports the version now
_emit "--- run with the substitution above, otherwise byte-for-byte ---------"
printf '%s\n' "$CMD2_SUBST" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
_emit "----------------------------------------------------------------------"

execute_begin "the documented ArgoCD metrics-enabling install"
bash -c "$CMD2_SUBST" 2>&1 | sed 's/^/    | /'
execute_end "${PIPESTATUS[0]}"
RC2="${PIPESTATUS[0]}"
_emit "(block 2 exited ${RC2}; the exit code is not the assertion)"
_emit ""

# --- the success-condition command, now a fenced block like any other -------
# Was an inline code span pulled out with sed and a prose anchor until 0.6.1.
# TM-0628 made it a labelled ```bash fence, so this is an ordinary extraction
# and the CI canary that guarded the anchor string is deleted with it.
if ! CMD_METRICS_BLOCK="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'grep metrics' 2>/dev/null)"; then
  _emit "EXCEPTION: no bash block under '${SECTION}' in ${PAGE} at ${REF}"
  _emit "           contains 'grep metrics'. The success condition moved or"
  _emit "           changed shape; this path hands back rather than guessing."
  exit 3
fi
SHA_METRICS="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'grep metrics' --sha)"
provenance "$REF" "$PAGE" "$SECTION" "containing:grep metrics" "$SHA_METRICS"
verbatim "$CMD_METRICS_BLOCK"

# The block carries the page's KUBE_CONTEXT guard line above the command, so
# it is run whole rather than reduced to one line ... running the block as
# printed is the point of this harness.
metrics_svc_count() {
  bash -c "$CMD_METRICS_BLOCK" 2>/dev/null | grep -c . || true
}

after_out="$(bash -c "$CMD_METRICS_BLOCK" 2>&1)"
_emit "--- the documented success condition, after the documented install ----"
_emit "$(printf '%s' "$after_out" | sed 's/^/    | /')"
_emit ""
assert_artifact \
  "svc -n argocd | grep metrics  (after section 6's own install block, --set flags included)" \
  "metrics_svc_count" \
  "3"

does_not_prove \
  "The page's own stock-install parenthetical, 'a stock install, without those --set flags, lists none'. This path used to assert it as claim (a) against section 6's install block. TM-0628 put the metrics flags INTO that block, so the documented path no longer produces a stock install and the baseline is now a counterfactual: reaching it needs an install this page does not document. Dropped deliberately rather than tested against a command the harness would have to author. If that parenthetical is worth proving, it needs its own documented path, not glue here." \
  "That the three service names this run found are the exact names a different chart version would produce. Chart version resolved live (see substitution above), not pinned, same caveat as P04/B7." \
  "That turning ArgoCD metrics on this way matches Tockmox's own recommended path, which also wants apps.argocdMonitoring enabled on the Tockmox side to get a dashboard. That second half is not tested here -- this path stops at the chart's own Services existing, and the page's own callout says having one half gets you neither." \
  "Anything about ServiceMonitors, Prometheus actually scraping, or the dashboard administration/argocd.md describes as the deliberate pair." \
  "That administration/argocd.md's YAML values and section 6's six --set flags still say the same thing. They were equivalent when TM-0628 moved them, and nothing asserts that they stay equivalent: a values key added to one and not the other drifts silently. This path now reads only the install block, so it would not notice. Worth a gate, and it is not this one." \
  "Any of the twelve other 'Success condition' paragraphs on this page. See the header comment for the full accounting: seven are node-local exceptions, two state no command at all, and three are already covered by P04 and P05."

parity_caveat \
  "Guest is an Ubuntu cloud image on KubeVirt, amd64. The harness runner is arm64; that caveat is about the runner, not the cluster under test."

path_finish

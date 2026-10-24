#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=sealed-secrets
#
# PATH P07 ... run sheet item 5, INVENTORY row A2's second half: seal one real
# secret with the page's own block and read it back out of the cluster. P05
# covers the controller install; this is the round trip.
#
# WHAT IT RUNS. `administration/secrets.md` "## Sealing one" carries exactly
# ONE ```bash block. That block is extracted at the ref under test and run
# byte for byte, with ONE substitution: the value placeholder `api-key='...'`
# (three literal dots, not a copyable value) is replaced with an obviously
# synthetic canary generated fresh every run and never written into this
# script (rule 6). The substitution is recorded in the log, not made silently.
#
# WHAT IT ASSERTS, all against the page's own text:
#   1. the page's stated success condition: `grep -c '^kind: SealedSecret'`
#      on the sealed file prints `1`. The page also says why the file and not
#      the exit code is the artefact: the `>` redirect creates the file BEFORE
#      kubeseal runs, so a failed seal leaves a zero-byte file looking minted.
#   2. the sealed file does not carry the plaintext, which is the mechanical
#      form of the page's claim "the plaintext never touches disk".
#   3. after the SealedSecret is applied, the controller decrypts it back to
#      the exact canary that was sealed. That is the round trip.
#
# HISTORY, kept short because the defect is fixed. P07 was first written
# 2026-09-02 against a page whose block omitted `--controller-name` and
# `--controller-namespace`, so the page's own bytes produced a zero-byte file
# against the controller this repo's own install creates (TM-0346). The first
# shape of this script pinned that as an XFAIL, then re-ran the same command
# with the two flags added as flagged harness glue to isolate the diagnosis.
# TM-0346 put the flags on the page, the XFAIL was observed flipping with this
# script unmodified (TM-0346's close-out log, run against `main` at 133637b),
# and TM-0350 collapsed the script to the single attempt below. The second
# attempt isolated nothing once the page carried the flags, and its glue
# substitution had started inserting the flags a second time. Do not
# reintroduce the two-attempt structure: a pinned XFAIL is for a live defect.
#
# GLUE THAT REMAINS, and is still honest glue: creating the target namespace,
# and `kubectl apply` of the sealed file standing in for the page's own
# "commit -> git -> sync", which this harness cannot exercise without a site
# repository (A5). Both are labelled GLUE in the log. No kubeseal invocation
# is glue.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

# --- the tool this path is ABOUT must exist, or nothing below means anything --
#
# Added 2026-09-13. Run with no kubeseal on PATH, this path reported two FAILs:
# the page's own success condition reading 0, and an empty decrypted value. Both
# read as "the sealing documentation is broken" ... which it genuinely was once
# (TM-0346), so a reader of that report would reasonably believe it had
# regressed. It had not. kubeseal was simply absent, the `>` redirect created an
# empty file, and the assertions measured that.
#
# This repository already learned the rule and wrote it down in
# tools/check-all.sh: "a gate that invents findings when its tooling is absent
# is worse than one that refuses to run." Exit 2 is SKIPPED here, the same
# convention check-blueprint-discovery.sh uses.
if ! command -v kubeseal >/dev/null 2>&1; then
  path_begin "P07-sealed-secrets-seal-roundtrip" "SKIPPED ... no kubeseal on PATH"
  _emit "SKIPPED: kubeseal is not installed on this runner."
  _emit "         Every assertion below reads a file that kubeseal writes, so"
  _emit "         without it they would measure an empty redirect and report the"
  _emit "         documented procedure as broken. Refusing rather than guessing."
  exit 2
fi

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P07_PAGE:-docs/administration/secrets.md}"
SECTION="${TOCKMOX_P07_SECTION:-## Sealing one}"
EXTRACT="${HERE}/../lib/extract-block.sh"

# Harness-chosen, not page-given: the namespace the page's own example uses,
# which this harness has to create (GLUE) because nothing upstream of this
# test does on a bare throwaway cluster.
TARGET_NS="tockmox-ai"

path_begin "P07-sealed-secrets-seal-roundtrip" \
  "seal a real secret with kubeseal, apply the SealedSecret, and assert the controller decrypts it back to the exact value that was sealed"

# --- the one block on the page, extracted verbatim --------------------------
if ! CMD1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'kubectl create secret generic my-secret' 2>/dev/null)"; then
  path_begin "P07-sealed-secrets-seal-roundtrip" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 1, at ${REF}."
  exit 3
fi
SHA1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'kubectl create secret generic my-secret' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 1 "$SHA1"
verbatim "$CMD1"
PAGE_BYTES="$(mktemp "${TMPDIR:-/tmp}/tockmox-p07-page.XXXXXX")"
git --no-optional-locks show "${REF}:${PAGE}" >"$PAGE_BYTES" 2>/dev/null
record_success_conditions "$PAGE_BYTES" "${PAGE} @ ${REF}"
rm -f "$PAGE_BYTES"

# --- the placeholder substitution --------------------------------------------
SYNTH="roundtrip-canary-$(openssl rand -hex 16)"
if ! printf '%s' "$CMD1" | grep -F "api-key='...'" >/dev/null; then
  _emit "EXCEPTION: expected literal \"api-key='...'\" in block 1 and did not find it."
  _emit "           The page's placeholder shape changed. Handing back rather than guessing."
  exit 3
fi
# NEEDLE held in a variable rather than written literally inside ${CMD1//.../...}:
# a LITERAL quote character typed directly in a pattern position undergoes quote
# REMOVAL there (it is bash syntax, not data to match), so a pattern written as
# api-key='...' silently searches for api-key=... with NO quote characters and
# never matches text that actually has them ... measured while writing this
# script: the substitution below silently no-opped and the run sealed the
# literal three-dot placeholder. Expanding an already-quote-resolved variable
# ($NEEDLE) sidesteps this: its VALUE, quote characters included, is used
# as-is with no second round of quote removal.
NEEDLE="api-key='...'"
REPLACEMENT="api-key='${SYNTH}'"
CMD1_SUBST="${CMD1//$NEEDLE/$REPLACEMENT}"
if [ "$CMD1_SUBST" = "$CMD1" ]; then
  _emit "EXCEPTION: the placeholder substitution had no effect. Handing back rather"
  _emit "           than running the page's literal, un-sealable '...' value."
  exit 3
fi
_emit "SUBSTITUTION MADE:"
_emit "  api-key='...'  ->  api-key='${SYNTH}'   (obviously-synthetic canary, generated this run, never committed)"
_emit ""
_emit "GLUE (namespace, not page text):"
_emit "  the page's own '--namespace ${TARGET_NS}' is run VERBATIM below; this harness additionally"
_emit "  creates that namespace before applying, since nothing upstream of this test creates it."
_emit ""

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-p07-seal.XXXXXX")"
mkdir -p "${WORKDIR}/secrets"
cd "$WORKDIR"

# --- the page's block, run exactly as printed (value placeholder substituted) ---
_emit "--- run exactly as printed on the page (plus the value substitution) ---------"
printf '%s\n' "$CMD1_SUBST" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
_emit "-----------------------------------------------------------------------"
execute_begin "the documented kubeseal seal round-trip"
RUN_ERR="$(bash -c "$CMD1_SUBST" 2>&1 1>/dev/null)"
execute_end "$?"
printf '%s\n' "$RUN_ERR" | sed 's/^/    | /'
_emit "(stderr above, expected empty; the exit code is not the assertion)"
_emit ""

# --- assertion 1: the page's OWN stated success condition --------------------
# "grep -c '^kind: SealedSecret' secrets/my-secret.sealed.yaml prints 1". The
# file's first line is `---`, not `kind:`, so this is the right read and a
# head -1 would not be. `grep -c` prints the count and still exits 1 on zero
# matches, so capture first and print once.
sealed_kind_count() {
  local n
  n="$(grep -c '^kind: SealedSecret' secrets/my-secret.sealed.yaml 2>/dev/null)"
  printf '%s' "${n:-0}"
}
assert_artifact \
  "grep -c '^kind: SealedSecret' secrets/my-secret.sealed.yaml, after 'Sealing one' block 1 run byte-for-byte (value placeholder substituted only) ... the page's own success condition" \
  "sealed_kind_count" \
  "1"

# --- assertion: the file is genuinely encrypted, not merely re-encoded ------
# Supports the page's own claim two paragraphs above the block ("Only the
# controller running in your cluster can decrypt it") with a cluster-observed
# check rather than trusting the format name.
plaintext_leak_count() {
  # `grep -c` PRINTS a count (even 0) but still exits 1 on zero matches, so
  # `grep -c ... || echo 0` prints TWICE on the no-leak case ("0" from grep,
  # then "0" from the fallback) ... measured here, same family as the
  # documented `pipefail + grep -q` inversion. Capture first, print once.
  local n
  n="$(grep -c -- "$SYNTH" secrets/my-secret.sealed.yaml 2>/dev/null)"
  printf '%s' "${n:-0}"
}
leak_n="$(plaintext_leak_count)"
assert_artifact \
  "grep -c '${SYNTH}' secrets/my-secret.sealed.yaml  (the sealed file must not carry the plaintext)" \
  "plaintext_leak_count" \
  "0"

# --- apply: GLUE standing in for 'commit -> git -> sync' ------------
# The page's own diagram is seal -> commit -> git -> sync -> controller ->
# Secret. This harness has no GitOps loop standing up a site repository (that
# is A5, out of scope), so a direct `kubectl apply` is the mechanical
# equivalent of "sync" for the one object this path cares about. Flagged as
# glue, same reasoning P06 gives for its `helm upgrade`.
_emit "GLUE (not page text): create the target namespace, since"
_emit "nothing upstream of this test creates it on a bare throwaway cluster."
kubectl --context="$KUBE_CONTEXT" create namespace "$TARGET_NS" --dry-run=client -o yaml 2>/dev/null | kubectl --context="$KUBE_CONTEXT" apply -f - >/dev/null 2>&1
_emit "GLUE (not page text): apply the SealedSecret. Standing in for"
_emit "the page's own 'commit -> git -> sync', which this harness cannot exercise"
_emit "without a site repository (A5, out of scope)."
APPLY_OUT="$(kubectl --context="$KUBE_CONTEXT" apply -f secrets/my-secret.sealed.yaml 2>&1)"
printf '%s\n' "$APPLY_OUT" | sed 's/^/    | /'
_emit ""

# Give the controller a moment to reconcile, same grace P05 gives readyReplicas.
for _i in 1 2 3 4 5 6 7 8 9 10; do
  kubectl --context="$KUBE_CONTEXT" -n "$TARGET_NS" get secret my-secret >/dev/null 2>&1 && break
  sleep 3
done

# --- THE CLAIM THAT MATTERS: the decrypted value equals what was sealed -----
decrypted_value() {
  kubectl --context="$KUBE_CONTEXT" -n "$TARGET_NS" get secret my-secret -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d 2>/dev/null
}
assert_artifact \
  "secret/my-secret in ns/${TARGET_NS}  .data['api-key'] (base64-decoded)" \
  "decrypted_value" \
  "$SYNTH"

cd /
rm -rf "$WORKDIR" 2>/dev/null || true

does_not_prove \
  "That tools/mint-secrets.sh, which the page recommends over the manual block, seals correctly. Only the page's inline block is executed here; the script's seal() helper carries the same two flags (read in the source at this ref, not executed), and that is a reading, not a cluster-observed result." \
  "That the page's block fails without the two --controller-* flags. A single attempt against the page's own bytes cannot isolate which part of the command made it work; the earlier two-attempt shape did, once, against the broken page (TM-0346's evidence log). If the flags are ever dropped from the page, assertion 1 goes red and says nothing about why." \
  "Anything about a SealedSecret committed to git and synced by ArgoCD. The apply below is direct kubectl, harness glue standing in for that path; the real GitOps loop is A5's scope, not this one's." \
  "Anything about key ROTATION, about a backup restoring into a fresh cluster (administration/secrets.md's separate 'Prove it once' step), or about a SealedSecret sealed against a DIFFERENT cluster's key ever decrypting here. Only one controller, one key, one cluster, one run." \
  "That the default 'strict' encryption scope is the only one Tockmox readers use, or that a mismatched secret name/namespace at seal time behaves any particular way. Not exercised." \
  "That the chart/controller version this run resolved (via P05, run first) is the one every reader gets. Same caveat as P04/P05/B7: deliberately not pinned."

parity_caveat \
  "Guest is an Ubuntu cloud image on KubeVirt, amd64. The harness runner is arm64; kubeseal itself was fetched as a linux/arm64 build for the runner, which is the client and holds no cluster-specific behaviour, so this caveat is about the runner architecture, not the cluster under test."

path_finish

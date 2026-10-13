#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=sealed-secrets
#
# PATH P05 ... install sealed-secrets, back up the controller key, against a
# live cluster.
#
# THE ROUTE, VERIFIED BEFORE WRITING THIS SCRIPT. The run sheet names this
# path's target as "deployment/prerequisites.md §3". On `main` that heading
# does not exist: `prerequisites.md` carries ZERO fenced bash blocks at all
# (confirmed with `grep -c '^```bash'`) and its four headings are
# "## Which path is yours", "## What you do NOT need", "## Sizing and
# hardware" and "## On equipment, rather than values" ... none numbered. The
# page was rewritten into a pure signpost on 2026-09-01 (same rewrite
# INVENTORY.md's A1a row notes for the ArgoCD prerequisite); it now names
# "sealed-secrets with your own key" as one of three things needed and links
# straight to `fresh-install.md`, without repeating any command.
#
# There is therefore only ONE documented sealed-secrets install route on this
# ref, not two: `fresh-install.md` "## 7. Install sealed-secrets, with your
# own key". `existing-cluster.md` "## Check 6: sealed-secrets" and
# `administration/secrets.md` "## Where the controller chart comes from, and
# why it matters" both cross-reference that same section by anchor
# (`fresh-install.md#7-install-sealed-secrets-with-your-own-key`) rather than
# documenting a second install command, and both check the SAME release name
# (`kubectl -n kube-system get deployment sealed-secrets`). So this is not the
# TM-0299 shape (two independent routes, one never run) ... it is a stale
# citation in the run sheet, predating the prerequisites.md rewrite. Reported
# here rather than silently reconciled; the run sheet is the thing to correct,
# not this comment.
#
# fresh-install.md "## 7. Install sealed-secrets, with your own key" carries
# four bash blocks:
#
#   block 1  `helm show chart oci://.../sealed-secrets | grep -E
#            '^(version|appVersion):'` ... already exercised on its own by
#            B7-helm-show-chart-sealed-secrets.sh. This path re-extracts and
#            re-runs it anyway (never retyped, never reused across scripts)
#            because the chart version is a moving tag and P05 needs a LIVE
#            reading to substitute into block 2, the same discipline P04 uses
#            for ArgoCD's chart version.
#   block 2  `helm install sealed-secrets oci://.../sealed-secrets --version
#            <CHART_VERSION_FROM_ABOVE> --namespace kube-system` ... the
#            install itself. THE RISKY HALF, per the run sheet: this path's
#            own success condition (block 3) only resolves because THIS
#            command names the release `sealed-secrets`. See does_not_prove.
#   block 3  the page's own "Success condition:" ... readyReplicas prints `1`.
#   block 4  the key-backup command, immediately under "### Back up the
#            controller's private key. Now.", plus `grep -c 'tls.key'` on the
#            file it wrote. The page's own stated success condition is "the
#            count is at least 1, AND you have moved the file somewhere the
#            cluster's failure does not reach." Only the first half is
#            testable from inside this harness; the second is a human action
#            on a disposable guest and is named in does_not_prove rather than
#            invented as a check nobody can pass in this environment.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
PAGE="${TOCKMOX_P05_PAGE:-docs/deployment/fresh-install.md}"
SECTION="${TOCKMOX_P05_SECTION:-## 7. Install sealed-secrets, with your own key}"
EXTRACT="${HERE}/../lib/extract-block.sh"

path_begin "P05-sealed-secrets-install" \
  "install sealed-secrets with the release name the page's own success condition assumes, then back up the controller key"

# --- block 1: resolve the chart version, live, same discipline as P04 -------
if ! CMD1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm show chart' 2>/dev/null)"; then
  path_begin "P05-sealed-secrets-install" "NOT A DOCUMENTED PATH AT THIS REF"
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 1, at ${REF}."
  exit 3
fi
SHA1="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm show chart' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 1 "$SHA1"
verbatim "$CMD1"

# Run in THIS shell and carry the export: the page derives
# SEALED_SECRETS_CHART_VERSION here and block 2 guards on it (TM-0484).
_B1OUT="$(mktemp "${TMPDIR:-/tmp}/p05-b1.XXXXXX")"
run_block_carrying_exports "$CMD1" > "$_B1OUT" 2>&1
_P05_RC1=$?
BLOCK1_OUT="$(cat "$_B1OUT")"; rm -f "$_B1OUT"
RC1=$?
printf '%s\n' "$BLOCK1_OUT" | sed 's/^/    | /'
_emit "(block 1 exited ${RC1}; the exit code is not the assertion)"
_emit ""

CHART_VERSION="$(printf '%s\n' "$BLOCK1_OUT" | awk -F': *' '/^version:/{print $2; exit}')"
_emit "SUBSTITUTION MADE:"
_emit "  SEALED_SECRETS_CHART_VERSION carried from block 1 -> ${SEALED_SECRETS_CHART_VERSION:-<unset>}"
_emit ""

if [ -z "$CHART_VERSION" ]; then
  _emit "EXCEPTION: could not parse a chart version out of block 1's own output."
  _emit "           This is a change in the OCI registry's output shape, not a"
  _emit "           cluster problem. Handing back rather than guessing."
  exit 3
fi

# --- block 2: the install, with the ONLY substitution this path makes -------
if ! CMD2="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm install sealed-secrets' 2>/dev/null)"; then
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 2, at ${REF}."
  exit 3
fi
SHA2="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'helm install sealed-secrets' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 2 "$SHA2"
verbatim "$CMD2"

CMD2_SUBST="$CMD2"   # no substitution: the page derives and exports the version
_emit "--- run with the substitution above, otherwise byte-for-byte ---------"
printf '%s\n' "$CMD2_SUBST" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
_emit "----------------------------------------------------------------------"

execute_begin "the documented helm install of sealed-secrets"
bash -c "$CMD2_SUBST" 2>&1 | sed 's/^/    | /'
execute_end "${PIPESTATUS[0]}"
RC2="${PIPESTATUS[0]}"
_emit "(block 2 exited ${RC2}; the exit code is not the assertion)"
_emit ""

# --- block 3: the page's own stated success condition -----------------------
if ! CMD3="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'readyReplicas' 2>/dev/null)"; then
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 3, at ${REF}."
  exit 3
fi
SHA3="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'readyReplicas' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 3 "$SHA3"
verbatim "$CMD3"

# Wait a moment for the Deployment to reconcile before reading it; the page's
# command has no built-in wait, unlike ArgoCD's step, so give it the same
# grace a reader watching a slow pull would give it by hand.
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  rr="$(bash -c "$CMD3" 2>/dev/null || true)"
  [ "$rr" = "1" ] && break
  sleep 10
done

BLOCK3_OUT="$(bash -c "$CMD3" 2>&1)"
_emit "$(printf '%s' "$BLOCK3_OUT" | sed 's/^/    | /')"
_emit ""

# Read independently of the captured transcript above, same reasoning as P04:
# a future reordering of block 3 cannot silently defeat the check.
ready_replicas() {
  kubectl --context="$KUBE_CONTEXT" -n kube-system get deployment sealed-secrets -o \
    jsonpath='{.status.readyReplicas}' 2>&1
}

# --- the page's own stated success condition: "Prints `1`." -----------------
# THE RISKY HALF (per the run sheet): this assertion resolves ONLY because
# block 2, run verbatim above IN THIS SAME RUN, happened to name the release
# `sealed-secrets`. The page never states the release name is load-bearing;
# it reads as an incidental consequence of the install command matching the
# check command. A reader who renamed the release (`helm install my-ss ...`,
# a common Helm habit when running more than one instance of a chart) would
# have a healthy controller and a permanently empty result from this exact
# command. See does_not_prove.
assert_artifact \
  "deployment/sealed-secrets (namespace kube-system)  .status.readyReplicas" \
  "ready_replicas" \
  "1"

# --- block 4: back up the controller key, then the page's own count check --
if ! CMD4="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'sealed-secrets-key-BACKUP.yaml' 2>/dev/null)"; then
  _emit "EXCEPTION: ${PAGE} carries no '${SECTION}' section, block 4, at ${REF}."
  exit 3
fi
SHA4="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing 'sealed-secrets-key-BACKUP.yaml' --sha)"
provenance "$REF" "$PAGE" "$SECTION" 4 "$SHA4"
verbatim "$CMD4"

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-p05-backup.XXXXXX")"
BLOCK4_OUT="$(cd "$BACKUP_DIR" && bash -c "$CMD4" 2>&1)"
RC4=$?
printf '%s\n' "$BLOCK4_OUT" | sed 's/^/    | /'
_emit "(block 4 exited ${RC4}; the exit code is not the assertion)"
_emit ""

BACKUP_FILE="${BACKUP_DIR}/sealed-secrets-key-BACKUP.yaml"

# Assert on the artefact the command was supposed to produce, never on RC4:
# a non-empty file is the only evidence the redirect actually captured
# something rather than an empty API response that still exits 0.
backup_file_nonempty() {
  if [ -s "$BACKUP_FILE" ]; then
    printf 'non-empty (%s bytes)' "$(wc -c < "$BACKUP_FILE" | tr -d ' ')"
  else
    printf 'EMPTY or missing'
  fi
}
backup_bytes="$(wc -c < "$BACKUP_FILE" 2>/dev/null | tr -d ' ')"
assert_artifact \
  "${BACKUP_FILE}  (file written by block 4's redirect)" \
  "backup_file_nonempty" \
  "non-empty (${backup_bytes} bytes)"

# --- the page's own literal count check --------------------------------------
# "Success condition: the count is at least 1, AND you have moved the file
# somewhere the cluster's failure does not reach." Only the first clause is a
# cluster artefact; the second is a human action this harness cannot perform
# on a disposable guest, and is named below rather than silently dropped.
tls_key_count_atleast1() {
  local n
  n="$(grep -c 'tls.key' "$BACKUP_FILE" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
    printf 'count >= 1 (actual %s)' "$n"
  else
    printf 'count < 1 (actual %s)' "${n:-0}"
  fi
}
tls_key_n="$(grep -c 'tls.key' "$BACKUP_FILE" 2>/dev/null || echo 0)"
assert_artifact \
  "grep -c 'tls.key' ${BACKUP_FILE}" \
  "tls_key_count_atleast1" \
  "count >= 1 (actual ${tls_key_n})"

rm -rf "$BACKUP_DIR" 2>/dev/null || true

does_not_prove \
  "That the page's own success condition names a load-bearing constraint. \`kubectl -n kube-system get deployment sealed-secrets\` resolves ONLY because block 2, run verbatim in this same script, happens to install the release under that exact name. Nothing on the page states the release name matters; a reader who installs under a different release name gets a healthy controller this exact command can never find, and the page gives them no way to know that from its own text." \
  "That prerequisites.md documents an independent second route. It does not: confirmed before writing this script that prerequisites.md carries zero fenced bash blocks on ${REF} and no numbered '§3' heading at all. It is a signpost that links to this same fresh-install.md section. existing-cluster.md Check 6 and administration/secrets.md both cross-reference the same anchor rather than duplicating a command. This path tests the one route that exists." \
  "That you have actually moved the key backup off this cluster. The page's own success condition has two clauses; only 'the count is at least 1' is a cluster artefact this harness can assert on. 'You have moved the file somewhere the cluster's failure does not reach' is a human action on a disposable guest and is not, and cannot be, checked here." \
  "That the backup restores. Proving it decrypts a real SealedSecret is administration/secrets.md's separately-stated 'Prove it once' step and a larger procedure than this one." \
  "That the chart version this run resolved (Bitnami's current tag) is the one every reader gets. Same caveat as B7 and P04: deliberately not pinned." \
  "Anything about the controller's key ROTATION behaviour, or about node-local or multi-node topology."

parity_caveat \
  "Guest is an Ubuntu cloud image on KubeVirt, amd64. The harness runner is arm64; that caveat is about the runner, not the cluster under test. No claim is made about x86 openSUSE MicroOS."

path_finish

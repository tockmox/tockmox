#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P12 ... `docs/administration/bring-your-own-ca.md`, run. The page says of itself that it has not been
# executed. This path runs its ten bash blocks, VERBATIM, out of the page at the ref under test (lib/extract-block.sh,
# never retyped), pasted into an interactive zsh the way P09 does, against the install P09 made on the same throwaway.
# It runs AFTER P09 and only when P09 ended PASS. It does not need P11 (the recovery path) to have run, and the lane
# runs it after P11 so that swapping the CA cannot disturb it.
#
# THE PREREQUISITE, then THE TEN BLOCKS. The page's "Before you begin" table asks for secrets/sealed-secrets-cert.pem in the
# site repository and for the sealed-secrets key escrowed (docs/operations/sealed-secrets-key-escrow.md). This path
# meets both the documented way, as step S00, before block 1, and only when the certificate file is absent:
#
#   0  Escrow page, step 2   the key export: `tockmox-install.sh bootstrap-secrets --mode reuse`, run as printed (its
#                            --dry-run) and then with --dry-run removed, as the page says. That run saves the public
#                            certificate as secrets/sealed-secrets-cert.pem. The block comes from the escrow page (the
#                            page the table row links), extracted, never retyped. install.md's copy of the block (the
#                            one P09's S14f runs) is the same command with a fixed backup path; it is not used because
#                            the escrow page can be run as printed plus the edit it names itself, so nothing is lost.
#
# THE TEN BLOCKS, in the order they run (the page's order, except that the adoption pair in step 4 runs before step 3:
# the two are alternatives that write the same file, so the adoption is read and sealed first, kept aside, and the
# supplied-CA seal then leaves the file that is delivered):
#
#   1  Before you begin    export CA_CERT CA_KEY SITE_REPO KUBE_CONTEXT; "inputs found"
#   2  Step 1              find cert-manager's namespace
#   3  Step 1              export PLATFORM_NS
#   4  Step 2              check the CA material (subject, end date, fingerprint, CA:TRUE, key matches, unencrypted)
#   6  Step 4              adopt the chart's CA: read tockmox-ca-root, seal it as site-ca-root
#   7  Step 4              the fingerprint of the certificate read
#   5  Step 3              seal the supplied key (the file that is delivered)
#   8  Step 5              the issuer is Ready; every Certificate is True on site-ca
#   9  Step 5              a certificate that was issued: its ca.crt fingerprint, and openssl verify against the CA
#   10 Step 5              one CA issuer, site-ca with site-ca-root
#
# THE PAGE'S SUCCESS CONDITIONS ARE THE ASSERTIONS. The two that matter: the fingerprint the page reads out of an
# issued certificate's ca.crt equals the fingerprint of the CA this path generated, and that issued certificate
# verifies against the CA file with openssl. Both are compared with a value held outside the cluster before the
# blocks ran. The page's own words: "Assert on a certificate that was issued, not on the issuer's Ready condition."
#
# GLUE, each labelled GLUE in the log and none of it page text:
#   - the CA. The page tells the reader to bring one and does not say how to make one, so openssl makes a throwaway
#     (EC P-256, CA:TRUE, keyCertSign, no passphrase) under the state directory. Its key never leaves this host except
#     sealed.
#   - the prerequisite (S00): ESCROW_DIR (a directory under the state directory), AGE_PUBLIC_KEY (from a throwaway age
#     identity: P09's, ${TOCKMOX_P09_STATE}/p09-age-identity.txt, when it exists, else one made there), and the three
#     typed confirmations (the context name, the API server, the controller NAMESPACE/NAME) through an answers file,
#     as P09 does for the same block. The block is run through the same paste-into-zsh runner as the rest.
#   - the YOU SUPPLY values of block 1 and block 3 (paths, the namespace block 2 printed) and block 9 (an Ingress's TLS
#     Secret, taken from the first Ingress that has one).
#   - the commit. The page ends step 4 with "commit ... and let ArgoCD sync" and gives no command. The harness writes
#     the page's YAML blocks (also extracted, not retyped) into the site repository, commits the four files (and the
#     sealing certificate, when S00 just put it into the repository), pushes to origin, and asks ArgoCD to refresh. The two values snippets are MERGED into the generated files, because
#     appending the global one as printed repeats the top-level key (a row pins that as a known defect).
#   - the waits, each bounded, each recorded in the notes with what it waited for.
#
# WHEN IT RUNS. run.sh discovers paths/P*.sh and gives this one P09's route group, so a plain run.sh reaches it. It does
# not run there unless P09's state exists. It needs TOCKMOX_P09_STATE, a p09-passed marker in it, the site repository
# P09 exported (SITE_REPO, in P09's session.env) and a git remote named origin on that repository. Any of them missing
# is BLOCKED with the reason, before any call to a cluster. The sealing certificate is NOT a precondition: on this
# route P09 mints with tools/mint-secrets.sh and skips S14f, the only place P09 runs the key export, so the file can
# never be there at the start. When it is absent S00 runs the escrow block (and needs TOCKMOX, which P09's session
# exported, and the installer under it, else BLOCKED); when it is present S00 logs one NOTE and runs nothing. If the
# block ran and the certificate is still absent, that is a FAIL row, not BLOCKED. The remote is the last
# precondition on purpose: on the built-in forge the site has no remote and main takes pull requests only (site-forge.md),
# which a harness cannot make an approver approve, so this path runs on the external route.
#
# IT CHANGES THE INSTALL'S CA. Afterwards the cluster issues from the CA this path generated, whose key exists only
# in its state directory and sealed in the site repository. Do not run it on an install you mean to keep.
#
# ITS OWN STATE AND BUDGET. State goes under ${TOCKMOX_P09_STATE}/p12. TOCKMOX_P12_BUDGET (seconds, default 150) is
# this path's own yield point: past it, with steps remaining, the path exits 75 and is called again.

# shellcheck disable=SC2016  # the replayed expressions and the awk program are literal text
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null  # read at run time, from beside this file
. "${HERE}/../lib/assert.sh"

path_begin "P12-bring-your-own-ca" \
  "after P09: docs/administration/bring-your-own-ca.md, ten blocks pasted into zsh: place a supplied CA, adopt the chart's, prove an issued certificate chains to it"

# --- preconditions: a declared environmental constraint (BLOCKED), not a failure and not silence ---
P09_STATE="${TOCKMOX_P09_STATE:-}"
blocked() { # REASON
  _emit "BLOCKED:  ${1}"
  _emit "          This path runs after P09, on the same cluster, from P09's state directory (see the header)."
  path_outcome BLOCKED "$1"
  exit 0
}
[ -n "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not set, so there is no P09 install on this cluster to read"
[ -d "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not a directory (${P09_STATE})"
[ -f "${P09_STATE}/p09-passed" ] || blocked "P09 did not end PASS on this state directory (no p09-passed marker in it)"
# the site repository P09 generated: its session carries the SITE_REPO that 1c exported
SITE_LINE="$(grep -E '^(export|declare -x) SITE_REPO=' "${P09_STATE}/session.env" 2>/dev/null | tail -1 || true)"
[ -n "$SITE_LINE" ] || blocked "P09's session in ${P09_STATE} holds no SITE_REPO, so there is no site repository to place a CA in"
SITE_REPO="$( eval "${SITE_LINE#declare -x }" 2>/dev/null; printf '%s' "${SITE_REPO:-}" )"
[ -n "$SITE_REPO" ] && [ -d "$SITE_REPO" ] || blocked "the site repository P09 recorded is not a directory (${SITE_REPO:-unset})"
git -C "$SITE_REPO" remote get-url origin >/dev/null 2>&1 \
  || blocked "the site repository has no remote named origin: on the built-in forge main takes pull requests only, so the page's commit cannot be delivered by a harness. Run the external route"
export SITE_REPO
CERT_REL="secrets/sealed-secrets-cert.pem"
CERT_FILE="${SITE_REPO}/${CERT_REL}"

# every kubectl call below names its cluster with --context from this variable, and an empty value is
# refused rather than falling back to the current context (docs/deployment/fresh-install.md, "Name the
# cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"
export KUBE_CONTEXT
REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"

STATE="${P09_STATE}/p12"
BUDGET="${TOCKMOX_P12_BUDGET:-150}"
SEALED_WAIT="${TOCKMOX_P12_SEALED_WAIT:-600}"
REISSUE_WAIT="${TOCKMOX_P12_REISSUE_WAIT:-900}"
WS_SHELL="${TOCKMOX_WS_SHELL:-zsh}"
T0=$(date +%s)
mkdir -p "$STATE/work" "$STATE/ca"
P12_TOOLS="kubectl kubeseal openssl git python3"
[ "$WS_SHELL" = zsh ] && P12_TOOLS="${P12_TOOLS} ${ZSH:-zsh}"
# the prerequisite step makes an age key pair to export to, only when it will run
[ -e "$CERT_FILE" ] || [ -f "${STATE}/S00-escrow.before" ] || P12_TOOLS="${P12_TOOLS} age-keygen"
for t in $P12_TOOLS; do
  command -v "$t" >/dev/null 2>&1 || { _emit "INFRA: '$t' is not on PATH"; path_outcome INFRA_ERROR "missing $t"; exit 1; }
done

FROM_TREE="${TOCKMOX_P12_FROM_TREE:-${TOCKMOX_P09_FROM_TREE:-0}}"
PAGE="docs/administration/bring-your-own-ca.md"
PAGE_FILE="${TOCKMOX_P12_PAGE_FILE:-${HERE}/../../../${PAGE}}"
ESCROW_PAGE="docs/operations/sealed-secrets-key-escrow.md"
ESCROW_PAGE_FILE="${TOCKMOX_P12_ESCROW_PAGE_FILE:-${HERE}/../../../${ESCROW_PAGE}}"
ESCROW_SECTION="## 2. Export the key ... Required"
SECTION="# Bring your own certificate authority"
S4="## 4. Move the key without re-minting it ... Required"
EXTRACT="${HERE}/../lib/extract-block.sh"
PASTE="${HERE}/../lib/zsh-paste.py"
VERDICT_PY="${HERE}/../lib/p12-byo-ca.py"
verdict() { python3 -I "$VERDICT_PY" "$@"; }

# ------------------------------------------------------------- state helpers
# The same shape as P09's and P11's: a step is skipped once done, a verdict is written to verdicts.tsv as it is made and
# replayed through assert_artifact at the end, and a spent budget exits 75 so the path is called again.
done_step() { [ -f "${STATE}/${1}.done" ]; }
mark_done()  { : > "${STATE}/${1}.done"; }
record() { # STEP DESC EXPECTED ACTUAL [xfail]
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "${STATE}/verdicts.tsv"
  if [ "${5:-}" = "xfail" ]; then
    _emit "RECORDED (xfail): ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"
  elif [ "$3" = "$4" ]; then _emit "RECORDED PASS: ${2}  [${4}]"
  else _emit "RECORDED FAIL: ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"; fi
}
note() { _emit "NOTE:     $*"; printf 'NOTE\t%s\n' "$*" >> "${STATE}/notes.txt"; }
budget_left() { [ $(( $(date +%s) - T0 )) -lt "$BUDGET" ]; }
yield() { _emit "BUDGET:   spent; ${1} step(s) remain. Call this path again to continue."; exit 75; }

# ------------------------------------------------------ session environment
# Exports a block makes are captured and re-applied so the next block sees them, as the reader's one terminal does.
ENVFILE="${STATE}/session.env"
apply_exports() {
  local line nv name
  while IFS= read -r line; do
    case "$line" in "export "*|"declare -x "*) : ;; *) continue ;; esac
    nv="${line#export }"; nv="${nv#declare -x }"; name="${nv%%=*}"
    case "$name" in
      PATH|PWD|OLDPWD|HOME|SHLVL|IFS|_|PS1|TERM|ZDOTDIR|BASH*|ZSH*|KUBECONFIG|KUBE_CONTEXT|ASSERT_REPORT|TOCKMOX_*|OUTCOME_RECEIPT_DIR|ABSENCE_RECEIPT_DIR|MODULE_PATH) continue ;;
      *[!A-Za-z0-9_]*|"") continue ;;
    esac
    [ "$nv" = "$name" ] && continue
    eval "export ${nv}"
  done < "$1"
}
[ -f "$ENVFILE" ] && apply_exports "$ENVFILE"

# --------------------------------------------------------------- the page
# xblock LANG SECTION NEEDLE ... one fenced block of the page, verbatim; refuses on none or several
xblock() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$PAGE_FILE" --section "$2" --lang "$1" --containing "$3" 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$PAGE" --section "$2" --lang "$1" --containing "$3" 2>/dev/null; fi
}
xblock_sha() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$PAGE_FILE" --section "$2" --lang "$1" --containing "$3" --sha 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$PAGE" --section "$2" --lang "$1" --containing "$3" --sha 2>/dev/null; fi
}

# eblock / eblock_sha ... the same, for the escrow page the prerequisite row links
eblock() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$ESCROW_PAGE_FILE" --section "$ESCROW_SECTION" --lang bash --containing "$1" 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$ESCROW_PAGE" --section "$ESCROW_SECTION" --lang bash --containing "$1" 2>/dev/null; fi
}
eblock_sha() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$ESCROW_PAGE_FILE" --section "$ESCROW_SECTION" --lang bash --containing "$1" --sha 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$ESCROW_PAGE" --section "$ESCROW_SECTION" --lang bash --containing "$1" --sha 2>/dev/null; fi
}

finish_path() {
  # The execute phase is a per-invocation fact in lib/assert.sh; a resumed final call that only replays would
  # otherwise be refused a PASS. Persist the last execute_end's rc and re-declare it from state, saying so.
  [ "$EXEC_PHASE_COMPLETED" -eq 1 ] && printf '%s' "$EXEC_LAST_RC" > "${STATE}/last-execute-rc"
  if [ "$EXEC_PHASE_STARTED" -eq 0 ] && [ -f "${STATE}/last-execute-rc" ]; then
    execute_begin "replayed from state: the page's blocks ran in earlier invocations of this path (see the STEP logs above in the same report)"
    execute_end "$(cat "${STATE}/last-execute-rc")"
  fi
  _emit ""; _emit "=== REPLAY of every recorded verdict through lib/assert.sh ==========="
  local st desc exp act flag _replay_val
  while IFS=$'\t' read -r st desc exp act flag; do
    _replay_val="$act"
    if [ "$flag" = "xfail" ]; then
      assert_artifact_xfail "[${st}] ${desc}" 'printf %s "$_replay_val"' "$exp"
    else
      assert_artifact "[${st}] ${desc}" 'printf %s "$_replay_val"' "$exp"
    fi
  done < "${STATE}/verdicts.tsv"
  _emit ""; _emit "NOTES (from the run):"; sed 's/^NOTE\t/  - /' "${STATE}/notes.txt" 2>/dev/null | while IFS= read -r l; do _emit "$l"; done

  does_not_prove \
    "That the page works with a CA this path did not make: the CA is a throwaway EC key made by openssl. A corporate CA, an intermediate (the chain the page says it believes but did not check) and an RSA key are not exercised." \
    "That the adoption of the chart's key is lossless: block 6 and 7 are run and the sealed file is read, but the sealed adoption file is set aside and never applied, so the claim that the key bytes arrive unchanged is shown only for the supplied CA (the unsealed site-ca-root key matches the generated key), not for the chart's. The fingerprint block 7 prints is read from the source Secret, not from anything sealed." \
    "That a console certificate was re-issued without a client re-trust or that consoles roll to pick up the new in-cluster trust: one Ingress's Secret is read, the consoles are not restarted, no browser is involved, and day-2.md's restart is not run." \
    "That going back to the chart's CA works, or what the chart's own CA does at renewal: those sections have no block and are not touched." \
    "That the built-in forge route works: the page's commit is a pull request there, which a harness does not open or approve. This path runs on the external route only." \
    "That the page's illustrative YAML can be pasted as printed: the two values snippets are merged by the harness (GLUE), because the global one repeats a key the generated file already has."

  parity_caveat \
    "The workstation shell was ${WS_SHELL} on Linux, pasted through a pty with bracketed paste, against a single-node KubeVirt guest. kubeseal, openssl and base64 are the runner's, not the macOS builds the page is written for (base64 -d and openssl 3 output formats are the Linux ones)."

  path_finish
}

# run_ws NAME TEXT [ANSWERFILE] ... paste one WORKSTATION block into the session shell. Transcript to NAME.out, status to NAME.rc.
# ANSWERFILE lines are PATTERN<TAB>ANSWER, typed when PATTERN appears (zsh-paste.py); the bash fallback has no terminal.
run_ws() {
  local name="$1" text="$2" answers="${3:-}" rc bf envout
  bf="${STATE}/${name}.block"; printf '%s\n' "$text" > "$bf"
  envout="${STATE}/${name}.env"; rm -f "$envout"
  _emit "--- verbatim from the page (${name}) -----------------------------"
  printf '%s\n' "$text" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
  _emit "--- pasted into an interactive ${WS_SHELL} ------------------------------"
  if [ "$WS_SHELL" = "zsh" ]; then
    ( cd "${STATE}/work" && ZSH_PASTE_ENVOUT="$envout" ZSH_PASTE_TIMEOUT="${ZSH_PASTE_TIMEOUT:-600}" \
      python3 "$PASTE" "$bf" ${answers:+"$answers"} ) > "${STATE}/${name}.out" 2>&1; rc=$?
  else
    ( cd "${STATE}/work" && bash -c "$(cat "$bf")"$'\n''__rc=$?; export -p > "'"$envout"$'"; exit $__rc' ) > "${STATE}/${name}.out" 2>&1 </dev/null; rc=$?
  fi
  printf '%s' "$rc" > "${STATE}/${name}.rc"
  sed 's/^/    | /' "${STATE}/${name}.out" | while IFS= read -r l; do _emit "$l"; done
  _emit "    (exit ${rc}; the exit code is evidence, not the assertion)"
  if [ -f "$envout" ]; then
    apply_exports "$envout"
    { [ -f "$ENVFILE" ] && cat "$ENVFILE"; cat "$envout"; } | awk -F= '/^(export|declare -x) /{k=$1; line[k]=$0; if(!(k in seen)){seen[k]=1; order[++n]=k}} END{for(i=1;i<=n;i++) print line[order[i]]}' > "${ENVFILE}.tmp" && mv "${ENVFILE}.tmp" "$ENVFILE"
  fi
  return "$rc"
}
out_of() { cat "${STATE}/${1}.out" 2>/dev/null; }

# page_block NAME SECTION LANG NEEDLE ... provenance, the verbatim text into BT, or a recorded failure that stops the path
BT=""
page_block() {
  local name="$1" sec="$2" lang="$3" needle="$4" sha
  _emit ""; _emit "--- ${name}: the page's block containing: ${needle}"
  sha="$(xblock_sha "$lang" "$sec" "$needle")" && BT="$(xblock "$lang" "$sec" "$needle")" && [ -n "$BT" ] || {
    record "$name" "the step's block resolves to exactly one block of ${PAGE} (missing or ambiguous)" "one block" "none or several"
    _emit "FAIL:     ${name}'s block did not resolve; replaying the verdicts so far and stopping here"
    finish_path; exit $?
  }
  provenance "$( [ "$FROM_TREE" = "1" ] && echo "WORKTREE (uncommitted; not evidence about ${REF})" || echo "$REF" )" "$PAGE" "$sec: ${needle}" "-" "$sha"
}
# run_page NAME DESC ... run BT as a documented block inside an execute phase
run_page() {
  local name="$1"
  execute_begin "bring-your-own-ca.md ${2}"; run_ws "$name" "$BT"; execute_end $?
}
last_line() { out_of "$1" | grep . | tail -1 | tr -d ' \r'; }

# ---------------------------------------------------------------------------- assumed live shapes
# names the chart renders (charts/tockmox-platform/values.yaml certIssuer.selfSigned): the chart's issuer and CA Secret
CHART_CA_SECRET=tockmox-ca-root
ISSUER=site-ca
SITE_SECRET=site-ca-root
ARGO_NS=argocd

# ============================================================== THE STEPS
CA_CRT="${STATE}/ca/ca.crt"; CA_KEYF="${STATE}/ca/ca.key"

# S00 ... the prerequisite the page's table names: secrets/sealed-secrets-cert.pem, written when the installer's key export
# runs (docs/operations/sealed-secrets-key-escrow.md, step 2). Only when the file is absent.
S=S00-escrow
sealed_sums() { ( cd "${SITE_REPO}/secrets" 2>/dev/null && find . -type f -name '*.sealed.yaml' | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ); }
if ! done_step "$S"; then budget_left || yield "S00+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ -e "$CERT_FILE" ] && [ ! -f "${STATE}/${S}.before" ]; then
    note "S00: ${CERT_REL} is already in the site repository, so the key-export block of the prerequisite row is not run and the installer is not called"
  else
    [ -f "${STATE}/${S}.before" ] || {
      # the installer clone: P09's session exported TOCKMOX (Set these once), read from there the way SITE_REPO is; an environment value is the fallback
      TOCKMOX_LINE="$(grep -E '^(export|declare -x) TOCKMOX=' "${P09_STATE}/session.env" 2>/dev/null | tail -1 || true)"
      [ -z "$TOCKMOX_LINE" ] || TOCKMOX="$( eval "${TOCKMOX_LINE#declare -x }" 2>/dev/null; printf '%s' "${TOCKMOX:-}" )"
      [ -n "${TOCKMOX:-}" ] && [ -x "${TOCKMOX}/install/tockmox-install.sh" ] \
        || blocked "${CERT_REL} is absent from the site repository and the installer that writes it is not at \$TOCKMOX/install/tockmox-install.sh (TOCKMOX=${TOCKMOX:-unset}); P09's session.env exports TOCKMOX"
      _emit "PREREQUISITE: the page's table wants ${CERT_REL} in the site repository and the sealing key escrowed; the file is absent"
      _emit "              (this route mints with mint-secrets.sh and skips P09's S14f, the only place P09 exports the key). The documented block is run."
      sealed_sums > "${STATE}/${S}.before"
      # the throwaway age identity: P09's, when it made one (S14f, built-in route only), else this path makes one beside it
      AGE_ID="${P09_STATE}/p09-age-identity.txt"
      [ -s "$AGE_ID" ] || age-keygen -o "$AGE_ID" >/dev/null 2>&1
      AGE_PUBLIC_KEY="$(age-keygen -y "$AGE_ID")"; export AGE_PUBLIC_KEY
      _emit "GLUE: AGE_PUBLIC_KEY from a throwaway age identity the harness made (${AGE_ID}); a reader exports their own"
      ESCROW_DIR="${STATE}/escrow"; mkdir -p "$ESCROW_DIR"; export ESCROW_DIR TOCKMOX
      _emit "GLUE: ESCROW_DIR is ${ESCROW_DIR}, outside the site repository (the installer refuses to write the backup inside it)"
      SERVER_V="$(kubectl --context="$KUBE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
      CTRL_V="$(kubectl --context="$KUBE_CONTEXT" get deploy -A -l app.kubernetes.io/name=sealed-secrets -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}' 2>/dev/null)"
      printf 'Type the context name\t%s\nType the API server\t%s\nType NAMESPACE/NAME\t%s\n' "$KUBE_CONTEXT" "$SERVER_V" "$CTRL_V" > "${STATE}/${S}.answers"
      _emit "GLUE: the context, API server and controller confirmations are typed at the terminal, as a reader would"
      eblock_sha 'bootstrap-secrets --mode reuse' > "${STATE}/${S}.sha" && BT="$(eblock 'bootstrap-secrets --mode reuse')" && [ -n "$BT" ] || {
        record "$S" "the prerequisite's block resolves to exactly one block of ${ESCROW_PAGE} (missing or ambiguous)" "one block" "none or several"
        _emit "FAIL:     ${S}'s block did not resolve; replaying the verdicts so far and stopping here"
        finish_path; exit $?
      }
      provenance "$( [ "$FROM_TREE" = "1" ] && echo "WORKTREE (uncommitted; not evidence about ${REF})" || echo "$REF" )" "$ESCROW_PAGE" "$ESCROW_SECTION: bootstrap-secrets --mode reuse" "-" "$(cat "${STATE}/${S}.sha")"
      printf '%s\n' "$BT" > "${STATE}/${S}.printed"
      execute_begin "sealed-secrets-key-escrow.md step 2, the key export as printed (its --dry-run)"; run_ws "${S}-dry" "$BT"; execute_end $?
      record "$S" "the dry run changes nothing: ${CERT_REL} is still absent" "absent" "$( [ -e "$CERT_FILE" ] && echo present || echo absent )"
      BT="$(printf '%s\n' "$BT" | python3 -c 'import sys; L=sys.stdin.read().rstrip("\n").split("\n"); i=L.index("  --dry-run"); L[i-1]=L[i-1].rstrip(" \\"); del L[i]; print("\n".join(L))')"
      _emit "EDIT AS THE PAGE SAYS: --dry-run removed to run for real"
      execute_begin "sealed-secrets-key-escrow.md step 2, the key export (--mode reuse)"
      ZSH_PASTE_TIMEOUT=900 run_ws "$S" "$BT" "${STATE}/${S}.answers"; execute_end $?
    }
    cert_state="absent or not a PEM certificate"
    [ -s "$CERT_FILE" ] && openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 && cert_state="a PEM certificate"
    record "$S" "the key export saved ${CERT_REL} into the site repository, and it is a PEM certificate" "a PEM certificate" "$cert_state"
    bk="$(ls -1 "${STATE}/escrow"/sealed-secrets-key-*.age 2>/dev/null | head -1)"
    record "$S" "the encrypted key backup exists and is not plain YAML (no tls.key, no backup marker line in clear)" "yes" \
      "$( [ -n "$bk" ] && [ -s "$bk" ] && ! grep -q -e 'tls.key' -e 'tockmox-sealed-secrets-key-backup' "$bk" && echo yes || echo no )"
    record "$S" "page success condition: the key export's run ends with 'encrypted key backup written:' and a path" "yes" \
      "$( [ "$(out_of "$S" | grep -c 'encrypted key backup written: ')" -ge 1 ] && echo yes || echo no )"
    sealed_sums > "${STATE}/${S}.after"
    record "$S" "every *.sealed.yaml in secrets/ is byte-identical to before the key export (the page promises it for --mode reuse)" "unchanged" \
      "$( cmp -s "${STATE}/${S}.before" "${STATE}/${S}.after" && echo unchanged || echo "changed: $(diff "${STATE}/${S}.before" "${STATE}/${S}.after" | grep -c '^[<>]') line(s) differ" )"
    note "S00: the key export ran because ${CERT_REL} was absent; the sealed files listed before and after: $(grep -c . "${STATE}/${S}.before" | tr -d ' ') and $(grep -c . "${STATE}/${S}.after" | tr -d ' ')"
  fi
  mark_done "$S"
fi

# S01 ... the CA (GLUE) and the page's "Before you begin" block.
S=S01-inputs
if ! done_step "$S"; then budget_left || yield "S01+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ ! -s "$CA_CRT" ] || [ ! -s "$CA_KEYF" ]; then
    _emit "GLUE: the page tells the reader to bring a CA and not how to make one; openssl makes a throwaway (EC P-256, CA:TRUE, keyCertSign, no passphrase). Not page text."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
      -subj "/CN=Tockmox executed-docs throwaway CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "$CA_KEYF" -out "$CA_CRT" >/dev/null 2>&1
  fi
  openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 | verdict fingerprint > "${STATE}/ca/fp"
  openssl pkey -in "$CA_KEYF" -pubout | openssl sha256 | awk '{print $NF}' > "${STATE}/ca/pubhash"
  note "S01: the generated CA's fingerprint, held outside the cluster: $(cat "${STATE}/ca/fp")"
  page_block "$S" "$SECTION" bash 'inputs found'
  BT="${BT//YOUR_CA_CERT_PATH/$CA_CRT}"; BT="${BT//YOUR_CA_KEY_PATH/$CA_KEYF}"
  BT="${BT//YOUR_SITE_REPO_PATH/$SITE_REPO}"; BT="${BT//YOUR_KUBE_CONTEXT/$KUBE_CONTEXT}"
  _emit "SUBSTITUTION: the four YOU SUPPLY paths and the context (CA files are the generated ones)"
  run_page "$S" "Before you begin"
  record "$S" "before you begin: 'inputs found' printed" "1" "$(out_of "$S" | verdict count --line 'inputs found')"
  mark_done "$S"
fi
GEN_FP="$(cat "${STATE}/ca/fp" 2>/dev/null)"

# S02 ... step 1: the namespace cert-manager's Secret lives in.
S=S02-namespace
if ! done_step "$S"; then budget_left || yield "S02+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  page_block "$S" "$SECTION" bash 'get pods -A'
  run_page "$S" "step 1, find the namespace"
  printed="$(out_of "$S" | verdict namespace)"
  # the independent read: where the chart's CA Secret actually is (it is placed in cert-manager's cluster resource namespace)
  want="$(kubectl --context="$KUBE_CONTEXT" get secret -A --field-selector "metadata.name=${CHART_CA_SECRET}" -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
  record "$S" "step 1: the command prints one namespace, the one holding the Secret ${CHART_CA_SECRET}" "${want:-(${CHART_CA_SECRET} not found)}" "$printed"
  page_block "${S}-export" "$SECTION" bash 'export PLATFORM_NS='
  BT="${BT//YOUR_PLATFORM_NAMESPACE/$printed}"
  _emit "SUBSTITUTION: YOUR_PLATFORM_NAMESPACE -> ${printed}  (the page: export the namespace it printed)"
  run_page "${S}-export" "step 1, export PLATFORM_NS"
  record "$S" "step 1: PLATFORM_NS is exported into the session as printed" "PLATFORM_NS=${printed}" "PLATFORM_NS=${PLATFORM_NS:-unset}"
  mark_done "$S"
fi

# S03 ... step 2: the four checks on the generated material.
S=S03-ca-checks
if ! done_step "$S"; then budget_left || yield "S03+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  page_block "$S" "$SECTION" bash 'CA:TRUE'
  run_page "$S" "step 2, check the CA material"
  record "$S" "step 2: a subject prints" "1" "$(out_of "$S" | grep -c '^subject=' | tr -d ' ')"
  record "$S" "step 2: the end date prints and is in the future" "future" "$(out_of "$S" | verdict enddate)"
  record "$S" "step 2: the fingerprint printed is the generated CA's, recorded outside the cluster" "$GEN_FP" "$(out_of "$S" | verdict fingerprint)"
  record "$S" "step 2: CA:TRUE prints" "1" "$(out_of "$S" | verdict count --line 'CA:TRUE')"
  record "$S" "step 2: Certificate Sign prints" "1" "$(out_of "$S" | grep -c 'Certificate Sign' | tr -d ' ')"
  record "$S" "step 2: 'key matches certificate' prints" "1" "$(out_of "$S" | verdict count --line 'key matches certificate')"
  record "$S" "step 2: 'unencrypted' prints" "1" "$(out_of "$S" | verdict count --line 'unencrypted')"
  record "$S" "step 2: no passphrase warning prints" "0" "$(out_of "$S" | verdict count --line 'ENCRYPTED: remove the passphrase first')"
  mark_done "$S"
fi

# S04 ... step 4: adopt the chart's CA (blocks 6 and 7). Run before step 3 because both write secrets/site-ca-root.sealed.yaml.
S=S04-adopt
SEALED_FILE="${SITE_REPO}/secrets/site-ca-root.sealed.yaml"
if ! done_step "$S"; then budget_left || yield "S04+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "ORDER: step 4's adoption runs before step 3's seal because they are alternatives writing one file. The adoption's file is read, then set aside."
  # the fingerprint recorded BEFORE the adoption, from the Secret itself (GLUE): step 2 records one from a file, and the adoption path has no file
  kubectl --context="$KUBE_CONTEXT" -n "${PLATFORM_NS:-}" get secret "$CHART_CA_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d > "${STATE}/ca/chart-ca.crt" 2>/dev/null
  openssl x509 -in "${STATE}/ca/chart-ca.crt" -noout -fingerprint -sha256 2>/dev/null | verdict fingerprint > "${STATE}/ca/chart-fp"
  CHART_FP="$(cat "${STATE}/ca/chart-fp")"
  note "S04: GLUE recorded the chart CA's fingerprint before the adoption: ${CHART_FP}"
  rm -f "$SEALED_FILE"
  page_block "$S" "$S4" bash 'python3 -c'
  run_page "$S" "step 4, adopt the chart's CA (seal)"
  record "$S" "step 4 adopt: the last line prints 1 (one SealedSecret)" "1" "$(last_line "$S")"
  record "$S" "step 4 adopt: the file is one SealedSecret naming ${SITE_SECRET} in ${PLATFORM_NS:-}, type tls, with tls.crt and tls.key sealed" \
    "sealed tls Secret ${SITE_SECRET} in ${PLATFORM_NS:-}" "$(verdict sealed --name "$SITE_SECRET" --ns "${PLATFORM_NS:-}" < "$SEALED_FILE" 2>/dev/null)"
  mv "$SEALED_FILE" "${STATE}/adopted-${SITE_SECRET}.sealed.yaml" 2>/dev/null
  page_block "${S}-fp" "$S4" bash "jsonpath='{.data.tls\\.crt}'"
  run_page "${S}-fp" "step 4, the fingerprint of the certificate read"
  record "$S" "step 4 adopt: the fingerprint read equals the one recorded before the adoption" "$CHART_FP" "$(out_of "${S}-fp" | verdict fingerprint)"
  mark_done "$S"
fi

# S05 ... step 3: seal the supplied key. This is the file that is delivered.
S=S05-seal
if ! done_step "$S"; then budget_left || yield "S05+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  rm -f "$SEALED_FILE"
  page_block "$S" "$SECTION" bash 'kubectl --context "$KUBE_CONTEXT" create secret tls'
  run_page "$S" "step 3, seal the supplied key"
  record "$S" "step 3: the last line prints 1 (one SealedSecret)" "1" "$(last_line "$S")"
  record "$S" "step 3: the file is one SealedSecret naming ${SITE_SECRET} in ${PLATFORM_NS:-}, type tls, with tls.crt and tls.key sealed" \
    "sealed tls Secret ${SITE_SECRET} in ${PLATFORM_NS:-}" "$(verdict sealed --name "$SITE_SECRET" --ns "${PLATFORM_NS:-}" < "$SEALED_FILE" 2>/dev/null)"
  record "$S" "step 3: the plaintext key is not in the sealed file" "0" "$(grep -c 'BEGIN' "$SEALED_FILE" 2>/dev/null | tr -d ' ')"
  mark_done "$S"
fi

# S06 ... the commit (GLUE): the page's YAML, written and pushed.
S=S06-deliver
if ! done_step "$S"; then budget_left || yield "S06+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "GLUE: the page ends step 4 with 'commit ... and let ArgoCD sync' and no command. The page's three YAML blocks are extracted"
  _emit "      (not retyped) and written; the two values snippets are merged; the four files (and the sealing certificate, if S00 just put it in) are committed and pushed to origin."
  ISSUER_YAML="$(xblock yaml "$SECTION" 'kind: ClusterIssuer')"
  PLAT_YAML="$(xblock yaml "$SECTION" 'enabled: false')"
  GLOB_YAML="$(xblock yaml "$SECTION" 'certIssuer: site-ca')"
  [ -n "$ISSUER_YAML" ] && [ -n "$PLAT_YAML" ] && [ -n "$GLOB_YAML" ] || {
    record "$S" "the page's three YAML blocks resolve" "three blocks" "missing or ambiguous"; finish_path; exit $?; }
  for y in ISSUER_YAML PLAT_YAML GLOB_YAML; do
    provenance "$( [ "$FROM_TREE" = "1" ] && echo "WORKTREE" || echo "$REF" )" "$PAGE" "yaml block ${y}" "-" "$(printf '%s\n' "${!y}" | sha256sum | cut -d' ' -f1)"
  done
  # where the page says each goes: its first line is a comment naming the path
  ISSUER_PATH="$(printf '%s\n' "$ISSUER_YAML" | sed -n '1s/^# //p')"
  PLAT_PATH="$(printf '%s\n' "$PLAT_YAML" | sed -n '1s/^# //p')"
  GLOB_PATH="$(printf '%s\n' "$GLOB_YAML" | sed -n '1s/^# //p')"
  mkdir -p "$(dirname "${SITE_REPO}/${ISSUER_PATH}")"
  printf '%s\n' "$ISSUER_YAML" > "${SITE_REPO}/${ISSUER_PATH}"
  # the known defect, shown on a copy: the global snippet appended as printed repeats the top-level key, and YAML keeps the last one
  { cat "${SITE_REPO}/${GLOB_PATH}"; printf '%s\n' "$GLOB_YAML"; } > "${STATE}/global-appended.yaml"
  record "$S" "the global.yaml snippet appended as printed leaves one top-level global key (xfail: the generated file already has one, and YAML keeps only the last)" \
    "1" "$(grep -c '^global:' "${STATE}/global-appended.yaml" | tr -d ' ')" xfail
  python3 - "${SITE_REPO}/${GLOB_PATH}" "$GLOB_YAML" <<'PY'
import re, sys
path, snippet = sys.argv[1], sys.argv[2]
want = re.search(r"(?m)^\s+certIssuer:\s*(\S+)\s*$", snippet).group(1)
s = open(path).read()
t, n = re.subn(r"(?m)^(  certIssuer:).*$", r"\1 " + want, s)
assert n == 1, "global.yaml has %d certIssuer lines" % n
open(path, "w").write(t)
PY
  if grep -q '^certIssuer:' "${SITE_REPO}/${PLAT_PATH}"; then
    record "$S" "${PLAT_PATH} has no certIssuer key of its own yet, so the snippet can be appended" "absent" "present"
  else
    printf '\n%s\n' "$PLAT_YAML" >> "${SITE_REPO}/${PLAT_PATH}"
  fi
  record "$S" "${GLOB_PATH}: certIssuer reads ${ISSUER} once and the file still holds internalDomain" "1 1" \
    "$(grep -c "^  certIssuer: ${ISSUER}\$" "${SITE_REPO}/${GLOB_PATH}" | tr -d ' ') $(grep -c '^  internalDomain:' "${SITE_REPO}/${GLOB_PATH}" | tr -d ' ')"
  record "$S" "${PLAT_PATH}: selfSigned.enabled is false" "1" "$(grep -c '^    enabled: false$' "${SITE_REPO}/${PLAT_PATH}" | tr -d ' ')"
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-p12}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-p12@example.invalid}"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  _emit "GLUE: git identity via GIT_AUTHOR_*/GIT_COMMITTER_*"
  # the sealing certificate is committed with the rest of secrets/ (the escrow page says so), but only when it is new or changed
  CERT_ADD=""; [ -n "$(git -C "$SITE_REPO" status --porcelain -- "$CERT_REL" 2>/dev/null)" ] && CERT_ADD="$CERT_REL"
  if [ -n "$CERT_ADD" ]; then _emit "GLUE: ${CERT_REL} is new in the repository (S00 saved it), so it goes in this commit"
  else _emit "GLUE: ${CERT_REL} was already committed, so the commit holds the page's four files"; fi
  execute_begin "GLUE: commit the sealed Secret, the issuer and the two values (and the new sealing certificate) in one commit, push to origin"
  git -C "$SITE_REPO" add "secrets/${SITE_SECRET}.sealed.yaml" "$ISSUER_PATH" "$GLOB_PATH" "$PLAT_PATH" ${CERT_ADD:+"$CERT_ADD"} >/dev/null 2>&1 \
    && git -C "$SITE_REPO" commit -q -m "Place a supplied CA: ${ISSUER} from ${SITE_SECRET}" >/dev/null 2>&1 \
    && git -C "$SITE_REPO" push origin main > "${STATE}/${S}.push" 2>&1
  execute_end $?
  sed 's/^/    | /' "${STATE}/${S}.push" 2>/dev/null | while IFS= read -r l; do _emit "$l"; done
  record "$S" "the commit holds exactly the four files the page names, plus the sealing certificate when S00 put it in the repository, in one commit" \
    "$(printf '%s\n' "$GLOB_PATH" "$PLAT_PATH" "$ISSUER_PATH" "secrets/${SITE_SECRET}.sealed.yaml" ${CERT_ADD:+"$CERT_ADD"} | sort | tr '\n' ' ')" \
    "$(git -C "$SITE_REPO" show --name-only --format= HEAD | sort | tr '\n' ' ')"
  record "$S" "origin's main equals the local HEAD after the push" "$(git -C "$SITE_REPO" rev-parse HEAD)" \
    "$(git -C "$SITE_REPO" ls-remote origin refs/heads/main | cut -f1)"
  mark_done "$S"
fi

# S07 ... let ArgoCD sync, and wait, bounded, for the two things the proof reads.
S=S07-converge
if ! done_step "$S"; then budget_left || yield "S07+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ ! -f "${STATE}/${S}.refreshed" ]; then
    _emit "GLUE: ask ArgoCD to refresh now, rather than wait for its poll"
    kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" annotate applications.argoproj.io --all argocd.argoproj.io/refresh=hard --overwrite > "${STATE}/${S}.refresh" 2>&1
    sed 's/^/    | /' "${STATE}/${S}.refresh" | while IFS= read -r l; do _emit "$l"; done
    : > "${STATE}/${S}.refreshed"
  fi
  # wait 1: the controller unseals site-ca-root into the platform namespace
  [ -f "${STATE}/${S}.deadline1" ] || echo $(( $(date +%s) + SEALED_WAIT )) > "${STATE}/${S}.deadline1"
  while :; do
    kubectl --context="$KUBE_CONTEXT" -n "${PLATFORM_NS:-}" get secret "$SITE_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "${STATE}/${S}.unsealed.crt" 2>/dev/null
    [ -s "${STATE}/${S}.unsealed.crt" ] && break
    [ "$(date +%s)" -ge "$(cat "${STATE}/${S}.deadline1")" ] && break
    budget_left || yield "S07 (waiting for the sealed Secret ${SITE_SECRET} to be unsealed; re-run to keep waiting)"
    sleep 10
  done
  note "S07: waited up to ${SEALED_WAIT}s for the controller to unseal ${SITE_SECRET} in ${PLATFORM_NS:-}; it is $( [ -s "${STATE}/${S}.unsealed.crt" ] && echo present || echo absent )"
  record "$S" "the unsealed ${SITE_SECRET} carries the generated CA's certificate (fingerprint)" "$GEN_FP" \
    "$(openssl x509 -in "${STATE}/${S}.unsealed.crt" -noout -fingerprint -sha256 2>/dev/null | verdict fingerprint)"
  record "$S" "the unsealed ${SITE_SECRET} carries the generated CA's key (public key hash)" "$(cat "${STATE}/ca/pubhash")" \
    "$(kubectl --context="$KUBE_CONTEXT" -n "${PLATFORM_NS:-}" get secret "$SITE_SECRET" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d 2>/dev/null | openssl pkey -pubout 2>/dev/null | openssl sha256 | awk '{print $NF}')"
  # the Secret the proof will read (GLUE): the first Ingress that has a TLS secret
  if [ ! -s "${STATE}/tls-pick" ]; then
    kubectl --context="$KUBE_CONTEXT" get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.tls[0].secretName}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' 'NF==2 && $2!="" {print; exit}' > "${STATE}/tls-pick"
  fi
  TLS_NS_V="$(cut -f1 "${STATE}/tls-pick")"; TLS_SECRET_V="$(cut -f2 "${STATE}/tls-pick")"
  note "S07: GLUE picked the TLS Secret for block 9 from the first Ingress that has one: ${TLS_NS_V:-none}/${TLS_SECRET_V:-none}"
  # wait 2: that Secret is re-issued by the new issuer
  [ -f "${STATE}/${S}.deadline2" ] || echo $(( $(date +%s) + REISSUE_WAIT )) > "${STATE}/${S}.deadline2"
  reissued=no
  if [ -n "$TLS_SECRET_V" ]; then
    while :; do
      kubectl --context="$KUBE_CONTEXT" -n "$TLS_NS_V" get secret "$TLS_SECRET_V" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "${STATE}/${S}.leaf.crt" 2>/dev/null
      if [ -s "${STATE}/${S}.leaf.crt" ] && openssl verify -CAfile "$CA_CRT" "${STATE}/${S}.leaf.crt" 2>/dev/null | grep ': OK' >/dev/null; then reissued=yes; break; fi
      [ "$(date +%s)" -ge "$(cat "${STATE}/${S}.deadline2")" ] && break
      budget_left || yield "S07 (waiting for ${TLS_NS_V}/${TLS_SECRET_V} to be re-issued; re-run to keep waiting)"
      sleep 15
    done
  fi
  note "S07: waited up to ${REISSUE_WAIT}s for ${TLS_NS_V:-no ingress}/${TLS_SECRET_V:-no secret} to chain to the generated CA: ${reissued}. The proof below reads whatever state is there when the wait ends."
  note "S07: applications not Synced/Healthy when the wait ended (not asserted: P09 already records which can be blocked by the environment): $(kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" get applications.argoproj.io --no-headers -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null | awk '$2 != "Synced" || $3 != "Healthy" {printf "%s=%s/%s ", $1, $2, $3}')"
  record "$S" "an Ingress with a TLS Secret exists to read the issued certificate from" "found" "$( [ -n "$TLS_SECRET_V" ] && echo found || echo none )"
  mark_done "$S"
fi

# S08 ... step 5: the proof.
S=S08-proof
if ! done_step "$S"; then budget_left || yield "S08+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  TLS_NS_V="$(cut -f1 "${STATE}/tls-pick" 2>/dev/null)"; TLS_SECRET_V="$(cut -f2 "${STATE}/tls-pick" 2>/dev/null)"
  page_block "$S" "$SECTION" bash 'get clusterissuer site-ca'
  run_page "$S" "step 5, the issuer and the Certificates"
  record "$S" "step 5: the first command prints True (the issuer is Ready)" "True" "$(out_of "$S" | grep . | head -1 | tr -d ' \r')"
  record "$S" "step 5: every Certificate row reads True and names ${ISSUER}" "all rows True on ${ISSUER}" \
    "$(out_of "$S" | grep -v '^True$' | verdict certs --issuer "$ISSUER" | sed -E 's/^all [0-9]+ /all rows /')"
  note "S08: the Certificate table: $(out_of "$S" | grep -v '^True$' | grep -c . | tr -d ' ') line(s) including the header"

  page_block "${S}-issued" "$SECTION" bash 'export TLS_SECRET'
  BT="${BT//YOUR_TLS_SECRET_NAME/${TLS_SECRET_V:-NO_TLS_SECRET}}"; BT="${BT//YOUR_TLS_SECRET_NAMESPACE/${TLS_NS_V:-NO_TLS_NAMESPACE}}"
  _emit "SUBSTITUTION: YOUR_TLS_SECRET_NAME -> ${TLS_SECRET_V:-none}; YOUR_TLS_SECRET_NAMESPACE -> ${TLS_NS_V:-none}  (YOU SUPPLY on the page; GLUE chose them)"
  run_page "${S}-issued" "step 5, compare an issued certificate to the CA"
  record "$S" "step 5: the ca.crt fingerprint read from the issued certificate's Secret equals the generated CA's" "$GEN_FP" "$(out_of "${S}-issued" | verdict fingerprint)"
  record "$S" "step 5: openssl verify prints 'issued.crt: OK'" "1" "$(out_of "${S}-issued" | verdict count --line 'issued.crt: OK')"
  # the same chain check read again by the harness, against the CA held outside the cluster
  record "$S" "step 5: issued.crt verifies against the generated CA (read again, not the page's output)" "issued.crt: OK" \
    "$(cd "${STATE}/work" && openssl verify -CAfile "$CA_CRT" issued.crt 2>&1 | head -1)"
  # a negative control: the same certificate must NOT verify against the chart's CA, or the check above does not discriminate
  if [ -s "${STATE}/ca/chart-ca.crt" ]; then
    record "$S" "step 5: issued.crt does not verify against the chart's own CA (the check can tell CAs apart)" "rejected" \
      "$( (cd "${STATE}/work" && openssl verify -CAfile "${STATE}/ca/chart-ca.crt" issued.crt 2>&1) | grep ': OK' >/dev/null && echo accepted || echo rejected )"
  else
    record "$S" "step 5: the chart's CA was kept to test the negative control against" "kept" "missing"
  fi

  page_block "${S}-issuers" "$SECTION" bash 'CA:.spec.ca.secretName'
  run_page "${S}-issuers" "step 5, only one CA issuer"
  note "S08: the blocks ran from a scratch directory (${STATE}/work), so block 9's issued.crt never lands in the site repository"
  record "$S" "block 9's issued.crt was written to the scratch directory and not into the site repository" "scratch only" \
    "$( [ -s "${STATE}/work/issued.crt" ] && [ ! -e "${SITE_REPO}/issued.crt" ] && echo 'scratch only' || echo 'not in the scratch directory, or in the site repository' )"
  record "$S" "step 5: exactly one ClusterIssuer has a CA secret, ${ISSUER} with ${SITE_SECRET}, and no tockmox-ca row" \
    "one CA issuer: ${ISSUER} with ${SITE_SECRET}" "$(out_of "${S}-issuers" | verdict issuers --issuer "$ISSUER" --secret "$SITE_SECRET")"
  record "$S" "the site repository clone holds nothing but the page's commit: no modified or untracked file is left" "clean" \
    "$( [ -z "$(git -C "$SITE_REPO" status --porcelain 2>/dev/null)" ] && echo clean || echo "dirty: $(git -C "$SITE_REPO" status --porcelain | head -3 | tr '\n' ' ')" )"
  mark_done "$S"
fi

finish_path
exit $?

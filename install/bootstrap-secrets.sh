#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# Tockmox secrets bootstrap (TM-0277)
#
#   ./install/tockmox-install.sh bootstrap-secrets --mode new --site ./my-site \
#       --backup-out ~/keys/sealed-secrets.key.enc --age-recipient age1...
#
# THIS IS THE ONE PART OF THE INSTALLER THAT WRITES TO A CLUSTER. The generator
# in tockmox-install.sh reads a cluster at most and applies nothing; this file
# installs (or restores the key of, or reuses) the sealed-secrets controller,
# exports its private key encrypted, and seals every credential into the site
# repository. It is therefore a separate file, reached only by naming the
# subcommand, and it shows the kube context and makes you confirm it before it
# touches anything.
#
# WHY IT IS BOOTSTRAP AND NOT A LAYER. The controller has to exist before Argo
# can decrypt the secrets the layers need, so it cannot be one of the nine
# GitOps layers. It sits beside ArgoCD, out of band.
#
# WHAT IT ORCHESTRATES, and what it does not reinvent. Credential generation and
# sealing stay in tools/mint-secrets.sh (one list of credentials, one place a
# pair is kept matched). This adds the lifecycle around it:
#   1. show and confirm the kube context, before any cluster contact
#   2. detect a controller; install, restore-then-install, or reuse it
#   3. wait until the controller can actually SERVE its certificate
#   4. export the controller's private key, encrypted, off the cluster, and
#      refuse to continue without one (or an explicit statement that you have it)
#   5. seal every credential into <site>/secrets with `kubeseal --cert`
#
# THE THREE MODES ARE THE INTERFACE. Whether this is a new deployment or the
# recovery of an existing one is the decision that decides whether every
# committed SealedSecret still opens, so it is a required flag and not a thing
# inferred from cluster state:
#   new      fresh cluster, fresh key. Refuses if a controller or a sealing key
#            already exists.
#   recover  restore the key from an encrypted backup BEFORE the controller
#            starts, so files already in the site repository keep decrypting.
#            Refuses if a controller is already running.
#   reuse    a controller already runs (this one, an older manual install, or a
#            homelab's). Detected by label in any namespace, never installed
#            a second time.
#
# NO PLAINTEXT ON DISK, on any path. Credentials are generated in memory and
# piped to kubeseal. The controller key travels cluster -> encrypt -> file with
# no plaintext file between. The only temp files are the public certificate and
# ciphertext, removed by a trap on every exit path.
#
# WHAT THIS DOES NOT DO: mint the console's LiteLLM virtual key (a running
# LiteLLM is needed to issue it; since 0.8.0 a Job in the AI layer mints it after
# the first sync, see install.md);
# apply the SealedSecrets (Argo does that, through the site-secrets Application);
# prove any of this against a real cluster (see docs/administration/secrets.md,
# "What is not certified here").
# ============================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF/.." && pwd)"
MINT="$REPO_ROOT/tools/mint-secrets.sh"

# PINNED, and the pin is the version the reference homelab runs (chart 2.20.0
# ships controller 0.40.0). Not "latest": this controller holds the key every
# sealed secret is encrypted to, and docs/administration/secrets.md records what
# unpinned sources did (a 404, and a controller several releases behind). The
# UPSTREAM chart is used, not Bitnami's OCI packaging that fresh-install.md
# section 7 installs by hand; the two differ in Service name and chart version.
CHART_REPO_DEFAULT="https://bitnami.github.io/sealed-secrets"
CHART_NAME="sealed-secrets"
CHART_VERSION_DEFAULT="2.20.0"
IMAGE_TAG_DEFAULT="0.40.0"
# kubeseal's own defaults, so a hand-run `kubeseal` against a controller this
# script installed needs no --controller-* flags.
DEFAULT_CTRL_NAME="sealed-secrets-controller"
DEFAULT_CTRL_NS="kube-system"
KEY_LABEL="sealedsecrets.bitnami.com/sealed-secrets-key"
# First line of every backup, inside the encryption. Recover refuses a file that
# lacks it, so a wrong passphrase or a foreign file fails with a reason.
BACKUP_MARKER="# tockmox-sealed-secrets-key-backup v1"
PBKDF2_ITER=600000

# ---------------------------------------------------------------- presentation
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; X=$'\033[0m'
else B=""; R=""; G=""; Y=""; C=""; X=""; fi
say()  { printf '\n%s== %s%s\n' "$B" "$*" "$X"; }
ok()   { printf '%s  ✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '%s  !%s %s\n' "$Y" "$X" "$*"; }
err()  { printf '%s  ✗%s %s\n' "$R" "$X" "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { printf '    %s\n' "$*"; }

usage() {
  cat <<USAGE
Tockmox secrets bootstrap

Writes to a CLUSTER. Installs or reuses the sealed-secrets controller, exports
its private key encrypted, and seals every credential into your site repository.

  tockmox-install.sh bootstrap-secrets --mode MODE --site DIR [options]

  --mode MODE            REQUIRED. What this run is:
                           new      fresh cluster, fresh key
                           recover  restore the key from --key-backup, then install
                           reuse    a controller already runs; adopt it. Installs
                                    nothing and never creates a second key
  --site DIR             the generated site repository (default ./tockmox-site)
  --context NAME         kubectl context (default: the current one)
  --yes-context NAME     confirm the context without a prompt. Must EQUAL the
                         context in use; it is a check, not a blanket yes
  --yes-server URL       confirm the API server the same way. Required with
                         --yes-context: a context NAME can be reused across
                         clusters, the server address is what it points at
  --yes-adopt NS/NAME    (--mode reuse) confirm the controller adopted, without
                         a prompt. Must EQUAL the one found; it is a check
  --no-prompt            never read a terminal (CI, agents). Refuses instead

 Controller (new and recover install one; reuse detects it)
  --controller-namespace NS   default ${DEFAULT_CTRL_NS} to install; detected for reuse
  --controller-name NAME      default ${DEFAULT_CTRL_NAME} to install; detected for reuse
  --chart-version V      default ${CHART_VERSION_DEFAULT} (controller ${IMAGE_TAG_DEFAULT})
  --chart-repo URL       default ${CHART_REPO_DEFAULT}
  --chart REF            a chart path, .tgz or oci:// reference, for a mirror or
                         an air-gapped install (replaces --chart-repo)
  --image-registry R     registry prefix for the controller image (a mirror)
  --wait-seconds N       how long to wait for the controller (default 180)

 Key backup. Required for new and reuse, encrypted, and never plaintext.
  --backup-out FILE      where the encrypted key export goes. Must be OUTSIDE
                         the site repository
  --age-recipient R      encrypt to an age public key (preferred: authenticated)
  --passphrase-file F    encrypt with openssl (AES-256, PBKDF2) using the first
                         line of F. Without it, and with a terminal, openssl asks
  --i-have-a-key-backup  declare that a current backup of this controller's key
                         already exists elsewhere. Skips the export; says so
                         loudly in the summary

 Recover
  --key-backup FILE      the encrypted export to restore
  --age-identity FILE    age identity that decrypts it (or --passphrase-file)

 Credentials
  --with-litellm         mint the model gateway's key and database credential (the
                         default since 0.8.0; the gateway follows the aiPlane capability)
  --without-litellm      do not: for a site with apps.litellm.enabled false
  --with-apprise         also mint an empty Apprise config to edit
  --with-tockmox-ui      also mint the Tockmox UI's session key and OIDC client secret
  --with-eval-gateway    also mint the eval gateway's master key
  --ntfy-password-file F read the ntfy password from the first line of F

  --dry-run              show the plan and what would be minted; change nothing
  -h, --help             this
USAGE
}

# ---------------------------------------------------------------- arguments
MODE=""; SITE="./tockmox-site"; CONTEXT=""; YES_CONTEXT=""; YES_SERVER=""; YES_ADOPT=""; NO_PROMPT=false; CONTEXT_GIVEN=false; YES_CTX_GIVEN=false; YES_SRV_GIVEN=false
CTRL_NS=""; CTRL_NAME=""; CHART_VERSION="$CHART_VERSION_DEFAULT"
CHART_REPO="$CHART_REPO_DEFAULT"; CHART_REF=""; IMAGE_REGISTRY=""; WAIT_SECONDS=180
BACKUP_OUT=""; AGE_RECIPIENT=""; PASSFILE=""; I_HAVE_BACKUP=false
KEY_BACKUP=""; AGE_IDENTITY=""
WITH_LITELLM=true; WITH_APPRISE=false; WITH_UI=false; WITH_EVAL=false; NTFY_PASSWORD_FILE=""; DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?--mode needs new, recover or reuse}"; shift 2 ;;
    --site) SITE="${2:?--site needs a directory}"; shift 2 ;;
    --context) CONTEXT="${2-}"; CONTEXT_GIVEN=true; shift $(( $# > 1 ? 2 : 1 )) ;;
    --yes-context) YES_CONTEXT="${2-}"; YES_CTX_GIVEN=true; shift $(( $# > 1 ? 2 : 1 )) ;;
    --yes-server) YES_SERVER="${2-}"; YES_SRV_GIVEN=true; shift $(( $# > 1 ? 2 : 1 )) ;;
    --yes-adopt) YES_ADOPT="${2:?--yes-adopt needs NAMESPACE/NAME}"; shift 2 ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    --controller-namespace) CTRL_NS="${2:?--controller-namespace needs a name}"; shift 2 ;;
    --controller-name) CTRL_NAME="${2:?--controller-name needs a name}"; shift 2 ;;
    --chart-version) CHART_VERSION="${2:?--chart-version needs a version}"; shift 2 ;;
    --chart-repo) CHART_REPO="${2:?--chart-repo needs a URL}"; shift 2 ;;
    --chart) CHART_REF="${2:?--chart needs a reference}"; shift 2 ;;
    --image-registry) IMAGE_REGISTRY="${2:?--image-registry needs a registry}"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="${2:?--wait-seconds needs a number}"; shift 2 ;;
    --backup-out) BACKUP_OUT="${2:?--backup-out needs a file}"; shift 2 ;;
    --age-recipient) AGE_RECIPIENT="${2:?--age-recipient needs a public key}"; shift 2 ;;
    --passphrase-file) PASSFILE="${2:?--passphrase-file needs a file}"; shift 2 ;;
    --i-have-a-key-backup) I_HAVE_BACKUP=true; shift ;;
    --key-backup) KEY_BACKUP="${2:?--key-backup needs a file}"; shift 2 ;;
    --age-identity) AGE_IDENTITY="${2:?--age-identity needs a file}"; shift 2 ;;
    --with-litellm) WITH_LITELLM=true; shift ;;
    --without-litellm) WITH_LITELLM=false; shift ;;
    --with-apprise) WITH_APPRISE=true; shift ;;
    --with-tockmox-ui) WITH_UI=true; shift ;;
    --with-eval-gateway) WITH_EVAL=true; shift ;;
    --ntfy-password-file) NTFY_PASSWORD_FILE="${2:?--ntfy-password-file needs a file}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

TMPD=""; BAK_TMP=""
cleanup() {
  [[ -z "$BAK_TMP" ]] || rm -f "$BAK_TMP"
  [[ -z "$TMPD" ]] || rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

have_tty() { (: < /dev/tty) 2>/dev/null; }

# ---------------------------------------------------------------- validate
# Everything that can be refused WITHOUT touching a cluster is refused here, so
# a mistake in the command line costs nothing.
say "Checking the request"

[[ -n "$MODE" ]] || die "--mode is required, and it is the decision that matters here:
       new      a fresh cluster and a fresh sealing key
       recover  restore an existing deployment's key from an encrypted backup
       reuse    a sealed-secrets controller is already running; use it
    Choosing wrongly is what strands sealed files, so it is not guessed."
# An EMPTY context is refused, never defaulted. `--context ""` is what an unset
# shell variable produces ("--context $KUBE_CONTEXT"), and falling back to the
# current context there would send a write to whichever cluster kubectl last
# pointed at, which is the trap this whole check exists for.
if $CONTEXT_GIVEN && [[ -z "${CONTEXT// }" ]]; then
  die "--context was given empty. Refusing rather than falling back to the current context.
       (An unset shell variable expands to exactly this.) Name the context, or omit the flag."
fi
if $YES_CTX_GIVEN && [[ -z "${YES_CONTEXT// }" ]]; then die "--yes-context was given empty; it must name the context you mean."; fi
if $YES_SRV_GIVEN && [[ -z "${YES_SERVER// }" ]]; then die "--yes-server was given empty; it must be the API server URL you mean."; fi
case "$MODE" in new|recover|reuse) ;; *) die "--mode must be new, recover or reuse, not '$MODE'" ;; esac
[[ -d "$SITE" ]] || die "site repository not found: $SITE
       Generate it first: tockmox-install.sh --config tockmox.yaml"
SITE="$(cd "$SITE" && pwd)"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a number: '$WAIT_SECONDS'"
if [[ -n "$CTRL_NS" && -z "$CTRL_NAME" ]] || [[ -z "$CTRL_NS" && -n "$CTRL_NAME" ]]; then
  die "give --controller-namespace and --controller-name together, or neither"
fi

# mint-secrets.sh writes the DEFAULT namespaces. A site that adopts into
# renamed namespaces would get SealedSecrets bound to namespaces that do not
# exist there, and a SealedSecret cannot be re-pointed: its namespace is part of
# what it is encrypted to. Refuse rather than seal to the wrong place.
if [[ -f "$SITE/site/values/policy.yaml" ]]; then
  OVR="$(awk '
    /^namespaces:/ {f=1; next}
    f && /^[^ \t#]/ {f=0}
    f && /^[ \t]+(ai|monitoring|authentik|devops):[ \t]*[^ \t#]/ {print}
  ' "$SITE/site/values/policy.yaml")"
  if [[ -n "$OVR" ]]; then
    die "this site renames namespaces that credentials live in:
$(printf '%s\n' "$OVR" | sed 's/^/         /')
       tools/mint-secrets.sh seals to the default names, and a SealedSecret is
       bound to its namespace. Use the manual route in
       docs/administration/secrets.md, with your namespaces, for this site."
  fi
fi

# ---- backup: choose the encryption BEFORE anything is created
ENC="none"
if [[ -n "$AGE_RECIPIENT" ]]; then ENC="age"
elif [[ -n "$PASSFILE" ]]; then ENC="openssl"
elif ! $NO_PROMPT && have_tty; then ENC="openssl"   # openssl asks for the passphrase itself
fi
if [[ -n "$PASSFILE" ]]; then
  [[ -r "$PASSFILE" ]] || die "cannot read --passphrase-file $PASSFILE"
  [[ -s "$PASSFILE" ]] || die "--passphrase-file $PASSFILE is empty"
fi

abspath() {
  local d; d="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s' "$d" "$(basename "$1")"
}

NEED_EXPORT=false
case "$MODE" in
  new|reuse)
    if $I_HAVE_BACKUP; then :
    else
      NEED_EXPORT=true
      [[ -n "$BACKUP_OUT" ]] || die "a backup of the controller's private key is required, and there is none.
       Without it, every SealedSecret in your site repository is unreadable the
       day this cluster is lost, and no amount of care with the files fixes that.
         --backup-out FILE  with  --age-recipient R  or  --passphrase-file F
       or, if a current backup of THIS controller's key already exists:
         --i-have-a-key-backup"
      [[ "$ENC" != "none" ]] || die "no way to encrypt the key backup, so it will not be written.
       This script does not write the controller's private key in plaintext, on
       any path. Give it one of:
         --age-recipient R      (age installed; preferred)
         --passphrase-file F    (openssl; the first line of F is the passphrase)
       or run from a terminal without --no-prompt and openssl will ask."
    fi ;;
  recover)
    [[ -n "$KEY_BACKUP" ]] || die "--mode recover needs --key-backup FILE, the encrypted export to restore"
    [[ -r "$KEY_BACKUP" ]] || die "cannot read --key-backup $KEY_BACKUP"
    if [[ -n "$AGE_IDENTITY" ]]; then
      [[ -r "$AGE_IDENTITY" ]] || die "cannot read --age-identity $AGE_IDENTITY"
    elif [[ -z "$PASSFILE" ]] && { $NO_PROMPT || ! have_tty; }; then
      die "cannot decrypt --key-backup: give --age-identity FILE or --passphrase-file F
       (no terminal to ask on, or --no-prompt was given)"
    fi ;;
esac
if [[ -n "$BACKUP_OUT" ]]; then
  BACKUP_ABS="$(abspath "$BACKUP_OUT")" || die "the directory for --backup-out does not exist: $(dirname "$BACKUP_OUT")"
  case "$BACKUP_ABS" in
    "$SITE"/*) die "--backup-out is inside the site repository ($SITE).
       The backup exists to survive the loss of the cluster; a site repository is
       pushed to a git host. Put it somewhere else." ;;
  esac
  if command -v git >/dev/null 2>&1 \
     && git -C "$(dirname "$BACKUP_ABS")" rev-parse --show-toplevel >/dev/null 2>&1; then
    warn "--backup-out is inside a git working tree. It is encrypted, but do not commit it."
  fi
  BACKUP_OUT="$BACKUP_ABS"
fi

# ---- tools
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1 ... $2"; }
need kubectl "talks to the cluster"
need kubeseal "seals each credential; https://github.com/bitnami-labs/sealed-secrets/releases"
need openssl "generates every value, and encrypts the key backup when age is not used"
[[ "$MODE" == "reuse" ]] || need helm "installs the controller (v3)"
{ [[ "$ENC" == "age" ]] || [[ -n "$AGE_IDENTITY" ]]; } && need age "was asked for by --age-recipient or --age-identity"
[[ -f "$MINT" ]] || die "tools/mint-secrets.sh not found beside this script: $MINT"

MINT_ARGS=(--out "$SITE/secrets" --no-next)
$WITH_LITELLM && MINT_ARGS+=(--with-litellm) || MINT_ARGS+=(--without-litellm)
$WITH_APPRISE && MINT_ARGS+=(--with-apprise)
$WITH_UI && MINT_ARGS+=(--with-tockmox-ui)
$WITH_EVAL && MINT_ARGS+=(--with-eval-gateway)
$NO_PROMPT && MINT_ARGS+=(--no-prompt)
[[ -z "$NTFY_PASSWORD_FILE" ]] || MINT_ARGS+=(--ntfy-password-file "$NTFY_PASSWORD_FILE")

# The context NAME is a local kubeconfig read; no cluster is contacted yet.
CTX_CUR="$(kubectl config current-context 2>/dev/null || true)"
CTX="${CONTEXT:-$CTX_CUR}"
[[ -n "$CTX" ]] || die "no kubectl context is set and none was given. Name one with --context."

# ---- matched pairs, before ANY cluster contact
# mint-secrets.sh refuses a half-present pair, and this asks it to now, in
# dry-run form against no certificate, so the refusal happens before the
# controller is installed or a key exported. A retry that fails after changing
# the cluster is a worse failure than one that fails first.
PRE_OUT="$(bash "$MINT" --dry-run --cert /dev/null --context "$CTX" "${MINT_ARGS[@]}")" \
  || die "the credentials in $SITE/secrets cannot be completed as they stand (above)."
ok "request is consistent"

# ---------------------------------------------------------------- context
say "Cluster context"
SERVER="$(kubectl config view --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
info "context     ${CTX}"
info "API server  ${SERVER:-unknown}"
info "mode        ${MODE}"
info "site        ${SITE}"
# A context that reaches production is a documented trap in this project. The
# confirmation is a check that the operator READ the name, not a reflex: it must
# be typed, or given as a value that has to match.
if $DRY_RUN; then
  warn "--dry-run: not asking to confirm, because nothing will be written"
elif [[ -n "$YES_CONTEXT" ]]; then
  [[ "$YES_CONTEXT" == "$CTX" ]] \
    || die "--yes-context '$YES_CONTEXT' does not match the context in use, '$CTX'. Refusing.
       (A confirmation that does not match is not a confirmation. Nothing was touched.)"
  [[ -n "$SERVER" ]] || die "cannot read the API server address for context '$CTX', so it cannot be confirmed. Refusing."
  [[ -n "$YES_SERVER" ]] \
    || die "--yes-context was given without --yes-server. A context NAME can be reused across
       clusters; the server is what it reaches. Re-run with --yes-server '$SERVER' if that is the one."
  [[ "$YES_SERVER" == "$SERVER" ]] \
    || die "--yes-server '$YES_SERVER' does not match the API server in use, '$SERVER'. Refusing.
       (Nothing was touched.)"
  ok "context and API server confirmed by --yes-context and --yes-server"
else
  $NO_PROMPT && die "--no-prompt was given without --yes-context and --yes-server, so the cluster cannot be confirmed.
       Re-run with --yes-context '$CTX' --yes-server '${SERVER:-URL}' if that is the cluster you mean."
  have_tty || die "no terminal to confirm the context on. Re-run with --yes-context '$CTX' --yes-server '${SERVER:-URL}'
       if that is the cluster you mean."
  [[ -n "$SERVER" ]] || die "cannot read the API server address for context '$CTX', so it cannot be confirmed. Refusing."
  printf '  Type the context name to write to that cluster: '
  read -r ANS </dev/tty || ANS=""
  [[ "$ANS" == "$CTX" ]] || die "not confirmed. Nothing was touched."
  printf '  Type the API server it reaches (as shown above): '
  read -r ANS </dev/tty || ANS=""
  [[ "$ANS" == "$SERVER" ]] || die "not confirmed. Nothing was touched."
fi
K=(--context "$CTX")
kubectl "${K[@]}" get namespace >/dev/null 2>&1 || die "cannot reach the cluster through context '$CTX'"
ok "cluster reachable"

# ---------------------------------------------------------------- detect
say "Looking for a sealed-secrets controller"
# TWO ways to recognise a controller, unioned, because installs differ: the
# chart labels the Deployment app.kubernetes.io/name=sealed-secrets, and the
# release YAML the upstream project publishes does not. A second key generated
# beside a controller this missed is the failure that cannot be undone, so the
# net is wide and a false positive only asks the operator to look.
FOUND_L="$(kubectl "${K[@]}" get deploy -A -l app.kubernetes.io/name=sealed-secrets \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
FOUND_I="$(kubectl "${K[@]}" get deploy -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
  | awk 'index($0, "sealed-secrets") && NF >= 3 {print $1, $2}' || true)"
FOUND="$(printf '%s\n%s\n' "$FOUND_L" "$FOUND_I" | grep . | sort -u || true)"
N_FOUND="$(printf '%s\n' "$FOUND" | grep -c . || true)"
# Sealing keys anywhere: a controller may be down or renamed and its keys remain.
KEY_NS="$(kubectl "${K[@]}" get secret -A -l "$KEY_LABEL" \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | grep . | sort -u || true)"
EXPLICIT=false; [[ -n "$CTRL_NS" ]] && EXPLICIT=true
RESUME=false; INSTALL=false

count_keys() {  # namespace
  kubectl "${K[@]}" -n "$1" get secret -l "$KEY_LABEL" -o name 2>/dev/null | grep -c . || true
}
our_release() {  # namespace name
  [[ "$(helm --kube-context "$CTX" -n "$1" list -q -f "^${2}\$" 2>/dev/null || true)" == "$2" ]]
}

case "$MODE" in
  reuse)
    if $EXPLICIT; then
      kubectl "${K[@]}" -n "$CTRL_NS" get deploy "$CTRL_NAME" >/dev/null 2>&1 \
        || die "no deployment $CTRL_NAME in namespace $CTRL_NS. Nothing named that is running."
    elif [[ "$N_FOUND" -eq 0 ]]; then
      [[ -z "$KEY_NS" ]] || die "no sealed-secrets controller Deployment found, but sealing keys exist in:
$(printf '%s\n' "$KEY_NS" | sed 's/^/         /')
       Something ran here and left its key. Nothing is adopted or installed on a guess:
       if the controller has another name, give --controller-namespace and
       --controller-name; if you mean to restore, use --mode recover."
      die "no sealed-secrets controller found in any namespace (by label, or by image).
       For a cluster that has none, use --mode new. For a rebuilt cluster whose key
       you have backed up, use --mode recover."
    elif [[ "$N_FOUND" -gt 1 ]]; then
      die "more than one controller found; say which one holds your key:
$(printf '%s\n' "$FOUND" | sed 's/^/         /')
       Re-run with --controller-namespace and --controller-name."
    else
      CTRL_NS="${FOUND%% *}"; CTRL_NAME="${FOUND##* }"
    fi
    # ADOPTING a controller is a decision about whose key every SealedSecret in
    # this site is encrypted to. Show what was found and make the operator
    # confirm THAT controller, so a stray or foreign one is not adopted by default.
    AD_IMG="$(kubectl "${K[@]}" -n "$CTRL_NS" get deploy "$CTRL_NAME" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    AD_KEYS="$(count_keys "$CTRL_NS")"
    say "Adopting an existing controller"
    info "controller  ${CTRL_NS}/${CTRL_NAME}"
    info "image       ${AD_IMG:-unknown}"
    info "keys        ${AD_KEYS} sealing key Secret(s) in ${CTRL_NS}"
    info "NOTHING will be installed and NO new key will be generated. The site's"
    info "SealedSecrets will be encrypted to this controller's key."
    if $DRY_RUN; then
      warn "--dry-run: not asking to confirm the adoption"
    elif [[ -n "$YES_ADOPT" ]]; then
      [[ "$YES_ADOPT" == "$CTRL_NS/$CTRL_NAME" ]] \
        || die "--yes-adopt '$YES_ADOPT' does not match the controller found, '$CTRL_NS/$CTRL_NAME'. Refusing.
       (Nothing was installed and nothing was sealed.)"
      ok "adoption of $CTRL_NS/$CTRL_NAME confirmed by --yes-adopt"
    else
      $NO_PROMPT && die "--no-prompt was given without --yes-adopt, so the adoption cannot be confirmed.
       Re-run with --yes-adopt '$CTRL_NS/$CTRL_NAME' if that is the controller you mean."
      have_tty || die "no terminal to confirm the adoption on. Re-run with --yes-adopt '$CTRL_NS/$CTRL_NAME'."
      printf '  Type NAMESPACE/NAME of the controller to adopt: '
      read -r ANS </dev/tty || ANS=""
      [[ "$ANS" == "$CTRL_NS/$CTRL_NAME" ]] || die "not confirmed. Nothing was installed or sealed."
    fi
    ok "reusing $CTRL_NS/$CTRL_NAME; no controller will be installed" ;;
  new|recover)
    [[ -n "$CTRL_NS" ]] || { CTRL_NS="$DEFAULT_CTRL_NS"; CTRL_NAME="$DEFAULT_CTRL_NAME"; }
    if [[ "$N_FOUND" -gt 0 ]]; then
      if [[ "$MODE" == "new" && "$N_FOUND" -eq 1 && "$FOUND" == "$CTRL_NS $CTRL_NAME" ]] \
         && our_release "$CTRL_NS" "$CTRL_NAME"; then
        RESUME=true
        ok "resuming: helm release $CTRL_NAME in $CTRL_NS is one this script installed; not touching it"
      elif [[ "$MODE" == "recover" ]]; then
        die "a sealed-secrets controller is already running:
$(printf '%s\n' "$FOUND" | sed 's/^/         /')
       --mode recover restores the key BEFORE the controller starts, so that the
       files in your site repository open. Into a running controller it cannot:
       the controller would need a restart and a decision about which key is
       active. If this controller is the right one, use --mode reuse. If it is
       not, remove it (that is yours to decide) and re-run."
      else
        die "a sealed-secrets controller is already running:
$(printf '%s\n' "$FOUND" | sed 's/^/         /')
       --mode new would install a second one, with a second key, and anything
       sealed to one cannot be opened by the other. To use the running one:
         --mode reuse
       If it was installed by hand and is what you want, that is the mode."
      fi
    fi
    if ! $RESUME; then
      # ANY namespace, not only the one about to be installed into: a leftover
      # key elsewhere means an earlier controller existed, and a second key made
      # now is one the site's existing files were never sealed to.
      [[ -z "$KEY_NS" ]] || die "no controller is running, but sealing key Secret(s) exist in:
$(printf '%s\n' "$KEY_NS" | sed 's/^/         /')
       A controller installed now would either adopt them silently (same namespace)
       or generate a second key beside them. If they are the keys of the deployment
       you are recovering, use --mode recover with the backup (after removing these
       yourself); if they are stale, delete them yourself first. Not guessed."
      INSTALL=true
    fi ;;
esac
info "controller  ${CTRL_NS}/${CTRL_NAME}"

# ---------------------------------------------------------------- plan / dry run
if $DRY_RUN; then
  say "Plan (dry run, nothing changed)"
  $INSTALL && info "install    chart ${CHART_REF:-$CHART_NAME $CHART_VERSION} as release ${CTRL_NAME} in ${CTRL_NS}"
  [[ "$MODE" == "recover" ]] && info "restore    sealing key from ${KEY_BACKUP}, before the controller starts"
  $NEED_EXPORT && info "backup     encrypted (${ENC}) key export to ${BACKUP_OUT}"
  $I_HAVE_BACKUP && warn "you state a current key backup exists elsewhere; none will be written"
  info "credentials:"
  printf '%s\n' "$PRE_OUT" | sed 's/^/      /'
  exit 0
fi

# ---------------------------------------------------------------- encryption
encrypt_stream() {
  case "$ENC" in
    age)     age -r "$AGE_RECIPIENT" ;;
    openssl) if [[ -n "$PASSFILE" ]]; then
               openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -salt -pass "file:$PASSFILE"
             else
               openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -salt
             fi ;;
    *) return 1 ;;
  esac
}
decrypt_stream() {
  if [[ -n "$AGE_IDENTITY" ]]; then age -d -i "$AGE_IDENTITY"
  elif [[ -n "$PASSFILE" ]]; then
    openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -pass "file:$PASSFILE"
  else openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER"; fi
}

# The go-template is the export FORMAT: just enough of each key Secret to
# recreate it (name, label, tls.crt, tls.key), with no uid, resourceVersion or
# namespace, so `kubectl create -n <any namespace> -f -` accepts it. A raw
# `kubectl get -o yaml` carries fields a create refuses. It handles both a List
# (a label selector) and a single object.
read -r -d '' KEY_TEMPLATE <<'TPL' || true
{{define "k"}}---
apiVersion: v1
kind: Secret
metadata:
  name: {{.metadata.name}}
  labels:
    sealedsecrets.bitnami.com/sealed-secrets-key: {{index .metadata.labels "sealedsecrets.bitnami.com/sealed-secrets-key"}}
type: {{.type}}
data:
  tls.crt: {{index .data "tls.crt"}}
  tls.key: {{index .data "tls.key"}}
{{end}}{{if eq .kind "List"}}{{range .items}}{{template "k" .}}{{end}}{{else}}{{template "k" .}}{{end}}
TPL

# ---------------------------------------------------------------- recover
if [[ "$MODE" == "recover" ]]; then
  say "Restoring the sealing key, before the controller exists"
  kubectl "${K[@]}" get namespace "$CTRL_NS" >/dev/null 2>&1 \
    || kubectl "${K[@]}" create namespace "$CTRL_NS" >/dev/null
  rc=0
  decrypt_stream < "$KEY_BACKUP" | {
    IFS= read -r first || exit 3
    [[ "$first" == "$BACKUP_MARKER" ]] || exit 4
    kubectl "${K[@]}" -n "$CTRL_NS" create -f - -o name
  } || rc=$?
  case "$rc" in
    0) ok "sealing key restored into $CTRL_NS" ;;
    3|4) die "$KEY_BACKUP did not decrypt to a Tockmox key backup.
       A wrong passphrase, the wrong identity, or a file this script did not write.
       (A backup made by hand with 'kubectl get -o yaml' is not this format; see
       docs/administration/secrets.md.) Nothing was installed." ;;
    *) die "restoring the key failed (status $rc). Nothing was installed." ;;
  esac
fi

# ---------------------------------------------------------------- install
if $INSTALL; then
  say "Installing the controller"
  HELM_SRC=("$CHART_NAME" --repo "$CHART_REPO")
  [[ -z "$CHART_REF" ]] || HELM_SRC=("$CHART_REF")
  HELM_SET=(--set-string "fullnameOverride=${CTRL_NAME}" --set-string "image.tag=${IMAGE_TAG_DEFAULT}")
  [[ -z "$IMAGE_REGISTRY" ]] || HELM_SET+=(--set-string "image.registry=${IMAGE_REGISTRY}")
  # --version applies to a repository chart. A local path or .tgz carries its own.
  HELM_VER=(--version "$CHART_VERSION"); [[ -z "$CHART_REF" ]] || HELM_VER=()
  helm upgrade --install "$CTRL_NAME" "${HELM_SRC[@]}" ${HELM_VER[@]+"${HELM_VER[@]}"} \
    --kube-context "$CTX" --namespace "$CTRL_NS" --create-namespace \
    "${HELM_SET[@]}" --wait --timeout "${WAIT_SECONDS}s" \
    || die "helm could not install the controller. Nothing has been sealed."
  ok "controller installed: chart ${CHART_REF:-$CHART_VERSION}, image tag ${IMAGE_TAG_DEFAULT}"
fi

# ---------------------------------------------------------------- wait
# WAIT FOR THE CAPABILITY, not the object. A Ready Deployment is not a
# controller that can hand out its certificate; the key is generated (or loaded)
# as it starts. Ask for the certificate, which is the thing needed, and retry.
say "Waiting for the controller to serve its certificate"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-bootstrap.XXXXXX")"
CERT="$TMPD/sealed-secrets-cert.pem"
DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
GOT=false
while :; do
  if kubeseal --fetch-cert --controller-name "$CTRL_NAME" --controller-namespace "$CTRL_NS" \
       --context "$CTX" > "$CERT" 2>"$TMPD/fetch.err" && grep -q 'BEGIN CERTIFICATE' "$CERT"; then
    GOT=true; break
  fi
  [[ $(date +%s) -lt $DEADLINE ]] || break
  sleep 2
done
$GOT || die "the controller $CTRL_NS/$CTRL_NAME did not serve a certificate within ${WAIT_SECONDS}s.
       Last error: $(head -c 300 "$TMPD/fetch.err" 2>/dev/null | tr '\n' ' ')
       Nothing has been sealed."
ok "certificate fetched from $CTRL_NS/$CTRL_NAME"
# The certificate is PUBLIC and is kept with the site, so a machine with no
# cluster access can still seal (mint-secrets.sh --cert). Written once and not
# rewritten: the controller renews its key on a schedule, and a certificate that
# changed on every run would make a re-run look like a change.
if [[ ! -e "$SITE/secrets/sealed-secrets-cert.pem" ]]; then
  mkdir -p "$SITE/secrets"
  cp "$CERT" "$SITE/secrets/sealed-secrets-cert.pem"; chmod 0644 "$SITE/secrets/sealed-secrets-cert.pem"
  ok "public certificate saved to secrets/sealed-secrets-cert.pem"
fi

# kubeseal against the controller's minor version. Docs say to match, and have
# not measured what a mismatch costs; a warning, not a refusal, for that reason.
KS_VER="$(kubeseal --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
IMG="$(kubectl "${K[@]}" -n "$CTRL_NS" get deploy "$CTRL_NAME" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
CT_VER="$(printf '%s' "$IMG" | sed -nE 's/.*:v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
if [[ -n "$KS_VER" && -n "$CT_VER" ]]; then
  if [[ "${KS_VER%.*}" == "${CT_VER%.*}" ]]; then ok "kubeseal $KS_VER matches controller $CT_VER (major.minor)"
  else warn "kubeseal $KS_VER against controller $CT_VER: major.minor differ. Not measured whether that breaks; docs/administration/secrets.md says to match."; fi
else
  warn "could not compare kubeseal and controller versions (kubeseal '${KS_VER:-?}', controller image '${IMG:-?}')"
fi

# ---------------------------------------------------------------- backup
BACKUP_NOTE=""
if [[ "$MODE" == "recover" ]]; then
  BACKUP_NOTE="restored from $KEY_BACKUP; that file is your backup, of the keys as they were then"
elif $I_HAVE_BACKUP; then
  warn "you state a current backup of this controller's key exists elsewhere. This run did not write one and cannot check it."
  BACKUP_NOTE="NOT WRITTEN BY THIS RUN. You declared one exists."
elif [[ -e "$BACKUP_OUT" ]]; then
  warn "$BACKUP_OUT already exists, so it was not overwritten (it may be your only good copy)."
  info "To re-export after a key renewal, give a new --backup-out path."
  BACKUP_NOTE="$BACKUP_OUT (existing file kept, NOT re-exported this run)"
else
  say "Exporting the controller's private key, encrypted"
  NK="$(count_keys "$CTRL_NS")"
  [[ "$NK" -ge 1 ]] || die "the controller has no sealing key yet ($CTRL_NS). Nothing has been sealed."
  BAK_TMP="$BACKUP_OUT.tmp.$$"
  # umask in a subshell so it does not leak. The key never touches a file until
  # it is ciphertext.
  if ! ( umask 077
         { printf '%s\n' "$BACKUP_MARKER"
           kubectl "${K[@]}" -n "$CTRL_NS" get secret -l "$KEY_LABEL" -o go-template="$KEY_TEMPLATE"
         } | encrypt_stream > "$BAK_TMP" ); then
    die "the key export failed. No backup was written and nothing has been sealed."
  fi
  if [[ "$ENC" == "age" && -z "$AGE_IDENTITY" ]]; then
    head -c 32 "$BAK_TMP" | grep -q 'age-encryption.org' \
      || die "the export does not look like an age file. Nothing has been sealed."
    warn "NOT VERIFIED: age cannot open its own output without your identity. Once, yourself:"
    info "age -d -i YOUR-IDENTITY $BACKUP_OUT | grep -c 'tls.key'      (expect $NK)"
  else
    NBACK="$(decrypt_stream < "$BAK_TMP" | grep -c 'tls\.key' || true)"
    [[ "$NBACK" -ge 1 ]] || die "the backup does not decrypt back to a key. It was discarded; nothing has been sealed."
    ok "backup decrypts and holds $NBACK key(s) of $NK"
  fi
  mv "$BAK_TMP" "$BACKUP_OUT"; BAK_TMP=""
  ok "encrypted key backup written: $BACKUP_OUT"
  BACKUP_NOTE="$BACKUP_OUT (${ENC}, ${NK} key(s) as of now)"
fi

# ---------------------------------------------------------------- seal
say "Sealing credentials into $SITE/secrets"
bash "$MINT" --cert "$CERT" --context "$CTX" "${MINT_ARGS[@]}" \
  || die "sealing did not complete. Files already in $SITE/secrets are untouched; nothing half-written was left. The controller and backup above stand."

# ---------------------------------------------------------------- summary
say "Done"
NSEALED="$(find "$SITE/secrets" -maxdepth 1 -name '*.sealed.yaml' | wc -l | tr -d ' ')"
ok "$NSEALED sealed file(s) in $SITE/secrets"
info "controller  ${CTRL_NS}/${CTRL_NAME}   (${MODE})"
info "key backup  ${BACKUP_NOTE}"
printf '\n'
warn "THE KEY BACKUP IS THE ONE THING A REBUILD CANNOT REGENERATE."
info "Move it off this machine. It is encrypted, and the passphrase or age identity"
info "is not stored anywhere by this script: lose that and the backup is noise."
info "The controller renews its key about every 30 days and keeps the old ones."
info "A backup made today does not open a file sealed after the next renewal:"
info "re-run with --mode reuse and a new --backup-out path after each renewal."
info "Where to keep it, how to restore it and how to drill that:"
info "docs/operations/sealed-secrets-key-escrow.md"
printf '\n'
info "Next: commit $SITE/secrets, push the site repository, replace the"
info "placeholder repository URL, and apply bootstrap/root.yaml (install.md Phase 3)."
info "NOT done here: the console's LiteLLM virtual key needs a running LiteLLM, so a"
info "Job in the AI layer mints it after the first sync (install.md, 'Confirm the"
info "console's model-gateway key was minted' checks it)."

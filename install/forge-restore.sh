#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# Tockmox built-in forge: rebuild and repair from the off-site copy
#
#   ./install/tockmox-install.sh --restore-from offsite --kit KIT --passphrase-file F \
#       --offsite-s3-endpoint URL --offsite-s3-bucket B --offsite-s3-credentials F \
#       --kit-out NEW-KIT --site-out ./tockmox-site
#   ./install/tockmox-install.sh --restore-from file:./site.bundle --kit KIT ...
#   ./install/tockmox-install.sh repair-forge --offsite-s3-endpoint ... --kit-out NEW-KIT ...
#
# TWO COMMANDS, ONE SOURCE OF TRUTH. A site whose repository lives in the built-in
# forge keeps two things off the cluster: the off-site copy of main (a git bundle in a
# bucket, or a git remote the forge mirrors to) and the recovery kit (the sealing key
# backup and the forge's own secrets, encrypted). This script turns them back into a
# running site:
#
#   rebuild (--restore-from)  a cluster that has Argo CD and nothing else. Opens the
#               kit, restores the sealing key BEFORE the controller starts
#               (bootstrap-secrets --mode recover), installs the forge and seeds it
#               from the copy (bootstrap-forge), and applies the root Application.
#               Every Application already names the forge's in-cluster address,
#               which is the same on every cluster, so no URL is rewritten.
#   repair (repair-forge)     a cluster that runs, whose forge does not: its volume
#               was lost, or its node. Reinstalls ONLY the forge, seeds it from the
#               copy and gives Argo CD its read credential again. Nothing else is
#               touched; Argo CD shows ComparisonError until the forge answers and
#               then reads the same commit it read before.
#
# EVERY REFUSAL COMES BEFORE THE CLUSTER IS TOUCHED. The copy is fetched and checked
# (its SHA-256, `git bundle verify`, the commit the bucket's pointer names, that the
# tree is a built-in-forge site) and the kit is opened and checked (its marker, its
# end line, its sealing key backup) on this workstation first. A wrong passphrase, a
# corrupt or tampered bundle, a checksum that does not match, or a site generated for
# another forge stops the run with nothing installed. The copy's age is always named
# (the commit time of its main): nothing here can know how far the copy is behind the
# forge that is gone, so the age is the honest number, and a copy older than
# --max-age-hours is called out.
#
# THE REVIEW HISTORY comes back from the last nightly forge dump, best effort: the dump is
# fetched beside the copy (the bucket's latest-dump pointer, the remote's forge-dump
# branch, or --dump FILE beside a copy on media), checked against its SHA-256 and its own
# counts here, before the cluster is touched, and each pull request in it returns as a
# closed issue labelled restored-from-dump (bootstrap-forge --restore-history). What was
# said after that dump is lost. No dump at the destination is a warning, not a refusal; a
# dump that does not match its checksum is a refusal, like a copy that does not.
#
# WHAT IT DOES NOT RESTORE. The forge's own settings: bootstrap-forge recreates them. Who
# approved each change is in the merge commits, so that is never lost. Accounts come back
# at each person's next sign-in. Running workloads and their volumes are the backups'
# business.
#
# A COPY ON MEDIA (file:PATH) is checked against PATH.sha256 (the line the off-site
# job writes beside every bundle: "<sum>  site.bundle") or --sha256 HEX. Its
# signature, once copies are signed, is checked here too; nothing signs them yet.
#
# NO SECRET ON A COMMAND LINE. The S3 key pair reaches curl as a config on stdin, a
# git remote's credential as a header in GIT_CONFIG_* variables, and the kit is
# decrypted as a stream. What is written from the kit goes to a temp directory a
# trap removes, mode 0600: its manifest lines (no secret in them) and its sealing key
# backup, which is still encrypted (bootstrap-secrets' own export). The forge's own
# secrets and admin password in the kit are never written anywhere.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_MARKER="# tockmox-recovery-kit v1"
COPY_FORMAT="format tockmox-site-copy v1"
PBKDF2_ITER=600000
RELEASE="tockmox-forge"
ORG="tockmox"; REPO="site"

# ---------------------------------------------------------------- presentation
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else B=""; G=""; Y=""; R=""; X=""; fi
say()  { printf '\n%s== %s%s\n' "$B" "$*" "$X"; }
ok()   { printf '%s  ✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '%s  !%s %s\n' "$Y" "$X" "$*"; }
err()  { printf '%s  ✗%s %s\n' "$R" "$X" "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { printf '    %s\n' "$*"; }

ACTION="${1:-}"; shift || true
case "$ACTION" in rebuild|repair|drill) ;; *) die "internal: forge-restore.sh needs rebuild, repair or drill first" ;; esac
ORIG_ARGS=("$@")
DRILL=false
if [[ "$ACTION" == drill ]]; then DRILL=true; ACTION=rebuild; fi   # a drill is a rebuild, checked the same way

usage() {
  cat <<USAGE
Tockmox built-in forge: $( [[ "$ACTION" == rebuild ]] && echo "rebuild a site from its off-site copy" || echo "repair the forge from its off-site copy" )

Writes to a CLUSTER, after it has checked everything it can without one.

  tockmox-install.sh --restore-from offsite|file:PATH --kit KIT (--passphrase-file F | --age-identity I) \\
      --kit-out NEW-KIT --site-out DIR [source] [options]
  tockmox-install.sh repair-forge [--restore-from offsite|file:PATH] --kit-out NEW-KIT [source] [options]

 Source of the site (the off-site copy)
  --restore-from offsite    read the copy from the destination named below (default for repair-forge)
  --restore-from file:PATH  a bundle carried in on media; checked against PATH.sha256 or --sha256
  --sha256 HEX              the bundle's SHA-256, when there is no PATH.sha256 beside it
  --offsite-s3-endpoint URL --offsite-s3-bucket NAME [--offsite-s3-prefix P] [--offsite-s3-region R]
  --offsite-s3-credentials F [--offsite-s3-ca FILE]
                            the bucket the off-site job writes to (the same flags bootstrap-forge took)
  --offsite-git URL --offsite-git-credentials F
                            the git remote the forge mirrors to
  The same destination is set up again for the new forge's off-site copy.
  --max-age-hours N         call the copy out as old past this age (default 24)
  --dump FILE               (file:PATH) the forge dump carried in beside the copy; checked against
                            FILE.sha256 or --dump-sha256. Offsite, the dump is read from the destination
  --dump-sha256 HEX         the dump's SHA-256, when there is no FILE.sha256 beside it
  --no-review-history       do not read the forge dump: the review history is not restored

 The recovery kit (rebuild)
  --kit FILE                the kit bootstrap-forge wrote
  --passphrase-file F       the kit's passphrase (an openssl kit); also encrypts the new kit
  --age-identity FILE       the kit's age identity (an age kit)
  --key-passphrase-file F   the sealing key backup's passphrase, if it differs from the kit's
  --key-age-identity FILE   the sealing key backup's age identity, if it differs

 What it writes
  --kit-out FILE            the NEW recovery kit: the new forge has new secrets (required)
  --age-recipient R         encrypt the new kit to this age key (default: derived from --age-identity)
  --site-out DIR            where the restored site is checked out (rebuild; default ./tockmox-site-restored)
  --sealing-key-backup F    (repair) your current sealing key backup, for the new kit
  --no-sealing-key-backup   (repair) write the new kit without it, and say so loudly

 Cluster
  --context NAME --yes-context NAME --yes-server URL --no-prompt   as bootstrap-forge
  --namespace NS --argocd-namespace NS --ai-namespace NS --identity-namespace NS
  --platform-namespace NS --chart REF --chart-version V --image-registry R
  --storage-class SC --wait-seconds N --no-sign-in                 passed to bootstrap-forge
  --controller-namespace NS --controller-name NAME                 (rebuild) passed to bootstrap-secrets
  --config FILE             read argocd.namespace from the installer's config
  --force                   (repair) reinstall a forge that answers and holds the copy's commit
  --dry-run                 fetch and check the copy and the kit; touch no cluster
  --keep-copy FILE          keep the checked copy as FILE, with FILE.sha256 and FILE.commit beside it
  --no-offsite-setup        (rebuild) read the copy from the destination, but do not set the new
                            forge up to write to it (the drill's throwaway forge never does)

 Rebuild drill (tockmox-install.sh rebuild-drill: the rebuild options above, plus)
  --drill-wait-minutes N    wait up to N minutes for every Application to be Synced and
                            Healthy (default 45; 0 records the time to the rebuild's end)
  -h, --help                this
USAGE
}

# ---------------------------------------------------------------- arguments
FROM=""; SHA256_GIVEN=""; MAX_AGE_H=24; DUMP_FILE=""; DUMP_SHA=""; NO_HISTORY=false
OS_S3_ENDPOINT=""; OS_S3_BUCKET=""; OS_S3_PREFIX=""; OS_S3_REGION="us-east-1"; OS_S3_CREDS=""; OS_S3_CA=""
OS_GIT_URL=""; OS_GIT_CREDS=""
KIT=""; PASSFILE=""; AGE_IDENTITY=""; KEY_PASSFILE=""; KEY_AGE_IDENTITY=""
KIT_OUT=""; AGE_RECIPIENT=""; SITE_OUT=""; SEAL_BACKUP=""; NO_SEAL_BACKUP=false
CONTEXT=""; CONTEXT_GIVEN=false; YES_CONTEXT=""; YES_SERVER=""; NO_PROMPT=false
FORGE_NS="tockmox-forge"; ARGO_NS=""; CONFIG=""; FORCE=false; DRY_RUN=false
KEEP_COPY=""; DRILL_WAIT_MIN=45; NO_OFFSITE_SETUP=false
PASS_FORGE=(); PASS_SECRETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore-from) FROM="${2:?--restore-from needs offsite or file:PATH}"; shift 2 ;;
    --restore-from=*) FROM="${1#*=}"; shift ;;
    --sha256) SHA256_GIVEN="${2:?--sha256 needs a hex digest}"; shift 2 ;;
    --max-age-hours) MAX_AGE_H="${2:?--max-age-hours needs a number}"; shift 2 ;;
    --offsite-s3-endpoint) OS_S3_ENDPOINT="${2:?--offsite-s3-endpoint needs a URL}"; shift 2 ;;
    --offsite-s3-bucket) OS_S3_BUCKET="${2:?--offsite-s3-bucket needs a name}"; shift 2 ;;
    --offsite-s3-prefix) OS_S3_PREFIX="${2?--offsite-s3-prefix needs a value}"; shift 2 ;;
    --offsite-s3-region) OS_S3_REGION="${2:?--offsite-s3-region needs a value}"; shift 2 ;;
    --offsite-s3-credentials) OS_S3_CREDS="${2:?--offsite-s3-credentials needs a file}"; shift 2 ;;
    --offsite-s3-ca) OS_S3_CA="${2:?--offsite-s3-ca needs a file}"; shift 2 ;;
    --offsite-git) OS_GIT_URL="${2:?--offsite-git needs a URL}"; shift 2 ;;
    --offsite-git-credentials) OS_GIT_CREDS="${2:?--offsite-git-credentials needs a file}"; shift 2 ;;
    --kit) KIT="${2:?--kit needs a file}"; shift 2 ;;
    --passphrase-file) PASSFILE="${2:?--passphrase-file needs a file}"; shift 2 ;;
    --age-identity) AGE_IDENTITY="${2:?--age-identity needs a file}"; shift 2 ;;
    --key-passphrase-file) KEY_PASSFILE="${2:?--key-passphrase-file needs a file}"; shift 2 ;;
    --key-age-identity) KEY_AGE_IDENTITY="${2:?--key-age-identity needs a file}"; shift 2 ;;
    --kit-out) KIT_OUT="${2:?--kit-out needs a file}"; shift 2 ;;
    --age-recipient) AGE_RECIPIENT="${2:?--age-recipient needs a public key}"; shift 2 ;;
    --site-out) SITE_OUT="${2:?--site-out needs a directory}"; shift 2 ;;
    --sealing-key-backup) SEAL_BACKUP="${2:?--sealing-key-backup needs a file}"; shift 2 ;;
    --no-sealing-key-backup) NO_SEAL_BACKUP=true; shift ;;
    --context) CONTEXT="${2-}"; CONTEXT_GIVEN=true; shift $(( $# > 1 ? 2 : 1 )) ;;
    --yes-context) YES_CONTEXT="${2:?--yes-context needs the context name}"; shift 2 ;;
    --yes-server) YES_SERVER="${2:?--yes-server needs the API server URL}"; shift 2 ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    --namespace) FORGE_NS="${2:?--namespace needs a name}"; shift 2 ;;
    --argocd-namespace) ARGO_NS="${2:?--argocd-namespace needs a name}"; shift 2 ;;
    --ai-namespace|--identity-namespace|--platform-namespace|--chart|--chart-version|--image-registry|--storage-class|--wait-seconds)
      PASS_FORGE+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    --no-sign-in) PASS_FORGE+=("$1"); shift ;;
    --controller-namespace|--controller-name) PASS_SECRETS+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --keep-copy) KEEP_COPY="${2:?--keep-copy needs a file}"; shift 2 ;;
    --dump) DUMP_FILE="${2:?--dump needs a file}"; shift 2 ;;
    --dump-sha256) DUMP_SHA="${2:?--dump-sha256 needs a SHA-256}"; shift 2 ;;
    --no-review-history) NO_HISTORY=true; shift ;;
    --no-offsite-setup) NO_OFFSITE_SETUP=true; shift ;;
    --drill-wait-minutes) DRILL_WAIT_MIN="${2:?--drill-wait-minutes needs a number}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

TMPD=""; PF_PID=""
cleanup() {
  [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true
  [[ -z "$TMPD" ]] || rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
have_tty() { (: < /dev/tty) 2>/dev/null; }
abspath() {
  local d; d="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s' "$d" "$(basename "$1")"
}
sha_of() {  # FILE -> hex SHA-256 (Linux sha256sum, or macOS shasum)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1 ... $2"; }

# ---------------------------------------------------------------- validate
say "Checking the request"
[[ "$ACTION" == repair && -z "$FROM" ]] && FROM="offsite"
[[ -n "$FROM" ]] || die "--restore-from is required: offsite (the destination named by --offsite-*) or file:PATH"
case "$FROM" in
  offsite) SRC="offsite" ;;
  file:*) SRC="file"; COPY_FILE="${FROM#file:}"
          [[ -r "$COPY_FILE" && -s "$COPY_FILE" ]] || die "cannot read the copy $COPY_FILE, or it is empty" ;;
  *) die "--restore-from must be offsite or file:PATH, not '$FROM'" ;;
esac
[[ "$MAX_AGE_H" =~ ^[0-9]+$ ]] || die "--max-age-hours must be a number: '$MAX_AGE_H'"
[[ -z "$SHA256_GIVEN" || "$SHA256_GIVEN" =~ ^[0-9a-f]{64}$ ]] || die "--sha256 must be 64 lowercase hex characters"
[[ -z "$DUMP_SHA" || "$DUMP_SHA" =~ ^[0-9a-f]{64}$ ]] || die "--dump-sha256 must be 64 lowercase hex characters"
[[ -z "$DUMP_FILE" || "$SRC" == file ]] || die "--dump FILE goes with --restore-from file:PATH; offsite, the dump is read from the destination"
[[ -z "$DUMP_FILE" ]] || { [[ -r "$DUMP_FILE" && -s "$DUMP_FILE" ]] || die "cannot read the forge dump $DUMP_FILE, or it is empty"; }
! $NO_HISTORY || [[ -z "$DUMP_FILE" ]] || die "--dump and --no-review-history do not go together"
[[ "$FORGE_NS" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--namespace is not a namespace name: '$FORGE_NS'"
if $CONTEXT_GIVEN && [[ -z "${CONTEXT// }" ]]; then
  die "--context was given empty. Refusing rather than falling back to the current context."
fi
if [[ -z "$ARGO_NS" && -n "$CONFIG" ]]; then
  [[ -r "$CONFIG" ]] || die "cannot read --config $CONFIG"
  ARGO_NS="$(awk '/^argocd:/{a=1;next} a && /^[^ ]/{a=0} a && /^  namespace:/{print $2; exit}' "$CONFIG" | tr -d "\"'")"
fi
ARGO_NS="${ARGO_NS:-argocd}"
REPO_URL="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000/${ORG}/${REPO}.git"

# The off-site destination: required to read from it, and set up again for the new forge.
OFFSITE=""
[[ -n "$OS_S3_ENDPOINT$OS_S3_BUCKET$OS_S3_CREDS$OS_S3_CA$OS_S3_PREFIX" ]] && OFFSITE="bucket"
if [[ -n "$OS_GIT_URL$OS_GIT_CREDS" ]]; then
  [[ -z "$OFFSITE" ]] || die "give one off-site destination, a bucket OR a git remote, not both"
  OFFSITE="git"
fi
two_lines() {
  local f="$1" what="$2"
  [[ -r "$f" && -s "$f" ]] || die "cannot read $what $f, or it is empty"
  [[ "$(grep -c . "$f")" -ge 2 ]] || die "$what $f must have two lines (an id, then its secret)"
  [[ -z "$(sed -n '1,2{/["\\]/p;}' "$f")" ]] || die "$what $f contains a quote or a backslash, which cannot be passed safely"
}
case "$OFFSITE" in
  bucket)
    [[ "$OS_S3_ENDPOINT" =~ ^https?://[^/[:space:]]+$ ]] || die "--offsite-s3-endpoint must be http(s)://host[:port] with no path: '$OS_S3_ENDPOINT'"
    [[ "$OS_S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "--offsite-s3-bucket is not a bucket name: '$OS_S3_BUCKET'"
    [[ -z "$OS_S3_PREFIX" || "$OS_S3_PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die "--offsite-s3-prefix must be path segments with no leading or trailing slash"
    [[ "$OS_S3_REGION" =~ ^[a-z0-9-]+$ ]] || die "--offsite-s3-region is not a region name: '$OS_S3_REGION'"
    [[ -n "$OS_S3_CREDS" ]] || die "--offsite-s3-credentials FILE is required with a bucket"
    two_lines "$OS_S3_CREDS" --offsite-s3-credentials
    [[ -z "$OS_S3_CA" || -r "$OS_S3_CA" ]] || die "cannot read --offsite-s3-ca $OS_S3_CA" ;;
  git)
    [[ "$OS_GIT_URL" =~ ^https://[^@[:space:]]+$ ]] || die "--offsite-git must be an https URL with no credentials in it"
    [[ -n "$OS_GIT_CREDS" ]] || die "--offsite-git-credentials FILE is required with a git remote"
    two_lines "$OS_GIT_CREDS" --offsite-git-credentials ;;
esac
[[ "$SRC" != offsite || -n "$OFFSITE" ]] || die "--restore-from offsite needs the destination the off-site job wrote to:
         --offsite-s3-endpoint/--offsite-s3-bucket/--offsite-s3-credentials   (a bucket)
         --offsite-git/--offsite-git-credentials                              (a git remote)"

# The kit (rebuild) and the new kit (both).
ENC=""
if [[ "$ACTION" == rebuild ]]; then
  [[ -n "$KIT" ]] || die "--kit FILE is required: the recovery kit bootstrap-forge wrote. It holds the sealing key
       backup a rebuilt cluster needs to open every SealedSecret in the site."
  [[ -r "$KIT" && -s "$KIT" ]] || die "cannot read --kit $KIT, or it is empty"
  if [[ -n "$AGE_IDENTITY" ]]; then
    [[ -r "$AGE_IDENTITY" ]] || die "cannot read --age-identity $AGE_IDENTITY"
    need age "opens an age kit"
  elif [[ -n "$PASSFILE" ]]; then
    [[ -r "$PASSFILE" && -s "$PASSFILE" ]] || die "cannot read --passphrase-file $PASSFILE, or it is empty"
  else
    die "no way to open the kit: give --passphrase-file F (an openssl kit) or --age-identity FILE (an age kit)"
  fi
  # The sealing key backup's own credential: the one given for it, else the kit's.
  [[ -z "$KEY_PASSFILE" || -z "$KEY_AGE_IDENTITY" ]] || die "give the sealing key backup ONE way to open: --key-passphrase-file or --key-age-identity"
  if [[ -z "$KEY_PASSFILE" && -z "$KEY_AGE_IDENTITY" ]]; then KEY_PASSFILE="$PASSFILE"; KEY_AGE_IDENTITY="$AGE_IDENTITY"; fi
  [[ -z "$KEY_PASSFILE" || -r "$KEY_PASSFILE" ]] || die "cannot read --key-passphrase-file $KEY_PASSFILE"
  [[ -z "$KEY_AGE_IDENTITY" || -r "$KEY_AGE_IDENTITY" ]] || die "cannot read --key-age-identity $KEY_AGE_IDENTITY"
  SITE_OUT="${SITE_OUT:-./tockmox-site-restored}"
fi
[[ -n "$KIT_OUT" ]] || die "--kit-out FILE is required: the new forge has new secrets, so the old kit cannot rebuild it.
       This run writes a new kit; keep it where you kept the old one."
KIT_OUT_ABS="$(abspath "$KIT_OUT")" || die "the directory for --kit-out does not exist: $(dirname "$KIT_OUT")"
[[ ! -e "$KIT_OUT_ABS" ]] || die "--kit-out $KIT_OUT_ABS already exists. Refusing to overwrite a recovery kit (it may be your only one);
       name a new file. Nothing was touched."
if [[ -n "$KIT" ]]; then
  [[ "$KIT_OUT_ABS" != "$(abspath "$KIT")" ]] || die "--kit-out names the kit this run is restoring from. Name a new file."
fi
if [[ -n "$AGE_RECIPIENT" ]]; then ENC="age"
elif [[ -n "$AGE_IDENTITY" ]]; then
  need age-keygen "derives the new kit's age recipient from --age-identity (or give --age-recipient)"
  AGE_RECIPIENT="$(age-keygen -y "$AGE_IDENTITY" 2>/dev/null)" || die "cannot derive an age recipient from $AGE_IDENTITY"
  ENC="age"
elif [[ -n "$PASSFILE" ]]; then ENC="openssl"
else die "no way to encrypt the new kit: give --passphrase-file F or --age-recipient R"; fi
if [[ "$ACTION" == repair ]]; then
  if [[ -n "$SEAL_BACKUP" ]]; then [[ -r "$SEAL_BACKUP" && -s "$SEAL_BACKUP" ]] || die "cannot read --sealing-key-backup $SEAL_BACKUP"
    # The same check bootstrap-forge makes, made HERE as well: a repair removes the old
    # forge before it calls bootstrap-forge, so a refusal there would come too late.
    case "$(head -c 34 "$SEAL_BACKUP" | tr -d '\0')" in
      age-encryption.org/v1*|"-----BEGIN AGE ENCRYPTED FILE-----"*|Salted__*) : ;;
      *) die "--sealing-key-backup $SEAL_BACKUP is not bootstrap-secrets' encrypted key export
       (it is neither age nor openssl output; a plain YAML export of the key is the usual cause).
       Write the export first with bootstrap-secrets --mode reuse --backup-out NEW-FILE, then pass
       NEW-FILE here. Nothing was touched." ;;
    esac
  elif ! $NO_SEAL_BACKUP; then
    die "--sealing-key-backup FILE is required for the new kit (bootstrap-secrets' encrypted export),
       or say you keep it elsewhere with --no-sealing-key-backup."
  fi
fi

need git "checks and checks out the copy"
need curl "reads the copy"
need openssl "opens an openssl kit"
need kubectl "talks to the cluster"
need helm "installs the forge"
[[ "$SRC/$OFFSITE" != offsite/bucket ]] || curl --help all 2>/dev/null | grep -- '--aws-sigv4' >/dev/null \
  || die "this curl cannot sign S3 requests (--aws-sigv4, curl 7.75 or newer). Upgrade curl, or fetch the copy
       yourself and use --restore-from file:PATH."
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-restore.XXXXXX")"
ok "request is consistent"

# ---------------------------------------------------------------- the rebuild drill
# `tockmox-install.sh rebuild-drill`: the REAL rebuild command, against the REAL
# latest off-site copy and the REAL recovery kit, on a throwaway cluster. Before it, the
# three refusals a rebuild promises are proven on the same copy and kit, each one a dry
# run that touches no cluster: a stale copy is named as stale, a corrupt bundle is
# refused, a wrong passphrase stops before anything is installed. Then the rebuild runs,
# the drill waits for every Application to be Synced and Healthy, and the result goes to
# the off-site destination as drill/latest (the record format is in
# forge-offsite-copy.sh), where the site's own drill-check job reads it every day and
# TockmoxSiteRebuildDrillOverdue fires when it has failed or is a quarter old. A drill
# that fails still writes its record, so a failure is never silent.
if $DRILL; then
  say "The rebuild drill"
  [[ "$SRC" == offsite ]] || die "a rebuild drill reads the real latest off-site copy: give --restore-from offsite.
       (The disconnected variant, a copy carried in on media, is a later step of this drill.)"
  $CONTEXT_GIVEN && [[ -n "$CONTEXT" ]] || die "a rebuild drill runs on a THROWAWAY cluster: name it with --context.
       Never the site's own cluster: the drill installs a second forge from the copy."
  ! $DRY_RUN || die "--dry-run and a drill do not go together: the drill runs the dry-run checks itself, then the rebuild"
  [[ "$DRILL_WAIT_MIN" =~ ^[0-9]+$ ]] || die "--drill-wait-minutes must be a whole number: '$DRILL_WAIT_MIN'"
  SELF_SH="$HERE/forge-restore.sh"
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  # The run's own arguments, without the drill's: each probe and the rebuild get them.
  BASE_ARGS=(); skip_next=false
  for a in "${ORIG_ARGS[@]}"; do
    if $skip_next; then skip_next=false; continue; fi
    case "$a" in --drill-wait-minutes|--keep-copy) skip_next=true; continue ;; esac
    BASE_ARGS+=("$a")
  done
  RESULT="pass"; REASON=""; PROVEN=(); COPY_COMMIT=""; SECS=0
  fail() { RESULT="fail"; REASON="$*"; err "$*"; }
  # probe NAME WANT RC ARGS...: a dry run with ARGS added must end with exit status RC
  # (0, or 1 for a refusal) and say WANT; it never reaches a cluster.
  probe() {
    local name="$1" want="$2" rc_want="$3"; shift 3
    local log="$TMPD/probe-$name.log" rc
    set +e
    NO_COLOR=1 bash "$SELF_SH" rebuild "${BASE_ARGS[@]}" --dry-run --site-out "$TMPD/probe-$name-site" "$@" >"$log" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq "$rc_want" ]] && grep -q -- "$want" "$log"; then
      [[ "$name" == copy-and-kit ]] || PROVEN+=("$name")
      ok "$name: $(grep -m1 -- "$want" "$log" | sed 's/^[[:space:]✓!✗]*//' | cut -c1-110)"
      return 0
    fi
    fail "the $name check did not behave: exit $rc, wanted $rc_want and '$want'. Its log: $(tail -1 "$log" | cut -c1-200)"
    return 1
  }
  KEEP="$TMPD/latest.bundle"
  if probe copy-and-kit "the copy's main:" 0 --keep-copy "$KEEP"; then
    COPY_COMMIT="$(cat "$KEEP.commit")"
    probe stale "older than --max-age-hours 0" 0 --max-age-hours 0 || true
    head -c "$(( $(wc -c < "$KEEP") - 100 ))" "$KEEP" > "$TMPD/corrupt.bundle"
    cp "$KEEP.sha256" "$TMPD/corrupt.bundle.sha256"
    probe corrupt "corrupt or was changed. Nothing was installed" 1 --restore-from "file:$TMPD/corrupt.bundle" || true
    if [[ -n "$AGE_IDENTITY" ]]; then
      need age-keygen "makes a wrong identity for the wrong-key check"
      age-keygen -o "$TMPD/wrong.identity" >/dev/null 2>&1 || die "age-keygen could not make a wrong identity"
      probe passphrase "the kit did not open whole" 1 --age-identity "$TMPD/wrong.identity" || true
    else
      ( umask 077; printf 'not-the-passphrase-%s\n' "$STAMP" > "$TMPD/wrong.pass" )
      probe passphrase "the kit did not open whole" 1 --passphrase-file "$TMPD/wrong.pass" || true
    fi
  fi
  if [[ "$RESULT" == pass ]]; then
    say "The rebuild, on $CONTEXT"
    T0="$(date +%s)"
    set +e
    if [[ -n "${TOCKMOX_DRILL_REBUILD:-}" ]]; then   # the hermetic tests' stand-in for the rebuild; never set it
      bash -c "$TOCKMOX_DRILL_REBUILD" > "$TMPD/rebuild.log" 2>&1
    else
      # --no-offsite-setup: the throwaway forge must never write to the site's destination.
      bash "$SELF_SH" rebuild "${BASE_ARGS[@]}" --no-offsite-setup 2>&1 | tee "$TMPD/rebuild.log"
      (exit "${PIPESTATUS[0]}")
    fi
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      fail "the rebuild command failed (exit $rc): $(grep -m1 '✗' "$TMPD/rebuild.log" | sed 's/^[[:space:]✗]*//' | cut -c1-200)"
    elif [[ "$DRILL_WAIT_MIN" -gt 0 ]]; then
      info "waiting up to $DRILL_WAIT_MIN min for every Application in $ARGO_NS to be Synced and Healthy"
      deadline=$(( $(date +%s) + DRILL_WAIT_MIN * 60 )); apps=""
      while :; do
        apps="$(kubectl --context "$CONTEXT" -n "$ARGO_NS" get applications.argoproj.io \
          -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null || true)"
        total="$(printf '%s\n' "$apps" | grep -c . || true)"
        good="$(printf '%s\n' "$apps" | awk '$2=="Synced" && $3=="Healthy"' | grep -c . || true)"
        [[ "$total" -gt 0 && "$good" -eq "$total" ]] && break
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
          fail "after $DRILL_WAIT_MIN min, $good of $total Applications are Synced and Healthy: $(printf '%s\n' "$apps" | awk '!($2=="Synced" && $3=="Healthy"){printf "%s %s/%s; ", $1, $2, $3}' | cut -c1-200)"
          break
        fi
        sleep 15
      done
      [[ "$RESULT" == pass ]] && ok "all $total Applications Synced and Healthy"
    fi
    SECS=$(( $(date +%s) - T0 ))
  fi

  say "The drill's record"
  {
    echo "format tockmox-rebuild-drill v1"
    echo "result $RESULT"
    echo "created $STAMP"
    echo "copy-commit ${COPY_COMMIT:-unknown}"
    echo "seconds $SECS"
    echo "refusals $(IFS=,; echo "${PROVEN[*]:-none}")"
    [[ -z "$REASON" ]] || echo "reason $(printf '%s' "$REASON" | tr '\n' ' ' | cut -c1-300)"
  } > "$TMPD/drill.record"
  if [[ "$OFFSITE" == bucket ]]; then
    AK="$(sed -n 1p "$OS_S3_CREDS")"; SK="$(sed -n 2p "$OS_S3_CREDS")"
    dkey() { if [[ -n "$OS_S3_PREFIX" ]]; then printf '%s/%s' "$OS_S3_PREFIX" "$1"; else printf '%s' "$1"; fi; }
    s3_call() {  # METHOD KEY FILE -> HTTP status; PUT uploads FILE, GET writes it
      local -a a=(-sS -K - --aws-sigv4 "aws:amz:${OS_S3_REGION}:s3" --connect-timeout 15 --max-time 120 -w '%{http_code}')
      [[ -z "$OS_S3_CA" ]] || a+=(--cacert "$OS_S3_CA")
      if [[ "$1" == PUT ]]; then a+=(-o /dev/null --upload-file "$3"); else a+=(-o "$3"); fi
      printf 'user = "%s:%s"\n' "$AK" "$SK" | curl "${a[@]}" "$OS_S3_ENDPOINT/$OS_S3_BUCKET/$2" || true
    }
    st="$(s3_call PUT "$(dkey "drill/$STAMP")" "$TMPD/drill.record")"
    [[ "$st" == 2?? ]] || die "writing the drill's record $(dkey "drill/$STAMP") failed: HTTP $st. The drill's result ($RESULT) is in no record."
    st="$(s3_call PUT "$(dkey drill/latest)" "$TMPD/drill.record")"
    [[ "$st" == 2?? ]] || die "writing $(dkey drill/latest) failed: HTTP $st. The drill's result ($RESULT) is only in $(dkey "drill/$STAMP")."
    st="$(s3_call GET "$(dkey drill/latest)" "$TMPD/drill.back")"
    { [[ "$st" == 200 ]] && cmp -s "$TMPD/drill.record" "$TMPD/drill.back"; } || die "$(dkey drill/latest) does not read back as written (HTTP $st)"
    WHERE="$OS_S3_BUCKET/$(dkey drill/latest)"
  else
    GH="Authorization: Basic $(printf '%s:%s' "$(sed -n 1p "$OS_GIT_CREDS")" "$(sed -n 2p "$OS_GIT_CREDS")" | base64 | tr -d '\n')"
    rgit() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$GH" GIT_TERMINAL_PROMPT=0 git "$@"; }
    DR="$TMPD/drill-repo"; git init -q "$DR"
    if rgit ls-remote --exit-code "$OS_GIT_URL" refs/heads/forge-drill >/dev/null 2>&1; then
      rgit -C "$DR" fetch -q "$OS_GIT_URL" forge-drill || die "cannot fetch forge-drill from $OS_GIT_URL"
      git -C "$DR" checkout -q -B forge-drill FETCH_HEAD
    else
      git -C "$DR" checkout -q --orphan forge-drill
    fi
    mkdir -p "$DR/drill"; cp "$TMPD/drill.record" "$DR/drill/$STAMP"; cp "$TMPD/drill.record" "$DR/drill/latest"
    git -C "$DR" add drill
    git -C "$DR" -c user.name=tockmox-rebuild-drill -c user.email=tockmox-rebuild-drill@localhost.invalid \
      commit -q -m "Rebuild drill $STAMP: $RESULT"
    # No --force: a remote that refuses rewrites keeps every earlier record.
    rgit -C "$DR" push -q "$OS_GIT_URL" forge-drill || die "pushing the drill's record to $OS_GIT_URL forge-drill failed. The drill's result ($RESULT) is in no record."
    got="$(rgit ls-remote "$OS_GIT_URL" refs/heads/forge-drill | awk 'NR==1{print $1}')"
    [[ "$got" == "$(git -C "$DR" rev-parse HEAD)" ]] || die "forge-drill on $OS_GIT_URL is not the record just pushed"
    WHERE="$OS_GIT_URL forge-drill"
  fi
  ok "record written to $WHERE and read back"
  if [[ "$RESULT" == pass ]]; then
    ok "rebuild drill PASSED in $SECS s from ${COPY_COMMIT:0:12}; refusals proven: $(IFS=,; echo "${PROVEN[*]}")"
    info "the site's drill-check job reads this record daily; the next drill is due within 92 days"
    exit 0
  fi
  err "rebuild drill FAILED: $REASON"
  info "the record says so, and the site's TockmoxSiteRebuildDrillOverdue alert fires within a day"
  exit 1
fi

# ---------------------------------------------------------------- the copy
say "The off-site copy"
BUNDLE="$TMPD/site.bundle"; WANT_COMMIT=""
if [[ "$SRC" == file ]]; then
  cp "$COPY_FILE" "$BUNDLE"
  if [[ -z "$SHA256_GIVEN" ]]; then
    [[ -r "$COPY_FILE.sha256" ]] || die "no checksum for $COPY_FILE: put its .sha256 beside it (the off-site job writes one with
       every bundle) or give --sha256 HEX. A copy carried in on media is not trusted unchecked."
    SHA256_GIVEN="$(awk 'NR==1{print $1}' "$COPY_FILE.sha256")"
    [[ "$SHA256_GIVEN" =~ ^[0-9a-f]{64}$ ]] || die "$COPY_FILE.sha256 does not start with a SHA-256"
  fi
  GOT="$(sha_of "$BUNDLE")"
  [[ "$GOT" == "$SHA256_GIVEN" ]] || die "the copy's SHA-256 is $GOT, not $SHA256_GIVEN: the file is corrupt or was changed. Nothing was installed."
  ok "file copy matches its SHA-256 (${GOT:0:16}...)"
elif [[ "$OFFSITE" == bucket ]]; then
  AK="$(sed -n 1p "$OS_S3_CREDS")"; SK="$(sed -n 2p "$OS_S3_CREDS")"
  key_of() { if [[ -n "$OS_S3_PREFIX" ]]; then printf '%s/%s' "$OS_S3_PREFIX" "$1"; else printf '%s' "$1"; fi; }
  s3_get() {  # KEY OUTFILE -> HTTP status on stdout
    local -a a=(-sS -K - --aws-sigv4 "aws:amz:${OS_S3_REGION}:s3" --connect-timeout 15 --max-time 600 -o "$2" -w '%{http_code}')
    [[ -z "$OS_S3_CA" ]] || a+=(--cacert "$OS_S3_CA")
    printf 'user = "%s:%s"\n' "$AK" "$SK" | curl "${a[@]}" "$OS_S3_ENDPOINT/$OS_S3_BUCKET/$1" || true
  }
  st="$(s3_get "$(key_of latest)" "$TMPD/latest")"
  [[ "$st" == 200 ]] || die "reading the copy's pointer ($(key_of latest)) from $OS_S3_ENDPOINT/$OS_S3_BUCKET failed: HTTP $st.
       Is this the bucket the off-site job writes to, with credentials that can read it? Nothing was installed."
  [[ "$(head -1 "$TMPD/latest")" == "$COPY_FORMAT" ]] || die "the copy's pointer is not '$COPY_FORMAT': $(head -c 80 "$TMPD/latest")"
  field() { awk -v k="$1" '$1==k{print $2; exit}' "$TMPD/latest"; }
  WANT_COMMIT="$(field commit)"; BKEY="$(field bundle)"; BSUM="$(field sha256)"; COPY_CREATED="$(field created)"
  [[ "$WANT_COMMIT" =~ ^[0-9a-f]{40}$ && -n "$BKEY" && "$BSUM" =~ ^[0-9a-f]{64}$ ]] \
    || die "the copy's pointer is incomplete (commit, bundle and sha256 are required)"
  case "$BKEY" in *..*|/*) die "the copy's pointer names an unsafe key: $BKEY" ;; esac
  st="$(s3_get "$BKEY" "$BUNDLE")"
  [[ "$st" == 200 ]] || die "reading the bundle $BKEY failed: HTTP $st. Nothing was installed."
  GOT="$(sha_of "$BUNDLE")"
  [[ "$GOT" == "$BSUM" ]] || die "the bundle's SHA-256 is $GOT, but the pointer says $BSUM: the bundle is corrupt or was
       replaced. A versioned bucket keeps the earlier ones. Nothing was installed."
  st="$(s3_get "$BKEY.sha256" "$TMPD/bundle.sha256")"
  if [[ "$st" == 200 ]]; then
    [[ "$(awk 'NR==1{print $1}' "$TMPD/bundle.sha256")" == "$GOT" ]] \
      || die "the bundle's own .sha256 object disagrees with the bundle: something in the bucket was changed. Nothing was installed."
  else warn "the bundle has no .sha256 object beside it (HTTP $st); checked against the pointer only"; fi
  ok "bucket copy: $BKEY, SHA-256 matches the pointer"
else
  GH="Authorization: Basic $(printf '%s:%s' "$(sed -n 1p "$OS_GIT_CREDS")" "$(sed -n 2p "$OS_GIT_CREDS")" | base64 | tr -d '\n')"
  git init -q --bare "$TMPD/remote.git"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$GH" GIT_TERMINAL_PROMPT=0 \
    git -C "$TMPD/remote.git" fetch -q "$OS_GIT_URL" "+refs/heads/main:refs/heads/main" \
    || die "fetching main from $OS_GIT_URL failed. Is it the remote the forge mirrors to, and can these credentials read it?"
  git -C "$TMPD/remote.git" symbolic-ref HEAD refs/heads/main
  git -C "$TMPD/remote.git" bundle create "$BUNDLE" HEAD refs/heads/main >/dev/null 2>&1 \
    || die "could not make a bundle of the remote's main"
  ok "git remote copy: main fetched from $OS_GIT_URL"
fi
# Whatever the source: git itself must accept the bundle, and it must hold main.
# `git bundle verify` reads only the bundle's header, so a bundle cut short after it
# still verifies (measured). Fetching from it runs index-pack, which checks every object.
git init -q --bare "$TMPD/check.git"
{ git -C "$TMPD/check.git" bundle verify "$BUNDLE" >/dev/null 2>&1 \
  && git -C "$TMPD/check.git" fetch -q "$BUNDLE" "+refs/heads/*:refs/heads/*" >/dev/null 2>&1; } \
  || die "git does not accept the copy as a bundle (corrupt or incomplete). Nothing was installed."
HEADS="$(git bundle list-heads "$BUNDLE" 2>/dev/null)"
MAIN="$(printf '%s\n' "$HEADS" | awk '$2=="refs/heads/main"{print $1; exit}')"
[[ -n "$MAIN" ]] || die "the copy holds no main branch. Nothing was installed."
if [[ -n "$WANT_COMMIT" && "$MAIN" != "$WANT_COMMIT" ]]; then
  die "the bundle's main is $MAIN, but the copy's pointer names $WANT_COMMIT. Nothing was installed."
fi
if [[ -n "$KEEP_COPY" ]]; then
  { cp "$BUNDLE" "$KEEP_COPY" && printf '%s  site.bundle\n' "$(sha_of "$BUNDLE")" > "$KEEP_COPY.sha256" \
    && printf '%s\n' "$MAIN" > "$KEEP_COPY.commit"; } || die "cannot keep the copy as $KEEP_COPY"
  ok "copy kept as $KEEP_COPY (with .sha256 and .commit)"
fi

# The site: checked out where the operator can keep it (rebuild) or in the temp dir (repair).
if [[ "$ACTION" == rebuild ]]; then
  SITE_ABS="$(abspath "$SITE_OUT")" || die "the directory for --site-out does not exist: $(dirname "$SITE_OUT")"
  [[ ! -e "$SITE_ABS" ]] || die "--site-out $SITE_ABS already exists. Name a new directory; nothing was installed."
else
  SITE_ABS="$TMPD/tockmox-site"   # its name is what the new kit records as the site
fi
git clone -q --branch main "$BUNDLE" "$SITE_ABS" 2>/dev/null || die "checking the copy out failed"
git -C "$SITE_ABS" remote remove origin >/dev/null 2>&1 || true
[[ -f "$SITE_ABS/bootstrap/root.yaml" ]] || die "the copy has no bootstrap/root.yaml: it is not a Tockmox site repository"
grep -Eqs "^[[:space:]-]*repoURL:[[:space:]]*[\"']?${REPO_URL//./\\.}[\"']?[[:space:]]*\$" "$SITE_ABS/bootstrap/root.yaml" || die "the copy's bootstrap/root.yaml does not name the built-in forge at
         $REPO_URL
       It is not a built-in-forge site, or it used another --namespace. Nothing was installed."
WHEN="$(git -C "$SITE_ABS" log -1 --format=%ct main)"
NOW="$(date +%s)"; AGE_S=$(( NOW - WHEN ))
[[ "$AGE_S" -ge 0 ]] || { warn "the copy's latest commit is dated in the future (a clock is wrong somewhere)"; AGE_S=0; }
if   [[ "$AGE_S" -lt 3600 ]];  then AGE_TXT="$(( AGE_S / 60 )) min old"
elif [[ "$AGE_S" -lt 172800 ]]; then AGE_TXT="$(( AGE_S / 3600 )) h old"
else AGE_TXT="$(( AGE_S / 86400 )) days old"; fi
SUBJECT="$(git -C "$SITE_ABS" log -1 --format=%s main | cut -c1-72)"
ok "the copy's main: ${MAIN:0:12} \"$SUBJECT\" ($AGE_TXT; $(git -C "$SITE_ABS" rev-list --count main) commits)"
if [[ "$AGE_S" -gt $(( MAX_AGE_H * 3600 )) ]]; then
  warn "the copy's latest commit is $AGE_TXT, older than --max-age-hours $MAX_AGE_H. If the site changed after it,
       those changes are not in this copy: they are in no copy at all, or in a newer one somewhere else."
fi
[[ -z "${COPY_CREATED:-}" ]] || info "the bucket's pointer says this copy was written at $COPY_CREATED (UTC)"
info "nothing here can tell how far it is behind the forge that is gone; its age is what it is"

# ---------------------------------------------------------------- the forge dump
# Read and checked here, beside the copy, before anything touches a cluster. Format and
# writer: forge-offsite-copy.sh TASK=dump. The counts check is forge-history.py's.
DUMP_DIR=""
if $NO_HISTORY; then
  info "review history: not restored (--no-review-history)"
else
  say "The forge dump"
  DTGZ="$TMPD/dump.tar.gz"; DX="$TMPD/dump"; HAVE_DUMP=false; DUMP_WHERE=""
  if [[ "$SRC" == file ]]; then
    if [[ -n "$DUMP_FILE" ]]; then
      if [[ -z "$DUMP_SHA" ]]; then
        [[ -r "$DUMP_FILE.sha256" ]] || die "no checksum for the forge dump $DUMP_FILE: put its .sha256 beside it (the off-site job
       writes one with every dump) or give --dump-sha256 HEX. Nothing was installed."
        DUMP_SHA="$(awk 'NR==1{print $1}' "$DUMP_FILE.sha256")"
        [[ "$DUMP_SHA" =~ ^[0-9a-f]{64}$ ]] || die "$DUMP_FILE.sha256 does not start with a SHA-256"
      fi
      cp "$DUMP_FILE" "$DTGZ"
      GOT="$(sha_of "$DTGZ")"
      [[ "$GOT" == "$DUMP_SHA" ]] || die "the forge dump's SHA-256 is $GOT, not $DUMP_SHA: the file is corrupt or was changed. Nothing was installed."
      HAVE_DUMP=true; DUMP_WHERE="$DUMP_FILE"
    else
      DUMP_WHERE="the media (no --dump given)"
    fi
  elif [[ "$OFFSITE" == bucket ]]; then
    DUMP_WHERE="$OS_S3_BUCKET/$(key_of latest-dump)"
    st="$(s3_get "$(key_of latest-dump)" "$TMPD/latest-dump")"
    if [[ "$st" == 200 ]]; then
      [[ "$(head -1 "$TMPD/latest-dump")" == "format tockmox-forge-dump v1" ]] \
        || die "the forge dump's pointer is not 'format tockmox-forge-dump v1': $(head -c 80 "$TMPD/latest-dump")"
      DKEY="$(awk '$1=="dump"{print $2; exit}' "$TMPD/latest-dump")"
      DSUM="$(awk '$1=="sha256"{print $2; exit}' "$TMPD/latest-dump")"
      [[ -n "$DKEY" && "$DSUM" =~ ^[0-9a-f]{64}$ ]] || die "the forge dump's pointer is incomplete (dump and sha256 are required)"
      case "$DKEY" in *..*|/*) die "the forge dump's pointer names an unsafe key: $DKEY" ;; esac
      st="$(s3_get "$DKEY" "$DTGZ")"
      [[ "$st" == 200 ]] || die "reading the forge dump $DKEY failed: HTTP $st. Nothing was installed.
       (--no-review-history rebuilds without it.)"
      GOT="$(sha_of "$DTGZ")"
      [[ "$GOT" == "$DSUM" ]] || die "the forge dump's SHA-256 is $GOT, but latest-dump says $DSUM: the dump is corrupt or was
       replaced. Nothing was installed. (--no-review-history rebuilds without it.)"
      HAVE_DUMP=true; DUMP_WHERE="$DKEY"
    elif [[ "$st" != 404 ]]; then
      die "reading the forge dump's pointer $(key_of latest-dump) failed: HTTP $st. Nothing was installed.
       (--no-review-history rebuilds without it.)"
    fi
  else
    DUMP_WHERE="$OS_GIT_URL forge-dump"
    set +e
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$GH" GIT_TERMINAL_PROMPT=0 \
      git ls-remote --exit-code "$OS_GIT_URL" refs/heads/forge-dump >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$GH" GIT_TERMINAL_PROMPT=0 \
        git -C "$TMPD/remote.git" fetch -q "$OS_GIT_URL" "+refs/heads/forge-dump:refs/heads/forge-dump" 2>/dev/null \
        || die "fetching forge-dump from $OS_GIT_URL failed. Nothing was installed. (--no-review-history rebuilds without it.)"
      mkdir -p "$TMPD/dumpx"
      git -C "$TMPD/remote.git" archive refs/heads/forge-dump dump | tar -x -C "$TMPD/dumpx" \
        || die "the remote's forge-dump branch holds no dump/ directory. Nothing was installed."
      DX="$TMPD/dumpx/dump"; HAVE_DUMP=true
    elif [[ "$rc" -ne 2 ]]; then
      die "asking $OS_GIT_URL for its forge-dump branch failed. Nothing was installed. (--no-review-history rebuilds without it.)"
    fi
  fi
  if $HAVE_DUMP; then
    need python3 "reads the forge dump"
    if [[ -f "$DTGZ" && ! -d "$TMPD/dumpx" ]]; then
      mkdir -p "$DX"
      tar -xzf "$DTGZ" -C "$DX" 2>/dev/null || die "the forge dump does not unpack. Nothing was installed."
    fi
    set +e
    DOUT="$(python3 "$HERE/forge-history.py" check "$DX" 2>&1)"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] || die "the forge dump does not read whole: ${DOUT#forge-history: }. Nothing was installed.
       (--no-review-history rebuilds without it.)"
    DREPO="$(awk '$1=="repository"{print $2; exit}' "$DX/MANIFEST")"
    [[ "$DREPO" == "$ORG/$REPO" ]] || die "the forge dump is of $DREPO, not $ORG/$REPO: it belongs to another site. Nothing was installed."
    DCREATED="$(awk '$1=="created"{print $2; exit}' "$DX/MANIFEST")"
    DAGE="$(python3 -c 'import sys, calendar, time
try:
    s = int(time.time()) - calendar.timegm(time.strptime(sys.argv[1], "%Y%m%dT%H%M%SZ"))
except ValueError:
    print("of unknown age"); sys.exit(0)
s = max(s, 0)
print("%d min old" % (s // 60) if s < 3600 else ("%d h old" % (s // 3600) if s < 172800 else "%d days old" % (s // 86400)))' "$DCREATED")"
    ok "forge dump: ${DOUT#dump } ($DAGE)"
    info "each pull request in it returns as a closed issue labelled restored-from-dump"
    DUMP_DIR="$DX"
  else
    warn "no forge dump at $DUMP_WHERE: the review history is not restored (review comments since the last dump are lost either way)"
  fi
fi

# ---------------------------------------------------------------- the kit (rebuild)
if [[ "$ACTION" == rebuild ]]; then
  say "The recovery kit"
  decrypt_kit() {
    if [[ -n "$AGE_IDENTITY" ]]; then age -d -i "$AGE_IDENTITY" < "$KIT"
    else openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -pass "file:$PASSFILE" < "$KIT"; fi
  }
  # One pass over the stream: check the marker and the end line, and write out only the
  # sealing key backup's section (base64 of an ENCRYPTED file) and the manifest lines.
  SEAL_FILE="$TMPD/sealing-key-backup.enc"
  set +e
  ( umask 077; decrypt_kit 2>/dev/null | awk -v m="$KIT_MARKER" -v seal="$TMPD/seal.b64" -v man="$TMPD/manifest" '
      NR==1 { if ($0 != m) { bad=1; exit } ; next }
      /^=== / { sec=$0; if (sec=="=== end") ended=1; next }
      sec=="" { print > man; next }
      sec=="=== sealed-secrets.key.enc (base64)" { print > seal }
      END { if (bad || !ended) exit 3 }' )
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || die "the kit did not open whole: a wrong passphrase or identity, a file that is not a Tockmox
       recovery kit, or one cut short. Nothing was installed."
  ok "kit opened: $(awk -F': ' '$1=="created"{print "made "$2}' "$TMPD/manifest"), $(awk -F': ' '$1=="site"{print "site "$2}' "$TMPD/manifest")"
  KIT_REPO="$(awk -F': ' '$1=="repository"{print $2}' "$TMPD/manifest")"
  [[ -z "$KIT_REPO" || "$KIT_REPO" == "$REPO_URL" ]] || warn "the kit was written for $KIT_REPO, and this copy names $REPO_URL"
  [[ -s "$TMPD/seal.b64" ]] || die "the kit carries no sealing key backup (it was written with --no-sealing-key-backup).
       A rebuilt cluster cannot open the site's SealedSecrets without one; restore the key yourself
       (bootstrap-secrets --mode recover) and run repair-forge instead. Nothing was installed."
  ( umask 077; base64 -d < "$TMPD/seal.b64" > "$SEAL_FILE" 2>/dev/null || base64 -D < "$TMPD/seal.b64" > "$SEAL_FILE" ) \
    || die "the kit's sealing key backup is not valid base64"
  # Prove the sealing key backup opens too, here, before a controller is installed.
  set +e
  if [[ -n "$KEY_AGE_IDENTITY" ]]; then first="$(age -d -i "$KEY_AGE_IDENTITY" < "$SEAL_FILE" 2>/dev/null | head -1)"
  else first="$(openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -pass "file:$KEY_PASSFILE" < "$SEAL_FILE" 2>/dev/null | head -1)"; fi
  set -e
  [[ "$first" == "# tockmox-sealed-secrets-key-backup v1" ]] || die "the kit's sealing key backup does not open with the key you gave
       (--key-passphrase-file or --key-age-identity, which default to the kit's own). Nothing was installed."
  ok "sealing key backup opens"
  SEAL_BACKUP="$SEAL_FILE"
  info "the forge's own settings are recreated by bootstrap-forge. Who approved each change is in the merge"
  info "commits. People's accounts return at their next sign-in."
fi

if $DRY_RUN; then
  say "Plan (dry run, nothing changed)"
  if [[ "$ACTION" == rebuild ]]; then
    info "restore the sealing key and install the controller (bootstrap-secrets --mode recover)"
    info "install the forge and seed it from the copy (${MAIN:0:12}); write the new kit to $KIT_OUT"
    [[ -z "$DUMP_DIR" ]] || info "restore the review history from the forge dump as closed issues"
    info "apply $SITE_ABS/bootstrap/root.yaml"
  else
    info "reinstall the forge in $FORGE_NS and seed it from the copy (${MAIN:0:12}); nothing else is touched"
    [[ -z "$DUMP_DIR" ]] || info "restore the review history from the forge dump as closed issues"
    info "write the new kit to $KIT_OUT"
  fi
  exit 0
fi

# ---------------------------------------------------------------- context
say "Cluster context"
CTX_CUR="$(kubectl config current-context 2>/dev/null || true)"
CTX="${CONTEXT:-$CTX_CUR}"
[[ -n "$CTX" ]] || die "no kubectl context is set and none was given. Name one with --context."
SERVER="$(kubectl config view --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
info "context     ${CTX}"
info "API server  ${SERVER:-unknown}"
[[ -n "$SERVER" ]] || die "cannot read the API server address for context '$CTX', so it cannot be confirmed. Refusing."
if [[ -n "$YES_CONTEXT" ]]; then
  [[ "$YES_CONTEXT" == "$CTX" ]] || die "--yes-context '$YES_CONTEXT' does not match the context in use, '$CTX'. Refusing."
  [[ "$YES_SERVER" == "$SERVER" ]] || die "--yes-server must equal the API server in use, '$SERVER'. Refusing."
else
  $NO_PROMPT && die "--no-prompt was given without --yes-context and --yes-server. Re-run with
       --yes-context '$CTX' --yes-server '$SERVER' if that is the cluster you mean."
  have_tty || die "no terminal to confirm the context on. Re-run with --yes-context '$CTX' --yes-server '$SERVER'."
  printf '  Type the context name to write to that cluster: '; read -r ANS </dev/tty || ANS=""
  [[ "$ANS" == "$CTX" ]] || die "not confirmed. Nothing was touched."
  printf '  Type the API server it reaches (as shown above): '; read -r ANS </dev/tty || ANS=""
  [[ "$ANS" == "$SERVER" ]] || die "not confirmed. Nothing was touched."
fi
K=(--context "$CTX")
CONFIRM=(--context "$CTX" --yes-context "$CTX" --yes-server "$SERVER" --no-prompt)
kubectl "${K[@]}" get namespace "$ARGO_NS" >/dev/null 2>&1 || die "namespace $ARGO_NS does not exist. A rebuild starts from a cluster with
       Argo CD installed (docs/deployment/fresh-install.md section 6), and a repair from a running site."
ok "cluster reachable, Argo CD namespace $ARGO_NS present"

FORGE_FLAGS=(--site "$SITE_ABS" --kit-out "$KIT_OUT" --argocd-namespace "$ARGO_NS" "${CONFIRM[@]}")
case "$ENC" in age) FORGE_FLAGS+=(--age-recipient "$AGE_RECIPIENT") ;; openssl) FORGE_FLAGS+=(--passphrase-file "$PASSFILE") ;; esac
if [[ -n "$SEAL_BACKUP" ]]; then FORGE_FLAGS+=(--sealing-key-backup "$SEAL_BACKUP"); else FORGE_FLAGS+=(--no-sealing-key-backup); fi
# The rebuild drill's throwaway forge reads the site's destination and never writes to it:
# its push mirror would force-push its (older) main over the site's copy.
$NO_OFFSITE_SETUP && OFFSITE_FOR_FORGE="" || OFFSITE_FOR_FORGE="$OFFSITE"
case "$OFFSITE_FOR_FORGE" in
  bucket) FORGE_FLAGS+=(--offsite-s3-endpoint "$OS_S3_ENDPOINT" --offsite-s3-bucket "$OS_S3_BUCKET" \
            --offsite-s3-region "$OS_S3_REGION" --offsite-s3-credentials "$OS_S3_CREDS")
          [[ -z "$OS_S3_PREFIX" ]] || FORGE_FLAGS+=(--offsite-s3-prefix "$OS_S3_PREFIX")
          [[ -z "$OS_S3_CA" ]] || FORGE_FLAGS+=(--offsite-s3-ca "$OS_S3_CA") ;;
  git) FORGE_FLAGS+=(--offsite-git "$OS_GIT_URL" --offsite-git-credentials "$OS_GIT_CREDS") ;;
esac
FORGE_FLAGS+=(--namespace "$FORGE_NS")
[[ -z "$DUMP_DIR" ]] || FORGE_FLAGS+=(--restore-history "$DUMP_DIR")
FORGE_FLAGS+=(${PASS_FORGE[@]+"${PASS_FORGE[@]}"})

# Applications and their state, so a repair can show it touched nothing else.
apps_state() {  # name revision health, one line each; fails (no output) when the API does not answer
  local out
  out="$(kubectl "${K[@]}" -n "$ARGO_NS" get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.revision}{.status.sync.revisions[0]}{" "}{.status.health.status}{"\n"}{end}')" || return 1
  printf '%s\n' "$out" | sort
}
apps_reconciled_since() {  # EPOCH -> how many Applications Argo CD has compared since then
  kubectl "${K[@]}" -n "$ARGO_NS" get applications.argoproj.io -o jsonpath='{range .items[*]}{.status.reconciledAt}{"\n"}{end}' 2>/dev/null \
    | while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        # GNU and BusyBox date read "YYYY-MM-DD hh:mm:ss" (BusyBox refuses the T and Z,
        # measured); macOS date needs -j -f. A time none of them reads counts as not compared.
        t2="${ts%Z}"; t2="${t2/T/ }"
        e="$(date -u -d "$t2" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || echo 0)"
        [[ "$e" -ge "$1" ]] && echo x
      done | grep -c x || true
}

# ---------------------------------------------------------------- repair
if [[ "$ACTION" == repair ]]; then
  say "The forge as it stands"
  if helm --kube-context "$CTX" -n "$FORGE_NS" status "$RELEASE" >/dev/null 2>&1; then
    READY="$(kubectl "${K[@]}" -n "$FORGE_NS" get deploy "$RELEASE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    HELD=""
    if [[ "${READY:-0}" -ge 1 ]]; then
      HELD="$(kubectl "${K[@]}" -n "$FORGE_NS" exec deploy/"$RELEASE" -c forgejo -- \
        git --git-dir=/data/git/gitea-repositories/${ORG}/${REPO}.git rev-parse --verify -q refs/heads/main 2>/dev/null || true)"
    fi
    PVC_PHASE="$(kubectl "${K[@]}" -n "$FORGE_NS" get pvc gitea-shared-storage -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    info "release $RELEASE in $FORGE_NS: ready replicas ${READY:-0}; main ${HELD:-not readable}; volume ${PVC_PHASE:-absent}"
    # The decision needs evidence either way. A volume that is gone (or Lost) is what a
    # repair is for. A volume that is still there while the forge could not be asked
    # what it holds (a pod that is not Ready yet, a slow image pull, an exec timeout)
    # may hold commits the copy lacks, so it is not deleted on a guess.
    if [[ -z "$HELD" && -n "$PVC_PHASE" && "$PVC_PHASE" != Lost ]] && ! $FORCE; then
      die "the forge's volume (gitea-shared-storage) is still there, ${PVC_PHASE}, but the forge could not be asked what it
       holds (ready replicas ${READY:-0}). It may hold commits the copy lacks. Find out why the forge is down first:
         kubectl --context $CTX -n $FORGE_NS get pods,events
       If the volume's contents are lost or unwanted, re-run with --force. Nothing was touched."
    fi
    if [[ -n "$HELD" ]] && ! $FORCE; then
      if [[ "$HELD" == "$MAIN" ]] || git -C "$SITE_ABS" merge-base --is-ancestor "$MAIN" "$HELD" 2>/dev/null \
         || ! git -C "$SITE_ABS" cat-file -e "$HELD" 2>/dev/null; then
        die "the forge answers and holds main at ${HELD:0:12}$( [[ "$HELD" == "$MAIN" ]] && echo ", the copy's commit" || echo ", which the copy does not have or is behind").
       There is nothing to repair, and a reinstall would lose whatever the copy lacks. If you mean it, --force."
      fi
    fi
    BEFORE="$(apps_state)" || die "cannot list Argo CD's Applications in $ARGO_NS, so this repair could not show it changed nothing else"
    warn "reinstalling the forge: its release and its volume are removed, then it is seeded from the copy"
    helm --kube-context "$CTX" -n "$FORGE_NS" uninstall "$RELEASE" --wait --timeout 180s >/dev/null \
      || die "helm could not uninstall $RELEASE; nothing else was changed"
    # The chart keeps its claim on uninstall (measured). A repair is a fresh volume.
    kubectl "${K[@]}" -n "$FORGE_NS" delete pvc gitea-shared-storage --ignore-not-found --wait=true --timeout=120s >/dev/null \
      || die "could not remove the forge's old volume claim (gitea-shared-storage)"
    ok "old forge removed (release and volume); the Secrets this installer wrote stay, so sign-in keeps its OIDC client secret"
  else
    BEFORE="$(apps_state)" || die "cannot list Argo CD's Applications in $ARGO_NS, so this repair could not show it changed nothing else"
    info "no forge release in $FORGE_NS: installing one"
  fi
  say "Seeding a new forge from the copy"
  bash "$HERE/bootstrap-forge.sh" "${FORGE_FLAGS[@]}" || die "bootstrap-forge did not finish; see above. The copy and your kit are unchanged."
  say "Everything else"
  # Argo CD retries a repository it could not read on its own; ask once now, wait until
  # every Application has been compared AFTER the new forge answered (a status read
  # before that is the one from before the repair), then compare both ways.
  SEEDED="$(date +%s)"
  NAPPS="$(printf '%s\n' "$BEFORE" | grep -c . || true)"
  for a in $(printf '%s\n' "$BEFORE" | awk 'NF{print $1}'); do
    kubectl "${K[@]}" -n "$ARGO_NS" annotate application.argoproj.io "$a" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 36); do
    [[ "$(apps_reconciled_since "$SEEDED")" -ge "$NAPPS" ]] && break
    sleep 5
  done
  AFTER="$(apps_state)" || die "the forge is repaired, but Argo CD's Applications could not be listed to compare"
  CHANGED="$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -E '^[<>]' || true)"
  ERRS="$(kubectl "${K[@]}" -n "$ARGO_NS" get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[*].type}{"\n"}{end}' 2>/dev/null | awk '/ComparisonError/{print $1}')"
  FRESH="$(apps_reconciled_since "$SEEDED")"
  if [[ -z "$CHANGED" && -z "$ERRS" && "$FRESH" -ge "$NAPPS" ]]; then
    ok "all $NAPPS Applications were compared against the new forge and read the same revision and health as before"
  else
    [[ "$FRESH" -ge "$NAPPS" ]] || warn "only $FRESH of $NAPPS Applications were compared against the new forge in 3 minutes"
    [[ -z "$ERRS" ]] || warn "still reporting ComparisonError: $(printf '%s' "$ERRS" | tr '\n' ' ')"
    if [[ -n "$CHANGED" ]]; then
      warn "Applications whose revision or health differs from before the repair (< before, > now):"
      printf '%s\n' "$CHANGED" | sed 's/^/      /'
    fi
  fi
  say "Done"
  ok "the forge was repaired from the copy at ${MAIN:0:12} ($AGE_TXT)"
  info "keep the new recovery kit ($KIT_OUT); the old one no longer matches this forge"
  exit 0
fi

# ---------------------------------------------------------------- rebuild
say "The sealing key"
KEY_DEC=(--passphrase-file "$KEY_PASSFILE"); [[ -z "$KEY_AGE_IDENTITY" ]] || KEY_DEC=(--age-identity "$KEY_AGE_IDENTITY")
bash "$HERE/bootstrap-secrets.sh" --mode recover --site "$SITE_ABS" --key-backup "$SEAL_FILE" "${CONFIRM[@]}" \
  "${KEY_DEC[@]}" ${PASS_SECRETS[@]+"${PASS_SECRETS[@]}"} \
  || die "restoring the sealing key did not finish; see above. Nothing else was installed."
say "The forge"
bash "$HERE/bootstrap-forge.sh" "${FORGE_FLAGS[@]}" || die "bootstrap-forge did not finish; see above. The sealing key is restored."
say "The site"
kubectl "${K[@]}" apply -f "$SITE_ABS/bootstrap/root.yaml" >/dev/null || die "applying the root Application failed"
ok "root Application applied from $SITE_ABS/bootstrap/root.yaml; Argo CD syncs the layers from the forge"
say "Done"
ok "rebuilt from the copy at ${MAIN:0:12} ($AGE_TXT)"
info "watch it land: kubectl --context $CTX -n $ARGO_NS get applications -w"
case " ${PASS_FORGE[*]-} " in *" --no-sign-in "*) ;; *)
  info "once tockmox-identity is Healthy: tockmox-install.sh bootstrap-forge --site $SITE_ABS --context $CTX --connect-sign-in" ;; esac
info "keep the new recovery kit ($KIT_OUT) and the restored site ($SITE_ABS); the old kit no longer matches this forge"

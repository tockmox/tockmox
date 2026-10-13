#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Mints every credential Tockmox expects you to create, seals them, and writes
# them to secrets/.
#
# WHAT THIS DOES NOT CHANGE. Tockmox still generates no credentials: this is a
# script YOU run, on YOUR machine, producing values sealed to YOUR controller's
# key. Nothing here phones anywhere, and the private key stays where it was.
#
# WHY IT EXISTS. Ten Secrets, four of them holding a value that must MATCH its
# pair across two namespaces. The documentation gives a correct block to paste,
# but pasting it is the longest manual step in the install and the one most
# likely to go wrong quietly: get AUTHENTIK_POSTGRESQL__PASSWORD and the
# database's `password` out of step and Authentik fails to start with an
# authentication error that names neither Secret.
#
# THE FOUR PAIRS, generated once each and written to both sides:
#   AK_PG      tockmox-authentik.AUTHENTIK_POSTGRESQL__PASSWORD
#              tockmox-authentik-postgres.password
#   SSO_GRAF   tockmox-sso.GRAFANA_CLIENT_SECRET   tockmox-sso-grafana.client-secret
#   SSO_OWUI   tockmox-sso.OPENWEBUI_CLIENT_SECRET tockmox-sso-openwebui.client-secret
#   SSO_ARGO   tockmox-sso.ARGO_CLIENT_SECRET      tockmox-sso-argo.client-secret
#
# IT REFUSES TO OVERWRITE. Re-running after a partial run mints only what is
# missing, which is the behaviour you want at 1am. Rotating means deleting the
# file you want rotated and running it again ... and if that file holds one half
# of a pair, this script tells you which other file has to go with it, because
# rotating one side alone is the failure it exists to prevent.
#
# TM-0277. Three properties this header PROMISED and the body did not keep, and
# one it did not promise at all:
#   - The sentence above about pairs was aspirational. Nothing checked it: with
#     one half of a pair on disk, the other half was minted from a FRESH value
#     and the two no longer matched, which is the outage this script exists to
#     prevent, produced by the retry it recommends. check_pairs now refuses
#     BEFORE generating anything, and names the file that has to go too.
#   - Generation was eager, so a re-run generated every value and discarded the
#     ones whose files already existed. Harmless, but "a re-run generates
#     nothing" is a property worth being able to assert, and now can be.
#   - The Secret was an ARGUMENT (`kubectl create secret --from-literal=k=v`),
#     visible in the process table for as long as kubectl ran. The manifest is
#     now built in this shell and piped to kubeseal on stdin.
#   - Files are staged in a private directory beside the output and moved into
#     place together at the end. A run that dies at the fifth file leaves none
#     of the four before it, so the retry starts clean rather than half-paired.
set -euo pipefail

# THERE IS DELIBERATELY NO `cd` HERE. Until 2026-08-25 this line read
# `cd "$(dirname "$0")/.."`, which made OUT resolve against the TOCKMOX
# checkout rather than the directory you ran this from. install.md Phase 2.5
# promises the files land "in secrets/ in your site repository", so an operator
# following the page exactly got `MINTED (9)` and an empty site repo ... and
# then landed in the CreateContainerConfigError failure that Phase 2.5 exists
# to prevent. The safeguard routed you into the failure it documents.
#
# Nothing in this script needs the repository root: every write goes through
# $OUT, and there is no relative sourcing. Found during the K1 air-gap
# walkthrough, 2026-08-25.
OUT=secrets
ONLY=""
CERT=""; CONTEXT=""; DRY=false; WITH_LITELLM=true; WITH_APPRISE=false; WITH_UI=false; WITH_EVAL=false; YES=false
# kubeseal's OWN default is a Service named `sealed-secrets-controller`, and it
# is wrong for every install this repository documents: fresh-install.md #7
# names the Helm release `sealed-secrets`, and the chart names the Service after
# the release. Left at kubeseal's default, every seal below fails with
# `services "sealed-secrets-controller" not found`. TM-0346.
#
# These are OPTIONS rather than literals in seal() on purpose. Hardcoding the
# name our own install happens to produce would make this script work by
# coincidence and strand anyone who installed the chart under another name in
# the same hole ... which is the argument against "just rename the release".
CONTROLLER_NAME="sealed-secrets"
CONTROLLER_NS="kube-system"
NTFY_IMAGE="binwiederhier/ntfy:v2.28.0"
NTFY_PASSWORD=""; NTFY_PASSWORD_FILE=""; NO_NEXT=false; NO_PROMPT=false

# A secret value containing a control character is never correct, and every
# stage after generation is capable of noticing one and none of them do: it
# seals cleanly, commits cleanly, applies cleanly, and fails inside whatever
# consumes it. TM-0662: `openssl rand -base64 60` wraps at 64 columns, the
# newline rode all the way into `AUTHENTIK_SECRET_KEY`, and authentik's embedded
# outpost ... which authenticates with that key, and cannot put a control
# character in an HTTP header ... failed every five seconds for thirteen hours
# while every console stayed green. This check makes the CLASS unrepeatable
# rather than the one instance fixed: a different length, a different command or
# a pasted value all produce the same failure, and fixing that one call site
# catches none of them.
#
# NOT `grep '[[:cntrl:]]'`. grep is line-oriented, so a newline is a record
# separator and never a match ... the exact character that caused TM-0662 is the
# one a grep-based check cannot see. Length before and after `tr -d` can.
assert_no_control_chars() {
  local key="$1" value="$2" stripped
  stripped=$(printf '%s' "$value" | LC_ALL=C tr -d '[:cntrl:]')
  if [ "${#stripped}" -ne "${#value}" ]; then
    echo "REFUSING TO SEAL: the value for '$key' contains a control character." >&2
    echo "  length ${#value}, $(( ${#value} - ${#stripped} )) control character(s)." >&2
    echo "  Almost always \`openssl rand -base64 N\` with N above 48, which wraps" >&2
    echo "  at 64 columns. Pipe it through \`| tr -d '\\n'\`, or use \`rand -hex\`," >&2
    echo "  which never wraps at any length. See docs/administration/secrets.md." >&2
    return 1
  fi
  return 0
}

# Proves the guard above actually trips, on the value that actually shipped.
# Needs no kubectl, no kubeseal and no cluster, so it runs anywhere ... which is
# the point: the check that was missing must be testable where CI is, not only
# where a controller is.
selftest() {
  local fails=0 wrapped flat
  _t() { # name expect(0|1) key value
    local name="$1" expect="$2" got=0
    assert_no_control_chars "$3" "$4" >/dev/null 2>&1 || got=1
    if [ "$got" -eq "$expect" ]; then
      echo "  ok   $name"
    else
      echo "  FAIL $name (expected rc $expect, got $got)"; fails=$((fails + 1))
    fi
  }
  # The real thing: 60 bytes of base64 is 80 characters, which openssl wraps.
  wrapped=$(openssl rand -base64 60)
  flat=$(openssl rand -base64 60 | tr -d '\n')
  _t "wrapped rand -base64 60 is REFUSED"      1 AUTHENTIK_SECRET_KEY "$wrapped"
  _t "the same value, tr -d'd, is accepted"    0 AUTHENTIK_SECRET_KEY "$flat"
  _t "rand -base64 24 (never wraps)"           0 password "$(openssl rand -base64 24)"
  _t "rand -hex 32"                            0 masterkey "$(openssl rand -hex 32)"
  # $'...' rather than "$(printf ...)". Command substitution STRIPS trailing
  # newlines, so `"$(printf 'abc\n')x"` is just `abcx` and the fixture proves
  # nothing ... which is exactly how it failed when first written, 2026-09-16.
  _t "an embedded newline is REFUSED"          1 k $'abc\nx'
  _t "a trailing newline is REFUSED"           1 k $'abc\n'
  _t "an embedded tab is REFUSED"              1 k $'a\tb'
  _t "a carriage return is REFUSED"            1 k $'a\rb'
  _t "ordinary base64 punctuation is fine"     0 k 'aB3+/xyz=='
  _t "an empty value is not a control char"    0 k ''
  # Guards the guard: a wrapped value must be caught by LENGTH, not by grep.
  if printf '%s' "$wrapped" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo "  note grep DID match ... the length check is then belt and braces"
  else
    echo "  ok   grep cannot see the newline, which is why this is a length check"
  fi
  if [ "$fails" -eq 0 ]; then echo "selftest: all checks passed"; return 0; fi
  echo "selftest: $fails failure(s)" >&2; return 1
}

usage() {
  cat <<'USAGE'
usage: tools/mint-secrets.sh [options]

  --context NAME     kubectl context to seal against. No default, on purpose.
  --cert FILE        seal offline against a fetched certificate instead of a
                     live controller. Needed for air-gapped installs. Add
                     --context to let the ntfy image run as a pod on that
                     cluster when no local container runtime answers. Fetch
                     the certificate once with:
                       kubeseal --fetch-cert \
                         --controller-name sealed-secrets \
                         --controller-namespace kube-system \
                         > pub-sealed-secrets.pem
  --controller-name NAME
                     the sealed-secrets controller Service. Defaults to
                     `sealed-secrets`, the release name fresh-install.md #7
                     installs under. kubeseal's own default is
                     `sealed-secrets-controller` and does NOT match it.
  --controller-namespace NS
                     namespace of that Service (default: kube-system)
  --ntfy-password P  the ntfy password you will type into a phone. Prompted for
                     if omitted. Skips the ntfy Secret entirely if you decline.
                     Visible in the process table; prefer the file form.
  --ntfy-password-file FILE
                     read that password from the first line of FILE instead.
  --no-prompt        never read a terminal: no ntfy password prompt (the ntfy
                     Secret is then skipped unless a password was given)
  --no-next          do not print the closing NEXT note (tockmox-install.sh
                     bootstrap-secrets prints its own, and its backup advice
                     differs from the plaintext one printed here)
  --with-litellm     mint the model gateway's key and database credential.
                     THE DEFAULT since 0.8.0 (TM-0460): the gateway follows the
                     aiPlane capability, so a site that never mentions it runs
                     it. Kept as a flag so older runbooks still work.
  --without-litellm  do not mint them: for a site that set
                     apps.litellm.enabled: false, or already owns both files
  --with-apprise     also mint an empty Apprise config to edit
  --with-tockmox-ui  also mint the Tockmox UI's session key and OIDC client
                     secret (tockmox-ui-session, tockmox-sso-tockmox-ui)
  --with-eval-gateway
                     also mint the eval gateway's master key (tockmox-litellm-eval)
  --out DIR          output directory, relative to where you run this
                     (default: ./secrets). Run this from your site repository
                     and the sealed files land in that repository.
  --only LIST        mint only these groups, comma separated: authentik, sso,
                     grafana, openwebui, ntfy, litellm, apprise, tockmoxui,
                     evalgateway. Default: everything this
                     script mints today. A group is its whole set of files, so
                     `--only sso` mints sso.sealed.yaml and its three per-console
                     halves together and never touches the rest. Pair checks run
                     only for the selected groups. `litellm` and `apprise` in
                     the list stand in for --with-litellm / --with-apprise
                     (a list without `litellm` mints no gateway credential),
                     and `tockmoxui` and `evalgateway` for the two flags above.
                     For a site that already owns the other Secrets and needs
                     only the new SSO client secrets, instead of minting
                     everything into a scratch directory and deleting most of it.
  --dry-run          show what would be minted, write nothing
  --selftest         prove the control-character guard trips. Needs no kubectl,
                     no kubeseal and no cluster.
  -y, --yes          do not ask to confirm the target context
  -h, --help         this
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --cert) CERT="$2"; shift 2 ;;
    --controller-name) CONTROLLER_NAME="$2"; shift 2 ;;
    --controller-namespace) CONTROLLER_NS="$2"; shift 2 ;;
    --ntfy-password) NTFY_PASSWORD="$2"; shift 2 ;;
    --ntfy-password-file) NTFY_PASSWORD_FILE="$2"; shift 2 ;;
    --no-next) NO_NEXT=true; shift ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    --with-litellm) WITH_LITELLM=true; shift ;;
    --without-litellm) WITH_LITELLM=false; shift ;;
    --with-apprise) WITH_APPRISE=true; shift ;;
    --with-tockmox-ui) WITH_UI=true; shift ;;
    --with-eval-gateway) WITH_EVAL=true; shift ;;
    --out) OUT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    # Dispatched inside the loop, deliberately, so it runs before the `need`
    # checks below. The guard has no external dependencies and the selftest must
    # not be gated on tools the machine running CI may not have.
    --selftest) selftest; exit $? ;;
    -y|--yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# want <group>: true when no --only was given, or the group is in the list.
# Unknown names are refused here, before anything runs, so a typo cannot
# silently select nothing and report an empty success.
if [ -n "$ONLY" ]; then
  for _g in ${ONLY//,/ }; do
    case "$_g" in authentik|sso|grafana|openwebui|ntfy|litellm|apprise|tockmoxui|evalgateway) ;;
      *) echo "unknown --only group '$_g' (authentik, sso, grafana, openwebui, ntfy, litellm, apprise, tockmoxui, evalgateway)" >&2; exit 2 ;;
    esac
  done
  WITH_LITELLM=false; WITH_APPRISE=false; WITH_UI=false; WITH_EVAL=false
fi
want() { [ -z "$ONLY" ] && return 0; case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }
if [ -n "$ONLY" ]; then
  want litellm && WITH_LITELLM=true
  want apprise && WITH_APPRISE=true
  want tockmoxui && WITH_UI=true
  want evalgateway && WITH_EVAL=true
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ... $2" >&2; exit 1; }; }
need openssl "used for every generated value"
need kubeseal "install from https://github.com/bitnami-labs/sealed-secrets/releases"
# kubectl is needed to reach a live controller and to borrow a cluster for the
# ntfy image. It no longer builds the Secret manifests (see the header), so an
# offline --cert run with no --context needs none.
if [ -z "$CERT" ] || [ -n "$CONTEXT" ]; then
  need kubectl "used to reach the controller's cluster; no Secret is applied"
fi

if [ -n "$NTFY_PASSWORD_FILE" ]; then
  [ -r "$NTFY_PASSWORD_FILE" ] || { echo "cannot read --ntfy-password-file $NTFY_PASSWORD_FILE" >&2; exit 1; }
  IFS= read -r NTFY_PASSWORD < "$NTFY_PASSWORD_FILE" || true
fi

# TM-0631. ntfy stores a bcrypt hash of this password, and bcrypt cannot hash
# more than 72 BYTES: ntfy 2.28.0 answers a longer one with "failed to hash
# password: bcrypt: password length exceeds 72 bytes" (measured 2026-10-06).
# Until this check, that surfaced after every other secret was generated, as
# "returned something that is not a bcrypt hash: ''" ... the empty string
# because the hash pattern matched nothing ... and, on the kubectl path, with
# advice to check the image pull. Refuse it here, before anything is generated.
ntfy_pw_bytes() { LC_ALL=C; printf '%s' "$1" | wc -c | tr -d ' '; }
if [ -n "$NTFY_PASSWORD" ] && [ "$(ntfy_pw_bytes "$NTFY_PASSWORD")" -gt 72 ]; then
  echo "the ntfy password is $(ntfy_pw_bytes "$NTFY_PASSWORD") bytes; ntfy hashes it with bcrypt, which cannot take more than 72. Choose a shorter one (a non-ASCII character is two or more bytes). Nothing was generated." >&2
  exit 1
fi

# --------------------------------------------------------------------------
# MATCHED PAIRS, checked BEFORE anything is generated or any prompt is shown.
#
# Each entry is two files that hold one generated value. If exactly one exists,
# minting the other would generate a new value that no longer matches it, and
# nothing downstream can tell: both Secrets exist, both look right, and the
# consumer fails to authenticate against a peer that holds the other value.
# sso.sealed.yaml is one half of THREE pairs (the consoles each hold their own
# copy of a value sso.sealed.yaml also holds).
# --------------------------------------------------------------------------
PAIRS_AUTHENTIK="authentik.sealed.yaml:authentik-postgres.sealed.yaml"
PAIRS_SSO="sso.sealed.yaml:sso-grafana.sealed.yaml sso.sealed.yaml:sso-openwebui.sealed.yaml sso.sealed.yaml:sso-argo.sealed.yaml"
PAIRS=""
want authentik && PAIRS="$PAIRS_AUTHENTIK"
want sso && PAIRS="$PAIRS $PAIRS_SSO"
check_pairs() {
  local p a b bad=0
  for p in $PAIRS; do
    a="${p%%:*}"; b="${p##*:}"
    if [ -e "$OUT/$a" ] && [ ! -e "$OUT/$b" ]; then
      echo "REFUSING: $a exists and $b does not." >&2; bad=1
      echo "  They hold ONE generated value between them. Minting $b now would" >&2
      echo "  generate a new value that does not match the one sealed in $a." >&2
      echo "  Either restore $b (from git), or delete $a too and re-run, which" >&2
      echo "  ROTATES the pair: safe only if $a was never deployed." >&2
    elif [ ! -e "$OUT/$a" ] && [ -e "$OUT/$b" ]; then
      echo "REFUSING: $b exists and $a does not." >&2; bad=1
      echo "  They hold ONE generated value between them. Minting $a now would" >&2
      echo "  generate a new value that does not match the one sealed in $b." >&2
      echo "  Either restore $a (from git), or delete $b too and re-run, which" >&2
      echo "  ROTATES the pair: safe only if $b was never deployed." >&2
    fi
  done
  if [ "$bad" -ne 0 ]; then
    echo "Nothing was generated and nothing was written." >&2
    exit 1
  fi
}
check_pairs

# --------------------------------------------------------------------------
# The target. Sealing encrypts to ONE controller's key, so a SealedSecret sealed
# against the wrong cluster is undecryptable in the right one, and the error
# arrives later as a Secret that never appears. Naming the context is cheap; the
# alternative is a silent wrong answer.
# --------------------------------------------------------------------------
KCTX=()
if [ -n "$CERT" ]; then
  [ -r "$CERT" ] || { echo "cannot read --cert $CERT" >&2; exit 1; }
  TARGET="offline, against $CERT"
  # --cert with --context: the certificate is still the sealing target, and the
  # context is used ONLY to run the ntfy image as a pod when no local runtime
  # answers. Without it the two flags were mutually exclusive in effect, and an
  # offline seal on a machine with no container runtime could not mint ntfy.
  if [ -n "$CONTEXT" ]; then
    KCTX=(--context "$CONTEXT")
    TARGET="$TARGET (the ntfy image may run as a pod in context '$CONTEXT')"
  fi
else
  [ -z "$CONTEXT" ] && CONTEXT=$(kubectl config current-context 2>/dev/null || true)
  [ -z "$CONTEXT" ] && { echo "no kubectl context set and no --context or --cert given" >&2; exit 1; }
  KCTX=(--context "$CONTEXT")
  TARGET="live controller in context '$CONTEXT'"
  if ! $YES && ! $DRY; then
    # /dev/tty, not stdin, because a piped stdin must not be able to answer a
    # question about which cluster to seal against. That is deliberate, and it
    # means this prompt CANNOT be satisfied without a controlling terminal ...
    # CI, a container, an agent-driven run, `ssh` without -t, `nohup`. Say so,
    # instead of letting bash print `/dev/tty: No such device or address` and
    # leaving the caller to guess that --yes exists.
    # `[ -r /dev/tty ]` is NOT the check. The device node exists and passes an
    # access() test in environments where actually opening it fails with ENXIO,
    # so the guard reads as satisfied and the read below still dies. Attempt the
    # open instead ... probe the capability, not the file.
    if ! (: < /dev/tty) 2>/dev/null; then
      echo "no controlling terminal, so the confirmation prompt cannot be answered." >&2
      echo "Re-run with --yes (-y) to seal against '${CONTEXT}' without confirming." >&2
      exit 1
    fi
    printf 'Seal against %s? [y/N] ' "$CONTEXT"
    read -r a </dev/tty || a=""
    case "$a" in y|Y|yes|YES) ;; *) echo "nothing done."; exit 1 ;; esac
  fi
fi

# The --cert branch never contacts a controller, so the --controller-* flags are
# meaningless there and are deliberately not passed: the certificate IS the
# target. The live branch needs them, per TM-0346.
seal() {
  if [ -n "$CERT" ]; then kubeseal --format yaml --cert "$CERT"
  else kubeseal --format yaml \
         --controller-name "$CONTROLLER_NAME" \
         --controller-namespace "$CONTROLLER_NS" "${KCTX[@]}"; fi
}

# THE SECRET IS NEVER AN ARGUMENT. `kubectl create secret --from-literal=k=v`
# put every value in kubectl's argv, readable by any local user for as long as
# the process lived. This builds the manifest with shell builtins and hands it
# to kubeseal on stdin: `printf` is a builtin (no exec, no argv) and the value
# reaches `openssl base64` on stdin. It writes nothing to disk. `-A` keeps the
# encoding on one line; GNU and BSD base64 disagree about wrapping.
# emit_secret <namespace> <name> <type> [--from-literal=k=v ...]
emit_secret() {
  local ns="$1" name="$2" type="$3" arg kv k v; shift 3
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: %s\ndata:\n' \
    "$name" "$ns" "$type"
  for arg in "$@"; do
    case "$arg" in --from-literal=*) ;; *) continue ;; esac
    kv="${arg#--from-literal=}"; k="${kv%%=*}"; v="${kv#*=}"
    printf '  %s: %s\n' "$k" "$(printf '%s' "$v" | openssl base64 -A)"
  done
}

# STAGING. Sealed files are written into a private directory beside the output
# and moved into place together by commit_staged. A run that dies part-way (a
# seal that fails, a Ctrl-C, a bad ntfy hash) therefore leaves NO new file, not
# the first four of eleven, and the retry cannot meet one half of a pair. The
# staging directory holds ciphertext only, and the trap removes it on every
# exit path.
STAGE=""
cleanup() { [ -z "$STAGE" ] || rm -rf "$STAGE"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Newline-delimited strings rather than arrays. bash 3.2 ships on macOS and
# expanding an empty array under `set -u` is an unbound-variable error there, so
# the summary would abort exactly when there was nothing to report.
MADE=""; SKIPPED=""; NOTMADE=""

# have <file> <secret-name>: true when the file exists, and records it as left
# alone. Used as `have f n || mk f ...` so the values in mk's ARGUMENTS are not
# generated for a file that already exists: a re-run generates nothing for it.
have() {
  [ -e "$OUT/$1" ] || return 1
  SKIPPED="$SKIPPED$1 ($2)\n"
  return 0
}

# mk <file> <namespace> <name> [--type=T] [--from-literal=k=v ...]
mk() {
  # Capture the report line BEFORE the shift. Reading $1 after it named the
  # first --from-literal instead of the file, which printed generated secret
  # material to the terminal on every dry run.
  local short="$1" ns="$2" name="$3" type="Opaque"; shift 3
  local label="$short -> $ns/$name"
  # BEFORE the dry-run return, deliberately. A malformed value is a defect
  # whether or not this run would have written the file, and a dry run that
  # cannot catch it is a dry run that proves nothing.
  local arg kv k v
  for arg in "$@"; do
    case "$arg" in
      --type=*) type="${arg#--type=}"; continue ;;
      --from-literal=*) ;;
      *) continue ;;
    esac
    kv="${arg#--from-literal=}"; k="${kv%%=*}"; v="${kv#*=}"
    assert_no_control_chars "$ns/$name:$k" "$v" || exit 1
  done
  # Backstop: callers use `have`, which skips before generating. This catches a
  # caller that forgot.
  if [ -e "$OUT/$short" ]; then SKIPPED="$SKIPPED$short ($name)\n"; return 0; fi
  if $DRY; then MADE="$MADE$label\n"; return 0; fi
  emit_secret "$ns" "$name" "$type" "$@" | seal > "$STAGE/$short" \
    || { echo "sealing $name failed" >&2; exit 1; }
  # Assert on the artifact rather than on kubeseal's exit code: a truncated or
  # empty file here is a Secret that never materialises in the cluster, and the
  # symptom arrives days later as a pod stuck in CreateContainerConfigError.
  if ! grep -q '^kind: SealedSecret' "$STAGE/$short"; then
    echo "sealing $name produced no SealedSecret" >&2; exit 1
  fi
  chmod 0600 "$STAGE/$short"
  MADE="$MADE$label\n"
}

# Move every staged file into place. Called once, after the last mk.
commit_staged() {
  local f
  $DRY && return 0
  for f in "$STAGE"/*; do
    [ -e "$f" ] || continue
    mv "$f" "$OUT/$(basename "$f")"
  done
}

if ! $DRY; then
  mkdir -p "$OUT"
  STAGE=$(mktemp -d "$OUT/.mint.XXXXXX")
fi
echo "target: $TARGET"
echo "output: $OUT/"
echo

# --------------------------------------------------------------------------
# The paired values. Generated ONCE, above every use, and ONLY when the pair is
# absent. check_pairs has already refused a half-present pair, so "the first
# file of a pair is absent" means "the whole pair is".
# --------------------------------------------------------------------------
AK_PG=""; SSO_GRAF=""; SSO_OWUI=""; SSO_ARGO=""
if want authentik && [ ! -e "$OUT/authentik.sealed.yaml" ]; then AK_PG=$(openssl rand -base64 24); fi
if want sso && [ ! -e "$OUT/sso.sealed.yaml" ]; then
  SSO_GRAF=$(openssl rand -base64 32)
  SSO_OWUI=$(openssl rand -base64 32)
  SSO_ARGO=$(openssl rand -base64 32)
fi

if want grafana; then
have grafana-admin.sealed.yaml tockmox-grafana-admin || \
mk grafana-admin.sealed.yaml tockmox-monitoring tockmox-grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
fi

# The console's bootstrap administrator (TM-0859). Open WebUI creates it at
# startup only when it has no accounts, which closes the window in which the
# first SSO login, whatever its groups, becomes the console's admin. The address
# is under `.invalid` (RFC 2606), so no Authentik user can hold it and no SSO
# login can merge into it by email. Read the password back from the cluster when
# you need the break-glass login: docs/administration/secrets.md.
if want openwebui; then
have openwebui-bootstrap-admin.sealed.yaml tockmox-openwebui-bootstrap-admin || \
mk openwebui-bootstrap-admin.sealed.yaml tockmox-ai tockmox-openwebui-bootstrap-admin \
  --from-literal=WEBUI_ADMIN_EMAIL=bootstrap-admin@tockmox.invalid \
  --from-literal=WEBUI_ADMIN_NAME="Tockmox bootstrap admin" \
  --from-literal=WEBUI_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
fi

# `tr -d` IS REQUIRED. `openssl rand -base64` wraps its output at 64 columns, so
# any length above 48 bytes emits a newline INSIDE the value. Command
# substitution strips the trailing newline and leaves the internal one. Authentik
# authenticates its embedded outpost with this key, HTTP header values may not
# contain control characters, and the outpost then fails every few seconds at
# `warn` for the life of the install. Measured 2026-09-16 (Phase E, rc4).
if want authentik; then
have authentik.sealed.yaml tockmox-authentik || \
mk authentik.sealed.yaml tockmox-authentik tockmox-authentik \
  --from-literal=AUTHENTIK_SECRET_KEY="$(openssl rand -base64 60 | tr -d '\n')" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$AK_PG"

have authentik-postgres.sealed.yaml tockmox-authentik-postgres || \
mk authentik-postgres.sealed.yaml tockmox-authentik tockmox-authentik-postgres \
  --from-literal=password="$AK_PG" \
  --from-literal=postgres-password="$(openssl rand -base64 24)"
fi

if want sso; then
have sso.sealed.yaml tockmox-sso || \
mk sso.sealed.yaml tockmox-authentik tockmox-sso \
  --from-literal=GRAFANA_CLIENT_SECRET="$SSO_GRAF" \
  --from-literal=OPENWEBUI_CLIENT_SECRET="$SSO_OWUI" \
  --from-literal=ARGO_CLIENT_SECRET="$SSO_ARGO"

have sso-grafana.sealed.yaml tockmox-sso-grafana || \
mk sso-grafana.sealed.yaml tockmox-monitoring tockmox-sso-grafana \
  --from-literal=client-secret="$SSO_GRAF"

have sso-openwebui.sealed.yaml tockmox-sso-openwebui || \
mk sso-openwebui.sealed.yaml tockmox-ai tockmox-sso-openwebui \
  --from-literal=client-secret="$SSO_OWUI"

have sso-argo.sealed.yaml tockmox-sso-argo || \
mk sso-argo.sealed.yaml tockmox-devops tockmox-sso-argo \
  --from-literal=client-id=tockmox-argo \
  --from-literal=client-secret="$SSO_ARGO"
fi

# --------------------------------------------------------------------------
# ntfy. Separate because two of its values cannot come from openssl: it wants a
# bcrypt hash and a token in its own tk_ format, and both come from the ntfy
# binary, which means a container runtime.
# --------------------------------------------------------------------------
# SELECT BY PROVING THE DAEMON ANSWERS, NOT BY `command -v` (TM-0485).
# `command -v docker` answers "is the CLI on PATH", which is a different question
# from "is a runtime serving". A Mac with Colima installed and stopped has the
# docker CLI and no daemon: the old loop picked docker, broke out, and never
# considered podman ... so the fall-through existed and could not be reached.
# The mint then failed on the one Secret whose absence means NO ALERT REACHES
# ANYBODY, at the end of a long install, with an error about a socket.
#
# `info` is the probe because it round-trips to the daemon and fails fast when
# there is not one. What it does NOT prove is that the image pulls; a runtime
# that answers but cannot reach a registry fails later, at ntfy_run, and says so
# there. Stated rather than implied, because a probe's limits are part of it.
RUNTIME=""
# `want ntfy` first: a selective run that does not mint ntfy must not probe
# container runtimes (each probe can start a VM or print a daemon note).
for r in $(want ntfy && echo docker podman nerdctl); do
  command -v "$r" >/dev/null 2>&1 || continue
  if "$r" info >/dev/null 2>&1; then
    RUNTIME="$r"
    break
  fi
  echo "  note: $r is on PATH but its daemon does not answer; trying the next." >&2
done
[ -n "$RUNTIME" ] && echo "  container runtime: $RUNTIME (daemon answered)" >&2

# THE CLUSTER IS A CONTAINER RUNTIME, and assuming a local one blocked a release
# gate (2026-09-11). macOS ships none of the three, so an operator following this
# page on a Mac could not mint the one Secret without which NO ALERT REACHES
# ANYBODY ... on the machine the rest of the install is driven from. The cluster
# we are already sealing against can pull and run the same image, so it does.
#
# Available when sealing against a LIVE controller, or with --cert AND --context.
# With --cert alone there is no cluster by definition, and the local runtime is
# the only option.
NTFY_VIA=""
if [ -n "$RUNTIME" ]; then
  NTFY_VIA="$RUNTIME"
elif want ntfy && { [ -z "$CERT" ] || [ -n "$CONTEXT" ]; } && command -v kubectl >/dev/null 2>&1; then
  NTFY_VIA="kubectl"
fi

# Run the ntfy image and return its stdout, wherever a runtime happens to live.
# stdin is forwarded either way, because `ntfy user hash` reads a terminal.
#
# The pod lands in `default` deliberately. Tockmox labels only its OWN namespaces
# for PodSecurity, and `default` is not one of them, so nothing enforces there
# ... no securityContext override is needed and none is set, which keeps this
# readable. (Since 0.7.0 five Tockmox namespaces DO enforce; this pod must not be
# moved into one of them without a securityContext.)
# stderr is dropped because `kubectl run --rm` narrates the pod's deletion there
# and that narration would otherwise land in a bcrypt hash.
#
# A call that reads no stdin (`token generate`) does NOT go through `run -i`.
# kubectl attaches only after the container starts, and a command that prints
# and exits in that window loses its output: measured 2026-10-06, two of three
# back-to-back `kubectl run -i ... ntfy token generate` calls printed nothing at
# all, and an empty token is a refusal further down. A command waiting on stdin
# (`user hash`) cannot exit before the attach, so it keeps `-i`. The other kind
# runs to completion and is READ from its log, which cannot miss.
NTFY_POD="tockmox-ntfy-mint-$$"
NTFY_SEQ=0
ntfy_run() {
  if [ "$NTFY_VIA" = "kubectl" ]; then
    NTFY_SEQ=$((NTFY_SEQ + 1))
    local pod="${NTFY_POD}-${NTFY_SEQ}"
    if [ "${1:-}" = "user" ]; then
      kubectl "${KCTX[@]}" -n default run "$pod" \
        --rm -i --restart=Never --image="$NTFY_IMAGE" \
        --command -- ntfy "$@" 2>/dev/null
    else
      kubectl "${KCTX[@]}" -n default run "$pod" \
        --restart=Never --image="$NTFY_IMAGE" \
        --command -- ntfy "$@" >/dev/null 2>&1 || return 1
      kubectl "${KCTX[@]}" -n default wait "pod/$pod" \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null 2>&1
      kubectl "${KCTX[@]}" -n default logs "pod/$pod" 2>/dev/null
      kubectl "${KCTX[@]}" -n default delete "pod/$pod" --wait=false >/dev/null 2>&1
    fi
  else
    "$NTFY_VIA" run --rm -i "$NTFY_IMAGE" "$@"
  fi
}

if ! want ntfy; then
  :
elif [ -e "$OUT/ntfy-auth.sealed.yaml" ]; then
  SKIPPED="${SKIPPED}ntfy-auth.sealed.yaml (tockmox-ntfy-auth)\n"
elif [ -z "$NTFY_VIA" ]; then
  NOTMADE="${NOTMADE}tockmox-ntfy-auth ... no container runtime ANSWERED (docker, podman and nerdctl were each either absent or present-but-not-serving ... any 'daemon does not answer' note above says which), and --cert mode without --context has no cluster to borrow one from. If one of them is installed, start it and re-run; this is not the same as not having it. The bcrypt hash and tk_ token can only come from the ntfy binary; docs/administration/secrets.md has the manual block. UNTIL IT EXISTS NO ALERT REACHES ANYBODY: ntfy defaults to deny-all.\n"
else
  # READ IT TWICE (TM-0485). This value is typed once here, silently, and then
  # typed again days later into a phone. Nothing verifies it in between: the
  # bcrypt hash is computed from whatever was entered, sealed, committed and
  # applied, so a typo produces a perfectly healthy ntfy that refuses the one
  # login it exists for. The failure surfaces as "my phone will not connect",
  # which reads as an app or TLS problem and is diagnosed nowhere near here.
  # Re-minting means deleting both halves of the pair and running again.
  if [ -z "$NTFY_PASSWORD" ] && ! $DRY && ! $NO_PROMPT; then
    echo "ntfy needs a password you will type into a phone app."
    while true; do
      printf '  password (empty to skip ntfy): '
      read -rs NTFY_PASSWORD </dev/tty || NTFY_PASSWORD=""
      echo
      [ -z "$NTFY_PASSWORD" ] && break
      if [ "$(ntfy_pw_bytes "$NTFY_PASSWORD")" -gt 72 ]; then
        echo "  that is $(ntfy_pw_bytes "$NTFY_PASSWORD") bytes; ntfy (bcrypt) cannot take more than 72. Again." >&2
        NTFY_PASSWORD=""; continue
      fi
      printf '  again: '
      read -rs NTFY_PASSWORD_CONFIRM </dev/tty || NTFY_PASSWORD_CONFIRM=""
      echo
      [ "$NTFY_PASSWORD" = "$NTFY_PASSWORD_CONFIRM" ] && break
      echo "  they do not match. Again." >&2
      NTFY_PASSWORD=""
    done
    unset NTFY_PASSWORD_CONFIRM
  fi
  if [ -z "$NTFY_PASSWORD" ]; then
    NOTMADE="${NOTMADE}tockmox-ntfy-auth ... skipped, no password given. UNTIL IT EXISTS NO ALERT REACHES ANYBODY.\n"
  elif $DRY; then
    MADE="${MADE}ntfy-auth.sealed.yaml -> tockmox-monitoring/tockmox-ntfy-auth\n"
  else
    # `ntfy user hash` PROMPTS TWICE and reads a terminal rather than a pipe.
    # One line gets "password cannot be empty"; two lines works, and the hash is
    # the last field because both prompts land on the same output line.
    # EXTRACT BY PATTERN, not by position. The old form took the last field of
    # the output, which works for a local runtime because both prompts land on
    # the hash's line ... and breaks for kubectl, because `kubectl run --rm`
    # announces the pod's deletion ON STDOUT afterwards. Taking the last field
    # then yields two lines, and the word "namespace" ends up inside the Secret.
    # A bcrypt hash and a tk_ token are both unambiguous shapes; match those.
    nhash() {
      printf '%s\n%s\n' "$1" "$1" | ntfy_run user hash 2>&1 | tr -d '\r' > "$NTFY_RAW"
      grep -oE '\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{53}' "$NTFY_RAW" | head -1
    }
    NTFY_RAW="$(mktemp)"
    YOU_HASH=$(nhash "$NTFY_PASSWORD")
    YOU_RAW="$(grep -v '^[[:space:]]*$' "$NTFY_RAW" | tail -1 | cut -c1-200)"
    BRIDGE_HASH=$(nhash "$(openssl rand -base64 18)")
    BRIDGE_TOKEN=$(ntfy_run token generate </dev/null \
      | tr -d '\r' | grep -oE 'tk_[A-Za-z0-9]+' | head -1)
    # Both assertions name the PATH that produced the value. A pull failure or a
    # missing egress route through the kubectl path yields an empty string, and
    # "not a bcrypt hash: " with nothing after it sends you looking at ntfy
    # rather than at the cluster that could not fetch the image.
    case "$YOU_HASH" in
      \$2*) ;;
      *) rm -f "$NTFY_RAW"
         echo "ntfy user hash via ${NTFY_VIA} returned no bcrypt hash. ntfy's last line: '${YOU_RAW}'" >&2
         if [ "$NTFY_VIA" = kubectl ]; then
           echo "  the cluster ran the pod; check it can pull ${NTFY_IMAGE}" >&2
         fi
         exit 1 ;;
    esac
    rm -f "$NTFY_RAW"
    case "$BRIDGE_TOKEN" in
      tk_*) ;;
      *) echo "ntfy token generate via ${NTFY_VIA} returned '${BRIDGE_TOKEN}', which is not a tk_ token" >&2; exit 1 ;;
    esac
    # Both accounts are `user`, never `admin`: ntfy refuses to start when an
    # admin also carries an ACL entry, and receiving alerts needs no admin
    # rights, so least privilege and the only working configuration agree.
    #
    # The bridge gets `wo`. It publishes; it has no business reading back, and a
    # leaked bridge token should not hand anybody your alert history.
    #
    # The hash goes in EXACTLY as printed. ntfy's docs say to double the `$` to
    # `$$` ... that is a docker-compose interpolation rule. A Kubernetes Secret
    # interpolates nothing, so doubling produces a hash that never matches.
    mk ntfy-auth.sealed.yaml tockmox-monitoring tockmox-ntfy-auth \
      --from-literal=NTFY_AUTH_USERS="you:${YOU_HASH}:user,alertbridge:${BRIDGE_HASH}:user" \
      --from-literal=NTFY_AUTH_ACCESS="alertbridge:alerts:wo,you:alerts:rw" \
      --from-literal=NTFY_AUTH_TOKENS="alertbridge:${BRIDGE_TOKEN}:alert bridge" \
      --from-literal=NTFY_BRIDGE_TOKEN="${BRIDGE_TOKEN}"
  fi
fi

# --------------------------------------------------------------------------
# The model gateway's two Secrets. Minted by default since 0.8.0 (TM-0460):
# the gateway follows the aiPlane capability, and a site that never mentions
# it runs it. --without-litellm is for a site that turned it off.
# --------------------------------------------------------------------------
if $WITH_LITELLM; then
  have litellm.sealed.yaml tockmox-litellm || \
  mk litellm.sealed.yaml tockmox-ai tockmox-litellm \
    --from-literal=masterkey="sk-$(openssl rand -hex 32)"
  # hex, not base64: this password reaches PostgreSQL through a connection URL,
  # and base64's `+` and `/` are URL-reserved. The failure is an authentication
  # error naming neither the character nor the encoding.
  have litellm-db.sealed.yaml tockmox-litellm-db || \
  mk litellm-db.sealed.yaml tockmox-ai tockmox-litellm-db \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=litellm \
    --from-literal=password="$(openssl rand -hex 32)"
else
  # Files already in the site are reported as kept, not as "not requested": a
  # site that minted them once and passes --without-litellm on a later run
  # must not read "NOT MINTED ... not requested" for secrets that exist, which
  # reads as missing (0.7.0 lab pass). Only an absent file is a NOT MINTED line.
  _l1=false; _l2=false
  have litellm.sealed.yaml tockmox-litellm && _l1=true
  have litellm-db.sealed.yaml tockmox-litellm-db && _l2=true
  if [ -z "$ONLY" ] && { ! $_l1 || ! $_l2; }; then
    NOTMADE="${NOTMADE}tockmox-litellm and tockmox-litellm-db ... not requested (--without-litellm). The model gateway is on by default since 0.8.0 and needs both; re-run without --without-litellm unless apps.litellm.enabled is false in your site values.\n"
  fi
fi

if $WITH_APPRISE; then
  # Keeping the ntfy:// line matters: adding email or Slack without it quietly
  # costs you the phone path.
  have apprise-config.sealed.yaml tockmox-apprise-config || \
  mk apprise-config.sealed.yaml tockmox-monitoring tockmox-apprise-config \
    --from-literal=tockmox="tockmox=ntfy://tockmox-ntfy.tockmox-monitoring.svc/alerts"
else
  [ -z "$ONLY" ] && { have apprise-config.sealed.yaml tockmox-apprise-config || \
  NOTMADE="${NOTMADE}tockmox-apprise-config ... not requested. Needed only with notifications.apprise.enabled; re-run with --with-apprise.\n"; }
fi

# The 0.8.0 experimental features (lab F3, 2026-10-08: the pages named these
# Secrets and gave no command). Neither pairs with anything this script mints:
# the UI's OIDC client secret is registered in Authentik by hand
# (docs/administration/tockmox-ui.md), so it is read back from the cluster, not
# from a second file here.
if $WITH_UI; then
  have tockmox-ui-session.sealed.yaml tockmox-ui-session || \
  mk tockmox-ui-session.sealed.yaml tockmox-ai tockmox-ui-session \
    --from-literal=secret="$(openssl rand -hex 32)"
  have sso-tockmox-ui.sealed.yaml tockmox-sso-tockmox-ui || \
  mk sso-tockmox-ui.sealed.yaml tockmox-ai tockmox-sso-tockmox-ui \
    --from-literal=client-secret="$(openssl rand -hex 32)"
else
  _u1=false; _u2=false
  have tockmox-ui-session.sealed.yaml tockmox-ui-session && _u1=true
  have sso-tockmox-ui.sealed.yaml tockmox-sso-tockmox-ui && _u2=true
  if [ -z "$ONLY" ] && { ! $_u1 || ! $_u2; }; then
    NOTMADE="${NOTMADE}tockmox-ui-session and tockmox-sso-tockmox-ui ... not requested. Needed only with tockmoxUi.enabled; re-run with --with-tockmox-ui.\n"
  fi
fi

if $WITH_EVAL; then
  have litellm-eval.sealed.yaml tockmox-litellm-eval || \
  mk litellm-eval.sealed.yaml tockmox-ai tockmox-litellm-eval \
    --from-literal=masterkey="sk-$(openssl rand -hex 32)"
else
  [ -z "$ONLY" ] && { have litellm-eval.sealed.yaml tockmox-litellm-eval || \
  NOTMADE="${NOTMADE}tockmox-litellm-eval ... not requested. Needed only with modelLifecycle.evalGateway.enabled; re-run with --with-eval-gateway.\n"; }
fi

# --------------------------------------------------------------------------
commit_staged
count() { [ -z "$1" ] && echo 0 || printf '%b' "$1" | grep -c . ; }
show()  { printf '%b' "$1" | sed '/^$/d;s/^/  /'; }

echo "MINTED ($(count "$MADE"))"
show "$MADE"
if [ -n "$SKIPPED" ]; then
  echo
  echo "ALREADY PRESENT, LEFT ALONE ($(count "$SKIPPED"))"
  show "$SKIPPED"
fi
if [ -n "$NOTMADE" ]; then
  echo
  echo "NOT MINTED ($(count "$NOTMADE"))"
  show "$NOTMADE"
fi
$NO_NEXT && exit 0
cat <<'ENDNOTE'

NEXT
  1. Commit secrets/ to the repository. SealedSecrets are safe to commit; that
     is the whole point of them.
  2. BACK UP THE CONTROLLER'S PRIVATE KEY. Without it these files are
     undecryptable and every credential here has to be minted again:
       kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
         -o yaml > sealed-secrets-key.backup.yaml
     Store that off-cluster. It is the one file in this process that a cluster
     rebuild cannot regenerate.
  3. Rotating one half of a pair breaks the pair. The four pairs are listed at
     the top of this script; delete both files and re-run.
ENDNOTE

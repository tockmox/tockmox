#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# Tockmox built-in forge bootstrap
#
#   ./install/tockmox-install.sh bootstrap-forge --site ./my-site \
#       --kit-out ~/keys/tockmox-recovery-kit.tar.age --age-recipient age1... \
#       --sealing-key-backup ~/keys/sealed-secrets.key.enc
#
# WRITES TO A CLUSTER, so like bootstrap-secrets it is its own file, reached only
# by naming the subcommand, and it shows the kube context and makes you confirm it
# before it touches anything.
#
# WHY IT IS BOOTSTRAP AND NOT A LAYER. The forge holds the site repository ArgoCD
# reads, so it must exist before the GitOps loop can read anything. That is the
# project's own test for a prerequisite (docs/administration/argocd.md), and it is
# why the forge is installed out of band, beside ArgoCD and sealed-secrets, and is
# NEVER an Application synced from the repository it holds: a broken sync cannot
# take the forge down, and fixing the forge never needs the forge.
#
# WHAT IT DOES, in order, each step refusing before the next:
#   1. show and confirm the kube context, before any cluster contact
#   2. install Forgejo (pinned, one replica, SQLite) as release tockmox-forge in
#      namespace tockmox-forge, or adopt the release this script installed earlier,
#      and fence it with a NetworkPolicy: its port admits ArgoCD's repo-server,
#      tockmox-actions and the model watcher (in the AI layer's namespace) and the
#      forge namespace's own pods (the off-site copy job), nothing else. The
#      installer's own port-forward enters through the kubelet, which the policy
#      does not see.
#   3. create the organisation `tockmox`, the private repository `tockmox/site`,
#      and the machine users: `tockmox-argocd` (read), `tockmox-changes` (opens
#      changes, cannot approve them) and `tockmox-offsite` (reads main for the copy)
#   4. push the site directory to it as `main`
#   5. protect `main`: no direct pushes, one approval from the `approvers` team
#      (the console's admin group, mapped at sign-in; see SIGN-IN). The forge's ADMIN
#      can still force-merge past the rule: Forgejo 15 has no admin-override block
#      (measured 2026-10-31 on 15.0.11; the Gitea field is silently ignored). That
#      is the detect-not-prevent boundary the spec states, and why no service but
#      this installer holds the admin credential.
#   6. give ArgoCD its read credential as a repository Secret, the console's
#      change identity as a Secret in the forge namespace, and the same bot's
#      token to the model watcher as a Secret in the AI layer's namespace
#   6b. with an off-site destination (optional): a CronJob that copies main every
#      minute (a git bundle to an S3-compatible bucket) or verifies the forge's push
#      mirror (a git remote), and the first copy written and read back before this
#      run reports done. Without one, the observability layer raises the persistent
#      "No off-site copy" alert, which the console can snooze or silence like any other
#   7. write the RECOVERY KIT: the forge's own secrets (app.ini, which carries
#      SECRET_KEY, INTERNAL_TOKEN and the JWT secrets a restore needs) plus your
#      sealing-key backup, as ONE encrypted file, kept off the cluster. Its format,
#      inside the encryption, is text in sections, so a person can read it with
#      `openssl enc -d ...` or `age -d ...` and nothing else:
#        # tockmox-recovery-kit v1        (first line; a restore refuses without it)
#        key: value ...                   (the manifest)
#        === app.ini                      (the forge's config, verbatim)
#        === forge-admin                  (user, then password, one per line)
#        === sealed-secrets.key.enc (base64)   (your bootstrap-secrets export, as is)
#        === end                          (a kit without it was cut short)
#
# SIGN-IN. People sign in to the forge through Authentik and are registered
# at their first sign-in; Forgejo's OIDC group mapping puts members of the console's
# admin group (tockmox-admins) in the `approvers` team, and takes them out again at
# a sign-in where the group is gone. Nobody is ever made a forge ADMIN that way: the
# admin can merge past the rule, so the admin stays one credential in one Secret.
# Two halves, because the forge exists before Authentik does:
#   this run      gives the forge a browser address (an Ingress at forge.<internalDomain>,
#                 TLS from the platform's CA when global.certIssuer is set), makes it
#                 trust that CA for its own calls to Authentik, admits Traefik through
#                 the fence, and mints the OIDC client secret into BOTH namespaces: the
#                 forge's (`tockmox-forge-oidc`) and the identity layer's
#                 (`tockmox-sso-forge`, FORGE_CLIENT_SECRET, which Authentik's blueprint
#                 for sso.apps.forge reads). Never sealed into the site repository: the
#                 forge holds that repository, so its own sign-in cannot come from it.
#   --connect-sign-in, once tockmox-identity is Healthy: adds the sign-in source
#                 `authentik` to the forge. Forgejo refuses a source whose discovery
#                 address does not answer (measured on 15.0.11: "Non-success code for
#                 Discovery URL: 404"), and the chart's own `gitea.oauth` runs that same
#                 check in an init container on EVERY start, which would make the forge
#                 unable to start whenever Authentik is down. So the source is added once,
#                 here, into the forge's database; a forge that later starts with Authentik
#                 unreachable logs a warning, starts, and signs people in again as soon as
#                 Authentik answers, with no restart (measured on the lab, 2026-11-02).
#                 This run tries it at the end too, so a re-run on a finished install needs
#                 nothing else.
# The browser offers ONLY Authentik: the username-and-password form is off
# (ENABLE_INTERNAL_SIGNIN=false), so the forge's admin has no web sign-in at all.
# Accounts are never LINKED: an Authentik user whose name equals a forge user's (a
# machine user, the admin) is refused at sign-in (ACCOUNT_LINKING=disabled; measured:
# "CreateUser: user already exists"), never signed in as that user.
#
# THE IN-CLUSTER ADDRESS IS THE INTERFACE. Every Application the generator wrote
# for a built-in-forge site names
#   http://tockmox-forge-http.tockmox-forge.svc.cluster.local:3000/tockmox/site.git
# It is the same on every site and after every rebuild, so a rebuild rewrites no
# URL; nothing outside the cluster resolves it, so no DNS, TLS or CA step exists.
# This script reaches the forge through a kubectl port-forward that it starts and
# stops itself.
#
# NO SECRET ON DISK OR IN A PROCESS'S ARGUMENTS. Passwords and tokens are generated
# in memory and never appear on a command line, where `ps` would show them to every
# user of the workstation: curl reads its credential from a config on a pipe
# (`-K <(...)`) and its body from stdin, git reads its header from GIT_CONFIG_*
# environment variables, and every Secret reaches kubectl as YAML on stdin. The kit
# is one stream, encrypted as it is written, never staged as plaintext files. The
# temp directory holds the values file (no secret in it), the port-forward's log,
# the last HTTP status and the last ERROR body (a success body can carry a token,
# so it is never written), and a trap removes it on every exit path.
#
# WHAT THIS DOES NOT DO (yet, each its own card): the nightly forge dump;
# rebuild and forge repair; approving in the console as yourself;
# upgrades. Taking someone OUT of the admin group takes them out of
# `approvers` only at their next forge sign-in, and with sso.apps.forge.access: admin
# (the default) that sign-in is refused, so it never happens: until a reconciler
# exists, remove them from the team by hand as well (docs/administration/identity.md). Proven on one single-node k3s
# lab cluster only; nothing here has been run against a multi-node cluster.
# ============================================================================
set -euo pipefail


# PINNED: Forgejo's long-term-support line (v15 LTS, supported to 2027-07-15 at
# the time of writing). The chart is the community forgejo-helm chart Forgejo's own
# operators call the upstream one; chart 17.3.2 ships app 15.0.11.
CHART_REF_DEFAULT="oci://code.forgejo.org/forgejo-helm/forgejo"
CHART_VERSION_DEFAULT="17.3.2"
FORGE_NS_DEFAULT="tockmox-forge"
RELEASE="tockmox-forge"
ORG="tockmox"
REPO="site"
BOT_READ="tockmox-argocd"
BOT_CHANGE="tockmox-changes"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_OFFSITE="tockmox-offsite"   # reads main for the off-site copy; nothing else
APPROVERS_TEAM="approvers"
SSO_SOURCE="authentik"         # the sign-in source's name; the identity layer's redirect URI names it
SSO_CLIENT_ID="tockmox-forge"  # sso.apps.forge.clientId in the identity layer
KIT_MARKER="# tockmox-recovery-kit v1"
PBKDF2_ITER=600000

# ---------------------------------------------------------------- presentation
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; X=$'\033[0m'
else B=""; R=""; G=""; Y=""; X=""; fi
say()  { printf '\n%s== %s%s\n' "$B" "$*" "$X"; }
ok()   { printf '%s  ✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '%s  !%s %s\n' "$Y" "$X" "$*"; }
err()  { printf '%s  ✗%s %s\n' "$R" "$X" "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { printf '    %s\n' "$*"; }

usage() {
  cat <<USAGE
Tockmox built-in forge bootstrap

Writes to a CLUSTER. Installs the built-in forge beside ArgoCD, creates the site
repository in it, pushes your site, gives ArgoCD its read credential, and writes
the encrypted recovery kit.

  tockmox-install.sh bootstrap-forge --site DIR --kit-out FILE (--age-recipient R | --passphrase-file F) [options]
  tockmox-install.sh bootstrap-forge --site DIR --connect-sign-in [--context ...]   (once tockmox-identity is Healthy)

  --site DIR             the generated site repository (site.forge: built-in)
  --context NAME         kubectl context (default: the current one)
  --yes-context NAME     confirm the context without a prompt. Must EQUAL it
  --yes-server URL       confirm the API server the same way (required with
                         --yes-context)
  --no-prompt            never read a terminal (CI, agents). Refuses instead

 Recovery kit. Required, encrypted, and never plaintext.
  --kit-out FILE         where the kit goes. Must be OUTSIDE the site repository
  --age-recipient R      encrypt to an age public key (preferred)
  --passphrase-file F    encrypt with openssl (AES-256, PBKDF2) using the first
                         line of F; the kit is then opened once to prove it
  --sealing-key-backup F the encrypted sealed-secrets key export from
                         bootstrap-secrets, folded into the kit as it is
  --no-sealing-key-backup  write the kit without it, and say so loudly

 Off-site copy. Optional; without one the console raises "No off-site copy" until you
 add one (re-run with these flags). At most one destination.
  --offsite-s3-endpoint URL   an S3-compatible endpoint, path-style (https://s3.example.com)
  --offsite-s3-bucket NAME    the bucket; a versioned or object-locked one keeps every
                              earlier copy even if someone rewrites history
  --offsite-s3-prefix P       keys go under P/ (default: none)
  --offsite-s3-region R       default us-east-1
  --offsite-s3-credentials F  two lines: the access key id, then the secret key
  --offsite-s3-ca FILE        a CA bundle for the endpoint, if it is private
  --offsite-git URL           an https git remote that receives main after every merge
                              (protect its main from force pushes)
  --offsite-git-credentials F two lines: the user, then a token that can push

 Sign-in through Authentik (on when the site has the identity layer)
  --connect-sign-in      add the forge's sign-in source now. Run it once tockmox-identity
                         is Healthy; it needs neither the kit nor the off-site flags.
                         The full run tries it at its end as well
  --forge-host HOST      the forge's browser address (default forge.<internalDomain>;
                         must equal sso.apps.forge.host in the identity layer if set)
  --admin-group G        the group whose members become approvers (default tockmox-admins,
                         the identity layer's sso.adminGroup)
  --identity-namespace NS  where Authentik runs (default tockmox-authentik)
  --platform-namespace NS  where Traefik runs, admitted through the fence (default tockmox-platform)
  --auth-host HOST       Authentik's address (default auth.<internalDomain>; set it if the
                         identity layer's ingress.apps.authentik.host is overridden)
  --no-sign-in           no sign-in, no Ingress: the forge answers only in the cluster

 Forge
  --namespace NS         default ${FORGE_NS_DEFAULT} (the in-cluster address names it;
                         change it only if you also change every Application)
  --chart REF            default ${CHART_REF_DEFAULT} (a path or .tgz for a mirror)
  --chart-version V      default ${CHART_VERSION_DEFAULT}
  --image-registry R     registry prefix for the forge image (a mirror)
  --storage-class SC     for the forge's volume (default: the cluster default)
  --argocd-namespace NS  default argocd
  --ai-namespace NS      where tockmox-actions and the model watcher run (default tockmox-ai)
  --replace-argocd-credential  replace an ArgoCD tockmox-site-repo Secret that names another
                         repository (refused without this: ArgoCD would lose that repository)
  --wait-seconds N       how long to wait for the forge (default 300)

  --dry-run              show the plan; change nothing
  -h, --help             this
USAGE
}

# ---------------------------------------------------------------- arguments
SITE=""; CONTEXT=""; CONTEXT_GIVEN=false; YES_CONTEXT=""; YES_SERVER=""; NO_PROMPT=false
KIT_OUT=""; AGE_RECIPIENT=""; PASSFILE=""; SEAL_BACKUP=""; NO_SEAL_BACKUP=false
FORGE_NS="$FORGE_NS_DEFAULT"; CHART_REF="$CHART_REF_DEFAULT"; CHART_VERSION="$CHART_VERSION_DEFAULT"
OS_S3_ENDPOINT=""; OS_S3_BUCKET=""; OS_S3_PREFIX=""; OS_S3_REGION="us-east-1"; OS_S3_CREDS=""; OS_S3_CA=""
OS_GIT_URL=""; OS_GIT_CREDS=""
IMAGE_REGISTRY=""; STORAGE_CLASS=""; ARGO_NS="argocd"; AI_NS="tockmox-ai"; WAIT_SECONDS=300; DRY_RUN=false
CONNECT_ONLY=false; NO_SIGN_IN=false; REPLACE_ARGO_CRED=false; FORGE_HOST=""; ADMIN_GROUP="tockmox-admins"
IDENTITY_NS="tockmox-authentik"; PLATFORM_NS="tockmox-platform"; AUTH_HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE="${2:?--site needs a directory}"; shift 2 ;;
    --context) CONTEXT="${2-}"; CONTEXT_GIVEN=true; shift $(( $# > 1 ? 2 : 1 )) ;;
    --yes-context) YES_CONTEXT="${2:?--yes-context needs the context name}"; shift 2 ;;
    --yes-server) YES_SERVER="${2:?--yes-server needs the API server URL}"; shift 2 ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    --kit-out) KIT_OUT="${2:?--kit-out needs a file}"; shift 2 ;;
    --age-recipient) AGE_RECIPIENT="${2:?--age-recipient needs a public key}"; shift 2 ;;
    --passphrase-file) PASSFILE="${2:?--passphrase-file needs a file}"; shift 2 ;;
    --sealing-key-backup) SEAL_BACKUP="${2:?--sealing-key-backup needs a file}"; shift 2 ;;
    --no-sealing-key-backup) NO_SEAL_BACKUP=true; shift ;;
    --namespace) FORGE_NS="${2:?--namespace needs a name}"; shift 2 ;;
    --chart) CHART_REF="${2:?--chart needs a reference}"; shift 2 ;;
    --chart-version) CHART_VERSION="${2:?--chart-version needs a version}"; shift 2 ;;
    --image-registry) IMAGE_REGISTRY="${2:?--image-registry needs a registry}"; shift 2 ;;
    --storage-class) STORAGE_CLASS="${2:?--storage-class needs a name}"; shift 2 ;;
    --argocd-namespace) ARGO_NS="${2:?--argocd-namespace needs a name}"; shift 2 ;;
    --ai-namespace) AI_NS="${2:?--ai-namespace needs a name}"; shift 2 ;;
    --offsite-s3-endpoint) OS_S3_ENDPOINT="${2:?--offsite-s3-endpoint needs a URL}"; shift 2 ;;
    --offsite-s3-bucket) OS_S3_BUCKET="${2:?--offsite-s3-bucket needs a name}"; shift 2 ;;
    --offsite-s3-prefix) OS_S3_PREFIX="${2?--offsite-s3-prefix needs a value}"; shift 2 ;;
    --offsite-s3-region) OS_S3_REGION="${2:?--offsite-s3-region needs a value}"; shift 2 ;;
    --offsite-s3-credentials) OS_S3_CREDS="${2:?--offsite-s3-credentials needs a file}"; shift 2 ;;
    --offsite-s3-ca) OS_S3_CA="${2:?--offsite-s3-ca needs a file}"; shift 2 ;;
    --offsite-git) OS_GIT_URL="${2:?--offsite-git needs a URL}"; shift 2 ;;
    --offsite-git-credentials) OS_GIT_CREDS="${2:?--offsite-git-credentials needs a file}"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="${2:?--wait-seconds needs a number}"; shift 2 ;;
    --connect-sign-in) CONNECT_ONLY=true; shift ;;
    --replace-argocd-credential) REPLACE_ARGO_CRED=true; shift ;;
    --no-sign-in) NO_SIGN_IN=true; shift ;;
    --forge-host) FORGE_HOST="${2:?--forge-host needs a host name}"; shift 2 ;;
    --admin-group) ADMIN_GROUP="${2:?--admin-group needs a group name}"; shift 2 ;;
    --identity-namespace) IDENTITY_NS="${2:?--identity-namespace needs a name}"; shift 2 ;;
    --platform-namespace) PLATFORM_NS="${2:?--platform-namespace needs a name}"; shift 2 ;;
    --auth-host) AUTH_HOST="${2:?--auth-host needs a host name}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
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

# ---------------------------------------------------------------- validate
# Everything refusable without a cluster is refused here, so a mistake in the
# command line costs nothing.
say "Checking the request"
[[ -n "$SITE" ]] || die "--site is required: the site repository the generator wrote"
[[ -d "$SITE" ]] || die "site repository not found: $SITE
       Generate it first: tockmox-install.sh --config tockmox.yaml (with site.forge: built-in)"
SITE="$(cd "$SITE" && pwd)"
[[ -f "$SITE/bootstrap/root.yaml" ]] || die "$SITE has no bootstrap/root.yaml; it is not a generated site repository"
if $CONTEXT_GIVEN && [[ -z "${CONTEXT// }" ]]; then
  die "--context was given empty. Refusing rather than falling back to the current context.
       (An unset shell variable expands to exactly this.) Name the context, or omit the flag."
fi
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a number: '$WAIT_SECONDS'"
[[ "$FORGE_NS" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--namespace is not a namespace name: '$FORGE_NS'"
REPO_URL="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000/${ORG}/${REPO}.git"

# The site must name the forge. A site generated for an external forge carries the
# placeholder; one generated with another namespace names a different address.
# Either way ArgoCD would read somewhere this script did not create, so refuse.
if grep -rqs PLACEHOLDER_SITE_REPO_URL "$SITE/bootstrap"; then
  die "$SITE was generated for an external forge (it carries PLACEHOLDER_SITE_REPO_URL).
       Regenerate it with site.forge: built-in, or follow install.md 2a-2c for your own forge."
fi
grep -rqsF "$REPO_URL" "$SITE/bootstrap/root.yaml" || die "bootstrap/root.yaml does not name the built-in forge at
         $REPO_URL
       Was the site generated with site.forge: built-in, and with this --namespace?"

# ---- sign-in: everything it needs comes from the site, and is refused here if it cannot
NS_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
HOST_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
gval() {  # KEY -> its value in the site's global.yaml (two-space indent, quotes and comment stripped)
  sed -n "s/^  $1: *//p" "$SITE/site/values/global.yaml" 2>/dev/null | head -1 | sed 's/ #.*$//' | tr -d "\"'" | tr -d '[:space:]'
}
INTERNAL_DOMAIN="$(gval internalDomain)"; CERT_ISSUER="$(gval certIssuer)"
case "$CERT_ISSUER" in null|"~") CERT_ISSUER="" ;; esac
case "$INTERNAL_DOMAIN" in null|"~") INTERNAL_DOMAIN="" ;; esac
[[ -z "$CERT_ISSUER" || "$CERT_ISSUER" =~ $NS_RE ]] || die "global.certIssuer in the site is not an issuer name: '$CERT_ISSUER'"
# forge_sso_on: does the site's identity layer turn on the forge's application?
forge_sso_on() {
  grep -Eqs '^ *forge: *\{ *enabled: *true' "$SITE/site/values/identity.yaml" \
    || grep -A1 -Es '^    forge:' "$SITE/site/values/identity.yaml" 2>/dev/null | grep -E 'enabled: *true' >/dev/null
}
SIGN_IN=true; SIGN_IN_WHY=""
if $NO_SIGN_IN; then
  $CONNECT_ONLY && die "--connect-sign-in and --no-sign-in contradict each other"
  # The identity layer's blueprint for the forge reads FORGE_CLIENT_SECRET, which only a
  # run WITH sign-in writes; an !Env with nothing behind it stops Authentik applying
  # EVERY blueprint, so every console's sign-in would go with it.
  forge_sso_on && die "--no-sign-in, but site/values/identity.yaml turns on sso.apps.forge. Its blueprint needs the
       client secret only a run with sign-in writes, and without it Authentik applies none of its blueprints.
       Set sso.apps.forge.enabled: false in that file (or drop --no-sign-in). Nothing was touched."
  SIGN_IN=false; SIGN_IN_WHY="--no-sign-in"
elif [[ ! -f "$SITE/bootstrap/applications/tockmox-identity.yaml" ]]; then
  $CONNECT_ONLY && die "the site has no identity layer (no bootstrap/applications/tockmox-identity.yaml),
       so there is no Authentik to connect the forge to"
  SIGN_IN=false; SIGN_IN_WHY="the site has no identity layer"
fi
FORGE_URL="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000/"; SCHEME=""; DISCOVERY=""
if $SIGN_IN; then
  [[ -n "$INTERNAL_DOMAIN" ]] || die "global.internalDomain is empty in $SITE/site/values/global.yaml.
       The forge's address (forge.<internalDomain>) and Authentik's come from it. Set it, or run with --no-sign-in."
  FORGE_HOST="${FORGE_HOST:-forge.${INTERNAL_DOMAIN}}"; AUTH_HOST="${AUTH_HOST:-auth.${INTERNAL_DOMAIN}}"
  [[ "$FORGE_HOST" =~ $HOST_RE ]] || die "--forge-host is not a host name: '$FORGE_HOST'"
  [[ "$AUTH_HOST" =~ $HOST_RE ]] || die "--auth-host is not a host name: '$AUTH_HOST'"
  [[ "$ADMIN_GROUP" =~ ^[A-Za-z0-9._-]+$ ]] || die "--admin-group must be letters, digits, '.', '_' or '-': '$ADMIN_GROUP'"
  [[ "$IDENTITY_NS" =~ $NS_RE ]] || die "--identity-namespace is not a namespace name: '$IDENTITY_NS'"
  [[ "$PLATFORM_NS" =~ $NS_RE ]] || die "--platform-namespace is not a namespace name: '$PLATFORM_NS'"
  # global.certIssuer set means the platform's CA signs the forge's certificate, and the
  # forge must trust that CA to reach Authentik; empty means plain http on both.
  SCHEME=http; [[ -n "$CERT_ISSUER" ]] && SCHEME=https
  FORGE_URL="${SCHEME}://${FORGE_HOST}/"
  DISCOVERY="${SCHEME}://${AUTH_HOST}/application/o/${SSO_CLIENT_ID}/.well-known/openid-configuration"
  # The identity layer's blueprint only exists when the site turned it on.
  forge_sso_on \
    || warn "site/values/identity.yaml does not turn on sso.apps.forge. Without it Authentik has no application
       for the forge and --connect-sign-in will be refused (a site generated with site.forge: built-in has it)."
fi

# ---- the kit: choose the encryption BEFORE anything is created
ENC=""; OFFSITE=""; OFFSITE_WHERE=""
if ! $CONNECT_ONLY; then
if [[ -n "$AGE_RECIPIENT" ]]; then ENC="age"
elif [[ -n "$PASSFILE" ]]; then
  ENC="openssl"
  [[ -r "$PASSFILE" && -s "$PASSFILE" ]] || die "cannot read --passphrase-file $PASSFILE, or it is empty"
fi
[[ -n "$KIT_OUT" ]] || die "--kit-out FILE is required. The recovery kit holds what a rebuild needs and the
       site repository must not carry: the forge's secrets and your sealing-key backup.
       Without it, a lost cluster cannot be rebuilt from its off-site copy."
[[ -n "$ENC" ]] || die "no way to encrypt the recovery kit, so it will not be written. Give one of:
         --age-recipient R      (age installed; preferred)
         --passphrase-file F    (openssl; the first line of F is the passphrase)"
KIT_ABS="$(abspath "$KIT_OUT")" || die "the directory for --kit-out does not exist: $(dirname "$KIT_OUT")"
case "$KIT_ABS" in
  "$SITE"/*) die "--kit-out is inside the site repository ($SITE).
       The kit exists to survive the loss of the cluster and of the site repository. Put it elsewhere." ;;
esac
[[ ! -e "$KIT_ABS" ]] || die "--kit-out $KIT_ABS already exists. Refusing to overwrite a recovery kit; name a new file."
KIT_OUT="$KIT_ABS"
if [[ -n "$SEAL_BACKUP" ]]; then
  [[ -r "$SEAL_BACKUP" && -s "$SEAL_BACKUP" ]] || die "cannot read --sealing-key-backup $SEAL_BACKUP, or it is empty"
elif ! $NO_SEAL_BACKUP; then
  die "--sealing-key-backup FILE is required: the encrypted key export bootstrap-secrets wrote.
       A rebuild needs it to open every SealedSecret in the site, so the kit carries it.
       If you keep that backup elsewhere on purpose, say so with --no-sealing-key-backup."
fi

# ---- the off-site copy: everything about it is checked before the cluster is touched
# two_lines FILE WHAT -> refuses unless FILE is readable, outside the site, and has two non-empty lines
two_lines() {
  local f="$1" what="$2" a
  [[ -r "$f" && -s "$f" ]] || die "cannot read $what $f, or it is empty"
  a="$(abspath "$f")" || die "cannot resolve $what $f"
  case "$a" in "$SITE"/*) die "$what is inside the site repository ($SITE), which is pushed to the forge. Put it elsewhere." ;; esac
  [[ "$(grep -c . "$f")" -ge 2 ]] || die "$what $f must have two lines (an id, then its secret)"
  [[ -z "$(sed -n '1,2{/["\\]/p;}' "$f")" ]] || die "$what $f contains a quote or a backslash, which cannot be passed safely"
  printf '%s' "$a"
}
OFFSITE=""
if [[ -n "$OS_S3_ENDPOINT$OS_S3_BUCKET$OS_S3_CREDS$OS_S3_CA$OS_S3_PREFIX" ]]; then OFFSITE="bucket"; fi
if [[ -n "$OS_GIT_URL$OS_GIT_CREDS" ]]; then
  [[ -z "$OFFSITE" ]] || die "give one off-site destination, a bucket OR a git remote, not both"
  OFFSITE="git"
fi
case "$OFFSITE" in
  bucket)
    [[ "$OS_S3_ENDPOINT" =~ ^https?://[^/[:space:]]+$ ]] || die "--offsite-s3-endpoint must be http(s)://host[:port] with no path: '$OS_S3_ENDPOINT'"
    [[ "$OS_S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "--offsite-s3-bucket is not a bucket name: '$OS_S3_BUCKET'"
    [[ -z "$OS_S3_PREFIX" || "$OS_S3_PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die "--offsite-s3-prefix must be path segments with no leading or trailing slash: '$OS_S3_PREFIX'"
    [[ "$OS_S3_REGION" =~ ^[a-z0-9-]+$ ]] || die "--offsite-s3-region is not a region name: '$OS_S3_REGION'"
    [[ -n "$OS_S3_CREDS" ]] || die "--offsite-s3-credentials FILE is required with a bucket"
    OS_S3_CREDS="$(two_lines "$OS_S3_CREDS" --offsite-s3-credentials)" || exit 1
    if [[ -n "$OS_S3_CA" ]]; then [[ -r "$OS_S3_CA" && -s "$OS_S3_CA" ]] || die "cannot read --offsite-s3-ca $OS_S3_CA"; fi
    [[ "$OS_S3_ENDPOINT" == https://* || -n "$OS_S3_CA" ]] || warn "the off-site endpoint is plain http: the copy and its key pair cross the network unencrypted"
    OFFSITE_WHERE="$OS_S3_ENDPOINT/$OS_S3_BUCKET${OS_S3_PREFIX:+/$OS_S3_PREFIX}" ;;
  git)
    [[ "$OS_GIT_URL" =~ ^https://[^@[:space:]]+$ ]] || die "--offsite-git must be an https URL with no credentials in it: '$OS_GIT_URL'"
    [[ -n "$OS_GIT_CREDS" ]] || die "--offsite-git-credentials FILE is required with a git remote"
    OS_GIT_CREDS="$(two_lines "$OS_GIT_CREDS" --offsite-git-credentials)" || exit 1
    OFFSITE_WHERE="$OS_GIT_URL" ;;
  *) OFFSITE_WHERE="" ;;
esac
OFFSITE_SCRIPT="$HERE/forge-offsite-copy.sh"
[[ -z "$OFFSITE" || -r "$OFFSITE_SCRIPT" ]] || die "missing $OFFSITE_SCRIPT, which the off-site CronJob runs"
fi  # not --connect-sign-in

# ---- tools
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1 ... $2"; }
need kubectl "talks to the cluster"
need helm "installs the forge (v3)"
need git "pushes the site repository"
need curl "talks to the forge's API through the port-forward"
need openssl "generates every password"
need tar "packs the recovery kit"
[[ "$ENC" == "age" ]] && need age "was asked for by --age-recipient"

CTX_CUR="$(kubectl config current-context 2>/dev/null || true)"
CTX="${CONTEXT:-$CTX_CUR}"
[[ -n "$CTX" ]] || die "no kubectl context is set and none was given. Name one with --context."
ok "request is consistent"

# ---------------------------------------------------------------- context
say "Cluster context"
SERVER="$(kubectl config view --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
info "context     ${CTX}"
info "API server  ${SERVER:-unknown}"
info "site        ${SITE}"
info "forge       release ${RELEASE} in namespace ${FORGE_NS}, chart ${CHART_REF} ${CHART_VERSION}"
info "repository  ${REPO_URL}"
if $SIGN_IN; then
  info "sign-in     ${FORGE_URL} through Authentik at ${AUTH_HOST}; ${ADMIN_GROUP} -> team ${APPROVERS_TEAM}"
else
  info "sign-in     none (${SIGN_IN_WHY}); the forge answers only in the cluster"
fi
$CONNECT_ONLY || info "kit         ${KIT_OUT} (${ENC})"
if $DRY_RUN && $CONNECT_ONLY; then
  say "Plan (dry run, nothing changed)"
  info "check the forge's certificate and Authentik's discovery address (${DISCOVERY}),"
  info "then add or update the forge's sign-in source '${SSO_SOURCE}'"
  exit 0
fi
if $DRY_RUN; then
  say "Plan (dry run, nothing changed)"
  info "install or adopt the forge; fence its port to ArgoCD (${ARGO_NS}), the AI layer (${AI_NS}) and its own namespace"
  info "create ${ORG}/${REPO}, ${BOT_READ}, ${BOT_CHANGE}, team ${APPROVERS_TEAM}"
  info "push ${SITE} as main; protect main; write the ArgoCD repository Secret in ${ARGO_NS}"
  info "give the model watcher the change bot's token: Secret ${RELEASE}-change-bot in ${AI_NS}"
  if $SIGN_IN; then
    info "an Ingress at ${FORGE_HOST}; the OIDC client secret in ${FORGE_NS} and ${IDENTITY_NS};"
    info "Traefik (${PLATFORM_NS}) admitted through the fence; the sign-in source once Authentik answers"
  fi
  if [[ -n "$OFFSITE" ]]; then info "off-site copy (${OFFSITE}) to ${OFFSITE_WHERE}: a CronJob every minute, then the first copy written and read back"
  else info "no off-site copy (the console will raise No off-site copy until one is set)"; fi
  info "write the recovery kit to ${KIT_OUT}"
  exit 0
fi
if [[ -n "$YES_CONTEXT" ]]; then
  [[ "$YES_CONTEXT" == "$CTX" ]] || die "--yes-context '$YES_CONTEXT' does not match the context in use, '$CTX'. Refusing. Nothing was touched."
  [[ -n "$SERVER" ]] || die "cannot read the API server address for context '$CTX', so it cannot be confirmed. Refusing."
  [[ -n "$YES_SERVER" ]] || die "--yes-context was given without --yes-server. Re-run with --yes-server '$SERVER' if that is the one."
  [[ "$YES_SERVER" == "$SERVER" ]] || die "--yes-server '$YES_SERVER' does not match the API server in use, '$SERVER'. Refusing. Nothing was touched."
  ok "context and API server confirmed by --yes-context and --yes-server"
else
  $NO_PROMPT && die "--no-prompt was given without --yes-context and --yes-server, so the cluster cannot be confirmed.
       Re-run with --yes-context '$CTX' --yes-server '${SERVER:-URL}' if that is the cluster you mean."
  have_tty || die "no terminal to confirm the context on. Re-run with --yes-context '$CTX' --yes-server '${SERVER:-URL}'."
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
kubectl "${K[@]}" get namespace "$ARGO_NS" >/dev/null 2>&1 || die "namespace $ARGO_NS does not exist. Install ArgoCD first
       (fresh-install.md section 6), or name its namespace with --argocd-namespace."
ok "cluster reachable, ArgoCD namespace present"
# ArgoCD's repository credential is ONE Secret, tockmox-site-repo, and the external
# route's docs name the same one. Overwriting a credential for another repository cuts
# ArgoCD off from it at its next refresh, and the old token is gone for good (it did
# exactly that to a lab cluster on 2026-11-02). So a credential for any other
# URL stops the run here, before anything is written, unless you say to replace it.
if ! $CONNECT_ONLY; then
  CUR_ERR="$(kubectl "${K[@]}" -n "$ARGO_NS" get secret tockmox-site-repo -o name 2>&1 >/dev/null)" \
    || [[ "$CUR_ERR" == *NotFound* ]] \
    || die "cannot read ${ARGO_NS}/tockmox-site-repo to check what it holds: ${CUR_ERR}. Nothing was touched."
  CUR_URL="$(kubectl "${K[@]}" -n "$ARGO_NS" get secret tockmox-site-repo -o jsonpath='{.data.url}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "$CUR_URL" && "$CUR_URL" != "$REPO_URL" ]]; then
    $REPLACE_ARGO_CRED || die "${ARGO_NS}/tockmox-site-repo already holds ArgoCD's credential for
         ${CUR_URL}
       This run would replace it with the built-in forge's, and ArgoCD would lose that repository at its next
       refresh. Nothing was touched. If this cluster is moving its site to the built-in forge, keep a copy of
       that Secret and re-run with --replace-argocd-credential; to try the forge beside a running site, use
       another cluster."
    warn "replacing ArgoCD's credential for ${CUR_URL} (--replace-argocd-credential)"
  fi
fi

TMPD="$(mktemp -d)"
gen() {  # n -> n random alphanumerics, or the run stops
  local v; v="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}")"
  [[ "${#v}" -eq "${1:-32}" ]] || die "could not generate a ${1:-32}-character secret (openssl rand failed?)"
  printf '%s' "$v"
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
# secret_apply NS NAME [label] KEY=VALUE... -> a Secret applied from YAML on stdin.
# Values travel as function arguments (bash builtins, never an exec'd argv) and
# reach kubectl only on its stdin, so `ps` never shows them.
secret_apply() {
  local ns="$1" name="$2" label="$3"; shift 3
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n' "$name" "$ns"
    [[ -z "$label" ]] || printf '  labels:\n    %s\n' "$label"
    printf 'type: Opaque\ndata:\n'
    local kv; for kv in "$@"; do printf '  %s: %s\n' "${kv%%=*}" "$(b64 "${kv#*=}")"; done
  } | kubectl "${K[@]}" apply -f - >/dev/null
}

# ---------------------------------------------------------------- install
# connect_sign_in: add (or update) the forge's sign-in source. Defined here because
# --connect-sign-in runs it on its own, after the context is confirmed, and the full
# run tries it once at its end. Returns non-zero, with the forge's own words, when
# Authentik does not answer yet; never dies, so the full run can finish without it.
connect_sign_in() {
  local pod started ca_made list id out
  pod="$(kubectl "${K[@]}" -n "$FORGE_NS" get pod -l "app.kubernetes.io/instance=$RELEASE" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { warn "the forge has no running pod"; return 1; }
  if [[ "$SCHEME" == https ]]; then
    # The forge trusts the platform's CA through the ca.crt cert-manager writes beside
    # its certificate. That Secret appears only once the platform layer runs, after this
    # forge started; a process that started without it has no CA to trust, so restart once.
    ca_made="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-tls" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
    if [[ -z "$ca_made" ]] || [[ -z "$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-tls" -o jsonpath='{.data.ca\.crt}' 2>/dev/null)" ]]; then
      warn "the forge's certificate (${FORGE_NS}/${RELEASE}-tls, with ca.crt) does not exist yet: cert-manager issues it once
       tockmox-platform is Healthy. Sign-in waits for it."
      return 1
    fi
    started="$(kubectl "${K[@]}" -n "$FORGE_NS" get pod "$pod" -o jsonpath='{.status.startTime}' 2>/dev/null || true)"
    if [[ -z "$started" || "$started" < "$ca_made" ]]; then
      info "the forge started before its certificate existed; restarting it once so it trusts the CA"
      if ! kubectl "${K[@]}" -n "$FORGE_NS" rollout restart deploy/"$RELEASE" >/dev/null \
         || ! kubectl "${K[@]}" -n "$FORGE_NS" rollout status deploy/"$RELEASE" --timeout="${WAIT_SECONDS}s" >/dev/null; then
        warn "the forge did not come back within ${WAIT_SECONDS}s after the restart"; return 1
      fi
    fi
  fi
  # A list that FAILED must not read as "no source yet": that would add a second one.
  list="$(kubectl "${K[@]}" -n "$FORGE_NS" exec deploy/"$RELEASE" -c forgejo -- forgejo admin auth list --vertical-bars 2>/dev/null)" \
    || { warn "could not list the forge's sign-in sources (is its pod restarting?)"; return 1; }
  printf '%s\n' "$list" | grep '^ID' >/dev/null || { warn "the forge's list of sign-in sources did not read as one"; return 1; }
  id="$(printf '%s\n' "$list" | awk -F'|' -v n="$SSO_SOURCE" '{for (i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)} $2==n && $3=="OAuth2" {print $1}')"
  [[ "$(printf '%s' "$id" | grep -c .)" -le 1 ]] || { warn "the forge has more than one sign-in source named ${SSO_SOURCE}; remove the extra one first"; return 1; }
  # The client secret goes in on stdin, so it is on no command line on this workstation
  # (inside the pod it is the forgejo CLI's argument while that runs; the CLI takes it
  # no other way). The map names the ADMIN group's members `approvers`, never forge admins.
  local -a flags=(--name "$SSO_SOURCE" --provider openidConnect --key "$SSO_CLIENT_ID"
    --auto-discover-url "$DISCOVERY" --scopes "openid email profile"
    --group-claim-name groups --group-team-map "{\"${ADMIN_GROUP}\":{\"${ORG}\":[\"${APPROVERS_TEAM}\"]}}"
    --group-team-map-removal)
  [[ -z "$id" ]] || flags=(--id "$id" "${flags[@]}")
  # shellcheck disable=SC2016  # $0, $S and $@ are the pod's shell's, not this one's
  out="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-oidc" -o jsonpath='{.data.secret}' | base64 -d \
    | kubectl "${K[@]}" -n "$FORGE_NS" exec -i deploy/"$RELEASE" -c forgejo -- \
        sh -c 'IFS= read -r S; exec forgejo admin auth "$0" --secret "$S" "$@"' \
        "$([[ -z "$id" ]] && echo add-oauth || echo update-oauth)" "${flags[@]}" 2>&1)" || {
    warn "the forge refused the sign-in source: $(printf '%s' "$out" | grep -E 'error|Error|Failed' | grep -v '\[I\]' | tail -1)"
    info "Authentik answers at ${DISCOVERY} only once tockmox-identity is Healthy with sso.apps.forge.enabled: true."
    return 1
  }
  list="$(kubectl "${K[@]}" -n "$FORGE_NS" exec deploy/"$RELEASE" -c forgejo -- forgejo admin auth list --vertical-bars 2>/dev/null || true)"
  printf '%s\n' "$list" | awk -F'|' -v n="$SSO_SOURCE" '{for (i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)} $2==n && $3=="OAuth2" && $4=="true" {f=1} END {exit !f}' \
    || { warn "the sign-in source '${SSO_SOURCE}' does not read back as an enabled OAuth2 source"; return 1; }
  ok "sign-in: ${FORGE_URL} signs people in through Authentik; ${ADMIN_GROUP} members join ${APPROVERS_TEAM} at sign-in"
}

if $CONNECT_ONLY; then
  say "Connecting the forge's sign-in"
  helm --kube-context "$CTX" -n "$FORGE_NS" status "$RELEASE" >/dev/null 2>&1 \
    || die "release ${RELEASE} is not installed in ${FORGE_NS}. Run bootstrap-forge without --connect-sign-in first."
  kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-oidc" >/dev/null 2>&1 \
    || die "${FORGE_NS}/${RELEASE}-oidc does not exist: this forge was installed without sign-in.
       Re-run bootstrap-forge without --connect-sign-in (and without --no-sign-in) to give it one."
  connect_sign_in || die "sign-in is not connected yet. Nothing else was changed; run this again when the above is fixed."
  exit 0
fi

say "The forge"
# The OIDC client secret, one value in two Secrets: the forge's, which the sign-in
# source is created from, and the identity layer's, which Authentik's blueprint reads
# (FORGE_CLIENT_SECRET). An existing value is kept, from either side, so a re-run or a
# forge repair never leaves Authentik holding a different one than the forge.
if $SIGN_IN; then
  OIDC_SECRET="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-oidc" -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  ID_SECRET="$(kubectl "${K[@]}" -n "$IDENTITY_NS" get secret tockmox-sso-forge -o jsonpath='{.data.FORGE_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  OIDC_SECRET="${OIDC_SECRET:-${ID_SECRET:-$(gen 48)}}"
  for ns in "$FORGE_NS" "$IDENTITY_NS"; do
    kubectl "${K[@]}" get namespace "$ns" >/dev/null 2>&1 || kubectl "${K[@]}" create namespace "$ns" >/dev/null
  done
  secret_apply "$FORGE_NS" "${RELEASE}-oidc" "" key="$SSO_CLIENT_ID" secret="$OIDC_SECRET"
  secret_apply "$IDENTITY_NS" tockmox-sso-forge "" FORGE_CLIENT_SECRET="$OIDC_SECRET"
  if [[ -n "$ID_SECRET" && "$ID_SECRET" != "$OIDC_SECRET" ]]; then
    warn "${IDENTITY_NS}/tockmox-sso-forge held a different client secret and now holds the forge's. Authentik reads it
       at start: restart its server and worker, then delete and re-sync the tockmox-app-forge blueprint, or the
       forge's sign-in is refused (invalid_client)."
  fi
  ok "OIDC client ${SSO_CLIENT_ID}: one secret in ${FORGE_NS}/${RELEASE}-oidc and ${IDENTITY_NS}/tockmox-sso-forge"
fi

# The release's values are this script's: an adopted release is upgraded to the values
# this run writes, so a value set by hand on it is reverted (set it here instead).
if helm --kube-context "$CTX" -n "$FORGE_NS" status "$RELEASE" >/dev/null 2>&1; then
  ADOPT=true
  ok "release ${RELEASE} already installed in ${FORGE_NS}; adopting it (its data and admin are kept)"
  ADMIN_USER="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
  ADMIN_PASS="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || die "release ${RELEASE} exists but its admin Secret ${RELEASE}-admin does not.
       It was not installed by this script. Refusing to guess at a forge it did not create."
  # A volume's class cannot change in place: keep the one it was made with unless told.
  # (gitea-shared-storage is the chart's own claim name, persistence.claimName.)
  if [[ -z "$STORAGE_CLASS" ]]; then
    STORAGE_CLASS="$(kubectl "${K[@]}" -n "$FORGE_NS" get pvc gitea-shared-storage -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
  fi
else
  ADOPT=false
  kubectl "${K[@]}" get namespace "$FORGE_NS" >/dev/null 2>&1 \
    || kubectl "${K[@]}" create namespace "$FORGE_NS" >/dev/null
  ADMIN_USER="tockmox-admin"; ADMIN_PASS="$(gen 32)"
  # The admin credential lives in ONE Secret the chart reads (gitea.admin.existingSecret).
  secret_apply "$FORGE_NS" "${RELEASE}-admin" "" username="$ADMIN_USER" password="$ADMIN_PASS"
fi
# No secret in this file: the admin password comes from the Secret above, the OIDC
# client secret is added by connect_sign_in from its own Secret, and the forge generates
# its own SECRET_KEY and tokens on first start (the kit exports them).
{
cat <<VALUES
fullnameOverride: ${RELEASE}
replicaCount: 1
strategy:
  type: Recreate
$( [[ -n "$IMAGE_REGISTRY" ]] && printf 'image:\n  registry: %s\n' "$IMAGE_REGISTRY" )
persistence:
  enabled: true
  size: 5Gi
$( [[ -n "$STORAGE_CLASS" ]] && printf '  storageClass: %s\n' "$STORAGE_CLASS" )
service:
  http:
    type: ClusterIP
    port: 3000
  ssh:
    type: ClusterIP
postgresql:
  enabled: false
postgresql-ha:
  enabled: false
redis-cluster:
  enabled: false
redis:
  enabled: false
valkey:
  enabled: false
valkey-cluster:
  enabled: false
VALUES
if $SIGN_IN; then
  # The browser address. The class is the cluster default (the platform layer's Traefik
  # marks itself default); the Ingress waits harmlessly until Traefik and cert-manager exist.
  cat <<VALUES
ingress:
  enabled: true
$( [[ "$SCHEME" == https ]] && printf '  annotations:\n    cert-manager.io/cluster-issuer: %s\n' "$CERT_ISSUER" )
  hosts:
    - host: ${FORGE_HOST}
      paths:
        - path: /
          pathType: Prefix
$( [[ "$SCHEME" == https ]] && printf '  tls:\n    - secretName: %s-tls\n      hosts: [%s]\n' "$RELEASE" "$FORGE_HOST" )
VALUES
  if [[ "$SCHEME" == https ]]; then
    # Trust: ONLY ca.crt from the certificate's Secret (never its key), as an extra
    # directory beside the image's own store. Go reads every directory in SSL_CERT_DIR.
    # Optional, so the forge starts before cert-manager exists; connect_sign_in restarts
    # it once when the CA arrived after it started.
    cat <<VALUES
extraVolumes:
  - name: tockmox-ca
    secret:
      secretName: ${RELEASE}-tls
      optional: true
      items: [{key: ca.crt, path: tockmox-ca.crt}]
extraContainerVolumeMounts:
  - name: tockmox-ca
    mountPath: /etc/tockmox-ca
    readOnly: true
extraInitVolumeMounts:
  - name: tockmox-ca
    mountPath: /etc/tockmox-ca
    readOnly: true
deployment:
  env:
    - name: SSL_CERT_DIR
      value: /etc/ssl/certs:/etc/tockmox-ca
VALUES
  fi
else
  printf 'ingress:\n  enabled: false\n'
fi
cat <<VALUES
gitea:
  admin:
    existingSecret: ${RELEASE}-admin
    email: admin@${RELEASE}.invalid
  config:
    APP_NAME: Tockmox site forge
    database:
      DB_TYPE: sqlite3
    session:
      PROVIDER: memory
    cache:
      ADAPTER: memory
    queue:
      TYPE: level
    indexer:
      ISSUE_INDEXER_TYPE: bleve
      REPO_INDEXER_ENABLED: false
    server:
      ROOT_URL: ${FORGE_URL}
      DOMAIN: $( $SIGN_IN && printf '%s' "$FORGE_HOST" || printf '%s' "${RELEASE}-http.${FORGE_NS}.svc.cluster.local" )
      DISABLE_SSH: true
      START_SSH_SERVER: false
      OFFLINE_MODE: true
    repository:
      DEFAULT_BRANCH: main
      DEFAULT_PRIVATE: private
      ENABLE_PUSH_CREATE_USER: false
      ENABLE_PUSH_CREATE_ORG: false
    service:
      # No local sign-up. Sign-in registers people through Authentik (measured on
      # 15.0.11: auto-registration works with registration disabled).
      DISABLE_REGISTRATION: true
      REQUIRE_SIGNIN_VIEW: true
      DEFAULT_ALLOW_CREATE_ORGANIZATION: false
      DEFAULT_USER_VISIBILITY: private
      # No username-and-password form in the browser, so the forge's admin (who can
      # merge past the rule) has no web sign-in at forge.<internalDomain>. The API's
      # basic auth, which this script uses through its port-forward, still works
      # (measured on 15.0.11). Off only with sign-in: without it the form is the only way in.
      ENABLE_INTERNAL_SIGNIN: $( $SIGN_IN && printf false || printf true )
    oauth2_client:
      ENABLE_AUTO_REGISTRATION: true
      # Never sign someone in as an existing forge user because the names match.
      ACCOUNT_LINKING: disabled
      USERNAME: nickname
      UPDATE_AVATAR: false
    openid:
      ENABLE_OPENID_SIGNIN: false
      ENABLE_OPENID_SIGNUP: false
    security:
      INSTALL_LOCK: true
    actions:
      ENABLED: false
    federation:
      ENABLED: false
    mirror:
      ENABLED: true
    api:
      ENABLE_SWAGGER: false
VALUES
} > "$TMPD/values.yaml"
info "$($ADOPT && echo upgrading || echo installing) chart ${CHART_REF} ${CHART_VERSION} (an install pulls the forge image)"
helm --kube-context "$CTX" upgrade --install "$RELEASE" "$CHART_REF" --version "$CHART_VERSION" \
  -n "$FORGE_NS" -f "$TMPD/values.yaml" --wait --timeout "${WAIT_SECONDS}s" >/dev/null \
  || die "helm $($ADOPT && echo upgrade || echo install) of the forge failed or did not become ready within ${WAIT_SECONDS}s.
       Look at: kubectl --context $CTX -n $FORGE_NS get pods,events"
ok "forge $($ADOPT && echo upgraded || echo installed): release ${RELEASE} in ${FORGE_NS}"
kubectl "${K[@]}" -n "$FORGE_NS" rollout status deploy/"$RELEASE" --timeout="${WAIT_SECONDS}s" >/dev/null \
  || die "the forge did not become ready within ${WAIT_SECONDS}s"

# The fence. Applied on every run, so an adopted forge gets it too. Ingress only:
# the policy does not limit egress (the push mirror and the off-site CronJob reach a
# destination you choose). Pods are named by label AND namespace, so a pod that copies
# a label in some other namespace gets nothing. Measured 2026-11-01 on a lab cluster
# (k3s, kube-router): a repo-server-labelled pod in the ArgoCD namespace and a pod
# in the forge namespace connect; an unlabelled pod there and a repo-server-
# labelled pod in `default` are refused; the forge's own probes keep it Ready. A
# pod that has just started can be refused for its first ~10 s while kube-router
# adds it to the policy's sets; ArgoCD retries.
# With sign-in, Traefik too: it serves the Ingress at the forge's browser address.
TRAEFIK_PEER=""
if $SIGN_IN; then
  TRAEFIK_PEER="        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ${PLATFORM_NS} }
          podSelector:
            matchLabels: { app.kubernetes.io/name: traefik }"
fi
kubectl "${K[@]}" apply -f - >/dev/null <<NETPOL || die "could not apply the forge's NetworkPolicy"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${RELEASE}-ingress
  namespace: ${FORGE_NS}
  labels:
    app.kubernetes.io/managed-by: tockmox-install
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/instance: ${RELEASE}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ${ARGO_NS} }
          podSelector:
            matchLabels: { app.kubernetes.io/name: argocd-repo-server }
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ${AI_NS} }
          podSelector:
            matchExpressions:
              - { key: app.kubernetes.io/name, operator: In, values: [tockmox-actions, tockmox-model-watch] }
        - podSelector: {}
${TRAEFIK_PEER}
      ports:
        - { port: 3000, protocol: TCP }
NETPOL
ok "forge fenced: port 3000 admits ArgoCD's repo-server, tockmox-actions, the model watcher$($SIGN_IN && printf ', Traefik') and ${FORGE_NS}'s own pods"

# ---------------------------------------------------------------- reach it
# A port-forward this script starts and stops. The address ArgoCD uses is the
# Service's in-cluster one; this is only how a workstation reaches the same Service.
PF_LOG="$TMPD/pf.log"
kubectl "${K[@]}" -n "$FORGE_NS" port-forward "svc/${RELEASE}-http" 0:3000 >"$PF_LOG" 2>&1 &
PF_PID=$!
PORT=""
for _ in $(seq 1 30); do
  PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 3000$/\1/p' "$PF_LOG" | head -1)"
  [[ -n "$PORT" ]] && break
  kill -0 "$PF_PID" 2>/dev/null || die "the port-forward to the forge exited: $(cat "$PF_LOG")"
  sleep 1
done
[[ -n "$PORT" ]] || die "the port-forward to the forge did not start: $(cat "$PF_LOG")"
API="http://127.0.0.1:${PORT}/api/v1"
# Authenticated: REQUIRE_SIGNIN_VIEW refuses even /version to an anonymous caller
# ("Only signed in user is allowed to call APIs"), which is the setting working.
# curl's credential arrives as a config on a pipe, never in its argv.
curl_auth() {  # user:pass [sudo-user]
  printf 'user = "%s"\n' "$1"
  [[ -z "${2:-}" ]] || printf 'header = "Sudo: %s"\n' "$2"
}
# api METHOD PATH [JSON] [USER:PASS] -> body on stdout; SUDO_AS=user acts as that
# user with the admin's credential. The HTTP status goes to a FILE, not a variable:
# most calls run inside $(...), a subshell, and a variable set there never reaches
# the `expect` that follows. (The first draft did exactly that, and checked every
# call against the previous call's status.) Only an ERROR body is written to disk.
api() {
  local m="$1" p="$2" d="${3:-}" auth="${4:-$ADMIN_USER:$ADMIN_PASS}" body code
  local -a dat=()
  [[ -z "$d" ]] || dat=(-H 'Content-Type: application/json' --data-binary @-)
  body="$(printf '%s' "$d" | curl -sS -w '\n%{http_code}' -X "$m" -K <(curl_auth "$auth" "${SUDO_AS:-}") \
          "${dat[@]}" "$API$p")" || body=$'\n000'
  code="${body##*$'\n'}"; body="${body%$'\n'*}"
  printf '%s' "$code" > "$TMPD/http"
  case "$code" in 2*) : > "$TMPD/resp" ;; *) printf '%s' "$body" | head -c 400 > "$TMPD/resp" ;; esac
  printf '%s' "$body"
}
FV=""
for _ in $(seq 1 60); do
  FV="$(api GET /version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" || true
  [[ -n "$FV" ]] && break
  sleep 2
done
[[ -n "$FV" ]] || die "the forge's API did not answer through the port-forward, or refused the admin credential (HTTP $(cat "$TMPD/http" 2>/dev/null))"
ok "forge answers as ${ADMIN_USER} (version ${FV})"
status() { cat "$TMPD/http" 2>/dev/null || printf '000'; }
expect() {  # what, allowed codes...
  local what="$1" got; shift
  got="$(status)"
  local c; for c in "$@"; do [[ "$got" == "$c" ]] && return 0; done
  die "$what failed (HTTP $got): $(head -c 400 "$TMPD/resp")"
}
json_field() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

# ---------------------------------------------------------------- repository
say "The site repository"
api GET "/orgs/$ORG" >/dev/null
if [[ "$(status)" == 404 ]]; then
  api POST /orgs "{\"username\":\"$ORG\",\"visibility\":\"private\",\"repo_admin_change_team_access\":false}" >/dev/null
  expect "creating organisation $ORG" 201
  ok "organisation $ORG created"
else expect "reading organisation $ORG" 200; ok "organisation $ORG exists"; fi

api GET "/repos/$ORG/$REPO" >/dev/null
if [[ "$(status)" == 404 ]]; then
  api POST "/orgs/$ORG/repos" "{\"name\":\"$REPO\",\"private\":true,\"default_branch\":\"main\",\"auto_init\":false}" >/dev/null
  expect "creating repository $ORG/$REPO" 201
  ok "repository $ORG/$REPO created (private, empty)"
else
  expect "reading repository $ORG/$REPO" 200
  ok "repository $ORG/$REPO exists"
fi

# Machine users. Each gets a random password nobody keeps (tokens are what is used)
# and is told not to change it, since no person ever signs in as it.
mkuser() {  # name
  api GET "/users/$1" >/dev/null
  if [[ "$(status)" == 404 ]]; then
    api POST /admin/users "{\"username\":\"$1\",\"email\":\"$1@${RELEASE}.invalid\",\"password\":\"$(gen 40)\",\"must_change_password\":false,\"visibility\":\"private\"}" >/dev/null
    expect "creating user $1" 201
    ok "machine user $1 created"
  else expect "reading user $1" 200; ok "machine user $1 exists"; fi
}
mkuser "$BOT_READ"
mkuser "$BOT_CHANGE"
mkuser "$BOT_OFFSITE"

# Teams carry the permissions, so a token is never broader than its team.
mkteam() {  # name permission user...
  local t="$1" perm="$2"; shift 2
  local id
  id="$(api GET "/orgs/$ORG/teams/search?q=$t" | sed -n "s/.*\"id\":\([0-9]*\),\"name\":\"$t\".*/\1/p" | head -1)"
  if [[ -z "$id" ]]; then
    id="$(api POST "/orgs/$ORG/teams" "{\"name\":\"$t\",\"permission\":\"$perm\",\"includes_all_repositories\":false,\"units\":[\"repo.code\",\"repo.pulls\"]}" | sed -n 's/^{"id":\([0-9]*\),.*/\1/p')"
    expect "creating team $t" 201
    [[ -n "$id" ]] || die "creating team $t returned no id"
  fi
  api PUT "/teams/$id/repos/$ORG/$REPO" >/dev/null; expect "adding $ORG/$REPO to team $t" 204
  local u; for u in "$@"; do api PUT "/teams/$id/members/$u" >/dev/null; expect "adding $u to team $t" 204; done
  ok "team $t ($perm)${*:+: $*}"
}
mkteam readers read "$BOT_READ" "$BOT_OFFSITE"
mkteam changes write "$BOT_CHANGE"
mkteam "$APPROVERS_TEAM" write

# Tokens, minted as the user they belong to, through the admin's sudo. A fresh name
# per run, so a re-run never fails on a name collision and never reuses a token.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mktoken() {  # user scope...
  local u="$1"; shift
  local scopes; scopes="$(printf '"%s",' "$@")"; scopes="[${scopes%,}]"
  local body
  body="$(SUDO_AS="$u" api POST "/users/$u/tokens" "{\"name\":\"${TOKEN_NAME:-bootstrap-$STAMP}\",\"scopes\":$scopes}")"
  expect "minting a token for $u" 201
  printf '%s' "$body" | json_field sha1
}
# A re-run mints fresh tokens and then revokes this script's older ones, so tokens
# never pile up and the one ArgoCD holds is always the newest. Only names this
# script writes (bootstrap-<stamp>, bootstrap-watch-<stamp>) are touched; a token
# someone made by hand stays.
revoke_old() {  # user keep-name...
  local u="$1" n; shift
  local names
  names="$(SUDO_AS="$u" api GET "/users/$u/tokens" | grep -oE '"name":"bootstrap-([a-z]+-)?[0-9TZ]*"' | cut -d'"' -f4 || true)"
  for n in $names; do
    [[ " $* " == *" $n "* ]] && continue
    SUDO_AS="$u" api DELETE "/users/$u/tokens/$n" >/dev/null
    [[ "$(status)" == 204 ]] || warn "could not revoke $u's older token $n (HTTP $(status)); revoke it in the forge"
  done
}
TOKEN_READ="$(mktoken "$BOT_READ" read:repository)"
TOKEN_CHANGE="$(mktoken "$BOT_CHANGE" write:repository write:issue)"
# The model watcher opens its changes as the same bot, with a token of its own, so
# either can be revoked without the other.
TOKEN_WATCH="$(TOKEN_NAME="bootstrap-watch-$STAMP" mktoken "$BOT_CHANGE" write:repository write:issue)"
[[ -n "$TOKEN_READ" && -n "$TOKEN_CHANGE" && -n "$TOKEN_WATCH" ]] || die "a token came back empty"
ok "tokens minted for $BOT_READ (read:repository) and $BOT_CHANGE (write:repository, write:issue; one for the console, one for the model watcher)"
# The older tokens are revoked only once the new ones are in their Secrets (below).
# Revoking here, as this script first did, left a re-run that stopped in between (a
# forge whose main had moved past the site's, say) with every Secret holding a revoked
# token: ArgoCD and the change bot answered 401 (measured on the lab, 2026-11-02).

# ---------------------------------------------------------------- push
say "Publishing the site"
SEALED="$(find "$SITE/secrets" -name '*.yaml' -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$SEALED" -gt 0 ]] || warn "no sealed credentials under $SITE/secrets. Run bootstrap-secrets first (install step 0),
       or the layers that need credentials will wait for them after the first sync."
AUTH_HDR="Authorization: Basic $(printf '%s:%s' "$ADMIN_USER" "$ADMIN_PASS" | base64 | tr -d '\n')"
PUSH_URL="http://127.0.0.1:${PORT}/${ORG}/${REPO}.git"
if [[ ! -d "$SITE/.git" ]]; then
  git -C "$SITE" init -q -b main
fi
git -C "$SITE" add -A
if ! git -C "$SITE" diff --cached --quiet 2>/dev/null || ! git -C "$SITE" rev-parse -q --verify HEAD >/dev/null; then
  git -C "$SITE" -c user.name="Tockmox installer" -c user.email="installer@${RELEASE}.invalid" \
    commit -q -m "Tockmox site: published to the built-in forge" \
    || die "could not commit the site in $SITE"
fi
[[ "$(git -C "$SITE" rev-parse --abbrev-ref HEAD)" == main ]] || die "the site's branch is not main; the Applications target main"
# The credential travels as a header in GIT_CONFIG_* environment variables for these
# commands only: never in a remote URL, the site's git config, or git's argv.
gita() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$AUTH_HDR" git "$@"; }
REMOTE_HEAD="$(gita ls-remote "$PUSH_URL" refs/heads/main 2>/dev/null | cut -f1 || true)"
LOCAL_HEAD="$(git -C "$SITE" rev-parse HEAD)"
if [[ -n "$REMOTE_HEAD" && "$REMOTE_HEAD" != "$LOCAL_HEAD" ]]; then
  git -C "$SITE" merge-base --is-ancestor "$REMOTE_HEAD" "$LOCAL_HEAD" 2>/dev/null \
    || die "the forge's main ($REMOTE_HEAD) is not an ancestor of $SITE's ($LOCAL_HEAD).
       The forge holds history this directory does not. Refusing to overwrite it."
fi
if [[ "$REMOTE_HEAD" != "$LOCAL_HEAD" ]]; then
  # Protection may already be on from an earlier run; lift it for the installer's own push.
  api DELETE "/repos/$ORG/$REPO/branch_protections/main" >/dev/null || true
  gita -C "$SITE" push -q "$PUSH_URL" main:main \
    || die "pushing the site to the forge failed"
  ok "site pushed as main ($(git -C "$SITE" rev-parse --short HEAD))"
else
  ok "the forge already holds this site's main ($(git -C "$SITE" rev-parse --short HEAD))"
fi
REMOTE_HEAD="$(gita ls-remote "$PUSH_URL" refs/heads/main | cut -f1)"
[[ "$REMOTE_HEAD" == "$LOCAL_HEAD" ]] || die "after the push the forge's main is '$REMOTE_HEAD', not '$LOCAL_HEAD'"

# ---------------------------------------------------------------- protect
say "Protecting main"
APPROVERS_ID="$(api GET "/orgs/$ORG/teams/search?q=$APPROVERS_TEAM" | sed -n "s/.*\"id\":\([0-9]*\),\"name\":\"$APPROVERS_TEAM\".*/\1/p" | head -1)"
[[ -n "$APPROVERS_ID" ]] || die "cannot find team $APPROVERS_TEAM"
api DELETE "/repos/$ORG/$REPO/branch_protections/main" >/dev/null || true
api POST "/repos/$ORG/$REPO/branch_protections" "{
  \"rule_name\":\"main\",
  \"enable_push\":false,
  \"required_approvals\":1,
  \"enable_approvals_whitelist\":true,
  \"approvals_whitelist_teams\":[\"$APPROVERS_TEAM\"],
  \"block_on_rejected_reviews\":true,
  \"dismiss_stale_approvals\":true
}" >/dev/null
expect "protecting main" 201
# Assert on the artifact, not the exit code: read the rule back.
RULE="$(api GET "/repos/$ORG/$REPO/branch_protections/main")"
expect "reading the rule on main" 200
for want in '"enable_push":false' '"required_approvals":1' '"enable_approvals_whitelist":true' "\"approvals_whitelist_teams\":\[\"$APPROVERS_TEAM\"\]"; do
  printf '%s' "$RULE" | grep "$want" >/dev/null || die "the rule on main does not read back $want: $RULE"
done
ok "main: no direct pushes, one approval from team $APPROVERS_TEAM (the forge admin can still override; see the header)"
if $SIGN_IN; then
  info "members of ${ADMIN_GROUP} join $APPROVERS_TEAM when they sign in to ${FORGE_URL} (after --connect-sign-in)"
else
  warn "nobody can join $APPROVERS_TEAM without sign-in (${SIGN_IN_WHY}): add approvers in the forge as its admin"
fi

# ---------------------------------------------------------------- credentials
say "ArgoCD's read credential and the console's change identity"
secret_apply "$ARGO_NS" tockmox-site-repo "argocd.argoproj.io/secret-type: repository" \
  type=git url="$REPO_URL" username="$BOT_READ" password="$TOKEN_READ"
LBL="$(kubectl "${K[@]}" -n "$ARGO_NS" get secret tockmox-site-repo -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}')"
[[ "$LBL" == repository ]] || die "the ArgoCD repository Secret does not carry its label; ArgoCD would never read it"
ok "ArgoCD repository Secret ${ARGO_NS}/tockmox-site-repo (user $BOT_READ, read only)"
secret_apply "$FORGE_NS" "${RELEASE}-change-bot" "" \
  username="$BOT_CHANGE" token="$TOKEN_CHANGE" \
  url="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000" repository="$ORG/$REPO"
ok "change identity ${FORGE_NS}/${RELEASE}-change-bot (opens changes; cannot approve them)"
# The model watcher (modelLifecycle.watch in the AI layer) reads `token` from a Secret
# in its own namespace; docs/administration/model-lifecycle.md has the values that
# point it at this forge. The namespace may not exist yet: ArgoCD adopts it.
kubectl "${K[@]}" get namespace "$AI_NS" >/dev/null 2>&1 || kubectl "${K[@]}" create namespace "$AI_NS" >/dev/null
secret_apply "$AI_NS" "${RELEASE}-change-bot" "" \
  username="$BOT_CHANGE" token="$TOKEN_WATCH" \
  url="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000" repository="$ORG/$REPO"
ok "model watcher's identity ${AI_NS}/${RELEASE}-change-bot (the same bot, its own token)"
revoke_old "$BOT_READ" "bootstrap-$STAMP"
revoke_old "$BOT_CHANGE" "bootstrap-$STAMP" "bootstrap-watch-$STAMP"

# ---------------------------------------------------------------- off-site copy
# A CronJob in the forge namespace, every minute, running install/forge-offsite-copy.sh
# in the forge's own image (git and curl are already in it, so the air-gap set gains
# nothing). It exits 0 only when the destination holds the forge's current main, and
# the observability layer alerts when it has not succeeded for 15 minutes: the job's
# success IS the health signal (kube_cronjob_status_last_successful_time), so no new
# scrape target and no hole in the forge's NetworkPolicy. For a git remote the forge's
# own push mirror pushes on every commit and the job only verifies.
if [[ -n "$OFFSITE" ]]; then
  say "The off-site copy"
  IMAGE="$(kubectl "${K[@]}" -n "$FORGE_NS" get deploy "$RELEASE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="forgejo")].image}')"
  [[ -n "$IMAGE" ]] || die "cannot read the forge's image from deploy/$RELEASE"
  TOKEN_OFFSITE="$(mktoken "$BOT_OFFSITE" read:repository)"
  [[ -n "$TOKEN_OFFSITE" ]] || die "minting a token for $BOT_OFFSITE returned none"
  if [[ "$OFFSITE" == bucket ]]; then
    secret_apply "$FORGE_NS" "${RELEASE}-offsite" "" forge-username="$BOT_OFFSITE" forge-token="$TOKEN_OFFSITE" \
      s3-access-key-id="$(sed -n 1p "$OS_S3_CREDS")" s3-secret-access-key="$(sed -n 2p "$OS_S3_CREDS")"
    ENV_YAML="                - { name: MODE, value: bucket }
                - { name: S3_ENDPOINT, value: \"$OS_S3_ENDPOINT\" }
                - { name: S3_BUCKET, value: \"$OS_S3_BUCKET\" }
                - { name: S3_PREFIX, value: \"$OS_S3_PREFIX\" }
                - { name: S3_REGION, value: \"$OS_S3_REGION\" }"
  else
    secret_apply "$FORGE_NS" "${RELEASE}-offsite" "" forge-username="$BOT_OFFSITE" forge-token="$TOKEN_OFFSITE" \
      git-username="$(sed -n 1p "$OS_GIT_CREDS")" git-password="$(sed -n 2p "$OS_GIT_CREDS")"
    ENV_YAML="                - { name: MODE, value: git }
                - { name: GIT_REMOTE_URL, value: \"$OS_GIT_URL\" }"
    # The push mirror: main only, on every commit, with an hourly retry. Recreated on
    # each run so a rotated remote token takes effect; the remote's own rule against
    # force pushes is what turns a rewritten history into a refusal and an alert.
    for name in $(api GET "/repos/$ORG/$REPO/push_mirrors" | grep -o '"remote_name":"[^"]*"' | cut -d'"' -f4 || true); do
      api DELETE "/repos/$ORG/$REPO/push_mirrors/$name" >/dev/null
      [[ "$(status)" == 204 ]] || warn "could not remove the older push mirror $name (HTTP $(status))"
    done
    api POST "/repos/$ORG/$REPO/push_mirrors" "{\"remote_address\":\"$OS_GIT_URL\",\"remote_username\":\"$(sed -n 1p "$OS_GIT_CREDS")\",\"remote_password\":\"$(sed -n 2p "$OS_GIT_CREDS")\",\"interval\":\"1h0m0s\",\"sync_on_commit\":true,\"branch_filter\":\"main\"}" >/dev/null
    expect "creating the push mirror to $OS_GIT_URL (a remote on a private address needs the forge's migrations.ALLOW_LOCALNETWORKS)" 200 201
    api POST "/repos/$ORG/$REPO/push_mirrors-sync" >/dev/null; expect "starting the first push to $OS_GIT_URL" 200 204
    ok "push mirror: main goes to $OS_GIT_URL on every commit"
  fi
  revoke_old "$BOT_OFFSITE" "bootstrap-$STAMP"   # only now that its Secret holds the new one
  CA_VOL=""; CA_MOUNT=""; CA_ENV=""
  if [[ -n "$OS_S3_CA" ]]; then
    kubectl "${K[@]}" -n "$FORGE_NS" create configmap "${RELEASE}-offsite-ca" --from-file=ca.crt="$OS_S3_CA" \
      --dry-run=client -o yaml | kubectl "${K[@]}" apply -f - >/dev/null
    CA_VOL="            - { name: ca, configMap: { name: ${RELEASE}-offsite-ca } }"
    CA_MOUNT="                - { name: ca, mountPath: /run/offsite-ca, readOnly: true }"
    CA_ENV="                - { name: S3_CA_FILE, value: /run/offsite-ca/ca.crt }"
  fi
  kubectl "${K[@]}" -n "$FORGE_NS" create configmap "${RELEASE}-offsite-script" \
    --from-file=forge-offsite-copy.sh="$OFFSITE_SCRIPT" --dry-run=client -o yaml \
    | kubectl "${K[@]}" apply -f - >/dev/null
  kubectl "${K[@]}" apply -f - >/dev/null <<CRON || die "could not apply the off-site CronJob"
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${RELEASE}-offsite
  namespace: ${FORGE_NS}
  labels:
    app.kubernetes.io/name: ${RELEASE}-offsite
    app.kubernetes.io/managed-by: tockmox-install
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 120
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 600
      ttlSecondsAfterFinished: 3600
      template:
        metadata:
          labels:
            app.kubernetes.io/name: ${RELEASE}-offsite
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          enableServiceLinks: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            # The Secret's files are root's; group 1000 with mode 0440 is what lets the
            # copy read them (measured: 0400 without fsGroup failed every run on the lab).
            fsGroup: 1000
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: copy
              image: ${IMAGE}
              command: [/bin/sh, /opt/offsite/forge-offsite-copy.sh]
              env:
${ENV_YAML}
${CA_ENV}
                - { name: FORGE_URL, value: "http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000" }
                - { name: REPO, value: "${ORG}/${REPO}" }
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: [ALL] }
              resources:
                requests: { cpu: 10m, memory: 32Mi }
                limits: { memory: 256Mi }
              volumeMounts:
                - { name: script, mountPath: /opt/offsite, readOnly: true }
                - { name: secrets, mountPath: /run/offsite, readOnly: true }
                - { name: tmp, mountPath: /tmp }
${CA_MOUNT}
          volumes:
            - { name: script, configMap: { name: ${RELEASE}-offsite-script } }
            - { name: secrets, secret: { secretName: ${RELEASE}-offsite, defaultMode: 0440 } }
            - { name: tmp, emptyDir: { sizeLimit: 1Gi } }
${CA_VOL}
CRON
  ok "CronJob ${FORGE_NS}/${RELEASE}-offsite: every minute, ${OFFSITE} to ${OFFSITE_WHERE}"
  # The first copy, now, while you watch: written AND read back, or this run fails.
  FIRST="${RELEASE}-offsite-first-$(date -u +%H%M%S)"; FIRST_OK=false
  for try in 1 2 3; do
    kubectl "${K[@]}" -n "$FORGE_NS" create job "$FIRST-$try" --from="cronjob/${RELEASE}-offsite" >/dev/null
    if kubectl "${K[@]}" -n "$FORGE_NS" wait --for=condition=complete "job/$FIRST-$try" --timeout=180s >/dev/null 2>&1; then
      ok "first off-site copy: $(kubectl "${K[@]}" -n "$FORGE_NS" logs "job/$FIRST-$try" 2>/dev/null | tail -1)"
      FIRST_OK=true; break
    fi
    FIRST_OK=false
    warn "off-site copy attempt $try did not succeed: $(kubectl "${K[@]}" -n "$FORGE_NS" logs "job/$FIRST-$try" 2>/dev/null | tail -2 | tr '\n' ' ')"
    # A push mirror pushes asynchronously; give it a moment before checking again.
    sleep 10
  done
  $FIRST_OK || die "the off-site copy could not be written and read back. The CronJob stays and retries every
       minute, and the console will alert; fix the destination and re-run this command.
       Look at: kubectl --context $CTX -n $FORGE_NS logs -l app.kubernetes.io/name=${RELEASE}-offsite --tail=20"
fi

# ---------------------------------------------------------------- recovery kit
say "The recovery kit"
POD="$(kubectl "${K[@]}" -n "$FORGE_NS" get pod -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "cannot find the forge's pod"
# Count, do not read: the check prints a number, never a secret.
NKEYS="$(kubectl "${K[@]}" -n "$FORGE_NS" exec "$POD" -c forgejo -- \
  grep -c -E '^(SECRET_KEY|INTERNAL_TOKEN) *=' /data/gitea/conf/app.ini 2>/dev/null || true)"
[[ "${NKEYS:-0}" -ge 1 ]] || die "the forge's app.ini carries neither SECRET_KEY nor INTERNAL_TOKEN; refusing to write a kit that cannot restore"
encrypt() {
  case "$ENC" in
    age) age -r "$AGE_RECIPIENT" ;;
    openssl) openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -salt -pass "file:$PASSFILE" ;;
  esac
}
# ONE stream, from the cluster and from memory straight into the encryption. Format:
# the header of this file. pipefail makes a failed `exec` fail the whole write.
kit_stream() {
  printf '%s\n' "$KIT_MARKER"
  printf 'created: %s\n' "$STAMP"
  printf 'site: %s\n' "$(basename "$SITE")"
  printf 'repository: %s\n' "$REPO_URL"
  printf 'forge: release %s, namespace %s, chart %s %s\n' "$RELEASE" "$FORGE_NS" "$CHART_REF" "$CHART_VERSION"
  printf 'site main at kit time: %s\n' "$LOCAL_HEAD"
  if [[ -n "$OFFSITE" ]]; then printf 'off-site copy: %s %s (its credentials are NOT in this kit)\n' "$OFFSITE" "$OFFSITE_WHERE"
  else printf 'off-site copy: none\n'; fi
  printf 'sealing-key backup: %s\n' "$([[ -n "$SEAL_BACKUP" ]] && echo included || echo 'NOT included (--no-sealing-key-backup)')"
  printf '=== app.ini\n'
  kubectl "${K[@]}" -n "$FORGE_NS" exec "$POD" -c forgejo -- cat /data/gitea/conf/app.ini
  printf '=== forge-admin\n%s\n%s\n' "$ADMIN_USER" "$ADMIN_PASS"
  if [[ -n "$SEAL_BACKUP" ]]; then
    printf '=== sealed-secrets.key.enc (base64)\n'
    base64 < "$SEAL_BACKUP"
  fi
  printf '=== end\n'
}
umask 077
kit_stream | encrypt > "$KIT_OUT" || { rm -f "$KIT_OUT"; die "writing the recovery kit failed"; }
[[ -s "$KIT_OUT" ]] || die "the recovery kit is empty"
if [[ "$ENC" == openssl ]]; then
  # Prove it opens, and that the passphrase is what opens it.
  # Prove it opens with the passphrase, starts with the marker and was not cut short.
  KIT_CHECK="$(openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -pass "file:$PASSFILE" < "$KIT_OUT" 2>/dev/null \
    | awk -v m="$KIT_MARKER" 'NR==1 && $0==m {h=1} /^=== app\.ini$/ {a=1} /^=== end$/ {e=1} END {print (h&&a&&e) ? "whole" : "broken"}')" || KIT_CHECK=broken
  [[ "$KIT_CHECK" == whole ]] || { rm -f "$KIT_OUT"; die "the recovery kit does not open whole with the passphrase it was written with"; }
  ok "recovery kit written and opened again with its passphrase: $KIT_OUT"
else
  ok "recovery kit written (age, to $AGE_RECIPIENT): $KIT_OUT"
  info "open it once with your age identity to prove it: age -d -i IDENTITY $KIT_OUT | grep '^=== '"
fi
[[ -n "$SEAL_BACKUP" ]] || warn "the kit does NOT carry your sealing-key backup (--no-sealing-key-backup). A rebuild needs both."

# ---------------------------------------------------------------- sign-in
SIGNED_IN=false
if $SIGN_IN; then
  say "Sign-in"
  # On a fresh install Authentik does not exist yet, so this is expected to wait; on a
  # re-run against a finished install it connects, and nothing else is needed.
  if connect_sign_in; then SIGNED_IN=true
  else info "that is expected before the layers are applied; finish with --connect-sign-in (below)"; fi
fi

# ---------------------------------------------------------------- done
say "Done"
ok "the built-in forge holds ${ORG}/${REPO}; ArgoCD reads it at ${REPO_URL}"
if [[ -n "$OFFSITE" ]]; then
  ok "off-site copy: ${OFFSITE} to ${OFFSITE_WHERE}, checked every minute; the console alerts after 15 minutes behind"
else
  warn "no off-site copy is set: until one is, losing this cluster loses the site's history, and the
       console says so (No off-site copy) until you add one: re-run with --offsite-s3-* or --offsite-git."
fi
info "next: kubectl --context $CTX apply -f $SITE/bootstrap/root.yaml"
if $SIGN_IN && ! $SIGNED_IN; then
  info "then, once tockmox-identity is Synced and Healthy, connect the forge's sign-in:"
  info "  $HERE/tockmox-install.sh bootstrap-forge --site $SITE --context $CTX --connect-sign-in"
fi
info "keep the recovery kit somewhere that is not this cluster and not any off-site bucket"

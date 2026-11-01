#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# Tockmox built-in forge bootstrap (TM-1335)
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
#      and two machine users: `tockmox-argocd` (read) and `tockmox-changes`
#      (opens changes, cannot approve them)
#   4. push the site directory to it as `main`
#   5. protect `main`: no direct pushes, one approval from the `approvers` team
#      (TM-1336 maps the console's admin group onto that team). The forge's ADMIN
#      can still force-merge past the rule: Forgejo 15 has no admin-override block
#      (measured 2026-10-31 on 15.0.11; the Gitea field is silently ignored). That
#      is the detect-not-prevent boundary the spec states, and why no service but
#      this installer holds the admin credential.
#   6. give ArgoCD its read credential as a repository Secret, and the console's
#      change identity as a Secret in the forge namespace
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
# WHAT THIS DOES NOT DO (yet, each its own card): the off-site copy after every
# merge (TM-1337); rebuild and forge repair (TM-1338); Authentik sign-in and the
# approvers mapping (TM-1336); upgrades (TM-1342). Proven on one single-node k3s
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
APPROVERS_TEAM="approvers"
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

 Forge
  --namespace NS         default ${FORGE_NS_DEFAULT} (the in-cluster address names it;
                         change it only if you also change every Application)
  --chart REF            default ${CHART_REF_DEFAULT} (a path or .tgz for a mirror)
  --chart-version V      default ${CHART_VERSION_DEFAULT}
  --image-registry R     registry prefix for the forge image (a mirror)
  --storage-class SC     for the forge's volume (default: the cluster default)
  --argocd-namespace NS  default argocd
  --ai-namespace NS      where tockmox-actions and the model watcher run (default tockmox-ai)
  --wait-seconds N       how long to wait for the forge (default 300)

  --dry-run              show the plan; change nothing
  -h, --help             this
USAGE
}

# ---------------------------------------------------------------- arguments
SITE=""; CONTEXT=""; CONTEXT_GIVEN=false; YES_CONTEXT=""; YES_SERVER=""; NO_PROMPT=false
KIT_OUT=""; AGE_RECIPIENT=""; PASSFILE=""; SEAL_BACKUP=""; NO_SEAL_BACKUP=false
FORGE_NS="$FORGE_NS_DEFAULT"; CHART_REF="$CHART_REF_DEFAULT"; CHART_VERSION="$CHART_VERSION_DEFAULT"
IMAGE_REGISTRY=""; STORAGE_CLASS=""; ARGO_NS="argocd"; AI_NS="tockmox-ai"; WAIT_SECONDS=300; DRY_RUN=false

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
    --wait-seconds) WAIT_SECONDS="${2:?--wait-seconds needs a number}"; shift 2 ;;
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

# ---- the kit: choose the encryption BEFORE anything is created
ENC=""
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
info "kit         ${KIT_OUT} (${ENC})"
if $DRY_RUN; then
  say "Plan (dry run, nothing changed)"
  info "install or adopt the forge; fence its port to ArgoCD (${ARGO_NS}), the AI layer (${AI_NS}) and its own namespace"
  info "create ${ORG}/${REPO}, ${BOT_READ}, ${BOT_CHANGE}, team ${APPROVERS_TEAM}"
  info "push ${SITE} as main; protect main; write the ArgoCD repository Secret in ${ARGO_NS}"
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
say "The forge"
if helm --kube-context "$CTX" -n "$FORGE_NS" status "$RELEASE" >/dev/null 2>&1; then
  ok "release ${RELEASE} already installed in ${FORGE_NS}; adopting it (no reinstall)"
  ADMIN_USER="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
  ADMIN_PASS="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || die "release ${RELEASE} exists but its admin Secret ${RELEASE}-admin does not.
       It was not installed by this script. Refusing to guess at a forge it did not create."
else
  kubectl "${K[@]}" get namespace "$FORGE_NS" >/dev/null 2>&1 \
    || kubectl "${K[@]}" create namespace "$FORGE_NS" >/dev/null
  ADMIN_USER="tockmox-admin"; ADMIN_PASS="$(gen 32)"
  # The admin credential lives in ONE Secret the chart reads (gitea.admin.existingSecret).
  secret_apply "$FORGE_NS" "${RELEASE}-admin" "" username="$ADMIN_USER" password="$ADMIN_PASS"
  # No secret in this file: the admin password comes from the Secret above, and the
  # forge generates its own SECRET_KEY and tokens on first start (the kit exports them).
  cat > "$TMPD/values.yaml" <<VALUES
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
ingress:
  enabled: false
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
      ROOT_URL: http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000/
      DOMAIN: ${RELEASE}-http.${FORGE_NS}.svc.cluster.local
      DISABLE_SSH: true
      START_SSH_SERVER: false
      OFFLINE_MODE: true
    repository:
      DEFAULT_BRANCH: main
      DEFAULT_PRIVATE: private
      ENABLE_PUSH_CREATE_USER: false
      ENABLE_PUSH_CREATE_ORG: false
    service:
      DISABLE_REGISTRATION: true
      REQUIRE_SIGNIN_VIEW: true
      DEFAULT_ALLOW_CREATE_ORGANIZATION: false
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
  info "installing chart ${CHART_REF} ${CHART_VERSION} (this pulls the forge image)"
  helm --kube-context "$CTX" upgrade --install "$RELEASE" "$CHART_REF" --version "$CHART_VERSION" \
    -n "$FORGE_NS" -f "$TMPD/values.yaml" --wait --timeout "${WAIT_SECONDS}s" >/dev/null \
    || die "helm install of the forge failed or did not become ready within ${WAIT_SECONDS}s.
       Look at: kubectl --context $CTX -n $FORGE_NS get pods,events"
  ok "forge installed: release ${RELEASE} in ${FORGE_NS}"
fi
kubectl "${K[@]}" -n "$FORGE_NS" rollout status deploy/"$RELEASE" --timeout="${WAIT_SECONDS}s" >/dev/null \
  || die "the forge did not become ready within ${WAIT_SECONDS}s"

# The fence. Applied on every run, so an adopted forge gets it too. Ingress only:
# the forge makes no outbound call of its own (OFFLINE_MODE; the off-site copy's
# egress is TM-1337's). Pods are named by label AND namespace, so a pod that copies
# a label in some other namespace gets nothing. Measured 2026-11-01 on a lab cluster
# (k3s, kube-router): a repo-server-labelled pod in the ArgoCD namespace and a pod
# in the forge namespace connect; an unlabelled pod there and a repo-server-
# labelled pod in `default` are refused; the forge's own probes keep it Ready. A
# pod that has just started can be refused for its first ~10 s while kube-router
# adds it to the policy's sets; ArgoCD retries.
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
      ports:
        - { port: 3000, protocol: TCP }
NETPOL
ok "forge fenced: port 3000 admits ArgoCD's repo-server, tockmox-actions, the model watcher and ${FORGE_NS}'s own pods"

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
mkteam readers read "$BOT_READ"
mkteam changes write "$BOT_CHANGE"
mkteam "$APPROVERS_TEAM" write

# Tokens, minted as the user they belong to, through the admin's sudo. A fresh name
# per run, so a re-run never fails on a name collision and never reuses a token.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mktoken() {  # user scope...
  local u="$1"; shift
  local scopes; scopes="$(printf '"%s",' "$@")"; scopes="[${scopes%,}]"
  local body
  body="$(SUDO_AS="$u" api POST "/users/$u/tokens" "{\"name\":\"bootstrap-$STAMP\",\"scopes\":$scopes}")"
  expect "minting a token for $u" 201
  printf '%s' "$body" | json_field sha1
}
# A re-run mints fresh tokens and then revokes this script's older ones, so tokens
# never pile up and the one ArgoCD holds is always the newest. Only names this
# script writes (bootstrap-<stamp>) are touched; a token someone made by hand stays.
revoke_old() {  # user keep-name
  local u="$1" keep="$2" n
  local names
  names="$(SUDO_AS="$u" api GET "/users/$u/tokens" | grep -o '"name":"bootstrap-[0-9TZ]*"' | cut -d'"' -f4 || true)"
  for n in $names; do
    [[ "$n" == "$keep" ]] && continue
    SUDO_AS="$u" api DELETE "/users/$u/tokens/$n" >/dev/null
    [[ "$(status)" == 204 ]] || warn "could not revoke $u's older token $n (HTTP $(status)); revoke it in the forge"
  done
}
TOKEN_READ="$(mktoken "$BOT_READ" read:repository)"
TOKEN_CHANGE="$(mktoken "$BOT_CHANGE" write:repository write:issue)"
[[ -n "$TOKEN_READ" && -n "$TOKEN_CHANGE" ]] || die "a token came back empty"
ok "tokens minted for $BOT_READ (read:repository) and $BOT_CHANGE (write:repository, write:issue)"
revoke_old "$BOT_READ" "bootstrap-$STAMP"
revoke_old "$BOT_CHANGE" "bootstrap-$STAMP"

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
info "nobody is in $APPROVERS_TEAM yet; the console's admin group is mapped onto it at sign-in (TM-1336)"

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

# ---------------------------------------------------------------- done
say "Done"
ok "the built-in forge holds ${ORG}/${REPO}; ArgoCD reads it at ${REPO_URL}"
warn "no off-site copy is set yet: until one is, losing this cluster loses the site's history.
       Until then, keep a clone of the site repository somewhere that is not this cluster."
info "next: kubectl --context $CTX apply -f $SITE/bootstrap/root.yaml"
info "keep the recovery kit somewhere that is not this cluster and not any off-site bucket"

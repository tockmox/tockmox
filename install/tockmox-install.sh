#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# Tockmox installer
#
#   ./install/tockmox-install.sh                       interactive
#   ./install/tockmox-install.sh --config tockmox.yaml non-interactive
#   ./install/tockmox-install.sh --config f --dry-run  validate, change nothing
#   ./install/tockmox-install.sh bootstrap-secrets ... the ONE cluster-writing step
#   ./install/tockmox-install.sh publish-docs ...      after the platform layer is Healthy:
#                                                      build the docs and upload them
#
# Generates a site repository from your answers. It does not apply anything:
# the Applications it writes point at a git repository only you can create, so
# there is nothing this script could usefully apply on your behalf. The README
# and the walkthrough both say so; the flags used to say otherwise (TM-0271).
#
# THE EXCEPTION IS A SUBCOMMAND, NOT A FLAG (TM-0277). `bootstrap-secrets`
# installs or reuses the sealed-secrets controller, exports its key encrypted,
# and seals the site's credentials. It writes to a cluster, so it lives in its
# own file (install/bootstrap-secrets.sh), must be named to be run, and shows
# the kube context and makes you confirm it. Nothing in THIS file's own
# behaviour changed: run without the subcommand it still applies nothing.
#
# Deliberately bash: a bootstrap installer that first requires you to install a
# runtime is a worse bootstrap installer. Needs kubectl only for the cluster
# preflight, which is skipped when there is no cluster to check against.
# ============================================================================
set -euo pipefail

# MUST MATCH charts/tockmox-common/Chart.yaml. This is the fifth edit of the
# version bump and it was missing from the list until 2026-09-01, so it read
# 0.1.0 through two releases: every generated site file was stamped with a
# version that had never existed, and the revision prompt below offered
# "v0.1.0" as its default, which no remote could resolve (TM-0269). CI now
# compares the two, because a checklist is not a mechanism.
VERSION="0.8.2"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF/.." && pwd)"

# NO_CLUSTER was called APPLY until 2026-09-01, initialised true, and set false
# by a --no-apply flag. That named a decision this script does not make: it has
# never applied anything, so "do not apply" was switching off something that was
# never on. What the flag actually does is skip the cluster preflight, which is
# what it is now called (TM-0271).
CONFIG=""; DRY_RUN=false; NO_CLUSTER=false; FORCE=false; CONTEXT=""

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
Tockmox installer v${VERSION}

Generates your site repository and stops. It applies nothing to your cluster:
the Applications it writes point at a git repository only you can create.

One subcommand DOES write to a cluster, and only when you name it:

  bootstrap-secrets  install or reuse the sealed-secrets controller, export its
                     key encrypted, and seal your credentials into the site.
                     Run '$0 bootstrap-secrets --help'.
  publish-docs       AFTER the platform layer is Healthy: build the product docs
                     from this checkout and upload them to the docs bucket
                     (tools/publish-docs.sh, which takes the same arguments:
                     --context CTX --config FILE [--wait SECONDS]). Needs the
                     pinned documentation generator; without it this warns, skips
                     and prints the commands. The install does not depend on it.

  --config FILE     read settings from FILE instead of prompting
  --dry-run         validate and render; write and change nothing
  --force           write into a site directory that already has files in it
                    (without it the installer refuses: a second run rewrites
                    every generated file, including the ones you edited)
  --no-cluster      skip the cluster preflight (no kubectl, or no cluster yet)
  --context NAME    kubectl context for the preflight (default: current)
  --lint DIR        check an EXISTING site's values files and exit
  --print-netpol-node-sources
                    print the policy-layer values block that narrows the
                    platform namespace's node-network rule (needs kubectl and a
                    reachable cluster); prints only, writes nothing, then exits
  -h, --help        this

Examples
  $0
  $0 --config tockmox.yaml
  $0 --config tockmox.yaml --dry-run
  $0 --config tockmox.yaml --no-cluster
  $0 --lint ./tockmox-site
  $0 --print-netpol-node-sources [--context NAME]
USAGE
}

# ------------------------------------------------------------------- site lint
# Two edits to a generated site are silent, and both were made by real people
# on real installs rather than imagined here.
#
# 1. A DUPLICATE top-level key. YAML keeps the LAST occurrence and discards the
#    earlier one with no error. On 2026-08-15 an appended "open-webui:" block
#    made the original vanish and re-enabled Pipelines; rendered PVCs went from
#    ten to three and helm lint reported 9 of 9 clean. The tree has had
#    tools/check-values-duplicate-keys.sh for this ever since ... but that gate
#    scans charts/*/values.yaml, and a SITE is the file operators actually edit.
#    Repeated on 2026-09-11 while configuring a test install.
#
# 2. A NULL top-level key ... "apps:" with nothing but comments under it, which
#    is what you get by commenting out your own edit. That is not "leave the
#    defaults alone": YAML null DELETES the key, so the layer's entire switch
#    map goes. Measured 2026-09-11 across all nine layers: platform,
#    observability, policy and selfcheck then fail to render (loud, at least),
#    and tockmox-ai renders CLEANLY with every app fallen through to its
#    capability tier ... which at the time enabled the model gateway (it shipped
#    off until 0.8.0, TM-0460) with zero NetworkPolicies over its PostgreSQL
#    database, and today silently undoes any component the site turned off.
#    Every layer reports Synced and Healthy.
#
# Runs on a directory, needs no cluster, and is safe to run any time.
site_lint() {
  local dir="${1:?--lint needs a site directory}"
  local vdir="$dir"
  [[ -d "$dir/site/values" ]] && vdir="$dir/site/values"
  [[ -d "$vdir" ]] || die "--lint: no such directory: $vdir"
  command -v python3 >/dev/null 2>&1 || die "--lint needs python3"

  python3 - "$vdir" <<'PY'
import sys, os, re, glob

vdir = sys.argv[1]
files = sorted(glob.glob(os.path.join(vdir, '*.yaml')) + glob.glob(os.path.join(vdir, '*.yml')))
if not files:
    print(f"lint: no values files found under {vdir}")
    sys.exit(1)

# Top-level keys only: column 0, not inside a block scalar, not a list item.
KEY = re.compile(r'^([A-Za-z0-9_.-]+):(.*)$')
problems = []

for path in files:
    seen = {}
    with open(path) as fh:
        lines = fh.read().split('\n')
    for i, line in enumerate(lines, 1):
        m = KEY.match(line)
        if not m:
            continue
        key, rest = m.group(1), m.group(2)
        if key in seen:
            problems.append(
                (path, i, f'DUPLICATE top-level key "{key}" (first seen line {seen[key]}). '
                          f'YAML keeps this one and SILENTLY DISCARDS the earlier block.'))
        else:
            seen[key] = i
        # Null-valued key: nothing after the colon, and nothing indented under
        # it before the next top-level key or EOF.
        if rest.strip() and not rest.strip().startswith('#'):
            continue
        has_child = False
        for nxt in lines[i:]:
            if not nxt.strip() or nxt.lstrip().startswith('#'):
                continue
            if nxt[:1] in (' ', '\t'):
                has_child = True
            break
        if not has_child:
            problems.append(
                (path, i, f'NULL top-level key "{key}" ... nothing is indented under it. '
                          f'This DELETES the key rather than leaving it at defaults. '
                          f'Write "{key}: ' + '{}" if you meant "no overrides".'))

# CROSS-LAYER: every namespace the platform layer hands Garage credentials to must
# also be admitted to Garage's S3 port by the policy layer (TM-1032). The two keys
# live in different layers' files, so neither chart can see the other's value.
# 0.8.0 requires platformNetpol.nodeOriginSources, which drops the 0.7.x rule that
# admitted the whole pod network; from then on the S3 port admits only
# namespaces.ai, namespaces.authentik and platformNetpol.extraS3ClientNamespaces.
# A site namespace that backs up to Garage and is in none of them loses its
# backups silently: the database reads healthy, only ContinuousArchiving goes
# False. Measured on the 0.8.0-rc1 greenfield (news/miniflux-db).
def block_value(path, dotted):
    """Value text and following lines for a dotted key; stdlib only, like the
    checks above. Returns None when the key is absent."""
    try:
        with open(path) as fh:
            lines = fh.read().split('\n')
    except OSError:
        return None
    want = dotted.split('.')
    stack = []
    for i, raw in enumerate(lines):
        line = re.sub(r'\s+#.*$', '', raw)
        if not line.strip() or line.lstrip().startswith('#') or line.lstrip().startswith('- '):
            continue
        m = re.match(r'^(\s*)([A-Za-z0-9_.-]+):(.*)$', line)
        if not m:
            continue
        ind = len(m.group(1))
        while stack and stack[-1][0] >= ind:
            stack.pop()
        stack.append((ind, m.group(2)))
        if [k for _, k in stack] == want:
            rest = m.group(3).strip()
            if rest:
                return rest, []
            body = []
            for nxt in lines[i + 1:]:
                n = re.sub(r'\s+#.*$', '', nxt)
                if not n.strip() or n.lstrip().startswith('#'):
                    continue
                if len(n) - len(n.lstrip()) <= ind and not n.lstrip().startswith('- '):
                    break
                if len(n) - len(n.lstrip()) < ind:
                    break
                body.append(n)
            return '', body
    return None

def as_list(v):
    if v is None:
        return None
    rest, body = v
    unq = lambda x: x.strip().strip('"').strip("'")
    if rest.startswith('['):
        inner = rest.strip('[]').strip()
        return [unq(x) for x in inner.split(',') if unq(x)]
    if rest in ('', '[]'):
        return [unq(b.lstrip()[2:]) for b in body if b.lstrip().startswith('- ')]
    return [unq(rest)]

def as_scalar(v, default):
    if v is None or not v[0]:
        return default
    return v[0].strip().strip('"').strip("'")

plat = os.path.join(vdir, 'platform.yaml')
pol = os.path.join(vdir, 'policy.yaml')
creds = as_list(block_value(plat, 'garage.credentialsNamespaces'))
if creds:
    ns_ai = as_scalar(block_value(pol, 'namespaces.ai'), 'tockmox-ai')
    ns_auth = as_scalar(block_value(pol, 'namespaces.authentik'), 'tockmox-authentik')
    extra = as_list(block_value(pol, 'platformNetpol.extraS3ClientNamespaces')) or []
    s3_off = as_scalar(block_value(pol, 'apps.platform_netpol.enabled'), 'true') == 'false'
    missing = [n for n in creds if n not in (ns_ai, ns_auth) and n not in extra]
    if missing and not s3_off:
        problems.append(
            (plat, 0, 'garage.credentialsNamespaces names ' + ', '.join(missing) +
                      ', which policy.yaml does not admit to the object store\'s S3 port. '
                      'Add ' + ('it' if len(missing) == 1 else 'them') +
                      ' to platformNetpol.extraS3ClientNamespaces in site/values/policy.yaml, '
                      'or the database there loses its backups silently once '
                      'platformNetpol.nodeOriginSources is set (required from 0.8.0): '
                      'the Cluster reads healthy and only ContinuousArchiving goes False.'))

if problems:
    print("SITE VALUES LINT: problems found\n")
    for path, line, msg in problems:
        print(f"  {os.path.basename(path)}" + (f":{line}" if line else ""))
        print(f"    {msg}\n")
    print("None of these produces a YAML error, a helm lint failure, or an")
    print("ArgoCD OutOfSync. Each changes what your cluster runs.")
    sys.exit(1)

print(f"  site values lint: {len(files)} file(s) clean (no duplicate or null top-level keys; "
      f"every credentials namespace admitted to S3)")
PY
}

# ------------------------------------------------- netpol node sources (TM-0273)
# PRINTS the values block for platformNetpol.nodeOriginSources. It never writes
# it anywhere: the list is a security decision and a site file is the operator's.
#
# For each node, take its IPv4 podCIDR and emit <network>/31, which covers the
# two addresses a node-originated packet carries when delivered to a pod on
# flannel (k3s default): the cni0 gateway (network + 1) for a pod on the same
# node, and the flannel.1 address (network + 0) for a packet that crossed nodes.
# That is INFERRED from how flannel numbers a node's subnet, not measured on this
# cluster: check `ip -4 addr show cni0 flannel.1` on one node before applying.
# A node added later is not in the printed list; re-run this and update the site.
print_netpol_node_sources() {
  command -v kubectl >/dev/null 2>&1 || die "--print-netpol-node-sources needs kubectl"
  command -v python3 >/dev/null 2>&1 || die "--print-netpol-node-sources needs python3"
  local kc=(kubectl); [[ -n "$CONTEXT" ]] && kc=(kubectl --context "$CONTEXT")
  local json
  json="$("${kc[@]}" get nodes -o json)" || die "could not read nodes (is the cluster reachable?)"
  printf '%s' "$json" | python3 -c '
import sys, json, ipaddress
nodes = json.load(sys.stdin)["items"]
rows, missing = [], []
for n in nodes:
    name = n["metadata"]["name"]
    cidrs = n.get("spec", {}).get("podCIDRs") or ([n["spec"]["podCIDR"]] if n.get("spec", {}).get("podCIDR") else [])
    v4 = [c for c in cidrs if ipaddress.ip_network(c, strict=False).version == 4]
    if not v4:
        missing.append(name); continue
    for c in v4:
        net = ipaddress.ip_network(c, strict=False)
        rows.append((name, c, "%s/31" % net.network_address))
if missing:
    sys.stderr.write("no IPv4 podCIDR on node(s): %s (does this CNI allocate podCIDRs? this helper is for flannel)\n" % ", ".join(missing))
    sys.exit(1)
print("# Generated by tockmox-install.sh --print-netpol-node-sources. Review, then put in policy.yaml.")
print("# One /31 per node: its flannel.1 and cni0 addresses. Re-run when a node is added.")
print("platformNetpol:")
print("  nodeOriginSources:")
for name, c, blk in rows:
    print("    - %s   # %s (podCIDR %s)" % (blk, name, c))
'
}

# Subcommands, before the generator's own flags. exec, so the cluster-writing code
# is a different program with its own flags rather than a mode of this one.
if [[ "${1:-}" == "bootstrap-secrets" ]]; then
  shift
  exec bash "$SELF/bootstrap-secrets.sh" "$@"
fi

# publish-docs is the install's last step (TM-0807), and it is a subcommand for the
# same reason bootstrap-secrets is: this script applies nothing and waits for
# nothing, so there is no moment inside it at which the platform layer is Healthy.
# The operator runs it once that is true. It reads nothing secret to this machine
# (tools/publish-docs.sh says how). The documentation is a convenience, so a
# missing generator (exit 2) is a warning and never a failed install; a real
# failure still exits non-zero so it is not mistaken for success.
if [[ "${1:-}" == "publish-docs" ]]; then
  shift
  rc=0
  bash "$REPO_ROOT/tools/publish-docs.sh" "$@" || rc=$?
  case "$rc" in
    0) exit 0 ;;
    2) warn "docs not published: the pinned documentation generator is absent. Your install is not affected; the docs site shows its placeholder page until you run the commands above."
       exit 0 ;;
    *) err "publishing the docs failed (exit $rc). Your install is not affected; fix the cause above and run this again."
       exit "$rc" ;;
  esac
fi

PRINT_NODE_SOURCES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --no-cluster) NO_CLUSTER=true; shift ;;
    # Accepted, undocumented, and not an error: --no-apply is what this flag
    # was called through 0.5.0, and it appears in notes and transcripts that
    # outlive the rename. Breaking it would punish someone for having read
    # older material accurately.
    --no-apply) NO_CLUSTER=true; shift ;;
    --context) CONTEXT="${2:?--context needs a name}"; shift 2 ;;
    # Terminal: lints an existing site and exits without generating anything.
    --lint) site_lint "${2:?--lint needs a site directory}"; exit $? ;;
    --print-netpol-node-sources) PRINT_NODE_SOURCES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

# Terminal, and after the loop so --context can come on either side of it.
if $PRINT_NODE_SOURCES; then print_netpol_node_sources; exit $?; fi

KUBECTL=(kubectl); [[ -n "$CONTEXT" ]] && KUBECTL=(kubectl --context "$CONTEXT")

# ---------------------------------------------------------------- yaml reading
# Minimal dotted-path reader. Avoids a yq dependency for a handful of scalars.
# Handles: nested maps, quoted and bare scalars, comments, blank lines.
yget() {
  local path="$1" file="$2"
  awk -v want="$path" '
    function emit(v){ gsub(/^[ \t]+|[ \t]+$/,"",v)
                      gsub(/^"|"$/,"",v); gsub(/^'"'"'|'"'"'$/,"",v)
                      print v; found=1; exit }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    {
      line=$0; sub(/[ \t]+#.*$/,"",line)
      match(line,/^[ \t]*/); ind=RLENGTH
      lvl=int(ind/2)
      if (match(line,/^[ \t]*[A-Za-z0-9_.-]+:/)) {
        key=substr(line,ind+1,RLENGTH-ind-1)
        stack[lvl]=key
        full=""; for(i=0;i<=lvl;i++) full=(full=="")?stack[i]:full"."stack[i]
        rest=substr(line,RLENGTH+1)
        if (full==want && rest ~ /[^ \t]/) emit(rest)
      }
    }
    END { if(!found) print "" }
  ' "$file"
}

need() {  # value, human name
  [[ -n "${1// }" ]] || die "required setting missing: $2"
}

# ---------------------------------------------------------------- gather
declare SITE_NAME SITE_PATH TM_REV TM_REPO
declare G_INT G_ISSUER G_LAN G_CLUSTER G_SVC G_TZ G_REG G_SC G_LSC
declare ARGO_NS ARGO_AUTO ARGO_HEAL
declare -a LAYERS_ON=()
ALL_LAYERS=(crds policy platform observability exporters identity devops ai selfcheck)

# THE STORAGE CONTRACT NEEDS BOTH CLASSES NAMED, and this file is where a site
# says so. Leaving either empty falls through to whatever the cluster's default
# StorageClass happens to be, which is the failure docs/administration/storage.md
# exists to remove: Tockmox once shipped Longhorn and wrote every volume to
# local-path anyway, because nothing named a class.
#
# `longhorn` is the right default only when this install ships Longhorn. With
# the platform layer off you are bringing your own CSI and we must not guess.
#
# A FUNCTION, not an inline `case`, because both callers need it and they run at
# different times: the interactive branch needs it to offer a prompt default,
# and the config branch needs it after reading `layers.*`. It was inline and
# positioned after BOTH, so the interactive prompt on line 196 read an unset
# variable, `set -u` fired, and every interactive run died at the twelfth
# question ... after eleven answers ... with `DEF_SC: unbound variable` and no
# site repository. Counted off a driven run, because the first draft of this
# comment said nine from memory and was wrong. The
# `--config` route was unaffected, which is why it survived: every proof run
# this project has ever made used a config file. Gated by tests/installer.
default_storage_class() {
  case " ${LAYERS_ON[*]} " in
    *" platform "*) printf 'longhorn' ;;
    *)              printf '' ;;
  esac
}

# INTERACTIVE MODE NEEDS A TERMINAL, and says so instead of spinning.
#
# `read </dev/tty` is right ... it keeps prompts working when stdin is a pipe.
# But with no controlling terminal at all (CI, a container, `sh install.sh <
# answers`) the read fails instantly, the answer is empty, a required field
# rejects it, and the loop runs forever printing "required" with no way out but
# Ctrl-C. Checked once up front, and bounded per question as a backstop.
ask() {  # var, prompt, default, required
  local __var="$1" prompt="$2" def="${3:-}" req="${4:-false}" ans tries=0
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    die "interactive mode needs a terminal, and there is none here.
    Use a config file instead, which is repeatable and reviewable anyway:
      cp install/tockmox.yaml.example tockmox.yaml
      \$EDITOR tockmox.yaml
      $0 --config tockmox.yaml"
  fi
  exec 3<&-
  while true; do
    if [[ -n "$def" ]]; then printf '  %s%s%s [%s]: ' "$C" "$prompt" "$X" "$def"
    else printf '  %s%s%s: ' "$C" "$prompt" "$X"; fi
    read -r ans </dev/tty || true
    ans="${ans:-$def}"
    if [[ -z "$ans" && "$req" == true ]]; then
      err "required"
      (( ++tries >= 5 )) && die "no answer after 5 attempts for: $prompt"
      continue
    fi
    printf -v "$__var" '%s' "$ans"; return
  done
}

if [[ -n "$CONFIG" ]]; then
  [[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
  say "Reading $CONFIG"
  # `yget` is a line-oriented reader, so a FLOW mapping -- `site: {name: x}` --
  # is valid YAML it cannot see. Without this check the run died four steps
  # later on "required setting missing: site.name", which sends the reader to
  # look for a key that is right there in front of them. Measured 2026-09-13:
  # python yaml reads that file correctly, this installer does not, and the
  # error named the wrong problem. Say what is actually wrong instead.
  if grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*\{' "$CONFIG"; then
    die "config uses YAML flow mappings, which this reader does not support.
       Found: $(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*\{' "$CONFIG" | head -1)
       Write it in block style instead:
           site:
             name: my-site
       Your file is valid YAML; this reader is line-oriented and reads only
       block style. See install/README or tests/installer/fixtures/parity.yaml."
  fi
  SITE_NAME=$(yget site.name "$CONFIG");         SITE_PATH=$(yget site.path "$CONFIG")
  TM_REV=$(yget tockmox.revision "$CONFIG");     TM_REPO=$(yget tockmox.repoURL "$CONFIG")
  G_INT=$(yget global.internalDomain "$CONFIG"); G_ISSUER=$(yget global.certIssuer "$CONFIG")
  # TM-0497, 2026-09-11. A config file that OMITS certIssuer gets the shipped
  # default rather than "". Omission is not the same as `certIssuer: ""`, which
  # is a deliberate choice to serve plain HTTP and is honoured -- yget returns
  # empty for both, so the two cannot be told apart here, and the safe reading
  # of silence is the working one. The platform layer creates `tockmox-ca` on
  # every stock install; leaving it unnamed built the issuer and pointed nothing
  # at it, which is plain HTTP and broken SSO with every layer reporting green.
  [[ -z "${G_ISSUER// }" ]] && ! grep -qE '^[[:space:]]*certIssuer:' "$CONFIG" \
    && G_ISSUER="tockmox-ca"
  G_LAN=$(yget global.lanCIDR "$CONFIG");        G_CLUSTER=$(yget global.clusterCIDR "$CONFIG")
  G_SVC=$(yget global.serviceCIDR "$CONFIG");    G_TZ=$(yget global.timezone "$CONFIG")
  G_REG=$(yget global.imageRegistry "$CONFIG")
  G_SC=$(yget global.storageClass "$CONFIG");     G_LSC=$(yget global.localStorageClass "$CONFIG")
  ADDR_POOL=$(yget addressPool.range "$CONFIG")
  ARGO_NS=$(yget argocd.namespace "$CONFIG")
  ARGO_AUTO=$(yget argocd.autoSync "$CONFIG");   ARGO_HEAL=$(yget argocd.selfHeal "$CONFIG")
  for l in "${ALL_LAYERS[@]}"; do
    [[ "$(yget "layers.$l" "$CONFIG")" != "false" ]] && LAYERS_ON+=("$l")
  done
  # namespace overrides, for adopting into an existing cluster
  NS_OVERRIDES=""
  for k in ai monitoring platform traefik authentik forgejo harbor tailscale selfcheck devops; do
    v="$(yget "namespaces.$k" "$CONFIG")"
    [[ -n "$v" ]] && NS_OVERRIDES+="  ${k}: ${v}"$'\n'
  done
else
  say "Tockmox installer v${VERSION} ... interactive"
  info "Enter to accept the default in brackets. Ctrl-C to abort."
  info "Prefer a file? cp install/tockmox.yaml.example tockmox.yaml"
  printf '\n'
  # Interactive mode installs every layer. It does not offer the choice, so say
  # so here rather than leaving it implicit in an assignment further down: the
  # storage-class default below is derived from this, and an operator who wants
  # a subset needs the config file. Set BEFORE the prompts for that reason.
  LAYERS_ON=("${ALL_LAYERS[@]}")
  DEF_SC="$(default_storage_class)"
  ask SITE_NAME "Deployment name"                     ""              true
  ask SITE_PATH "Write site repo to"                  "./tockmox-site"
  ask TM_REV    "Tockmox release (a tag, not a branch)" "v${VERSION}"
  TM_REPO="https://github.com/tockmox/tockmox.git"
  printf '\n'
  ask G_INT     "Internal base domain (grafana.<this>)" ""            true
  ask G_ISSUER  "cert-manager issuer (blank = plain HTTP, no SSO)" "tockmox-ca"
  ask G_LAN     "LAN/node CIDR (admits off-cluster traffic)" ""       true
  ask ADDR_POOL "MetalLB range (inside that CIDR, outside DHCP)" ""   true
  ask G_CLUSTER "Pod CIDR"                              "10.42.0.0/16"
  ask G_SVC     "Service CIDR"                          "10.43.0.0/16"
  ask G_TZ      "Timezone"                              "UTC"
  ask G_REG     "Mirror registry (blank = upstream)"    ""
  ask G_SC      "StorageClass for data the volume must protect" "$DEF_SC"
  ask G_LSC     "StorageClass for data the app replicates or rebuilds" "local-path"
  printf '\n'
  ask ARGO_NS   "ArgoCD namespace"                      "argocd"
  ARGO_AUTO=true; ARGO_HEAL=true
fi

SITE_PATH="${SITE_PATH:-./tockmox-site}"; TM_REV="${TM_REV:-v$VERSION}"
TM_REPO="${TM_REPO:-https://github.com/tockmox/tockmox.git}"
G_CLUSTER="${G_CLUSTER:-10.42.0.0/16}"; G_SVC="${G_SVC:-10.43.0.0/16}"
# Reasoning for both classes is on default_storage_class() above.
G_SC="${G_SC:-$(default_storage_class)}"; G_LSC="${G_LSC:-local-path}"
G_TZ="${G_TZ:-UTC}"; ARGO_NS="${ARGO_NS:-argocd}"
ARGO_AUTO="${ARGO_AUTO:-true}"; ARGO_HEAL="${ARGO_HEAL:-true}"

# ---------------------------------------------------------------- validate
say "Validating"
need "$SITE_NAME" "site.name"
need "$G_INT"     "global.internalDomain"
need "$G_LAN"     "global.lanCIDR"
# MetalLB refuses to render without a pool, by design ... a LoadBalancer that
# stays Pending forever is a worse failure than a question.
need "$ADDR_POOL" "addressPool.range"
[[ "$SITE_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "site.name must be lowercase alphanumeric and hyphens: '$SITE_NAME'"
for cidr in "$G_LAN" "$G_CLUSTER" "$G_SVC"; do
  [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "not a CIDR: '$cidr'"
done
[[ "$G_INT" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "not a domain: '$G_INT'"
case "$TM_REV" in
  main|master|HEAD) warn "tracking '$TM_REV' means your cluster changes when upstream does. Fine for a lab." ;;
  v*) : ;;
  *) warn "'$TM_REV' does not look like a release tag." ;;
esac

# DOES THAT REVISION ACTUALLY EXIST? The shape check above only looks at the
# string. A revision that does not resolve is not caught until ArgoCD tries to
# fetch it, three phases and one `kubectl apply` later, and the error it gives
# then names neither this file nor this setting.
#
# It is a real trap rather than a hypothetical: the example config ships a
# release tag, and before the first release is cut that tag does not exist.
# Every Application would fail to resolve and the install would look broken
# rather than unreleased.
#
# Skipped without git or without network, because an air-gapped install
# legitimately cannot check, and refusing to proceed there would be worse than
# the problem.
if ! command -v git >/dev/null 2>&1; then
  warn "git not found ... cannot confirm '$TM_REV' exists in $TM_REPO"
elif ! git ls-remote --exit-code "$TM_REPO" >/dev/null 2>&1; then
  warn "cannot reach $TM_REPO ... not confirming '$TM_REV' exists (fine if you are air-gapped or mirroring)"
elif git ls-remote --exit-code "$TM_REPO" "$TM_REV" >/dev/null 2>&1; then
  ok "revision $TM_REV resolves in $TM_REPO"
else
  err "revision '$TM_REV' does not exist in $TM_REPO"
  info "ArgoCD would accept this file and then fail to resolve it on every layer."
  info "Available branches and tags:"
  git ls-remote --heads --tags "$TM_REPO" 2>/dev/null \
    | sed -E 's|.*refs/(heads\|tags)/|      |' | sort -u | head -20
  die "set tockmox.revision to one of the above"
fi
[[ -n "$G_SC"  ]] || warn "global.storageClass is empty: volumes fall through to the cluster default, which is what the storage contract exists to stop. See docs/administration/storage.md."
[[ -n "$G_LSC" ]] || warn "global.localStorageClass is empty: the metrics TSDB and log chunks get replicated storage they do not need."
ok "settings valid"

printf '\n'
info "site          ${SITE_NAME}"
info "release       ${TM_REV}"
info "internal      ${G_INT}"
info "lan           ${G_LAN}"
info "layers        ${LAYERS_ON[*]}"
info "site repo     ${SITE_PATH}"
[[ -n "$G_REG" ]] && info "registry      ${G_REG} (air-gapped)"

# ---------------------------------------------------------------- prereqs
#
# THESE CHECKS ARE ADVICE ABOUT THE CLUSTER, NOT INPUTS TO THE RENDER. Site
# generation below reads nothing from the cluster ... every value it writes
# comes from the config file. So both --dry-run and --no-cluster skip them.
#
# The escape exists because of TM-0247: preparing a site repo AHEAD of a
# cluster is the sensible order, and it used to be impossible. --dry-run
# skipped the checks but writes nothing, so no flag combination produced a
# site repository without a live cluster. The prerequisite was enforced for a
# step that does not need it.
#
# Note what is NOT relaxed: with a cluster reachable and --no-cluster unset,
# every check still runs and still dies on a missing argocd namespace or CRDs.
#
# THE ESCAPE SKIPS THE CHECKS OUTRIGHT, and that wording is the fix rather than
# a restatement. Until 2026-09-10 the flag only set a message string, and the
# checks were skipped only when kubectl was MISSING or the cluster UNREACHABLE.
# So `--no-cluster` on a workstation whose kubeconfig pointed at some other
# reachable cluster ran every check anyway and died on `namespace argocd not
# found`. That is the common case rather than an exotic one: a merged kubeconfig
# usually has a current context, and it is usually not the cluster you are about
# to build. The operator said there was nothing to check against and the script
# checked anyway, contradicting both --help and this paragraph. Reproduced with a
# stub kubectl; gated by tests/installer.
say "Checking prerequisites"
if $DRY_RUN; then   SKIP_CLUSTER=true; SKIP_FLAG="--dry-run"
elif $NO_CLUSTER; then SKIP_CLUSTER=true; SKIP_FLAG="--no-cluster"
else                SKIP_CLUSTER=false; SKIP_FLAG=""
fi
if $SKIP_CLUSTER; then
  warn "not checking the cluster (${SKIP_FLAG})"
  info "Site generation reads nothing from a cluster; every value it writes comes from your answers."
else
  command -v kubectl >/dev/null || die "kubectl not found"
  "${KUBECTL[@]}" version -o json >/dev/null 2>&1 || die "cannot reach a cluster. Check your context: kubectl config get-contexts
    Preparing a site repository ahead of the cluster is fine: use --no-cluster."
fi
if ! $SKIP_CLUSTER; then
ok "cluster reachable ... $("${KUBECTL[@]}" config current-context 2>/dev/null || echo '?')"

if "${KUBECTL[@]}" get ns "$ARGO_NS" >/dev/null 2>&1; then ok "namespace $ARGO_NS exists"
else die "namespace $ARGO_NS not found. Install ArgoCD first: docs/deployment/prerequisites.md"; fi

if "${KUBECTL[@]}" get crd applications.argoproj.io >/dev/null 2>&1; then ok "ArgoCD CRDs present"
else die "ArgoCD CRDs not found. Install ArgoCD first."; fi

if "${KUBECTL[@]}" get crd sealedsecrets.bitnami.com >/dev/null 2>&1; then ok "sealed-secrets present"
else warn "sealed-secrets not found. Required before any secret syncs; you can add it later."; fi

# PVCs bind to the cluster's DEFAULT StorageClass; without one they stay
# Pending forever with no obvious cause. Longhorn (platform layer) can be
# made the default via longhorn.persistence.defaultClass ... see
# docs/administration/configuration.md.
DEFAULT_SC=$("${KUBECTL[@]}" get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
case "$(echo "$DEFAULT_SC" | wc -w | tr -d ' ')" in
  0) warn "no default StorageClass on this cluster. PVCs will stay Pending until one exists." ;;
  1) ok "default StorageClass: ${DEFAULT_SC}"
     [[ "$DEFAULT_SC" == "local-path " || "$DEFAULT_SC" == "local-path" ]] && warn "local-path is node-local: a rescheduled pod loses its data. Fine to evaluate, wrong to rely on." ;;
  *) warn "MULTIPLE default StorageClasses (${DEFAULT_SC}). Which one wins is version-dependent; keep exactly one." ;;
esac
fi   # SKIP_CLUSTER

# ---------------------------------------------------------------- render
# A SECOND RUN OVER AN EXISTING SITE REWRITES IT, silently, from the config: the
# values files and every Application are regenerated, so a hand edit made after
# the first run is lost. Found by the 0.8.0 lab pass (TM-0902's L1): the policy
# layer's nodeOriginSources block, added by hand in install.md 1f, vanished when
# the installer was run again for a grep, and tockmox-policy went to
# ComparisonError. A directory with anything in it is the signal. --dry-run
# writes nothing, so it only says what a real run would do.
if [[ -d "$SITE_PATH" && -n "$(ls -A "$SITE_PATH" 2>/dev/null)" ]]; then
  if $DRY_RUN; then
    warn "$SITE_PATH already has files in it: a real run would refuse without --force."
  elif ! $FORCE; then
    die "$SITE_PATH already has files in it. Generating again rewrites every file the installer wrote, including the ones you have edited since (the policy layer's nodeOriginSources from install.md 1f, your site values). To change one setting, edit that file. To regenerate on purpose, pass --force, or point site.path at an empty directory."
  else
    warn "--force: regenerating into $SITE_PATH. Files you edited by hand are overwritten."
  fi
fi
say "Generating site repository"
if $DRY_RUN; then warn "dry-run: nothing will be written"; fi

mk() { $DRY_RUN || mkdir -p "$1"; }
wr() { local p="$1"; shift; if $DRY_RUN; then printf '    would write %s\n' "$p"; else cat > "$p"; fi; }

mk "$SITE_PATH/site/values"; mk "$SITE_PATH/apps"; mk "$SITE_PATH/secrets"; mk "$SITE_PATH/bootstrap"
# secrets/ IS EMPTY UNTIL mint-secrets.sh RUNS, and git does not carry empty
# directories. Without this file the directory vanishes on the first push and
# the site-secrets Application below reports a path that does not exist ...
# on a site that is, at that moment, entirely correct. .gitkeep is the cheapest
# thing that makes "the Application always has a path" true rather than true
# only after somebody mints a credential.
$DRY_RUN || : > "$SITE_PATH/secrets/.gitkeep"

if $DRY_RUN; then
  for f in README.md .gitignore site/values/global.yaml bootstrap/root.yaml bootstrap/applications/; do
    printf '    would write %s/%s\n' "$SITE_PATH" "$f"
  done
  for l in "${LAYERS_ON[@]}"; do printf '    would write %s/site/values/%s.yaml\n' "$SITE_PATH" "$l"; done
else
  # Emit "" for empties: a bare `key:` is YAML null, and the charts' JSON
  # schema requires strings. Caught by validating generated output against the
  # real chart rather than eyeballing it.
  q() { if [[ -z "${1// }" ]]; then printf '""'; else printf '%s' "$1"; fi; }
  wr "$SITE_PATH/site/values/global.yaml" <<EOF
# Generated by tockmox-install.sh v${VERSION} for site "${SITE_NAME}".
# Safe to edit. Read by every Tockmox layer chart.
global:
  internalDomain: $(q "${G_INT}")
  certIssuer: $(q "${G_ISSUER}")
  imageRegistry: $(q "${G_REG}")
  timezone: $(q "${G_TZ}")
  clusterCIDR: $(q "${G_CLUSTER}")
  serviceCIDR: $(q "${G_SVC}")
  lanCIDR: $(q "${G_LAN}")
  # Data whose only copy is the volume. See docs/administration/storage.md.
  storageClass: $(q "${G_SC}")
  # Data the application replicates itself, or can rebuild: the metrics TSDB,
  # log chunks, a Postgres cluster that is already streaming to its replicas.
  # Node-local by design. Do not point it at anything whose loss you would mind.
  localStorageClass: $(q "${G_LSC}")
EOF
  for l in "${LAYERS_ON[@]}"; do
    if [[ "$l" == "policy" && -n "${NS_OVERRIDES:-}" ]]; then
      wr "$SITE_PATH/site/values/${l}.yaml" <<EOF
# Overrides for tockmox-${l}. Globals are inherited from global.yaml.
# Namespace overrides below came from your config: you are adopting Tockmox
# into a cluster that already has these namespaces.
namespaces:
${NS_OVERRIDES}
# Feature switches. To enable something, replace the empty map on the last line
# of this block with your entries, indented under the key.
#
# This comment deliberately does NOT quote that line verbatim. It used to, and
# a scripted edit then matched the text inside this comment before the real
# key, splitting the comment and hoisting the entries to the top level. What
# ArgoCD reports for that is a schema error naming the KEY, which sends you
# looking for a chart bug rather than at the indentation. Cost an hour on
# 2026-09-11.
#
# Two ways to get this wrong, and neither reports an error:
#   - appending a SECOND "apps:" block lower down. YAML keeps only the LAST
#     occurrence of a top-level key and silently discards this one.
#   - leaving "apps:" with nothing under it. That is null, which DELETES this
#     layer's switch map rather than leaving it at defaults. Most layers then
#     fail to render; tockmox-ai instead falls every app through to its
#     capability tier and quietly undoes any component you turned off (until
#     0.8.0 that switched on the model gateway, which then shipped off, with
#     no NetworkPolicy over its database). Measured 2026-09-11.
#
# Both are checked by: ./install/tockmox-install.sh --lint <site path>
apps: {}
EOF
    elif [[ "$l" == "platform" ]]; then
      wr "$SITE_PATH/site/values/${l}.yaml" <<EOF
# Overrides for tockmox-${l}. Globals are inherited from global.yaml.
# Anything you set here wins.
# The MetalLB pool you chose. LoadBalancer IPs (Traefik first) come from here.
addressPool:
  range: ${ADDR_POOL}
# Feature switches. To enable something, replace the empty map on the last line
# of this block with your entries, indented under the key.
#
# This comment deliberately does NOT quote that line verbatim. It used to, and
# a scripted edit then matched the text inside this comment before the real
# key, splitting the comment and hoisting the entries to the top level. What
# ArgoCD reports for that is a schema error naming the KEY, which sends you
# looking for a chart bug rather than at the indentation. Cost an hour on
# 2026-09-11.
#
# Two ways to get this wrong, and neither reports an error:
#   - appending a SECOND "apps:" block lower down. YAML keeps only the LAST
#     occurrence of a top-level key and silently discards this one.
#   - leaving "apps:" with nothing under it. That is null, which DELETES this
#     layer's switch map rather than leaving it at defaults. Most layers then
#     fail to render; tockmox-ai instead falls every app through to its
#     capability tier and quietly undoes any component you turned off (until
#     0.8.0 that switched on the model gateway, which then shipped off, with
#     no NetworkPolicy over its database). Measured 2026-09-11.
#
# Both are checked by: ./install/tockmox-install.sh --lint <site path>
apps: {}
EOF
    elif [[ "$l" == "devops" ]]; then
      # Argo Workflows' upstream chart takes the OIDC issuer and redirect URL
      # as plain values it does not template, so the installer derives them
      # here ... the chart cannot. See the argo-workflows comment in the chart.
      SCHEME="http"; [[ -n "${G_ISSUER// }" ]] && SCHEME="https"
      wr "$SITE_PATH/site/values/${l}.yaml" <<EOF
# Overrides for tockmox-${l}. Globals are inherited from global.yaml.
# Anything you set here wins.
# The SSO endpoints below are derived from your internalDomain by the
# installer, because the upstream argo-workflows chart cannot derive them
# itself. Regenerate or edit if the domain changes.
argo-workflows:
  server:
    authModes: ["sso", "client"]
    sso:
      enabled: true
      issuer: ${SCHEME}://auth.${G_INT}/application/o/tockmox-argo/
      clientId:
        name: tockmox-sso-argo
        key: client-id
      clientSecret:
        name: tockmox-sso-argo
        key: client-secret
      redirectUrl: ${SCHEME}://workflows.${G_INT}/oauth2/callback
      scopes: ["openid", "email", "profile"]
      rbac:
        enabled: true
# Feature switches. To enable something, replace the empty map on the last line
# of this block with your entries, indented under the key.
#
# This comment deliberately does NOT quote that line verbatim. It used to, and
# a scripted edit then matched the text inside this comment before the real
# key, splitting the comment and hoisting the entries to the top level. What
# ArgoCD reports for that is a schema error naming the KEY, which sends you
# looking for a chart bug rather than at the indentation. Cost an hour on
# 2026-09-11.
#
# Two ways to get this wrong, and neither reports an error:
#   - appending a SECOND "apps:" block lower down. YAML keeps only the LAST
#     occurrence of a top-level key and silently discards this one.
#   - leaving "apps:" with nothing under it. That is null, which DELETES this
#     layer's switch map rather than leaving it at defaults. Most layers then
#     fail to render; tockmox-ai instead falls every app through to its
#     capability tier and quietly undoes any component you turned off (until
#     0.8.0 that switched on the model gateway, which then shipped off, with
#     no NetworkPolicy over its database). Measured 2026-09-11.
#
# Both are checked by: ./install/tockmox-install.sh --lint <site path>
apps: {}
EOF
    else
      wr "$SITE_PATH/site/values/${l}.yaml" <<EOF
# Overrides for tockmox-${l}. Globals are inherited from global.yaml.
# Anything you set here wins.
# Feature switches. To enable something, replace the empty map on the last line
# of this block with your entries, indented under the key.
#
# This comment deliberately does NOT quote that line verbatim. It used to, and
# a scripted edit then matched the text inside this comment before the real
# key, splitting the comment and hoisting the entries to the top level. What
# ArgoCD reports for that is a schema error naming the KEY, which sends you
# looking for a chart bug rather than at the indentation. Cost an hour on
# 2026-09-11.
#
# Two ways to get this wrong, and neither reports an error:
#   - appending a SECOND "apps:" block lower down. YAML keeps only the LAST
#     occurrence of a top-level key and silently discards this one.
#   - leaving "apps:" with nothing under it. That is null, which DELETES this
#     layer's switch map rather than leaving it at defaults. Most layers then
#     fail to render; tockmox-ai instead falls every app through to its
#     capability tier and quietly undoes any component you turned off (until
#     0.8.0 that switched on the model gateway, which then shipped off, with
#     no NetworkPolicy over its database). Measured 2026-09-11.
#
# Both are checked by: ./install/tockmox-install.sh --lint <site path>
apps: {}
EOF
    fi
  done

  mkdir -p "$SITE_PATH/bootstrap/applications"
  wave() { case "$1" in crds) echo 0;; policy) echo 1;; platform) echo 2;;
                        observability|exporters) echo 3;; identity) echo 4;; *) echo 5;; esac; }
  # Each layer's DESTINATION namespace. Helm subcharts install into their
  # release's namespace, so this is where the layer's workloads actually land
  # ... and it must be the namespace the policy layer's NetworkPolicies guard.
  # Pointing every layer at the Argo namespace deploys a working stack whose
  # 20 NetworkPolicies all guard empty namespaces.
  # NOTE: this map is duplicated in tools/check-no-ghost-policies.sh, which
  # fails CI when the two disagree in the way that matters ... a policy left
  # guarding a namespace nothing deploys into.
  # Honours the same namespaces.* overrides as the policy chart when adopting.
  dest_ns() {
    local key="" def=""
    case "$1" in
      ai)            key=ai;        def=tockmox-ai ;;
      observability|exporters) key=monitoring; def=tockmox-monitoring ;;
      platform)      key=platform;  def=tockmox-platform ;;
      identity)      key=authentik; def=tockmox-authentik ;;
      devops)        key=devops;    def=tockmox-devops ;;
      selfcheck)     key=selfcheck; def=tockmox-selfcheck ;;
      # crds is cluster-scoped; policy names an explicit namespace on
      # everything it ships. Both can live with the Argo namespace.
      *) printf '%s' "$ARGO_NS"; return ;;
    esac
    local ov=""
    [[ -n "$CONFIG" ]] && ov="$(yget "namespaces.$key" "$CONFIG")"
    printf '%s' "${ov:-$def}"
  }
  for l in "${LAYERS_ON[@]}"; do
    cat > "$SITE_PATH/bootstrap/applications/tockmox-${l}.yaml" <<EOF
# Generated by tockmox-install.sh v${VERSION}.
# Applied by the parent Application in ../root.yaml, which is what makes the
# sync-wave annotation below actually sequence. Applying these directly with
# kubectl works, but they all sync at once and the waves do nothing.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tockmox-${l}
  namespace: ${ARGO_NS}
  annotations:
    argocd.argoproj.io/sync-wave: "$(wave "$l")"
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    # Where this layer's workloads land; must match what the policy layer's
    # NetworkPolicies guard. See the namespaces map in tockmox-policy/values.yaml.
    namespace: $(dest_ns "$l")
  sources:
    - repoURL: ${TM_REPO}
      targetRevision: ${TM_REV}
      path: charts/tockmox-${l}
      helm:
        valueFiles:
          - \$site/site/values/global.yaml
          - \$site/site/values/${l}.yaml
    - repoURL: PLACEHOLDER_SITE_REPO_URL
      targetRevision: main
      ref: site
  syncPolicy:
$( [[ "$ARGO_AUTO" == true ]] && printf '    automated:\n      prune: true\n      selfHeal: %s\n' "$ARGO_HEAL" )
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
  done

  # THE SEALED SECRETS, which nothing used to apply. `tools/mint-secrets.sh`
  # writes eleven `.sealed.yaml` files into secrets/, the site README calls
  # that directory "your SealedSecrets", and secrets.md says to commit them
  # ... and until 2026-09-12 no generated Application ever read the directory,
  # so they sat in the repository and never reached the cluster. What the
  # operator sees is CreateContainerConfigError on litellm, authentik, grafana
  # and ntfy, which reads as a broken chart rather than an unapplied secret.
  # Found by installing from the generated site verbatim.
  #
  # Sync-wave 1, ahead of every layer (the layers are 2+): a Secret that
  # arrives after the Deployment that mounts it is the same outage, just later.
  # An EMPTY secrets/ is fine and syncs to nothing ... the directory always
  # holds .gitkeep, so ArgoCD never sees a path that does not exist.
  #
  # NAMESPACE TIMING (TM-0277). Each SealedSecret names its own namespace
  # (tockmox-monitoring, tockmox-authentik, ...), and those namespaces are
  # created by the POLICY layer, which is also wave 1. So this Application can
  # reach a namespace before policy has made it. `CreateNamespace=true` below
  # does not help: it creates only the Application's destination, `default`.
  # The `retry` block is the mechanism: a sync that fails on a missing namespace
  # is retried with backoff until policy has created it, instead of failing once
  # and staying failed (Argo does not re-attempt a failed automated sync of the
  # same revision on its own). It is not a proof that the two never race; see
  # docs/administration/secrets.md, "What is not certified here". The wave is
  # NOT moved: the site template repository mirrors wave 1, and so does the
  # release preflight.
  cat > "$SITE_PATH/bootstrap/applications/site-secrets.yaml" <<EOF
# Generated by tockmox-install.sh v${VERSION}.
# Syncs every SealedSecret under secrets/ in this repository. SealedSecrets are
# safe to commit ... that is the point of them ... so they travel with the site
# and are applied like anything else, rather than by a kubectl step nobody
# writes down. The controller in kube-system decrypts them into real Secrets.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: site-secrets
  namespace: ${ARGO_NS}
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  source:
    repoURL: PLACEHOLDER_SITE_REPO_URL
    targetRevision: main
    path: secrets
    directory:
      recurse: true
  syncPolicy:
$( [[ "$ARGO_AUTO" == true ]] && printf '    automated:\n      prune: true\n      selfHeal: %s\n' "$ARGO_HEAL" )
    # A SealedSecret in a namespace policy has not created yet fails the sync;
    # retry until it exists. See the note in tockmox-install.sh.
    retry:
      limit: 5
      backoff:
        duration: 20s
        factor: 2
        maxDuration: 5m
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF

  # Your own applications: everything in apps/ syncs as one Application, so
  # the README's promise that apps/ is yours actually has a mechanism.
  cat > "$SITE_PATH/bootstrap/applications/site-apps.yaml" <<EOF
# Generated by tockmox-install.sh v${VERSION}.
# Syncs everything under apps/ in this repository ... your own workloads,
# ordered after all Tockmox layers. Manifests carry their own namespaces.
# See docs/administration/adding-an-application.md for the full wiring of a
# new app (ingress, SSO, database, backups, metrics).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: site-apps
  namespace: ${ARGO_NS}
  annotations:
    argocd.argoproj.io/sync-wave: "6"
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  source:
    repoURL: PLACEHOLDER_SITE_REPO_URL
    targetRevision: main
    path: apps
    directory:
      recurse: true
  syncPolicy:
$( [[ "$ARGO_AUTO" == true ]] && printf '    automated:\n      prune: true\n      selfHeal: %s\n' "$ARGO_HEAL" )
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF

  wr "$SITE_PATH/apps/README.md" <<'EOF'
# Your applications

Everything in this directory syncs to the cluster via the `site-apps`
Application. Plain manifests or Argo Application CRs both work; manifests
should carry their own `namespace:`. The full wiring guide for a new app
(namespace, netpol, database, backups, ingress, SSO, metrics):
docs/administration/adding-an-application.md in the Tockmox repository.
EOF

  # The parent. This is the only thing you apply by hand.
  cat > "$SITE_PATH/bootstrap/root.yaml" <<EOF
# Tockmox root Application ("app of apps") for site "${SITE_NAME}".
#
# Apply THIS ONE:  kubectl apply -f bootstrap/root.yaml
#
# It owns the nine layer Applications in bootstrap/applications/, which is what
# gives their sync-wave annotations effect. Waves applied flat with kubectl do
# not sequence ... ArgoCD orders resources within an Application, and without a
# parent there is no Application to order them within.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tockmox-root
  namespace: ${ARGO_NS}
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGO_NS}
  source:
    repoURL: PLACEHOLDER_SITE_REPO_URL
    targetRevision: main
    path: bootstrap/applications
  syncPolicy:
    automated:
      prune: true
      selfHeal: ${ARGO_HEAL}
EOF

  wr "$SITE_PATH/.gitignore" <<'EOF'
*.tgz
.DS_Store
# Never commit an unsealed secret or a kubeconfig.
*.kubeconfig
kubeconfig
secrets/*.plain.yaml
# mint-secrets.sh stages sealed files here while it runs and removes it on exit.
# Only a killed process leaves one behind.
secrets/.mint.*/
EOF

  wr "$SITE_PATH/README.md" <<EOF
# ${SITE_NAME} ... Tockmox site

Your deployment. Contains **no copy of Tockmox** ... only what is yours:
values, secrets, and your own applications.

Generated by tockmox-install.sh v${VERSION}.

## Before you apply

\`bootstrap/root.yaml\` and \`bootstrap/applications/*.yaml\` contain **PLACEHOLDER_SITE_REPO_URL**.
Push this directory to a git repository, then replace that placeholder with its
URL. ArgoCD reads your values from that repo, so it must be reachable from the
cluster.

## Upgrading Tockmox

Edit \`targetRevision\` in \`bootstrap/applications/*.yaml\` and sync.
Currently tracking **${TM_REV}**.

## Layout

    site/values/global.yaml   settings every layer reads
    site/values/<layer>.yaml  per-layer overrides
    apps/                     your own Argo Applications
    secrets/                  your SealedSecrets
    bootstrap/                the root Applications

## Rules worth knowing

- Do not use the reserved \`tockmox-\` namespace prefix for your own workloads.
- Editing resources with kubectl will not stick while selfHeal is on.
  Change this repo instead.
EOF
  ok "site repository written to $SITE_PATH"
fi

# ---------------------------------------------------------------- next steps
#
# There is ONE ending, because there is no apply phase to branch on. Until
# 2026-09-01 there were two, differing only in whether the PLACEHOLDER warning
# printed, plus a --verify block whose entire body explained that it had
# nothing to verify. That block was the clearest evidence that the flags
# described a phase this script does not have (TM-0271).
say "Next steps"
if $DRY_RUN; then
  warn "--dry-run: nothing was written. Re-run without it to generate $SITE_PATH."
  printf '\n'
fi
# COUNTED, not hardcoded. It was "11 files" as a literal, which happens to be
# right today and is one layer away from being wrong ... and a wrong count in
# a warning about a manual step is worse than no count, because the operator
# stops looking when they have fixed that many.
if $DRY_RUN; then
  # Nothing was written to count, so count what a real run writes: README.md,
  # bootstrap/root.yaml, site-secrets.yaml and site-apps.yaml, plus one
  # Application per layer. It said eleven, which missed README.md and
  # site-secrets.yaml (L1, 2026-10-09: the real run carried 13).
  ph=$((4 + ${#LAYERS_ON[@]}))
else
  # Scan the WHOLE site, not just bootstrap/. The generated README.md carries
  # the placeholder too, so a count scoped to bootstrap/ was right about
  # bootstrap/ and wrong about the repository ... and step 3 below, which named
  # only root.yaml and applications/*.yaml, left the README holding a stale
  # placeholder on every install.
  ph=$(grep -rl PLACEHOLDER_SITE_REPO_URL "$SITE_PATH" 2>/dev/null | wc -l | tr -d ' ')
fi
warn "The generated site carries PLACEHOLDER_SITE_REPO_URL in ${ph} files."
warn "ArgoCD reads your values over git, so it cannot work until that points at"
warn "a repository your cluster can reach. Only you know where that is."
printf '\n'
# `-b main`: a bare `git init` names the branch from init.defaultBranch, which a
# stock git leaves unset, so the branch is `master` and the `git push -u origin
# main` that install.md 2a prints fails with `src refspec main does not match
# any` (measured 2026-09-14). The Applications this script just wrote target
# `main`, so the branch name is not the operator's to vary.
info "0. seal your credentials (writes to a CLUSTER; confirms the context first):"
info "     $0 bootstrap-secrets --mode new --site $SITE_PATH --backup-out KEYFILE --age-recipient AGE_PUBLIC_KEY"
info "   --mode recover restores an existing deployment's key; --mode reuse uses a running"
info "   controller. Prefer to do it by hand? docs/administration/secrets.md still works."
# TM-0798: since 0.8.0 the policy layer refuses to render the platform
# namespace's node-network rule without the per-node gateway list, and that list
# can only be read from a running cluster. Site generation deliberately reads
# nothing from one (see "THESE CHECKS ARE ADVICE" above), so it is a step the
# operator runs, named here so the refusal is never the first they hear of it.
if [[ " ${LAYERS_ON[*]} " == *" policy "* ]]; then
  info "0b. give the policy layer each node's gateway address (required since 0.8.0;"
  info "    reads the cluster, prints only; install.md step 1f):"
  info "     $0 --print-netpol-node-sources --context YOUR_KUBECONTEXT >> $SITE_PATH/site/values/policy.yaml"
  info "    No per-node podCIDR on your CNI? Set apps.platform_netpol.enabled=false there instead."
fi
info "1. cd $SITE_PATH && git init -b main && git add -A && git commit -m 'initial'"
info "2. push it somewhere the cluster can reach"
info "3. replace PLACEHOLDER_SITE_REPO_URL everywhere it appears:"
# The form below is install.md section 2b's, and the naive one-liner this used
# to print broke all three of the rules that page names (2026-09-13):
#   `git grep`, not `grep -r`   -- a recursive grep descends into .git/, where
#                                  the placeholder sits inside object files
#   a read loop, not `xargs`    -- `xargs sed` with no matches reads stdin and
#                                  appears to hang
#   write-and-move, not `sed -i` -- BSD and GNU disagree about bare -i, and one
#                                  of them creates a file named `-e`
# It also used `sed -i.bak`, which litters the site repo with .bak files that
# then get committed. This is the LAST thing an operator reads, from the tool
# itself, so it must not contradict the page it sends them to next.
info "     git grep -l PLACEHOLDER_SITE_REPO_URL | while IFS= read -r f; do"
info "       sed \"s|PLACEHOLDER_SITE_REPO_URL|\$SITE_REPO_URL|g\" \"\$f\" > \"\$f.tmp\" && mv \"\$f.tmp\" \"\$f\""
info "     done"
info "   That is bootstrap/root.yaml, bootstrap/applications/*.yaml and README.md."
info "   (run it after step 1, since git grep needs the repository to exist)"
info "4. kubectl apply -f $SITE_PATH/bootstrap/root.yaml"
info "5. watch it land: kubectl -n ${ARGO_NS} get applications -w"
info "6. when tockmox-platform is Synced and Healthy, publish the product docs from this"
info "   checkout (they are not in any image; the docs site shows a placeholder until then):"
info "     $0 publish-docs --context YOUR_KUBECONTEXT --config ${CONFIG:-tockmox.yaml} --wait 600"
printf '\n'
ok "installer finished. Nothing was applied to your cluster."

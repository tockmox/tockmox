#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# forge-move.sh ... move the site repository off the built-in forge to an empty
# repository you own elsewhere, and repoint Argo CD at it.
#
#   ./install/tockmox-install.sh move-forge --context NAME --to URL --credentials FILE [options]
#
# The exit the spec promises ("For people who want git"): the whole history goes,
# not a snapshot, and Argo CD changes source in ONE change that an approver merges,
# like every other change to the site. In order:
#
#   1. The target must be EMPTY (no branch, no tag). A repository with anything in
#      it is refused: pushing over someone's history is never what "move" means.
#   2. Every branch and tag of the site repository is pushed to the target, and the
#      target's main is read back equal to the forge's.
#   3. Argo CD gets a read credential for the target (a repository Secret), before
#      anything names it.
#   4. One change opens on the built-in forge: every file that names the forge's
#      in-cluster address names the target instead. It waits for an approver, in
#      the console (Platform > Changes) or on the forge, as every change does.
#   5. Once it is merged: main is pushed to the target again (it now holds the
#      merge), the root Application is re-applied from it, and the built-in forge's
#      repository is ARCHIVED (read-only; nothing is deleted). Argo CD then reads
#      only the target.
#
# If the approval does not come within --approval-wait-minutes, the run stops
# after step 4 and says so; `move-forge --finish` with the same options carries
# out step 5 once the change is merged. Re-running from the start is refused once
# the target holds the history (it is no longer empty), which is the point.
#
# IN THE CLUSTER (--in-cluster): the console's "Move to my own forge" runs THIS script in a Job
# (bootstrap-forge's suspended <release>-move template, image alpine/k8s), so there is one move,
# not two. Then there is no kubeconfig and no port-forward: the forge is reached at its Service,
# kubectl uses the Job's ServiceAccount (a Role that can read the forge's admin Secret, write the
# one Argo CD repository Secret and patch the one root Application), the person who asked is
# --requested-by, and every step prints one "STEP n ok|fail|wait <words>" line the console shows.
#
# WHAT STAYS: the forge itself, archived, and its off-site copy job, which keeps
# the last state it copied. Remove them when you are sure (site-forge.md says how).
# Your tockmox.yaml still says site.forge: built-in; set it to external, with the
# target as the repository, before you run the installer again.
# ============================================================================
set -euo pipefail

RELEASE="tockmox-forge"; ORG="tockmox"; REPO="site"; BRANCH="move-to-own-forge"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; X=$'\e[0m'
else B=""; G=""; Y=""; R=""; X=""; fi
say()  { printf '\n%s== %s%s\n' "$B" "$*" "$X"; }
ok()   { printf '%s  ✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '%s  !%s %s\n' "$Y" "$X" "$*"; }
err()  { printf '%s  ✗%s %s\n' "$R" "$X" "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { printf '    %s\n' "$*"; }

usage() {
  cat <<'USAGE'
tockmox-install.sh move-forge --context NAME --to URL --credentials FILE [options]

Move the site repository from the built-in forge to an EMPTY repository elsewhere,
with its whole history, and repoint Argo CD at it in one change an approver merges.

  --context NAME            the site's cluster (required)
  --yes-context NAME        confirm it without a prompt (must equal --context)
  --no-prompt               never ask; refuse unless --yes-context confirms the context
  --to URL                  the empty repository, https://, no credentials in it
  --credentials FILE        two lines, user then token, that can PUSH to it (never stored in the cluster)
  --read-credentials FILE   two lines Argo CD reads it with (default: --credentials; a read-only token is better)
  --namespace NS            the forge's namespace (default tockmox-forge)
  --argocd-namespace NS     default argocd
  --approval-wait-minutes N how long to wait for the change's approval (default 60)
  --finish                  only step 5, once the change is merged
  --dry-run                 check the target and say what would happen; change nothing
  --in-cluster              run inside the forge's namespace (the console's Job): no --context, the forge
                            at its Service, kubectl as the pod's ServiceAccount, no prompt
  --forge-url URL           with --in-cluster: the forge's address (default its Service)
  --requested-by NAME       who asked (their sign-in name); the change carries Tockmox-Requested-By: NAME
  --request FILE            with --in-cluster: the run's request, one key=value a line: to=URL,
                            mode=check|move|finish, requested-by=NAME (the console's Job template is fixed;
                            what changes from run to run comes in this file, beside the credentials)
  -h, --help                this
USAGE
}

CONTEXT=""; YES_CONTEXT=""; NO_PROMPT=false; TO=""; CREDS=""; READ_CREDS=""
FORGE_NS="tockmox-forge"; ARGO_NS="argocd"; WAIT_MIN=60; FINISH=false; DRY_RUN=false
IN_POD=false; FORGE_URL=""; REQUESTED_BY=""; REQUEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:?--context needs a name}"; shift 2 ;;
    --yes-context) YES_CONTEXT="${2:?--yes-context needs the context name}"; shift 2 ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    --to) TO="${2:?--to needs a URL}"; shift 2 ;;
    --credentials) CREDS="${2:?--credentials needs a file}"; shift 2 ;;
    --read-credentials) READ_CREDS="${2:?--read-credentials needs a file}"; shift 2 ;;
    --namespace) FORGE_NS="${2:?--namespace needs a name}"; shift 2 ;;
    --argocd-namespace) ARGO_NS="${2:?--argocd-namespace needs a name}"; shift 2 ;;
    --approval-wait-minutes) WAIT_MIN="${2:?--approval-wait-minutes needs a number}"; shift 2 ;;
    --finish) FINISH=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --in-cluster) IN_POD=true; shift ;;
    --forge-url) FORGE_URL="${2:?--forge-url needs a URL}"; shift 2 ;;
    --requested-by) REQUESTED_BY="${2:?--requested-by needs a name}"; shift 2 ;;
    --request) REQUEST="${2:?--request needs a file}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

# One line per step for the console's progress page (--in-cluster); a person at a terminal reads the rest.
STEP_NOW=0
step() { STEP_NOW="$1"; $IN_POD && printf 'STEP %s %s %s\n' "$1" "$2" "$3" || true; }
die_step() { $IN_POD && [[ "$STEP_NOW" != 0 ]] && printf 'STEP %s fail %s\n' "$STEP_NOW" "$1" || true; die "$1"; }

say "Checking the request"
if [[ -n "$REQUEST" ]]; then
  # Only the console's Job takes a request file, and then nothing on the command line says what to do.
  $IN_POD || die "--request goes with --in-cluster"
  if [[ -n "$TO$REQUESTED_BY" ]] || $DRY_RUN || $FINISH; then
    die "--request carries to, mode and requested-by; do not pass them as options too"
  fi
  [[ -r "$REQUEST" ]] || die "cannot read the request $REQUEST"
  MODE=""; SEEN=" "
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    [[ "$line" == *=* && "$SEEN" != *" $k "* ]] || die "the request has a malformed or repeated line: '${line%%=*}'"
    SEEN="$SEEN$k "
    case "$k" in
      to) TO="$v" ;;
      mode) MODE="$v" ;;
      requested-by) REQUESTED_BY="$v" ;;
      *) die "the request names an unknown key: '$k'" ;;
    esac
  done < "$REQUEST"
  case "$MODE" in
    check) DRY_RUN=true ;;
    move) ;;
    finish) FINISH=true ;;
    *) die "the request's mode must be check, move or finish: '$MODE'" ;;
  esac
fi
if $IN_POD; then
  [[ -z "$CONTEXT" && -z "$YES_CONTEXT" ]] || die "--in-cluster runs as the pod's ServiceAccount: it takes no --context"
  [[ -n "${KUBERNETES_SERVICE_HOST:-}" || -n "${TOCKMOX_TEST_ALLOW_HTTP:-}" ]] || die "--in-cluster runs only inside a pod (no KUBERNETES_SERVICE_HOST here)"
  [[ -z "$REQUESTED_BY" || "$REQUESTED_BY" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || die "--requested-by must be a sign-in name: '${REQUESTED_BY}'"
else
  [[ -z "$FORGE_URL" ]] || die "--forge-url goes with --in-cluster"
  [[ -n "$CONTEXT" ]] || die "--context is required: name the site's cluster. This never falls back to the current context."
  [[ -z "$YES_CONTEXT" || "$YES_CONTEXT" == "$CONTEXT" ]] || die "--yes-context '$YES_CONTEXT' does not match --context '$CONTEXT'. Nothing was touched."
fi
# A loopback http target exists only for this script's own tests (TOCKMOX_TEST_ALLOW_HTTP); never set it.
if [[ -n "${TOCKMOX_TEST_ALLOW_HTTP:-}" && "$TO" =~ ^http://127\.0\.0\.1:[0-9]+/ ]]; then :
else [[ "$TO" =~ ^https://[^@[:space:]]+$ ]] || die "--to must be an https URL with no credentials in it: '${TO}'"; fi
[[ -n "$CREDS" && -r "$CREDS" && "$(grep -c . "$CREDS")" -ge 2 ]] || die "--credentials FILE is required: two lines, a user and a token that can push to $TO"
READ_CREDS="${READ_CREDS:-$CREDS}"
[[ -r "$READ_CREDS" && "$(grep -c . "$READ_CREDS")" -ge 2 ]] || die "cannot read --read-credentials $READ_CREDS (two lines)"
[[ -z "$(sed -n '1,2{/["\\]/p;}' "$CREDS" "$READ_CREDS")" ]] || die "a credentials file holds a quote or a backslash, which cannot be passed safely"
[[ "$WAIT_MIN" =~ ^[0-9]+$ ]] || die "--approval-wait-minutes must be a whole number: '$WAIT_MIN'"
for t in kubectl git curl python3; do command -v "$t" >/dev/null 2>&1 || die "missing: $t"; done
K=(--context "$CONTEXT")
$IN_POD && K=()
if ! $IN_POD && [[ -z "$YES_CONTEXT" ]] && ! $DRY_RUN; then
  if ! $NO_PROMPT && (: < /dev/tty) 2>/dev/null; then
    printf '    Move the site repository of %s to %s? Type the context name to go on: ' "$CONTEXT" "$TO" > /dev/tty
    read -r answer < /dev/tty || answer=""
    [[ "$answer" == "$CONTEXT" ]] || die "not confirmed. Nothing was touched."
  else
    die "nothing to confirm the context with: pass --yes-context $CONTEXT. Nothing was touched."
  fi
fi
IN_CLUSTER="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000/${ORG}/${REPO}.git"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-move.XXXXXX")"; PF_PID=""
cleanup() { [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

hdr() { printf 'Authorization: Basic %s' "$(printf '%s:%s' "$(sed -n 1p "$1")" "$(sed -n 2p "$1")" | base64 | tr -d '\n')"; }
TGT_HDR="$(hdr "$CREDS")"
tgit() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$TGT_HDR" GIT_TERMINAL_PROMPT=0 git "$@"; }

# ---------------------------------------------------------------- the forge
say "The built-in forge"
ADMIN_USER="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
ADMIN_PASS="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || die "cannot read the forge's admin Secret ${FORGE_NS}/${RELEASE}-admin. This moves a site on the built-in forge."
printf '%s\n%s\n' "$ADMIN_USER" "$ADMIN_PASS" > "$TMPD/admin"; chmod 600 "$TMPD/admin"
FORGE_HDR="$(hdr "$TMPD/admin")"
fgit() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$FORGE_HDR" GIT_TERMINAL_PROMPT=0 git "$@"; }
if $IN_POD; then
  FORGE="${FORGE_URL:-http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000}"
  FORGE="${FORGE%/}"
  if [[ -n "${TOCKMOX_TEST_ALLOW_HTTP:-}" && "$FORGE" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then :
  else [[ "$FORGE" =~ ^http://[a-z0-9.-]+\.svc\.cluster\.local:[0-9]+$ ]] || die "--forge-url must be the forge's in-cluster Service address: '$FORGE'"; fi
else
  kubectl "${K[@]}" -n "$FORGE_NS" port-forward "svc/${RELEASE}-http" 0:3000 > "$TMPD/pf.log" 2>&1 &
  PF_PID=$!
  PORT=""
  for _ in $(seq 1 30); do
    PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 3000$/\1/p' "$TMPD/pf.log" | head -1)"
    [[ -n "$PORT" ]] && break
    kill -0 "$PF_PID" 2>/dev/null || die "the port-forward to the forge exited: $(cat "$TMPD/pf.log")"
    sleep 1
  done
  [[ -n "$PORT" ]] || die "the port-forward to the forge did not start"
  FORGE="http://127.0.0.1:${PORT}"
fi
api() {  # METHOD PATH [JSON] -> body; status in $TMPD/http
  local body
  body="$(printf '%s' "${3:-}" | curl -sS -w '\n%{http_code}' -X "$1" -H "$FORGE_HDR" \
    ${3:+-H 'Content-Type: application/json' --data-binary @-} "$FORGE/api/v1$2")" || body=$'\n000'
  printf '%s' "${body##*$'\n'}" > "$TMPD/http"; printf '%s' "${body%$'\n'*}"
}
code() { cat "$TMPD/http"; }
FORGE_MAIN="$(fgit ls-remote "$FORGE/$ORG/$REPO.git" refs/heads/main | awk 'NR==1{print $1}')"
[[ "$FORGE_MAIN" =~ ^[0-9a-f]{40}$ ]] || die "cannot read main from the built-in forge"
ok "the site repository's main is ${FORGE_MAIN:0:12}"

# ---------------------------------------------------------------- steps 1 to 4
if ! $FINISH; then
  say "The target"
  step 1 run "checking the target"
  REFS="$(tgit ls-remote "$TO" 2>"$TMPD/ls.err")" || die_step "cannot read $TO with --credentials: $(tail -1 "$TMPD/ls.err"). Nothing was touched."
  [[ -z "$REFS" ]] || die_step "$TO is not empty ($(printf '%s\n' "$REFS" | grep -c .) refs). Moving pushes the whole history into an EMPTY repository;
       create a new one with no README, licence or branch. Nothing was touched."
  ok "$TO is empty and these credentials can read it"
  step 1 ok "the target is empty and the credentials can read it"
  if $DRY_RUN && $IN_POD; then
    # What the console's check shows before anything moves: what would go, and what the change would rewrite.
    SRC="$(fgit ls-remote "$FORGE/$ORG/$REPO.git")" || die "cannot read the site repository from the forge"
    NB="$(printf '%s\n' "$SRC" | grep -c $'\trefs/heads/' || true)"
    NT="$(printf '%s\n' "$SRC" | grep $'\trefs/tags/' | grep -vc '\^{}$' || true)"
    fgit clone -q --depth 1 --branch main "$FORGE/$ORG/$REPO.git" "$TMPD/look" || die "cannot check the site out"
    NF="$(grep -rlF --exclude-dir=.git "$IN_CLUSTER" "$TMPD/look" | grep -c . || true)"
    [[ "$NF" -gt 0 ]] || die "no file in the site names $IN_CLUSTER; is this a built-in-forge site, in namespace $FORGE_NS?"
    printf 'CHECK branches=%s tags=%s main=%s files=%s\n' "$NB" "$NT" "$FORGE_MAIN" "$NF"
  fi
  if $DRY_RUN; then
    info "would push every branch and tag (main ${FORGE_MAIN:0:12}) to $TO, give Argo CD a read credential for it,"
    info "and open one change that names $TO wherever the site names $IN_CLUSTER"
    exit 0
  fi
  say "The whole history, to the target"
  step 2 run "pushing every branch and tag"
  fgit clone -q --mirror "$FORGE/$ORG/$REPO.git" "$TMPD/mirror.git" || die_step "cannot clone the site repository from the forge"
  tgit -C "$TMPD/mirror.git" push -q "$TO" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' \
    || die_step "pushing to $TO failed. Can these credentials push there? If part of it landed, the target is no longer empty; empty it before you run this again."
  got="$(tgit ls-remote "$TO" refs/heads/main | awk 'NR==1{print $1}')"
  [[ "$got" == "$FORGE_MAIN" ]] || die_step "$TO's main reads back as ${got:-nothing}, not ${FORGE_MAIN:0:12}"
  ok "every branch and tag pushed; $TO's main is ${FORGE_MAIN:0:12}"
  step 2 ok "every branch and tag pushed; the target's main is ${FORGE_MAIN:0:12}"

  say "Argo CD's read credential for the target"
  step 3 run "giving Argo CD a read credential for the target"
  { printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: tockmox-site-repo-own\n  namespace: %s\n' "$ARGO_NS"
    printf '  labels:\n    argocd.argoproj.io/secret-type: repository\n    app.kubernetes.io/managed-by: tockmox-install\n'
    printf 'stringData:\n  type: git\n  url: "%s"\n  username: "%s"\n  password: "%s"\n' "$TO" "$(sed -n 1p "$READ_CREDS")" "$(sed -n 2p "$READ_CREDS")"
  } | kubectl "${K[@]}" apply -f - >/dev/null || die_step "cannot write ${ARGO_NS}/tockmox-site-repo-own"
  ok "${ARGO_NS}/tockmox-site-repo-own: Argo CD can read $TO"
  step 3 ok "Argo CD can read the target"

  say "The change that repoints Argo CD"
  step 4 run "opening the change that repoints Argo CD"
  fgit clone -q --branch main "$FORGE/$ORG/$REPO.git" "$TMPD/work" || die_step "cannot check the site out"
  mapfile -t FILES < <(grep -rlF --exclude-dir=.git "$IN_CLUSTER" "$TMPD/work" || true)
  [[ "${#FILES[@]}" -gt 0 ]] || die_step "no file in the site names $IN_CLUSTER; is this a built-in-forge site, in namespace $FORGE_NS?"
  for f in "${FILES[@]}"; do
    python3 - "$f" "$IN_CLUSTER" "$TO" <<'PY' || die "cannot rewrite $f"
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
  done
  git -C "$TMPD/work" checkout -q -b "$BRANCH"
  git -C "$TMPD/work" -c user.name=tockmox-install -c user.email=tockmox-install@localhost.invalid \
    commit -q -am "Move the site repository to ${TO}

Argo CD reads the site from ${TO} from this change on. The built-in forge is
archived (read-only) once it is merged; its history is all in ${TO}.${REQUESTED_BY:+

Tockmox-Requested-By: ${REQUESTED_BY}}" || die_step "cannot commit the change"
  fgit -C "$TMPD/work" push -q "$FORGE/$ORG/$REPO.git" "$BRANCH" || die_step "cannot push the change's branch to the forge"
  # Started from the console, the change carries who asked (an approver other than them merges it) and its origin.
  PR_BODY="Every file that named the built-in forge names ${TO} instead (${#FILES[@]} files). Approve it to move.${REQUESTED_BY:+\\n\\nTockmox-Requested-By: ${REQUESTED_BY}\\nTockmox-Origin: console}"
  PR_JSON="$(api POST "/repos/$ORG/$REPO/pulls" "{\"head\":\"$BRANCH\",\"base\":\"main\",\"title\":\"Move the site repository to my own forge\",\"body\":\"${PR_BODY}\"}")"
  [[ "$(code)" == 201 ]] || die_step "opening the change failed (HTTP $(code))"
  PR="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("number") or "")')"
  [[ "$PR" =~ ^[0-9]+$ ]] || die_step "the forge did not say which change it opened"
  ok "change #$PR opened: ${#FILES[@]} files name $TO. Approve it in Platform > Changes."
  step 4 ok "change #$PR opened: ${#FILES[@]} files name the target"
else
  PR="$(api GET "/repos/$ORG/$REPO/pulls?state=all&limit=50" | python3 -c '
import json, sys
try:
    prs = json.load(sys.stdin)
except ValueError:
    prs = []
hits = [p["number"] for p in prs if isinstance(p, dict) and (p.get("head") or {}).get("ref") == sys.argv[1]]
print(max(hits) if hits else "")' "$BRANCH")"
  [[ -n "$PR" ]] || die "no 'Move the site repository to my own forge' change on the forge; run move-forge without --finish first"
fi

# ---------------------------------------------------------------- step 5
say "Waiting for the approval"
deadline=$(( $(date +%s) + WAIT_MIN * 60 )); MERGED=false
while :; do
  st="$(api GET "/repos/$ORG/$REPO/pulls/$PR" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)
except ValueError:
    p = {}
print("merged" if p.get("merged") else p.get("state", "unknown"))')"
  if [[ "$st" == merged ]]; then MERGED=true; break; fi
  [[ "$st" != closed ]] || die "change #$PR was closed without merging. Nothing moved: Argo CD still reads the built-in forge. ($TO holds a copy of the history.)"
  [[ "$(date +%s)" -lt "$deadline" ]] || break
  sleep 10
done
if ! $MERGED; then
  if $IN_POD; then
    step 5 wait "change #$PR waits for an approver; Finish the move once it is merged"
    exit 0
  fi
  warn "change #$PR is not merged yet. Approve it, then run move-forge --finish with the same options."; exit 3
fi
ok "change #$PR merged"
step 5 run "change #$PR merged: pushing main again, re-applying the root, archiving the forge's repository"
MAIN_NOW="$(fgit ls-remote "$FORGE/$ORG/$REPO.git" refs/heads/main | awk 'NR==1{print $1}')"
rm -rf "$TMPD/mirror.git"
fgit clone -q --mirror "$FORGE/$ORG/$REPO.git" "$TMPD/mirror.git" || die "cannot clone the forge again"
tgit -C "$TMPD/mirror.git" push -q "$TO" 'refs/heads/main:refs/heads/main' || die "pushing the merged main to $TO failed. Argo CD now names $TO: push it by hand, or move back by reverting change #$PR."
got="$(tgit ls-remote "$TO" refs/heads/main | awk 'NR==1{print $1}')"
[[ "$got" == "$MAIN_NOW" ]] || die "$TO's main is ${got:-nothing}, not the merged ${MAIN_NOW:0:12}"
ok "$TO holds the merged main ${MAIN_NOW:0:12}"
rm -rf "$TMPD/work"; tgit clone -q --branch main "$TO" "$TMPD/work" || die_step "cannot check the target out"
if $IN_POD; then
  # The Job's Role may patch ONE Application, tockmox-root: refuse anything else before kubectl is asked.
  python3 - "$TMPD/work/bootstrap/root.yaml" "$ARGO_NS" <<'ROOTCHECK' || die_step "bootstrap/root.yaml in $TO is not the one root Application (tockmox-root in $ARGO_NS); nothing was applied"
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
docs = [d for d in re.split(r"(?m)^---\s*$", s)
        if any(l.strip() and not l.strip().startswith("#") for l in d.splitlines())]
ok = (len(docs) == 1 and re.search(r"(?m)^kind:\s*Application\s*$", docs[0])
      and re.search(r"(?m)^  name:\s*tockmox-root\s*$", docs[0])
      and re.search(r"(?m)^  namespace:\s*" + re.escape(sys.argv[2]) + r"\s*$", docs[0]))
sys.exit(0 if ok else 1)
ROOTCHECK
fi
kubectl "${K[@]}" apply -f "$TMPD/work/bootstrap/root.yaml" >/dev/null || die_step "cannot re-apply the root Application from $TO"
ok "root Application re-applied from $TO"
api PATCH "/repos/$ORG/$REPO" '{"archived":true}' >/dev/null
[[ "$(code)" == 200 ]] || die_step "archiving the built-in forge's repository failed (HTTP $(code)). Argo CD already reads $TO; archive it by hand."
ok "the built-in forge's repository is archived: read-only, nothing deleted"
step 5 ok "Argo CD reads only the target; the built-in forge's repository is archived (read-only, nothing deleted)"
info "next: in tockmox.yaml set site.forge: external, with $TO as the site repository, before you run the installer again"
info "the forge and its off-site copy job are still installed; site-forge.md says how to remove them"

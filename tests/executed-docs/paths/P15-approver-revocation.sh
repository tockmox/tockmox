#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P15 ... the approvers watcher (docs/administration/site-forge.md, "The approvers watcher") on the install P09
# made on the built-in forge route. The forge updates a person's teams only when they sign in, so someone taken out of
# the admin group stays in `approvers`; the watcher reads both every minute and two alerts read the watcher. P09 shows
# the watcher's check is clean on a fresh install. This path plants the removal and the failed read the page talks
# about, and reads the alerts in Prometheus, in six steps:
#
#   S01  before anything is planted: both alerts are loaded from the chart's rules and inactive, the watcher's check is
#        clean, and the name the path plants exists nowhere
#   S02  plant (GLUE): an Authentik user, active and in tockmox-admins, and a forge account of the same name in the
#        approvers team (what Forgejo's group mapping does at a sign-in), and an open pull request on the site
#        repository that carries that person's approval. The watcher reads them clean: nobody is outside
#   S03  the person is taken out of tockmox-admins. TockmoxForgeApproverOutsideGroup fires for them within 120 seconds,
#        and its description names the approvers team and the pull request. They never signed in, in either place
#   S04  they are put back: the alert stops. Then they are deactivated: it fires again within 120 seconds
#   S05  a failed read: the watcher's copy of its Authentik token is replaced by one Authentik refuses. The watcher
#        judges nobody, so the person's alert stops while they are still deactivated, and
#        TockmoxForgeApproversCheckDown fires after its 15 minutes. The token is put back: CheckDown stops and the
#        person's alert fires again
#   S06  identity.md's block that removes them from the forge's organisation, as printed (two placeholders filled, the
#        log names them). It prints 204, they are no longer in approvers, and the alert stops
#   S07  everything planted is taken out again and read back as gone
#
# THE PAGES PRINT ONE COMMAND HERE, S06's. Everything else is GLUE, labelled GLUE in the log:
#   - Authentik's side, made and changed with `ak shell` in the worker (tools/check-blueprint-discovery.sh's way in, and
#     the admin-users Job's: group.users.add / remove). identity.md says membership and deactivation are done in
#     Authentik's admin interface and prints no command for either.
#   - the forge's side, through its API as the forge's admin over a port-forward, the way the page's block reaches it:
#     the account (a local one: the watcher compares names, and a real one is made from the Authentik username at the
#     first sign-in), its place in approvers, a branch with one file, a pull request, and the person's approval, made
#     with the forge's Sudo header so that it is theirs. The pull request is never merged and is closed in S07.
#   - the failed read: one key of the watcher's own Secret. The Authentik token is one value in two Secrets
#     (site-forge.md); the watcher's copy is replaced, and put back from the identity layer's copy, so no file of
#     this path ever holds it.
#   - S06's two placeholders, and its lines run one at a time with a pause between them (lib's `pace`), so the
#     port-forward the first line starts is up before the curl, as it is for a reader; then the page's own
#     "Stop the port-forward afterwards (kill %1)".
#   - the waits, every one bounded and recorded with how long it took.
#
# WHEN IT RUNS. run.sh discovers paths/P*.sh and gives this one P09's route group, so a plain run.sh reaches it. It
# does not run there. It needs TOCKMOX_P09_STATE, a p09-passed marker in it, and TOCKMOX_P09_ROUTE=built-in: the
# watcher is bootstrap-forge's, and only the built-in route has it. Any of them missing is BLOCKED with the reason,
# before any call to a cluster.
#
# EVERYTHING PLANTED IS TAKEN OUT, TWICE OVER (P13's shape). A planted thing is written to ${STATE}/planted.list before
# it is made and struck from it once S07 reads it back as gone; an EXIT, TERM, INT and HUP trap takes out whatever is
# still listed. The watcher's token is put back from the identity layer's copy whatever happened.
#
# ITS OWN STATE AND BUDGET. State goes under ${TOCKMOX_P09_STATE}/p15. TOCKMOX_P15_BUDGET (seconds, default 5400) is
# read before S01 and before S02 only: once something is planted the path runs to S07, because every later step reads
# what S02 planted and the trap takes it out on any exit.
#
# TIME, worst case, from the waits below: S02 about 3 minutes (the watcher's one-minute cycle and a scrape, twice),
# S03 5, S04 10, S05 about 43 (the token's way into the pod 4, CheckDown's for: of 15 minutes plus 8 of margin, and
# 13 more for the way back), S06 7, S07 1: about 70 minutes. On a product that behaves, about 35.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null  # read at run time, from beside this file
. "${HERE}/../lib/assert.sh"

path_begin "P15-approver-revocation" \
  "after P09 on the built-in forge: an approver taken out of the admin group, or deactivated, is alerted on within two minutes without signing in; a failed read judges nobody and raises CheckDown; the page's removal clears it"

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
[ "${TOCKMOX_P09_ROUTE:-}" = built-in ] \
  || blocked "TOCKMOX_P09_ROUTE is '${TOCKMOX_P09_ROUTE:-unset}', not built-in: the approvers watcher is installed by bootstrap-forge, so only the built-in forge route has one. Run the built-in route"

# every kubectl call below names its cluster with --context from this variable, and an empty value is
# refused rather than falling back to the current context (docs/deployment/fresh-install.md, "Name the
# cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"
REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"

STATE="${P09_STATE}/p15"
BUDGET="${TOCKMOX_P15_BUDGET:-5400}"
T0=$(date +%s)
mkdir -p "$STATE"
for t in kubectl curl python3 base64; do
  command -v "$t" >/dev/null 2>&1 || { _emit "INFRA: '$t' is not on PATH"; path_outcome INFRA_ERROR "missing $t"; exit 1; }
done

# ------------------------------------------------------------- the stock install's names
# install/bootstrap-forge.sh and install/forge-approver-watch-template.sh: the forge's namespace and release, the
# watcher's Deployment and Secret (keys forge-token, authentik-token), the identity layer's copy of the Authentik token
# (FORGE_APPROVER_WATCH_TOKEN), the admin's Secret. charts/tockmox-observability/templates/site-forge-rules.yaml: the
# group, the two alerts and CheckDown's for:. The organisation, team, repository and admin name are the ones the pages
# print (site-forge.md, identity.md).
FORGE_NS=tockmox-forge
FORGE_SVC=tockmox-forge-http
WATCH=tockmox-forge-approver-watch
WATCH_KEY=authentik-token
AK_NS=tockmox-authentik
AK_COPY=tockmox-forge-approver-watch
AK_COPY_KEY=FORGE_APPROVER_WATCH_TOKEN
ADMIN_SECRET=tockmox-forge-admin
ADMIN_USER=tockmox-admin
ADMIN_GROUP=tockmox-admins
ORG=tockmox
TEAM=approvers
REPO=site
TEAM_PATH="/org/${ORG}/teams/${TEAM}"
RULE_GROUP=tockmox.site-repository
A_OUT=TockmoxForgeApproverOutsideGroup
A_DOWN=TockmoxForgeApproversCheckDown
A_DOWN_FOR=900
PERSON="${TOCKMOX_P15_USER:-p15-approver}"
case "$PERSON" in *[!a-z0-9-]*|"") blocked "TOCKMOX_P15_USER must be lower-case letters, digits and hyphens, not '${PERSON}'" ;; esac
BRANCH="p15-approval-probe"
PROBE_FILE="p15-approval-probe.txt"
BAD_TOKEN="p15-not-a-token"
# Prometheus, read through the API server's service proxy, as P13 reads it.
PROM_NS="${TOCKMOX_P15_PROM_NS:-tockmox-monitoring}"
PROM_SVC="${TOCKMOX_P15_PROM_SVC:-prometheus-operated}"
PROM_PORT="${TOCKMOX_P15_PROM_PORT:-9090}"
FPORT="${TOCKMOX_P15_FORGE_PORT:-3015}"
# the DoD's number, and the waits; every wait is bounded
DEADLINE="${TOCKMOX_P15_DEADLINE:-120}"
ALERT_WAIT="${TOCKMOX_P15_ALERT_WAIT:-300}"
CLEAR_WAIT="${TOCKMOX_P15_CLEAR_WAIT:-300}"
SETTLE_WAIT="${TOCKMOX_P15_SETTLE_WAIT:-150}"
TOKEN_WAIT="${TOCKMOX_P15_TOKEN_WAIT:-240}"
DOWN_WAIT="${TOCKMOX_P15_DOWN_WAIT:-$((A_DOWN_FOR + 480))}"
POLL="${TOCKMOX_P15_POLL:-10}"
CYCLE="${TOCKMOX_P15_CYCLE:-90}"
PACE="${TOCKMOX_P15_PACE:-3}"

ID_PAGE="docs/administration/identity.md"
ID_PAGE_FILE="${TOCKMOX_P15_ID_PAGE_FILE:-${HERE}/../../../${ID_PAGE}}"
ID_SECTION="## The built-in forge: sign-in and approvers"
SF_PAGE="docs/administration/site-forge.md"
SF_PAGE_FILE="${TOCKMOX_P15_SF_PAGE_FILE:-${HERE}/../../../${SF_PAGE}}"
FROM_TREE="${TOCKMOX_P15_FROM_TREE:-${TOCKMOX_P09_FROM_TREE:-0}}"
EXTRACT="${HERE}/../lib/extract-block.sh"
VERDICT_PY="${HERE}/../lib/p15-approver-revocation.py"
verdict() { python3 -I "$VERDICT_PY" "$@"; }

# ------------------------------------------------------------- state helpers (P13's shape)
done_step() { [ -f "${STATE}/${1}.done" ]; }
mark_done()  { : > "${STATE}/${1}.done"; }
record() { # STEP DESC EXPECTED ACTUAL
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${STATE}/verdicts.tsv"
  if [ "$3" = "$4" ]; then _emit "RECORDED PASS: ${2}  [${4}]"
  else _emit "RECORDED FAIL: ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"; fi
}
note() { _emit "NOTE:     $*"; printf 'NOTE\t%s\n' "$*" >> "${STATE}/notes.txt"; }
budget_left() { [ $(( $(date +%s) - T0 )) -lt "$BUDGET" ]; }
yield() { _emit "BUDGET:   spent; ${1} step(s) remain. Call this path again to continue."; exit 75; }
reset_rows() {
  [ -f "${STATE}/verdicts.tsv" ] || return 0
  grep -v -- "^${1}"$'\t' "${STATE}/verdicts.tsv" > "${STATE}/verdicts.tmp" || true
  mv "${STATE}/verdicts.tmp" "${STATE}/verdicts.tsv"
}
planted_add() { grep -x -F -- "$1 $2" "${STATE}/planted.list" >/dev/null 2>&1 || printf '%s %s\n' "$1" "$2" >> "${STATE}/planted.list"; }
planted_remove() {
  [ -f "${STATE}/planted.list" ] || return 0
  grep -v -x -F -- "$1 $2" "${STATE}/planted.list" > "${STATE}/planted.tmp" || true
  mv "${STATE}/planted.tmp" "${STATE}/planted.list"
}
planted() { grep -x -F -- "$1 $2" "${STATE}/planted.list" >/dev/null 2>&1; }

# ------------------------------------------------------------- Authentik, through `ak shell` in the worker (GLUE)
WORKER=""
ak_worker() {
  [ -n "$WORKER" ] && return 0
  WORKER="$(kubectl --context="$KUBE_CONTEXT" -n "$AK_NS" get deploy -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=worker \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$WORKER" ]
}
# ak OP ... one change (or none, for read) to the planted person, then their state as one line "P15 state=..." and
# "P15 login=...". The marker comment names the operation; the real `ak shell` reads it as a comment.
ak() {
  local op="$1" act
  case "$op" in
    read) act="pass" ;;
    plant) act='u, _ = User.objects.get_or_create(username=name, defaults={"name": "P15 planted approver", "email": name + "@example.com"})
u.is_active = True
u.save()
g.users.add(u)' ;;
    remove) act='g.users.remove(User.objects.get(username=name))' ;;
    add) act='g.users.add(User.objects.get(username=name))' ;;
    deactivate) act='u = User.objects.get(username=name)
u.is_active = False
u.save()' ;;
    delete) act='User.objects.filter(username=name).delete()' ;;
    *) return 2 ;;
  esac
  ak_worker || { echo "P15 state=unreadable: no authentik worker Deployment in ${AK_NS}"; return 1; }
  kubectl --context="$KUBE_CONTEXT" -n "$AK_NS" exec "deploy/${WORKER}" -- ak shell -c "# p15-op: ${op}
from authentik.core.models import Group, User
name = \"${PERSON}\"
g = Group.objects.get(name=\"${ADMIN_GROUP}\")
${act}
u = User.objects.filter(username=name).first()
if u is None:
    print(\"P15 state=absent\")
    print(\"P15 login=none\")
else:
    print(\"P15 state=\" + (\"active\" if u.is_active else \"inactive\") + \", \" + (\"member\" if g.users.filter(pk=u.pk).exists() else \"not member\"))
    print(\"P15 login=\" + (\"none\" if u.last_login is None else str(u.last_login)))
" 2>&1
}
ak_state() { ak "$1" > "${STATE}/ak-${1}.out"; verdict ak --key state < "${STATE}/ak-${1}.out" | head -1; }

# ------------------------------------------------------------- the forge, through its API as its admin (GLUE)
PF_PID=""
PASS_ADMIN=""
forge_up() {
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null && [ "$(forge_api GET /version)" = 200 ]; then return 0; fi
  forge_down
  PASS_ADMIN="$(kubectl --context="$KUBE_CONTEXT" -n "$FORGE_NS" get secret "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
  [ -n "$PASS_ADMIN" ] || return 1
  kubectl --context="$KUBE_CONTEXT" -n "$FORGE_NS" port-forward "svc/${FORGE_SVC}" "${FPORT}:3000" > "${STATE}/port-forward.log" 2>&1 &
  PF_PID=$!
  local tries=0
  while [ "$tries" -lt 15 ]; do
    [ "$(forge_api GET /version)" = 200 ] && return 0
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}
forge_down() { [ -z "$PF_PID" ] || kill "$PF_PID" 2>/dev/null; PF_PID=""; }
# forge_api METHOD PATH [BODY [SUDO]] ... the status code on stdout, the answer in ${STATE}/forge.out. The admin's
# password goes to curl on a pipe, as the page's block passes it.
forge_api() {
  local m="$1" p="$2" body="${3:-}" sudo="${4:-}"
  local args=(-sS -o "${STATE}/forge.out" -w '%{http_code}' -X "$m" -H 'Content-Type: application/json')
  [ -z "$sudo" ] || args+=(-H "Sudo: ${sudo}")
  [ -z "$body" ] || args+=(--data-binary "$body")
  curl "${args[@]}" -K <(printf 'user = "%s:%s"\n' "$ADMIN_USER" "$PASS_ADMIN") "http://127.0.0.1:${FPORT}/api/v1${p}" 2>"${STATE}/forge.err"
}
team_id() {
  [ "$(forge_api GET "/orgs/${ORG}/teams")" = 200 ] || return 1
  python3 -I -c 'import json,sys; t=[x["id"] for x in json.load(open(sys.argv[1])) if x.get("name")==sys.argv[2]]; print(t[0] if len(t)==1 else "")' \
    "${STATE}/forge.out" "$TEAM" 2>/dev/null
}
forge_member() { # the person's place in the team: "member", "not member" or "unreadable: ..."
  local id; id="$(team_id)"
  [ -n "$id" ] || { echo "unreadable: the team ${ORG}/${TEAM} was not found once"; return; }
  [ "$(forge_api GET "/teams/${id}/members")" = 200 ] || { echo "unreadable: the team's members could not be read"; return; }
  verdict member --user "$PERSON" < "${STATE}/forge.out" | head -1
}
forge_login() { # the forge account's last sign-in, as the forge reports it
  [ "$(forge_api GET "/users/${PERSON}")" = 200 ] || { echo "unreadable: no forge account ${PERSON}"; return; }
  verdict field --name last_login < "${STATE}/forge.out" | head -1
}

# ------------------------------------------------------------- the watcher and Prometheus
watch_once() { # FILE ... one check by the watcher itself, in its own pod, with its own credentials (P09's S21c read)
  kubectl --context="$KUBE_CONTEXT" -n "$FORGE_NS" exec "deploy/${WATCH}" -- python3 /opt/watch/forge-approver-watch.py --once > "$1" 2>&1
}
watch_wait() { # STEP WANT LIMIT ... poll the watcher's own check until it reads WANT for the person. Sets WLAST, WWAITED
  local s="$1" want="$2" limit="$3" t0; t0=$(date +%s)
  while :; do
    watch_once "${STATE}/${s}.watch"
    WLAST="$(verdict watch --user "$PERSON" < "${STATE}/${s}.watch" | head -1)"
    WWAITED=$(( $(date +%s) - t0 ))
    [ "$WLAST" = "$want" ] && break
    [ "$WWAITED" -ge "$limit" ] && break
    sleep "$POLL"
  done
  note "${s}: waited ${WWAITED}s (limit ${limit}s) for the watcher's own check to read '${want}' for ${PERSON}; it read '${WLAST}'"
}
prom_read() {
  kubectl --context="$KUBE_CONTEXT" get --raw "/api/v1/namespaces/${PROM_NS}/services/${PROM_SVC}:${PROM_PORT}/proxy/api/v1/rules?type=alert" > "$1" 2> "${1}.err"
}
# alert_wait STEP ALERT WANT LIMIT [USER] ... poll Prometheus until ALERT (for USER) reads WANT or LIMIT seconds pass. Sets
# ALAST (the state last read) and AWAITED (seconds from the call); the last read is in ${STATE}/STEP.rules.json.
alert_wait() {
  local s="$1" a="$2" want="$3" limit="$4" u="${5:-}" t0; t0=$(date +%s)
  while :; do
    prom_read "${STATE}/${s}.rules.json"
    ALAST="$(verdict alert --group "$RULE_GROUP" --alert "$a" ${u:+--user "$u"} < "${STATE}/${s}.rules.json" | head -1)"
    AWAITED=$(( $(date +%s) - t0 ))
    [ "$ALAST" = "$want" ] && break
    [ "$AWAITED" -ge "$limit" ] && break
    sleep "$POLL"
  done
  note "${s}: waited ${AWAITED}s (limit ${limit}s) for ${a}${u:+ (user ${u})} to read ${want}; it read ${ALAST}"
}
# within ... the DoD's verdict on the last alert_wait: "firing within Ns", or what was read and when
within() { if [ "$ALAST" = firing ] && [ "$AWAITED" -le "$DEADLINE" ]; then echo "firing within ${DEADLINE}s"; else echo "${ALAST} after ${AWAITED}s"; fi; }

# ------------------------------------------------------------- the watcher's token (the failed read)
token_b64() { # NS SECRET KEY ... the value as the Secret holds it (base64), never decoded, never written to a file
  kubectl --context="$KUBE_CONTEXT" -n "$1" get secret "$2" -o jsonpath="{.data.${3}}" 2>/dev/null
}
token_same() { # "same", "different" or "unreadable": the watcher's copy against the identity layer's
  local a b
  a="$(token_b64 "$FORGE_NS" "$WATCH" "$WATCH_KEY")"; b="$(token_b64 "$AK_NS" "$AK_COPY" "$AK_COPY_KEY")"
  if [ -z "$a" ] || [ -z "$b" ]; then echo unreadable; elif [ "$a" = "$b" ]; then echo same; else echo different; fi
}
token_set() { # B64 ... the watcher's copy, through a pipe, so the value is on no command line
  printf '{"data":{"%s":"%s"}}' "$WATCH_KEY" "$1" \
    | kubectl --context="$KUBE_CONTEXT" -n "$FORGE_NS" patch secret "$WATCH" --type merge --patch-file=/dev/stdin > "${STATE}/token-patch.out" 2>&1
}
token_restore() { local b; b="$(token_b64 "$AK_NS" "$AK_COPY" "$AK_COPY_KEY")"; [ -n "$b" ] && token_set "$b"; }

# ------------------------------------------------------------- taking it all out
# revert_one KIND NAME ... 0 when it is gone (or was never there)
revert_one() {
  case "$1" in
    token) token_restore && [ "$(token_same)" = same ] ;;
    pr) forge_up && case "$(forge_api PATCH "/repos/${ORG}/${REPO}/pulls/${2}" '{"state":"closed"}')" in 200|201) true ;; *) false ;; esac ;;
    branch) forge_up && case "$(forge_api DELETE "/repos/${ORG}/${REPO}/branches/${2}")" in 204|404) true ;; *) false ;; esac ;;
    forge-user) forge_up && case "$(forge_api DELETE "/admin/users/${2}?purge=true")" in 204|404) true ;; *) false ;; esac ;;
    ak-user) [ "$(ak_state delete)" = absent ] ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2329  # invoked by the EXIT, TERM, INT and HUP traps set before the steps
revert_all() {
  local kind name order
  if [ -s "${STATE}/planted.list" ]; then
    for order in token pr branch forge-user ak-user; do
      while read -r kind name; do
        [ "$kind" = "$order" ] || continue
        if revert_one "$kind" "$name" >/dev/null 2>&1; then planted_remove "$kind" "$name"; fi
      done < <(cp "${STATE}/planted.list" "${STATE}/planted.copy"; cat "${STATE}/planted.copy")
    done
  fi
  forge_down
  return 0
}

# ------------------------------------------------------------- the page's block
# idblock ... identity.md's removal block, verbatim; empty on none or several
idblock() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$ID_PAGE_FILE" --section "$ID_SECTION" --lang bash --containing 'members/<their-forge-name>' 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$ID_PAGE" --section "$ID_SECTION" --lang bash --containing 'members/<their-forge-name>' 2>/dev/null; fi
}

finish_path() {
  [ "$EXEC_PHASE_COMPLETED" -eq 1 ] && printf '%s' "$EXEC_LAST_RC" > "${STATE}/last-execute-rc"
  if [ "$EXEC_PHASE_STARTED" -eq 0 ] && [ -f "${STATE}/last-execute-rc" ]; then
    execute_begin "replayed from state: the steps ran in an earlier invocation of this path (see the STEP logs above in the same report)"
    execute_end "$(cat "${STATE}/last-execute-rc")"
  fi
  _emit ""; _emit "=== REPLAY of every recorded verdict through lib/assert.sh ==========="
  local st desc exp act _replay_val
  # shellcheck disable=SC2016  # the read is a command string assert.sh evaluates later; $_replay_val must stay unexpanded here
  while IFS=$'\t' read -r st desc exp act; do
    _replay_val="$act"
    assert_artifact "[${st}] ${desc}" 'printf %s "$_replay_val"' "$exp"
  done < "${STATE}/verdicts.tsv"
  _emit ""; _emit "NOTES (from the run):"; sed 's/^NOTE\t/  - /' "${STATE}/notes.txt" 2>/dev/null | while IFS= read -r l; do _emit "$l"; done

  does_not_prove \
    "That the alert reaches a person: Prometheus's rule state is read, not Alertmanager, the alert bridge or ntfy. The rule's severity (critical) is the chart's; whether it pages is routing, not read here." \
    "A real person's history: the approver is planted, an Authentik user made with ak shell and a forge account made through the admin API and put in approvers by hand, which is the state Forgejo's group mapping leaves at a sign-in. No browser signed in as anyone." \
    "That an approval given before the removal still counts toward a merge: the pull request is never merged; only the watcher's and the alert's reading of the approval is checked." \
    "A failed read of any other kind: the one planted is a token Authentik refuses. Authentik down, the network path cut, a group that comes back empty while the team has people, and a forge read that fails are installer-test cases on stand-ins (tests/installer), not run here." \
    "That the alert fires within two minutes on every site: the time is measured once, on this throwaway, from the change in Authentik to Prometheus reading firing, and it rests on the watcher's 60 second cycle, the 30 second scrape and the rule group's evaluation interval; a site that changes any of them changes it." \
    "Membership and deactivation done in Authentik's admin interface, as identity.md says to: the same database rows are changed with ak shell, the way the admin-users Job changes them." \
    "That the install itself works: that is P09's."

  parity_caveat \
    "kubectl, curl and the page's block ran from a Linux runner against a single-node KubeVirt guest, the one P09 installed on the built-in forge route. The block ran in bash with its lines paced, not typed into the workstation shell the page is written for."

  path_finish
}

record_success_conditions "$ID_PAGE_FILE" "${ID_PAGE} @ $( [ "$FROM_TREE" = "1" ] && echo WORKTREE || echo "$REF" )"
record_success_conditions "$SF_PAGE_FILE" "${SF_PAGE} @ $( [ "$FROM_TREE" = "1" ] && echo WORKTREE || echo "$REF" )"

# ============================================================== THE STEPS
trap revert_all EXIT
trap 'revert_all; exit 143' TERM
trap 'revert_all; exit 130' INT
trap 'revert_all; exit 129' HUP

# S01 ... nothing planted: the rules are loaded and quiet, the watcher is clean, the name is free.
S=S01-before
if ! done_step "$S"; then budget_left || yield "S01+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  prom_read "${STATE}/${S}.rules.json"
  record "$S" "Prometheus has ${A_OUT} loaded from the chart's rule (group ${RULE_GROUP}), healthy, with no for:" \
    "loaded, healthy, for 0s" "$(verdict rule --group "$RULE_GROUP" --alert "$A_OUT" < "${STATE}/${S}.rules.json" | head -1)"
  record "$S" "Prometheus has ${A_DOWN} loaded, healthy, with for: ${A_DOWN_FOR}s" \
    "loaded, healthy, for ${A_DOWN_FOR}s" "$(verdict rule --group "$RULE_GROUP" --alert "$A_DOWN" < "${STATE}/${S}.rules.json" | head -1)"
  record "$S" "${A_OUT} reads inactive before anything is planted, so a firing one afterwards is this path's" \
    "inactive" "$(verdict alert --group "$RULE_GROUP" --alert "$A_OUT" < "${STATE}/${S}.rules.json" | head -1)"
  record "$S" "${A_DOWN} reads inactive before anything is planted" \
    "inactive" "$(verdict alert --group "$RULE_GROUP" --alert "$A_DOWN" < "${STATE}/${S}.rules.json" | head -1)"
  watch_once "${STATE}/${S}.watch"
  record "$S" "the watcher's own check is clean and does not name ${PERSON}" "clean, not outside" "$(verdict watch --user "$PERSON" < "${STATE}/${S}.watch" | head -1)"
  record "$S" "the watcher's Authentik token is the identity layer's (one value in two Secrets), so S05 can put it back from there" "same" "$(token_same)"
  record "$S" "no Authentik user is called ${PERSON} yet" "absent" "$(ak_state read)"
  if forge_up; then v=reached; else v="not reached: $(tail -c 200 "${STATE}/port-forward.log" 2>/dev/null | tr '\n' ' ')"; fi
  record "$S" "GLUE: the forge's API answers its admin through a port-forward, as the page's block reaches it" "reached" "$v"
  record "$S" "no forge account is called ${PERSON} yet" "404" "$(forge_api GET "/users/${PERSON}")"
  mark_done "$S"
fi

# S02 ... plant an approver who is also an admin: the watcher must say nothing.
S=S02-plant
if ! done_step "$S"; then budget_left || yield "S02+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "GLUE: no page makes an approver; Forgejo's group mapping does at a sign-in. Planted: Authentik user ${PERSON} in ${ADMIN_GROUP}, a forge account of that name in ${ORG}/${TEAM}, and an open pull request on ${ORG}/${REPO} that carries their approval"
  execute_begin "GLUE: plant an approver who is in ${ADMIN_GROUP}"
  planted_add ak-user "$PERSON"
  v="$(ak_state plant)"
  record "$S" "Authentik: ${PERSON} is active and in ${ADMIN_GROUP}" "active, member" "$v"
  rc=1
  if forge_up; then
    planted_add forge-user "$PERSON"
    pw="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(24) + "Aa1-")')"
    c1="$(forge_api POST /admin/users "{\"username\":\"${PERSON}\",\"email\":\"${PERSON}@example.com\",\"password\":\"${pw}\",\"must_change_password\":false,\"login_name\":\"${PERSON}\",\"source_id\":0}")"
    pw=""
    tid="$(team_id)"
    c2="no team"; [ -z "$tid" ] || c2="$(forge_api PUT "/teams/${tid}/members/${PERSON}")"
    planted_add branch "$BRANCH"
    c3="$(forge_api POST "/repos/${ORG}/${REPO}/contents/${PROBE_FILE}" "{\"content\":\"$(printf 'planted by executed-docs P15; never merged\n' | base64 | tr -d '\n')\",\"message\":\"P15: a change for a planted approval (never merged)\",\"branch\":\"main\",\"new_branch\":\"${BRANCH}\"}")"
    c4="$(forge_api POST "/repos/${ORG}/${REPO}/pulls" "{\"head\":\"${BRANCH}\",\"base\":\"main\",\"title\":\"P15: a planted approval (never merged)\"}")"
    PR="$(verdict field --name number < "${STATE}/forge.out" | head -1)"
    case "$PR" in ''|*[!0-9]*) PR="" ;; *) planted_add pr "$PR"; printf '%s' "$PR" > "${STATE}/pr" ;; esac
    c5="no pull request"; [ -z "$PR" ] || c5="$(forge_api POST "/repos/${ORG}/${REPO}/pulls/${PR}/reviews" '{"event":"APPROVED","body":"P15: a planted approval"}' "$PERSON")"
    record "$S" "GLUE: the forge made the account (201), put it in ${TEAM} (204), made the branch (201) and the pull request (201), and took the approval as ${PERSON}'s (200)" \
      "201 204 201 201 200" "${c1} ${c2} ${c3} ${c4} ${c5}"
    [ "${c1} ${c2} ${c3} ${c4} ${c5}" = "201 204 201 201 200" ] && rc=0
  else
    record "$S" "GLUE: the forge's API answers its admin" "reached" "not reached"
  fi
  execute_end "$rc"
  PR="$(cat "${STATE}/pr" 2>/dev/null || true)"
  if [ -n "$PR" ] && [ "$(forge_api GET "/repos/${ORG}/${REPO}/pulls/${PR}/reviews")" = 200 ]; then v="$(verdict review --user "$PERSON" < "${STATE}/forge.out" | head -1)"; else v="unreadable"; fi
  record "$S" "the forge holds a standing approval from ${PERSON} on pull request #${PR:-none}" "standing approval" "$v"
  record "$S" "the forge has ${PERSON} in ${TEAM}" "member" "$(forge_member)"
  forge_login > "${STATE}/forge-login-before"
  verdict ak --key login < "${STATE}/ak-plant.out" | head -1 > "${STATE}/ak-login-before"
  # A person in both is nobody to judge: read the watcher, then wait one full cycle and a scrape and read the alert.
  watch_wait "$S" "clean, not outside" "$SETTLE_WAIT"
  record "$S" "the watcher's own check is clean and does not name ${PERSON}, who is in both" "clean, not outside" "$WLAST"
  sleep "$CYCLE"
  prom_read "${STATE}/${S}.rules.json"
  record "$S" "${A_OUT} does not fire for ${PERSON} while they are an active admin (read after a watcher cycle and a scrape)" \
    "inactive" "$(verdict alert --group "$RULE_GROUP" --alert "$A_OUT" --user "$PERSON" < "${STATE}/${S}.rules.json" | head -1)"
  mark_done "$S"
fi
PR="$(cat "${STATE}/pr" 2>/dev/null || true)"
PLANTED=0; [ -f "${STATE}/S02-plant.done" ] && planted ak-user "$PERSON" && planted forge-user "$PERSON" && [ -n "$PR" ] && PLANTED=1

# S03 ... out of the admin group, still an approver: alerted within two minutes, team and pull request named.
S=S03-remove
if ! done_step "$S"; then
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ "$PLANTED" = 1 ]; then
    _emit "GLUE: identity.md 'Day-to-day administration': removing someone is removing their group membership, in Authentik's admin interface; no command is printed"
    execute_begin "GLUE: take ${PERSON} out of ${ADMIN_GROUP}"
    v="$(ak_state remove)"; execute_end 0
    record "$S" "Authentik: ${PERSON} is active and no longer in ${ADMIN_GROUP}" "active, not member" "$v"
    alert_wait "$S" "$A_OUT" firing "$ALERT_WAIT" "$PERSON"
    record "$S" "row 1: ${A_OUT} fires for ${PERSON} within ${DEADLINE}s of the removal" "firing within ${DEADLINE}s" "$(within)"
    record "$S" "row 1: its description names the approvers team (${TEAM_PATH}) and the pull request their approval stands on" \
      "names the team and #${PR}" "$(verdict annotation --group "$RULE_GROUP" --alert "$A_OUT" --user "$PERSON" --team "$TEAM_PATH" --pr "$PR" < "${STATE}/${S}.rules.json" | head -1)"
    watch_once "${STATE}/${S}.watch"
    record "$S" "the watcher's own check names the same pull request" "#${PR}" "$(verdict watch-prs --user "$PERSON" < "${STATE}/${S}.watch" | head -1)"
    record "$S" "${PERSON} never signed in to the forge: its account's last sign-in is unchanged since the plant" "$(cat "${STATE}/forge-login-before")" "$(forge_login)"
    ak_state read > /dev/null
    record "$S" "${PERSON} never signed in to Authentik" "none" "$(verdict ak --key login < "${STATE}/ak-read.out" | head -1)"
  else
    record "$S" "S02 planted the approver this step removes" "planted" "not planted"
  fi
  mark_done "$S"
fi

# S04 ... back in the group: it stops. Deactivated: it fires again.
S=S04-deactivate
if ! done_step "$S"; then
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ "$PLANTED" = 1 ]; then
    v="$(ak_state add)"
    record "$S" "GLUE: Authentik: ${PERSON} is in ${ADMIN_GROUP} again" "active, member" "$v"
    alert_wait "$S" "$A_OUT" inactive "$CLEAR_WAIT" "$PERSON"
    record "$S" "${A_OUT} stops for ${PERSON} once the team matches the group again (site-forge.md)" "inactive" "$ALAST"
    _emit "GLUE: identity.md 'Day-to-day administration': or deactivating the user, in Authentik's admin interface; no command is printed"
    v="$(ak_state deactivate)"
    record "$S" "Authentik: ${PERSON} is deactivated and still in ${ADMIN_GROUP}" "inactive, member" "$v"
    alert_wait "$S" "$A_OUT" firing "$ALERT_WAIT" "$PERSON"
    record "$S" "row 2: a deactivated account counts as removed: ${A_OUT} fires for ${PERSON} within ${DEADLINE}s" "firing within ${DEADLINE}s" "$(within)"
  else
    record "$S" "S02 planted the approver this step deactivates" "planted" "not planted"
  fi
  mark_done "$S"
fi

# S05 ... a read that fails: nobody is judged, CheckDown fires. Put back: CheckDown stops, the person's alert returns.
S=S05-failed-read
if ! done_step "$S"; then
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ "$PLANTED" = 1 ]; then
    _emit "GLUE: the watcher's copy of its Authentik token (Secret ${FORGE_NS}/${WATCH}, key ${WATCH_KEY}) becomes '${BAD_TOKEN}'; it is put back from ${AK_NS}/${AK_COPY}"
    planted_add token "$WATCH"
    token_set "$(printf '%s' "$BAD_TOKEN" | base64 | tr -d '\n')"
    record "$S" "GLUE: the watcher's copy of the token is no longer the identity layer's" "different" "$(token_same)"
    watch_wait "$S" "not clean, nobody judged" "$TOKEN_WAIT"
    record "$S" "row 3: the watcher's own check is not clean, and it judges nobody (no per-person series, no count)" "not clean, nobody judged" "$WLAST"
    alert_wait "$S" "$A_OUT" inactive "$CLEAR_WAIT" "$PERSON"
    record "$S" "row 3: ${A_OUT} stops for ${PERSON} while the read fails, though they are still deactivated: an outage is never read as a removal" "inactive" "$ALAST"
    alert_wait "$S" "$A_DOWN" firing "$DOWN_WAIT"
    record "$S" "row 3: ${A_DOWN} fires within its for: (${A_DOWN_FOR}s) and a margin" "firing" "$ALAST"
    token_restore
    record "$S" "GLUE: the watcher's copy of the token is the identity layer's again" "same" "$(token_same)"
    [ "$(token_same)" = same ] && planted_remove token "$WATCH"
    watch_wait "$S" "clean, outside" "$TOKEN_WAIT"
    record "$S" "with the token back, the watcher's own check is clean and names ${PERSON} again" "clean, outside" "$WLAST"
    alert_wait "$S" "$A_DOWN" inactive "$CLEAR_WAIT"
    record "$S" "${A_DOWN} stops once the check is clean" "inactive" "$ALAST"
    alert_wait "$S" "$A_OUT" firing "$ALERT_WAIT" "$PERSON"
    record "$S" "${A_OUT} fires for ${PERSON} again within ${DEADLINE}s of a clean check" "firing within ${DEADLINE}s" "$(within)"
  else
    record "$S" "S02 planted the approver whose alert this step reads" "planted" "not planted"
  fi
  mark_done "$S"
fi

# S06 ... the page's removal: 204, out of approvers, the alert stops.
S=S06-page-removal
if ! done_step "$S"; then
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ "$PLANTED" = 1 ]; then
    idblock > "${STATE}/block.sh"
    if [ -s "${STATE}/block.sh" ]; then
      provenance "$( [ "$FROM_TREE" = "1" ] && echo WORKTREE || echo "$REF" )" "$ID_PAGE" "${ID_SECTION}, the bash block containing 'members/<their-forge-name>'" "-" \
        "$(sha256sum < "${STATE}/block.sh" | cut -d' ' -f1)"
      verbatim "$(cat "${STATE}/block.sh")"
      record "$S" "the page's block holds the two placeholders the path fills, once and twice" "1 2" \
        "$(grep -o '<their-forge-name>' "${STATE}/block.sh" | wc -l | tr -d ' ') $(grep -o '<your-cluster>' "${STATE}/block.sh" | wc -l | tr -d ' ')"
      _emit "SUBSTITUTION: <your-cluster> -> ${KUBE_CONTEXT}; <their-forge-name> -> ${PERSON}  (the page: '<their-forge-name> is their Authentik username')"
      _emit "GLUE: the lines run one at a time with ${PACE}s between them, as a reader enters them, then the page's 'Stop the port-forward afterwards (kill %1)'"
      # shellcheck disable=SC2016  # the exit line is for the block's own shell: ${P15_RC} must stay unexpanded here
      { sed -e "s|<your-cluster>|${KUBE_CONTEXT}|g" -e "s|<their-forge-name>|${PERSON}|g" "${STATE}/block.sh" | verdict pace --seconds "$PACE"
        printf '\nkill %%1 2>/dev/null\nexit "${P15_RC:-0}"\n'; } > "${STATE}/block.run.sh"
      execute_begin "identity.md: remove ${PERSON} from the forge's ${ORG} organisation"
      bash "${STATE}/block.run.sh" > "${STATE}/${S}.out" 2>&1
      execute_end $?
      sed 's/^/    | /' "${STATE}/${S}.out" | while IFS= read -r l; do _emit "$l"; done
      record "$S" "row 4: the page's success condition, 'It prints 204'" "204" "$(grep -E '^[0-9]{3}$' "${STATE}/${S}.out" | tail -1)"
      record "$S" "the forge no longer has ${PERSON} in ${TEAM}" "not member" "$(forge_member)"
      watch_wait "$S" "clean, not outside" "$SETTLE_WAIT"
      record "$S" "the watcher's own check is clean and no longer names ${PERSON}" "clean, not outside" "$WLAST"
      alert_wait "$S" "$A_OUT" inactive "$CLEAR_WAIT" "$PERSON"
      record "$S" "row 4: ${A_OUT} stops for ${PERSON} once they are out of the team" "inactive" "$ALAST"
    else
      record "$S" "the page's removal block resolves" "one block" "missing or ambiguous"
    fi
  else
    record "$S" "S02 planted the approver this step removes from the forge" "planted" "not planted"
  fi
  mark_done "$S"
fi

# S07 ... take it all out, and read each back as gone.
S=S07-revert
reset_rows "$S"
_emit ""; _emit "=== STEP ${S} =============================================="
if planted token "$WATCH"; then
  revert_one token "$WATCH" >/dev/null 2>&1 && planted_remove token "$WATCH"
fi
record "$S" "revert: the watcher's Authentik token is the identity layer's" "same" "$(token_same)"
if [ -n "$PR" ]; then
  revert_one pr "$PR" >/dev/null 2>&1
  if forge_up && [ "$(forge_api GET "/repos/${ORG}/${REPO}/pulls/${PR}")" = 200 ]; then v="$(verdict field --name state < "${STATE}/forge.out" | head -1)"; else v=unreadable; fi
  record "$S" "revert: pull request #${PR} is closed, never merged" "closed false" "${v} $(verdict field --name merged < "${STATE}/forge.out" | head -1)"
  [ "$v" = closed ] && planted_remove pr "$PR"
fi
if planted branch "$BRANCH"; then
  revert_one branch "$BRANCH" >/dev/null 2>&1
  v="$(forge_api GET "/repos/${ORG}/${REPO}/branches/${BRANCH}")"
  record "$S" "revert: the branch ${BRANCH} is gone from ${ORG}/${REPO}" "404" "$v"
  [ "$v" = 404 ] && planted_remove branch "$BRANCH"
fi
if planted forge-user "$PERSON"; then
  revert_one forge-user "$PERSON" >/dev/null 2>&1
  v="$(forge_api GET "/users/${PERSON}")"
  record "$S" "revert: the forge account ${PERSON} is gone" "404" "$v"
  [ "$v" = 404 ] && planted_remove forge-user "$PERSON"
fi
if planted ak-user "$PERSON"; then
  v="$(ak_state delete)"
  record "$S" "revert: the Authentik user ${PERSON} is gone" "absent" "$v"
  [ "$v" = absent ] && planted_remove ak-user "$PERSON"
fi
forge_down
watch_once "${STATE}/${S}.watch"
record "$S" "after the revert the watcher's own check is clean and names nobody new" "clean, not outside" "$(verdict watch --user "$PERSON" < "${STATE}/${S}.watch" | head -1)"

finish_path
exit $?

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P13 ... what a restore drill says when it is made to fail. Runs LAST in the p09 lane, after P11 (and after
# any path between), on the same throwaway and the same state directory, only when P09 ended PASS. P11 shows the
# drills PASS on a healthy install; this path plants one fault at a time on that same install, shows the failure
# arrive where the charts say it does, and takes the fault out again. It breaks things on purpose, so it is the one
# path here that must leave the cluster as it found it, and it asserts that it did.
#
#   S01  A ResourceQuota that refuses the identity drill's recovery cluster. The quota limits the NUMBER of
#        clusters.postgresql.cnpg.io in the drill's namespace to 0, so the drill's `kubectl apply` of its recovery
#        cluster is refused at admission. Asserted: the Job started from the drill CronJob ends Failed and never
#        Complete; no recovery cluster was created; the log records no PASS; the drill's own `apply:` line and the
#        FAIL row it writes both name the quota refusal; the FAIL row was recorded in the register. Then the quota
#        and the Job are removed and each is read back as gone.
#   S02  A drill that cannot write its register row. The Job for the model gateway's drill is made from the
#        CronJob's own template with ONE env value changed (REG_BUCKET, a bucket that does not exist), so the restore
#        itself runs and passes and the register write is refused. Asserted: the Job ends Failed; the log shows a
#        PASS row, a "register: NOT RECORDED" line naming the write that was refused, and no recorded object; and
#        Prometheus's rule TockmoxRestoreDrillFailed reads inactive before, FIRING within its for: plus the
#        evaluation interval and a margin, and inactive again after the Job is removed. Then the Job is removed and
#        read back as gone, and so is the drill's recovery cluster.
#
# THE ALERTS THAT ARE NOT HERE, and why, are in the design list printed by does_not_prove below: TockmoxLiteLLMDown
# is in a group that is off by default and needs a values change in the site repository, TockmoxLokiNotIngesting
# cannot fire in under about 25 minutes and ArgoCD would undo the fault, and the TSDB trough alert reads a 3 day
# window.
#
# Nothing here is a page block. The objects are made with kubectl, with this harness's --context on every call.
# The verdicts are lib/p09-recovery.py's, shown red one mutation at a time by fault-rows-test.sh, which needs no
# cluster.
#
# EVERY FAULT IS REVERTED, TWICE OVER. Each step ends with an always-run revert that deletes what it planted and
# READS THE LIST BACK to record that the object is gone (a revert that cannot be seen to work is not one). A
# planted object is written to ${STATE}/planted.list before it is made and struck from it only once it is read back
# as absent, and an EXIT, TERM, INT and HUP trap deletes whatever is still listed, so a path that dies in the
# middle of a wait still leaves a usable VM.
#
# WHEN IT RUNS. run.sh discovers paths/P*.sh and gives this one P09's route group, so a plain run.sh reaches it. It
# does not run there. It needs TOCKMOX_P09_STATE (the state directory of a P09 run on this cluster), a marker in it
# that P09 ended PASS (p09-lane.sh writes it), and root-applied-at. Any of the three missing is BLOCKED with the
# reason, with no cluster call of its own.
#
# ITS OWN STATE AND BUDGET. State goes under ${TOCKMOX_P09_STATE}/p13. TOCKMOX_P13_BUDGET (seconds, default 2700)
# is checked before each step starts, never inside one: a step that has planted a fault runs to its revert. Past it,
# with steps remaining, the path exits 75 before planting anything.
#
# TIME, worst case, from the waits below (each is bounded and each wait is recorded with how long it took):
#   S01   quota counted 90s + Job ends 240s + two reverts 45s each                          about 7 minutes
#   S02   Job ends 480s + alert firing 1020s + Job gone 45s + cluster gone 60s + alert clear 420s   about 34 minutes
#   The alert's wait is its for: (600s) + the group's evaluation interval (300s) + the scrape (30s) + 90s of margin.
#   TOCKMOX_P13_ALERT=0 leaves out the Prometheus reads and waits and bounds the rest at about 17 minutes.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null  # lib/assert.sh, resolved from this script's own directory at run time
. "${HERE}/../lib/assert.sh"

path_begin "P13-planted-faults" \
  "after P11: a quota that refuses a restore drill, and a drill that cannot record its row; each fault read, then reverted and read back as gone"

# install_time_ok VALUE ... true for a whole number of seconds above zero, the only thing "after the install" can be measured from
install_time_ok() {
  case "${1:-}" in ""|*[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -gt 0 ]
}

# --- preconditions: a declared environmental constraint (BLOCKED), not a failure and not silence ---
P09_STATE="${TOCKMOX_P09_STATE:-}"
blocked() { # REASON
  _emit "BLOCKED:  ${1}"
  _emit "          This path runs after P09, on the same cluster, from P09's state directory (see the header)."
  path_outcome BLOCKED "$1"
  exit 0
}
[ -n "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not set, so there is no P09 install on this cluster to break"
[ -d "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not a directory (${P09_STATE})"
[ -f "${P09_STATE}/p09-passed" ] || blocked "P09 did not end PASS on this state directory (no p09-passed marker in it)"
ROOT_APPLIED="$(cat "${P09_STATE}/root-applied-at" 2>/dev/null || true)"
install_time_ok "$ROOT_APPLIED" || blocked "root-applied-at is missing or not a positive number of seconds in ${P09_STATE} (found [${ROOT_APPLIED}]); this path breaks an install, and without the install time it cannot tell that there is one"

# every kubectl call below names its cluster with --context from this variable, and an empty value is
# refused rather than falling back to the current context (docs/deployment/fresh-install.md, "Name the
# cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

STATE="${P09_STATE}/p13"
BUDGET="${TOCKMOX_P13_BUDGET:-2700}"
T0=$(date +%s)
mkdir -p "$STATE"
for t in kubectl python3; do
  command -v "$t" >/dev/null 2>&1 || { _emit "INFRA: '$t' is not on PATH"; path_outcome INFRA_ERROR "missing $t"; exit 1; }
done

# ------------------------------------------------------------- the stock install's names
# Namespaces, CronJobs and cluster names are the ones P11 used and proved live. The register bucket likewise.
# charts/tockmox-identity/templates/restore-drill.yaml and charts/tockmox-ai/templates/restore-drill.yaml:
# the container is named drill (line 131) and takes REG_BUCKET from the env block that
# charts/tockmox-common/templates/_drill-register.tpl builds (line 41).
IDENTITY_NS=tockmox-authentik
IDENTITY_CRON=tockmox-authentik-db-drill
IDENTITY_DB=tockmox-authentik-db
AI_NS=tockmox-ai
AI_CRON=tockmox-litellm-db-drill
AI_DB=tockmox-litellm-db
DRILL_BUCKET=tockmox-drill-register
DRILL_CONTAINER=drill
QUOTA_NAME=tockmox-p13-refuse-drill
QUOTA_KEY=count/clusters.postgresql.cnpg.io
QUOTA_TEXT="exceeded quota"
FAULT_BUCKET=p13-no-such-bucket
Q_JOB="${IDENTITY_CRON}-p13quota"
R_JOB="${AI_CRON}-p13reg"
# The alert: group name restore-drill.yaml line 308 (identity: tockmox.identity.restore-drill, line 316), alert
# name line 375, for: 10m line 408. The two charts' alerts carry the same name and no per-database label.
RULE_GROUP=tockmox.ai.restore-drill
ALERT=TockmoxRestoreDrillFailed
ALERT_FOR=600
# Prometheus, read through the API server's service proxy. The operator makes the headless Service
# prometheus-operated for every Prometheus it runs; the namespace is namespaces.monitoring in
# charts/tockmox-observability/values.yaml line 42.
PROM_NS="${TOCKMOX_P13_PROM_NS:-tockmox-monitoring}"
PROM_SVC="${TOCKMOX_P13_PROM_SVC:-prometheus-operated}"
PROM_PORT="${TOCKMOX_P13_PROM_PORT:-9090}"
# waits, in seconds; every one is bounded
QUOTA_WAIT="${TOCKMOX_P13_QUOTA_WAIT:-90}"
QUOTA_JOB_WAIT="${TOCKMOX_P13_QUOTA_JOB_WAIT:-240}"
DRILL_JOB_WAIT="${TOCKMOX_P13_DRILL_JOB_WAIT:-480}"
ALERT_WAIT="${TOCKMOX_P13_ALERT_WAIT:-1020}"
CLEAR_WAIT="${TOCKMOX_P13_CLEAR_WAIT:-420}"
GONE_WAIT="${TOCKMOX_P13_GONE_WAIT:-45}"
CLUSTER_WAIT="${TOCKMOX_P13_CLUSTER_WAIT:-60}"
POLL="${TOCKMOX_P13_POLL:-10}"
ALERT_POLL="${TOCKMOX_P13_ALERT_POLL:-30}"
WITH_ALERT="${TOCKMOX_P13_ALERT:-1}"

# ------------------------------------------------------------- state helpers
# The same shape as P11's: a step is skipped once done, a verdict is written to verdicts.tsv as it is made and
# replayed through assert_artifact at the end, and a spent budget exits 75 so the path is called again.
done_step() { [ -f "${STATE}/${1}.done" ]; }
mark_done()  { : > "${STATE}/${1}.done"; }
# record STEP DESC EXPECTED ACTUAL [xfail] ... one line per verdict, replayed at the end
record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "${STATE}/verdicts.tsv"
  if [ "${5:-}" = "xfail" ]; then
    _emit "RECORDED (xfail): ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"
  elif [ "$3" = "$4" ]; then _emit "RECORDED PASS: ${2}  [${4}]"
  else _emit "RECORDED FAIL: ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"; fi
}
note() { _emit "NOTE:     $*"; printf 'NOTE\t%s\n' "$*" >> "${STATE}/notes.txt"; }
budget_left() { [ $(( $(date +%s) - T0 )) -lt "$BUDGET" ]; }
yield() { _emit "BUDGET:   spent; ${1} step(s) remain. Call this path again to continue."; exit 75; }
# reset_rows STEP ... drop the rows and notes of an earlier attempt at this step that never finished, so a second try writes each row once
reset_rows() {
  [ -f "${STATE}/verdicts.tsv" ] || return 0
  grep -v -- "^${1}"$'\t' "${STATE}/verdicts.tsv" > "${STATE}/verdicts.tmp" || true
  mv "${STATE}/verdicts.tmp" "${STATE}/verdicts.tsv"
}
recovery_verdict() {
  python3 -I "${HERE}/../lib/p09-recovery.py" "$@"
}

# ------------------------------------------------------------- the planted list, the revert and the read-back
# planted_add KIND NS NAME ... written BEFORE the object is made, so an apply that dies half way is still reverted
planted_add() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${STATE}/planted.list"; }
planted_remove() {
  [ -f "${STATE}/planted.list" ] || return 0
  grep -v -x -F -- "$1 $2 $3" "${STATE}/planted.list" > "${STATE}/planted.tmp" || true
  mv "${STATE}/planted.tmp" "${STATE}/planted.list"
}
# delete_planted KIND NS NAME ... the one place an object is deleted; 0 when it is gone or was never there
delete_planted() {
  case "$1" in
    job) kubectl --context="$KUBE_CONTEXT" -n "$2" delete job "$3" --ignore-not-found --timeout=120s ;;
    quota) kubectl --context="$KUBE_CONTEXT" -n "$2" delete resourcequota "$3" --ignore-not-found --timeout=120s ;;
    cluster) kubectl --context="$KUBE_CONTEXT" -n "$2" delete cluster.postgresql.cnpg.io "$3" --ignore-not-found --timeout=120s ;;
    *) return 1 ;;
  esac
}
# read_list KIND NS ... the objects of that kind in the namespace, as a JSON list on stdout
read_list() {
  case "$1" in
    job) kubectl --context="$KUBE_CONTEXT" -n "$2" get jobs -o json ;;
    quota) kubectl --context="$KUBE_CONTEXT" -n "$2" get resourcequotas -o json ;;
    cluster) kubectl --context="$KUBE_CONTEXT" -n "$2" get clusters.postgresql.cnpg.io -o json ;;
    cronjob) kubectl --context="$KUBE_CONTEXT" -n "$2" get cronjobs -o json ;;
    *) return 1 ;;
  esac
}
kind_of() { case "$1" in job) echo Job ;; quota) echo ResourceQuota ;; cluster) echo Cluster ;; cronjob) echo CronJob ;; esac; }
# absent_verdict KIND NS NAME ... "absent", "present", or "unreadable: ..." when the list could not be read
absent_verdict() {
  read_list "$1" "$2" 2>/dev/null | recovery_verdict absent --kind "$(kind_of "$1")" --name "$3" | head -1
}
# revert_object STEP KIND NS NAME DESC ... delete it, then read the list back until it is absent or GONE_WAIT passes
revert_object() {
  local s="$1" kind="$2" ns="$3" name="$4" desc="$5" v t0 wait="${6:-$GONE_WAIT}"
  delete_planted "$kind" "$ns" "$name" > "${STATE}/${s}.revert-${kind}-${name}" 2>&1
  t0=$(date +%s)
  while :; do
    v="$(absent_verdict "$kind" "$ns" "$name")"
    [ "$v" = absent ] && break
    [ $(( $(date +%s) - t0 )) -ge "$wait" ] && break
    sleep 3
  done
  record "$s" "revert: ${desc} ${name} is gone from ${ns}" "absent" "$v"
  if [ "$v" = absent ]; then planted_remove "$kind" "$ns" "$name"; fi
}
# shellcheck disable=SC2329  # invoked by the EXIT, TERM, INT and HUP traps set before the steps
# revert_all ... the safety net: delete whatever the list still holds. Idempotent, and silent when the list is empty.
revert_all() {
  local kind ns name
  [ -s "${STATE}/planted.list" ] || return 0
  cp "${STATE}/planted.list" "${STATE}/planted.copy"
  while read -r kind ns name; do
    [ -n "$name" ] || continue
    if delete_planted "$kind" "$ns" "$name" >/dev/null 2>&1; then planted_remove "$kind" "$ns" "$name"; fi
  done < "${STATE}/planted.copy"
  return 0
}

# ------------------------------------------------------------- Prometheus, through the API server
# prom_read FILE ... the alerting rules and their state. `get --raw` is a GET of that path on the API server, which proxies
# to the Service; nothing is written and nothing is exposed.
prom_read() {
  kubectl --context="$KUBE_CONTEXT" get --raw "/api/v1/namespaces/${PROM_NS}/services/${PROM_SVC}:${PROM_PORT}/proxy/api/v1/rules?type=alert" > "$1" 2> "${1}.err"
}
# alert_wait WANT LIMIT FILE ... poll until the alert reads WANT or LIMIT seconds pass, or Prometheus cannot be read six polls
# in a row. Sets ALERT_LAST (the last state read) and ALERT_WAITED (seconds spent). Returns 0 when WANT was read.
alert_wait() {
  local want="$1" limit="$2" f="$3" t0 bad=0
  t0=$(date +%s)
  while :; do
    prom_read "$f"
    ALERT_LAST="$(recovery_verdict alert-state --group "$RULE_GROUP" --alert "$ALERT" < "$f" | head -1)"
    ALERT_WAITED=$(( $(date +%s) - t0 ))
    [ "$ALERT_LAST" = "$want" ] && return 0
    case "$ALERT_LAST" in unreadable*) bad=$((bad+1)) ;; *) bad=0 ;; esac
    [ "$bad" -ge 6 ] && return 1
    [ "$ALERT_WAITED" -ge "$limit" ] && return 1
    sleep "$ALERT_POLL"
  done
}
# job_wait NS JOB FILE LIMIT ... poll the Job until it is Failed or Complete or LIMIT seconds pass; leaves the last read in FILE
JOB_WAITED=0
job_wait() {
  local ns="$1" job="$2" f="$3" limit="$4" t0 v
  t0=$(date +%s)
  while :; do
    kubectl --context="$KUBE_CONTEXT" -n "$ns" get job "$job" -o json > "$f" 2>/dev/null
    v="$(recovery_verdict job-not-complete < "$f" | head -1)"
    JOB_WAITED=$(( $(date +%s) - t0 ))
    case "$v" in "still running"*) ;; *) return 0 ;; esac
    [ "$JOB_WAITED" -ge "$limit" ] && return 1
    sleep "$POLL"
  done
}

# ---- S01 ... a quota that refuses the drill's recovery cluster -------------------------------------------
step_quota() {
  local s=S01-quota ns="$IDENTITY_NS" v ok=1 t0 cluster="${IDENTITY_DB}-drillcheck"
  reset_rows "$s"
  _emit ""; _emit "=== STEP ${s} =============================================="
  _emit "SOURCE:   no page block. A ResourceQuota on the number of ${QUOTA_KEY} in ${ns}, then a Job from the ${IDENTITY_CRON} CronJob (profiles.md \"Run the first drill\")"
  v="$(absent_verdict cronjob "$ns" "$IDENTITY_CRON")"
  record "$s" "the drill CronJob ${IDENTITY_CRON} exists in ${ns}, so there is a drill to make fail" "present" "$v"
  [ "$v" = present ] || ok=0
  if [ "$ok" = 1 ]; then
    execute_begin "plant a ResourceQuota that allows no ${QUOTA_KEY} in ${ns}"
    planted_add quota "$ns" "$QUOTA_NAME"
    kubectl --context="$KUBE_CONTEXT" -n "$ns" apply -f - > "${STATE}/${s}.plant" 2>&1 <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${QUOTA_NAME}
  namespace: ${ns}
  annotations:
    tockmox.com/planted-by: "executed-docs P13, removed when the path ends"
spec:
  hard:
    ${QUOTA_KEY}: "0"
EOF
    execute_end $?
    _emit "    | $(tr '\n' ' ' < "${STATE}/${s}.plant")"
    # An admission that has no count for the resource yet refuses with "status unknown", not with the quota's own
    # wording, so wait until the quota controller has counted before the drill is started.
    t0=$(date +%s)
    while :; do
      kubectl --context="$KUBE_CONTEXT" -n "$ns" get resourcequota "$QUOTA_NAME" -o json > "${STATE}/${s}.quota.json" 2>/dev/null
      v="$(recovery_verdict quota-enforced --name "$QUOTA_NAME" --key "$QUOTA_KEY" < "${STATE}/${s}.quota.json" | head -1)"
      [ "$v" = enforced ] && break
      [ $(( $(date +%s) - t0 )) -ge "$QUOTA_WAIT" ] && break
      sleep 3
    done
    note "${s}: waited $(( $(date +%s) - t0 ))s (limit ${QUOTA_WAIT}s) for the quota controller to count ${QUOTA_KEY}; it read: ${v}"
    record "$s" "the planted quota is counting ${QUOTA_KEY} in ${ns} before the drill starts" "enforced" "$v"
    [ "$v" = enforced ] || ok=0
  fi
  if [ "$ok" = 1 ]; then
    execute_begin "profiles.md Run the first drill: create job --from=cronjob/${IDENTITY_CRON}, with the quota in force"
    planted_add job "$ns" "$Q_JOB"
    kubectl --context="$KUBE_CONTEXT" -n "$ns" create job --from="cronjob/${IDENTITY_CRON}" "$Q_JOB" > "${STATE}/${s}.create" 2>&1
    execute_end $?
    _emit "    | $(cat "${STATE}/${s}.create")"
    job_wait "$ns" "$Q_JOB" "${STATE}/${s}.job.json" "$QUOTA_JOB_WAIT"
    note "${s}: waited ${JOB_WAITED}s (limit ${QUOTA_JOB_WAIT}s) for the drill Job ${Q_JOB} to end"
    kubectl --context="$KUBE_CONTEXT" -n "$ns" logs "job/${Q_JOB}" > "${STATE}/${s}.log" 2>&1
    _emit "    the drill's log, last lines:"
    tail -n 8 "${STATE}/${s}.log" | sed 's/^/    | /' | while IFS= read -r l; do _emit "$l"; done
    kubectl --context="$KUBE_CONTEXT" -n "$ns" get clusters.postgresql.cnpg.io -o json > "${STATE}/${s}.clusters.json" 2>/dev/null
    record "$s" "quota refusal: the drill Job ends Failed and never reaches Complete" \
      "Failed, never Complete" "$(recovery_verdict job-not-complete < "${STATE}/${s}.job.json" | head -1)"
    record "$s" "quota refusal: the drill's recovery cluster ${cluster} was never created" \
      "absent" "$(recovery_verdict absent --kind Cluster --name "$cluster" < "${STATE}/${s}.clusters.json" | head -1)"
    record "$s" "quota refusal: the log records no PASS, row or object" \
      "no PASS recorded" "$(recovery_verdict drill-no-pass --allow-row no < "${STATE}/${s}.log" | head -1)"
    record "$s" "quota refusal: the drill's own apply: line and its FAIL row both name the refusal (\"${QUOTA_TEXT}\")" \
      "refusal named in the apply output and the FAIL row" "$(recovery_verdict drill-refusal --text "$QUOTA_TEXT" < "${STATE}/${s}.log" | head -1)"
    record "$s" "quota refusal: the drill still wrote its FAIL row to the register (s3://${DRILL_BUCKET}/${IDENTITY_DB}/), read back" \
      "FAIL object recorded" "$(recovery_verdict drill-recorded --db "$IDENTITY_DB" --bucket "$DRILL_BUCKET" < "${STATE}/${s}.log" | head -1)"
  fi
  # THE REVERT, whatever happened above
  revert_object "$s" job "$ns" "$Q_JOB" "the planted drill Job"
  revert_object "$s" quota "$ns" "$QUOTA_NAME" "the planted ResourceQuota"
  mark_done "$s"
}

# ---- S02 ... a drill that cannot write its register row, and the alert that says so -----------------------
step_register() {
  local s=S02-register ns="$AI_NS" v ok=1 alert_ok=0 built made="" t0
  local cluster="${AI_DB}-drillcheck"
  reset_rows "$s"
  _emit ""; _emit "=== STEP ${s} =============================================="
  _emit "SOURCE:   no page block. A Job from the ${AI_CRON} CronJob's own template with REG_BUCKET set to a bucket that does not exist"
  v="$(absent_verdict cronjob "$ns" "$AI_CRON")"
  record "$s" "the drill CronJob ${AI_CRON} exists in ${ns}, so there is a drill to make fail" "present" "$v"
  [ "$v" = present ] || ok=0
  if [ "$ok" = 1 ] && [ "$WITH_ALERT" = 1 ]; then
    prom_read "${STATE}/${s}.rules-before.json"
    v="$(recovery_verdict alert-rule --group "$RULE_GROUP" --alert "$ALERT" --for "$ALERT_FOR" < "${STATE}/${s}.rules-before.json" | head -1)"
    record "$s" "Prometheus has ${ALERT} loaded from the chart's rule (group ${RULE_GROUP}), healthy, with for: ${ALERT_FOR}s" \
      "loaded, healthy, for ${ALERT_FOR}s" "$v"
    if [ "$v" = "loaded, healthy, for ${ALERT_FOR}s" ]; then
      v="$(recovery_verdict alert-state --group "$RULE_GROUP" --alert "$ALERT" < "${STATE}/${s}.rules-before.json" | head -1)"
      record "$s" "${ALERT} reads inactive before the fault, so a firing one afterwards is this fault's" "inactive" "$v"
      [ "$v" = inactive ] && alert_ok=1
    fi
    [ "$alert_ok" = 1 ] || note "${s}: the alert half is not waited for: ${ALERT} was not loaded and inactive when read, and the rows above say what was read instead"
  elif [ "$WITH_ALERT" != 1 ]; then
    note "${s}: TOCKMOX_P13_ALERT=${WITH_ALERT}, so ${ALERT} is neither read nor waited for"
  fi
  if [ "$ok" = 1 ]; then
    execute_begin "make a drill Job from cronjob/${AI_CRON} with REG_BUCKET=${FAULT_BUCKET} (a bucket that does not exist)"
    kubectl --context="$KUBE_CONTEXT" -n "$ns" create job --from="cronjob/${AI_CRON}" "$R_JOB" --dry-run=client -o json \
      > "${STATE}/${s}.template.json" 2> "${STATE}/${s}.template.err"
    built="$(recovery_verdict job-with-env --container "$DRILL_CONTAINER" --env REG_BUCKET --value "$FAULT_BUCKET" --name "$R_JOB" < "${STATE}/${s}.template.json" | head -1)"
    case "$built" in
      "{"*)
        planted_add job "$ns" "$R_JOB"
        printf '%s\n' "$built" | kubectl --context="$KUBE_CONTEXT" -n "$ns" create -f - > "${STATE}/${s}.create" 2>&1
        v=$?
        execute_end "$v"
        _emit "    | $(cat "${STATE}/${s}.create")"
        if [ "$v" = 0 ]; then made="created from the CronJob's template with REG_BUCKET=${FAULT_BUCKET}"
        else made="create refused: $(head -c 200 "${STATE}/${s}.create" | tr '\n' ' ')"; fi ;;
      *) execute_end 1; made="$built" ;;
    esac
    record "$s" "the fault Job ${R_JOB} is the CronJob's own template with one env value changed" \
      "created from the CronJob's template with REG_BUCKET=${FAULT_BUCKET}" "$made"
    case "$made" in created*) ;; *) ok=0; alert_ok=0 ;; esac
  fi
  if [ "$ok" = 1 ]; then
    job_wait "$ns" "$R_JOB" "${STATE}/${s}.job.json" "$DRILL_JOB_WAIT"
    note "${s}: waited ${JOB_WAITED}s (limit ${DRILL_JOB_WAIT}s) for the drill Job ${R_JOB} to end"
    kubectl --context="$KUBE_CONTEXT" -n "$ns" logs "job/${R_JOB}" > "${STATE}/${s}.log" 2>&1
    _emit "    the drill's log, last lines:"
    tail -n 8 "${STATE}/${s}.log" | sed 's/^/    | /' | while IFS= read -r l; do _emit "$l"; done
    record "$s" "unwritable register: the drill Job ends Failed and never reaches Complete" \
      "Failed, never Complete" "$(recovery_verdict job-not-complete < "${STATE}/${s}.job.json" | head -1)"
    record "$s" "unwritable register: the restore passed, the write to s3://${FAULT_BUCKET}/${AI_DB}/ was refused, and the drill says NOT RECORDED" \
      "restore PASS, register write refused, nothing recorded" "$(recovery_verdict drill-unrecorded --db "$AI_DB" --bucket "$FAULT_BUCKET" < "${STATE}/${s}.log" | head -1)"
    record "$s" "unwritable register: no PASS object was recorded for this run" \
      "no PASS recorded" "$(recovery_verdict drill-no-pass --allow-row yes < "${STATE}/${s}.log" | head -1)"
    if [ "$alert_ok" = 1 ]; then
      alert_wait firing "$ALERT_WAIT" "${STATE}/${s}.rules-after.json"
      note "${s}: waited ${ALERT_WAITED}s (limit ${ALERT_WAIT}s; ${ALERT} has for: ${ALERT_FOR}s and its group evaluates every 300s) for ${ALERT} to read firing; the last state read was ${ALERT_LAST}"
      if [ "$ALERT_LAST" = firing ]; then v=firing; else v="${ALERT_LAST} after ${ALERT_WAITED}s (limit ${ALERT_WAIT}s)"; fi
      record "$s" "${ALERT} is firing in Prometheus within its for: plus the evaluation interval and a margin" "firing" "$v"
    fi
  fi
  # THE REVERT, whatever happened above
  revert_object "$s" job "$ns" "$R_JOB" "the planted drill Job"
  if [ -n "$made" ]; then
    # the drill's own teardown removes its recovery cluster; read that it did, and remove it if it did not
    t0=$(date +%s)
    while :; do
      v="$(absent_verdict cluster "$ns" "$cluster")"
      [ "$v" = absent ] && break
      [ $(( $(date +%s) - t0 )) -ge "$CLUSTER_WAIT" ] && break
      sleep 3
    done
    if [ "$v" != absent ]; then planted_add cluster "$ns" "$cluster"; delete_planted cluster "$ns" "$cluster" >/dev/null 2>&1; fi
    record "$s" "revert: the drill's recovery cluster ${cluster} is gone from ${ns}" "absent" "$v"
  fi
  if [ "$alert_ok" = 1 ]; then
    if alert_wait inactive "$CLEAR_WAIT" "${STATE}/${s}.rules-cleared.json"; then v=inactive; else v="${ALERT_LAST} after ${ALERT_WAITED}s (limit ${CLEAR_WAIT}s)"; fi
    note "${s}: waited ${ALERT_WAITED}s (limit ${CLEAR_WAIT}s) for ${ALERT} to read inactive once the failed Job was removed"
    record "$s" "revert: ${ALERT} reads inactive again once the failed Job is removed" "inactive" "$v"
  fi
  mark_done "$s"
}

# finish_path ... replay every recorded verdict, then declare the outcome.
finish_path() {
  # The execute phase is a per-invocation fact in lib/assert.sh; a resumed final call that only replays would
  # otherwise be refused a PASS. Persist the last execute_end's rc and re-declare it from state, saying so.
  [ "$EXEC_PHASE_COMPLETED" -eq 1 ] && printf '%s' "$EXEC_LAST_RC" > "${STATE}/last-execute-rc"
  if [ "$EXEC_PHASE_STARTED" -eq 0 ] && [ -f "${STATE}/last-execute-rc" ]; then
    execute_begin "replayed from state: the faults were planted in an earlier invocation of this path (see the STEP logs above in the same report)"
    execute_end "$(cat "${STATE}/last-execute-rc")"
  fi
  _emit ""; _emit "=== REPLAY of every recorded verdict through lib/assert.sh ==========="
  # shellcheck disable=SC2016  # the read is a command string assert.sh evaluates later; $_replay_val must stay unexpanded here
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
    "That the identity drill's alert fires: S01's failed Job is removed within minutes, before the alert's for: could elapse, and the two charts' TockmoxRestoreDrillFailed carry no database label, so Prometheus's answer for one group is read and the other is not asserted." \
    "That the alert reaches a person: Prometheus's rule state is read, not Alertmanager, the alert bridge or ntfy." \
    "A refusal from a quota on compute or on pods: S01 limits the number of Cluster objects, so the refusal is at the drill's own apply and the drill fails in seconds. A quota that lets the Cluster in and refuses its pod makes the cluster never become Ready, which the drill waits 900 seconds for (restore-drill.yaml in charts/tockmox-ai and charts/tockmox-identity); that path is not exercised." \
    "TockmoxLiteLLMDown: its group renders only with alertPack.litellm.enabled, which is off, and it needs the gateway's prometheus callback and a ServiceMonitor besides, all values the site repository sets; and scaling the gateway to zero removes the series, which TockmoxLiteLLMMetricsAbsent (for: 15m) reads, not the Down rule. TockmoxLokiNotIngesting: at least 25 minutes with the shipper stopped (a 10 minute rate window, then for: 15m), with ArgoCD's self-heal free to undo the fault and a hole left in the throwaway's logs. TockmoxPrometheusTSDBVolumeTroughRising: a 3 day minimum, so filling a volume cannot make it fire in a run." \
    "That the register's FAIL objects these faults leave are harmless: the register is append-only by design, and S01 leaves a FAIL object for the identity database, which this path cannot and should not delete." \
    "That the install itself works, or that a drill PASSES: those are P09's and P11's."

  parity_caveat \
    "The kubectl calls ran from a Linux runner against a single-node KubeVirt guest, the one P09 installed. The refusal wording in S01 is the API server's and the register wording is the chart's; the first is matched on its stable part only (\"exceeded quota\"). Nothing was run on the workstation shells the docs are written for, and no step of this path is a page block."

  path_finish
}

# ============================================================== THE STEPS
# The safety net first: from here on, anything planted is struck from planted.list only once it reads as gone, and
# the traps delete whatever is left. A step never yields once it has planted (the budget is read between steps).
trap revert_all EXIT
trap 'revert_all; exit 143' TERM
trap 'revert_all; exit 130' INT
trap 'revert_all; exit 129' HUP

if ! done_step S01-quota; then budget_left || yield "S01+"; step_quota; fi
if ! done_step S02-register; then budget_left || yield "S02"; step_register; fi

finish_path
exit $?

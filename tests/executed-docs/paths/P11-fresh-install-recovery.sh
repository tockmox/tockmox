#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P11 ... what a fresh install can come back from. Runs AFTER P09 on the same cluster and the same
# state directory, only when P09 ended PASS. P09 installs from docs/deployment/install.md and proves the
# install is Healthy; this path then reads three things the install made and the docs make claims about:
#
#   S01  the LiteLLM migrations Job: exactly one, an Argo CD Sync hook that deletes the last Job first,
#        Complete, and the litellm subchart's own (Tockmox renders none beside it). upgrade.md, "The
#        LiteLLM migrations Job becomes an Argo CD hook".
#   S02  a base backup of the identity and model gateway databases: a Backup made now, the way
#        backup-restore.md section 4 says, that completes, has a backupId and is newer than the install;
#        and a ScheduledBackup of the right shape beside it.
#   S03  a restore drill of each database: a Job made from the drill CronJob, the way profiles.md "Run the
#        first drill" says, that is Complete, whose log shows a PASS object written to the drill register
#        and read back, and whose PASS row names the backup S02 took.
#
# These are not page blocks. The commands that make the objects are the documented ones with this
# harness's --context added, because those pages' blocks name no cluster and this harness never runs a
# call that does not. The verdicts are lib/p09-recovery.py's, shown red one mutation at a time by
# recovery-rows-test.sh, which needs no cluster.
#
# WHEN IT RUNS. run.sh discovers paths/P*.sh and gives this one P09's route group, so a plain run.sh
# reaches it on whatever cluster the group has. It does not run there. It needs TOCKMOX_P09_STATE (the
# state directory of a P09 run on this cluster), a marker in it that P09 ended PASS (p09-lane.sh writes
# it), and root-applied-at (P09 writes it when it applies root.yaml). Any of the three missing is BLOCKED
# with the reason, an outcome run.sh counts as a declared constraint, not a failure and not UNCONVERTED.
# A missing or zero install time in particular is BLOCKED and never defaulted: with a cut-off of 0 the
# claim "a Backup newer than the install" cannot be false.
#
# ITS OWN STATE AND BUDGET. State goes under ${TOCKMOX_P09_STATE}/p11, so P09's verdicts and step markers
# are not touched. TOCKMOX_P11_BUDGET (seconds, default 150) is this path's own yield point: past it, with
# steps remaining, the path exits 75 and is called again. P09's budget does not apply to it.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null  # lib/assert.sh, resolved from this script's own directory at run time
. "${HERE}/../lib/assert.sh"

path_begin "P11-fresh-install-recovery" \
  "after P09: the migrations Job, a base backup of each CNPG database, and a restore drill of each that records a PASS"

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
[ -n "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not set, so there is no P09 install on this cluster to read"
[ -d "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not a directory (${P09_STATE})"
[ -f "${P09_STATE}/p09-passed" ] || blocked "P09 did not end PASS on this state directory (no p09-passed marker in it)"
ROOT_APPLIED="$(cat "${P09_STATE}/root-applied-at" 2>/dev/null || true)"
install_time_ok "$ROOT_APPLIED" || blocked "root-applied-at is missing or not a positive number of seconds in ${P09_STATE} (found [${ROOT_APPLIED}]); without the install time, \"after the install\" cannot be tested"

# every kubectl call below names its cluster with --context from this variable, and an empty value is
# refused rather than falling back to the current context (docs/deployment/fresh-install.md, "Name the
# cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

STATE="${P09_STATE}/p11"
BUDGET="${TOCKMOX_P11_BUDGET:-150}"
T0=$(date +%s)
mkdir -p "$STATE"
for t in kubectl python3; do
  command -v "$t" >/dev/null 2>&1 || { _emit "INFRA: '$t' is not on PATH"; path_outcome INFRA_ERROR "missing $t"; exit 1; }
done

# ------------------------------------------------------------- state helpers
# The same shape as P09's: a step is skipped once done, a verdict is written to verdicts.tsv as it is made and
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

# ---- the rows --------------------------------------------------------------------------------------
# These rows read objects the install itself made, for claims the docs make about them. They are not
# page blocks: the commands that make the objects are the documented ones (backup-restore.md section 4,
# profiles.md "Run the first drill") with this harness's --context added, because those pages' blocks
# name no cluster and this harness never runs a call that does not. The verdicts come from
# lib/p09-recovery.py, so recovery-rows-test.sh can show each row go red without a cluster.
RECOVERY_PY="${HERE}/../lib/p09-recovery.py"
recovery_verdict() {
  python3 -I "$RECOVERY_PY" "$@"
}
# the stock install's names: charts/tockmox-ai (release tockmox-ai, litellm subchart alias) and charts/tockmox-identity
MIG_JOB=tockmox-ai-litellm-migrations
DRILL_BUCKET=tockmox-drill-register

# record_migrations_rows STEP JOB ... three rows from ${STATE}/STEP.jobs.json (kubectl get jobs -o json)
record_migrations_rows() {
  local s="$1" name="$2" f="${STATE}/${1}.jobs.json"
  record "$s" "migrations Job: exactly one, named ${name}, an Argo CD Sync hook that deletes the last Job first" \
    "one Sync hook Job, BeforeHookCreation" "$(recovery_verdict migrations-hook --job "$name" < "$f" | head -1)"
  record "$s" "migrations Job: ${name} is Complete" \
    "Complete" "$(recovery_verdict migrations-complete --job "$name" < "$f" | head -1)"
  record "$s" "migrations Job: Tockmox renders none of its own, the only one is the litellm subchart's" \
    "the only migrations Job is the subchart's" "$(recovery_verdict migrations-owner --job "$name" < "$f" | head -1)"
}

# record_backup_rows STEP CLUSTER ... from ${STATE}/STEP.backups.json and STEP.scheduled.json; leaves the
# backupId in ${STATE}/STEP.backup-id for the drill rows. The cut-off is ROOT_APPLIED, the time P09 applied
# root.yaml, read and checked once at the top of this path. It is never defaulted: a cut-off of 0 would make
# "after the install" true of any Backup that ever existed.
record_backup_rows() {
  local s="$1" cluster="$2" v
  if ! install_time_ok "${ROOT_APPLIED:-}"; then
    record "$s" "base backup: a completed Backup of ${cluster} made after the install, with a backupId" \
      "completed after the install" "no usable install time (ROOT_APPLIED is [${ROOT_APPLIED:-}])"
    return 0
  fi
  v="$(recovery_verdict backup --cluster "$cluster" --after "$ROOT_APPLIED" < "${STATE}/${s}.backups.json")"
  record "$s" "base backup: a completed Backup of ${cluster} made after the install, with a backupId" \
    "completed after the install" "$(printf '%s\n' "$v" | sed -n 1p)"
  printf '%s' "$(printf '%s\n' "$v" | sed -n 2p)" > "${STATE}/${s}.backup-id"
  record "$s" "scheduled backup: ${cluster}-scheduled backs ${cluster} up through the barman plugin on a schedule" \
    "plugin backup of ${cluster} on a schedule" "$(recovery_verdict scheduled --cluster "$cluster" < "${STATE}/${s}.scheduled.json" | head -1)"
}

# record_drill_rows STEP DB BACKUP_ID ... from ${STATE}/STEP.job.json (the drill Job) and STEP.log (its log)
record_drill_rows() {
  local s="$1" db="$2" id="$3"
  record "$s" "restore drill (${db}): the drill Job is Complete" \
    "Complete" "$(recovery_verdict job < "${STATE}/${s}.job.json" | head -1)"
  record "$s" "restore drill (${db}): a PASS object sits in the drill register (s3://${DRILL_BUCKET}/${db}/), written and read back" \
    "PASS object recorded" "$(recovery_verdict drill-recorded --db "$db" --bucket "$DRILL_BUCKET" < "${STATE}/${s}.log" | head -1)"
  record "$s" "restore drill (${db}): the PASS row names the backup this run took, so that backup is what was restored" \
    "pinned ${id}" "$(recovery_verdict drill-pinned --backup-id "$id" < "${STATE}/${s}.log" | head -1)"
}

# take_backup KEY NS CLUSTER ... backup-restore.md section 4: force a WAL switch, then a Backup now. The scheduled
# backup fires at 03:00 or 03:20 UTC (charts/tockmox-ai, charts/tockmox-identity), which a lane run does not wait for.
# Safe to call again after a yield: the Backup is made once, and the wait keeps its first deadline.
take_backup() {
  local key="$1" ns="$2" cluster="$3" name="${3}-proof" phase wal_rc
  done_step "$key" && return 0
  if ! kubectl --context="$KUBE_CONTEXT" -n "$ns" get backups.postgresql.cnpg.io "$name" >/dev/null 2>&1; then
    kubectl --context="$KUBE_CONTEXT" -n "$ns" exec "${cluster}-1" -c postgres -- \
      psql -U postgres -c 'SELECT pg_switch_wal();' > "${STATE}/${key}.wal" 2>&1
    wal_rc=$?
    note "${key}: pg_switch_wal on ${cluster}-1 exited ${wal_rc}: $(tr '\n' ' ' < "${STATE}/${key}.wal" | cut -c1-120)"
    execute_begin "backup-restore.md section 4: a Backup of ${cluster} now"
    kubectl --context="$KUBE_CONTEXT" -n "$ns" apply -f - > "${STATE}/${key}.apply" 2>&1 <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: ${name}, namespace: ${ns} }
spec:
  cluster: { name: ${cluster} }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF
    execute_end $?
    _emit "    | $(cat "${STATE}/${key}.apply")"
  fi
  [ -f "${STATE}/${key}.deadline" ] || echo $(( $(date +%s) + 900 )) > "${STATE}/${key}.deadline"
  while :; do
    phase="$(kubectl --context="$KUBE_CONTEXT" -n "$ns" get backups.postgresql.cnpg.io "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in completed|failed) break ;; esac
    [ "$(date +%s)" -ge "$(cat "${STATE}/${key}.deadline")" ] && break
    budget_left || yield "S02 (waiting for the Backup of ${cluster}; re-run to keep waiting)"
    sleep 10
  done
  _emit "    Backup ${name}: phase ${phase:-unset}"
  kubectl --context="$KUBE_CONTEXT" -n "$ns" get backups.postgresql.cnpg.io -o json > "${STATE}/${key}.backups.json" 2>/dev/null
  kubectl --context="$KUBE_CONTEXT" -n "$ns" get scheduledbackups.postgresql.cnpg.io "${cluster}-scheduled" -o json > "${STATE}/${key}.scheduled.json" 2>/dev/null
  record_backup_rows "$key" "$cluster"
  mark_done "$key"
}

# run_drill KEY NS CRONJOB DB BACKUP_KEY ... profiles.md "Run the first drill": a Job from the drill CronJob, read when it ends.
run_drill() {
  local key="$1" ns="$2" cron="$3" db="$4" bkey="$5" job="${3}-first" v
  done_step "$key" && return 0
  if ! kubectl --context="$KUBE_CONTEXT" -n "$ns" get job "$job" >/dev/null 2>&1; then
    execute_begin "profiles.md Run the first drill: create job --from=cronjob/${cron}"
    kubectl --context="$KUBE_CONTEXT" -n "$ns" create job --from="cronjob/${cron}" "$job" > "${STATE}/${key}.create" 2>&1
    execute_end $?
    _emit "    | $(cat "${STATE}/${key}.create")"
  fi
  # the drill Job's own activeDeadlineSeconds is 1800
  [ -f "${STATE}/${key}.deadline" ] || echo $(( $(date +%s) + 2100 )) > "${STATE}/${key}.deadline"
  while :; do
    kubectl --context="$KUBE_CONTEXT" -n "$ns" get job "$job" -o json > "${STATE}/${key}.job.json" 2>/dev/null
    v="$(recovery_verdict job < "${STATE}/${key}.job.json" | head -1)"
    case "$v" in Complete|Failed*) break ;; esac
    [ "$(date +%s)" -ge "$(cat "${STATE}/${key}.deadline")" ] && break
    budget_left || yield "S03 (waiting for the ${db} drill; re-run to keep waiting)"
    sleep 15
  done
  kubectl --context="$KUBE_CONTEXT" -n "$ns" logs "job/${job}" > "${STATE}/${key}.log" 2>&1
  _emit "    the drill's log, last lines:"
  tail -n 12 "${STATE}/${key}.log" | sed 's/^/    | /' | while IFS= read -r l; do _emit "$l"; done
  record_drill_rows "$key" "$db" "$(cat "${STATE}/${bkey}.backup-id" 2>/dev/null)"
  mark_done "$key"
}


# finish_path ... replay every recorded verdict, then declare the outcome.
finish_path() {
  # The execute phase is a per-invocation fact in lib/assert.sh; a resumed final call that only replays would
  # otherwise be refused a PASS. Persist the last execute_end's rc and re-declare it from state, saying so.
  [ "$EXEC_PHASE_COMPLETED" -eq 1 ] && printf '%s' "$EXEC_LAST_RC" > "${STATE}/last-execute-rc"
  if [ "$EXEC_PHASE_STARTED" -eq 0 ] && [ -f "${STATE}/last-execute-rc" ]; then
    execute_begin "replayed from state: the Backups and drill Jobs were made in an earlier invocation of this path (see the STEP logs above in the same report)"
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
    "That a SCHEDULED backup or a SCHEDULED drill fires: this path takes each Backup and starts each drill Job by hand, the way backup-restore.md section 4 and profiles.md tell a reader to, because the schedules (03:00 and 03:20 UTC, Mondays 04:30 and 04:45) are not waited for. It shows the Backup and Job objects the schedules create work, and that a ScheduledBackup of the right shape exists." \
    "That the backups and the register survive losing the cluster: the object store and the drill register are the Garage inside this cluster, and this path reads them from inside it. What a drill's PASS proves is that a Postgres could be rebuilt from that store, not that the store outlives the throwaway." \
    "That an alert fires or clears: this path reads no Prometheus. TockmoxRestoreDrillFailed, the freshness rules and the resilient profile's alerts are not exercised here (a failing drill needs a planted fault)." \
    "That the namespace guard raises no warning on a stock install: it is off by default, so this install has no such policy to read." \
    "That the install itself works: that is P09's, and this path only runs when P09 ended PASS on the same state. It also does not run the model-gateway key block of install.md; the gateway is on in this install (charts/tockmox-ai follows capabilities.aiPlane) and the migrations Job is read, nothing more."

  parity_caveat \
    "The reads and the Backup and Job commands ran through kubectl on a Linux runner against a single-node KubeVirt guest, the one P09 installed. Nothing was run on the workstation shells the docs are written for, and no step of this path is a page block."

  path_finish
}

# ============================================================== THE STEPS
# S01 ... the migrations Job.
S=S01-migrations-job
if ! done_step "$S"; then budget_left || yield "S01+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "SOURCE:   no page block. A read of the Jobs in tockmox-ai, for upgrade.md's \"The LiteLLM migrations Job becomes an Argo CD hook\""
  # a sync still running replaces the hook Job (BeforeHookCreation), so wait a bounded time for it to be Complete
  [ -f "${STATE}/${S}.deadline" ] || echo $(( $(date +%s) + 300 )) > "${STATE}/${S}.deadline"
  while :; do
    kubectl --context="$KUBE_CONTEXT" -n tockmox-ai get jobs -o json > "${STATE}/${S}.jobs.json" 2>/dev/null
    [ "$(recovery_verdict migrations-complete --job "$MIG_JOB" < "${STATE}/${S}.jobs.json" | head -1)" = Complete ] && break
    [ "$(date +%s)" -ge "$(cat "${STATE}/${S}.deadline")" ] && break
    budget_left || yield "S01 (waiting for the migrations Job)"
    sleep 10
  done
  record_migrations_rows "$S" "$MIG_JOB"
  mark_done "$S"
fi

# S02 ... a base backup of each database.
S=S02-base-backups
if ! done_step "$S"; then budget_left || yield "S02+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "SOURCE:   no page block. backup-restore.md section 4 (\"Prove a backup now, not at 03:00\") on the identity and model gateway databases"
  take_backup S02-authentik tockmox-authentik tockmox-authentik-db
  take_backup S02-litellm tockmox-ai tockmox-litellm-db
  mark_done "$S"
fi

# S03 ... a restore drill of each database, from the backup S02 took.
S=S03-restore-drills
if ! done_step "$S"; then budget_left || yield "S03+"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "SOURCE:   no page block. profiles.md \"Run the first drill\", one Job from each drill CronJob, one after the other"
  run_drill S03-authentik tockmox-authentik tockmox-authentik-db-drill tockmox-authentik-db S02-authentik
  run_drill S03-litellm tockmox-ai tockmox-litellm-db-drill tockmox-litellm-db S02-litellm
  mark_done "$S"
fi

finish_path
exit $?

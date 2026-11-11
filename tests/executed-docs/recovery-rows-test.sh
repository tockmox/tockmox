#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof of P10's rows: the migrations Job, a base backup of each CNPG database, and a
# restore drill of each that records a PASS. No cluster. Two layers, because the rows have two parts.
#
#   1. The verdicts (lib/p09-recovery.py) and the row functions P09 builds on them. A green fixture
#      makes every row read as expected; then one mutation per row, each of which must turn exactly
#      that row red and leave its neighbours green. A mutation that changes nothing is itself a
#      failure, so a fixture edit that no longer matches cannot pass quietly.
#   2. The glue (take_backup, run_drill), run unmodified against a stub kubectl that keeps no state
#      beyond marker files and logs every call: every call names its cluster, the Backup and the
#      drill Job are the documented ones, a second call after a yield makes neither again and writes
#      no row twice, an exhausted budget yields (exit 75) instead of waiting, and a Failed drill or a
#      failed Backup turns its rows red.
#
# The functions are read out of P10 itself (as env-rows-test.sh does), so a change to P10 that breaks
# a row breaks this.
#
# A third layer is the path's own gate: P10 runs after P09 and must never run, or pass, without an install
# to read. It is run as a script, and by run.sh, and must declare BLOCKED (and not read as a failure or as
# UNCONVERTED) when P09's state, its PASS marker or the install time is missing, and the same checks are
# run against mutated copies that must not.
#
#   ./tests/executed-docs/recovery-rows-test.sh
#   P10=/path/to/P10.sh ./tests/executed-docs/recovery-rows-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture text is literal
# shellcheck disable=SC2034  # STATE, KUBE_CONTEXT, BUDGET, T0, RECOVERY_PY and ASSERT_REPORT are read by the P10 functions sourced below
# shellcheck disable=SC2329  # _emit and sleep are stubs for the sourced functions
# shellcheck disable=SC1090,SC2030,SC2031  # the P10 functions are sourced from a file built at run time; PATH is set per subshell on purpose
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
P10="${P10:-${HERE}/paths/P10-fresh-install-recovery.sh}"
PY="${HERE}/lib/p09-recovery.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\) +\\{" {on=1; print; if ($0 ~ /\}[ \t]*$/) exit; next} on {print} on && /^}/ {exit}' "$P10"; }
FNS="${TMP}/p10-fns.sh"
: > "$FNS"
for f in record note done_step mark_done budget_left yield install_time_ok recovery_verdict \
         record_migrations_rows record_backup_rows record_drill_rows take_backup run_drill; do
  body="$(fn_of "$f")"
  if [ -z "$body" ]; then bad "P10 defines ${f}()" "not found in ${P10}"; else printf '%s\n' "$body" >> "$FNS"; fi
done
# the constants the rows use, read from P10 too
grep -E '^(MIG_JOB|DRILL_BUCKET)=' "$P10" >> "$FNS"

# ------------------------------------------------------------------ fixtures
CL=tockmox-authentik-db
MIG=tockmox-ai-litellm-migrations
ID=20261110T210100
LOGDB=tockmox-litellm-db
SUM=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

mk_backups() { # FILE CLUSTER PHASE CREATED [ID]
  local idpart=""
  [ -z "${5:-}" ] || idpart=",\"backupId\":\"$5\""
  cat > "$1" <<EOF
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"postgresql.cnpg.io/v1","kind":"Backup","metadata":{"name":"${2}-proof","creationTimestamp":"${4}"},"spec":{"cluster":{"name":"${2}"},"method":"plugin"},"status":{"phase":"${3}"${idpart}}}]}
EOF
}
mk_sched() { # FILE CLUSTER METHOD SUSPEND
  cat > "$1" <<EOF
{"apiVersion":"postgresql.cnpg.io/v1","kind":"ScheduledBackup","metadata":{"name":"${2}-scheduled"},"spec":{"schedule":"0 20 3 * * *","method":"${3}","cluster":{"name":"${2}"},"suspend":${4}}}
EOF
}
mk_job() { # FILE CONDITION-TYPE
  cat > "$1" <<EOF
{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"x-first"},"status":{"conditions":[{"type":"${2}","status":"True"}]}}
EOF
}
mk_jobs() { # FILE NAME HOOK DELETE-POLICY COMPLETE(True|False) CHART [EXTRA-ITEM]
  cat > "$1" <<EOF
{"apiVersion":"v1","kind":"List","items":[
 {"kind":"Job","metadata":{"name":"tockmox-ai-gateway-key-b7592bff0a","labels":{"tockmox.com/managed-by":"tockmox","app.kubernetes.io/part-of":"tockmox"}},"status":{"conditions":[{"type":"Complete","status":"True"}]}},
 {"kind":"Job","metadata":{"name":"${2}","annotations":{"argocd.argoproj.io/hook":"${3}","argocd.argoproj.io/hook-delete-policy":"${4}"},"labels":{"app.kubernetes.io/component":"migrations","helm.sh/chart":"${6}","app.kubernetes.io/managed-by":"Helm"}},"status":{"conditions":[{"type":"Complete","status":"${5}"}]}}${7:+,
 $7}
]}
EOF
}
mk_log() { # FILE [STAMP-WITH-SEPARATORS] [VERDICT] [BACKUP-FIELD]
  local stamp="${2:-2026-11-10T21:04:05Z}" verdict="${3:-PASS}" bk="${4:-$ID}" keystamp
  keystamp="$(printf '%s' "$stamp" | tr -d ':-')"
  cat > "$1" <<EOF
backup: ${ID}
image: ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
apply: cluster.postgresql.cnpg.io/${LOGDB}-drillcheck created
wait: cluster.postgresql.cnpg.io/${LOGDB}-drillcheck condition met
verify: in_recovery=f public_tables=42
register: ${stamp} ${verdict} in_recovery=f public_tables=42 backup=${bk}
register: recorded s3://tockmox-drill-register/${LOGDB}/${keystamp}-${verdict}.json sha256=${SUM}
EOF
}
GOOD_AFTER=1000000000   # 2001: every fixture's creation time is after this
mut() { # IN OUT OLD NEW ... a copy with every OLD replaced by NEW; refuses an edit that changes nothing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
t = s.replace(old, new)
assert t != s, "the fixture edit changed nothing: %r" % old
open(dst, "w", encoding="utf-8").write(t)
PY
}

# ------------------------------------------------------- the row functions
# rows FUNCTION ARGS... ... run a P10 row function over the files in $ST, print "n|expected|actual" per row
ST="${TMP}/st"
rows() {
  (
    STATE="$ST"; rm -rf "$STATE"; mkdir -p "$STATE"
    RECOVERY_PY="$PY"
    # shellcheck disable=SC2329
    _emit() { :; }
    # shellcheck source=/dev/null  # P10's own functions, read out of the path above
    . "$FNS"
    cp "${ROWS_FILES}"/* "$STATE"/ 2>/dev/null
    ROOT_APPLIED="${ROWS_AFTER-$GOOD_AFTER}"
    "$@" >/dev/null
    awk -F'\t' '{n++; print n "|" $3 "|" $4}' "${STATE}/verdicts.tsv"
  )
}
# red_of ... the numbers of the rows whose expected and actual differ, as "1 3", from rows' output
red_of() { awk -F'|' '$2 != $3 {printf "%s%s", sep, $1; sep=" "} END{print ""}'; }
# expect LABEL WANT ... compare the red rows of the last `rows` output to WANT ("" = none red)
RO=""
expect() { # LABEL WANT-RED-ROWS [REASON-SUBSTRING-OF-A-RED-ROW'S-ACTUAL]
  local got; got="$(printf '%s\n' "$RO" | red_of)"
  if [ "$got" != "$2" ]; then bad "$1" "red rows: [${got}] want [${2}]; rows: $(printf '%s' "$RO" | tr '\n' ';' | cut -c1-400)"
  elif [ -n "${3:-}" ] && ! printf '%s\n' "$RO" | awk -F'|' '$2 != $3' | grep -F -- "$3" >/dev/null; then
    bad "$1" "the right rows are red but not for the reason [${3}]; rows: $(printf '%s' "$RO" | tr '\n' ';' | cut -c1-400)"
  else ok "$1"; fi
}
nrows() { printf '%s\n' "$RO" | grep -c .; }

# --- the migrations Job ---------------------------------------------------
D="${TMP}/mig"; mkdir -p "$D"
ROWS_FILES="$D"
mk_jobs "$D/S.jobs.json" "$MIG" Sync BeforeHookCreation True litellm-1.106.6
RO="$(rows record_migrations_rows S "$MIG")"
expect "migrations: the shipped shape (one Sync hook Job, Complete, the subchart's) reads green on all three rows" ""
[ "$(nrows)" = 3 ] && ok "migrations: three rows" || bad "migrations: three rows" "got $(nrows)"

mutcase() { # LABEL WANT-RED-ROWS REASON
  RO="$(rows record_migrations_rows S "$MIG")"; expect "$1" "$2" "${3:-}"
}
mk_jobs "$D/S.jobs.json" "$MIG" PreSync BeforeHookCreation True litellm-1.106.6;  mutcase "migrations: a PreSync hook (upstream's default, a deadlock here) turns the hook row red" "1" "is PreSync, not Sync"
mk_jobs "$D/S.jobs.json" "$MIG" Sync HookSucceeded True litellm-1.106.6;          mutcase "migrations: a hook-delete-policy that is not BeforeHookCreation turns the hook row red" "1" "is HookSucceeded, not BeforeHookCreation"
mk_jobs "$D/S.jobs.json" "$MIG" Sync BeforeHookCreation False litellm-1.106.6;    mutcase "migrations: a Job that is not Complete turns the Complete row red" "2" "not finished"
mk_jobs "$D/S.jobs.json" "$MIG" Sync BeforeHookCreation True tockmox-ai-0.8.0;    mutcase "migrations: a Job whose chart is not litellm's turns the ownership row red" "3" "is not from the litellm subchart"
mk_jobs "$D/S.jobs.json" other-migrations Sync BeforeHookCreation True litellm-1.106.6; mutcase "migrations: a Job under another name turns the hook and Complete rows red" "1 2" "is other-migrations, not"
HASH='{"kind":"Job","metadata":{"name":"tockmox-ai-litellm-migrations-0123456789","labels":{"tockmox.com/managed-by":"tockmox","app.kubernetes.io/component":"migrations"}},"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
mk_jobs "$D/S.jobs.json" "$MIG" Sync BeforeHookCreation True litellm-1.106.6 "$HASH"; mutcase "migrations: the 0.8.x hash-named Job beside the hook Job turns the hook and ownership rows red" "1 3" "migrations Jobs, one expected"
HASH2='{"kind":"Job","metadata":{"name":"tockmox-ai-litellm-migrations-0123456789","labels":{"tockmox.com/managed-by":"tockmox"}},"status":{}}'
mk_jobs "$D/S.jobs.json" "$MIG" Sync BeforeHookCreation True litellm-1.106.6 "$HASH2"; mutcase "migrations: a Tockmox-owned migrations Job that carries no component label is still caught by the ownership row" "3" "tockmox-owned migrations Job"
printf '{"kind":"List","items":[]}' > "$D/S.jobs.json";                           mutcase "migrations: no Jobs at all turns all three rows red" "1 2 3" "no Job labelled"
: > "$D/S.jobs.json";                                                             mutcase "migrations: an empty read turns all three rows red, it is not read as healthy" "1 2 3" "unreadable"

# --- a base backup --------------------------------------------------------
D="${TMP}/bk"; mkdir -p "$D"
ROWS_FILES="$D"
mk_backups "$D/S.backups.json" "$CL" completed 2026-11-10T21:01:00Z "$ID"; mk_sched "$D/S.scheduled.json" "$CL" plugin false
RO="$(rows record_backup_rows S "$CL")"; expect "backup: a completed Backup after the install, with a backupId, and a plugin ScheduledBackup, reads green" ""
[ "$(cat "$ST/S.backup-id")" = "$ID" ] && ok "backup: the backupId is left for the drill rows" || bad "backup: the backupId is left for the drill rows" "got [$(cat "$ST/S.backup-id")]"
[ "$(nrows)" = 2 ] && ok "backup: two rows" || bad "backup: two rows" "got $(nrows)"
bkcase() { RO="$(rows record_backup_rows S "$CL")"; expect "$1" "$2" "${3:-}"; }
mk_backups "$D/S.backups.json" "$CL" failed 2026-11-10T21:01:00Z "$ID";           bkcase "backup: a failed Backup turns the base-backup row red" "1" "newest Backup of tockmox-authentik-db is failed"
mk_backups "$D/S.backups.json" "$CL" started 2026-11-10T21:01:00Z;                 bkcase "backup: a Backup that never finished turns the base-backup row red" "1" "is started"
mk_backups "$D/S.backups.json" "$CL" completed 2001-09-09T01:46:00Z "$ID";         bkcase "backup: a completed Backup that predates the install turns the base-backup row red" "1" "predates the install"
mk_backups "$D/S.backups.json" "$CL" completed 2026-11-10T21:01:00Z;               bkcase "backup: a completed Backup with no backupId turns the base-backup row red" "1" "has no backupId"
mk_backups "$D/S.backups.json" other-db completed 2026-11-10T21:01:00Z "$ID";      bkcase "backup: a completed Backup of another database turns the base-backup row red" "1" "no Backup of tockmox-authentik-db"
printf '{"items":[]}' > "$D/S.backups.json";                                       bkcase "backup: no Backup at all turns the base-backup row red" "1" "no Backup of tockmox-authentik-db"
: > "$D/S.backups.json";                                                           bkcase "backup: an empty read turns the base-backup row red" "1" "unreadable"
mk_backups "$D/S.backups.json" "$CL" completed 2026-11-10T21:01:00Z "$ID"
mk_sched "$D/S.scheduled.json" "$CL" snapshot false;                               bkcase "backup: a ScheduledBackup that is not the plugin method turns the schedule row red" "2" "not plugin"
mk_sched "$D/S.scheduled.json" other-db plugin false;                              bkcase "backup: a ScheduledBackup of another cluster turns the schedule row red" "2" "is for other-db"
mk_sched "$D/S.scheduled.json" "$CL" plugin true;                                  bkcase "backup: a suspended ScheduledBackup turns the schedule row red" "2" "is suspended"
: > "$D/S.scheduled.json";                                                         bkcase "backup: no ScheduledBackup turns the schedule row red" "2" "unreadable"
mk_sched "$D/S.scheduled.json" "$CL" plugin false
ROWS_AFTER=4000000000 bkcase "backup: the cut-off is the install's time (a Backup from before root.yaml was applied is not this install's)" "1" "predates the install"

# --- a restore drill ------------------------------------------------------
D="${TMP}/dr"; mkdir -p "$D"
ROWS_FILES="$D"
mk_job "$D/S.job.json" Complete; mk_log "$D/S.log"
drcase() { RO="$(rows record_drill_rows S "$LOGDB" "${DRID-$ID}")"; expect "$1" "$2" "${3:-}"; }
drcase "drill: a Complete Job, a PASS object in the register, and the row naming the backup taken, reads green" ""
[ "$(nrows)" = 3 ] && ok "drill: three rows" || bad "drill: three rows" "got $(nrows)"
mk_job "$D/S.job.json" Failed;                                  drcase "drill: a Failed Job turns the Complete row red" "1" "Failed"
mk_job "$D/S.job.json" Complete
mk_log "$D/S.log" 2026-11-10T21:04:05Z FAIL;                    drcase "drill: a FAIL object in the register turns the register and pin rows red" "2 3" "FAIL object recorded"
mk_log "$D/S.log"; printf 'register: NOT RECORDED, so this drill FAILS whatever its verdict (PASS): write of s3://b/k refused (curl exit 0, http 403)\n' >> "$D/S.log"
drcase "drill: 'NOT RECORDED' turns the register row red, naming the refusal" "2" "NOT RECORDED"
mk_log "$D/S.log"; mut "$D/S.log" "$D/S.log2" "register: recorded" "register: skipped"; cp "$D/S.log2" "$D/S.log"
drcase "drill: no 'register: recorded' line turns the register row red" "2" "no register line"
mk_log "$D/S.log"; mut "$D/S.log" "$D/S.log2" "s3://tockmox-drill-register/" "s3://elsewhere/"; cp "$D/S.log2" "$D/S.log"
drcase "drill: an object in another bucket turns the register row red" "2" "no register line"
mk_log "$D/S.log"; mut "$D/S.log" "$D/S.log2" "/${LOGDB}/" "/other-db/"; cp "$D/S.log2" "$D/S.log"
drcase "drill: an object under another database's prefix turns the register row red" "2" "no register line"
mk_log "$D/S.log"; mut "$D/S.log" "$D/S.log2" "20261110T210405Z-PASS" "20261110T210406Z-PASS"; cp "$D/S.log2" "$D/S.log"
drcase "drill: a register object whose time is not the PASS row's turns the register row red" "2" "time differs"
mk_log "$D/S.log"; mut "$D/S.log" "$D/S.log2" "sha256=${SUM}" "sha256=nothex"; cp "$D/S.log2" "$D/S.log"
drcase "drill: a register line with no checksum turns the register row red" "2" "no register line"
mk_log "$D/S.log"; tail -1 "$D/S.log" > "$D/S.last"; cat "$D/S.last" >> "$D/S.log"
drcase "drill: two register lines turn the register row red (one run, one object)" "2" "2 register lines"
mk_log "$D/S.log" 2026-11-10T21:04:05Z PASS none;               drcase "drill: a PASS row with backup=none turns the pin row red" "3" "unpinned"
mk_log "$D/S.log" 2026-11-10T21:04:05Z PASS 20250101T000000;    drcase "drill: a PASS row that restored a different backup turns the pin row red" "3" "pinned 20250101T000000, not"
mk_log "$D/S.log"; DRID="" drcase "drill: no backupId from the backup step turns the pin row red" "3" "pinned 20261110T210100, not"
: > "$D/S.log";                                                 drcase "drill: an empty log turns the register and pin rows red" "2 3" "unreadable"

# the verdicts refuse a bad call rather than answering it
if python3 -I "$PY" backup --cluster x < /dev/null >/dev/null 2>&1; then bad "verdicts: a missing --after is refused" "exit 0"
else ok "verdicts: a missing option is a usage error (exit 2), not a verdict"; fi
if python3 -I "$PY" nonsense < /dev/null >/dev/null 2>&1; then bad "verdicts: an unknown subcommand is refused" "exit 0"
else ok "verdicts: an unknown subcommand is refused"; fi

# ------------------------------------------------------------------- the glue
# A kubectl that answers from files and records what it was asked. Markers under $SB make "created" stick.
SB="${TMP}/sb"; BIN="${TMP}/bin"; mkdir -p "$BIN"
cat > "$BIN/kubectl" <<'STUB'
#!/usr/bin/env python3
import os, sys
sb = os.environ["SB"]
with open(os.path.join(sb, "calls.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
a = [x for x in sys.argv[1:] if not x.startswith("--context=")]
ns = ""
if "-n" in a:
    i = a.index("-n"); ns = a[i + 1]; del a[i:i + 2]
def mark(n): return os.path.join(sb, "m-" + ns + "-" + n)
def scen(n, default):
    p = os.path.join(sb, "scenario-" + n)
    return open(p).read().strip() if os.path.exists(p) else default
if a[:2] == ["get", "backups.postgresql.cnpg.io"] and len(a) == 3:
    sys.exit(0 if os.path.exists(mark(a[2])) else 1)
if a[:2] == ["get", "backups.postgresql.cnpg.io"] and a[-2:] == ["-o", "json"]:
    sys.stdout.write(open(os.path.join(sb, "backups-" + ns + ".json")).read()); sys.exit(0)
if a[:2] == ["get", "backups.postgresql.cnpg.io"] and "-o" in a and a[a.index("-o") + 1].startswith("jsonpath"):
    sys.stdout.write(scen("phase", "completed")); sys.exit(0)
if a[:2] == ["get", "scheduledbackups.postgresql.cnpg.io"]:
    sys.stdout.write(open(os.path.join(sb, "sched-" + ns + ".json")).read()); sys.exit(0)
if a[:1] == ["exec"]:
    print("pg_switch_wal"); sys.exit(0)
if a[:2] == ["apply", "-f"]:
    body = sys.stdin.read()
    open(os.path.join(sb, "applied-" + ns + ".yaml"), "a").write(body)
    for l in body.splitlines():
        if l.startswith("metadata:"):
            n = l.split("name:")[1].split(",")[0].strip()
            open(mark(n), "w").close(); print("backup.postgresql.cnpg.io/%s created" % n)
    sys.exit(0)
if a[:2] == ["get", "job"] and len(a) == 3:
    sys.exit(0 if os.path.exists(mark(a[2])) else 1)
if a[:2] == ["create", "job"]:
    open(mark(a[-1]), "w").close(); print("job.batch/%s created" % a[-1]); sys.exit(0)
if a[:2] == ["get", "job"] and "-o" in a:
    sys.stdout.write(open(os.path.join(sb, "job-" + ns + ".json")).read()); sys.exit(0)
if a[:1] == ["logs"]:
    sys.stdout.write(open(os.path.join(sb, "log-" + ns + ".txt")).read()); sys.exit(0)
sys.stderr.write("stub kubectl: no answer for: %s\n" % " ".join(a)); sys.exit(1)
STUB
chmod +x "$BIN/kubectl"

# glue_run LABEL-FILE-PREFIX ... runs take_backup then run_drill for the identity database; prints nothing, leaves $SB
AUTH_NS=tockmox-authentik
glue_setup() { # scenario resets
  rm -rf "$SB"; mkdir -p "$SB"
  mk_backups "$SB/backups-${AUTH_NS}.json" "$CL" completed 2026-11-10T21:01:00Z "$ID"
  mk_sched "$SB/sched-${AUTH_NS}.json" "$CL" plugin false
  mk_job "$SB/job-${AUTH_NS}.json" Complete
  mk_log "$SB/log-${AUTH_NS}.txt"
  mut "$SB/log-${AUTH_NS}.txt" "$SB/log-${AUTH_NS}.txt.2" "$LOGDB" "$CL"; mv "$SB/log-${AUTH_NS}.txt.2" "$SB/log-${AUTH_NS}.txt"
  rm -rf "${TMP}/gst"; mkdir -p "${TMP}/gst"
}
glue() { # BUDGET-SECONDS ... one pass of the two steps, in a subshell; exit status is the pass's
  (
    export SB PATH="${BIN}:${PATH}"
    STATE="${TMP}/gst"; KUBE_CONTEXT=stub-ctx; RECOVERY_PY="$PY"; BUDGET="$1"; T0=$(date +%s); ROOT_APPLIED=1
    # the outcome library P10 sources, for execute_begin and execute_end
    # shellcheck source=/dev/null
    . "${HERE}/lib/assert.sh"
    ASSERT_REPORT=""
    # shellcheck disable=SC2329
    _emit() { :; }
    # shellcheck source=/dev/null
    . "$FNS"
    sleep() { :; }
    take_backup S02-authentik "$AUTH_NS" "$CL"
    run_drill S03-authentik "$AUTH_NS" tockmox-authentik-db-drill "$CL" S02-authentik
  ) >/dev/null 2>&1
}
glue_red() { # the red rows in $TMP/gst/verdicts.tsv, as "n n"
  awk -F'\t' '{n++; if ($3 != $4) {printf "%s%s", sep, n; sep=" "}} END{print ""}' "${TMP}/gst/verdicts.tsv"
}

glue_setup; glue 1000; rc=$?
nr="$(grep -c . "${TMP}/gst/verdicts.tsv" 2>/dev/null || echo 0)"
if [ "$rc" = 0 ] && [ "$nr" = 5 ] && [ -z "$(glue_red)" ]; then ok "glue: a Backup and a drill that both succeed record five rows, all green"
else bad "glue: the passing pass" "rc=${rc}, rows=${nr}, red=[$(glue_red)]"; fi
# every call named its cluster
if [ -s "$SB/calls.log" ] && ! grep -v -- '--context=stub-ctx' "$SB/calls.log" >/dev/null; then ok "glue: every kubectl call names its cluster ($(grep -c . "$SB/calls.log") calls)"
else bad "glue: every kubectl call names its cluster" "$(grep -v -- '--context=stub-ctx' "$SB/calls.log" | head -3)"; fi
# the documented objects
if grep -q 'kind: Backup' "$SB/applied-${AUTH_NS}.yaml" && grep -q "cluster: { name: ${CL} }" "$SB/applied-${AUTH_NS}.yaml" \
   && grep -q 'method: plugin' "$SB/applied-${AUTH_NS}.yaml" && grep -q 'name: barman-cloud.cloudnative-pg.io' "$SB/applied-${AUTH_NS}.yaml"; then
  ok "glue: the Backup is the documented one (plugin method, the barman-cloud plugin, this cluster)"
else bad "glue: the Backup is the documented one" "$(cat "$SB/applied-${AUTH_NS}.yaml" 2>/dev/null)"; fi
if grep -q -- "-n ${AUTH_NS} create job --from=cronjob/tockmox-authentik-db-drill tockmox-authentik-db-drill-first" "$SB/calls.log"; then
  ok "glue: the drill Job is made from the drill CronJob, in the database's namespace, under the documented name"
else bad "glue: the drill Job is made from the drill CronJob" "$(grep 'create' "$SB/calls.log")"; fi
first_write="$(grep -E 'exec|apply' "$SB/calls.log" | head -1)"
if [[ "$first_write" == *"psql -U postgres -c SELECT pg_switch_wal();"* ]]; then
  ok "glue: the WAL switch comes before the Backup, as the page says"
else bad "glue: the WAL switch comes before the Backup" "$(grep -nE 'exec|apply' "$SB/calls.log")"; fi

# resume: the same two steps again make nothing twice and add no row
glue 1000; rc=$?
nr2="$(grep -c . "${TMP}/gst/verdicts.tsv")"
if [ "$rc" = 0 ] && [ "$nr2" = 5 ] && [ "$(grep -c ' apply ' "$SB/calls.log")" = 1 ] && [ "$(grep -c ' create job' "$SB/calls.log")" = 1 ]; then
  ok "glue: run again, it makes no second Backup or Job and records no row twice"
else bad "glue: resume" "rc=${rc}, rows=${nr2}, applies=$(grep -c ' apply ' "$SB/calls.log"), creates=$(grep -c ' create job' "$SB/calls.log")"; fi

# the wait yields when the budget is spent, and leaves no row for a step it did not finish
glue_setup; printf 'started' > "$SB/scenario-phase"; glue 0; rc=$?
if [ "$rc" = 75 ] && [ ! -s "${TMP}/gst/verdicts.tsv" ]; then ok "glue: a Backup still running with the budget spent yields (75) and records nothing"
else bad "glue: yield" "rc=${rc}, rows=$(grep -c . "${TMP}/gst/verdicts.tsv" 2>/dev/null)"; fi

# red variants of the glue
glue_setup; printf 'failed' > "$SB/scenario-phase"
mk_backups "$SB/backups-${AUTH_NS}.json" "$CL" failed 2026-11-10T21:01:00Z "$ID"
glue 1000
if [ "$(glue_red | awk '{print $1}')" = 1 ]; then ok "glue: a Backup that fails turns the base-backup row red"
else bad "glue: failed Backup" "red=[$(glue_red)]"; fi
glue_setup; mk_job "$SB/job-${AUTH_NS}.json" Failed; glue 1000
red="$(glue_red)"
if [[ " ${red} " == *" 3 "* ]]; then ok "glue: a drill Job that fails turns its Complete row red"
else bad "glue: failed drill" "red=[$(glue_red)]"; fi
glue_setup; printf 'register: NOT RECORDED, so this drill FAILS whatever its verdict (PASS): x\n' >> "$SB/log-${AUTH_NS}.txt"; glue 1000
red="$(glue_red)"
if [[ " ${red} " == *" 4 "* ]]; then ok "glue: a drill whose register write was refused turns its register row red"
else bad "glue: NOT RECORDED" "red=[$(glue_red)]"; fi

# ------------------------------------------------- P10 still runs every row
# A step deleted from P10 would leave this file green on the fixtures above. Count the calls.
calls_in() { # FILE ... how many of the five calls the file makes
  local n=0 pat
  for pat in 'record_migrations_rows "$S" "$MIG_JOB"' 'take_backup S02-authentik ' 'take_backup S02-litellm ' \
             'run_drill S03-authentik ' 'run_drill S03-litellm '; do
    grep -F -- "$pat" "$1" >/dev/null && n=$((n+1))
  done
  echo "$n"
}
[ "$(calls_in "$P10")" = 5 ] && ok "P10 runs the migrations rows, both backups and both drills" || bad "P10 runs the migrations rows, both backups and both drills" "found $(calls_in "$P10") of 5"
grep -v 'run_drill S03-litellm ' "$P10" > "${TMP}/p10-missing-drill.sh"
[ "$(calls_in "${TMP}/p10-missing-drill.sh")" = 4 ] && ok "P10 with one drill step deleted counts 4 of 5, so that deletion goes red" || bad "the deleted-drill mutation" "counted $(calls_in "${TMP}/p10-missing-drill.sh")"
# and finish_path is still the last call, after the drills
last="$(grep -n '^finish_path$' "$P10" | tail -1 | cut -d: -f1)"; s03="$(grep -n '^S=S03-restore-drills' "$P10" | cut -d: -f1)"
[ -n "$last" ] && [ -n "$s03" ] && [ "$s03" -lt "$last" ] && ok "the drills run before finish_path replays the verdicts" || bad "the drills run before finish_path" "S03 at ${s03:-none}, finish_path at ${last:-none}"

# ---------------------------------------------- the install time is never defaulted
# install_time_ok: only a whole number of seconds above zero is an install time
tm() { ( . "$FNS"; install_time_ok "$1" ) && echo yes || echo no; }
for v in 1 1762800000 007; do [ "$(tm "$v")" = yes ] && ok "install time: [${v}] is usable" || bad "install time: [${v}] is usable" "refused"; done
for v in "" 0 00 abc -5 1.5 "12 3"; do [ "$(tm "$v")" = no ] && ok "install time: [${v}] is refused" || bad "install time: [${v}] is refused" "accepted"; done
# the Backup row fed a cut-off of 0 or nothing is red whatever the Backup says, and says why
D="${TMP}/cut"; mkdir -p "$D"; ROWS_FILES="$D"
mk_backups "$D/S.backups.json" "$CL" completed 2026-11-10T21:01:00Z "$ID"; mk_sched "$D/S.scheduled.json" "$CL" plugin false
ROWS_AFTER="" RO="$(rows record_backup_rows S "$CL")"; expect "install time: a missing cut-off turns the base-backup row red, it is not read as 0" "1" "no usable install time"
ROWS_AFTER=0 RO="$(rows record_backup_rows S "$CL")"; expect "install time: a cut-off of 0 turns the base-backup row red" "1" "no usable install time"

# ---------------------------------------------------- the path's own gate, as a script
# run_p10 FILE STATE-DIR [VAR=VALUE ...] ... the path as run.sh runs it (a receipt directory, a path name), kubectl a stub that
# records its calls. Prints the receipt, then the exit status. The budget is 0 so a copy that does NOT stop at its
# gate yields at once instead of waiting on a stub.
GT="${TMP}/gate"; mkdir -p "$GT/tree/paths" "$GT/bin"
ln -s "${HERE}/lib" "$GT/tree/lib"
cat > "$GT/bin/kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "$GT/kcalls"
exit 1
STUB
chmod +x "$GT/bin/kubectl"
run_p10() {
  local f="$1" sd="$2"; shift 2
  rm -rf "$GT/r" "$GT/kcalls"
  env PATH="$GT/bin:$PATH" OUTCOME_RECEIPT_DIR="$GT/r" TOCKMOX_PATH_NAME=P10-fresh-install-recovery \
      KUBE_CONTEXT=stub-ctx TOCKMOX_P10_BUDGET=0 ${sd:+TOCKMOX_P09_STATE="$sd"} "$@" \
      bash "$f" > "$GT/out" 2>&1
  local rc=$?
  printf '%s|%s|%s' "$rc" "$(cut -d' ' -f1 "$GT/r/P10-fresh-install-recovery" 2>/dev/null)" "$(grep -c . "$GT/kcalls" 2>/dev/null || echo 0)"
}
gate_cases() { # FILE LABEL-PREFIX WANT(blocked|not) ... runs the four precondition cases against FILE
  local f="$1" pre="$2" want="$3" sd="$GT/p09" got
  rm -rf "$sd"
  check() { # LABEL EXPECT-RECEIPT-WORD ARGS... ; BLOCKED means rc 0, receipt BLOCKED, no kubectl call
    local lab="$1" r; shift
    r="$(run_p10 "$f" "$@")"
    if [ "$want" = blocked ]; then
      [ "$r" = "0|BLOCKED|0" ] && ok "${pre}${lab}: BLOCKED, exit 0, and no cluster call" || bad "${pre}${lab}" "rc|receipt|kubectl calls = [${r}]; $(tail -3 "$GT/out" | tr '\n' ';' | cut -c1-200)"
    else
      [ "$r" != "0|BLOCKED|0" ] && ok "${pre}${lab}: the mutated copy is NOT blocked, so the case above would catch it" || bad "${pre}${lab}" "the mutated copy still declared BLOCKED"
    fi
  }
  check "no P09 state directory named" ""
  mkdir -p "$sd"
  check "a P09 state directory that never ended PASS (no p09-passed marker)" "$sd"
  : > "$sd/p09-passed"
  check "a PASS marker but no root-applied-at" "$sd"
  printf '0' > "$sd/root-applied-at"
  check "a root-applied-at of 0" "$sd"
  printf 'soon' > "$sd/root-applied-at"
  check "a root-applied-at that is not a number" "$sd"
}
gate_cases "$P10" "gate: " blocked
# a state that is complete is NOT blocked: it goes on to the steps (here yielding at once on its zero budget)
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"; printf '1762800000' > "$GT/p09/root-applied-at"
r="$(run_p10 "$P10" "$GT/p09")"
[ "${r%%|*}" = 75 ] && ok "gate: a state with P09's PASS marker and an install time is not blocked (it starts the steps; exit 75 on the zero budget)" || bad "gate: a complete state is not blocked" "got [${r}]; $(tail -3 "$GT/out" | tr '\n' ';' | cut -c1-200)"

# mutated copies of P10: each removes one precondition and must stop being BLOCKED in the case aimed at it
mkp() { mut "$P10" "$GT/tree/paths/$1" "$2" "$3"; }
only_case() { # FILE LABEL EXPECT-NOT-BLOCKED-STATE-SETUP ... one case against a mutant
  local f="$1" lab="$2" r; shift 2
  r="$(run_p10 "$f" "$@")"
  [ "$r" != "0|BLOCKED|0" ] && ok "gate mutation: ${lab} is caught (the copy was not BLOCKED: ${r})" || bad "gate mutation: ${lab}" "the mutated copy still declared BLOCKED"
}
# 1. the cut-off defaults to 0 when the file is missing, and the validity check is gone
mkp m-default0.sh '|| true)"' '|| echo 0)"'
mut "$GT/tree/paths/m-default0.sh" "$GT/tree/paths/m-default0.sh" 'install_time_ok "$ROOT_APPLIED" || blocked' ': || blocked'
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"
only_case "$GT/tree/paths/m-default0.sh" "defaulting the install time to 0 with no root-applied-at" "$GT/p09"
# 2. no check that P09 ended PASS
mkp m-nomarker.sh '[ -f "${P09_STATE}/p09-passed" ] || blocked' ': || blocked'
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; printf '1762800000' > "$GT/p09/root-applied-at"
only_case "$GT/tree/paths/m-nomarker.sh" "dropping the check that P09 ended PASS" "$GT/p09"
# 2b. the validity check alone is gone: an install time of 0 is then read as an install time
mkp m-nocheck.sh 'install_time_ok "$ROOT_APPLIED" || blocked' ': || blocked'
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"; printf '0' > "$GT/p09/root-applied-at"
only_case "$GT/tree/paths/m-nocheck.sh" "dropping the check that the install time is a positive number (a file holding 0)" "$GT/p09"
# 3. a default for the state directory (the stale-state-on-a-runner case)
mkp m-defstate.sh 'P09_STATE="${TOCKMOX_P09_STATE:-}"' "P09_STATE=\"\${TOCKMOX_P09_STATE:-$GT/p09}\""
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"; printf '1762800000' > "$GT/p09/root-applied-at"
only_case "$GT/tree/paths/m-defstate.sh" "a default P09 state directory (a stale one would be read as an install)" ""

# ----------------------------------------------------- run.sh: the all lane cannot run it against no install
# run.sh discovers paths/P*.sh, so P10 is discovered, and shares P09's route group so it costs no cluster of its own.
DRY="$(env TOCKMOX_DRY_RUN=1 TOCKMOX_DOCS_REF=HEAD TOCKMOX_WORKDIR="$GT/w0" bash "${HERE}/run.sh" 2>&1)"
if printf '%s\n' "$DRY" | grep -E "group 'argocd-helm': .*P09-install-md-end-to-end P10-fresh-install-recovery" >/dev/null; then
  ok "run.sh: a run with no arguments discovers P10, in P09's route group, after P09 (no extra cluster)"
else bad "run.sh: discovery" "$(printf '%s' "$DRY" | grep group | tr '\n' ';' | cut -c1-300)"; fi
# ... and P10 run by run.sh with no P09 state declares BLOCKED: the run is not red, and P10 is not UNCONVERTED.
cat > "$GT/bin/kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "$GT/kcalls"
case "\$*" in *get-contexts*) echo stub-ctx ;; *"get nodes"*) printf True ;; *"version -o json"*) echo '{"serverVersion":{"gitVersion":"v1.33.0"}}' ;; esac
exit 0
STUB
echo "apiVersion: v1" > "$GT/kc"
rm -f "$GT/kcalls"
RUNOUT="$(env PATH="$GT/bin:$PATH" TOCKMOX_EXISTING_KUBECONFIG="$GT/kc" KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD \
          TOCKMOX_WORKDIR="$GT/w1" TOCKMOX_P09_STATE= bash "${HERE}/run.sh" P10 2>&1)"; RUNRC=$?
if [ "$RUNRC" = 0 ] && printf '%s\n' "$RUNOUT" | grep -F 'OUTCOME:  BLOCKED' >/dev/null \
   && printf '%s\n' "$RUNOUT" | grep -F 'UNCONVERTED    : 0' >/dev/null \
   && printf '%s\n' "$RUNOUT" | grep -F 'paths failed   : 0' >/dev/null; then
  ok "run.sh: P10 with no install declares BLOCKED; the run exits 0 with nothing failed and nothing UNCONVERTED"
else bad "run.sh: P10 with no install" "rc=${RUNRC}; $(printf '%s' "$RUNOUT" | tail -12 | tr '\n' ';' | cut -c1-400)"; fi
# the only kubectl calls were run.sh's own readiness reads: P10 made none of its own
if ! grep -E 'jobs|backups|create job|exec' "$GT/kcalls" >/dev/null 2>&1; then ok "run.sh: P10 made no cluster read or write of its own"
else bad "run.sh: P10 made a cluster call" "$(grep -E 'jobs|backups|create job|exec' "$GT/kcalls" | head -3)"; fi

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof of P13's rows: a ResourceQuota that refuses a restore drill, a drill that cannot write its
# register row, the alert that says so, and the revert of each fault. No cluster. Four layers.
#
#   1. The verdicts (lib/p09-recovery.py). A green fixture for each, then one planted red per assertion the verdict
#      makes, each of which must turn that verdict red for the stated reason. An empty or unreadable input is a red
#      verdict, never a green one.
#   2. The steps (step_quota, step_register), read out of P13 itself and run unmodified against a stub kubectl that
#      keeps state in marker files and logs every call: every call names its cluster, the fault is the documented
#      shape, the Job is not started until the quota has been counted, a fault is reverted AND read back as gone
#      when the middle of the step fails (the Job cannot be created, cannot be read, has no log, the planting
#      itself fails, the quota is never counted, the template cannot be built, Prometheus cannot be read), and a
#      revert that does not work turns its row red and leaves the object on the list the trap deletes from.
#   3. The path as a script: green end to end (outcome PASS, nothing left planted), and killed in the middle of a
#      wait (the trap deletes the fault). Then mutated copies of P13 that lose a guard, each of which a probe
#      must catch: the revert step deleted, the trap deleted, the read-back that cannot go red, the planted list
#      never written, the context dropped from a delete, the quota wait skipped, the alert row that cannot go red,
#      the no-PASS verdict replaced by a constant.
#   4. The gate: P13 runs after P09 and must never run, or pass, without an install to break. It is run as a
#      script and by run.sh, and must declare BLOCKED (not a failure, not UNCONVERTED, no cluster call of its own)
#      when P09's state, its PASS marker or the install time is missing; the same checks are run against mutated
#      copies that must not. The lane's P13 block is checked for its place; its exit rule is lane-outcome-test.sh's.
#
#   ./tests/executed-docs/fault-rows-test.sh
#   P13=/path/to/P13.sh ./tests/executed-docs/fault-rows-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture text is literal
# shellcheck disable=SC2034  # STATE, KUBE_CONTEXT, BUDGET and T0 are read by the P13 functions sourced below
# shellcheck disable=SC2329  # _emit and sleep are stubs for the sourced functions
# shellcheck disable=SC1090,SC2030,SC2031  # the P13 functions are sourced from a file built at run time; PATH is set per subshell on purpose
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
P13="${P13:-${HERE}/paths/P13-planted-faults.sh}"
PY="${HERE}/lib/p09-recovery.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
# every wait in the path is bounded by one of these; the tests run them at zero (one read, then the verdict), and the alert's at three so a few polls can be made
export TOCKMOX_P13_QUOTA_WAIT=0 TOCKMOX_P13_QUOTA_JOB_WAIT=0 TOCKMOX_P13_DRILL_JOB_WAIT=0 TOCKMOX_P13_ALERT_WAIT=3
export TOCKMOX_P13_CLEAR_WAIT=3 TOCKMOX_P13_GONE_WAIT=0 TOCKMOX_P13_CLUSTER_WAIT=0 TOCKMOX_P13_POLL=0 TOCKMOX_P13_ALERT_POLL=0

mut() { # IN OUT OLD NEW ... a copy with every OLD replaced by NEW; refuses an edit that changes nothing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
t = s.replace(old, new)
assert t != s, "the edit changed nothing: %r" % old
open(dst, "w", encoding="utf-8").write(t)
PY
}

# ------------------------------------------------------------------ 1. the verdicts
CL=tockmox-authentik-db
LDB=tockmox-litellm-db
ID=20261110T210100
SUM=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
BKT=tockmox-drill-register
FB="p13-no-such-bucket"
QUOTA=tockmox-p13-refuse-drill
KEY=count/clusters.postgresql.cnpg.io
GRP=tockmox.ai.restore-drill
ALR=TockmoxRestoreDrillFailed

mk_job() { # FILE complete|failed|running
  case "$2" in
    complete) c='[{"type":"Complete","status":"True"}]' ;;
    failed) c='[{"type":"Failed","status":"True","reason":"BackoffLimitExceeded"}]' ;;
    both) c='[{"type":"Failed","status":"True"},{"type":"Complete","status":"True"}]' ;;
    *) c='[]' ;;
  esac
  printf '{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"x"},"status":{"active":1,"conditions":%s}}\n' "$c" > "$1"
}
APPLY_ERR='Error from server (Forbidden): error when creating "STDIN": clusters.postgresql.cnpg.io "tockmox-authentik-db-drillcheck" is forbidden: exceeded quota: tockmox-p13-refuse-drill, requested: count/clusters.postgresql.cnpg.io=1, used: count/clusters.postgresql.cnpg.io=1, limited: count/clusters.postgresql.cnpg.io=0'
ROW_ERR='Error from server (Forbidden): error when creating  STDIN : clusters.postgresql.cnpg.io tockmox-authentik-db-drillcheck is forbidden: exceeded quota: tockmox-p13-refuse-drill, requested: count/clusters.postgresql.cnpg.io:1, used: count/clusters.postgresql.cnpg.io:1, limited: count/clusters.postgresql.cnpg.io:0'
mk_qlog() { # FILE [APPLY-TEXT] [ROW-DETAIL] [VERDICT] [RECORDED-VERDICT]
  local apply="${2-$APPLY_ERR}" detail="${3-apply refused: $ROW_ERR}" verdict="${4:-FAIL}" rv="${5:-FAIL}"
  cat > "$1" <<EOF
backup: ${ID}
image: ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
apply: ${apply}
register: 2026-11-10T21:04:05Z ${verdict} ${detail} backup=${ID}
register: recorded s3://${BKT}/${CL}/20261110T210405Z-${rv}.json sha256=${SUM}
EOF
}
RWRITE="write of s3://${FB}/${LDB}/20261110T210405Z-PASS.json refused (curl exit 0, http 404): <?xml version 1.0 encoding UTF-8?><Error><Code>NoSuchBucket</Code></Error>"
mk_rlog() { # FILE [NOT-RECORDED-LINE-OR-NONE] [VERDICT-IN-THE-LINE] [ROW-VERDICT]
  local reason="${2-$RWRITE}" lv="${3:-PASS}" rv="${4:-PASS}"
  cat > "$1" <<EOF
backup: ${ID}
image: ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
apply: cluster.postgresql.cnpg.io/${LDB}-drillcheck created
wait: cluster.postgresql.cnpg.io/${LDB}-drillcheck condition met
verify: in_recovery=f public_tables=106
cluster.postgresql.cnpg.io "${LDB}-drillcheck" deleted from tockmox-ai namespace
EOF
  [ "$rv" = none ] || echo "register: 2026-11-10T21:04:05Z ${rv} in_recovery=f public_tables=106 backup=${ID}" >> "$1"
  [ "$reason" = none ] || echo "register: NOT RECORDED, so this drill FAILS whatever its verdict (${lv}): ${reason}" >> "$1"
}
mk_list() { # FILE KIND NAME...  ... a kubectl list holding those names
  local f="$1" kind="$2"; shift 2
  python3 - "$f" "$kind" "$@" <<'PY'
import json, sys
f, kind, names = sys.argv[1], sys.argv[2], sys.argv[3:]
json.dump({"apiVersion": "v1", "kind": "List", "items": [{"kind": kind, "metadata": {"name": n}} for n in names]}, open(f, "w"))
PY
}
mk_quota() { # FILE NAME KEY [counted|uncounted]
  if [ "${4:-counted}" = counted ]; then st="{\"hard\":{\"$3\":\"0\"},\"used\":{\"$3\":\"1\"}}"; else st='{}'; fi
  printf '{"kind":"ResourceQuota","metadata":{"name":"%s"},"spec":{"hard":{"%s":"0"}},"status":%s}\n' "$2" "$3" "$st" > "$1"
}
mk_rules() { # FILE STATE [FOR] [HEALTH] [GROUP] [OTHER-GROUP-STATE]
  python3 - "$1" "$2" "${3:-600}" "${4:-ok}" "${5:-$GRP}" "${6:-inactive}" <<'PY'
import json, sys
f, state, dur, health, group, other = sys.argv[1:7]
def rule(name, st, d):
    return {"state": st, "name": name, "query": "up", "duration": float(d), "keepFiringFor": 0, "health": health,
            "evaluationTime": 0.001, "type": "alerting", "labels": {"severity": "warning"}, "alerts": []}
doc = {"status": "success", "data": {"groups": [
    {"name": group, "file": "/etc/prometheus/rules/a.yaml", "interval": 300,
     "rules": [rule("TockmoxRestoreDrillNeverRan", "inactive", 900), rule("TockmoxRestoreDrillFailed", state, dur)]},
    {"name": "tockmox.identity.restore-drill", "file": "/etc/prometheus/rules/b.yaml", "interval": 300,
     "rules": [rule("TockmoxRestoreDrillFailed", other, 600)]}]}}
json.dump(doc, open(f, "w"))
PY
}
mk_template() { # FILE [plain|valuefrom|noenv|nocontainer]
  python3 - "$1" "${2:-plain}" <<'PY'
import json, sys
f, mode = sys.argv[1:3]
env = [{"name": "REG_ENDPOINT", "value": "http://garage:3900"},
       {"name": "REG_BUCKET", "value": "tockmox-drill-register"},
       {"name": "REG_AK", "valueFrom": {"secretKeyRef": {"name": "s", "key": "ACCESS_KEY_ID"}}}]
if mode == "valuefrom":
    env[1] = {"name": "REG_BUCKET", "valueFrom": {"secretKeyRef": {"name": "s", "key": "B"}}}
if mode == "noenv":
    del env[1]
name = "other" if mode == "nocontainer" else "drill"
doc = {"apiVersion": "batch/v1", "kind": "Job",
       "metadata": {"name": "x", "creationTimestamp": None, "annotations": {"cronjob.kubernetes.io/instantiate": "manual"},
                    "ownerReferences": [{"apiVersion": "batch/v1", "kind": "CronJob", "name": "c", "uid": "u"}]},
       "spec": {"backoffLimit": 0, "template": {"spec": {"containers": [{"name": name, "env": env}], "restartPolicy": "Never"}}},
       "status": {}}
json.dump(doc, open(f, "w"))
PY
}
D="${TMP}/v"; mkdir -p "$D"
# vcase LABEL WANT FILE ARGS... ... the first line of the verdict must be exactly WANT, or (WANT ending in '*') begin with it
vcase() {
  local lab="$1" want="$2" f="$3" got; shift 3
  got="$(python3 -I "$PY" "$@" < "$f" 2>&1 | head -1)"
  case "$want" in
    *"*") [ "${got#"${want%\*}"}" != "$got" ] && ok "$lab" || bad "$lab" "got [${got}] want [${want}]" ;;
    *) [ "$got" = "$want" ] && ok "$lab" || bad "$lab" "got [${got}] want [${want}]" ;;
  esac
}
: > "$D/empty"
echo '{"kind":"List","items":[' > "$D/trunc"

# --- job-not-complete
mk_job "$D/j" failed;   vcase "job-not-complete: a Failed Job reads 'Failed, never Complete'" "Failed, never Complete" "$D/j" job-not-complete
mk_job "$D/j" complete; vcase "job-not-complete: a Complete Job is red (the fault did not stop the drill)" "reached Complete" "$D/j" job-not-complete
mk_job "$D/j" both;     vcase "job-not-complete: a Job with both conditions is red" "reached Complete" "$D/j" job-not-complete
mk_job "$D/j" running;  vcase "job-not-complete: a Job still running is neither" "still running*" "$D/j" job-not-complete
vcase "job-not-complete: an empty read is unreadable, not 'never Complete'" "unreadable*" "$D/empty" job-not-complete
mk_list "$D/j" Job a;   vcase "job-not-complete: a list is not a Job" "unreadable*" "$D/j" job-not-complete

# --- drill-no-pass
mk_qlog "$D/l";  vcase "drill-no-pass: the quota refusal's log holds no PASS" "no PASS recorded" "$D/l" drill-no-pass --allow-row no
mk_qlog "$D/l" "$APPLY_ERR" "in_recovery=f public_tables=106" PASS PASS
vcase "drill-no-pass: a recorded PASS object is red" "a PASS object was recorded" "$D/l" drill-no-pass --allow-row no
vcase "drill-no-pass: a recorded PASS object is red even where the PASS row is allowed" "a PASS object was recorded" "$D/l" drill-no-pass --allow-row yes
mk_rlog "$D/l"
vcase "drill-no-pass: a PASS row with nothing recorded is red when rows are not allowed" "a PASS row is in the log" "$D/l" drill-no-pass --allow-row no
vcase "drill-no-pass: a PASS row with nothing recorded is green where the restore is allowed to pass" "no PASS recorded" "$D/l" drill-no-pass --allow-row yes
vcase "drill-no-pass: an empty log is unreadable" "unreadable*" "$D/empty" drill-no-pass --allow-row yes

# --- drill-refusal
mk_qlog "$D/l"; vcase "drill-refusal: the apply: line and the FAIL row both name the refusal" "refusal named in the apply output and the FAIL row" "$D/l" drill-refusal --text "exceeded quota"
mk_qlog "$D/l" "cluster.postgresql.cnpg.io/x created"
vcase "drill-refusal: an apply: line that does not name it is red" "no apply: line names*" "$D/l" drill-refusal --text "exceeded quota"
mk_qlog "$D/l" "$APPLY_ERR" "apply refused: Error from server (Forbidden): something else"
vcase "drill-refusal: a FAIL row that does not name it is red" "the FAIL row does not name*" "$D/l" drill-refusal --text "exceeded quota"
mk_qlog "$D/l" "$APPLY_ERR" "cluster never became Ready (phase: unknown): exceeded quota"
vcase "drill-refusal: a FAIL row from another failure path is red even if it repeats the words" "no FAIL row says 'apply refused:'" "$D/l" drill-refusal --text "exceeded quota"
mk_qlog "$D/l" "$APPLY_ERR" "in_recovery=f public_tables=1" PASS PASS
vcase "drill-refusal: a PASS row is not a refusal" "no FAIL row says 'apply refused:'" "$D/l" drill-refusal --text "exceeded quota"
vcase "drill-refusal: an empty log is unreadable" "unreadable*" "$D/empty" drill-refusal --text "exceeded quota"
vcase "drill-refusal: no text to look for is unreadable, not a pass" "unreadable*" "$D/l" drill-refusal --text ""

# --- drill-unrecorded
mk_rlog "$D/l"; vcase "drill-unrecorded: restore PASS, write refused, nothing recorded" "restore PASS, register write refused, nothing recorded" "$D/l" drill-unrecorded --db "$LDB" --bucket "$FB"
mk_rlog "$D/l"; echo "register: recorded s3://${FB}/${LDB}/20261110T210405Z-PASS.json sha256=${SUM}" >> "$D/l"
vcase "drill-unrecorded: a recorded object means the fault did not bite" "a register object was recorded" "$D/l" drill-unrecorded --db "$LDB" --bucket "$FB"
mk_rlog "$D/l" none
vcase "drill-unrecorded: no NOT RECORDED line is red" "no NOT RECORDED line" "$D/l" drill-unrecorded --db "$LDB" --bucket "$FB"
mk_rlog "$D/l" "$RWRITE" FAIL FAIL
vcase "drill-unrecorded: a restore that itself FAILED is red (the planted fault is not the only failure)" "the restore's own verdict was FAIL*" "$D/l" drill-unrecorded --db "$LDB" --bucket "$FB"
mk_rlog "$D/l" "$RWRITE" PASS none
vcase "drill-unrecorded: a NOT RECORDED line with no PASS row before it is red" "no PASS row before the NOT RECORDED line" "$D/l" drill-unrecorded --db "$LDB" --bucket "$BKT"
mk_rlog "$D/l"
vcase "drill-unrecorded: a refusal naming another bucket is red" "the refusal does not read*" "$D/l" drill-unrecorded --db "$LDB" --bucket "$BKT"
mk_rlog "$D/l" "read back of s3://${FB}/${LDB}/k failed (curl exit 0, http 500): x"
vcase "drill-unrecorded: a failed read-back is not a refused write" "the refusal does not read*" "$D/l" drill-unrecorded --db "$LDB" --bucket "$FB"
vcase "drill-unrecorded: an empty log is unreadable" "unreadable*" "$D/empty" drill-unrecorded --db "$LDB" --bucket "$FB"

# --- absent
mk_list "$D/a" Job one two; vcase "absent: a name in the list reads present" "present" "$D/a" absent --kind Job --name two
mk_list "$D/a" Job one;     vcase "absent: a name not in the list reads absent" "absent" "$D/a" absent --kind Job --name two
mk_list "$D/a" Job;         vcase "absent: an empty list reads absent" "absent" "$D/a" absent --kind Job --name two
mk_list "$D/a" Cluster two; vcase "absent: the same name under another kind is not this object" "absent" "$D/a" absent --kind Job --name two
vcase "absent: an empty read is unreadable, never 'gone'" "unreadable*" "$D/empty" absent --kind Job --name two
vcase "absent: a truncated read is unreadable, never 'gone'" "unreadable*" "$D/trunc" absent --kind Job --name two
mk_job "$D/a" failed;       vcase "absent: a single object is not a list" "unreadable*" "$D/a" absent --kind Job --name x

# --- quota-enforced
mk_quota "$D/q" "$QUOTA" "$KEY";            vcase "quota-enforced: counted and limiting the resource reads enforced" "enforced" "$D/q" quota-enforced --name "$QUOTA" --key "$KEY"
mk_quota "$D/q" "$QUOTA" "$KEY" uncounted;  vcase "quota-enforced: a quota the controller has not counted yet is red" "not enforced yet*" "$D/q" quota-enforced --name "$QUOTA" --key "$KEY"
mk_quota "$D/q" "$QUOTA" "pods";            vcase "quota-enforced: a quota that limits another resource is red" "the quota does not limit*" "$D/q" quota-enforced --name "$QUOTA" --key "$KEY"
mk_quota "$D/q" other "$KEY";               vcase "quota-enforced: another quota is red" "the quota is other*" "$D/q" quota-enforced --name "$QUOTA" --key "$KEY"
vcase "quota-enforced: an empty read is unreadable" "unreadable*" "$D/empty" quota-enforced --name "$QUOTA" --key "$KEY"

# --- alert-rule and alert-state
mk_rules "$D/r" inactive; vcase "alert-rule: loaded, healthy, for 600s" "loaded, healthy, for 600s" "$D/r" alert-rule --group "$GRP" --alert "$ALR" --for 600
mk_rules "$D/r" inactive 300;  vcase "alert-rule: a for: that is not 600s is red" "for: is 300s, not 600s" "$D/r" alert-rule --group "$GRP" --alert "$ALR" --for 600
mk_rules "$D/r" inactive 600 err; vcase "alert-rule: a rule that does not evaluate is red" "rule unhealthy*" "$D/r" alert-rule --group "$GRP" --alert "$ALR" --for 600
mk_rules "$D/r" inactive 600 ok other.group; vcase "alert-rule: the rule not in the named group is red (the other group's twin does not count)" "rule not loaded*" "$D/r" alert-rule --group "$GRP" --alert "$ALR" --for 600
vcase "alert-rule: an empty read is unreadable" "unreadable*" "$D/empty" alert-rule --group "$GRP" --alert "$ALR" --for 600
echo '{"status":"error","error":"x"}' > "$D/r"; vcase "alert-rule: an error answer is unreadable" "unreadable*" "$D/r" alert-rule --group "$GRP" --alert "$ALR" --for 600
for st in inactive pending firing; do
  mk_rules "$D/r" "$st"; vcase "alert-state: reads ${st}" "$st" "$D/r" alert-state --group "$GRP" --alert "$ALR"
done
mk_rules "$D/r" inactive 600 ok "$GRP" firing; vcase "alert-state: the other group's firing twin is not this group's state" "inactive" "$D/r" alert-state --group "$GRP" --alert "$ALR"
mk_rules "$D/r" inactive 600 ok other.group; vcase "alert-state: no such group is 'rule not loaded', not inactive" "rule not loaded*" "$D/r" alert-state --group "$GRP" --alert "$ALR"
mk_rules "$D/r" weird; vcase "alert-state: a state that is none of the three is unreadable" "unreadable*" "$D/r" alert-state --group "$GRP" --alert "$ALR"
vcase "alert-state: an empty read is unreadable, not inactive" "unreadable*" "$D/empty" alert-state --group "$GRP" --alert "$ALR"

# --- job-with-env
jwe() { python3 -I "$PY" job-with-env --container drill --env REG_BUCKET --value "$FB" --name p13job < "$1" | head -1; }
mk_template "$D/t"; out="$(jwe "$D/t")"
if python3 - "$out" "$FB" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); fb = sys.argv[2]
env = {e["name"]: e for e in d["spec"]["template"]["spec"]["containers"][0]["env"]}
assert d["metadata"]["name"] == "p13job" and "status" not in d and "creationTimestamp" not in d["metadata"]
assert env["REG_BUCKET"]["value"] == fb and env["REG_ENDPOINT"]["value"] == "http://garage:3900" and "valueFrom" in env["REG_AK"]
assert d["metadata"]["ownerReferences"] and d["metadata"]["annotations"]["cronjob.kubernetes.io/instantiate"] == "manual"
PY
then ok "job-with-env: one env value changed, the name ours, the rest of the CronJob's template kept"
else bad "job-with-env: the built Job" "$out"; fi
for m in valuefrom noenv nocontainer; do
  mk_template "$D/t" "$m"; out="$(jwe "$D/t")"
  case "$out" in "cannot build:"*) ok "job-with-env: a template with ${m} is 'cannot build', so no fault is silently left unplanted" ;; *) bad "job-with-env: ${m}" "$out" ;; esac
done
out="$(jwe "$D/empty")"; case "$out" in "cannot build:"*) ok "job-with-env: an empty template is 'cannot build'" ;; *) bad "job-with-env: empty" "$out" ;; esac
mk_list "$D/t" Job a; out="$(jwe "$D/t")"; case "$out" in "cannot build:"*) ok "job-with-env: a list is 'cannot build'" ;; *) bad "job-with-env: list" "$out" ;; esac
if python3 -I "$PY" alert-rule --group g --alert a < /dev/null >/dev/null 2>&1; then bad "verdicts: a missing --for is refused" "exit 0"
else ok "verdicts: a missing option is a usage error (exit 2), not a verdict"; fi

# ------------------------------------------------------------------ 2. the steps against a stub kubectl
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\) +\\{" {on=1; print; if ($0 ~ /\}[ \t]*$/) exit; next} on {print} on && /^}/ {exit}' "$P13"; }
FNS="${TMP}/p13-fns.sh"
: > "$FNS"
for f in record note done_step mark_done budget_left yield reset_rows recovery_verdict planted_add planted_remove delete_planted \
         read_list kind_of absent_verdict revert_object revert_all prom_read alert_wait job_wait step_quota step_register; do
  body="$(fn_of "$f")"
  if [ -z "$body" ]; then bad "P13 defines ${f}()" "not found in ${P13}"; else printf '%s\n' "$body" >> "$FNS"; fi
done
grep -E '^(IDENTITY_NS|IDENTITY_CRON|IDENTITY_DB|AI_NS|AI_CRON|AI_DB|DRILL_BUCKET|DRILL_CONTAINER|QUOTA_NAME|QUOTA_KEY|QUOTA_TEXT|FAULT_BUCKET|Q_JOB|R_JOB|RULE_GROUP|ALERT|ALERT_FOR|PROM_NS|PROM_SVC|PROM_PORT|QUOTA_WAIT|QUOTA_JOB_WAIT|DRILL_JOB_WAIT|ALERT_WAIT|CLEAR_WAIT|GONE_WAIT|CLUSTER_WAIT|POLL|ALERT_POLL|WITH_ALERT|JOB_WAITED)=' "$P13" >> "$FNS"

SB="${TMP}/sb"; BIN="${TMP}/bin"; mkdir -p "$BIN"
cat > "$BIN/kubectl" <<'STUB'
#!/bin/bash
# A kubectl that answers from files and keeps "created" in marker files. Every call is logged.
sb="${SB:?}"
echo "$*" >> "$sb/calls.log"
a=(); ns=""; args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --context=*) ;;
    -n) i=$((i+1)); ns="${args[$i]}" ;;
    *) a+=("${args[$i]}") ;;
  esac
  i=$((i+1))
done
sc() { if [ -s "$sb/sc-$1" ]; then cat "$sb/sc-$1"; else printf '%s' "${2:-}"; fi; }
mark() { printf '%s/m-%s-%s-%s' "$sb" "$1" "$ns" "$2"; }
markers() { local f; for f in "$sb"/m-"$1"-"$ns"-*; do [ -e "$f" ] && printf '%s\n' "${f##*/m-$1-$ns-}"; done; return 0; }
lst() { local kind="$1" out sep=""; shift; out='{"apiVersion":"v1","kind":"List","items":['
  for n in "$@"; do out+="${sep}{\"kind\":\"${kind}\",\"metadata\":{\"name\":\"${n}\"}}"; sep=,; done; printf '%s]}' "$out"; }
fail() { echo "$1" >&2; exit 1; }
case "${a[0]:-} ${a[1]:-}" in
  "get --raw")
    [ -n "$(sc raw-fail)" ] && fail "the server is unavailable"
    n="$(sc rawn 0)"; printf '%s' $((n+1)) > "$sb/sc-rawn"
    read -r -a seq <<< "$(sc rules-seq inactive)"
    idx=$n; [ "$idx" -ge "${#seq[@]}" ] && idx=$((${#seq[@]}-1))
    cat "$sb/rules-${seq[$idx]}.json"; exit 0 ;;
  "get cronjobs") read -r -a names <<< "$(sc cronjobs "tockmox-authentik-db-drill tockmox-litellm-db-drill")"; lst CronJob "${names[@]}"; exit 0 ;;
  "get resourcequotas") mapfile -t names < <(markers quota); lst ResourceQuota "${names[@]}"; exit 0 ;;
  "get resourcequota")
    [ -e "$(mark quota "${a[2]}")" ] || fail "NotFound"
    cat "$sb/quota-$(sc quota-status counted).json"; exit 0 ;;
  "apply -f")
    body="$(cat)"; printf '%s\n' "$body" >> "$sb/applied-${ns}.yaml"
    [ -n "$(sc plant-fail)" ] && fail "admission webhook denied the request"
    name="$(printf '%s\n' "$body" | sed -n 's/^ *name: *//p' | head -1)"
    : > "$(mark quota "$name")"; echo "resourcequota/${name} created"; exit 0 ;;
  "create job")
    case " ${a[*]} " in *" --dry-run=client "*) cat "$sb/template.json"; exit 0 ;; esac
    [ -n "$(sc create-fail)" ] && fail "create refused"
    : > "$(mark job "${a[${#a[@]}-1]}")"; echo "job.batch/${a[${#a[@]}-1]} created"; exit 0 ;;
  "create -f")
    body="$(cat)"; printf '%s' "$body" > "$sb/created-${ns}.json"
    [ -n "$(sc create-fail)" ] && fail "create refused"
    name="$(printf '%s' "$body" | grep -o '"metadata":{"name":"[^"]*"' | head -1 | sed 's/.*"name":"//; s/"$//')"
    : > "$(mark job "$name")"; echo "job.batch/${name} created"; exit 0 ;;
  "get job")
    if [ -n "$(sc block-get-job)" ]; then
      : > "$sb/blocked"
      for _ in $(seq 1 300); do [ -e "$sb/release" ] && break; sleep 0.1; done
      fail "interrupted"
    fi
    [ -e "$(mark job "${a[2]}")" ] || fail "NotFound"
    [ -n "$(sc job-garbage)" ] && { echo "this is not json"; exit 0; }
    cat "$sb/job-${ns}.json"; exit 0 ;;
  "get jobs") mapfile -t names < <(markers job); lst Job "${names[@]}"; exit 0 ;;
  "get clusters.postgresql.cnpg.io")
    mapfile -t names < <(markers cluster; sc "clusters-${ns}" | tr ' ' '\n' | grep .); lst Cluster "${names[@]}"; exit 0 ;;
  "delete job"|"delete resourcequota"|"delete cluster.postgresql.cnpg.io")
    case "${a[1]}" in job) kind=job ;; resourcequota) kind=quota ;; *) kind=cluster ;; esac
    if [ -n "$(sc delete-stuck)" ]; then echo "${a[1]} ${a[2]}: deletion is taking a while"; exit 0; fi
    rm -f "$(mark "$kind" "${a[2]}")"; echo "${a[1]} \"${a[2]}\" deleted"; exit 0 ;;
esac
case "${a[0]:-}" in logs) [ -n "$(sc logs-fail)" ] && fail "no pod"; cat "$sb/log-${ns}.txt"; exit 0 ;; esac
fail "stub kubectl: no answer for: ${a[*]}"
STUB
chmod +x "$BIN/kubectl"

QNS=tockmox-authentik; RNS=tockmox-ai
QJOB=tockmox-authentik-db-drill-p13quota; RJOB=tockmox-litellm-db-drill-p13reg
sb_setup() { # DIR ... fresh stub state in DIR with the green scenario for both steps
  local SB="$1"
  rm -rf "$SB"; mkdir -p "$SB"
  mk_job "$SB/job-${QNS}.json" failed; mk_job "$SB/job-${RNS}.json" failed
  mk_qlog "$SB/log-${QNS}.txt"; mk_rlog "$SB/log-${RNS}.txt"
  mk_quota "$SB/quota-counted.json" "$QUOTA" "$KEY"; mk_quota "$SB/quota-none.json" "$QUOTA" "$KEY" uncounted
  mk_template "$SB/template.json"
  mk_rules "$SB/rules-inactive.json" inactive; mk_rules "$SB/rules-pending.json" pending; mk_rules "$SB/rules-firing.json" firing
  mk_rules "$SB/rules-absent.json" inactive 600 ok other.group
  printf 'inactive pending firing firing inactive' > "$SB/sc-rules-seq"
}
sb_reset() { sb_setup "$SB"; rm -rf "${TMP}/gst"; mkdir -p "${TMP}/gst"; }
step_run() { # FUNC ... one step function, in a subshell, against the stub; the exit status is the function's
  (
    export SB PATH="${BIN}:${PATH}"
    STATE="${TMP}/gst"; KUBE_CONTEXT=stub-ctx; HERE="${HERE}/paths"; BUDGET=1000; T0=$(date +%s)
    # shellcheck source=/dev/null
    . "${HERE}/../lib/assert.sh"
    ASSERT_REPORT=""
    _emit() { :; }
    # shellcheck source=/dev/null
    . "$FNS"
    sleep() { :; }
    "$1"
  ) >/dev/null 2>&1
}
rows_n() { grep -c . "${TMP}/gst/verdicts.tsv" 2>/dev/null || echo 0; }
red_rows() { awk -F'\t' '$3 != $4 {printf "%s%s", sep, NR; sep=" "} END{print ""}' "${TMP}/gst/verdicts.tsv" 2>/dev/null; }
red_text() { awk -F'\t' '$3 != $4 {printf "[%s => %s] ", $2, $4}' "${TMP}/gst/verdicts.tsv" 2>/dev/null | cut -c1-300; }
row_actual() { awk -F'\t' -v pat="$1" 'index($2, pat) {print $4; exit}' "${TMP}/gst/verdicts.tsv"; }
calls_have() { grep -q -- "$1" "$SB/calls.log" 2>/dev/null; }
no_planted() { [ ! -s "${TMP}/gst/planted.list" ]; }
no_markers() { ! compgen -G "$SB/m-*" >/dev/null; }
left_markers() { local f; for f in "$SB"/m-*; do [ -e "$f" ] && printf '%s ' "${f##*/}"; done; return 0; }

# every kubectl call in every scenario below is checked for its context at the end of this layer
CTXLOG="${TMP}/all-calls.log"; : > "$CTXLOG"
keep_calls() { cat "$SB/calls.log" >> "$CTXLOG" 2>/dev/null; }

# ---- S01: the quota
sb_reset; step_run step_quota; rc=$?
if [ "$rc" = 0 ] && [ "$(rows_n)" = 9 ] && [ -z "$(red_rows)" ]; then ok "quota: the refusal scenario records nine rows, all green"
else bad "quota: the green scenario" "rc=${rc}, rows=$(rows_n), red=[$(red_text)]"; fi
if grep -q 'kind: ResourceQuota' "$SB/applied-${QNS}.yaml" && grep -q "namespace: ${QNS}" "$SB/applied-${QNS}.yaml" && grep -q "${KEY}: \"0\"" "$SB/applied-${QNS}.yaml"; then
  ok "quota: the planted object is a ResourceQuota that allows no ${KEY} in the identity namespace"
else bad "quota: the planted object" "$(cat "$SB/applied-${QNS}.yaml" 2>/dev/null)"; fi
if grep -q -- "-n ${QNS} create job --from=cronjob/tockmox-authentik-db-drill ${QJOB}" "$SB/calls.log"; then ok "quota: the drill Job is made from the drill CronJob, in the identity namespace, under a name of its own"
else bad "quota: the drill Job" "$(grep create "$SB/calls.log")"; fi
if [ "$(awk '/get resourcequota /{q=NR} /create job/{j=NR} END{print (q>0 && j>q)}' "$SB/calls.log")" = 1 ]; then ok "quota: the Job is not started until the quota has been read as counted"
else bad "quota: order" "$(grep -nE 'resourcequota|create job' "$SB/calls.log")"; fi
if calls_have "delete job ${QJOB}" && calls_have "delete resourcequota ${QUOTA}" && no_markers && no_planted; then ok "quota: both faults are deleted, read back, and struck off the planted list"
else bad "quota: the revert" "markers: $(left_markers); planted: $(cat "${TMP}/gst/planted.list" 2>/dev/null)"; fi
if [ -n "$(row_actual "revert: the planted ResourceQuota")" ] && [ "$(row_actual "revert: the planted ResourceQuota")" = absent ] && [ "$(row_actual "revert: the planted drill Job")" = absent ]; then ok "quota: the revert rows exist and read absent"
else bad "quota: the revert rows" "$(cat "${TMP}/gst/verdicts.tsv" | tail -2)"; fi
keep_calls

# the log of a drill that PASSED despite the quota is red where it should be
sb_reset; mk_qlog "$SB/log-${QNS}.txt" "cluster.postgresql.cnpg.io/x created" "in_recovery=f public_tables=106" PASS PASS; step_run step_quota
r="$(red_rows)"
if [ "$r" = "6 7 8" ] || [ "$r" = "5 6 7" ]; then ok "quota: a drill that passed under the quota turns the no-PASS, refusal and FAIL-object rows red"
else bad "quota: a passing drill" "red=[$r] $(red_text)"; fi
keep_calls
sb_reset; mk_job "$SB/job-${QNS}.json" complete; step_run step_quota
if [[ " $(red_rows) " == *" 3 "* ]]; then ok "quota: a Job that reaches Complete turns the Job row red"; else bad "quota: Complete" "red=[$(red_rows)]"; fi
keep_calls
sb_reset; printf 'tockmox-authentik-db-drillcheck' > "$SB/sc-clusters-${QNS}"; step_run step_quota
if [[ " $(red_rows) " == *" 4 "* ]]; then ok "quota: a recovery cluster that exists turns the 'never created' row red"; else bad "quota: cluster created" "red=[$(red_rows)]"; fi
keep_calls

# the middle of the step fails; the faults are still reverted, and the reverts are read back
revert_ok() { # LABEL ... after a failed middle: the Job and quota delete calls were made, both markers are gone, the revert rows read absent
  if calls_have "delete job ${QJOB}" && calls_have "delete resourcequota ${QUOTA}" && no_markers && no_planted \
     && [ "$(row_actual "revert: the planted ResourceQuota")" = absent ] && [ "$(row_actual "revert: the planted drill Job")" = absent ]; then ok "$1"
  else bad "$1" "calls: $(grep delete "$SB/calls.log" | tr '\n' ';'); markers: $(left_markers); rows: $(tail -2 "${TMP}/gst/verdicts.tsv" | cut -f2,4 | tr '\n' ';')"; fi
}
sb_reset; echo 1 > "$SB/sc-create-fail"; step_run step_quota
revert_ok "quota: the Job cannot be created, and the quota is still deleted and read back as gone"
[ -n "$(red_rows)" ] && ok "quota: ... and the failed Job creation is red, not silent" || bad "quota: create failed but nothing is red" ""
keep_calls
sb_reset; echo 1 > "$SB/sc-job-garbage"; echo 1 > "$SB/sc-logs-fail"; step_run step_quota
revert_ok "quota: the Job cannot be read and has no log, and both faults are still reverted"
[ -n "$(red_rows)" ] && ok "quota: ... and the unreadable Job and missing log are red" || bad "quota: unreadable but nothing red" ""
keep_calls
sb_reset; echo 1 > "$SB/sc-plant-fail"; step_run step_quota
revert_ok "quota: the planting itself fails, and the revert still runs and reads back absent"
if ! calls_have "create job"; then ok "quota: ... and the drill Job is not started when the quota was not planted"; else bad "quota: Job started without a quota" "$(grep 'create job' "$SB/calls.log")"; fi
keep_calls
sb_reset; printf 'none' > "$SB/sc-quota-status"; step_run step_quota
revert_ok "quota: the quota is never counted, and the revert still runs"
if ! calls_have "create job" && [[ " $(red_rows) " == *" 2 "* ]]; then ok "quota: ... the drill Job is NOT started (a drill under an unenforced quota would be a real restore), and the 'counting' row is red"
else bad "quota: uncounted quota" "calls: $(grep 'create job' "$SB/calls.log"); red=[$(red_rows)]"; fi
keep_calls
sb_reset; printf 'tockmox-litellm-db-drill' > "$SB/sc-cronjobs"; step_run step_quota
if ! calls_have "apply -f" && ! calls_have "create job" && [ "$(red_rows)" = 1 ] && no_planted; then ok "quota: no drill CronJob turns the first row red and plants nothing"
else bad "quota: no CronJob" "red=[$(red_rows)] calls: $(tr '\n' ';' < "$SB/calls.log")"; fi
keep_calls
# the revert is itself asserted
sb_reset; echo 1 > "$SB/sc-delete-stuck"; step_run step_quota
if [ "$(row_actual "revert: the planted ResourceQuota")" = present ] && [ "$(row_actual "revert: the planted drill Job")" = present ] \
   && grep -q "quota ${IDENTITY_NS:-tockmox-authentik} ${QUOTA}" "${TMP}/gst/planted.list" 2>/dev/null; then
  ok "quota: a delete that does not take turns both revert rows red, and the objects stay on the list the trap deletes from"
else bad "quota: stuck delete" "$(tail -2 "${TMP}/gst/verdicts.tsv" | cut -f2,4); planted: $(cat "${TMP}/gst/planted.list" 2>/dev/null)"; fi
# ... and the trap's own revert (revert_all) takes them out once the delete works
rm -f "$SB/sc-delete-stuck"
( export SB PATH="${BIN}:${PATH}"; STATE="${TMP}/gst"; KUBE_CONTEXT=stub-ctx; . "$FNS"; revert_all ) >/dev/null 2>&1
if no_markers && no_planted; then ok "quota: revert_all (the trap's) deletes what the list still holds and empties the list"; else bad "quota: revert_all" "$(left_markers)"; fi
keep_calls
# a step run again after a half-finished try writes each row once
sb_reset; step_run step_quota; step_run step_quota
[ "$(rows_n)" = 9 ] && ok "quota: a second try writes each row once, not twice" || bad "quota: a second try" "rows=$(rows_n)"
keep_calls

# ---- S02: the register
sb_reset; step_run step_register; rc=$?
if [ "$rc" = 0 ] && [ "$(rows_n)" = 11 ] && [ -z "$(red_rows)" ]; then ok "register: the fault scenario records eleven rows, all green (rule loaded, inactive, then firing, then inactive again)"
else bad "register: the green scenario" "rc=${rc}, rows=$(rows_n), red=[$(red_text)]"; fi
if python3 - "$SB/created-${RNS}.json" "$FB" "$RJOB" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
env = {e["name"]: e for e in d["spec"]["template"]["spec"]["containers"][0]["env"]}
assert d["metadata"]["name"] == sys.argv[3] and env["REG_BUCKET"]["value"] == sys.argv[2] and env["REG_ENDPOINT"]["value"] == "http://garage:3900"
PY
then ok "register: the Job created is the CronJob's template with REG_BUCKET changed to a bucket that does not exist, and nothing else"
else bad "register: the created Job" "$(cat "$SB/created-${RNS}.json" 2>/dev/null | cut -c1-200)"; fi
if [ "$(grep -c -- '--raw' "$SB/calls.log")" = 5 ] && grep -q -- "get --raw /api/v1/namespaces/tockmox-monitoring/services/prometheus-operated:9090/proxy/api/v1/rules?type=alert" "$SB/calls.log"; then
  ok "register: Prometheus is read through the API server's service proxy, five times (before, two polls to firing, two polls to clear)"
else bad "register: the Prometheus reads" "$(grep -c -- '--raw' "$SB/calls.log") reads: $(grep -- '--raw' "$SB/calls.log" | head -1)"; fi
if [ "$(grep -c 'waited .*s (limit' "${TMP}/gst/notes.txt")" -ge 3 ]; then ok "register: every wait is recorded with how long it took and its limit"
else bad "register: the wait notes" "$(cat "${TMP}/gst/notes.txt")"; fi
keep_calls

rev_ok() { # LABEL ... the planted Job's delete call was made, it reads absent, nothing is left planted
  if calls_have "delete job ${RJOB}" && no_markers && no_planted && [ "$(row_actual "revert: the planted drill Job")" = absent ]; then ok "$1"
  else bad "$1" "calls: $(grep delete "$SB/calls.log" | tr '\n' ';'); markers: $(left_markers); rows: $(tail -3 "${TMP}/gst/verdicts.tsv" | cut -f2,4 | tr '\n' ';')"; fi
}
# the alert never fires
sb_reset; printf 'inactive' > "$SB/sc-rules-seq"; TOCKMOX_P13_ALERT_WAIT=0 step_run step_register
r="$(red_text)"
if [[ "$r" == *"is firing in Prometheus"*"inactive after"* ]] && [ "$(red_rows | wc -w)" = 1 ]; then ok "register: an alert that stays inactive turns exactly the firing row red, naming the state and the wait"
else bad "register: alert never fires" "$r"; fi
rev_ok "register: ... and the Job is still deleted and read back as gone"
keep_calls
# the alert fires but never clears
sb_reset; printf 'inactive firing' > "$SB/sc-rules-seq"; TOCKMOX_P13_CLEAR_WAIT=0 step_run step_register
if [ "$(red_rows | wc -w)" = 1 ] && [[ "$(red_text)" == *"reads inactive again"*"firing after"* ]]; then ok "register: an alert that does not clear after the revert turns the clearing row red"
else bad "register: alert never clears" "$(red_text)"; fi
keep_calls
# TOCKMOX_P13_ALERT=0: no Prometheus read at all
sb_reset; (
  export SB PATH="${BIN}:${PATH}" TOCKMOX_P13_ALERT=0
  STATE="${TMP}/gst"; KUBE_CONTEXT=stub-ctx; HERE="${HERE}/paths"; BUDGET=1000; T0=$(date +%s)
  # shellcheck source=/dev/null
  . "${HERE}/../lib/assert.sh"; ASSERT_REPORT=""; _emit() { :; }
  . "$FNS"; sleep() { :; }; step_register
) >/dev/null 2>&1
if ! calls_have "--raw" && [ "$(rows_n)" = 7 ] && [ -z "$(red_rows)" ]; then ok "register: with TOCKMOX_P13_ALERT=0 Prometheus is not read, the other seven rows are green"
else bad "register: alert off" "raw reads=$(grep -c -- '--raw' "$SB/calls.log"), rows=$(rows_n), red=[$(red_text)]"; fi
keep_calls
# the rule is not loaded: no wait, red row, fault still reverted
sb_reset; printf 'absent' > "$SB/sc-rules-seq"; step_run step_register
if [ "$(grep -c -- '--raw' "$SB/calls.log")" = 1 ] && [[ "$(red_text)" == *"rule not loaded"* ]]; then ok "register: a rule that is not loaded in Prometheus is one red row and no 17 minute wait"
else bad "register: rule not loaded" "reads=$(grep -c -- '--raw' "$SB/calls.log") red=$(red_text)"; fi
rev_ok "register: ... and the Job is still reverted"
keep_calls
# Prometheus cannot be read
sb_reset; echo 1 > "$SB/sc-raw-fail"; step_run step_register
if [[ "$(red_text)" == *"unreadable"* ]] && [ "$(grep -c -- '--raw' "$SB/calls.log")" = 1 ]; then ok "register: Prometheus unreadable is a red row, read once, not waited on"
else bad "register: Prometheus unreadable" "reads=$(grep -c -- '--raw' "$SB/calls.log") red=$(red_text)"; fi
rev_ok "register: ... and the Job is still reverted"
keep_calls
# the template cannot be built
sb_reset; mk_template "$SB/template.json" valuefrom; step_run step_register
if ! calls_have "create -f" && [[ "$(red_text)" == *"cannot build"* ]]; then ok "register: a template without a plain REG_BUCKET is 'cannot build': nothing is created, one red row says so"
else bad "register: template" "$(red_text) $(grep 'create' "$SB/calls.log")"; fi
rev_ok "register: ... and the revert still reads the Job as absent"
keep_calls
# the create is refused
sb_reset; echo 1 > "$SB/sc-create-fail"; step_run step_register
[[ "$(red_text)" == *"create refused"* ]] && ok "register: a refused create is a red row that carries the refusal" || bad "register: create refused" "$(red_text)"
rev_ok "register: ... and the revert runs"
keep_calls
# the Job never ends
sb_reset; mk_job "$SB/job-${RNS}.json" running; step_run step_register
[[ "$(red_text)" == *"still running"* ]] && ok "register: a Job that does not end inside its wait turns the Job row red" || bad "register: Job running" "$(red_text)"
rev_ok "register: ... and it is deleted anyway"
keep_calls
# the restore itself failed, so the planted fault is not the only failure
sb_reset; mk_rlog "$SB/log-${RNS}.txt" "$RWRITE" FAIL FAIL; step_run step_register
[[ "$(red_text)" == *"restore's own verdict was FAIL"* ]] && ok "register: a restore that failed on its own turns the unrecorded row red" || bad "register: restore failed" "$(red_text)"
keep_calls
# the drill's recovery cluster is left behind
sb_reset; printf 'tockmox-litellm-db-drillcheck' > "$SB/sc-clusters-${RNS}"; step_run step_register
[[ "$(row_actual "revert: the drill's recovery cluster")" = present ]] && ok "register: a recovery cluster left behind turns its row red, and is deleted" || bad "register: leftover cluster" "$(tail -3 "${TMP}/gst/verdicts.tsv" | cut -f2,4)"
calls_have "delete cluster.postgresql.cnpg.io tockmox-litellm-db-drillcheck" && ok "register: ... the delete of the leftover cluster was issued" || bad "register: leftover cluster delete" "$(grep delete "$SB/calls.log")"
keep_calls
# the revert does not take
sb_reset; echo 1 > "$SB/sc-delete-stuck"; step_run step_register
if [ "$(row_actual "revert: the planted drill Job")" = present ] && grep -q "job ${RNS} ${RJOB}" "${TMP}/gst/planted.list"; then ok "register: a delete that does not take turns the revert row red and leaves the Job on the trap's list"
else bad "register: stuck delete" "$(tail -3 "${TMP}/gst/verdicts.tsv" | cut -f2,4)"; fi
keep_calls

# every call in every scenario named its cluster
if [ -s "$CTXLOG" ] && ! grep -v -- '--context=stub-ctx' "$CTXLOG" >/dev/null; then ok "every kubectl call in every scenario names its cluster ($(grep -c . "$CTXLOG") calls)"
else bad "every kubectl call names its cluster" "$(grep -v -- '--context=stub-ctx' "$CTXLOG" | head -3)"; fi

# ------------------------------------------------------------------ 3. the path as a script, and mutated copies
# Each probe runs the path as a script in a sandbox of its own (a stub scenario, a P09 state directory, a receipt
# directory), so they run side by side. A probe returns 0 when the file under test behaves as a correct P13 does.
GT="${TMP}/gate"; mkdir -p "$GT/tree/paths" "$GT/bin"
ln -s "${HERE}/lib" "$GT/tree/lib"
sandbox() { # prints a fresh sandbox directory holding the green scenario and a complete P09 state
  local d; d="$(mktemp -d "${TMP}/sbx.XXXXXX")"
  sb_setup "$d/sb"; mkdir -p "$d/p09"; : > "$d/p09/p09-passed"; printf '1762800000' > "$d/p09/root-applied-at"
  printf '%s' "$d"
}
# run_p13 FILE SANDBOX [VAR=VALUE ...] ... the path as run.sh runs it, against the stub; prints "rc|receipt"
run_p13() {
  local f="$1" d="$2"; shift 2
  env SB="$d/sb" PATH="${BIN}:${PATH}" OUTCOME_RECEIPT_DIR="$d/r" TOCKMOX_PATH_NAME=P13-planted-faults KUBE_CONTEXT=stub-ctx \
      TOCKMOX_P09_STATE="$d/p09" "$@" bash "$f" > "$d/out" 2>&1
  local rc=$?
  printf '%s|%s' "$rc" "$(cut -d' ' -f1 "$d/r/P13-planted-faults" 2>/dev/null)"
}
not_pass() { [ "$(printf '%s' "$1" | cut -d'|' -f2)" != PASS ] && [ "${1%%|*}" != 0 ]; }
sbx_markers() { compgen -G "$1/sb/m-*" >/dev/null; }
probe_green() { # green end to end: PASS, nothing left planted, every revert row present, every call names its cluster
  local d r; d="$(sandbox)"; r="$(run_p13 "$1" "$d")"
  [ "${r%%|*}" = 0 ] && [ "$(printf '%s' "$r" | cut -d'|' -f2)" = PASS ] || return 1
  [ -z "$(cat "$d/p09/p13/planted.list" 2>/dev/null)" ] || return 1
  ! sbx_markers "$d" || return 1
  [ "$(grep -c 'revert: ' "$d/p09/p13/verdicts.tsv")" -ge 5 ] || return 1
  ! grep -v -- '--context=stub-ctx' "$d/sb/calls.log" >/dev/null
}
probe_stuck() { # a revert that does not take must not end PASS
  local d; d="$(sandbox)"; echo 1 > "$d/sb/sc-delete-stuck"; not_pass "$(run_p13 "$1" "$d")"
}
probe_trap() { # killed in the middle of a wait: whatever was planted is deleted
  local d pid i; d="$(sandbox)"; echo 1 > "$d/sb/sc-block-get-job"
  env SB="$d/sb" PATH="${BIN}:${PATH}" OUTCOME_RECEIPT_DIR="$d/r" TOCKMOX_PATH_NAME=P13-planted-faults KUBE_CONTEXT=stub-ctx \
      TOCKMOX_P09_STATE="$d/p09" bash "$1" > "$d/out" 2>&1 &
  pid=$!
  for i in $(seq 1 100); do [ -e "$d/sb/blocked" ] && break; sleep 0.1; done
  [ -e "$d/sb/blocked" ] || { kill -KILL "$pid" 2>/dev/null; return 1; }
  kill -TERM "$pid" 2>/dev/null
  : > "$d/sb/release"
  wait "$pid" 2>/dev/null
  ! sbx_markers "$d" && grep -q "delete job ${QJOB}" "$d/sb/calls.log" && grep -q "delete resourcequota ${QUOTA}" "$d/sb/calls.log"
}
probe_uncounted() { # a quota the controller never counted must not be followed by a drill Job
  local d r; d="$(sandbox)"; printf 'none' > "$d/sb/sc-quota-status"; r="$(run_p13 "$1" "$d")"
  ! grep -q "create job --from=cronjob/tockmox-authentik-db-drill" "$d/sb/calls.log" && not_pass "$r"
}
probe_nofire() { # an alert that never fires must not end PASS
  local d; d="$(sandbox)"; printf 'inactive' > "$d/sb/sc-rules-seq"; not_pass "$(run_p13 "$1" "$d" TOCKMOX_P13_ALERT_WAIT=0)"
}
probe_passed() { # a PASS row under the quota (everything else as it should be) must not end PASS
  local d; d="$(sandbox)"
  echo "register: 2026-11-10T21:04:05Z PASS in_recovery=f public_tables=106 backup=${ID}" >> "$d/sb/log-${QNS}.txt"
  not_pass "$(run_p13 "$1" "$d")"
}
probe_unrecorded() { # a restore that itself failed (everything else as it should be) must not end PASS
  local d; d="$(sandbox)"; mk_rlog "$d/sb/log-${RNS}.txt" "$RWRITE" FAIL FAIL; not_pass "$(run_p13 "$1" "$d")"
}
mkm() { mut "$P13" "$GT/tree/paths/$1" "$2" "$3"; }
# the work list: KIND|LABEL|FILE|PROBE, run eight at a time, reported in order
WORK="${TMP}/work"; : > "$WORK"
for pr in green stuck trap uncounted nofire passed unrecorded; do
  printf 'real|%s|%s|%s\n' "P13 as a script, probe '${pr}': behaves as a correct path does" "$P13" "$pr" >> "$WORK"
done
addm() { printf 'mut|%s|%s|%s\n' "mutation: ${1}" "$GT/tree/paths/$2" "$3" >> "$WORK"; }
# 1 and 2. the explicit revert step deleted
mkm m-norevert-q.sh '  revert_object "$s" job "$ns" "$Q_JOB" "the planted drill Job"
  revert_object "$s" quota "$ns" "$QUOTA_NAME" "the planted ResourceQuota"
' ''
addm "the quota step's revert deleted (the trap still deletes, but no row says the fault is gone)" m-norevert-q.sh green
mkm m-norevert-r.sh '  revert_object "$s" job "$ns" "$R_JOB" "the planted drill Job"
' ''
addm "the register step's revert deleted" m-norevert-r.sh green
# 3. no trap
mkm m-notrap.sh 'trap revert_all EXIT
trap '"'"'revert_all; exit 143'"'"' TERM' ':
:'
addm "the EXIT and TERM traps deleted" m-notrap.sh trap
# 4. the read-back cannot go red
mkm m-gonegreen.sh 'record "$s" "revert: ${desc} ${name} is gone from ${ns}" "absent" "$v"' 'record "$s" "revert: ${desc} ${name} is gone from ${ns}" "absent" "absent"'
addm "the read-back that cannot go red (the row compares absent with absent)" m-gonegreen.sh stuck
# 5. the planted list never written
mkm m-nolist.sh 'planted_add() { printf '"'"'%s %s %s\n'"'"' "$1" "$2" "$3" >> "${STATE}/planted.list"; }' 'planted_add() { :; }'
addm "the planted list never written (the trap has nothing to delete)" m-nolist.sh trap
# 6. the context dropped from a delete
mkm m-noctx.sh '    job) kubectl --context="$KUBE_CONTEXT" -n "$2" delete job' '    job) kubectl -n "$2" delete job'
addm "the context dropped from the Job delete" m-noctx.sh green
# 7. the quota wait skipped: the Job is started whatever the quota reads
mkm m-noqwait.sh '    [ "$v" = enforced ] || ok=0' '    :'
addm "the 'quota is counted' gate removed" m-noqwait.sh uncounted
# 8. the alert row that cannot go red
mkm m-alertgreen.sh 'record "$s" "${ALERT} is firing in Prometheus within its for: plus the evaluation interval and a margin" "firing" "$v"' 'record "$s" "${ALERT} is firing in Prometheus within its for: plus the evaluation interval and a margin" "firing" "firing"'
addm "the alert row that cannot go red" m-alertgreen.sh nofire
# 9. the no-PASS verdict replaced by a constant (quota step)
mkm m-nopass.sh '"no PASS recorded" "$(recovery_verdict drill-no-pass --allow-row no < "${STATE}/${s}.log" | head -1)"' '"no PASS recorded" "no PASS recorded"'
addm "the quota step's no-PASS verdict replaced by a constant" m-nopass.sh passed
# 10. the unrecorded verdict replaced by a constant (register step)
mkm m-unrec.sh '"restore PASS, register write refused, nothing recorded" "$(recovery_verdict drill-unrecorded --db "$AI_DB" --bucket "$FAULT_BUCKET" < "${STATE}/${s}.log" | head -1)"' '"restore PASS, register write refused, nothing recorded" "restore PASS, register write refused, nothing recorded"'
addm "the register step's unrecorded verdict replaced by a constant" m-unrec.sh unrecorded
RES="${TMP}/res"; mkdir -p "$RES"
n=0
while IFS='|' read -r kind label file pr; do
  n=$((n+1))
  ( if "probe_${pr}" "$file"; then echo ok > "$RES/$n"; else echo no > "$RES/$n"; fi ) >/dev/null 2>&1 &
  [ $((n % 8)) -eq 0 ] && wait
done < "$WORK"
wait
n=0
while IFS='|' read -r kind label file pr; do
  n=$((n+1)); r="$(cat "$RES/$n" 2>/dev/null)"
  if [ "$kind" = real ]; then
    [ "$r" = ok ] && ok "$label" || bad "$label" "the real path failed the '${pr}' probe"
  else
    # a mutated copy must FAIL the probe aimed at it: the probe passing would mean the guard was never tested
    [ "$r" = no ] && ok "${label} is caught by the '${pr}' probe" || bad "$label" "the probe '${pr}' still passed on the mutated copy, so the guard is not tested"
  fi
done < "$WORK"

# ------------------------------------------------------------------ 4. the path's own gate, as a script
cat > "$GT/bin/kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "$GT/kcalls"
exit 1
STUB
chmod +x "$GT/bin/kubectl"
run_gate() { # FILE STATE-DIR [VAR=VALUE ...] ... prints "rc|receipt|kubectl calls". The budget is 0 so a copy that does NOT stop at its gate yields at once.
  local f="$1" sd="$2"; shift 2
  rm -rf "$GT/r" "$GT/kcalls"
  env PATH="$GT/bin:$PATH" OUTCOME_RECEIPT_DIR="$GT/r" TOCKMOX_PATH_NAME=P13-planted-faults \
      KUBE_CONTEXT=stub-ctx TOCKMOX_P13_BUDGET=0 ${sd:+TOCKMOX_P09_STATE="$sd"} "$@" \
      bash "$f" > "$GT/out" 2>&1
  local rc=$?
  printf '%s|%s|%s' "$rc" "$(cut -d' ' -f1 "$GT/r/P13-planted-faults" 2>/dev/null)" "$(grep -c . "$GT/kcalls" 2>/dev/null || echo 0)"
}
gate_cases() { # FILE LABEL-PREFIX WANT(blocked|not)
  local f="$1" pre="$2" want="$3" sd="$GT/p09"
  rm -rf "$sd"
  check() { # LABEL STATE-DIR
    local lab="$1" r; shift
    r="$(run_gate "$f" "$@")"
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
gate_cases "$P13" "gate: " blocked
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"; printf '1762800000' > "$GT/p09/root-applied-at"
r="$(run_gate "$P13" "$GT/p09")"
[ "${r%%|*}" = 75 ] && ok "gate: a state with P09's PASS marker and an install time is not blocked (it starts the steps; exit 75 on the zero budget, before anything is planted)" || bad "gate: a complete state is not blocked" "got [${r}]; $(tail -3 "$GT/out" | tr '\n' ';' | cut -c1-200)"
if [ "$(printf '%s' "$r" | cut -d'|' -f3)" = 0 ]; then ok "gate: ... and the yield made no cluster call, so nothing was planted"; else bad "gate: yield calls" "$r"; fi
mkp() { mut "$P13" "$GT/tree/paths/$1" "$2" "$3"; }
only_case() { # FILE LABEL STATE-DIR
  local f="$1" lab="$2" r; shift 2
  r="$(run_gate "$f" "$@")"
  [ "$r" != "0|BLOCKED|0" ] && ok "gate mutation: ${lab} is caught (the copy was not BLOCKED: ${r})" || bad "gate mutation: ${lab}" "the mutated copy still declared BLOCKED"
}
mkp g-default0.sh '|| true)"' '|| echo 0)"'
mut "$GT/tree/paths/g-default0.sh" "$GT/tree/paths/g-default0.sh" 'install_time_ok "$ROOT_APPLIED" || blocked' ': || blocked'
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"
only_case "$GT/tree/paths/g-default0.sh" "defaulting the install time to 0 with no root-applied-at" "$GT/p09"
mkp g-nomarker.sh '[ -f "${P09_STATE}/p09-passed" ] || blocked' ': || blocked'
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; printf '1762800000' > "$GT/p09/root-applied-at"
only_case "$GT/tree/paths/g-nomarker.sh" "dropping the check that P09 ended PASS" "$GT/p09"
mkp g-nocheck.sh 'install_time_ok "$ROOT_APPLIED" || blocked' ': || blocked'
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"; printf '0' > "$GT/p09/root-applied-at"
only_case "$GT/tree/paths/g-nocheck.sh" "dropping the check that the install time is a positive number" "$GT/p09"
mkp g-defstate.sh 'P09_STATE="${TOCKMOX_P09_STATE:-}"' "P09_STATE=\"\${TOCKMOX_P09_STATE:-$GT/p09}\""
rm -rf "$GT/p09"; mkdir -p "$GT/p09"; : > "$GT/p09/p09-passed"; printf '1762800000' > "$GT/p09/root-applied-at"
only_case "$GT/tree/paths/g-defstate.sh" "a default P09 state directory (a stale one would be read as an install)" ""
# the trap is armed after the gate, so a blocked path has no trap that could call the cluster
if ! grep -B1000 -n '^trap revert_all EXIT' "$P13" | grep 'blocked "root-applied-at' >/dev/null; then bad "the traps are set after the gates" "order"; else ok "the traps are set after the gates, so a BLOCKED path has nothing to revert and makes no call"; fi

# ----------------------------------------------------- run.sh: the full run cannot reach it without an install
DRY="$(env TOCKMOX_DRY_RUN=1 TOCKMOX_DOCS_REF=HEAD TOCKMOX_WORKDIR="$GT/w0" bash "${HERE}/run.sh" 2>&1)"
if printf '%s\n' "$DRY" | grep -E "group 'argocd-helm': .*P09-install-md-end-to-end.* P13-planted-faults" >/dev/null \
   && ! printf '%s\n' "$DRY" | grep -E "group 'argocd-helm': .*P13-planted-faults .*P1[0-2]" >/dev/null; then
  ok "run.sh: a run with no arguments discovers P13, in P09's route group, after P09 and P11 (no extra cluster)"
else bad "run.sh: discovery" "$(printf '%s' "$DRY" | grep group | tr '\n' ';' | cut -c1-300)"; fi
cat > "$GT/bin/kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "$GT/kcalls"
case "\$*" in *get-contexts*) echo stub-ctx ;; *"get nodes"*) printf True ;; *"version -o json"*) echo '{"serverVersion":{"gitVersion":"v1.33.0"}}' ;; esac
exit 0
STUB
echo "apiVersion: v1" > "$GT/kc"
rm -f "$GT/kcalls"
RUNOUT="$(env PATH="$GT/bin:$PATH" TOCKMOX_EXISTING_KUBECONFIG="$GT/kc" KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD \
          TOCKMOX_WORKDIR="$GT/w1" TOCKMOX_P09_STATE= bash "${HERE}/run.sh" P13 2>&1)"; RUNRC=$?
if [ "$RUNRC" = 4 ] && printf '%s\n' "$RUNOUT" | grep -F 'OUTCOME:  BLOCKED' >/dev/null \
   && printf '%s\n' "$RUNOUT" | grep -F 'UNCONVERTED    : 0' >/dev/null \
   && printf '%s\n' "$RUNOUT" | grep -F 'paths blocked, NOT declared: 1' >/dev/null; then
  ok "run.sh: P13 named with no install declares BLOCKED; the run exits 4 (expected-outcomes.txt is read only in a run with no arguments), nothing UNCONVERTED"
else bad "run.sh: P13 with no install" "rc=${RUNRC}; $(printf '%s' "$RUNOUT" | tail -12 | tr '\n' ';' | cut -c1-400)"; fi
if ! grep -E 'quota|jobs|create|delete|--raw|logs|apply' "$GT/kcalls" >/dev/null 2>&1; then ok "run.sh: P13 made no cluster read or write of its own"
else bad "run.sh: P13 made a cluster call" "$(grep -E 'quota|jobs|create|delete|--raw|logs|apply' "$GT/kcalls" | head -3)"; fi
# the three together, as a full run reaches them with no P09 state: P09 and P11 and P13 each declare BLOCKED
rm -f "$GT/kcalls"
RUNOUT3="$(env PATH="$GT/bin:$PATH" TOCKMOX_EXISTING_KUBECONFIG="$GT/kc" KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD \
          TOCKMOX_WORKDIR="$GT/w2" TOCKMOX_P09_STATE= bash "${HERE}/run.sh" P09 P11 P13 2>&1)"; RUNRC3=$?
if [ "$RUNRC3" = 4 ] && [ "$(printf '%s\n' "$RUNOUT3" | grep -c 'OUTCOME:  BLOCKED')" -ge 3 ] && printf '%s\n' "$RUNOUT3" | grep -F 'UNCONVERTED    : 0' >/dev/null \
   && printf '%s\n' "$RUNOUT3" | grep -F 'paths blocked, NOT declared: 3' >/dev/null; then
  ok "run.sh: P09, P11 and P13 named together with no P09 state: all three BLOCKED, exit 4 (named, so not declared), nothing UNCONVERTED"
else bad "run.sh: P09 P11 P13 with no install" "rc=${RUNRC3}; blocked=$(printf '%s\n' "$RUNOUT3" | grep -c 'OUTCOME:  BLOCKED'); $(printf '%s' "$RUNOUT3" | tail -8 | tr '\n' ';' | cut -c1-300)"; fi
if ! grep -E 'quota|jobs|create|delete|--raw|logs|apply' "$GT/kcalls" >/dev/null 2>&1; then ok "run.sh: ... and none of the three made a cluster read or write of its own"
else bad "run.sh: a path made a cluster call" "$(grep -E 'quota|jobs|create|delete|--raw|logs|apply' "$GT/kcalls" | head -3)"; fi

# ----------------------------------------------------- the lane's P13 block
LANE="${HERE}/p09-lane.sh"
BLK="${TMP}/p13-block.sh"
awk '/^# --- P13 block begin/{on=1} on{print} /^# --- P13 block end/{on=0}' "$LANE" > "$BLK"
if [ "$(grep -c . "$BLK")" -gt 5 ] && head -1 "$BLK" | grep 'P13 block begin' >/dev/null && tail -1 "$BLK" | grep 'P13 block end' >/dev/null; then ok "lane: the P13 block is a self-contained region between its two markers"
else bad "lane: the P13 block" "found $(grep -c . "$BLK") lines"; fi
l11="$(grep -n 'run.sh" P11' "$LANE" | head -1 | cut -d: -f1)"; l13="$(grep -n 'run.sh" P13' "$LANE" | head -1 | cut -d: -f1)"; lex="$(grep -n '^exit "\$rc"' "$LANE" | tail -1 | cut -d: -f1)"
if [ -n "$l11" ] && [ -n "$l13" ] && [ -n "$lex" ] && [ "$l11" -lt "$l13" ] && [ "$l13" -lt "$lex" ]; then ok "lane: P13 runs after P11 and before the lane's exit"
else bad "lane: order" "P11 at ${l11:-none}, P13 at ${l13:-none}, exit at ${lex:-none}"; fi
# the exit rule and the receipt check (4 BLOCKED, 5 INFRA_ERROR, 1 otherwise, an earlier failure kept, no run after a P09 that
# did not declare PASS) are run against the real lane in lane-outcome-test.sh, with stub receipts that include P13's.
printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

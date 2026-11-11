#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verdicts for P09's recovery rows: what a fresh install can come back from.

P09 reads objects off the cluster it just installed (Backups, ScheduledBackups,
Jobs, a drill Job's log) into files, and asks this module one question per row.
Each subcommand reads ONE artefact on stdin and prints ONE verdict line. The
row's expected value is a fixed phrase in P09; a verdict that is anything else
is the reason the row is red.

  p09-recovery.py backup           --cluster NAME --after EPOCH   < Backup list (JSON)
  p09-recovery.py scheduled        --cluster NAME                 < one ScheduledBackup (JSON)
  p09-recovery.py job                                             < one Job (JSON)
  p09-recovery.py drill-recorded   --db NAME --bucket NAME        < a drill Job's log
  p09-recovery.py drill-pinned     --backup-id ID                 < a drill Job's log
  p09-recovery.py migrations-hook  --job NAME                     < Job list (JSON)
  p09-recovery.py migrations-complete --job NAME                  < Job list (JSON)
  p09-recovery.py migrations-owner --job NAME                     < Job list (JSON)

Why a module and not shell: the same predicates run in recovery-rows-test.sh
against green and red fixtures, so each row is shown able to go red without a
cluster. Input that cannot be read is a verdict beginning "unreadable", never a
traceback and never a pass: an empty read must not look like a healthy one.

The strings this module matches are quoted from the charts, not recalled:
  - the register line   charts/tockmox-common/templates/_drill-register.tpl
                        ("register: recorded s3://BUCKET/KEY sha256=SUM",
                        KEY = DB/STAMP-VERDICT.json with ":" and "-" removed
                        from STAMP, and "register: NOT RECORDED, so this drill
                        FAILS")
  - the register row    charts/tockmox-ai/templates/restore-drill.yaml and
                        charts/tockmox-identity/templates/restore-drill.yaml
                        ("register: STAMP VERDICT DETAIL backup=ID")
  - the hook            charts/tockmox-ai/values.yaml litellm.migrationJob
                        (argocd.argoproj.io/hook: Sync, hook-delete-policy:
                        BeforeHookCreation, label app.kubernetes.io/component:
                        migrations)
  - the owner label     charts/tockmox-common/templates/_helpers.tpl
                        (tockmox.com/managed-by: tockmox)

Exit 0 with a verdict, 2 for a usage error.
"""
import calendar
import json
import re
import sys
import time

HOOK = "argocd.argoproj.io/hook"
HOOK_DELETE = "argocd.argoproj.io/hook-delete-policy"
OWNER = "tockmox.com/managed-by"


def load(text):
    """Parsed JSON, or None."""
    try:
        return json.loads(text)
    except ValueError:
        return None


def items_of(doc):
    if isinstance(doc, dict) and isinstance(doc.get("items"), list):
        return doc["items"]
    return None


def epoch_of(stamp):
    """Seconds since the epoch for a Kubernetes RFC3339 UTC time, or None."""
    try:
        return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def get(d, *path):
    for p in path:
        if not isinstance(d, dict):
            return None
        d = d.get(p)
    return d


def backup(text, cluster, after):
    """Line 1: the verdict. Line 2, only on success: the backupId."""
    items = items_of(load(text))
    if items is None:
        return ["unreadable: not a list of Backups"]
    mine = [b for b in items if get(b, "spec", "cluster", "name") == cluster]
    if not mine:
        return ["no Backup of %s" % cluster]
    mine.sort(key=lambda b: get(b, "metadata", "creationTimestamp") or "")
    done = [b for b in mine if get(b, "status", "phase") == "completed"]
    if not done:
        return ["newest Backup of %s is %s" % (cluster, get(mine[-1], "status", "phase") or "without a phase")]
    with_id = [b for b in done if get(b, "status", "backupId")]
    if not with_id:
        return ["completed Backup of %s has no backupId" % cluster]
    newer = [b for b in with_id if (epoch_of(get(b, "metadata", "creationTimestamp")) or 0) >= after]
    if not newer:
        return ["completed Backup of %s predates the install" % cluster]
    return ["completed after the install", get(newer[-1], "status", "backupId")]


def scheduled(text, cluster):
    doc = load(text)
    if not isinstance(doc, dict) or doc.get("kind") != "ScheduledBackup":
        return ["unreadable: not a ScheduledBackup"]
    spec = doc.get("spec") or {}
    if get(spec, "cluster", "name") != cluster:
        return ["ScheduledBackup is for %s, not %s" % (get(spec, "cluster", "name"), cluster)]
    if spec.get("method") != "plugin":
        return ["ScheduledBackup method is %s, not plugin" % spec.get("method")]
    if not spec.get("schedule"):
        return ["ScheduledBackup has no schedule"]
    if spec.get("suspend") is True:
        return ["ScheduledBackup is suspended"]
    return ["plugin backup of %s on a schedule" % cluster]


def conditions_verdict(job):
    conds = get(job, "status", "conditions") or []
    for c in conds:
        if isinstance(c, dict) and c.get("type") == "Failed" and c.get("status") == "True":
            return "Failed: %s" % (c.get("reason") or c.get("message") or "no reason given")
    for c in conds:
        if isinstance(c, dict) and c.get("type") == "Complete" and c.get("status") == "True":
            return "Complete"
    return "not finished (active=%s)" % (get(job, "status", "active") or 0)


def job(text):
    doc = load(text)
    if not isinstance(doc, dict) or doc.get("kind") != "Job":
        return ["unreadable: not a Job"]
    return [conditions_verdict(doc)]


STAMP = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"


def row_lines(log, verdict):
    """(stamp, rest) of each 'register: STAMP VERDICT ...' row line."""
    out = []
    for line in log.splitlines():
        m = re.match(r"^register: (%s) %s( .*)?$" % (STAMP, verdict), line.strip())
        if m:
            out.append((m.group(1), m.group(2) or ""))
    return out


def drill_recorded(log, db, bucket):
    if not log.strip():
        return ["unreadable: empty log"]
    for line in log.splitlines():
        if line.startswith("register: NOT RECORDED"):
            return ["NOT RECORDED: %s" % line[len("register: NOT RECORDED"):].strip()[:200]]
    rec = re.findall(
        r"^register: recorded s3://%s/%s/([0-9]{8}T[0-9]{6}Z)-([A-Z]+)\.json sha256=([0-9a-f]{64})$"
        % (re.escape(bucket), re.escape(db)),
        log, re.M)
    if not rec:
        return ["no register line for %s in bucket %s" % (db, bucket)]
    if len(rec) != 1:
        return ["%d register lines, one expected" % len(rec)]
    key_stamp, verdict, _ = rec[0]
    if verdict != "PASS":
        return ["%s object recorded" % verdict]
    rows = row_lines(log, "PASS")
    if not rows:
        return ["PASS object recorded but the log holds no PASS row"]
    if rows[-1][0].replace("-", "").replace(":", "") != key_stamp:
        return ["PASS object's time differs from the PASS row's"]
    return ["PASS object recorded"]


def drill_pinned(log, backup_id):
    if not log.strip():
        return ["unreadable: empty log"]
    rows = row_lines(log, "PASS")
    if not rows:
        return ["no PASS row"]
    m = re.search(r"(?:^| )backup=(\S+)$", rows[-1][1])
    if not m:
        return ["PASS row carries no backup="]
    if m.group(1) == "none":
        return ["unpinned (backup=none)"]
    if m.group(1) != backup_id:
        return ["pinned %s, not %s" % (m.group(1), backup_id)]
    return ["pinned %s" % backup_id]


def migrations_jobs(text):
    items = items_of(load(text))
    if items is None:
        return None, None
    mig = [j for j in items
           if (get(j, "metadata", "labels") or {}).get("app.kubernetes.io/component") == "migrations"]
    return items, mig


def migrations_hook(text, name):
    items, mig = migrations_jobs(text)
    if items is None:
        return ["unreadable: not a list of Jobs"]
    if not mig:
        return ["no Job labelled app.kubernetes.io/component=migrations"]
    if len(mig) != 1:
        return ["%d migrations Jobs, one expected: %s" % (len(mig), ", ".join(sorted(get(j, "metadata", "name") or "?" for j in mig)))]
    j = mig[0]
    got = get(j, "metadata", "name")
    if got != name:
        return ["the migrations Job is %s, not %s" % (got, name)]
    ann = get(j, "metadata", "annotations") or {}
    if ann.get(HOOK) != "Sync":
        return ["%s is %s, not Sync" % (HOOK, ann.get(HOOK))]
    if ann.get(HOOK_DELETE) != "BeforeHookCreation":
        return ["%s is %s, not BeforeHookCreation" % (HOOK_DELETE, ann.get(HOOK_DELETE))]
    return ["one Sync hook Job, BeforeHookCreation"]


def migrations_complete(text, name):
    items, _ = migrations_jobs(text)
    if items is None:
        return ["unreadable: not a list of Jobs"]
    named = [j for j in items if get(j, "metadata", "name") == name]
    if not named:
        return ["no Job named %s" % name]
    return [conditions_verdict(named[0])]


def migrations_owner(text, name):
    items, mig = migrations_jobs(text)
    if items is None:
        return ["unreadable: not a list of Jobs"]
    for j in items:
        n = get(j, "metadata", "name") or ""
        labels = get(j, "metadata", "labels") or {}
        if "migrations" not in n and labels.get("app.kubernetes.io/component") != "migrations":
            continue
        if labels.get(OWNER) == "tockmox" or labels.get("app.kubernetes.io/part-of") == "tockmox":
            return ["tockmox-owned migrations Job: %s" % n]
        if re.match(r"^%s-[0-9a-f]{10}$" % re.escape(name), n):
            return ["hash-named migrations Job from 0.8.x: %s" % n]
        if n == name and not str(labels.get("helm.sh/chart", "")).startswith("litellm-"):
            return ["%s is not from the litellm subchart (helm.sh/chart is %s)" % (n, labels.get("helm.sh/chart"))]
    if not mig:
        return ["no migrations Job to attribute"]
    return ["the only migrations Job is the subchart's"]


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    opts = {}
    while args:
        if len(args) < 2 or not args[0].startswith("--"):
            sys.stderr.write("p09-recovery: bad arguments for %s\n" % cmd)
            return 2
        opts[args[0][2:]] = args[1]
        args = args[2:]
    text = sys.stdin.read()
    try:
        if cmd == "backup":
            out = backup(text, opts["cluster"], int(opts["after"]))
        elif cmd == "scheduled":
            out = scheduled(text, opts["cluster"])
        elif cmd == "job":
            out = job(text)
        elif cmd == "drill-recorded":
            out = drill_recorded(text, opts["db"], opts["bucket"])
        elif cmd == "drill-pinned":
            out = drill_pinned(text, opts["backup-id"])
        elif cmd == "migrations-hook":
            out = migrations_hook(text, opts["job"])
        elif cmd == "migrations-complete":
            out = migrations_complete(text, opts["job"])
        elif cmd == "migrations-owner":
            out = migrations_owner(text, opts["job"])
        else:
            sys.stderr.write("p09-recovery: unknown subcommand %s\n" % cmd)
            return 2
    except (KeyError, ValueError):
        sys.stderr.write("p09-recovery: missing or bad option for %s\n" % cmd)
        return 2
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

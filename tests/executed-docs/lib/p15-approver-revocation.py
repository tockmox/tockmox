#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The verdicts of paths/P15-approver-revocation.sh, kept apart from the path so that approver-revocation-rows-test.sh
can show each one red on a planted input, with no cluster.

Every subcommand reads standard input and prints ONE line, the verdict, which the path compares with the value it
expects. A read that cannot be judged prints "unreadable: ..." and is never a pass.

  watch --user U          stdin: what `forge-approver-watch.py --once` printed (its metrics, and its log lines).
                          "clean, not outside"          check_ok 1, and U is not among the people it reports
                          "clean, outside"              check_ok 1, and U is reported outside the admin group
                          "not clean, nobody judged"    check_ok 0, and no per-person series and no count
                          "not clean, yet judged: ..."  check_ok 0 with a per-person series or a count beside it
  watch-prs --user U      stdin: the same. The open pull requests the watcher says U's approval stands on, as
                          "#N #M", or "none".
  rule --group G --alert A
                          stdin: Prometheus's /api/v1/rules (JSON). "loaded, healthy, for Ns", or "absent".
  alert --group G --alert A [--user U]
                          stdin: the same. "firing", "pending" or "inactive": the state of that alert, counting only
                          the instances whose label user is U when --user is given.
  annotation --group G --alert A --user U --team PATH --pr N
                          stdin: the same. "names the team and #N" when the firing instance for U carries PATH and
                          the pull request in its description; otherwise what is missing.
  review --user U         stdin: a pull request's reviews from the forge (JSON list). "standing approval" when U's
                          latest approving or change-requesting review is an approval that is neither dismissed nor
                          stale, as the watcher reads it; otherwise "no standing approval".
  member --user U         stdin: a team's members from the forge (JSON list). "member" or "not member".
  field --name F          stdin: one JSON object. The value of its top-level key F, as text.
  ak --key K              stdin: what `ak shell -c` printed. The value on its line "P15 K=VALUE".
  pace --seconds N        stdin: a bash block. The same block with `P15_RC=$?; sleep N` after every complete command
                          line, so a background job one line starts (a port-forward) is up before the next line runs,
                          as it is when a reader enters the lines one at a time, and the status of the block's last
                          command is kept in P15_RC for the caller to exit with. A line that ends in a backslash
                          continues, and blank and comment lines get no pause. Nothing in the block is changed.
"""
import argparse
import json
import re
import sys

METRIC = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{([^}]*)\})?\s+(\S+)\s*$')
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')
PER_PERSON = ("tockmox_forge_approver_outside_group_info", "tockmox_forge_approval_by_outside_approver",
              "tockmox_forge_approvers_outside_group")


def one(line):
    print(line)
    return 0


def series(text):
    """[(name, {labels}, value)] for every line that is a metric sample. Log lines are skipped."""
    out = []
    for line in text.splitlines():
        m = METRIC.match(line.strip())
        if not m or not m.group(1).startswith("tockmox_forge_"):
            continue
        labels = dict((k, v.replace('\\"', '"').replace("\\\\", "\\")) for k, v in LABEL.findall(m.group(3) or ""))
        out.append((m.group(1), labels, m.group(4)))
    return out


def watch(text, user):
    s = series(text)
    ok = [v for n, _, v in s if n == "tockmox_forge_approvers_check_ok"]
    if len(ok) != 1:
        return "unreadable: the watcher printed %d check_ok lines, not one" % len(ok)
    judged = [n for n, _, _ in s if n in PER_PERSON]
    if ok[0] == "0":
        return "not clean, yet judged: %s" % ", ".join(sorted(set(judged))) if judged else "not clean, nobody judged"
    if ok[0] != "1":
        return "unreadable: check_ok is %s" % ok[0]
    counts = [v for n, _, v in s if n == "tockmox_forge_approvers_outside_group"]
    people = [lab.get("user") for n, lab, _ in s if n == "tockmox_forge_approver_outside_group_info"]
    if len(counts) != 1:
        return "unreadable: a clean check printed %d outside_group counts, not one" % len(counts)
    try:
        if int(float(counts[0])) != len(people):
            return "unreadable: the count says %s outside, and %d people are named" % (counts[0], len(people))
    except ValueError:
        return "unreadable: the outside_group count is %s" % counts[0]
    return "clean, outside" if user in people else "clean, not outside"


def watch_prs(text, user):
    prs = sorted({int(lab["pr"]) for n, lab, _ in series(text)
                  if n == "tockmox_forge_approval_by_outside_approver" and lab.get("user") == user
                  and lab.get("pr", "").isdigit()})
    return " ".join("#%d" % p for p in prs) if prs else "none"


def rules_of(text, group, alert):
    """The one alerting rule ALERT in GROUP, or a string that says why there is none."""
    try:
        doc = json.loads(text)
    except ValueError:
        return "unreadable: the rules read is not JSON"
    if not isinstance(doc, dict) or doc.get("status") != "success":
        return "unreadable: Prometheus did not answer success"
    groups = (doc.get("data") or {}).get("groups")
    if not isinstance(groups, list):
        return "unreadable: the answer has no rule groups"
    found = [r for g in groups if isinstance(g, dict) and g.get("name") == group
             for r in (g.get("rules") or []) if isinstance(r, dict) and r.get("name") == alert]
    if not found:
        return "absent"
    if len(found) > 1:
        return "unreadable: %s is in %s %d times" % (alert, group, len(found))
    return found[0]


def rule(text, group, alert):
    r = rules_of(text, group, alert)
    if isinstance(r, str):
        return r
    if r.get("type") not in (None, "alerting"):
        return "unreadable: %s is not an alerting rule" % alert
    health = r.get("health")
    dur = r.get("duration")
    if not isinstance(dur, (int, float)):
        return "unreadable: %s has no duration" % alert
    return "loaded, %s, for %ds" % ("healthy" if health == "ok" else "health %s" % health, int(dur))


def instances(r, user):
    al = r.get("alerts")
    if not isinstance(al, list):
        return None
    return [a for a in al if isinstance(a, dict)
            and (user is None or (a.get("labels") or {}).get("user") == user)]


def alert(text, group, name, user):
    r = rules_of(text, group, name)
    if isinstance(r, str):
        return r
    inst = instances(r, user)
    if inst is None:
        return "unreadable: %s carries no alert list" % name
    states = {a.get("state") for a in inst}
    if "firing" in states:
        return "firing"
    if "pending" in states:
        return "pending"
    return "inactive"


def annotation(text, group, name, user, team, pr):
    r = rules_of(text, group, name)
    if isinstance(r, str):
        return r
    inst = [a for a in (instances(r, user) or []) if a.get("state") == "firing"]
    if len(inst) != 1:
        return "unreadable: %d firing instances for %s, not one" % (len(inst), user)
    desc = str((inst[0].get("annotations") or {}).get("description", ""))
    missing = []
    if team not in desc:
        missing.append("the team")
    if not re.search(r"#%s(?!\d)" % re.escape(str(pr)), desc):
        missing.append("#%s" % pr)
    return "names the team and #%s" % pr if not missing else "missing: %s" % ", ".join(missing)


def review(text, user):
    try:
        reviews = json.loads(text)
    except ValueError:
        return "unreadable: the reviews read is not JSON"
    if not isinstance(reviews, list):
        return "unreadable: the reviews read is not a list"
    latest = None
    for rv in sorted((r for r in reviews if isinstance(r, dict)),
                     key=lambda r: r.get("id") if isinstance(r.get("id"), int) else 0):
        if (rv.get("user") or {}).get("login") == user and rv.get("state") in ("APPROVED", "REQUEST_CHANGES"):
            latest = rv
    if latest and latest.get("state") == "APPROVED" and not latest.get("dismissed") and not latest.get("stale"):
        return "standing approval"
    return "no standing approval"


def member(text, user):
    try:
        people = json.loads(text)
    except ValueError:
        return "unreadable: the members read is not JSON"
    if not isinstance(people, list):
        return "unreadable: the members read is not a list"
    return "member" if any(isinstance(p, dict) and p.get("login") == user for p in people) else "not member"


def field(text, name):
    try:
        doc = json.loads(text)
    except ValueError:
        return "unreadable: not JSON"
    if not isinstance(doc, dict) or name not in doc:
        return "unreadable: no %s" % name
    v = doc[name]
    return json.dumps(v) if isinstance(v, (dict, list, bool)) or v is None else str(v)


def ak(text, key):
    vals = [line.split("=", 1)[1].strip() for line in text.splitlines() if line.startswith("P15 %s=" % key)]
    if len(vals) != 1:
        return "unreadable: ak shell printed %d lines for %s, not one" % (len(vals), key)
    return vals[0]


def pace(text, seconds):
    out = []
    cont = False
    for line in text.split("\n"):
        out.append(line)
        s = line.strip()
        if cont:
            cont = s.endswith("\\")
            if not cont:
                out.append("P15_RC=$?; sleep %s" % seconds)
            continue
        if not s or s.startswith("#"):
            continue
        cont = s.endswith("\\")
        if not cont:
            out.append("P15_RC=$?; sleep %s" % seconds)
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("watch", "watch-prs", "review", "member"):
        sub.add_parser(c).add_argument("--user", required=True)
    p = sub.add_parser("rule")
    p.add_argument("--group", required=True)
    p.add_argument("--alert", required=True)
    p = sub.add_parser("alert")
    p.add_argument("--group", required=True)
    p.add_argument("--alert", required=True)
    p.add_argument("--user")
    p = sub.add_parser("annotation")
    for o in ("--group", "--alert", "--user", "--team", "--pr"):
        p.add_argument(o, required=True)
    sub.add_parser("field").add_argument("--name", required=True)
    sub.add_parser("ak").add_argument("--key", required=True)
    sub.add_parser("pace").add_argument("--seconds", required=True)
    a = ap.parse_args()
    text = sys.stdin.read()
    if a.cmd == "pace":
        if not re.match(r"^[0-9]+$", a.seconds):
            return one("unreadable: --seconds is not a whole number")
        sys.stdout.write(pace(text, a.seconds))
        return 0
    if not text.strip():
        return one("unreadable: nothing was read")
    if a.cmd == "watch":
        return one(watch(text, a.user))
    if a.cmd == "watch-prs":
        return one(watch_prs(text, a.user))
    if a.cmd == "rule":
        return one(rule(text, a.group, a.alert))
    if a.cmd == "alert":
        return one(alert(text, a.group, a.alert, a.user))
    if a.cmd == "annotation":
        return one(annotation(text, a.group, a.alert, a.user, a.team, a.pr))
    if a.cmd == "review":
        return one(review(text, a.user))
    if a.cmd == "member":
        return one(member(text, a.user))
    if a.cmd == "field":
        return one(field(text, a.name))
    return one(ak(text, a.key))


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The verdicts of paths/P14-open-applications.sh, kept apart from the path so that open-applications-rows-test.sh
can show each one red on a planted input, with no cluster.

Every subcommand reads standard input and prints ONE line, the verdict, which the path compares with the value it
expects. A read that cannot be judged prints "unreadable: ..." and is never a pass.

  listed --slug SLUG      stdin: the ConfigMap tockmox-identity-open-applications as JSON (kubectl get -o json).
                          "not listed"                 the list is readable and does not name SLUG
                          "listed, not declared open"  SLUG has no group or user binding and the site did not declare
                                                       it open: the shape the console's Status page warns about
                          "listed, declared open"      SLUG is listed with everyone true: the console says nothing
  written-at              stdin: the same ConfigMap. Prints the list's generatedAt, or "unreadable: ...".
  everyone-env            stdin: the CronJob tockmox-open-applications as JSON. Prints the value of
                          TOCKMOX_OPEN_TO_EVERYONE in its container, which is sso.access.everyone as the job reads it.
  unbind                  stdin: a blueprint (or a ConfigMap that carries one) as text. Prints the same text with every
                          authentik_policies.policybinding entry taken out, byte for byte otherwise. Exit 1, with
                          "unreadable: ..." on stdout, when there is no such entry: an edit that changes nothing would
                          plant a bound application and call it unbound.
  bindings                stdin: the same kind of text. Prints "N present, M absent": the policybinding entries by state.
"""
import argparse
import json
import re
import sys

REPORT_KEY = "report.json"
ENTRY = re.compile(r"^(\s*)- model:\s*(\S+)\s*$")


def one(line):
    print(line)
    return 0


def report_of(text):
    """The report inside the ConfigMap, or a string that says why there is none."""
    try:
        doc = json.loads(text)
    except ValueError:
        return "unreadable: the ConfigMap read is not JSON"
    if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
        return "unreadable: not a ConfigMap"
    raw = (doc.get("data") or {}).get(REPORT_KEY)
    if raw is None:
        return "unreadable: the ConfigMap has no %s (the job has not written)" % REPORT_KEY
    try:
        rep = json.loads(raw)
    except ValueError:
        return "unreadable: %s is not JSON" % REPORT_KEY
    if not isinstance(rep, dict) or rep.get("version") != 1 or not isinstance(rep.get("open"), list):
        return "unreadable: %s is not a version 1 list" % REPORT_KEY
    return rep


def listed(text, slug):
    rep = report_of(text)
    if isinstance(rep, str):
        return rep
    rows = [a for a in rep["open"] if isinstance(a, dict) and a.get("slug") == slug]
    if not rows:
        return "not listed"
    if len(rows) > 1:
        return "unreadable: %s is listed %d times" % (slug, len(rows))
    return "listed, declared open" if rows[0].get("everyone") is True else "listed, not declared open"


def written_at(text):
    rep = report_of(text)
    if isinstance(rep, str):
        return rep
    ts = rep.get("generatedAt")
    return ts if isinstance(ts, str) and ts else "unreadable: the list carries no generatedAt"


def everyone_env(text):
    try:
        doc = json.loads(text)
        containers = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"]
    except (ValueError, KeyError, TypeError):
        return "unreadable: not a CronJob with a container"
    for c in containers:
        for e in c.get("env") or []:
            if e.get("name") == "TOCKMOX_OPEN_TO_EVERYONE":
                return str(e.get("value"))
    return "unreadable: no TOCKMOX_OPEN_TO_EVERYONE in the CronJob"


def entries(lines):
    """(start, end, model) of each `- model:` list item: it ends where the next item at the same indent starts, or
    where the indentation drops below the item's own."""
    out = []
    i = 0
    while i < len(lines):
        m = ENTRY.match(lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        j = i + 1
        while j < len(lines):
            s = lines[j]
            if s.strip() and len(s) - len(s.lstrip(" ")) <= indent:
                break
            j += 1
        while j > i + 1 and not lines[j - 1].strip():
            j -= 1          # blank lines after an item are not part of it
        out.append((i, j, m.group(2)))
        i = j
    return out


def unbind(text):
    lines = text.split("\n")
    drop = [(a, b) for a, b, model in entries(lines) if model == "authentik_policies.policybinding"]
    if not drop:
        return None
    keep = []
    for n, line in enumerate(lines):
        if not any(a <= n < b for a, b in drop):
            keep.append(line)
    return "\n".join(keep)


def bindings(text):
    lines = text.split("\n")
    present = absent = 0
    for a, b, model in entries(lines):
        if model != "authentik_policies.policybinding":
            continue
        state = "present"
        for s in lines[a:b]:
            m = re.match(r"^\s*state:\s*(\S+)\s*$", s)
            if m:
                state = m.group(1)
        if state == "absent":
            absent += 1
        else:
            present += 1
    return "%d present, %d absent" % (present, absent)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("listed")
    p.add_argument("--slug", required=True)
    sub.add_parser("written-at")
    sub.add_parser("everyone-env")
    sub.add_parser("unbind")
    sub.add_parser("bindings")
    a = ap.parse_args()
    text = sys.stdin.read()
    if a.cmd == "listed":
        return one(listed(text, a.slug))
    if a.cmd == "written-at":
        return one(written_at(text))
    if a.cmd == "everyone-env":
        return one(everyone_env(text))
    if a.cmd == "bindings":
        return one(bindings(text))
    out = unbind(text)
    if out is None:
        print("unreadable: no authentik_policies.policybinding entry to take out")
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

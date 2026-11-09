#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# forge-history.py: read a nightly forge dump and turn its pull requests into
# restorable issues.
#
# WHAT. "check DIR" reads a forge dump directory (the one install/forge-offsite-copy.sh
# TASK=dump writes), confirms it is a v1 dump and that what it holds matches the counts
# its MANIFEST states, and prints one summary line. "issues DIR" does the same checks and
# then prints JSON Lines, one object per pull request, each with the title and the
# markdown body of the closed issue that stands in for that pull request on a rebuilt
# forge.
#
# WHY. A rebuilt forge has no pull requests: git carries commits, not reviews. The
# ruling of 2026-11-08 is that the review history comes back as one closed issue per
# pull request, so that who approved what, and why, can still be read. The counts in
# the MANIFEST are a tamper and truncation check: a dump that lost a page must stop the
# restore, not quietly restore less.
#
# "restore DIR --api URL --repo ORG/REPO" posts those issues to a forge (Forgejo's API),
# reading the credential as "user:password" from the first line of stdin, never from
# argv: it makes the label restored-from-dump if it is missing, skips an issue whose title
# is already there under that label (so a rerun creates nothing twice), creates each new
# one and closes it. It prints one summary line and exits 1 if any issue failed, which a
# caller treats as a warning: the restore is best effort, the dump stays in the copy.
#
# Bodies of user text pass through verbatim, with no escaping, and are cut at 60000
# characters because a forge refuses very long issue bodies. A field a forge object
# lacks is shown as "?" so an odd object never stops a restore.
import base64
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request

FORMAT = "format tockmox-forge-dump v1"
LIMIT = 60000
NOTE = "\n\n_(cut: the full text is in the forge dump)_"


class Bad(Exception):
    pass


def s(v):
    return "?" if v is None or v == "" else str(v)


def login(o):
    u = o.get("user")
    return s(u.get("login")) if isinstance(u, dict) else "?"


def text(t):
    if t is None:
        return ""
    t = t if isinstance(t, str) else str(t)
    if len(t) > LIMIT:
        t = t[:LIMIT] + NOTE
    return t


def quote(t):
    return "\n".join("  > " + line for line in text(t).split("\n"))


def load_list(path):
    name = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        raise Bad("%s is not valid JSON (%s)" % (name, e))
    if not isinstance(data, list):
        raise Bad("%s is not a JSON list" % name)
    for it in data:
        if not isinstance(it, dict):
            raise Bad("%s holds an item that is not an object" % name)
    return data


def nums(path):
    return [int(x) for x in re.findall(r"\d+", os.path.basename(path))]


def files(d, pattern):
    return sorted(glob.glob(os.path.join(d, pattern)), key=lambda p: (nums(p), p))


def load(d):
    mpath = os.path.join(d, "MANIFEST")
    if not os.path.isfile(mpath):
        raise Bad("MANIFEST is missing from %s" % d)
    try:
        with open(mpath, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except (OSError, ValueError) as e:
        raise Bad("MANIFEST cannot be read (%s)" % e)
    if lines[0] != FORMAT:
        raise Bad('MANIFEST first line is not "%s"' % FORMAT)
    man = {}
    for line in lines[1:]:
        parts = line.split(None, 1)
        if len(parts) == 2:
            man.setdefault(parts[0], parts[1].strip())

    pulls = {}
    for p in files(d, "pulls-*.json"):
        for o in load_list(p):
            n = o.get("number")
            if not isinstance(n, int) or isinstance(n, bool):
                raise Bad("%s holds a pull request with no number" % os.path.basename(p))
            pulls[n] = o

    reviews = {}
    nrev = 0
    for p in files(d, "reviews-*.json"):
        m = re.fullmatch(r"reviews-(\d+)-(\d+)\.json", os.path.basename(p))
        if not m:
            continue
        n = int(m.group(1))
        for i, o in enumerate(load_list(p)):
            key = o.get("id", ("noid", p, i))
            reviews.setdefault(n, {})[key] = o
    nrev = sum(len(v) for v in reviews.values())

    rcs = {}
    for p in files(d, "review-comments-*.json"):
        m = re.fullmatch(r"review-comments-(\d+)-(\d+)\.json", os.path.basename(p))
        if not m:
            continue
        n = int(m.group(1))
        for i, o in enumerate(load_list(p)):
            key = (m.group(2), o.get("id", ("noid", p, i)))
            rcs.setdefault(n, {})[key] = o
    nrc = sum(len(v) for v in rcs.values())

    ics = {}
    for p in files(d, "issue-comments-*.json"):
        for i, o in enumerate(load_list(p)):
            ics[o.get("id", ("noid", p, i))] = o

    for key, got in (("pull-requests", len(pulls)), ("reviews", nrev),
                     ("review-comments", nrc), ("issue-comments", len(ics))):
        want = man.get(key, "")
        if not want.isdigit() or int(want) != got:
            raise Bad("MANIFEST says %s %s, but %d were read" % (key, want or "(nothing)", got))
    return man, pulls, reviews, rcs, ics


def when(created):
    m = re.fullmatch(r"(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)\d\dZ", created)
    if not m:
        return created
    return "%s-%s-%s %s:%s UTC" % m.groups()


def body_for(man, n, o, reviews, rcs, ics):
    created = man.get("created", "?")
    st = o.get("state")
    if o.get("merged") is True:
        end = "merged %s" % s(o.get("merged_at"))
    elif st == "closed":
        end = "closed"
    else:
        end = "open at the time of the dump"
    out = ["_Restored from the forge dump of %s. Pull request #%d by %s, opened %s, %s._"
           % (when(created), n, login(o), s(o.get("created_at")), end), ""]
    desc = text(o.get("body"))
    out.append(desc if desc.strip() else "_(no description)_")
    out += ["", "### Reviews", ""]
    revs = sorted(reviews.get(n, {}).values(), key=lambda r: (str(r.get("submitted_at", "")), str(r.get("id", ""))))
    for r in revs:
        out.append("- **%s** %s at %s" % (login(r), s(r.get("state")), s(r.get("submitted_at"))))
        if text(r.get("body")) != "":
            out.append(quote(r.get("body")))
    rc = sorted(rcs.get(n, {}).values(), key=lambda c: (str(c.get("created_at", "")), str(c.get("id", ""))))
    if rc:
        out += ["", "### Review comments", ""]
        for c in rc:
            line = "?"
            for k in ("line", "original_line", "position"):
                if c.get(k) is not None:
                    line = str(c[k])
                    break
            out.append("- `%s:%s` **%s** at %s:" % (s(c.get("path")), line, login(c), s(c.get("created_at"))))
            out.append(quote(c.get("body")))
    mine = []
    for c in ics.values():
        m = re.search(r"/(?:issues|pulls)/(\d+)/?$", str(c.get("issue_url", "")))
        if m and int(m.group(1)) == n:
            mine.append(c)
    mine.sort(key=lambda c: (str(c.get("created_at", "")), str(c.get("id", ""))))
    if mine:
        out += ["", "### Comments", ""]
        for c in mine:
            out.append("- **%s** at %s:" % (login(c), s(c.get("created_at"))))
            out.append(quote(c.get("body")))
    return "\n".join(out) + "\n"


LABEL = "restored-from-dump"


def call(api, auth, method, path, payload=None):
    """-> (status, decoded JSON or None). Never raises for an HTTP status."""
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(api + path, data=data, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(auth.encode("utf-8")).decode("ascii"))
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            code = r.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    except (urllib.error.URLError, OSError) as e:
        return 0, {"message": str(e)}
    try:
        return code, json.loads(raw.decode("utf-8")) if raw else None
    except ValueError:
        return code, None


def restore(d, api, repo, auth):
    man, pulls, reviews, rcs, ics = load(d)
    base = "/repos/%s" % repo
    code, labels = call(api, auth, "GET", base + "/labels?limit=50")
    lid = None
    if code == 200 and isinstance(labels, list):
        lid = next((l.get("id") for l in labels if isinstance(l, dict) and l.get("name") == LABEL), None)
    if lid is None:
        code, lab = call(api, auth, "POST", base + "/labels", {
            "name": LABEL, "color": "#8b8b8b",
            "description": "Review history restored from the forge dump after a rebuild"})
        if code != 201 or not isinstance(lab, dict) or "id" not in lab:
            raise Bad("cannot create the label %s (HTTP %s)" % (LABEL, code))
        lid = lab["id"]
    have, page = set(), 1
    while page <= 400:
        code, items = call(api, auth, "GET", base + "/issues?state=all&type=issues&labels=%s&limit=50&page=%d"
                           % (LABEL, page))
        if code != 200:
            raise Bad("cannot list the issues already restored (HTTP %s)" % code)
        if not items:
            break
        have.update(str(i.get("title", "")) for i in items if isinstance(i, dict))
        page += 1
    made = had = failed = 0
    for n in sorted(pulls):
        o = pulls[n]
        title = "Restored: #%d %s" % (n, s(o.get("title")))
        if title in have:
            had += 1
            continue
        code, issue = call(api, auth, "POST", base + "/issues", {
            "title": title, "body": body_for(man, n, o, reviews, rcs, ics), "labels": [lid]})
        if code != 201 or not isinstance(issue, dict) or "number" not in issue:
            failed += 1
            print("forge-history: pull request #%d was not restored (HTTP %s)" % (n, code), file=sys.stderr)
            continue
        code, _ = call(api, auth, "PATCH", base + "/issues/%d" % issue["number"], {"state": "closed"})
        if code not in (200, 201):
            failed += 1
            print("forge-history: issue #%d was created but not closed (HTTP %s)" % (issue["number"], code),
                  file=sys.stderr)
            continue
        made += 1
    print("%d pull requests restored as closed issues (%d already present, %d failed) from the forge dump of %s"
          % (made, had, failed, when(man.get("created", "?"))))
    return 1 if failed else 0


def main(argv):
    if len(argv) == 7 and argv[1] == "restore" and argv[3] == "--api" and argv[5] == "--repo":
        auth = sys.stdin.readline().rstrip("\r\n")
        if ":" not in auth:
            print("forge-history: restore reads user:password from the first line of stdin", file=sys.stderr)
            return 2
        try:
            return restore(argv[2], argv[4].rstrip("/"), argv[6], auth)
        except Bad as e:
            print("forge-history: %s" % e, file=sys.stderr)
            return 1
    if len(argv) != 3 or argv[1] not in ("check", "issues"):
        print("usage: forge-history.py check|issues DIR, or restore DIR --api URL --repo ORG/REPO (user:password on stdin)",
              file=sys.stderr)
        return 2
    try:
        man, pulls, reviews, rcs, ics = load(argv[2])
    except Bad as e:
        print("forge-history: %s" % e, file=sys.stderr)
        return 1
    if argv[1] == "check":
        print("dump %s of %s: %d pull requests, %d reviews, %d review comments, %d issue comments" % (
            man.get("created", "?"), man.get("repository", "?"), len(pulls),
            sum(len(v) for v in reviews.values()), sum(len(v) for v in rcs.values()), len(ics)))
        return 0
    for n in sorted(pulls):
        o = pulls[n]
        print(json.dumps({"number": n, "title": "Restored: #%d %s" % (n, s(o.get("title"))),
                          "body": body_for(man, n, o, reviews, rcs, ics)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Why the readiness bar is not clean, in Argo CD's own words. Used by paths/P09-install-md-end-to-end.sh when the bar
times out, so a failed run names what Argo CD saw instead of only "OutOfSync Degraded".

  stdin:  Argo CD's Applications (kubectl get applications -o json).
  stdout: one line per Application the bar lists (not Synced or not Healthy; site-apps excluded, as the bar excludes
          it), sorted by name:
            NAME SYNC/HEALTH; operation PHASE: MESSAGE; failed: KIND/NAME STATUS/HOOKPHASE MESSAGE ...;
            TYPE: MESSAGE ...; not ready: KIND/NAME SYNC/HEALTH MESSAGE ... (at most five, then "and N more")
          each line cut at 600 characters. "none" when no Application is listed; "unreadable: WHY" when stdin is not a
          list of Applications. Exit 0 in every case: this is a note, never a verdict.

  --scrub URL  every occurrence of URL, and then of its host, is replaced by <site repository> and <site host>, so
               the lab's address for the site repository stays out of the report. Empty changes nothing.
"""
import argparse
import json
import re
import sys
from urllib.parse import urlsplit

LIMIT = 600
SHOWN = 5


def one(s):
    return " ".join(str(s or "").split())


def host_of(url):
    try:
        net = urlsplit(url).netloc
    except ValueError:
        return ""
    return net.rsplit("@", 1)[-1].split(":")[0]


def scrubber(url):
    url = (url or "").strip()
    if not url:
        return lambda s: s
    host = host_of(url)

    def f(s):
        s = s.replace(url, "<site repository>")
        if host:
            s = re.sub(re.escape(host), "<site host>", s, flags=re.IGNORECASE)
        return s
    return f


def why(app):
    st = app.get("status") or {}
    name = (app.get("metadata") or {}).get("name", "?")
    sync = (st.get("sync") or {}).get("status") or "?"
    health = (st.get("health") or {}).get("status") or "?"
    if name == "site-apps" or (sync == "Synced" and health == "Healthy"):
        return None
    parts = ["%s %s/%s" % (name, sync, health)]
    op = st.get("operationState") or {}
    if op:
        parts.append("operation %s: %s" % (op.get("phase") or "?", one(op.get("message")) or "-"))
    failed = [r for r in ((op.get("syncResult") or {}).get("resources") or [])
              if r.get("status") == "SyncFailed" or r.get("hookPhase") in ("Failed", "Error", "Running")]
    for r in failed[:SHOWN]:
        parts.append("failed: %s/%s %s/%s %s" % (r.get("kind") or "?", r.get("name") or "?", r.get("status") or "-",
                                                 r.get("hookPhase") or "-", one(r.get("message"))))
    for c in st.get("conditions") or []:
        parts.append("%s: %s" % (c.get("type") or "?", one(c.get("message"))))
    notready = []
    for r in st.get("resources") or []:
        h = r.get("health") or {}
        if r.get("status") not in (None, "Synced") or h.get("status") not in (None, "Healthy"):
            notready.append(r)
    for r in notready[:SHOWN]:
        h = r.get("health") or {}
        msg = one(h.get("message"))
        parts.append("not ready: %s/%s %s/%s%s" % (r.get("kind") or "?", r.get("name") or "?", r.get("status") or "-",
                                                   h.get("status") or "-", (" " + msg) if msg else ""))
    if len(notready) > SHOWN:
        parts.append("and %d more" % (len(notready) - SHOWN))
    return "; ".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scrub", default="")
    a = ap.parse_args()
    scrub = scrubber(a.scrub)
    try:
        doc = json.loads(sys.stdin.read())
        items = doc.get("items")
        if not isinstance(items, list):
            raise ValueError
    except (ValueError, AttributeError):
        print("unreadable: not a list of Applications")
        return 0
    lines = []
    for app in sorted(items, key=lambda x: str((x.get("metadata") or {}).get("name", ""))):
        w = why(app)
        if w is not None:
            lines.append(scrub(w)[:LIMIT])
    print("\n".join(lines) if lines else "none")
    return 0


if __name__ == "__main__":
    sys.exit(main())

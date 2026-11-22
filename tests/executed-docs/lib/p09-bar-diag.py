#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""What a namespace holds when the readiness bar records a FAIL. Used by paths/P09-install-md-end-to-end.sh (bar_diag),
so a run whose VM is destroyed at the safe end still names why its pods never came up: an image that could not be
pulled, a volume that never bound, a container that keeps exiting. Output only, never a verdict: exit 0 in every case.

  --pods        stdin:  a namespace's pods (kubectl get pods -o json).
                stdout: one line per container that is not running and ready, sorted by pod name:
                          pod NAME (PHASE): [init ]container NAME, image IMAGE: waiting REASON: MESSAGE
                          pod NAME (PHASE): [init ]container NAME, image IMAGE: terminated REASON, exit N: MESSAGE
                        with "; last terminated REASON, exit N" when it has restarted, and for a pod that is not
                        Running and has no such container (Pending before any container exists, Evicted, ...) its own
                        reason and each condition that is not True:
                          pod NAME (Pending): PodScheduled False Unschedulable: MESSAGE
                        A pod that Succeeded, an init container that Completed, and a container running and ready are
                        not listed. "none" when nothing is; "unreadable: WHY" when stdin is not a list of pods.

  --frame NS    stdin:  any text. stdout: each non-empty line as "DIAG: NS: LINE", cut at --width characters (400),
                at most --cap lines (200): past that the last line kept says how many were cut. --scrub URL takes the
                site repository's URL and then its host out, as lib/p09-stuck-apps.py does for Argo CD's words.
"""
import argparse
import importlib.util
import json
import os
import sys


def _stuck_apps():
    # the site-repository scrub is lib/p09-stuck-apps.py's, so the two notes cannot disagree on what is scrubbed
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "p09-stuck-apps.py")
    spec = importlib.util.spec_from_file_location("p09_stuck_apps", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def one(s):
    return " ".join(str(s or "").split())


def state_of(cs):
    st = cs.get("state") or {}
    w, t = st.get("waiting"), st.get("terminated")
    if w is not None:
        msg = one(w.get("message"))
        return "waiting %s%s" % (w.get("reason") or "-", (": " + msg) if msg else "")
    if t is not None:
        msg = one(t.get("message"))
        return "terminated %s, exit %s%s" % (t.get("reason") or "-", t.get("exitCode", "?"), (": " + msg) if msg else "")
    if st.get("running") is not None:
        return "running, not ready, %s restart(s)" % cs.get("restartCount", 0)
    return "no state yet"


def wanted(cs, init):
    st = cs.get("state") or {}
    t = st.get("terminated")
    if init and t is not None and t.get("reason") == "Completed":
        return False
    return not (st.get("running") is not None and cs.get("ready"))


def pod_lines(pod):
    meta, st = pod.get("metadata") or {}, pod.get("status") or {}
    name, phase = meta.get("name") or "?", st.get("phase") or "?"
    if phase == "Succeeded":
        return []
    out = []
    for init, key in ((True, "initContainerStatuses"), (False, "containerStatuses")):
        for cs in st.get(key) or []:
            if not wanted(cs, init):
                continue
            line = "pod %s (%s): %scontainer %s, image %s: %s" % (
                name, phase, "init " if init else "", cs.get("name") or "?", cs.get("image") or "?", state_of(cs))
            last = (cs.get("lastState") or {}).get("terminated")
            if last is not None:
                line += "; last terminated %s, exit %s" % (last.get("reason") or "-", last.get("exitCode", "?"))
            out.append(line)
    if not out and phase != "Running":
        why = [one(st.get("reason")), one(st.get("message"))]
        head = "pod %s (%s)" % (name, phase)
        if any(why):
            out.append("%s: %s" % (head, ": ".join(w for w in why if w)))
        for c in st.get("conditions") or []:
            if c.get("status") != "True":
                msg = one(c.get("message"))
                out.append("%s: %s %s %s%s" % (head, c.get("type") or "?", c.get("status") or "?",
                                               c.get("reason") or "-", (": " + msg) if msg else ""))
        if not out:
            out.append("%s: no container status and no condition" % head)
    return out


def pods(_args):
    try:
        doc = json.loads(sys.stdin.read())
        items = doc.get("items")
        if not isinstance(items, list):
            raise ValueError
    except (ValueError, AttributeError):
        print("unreadable: not a list of pods")
        return 0
    lines = []
    for pod in sorted(items, key=lambda p: str((p.get("metadata") or {}).get("name", ""))):
        if isinstance(pod, dict):
            lines.extend(pod_lines(pod))
    print("\n".join(lines) if lines else "none")
    return 0


def frame(args):
    scrub = _stuck_apps().scrubber(args.scrub)
    prefix = "DIAG: %s: " % args.frame
    lines = [ln.rstrip() for ln in sys.stdin.read().splitlines() if ln.strip()]
    if len(lines) > args.cap:
        cut = len(lines) - (args.cap - 1)
        lines = lines[:args.cap - 1] + ["... %d more line(s) cut here (at most %d a namespace)" % (cut, args.cap)]
    for ln in lines:
        print((prefix + scrub(ln))[:args.width])
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--pods", action="store_true")
    g.add_argument("--frame", metavar="NS")
    ap.add_argument("--scrub", default="")
    ap.add_argument("--cap", type=int, default=200)
    ap.add_argument("--width", type=int, default=400)
    a = ap.parse_args()
    return pods(a) if a.pods else frame(a)


if __name__ == "__main__":
    sys.exit(main())

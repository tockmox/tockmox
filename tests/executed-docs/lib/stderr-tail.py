#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The last lines of a provisioner's stderr, safe to put in a run report.

    stderr-tail.py --lines 40 FILE

The run report is uploaded as a CI artifact and read by people and agents who
never open the job log, so what goes into it is bounded and cleaned:

  - only the last --lines lines (a provision can print thousands);
  - terminal escape codes and other control characters removed;
  - anything shaped like a credential replaced by [masked]: a PEM private key
    block, a JWT, a `Bearer` value, the value after a key whose name says
    token, password, secret, credential, api key or authorization, and any run
    of 40 or more base64 or hex characters (a kubeconfig's certificate data, a
    raw token), except a 40- or 64-hex id (a commit, a digest) and a path whose
    parts are all short.

An empty or missing file says so in one line rather than printing nothing,
because an empty section in a report reads like a bug in the report.

Exit 0 always, unless the arguments are wrong (2): this runs inside a failure
report and must not become a second failure.
"""

import argparse
import re
import sys

ESC = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b[@-_]")
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
MASKS = [
    re.compile(r"eyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*){1,2}"),
    re.compile(r"(?i)(\bbearer\s+)\S+"),
    re.compile(r"(?i)((?:token|passw(?:or)?d|secret|credential|api[_-]?key|authorization)[A-Za-z0-9_-]*[\"']?\s*[:=]\s*[\"']?)[^\s\"',;]+"),
]
LONG = re.compile(r"[A-Za-z0-9+/_-]{40,}={0,2}")
ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def long_run(m):
    """A 40+ character base64/hex run is masked, unless it is a git or sha256 id, or a path of short parts."""
    t = m.group(0)
    if ID.fullmatch(t) or ("/" in t and max(len(x) for x in t.split("/")) < 40):
        return t
    return "[masked]"
PEM_BEGIN = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
PEM_END = re.compile(r"-----END [A-Z ]*PRIVATE KEY-----")


def clean(line):
    line = CTRL.sub("", ESC.sub("", line.rstrip("\r\n")))
    for i, rx in enumerate(MASKS):
        if i in (1, 2):
            line = rx.sub(lambda m: m.group(1) + "[masked]", line)
        else:
            line = rx.sub("[masked]", line)
    return LONG.sub(long_run, line)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lines", type=int, default=40)
    ap.add_argument("file")
    a = ap.parse_args()
    if a.lines < 1:
        print("stderr-tail: --lines must be at least 1", file=sys.stderr)
        return 2
    try:
        with open(a.file, errors="replace") as f:
            raw = f.read().splitlines()
    except OSError:
        print("(no stderr was captured: %s is missing)" % a.file)
        return 0
    out, in_pem = [], False
    for line in raw:
        if PEM_BEGIN.search(line):
            in_pem = True
            out.append("[masked: a private key block]")
            continue
        if in_pem:
            if PEM_END.search(line):
                in_pem = False
            continue
        out.append(clean(line))
    if not any(x.strip() for x in out):
        print("(the provisioner wrote nothing to stderr)")
        return 0
    shown = out[-a.lines:]
    if len(out) > len(shown):
        print("(%d earlier lines not shown)" % (len(out) - len(shown)))
    for line in shown:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""No `cmd | grep -q` in a script that sets pipefail.

    python3 tools/check-pipe-grep-q.py              scan every tracked shell script
    python3 tools/check-pipe-grep-q.py --selftest   prove the scan goes red, and green where it should
    python3 tools/check-pipe-grep-q.py --root DIR   scan DIR (every file in it) instead of the tracked tree

WHY. `grep -q` exits at its first match. Whatever writes into the pipe is still
writing, gets SIGPIPE and exits 141, and under `set -o pipefail` the pipeline's
status is that 141: a MATCH reads as a failure. Whether the writer has finished
before grep exits is a race, so it fails only sometimes, and more often on a
loaded machine. On an idle runner a 24 KB render piped into `grep -q` failed 0
times in 300; with the CPUs busy it failed 6 times in 3000, every one exit 141
from printf. check-all runs its gates in parallel and had over a hundred of
these, which is why it went red at random on pushes the PR run had passed.

THE FIX this asks for is `cmd | grep PATTERN >/dev/null`: grep without -q reads
to the end of its input, so the writer is never cut off, and the exit status is
the same. Capturing first and testing the variable (`out=$(cmd); grep -q P
<<<"$out"`) is also fine and is what tests/executed-docs/lib/assert.sh does.

WHAT IT FLAGS, in a tracked file that is a shell script (*.sh, or a sh/bash
shebang) and contains `pipefail` outside a comment: a `| grep` whose options
include q (-q, -qF, -Eq, --quiet, --silent). It reads the pipe at the shell's
top level and inside `$( ... )`.

WHAT IT DOES NOT SEE. A pipe inside a quoted string that is later eval'd (the
string is data until it runs), and a script that enables pipefail some other
way (an inherited SHELLOPTS). It also leaves alone `| grep -m N` and `| head`,
which cut their writer off the same way but are used here to pick a value or
trim a message, where the status is not the verdict; when one of those decides
a test, it has the same race.
"""
import os
import re
import subprocess
import sys
import tempfile

EARLY_EXIT = re.compile(r"^(-[A-Za-z0-9]*q[A-Za-z0-9]*|--quiet|--silent)$")
PIPE_GREP = re.compile(r"(?<![|])\|(?![|&])\s*grep\s+")


def contexts(line):
    """Map each character index to the innermost quoting context: top, $(, ", ' or `."""
    stack, i, ctx_at = ["top"], 0, {}
    while i < len(line):
        c, ctx = line[i], stack[-1]
        ctx_at[i] = ctx
        if ctx == "'":
            if c == "'":
                stack.pop()
        elif c == "\\":
            ctx_at[i + 1] = ctx
            i += 2
            continue
        elif ctx == '"':
            if c == '"':
                stack.pop()
            elif line.startswith("$(", i):
                stack.append("$(")
                ctx_at[i + 1] = "$("
                i += 2
                continue
        else:
            if c == "#" and (i == 0 or line[i - 1] in " \t;"):
                break  # the rest of the line is a comment
            if c in "'\"":
                stack.append(c)
            elif line.startswith("$(", i):
                stack.append("$(")
                ctx_at[i + 1] = "$("
                i += 2
                continue
            elif c == "`":
                stack.pop() if ctx == "`" else stack.append("`")
            elif c == "(" and ctx == "$(":
                stack.append("$(")
            elif c == ")" and ctx == "$(":
                stack.pop()
        i += 1
    return ctx_at


def findings_in_line(line):
    ctx_at = contexts(line)
    out = []
    for m in PIPE_GREP.finditer(line):
        if ctx_at.get(m.start()) not in ("top", "$("):
            continue
        words = line[m.end():].split()
        for w in words:
            if w == "--" or not w.startswith("-"):
                break
            if EARLY_EXIT.match(w):
                out.append(w)
                break
    return out


def sets_pipefail(text):
    return any("pipefail" in l.split("#", 1)[0] for l in text.splitlines())


def is_shell(path):
    if path.endswith(".sh"):
        return True
    try:
        with open(path, "rb") as f:
            first = f.readline(200)
    except OSError:
        return False
    return bool(re.match(rb"#!\s*\S*(/env\s+)?\S*\b(ba)?sh\b", first))


def scan(paths):
    found = []
    for p in paths:
        if not os.path.isfile(p) or not is_shell(p):
            continue
        try:
            text = open(p, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        if not sets_pipefail(text):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for flag in findings_in_line(line):
                found.append(f"{p}:{n}: `| grep {flag}` under pipefail: {line.strip()[:120]}")
    return found


def tracked(root):
    """What git tracks under root, or None when root is not a git checkout (the caller reports SKIPPED)."""
    try:
        out = subprocess.run(["git", "--no-optional-locks", "-C", root, "ls-files", "-z"],
                             capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [os.path.join(root, p) for p in out.decode().split("\0") if p]


def selftest():
    cases = [  # (name, script body, should it be flagged)
        ("a top-level pipe into grep -q", "set -uo pipefail\nprintf '%s' \"$x\" | grep -q y\n", True),
        ("combined flags, -qF", "set -euo pipefail\nif cmd | grep -qF \"$m\"; then :; fi\n", True),
        ("-Eq after another option", "set -o pipefail\ncmd | grep -i -Eq 'a|b' || exit 1\n", True),
        ("inside $( )", "set -o pipefail\nr=$(cmd | grep -q x && echo y)\n", True),
        ("--quiet", "set -o pipefail\ncmd | grep --quiet x\n", True),
        ("the fixed form", "set -o pipefail\ncmd | grep x >/dev/null\n", False),
        ("no pipefail in the file", "set -eu\ncmd | grep -q x\n", False),
        ("grep -q reading a file", "set -o pipefail\ngrep -q x file\n", False),
        ("after ||, not a pipe", "set -o pipefail\ntrue || grep -q x file\n", False),
        ("in a comment", "set -o pipefail\n# never cmd | grep -q x\n", False),
        ("inside a quoted string", "set -o pipefail\ncheck \"name\" \"cmd | grep -q x\"\n", False),
        ("an option argument after --", "set -o pipefail\ncmd | grep -- -q\n", False),
    ]
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        for i, (name, body, want) in enumerate(cases):
            p = os.path.join(d, f"case{i}.sh")
            with open(p, "w") as f:
                f.write("#!/usr/bin/env bash\n" + body)
            got = bool(scan([p]))
            ok = got == want
            bad += not ok
            print(f"selftest {'ok  ' if ok else 'FAIL'}  {name}: {'flagged' if got else 'clean'}")
        p = os.path.join(d, "noext")
        with open(p, "w") as f:
            f.write("#!/bin/sh\nset -o pipefail\nx | grep -q y\n")
        got = bool(scan([p]))
        bad += not got
        print(f"selftest {'ok  ' if got else 'FAIL'}  an extensionless script found by its shebang: {'flagged' if got else 'clean'}")
    print("selftest ok    every case" if not bad else f"selftest FAILED: {bad} case(s)")
    return 1 if bad else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
        paths = [os.path.join(dp, f) for dp, _, fs in os.walk(root) for f in fs]
    else:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        paths = tracked(root)
        if paths is None:
            # Exit 2, the repository's SKIPPED. Until this, an unpacked archive got a Python traceback and exit 1,
            # which reads as a defect in the tree. The scan set is what git tracks, so there is nothing to judge.
            print(f"check-pipe-grep-q: SKIPPED: {root} is not a git checkout, and the scan set is what git tracks "
                  "(clone the repository, or pass --root DIR to scan a directory)")
            return 2
    found = scan(paths)
    for f in found:
        print("FAIL " + os.path.relpath(f.split(":", 1)[0], root) + ":" + f.split(":", 1)[1])
    if found:
        print(f"check-pipe-grep-q: {len(found)} pipe(s) into an early-exiting grep under pipefail. "
              "Write `cmd | grep PATTERN >/dev/null` instead (see this file's header).")
        return 1
    print(f"check-pipe-grep-q: ok, no pipe into grep -q under pipefail "
          f"({sum(1 for p in paths if os.path.isfile(p) and is_shell(p))} shell scripts read)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

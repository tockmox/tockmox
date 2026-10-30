#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""No GNU-only alternation in a basic grep pattern.

`grep 'a\\|b'` means "a or b" to GNU grep and the literal three characters `a|b` to the BSD grep a Mac ships.
The command does not fail on a Mac. It matches less, or nothing, and every caller reads that as an answer:

  - `grep -q 'x\\|y' <<<"$out" && bad ...` in a gate stays green on a Mac whatever the render holds, because the
    pattern can never match there. A check that cannot go red.
  - `kubectl ... | grep -v 'kube-\\|default'` in a page lists everything, kube-system included, under a heading
    that says "anything listed is yours".
  - `... | grep -i 'svclb\\|metallb'` in a page prints nothing on a Mac, which the page reads as "no controller".

Written as `grep -E 'a|b'`, the same pattern means the same thing to both. This gate refuses the basic form in
every tracked shell script and in every bash block of the documentation. It does not read charts/ (their
scripts run in Linux images) or .github/ (Linux runners).

Exit 0 clean, 1 findings, 2 cannot run (not a git checkout: the scan set is what git tracks).
  --selftest   it goes red on each shape above and stays green on the -E forms
  --files F..  scan exactly these files (the selftest uses this)
"""
import os
import re
import subprocess
import sys
import tempfile

SHELL_EXT = (".sh", ".bash")
FENCE_OPEN = re.compile(r"^\s*```\s*(bash|sh|shell|zsh|console)\b")
FENCE_CLOSE = re.compile(r"^\s*```\s*$")
# A grep word, its option words, an optional --, then a quoted pattern.
GREP = re.compile(r"(?<![\w-])grep((?:\s+-[-A-Za-z0-9]+)*)\s+(?:--\s+)?(['\"])(.*?)\2")
EXTENDED = re.compile(r"(?:^|\s)-[A-Za-z0-9]*[EP][A-Za-z0-9]*(?=\s|$)|--extended-regexp|--perl-regexp")


def findings_in_line(line):
    out = []
    for m in GREP.finditer(line):
        flags, pat = m.group(1), m.group(3)
        if "\\|" in pat and not EXTENDED.search(flags):
            out.append(m.group(0))
    return out


def scan_file(path, rel):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except (OSError, UnicodeDecodeError):
        return []
    found = []
    is_md = rel.endswith(".md")
    in_fence = False
    for n, line in enumerate(lines, 1):
        if is_md:
            if not in_fence:
                in_fence = bool(FENCE_OPEN.match(line))
                continue
            if FENCE_CLOSE.match(line):
                in_fence = False
                continue
        if not is_md and line.lstrip().startswith("#"):
            continue  # a comment may quote the bad form to explain it; only a command can run it
        for hit in findings_in_line(line):
            found.append("%s:%d: %s" % (rel, n, hit))
    return found


def tracked(root):
    try:
        out = subprocess.run(["git", "--no-optional-locks", "-C", root, "ls-files", "-z"],
                             capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    files = [p for p in out.decode("utf-8", "replace").split("\0") if p]
    return [p for p in files
            if (p.endswith(SHELL_EXT) or p.endswith(".md"))
            and not p.startswith("charts/") and not p.startswith(".github/")]


def run(root, files):
    found = []
    for rel in files:
        found.extend(scan_file(os.path.join(root, rel), rel))
    if found:
        print("check-grep-portability: a basic grep pattern uses \\| (GNU-only; BSD grep reads it literally).")
        print("  Write it as grep -E 'a|b'. Found:")
        for f in found:
            print("  " + f)
        return 1
    print("check-grep-portability: ok, no GNU-only alternation in a basic grep pattern (%d files read)" % len(files))
    return 0


def selftest():
    red = {
        "gate.sh": "grep -q 'tockmox_gate\\|tockmox_policy' <<<\"$out\" && bad x\n",
        "dq.sh": 'grep -q "class_forbids\\|may not use" "$f"\n',
        "esc.sh": "check x bash -c \"! grep -q 'a.yaml\\\\|b.yaml' '$W/calls'\"\n",
        "opt.sh": "grep -o -- '--version 2.20.0\\|image.tag=0.40.0' calls.log\n",
        "page.md": "Intro.\n\n```bash\nkubectl get ns -o name | grep -v 'kube-\\|default'\n```\n",
    }
    green = {
        "fixed.sh": "grep -E -q 'tockmox_gate|tockmox_policy' <<<\"$out\"\ngrep -Eq 'a|b' f\ngrep -iE 'x|y' f\n",
        "perl.sh": "grep -P 'a\\|b' f\n",
        "prose.md": "The old `grep -vc '^#\\|^$'` form, in prose.\n\n```yaml\nx: grep 'a\\|b'\n```\n",
        "word.sh": "echo 'egrep-like: my-grep \\| thing'\n",
        "comment.sh": "# BSD grep reads grep -q 'a\\|b' as the literal text a|b\n",
    }
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        for name, text in list(red.items()) + list(green.items()):
            with open(os.path.join(d, name), "w", encoding="utf-8") as f:
                f.write(text)
        for name in red:
            if scan_file(os.path.join(d, name), name):
                print("  ok    red on %s" % name)
            else:
                print("  FAIL  %s was not refused" % name)
                fails = 1
        for name in green:
            got = scan_file(os.path.join(d, name), name)
            if got:
                print("  FAIL  %s was refused: %s" % (name, got))
                fails = 1
            else:
                print("  ok    green on %s" % name)
    print("check-grep-portability selftest: %s" % ("ok" if not fails else "FAILED"))
    return fails


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if argv[1:2] == ["--selftest"]:
        return selftest()
    if argv[1:2] == ["--files"]:
        return run(os.getcwd(), argv[2:])
    files = tracked(root)
    if files is None:
        print("check-grep-portability: SKIPPED: %s is not a git checkout, and the scan set is what git tracks" % root)
        return 2
    return run(root, files)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

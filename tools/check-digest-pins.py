#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""One image, one digest, in every place it is spelled.

    python3 tools/check-digest-pins.py [--tree DIR]   the gate (default: this repository)
    python3 tools/check-digest-pins.py --selftest     prove each failure goes red, and the revert green

WHY. Some images are named in more than one place: a values `image:` key, the template `default`
a render falls back to when that key is empty, a string built through tpl, the installer's
MOVE_IMAGE_DEFAULT, and images.txt, which tools/gen-images.sh writes from the renders and from that
installer line. When a digest reaches some of those spellings and not the others, the cluster pulls
by tag on whichever path a render takes, and the air-gap list says one thing while a pod runs
another. gen-images.sh --check cannot see it: an empty-key fallback that is never rendered in CI
never reaches images.txt.

WHAT IT ASSERTS. For each image in PINNED, every spelling `REPO:...` in a text file under charts/ or
install/, and in images.txt:
  1. carries a tag and `@sha256:` with 64 lowercase hex digits;
  2. is the same tag@digest as every other spelling.
And at least one spelling exists, so a renamed image cannot leave the gate checking nothing.
Vendored subchart archives (charts/*/charts/) are not read. tests/, tools/ and docs/ are not read:
their spellings are fixtures and examples, not what an install pulls.

Exit 0 every spelling agrees; 1 a spelling disagrees, lacks a digest, or none is found; 2 bad input.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

# The images whose every spelling must carry one digest. Add an image here when its pin is spelled
# outside a single values key; tools/gen-sbom.sh and tools/gen-images.sh --check cover the rest.
PINNED = ("alpine/k8s",)

ROOTS = ("charts", "install")
FILES = ("images.txt",)
SKIP_DIRS = {".git", "build"}
DIGEST = re.compile(r"^(?P<tag>[A-Za-z0-9_][A-Za-z0-9._-]*)@sha256:[0-9a-f]{64}$")


def spelling_re(repo):
    # The repository, not preceded by a character that would make it part of a longer name, then a
    # colon and everything up to a quote, whitespace, a bracket or a comma.
    return re.compile(r"(?<![A-Za-z0-9._-])" + re.escape(repo) + r":[^\s\"'`)}\]>,]+")


def text_files(tree):
    for root in ROOTS:
        top = os.path.join(tree, root)
        if not os.path.isdir(top):
            continue
        for d, dirs, files in os.walk(top):
            rel_d = os.path.relpath(d, tree)
            parts = rel_d.split(os.sep)
            # charts/<layer>/charts/ holds vendored subchart archives, not ours.
            if len(parts) >= 3 and parts[0] == "charts" and parts[2] == "charts":
                dirs[:] = []
                continue
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
            for f in sorted(files):
                if f.endswith((".tgz", ".tar", ".gz", ".png", ".svg", ".ico")):
                    continue
                yield os.path.join(rel_d, f)
    for f in FILES:
        if os.path.isfile(os.path.join(tree, f)):
            yield f


def scan(tree):
    found = {repo: [] for repo in PINNED}
    pats = {repo: spelling_re(repo) for repo in PINNED}
    for rel in text_files(tree):
        try:
            with open(os.path.join(tree, rel), encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(lines, 1):
            for repo, pat in pats.items():
                for m in pat.finditer(line):
                    found[repo].append((rel, n, m.group(0)))
    return found


def check(tree):
    if not os.path.isfile(os.path.join(tree, "images.txt")):
        print("check-digest-pins: cannot read %s/images.txt" % tree, file=sys.stderr)
        return 2
    rc = 0
    for repo, spellings in scan(tree).items():
        if not spellings:
            print("FAIL %s: no spelling under %s or in %s; the image was renamed or the scan is broken"
                  % (repo, ", ".join(r + "/" for r in ROOTS), ", ".join(FILES)))
            rc = 1
            continue
        refs = {}
        for rel, n, ref in spellings:
            refs.setdefault(ref, []).append("%s:%d" % (rel, n))
        bad = [ref for ref in refs if not DIGEST.match(ref[len(repo) + 1:])]
        for ref in sorted(bad):
            for site in refs[ref]:
                print("NO DIGEST %s: %s" % (site, ref))
        if len(refs) > 1:
            print("FAIL %s is spelled %d ways; every spelling must carry the same tag@sha256:" % (repo, len(refs)))
            for ref in sorted(refs, key=lambda r: (-len(refs[r]), r)):
                print("  %s (%d): %s" % (ref, len(refs[ref]), ", ".join(refs[ref])))
            rc = 1
        elif bad:
            print("FAIL %s: %d spelling(s), none with a digest" % (repo, len(spellings)))
            rc = 1
        else:
            print("ok   %s: %d spelling(s), one reference %s" % (repo, len(spellings), next(iter(refs))))
    if rc:
        print("check-digest-pins: give every spelling the one tag@sha256: (read the digest from the registry "
              "index, e.g. `crane digest REPO:TAG`), then regenerate images.txt and sbom.cdx.json", file=sys.stderr)
    return rc


# ---- selftest: a fixture tree in each of the shapes the real tree spells the image ----
D1 = "sha256:" + "a1" * 32
D2 = "sha256:" + "b2" * 32
REPO = PINNED[0]


def fixture(t, ref):
    def w(rel, text):
        p = os.path.join(t, rel)
        os.makedirs(os.path.dirname(p) or t, exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)
    w("charts/layer-a/values.yaml", "job:\n  image: %s\nhook:\n  image: ''\n" % ref)
    w("charts/layer-a/templates/job.yaml",
      '          image: {{ include "x.image" (dict "repo" (.Values.hook.image | default "%s")) }}\n' % ref)
    w("charts/layer-b/values.yaml",
      "  wait:\n    image: '{{ with .Values.global.imageRegistry }}{{ . }}/{{ end }}%s'\n" % ref)
    w("install/bootstrap.sh", '#!/usr/bin/env bash\nMOVE_DEFAULT="%s"\n' % ref)
    w("images.txt", "# fixture\n%s\nother/image:1.0\n" % ref)
    # Not read: a vendored archive directory, and a fixture under tests/.
    w("charts/layer-a/charts/vendored/values.yaml", "image: %s:0.0.1\n" % REPO)
    w("tests/fixture.sh", "IMG=%s:0.0.1\n" % REPO)


def selftest():
    me = os.path.abspath(__file__)
    cases = fails = 0
    tmp = tempfile.mkdtemp(prefix="check-digest-pins-selftest.")
    try:
        def run(want, label, edit, *texts):
            nonlocal cases, fails
            cases += 1
            t = os.path.join(tmp, "t%d" % cases)
            fixture(t, "%s:1.37.2@%s" % (REPO, D1))
            edit(t)
            p = subprocess.run([sys.executable, me, "--tree", t], capture_output=True, text=True)
            out = p.stdout + p.stderr
            if p.returncode == want and all(x in out for x in texts):
                print("ok    %s (exit %d)" % (label, p.returncode))
            else:
                fails += 1
                print("FAIL  %s: wanted exit %d and %r, got exit %d:" % (label, want, texts, p.returncode))
                print("\n".join("        " + ln for ln in out.splitlines()))

        def sub(rel, old, new):
            def edit(t):
                p = os.path.join(t, rel)
                with open(p, encoding="utf-8") as fh:
                    s = fh.read()
                assert s.count(old) >= 1, (rel, old)
                with open(p, "w", encoding="utf-8") as fh:
                    fh.write(s.replace(old, new))
            return edit

        def none(t):
            pass

        def everywhere(old, new):
            def edit(t):
                for rel in ("charts/layer-a/values.yaml", "charts/layer-a/templates/job.yaml",
                            "charts/layer-b/values.yaml", "install/bootstrap.sh", "images.txt"):
                    sub(rel, old, new)(t)
            return edit

        def drop_images(t):
            os.remove(os.path.join(t, "images.txt"))

        def rename(t):
            everywhere(REPO + ":", "alpine/k9s:")(t)

        run(0, "every spelling carries one digest (values, template default, tpl string, installer, images.txt)",
            none, "ok   %s: 5 spelling(s)" % REPO)
        run(1, "a template default left tag-only (the shape a values-only pin leaves behind)",
            sub("charts/layer-a/templates/job.yaml", "@" + D1, ""),
            "NO DIGEST charts/layer-a/templates/job.yaml:1: %s:1.37.2" % REPO, "spelled 2 ways")
        run(1, "the installer default at another digest",
            sub("install/bootstrap.sh", D1, D2), "spelled 2 ways", "install/bootstrap.sh:2")
        run(1, "the tpl string at another tag, same digest",
            sub("charts/layer-b/values.yaml", "1.37.2@", "1.37.1@"), "spelled 2 ways", "charts/layer-b/values.yaml:2")
        run(1, "images.txt tag-only while the charts carry the digest",
            sub("images.txt", "@" + D1, ""), "NO DIGEST images.txt:2")
        run(1, "a truncated digest",
            sub("charts/layer-a/values.yaml", D1, D1[:-1]), "NO DIGEST charts/layer-a/values.yaml:2")
        run(1, "a digest in upper case", sub("charts/layer-a/values.yaml", D1, D1.upper().replace("SHA256", "sha256")),
            "NO DIGEST charts/layer-a/values.yaml:2")
        run(1, "no spelling carries a digest (agreeing on a bare tag is not a pin)",
            everywhere("@" + D1, ""), "none with a digest")
        run(1, "the image renamed everywhere, so the gate would check nothing", rename, "no spelling under")
        run(2, "no images.txt", drop_images, "cannot read")
        run(0, "the vendored archive directory and tests/ are not read", none, "5 spelling(s)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("check-digest-pins selftest: %d cases, %d failed" % (cases, fails))
    return 0 if fails == 0 else 1


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if not argv:
        return check(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if len(argv) == 2 and argv[0] == "--tree":
        return check(argv[1])
    print("usage: check-digest-pins.py [--tree DIR] | --selftest", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

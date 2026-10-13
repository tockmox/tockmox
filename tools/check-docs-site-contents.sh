#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert that a BUILT documentation site holds only static web content.
# TM-0807, TM-0805, ADR-0036.
#
#   ./tools/check-docs-site-contents.sh              build the site, then check it
#   ./tools/check-docs-site-contents.sh --site DIR   check an already-built site
#   ./tools/check-docs-site-contents.sh --selftest [--site DIR]
#                                                    prove the gate goes red
#
# Exit 0 pass, 1 fail, 2 skipped (no --site and the pinned generator is absent,
# the same convention as check-docs-offline.sh), 64 usage.
#
# WHY. tools/publish-docs.sh copies a directory into a bucket that the cluster
# then serves anonymously, and the directory can come from `--site DIR` built on
# some other machine (the dark-site path). The operator trusts their own
# checkout, but a directory is not a checkout: it may have been unpacked from a
# tarball, built by a different toolchain, or written to by a person. Nothing in
# it should be a program. This runs on the directory before anything is
# uploaded, next to check-docs-offline.sh (which asks whether a page would fetch
# from the network; this asks whether the directory holds anything but pages).
#
# WHAT IT REFUSES, per file:
#   - an extension that is not on the static allowlist below (and any file with
#     no extension), so `.sh`, `.py`, `.exe`, `.so`, `.jar`, `.wasm`, `.zip`
#     and the like never pass
#   - a first few bytes that are an ELF, Mach-O (thin or fat) or PE/MZ
#     executable, or a `#!` line, WHATEVER the extension says, so a program
#     renamed to `logo.png` does not pass
#   - any execute bit (owner, group or other)
#   - a symbolic link, a FIFO, a device or a socket: only regular files and
#     directories are copied, and a link could point outside the directory
#   - an empty directory tree (nothing to publish is not a pass)
# The allowlist is the set of extensions the pinned MkDocs Material build
# actually emits (html css js json xml map svg png jpg gif webp ico woff woff2,
# plus `sitemap.xml.gz`), and a few more that a static site may carry (txt,
# webmanifest, ttf, otf, mjs).
#
# WHAT THIS DOES NOT PROVE. A .js file is allowed because the theme needs its
# scripts, and this does not read them: a malicious script in a page would be
# served to the operator's browser, and only the trust in the checkout (a signed
# tag) and check-docs-offline.sh's scan for external fetches stand against that.
# Magic bytes are checked at the start of a file only. The scan is of a
# directory at one moment; nothing stops it changing before upload.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=check; SITE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest ;;
    --site) SITE="${2:?--site needs a directory}"; shift ;;
    *) echo "usage: $0 [--site DIR] | --selftest [--site DIR]" >&2; exit 64 ;;
  esac
  shift
done
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: python3 not found" >&2; exit 2; }

if [ "$MODE" = check ] && [ -z "$SITE" ]; then
  SITE="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-docs-contents.XXXXXX")"
  trap 'rm -rf "$SITE" "$SITE.err"' EXIT
  rc=0
  bash tools/build-docs.sh "$SITE" >/dev/null 2>"$SITE.err" || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "SKIPPED: the pinned documentation generator is not installed:"
    sed 's/^/  /' "$SITE.err"
    exit 2
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL: the docs build itself failed (exit $rc):"; sed 's/^/  /' "$SITE.err"
    exit 1
  fi
fi

exec python3 - "$MODE" "$SITE" <<'PY'
import os, shutil, stat, sys, tempfile

MODE, SITE = sys.argv[1], sys.argv[2]

ALLOW = {".html", ".htm", ".css", ".js", ".mjs", ".json", ".xml", ".txt", ".map", ".svg",
         ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".woff", ".woff2", ".ttf", ".otf",
         ".webmanifest"}
ALLOW_NAMES = {"sitemap.xml.gz"}
MAGIC = [
    (b"\x7fELF", "ELF executable"),
    (b"MZ", "PE/DOS executable"),
    (b"#!", "script with a shebang"),
    (b"\xfe\xed\xfa\xce", "Mach-O executable"), (b"\xfe\xed\xfa\xcf", "Mach-O executable"),
    (b"\xce\xfa\xed\xfe", "Mach-O executable"), (b"\xcf\xfa\xed\xfe", "Mach-O executable"),
    (b"\xca\xfe\xba\xbe", "Mach-O fat binary or Java class"),
]


def scan(root):
    problems, files = [], 0
    if not os.path.isdir(root):
        return ["%s is not a directory" % root], 0
    for dp, dn, fn in os.walk(root):
        dn.sort()
        for d in dn:
            full = os.path.join(dp, d)
            if os.path.islink(full):
                problems.append("%s: symbolic link to a directory" % os.path.relpath(full, root))
        for f in sorted(fn):
            full = os.path.join(dp, f)
            rel = os.path.relpath(full, root)
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                problems.append("%s: symbolic link" % rel); continue
            if not stat.S_ISREG(st.st_mode):
                problems.append("%s: not a regular file (FIFO, device or socket)" % rel); continue
            files += 1
            ext = os.path.splitext(f)[1].lower()
            if f.lower() not in ALLOW_NAMES and ext not in ALLOW:
                problems.append("%s: extension %r is not on the static-content allowlist" % (rel, ext or "(none)"))
            if st.st_mode & 0o111:
                problems.append("%s: has an execute bit (mode %o)" % (rel, st.st_mode & 0o777))
            with open(full, "rb") as fh:
                head = fh.read(4)
            for sig, what in MAGIC:
                if head.startswith(sig):
                    problems.append("%s: starts like a %s, whatever its extension says" % (rel, what)); break
    if files == 0:
        problems.append("%s holds no files; an empty site must not pass" % root)
    return problems, files


def report(root, quiet=False):
    problems, files = scan(root)
    if not quiet:
        print("scanned %d file(s) under %s" % (files, root))
        for p in problems[:60]:
            print("  FAIL  " + p)
        if len(problems) > 60:
            print("  ... and %d more" % (len(problems) - 60))
        print("FAIL: %d problem(s)" % len(problems) if problems else
              "PASS: the site holds only static web content")
    return not problems


def write(path, data, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    if mode is not None:
        os.chmod(path, mode)


def fixture(root):
    write(os.path.join(root, "index.html"), b"<!doctype html><title>x</title>")
    write(os.path.join(root, "assets/a.css"), b"body{}")
    write(os.path.join(root, "assets/a.js"), b"var x=1;")
    write(os.path.join(root, "assets/i.png"), b"\x89PNG\r\n\x1a\n")
    write(os.path.join(root, "sitemap.xml.gz"), b"\x1f\x8b")


def selftest(real):
    bad = 0
    tmp = tempfile.mkdtemp(prefix="docs-contents-selftest.")
    try:
        base = os.path.join(tmp, "clean"); fixture(base)
        print("-- control: the clean fixture must pass")
        if not report(base, quiet=True):
            print("  SELFTEST FAIL: the clean fixture was rejected"); bad += 1
        else:
            print("  ok")
        cases = [
            ("ELF renamed to .png", lambda d: write(os.path.join(d, "assets/logo.png"), b"\x7fELF\x02\x01\x01")),
            ("PE renamed to .ico", lambda d: write(os.path.join(d, "assets/favicon.ico"), b"MZ\x90\x00")),
            ("Mach-O renamed to .woff2", lambda d: write(os.path.join(d, "assets/f.woff2"), b"\xcf\xfa\xed\xfe\x07")),
            ("shebang in .js", lambda d: write(os.path.join(d, "assets/run.js"), b"#!/bin/sh\necho hi\n")),
            ("shell script by extension", lambda d: write(os.path.join(d, "install.sh"), b"echo hi\n")),
            ("executable by extension", lambda d: write(os.path.join(d, "setup.exe"), b"not really\n")),
            ("shared object by extension", lambda d: write(os.path.join(d, "lib.so"), b"plain text\n")),
            ("file with no extension", lambda d: write(os.path.join(d, "README"), b"text\n")),
            ("execute bit on an html page", lambda d: os.chmod(os.path.join(d, "index.html"), 0o755)),
            ("group execute bit on a css file", lambda d: os.chmod(os.path.join(d, "assets/a.css"), 0o654)),
            ("symbolic link", lambda d: os.symlink("/etc/hostname", os.path.join(d, "hostname.txt"))),
            ("symbolic link to a directory", lambda d: os.symlink("/tmp", os.path.join(d, "tmp"))),
            ("FIFO", lambda d: os.mkfifo(os.path.join(d, "pipe.txt"))),
            ("wasm module", lambda d: write(os.path.join(d, "m.wasm"), b"\x00asm\x01\x00\x00\x00")),
            ("a gzip that is not the sitemap", lambda d: write(os.path.join(d, "payload.gz"), b"\x1f\x8b")),
        ]
        print("-- each injected file must turn the gate red")
        for i, (name, mut) in enumerate(cases):
            d = os.path.join(tmp, "m%d" % i); shutil.copytree(base, d, symlinks=True)
            mut(d)
            if report(d, quiet=True):
                print("  SELFTEST FAIL: %s stayed green" % name); bad += 1
            else:
                print("  red, as required: %s" % name)
        print("-- an empty directory, and a missing one, must not pass")
        e = os.path.join(tmp, "empty"); os.makedirs(e)
        if report(e, quiet=True) or report(os.path.join(tmp, "nope"), quiet=True):
            print("  SELFTEST FAIL: an empty or missing site passed"); bad += 1
        else:
            print("  red, as required")
        if real:
            print("-- the real site, plus an injected ELF in a copy")
            if not report(real, quiet=True):
                print("  NOTE: the real site is already red; run with --site to see why")
            d = os.path.join(tmp, "real"); shutil.copytree(real, d, symlinks=True)
            write(os.path.join(d, "assets/logo.png"), b"\x7fELF\x02\x01\x01")
            if report(d, quiet=True):
                print("  SELFTEST FAIL: the real site stayed green with an ELF injected"); bad += 1
            else:
                print("  red, as required")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST FAILED (%d)" % bad if bad else "SELFTEST PASSED")
    return bad == 0


if MODE == "selftest":
    sys.exit(0 if selftest(SITE or None) else 1)
sys.exit(0 if report(SITE) else 1)
PY

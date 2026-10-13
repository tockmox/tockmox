#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Supply-chain pins, asserted on the files themselves (TM-0592).
#
#   ./tools/check-action-pins.sh              run the assertions on this tree
#   ./tools/check-action-pins.sh --root DIR   run them on another tree
#   ./tools/check-action-pins.sh --selftest   prove they can go red
#
# P1  Every `uses:` in .github/workflows/*.y*ml is pinned to a full 40 hex
#     commit SHA and carries the tag as a trailing comment
#     (`uses: actions/checkout@<sha> # v4.4.0`), which is the form Renovate's
#     helpers:pinGitHubActionDigests keeps moving. A moving tag such as @v4 can
#     be repointed by whoever controls the action's repository. Local actions
#     (`uses: ./...`) are exempt.
# P2  Every download of a literal http(s) URL with curl or wget, in the
#     workflows, in tools/*.sh and in install/, is (a) written to a file rather
#     than piped into tar, sh, bash or sudo, and (b) followed, within 8 lines of
#     the same file, by a `sha256sum -c` / `shasum -a 256 -c` check. A download
#     that runs before it is verified is the failure this exists for. tools/
#     check-*.sh are not scanned: they hold curl strings as test fixtures.
# LIMIT: this proves a check is WRITTEN after each download, not that it compares
#     the right hash, and it does not see downloads made by an action's own code
#     (azure/setup-helm fetches helm itself) or by a package manager. The live
#     half is a mutated hash making the CI job fail; see TM-0592.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null 2>&1 || { echo "check-action-pins: python3 missing" >&2; exit 2; }
self="$(pwd)/tools/check-action-pins.sh"

scan() {
python3 - "$1" <<'PY'
import sys, re, glob, os
root = sys.argv[1]
bad = 0
def fail(m):
    global bad; print("FAIL " + m); bad += 1
# ---- P1
npin = 0
for f in sorted(glob.glob(root + "/.github/workflows/*.y*ml")):
    for i, line in enumerate(open(f), 1):
        m = re.match(r"^\s*(?:-\s*)?uses:\s*(\S+)(.*)$", line.rstrip("\n"))
        if not m: continue
        ref, rest = m.group(1), m.group(2)
        if ref.startswith("./"): continue
        where = "%s:%d" % (os.path.relpath(f, root), i)
        if not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", ref):
            fail("P1: %s uses %s, which is not pinned to a full 40 hex commit SHA. Resolve the tag to its commit (the peeled commit for an annotated tag) and write `uses: owner/repo@<sha> # <tag>`" % (where, ref))
        elif not re.match(r"^\s+#\s*v?\d", rest):
            fail("P1: %s pins %s but has no trailing `# <tag>` comment; without it Renovate and a reader cannot tell which release the SHA is" % (where, ref))
        else:
            npin += 1
# ---- P2
files = sorted(glob.glob(root + "/.github/workflows/*.y*ml")) + \
        [f for f in sorted(glob.glob(root + "/tools/*.sh")) if not os.path.basename(f).startswith("check-")] + \
        sorted(p for p in glob.glob(root + "/install/*") if os.path.isfile(p))
CHK = re.compile(r"sha256sum\s+(-c|--check)\b|shasum\s+-a\s+256\s+(-c|--check)\b")
ndl = 0
for f in files:
    lines = open(f, errors="replace").read().split("\n")
    i = 0
    while i < len(lines):
        raw = lines[i]
        if raw.lstrip().startswith("#") or not re.search(r"\b(curl|wget)\b", raw):
            i += 1; continue
        j = i; stmt = raw
        while stmt.rstrip().endswith("\\") and j + 1 < len(lines):
            j += 1; stmt += "\n" + lines[j]
        if re.search(r"https?://", stmt):
            ndl += 1
            where = "%s:%d" % (os.path.relpath(f, root), i + 1)
            if re.search(r"\|\s*(sudo\s+)?(tar|sh|bash|zsh|unzip)\b", stmt):
                fail("P2: %s pipes a download straight into a command, so nothing can check it first. Write it to a file, check its sha256, then unpack" % where)
            elif not any(CHK.search(l) for l in lines[j + 1:j + 9]):
                fail("P2: %s downloads a URL with no `sha256sum -c` in the next 8 lines" % where)
        i = j + 1
if not bad:
    print("  ok: %d uses: lines are SHA-pinned with a tag comment; %d downloads are written to a file and followed by a sha256 check" % (npin, ndl))
sys.exit(1 if bad else 0)
PY
}

if [ "${1:-}" = "--root" ]; then scan "${2:?--root needs a directory}"; exit $?; fi

if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  SHA=11d5960a326750d5838078e36cf38b85af677262
  mk() { rm -rf "$tmp/t"; mkdir -p "$tmp/t/.github/workflows" "$tmp/t/tools" "$tmp/t/install"; }
  wf() { printf '%s\n' "$1" > "$tmp/t/.github/workflows/w.yaml"; }
  expect() { # name, grep-pattern ('' = must pass)
    local out
    if out=$(bash "$self" --root "$tmp/t" 2>&1); then
      [ -z "$2" ] || { echo "selftest FAIL: $1 passed"; exit 1; }
    else
      [ -n "$2" ] || { echo "selftest FAIL: $1 failed: $out"; exit 1; }
      printf '%s' "$out" | grep -q -- "$2" || { echo "selftest FAIL: $1: wrong message: $out"; exit 1; }
    fi
    echo "selftest ok: $1"
  }
  GOOD='steps:
  - uses: actions/checkout@'$SHA' # v4.4.0
  - run: |
      curl -fsSL -o t.tar.gz "https://example.com/t.tar.gz"
      echo "abc  t.tar.gz" | sha256sum -c -
      tar -xzf t.tar.gz'
  mk; wf "$GOOD";                                                          expect "a pinned action and a verified download pass" ""
  mk; wf "${GOOD//actions\/checkout@$SHA # v4.4.0/actions/checkout@v4}";   expect "a moving tag (@v4) is refused" "FAIL P1: .*not pinned"
  mk; wf "${GOOD//$SHA/${SHA:0:12}}";                                      expect "an abbreviated SHA is refused" "FAIL P1: .*not pinned"
  mk; wf "${GOOD// # v4.4.0/}";                                            expect "a SHA with no tag comment is refused" "FAIL P1: .*no trailing"
  mk; wf "${GOOD//echo \"abc  t.tar.gz\" | sha256sum -c -/true}";          expect "a download with no checksum is refused" "FAIL P2: .*no .sha256sum -c"
  mk; wf '  - run: curl -fsSL "https://example.com/t.tar.gz" | tar -xz';      expect "curl piped into tar is refused" "FAIL P2: .*pipes a download"
  mk; wf "$GOOD"; printf 'wget https://example.com/x\n' > "$tmp/t/tools/get.sh"; expect "an unverified download in tools/ is refused" "FAIL P2: tools/get.sh"
  mk; wf "$GOOD"; printf '# curl -fsSL https://example.com/x | sh\n' > "$tmp/t/tools/get.sh"; expect "a commented-out curl is ignored" ""
  mk; wf "$GOOD"; printf 'curl -fsS "$WEB/marker"\n' > "$tmp/t/tools/probe.sh"; expect "a curl of a variable URL (not a download) is ignored" ""
  mk; wf "  - uses: ./local-action";                                       expect "a local action is exempt" ""
  echo "check-action-pins selftest: ok"
  exit 0
fi

echo "check-action-pins:"
scan "$(pwd)"

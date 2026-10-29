#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# No known-bad LiteLLM image digest, and no LiteLLM image at the compromised tag, appears anywhere a LiteLLM image
# can be named (TM-1197).
#
#   ./tools/check-litellm-compromise.sh              scan this tree
#   ./tools/check-litellm-compromise.sh --root DIR   scan another tree (the selftest's fixtures)
#   ./tools/check-litellm-compromise.sh --selftest   prove it can go red, and say what it cannot see
#
# WHY. LiteLLM's release pipeline was hijacked on 2026-10-21 and v1.107.0 shipped a credential stealer
# (tools/litellm-bad-digests.txt cites the vendor post and the issue). The vendor pulled the release and
# has not re-cut it. Two guards were ruled for 0.9.0: a three-day minimumReleaseAge on LiteLLM in
# renovate.json5, and this gate, which fails when a known-bad digest is named in the tree.
#
# WHAT IT KEYS ON. DIGESTS FIRST (maintainer ruling 2026-10-28), AND THE EXACT TAG (ruling 2026-10-29). The bad
# artifacts are listed in tools/litellm-bad-digests.txt, one per line. A digest entry is 12 to 64 hex; a digest
# found in the tree matches an entry when either is a prefix of the other. Short entries exist because the image
# the product ships, ghcr.io/berriai/litellm-database, has no full bad digest in any public source, only
# "sha256:c00f9d92c427...". A tag entry ("tag:<repository>:<tag>") matches that repository at exactly that tag,
# as an image reference ("<repository>:<tag>", with or without "@sha256:...") or as an SBOM purl
# ("repository_url=<repository>&tag=<tag>"); "1.107.0-rc.2" and "1.107.1" do not match "1.107.0". The tag
# lines exist because images.txt pins LiteLLM by tag only, so a Renovate bump to the bad version names no digest.
# 1.107.0 was pulled, not re-cut; if the vendor ever re-cuts a clean release under that number, taking it is a
# deliberate act: delete its tag lines.
#
# WHAT IT SCANS. Every text file in the tree except the prose that is allowed to quote an incident:
# docs/, docs-site/, CHANGELOG.md, this script and the digest list. That reaches images.txt (the rendered
# image list the airgap mirror and the SBOM are made from), sbom.cdx.json, every chart's values and templates,
# ci/, examples/, install/ and tools/. A LiteLLM image can be named in images.txt, in a values file
# (litellm.image.tag may carry "1.106.6@sha256:..."), in a template, or in a site's own values; the first
# three are in the tree and scanned, the last is not (see below).
#
# WHAT IT CANNOT SEE, stated rather than left to be found:
#   - A tag it does not list. A bad release under a new number needs its own tag lines; until then the three-day
#     soak in renovate.json5 is what covers the tag path.
#   - A tag written apart from its repository (a values file's "tag: 1.107.0" under "repository: ..."). Such a
#     value reaches images.txt through gen-images.sh, which is where this gate sees it.
#   - A site repository's own pin (tockmox-site-homelab restates the image in site/values/ai.yaml). The product
#     gate covers it at release pickup only if the site names a digest; the site's render CI would need the same
#     check to cover it sooner.
#   - A digest inside a vendored subchart tarball (charts/*/charts/*.tgz) other than through images.txt, which is
#     the render of ci/values.yaml and is checked against the charts by gen-images.sh --check.
#   - A digest this list does not know. It stops what was published; a new compromise needs a new line.
#
# Exit 0 clean, 1 a known-bad digest or a list that cannot be trusted. Needs python3 only. Bash 3.2 compatible.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null 2>&1 || { echo "check-litellm-compromise: python3 missing" >&2; exit 2; }
self="$(pwd)/tools/check-litellm-compromise.sh"

scan() { # scan <root>
python3 -I - "$1" <<'PY'
import os, re, sys
root = os.path.abspath(sys.argv[1])
LIST = os.path.join("tools", "litellm-bad-digests.txt")
bad = 0
def fail(m):
    global bad; print("FAIL " + m); bad += 1

# ---- the list: refuse one that is missing, empty or does not parse (a list that cannot match is decoration)
entries = []   # (hex, label, lineno)
tags = []      # (repository, tag, label, lineno)
try:
    raw = open(os.path.join(root, LIST), encoding="utf-8").read().split("\n")
except OSError:
    raw = None
if raw is None:
    fail("%s is missing, so there is nothing to compare the tree against" % LIST)
else:
    for n, line in enumerate(raw, 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        t = re.fullmatch(r"tag:([a-z0-9][a-z0-9./_-]*/[a-z0-9._-]+):([A-Za-z0-9_][A-Za-z0-9._-]{0,127})(?:\s+(\S.*))?", s)
        if t:
            tags.append((t.group(1), t.group(2), (t.group(3) or "").strip(), n))
            continue
        m = re.fullmatch(r"sha256:([0-9a-f]{12,64})(?:\s+(\S.*))?", s)
        if not m:
            fail("%s:%d is not 'sha256:<12 to 64 lowercase hex> <label>' or 'tag:<repository>:<tag> <label>': %r" % (LIST, n, s[:80]))
            continue
        entries.append((m.group(1), (m.group(2) or "").strip(), n))
    if not entries and not tags and not bad:
        fail("%s holds no entries, so the gate would pass on anything" % LIST)

# ---- tag patterns: <repository>:<tag> as a whole reference (the tag may carry @sha256:...; a registry or mirror
#      prefix ending in "/" before the repository still matches), or an SBOM purl
TAGRE = []
for repo, tag, label, en in tags:
    r = re.escape(repo).encode(); g = re.escape(tag).encode()
    pat = rb"(?<![A-Za-z0-9._-])" + r + rb":" + g + rb"(?![A-Za-z0-9._-])|repository_url=" + r + rb"&tag=" + g + rb"(?![A-Za-z0-9._-])"
    TAGRE.append((re.compile(pat), repo, tag, label, en))

# ---- the corpus
PRUNE = {".git", "build", "node_modules", "docs", "docs-site"}
SKIP_FILES = {os.path.normpath("CHANGELOG.md"), os.path.normpath(LIST),
              os.path.normpath("tools/check-litellm-compromise.sh")}
if not os.path.isfile(os.path.join(root, "images.txt")):
    fail("images.txt is missing from %s: it is the list this gate exists to read" % root)
DIG = re.compile(rb"sha256:([0-9a-fA-F]{12,64})(?![0-9a-fA-F])")
nfiles = ndig = 0
hits = 0
for d, dirs, files in os.walk(root):
    rel_d = os.path.relpath(d, root)
    # docs/ and docs-site/ are pruned at the top level only; a chart's own docs/ folder is scanned
    dirs[:] = sorted(x for x in dirs if not (x in (".git", "build", "node_modules") or (rel_d == "." and x in PRUNE)))
    for f in sorted(files):
        p = os.path.join(d, f)
        rel = os.path.relpath(p, root)
        if os.path.normpath(rel) in SKIP_FILES or f.endswith((".tgz", ".gz", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2", ".pdf", ".zip")):
            continue
        try:
            data = open(p, "rb").read()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        nfiles += 1
        for ln, line in enumerate(data.split(b"\n"), 1):
            for rx, repo, tag, label, en in TAGRE:
                if rx.search(line):
                    hits += 1
                    fail("%s:%d names %s at tag %s, a known-bad LiteLLM release (%s:%d: %s). "
                         "Do not take it: keep the last good version pinned." % (rel, ln, repo, tag, LIST, en, label or "no label"))
            for m in DIG.finditer(line):
                ndig += 1
                h = m.group(1).decode().lower()
                for e, label, en in entries:
                    if h.startswith(e) or e.startswith(h):
                        hits += 1
                        fail("%s:%d names sha256:%s, a known-bad LiteLLM digest (%s:%d: %s). "
                             "Do not take it: keep the last good version pinned. The incident is cited at the top of the list."
                             % (rel, ln, h, LIST, en, label or "no label"))
                        break
if not bad:
    print("  ok: %d text files read, %d sha256 references compared against %d known-bad digests, and %d known-bad tags looked for, none matched" % (nfiles, ndig, len(entries), len(tags)))
sys.exit(1 if bad else 0)
PY
}

if [ "${1:-}" = "--root" ]; then scan "${2:?--root needs a directory}"; exit $?; fi

if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  F="$tmp/t"
  # Fixture digests: the real list's entries, plus invented neighbours that must NOT match.
  FULL=1bbcb1443bc962e45f5aad53fe3d2c30600e0379715fb6c664cdd3ac126c339e
  AMD=bd1aeee419ea36da9aa2b657288da4101887be468f020ac63d22ba6ed84a3ea5
  ARM=56b74573eed6e4aafe4b50603dbe7853e0345f188c8e44a09f1098caf1f4bcdf
  REST=0123456789abcdef0123456789abcdef0123456789abcdef0123  # 52 hex: 12 + 52 = 64
  GOOD=a1897c67478bc23434534e91ad3855280771196b1daf17144db9dbcb655bef71
  mk() {
    rm -rf "$F"; mkdir -p "$F/tools" "$F/charts/tockmox-ai" "$F/docs" "$F/ci"
    cp tools/litellm-bad-digests.txt "$F/tools/litellm-bad-digests.txt"
    printf '%s\n' "# Container images referenced by Tockmox charts." \
      "ghcr.io/berriai/litellm-database:1.106.6" \
      "quay.io/prometheus-operator/prometheus-config-reloader:v0.94.2@sha256:$GOOD" > "$F/images.txt"
    printf '%s\n' "litellm:" "  image:" "    tag: \"\"" > "$F/charts/tockmox-ai/values.yaml"
  }
  img() { printf '%s\n' "$1" >> "$F/images.txt"; }
  expect() { # name, grep-pattern ('' = must pass)
    local out
    if out=$(bash "$self" --root "$F" 2>&1); then
      [ -z "$2" ] || { echo "selftest FAIL: $1 passed"; exit 1; }
    else
      [ -n "$2" ] || { echo "selftest FAIL: $1 failed: $out"; exit 1; }
      printf '%s' "$out" | grep -- "$2" >/dev/null || { echo "selftest FAIL: $1: wrong message: $out"; exit 1; }
    fi
    echo "selftest ok: $1"
  }
  mk;                                                                                  expect "a clean tree passes" ""
  mk; img "docker.io/litellm/litellm:main-latest@sha256:$FULL";                        expect "the compromised index digest in images.txt is refused" "FAIL images.txt:.*known-bad"
  mk; img "ghcr.io/berriai/litellm-database:1.106.6@sha256:c00f9d92c427$REST";         expect "a litellm-database ref with the published 12-hex prefix is refused" "FAIL images.txt:.*image index"
  mk; img "ghcr.io/berriai/litellm-non_root:1.106.6@sha256:7b00e91cd2fe$REST";         expect "a litellm-non_root ref with its published prefix is refused" "FAIL images.txt:.*non_root"
  mk; img "ghcr.io/berriai/litellm:v1.107.0@sha256:$AMD";                              expect "the amd64 platform manifest is refused" "FAIL images.txt:.*amd64"
  mk; img "ghcr.io/berriai/litellm:v1.107.0@sha256:$ARM";                              expect "the arm64 platform manifest is refused" "FAIL images.txt:.*arm64"
  mk; img "ghcr.io/berriai/litellm:main@sha256:${FULL:0:12}";                          expect "a vendor-style truncated copy of a full entry is refused" "FAIL images.txt:"
  mk; img "ghcr.io/berriai/litellm-database:1.106.6@sha256:$(printf '%s' "C00F9D92C427$REST" | tr 'a-f' 'A-F')"
                                                                                       expect "upper-case hex is refused" "FAIL images.txt:"
  mk; printf '    tag: "1.106.6@sha256:c00f9d92c427%s"\n' "$REST" >> "$F/charts/tockmox-ai/values.yaml"
                                                                                       expect "a digest in a chart values file is refused" "FAIL charts/tockmox-ai/values.yaml:"
  mk; printf '      "purl": "pkg:oci/litellm@sha256:%s"\n' "$FULL" > "$F/sbom.cdx.json"; expect "a digest in the SBOM is refused" "FAIL sbom.cdx.json:"
  mk; img "ghcr.io/berriai/litellm-database:1.106.6@sha256:c00f9d92c428$REST";         expect "a neighbour that differs in the 12th hex digit passes" ""
  mk; img "ghcr.io/berriai/litellm-database:1.106.6@sha256:c00f9d92c42";               expect "11 hex is not a digest reference and passes" ""
  mk; img "ghcr.io/berriai/litellm-database:1.106.6@sha256:$GOOD";                     expect "an unrelated digest on a LiteLLM image passes" ""
  mk; printf 'The bad index is sha256:%s\n' "$FULL" > "$F/docs/incident.md"
      printf 'The bad index is sha256:%s\n' "$FULL" > "$F/CHANGELOG.md";               expect "the incident quoted in docs/ and CHANGELOG.md passes" ""
  mk; printf 'x: sha256:%s\n' "$FULL" > "$F/ci/values.yaml";                           expect "the same digest in ci/ is refused" "FAIL ci/values.yaml:"
  mk; img "ghcr.io/berriai/litellm-database:v1.107.0";                                 expect "the bad tag with a v is refused" "FAIL images.txt:.*at tag v1.107.0"
  mk; img "ghcr.io/berriai/litellm-database:1.107.0";                                  expect "the bad tag without a v (our pin's form) is refused" "FAIL images.txt:.*at tag 1.107.0"
  mk; img "ghcr.io/berriai/litellm-non_root:1.107.0@sha256:$GOOD";                     expect "the bad tag carrying an unrelated digest is still refused" "FAIL images.txt:.*non_root at tag 1.107.0"
  mk; img "docker.io/litellm/litellm:v1.107.0";                                        expect "the Docker Hub name at the bad tag is refused" "FAIL images.txt:.*litellm/litellm at tag"
  mk; printf '      "purl": "pkg:oci/litellm-database?repository_url=ghcr.io/berriai/litellm-database&tag=1.107.0",\n' > "$F/sbom.cdx.json"
                                                                                       expect "the bad tag as an SBOM purl is refused" "FAIL sbom.cdx.json:.*at tag 1.107.0"
  mk; img "ghcr.io/berriai/litellm-database:1.107.0-rc.2";                             expect "a pre-release of the same number passes" ""
  mk; img "ghcr.io/berriai/litellm-database:1.107.1";                                  expect "the next patch passes" ""
  mk; img "ghcr.io/berriai/litellm-database:1.107.01";                                 expect "a longer number that starts the same passes" ""
  mk; img "example.com/mirror/ghcr.io/berriai/litellm-database-fork:1.107.0";          expect "another repository whose name starts the same passes" ""
  mk; img "registry.example/proxy/ghcr.io/berriai/litellm-database:1.107.0";           expect "a mirror-prefixed reference at the bad tag is refused" "FAIL images.txt:.*at tag 1.107.0"
  mk; img "litellm/litellm:v1.107.0";                                                  expect "the bare Docker Hub short name at the bad tag is refused" "FAIL images.txt:.*litellm/litellm at tag"
  mk; printf 'tag:ghcr.io/berriai/litellm-database\n' >> "$F/tools/litellm-bad-digests.txt"; expect "a tag line with no tag is refused" "FAIL tools/litellm-bad-digests.txt:.*not 'sha256"
  mk; printf 'sha256:c00f9d92c42  too short\n' >> "$F/tools/litellm-bad-digests.txt";  expect "a list line that does not parse is refused" "FAIL tools/litellm-bad-digests.txt:.*not 'sha256"
  mk; : > "$F/tools/litellm-bad-digests.txt";                                          expect "an empty list is refused" "holds no entries"
  mk; rm "$F/tools/litellm-bad-digests.txt";                                           expect "a missing list is refused" "is missing"
  mk; rm "$F/images.txt";                                                              expect "a missing images.txt is refused" "images.txt is missing"
  echo "check-litellm-compromise selftest: ok"
  exit 0
fi

echo "check-litellm-compromise:"
scan "$(pwd)"

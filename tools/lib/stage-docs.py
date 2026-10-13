# SPDX-License-Identifier: Apache-2.0
#
# Stage the audience-filtered documentation tree that tools/build-docs.sh hands to
# MkDocs. Not run directly; see that script for the why.
#
#   stage-docs.py --root REPO --stage DIR --ref GITREF --upstream URL [--list]
#
# WHAT IT DECIDES, AND WHY HERE. The site is the OPERATOR's manual, so a page is
# in iff its frontmatter `tockmox.audience` names an operator-facing audience.
# The frontmatter is PARSED (PyYAML, which MkDocs already brings), not grepped:
# a loose grep for "operator" matches prose, the `audience:` line of another
# page's example block, and a comment. Filtering on directories was the card's
# v1 proxy and is wrong now: docs/architecture.md, docs/why-tockmox.md and
# docs/third-party-licenses.md are operator pages that live at the top level,
# and docs/usage/working-with-an-agent.md sits beside material for other readers.
#
#   INCLUDED audiences: operator, end-user, admin. (The contract in
#     docs/frontmatter-contract.md defines operator, contributor, machine; the
#     other two are accepted so the filter needs no edit the day the vocabulary
#     grows.) ANY included audience puts the page in, so [operator, contributor]
#     is in and [machine, operator] is in.
#   EXCLUDED audiences: contributor, maintainer, internal, machine. A page whose
#     values are ALL excluded is out.
#   ANYTHING ELSE fails the build. An unknown audience value is a decision
#     somebody has to make, and guessing it either way is silent.
#   NO FRONTMATTER or NO audience key: the page is OUT, printed by name. Out
#     rather than in because "absent" must not mean "public" to a filter
#     (docs/frontmatter-contract.md makes the same point about classification).
#
# LINKS FROM AN INCLUDED PAGE, resolved against the source tree:
#   - to an included page: left alone; MkDocs resolves it and, being strict,
#     fails on a bad anchor.
#   - to a file under docs/ that is not a page (an image): the file is copied in.
#   - to an EXCLUDED page, or to anything outside docs/ (a chart, CONTRIBUTING.md,
#     a directory): rewritten to a plain link at the upstream repository, at the
#     release ref. A plain <a href> is a link and not a fetch, so it does not
#     break the air-gap claim; it just does not open offline, and the title
#     attribute says so. Failing the build instead was rejected: most operator
#     pages cite a chart file or CONTRIBUTING.md, so the site would be unbuildable.
#   - an IMAGE that would need the upstream URL fails the build: an <img> to a
#     remote host is a fetch.
#   - a target that does not exist fails the build.
#
# Text inside fenced code blocks and inline code spans is never rewritten.
import argparse
import os
import re
import shutil
import sys

import yaml

INCLUDE = {"operator", "end-user", "admin"}
EXCLUDE = {"contributor", "maintainer", "internal", "machine"}

# Maintenance data under docs/assets, not site content.
SKIP_ASSETS = {"assets/capture-manifest.yaml", "assets/social-preview.png"}
# Screenshots are copied only when an included page references them.
ON_DEMAND_ASSET_DIRS = ("assets/getting-started/", "assets/monitoring/")

SECTION_TITLES = {
    "usage": "Using Tockmox",
    "deployment": "Deploying",
    "administration": "Administration",
    "operations": "Operations",
    "agent-skills": "Agent skills",
}
SECTION_ORDER = ["usage", "deployment", "administration", "operations", "agent-skills"]
# Pinned first within a section; anything not listed follows alphabetically, so a
# new page appears in the nav without anyone editing this file.
PAGE_ORDER = {
    "usage": ["getting-started", "what-you-get", "ai-plane", "working-with-an-agent"],
    "deployment": ["prerequisites", "sizing", "install", "fresh-install",
                   "existing-cluster", "virtual-machines", "hardware-platforms",
                   "profiles", "registry", "airgap", "verify", "upgrade"],
    "operations": ["day-2", "monitoring", "backup-restore", "troubleshooting", "uninstall"],
}
TOP_ORDER = ["architecture", "values", "alternatives", "third-party-licenses"]

TITLE = ' "Not part of the offline documentation; opens the upstream repository"'
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE = re.compile(r"\]\(\s*(<[^>]*>|[^)\s]*)((?:\s+\"[^\"]*\")?)\s*\)")
REFDEF = re.compile(r"^(\s{0,3}\[[^\]]+\]:\s*)(<[^>]*>|\S+)(.*)$")
HREF = re.compile(r"""(href\s*=\s*)(["'])([^"']*)\2""")
SCHEME = re.compile(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//)")


def die(msg):
    print("stage-docs: ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def read_page(path):
    """Return (frontmatter mapping or None, full text)."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end < 0:
        return None, text
    try:
        fm = yaml.safe_load(text[4:end]) or {}
    except yaml.YAMLError as exc:
        die("%s: frontmatter does not parse: %s" % (path, exc))
    return fm, text


def audience_of(fm):
    if not isinstance(fm, dict) or not isinstance(fm.get("tockmox"), dict):
        return None
    aud = fm["tockmox"].get("audience")
    if aud is None:
        return None
    return [str(a) for a in ([aud] if isinstance(aud, str) else aud)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--stage", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--list", action="store_true", help="print the in/out table and stop")
    args = ap.parse_args()

    root = os.path.realpath(args.root)
    docs = os.path.join(root, "docs")
    stage_docs = os.path.join(args.stage, "docs")

    pages = []
    for dp, dn, fn in os.walk(docs):
        dn[:] = sorted(d for d in dn if d != "overrides" or dp != docs)
        for f in sorted(fn):
            if f.endswith(".md"):
                pages.append(os.path.relpath(os.path.join(dp, f), docs))
    pages.sort()

    included, excluded, counts = {}, [], {}
    for rel in pages:
        fm, text = read_page(os.path.join(docs, rel))
        aud = audience_of(fm)
        key = "(none)" if aud is None else ",".join(sorted(aud))
        counts[key] = counts.get(key, 0) + 1
        if aud is None:
            excluded.append((rel, "no tockmox.audience; out, because absent is not public"))
            continue
        unknown = [a for a in aud if a not in INCLUDE and a not in EXCLUDE]
        if unknown:
            die("%s: unknown audience value(s) %s; decide in/out in tools/lib/stage-docs.py"
                % (rel, unknown))
        if any(a in INCLUDE for a in aud):
            included[rel] = (fm, text)
        else:
            excluded.append((rel, "audience %s" % aud))

    print("audience value sets across docs/**/*.md (%d pages):" % len(pages))
    for k in sorted(counts):
        print("  %3d  [%s]" % (counts[k], k))
    print("included: %d pages   excluded: %d pages" % (len(included), len(excluded)))
    for rel, why in excluded:
        print("  OUT  docs/%s  (%s)" % (rel, why))
    if args.list:
        for rel in sorted(included):
            print("  IN   docs/%s" % rel)
        return
    if not included:
        die("no page survived the audience filter")

    if os.path.isdir(args.stage):
        shutil.rmtree(args.stage)
    os.makedirs(stage_docs)

    copied = set()
    rewrites = []

    def convert(src_rel, target, is_image):
        """Return the replacement target, or None to leave it alone."""
        raw = target[1:-1] if target.startswith("<") and target.endswith(">") else target
        if not raw or raw.startswith("#") or SCHEME.match(raw):
            return None
        path, hash_, frag = raw.partition("#")
        path = path.partition("?")[0]
        abs_t = os.path.normpath(os.path.join(os.path.dirname(os.path.join(docs, src_rel)), path))
        if not (abs_t == root or abs_t.startswith(root + os.sep)):
            die("%s: link %r leaves the repository" % (src_rel, target))
        if not os.path.exists(abs_t):
            die("%s: link target %r does not exist" % (src_rel, target))
        rel_docs = os.path.relpath(abs_t, docs) if abs_t.startswith(docs + os.sep) else None
        if rel_docs in included:
            return None
        if rel_docs and os.path.isfile(abs_t) and not abs_t.endswith(".md") \
                and not rel_docs.startswith("overrides" + os.sep):
            if rel_docs not in copied:
                dst = os.path.join(stage_docs, rel_docs)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(abs_t, dst)
                copied.add(rel_docs)
            return None
        if is_image:
            die("%s: image %r is not an asset inside docs/; an <img> to the upstream "
                "host would be a runtime fetch" % (src_rel, target))
        rel_root = os.path.relpath(abs_t, root).replace(os.sep, "/")
        url = "%s/%s/%s/%s" % (args.upstream.rstrip("/"),
                               "tree" if os.path.isdir(abs_t) else "blob", args.ref, rel_root)
        if hash_:
            url += "#" + frag
        rewrites.append((src_rel, target, url))
        return url

    def rewrite_line(src_rel, line):
        parts = re.split(r"(`+[^`]*`+)", line)  # even indexes are prose
        for i in range(0, len(parts), 2):
            seg = parts[i]

            def inline(m):
                head = seg[:m.start()]
                lb = head.rfind("[")
                is_image = lb > 0 and head[lb - 1] == "!"
                new = convert(src_rel, m.group(1), is_image)
                if new is None:
                    return m.group(0)
                return "](%s%s)" % (new, m.group(2) or TITLE)

            def href(m):
                new = convert(src_rel, m.group(3), False)
                return m.group(0) if new is None else "%s%s%s%s" % (m.group(1), m.group(2), new, m.group(2))

            parts[i] = HREF.sub(href, INLINE.sub(inline, seg))
        line = "".join(parts)
        m = REFDEF.match(line)
        if m:
            new = convert(src_rel, m.group(2), False)
            if new is not None:
                line = "%s%s%s" % (m.group(1), new, m.group(3) or TITLE)
        return line

    for rel in sorted(included):
        _, text = included[rel]
        out, in_fence, tok0 = [], False, None
        for line in text.split("\n"):
            m = FENCE.match(line)
            if m:
                if not in_fence:
                    in_fence, tok0 = True, m.group(1)
                elif m.group(1) == tok0:
                    in_fence = False
                out.append(line)
            else:
                out.append(line if in_fence else rewrite_line(rel, line))
        dst = os.path.join(stage_docs, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out))

    # Site-wide assets the theme override and stylesheet reference by path.
    for dp, dn, fn in os.walk(os.path.join(docs, "assets")):
        dn.sort()
        for f in sorted(fn):
            rel = os.path.relpath(os.path.join(dp, f), docs)
            if rel in SKIP_ASSETS or rel in copied or rel.startswith(ON_DEMAND_ASSET_DIRS):
                continue
            dst = os.path.join(stage_docs, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(docs, rel), dst)

    # Navigation, generated so a new page appears without a config edit.
    def title_of(rel):
        t = (included[rel][0] or {}).get("title")
        return str(t or os.path.splitext(os.path.basename(rel))[0])

    def stem(rel):
        return os.path.splitext(os.path.basename(rel))[0]

    def ordered(rels, pinned):
        pin = {p: i for i, p in enumerate(pinned)}
        return sorted(rels, key=lambda r: (pin.get(stem(r), len(pinned)), r))

    nav = []
    if "README.md" in included:
        nav.append({"Home": "README.md"})
    if "why-tockmox.md" in included:
        nav.append({title_of("why-tockmox.md"): "why-tockmox.md"})
    dirs = sorted({os.path.dirname(r) for r in included if os.sep in r},
                  key=lambda d: (SECTION_ORDER.index(d) if d in SECTION_ORDER else 99, d))
    for d in dirs:
        members = [r for r in included if os.path.dirname(r) == d]
        nav.append({SECTION_TITLES.get(d, d): [{title_of(r): r} for r in ordered(members, PAGE_ORDER.get(d, []))]})
    rest = [r for r in included if os.sep not in r and r not in ("README.md", "why-tockmox.md")]
    if rest:
        nav.append({"Reference": [{title_of(r): r} for r in ordered(rest, TOP_ORDER)]})

    cfg = {
        "INHERIT": os.path.join(root, "docs-site", "mkdocs.yml"),
        "docs_dir": stage_docs,
        "theme": {"custom_dir": os.path.join(docs, "overrides")},
        "nav": nav,
    }
    with open(os.path.join(args.stage, "mkdocs.yml"), "w", encoding="utf-8") as fh:
        fh.write(yaml.safe_dump(cfg, sort_keys=True, allow_unicode=True, width=1000))
    with open(os.path.join(args.stage, "rewrites.tsv"), "w", encoding="utf-8") as fh:
        for src, orig, url in sorted(set(rewrites)):
            fh.write("%s\t%s\t%s\n" % (src, orig, url))
    print("staged %d pages, %d assets; %d links rewritten to the upstream repository"
          % (len(included), len(copied), len(rewrites)))


if __name__ == "__main__":
    main()

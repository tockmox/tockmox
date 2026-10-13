#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Every relative markdown link in this repository must resolve to a file that
# exists. Nothing else here is fatal.
#
#   ./tools/check-docs-links.sh              check the tree
#   ./tools/check-docs-links.sh --selftest   prove the rule actually trips
#
# WHY THIS EXISTS. A new deployment page landed on 2026-08-18 linked from the
# docs index and from prerequisites, and from nowhere a reader following the
# installation walkthrough would ever pass. It took a human noticing. Nothing
# was broken, so nothing could have failed: every existing gate ... helm lint,
# kubeconform, the schema validator, the style checker ... has no opinion about
# whether a page can be reached.
#
# That is the same shape this repository keeps finding. A NetworkPolicy that
# applied cleanly and permitted nothing. An alert rule that loaded and could
# not fire. A page that renders and nobody can navigate to. The common
# property is that a clean result and an absent result look identical, so the
# only defence is a check that asserts on reachability rather than validity.
#
# THREE CLASSES, DELIBERATELY DIFFERENT SEVERITY:
#
#   BROKEN LINK ... fatal. A link to a file that does not exist is always a
#   defect, and it is the case a reader hits as a 404.
#
#   BROKEN ANCHOR ... fatal. A link to a heading that does not exist on a page
#   that does. Added 2026-08-27, after `docs/why-tockmox.md` spent eight days
#   pointing at `README.md#what-works-today`, an anchor a README rework had
#   renamed. This is the failure mode this file was written about, in its
#   purest form: a forge silently ignores an unknown fragment and drops the
#   reader at the top of the page, so a correct link and a broken one look
#   identical to everyone except the reader, who does not know what they
#   missed. It survived a checkpoint that recorded the anchor as deliberately
#   preserved. Nothing on the honour system stays true.
#
#   ORPHAN ... advisory, printed and not fatal. A page nothing links to is
#   usually an oversight and sometimes correct: `docs/values.md` is a
#   deliberate redirect stub kept so old links survive, and `docs/README.md` is
#   reached by browsing to the directory rather than by a link. Failing the
#   build on those would teach people to add decorative links, which is worse
#   than the problem. Print it, let a human judge it.
#
# ANCHOR RESOLUTION follows GitHub's slug rules: lowercase, formatting and
# punctuation dropped, spaces to hyphens. Explicit `<a id=>` and `<a name=>`
# targets count, so a renamed heading can keep an old inbound link alive
# deliberately rather than by accident. A same-page `](#section)` link is
# checked against its own file. External links are not checked ... that needs
# the network, and a build that fails because someone else's site is down is a
# build people learn to re-run rather than read.
set -euo pipefail
cd "$(dirname "$0")/.."

exec python3 - "$@" <<'PY'
import os
import subprocess, re, sys, collections, tempfile

argv = sys.argv[1:]
mode = 'selftest' if '--selftest' in argv else 'check'

# The negative lookahead keeps this true to the contract above: external
# links are not checked, INCLUDING external links that happen to end in .md
# (a GitHub blob URL to a root file tripped this on 2026-08-19 ... the target
# existed, the checker resolved it as a relative path).
LINK = re.compile(r'\[[^\]]*\]\(\s*(?!https?://)([^)\s#]+\.md)(?:#[^)]*)?\s*\)')

# Same shape, but keeping the fragment and allowing the file half to be absent
# so a same-page `](#section)` is caught too.
ANCHORED = re.compile(r'\[[^\]]*\]\(\s*(?!https?://)([^)\s#]*\.md)?#([^)\s]+)\s*\)')

# A fenced block can contain anything, including prose that looks like a
# heading. Strip fences before harvesting headings so a `# comment` line in a
# shell transcript does not mint an anchor that does not exist.
FENCE = re.compile(r'^(?: {0,3})(```|~~~).*?^(?: {0,3})\1', re.M | re.S)
HEADING = re.compile(r'^(#{1,6})\s+(.+?)\s*#*\s*$', re.M)
EXPLICIT = re.compile(r'<a\s[^>]*?(?:id|name)\s*=\s*["\']([^"\']+)["\']', re.I)

def slug(text):
    """GitHub's heading-to-fragment rule, close enough for the constructions
    this repository actually uses: strip inline formatting, drop punctuation,
    lowercase, spaces to hyphens.

    TWO CORRECTIONS, 2026-09-01 (TM-0311). This function disagreed with GitHub
    in two ways, and both were wrong in BOTH directions ... a link a reader
    could follow failed the build, and a link the gate accepted dropped a
    reader at the top of the page. That second one is the exact failure this
    whole script was written to catch, so the gate was reproducing its own
    subject.

    1. UNDERSCORES ARE NOT EMPHASIS HERE. The old code stripped `_` alongside
       `*` and `~`. But `_` is a word character to `[^\\w\\s-]` below, and
       GitHub keeps it. `CERTIFICATE_VERIFY_FAILED` slugged to
       `certificateverifyfailed` where a forge gives `certificate_verify_failed`.
       Underscores are unavoidable in this project's headings: environment
       variables, Python exception names, Postgres functions.

    2. ONE HYPHEN PER SPACE, NOT PER RUN. The old code collapsed a whitespace
       RUN with `\\s+`; GitHub emits one hyphen per space character. After
       punctuation is dropped, the house `...` separator leaves TWO spaces, so
       every `Heading ... Required` diverged. Measured at the time of the fix:
       46 headings in docs/ were affected. The house style guaranteed it.
    """
    s = re.sub(r'!?\[([^\]]*)\]\([^)]*\)', r'\1', text)   # links and images
    s = s.replace('`', '')
    s = re.sub(r'[*~]', '', s)                             # NOT _, see above
    s = re.sub(r'<[^>]+>', '', s)                          # inline html
    s = s.lower().strip()
    s = re.sub(r'[^\w\s-]', '', s)
    return re.sub(r'\s', '-', s)                           # per char, not per run

def anchors_in(text):
    body = FENCE.sub('', text)
    found = {slug(m.group(2)) for m in HEADING.finditer(body)}
    found.update(m.group(1) for m in EXPLICIT.finditer(body))
    found.discard('')
    return found

def markdown_files(root):
    """Tracked files when `root` is a git work tree, a filesystem walk otherwise.

    THE WALK WAS WRONG ON THE REPOSITORY and right on a fixture, which is why it
    survived. A gate judges what ships, and what ships is what git tracks ...
    check-no-site-specifics.sh and check-docs-style.sh both say so in their own
    comments and both use `git ls-files`. This one did not, and on 2026-09-03 it
    read 6473 markdown files against 73 tracked, reporting 568 broken links,
    every one of them inside an untracked `render-diff/` scratch directory that
    `tools/render-diff.sh` had left behind. Zero were in the repository.

    That is not merely noise. It made the gate unrunnable locally while staying
    green in CI, which checks out clean ... so the one place the failure could
    not appear was the place anyone would notice, and the practical effect was
    that no contributor could reproduce CI on their own machine.

    The selftest drives analyse() on a fixture tree that is not a git
    repository, so the walk stays as the fallback rather than being deleted.
    """
    try:
        out = subprocess.run(
            ['git', '--no-optional-locks', '-C', root, 'ls-files', '-z', '--', '*.md'],
            capture_output=True, check=True, text=True).stdout
        tracked = {os.path.normpath(os.path.join(root, p))
                   for p in out.split('\0') if p}
        if tracked:
            return tracked
    except (OSError, subprocess.CalledProcessError):
        pass

    out = set()
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', 'build')]
        for f in files:
            if f.endswith('.md'):
                out.add(os.path.normpath(os.path.join(base, f)))
    return out

def analyse(root):
    """Pure. Returns (broken, bad_anchors, orphans, pages) so selftest can drive
    it on a fixture tree instead of on the repository."""
    pages = markdown_files(root)
    text_of, anchors = {}, {}
    for page in pages:
        try:
            text_of[page] = open(page, encoding='utf-8').read()
        except (OSError, UnicodeDecodeError):
            continue
        anchors[page] = anchors_in(text_of[page])

    broken, bad_anchors, inbound = [], [], collections.Counter()
    for page in sorted(text_of):
        here = os.path.dirname(page)
        text = text_of[page]
        for m in LINK.finditer(text):
            target = os.path.normpath(os.path.join(here, m.group(1)))
            if os.path.isfile(target):
                inbound[target] += 1
            else:
                broken.append((page, m.group(1)))
        for m in ANCHORED.finditer(text):
            rel, frag = m.group(1), m.group(2)
            target = os.path.normpath(os.path.join(here, rel)) if rel else page
            # A missing FILE is already reported as a broken link; do not
            # report it twice under a second heading.
            if target not in anchors:
                continue
            if frag not in anchors[target] and frag.lower() not in anchors[target]:
                bad_anchors.append((page, (rel or '') + '#' + frag, target))
    orphans = [p for p in sorted(pages) if inbound[p] == 0]
    return broken, bad_anchors, orphans, pages

# Orphans that are correct by design.
#
# ANY file named README.md, at any depth. Forges render a directory's README
# when you browse to it, so a chart README is reached by opening the chart
# directory ... which is exactly how someone looks for it. Enumerating the
# eleven that exist today would mean editing this list every time a chart is
# added, and a list that needs maintaining to stay true is the thing this
# repository keeps getting caught by. Express the rule instead.
#
# Everything else needs a named reason.
ORPHANS_BY_DESIGN = {
    os.path.normpath('docs/values.md'),       # redirect stub, says so in the file
    # CLAUDE.md is reached by a tool looking for that exact filename, never by a
    # reader following a link. Linking it from AGENTS.md would satisfy this gate
    # and mislead a human into opening a three-line pointer. It holds no content
    # of its own on purpose: two copies of a rule set is two copies that drift.
    os.path.normpath('CLAUDE.md'),
}

def orphan_by_design(path):
    return (os.path.basename(path) == 'README.md'
            or os.path.normpath(path) in ORPHANS_BY_DESIGN)

if mode == 'selftest':
    cases = []
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, 'sub'))
        # a.md links to a real file, a missing file, a real anchor, a renamed
        # anchor, an explicit anchor, a same-page anchor, and a fragment whose
        # only match is a heading inside a fenced code block.
        open(os.path.join(d, 'a.md'), 'w').write(
            '# Top\n\n'
            'see [ok](sub/b.md) and [gone](sub/nope.md)\n'
            'and [live](sub/b.md#the-real-heading)\n'
            'and [renamed](sub/b.md#what-works-today)\n'
            'and [explicit](sub/b.md#kept-alive)\n'
            'and [self](#top)\n'
            'and [selfgone](#no-such-section)\n'
            'and [fenced](sub/b.md#not-a-heading)\n'
            'and [dead file anchor](sub/nope.md#whatever)\n'
            # TM-0311, the two GitHub-divergence corrections. Each is asserted
            # in BOTH directions: the GitHub spelling must be ACCEPTED, and the
            # old wrong spelling must now be REFUSED. An acceptance case alone
            # would still pass if slug() started accepting everything.
            'and [underscore ok](sub/b.md#certificate_verify_failed)\n'
            'and [underscore old](sub/b.md#certificateverifyfailed)\n'
            'and [two spaces ok](sub/b.md#mirror-the-images--required)\n'
            'and [two spaces old](sub/b.md#mirror-the-images-required)\n')
        open(os.path.join(d, 'sub', 'b.md'), 'w').write(
            '# B\n\n## The `real` **heading**\n\n'
            '<a id="kept-alive"></a>\n\n'
            '## CERTIFICATE_VERIFY_FAILED\n\n'
            '## Mirror the images ... Required\n\n'
            '```bash\n# not a heading\n```\n')
        open(os.path.join(d, 'sub', 'orphan.md'), 'w').write('# nobody links here\n')
        broken, bad_anchors, orphans, pages = analyse(d)
        rel = lambda ps: sorted(os.path.relpath(p, d) for p in ps)
        frags = sorted(f for _, f, _ in bad_anchors)

        # Two links point at sub/nope.md: a bare one and an anchored one. Both
        # are broken FILE links, which is why the anchored one is not also
        # counted as a broken anchor below.
        cases.append(('finds the broken link',
                      [os.path.relpath(p, d) + ' -> ' + l for p, l in broken]
                      == ['a.md -> sub/nope.md', 'a.md -> sub/nope.md']))
        cases.append(('does not flag the resolving link',
                      all(l != 'sub/b.md' for _, l in broken)))
        cases.append(('strips anchors before resolving files',
                      all('#' not in l for _, l in broken)))
        cases.append(('finds the renamed anchor',
                      'sub/b.md#what-works-today' in frags))
        cases.append(('accepts a heading with inline formatting',
                      'sub/b.md#the-real-heading' not in frags))
        cases.append(('accepts an explicit <a id> target',
                      'sub/b.md#kept-alive' not in frags))
        cases.append(('accepts a same-page anchor', '#top' not in frags))
        cases.append(('finds a broken same-page anchor',
                      '#no-such-section' in frags))
        cases.append(('does not mint anchors from fenced code',
                      'sub/b.md#not-a-heading' in frags))
        cases.append(('does not report an anchor on a file already reported missing',
                      all(not f.startswith('sub/nope.md') for f in frags)))
        # TM-0311. Underscores are word characters to GitHub and to `\w`, and
        # are only emphasis markers between words. Stripping them made the gate
        # accept an anchor that 404s and refuse one that works.
        cases.append(('accepts an underscore anchor the way GitHub spells it',
                      'sub/b.md#certificate_verify_failed' not in frags))
        cases.append(('refuses the old underscore-stripped spelling',
                      'sub/b.md#certificateverifyfailed' in frags))
        # TM-0311. GitHub emits one hyphen PER SPACE. The house "..." separator
        # leaves two spaces once punctuation is dropped, so this fires on the
        # project's own style rather than on an edge case.
        cases.append(('accepts one hyphen per space, as GitHub does',
                      'sub/b.md#mirror-the-images--required' not in frags))
        cases.append(('refuses the old collapsed-whitespace spelling',
                      'sub/b.md#mirror-the-images-required' in frags))
        cases.append(('finds the orphan', 'sub/orphan.md' in rel(orphans)))
        cases.append(('does not call a linked page an orphan',
                      'sub/b.md' not in rel(orphans)))
        cases.append(('sees every markdown file', len(pages) == 3))

    bad = [name for name, ok in cases if not ok]
    for name, ok in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if bad:
        print(f"\ncheck-docs-links: {len(bad)} selftest case(s) wrong. The gate "
              f"does not do what it claims, so a clean run proves nothing.")
        sys.exit(1)
    print(f"\ncheck-docs-links: {len(cases)} selftest cases pass.")
    sys.exit(0)

broken, bad_anchors, orphans, pages = analyse('.')
orphans = [p for p in orphans if not orphan_by_design(p)]

print(f"check-docs-links: {len(pages)} markdown file(s)")

if orphans:
    print("\nADVISORY ... nothing links to these pages:")
    for p in orphans:
        print(f"  {p}")
    print("  A reader can only reach them by knowing the path. Link them, or")
    print("  add them to ORPHANS_BY_DESIGN with a reason.")

if broken:
    print("\nBROKEN relative links:")
    for p, l in broken:
        print(f"  {p} -> {l}")

if bad_anchors:
    print("\nBROKEN anchors ... the page exists, the heading does not:")
    for p, l, target in bad_anchors:
        print(f"  {p} -> {l}")
    print("  Rename the link, or keep the old fragment alive on the target")
    print("  page with an explicit <a id=\"...\"></a>.")

if broken or bad_anchors:
    print(f"\ncheck-docs-links: {len(broken)} broken link(s), "
          f"{len(bad_anchors)} broken anchor(s).")
    sys.exit(1)

print("check-docs-links: no broken relative links or anchors.")
sys.exit(0)
PY

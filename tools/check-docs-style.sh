#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Enforce the documentation style rules that govern every markdown surface in
# this repository: no emoji that carries meaning on its own, the fixed form
# and cap of the Maintainer's-note heading, and no first person outside those
# two note zones (three rule blocks below; the third was added 2026-09-04,
# TM-0401), and no correction history inside a how-to page's procedure (the
# fourth, added 2026-09-14, TM-0590).
#
# NOT ENFORCED, deliberately: em-dashes. They were gated here until 2026-08-18,
# when the rule was relaxed for public-repo docs surfaces to normal editorial
# convention: use them where they read well, do not overuse them. A punctuation
# preference is a review comment, not a build failure, and a gate that fails a
# pull request over a dash trains people to resent the gate that also catches
# the accessibility problem. The "..." convention still holds on brand surfaces,
# which this check does not cover.
#
#   ./tools/check-docs-style.sh              check every tracked markdown file
#   ./tools/check-docs-style.sh --selftest   prove the rules actually trip
#   ./tools/check-docs-style.sh FILE...      check specific files
#
# WHY THIS EXISTS: the style rules were stated in four places and enforced in
# none, and the tree quietly disagreed with them. A scan on 2026-08-17 found
# fourteen emoji sitting in two published documentation pages that every
# existing check had passed over for months, because helm lint, kubeconform,
# and a schema validator have no opinion about prose. A rule with no gate is a
# preference, and this repository has learned that lesson once already with
# NetworkPolicies that guarded nothing.
#
# THE RULE: an emoji may appear only where deleting it changes nothing. It may
# never be the thing that carries the meaning. That is not a stylistic
# preference ... an emoji's accessible name describes its appearance, so a
# screen reader announces "white heavy check mark" where the author meant
# "supported", and "link" where the author meant "release notes for v1.12.0".
# GitHub's own documentation style guide bans emoji in tables for exactly this
# reason and requires a symbol's accessible name to state its meaning rather
# than its appearance. A repository README has no mechanism to supply one.
#
# WHAT IS PERMITTED, precisely, because a gate that cannot be predicted gets
# disabled:
#
#   1. Inside a ```mermaid fence, as a node icon, provided the line also
#      carries a text label. Mermaid has no alt-text mechanism for a node
#      label, so icon-plus-label is the only construction available to a
#      diagram that wants visual differentiation at all.
#   2. In prose, as decoration, provided the line also carries words and the
#      emoji is not doing structural work. Permitted, discouraged.
#   3. Inside any other fenced code block. Those are transcripts of program
#      output, quoted rather than authored, and this project does not get to
#      restyle what someone else's tool prints.
#
# WHAT IS REFUSED:
#
#   - Any emoji in a heading. Headings are navigation targets and are read
#     aloud as a list.
#   - Any emoji in a table row. This is the specific pattern GitHub bans and
#     the specific pattern two peer projects ship anyway.
#   - Any emoji inside link text. A column of link glyphs reads as "link,
#     link, link" to anyone navigating by jumping between links.
#   - Any emoji on a line with no words, which is the machine-checkable form
#     of "the emoji is the only thing here, so it is carrying the meaning".
#
# HONEST BOUNDARY: rule 2's word test is a proxy. A gate can prove an emoji is
# not alone on a line; it cannot prove the words next to it mean the same
# thing. Redundancy in prose stays a review judgment, and this check only
# guarantees that the structural cases ... headings, tables, link text, bare
# glyphs ... cannot ship.
#
# WHY NOT markdownlint OR Vale (build-or-adopt scan, 2026-08-17):
#   markdownlint  55 built-in rules as of v0.40.x, none of which concern
#                 emoji (the `accessibility` tag covers only MD045 alt-text
#                 and MD059 descriptive-link-text). Expressing this rule means
#                 authoring a custom rule in JavaScript AND adding Node to
#                 both pipelines. The Forgejo runner is Wolfi, runs as uid 0
#                 with no sudo, and today installs only helm and kubeconform.
#   Vale          Can express the match: its regex engine is Go's plus
#                 lookaround, so a custom `existence` style would work. Costs
#                 a binary download and a style directory, and its scoping is
#                 built for prose rather than for "inside a mermaid fence but
#                 not a table row", which is the distinction doing the work
#                 here.
#   Verdict       BUILD. The carve-out is bespoke under every option, so the
#                 only real question is which runtime hosts it. This
#                 repository already hosts eight bash check scripts and
#                 depends on python3 in CI, and adds nothing new by hosting a
#                 ninth. Revisit if a second project needs the same rule.

# PORTABILITY: this wrapper must run on macOS, whose /bin/bash is 3.2.57 (the
# last GPLv2 release, frozen in 2007). The first version of this script used
# `mapfile`, an empty-array length test, and a bare "$@" ... all three are
# bash 4+ or 4.4+ behaviour, and all three blew up on the maintainer's laptop
# while passing in a Linux CI container. So: no arrays, no mapfile, no bare
# "$@" under `set -u`, and argument handling and file discovery both live in
# python3 where the semantics do not depend on which decade the shell is from.
# A gate that only runs on the CI runner cannot be run before pushing, which
# defeats the point of having it.

set -eu

cd "$(dirname "$0")/.."

case "${1:-}" in
  -h|--help) sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "check-docs-style: needs python3 on PATH." >&2
  echo "  macOS: xcode-select --install, or brew install python" >&2
  exit 2
}

# ${@+"$@"} rather than "$@": bash 3.2 with `set -u` treats an empty "$@" as an
# unbound variable and aborts. This form expands to nothing when there are no
# arguments and to the arguments otherwise, on every bash back to 2.
python3 - ${@+"$@"} <<'PY'
import os, re, subprocess, sys

argv = sys.argv[1:]
mode = 'selftest' if '--selftest' in argv else 'check'
paths = [a for a in argv if not a.startswith('-')]

if mode == 'check' and not paths:
    # git ls-files, not a filesystem walk: a gate should judge what is
    # committed. An untracked scratch file failing CI teaches people to
    # distrust the gate. Falls back to a walk outside a git checkout, which is
    # how this behaves inside a release tarball.
    try:
        out = subprocess.run(['git', 'ls-files', '*.md'],
                             capture_output=True, text=True, check=True).stdout
        paths = [p for p in out.splitlines() if p]
    except (OSError, subprocess.CalledProcessError):
        paths = []
    if not paths:
        # The `./` prefix os.walk produces has to come off. Rules that compare a
        # path against a literal ... the maintainer-note allow-list is the one
        # that bit ... see `docs/why-tockmox.md` where the walk gives
        # `./docs/why-tockmox.md`, and report a violation in the one file the
        # rule exists to permit. git ls-files emits no prefix, so this only ever
        # showed up in the fallback path: inside a release tarball, or when
        # validating a copy of the tree rather than a checkout.
        paths = [os.path.relpath(os.path.join(d, f), '.')
                 for d, _, fs in os.walk('.') if '.git' not in d.split(os.sep)
                 for f in fs if f.endswith('.md')]

# Characters that render as emoji with NO variation selector
# (Unicode Emoji_Presentation=Yes), plus the emoji planes, plus anything an
# author explicitly asked to be emoji with U+FE0F.
#
# Deliberately NOT matched, and this is the point of curating the set by hand
# rather than reaching for the whole Dingbats block: U+2713 CHECK MARK (used
# in this repo's installer output), U+2717, U+2192 ARROW, U+00B7 MIDDLE DOT,
# U+2026 ELLIPSIS, and box-drawing. None of those is an emoji, all of them are
# legitimate typography, and a check that flagged them would be turned off
# within a week.
EMOJI = re.compile(
    '['
    '\U0001F000-\U0001FAFF'          # emoji planes: faces, objects, symbols, flags
    '⌚-⌛⏩-⏬⏰⏳'
    '◽-◾☔-☕♈-♓♿⚓⚡'
    '⚪-⚫⚽-⚾⛄-⛅⛎⛔⛪'
    '⛲-⛳⛵⛺⛽✅✊-✋✨'
    '❌❎❓-❕❗➕-➗➰➿'
    '⬛-⬜⭐⭕'
    ']'
    '|.️'                        # any char + emoji variation selector
)

WORDS      = re.compile(r'[A-Za-z]{3}')          # "there is a text label here"
HEADING    = re.compile(r'^\s{0,3}#{1,6}\s')
TABLE_ROW  = re.compile(r'^\s*\|')
LINK_TEXT  = re.compile(r'\[([^\]]*)\]\s*[\(\[]')
FENCE      = re.compile(r'^\s*```+\s*([A-Za-z0-9_-]*)')

def violations(text):
    """Yield (lineno, rule, line) for each violation. Pure, so selftest can
    exercise the identical code path CI runs."""
    fence_lang = None
    for n, line in enumerate(text.splitlines(), 1):

        m = FENCE.match(line)
        if m:
            fence_lang = None if fence_lang is not None else (m.group(1).lower() or 'plain')
            continue

        if not EMOJI.search(line):
            continue

        if fence_lang == 'mermaid':
            if not WORDS.search(line):
                yield n, 'emoji is the whole mermaid node label; add the text label', line
            continue

        if fence_lang is not None:
            continue    # transcript of someone else's output, not ours to restyle

        if HEADING.match(line):
            yield n, 'emoji in a heading', line
        elif TABLE_ROW.match(line):
            yield n, 'emoji in a table row (see GitHub docs style guide: no emoji in tables)', line
        elif any(EMOJI.search(t) for t in LINK_TEXT.findall(line)):
            yield n, 'emoji inside link text (link must read out of context)', line
        elif not WORDS.search(line):
            yield n, 'emoji is the only content on the line, so it carries the meaning', line

# ---- Maintainer's-note blocks (the "M" zone in the brand ruling) ------------
# Company docs are written in one voice. Exactly two places may carry the
# maintainer's personal first-person register, they must announce themselves in
# a fixed form, and there may never be a third.
#
# This is not style policing. The separability directive says the product has to
# stand on its own without the founder's persona welded to it, and the control
# that makes that true is that every personal block is ATTRIBUTED, EXCISABLE and
# claims nothing. A block that drifts into an unmarked "I think" paragraph
# somewhere in the reference docs is the failure mode, and it happens one
# reasonable exception at a time. A cap written only in prose is a cap nobody
# enforces, so it is enforced here.
M_HEADING = 'A note from Jeff Maaks, maintainer'
M_ALLOWED = ('README.md', 'docs/why-tockmox.md')
M_SHAPED  = re.compile(r'^#{1,6}\s*(.*(?:note from|maintainer.s note).*?)\s*$',
                       re.IGNORECASE)

def maintainer_note_violations(files):
    """files: list of (path, text). Cross-file, so it cannot live in violations()."""
    found = []
    for path, text in files:
        for n, line in enumerate(text.splitlines(), 1):
            m = M_SHAPED.match(line)
            if m:
                found.append((path.replace('\\', '/'), n, m.group(1)))

    for path, n, heading in found:
        if heading != M_HEADING:
            yield path, n, (f'maintainer note heading must be exactly '
                            f'"{M_HEADING}", got "{heading}"')
        if path not in M_ALLOWED:
            yield path, n, ('maintainer note is only permitted in '
                            + ' or '.join(M_ALLOWED))
    if len(found) > 2:
        path, n, _ = found[2]
        yield path, n, (f'{len(found)} maintainer notes; the cap is 2. '
                        f'A third needs a new brand ruling, not a commit.')

# ---- Diffused first person (the rest of the "M" zone rule) -----------------
# The heading rule above bounds WHERE the maintainer's register may appear. It
# says nothing about first person landing in ordinary prose, which is the
# failure the voice ruling was actually written against: "diffusion happens one
# reasonable exception at a time" (brand/voice-ruling-oss-surfaces-2026-08-14,
# risk register). Until 2026-09-04 a paragraph written in "I" anywhere in the
# reference docs passed CI, so the ruling's property ... first person stays
# ATTRIBUTED and EXCISABLE ... was held by convention alone. TM-0401.
#
# THE HARD PART is that documentation legitimately speaks in the READER's first
# person all the time: "How do I change this safely", "I want to | Go to",
# "I had to patch something" as the quoted shape of a good bug report. A bare
# \bI\b grep would refuse fourteen correct pages and be switched off in a week.
# So the check asserts on the one form the ruling refuses ... first person in
# RUNNING, DECLARATIVE, UNQUOTED prose ... and treats these as the reader's
# voice by construction, each for a stated reason:
#
#   fenced blocks, inline code        someone else's output; never restyled
#   YAML frontmatter, HTML comments   not prose
#   headings, table rows              navigation and symptom titles, phrased
#                                     from the reader's seat ("A change I made
#                                     in the cluster reverted")
#   link text and link targets        mirror a heading somewhere
#   "double-quoted" spans             attributed speech, including a quote
#                                     that runs across a line break, which is
#                                     why prose is examined per PARAGRAPH
#   sentences ending in "?"           a question in first person is the
#                                     reader asking, not the author asserting
#   the Maintainer's-note zone        from the exact M heading to the next
#                                     heading of the same or higher level
#   CONTRIBUTING.md                   outside the ruling's scope, 2026-09-03
#                                     amendment; SUPPORT.md deliberately is NOT
#   "I/O", "I-frame" and the like     a letter, not a pronoun
#
# HONEST BOUNDARY, in the permissive direction: an author can hide a
# first-person paragraph inside quotation marks or phrase it as a question, and
# a first-person HEADING over company-voice prose is not refused on its own.
# All three are visible in review in a way a paragraph is not, and the first
# two are also the correct typography for reader speech, so the discipline the
# gate enforces is "attribute it or quote it", which is the ruling's own test.
# In the strict direction it refuses nothing legitimate on the tree as of
# 2026-09-04, measured across every tracked markdown file before it was wired
# in; the one paragraph it did flag (two sentences in SUPPORT.md, "Discussions
# is open and I read it ... a way to reach me") was a real violation of the
# amendment and was fixed in the same commit.
FP_EXEMPT_PATHS = ('CONTRIBUTING.md',)
FIRST_PERSON = re.compile(
    r"(?<![\w'’/-])(I|I'm|I’m|I've|I’ve|I'd|I’d|I'll|I’ll|[Mm]e|[Mm]y|[Mm]ine|[Mm]yself)(?![\w'’/-])")
# Case is listed explicitly rather than with re.I, which would turn "i.e." and
# a lone lowercase "i" in a code-ish fragment into hits. Sentence-initial "My"
# is the commonest shape of a first-person paragraph and was missed by the
# first draft of this rule (zero-context review, 2026-09-04).
CODE_SPAN  = re.compile(r'`[^`\n]*`')
QUOTED     = re.compile(r'"[^"]*"|“[^”]*”')
LINK       = re.compile(r'!?\[[^\]]*\]\([^)]*\)')
HTML_CMT   = re.compile(r'<!--.*?-->', re.S)
HEADING_RE = re.compile(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$')
# ---------------------------------------------------------------------------
# RULE 4 (TM-0590, 2026-09-14): a how-to page's procedure carries no history.
#
# documentation-standard.md already says it: rationale, history and hard-won
# gotchas accumulate inside a procedure until the steps are no longer visible,
# and the fix is relocation, never deletion. The pages drifted anyway, one
# correction at a time ... "Until 2026-09-12 this step WAS ...", "This section
# used to sit ...", "the confirmation as it then read" ... until an outside
# reader called the install page a forensic history and the maintainer agreed.
# A rule with no gate is a preference, so this is the gate.
#
# Scope, deliberately narrow: pages whose frontmatter says `type: HowTo`, and
# within them everything ABOVE the first `## History and corrections` or
# `## What is not certified here` heading. Reference and explanation pages are
# out of scope: a dated verification there is the standard's own section 6, not
# archaeology. What trips it is a PARAGRAPH that opens with, or a blockquote
# that carries, one of the correction shapes below. A dated success condition
# ("Measured 2026-09-14 on the 0.6.0 tree ...") does not match, on purpose.
ARCHAEOLOGY = re.compile(
    r'(^|\s)(\*\*)?('
    r'Until 2026-\d\d-\d\d'
    r'|until 2026-\d\d-\d\d this (step|page|section|block|line|sheet|table)'
    r'|This (page|section|step|block|table|sheet) (said|used to|once)'
    r'|This section used to sit'
    r'|used to (sit|say|read|miss|be a)'
    r'|as it then read'
    r'|(the|an) (first|earlier) (version|draft) of this'
    r'|was marked \*?Optional\*? until'
    # The three shapes added 2026-09-17, overnight-verification finding: the
    # regex above caught `Until 2026-` and a handful of transition phrases but
    # never gained the `Measured 2026-…` / `Found 2026-…` / `Corrected 2026-…`
    # shapes this card's own "The gate" section always described. A
    # `Measured 2026-09-20 on a later run: this step behaved differently…`
    # paragraph, injected into uninstall.md's procedure, was NOT caught.
    #
    # `Found` and `Corrected` are unconditional: a paragraph that opens
    # "Found 2026-…" or "Corrected 2026-…" is, by construction, narrating a
    # discovery or a fix, never a bare measurement. `Measured 2026-…` is NOT
    # made unconditional, on purpose ... "**Measured 2026-09-14** on the 0.6.0
    # tree, and pinned in doc-claims" is a dated SUCCESS CONDITION (the
    # standard's §6), not archaeology, and the false-case selftest below guards
    # that distinction. What separates the two on the tree is the "compared to
    # an earlier pass" language: "on a later/earlier/subsequent/previous run",
    # which a bare measurement never carries.
    r'|Found 2026-\d\d-\d\d'
    r'|Corrected 2026-\d\d-\d\d'
    r'|Measured 2026-\d\d-\d\d.{0,60}?\bon (a|the) (later|earlier|subsequent|previous|second|next) run\b'
    r'|this block held\b.{0,80}?\buntil\b'
    r')', re.I)
HOWTO_FM = re.compile(r'^type:\s*HowTo\s*$', re.M)
HISTORY_HEADINGS = ('## history and corrections', '## what is not certified here')

def archaeology_violations(path, text):
    """Yield (lineno, rule, excerpt) for correction-history paragraphs inside a
    HowTo page's procedure body."""
    lines = text.splitlines()
    if not (lines and lines[0].strip() == '---'):
        return
    try:
        fm_end = lines.index('---', 1)
    except ValueError:
        return
    if not HOWTO_FM.search('\n'.join(lines[1:fm_end])):
        return
    fence = None
    para, para_start = [], None
    def check():
        if not para:
            return None
        joined = ' '.join(l.strip().lstrip('> ').strip() for l in para)
        joined = CODE_SPAN.sub(' ', joined)
        if ARCHAEOLOGY.search(joined):
            return (para_start, 'correction history inside a how-to procedure ... move it to '
                    '"## History and corrections" at the bottom of the page, or to the '
                    'component page, and leave the decision beside the step (TM-0590)',
                    joined[:120])
        return None
    for i, line in enumerate(lines[fm_end + 1:], start=fm_end + 2):
        low = line.strip().lower()
        if low.startswith('```'):
            fence = None if fence else line.strip()
            continue
        if fence:
            continue
        if low.startswith('## ') and low in HISTORY_HEADINGS:
            v = check(); para = []
            if v: yield v
            return
        if not line.strip() or line.startswith('#') or line.startswith('|'):
            v = check(); para = []
            if v: yield v
            continue
        if not para:
            para_start = i
        para.append(line)
    v = check()
    if v: yield v

# Split on a terminator FOLLOWED BY WHITESPACE, not on every period: "v0.6.0"
# and "k3s 1.30" inside a question would otherwise end the sentence early and
# strip the "?" that exempts it.
SENTENCE_SPLIT = re.compile(r'(?<=[.!?])\s+')

def first_person_violations(path, text):
    """Yield (lineno, rule, excerpt). Line-structured scan to find the prose
    paragraphs, then a per-paragraph scan so a quote spanning lines is still
    seen as one quote."""
    if path.replace('\\', '/') in FP_EXEMPT_PATHS:
        return
    lines = text.splitlines()
    in_fm = bool(lines) and lines[0].strip() == '---'
    fence = None
    note_level = None
    para, para_start = [], None

    def flush():
        if not para:
            return
        joined = ' '.join(l.strip() for l in para)
        joined = HTML_CMT.sub(' ', joined)
        joined = CODE_SPAN.sub(' ', joined)
        joined = LINK.sub(' ', joined)
        joined = QUOTED.sub(' ', joined)
        for sent in SENTENCE_SPLIT.split(joined):
            sent = sent.strip().rstrip('*_ ')   # "...promise?**" is still a question
            if not sent or sent.endswith('?'):
                continue
            m = FIRST_PERSON.search(sent)
            if m:
                yield para_start, (f'first person ("{m.group(0)}") in running prose; '
                                   f'company voice everywhere except a Maintainer\'s note '
                                   f'(quote it if it is the reader speaking)'), sent[:110]
                return

    for n, line in enumerate(lines, 1):
        if in_fm:
            if n > 1 and line.strip() == '---':
                in_fm = False
            continue
        m = FENCE.match(line)
        if m:
            yield from flush(); para, para_start = [], None
            fence = None if fence is not None else (m.group(1).lower() or 'plain')
            continue
        if fence is not None:
            continue
        h = HEADING_RE.match(line)
        if h:
            yield from flush(); para, para_start = [], None
            level = len(h.group(1))
            if note_level is not None and level <= note_level:
                note_level = None
            if h.group(2).strip() == M_HEADING:
                note_level = level
            continue                      # headings are exempt, see above
        if note_level is not None:
            continue
        if not line.strip() or TABLE_ROW.match(line):
            yield from flush(); para, para_start = [], None
            continue
        if para_start is None:
            para_start = n
        para.append(line)
    yield from flush()


SELFTEST = [
    # (should_fail, name, markdown)
    (True,  'emoji in a heading',        '# Status \U0001F680\n'),
    (True,  'emoji in a table row',      '| Release | Active |\n|---|---|\n| 1.12 | ✅ |\n'),
    (True,  'emoji as link text',        'See [\U0001F517](https://example.com) for notes.\n'),
    (True,  'bare emoji line',           'Result:\n\n✅\n'),
    (True,  'bare mermaid node',         '```mermaid\ngraph TD\n  A["\U0001F9E0"]\n```\n'),
    (True,  'vs16 emoji in a table',     '| a | b |\n|---|---|\n| x | \U0001F6E1️ |\n'),
    (False, 'mermaid icon plus label',   '```mermaid\ngraph TD\n  A["\U0001F9E0 Inference host"]\n```\n'),
    (False, 'prose decoration',          'The build is green \U0001F680 and the tag is cut.\n'),
    (False, 'shell transcript with tick', '```bash\n$ install\n  ✓ cluster reachable\n```\n'),
    (False, 'check mark is not an emoji', 'Status: ✓ reachable, → next, mid·dot.\n'),
    (False, 'plain table',               '| Release | Active |\n|---|---|\n| 1.12 | Supported |\n'),
    # Guards the 2026-08-18 relaxation. Without a fixture asserting em-dashes
    # are ACCEPTED, someone re-reading the old comments could reinstate the
    # rule and no test would object.
    (False, 'em-dash is allowed now',    'A sentence — with an em-dash — reads fine.\n'),
]

M_SELFTEST = [
    (False, 'the two sanctioned notes', [
        ('README.md', f'# T\n\n## {M_HEADING}\n\nprose\n'),
        ('docs/why-tockmox.md', f'# W\n\n## {M_HEADING}\n\nprose\n')]),
    (True,  'a third note anywhere', [
        ('README.md', f'## {M_HEADING}\n'),
        ('docs/why-tockmox.md', f'## {M_HEADING}\n'),
        ('docs/architecture.md', f'## {M_HEADING}\n')]),
    (True,  'note in an unsanctioned file', [
        ('docs/operations/day-2.md', f'## {M_HEADING}\n')]),
    (True,  'near-miss heading wording', [
        ('README.md', '## A note from Jeff, maintainer\n')]),
    (True,  'maintainer note styled differently', [
        ('README.md', "## Maintainer's note\n")]),
    (False, 'no notes at all', [('docs/values.md', '# Values\n\nprose\n')]),
]

# (should_fail, name, path, markdown). The refusals are the poison test the
# card asked for; the acceptances are every reader-voice shape found on the
# real tree on 2026-09-04, so a later "tighten it" cannot silently start
# refusing correct pages.
FP_SELFTEST = [
    (True,  'first-person paragraph in a reference page',
     'docs/operations/day-2.md', '# Day 2\n\nI run this every morning and it has never failed me.\n'),
    (True,  'contraction with a curly apostrophe',
     'docs/architecture.md', 'Some prose.\n\nI’ve found the cascade reliable.\n'),
    (True,  '"my" in running prose',
     'README.md', 'This is my favourite part of the design.\n'),
    (True,  'sentence-initial "My" and "Me"',
     'docs/x.md', 'My favourite part is the cascade. Me too.\n'),
    (True,  'first person after the note zone closes',
     'docs/why-tockmox.md',
     f'## {M_HEADING}\n\nI built this at night.\n\n## Next steps\n\nI think you should install it.\n'),
    (True,  'SUPPORT.md is not exempt',
     'SUPPORT.md', 'Discussions is open and I read it.\n'),
    (True,  'a quote that closes before the pronoun',
     'docs/usage/ai-plane.md', 'Say "no" and then I will explain why.\n'),
    (False, 'inside the Maintainer\'s note zone',
     'docs/why-tockmox.md', f'## {M_HEADING}\n\nI built this at night, and I would do it again.\n'),
    (False, 'CONTRIBUTING.md is outside the ruling',
     'CONTRIBUTING.md', 'The contribution I want most is a values-interface gap.\n'),
    (False, 'reader question table',
     'AGENTS.md', '| I want to | Go to |\n|---|---|\n| Walk me through the install | [install](x.md) |\n'),
    (False, 'quoted reader statement across a line break',
     'README.md', 'Tell us where it failed you. "I had\nto patch something because it wouldn\'t let me" is\nthe report we want.\n'),
    (False, 'first-person question is the reader asking',
     'docs/administration/values-contract.md', '**Is this key mine to set, and is it a promise?**\n'),
    (False, 'a question containing a dotted version is still a question',
     'docs/x.md', 'How do I pin v0.6.0 in my site? What if I run k3s 1.30 and it fails?\n'),
    (False, 'i.e. is not a pronoun',
     'docs/x.md', 'Set the class, i.e. the one the globals name.\n'),
    (False, 'symptom heading and its link text',
     'docs/operations/troubleshooting.md',
     '## A change I made in the cluster reverted\n\nSee [a change I made](#a-change-i-made) for the cause.\n'),
    (False, 'inline code and fenced output',
     'docs/x.md', 'Run `echo I am here` first.\n\n```console\n$ whoami\nI am root\n```\n'),
    (False, 'I/O is a letter, not a pronoun',
     'docs/x.md', 'Disk I/O dominates, and the I-frame cadence is fixed.\n'),
    (False, 'company voice',
     'docs/x.md', 'We ship nine layers and our restore drill runs weekly.\n'),
    (False, 'frontmatter and an HTML comment',
     'docs/x.md', '---\nauthor: I\n---\n<!-- I will fix this later -->\nProse in company voice.\n'),
]

AR_SELFTEST = [
    (True, 'until-dated step history in a HowTo',
     'docs/x.md', '---\ntype: HowTo\n---\n## 3b\n\n**Until 2026-09-12 this step WAS a manual apply.** Now it is not.\n'),
    (True, 'a section that used to sit elsewhere',
     'docs/x.md', '---\ntype: HowTo\n---\n**This section used to sit between sections 5 and 6**, which put it late.\n'),
    (True, 'blockquote carrying a correction',
     'docs/x.md', '---\ntype: HowTo\n---\n> **This page said the password came from a Secret until 2026-09-01.** It never did.\n'),
    (False, 'the same sentence under the history heading',
     'docs/x.md', '---\ntype: HowTo\n---\n## Steps\n\nDo the thing.\n\n## History and corrections\n\nUntil 2026-09-12 this step WAS a manual apply.\n'),
    (False, 'a dated success condition is not archaeology',
     'docs/x.md', '---\ntype: HowTo\n---\n**Measured 2026-09-14** on the 0.6.0 tree, and pinned in doc-claims.\n'),
    (False, 'a reference page is out of scope',
     'docs/x.md', '---\ntype: Reference\n---\nUntil 2026-09-12 this table said 32. It says 33 now.\n'),
    (False, 'inside a fence',
     'docs/x.md', '---\ntype: HowTo\n---\n```console\nUntil 2026-09-12 this step was manual\n```\n'),
    # 2026-09-17 additions: the three shapes the overnight verification found
    # missing, plus the negative case it asked for (the same phrase, relocated
    # past the History heading, must be accepted).
    (True, 'measured-on-a-later-run narrative (the exact miss, TM-0590)',
     'docs/x.md', '---\ntype: HowTo\n---\n## 7f\n\n**Measured 2026-09-20 on a later run: this step behaved differently** than the first pass recorded, and the count above was wrong.\n'),
    (True, 'found-dated discovery narrative',
     'docs/x.md', '---\ntype: HowTo\n---\nFound 2026-09-13 by running this page end to end: the sweep ran clean and the listing still printed a name it should not have.\n'),
    (True, 'corrected-dated narrative',
     'docs/x.md', '---\ntype: HowTo\n---\n**Corrected 2026-09-16:** the previous count was wrong and is fixed above.\n'),
    (True, 'this block held ... until shape',
     'docs/x.md', '---\ntype: HowTo\n---\nThis block held the placeholder value until 2026-09-10, when it was replaced with the real one.\n'),
    (False, 'a dated measurement with no later-run language is not archaeology',
     'docs/x.md', '---\ntype: HowTo\n---\n**Measured 2026-09-14** on the 0.6.0 tree, and pinned in doc-claims.\n'),
    (False, 'the measured-on-a-later-run phrase, relocated under the history heading, is accepted',
     'docs/x.md', '---\ntype: HowTo\n---\n## Steps\n\nDo the thing.\n\n## History and corrections\n\nMeasured 2026-09-20 on a later run: this step behaved differently.\n'),
    (False, 'found/corrected phrases, relocated under the history heading, are accepted',
     'docs/x.md', '---\ntype: HowTo\n---\n## Steps\n\nDo the thing.\n\n## History and corrections\n\nFound 2026-09-13 by running this page end to end: it printed a stray name.\nCorrected 2026-09-16: the count above was wrong.\n'),
]

if mode == 'selftest':
    bad = 0
    for should_fail, name, path, md in AR_SELFTEST:
        got = list(archaeology_violations(path, md))
        if bool(got) != should_fail:
            bad += 1
            want = 'to be refused' if should_fail else 'to be accepted'
            print(f'  SELFTEST FAIL  expected archaeology case {name!r} {want}, got {got}')
        else:
            print(f'  ok  archaeology, {name}: {"refused" if should_fail else "accepted"}')
    for should_fail, name, pairs in M_SELFTEST:
        got = list(maintainer_note_violations(pairs))
        if bool(got) != should_fail:
            bad += 1
            want = 'to be refused' if should_fail else 'to be accepted'
            print(f'  SELFTEST FAIL  expected {name!r} {want}, got {got}')
        else:
            print(f'  ok  {name}: {"refused" if should_fail else "accepted"}')
    for should_fail, name, md in SELFTEST:
        got = list(violations(md))
        if bool(got) != should_fail:
            bad += 1
            want = 'to be refused' if should_fail else 'to be accepted'
            print(f'  SELFTEST FAIL  expected {name!r} {want}, got {got}')
        else:
            verdict = 'refused' if should_fail else 'accepted'
            print(f'  ok  {name}: {verdict}')
    for should_fail, name, path, md in FP_SELFTEST:
        got = list(first_person_violations(path, md))
        if bool(got) != should_fail:
            bad += 1
            want = 'to be refused' if should_fail else 'to be accepted'
            print(f'  SELFTEST FAIL  expected first-person case {name!r} {want}, got {got}')
        else:
            verdict = 'refused' if should_fail else 'accepted'
            print(f'  ok  first person, {name}: {verdict}')
    if bad:
        print(f'\ncheck-docs-style: {bad} selftest case(s) wrong. The gate does not '
              f'enforce what it claims to.', file=sys.stderr)
        sys.exit(1)
    n_cases = len(SELFTEST) + len(M_SELFTEST) + len(FP_SELFTEST) + len(AR_SELFTEST)
    n_refuse = (sum(1 for f, _, _ in SELFTEST if f) + sum(1 for f, _, _ in M_SELFTEST if f)
                + sum(1 for f, _, _, _ in FP_SELFTEST if f) + sum(1 for f, _, _, _ in AR_SELFTEST if f))
    print(f'\ncheck-docs-style: {n_cases} selftest cases pass. '
          f'{n_refuse} of them are refusals, so the gate '
          f'is proven to fail and not merely to run.')
    sys.exit(0)

total = 0
corpus = []
for path in paths:
    try:
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        print(f'{path}: cannot read ({exc})', file=sys.stderr)
        total += 1
        continue
    corpus.append((path, text))
    for lineno, rule, line in violations(text):
        total += 1
        print(f'{path}:{lineno}: {rule}\n    {line.strip()[:110]}')
    for lineno, rule, excerpt in first_person_violations(path, text):
        total += 1
        print(f'{path}:{lineno}: {rule}\n    {excerpt}')
    for lineno, rule, excerpt in archaeology_violations(path, text):
        total += 1
        print(f'{path}:{lineno}: {rule}\n    {excerpt}')

# Cross-file, so it runs once over everything rather than per file. Only
# meaningful on a whole-repo run; skipped when specific files are named,
# because a two-instance cap cannot be judged from a partial view.
if len(corpus) > 5:
    for path, lineno, rule in maintainer_note_violations(corpus):
        total += 1
        print(f'{path}:{lineno}: {rule}')

if total:
    print(f'\ncheck-docs-style: {total} violation(s) across {len(paths)} file(s).\n'
          f'Emoji rule: never-sole-carrier ... an emoji may appear only where '
          f'deleting it changes nothing.\n'
          f'Maintainer notes: fixed heading, {" or ".join(M_ALLOWED)} only, two at most.\n'
          f'First person: company voice in running prose everywhere except a '
          f'Maintainer\'s note and CONTRIBUTING.md; quote the reader\'s words.\n'
          f'History: a how-to procedure carries the decision, not the story of the '
          f'correction; the story goes under "## History and corrections" (TM-0590).\n'
          f'See CONTRIBUTING.md, "Documentation style".',
          file=sys.stderr)
    sys.exit(1)

print(f'check-docs-style: {len(paths)} markdown file(s) clean.')
PY

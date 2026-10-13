#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Extract a fenced code block VERBATIM from a documentation page at a git ref.
#
# This exists to enforce rule 8 of docs/testing-standard.md: "it must execute
# the documented commands verbatim ... not a tidied equivalent that happens to
# work. A harness that quietly fixes the command is testing the harness."
#
# The obvious way to write an executed-docs test is to retype the command into
# the test script. That is exactly the failure mode: the retyped command and the
# published one drift apart, the test stays green, and the page stays wrong.
# So the harness never holds a copy of the command. It reads the bytes out of
# the page at the ref under test and runs those.
#
#   ./extract-block.sh --ref v0.6.0-rc1 \
#                      --page docs/deployment/prerequisites.md \
#                      --section '## 2. ArgoCD, 2.6 or newer' \
#                      --lang bash --block 1
#
#   ./extract-block.sh --ref main \
#                      --page docs/deployment/fresh-install.md \
#                      --section '## 6. Install ArgoCD' \
#                      --lang bash --containing 'helm repo add argo'
#
#   ./extract-block.sh --ref main \
#                      --page docs/deployment/fresh-install.md \
#                      --section '### 4a. The first server ... BOTH SHAPES, on node 1' \
#                      --lang bash --under-label 'One node'
#
# PREFER --containing OVER --block. An ordinal is a position, and a position
# moves when anyone inserts a block above it; --containing names the command
# the path actually means, and refuses on zero matches or on more than one.
#
# --under-label SELECTS BY THE PROSE ABOVE THE FENCE, which is where these pages
# put their routing on purpose: "the routing is stated in the prose immediately
# above every block, in bold, rather than inside it", because a marker inside a
# code block is stripped by every copy control on every docs site. Use it when
# the blocks are distinguishable by their label and not by their content ...
# section 4a's two k3s installs are byte-identical apart from --cluster-init,
# and --containing has no negation, so nothing else can express "the one
# without" (TM-0716). The label is the nearest non-blank line outside any fence;
# two adjacent fences therefore share the one above them. Combining
# --under-label with --containing ANDs them: the label picks the shape, the
# content confirms the command. Both refuse on zero matches or on more than one.
#
# Prints the block body to stdout. With --sha, prints only the SHA256 of the
# block body, which is what a caller records so that a page edit is visible as a
# changed fingerprint rather than as a silently different test.
#
# A section is the named heading and everything under it up to the next heading
# of the SAME OR HIGHER level. Sub-sections are therefore included, which is
# what a reader following the page would also encounter.
#
# A FENCE MAY BE INDENTED, because a page nests a code block inside a list
# item, an admonition or a tab by indenting it, and a reader pastes what is
# INSIDE the indentation. An earlier version recognised a fence only at column
# 0, so a nested block was not merely unselectable, it was invisible: asking
# for fresh-install section 2's timer hold answered EXTRACT_ERROR_NO_MATCH
# about a block the page has, and `--containing transactional-update` looked
# unique only because the extractor could not see the second block carrying
# that string (TM-0722). Now a fence opens at any indent, the indent is
# recorded, the fence closes only on a closing marker at that SAME indent, and
# exactly that indent is removed from every body line, so the bytes returned
# are what a reader would paste rather than what the markdown nesting added.
# A body line indented LESS than its fence, or a closing marker at a different
# indent, is refused with EXTRACT_ERROR_INDENT rather than guessed at: either
# means the fence does not end where this tool would think it does. A line
# with a backtick after the opening three is an inline code span, not a fence,
# and is treated as prose. An indent of four spaces or more OUTSIDE a list is
# markdown's indented code block, and a ``` line inside one is literal text
# that this tool will read as a fence; no page in this repository does that,
# and tools/doc-claims.txt's fence counts already treat an indented ``` line as
# a fence, so the two agree.
#
# WHAT THIS DOES NOT DO: it does not render the MkDocs site. The published page
# and the tracked markdown carry the same command bytes ... the site theme wraps
# them, it does not rewrite them. If that ever stops being true (a macro or an
# include that substitutes into a fence), this tool is reading the wrong thing
# and the harness is back to testing itself. Nothing here detects that.

set -eu

if [ -z "${BASH_VERSION:-}" ]; then
  echo "extract-block.sh: must run under bash" >&2
  exit 2
fi

# Refuse rather than skip. A gate that exits 0 having examined nothing converts
# an absence of testing into a claim of coverage (testing-standard rule 1).
_bash_major="${BASH_VERSINFO[0]:-0}"
if [ "$_bash_major" -lt 3 ]; then
  echo "extract-block.sh: needs bash 3.2 or newer, found ${BASH_VERSION:-unknown}" >&2
  exit 2
fi

REF=""
PAGE=""
SECTION=""
LANG_FENCE="bash"
BLOCK=1
WANT_SHA=0
FROM_FILE=""
CONTAINING=""
UNDER_LABEL=""

usage() {
  sed -n '3,32p' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)     REF="$2"; shift 2 ;;
    --page)    PAGE="$2"; shift 2 ;;
    --section) SECTION="$2"; shift 2 ;;
    --lang)    LANG_FENCE="$2"; shift 2 ;;
    --block)   BLOCK="$2"; shift 2 ;;
    --containing) CONTAINING="$2"; shift 2 ;;
    --under-label) UNDER_LABEL="$2"; shift 2 ;;
    --file)    FROM_FILE="$2"; shift 2 ;;
    --sha)     WANT_SHA=1; shift ;;
    -h|--help) usage ;;
    *) echo "extract-block.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$SECTION" ] || { echo "extract-block.sh: --section is required" >&2; exit 2; }
# --page names the file inside the ref. With --file the path is the file itself,
# so --page is redundant there and is used only to label the output.
if [ -z "$FROM_FILE" ] && [ -z "$PAGE" ]; then
  echo "extract-block.sh: --page is required with --ref" >&2; exit 2
fi
[ -n "$PAGE" ] || PAGE="$FROM_FILE"

# Source the page. --file reads a working tree; --ref reads a tag or commit,
# which is what a released run uses, so the evidence names an immutable ref.
SRC=""
if [ -n "$FROM_FILE" ]; then
  [ -f "$FROM_FILE" ] || { echo "extract-block.sh: no such file: $FROM_FILE" >&2; exit 2; }
  SRC="$(cat "$FROM_FILE")"
elif [ -n "$REF" ]; then
  # Read-only. This harness never writes to a git repository.
  if ! SRC="$(git --no-optional-locks show "${REF}:${PAGE}" 2>/dev/null)"; then
    echo "extract-block.sh: cannot read ${PAGE} at ref ${REF}" >&2
    exit 2
  fi
else
  echo "extract-block.sh: one of --ref or --file is required" >&2
  exit 2
fi

# Exported, not set as a pipeline-element prefix: `VAR=x cmd1 | cmd2` puts VAR
# in cmd1's environment only, and the awk that needs it is cmd2.
export SECTION LANG_FENCE BLOCK CONTAINING UNDER_LABEL

BODY="$(
  printf '%s\n' "$SRC" | awk '
    BEGIN {
      section = ENVIRON["SECTION"]
      lang    = ENVIRON["LANG_FENCE"]
      want    = ENVIRON["BLOCK"] + 0
      needle  = ENVIRON["CONTAINING"]
      label   = ENVIRON["UNDER_LABEL"]
      # The nearest non-blank line seen OUTSIDE any fence. This is where these
      # pages put their routing ("**One node** ... **NODE 1**."), deliberately,
      # because a marker inside a block is stripped by every copy control.
      lastline = ""
      # Selecting by CONTENT rather than by ordinal. Adding one block to a
      # documented section silently re-points every later ordinal, and the
      # path then runs a different command while believing it ran the right
      # one. Measured 2026-09-13: a reachability check was added at the top of
      # fresh-install section 6, every P04 index shifted by one, P04 executed
      # the reachability check as if it were the version listing, failed to
      # parse a chart version out of kubectl output, and reported the cause as
      # a change in helm search output shape. Naming the command cannot drift
      # that way.
      nmatch = 0; saved = ""; buf = ""
      selecting = (needle != "" || label != "")
      # Heading level of the requested section, counted from its leading hashes.
      level = 0
      for (i = 1; i <= length(section); i++) {
        if (substr(section, i, 1) == "#") level++; else break
      }
      inside = 0; infence = 0; capturing = 0; n = 0; found = 0
      findent = ""; err = 0
    }
    {
      line = $0
      if (!inside) {
        if (line == section) { inside = 1; found = 1 }
        next
      }

      # Fence state is tracked for EVERY fenced block, not only the wanted one.
      #
      # An earlier version toggled `infence` only while capturing the target
      # block, so a shell COMMENT inside any preceding code block ... a line
      # starting with "#" ... was read as a markdown heading and silently ended
      # the section. `fresh-install.md` §6 has exactly that, and the extractor
      # reported "fewer than 2 blocks" for a section that has three. Silent
      # truncation is the worst possible failure here: it looks like the page
      # changed, so the reader goes and edits a path script that was correct.
      if (infence) {
        # The close must sit at the indent of the OPENING fence. A closer-shaped
        # line at any other indent is refused rather than read either way:
        # taken as the close it could end a block early, taken as body it
        # could swallow the rest of the section into one command.
        if (line == findent "```") {
          infence = 0
          if (selecting) {
            if (counting) {
              # Both selectors AND together when both are given: the label picks
              # the shape, the content confirms the command.
              ok = 1
              if (needle != "" && index(buf, needle) == 0) ok = 0
              if (label  != "" && index(openlabel, label) == 0) ok = 0
              if (ok) { nmatch++; saved = buf }
            }
            counting = 0; buf = ""
          } else if (capturing) { capturing = 0; exit }
          next
        }
        if (line ~ /^[ \t]*```[ \t]*$/) {
          err = 7; errline = NR; exit
        }
        # Remove exactly the indent of the fence. A blank line may carry less of it
        # (markdown allows an empty line inside a nested fence); a non-blank
        # line that carries less is not inside this fence as a reader sees it.
        if (substr(line, 1, length(findent)) == findent) {
          body = substr(line, length(findent) + 1)
        } else if (line ~ /^[ \t]*$/) {
          body = ""
        } else {
          err = 7; errline = NR; exit
        }
        if (selecting && counting) { buf = buf body "\n" }
        else if (capturing) print body
        next
      }

      # Not in a fence. A heading at the same or a higher level ends the section.
      if (substr(line, 1, 1) == "#") {
        h = 0
        for (i = 1; i <= length(line); i++) {
          if (substr(line, i, 1) == "#") h++; else break
        }
        if (h <= level) { inside = 0; next }
      }

      # Outside a fence and not a heading: this is prose, and the most recent
      # non-blank one is the label in force for the next block. Updated HERE,
      # after the fence and heading branches have taken their lines, so a
      # label-shaped line inside a code block can never become a label ... the
      # same class of bug as the `#`-comment truncation this awk already carries
      # a scar for.
      # A FENCE MARKER IS NOT PROSE. Without this guard the ```bash line itself
      # becomes the label, because it is non-blank and arrives immediately
      # before the fence-open branch reads it. Caught on the first run.
      # A fence opens at ANY indent (TM-0722): up to the three backticks is
      # the indent, and what follows them is the info string, which for a
      # backtick fence may not itself contain a backtick ... a line that does
      # is an inline code span in prose, not a fence.
      isfence = 0
      if (match(line, /^[ \t]*```/)) {
        oind = substr(line, 1, RLENGTH - 3)
        finfo = substr(line, RLENGTH + 1)
        if (index(finfo, "`") == 0) isfence = 1
      }
      if (line !~ /^[ \t]*$/ && !isfence) lastline = line

      # A fence opens. Count it only if its language matches.
      if (isfence) {
        infence = 1
        findent = oind
        if (finfo == lang) {
          n++
          # Captured at fence OPEN, not read at fence close: `lastline` keeps
          # moving while the block body is consumed otherwise.
          openlabel = lastline
          if (selecting) { counting = 1; buf = "" }
          else if (n == want) capturing = 1
        }
      }
      next
    }
    END {
      if (err == 7) { print "EXTRACT_ERROR_INDENT line " errline > "/dev/stderr"; exit 7 }
      if (!found) { print "EXTRACT_ERROR_NO_SECTION" > "/dev/stderr"; exit 3 }
      if (selecting) {
        # Ambiguity is a defect too: if two blocks carry the same command the
        # path cannot say which one it means, and picking the first would be a
        # guess wearing a result.
        if (nmatch == 0) { print "EXTRACT_ERROR_NO_MATCH" > "/dev/stderr"; exit 5 }
        if (nmatch > 1)  { print "EXTRACT_ERROR_AMBIGUOUS" > "/dev/stderr"; exit 6 }
        printf "%s", saved
        exit 0
      }
      if (n < want) { print "EXTRACT_ERROR_NO_BLOCK" > "/dev/stderr"; exit 4 }
    }
  '
)" || {
  rc=$?
  case "$rc" in
    3) echo "extract-block.sh: section not found in ${PAGE}: ${SECTION}" >&2 ;;
    4) echo "extract-block.sh: fewer than ${BLOCK} '${LANG_FENCE}' blocks under: ${SECTION}" >&2 ;;
    5) echo "extract-block.sh: no '${LANG_FENCE}' block under '${SECTION}' matches${CONTAINING:+ contains: ${CONTAINING}}${UNDER_LABEL:+ under-label: ${UNDER_LABEL}}" >&2 ;;
    6) echo "extract-block.sh: MORE THAN ONE '${LANG_FENCE}' block under '${SECTION}' matches${CONTAINING:+ contains: ${CONTAINING}}${UNDER_LABEL:+ under-label: ${UNDER_LABEL}}" >&2 ;;
    7) echo "extract-block.sh: a fenced block under '${SECTION}' in ${PAGE} does not keep its indentation: a body line is indented less than its opening fence, or a closing fence sits at a different indent. Refusing rather than guessing where the block ends." >&2 ;;
    *) echo "extract-block.sh: extraction failed (rc=${rc})" >&2 ;;
  esac
  exit 2
}

# An empty extraction is a failure, never a pass. This is the bash-3.2 lesson:
# the dangerous outcome is not an error, it is a success that examined nothing.
if [ -z "$BODY" ]; then
  echo "extract-block.sh: extracted an EMPTY block ${BLOCK} (${LANG_FENCE}) from ${SECTION} in ${PAGE}" >&2
  exit 2
fi

if [ "$WANT_SHA" -eq 1 ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' "$BODY" | sha256sum | awk '{print $1}'
  else
    printf '%s\n' "$BODY" | shasum -a 256 | awk '{print $1}'
  fi
else
  printf '%s\n' "$BODY"
fi

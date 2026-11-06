#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Every block a path script asks the page for, as tab-separated lines: KIND, SECTION, SELECTOR.

  needle   SECTION  TEXT   the block containing TEXT in SECTION        (block, step_begin, block_sha,
                                                                      block_sec, step_begin_sec, block_sec_sha)
  ordinal  SECTION  N      the Nth bash block of SECTION               (block_in, block_in_sha)

The selftest hands each line to extract-block.sh against the working tree's page, so a needle that stops
naming exactly one block (gone, or matched twice) goes red per commit instead of in a live lab run
(run 42074588954: S20's needle matched two install.md blocks and only the lab found it).

The path's default SECTION is read from its `SECTION="${...:-<value>}"` line; a section passed as $NAME is
read from that variable's literal assignment in the same file. Quoting follows bash for what the paths
use: '...' is literal; "..." takes \\" \\$ \\` \\\\ as escapes and must hold no expansion (a needle that
expands at run time cannot be checked here, so it is refused rather than skipped).
Usage: path-needles.py PATH_SCRIPT
"""
import re
import sys

CALLS = {"block": ("needle", 0), "block_sha": ("needle", 0), "step_begin": ("needle", 1),
         "block_sec": ("sec", 0), "block_sec_sha": ("sec", 0), "step_begin_sec": ("sec", 1),
         "block_in": ("ordinal", 0), "block_in_sha": ("ordinal", 0)}
# A call is `$(name ...` or a statement that starts with name: at the line's start, or after ; && || then do.
# The word "block" in a comment or a message is neither.
CALL = re.compile(r'(?:\$\(|^\s*|(?:;|&&|\|\||\bthen|\bdo)\s+)(' + "|".join(sorted(CALLS, key=len, reverse=True))
                  + r')[ \t]+(?=\S)')
INTERNAL = re.compile(r'"?\$(?:[a-z_][a-z0-9_]*|\{[a-z_][a-z0-9_]*\}|[0-9@*])"?')   # a helper passing its own argument on


def words(s: str, i: int, n: int):
    """Read n shell words from s[i:]. Returns (list of (text, quote)), or raises ValueError."""
    out = []
    while len(out) < n:
        while i < len(s) and s[i] in " \t":
            i += 1
        if i >= len(s):
            raise ValueError("ran out of words")
        q, buf = s[i], []
        if q == "'":
            j = s.index("'", i + 1)
            out.append((s[i + 1:j], "'"))
            i = j + 1
        elif q == '"':
            i += 1
            while s[i] != '"':
                if s[i] == "\\" and s[i + 1] in '"$`\\':
                    buf.append(s[i + 1]); i += 2
                    continue
                buf.append(s[i]); i += 1
            out.append(("".join(buf), '"'))
            i += 1
        else:
            m = re.match(r'[^\s;|&)]+', s[i:])
            out.append((m.group(0), ""))
            i += len(m.group(0))
    return out


def main(path: str) -> int:
    src = open(path, encoding="utf-8").read()
    m = re.search(r'^SECTION="\$\{[A-Z0-9_]+:-(.*)\}"\s*$', src, re.M)
    if not m:
        print(f"path-needles: no SECTION=\"${{...:-...}}\" default in {path}", file=sys.stderr)
        return 2
    default = m.group(1)
    assigns = dict(re.findall(r'^\s*([A-Z][A-Z0-9_]*)="([^"$`\\]*)"(?:\s+#.*)?\s*$', src, re.M))
    seen, bad = set(), 0
    for no, line in enumerate(src.split("\n"), 1):
        code = line.split("#", 1)[0] if line.lstrip().startswith("#") else line
        if re.match(r'^\s*(?:[a-z_]+)\(\)\s*\{', code):        # a definition, not a call
            continue
        for c in CALL.finditer(code):
            kind, skip = CALLS[c.group(1)]
            try:
                need = skip + (2 if kind in ("sec", "ordinal") else 1)
                w = words(code, c.end(), need)[skip:]
            except (ValueError, IndexError):
                print(f"path-needles: {path}:{no}: cannot read the arguments of {c.group(1)}", file=sys.stderr)
                bad += 1
                continue
            if any(q != "'" and INTERNAL.fullmatch(t) for t, q in w):
                continue
            texts = []
            for t, q in w:
                if q != "'" and re.fullmatch(r'"?\$[A-Z][A-Z0-9_]*"?', t if q else t):
                    v = t.strip('"').lstrip("$")
                    if v not in assigns:
                        print(f"path-needles: {path}:{no}: {v} has no literal assignment", file=sys.stderr)
                        bad += 1
                        break
                    t = assigns[v]
                elif q != "'" and re.search(r'\$[A-Za-z_{(]|`', t):
                    if t.startswith('"$S') or t == "$S":
                        continue
                    print(f"path-needles: {path}:{no}: {t!r} expands at run time; it cannot be checked", file=sys.stderr)
                    bad += 1
                    break
                texts.append(t)
            else:
                if kind == "needle":
                    row = ("needle", default, texts[0])
                elif kind == "sec":
                    row = ("needle", texts[0], texts[1])
                else:
                    row = ("ordinal", texts[0], texts[1])
                if row not in seen:
                    seen.add(row)
                    print("\t".join(row))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]) if len(sys.argv) == 2 else 2)

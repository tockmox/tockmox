# SPDX-License-Identifier: Apache-2.0
"""Release notes: the CHANGELOG bundled into the image at build time.

Bundled, not fetched, so the running version's notes render with the internet
severed. Rendering is a small, closed Markdown subset over ESCAPED text:
headings, bullets, paragraphs, **bold** and `code`. Links keep their text and
lose their target (the relative paths point into a repo the reader may not have).
"""
from __future__ import annotations

import os
import re

from markupsafe import Markup, escape

_LINKDEF = re.compile(r"^\[[^\]]+\]:\s*\S+\s*$")
_REL = re.compile(r"^## \[(?P<v>[^\]]+)\]\s*(?:\.\.\.|-|–)?\s*(?P<d>\S.*)?$")


def _inline(text: str) -> Markup:
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)      # drop link targets
    s = str(escape(text))
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return Markup(s)


def parse_changelog(md: str) -> dict:
    out: dict = {}
    cur = None
    para: list[str] = []

    def flush():
        if cur is not None and para:
            out[cur]["blocks"].append(("p", _inline(" ".join(para))))
        para.clear()

    for line in md.splitlines():
        m = _REL.match(line)
        if m:
            flush()
            cur = m.group("v").lstrip("v")
            out[cur] = {"version": cur, "date": (m.group("d") or "").strip(), "blocks": []}
            continue
        if cur is None:
            continue
        if _LINKDEF.match(line):
            continue                                  # "[0.8.0]: https://..." is a link target, not text
        if line.startswith("### "):
            flush()
            out[cur]["blocks"].append(("h", _inline(line[4:].strip())))
        elif re.match(r"^\s*[-*] ", line):
            flush()
            out[cur]["blocks"].append(("li", _inline(re.sub(r"^\s*[-*] ", "", line).strip())))
        elif line.strip() == "":
            flush()
        elif out[cur]["blocks"] and out[cur]["blocks"][-1][0] == "li" and line.startswith("  "):
            k, v = out[cur]["blocks"][-1]
            out[cur]["blocks"][-1] = (k, Markup(v + " ") + _inline(line.strip()))
        else:
            para.append(line.strip())
    flush()
    return out


class ReleaseNotes:
    def __init__(self, path: str):
        self.path = path
        self.by_version: dict = {}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                self.by_version = parse_changelog(fh.read())

    def get(self, version: str):
        return self.by_version.get((version or "").lstrip("v"))

    def first(self):
        """The top section of the bundled CHANGELOG: the notes THIS build carries. Shown when the
        layers track a commit or a branch rather than a release tag, where get() has no version to
        look up and the page used to say "No notes bundled" on every pre-release build."""
        return next(iter(self.by_version.values()), None)

    def breaking(self, version: str):
        rel = self.get(version)
        if not rel:
            return []
        out, on = [], False
        for k, v in rel["blocks"]:
            if k == "h":
                on = "breaking" in str(v).lower()
            elif on and k == "li":
                out.append(v)
        return out

# SPDX-License-Identifier: Apache-2.0
"""Set one key in a site values file and leave every other byte of it alone.

The console opens a change as an edit to the file a person keeps in the site repository: their comments, their order and
their other keys must survive. PyYAML cannot round-trip comments, so this edits the TEXT: it finds the key's lines by
indentation (block-style YAML, the style every file the installer writes uses), replaces exactly those lines with the new
value, and then proves the edit: the new file must load, and load to the old file's data with only that key changed. A
file this cannot edit that way (flow style at that key, an anchor, a key spelled with quotes, a tab) is refused with
"edit it by hand"; it is never edited approximately.

    set_path(text, ["sso", "adminUsers"], ["jeff", "dawn"]) -> the new text

A missing key is added at the end of its parent mapping (the parent made too if it is missing). Comments INSIDE the
replaced value are not kept: the value is written whole, as the page that rendered it said.
"""
from __future__ import annotations

import copy
import re

import yaml

KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_./-]*$")             # a plain key; tockmox.com/node-routes is one
MAX_DEPTH = 8


class EditRefused(ValueError):
    pass


class _Dumper(yaml.SafeDumper):
    """Lists indented under their key, the way people write values files (`- a` two spaces in)."""
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def _dump(obj, indent: int) -> list[str]:
    text = yaml.dump(obj, Dumper=_Dumper, sort_keys=False, default_flow_style=False, width=120, allow_unicode=True)
    pad = " " * indent
    return [(pad + ln) if ln.strip() else ln for ln in text.splitlines()]


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _content(line: str) -> bool:
    s = line.strip()
    return bool(s) and not s.startswith("#")


def _find(lines: list[str], lo: int, hi: int, ind: int, key: str):
    """The line index of `key:` at exactly this indent within [lo, hi), or None."""
    pat = re.compile(r"^" + " " * ind + re.escape(key) + r":(\s|$)")
    for i in range(lo, hi):
        if pat.match(lines[i]):
            return i
    return None


def _block_end(lines: list[str], start: int, hi: int, ind: int) -> int:
    """One past the last line that belongs to the key at `start`: its deeper content lines (and the blank or comment
    lines between them). Comments and blanks after the last deeper line belong to whatever follows."""
    end = start + 1
    for i in range(start + 1, hi):
        if _content(lines[i]):
            if _indent(lines[i]) <= ind:
                break
            end = i + 1
    return end


def _child_indent(lines: list[str], start: int, end: int, ind: int) -> int:
    for i in range(start + 1, end):
        if _content(lines[i]):
            return _indent(lines[i])
    return ind + 2


def _check_text(text: str) -> None:
    if "\t" in text:
        raise EditRefused("the file has tab characters; edit it by hand")
    for ln in text.splitlines():
        body = ln if not ln.lstrip().startswith("#") else ""
        body = body.split(" #", 1)[0]
        if re.search(r"(^|[:\-\[,{]\s*)[&*][A-Za-z0-9_-]+|<<\s*:", body):
            raise EditRefused("the file uses YAML anchors, aliases or merge keys; edit it by hand")
    if len([d for d in re.split(r"^---[^\n]*$", text, flags=re.M) if any(_content(x) for x in d.splitlines())]) > 1:
        raise EditRefused("the file holds more than one YAML document; edit it by hand")


def _load(text: str):
    try:
        doc = yaml.safe_load(text) if text.strip() else {}
    except yaml.YAMLError as e:
        raise EditRefused(f"the file is not valid YAML ({str(e).splitlines()[0]})") from None
    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        raise EditRefused("the file is not a mapping")
    return doc


def get_path(doc: dict, path: list[str]):
    cur = doc
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def _has(doc, path) -> bool:
    cur = doc
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return False
        cur = cur[k]
    return True


def set_path(text: str, path: list[str], value) -> str:
    """text with path set to value; text unchanged when it already holds that value. EditRefused otherwise."""
    if not path or len(path) > MAX_DEPTH or not all(isinstance(k, str) and KEY.match(k) for k in path):
        raise EditRefused(f"no such setting {'.'.join(map(str, path))!r}")
    _check_text(text)
    old = _load(text)
    want = copy.deepcopy(old)
    cur = want
    for k in path[:-1]:
        nxt = cur.get(k)
        if nxt is None:
            cur[k] = nxt = {}
        elif not isinstance(nxt, dict):
            raise EditRefused(f"{k} is not a mapping in the file; edit it by hand")
        cur = nxt
    cur[path[-1]] = copy.deepcopy(value)
    if want == old:
        return text

    lines = text.splitlines()
    lo, hi, ind = 0, len(lines), 0
    out = None
    for depth, k in enumerate(path):
        at = _find(lines, lo, hi, ind, k)
        if at is None:
            if _has(old, path[:depth + 1]):
                # the data has it but no line spells it the plain way (quoted, flow style): adding it again would
                # leave two of the same key
                raise EditRefused(f"{'.'.join(path[:depth + 1])} is written in a way the console cannot edit; edit it by hand")
            obj = copy.deepcopy(value)
            for kk in reversed(path[depth:]):
                obj = {kk: obj}
            if depth > 0:
                # a parent written `k: {}`, `k: null` or `k: ~` becomes a block
                lines[lo - 1] = re.sub(r":[ ]*(\{\}|null|~)([ ]*#.*)?$", r":\2", lines[lo - 1])
            out = lines[:hi] + _dump(obj, ind) + lines[hi:]
            break
        end = _block_end(lines, at, hi, ind)
        if depth == len(path) - 1:
            out = lines[:at] + _dump({k: value}, ind) + lines[end:]
            break
        tail = lines[at][ind + len(k) + 1:].split("#", 1)[0].strip()
        if tail not in ("", "{}", "null", "~"):
            raise EditRefused(f"{'.'.join(path[:depth + 1])} is written on one line; edit it by hand")
        lo, hi = at + 1, end
        ind = _child_indent(lines, at, end, ind)
    new_text = "\n".join(out) + "\n"
    try:
        got = _load(new_text)
    except EditRefused:
        got = None
    if got != want:
        raise EditRefused("this file's layout is one the console cannot edit safely; edit it by hand")
    return new_text

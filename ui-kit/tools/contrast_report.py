#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Contrast report for the kit's own pairs, computed with the WCAG formula, in dark and light.

Resolves the custom properties the way the browser does for each theme (the token file's :root,
then the kit's :root; for light, each file's [data-theme="light"] block on top of that), composites
the soft state backgrounds over the panel surface, and prints the ratio of every pair the kit's
components use. Exit 1 if a text pair is under 4.5:1 or a non-text pair (borders, focus) under 3:1.
Apps keep their own report for the pairs they add; this one covers what every app inherits.

  contrast_report.py [--tokens static/tockmox-tokens.css] [--base static/kit-base.css] [--kit static/kit.css]

Stdlib only.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent
_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_DECL = re.compile(r"(--[a-zA-Z0-9_-]+)\s*:\s*([^;]+);")


def blocks(path: Path, selector_re: str) -> dict[str, str]:
    text = _COMMENT.sub("", path.read_text())
    out: dict[str, str] = {}
    for body in re.findall(selector_re + r"\s*\{(.*?)\}", text, re.S):
        out.update({k: v.strip() for k, v in _DECL.findall(body)})
    return out


def theme_vars(tokens: Path, kit: Path, light: bool, base: Path | None = None) -> dict[str, str]:
    """The custom properties in force: the tokens, then the kit's base (where its :root lives), then kit.css."""
    files = [f for f in (tokens, base, kit) if f is not None and f.is_file()]
    v: dict[str, str] = {}
    for f in files:
        v.update(blocks(f, r"(?<![\w\]-]):root"))
    if light:
        for f in files:
            v.update(blocks(f, r'\[data-theme="light"\][^{]*'))
    return v


def resolve(v: dict[str, str], value: str, depth=0) -> str:
    m = re.fullmatch(r"var\((--[\w-]+)(?:\s*,\s*(.+))?\)", value.strip())
    if not m:
        return value.strip()
    if depth > 20:
        raise ValueError(value)
    name, fallback = m.groups()
    if name in v:
        return resolve(v, v[name], depth + 1)
    if fallback:
        return resolve(v, fallback, depth + 1)
    raise KeyError(name)


def rgba(c: str) -> tuple[float, float, float, float]:
    c = c.strip()
    if c.startswith("#"):
        h = c[1:]
        if len(h) == 3:
            h = "".join(x * 2 for x in h)
        return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 1.0
    m = re.fullmatch(r"rgba?\(([^)]+)\)", c)
    if m:
        parts = [p.strip() for p in m.group(1).split(",")]
        a = float(parts[3]) if len(parts) == 4 else 1.0
        return float(parts[0]), float(parts[1]), float(parts[2]), a
    raise ValueError(f"not a colour: {c}")


def over(fg, bg):
    a = fg[3]
    return tuple(fg[i] * a + bg[i] * (1 - a) for i in range(3)) + (1.0,)


def lum(c) -> float:
    def ch(x):
        x /= 255
        return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])


def ratio(a, b) -> float:
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


# (label, foreground, background, soft background composited over `background` or None, kind)
PAIRS = [
    ("body text on page", "--tx-text", "--tx-bg", None, "text"),
    ("body text on panel", "--tx-text", "--tx-surface", None, "text"),
    ("muted text on panel (source lines, captions)", "--tx-text-muted", "--tx-surface", None, "text"),
    ("muted text on raised (row hover, tab hover)", "--tx-text-muted", "--tx-surface-raised", None, "text"),
    ("link on page", "--tx-link", "--tx-bg", None, "text"),
    ("link on panel", "--tx-link", "--tx-surface", None, "text"),
    ("primary button", "--tx-btn-text", "--tx-btn-bg", None, "text"),
    ("primary button, hover", "--tx-btn-text", "--tx-btn-bg-hover", None, "text"),
    ("secondary button", "--tx-btn2-text", "--tx-btn2-bg", None, "text"),
    ("secondary button, hover", "--tx-btn2-text", "--tx-btn2-bg-hover", None, "text"),
    ("secondary button border on page", "--tx-btn2-border", "--tx-bg", None, "ui"),
    ("OK badge", "--st-ok", "--tx-surface", "--st-ok-soft", "text"),
    ("Warning badge", "--st-warning", "--tx-surface", "--st-warning-soft", "text"),
    ("Problem badge", "--st-critical", "--tx-surface", "--st-critical-soft", "text"),
    ("Unknown badge", "--st-unknown", "--tx-surface", "--st-unknown-soft", "text"),
    ("field border on page", "--field-border", "--tx-bg", None, "ui"),
    ("focus ring on page", "--focus", "--tx-bg", None, "ui"),
    ("active tab underline on panel", "--tx-trim", "--tx-surface", None, "ui"),
]


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", type=Path, default=KIT / "static" / "tockmox-tokens.css")
    ap.add_argument("--kit", type=Path, default=KIT / "static" / "kit.css")
    ap.add_argument("--base", type=Path, default=None,
                    help="kit-base.css; defaults to the one beside --kit")
    a = ap.parse_args(argv)
    base = a.base or a.kit.with_name("kit-base.css")
    fails = 0
    for theme in ("dark", "light"):
        v = theme_vars(a.tokens, a.kit, theme == "light", base)
        print(f"== {theme}")
        for label, fg, bg, soft, kind in PAIRS:
            b = rgba(resolve(v, f"var({bg})"))
            if soft:
                b = over(rgba(resolve(v, f"var({soft})")), b)
            f = over(rgba(resolve(v, f"var({fg})")), b)
            r = ratio(f, b)
            need = 4.5 if kind == "text" else 3.0
            ok = r >= need
            fails += not ok
            print(f"   {'PASS' if ok else 'FAIL'}  {r:5.2f}:1 (needs {need})  {label}")
    print("contrast: " + ("ok" if not fails else f"{fails} pair(s) under the bar"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

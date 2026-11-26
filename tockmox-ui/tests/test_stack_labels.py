# SPDX-License-Identifier: Apache-2.0
"""The Stack view's side labels (Argo CD, Site repository) read horizontally, like every band label.

A rule that sets a vertical writing mode, or rotates the label, on `.layer-stack .side` draws the
text turned on its side. The check reads the shipped stylesheet and fails on such a rule.

Run from tockmox-ui/: python -m pytest tests/test_stack_labels.py
"""
import re
from pathlib import Path

CSS = Path(__file__).resolve().parent.parent / "app" / "static" / "app.css"


def _rules():
    text = re.sub(r"/\*.*?\*/", "", CSS.read_text(encoding="utf-8"), flags=re.S)
    return re.findall(r"([^{}]+)\{([^{}]*)\}", text)


def _side_decls():
    return [(sel.strip(), body) for sel, body in _rules() if ".layer-stack .side" in sel]


def test_the_side_label_rules_exist():
    assert any(sel == ".layer-stack .side" for sel, _ in _side_decls())


def test_side_labels_are_not_turned_on_their_side():
    for sel, body in _side_decls():
        assert not re.search(r"writing-mode\s*:\s*(vertical|sideways)", body), (sel, body)
        assert not re.search(r"transform\s*:[^;]*rotate", body), (sel, body)

# SPDX-License-Identifier: Apache-2.0
"""app/values_edit.py: a change opened from the console sets one key in a site values file and leaves every other
byte alone, or refuses. Every edit is proven by loading the result; a layout it cannot edit is refused, never guessed."""
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.values_edit import EditRefused, get_path, set_path  # noqa: E402

SITE = """\
# AI layer: this site's values. Kept by hand; the console edits only what a change names.
litellm:
  masterKeySecret: tockmox-litellm   # rotated 2026-10
  podAnnotations:
    tockmox.com/node-routes: "0123456789abcdef"

# the catalog, as the model watcher left it
modelLifecycle:
  catalog:
    - id: a
      model: org/a        # the first one
  promotion:
    requiredPasses: 3

tockmoxUi:
  enabled: true
"""


def test_a_block_is_replaced_and_every_other_line_stays_as_it_was():
    new = set_path(SITE, ["modelLifecycle"], {"catalog": [{"id": "b", "model": "org/b"}]})
    assert yaml.safe_load(new)["modelLifecycle"] == {"catalog": [{"id": "b", "model": "org/b"}]}
    old_lines = SITE.splitlines()
    kept = [ln for ln in old_lines if not ln.startswith(("  ", "    ", "modelLifecycle"))]
    for ln in kept:
        assert ln in new.splitlines(), ln
    assert "masterKeySecret: tockmox-litellm   # rotated 2026-10" in new
    assert "# the catalog, as the model watcher left it" in new            # the comment above the key is the file's
    assert new.index("modelLifecycle:") < new.index("tockmoxUi:")           # in place, not moved to the end


def test_a_nested_key_with_a_slash_is_set_without_touching_its_siblings():
    new = set_path(SITE, ["litellm", "podAnnotations", "tockmox.com/node-routes"], "fedcba9876543210")
    d = yaml.safe_load(new)
    assert d["litellm"] == {"masterKeySecret": "tockmox-litellm", "podAnnotations": {"tockmox.com/node-routes": "fedcba9876543210"}}
    assert new.replace("fedcba9876543210", "X") .count("# rotated 2026-10") == 1


def test_a_missing_key_is_added_to_its_parent_and_a_missing_parent_is_made():
    new = set_path(SITE, ["tockmoxUi", "actions"], {"changes": {"enabled": False}})
    assert yaml.safe_load(new)["tockmoxUi"] == {"enabled": True, "actions": {"changes": {"enabled": False}}}
    new = set_path(SITE, ["sso", "adminUsers"], ["jeff"])
    assert yaml.safe_load(new)["sso"] == {"adminUsers": ["jeff"]} and new.startswith(SITE.rstrip("\n"))
    assert set_path("", ["sso", "adminUsers"], ["a"]) == "sso:\n  adminUsers:\n    - a\n"
    assert yaml.safe_load(set_path("sso: {}\nx: 1\n", ["sso", "adminUsers"], ["a"])) == {"sso": {"adminUsers": ["a"]}, "x": 1}
    assert yaml.safe_load(set_path("sso:\nx: 1\n", ["sso", "adminUsers"], ["a"])) == {"sso": {"adminUsers": ["a"]}, "x": 1}


def test_a_value_already_there_returns_the_file_unchanged():
    assert set_path(SITE, ["tockmoxUi", "enabled"], True) == SITE


def test_a_list_value_is_replaced_whole():
    t = "sso:\n  enabled: true\n  adminUsers:\n    - jeff\n  # the next key\n  recoveryFlow: true\n"
    new = set_path(t, ["sso", "adminUsers"], ["jeff", "dawn"])
    assert yaml.safe_load(new)["sso"] == {"enabled": True, "adminUsers": ["jeff", "dawn"], "recoveryFlow": True}
    assert "  # the next key\n  recoveryFlow: true" in new


@pytest.mark.parametrize("text,path,why", [
    ('"sso":\n  adminUsers: []\n', ["sso", "adminUsers"], "written in a way"),          # a quoted key: never a second one
    ("sso: {adminUsers: []}\n", ["sso", "adminUsers"], "on one line"),
    ("a: &x 1\nb: *x\n", ["a"], "anchors"),
    ("base: &b\n  x: 1\nc:\n  <<: *b\n", ["c", "x"], "anchors"),
    ("sso:\n\tadminUsers: []\n", ["sso", "adminUsers"], "tab"),
    ("a: 1\n---\nb: 2\n", ["a"], "more than one"),
    ("- a\n- b\n", ["a"], "not a mapping"),
    ("sso: [1]\n", ["sso", "adminUsers"], "not a mapping"),
    ("a: [\n", ["a"], "not valid YAML"),
    ("sso:\n  adminUsers: []\nsso:\n  x: 1\n", ["sso", "adminUsers"], "cannot edit safely"),    # a duplicate key
    ("a: 1\n", ["../x"], "no such setting"),
    ("a: 1\n", [], "no such setting"),
])
def test_a_layout_it_cannot_edit_is_refused(text, path, why):
    with pytest.raises(EditRefused, match=why):
        set_path(text, path, ["z"])


def test_get_path():
    d = yaml.safe_load(SITE)
    assert get_path(d, ["modelLifecycle", "promotion", "requiredPasses"]) == 3
    assert get_path(d, ["nope", "x"]) is None

# SPDX-License-Identifier: Apache-2.0
"""The vendored UI kit (tockmox-ui-kit) is intact and current, and every face the UI loads is one it ships.

The kit's source is ui-kit/ at the repo root; this app serves a pinned copy from app/static/kit and
app/templates/kit (the image copies only tockmox-ui/app). A copy edited in place, or one that fell
behind the source, would let the apps drift apart again, which is what the kit exists to stop."""
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parent
TOOL = REPO / "ui-kit" / "tools" / "ui_kit.py"


def _check(*extra):
    return subprocess.run([sys.executable, str(TOOL), "check", "--static", str(HERE / "app/static/kit"),
                           "--templates", str(HERE / "app/templates/kit"), *extra], capture_output=True, text=True)


def test_the_vendored_kit_matches_its_manifest_and_the_source():
    r = _check("--source", str(REPO / "ui-kit"))
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_check_goes_red_on_an_edited_copy(tmp_path):
    # Prove the check can fail: copy the vendored kit, change one byte, check the copy.
    import shutil
    st, tp = tmp_path / "static", tmp_path / "templates"
    shutil.copytree(HERE / "app/static/kit", st)
    shutil.copytree(HERE / "app/templates/kit", tp)
    css = st / "kit.css"
    css.write_text(css.read_text() + "\n/* local edit */\n")
    r = subprocess.run([sys.executable, str(TOOL), "check", "--static", str(st), "--templates", str(tp)],
                       capture_output=True, text=True)
    assert r.returncode == 1 and "edited" in r.stdout


def test_every_font_face_the_ui_declares_is_shipped_and_none_is_the_display_face():
    static = HERE / "app/static"
    for css in (static / "kit/kit.css", static / "app.css"):
        text = css.read_text()
        assert "Inknut" not in text, f"{css.name} names the display face; it belongs to the lockup only"
        for url in re.findall(r'url\("([^"]+\.woff2)"\)', text):
            assert (css.parent / url).is_file(), f"{css.name} loads {url}, which is not shipped"


def test_the_kit_palette_meets_wcag_in_both_themes():
    r = subprocess.run([sys.executable, str(REPO / "ui-kit" / "tools" / "contrast_report.py"),
                        "--tokens", str(HERE / "app/static/kit/tockmox-tokens.css"),
                        "--kit", str(HERE / "app/static/kit/kit.css")], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout

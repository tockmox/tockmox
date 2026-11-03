# SPDX-License-Identifier: Apache-2.0
"""The console's shell (specs/tockmox-ui/SPEC.md sections 2-3 in the planning repo).

  sections   Home, Status, AI, Platform in the top bar; a rail inside AI and Platform; non-admins see Home
  utilities  the health pill (admins), the Help menu, the account menu with Appearance, Sign out last
  site name  out of the top bar; in the tab title, the footer and About
  version    in the footer and on About; /version moved to /platform/updates (redirect kept)
  theme      shell.js loads before the stylesheets; the light tokens exist; no other script anywhere

Run from tockmox-ui/: python -m pytest tests
"""
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import nav  # noqa: E402
from tests.test_status_api import World, app_obj, make_client  # noqa: E402

HERE = Path(__file__).resolve().parent.parent
DOCS = HERE.parent / "docs"


@pytest.fixture
def world():
    w = World()
    w.apps = [app_obj("tockmox-platform", rev="v0.8.0", path="charts/tockmox-platform"),
              app_obj("tockmox-ai", rev="v0.8.0", path="charts/tockmox-ai")]
    return w


def adm(tmp_path, world, **kw):
    return make_client(tmp_path, world, groups=["tockmox-admins"], **kw)


def member(tmp_path, world, **kw):
    return make_client(tmp_path, world, groups=["tockmox-users"], **kw)


def top(t):
    return t.split('<header class="top">', 1)[1].split("</header>", 1)[0]


def nav_labels(t):
    n = top(t).split('<nav aria-label="Main">', 1)[1].split("</nav>", 1)[0]
    return re.findall(r'<a href="[^"]*"[^>]*>([^<]+)</a>', n)


def current_nav(t):
    m = re.search(r'<nav aria-label="Main">.*?<a href="([^"]*)" aria-current="page">([^<]+)</a>', top(t), re.S)
    return m.group(2) if m else None


def rail_html(t):
    m = re.search(r'<nav class="rail"[^>]*>(.*?)</nav>', t, re.S)
    return m.group(1) if m else ""


# ------------------------------------------------------------ sections and the rail

def test_admins_get_four_sections_and_everyone_else_gets_home(tmp_path, world):
    assert nav_labels(adm(tmp_path, world).get("/").text) == ["Home", "Status", "AI", "Platform"]
    assert nav_labels(member(tmp_path, world).get("/").text) == ["Home"]


@pytest.mark.parametrize("path,section", [("/", "Home"), ("/status", "Status"), ("/models", "AI"),
                                          ("/nodes", "AI"), ("/capabilities", "Platform"),
                                          ("/platform/updates", "Platform"), ("/upgrade", "Platform")])
def test_the_current_section_is_marked(tmp_path, world, path, section):
    r = adm(tmp_path, world).get(path)
    assert r.status_code == 200, (path, r.status_code)
    assert current_nav(r.text) == section


def test_ai_and_platform_have_a_rail_and_home_and_status_do_not(tmp_path, world):
    c = adm(tmp_path, world)
    assert rail_html(c.get("/").text) == "" and rail_html(c.get("/status").text) == ""
    ai = rail_html(c.get("/models").text)
    assert ">Models</a>" in ai and ">Inference nodes</a>" in ai and 'aria-current="page">Models' in ai
    pl = rail_html(c.get("/capabilities").text)
    assert ">Capabilities</a>" in pl and ">Updates</a>" in pl and 'aria-current="page">Capabilities' in pl
    assert ">Overview</a>" not in pl            # Platform Management is off in the example config: absent, not locked
    assert 'class="page-frame with-rail"' in c.get("/models").text


def test_updates_lights_up_for_the_upgrade_page(tmp_path, world):
    assert 'aria-current="page">Updates' in rail_html(adm(tmp_path, world).get("/upgrade").text)


def test_platform_opens_on_capabilities_when_platform_management_is_off(tmp_path, world):
    t = adm(tmp_path, world).get("/").text
    assert '<a href="/capabilities">Platform</a>' in top(t)


# ------------------------------------------------------------ utilities

def test_the_health_pill_is_on_every_admin_page_and_never_for_members(tmp_path, world):
    c = adm(tmp_path, world)
    for p in ("/", "/status", "/models", "/capabilities", "/about"):
        t = top(c.get(p).text)
        assert 'class="hpill st-' in t and 'href="/status"' in t, p
        assert re.search(r'aria-label="[^"]*\. Open Status\."', t), p
    assert "hpill" not in top(member(tmp_path, world).get("/").text)


def test_help_menu_has_its_items_and_help_for_this_page_points_at_a_real_doc(tmp_path, world):
    t = top(adm(tmp_path, world).get("/models").text)
    for label in ("Documentation", "Help for this page", "What's in this build", "If something is down",
                  "Report a problem", "About Tockmox"):
        assert f">{label}" in t, label
    assert "docs/administration/model-lifecycle.md" in t
    assert 'href="https://github.com/tockmox/tockmox/issues"' in t


def test_every_help_map_target_exists():
    for route, page in nav.HELP_MAP.items():
        assert (DOCS / page).is_file(), (route, page)


def test_account_menu_has_appearance_and_sign_out_last(tmp_path, world):
    t = top(adm(tmp_path, world).get("/").text)
    acct = t.split('aria-label="Account:', 1)[1]
    assert "data-appearance hidden" in acct                       # shown by shell.js, absent without it
    for v in ("system", "light", "dark"):
        assert f'data-theme-set="{v}"' in acct
    assert acct.rfind("Sign out") > acct.rfind("data-theme-set")
    assert 'action="/logout"' in acct


# ------------------------------------------------------------ site name and version

def test_site_name_left_the_top_bar_but_stays_in_title_and_footer(tmp_path, world):
    t = adm(tmp_path, world, tweak=lambda d: d["site"].update({"name": "Example Lab"})).get("/status").text
    assert "Example Lab" not in top(t)
    assert re.search(r"<title>[^<]*· Example Lab</title>", t)
    assert "Example Lab" in t.split('<footer class="foot">', 1)[1]


def test_version_is_in_the_footer_and_not_on_the_home_healthy_line(tmp_path, world):
    t = adm(tmp_path, world).get("/").text
    assert "Tockmox v0.8.0" in t.split('<footer class="foot">', 1)[1] or "Tockmox 0.8.0" in t.split('<footer class="foot">', 1)[1]
    line = t.split('class="healthy-line"', 1)[1].split("</p>", 1)[0] if 'class="healthy-line"' in t else ""
    assert "Tockmox" not in line


def test_version_redirects_to_platform_updates(tmp_path, world):
    c = adm(tmp_path, world)
    r = c.get("/version")
    assert r.status_code == 308 and r.headers["location"] == "/platform/updates"
    assert "<h1>Updates</h1>" in c.get("/platform/updates").text


def test_about_is_open_to_every_signed_in_user_and_shows_what_runs(tmp_path, world):
    t = member(tmp_path, world).get("/about").text
    assert "<h1>About Tockmox</h1>" in t and 'id="notes"' in t and "Apache-2.0" in t
    assert ">Updates</a>" not in t.split("<main", 1)[1]           # the update path is the admins'
    assert make_client(tmp_path, world).get("/about").status_code == 302   # signed out: sign in first


def test_platform_updates_is_for_admins(tmp_path, world):
    assert member(tmp_path, world).get("/platform/updates").status_code == 403


# ------------------------------------------------------------ theme and the one script

def test_shell_js_loads_before_every_stylesheet(tmp_path, world):
    t = adm(tmp_path, world).get("/").text
    head = t.split("</head>", 1)[0]
    js = head.find('<script src="/static/kit/shell.js')
    assert js != -1 and js < head.find('<link rel="stylesheet"')
    assert len(re.findall(r"<script", t)) == 1                     # no inline script, no second file
    assert not re.search(r"\son[a-z]+\s*=", t)                    # no inline handlers


def test_shell_js_is_served_from_this_origin(tmp_path, world):
    r = adm(tmp_path, world).get("/static/kit/shell.js")
    assert r.status_code == 200 and "tockmox-theme" in r.text and "prefers-color-scheme: light" in r.text


def test_the_light_theme_tokens_and_state_colours_exist():
    kit = HERE / "app" / "static" / "kit"
    assert '[data-theme="light"]' in (kit / "tockmox-tokens.css").read_text()
    base = (kit / "kit-base.css").read_text()
    assert '[data-theme="light"]' in base and "--st-warning:" in base.split('[data-theme="light"]', 1)[1]


def test_the_signed_out_recovery_page_has_no_menus(tmp_path, world):
    t = make_client(tmp_path, world).get("/recovery").text
    assert "menu-d" not in t and "hpill" not in t and "Documentation" in t


def test_the_pill_says_what_the_verdict_says_when_no_row_explains_it():
    # Fresh-eyes review (claude-sonnet-5-5 via the gateway), finding 3: colour and words never disagree.
    assert nav.health("warning", [])["parts"] == ["Warning"]
    assert nav.health("critical", [])["parts"] == ["Problem"]
    assert nav.health("unknown", [])["parts"] == ["Status unknown"]


def test_admins_see_every_installed_feature_in_the_platform_rail():
    # Review finding 1: a feature members may open must not vanish for admins.
    from types import SimpleNamespace as NS
    tabs = [NS(id="posture", name="Security posture", admin_only=True), NS(id="media", name="Media", admin_only=False)]
    labels = [i.label for g in nav.rail("platform", True, False, admin_tabs=tabs) for i in g.items]
    assert "Security posture" in labels and "Media" in labels

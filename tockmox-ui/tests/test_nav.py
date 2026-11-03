# SPDX-License-Identifier: Apache-2.0
"""Unit tests for app/nav.py (sections, rail, health pill wording, Help for this page).

Drafted by a local model (local-medium on the inference node) from nav.py alone, reviewed, kept as written:
all 14 passed on the first run."""
import types
from app import nav


def test_section_of_mappings():
    assert nav.section_of("/") == "home"
    assert nav.section_of("/status") == "status"
    assert nav.section_of("/status/backup") == "status"
    assert nav.section_of("/models") == "ai"
    assert nav.section_of("/models/inbox") == "ai"
    assert nav.section_of("/nodes") == "ai"
    assert nav.section_of("/nodes/abc") == "ai"
    assert nav.section_of("/platform") == "platform"
    assert nav.section_of("/capabilities") == "platform"
    assert nav.section_of("/upgrade") == "platform"
    assert nav.section_of("/version") == "platform"
    assert nav.section_of("/tabs/posture") == "platform"
    assert nav.section_of("/about") is None
    assert nav.section_of("/recovery") is None
    assert nav.section_of("/unknown") is None


def test_platform_home():
    assert nav.platform_home(True) == "/platform"
    assert nav.platform_home(False) == "/capabilities"


def test_sections_admin():
    items = nav.sections(is_admin=True, platform_on=True)
    labels = [i.label for i in items]
    assert labels == ["Home", "Status", "AI", "Platform"]
    # Check hrefs
    assert items[0].href == "/"
    assert items[1].href == "/status"
    assert items[2].href == "/models"
    assert items[3].href == "/platform"


def test_sections_non_admin():
    # Non-admin sees Home + non-admin tabs
    tab1 = types.SimpleNamespace(id="t1", name="Tab1", admin_only=False)
    tab2 = types.SimpleNamespace(id="t2", name="Tab2", admin_only=True)
    items = nav.sections(is_admin=False, platform_on=False, user_tabs=(tab1, tab2))
    labels = [i.label for i in items]
    assert labels == ["Home", "Tab1"]
    assert items[1].href == "/tabs/t1"


def test_current_longest_prefix():
    # Create items similar to rail for AI section
    models_item = nav.Item("Models", "/models", ("/models/a/", "/models/c/"))
    inbox_item = nav.Item("Inbox", "/models/inbox")
    nodes_item = nav.Item("Inference nodes", "/nodes", ("/nodes",))

    items = [models_item, inbox_item, nodes_item]

    # The exact href (13 characters) beats every prefix; Models claims nothing under /models/inbox.
    assert nav.current(items, "/models/inbox") is inbox_item

    # A path under one of Models' prefixes lights Models.
    assert nav.current(items, "/models/a/x") is models_item

    # A node page lights Inference nodes.
    assert nav.current(items, "/nodes/abc") is nodes_item


def test_rail_home_and_status():
    assert nav.rail("home", is_admin=True, platform_on=True) == []
    assert nav.rail("status", is_admin=True, platform_on=True) == []


def test_rail_non_admin():
    assert nav.rail("ai", is_admin=False, platform_on=True) == []
    assert nav.rail("platform", is_admin=False, platform_on=True) == []


def test_rail_ai():
    groups = nav.rail("ai", is_admin=True, platform_on=True, inbox_count=5)
    assert len(groups) == 2
    assert groups[0].heading == "Models"
    assert groups[1].heading == "Hardware"

    # Check Inbox count
    inbox_item = groups[0].items[1]
    assert inbox_item.label == "Inbox"
    assert inbox_item.count == 5


def test_rail_platform_operations_visibility():
    # platform_on=False: No Operations group
    groups_off = nav.rail("platform", is_admin=True, platform_on=False)
    headings_off = [g.heading for g in groups_off]
    assert "Operations" not in headings_off
    assert "Configuration" in headings_off

    # platform_on=True: Operations group present
    groups_on = nav.rail("platform", is_admin=True, platform_on=True)
    headings_on = [g.heading for g in groups_on]
    assert "Operations" in headings_on
    assert "Configuration" in headings_on


def test_rail_platform_updates():
    groups = nav.rail("platform", is_admin=True, platform_on=True)
    # Find Configuration group
    conf_group = next(g for g in groups if g.heading == "Configuration")
    updates_item = next(i for i in conf_group.items if i.label == "Updates")

    # Updates should light up for /upgrade and /version
    assert nav.current([updates_item], "/upgrade") is updates_item
    assert nav.current([updates_item], "/version") is updates_item
    assert nav.current([updates_item], "/platform/updates") is updates_item


def test_rail_current():
    groups = nav.rail("ai", is_admin=True, platform_on=True)
    # /models/inbox
    item = nav.rail_current(groups, "/models/inbox")
    assert item is not None
    assert item.label == "Inbox"

    # /models
    item = nav.rail_current(groups, "/models")
    assert item is not None
    assert item.label == "Models"


def test_health_wording():
    # 1 problem
    h = nav.health("bad", [{"state": "critical"}])
    assert h["parts"] == ["1 problem"]
    assert h["label"] == "1 problem. Open Status."

    # 2 warnings
    h = nav.health("warn", [{"state": "warning"}, {"state": "warning"}])
    assert h["parts"] == ["2 warnings"]
    assert h["label"] == "2 warnings. Open Status."

    # Plural forms: 2 problems
    h = nav.health("bad", [{"state": "critical"}, {"state": "critical"}])
    assert h["parts"] == ["2 problems"]

    # All healthy
    h = nav.health("ok", [])
    assert h["parts"] == ["All healthy"]
    assert h["label"] == "All healthy. Open Status."

    # Unknown verdict with no rows
    h = nav.health("unknown", [])
    assert h["parts"] == ["Status unknown"]
    assert h["label"] == "Status unknown. Open Status."

    # Mixed
    h = nav.health("bad", [{"state": "critical"}, {"state": "warning"}, {"state": "unknown"}])
    assert h["parts"] == ["1 problem", "1 warning", "1 unknown"]
    assert h["label"] == "1 problem, 1 warning, 1 unknown. Open Status."


def test_help_for():
    # Exact match
    assert nav.help_for("/status") == "administration/tockmox-ui.md"
    assert nav.help_for("/models") == "administration/model-lifecycle.md"

    # Longest prefix
    # /platform/updates is in map
    assert nav.help_for("/platform/updates") == "deployment/upgrade.md"

    # /platform/agents should match /platform
    assert nav.help_for("/platform/agents") == "administration/platform-management.md"

    # /models/inbox should match /models
    assert nav.help_for("/models/inbox") == "administration/model-lifecycle.md"

    # None for unmapped
    assert nav.help_for("/nope") is None
    assert nav.help_for("/unknown/path") is None


def test_docs_href():
    # With docs site URL
    url = nav.docs_href("https://docs.example.com", "https://github.com/repo", "administration/tockmox-ui.md")
    assert url == "https://docs.example.com/administration/tockmox-ui.html"

    # Without docs site URL
    url = nav.docs_href("", "https://github.com/repo", "administration/tockmox-ui.md")
    assert url == "https://github.com/repo/administration/tockmox-ui.md"

    # Trailing slash handling
    url = nav.docs_href("https://docs.example.com/", "https://github.com/repo/", "administration/tockmox-ui.md")
    assert url == "https://docs.example.com/administration/tockmox-ui.html"
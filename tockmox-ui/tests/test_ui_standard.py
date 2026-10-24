# SPDX-License-Identifier: Apache-2.0
"""The UI standard's page rules that are easy to break quietly (TM-1127 follow-up, 2026-10-23)."""
import re
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.sources import Reading  # noqa: E402
from app import views  # noqa: E402
from tests.test_status_api import World, admin, app_obj  # noqa: E402,F401


@pytest.fixture
def world():
    return World()


def _everything_else(t):
    return t.split('id="healthy-h"', 1)[1]


def test_stylesheets_carry_a_version_and_static_revalidates(tmp_path, world):
    c = admin(tmp_path, world)
    t = c.get("/").text
    m = re.search(r'href="/static/app\.css\?v=([0-9a-f]{10})"', t)
    assert m, "app.css is linked without a version"
    assert f'href="/static/brand/tockmox-tokens.css?v={m.group(1)}"' in t
    r = c.get("/static/app.css")
    assert r.status_code == 200 and r.headers.get("cache-control") == "no-cache"
    assert c.get("/").headers.get("cache-control") == "no-store"


def test_a_failing_group_folds_as_its_healthy_part_with_a_pointer(tmp_path, world):
    world.apps.append(app_obj("broken", health="Degraded"))
    t = admin(tmp_path, world).get("/status").text
    rest = _everything_else(t)
    n = len(world.apps)
    assert f"{n - 1} of {n} applications · 1 in Problems above" in rest
    assert "st-critical" not in rest.split("</summary>")[0], "a fold row wears a Problem badge"
    assert "broken" in t.split('id="healthy-h"', 1)[0], "the failing app is not a Problems row"


def test_source_lines_have_no_space_before_the_colon(tmp_path, world):
    """The space came from the flex gap in .src, not from the text: the name and its reason must sit
    inside one wrapper span, never as separate flex children of .src."""
    t = admin(tmp_path, world).get("/status").text
    n = t.count('class="src-name"')
    assert n >= 4
    assert t.count('<span><span class="src-name">') == n


def test_the_alerting_pipeline_line_says_where_the_firing_alerts_are(tmp_path, world):
    world.alerts.append({"labels": {"alertname": "KubePodNotReady", "severity": "warning"}, "annotations": {"summary": "x"}})
    rest = _everything_else(admin(tmp_path, world).get("/status").text)
    assert "1 firing, listed above" in rest


def test_one_time_format_just_now_then_compact():
    now = time.time()
    r = Reading("Argo CD applications", "ok", [], "", now, now)
    assert r.age_text(now + 2) == "just now"
    assert r.age_text(now + 12) == "12s ago"
    assert r.age_text(now + 180) == "3m ago"
    assert views.sources_sentence({"a": r}).endswith("answered just now.")

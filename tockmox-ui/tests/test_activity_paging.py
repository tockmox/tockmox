# SPDX-License-Identifier: Apache-2.0
"""Activity reaches every action the record keeps, not only the newest 100, and says how many it shows of how many
are kept ("Showing 100 of 250 kept"), with Newer and Older links a page of 100 at a time.

The console's /v1/activity calls go through the real actions service endpoint (app.actions_service.create_service)
in-process, so its limit is the one that applies here, not a fake that hands back every row.
Run from tockmox-ui/: python -m pytest tests/test_activity_paging.py
"""
import json
import re
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions_routes  # noqa: E402
from app import actions_service as svcmod  # noqa: E402
from tests import test_actions as ta  # noqa: E402


class _HttpxWithRealActivity:
    """httpx as tests.test_actions sees it, except that the console's bridge sends GET /v1/activity to the real
    service endpoint, limit and all."""

    def __init__(self, svc_box):
        self._box = svc_box

    def __getattr__(self, name):
        return getattr(httpx, name)

    def MockTransport(self, handler):  # noqa: N802 - the name console() calls
        if getattr(handler, "__name__", "") != "bridge":
            return httpx.MockTransport(handler)
        box = self._box

        def routed(req: httpx.Request):
            if req.url.path == "/v1/activity":
                from fastapi.testclient import TestClient
                r = TestClient(svcmod.create_service(service=box["svc"])).get(
                    "/v1/activity", params=dict(req.url.params))
                return httpx.Response(r.status_code, content=r.content,
                                      headers={"content-type": r.headers.get("content-type", "")})
            return handler(req)
        return httpx.MockTransport(routed)


def _row(i):
    return {"key": f"k-{i:03d}", "nonce": "n", "at": 1_795_000_000 - i * 60, "sub": "a", "who": "Jeff",
            "kind": "test-alert", "target": {}, "summary": f"Action number {i:03d}", "result": "done",
            "detail": "", "ref": [], "until": None}


@pytest.fixture
def activity(tmp_path, monkeypatch):
    """A console whose activity record holds n rows, newest first, row i summarised "Action number i"."""
    box = {}
    real_service = ta.service

    def keep(*a, **kw):
        out = real_service(*a, **kw)
        box["svc"] = out[0]
        return out
    monkeypatch.setattr(ta, "service", keep)
    monkeypatch.setattr(ta, "httpx", _HttpxWithRealActivity(box))

    def make(n):
        c, _, _, _, kube, _ = ta.console(tmp_path)
        kube.cm = {"metadata": {"name": "tockmox-actions-activity", "resourceVersion": "1"},
                   "data": {"activity.json": json.dumps([_row(i) for i in range(1, n + 1)])}}
        return c
    return make


def shown(t):
    """The row numbers a page lists, in order."""
    return [int(x) for x in re.findall(r"Action number (\d{3})", t)]


def test_the_console_asks_for_every_row_the_service_keeps():
    assert actions_routes.ACTIVITY_READ == svcmod.ACTIVITY_MAX


def test_the_first_page_shows_the_newest_100_and_says_how_many_are_kept(activity):
    c = activity(250)
    r = c.get("/platform/activity")
    assert r.status_code == 200
    assert shown(r.text) == list(range(1, 101))
    assert "Showing 100 of 250 kept" in r.text and "1 to 100" in r.text
    assert 'href="/platform/activity?page=2"' in r.text and "Older" in r.text
    assert "?page=0" not in r.text and "Newer" not in r.text


def test_rows_past_100_are_reachable_a_page_at_a_time(activity):
    c = activity(250)
    t2 = c.get("/platform/activity?page=2").text
    assert shown(t2) == list(range(101, 201))
    assert "Showing 100 of 250 kept" in t2 and "101 to 200" in t2
    assert 'href="/platform/activity?page=1"' in t2 and 'href="/platform/activity?page=3"' in t2
    t3 = c.get("/platform/activity?page=3").text
    assert shown(t3) == list(range(201, 251))                     # the oldest one kept is on the last page
    assert "Showing 50 of 250 kept" in t3 and "201 to 250" in t3
    assert "Older" not in t3 and 'href="/platform/activity?page=2"' in t3


def test_a_full_record_reaches_its_oldest_row_and_says_older_ones_are_in_loki_only(activity):
    c = activity(svcmod.ACTIVITY_MAX)
    t1 = c.get("/platform/activity").text
    assert f"Showing 100 of {svcmod.ACTIVITY_MAX} kept" in t1
    assert f"keeps the last {svcmod.ACTIVITY_MAX}" in t1 and "Loki" in t1
    last = c.get("/platform/activity?page=3").text
    assert shown(last)[-1] == svcmod.ACTIVITY_MAX


def test_a_record_that_is_not_full_does_not_send_anyone_to_loki_for_older_rows(activity):
    t = activity(250).get("/platform/activity").text
    assert "keeps the last" not in t


def test_one_page_shows_everything_with_no_paging_links(activity):
    t = activity(12).get("/platform/activity").text
    assert shown(t) == list(range(1, 13))
    assert "Showing 12 of 12 kept" in t
    assert "?page=" not in t and "Older" not in t and "Newer" not in t


@pytest.mark.parametrize("page, rows", [("0", range(1, 101)), ("-4", range(1, 101)), ("x", range(1, 101)),
                                        ("", range(1, 101)), ("99", range(201, 251)), ("2.5", range(1, 101))])
def test_a_page_that_does_not_exist_lands_on_the_nearest_one_that_does(activity, page, rows):
    r = activity(250).get(f"/platform/activity?page={page}")
    assert r.status_code == 200
    assert shown(r.text) == list(rows)

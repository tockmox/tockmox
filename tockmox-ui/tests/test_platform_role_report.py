# SPDX-License-Identifier: Apache-2.0
"""Platform Management: each role reports on its area in four blocks, and the Overview opens on its tiles.

Every role page opens on the same four blocks, read from live sources: what it watches (its signals by name), what it
logged since the viewer last looked, its open items, and its health. The Overview opens on four counts, each naming
where it comes from. A source that is not connected or did not answer says so in words, in the block or tile that
needed it, and never reads as an empty list or a healthy value."""
import copy
import json
import os
import time
from datetime import datetime, timezone

import httpx

from tests.proto_support import ROOT, login_as  # noqa: F401
from tests.proto_support import _secret, world  # noqa: F401  (fixtures)
from tests.test_platform import Ledger, add_cronjob, doc_with_platform, healthy_signals
from tests.test_platform_cases import FIX, HOST, Host
from app import config as cfgmod
from app import platform as pm
from app.main import Transports, create_app
from fastapi.testclient import TestClient

LEDGER = "https://ledger.example"
BLOCKS = ("rb-watches", "rb-logged", "rb-open", "rb-health")


def _iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def fresh_desk(ago=3600):
    """The desk fixture with every record's activity moved to `ago` seconds before now, so "since you last looked"
    does not depend on the day the suite runs."""
    fix = copy.deepcopy(FIX)
    t = _iso(time.time() - ago)
    for r in fix["list"]["records"]:
        for k in ("updated", "state_since", "created"):
            if r.get(k):
                r[k] = t
        if isinstance(r.get("waiting"), dict) and r["waiting"].get("since"):
            r["waiting"]["since"] = t
    return fix


def live_client(world, host=None, ledger=None, desk=True, led=True, cronworkflows=()):
    """Every source the role pages read: Prometheus, Argo (an empty answer), the desk and the ledger."""
    opts = {}
    if desk:
        opts["specialistsUrl"] = HOST
    if led:
        opts["ledgerUrl"] = LEDGER
    s = cfgmod.parse(doc_with_platform(**opts))
    kube_h = world.handler("kube")

    def kube(req):
        if req.url.path.endswith("/cronworkflows") or req.url.path.endswith("/workflows"):
            if "kube" in world.down:
                raise httpx.ConnectError("refused", request=req)
            return httpx.Response(200, json={"items": list(cronworkflows)})
        return kube_h(req)
    host = host or Host(fix=fresh_desk())
    ledger = ledger or Ledger()
    tp = Transports(kube=httpx.MockTransport(kube), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")),
                    ledger=httpx.MockTransport(ledger.handler), specialists=httpx.MockTransport(host.handler))
    app = create_app(s, tp, notes_path=os.path.join(ROOT, "tests", "fixtures", "none.md"))
    c = TestClient(app, follow_redirects=False)
    login_as(c, s, ["tockmox-admins"])
    return c


def block(page, bid):
    """The HTML of one block, from its heading to the end of its section."""
    i = page.index(f'id="{bid}"')
    return page[i:page.index("</section>", i)]


def tile(page, tid):
    i = page.index(f'id="tile-{tid}"')
    return page[i:page.index("</li>", i)]


# ---------------------------------------------------------------- the format: every role, four blocks, live data

def test_every_role_page_opens_on_the_four_blocks(world):
    healthy_signals(world)
    c = live_client(world)
    for a in pm.load_catalog().all():
        t = c.get(f"/platform/agents/{a.id}").text
        at = [t.find(f'id="{b}"') for b in BLOCKS]
        assert all(i > 0 for i in at), (a.id, at)
        assert at == sorted(at), f"{a.id}: the blocks are out of order"
        assert at[-1] < t.index('id="scope"'), f"{a.id}: the blocks do not open the page"
        w = block(t, "rb-watches")
        for sig in a.signals:
            assert sig.label in w, (a.id, sig.label)


def test_the_blocks_read_live_data(world):
    healthy_signals(world)
    q = next(s.query for s in pm.load_catalog().get("incident").signals if s.id == "warnings")
    world.series[q] = [({}, 3)]
    now = time.time()
    add_cronjob(world, "monitoring", "alert-relay-check", "*/5 * * * *", last_run=now - 120, last_ok=now - 120 + 5)
    ledger = Ledger(jobs=[{"id": "job-41", "profile": "incident", "status": "completed", "created": _iso(now - 600)},
                          {"id": "job-42", "profile": "incident", "status": "input_required", "created": _iso(now - 300)}])
    c = live_client(world, ledger=ledger)
    t = c.get("/platform/agents/incident").text

    w = block(t, "rb-watches")
    assert "Warnings firing" in w and ">3<" in w and "st-warning" in w          # the live value and its state, by name

    lg = block(t, "rb-logged")
    assert "has not opened this page" in lg                                   # a first look says so
    for rid in ("INC-0001", "INC-0002", "INC-0003"):                          # its cases' activity in the last day
        assert f"/platform/cases/{rid}" in lg, rid
    assert "CHG-0001" not in lg, "the change is the Change Manager's"
    assert "job-41" in lg and "job-42" in lg                                  # its agent's runs
    assert "alert-relay-check" in lg                                          # its scheduled job ran

    op = block(t, "rb-open")
    assert "INC-0002" in op and "Waiting on you" in op and "Approve a restore no standard change covers" in op
    assert "INC-0003" not in op, "a closed case is not an open item"
    assert "job-42" in op and "waits on your decision" in op

    h = block(t, "rb-health")
    assert "st-warning" in h and "Warnings firing" in h                       # the practice, and why
    assert "Waiting on you" in h                                              # the agent, from the ledger


def test_since_you_last_looked_is_the_viewers_own_and_moves(world):
    healthy_signals(world)
    c = live_client(world)
    r = c.get("/platform/agents/incident")
    assert "has not opened this page" in block(r.text, "rb-logged")
    set_cookie = r.headers.get("set-cookie", "")
    assert set_cookie.startswith("tmx_seen_incident=") and "Path=/platform" in set_cookie and "HttpOnly" in set_cookie
    # opened again: the desk's activity (an hour ago) is older than the last look, and every source answered
    lg = block(c.get("/platform/agents/incident").text, "rb-logged")
    assert "when this browser last opened this page" in lg
    assert "/platform/cases/" not in lg
    assert "Nothing logged since then. Every source it reports through answered." in lg
    # a cookie that is not a time is a first look, never an error
    for ck in c.cookies.jar:
        if ck.name == "tmx_seen_incident":
            ck.value = "not-a-time"
    assert "has not opened this page" in block(c.get("/platform/agents/incident").text, "rb-logged")


# ---------------------------------------------------------------- a source that is down says so, in words

def test_a_desk_that_does_not_answer_says_so_in_each_block_that_needs_it(world):
    healthy_signals(world)
    c = live_client(world, host=Host(down=True))
    t = c.get("/platform/agents/incident").text
    for bid in ("rb-logged", "rb-open"):
        b = block(t, bid)
        assert "Service Desk did not answer" in b, bid
        assert "Every source it reports through answered" not in b, bid
    assert "That is not the same as none." in block(t, "rb-open")


def test_a_ledger_that_does_not_answer_says_so(world):
    healthy_signals(world)
    c = live_client(world, ledger=Ledger(down=True))
    t = c.get("/platform/agents/incident").text
    for bid in ("rb-logged", "rb-open"):
        b = block(t, bid)
        assert "Agent ledger did not answer" in b, bid
        assert "Every source it reports through answered" not in b, bid


def test_prometheus_down_is_words_in_watches_and_health_never_a_healthy_value(world):
    world.down.add("prometheus")
    c = live_client(world)
    t = c.get("/platform/agents/capacity").text
    w = block(t, "rb-watches")
    assert "Practice signals (Prometheus) did not answer" in w and "That is not the same as healthy." in w
    assert "st-ok" not in w, "a signal reads healthy while Prometheus is down"
    assert "0 deployed" not in w and "deployed: unknown" in w, "a count of jobs from a source that did not answer"
    h = block(t, "rb-health")
    assert "did not answer" in h
    assert "every signal and scheduled job is healthy" not in h.lower()
    assert "st-ok" not in h.split("Agent")[0], "the practice reads healthy while Prometheus is down"


def test_sources_not_connected_are_named_not_empty(world):
    healthy_signals(world)
    c = live_client(world, desk=False, led=False)
    t = c.get("/platform/agents/incident").text
    for bid in ("rb-logged", "rb-open"):
        b = block(t, bid)
        assert "No Service Desk is connected" in b and "No agent ledger is connected" in b, bid
        assert "Every source it reports through answered" not in b, bid


# ---------------------------------------------------------------- the Overview's tiles

def test_the_overview_opens_on_four_tiles_from_live_data(world):
    healthy_signals(world)
    c = live_client(world)
    t = c.get("/platform").text
    assert t.index('id="pm-tiles"') < t.index('id="needs-you"')
    assert ">2<" in tile(t, "waiting") and "From the Service Desk and the agent ledger." in tile(t, "waiting")
    assert ">4<" in tile(t, "cases") and "From the Service Desk." in tile(t, "cases")     # four open records
    assert ">0<" in tile(t, "jobs") and "kube-state-metrics and Argo" in tile(t, "jobs")
    p = tile(t, "practices")
    assert " of " in p and "From live signals and scheduled jobs." in p and "st-ok" in p


def test_a_tile_whose_source_is_down_says_so_and_shows_no_count(world):
    healthy_signals(world)
    c = live_client(world, host=Host(down=True), ledger=Ledger(down=True))
    t = c.get("/platform").text
    for tid in ("waiting", "cases"):
        x = tile(t, tid)
        assert ">Unknown<" in x and "did not answer" in x, tid
        assert ">0<" not in x, tid
    world.down.add("prometheus")
    t = live_client(world).get("/platform").text
    for tid in ("practices", "jobs"):
        x = tile(t, tid)
        assert ">Unknown<" in x and "did not answer" in x, tid
        assert "st-ok" not in x, tid


def test_tiles_not_connected_are_named(world):
    healthy_signals(world)
    t = live_client(world, desk=False, led=False).get("/platform").text
    assert ">Not connected<" in tile(t, "waiting") and "That is not the same as nothing waiting." in tile(t, "waiting")
    assert ">Not connected<" in tile(t, "cases") and "No Service Desk is connected" in tile(t, "cases")


def test_the_role_page_still_writes_nothing(world):
    healthy_signals(world)
    host = Host(fix=fresh_desk())
    c = live_client(world, host=host)
    c.get("/platform/agents/incident"); c.get("/platform")
    ops = {r.url.path.rsplit("/", 1)[-1] for r in host.seen if r.method == "POST"}
    assert ops <= {"list", "get"}, ops
    assert c.post("/platform/agents/incident").status_code in (403, 404, 405)


def test_the_fixture_is_the_desk_contract():
    """fresh_desk moves times only; ids, roles and waits are the desk's own."""
    a, b = FIX["list"]["records"], fresh_desk()["list"]["records"]
    strip = lambda rs: json.dumps([{k: v for k, v in r.items() if k not in ("updated", "state_since", "created", "waiting")}
                                   for r in rs], sort_keys=True)
    assert strip(a) == strip(b)

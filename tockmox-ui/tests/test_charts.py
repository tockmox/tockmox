# SPDX-License-Identifier: Apache-2.0
"""TM-1306 (absorbs TM-1016): trend panels from the data Grafana graphs, drawn server-side; TM-1307: Home from parts;
TM-1310: the mascot at a moment (specs/tockmox-ui/SPEC.md sections 4, 6 and 11 in the planning repo).

  panels     one file, panels.yaml; every PromQL there once; the Tockmox / Status board is generated from it
  reading    a failed or an empty range query reads Unknown with a reason, never a flat zero
  drawing    SVG with a text alternative carrying the numbers; links to the board by UID
  Home       Everything is running with no chips; a problem names its part; the strip links each band on Status
  mascot     one per screen, alt="", never in the top bar, rail, menus, tables or the drawer

Run from tockmox-ui/: python -m pytest tests
"""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import charts, stack  # noqa: E402
from tests.test_status_api import World, app_obj, make_client  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
NOW = 1_800_000_000.0


def answer(series):
    """A query_range answer: series is [(labels, [(t, v), ...])]."""
    return {"status": "success", "data": {"resultType": "matrix",
                                          "result": [{"metric": m, "values": [[t, str(v)] for t, v in pts]} for m, pts in series]}}


def reader(handler):
    return charts.RangeReader("http://prom", 1, httpx.MockTransport(handler), clock=lambda: NOW)


def P(pid):
    return charts.load()[pid]


# ------------------------------------------------------------ the panels file

def test_every_shipped_panel_parses_and_names_a_page():
    ps = charts.load()
    assert len(ps) >= 15
    pages = {p.page for p in ps.values()}
    assert {"status", "ai-nodes", "ai-models", "platform", "part"} <= pages
    assert sum(1 for p in ps.values() if p.page == "status") == 6       # the spec's 24-hour row


@pytest.mark.parametrize("bad", [
    {"version": 1, "panels": [{"id": "x", "page": "nowhere", "title": "t", "expr": "up", "unit": "count", "range": "1h", "step": "1m", "describe": "d"}]},
    {"version": 1, "panels": [{"id": "x", "page": "status", "title": "t", "expr": "up", "unit": "furlongs", "range": "1h", "step": "1m", "describe": "d"}]},
    {"version": 1, "panels": [{"id": "x", "page": "status", "title": "t", "expr": "up", "unit": "count", "range": "1 week", "step": "1m", "describe": "d"}]},
    {"version": 1, "panels": [{"id": "x", "page": "status", "title": "t", "expr": "up{namespace=~\"{namespaces}\"}", "unit": "count", "range": "1h", "step": "1m", "describe": "d"}]},
    {"version": 1, "panels": [{"id": "x", "page": "status", "title": "t", "expr": "up", "unit": "count", "range": "1h", "step": "1m"}]},
    {"version": 2, "panels": []},
])
def test_a_malformed_panel_is_refused(bad):
    with pytest.raises(charts.PanelError):
        charts.parse(bad)


def test_every_stack_trend_names_a_part_panel():
    ps = charts.load()
    s = stack.load()
    for p in list(s.side) + [p for b in s.bands for p in b.parts]:
        if p.trend:
            assert p.trend in ps and ps[p.trend].page == "part", (p.id, p.trend)


def test_the_status_board_is_generated_from_the_same_expressions():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen-dashboard-status.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    board = json.loads((ROOT / "charts" / "tockmox-observability" / "dashboards" / "status.json").read_text())
    assert board["uid"] == "tockmox-status"
    on_board = {p["title"]: p["targets"][0]["expr"] for p in board["panels"] if p["type"] == "timeseries"}
    for p in charts.load().values():
        if p.page != "part":
            assert on_board[p.title] == p.expr, p.id
    # the UI's ?viewPanel=<n> is the panel's 1-based position among the board's panels in file order
    order = [p.id for p in charts.load().values() if p.page != "part"]
    by_id = {p["id"]: p["title"] for p in board["panels"] if p["type"] == "timeseries"}
    for i, pid in enumerate(order):
        assert by_id[i + 1] == charts.load()[pid].title


# ------------------------------------------------------------ reading: absence is not green

def test_a_failed_query_reads_unknown_with_a_reason():
    v = charts.read(reader(lambda req: httpx.Response(503)), P("scrape-health"))
    assert v.state == "unknown" and "did not answer" in v.reason and not v.series
    assert "Unknown" in charts.alt(v)


def test_an_unreachable_prometheus_reads_unknown():
    def h(req):
        raise httpx.ConnectError("refused", request=req)
    v = charts.read(reader(h), P("scrape-health"))
    assert v.state == "unknown" and v.reason


def test_an_empty_answer_reads_unknown_never_zero():
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer([]))), P("fullest-volume"))
    assert v.state == "unknown" and v.reason == "no data in this window" and v.last is None


def test_nan_points_are_dropped_and_an_all_nan_series_is_no_data():
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer([({}, [(NOW - 60, "NaN"), (NOW, "NaN")])]))), P("fullest-volume"))
    assert v.state == "unknown"


def test_not_configured_reads_unknown():
    v = charts.read(charts.RangeReader("", 1), P("scrape-health"))
    assert v.state == "unknown" and "not configured" in v.reason


def test_thresholds_set_the_state_both_ways():
    up = lambda val: reader(lambda req: httpx.Response(200, json=answer([({}, [(NOW - 900, val), (NOW, val)])])))  # noqa: E731
    assert charts.read(up(95), P("fullest-volume")).state == "critical"       # high is bad
    assert charts.read(up(85), P("fullest-volume")).state == "warning"
    assert charts.read(up(40), P("fullest-volume")).state == "ok"
    assert charts.read(up(5), P("cert-expiry")).state == "critical"           # low is bad (below: true)
    assert charts.read(up(10), P("cert-expiry")).state == "warning"
    assert charts.read(up(60), P("cert-expiry")).state == "ok"


def test_alerts_by_severity_go_critical_only_for_a_critical_alert():
    one_warn = answer([({"severity": "warning"}, [(NOW, 1)]), ({"severity": "critical"}, [(NOW, 0)])])
    one_crit = answer([({"severity": "warning"}, [(NOW, 0)]), ({"severity": "critical"}, [(NOW, 2)])])
    assert charts.read(reader(lambda req: httpx.Response(200, json=one_warn)), P("alerts-firing")).state == "warning"
    v = charts.read(reader(lambda req: httpx.Response(200, json=one_crit)), P("alerts-firing"))
    assert v.state == "critical" and v.last == 2


def test_the_query_is_a_coarse_cached_range_query():
    seen = []

    def h(req):
        seen.append(dict(req.url.params))
        return httpx.Response(200, json=answer([({}, [(NOW, 1)])]))
    r = reader(h)
    charts.read(r, P("scrape-health"))
    charts.read(r, P("scrape-health"))
    assert len(seen) == 1                                          # cached for a minute
    q = seen[0]
    assert q["step"] == "900" and float(q["end"]) - float(q["start"]) == 86400 and float(q["end"]) % 900 == 0


def test_namespaces_are_bound_from_dns_labels_only():
    p = P("part-alerts")
    assert 'namespace=~"forgejo|tockmox-ai"' in charts.bind(p, ["forgejo", "tockmox-ai"])
    assert charts.bind(p, ['x"} or vector(1) #']) == ""          # never interpolates anything else
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer([]))), p, ['x"}'])
    assert v.state == "unknown" and "names no namespace" in v.reason


# ------------------------------------------------------------ drawing

def test_the_svg_geometry_stays_inside_the_viewbox_and_the_alt_carries_the_numbers():
    pts = [(NOW - 3600 * i, 50 + i) for i in range(24, -1, -1)]
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer([({}, pts)]))), P("node-pressure"))
    for x, y in (map(float, c.split(",")) for c in v.svg["lines"][0]["d"].split()):
        assert 0 <= x <= charts.W and 0 <= y <= charts.H
    a = charts.alt(v)
    assert a.startswith("OK: now 50%") and "high 74%" in a and "Memory in use on the busiest cluster node" in a


# ------------------------------------------------------------ the pages

class PromWorld(World):
    """World whose Prometheus also answers range queries, with one value per panel."""

    def __init__(self, value=1.0):
        super().__init__()
        self.value = value
        self.range_calls = []

    def handler(self, which):
        base = super().handler(which)

        def h(req):
            if which == "prometheus" and req.url.path == "/api/v1/query_range":
                self.range_calls.append(req.url.params["query"])
                if "prometheus" in self.down:
                    raise httpx.ConnectError("refused", request=req)
                t = time.time()
                return httpx.Response(200, json=answer([({}, [(t - 3600, self.value), (t, self.value)])]))
            return base(req)
        return h


ALL = ["crds", "policy", "platform", "observability", "exporters", "identity", "ai", "selfcheck"]


@pytest.fixture
def world():
    w = PromWorld()
    w.apps = [app_obj(f"tockmox-{x}", path=f"charts/tockmox-{x}") for x in ALL]
    return w


def adm(tmp_path, world, **kw):
    return make_client(tmp_path, world, groups=["tockmox-admins"], **kw)


def mascots(t):
    return re.findall(r'<img class="mascot[^"]*"[^>]*>', t)


def test_status_draws_the_24_hour_row_with_links_to_the_board(tmp_path, world):
    t = adm(tmp_path, world).get("/status").text
    row = t.split('<section class="trends"', 1)[1].split("</section>", 1)[0]
    assert row.count('<figure class="trend') == 6
    assert 'href="https://grafana.int.example.com/d/tockmox-status?viewPanel=1"' in row
    assert 'href="https://grafana.int.example.com/d/tockmox-storage-contract"' in row
    assert "<iframe" not in t


def test_with_prometheus_down_every_panel_says_unknown(tmp_path, world):
    world.down.add("prometheus")
    t = adm(tmp_path, world).get("/status").text
    row = t.split('<section class="trends"', 1)[1].split("</section>", 1)[0]
    assert row.count("st-unknown") == 6 and "<polyline" not in row and "did not answer" in row


def test_the_drawer_shows_the_parts_own_seven_days(tmp_path, world):
    t = adm(tmp_path, world).get("/status/storage").text
    aside = t.split("<aside", 1)[1].split("</aside>", 1)[0]
    assert "Last 7 days" in aside and 'data-panel="part-volume"' in aside
    assert any("kubelet_volume_stats_available_bytes" in q for q in world.range_calls)


def test_ai_and_platform_pages_draw_their_panels(tmp_path, world):
    c = adm(tmp_path, world)
    assert c.get("/models").text.count('<figure class="trend') == 4
    assert c.get("/nodes").text.count('<figure class="trend') == 2


def test_members_get_no_panels_and_no_range_queries(tmp_path, world):
    make_client(tmp_path, world, groups=["tockmox-users"]).get("/")
    assert world.range_calls == []


def test_home_all_ok_reads_everything_is_running_with_no_chips(tmp_path, world):
    t = adm(tmp_path, world).get("/").text
    assert '<h1 id="verdict-h">Everything is running.</h1>' in t
    assert 'class="chips"' not in t and "Needs attention" not in t
    assert 'data-pose="all-clear"' in t


def test_home_names_the_part_and_the_strip_links_each_band(tmp_path, world):
    world.apps.append(app_obj("forgejo-backup", health="Degraded"))
    world.apps.append(app_obj("forgejo"))
    t = adm(tmp_path, world).get("/").text
    h1 = t.split('<h1 id="verdict-h">', 1)[1].split("</h1>", 1)[0]
    assert h1.startswith("Forgejo has a problem: forgejo-backup application") and "Everything else is running." in h1
    assert '<a class="part st-critical" href="/status/site-forgejo">' in t
    strip = t.split('<nav class="strip"', 1)[1].split("</nav>", 1)[0]
    assert 'href="/status#band-hosts"' in strip and 'href="/status#band-site"' in strip
    assert strip.index("band-hosts") < strip.index("band-site")              # bottom of the stack on the left
    assert 'data-pose="puzzled"' in t
    # the anchor exists on Status
    assert 'id="band-hosts"' in adm(tmp_path, world).get("/status").text


@pytest.mark.parametrize("path", ["/", "/status", "/models", "/about", "/no/such/page", "/status/storage"])
def test_never_more_than_one_mascot_and_never_in_the_chrome(tmp_path, world, path):
    t = adm(tmp_path, world).get(path).text
    assert len(mascots(t)) <= 1, path
    for m in mascots(t):
        assert 'alt=""' in m and "/static/mascot/" in m and "384.webp 2x" in m
    chrome = t.split('<header class="top">', 1)[1].split("</header>", 1)[0]
    rail = re.search(r'<nav class="rail".*?</nav>', t, re.S)
    aside = t.split("<aside", 1)[1].split("</aside>", 1)[0] if "<aside" in t else ""
    for region in (chrome, rail.group(0) if rail else "", aside):
        assert "mascot" not in region


def test_a_page_that_does_not_exist_is_the_consoles_own_404(tmp_path, world):
    r = adm(tmp_path, world).get("/no/such/page")
    assert r.status_code == 404 and 'data-pose="lost"' in r.text and "<h1>Not found</h1>" in r.text
    api = adm(tmp_path, world).get("/api/v1/nope")
    assert api.status_code == 404 and api.headers["content-type"].startswith("application/json")


def test_every_pose_the_templates_name_ships_at_both_sizes():
    tpl = (ROOT / "tockmox-ui" / "app" / "templates")
    names = set()
    for f in tpl.rglob("*.html"):
        names |= set(re.findall(r'mascot\("([a-z-]+)"', f.read_text()))
        names |= set(re.findall(r'"(lost|puzzled)"', f.read_text())) if f.name == "error.html" else set()
    assert names
    for n in names:
        for px in (192, 384):
            assert (ROOT / "tockmox-ui" / "app" / "static" / "mascot" / f"tockmox-pose-{n}-{px}.webp").is_file(), (n, px)


# ------------------------------------------------------------ fresh-eyes review (claude-sonnet-5-5 via the gateway)

def test_review_a_stale_series_reads_unknown_not_its_last_value():
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer([({}, [(NOW - 20 * 3600, 95), (NOW - 19 * 3600, 95)])]))), P("fullest-volume"))
    assert v.state == "unknown" and "old" in v.reason and v.last is None and v.series


def test_review_now_is_the_current_minute_not_the_step():
    seen = []

    def h(req):
        seen.append(float(req.url.params["end"]))
        return httpx.Response(200, json=answer([({}, [(NOW, 1)])]))
    charts.read(reader(h), P("part-drill-age"))                       # a 2h step
    assert NOW - seen[0] < 60


def test_review_quiet_alerts_and_clean_gateway_read_zero_by_their_expression():
    for pid in ("alerts-firing", "platform-alerts"):
        assert P(pid).expr.endswith('or label_replace(vector(0), "severity", "critical", "", "")')
    for pid in ("ai-errors", "part-gateway-errors"):
        assert "or vector(0))" in P(pid).expr


def test_review_the_headline_counts_series_beyond_the_ones_drawn():
    ser = [({"namespace": f"ns{i}"}, [(NOW, 1)]) for i in range(7)] + [({"namespace": "old"}, [(NOW, 20)])]
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer(ser))), P("platform-drill-age"))
    assert v.state == "critical" and v.last == 20 and v.hidden == 2 and len(v.series) == 6
    assert v.series[0].name == "old"
    assert "and 2 more not drawn" in charts.alt(v)


def test_review_a_node_with_no_healthy_engine_is_a_problem():
    ser = [({"ai_node": "a"}, [(NOW, 2)]), ({"ai_node": "b"}, [(NOW, 0)])]
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer(ser))), P("ai-engines-healthy"))
    assert v.state == "critical" and v.last == 0


def test_review_one_bad_namespace_makes_the_panel_unknown():
    assert charts.bind(P("part-alerts"), ["forgejo", "Bad_NS"]) == ""


def test_review_a_single_point_is_drawn_as_a_dot():
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer([({}, [(NOW, 3)])]))), P("cert-expiry"))
    assert v.svg["lines"][0]["dot"] is True


def test_review_the_alt_says_the_state_in_words():
    v = charts.read(reader(lambda req: httpx.Response(200, json=answer([({}, [(NOW, 95)])]))), P("fullest-volume"))
    assert charts.alt(v).startswith("Problem: now 95%")


def test_review_a_down_prometheus_is_asked_once_for_a_moment():
    calls = []

    def h(req):
        calls.append(1)
        raise httpx.ConnectError("refused", request=req)
    r = reader(h)
    for pid in ("scrape-health", "fullest-volume", "cert-expiry"):
        assert charts.read(r, P(pid)).state == "unknown"
    assert len(calls) == 1

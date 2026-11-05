# SPDX-License-Identifier: Apache-2.0
"""Feature pages (app/feature_pages.py; specs/tockmox-ui/SPEC.md sections 9 and 10 in the planning repo).

  contributes  features.<id>.contributes is checked at start-up: a key the format does not name, two places for the
               pages, a third contributed section, a page id that is not a slug, all refuse the config
  format       a page document the console will not draw is refused whole with the path of the first thing wrong:
               an unknown key, an unknown block type, a javascript: or protocol-relative link, a series whose length
               does not match its labels, a non-finite number
  drawing      every block draws with the console's own components; strings are escaped; a chart's text
               alternative carries every number; a null is a gap, not a zero
  placement    a feature with section: true adds a top-bar section after Platform with its pages in the rail; a rail
               contribution adds a group to AI or Platform; off means absent (404), not locked; a non-admin never
               sees an admin-only feature's pages
  markers      origin: private shows the word Private on the section, the rail items and the page heading
  failure      a read API that fails, answers HTML, answers too much, or answers a bad document reads as Unknown with
               its reason, never as an empty page; a stale document says so
  token        the bearer token from tokenFile goes on the request; nothing goes when there is none

Run from tockmox-ui/: python -m pytest tests/test_feature_pages.py
"""
import json
import re
import sys
import time
from pathlib import Path

import httpx
import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config as cfgmod  # noqa: E402
from app import feature_pages as fp  # noqa: E402
from tests.test_status_api import World, app_obj  # noqa: E402

NOW = "2026-11-05T06:00:00Z"


def now_iso(delta=0):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + delta))


def page(**over):
    doc = {"format": fp.FORMAT, "title": "Delivery flow", "lede": "How fast work moves.", "generated_at": now_iso(-60),
           "source": "Example renderer", "stale_after_s": 3600,
           "blocks": [
               {"type": "stats", "title": "This week", "items": [
                   {"label": "Closed", "value": 42, "delta": 5, "better": "up", "state": "ok"},
                   {"label": "Lead time", "value": 3.5, "unit": "days", "delta": 1.5, "better": "down"},
                   {"label": "Waiting on you", "value": "7", "state": "warning", "note": "oldest 2 days"}]},
               {"type": "chart", "title": "Closed per week", "kind": "bar", "unit": "cards", "x": ["W43", "W44", "W45"],
                "series": [{"name": "Closed", "values": [10, None, 12]}, {"name": "Created", "values": [9, 11, 13]}],
                "describe": "Cards closed and created each ISO week."},
               {"type": "chart", "title": "Lead time", "kind": "line", "x": ["W43", "W44", "W45"],
                "series": [{"name": "Median", "values": [2, None, 3.25]}]},
               {"type": "table", "title": "Oldest waiting", "caption": "Oldest first.", "columns": ["Item", {"label": "Age", "align": "end"}],
                "rows": [[{"text": "EX-1 <b>bold</b>", "href": "https://forge.example.com/x/1", "mono": True}, 3],
                         [{"text": "OK", "state": "ok"}, "two"]]},
               {"type": "lanes", "title": "Board", "lanes": [
                   {"label": "Active", "items": [{"text": "Build the thing", "tag": "EX-2", "meta": "since Monday", "href": "/f/delivery/flow"}]},
                   {"label": "Review", "items": [], "empty": "Nothing in review."}]},
               {"type": "note", "title": "Heads up", "state": "warning", "text": "The weekly figure is partial."}]}
    doc.update(over)
    return doc


class Api:
    """A feature's read API: serves page documents by id, records what it was asked and with which headers."""

    def __init__(self, pages=None, status=200, ctype="application/json", body=None):
        self.pages = pages if pages is not None else {"flow": page(), "board": page(title="Board")}
        self.status, self.ctype, self.body, self.calls = status, ctype, body, []

    def handler(self, req: httpx.Request):
        self.calls.append((req.url.path, req.headers.get("authorization")))
        if self.body is not None:
            return httpx.Response(self.status, content=self.body, headers={"content-type": self.ctype})
        m = re.fullmatch(r".*/pages/([a-z0-9-]+)", req.url.path)
        if not m or m.group(1) not in self.pages:
            return httpx.Response(404, json={"error": "not found"})
        return httpx.Response(self.status, content=json.dumps(self.pages[m.group(1)]).encode(),
                              headers={"content-type": self.ctype})


@pytest.fixture
def world():
    w = World()
    w.apps = [app_obj("tockmox-platform", rev="v0.8.0", path="charts/tockmox-platform"),
              app_obj("tockmox-ai", rev="v0.8.0", path="charts/tockmox-ai")]
    return w


def feature(**over):
    f = {"enabled": True, "name": "Delivery", "origin": "private", "apiUrl": "http://pages.example.svc:8080/s/example",
         "contributes": {"section": True, "pages": [{"id": "flow", "title": "Flow"}, {"id": "board", "title": "Board"}]}}
    f.update(over)
    return f


def client(tmp_path, world, api=None, feats=None, groups=("tockmox-admins",), token=None):
    from fastapi.testclient import TestClient
    from app.auth import Sessions
    from app.main import Transports, create_app
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["sources"]["kubernetes"].update({"url": "https://kube.test", "tokenFile": "/nonexistent", "caFile": "/nonexistent"})
    doc["sources"]["timeoutSeconds"] = 1
    f = feats if feats is not None else {"delivery": feature()}
    if token is not None:
        (tmp_path / "tok").write_text(token + "\n")
        for v in f.values():
            v["tokenFile"] = str(tmp_path / "tok")
    doc["features"] = dict(doc["features"], **f)
    s = cfgmod.parse(doc)
    api = api or Api()
    tp = Transports(kube=httpx.MockTransport(world.handler("kube")), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")), features=httpx.MockTransport(api.handler))
    c = TestClient(create_app(s, tp, notes_path=str(tmp_path / "none.md")), follow_redirects=False)
    if groups is not None:
        sess = Sessions(s.session_secret, 3600, s.admin_group, False)
        c.cookies.set(sess.session_cookie, sess.issue("a", "Someone", list(groups)))
    return c


def top(t):
    return t.split('<header class="top">', 1)[1].split("</header>", 1)[0]


def rail(t):
    m = re.search(r'<nav class="rail"[^>]*>(.*?)</nav>', t, re.S)
    return m.group(1) if m else ""


def main_html(t):
    return t.split("<main", 1)[1].split("</main>", 1)[0]


# ---------------------------------------------------------------- contributes, at start-up

@pytest.mark.parametrize("raw, words", [
    ({"section": True, "pages": [{"id": "a", "title": "A"}], "tiles": []}, "tiles is not a contribution"),
    ({"section": True, "rail": {"section": "ai", "group": "G"}, "pages": [{"id": "a", "title": "A"}]}, "exactly one place"),
    ({"pages": [{"id": "a", "title": "A"}]}, "exactly one place"),
    ({"rail": {"section": "status", "group": "G"}, "pages": [{"id": "a", "title": "A"}]}, "rail.section must be one of"),
    ({"rail": {"section": "ai", "group": ""}, "pages": [{"id": "a", "title": "A"}]}, "rail.group must be"),
    ({"section": True, "pages": []}, "pages must list 1 to"),
    ({"section": True, "pages": [{"id": "A b", "title": "A"}]}, "id must be lowercase"),
    ({"section": True, "pages": [{"id": "a", "title": "A"}, {"id": "a", "title": "B"}]}, "listed twice"),
    ({"section": True, "pages": [{"id": "a", "title": "A", "url": "x"}]}, "takes id and title only"),
    ({"section": "yes", "pages": [{"id": "a", "title": "A"}]}, "section must be true or false"),
])
def test_contributes_refuses_what_the_format_does_not_name(raw, words):
    with pytest.raises(ValueError, match=re.escape(words)):
        fp.parse_contributes("x", raw)


def test_contributes_parses_a_rail_contribution():
    c = fp.parse_contributes("x", {"rail": {"section": "platform", "group": " Delivery "}, "pages": [{"id": "a", "title": "A"}]})
    assert (c.section, c.rail_section, c.rail_group, c.pages[0].id) == (False, "platform", "Delivery", "a")


def test_config_refuses_a_third_contributed_section(tmp_path, world):
    feats = {f"f{i}": feature(contributes={"section": True, "pages": [{"id": "p", "title": "P"}]}) for i in range(3)}
    with pytest.raises(cfgmod.ConfigError, match="at most two features may add a section"):
        client(tmp_path, world, feats=feats)


def test_config_refuses_pages_with_no_api_and_an_unknown_marker(tmp_path, world):
    with pytest.raises(cfgmod.ConfigError, match="needs apiUrl"):
        client(tmp_path, world, feats={"delivery": feature(apiUrl="")})
    with pytest.raises(cfgmod.ConfigError, match="only marker a feature may carry is private"):
        client(tmp_path, world, feats={"delivery": feature(origin="preview")})
    with pytest.raises(cfgmod.ConfigError, match="tokenFile must be an absolute path"):
        client(tmp_path, world, feats={"delivery": feature(tokenFile="token")})


def test_an_app_called_f_is_refused_only_while_a_feature_has_pages(tmp_path, world):
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"], doc["session"]["secretFile"] = str(tmp_path / "cs"), str(tmp_path / "ss")
    doc["apps"] = list(doc.get("apps") or []) + [{"id": "f", "name": "F", "url": "https://f.example.com"}]
    from app.main import create_app as mk
    mk(cfgmod.parse(doc), notes_path=str(tmp_path / "none.md"))   # no feature with pages: an app may be called f
    doc["features"] = dict(doc["features"], delivery=feature())
    with pytest.raises(cfgmod.ConfigError, match="app id 'f' is reserved"):
        mk(cfgmod.parse(doc), notes_path=str(tmp_path / "none.md"))


def test_origin_and_token_checks_leave_a_feature_without_pages_alone(tmp_path, world):
    # an existing feature that happens to carry these keys keeps starting after an upgrade
    client(tmp_path, world, feats={"scanning": {"enabled": True, "origin": "anything", "tokenFile": "relative"}})


def test_a_rail_contribution_open_to_members_is_refused():
    with pytest.raises(ValueError, match="pages in the AI or Platform rail are for admins"):
        fp.parse_contributes("x", {"rail": {"section": "ai", "group": "G"}, "pages": [{"id": "a", "title": "A"}]}, admin_only=False)


def test_a_page_id_with_a_trailing_newline_is_refused():
    with pytest.raises(ValueError, match="id must be lowercase"):
        fp.parse_contributes("x", {"section": True, "pages": [{"id": "flow\n", "title": "A"}]})
    assert fp.PageSource("http://x.example").read("flow\n").reason == "not a page id"
    assert fp.PageSource("http://x.example").read("../x").reason == "not a page id"


# ---------------------------------------------------------------- the format

def test_a_good_document_validates_and_computes_its_trend_words():
    pg = fp.validate(page())
    st = pg["blocks"][0]["items"]
    assert (st[0]["delta"], st[0]["trend"]) == ("+5", "good")
    assert (st[1]["delta"], st[1]["trend"]) == ("+1.50", "bad")        # lead time up is worse
    assert st[2]["trend"] is None and st[2]["value"] == "7"
    assert not pg["stale"]


@pytest.mark.parametrize("mutate, words", [
    (lambda d: d.update(format="tockmox.page/v2"), "page.format must be"),
    (lambda d: d.update(script="alert(1)"), "page.script is not in"),
    (lambda d: d["blocks"].append({"type": "html", "html": "<b>"}), "type 'html' is not a block"),
    (lambda d: d["blocks"][0]["items"][0].update(colour="red"), "items[0].colour is not in"),
    (lambda d: d["blocks"][1]["series"][0]["values"].append(1), "must have one value per x label"),
    (lambda d: d["blocks"][1]["series"][0]["values"].__setitem__(0, float("nan")), "must be a finite number"),
    (lambda d: d["blocks"][1]["series"][0]["values"].__setitem__(0, True), "must be a finite number"),
    (lambda d: d["blocks"][3]["rows"][0][0].update(href="javascript:alert(1)"), "is not a link this page may carry"),
    (lambda d: d["blocks"][3]["rows"][0][0].update(href="//evil.example.com/x"), "is not a link this page may carry"),
    (lambda d: d["blocks"][3]["rows"][0][0].update(href="https://user@evil.example.com/"), "is not a link this page may carry"),
    (lambda d: d["blocks"][3]["rows"][0][0].update(href="data:text/html,x"), "is not a link this page may carry"),
    (lambda d: d["blocks"][4]["lanes"][0]["items"][0].update(href="/\\evil.example.com"), "is not a link this page may carry"),
    (lambda d: d["blocks"][3]["rows"].append(["only one cell"]), "one cell per column"),
    (lambda d: d["blocks"][3]["rows"][1][0].update(href="https://forge.example.com/"), "has a state and a link"),
    (lambda d: d["blocks"][3]["rows"][0][0].update(href="http://203.0.113.7/"), "is not a link this page may carry"),
    (lambda d: d.update(generated_at="2026-99-99T00:00:00Z"), "is not a real date and time"),
    (lambda d: d["blocks"][1]["series"][0]["values"].__setitem__(0, 10 ** 400), "too large a number"),
    (lambda d: d["blocks"][1]["series"][0]["values"].__setitem__(0, 1e308), "too large a number"),
    (lambda d: d["blocks"][5].update(state="red"), "state must be one of"),
    (lambda d: d.update(generated_at="yesterday"), "generated_at must be a UTC time"),
    (lambda d: d.update(title="x" * 200), "page.title is over"),
    (lambda d: d["blocks"][3].update(rows=[["a", 1]] * (fp.MAX_ROWS + 1)), "at most 500 rows"),
])
def test_a_document_the_console_will_not_draw_is_refused_with_its_path(mutate, words):
    d = page()
    mutate(d)
    with pytest.raises(fp.PageError, match=re.escape(words)):
        fp.validate(d)


def test_a_null_is_a_gap_in_a_line_and_no_bar():
    g = fp.chart_geometry("line", list("abcde"), [{"name": "s", "values": [1, 2, None, 3, 4]}])
    segs = g["lines"][0]["segs"]
    assert len(segs) == 2 and all(len(sg.split()) == 2 for sg in segs)       # bridged would be one run of four
    assert g["lines"][0]["dots"] == []
    one = fp.chart_geometry("line", list("abc"), [{"name": "s", "values": [1, None, 2]}])
    assert len(one["lines"][0]["dots"]) == 2                                 # a lone point is drawn as a dot
    b = fp.chart_geometry("bar", list("abc"), [{"name": "s", "values": [1, None, 2]}])
    assert len(b["bars"]) == 2


def test_a_stale_document_says_so():
    d = page(generated_at=now_iso(-7200))
    assert fp.validate(d)["stale"]


# ---------------------------------------------------------------- drawing and placement

def test_a_section_feature_adds_a_top_bar_section_with_its_rail_and_the_private_marker(tmp_path, world):
    r = client(tmp_path, world).get("/f/delivery/flow")
    assert r.status_code == 200
    t = r.text
    nav = top(t)
    assert re.search(r'<a href="/f/delivery/flow" aria-current="page">Delivery<span class="fmark">Private</span></a>', nav)
    assert nav.index(">Platform<") < nav.index(">Delivery<")
    rl = rail(t)
    assert '<a href="/f/delivery/flow" aria-current="page">Flow<span class="fmark">Private</span>' in rl
    assert '<a href="/f/delivery/board">Board<span class="fmark">Private</span>' in rl
    m = main_html(t)
    assert "<h1>Delivery flow</h1>" in m and 'class="fmark"' in m
    assert "EX-1 &lt;b&gt;bold&lt;/b&gt;" in m and "<b>bold</b>" not in m           # escaped, never markup
    assert 'href="https://forge.example.com/x/1" rel="noopener"' in m
    assert "Closed: W43 10, W45 12" in m                                          # the alt text has every number
    assert "Nothing in review." in m and "The weekly figure is partial." in m
    assert "From Example renderer, generated" in m


def test_feature_home_redirects_to_its_first_page(tmp_path, world):
    r = client(tmp_path, world).get("/f/delivery")
    assert r.status_code == 303 and r.headers["location"] == "/f/delivery/flow"


def test_a_rail_contribution_goes_into_platform_and_adds_no_section(tmp_path, world):
    f = feature(origin=None, contributes={"rail": {"section": "platform", "group": "Delivery"},
                                          "pages": [{"id": "flow", "title": "Flow"}]})
    f.pop("origin")
    t = client(tmp_path, world, feats={"delivery": f}).get("/f/delivery/flow").text
    nav = top(t)
    assert ">Delivery<" not in nav
    assert re.search(r'<a href="[^"]+" aria-current="page">Platform</a>', nav)
    rl = rail(t)
    assert "Delivery" in rl and '<a href="/f/delivery/flow" aria-current="page">Flow</a>' in rl
    assert "Capabilities" in rl                                                    # the built-in groups stay
    assert 'class="fmark"' not in t                                                # no marker without origin: private


def test_a_feature_with_pages_is_not_also_a_tab(tmp_path, world):
    t = client(tmp_path, world).get("/capabilities").text
    assert "/tabs/delivery" not in t


def test_off_means_absent_not_locked(tmp_path, world):
    c = client(tmp_path, world, feats={"delivery": feature(enabled=False)})
    assert c.get("/f/delivery/flow").status_code == 404
    assert ">Delivery<" not in top(c.get("/").text)


def test_a_page_the_feature_does_not_list_is_404_and_never_fetched(tmp_path, world):
    api = Api()
    c = client(tmp_path, world, api=api)
    assert c.get("/f/delivery/other").status_code == 404
    assert c.get("/f/delivery/..%2f..%2fetc").status_code == 404
    assert api.calls == []


def test_a_member_never_sees_an_admin_only_feature(tmp_path, world):
    c = client(tmp_path, world, groups=("tockmox-users",))
    assert c.get("/f/delivery/flow").status_code == 404
    assert ">Delivery<" not in top(c.get("/").text)


def test_a_member_sees_a_feature_open_to_members(tmp_path, world):
    c = client(tmp_path, world, groups=("tockmox-users",), feats={"delivery": feature(adminOnly=False)})
    r = c.get("/f/delivery/flow")
    assert r.status_code == 200 and ">Delivery<" in top(r.text)


def test_signed_out_is_sent_to_login(tmp_path, world):
    r = client(tmp_path, world, groups=None).get("/f/delivery/flow")
    assert r.status_code == 302 and r.headers["location"].startswith("/login")


# ---------------------------------------------------------------- failures read as Unknown

@pytest.mark.parametrize("api, words", [
    (Api(status=500), "answered HTTP 500"),
    (Api(ctype="text/html", body=b"<html>"), "did not answer JSON"),
    (Api(body=b"{not json"), "not JSON"),
    (Api(body=json.dumps(page(blocks=[{"type": "html"}])).encode()), "not in the format this console draws"),
    (Api(body=b'{"x": "' + b"a" * (fp.MAX_BYTES + 10) + b'"}'), "over 1000 kB"),
])
def test_a_failing_read_api_reads_unknown_with_its_reason(tmp_path, world, api, words):
    t = main_html(client(tmp_path, world, api=api).get("/f/delivery/flow").text)
    assert "Unknown" in t and words in t and "That is not the same as nothing to show" in t


def test_an_unreachable_read_api_reads_unknown(tmp_path, world):
    class Down(Api):
        def handler(self, req):
            raise httpx.ConnectError("down", request=req)
    t = main_html(client(tmp_path, world, api=Down()).get("/f/delivery/flow").text)
    assert "did not answer (ConnectError)" in t


def test_a_stale_page_carries_the_stale_badge(tmp_path, world):
    api = Api(pages={"flow": page(generated_at=now_iso(-7200)), "board": page()})
    t = main_html(client(tmp_path, world, api=api).get("/f/delivery/flow").text)
    assert ">Stale<" in t and "has not been regenerated on schedule" in t


def test_the_bearer_token_goes_on_the_request(tmp_path, world):
    api = Api()
    client(tmp_path, world, api=api, token="t0ken").get("/f/delivery/flow")
    assert api.calls == [("/s/example/pages/flow", "Bearer t0ken")]


def test_no_token_file_sends_no_authorization(tmp_path, world):
    api = Api()
    client(tmp_path, world, api=api).get("/f/delivery/board")
    assert api.calls == [("/s/example/pages/board", None)]


def test_a_redirect_is_not_followed(tmp_path, world):
    class Redirect(Api):
        def handler(self, req):
            self.calls.append((req.url.path, req.headers.get("authorization")))
            return httpx.Response(302, headers={"location": "http://elsewhere.example.com/pages/flow"})
    api = Redirect()
    t = main_html(client(tmp_path, world, api=api).get("/f/delivery/flow").text)
    assert "answered HTTP 302" in t and len(api.calls) == 1


def test_the_page_is_cached_briefly_and_then_fetched_again(tmp_path, world):
    api = Api()
    c = client(tmp_path, world, api=api)
    c.get("/f/delivery/flow")
    c.get("/f/delivery/flow")
    assert len(api.calls) == 1
    t = [1000.0]
    src = fp.PageSource("http://pages.example.svc/s/x", transport=httpx.MockTransport(api.handler), clock=lambda: t[0])
    src.read("flow"); src.read("flow")
    assert len(api.calls) == 2
    t[0] += src.ttl + 1
    src.read("flow")
    assert len(api.calls) == 3


def test_age_and_staleness_are_computed_when_drawn_not_when_fetched():
    pg = fp.validate(page(generated_at=now_iso(-60)), now=time.time())
    assert not pg["stale"]
    later = fp.freshness(pg, now=time.time() + 7200)
    assert later["stale"] and later["age_s"] > 7000


@pytest.mark.parametrize("body, words", [
    (b"[" * 200000, "not JSON"),
])
def test_a_pathological_body_reads_unknown(tmp_path, world, body, words):
    t = main_html(client(tmp_path, world, api=Api(body=body)).get("/f/delivery/flow").text)
    assert words in t and "Unknown" in t


def test_a_compressed_answer_is_refused(tmp_path, world):
    class Gz(Api):
        def handler(self, req):
            return httpx.Response(200, content=b"x", headers={"content-type": "application/json", "content-encoding": "gzip"})
    t = main_html(client(tmp_path, world, api=Gz()).get("/f/delivery/flow").text)
    assert "answered compressed" in t


def test_an_unexpected_error_in_fetching_reads_unknown():
    class Boom(Api):
        def handler(self, req):
            raise RuntimeError("boom")
    rd = fp.PageSource("http://pages.example.svc/s/x", transport=httpx.MockTransport(Boom().handler)).read("flow")
    assert rd.page is None and "RuntimeError" in rd.reason


def test_help_for_a_feature_page_names_the_feature_pages_doc():
    from app import nav
    assert nav.help_for("/f/delivery/flow") == "administration/feature-pages.md"


def test_the_docs_example_is_a_page_the_console_draws():
    # docs/administration/feature-pages.md carries a complete example document; it must validate as written
    doc = (Path(__file__).resolve().parents[2] / "docs" / "administration" / "feature-pages.md").read_text()
    block = doc.split("### A complete minimal example", 1)[1].split("```json", 1)[1].split("```", 1)[0]
    pg = fp.validate(json.loads(block), now=fp.validate(json.loads(block))["generated_at"])
    assert [b["type"] for b in pg["blocks"]] == ["stats", "chart", "table", "lanes", "note"]

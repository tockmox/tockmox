# SPDX-License-Identifier: Apache-2.0
"""Platform Management: one page per specialist, /platform/specialists/<id>, and its Health.

Health is one of five words (Up, Degraded, Down, Not served, Unknown), decided from the specialist host's index and
Prometheus, and no missing fact ever reads Up. The page opens on three blocks shaped like a role page's; a source that
did not answer says so in words, and a field the host's index does not carry yet says "not in the index yet"."""
import copy

from tests.proto_support import ROOT, login_as  # noqa: F401
from tests.proto_support import _secret, world  # noqa: F401  (fixtures)
from tests.test_platform_cases import Host, cases_client
from app import platform_cases as pc
from app import specialist_page as sp
from app.sources import Reading

UP_Q = 'up{job="specialist-host"}'
CALLS_Q = 'sum by (specialist, outcome) (increase(specialist_calls_total[1h]))'
FIRST_LOOK_CALLS_Q = ('sum by (op, outcome) (increase(specialist_calls_total{specialist="incident-responder"}[1440m]))')
PAGE = "/platform/specialists/incident-responder"


def host_up(world, v=1):
    world.series[UP_Q] = [({"job": "specialist-host"}, v)]


def block(page, bid):
    i = page.index(f'id="{bid}"')
    return page[i:page.index("</section>", i)]


def health_dd(page):
    b = block(page, "sb-health")
    return b[b.index("<dt>Health</dt>"):b.index("<dt>Mode</dt>")]


# ---------------------------------------------------------------- the route

def test_an_unknown_id_is_a_404_in_words(world):
    c, host = cases_client(world)
    r = c.get("/platform/specialists/no-such-specialist")
    assert r.status_code == 404
    assert "There is no specialist no-such-specialist" in r.text
    assert "catalog does not name it and the host does not serve it" in r.text
    r = c.get("/platform/specialists/Not_An_Id")
    assert r.status_code == 404 and "That is not a specialist id." in r.text


def test_an_unknown_id_while_the_host_is_down_says_so_and_is_still_404(world):
    c, _ = cases_client(world, Host(down=True))
    r = c.get("/platform/specialists/no-such-specialist")
    assert r.status_code == 404
    assert "the specialist host did not answer" in r.text and "unknown" in r.text


def test_admins_only(world):
    from tests.test_platform import client_for, doc_with_platform
    c, app, s = client_for(world, doc_with_platform(specialistsUrl="https://specialists.example"))
    login_as(c, s, ["users"])
    assert c.get(PAGE).status_code == 403


def test_the_page_opens_on_three_blocks_and_five_sections(world):
    host_up(world)
    c, _ = cases_client(world)
    t = c.get(PAGE).text
    for bid in ("sb-did", "sb-open", "sb-health", "sp-does", "sp-for", "sp-ask", "sp-calls", "sp-yours"):
        assert f'id="{bid}"' in t, bid
    assert "<h1>Incident Responder</h1>" in t


def test_every_specialist_the_catalog_or_the_host_names_has_a_page_with_every_block(world):
    from app import platform as pm
    host_up(world)
    c, host = cases_client(world)
    ids = set(pc.specialist_roles(pm.load_catalog())) | {s["id"] for s in host.index["specialists"]}
    for sid in sorted(ids):
        r = c.get(f"/platform/specialists/{sid}")
        assert r.status_code == 200, sid
        for bid in ("sb-did", "sb-open", "sb-health", "sp-does", "sp-for", "sp-ask", "sp-calls", "sp-yours"):
            assert f'id="{bid}"' in r.text, (sid, bid)


def test_the_list_and_the_role_page_link_to_it(world):
    c, _ = cases_client(world)
    assert f'href="{PAGE}"' in c.get("/platform/specialists").text
    assert f'href="{PAGE}"' in c.get("/platform/agents/incident").text


def test_it_sets_its_own_last_looked_cookie(world):
    c, _ = cases_client(world)
    r = c.get(PAGE)
    assert "tmx_seen_sp_incident-responder=" in r.headers.get("set-cookie", "")


# ---------------------------------------------------------------- Health

def test_a_planted_down_prometheus_reads_unknown_in_words_never_up(world):
    world.down.add("prometheus")
    c, _ = cases_client(world)
    t = c.get(PAGE).text
    h = health_dd(t)
    assert "st-unknown" in h and ">Unknown<" in h
    assert "Prometheus did not answer" in h and "so health is unknown" in h
    assert "Served by the host, version 1.2.0" in h
    assert ">Up<" not in h and "st-ok" not in h
    did = block(t, "sb-did")
    assert "Prometheus did not answer" in did and "That is not the same as idle" in did
    assert "No calls since then" not in did


def test_a_planted_failed_share_over_five_percent_reads_degraded(world):
    host_up(world)
    world.series[CALLS_Q] = [({"specialist": "incident-responder", "outcome": "failed"}, 2),
                             ({"specialist": "incident-responder", "outcome": "restored"}, 28),
                             ({"specialist": "service-desk", "outcome": "ok"}, 500)]
    c, _ = cases_client(world)
    h = health_dd(c.get(PAGE).text)
    assert ">Degraded<" in h and "st-warning" in h
    assert "2 failed of 30 calls in the last hour" in h
    # the same share on another specialist leaves this one alone
    h2 = health_dd(c.get("/platform/specialists/service-desk").text)
    assert ">Up<" in h2 and ">Degraded<" not in h2


def test_a_failed_share_under_twenty_calls_says_nothing(world):
    host_up(world)
    world.series[CALLS_Q] = [({"specialist": "incident-responder", "outcome": "failed"}, 3),
                             ({"specialist": "incident-responder", "outcome": "restored"}, 10)]
    c, _ = cases_client(world)
    h = health_dd(c.get(PAGE).text)
    assert ">Up<" in h and "3 failed of 13 calls" in h


def test_a_planted_up_zero_reads_down(world):
    host_up(world, 0)
    c, _ = cases_client(world)
    h = health_dd(c.get(PAGE).text)
    assert ">Down<" in h and "st-critical" in h and "up is 0" in h


def test_no_up_series_is_unknown_not_up(world):
    c, _ = cases_client(world)                  # Prometheus answers, but scrapes no specialist host
    h = health_dd(c.get(PAGE).text)
    assert ">Unknown<" in h and "no up series" in h


def test_a_host_that_does_not_answer_reads_down(world):
    host_up(world)
    c, _ = cases_client(world, Host(down=True))
    h = health_dd(c.get(PAGE).text)
    assert ">Down<" in h and "The specialist host did not answer" in h


def test_a_built_specialist_the_host_does_not_serve_reads_not_served(world):
    host_up(world)
    c, _ = cases_client(world)
    t = c.get("/platform/specialists/problem-analyst").text
    h = health_dd(t)
    assert ">Not served<" in h and "does not serve it" in h
    assert "not served, so it has made no calls" in block(t, "sb-did")


def test_up_needs_every_fact_and_idle_is_not_a_fault(world):
    host_up(world)
    c, _ = cases_client(world)
    h = health_dd(c.get(PAGE).text)
    assert ">Up<" in h and "No calls in the last hour. That is idle, not a fault." in h


def test_the_rules_in_order_never_fall_through_to_up():
    t = 1.0
    idx = Reading("Specialist host", "ok", {}, "", t, t)
    idx_down = Reading("Specialist host", "unknown", None, "unreachable", None, None)
    entry = {"version": "1.0.0"}

    def prom(**d):
        base = {"up": [1.0], "calls": {}, "ready": [], "desired": []}
        base.update(d)
        return Reading("p", "ok", base, "", t, t)
    h = sp.health
    assert h("x", entry, idx, False, prom(), True)["state"] == sp.UNKNOWN_H
    assert h("x", entry, idx_down, True, prom(), True)["state"] == sp.DOWN
    assert h("x", None, idx, True, prom(), True)["state"] == sp.NOT_SERVED
    assert h("x", dict(entry, served=False), idx, True, prom(), True)["state"] == sp.NOT_SERVED
    assert h("x", entry, idx, True, prom(), False)["state"] == sp.UNKNOWN_H
    assert h("x", entry, idx, True, prom(up=None), True)["state"] == sp.UNKNOWN_H
    assert h("x", entry, idx, True, prom(calls=None), True)["state"] == sp.UNKNOWN_H
    assert h("x", entry, idx, True, prom(up=[0.0, 0.0]), True)["state"] == sp.DOWN
    assert h("x", entry, idx, True, prom(up=[1.0, 0.0]), True)["state"] == sp.DEGRADED
    assert h("x", entry, idx, True, prom(ready=[0.0], desired=[1.0]), True)["state"] == sp.DOWN
    assert h("x", entry, idx, True, prom(ready=[1.0], desired=[2.0]), True)["state"] == sp.DEGRADED
    assert h("x", entry, idx, True, prom(calls={"x": {"failed": 1, "ok": 19}}), True)["state"] == sp.DEGRADED
    assert h("x", entry, idx, True, prom(calls={"x": {"failed": 1, "ok": 20}}), True)["state"] == sp.UP
    assert h("x", entry, idx, True, prom(), True)["state"] == sp.UP


# ---------------------------------------------------------------- the blocks and sections

def test_what_it_did_counts_calls_by_operation_and_outcome_since_the_last_look(world):
    host_up(world)
    world.series[FIRST_LOOK_CALLS_Q] = [({"op": "triage", "outcome": "out_of_scope"}, 59),
                                        ({"op": "triage", "outcome": "needs_you"}, 7),
                                        ({"op": "triage", "outcome": "restored"}, 3)]
    c, _ = cases_client(world)
    did = block(c.get(PAGE).text, "sb-did")
    assert "last 24 hours" in did
    assert "Triage" in did and "69 times" in did
    assert "59 out of scope, 7 needs you, 3 restored" in did


def test_no_calls_is_said_only_when_prometheus_answered(world):
    host_up(world)
    c, _ = cases_client(world)
    did = block(c.get(PAGE).text, "sb-did")
    assert "No calls since then. Prometheus answered and counts none." in did


def test_its_open_items_are_the_open_cases_it_worked_and_a_down_desk_says_so(world):
    host_up(world)
    c, _ = cases_client(world)
    op = block(c.get(PAGE).text, "sb-open")
    items = [x.split('"', 1)[0] for x in op.split('<li><a href="/platform/cases/')[1:]]
    assert items == ["INC-0002", "INC-0001"], "open cases it worked, in pending order (what waits on you first)"
    assert "INC-0003" not in items, "a closed case is not an open item"
    assert "PRB-0001" not in items, "a case only another specialist worked"
    c2, _ = cases_client(world, Host(down=True))
    op = block(c2.get(PAGE).text, "sb-open")
    assert "The Service Desk did not answer" in op and "That is not the same as none" in op
    assert "No open item. The Service Desk answered" not in op


def test_index_fields_not_rendered_yet_say_so_never_an_empty_list(world):
    host_up(world)
    c, _ = cases_client(world)
    t = c.get(PAGE).text
    assert "Its schedules and events are not in the index yet." in block(t, "sp-does")
    assert "What it leaves to you is not in the index yet." in block(t, "sp-yours")
    assert "are not in the index yet" in block(t, "sp-calls")


def test_index_fields_once_rendered_show_on_the_page(world):
    host_up(world)
    h = Host()
    ir = h.index["specialists"][0]
    ir.update({"summary": "Triages an incident the desk opened.",
               "callers": ["specialist/service-desk", "client/tockmox-ui", "schedule"],
               "may_call": ["service-desk", "cluster-operator"],
               "operations": [{"name": "triage", "kind": "command", "model_step": "classify",
                               "outcomes": ["restored", "needs_you"], "summary": "Triage one incident.",
                               "callers": ["specialist/service-desk"]},
                              {"name": "status", "kind": "query", "model_step": "none", "outcomes": ["ok"],
                               "summary": "Say how it is doing.", "callers": []}],
               "owner_keeps": [{"any non-standard restore": "it asks you instead"}, "every write to production"],
               "triggers": {"schedules": [{"every": "1h", "op": "sweep"}], "events": [{"source": "desk", "op": "triage"}]},
               "model_steps": {"classify": {"alias": "local-medium", "caps": {"usd": 0.02}, "shadow": "the rule table"}},
               "reporting": {"to_caller": "result", "to_person": "needs_you_only"},
               "data_class_max": "internal"})
    c, _ = cases_client(world, h)
    t = c.get(PAGE).text
    does = block(t, "sp-does")
    assert "Things it can do" in does and "Things you can ask it" in does
    assert "On a schedule (1h): sweep" in does and "On an event (desk): triage" in does
    ask = block(t, "sp-ask")
    assert 'href="/platform/specialists/service-desk"' in ask and "This console" in ask and "The schedule" in ask
    calls = block(t, "sp-calls")
    assert "Model local-medium for one step (classify), at most $0.02 a call" in calls
    assert "Without a model: the rule table" in calls
    yours = block(t, "sp-yours")
    assert "any non-standard restore: it asks you instead" in yours and "every write to production" in yours
    assert "It tells you only when it needs you." in yours
    assert "not in the index yet" not in t


def test_who_it_works_for_puts_the_accountable_role_first(world):
    c, _ = cases_client(world)
    t = block(c.get(PAGE).text, "sp-for")
    assert 'href="/platform/agents/incident"' in t and "(accountable)" in t


def test_a_served_specialist_the_catalog_does_not_name_says_not_in_the_catalog_yet(world):
    host_up(world)
    h = Host()
    h.index["specialists"].append({"id": "brand-new-one", "version": "0.1.0", "status": "observe",
                                   "title": "Brand New One", "owner_role": "nobody"})
    c, _ = cases_client(world, h)
    r = c.get("/platform/specialists/brand-new-one")
    assert r.status_code == 200
    assert "Not in the catalog yet" in block(r.text, "sp-for")


def test_a_shape_that_is_not_its_own_is_dropped_from_the_index_entry():
    e = sp.clean_entry({"id": "x-y", "operations": [{"name": "Bad Name", "kind": "command"},
                                                    {"name": "ok_op", "kind": "command", "outcomes": ["ok", "<b>x</b>"]}],
                        "callers": ["specialist/<script>", "client/tockmox-ui"], "may_call": ["UPPER", "fine-one"]})
    assert [o["name"] for o in e["operations"]] == ["ok_op"]
    assert e["operations"][0]["outcomes"] == ["ok"]
    assert [x["id"] for x in e["callers"]] == ["client/tockmox-ui"]
    assert [m["id"] for m in e["may_call"]] == ["fine-one"]
    assert e["present"] == []


def test_the_index_source_keeps_the_served_map_the_other_pages_read(world):
    h = Host()
    src = pc.IndexSource("https://specialists.example", 2.0, transport=__import__("httpx").MockTransport(h.handler))
    d = src.read().data
    assert set(d["served"]) == {"incident-responder", "service-desk"}
    assert set(d["entries"]) == {"incident-responder", "service-desk"}
    h2 = copy.deepcopy(h)
    h2.index["specialists"][0]["served"] = False
    d = pc.IndexSource("https://specialists.example", 2.0, transport=__import__("httpx").MockTransport(h2.handler)).read().data
    assert "incident-responder" not in d["served"] and "incident-responder" in d["entries"]

# SPDX-License-Identifier: Apache-2.0
"""Platform Management: the Service Desk's cases and the specialists.

The fixture (tests/fixtures/desk-case.json) was made by running a whole case through the Service Desk 1.2.0 handler
and reading it back as client/tockmox-ui, so these tests hold the page to the desk's real contract: INC-0001 restored by
a rollback, its problem PRB-0001 with a root cause a model worded, the fix CHG-0001 waiting on Jeff's PR approval,
INC-0002 asking Jeff to approve a restore, and INC-0003 closed as a false positive."""
import copy
import json
import os
import shutil
import subprocess
import sys

import httpx
import pytest

from tests.proto_support import ROOT, login_as  # noqa: F401
from tests.proto_support import _secret, world  # noqa: F401  (fixtures)
from tests.test_platform import client_for, doc_with_platform
from app import platform as pm
from app import platform_cases as pc
from app.main import Transports, create_app
from app import config as cfgmod
from fastapi.testclient import TestClient

FIX = json.load(open(os.path.join(ROOT, "tests", "fixtures", "desk-case.json")))
HOST = "https://specialists.example"
TOKEN_FILE = os.path.join(ROOT, "tests", "fixtures", "none.md")
REPO = os.path.dirname(ROOT)
GEN = os.path.join(REPO, "tools", "gen-platform-specialists.py")


class Host:
    """The specialist host: POST /s/service-desk/v1/<op> and GET /v1/index."""

    def __init__(self, fix=None, down=False, index=None, list_outcome=None):
        self.fix, self.down, self.seen = copy.deepcopy(fix or FIX), down, []
        self.index = index if index is not None else {"version": 1, "specialists": [
            {"id": "incident-responder", "version": "1.2.0", "status": "propose", "title": "Incident Responder", "owner_role": "incident-manager"},
            {"id": "service-desk", "version": "1.2.0", "status": "propose", "title": "Service Desk", "owner_role": "platform-manager"}],
            "roles": {"file": "roles/platform-roles.yaml", "sha256": pm.load_catalog().specialists_source.get("sha256", "")}}
        self.list_outcome = list_outcome

    def handler(self, req):
        self.seen.append(req)
        if self.down:
            raise httpx.ConnectError("refused", request=req)
        if req.method == "GET" and req.url.path == "/v1/index":
            return httpx.Response(200, json=self.index)
        body = json.loads(req.content or b"{}")
        op = req.url.path.rsplit("/", 1)[-1]
        if op == "list":
            if self.list_outcome:
                return httpx.Response(200, json={"outcome": self.list_outcome, "message": "no"})
            got = copy.deepcopy(self.fix["list"])
            if body.get("open_only"):
                got["records"] = [r for r in got["records"] if not r.get("closed")]
                got["count"] = len(got["records"]) if "count_override" not in self.fix else self.fix["count_override"]
            return httpx.Response(200, json=got)
        if op == "get":
            got = self.fix["get"].get(body.get("id"))
            return httpx.Response(200, json=got or {"outcome": "not_found", "message": "no record"})
        return httpx.Response(403, json={"outcome": "refused"})


def cases_client(world, host=None, **opts):
    host = host or Host()
    doc = doc_with_platform(specialistsUrl=HOST, specialistsTokenFile=opts.pop("token_file", ""), **opts)
    s = cfgmod.parse(doc)
    tp = Transports(kube=httpx.MockTransport(world.handler("kube")), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")),
                    specialists=httpx.MockTransport(host.handler))
    app = create_app(s, tp, notes_path=os.path.join(ROOT, "tests", "fixtures", "none.md"))
    c = TestClient(app, follow_redirects=False)
    login_as(c, s, ["tockmox-admins"])
    return c, host


# ---------------------------------------------------------------- the gate and the rules

def test_admins_only_and_no_write_routes(world):
    c, host = cases_client(world)
    for path in ("/platform/cases", "/platform/cases/INC-0001", "/platform/specialists"):
        assert c.get(path).status_code == 200, path
        assert c.post(path).status_code in (403, 404, 405)
    c2, app, s = client_for(world, doc_with_platform(specialistsUrl=HOST))
    login_as(c2, s, ["tockmox-users"])
    for path in ("/platform/cases", "/platform/cases/INC-0001", "/platform/specialists"):
        assert c2.get(path).status_code == 403


def test_the_page_only_ever_asks_the_desk_to_read(world):
    c, host = cases_client(world)
    c.get("/platform/cases"); c.get("/platform/cases/INC-0001"); c.get("/platform/agents/incident"); c.get("/platform")
    ops = {r.url.path.rsplit("/", 1)[-1] for r in host.seen if r.method == "POST"}
    assert ops <= {"list", "get"}, ops


def test_the_token_file_is_sent_as_a_bearer(world, tmp_path):
    tf = tmp_path / "token"
    tf.write_text("ui-token\n")
    c, host = cases_client(world, token_file=str(tf))
    c.get("/platform/cases")
    assert any(r.headers.get("authorization") == "Bearer ui-token" for r in host.seen if r.method == "POST")


# ---------------------------------------------------------------- what is pending, and what was worked

def test_cases_lists_every_record_with_who_it_waits_on(world):
    c, _ = cases_client(world)
    t = c.get("/platform/cases").text
    for rid in ("INC-0001", "INC-0002", "PRB-0001", "CHG-0001", "INC-0003"):
        assert f"/platform/cases/{rid}" in t, rid
    assert "2 cases wait on you" in t                      # INC-0002's ask, CHG-0001's approval: never counted twice
    assert "Approve a restore no standard change covers" in t
    assert "Your approval of its pull request" in t and "https://git.example/example/site/pulls/41" in t
    assert "The next move is on" in t and "which waits on you" in t   # INC-0001 -> PRB-0001 -> CHG-0001 -> Jeff
    pending, done = t.split('id="done"')
    assert "INC-0003" not in pending and "INC-0003" in done, "a closed case is in Worked on, not Pending"
    assert pending.index("INC-0002") < pending.index("PRB-0001"), "what waits on you comes first"


def test_a_role_sees_what_it_is_accountable_for_and_what_its_agents_worked(world):
    c, _ = cases_client(world)
    t = c.get("/platform/agents/incident").text
    assert "Its cases" in t and "Pending (2)" in t and "Worked on in the last 30 days (1)" in t
    assert "INC-0001" in t and "INC-0002" in t and "INC-0003" in t
    row = '<code>CHG-0001</code></a> <span class="muted">Change</span>'
    assert row not in t.split("Its cases")[1], "the change is not the incident manager's (only named as where INC-0001 waits)"
    p = c.get("/platform/agents/problem").text
    assert "PRB-0001" in p and "CHG-0001" in p, "the analyst opened and worked the change"
    assert "INC-0002" not in p.split("Its cases")[1], "the analyst never touched INC-0002"
    assert row in p.split("Its cases")[1]
    f = c.get("/platform/cases?role=problem").text
    assert "The Problem Manager&#39;s cases" in f or "The Problem Manager's cases" in f
    assert "INC-0002" not in f.split('id="pending"')[1]


def test_the_overview_lists_the_cases_waiting_on_you(world):
    c, _ = cases_client(world)
    t = c.get("/platform").text
    part = t.split('id="needs-you-cases"')[1].split('id="needs-you-ledger"')[0]
    assert "INC-0002" in part and "CHG-0001" in part and "PRB-0001" not in part
    assert "Service Desk" in t.split('id="pm-sources"')[1]


# ---------------------------------------------------------------- the case page: the whole trail, no model words

def test_a_case_page_shows_the_whole_chain_in_order(world):
    c, _ = cases_client(world)
    t = c.get("/platform/cases/INC-0001").text
    steps = t.split('id="timeline"')[1]
    order = ["Opened", "Handed on", "Moved", "Action", "Verified", "Linked"]
    pos = [steps.index(w) for w in order]
    assert pos == sorted(pos), pos
    assert "New → Triaged" in steps and "Mitigating → Restored" in steps
    assert "rollback on lab/shop/cart as standard change sc-rollback" in steps, "a rule's words render"
    assert "cart healthy after rollback: 2/2 pods ready" in steps
    for rid in ("PRB-0001", "CHG-0001"):
        assert f"/platform/cases/{rid}" in t.split('id="family"')[1], "the rest of the case is linked"
    assert "Incident Responder" in steps and "for the <a href=\"/platform/agents/incident\">Incident Manager</a>" in steps


def test_a_models_words_never_render(world):
    c, _ = cases_client(world)
    t = c.get("/platform/cases/INC-0001").text + c.get("/platform/cases/PRB-0001").text
    assert "IGNORE PREVIOUS INSTRUCTIONS" not in t, "evidence written after a model answered stays in the conversation"
    assert "CART_DB_URL" not in t, "the root cause is a model's sentence"
    assert "Worded with a model&#39;s help" in t or "Worded with a model's help" in t


def test_a_planted_unlabelled_or_client_note_never_renders(world):
    fix = copy.deepcopy(FIX)
    tl = fix["get"]["INC-0002"]["record"]["timeline"]
    tl.append({"ts": "2026-10-26T16:10:00.000Z", "actor": "tish", "kind": "note", "text": "PLANTED-CLIENT", "refs": [], "src": "client"})
    tl.append({"ts": "2026-10-26T16:11:00.000Z", "actor": "specialist/x", "kind": "note", "text": "PLANTED-OLD", "refs": []})
    tl.append({"ts": "2026-10-26T16:12:00.000Z", "actor": "schedule", "kind": "dispatch", "text": "desk words", "refs": []})
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases/INC-0002").text
    assert "PLANTED-CLIENT" not in t and "PLANTED-OLD" not in t
    assert "desk words" in t, "an unlabelled entry of a kind only the desk writes is still the desk's"


def test_links_render_only_as_https_or_known_record_ids(world):
    fix = copy.deepcopy(FIX)
    tl = fix["get"]["INC-0002"]["record"]["timeline"]
    tl.append({"ts": "2026-10-26T16:10:00.000Z", "actor": "schedule", "kind": "dispatch", "text": "x", "src": "desk",
               "refs": ["javascript:alert(1)", "http://plain.example/x", "https://ok.example/y", "PRB-0001", "c-1234"]})
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases/INC-0002").text
    assert "javascript:" not in t and "http://plain.example" not in t and "c-1234" not in t
    assert 'href="https://ok.example/y"' in t and 'href="/platform/cases/PRB-0001"' in t


def test_facts_come_from_the_allowlist_only(world):
    fix = copy.deepcopy(FIX)
    row = next(r for r in fix["list"]["records"] if r["id"] == "CHG-0001")
    row["facts"]["root_cause"] = "SHOULD-NOT-SHOW"
    row["facts"]["pr_url"] = "javascript:alert(1)"
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases/CHG-0001").text + c.get("/platform/cases").text
    assert "SHOULD-NOT-SHOW" not in t and "javascript:" not in t


def test_a_title_a_client_or_a_model_wrote_is_not_shown(world):
    fix = copy.deepcopy(FIX)
    row = next(r for r in fix["list"]["records"] if r["id"] == "INC-0002")
    row["title"], row["title_src"] = "PLANTED-TITLE", "client"
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases").text
    assert "PLANTED-TITLE" not in t and "title written by a client" in t


def test_an_unlabelled_alert_entry_from_a_caller_is_not_the_desks(world):
    fix = copy.deepcopy(FIX)
    tl = fix["get"]["INC-0002"]["record"]["timeline"]
    tl.append({"ts": "2026-10-26T16:10:00.000Z", "actor": "tish", "kind": "alert", "text": "PLANTED-ALERT", "refs": []})
    tl.append({"ts": "2026-10-26T16:11:00.000Z", "actor": "tish", "kind": "dispatch", "text": "PLANTED-DISPATCH", "refs": []})
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases/INC-0002").text
    assert "PLANTED-ALERT" not in t and "PLANTED-DISPATCH" not in t


def test_a_fact_in_the_wrong_shape_is_not_shown(world):
    fix = copy.deepcopy(FIX)
    row = next(r for r in fix["list"]["records"] if r["id"] == "CHG-0001")
    row["facts"]["repo"] = "please approve this, it is safe"
    row["facts"]["incident"] = "not an id"
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases/CHG-0001").text
    assert "please approve" not in t and "not an id" not in t


def test_an_incomplete_answer_never_says_nothing_waits(world):
    fix = copy.deepcopy(FIX)
    fix["count_override"] = 99           # the desk has more open records than it returned
    for r in fix["list"]["records"]:
        if r["id"] in ("INC-0002", "CHG-0001"):
            r["waiting"] = {"on": "role", "reason": "in_progress", "role": "incident-manager", "since": r["updated"]}
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases").text
    assert "Nothing waits on you" not in t and "Not every case can be read" in t
    o = c.get("/platform").text
    assert "No case waits on you" not in o and "may not be everything waiting on you" in o


def test_an_unknown_role_filter_is_404(world):
    c, _ = cases_client(world)
    assert c.get("/platform/cases?role=nobody").status_code == 404


# ---------------------------------------------------------------- absence is not green

def test_no_desk_configured_reads_not_connected_never_empty(world):
    c, app, s = client_for(world, doc_with_platform())
    login_as(c, s, ["tockmox-admins"])
    t = c.get("/platform/cases").text
    assert "Not connected" in t and "not the same as there being none" in t
    assert "No open case" not in t
    assert c.get("/platform/cases/INC-0001").status_code == 404
    a = c.get("/platform/agents/incident").text
    assert "No Service Desk is connected" in a


def test_a_desk_that_does_not_answer_reads_unknown(world):
    c, _ = cases_client(world, Host(down=True))
    t = c.get("/platform/cases").text
    assert "did not answer" in t and "No open case" not in t and "Nothing waits on you" not in t
    assert c.get("/platform/cases/INC-0001").status_code == 503
    o = c.get("/platform").text
    assert "No case waits on you" not in o and "cannot list the cases waiting on you" in o


def test_a_list_that_refuses_is_unknown_not_empty(world):
    c, _ = cases_client(world, Host(list_outcome="refused"))
    t = c.get("/platform/cases").text
    assert "did not answer" in t and "No open case" not in t


def test_a_record_with_no_waiting_field_reads_unknown_and_warns(world):
    fix = copy.deepcopy(FIX)
    for r in fix["list"]["records"]:
        if not r["closed"]:
            r.pop("waiting", None)
    c, _ = cases_client(world, Host(fix))
    t = c.get("/platform/cases").text
    assert "older than 1.2.0" in t and "Unknown" in t
    assert "Nothing waits on you" not in t.split('id="pending"')[0] or "older than 1.2.0" in t


def test_an_unknown_case_is_404_and_a_bad_id_never_reaches_the_desk(world):
    c, host = cases_client(world)
    assert c.get("/platform/cases/INC-9999").status_code == 404
    n = len(host.seen)
    assert c.get("/platform/cases/..%2Fetc").status_code == 404
    assert len(host.seen) == n


# ---------------------------------------------------------------- specialists

def test_the_shipped_catalog_carries_the_generated_specialists_field():
    cat = pm.load_catalog()
    inc = cat.get("incident")
    assert inc.agent_role == "incident-manager"
    assert {"id": "incident-responder", "state": "built"} in inc.specialists
    assert len(cat.specialists_source.get("sha256", "")) == 64


def test_the_specialists_page_shows_built_and_served_as_two_facts(world):
    c, _ = cases_client(world)
    t = c.get("/platform/specialists").text
    row = t.split("<code>incident-responder</code>")[1].split("</tr>")[0]
    assert "Built" in row and "Served" in row and "1.2.0" in row
    row = t.split("<code>problem-analyst</code>")[1].split("</tr>")[0]
    assert "Not served" in row, "built but not in the host's index"
    row = t.split("<code>capacity-analyst</code>")[1].split("</tr>")[0]
    assert "Proposed" in row and "Not served" not in row


def test_drift_between_the_catalog_and_the_hosts_roles_file_is_named(world):
    host = Host()
    host.index["roles"]["sha256"] = "f" * 64
    c, _ = cases_client(world, host)
    for path in ("/platform/specialists", "/platform/agents/incident"):
        assert "Out of date" in c.get(path).text, path


def test_the_generator_changes_the_page_and_its_check_goes_red_without_a_rerun(world, tmp_path):
    """change a specialist's state in the roles file, re-run the script, and the page changes; without
    the re-run, --check goes red."""
    roles = tmp_path / "roles.yaml"
    cat = tmp_path / "catalog.yaml"
    shutil.copy(pm.DEFAULT_CATALOG, cat)
    import yaml
    doc = {"schema": 1, "roles": []}
    loaded = pm.load_catalog(str(cat))
    for a in loaded.all():
        doc["roles"].append({"id": a.agent_role, "title": a.name, "specialists": [dict(s) for s in a.specialists]})
    roles.write_text(yaml.safe_dump(doc, sort_keys=False))
    run = lambda *a: subprocess.run([sys.executable, GEN, *a], capture_output=True, text=True)
    assert run(str(roles), str(cat)).returncode == 0
    assert run("--check", str(roles), str(cat)).returncode == 0
    cap = next(r for r in doc["roles"] if r["id"] == "capacity-manager")
    cap["specialists"][0]["state"] = "built"
    roles.write_text(yaml.safe_dump(doc, sort_keys=False))
    r = run("--check", str(roles), str(cat))
    assert r.returncode == 1 and "stale" in r.stdout
    c, _ = cases_client(world, catalogFile=str(cat))
    before = c.get("/platform/specialists").text.split("<code>capacity-analyst</code>")[1].split("</tr>")[0]
    assert "Proposed" in before
    assert run(str(roles), str(cat)).returncode == 0
    assert run("--check", str(roles), str(cat)).returncode == 0
    c, _ = cases_client(world, catalogFile=str(cat))
    after = c.get("/platform/specialists").text.split("<code>capacity-analyst</code>")[1].split("</tr>")[0]
    assert "Built" in after
    assert open(cat).read().count("# Platform Management catalog") == 1, "every other line is left as it was"


def test_the_generator_refuses_two_rosters_that_disagree(tmp_path):
    import yaml
    roles = tmp_path / "roles.yaml"
    roles.write_text(yaml.safe_dump({"roles": [{"id": "x-role", "title": "Nobody Here", "specialists": []}]}))
    r = subprocess.run([sys.executable, GEN, "--check", str(roles), pm.DEFAULT_CATALOG], capture_output=True, text=True)
    assert r.returncode == 1 and "not one roster" in r.stdout


def test_a_catalog_specialist_with_a_bad_state_is_the_pages_503(world, tmp_path):
    bad = tmp_path / "c.yaml"
    bad.write_text(open(pm.DEFAULT_CATALOG).read().replace("{id: incident-responder, state: built}",
                                                            "{id: incident-responder, state: shipped}"))
    with pytest.raises(pm.CatalogError, match="state"):
        pm.load_catalog(str(bad))

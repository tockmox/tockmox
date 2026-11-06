# SPDX-License-Identifier: Apache-2.0
"""Open a change from the page that renders it: the models and inference-node changes, and making someone an
administrator (sso.adminUsers), opened as the change bot in the site's forge, waiting for an approval.

  service    a page stages the blocks it rendered; only the blocks a kind may set, each parsing as the page's own
             parsers would; the confirm shows the exact diff against main; a confirmed intent opens one change that
             edits only those keys and keeps the rest of the file (comments too); the same change asked for again
             opens nothing; a file that moved on main since Argo CD applied it is refused; add-admin is computed
             from main and refused when the name is there already
  console    Open as a change on the models and nodes pages when the lane is on; with it off, the page still renders
             the change to download; the result names the change's number

Run from tockmox-ui/: python -m pytest tests
"""
import base64
import html
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402
from app import actions_service as svcmod  # noqa: E402
from app import nodes as nm  # noqa: E402
from tests import test_actions as base  # noqa: E402
from tests import test_changes as tc  # noqa: E402
from tests.proto_support import lifecycle_full_doc, write_report  # noqa: E402
from tests.test_models_ui import CANDS  # noqa: E402

AI = "site/values/ai.yaml"
IDENT = "site/values/identity.yaml"
AP = "d" * 40                                     # the site commit Argo CD last applied for the AI layer


def site_ai_text() -> str:
    d = lifecycle_full_doc()
    body = yaml.dump({"modelLifecycle": d["modelLifecycle"], "inferenceNodes": d["inferenceNodes"]},
                     Dumper=nm._Dumper, sort_keys=False, width=120)
    return ("# AI layer: kept by hand. The console edits only what a change names.\n"
            "litellm:\n  masterKeySecret: tockmox-litellm   # rotated by hand\n\n" + body +
            "\n# the console\ntockmoxUi:\n  enabled: true\n")


IDENT_TEXT = "# identity\nsso:\n  enabled: true\n  # who administers this site\n  adminUsers:\n    - jeff\n"


def forge():
    fg = tc.Forge()
    fg.files["main"].update({AI: site_ai_text(), IDENT: IDENT_TEXT})
    fg.files[AP] = dict(fg.files["main"])
    return fg


def service(tmp_path, fg=None):
    return tc.service(tmp_path, fg or forge())


def draft(what="models", **over):
    d = lifecycle_full_doc()
    lc = dict(d["modelLifecycle"], promotion={"requiredPasses": 2})
    edits = [{"path": ["modelLifecycle"], "value": lc}] if what == "models" else []
    edits.append({"path": ["inferenceNodes"], "value": d["inferenceNodes"]})
    edits.append({"path": list(svcmod._ROLL), "value": "0123456789abcdef"})
    return dict({"what": what, "title": "Require two passes to promote", "summary": "Two passes, not three.",
                 "edits": edits}, **over)


def opened(fg, n=-1):
    """The file the n-th commit wrote, and its branch."""
    who, b = fg.contents_posts[n]
    f = b["files"][0]
    return who, b, f, base64.b64decode(f["content"]).decode()


def confirm_and_open(s, kind, target, **tok):
    it = act.intent(kind, target, {}, "a")
    return s.handle({"intent": it, "id_token": base.token(act.nonce_for(it), **tok)})


# ---------------------------------------------------------------- shared

def test_open_kinds_are_changes_kinds_and_only_add_admin_steps_up(tmp_path):
    assert act.KINDS["open-change"][0] == act.KINDS["add-admin"][0] == "changes"
    assert not act.step_up("open-change") and act.step_up("add-admin")
    with pytest.raises(act.Refused, match="not turned on"):
        act.check(act.parse(dict(base.ACTIONS, url="http://a.test")),
                  act.intent("add-admin", {"username": "dawn"}, {}, "a"))


@pytest.mark.parametrize("kind,target,why", [
    ("open-change", {"what": "secrets", "draft": "0" * 64, "title": "x"}, "names what it changes"),
    ("open-change", {"what": "models", "draft": "nope", "title": "x"}, "names what it changes"),
    ("open-change", {"what": "models", "draft": "0" * 64, "title": "x", "file": "../../etc"}, "names what it changes"),
    ("open-change", {"what": "models", "draft": "0" * 64, "title": "a\nb"}, "one line"),
    ("open-change", {"what": "models", "draft": "0" * 64, "title": "x", "applied": "main"}, "not a commit"),
    ("add-admin", {"username": "two words"}, "no spaces"),
    ("add-admin", {"username": "dawn", "group": "x"}, "no spaces"),
])
def test_check_refuses_a_malformed_open_intent(tmp_path, kind, target, why):
    with pytest.raises(act.Refused, match=why):
        act.check(act.parse(tc.actions_on(tmp_path)), act.intent(kind, target, {}, "a"))


def test_values_files_are_paths_inside_the_site_repository():
    for bad in ({"models": "/etc/passwd.yaml"}, {"models": "../up.yaml"}, {"models": "x.json"}, {"secrets": "a.yaml"}):
        with pytest.raises(ValueError):
            act.parse({"changes": {"valuesFiles": bad}})
    c = act.parse({"changes": {"valuesFiles": {"models": "site/values/models.yaml"}}})
    assert c.values_file("models") == "site/values/models.yaml" and c.values_file("identity") == IDENT


# ---------------------------------------------------------------- staging a draft

def test_a_draft_may_set_only_its_kinds_blocks_and_each_must_parse(tmp_path):
    s, fg, _ = service(tmp_path)
    assert len(s.stage_draft(draft())) == 64
    for bad, why in [
        (draft(what="secrets"), "no such kind"),
        (draft(edits=[{"path": ["tockmoxUi"], "value": {}}]), "may not set tockmoxUi"),
        (draft(what="nodes", edits=[{"path": ["modelLifecycle"], "value": {}}]), "may not set modelLifecycle"),
        (draft(edits=[{"path": ["inferenceNodes"], "value": {}}, {"path": ["inferenceNodes"], "value": {}}]), "may not set"),
        (draft(edits=[{"path": ["inferenceNodes"], "value": {"nodes": "not a list"}}]), "inferenceNodes is not valid"),
        (draft(edits=[{"path": list(svcmod._ROLL), "value": "not-a-hash"}]), "16-character hash"),
        (draft(title="a\nb"), "one line"),
        (dict(draft(), extra=1), "what, title, summary and edits"),
    ]:
        with pytest.raises(act.Refused, match=why):
            s.stage_draft(bad)


def test_a_draft_older_than_its_time_or_unknown_is_not_opened(tmp_path):
    s, fg, _ = service(tmp_path)
    d = s.stage_draft(draft())
    t = {"what": "models", "draft": d, "title": "Require two passes to promote", "applied": AP}
    assert s.preview("open-change", t)["diff"]
    s.now = lambda: 10 ** 10
    with pytest.raises(act.Refused, match="drawn too long ago"):
        s.preview("open-change", t)
    with pytest.raises(act.Refused, match="drawn too long ago"):
        s.preview("open-change", dict(t, draft="e" * 64))


# ---------------------------------------------------------------- opening it

def test_a_confirmed_change_edits_only_its_blocks_and_waits_for_an_approval(tmp_path):
    s, fg, _ = service(tmp_path)
    d = s.stage_draft(draft())
    t = {"what": "models", "draft": d, "title": "Require two passes to promote", "applied": AP}
    pv = s.preview("open-change", t)
    assert pv["path"] == AI and "+    requiredPasses: 2" in pv["diff"] and "-  masterKeySecret" not in pv["diff"]
    code, out = confirm_and_open(s, "open-change", t)
    assert code == 200 and out["result"] == "done", out
    assert out["detail"] == "opened as #8, waiting for an approval" and out["ref"] == ["#8"]
    who, b, f, text = opened(fg)
    assert who == "tockmox-change-bot" and b["branch"] == "main" and b["new_branch"].startswith("tockmox/console-models-")
    assert f == dict(f, operation="update", path=AI, sha=tc.sha_of(fg.files["main"][AI]))
    assert "masterKeySecret: tockmox-litellm   # rotated by hand" in text and "# the console\ntockmoxUi:" in text
    got = yaml.safe_load(text)
    assert got["modelLifecycle"]["promotion"] == {"requiredPasses": 2}
    assert got["litellm"] == {"masterKeySecret": "tockmox-litellm",
                              "podAnnotations": {"tockmox.com/node-routes": "0123456789abcdef"}}
    assert got["tockmoxUi"] == {"enabled": True}
    login, pr = fg.opened[-1]
    assert login == "tockmox-change-bot" and pr["head"] == b["new_branch"] and pr["base"] == "main"
    assert pr["body"].startswith("Two passes, not three.") and "Tockmox-Origin: console" in pr["body"]
    assert "Jeff" in pr["body"] and "Jeff" in b["message"]                    # who asked for it travels with it
    assert fg.reviews == [] and fg.merges == []                                # nothing is applied


def test_the_same_change_asked_for_again_opens_nothing(tmp_path):
    s, fg, _ = service(tmp_path)
    t = {"what": "models", "draft": s.stage_draft(draft()), "title": "Require two passes to promote", "applied": AP}
    it = act.intent("open-change", t, {}, "a")
    tok = base.token(act.nonce_for(it))
    assert s.handle({"intent": it, "id_token": tok})[1]["detail"].startswith("opened as #8")
    code, again = s.handle({"intent": it, "id_token": tok})                   # the same confirmation, twice
    assert code == 200 and again.get("repeat") and len(fg.opened) == 1
    code, out = confirm_and_open(s, "open-change", t)                          # a second click: a new key, same change
    assert code == 200 and out["detail"] == "already open as #8; nothing new was opened", out
    assert len(fg.opened) == 1 and len(fg.contents_posts) == 1


def test_a_file_that_moved_on_main_since_it_was_applied_is_refused(tmp_path):
    fg = forge()
    fg.files["main"][AI] = fg.files["main"][AI].replace("rotated by hand", "rotated again")   # merged, not applied yet
    s, fg, _ = service(tmp_path, fg)
    t = {"what": "models", "draft": s.stage_draft(draft()), "title": "Require two passes to promote", "applied": AP}
    with pytest.raises(act.Refused, match="has changed on main since Argo CD last applied it"):
        s.preview("open-change", t)
    code, out = confirm_and_open(s, "open-change", t)
    assert code == 403 and "since Argo CD last applied it" in out["reason"] and fg.contents_posts == []


def test_what_main_already_says_and_a_layout_it_cannot_edit_open_nothing(tmp_path):
    s, fg, _ = service(tmp_path)
    same = draft(edits=[{"path": ["inferenceNodes"], "value": lifecycle_full_doc()["inferenceNodes"]}])
    t = {"what": "models", "draft": s.stage_draft(same), "title": same["title"], "applied": AP}
    with pytest.raises(act.Refused, match="already says this"):
        s.preview("open-change", t)
    for ref in ("main", AP):
        fg.files[ref][AI] = "x: &cat {catalog: []}\nmodelLifecycle: *cat\n"
    t = {"what": "models", "draft": s.stage_draft(draft()), "title": draft()["title"], "applied": AP}
    with pytest.raises(act.Refused, match="anchors, aliases or merge keys; edit it by hand"):
        s.preview("open-change", t)
    assert fg.contents_posts == []


def test_a_forge_that_does_not_answer_opens_nothing(tmp_path):
    s, fg, _ = service(tmp_path)
    t = {"what": "models", "draft": s.stage_draft(draft()), "title": draft()["title"], "applied": AP}
    fg.down = True
    code, out = confirm_and_open(s, "open-change", t)
    assert code == 403 and "nothing was opened" in out["reason"] and fg.opened == []


def test_the_models_file_can_be_the_model_watchers(tmp_path):
    fg = forge()
    for ref in ("main", AP):
        fg.files[ref]["site/values/models.yaml"] = fg.files[ref].pop(AI)
    s, fg, _ = tc.service(tmp_path, fg, valuesFiles={"models": "site/values/models.yaml"})
    t = {"what": "models", "draft": s.stage_draft(draft()), "title": draft()["title"], "applied": AP}
    assert confirm_and_open(s, "open-change", t)[0] == 200
    assert opened(fg)[2]["path"] == "site/values/models.yaml"


# ---------------------------------------------------------------- make someone an administrator

def test_add_admin_appends_to_what_main_says_and_keeps_the_file(tmp_path):
    s, fg, _ = service(tmp_path)
    pv = s.preview("add-admin", {"username": "dawn"})
    assert pv["path"] == IDENT and "+    - dawn" in pv["diff"]
    code, out = confirm_and_open(s, "add-admin", {"username": "dawn"}, auth_time=int(__import__("time").time()))
    assert code == 200, out
    _, b, f, text = opened(fg)
    assert b["new_branch"].startswith("tockmox/console-admin-") and fg.opened[-1][1]["title"] == "Make dawn an administrator"
    assert text == IDENT_TEXT + "    - dawn\n"
    with pytest.raises(act.Refused, match="jeff is already in sso.adminUsers"):
        s.preview("add-admin", {"username": "jeff"})


def test_add_admin_needs_a_fresh_sign_in(tmp_path):
    s, fg, _ = service(tmp_path)
    code, out = confirm_and_open(s, "add-admin", {"username": "dawn"}, auth_time=1)
    assert code == 403 and fg.opened == [], out


def test_add_admin_makes_the_list_when_the_file_has_none(tmp_path):
    fg = forge()
    del fg.files["main"][IDENT]
    s, fg, _ = service(tmp_path, fg)
    code, out = confirm_and_open(s, "add-admin", {"username": "dawn"}, auth_time=int(__import__("time").time()))
    assert code == 200, out
    _, _, f, text = opened(fg)
    assert f["operation"] == "create" and "sha" not in f and yaml.safe_load(text) == {"sso": {"adminUsers": ["dawn"]}}


# ---------------------------------------------------------------- the console

def ui(tmp_path, fg=None, actions=None, site_rev=AP):
    fg = fg or forge()
    a = actions if actions is not None else tc.actions_on(tmp_path)
    full = lifecycle_full_doc(report=write_report(tmp_path, CANDS))
    extra = {k: full[k] for k in ("modelLifecycle", "inferenceNodes")}
    apps = None
    if site_rev is not None:
        from tests.test_status_api import app_obj
        ai = app_obj("tockmox-ai", path="charts/tockmox-ai")
        ai["spec"] = {"sources": [dict(ai["spec"]["source"]), {"repoURL": "http://forge/site.git", "ref": "site"}]}
        ai["status"]["sync"]["revisions"] = ["e" * 40, site_rev]
        apps = [ai]
    c, csrf, idp, am, kube, sent = base.console(tmp_path, actions=a, forge=fg.handler, extra=extra, apps=apps)
    return c, csrf, idp, fg, sent


def follow(c, idp, r):
    """From a confirm panel's form to the result page, through the identity provider."""
    t = r.text
    form = {k: html.unescape(v) for k, v in re.findall(r'<input type="hidden" name="([a-z]+)" value="([^"]*)"', t)}
    r = c.post("/actions/go", data=form)
    assert r.status_code == 303, r.text
    q = parse_qs(urlsplit(r.headers["location"]).query)
    idp.next_claims = {"nonce": q["nonce"][0]}
    return c.get(f"/auth/callback?code=c&state={q['state'][0]}")


def test_admit_from_the_page_opens_one_change_and_says_its_number(tmp_path):
    c, csrf, idp, fg, sent = ui(tmp_path)
    form = {"csrf": csrf, "cid": CANDS[0]["id"]}                             # admit a successor: a -next route
    t = c.post("/models/propose", data=form).text
    assert "Open as a change" in t and "Download it" in t
    r = c.post("/models/propose", data=dict(form, fmt="open"))
    assert r.status_code == 303 and r.headers["location"].startswith("/actions/confirm?kind=open-change"), r.text
    r = c.get(r.headers["location"])
    assert r.status_code == 200, r.text
    assert "The exact change to <code>site/values/ai.yaml</code>" in r.text and "Open this as a change" in r.text
    res = follow(c, idp, r)
    assert res.status_code == 200 and "opened as #8, waiting for an approval" in res.text, res.text
    assert sent[-1]["intent"]["kind"] == "open-change" and sent[-1]["intent"]["target"]["applied"] == AP
    text = opened(fg)[3]
    assert "masterKeySecret: tockmox-litellm   # rotated by hand" in text
    # a second click on the same change opens nothing new
    r = c.get(c.post("/models/propose", data=dict(form, fmt="open")).headers["location"])
    assert "already open as #8" in follow(c, idp, r).text and len(fg.opened) == 1


def test_with_the_lane_off_the_page_still_renders_the_change_to_download(tmp_path):
    a = dict(base.ACTIONS)
    c, csrf, idp, fg, _ = ui(tmp_path, actions=a)
    form = {"csrf": csrf, "cid": CANDS[0]["id"]}
    t = c.post("/models/propose", data=form).text
    assert "Open as a change" not in t and "Download it" in t and "Commit this to" in t
    r = c.post("/models/propose", data=dict(form, fmt="open"))
    assert r.status_code == 404 and "download the change instead" in r.text and fg.opened == []
    assert c.post("/models/propose", data=dict(form, fmt="yaml")).headers["content-type"].startswith("application/yaml")


def test_no_applied_revision_no_open(tmp_path):
    c, csrf, idp, fg, _ = ui(tmp_path, site_rev=None)
    r = c.post("/models/propose", data={"csrf": csrf, "cid": CANDS[0]["id"], "fmt": "open"})
    assert r.status_code == 409 and "could not be read" in r.text and fg.opened == []


def test_a_change_that_moved_is_refused_on_the_confirm_panel_before_any_sign_in(tmp_path):
    fg = forge()
    fg.files["main"][AI] += "# merged since\n"
    c, csrf, idp, fg, sent = ui(tmp_path, fg=fg)
    r = c.get(c.post("/models/propose", data={"csrf": csrf, "cid": CANDS[0]["id"], "fmt": "open"}).headers["location"])
    assert r.status_code == 409 and "since Argo CD last applied it" in r.text and sent == []


def test_identity_offers_make_an_administrator_with_only_the_changes_lane_on(tmp_path):
    c, csrf, idp, fg, sent = ui(tmp_path)
    t = c.get("/platform/identity").text
    assert "Make an administrator" in t and "Recovery link" not in t
    r = c.get("/actions/confirm?kind=add-admin&username=dawn")
    assert r.status_code == 200 and "+    - dawn" in html.unescape(r.text) and "sign in again" in r.text
    assert c.get("/actions/confirm?kind=add-admin&username=jeff").status_code == 409


def test_an_intent_must_name_the_draft_as_it_was_staged(tmp_path):
    s, fg, _ = service(tmp_path)
    d = s.stage_draft(draft())
    for t in ({"what": "models", "draft": d, "title": "Something else entirely", "applied": AP},
              {"what": "nodes", "draft": d, "title": draft()["title"], "applied": AP}):
        code, out = confirm_and_open(s, "open-change", t)
        assert code == 403 and "not the one this action names" in out["reason"], out
    assert fg.opened == []


def test_a_node_change_from_the_nodes_page_opens_one_change(tmp_path):
    import json
    c, csrf, idp, fg, sent = ui(tmp_path)
    inv = nm.inventory_to_doc(nm.parse_inventory(lifecycle_full_doc()["inferenceNodes"]))
    node = dict(inv["nodes"][0], name="Renamed in the console")
    d = json.dumps({"nodes": [node], "routes": []})
    t = c.post("/nodes/change", data={"csrf": csrf, "draft": d}).text
    assert "Open as a change" in t
    r = c.post("/nodes/change", data={"csrf": csrf, "draft": d, "format": "open"})
    assert r.status_code == 303 and "what=nodes" in r.headers["location"], r.text
    res = follow(c, idp, c.get(r.headers["location"]))
    assert "opened as #8" in res.text, res.text
    got = yaml.safe_load(opened(fg)[3])
    assert {n["id"]: n["name"] for n in got["inferenceNodes"]["nodes"]}[node["id"]] == "Renamed in the console"
    assert got["modelLifecycle"] == yaml.safe_load(site_ai_text())["modelLifecycle"]       # a node change leaves it
    assert fg.opened[-1][1]["title"].startswith("Inference nodes: Renamed in the console")

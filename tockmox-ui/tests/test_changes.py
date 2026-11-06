# SPDX-License-Identifier: Apache-2.0
"""Platform > Changes: approve and apply, decline and revert the site's changes from the console, through
tockmox-actions, as the person's own forge identity, with the approver in the merge commit.

  shared     the change kinds' targets and parameters; every one is a step-up kind; off means absent
  service    approve: the person's token from the forge's OAuth2 code (PKCE, the client secret only here), the forge
             login must be the identity provider's username, an APPROVED review of exactly the head shown, and a
             MERGE commit (not a squash) carrying Approved-by; the forge's branch rule decides (a person outside the
             approvers team is refused there); a head that moved is refused before anything; decline closes with a
             comment as the person; revert opens the opposite change as the bot and refuses when a file moved since
  console    the page lists waiting changes with summary, checks and the diff behind a fold; Approve takes the
             browser to the forge's sign-in and then the identity provider's step-up; a member who is not an
             administrator gets no page and no button; a forge that does not answer reads "Changes paused"

The fake forge models what was measured on Forgejo 15.0.11 on the lab: the change bot cannot approve, a merge
needs an approval of the head from the approvers team (405 otherwise), Do=merge keeps the merge message's
Approved-by line and Do=squash would not. Run from tockmox-ui/: python -m pytest tests
"""
import base64
import copy
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402
from app import forge as forge_mod  # noqa: E402
from tests import test_actions as base  # noqa: E402

API = "http://forge.test:3000/api/v1"
TOKEN_URL = "http://forge.test:3000/login/oauth/access_token"
AUTHORIZE = "https://forge.int.example.com/login/oauth/authorize"
BOT_TOKEN = "b" * 40
CLIENT_SECRET = "only-the-service"
REPO = "tockmox/site"
H1, H2, M0, M1, P0 = "1" * 40, "2" * 40, "a" * 40, "b" * 40, "c" * 40


def b64(s: str) -> str:
    return base64.b64encode(s.encode()).decode()


def sha_of(s: str) -> str:
    return hashlib.sha1(s.encode()).hexdigest()


class Forge:
    """Forgejo 15 as far as the change kinds reach it."""

    def __init__(self):
        self.users = {BOT_TOKEN: {"login": "tockmox-change-bot", "full_name": "", "email": "bot@forge.invalid"}}
        self.approvers = {"jeff"}
        self.teams_readable = True          # the person's token can list the approvers team (self-approval check)
        self.codes = {}                     # code -> (login, challenge)
        self.down = False
        self.files = {"main": {"site/values/models.yaml": "models: [a]\n", "README.md": "# site\n"},
                      M0: {"site/values/models.yaml": "models: [a]\n", "README.md": "# site\n"},
                      P0: {"site/values/models.yaml": "models: []\n", "README.md": "# site\n"}}
        self.pulls = {
            7: {"number": 7, "title": "Admit qwen3-coder as a candidate", "state": "open", "merged": False,
                "body": "Adds qwen3-coder at stage candidate behind local-coder-next.\n\nTockmox-Origin: model-watcher",
                "user": {"login": "tockmox-change-bot"}, "head": {"sha": H1, "ref": "watch/qwen"}, "base": {"ref": "main"},
                "mergeable": True, "created_at": "2026-11-05T15:00:00Z", "updated_at": "2026-11-05T15:00:00Z",
                "diff": "diff --git a/site/values/models.yaml b/site/values/models.yaml\n+  - qwen3-coder\n"},
            5: {"number": 5, "title": "Add model a", "state": "closed", "merged": True, "merge_commit_sha": M0,
                "merged_at": "2026-11-04T10:00:00Z", "merged_by": {"login": "jeff", "full_name": "Jeff"},
                "body": "Adds a.", "user": {"login": "tockmox-change-bot"}, "head": {"sha": "9" * 40},
                "base": {"ref": "main"}},
        }
        self.commits = {M0: {"parents": [{"sha": P0}], "files": [{"filename": "site/values/models.yaml", "status": "modified"}]}}
        self.reviews, self.merges, self.comments, self.contents_posts, self.opened = [], [], [], [], []
        self.statuses = {H1: {"state": "success", "statuses": [{"context": "render", "status": "success", "description": "ok"}]}}

    def person(self, login, name, email):
        tok = "p-" + login
        self.users[tok] = {"login": login, "full_name": name, "email": email}
        return tok

    def code_for(self, login, challenge):
        code = f"code-{login}-{len(self.codes)}"
        self.codes[code] = (login, challenge)
        return code

    def handler(self, req: httpx.Request):
        if self.down:
            raise httpx.ConnectError("refused", request=req)
        u = urlsplit(str(req.url))
        p, m = u.path, req.method
        if p == "/login/oauth/access_token" and m == "POST":
            f = parse_qs(req.content.decode())
            code = (f.get("code") or [""])[0]
            if (f.get("client_secret") or [""])[0] != CLIENT_SECRET or code not in self.codes:
                return httpx.Response(400, json={"error": "invalid_grant"})
            login, challenge = self.codes.pop(code)
            v = (f.get("code_verifier") or [""])[0]
            if base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode() != challenge:
                return httpx.Response(400, json={"error": "invalid_grant", "error_description": "PKCE"})
            tok = next(t for t, x in self.users.items() if x["login"] == login)
            return httpx.Response(200, json={"access_token": tok, "token_type": "bearer"})
        auth = req.headers.get("authorization", "")
        me = self.users.get(auth.removeprefix("token "))
        if not me:
            return httpx.Response(401, json={"message": "token is required"})
        p = p.removeprefix("/api/v1")
        if p == "/user":
            return httpx.Response(200, json=me)
        org = REPO.split("/")[0]
        if p == f"/orgs/{org}/teams/search" and m == "GET":
            if not self.teams_readable:
                return httpx.Response(403, json={"message": "token does not have at least one of required scope(s)"})
            q = req.url.params.get("q", "")
            return httpx.Response(200, json={"ok": True, "data": [{"id": 3, "name": "approvers"}] if q in "approvers" else []})
        if p == "/teams/3/members" and m == "GET":
            if not self.teams_readable:
                return httpx.Response(403, json={"message": "forbidden"})
            return httpx.Response(200, json=[{"login": x} for x in sorted(self.approvers)])
        base_ = f"/repos/{REPO}"
        if p == base_ + "/pulls" and m == "GET":
            st = req.url.params.get("state")
            return httpx.Response(200, json=[{k: v for k, v in x.items() if k != "diff"} for x in self.pulls.values()
                                             if x["state"] == st])
        if p == base_ + "/pulls" and m == "POST":
            b = json.loads(req.content)
            n = max(self.pulls) + 1
            self.pulls[n] = {"number": n, "title": b["title"], "body": b["body"], "state": "open", "merged": False,
                             "user": {"login": me["login"]}, "head": {"sha": "f" * 40, "ref": b["head"]},
                             "base": {"ref": b["base"]}}
            self.opened.append((me["login"], b))
            return httpx.Response(201, json=self.pulls[n])
        mt = re.fullmatch(base_ + r"/pulls/(\d+)\.diff", p)
        if mt:
            x = self.pulls.get(int(mt.group(1)))
            return httpx.Response(200, text=x.get("diff", "")) if x else httpx.Response(404)
        mt = re.fullmatch(base_ + r"/pulls/(\d+)", p)
        if mt:
            x = self.pulls.get(int(mt.group(1)))
            if not x:
                return httpx.Response(404, json={"message": "not found"})
            if m == "PATCH":
                x.update(json.loads(req.content))
            return httpx.Response(200, json={k: v for k, v in x.items() if k != "diff"})
        mt = re.fullmatch(base_ + r"/pulls/(\d+)/reviews", p)
        if mt and m == "POST":
            b = json.loads(req.content)
            if me["login"] == "tockmox-change-bot":
                return httpx.Response(422, json={"message": "approve your own pull is not allowed"})
            self.reviews.append((int(mt.group(1)), me["login"], b))
            return httpx.Response(200, json={"id": len(self.reviews)})
        mt = re.fullmatch(base_ + r"/pulls/(\d+)/merge", p)
        if mt and m == "POST":
            n, b = int(mt.group(1)), json.loads(req.content)
            x = self.pulls[n]
            ok = any(r[0] == n and r[1] in self.approvers and r[2]["event"] == "APPROVED" and r[2]["commit_id"] == x["head"]["sha"]
                     for r in self.reviews)
            if not ok:
                return httpx.Response(405, json={"message": "Does not have enough approvals"})
            msg = b.get("MergeMessageField", "") if b.get("Do") == "merge" else ""      # squash drops it (measured)
            sha = M1
            self.merges.append({"number": n, "by": me["login"], "do": b.get("Do"), "message": msg, "sha": sha})
            x.update(state="closed", merged=True, merge_commit_sha=sha, merged_at="2026-11-05T16:00:00Z",
                     merged_by={"login": me["login"], "full_name": me["full_name"]})
            return httpx.Response(200)
        mt = re.fullmatch(base_ + r"/issues/(\d+)/comments", p)
        if mt and m == "POST":
            self.comments.append((int(mt.group(1)), me["login"], json.loads(req.content)["body"]))
            return httpx.Response(201, json={})
        mt = re.fullmatch(base_ + r"/commits/([0-9a-f]{40})/status", p)
        if mt:
            return httpx.Response(200, json=self.statuses.get(mt.group(1), {"state": "", "statuses": []}))
        mt = re.fullmatch(base_ + r"/git/commits/([0-9a-f]{40})", p)
        if mt:
            c = self.commits.get(mt.group(1))
            return httpx.Response(200, json=c) if c else httpx.Response(404)
        mt = re.fullmatch(base_ + r"/contents/(.+)", p)
        if mt and m == "GET":
            tree = self.files.get(req.url.params.get("ref", "main"), {})
            body = tree.get(mt.group(1))
            if body is None:
                pre = mt.group(1).rstrip("/") + "/"
                kids = sorted(k for k in tree if k.startswith(pre) and "/" not in k[len(pre):])
                if kids:                                  # a folder: its direct files, as Forgejo lists them
                    return httpx.Response(200, json=[{"type": "file", "name": k[len(pre):], "path": k} for k in kids])
                return httpx.Response(404, json={"message": "not found"})
            return httpx.Response(200, json={"type": "file", "encoding": "base64", "content": b64(body), "sha": sha_of(body)})
        if p == base_ + "/contents" and m == "POST":
            b = json.loads(req.content)
            self.contents_posts.append((me["login"], b))
            return httpx.Response(201, json={})
        return httpx.Response(404, json={"message": f"no {m} {p}"})


def actions_on(tmp_path, **over):
    bot = tmp_path / "bot-token"
    bot.write_text(BOT_TOKEN + "\n")
    cs = tmp_path / "client-secret"
    cs.write_text(CLIENT_SECRET)
    a = copy.deepcopy(base.ACTIONS)
    a["changes"] = dict({"enabled": True, "apiUrl": API, "repo": REPO, "botTokenFile": str(bot),
                         "webUrl": "https://forge.int.example.com",
                         "oauth": {"authorizeUrl": AUTHORIZE, "tokenUrl": TOKEN_URL, "clientId": "tockmox-console",
                                   "clientSecretFile": str(cs)}}, **over)
    return a


def service(tmp_path, fg=None, **over):
    fg = fg or Forge()
    s, am, kube = base.service(actions=actions_on(tmp_path, **over))
    s.forge.transport = httpx.MockTransport(fg.handler)
    return s, fg, kube


def pkce():
    v = "v" * 43
    return v, base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()


def go(s, fg, it, login="jeff", name="Jeff", email="jeff@example.com", claims=None, verifier=None, **tok):
    fg.person(login, name, email)
    v, ch = pkce()
    code = fg.code_for(login, ch)
    c = dict({"preferred_username": "jeff"}, **(claims or {}))
    return s.handle({"intent": it, "id_token": base.token(act.nonce_for(it), **c, **tok),
                     "forge": {"code": code, "verifier": verifier or v, "redirect_uri": "https://ui.test/actions/forge/callback"}})


def approve(n=7, head=H1, title="Admit qwen3-coder as a candidate"):
    return act.intent("approve-change", {"number": n, "title": title, "head": head}, {}, "a")


# ---------------------------------------------------------------- shared

def test_change_kinds_are_step_up_and_off_unless_turned_on(tmp_path):
    assert all(act.step_up(k) for k in act.CHANGE_KINDS)
    off = act.parse(dict(base.ACTIONS, url="http://a.test"))
    with pytest.raises(act.Refused, match="not turned on"):
        act.check(off, approve())
    on = act.parse(actions_on(tmp_path))
    assert act.check(on, approve())


@pytest.mark.parametrize("target,params,why", [
    ({"number": 0, "title": "x", "head": H1}, {}, "by its number"),
    ({"number": True, "title": "x", "head": H1}, {}, "by its number"),
    ({"number": 7, "title": "x\ny", "head": H1}, {}, "one line"),
    ({"number": 7, "title": "x", "head": "abc"}, {}, "head commit"),
    ({"number": 7, "title": "x", "head": H1, "extra": 1}, {}, "head commit"),
    ({"number": 7, "title": "x", "head": H1}, {"force": True}, "takes no parameters"),
])
def test_check_refuses_a_malformed_change_intent(tmp_path, target, params, why):
    with pytest.raises(act.Refused, match=why):
        act.check(act.parse(actions_on(tmp_path)), act.intent("approve-change", target, params, "a"))


def test_a_malformed_changes_block_stops_the_process():
    for bad in ({"changes": {"enabled": True, "repo": "no-slash"}}, {"changes": {"apiUrl": "ftp://x"}},
                {"changes": {"oauth": {"clientSecret": "inline"}}}, {"changes": {"token": "x"}}):
        with pytest.raises(ValueError):
            act.parse(bad)


# ---------------------------------------------------------------- the service

def test_an_approval_by_an_approver_merges_as_a_merge_commit_carrying_approved_by(tmp_path, capsys):
    s, fg, kube = service(tmp_path)
    code, out = go(s, fg, approve())
    assert code == 200 and out["result"] == "done", out
    assert fg.reviews == [(7, "jeff", {"event": "APPROVED", "commit_id": H1, "body": "Approved in the Tockmox console."})]
    m = fg.merges[0]
    assert (m["by"], m["do"]) == ("jeff", "merge"), "as the person, and a merge commit: a squash drops Approved-by"
    assert m["message"].rstrip().endswith("Approved-by: Jeff <jeff@example.com>"), m["message"]
    assert "Approved-by: Jeff" in out["detail"]
    line = json.loads([x for x in capsys.readouterr().out.splitlines() if "tockmox.action" in x][-1])
    assert line["action"] == "approve-change" and line["result"] == "done"
    assert "p-jeff" not in json.dumps(line) and "p-jeff" not in json.dumps(kube.cm), "the person's token is never kept"


def test_a_person_outside_the_approvers_team_is_refused_by_the_forge(tmp_path):
    s, fg, _ = service(tmp_path)
    code, out = go(s, fg, approve(), login="dawn", name="Dawn", email="dawn@example.com",
                   claims={"preferred_username": "dawn"})
    assert code == 403 and "branch rule is not met" in out["reason"], out
    assert fg.merges == [] and fg.pulls[7]["state"] == "open"


def test_the_forge_must_sign_in_the_same_person_the_identity_provider_did(tmp_path):
    s, fg, _ = service(tmp_path)
    code, out = go(s, fg, approve(), claims={"preferred_username": "dawn"})       # Authentik says dawn, forge says jeff
    assert code == 403 and "signed you in as jeff, not as dawn" in out["reason"], out
    assert fg.reviews == [] and fg.merges == []


def test_a_head_that_moved_is_refused_before_anything_is_done(tmp_path):
    s, fg, _ = service(tmp_path)
    fg.pulls[7]["head"]["sha"] = H2
    code, out = go(s, fg, approve(head=H1))
    assert code == 403 and "changed since you opened it" in out["reason"]
    assert fg.reviews == [] and fg.merges == []


def test_a_forged_intent_is_refused(tmp_path):
    s, fg, _ = service(tmp_path)
    it = approve()
    other = approve(n=7, head=H1, title="something else")                   # a token minted for another intent
    fg.person("jeff", "Jeff", "jeff@example.com")
    v, ch = pkce()
    code, out = s.handle({"intent": it, "id_token": base.token(act.nonce_for(other), preferred_username="jeff"),
                          "forge": {"code": fg.code_for("jeff", ch), "verifier": v, "redirect_uri": "x"}})
    assert code == 403 and "not made for this action" in out["reason"]
    code, out = go(s, fg, approve(), groups=("tockmox-users",))               # not an administrator
    assert code == 403 and "administrators" in out["reason"]
    assert fg.reviews == [] and fg.merges == []


def test_the_pkce_verifier_and_the_client_secret_are_both_needed(tmp_path):
    s, fg, _ = service(tmp_path)
    code, out = go(s, fg, approve(), verifier="w" * 43)
    assert code == 403 and "the forge refused the sign-in's code" in out["reason"]
    it = approve()
    code, out = s.handle({"intent": it, "id_token": base.token(act.nonce_for(it), preferred_username="jeff")})
    assert code == 403 and "did not come back with a code" in out["reason"], out
    (tmp_path / "client-secret").write_text("not-the-registered-secret")
    code, out = go(s, fg, approve())
    assert code == 403 and "the forge refused the sign-in's code" in out["reason"]
    assert fg.reviews == [] and fg.merges == []
    (tmp_path / "client-secret").write_text(CLIENT_SECRET)                    # and with both right, it acts
    code, out = go(s, fg, approve())
    assert code == 200 and fg.merges, out


def test_decline_closes_the_change_as_the_person_with_the_reason(tmp_path):
    s, fg, _ = service(tmp_path)
    it = act.intent("decline-change", {"number": 7, "title": "Admit", "head": H1}, {"reason": "not this week"}, "a")
    code, out = go(s, fg, it)
    assert code == 200, out
    assert fg.comments == [(7, "jeff", "Declined in the Tockmox console by Jeff: not this week")]
    assert fg.pulls[7]["state"] == "closed" and not fg.pulls[7]["merged"]


def test_revert_opens_the_opposite_change_as_the_bot(tmp_path):
    s, fg, _ = service(tmp_path)
    it = act.intent("revert-change", {"number": 5, "title": "Add model a", "merge": M0}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": base.token(act.nonce_for(it))})
    assert code == 200, out
    who, post = fg.contents_posts[0]
    assert who == "tockmox-change-bot" and post["new_branch"] == f"tockmox/revert-5-{M0[:7]}"
    assert post["files"] == [{"operation": "update", "path": "site/values/models.yaml",
                              "content": b64("models: []\n"), "sha": sha_of("models: [a]\n")}]
    assert fg.opened[0][0] == "tockmox-change-bot" and fg.opened[0][1]["title"] == "Revert: Add model a"
    assert fg.merges == [], "a revert waits for an approval like any change"


def test_revert_is_refused_when_a_file_changed_again_since(tmp_path):
    s, fg, _ = service(tmp_path)
    fg.files["main"]["site/values/models.yaml"] = "models: [a, b]\n"
    it = act.intent("revert-change", {"number": 5, "title": "Add model a", "merge": M0}, {}, "a")
    code, out = s.handle({"intent": it, "id_token": base.token(act.nonce_for(it))})
    assert code == 403 and "changed again after #5" in out["reason"]
    assert fg.contents_posts == []


def test_the_bot_cannot_approve_its_own_change():
    """What the fake models, as measured: a token for the bot gets 422 on a review."""
    fg = Forge()
    r = httpx.Client(transport=httpx.MockTransport(fg.handler)).post(
        f"{API}/repos/{REPO}/pulls/7/reviews", json={"event": "APPROVED", "commit_id": H1},
        headers={"authorization": "token " + BOT_TOKEN})
    assert r.status_code == 422


def test_the_forge_answers_through_the_service_endpoints(tmp_path):
    from fastapi.testclient import TestClient
    from app.actions_service import create_service
    s, fg, _ = service(tmp_path)
    c = TestClient(create_service(service=s))
    j = c.get("/v1/changes").json()
    assert [x["number"] for x in j["open"]] == [7] and [x["number"] for x in j["applied"]] == [5]
    row = j["open"][0]
    assert row["by"] == "the model watcher" and row["summary"].startswith("Adds qwen3-coder") and "Tockmox-Origin" not in row["summary"]
    assert row["checks"] == [{"context": "render", "state": "success", "description": "ok"}]
    assert "qwen3-coder" in c.get("/v1/changes/7/diff").json()["diff"]
    fg.down = True
    r = c.get("/v1/changes")
    assert r.status_code == 503 and r.json()["paused"] is True


# ---------------------------------------------------------------- the console

def wire(tmp_path, groups=("tockmox-admins",), on=True):
    fg = Forge()
    a = actions_on(tmp_path) if on else copy.deepcopy(base.ACTIONS)
    c, csrf, idp, am, kube, sent = base.console(tmp_path, actions=a, groups=groups, forge=fg.handler)
    return c, csrf, idp, fg, sent


def test_the_page_lists_waiting_changes_with_checks_the_diff_and_the_buttons(tmp_path):
    c, csrf, idp, fg, sent = wire(tmp_path)
    t = c.get("/platform/changes").text
    assert "#7 Admit qwen3-coder as a candidate" in t and "From the model watcher" in t
    assert "render: success" in t and "<details>" in t and "+  - qwen3-coder" in t
    assert f"kind=approve-change&amp;number=7&amp;head={H1}" in t and "kind=decline-change" in t
    assert "kind=revert-change&amp;number=5" in t
    assert 'href="/platform/changes"' in t                                       # on the rail


def test_a_member_who_is_not_an_administrator_gets_no_page_and_no_button(tmp_path):
    c, *_ = wire(tmp_path, groups=("tockmox-users",))
    r = c.get("/platform/changes")
    assert r.status_code == 403 and "approve-change" not in r.text


def test_off_means_no_page_and_no_rail_item(tmp_path):
    c, *_ = wire(tmp_path, on=False)
    assert c.get("/platform/changes").status_code == 404
    assert 'href="/platform/changes"' not in c.get("/platform/activity").text


def test_a_forge_that_does_not_answer_reads_changes_paused(tmp_path):
    c, csrf, idp, fg, sent = wire(tmp_path)
    fg.down = True
    t = c.get("/platform/changes").text
    assert "Changes paused" in t and "approve-change" not in t


def test_approve_end_to_end_through_the_forge_sign_in_then_the_step_up(tmp_path):
    c, csrf, idp, fg, sent = wire(tmp_path)
    t = c.get(f"/actions/confirm?kind=approve-change&number=7&head={H1}").text
    assert "Approve and apply #7?" in t and "as you" in t
    form = {k: v.replace("&#34;", '"').replace("&quot;", '"')
            for k, v in re.findall(r'<input type="hidden" name="([a-z]+)" value="([^"]*)"', t)}
    r = c.post("/actions/go", data=form)
    assert r.status_code == 303 and r.headers["location"].startswith(AUTHORIZE + "?"), "the forge's sign-in comes first"
    q = parse_qs(urlsplit(r.headers["location"]).query)
    assert q["client_id"] == ["tockmox-console"] and q["code_challenge_method"] == ["S256"]
    assert q["redirect_uri"] == ["https://tockmox.int.example.com/actions/forge/callback"]
    assert "client_secret" not in r.headers["location"] and CLIENT_SECRET not in r.text
    fg.person("jeff", "Jeff", "jeff@example.com")
    code = fg.code_for("jeff", q["code_challenge"][0])
    r = c.get(f"/actions/forge/callback?code={code}&state={q['state'][0]}")
    assert r.status_code == 303 and r.headers["location"].startswith(base.ISS + "/authorize"), "then the step-up"
    q2 = parse_qs(urlsplit(r.headers["location"]).query)
    assert q2["max_age"] == ["300"]
    idp.next_claims = {"nonce": q2["nonce"][0], "preferred_username": "jeff"}
    r = c.get(f"/auth/callback?code=c&state={q2['state'][0]}")
    assert r.status_code == 200, r.text
    assert fg.merges and fg.merges[0]["message"].rstrip().endswith("Approved-by: Jeff <jeff@example.com>")
    assert "forge" in sent[0] and "client_secret" not in json.dumps(sent[0])
    assert "Approved and applied #7" in c.get("/platform/activity").text


def test_a_forge_callback_that_was_not_started_here_does_nothing(tmp_path):
    c, csrf, idp, fg, sent = wire(tmp_path)
    r = c.get("/actions/forge/callback?code=x&state=y")
    assert r.status_code == 400 and not sent


def test_the_confirm_panel_refuses_a_head_the_page_no_longer_shows(tmp_path):
    c, csrf, idp, fg, sent = wire(tmp_path)
    r = c.get(f"/actions/confirm?kind=approve-change&number=7&head={H2}")
    assert r.status_code == 409 and "changed since the page was drawn" in r.text


def test_summary_drops_markup_and_trailers():
    assert forge_mod.summary_of("## Title\n\nFirst line\nsecond line.\n\nMore.\n\nTockmox-Origin: console") == \
        "First line second line."
    assert forge_mod.summary_of("Only a paragraph\nTockmox-Origin: console") == "Only a paragraph"

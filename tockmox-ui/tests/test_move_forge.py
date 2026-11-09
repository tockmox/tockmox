# SPDX-License-Identifier: Apache-2.0
"""Move to my own forge from the console: Status > Site repository > Move to my own forge.

  shared     the kind: check, move (after a clean check of the same repository), finish; an https URL with no
             credentials in it; high risk, so a fresh sign-in
  service    the credential is staged under a one-use handle and goes only into the move Job's own Secret, owned by
             that Job; the Job is the template's own, labelled as a move; one run at a time; the run is read back
             from its STEP lines, and its Secret is deleted once it has ended
  console    the drawer entry on Site repository only; the confirm panel asks for the credential; the round trip asks
             the issuer for a fresh sign-in and lands on the run's page; a planted credential appears in no page,
             no cookie, no intent, no Activity row and no audit line
Run from tockmox-ui/: python -m pytest tests
"""
import base64
import json
import re
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from app import actions as act
from app import actions_routes
from tests import test_actions as ta

NEEDLE = "PLANTED-PUSH-CREDENTIAL"            # a credential planted to prove it travels nowhere it should not
READ_NEEDLE = "PLANTED-READ-CREDENTIAL"
TO = "https://git.example.org/acme/site.git"
REQUEST = "tockmox-forge-move-request"          # the one Secret a move run reads its request and credential from
MOVE = {"changes": {"enabled": False}, "moveForge": dict(enabled=True, forgeNamespace="tockmox-forge",
                                                         forgeRelease="tockmox-forge", cronJob="tockmox-forge-move",
                                                         requestSecret=REQUEST)}
ACTIONS = dict(ta.ACTIONS, **MOVE)


class MoveKube(ta.Kube):
    """The forge namespace as a move sees it: the suspended template, Jobs, their pods' logs, and the one Secret."""

    def __init__(self):
        super().__init__()
        self.cronjobs[("tockmox-forge", "tockmox-forge-move")] = {
            "metadata": {"name": "tockmox-forge-move", "uid": "cj-move"},
            "spec": {"jobTemplate": {"metadata": {"labels": {"app.kubernetes.io/name": "tockmox-forge-move"}},
                                     "spec": {"template": {"spec": {"serviceAccountName": "tockmox-forge-move"}}}}}}
        self.made = {}                   # name -> Job as created, plus a status the test sets
        self.logs = {}                   # job -> log text
        self.secret = None
        self.secret_deletes = 0

    def handler(self, req: httpx.Request):
        p, m = req.url.path, req.method
        base = "/apis/batch/v1/namespaces/tockmox-forge/jobs"
        if p == base and m == "POST":
            self.calls.append((m, p))
            j = json.loads(req.content)
            j["metadata"]["uid"] = "uid-" + j["metadata"]["name"]
            self.made[j["metadata"]["name"]] = j
            self.jobs.append(j)
            return httpx.Response(201, json=j)
        mt = re.fullmatch(base + r"/([^/]+)", p)
        if mt and m == "GET":
            self.calls.append((m, p))
            j = self.made.get(mt.group(1))
            return httpx.Response(200, json=j) if j else httpx.Response(404, json={"message": "no"})
        if p == "/api/v1/namespaces/tockmox-forge/pods" and m == "GET":
            job = req.url.params.get("labelSelector", "").split("=", 1)[-1]
            items = [{"metadata": {"name": f"{job}-pod"}}] if job in self.made else []
            return httpx.Response(200, json={"items": items})
        mt = re.fullmatch(r"/api/v1/namespaces/tockmox-forge/pods/(.+)-pod/log", p)
        if mt:
            return httpx.Response(200, text=self.logs.get(mt.group(1), ""))
        sp = "/api/v1/namespaces/tockmox-forge/secrets"
        if p == sp and m == "POST":
            self.calls.append((m, p))
            self.secret = json.loads(req.content)
            return httpx.Response(201, json=self.secret)
        if p == sp + "/tockmox-forge-move-request":
            self.calls.append((m, p))
            if m == "GET":
                return httpx.Response(200, json=self.secret) if self.secret else httpx.Response(404, json={})
            if m == "DELETE":
                self.secret_deletes += 1
                self.secret = None
                return httpx.Response(200, json={})
        return super().handler(req)

    def end(self, job, ok=True, log=""):
        self.made[job]["status"] = {"conditions": [{"type": "Complete" if ok else "Failed", "status": "True"}]}
        self.logs[job] = log


def svc(kube=None):
    kube = kube or MoveKube()
    s, _, _ = ta.service(actions=ACTIONS, kube=kube)
    return s, kube


def run_intent(s, mode, to=TO, after="", handle=None, claims=None):
    t = {"mode": mode, "to": to}
    if after:
        t["after"] = after
    it = act.intent("move-forge", t, {}, "a")
    body = {"intent": it, "id_token": ta.token(act.nonce_for(it), **dict({"preferred_username": "jeff"}, **(claims or {})))}
    if handle is not None:
        body["move"] = {"handle": handle}
    return it, s.handle(body)


def stage(s, push=("ci-bot", NEEDLE), read=None):
    body = {"push": {"user": push[0], "token": push[1]}}
    if read:
        body["read"] = {"user": read[0], "token": read[1]}
    return s.stage_move(body)


CLEAN_CHECK = ("STEP 1 run checking the target\nSTEP 1 ok the target is empty and the credentials can read it\n"
               f"CHECK branches=3 tags=7 main={'4f2a9c1' + '0' * 33} files=11\n")


# ---------------------------------------------------------------- shared

@pytest.mark.parametrize("t,why", [
    ({"mode": "check", "to": "http://git.example.org/acme/site.git"}, "https URL"),
    ({"mode": "check", "to": "https://someone@git.example.org/acme/site.git"}, "https URL"),
    ({"mode": "check", "to": "https://git.example.org/acme/site.git?x=1"}, "https URL"),
    ({"mode": "check", "to": "https://git.example.org/../etc"}, "https URL"),
    ({"mode": "everything", "to": TO}, "check, move or finish"),
    ({"mode": "move", "to": TO}, "clean check"),
    ({"mode": "move", "to": TO, "after": "tockmox-forge-move-move-abc123"}, "clean check"),
    ({"mode": "check", "to": TO, "after": "tockmox-forge-move-check-abc123"}, "follows nothing"),
    ({"mode": "check", "to": TO, "token": NEEDLE}, "check, move or finish"),
])
def test_the_kind_refuses(t, why):
    with pytest.raises(act.Refused, match=why):
        act.check(act.parse(dict(ACTIONS, url="http://a")), act.intent("move-forge", t, {}, "a"))


def test_it_is_high_risk_with_a_fresh_sign_in_and_off_unless_turned_on():
    assert act.KINDS["move-forge"][1:3] == ("high", True) and act.step_up("move-forge")
    assert not act.parse(dict(ta.ACTIONS, url="http://a")).on("move-forge")
    with pytest.raises(ValueError, match="unknown key"):
        act.parse({"moveForge": {"enabled": True, "token": "x"}})


def test_the_drawer_offers_it_on_the_site_repository_only():
    cfg = act.parse(dict(ACTIONS, url="http://a"))
    pv = lambda pid: SimpleNamespace(part=SimpleNamespace(id=pid, namespaces=["tockmox-forge"]), signals=[])  # noqa: E731
    assert [a["label"] for a in actions_routes.part_actions(cfg, pv("site-repository"))] == ["Move to my own forge…"]
    assert "move-forge" not in [a["kind"] for a in actions_routes.part_actions(cfg, pv("layer-ai"))]
    off = act.parse(dict(ta.ACTIONS, url="http://a"))
    assert actions_routes.part_actions(off, pv("site-repository")) == []


# ---------------------------------------------------------------- service

def test_a_check_starts_the_templates_job_and_hands_the_credential_to_its_own_secret_only(capsys):
    s, kube = svc()
    h = stage(s, read=("argocd-read", READ_NEEDLE))
    it, (code, out) = run_intent(s, "check", handle=h)
    assert code == 200, out
    (job,) = kube.jobs
    md = job["metadata"]
    assert re.fullmatch(r"tockmox-forge-move-check-[0-9a-f]{6}", md["name"]) and out["job"] == md["name"]
    assert md["ownerReferences"] == [{"apiVersion": "batch/v1", "kind": "CronJob", "name": "tockmox-forge-move",
                                      "uid": "cj-move", "controller": True}]
    assert md["labels"]["tockmox.com/move-forge"] == "true" and "tockmox.com/run-now" not in md["labels"]
    assert md["annotations"]["tockmox.com/move-to"] == TO and md["annotations"]["tockmox.com/requested-by"] == "jeff"
    assert job["spec"] == {"template": {"spec": {"serviceAccountName": "tockmox-forge-move"}}}   # the template's own
    sec = kube.secret
    assert sec["metadata"]["name"] == "tockmox-forge-move-request"
    assert sec["metadata"]["ownerReferences"] == [{"apiVersion": "batch/v1", "kind": "Job", "name": md["name"],
                                                   "uid": "uid-" + md["name"]}]
    data = {k: base64.b64decode(v).decode() for k, v in sec["data"].items()}
    assert data == {"request": f"to={TO}\nmode=check\nrequested-by=jeff\n", "push": f"ci-bot\n{NEEDLE}\n",
                    "read": f"argocd-read\n{READ_NEEDLE}\n"}
    # the credential is in the Secret and nowhere else this service writes or says
    rows, _ = s.activity.read()
    for where in (json.dumps(it), json.dumps(out), json.dumps(rows), json.dumps(job), capsys.readouterr().out):
        assert NEEDLE not in where and READ_NEEDLE not in where


def test_a_handle_is_used_once_and_a_missing_one_starts_nothing():
    s, kube = svc()
    h = stage(s)
    assert run_intent(s, "check", handle=h)[1][0] == 200
    kube.end(kube.jobs[0]["metadata"]["name"], log=CLEAN_CHECK)
    code, out = run_intent(s, "check", handle=h)[1]
    assert code == 403 and "type it again" in out["reason"] and len(kube.jobs) == 1
    code, out = run_intent(s, "check")[1]
    assert code == 403 and "type it again" in out["reason"] and len(kube.jobs) == 1


@pytest.mark.parametrize("push", [("ci bot", "t"), ("ci-bot", 'to"k'), ("ci-bot", "to\\k"), ("ci-bot", "a b"), ("", "t")])
def test_a_credential_that_cannot_be_passed_safely_is_refused(push):
    s, _ = svc()
    with pytest.raises(act.Refused, match="no spaces, quotes or backslashes"):
        stage(s, push=push)


def test_the_move_follows_a_clean_check_of_the_same_repository_still_kept():
    s, kube = svc()
    _, (_, out) = run_intent(s, "check", handle=stage(s))
    chk = out["job"]
    code, out = run_intent(s, "move", after=chk, handle=stage(s))[1]
    assert code == 403 and "did not pass" in out["reason"]                   # still running
    kube.end(chk, log=CLEAN_CHECK)
    code, out = run_intent(s, "move", to="https://git.example.org/acme/other.git", after=chk, handle=stage(s))[1]
    assert code == 403 and "did not pass for this repository" in out["reason"]
    code, out = run_intent(s, "move", after=chk, handle=stage(s))[1]
    assert code == 200, out
    assert base64.b64decode(kube.secret["data"]["request"]).decode() == f"to={TO}\nmode=move\nrequested-by=jeff\n"
    del kube.made[chk]                                                        # kept ten minutes, then gone
    code, out = run_intent(s, "move", after=chk, handle=stage(s))[1]
    assert code == 403 and "check the target again" in out["reason"]


def test_one_run_at_a_time_and_a_finished_runs_secret_goes_before_the_next():
    s, kube = svc()
    first = run_intent(s, "check", handle=stage(s))[1][1]["job"]
    code, out = run_intent(s, "check", handle=stage(s))[1]
    assert code == 403 and "still running" in out["reason"] and len(kube.jobs) == 1
    kube.made[first]["status"] = {"conditions": [{"type": "Failed", "status": "True"}]}   # ended, Secret left over
    code, out = run_intent(s, "check", handle=stage(s))[1]
    assert code == 200 and kube.secret_deletes >= 1 and len(kube.jobs) == 2
    assert kube.secret["metadata"]["ownerReferences"][0]["name"] == out["job"]          # the new run's own


def test_a_run_reads_back_from_its_steps_and_its_secret_goes_when_it_ends():
    s, kube = svc()
    job = run_intent(s, "move", after="tockmox-forge-move-check-000000", handle=stage(s))[1]
    assert job[0] == 403                                                      # no such check
    kube.made["tockmox-forge-move-check-000000"] = {"metadata": {"annotations": {"tockmox.com/move-to": TO}}}
    kube.end("tockmox-forge-move-check-000000", log=CLEAN_CHECK)
    _, (code, out) = run_intent(s, "move", after="tockmox-forge-move-check-000000", handle=stage(s))
    assert code == 200, out
    mv = out["job"]
    r = s.move_run(mv)
    assert r["state"] == "running" and r["mode"] == "move" and r["to"] == TO and kube.secret is not None
    kube.end(mv, log="STEP 1 ok the target is empty\nSTEP 2 ok every branch and tag pushed\n"
                     "STEP 3 ok Argo CD can read the target\nSTEP 4 ok change #42 opened: 11 files name the target\n"
                     "STEP 5 wait change #42 waits for an approver; Finish the move once it is merged\n")
    r = s.move_run(mv)
    assert {k: v["state"] for k, v in r["steps"].items()} == {"1": "ok", "2": "ok", "3": "ok", "4": "ok", "5": "wait"}
    assert r["change"] == 42 and r["state"] == "done" and kube.secret is None
    with pytest.raises(act.Refused, match="not a move run"):
        s.move_run("tockmox-model-watch-run-abc123")


def test_a_refusal_is_shown_in_the_scripts_own_words():
    s, kube = svc()
    job = run_intent(s, "check", handle=stage(s))[1][1]["job"]
    kube.end(job, ok=False, log="STEP 1 run checking the target\nSTEP 1 fail https://x is not empty (3 refs)\n"
                                "  ✗ https://x is not empty (3 refs). Moving pushes the whole history into an EMPTY repository;\n")
    r = s.move_run(job)
    assert r["state"] == "failed" and r["steps"]["1"]["state"] == "fail" and "is not empty" in r["refusal"]


def test_a_username_that_cannot_go_on_the_change_starts_nothing():
    s, kube = svc()
    code, out = run_intent(s, "check", handle=stage(s), claims={"preferred_username": "jeff maaks"})[1]
    assert code == 403 and "username" in out["reason"] and kube.jobs == []


# ---------------------------------------------------------------- console

@pytest.fixture
def move_console(tmp_path, monkeypatch):
    monkeypatch.setattr(ta, "Kube", MoveKube)
    return ta.console(tmp_path, actions=ACTIONS)


def _hidden(t):
    f = {k: v for k, v in re.findall(r'<input type="hidden" name="([a-z]+)" value="([^"]*)"', t)}
    return {k: v.replace("&#34;", '"').replace("&quot;", '"') for k, v in f.items()}


def test_check_then_move_end_to_end_and_the_credential_is_on_no_page(move_console):
    c, csrf, idp, _, kube, sent = move_console
    pages = []
    t = c.get("/actions/move-forge").text
    pages.append(t)
    assert "Check the target" in t and 'name="to"' in t
    t = c.get("/actions/confirm", params={"kind": "move-forge", "mode": "check", "to": TO}).text
    pages.append(t)
    assert "Check the target repository?" in t and 'name="push_token"' in t and 'name="read_token"' not in t
    assert "sign in again" in t
    r = c.post("/actions/go", data=dict(_hidden(t), push_user="ci-bot", push_token=NEEDLE))
    assert r.status_code == 303
    q = parse_qs(urlsplit(r.headers["location"]).query)
    assert q["max_age"] == ["300"]                                           # high risk: a fresh sign-in
    cookies = "".join(f"{k}={v}" for k, v in c.cookies.items())
    assert NEEDLE not in cookies and NEEDLE not in r.headers["location"]
    idp.next_claims = {"nonce": q["nonce"][0], "preferred_username": "jeff"}
    r = c.get(f"/auth/callback?code=c&state={q['state'][0]}")
    assert r.status_code == 303 and r.headers["location"].startswith("/platform/move-forge/tockmox-forge-move-check-")
    job = r.headers["location"].rsplit("/", 1)[1]
    t = c.get(r.headers["location"]).text
    pages.append(t)
    assert 'http-equiv="refresh"' in t and "Checking" in t
    kube.end(job, log=CLEAN_CHECK)
    t = c.get(f"/platform/move-forge/{job}").text
    pages.append(t)
    assert "It will receive 3 branches and 7 tags" in t and "11 files" in t and "Start the move" in t
    assert 'http-equiv="refresh"' not in t
    start = re.search(r'href="(/actions/confirm\?kind=move-forge&amp;mode=move[^"]+)"', t).group(1).replace("&amp;", "&")
    t = c.get(start).text
    pages.append(t)
    assert "Move the site to" in t and 'name="read_token"' in t
    r = c.post("/actions/go", data=dict(_hidden(t), push_user="ci-bot", push_token=NEEDLE,
                                        read_user="argocd-read", read_token=READ_NEEDLE))
    q = parse_qs(urlsplit(r.headers["location"]).query)
    idp.next_claims = {"nonce": q["nonce"][0], "preferred_username": "jeff"}
    r = c.get(f"/auth/callback?code=c&state={q['state'][0]}")
    assert r.headers["location"].startswith("/platform/move-forge/tockmox-forge-move-move-")
    pages.append(c.get(r.headers["location"]).text)
    pages.append(c.get("/platform/activity").text)
    pages.append(c.get("/actions/move-forge").text)
    assert "Finish the move" in pages[-1]
    # the planted credentials: in the Job's Secret, and in no page, intent, cookie or Activity row
    assert base64.b64decode(kube.secret["data"]["read"]).decode() == f"argocd-read\n{READ_NEEDLE}\n"
    for where in pages + [json.dumps(sent), "".join(c.cookies.values())]:
        assert NEEDLE not in where and READ_NEEDLE not in where
    assert all(set(b) <= {"intent", "id_token", "move"} and set(b.get("move") or {}) <= {"handle"} for b in sent)


def test_off_means_absent(tmp_path, monkeypatch):
    monkeypatch.setattr(ta, "Kube", MoveKube)
    c, *_ = ta.console(tmp_path)
    assert c.get("/actions/move-forge").status_code == 404
    assert c.get("/actions/confirm", params={"kind": "move-forge", "mode": "check", "to": TO}).status_code == 404
    assert c.get("/platform/move-forge/tockmox-forge-move-check-abc123").status_code == 404

# SPDX-License-Identifier: Apache-2.0
"""Platform > Site history: where the site's history lives, the off-site copy's state, the last rebuild drill, recent
changes with Revert, and Copy now.

  view       every state the page can be in, from fixtures: matches, pending, behind 20 minutes, no copy, drill
             failed, drill overdue, and the sources not answering (which is never good news); every badge has a word
  service    /v1/forge/state: main from the forge, the two CronJobs read by name, a git remote's credential never shown
  console    the page draws the three panels and the applied changes; Copy now is a run-now of the copy job through
             the usual confirm and sign-in; off means no page and no rail item

Run from tockmox-ui/: python -m pytest tests
"""
import copy
import json
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import site_history as sh  # noqa: E402
from tests import test_actions as base  # noqa: E402
from tests import test_changes as tc  # noqa: E402

NOW = 1_800_000_000.0
NS = "tockmox-forge"


def iso(t):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def state(main_ago=3600, copy=True, drill=True, paused=False, mode="bucket"):
    return {"jobs_namespace": NS, "repo": "tockmox/site", "paused": paused,
            "main": None if paused else {"sha": "a" * 40, "time": iso(NOW - main_ago), "message": "Admit qwen"},
            "copy": {"name": "tockmox-forge-offsite", "mode": mode, "destination": "https://s3.example.com/bkt/site",
                     "suspended": False} if copy else None,
            "drill": {"name": "tockmox-forge-drill-check", "max_days": "92", "since": ""} if drill else None,
            "unreadable": []}


def jobs(copy_ok_ago=None, drill_ok_ago=600, drill_failed=False, copy_failed=False):
    return [{"namespace": NS, "name": "tockmox-forge-offsite", "last_success": None if copy_ok_ago is None else NOW - copy_ok_ago,
             "last_failed": copy_failed},
            {"namespace": NS, "name": "tockmox-forge-drill-check",
             "last_success": None if drill_ok_ago is None else NOW - drill_ok_ago, "last_failed": drill_failed}]


def alert(name, summary="s"):
    return {"name": name, "summary": summary, "silenced": None}


@pytest.mark.parametrize("st,jb,al,part,want_state,want_word", [
    (state(main_ago=3600), jobs(copy_ok_ago=30), [], "offsite", "ok", "Matches"),
    (state(main_ago=120), jobs(copy_ok_ago=600), [], "offsite", "unknown", "Copy pending"),
    (state(main_ago=20 * 60), jobs(copy_ok_ago=40 * 60), [], "offsite", "critical", "Behind"),
    (state(main_ago=20 * 60), jobs(copy_ok_ago=40 * 60), [alert(sh.COPY_BEHIND, "behind 20m")], "offsite", "critical", "Behind"),
    (state(copy=False), jobs(), [], "offsite", "warning", "No off-site copy"),
    (state(), jobs(copy_ok_ago=30), [alert(sh.NO_COPY, "No off-site copy of the site")], "offsite", "warning", "No off-site copy"),
    (state(), jobs(copy_ok_ago=None), [], "offsite", "warning", "Not copied yet"),
    (state(), jobs(drill_ok_ago=600), [], "drill", "ok", "Passed"),
    (state(), jobs(drill_failed=True, drill_ok_ago=40 * 3600), [], "drill", "critical", "Failed or overdue"),
    (state(), jobs(drill_ok_ago=40 * 3600), [alert(sh.DRILL_OVERDUE, "drill overdue")], "drill", "critical", "Failed or overdue"),
    (state(drill=False), jobs(), [], "drill", "unknown", "Not set up"),
    (state(paused=True), jobs(copy_ok_ago=30), [], "repo", "warning", "Not answering"),
])
def test_every_state_from_a_fixture_with_a_word_for_its_badge(st, jb, al, part, want_state, want_word):
    v = sh.view(st, jb, al, NOW)
    assert (v[part]["state"], v[part]["word"]) == (want_state, want_word), v[part]
    assert v[part]["text"], "every badge has a sentence beside it"


def test_behind_twenty_minutes_says_so():
    v = sh.view(state(main_ago=20 * 60), jobs(copy_ok_ago=40 * 60), [], NOW)
    assert "main changed 20 minutes ago" in v["offsite"]["text"] and "40 minutes ago" in v["offsite"]["text"]


def test_the_alerts_own_words_are_the_pages():
    v = sh.view(state(), jobs(copy_ok_ago=30), [alert(sh.NO_COPY, "The site repository has no off-site copy")], NOW)
    assert v["offsite"]["text"] == "The site repository has no off-site copy" and v["offsite"]["none"]


def test_a_source_that_did_not_answer_is_unknown_not_good_news():
    v = sh.view(state(), [], [], NOW, jobs_known=False)
    assert v["offsite"]["state"] == "unknown" and v["drill"]["state"] == "unknown"
    assert "not the same as it being behind" in v["offsite"]["text"]
    v = sh.view(None, [], [], NOW)                                     # the actions service did not answer
    assert v["repo"]["state"] == "unknown" and v["offsite"]["state"] == "unknown"


def test_a_cronjob_the_service_could_not_read_is_unknown_not_missing():
    st = state(copy=False, drill=False)
    st["unreadable"] = ["tockmox-forge-offsite", "tockmox-forge-drill-check"]
    v = sh.view(st, jobs(), [], NOW)
    assert v["offsite"]["word"] == "Unknown" and v["drill"]["word"] == "Unknown"


# ---------------------------------------------------------------- the service

def kube_with_forge_jobs(kube, git_url=None):
    env = ([{"name": "MODE", "value": "git"}, {"name": "GIT_REMOTE_URL", "value": git_url}] if git_url else
           [{"name": "MODE", "value": "bucket"}, {"name": "S3_ENDPOINT", "value": "https://s3.example.com"},
            {"name": "S3_BUCKET", "value": "bkt"}, {"name": "S3_PREFIX", "value": "site"}])
    tpl = lambda e: {"metadata": {"uid": "u"}, "spec": {"schedule": "* * * * *", "jobTemplate": {"spec": {"template": {
        "spec": {"containers": [{"name": "copy", "env": e + [{"name": "S3_KEY", "valueFrom": {"secretKeyRef": {"name": "x"}}}]}]}}}}}}
    kube.cronjobs[(NS, "tockmox-forge-offsite")] = dict(tpl(env), metadata={"name": "tockmox-forge-offsite", "uid": "u1"})
    kube.cronjobs[(NS, "tockmox-forge-drill-check")] = dict(tpl([{"name": "DRILL_MAX_DAYS", "value": "92"}]),
                                                             metadata={"name": "tockmox-forge-drill-check", "uid": "u2"})


class ForgeWithBranch(tc.Forge):
    def handler(self, req):
        if req.url.path.endswith("/repos/tockmox/site/branches/main") and not self.down:
            return httpx.Response(200, json={"commit": {"id": "c" * 40, "timestamp": "2026-11-05T15:00:00Z",
                                                        "message": "Admit qwen3-coder (#7)\n\nApproved-by: Jeff"}})
        return super().handler(req)


def test_the_state_reads_main_and_the_two_cronjobs_and_never_a_credential(tmp_path):
    from fastapi.testclient import TestClient
    from app.actions_service import create_service
    s, fg, kube = tc.service(tmp_path, fg=ForgeWithBranch())
    kube_with_forge_jobs(kube, git_url="https://pusher:SECRET-TOKEN@git.example.com/acme/site.git")
    j = TestClient(create_service(service=s)).get("/v1/forge/state").json()
    assert j["main"] == {"sha": "c" * 40, "time": "2026-11-05T15:00:00Z", "message": "Admit qwen3-coder (#7)"}
    assert j["copy"]["mode"] == "git" and j["copy"]["destination"] == "https://git.example.com/acme/site.git"
    assert "SECRET-TOKEN" not in json.dumps(j) and "pusher" not in json.dumps(j)
    assert j["drill"]["max_days"] == "92"
    assert ("GET", f"/apis/batch/v1/namespaces/{NS}/cronjobs/tockmox-forge-offsite") in kube.calls
    kube_with_forge_jobs(kube)
    j = TestClient(create_service(service=s)).get("/v1/forge/state").json()
    assert j["copy"]["destination"] == "https://s3.example.com/bkt/site"
    fg.down = True
    j = TestClient(create_service(service=s)).get("/v1/forge/state").json()
    assert j["paused"] is True and j["copy"]["name"] == "tockmox-forge-offsite"


# ---------------------------------------------------------------- the console

def wire(tmp_path, on=True):
    fg = ForgeWithBranch()
    a = tc.actions_on(tmp_path) if on else copy.deepcopy(base.ACTIONS)
    if on:                                      # what the chart adds with the change kinds on
        a["runJob"]["allow"] = a["runJob"]["allow"] + [
            {"namespace": NS, "name": "tockmox-forge-offsite", "part": "site-repository"},
            {"namespace": NS, "name": "tockmox-forge-drill-check", "part": "site-repository"}]
    c, csrf, idp, am, kube, sent = base.console(tmp_path, actions=a, forge=fg.handler)
    kube_with_forge_jobs(kube)
    return c, idp, fg, kube, sent


def test_the_page_draws_the_three_panels_and_the_applied_changes(tmp_path):
    c, idp, fg, kube, sent = wire(tmp_path)
    t = c.get("/platform/history").text
    assert "Where it lives" in t and "Off-site copy" in t and "Last rebuild drill" in t
    assert "https://s3.example.com/bkt/site" in t and "main is at ccccccc" in t
    assert "#5 Add model a" in t and "kind=revert-change&amp;number=5" in t
    assert f"kind=run-job&amp;ns={NS}&amp;name=tockmox-forge-offsite" in t, "Copy now"
    assert f"name=tockmox-forge-drill-check" in t, "Check the drill now"
    assert 'href="/platform/history"' in t


def test_copy_now_is_a_run_now_of_the_copy_job(tmp_path):
    import re
    from urllib.parse import parse_qs, urlsplit
    c, idp, fg, kube, sent = wire(tmp_path)
    t = c.get(f"/actions/confirm?kind=run-job&ns={NS}&name=tockmox-forge-offsite&back=/platform/history").text
    assert "Run tockmox-forge-offsite now?" in t
    form = {k: v.replace("&#34;", '"').replace("&quot;", '"')
            for k, v in re.findall(r'<input type="hidden" name="([a-z]+)" value="([^"]*)"', t)}
    r = c.post("/actions/go", data=form)
    q = parse_qs(urlsplit(r.headers["location"]).query)
    idp.next_claims = {"nonce": q["nonce"][0]}
    r = c.get(f"/auth/callback?code=c&state={q['state'][0]}")
    assert r.status_code == 200, r.text
    assert kube.jobs and kube.jobs[0]["metadata"]["namespace"] == NS
    assert kube.jobs[0]["metadata"]["ownerReferences"][0]["name"] == "tockmox-forge-offsite"


def test_off_means_no_page_and_no_rail_item(tmp_path):
    c, *_ = wire(tmp_path, on=False)
    assert c.get("/platform/history").status_code == 404
    assert 'href="/platform/history"' not in c.get("/platform/activity").text


def test_a_member_who_is_not_an_administrator_gets_no_page(tmp_path):
    fg = ForgeWithBranch()
    c, *_ = base.console(tmp_path, actions=tc.actions_on(tmp_path), groups=("tockmox-users",), forge=fg.handler)
    assert c.get("/platform/history").status_code == 403


# ---------------------------------------------------------------- Download a copy

def bare_repo(tmp_path):
    import subprocess
    w, bare = tmp_path / "w", tmp_path / "site.git"
    run = lambda *a, cwd=None: subprocess.run(a, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()
    run("git", "init", "-q", "-b", "main", str(w))
    (w / "values.yaml").write_text("models: [a]\n")
    run("git", "-C", str(w), "add", "-A")
    run("git", "-C", str(w), "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "site")
    run("git", "clone", "-q", "--bare", str(w), str(bare))
    return str(bare), run("git", "-C", str(bare), "rev-parse", "refs/heads/main")


def test_a_copy_is_mains_bundle_with_the_sum_the_restore_checks(tmp_path, monkeypatch):
    import hashlib
    import subprocess
    from fastapi.testclient import TestClient
    from app.actions_service import create_service
    monkeypatch.setenv("TOCKMOX_ACTIONS_BUNDLES", str(tmp_path / "bundles"))
    s, fg, kube = tc.service(tmp_path, fg=ForgeWithBranch())
    bare, sha = bare_repo(tmp_path)
    s.forge._clone_url = lambda: bare
    c = TestClient(create_service(service=s))
    j = c.post("/v1/forge/bundle").json()
    assert j["commit"] == sha
    body = c.get(f"/v1/forge/bundle/{j['sha256']}").content
    assert hashlib.sha256(body).hexdigest() == j["sha256"] and len(body) == j["bytes"]
    f = tmp_path / "got.bundle"
    f.write_bytes(body)
    heads = subprocess.run(["git", "bundle", "list-heads", str(f)], capture_output=True, text=True).stdout
    assert f"{sha} refs/heads/main" in heads and "HEAD" in heads, "a plain git clone of it checks out main"
    chk = tmp_path / "check.git"                       # forge-restore.sh's own check: verify, then fetch every object
    subprocess.run(["git", "init", "-q", "--bare", str(chk)], check=True)
    assert subprocess.run(["git", "-C", str(chk), "bundle", "verify", str(f)], capture_output=True).returncode == 0
    assert subprocess.run(["git", "-C", str(chk), "fetch", "-q", str(f), "+refs/heads/*:refs/heads/*"],
                          capture_output=True).returncode == 0
    w = tmp_path / "w"                                  # main moves: the next copy is another file
    (w / "values.yaml").write_text("models: [a, b]\n")
    subprocess.run(["git", "-C", str(w), "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qam", "b"], check=True)
    subprocess.run(["git", "-C", str(w), "push", "-q", bare, "main"], check=True)
    j2 = c.post("/v1/forge/bundle").json()
    assert j2["sha256"] != j["sha256"]
    assert sorted(p.name for p in (tmp_path / "bundles").iterdir()) == [j2["sha256"] + ".bundle"], "only the newest"
    assert c.get("/v1/forge/bundle/" + "0" * 64).status_code == 404
    assert c.get("/v1/forge/bundle/..%2f..%2fetc").status_code == 404


def test_a_failed_clone_keeps_the_token_out_of_the_log_and_the_answer(tmp_path, monkeypatch, caplog):
    from fastapi.testclient import TestClient
    from app.actions_service import create_service
    monkeypatch.setenv("TOCKMOX_ACTIONS_BUNDLES", str(tmp_path / "bundles"))
    s, fg, kube = tc.service(tmp_path, fg=ForgeWithBranch())
    s.forge._clone_url = lambda: f"http://{tc.BOT_TOKEN}@127.0.0.1:9/none.git"
    r = TestClient(create_service(service=s)).post("/v1/forge/bundle")
    assert r.status_code == 502 and tc.BOT_TOKEN not in r.text
    assert tc.BOT_TOKEN not in caplog.text


def test_download_a_copy_end_to_end_in_the_console(tmp_path, monkeypatch):
    import hashlib
    import re
    monkeypatch.setenv("TOCKMOX_ACTIONS_BUNDLES", str(tmp_path / "bundles"))
    c, idp, fg, kube, sent = wire(tmp_path)
    from app.actions_service import Forge  # noqa: F401  (the service the bridge serves is the one wire() built)
    bare, sha = bare_repo(tmp_path)
    import app.forge as fm
    monkeypatch.setattr(fm.Forge, "_clone_url", lambda self: bare)
    t = c.get("/platform/history").text
    csrf = re.search(r'name="csrf" value="([^"]+)"', t).group(1)
    r = c.post("/actions/site-copy", data={"csrf": csrf})
    assert r.status_code == 200, r.text
    digest = re.search(r"<code>([0-9a-f]{64})</code>", r.text).group(1)
    assert sha in r.text and "--restore-from file:site.bundle" in r.text
    b = c.get(f"/platform/history/copy/{digest}/site.bundle")
    assert b.status_code == 200 and hashlib.sha256(b.content).hexdigest() == digest
    assert 'filename="site.bundle"' in b.headers["content-disposition"]
    s = c.get(f"/platform/history/copy/{digest}/site.bundle.sha256").text
    assert s == f"{digest}  site.bundle\n", "the line forge-restore.sh checks"
    assert c.post("/actions/site-copy", data={"csrf": "wrong"}).status_code == 400

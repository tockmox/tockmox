# SPDX-License-Identifier: Apache-2.0
"""The evidence PR (design 3.1 stage 7, AC-45.9): the eval runner's result twins and verdict records go to the site repo as a
PR that ADDS files under evals/. It never edits an existing file, never leaves evals/, never carries a file over 1 MiB, and
never touches the values file. Fake-forge pattern, as in test_pr_opener."""
import json

import httpx
import pytest

from tests.models_support import SHA_A, result_text, sha, verdict_record
from tests.proto_support import _secret  # noqa: F401  (autouse fixture)
from tests.test_pr_opener import FakeForge, PATH, cfg, forge_for, report, values
from app import models as ml
from app import pr_opener as po
from app import results as rs

MODEL = "example-org/Example-27B-4bit"
TWIN_TEXT = result_text()
TWIN_PATH = rs.repo_path(rs.parse(TWIN_TEXT))


def verdict_text(run="r1", results=None, **kw):
    refs = [{"path": TWIN_PATH, "sha256": sha(TWIN_TEXT)}] if results is None else results
    return verdict_record(MODEL, "local-medium", run=run, results=refs, incumbent="example-org/Other-27B-4bit", **kw)


def files(**extra):
    d = {TWIN_PATH: TWIN_TEXT.encode(), "evals/verdicts/r1.json": verdict_text().encode()}
    d.update({k: (v.encode() if isinstance(v, str) else v) for k, v in extra.items()})
    return d


def repo_files():
    return {"README.md": "x", PATH: "modelLifecycle: {}\n", "evals/results/beta/method.md": "how"}


def none(_p):
    return None


# ------------------------------------------------------------ the plan

def test_a_twin_and_the_verdict_that_cites_it_become_one_additive_pr():
    spec = po.plan_evidence(files(), none, PATH)
    assert spec.kind == "evidence" and spec.branch.startswith("tockmox/evidence/") and spec.text == ""
    assert sorted(spec.files) == sorted([TWIN_PATH, "evals/verdicts/r1.json"])
    assert all(p.startswith("evals/") for p in spec.files)
    assert "1 result twin(s), 1 verdict record(s)" in spec.body and "Nothing here changes a model, a route or the values file" in spec.body
    assert sha(TWIN_TEXT)[:16] in spec.body


def test_the_verdict_may_cite_a_twin_that_is_already_in_the_repo():
    existing = lambda p: TWIN_TEXT.encode() if p == TWIN_PATH else None  # noqa: E731
    spec = po.plan_evidence({"evals/verdicts/r1.json": verdict_text().encode()}, existing, PATH)
    assert list(spec.files) == ["evals/verdicts/r1.json"]


@pytest.mark.parametrize("path", [
    PATH, "site/values/other.yaml", "docs/administration/model-lifecycle.md", ".github/workflows/ci.yml", "evals.json", "/evals/x.json",
    "evals/../site/values/models.yaml", "evals/../../etc/passwd.json", "../evals/x.json", "evals//x.json", "evals/./x.json", "evals/",
    "evals/x y.json", "evals/x.sh", "evals/x.yaml", "evals/x.json\n.sh", "EVALS/x.json", "evals/" + "a" * 200 + ".json",
])
def test_a_path_outside_evals_or_of_the_wrong_kind_is_refused(path):
    with pytest.raises(po.Refused):
        po.plan_evidence({path: b"{}"}, none, PATH)


def test_the_values_file_is_refused_even_when_it_is_named_under_evals():
    with pytest.raises(po.Refused, match="never touches it"):
        po.plan_evidence({"evals/models.yaml.json": b"{}"}, none, "evals/models.yaml.json")


def test_a_file_over_one_mebibyte_is_refused_and_one_at_the_limit_is_not():
    big = ("x" * ((1 << 20) + 1)).encode()
    with pytest.raises(po.Refused, match="over 1 MiB"):
        po.plan_evidence({"evals/results/beta/notes.md": big}, none, PATH)
    ok = po.plan_evidence({"evals/results/beta/notes.md": b"x" * (1 << 20)}, none, PATH)
    assert len(ok.files) == 1


def test_too_many_files_or_too_many_bytes_is_refused():
    many = {f"evals/results/beta/n{i}.md": b"x" for i in range(po.EVIDENCE_MAX_FILES + 1)}
    with pytest.raises(po.Refused, match="at most"):
        po.plan_evidence(many, none, PATH)
    total = {f"evals/results/beta/n{i}.md": b"x" * (1 << 20) for i in range(9)}
    with pytest.raises(po.Refused, match="in total"):
        po.plan_evidence(total, none, PATH)
    with pytest.raises(po.Refused, match="no files"):
        po.plan_evidence({}, none, PATH)


def test_an_existing_file_is_never_edited_and_identical_content_is_skipped():
    existing = lambda p: b"something else" if p == "evals/results/beta/method.md" else None  # noqa: E731
    with pytest.raises(po.Refused, match="already exists with other contents"):
        po.plan_evidence({"evals/results/beta/method.md": b"how"}, existing, PATH)
    same = lambda p: b"how" if p == "evals/results/beta/method.md" else None  # noqa: E731
    spec = po.plan_evidence({"evals/results/beta/method.md": b"how", "evals/results/beta/other.md": b"y"}, same, PATH)
    assert list(spec.files) == ["evals/results/beta/other.md"] and "skipped" in spec.body
    with pytest.raises(po.Refused, match="already in the repo"):
        po.plan_evidence({"evals/results/beta/method.md": b"how"}, same, PATH)


def test_a_verdict_must_cite_files_that_exist_and_hash_right():
    with pytest.raises(po.Refused, match="neither in this PR nor in the repo"):
        po.plan_evidence({"evals/verdicts/r1.json": verdict_text().encode()}, none, PATH)
    bad = verdict_text(results=[{"path": TWIN_PATH, "sha256": "0" * 64}]).encode()
    with pytest.raises(po.Refused, match="sha256 that does not match"):
        po.plan_evidence({TWIN_PATH: TWIN_TEXT.encode(), "evals/verdicts/r1.json": bad}, none, PATH)


def test_new_evidence_must_be_hashed_so_a_bare_path_verdict_is_refused():
    bare = verdict_text(results=[TWIN_PATH]).encode()
    with pytest.raises(po.Refused, match="must be hashed"):
        po.plan_evidence({TWIN_PATH: TWIN_TEXT.encode(), "evals/verdicts/r1.json": bare}, none, PATH)


def test_a_twin_or_verdict_that_does_not_parse_or_sits_in_the_wrong_place_is_refused():
    with pytest.raises(po.Refused, match="not a valid capability-result/1"):
        po.plan_evidence({"evals/results/beta/x.json": b'{"schema": "capability-result/1"}'}, none, PATH)
    with pytest.raises(po.Refused, match="belongs at"):
        po.plan_evidence({"evals/results/beta/renamed.json": TWIN_TEXT.encode()}, none, PATH)
    with pytest.raises(po.Refused, match="not a verdict record"):
        po.plan_evidence({"evals/verdicts/r1.json": b"{}"}, none, PATH)
    with pytest.raises(po.Refused, match="named <run_id>.json"):
        po.plan_evidence({TWIN_PATH: TWIN_TEXT.encode(), "evals/verdicts/other.json": verdict_text().encode()}, none, PATH)
    with pytest.raises(po.Refused, match="not UTF-8"):
        po.plan_evidence({"evals/results/beta/x.md": b"\xff\xfe"}, none, PATH)


# ------------------------------------------------------------ against a forge

@pytest.mark.parametrize("kind", ["github", "forgejo"])
def test_applying_opens_one_branch_adds_files_with_puts_and_touches_nothing_else(kind):
    f, forge = forge_for(kind, repo_files())
    spec, url = po.run_evidence(cfg(kind), files(), forge, apply=True, log=lambda *_: None)
    assert url.startswith("https://forge.example/o/r/pull/") and spec.branch in f.prs
    puts = [r for r in f.requests if r.method == "PUT"]
    assert sorted(r.url.path.split("/contents/")[1] for r in puts) == sorted(files())
    for r in puts:
        body = json.loads(r.content)
        assert "sha" not in body                                     # a PUT without a sha cannot overwrite an existing path
        assert body["branch"] == spec.branch and "Evidence" in body["message"] and "Tockmox-Origin: model-watcher" in body["message"]
    assert not [r for r in f.requests if PATH in r.url.path and r.method != "GET"]
    assert f.files["main"] == repo_files()                           # main is untouched
    assert set(f.files[spec.branch]) - set(repo_files()) == set(files())
    assert all(f.files[spec.branch][k] == repo_files()[k] for k in repo_files())      # nothing existing changed on the branch either
    assert f.last_pr["base"] == "main" and f.last_pr["head"] == spec.branch


def test_a_dry_run_reads_but_writes_nothing():
    f, forge = forge_for("github", repo_files())
    logs = []
    spec, url = po.run_evidence(cfg(), files(), forge, apply=False, log=logs.append)
    assert url == "" and any("would open" in x for x in logs)
    assert [r.method for r in f.requests if r.method not in ("GET",)] == []


def test_an_open_evidence_pr_for_the_same_files_is_not_opened_twice():
    spec = po.plan_evidence(files(), none, PATH)
    f, forge = forge_for("github", repo_files(), prs=[spec.branch])
    logs = []
    _, url = po.run_evidence(cfg(), files(), forge, apply=True, log=logs.append)
    assert url == "" and any("already open" in x for x in logs)
    assert not [r for r in f.requests if r.method in ("POST", "PUT")]


def test_the_one_pr_at_a_time_lane_is_not_held_by_an_evidence_pr_and_does_not_hold_it():
    """An evidence PR adds files under evals/ and an admit or promote PR edits the values file: different files, so neither
    waits for the other (design 3.1)."""
    assert len(po.plan(values(), report(), [], open_branches=["tockmox/evidence/abc"]).prs) == 1       # an evidence PR is open: admit still goes
    assert po.plan(values(), report(), [], open_branches=["tockmox/admit/x"]).prs == []                 # an admit PR is open: the lane is held
    spec = po.plan_evidence(files(), none, PATH)
    f, forge = forge_for("github", repo_files(), prs=["tockmox/admit/some-model"])
    _, url = po.run_evidence(cfg(), files(), forge, apply=True, log=lambda *_: None)
    assert url and spec.branch in f.prs


def test_a_failure_part_way_removes_the_branch_and_reraises():
    class Flaky(FakeForge):
        def handler(self, req):
            if req.method == "PUT" and "r1.json" in req.url.path:
                return httpx.Response(500, json={})
            if req.method == "DELETE":
                self.requests.append(req)
                self.deleted = req.url.path
                return httpx.Response(204)
            return super().handler(req)
    f = Flaky("github", repo_files())
    forge = po.Forge("github", "https://api.github.com", "o/r", "tok", transport=httpx.MockTransport(f.handler))
    with pytest.raises(httpx.HTTPStatusError):
        po.run_evidence(cfg(), files(), forge, apply=True, log=lambda *_: None)
    assert f.deleted.startswith("/repos/o/r/git/refs/heads/tockmox/evidence/")


def test_the_forge_is_asked_about_the_base_branch_not_a_guess():
    f, forge = forge_for("github", repo_files())
    po.run_evidence(cfg(baseBranch="main"), files(), forge, apply=False, log=lambda *_: None)
    reads = [r.url.params.get("ref") for r in f.requests if "/contents/" in r.url.path]
    assert reads and set(reads) == {"main"}


# ------------------------------------------------------------ the command line

def test_read_tree_refuses_symlinks_and_oversize_files(tmp_path):
    (tmp_path / "evals").mkdir()
    (tmp_path / "evals" / "a.md").write_text("a")
    assert po.read_tree(str(tmp_path)) == {"evals/a.md": b"a"}
    (tmp_path / "evals" / "link.md").symlink_to(tmp_path / "evals" / "a.md")
    with pytest.raises(po.Refused, match="symlink"):
        po.read_tree(str(tmp_path))
    (tmp_path / "evals" / "link.md").unlink()
    (tmp_path / "evals" / "big.md").write_bytes(b"x" * ((1 << 20) + 1))
    with pytest.raises(po.Refused, match="over 1 MiB"):
        po.read_tree(str(tmp_path))


def test_a_directory_with_a_file_outside_evals_is_refused_whole(tmp_path):
    (tmp_path / "evals" / "results" / "beta").mkdir(parents=True)
    (tmp_path / TWIN_PATH).write_text(TWIN_TEXT)
    (tmp_path / "site" / "values").mkdir(parents=True)
    (tmp_path / PATH).write_text("modelLifecycle: {}\n")
    with pytest.raises(po.Refused, match="not a plain relative path under evals/|never touches"):
        po.plan_evidence(po.read_tree(str(tmp_path)), none, PATH)

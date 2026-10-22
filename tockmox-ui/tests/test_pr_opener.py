# SPDX-License-Identifier: Apache-2.0
"""TM-0930: the watcher's PR opener. The two approvals become PRs, one at a time, built by the UI's own functions."""
import base64
import json
import re

import httpx
import pytest
import yaml

from tests.proto_support import _secret  # noqa: F401  (autouse fixture: the session secret the config needs)
from tests.proto_support import lifecycle_full_doc, verdict_record
from app import config as cfgmod
from app import models as ml
from app import nodes as nm
from app import pr_opener as po
from tests.test_models_ui import CANDS

NEW = "mlx-community/Qwen3.9-27B-4bit"
PATH = "site/values/models.yaml"


def values(with_next=False):
    d = lifecycle_full_doc()
    v = {"modelLifecycle": d["modelLifecycle"], "inferenceNodes": d["inferenceNodes"]}
    if with_next:
        v["modelLifecycle"]["catalog"].append({"id": "q39", "model": NEW, "stage": "candidate", "source": {"kind": "huggingface", "ref": NEW}})
        v["inferenceNodes"]["routes"].append({"alias": "local-agent-next", "node": "mac-studio-m4-max", "endpoint": "http-8082",
                                              "model": NEW, "kind": "chat"})
    return v


def passes(v, n=3):
    old = next(r for r in v["inferenceNodes"]["routes"] if r["alias"] == "local-agent")["model"]
    return [verdict_record(NEW, "local-agent", run=f"r{i}", date=f"2026-10-0{i + 1}", incumbent=old) for i in range(n)]


class FakeForge:
    """Enough of GitHub REST and Forgejo API v1 to open a PR, with state."""

    def __init__(self, kind, files, prs=()):
        self.kind, self.files, self.branches, self.prs = kind, {"main": dict(files)}, {"main": "sha-main"}, list(prs)
        self.requests = []

    def handler(self, req: httpx.Request):
        self.requests.append(req)
        p = req.url.path
        p = p[len("/api/v1"):] if p.startswith("/api/v1") else p
        m = re.match(r"^/repos/o/r(/.*)$", p)
        if not m:
            return httpx.Response(404)
        p, q = m.group(1), dict(req.url.params)
        if req.method == "GET" and p.startswith("/contents/"):
            path, ref = p[len("/contents/"):], q.get("ref", "main")
            tree = self.files[ref]
            if path in tree:
                return httpx.Response(200, json={"content": base64.b64encode(tree[path].encode()).decode(), "sha": f"blob-{len(tree[path])}"})
            kids = [{"type": "file", "path": k} for k in tree if k.startswith(path.rstrip("/") + "/")]
            return httpx.Response(200, json=kids) if kids else httpx.Response(404, json={})
        if req.method == "GET" and p.startswith("/pulls"):
            return httpx.Response(200, json=[{"head": {"ref": b}} for b in self.prs])
        if req.method == "GET" and p.startswith("/git/ref/heads/"):
            return httpx.Response(200, json={"object": {"sha": self.branches[p.rsplit("/", 1)[1]]}})
        if req.method == "GET" and p.startswith("/branches/"):
            return httpx.Response(200, json={"commit": {"id": self.branches[p.rsplit("/", 1)[1]]}})
        body = json.loads(req.content or b"{}")
        if req.method == "POST" and p == "/git/refs":
            name = body["ref"][len("refs/heads/"):]
            self.branches[name], self.files[name] = body["sha"], dict(self.files["main"])
            return httpx.Response(201, json={})
        if req.method == "POST" and p == "/branches":
            self.branches[body["new_branch_name"]] = "x"
            self.files[body["new_branch_name"]] = dict(self.files[body["old_branch_name"]])
            return httpx.Response(201, json={})
        if req.method == "PUT" and p.startswith("/contents/"):
            self.files[body["branch"]][p[len("/contents/"):]] = base64.b64decode(body["content"]).decode()
            self.last_message = body["message"]
            return httpx.Response(200, json={})
        if req.method == "POST" and p == "/pulls":
            self.prs.append(body["head"])
            self.last_pr = body
            return httpx.Response(201, json={"html_url": f"https://forge.example/o/r/pull/{len(self.prs)}"})
        return httpx.Response(405)


def cfg(kind="github", **pr):
    api = "https://api.github.com" if kind == "github" else "https://forge.example/api/v1"
    return {"modelLifecycle": {"watch": {"pullRequests": {"enabled": True, "forge": kind, "apiUrl": api, "repo": "o/r",
                                                          "valuesPath": PATH, "commitTrailers": ["Tockmox-Origin: model-watcher"], **pr}}}}


def forge_for(kind, files, prs=()):
    f = FakeForge(kind, files, prs)
    api = "https://api.github.com" if kind == "github" else "https://forge.example/api/v1"
    return f, po.Forge(kind, api, "o/r", "tok", transport=httpx.MockTransport(f.handler))


def report():
    return {"schema": 1, "candidates": CANDS}


# ------------------------------------------------------------ the plan

def test_plan_admits_one_candidate_and_the_change_passes_the_gate():
    p = po.plan(values(), report(), [])
    assert len(p.prs) == 1 and p.prs[0].kind == "admit"                # one at a time
    doc = yaml.safe_load(p.prs[0].text)
    full = lifecycle_full_doc()
    full["modelLifecycle"], full["inferenceNodes"] = doc["modelLifecycle"], doc["inferenceNodes"]
    cfgmod.parse(full)
    assert "first approval" in p.prs[0].body


def test_promotion_comes_first_when_the_count_is_reached():
    v = values(with_next=True)
    vs = [ml.parse_verdict(t, f"evals/verdicts/{i}.json") for i, t in enumerate(passes(v))]
    p = po.plan(v, report(), vs)
    assert p.prs[0].kind == "promote" and p.prs[0].branch == "tockmox/promote/local-agent"
    routes = {r["alias"]: r["model"] for r in yaml.safe_load(p.prs[0].text)["inferenceNodes"]["routes"]}
    assert routes["local-agent"] == NEW and "local-agent-next" not in routes
    assert "second approval" in p.prs[0].body and "evals/verdicts/0.json" in p.prs[0].body


def test_a_candidate_with_nothing_to_compare_against_is_not_a_pr():
    """Lab finding 2026-10-07: a successor of a model served only by a -next route became a catalog-only PR."""
    c = dict(CANDS[0], subject="qwen3-8-27b-4bit")
    p = po.plan(values(), {"schema": 1, "candidates": [c]}, [])
    assert p.prs == [] and any("admit it from the UI" in why for _, why in p.skipped)


def test_two_passes_are_not_a_promotion():
    v = values(with_next=True)
    vs = [ml.parse_verdict(t, f"evals/verdicts/{i}.json") for i, t in enumerate(passes(v, 2))]
    p = po.plan(v, None, vs)
    assert p.prs == [] and any("2 of 3" in why for _, why in p.skipped)


def test_nothing_new_while_a_lifecycle_pr_is_open():
    p = po.plan(values(), report(), [], open_branches={"tockmox/admit/x"})
    assert p.prs == [] and "one at a time" in p.skipped[0][1]


def test_a_values_file_with_other_content_is_refused():
    v = values()
    v["openWebui"] = {"image": "x"}
    with pytest.raises(po.Refused, match="only modelLifecycle, inferenceNodes and the gateway's rolling annotation"):
        po.plan(v, report(), [])


@pytest.mark.parametrize("lit", [{"image": "x"}, {"podAnnotations": {"other": "y"}},
                                 {"podAnnotations": {nm.ROLL_ANNOTATION: "a", "other": "y"}},
                                 {"podAnnotations": {nm.ROLL_ANNOTATION: "a"}, "image": "x"}, "x"])
def test_a_litellm_block_beyond_the_rolling_annotation_is_refused(lit):
    v = values()
    v["litellm"] = lit
    with pytest.raises(po.Refused, match="litellm block holds more than"):
        po.plan(v, report(), [])


def test_the_rolling_annotation_alone_is_accepted_and_every_pr_rewrites_it():
    v = values()
    v["litellm"] = {"podAnnotations": {nm.ROLL_ANNOTATION: "stale"}}
    p = po.plan(v, report(), [])
    assert p.prs, p.skipped
    for spec in p.prs:
        doc = yaml.safe_load(spec.text)
        po.check_values_file(doc)        # what it writes, it would accept next run
        inv = nm.parse_inventory(doc["inferenceNodes"])
        assert doc["litellm"] == {"podAnnotations": {nm.ROLL_ANNOTATION: nm.routes_hash(inv)}}


# ------------------------------------------------------------ the forge

@pytest.mark.parametrize("kind", ["github", "forgejo"])
def test_apply_opens_one_pr_and_the_next_run_waits(kind):
    files = {PATH: yaml.safe_dump(values())}
    f, forge = forge_for(kind, files)
    p, opened = po.run(cfg(kind), report(), forge, apply=True, log=lambda *_: None)
    assert len(opened) == 1 and len(f.prs) == 1
    branch = f.prs[0]
    assert yaml.safe_load(f.files[branch][PATH]) != values() and f.files["main"][PATH] == files[PATH]   # main untouched
    assert "Tockmox-Origin: model-watcher" in f.last_message
    p2, opened2 = po.run(cfg(kind), report(), forge, apply=True, log=lambda *_: None)
    assert opened2 == [] and "one at a time" in p2.skipped[0][1]
    auth = f.requests[0].headers["authorization"]
    assert auth == ("Bearer tok" if kind == "github" else "token tok")


def test_dry_run_writes_nothing():
    f, forge = forge_for("github", {PATH: yaml.safe_dump(values())})
    po.run(cfg(), report(), forge, apply=False, log=lambda *_: None)
    assert all(r.method == "GET" for r in f.requests)


def test_promotion_reads_verdicts_from_the_repo_and_an_unreadable_one_blocks_it():
    v = values(with_next=True)
    files = {PATH: yaml.safe_dump(v), **{f"evals/verdicts/{i}.json": t for i, t in enumerate(passes(v))}}
    f, forge = forge_for("github", files)
    p, _ = po.run(cfg(), None, forge, apply=False, log=lambda *_: None)
    assert [x.kind for x in p.prs] == ["promote"]
    files["evals/verdicts/9.json"] = "{not json"
    f, forge = forge_for("github", files)
    lines = []
    p, _ = po.run(cfg(), None, forge, apply=False, log=lines.append)
    assert p.prs == [] and any("unreadable" in x for x in lines)


@pytest.mark.parametrize("kind,api,repo,match", [("gitlab", "https://x", "o/r", "github or forgejo"),
                                                 ("github", "http://api.github.com", "o/r", "https"),
                                                 ("github", "https://api.github.com", "o/r/../x", "owner/name")])
def test_forge_config_is_refused(kind, api, repo, match):
    with pytest.raises(po.Refused, match=match):
        po.Forge(kind, api, repo, "t")


def test_a_redirect_is_not_followed():
    def h(req):
        return httpx.Response(302, headers={"location": "https://evil.example/x"})
    forge = po.Forge("github", "https://api.github.com", "o/r", "tok", transport=httpx.MockTransport(h))
    with pytest.raises(httpx.HTTPStatusError, match="302"):
        forge.read_file(PATH, "main")


# ------------------------------------------------------------ GitHub App auth

def test_app_jwt_verifies_with_the_public_key():
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    tok = po.app_jwt("42", pem, now=1_800_000_000)
    head, body, sig = tok.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)
    claims = json.loads(base64.urlsafe_b64decode(pad(body)))
    assert claims == {"iat": 1_800_000_000 - 60, "exp": 1_800_000_000 + 540, "iss": "42"}
    k.public_key().verify(base64.urlsafe_b64decode(pad(sig)), f"{head}.{body}".encode(), padding.PKCS1v15(), hashes.SHA256())


def test_installation_token_is_scoped_to_one_repo_and_two_permissions():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    pem = rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    seen = []

    def h(req):
        seen.append(req)
        assert req.headers["authorization"].startswith("Bearer ey")
        if req.url.path == "/repos/o/r/installation":
            return httpx.Response(200, json={"id": 77})
        if req.url.path == "/app/installations/77/access_tokens":
            return httpx.Response(201, json={"token": "ghs_x"})
        return httpx.Response(404)
    assert po.app_installation_token("https://api.github.com", "o/r", "42", pem, transport=httpx.MockTransport(h)) == "ghs_x"
    body = json.loads(seen[-1].content)
    assert body == {"repositories": ["r"], "permissions": {"contents": "write", "pull_requests": "write"}}
    with pytest.raises(po.Refused, match="not installed"):
        po.app_installation_token("https://api.github.com", "o/x", "42", pem,
                                  transport=httpx.MockTransport(lambda r: httpx.Response(404)))


def test_the_ui_node_change_carries_the_same_rolling_annotation():
    v = values()
    inv = nm.parse_inventory(v["inferenceNodes"])
    doc = yaml.safe_load(nm.change_yaml(inv, "header", v["inferenceNodes"]))
    assert doc["litellm"] == nm.roll_block(inv) == {"podAnnotations": {nm.ROLL_ANNOTATION: nm.routes_hash(inv)}}
    assert len(nm.routes_hash(inv)) == 16


# ------------------------------------------------------------ TM-0939: branch names and anchors

def test_branch_slug_short_names_unchanged_long_ones_hashed_and_unique():
    assert po.branch_slug("local-agent") == "local-agent"
    a = "mlx-community/Qwen3.8-Flash-Next-4bit-mtp"
    b = "mlx-community/Qwen3.8-Flash-Next-4bit-mtp-dwq"     # same first 40 slug characters
    sa, sb = po.branch_slug(a), po.branch_slug(b)
    assert sa != sb and len(sa) <= po.BRANCH_SLUG_MAX and len(sb) <= po.BRANCH_SLUG_MAX
    assert po.branch_slug(a) == sa                         # stable across runs
    assert re.match(r"^[a-z0-9-]+$", sa) and not sa.endswith("-")


def test_an_admit_pr_writes_no_yaml_anchors_and_the_next_route_owns_its_tags():
    v = values()
    for r in v["inferenceNodes"]["routes"]:
        r.setdefault("params", {})["tags"] = ["restricted", "internal"]
    p = po.plan(v, report(), [])
    assert p.prs and p.prs[0].kind == "admit"
    text = p.prs[0].text
    assert not re.search(r"(^|\s)[&*]id\d+", text), "the values file carries a YAML anchor or alias"
    doc = yaml.safe_load(text)
    routes = doc["inferenceNodes"]["routes"]
    nxt = [r for r in routes if r["alias"].endswith("-next")]
    assert nxt
    for r in nxt:
        live = next(x for x in routes if x["alias"] == r["alias"][:-5])
        assert r["params"]["tags"] == live["params"]["tags"]
        assert r["params"]["tags"] is not live["params"]["tags"]


def test_proposed_next_route_does_not_share_the_incumbents_objects():
    v = values()
    for r in v["inferenceNodes"]["routes"]:
        r.setdefault("params", {})["tags"] = ["restricted"]
    lc, inv = ml.parse(v["modelLifecycle"]), nm.parse_inventory(v["inferenceNodes"])
    cand = next(c for c in ml.parse_report(report()).candidates if c.kind in ("quant", "successor"))
    _, add_inv, _ = ml.propose(cand, lc, inv)
    for r in add_inv.routes:
        live = next(x for x in inv.routes if x.alias == r.alias[:-5])
        assert r.params["tags"] is not live.params["tags"]
        r.params["tags"].append("changed")
        assert live.params["tags"] == ["restricted"]


def test_the_values_dumper_never_writes_anchors_even_for_shared_objects():
    shared = ["restricted", "internal"]
    text = yaml.dump({"a": {"tags": shared}, "b": {"tags": shared}}, Dumper=nm._Dumper, sort_keys=False)
    assert "&" not in text and "*" not in text
    assert yaml.safe_load(text) == {"a": {"tags": shared}, "b": {"tags": shared}}

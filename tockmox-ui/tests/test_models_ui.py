# SPDX-License-Identifier: Apache-2.0
"""REQ-0048 in the UI: admin only, report freshness, propose and promote end in changes, nothing is written."""
import datetime
import html
import json
import re

import yaml

from tests.proto_support import _secret, world  # noqa: F401  (fixtures)
from tests.proto_support import (SHA_NEW, lifecycle_full_doc, login_as, make_client, mac_series, verdict_record, write_report, write_verdicts)
from app import config as cfgmod
from app import models as ml
from app import nodes as nm

CANDS = [
    {"id": "successor:Qwen/Qwen3.9-27B", "kind": "successor", "subject": "qwen2-5-32b-4bit", "model": "mlx-community/Qwen3.9-27B-4bit",
     "source": {"kind": "huggingface", "ref": "mlx-community/Qwen3.9-27B-4bit"}, "detail": "newer qwen", "url": "https://huggingface.co/Qwen/Qwen3.9-27B", "sizeGiB": 17.5},
    {"id": "frontier:anthropic/claude-opus-5-5", "kind": "frontier", "subject": "anthropic", "model": "anthropic/claude-opus-5-5",
     "source": {"kind": "hosted", "ref": "anthropic/claude-opus-5-5"}, "detail": "new"},
    {"id": "deprecation:anthropic/claude-haiku-4-5", "kind": "deprecation", "subject": "anthropic", "model": "anthropic/claude-haiku-4-5",
     "source": {"kind": "hosted", "ref": "anthropic/claude-haiku-4-5"}, "detail": "retires 2026-12-01"},
    {"id": "revision:x", "kind": "revision", "subject": "qwen3-8-27b-4bit", "model": "mlx-community/Qwen3.8-27B-4bit",
     "source": {"kind": "huggingface", "ref": "mlx-community/Qwen3.8-27B-4bit", "revision": SHA_NEW}, "detail": "new commit",
     "url": "javascript:alert(1)"},
]


def admin(world, tmp_path, cands=CANDS, **kw):
    c, app, s = make_client(world, lifecycle_full_doc(report=write_report(tmp_path, cands, **kw)))
    return c, app, s, login_as(c, s, ["tockmox-admins"])


def test_models_page_lists_catalog_and_candidates(world, tmp_path):
    c, app, s, u = admin(world, tmp_path)
    t = c.get("/models").text
    assert "Promotion gate passes" in t and "mlx-community/Qwen3.8-27B-4bit" in t
    assert "Newer models in families you run" in t and "New hosted models" in t and "Hosted models being retired" in t
    assert "javascript:" not in t                                     # only https links from a report are rendered
    assert "Routed but not in the catalog" in t                       # e.g. local-fast's model


def test_stale_or_partial_report_reads_unknown(world, tmp_path):
    c, app, s, u = admin(world, tmp_path, generated="2026-01-01T00:00:00Z")
    assert "the watcher may have stopped" in c.get("/models").text
    c, app, s, u = admin(world, tmp_path, sources={"huggingface": {"ok": False, "reason": "unreachable"}})
    assert "not every upstream answered" in c.get("/models").text


def test_no_report_says_not_watching(world):
    c, app, s = make_client(world, lifecycle_full_doc())
    login_as(c, s, ["tockmox-admins"])
    assert "Not watching" in c.get("/models").text


def test_admin_only(world, tmp_path):
    c, app, s, u = admin(world, tmp_path)
    login_as(c, s, ["tockmox-users"])
    for p in ("/models", "/models/profiles", "/models/promote?alias=x-next", "/models/evaluate?alias=x-next",
              "/models/promote-hosted?entry=x"):
        assert c.get(p).status_code == 403
    assert c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDS[0]["id"]}).status_code == 403
    assert c.post("/models/evaluate", data={"csrf": u.csrf, "alias": "x-next"}).status_code == 403
    assert c.post("/models/promote-hosted", data={"csrf": u.csrf, "entry": "x"}).status_code == 403


def test_propose_successor_gives_a_next_route_and_a_valid_change(world, tmp_path):
    c, app, s, u = admin(world, tmp_path)
    r = c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDS[0]["id"], "fmt": "yaml"})
    doc = yaml.safe_load(r.text)
    routes = {x["alias"]: x for x in doc["inferenceNodes"]["routes"]}
    assert routes["local-medium-next"]["model"] == "mlx-community/Qwen3.8-27B-4bit"  # the existing -next is untouched
    assert routes["local-medium"]["model"] == "mlx-community/Qwen2.5-32B-Instruct-4bit"  # live alias untouched
    assert routes["ops-32b-next"]["model"] == "mlx-community/Qwen3.9-27B-4bit"
    t = c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDS[0]["id"]}).text
    assert "local-medium-next already serves mlx-community/Qwen3.8-27B-4bit" in t   # found by this test: never overwrite a comparison
    prod = t.split("What the production gateway will get")[1].split("What the eval gateway will get")[0] \
        if "What the production gateway will get" in t else ""
    ev = html.unescape(t.split("What the eval gateway will get")[1].split("The values blocks")[0])
    assert "ops-32b-next" in ev and "ops-32b-next" not in prod            # the candidate is on the eval gateway only
    # the committed result loads, and the gate passes
    d = lifecycle_full_doc()
    d["modelLifecycle"] = doc["modelLifecycle"]
    d["inferenceNodes"].update(doc["inferenceNodes"])
    cfgmod.parse(d)


def test_propose_frontier_admits_it_to_the_eval_gateway_untagged(world, tmp_path):
    c, app, s, u = admin(world, tmp_path)
    t = html.unescape(c.post("/models/propose", data={"csrf": u.csrf, "cid": CANDS[1]["id"]}).text)
    assert "What the eval gateway will get" in t and "What the production gateway will get" not in t
    assert "claude-opus-5-5" in t and "tags:" not in t.split("What the eval gateway will get")[1].split("The values blocks")[0]


def test_propose_needs_csrf_and_a_current_candidate(world, tmp_path):
    c, app, s, u = admin(world, tmp_path)
    assert c.post("/models/propose", data={"csrf": "x", "cid": CANDS[0]["id"]}).status_code == 400
    assert c.post("/models/propose", data={"csrf": u.csrf, "cid": "nope"}).status_code == 404


NEW = "mlx-community/Qwen3.9-27B-4bit"
OLD = "mlx-community/Qwen3.6-35B-A3B-4bit"   # what local-agent serves in the fixture


def _with_next_config(tmp_path, *records):
    d = lifecycle_full_doc(report=write_report(tmp_path, []))
    d["modelLifecycle"]["catalog"].append({"id": "q39", "model": NEW, "stage": "candidate",
                                           "source": {"kind": "huggingface", "ref": NEW}})
    d["inferenceNodes"]["routes"].append({"alias": "local-agent-next", "node": "mac-studio-m4-max", "endpoint": "http-8082",
                                          "model": NEW, "kind": "chat"})
    d["modelLifecycle"]["verdictsDir"] = write_verdicts(tmp_path, *records)
    return d


def _pass(i, verdict="pass"):
    return verdict_record(NEW, "local-agent", verdict, run=f"r{i}", date=f"2026-10-0{i + 1}", incumbent=OLD)


def test_promote_counts_then_refuses_then_accepts(world, tmp_path):
    c, app, s = make_client(world, _with_next_config(tmp_path, _pass(0), _pass(1)))
    u = login_as(c, s, ["tockmox-admins"])
    t = c.get("/models").text
    assert "Comparisons in progress" in t and "2 of 3" in t
    assert "2 of 3" in c.get("/models/promote?alias=local-agent-next").text
    bad = c.post("/models/promote", data={"csrf": u.csrf, "alias": "local-agent-next"})
    assert bad.status_code == 400 and "Not promoted" in bad.text and "2 of 3" in bad.text
    c, app, s = make_client(world, _with_next_config(tmp_path, _pass(0), _pass(1), _pass(2)))
    u = login_as(c, s, ["tockmox-admins"])
    assert "Ready to promote" in c.get("/models").text
    ok = c.post("/models/promote", data={"csrf": u.csrf, "alias": "local-agent-next", "fmt": "yaml"})
    doc = yaml.safe_load(ok.text)
    routes = {x["alias"]: x for x in doc["inferenceNodes"]["routes"]}
    assert routes["local-agent"]["model"] == NEW and "local-agent-next" not in routes
    e = next(x for x in doc["modelLifecycle"]["catalog"] if x["model"] == NEW)
    assert e["stage"] == "promoted" and len(e["promotion"]["evidence"]) == 3
    assert e["promotion"]["evidence"][0]["path"] == "evals/verdicts/000.json"


def test_a_fail_resets_the_count_in_the_ui(world, tmp_path):
    c, app, s = make_client(world, _with_next_config(tmp_path, _pass(0), _pass(1), _pass(2, "fail"), _pass(3)))
    login_as(c, s, ["tockmox-admins"])
    t = html.unescape(c.get("/models/promote?alias=local-agent-next").text)
    assert "1 of 3" in t and "no longer count" in t


def test_an_unreadable_verdict_file_blocks_promotion(world, tmp_path):
    """The file that does not parse could be the fail that resets the count."""
    c, app, s = make_client(world, _with_next_config(tmp_path, _pass(0), _pass(1), _pass(2), "{not json"))
    u = login_as(c, s, ["tockmox-admins"])
    assert "could not be read" in c.get("/models").text
    r = c.post("/models/promote", data={"csrf": u.csrf, "alias": "local-agent-next"})
    assert r.status_code == 400 and "cannot be trusted" in r.text


def test_start_an_evaluation_generates_a_request_and_writes_nothing(world, tmp_path):
    c, app, s = make_client(world, _with_next_config(tmp_path))
    u = login_as(c, s, ["tockmox-admins"])
    assert c.get("/models/evaluate?alias=local-agent-next").status_code == 200
    assert c.get("/models/evaluate?alias=nope-next").status_code == 404
    t = html.unescape(c.post("/models/evaluate", data={"csrf": u.csrf, "alias": "local-agent-next", "klass": "chat"}).text)
    assert "evals/requests/" in t and "eval-request/1" in t
    y = c.post("/models/evaluate", data={"csrf": u.csrf, "alias": "local-agent-next", "klass": "chat", "fmt": "yaml"})
    req = yaml.safe_load(y.text)
    assert req["alias"] == "local-agent" and req["candidate"]["model"] == NEW and req["incumbent"]["model"] == OLD
    assert req["runs"] == 3 and req["gateway"] == "eval"
    bad = c.post("/models/evaluate", data={"csrf": u.csrf, "alias": "local-agent-next", "klass": "Chat!"})
    assert bad.status_code == 400
    assert c.post("/models/evaluate", data={"csrf": "x", "alias": "local-agent-next", "klass": "chat"}).status_code == 400


def test_hosted_candidate_evaluate_and_promote(world, tmp_path):
    d = lifecycle_full_doc(report=write_report(tmp_path, []))
    d["modelLifecycle"]["catalog"].append({"id": "anthropic-opus", "model": "anthropic/claude-opus-5-5", "stage": "candidate",
                                           "source": {"kind": "hosted", "ref": "anthropic/claude-opus-5-5"}, "track": ["deprecation"]})
    d["modelLifecycle"]["verdictsDir"] = write_verdicts(tmp_path, *[verdict_record("anthropic/claude-opus-5-5", "frontier-chat", run=f"h{i}")
                                                                    for i in range(3)])
    c, app, s = make_client(world, d)
    u = login_as(c, s, ["tockmox-admins"])
    assert "hosted candidate on the eval gateway" in c.get("/models").text
    assert "3 of 3" in c.get("/models/promote-hosted?entry=anthropic-opus&target=frontier-chat").text
    r = c.post("/models/promote-hosted", data={"csrf": u.csrf, "entry": "anthropic-opus", "target": "frontier-chat", "tags": ""})
    assert r.status_code == 400 and "tag" in r.text
    ok = html.unescape(c.post("/models/promote-hosted", data={"csrf": u.csrf, "entry": "anthropic-opus", "target": "frontier-chat",
                                                              "tags": "open"}).text)
    assert "What the production gateway will get" in ok and "model_name: frontier-chat" in ok and "- open" in ok
    y = yaml.safe_load(c.post("/models/promote-hosted", data={"csrf": u.csrf, "entry": "anthropic-opus", "target": "frontier-chat",
                                                              "tags": "open", "fmt": "yaml"}).text)
    e = next(x for x in y["modelLifecycle"]["catalog"] if x["id"] == "anthropic-opus")
    assert e["stage"] == "promoted" and e["promotion"]["tags"] == ["open"]


def test_model_page_links_to_its_source_and_never_fetches(world, tmp_path):
    d = lifecycle_full_doc(report=write_report(tmp_path, CANDS))
    d["modelLifecycle"]["catalog"][0]["links"] = [{"title": "Release notes", "url": "https://qwenlm.github.io/blog/qwen3.8/"}]
    c, app, s = make_client(world, d)
    login_as(c, s, ["tockmox-admins"])
    assert '/models/m/qwen3-8-27b-4bit"' in c.get("/models").text
    t = c.get("/models/m/qwen3-8-27b-4bit").text
    assert 'href="https://huggingface.co/mlx-community/Qwen3.8-27B-4bit"' in t and "Release notes" in t
    assert "Where it is served" in t and "eval gateway" in t                 # local-medium-next serves this model
    assert "What the watcher found newer" in t and "javascript:" not in t
    assert 'href="https://ollama.com/library/qwen3-coder/tags"' in c.get("/models/m/qwen3-coder-30b").text
    assert c.get("/models/m/nope").status_code == 404
    login_as(c, s, ["tockmox-users"])
    assert c.get("/models/m/qwen3-8-27b-4bit").status_code == 403


def test_profiles_page_plans_each_node(world, tmp_path):
    mac_series(world)
    world.series['sum by (model_group) (increase(litellm_deployment_success_responses_total[7d]))'] = [
        ({"model_group": "local-medium-next"}, 412), ({"model_group": "ops-agent-30b"}, 37)]
    c, app, s, u = admin(world, tmp_path)
    t = c.get("/models/profiles").text
    assert "Residency plan for Mac Studio M4 Max" in t and "local-agent wanted pinned but does not fit" in t
    assert "llama-swap configuration" in t and "412 requests" in t

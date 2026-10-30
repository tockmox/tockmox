# SPDX-License-Identifier: Apache-2.0
"""Unit tests for the shipped key policy module (TM-0991). The live proof against a real LiteLLM is run.sh."""
import asyncio
import importlib.util
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "..", "charts", "tockmox-ai", "files", "key-policy", "tockmox_key_policy.py")


def load(tmp_path, policy_text):
    p = tmp_path / "policy.yaml"
    if policy_text is not None:
        p.write_text(policy_text)
    os.environ["TOCKMOX_KEY_POLICY_PATH"] = str(p)
    spec = importlib.util.spec_from_file_location("tockmox_key_policy", MOD)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


POLICY = "allow_all_models_aliases: [open-webui]\nrefuse_suffixes: ['-next']\nrequire_mcp: true\n"


def call(m, op, models, alias="agent-x", op_perm="unset"):
    req = {} if op_perm == "unset" else {"object_permission": op_perm}
    return asyncio.run(m.check({"operation": op, "effective_key": {"key_alias": alias, "models": models}, "request": req}))


@pytest.mark.parametrize("models", [[], None, ["*"], ["all-proxy-models"], ["local-chat", "*"]])
def test_an_open_model_list_is_refused(tmp_path, models):
    m = load(tmp_path, POLICY)
    r = call(m, "generate", models, op_perm={"mcp_servers": ["no-mcp-servers"]})
    assert r["decision"] is False and "EVERY model" in r["message"]


def test_the_named_console_alias_may_have_every_model(tmp_path):
    m = load(tmp_path, POLICY)
    assert call(m, "generate", [], alias="open-webui", op_perm={"mcp_servers": ["no-mcp-servers"]}) == {"decision": True}


def test_an_update_back_to_an_empty_list_is_refused(tmp_path):
    m = load(tmp_path, POLICY)
    r = call(m, "update", [], op_perm="unset")
    assert r["decision"] is False


def test_a_candidate_name_is_refused(tmp_path):
    m = load(tmp_path, POLICY)
    r = call(m, "generate", ["local-agent-next"], op_perm={"mcp_servers": ["no-mcp-servers"]})
    assert r["decision"] is False and "candidate" in r["message"]


@pytest.mark.parametrize("op_perm,ok", [
    ("unset", False), ({"vector_stores": []}, False), ({"mcp_servers": []}, False), ({"mcp_servers": ["*"]}, False),
    ({"mcp_servers": ["no-mcp-servers"]}, True), ({"mcp_servers": ["k8s-ro"]}, True)])
def test_a_new_key_must_state_its_mcp_access(tmp_path, op_perm, ok):
    m = load(tmp_path, POLICY)
    assert call(m, "generate", ["local-chat"], op_perm=op_perm)["decision"] is ok


def test_an_update_that_does_not_touch_mcp_is_allowed_and_one_that_empties_it_is_not(tmp_path):
    m = load(tmp_path, POLICY)
    assert call(m, "update", ["local-chat"], op_perm="unset")["decision"] is True
    assert call(m, "update", ["local-chat"], op_perm={"mcp_servers": []})["decision"] is False


def test_an_unreadable_policy_fails_closed(tmp_path):
    m = load(tmp_path, None)
    r = call(m, "generate", ["local-chat"], op_perm={"mcp_servers": ["no-mcp-servers"]})
    assert r["decision"] is False and "failing closed" in r["message"]


def test_a_pydantic_request_is_read_too(tmp_path):
    m = load(tmp_path, POLICY)

    class OP:
        def model_dump(self, exclude_unset=True):
            return {"mcp_servers": []}

    class Req:
        object_permission = OP()

    r = asyncio.run(m.check({"operation": "generate", "effective_key": {"key_alias": "a", "models": ["x"]}, "request": Req()}))
    assert r["decision"] is False

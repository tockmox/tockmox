# SPDX-License-Identifier: Apache-2.0
"""Tockmox key policy for the model gateway (TM-0991; DESIGN-2026-10-29-agent-kit-security K1 and K2).

Registered as LiteLLM's `general_settings.custom_key_policy: hooks.tockmox_key_policy.check` and rendered into the
`tockmox-litellm-hooks` ConfigMap by charts/tockmox-ai when modelGateway.keyPolicy.enabled is true. LiteLLM calls
it on every key generate, update and regenerate, with the key as it WILL be written (`effective_key`), and refuses
the operation with a 403 when it returns {"decision": False}.

Why it exists. On LiteLLM a virtual key whose model list is empty, absent, `*` or `all-proxy-models` can call every
model the gateway has (measured on 1.100.3, TM-0936; the same code path in 1.106.6), and
`default_key_generate_params` fills the gap only when a key is MINTED, so a later update back to an empty list
reopens it. The same open default applies to MCP tool servers: a key with no `mcp_servers` list reaches every one.
Defaults are defense in depth; this is the fence, because it runs on every write.

The rules (all data in tockmox_key_policy.yaml, rendered from values; nothing here is site-specific):
  1. A key names its models. Empty, absent, `*` and `all-proxy-models` are refused, except for a key whose alias is
     listed in allow_all_models_aliases (the console's own key: one named, reviewable exception).
  2. A key never names a model with a refused suffix (`-next` by default): candidates live on the eval gateway, and
     a production key that names one is a mistake waiting for a route.
  3. A key states its MCP access. On generate the request must carry object_permission.mcp_servers, a non-empty
     list (["no-mcp-servers"] is the explicit "none"); on update an mcp_servers list, when sent, must be non-empty.
     `*` is refused everywhere.
  4. Fail closed: a policy file that cannot be read refuses every operation, and says so.

It does not see, and so does not govern: the master key (not a virtual key), keys that already exist until they are
next updated (tools/audit-keys.sh lists them), and what a key does with a model it may call (the policy gate's job).
"""

import os

import yaml

POLICY_PATH = os.environ.get("TOCKMOX_KEY_POLICY_PATH", "/etc/litellm/hooks/tockmox_key_policy.yaml")
WILDCARDS = {"*", "all-proxy-models"}
NO_MCP = "no-mcp-servers"


def _load_policy():
    with open(POLICY_PATH, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    if not isinstance(doc, dict):
        raise ValueError("the policy file is not a mapping")
    return {
        "allow_all_models_aliases": set(doc.get("allow_all_models_aliases") or []),
        "refuse_suffixes": tuple(doc.get("refuse_suffixes") or ()),
        "require_mcp": bool(doc.get("require_mcp", True)),
    }


def _get(obj, name, default=None):
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _mcp_servers_of(request):
    """(present, servers) for the object_permission the REQUEST carries. A pydantic model or a dict."""
    op = _get(request, "object_permission")
    if op is None:
        return False, None
    if not isinstance(op, dict) and hasattr(op, "model_dump"):
        op = op.model_dump(exclude_unset=True)
    if not isinstance(op, dict) or "mcp_servers" not in op:
        return False, None
    return True, op.get("mcp_servers")


def decide(operation, effective_key, request, policy):
    """The rules, pure: returns (decision, message)."""
    alias = _get(effective_key, "key_alias") or ""
    models = list(_get(effective_key, "models") or [])
    if not models or WILDCARDS & set(models):
        if alias not in policy["allow_all_models_aliases"]:
            what = "no model list" if not models else f"the wildcard {sorted(WILDCARDS & set(models))[0]!r}"
            return False, (f"tockmox key policy: the key has {what}, which LiteLLM reads as EVERY model on the gateway. "
                           "Name the models (or access groups) this key may call.")
    for m in models:
        for suf in policy["refuse_suffixes"]:
            if suf and str(m).endswith(suf):
                return False, (f"tockmox key policy: {m!r} is a candidate name ({suf}); candidates are served by the "
                               "eval gateway, never to a production key")
    present, servers = _mcp_servers_of(request)
    if present:
        if not isinstance(servers, list) or not servers:
            return False, ("tockmox key policy: object_permission.mcp_servers is empty, which LiteLLM reads as EVERY "
                           f"MCP server. Name the servers, or send [{NO_MCP!r}] for none.")
        if "*" in servers:
            return False, "tockmox key policy: object_permission.mcp_servers may not contain '*'"
    elif operation == "generate" and policy["require_mcp"]:
        return False, ("tockmox key policy: the key does not state its MCP access. Send "
                       f"object_permission.mcp_servers: [{NO_MCP!r}] for none, or name the servers.")
    return True, ""


async def check(data):
    """LiteLLM's custom_key_policy entry point. `data` is a CustomKeyPolicyRequest."""
    try:
        policy = _load_policy()
    except Exception as e:  # fail closed: the rules live in the file that could not be read
        return {"decision": False, "message": f"tockmox key policy: failing closed, the policy file is unreadable ({e})"}
    ok, msg = decide(_get(data, "operation", ""), _get(data, "effective_key"), _get(data, "request"), policy)
    return {"decision": True} if ok else {"decision": False, "message": msg}

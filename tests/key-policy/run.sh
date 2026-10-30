#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2015  # `ok ... || bad ...`: ok and bad are printf wrappers that return 0, so C runs only when A or B failed
#
# THE KEY POLICY, AGAINST A REAL PROXY WITH A REAL DATABASE (TM-0991).
#
# The claim: with modelGateway.keyPolicy on, no virtual key can be written that reaches every model, names a
# candidate, or leaves its MCP access unstated, on mint OR on update. The case that matters is the update: LiteLLM's
# default_key_generate_params only applies at mint time, so a key updated back to an empty model list reaches every
# model again (measured on 1.100.3, TM-0936). This runs the shipped module in the shipped LiteLLM version, with a
# throwaway Postgres for its key table and two fake backends on 127.0.0.1 (local and frontier), and then runs the
# SAME requests against the same proxy with the policy unregistered, so each refusal is shown to be the policy's doing
# (the red leg), not something LiteLLM would have refused anyway.
#
# EVERYTHING UNDER TEST COMES FROM THE RENDER: config.yaml, tockmox_key_policy.py and tockmox_key_policy.yaml are
# extracted from `helm template charts/tockmox-ai` with ci/values.yaml, ci/values-policy-gate.yaml (for its two-model
# list) and ci/values-key-policy.yaml.
#
#   1 control   mint {models: [local-chat], mcp: none}              200; it answers on local-chat; frontier-x refused
#   2 open      mint {models: []}                                   403 EVERY model
#   3 wildcard  mint {models: ["*"]} and ["all-proxy-models"]       403
#   4 mcp       mint {models: [local-chat]} with no MCP statement   403
#   5 THE CASE  update key 1 to {models: []}                        403, and key 1 still cannot reach frontier-x
#   6 candidate mint {models: [local-agent-next]}                   403
#   7 named     mint alias open-webui {models: []}                  200 (the console's one named exception)
#   8 closed    policy file unreadable                              403 failing closed
#   9 RED LEG   the same proxy WITHOUT custom_key_policy:
#               2, 4 and 5 succeed, and the opened key reaches frontier-x (so the refusals above were the policy's)
#
# Needs: helm, python3 with PyYAML, curl, Postgres binaries (initdb, pg_ctl), and the `litellm` CLI at the chart's
# version with its database extras (set LITELLM_BIN). Without them this exits 2, SKIPPED, never 0.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

LITELLM_BIN="${LITELLM_BIN:-$(command -v litellm || true)}"
# shellcheck disable=SC2012  # one well-known path pattern, version directories only
PGBIN="${PGBIN:-$(dirname "$(ls /usr/lib/postgresql/*/bin/initdb 2>/dev/null | head -1)" 2>/dev/null)}"
command -v helm >/dev/null 2>&1 || { echo "key-policy: helm not on PATH"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "key-policy: curl not on PATH"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "key-policy: python3 PyYAML missing"; exit 2; }
[ -n "$LITELLM_BIN" ] && [ -x "$LITELLM_BIN" ] || { echo "key-policy: SKIPPED, no litellm CLI (set LITELLM_BIN)"; exit 2; }
[ -n "$PGBIN" ] && [ -x "$PGBIN/initdb" ] || { echo "key-policy: SKIPPED, no Postgres binaries (set PGBIN)"; exit 2; }

PORT_PROXY="${PORT_PROXY:-14100}"; PORT_PG="${PORT_PG:-15432}"; KEY=sk-key-policy-test
work="$(mktemp -d)"; pids=()
# shellcheck disable=SC2329  # invoked by the trap
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; pg "$PGBIN/pg_ctl" -D "$work/pg" -m fast stop >/dev/null 2>&1; wait 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }

# --- the artifact under test, from the render
helm template t charts/tockmox-ai -f ci/values.yaml -f ci/values-policy-gate.yaml -f ci/values-key-policy.yaml > "$work/render.yaml" \
  || { echo "key-policy: the fixture does not render"; exit 1; }
mkdir -p "$work/cfg/hooks"
python3 - "$work" <<'PY' || exit 1
import sys, yaml
w = sys.argv[1]
class L(yaml.SafeLoader): pass
L.add_multi_constructor("", lambda l, s, n: None)
got = set()
for d in yaml.load_all(open(f"{w}/render.yaml"), Loader=L):
    if not isinstance(d, dict) or d.get("kind") != "ConfigMap":
        continue
    data = d.get("data") or {}
    if "config.yaml" in data and "litellm" in d["metadata"]["name"]:
        cfg = yaml.safe_load(data["config.yaml"])
        assert cfg["general_settings"]["custom_key_policy"] == "hooks.tockmox_key_policy.check"
        cfg["general_settings"]["database_url"] = "os.environ/DATABASE_URL"
        yaml.safe_dump(cfg, open(f"{w}/cfg/config.yaml", "w"))
        del cfg["general_settings"]["custom_key_policy"]                # the red leg's config: same, unregistered
        yaml.safe_dump(cfg, open(f"{w}/cfg/config-open.yaml", "w")); got.add("config")
    if d["metadata"]["name"] == "tockmox-litellm-hooks":
        for k in data:
            open(f"{w}/cfg/hooks/{k}", "w").write(data[k]); got.add(k)
need = {"config", "tockmox_key_policy.py", "tockmox_key_policy.yaml", "tockmox_gate.py", "tockmox_policy.yaml"}
if not need <= got:
    sys.exit(f"key-policy: the render is missing {sorted(need - got)}")
PY
echo "artifact: config.yaml and the key-policy module and policy extracted from the render"

# --- a throwaway database for the key table (Postgres refuses to run as root; a CI container often is root)
pg() { if [ "$(id -u)" = 0 ]; then runuser -u postgres -- "$@"; else "$@"; fi; }
if [ "$(id -u)" = 0 ]; then mkdir -p "$work/pg" && chown postgres "$work" "$work/pg"; fi
pg "$PGBIN/initdb" -D "$work/pg" -U postgres --auth=trust -E UTF8 --no-locale >/dev/null 2>&1 || { echo "key-policy: initdb failed"; exit 1; }
pg "$PGBIN/pg_ctl" -D "$work/pg" -o "-p $PORT_PG -k $work -c listen_addresses=127.0.0.1" -l "$work/pg.log" start >/dev/null \
  || { echo "key-policy: postgres did not start"; tail -5 "$work/pg.log"; exit 1; }
export DATABASE_URL="postgresql://postgres@127.0.0.1:$PORT_PG/postgres"

: > "$work/local.log"; : > "$work/ext.log"
python3 tests/policy-gate/fake_backend.py 18101 local "$work/local.log" & pids+=($!)
python3 tests/policy-gate/fake_backend.py 18102 external "$work/ext.log" & pids+=($!)
# The fixture's model list names 18001/18002 (the policy-gate test's ports); point them here.
sed -i.bak -e 's#127.0.0.1:18001#127.0.0.1:18101#' -e 's#127.0.0.1:18002#127.0.0.1:18102#' "$work/cfg/config.yaml" "$work/cfg/config-open.yaml"
export PROXY_MASTER_KEY="$KEY" FRONTIER_KEY=fake-not-a-secret \
  TOCKMOX_POLICY_PATH="$work/cfg/hooks/tockmox_policy.yaml" TOCKMOX_KEY_POLICY_PATH="$work/cfg/hooks/tockmox_key_policy.yaml"

PROXY_PID=
start_proxy() {   # $1 = config file
  [ -n "$PROXY_PID" ] && { kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null; }
  ( cd "$work/cfg" && exec "$LITELLM_BIN" --config "$1" --port "$PORT_PROXY" ) >> "$work/proxy.log" 2>&1 & PROXY_PID=$!; pids+=($!)
  for _ in $(seq 1 240); do curl -fs -o /dev/null "http://127.0.0.1:$PORT_PROXY/health/liveliness" && return 0; sleep 1; done
  echo "key-policy: the proxy never came up"; tail -40 "$work/proxy.log"; exit 1
}
mgmt() { curl -s -o "$work/resp" -w '%{http_code}' "http://127.0.0.1:$PORT_PROXY$1" -H "Authorization: Bearer $KEY" \
           -H 'Content-Type: application/json' -d "$2"; }
chat() { curl -s -o "$work/chat" -w '%{http_code}' "http://127.0.0.1:$PORT_PROXY/v1/chat/completions" -H "Authorization: Bearer $1" \
           -H 'Content-Type: application/json' -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"; }
keyof() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("key",""))' "$work/resp"; }
NOMCP='"object_permission":{"mcp_servers":["no-mcp-servers"]}'
ext() { wc -l < "$work/ext.log" | tr -d ' '; }

start_proxy config.yaml

# 1
code=$(mgmt /key/generate "{\"key_alias\":\"agent-a\",\"models\":[\"local-chat\"],$NOMCP}"); K1=$(keyof)
[ "$code" = 200 ] && [ -n "$K1" ] && ok "1 control: a scoped key with its MCP access stated is minted" \
  || bad "1 control: expected 200, got $code $(head -c 300 "$work/resp")"
c=$(chat "$K1" local-chat); [ "$c" = 200 ] && ok "1 control: it answers on local-chat" || bad "1 control: local-chat gave $c"
e0=$(ext); c=$(chat "$K1" frontier-x)
[ "$c" != 200 ] && [ "$(( $(ext) - e0 ))" = 0 ] && ok "1 control: it is refused on frontier-x ($c), nothing reached the frontier backend" \
  || bad "1 control: frontier-x gave $c with $(( $(ext) - e0 )) frontier hit(s)"
# 2
code=$(mgmt /key/generate "{\"key_alias\":\"agent-b\",\"models\":[],$NOMCP}")
[ "$code" = 403 ] && grep -q "EVERY model" "$work/resp" && ok "2 open: a key with an empty model list is refused 403" \
  || bad "2 open: expected 403, got $code $(head -c 300 "$work/resp")"
# 3
for w in '"*"' '"all-proxy-models"'; do
  code=$(mgmt /key/generate "{\"key_alias\":\"agent-c\",\"models\":[$w],$NOMCP}")
  [ "$code" = 403 ] && ok "3 wildcard: models [$w] is refused 403" || bad "3 wildcard: models [$w] gave $code"
done
# 4
code=$(mgmt /key/generate '{"key_alias":"agent-d","models":["local-chat"]}')
[ "$code" = 403 ] && grep -q "MCP access" "$work/resp" && ok "4 mcp: a new key that does not state its MCP access is refused 403" \
  || bad "4 mcp: expected 403, got $code $(head -c 300 "$work/resp")"
# 5
code=$(mgmt /key/update "{\"key\":\"$K1\",\"models\":[]}")
[ "$code" = 403 ] && ok "5 THE CASE: updating key 1 back to an empty model list is refused 403" \
  || bad "5 THE CASE: expected 403, got $code $(head -c 300 "$work/resp")"
e0=$(ext); c=$(chat "$K1" frontier-x)
[ "$c" != 200 ] && [ "$(( $(ext) - e0 ))" = 0 ] && ok "5 THE CASE: key 1 still cannot reach frontier-x" || bad "5 THE CASE: key 1 reached frontier-x ($c)"
# 6
code=$(mgmt /key/generate "{\"key_alias\":\"agent-e\",\"models\":[\"local-agent-next\"],$NOMCP}")
[ "$code" = 403 ] && grep -q "candidate" "$work/resp" && ok "6 candidate: a key naming a -next model is refused 403" || bad "6 candidate: gave $code"
# 7
code=$(mgmt /key/generate "{\"key_alias\":\"open-webui\",\"models\":[],$NOMCP}")
[ "$code" = 200 ] && ok "7 named: the console alias may hold every model (the one named exception)" || bad "7 named: gave $code $(head -c 300 "$work/resp")"
# 8
mv "$TOCKMOX_KEY_POLICY_PATH" "$TOCKMOX_KEY_POLICY_PATH.away"
code=$(mgmt /key/generate "{\"key_alias\":\"agent-f\",\"models\":[\"local-chat\"],$NOMCP}")
mv "$TOCKMOX_KEY_POLICY_PATH.away" "$TOCKMOX_KEY_POLICY_PATH"
[ "$code" = 403 ] && grep -q "failing closed" "$work/resp" && ok "8 closed: an unreadable policy refuses even a good key" || bad "8 closed: gave $code"

# 9 the red leg: the same proxy, the same database, the policy unregistered
start_proxy config-open.yaml
code=$(mgmt /key/generate "{\"key_alias\":\"agent-r\",\"models\":[],$NOMCP}"); KR=$(keyof)
[ "$code" = 200 ] && ok "9 red: without the policy, the empty-list key is minted (so 2 was the policy's refusal)" || bad "9 red: mint gave $code"
e0=$(ext); c=$(chat "$KR" frontier-x)
[ "$c" = 200 ] && [ "$(( $(ext) - e0 ))" = 1 ] && ok "9 red: and that key reaches frontier-x: the fail-open the policy closes, measured on this LiteLLM" \
  || bad "9 red: the empty-list key gave $c on frontier-x (expected the fail-open)"
code=$(mgmt /key/generate '{"key_alias":"agent-r2","models":["local-chat"]}')
[ "$code" = 200 ] && ok "9 red: without the policy, a key with no MCP statement is minted (so 4 was the policy's)" || bad "9 red: gave $code"
code=$(mgmt /key/update "{\"key\":\"$K1\",\"models\":[]}")
[ "$code" = 200 ] && ok "9 red: without the policy, key 1 is updated to an empty list (so 5 was the policy's)" || bad "9 red: update gave $code"
e0=$(ext); c=$(chat "$K1" frontier-x)
[ "$c" = 200 ] && ok "9 red: and key 1 now reaches frontier-x: the update-reopens-it hole, measured" \
  || ok "9 red: key 1 still refused on frontier-x after the update ($c): this LiteLLM does not reopen on update"

echo
"$LITELLM_BIN" --version 2>/dev/null | tail -1 | sed 's/^/litellm: /'
if [ "$fail" = 0 ]; then echo "key-policy: PASSED"; exit 0; fi
echo "key-policy: FAILED (proxy log tail follows)"; tail -40 "$work/proxy.log"; exit 1

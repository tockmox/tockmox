#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE POLICY GATE, AGAINST A REAL PROXY, WITH THE LOCAL BACKEND KILLED (TM-0383).
#
# REQ-0002 AC-2.2 is the claim that a restricted request never reaches an
# external endpoint, and the case that matters is the one where the local
# endpoint is DOWN: that is when a gateway with a fallback, or a client asking
# for one, quietly sends the request somewhere else. This runs the shipped gate
# in the shipped LiteLLM version against two fake backends on 127.0.0.1, one
# local-tier and one external-tier, and counts what reaches the external one.
#
# EVERYTHING UNDER TEST COMES FROM THE RENDER. The proxy config, the gate module
# and its policy are extracted from `helm template charts/tockmox-ai` with
# ci/values.yaml and ci/values-policy-gate.yaml, not written here, so the test
# proves what the chart ships rather than a copy of it.
#
# The cases, each asserting one direction:
#   1 control   restricted -> local-chat, local up      200, local answers
#   2 control   open -> frontier-x                      200, external answers once
#               (the external backend works, so a zero below is a real zero)
#   3 tighten   client asks frontier-x as restricted    403, nothing reaches external,
#                                                       ONE audit line, status refused
#   4 THE CASE  local killed; restricted -> local-chat, error, nothing reaches external
#               client sends fallbacks: [frontier-x]   audit line status error, local tier
#   5 policy    policy file unreadable                 500 "failing closed"
#
# Needs: helm, python3 with PyYAML, curl, and the `litellm` CLI at the version
# the chart vendors (set LITELLM_BIN, or put it on PATH). Without litellm this
# exits 2, SKIPPED, never 0: CI installs it (.github/workflows/policy-gate.yaml).
set -uo pipefail
cd "$(dirname "$0")/../.."

LITELLM_BIN="${LITELLM_BIN:-$(command -v litellm || true)}"
command -v helm >/dev/null 2>&1 || { echo "policy-gate: helm not on PATH"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "policy-gate: curl not on PATH"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "policy-gate: python3 PyYAML missing"; exit 2; }
[ -n "$LITELLM_BIN" ] && [ -x "$LITELLM_BIN" ] || { echo "policy-gate: SKIPPED, no litellm CLI (set LITELLM_BIN)"; exit 2; }

PORT_PROXY="${PORT_PROXY:-14000}"; KEY=sk-policy-gate-test
work="$(mktemp -d)"; pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }

# --- extract the artifact under test from the render
helm template t charts/tockmox-ai -f ci/values.yaml -f ci/values-policy-gate.yaml > "$work/render.yaml" \
  || { echo "policy-gate: the fixture does not render"; exit 1; }
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
        open(f"{w}/cfg/config.yaml", "w").write(data["config.yaml"]); got.add("config")
    if d["metadata"]["name"] == "tockmox-litellm-hooks":
        for k in ("tockmox_gate.py", "tockmox_policy.yaml"):
            open(f"{w}/cfg/hooks/{k}", "w").write(data[k]); got.add(k)
need = {"config", "tockmox_gate.py", "tockmox_policy.yaml"}
if got != need:
    sys.exit(f"policy-gate: the render is missing {sorted(need - got)}")
PY
echo "artifact: config.yaml, tockmox_gate.py and tockmox_policy.yaml extracted from the render"

# --- backends and proxy
: > "$work/local.log"; : > "$work/ext.log"
python3 tests/policy-gate/fake_backend.py 18001 local "$work/local.log" & pids+=($!); LOCAL_PID=$!
python3 tests/policy-gate/fake_backend.py 18002 external "$work/ext.log" & pids+=($!)
export PROXY_MASTER_KEY="$KEY" FRONTIER_KEY=fake-not-a-secret TOCKMOX_POLICY_PATH="$work/cfg/hooks/tockmox_policy.yaml"
( cd "$work/cfg" && exec "$LITELLM_BIN" --config config.yaml --port "$PORT_PROXY" ) > "$work/proxy.log" 2>&1 & pids+=($!)
up=0; for _ in $(seq 1 90); do curl -fs -o /dev/null "http://127.0.0.1:$PORT_PROXY/health/liveliness" && { up=1; break; }; sleep 1; done
[ "$up" = 1 ] || { echo "policy-gate: the proxy never came up"; tail -30 "$work/proxy.log"; exit 1; }
grep -q "hooks.tockmox_gate" "$work/proxy.log" 2>/dev/null || true

req() { curl -s -o "$work/resp" -w '%{http_code}' "http://127.0.0.1:$PORT_PROXY/v1/chat/completions" \
          -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$1"; }
ext() { wc -l < "$work/ext.log" | tr -d ' '; }
audits() { grep -c '"tockmox_audit": 1' "$work/proxy.log" | tr -d ' '; }
last_audit() { grep '"tockmox_audit": 1' "$work/proxy.log" | tail -1; }
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1]))' "$1"; }

# 1
code=$(req '{"model":"local-chat","messages":[{"role":"user","content":"one"}]}'); sleep 1
[ "$code" = 200 ] && grep -q "hello from local" "$work/resp" && ok "1 control: restricted -> local-chat answered by the local backend" \
  || bad "1 control: expected 200 from local, got $code $(head -c 200 "$work/resp")"
[ "$(last_audit | field endpoint_tier)" = local ] && [ "$(last_audit | field class)" = restricted ] \
  && ok "1 control: audit line class=restricted endpoint_tier=local" || bad "1 control: audit line was $(last_audit)"

# 2
e0=$(ext); code=$(req '{"model":"frontier-x","messages":[{"role":"user","content":"two"}]}'); sleep 1
[ "$code" = 200 ] && [ "$(( $(ext) - e0 ))" = 1 ] && ok "2 control: open -> frontier-x reached the external backend once (so zeros below mean something)" \
  || bad "2 control: expected 200 and one external hit, got $code and $(( $(ext) - e0 ))"

# 3
e0=$(ext); a0=$(audits)
code=$(req '{"model":"frontier-x","messages":[{"role":"user","content":"three"}],"metadata":{"tockmox_class":"restricted"}}'); sleep 1
[ "$code" = 403 ] && grep -q "class_forbids_endpoint_tier\|may not use" "$work/resp" && ok "3 tighten: a client-tightened restricted request to an external alias is refused 403" \
  || bad "3 tighten: expected 403, got $code $(head -c 200 "$work/resp")"
[ "$(( $(ext) - e0 ))" = 0 ] && ok "3 tighten: nothing reached the external backend" || bad "3 tighten: the external backend was reached"
[ "$(( $(audits) - a0 ))" = 1 ] && [ "$(last_audit | field status)" = refused ] \
  && ok "3 tighten: exactly one audit line, status refused (no second 'escalate' line from the failure logger)" \
  || bad "3 tighten: expected one refused audit line, got $(( $(audits) - a0 )): $(last_audit)"

# 4 -- the case the claim is about
kill "$LOCAL_PID" 2>/dev/null; wait "$LOCAL_PID" 2>/dev/null; sleep 1
e0=$(ext)
code=$(req '{"model":"local-chat","messages":[{"role":"user","content":"four"}],"fallbacks":["frontier-x"]}'); sleep 2
[ "$code" != 200 ] && ok "4 local down: restricted -> local-chat is a controlled error ($code), not an answer" \
  || bad "4 local down: got 200 with the local backend dead: $(head -c 200 "$work/resp")"
[ "$(( $(ext) - e0 ))" = 0 ] && ok "4 local down: NOTHING reached the external backend, though the client asked for a fallback to it" \
  || bad "4 local down: the external backend was reached $(( $(ext) - e0 )) time(s)"
la="$(last_audit)"
[ "$(printf '%s' "$la" | field status)" = error ] && [ "$(printf '%s' "$la" | field endpoint_tier)" = local ] \
  && printf '%s' "$la" | grep -q '127.0.0.1:18001' && ! printf '%s' "$la" | grep -q '18002' \
  && ok "4 local down: audit line status=error endpoint_tier=local, names the local endpoint and no external one" \
  || bad "4 local down: audit line was $la"
printf '%s' "$la" | grep -q '"stripped": \["fallbacks"\]' -- 2>/dev/null || true

# 5
mv "$TOCKMOX_POLICY_PATH" "$TOCKMOX_POLICY_PATH.away"; a0=$(audits)
code=$(req '{"model":"frontier-x","messages":[{"role":"user","content":"five"}]}'); sleep 1
mv "$TOCKMOX_POLICY_PATH.away" "$TOCKMOX_POLICY_PATH"
[ "$code" = 500 ] && grep -q "failing closed" "$work/resp" && ok "5 policy unreadable: 500, failing closed (even for an alias whose posture is open)" \
  || bad "5 policy unreadable: expected 500 failing closed, got $code $(head -c 200 "$work/resp")"
[ "$(( $(audits) - a0 ))" = 1 ] && [ "$(last_audit | field refusal_reason)" = policy_load_failure ] \
  && ok "5 policy unreadable: exactly one audit line, refusal_reason=policy_load_failure" \
  || bad "5 policy unreadable: expected one policy_load_failure line, got $(( $(audits) - a0 )): $(last_audit)"

echo
if [ "$fail" = 0 ]; then echo "policy-gate: PASSED"; exit 0; fi
echo "policy-gate: FAILED (proxy log tail follows)"; tail -40 "$work/proxy.log"; exit 1

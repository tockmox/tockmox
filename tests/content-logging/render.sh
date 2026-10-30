#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2015  # `ok ... || bad ...`: ok and bad are printf wrappers that return 0, so C runs only when A or B failed
#
# PROMPT CONTENT IN AN OBSERVABILITY CALLBACK (TM-1250), AT RENDER. An otel,
# Langfuse or Arize callback with LiteLLM message logging on copies every
# prompt to its collector; the preflight refuses that unless the site
# acknowledges it with a reason. Each case changes one thing from the CI values.
#
#   tests/content-logging/render.sh       (needs helm)
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
chart="$root/charts/tockmox-ai"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
# the gateway-config hash a render-mode site restates is not in play: ci/values.yaml leaves inferenceNodes.render off
render() { helm template t "$chart" -f "$root/ci/values.yaml" "$@" > /dev/null 2> "$tmp/err"; }
cb() { printf 'litellm:\n  proxy_config:\n    litellm_settings:\n      %s: [%s]\n%s' "$1" "$2" "${3:-}" > "$tmp/v.yaml"; echo "$tmp/v.yaml"; }
refused() { grep -q "registers $1 with message logging on" "$tmp/err"; }

render && ok "0 the CI values render" || bad "0 the CI values: $(grep -o 'execution error.*' "$tmp/err" | head -c 200)"
for c in otel langfuse arize; do
  if render -f "$(cb callbacks "$c")"; then bad "1 $c with message logging on rendered"
  elif refused "$c"; then ok "1 $c with message logging on is refused"
  else bad "1 $c refused for another reason: $(grep -o 'execution error.*' "$tmp/err" | head -c 200)"; fi
done
if render -f "$(cb success_callback langfuse_otel)"; then bad "2 langfuse_otel as a success_callback rendered"
elif refused langfuse_otel; then ok "2 langfuse_otel as a success_callback is refused"; else bad "2 refused for another reason"; fi
render -f "$(cb callbacks otel "      turn_off_message_logging: true
")" && ok "3 otel with turn_off_message_logging: true renders" || bad "3 otel without content was refused: $(grep -o 'execution error.*' "$tmp/err" | head -c 200)"
render -f "$(cb callbacks otel)" --set modelGateway.contentLogging.acknowledged=true --set-string 'modelGateway.contentLogging.reason=self-hosted collector in this namespace' \
  && ok "4 otel with content, acknowledged with a reason, renders" || bad "4 acknowledged otel was refused: $(grep -o 'execution error.*' "$tmp/err" | head -c 200)"
if render -f "$(cb callbacks otel)" --set modelGateway.contentLogging.acknowledged=true; then bad "5 an acknowledgement with no reason rendered"
elif grep -q "contentLogging.reason is empty" "$tmp/err"; then ok "5 an acknowledgement with no reason is refused"; else bad "5 refused for another reason"; fi
render -f "$(cb callbacks prometheus)" && ok "6 a callback that carries no content (prometheus) renders" || bad "6 prometheus was refused"
[ "$fail" = 0 ] && { echo "content logging render: PASSED"; exit 0; }
echo "content logging render: FAILED"; exit 1

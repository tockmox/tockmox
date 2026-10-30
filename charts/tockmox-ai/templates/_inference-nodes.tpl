{{- /*
SPDX-License-Identifier: Apache-2.0

Inference nodes (REQ-0047) and the eval gateway (REQ-0048). Machines that serve models outside the
cluster, a Mac Studio, a DGX Spark, a workstation, are recorded under `inferenceNodes`, and the gateway's
model_list entries for them are DERIVED here rather than written by hand.

THE SAME MAPPING AS THE TOCKMOX UI. The UI renders the same list from the same block (app/nodes.py,
render_model_list) to show an admin what a change will do. files/inference-engines.yaml is generated from
the UI's engine table, and tests/golden/inference-nodes.yaml is the UI's output for
ci/values-inference-nodes.yaml; tools/check-inference-nodes.sh fails when this template drifts from it.

TWO GATEWAYS. A route whose alias ends in `-next` is a candidate (REQ-0048): it goes to the EVAL gateway
only, beside the live route it is compared against. It never reaches the production gateway, because
inside one LiteLLM a key with no model list can call every model the gateway has (measured on 1.100.3,
TM-0936), so a candidate in the production gateway is reachable by any such key.

Call with (dict "root" $ "gateway" "production"|"eval"); returns a YAML list.
*/ -}}
{{- define "tockmox-ai.nodeRoutes" -}}
{{- $root := .root -}}
{{- $gw := .gateway -}}
{{- $in := $root.Values.inferenceNodes | default dict -}}
{{- $engines := $root.Files.Get "files/inference-engines.yaml" | fromYaml -}}
{{- $nodes := dict -}}
{{- range ($in.nodes | default list) -}}
{{- $_ := set $nodes (required "inferenceNodes.nodes[].id is required" .id) . -}}
{{- end -}}
{{- $compared := dict -}}
{{- range ($in.routes | default list) -}}
{{- if hasSuffix "-next" .alias -}}{{- $_ := set $compared (trimSuffix "-next" .alias) true -}}{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $r := ($in.routes | default list) -}}
{{- $isNext := hasSuffix "-next" $r.alias -}}
{{- $take := false -}}
{{- if eq $gw "production" -}}{{- $take = not $isNext -}}
{{- else if eq $gw "eval" -}}{{- $take = or $isNext (hasKey $compared $r.alias) -}}
{{- else -}}{{- fail (printf "tockmox-ai.nodeRoutes: gateway must be production or eval, got %q" $gw) -}}
{{- end -}}
{{- if $take -}}
{{- $node := get $nodes $r.node -}}
{{- if not $node -}}{{- fail (printf "inferenceNodes.routes: route %s names node %q, which is not in inferenceNodes.nodes" $r.alias $r.node) -}}{{- end -}}
{{- $ep := dict -}}
{{- range ($node.endpoints | default list) -}}{{- if eq .id $r.endpoint -}}{{- $ep = . -}}{{- end -}}{{- end -}}
{{- if not $ep -}}{{- fail (printf "inferenceNodes.routes: route %s names endpoint %s/%s, which does not exist" $r.alias $r.node $r.endpoint) -}}{{- end -}}
{{- /* EVERY OLLAMA ROUTE PINS ITS CONTEXT (TM-0957). With no num_ctx, current Ollama sizes the context from the node's
memory (under 24 GiB 4k tokens, 24-48 GiB 32k, 48 GiB or more 256k), and the KV cache for 256k can outweigh the model:
Qwen3-Coder-30B at 262k is a 24 GiB KV cache beside 19 GiB of weights, and a lab route with none reached a 64 GiB node
(2026-10-08). The schema types num_ctx but cannot
require it, because whether a route is Ollama's is known only from the endpoint it names. The UI does not refuse it
(app/nodes.py renders what it is given); this is a check, not a derivation, so the golden still holds. */ -}}
{{- if and (eq $ep.engine "ollama") (not (hasKey ($r.params | default dict) "num_ctx")) -}}
{{- fail (printf "inferenceNodes.routes: route %s on %s/%s sets no params.num_ctx. Ollama then sizes the context from the node's memory (256k tokens at 48 GiB or more), and its KV cache can outgrow the model; set params.num_ctx on the route (and OLLAMA_CONTEXT_LENGTH on the node as a floor), see docs/administration/inference-nodes.md, \"Context length\"" $r.alias $r.node $r.endpoint) -}}
{{- end -}}
{{- $eng := get $engines $ep.engine | default (get $engines "openai-compatible") -}}
{{- $kind := $r.kind | default "chat" -}}
{{- $prov := $r.provider | default (get $eng.provider $kind) -}}
{{- if not $prov -}}{{- fail (printf "inferenceNodes.routes: route %s asks %s for %s, which that engine does not serve through the gateway" $r.alias $ep.engine $kind) -}}{{- end -}}
{{- $base := "" -}}
{{- if not (has $prov (list "ollama" "ollama_chat" "infinity")) -}}{{- $base = get $eng.base_path $kind | default "/v1" -}}{{- end -}}
{{- $lp := dict "model" (printf "%s/%s" $prov $r.model) "api_base" (printf "%s%s" $ep.url $base) -}}
{{- $params := $r.params | default dict -}}
{{- range (list "model" "api_base") -}}{{- if hasKey $params . -}}{{- fail (printf "inferenceNodes.routes: route %s sets params.%s, which is derived from the node and may not be set" $r.alias .) -}}{{- end -}}{{- end -}}
{{- if not (hasKey $params "api_key") -}}
{{- if ($ep.auth | default dict).secretRef -}}
{{- $_ := set $lp "api_key" (printf "os.environ/NODE_KEY_%s" (regexReplaceAll "[^A-Z0-9]" (upper $ep.auth.secretRef) "_")) -}}
{{- else if eq $prov "openai" -}}
{{- /* LiteLLM's openai provider refuses to send a request with no api_key at all ("The api_key client option must be
set"), even to a server that checks none (measured on 1.100.1, TM-0920 lab). A no-auth engine ignores the placeholder.
The UI does the same (app/nodes.py NO_AUTH_KEY). */ -}}
{{- $_ := set $lp "api_key" "no-auth" -}}
{{- end -}}
{{- end -}}
{{- $lp = merge (deepCopy $params) $lp -}}
{{- $info := deepCopy ($r.modelInfo | default dict) -}}
{{- if not (hasKey $info "tockmox_node") -}}{{- $_ := set $info "tockmox_node" $r.node -}}{{- end -}}
{{- if eq $gw "eval" -}}
{{- /* THE EVAL GATEWAY'S DATA-CLASS RAIL (TM-1249). The eval gateway filters by tag, and the runner tags every request
with its eval set's class (public -> open, internal -> internal, confidential and restricted -> restricted). A node
route is local unless it says otherwise and may serve every class; an external route may serve open only. The UI
applies the same defaults and the same refusal (app/nodes.py render_model_list). */ -}}
{{- $tier := $info.endpoint_tier | default "local" -}}
{{- if not (has $tier (list "local" "external")) -}}{{- fail (printf "inferenceNodes.routes: route %s has model_info.endpoint_tier %q; it must be local or external" $r.alias $tier) -}}{{- end -}}
{{- $_ := set $info "endpoint_tier" $tier -}}
{{- if not (hasKey $lp "tags") -}}{{- $_ := set $lp "tags" (ternary (list "restricted" "internal" "open") (list "open") (eq $tier "local")) -}}{{- end -}}
{{- if and (eq $tier "external") (without $lp.tags "open") -}}{{- fail (printf "inferenceNodes.routes: route %s is external but its tags %s let the eval gateway send it data above public; an external route may carry only the tag open (TM-1249)" $r.alias (toJson $lp.tags)) -}}{{- end -}}
{{- end -}}
{{- $out = append $out (dict "model_name" $r.alias "litellm_params" $lp "model_info" $info) -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{- /*
Hosted models admitted for evaluation (REQ-0048): catalog entries at stage `candidate` whose source is a
hosted provider. They go to the eval gateway only, tagged `open` alone (TM-1249): the eval gateway filters by tag,
so only public eval data reaches them. Production tags are chosen when one is promoted, and a promoted hosted model
is an entry in the production gateway's own model_list.
*/ -}}
{{- define "tockmox-ai.hostedCandidates" -}}
{{- $lc := .Values.modelLifecycle | default dict -}}
{{- $providers := (($lc.frontier | default dict).providers) | default dict -}}
{{- $out := list -}}
{{- range ($lc.catalog | default list) -}}
{{- if and (eq (.stage | default "promoted") "candidate") (eq (.source | default dict).kind "hosted") -}}
{{- $parts := splitn "/" 2 .source.ref -}}
{{- $provider := $parts._0 -}}
{{- $mid := $parts._1 | default "" -}}
{{- if not $mid -}}{{- fail (printf "modelLifecycle.catalog: hosted candidate %s needs source.ref provider/model" .id) -}}{{- end -}}
{{- $keyEnv := ((get $providers $provider) | default dict).keyEnv | default (printf "%s_API_KEY" (upper $provider)) -}}
{{- $out = append $out (dict "model_name" $mid "litellm_params" (dict "model" .source.ref "api_key" (printf "os.environ/%s" $keyEnv) "tags" (list "open")) "model_info" (dict "endpoint_tier" "external" "tockmox_catalog" .id)) -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

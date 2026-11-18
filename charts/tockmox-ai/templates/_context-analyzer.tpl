{{- /*
SPDX-License-Identifier: Apache-2.0

THE CONTEXT ANALYZER's helpers (ADR-0040). templates/context-analyzer.yaml
renders the service; tockmox.ai.hookFiles adds the hook to the gateway's hooks
ConfigMap; preflight.yaml refuses a configuration that would load nothing.
*/ -}}

{{- define "tockmox.ai.ctxaOn" -}}
{{- include "tockmox.appEnabled" (dict "ctx" . "app" "contextAnalyzer") -}}
{{- end -}}

{{- /* The callback the site registers, and the Service the hook reports to. */ -}}
{{- define "tockmox.ai.ctxaCallback" -}}hooks.tockmox_context_analyzer.analyzer_hook{{- end -}}
{{- define "tockmox.ai.ctxaName" -}}tockmox-context-analyzer{{- end -}}

{{- /*
The six files from the Context Analyzer source, file name to text. The site's
contextAnalyzer.source wins; a file the chart carries under
files/context-analyzer/ fills a name the site left unset. A missing file is an
empty string here and a sentence in preflight.
*/ -}}
{{- define "tockmox.ai.ctxaSourceNames" -}}
- compat.py
- segmentation.py
- actuation.py
- hooks.py
- prometheus-alerts.yaml
- context-analyzer-dashboard.json
{{- end -}}

{{- define "tockmox.ai.ctxaSource" -}}
{{- $site := ((.Values.contextAnalyzer | default dict).source) | default dict -}}
{{- $out := dict -}}
{{- range (include "tockmox.ai.ctxaSourceNames" . | fromYamlArray) -}}
{{- $_ := set $out . (index $site . | default ($.Files.Get (printf "files/context-analyzer/%s" .)) | default "") -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{- /*
What the hook is told, as environment defaults (the gateway's own environment
wins). Tockmox mode and the class source are set together or not at all: with
the policy gate on, the gate stamps each request's class and the hook fails
closed without one; with it off, Tockmox mode would capture nothing.
*/ -}}
{{- define "tockmox.ai.ctxaSettings" -}}
{{- $ca := .Values.contextAnalyzer | default dict -}}
{{- $env := dict "CTXA_SINK_URL" (printf "http://%s.%s.svc:8000" (include "tockmox.ai.ctxaName" .) .Release.Namespace) -}}
{{- with $ca.gatewayId }}{{- $_ := set $env "CTXA_GATEWAY_ID" . -}}{{- end -}}
{{- if include "tockmox.ai.policyGateOn" . -}}
{{- $_ := set $env "CTXA_TOCKMOX_MODE" "1" -}}
{{- $_ := set $env "CTXA_POLICY_HOOK" "TockmoxPolicyGate" -}}
{{- $_ := set $env "CTXA_CLASSIFICATION_PATH" "tockmox.class" -}}
{{- end -}}
{{- dict "env" $env | toPrettyJson -}}
{{- end -}}

{{- /* The hook's files in the hooks ConfigMap: the loader, its settings and the four modules. */ -}}
{{- define "tockmox.ai.ctxaHookFiles" -}}
{{- $src := include "tockmox.ai.ctxaSource" . | fromYaml -}}
{{- $files := dict "tockmox_context_analyzer.py" (.Files.Get "files/context-analyzer-hook/tockmox_context_analyzer.py") "tockmox_context_analyzer.json" (include "tockmox.ai.ctxaSettings" .) -}}
{{- range (list "compat" "segmentation" "actuation" "hooks") -}}
{{- $_ := set $files (printf "tockmox_context_analyzer_%s.py" .) (index $src (printf "%s.py" .)) -}}
{{- end -}}
{{- toYaml $files -}}
{{- end -}}

{{- /*
SPDX-License-Identifier: Apache-2.0

THE POLICY GATE (TM-0383), as files for the hooks ConfigMap.

tockmox.ai.hookFiles returns, as YAML, every file the tockmox-litellm-hooks
ConfigMap carries: the site's modelGateway.hooks.files, plus the gate's module
and its policy when modelGateway.policyGate.enabled is true. litellm-hooks.yaml
renders it and preflight.yaml checks registrations against it, so the two can
never disagree about what is in the mount.

The policy file is rendered from values rather than shipped as a file, so a
site changes policy in its values and never in code. Its keys are the ones the
module reads (snake_case, the shape the reference site has run since
2026-06-05).
*/ -}}
{{- define "tockmox.ai.policyGateOn" -}}
{{- if ((.Values.modelGateway | default dict).policyGate | default dict).enabled }}true{{- end -}}
{{- end -}}

{{- define "tockmox.ai.policyGatePolicy" -}}
{{- $pg := .Values.modelGateway.policyGate -}}
audit_schema: v0
policy_id: {{ $pg.policyId | quote }}
enforcement: {{ $pg.enforcement | quote }}
platform_mode: {{ $pg.platformMode | quote }}
default_class: {{ $pg.defaultClass | quote }}
classes:
{{- range $cls := list "open" "internal" "restricted" }}
  {{ $cls }}:
    allowed_tiers: {{ index $pg.classes $cls | toJson }}
{{- end }}
route_posture:
{{- if $pg.routePosture }}
{{ toYaml $pg.routePosture | indent 2 }}
{{- else }} {}
{{- end }}
{{- end -}}

{{- /*
THE KEY POLICY (TM-0991; DESIGN-2026-10-29-agent-kit-security K1, K2). On LiteLLM a key whose model list is empty,
absent, `*` or `all-proxy-models` reaches every model, and a key with no MCP list reaches every MCP server. The
module refuses both on every key generate, update and regenerate (general_settings.custom_key_policy). Its policy
file is rendered from values. The console key's alias is added to the one named exception automatically, because
the console is meant to see every production model and its key job names no list.
*/ -}}
{{- define "tockmox.ai.keyPolicyOn" -}}
{{- if and (((.Values.modelGateway | default dict).keyPolicy | default dict).enabled) (include "tockmox.appEnabled" (dict "ctx" . "app" "litellm")) }}true{{- end -}}
{{- end -}}

{{- define "tockmox.ai.keyPolicyPolicy" -}}
{{- $kp := .Values.modelGateway.keyPolicy -}}
{{- $aliases := $kp.allowAllModelsAliases | default list -}}
{{- if include "tockmox-ai.consoleKeyOn" . -}}
{{- $aliases = append $aliases ((.Values.modelGateway.consoleKey | default dict).alias | default "open-webui") -}}
{{- end -}}
allow_all_models_aliases: {{ $aliases | uniq | toJson }}
refuse_suffixes: {{ $kp.refuseSuffixes | default list | toJson }}
require_mcp: {{ ternary "true" "false" (ne (toString $kp.requireMcp) "false") }}
{{- end -}}

{{- define "tockmox.ai.hookFiles" -}}
{{- $files := deepCopy (((.Values.modelGateway | default dict).hooks | default dict).files | default dict) -}}
{{- if include "tockmox.ai.policyGateOn" . -}}
{{- range (list "tockmox_gate.py" "tockmox_policy.yaml") -}}
{{- if hasKey $files . -}}
{{- fail (printf "modelGateway.hooks.files has a file named %q, and so does the policy gate (modelGateway.policyGate.enabled). Both land in the same ConfigMap and only one can win; rename your file." .) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $files "tockmox_gate.py" ($.Files.Get "files/policy-gate/tockmox_gate.py") -}}
{{- $_ := set $files "tockmox_policy.yaml" (include "tockmox.ai.policyGatePolicy" $) -}}
{{- end -}}
{{- if include "tockmox.ai.keyPolicyOn" . -}}
{{- range (list "tockmox_key_policy.py" "tockmox_key_policy.yaml") -}}
{{- if hasKey $files . -}}
{{- fail (printf "modelGateway.hooks.files has a file named %q, and so does the key policy (modelGateway.keyPolicy.enabled). Both land in the same ConfigMap and only one can win; rename your file." .) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $files "tockmox_key_policy.py" ($.Files.Get "files/key-policy/tockmox_key_policy.py") -}}
{{- $_ := set $files "tockmox_key_policy.yaml" (include "tockmox.ai.keyPolicyPolicy" $) -}}
{{- end -}}
{{- toYaml $files -}}
{{- end -}}

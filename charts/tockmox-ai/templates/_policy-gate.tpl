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
{{- toYaml $files -}}
{{- end -}}

{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
CAPABILITIES: functional stories you can decline.

WHY THIS EXISTS. `apps.*.enabled` is a switch per piece of software, and that is
the wrong unit for the decision people actually make. Nobody wants "a Garage",
"a barman plugin" and "a snapshot controller". They want their data protected,
or they already have Velero and want none of it, or they are running a lab and
do not care yet. Three switches make that one decision three times, in three
places, with no name for the thing being chosen.

So a capability is a NAMED functional story spanning whatever components it
takes, on one switch, declinable as a unit.

THE RESOLUTION RULE, and the reason it is a helper rather than an `and`:

  apps.<x>.enabled: null   inherit the capability that owns this component
  apps.<x>.enabled: true   on, whatever the capability says
  apps.<x>.enabled: false  off, whatever the capability says

Null is the default in the shipped values, so a site that never mentions a
component follows the capability, and a site that names one means it. An `and`
between the two flags cannot express that: it makes declining a capability
override a deliberate opt-in, which is backwards.

WHAT A CAPABILITY IS NOT. It is not a layer, and it is not a chart. Layers are
about install order and blast radius; capabilities are about what a deployment
DOES. One capability can span layers, which is exactly why the switch cannot
live in any single chart's `apps` block.

Expects a dict:
  ctx        the chart context
  capability the capability name under `.Values.capabilities`
  app        the key under `.Values.apps`, or "" for a component with no
             individual override
  override   an already-resolved override value, for the components whose switch
             does not live under `apps`. `notifications.enabled` is the one that
             matters: it predates this framework and is a contract key, so it
             cannot be moved without a major version. Passing it here gives it
             the same tri-state as everything else instead of an `and`, which
             would have made declining the capability beat a deliberate opt-in.
             Pass at most one of `app` and `override`.
*/}}
{{- define "tockmox.capabilityEnabled" -}}
{{- $caps := .ctx.Values.capabilities | default dict -}}
{{- $cap := index $caps .capability | default dict -}}
{{- $capOn := $cap.enabled -}}
{{- if eq (kindOf $capOn) "invalid" -}}{{- $capOn = true -}}{{- end -}}
{{- $result := $capOn -}}
{{- if .app -}}
  {{- $apps := .ctx.Values.apps | default dict -}}
  {{- $entry := index $apps .app | default dict -}}
  {{- $override := $entry.enabled -}}
  {{- if ne (kindOf $override) "invalid" -}}
    {{- $result = $override -}}
  {{- end -}}
{{- else if ne (kindOf .override) "invalid" -}}
  {{- $result = .override -}}
{{- end -}}
{{- if $result -}}true{{- end -}}
{{- end -}}

{{/*
Fails the render when a capability is on but something it NEEDS is off.

The distinction from capabilityCoherent is worth stating, because the two
guards look similar and catch opposite mistakes. Coherent catches a component
switched on under a capability that is off ... a part with no whole. This one
catches a whole with no floor under it: hardware exporters with nothing
scraping them, an alert rule with no Prometheus to evaluate it. Both produce
objects that apply cleanly and do nothing, which is the failure mode this
repo keeps finding in itself.

`satisfiedBy` is a list of capability names, ANY of which is enough, plus an
optional list of `apps` keys that also satisfy it. The "I run my own Prometheus"
case is exactly why: `apps.serviceMonitors.enabled: true` means something DOES
scrape the exporters, so requiring the observability capability outright would
reject a configuration that works.

Expects a dict:
  ctx         the chart context
  capability  the capability doing the requiring
  satisfiedBy list of capability names, any one of which satisfies it
  apps        list of `apps` keys whose being explicitly true also satisfies it
  because     the sentence explaining what breaks, without the trailing fix
*/}}
{{- define "tockmox.capabilityRequires" -}}
{{- $ctx := .ctx -}}
{{- if include "tockmox.capabilityEnabled" (dict "ctx" $ctx "capability" .capability) -}}
  {{- $met := false -}}
  {{- range $c := .satisfiedBy -}}
    {{- if include "tockmox.capabilityEnabled" (dict "ctx" $ctx "capability" $c) -}}
      {{- $met = true -}}
    {{- end -}}
  {{- end -}}
  {{- $appsv := $ctx.Values.apps | default dict -}}
  {{- range $k := (.apps | default list) -}}
    {{- $entry := index $appsv $k | default dict -}}
    {{- if eq $entry.enabled true -}}{{- $met = true -}}{{- end -}}
  {{- end -}}
  {{- if not $met -}}
    {{- $fixes := list -}}
    {{- range $c := .satisfiedBy -}}
      {{- $fixes = append $fixes (printf "capabilities.%s.enabled: true" $c) -}}
    {{- end -}}
    {{- range $k := (.apps | default list) -}}
      {{- $fixes = append $fixes (printf "apps.%s.enabled: true" $k) -}}
    {{- end -}}
    {{- fail (printf "capabilities.%s is on, but %s Set one of: %s. Or turn capabilities.%s off, which is the right answer if you did not want it." .capability .because (join ", " $fixes) .capability) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Fails the render when a component is switched on individually while the
capability that owns it is off. That combination is almost always a mistake and
it produces a half-built story: the object store without the plugin that writes
to it, the drill without the store to restore from.

It is deliberately a failure rather than a silent promotion, because promoting
would mean a capability people declined coming back on because of one key.
*/}}
{{- define "tockmox.capabilityCoherent" -}}
{{- $caps := .ctx.Values.capabilities | default dict -}}
{{- $cap := index $caps .capability | default dict -}}
{{- $capOn := $cap.enabled -}}
{{- if eq (kindOf $capOn) "invalid" -}}{{- $capOn = true -}}{{- end -}}
{{- if not $capOn -}}
  {{- $apps := .ctx.Values.apps | default dict -}}
  {{- range $k := .apps -}}
    {{- $entry := index $apps $k | default dict -}}
    {{- if eq $entry.enabled true -}}
      {{- fail (printf "apps.%s.enabled is true but the %s capability is off. That leaves a component running with nothing around it to make it useful, which is worse than either choice made cleanly. Turn capabilities.%s.enabled on, or leave apps.%s.enabled unset so it follows the capability." $k $.capability $.capability $k) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
THE OWNERSHIP MAP. One place, read by everything.

It lives here rather than being spelled out at each call site because the
alternative was measured and it failed: making component defaults absent so the
capability could own them turned twenty-one `.Values.apps.<x>.enabled` reads
into nil, which is falsy. Every ingress, SSO Secret, brand ConfigMap and
blueprint for a capability-owned component silently stopped rendering, and the
charts still linted, still templated and still installed. Nothing said less.

So: nothing reads `.Values.apps.<x>.enabled` for an owned component directly.
Call `tockmox.appEnabled` and it resolves the tri-state through this map.
Components absent from the map are core, and resolve to their own key.

tools/check-capabilities.sh asserts its own manifest matches this map, so the
gate and the charts cannot drift into disagreeing about who owns what.
*/}}
{{- define "tockmox.capabilityOwners" -}}
kubePrometheusStack: observability
loki: observability
alloy: observability
blackbox: observability
prometheusOperatorCrds: observability
serviceMonitors: observability
dashboards: observability
argocdMonitoring: observability
authentik: identity
openWebui: aiPlane
litellm: aiPlane
garage: dataProtection
docs: dataProtection
barmanPlugin: dataProtection
snapshotController: dataProtection
snmp: hardwareTelemetry
smartctl: hardwareTelemetry
argoWorkflows: workflowAutomation
ai_namespace: networkPolicy
ai_cnpg_netpol: networkPolicy
ai_openwebui_egress: networkPolicy
authentik_netpol: networkPolicy
devops_netpol: networkPolicy
forgejo_netpol: networkPolicy
harbor_netpol: networkPolicy
monitoring_netpol: networkPolicy
platform_netpol: networkPolicy
selfcheck_netpol: networkPolicy
syslog_ingest_netpol: networkPolicy
tailscale_netpol: networkPolicy
{{- end -}}

{{/*
Resolves ONE app key to a boolean-ish string, through its capability if it has
one. Returns "true" or "". Use this everywhere instead of reading the key.

  {{- if include "tockmox.appEnabled" (dict "ctx" $ "app" "authentik") }}

Takes a dict: ctx, app.
*/}}
{{- define "tockmox.appEnabled" -}}
{{- $owners := fromYaml (include "tockmox.capabilityOwners" .) -}}
{{- $cap := index $owners .app -}}
{{- if $cap -}}
  {{- include "tockmox.capabilityEnabled" (dict "ctx" .ctx "capability" $cap "app" .app) -}}
{{- else -}}
  {{- $entry := index (.ctx.Values.apps | default dict) .app | default dict -}}
  {{- if $entry.enabled -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The resolved list, for NOTES.txt. Ranging over `.Values.apps` and testing
`$v.enabled` under-reports every component that follows a capability, and
crashes outright on a key someone set to null ... which one layer's values file
can do to all nine, because the values namespace is shared.
*/}}
{{- define "tockmox.enabledApps" -}}
{{- $ctx := . -}}
{{- $out := list -}}
{{- range $k, $v := (.Values.apps | default dict) -}}
  {{- if include "tockmox.appEnabled" (dict "ctx" $ctx "app" $k) -}}
    {{- $out = append $out $k -}}
  {{- end -}}
{{- end -}}
{{- join " " (sortAlpha $out) -}}
{{- end -}}

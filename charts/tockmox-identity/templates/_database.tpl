{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
THE IDENTITY DATABASE, the questions every template here asks about it
(TM-0788). One answer each, so the Cluster, the bridge, the drill and the
upgrade guard cannot disagree about which database Authentik is on.
*/}}

{{/*
Whether the CNPG cluster under identity.database renders. Returns "true" or "".
Off whenever Authentik itself is off: there is nothing to give a database to.
*/}}
{{- define "tockmox-identity.cnpgOn" -}}
{{- if and (include "tockmox.appEnabled" (dict "ctx" . "app" "authentik")) (((.Values.identity | default dict).database | default dict).enabled) -}}true{{- end -}}
{{- end -}}

{{/*
Whether the vendored authentik chart's bundled (Bitnami) server renders.
Returns "true" or "". Read the way Helm reads the subchart's condition
(`postgresql.enabled` inside the authentik chart, so `authentik.postgresql.
enabled` here), and off whenever Authentik is off, because the subchart that
owns it does not render at all then.
*/}}
{{- define "tockmox-identity.bundledOn" -}}
{{- $pg := ((.Values.authentik | default dict).postgresql | default dict) -}}
{{- if and (include "tockmox.appEnabled" (dict "ctx" . "app" "authentik")) (eq (toString $pg.enabled) "true") -}}true{{- end -}}
{{- end -}}

{{/*
The host Authentik will dial, evaluated the way the vendored chart evaluates
it: `authentik.authentik.postgresql.host` run through `tpl` against the
SUBCHART's values (where `.Values.postgresql.enabled` is the bundled server's
switch) and this release. The guards compare THIS, never the raw string, so a
literal host and the shipped template are judged by what reaches the pod.
*/}}
{{- define "tockmox-identity.dbHost" -}}
{{- $ak := .Values.authentik | default dict -}}
{{- $raw := (($ak.authentik | default dict).postgresql | default dict).host | default "{{ .Release.Name }}-postgresql" -}}
{{- $sub := dict "Values" (dict "postgresql" (dict "enabled" (eq (include "tockmox-identity.bundledOn" .) "true"))) "Release" .Release "Chart" (dict "Name" "authentik") "Template" .Template -}}
{{- tpl (toString $raw) $sub -}}
{{- end -}}

{{/*
Whether the identity database backs up: the house tri-state, resolved by the
helper every capability-owned component uses. Returns "true" or "".
  null   follow capabilities.dataProtection (the shipped default, which is on)
  true   on, whatever the capability says
  false  off, whatever the capability says
Every template asks THIS helper; a bare `if` on a null is silently falsy.
*/}}
{{- define "tockmox-identity.dbBackupEnabled" -}}
{{- include "tockmox.capabilityEnabled" (dict "ctx" . "capability" "dataProtection" "override" .Values.identity.database.backup.enabled) -}}
{{- end -}}

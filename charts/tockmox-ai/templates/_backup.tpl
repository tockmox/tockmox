{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
Whether the model gateway's database backs up (TM-0312). Returns "true" or "".

`modelGateway.database.backup.enabled` is the house tri-state, resolved by the
same helper every capability-owned component uses:

  null   follow capabilities.dataProtection (the shipped default, which is on)
  true   on, whatever the capability says
  false  off, whatever the capability says

It used to be a plain `false`, so a stock install with the gateway enabled had
a database nothing backed up and nothing said so. Every template in this chart
asks THIS helper; none reads the key directly, because a bare `{{ if
.Values...backup.enabled }}` on a null is silently falsy, which is the exact
failure the capability framework's ownership map was written to stop.
*/}}
{{- define "tockmox-ai.dbBackupEnabled" -}}
{{- include "tockmox.capabilityEnabled" (dict "ctx" . "capability" "dataProtection" "override" .Values.modelGateway.database.backup.enabled) -}}
{{- end -}}

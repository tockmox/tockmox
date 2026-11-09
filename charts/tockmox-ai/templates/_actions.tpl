{{- /*
SPDX-License-Identifier: Apache-2.0

tockmox.actions: the effective actions block, as YAML, for both the UI's config (which buttons it
offers) and the tockmox-actions service's (what it will do). One computation, two readers, so the two cannot disagree.

On by default for every kind this layer can do with what Tockmox ships (R10, Jeff 2026-10-31): silences and the test
alert (Alertmanager, by NetworkPolicy), run-now of the AI layer's own CronJobs, a restart of the AI layer's consoles.
argocd needs the site's Argo CD account and is on only when its url and tokenSecret are set. identity needs
the Authentik service account the identity layer makes with sso.consoleActions, and a token Secret both layers share,
so it is off until turned on. Off means absent.
Nothing renders without the UI, its issuer (every intent is checked against the issuer's signature) and the
Alertmanager-reading observability capability for the Alertmanager kinds.
*/ -}}
{{- define "tockmox.actions" -}}
{{- $ui := .Values.tockmoxUi | default dict -}}
{{- $a := $ui.actions | default dict -}}
{{- $aiNs := (.Values.namespaces | default dict).ai | default "tockmox-ai" -}}
{{- $issuer := ((($ui.config | default dict).oidc | default dict).issuer) | default "" -}}
{{- $obs := include "tockmox.capabilityEnabled" (dict "ctx" . "capability" "observability") -}}
{{- $out := dict -}}
{{- if and $ui.enabled $issuer -}}
{{- $sil := and (ne $obs "") ((($a.silence | default dict).enabled) | default false) -}}
{{- $test := and (ne $obs "") ((($a.testAlert | default dict).enabled) | default false) -}}
{{- $rj := $a.runJob | default dict -}}
{{- $jobs := list
      (dict "namespace" $aiNs "name" "tockmox-litellm-db-drill" "part" "restore-drills")
      (dict "namespace" $aiNs "name" "tockmox-model-watch" "part" "model-gateway")
      (dict "namespace" $aiNs "name" "tockmox-health-watch" "part" "model-gateway")
      (dict "namespace" $aiNs "name" "tockmox-eval-scheduler" "part" "model-gateway")
      (dict "namespace" $aiNs "name" "tockmox-console-key-check" "part" "self-check") -}}
{{- $ch := $a.changes | default dict -}}
{{- /* On by default where the site's forge is the built-in one (global.siteForge, which tockmox-install.sh writes
       into global.yaml), off elsewhere; an explicit true or false in the site's values wins either way. */ -}}
{{- $chOn := eq (((.Values.global | default dict).siteForge) | default "") "built-in" -}}
{{- if and (hasKey $ch "enabled") (not (kindIs "invalid" $ch.enabled)) -}}{{- $chOn = $ch.enabled -}}{{- end -}}
{{- /* With the change kinds on, Site history's Copy now and Check the drill now: the built-in forge's own two
       CronJobs (bootstrap-forge makes them), on the Site repository part. */ -}}
{{- if $chOn -}}
{{- $fRel := $ch.forgeRelease | default "tockmox-forge" -}}{{- $fNs := $ch.forgeNamespace | default "tockmox-forge" -}}
{{- $jobs = append $jobs (dict "namespace" $fNs "name" (printf "%s-offsite" $fRel) "part" "site-repository") -}}
{{- $jobs = append $jobs (dict "namespace" $fNs "name" (printf "%s-drill-check" $fRel) "part" "site-repository") -}}
{{- end -}}
{{- $jobs = concat $jobs ($rj.allow | default list) -}}
{{- $rs := $a.restart | default dict -}}
{{- $wl := list
      (dict "namespace" $aiNs "kind" "Deployment" "name" (printf "%s-litellm" .Release.Name) "part" "model-gateway")
      (dict "namespace" $aiNs "kind" "StatefulSet" "name" (printf "%s-open-webui" .Release.Name) "part" "chat-console")
      (dict "namespace" $aiNs "kind" "Deployment" "name" "tockmox-ui" "part" "tockmox-ui") -}}
{{- $wl = concat $wl ($rs.allow | default list) -}}
{{- $ar := $a.argocd | default dict -}}
{{- if and $ar.enabled (or (not $ar.url) (not $ar.tokenSecret)) -}}
{{- fail "tockmoxUi.actions.argocd.enabled needs argocd.url (the Argo CD API, e.g. http://argocd-server.argocd.svc) and argocd.tokenSecret (a Secret, key token, for an Argo CD local account allowed get and sync on applications only): docs/administration/tockmox-ui.md, \"Taking action\"" -}}
{{- end -}}
{{- $_ := set $out "silence" (dict "enabled" $sil) -}}
{{- $_ := set $out "testAlert" (dict "enabled" $test) -}}
{{- $_ := set $out "runJob" (dict "enabled" (($rj.enabled) | default false) "allow" $jobs) -}}
{{- $_ := set $out "restart" (dict "enabled" (($rs.enabled) | default false) "allow" $wl) -}}
{{- $_ := set $out "argocd" (dict "enabled" (($ar.enabled) | default false) "url" ($ar.url | default "")) -}}
{{- $id := $a.identity | default dict -}}
{{- $_ := set $out "identity" (dict "enabled" (($id.enabled) | default false) "apiUrl" ($id.apiUrl | default "") "recoveryGroups" ($id.recoveryGroups | default list) "userGroup" (((.Values.sso | default dict).userGroup) | default "tockmox-users")) -}}
{{- /* changes: the UI reads only the switch; the forge's addresses, the bot's token and the OAuth2 client are
       the service's alone (templates/tockmox-actions.yaml), and the UI asks the service for the sign-in URL. */ -}}
{{- $_ := set $out "changes" (dict "enabled" $chOn) -}}
{{- /* moveForge: Status > Site repository > Move to my own forge. It starts bootstrap-forge's suspended
       <release>-move Job, and its change is approved in Platform > Changes, so it is on only with the change kinds;
       an explicit false turns it off. image is the one the admission policy admits, so it must equal what
       bootstrap-forge installs (MOVE_IMAGE_DEFAULT; global.imageRegistry prefixes both). */ -}}
{{- $mf := $a.moveForge | default dict -}}
{{- $mfOn := $chOn -}}
{{- if and (hasKey $mf "enabled") (not (kindIs "invalid" $mf.enabled)) -}}{{- $mfOn = and $chOn $mf.enabled -}}{{- end -}}
{{- $mfImage := include "tockmox.image" (dict "ctx" . "repo" (($a.moveForge | default dict).image | default "alpine/k8s:1.37.2")) -}}
{{- $_ := set $out "moveForge" (dict "enabled" $mfOn "image" $mfImage) -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{- /* "true" when any kind is on: the service, its RBAC and the UI's egress to it render only then. */ -}}
{{- define "tockmox.actionsOn" -}}
{{- $a := include "tockmox.actions" . | fromYaml -}}
{{- range $k, $v := $a -}}{{- if $v.enabled -}}true{{- end -}}{{- end -}}
{{- end -}}

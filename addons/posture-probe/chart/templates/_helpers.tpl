{{- /*
SPDX-License-Identifier: Apache-2.0

pp.model: everything the templates share, computed once and checked once. Returned
as JSON (include + fromJson). Every refusal is here, so a bad values file fails the
render with a sentence rather than producing a probe that can only ever say
"could not run".
*/ -}}
{{- define "pp.labels" -}}
app.kubernetes.io/part-of: posture-probe
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "pp.model" -}}
{{- $v := .Values -}}
{{- if not $v.image -}}
{{- fail "posture-probe: enabled is true but image is empty. Tockmox publishes no image: build addons/posture-probe/Dockerfile, push it to your registry, and name it in image." -}}
{{- end -}}
{{- $nss := $v.namespaces | default list -}}
{{- if has .Release.Namespace $nss -}}
{{- fail (printf "posture-probe: the release namespace %s is also a measured namespace. Install the add-on into its own namespace: its NetworkPolicy would otherwise change what it measures." .Release.Namespace) -}}
{{- end -}}
{{- $t := $v.targets | default dict -}}
{{- $port := int ($t.standinPort | default 8080) -}}
{{- $standin := dict "app.kubernetes.io/name" "posture-standin" "app.kubernetes.io/part-of" "posture-probe" -}}
{{- $targets := dict -}}
{{- range $nss -}}
{{- $_ := set $targets . (dict "host" (printf "posture-standin.%s.svc.cluster.local" .) "port" $port "namespace" . "labels" $standin "portName" "http" "listener" (($v.standins | default dict).enabled | default false) "dimension" "ns-to-ns") -}}
{{- end -}}
{{- $inet := $t.internet | default dict -}}
{{- if $inet.host -}}
{{- $it := dict "host" $inet.host "port" (int ($inet.port | default 443)) "listener" true "dimension" "egress" -}}
{{- if regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$" $inet.host -}}
{{- $_ := set $it "policyIp" $inet.host -}}
{{- else -}}
{{- $_ := set $it "evaluate" false -}}
{{- $_ := set $it "why" "targets.internet.host is a name, and a NetworkPolicy matches addresses" -}}
{{- end -}}
{{- $_ := set $targets "internet" $it -}}
{{- end -}}
{{- /* The API server. Its config column needs the address a NetworkPolicy sees after DNAT; never guess it. */ -}}
{{- $api := $v.networkPolicy.apiServer | default list -}}
{{- if and (not $api) (($v.global | default dict).lanCIDR) -}}
{{- $api = list (dict "cidr" $v.global.lanCIDR "port" 6443) -}}
{{- end -}}
{{- $ka := $t.kubeApi | default dict -}}
{{- if $ka.host -}}
{{- $pip := $ka.policyIp | default "" -}}
{{- $pport := int ($ka.policyPort | default 6443) -}}
{{- if and (not $pip) (eq (len $api) 1) (hasSuffix "/32" (index $api 0).cidr) -}}
{{- $pip = trimSuffix "/32" (index $api 0).cidr -}}
{{- $pport = int ((index $api 0).port | default 6443) -}}
{{- end -}}
{{- $k := dict "host" $ka.host "port" (int ($ka.port | default 443)) "listener" true "dimension" "api-egress" -}}
{{- if $pip -}}
{{- $_ := set $k "policyIp" $pip -}}
{{- $_ := set $k "policyPort" $pport -}}
{{- else -}}
{{- $_ := set $k "evaluate" false -}}
{{- $_ := set $k "why" "targets.kubeApi.policyIp is not set and networkPolicy.apiServer is not a single /32" -}}
{{- end -}}
{{- $_ := set $targets "kube-api" $k -}}
{{- end -}}
{{- /*
Intent rows: the preset, then the site's own. A PRESET row that names a namespace,
target or identity this release does not measure is dropped, and counted: a site
that declined a capability has no tockmox-ai, and the preset must not make it
write rows away. A row the SITE wrote is held to it and fails the render.
*/ -}}
{{- $vant := dict -}}
{{- range $v.identityVantages | default list -}}
{{- if not (has .namespace $nss) -}}
{{- fail (printf "posture-probe: identityVantages names %s/%s, but %s is not in namespaces." .namespace .serviceAccount .namespace) -}}
{{- end -}}
{{- $_ := set $vant (printf "%s:%s" .namespace .serviceAccount) true -}}
{{- end -}}
{{- $cand := list -}}
{{- $preset := ($v.intent | default dict).preset | default "tockmox-reference" -}}
{{- if eq $preset "tockmox-reference" -}}
{{- range (.Files.Get "files/intent-tockmox-reference.json" | fromJson).intents -}}
{{- $cand = append $cand (dict "row" . "own" false) -}}
{{- end -}}
{{- end -}}
{{- range (($v.intent | default dict).rows | default list) -}}
{{- $cand = append $cand (dict "row" . "own" true) -}}
{{- end -}}
{{- $rows := list -}}
{{- $dropped := 0 -}}
{{- range $cand -}}
{{- $r := .row -}}
{{- $why := "" -}}
{{- if hasPrefix "rbac:" $r.dimension -}}
{{- if not (hasKey $vant $r.subject) -}}
{{- $why = printf "intent row %q / %q names identity %s, which no identityVantages entry measures." $r.subject $r.dimension $r.subject -}}
{{- end -}}
{{- else -}}
{{- $parts := splitList "->" $r.subject -}}
{{- if ne (len $parts) 2 -}}
{{- fail (printf "posture-probe: intent row subject %q is not SOURCE->TARGET." $r.subject) -}}
{{- end -}}
{{- if not (has (index $parts 0) $nss) -}}
{{- $why = printf "intent row %q measures from %s, which is not in namespaces." $r.subject (index $parts 0) -}}
{{- else if not (hasKey $targets (index $parts 1)) -}}
{{- $why = printf "intent row %q names target %s, which this release does not declare (namespaces, internet, kube-api)." $r.subject (index $parts 1) -}}
{{- else -}}
{{- $tdim := (get $targets (index $parts 1)).dimension -}}
{{- if ne $r.dimension $tdim -}}
{{- fail (printf "posture-probe: intent row %q has dimension %q, but its target is measured as %q; the row could never be observed." $r.subject $r.dimension $tdim) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $why -}}
{{- $rows = append $rows $r -}}
{{- else if .own -}}
{{- fail (printf "posture-probe: %s" $why) -}}
{{- else -}}
{{- $dropped = add1 $dropped -}}
{{- end -}}
{{- end -}}
{{- if not $rows -}}
{{- fail "posture-probe: no intent rows left to measure. Use intent.preset: tockmox-reference with its namespaces, or declare intent.rows." -}}
{{- end -}}
{{- /* Settling controls per measured namespace: the namespace's own declared
egress/api-egress DENY rows, which its policy must already enforce once the pod is
policed; plus or instead of those, settle.controls. */ -}}
{{- $sv := $v.settle | default dict -}}
{{- $auto := true -}}{{- if hasKey $sv "autoControls" -}}{{- $auto = $sv.autoControls -}}{{- end -}}
{{- $settle := dict -}}
{{- range $nss -}}
{{- $ns := . -}}
{{- $ctl := list -}}
{{- if $auto -}}
{{- range $rows -}}
{{- if and (eq .intent "deny") (or (eq .dimension "egress") (eq .dimension "api-egress")) (hasPrefix (printf "%s->" $ns) .subject) -}}
{{- $ctl = append $ctl (dict "target" (trimPrefix (printf "%s->" $ns) .subject) "expect" "denied") -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- with (get ($sv.controls | default dict) $ns) -}}
{{- $ctl = . -}}
{{- end -}}
{{- range $ctl -}}
{{- if not (hasKey $targets .target) -}}
{{- fail (printf "posture-probe: settle control %s for %s is not a declared target." .target $ns) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $settle $ns (dict "controls" $ctl "stableRounds" (int ($sv.stableRounds | default 3)) "intervalSeconds" ($sv.intervalSeconds | default 1) "minSpanSeconds" ($sv.minSpanSeconds | default 3) "maxSeconds" ($sv.maxSeconds | default 60)) -}}
{{- end -}}
{{- $collectS := int (($v.timeouts | default dict).collectSeconds | default 240) -}}
{{- if gt (add (int ($sv.maxSeconds | default 60)) 30) $collectS -}}
{{- fail (printf "posture-probe: settle.maxSeconds (%v) plus 30 s of measuring exceeds timeouts.collectSeconds (%d): collectors would be killed before they could settle." ($sv.maxSeconds | default 60) $collectS) -}}
{{- end -}}
{{- $eps := list -}}
{{- range $name, $tg := $targets -}}
{{- $eps = append $eps (dict "target" $name "host" $tg.host "port" $tg.port "dst_namespace" $tg.namespace "dimension" $tg.dimension "listener" $tg.listener) -}}
{{- end -}}
{{- $tm := $v.timeouts | default dict -}}
{{- $config := dict "namespaces" $nss "identityVantages" ($v.identityVantages | default list) "clusterIdentifier" ($v.clusterIdentifier | default "") "keep" (int (($v.store | default dict).keep | default 1)) "collectSeconds" (int ($tm.collectSeconds | default 240)) "apiTimeoutSeconds" 10 "presetRowsDropped" $dropped -}}
{{- dict "settle" $settle "targets" $targets "endpoints" $eps "rows" $rows "api" $api "config" $config "probeLabels" (dict "app.kubernetes.io/name" "posture-probe" "app.kubernetes.io/part-of" "posture-probe") | toJson -}}
{{- end -}}

{{- define "pp.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  seccompProfile: { type: RuntimeDefault }
{{- end -}}

{{- define "pp.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
{{- end -}}

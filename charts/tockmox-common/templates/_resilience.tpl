{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
THE RESILIENT CLAIM (TM-0597).

`global.resilience.profile: resilient` is the one key that says "this install
claims to be resilient". profiles/resilient.yaml sets it. A layer that has a
backup reads it and refuses to render while the claim is not backed by what a
claim needs, because the alternative is a profile called resilient whose
backups sit in the same failure domain as the cluster and say nothing. The
shipped Garage is in the cluster (docs/operations/backup-restore.md calls it
"not the answer for the store that matters"), and its Service name is the
default `endpoint` of every database backup.

WHAT THIS CAN AND CANNOT SEE. It reads one string, the backup endpoint, at
render time, with no cluster access. It names an endpoint that is inside the
cluster's DNS: a name ending in `.svc`, a `<service>.<namespace>.svc.<domain>`
name (a custom cluster domain), a `.cluster.local` name, a bare Service name, a
`<service>.<namespace>` pair whose namespace is one of this release's, one
named `tockmox-*`, `default` or `kube-system`, a loopback address in any IPv4
or IPv6 spelling, or the unspecified address (0.0.0.0, ::). A host that merely
has a `svc` label (`s3.svc.example.com`) is not refused: the Service form needs
a service and a namespace label before `svc`. It cannot see a NAS reached through an ExternalName Service,
an IP address that happens to be a cluster address, a CNAME that resolves to
an in-cluster ingress, or a store on the same host as the cluster. Those pass.
docs/deployment/profiles.md lists them under "what it cannot check", and that
list is the honest half of this guard.
*/}}

{{/*
Whether the install claims to be resilient. Returns "true" or "". The only
values are "resilient" and empty: any other string FAILS the render, because a
misspelt claim ("resilent") that quietly means "no claim" is the exact absence
that reads as green.
*/}}
{{- define "tockmox.resilience.claimed" -}}
{{- $r := ((.Values.global | default dict).resilience | default dict) -}}
{{- $p := $r.profile | default "" | toString -}}
{{- if eq $p "resilient" -}}true
{{- else if ne $p "" -}}{{- fail (printf "global.resilience.profile is %q. The only value it takes is \"resilient\", set by profiles/resilient.yaml, or empty for no claim. A misspelt claim would mean no claim, and an install that believes it is resilient is the failure this key exists to prevent." $p) -}}
{{- end -}}
{{- end -}}

{{/*
Why an endpoint is not an off-cluster target. Returns the reason as a short
phrase, or nothing when no in-cluster form was recognised.

Expects a dict:
  endpoint    the S3 endpoint string, with or without scheme, userinfo or port
  namespaces  a list of this release's namespace names, for the two-label
              `<service>.<namespace>` form (`tockmox-*`, `default` and
              `kube-system` are recognised without being listed)
*/}}
{{- define "tockmox.resilience.endpointProblem" -}}
{{- $why := "" -}}
{{- $raw := .endpoint | default "" | toString | trim -}}
{{- $h := regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://" $raw "" -}}
{{- $h = regexReplaceAll "[/?#].*$" $h "" -}}
{{- $h = regexReplaceAll "^[^@]*@" $h "" -}}
{{- if hasPrefix "[" $h -}}
  {{- $h = regexReplaceAll "^\\[([^\\]]*)\\].*$" $h "$1" -}}
{{- else -}}
  {{- $h = regexReplaceAll ":[0-9]*$" $h "" -}}
{{- end -}}
{{- $h = $h | lower | trimSuffix "." -}}
{{- $labels := splitList "." $h -}}
{{- if eq $h "" -}}
  {{- $why = "unset" -}}
{{- else if or (eq $h "localhost") (regexMatch "^(::ffff:)?127\\." $h) (regexMatch "^[0:]*:0*1$" $h) -}}
  {{- $why = (printf "%q is a loopback address, the pod itself" $h) -}}
{{- else if or (regexMatch "^(::ffff:)?0\\.0\\.0\\.0$" $h) (regexMatch "^[0:]+$" $h) -}}
  {{- $why = (printf "%q is the unspecified address, which a client reaches as the pod itself" $h) -}}
{{- else if or (hasSuffix ".svc" $h) (regexMatch "^[a-z0-9-]+\\.[a-z0-9-]+\\.svc\\." $h) -}}
  {{- $why = (printf "%q is a Kubernetes Service name (.svc)" $h) -}}
{{- else if hasSuffix ".cluster.local" $h -}}
  {{- $why = (printf "%q is inside the cluster's DNS (.cluster.local)" $h) -}}
{{- else if and (not (contains "." $h)) (not (contains ":" $h)) -}}
  {{- $why = (printf "%q is a bare name, which the cluster's DNS resolves to a Service in the same namespace" $h) -}}
{{- else if and (eq (len $labels) 2) (or (has (last $labels) (.namespaces | default list)) (hasPrefix "tockmox-" (last $labels)) (has (last $labels) (list "default" "kube-system"))) -}}
  {{- $why = (printf "%q is a Service in namespace %q" $h (last $labels)) -}}
{{- end -}}
{{- $why -}}
{{- end -}}

{{/*
Refuse to render while a backup endpoint is not an off-cluster target.

Expects a dict:
  ctx    the chart context (.Values.namespaces names the release's namespaces)
  key    the values path of the endpoint, named in the message
  value  the endpoint
*/}}
{{- define "tockmox.resilience.requireOffClusterTarget" -}}
{{- $why := include "tockmox.resilience.endpointProblem" (dict "endpoint" .value "namespaces" (values (.ctx.Values.namespaces | default dict))) -}}
{{- if eq $why "unset" -}}
{{- fail (printf "global.resilience.profile is resilient, but %s is empty. The resilient profile REQUIRES an off-cluster object-store target and does not choose one for you: set %s to an S3-compatible endpoint outside the cluster, with its bucket and credentialsSecretName. See docs/deployment/profiles.md, \"The resilient profile\"." .key .key) -}}
{{- else if $why -}}
{{- fail (printf "global.resilience.profile is resilient, but %s is %q, which is not an off-cluster target: %s. Backups that live inside the cluster are lost with it, and the resilient profile refuses to present that as resilient. The shipped default is the Garage inside the cluster. Set %s to an S3-compatible endpoint outside the cluster, with its bucket and credentialsSecretName, or remove the resilient profile if an in-cluster store is what you want. See docs/deployment/profiles.md, \"The resilient profile\"." .key .value $why .key) -}}
{{- end -}}
{{- end -}}

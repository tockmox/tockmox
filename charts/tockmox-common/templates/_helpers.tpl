{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
Standard labels applied to every Tockmox-shipped object.
The reserved-prefix contract (the design decision) is expressed here: anything carrying
tockmox.com/managed-by is shipped and maintained by the Tockmox base, and the
user's own layer must not use the reserved prefix.
NOTE: tockmox.com is the reserved label domain. Chosen over .ai deliberately:
 a label key is embedded in every user's cluster and is painful to change,
 and a ccTLD carries policy and pricing risk a .com does not.
*/}}
{{- define "tockmox.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tockmox
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
tockmox.com/managed-by: tockmox
tockmox.com/layer: {{ .Chart.Name | trimPrefix "tockmox-" }}
{{- end -}}

{{/* Reserved namespace for a shipped component (the design decision: tockmox- prefix). */}}
{{- define "tockmox.namespace" -}}
{{- printf "tockmox-%s" . -}}
{{- end -}}

{{/* Internal hostname for a service: <svc>.<global.internalDomain> */}}
{{- define "tockmox.internalHost" -}}
{{- printf "%s.%s" .svc .ctx.Values.global.internalDomain -}}
{{- end -}}

{{/* Image reference honouring global.imageRegistry for airgap mirroring. */}}
{{- define "tockmox.image" -}}
{{- if .ctx.Values.global.imageRegistry -}}
{{- printf "%s/%s" (trimSuffix "/" .ctx.Values.global.imageRegistry) .repo -}}
{{- else -}}
{{- .repo -}}
{{- end -}}
{{- end -}}

{{/*
One Ingress for a shipped UI. Hostname derives from global.internalDomain
(`<prefix>.<internalDomain>`) unless the caller supplies an explicit host.
TLS follows global.certIssuer: set, and the Ingress carries the cert-manager
annotation plus a tls block; empty, and it serves plain HTTP ... the same
"empty skips certificates" contract configuration.md documents.

Expects a dict:
  ctx      the chart context (required)
  name     Ingress object name (required)
  prefix   host label prepended to internalDomain (required)
  host     explicit FQDN override; "" derives from prefix (optional)
  service  backend Service name (required)
  port     backend Service port number (required)
  extra    additional paths on the SAME host, as a list of dicts
           {path, pathType, service, port} (optional)
  wave     ArgoCD sync-wave for the Ingress, as a string (optional; none set
           when omitted, which ArgoCD reads as wave 0)

`wave` exists for ONE case: an Ingress rendered by the SAME layer (ArgoCD
Application) that ships the controller giving it its address. ArgoCD calls an
Ingress Healthy only when it has a load-balancer address, and that address comes
from the controller's LoadBalancer Service, which the platform layer places in
wave 7 (after the MetalLB pool). An Ingress left in wave 0 of that layer waits
for an address that is never requested, because the wave that would request it
never starts: the sync hangs (0.7.0-rc2 greenfield, 2026-10-01). Ingresses in
any later layer need no wave, because the whole platform Application is Healthy
before they are applied. tools/check-upgrade-safety.sh F5 enforces both.

`extra` exists so a sidecar surface (the brand asset server under /tockmox on
the Authentik host) can share the host's ONE Ingress and therefore its ONE
certificate. A second Ingress object for the same host would need its own tls
block and its own cert, and if you omit that block the path is reachable over
plain HTTP only ... which looks like a routing bug and is really a TLS one.
*/}}
{{- /*
`annotations` (a dict) is added to THIS Ingress only, before the site-wide
`ingress.annotations`. It exists for the forward-auth route (TM-0425): a console
behind Authentik carries the router.middlewares annotation that
tockmox.forwardAuthAnnotations renders, and no other Ingress in the layer does.
*/ -}}
{{- define "tockmox.ingress" -}}
{{- $host := .host | default (include "tockmox.internalHost" (dict "svc" .prefix "ctx" .ctx)) -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .name }}
  labels:
    {{- include "tockmox.labels" .ctx | nindent 4 }}
  {{- $certIssuer := .ctx.Values.global.certIssuer }}
  {{- $extra := .ctx.Values.ingress.annotations }}
  {{- if or $certIssuer $extra .wave .annotations }}
  annotations:
    {{- if .wave }}
    argocd.argoproj.io/sync-wave: {{ .wave | toString | quote }}
    {{- end }}
    {{- if $certIssuer }}
    cert-manager.io/cluster-issuer: {{ $certIssuer }}
    {{- end }}
    {{- with .annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with $extra }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
spec:
  {{- with .ctx.Values.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  rules:
    - host: {{ $host }}
      http:
        paths:
          {{- /* More specific paths FIRST: ingress-nginx and Traefik both
                 order by specificity, but an explicit order removes any doubt
                 that "/" swallows "/tockmox". */}}
          {{- range .extra }}
          - path: {{ .path }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ .service }}
                port:
                  number: {{ .port }}
          {{- end }}
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .service }}
                port:
                  number: {{ .port }}
  {{- if $certIssuer }}
  tls:
    - hosts:
        - {{ $host }}
      secretName: {{ .name }}-tls
  {{- end }}
{{- end -}}

{{/*
IN-CLUSTER TRUST FOR A PRIVATE CA.

A console that performs its OWN OIDC token exchange does that from inside its
container, so the browser trusting the Tockmox CA is irrelevant: the container's
TLS stack has to trust it too. With `global.certIssuer` set and nothing else
done, login fails at the token step with

  [SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate

and only local break-glass accounts still work.

WHY A BUNDLE AND NOT JUST THE CA. The obvious fix is to mount `ca.crt` and point
`SSL_CERT_FILE` at it. Measured in the Open WebUI 0.11.0 image on 2026-08-15,
that breaks public TLS for two of the three HTTP clients it ships:

  SSL_CERT_FILE=<ca only>   public: urllib OK, httpx CERTFAIL, requests CERTFAIL
  SSL_CERT_FILE=<concat>    public: urllib OK, httpx OK,       requests OK

urllib survives because OpenSSL still consults the default capath; httpx and
requests pass the file as a cafile and consult nothing else. So the file has to
be the image's own trust store PLUS the CA, which is what the initContainer
below builds.

WHY THE INITCONTAINER RUNS THE APPLICATION'S OWN IMAGE. The bundle it writes is
that image's trust store. Any other image substitutes a different set of public
roots into the application, silently. `tockmox.trustBundle.assertImage` is the
check that proves the two stay equal.
*/}}
{{- define "tockmox.trustBundle.assertImage" -}}
{{- if ne .expected .actual -}}
{{- fail (printf "trust-bundle initContainer image mismatch. %s is %q; the %s container runs %q. The initContainer builds the CA bundle from its OWN image's trust store, so a different image hands the application a different set of public roots. Set %s to %q." .key .actual .component .expected .key .expected) -}}
{{- end -}}
{{- end -}}

{{/*
Guard the rest of the wiring. A site that overrides any of these list-valued
subchart keys REPLACES the shipped list rather than appending to it, which is
how the devtest site silently dropped `enableOpenaiApi` in August 2026. This
fails the render instead, naming the key and what has to be back in it.

Expects a dict:
  ctx        chart context (unused today, kept for symmetry)
  component  human name for the message
  checks     list of dicts {key, present} where present is a bool
*/}}
{{- define "tockmox.trustBundle.assertWiring" -}}
{{- range .checks -}}
{{- if not .present -}}
{{- fail (printf "in-cluster trust wiring for %s is incomplete: %s. Without it the container does not trust the Tockmox CA and server-side OIDC fails at the token exchange with CERTIFICATE_VERIFY_FAILED, while local break-glass login keeps working. See docs/administration/tls-and-trust.md, section \"Trust inside the cluster\"." $.component .detail) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
ROLLING A SUBCHART POD WHEN A PARENT-RENDERED SECRET CHANGES.

`envFrom` is not a trigger. Kubernetes does not restart a pod when a Secret it
reads through `envFrom` changes, so the pod keeps serving the value it started
with. Observed on the devtest lab 2026-08-15: `global.certIssuer` was set, the
sso-env Secrets correctly re-rendered to https, and Open WebUI and Grafana kept
using the http endpoints until both pods were deleted by hand.

The usual fix is a `checksum/config` pod annotation. It does not work here, and
the reason is worth writing down: the Secret is rendered by the PARENT chart and
the pod by a SUBCHART, and none of open-webui 16.0.0, grafana 12.10.4 or
argo-workflows 2.0.0 runs `tpl` over its `podAnnotations`. A template expression
placed there arrives in the manifest as literal text.

What those charts DO run `tpl` over is env values ... open-webui's
`extraEnvVars` and grafana's `env`, both verified in their templates. So the
trigger rides as an environment variable instead: it is part of the pod spec, so
a change to it rolls the pod the way any other spec change does.

WHAT THIS COVERS, EXACTLY. A subchart can see `.Values.global` and nothing else
of the parent's, so this hashes the globals the SSO Secrets derive from:
`certIssuer` (which is the scheme) and `internalDomain` (which is every
hostname). It does NOT cover `sso.clientId`, `sso.adminGroup` or `sso.userGroup`,
because those live in the parent's values and no subchart can read them.
Changing one of those still needs `kubectl rollout restart`, and
docs/operations/day-2.md says so.

argo-workflows needs none of this: its OIDC settings are plain values in the
pod spec rather than a Secret, so changing them already rolls the pod.
*/}}
{{- define "tockmox.ssoEnvRevision" -}}
{{- printf "certIssuer=%s;internalDomain=%s" (.Values.global.certIssuer | default "") (.Values.global.internalDomain | default "") | sha256sum | trunc 16 -}}
{{- end -}}

{{/*
FORWARD-AUTH FOR A CONSOLE THAT HAS NO SIGN-IN OF ITS OWN (TM-0425).

Prometheus, Alertmanager, Longhorn and the Traefik dashboard ship no
authentication. Each can now be routed at a Host-matched name with Authentik in
front: the identity layer renders ONE Traefik Middleware
(`tockmox-forward-auth` in its own namespace) pointing at Authentik's embedded
outpost, plus a per-console proxy provider, application and group binding
(`sso.forwardAuth.apps.<console>` in the identity layer). The console's own
layer only attaches the Middleware, by reference, with the annotation below.

The reference is provider-qualified (`<namespace>-<name>@kubernetescrd`), which
is how Traefik resolves a Middleware in another namespace from an Ingress
annotation. An IngressRoute cannot use it: Traefik refuses `@kubernetescrd`
references and cross-namespace Middlewares from the CRD provider unless its
`allowCrossNamespace` is on, so the platform layer's Traefik dashboard route
carries a Middleware of its own (TM-0217). The default matches a stock install (identity in
`tockmox-authentik`); `ingress.forwardAuth.middleware` overrides it for a site
that moved the identity layer.

THE CONSOLE REFUSES TO RENDER UNAUTHENTICATED BY ACCIDENT. An app with
`forwardAuth: true` (the default) while the identity capability is off fails the
render: the Middleware would not exist, and Traefik answers a route whose
middleware is missing with a 404, which reads as a routing bug rather than a
missing sign-in. `forwardAuth: false` is the explicit way to route the console
without Authentik (your own auth in front, via `ingress.annotations`).

Usage: include "tockmox.forwardAuthAnnotations" (dict "ctx" $ "app" "prometheus" "on" .forwardAuth)
returns a YAML dict (empty when `on` is false) for tockmox.ingress's `annotations`.
*/}}
{{- define "tockmox.forwardAuthRef" -}}
{{- $fa := (.ctx.Values.ingress | default dict).forwardAuth | default dict -}}
{{- $fa.middleware | default "tockmox-authentik-tockmox-forward-auth@kubernetescrd" -}}
{{- end -}}

{{- define "tockmox.forwardAuthAnnotations" -}}
{{- if .on -}}
{{- if not (include "tockmox.capabilityEnabled" (dict "ctx" .ctx "capability" "identity")) -}}
{{- fail (printf "ingress.apps.%s.forwardAuth is true (the default), but capabilities.identity is off, so there is no Authentik to sign in with and the route would answer 404. Turn the identity capability on, or set ingress.apps.%s.forwardAuth: false and put your own authentication in front (ingress.annotations), or leave ingress.apps.%s.enabled: false and use kubectl port-forward." .app .app .app) -}}
{{- end -}}
traefik.ingress.kubernetes.io/router.middlewares: {{ include "tockmox.forwardAuthRef" (dict "ctx" .ctx) }}
{{- end -}}
{{- end -}}

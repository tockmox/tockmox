{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
GARAGE WEB SERVING (TM-0215): the shared decisions, in one place so the
ConfigMap, the Service, the bootstrap Job, the Ingresses and the sync Jobs
cannot disagree about which sites exist.

Garage's web endpoint serves a bucket as a website when website access is on
for the bucket and the request Host equals one of its global aliases (or is
`<bucket><root_domain>`). Everything below follows from that: a site's host IS
its bucket alias, so a host that ends with the root domain would be parsed as a
bucket NAME instead and is refused.
*/}}

{{/* The [s3_web] root_domain, with a leading dot. Takes the chart context. */}}
{{- define "tockmox.garageWeb.rootDomain" -}}
{{- $w := .Values.garage.web | default dict -}}
{{- $r := $w.rootDomain | default (printf ".web.%s" .Values.global.internalDomain) -}}
{{- if not (hasPrefix "." $r) -}}{{- $r = printf ".%s" $r -}}{{- end -}}
{{- $r -}}
{{- end -}}

{{/*
The EFFECTIVE site list as YAML: the configured list minus the docs entry when
apps.docs resolves false, each entry normalised and validated. THE DOCS ENTRY IS
THE SITE NAMED `docs` (TM-0808): it has no content, because the product
documentation is published from the operator's checkout by tools/publish-docs.sh,
not synced from an image; it must have a writer key (the publish pod uses it);
and it is the one site the bootstrap Job gives a placeholder page to. Consume with
`include ... | fromYamlArray`. Takes the chart context.

Every failure here is a render-time failure on purpose. A site that renders and
serves nothing (a bad alias, a host the root domain swallows, a docs switch on
with no docs entry because a restated list dropped it) applies cleanly and does
nothing, which is the shape this repo keeps finding in itself.
*/}}
{{- define "tockmox.garageWeb.sites" -}}
{{- $ctx := . -}}
{{- $w := .Values.garage.web | default dict -}}
{{- $domain := .Values.global.internalDomain -}}
{{- $docsOn := include "tockmox.appEnabled" (dict "ctx" $ctx "app" "docs") -}}
{{- $root := include "tockmox.garageWeb.rootDomain" $ctx -}}
{{- $out := list -}}
{{- $names := dict -}}
{{- $hosts := dict -}}
{{- $docsSeen := false -}}
{{- range $s := ($w.sites | default list) -}}
  {{- $c := $s.content | default dict -}}
  {{- $name := $s.name | default "" -}}
  {{- $isDocs := eq $name "docs" -}}
  {{- if or (not $isDocs) $docsOn -}}
    {{- /*
    THE 32 IS ARITHMETIC. The sync CronJob is `tockmox-garage-sync-<name>`: 20
    characters plus the name. A CronJob name may have 52 characters, because the
    controller appends 11 for each Job it makes, and 20 + 32 = 52. The one-shot
    Job the bootstrap starts at install is `tockmox-garage-sync-<name>-<chart
    version, dashes>` (garage-bootstrap.yaml); with a 32 character name that is
    52 + 1 + 5 = 58 for `0-7-0` and 60 for `0-10-10`, under the 63 a Job name
    may have, and garage-bootstrap.yaml fails the render if a version ever pushes
    it over. An earlier draft of this feature allowed 40; a 33 to 40 character
    name rendered and was then refused by the API server at apply.
    */ -}}
    {{- if or (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) (gt (len $name) 32) -}}
      {{- fail (printf "garage.web.sites: name %q must be a DNS label of at most 32 characters (lowercase letters, digits, hyphens). It names the Ingress, the writer Secret and the sync CronJob `tockmox-garage-sync-<name>`, and a CronJob name may have 52 characters." $name) -}}
    {{- end -}}
    {{- if hasKey $names $name -}}
      {{- fail (printf "garage.web.sites: name %q appears twice. Names must be unique." $name) -}}
    {{- end -}}
    {{- $_ := set $names $name true -}}
    {{- $host := $s.host | default "" -}}
    {{- if not $host -}}
      {{- if not $domain -}}
        {{- fail (printf "garage.web.sites: site %q has no host and global.internalDomain is empty, so there is nothing to derive one from." $name) -}}
      {{- end -}}
      {{- $host = printf "%s.%s" $name $domain -}}
    {{- end -}}
    {{- if or (not (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" $host)) (gt (len $host) 63) (lt (len $host) 3) -}}
      {{- fail (printf "garage.web.sites: site %q host %q must be 3 to 63 characters of lowercase letters, digits, hyphens and dots. The host is also the bucket's global alias, and bucket names carry that limit." $name $host) -}}
    {{- end -}}
    {{- if hasKey $hosts $host -}}
      {{- fail (printf "garage.web.sites: host %q appears twice. One host is one bucket." $host) -}}
    {{- end -}}
    {{- $_ := set $hosts $host true -}}
    {{- if hasSuffix $root (printf ".%s" $host) -}}
      {{- fail (printf "garage.web.sites: site %q host %q ends with the web root domain %q. Garage would read the front of the host as a bucket NAME and never look at the alias. Change garage.web.rootDomain or the host." $name $host $root) -}}
    {{- end -}}
    {{- $index := $s.index | default "index.html" -}}
    {{- $errdoc := $s.errorDocument | default "" -}}
    {{- if or (not (regexMatch "^[^\\s\"\\\\]+$" $index)) (and $errdoc (not (regexMatch "^[^\\s\"\\\\]+$" $errdoc))) -}}
      {{- fail (printf "garage.web.sites: site %q index and errorDocument must be object keys with no whitespace, quotes or backslashes." $name) -}}
    {{- end -}}
    {{- $img := $c.image | default "" -}}
    {{- if and $isDocs $img -}}
      {{- fail "garage.web.sites: the site named docs is the product documentation, which is published from your checkout by tools/publish-docs.sh and takes no content.image. Name your own site something else." -}}
    {{- end -}}
    {{- if and $isDocs (hasKey $s "writerKey") (not $s.writerKey) -}}
      {{- fail "garage.web.sites: the docs site has writerKey: false. tools/publish-docs.sh writes with that key. Set writerKey: true." -}}
    {{- end -}}
    {{- $hasContent := $img -}}
    {{- if and $hasContent (hasKey $s "writerKey") (not $s.writerKey) -}}
      {{- fail (printf "garage.web.sites: site %q has content but writerKey: false. The sync Job writes with that key. Set writerKey: true or drop the content." $name) -}}
    {{- end -}}
    {{- if $isDocs -}}{{- $docsSeen = true -}}{{- end -}}
    {{- $out = append $out (dict
        "name" $name
        "host" $host
        "index" $index
        "errorDocument" $errdoc
        "ingress" ($s.ingress | default false)
        "writerKey" (or $hasContent $isDocs ($s.writerKey | default false))
        "placeholder" $isDocs
        "contentImage" $img
        "contentPath" ($c.path | default "/site")
        "secret" (printf "tockmox-garage-site-%s" $name)) -}}
  {{- end -}}
{{- end -}}
{{- if and $docsOn (not $docsSeen) -}}
  {{- fail "apps.docs is on but garage.web.sites has no entry named docs. Helm replaces a list rather than merging it, so a site list that omits the shipped `docs` entry drops the documentation site. Restate that entry in your list (see the comment on garage.web.sites in values.yaml), or set apps.docs.enabled: false." -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/* "true" when Garage should bind the web endpoint, else empty. */}}
{{- define "tockmox.garageWeb.enabled" -}}
{{- $w := .Values.garage.web | default dict -}}
{{- $sites := include "tockmox.garageWeb.sites" . | fromYamlArray -}}
{{- if or $w.enabled (include "tockmox.appEnabled" (dict "ctx" . "app" "docs")) (gt (len $sites) 0) -}}true{{- end -}}
{{- end -}}

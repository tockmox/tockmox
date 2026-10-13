{{- /*
SPDX-License-Identifier: Apache-2.0

IPv4 prefix containment, because Helm has no CIDR function (TM-0790).

  {{ include "tockmox.cidrContains" (dict "outer" "10.0.0.0/8" "inner" "10.42.0.0/16") }}

prints "true" when every address in INNER is also in OUTER, "" when it is not,
and "unparseable" when either argument is not a plain IPv4 CIDR (a.b.c.d/n with
each octet 0-255 and n 0-32). Callers treat "unparseable" as "cannot tell" and
DO NOT refuse on it: IPv6 and dual-stack sites are not evaluated here, and a
malformed value is the schema's and the API server's to reject, not this
helper's to guess about.

THE ARITHMETIC. An address is a 32-bit integer, o1*2^24 + o2*2^16 + o3*2^8 + o4.
A /n block is the run of 2^(32-n) addresses that share the same integer
quotient by 2^(32-n). OUTER contains INNER exactly when INNER is not the wider
block (n_outer <= n_inner) and both base addresses divide into the same OUTER
block. Host bits in a value are ignored, as a real ipBlock ignores them: 10.1.2.3/8
is the block 10.0.0.0/8.

What this does NOT do: it does not know which CIDR a given site's nodes really
sit in, and it only compares the two strings it is given.
*/ -}}
{{- define "tockmox.cidrParse" -}}
{{- /* -> "<address-int> <prefix>" or "" */ -}}
{{- if regexMatch "^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$" (toString .) -}}
{{- $parts := splitList "/" (toString .) -}}
{{- $o := splitList "." (index $parts 0) -}}
{{- $p := atoi (index $parts 1) -}}
{{- $ok := le $p 32 -}}
{{- range $o }}{{ if gt (atoi .) 255 }}{{ $ok = false }}{{ end }}{{ end -}}
{{- if $ok -}}
{{- $n := add (add (mul (int64 (atoi (index $o 0))) 16777216) (mul (int64 (atoi (index $o 1))) 65536)) (add (mul (int64 (atoi (index $o 2))) 256) (int64 (atoi (index $o 3)))) -}}
{{- printf "%d %d" $n $p -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "tockmox.cidrContains" -}}
{{- $o := include "tockmox.cidrParse" .outer | trim -}}
{{- $i := include "tockmox.cidrParse" .inner | trim -}}
{{- if or (eq $o "") (eq $i "") -}}
unparseable
{{- else -}}
{{- $of := splitList " " $o -}}
{{- $ib := splitList " " $i -}}
{{- $op := atoi (index $of 1) -}}
{{- $ip := atoi (index $ib 1) -}}
{{- if le $op $ip -}}
{{- $size := int64 1 -}}
{{- range untilStep 0 (int (sub 32 $op)) 1 }}{{ $size = mul $size 2 }}{{ end -}}
{{- if eq (div (int64 (atoi (index $of 0))) $size) (div (int64 (atoi (index $ib 0))) $size) -}}true{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

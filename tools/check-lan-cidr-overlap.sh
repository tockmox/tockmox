#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that the policy layer refuses a global.lanCIDR
# that contains global.clusterCIDR when platformNetpol.nodeOriginSources is set
# (TM-0790), and that it refuses nothing else.
#
#   ./tools/check-lan-cidr-overlap.sh
#
# WHY. platformNetpol.nodeOriginSources narrows allow-from-node-network by NOT
# rendering the clusterCIDR ipBlock. The lanCIDR ipBlock is always rendered, so a
# lanCIDR that is a supernet of the pod network (ci/values.yaml had 10.0.0.0/8
# against 10.42.0.0/16) re-admits every pod and the narrowing renders as done
# while doing nothing. Helm has no CIDR function; tockmox.cidrContains in
# charts/tockmox-policy/templates/_cidr.tpl does the prefix arithmetic, and this
# gate holds it to the cases below. Two parts:
#
#   1. the helper alone, through a scratch chart that includes only _cidr.tpl:
#      contains, equal, narrower, adjacent, disjoint, host bits, /0 and /32
#      edges, and inputs it must call unparseable rather than guess about
#   2. the policy layer, rendered: each case asserts the fail() MESSAGE names both
#      values, or (for a pass) that the rendered allow-from-node-network policy
#      carries the lanCIDR block AND the node source and no clusterCIDR block
#
# Assertions read the output, never the exit code: `helm template` exits 1 on
# ANY failure, and a case that failed for the wrong reason (a typo in the values
# file, a missing subchart) would otherwise read as "refused as expected".
#
# WHAT THIS DOES NOT PROVE. That the arithmetic is right for IPv6 (it declines
# to judge IPv6), that a site's real node addresses lie outside the lanCIDR it
# names, or that any of this reaches a live cluster's packets. It compares two
# strings.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-lan-cidr-overlap: helm not on PATH" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/lan-cidr.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n       %s\n' "$1" "$2"; fail=1; }

echo "helm: $(helm version --short 2>/dev/null)"

# ---- 1. the helper alone -----------------------------------------------------
sc="$tmp/scratch"; mkdir -p "$sc/templates"
printf 'apiVersion: v2\nname: scratch\nversion: 0.0.1\n' > "$sc/Chart.yaml"
cp charts/tockmox-policy/templates/_cidr.tpl "$sc/templates/_cidr.tpl"
# case format: outer|inner|expected  (expected: true | none | unparseable)
cases=(
  "10.0.0.0/8|10.42.0.0/16|true"                # the ci/values.yaml case
  "10.42.0.0/16|10.42.0.0/16|true"              # equal
  "10.42.0.0/17|10.42.0.0/16|none"              # outer NARROWER than inner
  "10.42.0.0/16|10.42.0.0/17|true"              # inner is a subset
  "10.40.0.0/14|10.42.0.0/16|true"              # non-octet boundary, contained
  "10.44.0.0/14|10.42.0.0/16|none"              # non-octet boundary, disjoint
  "10.43.0.0/16|10.42.0.0/16|none"              # adjacent, not overlapping
  "192.168.1.0/24|10.42.0.0/16|none"            # unrelated
  "172.16.0.0/12|10.42.0.0/16|none"
  "0.0.0.0/0|10.42.0.0/16|true"                 # everything contains everything
  "10.42.0.7/32|10.42.0.7/32|true"              # /32 equal
  "10.42.0.7/32|10.42.0.8/32|none"              # /32 different
  "10.1.2.3/8|10.42.0.0/16|true"                # host bits ignored
  "192.168.0.0/16|192.168.100.0/22|true"        # a non-default cluster CIDR
  "192.168.101.0/24|192.168.100.0/22|none"      # narrower than the cluster block
  "128.0.0.0/1|10.42.0.0/16|none"               # top-bit boundary
  "10.0.0.0/8|10.42.0.0|unparseable"            # no prefix length
  "10.0.0.0/8|10.42.0.0/33|unparseable"         # prefix out of range
  "10.0.0.0/8|10.42.0.256/16|unparseable"       # octet out of range
  "10.0.0.0/8|fd00::/8|unparseable"             # IPv6 is not judged
  "|10.42.0.0/16|unparseable"                   # empty
  "10.0.0.0/8|10.42.0.0/x|unparseable"
)
{
  i=0
  for c in "${cases[@]}"; do
    IFS='|' read -r o n _ <<<"$c"
    printf 'C%d: {{ include "tockmox.cidrContains" (dict "outer" "%s" "inner" "%s") | default "none" }}\n' "$i" "$o" "$n"
    i=$((i+1))
  done
} > "$sc/templates/out.yaml"
out="$(helm template s "$sc" 2>&1)"
i=0
for c in "${cases[@]}"; do
  IFS='|' read -r o n want <<<"$c"
  got="$(printf '%s\n' "$out" | sed -n "s/^C${i}: //p")"
  if [ "$got" = "$want" ]; then ok "contains(outer=${o:-<empty>}, inner=$n) = $want"
  else bad "contains(outer=${o:-<empty>}, inner=$n)" "wanted '$want', got '${got:-<no output>}'"; fi
  i=$((i+1))
done

# ---- 2. the policy layer, rendered -------------------------------------------
# render <lanCIDR> <clusterCIDR> <sources-yaml-list> -> $R (combined output)
render() {
  cat > "$tmp/v.yaml" <<YAML
global:
  lanCIDR: "$1"
  clusterCIDR: "$2"
platformNetpol:
  nodeOriginSources: $3
YAML
  R="$(helm template t charts/tockmox-policy -f ci/values.yaml -f "$tmp/v.yaml" 2>&1)"
}
# The allow-from-node-network policy's ipBlock cidrs, in order.
node_policy_cidrs() {
  printf '%s\n' "$R" | awk '
    /^kind: NetworkPolicy/ {k=1}
    /^---/ {k=0; n=0; inpol=0}
    k && /name: allow-from-node-network/ {inpol=1}
    inpol && /cidr:/ {print $2}' | tr '\n' ' '
}
SRC='["10.42.1.0/31"]'

refuses() { # name lan cluster
  render "$2" "$3" "$SRC"
  if printf '%s' "$R" | grep -q "global.lanCIDR ($2) contains global.clusterCIDR ($3)"; then
    ok "$1: refused, message names both values ($2 and $3)"
  else
    bad "$1: expected the containment refusal naming $2 and $3" "$(printf '%s' "$R" | head -3 | cut -c1-220)"
  fi
}
passes() { # name lan cluster
  render "$2" "$3" "$SRC"
  local got; got="$(node_policy_cidrs)"
  if printf '%s' "$R" | grep -q 'contains global.clusterCIDR'; then
    bad "$1: must NOT refuse ($2 vs $3)" "$(printf '%s' "$R" | head -2 | cut -c1-200)"
  elif [ "$got" = "$2 10.42.1.0/31 " ]; then
    ok "$1: renders, allow-from-node-network = [$2, 10.42.1.0/31], no clusterCIDR block"
  else
    bad "$1: rendered, but allow-from-node-network cidrs are not [$2, 10.42.1.0/31]" "got: '${got:-<none>}'; $(printf '%s' "$R" | grep -m1 -i error | cut -c1-200)"
  fi
}

refuses "lan contains cluster (ci/values.yaml's case until 0.8.0)" 10.0.0.0/8 10.42.0.0/16
refuses "lan equals cluster"                             10.42.0.0/16 10.42.0.0/16
refuses "lan is a non-octet supernet"                    10.40.0.0/14 10.42.0.0/16
refuses "lan is everything"                              0.0.0.0/0 10.42.0.0/16
refuses "a non-default cluster CIDR"                     192.168.0.0/16 192.168.100.0/22
passes  "lan does not contain cluster (disjoint)"        192.168.1.0/24 10.42.0.0/16
passes  "lan and cluster are adjacent, not overlapping"  10.43.0.0/16 10.42.0.0/16
passes  "lan is inside the cluster block"                10.42.5.0/24 10.42.0.0/16
passes  "lan is a narrower prefix on the same base"      10.42.0.0/17 10.42.0.0/16

# Not set: since 0.8.0 an empty list refuses rather than rendering the wide
# clusterCIDR rule (TM-0798), whatever the lanCIDR. Both a supernet and a
# disjoint LAN must refuse, and the message must name the key and the helper.
for lan in 10.0.0.0/8 192.168.1.0/24; do
  render "$lan" 10.42.0.0/16 '[]'
  got="$(node_policy_cidrs)"
  if printf '%s' "$R" | grep -q 'nodeOriginSources is empty' \
     && printf '%s' "$R" | grep -q -- '--print-netpol-node-sources' && [ -z "$got" ]; then
    ok "nodeOriginSources empty, lanCIDR $lan: refused, naming the key and the helper, no policy rendered"
  else
    bad "nodeOriginSources empty must refuse (TM-0798), lanCIDR $lan" "got cidrs: '${got:-<none>}'; $(printf '%s' "$R" | head -2 | cut -c1-200)"
  fi
done

# A value the helper cannot parse is not judged: it renders, and the API server
# owns the rejection.
render "fd00::/8" 10.42.0.0/16 "$SRC"
if printf '%s' "$R" | grep -q 'contains global.clusterCIDR'; then
  bad "an IPv6 lanCIDR must not trigger the IPv4 containment refusal" "$(printf '%s' "$R" | head -2 | cut -c1-200)"
else
  ok "an IPv6 lanCIDR is not judged by the IPv4 check"
fi

# The pre-existing guard must still be there and still win on its own case.
render 192.168.1.0/24 10.42.0.0/16 '["10.42.0.0/16"]'
if printf '%s' "$R" | grep -q 'nodeOriginSources contains 10.42.0.0/16'; then
  ok "the older whole-pod-network entry guard still fires"
else
  bad "the older whole-pod-network entry guard no longer fires" "$(printf '%s' "$R" | head -2 | cut -c1-200)"
fi

[ "$fail" -eq 0 ] && echo "PASS: lanCIDR containment refusal holds on the rendered artifact" || echo "FAIL: see above"
exit "$fail"

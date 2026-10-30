#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE AGENT-EGRESS PROXY, AS RENDERED, IN A REAL SMOKESCREEN (TM-1251).
#
# Takes the proxy's config.yaml and acl.yaml from `helm template` of the policy
# layer with ci/values-agent-egress.yaml, runs Smokescreen on them with a
# resolver this script controls, and records its decision for five CONNECTs:
#
#   a listed name -> a public address        allowed by the ACL
#   an unlisted name -> the same address      refused: the default rule
#   a listed name -> a private address        refused: private range
#   a listed name -> the metadata address     refused: not global unicast
#   a listed name -> the service range        refused: the chart's deny_ranges
#
# The verdicts come from Smokescreen's own decision log, not from whether the
# connection then succeeded (this runner has no route to the public address).
# It proves the proxy configuration; the NetworkPolicy fence around it is the
# lab proof.
#
#   SMOKESCREEN_BIN=/path/to/smokescreen tests/agent-egress/proxy-proof.sh
#   (build: git clone https://github.com/stripe/smokescreen && go build -mod=vendor .)
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="${SMOKESCREEN_BIN:-$(command -v smokescreen || true)}"
[ -x "$bin" ] || { echo "proxy-proof: SKIPPED, no Smokescreen binary (set SMOKESCREEN_BIN)"; exit 2; }
tmp="$(mktemp -d)"; pids=()
# shellcheck disable=SC2329  # invoked by the trap
cleanup() { local p; for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
PDNS=15353; PPROXY=14750

helm template t "$root/charts/tockmox-policy" -n argocd -f "$root/ci/values.yaml" -f "$root/ci/values-agent-egress.yaml" > "$tmp/out.yaml" \
  || { echo "proxy-proof: render failed"; exit 1; }
python3 - "$tmp" <<'PY' || { echo "proxy-proof: no proxy ConfigMap in the render"; exit 1; }
import sys, yaml
t = sys.argv[1]
for d in yaml.safe_load_all(open(f"{t}/out.yaml")):
    if d and d["kind"] == "ConfigMap" and d["metadata"]["name"] == "agent-egress-proxy-web-fetch":
        open(f"{t}/acl.yaml", "w").write(d["data"]["acl.yaml"])
        open(f"{t}/config.yaml", "w").write(d["data"]["config.yaml"].replace("/etc/smokescreen/acl.yaml", f"{t}/acl.yaml"))
        sys.exit(0)
sys.exit(1)
PY
# an address in the service range the CI values declare, NOT one read back from the render under test
svc=$(python3 -c '
import sys, yaml, ipaddress
cidr = None
for f in sys.argv[1:]:
    cidr = ((yaml.safe_load(open(f)) or {}).get("global") or {}).get("serviceCIDR") or cidr
print(ipaddress.ip_network(cidr)[10])' "$root/charts/tockmox-policy/values.yaml" "$root/ci/values.yaml") \
  || { echo "proxy-proof: no global.serviceCIDR in the policy layer values"; exit 1; }
python3 "$(dirname "$0")/fake_dns.py" "$PDNS" api.example.com=93.184.215.14 evil.example.net=93.184.215.14 \
  docs.example.org=10.1.2.3 meta.example.com=169.254.169.254 "svc.example.com=$svc" & pids+=($!)
"$bin" --config-file="$tmp/config.yaml" --listen-ip=127.0.0.1 --listen-port=$PPROXY --resolver-address=127.0.0.1:$PDNS \
  > "$tmp/proxy.log" 2>&1 & pids+=($!)
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$PPROXY) 2>/dev/null && break; sleep 0.2; done
for h in api.example.com evil.example.net docs.example.org meta.example.com svc.example.com; do
  curl -s -o /dev/null --noproxy '' -x "http://127.0.0.1:$PPROXY" --proxytunnel --connect-timeout 4 "https://$h/" || true
done
sleep 1
decide() { python3 - "$tmp/proxy.log" "$1" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("requested_host") == sys.argv[2] + ":443" and "allow" in d:
        print(("allow" if d["allow"] else "deny") + "|" + (d.get("decision_reason") or "").strip()); break
PY
}
expect() {   # host, allow|deny, reason fragment, label
  local got; got=$(decide "$1")
  case "${got#*|}" in *"$3"*) why_ok=1 ;; *) why_ok=0 ;; esac   # no pipe into grep -q under pipefail (check-pipe-grep-q.py)
  if [ "${got%%|*}" = "$2" ] && [ "$why_ok" = 1 ]; then ok "$4 ($1: ${got#*|})"
  else bad "$4: $1 gave '${got:-no decision}'"; fi
}
expect api.example.com  allow "host matched allowed domain" "1 a listed name, public address: allowed"
expect evil.example.net deny  "default rule policy used"    "2 an unlisted name: refused by the default rule"
expect docs.example.org deny  "Private Range"               "3 a listed name on a private address: refused"
expect meta.example.com deny  "Not Global Unicast"          "4 a listed name on the metadata address: refused"
expect svc.example.com  deny  "User Configured"             "5 a listed name in the service range: refused by the chart's deny_ranges"
"$bin" --version 2>/dev/null | head -1 | sed 's/^/smokescreen: /'
[ "$fail" = 0 ] && { echo "agent egress proxy proof: PASSED"; exit 0; }
echo "agent egress proxy proof: FAILED (proxy log tail follows)"; tail -20 "$tmp/proxy.log"; exit 1

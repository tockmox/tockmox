#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# edge-deny-count.sh: how many deny lines the network's edge logged for one guest over a window, read from Loki.
#
#   edge-deny-count.sh --guest ADDRESS --since RFC3339 --until RFC3339 [--lines N]
#
# The air-gap lane's counter (TOCKMOX_UPSTREAM_DENY=edge in profiles/registry-mirror.sh): the segment's firewall
# blocks and logs, its log reaches Loki, and this counts the lines that name the guest's address AND the deny rule's
# label. Prints the count on stdout; with --lines N, also prints up to N of the matching lines on stderr, so a
# non-zero count names what the guest tried to reach.
#
# Where the log is, from the environment (site specifics never enter this tree):
#   TOCKMOX_EDGE_LOKI_URL       Loki's base URL, e.g. http://loki.monitoring.svc:3100
#   TOCKMOX_EDGE_LOKI_SELECTOR  the stream selector of the firewall's log, e.g. {job="syslog",host="edge"}
#   TOCKMOX_EDGE_DENY_MATCH     a fixed string every deny line of the cut rule carries (its label or description)
#
# Exit: 0 with a count (zero included); 2 refused input; 3 Loki did not answer or answered something that is not a
# count. A count is only worth reading after a positive control: a request the edge must refuse, counted within the
# same minute. The lane does that; this script only counts.
set -euo pipefail
GUEST=""; SINCE=""; UNTIL=""; LINES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --guest) GUEST="${2:?--guest needs an address}"; shift 2 ;;
    --since) SINCE="${2:?--since needs a time}"; shift 2 ;;
    --until) UNTIL="${2:?--until needs a time}"; shift 2 ;;
    --lines) LINES="${2:?--lines needs a number}"; shift 2 ;;
    *) echo "edge-deny-count: unknown argument: $1" >&2; exit 2 ;;
  esac
done
URL="${TOCKMOX_EDGE_LOKI_URL:-}"; SEL="${TOCKMOX_EDGE_LOKI_SELECTOR:-}"; MATCH="${TOCKMOX_EDGE_DENY_MATCH:-}"
[ -n "$URL" ] && [ -n "$SEL" ] && [ -n "$MATCH" ] || {
  echo "edge-deny-count: set TOCKMOX_EDGE_LOKI_URL, TOCKMOX_EDGE_LOKI_SELECTOR and TOCKMOX_EDGE_DENY_MATCH" >&2; exit 2; }
[[ "$GUEST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "edge-deny-count: --guest must be an IPv4 address: '$GUEST'" >&2; exit 2; }
[[ "$LINES" =~ ^[0-9]+$ ]] || { echo "edge-deny-count: --lines must be a number" >&2; exit 2; }
[[ "$URL" =~ ^https?://[^[:space:]]+$ ]] || { echo "edge-deny-count: TOCKMOX_EDGE_LOKI_URL must be http(s)" >&2; exit 2; }
case "$MATCH" in *\"*|*\\*) echo "edge-deny-count: the match may not hold a quote or a backslash" >&2; exit 2 ;; esac
[[ "$SEL" == \{*\} ]] || { echo "edge-deny-count: the selector is a stream selector, {...}" >&2; exit 2; }

python3 - "$URL" "$SEL" "$MATCH" "$GUEST" "$SINCE" "$UNTIL" "$LINES" <<'PY'
import json, sys, urllib.parse, urllib.request
from datetime import datetime
url, sel, match, guest, since, until, lines = sys.argv[1:8]

def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        sys.stderr.write(f"edge-deny-count: not an RFC3339 time: {s!r}\n"); sys.exit(2)
t0, t1 = ts(since), ts(until)
if not t1 > t0:
    sys.stderr.write("edge-deny-count: --until must be after --since\n"); sys.exit(2)
# The address as a whole token: 192.0.2.6 must not count 192.0.2.60's lines (filterlog is CSV).
pipe = f'|= "{match}" |~ "(^|[^0-9.]){guest.replace(".", "[.]")}([^0-9.]|$)"'
window = max(1, int(round(t1 - t0)))

def get(path, params):
    q = urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(f"{url.rstrip('/')}{path}?{q}", timeout=20) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"edge-deny-count: Loki did not answer ({type(e).__name__})\n"); sys.exit(3)

d = get("/loki/api/v1/query", {"query": f"sum(count_over_time({sel} {pipe} [{window}s]))", "time": str(int(t1))})
try:
    res = d["data"]["result"]
    n = int(float(res[0]["value"][1])) if res else 0
except (KeyError, IndexError, TypeError, ValueError):
    sys.stderr.write("edge-deny-count: Loki's answer is not a count\n"); sys.exit(3)
print(n)
if n and int(lines):
    d = get("/loki/api/v1/query_range", {"query": f"{sel} {pipe}", "start": str(int(t0 * 1e9)),
                                          "end": str(int(t1 * 1e9)), "limit": str(int(lines)), "direction": "forward"})
    for stream in (d.get("data") or {}).get("result") or []:
        for _, line in stream.get("values") or []:
            sys.stderr.write(f"  deny: {line[:300]}\n")
PY

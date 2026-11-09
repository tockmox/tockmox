#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for lib/edge-deny-count.sh, the air-gap lane's counter. No Loki: a stand-in answers on loopback with
# the shapes Loki's query API returns, and records each query it was asked, so a case can check what was asked as
# well as what came back. One PASS or FAIL line per case; exit 1 on any FAIL.
#
#   1. a count comes back as the number, zero included, and an empty result is zero
#   2. the query names the deny label and the guest's address as a whole token (192.0.2.6 is not 192.0.2.60),
#      over the window between --since and --until
#   3. with --lines, a non-zero count prints the matching lines, so the run names what the guest tried to reach
#   4. Loki not answering, or answering something that is not a count, is exit 3 (INFRA), never a zero
#   5. missing settings, a bad address, a quote in the match and a window that ends before it starts are refused (2)
#
# What it does not show: that the edge logs a deny line at all, or that Loki holds it. The lane's positive control
# is that proof, on the lab.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EDC="${HERE}/lib/edge-deny-count.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/edc-test.XXXXXX")"
trap 'kill "${SPID:-0}" 2>/dev/null; rm -rf "$W"' EXIT
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS+1)); }

cat > "$W/stub.py" <<'PY'
import http.server, json, sys, urllib.parse
W = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        with open(f"{W}/asked", "a") as fh:
            fh.write(json.dumps({"path": u.path, **{k: v[0] for k, v in q.items()}}) + "\n")
        mode = open(f"{W}/mode").read().strip()
        if mode == "garbage":
            body = b"<html>not loki</html>"
        elif u.path.endswith("/query_range"):
            body = json.dumps({"status": "success", "data": {"resultType": "streams", "result": [
                {"stream": {}, "values": [["1", "filterlog,block,CUT,in,4,192.0.2.6,203.0.113.9,tcp,443"]]}]}}).encode()
        elif mode == "empty":
            body = json.dumps({"status": "success", "data": {"resultType": "vector", "result": []}}).encode()
        else:
            body = json.dumps({"status": "success", "data": {"resultType": "vector",
                                                             "result": [{"metric": {}, "value": [1, mode]}]}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(f"{W}/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$W/stub.py" "$W" & SPID=$!
for _ in $(seq 1 50); do [ -s "$W/port" ] && break; sleep 0.1; done
PORT="$(cat "$W/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "FAIL the stand-in Loki did not start"; exit 1; }

export TOCKMOX_EDGE_LOKI_URL="http://127.0.0.1:${PORT}" TOCKMOX_EDGE_LOKI_SELECTOR='{job="syslog",host="edge"}' \
       TOCKMOX_EDGE_DENY_MATCH="CUT"
S=2026-11-09T01:00:00Z; U=2026-11-09T01:30:00Z
run() { : > "$W/asked"; set +e; OUT="$(bash "$EDC" "$@" 2>"$W/err")"; RC=$?; set -e 2>/dev/null; set +e; }

echo 3 > "$W/mode"; run --guest 192.0.2.6 --since "$S" --until "$U"
if [ "$RC" = 0 ] && [ "$OUT" = 3 ]; then pass "1: a count of 3 comes back as 3"; else fail "1: count 3 -> rc=$RC out=$OUT"; fi
echo 0 > "$W/mode"; run --guest 192.0.2.6 --since "$S" --until "$U"
if [ "$RC" = 0 ] && [ "$OUT" = 0 ]; then pass "1: zero is zero"; else fail "1: zero -> rc=$RC out=$OUT"; fi
echo empty > "$W/mode"; run --guest 192.0.2.6 --since "$S" --until "$U"
if [ "$RC" = 0 ] && [ "$OUT" = 0 ]; then pass "1: an empty result is zero"; else fail "1: empty -> rc=$RC out=$OUT"; fi

echo 1 > "$W/mode"; run --guest 192.0.2.6 --since "$S" --until "$U"
Q="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["query"])' "$W/asked")"
TQ="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["time"])' "$W/asked")"
case "$Q" in *'{job="syslog",host="edge"}'*'|= "CUT"'*'[1800s]'*) pass "2: the selector, the deny label and the 30-minute window are asked" ;;
  *) fail "2: query was: $Q" ;; esac
python3 - "$Q" <<'PY'; TOK=$?
import re, sys
pat = re.search(r'\|~ "(.*)"', sys.argv[1]).group(1)
ok = [",192.0.2.6,", "src=192.0.2.6 ", "192.0.2.6"]
no = [",192.0.2.60,", ",1192.0.2.6,", "192.0.2.61"]
sys.exit(0 if all(re.search(pat, s) for s in ok) and not any(re.search(pat, s) for s in no) else 1)
PY
if [ "$TOK" = 0 ]; then pass "2: the address matches as a whole token (192.0.2.6 yes, 192.0.2.60 and 1192.0.2.6 no)"; else fail "2: the address pattern is not a whole-token match: $Q"; fi
if [ "$TQ" = "$(python3 -c 'from datetime import datetime; print(int(datetime.fromisoformat("2026-11-09T01:30:00+00:00").timestamp()))')" ]; then pass "2: the count is taken at --until"; else fail "2: time was $TQ"; fi

echo 2 > "$W/mode"; run --guest 192.0.2.6 --since "$S" --until "$U" --lines 5
if [ "$RC" = 0 ] && [ "$OUT" = 2 ] && grep -q 'deny: filterlog,block,CUT' "$W/err" && grep -q '"path": "/loki/api/v1/query_range"' "$W/asked"; then pass "3: --lines prints the matching lines for a non-zero count"; else fail "3: rc=$RC out=$OUT err=$(head -c 200 "$W/err")"; fi
echo 0 > "$W/mode"; run --guest 192.0.2.6 --since "$S" --until "$U" --lines 5
if [ "$(grep -c query_range "$W/asked")" = 0 ]; then pass "3: a zero count asks for no lines"; else fail "3: lines were asked for a zero"; fi

echo garbage > "$W/mode"; run --guest 192.0.2.6 --since "$S" --until "$U"
if [ "$RC" = 3 ] && [ -z "$OUT" ]; then pass "4: an answer that is not a count is exit 3, not a zero"; else fail "4: garbage -> rc=$RC out=$OUT"; fi
TOCKMOX_EDGE_LOKI_URL="http://127.0.0.1:9" run --guest 192.0.2.6 --since "$S" --until "$U"
if [ "$RC" = 3 ] && [ -z "$OUT" ]; then pass "4: Loki not answering is exit 3, not a zero"; else fail "4: no Loki -> rc=$RC out=$OUT"; fi

TOCKMOX_EDGE_DENY_MATCH="" run --guest 192.0.2.6 --since "$S" --until "$U"
if [ "$RC" = 2 ]; then pass "5: a missing setting is refused"; else fail "5: missing setting -> rc=$RC"; fi
run --guest edge.example.org --since "$S" --until "$U"
if [ "$RC" = 2 ]; then pass "5: a guest that is not an address is refused"; else fail "5: bad guest -> rc=$RC"; fi
TOCKMOX_EDGE_DENY_MATCH='CUT"} or {x="' run --guest 192.0.2.6 --since "$S" --until "$U"
if [ "$RC" = 2 ]; then pass "5: a quote in the match is refused"; else fail "5: quote -> rc=$RC"; fi
run --guest 192.0.2.6 --since "$U" --until "$S"
if [ "$RC" = 2 ]; then pass "5: a window that ends before it starts is refused"; else fail "5: backwards window -> rc=$RC"; fi

[ "$FAILS" = 0 ] || exit 1

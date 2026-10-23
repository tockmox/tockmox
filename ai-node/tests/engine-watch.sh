#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tests of bin/tockmox-ai-node-engine-watch against a fake curl and a fake launchctl (no macOS, no
# engine, no root): an engine whose health path answers 503 on consecutive checks is restarted once
# and counted; a single 503, a 200 or no answer at all restarts nothing; a failed kickstart is not
# counted; the textfile carries the documented series.
#
#   ai-node/tests/engine-watch.sh
#
# Plain bash; exit 0 all passed, 1 a failure.
# shellcheck disable=SC2015  # "A && ok || bad" is the harness idiom; ok never fails
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
WATCH="$HERE/../bin/tockmox-ai-node-engine-watch"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3], got [$2]"; fi; }

[ -x "$WATCH" ] || { bad "the engine watch is installed in bin/ and executable"; echo "engine-watch: $pass passed, $fail failed"; exit 1; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
ROOT="$W/root"; FAKE="$W/fake"
mkdir -p "$ROOT/etc/engine-watch.d" "$ROOT/textfile" "$FAKE/codes"
printf 'AI_NODE_ID=example-mac\n' > "$ROOT/etc/facts.env"
printf '# a comment\ncom.example.ai-node.mlx-lm-8080\t8080\t/health\ncom.example.ai-node.mlx-lm-8082\t8082\t/health\nbroken\tnot-a-port\t/health\n' \
  > "$ROOT/etc/engine-watch.d/mlx-lm.tsv"

# curl: answers the code in $FAKE/codes/<port>, or 000 when the file is absent (nothing listening).
cat > "$FAKE/curl" <<'SH'
#!/bin/bash
url="${*: -1}"; port="${url#http://127.0.0.1:}"; port="${port%%/*}"
printf '%s\n' "$url" >> "$FAKE_DIR/curl.log"
if [ -f "$FAKE_DIR/codes/$port" ]; then printf '%s' "$(cat "$FAKE_DIR/codes/$port")"; else printf '000'; exit 7; fi
SH
# launchctl: records every call; fails when $FAKE/launchctl-fail exists.
cat > "$FAKE/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DIR/launchctl.log"
[ -e "$FAKE_DIR/launchctl-fail" ] && exit 5
exit 0
SH
chmod +x "$FAKE/curl" "$FAKE/launchctl"

run() { FAKE_DIR="$FAKE" PATH="$FAKE:$PATH" TOCKMOX_ROOT="$ROOT" TOCKMOX_LAUNCHCTL="$FAKE/launchctl" bash "$WATCH" >> "$W/watch.log" 2>&1; }
code() { printf '%s' "$2" > "$FAKE/codes/$1"; }
kicks() { if [ -f "$FAKE/launchctl.log" ]; then grep -c "kickstart -k system/$1\$" "$FAKE/launchctl.log"; else echo 0; fi; }
metric() { sed -n "s/^$1{\(.*\)} \(.*\)$/\1 \2/p" "$ROOT/textfile/engine-watch.prom" | grep -F "port=\"$2\"" | awk '{print $NF}'; }

echo "engine watch"
code 8080 200; code 8082 200
run; rc=$?
eq "it exits 0" "$rc" 0
eq "a healthy engine reads healthy" "$(metric tockmox_ai_node_engine_healthy 8080)" 1
eq "a healthy engine is not restarted" "$(kicks com.example.ai-node.mlx-lm-8080)" 0
eq "the restart counter starts at 0" "$(metric tockmox_ai_node_engine_restarts_total 8080)" 0
grep -q 'tockmox_ai_node_engine_healthy{ai_node="example-mac",label="com.example.ai-node.mlx-lm-8080",port="8080"} 1' "$ROOT/textfile/engine-watch.prom" \
  && ok "the series carry ai_node, label and port" || bad "the series carry ai_node, label and port" "$(cat "$ROOT/textfile/engine-watch.prom")"
grep -q '^tockmox_ai_node_engine_watch_last_run_timestamp_seconds{ai_node="example-mac"} [0-9]' "$ROOT/textfile/engine-watch.prom" \
  && ok "the last-run timestamp is written" || bad "the last-run timestamp is written"
grep -q 'not-a-port' "$W/watch.log" && ! grep -q 'broken' "$ROOT/textfile/engine-watch.prom" \
  && ok "a line with a bad port is skipped and logged" || bad "a line with a bad port is skipped and logged"
eq "the comment line is not probed" "$(grep -c . "$FAKE/curl.log")" 2
grep -q '^http://127.0.0.1:8080/health$' "$FAKE/curl.log" && ok "it asks 127.0.0.1 on the listed port and path" || bad "it asks 127.0.0.1 on the listed port and path" "$(cat "$FAKE/curl.log")"

code 8080 503
run
eq "one 503 marks the engine unhealthy" "$(metric tockmox_ai_node_engine_healthy 8080)" 0
eq "one 503 restarts nothing" "$(kicks com.example.ai-node.mlx-lm-8080)" 0
run
eq "a second consecutive 503 restarts the engine once" "$(kicks com.example.ai-node.mlx-lm-8080)" 1
eq "... and counts the restart" "$(metric tockmox_ai_node_engine_restarts_total 8080)" 1
eq "... and leaves the healthy sibling alone" "$(kicks com.example.ai-node.mlx-lm-8082)" 0
grep -q 'restarted com.example.ai-node.mlx-lm-8080: /health answered 503 on 2 consecutive checks' "$W/watch.log" \
  && ok "the restart is logged with its reason" || bad "the restart is logged with its reason" "$(tail -3 "$W/watch.log")"
run
eq "the strikes start over after a restart (a third 503 is strike one)" "$(kicks com.example.ai-node.mlx-lm-8080)" 1

code 8080 200; run; code 8080 503; run; code 8080 200; run; code 8080 503; run
eq "503s that are not consecutive restart nothing" "$(kicks com.example.ai-node.mlx-lm-8080)" 1

rm -f "$FAKE/codes/8080"; run; run; run
eq "no answer (down or loading) restarts nothing" "$(kicks com.example.ai-node.mlx-lm-8080)" 1
eq "... and reads unhealthy" "$(metric tockmox_ai_node_engine_healthy 8080)" 0

code 8082 503; touch "$FAKE/launchctl-fail"; run; run
eq "a failed kickstart is attempted" "$(kicks com.example.ai-node.mlx-lm-8082)" 1
eq "... and not counted as a restart" "$(metric tockmox_ai_node_engine_restarts_total 8082)" 0
rm -f "$FAKE/launchctl-fail"; run; run
eq "the next pair of 503s tries again and counts" "$(metric tockmox_ai_node_engine_restarts_total 8082)" 1
eq "the counter survives across runs" "$(metric tockmox_ai_node_engine_restarts_total 8080)" 1

: > "$ROOT/etc/engine-watch.d/mlx-lm.tsv"; run
! grep -q '^tockmox_ai_node_engine_healthy{' "$ROOT/textfile/engine-watch.prom" && grep -q last_run "$ROOT/textfile/engine-watch.prom" \
  && ok "an empty list writes only the last-run timestamp" || bad "an empty list writes only the last-run timestamp"
rm -rf "$ROOT/etc/engine-watch.d"; run; rc=$?
eq "no list at all is not an error" "$rc" 0
left=""; for f in "$ROOT"/textfile/engine-watch.prom.*; do [ -e "$f" ] && left="$left $f"; done
[ -z "$left" ] && ok "no temporary file is left behind" || bad "no temporary file is left behind" "$left"

echo "engine-watch: $pass passed, $fail failed"
[ "$fail" = 0 ]

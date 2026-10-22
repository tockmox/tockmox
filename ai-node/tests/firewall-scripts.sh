#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tests of the root-run firewall scripts the firewall role installs, rendered from their templates
# and run against a fake pfctl, a fake sysctl and a fake launchctl (no macOS, no ansible, no root):
#
#   pf-load.sh               the boot marker is removed first, and written only after the block rule is
#                            seen live; rules that were rolled back are not loaded again
#   pf-rollback.sh           loads the last confirmed ruleset, or a minimal one; never flushes to empty
#   start-when-firewalled    waits for a marker that holds this boot's kern.boottime, then execs
#   stop-listeners.sh        removes the marker and boots out every job that starts through the wrapper
#
#   ai-node/tests/firewall-scripts.sh
#
# Plain bash; exit 0 all passed, 1 a failure, 2 a tool is missing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROLE="$HERE/../roles/firewall"

for c in python3 shasum; do
  command -v "$c" >/dev/null 2>&1 || { echo "firewall-scripts: $c not on PATH" >&2; exit 2; }
done
python3 -c 'import jinja2' 2>/dev/null || { echo "firewall-scripts: python3 Jinja2 missing" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3], got [$2]"; fi; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
STATE="$W/state"; LIB="$W/libexec"; BIN="$W/bin"; PF="$W/pf"; LD="$W/launchd"
mkdir -p "$STATE" "$LIB" "$BIN" "$PF" "$LD" "$W/etc"

# ------------------------------------------------------------------ render the templates

python3 - "$ROLE/templates" "$LIB" "$W" <<'PY'
import sys, os, jinja2
tdir, lib, w = sys.argv[1:4]
state = w + "/state"
v = {
    "firewall_anchor_name": "com.apple/250.tockmox",
    "firewall_anchor_file": w + "/etc/allowlist",
    "firewall_state_dir": state,
    "firewall_pfctl": w + "/bin/pfctl",
    "firewall_sysctl": w + "/bin/sysctl",
    "firewall_launchctl": w + "/bin/launchctl",
    "firewall_boot_marker": state + "/pf-boot-ok",
    "firewall_last_confirmed": state + "/pf-last-confirmed.rules",
    "firewall_minimal_rules": state + "/pf-minimal.rules",
    "firewall_libexec": lib,
    "firewall_boot_label": "com.example.ai-node.pf",
    "firewall_rollback_minutes": 5,
    "firewall_start_wrapper": lib + "/start-when-firewalled",
    "firewall_launchd_dir": w + "/launchd",
    "tn_node_id": "example-mac",
    "tn_firewall": {"adminCidrs": ["203.0.113.0/24"], "adminPorts": [22], "enginePorts": [8080, 11434],
                    "exporterPorts": [9100, 9101], "engineAllowFrom": ["198.51.100.0/24"],
                    "exporterAllowFrom": ["198.51.100.0/24"]},
}
env = jinja2.Environment(loader=jinja2.FileSystemLoader(tdir), keep_trailing_newline=True,
                         undefined=jinja2.StrictUndefined)
for src, dst in (("pf-load.sh.j2", "pf-load.sh"), ("pf-rollback.sh.j2", "pf-rollback.sh"),
                 ("start-when-firewalled.sh.j2", "start-when-firewalled"),
                 ("stop-listeners.sh.j2", "stop-listeners.sh"),
                 ("minimal.conf.j2", "../state/pf-minimal.rules"), ("anchor.conf.j2", "../etc/allowlist")):
    out = os.path.join(lib, dst)
    open(out, "w").write(env.get_template(src).render(**v))
    if not dst.endswith(".rules") and dst != "../etc/allowlist":
        os.chmod(out, 0o755)
PY
check "every template renders" test -s "$LIB/pf-load.sh" -a -s "$LIB/pf-rollback.sh" -a -s "$LIB/start-when-firewalled" -a -s "$LIB/stop-listeners.sh" -a -s "$STATE/pf-minimal.rules"
for s in pf-load.sh pf-rollback.sh stop-listeners.sh; do
  check "$s starts with the shebang and passes sh -n" bash -c "head -n 1 '$LIB/$s' | grep -qx '#!/bin/sh' && sh -n '$LIB/$s'"
done
check "start-when-firewalled is a bash script and passes bash -n" bash -c "head -n 1 '$LIB/start-when-firewalled' | grep -qx '#!/bin/bash' && bash -n '$LIB/start-when-firewalled'"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck passes on the rendered scripts" bash -c "shellcheck -s sh '$LIB/pf-load.sh' '$LIB/pf-rollback.sh' '$LIB/stop-listeners.sh' && shellcheck -s bash '$LIB/start-when-firewalled'"
fi
check "no bash 4 feature in the wrapper (macOS ships bash 3.2)" bash -c "! grep -nE 'declare -A|mapfile|readarray|\\$\\{[A-Za-z_]+(,,|\\^\\^)|\\|&|coproc' '$LIB/start-when-firewalled'"

# ------------------------------------------------------------------ the fakes

cat > "$BIN/pfctl" <<'EOF'
#!/bin/bash
# A pfctl that keeps one anchor's rules in $PF/anchor.rules. Every call is logged.
PF="$FAKE_PF"
echo "pfctl $*" >> "$PF/calls.log"
anchor=""; mode=""; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a) anchor="$2"; shift 2 ;;
    -f) file="$2"; mode="${mode}f"; shift 2 ;;
    -F) mode="${mode}F"; shift 2 ;;
    -E) mode="${mode}E"; shift ;;
    -s) mode="${mode}s$2"; shift 2 ;;
    -sr) mode="${mode}sr"; shift ;;
    *) shift ;;
  esac
done
case "$mode" in
  sinfo) echo "Status: Enabled for 0 days 00:00:10           Debug: Urgent"; exit 0 ;;
  sr) if [ -n "$anchor" ]; then [ -s "$PF/anchor.rules" ] && cat "$PF/anchor.rules"; else echo 'anchor "com.apple/*" all'; fi; exit 0 ;;
  f) [ -e "$PF/fail-all" ] && { echo "pfctl: injected failure" >&2; exit 1; }
     [ -e "$PF/fail-$(basename "$file")" ] && { echo "pfctl: injected failure for $file" >&2; exit 1; }
     # expand the "name = "value"" macros the way pfctl does, then keep the rules
     if [ -n "$anchor" ]; then
       awk '/^[a-z_]+ = "/ { v = $0; sub(/^[^"]*"/, "", v); sub(/"$/, "", v); m[$1] = v; next }
            { for (k in m) gsub("[$]" k, m[k]); print }' "$file" | grep -E '^(pass|block)' > "$PF/anchor.rules"
       echo "$file" > "$PF/anchor.from"
     fi
     exit 0 ;;
  F) rm -f "$PF/anchor.rules"; exit 0 ;;
  E) exit 0 ;;
esac
exit 0
EOF
cat > "$BIN/sysctl" <<'EOF'
#!/bin/sh
[ "$1" = "-n" ] && [ "$2" = "kern.boottime" ] && echo "{ sec = $(cat "$FAKE_PF/boottime"), usec = 7 } Tue Nov 14 22:13:20 2023"
exit 0
EOF
cat > "$BIN/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >> "$FAKE_PF/launchctl.log"
case "$1" in
  print) [ -e "$FAKE_PF/loaded/${2#system/}" ] && exit 0; exit 113 ;;
  bootout) rm -f "$FAKE_PF/loaded/${2#system/}"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/pfctl" "$BIN/sysctl" "$BIN/launchctl"
export FAKE_PF="$PF"
mkdir -p "$PF/loaded"
echo 1700000000 > "$PF/boottime"
BOOT_ID='{ sec = 1700000000, usec = 7 }'

# a confirmed ruleset, and a new one that was applied but never confirmed
NEW_RULES="$W/etc/allowlist"
CONFIRMED="$STATE/pf-last-confirmed.rules"
cat > "$W/confirmed.rules" <<'EOF'
# the ruleset an administrator confirmed
pass in quick on lo0 all
pass in quick proto tcp from 192.0.2.0/24 to any port 22 flags any keep state
block return in quick proto tcp from any to any port { 22, 8080, 9100 }
EOF
cp "$STATE/pf-minimal.rules" "$W/minimal.rules"
reset() {
  rm -f "$STATE"/pf-* "$PF"/anchor.* "$PF"/fail-* "$PF"/calls.log "$PF"/launchctl.log
  cp "$W/minimal.rules" "$STATE/pf-minimal.rules"
  echo 1700000000 > "$PF/boottime"
}
anchor_has() { grep -q "$1" "$PF/anchor.rules" 2>/dev/null; }
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# ------------------------------------------------------------------ pf-load.sh

echo "pf-load.sh and the boot marker"
reset
printf '{ sec = 1699999999, usec = 7 }\n' > "$STATE/pf-boot-ok"      # the marker of the previous boot
touch "$PF/fail-allowlist"                                            # the load will fail
"$LIB/pf-load.sh" >/dev/null 2>&1; rc=$?
eq "a failed load exits 1" "$rc" 1
check "a stale marker is removed first, so a failed load leaves none" test ! -e "$STATE/pf-boot-ok"
check "a failed load records nothing as loaded" test ! -e "$STATE/pf-loaded.sha256"

reset
"$LIB/pf-load.sh" >/dev/null 2>&1; rc=$?
eq "a good load exits 0" "$rc" 0
eq "the marker holds this boot's kern.boottime (the braces only)" "$(cat "$STATE/pf-boot-ok")" "$BOOT_ID"
eq "pf-loaded.sha256 is the rendered file's hash" "$(cat "$STATE/pf-loaded.sha256")" "$(sha_of "$NEW_RULES")"
check "the block rule is live" anchor_has '^block'
check "the marker is written after the anchor was read back" bash -c "grep -n 'pfctl -a com.apple/250.tockmox -sr' '$PF/calls.log' | tail -n 1 | grep -q ."

# rules with no block rule are loaded but earn no marker
reset
cp "$NEW_RULES" "$W/etc/allowlist.keep"
grep -v '^block' "$W/etc/allowlist.keep" > "$NEW_RULES"
"$LIB/pf-load.sh" >/dev/null 2>&1; rc=$?
eq "a ruleset without a block rule exits 1" "$rc" 1
check "and gets no boot marker" test ! -e "$STATE/pf-boot-ok"
cp "$W/etc/allowlist.keep" "$NEW_RULES"

# --mark
reset
"$LIB/pf-load.sh" --mark >/dev/null 2>&1; rc=$?
eq "--mark with nothing live exits 1" "$rc" 1
check "--mark with nothing live writes no marker" test ! -e "$STATE/pf-boot-ok"
"$LIB/pf-load.sh" >/dev/null 2>&1
echo 1700000099 > "$PF/boottime"
"$LIB/pf-load.sh" --mark >/dev/null 2>&1
eq "--mark follows the boot that is running" "$(cat "$STATE/pf-boot-ok")" '{ sec = 1700000099, usec = 7 }'
rm -f "$PF/anchor.rules"
"$LIB/pf-load.sh" --mark >/dev/null 2>&1
check "--mark with the anchor gone removes the marker" test ! -e "$STATE/pf-boot-ok"

# rules that were rolled back are not applied again at boot
reset
cp "$W/confirmed.rules" "$CONFIRMED"
sha_of "$NEW_RULES" > "$STATE/pf-rolled-back"
"$LIB/pf-load.sh" >/dev/null 2>&1; rc=$?
eq "boot after a rollback exits 0" "$rc" 0
eq "it loaded the last confirmed ruleset, not the rolled-back file" "$(cat "$PF/anchor.from")" "$CONFIRMED"
check "it recorded nothing as loaded, so the next converge sees the difference" test ! -e "$STATE/pf-loaded.sha256"
check "the managed ports are still blocked" anchor_has '^block'
check "and the marker is there, for this boot" test "$(cat "$STATE/pf-boot-ok")" = "$BOOT_ID"
rm -f "$CONFIRMED"
"$LIB/pf-load.sh" >/dev/null 2>&1
eq "with nothing ever confirmed it loads the minimal ruleset" "$(cat "$PF/anchor.from")" "$STATE/pf-minimal.rules"

# ------------------------------------------------------------------ pf-rollback.sh

echo "pf-rollback.sh"
arm() {  # leave the state of an applied but unconfirmed administrator change
  reset
  cp "$NEW_RULES" "$W/applied.rules"
  grep -E '^(pass|block)' "$NEW_RULES" > "$PF/anchor.rules"
  sha_of "$NEW_RULES" > "$STATE/pf-loaded.sha256"
  sha_of "$NEW_RULES" > "$STATE/pf-pending.sha256"
  date +%s > "$STATE/pf-armed"
  printf '%s\n' "$BOOT_ID" > "$STATE/pf-boot-ok"
}

arm; cp "$W/confirmed.rules" "$CONFIRMED"
"$LIB/pf-rollback.sh" 0 >/dev/null 2>&1; rc=$?
eq "the rollback exits 0" "$rc" 0
eq "it loaded the last confirmed ruleset" "$(cat "$PF/anchor.from")" "$CONFIRMED"
check "the anchor holds the confirmed rules" bash -c "diff <(grep -E '^(pass|block)' '$W/confirmed.rules') '$PF/anchor.rules'"
check "the managed-port block is still live" anchor_has '^block'
check "the anchor was never flushed" bash -c "! grep -q -- ' -F ' '$PF/calls.log'"
eq "the rolled-back marker is the pending hash" "$(cat "$STATE/pf-rolled-back")" "$(sha_of "$NEW_RULES")"
check "pf-loaded.sha256 is gone, so the next converge reloads" test ! -e "$STATE/pf-loaded.sha256"
eq "the boot marker is kept while a block rule is live" "$(cat "$STATE/pf-boot-ok")" "$BOOT_ID"

arm
"$LIB/pf-rollback.sh" 0 >/dev/null 2>&1; rc=$?
eq "with nothing ever confirmed the rollback still exits 0" "$rc" 0
eq "it loaded the minimal ruleset" "$(cat "$PF/anchor.from")" "$STATE/pf-minimal.rules"
check "the anchor is not empty" test -s "$PF/anchor.rules"
check "loopback is passed" anchor_has '^pass in quick on lo0'
check "port 22 is open to anyone" anchor_has 'from any to any port { 22 }'
check "the managed engine and exporter ports are blocked" bash -c "grep -q '^block return in quick proto tcp from any to any port { 8080, 9100, 9101, 11434 }' '$PF/anchor.rules'"
check "the anchor was never flushed" bash -c "! grep -q -- ' -F ' '$PF/calls.log'"

arm; cp "$W/confirmed.rules" "$CONFIRMED"
touch "$PF/fail-pf-last-confirmed.rules"
"$LIB/pf-rollback.sh" 0 >/dev/null 2>&1
eq "a confirmed ruleset that will not load falls back to the minimal one" "$(cat "$PF/anchor.from")" "$STATE/pf-minimal.rules"

arm; cp "$W/confirmed.rules" "$CONFIRMED"
touch "$PF/fail-all"
before="$(cat "$PF/anchor.rules")"
"$LIB/pf-rollback.sh" 0 >/dev/null 2>&1; rc=$?
eq "if nothing can be loaded the rollback exits 1" "$rc" 1
eq "and leaves the anchor as it was, not empty" "$(cat "$PF/anchor.rules")" "$before"
check "it does not claim a rollback happened" test ! -e "$STATE/pf-rolled-back"

arm; cp "$W/confirmed.rules" "$CONFIRMED"
sleep 1; touch "$STATE/pf-confirm"
"$LIB/pf-rollback.sh" 0 >/dev/null 2>&1; rc=$?
eq "a change confirmed after it was armed is left alone (exit 0)" "$rc" 0
check "and no rules were loaded" bash -c "! grep -q -- ' -f ' '$PF/calls.log'"
check "and no rolled-back marker was written" test ! -e "$STATE/pf-rolled-back"

# ------------------------------------------------------------------ start-when-firewalled

echo "start-when-firewalled"
SWF="$LIB/start-when-firewalled"
reset
"$SWF" >/dev/null 2>&1; rc=$?
eq "no program is a usage error (64)" "$rc" 64
check "no marker: the program does not start" bash -c "! timeout 3 '$SWF' /bin/echo started 2>/dev/null | grep -q started"
printf '{ sec = 1699999999, usec = 7 }\n' > "$STATE/pf-boot-ok"
check "a marker of another boot: the program does not start" bash -c "! timeout 3 '$SWF' /bin/echo started 2>/dev/null | grep -q started"
# it starts once the marker for this boot appears
( sleep 1; printf '%s\n' "$BOOT_ID" > "$STATE/pf-boot-ok" ) &
out="$(timeout 10 "$SWF" /bin/echo started with args 2>/dev/null | tail -n 1)"; rc=$?
wait
eq "it starts, with its arguments, once the marker matches" "$out" "started with args"
eq "and the exit code is the program's" "$rc" 0
printf '%s\n' "$BOOT_ID" > "$STATE/pf-boot-ok"
timeout 10 "$SWF" /bin/sh -c 'exit 7' >/dev/null 2>&1; rc=$?
eq "exec: the program's exit code comes through" "$rc" 7
echo 1700000123 > "$PF/boottime"
check "a reboot (a new kern.boottime) invalidates the marker" bash -c "! timeout 3 '$SWF' /bin/echo started 2>/dev/null | grep -q started"
echo 1700000000 > "$PF/boottime"
rm -f "$STATE/pf-boot-ok"
check "removing the marker stops the next start" bash -c "! timeout 3 '$SWF' /bin/echo started 2>/dev/null | grep -q started"
# the program replaces the wrapper (exec): the process that was the wrapper is now the program
printf '%s\n' "$BOOT_ID" > "$STATE/pf-boot-ok"
"$SWF" /bin/sleep 5 >/dev/null 2>&1 &
pid=$!
sleep 1
eq "the program is exec'd: that pid is now the program, not the wrapper" "$(ps -o comm= -p "$pid" | tr -d ' ')" sleep
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

# ------------------------------------------------------------------ stop-listeners.sh

echo "stop-listeners.sh"
reset
for l in com.example.ai-node.ollama com.example.ai-node.node-exporter com.example.ai-node.macmon com.example.ai-node.converge; do
  : > "$PF/loaded/$l"
done
for l in ollama node-exporter macmon; do
  printf '<plist><array><string>%s</string><string>/opt/homebrew/bin/x</string></array></plist>\n' "$LIB/start-when-firewalled" > "$LD/com.example.ai-node.$l.plist"
done
printf '<plist><array><string>/opt/tockmox/bin/tockmox-ai-node-converge</string></array></plist>\n' > "$LD/com.example.ai-node.converge.plist"
printf '%s\n' "$BOOT_ID" > "$STATE/pf-boot-ok"
"$LIB/stop-listeners.sh" >/dev/null 2>&1; rc=$?
eq "stop-listeners exits 0" "$rc" 0
check "the marker is removed" test ! -e "$STATE/pf-boot-ok"
check "the engine is booted out" test ! -e "$PF/loaded/com.example.ai-node.ollama"
check "node_exporter is booted out" test ! -e "$PF/loaded/com.example.ai-node.node-exporter"
check "macmon is booted out" test ! -e "$PF/loaded/com.example.ai-node.macmon"
check "the converge job, which does not start through the wrapper, is left alone" test -e "$PF/loaded/com.example.ai-node.converge"
"$LIB/stop-listeners.sh" >/dev/null 2>&1; rc=$?
eq "run again with nothing loaded it still exits 0" "$rc" 0

echo
echo "firewall-scripts: $pass passed, $fail failed"
[ "$fail" = 0 ]

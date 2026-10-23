#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the whole ai-node playbook, end to end, on Linux, against test doubles for the macOS commands.
#
#   ai-node/tests/e2e/run.sh            # all scenarios
#   ai-node/tests/e2e/run.sh KEEP=1     # leave the work directory for inspection
#
# WHAT THIS PROVES: that the play loads, that the Jinja in every role renders on real inputs, that
# the roles run in the order the design needs (firewall first), that every service gets a
# well-formed plist with the arguments the engine needs, that a second run changes nothing, and that
# the failure paths (a model that does not match its pin, an administrator change nobody confirms,
# an empty administrator list, a Linux node) stop the converge with a sentence that names the cause.
#
# WHAT IT DOES NOT PROVE: anything about macOS itself. The doubles under shims/ answer the way the
# real commands were documented to answer; whether they really do is the "unproven on macOS" list
# in the report.
#
# HOW. It needs root and a Linux mount namespace. Inside `unshare -m` it overlays /usr/bin and
# /usr/sbin with the doubles, mounts tmpfs on every path a Mac role writes (/Library/LaunchDaemons,
# /opt/tockmox, /opt/homebrew, /etc/pf.anchors, ...), adds the two accounts to a private copy of
# /etc/passwd, and runs ansible-playbook with a fact module that says "macOS 27 on arm64, 256 GiB".
# Nothing outside the namespace changes. Without root or unshare it exits 2 (skipped).
# shellcheck disable=SC2015  # "A && ok || bad" is the harness idiom; ok never fails
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AI="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$AI/.." && pwd)"
EXAMPLE="$AI/examples/site/ai-nodes/example-mac"

if [ "${TOCKMOX_E2E_INNER:-}" != 1 ]; then
  skip() { echo "e2e: skipped: $*" >&2; exit 2; }
  [ "$(uname -s)" = Linux ] || skip "needs Linux (mount namespaces)"
  [ "$(id -u)" = 0 ] || skip "needs root"
  for c in unshare ansible-playbook python3 mount; do command -v "$c" >/dev/null 2>&1 || skip "needs $c"; done
  unshare -m true 2>/dev/null || skip "unshare -m is not permitted here"
  WORK="$(mktemp -d)"
  created=""
  for d in /Library/LaunchDaemons /Users /opt/homebrew /opt/tockmox /etc/pf.anchors /etc/ssh/sshd_config.d \
           /usr/local/libexec /var/db/tockmox-ai-node /var/lib/tockmox-sim /var/lib/tockmox-sim-bin; do
    if [ ! -d "$d" ]; then mkdir -p "$d" && created="$d $created"; fi
  done
  for a in "$@"; do [ "$a" = KEEP=1 ] && KEEP=1; done
  TOCKMOX_E2E_INNER=1 E2E_WORK="$WORK" unshare -m --propagation private "$0" "$@"
  rc=$?
  for d in $created; do rmdir "$d" 2>/dev/null; done
  rmdir /opt/homebrew /opt/tockmox 2>/dev/null
  if [ "${KEEP:-0}" = 1 ]; then echo "e2e: work directory kept: $WORK" >&2; else rm -rf "$WORK"; fi
  exit "$rc"
fi

# ----------------------------------------------------------------- inside the namespace
WORK="$E2E_WORK"
# Listeners the launchctl shim starts for Ollama jobs must not outlive the run.
# shellcheck disable=SC2154  # f is set by the loop inside the trap string
trap 'for f in /var/lib/tockmox-sim/loaded/*.pid; do [ -e "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; true' EXIT
S=/var/lib/tockmox-sim
OUT="$WORK/out"; mkdir -p "$OUT"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$2"; fi; }

for d in /Library/LaunchDaemons /Users /opt/homebrew /opt/tockmox /etc/pf.anchors /etc/ssh/sshd_config.d \
         /usr/local/libexec /var/db/tockmox-ai-node /var/lib/tockmox-sim /var/lib/tockmox-sim-bin; do
  mount -t tmpfs tmpfs "$d" || { echo "cannot mount tmpfs on $d" >&2; exit 2; }
done
mkdir -p /Users/tockmox /Users/inference
cp "$HERE/shims/generic" "$HERE/shims/python-shim" "$HERE/shims/hf-shim" "$HERE/shims/ollama-shim" /var/lib/tockmox-sim-bin/
chmod +x /var/lib/tockmox-sim-bin/*

for pair in "/usr/bin:defaults pmset dscl mdutil tmutil fdesetup sw_vers caffeinate ps launchctl" \
            "/usr/sbin:netstat lsof sshd visudo sysctl dseditgroup pfctl"; do
  dir="${pair%%:*}"; names="${pair#*:}"
  up="$WORK/up$(echo "$dir" | tr / _)"; wk="$WORK/wk$(echo "$dir" | tr / _)"; mkdir -p "$up" "$wk"
  for n in $names; do ln -s "$HERE/shims/shim.sh" "$up/$n"; done
  mount -t overlay overlay -o "lowerdir=$dir,upperdir=$up,workdir=$wk" "$dir" || { echo "cannot overlay $dir" >&2; exit 2; }
done
mkdir -p /opt/homebrew/bin
ln -s "$HERE/shims/shim.sh" /opt/homebrew/bin/brew

cp /etc/passwd "$WORK/passwd"; cp /etc/group "$WORK/group"
printf 'tockmox:x:501:50:tockmox:/Users/tockmox:/bin/bash\ninference:x:502:50:inference:/var/empty:/usr/bin/false\n' >> "$WORK/passwd"
printf 'wheel:x:80:\nadmin:x:81:tockmox\n' >> "$WORK/group"
mount --bind "$WORK/passwd" /etc/passwd; mount --bind "$WORK/group" /etc/group
mkdir -p "$S/users/tockmox" "$S/users/inference" "$S/pf"; touch "$S/users/tockmox/admin"

# The node's two files. The Ollama revisions in the example are placeholders; the double stores a
# manifest of known bytes, so pin the digest of those bytes for the passing runs.
NODE="$WORK/node"; mkdir -p "$NODE"
cp "$EXAMPLE/ai-node.yaml" "$NODE/ai-node.yaml"
python3 - "$EXAMPLE/desired.yaml" "$NODE/desired.yaml" <<'PY'
import hashlib, sys
s = open(sys.argv[1]).read()
for ref, fake in (("example-coder:30b", "1" * 64), ("example-embed:latest", "2" * 64)):
    real = hashlib.sha256(("manifest:%s\n" % ref).encode()).hexdigest()
    s = s.replace("sha256:" + fake, "sha256:" + real)
open(sys.argv[2], "w").write(s)
PY
cp "$EXAMPLE/desired.yaml" "$WORK/desired-unpinned.yaml"

# An administrator's SSH session, as pfctl -ss would show it once the rules are in.
printf 'all tcp 192.0.2.10:22 <- 203.0.113.9:51234       ESTABLISHED:ESTABLISHED\n' > "$S/pf/states"

play() {  # name, node dir, extra ansible args...
  local name="$1" nd="$2"; shift 2
  # The converger hands the playbook ONE namespaced, !unsafe extra-var built from the two site
  # files (playbooks/site_vars.py); so does this.
  python3 "$AI/playbooks/site_vars.py" "$nd/ai-node.yaml" "$nd/desired.yaml" "$OUT/$name.vars.yml" || return 2
  ANSIBLE_CONFIG="$AI/ansible.cfg" ANSIBLE_LIBRARY="$HERE/library" ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i 'localhost,' -c local "$AI/playbooks/ai-node.yml" \
      -e "@$OUT/$name.vars.yml" \
      -e tockmox_ai_node_id=example-mac -e "tockmox_node_dir=$nd" -e "tockmox_toolkit_dir=$REPO" \
      -e tockmox_admin_user=admin -e tockmox_converge_interval=900 "$@" > "$OUT/$name.log" 2>&1
}
recap() { sed -n 's/^localhost *: *//p' "$OUT/$1.log" | tail -1; }
label() { echo "com.tockmox.ai-node.$1"; }
plist_get() { python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(" ".join(d["ProgramArguments"]) if sys.argv[2]=="args" else d.get(sys.argv[2]))' "/Library/LaunchDaemons/$(label "$1").plist" "$2"; }

echo "scenario 1: first converge of the example node"
play first "$NODE" ; rc=$?
[ "$rc" = 0 ] && ok "first converge exits 0" || bad "first converge exits 0" "rc=$rc; see $OUT/first.log; tail: $(tail -15 "$OUT/first.log" | tr '\n' '|')"
echo "       recap: $(recap first)"

fw=$(grep -n 'TASK \[firewall' "$OUT/first.log" | head -1 | cut -d: -f1)
ex=$(grep -n 'TASK \[exporters' "$OUT/first.log" | head -1 | cut -d: -f1)
en=$(grep -n 'TASK \[engine_mlx_lm' "$OUT/first.log" | head -1 | cut -d: -f1)
[ -n "$fw" ] && [ -n "$ex" ] && [ -n "$en" ] && [ "$fw" -lt "$ex" ] && [ "$ex" -lt "$en" ] && ok "firewall runs before exporters and engines" || bad "firewall runs before exporters and engines" "fw=$fw ex=$ex en=$en"

for l in node-exporter macmon ollama mlx-lm-8080 mlx-lm-8082 converge facts wired-limit maxfiles caffeinate; do
  check "service $l is loaded" "[ -e $S/loaded/$(label $l) ]"
done
check "the pf boot job is written but not loaded here" "[ -e /Library/LaunchDaemons/$(label pf).plist ] && [ ! -e $S/loaded/$(label pf) ]"
check "mlx-lm-8080 serves the pinned snapshot" "plist_get mlx-lm-8080 args | grep -q -- '--model /opt/tockmox/models/hf/hub/models--mlx-community--Example-27B-8bit/snapshots/0123456789abcdef0123456789abcdef01234567'"
check "mlx-lm-8080 listens on all interfaces once pf is verified" "plist_get mlx-lm-8080 args | grep -q -- '--host 0.0.0.0 --port 8080'"
check "mlx-lm runs as the service account" "[ \"\$(plist_get mlx-lm-8080 UserName)\" = inference ]"
check "mlx-lm is offline" "python3 -c 'import plistlib;d=plistlib.load(open(\"/Library/LaunchDaemons/$(label mlx-lm-8080).plist\",\"rb\"));assert d[\"EnvironmentVariables\"][\"HF_HUB_OFFLINE\"]==\"1\"'"
check "ollama listens on its port" "python3 -c 'import plistlib;d=plistlib.load(open(\"/Library/LaunchDaemons/$(label ollama).plist\",\"rb\"));assert d[\"EnvironmentVariables\"][\"OLLAMA_HOST\"]==\"0.0.0.0:11434\"'"
check "node_exporter reads the textfile directory" "plist_get node-exporter args | grep -q -- '--collector.textfile.directory=/opt/tockmox/textfile'"
check "the converge job runs as the converge account every 900 s" "[ \"\$(plist_get converge UserName)\" = tockmox ] && [ \"\$(plist_get converge StartInterval)\" = 900 ]"
check "the facts job runs as the service account every 60 s" "[ \"\$(plist_get facts UserName)\" = inference ] && [ \"\$(plist_get facts StartInterval)\" = 60 ]"
check "the wired limit is set live" "[ \"\$(cat $S/iogpu)\" = 229376 ]"
check "the pf anchor blocks the managed ports for everyone else" "grep -q '^block return in quick proto tcp from any to any port' /etc/pf.anchors/com.tockmox.ai-node.allowlist"
check "the anchor admits the administrators to port 22 with flags any" "grep -q 'from <tockmox_admin> to any port \$admin_ports flags any' /etc/pf.anchors/com.tockmox.ai-node.allowlist"
check "the anchor is loaded into the sub-anchor, /etc/pf.conf untouched" "[ -s $S/pf/anchor.rules ] && ! grep -q 'pf.conf' <(grep -h 'pfctl -f' $S/calls.log | grep -v 'pfctl -f /etc/pf.conf') "
check "the rollback was stood down after the session confirmed" "[ ! -e $S/loaded/$(label pf-rollback) ] && [ -s /var/db/tockmox-ai-node/pf-admin-sig ]"
check "the hf snapshot is on disk and stamped" "[ -d /opt/tockmox/models/hf/hub/models--mlx-community--Example-27B-8bit/snapshots/0123456789abcdef0123456789abcdef01234567 ] && [ -s /opt/tockmox/models/.tockmox/verified/models--mlx-community--Example-27B-8bit@0123456789abcdef0123456789abcdef01234567.json ]"
check "both ollama manifests are stored" "[ -s /opt/tockmox/models/ollama/manifests/registry.ollama.ai/library/example-coder/30b ] && [ -s /opt/tockmox/models/ollama/manifests/registry.ollama.ai/library/example-embed/latest ]"
check "the facts table lists all four models" "[ \$(wc -l < /opt/tockmox/var/models-present.tsv) = 4 ]"
check "every fetch is in the audit log" "[ \$(grep -c '\"verdict\": \"verified\"' /opt/tockmox/var/audit/model-updates.jsonl) = 4 ]"
check "root-only facts were written" "[ \"\$(cat /opt/tockmox/var/rootfacts.d/pf_anchor)\" = 1 ] && [ \"\$(cat /opt/tockmox/var/rootfacts.d/filevault_on)\" = 0 ] && [ \"\$(cat /opt/tockmox/var/rootfacts.d/remote_login)\" = 1 ]"
check "facts.env tells the facts writer what to expect" "grep -q '^FILEVAULT_POSTURE=off' /opt/tockmox/etc/facts.env && grep -q '^WIRED_LIMIT_MIB=229376' /opt/tockmox/etc/facts.env"
check "the sudoers fragment is in place" "grep -q '^tockmox ALL=(ALL) NOPASSWD: ALL' /etc/sudoers.d/tockmox-ai-node"
check "the converger and the facts writer are installed" "[ -x /opt/tockmox/bin/tockmox-ai-node-converge ] && [ -x /opt/tockmox/bin/tockmox-ai-node-facts ]"
check "models belong to the service account, the secrets directory to the converge account" "[ \"\$(stat -c %U /opt/tockmox/models)\" = inference ] && [ \"\$(stat -c %U /opt/tockmox/secrets)\" = tockmox ] && [ \"\$(stat -c %a /opt/tockmox/secrets)\" = 711 ]"
check "sleep is held off" "grep -q 'pmset -a disablesleep 1' $S/calls.log"
check "automatic OS install is off" "[ \"\$(cat $S/defaults/_Library_Preferences_com.apple.SoftwareUpdate/AutomaticallyInstallMacOSUpdates)\" = 0 ]"
check "Spotlight is off" "[ -e $S/spotlight-off ]"
check "sshd is limited to the administrator and the converge account" "grep -q '^AllowUsers admin tockmox' /etc/ssh/sshd_config.d/100-tockmox-ai-node.conf"

echo "scenario 2: a second converge changes nothing"
play second "$NODE"; rc=$?
[ "$rc" = 0 ] && ok "second converge exits 0" || bad "second converge exits 0" "rc=$rc; tail: $(tail -15 "$OUT/second.log" | tr '\n' '|')"
r="$(recap second)"; echo "       recap: $r"
case "$r" in *"changed=0"*) ok "second converge reports changed=0" ;; *) bad "second converge reports changed=0" "$r"; grep -B1 -A2 '^changed:' "$OUT/second.log" | head -40 ;; esac

echo "scenario 3: a model that does not match its pin stops the converge"
mkdir -p "$WORK/node-unpinned"; cp "$NODE/ai-node.yaml" "$WORK/node-unpinned/"; cp "$WORK/desired-unpinned.yaml" "$WORK/node-unpinned/desired.yaml"
rm -rf /opt/tockmox/models/ollama/manifests
play unpinned "$WORK/node-unpinned"; rc=$?
[ "$rc" != 0 ] && ok "a digest mismatch fails the converge" || bad "a digest mismatch fails the converge"
check "it says which model and why" "grep -q 'did not match its pin' $OUT/unpinned.log"
check "the mismatched model was removed again" "[ ! -e /opt/tockmox/models/ollama/manifests/registry.ollama.ai/library/example-coder/30b ]"
check "the refusal is in the audit log" "grep -q 'verify_failed' /opt/tockmox/var/audit/model-updates.jsonl"
check "the root-only facts were still refreshed after the failure" "[ -e /opt/tockmox/var/rootfacts.d/pf_anchor ]"

echo "scenario 4: refusals before anything is touched"
mkdir -p "$WORK/node-noadmin"; cp "$NODE/desired.yaml" "$WORK/node-noadmin/"
sed 's|adminCidrs: \[203.0.113.0/24\]|adminCidrs: []|' "$NODE/ai-node.yaml" > "$WORK/node-noadmin/ai-node.yaml"
play noadmin "$WORK/node-noadmin"; rc=$?
[ "$rc" != 0 ] && grep -q 'access.adminCidrs must list at least one network' "$OUT/noadmin.log" && ok "an empty administrator list is refused by name" || bad "an empty administrator list is refused by name" "rc=$rc"
mkdir -p "$WORK/node-world"; cp "$NODE/desired.yaml" "$WORK/node-world/"
sed 's|adminCidrs: \[203.0.113.0/24\]|adminCidrs: [0.0.0.0/0]|' "$NODE/ai-node.yaml" > "$WORK/node-world/ai-node.yaml"
play world "$WORK/node-world"; rc=$?
[ "$rc" != 0 ] && grep -q 'none may be /0' "$OUT/world.log" && ok "a /0 administrator network is refused" || bad "a /0 administrator network is refused" "rc=$rc"
mkdir -p "$WORK/node-linux"; cp "$NODE/desired.yaml" "$WORK/node-linux/"
sed 's|family: macos|family: linux|' "$NODE/ai-node.yaml" > "$WORK/node-linux/ai-node.yaml"
play linux "$WORK/node-linux"; rc=$?
[ "$rc" != 0 ] && grep -q 'Linux support is phase 6' "$OUT/linux.log" && ok "a Linux node stops with the phase 6 sentence" || bad "a Linux node stops with the phase 6 sentence" "rc=$rc"
mkdir -p "$WORK/node-bool"; cp "$NODE/desired.yaml" "$WORK/node-bool/"
sed -e 's|filevault: "off"|filevault: off|' -e 's|spotlight: "off"|spotlight: off|' "$NODE/ai-node.yaml" > "$WORK/node-bool/ai-node.yaml"
play bool "$WORK/node-bool"; rc=$?
[ "$rc" != 0 ] && grep -q 'os.filevault: must be one of' "$OUT/bool.log" && ok "an unquoted off (a YAML boolean) is refused by name before anything runs" || bad "an unquoted off (a YAML boolean) is refused by name before anything runs" "rc=$rc; $(tail -5 "$OUT/bool.log" | tr '\n' '|')"
mkdir -p "$WORK/node-badwired"; cp "$NODE/desired.yaml" "$WORK/node-badwired/"
sed 's|wiredLimitMiB: 229376|wiredLimitMiB: 262000|' "$NODE/ai-node.yaml" > "$WORK/node-badwired/ai-node.yaml"
play badwired "$WORK/node-badwired"; rc=$?
[ "$rc" != 0 ] && grep -q 'must be between' "$OUT/badwired.log" && ok "a wired limit above RAM minus the reserve is refused" || bad "a wired limit above RAM minus the reserve is refused" "rc=$rc"

echo "scenario 5: an administrator change nobody confirms leaves the rollback armed and fails"
rm -f /var/db/tockmox-ai-node/pf-admin-sig "$S/pf/anchor.rules" "$S/pf/anchor.loaded" /var/db/tockmox-ai-node/pf-loaded.sha256 "$S/pf/states"
play unconfirmed "$NODE" -e firewall_confirm_wait_seconds=5; rc=$?
[ "$rc" != 0 ] && grep -q 'no administrator session or confirmation was' "$OUT/unconfirmed.log" && ok "an unconfirmed administrator change fails the converge" || bad "an unconfirmed administrator change fails the converge" "rc=$rc"
check "the rollback is armed, as a job launchd can see" "[ -e $S/loaded/$(label pf-rollback) ] && grep -q 'launchctl print system/$(label pf-rollback)' $S/calls.log"
check "the armed rollback runs pf-rollback.sh with the configured minutes" "python3 -c 'import plistlib,sys; a=plistlib.load(open(sys.argv[1],\"rb\"))[\"ProgramArguments\"]; sys.exit(0 if a[1].endswith(\"/pf-rollback.sh\") and a[2]==\"5\" else 1)' $S/loaded/$(label pf-rollback)"

echo "scenario 6: llama-server and a split model"
mkdir -p "$WORK/node-llama"; cp "$NODE/ai-node.yaml" "$WORK/node-llama/"
python3 - "$NODE/desired.yaml" "$WORK/node-llama/desired.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
rev = "ab" * 20
d["instances"].append({"id": "llama-server-8090", "engine": "llama-server", "port": 8090, "gateway": "production",
    "auth": {"secretRef": "example-llama-key"},
    "models": [{"model": "example-org/Example-7B-GGUF", "aliases": ["local-small"], "contextTokens": 8192,
                "artifact": {"kind": "huggingface", "ref": "example-org/Example-7B-GGUF", "revision": rev}}]})
d["modelsPresent"].append({"model": "example-org/Example-7B-GGUF", "stage": "promoted",
    "artifact": {"kind": "huggingface", "ref": "example-org/Example-7B-GGUF", "revision": rev}})
d["firewall"]["enginePorts"] = sorted(d["firewall"]["enginePorts"] + [8090])
open(sys.argv[2], "w").write("# GENERATED test variant\n" + yaml.safe_dump(d, sort_keys=False))
PY
mkdir -p /opt/tockmox/secrets; printf 'k' > /opt/tockmox/secrets/example-llama-key
printf 'all tcp 192.0.2.10:22 <- 203.0.113.9:51234       ESTABLISHED:ESTABLISHED\n' > "$S/pf/states"
play llama "$WORK/node-llama"; rc=$?
[ "$rc" = 0 ] && ok "a node with a llama-server instance converges" || bad "a node with a llama-server instance converges" "rc=$rc; $(tail -15 "$OUT/llama.log" | tr '\n' '|')"
check "llama-server is started on the one GGUF in the snapshot" "plist_get llama-server-8090 args | grep -q -- '--model /opt/tockmox/models/hf/hub/models--example-org--Example-7B-GGUF/snapshots/abababababababababababababababababababab/Example-7B-Q4_K_M.gguf'"
check "llama-server gets the context and the key file" "plist_get llama-server-8090 args | grep -q -- '--ctx-size 8192' && plist_get llama-server-8090 args | grep -q -- '--api-key-file /opt/tockmox/secrets/example-llama-key'"

echo "scenario 7: an instance that is no longer wanted is taken away"
play back "$NODE"; rc=$?
[ "$rc" = 0 ] && ok "converging back to the smaller node succeeds" || bad "converging back to the smaller node succeeds" "rc=$rc"
check "the llama-server daemon is unloaded and its plist gone" "[ ! -e $S/loaded/$(label llama-server-8090) ] && [ ! -e /Library/LaunchDaemons/$(label llama-server-8090).plist ]"

# ---- scenarios 8 to 10: the allowlist is what lets an engine listen
LIBEXEC=/usr/local/libexec/tockmox-ai-node
MARK=/var/db/tockmox-ai-node/pf-boot-ok
listening() { python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$1" 2>/dev/null; }
wait_listening() {  # port seconds
  local i=0; while [ "$i" -lt $(( $2 * 5 )) ]; do listening "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1
}
# What a restart does to the node: every process is gone, launchd loads the jobs that start
# through the wrapper (the rest are not under test), pf is empty and off, and the clock of the boot
# differs. The marker on disk is the one the previous boot wrote.
restart_node() {  # new kern.boottime sec
  local f
  for f in "$S"/loaded/*.pid; do [ -e "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  sleep 1
  rm -f "$S"/loaded/* "$S/pf/anchor.rules" "$S/pf/anchor.loaded" "$S/pf/enabled"
  echo "$1" > "$S/boottime"
  for f in /Library/LaunchDaemons/*.plist; do
    grep -q start-when-firewalled "$f" || continue
    launchctl bootstrap system "$f"
  done
}

echo "scenario 8: after a restart, nothing listens until the allowlist is in force"
play settle "$NODE"; rc=$?
[ "$rc" = 0 ] && ok "the node is converged before the restart" || bad "the node is converged before the restart" "rc=$rc; $(tail -12 "$OUT/settle.log" | tr '\n' '|')"
check "the engine listens on 11434 before the restart" "wait_listening 11434 5"
check "every engine and exporter plist starts through the wrapper" "for n in ollama node-exporter macmon mlx-lm-8080 mlx-lm-8082; do plist_get \$n args | grep -q '^$LIBEXEC/start-when-firewalled ' || exit 1; done"
check "the converge job does not" "! plist_get converge args | grep -q start-when-firewalled"
check "the boot marker holds the boot id" "grep -qx '{ sec = 1700000000, usec = 0 }' $MARK"
restart_node 1700000500
sleep 4
check "after the restart, with pf not loaded, the engine does not listen" "! listening 11434"
check "node_exporter does not listen" "! listening 9100"
check "macmon does not listen" "! listening 9101"
check "mlx-lm does not listen" "! listening 8080"
check "the wrappers are alive and waiting" "[ \$(pgrep -fc 'bash $LIBEXEC/start-when-firewalled') -ge 4 ]"
check "the previous boot's marker is on disk and admits nothing" "[ -e $MARK ] && ! grep -q 1700000500 $MARK"
touch "$S/pf/fail-load"
"$LIBEXEC/pf-load.sh" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "a pf load that fails exits non-zero" || bad "a pf load that fails exits non-zero"
sleep 3
check "when the load fails the marker is gone" "[ ! -e $MARK ]"
check "and the engine still does not listen" "! listening 11434"
check "nor node_exporter" "! listening 9100"
rm -f "$S/pf/fail-load"
"$LIBEXEC/pf-load.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "the boot job loads the allowlist" || bad "the boot job loads the allowlist" "rc=$rc"
check "the marker now holds this boot's id" "grep -qx '{ sec = 1700000500, usec = 0 }' $MARK"
check "the engine starts listening once the marker is written" "wait_listening 11434 8"
check "node_exporter starts listening" "wait_listening 9100 8"
check "mlx-lm starts listening" "wait_listening 8080 8"

echo "scenario 9: an allowlist lost between converges stops the listeners"
# (a) the converge fails before it reaches the firewall role
rm -f "$S/pf/anchor.rules" "$S/pf/anchor.loaded"
play lostassert "$WORK/node-noadmin"; rc=$?
[ "$rc" != 0 ] && ok "a converge that fails before the firewall role still fails" || bad "a converge that fails before the firewall role still fails"
check "the engine was stopped" "! listening 11434 && [ ! -e $S/loaded/$(label ollama) ]"
check "node_exporter and macmon were stopped" "! listening 9100 && [ ! -e $S/loaded/$(label node-exporter) ] && [ ! -e $S/loaded/$(label macmon) ]"
check "mlx-lm was stopped" "! listening 8080 && [ ! -e $S/loaded/$(label mlx-lm-8080) ]"
check "the boot marker was removed" "[ ! -e $MARK ]"
check "the plists are still there for the next converge" "[ -e /Library/LaunchDaemons/$(label ollama).plist ]"
play recover1 "$NODE"; rc=$?
[ "$rc" = 0 ] && ok "the next converge reloads the allowlist and starts them again" || bad "the next converge reloads the allowlist and starts them again" "rc=$rc; $(tail -12 "$OUT/recover1.log" | tr '\n' '|')"
check "the engine listens again" "wait_listening 11434 8"
check "the marker is back" "grep -qx '{ sec = 1700000500, usec = 0 }' $MARK"
# (b) the firewall role cannot reload it
rm -f "$S/pf/anchor.rules" "$S/pf/anchor.loaded"; touch "$S/pf/fail-load"
play lostload "$NODE"; rc=$?
[ "$rc" != 0 ] && ok "a converge that cannot reload the allowlist fails" || bad "a converge that cannot reload the allowlist fails"
check "the engine was stopped before it failed" "! listening 11434 && [ ! -e $S/loaded/$(label ollama) ]"
check "node_exporter was stopped" "! listening 9100 && [ ! -e $S/loaded/$(label node-exporter) ]"
check "the boot marker was removed" "[ ! -e $MARK ]"
rm -f "$S/pf/fail-load"
play recover2 "$NODE"; rc=$?
[ "$rc" = 0 ] && ok "and the converge after that recovers" || bad "and the converge after that recovers" "rc=$rc; $(tail -12 "$OUT/recover2.log" | tr '\n' '|')"
check "the engine listens again" "wait_listening 11434 8"
# (c) pf switched off with the rules still loaded
rm -f "$S/pf/enabled"
play pfoff "$WORK/node-noadmin"
check "with pf off the engine is stopped too" "! listening 11434"
play recover3 "$NODE"; rc=$?
[ "$rc" = 0 ] && ok "pf is turned back on and the engine returns" || bad "pf is turned back on and the engine returns" "rc=$rc"
check "the engine listens again" "wait_listening 11434 8"

echo "scenario 10: the rollback puts back the last confirmed rules and never opens the managed ports"
check "the confirmed ruleset was saved when it was applied" "cmp -s /etc/pf.anchors/com.tockmox.ai-node.allowlist /var/db/tockmox-ai-node/pf-last-confirmed.rules"
check "a minimal ruleset is rendered beside it" "grep -q '^block return in quick proto tcp from any to any port' /var/db/tockmox-ai-node/pf-minimal.rules && grep -q 'lo0' /var/db/tockmox-ai-node/pf-minimal.rules"
mkdir -p "$WORK/node-newadmin"
sed 's|adminCidrs: \[203.0.113.0/24\]|adminCidrs: [198.51.100.0/24]|' "$NODE/ai-node.yaml" > "$WORK/node-newadmin/ai-node.yaml"
sed 's|adminCidrs: \[203.0.113.0/24\]|adminCidrs: [198.51.100.0/24]|' "$NODE/desired.yaml" > "$WORK/node-newadmin/desired.yaml"
rm -f "$S/pf/states"
play newadmin "$WORK/node-newadmin" -e firewall_confirm_wait_seconds=5; rc=$?
[ "$rc" != 0 ] && grep -q 'no administrator session or confirmation was' "$OUT/newadmin.log" && ok "an unconfirmed administrator change fails the converge" || bad "an unconfirmed administrator change fails the converge" "rc=$rc"
check "the new rules are the ones in force until the rollback fires" "grep -q '198.51.100.0/24' /etc/pf.anchors/com.tockmox.ai-node.allowlist && [ -s $S/pf/anchor.rules ]"
check "the engine keeps listening while the new rules protect it" "listening 11434"
sh "$LIBEXEC/pf-rollback.sh" 0; rc=$?
[ "$rc" = 0 ] && ok "the rollback runs" || bad "the rollback runs" "rc=$rc"
check "the anchor now holds the last confirmed rules" "diff <(grep -E '^(pass|block)' /var/db/tockmox-ai-node/pf-last-confirmed.rules) $S/pf/anchor.rules"
check "and still has the managed-port block" "grep -q '^block return in quick' $S/pf/anchor.rules"
check "the anchor was never flushed" "! grep -q 'pfctl .*-F' $S/calls.log"
check "the rolled-back marker names the rules that were rolled back" "[ -s /var/db/tockmox-ai-node/pf-rolled-back ]"
check "the boot marker is kept: a block rule is live" "grep -qx '{ sec = 1700000500, usec = 0 }' $MARK"
check "the engine was not touched by the rollback" "listening 11434"
play again "$WORK/node-newadmin" -e firewall_confirm_wait_seconds=5; rc=$?
[ "$rc" != 0 ] && grep -q 'applied before and rolled back' "$OUT/again.log" && ok "the same rules are refused after a rollback" || bad "the same rules are refused after a rollback" "rc=$rc"
check "that refusal does not take down an engine the restored rules still protect" "listening 11434"
rm -f /var/db/tockmox-ai-node/pf-last-confirmed.rules /var/db/tockmox-ai-node/pf-loaded.sha256
date +%s > /var/db/tockmox-ai-node/pf-armed
cp /etc/pf.anchors/com.tockmox.ai-node.allowlist "$WORK/newadmin.rules"
grep -E '^(pass|block)' "$WORK/newadmin.rules" > "$S/pf/anchor.rules"
sh "$LIBEXEC/pf-rollback.sh" 0
check "with nothing ever confirmed the rollback loads the minimal ruleset" "diff <(grep -E '^(pass|block)' /var/db/tockmox-ai-node/pf-minimal.rules) $S/pf/anchor.rules"
check "which is not empty and still blocks the managed ports" "[ -s $S/pf/anchor.rules ] && grep -q '^block return in quick' $S/pf/anchor.rules"
check "and the anchor was still never flushed" "! grep -q 'pfctl .*-F' $S/calls.log"

echo "scenario 11: the site files are data: not variables, not templates"
play restore "$NODE"; rc=$?
[ "$rc" = 0 ] && ok "the node is converged again before the hostile files" || bad "the node is converged again before the hostile files" "rc=$rc; $(tail -12 "$OUT/restore.log" | tr '\n' '|')"
mkdir -p "$WORK/node-evil"
cp "$NODE/ai-node.yaml" "$WORK/node-evil/ai-node.yaml"
python3 - "$NODE/desired.yaml" "$WORK/node-evil/desired.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["gpu_memory_sysctl"] = "/tmp/tockmox-evil-sysctl"
d["firewall_pfctl"] = "/tmp/tockmox-evil-pfctl"
d["tn_root"] = "/tmp/tockmox-evil-root"
d["firewall"]["extra"] = 1
open(sys.argv[2], "w").write(yaml.safe_dump(d, sort_keys=False))
PY
sed -i 's|^  ollama:.*|&\n    bogus: 1|' "$WORK/node-evil/ai-node.yaml"
grep -q 'bogus: 1' "$WORK/node-evil/ai-node.yaml" || printf 'engines:\n  ollama:\n    bogus: 1\n' >> "$WORK/node-evil/ai-node.yaml"
n0=$(wc -l < "$S/calls.log"); m0=$(stat -c %Y /opt/tockmox/var/rootfacts.d/pf_anchor)
play evil "$WORK/node-evil"; rc=$?
[ "$rc" != 0 ] && ok "unknown keys in the site files fail the converge" || bad "unknown keys in the site files fail the converge"
check "a top-level key that is a role variable is refused by name" "grep -q 'gpu_memory_sysctl is not a known key' $OUT/evil.log && grep -q 'firewall_pfctl is not a known key' $OUT/evil.log && grep -q 'tn_root is not a known key' $OUT/evil.log"
check "a nested unknown key is refused by name" "grep -q 'firewall: extra is not a known key' $OUT/evil.log"
check "it was refused by the schema check, the first task of the first role" "grep -q 'Refuse site files that do not match their schemas' $OUT/evil.log && ! grep -q 'TASK \\[ai_node_assert : Check the machine' $OUT/evil.log"
check "no command ran but the read-only firewall verdict" "[ \$(tail -n +\$(( $n0 + 1 )) $S/calls.log | grep -vc '^pfctl ') = 0 ]"
check "nothing was written for a program the site named" "[ ! -e /tmp/tockmox-evil-sysctl ] && [ ! -e /tmp/tockmox-evil-pfctl ] && [ ! -e /tmp/tockmox-evil-root ]"
check "the root-only facts were not rewritten from unchecked values" "[ \$(stat -c %Y /opt/tockmox/var/rootfacts.d/pf_anchor) = $m0 ]"
check "the listeners the verified allowlist protects are untouched" "listening 11434"

# A string that is a template is data too: it reaches the plist as the text it is.
rm -f /tmp/tockmox-pwned
mkdir -p "$WORK/node-template"; cp "$NODE/desired.yaml" "$WORK/node-template/"
python3 - "$NODE/ai-node.yaml" "$WORK/node-template/ai-node.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["engines"]["ollama"]["env"] = {"X_NOTE": "{{ lookup('pipe', 'touch /tmp/tockmox-pwned') }}"}
open(sys.argv[2], "w").write(yaml.safe_dump(d, sort_keys=False))
PY
play template "$WORK/node-template"; rc=$?
[ "$rc" = 0 ] && ok "a node whose env value looks like a template converges" || bad "a node whose env value looks like a template converges" "rc=$rc; $(tail -12 "$OUT/template.log" | tr '\n' '|')"
check "the template was not evaluated" "[ ! -e /tmp/tockmox-pwned ]"
check "it reached the plist as the literal text" "python3 -c 'import plistlib;d=plistlib.load(open(\"/Library/LaunchDaemons/$(label ollama).plist\",\"rb\"));assert d[\"EnvironmentVariables\"][\"X_NOTE\"]==\"{{ lookup(\x27pipe\x27, \x27touch /tmp/tockmox-pwned\x27) }}\"'"

cp "$S/calls.log" "$OUT/calls.log" 2>/dev/null; cp "$S/listener.err" "$OUT/listener.err" 2>/dev/null
echo
echo "e2e: $pass passed, $fail failed (logs in $OUT)"
if [ "$fail" != 0 ] && [ "${KEEP:-0}" != 1 ]; then cp -r "$OUT" /tmp/tockmox-e2e-logs 2>/dev/null && echo "e2e: logs copied to /tmp/tockmox-e2e-logs"; fi
[ "$fail" = 0 ]

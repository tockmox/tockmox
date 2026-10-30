#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tests of bin/tockmox-ai-node-converge that need no macOS, no ansible and no network:
#   - the recap parser and the failure classifier, including a play that never loaded;
#   - the metrics file and the state file (series, labels, atomicity, the -1 "no recap" value);
#   - the whole wrapper against a fake root, a real git site repository signed with ssh-keygen,
#     and a fake ansible: warn proceeds with signature_ok 0, enforce refuses with exit 12, a signed
#     history verifies, a signer rotation is honoured only when a pinned key signed it, and a play
#     that does not load is exit 14 with failed=-1.
#
#   ai-node/tests/converge-wrapper.sh
#
# Plain bash; exit 0 all passed, 1 a failure, 2 a tool is missing.

# shellcheck disable=SC2034  # globals consumed by the sourced converger
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
CONVERGE="$HERE/../bin/tockmox-ai-node-converge"
FACTS="$HERE/../bin/tockmox-ai-node-facts"

for c in git ssh-keygen python3 shasum; do
  command -v "$c" >/dev/null 2>&1 || { echo "converge-wrapper: $c not on PATH" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "converge-wrapper: python3 PyYAML missing" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3], got [$2]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------- unit: parser and classifier

echo "recap parser and classifier"
export TOCKMOX_SOURCE_ONLY=1 TOCKMOX_ROOT="$TMP/unit"
mkdir -p "$TMP/unit/var" "$TMP/unit/textfile"
# The globals below are read by the sourced functions, which shellcheck cannot see.
# shellcheck disable=SC1090,SC1091,SC2034
. "$CONVERGE"
unset TOCKMOX_SOURCE_ONLY
set_paths

printf 'PLAY RECAP *****\nlocalhost                  : ok=198  changed=5    unreachable=0    failed=0    skipped=119  rescued=0    ignored=0\n' > "$TMP/recap.ok"
parse_recap "$TMP/recap.ok"; eq "recap ok=" "$R_OK" 198; eq "recap changed=" "$R_CHANGED" 5; eq "recap skipped=" "$R_SKIPPED" 119
eq "recap failed=" "$R_FAILED" 0; eq "recap unreachable=" "$R_UNREACH" 0

printf 'localhost : ok=3 changed=0 unreachable=0 failed=2 skipped=0 rescued=0 ignored=0\n' > "$TMP/recap.fail"
parse_recap "$TMP/recap.fail"; eq "recap failed=2" "$R_FAILED" 2

printf 'ERROR! the playbook could not be found\n' > "$TMP/recap.none"
parse_recap "$TMP/recap.none"; rc=$?
eq "no recap returns 1" "$rc" 1; eq "no recap leaves failed=-1" "$R_FAILED" -1

# Two recaps (a re-run in one file): the last wins.
{ cat "$TMP/recap.fail"; cat "$TMP/recap.ok"; } > "$TMP/recap.two"
parse_recap "$TMP/recap.two"; eq "the last recap wins" "$R_FAILED" 0

classify_run 0 "$TMP/recap.ok";   eq "rc 0 with a clean recap is success" "$EXIT_CODE/$FAILED_PHASE" "0/"
classify_run 2 "$TMP/recap.fail"; eq "rc 2 with failures is a run failure" "$EXIT_CODE/$FAILED_PHASE" "2/run"
classify_run 0 "$TMP/recap.fail"; eq "rc 0 with failed=2 cannot be success" "$EXIT_CODE/$FAILED_PHASE" "2/run"
classify_run 4 "$TMP/recap.none"; eq "no recap is a load failure with ansible's code" "$EXIT_CODE/$FAILED_PHASE" "4/load"
classify_run 0 "$TMP/recap.none"; eq "no recap with rc 0 is still a failure" "$EXIT_CODE/$FAILED_PHASE" "$EX_LOAD/load"

echo "metrics and state files"
AI_NODE_ID='node "one"'; EXIT_CODE=14; FAILED_PHASE=load; SIG_OK=0; SIGNING_EFFECTIVE=warn
APPLIED_COMMIT=abc; TOOLKIT_REF_USED=v1; DESIRED_SHA=def; T_START=$(( $(date +%s) - 7 ))
parse_recap "$TMP/recap.none"
write_metrics; write_state
P="$TMP/unit/textfile/converge.prom"
check "converge.prom exists" test -s "$P"
check "no temporary file is left behind" bash -c "! ls '$TMP/unit/textfile' | grep -q 'converge.prom.'"
check "last_exit_code is 14" grep -q '^tockmox_ai_node_converge_last_exit_code{ai_node="node \\"one\\""} 14$' "$P"
check "the load phase is 1 and the others 0" bash -c "grep -q 'phase=\"load\"} 1' '$P' && grep -q 'phase=\"run\"} 0' '$P' && grep -q 'phase=\"fetch\"} 0' '$P'"
check "failed tasks is -1 with no recap" grep -q 'state="failed"} -1$' "$P"
check "signature_ok is 0" grep -q '^tockmox_ai_node_converge_signature_ok{.*} 0$' "$P"
check "the success timestamp did not move on a failure" grep -q 'last_success_timestamp_seconds{[^}]*} 0$' "$P"
check "every series has HELP and TYPE" bash -c "[ \$(grep -c '^# HELP' '$P') = \$(grep -c '^# TYPE' '$P') ]"
check "state.json is valid JSON" python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d['last_exit']==14 and d['failed_phase']=='load' and d['signature_ok']==0" "$TMP/unit/var/state.json"
EXIT_CODE=0; FAILED_PHASE=""; SIG_OK=1; parse_recap "$TMP/recap.ok"; write_metrics; write_state
check "a success moves the success timestamp" bash -c "! grep -q 'last_success_timestamp_seconds{[^}]*} 0\$' '$P'"
eq "state_get reads last_exit back" "$(state_get last_exit)" 0

echo "env file"
printf 'AI_NODE_ID=n1\nSITE_REPO="/x/y"\nSKIP_TAGS=timer\nBOGUS=1\n# comment\n' > "$TMP/env"
AI_NODE_ID=""; SITE_REPO=""; ANSIBLE_SKIP_TAGS=""
load_env_file "$TMP/env"
eq "env AI_NODE_ID" "$AI_NODE_ID" n1; eq "env quotes stripped" "$SITE_REPO" /x/y; eq "env SKIP_TAGS" "$ANSIBLE_SKIP_TAGS" timer

# ----------------------------------------------------------------- the wrapper against fakes

echo "the wrapper, end to end, against fakes"
W="$TMP/w"; mkdir -p "$W/bin"
ROOT="$W/root"; SITE="$W/site"; TK="$W/toolkit"; KEYS="$W/keys"
mkdir -p "$ROOT"/{etc,var,log,textfile,secrets} "$KEYS"
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.name tester; git config --global user.email t@example.invalid
git config --global init.defaultBranch main; git config --global commit.gpgsign false

ssh-keygen -q -t ed25519 -N '' -f "$KEYS/good" -C good
ssh-keygen -q -t ed25519 -N '' -f "$KEYS/other" -C other
ssh-keygen -q -t ed25519 -N '' -f "$KEYS/new" -C new
signer_line() { printf '%s namespaces="git" %s\n' "$1" "$(cut -d' ' -f1,2 "$KEYS/$2.pub")"; }

# the toolkit: just enough for the wrapper to find a playbook
mkdir -p "$TK/ai-node/playbooks"
printf -- '- hosts: localhost\n  tasks: []\n' > "$TK/ai-node/playbooks/ai-node.yml"
printf '[defaults]\n' > "$TK/ai-node/ansible.cfg"
cp "$HERE/../playbooks/site_vars.py" "$TK/ai-node/playbooks/site_vars.py"
git -C "$TK" init -q && git -C "$TK" add -A && git -C "$TK" commit -q -m toolkit

# the site
mkdir -p "$SITE/ai-nodes/n1"
git -C "$SITE" init -q
write_site() {  # FILE-SET: unsigned content for each commit
  printf 'schema: tockmox.ai-node.fleet/v1\ntoolkit:\n  repo: %s\n  ref: main\n%s' "$TK" "${1:-}" > "$SITE/ai-nodes/fleet.yaml"
  printf 'schema: tockmox.ai-node/v1\naiNodeId: n1\n' > "$SITE/ai-nodes/n1/ai-node.yaml"
  printf 'schema: tockmox.ai-node.desired/v1\naiNodeId: n1\nrev: %s\n' "$2" > "$SITE/ai-nodes/n1/desired.yaml"
}
commit_signed() {  # KEYNAME MESSAGE
  git -C "$SITE" add -A
  git -C "$SITE" -c gpg.format=ssh -c "user.signingkey=$KEYS/$1" commit -q -S -m "$2"
}
commit_unsigned() { git -C "$SITE" add -A; git -C "$SITE" commit -q -m "$1"; }

# the fakes
cat > "$W/bin/ansible" <<'EOF'
#!/bin/sh
# Prints what ansible-playbook would, selected by FAKE_ANSIBLE.
echo "$*" >> "$FAKE_LOG"
# keep what the extra-vars file said, for the tests to read
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$FAKE_LOG.vars" 2>/dev/null ;; esac; done
case "${FAKE_ANSIBLE:-ok}" in
  ok)     printf 'PLAY RECAP *****\nlocalhost : ok=10 changed=2 unreachable=0 failed=0 skipped=1 rescued=0 ignored=0\n'; exit 0 ;;
  fail)   printf 'PLAY RECAP *****\nlocalhost : ok=4 changed=0 unreachable=0 failed=1 skipped=0 rescued=0 ignored=0\n'; exit 2 ;;
  noload) printf '[ERROR]: the playbook could not be loaded: syntax error\n'; exit 4 ;;
esac
EOF
cat > "$W/bin/launchctl" <<'EOF'
#!/bin/sh
exit 113
EOF
chmod +x "$W/bin/ansible" "$W/bin/launchctl"
export FAKE_LOG="$W/ansible.calls"

cat > "$ROOT/etc/ai-node.env" <<EOF
AI_NODE_ID=n1
SITE_REPO=$SITE
SITE_REF=main
TOOLKIT_REPO=$TK
TOOLKIT_REF=main
SIGNING_MODE=warn
EOF
{ signer_line g good; } > "$ROOT/etc/allowed_signers"

run() {  # extra args; output to $W/run.out; returns the wrapper's exit code
  TOCKMOX_ROOT="$ROOT" TOCKMOX_ANSIBLE="$W/bin/ansible" TOCKMOX_LAUNCHCTL="$W/bin/launchctl" \
    TOCKMOX_LAUNCHD_DIR="$W/launchd" TOCKMOX_SUDO="" TOCKMOX_SOPS=/nonexistent \
    bash "$CONVERGE" "$@" > "$W/run.out" 2>&1 < /dev/null
}
prom() { sed -n "s/^$1{[^}]*} \\(.*\\)\$/\\1/p" "$ROOT/textfile/converge.prom" | head -1; }
statev() { python3 -c "import json,sys;print(json.load(open('$ROOT/var/state.json'))[sys.argv[1]])" "$1"; }
reset_state() { rm -f "$ROOT/var/state.json" "$ROOT/textfile/converge.prom"; rm -rf "$ROOT/site" "$ROOT/toolkit"; : > "$W/ansible.calls"; }

# 1. an unsigned history in warn mode proceeds and says so
write_site "" r1; commit_unsigned "unsigned commit"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "warn: an unsigned history is applied (exit 0)" "$rc" 0
eq "warn: signature_ok is 0" "$(prom tockmox_ai_node_converge_signature_ok)" 0
eq "warn: state records signature_ok 0" "$(statev signature_ok)" 0
eq "warn: verified_commit stays empty" "$(statev verified_commit)" ""
check "warn: the log says so" grep -q 'signing mode is warn: applying' "$W/run.out"
check "the playbook got the node's files and the toolkit directory" grep -q "tockmox_node_dir=$ROOT/site/ai-nodes/n1" "$W/ansible.calls"
check "the playbook runs against localhost only" grep -q -- "-i localhost, -c local" "$W/ansible.calls"
check "recap counts reach the metrics: ok=10" grep -q 'state="ok"} 10$' "$ROOT/textfile/converge.prom"

# 2. the same history in enforce mode is refused before anything runs
sed -i.bak 's/^SIGNING_MODE=.*/SIGNING_MODE=enforce/' "$ROOT/etc/ai-node.env"; rm -f "$ROOT/etc/ai-node.env.bak"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: an unsigned history is refused with exit 12" "$rc" 12
check "enforce: the playbook was never run" bash -c "[ ! -s '$W/ansible.calls' ]"
eq "enforce: the failed phase is verify" "$(statev failed_phase)" verify
check "enforce: the verify phase gauge is 1" grep -q 'phase="verify"} 1$' "$ROOT/textfile/converge.prom"

# 3. a signed history by a pinned key verifies and is recorded
write_site "" r2; commit_signed good "signed by the pinned key"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "the first converge checks the tip against the signers pinned at bootstrap" "$rc" 0

# A clean history, all signed
rm -rf "$SITE/.git"; git -C "$SITE" init -q
write_site "" r1; commit_signed good "first"
write_site "" r2; commit_signed good "second"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: an all-signed history is applied" "$rc" 0
eq "signature_ok is 1" "$(prom tockmox_ai_node_converge_signature_ok)" 1
eq "verified_commit is the head" "$(statev verified_commit)" "$(git -C "$SITE" rev-parse HEAD)"

# 4. a new unsigned commit on top is refused; the verified point is kept
write_site "" r3; commit_unsigned "sneaky"
FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: a new unsigned commit is refused" "$rc" 12
eq "the verified commit did not move" "$(statev verified_commit)" "$(git -C "$SITE" rev-parse HEAD~1)"
check "the refusal names the commit" grep -q 'refusing to apply: commit' "$W/run.out"

# 5. a commit signed by a key that is not pinned is refused
git -C "$SITE" reset -q --hard HEAD~1
write_site "" r3; commit_signed other "signed by a stranger"
FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: a signature from an unpinned key is refused" "$rc" 12

# 6. history rewritten under the verified point is refused
git -C "$SITE" reset -q --hard HEAD~2
write_site "" rewritten; commit_signed good "rewritten"
FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: a rewritten history is refused" "$rc" 12
check "the message says history was rewritten" grep -q 'history was rewritten' "$W/run.out"

# 7. a signer rotation signed by a pinned key is honoured; a later commit by the new key verifies
rm -rf "$SITE/.git"; git -C "$SITE" init -q
write_site "" r1; commit_signed good "first"
reset_state; FAKE_ANSIBLE=ok run; rc=$?; eq "baseline applied" "$rc" 0
{ signer_line g good; signer_line n new; } > "$SITE/ai-nodes/allowed_signers"
write_site "" r2; commit_signed good "add the new key (signed by the old)"
write_site "" r3; commit_signed new "signed by the new key"
FAKE_ANSIBLE=ok run; rc=$?
eq "a rotation signed by a pinned key is honoured" "$rc" 0
check "the new signer set is pinned afterwards" grep -qF "$(cut -d' ' -f2 "$KEYS/new.pub")" "$ROOT/etc/allowed_signers"

# 7b. GPG-signed commits (the forge's merge commits) verify against the pinned gpg-signers.asc
if command -v gpg >/dev/null 2>&1; then
  export GNUPGHOME="$W/gnupg-author"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-generate-key "forge <forge@example.invalid>" ed25519 sign never >/dev/null 2>&1
  GOOD_FPR="$(gpg --batch --list-keys --with-colons forge@example.invalid 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  gpg --batch --armor --export forge@example.invalid > "$W/forge.asc" 2>/dev/null
  export GNUPGHOME="$W/gnupg-stranger"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-generate-key "stranger <stranger@example.invalid>" ed25519 sign never >/dev/null 2>&1
  STRANGER_FPR="$(gpg --batch --list-keys --with-colons stranger@example.invalid 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  commit_gpg() {  # HOMEDIR FPR MESSAGE
    git -C "$SITE" add -A
    GNUPGHOME="$1" git -C "$SITE" -c gpg.format=openpgp -c "user.signingkey=$2" commit -q -S -m "$3"
  }
  unset GNUPGHOME
  rm -rf "$SITE/.git"; git -C "$SITE" init -q; rm -f "$SITE/ai-nodes/allowed_signers" "$SITE/ai-nodes/gpg-signers.asc"
  cp "$W/forge.asc" "$ROOT/etc/gpg-signers.asc"; rm -f "$ROOT/etc/allowed_signers"
  write_site "" r1; commit_gpg "$W/gnupg-author" "$GOOD_FPR" "merge by the forge"
  reset_state; FAKE_ANSIBLE=ok run; rc=$?
  eq "enforce: a GPG commit by the pinned forge key is applied" "$rc" 0
  eq "gpg: signature_ok is 1" "$(prom tockmox_ai_node_converge_signature_ok)" 1
  write_site "" r2; commit_gpg "$W/gnupg-stranger" "$STRANGER_FPR" "signed by a stranger"
  FAKE_ANSIBLE=ok run; rc=$?
  eq "enforce: a GPG commit by an unpinned key is refused" "$rc" 12
  check "gpg: the refusal names the pinned keys" grep -q 'gpg signature not accepted' "$W/run.out"
  rm -f "$ROOT/etc/gpg-signers.asc"; { signer_line g good; } > "$ROOT/etc/allowed_signers"
  rm -rf "$SITE/.git"; git -C "$SITE" init -q; write_site "" r9; commit_signed good "back to an ssh-signed history"
  reset_state; FAKE_ANSIBLE=ok run
else
  echo "  skip gpg tests: gpg is not installed"
fi

# 8. a play that fails to load is exit 14 with failed=-1, and not success
FAKE_ANSIBLE=noload run; rc=$?
eq "a play that does not load exits with ansible's code, not 0" "$rc" 4
eq "the load phase is the failed one" "$(statev failed_phase)" load
check "failed tasks is -1" grep -q 'state="failed"} -1$' "$ROOT/textfile/converge.prom"
FAKE_ANSIBLE=fail run; rc=$?
eq "a failed task exits non-zero" "$rc" 2
eq "the run phase is the failed one" "$(statev failed_phase)" run

# 9. refusals that happen before anything is touched
rm -rf "$SITE/.git"; git -C "$SITE" init -q; write_site "" r1; commit_signed good first
mkdir -p "$W/launchd"
printf '<plist>ansible-pull -U x</plist>\n' > "$W/launchd/com.example.old-converger.plist"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "another converger on the node is refused" "$rc" 14
check "it names the other converger" grep -q 'another converger is installed' "$W/run.out"
FAKE_ANSIBLE=ok run --check; rc=$?
eq "--check is allowed beside another converger" "$rc" 0
check "--check passed --check to ansible" grep -q -- '--check' "$W/ansible.calls"
rm -f "$W/launchd/com.example.old-converger.plist"

# 10. --skip-tags from the env file and the command line reach ansible
printf 'SKIP_TAGS=timer\n' >> "$ROOT/etc/ai-node.env"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "SKIP_TAGS applies" "$rc" 0
check "SKIP_TAGS reaches ansible as --skip-tags" grep -q -- '--skip-tags timer' "$W/ansible.calls"

# 11. only one converge at a time
bash -c 'sleep 60; true' tockmox-ai-node-converge &
holder=$!
mkdir -p "$ROOT/var/converge.lock"; echo "$holder" > "$ROOT/var/converge.lock/pid"
FAKE_ANSIBLE=ok run; rc=$?
eq "a second converge while one runs exits 75" "$rc" 75
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rm -rf "$ROOT/var/converge.lock"
FAKE_ANSIBLE=ok run; rc=$?
eq "a lock whose owner is gone is removed" "$rc" 0

# 12. confirm-firewall leaves its markers
mkdir -p "$W/db"; : > "$W/db/pf-rolled-back"
TOCKMOX_STATE_DB="$W/db" TOCKMOX_ROOT="$ROOT" TOCKMOX_SUDO="" bash "$CONVERGE" --confirm-firewall >/dev/null 2>&1
check "--confirm-firewall writes pf-confirm" test -e "$W/db/pf-confirm"
check "--confirm-firewall clears the rolled-back marker" test ! -e "$W/db/pf-rolled-back"

# 13. what selects the toolkit is trusted input: the repository is pinned on the node, and the ref
# comes from fleet.yaml only when the head verified (warn and enforce alike)
echo "toolkit selection"
EVIL="$W/evil-toolkit"; mkdir -p "$EVIL/ai-node/playbooks"
printf -- '- hosts: localhost\n  tasks: []\n' > "$EVIL/ai-node/playbooks/ai-node.yml"
printf '[defaults]\n' > "$EVIL/ai-node/ansible.cfg"
git -C "$EVIL" init -q && git -C "$EVIL" add -A && git -C "$EVIL" commit -q -m evil
git -C "$TK" tag v1
echo second > "$TK/second"; git -C "$TK" add -A; git -C "$TK" commit -q -m second; git -C "$TK" tag v2
set_env() {  # KEY VALUE
  grep -v "^$1=" "$ROOT/etc/ai-node.env" > "$ROOT/etc/ai-node.env.new"; printf '%s=%s\n' "$1" "$2" >> "$ROOT/etc/ai-node.env.new"
  mv -f "$ROOT/etc/ai-node.env.new" "$ROOT/etc/ai-node.env"
}
fleet_tk() {  # REPO REF
  printf 'schema: tockmox.ai-node.fleet/v1\ntoolkit:\n  repo: %s\n  ref: %s\n' "$1" "$2" > "$SITE/ai-nodes/fleet.yaml"
}
site_rev() { printf 'schema: tockmox.ai-node.desired/v1\naiNodeId: n1\nrev: %s\n' "$1" > "$SITE/ai-nodes/n1/desired.yaml"; }
set_env SKIP_TAGS ""; set_env TOOLKIT_REF v1; set_env SIGNING_MODE warn
rm -rf "$SITE/.git" "$SITE/ai-nodes/allowed_signers"; git -C "$SITE" init -q
write_site "" t1; fleet_tk "$TK" v1; commit_signed good "baseline, toolkit v1"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "a signed baseline applies" "$rc" 0
eq "the toolkit ref used is v1" "$(statev toolkit_ref)" v1
eq "a verified head records its toolkit ref" "$(statev verified_toolkit_ref)" v1
check "the clone is of the pinned repository" test "$(git -C "$ROOT/toolkit" remote get-url origin)" = "$TK"

# an UNSIGNED commit repointing toolkit.repo, in warn mode
fleet_tk "$EVIL" v1; site_rev t2; commit_unsigned "unsigned: point the toolkit at another repository"
: > "$W/ansible.calls"; FAKE_ANSIBLE=ok run; rc=$?
eq "warn: an unsigned commit repointing toolkit.repo is refused (exit 11)" "$rc" 11
eq "warn: the failed phase is fetch" "$(statev failed_phase)" fetch
check "warn: the playbook never ran" bash -c "[ ! -s '$W/ansible.calls' ]"
check "warn: the refusal names the pin" grep -q 'this node is pinned to' "$W/run.out"
check "warn: the checkout still points at the pinned repository" test "$(git -C "$ROOT/toolkit" remote get-url origin)" = "$TK"
# the same in enforce
set_env SIGNING_MODE enforce
: > "$W/ansible.calls"; FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: an unsigned commit repointing toolkit.repo is refused" "$rc" 12
check "enforce: the playbook never ran" bash -c "[ ! -s '$W/ansible.calls' ]"
# a SIGNED commit naming another repository is refused too: the pin is changed on the node
git -C "$SITE" reset -q --hard HEAD~1
fleet_tk "$EVIL" v1; site_rev t2; commit_signed good "signed: point the toolkit at another repository"
: > "$W/ansible.calls"; FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: even a signed commit cannot repoint toolkit.repo" "$rc" 11
set_env SIGNING_MODE warn
FAKE_ANSIBLE=ok run; rc=$?
eq "warn: nor can a signed commit" "$rc" 11
check "no run reached the playbook" bash -c "[ ! -s '$W/ansible.calls' ]"
# a spelling of the same repository is not a different repository
fleet_tk "$TK/" v1; git -C "$SITE" add -A; git -C "$SITE" -c gpg.format=ssh -c "user.signingkey=$KEYS/good" commit -q -S --amend -m "signed: same repository, trailing slash"
FAKE_ANSIBLE=ok run; rc=$?
eq "a trailing slash is the same repository" "$rc" 0

# an UNSIGNED commit changing toolkit.ref: warn keeps the last verified ref
fleet_tk "$TK" v2; site_rev t3; commit_unsigned "unsigned: move the toolkit to v2"
: > "$W/ansible.calls"; FAKE_ANSIBLE=ok run; rc=$?
eq "warn: an unsigned toolkit.ref change still applies the desired state" "$rc" 0
eq "warn: the toolkit stays at the last verified ref" "$(statev toolkit_ref)" v1
eq "warn: the verified ref is unchanged" "$(statev verified_toolkit_ref)" v1
check "warn: the log says the ref was ignored" grep -q 'ignoring toolkit.ref from the unverified head' "$W/run.out"
check "warn: the checkout has no file from v2" test ! -e "$ROOT/toolkit/second"
set_env SIGNING_MODE enforce
: > "$W/ansible.calls"; FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: an unsigned toolkit.ref change is refused" "$rc" 12
check "enforce: the playbook never ran" bash -c "[ ! -s '$W/ansible.calls' ]"
eq "enforce: the verified ref is unchanged" "$(statev verified_toolkit_ref)" v1
# a signed commit moves the ref, and the verified ref follows once the run succeeds
git -C "$SITE" reset -q --hard HEAD~1
fleet_tk "$TK" v2; site_rev t3; commit_signed good "signed: move the toolkit to v2"
FAKE_ANSIBLE=fail run; rc=$?
eq "a failing run on a verified head" "$rc" 2
eq "a failed run does not advance the verified ref" "$(statev verified_toolkit_ref)" v1
FAKE_ANSIBLE=ok run; rc=$?
eq "enforce: a signed toolkit.ref change is applied" "$rc" 0
eq "the toolkit is at v2" "$(statev toolkit_ref)" v2
eq "the verified ref follows" "$(statev verified_toolkit_ref)" v2
check "the checkout has the v2 file" test -e "$ROOT/toolkit/second"

# no state yet: an unverified head falls back to TOOLKIT_REF in ai-node.env
set_env SIGNING_MODE warn
rm -rf "$SITE/.git"; git -C "$SITE" init -q; write_site "" t9; fleet_tk "$TK" v2; commit_unsigned "unsigned first run"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "a first unverified converge applies" "$rc" 0
eq "it uses TOOLKIT_REF from the node, not fleet.yaml" "$(statev toolkit_ref)" v1
eq "and records no verified ref" "$(statev verified_toolkit_ref)" ""
# an option-shaped or odd ref is refused before git sees it
set_env SIGNING_MODE warn; set_env TOOLKIT_REF -oProxyCommand=x
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "an option-shaped toolkit ref is refused" "$rc" 11
set_env TOOLKIT_REF main; set_env TOOLKIT_REPO "ext::sh -c id"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "an ext:: toolkit repository is refused" "$rc" 11
set_env TOOLKIT_REPO "$TK"; set_env TOOLKIT_REF main; set_env SIGNING_MODE warn
# values from the head that reach a file name or a chown are taken only in plain form
rm -rf "$SITE/.git"; git -C "$SITE" init -q; write_site "" t10; fleet_tk "$TK" v1
printf 'schema: tockmox.ai-node/v1\naiNodeId: n1\nlabels:\n  prefix: ../../etc/evil\n' > "$SITE/ai-nodes/n1/ai-node.yaml"
commit_unsigned "unsigned: a label prefix that is a path"
reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "a labels.prefix that is not a plain prefix is refused (exit 14)" "$rc" 14
check "the playbook never ran" bash -c "[ ! -s '$W/ansible.calls' ]"
set_env TOOLKIT_REF main

# 14. the site files reach the playbook as ONE namespaced, unsafe extra-var, never as variables
echo "site data reaches the playbook as data"
rm -rf "$SITE/.git"; git -C "$SITE" init -q; write_site "" v1; fleet_tk "$TK" v1
printf 'schema: tockmox.ai-node.desired/v1\naiNodeId: n1\nrev: v1\ngpu_memory_sysctl: /tmp/evil\nfirewall_pfctl: /tmp/evil\ntn_root: /tmp/evil\n' > "$SITE/ai-nodes/n1/desired.yaml"
commit_unsigned "unsigned: top-level keys that are role variables"
set_env SIGNING_MODE warn; set_env TOOLKIT_REF v1
reset_state; rm -f "$W/ansible.calls.vars"; FAKE_ANSIBLE=ok run; rc=$?
eq "an unsigned commit with hostile top-level keys reaches the playbook (the playbook refuses it)" "$rc" 0
check "the playbook is given exactly one extra-vars file for the site" bash -c "[ \$(grep -o -- '-e @[^ ]*' '$W/ansible.calls' | wc -l) = 1 ]"
check "and never the site files themselves" bash -c "! grep -E -q 'ai-node[.]yaml|desired[.]yaml' '$W/ansible.calls'"
check "the vars are under tn_site and tagged !unsafe" bash -c "grep -qx 'tn_site: !unsafe' '$W/ansible.calls.vars'"
check "the hostile keys are nested, not at the top level" bash -c "! grep -E '^(gpu_memory_sysctl|firewall_pfctl|tn_root):' '$W/ansible.calls.vars' && grep -qE '^    gpu_memory_sysctl: /tmp/evil' '$W/ansible.calls.vars'"
check "both files are there" bash -c "grep -q '^  ai_node:' '$W/ansible.calls.vars' && grep -q '^  desired:' '$W/ansible.calls.vars'"
check "the temporary file is gone after the run" bash -c "! ls '$ROOT/var' | grep -q sitevars"
printf 'just a string\n' > "$SITE/ai-nodes/n1/desired.yaml"
commit_unsigned "unsigned: desired.yaml is not a mapping"
: > "$W/ansible.calls"; reset_state; FAKE_ANSIBLE=ok run; rc=$?
eq "a site file that is not a mapping is refused before ansible (exit 14)" "$rc" 14
check "ansible never ran" bash -c "[ ! -s '$W/ansible.calls' ]"
check "no temporary file is left" bash -c "! ls '$ROOT/var' | grep -q sitevars"

# ----------------------------------------------------------------- the facts script

echo "the facts script"
FR="$W/factsroot"; mkdir -p "$FR"/{etc,var/rootfacts.d,textfile}
now="$(date +%s)"
printf 'AI_NODE_ID=n1\nCONVERGE_INTERVAL=900\nROOTFACTS_MAX_AGE=3600\nEXPECTED_ROUTES=\n' > "$FR/etc/facts.env"
printf '{"ai_node": "n1", "site_commit": "abc", "verified_commit": "abc", "toolkit_ref": "v1", "desired_sha256": "d", "signing_mode": "warn", "signature_ok": 1, "last_run_epoch": %s, "last_success_epoch": %s, "last_exit": 0, "failed_phase": ""}\n' "$now" "$now" > "$FR/var/state.json"
echo 1 > "$FR/var/rootfacts.d/pf_anchor"; echo 0 > "$FR/var/rootfacts.d/filevault_on"
echo 1 > "$FR/var/rootfacts.d/remote_login"; touch -t 200001010000 "$FR/var/rootfacts.d/remote_login"
echo yes > "$FR/var/rootfacts.d/apple_account_signed_out"
printf 'FILEVAULT_POSTURE=off\n' >> "$FR/etc/facts.env"
TOCKMOX_ROOT="$FR" bash "$FACTS" >/dev/null 2>&1; rc=$?
eq "the facts script exits 0 with a partial fact set" "$rc" 0
FP="$FR/textfile/facts.prom"
check "it wrote facts.prom" test -s "$FP"
check "a fresh root-only fact is reported" grep -q 'check="pf_anchor"} 1$' "$FP"
check "a posture check follows facts.env" grep -q 'check="filevault_posture"} 1$' "$FP"
check "a non-0/1 root fact is unknown, so absent" bash -c "! grep -q 'apple_account_signed_out' '$FP'"
check "no temporary file is left behind" bash -c "! ls '$FR/textfile' | grep -q 'facts.prom.'"
printf 'm1\trev1\thf\t%s\n' "$FR/nowhere" > "$FR/var/models-present.tsv"
mkdir -p "$FR/m"; echo data > "$FR/m/f"; printf 'm2\trev2\thf\t%s\n' "$FR/m" >> "$FR/var/models-present.tsv"
TOCKMOX_ROOT="$FR" bash "$FACTS" >/dev/null 2>&1
check "a model on disk is present" grep -q 'model_present{.*model="m2".*} 1$' "$FP"
check "a model missing from disk is not claimed" bash -c "! grep -q 'model=\"m1\"' '$FP'"

echo
echo "converge-wrapper: $pass passed, $fail failed"
[ "$fail" = 0 ]

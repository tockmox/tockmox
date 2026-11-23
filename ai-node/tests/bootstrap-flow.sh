#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs bootstrap-node.sh end to end on a Linux box against fakes of the macOS tools it calls
# (uname, sw_vers, id, sudo, dscl, sysadminctl, dseditgroup, brew, stat, chown, ssh, ssh-keyscan,
# xcode-select, softwareupdate, gpg, and a git that behaves like the stub until the Command Line Tools are in),
# a real git site repository whose commits are signed with ssh-keygen, and a fake ansible. It tests
# the script's own logic: the order, what it asks and refuses, what it pins, what it never prints,
# and that a second run changes nothing. It tests nothing about macOS itself.
#
#   ai-node/tests/bootstrap-flow.sh
#
# Exit: 0 all passed, 1 a failure, 2 a tool is missing.
# shellcheck disable=SC2016  # the fakes are scripts held in single-quoted strings on purpose
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
AI="$(dirname "$HERE")"
BOOT="$AI/bootstrap-node.sh"

for c in git ssh-keygen age-keygen python3 visudo; do
  command -v "$c" >/dev/null 2>&1 || { echo "bootstrap-flow: $c not on PATH" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "bootstrap-flow: python3 PyYAML missing" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 12 | sed 's/^/       /'; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3], got [$2]"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REAL_PATH="$PATH"
REAL_GIT_EXEC="$(git --exec-path)"
REAL_GIT="$(command -v git)"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.name tester; git config --global user.email t@example.invalid
git config --global init.defaultBranch main; git config --global commit.gpgsign false

# ------------------------------------------------------------------ the fakes
F="$T/fake"; BIN="$F/bin"; BREW="$F/brew"; STATE="$F/state"
mkdir -p "$BIN" "$BREW/bin" "$BREW/opt/ansible/libexec/bin" "$STATE/users" "$STATE/admins" "$STATE/brew"
ln -s "$(command -v age-keygen)" "$BREW/bin/age-keygen"
ln -s "$(command -v python3)" "$BREW/opt/ansible/libexec/bin/python3"

fake() { printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

fake uname 'case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) exec /usr/bin/uname "$@" ;; esac'
fake sw_vers 'echo "${FAKE_OS:-27.0}"'
fake id 'case "${1:-}" in -u) echo 501 ;; -un) echo admin ;; -Gn) echo "staff admin" ;; *) exec /usr/bin/id "$@" ;; esac'
fake nc 'exit 0'
fake defaults 'exit 0'
fake chown "echo \"chown \$*\" >> '$STATE/chown.log'; case \"\$*\" in *tockmox:admin*) echo tockmox > '$STATE/brew-owner' ;; esac; exit 0"
fake stat "[ \"\$1\" = -f ] && [ \"\$2\" = %Su ] && { cat '$STATE/brew-owner' 2>/dev/null || echo admin; exit 0; }; exec /usr/bin/stat \"\$@\""
fake install 'args=(); skip=0; for a in "$@"; do if [ "$skip" = 1 ]; then skip=0; continue; fi; case "$a" in -o|-g) skip=1 ;; *) args+=("$a") ;; esac; done; exec /usr/bin/install "${args[@]}"'
# sudo: drop its options and run the command as ourselves
fake sudo 'while [ $# -gt 0 ]; do case "$1" in -n|-H|-E|-S) shift ;; -u) shift 2 ;; -v) exit 0 ;; *) break ;; esac; done; [ $# -gt 0 ] || exit 0; exec "$@"'
fake dseditgroup "case \"\$2\" in checkmember) [ -e '$STATE/admins/'\"\$4\" ]; exit \$? ;; edit) touch '$STATE/admins/'\"\$4\"; exit 0 ;; esac; exit 0"
fake dscl "shift; case \"\$1\" in
  -read) u=\"\${2#/Users/}\"; [ -e '$STATE/users/'\"\$u\" ] || exit 56
         case \"\$3\" in UniqueID) echo 'UniqueID: 501' ;; IsHidden) echo \"IsHidden: \$(cat '$STATE/users/'\"\$u\".hidden 2>/dev/null || echo 0)\" ;; esac ;;
  -create) u=\"\${2#/Users/}\"; [ \"\$3\" = IsHidden ] && echo \"\$4\" > '$STATE/users/'\"\$u\".hidden ;;
esac; exit 0"
fake sysadminctl "pw=\$(cat); [ -n \"\$pw\" ] || exit 1; while [ \$# -gt 0 ]; do [ \"\$1\" = -addUser ] && { touch '$STATE/users/'\"\$2\"; echo \"\$*\" > '$STATE/sysadminctl.'\"\$2\"; }; shift; done; exit 0"
fake brew "case \"\$1\" in
  list) [ -e '$STATE/brew/'\"\$3\" ]; exit \$? ;;
  install) shift; for p in \"\$@\"; do touch '$STATE/brew/'\"\$p\"; done; exit 0 ;;
esac; exit 0"
cp "$BIN/brew" "$BREW/bin/brew"
# ssh as git runs it: find the host, run the remote command here. A read-only key cannot receive a push.
fake ssh 'while [ $# -gt 0 ]; do case "$1" in -i|-o|-p|-l) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
cmd="$*"
case "$cmd" in
  git-receive-pack*) if [ -e "$FAKE_SSH_READONLY" ]; then echo "ERROR: The key you are attempting to authenticate with has been marked as read only." >&2; exit 1; fi ;;
esac
export PATH="'"$REAL_GIT_EXEC"':$PATH"
eval "$cmd"'
# The Command Line Tools: present when $F/clt/usr/bin/git is. Until then git is Apple's stub, which fails.
CLT="$F/clt"
fake xcode-select "[ \"\${1:-}\" = -p ] && [ -x '$CLT/usr/bin/git' ] && { echo '$CLT'; exit 0; }; exit 2"
fake softwareupdate "echo \"softwareupdate \$*\" >> '$STATE/softwareupdate.log'
case \"\${1:-}\" in
  -l) [ -e \"\$TOCKMOX_CLT_MARKER\" ] && printf '* Label: Command Line Tools for Xcode-26.0\\n\\tTitle: old\\n* Label: Command Line Tools for Xcode-26.1\\n\\tTitle: new\\n'; exit 0 ;;
  -i) mkdir -p '$CLT/usr/bin' && ln -sf '$REAL_GIT' '$CLT/usr/bin/git'; exit 0 ;;
esac; exit 0"
fake git "[ -x '$CLT/usr/bin/git' ] || { echo 'xcrun: error: invalid active developer path, missing xcrun' >&2; exit 1; }; exec '$REAL_GIT' \"\$@\""
# gpg: the bare name is what sudo's secure_path finds (nothing useful); Homebrew's is the real one.
fake gpg 'exit 0'
printf '#!/bin/bash\n[ -n "${FAKE_GPG_EMPTY:-}" ] && exit 0\nprintf "pub   ed25519/0123456789ABCDEF 2026-01-01 [SC]\\n      Key fingerprint = 0123 4567 89AB CDEF 0123  4567 89AB CDEF 0123 4567\\nuid                 Forge merge signer\\n"\n' > "$BREW/bin/gpg"
chmod +x "$BREW/bin/gpg"
fake ssh-keyscan "echo \"\$FAKE_HOSTNAME \$(cut -d' ' -f1,2 '$F/hostkey.pub')\""
ssh-keygen -q -t ed25519 -N '' -C hostkey -f "$F/hostkey"

# ------------------------------------------------------------------ keys, toolkit and site
K="$T/keys"; mkdir -p "$K"
ssh-keygen -q -t ed25519 -N '' -f "$K/good" -C good
ssh-keygen -q -t ed25519 -N '' -f "$K/other" -C other
signer_line() { printf '%s namespaces="git" %s\n' "$1" "$(cut -d' ' -f1,2 "$K/$2.pub")"; }

# the toolkit repository: the real wrapper and facts script, a stub playbook
TK="$T/toolkit-repo"; mkdir -p "$TK/ai-node/bin" "$TK/ai-node/playbooks"
cp "$AI/bin/tockmox-ai-node-converge" "$AI/bin/tockmox-ai-node-facts" "$TK/ai-node/bin/"
cp "$AI/playbooks/site_vars.py" "$TK/ai-node/playbooks/site_vars.py"
printf -- '- hosts: localhost\n  tasks: []\n' > "$TK/ai-node/playbooks/ai-node.yml"
printf '[defaults]\n' > "$TK/ai-node/ansible.cfg"
git -C "$TK" init -q && git -C "$TK" add -A && git -C "$TK" commit -q -m toolkit && git -C "$TK" tag v0.0.1

make_site() {  # DIR [KEYNAME]: a site with one node, every commit signed by KEYNAME (default good)
  local d="$1" key="${2:-good}"
  rm -rf "$d"; mkdir -p "$d/ai-nodes/n1"; git -C "$d" init -q
  printf 'schema: tockmox.ai-node.fleet/v1\ntoolkit:\n  repo: %s\n  ref: v0.0.1\n' "$TK" > "$d/ai-nodes/fleet.yaml"
  printf 'schema: tockmox.ai-node/v1\naiNodeId: n1\n' > "$d/ai-nodes/n1/ai-node.yaml"
  printf 'schema: tockmox.ai-node.desired/v1\naiNodeId: n1\n' > "$d/ai-nodes/n1/desired.yaml"
  signer_line g good > "$d/ai-nodes/allowed_signers"
  git -C "$d" add -A
  git -C "$d" -c gpg.format=ssh -c "user.signingkey=$K/$key" commit -q -S -m site
}
SITE="$T/site"; make_site "$SITE"

# a fake ansible that prints a clean recap
printf '#!/bin/sh\nprintf "PLAY RECAP\\nlocalhost : ok=1 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\\n"\n' > "$BIN/ansible"
chmod +x "$BIN/ansible"
printf '#!/bin/sh\nexit 113\n' > "$BIN/launchctl"; chmod +x "$BIN/launchctl"

# ------------------------------------------------------------------ running it
boot() {  # ANSWERS-TEXT args...; output in $T/out; sets rc
  local answers="$1"; shift
  printf '%s' "$answers" > "$T/answers"
  PATH="$BIN:$REAL_PATH" TOCKMOX_ROOT="$R" TOCKMOX_BREW_PREFIX="$BREW" TOCKMOX_SUDOERS_DIR="$F/sudoers.d" \
    TOCKMOX_BOOTSTRAP_ANSWERS="$T/answers" TOCKMOX_ANSIBLE="$BIN/ansible" TOCKMOX_LAUNCHCTL="$BIN/launchctl" \
    TOCKMOX_LAUNCHD_DIR="$F/launchd" FAKE_HOSTNAME=git.example.invalid FAKE_SSH_READONLY="$F/readonly" \
    TOCKMOX_USERS_DIR="$F/Users" TOCKMOX_CLT_MARKER="$F/clt-marker" \
    bash "$BOOT" "$@" > "$T/out" 2>&1 < /dev/null
  rc=$?
}
mkdir -p "$F/sudoers.d" "$F/launchd"
fresh() { rm -rf "$R" "$STATE/users" "$STATE/admins" "$STATE/brew" "$STATE/brew-owner" "$F/sudoers.d" "$F/Users" "$CLT"; mkdir -p "$STATE/users" "$STATE/admins" "$STATE/brew" "$F/sudoers.d" "$F/launchd" "$F/Users" "$CLT/usr/bin"; ln -s "$REAL_GIT" "$CLT/usr/bin/git"; rm -f "$F/readonly" "$F/clt-marker" "$STATE/softwareupdate.log"; }

# ================================================================== 1. a public site over a path, warn mode
echo "first run, site reached without a key"
R="$T/root1"; fresh
boot $'\n'$'yes\n' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1
eq "it exits 0" "$rc" 0
check "the converge account and the service account were created" bash -c "[ -e '$STATE/users/tockmox' ] && [ -e '$STATE/users/inference' ]"
check "the service account was hidden" bash -c "[ \"\$(cat '$STATE/users/inference.hidden')\" = 1 ]"
check "the converge account joined admin" test -e "$STATE/admins/tockmox"
check "the converge account's home was made, 0700" bash -c "[ \"\$(stat -c %a '$F/Users/tockmox')\" = 700 ]"
check "Homebrew was handed to the converge account" bash -c "[ \"\$(cat '$STATE/brew-owner')\" = tockmox ]"
check "ansible git sops age gnupg were installed" bash -c "for p in ansible git sops age gnupg; do [ -e '$STATE/brew/'\$p ] || exit 1; done"
check "the tree exists with the secrets directory 0711" bash -c "[ -d '$R/models/hf' ] && [ \"\$(stat -c %a '$R/secrets')\" = 711 ]"
check "the sudoers fragment says what the role says" grep -q 'tockmox ALL=(ALL) NOPASSWD: ALL' "$F/sudoers.d/tockmox-ai-node"
check "an age key was made, 0600" bash -c "[ \"\$(stat -c %a '$R/etc/age.key')\" = 600 ]"
check "no deploy key is made for a keyless site" test ! -e "$R/etc/deploy_key"
check "the age RECIPIENT is printed" grep -q 'age1[0-9a-z]\{50,\}' "$T/out"
check "the age PRIVATE key is never printed" bash -c "! grep -q 'AGE-SECRET-KEY' '$T/out'"
check "no private key block is printed" bash -c "! grep -q 'PRIVATE KEY' '$T/out'"
check "the signers were shown with a fingerprint before pinning" grep -q 'SHA256:' "$T/out"
check "allowed_signers was pinned" cmp -s "$SITE/ai-nodes/allowed_signers" "$R/etc/allowed_signers"
check "ai-node.env has no secret and the right ids" bash -c "grep -q '^AI_NODE_ID=n1\$' '$R/etc/ai-node.env' && grep -q '^SIGNING_MODE=warn\$' '$R/etc/ai-node.env' && ! grep -qiE '^[A-Z_]*(KEY|SECRET|TOKEN|PASSWORD)[A-Z_]*=' '$R/etc/ai-node.env'"
check "the wrapper was installed from the toolkit checkout" test -x "$R/bin/tockmox-ai-node-converge"
check "the toolkit is checked out at the ref" bash -c "[ \"\$(git -C '$R/toolkit' describe --tags --exact-match)\" = v0.0.1 ]"
check "the first converge ran and recorded success" bash -c "grep -q '\"last_exit\": 0' '$R/var/state.json'"
check "the first converge verified the head against the pinned signer" bash -c "grep -q '\"signature_ok\": 1' '$R/var/state.json'"

echo "second run changes nothing and asks nothing"
before="$(find "$R/etc" -type f | sort | xargs cksum 2>/dev/null)"
boot '' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1
eq "it exits 0" "$rc" 0
check "it says the accounts exist" grep -q 'account tockmox exists' "$T/out"
check "it says the signers are already pinned" grep -q 'already pinned' "$T/out"
eq "the keys and pins are untouched" "$(find "$R/etc" -type f | sort | xargs cksum 2>/dev/null | grep -v ai-node.env)" "$(printf '%s\n' "$before" | grep -v ai-node.env)"

# ================================================================== 2. refusals
echo "declining the signers pins nothing"
R="$T/root2"; fresh
boot $'\n'$'no\n' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
check "it exits non-zero" test "$rc" != 0
check "nothing was pinned" test ! -e "$R/etc/allowed_signers"
check "it says nothing was changed" grep -q 'not pinned' "$T/out"

echo "enforce mode with no signers to pin"
R="$T/root3"; fresh
SITE2="$T/site2"; make_site "$SITE2"; git -C "$SITE2" rm -q ai-nodes/allowed_signers; git -C "$SITE2" commit -q -m "no signers"
boot $'\n' --ai-node-id n1 --site-repo "$SITE2" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --signing-mode enforce --no-apply
check "enforce without ai-nodes/allowed_signers is refused" bash -c "[ $rc != 0 ] && grep -q 'enforce but the site has no' '$T/out'"

echo "a missing toolkit ref"
R="$T/root4"; fresh
boot $'\n'$'yes\n' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v9.9.9 --no-apply
check "an unknown toolkit ref is refused" bash -c "[ $rc != 0 ] && grep -q 'no ref v9.9.9' '$T/out'"

echo "an old macOS"
R="$T/root5"; fresh
FAKE_OS=14.5 PATH="$BIN:$REAL_PATH" boot '' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --no-apply
check "a macOS older than the floor stops at preflight" bash -c "[ $rc != 0 ] && grep -q 'older than 26.2' '$T/out' && [ ! -e '$STATE/users/tockmox' ]"

# ================================================================== 3. a keyed site over ssh
echo "a private site over ssh with a read-only deploy key"
R="$T/root6"; fresh; : > "$F/readonly"
SSHURL="ssh://git@git.example.invalid$SITE"
boot $'\n'$'yes\n'$'yes\n' --ai-node-id n1 --site-repo "$SSHURL" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
eq "it exits 0" "$rc" 0
check "a deploy key was made, 0600" bash -c "[ \"\$(stat -c %a '$R/etc/deploy_key')\" = 600 ]"
check "the deploy key's public half and fingerprint are printed" bash -c "grep -q 'ssh-ed25519 ' '$T/out' && grep -q 'fingerprint: 256 SHA256:' '$T/out'"
check "the deploy key's private half is never printed" bash -c "! grep -qF \"\$(sed -n '2p' '$R/etc/deploy_key')\" '$T/out'"
check "the host key was shown, then pinned" bash -c "grep -q 'presents these host keys' '$T/out' && grep -q 'git.example.invalid ssh-ed25519' '$R/etc/known_hosts'"
check "it proved the key cannot push" grep -q 'read-only confirmed' "$T/out"
check "the pause came before the clone" bash -c "[ \$(grep -n 'Press Return' '$T/out' | head -1 | cut -d: -f1) -lt \$(grep -n 'cloned the site' '$T/out' | head -1 | cut -d: -f1) ]"

echo "a deploy key that can write is refused"
R="$T/root7"; fresh; rm -f "$F/readonly"
boot $'\n'$'yes\n'$'yes\n' --ai-node-id n1 --site-repo "$SSHURL" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
check "a writable deploy key stops the bootstrap" bash -c "[ $rc != 0 ] && grep -q 'can WRITE to the site repository' '$T/out'"

echo "declining the host key pins nothing"
R="$T/root8"; fresh; : > "$F/readonly"
boot $'\n'$'no\n' --ai-node-id n1 --site-repo "$SSHURL" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
check "no known_hosts is written when the fingerprints are declined" bash -c "[ $rc != 0 ] && [ ! -s '$R/etc/known_hosts' ]"

# ================================================================== 4. adoption
echo "adopting a node that already serves"
R="$T/root9"; fresh
boot $'\n'$'yes\n'$'no\n' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --adopt --legacy-converger-label com.example.old --legacy-converger-label com.example.older
eq "it exits 0" "$rc" 0
check "the env file skips the converge timer" grep -q '^SKIP_TAGS=' "$R/etc/ai-node.env"
check "both legacy labels are in the env file, space separated" grep -q '^LEGACY_CONVERGER_LABELS="com.example.old com.example.older"$' "$R/etc/ai-node.env"
check "the preview ran before anything was applied" bash -c "grep -q 'what a converge WOULD change' '$T/out'"
check "declining the apply left only a preview" bash -c "grep -q 'left as a preview' '$T/out' && [ ! -s '$R/var/state.json' ]"

# ================================================================== 4a. found on the first Mac
echo "a Mac with no Command Line Tools: they go in before the first git call"
R="$T/root11"; fresh; rm -rf "$CLT"
boot $'\n'$'yes\n' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
eq "it exits 0" "$rc" 0
check "softwareupdate installed the newest Command Line Tools label" grep -q 'softwareupdate -i Command Line Tools for Xcode-26.1' "$STATE/softwareupdate.log"
check "the in-progress marker is removed afterwards" test ! -e "$F/clt-marker"
check "the git stub was never hit" bash -c "! grep -q 'invalid active developer path' '$T/out'"

echo "a dry run on a Mac with no Command Line Tools"
R="$T/root12"; fresh; rm -rf "$CLT"
boot '' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --dry-run
eq "it exits 0" "$rc" 0
check "it says it would install them" grep -q 'would install the Command Line Tools' "$T/out"
check "it installed nothing" bash -c "[ ! -e '$STATE/softwareupdate.log' ] && [ ! -e '$CLT/usr/bin/git' ]"

echo "an existing account whose home was never made"
R="$T/root13"; fresh; touch "$STATE/users/tockmox"
boot $'\n'$'yes\n' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
eq "it exits 0" "$rc" 0
check "the missing home is made on a re-run" test -d "$F/Users/tockmox"

echo "a toolkit ref that is a branch other than the default"
git -C "$TK" checkout -q -b rel && echo rel > "$TK/rel" && git -C "$TK" add -A && git -C "$TK" commit -q -m rel && git -C "$TK" checkout -q main
R="$T/root14"; fresh
boot $'\n'$'yes\n' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref rel --no-apply
eq "it exits 0" "$rc" 0
eq "the toolkit is checked out at the branch's head" "$(git -C "$R/toolkit" rev-parse HEAD 2>/dev/null)" "$(git -C "$TK" rev-parse rel)"

echo "the forge's GPG signers are shown with Homebrew's gpg"
SITE3="$T/site3"; make_site "$SITE3"; printf 'not really armored\n' > "$SITE3/ai-nodes/gpg-signers.asc"
git -C "$SITE3" add -A; git -C "$SITE3" -c gpg.format=ssh -c "user.signingkey=$K/good" commit -q -S -m gpg
R="$T/root15"; fresh
boot $'\n'$'yes\n'$'yes\n' --ai-node-id n1 --site-repo "$SITE3" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
eq "it exits 0" "$rc" 0
check "the GPG fingerprint was shown before pinning" grep -q 'Key fingerprint = 0123' "$T/out"
check "gpg-signers.asc was pinned" cmp -s "$SITE3/ai-nodes/gpg-signers.asc" "$R/etc/gpg-signers.asc"
R="$T/root16"; fresh
FAKE_GPG_EMPTY=1 boot $'\n'$'yes\n'$'yes\n' --ai-node-id n1 --site-repo "$SITE3" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --no-apply
check "an empty GPG key list stops the bootstrap" bash -c "[ $rc != 0 ] && grep -q 'shows no keys' '$T/out'"
check "an empty GPG key list pins nothing" test ! -e "$R/etc/gpg-signers.asc"

# ================================================================== 5. dry run
echo "a dry run touches nothing"
R="$T/root10"; fresh
boot '' --ai-node-id n1 --site-repo "$SITE" --toolkit-repo "$TK" --toolkit-ref v0.0.1 --dry-run
eq "it exits 0" "$rc" 0
check "it printed what it would do" grep -q '\[dry-run\]' "$T/out"
check "no account, no tree, no sudoers fragment, no keys" bash -c "[ ! -e '$STATE/users/tockmox' ] && [ ! -e '$R' ] && [ -z \"\$(ls '$F/sudoers.d')\" ]"

echo
echo "bootstrap-flow: $pass passed, $fail failed"
[ "$fail" = 0 ]

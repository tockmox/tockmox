#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# bootstrap-node.sh: turn a freshly set-up Mac into a GitOps-managed Tockmox AI node.
#
#   scp ai-node/bootstrap-node.sh admin@HOST:/tmp/
#   ssh -t admin@HOST 'bash /tmp/bootstrap-node.sh --ai-node-id ID --site-repo URL [options]'
#
# Run it as the human administrator who finished Setup Assistant, from a terminal (ssh -t),
# because it asks you to confirm things. It is the only step that is not driven from git, and
# it does the smallest amount that can be done safely and then hands over to the converger.
#
#   1  preflight         Apple silicon, macOS version, the repositories answer
#   2  accounts          tockmox (administrator, no login) and inference (hidden service account)
#   3  Homebrew          installed as you, then handed to tockmox; ansible git sops age gnupg installed
#   4  the /opt/tockmox tree, owners and modes as the toolkit expects, and the sudoers fragment
#   5  keys, made HERE: a deploy key and an age key. Only the PUBLIC halves and their
#      fingerprints are printed. The private halves never leave this machine.
#   6  PAUSE            you register the deploy key (read-only) and the age recipient
#   7  the site repository's host key: shown to you, pinned only when you say yes
#   8  clone the site and the toolkit; prove the deploy key cannot push
#   9  the signers: ai-nodes/allowed_signers (and gpg-signers.asc) are shown to you with their
#      fingerprints and pinned only when you say yes. Later commits are checked against THESE.
#   10 write /opt/tockmox/etc/ai-node.env, then the first converge, interactively
#
# Options:
#   --ai-node-id ID         the node's id; must equal a directory under ai-nodes/ in the site repo
#   --site-repo URL         the site repository (git@host:org/repo.git, ssh://, or https://)
#   --site-ref REF          branch or tag of the site repository (default main)
#   --toolkit-repo URL      default https://github.com/tockmox/tockmox.git
#   --toolkit-ref REF       the toolkit ref for the first converge (default: ai-nodes/fleet.yaml)
#   --signing-mode MODE     warn (default) or enforce
#   --min-version V         the lowest macOS this machine may run (default 26.2)
#   --adopt                 adopt a node that already serves: no converge timer is installed, running
#                           engines are not restarted, and the first converge is a --check --diff
#                           preview you then confirm. Retire the old converger yourself, then remove
#                           SKIP_TAGS from /opt/tockmox/etc/ai-node.env.
#   --legacy-converger-label L   the label of the old converger (with --adopt; repeatable)
#   --no-apply              stop after the clone and the pins; do not converge
#   --dry-run               print every action and change nothing
#   -h, --help
#
# Idempotent: run it again and every step that is already done says so and moves on.
#
# macOS bash 3.2 and BSD userland only. Nothing secret is printed, logged or passed on a command line.

set -uo pipefail

# ------------------------------------------------------------------ settings

AI_NODE_ID=""
SITE_REPO=""
SITE_REF="main"
TOOLKIT_REPO="https://github.com/tockmox/tockmox.git"
TOOLKIT_REF=""
SIGNING_MODE="warn"
MIN_VERSION="26.2"
ADOPT=0
NO_APPLY=0
DRY_RUN=0
LEGACY_LABELS=""

ROOT="${TOCKMOX_ROOT:-/opt/tockmox}"
CONVERGE_USER="tockmox"
SERVICE_USER="inference"
BREW_PREFIX="${TOCKMOX_BREW_PREFIX:-/opt/homebrew}"
SELF="${BASH_SOURCE[0]:-$0}"
ADMIN_USER="$(id -un)"

# ------------------------------------------------------------------ output

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf 'bootstrap-node: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '4,46p' "$SELF" | sed 's/^# \{0,1\}//'; }

# act DESCRIPTION CMD...: print what is about to happen; run it unless this is a dry run.
act() {
  local desc="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then
    printf '   [dry-run] %s\n' "$desc"
    return 0
  fi
  "$@"
}

# Questions go to the controlling terminal. TOCKMOX_BOOTSTRAP_ANSWERS names a file of answers instead
# (one line per question) for the tests; the prompts are then printed on stdout.
TTY_OPEN=0
tty_open() {
  [ "$TTY_OPEN" = 1 ] && return 0
  local src="${TOCKMOX_BOOTSTRAP_ANSWERS:-/dev/tty}"
  if ! { exec 3< "$src"; } 2>/dev/null; then
    die "this step needs a terminal. Run it with: ssh -t admin@HOST 'bash /tmp/bootstrap-node.sh ...'"
  fi
  TTY_OPEN=1
}
NL='
'
tty_say() {
  if [ -n "${TOCKMOX_BOOTSTRAP_ANSWERS:-}" ]; then printf '%s' "$1"; else printf '%s' "$1" > /dev/tty; fi
}

# ask PROMPT: needs the word yes, typed at the terminal. A dry run says what it would ask.
ask() {
  local prompt="$1" answer=""
  if [ "$DRY_RUN" = 1 ]; then
    printf '   [dry-run] would ask: %s\n' "$prompt"
    return 0
  fi
  tty_open
  tty_say "$NL$prompt [type yes] "
  read -r answer <&3 || true
  [ "$answer" = yes ]
}

pause() {
  local prompt="$1"
  if [ "$DRY_RUN" = 1 ]; then
    printf '   [dry-run] would wait: %s\n' "$prompt"
    return 0
  fi
  tty_open
  tty_say "$NL$prompt${NL}Press Return when done. "
  read -r _ <&3 || true
}

as_converge() { sudo -u "$CONVERGE_USER" -H "$@"; }

# The administrator's sudo credential lasts a few minutes by default and this script waits on people
# (the pause, the fingerprint questions) and on Homebrew. Refresh it in the background until we exit.
SUDO_KEEPALIVE=""
start_sudo_keepalive() {
  [ "$DRY_RUN" = 1 ] && return 0
  ( while kill -0 "$$" 2>/dev/null; do sudo -n -v >/dev/null 2>&1 || exit 0; sleep 50; done ) &
  SUDO_KEEPALIVE=$!
  trap 'stop_sudo_keepalive' EXIT
}
stop_sudo_keepalive() { [ -n "$SUDO_KEEPALIVE" ] && kill "$SUDO_KEEPALIVE" 2>/dev/null; SUDO_KEEPALIVE=""; }

version_ge() {
  local a="$1" b="$2" i x y
  for i in 1 2 3; do
    x="$(printf '%s' "$a" | cut -d. -f"$i")"; y="$(printf '%s' "$b" | cut -d. -f"$i")"
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"; x="${x:-0}"; y="${y:-0}"
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}

# ------------------------------------------------------------------ arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --ai-node-id) shift; AI_NODE_ID="${1:-}" ;;
    --site-repo) shift; SITE_REPO="${1:-}" ;;
    --site-ref) shift; SITE_REF="${1:-}" ;;
    --toolkit-repo) shift; TOOLKIT_REPO="${1:-}" ;;
    --toolkit-ref) shift; TOOLKIT_REF="${1:-}" ;;
    --signing-mode) shift; SIGNING_MODE="${1:-}" ;;
    --min-version) shift; MIN_VERSION="${1:-}" ;;
    --adopt) ADOPT=1 ;;
    --legacy-converger-label) shift; LEGACY_LABELS="${LEGACY_LABELS:+$LEGACY_LABELS }${1:-}" ;;
    --no-apply) NO_APPLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

[ -n "$AI_NODE_ID" ] || die "--ai-node-id is required"
[ -n "$SITE_REPO" ] || die "--site-repo is required"
case "$AI_NODE_ID" in *[!a-z0-9-]*|'') die "the node id is lower-case letters, digits and dashes" ;; esac
case "$SIGNING_MODE" in warn|enforce) ;; *) die "--signing-mode is warn or enforce" ;; esac
case "$SITE_REPO" in
  *[[:space:]]*|-*) die "that does not look like a repository URL" ;;
esac

# Does the site repository need the deploy key? Only an ssh remote does.
SITE_SSH=0
SITE_HOST=""
SITE_PORT=22
case "$SITE_REPO" in
  ssh://*)
    SITE_SSH=1
    rest="${SITE_REPO#ssh://}"; rest="${rest#*@}"; hostport="${rest%%/*}"
    SITE_HOST="${hostport%%:*}"
    case "$hostport" in *:*) SITE_PORT="${hostport##*:}" ;; esac ;;
  *@*:*)
    SITE_SSH=1
    rest="${SITE_REPO#*@}"; SITE_HOST="${rest%%:*}" ;;
esac

# ------------------------------------------------------------------ 1 preflight

preflight() {
  step "1 preflight"
  [ "$(uname -s)" = Darwin ] || die "this is for macOS (Linux support is phase 6)"
  [ "$(uname -m)" = arm64 ] || die "this is for Apple silicon (this machine is $(uname -m))"
  local v; v="$(sw_vers -productVersion)"
  version_ge "$v" "$MIN_VERSION" || die "macOS $v is older than $MIN_VERSION. Update it at the console first."
  note "macOS $v on Apple silicon"
  [ "$(id -u)" != 0 ] || die "run this as the human administrator, not as root; it uses sudo where it needs to"
  if ! id -Gn | tr ' ' '\n' | grep -x admin >/dev/null; then die "$ADMIN_USER is not in the admin group"; fi
  note "administrator: $ADMIN_USER"
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would ask for your sudo password"
  else
    sudo -v || die "sudo did not accept the password"
    start_sudo_keepalive
  fi
  note "toolkit repository: $TOOLKIT_REPO"
  if ! GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$TOOLKIT_REPO" >/dev/null 2>&1; then
    die "cannot read the toolkit repository $TOOLKIT_REPO (is the network up? is git installed? xcode-select --install)"
  fi
  if [ "$SITE_SSH" = 1 ]; then
    if command -v nc >/dev/null 2>&1 && ! nc -z -G 5 "$SITE_HOST" "$SITE_PORT" >/dev/null 2>&1; then
      die "cannot reach the site repository host $SITE_HOST on port $SITE_PORT"
    fi
    note "site repository host answers: $SITE_HOST:$SITE_PORT"
  else
    case "$SITE_REPO" in
      https://*) GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$SITE_REPO" >/dev/null 2>&1 \
                   || die "cannot read $SITE_REPO without credentials. A private site repository needs an ssh URL and a deploy key." ;;
    esac
    note "site repository is read without a key: $SITE_REPO"
  fi
  [ "$ADOPT" = 1 ] && note "adopt mode: no converge timer, no engine restarts"
  return 0
}

# ------------------------------------------------------------------ 2 accounts

user_exists() { dscl . -read "/Users/$1" UniqueID >/dev/null 2>&1; }

# make_account NAME FULLNAME ADMINFLAG(0|1) HOME SHELL
make_account() {
  local name="$1" full="$2" isadmin="$3" home="$4" shell="$5" pw
  if user_exists "$name"; then note "account $name exists"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then note "[dry-run] would create the account $name"; return 0; fi
  # The password is random, used once and never shown: these accounts have no interactive login.
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)"
  if [ "$isadmin" = 1 ]; then
    printf '%s\n' "$pw" | sudo sysadminctl -addUser "$name" -fullName "$full" -home "$home" -shell "$shell" -admin -password - >/dev/null 2>&1
  else
    printf '%s\n' "$pw" | sudo sysadminctl -addUser "$name" -fullName "$full" -home "$home" -shell "$shell" -password - >/dev/null 2>&1
  fi
  pw=""
  if ! user_exists "$name"; then
    note "sysadminctl would not take the password from a pipe; it will ask. Type any long random password and forget it."
    if [ "$isadmin" = 1 ]; then
      sudo sysadminctl -addUser "$name" -fullName "$full" -home "$home" -shell "$shell" -admin -password - || true
    else
      sudo sysadminctl -addUser "$name" -fullName "$full" -home "$home" -shell "$shell" -password - || true
    fi
  fi
  user_exists "$name" || die "could not create the account $name"
  note "created the account $name"
}

accounts() {
  step "2 accounts"
  make_account "$CONVERGE_USER" "Tockmox converge" 1 "/Users/$CONVERGE_USER" /bin/bash
  make_account "$SERVICE_USER" "Tockmox inference service" 0 /var/empty /usr/bin/false
  if [ "$DRY_RUN" = 0 ] && user_exists "$SERVICE_USER"; then
    if [ "$(dscl . -read "/Users/$SERVICE_USER" IsHidden 2>/dev/null | awk '{print $2}')" != 1 ]; then
      sudo dscl . -create "/Users/$SERVICE_USER" IsHidden 1
      sudo defaults write /Library/Preferences/com.apple.loginwindow HiddenUsersList -array-add "$SERVICE_USER"
      note "$SERVICE_USER is hidden from the login window"
    fi
    sudo dscl . -create "/Users/$SERVICE_USER" UserShell /usr/bin/false
  fi
  if [ "$DRY_RUN" = 0 ] && ! dseditgroup -o checkmember -m "$CONVERGE_USER" admin >/dev/null 2>&1; then
    sudo dseditgroup -o edit -a "$CONVERGE_USER" -t user admin
  fi
  return 0
}

# ------------------------------------------------------------------ 3 Homebrew

homebrew() {
  step "3 Homebrew"
  if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
    note "installing Homebrew as $ADMIN_USER (its installer needs your sudo password)"
    if [ "$DRY_RUN" = 1 ]; then
      note "[dry-run] would run the Homebrew installer, non-interactively"
    else
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "the Homebrew installer failed"
    fi
  else
    note "Homebrew is installed"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would hand $BREW_PREFIX to $CONVERGE_USER (Homebrew refuses to run as root, and the converge job must be able to install)"
  elif [ "$(stat -f %Su "$BREW_PREFIX")" != "$CONVERGE_USER" ]; then
    sudo chown -R "$CONVERGE_USER":admin "$BREW_PREFIX" || die "could not hand $BREW_PREFIX to $CONVERGE_USER"
    note "$BREW_PREFIX now belongs to $CONVERGE_USER"
  fi
  local pkg missing=""
  for pkg in ansible git sops age gnupg; do
    if [ "$DRY_RUN" = 1 ] || ! as_converge env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW_PREFIX/bin/brew" list --versions "$pkg" >/dev/null 2>&1; then
      missing="$missing $pkg"
    fi
  done
  if [ -z "$missing" ]; then
    note "ansible git sops age gnupg are installed"
  elif [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would install:$missing"
  else
    # shellcheck disable=SC2086  # a short list of formula names, split on purpose
    as_converge env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW_PREFIX/bin/brew" install $missing \
      || die "brew install failed"
  fi
  return 0
}

# ------------------------------------------------------------------ 4 tree and sudoers

tree() {
  step "4 the $ROOT tree and the sudoers fragment"
  local spec path owner mode full
  # path:owner:mode   (owner c = converge account, s = service account)
  for spec in ":c:0755" "bin:c:0755" "etc:c:0755" "site:c:0755" "toolkit:c:0755" "engines:c:0755" \
              "secrets:c:0711" "textfile:c:0775" "log:c:0755" "var:c:0755" "var/audit:c:0775" "var/rootfacts.d:c:0755" \
              "var/service-home:s:0700" "models:s:0755" "models/hf:s:0755" "models/ollama:s:0755" "models/gguf:s:0755"; do
    path="${spec%%:*}"; spec="${spec#*:}"; owner="${spec%%:*}"; mode="${spec#*:}"
    if [ -n "$path" ]; then full="$ROOT/$path"; else full="$ROOT"; fi
    [ "$owner" = c ] && owner="$CONVERGE_USER" || owner="$SERVICE_USER"
    if [ "$DRY_RUN" = 1 ]; then
      printf '   [dry-run] mkdir %s (%s, %s)\n' "$full" "$owner" "$mode"
    else
      if ! { sudo mkdir -p "$full" && sudo chown "$owner":staff "$full" && sudo chmod "$mode" "$full"; }; then die "could not make $full"; fi
    fi
  done
  local frag="${TOCKMOX_SUDOERS_DIR:-/etc/sudoers.d}/tockmox-ai-node"
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would write $frag (validated with visudo -cf): $CONVERGE_USER ALL=(ALL) NOPASSWD: ALL"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  # The same bytes the converge_timer role writes, so the first converge changes nothing here.
  {
    printf '# Managed by tockmox-ai-node (role converge_timer). The converge job runs as\n'
    printf '# %s with no password and no terminal; bootstrap-node.sh seeds this file.\n' "$CONVERGE_USER"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$CONVERGE_USER"
  } > "$tmp"
  if sudo visudo -cf "$tmp" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g wheel "$tmp" "$frag" && note "sudoers fragment in place"
  else
    rm -f "$tmp"; die "the sudoers fragment did not validate; nothing was written"
  fi
  rm -f "$tmp"
  return 0
}

# ------------------------------------------------------------------ 5 keys

DEPLOY_PUB=""
AGE_RECIPIENT=""

keys() {
  step "5 keys, made on this machine"
  local dk="$ROOT/etc/deploy_key" ak="$ROOT/etc/age.key"
  if [ "$SITE_SSH" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
      note "[dry-run] would make an ed25519 deploy key at $dk (owner $CONVERGE_USER, mode 0600)"
    elif ! as_converge test -f "$dk"; then
      as_converge ssh-keygen -q -t ed25519 -N '' -C "tockmox-ai-node $AI_NODE_ID@$(hostname -s)" -f "$dk" || die "ssh-keygen failed"
      as_converge chmod 0600 "$dk"
      note "made the deploy key"
    else
      note "the deploy key exists"
    fi
  fi
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would make an age key at $ak (owner $CONVERGE_USER, mode 0600)"
  elif ! as_converge test -f "$ak"; then
    # age-keygen writes the key to the file and prints only the PUBLIC key, on stderr; keep stderr off the screen.
    as_converge "$BREW_PREFIX/bin/age-keygen" -o "$ak" >/dev/null 2>&1 || die "age-keygen failed"
    as_converge chmod 0600 "$ak"
    note "made the age key"
  else
    note "the age key exists"
  fi
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  AGE_RECIPIENT="$(as_converge "$BREW_PREFIX/bin/age-keygen" -y "$ak" 2>/dev/null)"
  [ -n "$AGE_RECIPIENT" ] || die "could not read the age recipient"
  say
  if [ "$SITE_SSH" = 1 ]; then
    DEPLOY_PUB="$(as_converge cat "$dk.pub")"
    say "Deploy key (public half). Register it on the site repository as READ-ONLY:"
    say "  $DEPLOY_PUB"
    say "  fingerprint: $(as_converge ssh-keygen -lf "$dk.pub" | cut -d' ' -f1-2)"
    say
  fi
  say "age recipient (public). Add it to ai-nodes/.sops.yaml for ai-nodes/$AI_NODE_ID/secrets.sops.yaml,"
  say "then re-key the file (sops updatekeys) and commit:"
  say "  $AGE_RECIPIENT"
}

# ------------------------------------------------------------------ 6 pause

register() {
  step "6 register the keys"
  if [ "$SITE_SSH" = 1 ]; then
    pause "On the site repository's host, add the deploy key above, read-only (for GitHub: Settings > Deploy keys, leave 'Allow write access' UNTICKED).
Add the age recipient above to ai-nodes/.sops.yaml, run sops updatekeys on ai-nodes/$AI_NODE_ID/secrets.sops.yaml if it exists, commit and push.
Also commit ai-nodes/$AI_NODE_ID/ai-node.yaml and desired.yaml, ai-nodes/fleet.yaml, and ai-nodes/allowed_signers."
  else
    pause "Add the age recipient above to ai-nodes/.sops.yaml and re-key secrets.sops.yaml if there is one; commit and push.
Make sure ai-nodes/$AI_NODE_ID/ai-node.yaml and desired.yaml, ai-nodes/fleet.yaml and ai-nodes/allowed_signers are committed."
  fi
}

# ------------------------------------------------------------------ 7 host key

pin_host_key() {
  step "7 the site repository's host key"
  if [ "$SITE_SSH" != 1 ]; then note "not an ssh remote: nothing to pin"; return 0; fi
  local kh="$ROOT/etc/known_hosts" scan fp
  if [ "$DRY_RUN" = 0 ] && as_converge test -s "$kh"; then
    note "a host key is already pinned in $kh"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would fetch the host key of $SITE_HOST, show its fingerprints, and pin it only if you type yes"
    return 0
  fi
  scan="$(mktemp)"
  if [ "$SITE_PORT" = 22 ]; then
    ssh-keyscan -T 10 -t ed25519,ecdsa,rsa "$SITE_HOST" > "$scan" 2>/dev/null
  else
    ssh-keyscan -T 10 -p "$SITE_PORT" -t ed25519,ecdsa,rsa "$SITE_HOST" > "$scan" 2>/dev/null
  fi
  [ -s "$scan" ] || { rm -f "$scan"; die "could not fetch the host key of $SITE_HOST"; }
  say "The site repository host $SITE_HOST presents these host keys. Compare them with what the"
  say "forge publishes (GitHub: https://api.github.com/meta, key 'ssh_key_fingerprints') or with a"
  say "machine you trust. A scan over the network proves nothing by itself."
  ssh-keygen -lf "$scan" | sed 's/^/   /'
  fp=0
  ask "Do these fingerprints match? Pin them for $SITE_HOST?" && fp=1
  if [ "$fp" != 1 ]; then rm -f "$scan"; die "not pinned. Nothing was changed."; fi
  # shellcheck disable=SC2016  # $1 is for the inner shell
  as_converge sh -c 'cat > "$1" && chmod 0644 "$1"' _ "$kh" < "$scan"
  rm -f "$scan"
  note "pinned in $kh"
}

# ------------------------------------------------------------------ 8 clone

git_ssh_command() {
  printf 'ssh -i %s/etc/deploy_key -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s/etc/known_hosts' "$ROOT" "$ROOT"
}

clone_repos() {
  step "8 clone the site and the toolkit"
  local sd="$ROOT/site" td="$ROOT/toolkit"
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would clone $SITE_REPO ($SITE_REF) to $sd and $TOOLKIT_REPO to $td"
    note "[dry-run] would try a push with --dry-run to prove the deploy key is read-only"
    return 0
  fi
  if as_converge test -d "$sd/.git"; then
    note "the site is cloned"
  else
    if [ "$SITE_SSH" = 1 ]; then
      as_converge env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(git_ssh_command)" git clone --quiet --branch "$SITE_REF" "$SITE_REPO" "$sd" \
        || die "could not clone the site. Is the deploy key registered, and is the ref $SITE_REF right?"
    else
      as_converge env GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$SITE_REF" "$SITE_REPO" "$sd" || die "could not clone the site"
    fi
    note "cloned the site"
  fi
  if [ "$SITE_SSH" = 1 ]; then
    local out
    if out="$(as_converge env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(git_ssh_command)" git -C "$sd" push --dry-run origin "HEAD:refs/heads/tockmox-write-check" 2>&1)"; then
      die "the deploy key can WRITE to the site repository. Remove it, register it again with 'Allow write access' off, and run this again. (This node must not be able to change its own configuration.)"
    fi
    case "$out" in
      *[Rr]ead*only*|*[Pp]ermission*|*denied*|*"not allowed"*|*"does not have"*) note "the deploy key cannot push: read-only confirmed" ;;
      *) note "WARNING: a push attempt failed, but not in a way that says read-only. Check the key in the forge's settings yourself." ;;
    esac
  fi
  if as_converge test -d "$td/.git"; then
    note "the toolkit is cloned"
  else
    as_converge env GIT_TERMINAL_PROMPT=0 git clone --quiet "$TOOLKIT_REPO" "$td" || die "could not clone the toolkit"
    note "cloned the toolkit"
  fi
  if [ -z "$TOOLKIT_REF" ]; then
    TOOLKIT_REF="$(as_converge "$BREW_PREFIX/opt/ansible/libexec/bin/python3" -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print((d.get("toolkit") or {}).get("ref") or "")
' "$sd/ai-nodes/fleet.yaml" 2>/dev/null)"
  fi
  [ -n "$TOOLKIT_REF" ] || die "no toolkit ref: pass --toolkit-ref or set toolkit.ref in ai-nodes/fleet.yaml"
  as_converge env GIT_TERMINAL_PROMPT=0 git -C "$td" fetch --quiet --tags --force origin >/dev/null 2>&1 || true
  as_converge git -C "$td" checkout --quiet --detach "$TOOLKIT_REF" || die "the toolkit has no ref $TOOLKIT_REF"
  note "toolkit at $TOOLKIT_REF ($(as_converge git -C "$td" rev-parse --short HEAD))"
}

# ------------------------------------------------------------------ 9 signers

pin_signers() {
  step "9 the signers"
  local sd="$ROOT/site/ai-nodes" etc="$ROOT/etc" src line key tmp shown=0
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would show ai-nodes/allowed_signers (and gpg-signers.asc) with fingerprints and pin them in $etc if you type yes"
    return 0
  fi
  if as_converge test -s "$etc/allowed_signers"; then
    note "allowed_signers is already pinned in $etc (it changes only by a commit an already-pinned key signed)"
  else
    src="$sd/allowed_signers"
    if ! as_converge test -s "$src"; then
      [ "$SIGNING_MODE" = enforce ] && die "signing mode is enforce but the site has no ai-nodes/allowed_signers to pin"
      note "the site has no ai-nodes/allowed_signers: commits will not be verified (warn mode)"
    else
      say "These keys may sign commits this node will apply:"
      tmp="$(mktemp)"
      while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        key="$(printf '%s\n' "$line" | tr ' ' '\n' | awk '/^(ssh-|ecdsa-|sk-)/{print $1; getline; print $1; exit}' | tr '\n' ' ')"
        [ -n "$key" ] || continue
        printf '%s\n' "$key" > "$tmp"
        printf '   %s  %s\n' "${line%% *}" "$(ssh-keygen -lf "$tmp" 2>/dev/null | cut -d' ' -f1-2)"
        shown=$((shown + 1))
      done < <(as_converge cat "$src")
      rm -f "$tmp"
      [ "$shown" -gt 0 ] || die "ai-nodes/allowed_signers holds no keys"
      ask "Pin these $shown signer(s) on this node?" || die "not pinned. Nothing was changed."
      as_converge install -m 0644 "$src" "$etc/allowed_signers"
      note "pinned allowed_signers"
    fi
  fi
  if as_converge test -s "$etc/gpg-signers.asc"; then
    note "gpg-signers.asc is already pinned"
  elif as_converge test -s "$sd/gpg-signers.asc"; then
    say "The forge's merge-signing key(s) (GPG):"
    as_converge gpg --show-keys --with-fingerprint --keyid-format long "$sd/gpg-signers.asc" 2>/dev/null | sed 's/^/   /'
    ask "Pin these GPG key(s)?" || die "not pinned. Nothing was changed."
    as_converge install -m 0644 "$sd/gpg-signers.asc" "$etc/gpg-signers.asc"
    note "pinned gpg-signers.asc"
  fi
  return 0
}

# ------------------------------------------------------------------ 10 env and the first converge

write_env() {
  step "10 configuration and the first converge"
  local envf="$ROOT/etc/ai-node.env"
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would write $envf (no secrets in it)"
  else
    local tmp; tmp="$(mktemp)"
    {
      printf '# Written by bootstrap-node.sh. No secrets live here.\n'
      printf 'AI_NODE_ID=%s\n' "$AI_NODE_ID"
      printf 'SITE_REPO=%s\n' "$SITE_REPO"
      printf 'SITE_REF=%s\n' "$SITE_REF"
      printf 'TOOLKIT_REPO=%s\n' "$TOOLKIT_REPO"
      printf 'TOOLKIT_REF=%s\n' "$TOOLKIT_REF"
      printf 'SIGNING_MODE=%s\n' "$SIGNING_MODE"
      printf 'ADMIN_USER=%s\n' "$ADMIN_USER"
      [ -n "$LEGACY_LABELS" ] && printf 'LEGACY_CONVERGER_LABELS="%s"\n' "$LEGACY_LABELS"
      [ "$ADOPT" = 1 ] && printf 'SKIP_TAGS=timer,converge_timer\n'
    } > "$tmp"
    sudo install -m 0644 -o "$CONVERGE_USER" -g staff "$tmp" "$envf"
    rm -f "$tmp"
    note "wrote $envf"
  fi
  if [ "$DRY_RUN" = 0 ]; then
    as_converge install -m 0755 "$ROOT/toolkit/ai-node/bin/tockmox-ai-node-converge" "$ROOT/bin/tockmox-ai-node-converge" \
      || die "the toolkit at $TOOLKIT_REF has no ai-node/bin/tockmox-ai-node-converge"
    as_converge install -m 0755 "$ROOT/toolkit/ai-node/bin/tockmox-ai-node-facts" "$ROOT/bin/tockmox-ai-node-facts" || true
  fi
  if [ "$NO_APPLY" = 1 ]; then
    note "--no-apply: stopping here. Converge with: sudo -u $CONVERGE_USER $ROOT/bin/tockmox-ai-node-converge"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] would run the first converge as $CONVERGE_USER"
    return 0
  fi
  if [ "$ADOPT" = 1 ]; then
    say "Adopt mode: first, what a converge WOULD change (nothing is written):"
    as_converge "$ROOT/bin/tockmox-ai-node-converge" --check --diff || note "the preview reported problems; read it above"
    ask "Apply it now? Retire the old converger FIRST: while it is installed the converge refuses to apply. No converge timer is installed, and running engines are not restarted." || { note "left as a preview. Apply later with: sudo -u $CONVERGE_USER $ROOT/bin/tockmox-ai-node-converge"; return 0; }
  fi
  say "First converge, interactively. The firewall comes first; if you are connected over SSH your"
  say "session is what confirms it, so stay connected."
  as_converge "$ROOT/bin/tockmox-ai-node-converge"
  local rc=$?
  if [ "$rc" = 0 ]; then
    say
    say "Done. The node converges itself from now on (unless this was an adoption)."
    say "Check it: sudo -u $CONVERGE_USER cat $ROOT/textfile/converge.prom"
  else
    say
    say "The first converge exited $rc. The reason is above and in $ROOT/log/converge.log."
    say "Fix it in git (or on the node) and run: sudo -u $CONVERGE_USER $ROOT/bin/tockmox-ai-node-converge"
  fi
  return "$rc"
}

# ------------------------------------------------------------------ main

main() {
  preflight
  accounts
  homebrew
  tree
  keys
  register
  pin_host_key
  clone_repos
  pin_signers
  write_env
}

main

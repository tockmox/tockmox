#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P16 ... "Move a running site in" (docs/administration/site-forge.md) on the install P09 made on the external
# route: a running site whose repository is on a forge of its own is moved into the built-in forge with the page's one
# command, `tockmox-install.sh move-in-forge`, and what the move left is read back independently of the command's own
# check. Six steps:
#
#   S01  GLUE: the site as the page finds it. P09's external route serves the site repository from a git daemon on
#        the throwaway (git://), and the page asks for the repository's https address, so the site is first put on an
#        external https forge with its whole history: one commit that names that forge in every repoURL, pushed
#        there, Argo CD given a credential for it (install.md 2c's Secret) and, when that forge is on a private CA,
#        the CA (argocd-tls-certs-cm under the forge's host name, merged), the root applied, and every Application
#        waited on until it is Synced and Healthy on that forge. Then a clean clone of it is the reader's checkout, an
#        age identity is made, and the sealing key is exported the way bootstrap-forge asks for it.
#   S02  before the move: the page's block resolves to one block and holds its three placeholders once each and one
#        --dry-run; Argo CD's root reads the external repository at the checkout's revision; there is no built-in
#        forge. Argo CD's Applications are kept, as they are now, for S06.
#   S03  the refusal: an untracked file in the checkout, then the block without --dry-run. It refuses, it says
#        nothing was touched, it never asks for the context, and nothing was written: no forge namespace, no copy of
#        Argo CD's credential, the root and the external repository where they were
#   S04  the block as printed (--dry-run): it ends "Dry run: nothing was changed", shows the migration commit's
#        files, and nothing was written
#   S05  the block with --dry-run removed, as the page says, the context typed at its prompt: the page's success
#        condition, "every Application reads the built-in forge, Synced and Healthy, and nothing was pruned"
#   S06  read back, against the Applications S02 kept: every Application that read the external repository reads the
#        built-in forge and the root is synced to the forge's main; every Application is Synced and Healthy; nothing
#        any Application managed was pruned; the forge's main is ONE commit on top of the pre-move head, the
#        installer's; the external repository's main is the forge's main, with the whole pre-move history under it
#        (the off-site copy); the credential copy is gone; and the block run again says "Nothing to do"
#
# THE PAGES PRINT ONE COMMAND HERE, the move. S03 to S06 run it as printed, with three placeholders filled (the
# checkout, the repository's address as a variable this path exports, so no report prints it, and an age public key)
# and the page's two edits: --dry-run taken out, and the context typed at the prompt. Everything in S01 is GLUE and is
# labelled so in the log, and so is the untracked file of S03.
#
# WHEN IT RUNS. run.sh discovers paths/P*.sh and gives this one P09's route group, so a plain run.sh reaches it. It
# does not run there. It needs TOCKMOX_P09_STATE, a p09-passed marker in it, TOCKMOX_P09_ROUTE=external (on the
# built-in route the site is already in the built-in forge), and TOCKMOX_P16_FROM_DIR: a directory holding the
# external repository's https address (git-url), two lines that can push to it (git-credentials), its host name
# (host), and its CA when its certificate is private (ca.crt). The p09 lane makes it with throwaway-cluster.sh
# offsite-repo, an empty repository named after the VM that destroy deletes. Any of them missing is BLOCKED with the
# reason, before any call to a cluster. A ca.crt is the forge's private CA: the page tells that reader to add
# move-in-forge's --from-ca, so this path adds it to the block (an edit the page asks for, and logged as one) and reads
# the forge with it too. A page that does not say so is BLOCKED, because the path would add a word it does not print.
# The page says Argo CD needs nothing new for that CA because it already reads that repository; a reader's Argo CD
# does, P09's does not (its site was on the git daemon), so S01 gives it the CA as GLUE, in the object Argo CD reads
# a repository's CA from: argocd-tls-certs-cm, keyed by the host name, merged so that every other entry is kept. No
# insecure flag. The repo-server mounts that ConfigMap, so the change reaches it without a restart, after the
# kubelet's sync (a minute or so), well inside the settle.
#
# NOTHING IS PUT BACK. The move is the page's end state, so the install is left on the built-in forge, with the
# external repository as its off-site copy, and the throwaway is destroyed with it. A kept run does not reach this
# path (the lane skips it). Paths that run after it on the same install read it on the built-in forge.
#
# ITS OWN STATE AND BUDGET. State goes under ${TOCKMOX_P09_STATE}/p16. TOCKMOX_P16_BUDGET (seconds, default 5400) is
# read before each step up to S05; once the move has begun the path runs to its end.
#
# TIME, worst case, from the waits below: S01 the settle (TOCKMOX_P16_SETTLE, 900 s) and a minute of pushes and the
# key export; S03 and S04 under a minute each; S05 the forge's install by bootstrap-forge (5 to 10 minutes on the lab),
# the cutover check (the page's --wait-seconds, 900 s) and the second bootstrap-forge run with its first off-site copy
# (about 3 minutes); S06 a minute. About 45 minutes at worst, about 20 when the product behaves.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null  # read at run time, from beside this file
. "${HERE}/../lib/assert.sh"

path_begin "P16-move-in-forge" \
  "after P09 on the external route: move-in-forge moves the running site into the built-in forge; every Application reads it, Synced and Healthy, nothing pruned, one migration commit, the old repository the off-site copy; a dirty checkout is refused before any write"

# --- preconditions: a declared environmental constraint (BLOCKED), not a failure and not silence ---
P09_STATE="${TOCKMOX_P09_STATE:-}"
blocked() { # REASON
  _emit "BLOCKED:  ${1}"
  _emit "          This path runs after P09, on the same cluster, from P09's state directory (see the header)."
  path_outcome BLOCKED "$1"
  exit 0
}
[ -n "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not set, so there is no P09 install on this cluster to read"
[ -d "$P09_STATE" ] || blocked "TOCKMOX_P09_STATE is not a directory (${P09_STATE})"
[ -f "${P09_STATE}/p09-passed" ] || blocked "P09 did not end PASS on this state directory (no p09-passed marker in it)"
[ "${TOCKMOX_P09_ROUTE:-}" = external ] \
  || blocked "TOCKMOX_P09_ROUTE is '${TOCKMOX_P09_ROUTE:-unset}', not external: on the built-in route the site is already in the built-in forge, so there is nothing to move in. Run the external route"
FROM_DIR="${TOCKMOX_P16_FROM_DIR:-}"
[ -n "$FROM_DIR" ] && [ -s "${FROM_DIR}/git-url" ] && [ -s "${FROM_DIR}/git-credentials" ] \
  || blocked "TOCKMOX_P16_FROM_DIR does not name a directory with git-url and git-credentials in it, so there is no external https repository to move the site in from (the p09 lane makes one with throwaway-cluster.sh offsite-repo)"
FROM_CA=""
[ ! -s "${FROM_DIR}/ca.crt" ] || FROM_CA="${FROM_DIR}/ca.crt"
SITE_LINE="$(grep -E '^(export|declare -x) SITE_REPO=' "${P09_STATE}/session.env" 2>/dev/null | tail -1 || true)"
[ -n "$SITE_LINE" ] || blocked "P09's session in ${P09_STATE} holds no SITE_REPO, so there is no site repository to move"
SITE_REPO="$( eval "${SITE_LINE#declare -x }" 2>/dev/null; printf '%s' "${SITE_REPO:-}" )"
[ -n "$SITE_REPO" ] && [ -d "$SITE_REPO" ] || blocked "the site repository P09 recorded is not a directory (${SITE_REPO:-unset})"
OLD_URL="$(git -C "$SITE_REPO" config --get remote.origin.url 2>/dev/null || true)"
[ -n "$OLD_URL" ] || blocked "the site repository has no remote named origin, so there is no running site repository to move from"

# every kubectl call below names its cluster with --context from this variable, and an empty value is
# refused rather than falling back to the current context (docs/deployment/fresh-install.md, "Name the
# cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"
REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"

STATE="${P09_STATE}/p16"
BUDGET="${TOCKMOX_P16_BUDGET:-5400}"
SETTLE="${TOCKMOX_P16_SETTLE:-900}"
POLL="${TOCKMOX_P16_POLL:-10}"
MOVE_TIMEOUT="${TOCKMOX_P16_MOVE_TIMEOUT:-3600}"
FPORT="${TOCKMOX_P16_FORGE_PORT:-3016}"
WS_SHELL="${TOCKMOX_P16_SHELL:-zsh}"
T0=$(date +%s)
mkdir -p "$STATE"
for t in kubectl git python3 age age-keygen; do
  command -v "$t" >/dev/null 2>&1 || { _emit "INFRA: '$t' is not on PATH"; path_outcome INFRA_ERROR "missing $t"; exit 1; }
done
[ "$WS_SHELL" = bash ] || command -v "$WS_SHELL" >/dev/null 2>&1 || { _emit "INFRA: '$WS_SHELL' is not on PATH"; path_outcome INFRA_ERROR "missing $WS_SHELL"; exit 1; }

# ------------------------------------------------------------- the stock install's names
# install/forge-move-in.sh and install/bootstrap-forge.sh: the forge's release and namespace, its organisation and
# repository, the in-cluster address Argo CD reads, the root Application, the admin Secret, the credential copy kept
# during the cutover, and the migration commit's author. install.md 2c: the site repository's credential Secret.
ARGO_NS=argocd
ROOT_APP=tockmox-root
FORGE_NS=tockmox-forge
FORGE_SVC=tockmox-forge-http
ADMIN_SECRET=tockmox-forge-admin
IN_URL="http://${FORGE_SVC}.${FORGE_NS}.svc.cluster.local:3000/tockmox/site.git"
CRED_SECRET=tockmox-site-repo
CRED_COPY=tockmox-site-repo-before-move
TLS_CM=argocd-tls-certs-cm
MIG_AUTHOR="Tockmox installer"
P16_FROM_URL="$(head -1 "${FROM_DIR}/git-url" | tr -d '[:space:]')"
FROM_HOST="$(head -1 "${FROM_DIR}/host" 2>/dev/null | tr -d '[:space:]')"
export P16_FROM_URL
TOCKMOX="${TOCKMOX_P16_TOCKMOX:-${TOCKMOX_P09_TOCKMOX_CLONE:-$(cd "${HERE}/../../.." && pwd)}}"
export TOCKMOX KUBE_CONTEXT

PAGE="docs/administration/site-forge.md"
PAGE_FILE="${TOCKMOX_P16_PAGE_FILE:-${HERE}/../../../${PAGE}}"
SECTION="## Move a running site in"
NEEDLE='move-in-forge --context'
SUCCESS_LINE="every Application reads the built-in forge, Synced and Healthy, and nothing was pruned"
FROM_TREE="${TOCKMOX_P16_FROM_TREE:-${TOCKMOX_P09_FROM_TREE:-0}}"
if [ -n "$FROM_CA" ]; then
  if [ "$FROM_TREE" = "1" ]; then page_text="$(cat "$PAGE_FILE" 2>/dev/null || true)"
  else page_text="$(git -C "$HERE" show "${REF}:${PAGE}" 2>/dev/null || true)"; fi
  # shellcheck disable=SC2016  # the backquotes are the page's own markup, matched literally
  printf '%s' "$page_text" | grep -F -- '`--from-ca FILE`' >/dev/null \
    || blocked "the external forge in TOCKMOX_P16_FROM_DIR is on a private CA (ca.crt), and ${PAGE} at this ref does not tell that reader to add --from-ca, so the path would add a word the page does not print. Name a forge on a publicly trusted certificate, or a ref whose page has it"
fi
EXTRACT="${HERE}/../lib/extract-block.sh"
PASTE="${HERE}/../lib/zsh-paste.py"
VERDICT_PY="${HERE}/../lib/p16-move-in-forge.py"
verdict() { python3 -I "$VERDICT_PY" "$@"; }
scrub() { verdict scrub --host "$FROM_HOST"; }

# the reader's files: a HOME of the path's own, so the page's "$HOME/tockmox-backup/..." are the path's
P16_HOME="${STATE}/home"
BACKUP="${P16_HOME}/tockmox-backup"
SITE_DIR="${STATE}/site"
AGE_ID="${STATE}/age-identity.txt"

# ------------------------------------------------------------- state helpers (P13's shape)
done_step() { [ -f "${STATE}/${1}.done" ]; }
mark_done()  { : > "${STATE}/${1}.done"; }
record() { # STEP DESC EXPECTED ACTUAL
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${STATE}/verdicts.tsv"
  if [ "$3" = "$4" ]; then _emit "RECORDED PASS: ${2}  [${4}]"
  else _emit "RECORDED FAIL: ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"; fi
}
note() { _emit "NOTE:     $*"; printf 'NOTE\t%s\n' "$*" >> "${STATE}/notes.txt"; }
budget_left() { [ $(( $(date +%s) - T0 )) -lt "$BUDGET" ]; }
yield() { _emit "BUDGET:   spent; ${1} step(s) remain. Call this path again to continue."; exit 75; }
reset_rows() {
  [ -f "${STATE}/verdicts.tsv" ] || return 0
  grep -v -- "^${1}"$'\t' "${STATE}/verdicts.tsv" > "${STATE}/verdicts.tmp" || true
  mv "${STATE}/verdicts.tmp" "${STATE}/verdicts.tsv"
}

# ------------------------------------------------------------- git, with the external forge's credential (GLUE)
# The user and token reach git through an askpass script that reads the credentials file when git asks, so neither
# is on a command line or in a URL.
ASKPASS="${STATE}/askpass.sh"
# shellcheck disable=SC2016  # the script's own $1 and the file name are for the askpass script, not this shell
printf '#!/bin/sh\ncase "$1" in Username*) sed -n 1p "%s" ;; *) sed -n 2p "%s" ;; esac\n' "${FROM_DIR}/git-credentials" "${FROM_DIR}/git-credentials" > "$ASKPASS"
chmod 700 "$ASKPASS"
xgit() {
  if [ -n "$FROM_CA" ]; then GIT_SSL_CAINFO="$FROM_CA" GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git -c credential.helper= "$@"
  else GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git -c credential.helper= "$@"; fi
}
from_main() { xgit ls-remote "$P16_FROM_URL" refs/heads/main 2>/dev/null | awk 'NR==1{print $1}'; }

# ------------------------------------------------------------- the built-in forge, as its admin (read only)
PF_PID=""
forge_down() { [ -z "$PF_PID" ] || kill "$PF_PID" 2>/dev/null; PF_PID=""; }
trap forge_down EXIT
FORGE_GIT="http://127.0.0.1:${FPORT}/tockmox/site.git"
fgit() { # git with the forge admin's Basic header in the environment, never in argv
  local u p
  u="$(kubectl --context="$KUBE_CONTEXT" -n "$FORGE_NS" get secret "$ADMIN_SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null)"
  p="$(kubectl --context="$KUBE_CONTEXT" -n "$FORGE_NS" get secret "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s:%s' "$u" "$p" | base64 | tr -d '\n')" GIT_TERMINAL_PROMPT=0 git "$@"
}
forge_up() {
  forge_down
  kubectl --context="$KUBE_CONTEXT" -n "$FORGE_NS" port-forward "svc/${FORGE_SVC}" "${FPORT}:3000" > "${STATE}/port-forward.log" 2>&1 &
  PF_PID=$!
  local tries=0
  while [ "$tries" -lt 20 ]; do
    fgit ls-remote "$FORGE_GIT" refs/heads/main >/dev/null 2>&1 && return 0
    kill -0 "$PF_PID" 2>/dev/null || return 1
    tries=$((tries + 1)); sleep 1
  done
  return 1
}

# ------------------------------------------------------------- Argo CD and the cluster, as they are now
apps_now() { kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" get applications.argoproj.io -o json > "$1" 2> "${1}.err"; }
has_forge() { kubectl --context="$KUBE_CONTEXT" get namespace "$FORGE_NS" >/dev/null 2>&1 && echo present || echo absent; }
has_copy() { kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" get secret "$CRED_COPY" -o name >/dev/null 2>&1 && echo present || echo absent; }
cred_names() { # which repository Argo CD's site credential names
  kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" get secret "$CRED_SECRET" -o json 2>/dev/null | verdict credential --url "$1" | head -1
}
# untouched FILE-PREFIX ... one line saying what a refused or dry run must have left exactly as it was
untouched() {
  apps_now "${STATE}/${1}.apps.json"
  printf 'forge %s; credential copy %s; root on %s at %s; credential %s; external main %s' \
    "$(has_forge)" "$(has_copy)" \
    "$(verdict root --root "$ROOT_APP" --from "$P16_FROM_URL" --in "$IN_URL" < "${STATE}/${1}.apps.json" | head -1)" \
    "$(verdict revision --root "$ROOT_APP" < "${STATE}/${1}.apps.json" | head -1 | cut -c1-12)" \
    "$(cred_names "$P16_FROM_URL")" "$(from_main | cut -c1-12)"
}
# settle WANT-ROOT LIMIT ... poll until the root reads WANT-ROOT, nothing reads OLD_URL and every Application is Synced
# and Healthy, or LIMIT seconds pass. Sets SLAST (the settled verdict), SROOT, SWAITED.
# A settle that times out also notes the root Application's own conditions (Argo CD's words for why, the external
# host scrubbed), so a run that never settles says what Argo CD saw.
settle() {
  local want="$1" limit="$2" t0 f="${STATE}/settle.apps.json" settled=0; t0=$(date +%s)
  while :; do
    apps_now "$f"
    SROOT="$(verdict root --root "$ROOT_APP" --from "$P16_FROM_URL" --in "$IN_URL" < "$f" | head -1)"
    SLAST="$(verdict settled < "$f" | head -1)"
    SOLD="$(verdict reads --url "$OLD_URL" < "$f" | head -1)"
    SWAITED=$(( $(date +%s) - t0 ))
    if [ "$SROOT" = "$want" ] && [ "$SOLD" = "0 read it" ]; then case "$SLAST" in *" Synced and Healthy") settled=1; break ;; esac; fi
    [ "$SWAITED" -ge "$limit" ] && break
    sleep "$POLL"
  done
  note "settle: waited ${SWAITED}s (limit ${limit}s): root reads ${SROOT}; the old repository: ${SOLD}; ${SLAST}"
  [ "$settled" = 1 ] || note "settle: not settled within ${limit}s; the root Application's conditions: $(verdict conditions --root "$ROOT_APP" < "$f" | head -1 | scrub)"
}

# ------------------------------------------------------------- the page's block
pblock() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$PAGE_FILE" --section "$SECTION" --lang bash --containing "$NEEDLE" 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing "$NEEDLE" 2>/dev/null; fi
}
# filled BLOCKFILE ... the three placeholders filled; the repository's address as a variable this path exports
filled() {
  # shellcheck disable=SC2016  # "$P16_FROM_URL" is written into the block for the pasted shell to expand, not this one
  sed -e "s|YOUR_SITE_CHECKOUT|${SITE_DIR}|g" -e 's|YOUR_SITE_REPOSITORY_HTTPS_URL|"$P16_FROM_URL"|g' \
      -e "s|YOUR_AGE_PUBLIC_KEY|${AGE_PUBLIC_KEY:-NO_AGE_KEY}|g" "$1" | with_ca
}
# with_ca ... stdin: the block; stdout: the same, with --from-ca FILE after its --from-credentials argument when the
# forge is on a private CA (the page's YOU SUPPLY says to add it), and unchanged otherwise
with_ca() {
  if [ -z "$FROM_CA" ]; then cat; return; fi
  FROM_CA="$FROM_CA" python3 -I -c 'import os, re, sys
t = sys.stdin.read()
n = len(re.findall(r"--from-credentials \S+", t))
assert n == 1, "not one --from-credentials"
sys.stdout.write(re.sub(r"(--from-credentials \S+)", lambda m: m.group(1) + " --from-ca \"" + os.environ["FROM_CA"] + "\"", t, count=1))'
}
# undry ... stdin: the block; stdout: the same with its one --dry-run taken out, as the page says to run it again
undry() { python3 -I -c 'import sys; t=sys.stdin.read(); assert t.count(" --dry-run")==1, "not one --dry-run"; sys.stdout.write(t.replace(" --dry-run","",1))'; }
# run_ws NAME TEXT [ANSWERS] ... the block pasted into the workstation shell the page is written for (zsh), with a HOME
# of the path's own; ANSWERS are typed at the prompts they name. Output, scrubbed of the external host, in NAME.out.
run_ws() {
  local name="$1" text="$2" answers="${3:-}" rc bf
  bf="${STATE}/${name}.block"; printf '%s\n' "$text" > "$bf"
  _emit "--- verbatim from the page (${name}), placeholders filled -------------"
  printf '%s\n' "$text" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
  _emit "--- pasted into an interactive ${WS_SHELL} -------------------------------"
  mkdir -p "${STATE}/zdotdir"; : > "${STATE}/zdotdir/.zshrc"
  if [ "$WS_SHELL" = bash ]; then
    HOME="$P16_HOME" bash "$bf" > "${STATE}/${name}.raw" 2>&1 < /dev/null; rc=$?
  else
    HOME="$P16_HOME" ZSH="$(command -v "$WS_SHELL")" ZSH_PASTE_ZDOTDIR="${STATE}/zdotdir" ZSH_PASTE_TIMEOUT="${ZSH_PASTE_TIMEOUT:-600}" \
      python3 "$PASTE" "$bf" ${answers:+"$answers"} > "${STATE}/${name}.raw" 2>&1; rc=$?
  fi
  scrub < "${STATE}/${name}.raw" > "${STATE}/${name}.out"; rm -f "${STATE}/${name}.raw"
  printf '%s' "$rc" > "${STATE}/${name}.rc"
  sed 's/^/    | /' "${STATE}/${name}.out" | while IFS= read -r l; do _emit "$l"; done
  _emit "    (exit ${rc}; the exit code is evidence, not the assertion)"
  return "$rc"
}
out_of() { cat "${STATE}/${1}.out" 2>/dev/null; }

finish_path() {
  forge_down
  [ "$EXEC_PHASE_COMPLETED" -eq 1 ] && printf '%s' "$EXEC_LAST_RC" > "${STATE}/last-execute-rc"
  if [ "$EXEC_PHASE_STARTED" -eq 0 ] && [ -f "${STATE}/last-execute-rc" ]; then
    execute_begin "replayed from state: the steps ran in an earlier invocation of this path (see the STEP logs above in the same report)"
    execute_end "$(cat "${STATE}/last-execute-rc")"
  fi
  _emit ""; _emit "=== REPLAY of every recorded verdict through lib/assert.sh ==========="
  local st desc exp act _replay_val
  # shellcheck disable=SC2016  # the read is a command string assert.sh evaluates later; $_replay_val must stay unexpanded here
  while IFS=$'\t' read -r st desc exp act; do
    _replay_val="$act"
    assert_artifact "[${st}] ${desc}" 'printf %s "$_replay_val"' "$exp"
  done < "${STATE}/verdicts.tsv"
  _emit ""; _emit "NOTES (from the run):"; sed 's/^NOTE\t/  - /' "${STATE}/notes.txt" 2>/dev/null | while IFS= read -r l; do _emit "$l"; done

  does_not_prove \
    "A site that arrived on its forge by its own history: S01 puts P09's site on the external forge with one commit and an applied root, which is what a reader on their own forge already has, not how they got it." \
    "That a reader's Argo CD already trusts a forge on a private CA, as the page says it does: on such a forge S01 gives the guest's Argo CD the CA (argocd-tls-certs-cm) as GLUE, because P09's site was never on that forge." \
    "That a pull request on the old repository, or its CI, does anything after the move: the page says the forge runs no CI and the mirror pushes after the fact; nothing reads the old repository's workflows." \
    "That the push mirror refuses a force-push the page tells the reader to block: branch rules on the external forge are the reader's and are not set here." \
    "The cutover's failure branch (the printed command that points Argo CD back): the installer's tests run it against stand-ins; here the move settles or the path fails." \
    "That the install itself works: that is P09's."

  parity_caveat \
    "kubectl, git and the page's block ran from a Linux runner against a single-node KubeVirt guest, the one P09 installed on the external route. The block was pasted into ${WS_SHELL} on a pty, with a HOME of the path's own, not the workstation shell the page is written for."

  path_finish
}

record_success_conditions "$PAGE_FILE" "${PAGE} @ $( [ "$FROM_TREE" = "1" ] && echo WORKTREE || echo "$REF" )"

# ============================================================== THE STEPS

# S01 ... GLUE: the running site on an external https forge, a clean checkout of it, and the reader's key material.
S=S01-stage
if ! done_step "$S"; then budget_left || yield "S01+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "GLUE: the page starts from a site whose repository is on a forge of its own, at an https address; P09's external route serves it at git:// (a daemon on the throwaway), so the site moves to an external https forge first: one commit that names it in every repoURL, the whole history pushed there, Argo CD's credential for it (install.md 2c's Secret), its CA when it is on a private one, and the root applied"
  rm -rf "${STATE}/stage"
  git clone -q --no-local "$SITE_REPO" "${STATE}/stage" 2>"${STATE}/stage.err"
  v="$(verdict rewrite --old "$OLD_URL" --new "$P16_FROM_URL" "${STATE}/stage" 2>&1 | scrub)"
  note "${S}: ${v}"
  git -C "${STATE}/stage" -c user.name="executed-docs P16" -c user.email=p16@example.invalid -c commit.gpgsign=false \
    commit -q -am "The site repository is on its own forge (executed-docs P16 setup)" >/dev/null 2>&1
  STAGED="$(git -C "${STATE}/stage" rev-parse HEAD 2>/dev/null)"
  printf '%s' "$STAGED" > "${STATE}/staged-head"
  xgit -C "${STATE}/stage" push -q --force "$P16_FROM_URL" HEAD:refs/heads/main > "${STATE}/stage-push.out" 2>&1
  record "$S" "GLUE: the external repository's main is the staged head, with P09's whole history under it" "$STAGED" "$(from_main)"
  verdict argo-secret --name "$CRED_SECRET" --url "$P16_FROM_URL" --credentials "${FROM_DIR}/git-credentials" \
    | kubectl --context="$KUBE_CONTEXT" apply -f - > "${STATE}/cred-apply.out" 2>&1
  record "$S" "GLUE: Argo CD's site credential (${ARGO_NS}/${CRED_SECRET}) names the external repository" "names the URL's repository" "$(cred_names "$P16_FROM_URL")"
  if [ -n "$FROM_CA" ]; then
    # the CA under the forge's host name in argocd-tls-certs-cm, a merge patch that names no other key, before the root
    # is applied, so the first read of the external repository can verify it
    verdict argo-ca --url "$P16_FROM_URL" --ca "$FROM_CA" > "${STATE}/argo-ca-patch.json" 2> "${STATE}/argo-ca.err"
    kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" patch configmap "$TLS_CM" --type merge --patch-file "${STATE}/argo-ca-patch.json" > "${STATE}/argo-ca.out" 2>&1
    v="$(kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" get configmap "$TLS_CM" -o json 2>/dev/null | verdict ca-trusted --url "$P16_FROM_URL" --ca "$FROM_CA" | head -1)"
    record "$S" "GLUE: Argo CD trusts the external forge's private CA (${ARGO_NS}/${TLS_CM} holds ca.crt under its host name)" "holds the CA under the URL's host" "$v"
    if [ "$v" = "holds the CA under the URL's host" ]; then
      note "${S}: the external forge is on a private CA, so its ca.crt was given to Argo CD: ${ARGO_NS}/${TLS_CM}, under the forge's host name, merged (no other entry changed, no insecure flag)"
    else
      note "${S}: the external forge is on a private CA, and its ca.crt could not be given to Argo CD (${v}): $(cat "${STATE}/argo-ca.err" "${STATE}/argo-ca.out" 2>/dev/null | tail -c 300 | tr '\n' ' ' | scrub)"
    fi
  fi
  kubectl --context="$KUBE_CONTEXT" apply -f "${STATE}/stage/bootstrap/root.yaml" > "${STATE}/root-apply.out" 2>&1
  settle "the external repository" "$SETTLE"
  record "$S" "GLUE: Argo CD's root reads the external repository, and no Application reads the git daemon any more" "the external repository; 0 read it" "${SROOT}; ${SOLD}"
  case "$SLAST" in *" Synced and Healthy") v=settled ;; *) v="$SLAST" ;; esac
  record "$S" "GLUE: every Application is Synced and Healthy on the external repository" "settled" "$v"
  record "$S" "GLUE: the root is synced to the staged head" "$STAGED" "$(verdict revision --root "$ROOT_APP" < "${STATE}/settle.apps.json" | head -1)"
  rm -rf "$SITE_DIR"
  xgit clone -q "$P16_FROM_URL" "$SITE_DIR" > "${STATE}/clone.out" 2>&1
  record "$S" "GLUE: the checkout is a clean clone of the external repository, on main, at the staged head" "main ${STAGED} clean" \
    "$(git -C "$SITE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) $(git -C "$SITE_DIR" rev-parse HEAD 2>/dev/null) $([ -z "$(git -C "$SITE_DIR" status --porcelain 2>/dev/null)" ] && echo clean || echo dirty)"
  _emit "GLUE: the reader's files under the path's own HOME: the push credential the page names (two lines), an age identity, and the sealing-key export bootstrap-forge takes, written by bootstrap-secrets --mode reuse against a scratch copy of the site (confirmed with its --yes flags)"
  mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
  ( umask 077; sed -n '1,2p' "${FROM_DIR}/git-credentials" > "${BACKUP}/site-repo-push" )
  [ -s "$AGE_ID" ] || age-keygen -o "$AGE_ID" >/dev/null 2>&1
  SERVER_V="$(kubectl --context="$KUBE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  CTRL_V="$(kubectl --context="$KUBE_CONTEXT" get deploy -A -l app.kubernetes.io/name=sealed-secrets -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}' 2>/dev/null)"
  rm -rf "${STATE}/reuse-site"; git clone -q --no-local "$SITE_DIR" "${STATE}/reuse-site" 2>/dev/null
  rm -f "${BACKUP}/sealed-secrets.key.enc"
  HOME="$P16_HOME" bash "${TOCKMOX}/install/tockmox-install.sh" bootstrap-secrets --mode reuse --site "${STATE}/reuse-site" \
    --context "$KUBE_CONTEXT" --yes-context "$KUBE_CONTEXT" --yes-server "$SERVER_V" --yes-adopt "$CTRL_V" --no-prompt \
    --backup-out "${BACKUP}/sealed-secrets.key.enc" --age-recipient "$(age-keygen -y "$AGE_ID")" > "${STATE}/key-export.out" 2>&1
  record "$S" "GLUE: the sealing-key export is bootstrap-secrets' age-encrypted file, where the page's block names it" "age" \
    "$(head -c 21 "${BACKUP}/sealed-secrets.key.enc" 2>/dev/null | grep '^age-encryption.org/v1' >/dev/null && echo age || echo "not an age file")"
  mark_done "$S"
fi
AGE_PUBLIC_KEY="$(age-keygen -y "$AGE_ID" 2>/dev/null || true)"
STAGED="$(cat "${STATE}/staged-head" 2>/dev/null || true)"

# S02 ... before the move: the page's block, and Argo CD as the move finds it (kept for S06).
S=S02-before
if ! done_step "$S"; then budget_left || yield "S02+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  pblock > "${STATE}/block.sh"
  record "$S" "the page's block resolves to one block, with each placeholder P16 fills once and one --dry-run" "1 1 1 1" \
    "$(for p in YOUR_SITE_CHECKOUT YOUR_SITE_REPOSITORY_HTTPS_URL YOUR_AGE_PUBLIC_KEY ' --dry-run'; do grep -o -- "$p" "${STATE}/block.sh" 2>/dev/null | wc -l | tr -d ' '; done | tr '\n' ' ' | sed 's/ $//')"
  apps_now "${STATE}/apps-before.json"
  record "$S" "Argo CD's root reads the external repository" "the external repository" "$(verdict root --root "$ROOT_APP" --from "$P16_FROM_URL" --in "$IN_URL" < "${STATE}/apps-before.json" | head -1)"
  record "$S" "Argo CD's root is synced to the checkout's revision, which the page asks for" "$(git -C "$SITE_DIR" rev-parse HEAD 2>/dev/null)" "$(verdict revision --root "$ROOT_APP" < "${STATE}/apps-before.json" | head -1)"
  v="$(verdict reads --url "$P16_FROM_URL" < "${STATE}/apps-before.json" | head -1)"
  record "$S" "more than the root reads the external repository, so the move has Applications to cut over" "more than one" "$(case "$v" in 0\ *|1\ *|unreadable*) echo "$v" ;; *) echo "more than one" ;; esac)"
  case "$(verdict settled < "${STATE}/apps-before.json" | head -1)" in *" Synced and Healthy") v=settled ;; *) v="$(verdict settled < "${STATE}/apps-before.json" | head -1)" ;; esac
  record "$S" "every Application is Synced and Healthy before the move, so the check after it can tell what the move did" "settled" "$v"
  record "$S" "there is no built-in forge yet" "absent" "$(has_forge)"
  git -C "$SITE_DIR" rev-list --count HEAD > "${STATE}/pre-count" 2>/dev/null
  git -C "$SITE_DIR" rev-parse HEAD > "${STATE}/pre-head" 2>/dev/null
  untouched before > "${STATE}/untouched-before"
  note "${S}: before the move: $(cat "${STATE}/untouched-before")"
  mark_done "$S"
fi
PRE="$(cat "${STATE}/pre-head" 2>/dev/null || true)"
PRE_COUNT="$(cat "${STATE}/pre-count" 2>/dev/null || true)"
BEFORE_LINE="$(cat "${STATE}/untouched-before" 2>/dev/null || true)"
printf 'Type the context name to go on: \t%s\n' "$KUBE_CONTEXT" > "${STATE}/answers"

# S03 ... a dirty checkout: refused before anything is written, and before it asks for the context.
S=S03-refused
if ! done_step "$S"; then budget_left || yield "S03+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  _emit "GLUE: an untracked file in the checkout (p16-uncommitted.txt), then the block with --dry-run removed: the page says it refuses 'uncommitted or untracked changes in the checkout' before it writes anything"
  printf 'planted by executed-docs P16\n' > "${SITE_DIR}/p16-uncommitted.txt"
  B="$(filled "${STATE}/block.sh" | undry)"
  run_ws "$S" "$B" "${STATE}/answers"; rc=$?
  record "$S" "row 5: the move refuses a dirty checkout (a nonzero exit)" "refused" "$([ "$rc" -ne 0 ] && echo refused || echo "exit ${rc}")"
  record "$S" "row 5: it names the untracked file and says nothing was touched" "1 1" \
    "$(out_of "$S" | grep -c 'has uncommitted or untracked changes' | tr -d ' ') $(out_of "$S" | grep -c 'Nothing was touched' | tr -d ' ')"
  record "$S" "row 5: it refused before it asked for the context" "0" "$(out_of "$S" | grep -c 'Type the context name' | tr -d ' ')"
  record "$S" "row 5: nothing was written: no forge, no credential copy, the root, its credential and the external repository as they were" "$BEFORE_LINE" "$(untouched "$S")"
  rm -f "${SITE_DIR}/p16-uncommitted.txt"
  record "$S" "GLUE: the untracked file is gone again and the checkout is clean" "clean" "$([ -z "$(git -C "$SITE_DIR" status --porcelain 2>/dev/null)" ] && echo clean || echo dirty)"
  mark_done "$S"
fi

# S04 ... the block as printed: the dry run.
S=S04-dry-run
if ! done_step "$S"; then budget_left || yield "S04+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ -s "${STATE}/block.sh" ]; then
    provenance "$( [ "$FROM_TREE" = "1" ] && echo WORKTREE || echo "$REF" )" "$PAGE" "${SECTION}, the bash block containing '${NEEDLE}'" "-" \
      "$(sha256sum < "${STATE}/block.sh" | cut -d' ' -f1)"
    _emit "SUBSTITUTION: YOUR_SITE_CHECKOUT -> ${SITE_DIR}; YOUR_SITE_REPOSITORY_HTTPS_URL -> \"\$P16_FROM_URL\" (exported, not printed); YOUR_AGE_PUBLIC_KEY -> the path's age identity's public key  (YOU SUPPLY on the page)"
    [ -z "$FROM_CA" ] || _emit "EDIT AS THE PAGE SAYS: 'if a private CA signed that forge's certificate, the CA as a PEM file, given as --from-ca FILE': --from-ca and the forge's ca.crt are added after --from-credentials"
    execute_begin "site-forge.md: move-in-forge --dry-run"
    run_ws "$S" "$(filled "${STATE}/block.sh")" "${STATE}/answers"; execute_end $?
    record "$S" "the dry run ends as the page says: it changes nothing" "1" "$(out_of "$S" | grep -c 'Dry run: nothing was changed' | tr -d ' ')"
    record "$S" "the dry run shows the migration commit's files, the root among them" "shown" "$(out_of "$S" | grep 'bootstrap/root.yaml' >/dev/null && echo shown || echo "not shown")"
    record "$S" "the dry run wrote nothing" "$BEFORE_LINE" "$(untouched "$S")"
  else
    record "$S" "the page's block resolves" "one block" "missing or ambiguous"
  fi
  mark_done "$S"
fi

# S05 ... the move: the block with --dry-run removed, the context typed at the prompt.
S=S05-move
if ! done_step "$S"; then budget_left || yield "S05+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ -s "${STATE}/block.sh" ]; then
    _emit "EDIT AS THE PAGE SAYS: 'Run it again without --dry-run to move; it asks you to type the context name.' --dry-run is taken out, and the context name is typed at the prompt"
    execute_begin "site-forge.md: move-in-forge"
    ZSH_PASTE_TIMEOUT="$MOVE_TIMEOUT" run_ws "$S" "$(filled "${STATE}/block.sh" | undry)" "${STATE}/answers"; rc=$?; execute_end "$rc"
    record "$S" "the move exits 0" "0" "$rc"
    record "$S" "the page's success condition: it ends with '${SUCCESS_LINE}'" "1" "$(out_of "$S" | grep -c -F "$SUCCESS_LINE" | tr -d ' ')"
  else
    record "$S" "the page's block resolves" "one block" "missing or ambiguous"
  fi
  mark_done "$S"
fi

# S06 ... read back what the move left, against S02's Applications.
S=S06-after
reset_rows "$S"
_emit ""; _emit "=== STEP ${S} =============================================="
apps_now "${STATE}/apps-after.json"
record "$S" "row 1: every Application that read the external repository reads the built-in forge" \
  "every Application that read the external repository reads the built-in forge ($(verdict reads --url "$P16_FROM_URL" < "${STATE}/apps-before.json" | head -1 | cut -d' ' -f1))" \
  "$(verdict moved --before "${STATE}/apps-before.json" --from "$P16_FROM_URL" --in "$IN_URL" < "${STATE}/apps-after.json" | head -1)"
record "$S" "row 1: Argo CD's root reads the built-in forge" "the built-in forge" "$(verdict root --root "$ROOT_APP" --from "$P16_FROM_URL" --in "$IN_URL" < "${STATE}/apps-after.json" | head -1)"
case "$(verdict settled < "${STATE}/apps-after.json" | head -1)" in *" Synced and Healthy") v=settled ;; *) v="$(verdict settled < "${STATE}/apps-after.json" | head -1)" ;; esac
record "$S" "row 1: every Application is Synced and Healthy after the move" "settled" "$v"
v="$(verdict pruned --before "${STATE}/apps-before.json" < "${STATE}/apps-after.json" | head -1)"
note "${S}: ${v}"
record "$S" "row 2: nothing any Application managed before the move was pruned" "nothing pruned" "$(case "$v" in "nothing pruned ("*) echo "nothing pruned" ;; *) echo "$v" ;; esac)"
V="${STATE}/verify"; rm -rf "$V"; git clone -q --no-local "$SITE_DIR" "$V" 2>/dev/null
FM=""
if forge_up && fgit -C "$V" fetch -q "$FORGE_GIT" "+refs/heads/main:refs/remotes/forge/main" 2>"${STATE}/forge-fetch.err"; then
  FM="$(git -C "$V" rev-parse refs/remotes/forge/main 2>/dev/null)"
else
  note "${S}: the forge's main could not be read through a port-forward: $(tail -c 200 "${STATE}/port-forward.log" "${STATE}/forge-fetch.err" 2>/dev/null | tr '\n' ' ')"
fi
forge_down
record "$S" "row 3: the forge's main is ONE commit on top of the pre-move head, the installer's migration commit" \
  "1 commit, parent ${PRE}, by ${MIG_AUTHOR}" \
  "$( [ -n "$FM" ] && printf '%s commit, parent %s, by %s' "$(git -C "$V" rev-list --count "${PRE}..${FM}" 2>/dev/null)" "$(git -C "$V" rev-parse "${FM}^" 2>/dev/null)" "$(git -C "$V" log -1 --format=%an "$FM" 2>/dev/null)" || echo "the forge's main unreadable")"
record "$S" "row 3: the forge holds the whole pre-move history under it" "$((PRE_COUNT + 1))" "$( [ -n "$FM" ] && git -C "$V" rev-list --count "$FM" 2>/dev/null || echo unreadable)"
record "$S" "row 1: the root is synced to the forge's main" "${FM:-the forge main could not be read}" "$(verdict revision --root "$ROOT_APP" < "${STATE}/apps-after.json" | head -1)"
xgit -C "$V" fetch -q "$P16_FROM_URL" "+refs/heads/main:refs/remotes/external/main" 2>/dev/null
XM="$(git -C "$V" rev-parse -q --verify refs/remotes/external/main 2>/dev/null || true)"
record "$S" "row 4: the external repository is the off-site copy: its main is the forge's main" "${FM:-the forge main could not be read}" "${XM:-unreadable}"
record "$S" "row 4: the external repository still holds the pre-move history: the pre-move head is under its main, and nothing else was added" \
  "under it, $((PRE_COUNT + 1)) commits" \
  "$( [ -n "$XM" ] && git -C "$V" merge-base --is-ancestor "$PRE" "$XM" 2>/dev/null && echo under it || echo "not under it"), $( [ -n "$XM" ] && git -C "$V" rev-list --count "$XM" 2>/dev/null || echo 0) commits"
record "$S" "the copy of Argo CD's old credential is removed once the move is checked (the page: 'Then the credential copy is removed')" "absent" "$(has_copy)"
record "$S" "the checkout was never changed (the page: 'The command works on a copy and never changes it')" "${PRE} clean" \
  "$(git -C "$SITE_DIR" rev-parse HEAD 2>/dev/null) $([ -z "$(git -C "$SITE_DIR" status --porcelain 2>/dev/null)" ] && echo clean || echo dirty)"
if [ -s "${STATE}/block.sh" ]; then
  _emit "the page: 'Run it again: it says Nothing to do'. The block with --dry-run removed, once more"
  execute_begin "site-forge.md: move-in-forge, run again"
  run_ws "${S}-again" "$(filled "${STATE}/block.sh" | undry)" "${STATE}/answers"; rc=$?; execute_end "$rc"
  record "$S" "the page's second success condition: run again, it says Nothing to do (and exits 0)" "1 0" "$(out_of "${S}-again" | grep -c 'Nothing to do' | tr -d ' ') ${rc}"
fi

finish_path
exit $?

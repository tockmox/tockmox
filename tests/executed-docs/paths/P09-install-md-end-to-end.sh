#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P09 ... `docs/deployment/install.md`, end to end, every WORKSTATION
# block from "Set these once" through "Verify what Tockmox authored", run
# BYTE FOR BYTE out of the page, in order, in ONE session, against a cluster
# that fresh-install.md sections 6 and 7 left behind. INVENTORY row C1 said
# this page (the one the product's own release gate walks by hand) had
# "37 blocks, OPEN" for two weeks while everything around it was covered.
#
# WHAT IS DIFFERENT ABOUT THIS PATH, and both are the reason it exists:
#
#   1. THE SHELL IS zsh, PASTED. Every WORKSTATION block is fed to an
#      interactive zsh on a pseudo-terminal as a bracketed paste followed by
#      Enter (lib/zsh-paste.py), because that is what the page's supported
#      workstation does, and TM-0484/TM-0537 were both defects that bash
#      cannot reproduce: `#` is not a comment in an interactive zsh, `read -p`
#      means "coprocess", an unquoted $VAR does not word-split. A block that
#      passes here passed the shell macOS ships, not a shell that resembles it.
#      Set TOCKMOX_WS_SHELL=bash to fall back (recorded in the log as a
#      weaker run). `read -rs` prompts are answered through the pty, the way a
#      person types them, never through stdin.
#
#   2. IT IS A SESSION. The page's own model is one terminal, exports carried
#      forward (TM-0484). Exports made by a block are captured after it returns
#      and re-exported here, so the next block's `${SITE_REPO:?}` guard sees
#      what the previous block set, exactly as the reader's terminal does.
#
# WHAT IT NEEDS THAT THE PAGE DOES NOT NAME, all stated as GLUE in the log:
#   - a git remote the workstation can PUSH to and the cluster can CLONE from,
#     at ONE URL (the page uses SITE_REPO_URL at three call sites and warns that
#     three spellings are three chances to differ; a harness that gave the
#     cluster a different URL would be testing something the reader never
#     does). provision/site-repo-server.sh `up --writable` serves it from inside
#     the cluster under test with receive-pack enabled on a NodePort; on a
#     KubeVirt substrate throwaway-cluster.sh `publish` makes that port reachable
#     from outside, and the guest reaches its own published address by hairpin
#     (measured 2026-09-14). TOCKMOX_P09_SITE_REPO_URL carries the result.
#   - the PRODUCT repository the Applications' source 1 points at. GitHub's copy
#     is private until the public release (the page says so), so the same daemon
#     serves a snapshot of the working tree under the tag the operator would
#     pin. TOCKMOX_P09_TOCKMOX_REPO_URL and TOCKMOX_P09_TOCKMOX_REVISION.
#     **A run built on that proves nothing about the published tag**, and the
#     log says so every time.
#   - the four YOU SUPPLY values for tockmox.yaml. The page hands the reader
#     `$EDITOR tockmox.yaml`; here $EDITOR is a script that writes the four
#     values (and the repo override above) into the copy the block just made.
#     The block is unchanged; the editor is the glue.
#   - a git identity (user.name/email) for the site repository's first commit,
#     which a reader's workstation already has.
#   - kubeseal on PATH at the controller's version (the page's own tool table
#     says to check; block 3 checks).
#
# RESUMABLE. The whole page takes 20-40 minutes, most of it waiting for sync
# waves, and some runners cap a single invocation well under that. Every step
# records its verdicts under $TOCKMOX_P09_STATE and is skipped on re-run; the
# path exits 75 ("call me again") when its wall-clock budget
# (TOCKMOX_P09_BUDGET, default 150s) is spent with steps remaining. The final
# invocation replays every recorded assertion through lib/assert.sh so the
# summary counts what the run measured, and only then declares an outcome.
#
# CONDITIONAL STEPS the page gates on a read are gated on the SAME read here:
# 1d (node count), 2c (private repo), un-default StorageClass (two defaults),
# the model-gateway key (a Service exists). Each gate's reading is logged.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../lib/assert.sh"
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"
# TOCKMOX_P09_FROM_TREE=1 reads the page from the WORKING TREE instead of the
# ref, for proving a fix before it is committed (extract-block's --file). The
# provenance line then says WORKTREE so nobody reads it as evidence about a tag.
FROM_TREE="${TOCKMOX_P09_FROM_TREE:-0}"
PAGE="${TOCKMOX_P09_PAGE:-docs/deployment/install.md}"
# The H1: a section spans everything to the next heading of the same level,
# so naming the page title selects blocks from the whole page by content.
SECTION="${TOCKMOX_P09_SECTION:-# Install Tockmox}"
EXTRACT="${HERE}/../lib/extract-block.sh"
PASTE="${HERE}/../lib/zsh-paste.py"
STATE="${TOCKMOX_P09_STATE:-${TMPDIR:-/tmp}/tockmox-p09-state}"
BUDGET="${TOCKMOX_P09_BUDGET:-150}"
WS_SHELL="${TOCKMOX_WS_SHELL:-zsh}"
T0=$(date +%s)
mkdir -p "$STATE"

path_begin "P09-install-md-end-to-end" \
  "docs/deployment/install.md, every WORKSTATION block pasted into an interactive zsh in one session, from Set these once to Verify what Tockmox authored"

# --- inputs the page calls YOU SUPPLY, or that this harness supplies as glue ---
# Missing inputs are a declared environmental constraint (BLOCKED), not a
# failure and not silence: the nightly runner does not yet stand up the
# writable remote this path needs, and a run must say so rather than count
# this path as green or as broken.
missing=""
for v in TOCKMOX_P09_SITE_REPO_URL TOCKMOX_P09_TOCKMOX_REPO_URL TOCKMOX_P09_TOCKMOX_REVISION \
         TOCKMOX_P09_TOCKMOX_CLONE TOCKMOX_P09_LAN_CIDR TOCKMOX_P09_POOL; do
  eval "[ -n \"\${${v}:-}\" ]" || missing="${missing}${missing:+ }${v}"
done
if [ -n "$missing" ]; then
  _emit "BLOCKED:  this path needs a git remote the workstation can push to and the cluster can"
  _emit "          clone at ONE URL, plus the product tree served beside it (see the header)."
  _emit "          Unset: ${missing}"
  path_outcome BLOCKED "no writable site remote configured for this run (${missing})"
  exit 0
fi
SITE_URL="$TOCKMOX_P09_SITE_REPO_URL"
TM_URL="$TOCKMOX_P09_TOCKMOX_REPO_URL"
TM_REV="$TOCKMOX_P09_TOCKMOX_REVISION"
TM_CLONE="$TOCKMOX_P09_TOCKMOX_CLONE"
INTERNAL_DOMAIN_V="${TOCKMOX_P09_INTERNAL_DOMAIN:-p09.internal}"
LAN_CIDR_V="$TOCKMOX_P09_LAN_CIDR"
POOL_V="$TOCKMOX_P09_POOL"
SITE_NAME_V="${TOCKMOX_P09_SITE_NAME:-p09}"

if [ "$WS_SHELL" = "zsh" ] && ! command -v "${ZSH:-zsh}" >/dev/null 2>&1; then
  _emit "INFRA: no zsh on this runner and TOCKMOX_WS_SHELL=zsh. Install zsh, or set"
  _emit "       TOCKMOX_WS_SHELL=bash to run a weaker version of this path."
  path_outcome INFRA_ERROR "no zsh on the runner"; exit 1
fi
for t in kubectl helm kubeseal openssl git python3; do
  command -v "$t" >/dev/null 2>&1 || { _emit "INFRA: '$t' is not on PATH"; path_outcome INFRA_ERROR "missing $t"; exit 1; }
done

# ------------------------------------------------------------- state helpers
done_step() { [ -f "${STATE}/${1}.done" ]; }
mark_done()  { : > "${STATE}/${1}.done"; }
# record STEP DESC EXPECTED ACTUAL [xfail] ... one line per verdict, replayed at the end
record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "${STATE}/verdicts.tsv"
  if [ "${5:-}" = "xfail" ]; then
    _emit "RECORDED (xfail): ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"
  elif [ "$3" = "$4" ]; then _emit "RECORDED PASS: ${2}  [${4}]"
  else _emit "RECORDED FAIL: ${2}"; _emit "  expected: ${3}"; _emit "  actual:   ${4}"; fi
}
note() { _emit "NOTE:     $*"; printf 'NOTE\t%s\n' "$*" >> "${STATE}/notes.txt"; }
budget_left() { [ $(( $(date +%s) - T0 )) -lt "$BUDGET" ]; }
yield() { _emit "BUDGET:   spent; ${1} step(s) remain. Call this path again to continue."; exit 75; }

# ------------------------------------------------------ session environment
# Exports a block makes are captured (export -p) and re-applied here so the
# next block sees them, mirroring the reader's single terminal. They are also
# persisted so a re-run after a budget yield rejoins the same session.
ENVFILE="${STATE}/session.env"
load_session() { [ -f "$ENVFILE" ] && apply_exports "$ENVFILE"; return 0; }
apply_exports() {
  while IFS= read -r line; do
    case "$line" in "export "*|"declare -x "*) : ;; *) continue ;; esac
    nv="${line#export }"; nv="${nv#declare -x }"; name="${nv%%=*}"
    case "$name" in
      PATH|PWD|OLDPWD|HOME|SHLVL|IFS|_|PS1|TERM|ZDOTDIR|BASH*|ZSH*|KUBECONFIG|ASSERT_REPORT|TOCKMOX_*|OUTCOME_RECEIPT_DIR|ABSENCE_RECEIPT_DIR|MODULE_PATH) continue ;;
      *[!A-Za-z0-9_]*|"") continue ;;
    esac
    [ "$nv" = "$name" ] && continue
    eval "export ${nv}"
  done < "$1"
}
load_session

# block NEEDLE ... extract the block of $PAGE at $REF containing NEEDLE, verbatim
block() {
  local n="$1" out
  if [ "$FROM_TREE" = "1" ]; then
    out="$("$EXTRACT" --file "$PAGE" --section "$SECTION" --lang bash --containing "$n" 2>/dev/null)" || return 1
  else
    out="$("$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing "$n" 2>/dev/null)" || return 1
  fi
  printf '%s' "$out"
}
block_sha() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$PAGE" --section "$SECTION" --lang bash --containing "$1" --sha 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$PAGE" --section "$SECTION" --lang bash --containing "$1" --sha 2>/dev/null; fi
}

# run_ws NAME BLOCKTEXT [ANSWERFILE] ... paste one WORKSTATION block into the
# session shell. Transcript to $STATE/NAME.out, exit status to $STATE/NAME.rc.
# Exports carried. ZSH_PASTE_INTERRUPT may be set by the caller for a watch.
run_ws() {
  local name="$1" text="$2" answers="${3:-}" rc bf envout
  bf="${STATE}/${name}.block"; printf '%s\n' "$text" > "$bf"
  envout="${STATE}/${name}.env"; rm -f "$envout"
  _emit "--- verbatim from the page (${name}) -----------------------------"
  printf '%s\n' "$text" | sed 's/^/    /' | while IFS= read -r l; do _emit "$l"; done
  _emit "--- pasted into an interactive ${WS_SHELL} ------------------------------"
  if [ "$WS_SHELL" = "zsh" ]; then
    ZSH_PASTE_ENVOUT="$envout" ZSH_PASTE_TIMEOUT="${ZSH_PASTE_TIMEOUT:-600}" \
      python3 "$PASTE" "$bf" ${answers:+"$answers"} > "${STATE}/${name}.out" 2>&1; rc=$?
  else
    ( bash -c "$(cat "$bf")"$'\n''__rc=$?; export -p > "'"$envout"$'"; exit $__rc' ) > "${STATE}/${name}.out" 2>&1 </dev/null; rc=$?
  fi
  printf '%s' "$rc" > "${STATE}/${name}.rc"
  sed 's/^/    | /' "${STATE}/${name}.out" | while IFS= read -r l; do _emit "$l"; done
  _emit "    (exit ${rc}; the exit code is evidence, not the assertion)"
  if [ -f "$envout" ]; then
    apply_exports "$envout"
    # persist the session: merge into session.env (last write wins per name)
    { [ -f "$ENVFILE" ] && cat "$ENVFILE"; cat "$envout"; } | awk -F= '/^(export|declare -x) /{k=$1; line[k]=$0; if(!(k in seen)){seen[k]=1; order[++n]=k}} END{for(i=1;i<=n;i++) print line[order[i]]}' > "${ENVFILE}.tmp" && mv "${ENVFILE}.tmp" "$ENVFILE"
  fi
  return "$rc"
}
out_of() { cat "${STATE}/${1}.out" 2>/dev/null; }

# block_in SECTION N ... ordinal extraction inside a named sub-section, for the
# one block on the page that is byte-identical to another (the un-default gate
# and its success condition are the same two lines), where --containing
# correctly refuses to choose.
block_in() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$PAGE" --section "$1" --lang bash --block "$2" 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$PAGE" --section "$1" --lang bash --block "$2" 2>/dev/null; fi
}
block_in_sha() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$PAGE" --section "$1" --lang bash --block "$2" --sha 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$PAGE" --section "$1" --lang bash --block "$2" --sha 2>/dev/null; fi
}

# step NAME NEEDLE ... provenance + verbatim, then the caller runs it
step_begin() {
  local name="$1" needle="$2" sha
  _emit ""; _emit "=== STEP ${name} =============================================="
  sha="$(block_sha "$needle")" || { _emit "EXCEPTION: no block containing '${needle}' in ${PAGE} @ ${REF}"; return 1; }
  provenance "$( [ "$FROM_TREE" = "1" ] && echo "WORKTREE (uncommitted; not evidence about ${REF})" || echo "$REF" )" "$PAGE" "block containing: ${needle}" "-" "$sha"
}

# ============================================================== THE STEPS
# Each step: gate on done_step, gate on budget, run, record, mark_done.

# S01 ... Set these once. Two placeholders are the page's own YOU SUPPLY.
S=S01-set-these-once
if ! done_step "$S"; then budget_left || yield "S01+"
  step_begin "$S" 'export SITE_REPO_URL=YOUR_SITE_REPO_URL' || exit 3
  B="$(block 'export SITE_REPO_URL=YOUR_SITE_REPO_URL')"
  B="${B//YOUR_SITE_REPO_URL/$SITE_URL}"; B="${B//YOUR_TOCKMOX_CLONE_PATH/$TM_CLONE}"
  _emit "SUBSTITUTION: YOUR_SITE_REPO_URL -> ${SITE_URL}; YOUR_TOCKMOX_CLONE_PATH -> ${TM_CLONE}  (both YOU SUPPLY on the page)"
  execute_begin "install.md Set these once"; run_ws "$S" "$B"; execute_end $?
  want="$(kubectl --context="$KUBE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  got="$(out_of "$S" | grep -m1 '^https://' || true)"
  record "$S" "Set these once: the server address printed is the cluster under test (read, not recognised)" "$want" "$got"
  record "$S" "Set these once: both script paths exist (ls printed both)" "2" "$(out_of "$S" | grep -c 'tockmox-install.sh\|mint-secrets.sh' | tr -d ' ')"
  mark_done "$S"
fi

# S02 ... Confirm the handoff, in one block (five reads).
S=S02-confirm-handoff
if ! done_step "$S"; then budget_left || yield "S02+"
  step_begin "$S" "grep -Ei 'metallb|kube-vip|purelb|svclb'" || exit 3
  execute_begin "install.md Confirm the handoff"; run_ws "$S" "$(block "grep -Ei 'metallb|kube-vip|purelb|svclb'")"; execute_end $?
  record "$S" "handoff: every node Ready (no node line without Ready)" "0" "$(out_of "$S" | awk '$2 ~ /^(Ready|NotReady)/' | grep -vc ' Ready ' | tr -d ' ')"
  record "$S" "handoff: ArgoCD image tag is v2.6 or newer (major >= 3, or 2.x with minor >= 6)" "yes" "$(out_of "$S" | grep -m1 'argocd' | sed -E 's/.*:v([0-9]+)\.([0-9]+).*/\1 \2/' | awk '{ if ($1>2 || ($1==2 && $2>=6)) print "yes"; else print "no" }')"
  record "$S" "handoff: sealed-secrets readyReplicas prints 1" "1" "$(out_of "$S" | grep -Ex '[0-9]+' | head -1)"
  record "$S" "handoff: local-path listed and (default)" "1" "$(out_of "$S" | grep -c '^local-path (default)' | tr -d ' ')"
  record "$S" "handoff: fresh path, the LoadBalancer echo fires" "1" "$(out_of "$S" | grep -c 'no LoadBalancer controller running' | tr -d ' ')"
  mark_done "$S"
fi

# S03 ... the kubeseal check.
S=S03-kubeseal-version
if ! done_step "$S"; then budget_left || yield "S03+"
  step_begin "$S" 'kubeseal --version' || exit 3
  execute_begin "install.md kubeseal check"; run_ws "$S" "$(block 'kubeseal --version')"; execute_end $?
  cli="$(out_of "$S" | grep -m1 -i 'kubeseal version' | sed -E 's/.*([0-9]+\.[0-9]+)\.[0-9]+.*/\1/')"
  ctl="$(out_of "$S" | grep -m1 'sealed-secrets-controller' | sed -E 's/.*:([0-9]+\.[0-9]+)\.[0-9]+.*/\1/')"
  record "$S" "kubeseal client major.minor equals the controller's (${cli} vs ${ctl})" "$cli" "$ctl"
  mark_done "$S"
fi

# S04 ... precondition: can the cluster read the Tockmox repository. GitHub's
# copy is private until the public release; the page says exactly that. The
# block is run because a reader runs it; its documented failure is expected
# here and pinned as xfail so the day it starts passing is visible.
S=S04-ls-remote-github
if ! done_step "$S"; then budget_left || yield "S04+"
  step_begin "$S" 'git ls-remote https://github.com/tockmox/tockmox.git refs/tags/v0.8.0' || exit 3
  execute_begin "install.md Phase 1 precondition ls-remote"; GIT_TERMINAL_PROMPT=0 run_ws "$S" "$(block 'git ls-remote https://github.com/tockmox/tockmox.git refs/tags/v0.8.0')"; execute_end $?
  record "$S" "ls-remote of the public repo prints a SHA and the tag (xfail before the tag is pushed: this path runs on the candidate)" "prints" "$(out_of "$S" | grep -E '^[0-9a-f]{40}' >/dev/null && echo prints || echo nothing)" xfail
  note "S04: source 1 for this run is ${TM_URL} @ ${TM_REV}, a harness snapshot of the tree under test, NOT the published tag. Nothing below is evidence about GitHub's copy."
  mark_done "$S"
fi

# S05 ... 1a, the config-file route. $EDITOR is the glue that writes the four values.
S=S05-config-file
if ! done_step "$S"; then budget_left || yield "S05+"
  step_begin "$S" 'cp install/tockmox.yaml.example tockmox.yaml' || exit 3
  EDITOR_GLUE="${STATE}/editor-glue.sh"
  cat > "$EDITOR_GLUE" <<EOF
#!/usr/bin/env bash
# GLUE standing in for the reader's editor: writes the four YOU SUPPLY values,
# plus the repository override this harness needs (see the path header).
set -eu
f="\$1"
python3 - "\$f" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
def setk(s, path, val):
    # path like "global.internalDomain": replace the FIRST 'key:' line under the top-level block
    top, key = path.split('.',1)
    out=[]; intop=False; done=False
    for line in s.split('\n'):
        if re.match(r'^[A-Za-z]', line): intop = line.startswith(top+':')
        if intop and not done and re.match(r'^\s+'+re.escape(key)+r':', line):
            line=re.sub(r'^(\s+'+re.escape(key)+r':).*$', r'\1 '+val, line); done=True
        out.append(line)
    assert done, path
    return '\n'.join(out)
s=setk(s,'site.name','${SITE_NAME_V}')
s=setk(s,'global.internalDomain','${INTERNAL_DOMAIN_V}')
s=setk(s,'global.lanCIDR','${LAN_CIDR_V}')
s=setk(s,'addressPool.range','${POOL_V}')
s=setk(s,'tockmox.revision','${TM_REV}')
s=setk(s,'tockmox.repoURL','${TM_URL}')
open(p,'w').write(s)
PY
EOF
  chmod +x "$EDITOR_GLUE"; export EDITOR="$EDITOR_GLUE"
  _emit "GLUE: EDITOR=${EDITOR_GLUE} writes site.name=${SITE_NAME_V} internalDomain=${INTERNAL_DOMAIN_V} lanCIDR=${LAN_CIDR_V} addressPool.range=${POOL_V} tockmox.revision=${TM_REV} tockmox.repoURL=${TM_URL}"
  rm -f "${TM_CLONE}/tockmox.yaml"; rm -rf "${TM_CLONE}/tockmox-site"
  execute_begin "install.md 1a config-file route"; run_ws "$S" "$(block 'cp install/tockmox.yaml.example tockmox.yaml')"; execute_end $?
  nonempty=0
  for k in 'name' 'internalDomain' 'lanCIDR' 'range'; do
    grep -Eq "^\s*${k}:\s*\"?[^\"[:space:]]+" "${TM_CLONE}/tockmox.yaml" && nonempty=$((nonempty+1))
  done
  record "$S" "1a: tockmox.yaml exists and the four required keys are non-empty" "4" "$nonempty"
  mark_done "$S"
fi

# S06 ... 1b, the dry-run preflight.
S=S06-dry-run
if ! done_step "$S"; then budget_left || yield "S06+"
  step_begin "$S" '--config tockmox.yaml --dry-run' || exit 3
  execute_begin "install.md 1b --dry-run"; run_ws "$S" "$(block '--config tockmox.yaml --dry-run')"; execute_end $?
  record "$S" "1b: 'revision ${TM_REV} resolves in ${TM_URL}'" "1" "$(out_of "$S" | grep -c "revision ${TM_REV} resolves in" | tr -d ' ')"
  record "$S" "1b: 'settings valid'" "1" "$(out_of "$S" | grep -c 'settings valid' | tr -d ' ')"
  record "$S" "1b: 'dry-run: nothing will be written'" "1" "$(out_of "$S" | grep -c 'dry-run: nothing will be written' | tr -d ' ')"
  record "$S" "1b: 'installer finished. Nothing was applied to your cluster.'" "1" "$(out_of "$S" | grep -c 'installer finished. Nothing was applied' | tr -d ' ')"
  mark_done "$S"
fi

# S07 ... 1c, generate. The block exports SITE_REPO; the session carries it.
S=S07-generate
if ! done_step "$S"; then budget_left || yield "S07+"
  step_begin "$S" 'export SITE_REPO="$TOCKMOX/tockmox-site"' || exit 3
  execute_begin "install.md 1c generate the site repository"; run_ws "$S" "$(block 'export SITE_REPO="$TOCKMOX/tockmox-site"')"; execute_end $?
  record "$S" "1c: 'site repository written to'" "1" "$(out_of "$S" | grep -c 'site repository written to' | tr -d ' ')"
  n="$(out_of "$S" | sed -nE 's/.*PLACEHOLDER_SITE_REPO_URL in ([0-9]+) files.*/\1/p' | head -1)"
  printf '%s' "${n:-}" > "${STATE}/placeholder-count"
  record "$S" "1c: the installer names its placeholder count (a number)" "number" "$( [ -n "${n:-}" ] && echo number || echo none )"
  note "S07: installer placeholder count = ${n:-?} (the page says thirteen on a stock install with all nine layers on; 2b compares against this number, not the page's)"
  record "$S" "1c: SITE_REPO is exported into the session" "set" "$( [ -n "${SITE_REPO:-}" ] && echo set || echo unset )"
  mark_done "$S"
fi

# S08 ... 1c success condition.
S=S08-generate-success
if ! done_step "$S"; then budget_left || yield "S08+"
  step_begin "$S" 'ls "$SITE_REPO/site/values/"' || exit 3
  execute_begin "install.md 1c success condition"; run_ws "$S" "$(block 'ls "$SITE_REPO/site/values/"')"; execute_end $?
  record "$S" "1c success: root.yaml listed" "1" "$(out_of "$S" | grep -c 'bootstrap/root.yaml' | tr -d ' ')"
  record "$S" "1c success: site/values/ holds global.yaml" "1" "$(out_of "$S" | grep -cw 'global.yaml' | tr -d ' ')"
  mark_done "$S"
fi

# S09 ... 1d gate: node count.
S=S09-node-count
if ! done_step "$S"; then budget_left || yield "S09+"
  step_begin "$S" 'get nodes --no-headers | wc -l' || exit 3
  execute_begin "install.md 1d gate"; run_ws "$S" "$(block 'get nodes --no-headers | wc -l')"; execute_end $?
  nodes="$(out_of "$S" | grep -Ex '\s*[0-9]+\s*' | tr -d ' ' | head -1)"
  note "S09: node count reads ${nodes:-?}; 1d applies at 3 or more and is $( [ "${nodes:-0}" -ge 3 ] && echo APPLIED || echo SKIPPED ) per the page's own gate"
  record "$S" "1d gate printed a node count" "number" "$( [ -n "${nodes:-}" ] && echo number || echo none )"
  printf '%s' "${nodes:-}" > "${STATE}/node-count"
  mark_done "$S"
fi

# S09b ... 1f, the per-node gateway list the policy layer needs since 0.8.0
# (TM-0798). Appends to policy.yaml before the push, so S10 commits it.
S=S09b-node-sources
if ! done_step "$S"; then budget_left || yield "S09b+"
  step_begin "$S" '--print-netpol-node-sources' || exit 3
  execute_begin "install.md 1f node gateway addresses"; run_ws "$S" "$(block '--print-netpol-node-sources')"; execute_end $?
  run_ws "${S}-success" "$(block "grep -A8 '^platformNetpol:'")"
  record "$S" "1f success: one /31 per node" "${nodes:-$(cat "${STATE}/node-count" 2>/dev/null || echo '?')}" "$(out_of "${S}-success" | grep -Ex '\s*[0-9]+\s*' | tr -d ' ' | tail -1)"
  mark_done "$S"
fi

# S10 ... 2a push, then its success condition.
S=S10-push
if ! done_step "$S"; then budget_left || yield "S10+"
  step_begin "$S" 'git push -u origin main' || exit 3
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-p09}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-p09@example.invalid}"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  _emit "GLUE: git identity via GIT_AUTHOR_*/GIT_COMMITTER_* (a reader's workstation has one configured)"
  execute_begin "install.md 2a push"; run_ws "$S" "$(block 'git push -u origin main')"; execute_end $?
  run_ws "${S}-success" "$(block 'git -C "$SITE_REPO" remote -v')"
  record "$S" "2a success: the first status line is '## main...origin/main' (branch is main AND tracks the remote, so the push landed)" "## main...origin/main" "$(out_of "${S}-success" | grep -m1 '^## ')"
  record "$S" "2a success: origin is SITE_REPO_URL" "2" "$(out_of "${S}-success" | grep -c "origin.*${SITE_URL}" | tr -d ' ')"
  record "$S" "2a: the remote's main equals the local HEAD" "$(git -C "$SITE_REPO" rev-parse HEAD)" "$(git ls-remote "$SITE_URL" refs/heads/main | cut -f1)"
  mark_done "$S"
fi

# S11 ... 2b replace the placeholder, then its success condition.
S=S11-placeholder
if ! done_step "$S"; then budget_left || yield "S11+"
  step_begin "$S" 'git grep -l PLACEHOLDER_SITE_REPO_URL | while' || exit 3
  execute_begin "install.md 2b replace the placeholder"; run_ws "$S" "$(block 'git grep -l PLACEHOLDER_SITE_REPO_URL | while')"; execute_end $?
  run_ws "${S}-success" "$(block 'grep -l "$SITE_REPO_URL" | wc -l')"
  record "$S" "2b success: 'no file still carries the placeholder'" "1" "$(out_of "${S}-success" | grep -c 'no file still carries the placeholder' | tr -d ' ')"
  record "$S" "2b success: files carrying SITE_REPO_URL == the installer's placeholder count" "$(cat "${STATE}/placeholder-count")" "$(out_of "${S}-success" | grep -Ex '\s*[0-9]+\s*' | tr -d ' ' | tail -1)"
  mark_done "$S"
fi

# S12 ... 2c. The gate block, the credential block (synthetic token typed at
# the prompt), the success condition; then the Secret is removed (GLUE), since
# git:// carries no authentication and the reader's rule ("if you know it is
# private, do it regardless") is what this run is exercising, not the need.
S=S12-credential
if ! done_step "$S"; then budget_left || yield "S12+"
  step_begin "$S" 'read -rs READ_ONLY_TOKEN' || exit 3
  run_ws "${S}-gate" "$(block 'echo "public: skip this step"')"
  note "S12: 2c gate printed: $(out_of "${S}-gate" | grep -E 'public|private' | head -1)"
  TOK="p09-synthetic-$(openssl rand -hex 8)"
  printf 'read-only token: \t%s\n' "$TOK" > "${STATE}/${S}.answers"
  _emit "GLUE: a synthetic 32-byte token is typed at the prompt (never a real credential)"
  execute_begin "install.md 2c credential Secret"; run_ws "$S" "$(block 'read -rs READ_ONLY_TOKEN')" "${STATE}/${S}.answers"; execute_end $?
  record "$S" "2c: 'bytes read:' prints the token's length (TM-0537: the count is the stop signal)" "bytes read: ${#TOK}" "$(out_of "$S" | grep -m1 'bytes read:' | sed 's/^ *//')"
  record "$S" "2c: no STOP line (the paste reached the variable)" "0" "$(out_of "$S" | grep -c 'STOP: nothing was read' | tr -d ' ')"
  run_ws "${S}-success" "$(block ".data.password}' | base64 -d | wc -c")"
  record "$S" "2c success: the repository label is present" "1" "$(out_of "${S}-success" | grep -c 'argocd.argoproj.io/secret-type.*repository' | tr -d ' ')"
  record "$S" "2c success: the password byte count equals what was typed" "${#TOK}" "$(out_of "${S}-success" | grep -Ex '\s*[0-9]+\s*' | tr -d ' ' | tail -1)"
  _emit "GLUE: deleting secret/tockmox-site-repo again ... git:// has no credential to carry, and 2c is conditional on the page"
  kubectl --context="$KUBE_CONTEXT" -n argocd delete secret tockmox-site-repo --ignore-not-found >/dev/null 2>&1
  mark_done "$S"
fi

# S13 ... Phase 2.5 mint (dry-run then real; the seal-target prompt answered y).
S=S13-mint
if ! done_step "$S"; then budget_left || yield "S13+"
  step_begin "$S" 'mint-secrets.sh" --context "$KUBE_CONTEXT" --dry-run' || exit 3
  NTFY_PW="p09-ntfy-$(openssl rand -hex 6)"
  printf 'Seal against \ty\npassword (empty to skip ntfy): \t%s\nagain: \t%s\n' "$NTFY_PW" "$NTFY_PW" > "${STATE}/${S}.answers"
  _emit "GLUE: the 'Seal against <context>? [y/N]' prompt is answered y at the terminal, as a reader would;"
  _emit "      the ntfy password prompt (the script borrows the ntfy binary from the cluster when no local runtime answers) is answered twice with a synthetic value"
  execute_begin "install.md Phase 2.5 mint-secrets"; ZSH_PASTE_TIMEOUT=900 run_ws "$S" "$(block 'mint-secrets.sh" --context "$KUBE_CONTEXT" --dry-run')" "${STATE}/${S}.answers"; execute_end $?
  run_ws "${S}-success" "$(block 'ls "$SITE_REPO/secrets/"')"
  minted="$(out_of "${S}-success" | grep -o '[A-Za-z0-9._-]*\.sealed\.yaml' | sort -u | wc -l | tr -d ' ')"
  printf '%s' "$minted" > "${STATE}/minted-count"
  record "$S" "2.5 success: secrets/ holds sealed files (count > 0)" "yes" "$( [ "${minted:-0}" -gt 0 ] && echo yes || echo no )"
  # the block runs --dry-run then the real mint, so the LAST MINTED list is the real one; ALREADY PRESENT files count too (a re-run after a yield is the page's own "doing the right thing")
  record "$S" "2.5: every file the script listed under MINTED or ALREADY PRESENT (last run) is present in secrets/" "$(out_of "$S" | awk '/^MINTED/{m=0;f=1;next} /^ALREADY PRESENT/{f=1;next} /^NOT MINTED/{f=0} /^NEXT/{f=0} f && /sealed\.yaml/{m++} END{print m+0}')" "$minted"
  note "S13: NOT MINTED (last run): $(out_of "$S" | awk '/^NOT MINTED/{f=1;buf="";next} /^NEXT/{f=0} f{buf=buf $0 " "} END{print buf}' | cut -c1-260)"
  mark_done "$S"
fi

# S14 ... commit and push the sealed credentials.
S=S14-commit-secrets
if ! done_step "$S"; then budget_left || yield "S14+"
  step_begin "$S" 'git add secrets/ && git commit -m "sealed credentials" && git push' || exit 3
  execute_begin "install.md Phase 2.5 commit"; run_ws "$S" "$(block 'git add secrets/ && git commit -m "sealed credentials" && git push')"; execute_end $?
  record "$S" "2.5 commit: the remote's main equals the local HEAD after the push" "$(git -C "$SITE_REPO" rev-parse HEAD)" "$(git ls-remote "$SITE_URL" refs/heads/main | cut -f1)"
  record "$S" "2.5 commit: the sealed files are tracked at the remote" "$(cat "${STATE}/minted-count")" "$(git -C "$SITE_REPO" ls-tree -r --name-only HEAD secrets/ | grep -c '\.sealed\.yaml' | tr -d ' ')"
  mark_done "$S"
fi

# S15 ... 3a apply root.yaml + success condition.
S=S15-apply-root
if ! done_step "$S"; then budget_left || yield "S15+"
  step_begin "$S" 'apply -f "$SITE_REPO/bootstrap/root.yaml"' || exit 3
  execute_begin "install.md 3a apply the root Application"; run_ws "$S" "$(block 'apply -f "$SITE_REPO/bootstrap/root.yaml"')"; execute_end $?
  date +%s > "${STATE}/root-applied-at"
  run_ws "${S}-success" "$(block 'get application tockmox-root')"
  record "$S" "3a success: application/tockmox-root exists" "1" "$(out_of "${S}-success" | grep -c '^tockmox-root ' | tr -d ' ')"
  mark_done "$S"
fi

# S16 ... 3b: site-secrets Synced (the block is re-read until it is, or 10 min),
# then the success condition (sealedsecrets listed, a real Secret produced).
S=S16-site-secrets
if ! done_step "$S"; then budget_left || yield "S16+"
  step_begin "$S" 'get application site-secrets' || exit 3
  deadline=$(( $(date +%s) + 600 )); sync=""
  while :; do
    run_ws "$S" "$(block 'get application site-secrets')" >/dev/null
    sync="$(out_of "$S" | grep -m1 -E '^(Synced|OutOfSync|Unknown)' | awk '{print $1}')"
    [ "$sync" = "Synced" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    budget_left || yield "S16 (waiting for site-secrets to sync; re-run to keep waiting)"
    sleep 15
  done
  execute_begin "install.md 3b"; run_ws "$S" "$(block 'get application site-secrets')"; execute_end $?
  record "$S" "3b: site-secrets reports Synced" "Synced" "$(out_of "$S" | grep -m1 -E '^(Synced|OutOfSync|Unknown)' | awk '{print $1}')"
  sleep 10
  run_ws "${S}-success" "$(block 'get secret tockmox-authentik')"
  record "$S" "3b success: every minted file is listed as a SealedSecret (namespace + name rows)" "$(cat "${STATE}/minted-count")" "$(out_of "${S}-success" | grep -cE '^tockmox-[a-z-]+\s+tockmox-' | tr -d ' ')"
  record "$S" "3b success: the controller produced secret/tockmox-authentik (an Opaque Secret row)" "1" "$(out_of "${S}-success" | grep -cE '^tockmox-authentik\s+Opaque' | tr -d ' ')"
  mark_done "$S"
fi

# S17 ... 3c watch the waves. `-w` never returns; a reader presses Ctrl-C.
# Twenty seconds of the watch is pasted, then the page's own success
# condition (the readiness-bar block further down) is read TWICE, three
# minutes apart, exactly as the page says, until it prints nothing twice or
# 40 minutes pass since root.yaml was applied.
S=S17-watch-waves
if ! done_step "$S"; then budget_left || yield "S17+"
  step_begin "$S" 'get applications -w' || exit 3
  if [ ! -f "${STATE}/${S}.out" ]; then
    execute_expect_nonzero "a -w watch only returns on Ctrl-C (130), which is how the page's reader leaves it"
    execute_begin "install.md 3c watch the waves (20s, then Ctrl-C)"; ZSH_PASTE_INTERRUPT=20 run_ws "$S" "$(block 'get applications -w')"; execute_end $?
    record "$S" "3c: the watch listed tockmox-root" "1" "$(out_of "$S" | grep -c '^tockmox-root' | tr -d ' ')"
  fi
  BAR="$(block "awk '\$2 != \"Synced\" || \$3 != \"Healthy\"'")"
  deadline=$(( $(cat "${STATE}/root-applied-at") + 2400 ))
  while :; do
    run_ws "${S}-bar" "$BAR" >/dev/null
    now=$(date +%s); lines="$(out_of "${S}-bar" | grep -c . | tr -d ' ')"
    if [ "$lines" = "0" ]; then
      if [ -f "${STATE}/bar-first-clean" ]; then
        first=$(cat "${STATE}/bar-first-clean")
        if [ $(( now - first )) -ge 180 ]; then break; fi
      else printf '%s' "$now" > "${STATE}/bar-first-clean"; fi
    else rm -f "${STATE}/bar-first-clean"; fi
    _emit "  readiness bar at +$(( now - $(cat "${STATE}/root-applied-at") ))s: ${lines} not-ready line(s): $(out_of "${S}-bar" | tr '\n' ';' | cut -c1-160)"
    # Stop waiting early when the only residue is the DNS-blocked state the
    # page itself lists as expected, held for three minutes (same bar).
    if [ "$(out_of "${S}-bar" | awk '{print $1}' | sort -u | tr '\n' ' ')" = "tockmox-devops " ] \
       && kubectl --context="$KUBE_CONTEXT" -n tockmox-devops logs deploy/tockmox-devops-argo-workflows-server --tail=3 2>/dev/null | grep 'no such host' >/dev/null; then
      if [ -f "${STATE}/bar-dns-only-since" ]; then
        [ $(( now - $(cat "${STATE}/bar-dns-only-since") )) -ge 180 ] && break
      else printf '%s' "$now" > "${STATE}/bar-dns-only-since"; fi
    else rm -f "${STATE}/bar-dns-only-since"; fi
    [ "$now" -ge "$deadline" ] && break
    budget_left || yield "S17 (waiting for the waves; re-run to keep waiting)"
    sleep 30
  done
  first=$(cat "${STATE}/bar-first-clean" 2>/dev/null || echo 0); now=$(date +%s)
  if [ "$first" -gt 0 ] && [ $(( now - first )) -ge 180 ] && [ "$(out_of "${S}-bar" | grep -c .)" = "0" ]; then
    record "$S" "readiness bar: prints nothing, and nothing again at least three minutes later (site-apps excluded)" "clean twice" "clean twice"
  else
    # The page's own "expected to look broken" table names ONE state that only
    # DNS clears: argo-workflows-server exiting on `lookup auth.<domain> ... no
    # such host`. A throwaway has no resolver for the internal domain, so if
    # tockmox-devops is the ONLY line left and its log ends that way, the bar
    # is blocked by the environment, not falsified. Recorded as xfail with the
    # measured reason; anything else left is a real FAIL.
    left="$(out_of "${S}-bar" | awk '{print $1}' | sort -u | tr '\n' ' ')"
    tail3="$(kubectl --context="$KUBE_CONTEXT" -n tockmox-devops logs deploy/tockmox-devops-argo-workflows-server --tail=3 2>/dev/null | tr '\n' ' ')"
    if [ "$left" = "tockmox-devops " ] && printf '%s' "$tail3" | grep 'no such host' >/dev/null; then
      record "$S" "readiness bar: clean twice ... BLOCKED by the environment: only tockmox-devops remains and its log ends 'no such host' for auth.${INTERNAL_DOMAIN_V} (the page's expected-broken row 2; clears with DNS, lab only)" "clean twice" "devops only, DNS" xfail
    else
      record "$S" "readiness bar: prints nothing, and nothing again at least three minutes later (site-apps excluded)" "clean twice" "not clean after $(( now - $(cat "${STATE}/root-applied-at") ))s: $(out_of "${S}-bar" | tr '\n' ';' | cut -c1-200)"
    fi
  fi
  mark_done "$S"
fi

# S18 ... 3c's render-and-compare block for the policy layer.
S=S18-policy-render
if ! done_step "$S"; then budget_left || yield "S18+"
  step_begin "$S" 'helm template "$TOCKMOX/charts/tockmox-policy"' || exit 3
  execute_begin "install.md 3c render the policy layer"; run_ws "$S" "$(block 'helm template "$TOCKMOX/charts/tockmox-policy"')"; execute_end $?
  record "$S" "3c render: the policy chart renders NetworkPolicy objects" "yes" "$(out_of "$S" | grep 'kind: NetworkPolicy' >/dev/null && echo yes || echo no)"
  note "S18: rendered kinds: $(out_of "$S" | grep 'kind:' | sed 's/^ *//' | tr '\n' ';' | cut -c1-240)  (the page's own table is 'illustrative rather than a measurement')"
  mark_done "$S"
fi

# S19 ... un-default gate: how many defaults.
S=S19-default-gate
if ! done_step "$S"; then budget_left || yield "S19+"
  UNDEF_SECTION="### Then un-default k3s's StorageClass"
  _emit ""; _emit "=== STEP ${S} =============================================="
  sha="$(block_in_sha "$UNDEF_SECTION" 1)" || { _emit "EXCEPTION: no block 1 under '${UNDEF_SECTION}'"; exit 3; }
  provenance "$( [ "$FROM_TREE" = "1" ] && echo "WORKTREE (uncommitted; not evidence about ${REF})" || echo "$REF" )" "$PAGE" "$UNDEF_SECTION" 1 "$sha"
  execute_begin "install.md un-default gate"; run_ws "$S" "$(block_in "$UNDEF_SECTION" 1)"; execute_end $?
  defaults="$(out_of "$S" | grep -c '(default)' | tr -d ' ')"
  record "$S" "un-default gate: exactly one class marked (default) on a stock install (the page: 'On a stock install it will NOT')" "1" "$defaults"
  note "S19: $( [ "$defaults" -ge 2 ] && echo 'two defaults: the NODE step applies (not run here: node-local)' || echo 'one default: the un-default step is skipped per the page' )"
  mark_done "$S"
fi

# S20 ... what is expected to look broken: the devops log tail (read only).
S=S20-devops-log
if ! done_step "$S"; then budget_left || yield "S20+"
  step_begin "$S" 'logs deploy/tockmox-devops-argo-workflows-server --tail=3' || exit 3
  execute_begin "install.md expected-broken read"; run_ws "$S" "$(block 'logs deploy/tockmox-devops-argo-workflows-server --tail=3')"; execute_end $?
  note "S20: argo-workflows-server tail: $(out_of "$S" | tail -3 | tr '\n' ' ' | cut -c1-240)"
  record "$S" "expected-broken read: the log block ran against an existing Deployment" "0" "$(out_of "$S" | grep -c 'NotFound' | tr -d ' ')"
  mark_done "$S"
fi

# S21 ... Point DNS at Traefik's address: the Service read, and the domain read.
S=S21-traefik-and-domain
if ! done_step "$S"; then budget_left || yield "S21+"
  step_begin "$S" '-l app.kubernetes.io/name=traefik' || exit 3
  execute_begin "install.md Traefik Service read"; run_ws "$S" "$(block '-l app.kubernetes.io/name=traefik')"; execute_end $?
  ext="$(out_of "$S" | awk '/LoadBalancer/{print $4}' | head -1)"
  record "$S" "Traefik Service shows an EXTERNAL-IP from the pool rather than <pending> (MetalLB installed and assigning)" "assigned" "$( printf '%s' "$ext" | grep -E '^[0-9]+\.' >/dev/null && echo assigned || echo "${ext:-none}" )"
  B="$(block 'export LAN_RESOLVER=YOUR_LAN_RESOLVER_IP')"; B="${B//YOUR_LAN_RESOLVER_IP/${TOCKMOX_P09_LAN_RESOLVER:-YOUR_LAN_RESOLVER_IP}}"
  run_ws "${S}-domain" "$B"
  record "$S" "the domain block reads internalDomain back out of the generated site values" "domain: ${INTERNAL_DOMAIN_V}" "$(out_of "${S}-domain" | grep -m1 -o 'domain: [^ ]*')"
  mark_done "$S"
fi

# S21b ... the DNS success condition (TM-0897): a random label under the zone,
# which only a wildcard record answers, resolves to Traefik's address from the
# workstation (dig @LAN_RESOLVER) and from a pod (CoreDNS). It needs a resolver
# the cluster's nodes also use, holding *.<internalDomain> at the pool address
# Traefik took. A throwaway has none, so without TOCKMOX_P09_LAN_RESOLVER the
# step says so and asserts nothing (not an xfail: nothing here is a defect).
S=S21b-dns-wildcard-check
if ! done_step "$S"; then budget_left || yield "S21b+"
  if [ -z "${TOCKMOX_P09_LAN_RESOLVER:-}" ]; then
    note "S21b: the DNS success condition (random label, workstation and pod) needs a LAN resolver the cluster's nodes use, holding *.${INTERNAL_DOMAIN_V}; none on a throwaway (TOCKMOX_P09_LAN_RESOLVER unset), so it is not run (lab only)"
  else
    step_begin "$S" 'tockmox-probe-$RANDOM' || exit 3
    ext="$(out_of S21-traefik-and-domain | awk '/LoadBalancer/{print $4}' | head -1)"
    execute_begin "install.md DNS success condition"; run_ws "$S" "$(block 'tockmox-probe-$RANDOM')"; execute_end $?
    probe="$(out_of "$S" | awk '/^probe:/{print $2; exit}')"
    record "$S" "the probe is a fresh random label under the zone" "yes" "$(case "$probe" in tockmox-probe-[0-9]*".${INTERNAL_DOMAIN_V}") echo yes ;; *) echo "no (${probe:-none})" ;; esac)"
    record "$S" "the workstation resolves the random label to Traefik's address" "${ext:-traefik-address}" "$(out_of "$S" | awk '/^workstation:/{print $2; exit}')"
    record "$S" "a pod resolves the random label to Traefik's address" "${ext:-traefik-address}" "$(out_of "$S" | awk '/^pod:/{print $2; exit}')"
  fi
  mark_done "$S"
fi

# S22 ... model-gateway key gate (a Service exists?) and verify what Tockmox authored.
S=S22-verify-authored
if ! done_step "$S"; then budget_left || yield "S22+"
  step_begin "$S" 'get ns -l app.kubernetes.io/part-of=tockmox' || exit 3
  execute_begin "install.md Verify what Tockmox authored"; run_ws "$S" "$(block 'get ns -l app.kubernetes.io/part-of=tockmox')"; execute_end $?
  record "$S" "verify: namespaces with the reserved tockmox- prefix are listed" "yes" "$(out_of "$S" | grep '^tockmox-' >/dev/null && echo yes || echo no)"
  record "$S" "verify: NetworkPolicies carrying the part-of label exist" "yes" "$(out_of "$S" | awk '$1 ~ /^tockmox-/ && $2 ~ /./ {n++} END{print (n>0)?"yes":"no"}')"
  record "$S" "verify: ValidatingAdmissionPolicies present at cluster scope" "yes" "$(out_of "$S" | grep -i 'tockmox' >/dev/null && echo yes || echo no)"
  mark_done "$S"
fi

# The execute phase is a per-invocation fact in lib/assert.sh; a resumed final
# call that only replays would otherwise be refused a PASS. Persist the last
# execute_end's rc and re-declare it from state, saying so.
[ "$EXEC_PHASE_COMPLETED" -eq 1 ] && printf '%s' "$EXEC_LAST_RC" > "${STATE}/last-execute-rc"
if [ "$EXEC_PHASE_STARTED" -eq 0 ] && [ -f "${STATE}/last-execute-rc" ]; then
  execute_begin "replayed from state: the documented blocks ran in earlier invocations of this path (see STEP logs above in the same report)"
  execute_end "$(cat "${STATE}/last-execute-rc")"
fi
# ================================================================= REPLAY
_emit ""; _emit "=== REPLAY of every recorded verdict through lib/assert.sh ==========="
while IFS=$'\t' read -r st desc exp act flag; do
  _replay_val="$act"
  if [ "$flag" = "xfail" ]; then
    assert_artifact_xfail "[${st}] ${desc}" 'printf %s "$_replay_val"' "$exp"
  else
    assert_artifact "[${st}] ${desc}" 'printf %s "$_replay_val"' "$exp"
  fi
done < "${STATE}/verdicts.tsv"
_emit ""; _emit "NOTES (from the run):"; sed 's/^NOTE\t/  - /' "${STATE}/notes.txt" 2>/dev/null | while IFS= read -r l; do _emit "$l"; done

does_not_prove \
  "Anything about GitHub's copy of the product repository or the published tag: source 1 was a harness snapshot of the working tree served from inside the cluster under test (S04's note names the URL and revision). The credential path for a PRIVATE product repository is not exercised." \
  "That the page's NODE step (the .skip file) works: node-local, not reachable from this harness, and gated off on a stock install anyway (S19)." \
  "The DNS success condition (S21b, a random label from the workstation and a pod) unless TOCKMOX_P09_LAN_RESOLVER named a resolver holding the wildcard; the model-gateway key (LiteLLM off by default), or the ntfy subscription: each needs a device, a resolver or a Service this throwaway does not have. Lab only." \
  "Anything about the interactive installer route (1a's first block): only the config-file route ran. tests/installer covers the interactive prompts hermetically." \
  "That the render in S18 matches the page's illustrative table; the page itself says that table is not a dated verification." \
  "That a reader with a REAL editor lands the same four values: \$EDITOR was a script (glue) writing them. The block was unchanged." \
  "That the 2c credential Secret is CONSUMED by ArgoCD: it was created, measured, and removed, because a git:// remote carries no authentication. What is proven is the block's byte count and the Secret's password length (TM-0537's rc4 clause), not the clone through it."

parity_caveat \
  "The workstation shell was ${WS_SHELL} $( [ "$WS_SHELL" = zsh ] && "${ZSH:-zsh}" -c 'echo $ZSH_VERSION' 2>/dev/null ) on Linux/arm64, pasted through a pty with bracketed paste. macOS ships zsh 5.9; INTERACTIVE_COMMENTS, read -p, word-splitting and NOMATCH behave the same in both. The guest is an Ubuntu cloud image on KubeVirt, single node."

path_finish

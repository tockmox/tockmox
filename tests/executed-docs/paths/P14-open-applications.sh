#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tockmox:route=argocd-helm
#
# PATH P14 ... the applications open to every signed-in user (docs/administration/identity.md, "Applications open to
# every signed-in user"), on the install P09 made. The identity layer lists every Authentik application that has no
# group or user binding in ONE ConfigMap, tockmox-identity-open-applications, and the console's Status page warns
# about each one the site did not declare open. identity.md says of itself that this was proved on stand-ins and not
# on a cluster. This path runs it on one, in three rows:
#
#   S01  an application with no binding is planted, and the list names it, not declared open (the shape the console
#        warns about)
#   S02  the site names it in sso.access.everyone, and the list marks it declared open (the console says nothing)
#   S03  the declaration is taken out again and the application is bound to tockmox-admins, and the list no longer
#        names it; the job's own TOCKMOX_OPEN_TO_EVERYONE reads [] by then, so the binding is what cleared it
#
# THE PAGES PRINT YAML AND NO COMMAND for any of this, so there is no command here to read out of a page. What is
# read out of the pages, VERBATIM (lib/extract-block.sh, never retyped), is the YAML a site commits:
#   A  docs/administration/argocd.md, "A hostname and a portal tile": the blueprint ConfigMap for Argo CD's sign-in
#      (a provider, the application `argocd`, a binding to tockmox-admins, and the tockmox-users binding stated absent)
#   B  the same section: the identity layer's blueprint list that names that ConfigMap (site/values/identity.yaml)
#   C  docs/administration/identity.md, "Applications open to every signed-in user": sso.access.everyone
# The page's blueprint route for Argo CD's sign-in is the one argocd.md says was not executed; S03 delivers block A
# exactly as printed and reads the page's own success condition for it ("the console's Status page does not list
# argocd under Open applications"), from the list the console reads.
#
# GLUE, each labelled GLUE in the log and none of it page text:
#   - the unbound application of S01. No page prints an application without a binding (the pages exist to prevent
#     one). It is block A with its policybinding entries taken out and nothing else changed
#     (lib/p14-open-applications.py unbind, which refuses when there is no such entry to take out).
#   - the file name under apps/ (the page says "under apps/, which site-apps syncs" and names no file).
#   - block C's slug: the page's example names `handbook`, with the comment "the application's slug in Authentik";
#     the path writes the slug of the application it planted in its place. The log names the substitution.
#   - blocks B and C are appended to site/values/identity.yaml as printed. A file that already has a top-level
#     `authentik:` or `sso:` key cannot take them that way; that is recorded as a failed row, not merged around.
#   - taking the declaration out again in S03: the file is put back to the bytes it had before S02.
#   - the commits and the pushes to origin, and asking ArgoCD to refresh rather than wait for its poll. The pages say
#     "put it in your site repository" and give no command.
#   - the waits. Nothing starts the job by hand: it runs on its schedule (every ten minutes), as on a site, and each
#     row waits, bounded, for the list to read what the row expects.
#
# WHEN IT RUNS. run.sh discovers paths/P*.sh and gives this one P09's route group, so a plain run.sh reaches it. It
# does not run there unless P09's state exists. It needs TOCKMOX_P09_STATE, a p09-passed marker in it, the site
# repository P09 exported (SITE_REPO, in P09's session.env) and a git remote named origin on that repository. Any of
# them missing is BLOCKED with the reason, before any call to a cluster. The remote is the last precondition on
# purpose: on the built-in forge main takes pull requests only, which a harness cannot make an approver approve, so
# this path runs on the external route, like P12.
#
# WHAT IT LEAVES. The site repository and the cluster end with block A as the page prints it: Argo CD's sign-in
# application in Authentik, bound to tockmox-admins, with example.com in its two redirect URLs (the page says to put
# your domain there; nothing here signs in through it). Nothing else is planted and nothing is deleted.
#
# ITS OWN STATE AND BUDGET. State goes under ${TOCKMOX_P09_STATE}/p14. TOCKMOX_P14_BUDGET (seconds, default 5400) is
# checked before each step starts, never inside one. Past it, with steps remaining, the path exits 75.
#
# TIME, worst case, from the waits below: each row waits at most TOCKMOX_P14_WAIT (default 1500 seconds: ArgoCD's
# sync, the identity pods' restart when the blueprint list changes, the job's ten minute schedule and its run), so
# 75 minutes for the three. A row that reads what it expects stops waiting at once.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null  # read at run time, from beside this file
. "${HERE}/../lib/assert.sh"

path_begin "P14-open-applications" \
  "after P09: an unbound Authentik application is listed as open, declaring it open stops the warning, and binding it to tockmox-admins takes it off the list"

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
# the site repository P09 generated: its session carries the SITE_REPO that 1c exported
SITE_LINE="$(grep -E '^(export|declare -x) SITE_REPO=' "${P09_STATE}/session.env" 2>/dev/null | tail -1 || true)"
[ -n "$SITE_LINE" ] || blocked "P09's session in ${P09_STATE} holds no SITE_REPO, so there is no site repository to put a blueprint in"
SITE_REPO="$( eval "${SITE_LINE#declare -x }" 2>/dev/null; printf '%s' "${SITE_REPO:-}" )"
[ -n "$SITE_REPO" ] && [ -d "$SITE_REPO" ] || blocked "the site repository P09 recorded is not a directory (${SITE_REPO:-unset})"
git -C "$SITE_REPO" remote get-url origin >/dev/null 2>&1 \
  || blocked "the site repository has no remote named origin: on the built-in forge main takes pull requests only, so the pages' commits cannot be delivered by a harness. Run the external route"

# every kubectl call below names its cluster with --context from this variable, and an empty value is
# refused rather than falling back to the current context (docs/deployment/fresh-install.md, "Name the
# cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"
REF="${TOCKMOX_DOCS_REF:?set TOCKMOX_DOCS_REF to the tag under test}"

STATE="${P09_STATE}/p14"
BUDGET="${TOCKMOX_P14_BUDGET:-5400}"
WAIT="${TOCKMOX_P14_WAIT:-1500}"
POLL="${TOCKMOX_P14_POLL:-20}"
T0=$(date +%s)
mkdir -p "$STATE"
for t in kubectl git python3; do
  command -v "$t" >/dev/null 2>&1 || { _emit "INFRA: '$t' is not on PATH"; path_outcome INFRA_ERROR "missing $t"; exit 1; }
done

# ------------------------------------------------------------- the stock install's names
# charts/tockmox-identity/templates/open-applications.yaml: the ConfigMap and the CronJob, in namespaces.identity
# (charts/tockmox-identity/values.yaml). The slug and the ConfigMap's name are block A's own.
IDENTITY_NS=tockmox-authentik
LIST_CM=tockmox-identity-open-applications
LIST_CRON=tockmox-open-applications
ARGO_NS=argocd
SLUG=argocd
PAGE_SLUG=handbook
BP_NAME=argocd-sso-blueprint
BP_PATH="apps/${BP_NAME}.yaml"

FROM_TREE="${TOCKMOX_P14_FROM_TREE:-${TOCKMOX_P09_FROM_TREE:-0}}"
ARGO_PAGE="docs/administration/argocd.md"
ARGO_PAGE_FILE="${TOCKMOX_P14_ARGO_PAGE_FILE:-${HERE}/../../../${ARGO_PAGE}}"
ARGO_SECTION="## A hostname and a portal tile"
ID_PAGE="docs/administration/identity.md"
ID_PAGE_FILE="${TOCKMOX_P14_ID_PAGE_FILE:-${HERE}/../../../${ID_PAGE}}"
ID_SECTION="## Applications open to every signed-in user"
EXTRACT="${HERE}/../lib/extract-block.sh"
VERDICT_PY="${HERE}/../lib/p14-open-applications.py"
verdict() { python3 -I "$VERDICT_PY" "$@"; }

# ------------------------------------------------------------- state helpers
# The same shape as P12's and P13's: a step is skipped once done, a verdict is written to verdicts.tsv as it is made
# and replayed through assert_artifact at the end, and a spent budget exits 75 so the path is called again.
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
# reset_rows STEP ... drop the rows of an earlier attempt at this step that never finished, so a second try writes each row once
reset_rows() {
  [ -f "${STATE}/verdicts.tsv" ] || return 0
  grep -v -- "^${1}"$'\t' "${STATE}/verdicts.tsv" > "${STATE}/verdicts.tmp" || true
  mv "${STATE}/verdicts.tmp" "${STATE}/verdicts.tsv"
}

# --------------------------------------------------------------- the pages
# xblock PAGE FILE SECTION NEEDLE ... one fenced yaml block, verbatim; empty on none or several
xblock() {
  if [ "$FROM_TREE" = "1" ]; then "$EXTRACT" --file "$2" --section "$3" --lang yaml --containing "$4" 2>/dev/null
  else "$EXTRACT" --ref "$REF" --page "$1" --section "$3" --lang yaml --containing "$4" 2>/dev/null; fi
}
# page_yaml NAME PAGE FILE SECTION NEEDLE ... the block into ${STATE}/NAME.yaml, its fingerprint in the log; fails when it does not resolve
page_yaml() {
  xblock "$2" "$3" "$4" "$5" > "${STATE}/${1}.yaml"
  [ -s "${STATE}/${1}.yaml" ] || return 1
  provenance "$( [ "$FROM_TREE" = "1" ] && echo "WORKTREE" || echo "$REF" )" "$2" "${4}, the yaml block containing '${5}'" "-" \
    "$(sha256sum < "${STATE}/${1}.yaml" | cut -d' ' -f1)"
}

# --------------------------------------------------------------- the list, the delivery and the wait
# read_list FILE ... the ConfigMap the job writes and the console reads, as JSON
read_list() { kubectl --context="$KUBE_CONTEXT" -n "$IDENTITY_NS" get configmap "$LIST_CM" -o json > "$1" 2> "${1}.err"; }
# wait_listed STEP WANT ... poll the list until it reads WANT for the slug or WAIT seconds pass. Sets LAST and WAITED.
LAST=""; WAITED=0
wait_listed() {
  local s="$1" want="$2" t0
  t0=$(date +%s)
  while :; do
    read_list "${STATE}/${s}.list.json"
    LAST="$(verdict listed --slug "$SLUG" < "${STATE}/${s}.list.json" | head -1)"
    WAITED=$(( $(date +%s) - t0 ))
    [ "$LAST" = "$want" ] && break
    [ "$WAITED" -ge "$WAIT" ] && break
    sleep "$POLL"
  done
  note "${s}: waited ${WAITED}s (limit ${WAIT}s) for the list to read '${want}' for ${SLUG}; it read '${LAST}' (list written $(verdict written-at < "${STATE}/${s}.list.json" | head -1))"
}
# top_key FILE KEY ... "absent" or "present": whether FILE has that top-level key, which decides if a block can be appended as printed
top_key() { if grep -q "^${2}:" "$1" 2>/dev/null; then echo present; else echo absent; fi; }
# deliver STEP MESSAGE FILE... ... GLUE: one commit of the named files, pushed to origin, and ArgoCD asked to refresh
deliver() {
  local s="$1" msg="$2"; shift 2
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-p14}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-p14@example.invalid}"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  _emit "GLUE: the pages say to put this in the site repository and give no command: one commit ($*), pushed to origin; git identity via GIT_AUTHOR_*/GIT_COMMITTER_*"
  execute_begin "GLUE: commit ${*} and push to origin (${msg})"
  git -C "$SITE_REPO" add "$@" >/dev/null 2>&1 \
    && git -C "$SITE_REPO" commit -q -m "$msg" >/dev/null 2>&1 \
    && git -C "$SITE_REPO" push origin main > "${STATE}/${s}.push" 2>&1
  execute_end $?
  sed 's/^/    | /' "${STATE}/${s}.push" 2>/dev/null | while IFS= read -r l; do _emit "$l"; done
  record "$s" "origin's main equals the local HEAD after the push (${msg})" "$(git -C "$SITE_REPO" rev-parse HEAD)" \
    "$(git -C "$SITE_REPO" ls-remote origin refs/heads/main | cut -f1)"
  _emit "GLUE: ask ArgoCD to refresh now, rather than wait for its poll"
  kubectl --context="$KUBE_CONTEXT" -n "$ARGO_NS" annotate applications.argoproj.io --all argocd.argoproj.io/refresh=hard --overwrite > "${STATE}/${s}.refresh" 2>&1
  sed 's/^/    | /' "${STATE}/${s}.refresh" | while IFS= read -r l; do _emit "$l"; done
}

finish_path() {
  # The execute phase is a per-invocation fact in lib/assert.sh; a resumed final call that only replays would
  # otherwise be refused a PASS. Persist the last execute_end's rc and re-declare it from state, saying so.
  [ "$EXEC_PHASE_COMPLETED" -eq 1 ] && printf '%s' "$EXEC_LAST_RC" > "${STATE}/last-execute-rc"
  if [ "$EXEC_PHASE_STARTED" -eq 0 ] && [ -f "${STATE}/last-execute-rc" ]; then
    execute_begin "replayed from state: the commits were delivered in an earlier invocation of this path (see the STEP logs above in the same report)"
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
    "What the console's Status page shows: this reads the ConfigMap the console reads, not the page. That the console turns a listed application into one named warning, and a declared one into none, is tockmox-ui/tests/test_open_applications.py's, on fixtures of what the job writes; no browser signed in here." \
    "That the unbound application of S01 is one a reader could make from a page: no page prints an application without a binding, so it is the page's blueprint with its policybinding entries taken out by the harness (GLUE)." \
    "An application made by hand in Authentik's admin interface, or bound on its Policy / Group / User Bindings tab: both rows go through a site blueprint." \
    "That a binding to a policy alone still warns, that a negated or disabled binding does not count, or that a slug in sso.access.everyone that matches no application is reported: tests/identity-open-applications covers those on stand-ins." \
    "That Argo CD's sign-in works: block A is delivered as printed, with example.com in its redirect URLs and no client secret copied into Argo CD. Only the application's place on the list is read." \
    "That Argo CD leaves the job's data alone on a sync, as a claim of its own: the list is read after three syncs and still held the job's data each time, which is evidence for it and not a test of it." \
    "That the built-in forge route works: the pages' commits are pull requests there, which a harness does not open or approve. This path runs on the external route only." \
    "That the install itself works: that is P09's."

  parity_caveat \
    "git and kubectl ran from a Linux runner against a single-node KubeVirt guest, the one P09 installed. The pages' YAML was written to the site repository by the harness, not pasted by a reader, and no step of this path is a command a page prints."

  path_finish
}

record_success_conditions "$ARGO_PAGE_FILE" "${ARGO_PAGE} @ $( [ "$FROM_TREE" = "1" ] && echo WORKTREE || echo "$REF" )"
record_success_conditions "$ID_PAGE_FILE" "${ID_PAGE} @ $( [ "$FROM_TREE" = "1" ] && echo WORKTREE || echo "$REF" )"

# ============================================================== THE STEPS
# S01 ... an application with no binding, and the list names it.
S=S01-plant
if ! done_step "$S"; then budget_left || yield "S01+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  page_yaml block-a "$ARGO_PAGE" "$ARGO_PAGE_FILE" "$ARGO_SECTION" "name: ${BP_NAME}" \
    && page_yaml block-b "$ARGO_PAGE" "$ARGO_PAGE_FILE" "$ARGO_SECTION" "- ${BP_NAME}" \
    && page_yaml block-c "$ID_PAGE" "$ID_PAGE_FILE" "$ID_SECTION" "everyone:" \
    || { record "$S" "the pages' three YAML blocks resolve" "three blocks" "missing or ambiguous"; finish_path; exit $?; }
  VALUES_PATH="$(sed -n '1s/^# //p' "${STATE}/block-b.yaml")"
  record "$S" "blocks B and C name the same file in their first line, the identity layer's site values" \
    "site/values/identity.yaml site/values/identity.yaml" "${VALUES_PATH} $(sed -n '1s/^# //p' "${STATE}/block-c.yaml")"
  printf '%s' "$VALUES_PATH" > "${STATE}/values-path"
  record "$S" "block A as printed binds the application: one binding present (tockmox-admins), one stated absent" \
    "1 present, 1 absent" "$(verdict bindings < "${STATE}/block-a.yaml" | head -1)"
  read_list "${STATE}/${S}.before.json"
  record "$S" "before anything is planted the list is readable and does not name ${SLUG}, so a listing afterwards is this path's" \
    "not listed" "$(verdict listed --slug "$SLUG" < "${STATE}/${S}.before.json" | head -1)"
  _emit "GLUE: no page prints an application without a binding. The unbound one is block A with its policybinding entries taken out and nothing else changed."
  verdict unbind < "${STATE}/block-a.yaml" > "${STATE}/unbound.yaml"
  record "$S" "GLUE: the planted blueprint is block A with no binding left in it" "0 present, 0 absent" "$(verdict bindings < "${STATE}/unbound.yaml" | head -1)"
  _emit "GLUE: the page says 'under apps/' and names no file; the path writes ${BP_PATH}"
  mkdir -p "${SITE_REPO}/apps"
  cat "${STATE}/unbound.yaml" > "${SITE_REPO}/${BP_PATH}"
  v="$(top_key "${SITE_REPO}/${VALUES_PATH}" authentik)"
  record "$S" "${VALUES_PATH} has no top-level authentik key yet, so block B can be appended as printed" "absent" "$v"
  if [ "$v" = absent ]; then
    { printf '\n'; cat "${STATE}/block-b.yaml"; printf '\n'; } >> "${SITE_REPO}/${VALUES_PATH}"
    deliver "$S" "Plant an application with no binding: ${SLUG}" "$BP_PATH" "$VALUES_PATH"
    : > "${STATE}/planted"
    wait_listed "$S" "listed, not declared open"
    record "$S" "row 1: the list names the unbound application ${SLUG}, not declared open (the console warns about it by name)" \
      "listed, not declared open" "$LAST"
  fi
  mark_done "$S"
fi
VALUES_PATH="$(cat "${STATE}/values-path" 2>/dev/null || true)"

# S02 ... the site says it is meant for everyone, and it stops warning.
S=S02-everyone
if ! done_step "$S"; then budget_left || yield "S02+"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  v=unplanted
  if [ -f "${STATE}/planted" ]; then
    [ -f "${STATE}/values-before-everyone" ] || cp "${SITE_REPO}/${VALUES_PATH}" "${STATE}/values-before-everyone"
    v="$(top_key "${STATE}/values-before-everyone" sso)"
    record "$S" "${VALUES_PATH} has no top-level sso key yet, so block C can be appended as printed" "absent" "$v"
  else
    record "$S" "S01 planted the application this step declares open" "planted" "not planted"
  fi
  if [ "$v" = absent ]; then
    _emit "SUBSTITUTION: ${PAGE_SLUG} -> ${SLUG}  (the page's example slug; its comment says 'the application's slug in Authentik', and GLUE names the one it planted)"
    sed "s/^\\( *- \\)${PAGE_SLUG}\\( \\|\$\\)/\\1${SLUG}\\2/" "${STATE}/block-c.yaml" > "${STATE}/everyone.yaml"
    record "$S" "GLUE: block C is written whole, with the planted slug in place of the page's example" "1 0" \
      "$(grep -c "^ *- ${SLUG}\\( \\|\$\\)" "${STATE}/everyone.yaml" | tr -d ' ') $(grep -c "^ *- ${PAGE_SLUG}\\( \\|\$\\)" "${STATE}/everyone.yaml" | tr -d ' ')"
    { cat "${STATE}/values-before-everyone"; printf '\n'; cat "${STATE}/everyone.yaml"; printf '\n'; } > "${SITE_REPO}/${VALUES_PATH}"
    deliver "$S" "Declare ${SLUG} open to every signed-in user" "$VALUES_PATH"
    wait_listed "$S" "listed, declared open"
    record "$S" "row 3: named in sso.access.everyone, ${SLUG} is still listed and is marked declared open (the console does not warn)" \
      "listed, declared open" "$LAST"
  fi
  mark_done "$S"
fi

# S03 ... the declaration out again, the application bound to tockmox-admins, and the list no longer names it.
S=S03-bind
if ! done_step "$S"; then budget_left || yield "S03"
  reset_rows "$S"
  _emit ""; _emit "=== STEP ${S} =============================================="
  if [ -f "${STATE}/planted" ] && [ -f "${STATE}/values-before-everyone" ] && [ -s "${STATE}/block-a.yaml" ]; then
    _emit "GLUE: the declaration is taken out again (${VALUES_PATH} goes back to its bytes before S02), so that a cleared list is the binding's doing"
    cat "${STATE}/values-before-everyone" > "${SITE_REPO}/${VALUES_PATH}"
    cat "${STATE}/block-a.yaml" > "${SITE_REPO}/${BP_PATH}"
    record "$S" "the blueprint in the site repository is block A as printed, byte for byte" \
      "$(sha256sum < "${STATE}/block-a.yaml" | cut -d' ' -f1)" "$(sha256sum < "${SITE_REPO}/${BP_PATH}" | cut -d' ' -f1)"
    deliver "$S" "Bind ${SLUG} to tockmox-admins, as the page prints it" "$BP_PATH" "$VALUES_PATH"
    wait_listed "$S" "not listed"
    record "$S" "row 2: bound to tockmox-admins, ${SLUG} is no longer on the list (the page's success condition: Status does not list it under Open applications)" \
      "not listed" "$LAST"
    kubectl --context="$KUBE_CONTEXT" -n "$IDENTITY_NS" get cronjob "$LIST_CRON" -o json > "${STATE}/${S}.cronjob.json" 2>/dev/null
    record "$S" "the job reads no declared-open slug by then (TOCKMOX_OPEN_TO_EVERYONE), so the binding is what took ${SLUG} off the list" \
      "[]" "$(verdict everyone-env < "${STATE}/${S}.cronjob.json" | head -1)"
  else
    record "$S" "S01 and S02 left what this step starts from (block A, and the values file as it was before the declaration)" "present" "missing"
  fi
  mark_done "$S"
fi

finish_path
exit $?

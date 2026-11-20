#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof that a run which reads its pages from the working tree says what that tree is. No cluster.
#
# The p09 lane serves this tree and runs every path with TOCKMOX_P09_FROM_TREE=1, so the pages a path executes are
# the bytes on disk, not the ref's. Each SOURCE line used to print "WORKTREE (uncommitted; not evidence about <ref>)"
# whenever that variable was set, which in the lane is always: a lane run on a clean checkout of the ref read as not
# evidence about it, exactly like one on a tree with an edit in it. lib/assert.sh's tree_source now compares the tree
# with the ref, and it is the only place that spells the answer:
#
#   HEAD is the ref's commit, git status --porcelain empty    tree: <sha>, clean
#   HEAD is the ref's commit, an edited or untracked file      WORKTREE-DIRTY (...; not evidence about <ref>)
#   HEAD is not the ref's commit, or either does not resolve   WORKTREE-MISMATCH (...; not evidence about <ref>)
#
# The helper is run against a scratch repository; then the real lane runs the real run.sh in that repository (a stub
# cluster, a fixture P09 whose SOURCE line is written the way the real paths write theirs), on a clean tree at the ref,
# with a modified page, and one commit off the ref; then the real P09 and P12 are read for any WORKTREE text of their
# own; then copies of lib/assert.sh that lose one comparison each must print "clean" where they must not.
#
#   ./tests/executed-docs/tree-source-test.sh
#   ED_SRC=/path/to/tests/executed-docs ./tests/executed-docs/tree-source-test.sh   another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture bodies are literal text
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${ED_SRC:-$HERE}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
mut() { # IN OUT OLD NEW ... a copy with OLD replaced by NEW; refuses an edit that changes nothing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
t = s.replace(old, new)
assert t != s, "the edit changed nothing: %r" % old
open(dst, "w", encoding="utf-8").write(t)
PY
}
# The scratch repository's git: no user or system configuration (a signing or hook setting there must not decide this)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
G() { git -C "$FX" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

# ---- the scratch repository: the real lib, run.sh and lane, stub provisioners, fixture paths, one page
FX="${TMP}/repo"; L="${FX}/tests/executed-docs"; mkdir -p "$L/provision" "$L/paths" "${FX}/docs/deployment" "${TMP}/lbin"
cp -R "${SRC}/lib" "$L/lib"; cp "${SRC}/p09-lane.sh" "$L/p09-lane.sh"; cp "${SRC}/run.sh" "$L/run.sh"
printf '# Install Tockmox\n\n```bash\necho the page\n```\n' > "${FX}/docs/deployment/install.md"
cat > "$L/provision/throwaway-cluster.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in create) echo apiVersion: v1 > "$LANE_TMP/guest.kubeconfig"; echo "$LANE_TMP/guest.kubeconfig" ;; esac
STUB
printf '#!/usr/bin/env bash\n[ "$1" = url ] && echo http://site-repo.stub/tockmox.git\nexit 0\n' > "$L/provision/site-repo-server.sh"
PASSBODY='path_begin "fx" "a fixture path that passes"
execute_begin "nothing"; execute_end 0
assert_artifact "one equals one" "printf 1" 1
path_finish'
for pp in P04-fixture P05-fixture P11-fresh-install-recovery P13-planted-faults P15-approver-revocation; do
  printf '#!/usr/bin/env bash\n. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"\n%s\n' "$PASSBODY" > "$L/paths/${pp}.sh"
done
# the fixture P09 writes its SOURCE line as paths/P09-install-md-end-to-end.sh does (checked against the real one below)
printf '#!/usr/bin/env bash\n. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"\nREF="$TOCKMOX_DOCS_REF"\nFROM_TREE="${TOCKMOX_P09_FROM_TREE:-0}"\nprovenance "$(source_label "$REF" "$FROM_TREE")" "docs/deployment/install.md" "# Install Tockmox" 1 "-"\n%s\n' \
  "$PASSBODY" > "$L/paths/P09-install-md-end-to-end.sh"
printf '' > "$L/expected-outcomes.txt"
for t in helm kubeseal openssl zsh curl age age-keygen; do printf '#!/bin/sh\nexit 0\n' > "${TMP}/lbin/$t"; done
cat > "${TMP}/lbin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *"config current-context"*) echo stub-guest ;;
  *"config get-contexts"*) echo stub-guest ;;
  *InternalIP*) echo 192.0.2.5 ;;
  *"get nodes"*) printf True ;;
  *"version -o json"*) echo '{"serverVersion": {"gitVersion": "v0"}}' ;;
esac
STUB
chmod +x "${TMP}/lbin"/* "$L/provision"/*.sh "$L"/paths/*.sh "$L/run.sh"
if G init -q && G add -A && G commit -q -m fixture && G tag v-fixture; then
  SHA="$(G rev-parse HEAD)"
else
  bad "the scratch repository" "git init/add/commit/tag failed"; SHA=none
fi
[ -z "$(G status --porcelain)" ] && ok "the scratch repository is clean at v-fixture (the control for every case below)" \
  || bad "scratch repository clean" "$(G status --porcelain | head -3)"

# ---- the helper, against the scratch repository
# helper LIB TREE REF [FROM_TREE] ... what LIB's source_label (FROM_TREE given) or tree_source prints
helper() {
  if [ $# -ge 4 ]; then bash -c '. "$1"; _ASSERT_TREE="$2"; source_label "$3" "$4"' _ "$1" "$2" "$3" "$4" 2>&1
  else bash -c '. "$1"; tree_source "$2" "$3"' _ "$1" "$2" "$3" 2>&1; fi
}
LIB="$L/lib/assert.sh"
got="$(helper "$LIB" "$FX" v-fixture)"
[ "$got" = "tree: ${SHA}, clean" ] && ok "clean tree at the ref: 'tree: <sha>, clean'" || bad "clean at ref" "got '$got'"
got="$(helper "$LIB" "$FX" v-fixture 0)"
[ "$got" = "v-fixture" ] && ok "a path that reads at the ref (FROM_TREE 0) names the ref, unchanged" || bad "FROM_TREE 0" "got '$got'"
got="$(helper "$LIB" "$FX" v-fixture 1)"
[ "$got" = "tree: ${SHA}, clean" ] && ok "source_label with FROM_TREE 1 is tree_source of the tree the pages come from" || bad "source_label FROM_TREE 1" "got '$got'"
cp "${FX}/docs/deployment/install.md" "${TMP}/page.orig"
printf 'an edit nobody committed\n' >> "${FX}/docs/deployment/install.md"
got="$(helper "$LIB" "$FX" v-fixture)"
case "$got" in "WORKTREE-DIRTY (tree: ${SHA} with 1 uncommitted change(s); not evidence about v-fixture)") ok "a modified page at the ref: WORKTREE-DIRTY, not evidence about the ref" ;; *) bad "modified page" "got '$got'" ;; esac
cp "${TMP}/page.orig" "${FX}/docs/deployment/install.md"
: > "${FX}/docs/untracked.md"
got="$(helper "$LIB" "$FX" v-fixture)"
case "$got" in WORKTREE-DIRTY*"not evidence about v-fixture)") ok "an untracked file (served and read like any other): WORKTREE-DIRTY" ;; *) bad "untracked file" "got '$got'" ;; esac
got="$(cd "$FX" && git -c status.showUntrackedFiles=no status --porcelain)"
[ -z "$got" ] && { got="$(bash -c '. "$1"; git() { command git -c status.showUntrackedFiles=no "$@"; }; tree_source "$2" v-fixture' _ "$LIB" "$FX" 2>&1)"
  case "$got" in WORKTREE-DIRTY*) ok "... also where git is configured to hide untracked files" ;; *) bad "untracked hidden by config" "got '$got'" ;; esac; } \
  || bad "the hidden-untracked control" "status.showUntrackedFiles=no still listed: $got"
rm -f "${FX}/docs/untracked.md"
got="$(helper "$LIB" "$FX" no-such-ref)"
case "$got" in "WORKTREE-MISMATCH (tree: HEAD ${SHA}, no-such-ref is unresolved; not evidence about no-such-ref)") ok "a ref that does not resolve: WORKTREE-MISMATCH" ;; *) bad "unresolved ref" "got '$got'" ;; esac
mkdir -p "${TMP}/notgit"
got="$(helper "$LIB" "${TMP}/notgit" v-fixture)"
case "$got" in WORKTREE-MISMATCH*"HEAD unresolved"*) ok "a tree that is not a git checkout: WORKTREE-MISMATCH" ;; *) bad "not a checkout" "got '$got'" ;; esac

# ---- the real lane and the real run.sh, in the scratch repository
LN=0
run_lane() { # -> status in $LRC, output in $LOUT (the lane's lines and run.sh's report, which run.sh also prints)
  local lrun=$((LN+1)); LN=$lrun; mkdir -p "${TMP}/h-${lrun}/home" "${TMP}/h-${lrun}/work"
  LOUT="$(env -u TOCKMOX_KEEP_CLUSTER -u TOCKMOX_P09_ROUTE -u TOCKMOX_P09_NETPOL -u TOCKMOX_P09_APPROVER_WATCH \
    HOME="${TMP}/h-${lrun}/home" TOCKMOX_WORKDIR="${TMP}/h-${lrun}/work" LANE_TMP="${TMP}/h-${lrun}" PATH="${TMP}/lbin:$PATH" \
    KUBECONFIG="${TMP}/h-${lrun}/substrate.kubeconfig" TOCKMOX_DOCS_REF=v-fixture TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate \
    TOCKMOX_TEST_VM=ed-lane TOCKMOX_TREE_SOURCE="tree: ${SHA}, clean" bash "$L/p09-lane.sh" 2>&1)"
  LRC=$?
}
has() { printf '%s\n' "$LOUT" | grep -F -- "$1" >/dev/null; }
tl() { printf '%s' "$LOUT" | grep -E 'tree|SOURCE|lane: ' | tail -6 | tr '\n' ' '; }

run_lane
CLEAN="tree: ${SHA}, clean"
[ "$LRC" = 0 ] && ok "lane on a clean tree at the ref: exit 0 (the control)" || bad "lane control" "rc=$LRC $(tl)"
has "lane 3: the tree under test is ${CLEAN}" && ok "... the lane records it before serving the tree: '${CLEAN%% *} <sha>, clean'" || bad "lane 3 line, clean" "$(tl)"
has "  tree under test: ${CLEAN}" && ok "... run.sh's report header says it" || bad "report header, clean" "$(tl)"
has "SOURCE:   docs/deployment/install.md @ ${CLEAN}" && ok "... and P09's SOURCE line names the commit, not WORKTREE" || bad "SOURCE line, clean" "$(printf '%s\n' "$LOUT" | grep SOURCE | head -2)"
! has "WORKTREE" && ok "... and nothing in the lane's output says WORKTREE" || bad "no WORKTREE on a clean tree" "$(printf '%s\n' "$LOUT" | grep WORKTREE | head -2)"
! has "not evidence about" && ok "... nor that the run is not evidence about the ref" || bad "no 'not evidence' on a clean tree" "$(printf '%s\n' "$LOUT" | grep 'not evidence' | head -2)"
has "lane: what ran was ${CLEAN}" && ok "... and the lane says it again when it ends" || bad "lane end line, clean" "$(tl)"

printf 'an edit nobody committed\n' >> "${FX}/docs/deployment/install.md"
run_lane
cp "${TMP}/page.orig" "${FX}/docs/deployment/install.md"
has "lane 3: the tree under test is WORKTREE-DIRTY (tree: ${SHA} with 1 uncommitted change(s); not evidence about v-fixture)" \
  && ok "lane with a modified page at the ref: WORKTREE-DIRTY at step 3" || bad "lane 3 line, dirty" "$(tl)"
has "SOURCE:   docs/deployment/install.md @ WORKTREE-DIRTY" && ok "... P09's SOURCE line says WORKTREE-DIRTY" || bad "SOURCE line, dirty" "$(printf '%s\n' "$LOUT" | grep SOURCE | head -2)"
has "  tree under test: WORKTREE-DIRTY" && has "what ran is not evidence about v-fixture" \
  && ok "... the report header names it and the run summary says the run is not evidence about the ref" || bad "header and summary, dirty" "$(tl)"
! has "$CLEAN" && ok "... and nothing calls that tree clean, although the lane was handed a TOCKMOX_TREE_SOURCE that said so" || bad "dirty tree called clean" "$(printf '%s\n' "$LOUT" | grep -F "$CLEAN" | head -2)"

printf 'one commit past the ref\n' >> "${FX}/docs/deployment/install.md"
G commit -q -am "one commit past the ref"
OFF="$(G rev-parse HEAD)"
run_lane
has "lane 3: the tree under test is WORKTREE-MISMATCH (tree: HEAD ${OFF}, v-fixture is ${SHA}; not evidence about v-fixture)" \
  && ok "lane on a tree one commit off the ref: WORKTREE-MISMATCH at step 3, naming both commits" || bad "lane 3 line, mismatch" "$(tl)"
has "SOURCE:   docs/deployment/install.md @ WORKTREE-MISMATCH" && ok "... P09's SOURCE line says WORKTREE-MISMATCH" || bad "SOURCE line, mismatch" "$(printf '%s\n' "$LOUT" | grep SOURCE | head -2)"
has "what ran is not evidence about v-fixture" && ok "... and the run summary says so" || bad "summary, mismatch" "$(tl)"
G reset -q --hard v-fixture

# ---- the real paths: one helper, no WORKTREE text of their own
WT="$(grep -n 'WORKTREE' "${SRC}"/paths/*.sh 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')"
[ -z "$WT" ] && ok "no path script writes WORKTREE text of its own (lib/assert.sh spells every tag)" || bad "WORKTREE text in a path" "$(printf '%s' "$WT" | head -3)"
for p in P09-install-md-end-to-end P12-bring-your-own-ca; do
  f="${SRC}/paths/${p}.sh"
  n="$(grep -c 'source_label "$REF" "$FROM_TREE"' "$f" 2>/dev/null)"
  other="$(grep -E '^[[:space:]]*provenance "\$\(' "$f" | grep -v 'provenance "$(source_label "$REF" "$FROM_TREE")"')"
  [ "${n:-0}" -ge 1 ] && [ -z "$other" ] && ok "${p}: every SOURCE line built from FROM_TREE comes from source_label (${n})" \
    || bad "${p} uses the shared helper" "source_label ${n:-0} times; other: $(printf '%s' "$other" | head -2)"
done

# ---- mutated copies of lib/assert.sh: each loses one comparison and must print clean where it must not
MLIB="${TMP}/mut-assert.sh"
printf 'an edit nobody committed\n' >> "${FX}/docs/deployment/install.md"
mut "$LIB" "$MLIB" 'elif [ -n "$changes" ]; then' 'elif false; then'
[ "$(helper "$MLIB" "$FX" v-fixture)" = "tree: ${SHA}, clean" ] \
  && ok "mutation: a tree_source that does not read git status calls a modified page clean, so the dirty case is the guard" \
  || bad "mutation: no status check" "got '$(helper "$MLIB" "$FX" v-fixture)'"
cp "${TMP}/page.orig" "${FX}/docs/deployment/install.md"
G commit -q --allow-empty -m "one commit past the ref"
mut "$LIB" "$MLIB" '[ "$head" != "$want" ]; then' 'false; then'
case "$(helper "$MLIB" "$FX" v-fixture)" in "tree: "*", clean") ok "mutation: a tree_source that does not compare HEAD with the ref calls a tree one commit off clean, so the mismatch case is the guard" ;;
  *) bad "mutation: no HEAD comparison" "got '$(helper "$MLIB" "$FX" v-fixture)'" ;; esac
G reset -q --hard v-fixture

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

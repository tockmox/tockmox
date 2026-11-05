#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh after forge-dump-tests.sh, whose stand-in it uses (dp_start, dp_stop,
# lib/forge-stub.py). Groups M1-M5: install/forge-move.sh, reached as
# `tockmox-install.sh move-forge`.
#
# HERMETIC, and git is REAL: the forge's repository and the target are bare repositories
# the stand-in serves over HTTP, so the history the move pushes, the change it opens and
# the merge it waits for are real commits. The stand-in plays the forge's pull-request API
# (MOVE: merge, wait or close, switched by the file move-mode) and a kubectl of the
# script's own (below) plays the Secret, the port-forward and the applies. Every assertion
# reads what the move LEFT: the target's refs and files, what was applied, whether the
# forge's repository was archived.

FM_IN="$RS_URL"   # the built-in forge's in-cluster address, as forge-restore-tests.sh names it
FM_BIN="$WORK/forge-move-bin"; mkdir -p "$FM_BIN"
cat > "$FM_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$FM_STATE/calls.log"
a=" $* "
case "$a" in
  *" get secret tockmox-forge-admin "*username*) printf 'tockmox-admin' | base64; exit 0 ;;
  *" get secret tockmox-forge-admin "*password*) printf 'pw' | base64; exit 0 ;;
  *" port-forward "*) echo "Forwarding from 127.0.0.1:${FM_PORT} -> 3000"; exec sleep 300 ;;
  *" apply -f - "*) n=$(ls "$FM_STATE"/applied-* 2>/dev/null | wc -l | tr -d ' '); cat > "$FM_STATE/applied-$n"; exit 0 ;;
  *" apply -f "*) cp "${@: -1}" "$FM_STATE/root-applied.yaml"; exit 0 ;;
esac
echo "kubectl stub: unhandled: $*" >&2; exit 99
STUB
chmod +x "$FM_BIN/kubectl"
FM_STATUS=0

# fm_start NAME [ENV=VAL ...]: the stand-in, with the forge's repository holding a small
# built-in-forge site (two files name the in-cluster address, one does not), a tag and a
# second branch, and an empty target. Sets D, DP_PORT, FM_TO.
fm_git() { PATH="$DP_PATH" git "$@"; }
fm_start() {
  dp_start "$@"
  local W="$D/fmwork"
  fm_git -C "$D/root/tockmox/site.git" config http.receivepack true
  fm_git clone -q "$D/root/tockmox/site.git" "$W"
  mkdir -p "$W/bootstrap/applications"
  printf 'spec:\n  source:\n    repoURL: %s\n' "$FM_IN" > "$W/bootstrap/root.yaml"
  printf 'spec:\n  source:\n    repoURL: %s\n' "$FM_IN" > "$W/bootstrap/applications/tockmox-ai.yaml"
  printf '# my site\n' > "$W/README.md"
  fm_git -C "$W" add -A && fm_git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q -m "the site"
  fm_git -C "$W" tag v1 && fm_git -C "$W" branch feature
  fm_git -C "$W" push -q origin main feature v1
  mkdir -p "$D/state"; : > "$D/state/calls.log"
  printf 'pusher\ntok\n' > "$D/creds"
  FM_TO="http://127.0.0.1:$DP_PORT/remote/site.git"
}
fm_run() {
  set +e
  env PATH="$FM_BIN:$DP_PATH" FM_STATE="$D/state" FM_PORT="$DP_PORT" NO_COLOR=1 TOCKMOX_TEST_ALLOW_HTTP=1 \
    TMPDIR="$D" bash "$INSTALLER" move-forge "$@" >"$D/out/stdout" 2>"$D/out/stderr" </dev/null
  FM_STATUS=$?
  set -e
}
fm_target() { PATH="$DP_PATH" git --git-dir "$D/root/remote/site.git" "$@"; }
fm_forge() { PATH="$DP_PATH" git --git-dir "$D/root/tockmox/site.git" "$@"; }

path_begin "M1" "move-forge refuses before it touches anything: no context, a plain-http target, a target that is not empty"
fm_start m1
fm_run --to "$FM_TO" --credentials "$D/creds" --yes-context lab
assert_artifact "no --context is refused" \
  "echo $FM_STATUS; grep -c 'never falls back to the current context' '$D/out/stderr'" "$(printf '1\n1')"
set +e; env PATH="$FM_BIN:$DP_PATH" FM_STATE="$D/state" NO_COLOR=1 bash "$INSTALLER" move-forge --context lab --yes-context lab \
  --to "$FM_TO" --credentials "$D/creds" >"$D/out/stdout" 2>"$D/out/stderr" </dev/null; FM_STATUS=$?; set -e
assert_artifact "outside the tests, a target that is not https is refused" \
  "echo $FM_STATUS; grep -c 'must be an https URL' '$D/out/stderr'" "$(printf '1\n1')"
fm_git -C "$D/fmwork" push -q "$D/root/remote/site.git" main
fm_run --context lab --yes-context lab --to "$FM_TO" --credentials "$D/creds"
assert_artifact "a target that already holds a branch is refused, and nothing is applied or opened" \
  "echo $FM_STATUS; grep -c 'is not empty' '$D/out/stderr'; ls '$D/state' | grep -c applied || true; ls '$D/root' | grep -c moves || true" \
  "$(printf '1\n1\n0\n0')"
dp_stop

path_begin "M2" "a move: the whole history, Argo CD's credential, one change, then the merged main, the root re-applied, the forge archived"
fm_start m2 MOVE=merge
fm_run --context lab --yes-context lab --to "$FM_TO" --credentials "$D/creds" --approval-wait-minutes 1
assert_artifact "it exits 0 and says the forge is archived" \
  "echo $FM_STATUS; grep -c 'repository is archived' '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "every branch and the tag reached the target" \
  "fm_target for-each-ref --format='%(refname)' | LC_ALL=C sort | tr '\n' ' '" \
  "refs/heads/feature refs/heads/main refs/tags/v1 "
assert_artifact "the target's main IS the forge's merged main, and holds the history before it" \
  "[ \"\$(fm_target rev-parse main)\" = \"\$(fm_forge rev-parse main)\" ] && echo same; fm_target merge-base --is-ancestor v1 main && echo history" \
  "$(printf 'same\nhistory')"
assert_artifact "on the target, the two files that named the forge name the target, and the README is untouched" \
  "fm_target show main:bootstrap/root.yaml | grep -c '$FM_TO'; fm_target show main:bootstrap/applications/tockmox-ai.yaml | grep -c '$FM_TO'; fm_target show main:bootstrap/root.yaml | grep -cF '$FM_IN' || true; fm_target show main:README.md" \
  "$(printf '1\n1\n0\n# my site')"
assert_artifact "Argo CD got a repository Secret for the target, before the change" \
  "grep -c 'argocd.argoproj.io/secret-type: repository' '$D/state/applied-0'; grep -c \"url: \\\"$FM_TO\\\"\" '$D/state/applied-0'" "$(printf '1\n1')"
assert_artifact "the root Application was re-applied from the target's tree" \
  "grep -c '$FM_TO' '$D/state/root-applied.yaml'" "1"
assert_artifact "the built-in forge's repository was archived, not deleted" \
  "cat '$D/root/archived'; echo; fm_forge rev-parse --verify -q main >/dev/null && echo still-there" "$(printf 'true\nstill-there')"
dp_stop

path_begin "M3" "no approval within the wait: it stops after the change, and --finish completes the move once it is merged"
fm_start m3
echo wait > "$D/root/move-mode"
fm_run --context lab --yes-context lab --to "$FM_TO" --credentials "$D/creds" --approval-wait-minutes 0
assert_artifact "it exits 3 and names --finish" \
  "echo $FM_STATUS; grep -c 'run move-forge --finish' '$D/out/stdout'" "$(printf '3\n1')"
assert_artifact "the target holds the history but not the change yet, and nothing was archived" \
  "fm_target show main:bootstrap/root.yaml | grep -c '$FM_IN'; [ -e '$D/root/archived' ] && echo ARCHIVED || echo not-archived" \
  "$(printf '1\nnot-archived')"
echo merge > "$D/root/move-mode"
fm_run --context lab --yes-context lab --to "$FM_TO" --credentials "$D/creds" --finish --approval-wait-minutes 1
assert_artifact "--finish finds the change, waits for its merge and completes the move" \
  "echo $FM_STATUS; fm_target show main:bootstrap/root.yaml | grep -c '$FM_TO'; cat '$D/root/archived'; echo" "$(printf '0\n1\ntrue')"
fm_run --context lab --yes-context lab --to "$FM_TO" --credentials "$D/creds"
assert_artifact "running the whole move again is refused: the target is no longer empty" \
  "echo $FM_STATUS; grep -c 'is not empty' '$D/out/stderr'" "$(printf '1\n1')"
dp_stop

path_begin "M4" "a change closed without merging stops the move, and says Argo CD still reads the forge"
fm_start m4
echo close > "$D/root/move-mode"
fm_run --context lab --yes-context lab --to "$FM_TO" --credentials "$D/creds" --approval-wait-minutes 1
assert_artifact "it exits 1, says so, and archives nothing" \
  "echo $FM_STATUS; grep -c 'closed without merging. Nothing moved' '$D/out/stderr'; [ -e '$D/root/archived' ] && echo ARCHIVED || echo not-archived" \
  "$(printf '1\n1\nnot-archived')"
dp_stop

path_begin "M5" "--dry-run checks the target and pushes nothing"
fm_start m5
fm_run --context lab --to "$FM_TO" --credentials "$D/creds" --dry-run
assert_artifact "it exits 0, says what it would do, and the target stays empty" \
  "echo $FM_STATUS; grep -c 'would push every branch and tag' '$D/out/stdout'; fm_target for-each-ref | wc -l | tr -d ' '" "$(printf '0\n1\n0')"
dp_stop

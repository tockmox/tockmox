#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh after forge-move-tests.sh, whose stand-in it uses (dp_start, dp_stop,
# lib/forge-stub.py). Groups MI1-MI6: install/forge-move-in.sh, reached as
# `tockmox-install.sh move-in-forge`.
#
# HERMETIC, and git is REAL: the site checkout, the forge's repository (a bare repository
# the stand-in serves over HTTP) and the migration commit are real commits. A kubectl of
# this file's own plays Argo CD (its Applications before and after the cutover, switched
# by the file mi-mode), the repository Secrets, the forge's admin Secret and the applies; a
# stand-in bootstrap-forge records what it was given and pushes the migrated tree to the
# forge's repository the way the real one does (refusing history that is not an ancestor).
# What the stand-ins do not prove is that a real Argo CD settles: the lab run does.
# Every assertion reads what the move LEFT: the forge's refs and files, what was applied
# and deleted, what bootstrap-forge was given, the checkout it must not have changed.

MI_FROM="https://example.invalid/me/site.git"
MI_FROM_SSH="git@example.invalid:me/site.git"
MI_IN="$RS_URL"   # the built-in forge's in-cluster address, as forge-restore-tests.sh names it
MI_BIN="$WORK/forge-move-in-bin"; mkdir -p "$MI_BIN"
cat > "$MI_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$MI_STATE/calls.log"
a=" $* "
case "$a" in
  *" config view "*) printf 'https://lab.example.invalid:6443'; exit 0 ;;
  *" get applications.argoproj.io "*) exec python3 "$MI_STATE/apps.py" ;;
  *" get secret tockmox-forge-admin -o name "*) [[ -f "$MI_STATE/forge-installed" ]] && { echo secret/tockmox-forge-admin; exit 0; }; exit 1 ;;
  *" get secret tockmox-forge-admin "*username*) printf 'tockmox-admin' | base64; exit 0 ;;
  *" get secret tockmox-forge-admin "*password*) printf 'pw' | base64; exit 0 ;;
  *" port-forward "*) echo "Forwarding from 127.0.0.1:${MI_PORT} -> 3000"; exec sleep 300 ;;
  *" get secret -l "*) printf '{"items":[{"metadata":{"name":"repo-site"},"data":{"url":"%s"}}]}' "$(printf '%s' "$MI_FROM_SSH" | base64 | tr -d '\n')"; exit 0 ;;
  *" get secret repo-site -o json "*) printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"repo-site","namespace":"argocd","uid":"x"},"type":"Opaque","data":{"url":"dXJs","sshPrivateKey":"a2V5"}}'; exit 0 ;;
  *" apply -f - "*) n=$(ls "$MI_STATE"/applied-* 2>/dev/null | wc -l | tr -d ' '); cat > "$MI_STATE/applied-$n"; exit 0 ;;
  *" apply -f "*) cp "${@: -1}" "$MI_STATE/root-applied.yaml"; exit 0 ;;
  *" delete secret "*) exit 0 ;;
esac
echo "kubectl stub: unhandled: $*" >&2; exit 99
STUB
chmod +x "$MI_BIN/kubectl"
# Argo CD, as this kubectl reports it. Before the root is applied from the forge: everything reads
# the site repository at the checkout's revision. After: per mi-mode (settle, stuck, prune).
cat > "$MI_BIN/apps.py" <<'PY'
import json, os, subprocess
st = os.environ["MI_STATE"]
mode = open(os.path.join(st, "mi-mode")).read().strip()
moved = mode == "moved" or (os.path.exists(os.path.join(st, "root-applied.yaml")) and mode != "stuck")
rev = open(os.path.join(st, "rev")).read().strip()
if moved:
    rev = subprocess.run(["git", "--git-dir", os.environ["MI_FORGE"], "rev-parse", "main"],
                         capture_output=True, text=True).stdout.strip()
site = os.environ["MI_IN"] if moved else os.environ["MI_FROM_SSH"]
def app(name, url, res, sync="Synced", health="Healthy", revision=""):
    return {"metadata": {"name": name}, "spec": {"source": {"repoURL": url}},
            "status": {"sync": {"status": sync, "revision": revision}, "health": {"status": health},
                       "resources": [{"group": g, "kind": k, "namespace": "ns", "name": n} for g, k, n in res]}}
ai_res = [("apps", "Deployment", "a"), ("", "Service", "b")]
if moved and mode == "prune":
    ai_res = ai_res[:1]
ai_sync = "OutOfSync" if mode == "unsettled" else "Synced"
print(json.dumps({"items": [
    app("tockmox-root", site, [("argoproj.io", "Application", "tockmox-ai")], revision=rev),
    app("tockmox-ai", site if moved else os.environ["MI_FROM"], ai_res, sync=ai_sync),
    app("charts", "https://github.com/tockmox/tockmox.git", [("", "ConfigMap", "c")]),
]}))
PY
# bootstrap-forge's stand-in: record the arguments, then push --site's main to the forge as the real
# one does (a main the forge holds must be an ancestor), and mark the forge installed.
cat > "$MI_BIN/bootstrap-forge.sh" <<'BF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MI_STATE/bf-args"
site=""; while [[ $# -gt 0 ]]; do [[ "$1" == --site ]] && site="$2"; shift; done
cur="$(git --git-dir "$MI_FORGE" rev-parse -q --verify refs/heads/main || true)"
if [[ -n "$cur" ]] && ! git -C "$site" merge-base --is-ancestor "$cur" HEAD 2>/dev/null; then
  git -C "$site" fetch -q "$MI_FORGE" main 2>/dev/null || true
  git -C "$site" merge-base --is-ancestor "$cur" HEAD || { echo "stand-in: not an ancestor" >&2; exit 1; }
fi
git -C "$site" push -q "$MI_FORGE" HEAD:refs/heads/main || exit 1
touch "$MI_STATE/forge-installed"
BF
MI_STATUS=0

# mi_start NAME MODE: the stand-in forge (its repository emptied: no forge yet), a site checkout
# whose files name the site repository in both spellings and one other repository, and Argo CD
# synced to the checkout. Sets D, DP_PORT, MI_SITE.
mi_git() { PATH="$DP_PATH" git "$@"; }
mi_start() {
  dp_start "$1"
  local F="$D/root/tockmox/site.git"
  rm -rf "$F"; mi_git init -q --bare -b main "$F"; mi_git -C "$F" config http.receivepack true
  MI_SITE="$D/mysite"
  mi_git init -q -b main "$MI_SITE"
  mkdir -p "$MI_SITE/bootstrap/applications" "$MI_SITE/site/values" "$MI_SITE/.github/workflows"
  printf 'kind: Application\nmetadata:\n  name: tockmox-root\nspec:\n  source:\n    repoURL: %s\n    path: bootstrap/applications\n' "$MI_FROM_SSH" > "$MI_SITE/bootstrap/root.yaml"
  printf 'spec:\n  sources:\n    - repoURL: https://github.com/tockmox/tockmox.git\n      targetRevision: v0.9.0\n    - repoURL: "%s"   # values\n      ref: values\n' "$MI_FROM" > "$MI_SITE/bootstrap/applications/tockmox-identity.yaml"
  printf 'spec:\n  source:\n    repoURL: %s\n' "${MI_FROM%.git}" > "$MI_SITE/bootstrap/applications/tockmox-observability.yaml"
  printf 'global:\n  internalDomain: lab.example.invalid\n  localStorageClass: local-path\nother: 1\n' > "$MI_SITE/site/values/global.yaml"
  printf 'sso:\n  enabled: true\n  apps:\n    ntfy:\n      enabled: true\nauthentik: {}\n' > "$MI_SITE/site/values/identity.yaml"
  printf 'alerts: {}\n' > "$MI_SITE/site/values/observability.yaml"
  printf 'on: push   # git clone %s\n' "$MI_FROM" > "$MI_SITE/.github/workflows/lint.yml"
  mi_git -C "$MI_SITE" add -A
  mi_git -C "$MI_SITE" -c user.name=t -c user.email=t@example.invalid commit -q -m "first"
  echo 'b: 1' >> "$MI_SITE/site/values/observability.yaml"
  mi_git -C "$MI_SITE" -c user.name=t -c user.email=t@example.invalid commit -qam "second"
  mkdir -p "$D/state"; : > "$D/state/calls.log"
  cp "$MI_BIN/apps.py" "$D/state/apps.py"
  printf '%s\n' "$2" > "$D/state/mi-mode"
  mi_git -C "$MI_SITE" rev-parse HEAD > "$D/state/rev"
  printf 'pusher\ntok\n' > "$D/creds"; mkdir -p "$D/tmp"
}
mi_run() {
  set +e
  env PATH="$MI_BIN:$DP_PATH" MI_STATE="$D/state" MI_PORT="$DP_PORT" MI_FORGE="$D/root/tockmox/site.git" \
    MI_IN="$MI_IN" MI_FROM="$MI_FROM" MI_FROM_SSH="$MI_FROM_SSH" NO_COLOR=1 TOCKMOX_TEST_ALLOW_HTTP=1 \
    TOCKMOX_TEST_BOOTSTRAP_FORGE="$MI_BIN/bootstrap-forge.sh" TOCKMOX_TEST_POLL_S=0 \
    TMPDIR="$D/tmp" bash "$INSTALLER" move-in-forge "$@" >"$D/out/stdout" 2>"$D/out/stderr" </dev/null
  MI_STATUS=$?
  set -e
}
MI_OK=(--context lab --yes-context lab --yes-server https://lab.example.invalid:6443)
mi_writes() { grep -cE '^kubectl .*(apply|delete)' "$D/state/calls.log" || true; }
mi_forge() { PATH="$DP_PATH" git --git-dir "$D/root/tockmox/site.git" "$@"; }

path_begin "MI1" "move-in-forge refuses before it writes anything: no context, a dirty checkout, Argo CD reading another repository or another revision, an unsettled Application"
mi_start i1 settle
mi_run --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds"
assert_artifact "no --context is refused" \
  "echo $MI_STATUS; grep -c 'never falls back to the current context' '$D/out/stderr'" "$(printf '1\n1')"
echo dirty > "$MI_SITE/untracked.txt"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds"
assert_artifact "an untracked file in the checkout is refused, naming it, and nothing is written" \
  "echo $MI_STATUS; grep -c 'untracked.txt' '$D/out/stderr'; mi_writes; test -e '$D/state/bf-args' && echo ran || echo not-run" \
  "$(printf '1\n1\n0\nnot-run')"
rm "$MI_SITE/untracked.txt"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "https://example.invalid/someone-else/site.git" --from-credentials "$D/creds"
assert_artifact "Argo CD not reading --from is refused, and nothing is written" \
  "echo $MI_STATUS; grep -c 'not --from' '$D/out/stderr'; mi_writes" "$(printf '1\n1\n0')"
printf '%s\n' 0000000000000000000000000000000000000000 > "$D/state/rev"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds"
assert_artifact "a checkout that is not the revision Argo CD is synced to is refused" \
  "echo $MI_STATUS; grep -c 'Pull (or push) so your checkout is exactly what Argo CD reads' '$D/out/stderr'; mi_writes" "$(printf '1\n1\n0')"
mi_git -C "$MI_SITE" rev-parse HEAD > "$D/state/rev"; echo unsettled > "$D/state/mi-mode"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds"
assert_artifact "an Application that is not Synced and Healthy is refused, naming it and the way to accept it" \
  "echo $MI_STATUS; grep -c 'tockmox-ai is OutOfSync/Healthy' '$D/out/stderr'; grep -c -- '--accept-unsettled' '$D/out/stderr'; mi_writes" \
  "$(printf '1\n1\n1\n0')"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" --dry-run --accept-unsettled tockmox-ai
assert_artifact "named with --accept-unsettled, a dry run gets past it, shows the commit, and writes nothing" \
  "echo $MI_STATUS; grep -c 'Dry run: nothing was changed' '$D/out/stdout'; mi_writes; mi_forge rev-parse -q --verify main || echo no-main" \
  "$(printf '0\n1\n0\nno-main')"
dp_stop

path_begin "MI2" "a move: the site's history plus ONE migration commit in the forge, every repoURL to the site rewritten, the built-in values on, the root cut over, nothing pruned"
mi_start i2 settle
BEFORE_HEAD="$(mi_git -C "$MI_SITE" rev-parse HEAD)"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "it succeeds and says every Application reads the forge with nothing pruned" \
  "echo $MI_STATUS; grep -c 'nothing was pruned' '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "the forge's main is the site's history plus exactly one commit" \
  "mi_forge rev-list --count main; mi_forge rev-parse main~1; mi_forge log -1 --format=%s main" \
  "$(printf '3\n%s\nMove the site repository into the built-in forge' "$BEFORE_HEAD")"
assert_artifact "every repoURL to the site, in either spelling, quoted or not, now names the forge; the charts repository and the workflow do not change" \
  "mi_forge show main:bootstrap/root.yaml | grep -c '    repoURL: $MI_IN'; mi_forge show main:bootstrap/applications/tockmox-identity.yaml | grep -c 'repoURL: $MI_IN   # values'; mi_forge show main:bootstrap/applications/tockmox-identity.yaml | grep -c 'repoURL: https://github.com/tockmox/tockmox.git'; mi_forge show main:bootstrap/applications/tockmox-observability.yaml | grep -c 'repoURL: $MI_IN'; mi_forge show main:.github/workflows/lint.yml | grep -c '$MI_FROM'" \
  "$(printf '1\n1\n1\n1\n1')"
assert_artifact "the built-in values: global.siteForge, sso.apps.forge beside the existing app, siteForge in observability" \
  "mi_forge show main:site/values/global.yaml | sed -n 2p; mi_forge show main:site/values/identity.yaml | sed -n '4,5p'; mi_forge show main:site/values/identity.yaml | grep -c '    ntfy:'; mi_forge show main:site/values/observability.yaml | grep -A1 '^siteForge:' | tail -1" \
  "$(printf '  siteForge: built-in   # the site repository is in the built-in forge (move-in-forge)\n    forge:\n      enabled: true\n1\n  enabled: true')"
assert_artifact "bootstrap-forge got the migrated tree, the confirmed context, the credential replacement, --from as the off-site copy, and the options after --" \
  "grep -c -- '--replace-argocd-credential' '$D/state/bf-args'; grep -A1 -- '--offsite-git$' '$D/state/bf-args' | tail -1; grep -A1 -- '--yes-server' '$D/state/bf-args' | tail -1; grep -c 'age1test' '$D/state/bf-args'" \
  "$(printf '1\n%s\nhttps://lab.example.invalid:6443\n1' "$MI_FROM")"
assert_artifact "a copy of Argo CD's credential for the old repository was written, then removed after the check" \
  "grep -c '\"name\": \"tockmox-site-repo-before-move\"' '$D/state/applied-0'; grep -c 'sshPrivateKey' '$D/state/applied-0'; grep -c 'delete secret tockmox-site-repo-before-move' '$D/state/calls.log'" \
  "$(printf '1\n1\n1')"
assert_artifact "the root Application applied is the forge's, and the checkout was not changed" \
  "grep -c '$MI_IN' '$D/state/root-applied.yaml'; mi_git -C '$MI_SITE' rev-parse HEAD; mi_git -C '$MI_SITE' status --porcelain | wc -l | tr -d ' '" \
  "$(printf '1\n%s\n0' "$BEFORE_HEAD")"
: > "$D/state/calls.log"; echo moved > "$D/state/mi-mode"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit2" --age-recipient age1test
assert_artifact "a re-run after the move is a no-op: nothing applied, deleted or pushed" \
  "echo $MI_STATUS; grep -c 'Nothing to do' '$D/out/stdout'; mi_writes; mi_forge rev-list --count main" "$(printf '0\n1\n0\n3')"
dp_stop

path_begin "MI3" "a cutover that does not settle stops with the way back, keeps the credential copy, and a re-run carries on from the forge with the SAME commit"
mi_start i3 stuck
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" --wait-seconds 0 -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "it fails, names what is wrong, prints the command back to the checkout's root, and keeps the copy" \
  "echo $MI_STATUS; grep -c 'tockmox-ai still reads the old repository' '$D/out/stderr'; grep -c 'kubectl --context lab apply -f $MI_SITE/bootstrap/root.yaml' '$D/out/stdout'; grep -c 'delete secret' '$D/state/calls.log' || true" \
  "$(printf '1\n1\n1\n0')"
FIRST="$(mi_forge rev-parse main)"
rm -f "$D/state/root-applied.yaml"; echo settle > "$D/state/mi-mode"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit2" --age-recipient age1test
assert_artifact "the re-run finds this move in the forge, makes no new commit, and finishes" \
  "echo $MI_STATUS; grep -c 'the forge already holds this move' '$D/out/stdout'; mi_forge rev-parse main; mi_forge rev-list --count main" \
  "$(printf '0\n1\n%s\n3' "$FIRST")"
dp_stop

path_begin "MI4" "a cutover that loses a resource is not called done"
mi_start i4 prune
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" --wait-seconds 0 -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "it fails and names the Application and the resource it no longer manages" \
  "echo $MI_STATUS; grep -c 'tockmox-ai no longer manages 1 resource(s), e.g. Service/ns/b' '$D/out/stderr'" "$(printf '1\n1')"
dp_stop

path_begin "MI5" "a built-in forge that already holds another site's history is refused before anything is written"
mi_start i5 settle
( cd "$D" && mi_git clone -q "$D/root/tockmox/site.git" other 2>/dev/null; cd other && echo x > x && mi_git add x \
  && mi_git -c user.name=t -c user.email=t@example.invalid commit -qm other && mi_git push -q origin HEAD:main )
touch "$D/state/forge-installed"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "it refuses, says the forge holds other history, and writes nothing" \
  "echo $MI_STATUS; grep -c 'already holds other history' '$D/out/stderr'; mi_writes; test -e '$D/state/bf-args' && echo ran || echo not-run" \
  "$(printf '1\n1\n0\nnot-run')"
dp_stop

path_begin "MI6" "options that are this command's own are refused after --, and the off-site copy needs its credential or --no-offsite-copy"
mi_start i6 settle
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --site /elsewhere
assert_artifact "--site after -- is refused" "echo $MI_STATUS; grep -c -- \"--site is this command's to set\" '$D/out/stderr'" "$(printf '1\n1')"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM"
assert_artifact "no --from-credentials and no --no-offsite-copy is refused" \
  "echo $MI_STATUS; grep -c -- '--from-credentials FILE is required' '$D/out/stderr'" "$(printf '1\n1')"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --no-offsite-copy -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "with --no-offsite-copy, bootstrap-forge is not told to mirror to --from" \
  "echo $MI_STATUS; grep -c -- '--offsite-git' '$D/state/bf-args' || true" "$(printf '0\n0')"
dp_stop

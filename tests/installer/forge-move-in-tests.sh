#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh after forge-move-tests.sh, whose stand-in it uses (dp_start, dp_stop,
# lib/forge-stub.py). Groups MI1-MI11: install/forge-move-in.sh, reached as
# `tockmox-install.sh move-in-forge`.
#
# HERMETIC, and git is REAL: the site checkout, the forge's repository and the old
# repository (bare repositories the stand-in serves over HTTP, and in MI7 over HTTPS with a
# certificate from a CA made for the case) and the migration commit are real commits. A kubectl of
# this file's own plays Argo CD (its Applications before and after the cutover, switched
# by the file mi-mode), the repository Secrets, the forge's admin Secret and the applies; a
# stand-in bootstrap-forge records what it was given and pushes the migrated tree to the
# forge's repository the way the real one does (refusing history that is not an ancestor).
# What the stand-ins do not prove is that a real Argo CD settles: the lab run does.
# Every assertion reads what the move LEFT: the forge's refs and files, what was applied
# and deleted, what bootstrap-forge was given, the checkout it must not have changed.

# The old repository, which the move reads before it writes anything: mi_start serves it from the
# stand-in as me/site.git and sets these two spellings of it.
MI_FROM=""
MI_FROM_SSH=""
MI_IN="$RS_URL"   # the built-in forge's in-cluster address, as forge-restore-tests.sh names it
MI_BIN="$WORK/forge-move-in-bin"; mkdir -p "$MI_BIN"
cat > "$MI_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$MI_STATE/calls.log"
a=" $* "
case "$a" in
  *" exec "*) exec python3 "$MI_STATE/worker.py" exec ;;
  *" -n tockmox-authentik get pods -o json "*) exec python3 "$MI_STATE/worker.py" pods ;;
  *" -n tockmox-authentik get configmap tockmox-sso-blueprints -o json "*) exec python3 "$MI_STATE/worker.py" configmap ;;
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
# the site repository at the checkout's revision. After: per mi-mode (settle, stuck, prune; and
# for the two-read settle, flip: clean once, then tockmox-ai Progressing; flicker: Progressing on
# the second read only; moved-flip: already moved, clean once, then Progressing). Each read after
# the move is counted in after-reads. Once the off-site pass has run (the stand-in bootstrap-forge
# leaves offsite-ran), each read is also counted in offsite-reads: offsite-flip reads tockmox-ai
# Progressing on the first two of them, then Healthy; offsite-stuck reads it Progressing on all.
cat > "$MI_BIN/apps.py" <<'PY'
import json, os, subprocess
st = os.environ["MI_STATE"]
mode = open(os.path.join(st, "mi-mode")).read().strip()
moved = mode.startswith("moved") or (os.path.exists(os.path.join(st, "root-applied.yaml")) and mode != "stuck")
reads = 0
if moved:
    p = os.path.join(st, "after-reads")
    reads = (int(open(p).read().strip()) if os.path.exists(p) else 0) + 1
    open(p, "w").write("%d\n" % reads)
post = 0
if moved and os.path.exists(os.path.join(st, "offsite-ran")):
    p = os.path.join(st, "offsite-reads")
    post = (int(open(p).read().strip()) if os.path.exists(p) else 0) + 1
    open(p, "w").write("%d\n" % post)
ai_health = "Healthy"
if moved and ((mode in ("flip", "moved-flip") and reads >= 2) or (mode == "flicker" and reads == 2)):
    ai_health = "Progressing"
if (mode == "offsite-flip" and 1 <= post <= 2) or (mode == "offsite-stuck" and post >= 1):
    ai_health = "Progressing"
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
# tockmox-identity reads the charts and, as its values, the site repository (two sources, so Argo CD reports
# status.sync.revisions). stale-rev: Synced and Healthy, but still at the site's old head for the first two reads
# after the move; stale-rev-stuck and moved-stale: at it on every read.
id_rev = rev
old_head = open(os.path.join(st, "rev")).read().strip()
if moved and ((mode == "stale-rev" and reads <= 2) or mode in ("stale-rev-stuck", "moved-stale")):
    id_rev = old_head
ident = app("tockmox-identity", "", [("apps", "Deployment", "tockmox-identity-authentik-worker")])
ident["spec"] = {"sources": [{"repoURL": "https://github.com/tockmox/tockmox.git"}, {"repoURL": site if moved else os.environ["MI_FROM"], "ref": "values"}],
                 "destination": {"namespace": "tockmox-authentik"}}
ident["status"]["sync"]["revisions"] = ["c0ffee0000000000000000000000000000000000", id_rev]
print(json.dumps({"items": [
    app("tockmox-root", site, [("argoproj.io", "Application", "tockmox-ai")], revision=rev),
    app("tockmox-ai", site if moved else os.environ["MI_FROM"], ai_res, sync=ai_sync, health=ai_health, revision=rev),
    ident,
    app("charts", "https://github.com/tockmox/tockmox.git", [("", "ConfigMap", "c")]),
]}))
PY
# The identity layer's Authentik worker, as the kubectl above reports it: its pod, the blueprint ConfigMap it
# mounts, and what `kubectl exec` reads in it. The migration commit changes the blueprints (v1 before the move,
# v2 after). worker-mode (default current) says when the worker holds and runs on v2, counted in worker-reads
# (one per exec after the move): current, at once; pending, kubelet has not projected v2 on reads 1-2, the worker
# holds v2 but started on v1 (the probe's restart is still to come) on reads 3-4, runs on v2 from read 5;
# restart-stuck, holds v2 but started on v1 on every read; late-sync, Argo CD syncs v2 between the first read and
# the second, which still holds v1. `worker.py state` prints that, counting nothing.
cat > "$MI_BIN/worker.py" <<'PY'
import hashlib, json, os, sys
st = os.environ["MI_STATE"]
def rd(n, d=""):
    p = os.path.join(st, n)
    return open(p).read().strip() if os.path.exists(p) else d
mode = rd("mi-mode"); wmode = rd("worker-mode", "current")
moved = mode.startswith("moved") or (os.path.exists(os.path.join(st, "root-applied.yaml")) and mode != "stuck")
V1 = {"ntfy.yaml": "ntfy: 1\n"}
V2 = {"ntfy.yaml": "ntfy: 1\n", "forge.yaml": "forge: 1\n"}
DIR = "/blueprints/mounted/cm-tockmox-sso-blueprints"
def phase(n):  # (what the volume holds, what the worker started on)
    if not moved: return V1, V1
    if wmode == "restart-stuck": return V2, V1
    if wmode == "late-sync": return V1, V1
    if wmode == "pending": return (V1, V1) if n <= 2 else (V2, V1) if n <= 4 else (V2, V2)
    return V2, V2
def cat(files): return hashlib.sha256("".join(files[k] for k in sorted(files)).encode()).hexdigest()
reads = int(rd("worker-reads", "0"))
def current(): return V1 if not moved or (wmode == "late-sync" and reads == 0) else V2
cmd = sys.argv[1]
if cmd == "exec":
    if moved:
        reads += 1; open(os.path.join(st, "worker-reads"), "w").write("%d\n" % reads)
    held, began = phase(reads)
    for k in sorted(held):
        print("F %s %s/%s" % (hashlib.sha256(held[k].encode()).hexdigest(), DIR, k))
    print("START " + cat(began)); print("NOW " + cat(held))
elif cmd == "configmap":
    print(json.dumps({"metadata": {"name": "tockmox-sso-blueprints"}, "data": current()}))
elif cmd == "pods":
    vol = {"name": "blueprints-cm-tockmox-sso-blueprints", "configMap": {"name": "tockmox-sso-blueprints"}}
    print(json.dumps({"items": [
        {"metadata": {"name": "tockmox-identity-authentik-worker-0"}, "status": {"phase": "Running"},
         "spec": {"volumes": [vol], "containers": [{"name": "worker", "volumeMounts": [{"name": vol["name"], "mountPath": DIR}]}]}},
        {"metadata": {"name": "tockmox-identity-authentik-server-0"}, "status": {"phase": "Running"},
         "spec": {"volumes": [], "containers": [{"name": "server"}]}}]}))
elif cmd == "state":
    held, began = phase(reads)
    print("does not hold the current blueprints" if held != current() else
          "a restart is still to come" if held != began else "runs on the current blueprints")
PY
# bootstrap-forge's stand-in: record the arguments, then push --site's main to the forge as the real
# one does (a main the forge holds must be an ancestor), and mark the forge installed. A run with
# --offsite-git leaves offsite-ran: the real one upgrades the forge and connects its sign-in then,
# which can set an Application syncing again after the cutover check.
cat > "$MI_BIN/bootstrap-forge.sh" <<'BF'
#!/usr/bin/env bash
n=$(ls "$MI_STATE"/bf-args-* 2>/dev/null | wc -l | tr -d ' '); printf '%s\n' "$@" > "$MI_STATE/bf-args-$n"
site=""; while [[ $# -gt 0 ]]; do [[ "$1" == --site ]] && site="$2"; [[ "$1" == --offsite-git ]] && touch "$MI_STATE/offsite-ran"; shift; done
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
  MI_FROM="http://127.0.0.1:${DP_PORT}/me/site.git"; MI_FROM_SSH="git@127.0.0.1:me/site.git"
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
  mkdir -p "$D/root/me"; mi_git clone -q --bare "$MI_SITE" "$D/root/me/site.git"
  mkdir -p "$D/state"; : > "$D/state/calls.log"
  cp "$MI_BIN/apps.py" "$D/state/apps.py"; cp "$MI_BIN/worker.py" "$D/state/worker.py"
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
  "echo $MI_STATUS; grep -c 'untracked.txt' '$D/out/stderr'; mi_writes; ls '$D/state' | grep -c '^bf-args-' || true" \
  "$(printf '1\n1\n0\n0')"
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
assert_artifact "the first bootstrap-forge run got the migrated tree, the confirmed context, the credential replacement and the options after --, and NOT the off-site copy" \
  "grep -c -- '--replace-argocd-credential' '$D/state/bf-args-0'; grep -A1 -- '--yes-server' '$D/state/bf-args-0' | tail -1; grep -A1 -- '--kit-out' '$D/state/bf-args-0' | tail -1; grep -c -- '--offsite-git' '$D/state/bf-args-0' || true" \
  "$(printf '1\nhttps://lab.example.invalid:6443\n%s\n0' "$D/kit")"
assert_artifact "only after the check, a second run made --from the off-site copy, with its kit in a scratch file, not over yours" \
  "ls '$D/state' | grep -c '^bf-args-'; grep -A1 -- '--offsite-git$' '$D/state/bf-args-1' | tail -1; grep -A1 -- '--kit-out' '$D/state/bf-args-1' | tail -1 | grep -c 'second-run-kit'" \
  "$(printf '2\n%s\n1' "$MI_FROM")"
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
assert_artifact "and --from was never offered to the forge as a mirror: one bootstrap-forge run, without --offsite-git" \
  "ls '$D/state' | grep -c '^bf-args-'; grep -c -- '--offsite-git' '$D/state/bf-args-0' || true" "$(printf '1\n0')"
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
  "echo $MI_STATUS; grep -c 'already holds other history' '$D/out/stderr'; mi_writes; ls '$D/state' | grep -c '^bf-args-' || true" \
  "$(printf '1\n1\n0\n0')"
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
  "echo $MI_STATUS; ls '$D/state' | grep -c '^bf-args-'; grep -c -- '--offsite-git' '$D/state/bf-args-0' || true" "$(printf '0\n1\n0')"
dp_stop

# mi_tls_start: a CA made for the case, a certificate it signs for 127.0.0.1, another CA that signed
# nothing here, and a second stand-in serving the same repositories over HTTPS with that certificate.
# Sets MI_TLS_PORT and MI_TLS_PID.
mi_tls_start() {
  local C="$D/ca"; mkdir -p "$C"
  ( cd "$C" \
    && openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj "/CN=move-in test CA" \
    && openssl req -x509 -newkey rsa:2048 -nodes -keyout other.key -out other.crt -days 2 -subj "/CN=another CA" \
    && openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=127.0.0.1" \
    && printf 'subjectAltName=IP:127.0.0.1\n' > srv.ext \
    && openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out srv.crt -days 2 -extfile srv.ext ) >/dev/null 2>&1
  rm -f "$D/tls-port"
  env PATH="$DP_PATH" TLS_CERT="$C/srv.crt" TLS_KEY="$C/srv.key" python3 "$DP_STUB" "$D/root" "$D/tls-port" >/dev/null 2>&1 &
  MI_TLS_PID=$!
  local i=0
  while [ ! -s "$D/tls-port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  MI_TLS_PORT="$(cat "$D/tls-port" 2>/dev/null || true)"
}

path_begin "MI7" "an old repository behind a private CA: refused before anything is written unless --from-ca names the CA; with it, read, moved, and made the off-site copy with bootstrap-forge's --offsite-git-ca"
mi_start i7 settle
mi_tls_start
MI_FROM_TLS="https://127.0.0.1:${MI_TLS_PORT}/me/site.git"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM_TLS" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "without --from-ca the certificate is not verified, the refusal names --from-ca, and nothing is written" \
  "echo $MI_STATUS; grep -c 'cannot verify the certificate of 127.0.0.1:' '$D/out/stderr'; grep -c 'give that CA as --from-ca FILE' '$D/out/stderr'; mi_writes; ls '$D/state' | grep -c '^bf-args-' || true" \
  "$(printf '1\n1\n1\n0\n0')"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM_TLS" --from-credentials "$D/creds" --from-ca "$D/ca/other.crt" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a --from-ca that did not sign the certificate is refused as such, and nothing is written" \
  "echo $MI_STATUS; grep -c -- '--from-ca $D/ca/other.crt does not verify the certificate' '$D/out/stderr'; mi_writes; ls '$D/state' | grep -c '^bf-args-' || true" \
  "$(printf '1\n1\n0\n0')"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM_TLS" --from-credentials "$D/creds" -- --offsite-git-ca "$D/ca/ca.crt" --kit-out "$D/kit" --age-recipient age1test
assert_artifact "--offsite-git-ca after -- is refused, pointing at --from-ca" \
  "echo $MI_STATUS; grep -c -- 'as --from-ca FILE, before --' '$D/out/stderr'; mi_writes" "$(printf '1\n1\n0')"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM_TLS" --no-offsite-copy --from-ca "$D/ca/ca.crt" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "--from-ca with --no-offsite-copy is refused: the command never connects to --from then" \
  "echo $MI_STATUS; grep -c -- '--from-ca goes with --from-credentials' '$D/out/stderr'; mi_writes" "$(printf '1\n1\n0')"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM_TLS" --from-credentials "$D/creds" --from-ca "$D/ca/ca.crt" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "with --from-ca the old repository is read through its certificate and the move completes" \
  "echo $MI_STATUS; grep -c 'its certificate verifies against $D/ca/ca.crt' '$D/out/stdout'; grep -c 'nothing was pruned' '$D/out/stdout'; mi_forge rev-list --count main" \
  "$(printf '0\n1\n1\n3')"
assert_artifact "the CA goes to the off-site run alone, as bootstrap-forge's --offsite-git-ca beside --offsite-git --from" \
  "grep -c -- '--offsite-git-ca' '$D/state/bf-args-0' || true; grep -A1 -- '--offsite-git$' '$D/state/bf-args-1' | tail -1; grep -A1 -- '--offsite-git-ca' '$D/state/bf-args-1' | tail -1" \
  "$(printf '0\n%s\n%s' "$MI_FROM_TLS" "$D/ca/ca.crt")"
kill "$MI_TLS_PID" 2>/dev/null || true; wait "$MI_TLS_PID" 2>/dev/null || true
dp_stop

# mi_bf_flags DIR ... bootstrap-forge's own site_flag and its two calls for the approvers watcher, taken from the real
# install/bootstrap-forge.sh, run on DIR as bootstrap-forge runs them on the tree it publishes. Prints how many calls
# it found (two, or the extraction is broken and the case below proves nothing).
MI_BF_REAL="$REPO_ROOT/install/bootstrap-forge.sh"
# shellcheck disable=SC2016  # "$SITE" is bootstrap-forge's own text, matched literally
mi_bf_flags() {
  local f="$D/bf-flags.sh"
  { echo 'set -u'; sed -n '/^site_flag() {/,/^}/p' "$MI_BF_REAL"
    grep -E '^  if site_flag "\$SITE/site/values/(observability|identity)\.yaml"' "$MI_BF_REAL" \
      | sed -E 's/^  if (site_flag .*); then$/\1 || true/'
  } > "$f"
  grep -c '^site_flag "\$SITE' "$f"
  SITE="$1" bash "$f" >/dev/null 2>&1 || true
}

path_begin "MI8" "the approvers watcher's two switches ride the migration commit when bootstrap-forge will connect sign-in, so the forge's main is ONE commit on the site's history and bootstrap-forge has nothing of its own to commit; not with --no-sign-in; an operator's value is left alone"
mi_start i8 settle
BEFORE_HEAD="$(mi_git -C "$MI_SITE" rev-parse HEAD)"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "the move succeeds, and the forge's main is the site's history plus exactly one commit" \
  "echo $MI_STATUS; mi_forge rev-list --count main; mi_forge rev-parse main~1" "$(printf '0\n3\n%s' "$BEFORE_HEAD")"
assert_artifact "the migration commit turns the watcher on under sso.apps.forge and under siteForge, after each enabled: true" \
  "mi_forge show main:site/values/identity.yaml | grep -A2 '^    forge:'; mi_forge show main:site/values/observability.yaml | grep -A2 '^siteForge:'" \
  "$(printf '    forge:\n      enabled: true\n      approverWatch: true\nsiteForge:\n  enabled: true\n  approverWatch: true')"
assert_artifact "it says so" "grep -c 'approverWatch: true (bootstrap-forge installs the approvers watcher)' '$D/out/stdout'" "2"
rm -rf "$D/check"; mi_git clone -q "$D/root/tockmox/site.git" "$D/check"
assert_artifact "bootstrap-forge's own site_flag (both calls, read from install/bootstrap-forge.sh) finds nothing to add on the forge's main, so it makes no commit of its own" \
  "mi_bf_flags '$D/check'; mi_git -C '$D/check' status --porcelain | wc -l | tr -d ' '" "$(printf '2\n0')"
rm -rf "$D/check2"; mi_git clone -q "$D/root/tockmox/site.git" "$D/check2"
sed -i '/approverWatch/d' "$D/check2/site/values/identity.yaml" "$D/check2/site/values/observability.yaml"
mi_git -C "$D/check2" -c user.name=t -c user.email=t@example.invalid commit -qam "without the switches"
assert_artifact "the same check goes red on a tree without the two switches: bootstrap-forge would change both files, its second commit" \
  "mi_bf_flags '$D/check2'; mi_git -C '$D/check2' status --porcelain | wc -l | tr -d ' '" "$(printf '2\n2')"
dp_stop
mi_start i8b settle
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --no-sign-in --kit-out "$D/kit" --age-recipient age1test
assert_artifact "with --no-sign-in after --, bootstrap-forge installs no watcher, and the migration commit adds neither switch" \
  "echo $MI_STATUS; mi_forge show main:site/values/identity.yaml | grep -c approverWatch || true; mi_forge show main:site/values/observability.yaml | grep -c approverWatch || true" \
  "$(printf '0\n0\n0')"
dp_stop
mi_start i8c settle
printf 'sso:\n  enabled: true\n  apps:\n    forge:\n      enabled: true\n      approverWatch: false\n' > "$MI_SITE/site/values/identity.yaml"
mi_git -C "$MI_SITE" -c user.name=t -c user.email=t@example.invalid commit -qam "the operator turned the watcher off"
mi_git -C "$MI_SITE" push -q "$D/root/me/site.git" main
mi_git -C "$MI_SITE" rev-parse HEAD > "$D/state/rev"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "an approverWatch the operator already set is theirs: left as it is, and said so" \
  "echo $MI_STATUS; mi_forge show main:site/values/identity.yaml | grep -c approverWatch; mi_forge show main:site/values/identity.yaml | grep approverWatch; grep -c 'left as it is: sso.apps.forge.approverWatch' '$D/out/stdout'" \
  "$(printf '0\n1\n      approverWatch: false\n1')"
dp_stop

path_begin "MI9" "settled means two clean reads in a row: an Application that reads Progressing after one clean read keeps the move from declaring success, and the re-run from saying Nothing to do"
mi_start i9 flip
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" --wait-seconds 0 -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "clean once, then Progressing: past the deadline the first clean read is still confirmed, and the move fails naming what flipped, without its success line" \
  "echo $MI_STATUS; cat '$D/state/after-reads'; grep -c 'tockmox-ai is Synced/Progressing' '$D/out/stderr'; grep -c 'nothing was pruned' '$D/out/stdout' || true" \
  "$(printf '1\n2\n1\n0')"
assert_artifact "and so it keeps the credential copy and never offers --from to the forge as a mirror" \
  "grep -c 'delete secret' '$D/state/calls.log' || true; ls '$D/state' | grep -c '^bf-args-'" "$(printf '0\n1')"
dp_stop
mi_start i9b flicker
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "clean, Progressing, clean, clean: the Progressing read starts the count again, and the cutover settles on the fourth read (two more for the last check)" \
  "echo $MI_STATUS; cat '$D/state/after-reads'; grep -c 'nothing was pruned' '$D/out/stdout'" "$(printf '0\n6\n1')"
dp_stop
mi_start i9c settle
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a cutover that settles at once is still read twice, and twice again after the off-site pass, before it is called done, and says so" \
  "echo $MI_STATUS; cat '$D/state/after-reads'; grep -c 'settled means two clean reads in a row' '$D/out/stdout'; grep -c 'Checking every Application again, after the last change' '$D/out/stdout'" "$(printf '0\n4\n1\n1')"
dp_stop
mi_start i9d moved-flip
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a re-run that reads every Application clean once and then Progressing refuses, writes nothing, and does not say Nothing to do" \
  "echo $MI_STATUS; cat '$D/state/after-reads'; grep -c 'not every Application is settled' '$D/out/stderr'; grep -c 'tockmox-ai is Synced/Progressing' '$D/out/stderr'; grep -c 'Nothing to do' '$D/out/stdout' || true; mi_writes" \
  "$(printf '1\n2\n1\n1\n0\n0')"
dp_stop
mi_start i9e moved
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a re-run that reads every Application clean twice says Nothing to do and writes nothing" \
  "echo $MI_STATUS; cat '$D/state/after-reads'; grep -c 'read twice 0s apart. Nothing to do' '$D/out/stdout'; mi_writes" "$(printf '0\n2\n1\n0')"
dp_stop

# mi_read_ai: one read of Argo CD, as whatever reads it right after the move does (P16's next row): tockmox-ai's sync/health.
mi_read_ai() {
  env MI_STATE="$D/state" MI_FORGE="$D/root/tockmox/site.git" MI_IN="$MI_IN" MI_FROM="$MI_FROM" MI_FROM_SSH="$MI_FROM_SSH" \
    python3 "$D/state/apps.py" \
    | python3 -c 'import json,sys; a={x["metadata"]["name"]: x["status"] for x in json.load(sys.stdin)["items"]}["tockmox-ai"]; print(a["sync"]["status"] + "/" + a["health"]["status"])'
}
# mi_line TEXT: the number of the first stdout line holding TEXT (0 when none does).
mi_line() { grep -n -F -- "$1" "$D/out/stdout" | head -1 | cut -d: -f1 | grep . || echo 0; }
# mi_order A B C: "ordered" when A's line is after B's and B's after C's (each present), else the three numbers.
mi_order() {
  local a b c; a="$(mi_line "$1")"; b="$(mi_line "$2")"; c="$(mi_line "$3")"
  if [ "$c" -gt 0 ] && [ "$b" -gt "$c" ] && [ "$a" -gt "$b" ]; then echo ordered; else echo "$a $b $c"; fi
}

path_begin "MI10" "the move's last check runs after the off-site pass (bootstrap-forge again, which can set an Application syncing again), and the success line only after it: whatever reads Argo CD next reads it settled, and the re-run says Nothing to do"
mi_start i10 offsite-flip
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "an Application the off-site pass sets Progressing is waited on: two Progressing reads, then two clean, then the success line" \
  "echo $MI_STATUS; ls '$D/state' | grep -c '^bf-args-'; cat '$D/state/offsite-reads' 2>/dev/null || echo 0; grep -c 'nothing was pruned' '$D/out/stdout' || true" \
  "$(printf '0\n2\n4\n1')"
assert_artifact "the success line comes after the off-site pass and after the last check's heading" \
  "mi_order 'nothing was pruned' 'Checking every Application again, after the last change' 'the off-site copy (bootstrap-forge again'" "ordered"
assert_artifact "the first read after the move, as P16 makes it, finds every Application Synced and Healthy" \
  "mi_read_ai" "Synced/Healthy"
: > "$D/state/calls.log"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit2" --age-recipient age1test
assert_artifact "and the re-run reads every Application clean twice, says Nothing to do, exits 0 and writes nothing" \
  "echo $MI_STATUS; grep -c 'Nothing to do' '$D/out/stdout' || true; mi_writes" "$(printf '0\n1\n0')"
dp_stop
mi_start i10b offsite-stuck
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" --wait-seconds 0 -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "an Application the off-site pass leaves Progressing fails the last check: exit 1, named, no success line, the re-run named as the way on" \
  "echo $MI_STATUS; ls '$D/state' | grep -c '^bf-args-'; grep -c 'not every Application settled again' '$D/out/stderr' || true; grep -c 'tockmox-ai is Synced/Progressing' '$D/out/stderr' || true; grep -c 'nothing was pruned' '$D/out/stdout' || true; grep -c 'run this command again' '$D/out/stdout' || true" \
  "$(printf '1\n2\n1\n1\n0\n1')"
dp_stop
mi_start i10c settle
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --no-offsite-copy -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "with --no-offsite-copy the last check still runs, after the credential copy is removed, and the success line follows it" \
  "echo $MI_STATUS; cat '$D/state/after-reads'; mi_order 'nothing was pruned' 'Checking every Application again, after the last change' 'tockmox-site-repo-before-move removed'" \
  "$(printf '0\n4\nordered')"
dp_stop

# mi_worker: what the identity layer's Authentik worker runs on right now, as the stand-in reports it (counts nothing).
mi_worker() { env MI_STATE="$D/state" python3 "$D/state/worker.py" state; }

path_begin "MI11" "settled is about the forge's main and the cluster as it will stay: an Application synced to an older revision is not settled, and neither is an Authentik worker that has yet to restart onto the blueprints the migration commit changed (Argo CD reads it Synced and Healthy until the restart comes); the move's checks and the re-run share that one predicate"
mi_start i11 settle
echo pending > "$D/state/worker-mode"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a worker that does not hold the new blueprints yet, then holds them without having restarted, is waited on: the move succeeds only once it runs on them, so the next reader finds no restart to come" \
  "echo $MI_STATUS; cat '$D/state/worker-reads' 2>/dev/null || echo 0; mi_worker; grep -c 'nothing was pruned' '$D/out/stdout' || true" \
  "$(printf '0\n8\nruns on the current blueprints\n1')"
dp_stop
mi_start i11b settle
echo restart-stuck > "$D/state/worker-mode"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" --wait-seconds 0 -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a worker that never restarts onto the blueprints it holds keeps the cutover from settling: exit 1, the worker named, no success line, no off-site pass" \
  "echo $MI_STATUS; grep -c 'tockmox-identity: the Authentik worker tockmox-identity-authentik-worker-0 has not restarted onto the blueprints it now holds' '$D/out/stderr' || true; grep -c 'nothing was pruned' '$D/out/stdout' || true; ls '$D/state' | grep -c '^bf-args-'" \
  "$(printf '1\n1\n0\n1')"
dp_stop
mi_start i11c moved
echo restart-stuck > "$D/state/worker-mode"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a re-run reads the worker the same way: Argo CD clean, the worker's restart still to come, so it refuses, names the worker, writes nothing, and does not say Nothing to do" \
  "echo $MI_STATUS; grep -c 'not every Application is settled' '$D/out/stderr' || true; grep -c 'has not restarted onto the blueprints it now holds' '$D/out/stderr' || true; grep -c 'Nothing to do' '$D/out/stdout' || true; mi_writes" \
  "$(printf '1\n1\n1\n0\n0')"
dp_stop
mi_start i11c2 moved
echo late-sync > "$D/state/worker-mode"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "the re-run's second read is the same predicate as its first: a blueprint change synced between them, not yet in the worker's volume, makes it refuse" \
  "echo $MI_STATUS; cat '$D/state/worker-reads'; grep -c 'does not hold the current blueprints yet' '$D/out/stderr' || true; grep -c 'Nothing to do' '$D/out/stdout' || true; mi_writes" \
  "$(printf '1\n2\n1\n0\n0')"
dp_stop
mi_start i11d stale-rev
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "an Application that reads Synced and Healthy at the site's old head is not counted: two such reads, then two at the forge's main, then the last check's two" \
  "echo $MI_STATUS; cat '$D/state/after-reads'; grep -c 'nothing was pruned' '$D/out/stdout' || true" "$(printf '0\n6\n1')"
dp_stop
mi_start i11e stale-rev-stuck
OLD_HEAD="$(cut -c1-12 "$D/state/rev")"
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" --wait-seconds 0 -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "one that stays at the old head fails the cutover check, naming it and the revision it is at" \
  "echo $MI_STATUS; grep -c \"tockmox-identity is synced to ${OLD_HEAD}, not the forge's main\" '$D/out/stderr' || true; grep -c 'nothing was pruned' '$D/out/stdout' || true" \
  "$(printf '1\n1\n0')"
dp_stop
mi_start i11f moved-stale
mi_run "${MI_OK[@]}" --site "$MI_SITE" --from "$MI_FROM" --from-credentials "$D/creds" -- --kit-out "$D/kit" --age-recipient age1test
assert_artifact "a re-run that finds an Application at an older revision than the root refuses, names it, writes nothing" \
  "echo $MI_STATUS; grep -c \"tockmox-identity is synced to $(cut -c1-12 "$D/state/rev"), not the forge's main\" '$D/out/stderr' || true; grep -c 'Nothing to do' '$D/out/stdout' || true; mi_writes" \
  "$(printf '1\n1\n0\n0')"
dp_stop

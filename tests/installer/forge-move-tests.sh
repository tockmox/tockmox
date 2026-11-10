#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh after forge-dump-tests.sh, whose stand-in it uses (dp_start, dp_stop,
# lib/forge-stub.py). Groups M1-M10: install/forge-move.sh, reached as
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

# ---- In the cluster (--in-cluster): the console's Job runs this same script. No context and no
# port-forward: the forge at --forge-url (the stand-in here; outside the tests only its Service
# address), kubectl as the pod's ServiceAccount (the stub), one "STEP n ok|fail|wait" line per step.
fm_ic() { fm_run --in-cluster --forge-url "http://127.0.0.1:$DP_PORT" --to "$FM_TO" --credentials "$D/creds" "$@"; }
# A site whose bootstrap/root.yaml is the one root Application, as a real site's is.
fm_root_app() {
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: tockmox-root\n  namespace: argocd\nspec:\n  source:\n    repoURL: %s\n' "$FM_IN" > "$D/fmwork/bootstrap/root.yaml"
  fm_git -C "$D/fmwork" -c user.name=t -c user.email=t@example.invalid commit -q -am "the root is an Application"
  fm_git -C "$D/fmwork" push -q origin main
}

path_begin "M6" "in the cluster: no --context, only the forge's Service address, and the console's check before anything moves"
fm_start m6
fm_ic --context lab
assert_artifact "--in-cluster with --context is refused" \
  "echo $FM_STATUS; grep -c 'takes no --context' '$D/out/stderr'" "$(printf '1\n1')"
fm_run --in-cluster --forge-url "http://forge.example.org:3000" --to "$FM_TO" --credentials "$D/creds"
assert_artifact "a forge address that is not a cluster Service is refused" \
  "echo $FM_STATUS; grep -c \"must be the forge's in-cluster Service address\" '$D/out/stderr'" "$(printf '1\n1')"
fm_ic --dry-run
assert_artifact "the check says what would move and what the change rewrites, and moves nothing" \
  "echo $FM_STATUS; grep -c '^STEP 1 ok ' '$D/out/stdout'; grep -E '^CHECK ' '$D/out/stdout' | sed 's/ main=[0-9a-f]*//'; fm_target for-each-ref | wc -l | tr -d ' '; ls '$D/state' | grep -c applied || true" \
  "$(printf '0\n1\nCHECK branches=2 tags=1 files=2\n0\n0')"
fm_git -C "$D/fmwork" push -q "$D/root/remote/site.git" main
fm_ic --dry-run
assert_artifact "a target that is not empty is refused at step 1, with a STEP fail line" \
  "echo $FM_STATUS; grep -c '^STEP 1 fail .*is not empty' '$D/out/stdout'" "$(printf '1\n1')"
dp_stop

path_begin "M7" "in the cluster: steps 1 to 4, a wait that is not a failure, then Finish moves it"
fm_start m7
fm_root_app
echo wait > "$D/root/move-mode"
fm_ic --requested-by alice --approval-wait-minutes 0
assert_artifact "it exits 0 with steps 1 to 4 ok and step 5 waiting" \
  "echo $FM_STATUS; grep -E '^STEP [0-9] (ok|wait) ' '$D/out/stdout' | cut -d' ' -f2,3 | tr '\n' ' '" \
  "$(printf '0\n1 ok 2 ok 3 ok 4 ok 5 wait ')"
assert_artifact "the change carries who asked for it, in its commit and its description" \
  "fm_forge log -1 --format=%B move-to-own-forge | grep -c '^Tockmox-Requested-By: alice\$'; grep -c 'Tockmox-Requested-By: alice' '$D/root/moves/101.json'" \
  "$(printf '1\n1')"
echo merge > "$D/root/move-mode"
fm_ic --finish --approval-wait-minutes 1
assert_artifact "Finish: step 5 ok, the root re-applied from the target, the forge archived" \
  "echo $FM_STATUS; grep -c '^STEP 5 ok ' '$D/out/stdout'; grep -c 'name: tockmox-root' '$D/state/root-applied.yaml'; cat '$D/root/archived'; echo" \
  "$(printf '0\n1\n1\ntrue')"
dp_stop

path_begin "M8" "in the cluster: a root that is not the one root Application is not applied, and nothing is archived"
fm_start m8 MOVE=merge
fm_ic --approval-wait-minutes 1
assert_artifact "step 5 fails before kubectl is asked, and the forge stays unarchived" \
  "echo $FM_STATUS; grep -c '^STEP 5 fail .*not the one root Application' '$D/out/stdout'; [ -e '$D/state/root-applied.yaml' ] && echo APPLIED || echo not-applied; [ -e '$D/root/archived' ] && echo ARCHIVED || echo not-archived" \
  "$(printf '1\n1\nnot-applied\nnot-archived')"
dp_stop

path_begin "M9" "in the cluster: the console's fixed Job reads what to do from a request file, and refuses a request it cannot trust"
fm_start m9
fm_root_app
fm_rq() { printf '%s\n' "$@" > "$D/request"; fm_run --in-cluster --forge-url "http://127.0.0.1:$DP_PORT" --request "$D/request" --credentials "$D/creds" --approval-wait-minutes 0; }
fm_rq "to=$FM_TO" "mode=check" "requested-by=alice"
assert_artifact "mode=check is the dry run: the CHECK line, and the target stays empty" \
  "echo $FM_STATUS; grep -c '^CHECK ' '$D/out/stdout'; fm_target for-each-ref | wc -l | tr -d ' '" "$(printf '0\n1\n0')"
fm_rq "to=$FM_TO" "mode=check" "token=x"
assert_artifact "an unknown key is refused" \
  "echo $FM_STATUS; grep -c \"unknown key: 'token'\" '$D/out/stderr'" "$(printf '1\n1')"
fm_rq "to=$FM_TO" "mode=check" "mode=move"
assert_artifact "a repeated key is refused" \
  "echo $FM_STATUS; grep -c 'malformed or repeated line' '$D/out/stderr'" "$(printf '1\n1')"
fm_rq "to=$FM_TO" "mode=everything"
assert_artifact "a mode other than check, move or finish is refused" \
  "echo $FM_STATUS; grep -c 'mode must be check, move or finish' '$D/out/stderr'" "$(printf '1\n1')"
fm_rq "to=https://u:p@git.example.org/acme/site.git" "mode=check"
assert_artifact "a target with credentials in it is refused, as on the command line" \
  "echo $FM_STATUS; grep -c 'no credentials in it' '$D/out/stderr'" "$(printf '1\n1')"
fm_rq "to=$FM_TO" "mode=move" "requested-by=al ice"
assert_artifact "a requested-by that is not a sign-in name is refused" \
  "echo $FM_STATUS; grep -c 'must be a sign-in name' '$D/out/stderr'; fm_target for-each-ref | wc -l | tr -d ' '" "$(printf '1\n1\n0')"
printf 'to=%s\nmode=check\n' "$FM_TO" > "$D/request"
fm_run --in-cluster --forge-url "http://127.0.0.1:$DP_PORT" --request "$D/request" --to "$FM_TO" --credentials "$D/creds"
assert_artifact "a request file AND --to on the command line is refused" \
  "echo $FM_STATUS; grep -c 'do not pass them as options too' '$D/out/stderr'" "$(printf '1\n1')"
fm_run --context lab --request "$D/request" --credentials "$D/creds"
assert_artifact "a request file outside the cluster is refused" \
  "echo $FM_STATUS; grep -c -- '--request goes with --in-cluster' '$D/out/stderr'" "$(printf '1\n1')"
echo wait > "$D/root/move-mode"
fm_rq "to=$FM_TO" "mode=move" "requested-by=alice"
assert_artifact "mode=move runs steps 1 to 4 and waits, carrying who asked" \
  "echo $FM_STATUS; grep -E '^STEP [0-9] (ok|wait) ' '$D/out/stdout' | cut -d' ' -f2,3 | tr '\n' ' '; echo; fm_forge log -1 --format=%B move-to-own-forge | grep -c '^Tockmox-Requested-By: alice\$'" \
  "$(printf '0\n1 ok 2 ok 3 ok 4 ok 5 wait \n1')"
echo merge > "$D/root/move-mode"
fm_rq "to=$FM_TO" "mode=finish" "requested-by=bob"
assert_artifact "mode=finish completes it: step 5 ok and the forge archived" \
  "echo $FM_STATUS; grep -c '^STEP 5 ok ' '$D/out/stdout'; cat '$D/root/archived'; echo" "$(printf '0\n1\ntrue')"
dp_stop

path_begin "M10" "the console's move template: a suspended CronJob with a fixed pod spec, and a grant no wider than the move"
FMT="$WORK/forge-move-template"; mkdir -p "$FMT"
bash "$REPO_ROOT/install/forge-move-template.sh" --namespace tockmox-forge --argocd-namespace argocd \
  --image "$(sed -n 's/^MOVE_IMAGE_DEFAULT="\([^"]*\)"$/\1/p' "$REPO_ROOT/install/bootstrap-forge.sh")" > "$FMT/t.yaml"
fmt_q() { python3 - "$FMT/t.yaml" "$1" <<'PY'
import sys, yaml
docs = {(d["kind"], d["metadata"]["namespace"]): d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
cj = docs[("CronJob", "tockmox-forge")]
pod = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
c = pod["containers"][0]
q = sys.argv[2]
if q == "cron":
    print(cj["metadata"]["name"], cj["spec"]["suspend"], cj["spec"]["schedule"], pod["serviceAccountName"],
          cj["spec"]["jobTemplate"]["spec"]["ttlSecondsAfterFinished"])
elif q == "pod":
    print(" ".join(c["command"]))
    print(" ".join(c["args"]))
    print(sorted(v["name"] + ":" + (v.get("secret", {}).get("secretName") or v.get("configMap", {}).get("name") or "tmp") for v in pod["volumes"]))
    print(len(pod["containers"]), "initContainers" in pod, c["securityContext"]["readOnlyRootFilesystem"], [e["name"] for e in c["env"]])
elif q == "grant":
    for ns in ("tockmox-forge", "argocd"):
        for r in docs[("Role", ns)]["rules"]:
            print(ns, ",".join(r["apiGroups"]) or "core", ",".join(r["resources"]), ",".join(r.get("resourceNames", ["*"])), ",".join(r["verbs"]))
    for ns in ("tockmox-forge", "argocd"):
        b = docs[("RoleBinding", ns)]
        print(ns, b["roleRef"]["name"], [(s["name"], s["namespace"]) for s in b["subjects"]])
elif q == "image":
    print(c["image"])
PY
}
assert_artifact "a template only: suspended, a schedule that never comes, its own ServiceAccount, gone 10 minutes after it finishes" \
  "fmt_q cron" "tockmox-forge-move True 0 0 31 2 * tockmox-forge-move 600"
assert_artifact "the pod spec is fixed: the script from its ConfigMap, the run's request and credentials from one Secret" \
  "fmt_q pod" "$(printf '%s\n' 'bash /opt/move/forge-move.sh' \
    '--in-cluster --namespace tockmox-forge --argocd-namespace argocd --request /run/move/request --credentials /run/move/push --read-credentials /run/move/read --approval-wait-minutes 0' \
    "['request:tockmox-forge-move-request', 'script:tockmox-forge-move-script', 'tmp:tmp']" \
    "1 False True ['HOME', 'NO_COLOR']")"
assert_artifact "the grant: the forge's admin Secret, Argo CD's one repository Secret (create cannot be named), the one root Application" \
  "fmt_q grant" "$(printf '%s\n' \
    'tockmox-forge core secrets tockmox-forge-admin get' \
    'argocd core secrets tockmox-site-repo-own get,patch' \
    'argocd core secrets * create' \
    'argocd argoproj.io applications tockmox-root get,patch' \
    "tockmox-forge tockmox-forge-move [('tockmox-forge-move', 'tockmox-forge')]" \
    "argocd tockmox-forge-move [('tockmox-forge-move', 'tockmox-forge')]")"
assert_artifact "the Job's image is the one the console's admission policy admits (the chart's moveForge.image default)" \
  "fmt_q image; sed -n 's/.*moveForge.*default \"\\(alpine\\/k8s:[^\"]*\\)\".*/\\1/p' '$REPO_ROOT/charts/tockmox-ai/templates/_actions.tpl' | head -1" \
  "$(fmt_q image; fmt_q image)"
set +e; bash "$REPO_ROOT/install/forge-move-template.sh" --namespace 'Bad NS' --argocd-namespace argocd --image x:1 >/dev/null 2>"$FMT/err"; FMT_RC=$?; set -e
assert_artifact "a name that is not a Kubernetes name is refused" "echo $FMT_RC; grep -c 'not a Kubernetes name' '$FMT/err'" "$(printf '2\n1')"

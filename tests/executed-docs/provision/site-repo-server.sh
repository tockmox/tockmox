#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Serve a site repository (and optionally the product repository) from INSIDE
# the cluster under test, over a ClusterIP, with no credential.
#
#   site-repo-server.sh up                  start the daemon, empty
#   site-repo-server.sh push DIR NAME       publish DIR as git://.../NAME.git
#   site-repo-server.sh url NAME            print the URL to put in an Application
#   site-repo-server.sh down                remove everything it created
#
# WHY THIS EXISTS, and it is the whole reason A5 was blocked.
#
# `install/tockmox-install.sh` generates a site repository and stops. It writes
# PLACEHOLDER_SITE_REPO_URL into bootstrap/root.yaml and
# bootstrap/applications/*.yaml, because ArgoCD reads the site's values over git
# and only the operator knows where that repo lives. So an executed test of the
# installer needs a git repository the cluster can reach ... which the inventory
# recorded for weeks as "a site repository and a repository credential", i.e.
# design work.
#
# There is no credential to design. Serve the repo from a pod in the same
# cluster: nothing leaves the cluster, nothing authenticates, nothing is stored,
# and the whole thing dies with the throwaway. A credential that does not exist
# cannot expire, leak, or need rotating ... which is a better answer than any
# scheme for managing one.
#
# TWO REPOSITORIES, and the second one surprises people.
#
# The generated Applications are MULTI-SOURCE: source 1 is the PRODUCT repo
# (charts), source 2 is the SITE repo (values). Publishing only the site repo
# gets you eleven Applications that all fail with
#
#   ComparisonError: failed to list refs: authentication required: Repository not found.
#
# ... naming source 1, because `https://github.com/tockmox/tockmox.git` is
# PRIVATE until the public flip. Measured 2026-09-02. That error says
# "authentication required" and a reader will reasonably go looking for a
# credential to supply; there isn't one to supply, the repo simply is not
# readable yet. So the harness publishes the working tree as the product source
# too, which has the side benefit of testing THIS TREE rather than a published
# tag.
#
# WHAT SERVING THE WORKING TREE COSTS, stated rather than discovered: a run
# using it proves nothing about the published tag's contents or reachability.
# Any inventory row built on this must say which of the two it tested.
#
# TRAP, measured: `alpine/git` does NOT ship git-daemon ("git: 'daemon' is not a
# git command"), and the container then exits, and with no volume the restart
# loses the repository and sits waiting for a seed file that will never come
# again. Hence alpine + an explicit `apk add git-daemon`, and an emptyDir.

set -euo pipefail
# TM-0797: every kubectl call below names its cluster with --context from this
# variable; an empty value is refused rather than falling back to the current context.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

NS="${TOCKMOX_HARNESS_NAMESPACE:-tockmox-harness}"
POD=site-git
SVC=site-git
PORT=9418
IMAGE="${TOCKMOX_GIT_IMAGE:-alpine:3.20}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "REFUSING: '$1' is not on PATH" >&2; exit 2; }; }

url_for() { printf 'git://%s.%s.svc.cluster.local/%s.git' "$SVC" "$NS" "$1"; }

cmd_up() {
  need kubectl
  need git
  kubectl --context="$KUBE_CONTEXT" create namespace "$NS" --dry-run=client -o yaml | kubectl --context="$KUBE_CONTEXT" apply -f - >/dev/null
  cat <<YAML | kubectl --context="$KUBE_CONTEXT" apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
  labels: {tockmox.com/harness: executed-docs}
spec:
  selector: {app: ${SVC}}
  ports: [{name: git, port: ${PORT}, targetPort: ${PORT}}]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels: {app: ${SVC}, tockmox.com/harness: executed-docs}
spec:
  volumes:
    - name: repos
      emptyDir: {}
  containers:
    - name: git
      image: ${IMAGE}
      command: ["sh","-c"]
      args:
        - |
          apk add --no-cache git git-daemon >/dev/null
          mkdir -p /repos
          while [ ! -f /repos/.seeded ]; do sleep 2; done
          exec git daemon --verbose --export-all --base-path=/repos \\
            --reuseaddr --informative-errors --listen=0.0.0.0 --port=${PORT} /repos
      ports: [{containerPort: ${PORT}}]
      volumeMounts: [{name: repos, mountPath: /repos}]
YAML
  echo "waiting for ${NS}/${POD}..." >&2
  kubectl --context="$KUBE_CONTEXT" -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=180s >/dev/null
  # Pod-Ready is NOT the readiness that matters here, and the difference is a
  # race that fires as an unrelated-looking error. The container's command is
  # `apk add git git-daemon` followed by the serve loop, so the pod reports
  # Ready the instant the container STARTS ... while apk is still fetching. A
  # `push` issued in that window dies with
  #
  #   sh: git: not found            (exit 127)
  #
  # which reads as a broken image rather than "called too early". Measured
  # 2026-09-04. Wait for the binary, not for the pod: the thing to probe is the
  # capability the next command uses.
  local deadline; deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # PROBE THE SUBCOMMAND, NOT A BINARY ON PATH. The serve loop below runs
    # `git daemon`, and git resolves its subcommands out of its own exec-path
    # (/usr/libexec/git-core), not out of PATH. `command -v git-daemon` therefore
    # returns 127 even when the git-daemon package is fully installed, and this
    # loop then times out with "git never appeared in it" against a container
    # that is perfectly ready. Measured 2026-09-12 on alpine with
    # git-daemon-2.45.4-r0 installed and /usr/libexec/git-core/git-daemon
    # present. That is this function's own rule ... probe the capability the
    # next command uses ... violated one line under the comment stating it.
    if kubectl --context="$KUBE_CONTEXT" -n "$NS" exec "$POD" -- sh -c 'command -v git >/dev/null && [ -x "$(git --exec-path)/git-daemon" ]' >/dev/null 2>&1; then
      echo "  ${NS}/${POD} ready (daemon starts on first push)" >&2
      return 0
    fi
    sleep 3
  done
  echo "REFUSING: ${NS}/${POD} came up but git never appeared in it." >&2
  kubectl --context="$KUBE_CONTEXT" -n "$NS" logs "$POD" --tail=20 >&2 || true
  exit 1
}

# push DIR NAME [REF] ... publish a working directory as a bare repo the cluster
# serves. With no REF the repo is (re)created with DIR as `main`. With a REF the
# repo is KEPT and DIR is added as the tag `refs/tags/REF` on top of whatever
# it already serves ... which is how one served repository carries two
# revisions, so an Application can be pointed at `v0.5.0` and then moved to
# `v0.6.0-rc2` by changing one line, exactly as docs/deployment/upgrade.md says
# an operator does. Added 2026-09-06 for TM-0281: without it the only way to
# "upgrade" on the harness was to change repoURL as well, which is not the
# documented path and tests something the operator never does.
cmd_push() {
  need kubectl
  need git
  local dir="$1" name="$2" ref="${3:-}"
  [ -d "$dir" ] || { echo "REFUSING: no such directory: $dir" >&2; exit 2; }
  if [ -n "$ref" ]; then
    case "$ref" in
      main|HEAD|*/*|*' '*) echo "REFUSING: REF must be a plain tag name, not '${ref}'" >&2; exit 2 ;;
    esac
  fi
  local tgz
  tgz="$(mktemp "${TMPDIR:-/tmp}/tockmox-repo.XXXXXX").tgz"
  # A working tree, not a clone: this deliberately publishes what is ON DISK,
  # including uncommitted edits, because that is what a harness run is testing.
  ( cd "$dir" && tar czf "$tgz" --exclude=.git . )
  kubectl --context="$KUBE_CONTEXT" -n "$NS" cp "$tgz" "${POD}:/tmp/${name}.tgz" >/dev/null
  rm -f "$tgz"
  kubectl --context="$KUBE_CONTEXT" -n "$NS" exec "$POD" -- sh -c "
    set -e
    git config --global --add safe.directory '*'
    git config --global init.defaultBranch main
    git config --global user.email harness@example.com
    git config --global user.name harness
    rm -rf /tmp/w-${name}
    mkdir -p /tmp/w-${name} && cd /tmp/w-${name} && tar xzf /tmp/${name}.tgz
    git init -q . && git add -A && git commit -qm 'harness snapshot ${ref:-main}'
    if [ -z '${ref}' ]; then
      rm -rf /repos/${name}.git && git init -q --bare /repos/${name}.git
      git push -q /repos/${name}.git main
      git --git-dir=/repos/${name}.git symbolic-ref HEAD refs/heads/main
    else
      [ -d /repos/${name}.git ] || git init -q --bare /repos/${name}.git
      git tag -a '${ref}' -m 'harness snapshot ${ref}'
      git push -q -f /repos/${name}.git 'refs/tags/${ref}:refs/tags/${ref}'
      git --git-dir=/repos/${name}.git rev-parse --verify -q 'refs/heads/main' >/dev/null \
        || { git push -q /repos/${name}.git main; git --git-dir=/repos/${name}.git symbolic-ref HEAD refs/heads/main; }
    fi
    touch /repos/.seeded
  " >/dev/null
  # Assert on the artefact, not on the exit code: prove the daemon actually
  # serves it, from inside the cluster, before telling a caller to point an
  # Application at it. A repo that exists and is unservable is the failure this
  # whole file exists to avoid.
  kubectl --context="$KUBE_CONTEXT" -n "$NS" delete pod "gitprobe-${name}" --ignore-not-found >/dev/null 2>&1 || true
  local probe="git clone -q $(url_for "$name") /tmp/c && test -n \"\$(ls -A /tmp/c)\""
  [ -n "$ref" ] && probe="git clone -q --branch '${ref}' $(url_for "$name") /tmp/c && test -n \"\$(ls -A /tmp/c)\""
  if ! kubectl --context="$KUBE_CONTEXT" -n "$NS" run "gitprobe-${name}" --rm -i --restart=Never \
        --image=alpine/git:latest --command -- \
        sh -c "$probe" >/dev/null 2>&1; then
    echo "REFUSING: ${name}.git${ref:+ at ${ref}} was created but a pod in this cluster could not clone it." >&2
    kubectl --context="$KUBE_CONTEXT" -n "$NS" logs "$POD" --tail=20 >&2 || true
    exit 1
  fi
  echo "  published and clone-verified: $(url_for "$name")${ref:+ @ ${ref}}" >&2
  url_for "$name"
}

cmd_down() {
  need kubectl
  kubectl --context="$KUBE_CONTEXT" -n "$NS" delete pod -l tockmox.com/harness=executed-docs --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context="$KUBE_CONTEXT" -n "$NS" delete svc "$SVC" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context="$KUBE_CONTEXT" delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "  ${NS} removed" >&2
}

case "${1:-}" in
  up)   cmd_up ;;
  push) shift; [ $# -eq 2 ] || [ $# -eq 3 ] || { echo "usage: $0 push DIR NAME [REF]" >&2; exit 2; }; cmd_push "$1" "$2" "${3:-}" ;;
  url)  shift; [ $# -eq 1 ] || { echo "usage: $0 url NAME" >&2; exit 2; }; url_for "$1"; echo ;;
  down) cmd_down ;;
  *) echo "usage: $0 {up|push DIR NAME|url NAME|down}" >&2; exit 2 ;;
esac

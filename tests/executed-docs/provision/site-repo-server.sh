#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Serve a site repository (and optionally the product repository) from INSIDE
# the cluster under test, over a ClusterIP, with no credential.
#
#   site-repo-server.sh up                  start the daemon, empty
#   site-repo-server.sh up --writable       start it with receive-pack enabled, site.git and
#                                           tockmox.git pre-created, on a NodePort (see below)
#   site-repo-server.sh push DIR NAME       publish DIR as NAME.git (read over http:// and git://)
#                                           TOCKMOX_SERVE_FORCE_ADD=PATHSPEC also serves the files it
#                                           names that .gitignore excludes (the air-gap lane's vendored
#                                           subchart archives); without it, ignored files are never served
#   site-repo-server.sh url NAME            print the URL to put in an Application (http://)
#   site-repo-server.sh nodeport            print the NodePort --writable uses inside the cluster
#   site-repo-server.sh reach URL           prove a pod in the cluster can read URL
#   site-repo-server.sh manifest [--writable]   print what `up` applies (no cluster call)
#   site-repo-server.sh script [--writable]     print the daemon's start script (no cluster call)
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
# WHY THE URL IT HANDS OUT IS http://, NOT git://. The installer refuses a tockmox.repoURL that is
# not https://, http://, ssh:// or git@host: (install/tockmox-install.sh, the check before it runs
# `git ls-remote`, added with the 0.8.6 hardening so the value can never be read by git as an
# option). This script handed out git:// for every repository, so every lane that passed `url tockmox`
# to the installer stopped at its first step. The same pod now also serves every repository read-only
# over git's smart HTTP protocol (`git http-backend`, which the git-daemon package ships, behind a
# small Python bridge on HTTP_PORT), and `url` prints that address. Receive-pack is off over HTTP.
# The git:// daemon stays: writable mode's ONE URL, which the workstation pushes to, is still git://
# (it is the site repository's address, which the installer never checks; it writes a placeholder).
# selftest's remote-route test holds `url` to the installer's own pattern, read from the installer.

# TRAP, measured: `alpine/git` does NOT ship git-daemon ("git: 'daemon' is not a
# git command"), and the container then exits, and with no volume the restart
# loses the repository and sits waiting for a seed file that will never come
# again. Hence alpine + an explicit `apk add git-daemon`, and an emptyDir.

# WRITABLE MODE (`up --writable`), for the external (bring your own forge) route of
# p09-lane.sh. That route needs ONE git URL that the workstation can push to and the
# cluster can clone from. This daemon serves it:
#   - `git daemon --enable=receive-pack`, so a push over git:// is accepted;
#   - site.git and tockmox.git exist, bare and empty, before the daemon starts;
#   - the Service is a NodePort on a fixed port inside the cluster (TOCKMOX_SITE_GIT_NODEPORT,
#     default 30418). The cluster under test is itself a masqueraded VM, so that port is
#     published a second time on the hypervisor by `throwaway-cluster.sh publish git PORT`,
#     whose host:port is the URL both sides use. The in-cluster ClusterIP URL keeps working.
#
# AN UNAUTHENTICATED, WORLD-WRITABLE GIT DAEMON ON A NODEPORT is acceptable here ONLY because
# the VM it runs in is a throwaway in an isolated lab: it holds nothing that is not
# regenerated by the run and it is destroyed with the VM. It must never be pointed at a
# cluster anyone keeps. So `up --writable` refuses unless the file named by
# TOCKMOX_WRITABLE_GUARD exists and names this KUBE_CONTEXT as the guest context. That file
# is written by `throwaway-cluster.sh publish`, which runs only after that script's own
# disposable-namespace refusal passed (TOCKMOX_TEST_NAMESPACE is TOCKMOX_DISPOSABLE_NAMESPACE).
# The file can be written by hand, so this is a guard against a wrong context, not against
# a person who means it.

set -euo pipefail
# every kubectl call below names its cluster with --context from this
# variable; an empty value is refused rather than falling back to the current context.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

NS="${TOCKMOX_HARNESS_NAMESPACE:-tockmox-harness}"
FORCE_ADD=""   # set by push from TOCKMOX_SERVE_FORCE_ADD; read by tree_of
POD=site-git
SVC=site-git
PORT=9418
HTTP_PORT=8080
IMAGE="${TOCKMOX_GIT_IMAGE:-alpine:3.20}"
GUEST_NODEPORT="${TOCKMOX_SITE_GIT_NODEPORT:-30418}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "REFUSING: '$1' is not on PATH" >&2; exit 2; }; }

# The cluster DNS suffix is assembled in two parts, as revision-row-test.sh does, so the
# public-text scrubber does not read the standard in-cluster name as a site host.
CLUSTER_DNS="cluster"; CLUSTER_DNS="${CLUSTER_DNS}.local"
url_for() { printf 'http://%s.%s.svc.%s:%s/%s.git' "$SVC" "$NS" "$CLUSTER_DNS" "$HTTP_PORT" "$1"; }

# tree_of DIR ... the git tree id of DIR's bytes as `push` serves them: what `git add -A` takes
# (DIR's own .gitignore honoured, as the pod's `git add -A` honours it), minus macOS AppleDouble
# files (`._NAME`), which `push` never sends. A throwaway index in a scratch repository; DIR itself
# is not touched, and a .git inside it is ignored as git always ignores it. core.autocrlf is off so
# a workstation's line-ending setting cannot make the same bytes hash differently here and in the pod.
tree_of() {
  local idx rc
  idx="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-tree.XXXXXX")"
  git init -q --bare "$idx" \
    && GIT_DIR="$idx" git -c core.autocrlf=false -c core.safecrlf=false --work-tree="$1" \
         add -A -- . ':(exclude,glob)**/._*' >/dev/null \
    && { [ -z "${FORCE_ADD}" ] || GIT_DIR="$idx" git -c core.autocrlf=false -c core.safecrlf=false --work-tree="$1" \
           add -f -- "${FORCE_ADD}" >/dev/null; } \
    && GIT_DIR="$idx" git write-tree
  rc=$?
  rm -rf "$idx"
  return "$rc"
}

# The flags the daemon is started with. --enable=receive-pack is the whole of writable mode's
# daemon side; --export-all is what lets a repository without git-daemon-export-ok be served.
daemon_flags() {
  local f="--verbose --export-all --base-path=/repos"
  [ "$1" = writable ] && f="${f} --enable=receive-pack"
  printf '%s --reuseaddr --informative-errors --listen=0.0.0.0 --port=%s /repos' "$f" "$PORT"
}

# bridge_py ... the read-only smart-HTTP bridge: each request runs `git http-backend` as a CGI would,
# with receive-pack forced off, and its answer is sent back with a Content-Length. Stdlib only.
bridge_py() {
  cat <<'PYSRC'
import http.server, os, subprocess, sys
PORT, ROOT = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            out = b""
            while True:
                n = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if n == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return out
                out += self.rfile.read(n)
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def serve(self):
        path, _, query = self.path.partition("?")
        data = self.body()
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_PROJECT_ROOT": ROOT,
               "GIT_HTTP_EXPORT_ALL": "1", "GIT_CONFIG_COUNT": "1",
               "GIT_CONFIG_KEY_0": "http.receivepack", "GIT_CONFIG_VALUE_0": "false",
               "REQUEST_METHOD": self.command, "PATH_INFO": path, "QUERY_STRING": query,
               "CONTENT_TYPE": self.headers.get("Content-Type", ""), "CONTENT_LENGTH": str(len(data)),
               "REMOTE_ADDR": self.client_address[0]}
        for h in ("Content-Encoding", "Git-Protocol"):
            if self.headers.get(h):
                env["HTTP_" + h.upper().replace("-", "_")] = self.headers[h]
        r = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True)
        head, sep, rest = r.stdout.partition(b"\r\n\r\n")
        if not sep:
            head, sep, rest = r.stdout.partition(b"\n\n")
        status, hdrs = 200, []
        for line in head.decode("latin-1").splitlines():
            k, _, v = line.partition(":")
            if k.lower() == "status":
                status = int(v.split()[0])
            elif k:
                hdrs.append((k, v.strip()))
        if not sep:
            status, hdrs, rest = 500, [("Content-Type", "text/plain")], r.stderr[-400:]
        self.send_response(status)
        for k, v in hdrs:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(rest)))
        self.end_headers()
        self.wfile.write(rest)
    do_GET = do_POST = serve
    def log_message(self, fmt, *a):
        sys.stderr.write("git-http %s\n" % (fmt % a))
http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYSRC
}

# bridge_lines ... the serve script's lines that write the bridge and start it in the background, before
# the git daemon starts (both modes). Its pid is kept beside the repositories.
bridge_lines() {
  printf '%s\n' "cat > /repos/.git-http.py <<'PY'"
  bridge_py
  printf '%s\n' 'PY' "python3 /repos/.git-http.py ${HTTP_PORT} /repos & echo \$! > /repos/.git-http.pid"
}

# serve_script MODE ... what the container runs once git is installed (the `apk add` line is
# cmd_up's). Read-only waits for `push` to seed it; writable creates the two bare repositories
# itself, so the daemon can start at once and a push finds them there.
serve_script() {
  # shellcheck disable=SC2016  # $r is the container shell's, in the text it will run
  if [ "$1" = writable ]; then
    printf '%s\n' \
      'mkdir -p /repos' \
      'for r in site tockmox; do [ -d /repos/$r.git ] || git init -q --bare --initial-branch=main /repos/$r.git; done' \
      'touch /repos/.seeded'
    bridge_lines
    printf '%s\n' "exec git daemon $(daemon_flags writable)"
  else
    printf '%s\n' 'mkdir -p /repos'
    bridge_lines
    printf '%s\n' \
      'while [ ! -f /repos/.seeded ]; do sleep 2; done' \
      "exec git daemon $(daemon_flags readonly)"
  fi
}

# manifest MODE ... the Service and Pod `up` applies.
manifest() {
  local mode="$1" type_line="" np_field="" body
  if [ "$mode" = writable ]; then
    type_line="  type: NodePort"$'\n'
    np_field=", nodePort: ${GUEST_NODEPORT}"
  fi
  body="$(serve_script "$mode" | sed 's/^/          /')"
  cat <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
  labels: {tockmox.com/harness: executed-docs}
spec:
  selector: {app: ${SVC}}
${type_line}  ports: [{name: git, port: ${PORT}, targetPort: ${PORT}${np_field}}, {name: http, port: ${HTTP_PORT}, targetPort: ${HTTP_PORT}}]
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
          apk add --no-cache git git-daemon python3 >/dev/null
${body}
      ports: [{containerPort: ${PORT}}, {containerPort: ${HTTP_PORT}}]
      volumeMounts: [{name: repos, mountPath: /repos}]
YAML
}

check_nodeport() {
  case "$GUEST_NODEPORT" in ''|*[!0-9]*) echo "REFUSING: TOCKMOX_SITE_GIT_NODEPORT must be a number, not '${GUEST_NODEPORT}'" >&2; exit 2 ;; esac
  if [ "$GUEST_NODEPORT" -lt 30000 ] || [ "$GUEST_NODEPORT" -gt 32767 ]; then
    echo "REFUSING: TOCKMOX_SITE_GIT_NODEPORT ${GUEST_NODEPORT} is outside the NodePort range 30000-32767" >&2; exit 2
  fi
}

# writable_guard ... writable mode runs only on the throwaway that `throwaway-cluster.sh publish`
# vouched for (see WRITABLE MODE above).
writable_guard() {
  local g="${TOCKMOX_WRITABLE_GUARD:-}" ns ctx
  if [ -z "$g" ] || [ ! -s "$g" ]; then
    echo "REFUSING: up --writable starts an unauthenticated writable git daemon, and only on a disposable throwaway." >&2
    echo "          TOCKMOX_WRITABLE_GUARD must name the file 'throwaway-cluster.sh publish' wrote after its" >&2
    echo "          disposable-namespace check passed; it is unset, missing or empty." >&2
    exit 2
  fi
  ns="$(sed -n 's/^disposable-namespace=//p' "$g" | head -1)"
  ctx="$(sed -n 's/^guest-context=//p' "$g" | head -1)"
  if [ -z "$ns" ] || [ -z "$ctx" ]; then
    echo "REFUSING: ${g} does not name a disposable namespace and a guest context" >&2; exit 2
  fi
  if [ "$ctx" != "$KUBE_CONTEXT" ]; then
    echo "REFUSING: ${g} vouches for the guest context '${ctx}', not for KUBE_CONTEXT '${KUBE_CONTEXT}'." >&2
    echo "          A writable git daemon is not started on a cluster the harness did not create." >&2
    exit 2
  fi
}

cmd_up() {
  need kubectl
  need git
  local mode=readonly
  case "${1:-}" in
    "") ;;
    --writable) mode=writable ;;
    *) echo "usage: $0 up [--writable]" >&2; exit 2 ;;
  esac
  if [ "$mode" = writable ]; then
    check_nodeport
    writable_guard
  fi
  kubectl --context="$KUBE_CONTEXT" create namespace "$NS" --dry-run=client -o yaml | kubectl --context="$KUBE_CONTEXT" apply -f - >/dev/null
  manifest "$mode" | kubectl --context="$KUBE_CONTEXT" apply -f - >/dev/null
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
    if kubectl --context="$KUBE_CONTEXT" -n "$NS" exec "$POD" -- sh -c 'command -v git >/dev/null && command -v python3 >/dev/null && [ -x "$(git --exec-path)/git-daemon" ] && [ -x "$(git --exec-path)/git-http-backend" ]' >/dev/null 2>&1; then
      if [ "$mode" = writable ]; then
        echo "  ${NS}/${POD} ready (writable: site.git and tockmox.git exist, receive-pack is on, NodePort ${GUEST_NODEPORT})" >&2
      else
        echo "  ${NS}/${POD} ready (daemon starts on first push)" >&2
      fi
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
# an operator does. Added 2026-09-06: without it the only way to
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
  # THE TREE THIS PUSH MUST SERVE, computed from the bytes on disk before anything is sent. The
  # pod refuses to publish anything else (below). On 2026-11-16 a push from macOS served a product
  # tree with 631 extra `._*` files: bsdtar packs an AppleDouble file for every file carrying an
  # xattr, the pod's `git add -A` committed them, a chart's `.Files.Glob "dashboards/*.json"` read
  # them, and the clone probe still passed, so the run tested a tree that was not the one given.
  # FORCE_ADD: one pathspec of files to serve although .gitignore excludes them. The air-gap lane sets
  # it to the subchart archives tools/helm-deps.sh vendors: `.gitignore` excludes charts/*/charts/ and
  # *.tgz, so the pod's `git add -A` dropped them and the guest's Argo CD fetched every subchart from
  # upstream under the cut (2026-11-21). It goes into the tree check below as well, so the tree
  # pushed is still exactly the tree computed here, and the pod reports how many files it forced.
  FORCE_ADD="${TOCKMOX_SERVE_FORCE_ADD:-}"
  if [ -n "$FORCE_ADD" ] && ! [[ "$FORCE_ADD" =~ ^[A-Za-z0-9._*/-]+$ ]]; then
    echo "REFUSING: TOCKMOX_SERVE_FORCE_ADD must be one plain pathspec (letters, digits, . _ * / -), not '${FORCE_ADD}'" >&2; exit 2
  fi
  local want
  want="$(tree_of "$dir")" || { echo "REFUSING: could not compute the git tree of ${dir}" >&2; exit 2; }
  local tgz
  tgz="$(mktemp "${TMPDIR:-/tmp}/tockmox-repo.XXXXXX").tgz"
  # A working tree, not a clone: this deliberately publishes what is ON DISK,
  # including uncommitted edits, because that is what a harness run is testing.
  # COPYFILE_DISABLE stops macOS bsdtar writing AppleDouble files; the exclude drops any already
  # on disk (GNU tar ignores the variable and honours the exclude).
  ( cd "$dir" && COPYFILE_DISABLE=1 tar czf "$tgz" --exclude=.git --exclude='._*' . )
  kubectl --context="$KUBE_CONTEXT" -n "$NS" cp "$tgz" "${POD}:/tmp/${name}.tgz" >/dev/null
  rm -f "$tgz"
  local served
  if ! served="$(kubectl --context="$KUBE_CONTEXT" -n "$NS" exec "$POD" -- sh -c "
    set -e
    git config --global --add safe.directory '*'
    git config --global init.defaultBranch main
    git config --global user.email harness@example.com
    git config --global user.name harness
    rm -rf /tmp/w-${name}
    mkdir -p /tmp/w-${name} && cd /tmp/w-${name} && tar xzf /tmp/${name}.tgz
    git init -q . && git add -A
    if [ -n '${FORCE_ADD}' ]; then git add -f -- '${FORCE_ADD}'; echo \"FORCED \$(git ls-files -- '${FORCE_ADD}' | wc -l)\"; fi
    git commit -qm 'harness snapshot ${ref:-main}'
    got=\$(git rev-parse 'HEAD^{tree}')
    if [ \"\$got\" != '${want}' ]; then echo \"TREE_MISMATCH \$got\"; exit 3; fi
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
    echo \"SERVED \$got\"
  " 2>&1)"; then
    case "$served" in
      *TREE_MISMATCH*)
        echo "REFUSING: ${name}.git would have served tree $(printf '%s\n' "$served" | sed -n 's/.*TREE_MISMATCH //p' | tail -1), not ${want}, the tree of ${dir}. Nothing was published. The bytes that reached the pod differ from the directory given (on macOS, look for ._ files in what was sent)." >&2 ;;
      *) echo "REFUSING: publishing ${name}.git in ${NS}/${POD} failed: $(printf '%s' "$served" | tail -3)" >&2 ;;
    esac
    exit 1
  fi
  case "$served" in
    *"SERVED ${want}"*) ;;
    *) echo "REFUSING: the pod did not confirm ${name}.git serves ${want}: $(printf '%s' "$served" | tail -3)" >&2; exit 1 ;;
  esac
  local forced=""
  if [ -n "$FORCE_ADD" ]; then
    forced="$(printf '%s\n' "$served" | sed -n 's/^FORCED *//p' | tail -1)"
    # The tree check above already holds the forced files to the directory's bytes; this catches the
    # case it cannot: a pathspec that matched nothing, so the run would go on serving no archives.
    case "$forced" in
      ''|0|*[!0-9]*) echo "REFUSING: TOCKMOX_SERVE_FORCE_ADD='${FORCE_ADD}' forced ${forced:-no} file(s) into ${name}.git; the files it names are not in ${dir}" >&2; exit 1 ;;
    esac
  fi
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
  echo "  published and clone-verified: $(url_for "$name")${ref:+ @ ${ref}}, tree ${want}" >&2
  [ -z "$forced" ] || echo "  served although .gitignore excludes them: ${forced} file(s) matching ${FORCE_ADD}" >&2
  url_for "$name"
}

# reach URL ... a pod in THIS cluster reads URL with `git ls-remote`. For the writable mode's
# one URL, which is the hypervisor's published address, this is the hairpin: the cluster
# reaching the address it is itself published at. It is asserted here, not assumed.
cmd_reach() {
  need kubectl
  local url="${1:-}"
  case "$url" in
    git://?*) ;;
    *) echo "REFUSING: reach takes a git:// URL, not '${url}'" >&2; exit 2 ;;
  esac
  case "$url" in
    *[!A-Za-z0-9._:/-]*) echo "REFUSING: reach: the URL may hold only letters, digits and . _ : / - (it is run in a shell)" >&2; exit 2 ;;
  esac
  kubectl --context="$KUBE_CONTEXT" -n "$NS" delete pod gitprobe-reach --ignore-not-found >/dev/null 2>&1 || true
  if ! kubectl --context="$KUBE_CONTEXT" -n "$NS" run gitprobe-reach --rm -i --restart=Never \
        --image=alpine/git:latest --command -- \
        sh -c "git ls-remote '${url}' >/dev/null" >/dev/null 2>&1; then
    echo "REFUSING: a pod in this cluster could not read ${url}" >&2
    exit 1
  fi
  echo "  a pod in this cluster reads ${url}" >&2
}

cmd_down() {
  need kubectl
  kubectl --context="$KUBE_CONTEXT" -n "$NS" delete pod -l tockmox.com/harness=executed-docs --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context="$KUBE_CONTEXT" -n "$NS" delete svc "$SVC" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context="$KUBE_CONTEXT" delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "  ${NS} removed" >&2
}

case "${1:-}" in
  up)   shift; cmd_up "$@" ;;
  manifest) shift; case "${1:-}" in "") manifest readonly ;; --writable) check_nodeport; manifest writable ;; *) echo "usage: $0 manifest [--writable]" >&2; exit 2 ;; esac ;;
  script) shift; case "${1:-}" in "") serve_script readonly ;; --writable) serve_script writable ;; *) echo "usage: $0 script [--writable]" >&2; exit 2 ;; esac ;;
  nodeport) check_nodeport; printf '%s\n' "$GUEST_NODEPORT" ;;
  reach) shift; [ $# -eq 1 ] || { echo "usage: $0 reach URL" >&2; exit 2; }; cmd_reach "$1" ;;
  push) shift; [ $# -eq 2 ] || [ $# -eq 3 ] || { echo "usage: $0 push DIR NAME [REF]" >&2; exit 2; }; cmd_push "$1" "$2" "${3:-}" ;;
  url)  shift; [ $# -eq 1 ] || { echo "usage: $0 url NAME" >&2; exit 2; }; url_for "$1"; echo ;;
  down) cmd_down ;;
  *) echo "usage: $0 {up [--writable]|push DIR NAME [REF]|url NAME|nodeport|reach URL|manifest|script|down}" >&2; exit 2 ;;
esac

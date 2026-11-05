#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups K1-K9: the install kit's host launcher (install/kit/tockmox-kit) and its
# entrypoint (install/kit/entrypoint.sh).
#
# HERMETIC. The container runtime is a shim that records the arguments it was given and runs nothing,
# so these groups prove what the launcher ASKS the runtime for: the mounts, the uid, the tmpfs, the
# image, and that the installer's arguments arrive unchanged. They do not prove that a real runtime
# honours those flags or that the image builds; the kit workflow builds the image on amd64 and arm64
# and runs it. The entrypoint is run directly against this checkout (TOCKMOX_KIT_ROOT), which proves
# that it hands everything to the installer and that the installer names itself as the launcher.

KT="$WORK/kit"; mkdir -p "$KT/bin" "$KT/proj"
KIT="$REPO_ROOT/install/kit/tockmox-kit"
KIT_ENTRY="$REPO_ROOT/install/kit/entrypoint.sh"

# A runtime shim for each of docker, podman and nerdctl. `info` answers when RT_<NAME>_UP=1;
# every other call appends its arguments, one per line, to $KT/<name>.args, and exits 0.
for rt in docker podman nerdctl; do
  cat > "$KT/bin/$rt" <<SHIM
#!/usr/bin/env bash
up_var="RT_$(printf '%s' "$rt" | tr '[:lower:]' '[:upper:]')_UP"
if [ "\${1:-}" = "info" ]; then [ "\${!up_var:-0}" = "1" ]; exit \$?; fi
printf '%s\n' "\$@" > "$KT/$rt.args"
SHIM
  chmod +x "$KT/bin/$rt"
done
printf 'apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n    server: https://192.0.2.10:6443\n  name: lab\n' > "$KT/proj/kubeconfig"
printf 'apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n    server: https://127.0.0.1:6443\n  name: tunnel\n' > "$KT/proj/loopback"
printf -- '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n' > "$KT/proj/ca.pem"

# kit_run <env assignments...> -- <launcher args...>: run the launcher from $KT/proj with only the
# shims as runtimes, capturing exit code, stdout and stderr. The env assignments decide which runtime answers.
kit_run() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  rm -f "$KT"/*.args
  KIT_RC=0
  ( cd "$KT/proj" && env -u TOCKMOX_KIT_RUNTIME -u KUBECONFIG ${envs[@]+"${envs[@]}"} \
      PATH="$KT/bin:/usr/bin:/bin" HOME="$KT/proj" "$KIT" "$@" ) >"$KT/out" 2>"$KT/err" || KIT_RC=$?
}
args_of() { cat "$KT/$1.args" 2>/dev/null; }
# has_seq <runtime> <a> <b>: argument a is immediately followed by argument b
has_seq() { awk -v a="$2" -v b="$3" 'p==a && $0==b {f=1} {p=$0} END {print f?"yes":"no"}' "$KT/$1.args" 2>/dev/null || echo no; }

path_begin "K1" "the launcher asks for a throwaway container, memory for working files, your uid, and a read-only kubeconfig"
kit_run RT_DOCKER_UP=1 -- --kubeconfig kubeconfig --config tockmox.yaml --dry-run
assert_artifact "it ran docker, the runtime that answered" "test -s '$KT/docker.args' && echo ran" "ran"
assert_artifact "the container is removed when it exits" "has_seq docker run --rm" "yes"
assert_artifact "working files live on a tmpfs at /tmp, which is gone when it exits" \
  "args_of docker | grep -c '^/tmp:rw,nosuid,nodev,size=256m,mode=1777\$'" "1"
assert_artifact "the current directory is mounted as /work and nothing else of the host is" \
  "args_of docker | grep -E -c '^[^-].*:/(work|kube/config:ro|kit/ca.pem:ro)\$'" "2"
assert_artifact "it runs as the caller's uid and gid, so what it writes is theirs" "has_seq docker --user '$(id -u):$(id -g)'" "yes"
assert_artifact "the kubeconfig is mounted read-only at /kube/config" "has_seq docker -v '$KT/proj/kubeconfig:/kube/config:ro'" "yes"
assert_artifact "the installer's arguments arrive after the image, unchanged and in order" \
  "args_of docker | tail -n 4 | tr '\n' ' '" "tockmox-kit --config tockmox.yaml --dry-run "
assert_artifact "the installer is told the launcher's name, so its next steps are runnable here" \
  "has_seq docker -e 'TOCKMOX_INVOKED_AS=$KIT'" "yes"
assert_artifact "Docker gets no podman-only flag" "args_of docker | grep -c 'userns' || true" "0"

path_begin "K2" "a runtime is chosen because its daemon answers, not because its CLI is on PATH"
kit_run RT_DOCKER_UP=0 RT_PODMAN_UP=1 -- --kubeconfig kubeconfig kit-check
assert_artifact "a docker CLI with no daemon is passed over for a podman that answers" "test -s '$KT/podman.args' && echo podman" "podman"
assert_artifact "and the pass-over is said, not silent" "grep -c 'docker is on PATH but does not answer' '$KT/err'" "1"
assert_artifact "rootless Podman also gets keep-id, so ownership maps to the caller" "has_seq podman --user '$(id -u):$(id -g)'; args_of podman | grep -c '^--userns=keep-id\$'" "yes
1"
kit_run RT_DOCKER_UP=0 RT_PODMAN_UP=0 RT_NERDCTL_UP=0 -- kit-check
assert_artifact "with no runtime answering it refuses" "echo $KIT_RC" "1"
assert_artifact "and says what to do" "grep -c 'no container runtime answered' '$KT/err'" "1"
kit_run RT_DOCKER_UP=0 TOCKMOX_KIT_RUNTIME=nerdctl -- kit-check
assert_artifact "TOCKMOX_KIT_RUNTIME picks one explicitly" "test -s '$KT/nerdctl.args' && echo nerdctl" "nerdctl"

path_begin "K3" "kubeconfig shapes the kit cannot use are named before the container starts"
kit_run RT_DOCKER_UP=1 KUBECONFIG=/a:/b -- kit-check
assert_artifact "a KUBECONFIG listing several files is refused" "echo $KIT_RC" "1"
assert_artifact "with the flatten command to fix it" "grep -c 'kubectl config view --flatten' '$KT/err'" "1"
kit_run RT_DOCKER_UP=1 -- --kubeconfig loopback kit-check
assert_artifact "a cluster on 127.0.0.1 is warned about, because inside the kit that is the kit" \
  "grep -c 'names a cluster on 127.0.0.1 or localhost' '$KT/err'" "1"
assert_artifact "a warning, not a refusal: the run still starts" "test -s '$KT/docker.args' && echo ran" "ran"
kit_run RT_DOCKER_UP=1 -- --kubeconfig kubeconfig kit-check
assert_artifact "an ordinary address draws no loopback warning" "grep -E -c 'loopback|127[.]0[.]0[.]1' '$KT/err' || true" "0"
kit_run RT_DOCKER_UP=1 -- --kubeconfig nowhere kit-check
assert_artifact "a missing kubeconfig is said, and nothing is mounted for it" \
  "grep -c 'no kubeconfig at nowhere' '$KT/err'; args_of docker | grep -c '/kube/config' || true" "1
0"

path_begin "K4" "a path on the host is flagged, because the kit sees only the working directory"
kit_run RT_DOCKER_UP=1 -- --kubeconfig kubeconfig --config /etc/tockmox.yaml
assert_artifact "an absolute path argument draws a warning naming it" "grep -c \"'/etc/tockmox.yaml' is a path on this machine\" '$KT/err'" "1"
assert_artifact "and is still passed through unchanged" "args_of docker | tail -n 1" "/etc/tockmox.yaml"

path_begin "K5" "a CA is mounted read-only where the entrypoint looks for it, and a bad one is refused"
kit_run RT_DOCKER_UP=1 -- --kubeconfig kubeconfig --ca-file ca.pem kit-check
assert_artifact "the CA is mounted read-only at /kit/ca.pem" "has_seq docker -v '$KT/proj/ca.pem:/kit/ca.pem:ro'" "yes"
kit_run RT_DOCKER_UP=1 -- --ca-file absent.pem kit-check
assert_artifact "a CA file that is missing is refused before anything runs" "echo $KIT_RC; test -e '$KT/docker.args' && echo ran || echo not-run" "1
not-run"

path_begin "K6" "build: from this clone by default, from a tag on request, and the CA as a build secret"
kit_run RT_DOCKER_UP=1 -- build
assert_artifact "inside a clone, the context is the repository root and the Dockerfile is the kit's" \
  "args_of docker | tr '\n' ' '" "build -t tockmox-kit -f install/kit/Dockerfile $REPO_ROOT "
kit_run RT_DOCKER_UP=1 -- build --ref v9.9.9 --image my-kit
assert_artifact "--ref builds the named tag from GitHub, so no clone is needed" \
  "args_of docker | tail -n 1" "https://github.com/tockmox/tockmox.git#v9.9.9"
assert_artifact "--image names the result" "has_seq docker -t my-kit" "yes"
kit_run RT_DOCKER_UP=1 -- build --ca-file ca.pem
assert_artifact "--ca-file becomes a build secret, which no image layer keeps" "has_seq docker --secret 'id=ca,src=$KT/proj/ca.pem'" "yes"

path_begin "K7" "the entrypoint hands everything to the installer, which names itself as the launcher"
KE_OUT="$(cd "$KT/proj" && TOCKMOX_KIT_ROOT="$REPO_ROOT" TOCKMOX_INVOKED_AS=tockmox-kit HOME="$KT/proj/home" \
  KUBECONFIG=/nonexistent bash "$KIT_ENTRY" --help 2>&1 || true)"
printf '%s\n' "$KE_OUT" > "$KT/entry-help.txt"
assert_artifact "--help reaches the installer's own usage" "head -n 1 '$KT/entry-help.txt' | sed 's/ v[0-9].*//'" "Tockmox installer"
assert_artifact "and the subcommands it names are run through the launcher" \
  "grep -c \"Run 'tockmox-kit bootstrap-secrets --help'\" '$KT/entry-help.txt'" "1"
assert_artifact "with no launcher, the installer still names itself as before" \
  "bash '$REPO_ROOT/install/tockmox-install.sh' --help | grep -c \"Run '$REPO_ROOT/install/tockmox-install.sh bootstrap-secrets --help'\"" "1"

path_begin "K8" "the entrypoint adds a mounted CA to the system trust bundle, never replacing it, for every client"
mkdir -p "$KT/ca/tmp"
printf 'SYSTEM-BUNDLE\n' > "$KT/ca/system.pem"; printf 'MOUNTED-CA\n' > "$KT/ca/mounted.pem"
# shellcheck disable=SC2016  # expanded by the kit's shell, not this one
( cd "$KT/proj" && TOCKMOX_KIT_ROOT="$REPO_ROOT" TOCKMOX_KIT_CA="$KT/ca/mounted.pem" TOCKMOX_KIT_SYS_BUNDLE="$KT/ca/system.pem" \
  TMPDIR="$KT/ca/tmp" HOME="$KT/proj/home" KUBECONFIG=/nonexistent bash "$KIT_ENTRY" shell -c \
  'cat "$SSL_CERT_FILE"; for v in CURL_CA_BUNDLE GIT_SSL_CAINFO REQUESTS_CA_BUNDLE; do [ "${!v}" = "$SSL_CERT_FILE" ] && echo "$v same"; done' ) > "$KT/ca/out" 2>&1 || true
assert_artifact "the bundle every client reads is the system bundle, then the mounted CA" "head -n 2 '$KT/ca/out' | tr '\n' ' '" "SYSTEM-BUNDLE MOUNTED-CA "
assert_artifact "curl, git and Python are pointed at the same bundle" "tail -n 3 '$KT/ca/out' | tr '\n' ' '" "CURL_CA_BUNDLE same GIT_SSL_CAINFO same REQUESTS_CA_BUNDLE same "
# shellcheck disable=SC2016  # expanded by the kit's shell, not this one
( cd "$KT/proj" && env -u SSL_CERT_FILE TOCKMOX_KIT_ROOT="$REPO_ROOT" TOCKMOX_KIT_CA="$KT/ca/none.pem" HOME="$KT/proj/home" KUBECONFIG=/nonexistent \
  bash "$KIT_ENTRY" shell -c 'echo "[${SSL_CERT_FILE:-unset}]"' ) > "$KT/ca/out2" 2>&1 || true
assert_artifact "with no CA mounted, trust is left exactly as the image has it" "cat '$KT/ca/out2'" "[unset]"

path_begin "K9" "the entrypoint stays a launcher: paths, trust and two verbs, nothing that branches the install"
assert_artifact "every case the entrypoint dispatches on is kit-check, shell, or everything else to the installer" \
  "sed -n '/^case \"\${1:-}\" in/,/^esac/p' '$KIT_ENTRY' | grep -E -o '^  [a-z*-]+\\)' | tr -d ' )' | tr '\n' ' '" "kit-check shell * "
assert_artifact "the installer's scripts mention no container: the kit adds no branch to them" \
  "grep -l -E 'TOCKMOX_KIT_|/opt/tockmox|(^|[[:space:]=\\\"(])/work([/[:space:]\\\"]|\$)' '$REPO_ROOT'/install/*.sh '$REPO_ROOT/tools/mint-secrets.sh' | wc -l | tr -d ' '" "0"

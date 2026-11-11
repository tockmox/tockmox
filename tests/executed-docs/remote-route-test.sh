#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for the external (bring your own forge) route of p09-lane.sh: the one git URL that the
# workstation pushes to and the cluster clones from. No cluster: kubectl is a stub that logs every call and keeps
# Services as files; git is the REAL git, and where the question is whether a push and a clone work at one URL a
# real `git daemon` is started with the flags site-repo-server.sh would give it.
#
#   1. site-repo-server.sh: the writable mode's daemon flags, bare repositories and NodePort; the read-only
#      manifest unchanged in kind; up --writable refused without the voucher publish leaves, or on another context
#   2. a real git daemon started from that script: a push and a clone at ONE URL work; the read-only script's
#      daemon refuses the same push; a copy without --enable=receive-pack refuses it too
#   3. throwaway-cluster.sh publish: a Service named after the VM that selects the VM, the host:port it prints,
#      the voucher; destroy and sweep remove the Service and the voucher with the VM; every refusal
#   4. p09-lane.sh on the external route: publish, up --writable, a runner check, a guest check, then the URL is
#      exported and the real P09 no longer declares BLOCKED for it; the built-in route is untouched; a failed
#      step ends the lane with 5 and a named reason, never a pass
#   5. copies that lose one guard each stop being caught
#
#   ./tests/executed-docs/remote-route-test.sh
#
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # stub bodies and greps are literal text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRS="${SRS:-${HERE}/provision/site-repo-server.sh}"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
LANE_SH="${LANE_SH:-${HERE}/p09-lane.sh}"
P09="${P09:-${HERE}/paths/P09-install-md-end-to-end.sh}"
TMP="$(mktemp -d)"
DPIDS=""
cleanup() { for p in $DPIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
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
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# ============================================================ 1. site-repo-server.sh
mkdir -p "$TMP/kbin"
cat > "$TMP/kbin/kubectl" <<'STUB'
#!/bin/sh
echo "$*" >> "$KT_LOG"
case "$*" in
  *"apply -f -"*) cat >> "$KT_APPLIED" ;;
  *"create namespace"*) echo "kind: Namespace" ;;
  *" run "*) [ "${KT_FAIL:-}" = run ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP/kbin/kubectl"
run_srs() { # args... -> $TMP/out, $TMP/err, $RC
  KT_LOG="$TMP/klog" KT_APPLIED="$TMP/applied" PATH="$TMP/kbin:$PATH" KUBE_CONTEXT=guest-ctx \
    bash "${SRS_USE:-$SRS}" "$@" > "$TMP/out" 2> "$TMP/err"
  RC=$?
}
reset_k() { : > "$TMP/klog"; : > "$TMP/applied"; }
both() { cat "$TMP/out" "$TMP/err"; }
voucher() { printf 'disposable-namespace=tockmox-test\nvm=ed-run\nguest-context=%s\n' "${1:-guest-ctx}" > "$TMP/voucher"; }

run_srs script --writable
W="$(cat "$TMP/out")"
run_srs script
R="$(cat "$TMP/out")"
printf '%s' "$W" | grep -F -- '--enable=receive-pack' >/dev/null && ! printf '%s' "$R" | grep -F -- '--enable' >/dev/null \
  && ok "the writable daemon is started with --enable=receive-pack, the read-only one with no --enable" || bad "daemon flags" "$W"
printf '%s' "$W" | grep -F -- '--export-all --base-path=/repos' >/dev/null && printf '%s' "$W" | grep -F -- '--listen=0.0.0.0 --port=9418' >/dev/null \
  && ok "the writable daemon still exports every repository under /repos on the daemon port" || bad "daemon base flags" "$W"
printf '%s' "$W" | grep -F 'for r in site tockmox; do' >/dev/null && printf '%s' "$W" | grep -F 'git init -q --bare --initial-branch=main /repos/$r.git' >/dev/null \
  && printf '%s' "$W" | grep -n 'touch /repos/.seeded' >/dev/null \
  && ok "the writable script creates bare site.git and tockmox.git (main) before the daemon starts" || bad "bare repos" "$W"
printf '%s' "$R" | grep -F 'while [ ! -f /repos/.seeded ]' >/dev/null && ! printf '%s' "$R" | grep -F 'git init' >/dev/null \
  && ok "the read-only script still waits for a push to seed it and creates nothing" || bad "read-only script" "$R"
run_srs manifest --writable
printf '%s' "$(cat "$TMP/out")" | grep -E '^  type: NodePort$' >/dev/null && grep -F 'nodePort: 30418' "$TMP/out" >/dev/null \
  && ok "the writable Service is a NodePort on the fixed guest port 30418" || bad "writable manifest" "$(cat "$TMP/out")"
run_srs manifest
! grep -F 'NodePort' "$TMP/out" >/dev/null && grep -F 'name: site-git' "$TMP/out" >/dev/null && ! grep -F 'receive-pack' "$TMP/out" >/dev/null \
  && ok "the read-only manifest is still a ClusterIP Service with no receive-pack" || bad "read-only manifest" "$(cat "$TMP/out")"
run_srs nodeport
[ "$RC" = 0 ] && [ "$(cat "$TMP/out")" = 30418 ] && ok "nodeport prints 30418 by default" || bad "nodeport default" "rc=$RC $(both)"
TOCKMOX_SITE_GIT_NODEPORT=31999 run_srs nodeport
[ "$(cat "$TMP/out")" = 31999 ] && ok "TOCKMOX_SITE_GIT_NODEPORT moves it" || bad "nodeport override" "$(both)"
TOCKMOX_SITE_GIT_NODEPORT=80 run_srs nodeport
[ "$RC" = 2 ] && grep -F 'outside the NodePort range' "$TMP/err" >/dev/null && ok "a port outside 30000-32767 is refused" || bad "nodeport range" "rc=$RC $(both)"
TOCKMOX_SITE_GIT_NODEPORT=abc run_srs nodeport
[ "$RC" = 2 ] && ok "a port that is not a number is refused" || bad "nodeport nan" "rc=$RC"

# the voucher
reset_k; TOCKMOX_WRITABLE_GUARD="" run_srs up --writable
[ "$RC" = 2 ] && grep -F 'unauthenticated writable git daemon' "$TMP/err" >/dev/null && [ ! -s "$TMP/klog" ] \
  && ok "up --writable without a voucher is refused before any cluster call" || bad "no voucher" "rc=$RC $(both) log=$(cat "$TMP/klog")"
reset_k; TOCKMOX_WRITABLE_GUARD="$TMP/nope" run_srs up --writable
[ "$RC" = 2 ] && [ ! -s "$TMP/klog" ] && ok "a voucher file that does not exist is refused" || bad "missing voucher file" "rc=$RC"
voucher other-ctx; reset_k; TOCKMOX_WRITABLE_GUARD="$TMP/voucher" run_srs up --writable
[ "$RC" = 2 ] && grep -F "not for KUBE_CONTEXT 'guest-ctx'" "$TMP/err" >/dev/null && [ ! -s "$TMP/klog" ] \
  && ok "a voucher for another cluster's context is refused before any cluster call" || bad "wrong context voucher" "rc=$RC $(both)"
printf 'guest-context=guest-ctx\n' > "$TMP/voucher"; reset_k; TOCKMOX_WRITABLE_GUARD="$TMP/voucher" run_srs up --writable
[ "$RC" = 2 ] && [ ! -s "$TMP/klog" ] && ok "a voucher that names no disposable namespace is refused" || bad "no-namespace voucher" "rc=$RC"
voucher; reset_k; TOCKMOX_WRITABLE_GUARD="$TMP/voucher" run_srs up --writable
[ "$RC" = 0 ] && grep -F -- '--enable=receive-pack' "$TMP/applied" >/dev/null && grep -F 'nodePort: 30418' "$TMP/applied" >/dev/null \
  && ok "with the voucher up --writable applies the receive-pack daemon and the NodePort Service" || bad "up --writable" "rc=$RC $(both)"
! grep -v -- '--context=guest-ctx' "$TMP/klog" | grep . >/dev/null && ok "every kubectl call of up --writable names the guest context" || bad "context on every call" "$(grep -v -- '--context=guest-ctx' "$TMP/klog")"
reset_k; run_srs up
[ "$RC" = 0 ] && ! grep -F -- 'receive-pack' "$TMP/applied" >/dev/null && ok "plain up needs no voucher and applies no receive-pack" || bad "plain up" "rc=$RC $(both)"

# reach
reset_k; run_srs reach git://192.0.2.10:31234/site.git
[ "$RC" = 0 ] && grep -F "git ls-remote 'git://192.0.2.10:31234/site.git'" "$TMP/klog" >/dev/null && grep -F -- '--context=guest-ctx' "$TMP/klog" >/dev/null \
  && ok "reach reads the URL from a pod in the guest, on the guest context" || bad "reach" "rc=$RC $(both) $(cat "$TMP/klog")"
KT_FAIL=run run_srs reach git://192.0.2.10:31234/site.git
[ "$RC" = 1 ] && grep -F 'could not read git://192.0.2.10:31234/site.git' "$TMP/err" >/dev/null && ok "reach fails, naming the URL, when the pod cannot read it" || bad "reach failure" "rc=$RC $(both)"
run_srs reach "http://x/y"; [ "$RC" = 2 ] && ok "reach refuses a URL that is not git://" || bad "reach scheme" "rc=$RC"
run_srs reach "git://x/y';id;'"; [ "$RC" = 2 ] && ok "reach refuses a URL with shell metacharacters" || bad "reach quoting" "rc=$RC"

# ============================================================ 2. a real git daemon, one URL
start_daemon() { # SRS MODE -> sets DPORT, DREPOS; waits until the daemon answers
  DPORT="$(free_port)"; DREPOS="$TMP/repos-$DPORT"
  SRS_FOR_DAEMON="$1" SH_BODY "$2" "$DREPOS" "$DPORT" > "$TMP/dscript-$DPORT"
  if [ "$3" = preseed ]; then mkdir -p "$DREPOS"; git init -q --bare --initial-branch=main "$DREPOS/site.git"; git init -q --bare --initial-branch=main "$DREPOS/tockmox.git"; touch "$DREPOS/.seeded"; fi
  sh "$TMP/dscript-$DPORT" > "$TMP/dlog-$DPORT" 2>&1 &
  DPIDS="$DPIDS $!"

  for _ in $(seq 1 50); do
    git ls-remote "git://127.0.0.1:${DPORT}/site.git" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}
mkdir -p "$TMP/work"
git -C "$TMP/work" init -q . 2>/dev/null
echo hello > "$TMP/work/file"
git -C "$TMP/work" add -A
git -C "$TMP/work" -c user.name=t -c user.email=t@example.invalid commit -q -m first
export KUBE_CONTEXT=x
SRS_FOR_DAEMON="$SRS"
SH_BODY() { bash "$SRS_FOR_DAEMON" script ${1:+"$1"} | sed "s#/repos#$2#g; s#--port=9418#--port=$3#"; }
start_daemon "$SRS" --writable none
U="git://127.0.0.1:${DPORT}"
if [ -d "$DREPOS/site.git" ] && [ -d "$DREPOS/tockmox.git" ] && [ "$(git --git-dir="$DREPOS/site.git" symbolic-ref HEAD)" = refs/heads/main ]; then
  ok "the writable script created site.git and tockmox.git, bare, on main, by itself"
else bad "real daemon: bare repos" "$(cat "$TMP/dlog-$DPORT")"; fi
git -C "$TMP/work" push -q "$U/site.git" HEAD:refs/heads/main 2>"$TMP/perr"; PRC=$?
rm -rf "$TMP/clone"; git clone -q "$U/site.git" "$TMP/clone" 2>>"$TMP/perr"; CRC=$?
[ "$PRC" = 0 ] && [ "$CRC" = 0 ] && [ "$(git -C "$TMP/clone" rev-parse HEAD)" = "$(git -C "$TMP/work" rev-parse HEAD)" ] \
  && ok "a push to git://host:port/site.git and a clone from the same string give the same commit (one URL)" || bad "real daemon: push then clone" "push=$PRC clone=$CRC $(cat "$TMP/perr")"
git -C "$TMP/work" -c user.name=t -c user.email=t@example.invalid tag -a lane-x -m t
git -C "$TMP/work" push -q "$U/tockmox.git" HEAD:refs/heads/main refs/tags/lane-x 2>>"$TMP/perr"; TRC=$?
rm -rf "$TMP/clone2"; git clone -q --branch lane-x "$U/tockmox.git" "$TMP/clone2" 2>>"$TMP/perr"; T2=$?
[ "$TRC" = 0 ] && [ "$T2" = 0 ] && ok "the product tree pushed at a tag to tockmox.git clones at that tag" || bad "real daemon: tag" "push=$TRC clone=$T2 $(cat "$TMP/perr")"
git -C "$TMP/work" push --dry-run "$U/site.git" HEAD:refs/heads/lane-probe >/dev/null 2>&1 \
  && ok "a push dry run, the lane's runner check, is accepted by the writable daemon" || bad "dry run on writable" "$(git -C "$TMP/work" push --dry-run "$U/site.git" HEAD:refs/heads/lane-probe 2>&1)"
start_daemon "$SRS" "" preseed
RO="git://127.0.0.1:${DPORT}"
git -C "$TMP/work" push "$RO/site.git" HEAD:refs/heads/main >/dev/null 2>"$TMP/perr"; PRC=$?
[ "$PRC" != 0 ] && grep -F "service not enabled" "$TMP/perr" >/dev/null && git ls-remote "$RO/site.git" >/dev/null 2>&1 \
  && ok "the read-only script's daemon serves reads and refuses the same push (receive-pack not enabled)" || bad "read-only refuses push" "push=$PRC $(cat "$TMP/perr")"
git -C "$TMP/work" push --dry-run "$RO/site.git" HEAD:refs/heads/lane-probe >/dev/null 2>&1 \
  && bad "dry run on read-only must fail" "it was accepted" || ok "the push dry run the lane uses is refused by a read-only daemon"
mut "$SRS" "$TMP/srs-noflag.sh" ' --enable=receive-pack' ''
start_daemon "$TMP/srs-noflag.sh" --writable none
NF="git://127.0.0.1:${DPORT}"
git -C "$TMP/work" push "$NF/site.git" HEAD:refs/heads/main >/dev/null 2>&1 \
  && bad "mutation: no --enable=receive-pack" "the push was accepted" || ok "mutation: without --enable=receive-pack the push is refused (the flag is what the one URL needs)"

# ============================================================ 3. throwaway-cluster.sh publish
mkdir -p "$TMP/tbin" "$TMP/tw"
cat > "$TMP/tbin/kubectl" <<'STUB'
#!/usr/bin/env python3
# A kubectl that keeps Services as files under $KT_STORE/svc (YAML text and an assigned nodePort) and VMs as rows of
# $KT_STORE/vms (name, creation time, keep-until). KT_FAIL names steps that fail; KT_HOSTIP the node a pod runs on.
import os, re, sys
with open(os.environ["KT_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
a = [x for x in sys.argv[1:] if not x.startswith("--context=")]
if "-n" in a:
    i = a.index("-n"); del a[i:i + 2]
store = os.environ["KT_STORE"]
svc = os.path.join(store, "svc"); os.makedirs(svc, exist_ok=True)
vms = os.path.join(store, "vms")
fail = os.environ.get("KT_FAIL", "").split()
def rows():
    return [l.split() for l in open(vms) if l.strip()] if os.path.exists(vms) else []
def absent(w):
    sys.stderr.write('Error from server (NotFound): %s not found\n' % w); sys.exit(1)
if a[:2] == ["config", "current-context"]:
    kc = os.environ.get("KUBECONFIG", "")
    if kc and os.path.exists(kc):
        m = re.search(r"current-context: (\S+)", open(kc).read())
        if m: print(m.group(1))
elif a[:2] == ["get", "vm"]:
    if len(a) > 2 and not a[2].startswith("-"):
        sys.exit(0) if any(r[0] == a[2] for r in rows()) else absent('virtualmachine "%s"' % a[2])
    wide = any("creationTimestamp" in x for x in a)
    for r in rows():
        print(" ".join(r) if wide else r[0])
elif a[:2] == ["delete", "vm"]:
    keep = [r for r in rows() if r[0] != a[2]]
    open(vms, "w").write("".join(" ".join(r) + "\n" for r in keep))
elif a[:1] == ["apply"]:
    if "apply" in fail:
        sys.stderr.write("Error from server (Forbidden): services is forbidden (stub)\n"); sys.exit(1)
    y = sys.stdin.read()
    m = re.search(r"^kind: Service\nmetadata:\n  name: (\S+)", y, re.M)
    if m:
        open(os.path.join(svc, m.group(1)), "w").write(y)
        if "nonodeport" not in fail:
            open(os.path.join(svc, m.group(1) + ".np"), "w").write("31%03d" % (len(os.listdir(svc)) * 7 % 1000))
elif a[:2] == ["get", "svc"]:
    if len(a) > 2 and not a[2].startswith("-"):
        p = os.path.join(svc, a[2] + ".np")
        if not os.path.exists(p): absent('services "%s"' % a[2])
        if any("nodePort" in x for x in a): sys.stdout.write(open(p).read())
    else:
        for n in sorted(os.listdir(svc)):
            if not n.endswith(".np"): print(n)
elif a[:2] == ["delete", "svc"]:
    for n in [x for x in a[2:] if not x.startswith("-")]:
        for suf in ("", ".np"):
            p = os.path.join(svc, n + suf)
            if os.path.exists(p): os.remove(p)
        print('service "%s" deleted' % n)
elif a[:2] == ["get", "pod"]:
    if any("hostIP" in x for x in a): sys.stdout.write(os.environ.get("KT_HOSTIP", "192.0.2.10"))
elif a[:2] == ["get", "secret"]:
    if len(a) > 2 and not a[2].startswith("-"): absent('secrets "%s"' % a[2])
elif a[:1] == ["api-resources"]:
    print("virtualmachines   vm,vms   kubevirt.io/v1   true   VirtualMachine")
STUB
chmod +x "$TMP/tbin/kubectl"
stamp() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
OLD="$(stamp -300)"
reset_store() {
  rm -rf "$TMP/store" "$TMP/tw"; mkdir -p "$TMP/store/svc" "$TMP/tw"; : > "$TMP/tlog"
  printf 'ed-run %s <none>\n' "$OLD" > "$TMP/store/vms"
  [ "${NO_KC:-}" = 1 ] || printf 'current-context: guest-ctx\n' > "$TMP/tw/ed-run.kubeconfig"
}
run_tc() { # verb args... -> $TMP/out, $TMP/err, $RC
  KT_LOG="$TMP/tlog" KT_STORE="$TMP/store" PATH="$TMP/tbin:$PATH" TOCKMOX_WORKDIR="$TMP/tw" \
    TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate TOCKMOX_TEST_NAMESPACE="${NS:-tockmox-test}" TOCKMOX_TEST_VM="${VM:-ed-run}" \
    bash "${TC_USE:-$TC}" "$@" > "$TMP/out" 2> "$TMP/err"
  RC=$?
}
has_svc() { [ -f "$TMP/store/svc/$1" ]; }

reset_store; run_tc publish git 30418
HP="$(cat "$TMP/out")"
[ "$RC" = 0 ] && [ "${HP%%:*}" = 192.0.2.10 ] && [ -n "${HP##*:}" ] && [ "${HP##*:}" = "$(cat "$TMP/store/svc/ed-run-git.np")" ] \
  && ok "publish prints host:nodePort: the node the VM's pod is on and the port the Service was assigned" || bad "publish output" "rc=$RC out=$HP $(cat "$TMP/err")"
has_svc ed-run-git && ok "publish creates a Service named after the VM (ed-run-git)" || bad "service name" "$(ls "$TMP/store/svc")"
Y="$(cat "$TMP/store/svc/ed-run-git" 2>/dev/null)"
printf '%s' "$Y" | grep -E '^  type: NodePort$' >/dev/null && printf '%s' "$Y" | grep -F 'vm.kubevirt.io/name: ed-run' >/dev/null \
  && printf '%s' "$Y" | grep -E '^      targetPort: 30418$' >/dev/null && printf '%s' "$Y" | grep -F 'tockmox.com/harness: executed-docs' >/dev/null \
  && ok "the Service is a NodePort that selects the VM, forwards to the guest port and carries the harness label" || bad "service shape" "$Y"
[ "$(cat "$TMP/tw/ed-run.writable-guard")" = "disposable-namespace=tockmox-test
vm=ed-run
guest-context=guest-ctx" ] && ok "publish leaves the voucher: the disposable namespace, the VM and the guest context" || bad "voucher" "$(cat "$TMP/tw/ed-run.writable-guard" 2>&1)"
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$TMP/tw/ed-run.writable-guard")" = 0o600 ] && ok "the voucher is private to the caller" || bad "voucher mode" ""
! grep -v -- '--context=stub-substrate' "$TMP/tlog" | grep -v '^config current-context' | grep . >/dev/null && ok "every hypervisor call of publish names the substrate context" || bad "publish context" "$(grep -v -- '--context=stub-substrate' "$TMP/tlog")"
run_tc guard-file; [ "$(cat "$TMP/out")" = "$TMP/tw/ed-run.writable-guard" ] && ok "guard-file prints the voucher's path" || bad "guard-file" "$(both)"
run_tc publish git 30418; [ "$RC" = 0 ] && ok "publish is idempotent for the same name" || bad "idempotent" "rc=$RC"

# destroy and sweep
run_tc destroy
[ "$RC" = 0 ] && ! has_svc ed-run-git && [ ! -e "$TMP/tw/ed-run.writable-guard" ] && grep '^RESULT:   PASS' "$TMP/out" >/dev/null \
  && ok "destroy removes the published Service and the voucher with the VM" || bad "destroy" "rc=$RC svc=$(ls "$TMP/store/svc") $(tail -4 "$TMP/out") $(tail -6 "$TMP/err")"
reset_store; printf 'ed-keep %s %s\n' "$OLD" "$(( $(date -u +%s) + 3600 ))" >> "$TMP/store/vms"; printf 'current-context: guest-ctx\n' > "$TMP/tw/ed-keep.kubeconfig"
run_tc publish git 30418; VM=ed-keep run_tc publish git 30418
run_tc sweep ed- 120
! has_svc ed-run-git && has_svc ed-keep-git && [ ! -e "$TMP/tw/ed-run.writable-guard" ] && [ -e "$TMP/tw/ed-keep.writable-guard" ] \
  && ok "sweep removes the Service and voucher of a VM it destroys and leaves a kept VM's alone" || bad "sweep" "$(ls "$TMP/store/svc" "$TMP/tw")"
reset_store; run_tc publish git 30418; VM=ed-run; : > "$TMP/store/svc/ed-runner-git"
run_tc destroy; has_svc ed-runner-git && ok "destroy leaves a Service that is only a name prefix of another VM alone" || bad "prefix" ""

# refusals
reset_store; run_tc publish api 30418
[ "$RC" = 2 ] && grep -F "the name 'api'" "$TMP/err" >/dev/null && ! has_svc ed-run-api && ok "publish refuses the name api (the guest API's Service)" || bad "name api" "rc=$RC $(both)"
reset_store; run_tc publish Git 30418; [ "$RC" = 2 ] && ok "publish refuses an upper-case name" || bad "name case" "rc=$RC"
reset_store; run_tc publish git abc; [ "$RC" = 2 ] && ok "publish refuses a port that is not a number" || bad "port nan" "rc=$RC"
reset_store; run_tc publish git 70000; [ "$RC" = 2 ] && ok "publish refuses a port above 65535" || bad "port range" "rc=$RC"
reset_store; run_tc publish git; [ "$RC" = 2 ] && ok "publish refuses without a port" || bad "no port" "rc=$RC"
reset_store; printf 'current-context: guest-ctx\n' > "$TMP/tw/ed-gone.kubeconfig"; VM=ed-gone run_tc publish git 30418
[ "$RC" = 2 ] && grep -F 'does not exist' "$TMP/err" >/dev/null && [ -z "$(ls "$TMP/store/svc")" ] && ok "publish refuses when the VM does not exist: nothing would delete an orphan Service" || bad "no vm" "rc=$RC $(both)"
reset_store; NS=production run_tc publish git 30418
[ "$RC" = 2 ] && grep -F 'is not the disposable test namespace' "$TMP/err" >/dev/null && [ ! -s "$TMP/tlog" ] && [ -z "$(ls "$TMP/store/svc")" ] && [ ! -e "$TMP/tw/ed-run.writable-guard" ] \
  && ok "publish outside the disposable namespace is refused before any cluster call, and leaves no voucher" || bad "non-disposable namespace" "rc=$RC $(both)"
reset_store; TOCKMOX_VM_NETWORK=tockmox-test/segment run_tc publish git 30418
[ "$RC" = 2 ] && grep -F 'only the pod network' "$TMP/err" >/dev/null && ok "publish refuses off the pod network" || bad "network" "rc=$RC $(both)"
NO_KC=1 reset_store; run_tc publish git 30418
[ "$RC" = 2 ] && grep -F 'no guest kubeconfig' "$TMP/err" >/dev/null && [ -z "$(ls "$TMP/store/svc")" ] && ok "publish refuses before create has run (no guest kubeconfig)" || bad "no kubeconfig" "rc=$RC $(both)"
reset_store; KT_FAIL=apply run_tc publish git 30418
[ "$RC" = 1 ] && grep -F 'FAILED to apply tockmox-test/ed-run-git' "$TMP/err" >/dev/null && [ ! -e "$TMP/tw/ed-run.writable-guard" ] && ok "a refused apply fails publish, names the Service and leaves no voucher" || bad "apply failure" "rc=$RC $(both)"
reset_store; KT_HOSTIP=fd00::10 run_tc publish git 30418
[ "$RC" = 1 ] && grep -F 'IPv6' "$TMP/err" >/dev/null && [ ! -e "$TMP/tw/ed-run.writable-guard" ] && ok "an IPv6 node address is refused rather than printed as a broken URL" || bad "ipv6" "rc=$RC $(both)"
reset_store; TOCKMOX_NODEPORT_HOST=node.example.invalid run_tc publish git 30418
[ "$RC" = 0 ] && [ "${HP:-}" != "" ] && [[ "$(cat "$TMP/out")" == node.example.invalid:* ]] && ok "TOCKMOX_NODEPORT_HOST still names the host" || bad "nodeport host override" "rc=$RC $(both)"

# ============================================================ 4. the lane
L="$TMP/ltree/tests/executed-docs"; mkdir -p "$L/provision" "$TMP/lbin" "$TMP/gitstub"
cp "$LANE_SH" "$L/p09-lane.sh"
cat > "$L/provision/throwaway-cluster.sh" <<'STUB'
#!/usr/bin/env bash
echo "throwaway $* KUBECONFIG=${KUBECONFIG:-}" >> "$LANE_LOG"
case "$1" in
  create) echo apiVersion: v1 > "$LANE_TMP/guest.kubeconfig"; echo "$LANE_TMP/guest.kubeconfig" ;;
  publish) [ "${STUB_PUBLISH:-}" = fail ] && { echo "publish: stub failure" >&2; exit 1; }
           [ "${STUB_PUBLISH:-}" = failprint ] && { echo "${STUB_PUBLISH_HP:-node.stub.invalid:31234}"; exit 1; }
           [ "${STUB_PUBLISH:-}" = empty ] || echo "${STUB_PUBLISH_HP:-node.stub.invalid:31234}" ;;
  guard-file) echo "$LANE_TMP/voucher" ;;
esac
STUB
cat > "$L/provision/site-repo-server.sh" <<'STUB'
#!/usr/bin/env bash
echo "site-repo-server $* GUARD=${TOCKMOX_WRITABLE_GUARD:-}" >> "$LANE_LOG"
case "$1" in
  url) echo http://site-repo.stub/tockmox.git ;;
  nodeport) echo 30418 ;;
  up) [ "${2:-}" = --writable ] && [ "${STUB_UP:-}" = fail ] && exit 1 ;;
  reach) [ "${STUB_REACH:-}" = fail ] && exit 1 ;;
esac
exit 0
STUB
cat > "$L/run.sh" <<'STUB'
#!/usr/bin/env bash
echo "run.sh $*" >> "$LANE_LOG"
if [ "$1" = P09 ]; then
  env | grep '^TOCKMOX_P09_' > "$LANE_TMP/p09.env"
fi
case "$1" in P09) name=P09-install-md-end-to-end ;; P11) name=P11-fresh-install-recovery ;; P13) name=P13-planted-faults ;; *) exit 0 ;; esac
n="$(ls "$TOCKMOX_WORKDIR" | grep -c '^receipts-')"
d="$TOCKMOX_WORKDIR/receipts-$(printf %05d $((n+1)))"; mkdir -p "$d"
echo "PASS a stub reason" > "$d/$name"
exit 0
STUB
for t in helm kubeseal openssl zsh curl age age-keygen; do printf '#!/bin/sh\nexit 0\n' > "$TMP/lbin/$t"; done
cat > "$TMP/lbin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in *"config current-context"*) echo stub-guest ;; *"get nodes"*) echo node.stub.invalid ;; esac
STUB
# a git for the cases that do not start a daemon: init and commit work, ls-remote and push fail when told to
cat > "$TMP/gitstub/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$LANE_LOG"
case "$*" in
  *ls-remote*) [ "${STUB_GIT:-}" = ls-remote ] && exit 1 ;;
  *push*) [ "${STUB_GIT:-}" = push ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP/lbin"/* "$TMP/gitstub/git" "$L/provision"/*.sh "$L/run.sh"
LN=0
run_lane() { # VAR=value... -> output in $TMP/lout, status in $LRC, calls in $LH/log
  LN=$((LN+1)); LH="$TMP/lane-$LN"; mkdir -p "$LH/home" "$LH/work"; : > "$LH/log"
  local gp="$TMP/gitstub:" a
  for a in "$@"; do [ "$a" = LANE_REAL_GIT=1 ] && gp=""; done
  env -u TOCKMOX_KEEP_CLUSTER -u TOCKMOX_P09_ROUTE -u TOCKMOX_P09_SITE_REPO_URL "$@" HOME="$LH/home" TOCKMOX_WORKDIR="$LH/work" \
    LANE_LOG="$LH/log" LANE_TMP="$LH" PATH="${gp}$TMP/lbin:$PATH" KUBECONFIG="$LH/substrate.kubeconfig" TOCKMOX_DOCS_REF=stub \
    TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate TOCKMOX_TEST_VM=ed-lane \
    bash "${LANE_USE:-$L/p09-lane.sh}" > "$TMP/lout" 2>&1
  LRC=$?
}
logs() { grep -c -- "$1" "$LH/log"; }
say() { grep -F -- "$1" "$TMP/lout" >/dev/null; }
report() { cat "$LH"/work/report-p09-lane-*.txt 2>/dev/null; }

run_lane TOCKMOX_P09_ROUTE=external
[ "$LRC" = 0 ] && ok "external route, every step provided: the lane exits 0" || bad "external ok" "rc=$LRC $(tail -4 "$TMP/lout")"
ordered() { # PATTERN... each must appear in the lane's log, later than the one before
  local last=0 n pat
  for pat in "$@"; do
    n="$(grep -n -F -- "$pat" "$LH/log" | head -1 | cut -d: -f1)"
    [ -n "$n" ] && [ "$n" -gt "$last" ] || { echo "out of order or missing: $pat"; return 1; }
    last="$n"
  done
}
msg="$(ordered 'throwaway create' 'run.sh P04 P05' 'site-repo-server nodeport' 'throwaway publish git 30418' 'throwaway guard-file' 'site-repo-server up --writable' 'site-repo-server push' 'site-repo-server url' 'site-repo-server reach' 'run.sh P09' 'run.sh P11')" \
  && ok "the calls come in order: nodeport, publish git 30418, voucher, up --writable, push, url, reach, then P09" || bad "external call order" "$msg"
grep -F "throwaway publish git 30418 KUBECONFIG=$LH/substrate.kubeconfig" "$LH/log" >/dev/null && ok "publish is run with the hypervisor's credential, not the guest's" || bad "publish credential" "$(grep publish "$LH/log")"
grep -F "up --writable GUARD=$LH/voucher" "$LH/log" >/dev/null && ok "up --writable is given the voucher path that publish's sibling verb printed" || bad "voucher path" "$(grep 'up --writable' "$LH/log")"
grep -F "site-repo-server reach git://node.stub.invalid:31234/site.git" "$LH/log" >/dev/null && ok "the guest check reads the same URL the workstation will push to" || bad "reach url" "$(grep reach "$LH/log")"
[ "$(grep '^TOCKMOX_P09_SITE_REPO_URL=' "$LH/p09.env")" = "TOCKMOX_P09_SITE_REPO_URL=git://node.stub.invalid:31234/site.git" ] \
  && ok "P09 is run with TOCKMOX_P09_SITE_REPO_URL=git://<published host>:<nodePort>/site.git" || bad "exported URL" "$(cat "$LH/p09.env")"
grep -F 'TOCKMOX_P09_TOCKMOX_REPO_URL=http://site-repo.stub/tockmox.git' "$LH/p09.env" >/dev/null && ok "the product tree is still served at the daemon's in-cluster address" || bad "tockmox url" ""
# the real P09, against what the lane exported
run_p09() { # name, then env lines on stdin
  local envs=() v
  while IFS= read -r v; do envs+=("$v"); done
  mkdir -p "$TMP/p09bin" "$TMP/p09st-$1"
  for t in kubectl helm kubeseal zsh; do printf '#!/bin/sh\nexit 1\n' > "$TMP/p09bin/$t"; chmod +x "$TMP/p09bin/$t"; done
  ( cd "$HERE/../.." && env -i PATH="$TMP/p09bin:/usr/bin:/bin" HOME="$TMP" KUBE_CONTEXT=stub TOCKMOX_DOCS_REF=stub "${envs[@]}" \
    TOCKMOX_P09_ROUTE=external TOCKMOX_P09_BUDGET=0 TOCKMOX_P09_STATE="$TMP/p09st-$1" OUTCOME_RECEIPT_DIR="$TMP/p09rc-$1" bash "${P09_USE:-$P09}" > "$TMP/p09out-$1" 2>&1 )
  P9RC=$?
}
run_p09 with < "$LH/p09.env"
[ "$P9RC" = 75 ] && ! grep -F 'BLOCKED' "$TMP/p09out-with" >/dev/null && grep -F 'BUDGET:' "$TMP/p09out-with" >/dev/null \
  && ok "the real P09, given what the lane exported, passes its inputs check (no BLOCKED; it goes on to its first step and yields)" || bad "P09 with the URL" "rc=$P9RC $(tail -4 "$TMP/p09out-with")"
grep -v '^TOCKMOX_P09_SITE_REPO_URL=' "$LH/p09.env" > "$TMP/p09.env.without"; run_p09 without < "$TMP/p09.env.without"
[ "$P9RC" = 0 ] && grep -F 'Unset: TOCKMOX_P09_SITE_REPO_URL' "$TMP/p09out-without" >/dev/null \
  && ok "... and the same environment without that one variable is exactly what P09 declares BLOCKED (the check is real)" || bad "P09 without the URL" "rc=$P9RC $(tail -4 "$TMP/p09out-without")"

# the built-in route is untouched
run_lane TOCKMOX_P09_ROUTE=built-in
[ "$LRC" = 0 ] && ! grep -E 'publish|guard-file|nodeport|reach|--writable' "$LH/log" >/dev/null && grep -F 'site-repo-server up GUARD=' "$LH/log" >/dev/null \
  && ! grep '^TOCKMOX_P09_SITE_REPO_URL=' "$LH/p09.env" >/dev/null && ! grep -E '^git ' "$LH/log" >/dev/null \
  && ok "built-in route: plain up, no publish, no voucher, no reach, no git probe, and no site URL exported" || bad "built-in unchanged" "rc=$LRC $(cat "$LH/log")"
run_lane
[ "$LRC" = 0 ] && ! grep -E 'publish|--writable' "$LH/log" >/dev/null && ok "with no TOCKMOX_P09_ROUTE the lane's default (built-in) provisions no site remote" || bad "default route" "$(cat "$LH/log")"

# the caller's own forge
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_P09_SITE_REPO_URL=git://192.0.2.77/own.git
[ "$LRC" = 0 ] && ! grep -E 'publish|--writable|reach' "$LH/log" >/dev/null && grep -F 'TOCKMOX_P09_SITE_REPO_URL=git://192.0.2.77/own.git' "$LH/p09.env" >/dev/null && say 'is set by the caller' \
  && ok "a TOCKMOX_P09_SITE_REPO_URL the caller set is used as given and nothing is provisioned" || bad "caller URL" "rc=$LRC $(cat "$LH/log")"

# failures are INFRA_ERROR (5), named, and never reach P09
for c in "publish:STUB_PUBLISH=fail:throwaway-cluster.sh publish git 30418 failed" \
         "empty:STUB_PUBLISH=empty:throwaway-cluster.sh publish printed no host:port" \
         "up:STUB_UP=fail:site-repo-server.sh up --writable failed" \
         "runner-read:STUB_GIT=ls-remote:the workstation cannot read and push to git://node.stub.invalid:31234/site.git" \
         "runner-push:STUB_GIT=push:the workstation cannot read and push to git://node.stub.invalid:31234/site.git" \
         "reach:STUB_REACH=fail:the guest cannot read its own published address"; do
  nm="${c%%:*}"; rest="${c#*:}"; var="${rest%%:*}"; why="${rest#*:}"
  run_lane TOCKMOX_P09_ROUTE=external "$var"
  [ "$LRC" = 5 ] && say "lane: INFRA_ERROR: ${why}" && [ "$(logs '^run.sh P09')" = 0 ] && [ "$(logs '^throwaway destroy')" = 1 ] \
    && report | grep -F "lane: INFRA_ERROR: ${why}" >/dev/null \
    && ok "failure at ${nm}: the lane exits 5 naming it, writes it to the report, never runs P09 and destroys the VM" || bad "failure at ${nm}" "rc=$LRC $(tail -3 "$TMP/lout")"
done

# the runner check against a REAL daemon and the real git: writable passes, read-only is INFRA_ERROR
start_daemon "$SRS" --writable none; WP="$DPORT"
run_lane TOCKMOX_P09_ROUTE=external STUB_PUBLISH_HP="127.0.0.1:${WP}" LANE_REAL_GIT=1
[ "$LRC" = 0 ] && grep -F "TOCKMOX_P09_SITE_REPO_URL=git://127.0.0.1:${WP}/site.git" "$LH/p09.env" >/dev/null \
  && ok "real git against a real writable daemon: the lane's runner check passes and the URL is exported" || bad "real daemon, lane" "rc=$LRC $(tail -4 "$TMP/lout")"
start_daemon "$SRS" "" preseed; RP="$DPORT"
run_lane TOCKMOX_P09_ROUTE=external STUB_PUBLISH_HP="127.0.0.1:${RP}" LANE_REAL_GIT=1
[ "$LRC" = 5 ] && say "or the daemon refuses receive-pack" && [ "$(logs '^run.sh P09')" = 0 ] \
  && ok "real git against a read-only daemon: the lane exits 5 (the daemon refuses receive-pack) and P09 never runs" || bad "real daemon read-only, lane" "rc=$LRC $(tail -4 "$TMP/lout")"
run_lane TOCKMOX_P09_ROUTE=external STUB_PUBLISH_HP="127.0.0.1:$(free_port)" LANE_REAL_GIT=1
[ "$LRC" = 5 ] && ok "real git against a port nothing listens on: the lane exits 5" || bad "nothing listening" "rc=$LRC"

# ============================================================ 5. copies that lose one guard each
mutlane() { mut "$LANE_SH" "$L/p09-lane-m.sh" "$1" "$2"; LANE_USE="$L/p09-lane-m.sh"; }
# a: the URL is never exported
mutlane '  export TOCKMOX_P09_SITE_REPO_URL="$SITE_URL"' '  : "$SITE_URL"'
run_lane TOCKMOX_P09_ROUTE=external
if ! grep '^TOCKMOX_P09_SITE_REPO_URL=' "$LH/p09.env" >/dev/null; then
  run_p09 mutA < "$LH/p09.env"
  [ "$P9RC" = 0 ] && grep -F 'Unset: TOCKMOX_P09_SITE_REPO_URL' "$TMP/p09out-mutA" >/dev/null \
    && ok "mutation: a lane that never exports the URL leaves the real P09 declaring BLOCKED, which the cases above catch" || bad "mutation a" "rc=$P9RC"
else bad "mutation a" "the URL was still exported"; fi
# b: a failed publish is ignored
mutlane '    || infra "throwaway-cluster.sh publish git ${GIT_NP} failed' '    || : "throwaway-cluster.sh publish git ${GIT_NP} failed'
run_lane TOCKMOX_P09_ROUTE=external STUB_PUBLISH=failprint
[ "$LRC" != 5 ] && ok "mutation: a lane that ignores a failed publish no longer exits 5 (the publish case above is the guard)" || bad "mutation b" "rc=$LRC"
# c: a failed up --writable is ignored
mutlane '    || infra "site-repo-server.sh up --writable failed' '    || : "site-repo-server.sh up --writable failed'
run_lane TOCKMOX_P09_ROUTE=external STUB_UP=fail
[ "$LRC" != 5 ] && ok "mutation: a lane that ignores a failed up --writable no longer exits 5" || bad "mutation c" "rc=$LRC"
# d: INFRA_ERROR is 1
mutlane 'STOPPED="lane: INFRA_ERROR: $1"; echo "$STOPPED" >&2; exit 5; }' 'STOPPED="lane: INFRA_ERROR: $1"; echo "$STOPPED" >&2; exit 1; }'
run_lane TOCKMOX_P09_ROUTE=external STUB_PUBLISH=fail
[ "$LRC" = 1 ] && ok "mutation: infra() exiting 1 is caught by the exit-5 cases" || bad "mutation d" "rc=$LRC"
# e: the built-in route provisions the remote too
mutlane 'if [ "$ROUTE" = external ]; then
  if [ -n "${TOCKMOX_P09_SITE_REPO_URL:-}" ]; then' 'if true; then
  if [ -n "${TOCKMOX_P09_SITE_REPO_URL:-}" ]; then'
run_lane TOCKMOX_P09_ROUTE=built-in
grep -E 'publish|--writable' "$LH/log" >/dev/null && ok "mutation: a lane that provisions the remote on the built-in route is caught by the built-in case" || bad "mutation e" "$(cat "$LH/log")"
# f: the guest check is dropped
mutlane '    || infra "the guest cannot read its own published address' '    || : "the guest cannot read its own published address'
run_lane TOCKMOX_P09_ROUTE=external STUB_REACH=fail
[ "$LRC" != 5 ] && ok "mutation: a lane that ignores the guest check (the hairpin) no longer exits 5" || bad "mutation f" "rc=$LRC"
# g: the runner check is dropped
mutlane '    || infra "the workstation cannot read and push to' '    || : "the workstation cannot read and push to'
run_lane TOCKMOX_P09_ROUTE=external STUB_GIT=push
[ "$LRC" != 5 ] && ok "mutation: a lane that ignores the runner check no longer exits 5" || bad "mutation g" "rc=$LRC"
# h: a caller's URL is overwritten
mutlane '  if [ -n "${TOCKMOX_P09_SITE_REPO_URL:-}" ]; then' '  if false; then'
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_P09_SITE_REPO_URL=git://192.0.2.77/own.git
grep -F 'publish' "$LH/log" >/dev/null && ok "mutation: a lane that overrides the caller's own URL is caught" || bad "mutation h" "$(cat "$LH/log")"
LANE_USE=""
# the dry run is dropped from the runner check: a read-only daemon is then accepted
mut "$LANE_SH" "$L/p09-lane-m.sh" 'git push --dry-run "$1" HEAD:refs/heads/lane-probe >/dev/null 2>&1 )' 'true )'
LANE_USE="$L/p09-lane-m.sh"
run_lane TOCKMOX_P09_ROUTE=external STUB_PUBLISH_HP="127.0.0.1:${RP}" LANE_REAL_GIT=1
[ "$LRC" != 5 ] && ok "mutation: a runner check that never tries a push passes a read-only daemon (the real-daemon case above is the guard)" || bad "mutation dry run" "rc=$LRC"
LANE_USE=""

# site-repo-server copies
voucher
mut "$SRS" "$TMP/srs-m1.sh" '  if [ "$ctx" != "$KUBE_CONTEXT" ]; then' '  if false; then'
voucher other-ctx; reset_k; SRS_USE="$TMP/srs-m1.sh" TOCKMOX_WRITABLE_GUARD="$TMP/voucher" run_srs up --writable
[ "$RC" = 0 ] && ok "mutation: without the context comparison a voucher for another cluster is accepted (the wrong-context case above is the guard)" || bad "mutation srs ctx" "rc=$RC"
mut "$SRS" "$TMP/srs-m2.sh" '  if [ -z "$g" ] || [ ! -s "$g" ]; then' '  if false; then'
reset_k; SRS_USE="$TMP/srs-m2.sh" TOCKMOX_WRITABLE_GUARD="" run_srs up --writable
! grep -F 'unauthenticated writable git daemon' "$TMP/err" >/dev/null && ok "mutation: without the first voucher check the refusal loses its explanation (the no-voucher case above reads it)" || bad "mutation srs voucher" "rc=$RC"
mut "$SRS" "$TMP/srs-m4.sh" '  if [ -z "$ns" ] || [ -z "$ctx" ]; then' '  if false; then'
printf 'guest-context=guest-ctx\n' > "$TMP/voucher"; reset_k; SRS_USE="$TMP/srs-m4.sh" TOCKMOX_WRITABLE_GUARD="$TMP/voucher" run_srs up --writable
[ "$RC" = 0 ] && ok "mutation: without the namespace check a voucher that names no disposable namespace is accepted (the case above is the guard)" || bad "mutation srs namespace" "rc=$RC"
mut "$SRS" "$TMP/srs-m3.sh" '    writable_guard
  fi' '    :
  fi'
reset_k; SRS_USE="$TMP/srs-m3.sh" TOCKMOX_WRITABLE_GUARD="" run_srs up --writable
[ "$RC" != 2 ] && ok "mutation: a cmd_up that never calls the guard starts with none" || bad "mutation srs call" "rc=$RC"
unset SRS_USE

# throwaway-cluster copies (in a copy of the provision directory: the script sources files beside itself)
mkdir -p "$TMP/edcopy"; cp -r "$HERE/provision" "$HERE/lib" "$TMP/edcopy/"
mut "$TC" "$TMP/edcopy/provision/m1.sh" '  delete_owned svc -l tockmox.com/harness=executed-docs 2>/dev/null || true' '  :'
reset_store; run_tc publish git 30418; TC_USE="$TMP/edcopy/provision/m1.sh" run_tc destroy
has_svc ed-run-git && grep -F 'ARTEFACT: services owned by ed-run' "$TMP/out" >/dev/null && ! grep '^RESULT:   PASS' "$TMP/out" >/dev/null \
  && ok "mutation: a destroy that does not delete owned Services leaves ed-run-git and does not report PASS" || bad "mutation destroy" "rc=$RC $(tail -3 "$TMP/out") $(tail -3 "$TMP/err")"
mut "$TC" "$TMP/edcopy/provision/m2.sh" '  svc="${VM_NAME}-${name}"' '  svc="${name}"'
reset_store; TC_USE="$TMP/edcopy/provision/m2.sh" run_tc publish git 30418
[ "$RC" = 0 ] && [ -f "$TMP/store/svc/git" ] && ! has_svc ed-run-git && ok "mutation: a Service not named after the VM is not ed-run-git (the name case above is the guard)" || bad "mutation service name" "rc=$RC $(cat "$TMP/err")"
mut "$TC" "$TMP/edcopy/provision/m3.sh" '  if [ "$NETWORK" != pod ]; then
    echo "REFUSING: publish' '  if false; then
    echo "REFUSING: publish'
reset_store; TC_USE="$TMP/edcopy/provision/m3.sh" TOCKMOX_VM_NETWORK=tockmox-test/segment run_tc publish git 30418
[ "$RC" = 0 ] && has_svc ed-run-git && ok "mutation: without the pod-network check publish runs on a routable segment (the network case above is the guard)" || bad "mutation network" "rc=$RC $(cat "$TMP/err")"
mut "$TC" "$TMP/edcopy/provision/m4.sh" '      && mv "${guard}.tmp" "$guard" )' '      && : )'
reset_store; TC_USE="$TMP/edcopy/provision/m4.sh" run_tc publish git 30418
[ "$RC" = 0 ] && has_svc ed-run-git && [ ! -e "$TMP/tw/ed-run.writable-guard" ] && ok "mutation: a publish that never writes the voucher leaves none (the voucher case above is the guard)" || bad "mutation voucher" "rc=$RC $(cat "$TMP/err")"
mut "$TC" "$TMP/edcopy/provision/m5.sh" ' "$(guard_path)" "$(guard_path).tmp"
  # Assert the teardown' '
  # Assert the teardown'
reset_store; run_tc publish git 30418; TC_USE="$TMP/edcopy/provision/m5.sh" run_tc destroy
[ "$RC" = 0 ] && [ -e "$TMP/tw/ed-run.writable-guard" ] && ok "mutation: a destroy that keeps the voucher leaves it behind (the destroy case above is the guard)" || bad "mutation destroy voucher" "rc=$RC $(tail -3 "$TMP/err")"
mut "$TC" "$TMP/edcopy/provision/m6.sh" '  if ! kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm "$VM_NAME" -o name >/dev/null 2>&1; then
    echo "REFUSING: publish' '  if false; then
    echo "REFUSING: publish'
reset_store; printf 'current-context: guest-ctx\n' > "$TMP/tw/ed-gone.kubeconfig"; TC_USE="$TMP/edcopy/provision/m6.sh" VM=ed-gone run_tc publish git 30418
[ "$RC" = 0 ] && has_svc ed-gone-git && ok "mutation: without the VM check publish leaves an orphan Service (the no-VM case above is the guard)" || bad "mutation no vm" "rc=$RC $(cat "$TMP/err")"
mut "$TC" "$TMP/edcopy/provision/m7.sh" '    vm.kubevirt.io/name: ${VM_NAME}
  ports:
    - name: ${name}' '    vm.kubevirt.io/name: nothing
  ports:
    - name: ${name}'
reset_store; TC_USE="$TMP/edcopy/provision/m7.sh" run_tc publish git 30418
! grep -F 'vm.kubevirt.io/name: ed-run' "$TMP/store/svc/ed-run-git" >/dev/null && [ "$RC" = 0 ] && ok "mutation: a Service that does not select the VM is not the one the selector case above accepts" || bad "mutation selector" "rc=$RC"
unset TC_USE

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

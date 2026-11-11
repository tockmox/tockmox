#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for the recovery kit of a kept throwaway: throwaway-cluster.sh
# kit-store and kit, destroy and sweep taking the kit Secret with the VM, and
# step 5 of p09-lane.sh. No cluster: kubectl is a stub that keeps Secrets as
# files and logs every call, age is a stub that "opens" a kit when the identity
# is the right one, and the provisioner and the lane run unmodified against them.
#
#   1. kit-store keeps a kit and its identity as ${VM}-kit, labelled for destroy;
#      it refuses a pair that does not open, a missing file, an oversized file
#      and a VM that does not exist, and leaves nothing behind when a step fails
#   2. kit writes both files back byte for byte, private to the caller, never
#      over an existing file, and leaves nothing when a read fails
#   3. destroy and sweep delete the kit with the VM, labelled or not, and sweep
#      leaves a kept VM's kit alone
#   4. the lane keeps the kit of a kept built-in run and no other, with the
#      hypervisor's credential, and says so in its exit and report when it cannot
#
#   ./tests/executed-docs/kit-keep-test.sh
#   TC=/path/to/throwaway-cluster.sh LANE_SH=/path/to/p09-lane.sh ./tests/executed-docs/kit-keep-test.sh
#
# TC and LANE_SH point the cases at other copies, to show they go red there.
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # stub bodies and greps are literal text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
LANE_SH="${LANE_SH:-${HERE}/p09-lane.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

mkdir -p "$TMP/bin" "$TMP/kbin" "$TMP/work" "$TMP/store/secrets"
cat > "$TMP/kbin/kubectl" <<'STUB'
#!/usr/bin/env python3
# A kubectl that keeps Secrets as directories of files under $KT_STORE/secrets and VMs as
# rows of $KT_STORE/vms (name, creation time, keep-until). KT_FAIL names steps that fail.
import base64, os, shutil, sys
with open(os.environ["KT_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
a = [x for x in sys.argv[1:] if not x.startswith("--context=")]
if "-n" in a:
    i = a.index("-n"); del a[i:i + 2]
store = os.environ["KT_STORE"]
sec = os.path.join(store, "secrets")
vms = os.path.join(store, "vms")
fail = os.environ.get("KT_FAIL", "").split()
def rows():
    return [l.split() for l in open(vms) if l.strip()] if os.path.exists(vms) else []
def refused(what):
    sys.stderr.write("Error from server (Forbidden): %s is forbidden (stub)\n" % what); sys.exit(1)
def absent(what):
    sys.stderr.write('Error from server (NotFound): %s not found\n' % what); sys.exit(1)
if a[:2] == ["get", "vm"]:
    if len(a) > 2 and not a[2].startswith("-"):
        sys.exit(0) if any(r[0] == a[2] for r in rows()) else absent('virtualmachine "%s"' % a[2])
    wide = any("creationTimestamp" in x for x in a)
    for r in rows():
        print(" ".join(r) if wide else r[0])
elif a[:2] == ["delete", "vm"]:
    keep = [r for r in rows() if r[0] != a[2]]
    with open(vms, "w") as f:
        f.write("".join(" ".join(r) + "\n" for r in keep))
elif a[:2] == ["get", "secret"]:
    if len(a) < 3 or a[2].startswith("-"):
        for n in sorted(os.listdir(sec)):
            if "-l" not in a or os.path.exists(os.path.join(sec, n, ".labels")):
                print(n)
        sys.exit(0)
    d = os.path.join(sec, a[2])
    if not os.path.isdir(d):
        absent('secrets "%s"' % a[2])
    fmt = a[a.index("-o") + 1] if "-o" in a else ""
    if fmt == "name":
        print("secret/" + a[2])
    elif fmt.startswith("jsonpath={.data."):
        key = fmt[len("jsonpath={.data."):-1]
        if "read-" + key in fail:
            refused("secrets")
        p = os.path.join(d, key)
        if os.path.exists(p):
            sys.stdout.write(base64.b64encode(open(p, "rb").read()).decode())
elif a[:2] == ["delete", "secret"]:
    if "delete-secret" in fail:
        refused("secrets")
    for n in [x for x in a[2:] if not x.startswith("-")]:
        if os.path.isdir(os.path.join(sec, n)):
            shutil.rmtree(os.path.join(sec, n)); print('secret "%s" deleted' % n)
elif a[:3] == ["create", "secret", "generic"]:
    if "create-secret" in fail:
        refused("secrets")
    d = os.path.join(sec, a[3]); os.makedirs(d)
    for x in a[4:]:
        if x.startswith("--from-file="):
            k, p = x[len("--from-file="):].split("=", 1)
            shutil.copyfile(p, os.path.join(d, k))
    print("secret/%s created" % a[3])
elif a[:2] == ["label", "secret"]:
    if "label-secret" in fail:
        refused("secrets")
    open(os.path.join(sec, a[2], ".labels"), "w").write(" ".join(a[3:]))
elif a[:1] == ["api-resources"]:
    print("virtualmachines   vm,vms   kubevirt.io/v1   true   VirtualMachine")
STUB
# age -d -i IDENTITY KIT: the kit's first line stands for the ciphertext header; the right
# identity gets everything after it, any other gets nothing and a failure.
cat > "$TMP/bin/age" <<'STUB'
#!/bin/sh
[ "$1" = -d ] && [ "$2" = -i ] || exit 2
grep '^AGE-SECRET-KEY-RIGHT$' "$3" >/dev/null || exit 1
sed 1d "$4"
STUB
chmod +x "$TMP/kbin/kubectl" "$TMP/bin/age"

# A PATH holding everything this one holds except age, for the "no age on PATH" cases: they
# need it gone even on a machine that has it installed.
mkdir -p "$TMP/noage"
IFS=: read -r -a _dirs <<EOF_PATH
$PATH
EOF_PATH
for _d in "${_dirs[@]}"; do
  [ -d "$_d" ] && ln -s "$_d"/* "$TMP/noage/" 2>/dev/null
done
rm -f "$TMP/noage/age" "$TMP/noage/age-keygen"

# Fixtures. The first line carries bytes that are not text, so "byte for byte" means it.
{ printf 'age-encryption.org/v1 \000\001\377\376 stub\n# tockmox-recovery-kit v1\n=== app.ini\n[server]\n=== forge-admin\nadmin\nnot-a-real-password\n=== end\n'; } > "$TMP/kit.age"
{ printf 'age-encryption.org/v1 \000\001\377\376 stub\n# tockmox-recovery-kit v1\n=== app.ini\n[server]\n'; } > "$TMP/kit-cut.age"
{ printf 'age-encryption.org/v1 \000\001\377\376 stub\nsome other file sealed to the same identity\n=== end\n'; } > "$TMP/not-a-kit.age"
printf '# created: by the stub\nAGE-SECRET-KEY-RIGHT\n' > "$TMP/id.txt"
printf '# created: by the stub\nAGE-SECRET-KEY-OTHER\n' > "$TMP/id-other.txt"
stamp() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
now="$(date -u +%s)"; OLD="$(stamp -300)"
reset_store() {
  rm -rf "$TMP/store"; mkdir -p "$TMP/store/secrets"; : > "$TMP/log"
  printf 'ed-run %s <none>\n' "$OLD" > "$TMP/store/vms"
}
has_secret() { [ -d "$TMP/store/secrets/$1" ]; }

run_tc() {  # verb args... -> stdout in $TMP/out, stderr in $TMP/err, status in $RC
  KT_LOG="$TMP/log" KT_STORE="$TMP/store" PATH="${TC_PATH:-$TMP/kbin:$TMP/bin:$PATH}" TMPDIR="$TMP/work" \
    TOCKMOX_SUBSTRATE_CONTEXT=stub TOCKMOX_TEST_NAMESPACE=tockmox-test TOCKMOX_TEST_VM="${VM:-ed-run}" \
    bash "$TC" "$@" > "$TMP/out" 2> "$TMP/err"
  RC=$?
}
both() { cat "$TMP/out" "$TMP/err"; }

# ---------------------------------------------------------------------------
# 1. kit-store
reset_store; run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"
[ "$RC" = 0 ] && cmp -s "$TMP/kit.age" "$TMP/store/secrets/ed-run-kit/kit" && cmp -s "$TMP/id.txt" "$TMP/store/secrets/ed-run-kit/identity" \
  && ok "kit-store keeps the kit and its identity as the Secret <VM>-kit" \
  || bad "kit-store keeps the kit and its identity as the Secret <VM>-kit" "rc=$RC $(both | tail -3)"
grep -F 'tockmox.com/harness=executed-docs' "$TMP/store/secrets/ed-run-kit/.labels" >/dev/null 2>&1 \
  && ok "the kit Secret carries the harness label, so destroy's sweep owns it" \
  || bad "the kit Secret carries the harness label, so destroy's sweep owns it" "$(cat "$TMP/log")"
grep -F "kept as tockmox-test/ed-run-kit; its identity opens it" "$TMP/err" >/dev/null \
  && ok "kit-store says the identity opens the kit it kept" || bad "kit-store says the identity opens the kit it kept" "$(cat "$TMP/err")"
! both | grep -E 'not-a-real-password|AGE-SECRET-KEY' >/dev/null \
  && ok "kit-store prints neither the kit nor the identity" || bad "kit-store prints neither the kit nor the identity" "$(both)"

reset_store; run_tc kit-store "$TMP/kit.age" "$TMP/id-other.txt"
[ "$RC" = 2 ] && ! has_secret ed-run-kit && grep '^REFUSING: .*does not open' "$TMP/err" >/dev/null \
  && ok "kit-store refuses an identity that does not open the kit, and keeps nothing" \
  || bad "kit-store refuses an identity that does not open the kit, and keeps nothing" "rc=$RC $(both | tail -3)"
reset_store; run_tc kit-store "$TMP/kit-cut.age" "$TMP/id.txt"
[ "$RC" = 2 ] && ! has_secret ed-run-kit \
  && ok "kit-store refuses a kit that was cut short" || bad "kit-store refuses a kit that was cut short" "rc=$RC $(both | tail -3)"
reset_store; run_tc kit-store "$TMP/not-a-kit.age" "$TMP/id.txt"
[ "$RC" = 2 ] && ! has_secret ed-run-kit \
  && ok "kit-store refuses a file that opens but is not a recovery kit" || bad "kit-store refuses a file that opens but is not a recovery kit" "rc=$RC $(both | tail -3)"
reset_store; run_tc kit-store "$TMP/no-such-kit" "$TMP/id.txt"
[ "$RC" = 2 ] && grep '^REFUSING: there is no recovery kit' "$TMP/err" >/dev/null \
  && ok "kit-store refuses when there is no kit file" || bad "kit-store refuses when there is no kit file" "rc=$RC $(both | tail -3)"
reset_store; run_tc kit-store "$TMP/kit.age"
[ "$RC" = 2 ] && grep '^REFUSING: kit-store needs two files' "$TMP/err" >/dev/null \
  && ok "kit-store refuses without the identity argument" || bad "kit-store refuses without the identity argument" "rc=$RC $(both | tail -3)"
python3 -c 'import sys; open(sys.argv[1], "wb").write(open(sys.argv[2], "rb").read() + b"x" * 800000)' "$TMP/kit-big.age" "$TMP/kit.age"
reset_store; run_tc kit-store "$TMP/kit-big.age" "$TMP/id.txt"
[ "$RC" = 2 ] && ! has_secret ed-run-kit && grep '^REFUSING: .*bytes together' "$TMP/err" >/dev/null \
  && ok "kit-store refuses a file too large for a Secret" || bad "kit-store refuses a file too large for a Secret" "rc=$RC $(both | tail -3)"
reset_store; VM=ed-gone run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"
[ "$RC" = 2 ] && ! has_secret ed-gone-kit && grep '^REFUSING: tockmox-test/ed-gone does not exist' "$TMP/err" >/dev/null \
  && ok "kit-store refuses when the VM does not exist: nothing would delete an orphan kit" \
  || bad "kit-store refuses when the VM does not exist: nothing would delete an orphan kit" "rc=$RC $(both | tail -3)"
reset_store; KT_FAIL=create-secret run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"
[ "$RC" = 1 ] && ! has_secret ed-run-kit && grep '^kit-store: FAILED to create' "$TMP/err" >/dev/null \
  && ok "a refused create is a failure that names the Secret" || bad "a refused create is a failure that names the Secret" "rc=$RC $(both | tail -3)"
reset_store; KT_FAIL=label-secret run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"
[ "$RC" = 1 ] && ! has_secret ed-run-kit \
  && ok "a kit whose label is refused is removed again, never left unlabelled" \
  || bad "a kit whose label is refused is removed again, never left unlabelled" "rc=$RC $(ls "$TMP/store/secrets") $(both | tail -3)"
reset_store; mkdir -p "$TMP/store/secrets/ed-run-kit"; echo stale > "$TMP/store/secrets/ed-run-kit/kit"
run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"
[ "$RC" = 0 ] && cmp -s "$TMP/kit.age" "$TMP/store/secrets/ed-run-kit/kit" \
  && ok "kit-store replaces an earlier kit under the same name" || bad "kit-store replaces an earlier kit under the same name" "rc=$RC $(both | tail -3)"
reset_store; TC_PATH="$TMP/kbin:$TMP/noage" run_tc kit-store "$TMP/kit.age" "$TMP/id-other.txt"
[ "$RC" = 0 ] && has_secret ed-run-kit && grep -F 'NOT checked that its identity opens it (no age on PATH)' "$TMP/err" >/dev/null \
  && ok "without age on PATH kit-store keeps the pair and says it was not checked" \
  || bad "without age on PATH kit-store keeps the pair and says it was not checked" "rc=$RC $(both | tail -3)"

# ---------------------------------------------------------------------------
# 2. kit
reset_store; run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"
run_tc kit "$TMP/got"
[ "$RC" = 0 ] && cmp -s "$TMP/kit.age" "$TMP/got/tockmox-recovery-kit.tar.age" && cmp -s "$TMP/id.txt" "$TMP/got/p09-age-identity.txt" \
  && ok "kit writes back the kit and the identity byte for byte" \
  || bad "kit writes back the kit and the identity byte for byte" "rc=$RC $(both | tail -3)"
[ "$(cat "$TMP/out")" = "$TMP/got/tockmox-recovery-kit.tar.age
$TMP/got/p09-age-identity.txt" ] && ok "kit prints the two paths and nothing else on stdout" \
  || bad "kit prints the two paths and nothing else on stdout" "$(cat "$TMP/out")"
modes="$(python3 -c 'import os,sys; print(" ".join(oct(os.stat(p).st_mode & 0o777) for p in sys.argv[1:]))' "$TMP/got" "$TMP/got/tockmox-recovery-kit.tar.age" "$TMP/got/p09-age-identity.txt" 2>/dev/null)"
[ "$modes" = "0o700 0o600 0o600" ] && ok "a directory kit makes, and both files, are the caller's alone" \
  || bad "a directory kit makes, and both files, are the caller's alone" "$modes"
grep -F 'the identity opens the kit' "$TMP/err" >/dev/null && ! both | grep -E 'not-a-real-password|AGE-SECRET-KEY' >/dev/null \
  && ok "kit says the identity opens the kit, and prints neither" || bad "kit says the identity opens the kit, and prints neither" "$(both)"
run_tc kit "$TMP/got"
[ "$RC" = 2 ] && grep '^REFUSING: .*already exists, and a kit is never written over' "$TMP/err" >/dev/null \
  && cmp -s "$TMP/kit.age" "$TMP/got/tockmox-recovery-kit.tar.age" \
  && ok "kit never writes over a kit that is already there" || bad "kit never writes over a kit that is already there" "rc=$RC $(both | tail -3)"
mkdir -p "$TMP/mine"; chmod 755 "$TMP/mine"; run_tc kit "$TMP/mine"
[ "$RC" = 0 ] && [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$TMP/mine")" = 0o755 ] \
  && ok "a directory that already exists keeps its mode" || bad "a directory that already exists keeps its mode" "rc=$RC $(both | tail -3)"
run_tc kit
[ "$RC" = 2 ] && grep '^REFUSING: kit needs a directory' "$TMP/err" >/dev/null \
  && ok "kit refuses without a directory" || bad "kit refuses without a directory" "rc=$RC $(both | tail -3)"
VM=ed-other run_tc kit "$TMP/none"
[ "$RC" = 2 ] && [ ! -e "$TMP/none" ] && grep '^REFUSING: could not read tockmox-test/ed-other-kit' "$TMP/err" >/dev/null \
  && ok "kit refuses, naming the Secret, when the VM has no kit" || bad "kit refuses, naming the Secret, when the VM has no kit" "rc=$RC $(both | tail -3)"
KT_FAIL=read-identity run_tc kit "$TMP/half"
[ "$RC" = 1 ] && [ ! -e "$TMP/half" ] && grep "^kit: FAILED to read key 'identity'" "$TMP/err" >/dev/null \
  && ok "a read that fails half way leaves no kit without its identity" \
  || bad "a read that fails half way leaves no kit without its identity" "rc=$RC $(ls -A "$TMP/half" 2>/dev/null) $(both | tail -3)"
cp "$TMP/id-other.txt" "$TMP/store/secrets/ed-run-kit/identity" 2>/dev/null; run_tc kit "$TMP/wrong"
[ "$RC" = 1 ] && grep '^kit: FAILED: the identity .* does not open the kit' "$TMP/err" >/dev/null \
  && ok "kit fails when the identity it fetched does not open the kit" \
  || bad "kit fails when the identity it fetched does not open the kit" "rc=$RC $(both | tail -3)"
TC_PATH="$TMP/kbin:$TMP/noage" run_tc kit "$TMP/unchecked"
[ "$RC" = 0 ] && grep -F 'NOT checked that the identity opens the kit (no age on PATH)' "$TMP/err" >/dev/null \
  && ok "without age on PATH kit fetches the pair and says it was not checked" \
  || bad "without age on PATH kit fetches the pair and says it was not checked" "rc=$RC $(both | tail -3)"

# ---------------------------------------------------------------------------
# 3. destroy and sweep
reset_store; run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"; : > "$TMP/log"
run_tc destroy
[ "$RC" = 0 ] && ! has_secret ed-run-kit && grep '^RESULT:   PASS' "$TMP/out" >/dev/null \
  && ok "destroy deletes the kit with the VM" || bad "destroy deletes the kit with the VM" "rc=$RC $(both | tail -4)"
reset_store; mkdir -p "$TMP/store/secrets/ed-run-kit"; cp "$TMP/kit.age" "$TMP/store/secrets/ed-run-kit/kit"
run_tc destroy
[ "$RC" = 0 ] && ! has_secret ed-run-kit && grep -E 'delete secret .*ed-run-kit' "$TMP/log" >/dev/null \
  && ok "destroy deletes a kit by name even when its label never landed" \
  || bad "destroy deletes a kit by name even when its label never landed" "rc=$RC $(both | tail -4)"
reset_store
{ printf 'ed-old %s <none>\n' "$OLD"; printf 'ed-kept %s %s\n' "$OLD" "$((now + 3600))"; } > "$TMP/store/vms"
VM=ed-old run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"; VM=ed-kept run_tc kit-store "$TMP/kit.age" "$TMP/id.txt"
run_tc sweep ed- 120
! has_secret ed-old-kit && ok "sweep deletes the kit of a VM it destroys" \
  || bad "sweep deletes the kit of a VM it destroys" "$(ls "$TMP/store/secrets") $(both | tail -4)"
has_secret ed-kept-kit && ok "sweep leaves the kit of a VM it leaves alone" \
  || bad "sweep leaves the kit of a VM it leaves alone" "$(ls "$TMP/store/secrets") $(both | tail -4)"

# ---------------------------------------------------------------------------
# 4. the lane's step 5. The lane runs unmodified in a copy of the tree's shape, beside stubs of
# what it calls: the provisioner (create prints a kubeconfig path; kit-store exits as told and
# logs the KUBECONFIG it was given), site-repo-server.sh, and run.sh, whose P09 writes a kit and
# an identity where P09 writes them when told to.
L="$TMP/tree/tests/executed-docs"
mkdir -p "$L/provision" "$TMP/lbin"
cp "$LANE_SH" "$L/p09-lane.sh"
cat > "$L/provision/throwaway-cluster.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s KUBECONFIG=%s\n' "$*" "${KUBECONFIG-unset}" >> "$LANE_LOG"
case "$1" in
  create) : > "$LANE_TMP/guest.kubeconfig"; echo apiVersion: v1 > "$LANE_TMP/guest.kubeconfig"; echo "$LANE_TMP/guest.kubeconfig" ;;
  kit-store) exit "${STUB_KITSTORE_RC:-0}" ;;
  publish) echo node.stub.invalid:31234 ;;
  guard-file) echo "$LANE_TMP/guard" ;;
esac
STUB
cat > "$L/provision/site-repo-server.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = url ] && echo "http://site-repo.stub/tockmox.git"
[ "$1" = nodeport ] && echo 30418
exit 0
STUB
cat > "$L/run.sh" <<'STUB'
#!/usr/bin/env bash
# a real run.sh leaves a PASS receipt for a path that passed; the lane reads it (p09-lane.sh, lane_receipt)
rcpt() {
  local n f
  n="$(ls "$TOCKMOX_WORKDIR" | grep -c '^receipts-')"
  mkdir -p "$TOCKMOX_WORKDIR/receipts-$(printf %05d $((n+1)))"
  case "$1" in P09) f=P09-install-md-end-to-end ;; P11) f=P11-fresh-install-recovery ;; P13) f=P13-planted-faults ;; *) return 0 ;; esac
  echo PASS > "$TOCKMOX_WORKDIR/receipts-$(printf %05d $((n+1)))/$f"
}
[ "$1" = P09 ] || { rcpt "$1"; exit 0; }
if [ "${STUB_P09_KIT:-1}" = 1 ]; then
  mkdir -p "$HOME/tockmox-backup" "$TOCKMOX_P09_STATE"
  echo kit > "$HOME/tockmox-backup/tockmox-recovery-kit.tar.age"
  echo identity > "$TOCKMOX_P09_STATE/p09-age-identity.txt"
fi
[ "${STUB_P09_RC:-0}" != 0 ] || rcpt P09
exit "${STUB_P09_RC:-0}"
STUB
# The lane checks its tools are on PATH; only kubectl answers anything here.
for t in helm kubeseal openssl zsh curl age age-keygen git; do printf '#!/bin/sh\nexit 0\n' > "$TMP/lbin/$t"; done
cat > "$TMP/lbin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *"config current-context"*) echo stub-guest ;;
  *"get nodes"*) echo node.stub.invalid ;;
esac
STUB
chmod +x "$TMP/lbin"/*

LN=0
run_lane() {  # VAR=value... -> output in $TMP/lout, status in $RC, a fresh HOME and workdir per case
  LN=$((LN+1)); LH="$TMP/lane-$LN"; mkdir -p "$LH/home" "$LH/work"; : > "$LH/log"
  [ -z "${PRE_KIT:-}" ] || { mkdir -p "$LH/home/tockmox-backup" "$LH/work/p09-lane/p09-state"
    echo old > "$LH/home/tockmox-backup/tockmox-recovery-kit.tar.age"; echo old > "$LH/work/p09-lane/p09-state/p09-age-identity.txt"
    touch -t 202001010000 "$LH/home/tockmox-backup/tockmox-recovery-kit.tar.age"; }
  env "$@" HOME="$LH/home" TOCKMOX_WORKDIR="$LH/work" LANE_LOG="$LH/log" LANE_TMP="$LH" PATH="$TMP/lbin:$PATH" \
    KUBECONFIG="$LH/substrate.kubeconfig" TOCKMOX_DOCS_REF=stub TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate \
    TOCKMOX_TEST_NAMESPACE=tockmox-test TOCKMOX_TEST_VM=ed-lane \
    bash "$L/p09-lane.sh" > "$TMP/lout" 2>&1
  RC=$?
}
stored() { grep -c '^kit-store ' "$LH/log"; }

run_lane TOCKMOX_KEEP_CLUSTER=1
[ "$RC" = 0 ] && [ "$(stored)" = 1 ] \
  && grep -F "kit-store $LH/home/tockmox-backup/tockmox-recovery-kit.tar.age $LH/work/p09-lane/p09-state/p09-age-identity.txt KUBECONFIG=$LH/substrate.kubeconfig" "$LH/log" >/dev/null \
  && ok "a kept built-in run keeps P09's kit and identity, with the hypervisor's credential" \
  || bad "a kept built-in run keeps P09's kit and identity, with the hypervisor's credential" "rc=$RC $(cat "$LH/log") $(tail -3 "$TMP/lout")"
grep '^destroy ' "$LH/log" >/dev/null && bad "a kept run is not destroyed" "$(cat "$LH/log")" || ok "a kept run is not destroyed"
run_lane TOCKMOX_KEEP_CLUSTER=0
[ "$RC" = 0 ] && [ "$(stored)" = 0 ] && grep '^destroy ' "$LH/log" >/dev/null \
  && ok "a run that is not kept keeps no kit: its VM is destroyed" || bad "a run that is not kept keeps no kit: its VM is destroyed" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_KEEP_CLUSTER=1 TOCKMOX_P09_ROUTE=external
[ "$RC" = 0 ] && [ "$(stored)" = 0 ] \
  && ok "a kept run on your own forge keeps no kit: that route makes none" || bad "a kept run on your own forge keeps no kit: that route makes none" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_KEEP_CLUSTER=1 STUB_P09_KIT=0 STUB_P09_RC=1
[ "$RC" = 1 ] && [ "$(stored)" = 0 ] && grep -F 'P09 did not get as far as a recovery kit' "$TMP/lout" >/dev/null \
  && ok "a P09 that made no kit keeps none, says so, and the exit stays P09's" \
  || bad "a P09 that made no kit keeps none, says so, and the exit stays P09's" "rc=$RC $(tail -3 "$TMP/lout")"
PRE_KIT=1 run_lane TOCKMOX_KEEP_CLUSTER=1 STUB_P09_KIT=0 STUB_P09_RC=1
[ "$RC" = 1 ] && [ "$(stored)" = 0 ] && grep -F 'is older than this run' "$TMP/lout" >/dev/null \
  && ok "a kit an earlier run left on the runner is not kept as this run's" \
  || bad "a kit an earlier run left on the runner is not kept as this run's" "rc=$RC $(cat "$LH/log") $(tail -3 "$TMP/lout")"
run_lane TOCKMOX_KEEP_CLUSTER=1 STUB_P09_RC=1
[ "$RC" = 1 ] && [ "$(stored)" = 1 ] \
  && ok "a P09 that failed after making its kit still has the kit kept" || bad "a P09 that failed after making its kit still has the kit kept" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_KEEP_CLUSTER=1 STUB_KITSTORE_RC=1
[ "$RC" = 1 ] && grep -F 'P09 passed, but its recovery kit could not be kept as ed-lane-kit' "$LH"/work/report-p09-lane-*.txt >/dev/null 2>&1 \
  && ok "P09 passed but the kit could not be kept: the lane exits 1 and its report says why" \
  || bad "P09 passed but the kit could not be kept: the lane exits 1 and its report says why" "rc=$RC $(ls "$LH/work") $(tail -3 "$TMP/lout")"
run_lane TOCKMOX_KEEP_CLUSTER=1 STUB_KITSTORE_RC=1 STUB_P09_RC=3
[ "$RC" = 3 ] && ! ls "$LH"/work/report-p09-lane-*.txt >/dev/null 2>&1 \
  && ok "P09 failed and the kit could not be kept: the exit and the report stay P09's" \
  || bad "P09 failed and the kit could not be kept: the exit and the report stay P09's" "rc=$RC $(ls "$LH/work") $(tail -3 "$TMP/lout")"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

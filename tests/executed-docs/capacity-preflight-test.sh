#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic contract test for the capacity preflight. No cluster, no network, no
# root: kubectl, curl, ssh and sleep are stubs (the same stub shape as
# mirror-mode-test.sh), and the provisioner runs unmodified against them. The
# kubectl stub serves the four capacity sources from fixture files, and can make
# any one of them Forbidden.
#
# WHAT IT HOLDS THE PROVISIONER TO. `create` reads what the substrate can hold,
# sized from the run's own declared disk and memory, and refuses before it
# creates or deletes anything when the run does not fit:
#
#   1. a run that fits proceeds: it reaches the VirtualMachine apply
#   2. over-budget DISK is BLOCKED (exit 4), by the per-disk rule, and no
#      mutating kubectl call is made; a node-level sum that would have passed is
#      named as the wrong rule
#   3. over-budget MEMORY is BLOCKED, the same way
#   4. a stray harness VM in the namespace is BLOCKED; the run's own VM name is not
#   5. an UNREADABLE source (each of the four Forbidden in turn, an empty pod
#      list, no disk at all) is INFRA_ERROR (exit 5), never a pass, and creates nothing
#   6. the thresholds and the opt-outs are environment-overridable, a bad value is
#      refused (exit 2), and the skip is loud
#
# WHAT IT DOES NOT SHOW: that the numbers in a real Longhorn Node or Pod list have
# the shape the fixtures give them (the live, read-only run in the PR notes does),
# or that a given credential may read them.
#
#   ./tests/executed-docs/capacity-preflight-test.sh
#   TC=/path/to/throwaway-cluster.sh ./tests/executed-docs/capacity-preflight-test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

VM=k3s-test-01
REAL_SLEEP="$(command -v sleep)"
REAL_PY="$(command -v python3 || true)"
[ -n "$REAL_PY" ] || { bad "python3 is available to the test" "not on PATH"; exit 1; }
BIN="${TMP}/bin"
mkdir -p "$BIN"

cat >"${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
ST="$STUB_STATE"
printf '%s\n' "$*" >>"$ST/log"
# Every invocation, verbatim, so a case can assert that each one named a cluster
#. `log` above also carries non-call lines the cases grep for.
printf '%s\n' "$*" >>"$ST/calls"
a=()
while [ $# -gt 0 ]; do
  case "$1" in -n|--context) shift 2 ;; --context=*) shift ;; *) a+=("$1"); shift ;; esac
done
set -- "${a[@]}"
j="$*"
forbid() { echo "Error from server (Forbidden): secrets is forbidden: User \"stub\" cannot delete resource \"secrets\"" >&2; exit 1; }
notfound() { echo "Error from server (NotFound): secrets \"$1\" not found" >&2; exit 1; }
del_one() {
  if [ -f "$ST/secrets/$1" ]; then
    [ -f "$ST/sticky" ] || rm -f "$ST/secrets/$1"
    echo "secret \"$1\" deleted"
  fi
}
capfx() {  # one capacity source: Forbidden when <name>.fail exists, else its fixture
  if [ -f "$ST/fx/$1.fail" ]; then echo "Error from server (Forbidden): $1 is forbidden: User \"stub\" cannot list resource" >&2; exit 1; fi
  cat "$ST/fx/$1.json"; exit 0
}
case "$j" in
  "get nodes.longhorn.io -o json") capfx longhorn ;;
  "get nodes -o json") capfx nodes ;;
  "get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json") capfx pods ;;
  "get virtualmachines.kubevirt.io -l tockmox.com/harness=executed-docs -o json") capfx vms ;;
  "get virtualmachines.kubevirt.io -o name") exit 0 ;;
  "auth can-i"*) echo yes ;;
  *"jsonpath={.clusters[0].cluster.server}") printf 'https://api.invalid:6443' ;;
  *"jsonpath={.users[0].user.token}")
    # A JWT-shaped ServiceAccount token for tockmox-test (the script reads its
    # subject); $ST/token overrides it for the refusal cases.
    if [ -f "$ST/token" ]; then cat "$ST/token"
    else printf 'eyJhbGciOiJub25lIn0.%s.sig' "$(printf '{"sub":"system:serviceaccount:tockmox-test:tockmox-test-agent"}' | base64 | tr -d '=\n' | tr '+/' '-_')"; fi ;;
  "config view -o jsonpath={.clusters[0].name}") printf 'default' ;;
  "config current-context") printf 'default' ;;
  "config unset"*|"config set-cluster"*) exit 0 ;;
  "get virtualmachineimages.harvesterhci.io"*storageClassName*) printf 'stub-image-class' ;;
  "get virtualmachineimages.harvesterhci.io"*progress*) printf '100' ;;
  "delete secret -l "*)
    [ -f "$ST/deny-delete" ] && forbid
    for f in "$ST"/secrets/*; do [ -f "$f" ] && del_one "${f##*/}"; done; exit 0 ;;
  "delete secret "*)
    [ -f "$ST/deny-delete" ] && forbid
    shift 2
    for n in "$@"; do case "$n" in -*) ;; *) del_one "$n" ;; esac; done; exit 0 ;;
  "create secret generic "*)
    for x in "$@"; do case "$x" in --from-file=userdata=*) cp "${x#--from-file=userdata=}" "$ST/userdata"; cp "$ST/userdata" "$ST/secrets/$4" ;; esac; done ;;
  "label secret "*) exit 0 ;;
  "get secret "*" -o name")
    [ -f "$ST/secrets/$3" ] && { echo "secret/$3"; exit 0; }; notfound "$3" ;;
  "get secret "*"jsonpath={.data.kubeconfig}")
    [ -f "$ST/secrets/$3" ] || notfound "$3"
    grep -q STALE-GUEST "$ST/secrets/$3" && echo "READ-STALE $3" >>"$ST/log"
    base64 <"$ST/secrets/$3" | tr -d '\n' ;;
  "get secret "*"jsonpath={.data.ip}") notfound "$3" ;;
  "get secret -l "*|"get secret"|"get secret --no-headers"|"get secret -o "*)
    for f in "$ST"/secrets/*; do [ -f "$f" ] && echo "${f##*/}   Opaque   1   1m"; done; exit 0 ;;
  "apply -f -"|"apply -f - "*)
    k="$(sed -n 's/^kind: //p' | head -1)"
    stale=no; [ -f "$ST/secrets/k3s-test-01-kubeconfig" ] && stale=yes
    echo "APPLY ${k} stale-present=${stale}" >>"$ST/log"
    [ "$k" = VirtualMachine ] && echo "virtualmachine.kubevirt.io/k3s-test-01 created" ; exit 0 ;;
  "get svc "*nodePort*) printf '30001' ;;
  "get nodes"*) echo "error: You must be logged in to the server (the server has asked for the client to provide credentials)"; exit 1 ;;
  "api-resources --api-group=kubevirt.io") echo "virtualmachines  vm  kubevirt.io/v1  true  VirtualMachine" ;;
  "get pod "*|"get vmi "*|"get vm "*|"get svc "*|"get vmsnapshot "*|"get vm"|"get svc"|"get vmsnapshot") exit 0 ;;
  "delete "*) exit 0 ;;
  *) echo "STUB-UNHANDLED ${j}" >>"$ST/log"; exit 0 ;;
esac
STUB
# Nothing in these cases may reach the network.
printf '#!/bin/sh\necho "curl stub: no network in this test" >&2\nexit 7\n' >"${BIN}/curl"
# shellcheck disable=SC2016  # the stub reads $STUB_STATE when it runs, not when it is written
printf '#!/bin/sh\ncat >"$STUB_STATE/ssh-script"\necho "ssh stub: script kept"\n' >"${BIN}/ssh"
printf '#!/bin/sh\nexec %s 0.05\n' "$REAL_SLEEP" >"${BIN}/sleep"
# The per-run key: a stub that writes the two files create reads, so the test needs no ssh-keygen.
cat >"${BIN}/ssh-keygen" <<'KG'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -f) f="$2"; shift 2 ;; *) shift ;; esac; done
printf 'stub-private-key\n' >"$f"; printf 'ssh-ed25519 AAAAstub executed-docs-stub\n' >"$f.pub"
KG
# The capacity evaluator needs the real python3; the cloud-config check in create
# is skipped where PyYAML is absent, as in mirror-mode-test.sh.
cat >"${BIN}/python3" <<PY
#!/bin/sh
case "\$1" in *capacity-check.py) exec "${REAL_PY}" "\$@" ;; esac
if "${REAL_PY}" -c 'import yaml' 2>/dev/null; then exec "${REAL_PY}" "\$@"; fi
exit 0
PY
chmod +x "${BIN}"/*

# new_state DIR [key=val ...]: a fixture set. Defaults FIT a 250Gi / 24Gi VM:
#   disk_a/disk_b  "max:scheduled" in GiB; node_mem allocatable GiB; pod_mem requested GiB;
#   vms            space-separated labelled VM names
new_state() {
  local st="$1"; shift
  rm -rf "$st"; mkdir -p "$st/secrets" "$st/fx"; : >"$st/log"; : >"$st/calls"
  "$REAL_PY" - "$st/fx" "$@" <<'PYFX'
import json, sys
fx = sys.argv[1]
o = {"disk_a": "4000:1800", "disk_b": "2000:1200", "node_mem": "94", "pod_mem": "30", "vms": "", "pods": "yes", "disks": "yes"}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1); o[k] = v
G = 1 << 30
def disk(name, spec):
    mx, sc = (int(x) for x in spec.split(":"))
    return name, {"conditions": [{"type": "Ready", "status": "True"}, {"type": "Schedulable", "status": "True"}],
                  "storageMaximum": mx * G, "storageScheduled": sc * G, "storageAvailable": (mx - sc) * G}
status, sdisks = {}, {}
if o["disks"] == "yes":
    for n, s in (disk("disk-a", o["disk_a"]), disk("disk-b", o["disk_b"])):
        status[n] = s; sdisks[n] = {"allowScheduling": True}
lh = {"items": [{"metadata": {"name": "node-1"}, "spec": {"allowScheduling": True, "disks": sdisks},
                 "status": {"conditions": [{"type": "Ready", "status": "True"}, {"type": "Schedulable", "status": "True"}],
                            "diskStatus": status}}]}
nodes = {"items": [{"metadata": {"name": "node-1"}, "spec": {},
                    "status": {"allocatable": {"memory": "%dGi" % int(o["node_mem"])}, "conditions": [{"type": "Ready", "status": "True"}]}}]}
pods = {"items": []}
if o["pods"] == "yes":
    pods["items"] = [
        {"metadata": {"name": "p1"}, "spec": {"nodeName": "node-1", "containers": [{"resources": {"requests": {"memory": "%dGi" % int(o["pod_mem"])}}}]}, "status": {"phase": "Running"}},
        {"metadata": {"name": "p2"}, "spec": {"nodeName": "node-1", "containers": [{"resources": {"requests": {"memory": "500Gi"}}}]}, "status": {"phase": "Succeeded"}},
        {"metadata": {"name": "p3"}, "spec": {"containers": [{"resources": {"requests": {"memory": "500Gi"}}}]}, "status": {"phase": "Pending"}}]
vms = {"items": [{"metadata": {"name": n}} for n in o["vms"].split()]}
for name, doc in (("longhorn", lh), ("nodes", nodes), ("pods", pods), ("vms", vms)):
    json.dump(doc, open("%s/%s.json" % (fx, name), "w"))
PYFX
}
run_tc() {  # state-dir verb [extra env as VAR=val ...] -> $OUT, $RC
  local st="$1" verb="$2"; shift 2
  OUT="$(env STUB_STATE="$st" PATH="${BIN}:${PATH}" KUBECONFIG="${TMP}/substrate.kubeconfig" \
         TOCKMOX_SUBSTRATE_CONTEXT="stub-substrate" \
         TOCKMOX_WORKDIR="$st/wd" TOCKMOX_K3S_VERSION=v0.0.0-stub TOCKMOX_K3S_TIMEOUT=2 \
         TOCKMOX_TEST_VM="$VM" TMPDIR="$st" "$@" bash "$TC" "$verb" 2>&1)"
  RC=$?
}
vm_applied() { grep -c '^APPLY VirtualMachine' "$1/log" || true; }
# Calls that CHANGE something on the substrate. Reads (get, auth can-i, config view) are not them.
# `auth can-i create ...` is a read that names a verb.
mutations() { grep -v 'auth can-i' "$1/calls" | grep -cE ' (apply|create|delete|label|patch|replace|annotate|scale) ' || true; }
scratch_left() { find "$1" -maxdepth 1 -name 'capacity.*' | wc -l | tr -d ' '; }

# The tree under test must carry the preflight at all.
if [ ! -f "$(dirname "$TC")/profiles/capacity-preflight.sh" ]; then
  bad "capacity-preflight.sh is present" "not found next to ${TC}"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi

# ---- clause 1: a run that fits proceeds ---------------------------------------
S="${TMP}/fit"; new_state "$S"
run_tc "$S" create
if [ "$RC" -ne 4 ] && [ "$RC" -ne 5 ] && [ "$(vm_applied "$S")" -ge 1 ] && printf '%s' "$OUT" | grep 'capacity OK: storage' >/dev/null \
   && printf '%s' "$OUT" | grep 'capacity OK: memory' >/dev/null; then
  ok "a run that fits passes the capacity check and reaches the VirtualMachine apply"
else bad "a run that fits passes the capacity check and reaches the VirtualMachine apply" "rc=${RC}, applied=$(vm_applied "$S"): $(printf '%s' "$OUT" | tail -4)"; fi
if [ "$(scratch_left "$S")" -eq 0 ]; then ok "the capacity scratch directory is removed"
else bad "the capacity scratch directory is removed" "left: $(find "$S" -maxdepth 1 -name 'capacity.*')"; fi
S="${TMP}/fit-own-vm"; new_state "$S" "vms=$VM"
run_tc "$S" create
if [ "$RC" -ne 4 ] && [ "$(vm_applied "$S")" -ge 1 ]; then ok "the run's own VM name is not a stray harness VM"
else bad "the run's own VM name is not a stray harness VM" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi

# blocked_case LABEL STATE-DIR NEEDLE [env...]: BLOCKED, exit 4, nothing mutated
blocked_case() {
  local label="$1" st="$2" needle="$3"; shift 3
  run_tc "$st" create "$@"
  if [ "$RC" -eq 4 ] && [ "$(vm_applied "$st")" -eq 0 ] && [ "$(mutations "$st")" -eq 0 ] \
     && printf '%s' "$OUT" | grep -F -- "$needle" >/dev/null; then ok "$label"
  else bad "$label" "rc=${RC} (want 4), applied=$(vm_applied "$st"), mutations=$(mutations "$st"): $(printf '%s' "$OUT" | tail -4)"; fi
}

# ---- clause 2: disk ------------------------------------------------------------
# Two disks, each 150 GiB under its 85% stop line: the node-level sum (300) would
# hold a 250 GiB replica, and no single disk can.
S="${TMP}/disk"; new_state "$S" disk_a=1000:700 disk_b=1000:700
blocked_case "over-budget disk is BLOCKED before anything is created, by the per-disk rule" "$S" "BLOCKED: storage:"
if printf '%s' "$OUT" | grep 'the node-level sum would have passed' >/dev/null && printf '%s' "$OUT" | grep '250.0 GiB' >/dev/null; then
  ok "the BLOCKED line carries the numbers and names the node-level sum as the wrong rule"
else bad "the BLOCKED line carries the numbers and names the node-level sum as the wrong rule" "$(printf '%s' "$OUT" | grep BLOCKED)"; fi
S="${TMP}/disk-need"; new_state "$S" disk_a=1000:300 disk_b=1000:300
run_tc "$S" create TOCKMOX_VM_DISK=600Gi
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep '600.0 GiB' >/dev/null && [ "$(mutations "$S")" -eq 0 ]; then
  ok "the disk need is the run's own TOCKMOX_VM_DISK (600Gi blocks where 250Gi fits)"
else bad "the disk need is the run's own TOCKMOX_VM_DISK (600Gi blocks where 250Gi fits)" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi
S="${TMP}/disk-repl"; new_state "$S" disk_a=1000:300 disk_b=1000:800
run_tc "$S" create TOCKMOX_CAPACITY_REPLICAS=2
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep '1 of 2 disk' >/dev/null; then ok "two replicas need two disks that each fit"
else bad "two replicas need two disks that each fit" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi

# ---- clause 3: memory ----------------------------------------------------------
S="${TMP}/mem"; new_state "$S" pod_mem=80
blocked_case "over-budget memory is BLOCKED before anything is created" "$S" "BLOCKED: memory:"
S="${TMP}/mem-need"; new_state "$S"
run_tc "$S" create TOCKMOX_VM_MEMORY=80Gi
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep 'need 80.0 GiB' >/dev/null && [ "$(mutations "$S")" -eq 0 ]; then
  ok "the memory need is the run's own TOCKMOX_VM_MEMORY (80Gi blocks where 24Gi fits)"
else bad "the memory need is the run's own TOCKMOX_VM_MEMORY (80Gi blocks where 24Gi fits)" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi
# Terminated and unscheduled pods hold nothing: the fixture carries 1000Gi of them.
S="${TMP}/mem-terminated"; new_state "$S"
run_tc "$S" create
if [ "$RC" -ne 4 ]; then ok "terminated and unscheduled pods are not counted against a node"
else bad "terminated and unscheduled pods are not counted against a node" "$(printf '%s' "$OUT" | tail -3)"; fi

# ---- clause 4: a stray harness VM ---------------------------------------------
S="${TMP}/stray"; new_state "$S" "vms=ed-123-1"
blocked_case "a stray harness VM in the namespace is BLOCKED" "$S" "BLOCKED: harness:"
S="${TMP}/stray-allowed"; new_state "$S" "vms=ed-123-1"
run_tc "$S" create TOCKMOX_CAPACITY_ALLOW_OTHER_VMS=1
if [ "$RC" -ne 4 ] && [ "$(vm_applied "$S")" -ge 1 ]; then ok "TOCKMOX_CAPACITY_ALLOW_OTHER_VMS=1 lets a stray stand"
else bad "TOCKMOX_CAPACITY_ALLOW_OTHER_VMS=1 lets a stray stand" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi

# ---- clause 5: an unreadable source refuses ------------------------------------
for src in longhorn nodes pods vms; do
  S="${TMP}/forbidden-$src"; new_state "$S"; : >"$S/fx/$src.fail"
  run_tc "$S" create
  if [ "$RC" -eq 5 ] && [ "$(vm_applied "$S")" -eq 0 ] && [ "$(mutations "$S")" -eq 0 ] \
     && printf '%s' "$OUT" | grep 'INFRA_ERROR: capacity-source: cannot read' >/dev/null; then
    ok "an unreadable ${src} source is INFRA_ERROR, not a pass, and nothing is created"
  else bad "an unreadable ${src} source is INFRA_ERROR, not a pass, and nothing is created" "rc=${RC}, applied=$(vm_applied "$S"), mutations=$(mutations "$S"): $(printf '%s' "$OUT" | tail -3)"; fi
done
S="${TMP}/empty-pods"; new_state "$S" pods=no
run_tc "$S" create
if [ "$RC" -eq 5 ] && [ "$(mutations "$S")" -eq 0 ] && printf '%s' "$OUT" | grep 'no pod memory request on any node' >/dev/null; then
  ok "an empty pod list (what a front end may answer for a list the credential cannot make) is INFRA_ERROR, not an idle rig"
else bad "an empty pod list (what a front end may answer for a list the credential cannot make) is INFRA_ERROR, not an idle rig" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi
S="${TMP}/no-disks"; new_state "$S" disks=no
run_tc "$S" create
if [ "$RC" -eq 5 ] && [ "$(mutations "$S")" -eq 0 ] && printf '%s' "$OUT" | grep 'no disk with a storageMaximum' >/dev/null; then
  ok "a Longhorn answer with no disk is INFRA_ERROR, not a pass"
else bad "a Longhorn answer with no disk is INFRA_ERROR, not a pass" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi
S="${TMP}/garbage"; new_state "$S"; echo 'not json' >"$S/fx/nodes.json"
run_tc "$S" create
if [ "$RC" -eq 5 ] && printf '%s' "$OUT" | grep 'nodes: unreadable' >/dev/null; then ok "a source that is not JSON is INFRA_ERROR"
else bad "a source that is not JSON is INFRA_ERROR" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi

# ---- clause 6: thresholds, opt-outs, refusals -----------------------------------
# Disk A: 4000 max, 1800 scheduled, headroom 1600 at 85%: fits 250. At a 50% stop
# line the stop line is 2000 and the headroom 200.
S="${TMP}/pct"; new_state "$S" disk_a=4000:1800 disk_b=2000:1200
run_tc "$S" create TOCKMOX_CAPACITY_STOP_PERCENT=50
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep '50% stop line' >/dev/null; then ok "the stop line is environment-overridable (50 percent blocks where 85 fits)"
else bad "the stop line is environment-overridable (50 percent blocks where 85 fits)" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi
S="${TMP}/pct-default"; new_state "$S"
run_tc "$S" create
if printf '%s' "$OUT" | grep '85% stop line' >/dev/null; then ok "the default stop line is 85 percent"
else bad "the default stop line is 85 percent" "$(printf '%s' "$OUT" | grep 'capacity' | head -2)"; fi
for badval in "TOCKMOX_CAPACITY_STOP_PERCENT=0" "TOCKMOX_CAPACITY_STOP_PERCENT=101" "TOCKMOX_CAPACITY_STOP_PERCENT=lots" "TOCKMOX_CAPACITY_REPLICAS=0" \
              "TOCKMOX_CAPACITY_CHECK=off" "TOCKMOX_CAPACITY_ALLOW_OTHER_VMS=yes" "TOCKMOX_VM_DISK=big"; do
  S="${TMP}/bad-${badval}"; new_state "$S"
  run_tc "$S" create "$badval"
  if [ "$RC" -eq 2 ] && [ "$(mutations "$S")" -eq 0 ]; then ok "create refuses ${badval} (exit 2) before it changes anything"
  else bad "create refuses ${badval} (exit 2) before it changes anything" "rc=${RC}, mutations=$(mutations "$S"): $(printf '%s' "$OUT" | tail -2)"; fi
done
S="${TMP}/skip"; new_state "$S" disk_a=1000:900 disk_b=1000:900; : >"$S/fx/longhorn.fail"
run_tc "$S" create TOCKMOX_CAPACITY_CHECK=skip
if [ "$RC" -ne 4 ] && [ "$RC" -ne 5 ] && [ "$(vm_applied "$S")" -ge 1 ] && printf '%s' "$OUT" | grep 'WARNING: capacity preflight SKIPPED' >/dev/null \
   && [ "$(grep -c 'longhorn' "$S/calls" || true)" -eq 0 ]; then
  ok "TOCKMOX_CAPACITY_CHECK=skip runs unchecked, says so loudly, and reads nothing"
else bad "TOCKMOX_CAPACITY_CHECK=skip runs unchecked, says so loudly, and reads nothing" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi

# Every kubectl call the check makes names the substrate context.
S="${TMP}/ctx"; new_state "$S"
run_tc "$S" create
if grep -E 'nodes.longhorn.io|get nodes|get pods -A' "$S/calls" | grep -v -- '--context[= ]stub-substrate' >/dev/null; then
  bad "every capacity read names the substrate context" "$(grep -E 'nodes.longhorn.io|get nodes|get pods -A' "$S/calls" | grep -v -- '--context[= ]stub-substrate' | head -2)"
else ok "every capacity read names the substrate context"; fi

if grep -h 'STUB-UNHANDLED' "$TMP"/*/log 2>/dev/null | grep -E 'longhorn|get nodes|get pods -A' >/dev/null; then
  printf 'note: a capacity read the kubectl stub did not model:\n'; grep -h 'STUB-UNHANDLED' "$TMP"/*/log | sort -u | sed 's/^/  /'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

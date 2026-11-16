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
#   7. a namespace ResourceQuota with no room for what the run adds is BLOCKED and
#      names the key, the numbers and the pods holding the namespace's memory,
#      while the node itself has room; no quota at all is a pass that
#      says so; an unreadable or uncounted quota is INFRA_ERROR
#   8. run.sh puts what `create` said into the run REPORT: the provisioner's own
#      error (masked, bounded) and its exit code under the REFUSING line, a BLOCKED
#      capacity refusal as BLOCKED rather than as a provisioning failure, and a
#      create line on stdout is never taken for the kubeconfig path
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
  "get resourcequotas -o json") capfx quotas ;;
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
#   quota          yes|no: one ResourceQuota in the namespace, shaped like the rig's
#                  harness-ceiling; q_mem "hard:used" GiB (26:1), q_cpu "hard:used"
#                  millicores (10000:105), q_disk "hard:used" GiB (600:40), q_vms
#                  "hard:used" (4:1), q_used_missing a key left out of status.used,
#                  q_extra one more hard key, counted "key=hard:used"
new_state() {
  local st="$1"; shift
  rm -rf "$st"; mkdir -p "$st/secrets" "$st/fx"; : >"$st/log"; : >"$st/calls"
  "$REAL_PY" - "$st/fx" "$@" <<'PYFX'
import json, sys
fx = sys.argv[1]
o = {"disk_a": "4000:1800", "disk_b": "2000:1200", "node_mem": "94", "pod_mem": "30", "vms": "", "pods": "yes", "disks": "yes",
     "quota": "yes", "q_mem": "26:1", "q_cpu": "10000:105", "q_disk": "600:40", "q_vms": "4:1", "q_used_missing": "", "q_extra": ""}
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
    # Two pods in the run's namespace, as on the rig: what a BLOCKED quota line names.
    pods["items"] += [
        {"metadata": {"name": "virt-launcher-other-a", "namespace": "tockmox-test"}, "spec": {"nodeName": "node-1",
         "containers": [{"resources": {"requests": {"memory": "8Gi"}}}],
         "initContainers": [{"restartPolicy": "Always", "resources": {"requests": {"memory": "35M"}}}]}, "status": {"phase": "Running"}},
        {"metadata": {"name": "virt-launcher-other-b", "namespace": "tockmox-test"}, "spec": {"nodeName": "node-1",
         "containers": [{"resources": {"requests": {"memory": "1Gi"}}}]}, "status": {"phase": "Running"}}]
vms = {"items": [{"metadata": {"name": n}} for n in o["vms"].split()]}
def hu(spec):
    return [x for x in spec.split(":")]
quotas = {"items": []}
if o["quota"] == "yes":
    mh, mu = hu(o["q_mem"]); ch, cu = hu(o["q_cpu"]); dh, du = hu(o["q_disk"]); vh, vu = hu(o["q_vms"])
    hard = {"requests.memory": "%sGi" % mh, "requests.cpu": "%sm" % ch, "requests.storage": "%sGi" % dh,
            "count/virtualmachines.kubevirt.io": vh, "persistentvolumeclaims": "20"}
    used = {"requests.memory": "%sGi" % mu, "requests.cpu": "%sm" % cu, "requests.storage": "%sGi" % du,
            "count/virtualmachines.kubevirt.io": vu, "persistentvolumeclaims": "2"}
    if o["q_extra"]:
        k, v = o["q_extra"].split("=", 1); h, u = v.split(":"); hard[k] = h; used[k] = u
    if o["q_used_missing"]:
        used.pop(o["q_used_missing"], None)
    quotas["items"] = [{"metadata": {"name": "harness-ceiling"}, "spec": {"hard": hard}, "status": {"hard": hard, "used": used}}]
for name, doc in (("longhorn", lh), ("nodes", nodes), ("pods", pods), ("vms", vms), ("quotas", quotas)):
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
for src in longhorn nodes pods vms quotas; do
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
              "TOCKMOX_CAPACITY_CHECK=off" "TOCKMOX_CAPACITY_ALLOW_OTHER_VMS=yes" "TOCKMOX_VM_DISK=big" \
              "TOCKMOX_CAPACITY_LAUNCHER_OVERHEAD=lots" "TOCKMOX_CAPACITY_LAUNCHER_CPU=fast" "TOCKMOX_VM_CORES=eight"; do
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

# ---- clause 7: the namespace ResourceQuota ------------------------------
# The fixture quota is the rig's: 26Gi requests.memory, 10 cpu, 600Gi storage, 4 VMs.
S="${TMP}/quota-fit"; new_state "$S"
run_tc "$S" create
if [ "$RC" -ne 4 ] && [ "$RC" -ne 5 ] && [ "$(vm_applied "$S")" -ge 1 ] \
   && printf '%s' "$OUT" | grep -F 'capacity OK: quota: harness-ceiling: ' | grep -F 'requests.memory need 24.5 GiB (24.0 GiB VM + 0.5 GiB launcher overhead), free 25.0 GiB of 26.0 GiB' >/dev/null; then
  ok "a namespace quota with room passes, and its OK line carries the numbers"
else bad "a namespace quota with room passes, and its OK line carries the numbers" "rc=${RC}: $(printf '%s' "$OUT" | grep quota | head -2)"; fi
# 2026-11-14 to 16 on the rig: the node had room, the namespace did not.
S="${TMP}/quota-mem"; new_state "$S" q_mem=26:9.9
blocked_case "a namespace quota without room for the VM's memory is BLOCKED while the node has room" "$S" "BLOCKED: quota: harness-ceiling refuses requests.memory need 24.5 GiB"
if printf '%s' "$OUT" | grep 'BLOCKED: quota:' | grep -F 'memory held in tockmox-test by: virt-launcher-other-a 8.0 GiB, virt-launcher-other-b 1.0 GiB' >/dev/null \
   && ! printf '%s' "$OUT" | grep -F 'BLOCKED: memory:' >/dev/null; then
  ok "the BLOCKED quota line names the pods holding the namespace's memory, largest first, and the node check is not blamed"
else bad "the BLOCKED quota line names the pods holding the namespace's memory, largest first, and the node check is not blamed" "$(printf '%s' "$OUT" | grep BLOCKED)"; fi
# The run that fit on 2026-11-16: 1.43 GiB of other pods in a 26 GiB quota.
S="${TMP}/quota-edge"; new_state "$S" q_mem=26:1.43
run_tc "$S" create
if [ "$RC" -ne 4 ] && [ "$(vm_applied "$S")" -ge 1 ]; then ok "the shape that fit on the rig on 2026-11-16 still fits"
else bad "the shape that fit on the rig on 2026-11-16 still fits" "rc=${RC}: $(printf '%s' "$OUT" | grep -E 'quota|BLOCKED' | head -2)"; fi
S="${TMP}/quota-overhead"; new_state "$S" q_mem=26:1.43
blocked_case "the launcher overhead is TOCKMOX_CAPACITY_LAUNCHER_OVERHEAD (600Mi blocks where 512Mi fits)" "$S" "requests.memory need 24.6 GiB (24.0 GiB VM + 0.6 GiB launcher overhead)" TOCKMOX_CAPACITY_LAUNCHER_OVERHEAD=600Mi
S="${TMP}/quota-disk"; new_state "$S" q_disk=600:400
blocked_case "a quota without room for the VM disk is BLOCKED on requests.storage" "$S" "refuses requests.storage need 250.0 GiB, free 200.0 GiB"
S="${TMP}/quota-vms"; new_state "$S" q_vms=4:4
blocked_case "a quota with no VM left is BLOCKED on its VirtualMachine count" "$S" "refuses count/virtualmachines.kubevirt.io need 1, free 0"
S="${TMP}/quota-cpu"; new_state "$S" q_cpu=10000:9500
blocked_case "the launcher's cpu is 100m per vCPU of the run's own TOCKMOX_VM_CORES (8 cores, 800m, blocks on 500m free)" "$S" "refuses requests.cpu need 0.8 cpu, free 0.5 cpu"
S="${TMP}/quota-cpu-4"; new_state "$S" q_cpu=10000:9500
run_tc "$S" create TOCKMOX_VM_CORES=4
if [ "$RC" -ne 4 ] && [ "$(vm_applied "$S")" -ge 1 ]; then ok "4 vCPUs (400m) fit where 8 do not"
else bad "4 vCPUs (400m) fit where 8 do not" "rc=${RC}: $(printf '%s' "$OUT" | grep -E 'BLOCKED|quota' | head -2)"; fi
S="${TMP}/quota-none"; new_state "$S" quota=no
run_tc "$S" create
if [ "$RC" -ne 4 ] && [ "$RC" -ne 5 ] && [ "$(vm_applied "$S")" -ge 1 ] && printf '%s' "$OUT" | grep -F 'capacity OK: quota: no ResourceQuota in tockmox-test' >/dev/null; then
  ok "no ResourceQuota in the namespace is a pass that says so"
else bad "no ResourceQuota in the namespace is a pass that says so" "rc=${RC}: $(printf '%s' "$OUT" | grep quota | head -2)"; fi
S="${TMP}/quota-unsized"; new_state "$S" q_extra=services=10:2
run_tc "$S" create
if [ "$RC" -ne 4 ] && printf '%s' "$OUT" | grep 'capacity OK: quota:' | grep -F 'not sized: services' >/dev/null; then
  ok "a quota key the rule does not size is named as not sized, never silently passed"
else bad "a quota key the rule does not size is named as not sized, never silently passed" "rc=${RC}: $(printf '%s' "$OUT" | grep quota | head -2)"; fi
S="${TMP}/quota-uncounted"; new_state "$S" q_used_missing=requests.memory
run_tc "$S" create
if [ "$RC" -eq 5 ] && [ "$(mutations "$S")" -eq 0 ] && printf '%s' "$OUT" | grep -F 'quota harness-ceiling: status.used has no requests.memory' >/dev/null; then
  ok "a quota the controller has not counted is INFRA_ERROR, not a pass"
else bad "a quota the controller has not counted is INFRA_ERROR, not a pass" "rc=${RC}: $(printf '%s' "$OUT" | tail -3)"; fi

# ---- clause 8: run.sh reports what create said ---------------------------
# run.sh resolves the ref under test in its own repository root, so the copy lives in a
# one-commit scratch repository, with a fake provisioner in place of throwaway-cluster.sh.
FXREPO="${TMP}/repo"; ED="${FXREPO}/tests/executed-docs"; mkdir -p "${ED}/paths" "${ED}/provision" "${TMP}/rbin"
RUNSH="${RUNSH:-$(dirname "$TC")/../run.sh}"
cp "$RUNSH" "${ED}/run.sh"; cp -R "$(dirname "$RUNSH")/lib" "${ED}/lib"
cat >"${ED}/provision/throwaway-cluster.sh" <<'FAKE'
#!/usr/bin/env bash
# FAKE_CREATE picks what `create` does; every verb logs itself.
echo "$1 ${FAKE_CREATE:-}" >>"$FAKE_LOG"
[ "$1" = create ] || exit 0
case "$FAKE_CREATE" in
  quota)  echo "virtualmachine.kubevirt.io/ed-1 created"
          echo "  capacity OK: memory: need 24.0 GiB on one node" >&2
          echo "Error creating pod: pods "virt-launcher-ed-1" is forbidden: exceeded quota: harness-ceiling, requested: requests.memory=24.5Gi" >&2
          echo "debug: token=abc123SECRETVALUE" >&2
          exit 1 ;;
  blocked) echo "BLOCKED: quota: harness-ceiling refuses requests.memory need 24.5 GiB" >&2; exit 4 ;;
  infra)  echo "INFRA_ERROR: capacity-source: cannot read ResourceQuotas in tockmox-test" >&2; exit 5 ;;
  noise)  echo "virtualmachine.kubevirt.io/ed-1 created"; exit 0 ;;
  ok)     echo "  capacity OK: quota: harness-ceiling: requests.memory need 24.5 GiB, free 25.0 GiB of 26.0 GiB" >&2
          echo "virtualmachine.kubevirt.io/ed-1 created"; echo "fixture" >"${FAKE_KC}"; echo "${FAKE_KC}"; exit 0 ;;
esac
exit 9
FAKE
chmod 755 "${ED}/provision/throwaway-cluster.sh"
cat >"${ED}/paths/FXa-passes.sh" <<'FXP'
#!/usr/bin/env bash
. "$(cd "$(dirname "$0")/.." && pwd)/lib/assert.sh"
path_begin "FXa-passes" "a fixture path that passes"
execute_begin "nothing"; execute_end 0
assert_artifact "one equals one" 'printf 1' 1
path_finish
FXP
chmod 755 "${ED}/paths/FXa-passes.sh"
cat >"${TMP}/rbin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"config current-context"*|*"config get-contexts"*) echo fixture ;;
  *"get nodes"*) printf 'True' ;;
  *"version -o json"*) echo '{"serverVersion": {"gitVersion": "v0.0.0-fixture"}}' ;;
esac
exit 0
SH
chmod 755 "${TMP}/rbin/kubectl"
if ! { git -C "$FXREPO" init -q && git -C "$FXREPO" -c user.name=fixture -c user.email=fixture@example.com \
    commit -q --allow-empty -m fixture; }; then bad "the scratch repository for run.sh" "git init/commit failed"; fi
run_rs() {  # mode -> $ROUT, $RRC, $RREP (the report's text)
  local w="${TMP}/rs-$1"; rm -rf "$w"; mkdir -p "$w"
  ROUT="$( cd "$FXREPO" && env PATH="${TMP}/rbin:${PATH}" TOCKMOX_DOCS_REF=HEAD TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate \
           KUBECONFIG="${TMP}/substrate.kubeconfig" TOCKMOX_WORKDIR="$w" FAKE_CREATE="$1" FAKE_LOG="$w/fake.log" \
           FAKE_KC="$w/guest.kubeconfig" bash "${ED}/run.sh" FXa 2>&1 )"; RRC=$?
  RREP="$(cat "$w"/report-*.txt 2>/dev/null)"
}
run_rs quota
if [ "$RRC" -ne 0 ] && printf '%s' "$RREP" | grep -F 'REFUSING: provisioning: provisioning failed (rc=1)' >/dev/null \
   && printf '%s' "$RREP" | grep -F 'exceeded quota: harness-ceiling, requested: requests.memory=24.5Gi' >/dev/null; then
  ok "run.sh: a failed create puts its exit code and its own error into the REPORT"
else bad "run.sh: a failed create puts its exit code and its own error into the REPORT" "rc=${RRC}: $(printf '%s' "$RREP" | grep -A6 'provisioning ===' | tr '\n' ' ')"; fi
if printf '%s' "$RREP" | grep -F 'token=[masked]' >/dev/null && ! printf '%s' "$RREP" | grep -F 'abc123SECRETVALUE' >/dev/null; then
  ok "run.sh: credential-shaped text in the provisioner's error is masked in the report"
else bad "run.sh: credential-shaped text in the provisioner's error is masked in the report" "$(printf '%s' "$RREP" | grep -i token)"; fi
if ! printf '%s' "$RREP" | grep -E "Path returned|virtualmachine.kubevirt.io/ed-1 created'" >/dev/null; then
  ok "run.sh: a failed create's stdout is never read as the kubeconfig path"
else bad "run.sh: a failed create's stdout is never read as the kubeconfig path" "$(printf '%s' "$RREP" | grep -E 'Path|created')"; fi
if printf '%s' "$ROUT" | grep -F 'exceeded quota: harness-ceiling' >/dev/null; then ok "run.sh: the provisioner's stderr still streams to the job log"
else bad "run.sh: the provisioner's stderr still streams to the job log" "$(printf '%s' "$ROUT" | head -5 | tr '\n' ' ')"; fi
run_rs blocked
if [ "$RRC" -ne 0 ] && printf '%s' "$RREP" | grep -F 'BLOCKED: provisioning: the capacity preflight refused this run before anything was created (rc=4)' >/dev/null \
   && printf '%s' "$RREP" | grep -F '| BLOCKED: quota: harness-ceiling refuses requests.memory' >/dev/null \
   && ! printf '%s' "$RREP" | grep -E 'provisioning failed|did not produce a kubeconfig' >/dev/null; then
  ok "run.sh: a capacity BLOCKED is reported as BLOCKED, with its reason, never as a provisioning failure"
else bad "run.sh: a capacity BLOCKED is reported as BLOCKED, with its reason, never as a provisioning failure" "rc=${RRC}: $(printf '%s' "$RREP" | grep -A4 'provisioning ===' | tr '\n' ' ')"; fi
run_rs infra
if [ "$RRC" -ne 0 ] && printf '%s' "$RREP" | grep -F 'INFRA_ERROR: provisioning: the capacity preflight could not read the substrate (rc=5)' >/dev/null \
   && printf '%s' "$RREP" | grep -F 'cannot read ResourceQuotas in tockmox-test' >/dev/null; then
  ok "run.sh: a capacity INFRA_ERROR is reported as INFRA_ERROR, with the source it could not read"
else bad "run.sh: a capacity INFRA_ERROR is reported as INFRA_ERROR, with the source it could not read" "rc=${RRC}: $(printf '%s' "$RREP" | grep -A4 'provisioning ===' | tr '\n' ' ')"; fi
run_rs noise
if [ "$RRC" -ne 0 ] && printf '%s' "$RREP" | grep -F 'the provisioner exited 0 but its last line is not a kubeconfig file' >/dev/null \
   && ! grep -q '^destroy' "${TMP}/rs-noise/fake.log"; then
  ok "run.sh: a create that exits 0 with no kubeconfig file is refused, and nothing is torn down"
else bad "run.sh: a create that exits 0 with no kubeconfig file is refused, and nothing is torn down" "rc=${RRC}: $(printf '%s' "$RREP" | grep -A3 'provisioning ===' | tr '\n' ' '); $(cat "${TMP}/rs-noise/fake.log" 2>/dev/null | tr '\n' ' ')"; fi
run_rs ok
if [ "$RRC" -eq 0 ] && grep -q '^destroy' "${TMP}/rs-ok/fake.log"; then
  ok "run.sh: a create that works runs the path and tears down (the control)"
else bad "run.sh: a create that works runs the path and tears down (the control)" "rc=${RRC}: $(printf '%s' "$ROUT" | tail -4 | tr '\n' ' ')"; fi
if printf '%s' "$RREP" | grep -F '  capacity OK: quota: harness-ceiling' >/dev/null; then
  ok "run.sh: a create that works keeps its capacity lines in the report"
else bad "run.sh: a create that works keeps its capacity lines in the report" "$(printf '%s' "$RREP" | grep -A3 'provisioning ===' | tr '\n' ' ')"; fi

# Every kubectl call the check makes names the substrate context.
S="${TMP}/ctx"; new_state "$S"
run_tc "$S" create
if ! grep -q 'get resourcequotas' "$S/calls"; then bad "every capacity read names the substrate context" "the quota read was not made"
elif grep -E 'nodes.longhorn.io|get nodes|get pods -A|get resourcequotas' "$S/calls" | grep -v -- '--context[= ]stub-substrate' >/dev/null; then
  bad "every capacity read names the substrate context" "$(grep -E 'nodes.longhorn.io|get nodes|get pods -A|get resourcequotas' "$S/calls" | grep -v -- '--context[= ]stub-substrate' | head -2)"
else ok "every capacity read names the substrate context"; fi

if grep -h 'STUB-UNHANDLED' "$TMP"/*/log 2>/dev/null | grep -E 'longhorn|get nodes|get pods -A' >/dev/null; then
  printf 'note: a capacity read the kubectl stub did not model:\n'; grep -h 'STUB-UNHANDLED' "$TMP"/*/log | sort -u | sed 's/^/  /'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

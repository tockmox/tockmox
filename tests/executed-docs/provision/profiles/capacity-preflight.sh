# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# The capacity preflight: refuse a run that does not FIT, before it creates
# anything. Sourced by throwaway-cluster.sh; defines functions only.
#
# WHY IT EXISTS. The reach and verb checks in preflight() say the credential can
# talk to the substrate. They say nothing about whether the substrate can HOLD
# the machine this run is about to ask for. A run that does not fit fails late
# and wearing someone else's face: a replica Longhorn will not schedule shows up
# as a database in CrashLoopBackOff three steps from the cause, and a VM that
# cannot be placed shows up as a provision that never finishes. Both read as a
# product defect, and a false finding is worse than none.
#
# SIZED FROM THE RUN'S OWN DECLARED NEED, not from a constant: the disk is
# TOCKMOX_VM_DISK and the memory is TOCKMOX_VM_MEMORY, the same two values the
# VirtualMachine is rendered from.
#
# THE RULE (lib/capacity-check.py holds it and its comments):
#   storage  some one schedulable Longhorn disk must have
#            floor(stop% * storageMaximum) - storageScheduled >= the disk
#   memory   some one schedulable node must have allocatable memory minus the
#            memory requests of its non-terminated pods >= the memory
#   harness  no other harness-labelled VM in the run's namespace
#   quota    every ResourceQuota in the run's namespace has room, key by key,
#            for what this run adds: the VM memory plus the launcher's overhead,
#            the launcher's cpu request, the VM disk, one PVC and one VM. The
#            node can have room while the namespace does not.
#
# VERDICTS, as exit codes of `create` (everything else this script refuses with 2):
#   4  BLOCKED       "BLOCKED: <check>: <numbers>". The substrate was read and
#                    the run does not fit. Nothing has been created.
#   5  INFRA_ERROR   A capacity source could not be read, or read as nonsense.
#                    Never a pass.
#
# WHAT THE CREDENTIAL MUST BE ABLE TO READ, and what happens when it cannot. The
# check reads Longhorn nodes (longhorn-system), Nodes and all-namespace Pods
# (cluster scope), and the harness's own VirtualMachines and ResourceQuotas. A credential scoped to
# one namespace, as this harness intends, cannot read the first three. That is
# INFRA_ERROR, by design: the fix is a narrow read-only grant on the substrate
# (get and list on nodes, pods and nodes.longhorn.io; docs in README.md, "Capacity
# preflight"), or an explicit, loud TOCKMOX_CAPACITY_CHECK=skip.
#
# ENVIRONMENT
#   TOCKMOX_CAPACITY_CHECK              enforce (default) | skip
#   TOCKMOX_CAPACITY_STOP_PERCENT       85    the per-disk stop line, 1..100
#   TOCKMOX_CAPACITY_REPLICAS           1     replicas the storage class keeps; that
#                                             many distinct disks must each fit
#   TOCKMOX_CAPACITY_ALLOW_OTHER_VMS    0     1 lets another harness VM stand
#   TOCKMOX_CAPACITY_LAUNCHER_OVERHEAD  512Mi what KubeVirt's virt-launcher pod requests
#                                             beyond the VM's memory. Measured on the rig
#                                             2026-11-16 (KubeVirt 1.7): a 1Gi, 1-vCPU VM's
#                                             launcher requests 1Gi + 402Mi, plus a 35M
#                                             console sidecar; for the 24Gi, 8-vCPU harness
#                                             VM the overhead was at most 589Mi (it fit a
#                                             26Gi quota beside 1.4Gi of other pods). An
#                                             estimate: when it is wrong, the quota still
#                                             refuses, and the report now says why.
#   TOCKMOX_CAPACITY_LAUNCHER_CPU       (cores x 100m) the launcher's cpu request; KubeVirt's
#                                             default ratio requests 100m per vCPU
#
# NOT DECIDED HERE: whether the guest's own pods will fit INSIDE the guest. This
# is the substrate's side only.

CAPACITY_CHECK="${TOCKMOX_CAPACITY_CHECK:-enforce}"
CAPACITY_STOP_PERCENT="${TOCKMOX_CAPACITY_STOP_PERCENT:-85}"
CAPACITY_REPLICAS="${TOCKMOX_CAPACITY_REPLICAS:-1}"
CAPACITY_ALLOW_OTHER_VMS="${TOCKMOX_CAPACITY_ALLOW_OTHER_VMS:-0}"
CAPACITY_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/capacity-check.py"

capacity_preflight() {
  : "${TOCKMOX_SUBSTRATE_CONTEXT:?TOCKMOX_SUBSTRATE_CONTEXT is empty: export the kubectl context of the hypervisor cluster that hosts the throwaway VM}"
  case "$CAPACITY_CHECK" in
    enforce) ;;
    skip)
      echo "WARNING: capacity preflight SKIPPED (TOCKMOX_CAPACITY_CHECK=skip)." >&2
      echo "         Nothing has checked that ${DISK} of disk and ${MEMORY} of memory fit on the" >&2
      echo "         substrate. A run that does not fit fails late, as an error in some other component." >&2
      return 0 ;;
    *) echo "REFUSING: TOCKMOX_CAPACITY_CHECK must be enforce or skip, got '${CAPACITY_CHECK}'" >&2; exit 2 ;;
  esac
  case "$CAPACITY_ALLOW_OTHER_VMS" in 0|1) ;; *)
    echo "REFUSING: TOCKMOX_CAPACITY_ALLOW_OTHER_VMS must be 0 or 1, got '${CAPACITY_ALLOW_OTHER_VMS}'" >&2; exit 2 ;; esac
  if ! command -v python3 >/dev/null 2>&1; then
    echo "INFRA_ERROR: capacity-source: python3 is not on PATH, so the capacity rule cannot be evaluated." >&2
    exit 5
  fi
  [ -f "$CAPACITY_PY" ] || { echo "INFRA_ERROR: capacity-source: ${CAPACITY_PY} is missing" >&2; exit 5; }

  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/capacity.XXXXXX")" || { echo "INFRA_ERROR: capacity-source: no scratch directory" >&2; exit 5; }
  local what rc=0
  # Each source is a separate call so the refusal names the one that failed.
  # A failed read leaves its stderr in the message and never reaches the rule.
  capacity_read() {  # file label kubectl-args...
    local f="$1" label="$2"; shift 2
    if ! kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" "$@" -o json >"$f" 2>"${f}.err"; then
      echo "INFRA_ERROR: capacity-source: cannot read ${label}: $(head -c 300 "${f}.err" | tr '\n' ' ')" >&2
      echo "             This credential needs a read grant for it, or set TOCKMOX_CAPACITY_CHECK=skip to run unchecked." >&2
      rm -rf "$d"; exit 5
    fi
  }
  capacity_read "$d/longhorn.json" "Longhorn nodes (nodes.longhorn.io in longhorn-system)" -n longhorn-system get nodes.longhorn.io
  capacity_read "$d/nodes.json" "Nodes" get nodes
  capacity_read "$d/pods.json" "Pods in every namespace" get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed
  capacity_read "$d/vms.json" "harness VirtualMachines in ${NS}" -n "$NS" get virtualmachines.kubevirt.io -l tockmox.com/harness=executed-docs
  capacity_read "$d/quotas.json" "ResourceQuotas in ${NS}" -n "$NS" get resourcequotas

  local allow="" lcpu="${TOCKMOX_CAPACITY_LAUNCHER_CPU:-}"
  [ "$CAPACITY_ALLOW_OTHER_VMS" = "1" ] && allow="--allow-other-vms"
  # CPU_CORES is the VM's own vCPU count (TOCKMOX_VM_CORES); read here, at call time,
  # because throwaway-cluster.sh sets it after it sources this file.
  if [ -z "$lcpu" ]; then
    case "${CPU_CORES:-}" in ''|*[!0-9]*) echo "REFUSING: TOCKMOX_VM_CORES must be a whole number, got '${CPU_CORES:-}'" >&2; rm -rf "$d"; exit 2 ;; esac
    lcpu="$((CPU_CORES * 100))m"
  fi
  # shellcheck disable=SC2086  # $allow is empty or one fixed flag
  what="$(python3 "$CAPACITY_PY" --disk "$DISK" --memory "$MEMORY" --stop-percent "$CAPACITY_STOP_PERCENT" \
            --replicas "$CAPACITY_REPLICAS" --vm "$VM_NAME" $allow --namespace "$NS" \
            --launcher-memory-overhead "${TOCKMOX_CAPACITY_LAUNCHER_OVERHEAD:-512Mi}" --launcher-cpu "$lcpu" \
            --longhorn "$d/longhorn.json" --nodes "$d/nodes.json" --pods "$d/pods.json" --vms "$d/vms.json" \
            --quotas "$d/quotas.json" 2>&1)" || rc=$?
  rm -rf "$d"
  case "$rc" in
    0) printf '%s\n' "$what" | sed 's/^/  capacity /' >&2 ;;
    4) printf '%s\n' "$what" | grep '^BLOCKED:' >&2
       echo "          Nothing was created. Free the capacity (for a quota line, the pods it names), lower TOCKMOX_VM_DISK /" >&2
       echo "          TOCKMOX_VM_MEMORY deliberately, raise the namespace quota, or see" >&2
       echo "          'Capacity preflight' in tests/executed-docs/README.md for the thresholds." >&2
       exit 4 ;;
    5) printf '%s\n' "$what" >&2; exit 5 ;;
    2) printf '%s\n' "$what" >&2; exit 2 ;;
    *) echo "INFRA_ERROR: capacity-source: the evaluator exited ${rc}: ${what}" >&2; exit 5 ;;
  esac
}

# The `room` verb: is there room for this run now, and if the rig is full, wait a
# bounded time for it. It reads exactly what `create` reads, through the same
# capacity_preflight, and creates and deletes nothing.
#
# WHY IT EXISTS. A scheduled or push run that meets a rig another run is using
# used to fail at create's BLOCKED, and the job went red with nothing wrong with
# the product. A full rig is a reason the run did not happen, not a finding. So a
# caller that would rather wait than refuse asks `room` first, and lib/room-gate.sh
# turns a rig that stays full into "not run: lab full" instead of a failure.
#
# ONLY BLOCKED IS WAITED ON. An unreadable capacity source (5) or a bad setting (2)
# is returned at once: neither is a full rig, and waiting would hide it.
#
# ENVIRONMENT
#   TOCKMOX_CAPACITY_WAIT_S   0     how long, in all, to wait for room, 0 to 14400;
#                                   0 reads once and answers
#   TOCKMOX_CAPACITY_POLL_S   60    seconds between reads, 1 to 3600
#
# EXIT: 0 there is room (the capacity OK lines on stderr); 4 still full at the
# bound ("BLOCKED: not run: lab full after Ns", then the last BLOCKED line);
# 5 and 2 as capacity_preflight returns them.
capacity_room_wait() {
  local wait_s="${TOCKMOX_CAPACITY_WAIT_S:-0}" poll_s="${TOCKMOX_CAPACITY_POLL_S:-60}"
  case "$wait_s" in ''|*[!0-9]*)
    echo "REFUSING: TOCKMOX_CAPACITY_WAIT_S must be a whole number of seconds, got '${wait_s}'" >&2; exit 2 ;; esac
  case "$poll_s" in ''|*[!0-9]*)
    echo "REFUSING: TOCKMOX_CAPACITY_POLL_S must be a whole number of seconds, got '${poll_s}'" >&2; exit 2 ;; esac
  wait_s=$((10#$wait_s)); poll_s=$((10#$poll_s))
  if [ "$wait_s" -gt 14400 ]; then
    echo "REFUSING: TOCKMOX_CAPACITY_WAIT_S is ${wait_s}; the most is 14400 (4 h)" >&2; exit 2
  fi
  if [ "$poll_s" -lt 1 ] || [ "$poll_s" -gt 3600 ]; then
    echo "REFUSING: TOCKMOX_CAPACITY_POLL_S is ${poll_s}; it must be 1 to 3600" >&2; exit 2
  fi
  local waited=0 rc out last step
  while :; do
    # capacity_preflight exits rather than returns on every refusal, so each read
    # runs in its own subshell and leaves this loop standing.
    rc=0; out="$( (capacity_preflight) 2>&1 )" || rc=$?
    case "$rc" in
      0)
        printf '%s\n' "$out" >&2
        if [ "$waited" -gt 0 ]; then echo "ROOM: room after ${waited}s of waiting" >&2
        else echo "ROOM: room now" >&2; fi
        return 0 ;;
      4)
        last="$(printf '%s\n' "$out" | grep '^BLOCKED:' | tail -1 || true)"
        if [ "$waited" -ge "$wait_s" ]; then
          echo "BLOCKED: not run: lab full after ${waited}s (TOCKMOX_CAPACITY_WAIT_S=${wait_s}); nothing was created" >&2
          printf '%s\n' "${last:-BLOCKED: (the preflight printed no reason)}" >&2
          exit 4
        fi
        step="$poll_s"
        [ $((wait_s - waited)) -lt "$step" ] && step=$((wait_s - waited))
        echo "WAITING: lab full, reading again in ${step}s (${waited}s of ${wait_s}s waited): ${last}" >&2
        sleep "$step"
        waited=$((waited + step)) ;;
      *)
        printf '%s\n' "$out" >&2
        exit "$rc" ;;
    esac
  done
}

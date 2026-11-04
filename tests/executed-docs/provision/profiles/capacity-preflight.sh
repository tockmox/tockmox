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
#
# VERDICTS, as exit codes of `create` (everything else this script refuses with 2):
#   4  BLOCKED       "BLOCKED: <check>: <numbers>". The substrate was read and
#                    the run does not fit. Nothing has been created.
#   5  INFRA_ERROR   A capacity source could not be read, or read as nonsense.
#                    Never a pass.
#
# WHAT THE CREDENTIAL MUST BE ABLE TO READ, and what happens when it cannot. The
# check reads Longhorn nodes (longhorn-system), Nodes and all-namespace Pods
# (cluster scope) and the harness's own VirtualMachines. A credential scoped to
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

  local allow=""
  [ "$CAPACITY_ALLOW_OTHER_VMS" = "1" ] && allow="--allow-other-vms"
  # shellcheck disable=SC2086  # $allow is empty or one fixed flag
  what="$(python3 "$CAPACITY_PY" --disk "$DISK" --memory "$MEMORY" --stop-percent "$CAPACITY_STOP_PERCENT" \
            --replicas "$CAPACITY_REPLICAS" --vm "$VM_NAME" $allow \
            --longhorn "$d/longhorn.json" --nodes "$d/nodes.json" --pods "$d/pods.json" --vms "$d/vms.json" 2>&1)" || rc=$?
  rm -rf "$d"
  case "$rc" in
    0) printf '%s\n' "$what" | sed 's/^/  capacity /' >&2 ;;
    4) printf '%s\n' "$what" | grep '^BLOCKED:' >&2
       echo "          Nothing was created. Free the capacity, lower TOCKMOX_VM_DISK / TOCKMOX_VM_MEMORY deliberately, or see" >&2
       echo "          'Capacity preflight' in tests/executed-docs/README.md for the thresholds." >&2
       exit 4 ;;
    5) printf '%s\n' "$what" >&2; exit 5 ;;
    2) printf '%s\n' "$what" >&2; exit 2 ;;
    *) echo "INFRA_ERROR: capacity-source: the evaluator exited ${rc}: ${what}" >&2; exit 5 ;;
  esac
}

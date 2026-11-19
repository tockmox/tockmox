#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The rig-full gate for a scheduled or push run of the paths job. It asks the
# provisioner's `room` verb whether this run fits on the substrate, waiting up to
# TOCKMOX_CAPACITY_WAIT_S for room, and answers in a form the workflow can act on:
#
#   room=yes  there is room: the paths job runs. Exit 0.
#   room=no   the rig stayed full to the bound: the paths job does not run, and
#             the step summary says "not run: lab full" and why. Exit 0, so the
#             run ends neutral rather than red. Nothing was created.
#   (none)    anything else: a capacity source it cannot read (5), a bad setting
#             (2), any other exit. That exit is returned, so the job goes red as
#             before: a rig that cannot be read is not a full rig.
#
# The answer goes to $GITHUB_OUTPUT as `room=yes|no` and, for room=no, a short
# section to $GITHUB_STEP_SUMMARY, each only when the variable is set. Outside
# Actions it prints the same answer as a ROOM-GATE line.
#
# WHAT IT DOES NOT DO: hold the rig. It reads a moment; another run can take the
# room between this answer and the paths job's own create, whose capacity
# preflight then refuses as BLOCKED, as before. A reservation closes that gap.
#
#   TOCKMOX_SUBSTRATE_CONTEXT=... TOCKMOX_TEST_VM=ed-1-1 TOCKMOX_CAPACITY_WAIT_S=2700 \
#     bash tests/executed-docs/lib/room-gate.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${HERE}/../provision/throwaway-cluster.sh"

answer() {  # room-value
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'room=%s\n' "$1" >>"$GITHUB_OUTPUT"; fi
}

out="$(bash "$TC" room 2>&1)"; rc=$?
printf '%s\n' "$out"
case "$rc" in
  0)
    answer yes
    echo "ROOM-GATE room=yes: the run fits on the substrate now"
    exit 0 ;;
  4)
    full="$(printf '%s\n' "$out" | grep '^BLOCKED: not run: lab full' | tail -1 || true)"
    why="$(printf '%s\n' "$out" | grep '^BLOCKED:' | grep -v '^BLOCKED: not run: lab full' | tail -1 || true)"
    answer no
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        printf '### not run: lab full\n\n'
        printf 'The substrate had no room for this run, so the documented paths were not run.\n'
        printf 'This is not a failure and not a pass. Nothing was created.\n\n'
        printf -- '- %s\n' "${full#BLOCKED: }"
        [ -z "$why" ] || printf -- '- %s\n' "${why#BLOCKED: }"
      } >>"$GITHUB_STEP_SUMMARY"
    fi
    echo "ROOM-GATE room=no: not run: lab full${why:+ ... ${why#BLOCKED: }}"
    exit 0 ;;
  *)
    echo "ROOM-GATE no answer: the room check exited ${rc}, which is not a full rig"
    exit "$rc" ;;
esac

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Capture something that starts BEFORE an event and must outlive the caller.
#
#   recorder-job.sh start  NAME -- CMD...   create the Job, wait for READY
#   recorder-job.sh event  NAME             signal that the observed event happened
#   recorder-job.sh wait   NAME             wait for COMPLETE
#   recorder-job.sh fetch  NAME [OUT]       retrieve the captured evidence
#   recorder-job.sh status NAME             print the handshake phase
#   recorder-job.sh clean  NAME             delete the Job and its handshake
#
# WHY THIS EXISTS, and it is the one capability whose absence has actually cost
# this project a measurement.
#
# The release gate's first-sync evidence has to start a controller-log capture
# BEFORE `kubectl apply -f bootstrap/root.yaml` and hold it across the apply.
# The agent driving these tests gets a hard per-command time cap and **each
# invocation is its own PID namespace**, so nothing backgrounded survives. On
# 2026-09-13 that was worked around by reading the log afterwards with
# `--since` and hoping it had not rotated. It had not. That is luck, not method.
#
# THE ESTABLISHED ANSWER is to move ownership of the long-running work from the
# short-lived caller to a durable control-plane object. Kubernetes recommends a
# Job over a bare Pod for finite work because the controller survives node
# failure, and a completed Job's pod stays available for log inspection. So the
# recorder becomes a Job, and the caller interacts with it through a handshake:
#
#   start  -> Job created, capture running, handshake reaches READY
#   (caller does the thing being observed)
#   event  -> handshake reaches EVENT; the recorder keeps capturing for a grace
#             period, then stops
#   wait   -> handshake reaches COMPLETE
#   fetch  -> evidence retrieved
#
# No shell process needs to survive the caller. Each verb is a separate short
# command, which is exactly the shape the driver can express.
#
# THE HANDSHAKE IS A CONFIGMAP, not a file in the pod, because the evidence and
# the phase must be readable after the pod is gone and must not depend on the
# pod still running to be observed.
#
# DEADLINES ARE NOT OPTIONAL. A recorder that never sees its EVENT would
# otherwise hold a slot forever. `activeDeadlineSeconds` bounds the Job and the
# recorder bounds its own wait, so a caller that dies mid-test leaves a Job that
# terminates itself and a handshake that says ABORTED rather than one that says
# READY forever.
#
# WHAT IT DOES NOT DO. It does not make the capture correct: a command naming
# the wrong workload kind still captures nothing, which is its own recorded
# defect. Assert on the SIZE and CONTENT of what came back, never on the Job
# having succeeded.
set -euo pipefail
# TM-0797: every kubectl call below names its cluster with --context from this
# variable; an empty value is refused rather than falling back to the current context.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

NS="${RECORDER_NS:-tockmox-harness}"
IMAGE="${RECORDER_IMAGE:-alpine/k8s:1.36.2}"
DEADLINE="${RECORDER_DEADLINE:-1800}"       # hard bound on the whole Job
GRACE="${RECORDER_GRACE:-20}"               # keep capturing this long after EVENT
SA="${RECORDER_SA:-recorder}"

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 2 ] || usage
VERB="$1"; NAME="$2"; shift 2
CM="recorder-${NAME}"
JOB="recorder-${NAME}"

phase() { kubectl --context="$KUBE_CONTEXT" -n "$NS" get cm "$CM" -o jsonpath='{.data.phase}' 2>/dev/null || true; }

cmd_start() {
  [ "${1:-}" = "--" ] || { echo "recorder-job: start needs -- CMD..." >&2; exit 2; }
  shift
  [ $# -ge 1 ] || { echo "recorder-job: no command given" >&2; exit 2; }
  local capture="$*"

  kubectl --context="$KUBE_CONTEXT" create namespace "$NS" >/dev/null 2>&1 || true
  kubectl --context="$KUBE_CONTEXT" -n "$NS" create serviceaccount "$SA" >/dev/null 2>&1 || true
  # The recorder reads logs and writes its own handshake. Nothing wider.
  kubectl --context="$KUBE_CONTEXT" create clusterrolebinding "recorder-${NS}-view" \
    --clusterrole=view --serviceaccount="${NS}:${SA}" >/dev/null 2>&1 || true
  kubectl --context="$KUBE_CONTEXT" -n "$NS" create rolebinding recorder-edit \
    --clusterrole=edit --serviceaccount="${NS}:${SA}" >/dev/null 2>&1 || true

  kubectl --context="$KUBE_CONTEXT" -n "$NS" delete cm "$CM" job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context="$KUBE_CONTEXT" -n "$NS" create cm "$CM" --from-literal=phase=PENDING >/dev/null

  kubectl --context="$KUBE_CONTEXT" -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: ${JOB}}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${DEADLINE}
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: ${SA}
      containers:
      - name: recorder
        image: ${IMAGE}
        command: ["/bin/sh","-c"]
        args:
        - |
          set -u
          OUT=/tmp/capture.log
          # Start the capture FIRST, then declare READY. Declaring ready before
          # the producer is running is how a capture misses the very window it
          # exists to observe.
          ( ${capture} ) > "\$OUT" 2>&1 &
          CAP=\$!
          sleep 3
          if ! kill -0 "\$CAP" 2>/dev/null && [ ! -s "\$OUT" ]; then
            kubectl -n ${NS} patch cm ${CM} --type=merge \\
              -p '{"data":{"phase":"ABORTED","reason":"capture exited immediately with no output"}}'
            exit 1
          fi
          kubectl -n ${NS} patch cm ${CM} --type=merge -p '{"data":{"phase":"READY"}}'
          # Wait for the caller to say the observed event happened.
          WAITED=0
          while [ "\$(kubectl -n ${NS} get cm ${CM} -o jsonpath='{.data.phase}')" != "EVENT" ]; do
            sleep 3; WAITED=\$((WAITED+3))
            if [ "\$WAITED" -ge $((DEADLINE - 120)) ]; then
              kubectl -n ${NS} patch cm ${CM} --type=merge \\
                -p '{"data":{"phase":"ABORTED","reason":"no EVENT before deadline"}}'
              kill "\$CAP" 2>/dev/null || true
              exit 1
            fi
          done
          sleep ${GRACE}
          kill "\$CAP" 2>/dev/null || true
          sleep 1
          BYTES=\$(wc -c < "\$OUT" | tr -d ' ')
          LINES=\$(wc -l < "\$OUT" | tr -d ' ')
          # The evidence lands in the handshake object, so it outlives the pod.
          kubectl -n ${NS} create cm ${CM}-evidence --from-file=capture.log="\$OUT" \\
            --dry-run=client -o yaml | kubectl -n ${NS} apply -f - >/dev/null
          kubectl -n ${NS} patch cm ${CM} --type=merge \\
            -p "{\\"data\\":{\\"phase\\":\\"COMPLETE\\",\\"bytes\\":\\"\$BYTES\\",\\"lines\\":\\"\$LINES\\"}}"
EOF

  local waited=0
  while :; do
    local p; p="$(phase)"
    case "$p" in
      READY)   echo "READY"; return 0 ;;
      ABORTED) echo "ABORTED: $(kubectl --context="$KUBE_CONTEXT" -n "$NS" get cm "$CM" -o jsonpath='{.data.reason}')" >&2; return 1 ;;
    esac
    sleep 3; waited=$((waited+3))
    [ "$waited" -ge 120 ] && { echo "recorder-job: never reached READY (phase=${p:-none})" >&2; return 1; }
  done
}

case "$VERB" in
  start)  cmd_start "$@" ;;
  event)  kubectl -n "$NS" patch cm "$CM" --type=merge -p '{"data":{"phase":"EVENT"}}' >/dev/null; echo EVENT ;;
  status) p="$(phase)"; echo "${p:-none}" ;;
  wait)
    waited=0
    while :; do
      p="$(phase)"
      case "$p" in
        COMPLETE) kubectl -n "$NS" get cm "$CM" -o jsonpath='COMPLETE bytes={.data.bytes} lines={.data.lines}{"\n"}'; exit 0 ;;
        ABORTED)  echo "ABORTED: $(kubectl --context="$KUBE_CONTEXT" -n "$NS" get cm "$CM" -o jsonpath='{.data.reason}')" >&2; exit 1 ;;
      esac
      sleep 5; waited=$((waited+5))
      [ "$waited" -ge 300 ] && { echo "recorder-job: no COMPLETE after 300s (phase=${p:-none})" >&2; exit 1; }
    done ;;
  fetch)
    OUT="${1:-/dev/stdout}"
    kubectl --context="$KUBE_CONTEXT" -n "$NS" get cm "${CM}-evidence" -o jsonpath='{.data.capture\.log}' > "$OUT" ;;
  clean)
    kubectl --context="$KUBE_CONTEXT" -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context="$KUBE_CONTEXT" -n "$NS" delete cm "$CM" "${CM}-evidence" --ignore-not-found >/dev/null 2>&1 || true
    echo cleaned ;;
  *) usage ;;
esac

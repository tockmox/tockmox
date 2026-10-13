#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the posture probe once, now, and fetch the report. Runs as YOU: every
# create, exec and delete below is your identity's act, never the probe's.
#
#   addons/posture-probe/run-now.sh --context CTX [--namespace NS] [--run-id ID] [--out DIR]
#
# What it does, in order:
#   1. reads the measured namespaces and identity vantages from the add-on's
#      ConfigMap (posture-probe-config in NS, default tockmox-posture);
#   2. creates one Job from each CronJob, all named with one run id, so the
#      differential can find its collectors;
#   3. waits for the differential Job and prints its exit code, which IS the gate:
#      0 clean, 1 could not run, 2 drift;
#   4. with --out, starts a short-lived reader pod on the report volume, copies the
#      report out with exec (exec output is not a container log, so the report
#      does not reach log shipping), writes it 0600 under DIR, and deletes the pod.
#
# Exits with the gate's code, or 3 when this script itself could not proceed.
set -euo pipefail
CTX=""; NS=tockmox-posture; RUN=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --run-id) RUN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n 2,22p "$0"; exit 0 ;;
    *) echo "run-now: unknown argument $1" >&2; exit 3 ;;
  esac
done
[ -n "$CTX" ] || { echo "run-now: --context is required; this script never uses your current context" >&2; exit 3; }
RUN="${RUN:-now-$(date -u +%Y%m%d%H%M%S)}"
# The run id names Jobs. The alphabet is spelled out: under a non-C locale a
# range such as a-z can admit uppercase, and an invalid Job name fails creation.
case "$RUN" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|-*|"") echo "run-now: --run-id must be lowercase letters, digits and '-'" >&2; exit 3 ;;
esac
k() { kubectl --context "$CTX" "$@"; }

conf=$(k -n "$NS" get configmap posture-probe-config -o 'jsonpath={.data.config\.json}') \
  || { echo "run-now: no posture-probe-config in $NS (is the add-on enabled there?)" >&2; exit 3; }
read -r -a NSS <<<"$(printf '%s' "$conf" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["namespaces"]))')"
read -r -a VANT <<<"$(printf '%s' "$conf" | python3 -c 'import json,sys; print(" ".join(v["namespace"] for v in json.load(sys.stdin).get("identityVantages", [])))')"
image=$(k -n "$NS" get cronjob posture-probe-differential -o 'jsonpath={.spec.jobTemplate.spec.template.spec.containers[0].image}')

echo "run $RUN: ${#NSS[@]} collectors, ${#VANT[@]} identity vantage(s), differential in $NS"
for n in "${NSS[@]}"; do k -n "$n" create job --from=cronjob/posture-probe-collect "posture-probe-collect-$RUN" >/dev/null; done
for n in "${VANT[@]}"; do [ -n "$n" ] && k -n "$n" create job --from=cronjob/posture-probe-identity "posture-probe-identity-$RUN" >/dev/null; done
k -n "$NS" create job --from=cronjob/posture-probe-differential "posture-probe-differential-$RUN" >/dev/null

job="posture-probe-differential-$RUN"; code=""
for _ in $(seq 1 120); do
  code=$(k -n "$NS" get pods -l "job-name=$job" -o 'jsonpath={.items[0].status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
  [ -n "$code" ] && break
  sleep 5
done
[ -n "$code" ] || { echo "run-now: the differential did not finish in 10 minutes" >&2; exit 3; }
k -n "$NS" logs "job/$job" | sed 's/^/  /'
echo "gate exit: $code"

if [ -n "$OUT" ]; then
  mkdir -p "$OUT"; reader="posture-probe-read-$RUN"
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $reader, namespace: $NS, labels: {app.kubernetes.io/part-of: posture-probe, app.kubernetes.io/component: reader}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: reader
    image: $image
    command: ["python3", "-c", "import time; time.sleep(300)"]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
    resources: {limits: {memory: 64Mi}}
    volumeMounts: [{name: reports, mountPath: /reports, readOnly: true}]
  volumes: [{name: reports, persistentVolumeClaim: {claimName: posture-probe-reports, readOnly: true}}]
YAML
  trap 'k -n "$NS" delete pod "$reader" --ignore-not-found --wait=false >/dev/null' EXIT
  k -n "$NS" wait --for=condition=Ready "pod/$reader" --timeout=120s >/dev/null
  latest=$(k -n "$NS" exec "$reader" -- cat /reports/latest | tr -d '\r\n')
  umask 077
  k -n "$NS" exec "$reader" -- cat "/reports/$latest" > "$OUT/$latest"
  echo "report: $OUT/$latest"
fi
exit "$code"

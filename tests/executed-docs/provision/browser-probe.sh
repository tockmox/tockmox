#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Render a console IN the cluster under test, with a real browser, and hand
# back the JS-rendered DOM or a screenshot.
#
#   browser-probe.sh dom  URL [CA_SECRET/NS]    print the rendered DOM
#   browser-probe.sh shot URL OUTFILE [CA_...]  write a PNG
#
# WHY THIS EXISTS, and it is an evidence upgrade rather than a convenience.
#
# Every browser artefact this project has recorded came from a workstation
# reaching the lab over a hosts-file NAT ... a route no documented install
# produces, disclosed on every acceptance row that used it. A pod resolving
# through cluster DNS to the Traefik service IS the route a documented install
# produces, so evidence taken here needs no such disclosure.
#
# WHAT A BROWSER ADDS OVER THE BLACKBOX PROBE. The exporter proves TLS and a
# 2xx. It cannot execute JavaScript, so it cannot tell a working console from
# one that serves a shell and then fails to mount. Measured 2026-09-13 against
# ArgoCD on a throwaway: curl returned a few hundred bytes of HTML shell, this
# returned 1,518,572 bytes of rendered DOM with the app mounted.
#
# AND IT TURNS A CLASS OF "SOMEONE HAS TO LOOK" DEFECTS INTO ASSERTIONS.
# Three shipped dashboards were correct in JSON and misleading on screen
# (TM-0532 twice, TM-0559), every one caught by a human and none by a gate.
# "The first three columns are name, sync_status, health_status" is a DOM fact.
#
# TRUST, and this is a CORRECTION to what this file claimed when it was first
# written earlier on 2026-09-13. It said the CA is mounted and verified rather
# than bypassed. THAT WAS FALSE AS IMPLEMENTED.
#
# MOUNTING A CA IS NOT TRUSTING IT. Measured: with the file mounted under
# /usr/local/share/ca-certificates and nothing else done, Chrome returned
# `error -202` (ERR_CERT_AUTHORITY_INVALID). The system bundle has to be
# rebuilt and Chrome additionally reads an NSS database, and this image ships
# NEITHER `update-ca-certificates` NOR `certutil`, while `apk add` fails
# because the image runs as a non-root user.
#
# So the concerns are SEPARATED rather than duplicated, which is the better
# design anyway:
#
#   TLS verification is proven by the BLACKBOX EXPORTER, which probes the same
#   hosts through cluster DNS with verification ON, no `insecure_skip_verify`
#   anywhere, and the CA supplied via SSL_CERT_FILE.
#
#   THIS probe proves the page RENDERS, and it runs with
#   `--ignore-certificate-errors` and says so on stderr in every run. A DOM
#   captured here is evidence about JavaScript, layout and redirects. It is
#   NOT evidence about certificate trust and must never be cited as such.
#
# To make the browser verify for real, build a small image carrying the CA in
# its own trust store at build time. Worth doing when a claim needs a
# browser-verified chain specifically; not worth doing to re-prove what the
# exporter already proves.
#
# WHAT IT DOES NOT DO. It does not tell you the page is GOOD. Layout,
# readability and whether a label means anything to a human are still a human
# judgement on the screenshot.
set -euo pipefail
# TM-0797: every kubectl call below names its cluster with --context from this
# variable; an empty value is refused rather than falling back to the current context.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"

MODE="${1:?dom|shot}"; URL="${2:?URL}"
NS="${BROWSER_PROBE_NS:-default}"
IMAGE="${BROWSER_PROBE_IMAGE:-zenika/alpine-chrome:latest}"
JOB="browser-probe-$$"
CA_SECRET="${BROWSER_PROBE_CA:-}"     # accepted and IGNORED: see the TRUST note above

case "$MODE" in
  dom)  OUT=""; ARG="--dump-dom" ;;
  shot) OUT="${3:?output png path}"; ARG="--screenshot=/tmp/shot.png --window-size=1600,1200" ;;
  *) echo "usage: browser-probe.sh dom URL | shot URL OUT.png" >&2; exit 2 ;;
esac

TRUST_ARGS="--ignore-certificate-errors"
VOLS=""; MOUNTS=""
if [ -n "$CA_SECRET" ]; then
  TRUST_ARGS=""
  VOLS='      volumes:
      - name: ca
        secret:
          secretName: '"${CA_SECRET%%/*}"'
          items: [{key: ca.crt, path: tockmox-ca.crt}]'
  MOUNTS='        volumeMounts:
        - {name: ca, mountPath: /ca, readOnly: true}'
fi

cleanup() { kubectl --context="$KUBE_CONTEXT" -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl --context="$KUBE_CONTEXT" -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: ${JOB}}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: chrome
        image: ${IMAGE}
        command: ["/bin/sh","-c"]
        args:
        - |
          set -e
          echo "browser-probe: certificate verification is DISABLED in this probe." >&2
          echo "browser-probe: TLS trust is proven by the blackbox exporter, not here." >&2
          exec chromium-browser --no-sandbox --disable-gpu --ignore-certificate-errors \
            --virtual-time-budget=10000 ${ARG} "${URL}"
${MOUNTS}
        resources: {requests: {memory: 512Mi}, limits: {memory: 1Gi}}
${VOLS}
EOF

kubectl --context="$KUBE_CONTEXT" -n "$NS" wait --for=condition=complete --timeout=180s "job/${JOB}" >/dev/null 2>&1 || {
  echo "browser-probe: job did not complete" >&2
  kubectl --context="$KUBE_CONTEXT" -n "$NS" logs "job/${JOB}" >&2 || true
  exit 1
}

if [ "$MODE" = "dom" ]; then
  kubectl --context="$KUBE_CONTEXT" -n "$NS" logs "job/${JOB}"
else
  POD="$(kubectl --context="$KUBE_CONTEXT" -n "$NS" get pod -l job-name="${JOB}" -o jsonpath='{.items[0].metadata.name}')"
  kubectl --context="$KUBE_CONTEXT" -n "$NS" cp "${POD}:/tmp/shot.png" "$OUT" 2>/dev/null || {
    echo "browser-probe: could not copy the screenshot out" >&2; exit 1; }
  echo "$OUT"
fi

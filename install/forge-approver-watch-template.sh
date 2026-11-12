#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# forge-approver-watch-template.sh ... print the objects that run the forge's approvers
# watcher (install/forge-approver-watch.py), for `bootstrap-forge` to apply beside the forge:
#
#   forge-approver-watch-template.sh --namespace NS --image IMAGE [--release NAME]
#       [--identity-namespace NS] [--identity-service NAME] [--monitoring-namespace NS]
#       [--admin-group G]
#
# One Deployment, <release>-approver-watch, whose script comes from the ConfigMap
# <release>-approver-watch-script and whose two credentials come from the Secret
# <release>-approver-watch (forge-token, authentik-token). Nothing else is granted:
#
#   Kubernetes   a ServiceAccount with no Role and no mounted token
#   the forge    a token scoped read:organization and read:repository (the team's members, and
#                the open pull requests and their reviews), for a user that is in no team that can
#                write; it cannot merge, approve, change the rule or change membership
#   Authentik    a token that may view the one admin group (the identity layer's blueprint)
#
# THE FENCE, a default-deny pair on the watcher's own pod:
#   ingress  Prometheus's pods in the monitoring namespace, on the metrics port, nothing else
#   egress   the forge's pods on 3000, Authentik's server pods on 9000, and DNS
# Authentik's namespace admits only Traefik and Prometheus (the policy layer), so a second
# policy, applied here into that namespace, admits this one pod to the server on 9000.
# The forge's own policy already admits every pod of its namespace.
#
# Prometheus scrapes it through the PodMonitor tockmox-forge-approver-watch that the observability
# layer renders with siteForge.approverWatch (charts/tockmox-observability/templates/site-forge-monitor.yaml),
# not here: the PodMonitor kind does not exist on a fresh cluster until the CRDs layer has synced,
# which is after bootstrap-forge. The two alerts that read it are TockmoxForgeApproverOutsideGroup
# and TockmoxForgeApproversCheckDown (site-forge-rules.yaml).
# ============================================================================
set -euo pipefail

RELEASE="tockmox-forge"; FORGE_NS=""; IMAGE=""; IDENTITY_NS="tockmox-authentik"
IDENTITY_SVC="tockmox-identity-authentik-server"; MONITORING_NS="tockmox-monitoring"; ADMIN_GROUP="tockmox-admins"; SCRIPT_SHA="none"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:?--release needs a name}"; shift 2 ;;
    --namespace) FORGE_NS="${2:?--namespace needs a name}"; shift 2 ;;
    --image) IMAGE="${2:?--image needs an image}"; shift 2 ;;
    --identity-namespace) IDENTITY_NS="${2:?--identity-namespace needs a name}"; shift 2 ;;
    --identity-service) IDENTITY_SVC="${2:?--identity-service needs a name}"; shift 2 ;;
    --monitoring-namespace) MONITORING_NS="${2:?--monitoring-namespace needs a name}"; shift 2 ;;
    --admin-group) ADMIN_GROUP="${2:?--admin-group needs a name}"; shift 2 ;;
    --script-sha) SCRIPT_SHA="${2:?--script-sha needs a checksum}"; shift 2 ;;
    *) echo "forge-approver-watch-template.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in RELEASE FORGE_NS IDENTITY_NS IDENTITY_SVC MONITORING_NS; do
  [[ "${!v}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "forge-approver-watch-template.sh: $v is not a Kubernetes name: '${!v}'" >&2; exit 2; }
done
[[ "$IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { echo "forge-approver-watch-template.sh: --image is required: '$IMAGE'" >&2; exit 2; }
[[ "$ADMIN_GROUP" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "forge-approver-watch-template.sh: --admin-group is not a group name: '$ADMIN_GROUP'" >&2; exit 2; }
[[ "$SCRIPT_SHA" =~ ^[A-Za-z0-9]+$ ]] || { echo "forge-approver-watch-template.sh: --script-sha is not a checksum: '$SCRIPT_SHA'" >&2; exit 2; }
NAME="${RELEASE}-approver-watch"
PORT=9470

cat <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NAME}
  namespace: ${FORGE_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: ${FORGE_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app.kubernetes.io/name: ${NAME} }
  template:
    metadata:
      labels: { app.kubernetes.io/name: ${NAME} }
      # A changed script restarts the pod; the Secret is re-read on every check and needs no restart.
      annotations: { tockmox.io/script-sha256: "${SCRIPT_SHA}" }
    spec:
      serviceAccountName: ${NAME}
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        # The Secret's files are root's; group 1000 with mode 0440 is what lets the watcher read them.
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: watch
          image: ${IMAGE}
          command: [python3, /opt/watch/forge-approver-watch.py]
          env:
            - { name: HOME, value: /tmp }
            - { name: PYTHONDONTWRITEBYTECODE, value: "1" }
            - { name: AUTHENTIK_URL, value: "http://${IDENTITY_SVC}.${IDENTITY_NS}.svc.cluster.local" }
            - { name: AUTHENTIK_TOKEN_FILE, value: /run/watch/authentik-token }
            - { name: ADMIN_GROUP, value: "${ADMIN_GROUP}" }
            - { name: FORGE_URL, value: "http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000" }
            - { name: FORGE_TOKEN_FILE, value: /run/watch/forge-token }
            - { name: LISTEN, value: "0.0.0.0:${PORT}" }
          ports:
            - { name: metrics, containerPort: ${PORT}, protocol: TCP }
          readinessProbe:
            httpGet: { path: /healthz, port: metrics }
            periodSeconds: 15
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { cpu: 200m, memory: 128Mi }
          volumeMounts:
            - { name: script, mountPath: /opt/watch, readOnly: true }
            - { name: credentials, mountPath: /run/watch, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - { name: script, configMap: { name: ${NAME}-script } }
        - { name: credentials, secret: { secretName: ${NAME}, defaultMode: 0440 } }
        - { name: tmp, emptyDir: { sizeLimit: 16Mi } }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NAME}
  namespace: ${FORGE_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: ${NAME} }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ${MONITORING_NS} }
          podSelector:
            matchLabels: { app.kubernetes.io/name: prometheus }
      ports:
        - { port: ${PORT}, protocol: TCP }
  egress:
    - to:
        - podSelector:
            matchLabels: { app.kubernetes.io/instance: ${RELEASE} }
      ports:
        - { port: 3000, protocol: TCP }
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ${IDENTITY_NS} }
          podSelector:
            matchLabels: { app.kubernetes.io/name: authentik, app.kubernetes.io/component: server }
      ports:
        - { port: 9000, protocol: TCP }
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { port: 53, protocol: UDP }
        - { port: 53, protocol: TCP }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NAME}
  namespace: ${IDENTITY_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: authentik, app.kubernetes.io/component: server }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ${FORGE_NS} }
          podSelector:
            matchLabels: { app.kubernetes.io/name: ${NAME} }
      ports:
        - { port: 9000, protocol: TCP }
YAML

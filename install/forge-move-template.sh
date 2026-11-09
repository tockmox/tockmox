#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# forge-move-template.sh ... print the objects the console's "Move to my own forge"
# runs with, for `bootstrap-forge` to apply beside the forge:
#
#   forge-move-template.sh --namespace NS --argocd-namespace NS --image IMAGE [--release NAME]
#
# One suspended CronJob, <release>-move, whose Job runs install/forge-move.sh
# --in-cluster (the same script `move-forge` runs from a laptop, from the ConfigMap
# <release>-move-script). Its pod spec is FIXED: what changes from run to run (the
# target, check / move / finish, who asked) and the credentials come in ONE Secret,
# <release>-move-request, which the console's tockmox-actions service creates owned
# by the Job, so it goes when the Job does. The template never runs on a schedule:
# suspend is true and its schedule is a date that does not exist.
#
# THE GRANT, the ServiceAccount <release>-move and nothing else:
#   forge namespace  get the one Secret <release>-admin (the change is opened and the
#                    repository archived as the forge's admin, as the CLI does)
#   Argo CD's        get and patch the one Secret tockmox-site-repo-own, create Secrets
#                    (Kubernetes cannot limit create by name; the script creates only
#                    that one), get and patch the one Application tockmox-root
# Patching tockmox-root is the widest right here: whoever can edit the root can point
# Argo CD anywhere. The Job reaches that step only with mode=finish, after an approver
# other than the requester merged the change naming the target, and the console's
# admission policy pins this pod spec (charts/tockmox-ai, tockmox-actions-move).
# ============================================================================
set -euo pipefail

RELEASE="tockmox-forge"; FORGE_NS=""; ARGO_NS=""; IMAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:?--release needs a name}"; shift 2 ;;
    --namespace) FORGE_NS="${2:?--namespace needs a name}"; shift 2 ;;
    --argocd-namespace) ARGO_NS="${2:?--argocd-namespace needs a name}"; shift 2 ;;
    --image) IMAGE="${2:?--image needs an image}"; shift 2 ;;
    *) echo "forge-move-template.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in RELEASE FORGE_NS ARGO_NS; do
  [[ "${!v}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "forge-move-template.sh: $v is not a Kubernetes name: '${!v}'" >&2; exit 2; }
done
[[ "$IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { echo "forge-move-template.sh: --image is required: '$IMAGE'" >&2; exit 2; }
NAME="${RELEASE}-move"

cat <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NAME}
  namespace: ${FORGE_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAME}
  namespace: ${FORGE_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
rules:
  - { apiGroups: [""], resources: [secrets], resourceNames: [${RELEASE}-admin], verbs: [get] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NAME}
  namespace: ${FORGE_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: ${NAME} }
subjects:
  - { kind: ServiceAccount, name: ${NAME}, namespace: ${FORGE_NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAME}
  namespace: ${ARGO_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
rules:
  - { apiGroups: [""], resources: [secrets], resourceNames: [tockmox-site-repo-own], verbs: [get, patch] }
  - { apiGroups: [""], resources: [secrets], verbs: [create] }
  - { apiGroups: [argoproj.io], resources: [applications], resourceNames: [tockmox-root], verbs: [get, patch] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NAME}
  namespace: ${ARGO_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: ${NAME} }
subjects:
  - { kind: ServiceAccount, name: ${NAME}, namespace: ${FORGE_NS} }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${NAME}
  namespace: ${FORGE_NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/managed-by: tockmox-install }
spec:
  # A template only: the console starts each run. Never on a schedule (suspended, and 31 February).
  suspend: true
  schedule: "0 0 31 2 *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 0
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 1800
      ttlSecondsAfterFinished: 600
      template:
        metadata:
          labels: { app.kubernetes.io/name: ${NAME} }
        spec:
          serviceAccountName: ${NAME}
          restartPolicy: Never
          enableServiceLinks: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: move
              image: ${IMAGE}
              command: [bash, /opt/move/forge-move.sh]
              args: [--in-cluster, --namespace, ${FORGE_NS}, --argocd-namespace, ${ARGO_NS},
                     --request, /run/move/request, --credentials, /run/move/push,
                     --read-credentials, /run/move/read, --approval-wait-minutes, "0"]
              env:
                - { name: HOME, value: /tmp }
                - { name: NO_COLOR, value: "1" }
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: [ALL] }
              resources:
                requests: { cpu: 50m, memory: 64Mi }
                limits: { memory: 512Mi }
              volumeMounts:
                - { name: script, mountPath: /opt/move, readOnly: true }
                - { name: request, mountPath: /run/move, readOnly: true }
                - { name: tmp, mountPath: /tmp }
          volumes:
            - { name: script, configMap: { name: ${NAME}-script } }
            - { name: request, secret: { secretName: ${NAME}-request, defaultMode: 0440 } }
            - { name: tmp, emptyDir: { sizeLimit: 1Gi } }
YAML

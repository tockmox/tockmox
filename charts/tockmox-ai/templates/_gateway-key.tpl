{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
Whether the console-key Job renders: "true" or "". One answer for two
templates, the Job (gateway-key.yaml) and the check CronJob that watches the
key it minted (console-key-check.yaml, TM-0982), so the check can never run
against a key no Job owns. Unset follows the console AND the gateway AND the
console reading `secretName`; true forces it on and refuses, with a sentence
each, when there is nothing to mint for or the console would read another
Secret; false keeps the manual step.
*/}}
{{- define "tockmox-ai.consoleKeyOn" -}}
{{- $ck := .Values.modelGateway.consoleKey | default dict -}}
{{- $owui := index .Values "open-webui" | default dict -}}
{{- $consoleOn := include "tockmox.appEnabled" (dict "ctx" $ "app" "openWebui") -}}
{{- $gatewayOn := include "tockmox.appEnabled" (dict "ctx" $ "app" "litellm") -}}
{{- $secretName := $ck.secretName | default "tockmox-openwebui-gateway" -}}
{{- $secretKey := $ck.secretKey | default "api-key" -}}
{{- $wired := and $consoleOn $gatewayOn ($owui.enableOpenaiApi) (eq ($owui.openaiApiKeyExistingSecret | default "") $secretName) -}}
{{- $on := false -}}
{{- if eq (kindOf $ck.enabled) "invalid" -}}
  {{- $on = $wired -}}
{{- else if $ck.enabled -}}
  {{- if not (and $consoleOn $gatewayOn) -}}
  {{- fail "modelGateway.consoleKey.enabled is true but the console or the gateway is not enabled, so there is nothing to mint a key for or nothing to mint it with. Leave it unset to follow both, or turn them on." -}}
  {{- end -}}
  {{- if ne ($owui.openaiApiKeyExistingSecret | default "") $secretName -}}
  {{- fail (printf "modelGateway.consoleKey.enabled is true and it would write Secret %q, but open-webui.openaiApiKeyExistingSecret is %q, so the console would never read the key it mints. Make the two names agree." $secretName ($owui.openaiApiKeyExistingSecret | default "")) -}}
  {{- end -}}
  {{- if ne ($owui.openaiApiKeyExistingSecretKey | default "") $secretKey -}}
  {{- fail (printf "modelGateway.consoleKey.secretKey is %q but open-webui.openaiApiKeyExistingSecretKey is %q; the console reads a key the Job does not write. Make the two agree." $secretKey ($owui.openaiApiKeyExistingSecretKey | default "")) -}}
  {{- end -}}
  {{- $on = true -}}
{{- end -}}
{{- if $on }}true{{ end -}}
{{- end -}}

{{/*
The pod template of the console-key Job (templates/gateway-key.yaml), in a
helper so the Job's name can be a hash of it. Takes a dict: ctx, ck (the
modelGateway.consoleKey values), ns, gateway (the gateway's base URL),
secretName, secretKey, lit (the litellm values, for the master key reference),
consolePods (the console's pod names, space-separated: the pods the Job
deletes after it replaces a key the gateway rejected, so they restart on the
new one).
*/}}
{{- define "tockmox-ai.gatewayKeyPod" -}}
{{- $ctx := .ctx -}}
{{- $ck := .ck -}}
metadata:
  labels:
    {{- include "tockmox.labels" $ctx | nindent 4 }}
    app.kubernetes.io/name: tockmox-gateway-key
spec:
  # OnFailure, not Never: a pod that lost the gateway mid-poll is retried in
  # place under the Job's backoff rather than leaving a Failed pod per attempt.
  restartPolicy: OnFailure
  serviceAccountName: tockmox-gateway-key
  # Needs the API: kubectl reads and creates one Secret (the Role beside the
  # Job). Token kept on purpose (TM-0759); gate allowlist in
  # tools/check-sa-tokens.sh.
  automountServiceAccountToken: true
  {{- with $ctx.Values.modelGateway.database.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: mint
      image: {{ include "tockmox.image" (dict "ctx" $ctx "repo" ($ck.image | default "alpine/k8s:1.37.1")) }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources:
        requests: { cpu: 20m, memory: 64Mi }
        limits:   { memory: 128Mi }
      env:
        - name: NS
          value: {{ .ns | quote }}
        - name: GATEWAY
          value: {{ .gateway | quote }}
        - name: SECRET_NAME
          value: {{ .secretName | quote }}
        - name: SECRET_KEY
          value: {{ .secretKey | quote }}
        - name: KEY_ALIAS
          value: {{ $ck.alias | default "open-webui" | quote }}
        - name: GENERATE_EXTRA
          value: {{ ($ck.generateExtra | default dict) | toJson | quote }}
        - name: WAIT_SECONDS
          value: {{ $ck.waitSeconds | default 600 | quote }}
        - name: CONSOLE_PODS
          value: {{ .consolePods | quote }}
        # The master key, for one request. Same Secret the gateway reads; until
        # it exists this pod waits in CreateContainerConfigError naming it.
        - name: PROXY_MASTER_KEY
          valueFrom:
            secretKeyRef:
              name: {{ .lit.masterkeySecretName | default "tockmox-litellm" }}
              key: {{ .lit.masterkeySecretKey | default "masterkey" }}
      command: ["sh", "-c"]
      args:
        - |
          set -u
          # 1. Wait for the gateway. Readiness answers 200 only once the proxy
          #    has its database, which is the thing /key/generate needs, and
          #    the thing an existing key is checked against.
          i=0
          until [ "$(curl -s -o /dev/null -w '%{http_code}' "$GATEWAY/health/readiness" 2>/dev/null)" = "200" ]; do
            i=$((i+5))
            if [ "$i" -ge "$WAIT_SECONDS" ]; then
              echo "gateway at $GATEWAY not ready after ${WAIT_SECONDS}s; giving this attempt back to the Job's backoff" >&2
              exit 1
            fi
            sleep 5
          done
          # 2. Idempotence, checked against the gateway rather than assumed:
          #    an existing Secret is the job done only if the gateway still
          #    accepts its key. A gateway that was turned off and on again
          #    comes back with a fresh database that holds no keys at all, so
          #    the Secret outlives the key it holds (TM-0977); a 401 here is
          #    that case, and the key is replaced. Any other answer leaves the
          #    Secret alone: this never deletes a key it cannot prove dead.
          remint=
          if kubectl -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
            have=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o "jsonpath={.data.$SECRET_KEY}" | base64 -d)
            code=$(curl -s -o /dev/null -w '%{http_code}' "$GATEWAY/v1/models" -H "Authorization: Bearer $have" 2>/dev/null)
            case "$code" in
              200) echo "Secret $NS/$SECRET_NAME exists and the gateway accepts its key; nothing to mint"; exit 0 ;;
              401) echo "Secret $NS/$SECRET_NAME exists but the gateway rejects its key (HTTP 401: its database no longer holds it); minting a replacement"; remint=1 ;;
              *)   echo "Secret $NS/$SECRET_NAME exists and the gateway answered HTTP $code to its key; not replacing a key that may still be good. Giving this attempt back to the Job's backoff" >&2; exit 1 ;;
            esac
          fi
          # 3. Mint. The body is the alias plus whatever generateExtra adds;
          #    no model list means LiteLLM's default list for new keys.
          mint() {
            body=$(printf '%s' "$GENERATE_EXTRA" | jq -c --arg a "$1" '. + {key_alias: $a}')
            curl -s -X POST "$GATEWAY/key/generate" \
              -H "Authorization: Bearer $PROXY_MASTER_KEY" \
              -H 'Content-Type: application/json' \
              -d "$body"
          }
          resp=$(mint "$KEY_ALIAS")
          key=$(printf '%s' "$resp" | jq -r '.key // empty' 2>/dev/null)
          if [ -z "$key" ]; then
            # An alias LiteLLM already holds (the Secret was deleted after a
            # mint) is the one refusal worth a second try.
            alias2="${KEY_ALIAS}-$(date -u +%Y%m%d%H%M%S)"
            echo "no key in the answer for alias $KEY_ALIAS ($(printf '%s' "$resp" | jq -c 'del(.key)' 2>/dev/null || printf '%s' "$resp" | cut -c1-200)); retrying once as $alias2" >&2
            resp=$(mint "$alias2")
            key=$(printf '%s' "$resp" | jq -r '.key // empty' 2>/dev/null)
          fi
          # 4. Refuse an empty key rather than write a Secret the console
          #    would start with and fail on.
          if [ -z "$key" ]; then
            echo "gateway returned no key; not creating $SECRET_NAME. Answer (key field removed): $(printf '%s' "$resp" | jq -c 'del(.key)' 2>/dev/null || printf '%s' "$resp" | cut -c1-200)" >&2
            exit 1
          fi
          # 5. Exactly one Secret, by the configured name. A rejected key is
          #    replaced in place (update, scoped to this name), so there is no
          #    moment with no Secret for the console to start against. A
          #    create that loses a race with a hand-made Secret is success too.
          if [ -n "$remint" ]; then
            if ! kubectl -n "$NS" create secret generic "$SECRET_NAME" --from-literal="$SECRET_KEY=$key" --dry-run=client -o yaml | kubectl -n "$NS" replace -f - 2>/tmp/err; then
              cat /tmp/err >&2
              exit 1
            fi
            echo "replaced the key in Secret $NS/$SECRET_NAME (alias ${alias2:-$KEY_ALIAS})"
            # 6. The console reads the key from the Secret at pod start and
            #    never again, so a replaced key needs the console restarted.
            #    Deleting its pods by name (a StatefulSet recreates them) is
            #    the narrowest verb that does it; the Role names those pods.
            #    A console that cannot be restarted is a dead console, so the
            #    Job fails loudly rather than report a healthy layer.
            # shellcheck disable=SC2086
            if ! kubectl -n "$NS" delete pod $CONSOLE_PODS --ignore-not-found 2>/tmp/err; then
              echo "replaced the console's key but could not restart the console ($CONSOLE_PODS); restart it by hand (kubectl -n $NS rollout restart statefulset -l app.kubernetes.io/name=open-webui)" >&2
              cat /tmp/err >&2
              exit 1
            fi
            echo "restarted the console ($CONSOLE_PODS) so it reads the new key"
            exit 0
          fi
          if kubectl -n "$NS" create secret generic "$SECRET_NAME" --from-literal="$SECRET_KEY=$key" 2>/tmp/err; then
            echo "created Secret $NS/$SECRET_NAME for the console (alias ${alias2:-$KEY_ALIAS})"
            exit 0
          fi
          if grep -q AlreadyExists /tmp/err; then
            echo "Secret $NS/$SECRET_NAME appeared while minting; keeping it"
            exit 0
          fi
          cat /tmp/err >&2
          exit 1
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
{{- end -}}

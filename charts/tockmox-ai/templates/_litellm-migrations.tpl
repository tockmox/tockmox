{{- /*
The migrations Job's pod template, called with the litellm subchart's context
(`.Subcharts.litellm`), so `.Values` is the subchart's coalesced values and the
`litellm.*` helpers resolve as they do inside the subchart.

This is litellm-helm 1.100.1's templates/migrations-job.yaml `spec.template`,
unchanged except for indentation. Keep it that way: tools/check-upgrade-safety.sh
F1b renders the vendored subchart's Job with the same values and fails if the
pod specs differ, which is how an upstream change on a LiteLLM bump reaches
this file. Port the change here, do not silence the check.

Its rendered text is also hashed into the Job's name
(templates/litellm-migrations-job.yaml), so it must be deterministic: no
timestamps, no random values, no lookups.
*/ -}}
{{- define "tockmox-ai.litellmMigrationsPod" -}}
metadata:
  labels:
    {{- include "litellm.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.migrationJob.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "litellm.migrationServiceAccountName" . }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.migrationJob.extraInitContainers }}
  initContainers:
    {{- tpl (toYaml .) $ | nindent 4 }}
  {{- end }}
  containers:
    - name: prisma-migrations
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      command: ["python", "litellm/proxy/prisma_migration.py"]
      workingDir: "/app"
      env:
        {{- if .Values.db.useExisting }}
        - name: DATABASE_USERNAME
          valueFrom:
            secretKeyRef:
              name: {{ .Values.db.secret.name }}
              key: {{ .Values.db.secret.usernameKey }}
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ .Values.db.secret.name }}
              key: {{ .Values.db.secret.passwordKey }}
        - name: DATABASE_HOST
          {{- if .Values.db.secret.endpointKey }}
          valueFrom:
            secretKeyRef:
              name: {{ .Values.db.secret.name }}
              key: {{ .Values.db.secret.endpointKey }}
          {{- else }}
          value: {{ .Values.db.endpoint }}
          {{- end }}
        - name: DATABASE_NAME
          value: {{ .Values.db.database }}
        - name: DATABASE_URL
          value: {{ .Values.db.url | quote }}
        {{- else if .Values.db.deployStandalone }}
        - name: DATABASE_URL
          value: postgresql://{{ .Values.postgresql.auth.username }}:{{ .Values.postgresql.auth.password }}@{{ .Release.Name }}-postgresql/{{ .Values.postgresql.auth.database }}
        {{- end }}
        {{- if .Values.envVars }}
        {{- range $key, $val := .Values.envVars }}
        - name: {{ $key }}
          value: {{ $val | quote }}
        {{- end }}
        {{- end }}
        {{- with .Values.extraEnvVars }}
          {{- toYaml . | nindent 8 }}
        {{- end }}
        - name: DISABLE_SCHEMA_UPDATE
          value: "false"
      {{- with .Values.volumeMounts }}
      volumeMounts:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.migrationJob.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- with .Values.migrationJob.extraContainers }}
    {{- tpl (toYaml .) $ | nindent 4 }}
  {{- end }}
  {{- with .Values.volumes }}
  volumes:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  restartPolicy: OnFailure
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

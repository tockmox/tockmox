{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
THE RESTORE-DRILL REGISTER WRITER, ONE COPY (TM-0459).

Every restore drill (the model gateway's, Authentik's) ends by recording its
verdict. Until 0.9.0 each drill carried its own copy of the recording code and
it wrote a row into a ConfigMap, cut to the last 24 rows, with every step ending
in `|| true`: a PASS whose row was never written exited 0, and the freshness
alerts, which key on a failed Job, never fired. The register now lives in the
shipped object store, in a bucket of its own, one JSON object per run, and the
code that writes it lives here so the two drills cannot drift apart.

WHAT THE WRITER PROMISES. A run is recorded only when the object was written
AND read back AND the bytes read back hash to the bytes written (the register
is evidence, so it is checked on the read, never on the writer's exit code).
Anything else sets REG_ERR and leaves RECORDED=0, and the drill's `finish` turns
that into a non-zero exit whatever the restore's own verdict was: a drill that
cannot record its verdict has failed, and `TockmoxRestoreDrillFailed` pages on a
failed Job.

WHERE IT RUNS. Inlined into the drill's `sh -c` script by
`tockmox.drillRegister.script` (below), so it is POSIX sh, curl, jq and
sha256sum, all in the image the drill already uses. It signs with curl's native
SigV4 (`--aws-sigv4`), the way the identity layer's pg_dump uploader does, so it
adds no client library. The SigV4 REGION is read from the credentials Secret's
REGION key and never defaulted: Garage rejects a request signed for any other
region, and a writer that signs for the wrong one looks healthy while writing
nothing (the barman archiver died of it while restores kept working).
*/}}

{{/*
The container env the writer reads. Arguments: ctx (root context), reg (the
chart's `restoreDrill.register` map, may be empty). Defaults live HERE so both
drills share them, and the platform layer's `garage.drillRegister` defaults must
agree (tools/check-notify-and-drill.sh D4 asserts that they do).
*/}}
{{- define "tockmox.drillRegister.env" -}}
{{- $reg := .reg | default dict -}}
- name: REG_ENDPOINT
  value: {{ $reg.endpoint | default "http://tockmox-garage.tockmox-platform.svc:3900" | quote }}
- name: REG_BUCKET
  value: {{ $reg.bucket | default "tockmox-drill-register" | quote }}
- name: REG_CHART_VERSION
  value: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" | quote }}
- name: REG_JOB
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['job-name']
- name: REG_AK
  valueFrom:
    secretKeyRef:
      name: {{ $reg.credentialsSecretName | default "tockmox-drill-register-credentials" | quote }}
      key: ACCESS_KEY_ID
- name: REG_SK
  valueFrom:
    secretKeyRef:
      name: {{ $reg.credentialsSecretName | default "tockmox-drill-register-credentials" | quote }}
      key: ACCESS_SECRET_KEY
- name: REG_REGION
  valueFrom:
    secretKeyRef:
      name: {{ $reg.credentialsSecretName | default "tockmox-drill-register-credentials" | quote }}
      key: REGION
{{- end -}}

{{/*
The shell the drill inlines. The caller sets, before calling `register_write`:
  REG_DB       the drilled database's name (the object's key prefix)
  REG_SERVER   the server name its backups are archived under
  STAMP        the run's UTC time, YYYY-MM-DDTHH:MM:SSZ
  VERDICT      PASS or FAIL
  DETAIL       the one-line detail the row carries (already through `why`)
  BACKUP_ID    the backup the run pinned, or empty
  ROW          the human-readable row, kept for the log and carried in the object
  REG_IMAGE    the Postgres image the drill cluster ran on, or empty
  REG_EXTRA_JSON  optional JSON object of extra measured fields
and the script sets REG_START=$(date +%s) once at the top. `register_write`
returns 0 and sets RECORDED=1 only when the read-back matched; otherwise it
returns 1 with REG_ERR set to the reason, on one line.
*/}}
{{- define "tockmox.drillRegister.script" -}}
# ---- the register writer (tockmox-common: tockmox.drillRegister.script) -------------
# The failing step's own words on one line, for the register row (HL-0863): a pod that dies in
# seconds is gone before Alloy tails it, so the row is the only record of why. No newline, no
# "=" (later key=value fields are evidence), no double quote and no backslash, at most 240
# characters.
why() { printf '%s' "$1" | tr '\n\r\t"=\\' "   ': " | tr -s ' ' | cut -c1-240; }

REG_START=$(date +%s)
REG_TMP=/tmp/drill-register
RECORDED=0
REG_ERR=""

# One signed request. $1 method, $2 URL, $3 output file, $4 extra curl args (none or -T file).
# Prints the HTTP status. The status is what is asserted on: curl exits 0 on a 403.
reg_curl() {
  _m="$1"; _u="$2"; _o="$3"; shift 3
  curl -sS --max-time 60 -X "$_m" -o "$_o" -w '%{http_code}' \
    --aws-sigv4 "aws:amz:${REG_REGION}:s3" --user "${REG_AK}:${REG_SK}" \
    "$@" "$_u" 2>"$REG_TMP/curl.err"
}

# Write this run's row as one object, read it back, compare the bytes. Never overwrites an
# earlier run: the key carries the run's own timestamp and verdict.
register_write() {
  RECORDED=0; REG_ERR=""
  for _v in REG_ENDPOINT REG_BUCKET REG_AK REG_SK; do
    eval "_x=\${$_v:-}"
    [ -n "$_x" ] || { REG_ERR="register setting ${_v} is empty"; return 1; }
  done
  [ -n "${REG_REGION:-}" ] || { REG_ERR="REGION is empty in the register credentials Secret; Garage refuses a request signed for any region but its own"; return 1; }
  mkdir -p "$REG_TMP" 2>/dev/null || { REG_ERR="cannot create ${REG_TMP}"; return 1; }
  rm -f "$REG_TMP/row.json" "$REG_TMP/got.json" "$REG_TMP/put.out" "$REG_TMP/curl.err" "$REG_TMP/jq.err"
  [ -n "${REG_EXTRA_JSON:-}" ] || REG_EXTRA_JSON='{}'
  REG_KEY="${REG_DB}/$(printf '%s' "$STAMP" | tr -d ':-')-${VERDICT}.json"
  jq -nc --arg time "$STAMP" --arg verdict "$VERDICT" --arg db "$REG_DB" --arg backup "${BACKUP_ID:-none}" \
    --arg server "${REG_SERVER:-}" --arg image "${REG_IMAGE:-}" --arg detail "${DETAIL:-}" --arg row "${ROW:-}" \
    --arg job "${REG_JOB:-}" --arg cv "${REG_CHART_VERSION:-}" --argjson dur "$(( $(date +%s) - REG_START ))" \
    --argjson extra "$REG_EXTRA_JSON" \
    '{schema:1, time:$time, verdict:$verdict, db:$db, backupId:$backup, serverName:$server, image:$image,
      durationSeconds:$dur, detail:$detail, row:$row, job:$job, chartVersion:$cv} + $extra' \
    > "$REG_TMP/row.json" 2>"$REG_TMP/jq.err" \
    || { REG_ERR="cannot build the register object: $(why "$(cat "$REG_TMP/jq.err")")"; return 1; }
  _sum=$(sha256sum "$REG_TMP/row.json" | cut -d' ' -f1)
  _url="${REG_ENDPOINT}/${REG_BUCKET}/${REG_KEY}"

  _code=$(reg_curl PUT "$_url" "$REG_TMP/put.out" -H "x-amz-content-sha256: ${_sum}" -H 'Content-Type: application/json' -T "$REG_TMP/row.json"); _rc=$?
  if [ "$_rc" -ne 0 ] || [ "$_code" != 200 ]; then
    REG_ERR="write of s3://${REG_BUCKET}/${REG_KEY} refused (curl exit ${_rc}, http ${_code:-none}): $(why "$(cat "$REG_TMP/curl.err" "$REG_TMP/put.out" 2>/dev/null)")"
    return 1
  fi

  _code=$(reg_curl GET "$_url" "$REG_TMP/got.json"); _rc=$?
  if [ "$_rc" -ne 0 ] || [ "$_code" != 200 ]; then
    REG_ERR="read back of s3://${REG_BUCKET}/${REG_KEY} failed (curl exit ${_rc}, http ${_code:-none}): $(why "$(cat "$REG_TMP/curl.err" 2>/dev/null)")"
    return 1
  fi
  _got=$(sha256sum "$REG_TMP/got.json" | cut -d' ' -f1)
  if [ "$_got" != "$_sum" ]; then
    REG_ERR="read back of s3://${REG_BUCKET}/${REG_KEY} differs from what was written (wrote sha256 ${_sum}, read ${_got})"
    return 1
  fi
  RECORDED=1
  echo "register: recorded s3://${REG_BUCKET}/${REG_KEY} sha256=${_sum}"
  return 0
}
# ---- end of the register writer ------------------------------------------------------
{{- end -}}

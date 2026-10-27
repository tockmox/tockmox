#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the SCRIPTS the chart ships, not just render them, for three small cards
# whose defect is in script behaviour and renders cleanly when wrong.
#
#   ./tools/check-notify-and-drill.sh             run the assertions
#   ./tools/check-notify-and-drill.sh --selftest  prove each can go red
#
# B1  The alert bridge writes exactly one `delivery ...` line per alert, with
#     alertname, severity, status, fingerprint, sink and the sink's HTTP code,
#     and never the token or the sink URL (TM-0780). The bridge is extracted
#     from its ConfigMap and run against a stub sink that answers 200, then 403.
# B2  The ntfy Deployment still renders replicas 1, and the reason is written
#     where a reader will find it: in the template and in monitoring.md, with
#     TockmoxNtfyDown named (TM-0779).
# N1  ntfy picks up its auth Secret when it appears or changes (lab F11, 2026-10-08). envFrom is read once, at
#     container start; on a greenfield sync ntfy started one second before sealed-secrets wrote
#     tockmox-ntfy-auth, came up with no users, and every alert after that was a 401. The liveness probe compares
#     the Secret as mounted (an optional volume, which kubelet repopulates) with the environment the container
#     started with, so kubelet restarts ntfy onto the Secret. Its script is extracted and run against a fake
#     mount and environment: absent/absent and equal are healthy; Secret-appeared and Secret-rotated are not.
# D1  The restore drill script, run against a stub kubectl, pins the newest
#     completed Backup, records `backup=<id>` on its register row, and falls back
#     to `backup=none` with no pin when no Backup is visible (TM-0794). A FAIL
#     row carries the field too.
#     It runs the drill cluster on the image the SOURCE cluster runs
#     (spec.imageName, which CNPG always sets), and on the operator default only
#     when the source cannot be read (TM-1023).
# D2  The identity database's restore drill (TM-0788), the same script pointed
#     at Authentik's database, run against the same stub: it recovers from the
#     identity store under the identity cluster's server name, in the identity
#     namespace, pins that cluster's newest completed Backup, and PASSes only
#     when Authentik's user table came back with rows (users=<n> on the row).
#     A restore with an empty user table is a FAIL.
#
# LIMIT: no cluster. Whether CNPG accepts recoveryTarget.backupID from the
# barman-cloud plugin path, and that a Backup CR's status.backupId names what
# the store holds, are the lab's to prove.
set -euo pipefail
cd "$(dirname "$0")/.."
for c in helm python3 jq; do command -v "$c" >/dev/null 2>&1 || { echo "check-notify-and-drill: $c missing" >&2; exit 2; }; done
python3 -c 'import yaml' 2>/dev/null || { echo "check-notify-and-drill: python3 PyYAML missing" >&2; exit 2; }

T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT

helm template t charts/tockmox-observability -f ci/values.yaml > "$T/obs.yaml"
helm template t charts/tockmox-ai -f ci/values.yaml --set modelGateway.database.backup.enabled=true > "$T/ai.yaml"
helm template t charts/tockmox-identity -f ci/values.yaml > "$T/id.yaml"

python3 - "$T" <<'PY'
import sys, yaml
t = sys.argv[1]
for d in yaml.safe_load_all(open(f"{t}/obs.yaml")):
    if d and d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-alert-bridge":
        open(f"{t}/bridge.py", "w").write(d["data"]["bridge.py"])
    if d and d["kind"] == "Deployment" and d["metadata"]["name"] == "tockmox-ntfy":
        open(f"{t}/ntfy.replicas", "w").write(str(d["spec"]["replicas"]))
        sp = d["spec"]["template"]["spec"]; c = sp["containers"][0]
        lp = c.get("livenessProbe") or {}
        open(f"{t}/ntfy.live", "w").write(lp["exec"]["command"][2] if "exec" in lp else "")
        mnt = [m for m in c.get("volumeMounts") or [] if m["name"] == "ntfy-auth"]
        vol = [v for v in sp["volumes"] if v["name"] == "ntfy-auth"]
        env = [e["secretRef"] for e in c.get("envFrom") or [] if "secretRef" in e]
        ok = (len(mnt) == 1 and "subPath" not in mnt[0] and len(vol) == 1 and vol[0]["secret"].get("optional") is True
              and len(env) == 1 and env[0]["name"] == vol[0]["secret"]["secretName"])
        open(f"{t}/ntfy.wiring", "w").write(("ok " + mnt[0]["mountPath"]) if ok else "bad")
for src, out in (("ai.yaml", "drill.sh"), ("id.yaml", "id-drill.sh")):
    for d in yaml.safe_load_all(open(f"{t}/{src}")):
        if d and d["kind"] == "CronJob" and d["metadata"]["name"].endswith("-drill"):
            open(f"{t}/{out}", "w").write(d["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["args"][0])
PY
[ -s "$T/bridge.py" ] && [ -s "$T/drill.sh" ] && [ -s "$T/id-drill.sh" ] || { echo "check-notify-and-drill: bridge, drill or identity drill not rendered" >&2; exit 1; }

# ---- B1 ---------------------------------------------------------------------
SECRET=tok-SECRET-9f3a
cat > "$T/stub.py" <<'PY'
import http.server, sys
code = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
cat > "$T/payload.json" <<'JSON'
{"status":"firing","alerts":[
 {"status":"firing","labels":{"alertname":"Disk Full \"x\"","severity":"critical","namespace":"a"},"annotations":{"summary":"s"},"fingerprint":"abc123"},
 {"status":"resolved","labels":{"alertname":"HighLatency","severity":"warning"},"annotations":{},"fingerprint":"def456"}]}
JSON
bridge_log() { # bridge.py path, sink code, log out
  local py="$1" code="$2" out="$3" sp=$((20000 + RANDOM % 20000)) bp=$((40000 + RANDOM % 20000))
  python3 "$T/stub.py" "$sp" "$code" & local s=$!
  SINK=ntfy NTFY_URL="http://127.0.0.1:$sp" NTFY_TOKEN="$SECRET" PORT=$bp PROBE_INTERVAL=3600 \
    python3 "$py" > "$out" 2>&1 & local b=$!
  for _ in $(seq 50); do curl -fs "http://127.0.0.1:$bp/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
  curl -s -X POST --data @"$T/payload.json" "http://127.0.0.1:$bp/" >/dev/null || true
  sleep 0.3; kill "$b" "$s" 2>/dev/null || true; wait "$b" "$s" 2>/dev/null || true
}
b1() { # py
  bridge_log "$1" 200 "$T/log200"; bridge_log "$1" 403 "$T/log403"
  [ "$(grep -c '^delivery ' "$T/log200")" = 2 ] || return 1
  grep -q '^delivery alertname="Disk Full \\"x\\"" severity=critical status=firing fingerprint="abc123" sink=ntfy http=200 result=ok$' "$T/log200" || return 1
  grep -q '^delivery alertname="HighLatency" severity=warning status=resolved fingerprint="def456" sink=ntfy http=200 result=ok$' "$T/log200" || return 1
  [ "$(grep -c '^delivery ' "$T/log403")" = 2 ] || return 1
  [ "$(grep -c '^delivery .* http=403 result=failed$' "$T/log403")" = 2 ] || return 1
  # No secret and no sink URL on any delivery line.
  if grep -h '^delivery ' "$T/log200" "$T/log403" | grep -e "$SECRET" -e '127.0.0.1' >/dev/null; then return 1; fi
  return 0
}

# ---- B2 ---------------------------------------------------------------------
b2() {
  [ "$(cat "$T/ntfy.replicas")" = 1 ] \
    && grep -q 'TM-0779' charts/tockmox-observability/templates/ntfy.yaml \
    && grep -q 'TockmoxNtfyDown' charts/tockmox-observability/templates/ntfy.yaml \
    && grep -q 'runs as one replica, deliberately' docs/operations/monitoring.md \
    && grep -A8 'runs as one replica, deliberately' docs/operations/monitoring.md | grep 'TockmoxNtfyDown' >/dev/null
}

# ---- N1 ---------------------------------------------------------------------
n1() { # liveness script
  local s="$1" dir; read -r w dir < "$T/ntfy.wiring" || true
  [ "$w" = ok ] && [ -s "$s" ] || return 1
  mkdir -p "$T/n1/bin" "$T/n1/m"
  printf '#!/bin/sh\nexit 0\n' > "$T/n1/bin/wget"; chmod +x "$T/n1/bin/wget"   # ntfy answering /v1/health
  sed "s#$dir#$T/n1/m#g" "$s" > "$T/n1/probe.sh"
  probe() { env -i PATH="$T/n1/bin:$PATH" "$@" sh "$T/n1/probe.sh" >/dev/null 2>&1; }
  rm -f "$T/n1/m/"*
  probe || return 1                                                           # no Secret, none at start: healthy
  printf 'you:$2a$10$x:user' > "$T/n1/m/NTFY_AUTH_USERS"; printf 'alertbridge:alerts:wo' > "$T/n1/m/NTFY_AUTH_ACCESS"
  if probe; then return 1; fi                                                 # Secret appeared after start: restart
  probe NTFY_AUTH_USERS='you:$2a$10$x:user' NTFY_AUTH_ACCESS='alertbridge:alerts:wo' || return 1   # started with it
  if probe NTFY_AUTH_USERS='you:$2a$10$OLD:user' NTFY_AUTH_ACCESS='alertbridge:alerts:wo'; then return 1; fi  # rotated
  printf '#!/bin/sh\nexit 1\n' > "$T/n1/bin/wget"
  if probe NTFY_AUTH_USERS='you:$2a$10$x:user' NTFY_AUTH_ACCESS='alertbridge:alerts:wo'; then return 1; fi   # ntfy down
  return 0
}

# ---- D1 ---------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/kubectl" <<'SH'
#!/bin/sh
# Stub: records what the drill does. WAIT_RC and BACKUPS_JSON steer it.
case "$*" in
  *"get backups.postgresql.cnpg.io"*) cat "$STUB_DIR/backups.json" ;;
  *"get cluster.postgresql.cnpg.io"*imageName*) cat "$STUB_DIR/image" 2>/dev/null || exit 1 ;;
  *"get configmap"*jsonpath*) cat "$STUB_DIR/register" 2>/dev/null || true ;;
  *"get configmap"*) exit 0 ;;
  *apply\ -f*) cat > "$STUB_DIR/applied.yaml" ;;
  *" wait "*) exit "${WAIT_RC:-0}" ;;
  *" exec "*) n=$(cat "$STUB_DIR/n" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_DIR/n"
              # 1st: pg_is_in_recovery, 2nd: public tables, 3rd (identity only): users.
              if [ "$n" = 0 ]; then echo f; elif [ "$n" = 1 ]; then echo 86; else echo "${USERS:-6}"; fi ;;
  *" patch "*) printf '%s' "$*" > "$STUB_DIR/patched" ;;
esac
exit 0
SH
chmod +x "$T/bin/kubectl"
drill_run() { # script, backups.json, wait_rc, out dir, [source image], [users]
  local d="$4"; rm -rf "$d"; mkdir -p "$d"; cp "$2" "$d/backups.json"
  [ -n "${5:-}" ] && printf '%s' "$5" > "$d/image"
  STUB_DIR="$d" WAIT_RC="$3" USERS="${6:-6}" PATH="$T/bin:$PATH" sh "$1" > "$d/out" 2>&1 || true
}
cat > "$T/two.json" <<'JSON'
{"items":[
 {"spec":{"cluster":{"name":"tockmox-litellm-db"}},"status":{"phase":"completed","backupId":"20260928T030000","stoppedAt":"2026-09-28T03:01:00Z"}},
 {"spec":{"cluster":{"name":"tockmox-litellm-db"}},"status":{"phase":"completed","backupId":"20260929T030000","stoppedAt":"2026-09-29T03:01:00Z"}},
 {"spec":{"cluster":{"name":"tockmox-litellm-db"}},"status":{"phase":"failed","backupId":"20260930T030000","stoppedAt":"2026-09-30T03:01:00Z"}},
 {"spec":{"cluster":{"name":"other-db"}},"status":{"phase":"completed","backupId":"OTHER","stoppedAt":"2026-10-01T03:01:00Z"}}]}
JSON
echo '{"items":[]}' > "$T/none.json"
d1() { # script
  drill_run "$1" "$T/two.json" 0 "$T/d.pass" "ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie"
  drill_run "$1" "$T/none.json" 0 "$T/d.none"
  drill_run "$1" "$T/two.json" 1 "$T/d.fail"
  python3 - "$T" 2>/dev/null <<'PY' || return 1
import sys, yaml
t = sys.argv[1]
d = yaml.safe_load(open(f"{t}/d.pass/applied.yaml"))
assert d["spec"]["bootstrap"]["recovery"]["recoveryTarget"]["backupID"] == "20260929T030000", d
assert d["spec"]["bootstrap"]["recovery"]["source"] == "origin"
n = yaml.safe_load(open(f"{t}/d.none/applied.yaml"))
assert "recoveryTarget" not in n["spec"]["bootstrap"]["recovery"], n
assert d["spec"]["imageName"] == "ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie", d["spec"].get("imageName")
assert "imageName" not in n["spec"], n
PY
  grep -q '^register: .* PASS in_recovery=f public_tables=86 backup=20260929T030000$' "$T/d.pass/out" || return 1
  grep -q '^register: .* PASS in_recovery=f public_tables=86 backup=none$' "$T/d.none/out" || return 1
  grep -q '^register: .* FAIL cluster never became Ready backup=20260929T030000$' "$T/d.fail/out" || return 1
}

# ---- D2 ---------------------------------------------------------------------
cat > "$T/id-two.json" <<'JSON'
{"items":[
 {"spec":{"cluster":{"name":"tockmox-authentik-db"}},"status":{"phase":"completed","backupId":"20261026T032000","stoppedAt":"2026-10-26T03:21:00Z"}},
 {"spec":{"cluster":{"name":"tockmox-authentik-db"}},"status":{"phase":"completed","backupId":"20261027T032000","stoppedAt":"2026-10-27T03:21:00Z"}},
 {"spec":{"cluster":{"name":"tockmox-litellm-db"}},"status":{"phase":"completed","backupId":"LITELLM","stoppedAt":"2026-10-28T03:01:00Z"}}]}
JSON
d2() { # script
  drill_run "$1" "$T/id-two.json" 0 "$T/i.pass" "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie" 6
  drill_run "$1" "$T/id-two.json" 0 "$T/i.empty" "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie" 0
  python3 - "$T" 2>/dev/null <<'PY' || return 1
import sys, yaml
t = sys.argv[1]
d = yaml.safe_load(open(f"{t}/i.pass/applied.yaml"))
assert d["metadata"]["namespace"] == "tockmox-authentik", d["metadata"]
assert d["metadata"]["name"] == "tockmox-authentik-db-drillcheck", d["metadata"]
assert d["spec"]["bootstrap"]["recovery"]["recoveryTarget"]["backupID"] == "20261027T032000", d
p = d["spec"]["externalClusters"][0]["plugin"]["parameters"]
assert p["barmanObjectName"] == "tockmox-authentik-db-store" and p["serverName"] == "tockmox-authentik-db", p
assert d["spec"]["imageName"] == "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie", d["spec"].get("imageName")
PY
  grep -q 'authentik_core_user' "$1" || return 1
  grep -q '^register: .* PASS in_recovery=f public_tables=86 users=6 backup=20261027T032000$' "$T/i.pass/out" || return 1
  grep -q '^register: .* FAIL in_recovery=f public_tables=86 users=0 backup=20261027T032000$' "$T/i.empty/out" || return 1
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  ok() { echo "selftest ok: $1 goes red"; }
  no() { echo "selftest FAIL: $1 passed on a mutant it must refuse"; fail=1; }
  b1 "$T/bridge.py" || { echo "selftest FAIL: B1 red on the real bridge"; fail=1; }
  b2 || { echo "selftest FAIL: B2 red on the real tree"; fail=1; }
  d1 "$T/drill.sh" || { echo "selftest FAIL: D1 red on the real drill"; fail=1; }
  d2 "$T/id-drill.sh" || { echo "selftest FAIL: D2 red on the real identity drill"; fail=1; }
  n1 "$T/ntfy.live" || { echo "selftest FAIL: N1 red on the real ntfy probe"; fail=1; }
  sed 's/for k in NTFY_AUTH_USERS NTFY_AUTH_ACCESS NTFY_AUTH_TOKENS; do/for k in; do/' "$T/ntfy.live" > "$T/m7.sh"
  if n1 "$T/m7.sh"; then no "N1 with the Secret comparison removed"; else ok "N1 with the Secret comparison removed"; fi
  grep -v 'wget' "$T/ntfy.live" > "$T/m8.sh"
  if n1 "$T/m8.sh"; then no "N1 with the health check removed"; else ok "N1 with the health check removed"; fi
  grep -v 'log(delivery_line' "$T/bridge.py" > "$T/m1.py"
  if b1 "$T/m1.py"; then no "B1 with the delivery line removed"; else ok "B1 with the delivery line removed"; fi
  sed "s/result={'ok' if ok else 'failed'}/result=x/; s/f\" http={code}\"/f\" http=0\"/" "$T/bridge.py" > "$T/m2.py"
  if b1 "$T/m2.py"; then no "B1 with the sink code dropped"; else ok "B1 with the sink code dropped"; fi
  sed 's/log(delivery_line(alert, group_status, ok, code))/log(f"delivery token={NTFY_TOKEN}")/' "$T/bridge.py" > "$T/m3.py"
  if b1 "$T/m3.py"; then no "B1 with a secret in the line"; else ok "B1 with a secret in the line"; fi
  cp "$T/ntfy.replicas" "$T/ntfy.replicas.bak"; echo 2 > "$T/ntfy.replicas"
  if b2; then no "B2 with replicas 2"; else ok "B2 with replicas 2"; fi
  cp "$T/ntfy.replicas.bak" "$T/ntfy.replicas"
  sed 's/ backup=\${BACKUP_ID:-none}//' "$T/drill.sh" > "$T/m4.sh"
  if d1 "$T/m4.sh"; then no "D1 with backup= removed from the row"; else ok "D1 with backup= removed from the row"; fi
  grep -v '^ *\${PIN}$' "$T/drill.sh" > "$T/m5.sh"
  if d1 "$T/m5.sh"; then no "D1 with the pin removed"; else ok "D1 with the pin removed"; fi
  sed 's/sort_by(.t) | last/sort_by(.t) | first/' "$T/drill.sh" > "$T/m6.sh"
  if d1 "$T/m6.sh"; then no "D1 pinning the OLDEST backup"; else ok "D1 pinning the OLDEST backup"; fi
  grep -v '^ *\${IMG}$' "$T/drill.sh" > "$T/m9.sh"
  if d1 "$T/m9.sh"; then no "D1 with the source's imageName dropped"; else ok "D1 with the source's imageName dropped"; fi
  sed 's/ && \[ "\${USERS:-0}" -ge 1 \] 2>\/dev\/null//' "$T/id-drill.sh" > "$T/m10.sh"
  if d2 "$T/m10.sh"; then no "D2 passing a restore with no users"; else ok "D2 passing a restore with no users"; fi
  sed 's/tockmox-authentik-db-store/tockmox-litellm-db-store/' "$T/id-drill.sh" > "$T/m11.sh"
  if d2 "$T/m11.sh"; then no "D2 reading the model gateway's store"; else ok "D2 reading the model gateway's store"; fi
  exit $fail
fi

rc=0
b1 "$T/bridge.py" && echo "ok: B1 one delivery line per alert, no secrets" || { echo "FAIL: B1"; rc=1; }
b2 && echo "ok: B2 ntfy replicas 1, reason and TockmoxNtfyDown written" || { echo "FAIL: B2"; rc=1; }
d1 "$T/drill.sh" && echo "ok: D1 drill pins and records backup=, on the source's PostgreSQL image" || { echo "FAIL: D1"; rc=1; }
d2 "$T/id-drill.sh" && echo "ok: D2 identity drill recovers the identity store and PASSes only with Authentik's users back" || { echo "FAIL: D2"; rc=1; }
n1 "$T/ntfy.live" && echo "ok: N1 ntfy restarts onto its auth Secret when it appears or rotates" || { echo "FAIL: N1"; rc=1; }
exit $rc

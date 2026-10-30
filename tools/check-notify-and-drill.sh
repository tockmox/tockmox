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
# D3  A drill that FAILS says why on its register row (HL-0863). A pod that dies in seconds is gone before
#     Alloy tails it, so the row is the only record: the Kubernetes API's own refusal text after `apply
#     refused:`, the readiness wait's output and the cluster's phase after `cluster never became Ready`,
#     on one line (no newline, no `=`, no double quote, no backslash, 240 characters), and the object the
#     row travels in stays valid JSON. Both drills (model gateway, identity), run against the stub.
# D4  The register is an object in the object store, not a ConfigMap (TM-0459), and a drill that cannot
#     record its verdict FAILS. Both drills are run against a stand-in S3 that verifies SigV4 the way Garage
#     does (key, secret, and the signing region, which must be the store's own): a PASS is written, read
#     back and checksummed; a FAIL verdict is recorded too; and a write refused (403), a wrong key, a wrong
#     secret, a wrong signing region (400), an unreachable store, an empty REGION, an object that rots
#     between the write and the read, a write acknowledged but not stored, and a read that errors each end
#     the run NON-ZERO with the reason in the log, whatever the restore's own verdict was. Thirty runs leave
#     thirty objects (no row-count cap). No ConfigMap is written or granted. The two drills carry ONE copy of
#     the writer, and the bucket and Secret names they default to are the ones the platform layer's bootstrap
#     creates. The same writer was also run against a real Garage v2.4.1, outside this gate (the PR body).
#
# LIMIT: no cluster, and the S3 here is a stand-in; the real-Garage run is the PR's, not this gate's. Whether
# CNPG accepts recoveryTarget.backupID from the
# barman-cloud plugin path, and that a Backup CR's status.backupId names what
# the store holds, are the lab's to prove.
# shellcheck disable=SC2015  # "check && echo ok || { echo FAIL; rc=1; }" is this file's idiom; the echo never fails
# shellcheck disable=SC2016  # the stubs' case patterns and the sed mutations match shell text literally, on purpose
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
import json
facts = {}
for src, out, tag in (("ai.yaml", "drill.sh", "gateway"), ("id.yaml", "id-drill.sh", "identity")):
    for d in yaml.safe_load_all(open(f"{t}/{src}")):
        if d and d["kind"] == "CronJob" and d["metadata"]["name"].endswith("-drill"):
            pod = d["spec"]["jobTemplate"]["spec"]["template"]["spec"]; c = pod["containers"][0]
            open(f"{t}/{out}", "w").write(c["args"][0])
            facts[tag] = {"env": {e["name"]: e for e in c.get("env") or []}, "policy": c.get("terminationMessagePolicy"),
                          "mounts": [m["name"] for m in c.get("volumeMounts") or []], "volumes": [v["name"] for v in pod.get("volumes") or []]}
        if d and d["kind"] == "Role" and d["metadata"]["name"] == "tockmox-restore-drill":
            facts.setdefault(tag + "-role", d["rules"])
open(f"{t}/drill.facts.json", "w").write(json.dumps(facts))
PY
[ -s "$T/bridge.py" ] && [ -s "$T/drill.sh" ] && [ -s "$T/id-drill.sh" ] || { echo "check-notify-and-drill: bridge, drill or identity drill not rendered" >&2; exit 1; }
# The drills keep the register's scratch files in REG_TMP=/tmp/drill-register, an emptyDir in the pod. On a host,
# two copies of this gate (check-all runs it and its --selftest side by side) shared that directory and corrupted
# each other's D4 runs: alone each passed, together both failed D4. The test copies use this run's own directory;
# the rendered product text is unchanged, and the line is required so a rename cannot slip past this rewrite.
for f in "$T/drill.sh" "$T/id-drill.sh"; do
  grep -q '^REG_TMP=/tmp/drill-register$' "$f" \
    || { echo "check-notify-and-drill: $f no longer sets REG_TMP=/tmp/drill-register; move this per-run rewrite with it" >&2; exit 1; }
  sed "s#^REG_TMP=/tmp/drill-register\$#REG_TMP=$T/drill-register#" "$f" > "$f.run" && mv "$f.run" "$f"
done

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
# Stub: records what the drill does. WAIT_RC, WAIT_MSG, CLUSTER_PHASE, APPLY_RC and APPLY_MSG steer it.
# It has NO verb for a ConfigMap: the register is an object in the object store (D4), and a drill that
# still reached for one would get the stub's catch-all (exit 0, nothing) and be caught by D4's scan instead.
case "$*" in
  *"get backups.postgresql.cnpg.io"*) cat "$STUB_DIR/backups.json" ;;
  *"get cluster.postgresql.cnpg.io"*imageName*) cat "$STUB_DIR/image" 2>/dev/null || exit 1 ;;
  *"get cluster.postgresql.cnpg.io"*phase*) printf '%s' "${CLUSTER_PHASE:-}" ;;
  *apply\ -f*) cat > "$STUB_DIR/applied.yaml"; [ -z "${APPLY_MSG:-}" ] || printf '%s\n' "$APPLY_MSG" >&2; exit "${APPLY_RC:-0}" ;;
  *" wait "*) [ -z "${WAIT_MSG:-}" ] || printf '%s\n' "$WAIT_MSG" >&2; exit "${WAIT_RC:-0}" ;;
  *" exec "*) n=$(cat "$STUB_DIR/n" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_DIR/n"
              # 1st: pg_is_in_recovery, 2nd: public tables, 3rd (identity only): users.
              if [ "$n" = 0 ]; then echo f; elif [ "$n" = 1 ]; then echo 86; else echo "${USERS:-6}"; fi ;;
esac
exit 0
SH
chmod +x "$T/bin/kubectl"
# The register's store: a stand-in S3 that verifies SigV4 (access key, secret, signing region) as Garage does.
# Its code is a heredoc below; `mode` in $S3DIR steers it (ok, refuse, corrupt, lie, getfail).
cat > "$T/s3stub.py" <<'PY'
import hashlib, hmac, http.server, os, sys, urllib.parse
# argv: port dir access-key secret-key region
#   mode (a file in dir): ok = store what is PUT and return it | refuse = every PUT 403 | corrupt = store it
#   right, return it with one byte changed (the object rots between the write and the read) | lie = PUT 200,
#   nothing stored | getfail = store it, every GET 500
port, root, AK, SK, REGION = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
def hm(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def mode(self):
        try: return open(os.path.join(root, "mode")).read().strip()
        except OSError: return "ok"
    def reply(self, code, body=b"", ctype="application/xml"):
        self.send_response(code); self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", ctype); self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def err(self, code, name, msg):
        self.reply(code, ("<?xml version=\"1.0\"?><Error><Code>%s</Code><Message>%s</Message><Region>%s</Region></Error>" % (name, msg, REGION)).encode())
    def auth(self, payload):
        a = self.headers.get("Authorization", "")
        if not a.startswith("AWS4-HMAC-SHA256 "): self.err(403, "AccessDenied", "no signature"); return False
        f = dict(x.strip().split("=", 1) for x in a[len("AWS4-HMAC-SHA256 "):].split(","))
        ak, date, region, svc, term = f["Credential"].split("/")
        if region != REGION:
            self.err(400, "AuthorizationHeaderMalformed", "Authorization header malformed, unexpected scope: '%s/%s/%s/%s', expected: '%s/%s/s3/aws4_request'" % (date, region, svc, term, date, REGION)); return False
        if ak != AK: self.err(403, "InvalidAccessKeyId", "No such key: %s" % ak); return False
        ch = "".join("%s:%s\n" % (h, " ".join(self.headers.get(h, "").split())) for h in f["SignedHeaders"].split(";"))
        ph = self.headers.get("x-amz-content-sha256") or "UNSIGNED-PAYLOAD"
        path, _, q = self.path.partition("?")
        cr = "\n".join([self.command, urllib.parse.quote(urllib.parse.unquote(path), safe="/-_.~"), q, ch, f["SignedHeaders"], ph])
        sts = "\n".join(["AWS4-HMAC-SHA256", self.headers.get("x-amz-date"), "%s/%s/%s/%s" % (date, region, svc, term), hashlib.sha256(cr.encode()).hexdigest()])
        k = hm(hm(hm(hm(("AWS4" + SK).encode(), date), region), svc), term)
        if not hmac.compare_digest(hmac.new(k, sts.encode(), hashlib.sha256).hexdigest(), f["Signature"]):
            self.err(403, "AccessDenied", "Forbidden: Invalid signature"); return False
        if self.command == "PUT" and ph != "UNSIGNED-PAYLOAD" and ph != hashlib.sha256(payload).hexdigest():
            self.err(400, "XAmzContentSHA256Mismatch", "payload hash differs"); return False
        return True
    def target(self): return os.path.join(root, "objects", urllib.parse.unquote(self.path.partition("?")[0]).lstrip("/"))
    def do_PUT(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not self.auth(body): return
        m = self.mode()
        if m == "refuse": return self.err(403, "AccessDenied", "Forbidden: bucket policy")
        if m != "lie":
            t = self.target(); os.makedirs(os.path.dirname(t), exist_ok=True); open(t, "wb").write(body)
        self.reply(200)
    def do_GET(self):
        if not self.auth(b""): return
        m = self.mode()
        if m == "getfail": return self.err(500, "InternalError", "stub getfail")
        t = self.target()
        if not os.path.isfile(t): return self.err(404, "NoSuchKey", "The specified key does not exist.")
        b = open(t, "rb").read()
        if m == "corrupt": b = b[:-2] + (b"X" if b[-2:-1] != b"X" else b"Y") + b[-1:]
        self.reply(200, b, "application/json")
    do_HEAD = do_GET
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
S3DIR="$T/s3"; mkdir -p "$S3DIR"; S3PORT=$((20000 + RANDOM % 20000))
python3 "$T/s3stub.py" "$S3PORT" "$S3DIR" GKdrilltest SECRETdrilltest garage &
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$S3PORT/" && break; sleep 0.1; done
# What the drill pod gets from its env (the chart's Secret and defaults), pointed at the stand-in.
export REG_ENDPOINT="http://127.0.0.1:$S3PORT" REG_BUCKET=tockmox-drill-register REG_AK=GKdrilltest REG_SK=SECRETdrilltest \
  REG_REGION=garage REG_JOB=tockmox-drill-29000000 REG_CHART_VERSION=tockmox-test-0
# A clock that moves one second per stamp, so no two runs write the same key (a real drill runs weekly).
cat > "$T/bin/date" <<'SH'
#!/bin/sh
case "$*" in
  *%Y-%m-%dT%H:%M:%SZ*) n=$(cat "$STUB_CLOCK" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_CLOCK"
                        printf '2026-11-%02dT04:%02d:%02dZ\n' $(( (n-1)/3600 + 1 )) $(( ((n-1)%3600)/60 )) $(( (n-1)%60 )) ;;
  *) exec /bin/date "$@" ;;
esac
SH
chmod +x "$T/bin/date"; export STUB_CLOCK="$T/clock"
drill_exec() { # dir script [VAR=value ...]: run the script, keep its output, exit code and the objects it wrote
  local d="$1" s="$2" rc=0; shift 2
  [ -n "${KEEP_S3:-}" ] || rm -rf "$S3DIR/objects"
  env STUB_DIR="$d" "$@" PATH="$T/bin:$PATH" sh "$s" > "$d/out" 2>&1 || rc=$?
  echo "$rc" > "$d/rc"; rm -rf "$d/s3"; [ ! -d "$S3DIR/objects" ] || cp -r "$S3DIR/objects" "$d/s3"
}
drill_run() { # script, backups.json, wait_rc, out dir, [source image], [users]
  local d="$4"; rm -rf "$d"; mkdir -p "$d"; cp "$2" "$d/backups.json"
  [ -n "${5:-}" ] && printf '%s' "$5" > "$d/image"
  drill_exec "$d" "$1" WAIT_RC="$3" USERS="${6:-6}"
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
  grep -q '^register: .* FAIL cluster never became Ready (phase: unknown): *backup=20260929T030000$' "$T/d.fail/out" || return 1
}

# ---- D3 ---------------------------------------------------------------------
# A planted failure per step. The messages carry every character the row must not: a double quote, an equals
# sign, a backslash, a newline and a tab, and one is longer than the 240 characters the row keeps.
REFUSAL=$(printf 'Error from server (Forbidden): clusters.postgresql.cnpg.io is forbidden: User "system:serviceaccount:a:b" cannot create resource "clusters" in API group "postgresql.cnpg.io" in the namespace x=y\\z\nsecond\tline')
LONG=$(python3 -c 'print("e" * 400)')
d3() { # script, expected apply-refusal prefix check mode (gateway|identity)
  local s="$1" d bj="two.json"
  [ "$2" = identity ] && bj="id-two.json"
  d="$T/d3.apply"; rm -rf "$d"; mkdir -p "$d"; cp "$T/$bj" "$d/backups.json"
  drill_exec "$d" "$s" APPLY_RC=1 APPLY_MSG="$REFUSAL"
  d="$T/d3.wait"; rm -rf "$d"; mkdir -p "$d"; cp "$T/$bj" "$d/backups.json"
  drill_exec "$d" "$s" WAIT_RC=1 CLUSTER_PHASE="Setting up primary" WAIT_MSG="error: timed out waiting for the condition on clusters/x"
  d="$T/d3.long"; rm -rf "$d"; mkdir -p "$d"; cp "$T/$bj" "$d/backups.json"
  drill_exec "$d" "$s" APPLY_RC=1 APPLY_MSG="$LONG"
  python3 - "$T" 2>/dev/null <<'PY' || return 1
import sys, json, re, glob
t = sys.argv[1]
def row(sub):
    r = [l for l in open(f"{t}/{sub}/out").read().splitlines() if l.startswith("register: ") and " FAIL " in l]
    assert len(r) == 1, (sub, r)
    return r[0][len("register: "):]
def recorded(sub):                      # the object the row travels in: valid JSON, and it carries the row verbatim
    o = glob.glob(f"{t}/{sub}/s3/*/*/*.json")
    assert len(o) == 1, (sub, o)
    return json.loads(open(o[0]).read())
a = row("d3.apply")
m = re.match(r"^\S+ FAIL apply refused: (.*) backup=\S+$", a)
assert m, a
msg = m.group(1)
assert "Forbidden" in msg and "cannot create resource" in msg and "clusters" in msg, msg
assert '"' not in msg and "=" not in msg and "\\" not in msg and "\t" not in msg, msg
assert a.count("=") == 1, a                      # only backup=<id>: no later key=value field is forged
assert recorded("d3.apply")["row"] == a, "the register object lost the row"
w = row("d3.wait")
assert re.match(r"^\S+ FAIL cluster never became Ready \(phase: Setting up primary\): error: timed out waiting for the condition on clusters/x backup=\S+$", w), w
assert recorded("d3.wait")["row"] == w, "the register object lost the row"
l = row("d3.long")
m = re.match(r"^\S+ FAIL apply refused: (.*) backup=\S+$", l)
assert m and 1 <= len(m.group(1)) <= 240, (len(m.group(1)) if m else l)
assert recorded("d3.long")["detail"].startswith("apply refused: ")
PY
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

# ---- D4 ---------------------------------------------------------------------
# The register is an object, and a drill that cannot record its verdict FAILS (TM-0459). The restore itself
# PASSES in every case below but the FAIL one: what varies is the store.
d4_case() { # name, script, kind, s3 mode, [VAR=value ...]: one drill run with a PASSing restore; rc and objects kept
  local n="$1" s="$2" k="$3" mode="$4" d bj="two.json"; shift 4
  [ "$k" = identity ] && bj="id-two.json"
  d="$T/d4.$n"; rm -rf "$d"; mkdir -p "$d"; cp "$T/$bj" "$d/backups.json"; printf 'ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie' > "$d/image"
  echo "$mode" > "$S3DIR/mode"
  drill_exec "$d" "$s" WAIT_RC=0 USERS=6 "$@"
  echo ok > "$S3DIR/mode"
}
d4() { # script, kind (gateway|identity)
  local s="$1" k="$2" d db=tockmox-litellm-db
  [ "$k" = identity ] && db=tockmox-authentik-db
  d4_case pass "$s" "$k" ok
  d4_case failv "$s" "$k" ok WAIT_RC=1
  d4_case refuse "$s" "$k" refuse
  d4_case badkey "$s" "$k" ok REG_AK=GKsomebodyelse
  d4_case badsecret "$s" "$k" ok REG_SK=NOTTHESECRET
  d4_case region "$s" "$k" ok REG_REGION=us-east-1
  d4_case noregion "$s" "$k" ok REG_REGION=
  d4_case down "$s" "$k" ok REG_ENDPOINT=http://127.0.0.1:9
  d4_case rot "$s" "$k" corrupt
  d4_case lie "$s" "$k" lie
  d4_case getfail "$s" "$k" getfail
  python3 - "$T" "$db" "$k" 2>/dev/null <<'PY' || return 1
import sys, json, re, glob, hashlib
t, db, kind = sys.argv[1:4]
def case(n):
    d = f"{t}/d4.{n}"
    return int(open(f"{d}/rc").read()), open(f"{d}/out").read(), sorted(glob.glob(f"{d}/s3/*/*/*.json"))
# A PASS is recorded: exit 0, ONE object at <db>/<stamp>-PASS.json, valid JSON carrying the evidence, and the log's
# checksum is the checksum of the stored bytes.
rc, out, objs = case("pass")
assert rc == 0, ("a recorded PASS must exit 0", rc, out[-400:])
assert len(objs) == 1 and re.search(rf"/tockmox-drill-register/{db}/\d{{8}}T\d{{6}}Z-PASS\.json$", objs[0]), objs
o = json.load(open(objs[0]))
assert o["schema"] == 1 and o["verdict"] == "PASS" and o["db"] == db and o["backupId"] != "none", o
assert o["image"] == "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie" and o["inRecovery"] == "f" and o["publicTables"] == "86", o
assert o["row"] in out and o["detail"] in o["row"] and o["job"] == "tockmox-drill-29000000", o
assert isinstance(o["durationSeconds"], int) and o["chartVersion"] == "tockmox-test-0", o
if kind == "identity": assert o["users"] == "6", o
m = re.search(r"^register: recorded s3://tockmox-drill-register/(\S+) sha256=([0-9a-f]{64})$", out, re.M)
assert m and objs[0].endswith(m.group(1)) and m.group(2) == hashlib.sha256(open(objs[0], "rb").read()).hexdigest(), out[-300:]
# A FAIL verdict is recorded too, and the drill still fails.
rc, out, objs = case("failv")
assert rc != 0 and len(objs) == 1 and objs[0].endswith("-FAIL.json") and json.load(open(objs[0]))["verdict"] == "FAIL", (rc, objs)
assert "register: recorded " in out and "NOT RECORDED" not in out, out[-300:]
# Every way the row can fail to be recorded fails the run, loudly, whatever the restore said.
def loud(n, *needles):
    rc, out, objs = case(n)
    assert rc != 0, (n, "a drill that could not record its row must exit non-zero", rc, out[-500:])
    assert re.search(r"^register: [^ ]+ PASS in_recovery=f ", out, re.M), (n, "the restore PASSed and the log must say so", out[-500:])
    last = [l for l in out.splitlines() if l.strip()][-1]
    assert last.startswith("register: NOT RECORDED, so this drill FAILS whatever its verdict (PASS): "), (n, last)
    for x in needles: assert x in last, (n, x, last)
    assert "register: recorded " not in out, (n, out[-300:])
    return objs
assert loud("refuse", "refused", "http 403") == []
loud("badkey", "refused", "http 403", "InvalidAccessKeyId")
loud("badsecret", "refused", "http 403", "Invalid signature")
loud("region", "refused", "http 400", "AuthorizationHeaderMalformed")
loud("noregion", "REGION is empty")
loud("down", "refused", "curl exit 7")
assert len(loud("rot", "read back", "differs from what was written", "wrote sha256 ")) == 1     # written, then rotted: caught on the read
loud("lie", "read back", "http 404")
loud("getfail", "read back", "http 500")
PY
  # No row-count cap: thirty runs leave thirty objects (the ConfigMap kept the last 24).
  d="$T/d4.many"; rm -rf "$d"; mkdir -p "$d"; cp "$T/$( [ "$k" = identity ] && echo id-two.json || echo two.json )" "$d/backups.json"
  rm -rf "$S3DIR/objects"
  for _ in $(seq 30); do rm -f "$d/n"; KEEP_S3=1 drill_exec "$d" "$s" WAIT_RC=0 USERS=6; done
  [ "$(find "$S3DIR/objects/tockmox-drill-register/$db" -name '*-PASS.json' | wc -l | tr -d ' ')" = 30 ] || return 1
  # And no ConfigMap: not written by the script, not granted by the Role.
  if grep -i 'configmap' "$s" >/dev/null; then return 1; fi
  return 0
}
d4_static() { # platform values file
  python3 - "$T" "$1" 2>/dev/null <<'PY' || return 1
import sys, json, yaml
t, pv = sys.argv[1:3]
f = json.load(open(f"{t}/drill.facts.json"))
g = yaml.safe_load(open(pv))["garage"]
dr = g["drillRegister"]
assert dr["enabled"] is True and dr["bucket"] != g["bucket"], dr          # a bucket of its own, never the backups'
want = {"REG_BUCKET": dr["bucket"], "REG_ENDPOINT": "http://tockmox-garage.tockmox-platform.svc:3900"}
for k in ("gateway", "identity"):
    e = f[k]["env"]
    for n, v in want.items(): assert e[n]["value"] == v, (k, n, e[n], v)
    for n, key in (("REG_AK", "ACCESS_KEY_ID"), ("REG_SK", "ACCESS_SECRET_KEY"), ("REG_REGION", "REGION")):
        r = e[n]["valueFrom"]["secretKeyRef"]
        assert r["name"] == dr["credentialsSecretName"] and r["key"] == key and not r.get("optional"), (k, n, r)
    assert f[k]["policy"] == "FallbackToLogsOnError", f[k]                  # the reason survives a pod that is gone in seconds
    assert "tmp" in f[k]["mounts"] and "tmp" in f[k]["volumes"], f[k]       # readOnlyRootFilesystem: the writer needs a scratch dir
    ns = {"gateway": "tockmox-ai", "identity": "tockmox-authentik"}[k]
    assert ns in dr["namespaces"], (ns, dr["namespaces"])                    # the platform layer copies the Secret there
    for rule in f[k + "-role"]:
        assert "configmaps" not in rule["resources"], (k, rule)              # no ConfigMap access left
PY
}
# One writer, two drills: the text between the markers is byte-identical in both rendered scripts.
d4_one_copy() { # script, script
  local a b
  a=$(sed -n '/^ *# ---- the register writer/,/^ *# ---- end of the register writer/p' "$1" | sed 's/^ *//')
  b=$(sed -n '/^ *# ---- the register writer/,/^ *# ---- end of the register writer/p' "$2" | sed 's/^ *//')
  [ -n "$a" ] && [ "$a" = "$b" ]
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  ok() { echo "selftest ok: $1 goes red"; }
  no() { echo "selftest FAIL: $1 passed on a mutant it must refuse"; fail=1; }
  b1 "$T/bridge.py" || { echo "selftest FAIL: B1 red on the real bridge"; fail=1; }
  b2 || { echo "selftest FAIL: B2 red on the real tree"; fail=1; }
  d1 "$T/drill.sh" || { echo "selftest FAIL: D1 red on the real drill"; fail=1; }
  d2 "$T/id-drill.sh" || { echo "selftest FAIL: D2 red on the real identity drill"; fail=1; }
  d3 "$T/drill.sh" gateway || { echo "selftest FAIL: D3 red on the real drill"; fail=1; }
  d3 "$T/id-drill.sh" identity || { echo "selftest FAIL: D3 red on the real identity drill"; fail=1; }
  d4 "$T/drill.sh" gateway || { echo "selftest FAIL: D4 red on the real drill"; fail=1; }
  d4 "$T/id-drill.sh" identity || { echo "selftest FAIL: D4 red on the real identity drill"; fail=1; }
  d4_static charts/tockmox-platform/values.yaml || { echo "selftest FAIL: D4 static wiring red on the real tree"; fail=1; }
  d4_one_copy "$T/drill.sh" "$T/id-drill.sh" || { echo "selftest FAIL: D4 one-writer red on the real tree"; fail=1; }
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
  for which in drill id-drill; do
    kind=gateway; [ "$which" = id-drill ] && kind=identity
    sed 's/DETAIL="apply refused: \$(why "\$APPLY_OUT")"/DETAIL="apply refused"/' "$T/$which.sh" > "$T/m12.sh"
    if d3 "$T/m12.sh" $kind; then no "D3 ($kind) with the apply refusal text dropped"; else ok "D3 ($kind) with the apply refusal text dropped"; fi
    sed 's/: \$(why "\$WAIT_OUT"))"/)"/; s/ (phase: \$(why "\${PHASE:-unknown}"))//' "$T/$which.sh" > "$T/m13.sh"
    if d3 "$T/m13.sh" $kind; then no "D3 ($kind) with the readiness wait text dropped"; else ok "D3 ($kind) with the readiness wait text dropped"; fi
    sed "s/ | tr -s ' ' | cut -c1-240; }/ | tr -s ' '; }/" "$T/$which.sh" > "$T/m14.sh"
    if d3 "$T/m14.sh" $kind; then no "D3 ($kind) with the 240 character cap removed"; else ok "D3 ($kind) with the 240 character cap removed"; fi
    sed "s/tr '\\\\n\\\\r\\\\t\"=\\\\\\\\' \"   ': \"/tr '\\\\n\\\\r\\\\t\"' \"   '\"/" "$T/$which.sh" > "$T/m15.sh"
    if d3 "$T/m15.sh" $kind; then no "D3 ($kind) letting = and a backslash through"; else ok "D3 ($kind) letting = and a backslash through"; fi
  done
  sed 's/tockmox-authentik-db-store/tockmox-litellm-db-store/' "$T/id-drill.sh" > "$T/m11.sh"
  if d2 "$T/m11.sh"; then no "D2 reading the model gateway's store"; else ok "D2 reading the model gateway's store"; fi
  # D4: each assertion goes red on the smallest mutation that breaks what it guards. The first is the one the
  # card asks for: the writer SWALLOWS its error (the old `|| true`), so a PASS that was never recorded exits 0.
  for which in drill id-drill; do
    kind=gateway; [ "$which" = id-drill ] && kind=identity
    sed 's/if \[ "\$RECORDED" != 1 \]; then/if false; then/' "$T/$which.sh" > "$T/m16.sh"
    if d4 "$T/m16.sh" $kind; then no "D4 ($kind) with the writer swallowing its failure"; else ok "D4 ($kind) with the writer swallowing its failure"; fi
    sed 's/if \[ "\$_got" != "\$_sum" \]; then/if false; then/' "$T/$which.sh" > "$T/m17.sh"
    if d4 "$T/m17.sh" $kind; then no "D4 ($kind) with the read-back comparison removed"; else ok "D4 ($kind) with the read-back comparison removed"; fi
    sed 's/if \[ "\$_rc" -ne 0 \] || \[ "\$_code" != 200 \]; then/if false; then/' "$T/$which.sh" > "$T/m18.sh"
    if d4 "$T/m18.sh" $kind; then no "D4 ($kind) with the HTTP status unchecked"; else ok "D4 ($kind) with the HTTP status unchecked"; fi
    sed 's/aws:amz:\${REG_REGION}:s3/aws:amz:us-east-1:s3/' "$T/$which.sh" > "$T/m19.sh"
    if d4 "$T/m19.sh" $kind; then no "D4 ($kind) signing for another region than the Secret's"; else ok "D4 ($kind) signing for another region than the Secret's"; fi
    sed 's#^  REG_KEY=.*#  REG_KEY="${REG_DB}/latest.json"#' "$T/$which.sh" > "$T/m20.sh"
    if d4 "$T/m20.sh" $kind; then no "D4 ($kind) overwriting one row instead of keeping every run"; else ok "D4 ($kind) overwriting one row instead of keeping every run"; fi
    sed 's#register_write || true#register_write || true; kubectl -n "$NS" create configmap tockmox-restore-drill-register >/dev/null 2>\&1 || true#' "$T/$which.sh" > "$T/m21.sh"
    if d4 "$T/m21.sh" $kind; then no "D4 ($kind) writing the ConfigMap again"; else ok "D4 ($kind) writing the ConfigMap again"; fi
    sed 's/REG_ERR="REGION is empty in the register credentials Secret[^"]*"; return 1; }/:; }/' "$T/$which.sh" > "$T/m22.sh"
    if d4 "$T/m22.sh" $kind; then no "D4 ($kind) signing with an empty REGION"; else ok "D4 ($kind) signing with an empty REGION"; fi
  done
  sed 's/--max-time 60/--max-time 61/' "$T/id-drill.sh" > "$T/m23.sh"
  if d4_one_copy "$T/drill.sh" "$T/m23.sh"; then no "D4 with the two drills' writers diverged"; else ok "D4 with the two drills' writers diverged"; fi
  sed 's/^    bucket: tockmox-drill-register$/    bucket: tockmox-drill-registry/' charts/tockmox-platform/values.yaml > "$T/m24.yaml"
  if d4_static "$T/m24.yaml"; then no "D4 with the platform bootstrap and the drills naming different buckets"; else ok "D4 with the platform bootstrap and the drills naming different buckets"; fi
  sed 's/^    bucket: tockmox-drill-register$/    bucket: tockmox-backups/' charts/tockmox-platform/values.yaml > "$T/m25.yaml"
  if d4_static "$T/m25.yaml"; then no "D4 with the register in the backup bucket"; else ok "D4 with the register in the backup bucket"; fi
  sed 's/^      - tockmox-authentik$//' charts/tockmox-platform/values.yaml > "$T/m26.yaml"
  if d4_static "$T/m26.yaml"; then no "D4 with the identity namespace left out of the register Secret's copy targets"; else ok "D4 with the identity namespace left out of the register Secret's copy targets"; fi
  exit $fail
fi

rc=0
b1 "$T/bridge.py" && echo "ok: B1 one delivery line per alert, no secrets" || { echo "FAIL: B1"; rc=1; }
b2 && echo "ok: B2 ntfy replicas 1, reason and TockmoxNtfyDown written" || { echo "FAIL: B2"; rc=1; }
d1 "$T/drill.sh" && echo "ok: D1 drill pins and records backup=, on the source's PostgreSQL image" || { echo "FAIL: D1"; rc=1; }
d2 "$T/id-drill.sh" && echo "ok: D2 identity drill recovers the identity store and PASSes only with Authentik's users back" || { echo "FAIL: D2"; rc=1; }
d3 "$T/drill.sh" gateway && echo "ok: D3 a failed drill names its cause on the register row (model gateway)" || { echo "FAIL: D3 (model gateway)"; rc=1; }
d3 "$T/id-drill.sh" identity && echo "ok: D3 a failed drill names its cause on the register row (identity)" || { echo "FAIL: D3 (identity)"; rc=1; }
d4 "$T/drill.sh" gateway && echo "ok: D4 the model gateway drill records an object, and FAILS when it cannot write it, read it back or match it (model gateway)" || { echo "FAIL: D4 (model gateway)"; rc=1; }
d4 "$T/id-drill.sh" identity && echo "ok: D4 the identity drill records an object, and FAILS when it cannot write it, read it back or match it (identity)" || { echo "FAIL: D4 (identity)"; rc=1; }
d4_static charts/tockmox-platform/values.yaml && echo "ok: D4 the drills' bucket, Secret and namespaces are the ones the platform bootstrap creates; no ConfigMap in either Role" || { echo "FAIL: D4 static wiring"; rc=1; }
d4_one_copy "$T/drill.sh" "$T/id-drill.sh" && echo "ok: D4 both drills carry the same register writer" || { echo "FAIL: D4 one writer"; rc=1; }
n1 "$T/ntfy.live" && echo "ok: N1 ntfy restarts onto its auth Secret when it appears or rotates" || { echo "FAIL: N1"; rc=1; }
exit $rc

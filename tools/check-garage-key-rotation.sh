#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the RENDERED Garage bootstrap script (tockmox-platform, the
# tockmox-garage-bootstrap Job) against a stand-in for Garage's v2 admin API and
# a stand-in kubectl that enforces the Job's rendered Roles, and assert what a
# key rotation leaves behind.
#
#   ./tools/check-garage-key-rotation.sh             run the assertions
#   ./tools/check-garage-key-rotation.sh --selftest  prove each can go red
#
# K1  A fresh run mints one key per name (tockmox-backups,
#     tockmox-drill-register), each held by its Secret, and copies each Secret
#     to its namespaces. A second run changes no key.
# K2  Rotation (delete the Secret, re-run): the old key is deleted in Garage
#     BEFORE the new Secret is written, the new key is the only one under its
#     name, and every copy (the credentials namespaces, Longhorn's Secret)
#     carries the new key.
# K3  A run that dies between CreateKey and the Secret create leaves a key with
#     no grant on any bucket, and the next run deletes it.
# K4  A key of the same name that no Secret holds (an orphan from an older
#     release) is deleted on the next run, with the Secret present.
# K5  A copy older than REGION gets REGION, under the Job's own Role in the
#     copy's namespace (the stand-in kubectl refuses anything the rendered Roles
#     do not grant, so a branch the Role cannot run fails here and not in a Job).
#
# LIMIT: a stand-in Garage, written to the v2 admin API reference (ListKeys,
# DeleteKey, CreateKey, AllowBucketKey, GetBucketInfo). The same script against
# a real Garage binary is a lab proof, not this gate.
# shellcheck disable=SC2329  # the scenarios and helpers are called by name, through the run list and must_hold/must_refuse
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
command -v helm >/dev/null 2>&1 || { echo "check-garage-key-rotation: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-garage-key-rotation: python3 PyYAML missing" >&2; exit 2; }

T="${GARAGE_ROT_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/garage-rot.XXXXXX")}"
GPID=""
cleanup() { [ -n "$GPID" ] && kill "$GPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# The smallest render with every key step on: backups, the drill register,
# Longhorn's copy. Static sites off (their step needs an S3 client).
helm template t charts/tockmox-platform -f ci/values.yaml --set apps.docs.enabled=false > "$T/plat.yaml" 2>"$T/plat.err" \
  || { cat "$T/plat.err" >&2; exit 1; }

python3 - "$T" <<'PY' || exit 1
import sys, yaml, json
t = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(t + "/plat.yaml")) if d]
job = [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"] == "tockmox-garage-bootstrap"]
if len(job) != 1: sys.exit("no tockmox-garage-bootstrap Job in the render")
c = job[0]["spec"]["template"]["spec"]["containers"][0]
open(t + "/bootstrap.sh", "w").write(c["args"][0])
open(t + "/bootstrap.env", "w").write("".join("%s=%s\n" % (e["name"], json.dumps(e.get("value", ""))) for e in c["env"]))
roles = {}
for d in docs:
    if d.get("kind") == "Role" and d["metadata"]["name"] == "tockmox-garage-bootstrap":
        roles[d["metadata"]["namespace"]] = d["rules"]
json.dump(roles, open(t + "/roles.json", "w"))
PY

cat > "$T/fake-garage.py" <<'PY'
# A stand-in for the parts of Garage's v2 admin API the bootstrap calls. State in
# a JSON file, every mutating call appended to the shared event log.
import http.server, json, os, secrets, socket, sys, urllib.parse
STATE, PORTF, EVENTS = sys.argv[1], sys.argv[2], sys.argv[3]
def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {"keys": {}, "buckets": {}}
def save(s): json.dump(s, open(STATE, "w"))
def ev(line):
    with open(EVENTS, "a") as f: f.write(line + "\n")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def route(self, method):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query)); p = u.path
        body = {}
        n = int(self.headers.get("Content-Length") or 0)
        if n: body = json.loads(self.rfile.read(n) or b"{}")
        s = load()
        if p == "/health": return self.out(200, {})
        if p == "/v2/GetClusterStatus": return self.out(200, {"nodes": [{"id": "0123456789abcdef0123456789abcdef"}]})
        if p == "/v2/GetClusterLayout": return self.out(200, {"version": 1, "roles": [{"id": "0123456789abcdef"}]})
        if p == "/v2/GetBucketInfo":
            b = s["buckets"].get(q.get("globalAlias", ""))
            return self.out(200, b) if b else self.out(404, {"code": "NoSuchBucket"})
        if p == "/v2/CreateBucket" and method == "POST":
            a = body["globalAlias"]; s["buckets"][a] = {"id": secrets.token_hex(32), "globalAliases": [a], "keys": {}}
            save(s); ev("garage CreateBucket " + a); return self.out(200, s["buckets"][a])
        if p == "/v2/CreateKey" and method == "POST":
            kid = "GK" + secrets.token_hex(12)
            s["keys"][kid] = {"name": body.get("name", ""), "secret": secrets.token_hex(32)}
            save(s); ev("garage CreateKey %s %s" % (body.get("name", ""), kid))
            return self.out(200, {"accessKeyId": kid, "secretAccessKey": s["keys"][kid]["secret"], "name": body.get("name", "")})
        if p == "/v2/ListKeys":
            return self.out(200, [{"id": k, "name": v["name"], "expired": False} for k, v in s["keys"].items()])
        if p == "/v2/DeleteKey" and method == "POST":
            kid = q.get("id", "")
            if kid not in s["keys"]: return self.out(404, {"code": "NoSuchAccessKey"})
            del s["keys"][kid]
            for b in s["buckets"].values(): b["keys"].pop(kid, None)
            save(s); ev("garage DeleteKey " + kid); return self.out(200, {})
        if p == "/v2/AllowBucketKey" and method == "POST":
            kid = body["accessKeyId"]
            if kid not in s["keys"]: return self.out(404, {"code": "NoSuchAccessKey"})
            b = [x for x in s["buckets"].values() if x["id"] == body["bucketId"]]
            if not b: return self.out(404, {"code": "NoSuchBucket"})
            b[0]["keys"][kid] = body["permissions"]; save(s); ev("garage AllowBucketKey %s %s" % (kid, b[0]["globalAliases"][0]))
            return self.out(200, b[0])
        return self.out(400, {"code": "unhandled " + method + " " + p})
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTF + ".tmp", "w").write(str(srv.server_address[1])); os.rename(PORTF + ".tmp", PORTF)
srv.serve_forever()
PY

cat > "$T/kubectl" <<'PY'
#!/usr/bin/env python3
# A stand-in kubectl: Secrets and the Longhorn BackupTarget as files, and every
# call checked against the rendered Roles of the Job's ServiceAccount (a rule
# with resourceNames never authorises create, as in RBAC).
import base64, json, os, sys
K = os.environ["KDIR"]; a = sys.argv[1:]; ns = "default"
if a[:1] == ["-n"]: ns, a = a[1], a[2:]
roles = json.load(open(os.environ["ROLES"]))
def ev(line):
    with open(os.environ["EVENTS"], "a") as f: f.write(line + "\n")
def allow(verb, resource, name):
    for r in roles.get(ns, []):
        if resource not in r.get("resources", []) or verb not in r.get("verbs", []): continue
        names = r.get("resourceNames")
        if not names or (verb != "create" and name in names): return
    sys.stderr.write('Error from server (Forbidden): %s "%s" is forbidden: cannot %s in the namespace "%s"\n' % (resource, name, verb, ns)); sys.exit(1)
def d(name): return os.path.join(K, ns, name)
def jp(arg): return arg.split("{", 1)[1].rstrip("}").lstrip(".")
crash = os.environ.get("CRASH_CREATE", "")
if a[:2] == ["get", "secret"]:
    allow("get", "secrets", a[2])
    if not os.path.isdir(d(a[2])): sys.stderr.write('Error from server (NotFound): secrets "%s" not found\n' % a[2]); sys.exit(1)
    if "-o" in a:
        key = jp(a[a.index("-o") + 1]).split("data.", 1)[1]; f = os.path.join(d(a[2]), key)
        if os.path.exists(f): sys.stdout.write(base64.b64encode(open(f, "rb").read()).decode())
    sys.exit(0)
if a[:3] == ["create", "secret", "generic"]:
    allow("create", "secrets", a[3])
    if crash == ns + "/" + a[3]: sys.stderr.write("stand-in: the run dies here\n"); sys.exit(137)
    if os.path.isdir(d(a[3])): sys.stderr.write("Error from server (AlreadyExists)\n"); sys.exit(1)
    os.makedirs(d(a[3]))
    for x in a[4:]:
        if x.startswith("--from-literal="):
            k, v = x[len("--from-literal="):].split("=", 1); open(os.path.join(d(a[3]), k), "w").write(v)
    ev("kubectl create %s/%s" % (ns, a[3])); print("secret/%s created" % a[3]); sys.exit(0)
if a[:2] == ["patch", "secret"]:
    allow("patch", "secrets", a[2])
    if not os.path.isdir(d(a[2])): sys.exit(1)
    for k, v in json.loads(a[a.index("-p") + 1])["stringData"].items(): open(os.path.join(d(a[2]), k), "w").write(v)
    ev("kubectl patch %s/%s" % (ns, a[2])); print("secret/%s patched" % a[2]); sys.exit(0)
if a[:2] == ["get", "backuptargets.longhorn.io"]:
    allow("get", "backuptargets", a[2]); f = os.path.join(K, ns, "_backuptarget.json")
    bt = json.load(open(f)) if os.path.exists(f) else {}
    path = jp(a[a.index("-o") + 1])
    sys.stdout.write(a[2] if path == "metadata.name" else bt.get(path.split(".")[-1], "")); sys.exit(0)
if a[:2] == ["patch", "backuptargets.longhorn.io"]:
    allow("patch", "backuptargets", a[2]); f = os.path.join(K, ns, "_backuptarget.json")
    json.dump(json.loads(a[a.index("-p") + 1])["spec"], open(f, "w")); sys.exit(0)
sys.stderr.write("kubectl stand-in: unhandled %r\n" % (sys.argv[1:],)); sys.exit(1)
PY
chmod +x "$T/kubectl"

# --- harness ---------------------------------------------------------------
fresh() { # a new store, empty namespaces, the admin Secret
  [ -n "$GPID" ] && kill "$GPID" 2>/dev/null; GPID=""
  rm -rf "$T/k" "$T/state.json" "$T/port" "$T/events"; mkdir -p "$T/k/default/tockmox-garage"
  printf 'admintoken' > "$T/k/default/tockmox-garage/admin-token"; : > "$T/events"
  python3 "$T/fake-garage.py" "$T/state.json" "$T/port" "$T/events" > "$T/garage.log" 2>&1 & GPID=$!
  for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
  [ -s "$T/port" ] || { echo "the stand-in Garage did not start" >&2; exit 1; }
}
run() { # SCRIPT [CRASH_CREATE]: one bootstrap run; its exit status
  sed "s#^ADMIN=.*#ADMIN=\"http://127.0.0.1:$(cat "$T/port")\"#; s#^\( *\)ADMIN=\"http://\${SVC}.*#\1ADMIN=\"http://127.0.0.1:$(cat "$T/port")\"#" "$1" > "$T/run.sh"
  # shellcheck disable=SC1091  # written above from the rendered Job
  ( set -a; . "$T/bootstrap.env"; set +a
    KDIR="$T/k" ROLES="$T/roles.json" EVENTS="$T/events" CRASH_CREATE="${2:-}" PATH="$T:$PATH" bash "$T/run.sh" ) > "$T/run.log" 2>&1
}
keys() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(" ".join(sorted(k for k,v in s["keys"].items() if v["name"]==sys.argv[2])))' "$T/state.json" "$1"; }
grants() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(" ".join(sorted(b["globalAliases"][0] for b in s["buckets"].values() if sys.argv[2] in b["keys"])))' "$T/state.json" "$1"; }
held() { cat "$T/k/$1/$2/${3:-ACCESS_KEY_ID}" 2>/dev/null; }

# Each scenario prints its own failures and returns non-zero on any.
k1() { local s="$1" bad=0 b r
  fresh; run "$s" || { echo "    first run failed: $(tail -1 "$T/run.log")"; return 1; }
  b=$(keys tockmox-backups); r=$(keys tockmox-drill-register)
  [ "$b" = "$(held default tockmox-garage-credentials)" ] || { echo "    tockmox-backups keys [$b], Secret holds $(held default tockmox-garage-credentials)"; bad=1; }
  [ "$r" = "$(held default tockmox-drill-register-credentials)" ] || { echo "    tockmox-drill-register keys [$r]"; bad=1; }
  for ns in tockmox-ai tockmox-authentik; do
    [ "$(held "$ns" tockmox-garage-credentials)" = "$b" ] || { echo "    $ns has no copy of the backup key"; bad=1; }
    [ "$(held "$ns" tockmox-drill-register-credentials)" = "$r" ] || { echo "    $ns has no copy of the register key"; bad=1; }
  done
  run "$s" || { echo "    second run failed: $(tail -1 "$T/run.log")"; return 1; }
  [ "$(keys tockmox-backups) $(keys tockmox-drill-register)" = "$b $r" ] || { echo "    the second run changed a key"; bad=1; }
  return "$bad"; }

k2() { local s="$1" bad=0 name sec ob nb pair
  fresh; run "$s" || { echo "    first run failed: $(tail -1 "$T/run.log")"; return 1; }
  for pair in tockmox-backups:tockmox-garage-credentials tockmox-drill-register:tockmox-drill-register-credentials; do
    name=${pair%%:*}; sec=${pair#*:}; ob=$(keys "$name")
    rm -rf "$T/k/default/$sec"; : > "$T/events"
    run "$s" || { echo "    the rotation run failed: $(tail -1 "$T/run.log")"; return 1; }
    nb=$(keys "$name")
    [ "$nb" = "$(held default "$sec")" ] && [ "$nb" != "$ob" ] || { echo "    after rotating $sec: $name keys [$nb], old $ob, Secret holds $(held default "$sec")"; bad=1; }
    python3 - "$T/events" "$ob" "default/$sec" <<'PY' || bad=1
import sys
ev = open(sys.argv[1]).read().splitlines()
d = [i for i, l in enumerate(ev) if l == "garage DeleteKey " + sys.argv[2]]
c = [i for i, l in enumerate(ev) if l == "kubectl create " + sys.argv[3]]
if not d: print("    the old key %s was never deleted" % sys.argv[2]); sys.exit(1)
if not c or d[0] > c[0]: print("    the old key was deleted after the new Secret %s was written" % sys.argv[3]); sys.exit(1)
PY
    for ns in tockmox-ai tockmox-authentik; do
      [ "$(held "$ns" "$sec")" = "$nb" ] || { echo "    $ns still holds the old $sec"; bad=1; }
    done
    if [ "$sec" = tockmox-garage-credentials ]; then
      [ "$(held default tockmox-longhorn-backup AWS_ACCESS_KEY_ID)" = "$nb" ] || { echo "    Longhorn's Secret still holds the old backup key"; bad=1; }
    fi
  done
  return "$bad"; }

k3() { local s="$1" bad=0 orphan
  fresh
  run "$s" default/tockmox-garage-credentials && { echo "    the run went on past a failed Secret create"; return 1; }
  orphan=$(keys tockmox-backups)
  [ -n "$orphan" ] || { echo "    no key was minted before the crash (the scenario did not run)"; return 1; }
  [ -z "$(grants "$orphan")" ] || { echo "    the orphaned key $orphan has a grant on: $(grants "$orphan")"; bad=1; }
  run "$s" || { echo "    the run after the crash failed: $(tail -1 "$T/run.log")"; return 1; }
  [ "$(keys tockmox-backups)" = "$(held default tockmox-garage-credentials)" ] || { echo "    after the next run, tockmox-backups keys [$(keys tockmox-backups)]"; bad=1; }
  return "$bad"; }

k4() { local s="$1" bad=0 port n
  fresh; run "$s" || { echo "    first run failed: $(tail -1 "$T/run.log")"; return 1; }
  port=$(cat "$T/port")
  for n in tockmox-backups tockmox-drill-register; do
    curl -sf -X POST -H 'Content-Type: application/json' -d "{\"name\":\"$n\"}" "http://127.0.0.1:$port/v2/CreateKey" >/dev/null
  done
  run "$s" || { echo "    the run failed: $(tail -1 "$T/run.log")"; return 1; }
  [ "$(keys tockmox-backups)" = "$(held default tockmox-garage-credentials)" ] || { echo "    an orphan tockmox-backups key survived: [$(keys tockmox-backups)]"; bad=1; }
  [ "$(keys tockmox-drill-register)" = "$(held default tockmox-drill-register-credentials)" ] || { echo "    an orphan tockmox-drill-register key survived: [$(keys tockmox-drill-register)]"; bad=1; }
  return "$bad"; }

k5() { local s="$1" bad=0 ns sec
  fresh; run "$s" || { echo "    first run failed: $(tail -1 "$T/run.log")"; return 1; }
  for ns in tockmox-ai tockmox-authentik; do for sec in tockmox-garage-credentials tockmox-drill-register-credentials; do rm -f "$T/k/$ns/$sec/REGION"; done; done
  run "$s" || { echo "    the run failed: $(grep -m1 -i 'forbidden\|error' "$T/run.log" || tail -1 "$T/run.log")"; return 1; }
  for ns in tockmox-ai tockmox-authentik; do for sec in tockmox-garage-credentials tockmox-drill-register-credentials; do
    [ -n "$(held "$ns" "$sec" REGION)" ] || { echo "    $ns/$sec still has no REGION"; bad=1; }
  done; done
  return "$bad"; }

ALL="k1 k2 k3 k4 k5"
desc() {
  case "$1" in
    k1) echo "K1 a fresh run mints one key per name, held by its Secret and copied; a second run changes no key" ;;
    k2) echo "K2 rotation deletes the old key before the new Secret is written, and every copy follows" ;;
    k3) echo "K3 a run that dies between CreateKey and the Secret create leaves a key with no grant, and the next run deletes it" ;;
    k4) echo "K4 an orphaned key of the same name is deleted with the Secret present" ;;
    k5) echo "K5 a copy without REGION gets it, under the Job's own Role" ;;
  esac
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  S="$T/bootstrap.sh"
  must_hold() { if "$1" "$S" >/dev/null; then :; else echo "selftest FAIL: $1 does not hold on the render"; fail=1; fi; }
  must_refuse() { local n="$1" c="$2" f="$3"; if "$c" "$f" >/dev/null; then echo "selftest FAIL: $n passed a script it must refuse"; fail=1; else echo "selftest ok: $n goes red"; fi; }
  for c in $ALL; do must_hold "$c"; done
  # no pruning at all: the old key lives on, and so does the orphan
  grep -v '^ *garage_prune ' "$S" > "$T/m.noprune"; must_refuse "K2 (no prune)" k2 "$T/m.noprune"; must_refuse "K4 (no prune)" k4 "$T/m.noprune"
  # prune only after the Secret: the old key outlives the new Secret's write
  grep -v 'garage_prune tockmox-[a-z-]* ""$' "$S" > "$T/m.late"; must_refuse "K2 (old key deleted after the new Secret)" k2 "$T/m.late"
  # the grant back between CreateKey and the Secret create (the old order)
  python3 - "$S" "$T/m.early" <<'PY'
import sys
s = open(sys.argv[1]).read()
anchor = '"{\\"name\\":\\"tockmox-backups\\"}" "$ADMIN/v2/CreateKey")\n'
i = s.index(anchor) + len(anchor); j = s.index("\n", s.index('SK=$(echo "$KEY"', i)) + 1
grant = '                curl -sf --max-time 15 -X POST -H "$AUTH" -H \'Content-Type: application/json\' -d "{\\"bucketId\\":\\"$BID\\",\\"accessKeyId\\":\\"$AK\\",\\"permissions\\":{\\"read\\":true,\\"write\\":true,\\"owner\\":false}}" "$ADMIN/v2/AllowBucketKey" >/dev/null\n'
open(sys.argv[2], "w").write(s[:j] + grant + s[j:])
PY
  must_refuse "K3 (grant before the Secret)" k3 "$T/m.early"
  # copies that never follow the source (sed patterns, not shell expansions)
  # shellcheck disable=SC2016
  sed 's/if \[ "\$cak" != "\$ak" \] || /if /' "$S" > "$T/m.nofollow"; must_refuse "K2 (copies keep the old key)" k2 "$T/m.nofollow"
  # shellcheck disable=SC2016
  sed 's/-o jsonpath=.{.data.AWS_ACCESS_KEY_ID}. | base64 -d)" != "\$AK" \]/-o jsonpath='"'"'{.data.AWS_ACCESS_KEY_ID}'"'"' | base64 -d)" = "x" ]/' "$S" > "$T/m.nolh"; must_refuse "K2 (Longhorn keeps the old key)" k2 "$T/m.nolh"
  # the copy-target Role without patch (as before this gate)
  cp "$T/roles.json" "$T/roles.good"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); [x.__setitem__("verbs",[v for v in x["verbs"] if v!="patch"]) for ns,rs in r.items() if ns!="default" for x in rs]; json.dump(r,open(sys.argv[1],"w"))' "$T/roles.json"
  must_refuse "K5 (copy-target Role without patch)" k5 "$S"
  cp "$T/roles.good" "$T/roles.json"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

rc=0
for c in $ALL; do
  # Not in $(...): the stand-in Garage runs in the background and must stay a
  # child of this shell, so cleanup can stop it.
  if "$c" "$T/bootstrap.sh" > "$T/out"; then echo "  ok   $(desc "$c")"; else echo "  FAIL $(desc "$c")"; cat "$T/out"; rc=1; fi
done
exit $rc

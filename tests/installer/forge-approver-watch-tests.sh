#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups W1-W8: install/forge-approver-watch.py --once against one stand-in that answers
# as the identity provider (/api/v3/...) and as the forge (/api/v1/...), from a fixture this file writes per
# case, and records every request it was sent. Each case changes one thing in the fixture, so each proves its
# check can go red.
#
#   W1  every team member an active admin: check ok, nobody outside, no per-person series
#   W2  a member removed from the group: outside 1, an info series naming them, the PR they approved listed
#   W3  a deactivated member counts as removed (ruled 2026-11-04, R4)
#   W4  an approval later dismissed, or replaced by a change request, does not stand; a comment does not undo it
#   W5  the identity provider erroring, answering 403, or returning an empty or missing group: check not ok and
#       NOBODY judged (no outside count, no info series)
#   W6  the forge erroring, or the team missing: the same fail-safe
#   W7  a page of 50 team members is followed to the next page
#   W8  it only ever sent GET, and the token went in the header, never the URL
#
# What it does not show: that the real identity provider answers include_users=true with users_obj, or that a
# read:organization token may list the team. Those are lab items.

AW="$REPO_ROOT/install/forge-approver-watch.py"
AWD="$(mktemp -d "${TMPDIR:-/tmp}/aw-test.XXXXXX")"

cat > "$AWD/stub.py" <<'PY'
import http.server, json, sys, urllib.parse
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def handle_one(self):
        with open(f"{D}/asked", "a") as fh:
            fh.write(json.dumps({"method": self.command, "path": self.path,
                                 "auth": self.headers.get("Authorization", "")}) + "\n")
        fx = json.load(open(f"{D}/fixture.json"))
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        code, body = 404, {"message": "not found"}
        p = u.path
        if p == "/api/v3/core/groups/":
            if fx.get("ak_status", 200) != 200:
                code, body = fx["ak_status"], {"detail": "no"}
            else:
                code, body = 200, {"results": fx["groups"]}
        elif p.startswith("/api/v1/"):
            if fx.get("forge_status", 200) != 200:
                code, body = fx["forge_status"], {"message": "no"}
            elif p == "/api/v1/orgs/tockmox/teams/search":
                code, body = 200, {"ok": True, "data": fx["teams"]}
            elif p == "/api/v1/teams/7/members":
                page = int(q.get("page", ["1"])[0]); lim = int(q.get("limit", ["50"])[0])
                code, body = 200, fx["members"][(page - 1) * lim: page * lim]
            elif p == "/api/v1/repos/tockmox/site/pulls":
                page = int(q.get("page", ["1"])[0])
                code, body = 200, fx["pulls"] if page == 1 else []
            elif p.startswith("/api/v1/repos/tockmox/site/pulls/") and p.endswith("/reviews"):
                n = p.split("/")[-2]; page = int(q.get("page", ["1"])[0])
                code, body = 200, fx["reviews"].get(n, []) if page == 1 else []
        raw = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(raw)
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_one
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(f"{D}/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$AWD/stub.py" "$AWD" & AW_PID=$!
for _ in $(seq 1 50); do [ -s "$AWD/port" ] && break; sleep 0.1; done
AW_PORT="$(cat "$AWD/port" 2>/dev/null)"
printf 'ak-token-line\n' > "$AWD/ak.token"; printf 'forge-token-line\n' > "$AWD/forge.token"

# aw_fixture JSON: write the case's fixture. aw_run: one --once check; stdout is the metrics, then "rc=<exit>".
aw_fixture() { printf '%s' "$1" > "$AWD/fixture.json"; : > "$AWD/asked"; }
aw_run() {
  AUTHENTIK_URL="http://127.0.0.1:$AW_PORT" AUTHENTIK_TOKEN_FILE="$AWD/ak.token" \
  FORGE_URL="http://127.0.0.1:$AW_PORT" FORGE_TOKEN_FILE="$AWD/forge.token" \
    python3 "$AW" --once 2>/dev/null | grep -v '_last_success_timestamp_seconds' | sed 's/since="[0-9]*"/since="T"/'
  echo "rc=${PIPESTATUS[0]}"
}
# The base case: two admins, both in the team; PR 4 approved by bob.
AW_BASE='{"groups":[{"name":"tockmox-admins","users_obj":[{"username":"alice","is_active":true},{"username":"bob","is_active":true}]}],
 "teams":[{"id":7,"name":"approvers"}],
 "members":[{"login":"alice"},{"login":"bob"}],
 "pulls":[{"number":4},{"number":5}],
 "reviews":{"4":[{"id":1,"user":{"login":"bob"},"state":"APPROVED"}],"5":[]}}'
aw_with() { python3 -c 'import json,sys; b=json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(b))' "$AW_BASE" "$1"; }

path_begin "W1" "every approver an active admin: check ok, nobody outside"
aw_fixture "$AW_BASE"
assert_artifact "ok 1, outside 0, no per-person series, exit 0" "aw_run" \
  "$(printf 'tockmox_forge_approvers_check_ok 1\ntockmox_forge_approvers_outside_group 0\nrc=0')"

path_begin "W2" "bob removed from the group: named, with the PR his approval still stands on"
aw_fixture "$(aw_with 'b["groups"][0]["users_obj"]=[u for u in b["groups"][0]["users_obj"] if u["username"]!="bob"]')"
assert_artifact "outside 1, bob's info series, PR 4 listed, not PR 5" "aw_run" \
  "$(printf 'tockmox_forge_approvers_check_ok 1\ntockmox_forge_approvers_outside_group 1\ntockmox_forge_approver_outside_group_info{user="bob",since="T"} 1\ntockmox_forge_approval_by_outside_approver{user="bob",pr="4"} 1\nrc=0')"

path_begin "W3" "bob deactivated (still in the group) counts as removed"
aw_fixture "$(aw_with 'b["groups"][0]["users_obj"][1]["is_active"]=False')"
assert_artifact "outside 1 naming bob" "aw_run | grep -c 'outside_group_info{user=\"bob\"'" "1"

path_begin "W4" "only a standing approval is listed"
aw_fixture "$(aw_with 'b["groups"][0]["users_obj"].pop(1); b["reviews"]["4"][0]["dismissed"]=True')"
assert_artifact "a dismissed approval is not listed" "aw_run | grep -c approval_by_outside" "0"
aw_fixture "$(aw_with 'b["groups"][0]["users_obj"].pop(1); b["reviews"]["4"].append({"id":2,"user":{"login":"bob"},"state":"REQUEST_CHANGES"})')"
assert_artifact "an approval replaced by a change request is not listed" "aw_run | grep -c approval_by_outside" "0"
aw_fixture "$(aw_with 'b["groups"][0]["users_obj"].pop(1); b["reviews"]["4"].append({"id":2,"user":{"login":"bob"},"state":"COMMENT"})')"
assert_artifact "a later comment leaves the approval standing" "aw_run | grep -c approval_by_outside" "1"

path_begin "W5" "an identity provider that cannot be read cleanly judges nobody"
for c in 'b["ak_status"]=500' 'b["ak_status"]=403' 'b["groups"]=[]' 'b["groups"][0]["users_obj"]=[]' 'del b["groups"][0]["users_obj"]' \
         'b["groups"][0]["users_obj"]=[{"username":"alice","is_active":False},{"username":"bob","is_active":False}]'; do
  aw_fixture "$(aw_with "$c")"
  assert_artifact "check_ok 0, no outside count, no person named, exit 1 ($c)" "aw_run" \
    "$(printf 'tockmox_forge_approvers_check_ok 0\nrc=1')"
done

path_begin "W6" "a forge that cannot be read cleanly judges nobody"
for c in 'b["forge_status"]=500' 'b["teams"]=[]' 'b["teams"].append({"id":8,"name":"approvers"})'; do
  aw_fixture "$(aw_with "b['groups'][0]['users_obj'].pop(1); $c")"
  assert_artifact "check_ok 0, nobody named, exit 1 ($c)" "aw_run" \
    "$(printf 'tockmox_forge_approvers_check_ok 0\nrc=1')"
done

path_begin "W7" "the team's second page is read"
aw_fixture "$(aw_with 'b["members"]=[{"login":"alice"}]+[{"login":"m%02d" % i} for i in range(49)]+[{"login":"bob"},{"login":"zed"}]; b["groups"][0]["users_obj"]+= [{"username":"m%02d" % i,"is_active":True} for i in range(49)]+[{"username":"zed","is_active":True}]; b["groups"][0]["users_obj"].pop(1)')"
assert_artifact "bob, on page 2, is named" "aw_run | grep -c 'outside_group_info{user=\"bob\"'" "1"

path_begin "W8" "read only: every request a GET, the tokens in the header"
aw_fixture "$AW_BASE"; aw_run >/dev/null
assert_artifact "methods sent, and whether a token is in any URL" \
  "python3 -c 'import json,sys; a=[json.loads(l) for l in open(sys.argv[1])]; print(sorted({x[\"method\"] for x in a})); print(any(\"token-line\" in x[\"path\"] for x in a)); print(sorted({x[\"auth\"].split()[0] for x in a}))' '$AWD/asked'" \
  "$(printf "['GET']\nFalse\n['Bearer', 'token']")"

kill "$AW_PID" 2>/dev/null; wait "$AW_PID" 2>/dev/null
rm -rf "$AWD"

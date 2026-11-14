#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof of P15's rows: an approver taken out of the admin group, or deactivated, is alerted on; a failed read
# judges nobody and raises CheckDown; the page's removal clears it. No cluster. Four layers.
#
#   1. The verdicts (lib/p15-approver-revocation.py). A green fixture for each, then one planted red per thing the
#      verdict reads, each of which must change the verdict. An empty or unreadable input is never a pass.
#   2. The page. The block P15 runs resolves in this tree to one block, holds the two placeholders P15 fills, and keeps
#      its success condition ("It prints 204") beside it; the names P15 asserts on are the ones the chart and the
#      installer use. A page or chart edit that breaks any of these is red here, per commit, not on the next lane run.
#   3. The path as a script, against a stub product: kubectl and curl answer from one state file that the path's own
#      calls change (Authentik's users and the admin group, the forge's accounts, team and pull requests, the watcher's
#      two token copies), and the watcher's check and Prometheus's alerts are computed from that state the way
#      forge-approver-watch.py and site-forge-rules.yaml compute them. Green end to end, then one broken product per
#      row, each of which must fail the path at that row. Then mutated copies of P15 that lose a step or a guard, each
#      of which must not end PASS.
#   4. The gate: P15 runs after P09 on the built-in route and must declare BLOCKED, with no cluster call, when P09's
#      state, its PASS marker or the built-in route is missing.
#
#   ./tests/executed-docs/approver-revocation-rows-test.sh
#   P15=/path/to/P15.sh ./tests/executed-docs/approver-revocation-rows-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture text is literal
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "${HERE}/../.." && pwd)"
P15="${P15:-${HERE}/paths/P15-approver-revocation.sh}"
PY="${HERE}/lib/p15-approver-revocation.py"
EXTRACT="${HERE}/lib/extract-block.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
v() { python3 -I "$PY" "$@" | head -1; }
is() { # LABEL EXPECTED ACTUAL
  [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [${2}], got [${3}]"
}
isun() { # LABEL ACTUAL ... the verdict must be unreadable
  case "$2" in unreadable*) ok "$1" ;; *) bad "$1" "expected unreadable, got [${2}]" ;; esac
}
mut() { # IN OUT OLD NEW ... a copy with every OLD replaced by NEW; refuses an edit that changes nothing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
t = s.replace(old, new)
assert t != s, "the edit changed nothing: %r" % old
open(dst, "w", encoding="utf-8").write(t)
PY
}
U=p15-approver
G=tockmox.site-repository
AO=TockmoxForgeApproverOutsideGroup
AD=TockmoxForgeApproversCheckDown

# ------------------------------------------------------------------ 1. the verdicts
W="${TMP}/w.txt"
wmet() { printf '%s\n' "$@" > "$W"; }
wmet 'tockmox_forge_approvers_check_ok 1' 'tockmox_forge_approvers_outside_group 0' 'tockmox_forge_approvers_last_success_timestamp_seconds 5'
is "watch: a clean check with nobody outside" "clean, not outside" "$(v watch --user "$U" < "$W")"
wmet 'forge-approver-watch: outside the group but still approvers: p15-approver' 'tockmox_forge_approvers_check_ok 1' 'tockmox_forge_approvers_outside_group 1' \
  'tockmox_forge_approver_outside_group_info{user="p15-approver",since="5"} 1' 'tockmox_forge_approval_by_outside_approver{user="p15-approver",pr="7"} 1'
is "watch: a clean check that names the person (a log line beside the metrics is skipped)" "clean, outside" "$(v watch --user "$U" < "$W")"
is "watch: ... and someone else is not outside" "clean, not outside" "$(v watch --user other < "$W")"
is "watch-prs: the pull requests the person's approval stands on" "#7" "$(v watch-prs --user "$U" < "$W")"
is "watch-prs: another person's approvals are not theirs" "none" "$(v watch-prs --user other < "$W")"
wmet 'tockmox_forge_approvers_check_ok 1' 'tockmox_forge_approvers_outside_group 2' 'tockmox_forge_approver_outside_group_info{user="p15-approver",since="5"} 1'
isun "watch: a count that disagrees with the people named is unreadable" "$(v watch --user "$U" < "$W")"
wmet 'tockmox_forge_approvers_check_ok 0' 'tockmox_forge_approvers_last_success_timestamp_seconds 5'
is "watch: a check that is not clean and names nobody" "not clean, nobody judged" "$(v watch --user "$U" < "$W")"
wmet 'tockmox_forge_approvers_check_ok 0' 'tockmox_forge_approver_outside_group_info{user="p15-approver",since="5"} 1'
case "$(v watch --user "$U" < "$W")" in "not clean, yet judged"*) ok "watch: a check that is not clean but still names a person is judged, not 'nobody judged'" ;; *) bad "watch: judged on a bad read" "$(v watch --user "$U" < "$W")" ;; esac
wmet 'tockmox_forge_approvers_check_ok 0' 'tockmox_forge_approvers_outside_group 0'
case "$(v watch --user "$U" < "$W")" in "not clean, yet judged"*) ok "watch: a count beside a check that is not clean is judged too" ;; *) bad "watch: count on a bad read" "" ;; esac
wmet 'forge-approver-watch: check not ok, nobody judged: GET x: HTTP 403'
isun "watch: output with no check_ok line (the exec failed) is unreadable" "$(v watch --user "$U" < "$W")"
isun "watch: an empty read is unreadable, never clean" "$(: | v watch --user "$U")"
wmet 'tockmox_forge_approvers_check_ok 1' 'tockmox_forge_approvers_check_ok 1' 'tockmox_forge_approvers_outside_group 0'
isun "watch: two check_ok lines are unreadable" "$(v watch --user "$U" < "$W")"

R="${TMP}/rules.json"
# mk_rules OUT-STATE DOWN-STATE [DESCRIPTION] [OUT-HEALTH] [DOWN-FOR]
mk_rules() {
  python3 - "$R" "$@" <<'PY'
import json, sys
f, out, down = sys.argv[1], sys.argv[2], sys.argv[3]
desc = sys.argv[4] if len(sys.argv) > 4 else "p15-approver is in the approvers team. Take them out: https://forge.example.internal/org/tockmox/teams/approvers (one click). Open pull requests their approval still stands on: #7."
health = sys.argv[5] if len(sys.argv) > 5 else "ok"
dfor = int(sys.argv[6]) if len(sys.argv) > 6 else 900
def inst(state, labels, d=""):
    return [] if state == "inactive" else [{"labels": labels, "annotations": {"description": d}, "state": state}]
doc = {"status": "success", "data": {"groups": [
  {"name": "tockmox.site-repository", "rules": [
    {"name": "TockmoxForgeApproverOutsideGroup", "type": "alerting", "health": health, "duration": 0,
     "alerts": inst(out, {"alertname": "TockmoxForgeApproverOutsideGroup", "user": "p15-approver"}, desc)},
    {"name": "TockmoxForgeApproversCheckDown", "type": "alerting", "health": "ok", "duration": dfor,
     "alerts": inst(down, {"alertname": "TockmoxForgeApproversCheckDown"})}]},
  {"name": "other", "rules": [{"name": "TockmoxForgeApproverOutsideGroup", "type": "alerting", "health": "ok", "duration": 0, "alerts": []}]}]}}
json.dump(doc, open(f, "w"))
PY
}
mk_rules inactive inactive
is "rule: the outside-group rule is loaded, healthy, with no for:" "loaded, healthy, for 0s" "$(v rule --group "$G" --alert "$AO" < "$R")"
is "rule: CheckDown is loaded with its 15 minutes" "loaded, healthy, for 900s" "$(v rule --group "$G" --alert "$AD" < "$R")"
is "rule: a rule of that name in another group is not this one" "absent" "$(v rule --group "$G" --alert NoSuchAlert < "$R")"
is "alert: nothing firing reads inactive" "inactive" "$(v alert --group "$G" --alert "$AO" --user "$U" < "$R")"
mk_rules firing pending
is "alert: an instance for the person that fires reads firing" "firing" "$(v alert --group "$G" --alert "$AO" --user "$U" < "$R")"
is "alert: an instance for another person does not count for this one" "inactive" "$(v alert --group "$G" --alert "$AO" --user other < "$R")"
is "alert: a pending CheckDown reads pending, not firing" "pending" "$(v alert --group "$G" --alert "$AD" < "$R")"
is "annotation: the description names the team and the pull request" "names the team and #7" "$(v annotation --group "$G" --alert "$AO" --user "$U" --team /org/tockmox/teams/approvers --pr 7 < "$R")"
is "annotation: another pull request number is missing, not a prefix match" "missing: #70" "$(v annotation --group "$G" --alert "$AO" --user "$U" --team /org/tockmox/teams/approvers --pr 70 < "$R")"
mk_rules firing inactive "p15-approver ... Open pull requests their approval still stands on: none."
is "annotation: a description without the team or the pull request says both are missing" "missing: the team, #7" "$(v annotation --group "$G" --alert "$AO" --user "$U" --team /org/tockmox/teams/approvers --pr 7 < "$R")"
mk_rules firing inactive "x" bad 0
is "rule: a rule Prometheus reports unhealthy says so" "loaded, health bad, for 0s" "$(v rule --group "$G" --alert "$AO" < "$R")"
mk_rules inactive inactive "x" ok 600
is "rule: CheckDown with another for: says it" "loaded, healthy, for 600s" "$(v rule --group "$G" --alert "$AD" < "$R")"
isun "annotation: no firing instance is unreadable" "$(v annotation --group "$G" --alert "$AO" --user "$U" --team /x --pr 7 < "$R")"
isun "alert: an empty read is unreadable, never inactive" "$(: | v alert --group "$G" --alert "$AO")"
isun "alert: an answer that is not success is unreadable" "$(printf '{"status":"error"}' | v alert --group "$G" --alert "$AO")"
isun "alert: an API error object is unreadable" "$(printf '{"kind":"Status","code":503}' | v alert --group "$G" --alert "$AO")"

RV="${TMP}/rv.json"
printf '[{"id":1,"user":{"login":"p15-approver"},"state":"APPROVED"}]' > "$RV"
is "review: an approval stands" "standing approval" "$(v review --user "$U" < "$RV")"
printf '[{"id":1,"user":{"login":"p15-approver"},"state":"APPROVED"},{"id":2,"user":{"login":"p15-approver"},"state":"REQUEST_CHANGES"}]' > "$RV"
is "review: an approval later replaced by a change request does not stand" "no standing approval" "$(v review --user "$U" < "$RV")"
printf '[{"id":1,"user":{"login":"p15-approver"},"state":"APPROVED"},{"id":2,"user":{"login":"p15-approver"},"state":"COMMENT"}]' > "$RV"
is "review: a comment after an approval leaves it standing" "standing approval" "$(v review --user "$U" < "$RV")"
printf '[{"id":1,"user":{"login":"p15-approver"},"state":"APPROVED","dismissed":true}]' > "$RV"
is "review: a dismissed approval does not stand" "no standing approval" "$(v review --user "$U" < "$RV")"
printf '[{"id":1,"user":{"login":"other"},"state":"APPROVED"}]' > "$RV"
is "review: someone else's approval is not theirs" "no standing approval" "$(v review --user "$U" < "$RV")"
isun "review: an empty read is unreadable" "$(: | v review --user "$U")"
is "member: in the list" "member" "$(printf '[{"login":"a"},{"login":"p15-approver"}]' | v member --user "$U")"
is "member: not in the list" "not member" "$(printf '[{"login":"a"}]' | v member --user "$U")"
isun "member: an error object is unreadable, never 'not member'" "$(printf '{"message":"not found"}' | v member --user "$U")"
is "field: a value is read" "7" "$(printf '{"number":7}' | v field --name number)"
isun "field: a missing key is unreadable" "$(printf '{"x":7}' | v field --name number)"
is "ak: the marker line is read past Authentik's own log lines" "active, member" "$(printf '{"event":"x"}\nP15 state=active, member\n' | v ak --key state)"
isun "ak: no marker line (the shell failed) is unreadable" "$(printf 'Traceback\n' | v ak --key state)"
PACED="$(printf 'a &\nb=1\n\n# c\nd \\\n  e; f\n' | python3 -I "$PY" pace --seconds 3)"
is "pace: a pause after each command line, none inside a continued one, none after a blank or comment line" \
  'a &|P15_RC=$?; sleep 3|b=1|P15_RC=$?; sleep 3||# c|d \|  e; f|P15_RC=$?; sleep 3' "$(printf '%s' "$PACED" | tr '\n' '|')"
is "pace: the block's own lines are all there, unchanged and in order" "$(printf 'a &\nb=1\n\n# c\nd \\\n  e; f\n')" "$(printf '%s\n' "$PACED" | grep -v '^P15_RC=')"

# ------------------------------------------------------------------ 2. the page, the chart and the installer
B="${TMP}/block.sh"
bash "$EXTRACT" --file "${TREE}/docs/administration/identity.md" --section '## The built-in forge: sign-in and approvers' --lang bash --containing 'members/<their-forge-name>' > "$B" 2>/dev/null
[ -s "$B" ] && ok "page: the block P15 runs resolves in this tree, to one block" || bad "page: the block resolves" ""
is "page: it holds <their-forge-name> once and <your-cluster> twice, the placeholders P15 fills" "1 2" "$(grep -o '<their-forge-name>' "$B" | wc -l | tr -d ' ') $(grep -o '<your-cluster>' "$B" | wc -l | tr -d ' ')"
grep -q 'port-forward svc/tockmox-forge-http 3000:3000' "$B" && grep -q 'secret tockmox-forge-admin' "$B" && grep -q '/api/v1/orgs/tockmox/members/' "$B" \
  && ok "page: it reaches the forge the way P15's own calls do (the same Service, the same admin Secret, the same organisation)" || bad "page: the block's names" "$(cat "$B")"
grep -q '^It prints `204`. Stop the port-forward afterwards (`kill %1`' "${TREE}/docs/administration/identity.md" \
  && ok "page: its success condition (It prints 204) and the kill %1 P15 adds are the page's own words" || bad "page: success condition" ""
RULES="${TREE}/charts/tockmox-observability/templates/site-forge-rules.yaml"
grep -q '^    - name: tockmox.site-repository$' "$RULES" && grep -q '      - alert: TockmoxForgeApproverOutsideGroup$' "$RULES" && grep -q '      - alert: TockmoxForgeApproversCheckDown$' "$RULES" \
  && ok "chart: the group and the two alert names P15 reads are the chart's" || bad "chart: names" ""
[ "$(awk '/alert: TockmoxForgeApproversCheckDown/{f=1} f && /^ *for: /{print $2; exit}' "$RULES")" = 15m ] \
  && awk '/alert: TockmoxForgeApproverOutsideGroup/{f=1} f && /alert: TockmoxForgeApproversCheckDown/{exit} f && /^ *for: /{bad=1} END{exit bad}' "$RULES" \
  && ok "chart: CheckDown has for: 15m (P15's 900s) and the outside-group alert has none" || bad "chart: for:" ""
grep -q 'org/tockmox/teams/approvers' "$RULES" && grep -q 'tockmox_forge_approval_by_outside_approver' "$RULES" \
  && ok "chart: the outside-group description carries the team link and the pull requests, the two things P15 reads in it" || bad "chart: description" ""
TPL="${TREE}/install/forge-approver-watch-template.sh"
grep -q 'AUTHENTIK_TOKEN_FILE, value: /run/watch/authentik-token' "$TPL" && grep -q 'secret: { secretName: ${NAME}' "$TPL" && ! grep -q subPath "$TPL" \
  && ok "installer: the watcher reads its Authentik token from key authentik-token of its own Secret, mounted whole (no subPath), so a changed key reaches the pod" || bad "installer: the token mount" ""
grep -q 'FORGE_APPROVER_WATCH_TOKEN="$WATCH_AK"' "${TREE}/install/bootstrap-forge.sh" && grep -q 'authentik-token="$WATCH_AK"' "${TREE}/install/bootstrap-forge.sh" \
  && ok "installer: the identity layer's copy (FORGE_APPROVER_WATCH_TOKEN) is the same value, so P15 can put the watcher's back from it" || bad "installer: two copies" ""
grep -q '"is_active") is True' "${TREE}/install/forge-approver-watch.py" && ok "watcher: it reads is_active, so deactivation is something it can see" || bad "watcher: is_active" ""

# ------------------------------------------------------------------ 3. the path as a script
BIN="${TMP}/bin"; mkdir -p "$BIN"
cat > "$BIN/product.py" <<'PRODUCT'
#!/usr/bin/env python3
# The product, stood in for, from one state file. argv[1] is kubectl or curl; the rest is what the path passed.
# SB_MODE breaks one thing.
import base64, json, os, re, sys, time
SB = os.environ["SB"]; MODE = os.environ.get("SB_MODE", "")
SF = os.path.join(SB, "state.json")
GOOD = base64.b64encode(b"good-token").decode()
st = json.load(open(SF)) if os.path.exists(SF) else {
    "ak": {"akadmin": {"active": True, "member": True}}, "forge_users": ["akadmin", "tockmox-approver-watch"],
    "team": [], "prs": {}, "branches": ["main"], "watch_tok": GOOD, "id_tok": GOOD, "seen_firing": 0}
def save(): json.dump(st, open(SF, "w"))
def watcher():
    if st["watch_tok"] != st["id_tok"] and MODE != "reads-through-bad-token":
        return None
    admins = {u for u, a in st["ak"].items() if a["member"] and (a["active"] or MODE == "ignores-deactivation")}
    out = sorted(set(st["team"]) - admins)
    prs = {n: p["approved"] for n, p in st["prs"].items() if p["state"] == "open"}
    return out, prs
def metrics():
    w = watcher()
    if w is None:
        lines = ["tockmox_forge_approvers_check_ok 0"]
        if MODE == "judges-on-bad-read":
            lines.append('tockmox_forge_approver_outside_group_info{user="p15-approver",since="1"} 1')
        return "forge-approver-watch: check not ok, nobody judged: HTTP 403\n" + "\n".join(lines) + "\n"
    out, prs = w
    lines = ["tockmox_forge_approvers_check_ok 1", "tockmox_forge_approvers_outside_group %d" % len(out)]
    lines += ['tockmox_forge_approver_outside_group_info{user="%s",since="1"} 1' % u for u in out]
    lines += ['tockmox_forge_approval_by_outside_approver{user="%s",pr="%s"} 1' % (u, n) for n, a in prs.items() for u in a if u in out]
    return "\n".join(lines) + "\n"
def rules():
    w = watcher()
    outs = [] if w is None else w[0]
    if MODE == "never-alerts":
        outs = []
    if outs and MODE == "slow-alert" and st["seen_firing"] == 0:
        st["seen_firing"] = 1; save(); time.sleep(2)
    al = []
    for u in outs:
        prs = "" if MODE == "no-pr-in-description" else " ".join("#" + n for n, p in st["prs"].items() if p["state"] == "open" and u in p["approved"])
        al.append({"labels": {"alertname": "TockmoxForgeApproverOutsideGroup", "user": u}, "state": "firing",
                   "annotations": {"description": "%s ... https://forge.x/org/tockmox/teams/approvers ... stands on: %s." % (u, prs or "none")}})
    down = [] if (w is not None or MODE == "checkdown-never") else [{"labels": {"alertname": "TockmoxForgeApproversCheckDown"}, "state": "firing", "annotations": {}}]
    return {"status": "success", "data": {"groups": [{"name": "tockmox.site-repository", "rules": [
        {"name": "TockmoxForgeApproverOutsideGroup", "type": "alerting", "health": "ok", "duration": 0, "alerts": al},
        {"name": "TockmoxForgeApproversCheckDown", "type": "alerting", "health": "ok", "duration": 900, "alerts": down}]}]}}
def kubectl(a):
    j = " ".join(a)
    if "port-forward" in j:
        os.execvp("sleep", ["sleep", "600"])
    if "get deploy -l app.kubernetes.io/name=authentik" in j:
        print("tockmox-authentik-worker", end=""); return 0
    if "ak shell -c" in j:
        code = a[-1]; op = re.search(r"# p15-op: (\w+)", code).group(1); name = re.search(r'name = "([^"]+)"', code).group(1)
        u = st["ak"].get(name)
        if op == "plant": st["ak"][name] = u = {"active": True, "member": True}
        elif op == "remove" and u: u["member"] = False
        elif op == "add" and u: u["member"] = True
        elif op == "deactivate" and u: u["active"] = False
        elif op == "delete": st["ak"].pop(name, None); u = None
        save()
        print('{"event": "authentik starting", "level": "info"}')
        if u is None: print("P15 state=absent\nP15 login=none")
        else: print("P15 state=%s, %s\nP15 login=none" % ("active" if u["active"] else "inactive", "member" if u["member"] else "not member"))
        return 0
    if "forge-approver-watch.py --once" in j:
        sys.stdout.write(metrics()); return 0
    if "get --raw" in j and "/api/v1/rules" in j:
        print(json.dumps(rules())); return 0
    if "get secret tockmox-forge-admin" in j:
        print(base64.b64encode(b"stubpass").decode(), end=""); return 0
    if "-n tockmox-forge get secret tockmox-forge-approver-watch" in j:
        print(st["watch_tok"], end=""); return 0
    if "-n tockmox-authentik get secret tockmox-forge-approver-watch" in j:
        print(st["id_tok"], end=""); return 0
    if "patch secret tockmox-forge-approver-watch" in j:
        st["watch_tok"] = json.loads(sys.stdin.read())["data"]["authentik-token"]; save(); print("secret patched"); return 0
    sys.stderr.write("stub kubectl: no answer for: %s\n" % j); return 1
def curl(a):
    m, body, sudo, out, url = "GET", "", "", None, ""
    i = 0
    while i < len(a):
        x = a[i]
        if x == "-X": m = a[i + 1]; i += 1
        elif x == "--data-binary": body = a[i + 1]; i += 1
        elif x == "-H" and a[i + 1].startswith("Sudo: "): sudo = a[i + 1][6:]; i += 1
        elif x in ("-H", "-w", "-K"): i += 1
        elif x == "-o": out = a[i + 1]; i += 1
        elif x.startswith("http"): url = x
        i += 1
    p = re.sub(r"^http://127\.0\.0\.1:\d+/api/v1", "", url).split("?")[0]
    code, resp = 404, {"message": "not found"}
    if p == "/version": code, resp = 200, {"version": "15"}
    elif re.match(r"^/users/([^/]+)$", p):
        n = p.split("/")[2]
        if n in st["forge_users"]: code, resp = 200, {"login": n, "last_login": "1970-01-01T00:00:00Z"}
    elif p == "/admin/users" and m == "POST":
        n = json.loads(body)["username"]; st["forge_users"].append(n); code, resp = 201, {"login": n}
    elif re.match(r"^/admin/users/[^/]+$", p) and m == "DELETE":
        n = p.split("/")[3]
        if n in st["forge_users"]:
            st["forge_users"].remove(n); st["team"] = [t for t in st["team"] if t != n]; code, resp = 204, None
    elif p == "/orgs/tockmox/teams": code, resp = 200, [{"id": 3, "name": "Owners"}, {"id": 4, "name": "approvers"}]
    elif p == "/teams/4/members": code, resp = 200, [{"login": t} for t in st["team"]]
    elif re.match(r"^/teams/4/members/[^/]+$", p) and m == "PUT":
        st["team"].append(p.split("/")[4]); code, resp = 204, None
    elif re.match(r"^/orgs/tockmox/members/[^/]+$", p) and m == "DELETE":
        n = p.split("/")[4]
        if MODE != "removal-ignored": st["team"] = [t for t in st["team"] if t != n]
        code, resp = 204, None
    elif re.match(r"^/repos/tockmox/site/contents/", p) and m == "POST":
        st["branches"].append(json.loads(body)["new_branch"]); code, resp = 201, {}
    elif p == "/repos/tockmox/site/pulls" and m == "POST":
        n = str(len(st["prs"]) + 7); st["prs"][n] = {"state": "open", "approved": [], "merged": False}; code, resp = 201, {"number": int(n)}
    elif re.match(r"^/repos/tockmox/site/pulls/\d+/reviews$", p):
        n = p.split("/")[5]
        if m == "POST":
            if sudo: st["prs"][n]["approved"].append(sudo)
            code, resp = 200, {}
        else:
            code, resp = 200, [{"id": k + 1, "user": {"login": u}, "state": "APPROVED"} for k, u in enumerate(st["prs"][n]["approved"])]
    elif re.match(r"^/repos/tockmox/site/pulls/\d+$", p):
        n = p.split("/")[5]
        if m == "PATCH": st["prs"][n]["state"] = "closed"; code, resp = 201, {}
        else: code, resp = 200, {"number": int(n), "state": st["prs"][n]["state"], "merged": st["prs"][n]["merged"]}
    elif re.match(r"^/repos/tockmox/site/branches/", p):
        b = p.split("/")[5]
        if b in st["branches"]:
            if m == "DELETE": st["branches"].remove(b); code, resp = 204, None
            else: code, resp = 200, {"name": b}
    save()
    if out and out != "/dev/null":
        open(out, "w").write("" if resp is None else json.dumps(resp))
    print(code)
    return 0
sys.exit(kubectl(sys.argv[2:]) if sys.argv[1] == "kubectl" else curl(sys.argv[2:]))
PRODUCT
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$(printf "%%s" "$*" | tr "\\n" " ")" >> "${SB}/calls.log"\nexec python3 -I "%s/product.py" kubectl "$@"\n' "$BIN" > "$BIN/kubectl"
printf '#!/usr/bin/env bash\necho "curl $*" >> "${SB}/curl.log"\nexec python3 -I "%s/product.py" curl "$@"\n' "$BIN" > "$BIN/curl"
chmod +x "$BIN/kubectl" "$BIN/curl" "$BIN/product.py"
GT="${TMP}/tree"; mkdir -p "$GT/paths"; ln -s "${HERE}/lib" "$GT/lib"
sandbox() { local d; d="$(mktemp -d "${TMP}/sbx.XXXXXX")"; mkdir -p "$d/p09"; : > "$d/p09/p09-passed"; printf '%s' "$d"; }
# run_p15 FILE SANDBOX [VAR=VALUE ...] ... the path as run.sh runs it; prints "rc|receipt"
run_p15() {
  local f="$1" d="$2"; shift 2
  env SB="$d" PATH="${BIN}:${PATH}" OUTCOME_RECEIPT_DIR="$d/r" TOCKMOX_PATH_NAME=P15-approver-revocation KUBE_CONTEXT=stub-ctx \
      TOCKMOX_DOCS_REF=HEAD TOCKMOX_P09_ROUTE=built-in TOCKMOX_P15_FROM_TREE=1 \
      TOCKMOX_P15_ID_PAGE_FILE="${TREE}/docs/administration/identity.md" TOCKMOX_P15_SF_PAGE_FILE="${TREE}/docs/administration/site-forge.md" \
      TOCKMOX_P15_POLL=0 TOCKMOX_P15_CYCLE=0 TOCKMOX_P15_PACE=0 TOCKMOX_P15_ALERT_WAIT=0 TOCKMOX_P15_CLEAR_WAIT=0 TOCKMOX_P15_SETTLE_WAIT=0 \
      TOCKMOX_P15_TOKEN_WAIT=0 TOCKMOX_P15_DOWN_WAIT=0 TOCKMOX_P09_STATE="$d/p09" "$@" bash "$f" > "$d/out" 2>&1
  local rc=$?
  printf '%s|%s' "$rc" "$(cut -d' ' -f1 "$d/r/P15-approver-revocation" 2>/dev/null)"
}
failed_rows() { awk -F'\t' '$3 != $4 {print $2}' "$1/p09/p15/verdicts.tsv" 2>/dev/null; }
st_get() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1/state.json" "$2"; }

d="$(sandbox)"; r="$(run_p15 "$P15" "$d")"
is "path: green end to end against an honest product: exit 0 and a PASS receipt" "0|PASS" "$r"
[ -z "$(failed_rows "$d")" ] && [ "$(grep -c 'row [1234]:' "$d/p09/p15/verdicts.tsv" 2>/dev/null)" = 8 ] \
  && ok "path: the four rows were recorded ($(grep -c . "$d/p09/p15/verdicts.tsv") verdicts), and none is red" || bad "path: rows" "$(failed_rows "$d" | head -3 | tr '\n' ';'); $(tail -5 "$d/out" | tr '\n' ';' | cut -c1-300)"
is "path: it leaves nothing planted: no Authentik user, no forge account, the pull request closed and unmerged, no branch, the token back" \
  "False False closed False False True" \
  "$(st_get "$d" '" ".join(map(str, ["p15-approver" in s["ak"], "p15-approver" in s["forge_users"], s["prs"]["7"]["state"], s["prs"]["7"]["merged"], "p15-approval-probe" in s["branches"], s["watch_tok"] == s["id_tok"]]))')"
[ ! -s "$d/p09/p15/planted.list" ] && ok "path: the planted list is empty at the end" || bad "path: planted list" "$(cat "$d/p09/p15/planted.list")"
[ -s "$d/calls.log" ] && ! grep -v -E -- '--context(=| )stub-ctx' "$d/calls.log" >/dev/null && ok "path: every kubectl call names its cluster ($(grep -c . "$d/calls.log") calls, the page's own included)" || bad "path: every call names its cluster" "$(grep -v -- 'stub-ctx' "$d/calls.log" | head -2)"
grep -q -- '-X DELETE http://127.0.0.1:3000/api/v1/orgs/tockmox/members/p15-approver' "$d/curl.log" && ok "path: the page's block ran, with the person's name in its placeholder, on the page's own port" || bad "path: the page block ran" ""
! grep -F 'good-token' "$d/out" "$d/p09/p15/"* >/dev/null 2>&1 && ! grep -F "$(printf good-token | base64)" "$d/out" "$d/p09/p15/"* >/dev/null 2>&1 \
  && ok "path: the watcher's real token is in no log and no state file" || bad "path: token leaked" "$(grep -lF good-token "$d/out" "$d/p09/p15/"* 2>/dev/null | head -2)"
! grep -F 'stubpass' "$d/out" "$d/p09/p15/"* "$d/curl.log" >/dev/null 2>&1 && ok "path: the forge admin's password is on no command line, in no log and no state file" || bad "path: admin password leaked" ""
grep -q 'DOES NOT PROVE' "$d/out" && grep -q 'SUCCESS CONDITIONS STATED' "$d/out" && ok "path: the log says what the run does not prove, and what success conditions the pages state" || bad "path: caveats in the log" ""

# one broken product per row: the path must fail, and at that row
broken() { # MODE LABEL ROW-TEXT [VAR=VALUE]
  local d r; d="$(sandbox)"; r="$(run_p15 "$P15" "$d" SB_MODE="$1" ${4:+"$4"})"
  if [ "$r" = "1|PRODUCT_FAIL" ] && failed_rows "$d" | grep -F -- "$3" >/dev/null; then ok "$2"
  else bad "$2" "rc|receipt=[${r}] red rows: $(failed_rows "$d" | cut -c1-80 | tr '\n' ';')"; fi
  [ "$(st_get "$d" '"p15-approver" in s["ak"] or "p15-approver" in s["forge_users"] or s["watch_tok"] != s["id_tok"]')" = False ] \
    || bad "$2: and still takes everything out" "planted things are left"
}
broken never-alerts "red: a product whose alert never fires for a removed approver fails row 1" "row 1: TockmoxForgeApproverOutsideGroup fires"
broken no-pr-in-description "red: an alert that does not name the pull request fails row 1's description" "row 1: its description names"
broken ignores-deactivation "red: a watcher that reads a deactivated admin as an admin fails row 2" "row 2:"
broken judges-on-bad-read "red: a watcher that still names people on a failed read fails row 3" "row 3: the watcher's own check is not clean"
broken reads-through-bad-token "red: a product that never fails the read (the planted fault did not take) fails row 3" "row 3:"
broken checkdown-never "red: a CheckDown that never fires fails row 3" "row 3: TockmoxForgeApproversCheckDown fires"
broken removal-ignored "red: an organisation removal that leaves them in the team fails row 4" "row 4: TockmoxForgeApproverOutsideGroup stops"
broken slow-alert "red: an alert that fires later than the deadline fails the two-minute row" "row 1: TockmoxForgeApproverOutsideGroup fires" TOCKMOX_P15_DEADLINE=1

# mutated copies of the path, each of which must not end PASS against the honest product
mutated() { # LABEL OLD NEW
  local d r f; f="$(mktemp "${GT}/paths/m.XXXXXX")"
  mut "$P15" "$f" "$2" "$3" 2>/dev/null || { bad "$1" "the edit changed nothing"; return; }
  d="$(sandbox)"; r="$(run_p15 "$f" "$d")"
  [ "$r" != "0|PASS" ] && ok "mutation: ${1}: not a PASS (${r})" || bad "mutation: ${1}" "the mutated copy still ended 0|PASS"
}
mutated "a path that never takes the person out of the group cannot show row 1" 'v="$(ak_state remove)"; execute_end 0' 'v="active, not member"; execute_end 0'
mutated "a path that never deactivates cannot show row 2" 'v="$(ak_state deactivate)"' 'v="inactive, member"'
mutated "a path that never plants the bad token cannot show row 3" 'token_set "$(printf '"'"'%s'"'"' "$BAD_TOKEN" | base64 | tr -d '"'"'\n'"'"')"' ':'
mutated "a path that never runs the page's block cannot show row 4" 'bash "${STATE}/block.run.sh" > "${STATE}/${S}.out" 2>&1' 'echo 204 > "${STATE}/${S}.out"'
mutated "a path that leaves the page's placeholder in the block cannot show row 4" '-e "s|<their-forge-name>|${PERSON}|g"' '-e "s|<their-forge-name>|nobody|g"'
mutated "a path that plants no approval cannot name the pull request" '"$PERSON")"
    record "$S" "GLUE: the forge made' '"")"
    record "$S" "GLUE: the forge made'
mutated "a path that does not put the token back cannot read the check clean again" '    token_restore
    record "$S" "GLUE: the watcher' '    record "$S" "GLUE: the watcher'
# a mutated copy that drops the trap leaves the product planted when it dies in the middle: the trap is what takes it out
f="$(mktemp "${GT}/paths/m.XXXXXX")"; mut "$P15" "$f" 'S=S03-remove' 'exit 9; S=S03-remove'
d="$(sandbox)"; run_p15 "$f" "$d" >/dev/null
[ "$(st_get "$d" '"p15-approver" in s["ak"] or "p15-approver" in s["forge_users"]')" = False ] && ok "path: one that dies after the plant still takes it out (the EXIT trap)" || bad "path: trap revert" "left planted"
f2="$(mktemp "${GT}/paths/m.XXXXXX")"; mut "$f" "$f2" 'trap revert_all EXIT' ':'
d="$(sandbox)"; run_p15 "$f2" "$d" >/dev/null
[ "$(st_get "$d" '"p15-approver" in s["ak"]')" = True ] && ok "mutation: without the EXIT trap the same death leaves the person planted, so the case above is the guard" || bad "mutation: trap" "nothing left planted without the trap"

# ------------------------------------------------------------------ 4. the gate
cat > "${TMP}/gbin-kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "${TMP}/kcalls"
exit 1
STUB
mkdir -p "${TMP}/gbin"; mv "${TMP}/gbin-kubectl" "${TMP}/gbin/kubectl"; chmod +x "${TMP}/gbin/kubectl"
run_gate() { # FILE STATE-DIR [ROUTE] ... prints "rc|receipt|kubectl calls"
  rm -rf "${TMP}/gr" "${TMP}/kcalls"
  env -u TOCKMOX_P09_ROUTE PATH="${TMP}/gbin:${PATH}" OUTCOME_RECEIPT_DIR="${TMP}/gr" TOCKMOX_PATH_NAME=P15-approver-revocation KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD \
      TOCKMOX_P15_BUDGET=0 ${2:+TOCKMOX_P09_STATE="$2"} ${3:+TOCKMOX_P09_ROUTE="$3"} bash "$1" > "${TMP}/gout" 2>&1
  local rc=$?
  printf '%s|%s|%s' "$rc" "$(cut -d' ' -f1 "${TMP}/gr/P15-approver-revocation" 2>/dev/null)" "$(grep -c . "${TMP}/kcalls" 2>/dev/null || echo 0)"
}
gate() { is "gate: ${1}: BLOCKED, exit 0, and no cluster call" "0|BLOCKED|0" "$(run_gate "$P15" "${2:-}" "${3:-}")"; }
gate "no P09 state directory named" ""
gd="${TMP}/gate-p09"; mkdir -p "$gd"
gate "a P09 state directory that never ended PASS (no p09-passed marker)" "$gd" built-in
: > "$gd/p09-passed"
gate "a P09 that passed, with no route named (a plain run.sh)" "$gd"
gate "a P09 that passed on the external route" "$gd" external
grep -q 'Run the built-in route' "${TMP}/gout" && ok "gate: the reason names the route to run instead" || bad "gate: reason" "$(tail -2 "${TMP}/gout")"
is "gate: on the built-in route it goes past the gate (a spent budget stops it before any cluster call, exit 75)" "75||0" "$(run_gate "$P15" "$gd" built-in)"
gm="$(mktemp "${GT}/paths/g.XXXXXX")"
# shellcheck disable=SC1003  # the backslash is the line continuation in the path's text, matched literally
mut "$P15" "$gm" '[ "${TOCKMOX_P09_ROUTE:-}" = built-in ] \' '[ -n "${TOCKMOX_P09_ROUTE:-x}" ] \'
case "$(run_gate "$gm" "$gd" external)" in 0\|BLOCKED\|0) bad "mutation: a gate that does not read the route" "still BLOCKED on the external route" ;; *) ok "mutation: a gate that does not read the route goes past it on the external route, so the case above is the guard" ;; esac
grep -F '[ -f "${P09_STATE}/p09-passed" ]' "$P15" >/dev/null && grep -E '^P15 \| BLOCKED \| nofile:TOCKMOX_P09_STATE/p09-passed \|' "${HERE}/expected-outcomes.txt" >/dev/null \
  && ok "gate: expected-outcomes.txt allows P15 BLOCKED on the marker the path itself blocks on" || bad "gate: the expected-outcomes row" "no P15 row on nofile:TOCKMOX_P09_STATE/p09-passed"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

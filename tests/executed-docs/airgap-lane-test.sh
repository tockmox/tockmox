#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for airgap-lane.sh, the air-gap clause as one run. No hypervisor, no guest, no Loki: the lane runs from
# a copy of this tree's script in a scratch tree whose throwaway-cluster.sh, run.sh, site-repo-server.sh, helm-deps.sh
# and kubectl are stand-ins driven by files, and a stand-in Loki answers on loopback. The counter
# (lib/edge-deny-count.sh) is this tree's own. One PASS or FAIL line per case; exit 1 on any FAIL.
#
# Each case plants one fault and checks the lane goes red the right way, so the lane is shown able to fail:
#   1. a cut proven by the control, P09 PASS and only ignored (udp/123) denies: PASS, exit 0, the VM destroyed
#   2. mirror-tls not PASS: FAIL before P04, and the VM destroyed
#   3. mirror-proof not PASS: FAIL before P04
#   4. the guest resolves no public name: BLOCKED (4), never a zero count
#   5. the cut is never made (the control is answered every time): BLOCKED (4), and P09 never runs
#   6. the control is refused but the edge logs nothing for it, three times: FAIL, and P09 never runs
#   7. P09 fails: FAIL (1), the VM still destroyed
#   8. P09 exits 0 but declared BLOCKED in its receipt: BLOCKED (4), never a pass
#   9. one deny to tcp/443 under the cut: FAIL naming the destination, with P09 PASS
#  10. a deny line the lane cannot read is counted against the clause, not dropped
#  11. Loki does not answer for the cut window: INFRA_ERROR (5), never a zero
#  12. refusals before anything is created: a cache-mode mirror, the pod network, no CA file, a bad ignore entry
#  13. the rig is full (create exits 4): BLOCKED, and nothing to destroy
#  14. a kept run that stops before the cut install is destroyed anyway; a kept run that passes is not
#  15. a step that writes nothing for longer than TOCKMOX_AIRGAP_STALL prints an AIRGAP-STALL line while it hangs
#  16. Loki counts more deny lines than it returns: the lines it did not return count against the clause
#  17. create fails with a named error: FAIL, and the report's summary line and a masked stderr tail name it
#  18. the rig is full (create exits 4): the BLOCKED line in the report carries the capacity gate's own words
#  19. the charts repository is served by the documented path: install/charts-vendored-tag.sh (this tree's own) commits
#      the vendored archives under airgap-<vm>-vendored, site-repo-server.sh push-ref serves that tag with them in it,
#      P09 installs that tag, and TOCKMOX_SERVE_FORCE_ADD is never set; with an archive missing the lane FAILs before
#      the cut, naming it, and P09 never runs
#
# What it does not show: that the edge logs, that the segment has no other way out, or that P09 passes from the
# mirror. The lab run is that proof.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/airgap-lane-test.XXXXXX")"
trap 'kill "${SPID:-0}" 2>/dev/null; rm -rf "$W"' EXIT
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS+1)); }

T="$W/tree"; C="$W/ctl"; B="$W/bin"
mkdir -p "$T/tests/executed-docs/lib" "$T/tests/executed-docs/provision" "$T/tools" "$T/install" "$C" "$B"
cp "${HERE}/airgap-lane.sh" "$T/tests/executed-docs/"
cp "${HERE}/../../install/charts-vendored-tag.sh" "$T/install/"
# A charts tree shaped like this one: one layer with one locked upstream dependency, ignored the way .gitignore does.
mkdir -p "$T/charts/tockmox-platform"
printf 'charts/*/charts/\n*.tgz\n' > "$T/.gitignore"
printf 'apiVersion: v2\nname: tockmox-platform\nversion: 9.9.9\ndependencies:\n  - name: upstream\n    version: 1.2.3\n    repository: "https://charts.example.invalid"\n' \
  > "$T/charts/tockmox-platform/Chart.yaml"
printf 'dependencies:\n- name: upstream\n  repository: https://charts.example.invalid\n  version: 1.2.3\ndigest: sha256:0\n' \
  > "$T/charts/tockmox-platform/Chart.lock"
cp "${HERE}/lib/edge-deny-count.sh" "$T/tests/executed-docs/lib/"
cp "${HERE}/lib/stderr-tail.py" "$T/tests/executed-docs/lib/"

# ---- the stand-ins ------------------------------------------------------------------------------------------------
# pop FILE: the first line of a queue file, the last line repeated once the queue is down to one
cat > "$B/pop" <<'SH'
#!/usr/bin/env bash
f="$1"; [ -s "$f" ] || { echo ""; exit 0; }
head -1 "$f"; [ "$(wc -l < "$f")" -le 1 ] || { tail -n +2 "$f" > "$f.next" && mv "$f.next" "$f"; }
SH
cat > "$T/tests/executed-docs/provision/throwaway-cluster.sh" <<'SH'
#!/usr/bin/env bash
C="${AGT_CTL:?}"; echo "tc $*" >> "$C/calls"
case "$1" in
  create)
    [ ! -s "$C/create_err" ] || cat "$C/create_err" >&2
    rc="$(cat "$C/create_rc" 2>/dev/null || echo 0)"; [ "$rc" = 0 ] || { echo "virtualmachine.kubevirt.io/ed-1-1 created"; exit "$rc"; }
    mkdir -p "$TOCKMOX_WORKDIR"; kc="$TOCKMOX_WORKDIR/${TOCKMOX_TEST_VM}.kubeconfig"; echo "fake" > "$kc"
    echo "creating"; echo "$kc" ;;
  exec)
    shift
    case "$*" in
      *getent*) case "$(cat "$C/dns")" in resolved) echo AIRGAP-DNS-RESOLVED ;; none) echo AIRGAP-DNS-NONE ;; *) exit 255 ;; esac ;;
      *curl*) case "$(pop "$C/control")" in reached) echo AIRGAP-CONTROL-REACHED ;; refused) echo AIRGAP-CONTROL-REFUSED ;; *) exit 255 ;; esac ;;
      *) echo quiet ;;
    esac ;;
  mirror-tls) echo "mirror-tls: $(cat "$C/tls")" ;;
  mirror-proof) echo "mirror-proof: $(cat "$C/proof")" ;;
  destroy) echo destroyed ;;
  *) exit 2 ;;
esac
SH
cat > "$T/tests/executed-docs/run.sh" <<'SH'
#!/usr/bin/env bash
C="${AGT_CTL:?}"; echo "run $*" >> "$C/calls"
case "$1" in
  P04) sleep "$(cat "$C/p0405_sleep" 2>/dev/null || echo 0)"; exit "$(cat "$C/p0405_rc" 2>/dev/null || echo 0)" ;;
  P09)
    d="$TOCKMOX_WORKDIR/receipts-$(date -u +%Y%m%dT%H%M%S%N)"; mkdir -p "$d"
    printf '%s fake reason\n' "$(cat "$C/p09_outcome")" > "$d/P09-install-md-end-to-end"
    echo "p09 revision ${TOCKMOX_P09_TOCKMOX_REVISION:-none}" >> "$C/calls"
    exit "$(cat "$C/p09_rc")" ;;
esac
SH
cat > "$T/tests/executed-docs/provision/site-repo-server.sh" <<'SH'
#!/usr/bin/env bash
echo "srs $* force=${TOCKMOX_SERVE_FORCE_ADD:-unset}" >> "${AGT_CTL:?}/calls"
case "$1" in
  url) echo "git://192.0.2.9/tockmox.git" ;;
  # What the served tag carries, read from the repository it is served from, as push-ref serves it: as committed.
  push-ref) echo "served-archives $(git -C "$2" ls-tree -r --name-only "refs/tags/$4" | grep -c '/charts/.*\.tgz$')" >> "$AGT_CTL/calls" ;;
esac
SH
cat > "$T/tools/helm-deps.sh" <<'SH'
#!/usr/bin/env bash
echo "helm-deps" >> "${AGT_CTL:?}/calls"
rm -rf charts/tockmox-platform/charts
[ -e "$AGT_CTL/no_archive" ] || { mkdir -p charts/tockmox-platform/charts && printf 'archive' > charts/tockmox-platform/charts/upstream-1.2.3.tgz; }
SH
cat > "$B/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *current-context*) echo fake-guest ;;
  *"get nodes"*) echo 192.0.2.60 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$B/pop" "$B/kubectl" "$T/tests/executed-docs/provision/"*.sh "$T/tests/executed-docs/run.sh" "$T/tools/helm-deps.sh"

# The stand-in Loki: /query pops the next count from ctl/counts ("down" means no answer), /query_range serves ctl/lines.
cat > "$W/loki.py" <<'PY'
import http.server, json, os, subprocess, sys, urllib.parse
C = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path.endswith("/query_range"):
            lines = [l.rstrip("\n") for l in open(f"{C}/lines")] if os.path.exists(f"{C}/lines") else []
            body = {"status": "success", "data": {"resultType": "streams",
                    "result": [{"stream": {}, "values": [[str(i), l] for i, l in enumerate(lines)]}]}}
        else:
            v = subprocess.run([f"{C}/../bin/pop", f"{C}/counts"], capture_output=True, text=True).stdout.strip()
            if v == "down":
                self.send_response(502); self.end_headers(); return
            body = {"status": "success", "data": {"resultType": "vector", "result": [{"metric": {}, "value": [1, v or "0"]}]}}
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(f"{C}/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$W/loki.py" "$C" & SPID=$!
for _ in $(seq 1 50); do [ -s "$C/port" ] && break; sleep 0.1; done
PORT="$(cat "$C/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "FAIL the stand-in Loki did not start"; exit 1; }
echo "-----BEGIN CERTIFICATE-----" > "$W/ca.crt"

NTP='76,,,rule-cut,vtnet2,match,block,in,4,0x10,,64,5579,0,DF,17,udp,76,192.0.2.60,203.0.113.7,58168,123,56'
WEB='60,,,rule-cut,vtnet2,match,block,in,4,0x0,,64,1,0,DF,6,tcp,60,192.0.2.60,198.51.100.4,40000,443,0,S,1,,64240,,mss'

# set_case KEY=VALUE...: a fresh control directory with the happy path's values, then the case's own
set_case() {
  rm -f "$C/calls" "$C/lines" "$C/p0405_sleep" "$C/create_err" "$C/no_archive"
  echo resolved > "$C/dns"; echo PASS > "$C/tls"; echo PASS > "$C/proof"; echo 0 > "$C/create_rc"; echo 0 > "$C/p0405_rc"
  printf 'reached\nrefused\n' > "$C/control"; printf '1\n2\n' > "$C/counts"; printf '%s\n%s\n' "$NTP" "$NTP" > "$C/lines"
  echo PASS > "$C/p09_outcome"; echo 0 > "$C/p09_rc"
  while [ $# -gt 0 ]; do printf '%b' "${1#*=}" > "$C/${1%%=*}"; shift; done
}
lane() {
  rm -rf "$W/work"
  set +e
  OUT="$(env -i PATH="$B:$PATH" HOME="$W" TMPDIR="$W" AGT_CTL="$C" TOCKMOX_WORKDIR="$W/work" \
    TOCKMOX_DOCS_REF=0123456789abcdef0123456789abcdef01234567 TOCKMOX_SUBSTRATE_CONTEXT=fake TOCKMOX_TEST_VM=ed-1-1 \
    TOCKMOX_REGISTRY_MIRROR=mirror.example/closed TOCKMOX_REGISTRY_CA="$W/ca.crt" \
    TOCKMOX_VM_NETWORK=default/no-route TOCKMOX_VM_GUEST_ADDRESS=192.0.2.60/24 TOCKMOX_VM_ADDRESS=198.51.100.213 \
    TOCKMOX_EDGE_LOKI_URL="http://127.0.0.1:${PORT}" TOCKMOX_EDGE_LOKI_SELECTOR='{job="syslog"}' TOCKMOX_EDGE_DENY_MATCH=rule-cut \
    TOCKMOX_AIRGAP_CUT_HINT="flip the cut rule" TOCKMOX_AIRGAP_POLL=1 TOCKMOX_AIRGAP_SETTLE=1 TOCKMOX_AIRGAP_CUT_WAIT=4 \
    "$@" bash "$T/tests/executed-docs/airgap-lane.sh" 2>&1)"
  RC=$?
  set -e 2>/dev/null; set +e
}
called() { grep -q "$1" "$C/calls" 2>/dev/null; }
has() { grep -q -- "$1" <<<"$OUT"; }

set_case; lane
if [ "$RC" = 0 ] && has 'AIRGAP-RESULT PASS' && has 'AIRGAP-CUT proven' && has 'AIRGAP-DENY udp 203.0.113.7:123 2 ignored' \
   && called 'tc destroy' && called 'run P09'; then pass "1: cut proven, P09 PASS, only udp/123 denies: PASS and destroyed"
else fail "1: rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' '|')"; fi

set_case tls=FAIL; lane
if [ "$RC" = 1 ] && has 'mirror-tls did not pass' && ! called 'run P04' && called 'tc destroy'; then pass "2: mirror-tls red stops before P04, VM destroyed"
else fail "2: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi

set_case proof=FAIL; lane
if [ "$RC" = 1 ] && has 'mirror-proof did not pass' && ! called 'run P04'; then pass "3: mirror-proof red stops before P04"
else fail "3: rc=$RC"; fi

set_case dns=none; lane
if [ "$RC" = 4 ] && has 'AIRGAP-RESULT BLOCKED' && has 'resolves no public name' && called 'tc destroy'; then pass "4: no public name resolves: BLOCKED"
else fail "4: rc=$RC"; fi

set_case control='reached\n'; lane
if [ "$RC" = 4 ] && has 'the cut was not made' && ! called 'run P09' && has 'AIRGAP-PAUSE'; then pass "5: the cut never made: BLOCKED, P09 never runs"
else fail "5: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi

set_case control='refused\n' counts='0\n'; lane TOCKMOX_AIRGAP_CUT_WAIT=60
if [ "$RC" = 1 ] && has 'the counter cannot count' && ! called 'run P09'; then pass "6: refused with no deny line, three times: FAIL, P09 never runs"
else fail "6: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi

set_case p09_outcome=FAIL p09_rc=1; lane
if [ "$RC" = 1 ] && has 'P09 did not pass under the cut' && called 'tc destroy'; then pass "7: P09 fails: FAIL, destroyed"
else fail "7: rc=$RC"; fi

set_case p09_outcome=BLOCKED p09_rc=0; lane
if [ "$RC" = 4 ] && has 'P09 declared BLOCKED'; then pass "8: P09 exit 0 with a BLOCKED receipt: BLOCKED, not a pass"
else fail "8: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi

set_case counts='1\n3\n' lines="${NTP}\n${NTP}\n${WEB}\n"; lane
if [ "$RC" = 1 ] && has 'AIRGAP-DENY tcp 198.51.100.4:443 1' && has 'reached past the edge'; then pass "9: a tcp/443 deny under the cut: FAIL naming 198.51.100.4:443"
else fail "9: rc=$RC $(printf '%s' "$OUT" | tail -5 | tr '\n' '|')"; fi

set_case counts='1\n1\n' lines='garbage line with no guest\n'; lane
if [ "$RC" = 1 ] && has 'AIRGAP-DENY ? unparsed 1'; then pass "10: an unreadable deny line counts against the clause"
else fail "10: rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' '|')"; fi

set_case counts='1\ndown\n'; lane
if [ "$RC" = 5 ] && has 'AIRGAP-RESULT INFRA_ERROR'; then pass "11: Loki silent for the cut window: INFRA_ERROR, not a zero"
else fail "11: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi

ok=1
set_case; lane TOCKMOX_REGISTRY_MODE=cache; { [ "$RC" = 2 ] && ! called 'tc create'; } || ok=0
set_case; lane TOCKMOX_VM_NETWORK=pod; { [ "$RC" = 2 ] && ! called 'tc create'; } || ok=0
set_case; lane TOCKMOX_REGISTRY_CA="$W/missing.crt"; { [ "$RC" = 2 ] && ! called 'tc create'; } || ok=0
set_case; lane TOCKMOX_AIRGAP_IGNORE="ntp"; { [ "$RC" = 2 ] && ! called 'tc create'; } || ok=0
if [ "$ok" = 1 ]; then pass "12: cache mode, the pod network, no CA and a bad ignore entry are refused before create"
else fail "12: a refusal let the lane reach create (last rc=$RC)"; fi

set_case create_rc=4; lane
if [ "$RC" = 4 ] && ! called 'tc destroy'; then pass "13: the rig is full: BLOCKED with nothing to destroy"
else fail "13: rc=$RC"; fi

set_case dns=none; lane TOCKMOX_KEEP_CLUSTER=1
k1=0; [ "$RC" = 4 ] && called 'tc destroy' && k1=1
set_case; lane TOCKMOX_KEEP_CLUSTER=1
k2=0; [ "$RC" = 0 ] && ! called 'tc destroy' && k2=1
if [ "$k1" = 1 ] && [ "$k2" = 1 ]; then pass "14: a kept run stopped before the cut is destroyed; a kept pass is not"
else fail "14: kept-stopped=$k1 kept-pass=$k2"; fi

set_case counts='1\n3\n' lines="${NTP}\n"; lane
if [ "$RC" = 1 ] && has 'AIRGAP-DENY ? unread 2'; then pass "16: denies counted but not returned count against the clause"
else fail "16: rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' '|')"; fi

report() { cat "$W/work"/report-airgap-lane-*.txt 2>/dev/null; }
QUOTA='Error from server (Forbidden): pods "virt-launcher-ed-1-1" is forbidden: exceeded quota: harness-quota'
set_case create_rc=1 create_err="waiting for ed-1-1\\nauth: bearer s3cr3t-stub-value\\n${QUOTA}\\n"; lane
if [ "$RC" = 1 ] && report | grep -F "airgap lane: provisioning failed (create exit 1): ${QUOTA}" >/dev/null \
   && report | grep -F "  | ${QUOTA}" >/dev/null && ! report | grep -F 's3cr3t' >/dev/null \
   && ! report | grep -F 'virtualmachine.kubevirt.io' >/dev/null && called 'tc destroy'; then
  pass "17: create fails with a named error: FAIL, the report names it in the summary and a masked tail, destroyed"
else fail "17: rc=$RC $(report | tr '\n' '|')"; fi

set_case create_rc=4 create_err='  capacity BLOCKED: memory: the VM needs 24.5 GiB, the node has 9.9 GiB free\n'; lane
if [ "$RC" = 4 ] && report | grep -F 'BLOCKED: create refused: the rig is full (its capacity gate): capacity BLOCKED: memory: the VM needs 24.5 GiB' >/dev/null \
   && ! called 'tc destroy'; then pass "18: the rig is full: the BLOCKED line carries the capacity gate's own words"
else fail "18: rc=$RC $(report | tr '\n' '|')"; fi

set_case p0405_sleep=6; lane TOCKMOX_AIRGAP_STALL=2
if [ "$RC" = 0 ] && has "AIRGAP-STALL .* in step '6 P04 and P05'"; then pass "15: a quiet step raises AIRGAP-STALL while it hangs"
else fail "15: rc=$RC, no stall line"; fi

set_case; lane
if [ "$RC" = 0 ] && called 'srs push-ref .*/charts-checkout tockmox airgap-ed-1-1-vendored force=unset' && called 'served-archives 1' \
   && called 'p09 revision airgap-ed-1-1-vendored' && ! grep -q 'force=charts' "$C/calls" && ! called 'srs push '; then
  pass "19: the served tag is airgap-ed-1-1-vendored with the archive committed, P09 installs it, no TOCKMOX_SERVE_FORCE_ADD"
else fail "19: rc=$RC $(tr '\n' '|' < "$C/calls")"; fi
set_case no_archive=1; lane
if [ "$RC" = 1 ] && has 'install/charts-vendored-tag.sh refused' && has 'charts/tockmox-platform/charts/upstream-1.2.3.tgz' \
   && ! has 'AIRGAP-PAUSE' && ! called 'run P09' && ! called 'srs push-ref' && called 'tc destroy'; then
  pass "19: an archive missing FAILs before the cut, naming it; nothing is served and P09 never runs"
else fail "19: missing archive: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi

[ "$FAILS" = 0 ] || exit 1

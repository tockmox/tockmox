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
#  20. the guest cluster's own pod and Service ranges, learned at run time: from its k3s config where it names them,
#      else from the live cluster (the nodes' podCIDRs; the ServiceCIDR object, else the range the API server names
#      when a server-side dry run asks for an address outside it). Denies to them are reported as guest-cluster and
#      do not fail the clause; a deny outside them still does; a range wider than /12 FAILs before P04; ranges that
#      cannot be learned FAIL closed before P04, never an exemption; a guest that does not answer the read is
#      INFRA_ERROR before the cut
#  21. the Service-creation race probe observes and never changes the outcome: it records the backend that holds nat
#      KUBE-SERVICES and the route into the learned Service range, its sampler reads nft or iptables and
#      /proc/net/nf_conntrack or conntrack -L and is stopped at the end of step 9, and AIRGAP-RACE says confirmed only
#      when each deny to the Service range falls after its Service's create, before its ClusterIP's first-seen, with
#      an un-NATed flow
#  22. P09 hangs past TOCKMOX_AIRGAP_P09_WALL: the whole of P09 is stopped at the bound (its process gone, not orphaned),
#      AIRGAP-P09-BOUND names it, and the lane still counts the cut window (the AIRGAP-DENY table), destroys the VM and
#      ends INFRA_ERROR, in seconds rather than at P09's own pace
#  23. the lane is stopped from outside (SIGTERM, as when its Workflow is stopped) while P09 runs: P09 is stopped with it,
#      and the AIRGAP-DENY table for the window it had is still printed before the safe end, INFRA_ERROR naming the stop
#  24. a step that stays quiet raises AIRGAP-STALL again every TOCKMOX_AIRGAP_STALL seconds, not once
#  25. a TOCKMOX_AIRGAP_P09_WALL outside 2 to 14400 is refused before anything is created
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
      *k3s/config.yaml*) [ ! -e "$C/k3s_silent" ] || exit 255; cat "$C/k3s_config" 2>/dev/null; echo AIRGAP-K3S-CONFIG-END ;;
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
    # a hang (ctl/p09_sleep), and with ctl/p09_term a stop from outside: TERM to the lane, this script's grandparent
    if [ -s "$C/p09_sleep" ]; then
      sleep "$(cat "$C/p09_sleep")" & echo $! > "$C/p09_sleep_pid"
      [ ! -e "$C/p09_term" ] || kill -TERM "$(ps -o ppid= -p "$PPID" | tr -d ' ')"
      wait
    fi
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
  *podCIDRs*) cat "${AGT_CTL:?}/k_pod" 2>/dev/null ;;
  *servicecidrs*) [ -s "${AGT_CTL:?}/k_svc" ] || { echo 'error: the server doesn'"'"'t have a resource type "servicecidrs"' >&2; exit 1; }
    cat "$AGT_CTL/k_svc" ;;
  *dry-run=server*) [ ! -s "${AGT_CTL:?}/k_probe" ] || { cat "$AGT_CTL/k_probe" >&2; exit 1; }
    echo service/airgap-lane-range-probe created ;;
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
  rm -f "$C/calls" "$C/lines" "$C/p0405_sleep" "$C/create_err" "$C/p09_sleep" "$C/p09_term" "$C/p09_sleep_pid" "$C/no_archive" "$C/k3s_config" "$C/k3s_silent" "$C/k_probe"
  echo 198.18.0.0/24 > "$C/k_pod"; echo 198.19.0.0/16 > "$C/k_svc"
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

# 22 to 25: P09's hard bound, a stop from outside, a repeating stall line, and the bound's refusal
gone() { local p; p="$(cat "$C/p09_sleep_pid" 2>/dev/null)"; [ -n "$p" ] && case "$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')" in ''|Z*) true ;; *) false ;; esac; }
set_case p09_sleep=40; s0="$(date +%s)"; lane TOCKMOX_AIRGAP_P09_WALL=3; s1="$(date +%s)"
if [ "$RC" = 5 ] && has 'AIRGAP-P09-BOUND P09 ran past its bound of 3s' && has 'AIRGAP-DENY udp 203.0.113.7:123 2 ignored' \
   && has 'did not finish within its bound of 3s' && has 'AIRGAP-RESULT INFRA_ERROR' && called 'tc destroy' \
   && [ $((s1 - s0)) -lt 30 ] && gone; then
  pass "22: P09 hung past its bound: stopped there, the cut window still counted, the VM destroyed, INFRA_ERROR"
else fail "22: rc=$RC $((s1 - s0))s gone=$(gone && echo yes || echo no) $(printf '%s' "$OUT" | tail -5 | tr '\n' '|')"; kill "$(cat "$C/p09_sleep_pid" 2>/dev/null)" 2>/dev/null; fi

set_case p09_sleep=40 p09_term=1; s0="$(date +%s)"; lane; s1="$(date +%s)"
if [ "$RC" = 5 ] && has 'stopped from outside (SIGTERM)' && has 'the run ended early (INFRA_ERROR)' \
   && has 'AIRGAP-DENY udp 203.0.113.7:123 2 ignored' && has 'AIRGAP-RESULT INFRA_ERROR' && called 'tc destroy' \
   && [ $((s1 - s0)) -lt 30 ] && gone; then
  pass "23: stopped from outside while P09 runs: P09 stopped with it, the deny table printed, the VM destroyed, INFRA_ERROR"
else fail "23: rc=$RC $((s1 - s0))s gone=$(gone && echo yes || echo no) $(printf '%s' "$OUT" | tail -5 | tr '\n' '|')"; kill "$(cat "$C/p09_sleep_pid" 2>/dev/null)" 2>/dev/null; fi

set_case p0405_sleep=7; lane TOCKMOX_AIRGAP_STALL=2
if [ "$RC" = 0 ] && [ "$(grep -c "AIRGAP-STALL .* in step '6 P04 and P05'" <<<"$OUT")" -ge 2 ]; then
  pass "24: a step that stays quiet raises AIRGAP-STALL again, not once"
else fail "24: rc=$RC, $(grep -c 'AIRGAP-STALL' <<<"$OUT") stall line(s)"; fi

ok=1
set_case; lane TOCKMOX_AIRGAP_P09_WALL=1; { [ "$RC" = 2 ] && has 'TOCKMOX_AIRGAP_P09_WALL must be' && ! called 'tc create'; } || ok=0
set_case; lane TOCKMOX_AIRGAP_P09_WALL=14401; { [ "$RC" = 2 ] && ! called 'tc create'; } || ok=0
if [ "$ok" = 1 ]; then pass "25: a P09 bound outside 2 to 14400 is refused before create"
else fail "25: a bad TOCKMOX_AIRGAP_P09_WALL reached create (last rc=$RC)"; fi

# 20. the guest cluster's own pod and Service ranges, learned at run time (documentation and benchmark ranges here)
deny_to() { printf '60,,,rule-cut,vtnet2,match,block,in,4,0x0,,63,1,0,DF,6,tcp,60,192.0.2.60,%s,40000,%s,0,S,1,,64240,,mss' "$1" "$2"; }
SVC="$(deny_to 198.19.209.85 9090)"; POD="$(deny_to 198.18.0.15 8080)"; NEAR="$(deny_to 198.18.1.1 443)"
PINNED="$(deny_to 203.0.113.140 4000)"
set_case counts='1\n4\n' lines="${NTP}\n${SVC}\n${SVC}\n${POD}\n"; lane
if [ "$RC" = 0 ] && has 'AIRGAP-RESULT PASS' && has 'AIRGAP-DENY tcp 198.19.209.85:9090 2 guest-cluster' \
   && has 'AIRGAP-DENY tcp 198.18.0.15:8080 1 guest-cluster' && has 'airgap lane 10: 0 deny line(s) count against the clause' \
   && has "pod 198.18.0.0/24 (the nodes' podCIDRs), service 198.19.0.0/16 (the ServiceCIDR object)"; then
  pass "20: denies to the live cluster's own pod and Service ranges are reported as guest-cluster and pass"
else fail "20: own ranges: rc=$RC $(printf '%s' "$OUT" | tail -6 | tr '\n' '|')"; fi
set_case counts='1\n3\n' lines="${SVC}\n${POD}\n${NEAR}\n"; lane
if [ "$RC" = 1 ] && has 'AIRGAP-DENY tcp 198.18.1.1:443 1' && ! has '198.18.1.1:443 1 guest-cluster' \
   && has 'reached past the edge under the cut: 1 deny line(s)'; then
  pass "20: a deny just past the node's pod range (198.18.1.1) still FAILs the clause"
else fail "20: just outside: rc=$RC $(printf '%s' "$OUT" | tail -6 | tr '\n' '|')"; fi
set_case counts='1\n2\n' lines="${SVC}\n${PINNED}\n" \
  k3s_config='write-kubeconfig-mode: "0600"\ncluster-cidr: "203.0.113.0/25"\nservice-cidr: 203.0.113.128/25\n'; lane
if [ "$RC" = 1 ] && has 'AIRGAP-DENY tcp 203.0.113.140:4000 1 guest-cluster' && has 'AIRGAP-DENY tcp 198.19.209.85:9090 1' \
   && ! has '198.19.209.85:9090 1 guest-cluster' && has 'pod 203.0.113.0/25 (the k3s config), service 203.0.113.128/25 (the k3s config)'; then
  pass "20: ranges the guest's k3s config names are used, not the live ones: 203.0.113.140 passes, 198.19 now FAILs"
else fail "20: pinned ranges: rc=$RC $(printf '%s' "$OUT" | tail -6 | tr '\n' '|')"; fi
set_case k_svc='' k_probe='The Service "airgap-lane-range-probe" is invalid: spec.clusterIPs: Invalid value: ["192.0.2.1"]: failed to allocate IP 192.0.2.1: the provided IP (192.0.2.1) is not in the valid range. The range of valid IPs is 198.19.0.0/16\n' \
  counts='1\n1\n' lines="${SVC}\n"; lane
if [ "$RC" = 0 ] && has 'AIRGAP-DENY tcp 198.19.209.85:9090 1 guest-cluster' && has 'service 198.19.0.0/16 (the API server'; then
  pass "20: with no ServiceCIDR object, the range the API server names for a dry-run Service is used"
else fail "20: dry-run probe: rc=$RC $(printf '%s' "$OUT" | tail -6 | tr '\n' '|')"; fi
set_case k3s_config='cluster-cidr: 0.0.0.0/0\n'; lane
if [ "$RC" = 1 ] && has 'wider than /12' && ! called 'run P04' && called 'tc destroy'; then
  pass "20: a guest range wider than /12 FAILs before P04, never a clause that ignores everything"
else fail "20: wide range: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi
set_case k_pod=''; lane
r1=0; [ "$RC" = 1 ] && has 'could not be learned' && has 'pod range' && ! called 'run P04' && r1=1
set_case k_svc='' k_probe='Error from server (Forbidden): services is forbidden\n'; lane
r2=0; [ "$RC" = 1 ] && has 'could not be learned' && has 'service range' && ! called 'run P04' && r2=1
if [ "$r1" = 1 ] && [ "$r2" = 1 ]; then pass "20: a pod or Service range that cannot be learned FAILs closed before P04, nothing exempted"
else fail "20: unlearnable: pod=$r1 service=$r2 $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi
set_case k3s_silent=1; lane
if [ "$RC" = 5 ] && has 'AIRGAP-RESULT INFRA_ERROR' && ! called 'run P09' && ! has 'AIRGAP-PAUSE'; then
  pass "20: the guest does not answer the k3s config read: INFRA_ERROR before the cut"
else fail "20: silent config: rc=$RC $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi

# 21. the Service-creation race probe, which observes and never changes the outcome. Here the guest's side
#     runs on this host: the lane's own probe and sampler scripts, against stand-in iptables, nft, ip, conntrack and
#     date in $W/guest, with /proc/net/nf_conntrack and k3s's bundled aux directory pointed at fixtures. The stand-in
#     Loki stamps the i-th deny line i ns after the epoch, so these Services are created at the epoch and the sampler's
#     clock (ctl/race_clock: its start, each tick, then a time past its deadline, so it ends by itself) starts there.
G="$W/guest"; mkdir -p "$G/aux"
cp "$T/tests/executed-docs/provision/throwaway-cluster.sh" "$C/tc.orig"; cp "$B/kubectl" "$C/kubectl.orig"
cat > "$T/tests/executed-docs/provision/throwaway-cluster.sh" <<'SH'
#!/usr/bin/env bash
# The race probe's guest scripts run here when ctl/race_guest exists; everything else goes to the original stand-in.
C="${AGT_CTL:?}"; G="$C/../guest"
if [ "${1:-}" = exec ] && [ -e "$C/race_guest" ]; then
  case "${2:-}" in
    *AIRGAP-RACE-SAMPLER*|*AIRGAP-RACE-BACKEND*)
      echo "tc $*" >> "$C/calls"
      [ ! -e "$C/race_fail" ] || exit 255
      case "$2" in *AIRGAP-RACE-SAMPLER*)
        if [ -e "$C/sampler_hang" ]; then echo $$ > "$C/sampler_pid"; echo "AIRGAP-RACE-SAMPLER conntrack=proc kube-services=none ranges=x every 0.5 s"; exec sleep 30; fi
        export AGT_SAMPLER=1 ;;
      esac
      sed -e "s#/proc/net/nf_conntrack#${C}/nf_conntrack#g" -e "s#/var/lib/rancher/k3s/data/current/bin/aux#${G}/aux#g" <<<"$2" \
        | PATH="${G}:${PATH}" bash -s
      exit ;;
  esac
fi
exec bash "$C/tc.orig" "$@"
SH
cat > "$B/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *creationTimestamp*) [ -f "${AGT_CTL:?}/k_services" ] || exit 1; cat "$AGT_CTL/k_services" ;;
  *) exec bash "${AGT_CTL:?}/kubectl.orig" "$@" ;;
esac
SH
cat > "$G/date" <<'SH'
#!/usr/bin/env bash
if [ -n "${AGT_SAMPLER:-}" ] && [ "$*" = "+%s.%N" ] && [ -s "${AGT_CTL:?}/race_clock" ]; then exec pop "$AGT_CTL/race_clock"; fi
exec /bin/date "$@"
SH
# one iptables stand-in for each front end: it lists ctl/ks.<dir>-<name> (ks.guest-iptables-nft, ks.aux-iptables-legacy)
cat > "$G/iptables-nft" <<'SH'
#!/usr/bin/env bash
f="${AGT_CTL:?}/ks.$(basename "$(dirname "$0")")-$(basename "$0")"; [ -f "$f" ] || exit 1; cat "$f"
SH
for f in "$G/iptables-legacy" "$G/aux/iptables-legacy" "$G/aux/iptables-nft"; do cp "$G/iptables-nft" "$f"; done
cat > "$G/nft" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "list ruleset") cat "${AGT_CTL:?}/nft_ruleset" 2>/dev/null || exit 1 ;;
  "list chain ip nat KUBE-SERVICES") cat "${AGT_CTL:?}/nft_chain" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
SH
cat > "$G/ip" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "route get" ] && echo "$3 via 192.0.2.1 dev enp1s0 src 192.0.2.60 uid 0"
SH
cat > "$G/conntrack" <<'SH'
#!/usr/bin/env bash
cat "${AGT_CTL:?}/conntrack_l" 2>/dev/null || exit 1
SH
chmod +x "$G"/* "$G/aux"/* "$B/kubectl" "$T/tests/executed-docs/provision/throwaway-cluster.sh"

KS_RULES='-N KUBE-SERVICES
-A KUBE-SERVICES -d 198.19.0.1/32 -p tcp -m comment --comment "default/kubernetes:https cluster IP" -m tcp --dport 443 -j KUBE-SVC-NPX46M4PTMTKRN6Y
-A KUBE-SERVICES -d 198.19.40.10/32 -p tcp -m comment --comment "demo/web:http cluster IP" -m tcp --dport 4000 -j KUBE-SVC-DEMOWEB0000000000
-A KUBE-SERVICES -m comment --comment "kubernetes service nodeports" -m addrtype --dst-type LOCAL -j KUBE-NODEPORTS
'
NFT_CHAIN='table ip nat {
	chain KUBE-SERVICES {
		meta l4proto tcp ip daddr 198.19.0.1 tcp dport 443 counter packets 0 bytes 0 jump KUBE-SVC-NPX46M4PTMTKRN6Y
		meta l4proto tcp ip daddr 198.19.40.10 tcp dport 4000 counter packets 0 bytes 0 jump KUBE-SVC-DEMOWEB0000000000
	}
}
'
# an un-NATed SYN to demo/web (its reply would come from the ClusterIP itself), a DNATed flow to the API, and a flow
# outside the Service range
CT_UNNAT='tcp      6 117 SYN_SENT src=198.18.0.15 dst=198.19.40.10 sport=40000 dport=4000 [UNREPLIED] src=198.19.40.10 dst=198.18.0.15 sport=4000 dport=40000 mark=0 use=1'
CT_NATTED='tcp      6 86397 ESTABLISHED src=198.18.0.20 dst=198.19.0.1 sport=51000 dport=443 src=192.0.2.60 dst=198.18.0.20 sport=6443 dport=51000 [ASSURED] mark=0 use=1'
CT_OUT='udp      17 29 src=198.18.0.15 dst=203.0.113.53 sport=5353 dport=53 src=203.0.113.53 dst=192.0.2.60 sport=53 dport=5353 mark=0 use=1'
SVCS='default/kubernetes 198.19.0.1 1970-01-01T00:00:00Z\ndemo/web 198.19.40.10 1970-01-01T00:00:00Z\n'
RACE="$(deny_to 198.19.40.10 4000)"
# race_case KEY=VALUE...: set_case, then the probe's guest fixtures: k3s's bundled iptables-legacy holds
# KUBE-SERVICES, /proc/net/nf_conntrack holds the three flows, two denies to demo/web at 1 and 2 ns
race_case() {
  rm -f "$C"/race_* "$C"/ks.* "$C/nf_conntrack" "$C/conntrack_l" "$C/nft_ruleset" "$C/nft_chain" "$C/k_services" "$C"/sampler_*
  printf '%s' "$KS_RULES" > "$C/ks.aux-iptables-legacy"; : > "$C/ks.guest-iptables-nft"
  printf 'ipv4     2 %s\nipv4     2 %s\nipv4     2 %s\n' "$CT_UNNAT" "$CT_NATTED" "$CT_OUT" > "$C/nf_conntrack"
  printf '0.000000000\n0.400000000\n99999\n' > "$C/race_clock"
  set_case counts='1\n3\n' lines="${NTP}\n${RACE}\n${RACE}\n" k_services="$SVCS" "$@"
  touch "$C/race_guest"
}
sampler() { cat "$W/work/airgap-lane/race-sampler.txt" 2>/dev/null; }
in_sampler() { grep -q -- "$1" "$W/work/airgap-lane/race-sampler.txt" 2>/dev/null; }

race_case; lane
if [ "$RC" = 0 ] && has 'AIRGAP-RESULT PASS' && has 'KUBE-SERVICES held by .*/aux/iptables-legacy (3 rules)' \
   && has 'ip route get 198.19.0.1: 198.19.0.1 via 192.0.2.1' && has 'conntrack from proc' \
   && in_sampler '^AIRGAP-RACE-SAMPLER conntrack=proc kube-services=.*/aux/iptables-legacy -w 1 -t nat -S KUBE-SERVICES' \
   && in_sampler '^svc-seen 0.400000000 198.19.40.10$' \
   && in_sampler '^unnat 0.400000000 tcp 198.18.0.15:40000 198.19.40.10:4000 SYN_SENT UNREPLIED$' \
   && in_sampler '^nat-seen 0.400000000 tcp 198.19.0.1:443 192.0.2.60$' && ! in_sampler '203.0.113.53' \
   && [ "$(has 'AIRGAP-RACE-DENY tcp 198.19.40.10:4000 at .* service demo/web created 1970-01-01T00:00:00.000000Z first-seen 1970-01-01T00:00:00.400000Z un-NATed .*: fits' && grep -c '^AIRGAP-RACE-DENY .*: fits$' <<<"$OUT")" = 2 ] \
   && has 'AIRGAP-RACE confirmed: 2 of 2 deny line(s) to the Service range' && has 'race sampler had already ended: 1 tick(s)'; then
  pass "21: race probe: the backend holding KUBE-SERVICES and the route to the learned Service range are recorded; denies after the create, before the first-seen, with an un-NATed flow: confirmed, and the lane still PASSes"
else fail "21: confirmed: rc=$RC $(printf '%s' "$OUT" | grep -i race | tr '\n' '|') sampler: $(sampler | tr '\n' '|')"; fi

race_case race_clock='0.000000000\n0.000000000\n99999\n'; lane
if [ "$RC" = 0 ] && has 'AIRGAP-RESULT PASS' && has "misses, after its ClusterIP's first-seen" \
   && has 'AIRGAP-RACE not-confirmed: 0 of 2 deny line(s) to the Service range fit'; then
  pass "21: race probe: the ClusterIP first-seen before the deny refutes it; the lane's outcome is unchanged"
else fail "21: first-seen first: rc=$RC $(printf '%s' "$OUT" | grep -i race | tr '\n' '|')"; fi

race_case k_services='demo/web 198.19.40.10 1970-01-01T00:00:01Z\n'; lane
if [ "$RC" = 0 ] && has "misses, before its Service's create" && has 'AIRGAP-RACE not-confirmed: 0 of 2'; then
  pass "21: race probe: a deny before its Service's creationTimestamp refutes it"
else fail "21: before create: rc=$RC $(printf '%s' "$OUT" | grep -i race | tr '\n' '|')"; fi

race_case; printf 'ipv4     2 %s\n' "$CT_NATTED" > "$C/nf_conntrack"; lane
if [ "$RC" = 0 ] && has 'misses, no un-NATed flow to it' && has 'AIRGAP-RACE not-confirmed: 0 of 2'; then
  pass "21: race probe: with no un-NATed flow to the ClusterIP it is not confirmed"
else fail "21: no un-NATed flow: rc=$RC $(printf '%s' "$OUT" | grep -i race | tr '\n' '|')"; fi

# nft alone holds KUBE-SERVICES, and there is no /proc/net/nf_conntrack: the sampler reads nft and conntrack -L
race_case; rm -f "$C/nf_conntrack" "$C/ks.aux-iptables-legacy"
printf 'table ip nat {\n\tchain KUBE-SERVICES {\n' > "$C/nft_ruleset"; printf '%s' "$NFT_CHAIN" > "$C/nft_chain"
printf '%s\n%s\n' "$CT_UNNAT" "$CT_NATTED" > "$C/conntrack_l"; lane
if [ "$RC" = 0 ] && has 'KUBE-SERVICES held by nft (1 chain(s)' && has 'conntrack from conntrack-tool' \
   && in_sampler '^AIRGAP-RACE-SAMPLER conntrack=conntrack-tool kube-services=nft list chain ip nat KUBE-SERVICES' \
   && in_sampler '^svc-seen 0.400000000 198.19.40.10$' && has 'AIRGAP-RACE confirmed: 2 of 2'; then
  pass "21: race probe: nft alone holds KUBE-SERVICES and there is no /proc/net/nf_conntrack: nft and conntrack -L are read, and the choice recorded"
else fail "21: nft and conntrack -L: rc=$RC $(printf '%s' "$OUT" | grep -i race | tr '\n' '|') sampler: $(sampler | tr '\n' '|')"; fi

race_case k3s_config='cluster-cidr: 203.0.113.0/25\nservice-cidr: 203.0.113.128/25\n' counts='1\n1\n' lines="${NTP}\n"; lane
if [ "$RC" = 0 ] && has 'ip route get 203.0.113.129: 203.0.113.129 via' && grep -q "RANGES='203.0.113.128/25'" "$C/calls" \
   && has 'AIRGAP-RACE not-confirmed: no deny to the Service range (203.0.113.128/25)'; then
  pass "21: race probe: the route and the sampler follow the Service range the guest's k3s config names"
else fail "21: pinned range: rc=$RC $(printf '%s' "$OUT" | grep -i race | tr '\n' '|')"; fi

race_case race_fail=1 k_services=''; rm -f "$C/k_services"; lane
p1=0; [ "$RC" = 0 ] && has 'AIRGAP-RESULT PASS' && has 'AIRGAP-RACE not-confirmed: the sampler recorded no tick' && p1=1
race_case race_fail=1 counts='1\n3\n' lines="${NTP}\n${RACE}\n${WEB}\n"; lane
p2=0; [ "$RC" = 1 ] && has 'reached past the edge under the cut: 1 deny line(s)' && has '^AIRGAP-RACE not-confirmed' && p2=1
race_case counts='1\n3\n' lines="${NTP}\n${RACE}\n${WEB}\n"; lane
p3=0; [ "$RC" = 1 ] && has 'AIRGAP-RESULT FAIL' && has 'AIRGAP-RACE confirmed: 1 of 1' && p3=1
if [ "$p1" = 1 ] && [ "$p2" = 1 ] && [ "$p3" = 1 ]; then
  pass "21: race probe: a guest that does not answer it and Services that cannot be listed leave a PASS a PASS; a FAIL stays a FAIL, even when the probe confirms"
else fail "21: never fails the lane: pass-kept=$p1 fail-kept=$p2 fail-with-probe=$p3 rc=$RC $(printf '%s' "$OUT" | tail -4 | tr '\n' '|')"; fi

race_case sampler_hang=1; s0="$(date +%s)"; lane; s1="$(date +%s)"
sp="$(cat "$C/sampler_pid" 2>/dev/null)"; sst="$(ps -o stat= -p "${sp:-0}" 2>/dev/null | tr -d ' ')"
# gone, or a zombie (dead, not yet reaped where the host's init does not reap), is not running
if [ "$RC" = 0 ] && [ -n "$sp" ] && case "$sst" in ''|Z*) true ;; *) false ;; esac && has 'race sampler stopped: 0 tick(s)' \
   && [ $((s1 - s0)) -lt 30 ] && in_sampler '^AIRGAP-RACE-SAMPLER stopped-by-lane '; then
  pass "21: race probe: a sampler still running at the end of step 9 is stopped there, not left running"
else fail "21: sampler stop: rc=$RC pid=${sp:-none} state=${sst:-gone} $((s1 - s0))s"; kill "${sp:-0}" 2>/dev/null; fi
cp "$C/tc.orig" "$T/tests/executed-docs/provision/throwaway-cluster.sh"; cp "$C/kubectl.orig" "$B/kubectl"

[ "$FAILS" = 0 ] || exit 1

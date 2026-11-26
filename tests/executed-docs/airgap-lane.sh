#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# airgap-lane.sh: the air-gap clause as one unattended run. A mirror-only install on a segment with no route out,
# where the segment's edge, not the guest, blocks and counts every attempt to leave.
#
#   1. vendor the chart dependencies (tools/helm-deps.sh), outside the boundary, so the guest's Argo CD never fetches a
#      subchart from an upstream Helm repository under the cut
#   2. create the throwaway on the segment (throwaway-cluster.sh create, TOCKMOX_REGISTRY_MODE=nofallback,
#      TOCKMOX_UPSTREAM_DENY=edge, the mirror's CA placed by TOCKMOX_REGISTRY_CA)
#   3. the guest resolves a public name. Under the cut a name that does not resolve sends no packet, so the edge would
#      have nothing to refuse or count, and a zero would mean nothing. Then the guest cluster's own pod and Service
#      ranges, learned at run time: from the guest's k3s config and unit flags (cluster-cidr, service-cidr) where they
#      name them, else from the live cluster (the nodes' podCIDRs; the ServiceCIDR object, else the range the API
#      server names when a server-side dry run asks for an address outside it). A range that cannot be learned, or
#      one wider than /12, is a FAIL: the clause never exempts a range it has not read, or one that wide. The race
#      probe (below) records which backend holds nat KUBE-SERVICES and the guest's route into its Service range
#   4. mirror-tls and mirror-proof both PASS: one verified TLS round trip from the node to the mirror, and the mirror is
#      the node's only registry
#   5. the guest is quieted (apt timers, unattended upgrades, snap refresh, motd news), so the denies under the cut are
#      the install's
#   6. run.sh P04 P05 (Argo CD, sealed-secrets), the state install.md starts from, from the mirror
#   7. this tree served from inside the throwaway the way docs/deployment/airgap.md serves the charts repository: a
#      checkout of it, tagged, with the archives step 1 vendored committed under TAG-vendored by
#      install/charts-vendored-tag.sh (what bootstrap-forge --charts-repo runs), served as committed
#      (site-repo-server.sh push-ref), and that tag is the revision P09 installs. A refused helper is a FAIL here,
#      before the cut, never a served tree without the archives
#   8. THE CUT. The lane prints one AIRGAP-PAUSE line naming what the operator switches (TOCKMOX_AIRGAP_CUT_HINT), then
#      runs the positive control every TOCKMOX_AIRGAP_POLL seconds: the guest asks an upstream registry directly. While
#      that request is answered the cut is not made. When it is refused, the edge must have logged a deny line for the
#      guest within the same window; only then is the cut proven, and the counter proven able to count. A refusal with
#      no deny line, three times, is a FAIL (the counter cannot count); no refusal within TOCKMOX_AIRGAP_CUT_WAIT
#      seconds is BLOCKED (the cut was never made)
#   9. run.sh P09 (built-in route, this tree's install.md, and global.airGapped where airgap.md says), timed: the
#      cut window. The race probe's sampler reads the guest every 0.5 s while it runs, and is stopped at its end.
#      P09 runs under a hard bound, TOCKMOX_AIRGAP_P09_WALL: its own budget (TOCKMOX_P09_BUDGET) is checked only
#      between its steps, so one step that never returns would hold the rig to the job's deadline. At the bound the
#      whole of P09 (its process group) is stopped, AIRGAP-P09-BOUND says so, and the lane goes on to the count, the
#      safe end and a result (INFRA_ERROR: P09 did not finish)
#  10. the edge's deny lines for the guest over the cut window, counted and grouped by destination. A deny whose
#      protocol and port are on TOCKMOX_AIRGAP_IGNORE (default udp/123, the OS's time sync), or whose destination is
#      in the guest cluster's own pod or Service range (step 3: an address the guest owns, not a way out), is reported
#      and does not fail the clause; any other deny does, and the line names where the install reached
#  11. destroy the throwaway, unless TOCKMOX_KEEP_CLUSTER=1
#
# THE CLAUSE PASSES when P09 declared PASS and the edge refused nothing for the guest over the cut window outside
# TOCKMOX_AIRGAP_IGNORE and the guest cluster's own ranges. Every count is printed, ignored ones included.
#
# THE SITE'S VALUES come from the environment, never from this tree:
#   TOCKMOX_REGISTRY_MIRROR, TOCKMOX_REGISTRY_CA   the closed-set mirror (host/project) and the CA that signs it
#   TOCKMOX_VM_NETWORK                             the segment, NAMESPACE/NAME (the pod network is refused: it has a route)
#   TOCKMOX_VM_GUEST_ADDRESS, TOCKMOX_VM_ADDRESS   the guest's static address (CIDR) and the edge alias that reaches it
#   TOCKMOX_EDGE_LOKI_URL, TOCKMOX_EDGE_LOKI_SELECTOR, TOCKMOX_EDGE_DENY_MATCH   where the edge's deny lines are
#                                                  (lib/edge-deny-count.sh)
#   TOCKMOX_AIRGAP_CUT_HINT                        the exact switch the operator flips, as one line
# and the harness's own: TOCKMOX_DOCS_REF, TOCKMOX_SUBSTRATE_CONTEXT, TOCKMOX_TEST_VM. Optional:
#   TOCKMOX_AIRGAP_CUT_WAIT (default 1800 s, 1 to 7200), TOCKMOX_AIRGAP_POLL (default 30 s, 1 to 300),
#   TOCKMOX_AIRGAP_SETTLE (default 20 s, 1 to 120: how long a deny line takes to reach Loki),
#   TOCKMOX_AIRGAP_CONTROL_HOST (default registry-1.docker.io), TOCKMOX_AIRGAP_IGNORE (default "udp/123"),
#   TOCKMOX_AIRGAP_STALL (default 300 s, 2 to 3600: an AIRGAP-STALL line when the run has written nothing for that long,
#   repeated every STALL seconds while it stays quiet), TOCKMOX_AIRGAP_P09_WALL (default TOCKMOX_P09_BUDGET plus 600 s,
#   2 to 14400: the hard bound on step 9), TOCKMOX_KEEP_CLUSTER.
#
# AN EARLY END. A run that ends after P09 began and before step 10 counted (a failed step, or SIGTERM or SIGINT from
# outside, such as the Workflow being stopped) still prints the AIRGAP-DENY table for the cut window it had, from P09's
# start to its end, before the safe end: the egress record is the clause's evidence even when P09 did not finish. A
# stop from outside is INFRA_ERROR, named in the report.
#
# WHAT IT PRINTS for a caller to grep: AIRGAP-PAUSE, AIRGAP-CUT (the control's proof), AIRGAP-WINDOW,
# AIRGAP-DENY <proto> <destination>:<port> <count> [ignored|guest-cluster], AIRGAP-STALL, AIRGAP-P09-BOUND, the race probe's
# AIRGAP-RACE-DENY lines and its AIRGAP-RACE confirmed|not-confirmed line (they observe; they never change the outcome),
# the guest pods' container states and image IDs (AIRGAP-IMAGES BEGIN, one AIRGAP-IMAGE <namespace> <pod> <container> <init|app>
# <state> <imageID> line per container, init containers included, AIRGAP-IMAGES END), printed after P09 and before the safe
# end, so a proof that a container runs from the mirror's digest is read while the guest still exists. It reads status
# fields only: never an environment variable, an argument or a Secret. It observes and never changes the outcome.
# and last AIRGAP-RESULT <outcome>.
#
# Exit: 0 PASS; 1 FAIL (a step failed, P09 did not pass, or the install reached past the edge); 2 a refused
# precondition, before anything is created; 4 BLOCKED (the guest resolves nothing, or the cut was not made in time);
# 5 INFRA_ERROR (Loki or the guest did not answer). The same statuses p09-lane.sh uses, so a caller maps them the same.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "${HERE}/../.." && pwd)"
PROV="${HERE}/provision"
EDC="${HERE}/lib/edge-deny-count.sh"

STOPPED=""
STOP_DETAIL=""   # what a failed step said, under STOPPED in the report: the provisioner's own stderr when create fails
RESULT=""
CREATED=0
INSTALL_STARTED=0
STALL_PID=""
SAMPLER_PID=""   # the race probe's sampler on the guest, while step 9 runs
BOUND_PID=""     # P09 under its hard bound, while step 9 runs
T0=""            # P09's start: the cut window opens here
DENY_DONE=0      # the AIRGAP-DENY table was printed
refuse() { STOPPED="REFUSING: $1"; echo "$STOPPED" >&2; RESULT=REFUSED; exit 2; }
fail() { STOPPED="airgap lane: $1"; echo "$STOPPED" >&2; RESULT=FAIL; exit 1; }
blocked() { STOPPED="airgap lane: BLOCKED: $1"; echo "$STOPPED" >&2; RESULT=BLOCKED; exit 4; }
infra() { STOPPED="airgap lane: INFRA_ERROR: $1"; echo "$STOPPED" >&2; RESULT=INFRA_ERROR; exit 5; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
int_in() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

# ---- refusals, before anything is created ------------------------------------------------------------------------
for v in TOCKMOX_DOCS_REF TOCKMOX_SUBSTRATE_CONTEXT TOCKMOX_TEST_VM TOCKMOX_REGISTRY_MIRROR TOCKMOX_REGISTRY_CA \
         TOCKMOX_VM_NETWORK TOCKMOX_VM_GUEST_ADDRESS TOCKMOX_VM_ADDRESS \
         TOCKMOX_EDGE_LOKI_URL TOCKMOX_EDGE_LOKI_SELECTOR TOCKMOX_EDGE_DENY_MATCH TOCKMOX_AIRGAP_CUT_HINT; do
  [ -n "${!v:-}" ] || refuse "set ${v} (the header of this script says what each one is)"
done
case "${TOCKMOX_REGISTRY_MODE:-nofallback}" in
  nofallback) ;;
  *) refuse "TOCKMOX_REGISTRY_MODE=${TOCKMOX_REGISTRY_MODE}: the clause needs nofallback, where nothing falls back upstream" ;;
esac
case "${TOCKMOX_UPSTREAM_DENY:-edge}" in
  edge) ;;
  *) refuse "TOCKMOX_UPSTREAM_DENY=${TOCKMOX_UPSTREAM_DENY}: this lane counts at the edge; a node-side deny is mirror-proof's lane" ;;
esac
export TOCKMOX_REGISTRY_MODE=nofallback TOCKMOX_UPSTREAM_DENY=edge
[ -s "$TOCKMOX_REGISTRY_CA" ] || refuse "TOCKMOX_REGISTRY_CA names no file with content: ${TOCKMOX_REGISTRY_CA}"
case "$TOCKMOX_VM_NETWORK" in
  pod) refuse "TOCKMOX_VM_NETWORK=pod has a route out through the hypervisor; the clause runs on the no-route segment" ;;
  */*) ;;
  *) refuse "TOCKMOX_VM_NETWORK must be NAMESPACE/NAME, not: ${TOCKMOX_VM_NETWORK}" ;;
esac
GUEST_IP="${TOCKMOX_VM_GUEST_ADDRESS%/*}"
[[ "$GUEST_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || refuse "TOCKMOX_VM_GUEST_ADDRESS must be IPv4 CIDR, not: ${TOCKMOX_VM_GUEST_ADDRESS}"
CUT_WAIT="${TOCKMOX_AIRGAP_CUT_WAIT:-1800}"; int_in "$CUT_WAIT" 1 7200 || refuse "TOCKMOX_AIRGAP_CUT_WAIT must be 1 to 7200 seconds"
POLL="${TOCKMOX_AIRGAP_POLL:-30}";          int_in "$POLL" 1 300 || refuse "TOCKMOX_AIRGAP_POLL must be 1 to 300 seconds"
SETTLE="${TOCKMOX_AIRGAP_SETTLE:-20}";      int_in "$SETTLE" 1 120 || refuse "TOCKMOX_AIRGAP_SETTLE must be 1 to 120 seconds"
STALL="${TOCKMOX_AIRGAP_STALL:-300}";       int_in "$STALL" 2 3600 || refuse "TOCKMOX_AIRGAP_STALL must be 2 to 3600 seconds"
P09_BUDGET_S="${TOCKMOX_P09_BUDGET:-3000}"; int_in "$P09_BUDGET_S" 1 14400 || refuse "TOCKMOX_P09_BUDGET must be 1 to 14400 seconds"
P09_WALL="${TOCKMOX_AIRGAP_P09_WALL:-$((P09_BUDGET_S + 600))}"
int_in "$P09_WALL" 2 14400 || refuse "TOCKMOX_AIRGAP_P09_WALL must be 2 to 14400 seconds"
CONTROL_HOST="${TOCKMOX_AIRGAP_CONTROL_HOST:-registry-1.docker.io}"
[[ "$CONTROL_HOST" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]] || refuse "TOCKMOX_AIRGAP_CONTROL_HOST must be a host name"
IGNORE="${TOCKMOX_AIRGAP_IGNORE-udp/123}"
for i in $IGNORE; do
  [[ "$i" =~ ^(tcp|udp)/[0-9]{1,5}$ ]] || refuse "TOCKMOX_AIRGAP_IGNORE holds proto/port pairs (udp/123), not: ${i}"
done
KEEP="${TOCKMOX_KEEP_CLUSTER:-0}"
case "$KEEP" in 0|1) ;; *) refuse "TOCKMOX_KEEP_CLUSTER must be 0 or 1" ;; esac
CREATE_TAIL_LINES="${TOCKMOX_CREATE_TAIL_LINES:-40}"
case "$CREATE_TAIL_LINES" in ''|*[!0-9]*|0) refuse "TOCKMOX_CREATE_TAIL_LINES must be a positive whole number" ;; esac
[ -f "$EDC" ] || refuse "this tree has no tests/executed-docs/lib/edge-deny-count.sh, so the edge cannot be counted"
for t in kubectl python3; do command -v "$t" >/dev/null 2>&1 || refuse "'${t}' is not on PATH"; done

export TOCKMOX_WORKDIR="${TOCKMOX_WORKDIR:-${TMPDIR:-/tmp}/executed-docs}"
LANE="${TOCKMOX_WORKDIR}/airgap-lane"
mkdir -p "$LANE"
export TOCKMOX_KEY_SECRET="${TOCKMOX_KEY_SECRET:-1}"   # the per-run key lives beside the VM, so a later step can reach it
SUBSTRATE_KUBECONFIG="${KUBECONFIG:-}"
REPORT="${TOCKMOX_WORKDIR}/report-airgap-lane-${TOCKMOX_DOCS_REF//\//_}-$(date -u +%Y%m%dT%H%M%SZ).txt"
: > "$REPORT"
note() { printf '%s\n' "$*" | tee -a "$REPORT"; }
# step NAME: the step now running, kept where the stall watcher reads it
step() { printf '%s\n' "$1" > "${LANE}/step"; }

# shellcheck disable=SC2329  # invoked by the EXIT trap below
finish() {
  local rc=$?
  [ -z "$STALL_PID" ] || kill "$STALL_PID" 2>/dev/null || true
  [ -z "$SAMPLER_PID" ] || race_kill "$SAMPLER_PID" || true
  if [ -n "$BOUND_PID" ]; then kill -TERM "$BOUND_PID" 2>/dev/null || true; wait "$BOUND_PID" 2>/dev/null || true; fi
  [ -n "$RESULT" ] || case "$rc" in 0) RESULT=PASS ;; 2) RESULT=REFUSED ;; 4) RESULT=BLOCKED ;; 5) RESULT=INFRA_ERROR ;; *) RESULT=FAIL ;; esac
  # An early end after the cut install began: the egress record for the window it had, before the safe end.
  if [ "$INSTALL_STARTED" = 1 ] && [ "$DENY_DONE" != 1 ] && [ -n "$T0" ]; then
    DENY_DONE=1
    sleep "$SETTLE"
    local t1; t1="$(now)"
    note "airgap lane: the run ended early (${RESULT}); the edge's denies for the cut window it had, ${T0} to ${t1}:"
    deny_table "$T0" "$t1" || note "airgap lane: the early-end deny table could not be made: ${DENY_WHY}"
  fi
  # An early end after the cut install began: the guest's image IDs too, before the safe end below.
  if [ "$INSTALL_STARTED" = 1 ] && [ "${IMAGES_DONE:-0}" != 1 ] && declare -F image_ids >/dev/null 2>&1; then image_ids || true; fi
  [ -z "$STOPPED" ] || printf '%s\n' "$STOPPED" >> "$REPORT"
  [ -z "$STOP_DETAIL" ] || printf '%s\n' "$STOP_DETAIL" >> "$REPORT"
  # A kept run keeps an install. A run stopped before the cut install began has none, so its VM goes.
  if [ "$CREATED" = 1 ] && [ "$KEEP" = 1 ] && [ "$INSTALL_STARTED" != 1 ] && [ "$rc" != 0 ]; then
    echo "airgap lane: stopped before the cut install began, so there is nothing to keep; destroying ${TOCKMOX_TEST_VM}"
    KEEP=0
  fi
  if [ "$CREATED" = 1 ] && [ "$KEEP" != 1 ]; then
    echo "airgap lane: destroying ${TOCKMOX_TEST_VM}"
    if ! KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" destroy; then
      echo "airgap lane: destroy of ${TOCKMOX_TEST_VM} failed; the harness's sweep owns it now" >&2
      [ "$rc" != 0 ] || { rc=1; RESULT=FAIL; }
    fi
  elif [ "$CREATED" = 1 ]; then
    echo "airgap lane: TOCKMOX_KEEP_CLUSTER=1, so ${TOCKMOX_TEST_VM} stays up; destroy it with throwaway-cluster.sh destroy"
  fi
  echo "AIRGAP-RESULT ${RESULT}" | tee -a "$REPORT"
  exit "$rc"
}
trap finish EXIT

# A stall signal: one line when the run has written nothing under its work directory for STALL seconds, naming the
# newest file, so a watcher sees a hang while it is happening rather than at the job's deadline.
stall_watch() {
  local warned="" newest age tick=0
  # One-second steps, so the watcher is gone within a second of the run's end and never holds its output open.
  while kill -0 "$$" 2>/dev/null; do
    sleep 1; tick=$((tick + 1)); [ $((tick % (STALL < 15 ? STALL : 15))) = 0 ] || continue
    newest="$(python3 -c 'import os,sys
best=(0,"")
for d,_,fs in os.walk(sys.argv[1]):
    for f in fs:
        if f == "race-sampler.txt": continue  # the race sampler writes every 0.5 s; it is not the run making progress
        p=os.path.join(d,f)
        try: best=max(best,(os.path.getmtime(p),p))
        except OSError: pass
if best[1]: print("%d %s" % best)' "$TOCKMOX_WORKDIR" 2>/dev/null || true)"
    [ -n "$newest" ] || continue
    age=$(( $(date +%s) - ${newest%% *} ))
    # Once, then again every STALL seconds while the run stays quiet, so a hang is seen growing rather than once.
    if [ "$age" -ge "$STALL" ] && [ $(( $(date +%s) - ${warned:-0} )) -ge "$STALL" ]; then
      warned="$(date +%s)"
      echo "AIRGAP-STALL ${age}s with nothing written, in step '$(cat "${LANE}/step" 2>/dev/null || echo unknown)'; newest file: ${newest#* }"
    fi
  done
}
stall_watch & STALL_PID=$!

# A stop from outside (the Workflow stopped, or the pod's deadline) ends the run through finish(): the deny table for the
# window it had, the safe end and a result, never a silent kill. A trapped signal interrupts `wait`, so this runs at once
# while P09 is bounded below.
on_signal() { STOPPED="airgap lane: INFRA_ERROR: stopped from outside (SIG${1}) in step '$(cat "${LANE}/step" 2>/dev/null || echo unknown)'"; echo "$STOPPED" >&2; RESULT=INFRA_ERROR; exit 5; }
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

# bounded SECONDS MARK CMD...: CMD in a process group of its own, in the background so a trapped signal is seen while it
# runs. At SECONDS the whole group is stopped (TERM, then KILL after 20 s), MARK is written, and the status is 124. A TERM
# to the bounder stops the group the same way.
bounded() {
  python3 -c '
import os, signal, subprocess, sys
limit, mark, cmd = float(sys.argv[1]), sys.argv[2], sys.argv[3:]
p = subprocess.Popen(cmd, start_new_session=True)
def stop(rc):
    for sig, grace in ((signal.SIGTERM, 20), (signal.SIGKILL, 5)):
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            break
        try:
            p.wait(grace)
            break
        except subprocess.TimeoutExpired:
            pass
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    sys.exit(rc)
signal.signal(signal.SIGTERM, lambda *a: stop(143))
signal.signal(signal.SIGINT, lambda *a: stop(130))
try:
    sys.exit(p.wait(limit))
except subprocess.TimeoutExpired:
    open(mark, "w").write("%d\n" % limit)
    stop(124)
' "$@" &
  BOUND_PID=$!
  local rc=0
  wait "$BOUND_PID" || rc=$?
  BOUND_PID=""
  return "$rc"
}

# ---- the Service-creation race probe: it observes, and it never changes the outcome --------------------------------
# A hypothesis from the earlier cut runs: CoreDNS answers a new ClusterIP before k3s's embedded kube-proxy has
# programmed its DNAT, so the first SYN finds no rule in nat KUBE-SERVICES and leaves by the default route, and
# conntrack then keeps its retransmits un-NATed. The edge refuses them, and the clause reports them as guest-cluster.
# The probe records what would confirm or refute that, in race-* files under the lane directory and AIRGAP-RACE lines
# in the report:
#   step 3  which backend holds KUBE-SERVICES (iptables-legacy, iptables-nft, k3s's bundled ones, nft) and the route
#           the guest takes to the first address of its own Service range, learned above, never assumed
#   step 9  a read-only sampler on the guest, every 0.5 s while P09 runs: the first time each ClusterIP appears in nat
#           KUBE-SERVICES, and each conntrack flow to the Service range that was not DNATed (its reply comes from the
#           address it was sent to), read from /proc/net/nf_conntrack where it exists, else `conntrack -L`
#   after   each Service's creationTimestamp, and for each deny to the Service range: its time, its Service, that
#           Service's create, its ClusterIP's first-seen and whether an un-NATed flow went to it. Then one line,
#           AIRGAP-RACE confirmed (every such deny falls after its Service's create, before its ClusterIP's first-seen,
#           with an un-NATed flow) or AIRGAP-RACE not-confirmed and why
# Each piece runs in a subshell with errexit off, or is called with || true, and calls none of refuse, fail, blocked
# and infra. The guest's clock is compared with this host's once, at step 3, and printed; it is not applied, because
# the edge's times are Loki's.
RACE_AUX="/var/lib/rancher/k3s/data/current/bin/aux"
RACE_SVC=""   # the guest's Service range(s), set at step 3
race_ts() { python3 -c 'import time; print("%.6f" % time.time())'; }
# race_kill PID: the process and everything under it (the sampler is ssh under bash under a subshell)
race_kill() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do race_kill "$c"; done
  kill "$1" 2>/dev/null || true
}
# race_leaves PID: the processes under PID that have none of their own. Stopping those first lets each parent reap its
# child and end by itself; a parent killed first leaves its child unreaped.
race_leaves() {
  local c any=""
  for c in $(pgrep -P "$1" 2>/dev/null); do any=1; race_leaves "$c"; done
  [ -n "$any" ] || echo "$1"
}

# race_step3: the backend that holds KUBE-SERVICES, the route to the Service range, the guest's clock
race_step3() (
  set +eu +o pipefail
  ip0="$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_network(sys.argv[1].split()[0]).network_address + 1)' "$RACE_SVC" 2>/dev/null)"
  [[ "$ip0" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { note "airgap lane 3: race probe: no Service range to probe (${RACE_SVC:-none})"; exit 0; }
  script="$(cat <<GUEST
echo "AIRGAP-RACE-CLOCK \$(date +%s.%N)"
for c in iptables-legacy iptables-nft ${RACE_AUX}/iptables-legacy ${RACE_AUX}/iptables-nft; do
  if command -v "\$c" >/dev/null 2>&1; then
    echo "AIRGAP-RACE-BACKEND \$c rules=\$("\$c" -w 1 -t nat -S KUBE-SERVICES 2>/dev/null | grep -c '^-A KUBE-SERVICES')"
  else
    echo "AIRGAP-RACE-BACKEND \$c absent"
  fi
done
if command -v nft >/dev/null 2>&1; then
  echo "AIRGAP-RACE-BACKEND nft chains=\$(nft list ruleset 2>/dev/null | grep -c 'chain KUBE-SERVICES')"
else
  echo "AIRGAP-RACE-BACKEND nft absent"
fi
echo "AIRGAP-RACE-ROUTE \$(ip route get ${ip0} 2>&1 | head -1)"
if [ -r /proc/net/nf_conntrack ]; then echo "AIRGAP-RACE-CONNTRACK proc"
elif command -v conntrack >/dev/null 2>&1; then echo "AIRGAP-RACE-CONNTRACK conntrack-tool"
else echo "AIRGAP-RACE-CONNTRACK none"; fi
echo AIRGAP-RACE-END
GUEST
)"
  h0="$(race_ts)"; gexec "$script" > "${LANE}/race-step3.txt" 2>&1; h1="$(race_ts)"
  python3 - "${LANE}/race-step3.txt" "$h0" "$h1" "$ip0" "${LANE}/race-ks" <<'PY' > "${LANE}/race-step3.note" 2>/dev/null
import re, sys
path, h0, h1, ip0, ks_out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
holders, nft, route, clock, ct = [], 0, "", None, ""
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    m = re.match(r"AIRGAP-RACE-BACKEND nft chains=(\d+)$", line)
    if m:
        nft = int(m.group(1))
        continue
    m = re.match(r"AIRGAP-RACE-BACKEND ([A-Za-z0-9/_.+-]+) rules=(\d+)$", line)
    if m and int(m.group(2)) > 0:
        holders.append((int(m.group(2)), m.group(1)))
    m = re.match(r"AIRGAP-RACE-ROUTE (.*)$", line)
    if m:
        route = m.group(1).strip()
    m = re.match(r"AIRGAP-RACE-CLOCK ([0-9]+(?:\.[0-9]*)?)", line)
    if m:
        clock = float(m.group(1))
    m = re.match(r"AIRGAP-RACE-CONNTRACK (\S+)$", line)
    if m:
        ct = m.group(1)
order = sorted(holders, key=lambda h: -h[0])   # stable: the first listed wins a tie
if order:
    ks = "%s -w 1 -t nat -S KUBE-SERVICES" % order[0][1]
    held = ", ".join("%s (%d rules)" % (n, r) for r, n in holders)
    if len(holders) > 1:
        held += "; more than one holds it, and the sampler reads %s" % order[0][1]
elif nft:
    ks = "nft list chain ip nat KUBE-SERVICES"
    held = "nft (%d chain(s); no iptables front end listed it)" % nft
else:
    ks = ""
    held = "nothing the probe could read, so the sampler records no first-seen"
open(ks_out, "w").write(ks + "\n")
skew = "unknown" if clock is None else "%+.3f s (+/-%.3f)" % (clock - (h0 + h1) / 2, (h1 - h0) / 2)
print("airgap lane 3: race probe: KUBE-SERVICES held by %s; ip route get %s: %s; conntrack from %s; guest clock minus "
      "this host's %s" % (held, ip0, route or "no answer", ct or "unknown", skew))
PY
  if [ -s "${LANE}/race-step3.note" ]; then note "$(cat "${LANE}/race-step3.note")"
  else note "airgap lane 3: race probe: the guest's answer could not be read (${LANE}/race-step3.txt)"; fi
)

# race_sampler_start: the sampler, in the background, until race_sampler_stop. It waits up to 10 s for the first tick,
# so P09 never starts before the sampler is reading.
race_sampler_start() {
  local ks limit script i=0 ks_ok='^[A-Za-z0-9/_.+ -]*$' svc_ok='^[0-9./ ]+$'
  ks="$(head -1 "${LANE}/race-ks" 2>/dev/null || true)"
  [[ "$ks" =~ $ks_ok ]] || ks=""
  [[ "$RACE_SVC" =~ $svc_ok ]] || { note "airgap lane 9: race sampler not started: no Service range"; return 0; }
  limit="${TOCKMOX_P09_BUDGET:-3000}"
  case "$limit" in ''|*[!0-9]*) limit=3000 ;; esac
  limit=$((limit + 600))
  script="$(printf "RANGES='%s'\nKS='%s'\nLIMIT=%s\n" "$RACE_SVC" "$ks" "$limit"; cat <<'GUEST'
if [ -r /proc/net/nf_conntrack ]; then CT='cat /proc/net/nf_conntrack'; CTSRC=proc
elif command -v conntrack >/dev/null 2>&1; then CT='conntrack -L -f ipv4'; CTSRC=conntrack-tool
else CT=''; CTSRC=none; fi
echo "AIRGAP-RACE-SAMPLER conntrack=${CTSRC} kube-services=${KS:-none} ranges=${RANGES} every 0.5 s"
awk -v ks="${KS:+$KS 2>/dev/null}" -v ct="${CT:+$CT 2>/dev/null}" -v ranges="$RANGES" -v limit="$LIMIT" '
function ipn(s,  a) { if (split(s, a, ".") != 4) return -1; return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
function owned(s,  n, i, d) {
  n = ipn(s); if (n < 0) return 0
  for (i = 1; i <= nr; i++) { d = 2 ^ (32 - rp[i]); if (int(n / d) == int(rn[i] / d)) return 1 }
  return 0
}
function now(  c, t) { c = "date +%s.%N"; c | getline t; close(c); return t }
BEGIN {
  nr = split(ranges, r, " ")
  for (i = 1; i <= nr; i++) { split(r[i], p, "/"); rn[i] = ipn(p[1]); rp[i] = p[2] + 0 }
  t0 = now(); print "AIRGAP-RACE-SAMPLER start " t0; fflush()
  while (1) {
    t = now(); if (t + 0 >= t0 + limit) break
    if (ks != "") {
      while ((ks | getline l) > 0) {
        n = split(l, f, " ")
        for (i = 1; i < n; i++) if (f[i] == "-d" || f[i] == "daddr") {
          ip = f[i + 1]; sub(/\/32$/, "", ip)
          if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !(ip in seen)) { seen[ip] = t; print "svc-seen " t " " ip }
        }
      }
      close(ks)
    }
    if (ct != "") {
      while ((ct | getline l) > 0) {
        n = split(l, f, " "); proto = ""; st = ""; un = ""; ns = 0; nd = 0; nsp = 0; ndp = 0
        src[1] = src[2] = dst[1] = sp[1] = dp[1] = ""
        for (i = 1; i <= n; i++) {
          if (proto == "" && (f[i] == "tcp" || f[i] == "udp")) proto = f[i]
          else if (f[i] ~ /^src=/) src[++ns] = substr(f[i], 5)
          else if (f[i] ~ /^dst=/) dst[++nd] = substr(f[i], 5)
          else if (f[i] ~ /^sport=/) sp[++nsp] = substr(f[i], 7)
          else if (f[i] ~ /^dport=/) dp[++ndp] = substr(f[i], 7)
          else if (st == "" && f[i] ~ /^[A-Z_]+$/) st = f[i]
          else if (f[i] == "[UNREPLIED]") un = " UNREPLIED"
        }
        if (proto == "" || !owned(dst[1])) continue
        if (src[2] == dst[1]) {
          k = proto " " src[1] ":" sp[1] " " dst[1] ":" dp[1]
          if (!(k in flows)) { flows[k] = t; print "unnat " t " " k " " (st == "" ? "-" : st) un }
        } else {
          k = proto " " dst[1] ":" dp[1]
          if (!(k in natted)) { natted[k] = t; print "nat-seen " t " " k " " src[2] }
        }
      }
      close(ct)
    }
    print "tick " t; fflush()
    system("sleep 0.5")
  }
  print "AIRGAP-RACE-SAMPLER deadline " t; fflush()
}'
GUEST
)"
  gexec "$script" > "${LANE}/race-sampler.txt" 2>&1 &
  SAMPLER_PID=$!
  while [ "$i" -lt 20 ] && kill -0 "$SAMPLER_PID" 2>/dev/null && ! grep -q '^tick ' "${LANE}/race-sampler.txt" 2>/dev/null; do
    sleep 0.5; i=$((i + 1))
  done
  echo "airgap lane 9: race sampler started on the guest ($(head -1 "${LANE}/race-sampler.txt" 2>/dev/null || echo 'nothing yet'))"
}

# race_sampler_stop: the end of step 9. A sampler that already ended is said so; one still running is stopped.
race_sampler_stop() {
  local how="had already ended"
  [ -n "$SAMPLER_PID" ] || return 0
  if kill -0 "$SAMPLER_PID" 2>/dev/null; then
    local leaf i=0
    for leaf in $(race_leaves "$SAMPLER_PID"); do kill "$leaf" 2>/dev/null || true; done
    while [ "$i" -lt 10 ] && kill -0 "$SAMPLER_PID" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
    ! kill -0 "$SAMPLER_PID" 2>/dev/null || race_kill "$SAMPLER_PID"
    how="stopped"
  fi
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""
  echo "AIRGAP-RACE-SAMPLER stopped-by-lane $(race_ts)" >> "${LANE}/race-sampler.txt"
  note "airgap lane 9: race sampler ${how}: $(grep -c '^tick ' "${LANE}/race-sampler.txt" 2>/dev/null) tick(s), $(grep -c '^svc-seen ' "${LANE}/race-sampler.txt" 2>/dev/null) ClusterIP(s) first-seen, $(grep -c '^unnat ' "${LANE}/race-sampler.txt" 2>/dev/null) un-NATed flow(s) to the Service range ($(sed -n 's/^AIRGAP-RACE-SAMPLER \(conntrack=[^ ]* kube-services=.*\) ranges=.*/\1/p' "${LANE}/race-sampler.txt" 2>/dev/null | head -1))"
}

# race_services: after P09, every Service's namespace/name, ClusterIP and creationTimestamp
race_services() (
  set +eu +o pipefail
  gk get services -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.clusterIP} {.metadata.creationTimestamp}{"\n"}{end}' \
    > "${LANE}/race-services.txt" 2> "${LANE}/race-services.err" \
    || note "airgap lane 9: race probe: the Services could not be listed ($(tail -1 "${LANE}/race-services.err"))"
)

# race_verdict DENIES: each deny over the cut window to the Service range, with its time from Loki, against the
# sampler and the Services; then the AIRGAP-RACE line
race_verdict() (
  set +eu +o pipefail
  : > "${LANE}/race-deny-times.txt"
  if [ "${1:-0}" -gt 0 ] 2>/dev/null; then
    python3 - "$TOCKMOX_EDGE_LOKI_URL" "$TOCKMOX_EDGE_LOKI_SELECTOR" "$TOCKMOX_EDGE_DENY_MATCH" "$GUEST_IP" "$T0" "$T1" \
      > "${LANE}/race-deny-times.txt" 2> "${LANE}/race-deny-times.err" <<'PY'
import json, sys, urllib.parse, urllib.request
from datetime import datetime
url, sel, match, guest, since, until = sys.argv[1:7]
t0, t1 = (datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() for s in (since, until))
pipe = f'|= "{match}" |~ "(^|[^0-9.]){guest.replace(".", "[.]")}([^0-9.]|$)"'
q = urllib.parse.urlencode({"query": f"{sel} {pipe}", "start": str(int(t0 * 1e9)), "end": str(int(t1 * 1e9)),
                            "limit": "2000", "direction": "forward"})
with urllib.request.urlopen(f"{url.rstrip('/')}/loki/api/v1/query_range?{q}", timeout=20) as r:
    d = json.load(r)
for stream in (d.get("data") or {}).get("result") or []:
    for ts, line in stream.get("values") or []:
        print(f"{ts}\t{line[:300]}")
PY
  fi
  python3 - "$GUEST_IP" "$RACE_SVC" "${LANE}/race-sampler.txt" "${LANE}/race-services.txt" "${LANE}/race-deny-times.txt" \
    > "${LANE}/race-verdict.txt" 2> "${LANE}/race-verdict.err" <<'PY'
import ipaddress, re, sys
from datetime import datetime, timezone
guest, ranges, sampler, services, stamps = sys.argv[1:6]
nets = [ipaddress.ip_network(r) for r in ranges.split()]
def in_svc(a):
    try:
        return any(ipaddress.ip_address(a) in n for n in nets)
    except ValueError:
        return False
def lines(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return []
def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
ticks, seen, unnat, source = 0, {}, {}, "conntrack=? kube-services=?"
for l in lines(sampler):
    p = l.split()
    try:
        if l.startswith("AIRGAP-RACE-SAMPLER conntrack="):
            source = " ".join(p[1:3])
        elif p and p[0] == "tick":
            ticks += 1
        elif p and p[0] == "svc-seen" and len(p) >= 3:
            seen.setdefault(p[2], float(p[1]))
        elif p and p[0] == "unnat" and len(p) >= 5:
            ip, _, port = p[4].rpartition(":")
            unnat.setdefault((p[2], ip, port), float(p[1]))
    except ValueError:
        pass
svc = {}
for l in lines(services):
    p = l.split()
    if len(p) == 3:
        try:
            svc[p[1]] = (p[0], datetime.fromisoformat(p[2].replace("Z", "+00:00")).timestamp())
        except ValueError:
            pass
denies = []
for l in lines(stamps):
    ts, _, raw = l.partition("\t")
    t = [x.strip() for x in raw.split(",")]
    if guest not in t or not ts.isdigit():
        continue
    i = t.index(guest)
    proto = next((x for x in reversed(t[:i]) if x in ("tcp", "udp", "icmp", "igmp")), "?")
    dst = t[i + 1] if i + 1 < len(t) else "?"
    port = t[i + 3] if proto in ("tcp", "udp") and i + 3 < len(t) else ""
    if in_svc(dst):
        denies.append((int(ts) / 1e9, proto, dst, port))
read_ks = "kube-services=none" not in source and bool(seen)
fit = 0
for t, proto, dst, port in denies:
    why = []
    name, created = svc.get(dst, ("no Service", None))
    if created is None:
        why.append("no Service holds this ClusterIP after P09")
    elif t < created:
        why.append("before its Service's create")
    fs = seen.get(dst)
    if fs is None and not read_ks:
        why.append("KUBE-SERVICES was not read")
    elif fs is not None and t >= fs:
        why.append("after its ClusterIP's first-seen")
    flow = unnat.get((proto, dst, port))
    if flow is None:
        why.append("no un-NATed flow to it")
    fit += 0 if why else 1
    print("AIRGAP-RACE-DENY %s %s:%s at %s service %s created %s first-seen %s un-NATed %s: %s" % (
        proto, dst, port, iso(t), name, iso(created) if created is not None else "-",
        iso(fs) if fs is not None else "never", iso(flow) if flow is not None else "none",
        "fits" if not why else "misses, " + "; ".join(why)))
if not ticks:
    print("AIRGAP-RACE not-confirmed: the sampler recorded no tick, so nothing was observed (%s)" % source)
elif not denies:
    print("AIRGAP-RACE not-confirmed: no deny to the Service range (%s) over the cut window (%s)" % (ranges, source))
elif fit == len(denies):
    print("AIRGAP-RACE confirmed: %d of %d deny line(s) to the Service range fall after their Service's create, "
          "before their ClusterIP's first-seen in KUBE-SERVICES, with an un-NATed flow (%s)" % (fit, len(denies), source))
else:
    print("AIRGAP-RACE not-confirmed: %d of %d deny line(s) to the Service range fit (%s)" % (fit, len(denies), source))
PY
  if grep -q '^AIRGAP-RACE ' "${LANE}/race-verdict.txt" 2>/dev/null; then tee -a "$REPORT" < "${LANE}/race-verdict.txt"
  else note "AIRGAP-RACE not-confirmed: the probe's verdict could not be made ($(tail -1 "${LANE}/race-verdict.err" 2>/dev/null))"; fi
)

note "airgap lane: commit ${TOCKMOX_DOCS_REF} on ${TOCKMOX_VM_NETWORK}, guest ${GUEST_IP}, mirror ${TOCKMOX_REGISTRY_MIRROR} (nofallback, counted at the edge)"

# 1. the chart dependencies, vendored outside the boundary
step "1 vendor chart dependencies"
if [ -f "${TREE}/tools/helm-deps.sh" ]; then
  ( cd "$TREE" && bash tools/helm-deps.sh ) > "${LANE}/helm-deps.log" 2>&1 \
    || fail "tools/helm-deps.sh failed, so the guest's Argo CD would fetch subcharts upstream under the cut (${LANE}/helm-deps.log)"
  echo "airgap lane 1: chart dependencies vendored"
fi

# 2. the throwaway, on the segment
step "2 create the throwaway"
echo "airgap lane 2: creating ${TOCKMOX_TEST_VM} on ${TOCKMOX_SUBSTRATE_CONTEXT}, ${TOCKMOX_VM_NETWORK}"
# What create said goes in the report, not only in the job log (run.sh and p09-lane.sh do the same): its stderr is
# copied to a file while it still streams to the job log, and a failed create puts its last stderr line in the summary
# line and a bounded tail, masked by lib/stderr-tail.py's rule, beneath it. Without that helper nothing is copied.
CREATE_ERR="${LANE}/create-stderr.txt"
TAIL_PY="${HERE}/lib/stderr-tail.py"
create_said() {
  echo "  --- the provisioner's stderr, last ${CREATE_TAIL_LINES} lines (terminal codes stripped, credential-shaped text masked) ---"
  if [ -f "$TAIL_PY" ]; then
    python3 "$TAIL_PY" --lines "$CREATE_TAIL_LINES" "$1" 2>&1 | sed 's/^/  | /'
  else
    echo "  | (this tree has no lib/stderr-tail.py to mask it with, so it is in the job log only)"
  fi
  echo "  --- end ---"
}
create_reason() {
  if [ -f "$TAIL_PY" ] && python3 "$TAIL_PY" --last "$1" 2>/dev/null; then return 0; fi
  echo "its stderr is in the job log"
}
create_rc=0
why=""
out="$( { bash "${PROV}/throwaway-cluster.sh" create 2>&1 1>&3 3>&- | tee "$CREATE_ERR" >&2; } 3>&1 )" || create_rc=$?
[ "$create_rc" = 0 ] || { STOP_DETAIL="$(create_said "$CREATE_ERR")"; why="$(create_reason "$CREATE_ERR")"; }
case "$create_rc" in
  0) ;;
  4) blocked "create refused: the rig is full (its capacity gate): ${why}" ;;
  5) infra "create could not read the rig (exit 5): ${why}" ;;
  *) CREATED=1; fail "provisioning failed (create exit ${create_rc}): ${why}" ;;
esac
CREATED=1
KC="$(printf '%s\n' "$out" | tail -1)"
[ -s "$KC" ] || fail "create printed no kubeconfig path"
# ctx-exempt-next: reads the context NAME out of the kubeconfig file create just wrote; reaches no cluster
KUBE_CONTEXT="$(KUBECONFIG="$KC" kubectl config current-context)"
: "${KUBE_CONTEXT:?the guest kubeconfig names no context}"
export TOCKMOX_EXISTING_KUBECONFIG="$KC" KUBE_CONTEXT TOCKMOX_SUBSTRATE_KUBECONFIG="$SUBSTRATE_KUBECONFIG"
gexec() { KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" exec "$1"; }

# 3. the guest resolves a public name
step "3 guest resolver check"
dns="$(gexec "getent hosts ${CONTROL_HOST} >/dev/null && echo AIRGAP-DNS-RESOLVED || echo AIRGAP-DNS-NONE" 2>/dev/null || true)"
case "$dns" in
  *AIRGAP-DNS-RESOLVED*) echo "airgap lane 3: the guest resolves ${CONTROL_HOST}" ;;
  *AIRGAP-DNS-NONE*) blocked "the guest resolves no public name (${CONTROL_HOST}), so under the cut nothing it asks for would leave a packet to count. Open the segment's resolver to recursion for the run" ;;
  *) infra "the guest did not answer the resolver check" ;;
esac
# The guest cluster's own ranges. A packet to a ClusterIP or pod address that leaves the node by the default route is
# refused at the edge, but it is bound for an address the guest owns, not for the internet; the clause reports it
# (guest-cluster) and does not fail on it. Only the ranges this guest uses, learned now; nothing is assumed.
k3s_cfg="$(gexec 'cat /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.d/*.yaml /etc/systemd/system/k3s.service 2>/dev/null; echo AIRGAP-K3S-CONFIG-END' 2>/dev/null || true)"
case "$k3s_cfg" in
  *AIRGAP-K3S-CONFIG-END*) ;;
  *) infra "the guest did not answer the read of its k3s config, so its own pod and Service ranges are unknown" ;;
esac
gk() { KUBECONFIG="$KC" kubectl --context="$KUBE_CONTEXT" "$@"; }

# image_ids: after P09 and before the safe end (the guest is destroyed there), one marked block with, for every container
# of every pod in the guest cluster (init containers included), its namespace, pod, container, kind (init or app),
# state and imageID, so which digest a container runs from is read, not inferred. Status fields only: the filter never
# looks at env, args or Secrets. A guest that does not answer leaves AIRGAP-IMAGES UNREADABLE inside the block; the
# outcome is never changed either way.
IMAGES_DONE=0
image_ids() {
  local out rc=0
  IMAGES_DONE=1
  out="$(gk get pods -A -o json --request-timeout=30s 2>"${LANE}/image-ids.err")" || rc=$?
  note "AIRGAP-IMAGES BEGIN namespace pod container kind state imageID"
  if [ "$rc" != 0 ]; then
    note "AIRGAP-IMAGES UNREADABLE kubectl get pods -A exit ${rc}"
  else
    cat > "${LANE}/image-ids.py" <<'PY'
import json, re, sys
d = json.load(sys.stdin)
def clean(v):
    v = re.sub(r"\s+", "_", str(v or "").strip())
    return v or "-"
rows = []
for p in d.get("items") or []:
    m, st, sp = p.get("metadata") or {}, p.get("status") or {}, p.get("spec") or {}
    ns, pod = clean(m.get("namespace")), clean(m.get("name"))
    for kind, sk, pk in (("init", "initContainerStatuses", "initContainers"), ("app", "containerStatuses", "containers")):
        seen = set()
        for c in st.get(sk) or []:
            s = c.get("state") or {}
            k = next(iter(s), "unknown")
            r = (s.get(k) or {}).get("reason")
            rows.append((ns, pod, 0 if kind == "init" else 1, clean(c.get("name")), kind, clean(k + (":" + r if r else "")), clean(c.get("imageID"))))
            seen.add(c.get("name"))
        for c in sp.get(pk) or []:
            if c.get("name") not in seen:
                rows.append((ns, pod, 0 if kind == "init" else 1, clean(c.get("name")), kind, "no-status", "-"))
for ns, pod, _, name, kind, state, iid in sorted(rows):
    print("AIRGAP-IMAGE %s %s %s %s %s %s" % (ns, pod, name, kind, state, iid))
PY
    if printf '%s' "$out" | python3 "${LANE}/image-ids.py" > "${LANE}/image-ids.txt" 2>/dev/null; then
      while IFS= read -r line; do note "$line"; done < "${LANE}/image-ids.txt"
    else
      note "AIRGAP-IMAGES UNREADABLE the pod list could not be parsed"
    fi
  fi
  note "AIRGAP-IMAGES END"
}
live_pod="$(gk get nodes -o jsonpath='{.items[*].spec.podCIDRs[*]}' 2>/dev/null || true)"
live_svc="$(gk get servicecidrs.networking.k8s.io kubernetes -o jsonpath='{.spec.cidrs[*]}' 2>/dev/null || true)"
svc_probe=""
# Without a ServiceCIDR object, a server-side dry run (nothing is created) for an address outside the range makes the
# API server name the range it allocates from.
[ -n "$live_svc" ] || svc_probe="$(gk create service clusterip airgap-lane-range-probe --tcp=1 --clusterip=192.0.2.1 \
  --dry-run=server -o name 2>&1 || true)"
GUEST_RANGES="$(printf '%s\n' "$k3s_cfg" | python3 -c '
import ipaddress, re, sys
live_pod, live_svc, probe = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {}
for line in sys.stdin:
    for m in re.finditer(r"(?:^|[\s\x27\"])-{0,2}(cluster-cidr|service-cidr)\s*[:=\s]\s*[\x27\"]?([0-9A-Fa-f.:/,]+)", line):
        cfg[m.group(1)] = m.group(2)   # the last wins: config.yaml.d over config.yaml, the unit flags over both
found = re.findall(r"range of valid IPs is ([0-9A-Fa-f.:/]+)", probe)
learned = {
    "cluster-cidr": ("pod", cfg.get("cluster-cidr") and (cfg["cluster-cidr"], "the k3s config")
                     or live_pod.split() and (",".join(live_pod.split()), "the nodes\x27 podCIDRs")),
    "service-cidr": ("service", cfg.get("service-cidr") and (cfg["service-cidr"], "the k3s config")
                     or live_svc.split() and (",".join(live_svc.split()), "the ServiceCIDR object")
                     or found and (",".join(found), "the API server, for a dry-run Service")),
}
nets, said = [], []
for key, (what, got) in learned.items():
    if not got:
        sys.exit("the guest cluster %s range could not be learned (no %s in its k3s config, and the live cluster did not say)" % (what, key))
    value, src = got
    v4 = []
    for part in value.split(","):
        try:
            net = ipaddress.ip_network(part.strip(), strict=False)
        except ValueError:
            sys.exit("%s %r from %s is not a network" % (what, part.strip(), src))
        if net.version != 4:
            continue
        if net.prefixlen < 12:
            sys.exit("%s range %s from %s is wider than /12, so the clause would ignore too much" % (what, net, src))
        v4.append(net)
    if not v4:
        sys.exit("the guest cluster %s range could not be learned: %s names no IPv4 network" % (what, src))
    nets += v4
    said.append("%s %s (%s)" % (what, " ".join(map(str, v4)), src))
print(" ".join(map(str, nets)) + "|" + ", ".join(said))
' "$live_pod" "$live_svc" "$svc_probe" 2>"${LANE}/guest-ranges.err")" \
  || fail "the guest cluster's own ranges: $(tail -1 "${LANE}/guest-ranges.err")"
note "airgap lane 3: the guest cluster's own ranges, reported and not counted against the clause: ${GUEST_RANGES#*|}"
RACE_SVC="$(printf '%s' "${GUEST_RANGES#*|}" | python3 -c 'import re, sys
m = re.search(r"(?:^|, )service ((?:[0-9.]+/[0-9]+ ?)+) \(", sys.stdin.read())
print(m.group(1).strip() if m else "")' 2>/dev/null || true)"
GUEST_RANGES="${GUEST_RANGES%%|*}"
race_step3 || true

# 4. the mirror: a verified TLS round trip, and the only registry
step "4 mirror-tls and mirror-proof"
KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" mirror-tls > "${LANE}/mirror-tls.txt" 2>&1 || true
grep -q 'mirror-tls: PASS' "${LANE}/mirror-tls.txt" \
  || fail "mirror-tls did not pass, so every pull would fail before the cut is reached ($(tail -1 "${LANE}/mirror-tls.txt"))"
KUBECONFIG="$SUBSTRATE_KUBECONFIG" bash "${PROV}/throwaway-cluster.sh" mirror-proof > "${LANE}/mirror-proof.txt" 2>&1 || true
grep -q 'mirror-proof: PASS' "${LANE}/mirror-proof.txt" \
  || fail "mirror-proof did not pass: the node has a registry other than the mirror ($(tail -1 "${LANE}/mirror-proof.txt"))"
echo "airgap lane 4: mirror-tls and mirror-proof PASS"

# 5. quiet the guest
if gexec 'systemctl disable --now apt-daily.timer apt-daily-upgrade.timer motd-news.timer 2>/dev/null; systemctl disable --now unattended-upgrades 2>/dev/null; snap refresh --hold 2>/dev/null; true' >/dev/null 2>&1; then
  echo "airgap lane 5: guest quieted (apt timers, unattended-upgrades, snap refresh, motd news)"
else
  echo "airgap lane 5: WARN: the guest could not be quieted; its OS denies will show by destination"
fi

# 6. what install.md starts from
step "6 P04 and P05"
echo "airgap lane 6: P04 + P05 (Argo CD, sealed-secrets), from the mirror"
export KUBECONFIG="$KC"
bash "${HERE}/run.sh" P04 P05 || fail "P04/P05 failed, so P09 would start from the wrong state"

# 7. this tree, served from inside the throwaway, by the documented path
step "7 serve this tree"
bash "${PROV}/site-repo-server.sh" up >/dev/null || fail "site-repo-server.sh up failed"
# The archives step 1 vendored are what lets the guest's Argo CD render without reaching a chart repository, and
# .gitignore excludes them (charts/*/charts/, *.tgz), so no commit of this tree carries them: on 2026-11-21 the served
# tree held none, and Argo CD went upstream for every subchart under the cut (9 of 10 Applications sync Unknown,
# tcp/443 denies to the chart repositories' hosts). docs/deployment/airgap.md has the operator commit them under
# TAG-vendored with install/charts-vendored-tag.sh (bootstrap-forge --charts-repo runs it) and name that tag as
# tockmox.revision, so the lane does the same: a checkout of this tree's bytes, tagged as the release, the helper
# run on it, and that tag served as committed. TOCKMOX_SERVE_FORCE_ADD, the harness-only shortcut #329 added, is
# not used here; site-repo-server.sh keeps it for its own test.
REL_TAG="airgap-${TOCKMOX_TEST_VM}"
CHECKOUT="${LANE}/charts-checkout"
rm -rf "$CHECKOUT"; mkdir -p "$CHECKOUT"
( cd "$TREE" && COPYFILE_DISABLE=1 tar cf - --exclude=.git --exclude='._*' . ) | ( cd "$CHECKOUT" && tar xf - ) \
  || fail "could not copy this tree to ${CHECKOUT}"
( cd "$CHECKOUT" && git init -q -b main . && git add -A \
    && git -c user.name=airgap-lane -c user.email=airgap-lane@tockmox.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
         commit -q -m "this tree at ${TOCKMOX_DOCS_REF}" && git tag "$REL_TAG" ) > "${LANE}/charts-checkout.log" 2>&1 \
  || fail "could not make a checkout of this tree tagged ${REL_TAG} (${LANE}/charts-checkout.log)"
VENDORED="$(bash "${TREE}/install/charts-vendored-tag.sh" "$CHECKOUT" "$REL_TAG" 2> "${LANE}/charts-vendored.log")" \
  || fail "install/charts-vendored-tag.sh refused, so the served tree would lack the subchart archives: $(grep -v '^ *$' "${LANE}/charts-vendored.log" | tail -2 | tr '\n' ' ')"
read -r TAG VEN_COMMIT VEN_COUNT <<<"$VENDORED"
case "${VEN_COUNT:-}" in ''|0|*[!0-9]*) fail "install/charts-vendored-tag.sh printed '${VENDORED}': no archive is committed under the served tag" ;; esac
bash "${PROV}/site-repo-server.sh" push-ref "$CHECKOUT" tockmox "$TAG" >/dev/null \
  || fail "site-repo-server.sh push-ref of ${TAG} failed"
TM_URL="$(bash "${PROV}/site-repo-server.sh" url tockmox)"
[ -n "$TM_URL" ] || fail "site-repo-server gave no URL"
echo "airgap lane 7: this tree served at ${TM_URL} @ ${TAG} (${REL_TAG} plus ${VEN_COUNT} vendored subchart archives, ${VEN_COMMIT:0:12})"

# 8. the cut, proven by the positive control
step "8 waiting for the cut"
count() { bash "$EDC" --guest "$GUEST_IP" --since "$1" --until "$2" "${@:3}"; }
# deny_table SINCE UNTIL: the edge's deny lines for the guest over the window, counted and grouped by destination, as
# AIRGAP-DENY lines in the report. Sets DENY_N (the lines the edge logged) and counted (those that count against the
# clause). Step 10 calls it, and finish() on an early end after P09 began. On failure it returns 1 (the edge's log was
# not read) or 2 (its lines could not be grouped), with DENY_WHY, and exits nothing itself.
deny_table() {
  local n_rc=0
  DENY_WHY=""; DENY_N=0; counted=0
  DENY_N="$(count "$1" "$2" --lines 2000 2>"${LANE}/cut-denies.txt")" || n_rc=$?
  if [ "$n_rc" != 0 ]; then
    DENY_WHY="the edge's log could not be read for the cut window (edge-deny-count exit ${n_rc}: $(tail -1 "${LANE}/cut-denies.txt"))"
    return 1
  fi
  note "airgap lane 10: ${DENY_N} deny line(s) for ${GUEST_IP} over the cut window"
  if [ "$DENY_N" -gt 0 ]; then
    if ! python3 - "$GUEST_IP" "$IGNORE" "$DENY_N" "${LANE}/cut-denies.txt" "$GUEST_RANGES" > "${LANE}/cut-by-destination.txt" <<'PY'
import collections, ipaddress, sys
guest, ignore, total, path = sys.argv[1], set(sys.argv[2].split()), int(sys.argv[3]), sys.argv[4]
own = [ipaddress.ip_network(r) for r in sys.argv[5].split()]
def owned(dst):
    try:
        a = ipaddress.ip_address(dst)
    except ValueError:
        return False
    return any(a in r for r in own)
rows = collections.Counter()
seen = 0
for raw in open(path, encoding="utf-8", errors="replace"):
    if not raw.startswith("  deny: "):
        continue
    seen += 1
    t = [x.strip() for x in raw[len("  deny: "):].strip().split(",")]
    key = ("?", "unparsed", "")
    if guest in t:
        i = t.index(guest)
        proto = next((x for x in reversed(t[:i]) if x in ("tcp", "udp", "icmp", "igmp")), "?")
        dst = t[i + 1] if i + 1 < len(t) else "?"
        port = t[i + 3] if proto in ("tcp", "udp") and i + 3 < len(t) else ""
        key = (proto, dst, port)
    rows[key] += 1
bad = 0
for (proto, dst, port), c in rows.most_common():
    mark = " ignored" if f"{proto}/{port}" in ignore else " guest-cluster" if owned(dst) else ""
    bad += 0 if mark else c
    print(f"AIRGAP-DENY {proto} {dst}{':' + port if port else ''} {c}{mark}")
unread = max(0, total - seen)
if unread:
    print(f"AIRGAP-DENY ? unread {unread}")
    bad += unread
print(f"COUNTED {bad}")
PY
    then
      DENY_WHY="the cut window's deny lines could not be grouped"
      return 2
    fi
    grep '^AIRGAP-DENY' "${LANE}/cut-by-destination.txt" | tee -a "$REPORT"
    counted="$(sed -n 's/^COUNTED //p' "${LANE}/cut-by-destination.txt")"
  fi
  note "airgap lane 10: ${counted} deny line(s) count against the clause (ignored: ${IGNORE:-none}; the guest cluster's own: ${GUEST_RANGES})"
}

echo "AIRGAP-PAUSE make the cut now: ${TOCKMOX_AIRGAP_CUT_HINT}. Waiting up to ${CUT_WAIT}s; the lane goes on by itself once the guest is refused and the edge logs it."
deadline=$(( $(date +%s) + CUT_WAIT ))
silent=0
while :; do
  c0="$(date -u -d '-1 second' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || now)"
  ans="$(gexec "curl -sS -m 10 -o /dev/null https://${CONTROL_HOST}/v2/ && echo AIRGAP-CONTROL-REACHED || echo AIRGAP-CONTROL-REFUSED" 2>/dev/null || true)"
  case "$ans" in
    *AIRGAP-CONTROL-REFUSED*)
      sleep "$SETTLE"
      c1="$(now)"
      n_rc=0; n="$(count "$c0" "$c1" 2>"${LANE}/control-count.err")" || n_rc=$?
      [ "$n_rc" = 0 ] || infra "the edge's log could not be read for the control (edge-deny-count exit ${n_rc}: $(tail -1 "${LANE}/control-count.err"))"
      if [ "$n" -ge 1 ]; then
        note "AIRGAP-CUT proven: the guest was refused ${CONTROL_HOST} and the edge logged ${n} deny line(s), ${c0} to ${c1}"
        break
      fi
      silent=$((silent + 1))
      echo "airgap lane 8: the guest was refused, but the edge logged no deny line for it (${silent} of 3)"
      [ "$silent" -lt 3 ] || fail "the guest is refused but the edge logs no deny line for it, so the counter cannot count and a zero would mean nothing"
      ;;
    *AIRGAP-CONTROL-REACHED*) ;;
    *) infra "the guest did not answer the positive control" ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || blocked "the cut was not made within ${CUT_WAIT}s: the guest still reaches ${CONTROL_HOST}. ${TOCKMOX_AIRGAP_CUT_HINT}"
  sleep "$POLL"
done

# 9. P09, under the cut
step "9 P09 under the cut"
NODE_IP="$(kubectl --context="$KUBE_CONTEXT" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
[ -n "$NODE_IP" ] || fail "the throwaway reports no node InternalIP"
# TOCKMOX_P09_AIRGAPPED: P09 also sets global.airGapped where airgap.md says to, so the cut run has the values the page
# gives a disconnected site, not only install.md's.
export TOCKMOX_P09_ROUTE=built-in TOCKMOX_P09_FROM_TREE=1 TOCKMOX_P09_AIRGAPPED=1
export TOCKMOX_P09_TOCKMOX_REPO_URL="$TM_URL" TOCKMOX_P09_TOCKMOX_REVISION="$TAG" TOCKMOX_P09_TOCKMOX_CLONE="$TREE"
export TOCKMOX_P09_STATE="${LANE}/p09-state" TOCKMOX_P09_BUDGET="$P09_BUDGET_S"
export TOCKMOX_P09_LAN_CIDR="${TOCKMOX_P09_LAN_CIDR:-${NODE_IP%.*}.0/24}"
export TOCKMOX_P09_POOL="${TOCKMOX_P09_POOL:-${NODE_IP%.*}.240-${NODE_IP%.*}.250}"
race_sampler_start || true
T0="$(now)"
INSTALL_STARTED=1
echo "airgap lane 9: P09 under the cut, from ${T0}, bounded at ${P09_WALL}s"
rm -f "${LANE}/p09-bound"
set +e
bounded "$P09_WALL" "${LANE}/p09-bound" bash "${HERE}/run.sh" P09
P09_RC=$?
set -e
P09_BOUND=0
if [ -e "${LANE}/p09-bound" ]; then
  P09_BOUND=1
  newest="$(python3 -c 'import os, sys
d = sys.argv[1]
f = [(os.path.getmtime(os.path.join(d, x)), x) for x in os.listdir(d)] if os.path.isdir(d) else []
print(max(f)[1] if f else "")' "${TOCKMOX_P09_STATE}" 2>/dev/null || true)"
  note "AIRGAP-P09-BOUND P09 ran past its bound of ${P09_WALL}s and was stopped (its budget ${P09_BUDGET_S}s is checked only between its steps); last state written: ${newest:-none}"
fi
sleep "$SETTLE"
T1="$(now)"
note "AIRGAP-WINDOW ${T0} ${T1} guest ${GUEST_IP}"

# The outcome P09 declared, not its exit status: run.sh exits 0 for a path that declared BLOCKED.
p09_rec="MISSING no receipt for P09 in the newest run"
d=""; for g in "${TOCKMOX_WORKDIR}"/receipts-*; do [ -d "$g" ] && d="$g"; done
if [ -n "$d" ] && [ -s "${d}/P09-install-md-end-to-end" ]; then
  read -r o r < "${d}/P09-install-md-end-to-end" || true
  p09_rec="${o:-MISSING} ${r:-}"
fi
note "airgap lane 9: P09 exit ${P09_RC}, declared ${p09_rec}"
race_sampler_stop || true
race_services || true
image_ids || true

# 10. the edge's denies over the cut window, by destination
step "10 count the edge's denies"
dt_rc=0
deny_table "$T0" "$T1" || dt_rc=$?
DENY_DONE=1
case "$dt_rc" in 0) ;; 1) infra "$DENY_WHY" ;; *) fail "$DENY_WHY" ;; esac
n="$DENY_N"
race_verdict "$n" || true

# 11. the judgment; finish() destroys the throwaway and prints AIRGAP-RESULT
[ "$P09_BOUND" = 0 ] || infra "P09 did not finish within its bound of ${P09_WALL}s and was stopped (AIRGAP-P09-BOUND above); the AIRGAP-DENY lines cover the cut window up to then"
if [ "$P09_RC" != 0 ] || [ "${p09_rec%% *}" != PASS ]; then
  case "${p09_rec%% *}" in
    BLOCKED) blocked "P09 declared ${p09_rec}" ;;
    INFRA_ERROR) infra "P09 declared ${p09_rec}" ;;
    *) fail "P09 did not pass under the cut (exit ${P09_RC}, ${p09_rec})" ;;
  esac
fi
[ "$counted" = 0 ] || fail "the install reached past the edge under the cut: ${counted} deny line(s) outside ${IGNORE:-nothing ignored} and the guest cluster's own ranges (the AIRGAP-DENY lines above name where)"
note "airgap lane: the clause holds: P09 passed from the mirror alone, and the edge refused nothing the clause counts"

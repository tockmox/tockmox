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
#      have nothing to refuse or count, and a zero would mean nothing
#   4. mirror-tls and mirror-proof both PASS: one verified TLS round trip from the node to the mirror, and the mirror is
#      the node's only registry
#   5. the guest is quieted (apt timers, unattended upgrades, snap refresh, motd news), so the denies under the cut are
#      the install's
#   6. run.sh P04 P05 (Argo CD, sealed-secrets), the state install.md starts from, from the mirror
#   7. this tree served from inside the throwaway (site-repo-server.sh)
#   8. THE CUT. The lane prints one AIRGAP-PAUSE line naming what the operator switches (TOCKMOX_AIRGAP_CUT_HINT), then
#      runs the positive control every TOCKMOX_AIRGAP_POLL seconds: the guest asks an upstream registry directly. While
#      that request is answered the cut is not made. When it is refused, the edge must have logged a deny line for the
#      guest within the same window; only then is the cut proven, and the counter proven able to count. A refusal with
#      no deny line, three times, is a FAIL (the counter cannot count); no refusal within TOCKMOX_AIRGAP_CUT_WAIT
#      seconds is BLOCKED (the cut was never made)
#   9. run.sh P09 (built-in route, this tree's install.md), timed: the cut window
#  10. the edge's deny lines for the guest over the cut window, counted and grouped by destination. A deny whose
#      protocol and port are on TOCKMOX_AIRGAP_IGNORE (default udp/123, the OS's time sync) is reported and does not
#      fail the clause; any other deny does, and the line names where the install reached
#  11. destroy the throwaway, unless TOCKMOX_KEEP_CLUSTER=1
#
# THE CLAUSE PASSES when P09 declared PASS and the edge refused nothing for the guest over the cut window outside
# TOCKMOX_AIRGAP_IGNORE. Every count is printed, ignored ones included.
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
#   TOCKMOX_AIRGAP_STALL (default 300 s, 2 to 3600: an AIRGAP-STALL line when the run has written nothing for that long),
#   TOCKMOX_KEEP_CLUSTER.
#
# WHAT IT PRINTS for a caller to grep: AIRGAP-PAUSE, AIRGAP-CUT (the control's proof), AIRGAP-WINDOW,
# AIRGAP-DENY <proto> <destination>:<port> <count> [ignored], AIRGAP-STALL, and last AIRGAP-RESULT <outcome>.
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
RESULT=""
CREATED=0
INSTALL_STARTED=0
STALL_PID=""
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
CONTROL_HOST="${TOCKMOX_AIRGAP_CONTROL_HOST:-registry-1.docker.io}"
[[ "$CONTROL_HOST" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]] || refuse "TOCKMOX_AIRGAP_CONTROL_HOST must be a host name"
IGNORE="${TOCKMOX_AIRGAP_IGNORE-udp/123}"
for i in $IGNORE; do
  [[ "$i" =~ ^(tcp|udp)/[0-9]{1,5}$ ]] || refuse "TOCKMOX_AIRGAP_IGNORE holds proto/port pairs (udp/123), not: ${i}"
done
KEEP="${TOCKMOX_KEEP_CLUSTER:-0}"
case "$KEEP" in 0|1) ;; *) refuse "TOCKMOX_KEEP_CLUSTER must be 0 or 1" ;; esac
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
  [ -n "$RESULT" ] || case "$rc" in 0) RESULT=PASS ;; 2) RESULT=REFUSED ;; 4) RESULT=BLOCKED ;; 5) RESULT=INFRA_ERROR ;; *) RESULT=FAIL ;; esac
  [ -z "$STOPPED" ] || printf '%s\n' "$STOPPED" >> "$REPORT"
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
        p=os.path.join(d,f)
        try: best=max(best,(os.path.getmtime(p),p))
        except OSError: pass
if best[1]: print("%d %s" % best)' "$TOCKMOX_WORKDIR" 2>/dev/null || true)"
    [ -n "$newest" ] || continue
    age=$(( $(date +%s) - ${newest%% *} ))
    if [ "$age" -ge "$STALL" ] && [ "$warned" != "${newest%% *}" ]; then
      warned="${newest%% *}"
      echo "AIRGAP-STALL ${age}s with nothing written, in step '$(cat "${LANE}/step" 2>/dev/null || echo unknown)'; newest file: ${newest#* }"
    fi
  done
}
stall_watch & STALL_PID=$!

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
create_rc=0
out="$(bash "${PROV}/throwaway-cluster.sh" create)" || create_rc=$?
case "$create_rc" in
  0) ;;
  4) blocked "create refused: the rig is full (its capacity gate)" ;;
  5) infra "create could not read the rig (exit 5)" ;;
  *) CREATED=1; fail "create failed (exit ${create_rc})" ;;
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

# 7. this tree, served from inside the throwaway
step "7 serve this tree"
TAG="airgap-${TOCKMOX_TEST_VM}"
bash "${PROV}/site-repo-server.sh" up >/dev/null || fail "site-repo-server.sh up failed"
bash "${PROV}/site-repo-server.sh" push "$TREE" tockmox "$TAG" >/dev/null || fail "site-repo-server.sh push failed"
TM_URL="$(bash "${PROV}/site-repo-server.sh" url tockmox)"
[ -n "$TM_URL" ] || fail "site-repo-server gave no URL"
echo "airgap lane 7: this tree served at ${TM_URL} @ ${TAG}"

# 8. the cut, proven by the positive control
step "8 waiting for the cut"
count() { bash "$EDC" --guest "$GUEST_IP" --since "$1" --until "$2" "${@:3}"; }
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
export TOCKMOX_P09_ROUTE=built-in TOCKMOX_P09_FROM_TREE=1
export TOCKMOX_P09_TOCKMOX_REPO_URL="$TM_URL" TOCKMOX_P09_TOCKMOX_REVISION="$TAG" TOCKMOX_P09_TOCKMOX_CLONE="$TREE"
export TOCKMOX_P09_STATE="${LANE}/p09-state" TOCKMOX_P09_BUDGET="${TOCKMOX_P09_BUDGET:-3000}"
export TOCKMOX_P09_LAN_CIDR="${TOCKMOX_P09_LAN_CIDR:-${NODE_IP%.*}.0/24}"
export TOCKMOX_P09_POOL="${TOCKMOX_P09_POOL:-${NODE_IP%.*}.240-${NODE_IP%.*}.250}"
T0="$(now)"
INSTALL_STARTED=1
echo "airgap lane 9: P09 under the cut, from ${T0}"
set +e
bash "${HERE}/run.sh" P09
P09_RC=$?
set -e
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

# 10. the edge's denies over the cut window, by destination
step "10 count the edge's denies"
n_rc=0
n="$(count "$T0" "$T1" --lines 2000 2>"${LANE}/cut-denies.txt")" || n_rc=$?
[ "$n_rc" = 0 ] || infra "the edge's log could not be read for the cut window (edge-deny-count exit ${n_rc}: $(tail -1 "${LANE}/cut-denies.txt"))"
note "airgap lane 10: ${n} deny line(s) for ${GUEST_IP} over the cut window"
counted=0
if [ "$n" -gt 0 ]; then
  python3 - "$GUEST_IP" "$IGNORE" "$n" "${LANE}/cut-denies.txt" > "${LANE}/cut-by-destination.txt" <<'PY' || fail "the cut window's deny lines could not be grouped"
import collections, sys
guest, ignore, total, path = sys.argv[1], set(sys.argv[2].split()), int(sys.argv[3]), sys.argv[4]
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
    ign = f"{proto}/{port}" in ignore
    bad += 0 if ign else c
    print(f"AIRGAP-DENY {proto} {dst}{':' + port if port else ''} {c}{' ignored' if ign else ''}")
unread = max(0, total - seen)
if unread:
    print(f"AIRGAP-DENY ? unread {unread}")
    bad += unread
print(f"COUNTED {bad}")
PY
  grep '^AIRGAP-DENY' "${LANE}/cut-by-destination.txt" | tee -a "$REPORT"
  counted="$(sed -n 's/^COUNTED //p' "${LANE}/cut-by-destination.txt")"
fi
note "airgap lane 10: ${counted} deny line(s) count against the clause (ignored: ${IGNORE:-none})"

# 11. the judgment; finish() destroys the throwaway and prints AIRGAP-RESULT
if [ "$P09_RC" != 0 ] || [ "${p09_rec%% *}" != PASS ]; then
  case "${p09_rec%% *}" in
    BLOCKED) blocked "P09 declared ${p09_rec}" ;;
    INFRA_ERROR) infra "P09 declared ${p09_rec}" ;;
    *) fail "P09 did not pass under the cut (exit ${P09_RC}, ${p09_rec})" ;;
  esac
fi
[ "$counted" = 0 ] || fail "the install reached past the edge under the cut: ${counted} deny line(s) outside ${IGNORE:-nothing ignored} (the AIRGAP-DENY lines above name where)"
note "airgap lane: the clause holds: P09 passed from the mirror alone, and the edge refused nothing the clause counts"

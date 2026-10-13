#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE ADVERSARIAL NETWORKPOLICY HARNESS (TM-0273). Plants probe pods in TWO of
# the six namespaces the shipped policy set guards (tockmox-ai and
# tockmox-monitoring ... the two the card's findings name) on a LIVE cluster,
# and asserts, in both directions, what the policies actually let through ...
# not what their selectors match (tools/check-netpol-selectors.sh), and not
# what their comments say. The other four guarded namespaces are not probed
# yet; that gap is stated at the bottom, not implied away.
#
# WHY THIS EXISTS. On 2026-09-01 an outside reviewer read the policy templates
# as an attacker and found egress unrestricted everywhere except Open WebUI,
# plus three ingress rules wider than they read. The reviewer executed nothing
# and said so. Everything here was first measured by hand on 2026-09-06 on a
# throwaway k3s (Tockmox/EVIDENCE-2026-09-06-TM0273-egress-measure.log); this
# script is that measurement made repeatable, so each fix on the card lands
# against an assertion instead of a diff.
#
# HOW THE KNOWN LEAKS ARE ENCODED, and why the run is honest today. A path that
# must be CLOSED but is open today is asserted with assert_artifact_xfail: it
# reads XFAIL now, and the day a fix closes it the harness goes RED ("a known
# defect has started passing") so someone re-reads the card and promotes the
# line to assert_artifact. A leak that is never asserted at all is the thing
# this repo keeps getting caught by; a leak asserted as a fact is a gate.
#
# WHAT IT NEEDS. KUBECONFIG pointed at a cluster that already has the policy
# layer applied: it refuses, exit 2, unless BOTH probed namespaces carry the
# shipped default-deny-ingress (the harness asserts, the caller installs, and
# it never creates a guarded namespace itself). It first proves the CNI
# ENFORCES egress policies at all, because on a non-enforcing CNI every
# "BLOCKED" below would be a lie; a non-enforcing substrate is a SKIP, not a
# pass.
#
# ONE LIMIT OF THE XFAIL ENCODING, stated: an assertion reads its probe's
# stdout, so a `kubectl exec` that fails for an unrelated reason (image pull,
# evicted pod) yields an error string, which is "not BLOCKED", which an xfail
# line reports as ... expected. Read the ACTUAL: line of any xfail before
# believing it; the must-pass lines around it will usually go red first.
#
# NEVER run this against a cluster you care about: it creates namespaces and
# pods. The throwaway lane is the host (tests/executed-docs/provision/).
#
# THE FIXES ARE VALUES-DEPENDENT, so the assertions are too (TM-0273 0.7.0).
# A leak stays an assert_artifact_xfail until the caller says the fix's values
# are applied to the cluster under test, and then it is a hard assert_artifact:
#
#   TOCKMOX_EXPECT_AI_EGRESS_DENY=1   fix 1: the AI namespace egress default-deny
#                                     (the default in 0.7.0; set when the
#                                     cluster carries default-deny-egress)
#   TOCKMOX_EXPECT_NODE_SOURCES=1     fixes 3 and 4: platformNetpol.nodeOriginSources
#                                     is set, so allow-from-node-network no longer
#                                     admits the clusterCIDR
#
# The caller states this rather than the harness detecting it from the
# cluster, on purpose: a harness that infers "the fix is present" from the
# presence of the fix's own objects cannot notice the fix silently missing.
# The hole this pins was MEASURED 2026-09-29 on kube-router: a pod in
# namespace `default` reached the object store's admin port 3903 (HTTP 200) and
# S3 port 3900 (403) through the platform namespace's default-deny.
# TOCKMOX_SKIP_LITELLM_PROVIDER=1 skips the one assertion that assumes the
# default aiEgress.litellm.providerAllow (TCP 443 anywhere outside the cluster).
#
# Exit: 0 all must-pass assertions pass (xfails allowed); 1 a real failure or a
# known defect that started passing; 2 skipped (no cluster / policy layer
# absent / CNI does not enforce).
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/executed-docs/lib/assert.sh
# TM-0797: every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"
: "${ASSERT_REPORT:=}"

AI_NS="${TOCKMOX_NS_AI:-tockmox-ai}"
MON_NS="${TOCKMOX_NS_MONITORING:-tockmox-monitoring}"
PLAT_NS="${TOCKMOX_NS_PLATFORM:-tockmox-platform}"
OUT_NS="${TOCKMOX_NS_OUTSIDE:-default}"   # an UNGUARDED namespace: the measured attacker
EXPECT_AI_DENY="${TOCKMOX_EXPECT_AI_EGRESS_DENY:-0}"
EXPECT_NODE_SRC="${TOCKMOX_EXPECT_NODE_SOURCES:-0}"
SCRATCH="tockmox-netpol-probe"
EXT_HOST="${TOCKMOX_EXTERNAL_PROBE_HOST:-1.1.1.1}"   # any always-listening external :443
EXT_PORT=443
IMG="${TOCKMOX_PROBE_IMAGE:-alpine:3.20}"

path_begin "netpol-adversary" \
  "what the shipped NetworkPolicy set actually admits and denies, measured from probe pods, both directions"

need() { command -v "$1" >/dev/null 2>&1 || { _emit "SKIPPED: '$1' not on PATH"; exit 2; }; }
need kubectl

if ! kubectl --context="$KUBE_CONTEXT" get nodes >/dev/null 2>&1; then
  _emit "SKIPPED: no reachable cluster on KUBECONFIG=${KUBECONFIG:-<unset>}"
  exit 2
fi
# Both probed namespaces must carry the SHIPPED policy set. The harness never
# creates a guarded namespace itself: an assertion about an empty namespace it
# made would be a tautology, and ... worse ... the monitoring xfail below would
# stay "expected" forever, straight through the fix it exists to detect
# (zero-context review, 2026-09-07).
for ns in "$AI_NS" "$MON_NS"; do
  if ! kubectl --context="$KUBE_CONTEXT" get ns "$ns" >/dev/null 2>&1 || ! kubectl --context="$KUBE_CONTEXT" -n "$ns" get netpol default-deny-ingress >/dev/null 2>&1; then
    _emit "SKIPPED: the policy layer is not applied here (no ${ns}/default-deny-ingress)."
    _emit "         Apply charts/tockmox-policy first; this harness asserts, it does not install."
    exit 2
  fi
done

# A read command that prints REACHED or BLOCKED for a TCP connect from a pod.
# -w4 bounds a denied path to a 4s timeout so a blocked probe is fast and
# unambiguous; a policy-denied connect never RSTs, it just never answers.
tcp_from() { # tcp_from <ns> <pod> <host> <port>
  printf 'kubectl --context="$KUBE_CONTEXT" -n %s exec %s -- sh -c "nc -z -w4 %s %s >/dev/null 2>&1 && echo REACHED || echo BLOCKED"' "$1" "$2" "$3" "$4"
}
dns_from() { # dns_from <ns> <pod>
  # THE FQDN, DELIBERATELY. busybox nslookup (alpine) does not apply the
  # resolv.conf search path to a short name, so `nslookup kubernetes.default`
  # returns NXDOMAIN on a perfectly healthy cluster (measured 2026-09-06, no
  # policy in the way). A probe that fails in BOTH the healthy and the broken
  # state cannot tell them apart, and the first draft of this harness reported
  # "DNS broken" for exactly that reason. The FQDN resolves when DNS works and
  # fails when an egress policy cuts kube-dns:53, which is the discrimination
  # this assertion exists for.
  printf 'kubectl --context="$KUBE_CONTEXT" -n %s exec %s -- sh -c "nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo RESOLVES || echo NXDOMAIN"' "$1" "$2"
}
plant() { # plant <ns> <name> [label=value ...] ; a sleeping probe pod
  local ns="$1" name="$2"; shift 2
  local labels=""
  [ $# -gt 0 ] && labels="--labels=$(IFS=,; echo "$*")"
  kubectl --context="$KUBE_CONTEXT" -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl --context="$KUBE_CONTEXT" -n "$ns" run "$name" --image="$IMG" --restart=Never $labels --command -- sleep 1800 >/dev/null 2>&1
}
listener() { # listener <ns> <name> <port> [label=value ...] ; a pod accepting TCP
  local ns="$1" name="$2" port="$3"; shift 3
  local labels=""
  [ $# -gt 0 ] && labels="--labels=$(IFS=,; echo "$*")"
  kubectl --context="$KUBE_CONTEXT" -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl --context="$KUBE_CONTEXT" -n "$ns" run "$name" --image="$IMG" --restart=Never $labels --command -- \
    sh -c "while true; do nc -l -p $port -e /bin/true >/dev/null 2>&1 || nc -l -p $port >/dev/null 2>&1; done" >/dev/null 2>&1
}
# fix_assert <expect-flag> <description> <actual> <expected>: a hard assertion
# once the fix's values are declared applied, a pinned known defect until then.
fix_assert() {
  if [ "$1" = "1" ]; then assert_artifact "$2" "$3" "$4"
  else assert_artifact_xfail "$2 (fix not declared applied)" "$3" "$4"; fi
}
pod_ip_by_label() { kubectl --context="$KUBE_CONTEXT" -n "$1" get pod -l "$2" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null; }
ready() { kubectl --context="$KUBE_CONTEXT" -n "$1" wait --for=condition=Ready "pod/$2" --timeout=90s >/dev/null 2>&1; }
pod_ip() { kubectl --context="$KUBE_CONTEXT" -n "$1" get pod "$2" -o jsonpath='{.status.podIP}' 2>/dev/null; }

cleanup() {
  kubectl --context="$KUBE_CONTEXT" delete ns "$SCRATCH" --ignore-not-found --wait=false >/dev/null 2>&1
  for p in probe-plain probe-owui probe-cnpg probe-litellm listen-ai; do kubectl --context="$KUBE_CONTEXT" -n "$AI_NS" delete pod "$p" --ignore-not-found --wait=false >/dev/null 2>&1; done
  kubectl --context="$KUBE_CONTEXT" -n "$MON_NS" delete pod probe-mon probe-prom --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl --context="$KUBE_CONTEXT" -n "$OUT_NS" delete pod probe-outside --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl --context="$KUBE_CONTEXT" -n "$PLAT_NS" delete pod probe-plat --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0. SUBSTRATE: does this CNI enforce egress NetworkPolicies at all?
# ---------------------------------------------------------------------------
_emit "--- 0. substrate: CNI enforcement ------------------------------------"
# The previous run's cleanup deletes the scratch namespace with --wait=false so
# the harness exits fast; a namespace stays Terminating for a few seconds after
# that and refuses new pods. Back-to-back runs (measured 2026-09-06) then
# SKIPPED with "scratch probe never became Ready", which reads like a broken
# substrate. Wait for the old one to be gone, bounded, before creating anew.
deadline=$(( $(date +%s) + 90 ))
while kubectl --context="$KUBE_CONTEXT" get ns "$SCRATCH" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    _emit "SKIPPED: scratch namespace ${SCRATCH} is stuck Terminating from a previous run"
    exit 2
  fi
  sleep 3
done
kubectl --context="$KUBE_CONTEXT" create ns "$SCRATCH" >/dev/null 2>&1 || true
plant "$SCRATCH" probe
if ! ready "$SCRATCH" probe; then _emit "SKIPPED: scratch probe never became Ready"; exit 2; fi
base="$(eval "$(tcp_from "$SCRATCH" probe "$EXT_HOST" "$EXT_PORT")" 2>/dev/null)"
if [ "$base" != "REACHED" ]; then
  _emit "SKIPPED: a policy-free pod cannot reach ${EXT_HOST}:${EXT_PORT} (got '${base}')."
  _emit "         Without a reachable external target, BLOCKED would prove nothing."
  exit 2
fi
cat <<EOF | kubectl --context="$KUBE_CONTEXT" apply -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-egress, namespace: ${SCRATCH} }
spec: { podSelector: {}, policyTypes: [Egress] }
EOF
sleep 5
# Read the verdict for THIS assertion, not the cumulative counter: ASSERT_FAIL
# is a running total, and reading it here would turn any earlier failure into
# a SKIP, the worst direction (zero-context review, 2026-09-07).
fails_before=$ASSERT_FAIL
assert_artifact "CNI enforces egress: a pod behind deny-all-egress cannot reach ${EXT_HOST}:${EXT_PORT}" \
  "$(tcp_from "$SCRATCH" probe "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
if [ "$ASSERT_FAIL" -ne "$fails_before" ]; then
  _emit "SKIPPED: this CNI does not enforce egress NetworkPolicies; nothing below would be meaningful."
  _emit "         (If TOCKMOX_PROBE_IMAGE was overridden: the probe needs a BusyBox nc that accepts -z.)"
  exit 2
fi

# ---------------------------------------------------------------------------
# 1. PLANT the adversaries in the guarded namespaces
# ---------------------------------------------------------------------------
_emit "--- 1. plant probes ---------------------------------------------------"
plant    "$AI_NS"  probe-plain
plant    "$AI_NS"  probe-owui  "app.kubernetes.io/component=open-webui"
listener "$AI_NS"  listen-ai   8080
plant    "$MON_NS" probe-mon
# Labelled stand-ins: a CNPG pod (cnpg.io/cluster), the model gateway, and the
# Prometheus pod. The policies select by label, so the label IS the identity.
plant    "$AI_NS"  probe-cnpg    "cnpg.io/cluster=netpol-probe"
plant    "$AI_NS"  probe-litellm "app.kubernetes.io/name=litellm"
plant    "$MON_NS" probe-prom    "app.kubernetes.io/name=prometheus"
# The measured attacker: an ordinary pod in an UNGUARDED namespace. Planted only
# if the platform namespace carries the shipped policy set and the object store
# is there; otherwise section 4 is skipped and says so.
PLAT_GARAGE_IP=""; PLAT_CERTMGR_IP=""
if kubectl --context="$KUBE_CONTEXT" -n "$PLAT_NS" get netpol default-deny-ingress >/dev/null 2>&1; then
  PLAT_GARAGE_IP="$(pod_ip_by_label "$PLAT_NS" app.kubernetes.io/name=tockmox-garage)"
  PLAT_CERTMGR_IP="$(pod_ip_by_label "$PLAT_NS" app.kubernetes.io/name=cert-manager)"
fi
if [ -n "$PLAT_GARAGE_IP" ]; then
  plant "$OUT_NS"  probe-outside
  plant "$PLAT_NS" probe-plat
fi
for p in "$AI_NS/probe-plain" "$AI_NS/probe-owui" "$AI_NS/listen-ai" "$MON_NS/probe-mon" \
         "$AI_NS/probe-cnpg" "$AI_NS/probe-litellm" "$MON_NS/probe-prom"; do
  if ! ready "${p%/*}" "${p#*/}"; then _emit "SKIPPED: ${p} never became Ready"; exit 2; fi
done
if [ -n "$PLAT_GARAGE_IP" ]; then
  for p in "$OUT_NS/probe-outside" "$PLAT_NS/probe-plat"; do
    if ! ready "${p%/*}" "${p#*/}"; then _emit "SKIPPED: ${p} never became Ready"; exit 2; fi
  done
fi
AI_LISTENER_IP="$(pod_ip "$AI_NS" listen-ai)"
# An empty listener address would make every ingress probe read BLOCKED for
# the wrong reason and pass the denial assertion spuriously. Refuse instead.
if [ -z "$AI_LISTENER_IP" ]; then
  _emit "SKIPPED: ${AI_NS}/listen-ai has no pod IP; the ingress assertions would be meaningless."
  exit 2
fi
_emit "listener ${AI_NS}/listen-ai at ${AI_LISTENER_IP}:8080"
_emit ""

# ---------------------------------------------------------------------------
# 2. EGRESS ... the card's central finding
# ---------------------------------------------------------------------------
_emit "--- 2. egress ----------------------------------------------------------"
# TM-0273 fix 1: an ordinary AI-namespace workload must have no egress to the
# internet. A hard assertion once TOCKMOX_EXPECT_AI_EGRESS_DENY=1.
fix_assert "$EXPECT_AI_DENY" "egress: ${AI_NS} plain workload -> external ${EXT_HOST}:${EXT_PORT} (fix 1 target)" \
  "$(tcp_from "$AI_NS" probe-plain "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
# The one contained path today, and it must stay contained.
assert_artifact "egress: ${AI_NS} open-webui -> external ${EXT_HOST}:${EXT_PORT} is contained" \
  "$(tcp_from "$AI_NS" probe-owui "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
# KNOWN DEFECT (TM-0273 census): monitoring has unrestricted egress.
assert_artifact_xfail "egress: ${MON_NS} workload -> external ${EXT_HOST}:${EXT_PORT}" \
  "$(tcp_from "$MON_NS" probe-mon "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
# A CNPG pod may reach the Kubernetes API and the object store and NOTHING else.
fix_assert "$EXPECT_AI_DENY" "egress: ${AI_NS} CNPG-labelled pod -> external ${EXT_HOST}:${EXT_PORT}" \
  "$(tcp_from "$AI_NS" probe-cnpg "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
# The gateway keeps its provider path (default providerAllow: TCP 443 outside
# the cluster, service and LAN ranges). Only meaningful once the deny is on.
if [ "$EXPECT_AI_DENY" = "1" ] && [ "${TOCKMOX_SKIP_LITELLM_PROVIDER:-0}" != "1" ]; then
  assert_artifact "egress: ${AI_NS} gateway-labelled pod -> external ${EXT_HOST}:${EXT_PORT} stays open (providerAllow default)" \
    "$(tcp_from "$AI_NS" probe-litellm "$EXT_HOST" "$EXT_PORT")" "REACHED"
fi
# DNS must keep working for a plain AI pod. This is the line that turns red if
# fix 1 ships as a bare default-deny with no kube-dns allow (measured
# 2026-09-06: it does).
assert_artifact "egress: ${AI_NS} plain workload can still resolve DNS (a fix must not break this)" \
  "$(dns_from "$AI_NS" probe-plain)" "RESOLVES"

# ---------------------------------------------------------------------------
# 3. INGRESS ... default-deny-ingress + the allow set, from the outside and in
# ---------------------------------------------------------------------------
_emit "--- 3. ingress ---------------------------------------------------------"
# From another guarded namespace, unlabelled: default-deny-ingress must hold.
# (allow-prometheus-scrape admits only prometheus-labelled monitoring pods.)
assert_artifact "ingress: ${MON_NS} unlabelled pod -> ${AI_NS} listener :8080 is denied" \
  "$(tcp_from "$MON_NS" probe-mon "$AI_LISTENER_IP" 8080)" "BLOCKED"
# Same namespace: allow-intra-namespace must admit it.
assert_artifact "ingress: ${AI_NS} pod -> ${AI_NS} listener :8080 is admitted (intra-namespace)" \
  "$(tcp_from "$AI_NS" probe-plain "$AI_LISTENER_IP" 8080)" "REACHED"

# ---------------------------------------------------------------------------
# 4. THE PLATFORM NAMESPACE ... the measured hole (fix 4) and its collaterals
# ---------------------------------------------------------------------------
_emit "--- 4. platform namespace ingress -------------------------------------"
if [ -z "$PLAT_GARAGE_IP" ]; then
  _emit "SKIPPED (section only): ${PLAT_NS} has no default-deny-ingress or no object-store pod;"
  _emit "         the node-network / scrape / S3 assertions below need the shipped platform layer."
else
  _emit "object store at ${PLAT_GARAGE_IP}; attacker probe in namespace ${OUT_NS}"
  # POSITIVE CONTROL FIRST. An in-namespace pod is admitted by
  # allow-intra-namespace, so this proves the admin port is live at this
  # address; without it the BLOCKED lines below could be a wrong address.
  assert_artifact "control: ${PLAT_NS} pod -> object store admin :3903 is admitted (intra-namespace; proves the port is live)" \
    "$(tcp_from "$PLAT_NS" probe-plat "$PLAT_GARAGE_IP" 3903)" "REACHED"
  # THE MEASURED HOLE. Pod in `default` -> Garage admin 3903 (HTTP 200) and S3
  # 3900 (403) through allow-from-node-network's clusterCIDR ipBlock.
  fix_assert "$EXPECT_NODE_SRC" "ingress: pod in ${OUT_NS} -> ${PLAT_NS} object store admin :3903 (fix 4, the measured hole)" \
    "$(tcp_from "$OUT_NS" probe-outside "$PLAT_GARAGE_IP" 3903)" "BLOCKED"
  fix_assert "$EXPECT_NODE_SRC" "ingress: pod in ${OUT_NS} -> ${PLAT_NS} object store S3 :3900 (fix 4)" \
    "$(tcp_from "$OUT_NS" probe-outside "$PLAT_GARAGE_IP" 3900)" "BLOCKED"
  # Fix 3: a Prometheus-labelled pod may reach metrics ports and not the admin
  # port. Observable only once fix 4 removes the clusterCIDR block, which
  # admits the Prometheus pod's own address on every port.
  fix_assert "$EXPECT_NODE_SRC" "ingress: Prometheus-labelled pod -> ${PLAT_NS} object store admin :3903 (fix 3)" \
    "$(tcp_from "$MON_NS" probe-prom "$PLAT_GARAGE_IP" 3903)" "BLOCKED"
  if [ -n "$PLAT_CERTMGR_IP" ]; then
    assert_artifact "ingress: Prometheus-labelled pod -> cert-manager metrics :9402 stays admitted (scrape must not break)" \
      "$(tcp_from "$MON_NS" probe-prom "$PLAT_CERTMGR_IP" 9402)" "REACHED"
  else
    _emit "note: no cert-manager pod found; the scrape-still-works control was not run"
  fi
  # The collateral of fix 4: backups write to the object store from the AI
  # namespace. If the S3 allow is missing, narrowing the node-network rule
  # breaks them, and this line is where it shows.
  assert_artifact "ingress+egress: ${AI_NS} CNPG-labelled pod -> ${PLAT_NS} object store S3 :3900 stays admitted (backups)" \
    "$(tcp_from "$AI_NS" probe-cnpg "$PLAT_GARAGE_IP" 3900)" "REACHED"
fi

does_not_prove \
  "anything in the four guarded namespaces NOT probed here (tockmox-authentik, -devops, -platform, -selfcheck): the same egress finding applies to them by the census and none of it is measured yet" \
  "that node-originated traffic STILL gets in once nodeOriginSources is set: a probe pod cannot send from a node's cni0/flannel.1 address. The webhook, kubelet-to-CSI and MetalLB paths are proven only by a real certificate issuance, a volume attach and a LoadBalancer request on the cluster (the doc says which)" \
  "the diagnostic identity's API narrowing (fix 2): it needs a probe in the diagnostic namespace and a site-specific decoy address on the LAN, which a generic harness does not have" \
  "labels are the identity here: probe-cnpg, probe-litellm and probe-prom carry the label the policies select on, they are not the real pods. That the real CNPG instance manager, barman sidecar and LiteLLM pod complete their work under the deny is proven only by a Cluster reporting healthy, a Backup completing and a completion returning" \
  "the fixes without their values: with the TOCKMOX_EXPECT_* flags unset, the fixed lines are pinned xfail and prove only that the leak is still there"

assert_summary

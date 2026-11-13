#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE ADVERSARIAL NETWORKPOLICY HARNESS. Plants probe pods in EACH of the
# eight namespaces the shipped policy set guards by default (tockmox-ai,
# -monitoring, -platform, -authentik, -devops, -selfcheck, -node-agents and
# -diagnostic) on a LIVE cluster, and asserts, in both directions, what the
# policies actually let through ... not what their selectors match
# (tools/check-netpol-selectors.sh), and not what their comments say. The
# expectations for the six namespaces after the first two were read off the
# RENDERED policies (`helm template charts/tockmox-policy -f ci/values.yaml`),
# rule by rule, because a comment in this tree has been wrong about a rule
# before. What is still not probed is stated at the bottom, not implied away.
#
# WHY THIS EXISTS. On 2026-09-01 an outside reviewer read the policy templates
# as an attacker and found egress unrestricted everywhere except Open WebUI,
# plus three ingress rules wider than they read. The reviewer executed nothing
# and said so. Everything here was first measured by hand on 2026-09-06 on a
# throwaway k3s; this
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
# layer applied: it refuses, exit 2, unless the AI and monitoring namespaces
# both carry the shipped default-deny-ingress (the harness asserts, the caller
# installs, and it never creates a guarded namespace itself). Each of the other
# six is then ASSERTED to carry its default-deny: a guarded namespace that
# silently lost its guard is a failure, not a skip. A cluster that does not
# guard one of them on purpose (a blanked namespace, a bundle switched off)
# says so with TOCKMOX_UNGUARDED_NS="<namespace> ...", and that section is
# skipped and named in the log. It first proves the CNI
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
# THE FIXES ARE VALUES-DEPENDENT, so the assertions are too (0.7.0).
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
# THE PROBES IN THE SIX LATER NAMESPACES RUN UNPRIVILEGED. Two of those
# namespaces enforce the restricted Pod Security level, which refuses the plain
# `kubectl run` pod the first two sections use, so every later probe is a pod
# that passes restricted (non-root, no capabilities, RuntimeDefault seccomp).
# A TCP connect, a DNS lookup and a listener on a port above 1024 need none of
# what restricted takes away.
#
# OPEN EGRESS IS PINNED, NOT BLESSED. Authentik, devops, selfcheck, node-agents
# and platform render no egress policy, so a workload there reaches the
# internet. Each is an assert_artifact_xfail expecting BLOCKED, the same
# encoding the monitoring namespace already carries: the day one is closed the
# run goes red and the line is promoted. Whether to close them is the owner's
# decision; this file only makes the current answer a measured fact.
#
# Exit: 0 all must-pass assertions pass (xfails allowed); 1 a real failure or a
# known defect that started passing; 2 skipped (no cluster / policy layer
# absent / CNI does not enforce).
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/executed-docs/lib/assert.sh
# every kubectl and helm call below names its cluster with --context or
# --kube-context from this variable, and an empty value is refused rather than
# falling back to the current context (docs/deployment/fresh-install.md, "Name
# the cluster"). run.sh exports it; a standalone run must export it itself.
: "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"
: "${ASSERT_REPORT:=}"

AI_NS="${TOCKMOX_NS_AI:-tockmox-ai}"
MON_NS="${TOCKMOX_NS_MONITORING:-tockmox-monitoring}"
PLAT_NS="${TOCKMOX_NS_PLATFORM:-tockmox-platform}"
AUTH_NS="${TOCKMOX_NS_AUTHENTIK:-tockmox-authentik}"
DEVOPS_NS="${TOCKMOX_NS_DEVOPS:-tockmox-devops}"
SELF_NS="${TOCKMOX_NS_SELFCHECK:-tockmox-selfcheck}"
AGENTS_NS="${TOCKMOX_NS_NODE_AGENTS:-tockmox-node-agents}"
DIAG_NS="${TOCKMOX_NS_DIAGNOSTIC:-tockmox-diagnostic}"
UNGUARDED_NS="${TOCKMOX_UNGUARDED_NS:-}"   # namespaces the caller declares unguarded here
SECTIONS_SKIPPED=""
PLANTED=""
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

# probe_pod <ns> <name> <shell command> [label=value ...]: a pod that passes the
# RESTRICTED Pod Security level, for the namespaces that enforce it (a plain
# `kubectl run` pod is refused there at admission, and the refusal would read
# as "never became Ready"). Applied as a manifest because the two container
# fields restricted requires have no pod-level form `kubectl run` can set.
# The one-second grace period is so a re-run does not wait thirty seconds per
# pod for a shell that ignores SIGTERM as PID 1. Every pod planted here is
# recorded in PLANTED, which is what the readiness wait and the cleanup read.
probe_pod() {
  local ns="$1" name="$2" cmd="$3"; shift 3
  local labels="" l
  for l in "$@"; do
    labels="${labels}    \"${l%%=*}\": \"${l#*=}\"
"
  done
  kubectl --context="$KUBE_CONTEXT" -n "$ns" delete pod "$name" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1
  cat <<EOF | kubectl --context="$KUBE_CONTEXT" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    tockmox.com/netpol-probe: "true"
${labels}spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: probe
      image: ${IMG}
      command: ["sh", "-c", "${cmd}"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
EOF
  PLANTED="${PLANTED} ${ns}/${name}"
}
sleeper() { # sleeper <ns> <name> [label=value ...] ; an unprivileged sleeping probe
  local ns="$1" name="$2"; shift 2
  probe_pod "$ns" "$name" "sleep 1800" "$@"
}
listen_on() { # listen_on <ns> <name> "<port> [port ...]" [label=value ...] ; unprivileged, ports above 1024
  local ns="$1" name="$2" ports="$3"; shift 3
  probe_pod "$ns" "$name" \
    "for p in ${ports}; do (while true; do nc -l -p \$p -e /bin/true >/dev/null 2>&1 || nc -l -p \$p >/dev/null 2>&1; done) & done; wait" "$@"
}
# A namespace the CALLER declared unguarded on this cluster. Declared, not
# detected, for the reason the TOCKMOX_EXPECT_* flags are: a harness that
# skips a section because the guard is absent cannot notice the guard missing.
declared_unguarded() { case " $UNGUARDED_NS " in *" $1 "*) return 0 ;; esac; return 1; }
section_on() { # section_on <ns> <default-deny name> ; prints 1 when the section's probes can be planted
  if declared_unguarded "$1"; then echo 0
  elif kubectl --context="$KUBE_CONTEXT" -n "$1" get netpol "$2" >/dev/null 2>&1; then echo 1
  else echo 0; fi
}
# section_gate <ns> <default-deny name> <section_on result>: returns 0 when the
# section's probes should run. The guard's presence is itself an assertion, so
# a guarded namespace without its default-deny is RED here rather than a skip.
section_gate() {
  if declared_unguarded "$1"; then
    _emit "SKIPPED (section only): ${1} is declared unguarded on this cluster (TOCKMOX_UNGUARDED_NS)."
    _emit ""
    SECTIONS_SKIPPED="${SECTIONS_SKIPPED} ${1}"
    return 1
  fi
  assert_artifact "guard: ${1} carries the shipped ${2}" \
    "kubectl --context=\"$KUBE_CONTEXT\" -n ${1} get netpol ${2} -o jsonpath={.metadata.name}" "${2}"
  if [ "$3" != "1" ]; then
    _emit "note: ${1} had no ${2} when the probes were planted, so none were; the line above is the finding."
    _emit ""
    return 1
  fi
  return 0
}
# An empty address makes a probe read BLOCKED for the wrong reason and pass a
# denial spuriously (the same refusal the AI listener gets below).
require_ip() { # require_ip <ns/pod> <address>
  [ -n "$2" ] && return 0
  _emit "SKIPPED: ${1} has no pod IP; the assertions against it would be meaningless."
  exit 2
}

cleanup() {
  kubectl --context="$KUBE_CONTEXT" delete ns "$SCRATCH" --ignore-not-found --wait=false >/dev/null 2>&1
  for p in probe-plain probe-owui probe-cnpg probe-litellm listen-ai; do kubectl --context="$KUBE_CONTEXT" -n "$AI_NS" delete pod "$p" --ignore-not-found --wait=false >/dev/null 2>&1; done
  kubectl --context="$KUBE_CONTEXT" -n "$MON_NS" delete pod probe-mon probe-prom --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl --context="$KUBE_CONTEXT" -n "$OUT_NS" delete pod probe-outside --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl --context="$KUBE_CONTEXT" -n "$PLAT_NS" delete pod probe-plat --ignore-not-found --wait=false >/dev/null 2>&1
  # Everything probe_pod planted, by the label it stamps, in every namespace it
  # can have planted into ... by label rather than from PLANTED so that pods a
  # killed earlier run left behind go too.
  for ns in "$PLAT_NS" "$MON_NS" "$AUTH_NS" "$DEVOPS_NS" "$SELF_NS" "$AGENTS_NS" "$DIAG_NS"; do
    kubectl --context="$KUBE_CONTEXT" -n "$ns" delete pod -l tockmox.com/netpol-probe=true --ignore-not-found --wait=false >/dev/null 2>&1
  done
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
# The attacker in the unguarded namespace is planted on every run now: every
# section below measures from it. The platform-namespace sources (an unlabelled
# pod and a Traefik-labelled one) need only the namespace to exist, guarded or
# not, because they are where probes come FROM.
plant "$OUT_NS" probe-outside
PLAT_SRC=0
if kubectl --context="$KUBE_CONTEXT" get ns "$PLAT_NS" >/dev/null 2>&1; then
  PLAT_SRC=1
  plant   "$PLAT_NS" probe-plat
  # The label is the identity (allow-from-traefik selects on it). It carries
  # the name label ONLY, and it listens on nothing.
  sleeper "$PLAT_NS" probe-traefik "app.kubernetes.io/name=traefik"
fi
# The six later namespaces. A listener per namespace on ports the harness
# picks, so no assertion depends on a product pod being installed; a second
# port where a rule is port-scoped, so "this port and not that one" is read
# from one pod.
PLAT_ON="$(section_on "$PLAT_NS" default-deny-ingress)"
AUTH_ON="$(section_on "$AUTH_NS" default-deny-ingress)"
DEVOPS_ON="$(section_on "$DEVOPS_NS" default-deny-ingress)"
SELF_ON="$(section_on "$SELF_NS" default-deny-ingress)"
AGENTS_ON="$(section_on "$AGENTS_NS" default-deny-ingress)"
DIAG_ON="$(section_on "$DIAG_NS" default-deny)"
if [ "$PLAT_ON" = 1 ]; then
  # 8080 is in the default platformNetpol.scrapePorts, 8081 is not.
  listen_on "$PLAT_NS" listen-plat "8080 8081"
fi
if [ "$AUTH_ON" = 1 ]; then
  sleeper   "$AUTH_NS" probe-auth
  listen_on "$AUTH_NS" listen-auth 8080
  # A stand-in CNPG instance: allow-cnpg-operator selects on this label.
  listen_on "$AUTH_NS" listen-auth-db "5432 8080" "cnpg.io/podRole=instance"
fi
if [ "$DEVOPS_ON" = 1 ]; then
  sleeper   "$DEVOPS_NS" probe-devops
  listen_on "$DEVOPS_NS" listen-devops 8080
fi
if [ "$SELF_ON" = 1 ]; then
  sleeper   "$SELF_NS" probe-self
  listen_on "$SELF_NS" listen-self 8080
fi
if [ "$AGENTS_ON" = 1 ]; then
  sleeper   "$AGENTS_NS" probe-agents
  # 9633 is one of the two ports allow-from-prometheus opens, 8080 is not.
  listen_on "$AGENTS_NS" listen-agents "9633 8080"
fi
if [ "$DIAG_ON" = 1 ]; then
  sleeper   "$DIAG_NS" probe-diag
  listen_on "$DIAG_NS" listen-diag 8080
  # The telemetry the diagnostic identity may read: a Prometheus-labelled
  # listener in monitoring on 9090 (allowed) and 8080 (not).
  listen_on "$MON_NS" listen-mon "9090 8080" "app.kubernetes.io/name=prometheus"
fi
# The real Alertmanager, if there is one: the self-check heartbeat's one
# outbound call lands on it, and a stand-in carrying its label could be picked
# up by its Service.
MON_AM_IP="$(pod_ip_by_label "$MON_NS" app.kubernetes.io/name=alertmanager)"
for p in "$AI_NS/probe-plain" "$AI_NS/probe-owui" "$AI_NS/listen-ai" "$MON_NS/probe-mon" \
         "$AI_NS/probe-cnpg" "$AI_NS/probe-litellm" "$MON_NS/probe-prom"; do
  if ! ready "${p%/*}" "${p#*/}"; then _emit "SKIPPED: ${p} never became Ready"; exit 2; fi
done
if ! ready "$OUT_NS" probe-outside; then _emit "SKIPPED: ${OUT_NS}/probe-outside never became Ready"; exit 2; fi
if [ "$PLAT_SRC" = 1 ]; then
  if ! ready "$PLAT_NS" probe-plat; then _emit "SKIPPED: ${PLAT_NS}/probe-plat never became Ready"; exit 2; fi
fi
for p in $PLANTED; do
  if ! ready "${p%/*}" "${p#*/}"; then
    _emit "SKIPPED: ${p} never became Ready (an unprivileged probe: is it refused at admission, or is the image missing?)"
    exit 2
  fi
done
PLAT_L_IP=""; AUTH_L_IP=""; AUTH_DB_IP=""; DEVOPS_L_IP=""; SELF_L_IP=""; AGENTS_L_IP=""; DIAG_L_IP=""; MON_L_IP=""
if [ "$PLAT_ON" = 1 ]; then PLAT_L_IP="$(pod_ip "$PLAT_NS" listen-plat)"; require_ip "$PLAT_NS/listen-plat" "$PLAT_L_IP"; fi
if [ "$AUTH_ON" = 1 ]; then
  AUTH_L_IP="$(pod_ip "$AUTH_NS" listen-auth)"; require_ip "$AUTH_NS/listen-auth" "$AUTH_L_IP"
  AUTH_DB_IP="$(pod_ip "$AUTH_NS" listen-auth-db)"; require_ip "$AUTH_NS/listen-auth-db" "$AUTH_DB_IP"
fi
if [ "$DEVOPS_ON" = 1 ]; then DEVOPS_L_IP="$(pod_ip "$DEVOPS_NS" listen-devops)"; require_ip "$DEVOPS_NS/listen-devops" "$DEVOPS_L_IP"; fi
if [ "$SELF_ON" = 1 ]; then SELF_L_IP="$(pod_ip "$SELF_NS" listen-self)"; require_ip "$SELF_NS/listen-self" "$SELF_L_IP"; fi
if [ "$AGENTS_ON" = 1 ]; then AGENTS_L_IP="$(pod_ip "$AGENTS_NS" listen-agents)"; require_ip "$AGENTS_NS/listen-agents" "$AGENTS_L_IP"; fi
if [ "$DIAG_ON" = 1 ]; then
  DIAG_L_IP="$(pod_ip "$DIAG_NS" listen-diag)"; require_ip "$DIAG_NS/listen-diag" "$DIAG_L_IP"
  MON_L_IP="$(pod_ip "$MON_NS" listen-mon)"; require_ip "$MON_NS/listen-mon" "$MON_L_IP"
fi
# An allow rule that names a pod lags the pod by about a second on the one
# policy controller this was measured on (docs/usage/what-you-get.md, "A new
# pod is unpoliced for about its first second"). Every REACHED below depends
# on such a rule, so give the controller a moment after the last pod is Ready.
sleep 5
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
# fix 1: an ordinary AI-namespace workload must have no egress to the
# internet. A hard assertion once TOCKMOX_EXPECT_AI_EGRESS_DENY=1.
fix_assert "$EXPECT_AI_DENY" "egress: ${AI_NS} plain workload -> external ${EXT_HOST}:${EXT_PORT} (fix 1 target)" \
  "$(tcp_from "$AI_NS" probe-plain "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
# The one contained path today, and it must stay contained.
assert_artifact "egress: ${AI_NS} open-webui -> external ${EXT_HOST}:${EXT_PORT} is contained" \
  "$(tcp_from "$AI_NS" probe-owui "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
# KNOWN DEFECT (census): monitoring has unrestricted egress.
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

# ---------------------------------------------------------------------------
# 5-10. THE SIX LATER NAMESPACES. Every expectation below is a rule in the
# rendered policy set, named beside the line; "wrong reads" says what the
# probe returns when that rule is missing or wider than rendered.
# ---------------------------------------------------------------------------
_emit "--- 5. platform namespace: the harness's own listener ------------------"
# Section 4 measures the object store and needs it installed. This one needs
# only the namespace's bundle: default-deny-ingress, allow-intra-namespace,
# allow-from-node-network (LAN and node addresses, never a pod),
# allow-prometheus-scrape (the scrape ports only). No egress policy renders.
if section_gate "$PLAT_NS" default-deny-ingress "$PLAT_ON"; then
  # allow-intra-namespace, every port. Wrong reads BLOCKED; and without this
  # line the two :8081 denials below could be a dead port.
  assert_artifact "control: ${PLAT_NS} pod -> ${PLAT_NS} listener :8081 is admitted (intra-namespace; proves the port is live)" \
    "$(tcp_from "$PLAT_NS" probe-plat "$PLAT_L_IP" 8081)" "REACHED"
  # No rule admits a pod from another namespace to an ordinary platform pod.
  # Wrong reads REACHED, which is what the clusterCIDR block read (fix 4).
  fix_assert "$EXPECT_NODE_SRC" "ingress: pod in ${OUT_NS} -> ${PLAT_NS} listener :8081 (fix 4: no rule admits an ordinary pod)" \
    "$(tcp_from "$OUT_NS" probe-outside "$PLAT_L_IP" 8081)" "BLOCKED"
  # allow-prometheus-scrape opens the scrape ports. Wrong reads BLOCKED.
  assert_artifact "ingress: Prometheus-labelled pod -> ${PLAT_NS} listener :8080 is admitted (a default scrape port)" \
    "$(tcp_from "$MON_NS" probe-prom "$PLAT_L_IP" 8080)" "REACHED"
  # ... and nothing else (fix 3). Wrong reads REACHED.
  fix_assert "$EXPECT_NODE_SRC" "ingress: Prometheus-labelled pod -> ${PLAT_NS} listener :8081 (fix 3: not a scrape port)" \
    "$(tcp_from "$MON_NS" probe-prom "$PLAT_L_IP" 8081)" "BLOCKED"
  # KNOWN DEFECT (census): the platform namespace has unrestricted egress.
  assert_artifact_xfail "egress: ${PLAT_NS} workload -> external ${EXT_HOST}:${EXT_PORT}" \
    "$(tcp_from "$PLAT_NS" probe-plat "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
  # allow-s3-from-backup-clients names two client namespaces and one port.
  # Against the REAL object store, because a stand-in carrying its label
  # could be picked up by its Service.
  if [ -n "$PLAT_GARAGE_IP" ] && [ "$AUTH_ON" = 1 ]; then
    assert_artifact "ingress: ${AUTH_NS} pod -> ${PLAT_NS} object store S3 :3900 is admitted (the identity database's backup client)" \
      "$(tcp_from "$AUTH_NS" probe-auth "$PLAT_GARAGE_IP" 3900)" "REACHED"
    fix_assert "$EXPECT_NODE_SRC" "ingress: ${AUTH_NS} pod -> ${PLAT_NS} object store admin :3903 (a backup client gets the S3 port only)" \
      "$(tcp_from "$AUTH_NS" probe-auth "$PLAT_GARAGE_IP" 3903)" "BLOCKED"
  fi
  if [ -n "$PLAT_GARAGE_IP" ] && [ "$DEVOPS_ON" = 1 ]; then
    fix_assert "$EXPECT_NODE_SRC" "ingress: ${DEVOPS_NS} pod -> ${PLAT_NS} object store S3 :3900 (not a backup client namespace)" \
      "$(tcp_from "$DEVOPS_NS" probe-devops "$PLAT_GARAGE_IP" 3900)" "BLOCKED"
  fi
fi

_emit "--- 6. authentik namespace ---------------------------------------------"
# Rendered: default-deny-ingress, allow-intra-namespace, allow-from-traefik
# (the Traefik POD, any port), allow-prometheus-scrape (the Prometheus POD, any
# port), allow-cnpg-operator (platform namespace -> CNPG instances, 8000 and
# 5432). No egress policy.
if section_gate "$AUTH_NS" default-deny-ingress "$AUTH_ON"; then
  # default-deny-ingress. Wrong reads REACHED.
  assert_artifact "ingress: pod in ${OUT_NS} -> ${AUTH_NS} listener :8080 is denied" \
    "$(tcp_from "$OUT_NS" probe-outside "$AUTH_L_IP" 8080)" "BLOCKED"
  # The scrape allow is the Prometheus pod, not its namespace. Wrong reads REACHED.
  assert_artifact "ingress: ${MON_NS} unlabelled pod -> ${AUTH_NS} listener :8080 is denied (the scrape allow is pod-scoped)" \
    "$(tcp_from "$MON_NS" probe-mon "$AUTH_L_IP" 8080)" "BLOCKED"
  # allow-intra-namespace. Wrong reads BLOCKED.
  assert_artifact "ingress: ${AUTH_NS} pod -> ${AUTH_NS} listener :8080 is admitted (intra-namespace)" \
    "$(tcp_from "$AUTH_NS" probe-auth "$AUTH_L_IP" 8080)" "REACHED"
  # allow-prometheus-scrape. Wrong reads BLOCKED.
  assert_artifact "ingress: Prometheus-labelled pod -> ${AUTH_NS} listener :8080 is admitted (scrape)" \
    "$(tcp_from "$MON_NS" probe-prom "$AUTH_L_IP" 8080)" "REACHED"
  # allow-cnpg-operator names the platform namespace. Wrong reads REACHED.
  assert_artifact "ingress: pod in ${OUT_NS} -> ${AUTH_NS} CNPG-instance-labelled listener :5432 is denied" \
    "$(tcp_from "$OUT_NS" probe-outside "$AUTH_DB_IP" 5432)" "BLOCKED"
  if [ "$PLAT_SRC" = 1 ]; then
    # allow-from-traefik: every sign-in arrives this way. Wrong reads BLOCKED.
    assert_artifact "ingress: Traefik-labelled ${PLAT_NS} pod -> ${AUTH_NS} listener :8080 is admitted (the front door)" \
      "$(tcp_from "$PLAT_NS" probe-traefik "$AUTH_L_IP" 8080)" "REACHED"
    # ... and it is the Traefik pod, not the platform namespace. Wrong reads REACHED.
    assert_artifact "ingress: unlabelled ${PLAT_NS} pod -> ${AUTH_NS} listener :8080 is denied (the Traefik allow is pod-scoped)" \
      "$(tcp_from "$PLAT_NS" probe-plat "$AUTH_L_IP" 8080)" "BLOCKED"
    # allow-cnpg-operator: the operator's namespace reaches an instance on
    # 5432. Wrong reads BLOCKED.
    assert_artifact "ingress: ${PLAT_NS} pod -> ${AUTH_NS} CNPG-instance-labelled listener :5432 is admitted (the operator)" \
      "$(tcp_from "$PLAT_NS" probe-plat "$AUTH_DB_IP" 5432)" "REACHED"
    # ... and on 8000 and 5432 only. The control proves :8080 is live there
    # (intra-namespace); the denial then reads REACHED when the rule is wrong.
    assert_artifact "control: ${AUTH_NS} pod -> CNPG-instance-labelled listener :8080 is admitted (intra-namespace; proves the port is live)" \
      "$(tcp_from "$AUTH_NS" probe-auth "$AUTH_DB_IP" 8080)" "REACHED"
    assert_artifact "ingress: ${PLAT_NS} pod -> ${AUTH_NS} CNPG-instance-labelled listener :8080 is denied (the operator allow is two ports)" \
      "$(tcp_from "$PLAT_NS" probe-plat "$AUTH_DB_IP" 8080)" "BLOCKED"
  else
    _emit "note: no ${PLAT_NS} namespace; the Traefik and CNPG-operator paths into ${AUTH_NS} were not run"
  fi
  # KNOWN DEFECT (census): the authentik namespace has unrestricted egress.
  assert_artifact_xfail "egress: ${AUTH_NS} workload -> external ${EXT_HOST}:${EXT_PORT}" \
    "$(tcp_from "$AUTH_NS" probe-auth "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
fi

_emit "--- 7. devops namespace ------------------------------------------------"
# Rendered: default-deny-ingress, allow-intra-namespace, allow-from-traefik
# (the Traefik POD), allow-prometheus-scrape (the Prometheus POD). No egress
# policy.
if section_gate "$DEVOPS_NS" default-deny-ingress "$DEVOPS_ON"; then
  # default-deny-ingress. Wrong reads REACHED.
  assert_artifact "ingress: pod in ${OUT_NS} -> ${DEVOPS_NS} listener :8080 is denied" \
    "$(tcp_from "$OUT_NS" probe-outside "$DEVOPS_L_IP" 8080)" "BLOCKED"
  # Pod-scoped scrape allow. Wrong reads REACHED.
  assert_artifact "ingress: ${MON_NS} unlabelled pod -> ${DEVOPS_NS} listener :8080 is denied (the scrape allow is pod-scoped)" \
    "$(tcp_from "$MON_NS" probe-mon "$DEVOPS_L_IP" 8080)" "BLOCKED"
  # allow-intra-namespace. Wrong reads BLOCKED.
  assert_artifact "ingress: ${DEVOPS_NS} pod -> ${DEVOPS_NS} listener :8080 is admitted (intra-namespace)" \
    "$(tcp_from "$DEVOPS_NS" probe-devops "$DEVOPS_L_IP" 8080)" "REACHED"
  # allow-prometheus-scrape. Wrong reads BLOCKED.
  assert_artifact "ingress: Prometheus-labelled pod -> ${DEVOPS_NS} listener :8080 is admitted (scrape)" \
    "$(tcp_from "$MON_NS" probe-prom "$DEVOPS_L_IP" 8080)" "REACHED"
  if [ "$PLAT_SRC" = 1 ]; then
    # allow-from-traefik. Wrong reads BLOCKED.
    assert_artifact "ingress: Traefik-labelled ${PLAT_NS} pod -> ${DEVOPS_NS} listener :8080 is admitted (the front door)" \
      "$(tcp_from "$PLAT_NS" probe-traefik "$DEVOPS_L_IP" 8080)" "REACHED"
    # ... the pod, not the namespace. Wrong reads REACHED.
    assert_artifact "ingress: unlabelled ${PLAT_NS} pod -> ${DEVOPS_NS} listener :8080 is denied (the Traefik allow is pod-scoped)" \
      "$(tcp_from "$PLAT_NS" probe-plat "$DEVOPS_L_IP" 8080)" "BLOCKED"
  else
    _emit "note: no ${PLAT_NS} namespace; the Traefik path into ${DEVOPS_NS} was not run"
  fi
  # KNOWN DEFECT (census): the devops namespace has unrestricted egress.
  assert_artifact_xfail "egress: ${DEVOPS_NS} workload -> external ${EXT_HOST}:${EXT_PORT}" \
    "$(tcp_from "$DEVOPS_NS" probe-devops "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
fi

_emit "--- 8. selfcheck namespace ---------------------------------------------"
# Rendered: default-deny-ingress, allow-intra-namespace,
# allow-prometheus-scrape (the Prometheus POD). NO Traefik allow: nothing here
# is published. No egress policy.
if section_gate "$SELF_NS" default-deny-ingress "$SELF_ON"; then
  # default-deny-ingress. Wrong reads REACHED.
  assert_artifact "ingress: pod in ${OUT_NS} -> ${SELF_NS} listener :8080 is denied" \
    "$(tcp_from "$OUT_NS" probe-outside "$SELF_L_IP" 8080)" "BLOCKED"
  # Pod-scoped scrape allow. Wrong reads REACHED.
  assert_artifact "ingress: ${MON_NS} unlabelled pod -> ${SELF_NS} listener :8080 is denied (the scrape allow is pod-scoped)" \
    "$(tcp_from "$MON_NS" probe-mon "$SELF_L_IP" 8080)" "BLOCKED"
  # allow-intra-namespace. Wrong reads BLOCKED.
  assert_artifact "ingress: ${SELF_NS} pod -> ${SELF_NS} listener :8080 is admitted (intra-namespace)" \
    "$(tcp_from "$SELF_NS" probe-self "$SELF_L_IP" 8080)" "REACHED"
  # allow-prometheus-scrape: the probe results leave this way. Wrong reads BLOCKED.
  assert_artifact "ingress: Prometheus-labelled pod -> ${SELF_NS} listener :8080 is admitted (scrape)" \
    "$(tcp_from "$MON_NS" probe-prom "$SELF_L_IP" 8080)" "REACHED"
  if [ "$PLAT_SRC" = 1 ]; then
    # No allow-from-traefik renders here, unlike its neighbours. Wrong reads REACHED.
    assert_artifact "ingress: Traefik-labelled ${PLAT_NS} pod -> ${SELF_NS} listener :8080 is denied (nothing here is published)" \
      "$(tcp_from "$PLAT_NS" probe-traefik "$SELF_L_IP" 8080)" "BLOCKED"
  else
    _emit "note: no ${PLAT_NS} namespace; the Traefik denial into ${SELF_NS} was not run"
  fi
  if [ -n "$MON_AM_IP" ]; then
    # monitoring's allow-from-selfcheck: the heartbeat's one outbound call.
    # Wrong reads BLOCKED, and the heartbeat alert then fires for a healthy cluster.
    assert_artifact "egress+ingress: ${SELF_NS} pod -> Alertmanager :9093 is admitted (the heartbeat's path)" \
      "$(tcp_from "$SELF_NS" probe-self "$MON_AM_IP" 9093)" "REACHED"
    # ... from the selfcheck namespace, not from anywhere. Wrong reads REACHED.
    assert_artifact "ingress: pod in ${OUT_NS} -> Alertmanager :9093 is denied" \
      "$(tcp_from "$OUT_NS" probe-outside "$MON_AM_IP" 9093)" "BLOCKED"
  else
    _emit "note: no Alertmanager pod found; the heartbeat path was not run"
  fi
  # KNOWN DEFECT (census): the selfcheck namespace has unrestricted egress.
  assert_artifact_xfail "egress: ${SELF_NS} workload -> external ${EXT_HOST}:${EXT_PORT}" \
    "$(tcp_from "$SELF_NS" probe-self "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
fi

_emit "--- 9. node-agents namespace -------------------------------------------"
# Rendered: default-deny-ingress and allow-from-prometheus (the Prometheus POD,
# ports 9633 and 12345). NO intra-namespace allow, unlike every namespace
# above. No egress policy. (node-exporter is hostNetwork and outside all of it.)
if section_gate "$AGENTS_NS" default-deny-ingress "$AGENTS_ON"; then
  # Loopback is not policed, so this proves :8080 is live on a pod nothing may
  # reach on it; without it the :8080 denial below could be a dead port.
  assert_artifact "control: ${AGENTS_NS} listener answers on its own loopback :8080 (proves the port is live)" \
    "$(tcp_from "$AGENTS_NS" listen-agents 127.0.0.1 8080)" "REACHED"
  # allow-from-prometheus. Wrong reads BLOCKED.
  assert_artifact "ingress: Prometheus-labelled pod -> ${AGENTS_NS} listener :9633 is admitted (a metrics port)" \
    "$(tcp_from "$MON_NS" probe-prom "$AGENTS_L_IP" 9633)" "REACHED"
  # ... on the two metrics ports only. Wrong reads REACHED.
  assert_artifact "ingress: Prometheus-labelled pod -> ${AGENTS_NS} listener :8080 is denied (not a metrics port)" \
    "$(tcp_from "$MON_NS" probe-prom "$AGENTS_L_IP" 8080)" "BLOCKED"
  # ... and the Prometheus pod only. Wrong reads REACHED.
  assert_artifact "ingress: ${MON_NS} unlabelled pod -> ${AGENTS_NS} listener :9633 is denied (the scrape allow is pod-scoped)" \
    "$(tcp_from "$MON_NS" probe-mon "$AGENTS_L_IP" 9633)" "BLOCKED"
  # default-deny-ingress. Wrong reads REACHED.
  assert_artifact "ingress: pod in ${OUT_NS} -> ${AGENTS_NS} listener :9633 is denied" \
    "$(tcp_from "$OUT_NS" probe-outside "$AGENTS_L_IP" 9633)" "BLOCKED"
  # No allow-intra-namespace renders here. Wrong reads REACHED.
  assert_artifact "ingress: ${AGENTS_NS} pod -> ${AGENTS_NS} listener :9633 is denied (no intra-namespace allow in this namespace)" \
    "$(tcp_from "$AGENTS_NS" probe-agents "$AGENTS_L_IP" 9633)" "BLOCKED"
  # KNOWN DEFECT (census): the node-agents namespace has unrestricted egress.
  assert_artifact_xfail "egress: ${AGENTS_NS} workload -> external ${EXT_HOST}:${EXT_PORT}" \
    "$(tcp_from "$AGENTS_NS" probe-agents "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
fi

_emit "--- 10. diagnostic namespace -------------------------------------------"
# Rendered: default-deny (ingress AND egress) and allow-dns-api-telemetry
# (egress to cluster DNS; to the API ranges on 443 and 6443; to the monitoring
# namespace on 9090 and 3100). Nothing admits ingress, from anywhere.
if section_gate "$DIAG_NS" default-deny "$DIAG_ON"; then
  # default-deny egress. Wrong reads REACHED. (An EXT_HOST inside the service
  # or LAN range would read REACHED through the API rule; the default is not.)
  assert_artifact "egress: ${DIAG_NS} workload -> external ${EXT_HOST}:${EXT_PORT} is contained" \
    "$(tcp_from "$DIAG_NS" probe-diag "$EXT_HOST" "$EXT_PORT")" "BLOCKED"
  # The DNS rule. Wrong reads NXDOMAIN, and every other allowed path dies with it.
  assert_artifact "egress: ${DIAG_NS} workload can resolve DNS" \
    "$(dns_from "$DIAG_NS" probe-diag)" "RESOLVES"
  # The telemetry rule, and monitoring's allow-from-tockmox-agent on the other
  # side: both must hold for REACHED. Wrong reads BLOCKED.
  assert_artifact "egress+ingress: ${DIAG_NS} workload -> ${MON_NS} Prometheus-labelled listener :9090 is admitted (telemetry)" \
    "$(tcp_from "$DIAG_NS" probe-diag "$MON_L_IP" 9090)" "REACHED"
  # ... on the telemetry ports only. The control proves :8080 is live there
  # (intra-namespace in monitoring). TWO rules hold this denial, the egress
  # port list here and the ingress port list on monitoring's side, so it reads
  # REACHED only when both are wrong; it cannot tell you which one slipped.
  assert_artifact "control: ${MON_NS} pod -> ${MON_NS} Prometheus-labelled listener :8080 is admitted (intra-namespace; proves the port is live)" \
    "$(tcp_from "$MON_NS" probe-mon "$MON_L_IP" 8080)" "REACHED"
  assert_artifact "egress: ${DIAG_NS} workload -> ${MON_NS} Prometheus-labelled listener :8080 is denied (neither side opens a non-telemetry port)" \
    "$(tcp_from "$DIAG_NS" probe-diag "$MON_L_IP" 8080)" "BLOCKED"
  # Ingress: nothing is admitted, so liveness is proven on loopback.
  assert_artifact "control: ${DIAG_NS} listener answers on its own loopback :8080 (proves the port is live)" \
    "$(tcp_from "$DIAG_NS" listen-diag 127.0.0.1 8080)" "REACHED"
  # default-deny ingress. Wrong reads REACHED.
  assert_artifact "ingress: pod in ${OUT_NS} -> ${DIAG_NS} listener :8080 is denied" \
    "$(tcp_from "$OUT_NS" probe-outside "$DIAG_L_IP" 8080)" "BLOCKED"
  # Same namespace, and still denied: no intra-namespace allow in either
  # direction. Wrong reads REACHED.
  assert_artifact "ingress: ${DIAG_NS} pod -> ${DIAG_NS} listener :8080 is denied (no intra-namespace allow)" \
    "$(tcp_from "$DIAG_NS" probe-diag "$DIAG_L_IP" 8080)" "BLOCKED"
fi

if [ -n "$SECTIONS_SKIPPED" ]; then
  _emit "SECTIONS NOT RUN (declared unguarded by the caller):${SECTIONS_SKIPPED}"
  _emit ""
fi

does_not_prove \
  "the optional bundles (the kube-bench namespace, a separately installed registry or forge, the tailnet operator, the agent sandbox, syslog ingest, site clients of monitoring) and any namespace named in TOCKMOX_UNGUARDED_NS: none of it is probed" \
  "the rules whose only honest target is a real product pod behind a Service: Traefik's allow-from-anywhere, and monitoring's own allows for the node agents' log path, the console, the actions service, the model jobs, the reboot daemon and the operator admission webhook. A stand-in carrying those labels could be picked up by the Service in front of the real pod" \
  "that the open egress pinned as xfail in authentik, devops, selfcheck, node-agents, platform and monitoring should stay open or be closed: the xfail records that it is open today, and nothing else" \
  "the hostNetwork workloads (the load-balancer speaker, the reboot daemon, node-exporter): NetworkPolicy does not reach them and neither does a probe pod" \
  "an allowed LABEL arriving from the wrong NAMESPACE: every labelled source here (Prometheus, Traefik) is planted in the namespace its rule names, so a scrape or front-door allow that lost its namespaceSelector would still read green" \
  "that node-originated traffic STILL gets in once nodeOriginSources is set: a probe pod cannot send from a node's cni0/flannel.1 address. The webhook, kubelet-to-CSI and MetalLB paths are proven only by a real certificate issuance, a volume attach and a LoadBalancer request on the cluster (the doc says which)" \
  "the diagnostic identity's API narrowing (fix 2): the probe in the diagnostic namespace above measures the internet, DNS and telemetry, but the API rule's width needs a site-specific decoy address on the LAN, which a generic harness does not have" \
  "labels are the identity here: probe-cnpg, probe-litellm, probe-prom, probe-traefik and the labelled listeners carry the label the policies select on, they are not the real pods. That the real CNPG instance manager, barman sidecar and LiteLLM pod complete their work under the deny is proven only by a Cluster reporting healthy, a Backup completing and a completion returning" \
  "the fixes without their values: with the TOCKMOX_EXPECT_* flags unset, the fixed lines are pinned xfail and prove only that the leak is still there"

assert_summary

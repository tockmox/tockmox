#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Stand up, address, reboot and destroy a throwaway single-node k3s cluster for
# the executed-documentation harness.
#
# Step 1 and step 5 of the harness shape in docs/testing-standard.md: the
# cluster is ephemeral, created per run and destroyed after, because state that
# leaks between runs makes results unrepeatable.
#
#   throwaway-cluster.sh create   ... provision, wait, emit a kubeconfig path
#   throwaway-cluster.sh exec CMD ... run CMD on the node, as root
#   throwaway-cluster.sh reboot   ... hard node restart (used to test durability claims)
#   throwaway-cluster.sh destroy  ... delete every VM in the namespace
#   throwaway-cluster.sh await    ... resume create's wait for a guest already provisioning
#
# MicroOS images only (provision/profiles/microos.sh, TM-0715):
#
#   throwaway-cluster.sh uninstall-proof ... run uninstall.md section 9 on the guest
#   throwaway-cluster.sh evidence        ... copy the guest's beacon records out
#
# WHY `exec` EXISTS, since it is the part that adds a credential. Some documented
# procedures are node-local by their nature ... administration/storage.md step 1
# is "on EVERY k3s server node, sudo touch ...". A harness with no in-guest
# execution cannot run those verbatim, and would have to either skip them or
# substitute a cluster-side approximation. Substituting is the failure this
# harness exists to prevent, so it gets a key instead: generated per run, public
# half injected by cloud-init, private half deleted with the cluster. It is
# never a stored secret and it never outlives the VM.
#
# SUBSTRATE. Any KubeVirt-capable cluster ... Harvester, OpenShift
# Virtualization, or upstream KubeVirt on anything. The harness holds no
# credential of its own: point KUBECONFIG at a context scoped to the test
# namespace and nothing else. A ServiceAccount with VirtualMachine lifecycle in
# that one namespace, and no ClusterRole, is the intended shape.
#
# BLAST RADIUS. Everything happens in ONE namespace and the script refuses to
# start if that namespace is not the configured disposable one. A KubeVirt
# cluster typically also hosts machines that are not disposable, so the
# namespace rule is the boundary, and TOCKMOX_PROTECTED_VMS is a second net for
# naming any machine that must never be touched whatever else goes wrong.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then echo "must run under bash" >&2; exit 2; fi
if [ "${BASH_VERSINFO[0]:-0}" -lt 3 ]; then
  echo "needs bash 3.2 or newer, found ${BASH_VERSION:-unknown}" >&2; exit 2
fi

NS="${TOCKMOX_TEST_NAMESPACE:-tockmox-test}"
VM_NAME="${TOCKMOX_TEST_VM:-k3s-test-01}"
K3S_VERSION="${TOCKMOX_K3S_VERSION:-}"
# ---- defaults that RESOLVE, corrected 2026-09-04 (TM-0406) -----------------
# The image default previously named a resource that does not exist, so a
# `create` with no overrides failed cold for anyone who did not already know
# the right value ... which is the opposite of what a default is for. The image
# is `ubuntu-2204-cloud`, not `ubuntu-22-04-cloud`.
IMAGE_ID="${TOCKMOX_VM_IMAGE_ID:-tockmox-test/ubuntu-2204-cloud}"
# ---- the network default is `pod`, ruled 2026-09-04 (TM-0406) ---------------
# Two attachments were measured the same day, from inside the guest, with the
# beacon below. They differ in the ONE direction the `secret` handoff needs.
#
#   NAMESPACE/SEGMENT (multus bridge). The cross-namespace reference resolves:
#   `AddedInterface ... from NAMESPACE/SEGMENT`, `linkState: up`. The guest gets
#   a DHCP lease, a default route and working WAN (`get.k3s.io` returned 200)
#   ... and has NO route to the management network the substrate API sits on,
#   by design of that segment. The handoff POST returns `http_code=000`, no
#   kubeconfig Secret is ever written, and `create` waits forever behind a
#   healthy-looking VMI. LINK-UP IS NOT REACHABILITY.
#
#   pod (masquerade). The guest NATs out behind the virt-launcher pod, reaches
#   the substrate API it was created through, and the handoff works. Nothing
#   reaches IN: the guest is reachable only through the NodePort Service that
#   `create` publishes on the substrate's API host (see publish_kubeconfig).
#   Cost, stated rather than discovered: the guest can reach the cluster's pod
#   network on the way out, which is broader than an isolated segment.
#
# A default that hangs for every harness host that cannot route to the lab
# segment is not a default, so `pod` is the one that ships. A harness host that
# CAN route to the segment network ... and wants the isolated segment with a directly
# routable guest address ... overrides it with TOCKMOX_VM_NETWORK=NAMESPACE/SEGMENT.
NETWORK="${TOCKMOX_VM_NETWORK:-pod}"
# ---- 250Gi because 40Gi was MEASURED to fail, not because bigger is safer ---
# A full install pulls roughly 25GB of container images before Longhorn asks for
# its first replica. On a 40Gi root disk Longhorn then refuses to schedule with
#
#   insufficient storage: disk ... does not have enough storage available
#   for replica ... with size 8589934592
#
# and the volume goes to `faulted`. What an operator SEES is authentik in
# CrashLoopBackOff failing to reach PostgreSQL ... an error naming a component
# three steps from the cause. Measured 2026-09-04 on this harness.
#
# sizing.md puts the Minimal tier at 100 GB and Reference at 250 GB, and the
# machine the documented install is certified against is a Reference node.
# Matching it is what keeps a disk-space failure from being reported as a
# product defect.
DISK="${TOCKMOX_VM_DISK:-250Gi}"
# ---- sized to MATCH THE GATE TARGET, not to be small -----------------------
# A throwaway that is smaller than the machine the documented install is
# certified on cannot falsify that install: a full eleven-app stack (ArgoCD,
# Longhorn, Authentik, CNPG, monitoring) that dies for want of memory produces a
# FALSE finding, and a false finding is worse than no finding, because it sends
# someone to debug a product defect that does not exist. The greenfield machine
# the install is certified against is a Reference node, 8 cores / 24Gi, so that
# is the default here.
# Lower it deliberately if you are testing behaviour under pressure; do not
# lower it to be polite to the host.
# REGISTRY MIRROR, added 2026-09-13 (TM-0568). Empty by default: the tree must
# carry no site specifics, so the mirror is named by the caller.
#
# WHY IT MATTERS MORE THAN SPEED. A by-the-book install pulls 44 images, 17 of
# them docker.io-hosted, anonymously. On 2026-09-13 an upstream rate limit
# produced `Failed to pull image ... pull QPS exceeded`, which surfaced as the
# PLATFORM LAYER sitting OutOfSync/Degraded waiting on Longhorn CRDs ... a
# registry limit wearing a storage failure's face, on the very component whose
# CRDs the known first-sync race also names. A rig that can manufacture a
# finding indistinguishable from a real product defect is worse than a slow one.
#
#   TOCKMOX_REGISTRY_MIRROR=harbor.example.com ./throwaway-cluster.sh create
REGISTRY_MIRROR="${TOCKMOX_REGISTRY_MIRROR:-}"
CPU_CORES="${TOCKMOX_VM_CORES:-8}"
MEMORY="${TOCKMOX_VM_MEMORY:-24Gi}"
STORAGE_CLASS="${TOCKMOX_VM_STORAGECLASS:-harvester-longhorn-r1}"
WORKDIR="${TOCKMOX_WORKDIR:-${TMPDIR:-/tmp}/executed-docs}"
HANDOFF_PORT="${TOCKMOX_HANDOFF_PORT:-18080}"

# ---- a PINNED identity, for substrates where inbound is per-host ------------
# UNSET BY DEFAULT. Nothing below changes unless TOCKMOX_VM_ADDRESS is set, so
# the `pod`-mode path that runs today is untouched.
#
# WHY IT EXISTS. On a segmented lab network there is no
# routing between segments at all: every inbound path is an explicit
# destination NAT pinned to a FIXED address. A throwaway takes a DHCP lease that
# moves every run ... measured .104 and then .101 hours apart ... so it cannot be
# given a standing rule. Pinning the guest's address lets ONE standing set of
# NAT/pass rules serve every run, instead of the harness editing the firewall
# per run. A rule a test mutates is a rule a crashed run leaves behind, and that
# edge is a containment boundary.
#
# TWO ADDRESSES, NOT ONE. The address the guest HOLDS (on the segment network) and the
# address the harness DIALS (the edge's published alias on the harness's side)
# are different, because the harness has no route to the segment network at all. An earlier
# version of this block carried both in TOCKMOX_VM_ADDRESS and could only ever
# dial an address it could not reach.
#
# TOCKMOX_VM_ADDRESS        the address the harness DIALS: the edge alias whose
#                           standing destination NATs forward to the guest.
#                           Used INSTEAD of asking the VMI ... there is no guest
#                           agent, so .status.interfaces stays empty forever on
#                           a healthy VM and `http` mode's wait_for_ip could
#                           never return (run sheet 3.4).
# TOCKMOX_VM_GUEST_ADDRESS  the address the guest HOLDS, as CIDR (192.0.2.60/24),
#                           written STATICALLY into the guest's networkData. The
#                           preferred way to pin:
#                           outside the DHCP pool, so no lease exists to go
#                           stale. A MAC reservation instead hits the
#                           carrying-the-MAC trap on EVERY run, because every
#                           throwaway is freshly imaged and so presents a new
#                           client-id while the last run's lease still holds
#                           the reserved address.
# TOCKMOX_VM_GATEWAY        default route + DNS for the static address. Defaults
#                           to .1 of the guest's /24, which is the segment network's edge.
# TOCKMOX_VM_MAC            the older way to pin: a MAC for a DHCP reservation.
#                           Still accepted; see the trap above before using it.
# TOCKMOX_VM_SSH_PORT       the published port for in-guest execution. :22
#                           through the lab edge is dropped by design,
#                           so this is a NAT to the guest's :22, e.g. 2222.
# TOCKMOX_VM_API_PORT       the published port for the guest's k3s API
#                           (default 6443). The retrieved kubeconfig is pointed
#                           at ${TOCKMOX_VM_ADDRESS}:${this}, and k3s is told
#                           that address as a TLS SAN so verification holds.
#
# ONE THROWAWAY AT A TIME on a pinned address: two guests holding 192.0.2.60 is
# an address conflict, not a test.
#
# THE ADDRESS IS NOT ASSERTED, AND MUST NOT BE. Setting these does not prove the
# guest took that address; the dial against the handoff port is what proves it.
# See the timeout text in fetch_kubeconfig for the faults that look alike.
VM_MAC="${TOCKMOX_VM_MAC:-}"
VM_ADDRESS="${TOCKMOX_VM_ADDRESS:-}"
VM_GUEST_ADDRESS="${TOCKMOX_VM_GUEST_ADDRESS:-}"
VM_GATEWAY="${TOCKMOX_VM_GATEWAY:-}"
VM_SSH_PORT="${TOCKMOX_VM_SSH_PORT:-22}"
VM_API_PORT="${TOCKMOX_VM_API_PORT:-6443}"
if [ -n "$VM_GUEST_ADDRESS" ] && [ -n "$VM_MAC" ]; then
  echo "REFUSING: set TOCKMOX_VM_GUEST_ADDRESS (static) or TOCKMOX_VM_MAC" >&2
  echo "          (DHCP reservation), not both. Two mechanisms claiming one" >&2
  echo "          address is a race, and a race here reads as a firewall fault." >&2
  exit 2
fi
if { [ -n "$VM_MAC" ] || [ -n "$VM_GUEST_ADDRESS" ]; } && [ -z "$VM_ADDRESS" ]; then
  echo "REFUSING: the guest's address is pinned but TOCKMOX_VM_ADDRESS is not set." >&2
  echo "          Pinning only helps if you also say which published address" >&2
  echo "          reaches it. Half of this pair is a guest that boots onto a" >&2
  echo "          predictable address nothing is published to." >&2
  exit 2
fi
if [ -n "$VM_ADDRESS" ] && [ -z "$VM_MAC" ] && [ -z "$VM_GUEST_ADDRESS" ]; then
  echo "REFUSING: TOCKMOX_VM_ADDRESS is set but nothing pins the guest's own" >&2
  echo "          address (TOCKMOX_VM_GUEST_ADDRESS, preferred, or TOCKMOX_VM_MAC)." >&2
  echo "          Without it the NAT target is a guess that will be right until" >&2
  echo "          it is not." >&2
  exit 2
fi
if [ -n "$VM_GUEST_ADDRESS" ]; then
  case "$VM_GUEST_ADDRESS" in
    */*) ;;
    *) echo "REFUSING: TOCKMOX_VM_GUEST_ADDRESS must be CIDR, e.g. 192.0.2.60/24." >&2; exit 2 ;;
  esac
  if [ -z "$VM_GATEWAY" ]; then
    VM_GATEWAY="$(printf '%s' "${VM_GUEST_ADDRESS%/*}" | awk -F. '{print $1"."$2"."$3".1"}')"
  fi
fi

# How the guest's kubeconfig gets back to the harness. The two options differ in
# WHICH DIRECTION the connection runs, and that is the whole reason there are
# two: on a segmented lab network the harness reaching INTO the guest is the
# fragile direction, and the guest reaching OUT to the API it was created
# through is the sturdy one.
#
#   secret  ... the guest writes its kubeconfig into a Secret in the test
#               namespace and the harness reads it back through the same API it
#               used to create the VM. Needs NO inbound path to the guest.
#               Costs: a namespace-scoped token rides in the cloud-init data.
#   http    ... the guest serves it once on a random path and the harness pulls
#               it. No credential in the guest. Needs an inbound path.
#
# Default is `secret` because a run that cannot retrieve a kubeconfig produces
# no evidence at all, and provisioning is not the thing under test.
HANDOFF="${TOCKMOX_HANDOFF:-secret}"
case "$HANDOFF" in
  secret|http) : ;;
  *) echo "REFUSING: TOCKMOX_HANDOFF must be 'secret' or 'http', got '${HANDOFF}'" >&2; exit 2 ;;
esac

# --- refuse to run anywhere that is not disposable -------------------------
# A hold that names one forbidden machine is escaped the moment somebody adds
# another non-disposable machine. So the primary rule is scoped to a CLASS: this
# harness operates in the disposable namespace, full stop. Deny-listing
# individual names is the second net, not the first.
DISPOSABLE_NS="${TOCKMOX_DISPOSABLE_NAMESPACE:-tockmox-test}"
if [ "$NS" != "$DISPOSABLE_NS" ]; then
  echo "REFUSING: namespace '${NS}' is not the disposable test namespace." >&2
  echo "          This harness creates and destroys virtual machines. It runs in" >&2
  echo "          '${DISPOSABLE_NS}' only. Set TOCKMOX_DISPOSABLE_NAMESPACE if that" >&2
  echo "          is genuinely wrong ... deliberately, and not to get past this." >&2
  exit 2
fi

# Operator-supplied deny list, space separated. Machines that must never be
# touched however wrong everything else goes.
for _protected in ${TOCKMOX_PROTECTED_VMS:-}; do
  if [ "$VM_NAME" = "$_protected" ]; then
    echo "REFUSING: '${VM_NAME}' is on TOCKMOX_PROTECTED_VMS and is not a throwaway." >&2
    exit 2
  fi
done

mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
# Talking to the hypervisor always uses the SUBSTRATE credential. A caller that
# has already switched KUBECONFIG to the guest (run.sh does, so extracted
# documentation blocks work verbatim) sets TOCKMOX_SUBSTRATE_KUBECONFIG so the
# verbs that address VMs keep working. Without it, `exec` reached the guest,
# where `vm` is not a resource type.
if [ -n "${TOCKMOX_SUBSTRATE_KUBECONFIG:-}" ]; then
  KUBECONFIG="$TOCKMOX_SUBSTRATE_KUBECONFIG"
  export KUBECONFIG
fi

# TM-0797: EVERY kubectl call in this file names its cluster. The hypervisor
# calls carry --context="$TOCKMOX_SUBSTRATE_CONTEXT"; the few calls that address
# the guest carry the context read out of the guest's own kubeconfig. Nothing
# here relies on the caller's current-context, which is whatever the last shell
# left behind. The variable is refused when empty (checked at dispatch below),
# because `--context=` with an empty value silently means the current context.

KUBECONFIG_OUT="${WORKDIR}/${VM_NAME}.kubeconfig"
SSH_KEY="${WORKDIR}/${VM_NAME}.id_ed25519"
SSH_USER="${TOCKMOX_VM_USER:-tockmox}"

# The Service that gives the harness a way IN to a masqueraded guest. Named
# here rather than inline because create and destroy both need it and a
# teardown that misses it leaves a NodePort allocated against a dead VM.
API_SVC="${VM_NAME}-api"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "REFUSING: '$1' is not on PATH" >&2; exit 2; }
}

preflight() {
  need kubectl
  need curl
  # Name the precondition that is missing rather than failing three steps later
  # with something that reads as a network fault.
  #
  # Assert the capability this harness NEEDS, not a proxy for it. An earlier
  # version tested `kubectl get ns <NS>`, which a correctly scoped credential
  # CANNOT do: the identity is namespaced and has no permission on the
  # cluster-scoped Namespace object at all. So the preflight refused every
  # properly confined credential and would have accepted only an over-broad one.
  # A precondition check that rewards excess privilege is worse than none.
  local out
  out="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get virtualmachines.kubevirt.io -o name 2>&1)"
  case "$out" in
    *Forbidden*|*forbidden*)
      echo "REFUSING: this credential cannot list VirtualMachines in ${NS}." >&2
      printf '  %s\n' "$out" >&2
      exit 2 ;;
    *"connection refused"*|*"no such host"*|*"Unable to connect"*|*"timeout"*)
      echo "REFUSING: cannot reach the cluster with the current KUBECONFIG." >&2
      printf '  %s\n' "$out" >&2
      exit 2 ;;
    *"the server doesn't have a resource type"*|*"server could not find"*)
      echo "REFUSING: the target cluster serves no kubevirt.io/virtualmachines resource." >&2
      exit 2 ;;
  esac

  # And assert the writes this harness is about to make, before it makes the
  # first one. Failing at VM-create time leaves a half-provisioned namespace.
  local verb
  for verb in "create virtualmachines.kubevirt.io" "delete virtualmachines.kubevirt.io" "create secrets"; do
    if [ "$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" auth can-i $verb -n "$NS" 2>/dev/null)" != "yes" ]; then
      echo "REFUSING: this credential cannot '${verb}' in ${NS}." >&2
      exit 2
    fi
  done

  # Pod-network mode builds a NodePort to get back IN to the guest, so the
  # credential needs Services too. Assert it here rather than after the VM is
  # already running: a create that provisions a cluster and then cannot publish
  # it leaves state behind and reports the wrong cause.
  if [ "$NETWORK" = "pod" ]; then
    for verb in "create services" "delete services"; do
      if [ "$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" auth can-i $verb -n "$NS" 2>/dev/null)" != "yes" ]; then
        echo "REFUSING: TOCKMOX_VM_NETWORK=pod needs to '${verb}' in ${NS}." >&2
        echo "          Masquerade gives the guest no inbound path, so the harness" >&2
        echo "          publishes the guest API through a NodePort Service." >&2
        exit 2
      fi
    done
  fi
}

# ---- publishing a masqueraded guest ---------------------------------------
# WHY THIS IS IN THE HARNESS AND NOT IN A RUNBOOK. Until 2026-09-02 these three
# steps ... apply the Service, read the assigned port, rewrite the kubeconfig
# ... were written out for a human to do after every create. Three chances per
# run to get the setup silently wrong, in a harness whose whole argument is that
# the setup must not be the thing under test. A run that fails because a port
# was mistyped produces a failure report about the documentation, which is the
# most expensive kind of wrong answer this harness can give.
#
# Masquerade NATs the guest behind the virt-launcher pod: it reaches out, and
# nothing reaches in. A NodePort selecting the VMI's pod is the way back.
nodeport_host() {
  # NEVER hard-code an address here ... this repository is public and
  # tools/check-no-site-specifics.sh refuses IPs and hostnames in tests/.
  # Derive it: the node that fronts the NodePort is reachable at the same host
  # the harness already dials for the substrate API. Override when the
  # substrate's API endpoint is not a node (a managed control plane, say).
  if [ -n "${TOCKMOX_NODEPORT_HOST:-}" ]; then
    printf '%s' "$TOCKMOX_NODEPORT_HOST"; return
  fi
  # PREFER THE NODE THE GUEST IS ACTUALLY ON, measured 2026-09-23 (TM-0715).
  # The API host is not always a node: on a Harvester cluster the kubeconfig
  # names the cluster VIP, which fronts the API and refuses NodePorts outright
  # (`connection refused` on :30198 at the VIP, 401 from the same port on the
  # node's own address, seconds apart). The virt-launcher pod's hostIP is a
  # node by definition, and a NodePort answers on every node. Falls through to
  # the API host when the pod cannot be read.
  local hostip
  hostip="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get pod -l "vm.kubevirt.io/name=${VM_NAME}" \
            -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || true)"
  if [ -n "$hostip" ]; then printf '%s' "$hostip"; return; fi
  local server hostport
  server="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  hostport="${server#*://}"
  hostport="${hostport%%/*}"
  printf '%s' "${hostport%%:*}"
}

ensure_nodeport() {
  # Sets NODEPORT_CACHE. Idempotent: a re-run of create against an existing
  # Service keeps the port it already has.
  #
  # Deliberately assigns a GLOBAL rather than printing the port for a caller to
  # capture. `$(ensure_nodeport)` would run this in a subshell, where the cache
  # assignment is discarded the moment it returns ... so the "cache" would miss
  # every time and re-apply the Service on every poll of the retrieval loop.
  if [ -n "${NODEPORT_CACHE:-}" ]; then return 0; fi
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${API_SVC}
  namespace: ${NS}
  labels:
    tockmox.com/harness: executed-docs
    tockmox.com/blast-radius: disposable
spec:
  type: NodePort
  selector:
    vm.kubevirt.io/name: ${VM_NAME}
  ports:
    - name: api
      port: 6443
      targetPort: 6443
      protocol: TCP
YAML
  local port deadline
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    port="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get svc "$API_SVC" \
            -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    if [ -n "${port:-}" ]; then
      NODEPORT_CACHE="$port"
      echo "  guest API published on nodePort ${port}" >&2
      return 0
    fi
    sleep 3
  done
  echo "REFUSING: ${NS}/${API_SVC} was never assigned a nodePort." >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get svc "$API_SVC" -o yaml >&2 2>&1 || true
  return 1
}

publish_kubeconfig() {
  # Point the retrieved kubeconfig at the NodePort. The guest wrote it with its
  # own (masqueraded, unroutable) address in it, so a file that parses is not a
  # file that connects ... which is exactly why fetch_kubeconfig asserts a Ready
  # node AFTER this runs rather than before.
  local port host cluster
  ensure_nodeport || return 1
  port="$NODEPORT_CACHE"
  host="$(nodeport_host)"
  if [ -z "$host" ]; then
    echo "REFUSING: could not derive a NodePort host from the current context." >&2
    echo "          Set TOCKMOX_NODEPORT_HOST to the address of a node." >&2
    return 1
  fi
  # ctx-exempt-begin: kubeconfig FILE edits (view, unset, set-cluster) on the guest's own file; none reaches a cluster
  cluster="$(KUBECONFIG="$KUBECONFIG_OUT" kubectl config view \
             -o jsonpath='{.clusters[0].name}' 2>/dev/null)"
  [ -n "$cluster" ] || { echo "REFUSING: guest kubeconfig names no cluster." >&2; return 1; }

  # k3s issues its serving certificate with SANs for the addresses it knows
  # about, and the node fronting the NodePort is not one of them. Verification
  # is dropped deliberately and only for the throwaway's own kubeconfig, which
  # lives in WORKDIR and dies with the VM. Unset the CA first: kubectl refuses
  # to hold a root certificate and the insecure flag at the same time.
  KUBECONFIG="$KUBECONFIG_OUT" kubectl config unset \
    "clusters.${cluster}.certificate-authority-data" >/dev/null 2>&1 || true
  KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-cluster "$cluster" \
    --server="https://${host}:${port}" --insecure-skip-tls-verify=true >/dev/null
  # ctx-exempt-end
}

# The context name inside the GUEST kubeconfig this script wrote. That file holds
# one cluster (the k3s node), so its current-context is the guest rather than
# something ambient. An empty answer is refused at the call site.
guest_context() {
  # ctx-exempt-next: reads the context NAME out of the guest's own kubeconfig file; reaches no cluster
  KUBECONFIG="$KUBECONFIG_OUT" kubectl config current-context 2>/dev/null
}

resolve_k3s_version() {
  if [ -n "$K3S_VERSION" ]; then printf '%s' "$K3S_VERSION"; return; fi
  # THE VERSION A READER INSTALLS IS THE ONE THE PAGE PINS, so that is the one
  # this guest installs: fresh-install.md exports K3S_VERSION once per node and
  # passes it as INSTALL_K3S_VERSION on every install line. Read it from the
  # page at the ref under test (this script sits three levels below the repo
  # root), so a page that moves the pin moves the guest with it.
  #
  # Until 2026-10-10 this read k3s's stable channel live and, when that failed,
  # installed UNPINNED on the theory that the documented line was unpinned too.
  # Neither half held. The page pins (it has since TM-0406's era), and an
  # unpinned get.k3s.io install asks update.k3s.io for the version itself, so a
  # channel the harness could not read was a channel the guest could not read
  # either: on 2026-10-10 update.k3s.io served a self-signed TRAEFIK DEFAULT
  # CERT (k3s-io/k3s#14783) and every live run spent twenty minutes waiting for
  # a kubeconfig that could not arrive, twice in a row, on a release commit.
  local page
  page="$(dirname "${BASH_SOURCE[0]}")/../../../docs/deployment/fresh-install.md"
  [ -r "$page" ] || return 0
  sed -n 's/^export K3S_VERSION=\(v[0-9][^[:space:]]*\)[[:space:]]*$/\1/p' "$page" | head -1
}

mint_ssh_key() {
  need ssh-keygen
  rm -f "$SSH_KEY" "${SSH_KEY}.pub"
  ssh-keygen -t ed25519 -N '' -C "executed-docs-${VM_NAME}-$(date +%s)" -f "$SSH_KEY" >/dev/null
  chmod 600 "$SSH_KEY"
}

# ---- a stale handoff Secret is refused, never waited on (TM-0766) ------------
# fetch_kubeconfig polls ${VM_NAME}-kubeconfig and takes the first copy that
# parses, and vm_ip reads the same Secret for the guest's address. Neither can
# tell a Secret THIS guest wrote from one a previous guest left behind. Observed
# 2026-09-28: a failed create's teardown left k3s-test-01-kubeconfig in place,
# the next create read that dead guest's client certificate, pointed it at the
# new guest, and spent twenty minutes on 401 ... a leaked credential presenting
# as a guest auth fault. So create removes both guest-written Secrets before it
# builds anything, and refuses outright when it cannot prove they are gone. A
# delete that fails here is reported, not silenced: silencing it is how the
# leak stayed invisible.
clear_stale_handoff() {
  local s out
  for s in "${VM_NAME}-kubeconfig" "${VM_NAME}-boot"; do
    if ! out="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete secret "$s" --ignore-not-found 2>&1)"; then
      echo "REFUSING: could not delete ${NS}/${s} left by an earlier guest." >&2
      printf '  %s\n' "$out" >&2
      echo "          The guest writes this Secret and create reads it back. Waiting on" >&2
      echo "          a stale copy hands the harness a dead guest's credential. Remove" >&2
      echo "          it by hand, or grant delete on secrets in ${NS}, then re-run." >&2
      exit 2
    fi
    case "$out" in *deleted*) echo "  removed stale ${NS}/${s} left by an earlier guest" >&2 ;; esac
    # Assert the artefact, not the delete's exit code. Present = refuse. A
    # query that cannot answer is not an absence either.
    if out="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get secret "$s" -o name 2>&1)"; then
      echo "REFUSING: ${NS}/${s} still exists after its delete returned." >&2
      echo "          create will not wait on a Secret it did not see the guest write." >&2
      exit 2
    fi
    case "$out" in
      *NotFound*|*"not found"*) : ;;
      *)
        echo "REFUSING: could not confirm ${NS}/${s} is gone ... an unanswered query is not an absence." >&2
        printf '  %s\n' "$out" >&2
        exit 2 ;;
    esac
  done
}

check_handoff_token() {
  [ "$HANDOFF" = "secret" ] || return 0
  local API_TOKEN tok_sub
  API_TOKEN="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null)"
  [ -n "$API_TOKEN" ] || return 0   # create() refuses an empty token with its own message
  # THE TOKEN IS COPIED INTO THE GUEST, so it must be the narrow, namespace-scoped
  # identity create() says it is, and that is checked rather than assumed (TM-0849,
  # Harvester and testing council 2026-10-03, section 8b). Handed an admin
  # kubeconfig, this used to write a hypervisor admin token into a lab VM's
  # cloud-init. A ServiceAccount token names its subject in its own payload;
  # anything that is not a ServiceAccount of the disposable namespace, or not a
  # readable token at all, is refused before any VM exists.
  tok_sub="$(printf '%s' "$API_TOKEN" | python3 -c '
import base64, json, sys
t = sys.stdin.read().strip().split(".")
if len(t) != 3:
  sys.exit(1)
p = t[1] + "=" * (-len(t[1]) % 4)
try:
  print(json.loads(base64.urlsafe_b64decode(p)).get("sub", ""))
except Exception:
  sys.exit(1)
' 2>/dev/null)" || tok_sub=""
  case "$tok_sub" in
    "system:serviceaccount:${NS}:"?*) : ;;
    *)
      echo "REFUSING: TOCKMOX_HANDOFF=secret copies this kubeconfig's token into the guest, and its" >&2
      echo "          subject is '${tok_sub:-unreadable, not a ServiceAccount token}', not a ServiceAccount" >&2
      echo "          of ${NS}. A guest is disposable and its cloud-init is readable from the" >&2
      echo "          substrate; only the namespace-scoped harness identity may go there." >&2
      echo "          Use the tockmox-test ServiceAccount kubeconfig, or TOCKMOX_HANDOFF=http." >&2
      exit 2 ;;
  esac
}

create() {
  # First, before preflight touches anything: nothing may be created or deleted
  # on behalf of a run whose token must not reach a guest (TM-0849).
  check_handoff_token
  preflight
  clear_stale_handoff
  mint_ssh_key
  local ver token manifest pubkey API_SERVER API_TOKEN GUEST_API_SERVER
  pubkey="$(cat "${SSH_KEY}.pub")"
  ver="$(resolve_k3s_version)"

  # For the `secret` handoff the guest needs to reach this API itself. Both
  # values come from the kubeconfig the harness was given, so the guest gets
  # exactly the namespace-scoped identity the harness already has and no more.
  API_SERVER=""
  API_TOKEN=""
  if [ "$HANDOFF" = "secret" ]; then
    API_SERVER="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
    # THE GUEST MAY NOT REACH THE SAME ADDRESS THE HARNESS DOES, and until now
    # this script assumed it did. On a segmented lab that assumption is wrong in
    # the normal case rather than the exotic one: the harness runs on a host with
    # a route to the substrate API, and the guest sits behind an edge whose whole
    # purpose is that it CANNOT address that segment.
    #
    # The estate's documented answer is a doorway rather than a hole -- an IP
    # alias on the edge's lab-side interface that redirects to the real API, so
    # the "deny segment -> management" rule stays literally intact and no lab config
    # ever learns a prod address (see virtual-opnsense-edge.md, which does exactly
    # this for the inference endpoint). That pattern needs the guest to be told a
    # DIFFERENT URL than the harness uses, which is what this variable is for.
    #
    # Defaults to API_SERVER, so unset behaviour is exactly as before.
    GUEST_API_SERVER="${TOCKMOX_GUEST_API_SERVER:-$API_SERVER}"
    if [ "$GUEST_API_SERVER" != "$API_SERVER" ]; then
      echo "  guest will reach the API at ${GUEST_API_SERVER} (harness uses ${API_SERVER})"
    fi
    API_TOKEN="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null)"
    if [ -z "$API_SERVER" ] || [ -z "$API_TOKEN" ]; then
      echo "REFUSING: TOCKMOX_HANDOFF=secret needs a kubeconfig carrying a bearer token." >&2
      echo "          An exec-plugin or client-certificate context cannot be handed to the" >&2
      echo "          guest. Either supply a ServiceAccount-token kubeconfig, or set" >&2
      echo "          TOCKMOX_HANDOFF=http, which needs an inbound path to the guest instead." >&2
      exit 2
    fi
  fi
  # REFUSE IN SECONDS rather than provision a guest that cannot install k3s.
  # Without a version the guest's get.k3s.io line would ask update.k3s.io, and a
  # run that cannot reach that answer only learns so twenty minutes later, as a
  # missing kubeconfig (2026-10-10, see resolve_k3s_version).
  if [ -z "$ver" ]; then
    echo "REFUSING: no k3s version. Neither TOCKMOX_K3S_VERSION nor an" >&2
    echo "          'export K3S_VERSION=v...' line in docs/deployment/fresh-install.md" >&2
    echo "          names one. Set TOCKMOX_K3S_VERSION, or restore the page's pin." >&2
    exit 2
  fi
  if [ -n "$K3S_VERSION" ]; then
    echo "k3s ${ver} (TOCKMOX_K3S_VERSION)" >&2
  else
    echo "k3s ${ver} (the version docs/deployment/fresh-install.md pins)" >&2
  fi
  local k3s_env="INSTALL_K3S_VERSION=${ver} "
  # Per-run cluster token. Never a stored secret ... it dies with the VM.
  token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  local handoff_path
  handoff_path="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  # ---- the boot disk's StorageClass is DERIVED, never supplied ------------
  # On Harvester an image-backed disk is bound by the per-image StorageClass,
  # the one whose parameters carry `backingImage:`. The imageId annotation ALONE
  # does not populate anything.
  #
  # Get this wrong and the failure is silent and total: the DataVolume reports
  # Succeeded, the PVC reports Bound, the VMI reports Running, and the disk is a
  # blank volume with no operating system on it. The guest produces no console
  # output at all, because there is nothing to boot. That looked like a network
  # problem for three provisioning cycles.
  #
  # So the class is read off the image rather than trusted from configuration,
  # and a supplied class that disagrees is refused instead of quietly producing
  # an empty disk.
  local image_ns image_name image_sc
  image_ns="${IMAGE_ID%%/*}"
  image_name="${IMAGE_ID##*/}"
  image_sc="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$image_ns" get virtualmachineimages.harvesterhci.io "$image_name" \
              -o jsonpath='{.status.storageClassName}' 2>/dev/null || true)"
  if [ -z "$image_sc" ]; then
    echo "REFUSING: image ${IMAGE_ID} reports no storageClassName." >&2
    echo "          Either it does not exist, or its import has not finished." >&2
    kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$image_ns" get virtualmachineimages.harvesterhci.io "$image_name" >&2 2>&1 || true
    exit 2
  fi
  local image_progress
  image_progress="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$image_ns" get virtualmachineimages.harvesterhci.io "$image_name" \
                    -o jsonpath='{.status.progress}' 2>/dev/null || true)"
  if [ "${image_progress:-0}" != "100" ]; then
    echo "REFUSING: image ${IMAGE_ID} is ${image_progress:-0}% imported, not 100%." >&2
    echo "          Booting from a partial image produces a guest that does nothing." >&2
    exit 2
  fi
  if [ -n "${TOCKMOX_VM_STORAGECLASS:-}" ] && [ "$TOCKMOX_VM_STORAGECLASS" != "$image_sc" ]; then
    echo "REFUSING: TOCKMOX_VM_STORAGECLASS='${TOCKMOX_VM_STORAGECLASS}' but image" >&2
    echo "          ${IMAGE_ID} is backed by '${image_sc}'." >&2
    echo "          Using any other class yields a BLANK disk that reports Bound and" >&2
    echo "          Succeeded and boots nothing. Unset the variable and let the" >&2
    echo "          image decide." >&2
    exit 2
  fi
  STORAGE_CLASS="$image_sc"

  # ---- the OS profile is DERIVED from the image too (TM-0715) --------------
  # Same reasoning as the StorageClass above: the image is the fact, and
  # configuration that disagrees with it is refused rather than obeyed.
  #
  # WHAT THIS GUARDS. Everything below this point builds an Ubuntu cloud-init:
  # it calls `apt-get`, and it hand-writes the k3s install line (see the comment
  # at "the k3s the DOCUMENTATION prescribes"). Both are wrong on openSUSE
  # MicroOS, where packages install through `transactional-update` and take
  # effect only after a reboot, and where k3s needs
  # INSTALL_K3S_SKIP_SELINUX_RPM and a `restorecon` that the Ubuntu path knows
  # nothing about.
  #
  # Without this check, pointing TOCKMOX_VM_IMAGE_ID at the MicroOS image
  # produces a guest that boots, runs an apt-get that does not exist, installs
  # a k3s that will not start with a 203/EXEC error naming a permissions
  # problem rather than a labelling one, and reports none of it as a profile
  # mismatch. That is a long and misleading debugging session offered to
  # whoever tries it next, which is why it refuses here with the reason instead.
  #
  # `provision/profiles/microos.sh` carries the MicroOS lane: it EXTRACTS every
  # documented command from fresh-install.md rather than hand-writing any of
  # them, and drives the two-phase bring-up across the reboot the page itself
  # prescribes. Wired in 2026-09-23 (TM-0715): a MicroOS image now builds the
  # profile's cloud-config instead of the Ubuntu one below, and everything
  # after the cloud-config (the Secret, the VM, the handoff, the NodePort, the
  # Ready assertion) is shared, because none of it is OS-specific.
  # CASE-INSENSITIVE ON PURPOSE, and this was caught by testing the guard
  # rather than by reading it. The image resource is `microos-cloud`, but its
  # display name is `openSUSE-MicroOS-ContainerHost-Cloud` ... a case-SENSITIVE
  # `*microos*` matches the first and misses the second, so the guard would
  # have waved through the exact image it exists to catch, and done it silently.
  # A guard with a blind spot aimed at its own subject is worse than no guard,
  # because it is trusted.
  local image_name_lc image_profile
  image_name_lc="$(printf '%s' "$image_name" | tr '[:upper:]' '[:lower:]')"
  case "$image_name_lc" in
    *microos*|*micro-os*|*suse*) image_profile="microos" ;;
    *) image_profile="ubuntu" ;;
  esac
  # An override that DISAGREES with the image is refused, not obeyed ... the
  # same rule this function already applies to TOCKMOX_VM_STORAGECLASS a few
  # lines above, and for the same reason: the image is the fact. Letting
  # `TOCKMOX_VM_OS_PROFILE=ubuntu` win on a MicroOS image would hand back
  # precisely the silent 203/EXEC failure this guard exists to prevent, with
  # the added insult that someone typed the wrong answer and was believed.
  OS_PROFILE="${TOCKMOX_VM_OS_PROFILE:-$image_profile}"
  if [ -n "${TOCKMOX_VM_OS_PROFILE:-}" ] && [ "$TOCKMOX_VM_OS_PROFILE" != "$image_profile" ]; then
    echo "REFUSING: TOCKMOX_VM_OS_PROFILE='${TOCKMOX_VM_OS_PROFILE}' but image" >&2
    echo "          ${IMAGE_ID} resolves to '${image_profile}'." >&2
    echo "          The image is the fact. Unset the variable and let it decide." >&2
    exit 2
  fi
  local mx_dir="" mx_ref=""
  if [ "$OS_PROFILE" = "microos" ]; then
    # ---- the MicroOS lane's own preconditions, checked before anything is
    # created. Each is a way this lane can only fail late and misleadingly.
    #
    # The docs under test must be NAMED. The Ubuntu lane hand-writes its k3s
    # line and so never reads a page; this lane executes the page, so which
    # page is part of the run's identity. run.sh already requires the same
    # variable for the same reason.
    mx_ref="${TOCKMOX_DOCS_REF:-}"
    if [ -z "$mx_ref" ]; then
      echo "REFUSING: image ${IMAGE_ID} is MicroOS, and that lane executes the" >&2
      echo "          documentation itself. Set TOCKMOX_DOCS_REF to the git ref" >&2
      echo "          whose fresh-install.md is under test (e.g. main, v0.6.1)." >&2
      exit 2
    fi
    # The guest reports and hands off OUTBOUND, through the API it was created
    # through. The http handoff needs an inbound path and `nc`, neither of
    # which this lane builds.
    if [ "$HANDOFF" != "secret" ]; then
      echo "REFUSING: the MicroOS lane supports TOCKMOX_HANDOFF=secret only." >&2
      exit 2
    fi
    need python3
    for verb in "create configmaps" "get configmaps" "update configmaps"; do
      if [ "$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" auth can-i $verb -n "$NS" 2>/dev/null)" != "yes" ]; then
        echo "REFUSING: the MicroOS lane's guest reports through ConfigMaps, and this" >&2
        echo "          credential cannot '${verb}' in ${NS}. A guest that cannot" >&2
        echo "          report is the hour of silence run 1 was." >&2
        exit 2
      fi
    done
    if [ -n "$K3S_VERSION" ]; then
      echo "NOTE: TOCKMOX_K3S_VERSION is ignored on MicroOS. The guest runs section 4's" >&2
      echo "      exports block, which pins the version the page tells a reader to use." >&2
    fi
    # shellcheck source=profiles/microos.sh
    . "$(dirname "${BASH_SOURCE[0]}")/profiles/microos.sh"
    mx_dir="${WORKDIR}/${VM_NAME}.microos"
    rm -rf "$mx_dir"
    # The extractor reads pages with `git show REF:PAGE`, so it runs from the
    # repository this script lives in ... the docs and the harness are one tree.
    if ! ( cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && microos_extract_blocks "$mx_ref" "$mx_dir" ); then
      exit 2
    fi
    microos_you_supply "$mx_dir" "$VM_NAME" || exit 2
    # Two phases and a reboot before k3s even starts, so the Ubuntu lane's
    # twenty minutes is not enough. Run 2 (2026-09-17) took about forty.
    TOCKMOX_K3S_TIMEOUT="${TOCKMOX_K3S_TIMEOUT:-3600}"
    ver="as pinned by ${MICROOS_FRESH_INSTALL_PAGE} section 4 at ${mx_ref}"
  elif [ "$OS_PROFILE" != "ubuntu" ]; then
    echo "REFUSING: image ${IMAGE_ID} resolves to OS profile '${OS_PROFILE}', which" >&2
    echo "          this harness has no lane for." >&2
    exit 2
  fi

  echo "provisioning ${NS}/${VM_NAME}: k3s ${ver}, ${DISK} on ${STORAGE_CLASS} (derived from ${IMAGE_ID})" >&2
  echo "  os profile: ${OS_PROFILE} (derived from ${image_name})" >&2
  if [ -n "$mx_dir" ]; then
    echo "  docs under test: ${mx_ref}; blocks and PROVENANCE.tsv in ${mx_dir}" >&2
  fi
  # Say it on the transcript either way. A run whose image source is unstated is
  # a run whose pull failures have to be diagnosed by inference later.
  if [ -n "$REGISTRY_MIRROR" ]; then
    echo "  registry mirror: ${REGISTRY_MIRROR} (docker.io, quay.io, ghcr.io, registry.k8s.io)" >&2
  else
    echo "  registry mirror: NONE ... every image pulls anonymously from upstream." >&2
    echo "                   An upstream rate limit will look like a component that" >&2
    echo "                   never became ready. Set TOCKMOX_REGISTRY_MIRROR." >&2
  fi

  # ---- cloud-init goes in a Secret, not inline -----------------------------
  # KubeVirt caps INLINE cloudInitNoCloud userData at 2048 bytes and rejects the
  # VirtualMachine outright above it ("Should use UserDataSecretRef for larger
  # data"). Anything that installs software and hands a kubeconfig back is over
  # that, so the Secret is the normal path rather than a workaround.
  # ---- network attachment ---------------------------------------------------
  # TOCKMOX_VM_NETWORK=pod selects KubeVirt's default pod network with
  # masquerade binding, instead of a Multus NetworkAttachmentDefinition.
  #
  # WHY IT EXISTS. Measured 2026-09-02: a guest on the segmented lab network
  # gets a DHCP lease and a default route, and its gateway does not forward ...
  # no route to the management network, no WAN. A test node that cannot reach
  # anything cannot install k3s, let alone execute a documented procedure.
  #
  # WHAT IT COSTS, stated rather than discovered. Masquerade NATs the guest
  # behind the virt-launcher pod: nothing can reach IN, which is stricter than
  # the lab network, but the guest can reach the CLUSTER'S POD NETWORK on the
  # way out. That is broader outbound exposure than an isolated segment, and it
  # is a deliberate trade rather than a default to drift into.
  #
  # `create` publishes the guest API through a NodePort and rewrites the emitted
  # kubeconfig to match, so a caller gets a kubeconfig that already works. See
  # publish_kubeconfig above; the Service is torn down by `destroy`.
  local NET_IFACE NET_BLOCK MAC_LINE
  # A pinned MAC only means anything on a real network attachment. Under
  # masquerade the guest is NATed behind the virt-launcher pod and its MAC is
  # never seen by any DHCP server that could reserve against it, so setting one
  # would be theatre.
  MAC_LINE=""
  if [ -n "$VM_MAC" ] && [ "$NETWORK" != "pod" ]; then
    MAC_LINE=$'\n              macAddress: '"${VM_MAC}"
  fi
  # networkData: DHCP unless the guest's address is pinned statically. Built
  # here rather than inline so the manifest below carries one ${NET_DATA}.
  NET_DATA=$'                  dhcp4: true'
  if [ -n "$VM_GUEST_ADDRESS" ] && [ "$NETWORK" != "pod" ]; then
    NET_DATA=$'                  dhcp4: false\n                  addresses: ['"${VM_GUEST_ADDRESS}"$']\n                  routes:\n                    - to: 0.0.0.0/0\n                      via: '"${VM_GATEWAY}"$'\n                  nameservers:\n                    addresses: ['"${VM_GATEWAY}"$']'
  fi
  if [ "$NETWORK" = "pod" ]; then
    NET_IFACE=$'            - name: default\n              masquerade: {}'
    NET_BLOCK=$'        - name: default\n          pod: {}'
    echo "  network: pod network, masquerade (NAT out, nothing in)" >&2
    if [ -n "$VM_MAC" ]; then
      echo "  NOTE: TOCKMOX_VM_MAC ignored on the pod network ... masquerade hides it." >&2
    fi
  else
    NET_IFACE=$'            - name: labnet\n              bridge: {}'"${MAC_LINE}"
    NET_BLOCK=$'        - name: labnet\n          multus:\n            networkName: '"${NETWORK}"
    echo "  network: multus ${NETWORK}" >&2
    [ -n "$VM_MAC" ] && echo "  pinned MAC ${VM_MAC}, dialled via ${VM_ADDRESS}" >&2
    [ -n "$VM_GUEST_ADDRESS" ] && echo "  static guest address ${VM_GUEST_ADDRESS} (gw ${VM_GATEWAY}), dialled via ${VM_ADDRESS}" >&2
  fi

  local udfile secret_name
  secret_name="${VM_NAME}-cloudinit"
  udfile="$(mktemp "${TMPDIR:-/tmp}/tockmox-ud.XXXXXX")"

  if [ -n "$mx_dir" ]; then
    # ---- the MicroOS cloud-config comes from the profile --------------------
    # Same inputs the Ubuntu lane's handoff uses (the guest-facing API and the
    # namespace-scoped token), plus the CA the harness's kubeconfig trusts, so
    # the guest verifies the server it reports to. The CA is only valid for the
    # address the harness dials: if the guest is told a different one, it
    # would not match, and the guest falls back to the Ubuntu lane's -k.
    local mx_ca=""
    if [ "$GUEST_API_SERVER" = "$API_SERVER" ]; then
      mx_ca="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" config view --minify --raw \
               -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
    fi
    [ -n "$mx_ca" ] || echo "  NOTE: guest will not verify the API's certificate (no CA for ${GUEST_API_SERVER})" >&2
    if ! MX_OUTDIR="$mx_dir" MX_PREFIX="$VM_NAME" MX_API="$GUEST_API_SERVER" MX_NS="$NS" \
         MX_TOKEN="$API_TOKEN" MX_CA_B64="$mx_ca" MX_USER="$SSH_USER" MX_PUBKEY="$pubkey" \
         MX_HOSTNAME="$VM_NAME" MX_MIRROR="$REGISTRY_MIRROR" \
         MX_READY_BUDGET="${TOCKMOX_MICROOS_READY_BUDGET:-900}" \
         microos_cloud_config "$udfile"; then
      rm -f "$udfile"
      echo "REFUSING: the MicroOS profile could not build a cloud-config." >&2
      exit 2
    fi
  else
  {
    echo "#cloud-config"
    # Make the guest narrate itself to the serial console. Without this a guest
    # that boots and then fails somewhere in cloud-init is completely opaque
    # from outside: the console shows a login prompt and nothing else, which is
    # indistinguishable from a guest that never ran cloud-init at all. With it,
    # `virtctl console` is a live view of every stage. This one line is worth
    # more than every other diagnostic in this file.
    echo "output: {all: '| tee -a /dev/console'}"
    echo "users:"
    echo "  - name: ${SSH_USER}"
    echo "    sudo: \"ALL=(ALL) NOPASSWD:ALL\""
    echo "    shell: /bin/bash"
    echo "    lock_passwd: true"
    echo "    ssh_authorized_keys:"
    echo "      - ${pubkey}"
    echo "ssh_pwauth: false"
    echo "write_files:"
    if [ -n "$REGISTRY_MIRROR" ]; then
      # k3s reads this at start and rewrites every pull through the mirror.
      # Endpoint order matters: the mirror is tried first and the upstream is
      # the fallback, so a mirror outage degrades to today's behaviour rather
      # than failing the run.
      echo "  - path: /etc/rancher/k3s/registries.yaml"
      echo "    permissions: \"0600\""
      echo "    content: |"
      echo "      mirrors:"
      for _up in docker.io quay.io ghcr.io registry.k8s.io; do
        echo "        ${_up}:"
        echo "          endpoint:"
        echo "            - \"https://${REGISTRY_MIRROR}\""
        echo "            - \"https://${_up}\""
      done
    fi
    echo "  - path: /etc/rancher/k3s/config.yaml"
    echo "    permissions: \"0600\""
    echo "    content: |"
    echo "      write-kubeconfig-mode: \"0600\""
    echo "      tls-san:"
    echo "        - \"*\""
    # The published alias is not an address the guest knows about, so k3s will
    # not put it in the serving cert on its own. Without it the kubeconfig
    # rewritten to ${VM_ADDRESS} below fails TLS, which reads as a NAT fault.
    if [ -n "$VM_ADDRESS" ]; then
      echo "        - \"${VM_ADDRESS}\""
    fi
    if [ "$HANDOFF" = "secret" ]; then
      # BEACON, run before anything that needs the public internet. Without it a
      # silent guest is ambiguous: no route out at all, or a route out and a
      # slow k3s install. Those have completely different fixes. The beacon
      # costs one API call and turns the ambiguity into a measurement.
      echo "  - path: /usr/local/bin/beacon.sh"
      echo "    permissions: \"0755\""
      echo "    content: |"
      echo "      #!/bin/sh"
      echo "      # Everything here prints. A silent diagnostic is not a"
      echo "      # diagnostic: an earlier version sent curl to /dev/null, so a"
      echo "      # guest that reached this script and failed the call looked"
      echo "      # exactly like a guest that never ran it."
      echo "      echo \"TOCKMOX-BEACON: starting\""
      echo "      ip -4 -o addr show scope global | sed 's/^/TOCKMOX-BEACON addr: /'"
      echo "      ip route | sed 's/^/TOCKMOX-BEACON route: /'"
      echo "      IP=\$(ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1)"
      echo "      echo \"TOCKMOX-BEACON: ip=\$IP\""
      echo "      CODE=\$(curl -sk -m 25 -o /tmp/beacon.out -w '%{http_code}' -X POST '${GUEST_API_SERVER}/api/v1/namespaces/${NS}/secrets' \\"
      echo "        -H 'Authorization: Bearer ${API_TOKEN}' \\"
      echo "        -H 'Content-Type: application/json' \\"
      echo "        -d '{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${VM_NAME}-boot\",\"labels\":{\"tockmox.com/harness\":\"executed-docs\"}},\"stringData\":{\"stage\":\"cloud-init-reached-runcmd\",\"ip\":\"'\"\$IP\"'\"}}' 2>&1)"
      echo "      echo \"TOCKMOX-BEACON: api http_code=\$CODE\""
      echo "      # Probe the OTHER direction the guest needs. The API call and"
      echo "      # the public internet are separate reachability questions and"
      echo "      # a run that only tests one cannot tell an isolated guest from"
      echo "      # one that simply cannot reach the harness."
      echo "      WAN=\$(curl -s -m 20 -o /dev/null -w '%{http_code}' https://get.k3s.io 2>&1)"
      echo "      echo \"TOCKMOX-BEACON: wan get.k3s.io http_code=\$WAN\""
      echo "      GW=\$(ip route | awk '/^default/{print \$3}')"
      echo "      ping -c1 -W3 \"\$GW\" >/dev/null 2>&1 && echo \"TOCKMOX-BEACON: gateway \$GW reachable\" || echo \"TOCKMOX-BEACON: gateway \$GW UNREACHABLE\""
      echo "      head -c 300 /tmp/beacon.out | sed 's/^/TOCKMOX-BEACON body: /'"
      echo "      echo \"\""
    fi
    echo "  - path: /usr/local/bin/handoff.sh"
    echo "    permissions: \"0755\""
    echo "    content: |"
    echo "      #!/bin/sh"
    echo "      IP=\$(ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1)"
    echo "      sed \"s/127.0.0.1/\${IP}/\" /etc/rancher/k3s/k3s.yaml > /run/kc.yaml"
    if [ "$HANDOFF" = "secret" ]; then
      # Outbound: the guest writes its own kubeconfig into a Secret through the
      # same API that created this VM. Needs no inbound path to the guest,
      # which is the direction a segmented lab network breaks.
      echo "      B64=\$(base64 -w0 < /run/kc.yaml 2>/dev/null || base64 < /run/kc.yaml | tr -d '\\n')"
      echo "      IPB64=\$(printf '%s' \"\${IP}\" | base64 | tr -d '\\n')"
      # 409 IS NOT SUCCESS (TM-0766). It means a Secret of this name already
      # exists, which is a stale one from an earlier guest: it carries THAT
      # guest's credential, and treating 409 as done left it in place for the
      # harness to read. Replace it with this guest's copy (PUT), and count only
      # a 20x as delivered. A replace that is refused ends the handoff as a
      # failure, which is visible, rather than a success, which was not.
      echo "      BODY='{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${VM_NAME}-kubeconfig\",\"labels\":{\"tockmox.com/harness\":\"executed-docs\"}},\"data\":{\"kubeconfig\":\"'\"\${B64}\"'\",\"ip\":\"'\"\${IPB64}\"'\"}}'"
      echo "      ok=0"
      echo "      for i in 1 2 3 4 5 6 7 8 9 10 11 12; do"
      echo "        code=\$(curl -sk -o /run/out -w '%{http_code}' \\"
      echo "          -X POST '${GUEST_API_SERVER}/api/v1/namespaces/${NS}/secrets' \\"
      echo "          -H 'Authorization: Bearer ${API_TOKEN}' \\"
      echo "          -H 'Content-Type: application/json' \\"
      echo "          -d \"\$BODY\")"
      echo "        if [ \"\$code\" = 409 ]; then"
      echo "          echo \"TOCKMOX-HANDOFF: ${VM_NAME}-kubeconfig already exists (409), replacing it\""
      echo "          code=\$(curl -sk -o /run/out -w '%{http_code}' \\"
      echo "            -X PUT '${GUEST_API_SERVER}/api/v1/namespaces/${NS}/secrets/${VM_NAME}-kubeconfig' \\"
      echo "            -H 'Authorization: Bearer ${API_TOKEN}' \\"
      echo "            -H 'Content-Type: application/json' \\"
      echo "            -d \"\$BODY\")"
      echo "        fi"
      echo "        echo \"TOCKMOX-HANDOFF: attempt \$i http_code=\$code\""
      echo "        case \"\$code\" in 20*) ok=1; break ;; esac"
      echo "        sleep 10"
      echo "      done"
    else
      echo "      printf 'HTTP/1.0 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\n' > /run/resp"
      echo "      cat /run/kc.yaml >> /run/resp"
      echo "      nc -l -p ${HANDOFF_PORT} -q 1 < /run/resp > /dev/null 2>&1 || true"
      echo "      shred -u /run/resp 2>/dev/null || true"
    fi
    echo "      shred -u /run/kc.yaml 2>/dev/null || true"
    if [ "$HANDOFF" = "secret" ]; then
      echo "      [ \"\$ok\" = 1 ] || { echo \"TOCKMOX-HANDOFF: FAILED, kubeconfig not delivered (last http_code=\$code)\"; exit 1; }"
    fi
    echo "runcmd:"
    if [ "$HANDOFF" = "secret" ]; then
      # Every command lives in a write_files BLOCK SCALAR and runcmd only calls
      # it. Not a style preference ... an earlier version inlined the beacon in
      # a double-quoted YAML scalar containing awk's '\$4', which is an INVALID
      # YAML ESCAPE. cloud-init rejected the whole document and ran NOTHING: no
      # beacon, no k3s, no error anywhere the harness could see. Two runs were
      # spent suspecting the network. A block scalar processes no escapes at
      # all, so this entire class of bug cannot recur.
      echo "  - [ sh, -c, \"/usr/local/bin/beacon.sh\" ]"
    else
      echo "  - [ sh, -c, \"apt-get update && apt-get install -y netcat-openbsd\" ]"
    fi
    # ---- the k3s the DOCUMENTATION prescribes, not a default one ------------
    # `--disable traefik --disable servicelb` are not tuning. fresh-install.md
    # states both are required and existing-cluster.md's check 2 FAILS a cluster
    # that has ServiceLB running, because k3s's ServiceLB and Tockmox's MetalLB
    # both watch type: LoadBalancer Services ... "a race with a silent loser",
    # whose visible symptom is an unrelated component that cannot reach an
    # address, commonly an error naming Authentik. Bundled Traefik claims the
    # same ports as Tockmox's own ingress.
    #
    # WHY IT MATTERS HERE SPECIFICALLY. A harness that builds a cluster the
    # documentation forbids is not testing the documented path, and the install
    # failure it produces is a FALSE finding pointing at the wrong component.
    # This harness exists to keep setup from being the thing under test, so the
    # starting state has to be the one the docs describe.
    #
    # Keep these in step with fresh-install.md step 4a. If that page changes
    # its flags, this line is the second edit.
    echo "  - [ sh, -c, \"curl -sfL https://get.k3s.io | ${k3s_env}sh -s - server --disable traefik --disable servicelb --write-kubeconfig-mode 644 --token ${token}\" ]"
    echo "  - [ sh, -c, \"until /usr/local/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes 2>/dev/null | grep -q ' Ready'; do sleep 5; done\" ]"
    echo "  - [ sh, -c, \"/usr/local/bin/handoff.sh\" ]"
    echo "  - [ sh, -c, \"touch /run/tockmox-harness-ready\" ]"
  } > "$udfile"
  fi

  # ---- refuse to boot a VM with an unparseable cloud-config ----------------
  # cloud-init fails CLOSED and SILENTLY: an invalid document means no runcmd
  # runs at all, and there is no error anywhere the harness can reach. The guest
  # simply boots and sits there, which is indistinguishable from a network
  # problem. That cost two full provisioning cycles on 2026-09-02.
  #
  # This is the harness holding itself to its own rule. Assert on the artefact,
  # here the generated document, and refuse rather than hand the cluster
  # something that cannot work.
  if command -v python3 >/dev/null 2>&1; then
    # Exit 3 means THIS CHECK could not run, not that the document is bad
    # (TM-0765). The import used to sit outside the try, so a runner without
    # PyYAML died on ModuleNotFoundError and the harness reported "generated
    # cloud-config is invalid": a setup gap presented as a finding about the
    # document, which is the failure this block's comment warns against.
    cc_rc=0
    python3 - "$udfile" <<'PY' || cc_rc=$?
import sys
try:
    import yaml
except ImportError as e:
    print("cannot check the cloud-config: %s" % e, file=sys.stderr)
    sys.exit(3)
p = sys.argv[1]
try:
    d = yaml.safe_load(open(p))
except Exception as e:
    print("cloud-config is not valid YAML: %s" % e, file=sys.stderr)
    sys.exit(1)
if not isinstance(d, dict):
    print("cloud-config did not parse to a mapping", file=sys.stderr)
    sys.exit(1)
for key in ("write_files", "runcmd"):
    if not d.get(key):
        print("cloud-config has no %s ... it would boot and do nothing" % key, file=sys.stderr)
        sys.exit(1)
PY
    if [ "$cc_rc" -eq 3 ]; then
      echo "REFUSING: python3 here has no PyYAML, so the generated cloud-config cannot be checked." >&2
      echo "          This is the runner, not the document: install it (pip install pyyaml, or your" >&2
      echo "          distribution's python3-yaml) and run again. Kept at: ${udfile}" >&2
      exit 2
    elif [ "$cc_rc" -ne 0 ]; then
      echo "REFUSING: generated cloud-config is invalid. The VM would boot and run nothing." >&2
      echo "          Kept for inspection at: ${udfile}" >&2
      exit 2
    fi
    if [ -n "$mx_dir" ]; then
      echo "  cloud-config parses: $(grep -c '"path": "/var/lib/tockmox-harness/blocks/' "$udfile") documented block file(s), driver on the per-boot hook" >&2
    else
      echo "  cloud-config parses: $(grep -c '^  - \[' "$udfile") runcmd entries" >&2
    fi
  else
    echo "  WARNING: no python3, cloud-config NOT validated. A silent guest is" >&2
    echo "           more likely to be a malformed document than a network fault." >&2
  fi

  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete secret "$secret_name" --ignore-not-found >/dev/null 2>&1
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" create secret generic "$secret_name" \
    --from-file=userdata="$udfile" >/dev/null
  # Label it, so the teardown's label sweep catches it. An unlabelled Secret
  # survived a teardown on 2026-09-02 because the sweep selects on this label
  # and the by-name delete after it never ran ... the VM delete had not returned
  # when the run was cut short. A resource that only one of two cleanup paths
  # can see is a leak waiting for a slow delete.
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" label secret "$secret_name" \
    tockmox.com/harness=executed-docs --overwrite >/dev/null 2>&1 || true
  shred -u "$udfile" 2>/dev/null || rm -f "$udfile"
  echo "  cloud-init in secret ${NS}/${secret_name}" >&2

  manifest="$(cat <<YAML
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NS}
  labels:
    tockmox.com/role: k3s-test-server
    tockmox.com/blast-radius: disposable
    tockmox.com/harness: executed-docs
spec:
  running: true
  template:
    metadata:
      labels:
        harvesterhci.io/vmName: ${VM_NAME}
    spec:
      domain:
        cpu:
          cores: ${CPU_CORES}
        memory:
          guest: ${MEMORY}
        devices:
          # Capture the guest serial console. KubeVirt streams it from a
          # 'guest-console-log' sidecar, and WITHOUT this the sidecar is simply
          # not created ... which is not obvious, because the pod looks healthy
          # and "kubectl logs -c guest-console-log" returns empty rather than
          # an error. NO BACKTICKS IN THIS HEREDOC: the delimiter is unquoted
          # so that ${VM_NAME} and friends expand, which means backticks in a
          # COMMENT are command substitution and the shell runs them. This line
          # used to carry them, and every provisioning run silently executed
          # that kubectl invocation and pasted its output into the manifest.
          # It happened to error and print nothing to stdout, so the manifest
          # was unharmed by luck rather than by design.
          # A guest that boots and goes quiet is otherwise completely
          # opaque, and that opacity cost three provisioning cycles on
          # 2026-09-02. This is the single most valuable line in the manifest
          # for anyone debugging a silent guest.
          autoattachSerialConsole: true
          logSerialConsole: true
          disks:
            - name: rootdisk
              disk: { bus: virtio }
            - name: cloudinit
              disk: { bus: virtio }
          interfaces:
${NET_IFACE}
      networks:
${NET_BLOCK}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ${VM_NAME}-root
        - name: cloudinit
          cloudInitNoCloud:
            # Explicit DHCP (or an explicit static address when pinned, see
            # TOCKMOX_VM_GUEST_ADDRESS). Relying on the image's default network handling
            # means a guest with no address looks exactly like a guest with no
            # route, and those need different fixes. Matching on a glob rather
            # than a fixed name because the interface is enp1s0 or ens3 or eth0
            # depending on the machine type, and a name that does not match
            # yields a silently unconfigured NIC.
            networkData: |
              version: 2
              ethernets:
                primary:
                  match:
                    name: "e*"
${NET_DATA}
            # The JSON field is 'secretRef'. KubeVirt's own description of it
            # reads "UserDataSecretRef references a k8s secret that contains
            # NoCloud userdata", and the rejection message for oversized inline
            # data says "Should use UserDataSecretRef" ... neither is the field
            # name. Ask the CRD (kubectl explain), never the prose.
            secretRef:
              name: ${secret_name}
  dataVolumeTemplates:
    - metadata:
        name: ${VM_NAME}-root
        annotations:
          harvesterhci.io/imageId: ${IMAGE_ID}
      spec:
        storage:
          storageClassName: ${STORAGE_CLASS}
          resources:
            requests:
              storage: ${DISK}
        source:
          blank: {}
YAML
)"

  printf '%s\n' "$manifest" | kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" apply -n "$NS" -f -

  # Do NOT wait on the VMI-reported address in secret mode. KubeVirt learns a
  # guest's IP from the qemu guest agent, and a stock Ubuntu cloud image does
  # not ship one ... so .status.interfaces stays empty forever on a perfectly
  # healthy VM. Waiting on it would time out and report a boot failure that did
  # not happen. In secret mode the guest tells us its own address, which is a
  # better source anyway: it is the address the guest actually has, not the one
  # something else inferred.
  if [ "$HANDOFF" = "secret" ]; then
    echo "waiting for the guest to report in (no guest agent needed)..." >&2
  else
    wait_for_ip >/dev/null
  fi
  fetch_kubeconfig
  if [ -n "$mx_dir" ]; then
    microos_report_create || { echo "$KUBECONFIG_OUT"; exit 1; }
  fi
  echo "$KUBECONFIG_OUT"
}

# ---- the MicroOS lane's evidence, read from outside the guest ---------------
# The guest beacons every block's stdout, stderr and exit status as it runs.
# These functions pull those records back and print the documented success
# conditions in the harness's usual ARTEFACT / EXPECTED / ACTUAL shape, VERBATIM:
# the page's own output, not a summary of it.
mx_evidence_dir() { printf '%s' "${WORKDIR}/${VM_NAME}.evidence"; }

mx_print_block() {  # beacon-dir label
  local d="$1" label="$2"
  echo "ARTEFACT: ${label}"
  echo "  exit status: $(cat "${d}/rc" 2>/dev/null || echo '<absent>')"
  echo "  stdout:"; sed 's/^/    | /' "${d}/out" 2>/dev/null || echo "    <absent>"
  if [ -s "${d}/err" ]; then echo "  stderr:"; sed 's/^/    | /' "${d}/err"; fi
}

microos_report_create() {
  # shellcheck source=profiles/microos.sh
  declare -F microos_collect_evidence >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/profiles/microos.sh"
  local ev n fail=0
  ev="$(mx_evidence_dir)"
  rm -rf "$ev"
  n="$(microos_collect_evidence "$NS" "$VM_NAME" "$ev" || echo 0)"
  echo "  ${n} beacon record(s) from the guest in ${ev}" >&2
  local s2="${ev}/${VM_NAME}-block-s2-success" s4="${ev}/${VM_NAME}-block-s4a-success"
  {
    mx_print_block "$s2" "fresh-install section 2 success condition, as run by the page's reader"
    echo "EXPECTED: exit 0, 'active' and /usr/sbin/iscsiadm"
    if [ "$(cat "${s2}/rc" 2>/dev/null)" = "0" ]; then echo "RESULT:   PASS"; else echo "RESULT:   FAIL"; fail=1; fi
    sed 's/^/  ready poll: /' "${ev}/${VM_NAME}-ready/poll" 2>/dev/null || true
    mx_print_block "$s4" "fresh-install section 4a success condition, recorded after the node reported Ready"
    echo "EXPECTED: exit 0 and a node line reading Ready"
    if [ "$(cat "${s4}/rc" 2>/dev/null)" = "0" ] && grep -qw Ready "${s4}/out" 2>/dev/null; then
      echo "RESULT:   PASS"
    else
      echo "RESULT:   FAIL"; fail=1
    fi
  } >&2
  if [ "$fail" = 1 ]; then
    echo "A documented success condition FAILED on the guest. That is a finding about" >&2
    echo "the page (or the harness), and the cluster is left up for inspection." >&2
    return 1
  fi
}

# ---- uninstall.md section 9, proven on the guest -----------------------------
# MicroOS only. Tells the guest to run k3s's uninstaller, then waits while the
# guest applies the PAGE'S decision rule (reboot only if a snapshot was staged)
# and runs the page's confirmation block. The throwaway's k3s is gone after
# this; the VM remains until `destroy`.
uninstall_proof() {
  # shellcheck source=profiles/microos.sh
  . "$(dirname "${BASH_SOURCE[0]}")/profiles/microos.sh"
  if ! kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get configmap "${VM_NAME}-ready" >/dev/null 2>&1; then
    echo "REFUSING: ${NS}/${VM_NAME} never reported ready through the MicroOS lane." >&2
    echo "          uninstall-proof drives the profile's guest-side driver; an Ubuntu" >&2
    echo "          guest has none." >&2
    exit 2
  fi
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" create configmap "${VM_NAME}-uninstall-go" \
    --from-literal=requested="$(date -u +%FT%TZ)" >/dev/null 2>&1 || true
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" label configmap "${VM_NAME}-uninstall-go" \
    tockmox.com/harness=executed-docs "tockmox.com/run=${VM_NAME}" --overwrite >/dev/null
  echo "asked ${NS}/${VM_NAME} to run the uninstall proof; waiting for it to report complete..." >&2
  local deadline last="" now
  deadline=$(( $(date +%s) + ${TOCKMOX_UNINSTALL_TIMEOUT:-1800} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get configmap "${VM_NAME}-complete" >/dev/null 2>&1; then break; fi
    now="$(microos_latest_beacon "$NS" "$VM_NAME")"
    if [ -n "$now" ] && [ "$now" != "$last" ]; then echo "  guest: ${now}" >&2; last="$now"; fi
    sleep 15
  done
  local ev n
  ev="$(mx_evidence_dir)"
  rm -rf "$ev"
  n="$(microos_collect_evidence "$NS" "$VM_NAME" "$ev" || echo 0)"
  echo "  ${n} beacon record(s) from the guest in ${ev}" >&2
  if [ ! -d "${ev}/${VM_NAME}-complete" ]; then
    echo "TIMEOUT: the guest never reported the uninstall proof complete." >&2
    echo "  Last record: ${last:-<none>}. Evidence so far is in ${ev}." >&2
    exit 1
  fi
  local ud="${ev}/${VM_NAME}-uninstall-done" c="${ev}/${VM_NAME}-block-un9-confirm"
  echo "ARTEFACT: k3s-uninstall.sh's last lines (scaffolding; the page's rule reads them)"
  echo "  exit status: $(cat "${ud}/rc" 2>/dev/null || echo '<absent>')"
  # STDOUT's last lines, which is where the two outcomes the page names are
  # printed. The uninstaller also traces itself to stderr (`set -x`), and a
  # combined tail shows only that trace, which is not what the page tells a
  # reader to read. stderr is in the evidence directory in full.
  { tail -8 "${ud}/out" 2>/dev/null || true; } | sed 's/^/    | /'
  echo "  the page's rule chose: $(cat "${ud}/outcome" 2>/dev/null || echo '<absent>')"
  mx_print_block "$c" "uninstall.md section 9 confirmation block"
  # The page's own convention: "The five test and rpm lines print their correct
  # line either way ... A missing correct line is the signal here."
  local got
  got="$(grep -c ': correct$' "${c}/out" 2>/dev/null || true)"
  got="${got:-0}"
  echo "EXPECTED: all five 'correct' lines (the first line is informational, per the page)"
  echo "ACTUAL:   ${got} of 5"
  if [ "$got" = "5" ]; then echo "RESULT:   PASS"; else echo "RESULT:   FAIL ... a missing correct line is the page's signal"; exit 1; fi
}

# ---- resume the wait for a guest that is already provisioning -----------------
# The second half of `create`, on its own: retrieve the handoff, publish it,
# assert a Ready node, and (MicroOS) report the documented success conditions.
# Added 2026-09-23 (TM-0715) because the half of `create` that WAITS belongs to
# the caller's session, and the guest's run does not: when that session drops,
# the guest carries on unattended and nothing can collect its result short of
# provisioning a second guest. This collects it. It creates nothing and
# changes nothing on the guest.
await_guest() {
  if ! kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm "$VM_NAME" >/dev/null 2>&1; then
    echo "REFUSING: ${NS}/${VM_NAME} does not exist; there is nothing to wait for." >&2
    exit 2
  fi
  local mx=0
  if kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get configmap "${VM_NAME}-boot-1" >/dev/null 2>&1; then
    mx=1
    OS_PROFILE=microos
    # shellcheck source=profiles/microos.sh
    . "$(dirname "${BASH_SOURCE[0]}")/profiles/microos.sh"
    TOCKMOX_K3S_TIMEOUT="${TOCKMOX_K3S_TIMEOUT:-3600}"
  fi
  fetch_kubeconfig
  if [ "$mx" = 1 ]; then
    microos_report_create || { echo "$KUBECONFIG_OUT"; exit 1; }
  fi
  echo "$KUBECONFIG_OUT"
}

evidence() {
  # shellcheck source=profiles/microos.sh
  . "$(dirname "${BASH_SOURCE[0]}")/profiles/microos.sh"
  local ev n
  ev="$(mx_evidence_dir)"
  rm -rf "$ev"
  n="$(microos_collect_evidence "$NS" "$VM_NAME" "$ev" || echo 0)"
  echo "${n} beacon record(s) -> ${ev}" >&2
  printf '%s\n' "$ev"
}

vm_ip() {
  # A PINNED address wins over both sources below. It is not a measurement and
  # is not treated as one: nothing here asserts the guest took it. It is the
  # address a standing NAT rule publishes, so it is the address worth dialling,
  # and the dial is the test. See fetch_kubeconfig's timeout text.
  if [ -n "$VM_ADDRESS" ]; then printf '%s' "$VM_ADDRESS"; return; fi
  # Prefer what the guest reported about itself over what KubeVirt inferred.
  # The guest-agent path is absent on stock cloud images; the handoff Secret is
  # written by the guest and therefore always present once it has reported in.
  local ip
  ip="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get secret "${VM_NAME}-kubeconfig" \
        -o jsonpath='{.data.ip}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -n "$ip" ]; then printf '%s' "$ip"; return; fi
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vmi "$VM_NAME" \
    -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true
}

wait_for_ip() {
  local deadline ip
  deadline=$(( $(date +%s) + ${TOCKMOX_VM_TIMEOUT:-900} ))
  echo "waiting for ${NS}/${VM_NAME} to report an address..." >&2
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ip="$(vm_ip)"
    if [ -n "$ip" ]; then echo "  ${VM_NAME} is ${ip}" >&2; printf '%s' "$ip"; return 0; fi
    sleep 10
  done
  echo "TIMEOUT: ${NS}/${VM_NAME} never reported an address." >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" describe vmi "$VM_NAME" >&2 || true
  exit 1
}

fetch_kubeconfig() {
  local ip deadline got
  ip="$(vm_ip)"
  deadline=$(( $(date +%s) + ${TOCKMOX_K3S_TIMEOUT:-1200} ))
  if [ "$HANDOFF" = "secret" ]; then
    echo "waiting for ${NS}/${VM_NAME}-kubeconfig (guest writes it outbound)..." >&2
  else
    echo "waiting for the guest kubeconfig handoff on ${ip}:${HANDOFF_PORT}..." >&2
  fi

  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=0
    if [ "$HANDOFF" = "secret" ]; then
      if kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get secret "${VM_NAME}-kubeconfig" \
           -o jsonpath='{.data.kubeconfig}' 2>/dev/null \
           | base64 -d > "${KUBECONFIG_OUT}.tmp" 2>/dev/null; then
        got=1
      fi
    else
      if curl -sf -m 10 "http://${ip}:${HANDOFF_PORT}/" -o "${KUBECONFIG_OUT}.tmp" 2>/dev/null; then
        got=1
      fi
    fi

    if [ "$got" -eq 1 ] && grep -q 'certificate-authority-data' "${KUBECONFIG_OUT}.tmp" 2>/dev/null; then
      mv "${KUBECONFIG_OUT}.tmp" "$KUBECONFIG_OUT"
      chmod 600 "$KUBECONFIG_OUT"
      # In pod mode the address the guest wrote into this file is behind
      # masquerade and reaches nothing. Rewrite it BEFORE asserting, or the
      # assertion below can only ever fail. On a Multus network the guest's own
      # address is routable and no Service is needed.
      #
      # EVERY iteration, not just the first. The `mv` above replaces the file
      # with a fresh copy of what the GUEST wrote, so a rewrite applied on an
      # earlier pass is clobbered by the next one. Guarding this with a
      # "published" flag ... which an earlier version of this function did ...
      # means any run needing more than one poll ends holding an unrewritten
      # kubeconfig, and then the assertion below can never pass and the whole
      # create times out. Observed exactly that on 2026-09-02: the Service was
      # created and correct, the file still said `server: https://10.0.2.2:6443`.
      # ensure_nodeport caches, so the repetition costs one `kubectl config`
      # call per poll and nothing on the substrate.
      if [ "$NETWORK" = "pod" ]; then
        publish_kubeconfig || return 1
      elif [ -n "$VM_ADDRESS" ]; then
        # Pinned: the guest wrote its the segment network address, which the harness cannot
        # route to. Point at the published alias instead. The CA is KEPT: the
        # alias is in the serving cert's SANs (tls-san above), so verification
        # holds rather than being dropped as publish_kubeconfig has to.
        local pcluster
        # ctx-exempt-begin: kubeconfig FILE edits on the guest's own file; none reaches a cluster
        pcluster="$(KUBECONFIG="$KUBECONFIG_OUT" kubectl config view \
                    -o jsonpath='{.clusters[0].name}' 2>/dev/null)"
        [ -n "$pcluster" ] || { echo "REFUSING: guest kubeconfig names no cluster." >&2; return 1; }
        KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-cluster "$pcluster" \
          --server="https://${VM_ADDRESS}:${VM_API_PORT}" >/dev/null
        # ctx-exempt-end
      fi
      # Assert on the artefact, not on the retrieval's exit code: prove the
      # kubeconfig reaches a working API server before declaring the cluster up.
      # A well-formed file is not a working credential.
      local nodestatus gctx
      gctx="$(guest_context)"
      nodestatus="$(KUBECONFIG="$KUBECONFIG_OUT" kubectl --context="${gctx:?the guest kubeconfig names no context}" get nodes \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1 || true)"
      if [ "$nodestatus" = "True" ]; then
        echo "  cluster up: node Ready=True" >&2
        return 0
      fi
      echo "  kubeconfig retrieved but node Ready=${nodestatus}; retrying" >&2
    fi
    # The MicroOS lane beacons as it goes, so say where the guest is rather than
    # waiting in silence for up to an hour.
    if [ "${OS_PROFILE:-}" = "microos" ]; then
      local mx_now
      mx_now="$(microos_latest_beacon "$NS" "$VM_NAME" || true)"
      if [ -n "$mx_now" ] && [ "$mx_now" != "${mx_last:-}" ]; then
        echo "  guest: ${mx_now} ($(date -u +%H:%M:%SZ))" >&2
        mx_last="$mx_now"
      fi
    fi
    sleep 15
  done

  echo "TIMEOUT: no usable kubeconfig after $(( ${TOCKMOX_K3S_TIMEOUT:-1200} / 60 )) minutes." >&2
  if [ "$HANDOFF" = "secret" ]; then
    echo "  The guest never wrote ${NS}/${VM_NAME}-kubeconfig. That means the guest" >&2
    echo "  could not reach the API outbound, or cloud-init did not finish." >&2
    echo "  Secrets present in ${NS}:" >&2
    kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get secret 2>&1 | sed 's/^/    /' >&2
  else
    echo "  Nothing answered on ${ip}:${HANDOFF_PORT}. That is an INBOUND path" >&2
    echo "  problem, which TOCKMOX_HANDOFF=secret is designed to avoid." >&2
    if [ -n "$VM_ADDRESS" ]; then
      echo "" >&2
      echo "  ${ip} is a PINNED address (TOCKMOX_VM_ADDRESS), not something the" >&2
      echo "  guest reported. THREE different faults look exactly like this, and" >&2
      echo "  they need different fixes:" >&2
      echo "" >&2
      echo "    1. the guest is not up, or cloud-init did not finish" >&2
      echo "    2. the standing destination NAT does not publish this address" >&2
      if [ -n "$VM_GUEST_ADDRESS" ]; then
      echo "    3. the guest IS up but does not hold ${VM_GUEST_ADDRESS}: the static" >&2
      echo "       networkData did not match an interface, or another host holds it" >&2
      else
      echo "    3. the guest IS up and took a DIFFERENT address, because the DHCP" >&2
      echo "       reservation did not match ... a MAC reservation is bypassed when" >&2
      echo "       the client sends a client-id derived from its machine-id, which" >&2
      echo "       a freshly-imaged guest does by default" >&2
      fi
      echo "" >&2
      echo "  ONE command separates them. Attach a console and read the address" >&2
      echo "  the guest ACTUALLY took (it streams new output only, so send a" >&2
      echo "  newline first):" >&2
      echo "" >&2
      echo "    ( printf '\\n\\n'; sleep 15 ) | timeout 25 virtctl console ${VM_NAME} -n ${NS}" >&2
      echo "" >&2
      echo "  An address in the pool rather than ${ip} is fault 3, and no firewall" >&2
      echo "  change will fix it." >&2
    fi
  fi
  exit 1
}

node_exec() {
  # Run a command on the node, as root, verbatim. Used only for procedures the
  # documentation itself locates on the node.
  local ip
  ip="$(vm_ip)"
  [ -n "$ip" ] || { echo "REFUSING: ${VM_NAME} has no address" >&2; exit 2; }
  [ -f "$SSH_KEY" ] || { echo "REFUSING: no per-run key at ${SSH_KEY}; was this cluster created by this harness?" >&2; exit 2; }
  ssh -i "$SSH_KEY" -p "$VM_SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=15 \
      "${SSH_USER}@${ip}" "sudo -n bash -s" <<<"$1"
}

reboot() {
  # A node reboot, used to test claims of the form "this survives a restart".
  # Deliberately a VM restart rather than `systemctl restart k3s`: it needs no
  # in-guest session, and it is the STRONGER of the two cases the page names
  # ("a k3s restart or node rebuild"). A claim that survives this survives both.
  echo "restarting ${NS}/${VM_NAME} (node reboot)" >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete vmi "$VM_NAME" --wait=true
  wait_for_ip >/dev/null
  local deadline gctx
  gctx="$(guest_context)"
  deadline=$(( $(date +%s) + ${TOCKMOX_K3S_TIMEOUT:-900} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if KUBECONFIG="$KUBECONFIG_OUT" kubectl --context="${gctx:?the guest kubeconfig names no context}" get --raw /readyz >/dev/null 2>&1; then
      echo "  API server back up after reboot" >&2; return 0
    fi
    sleep 10
  done
  echo "TIMEOUT: API server did not return after reboot" >&2
  exit 1
}

# ---- WHAT A TEARDOWN MAY TOUCH (TM-0587, 2026-10-06) ----------------------
# Everything this script creates on the substrate is named `${VM_NAME}` or
# `${VM_NAME}-<something>`: the VM, its DataVolume, the cloud-init, boot and
# kubeconfig Secrets (the last two written by the guest), the API Service,
# snapshots, restores and the uninstall ConfigMap. So ownership is the NAME,
# and `destroy` deletes only names it owns.
#
# It used to be `delete vm --all` (and every harness-labelled Secret, Service
# and ConfigMap) in the namespace. Measured twice: on 2026-09-14 run.sh's
# rebuild took another session's finished P09 cluster, and on 2026-10-06 the
# scheduled executed-docs teardown deleted two agent lab VMs mid-install. A
# label says "the harness made this", not "THIS RUN made this", and the
# namespace is shared by design. The namespace-wide sweep survives as `reset`,
# which names what it is about to delete and wants an explicit confirmation.
#
# A name owned by VM_NAME is either VM_NAME itself or VM_NAME followed by a
# dash. Pick VM names that are not dash-prefixes of each other (`ed-123-1` and
# `ed-123-12` are fine; `k3s` and `k3s-test` are not).
owned_names() {
  # owned_names KIND [extra get args...]: the names of KIND in NS that belong
  # to VM_NAME, one per line. Exit 1 when the query itself failed: an
  # unanswered query is not an empty list.
  local kind="$1"; shift
  local out
  if ! out="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get "$kind" "$@" \
                -o custom-columns=:metadata.name --no-headers 2>&1)"; then
    case "$out" in
      *"doesn't have a resource type"*|*"the server doesn't have"*) return 0 ;;
    esac
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | awk '{print $1}' | while IFS= read -r n; do
    case "$n" in
      "$VM_NAME"|"$VM_NAME"-*) printf '%s\n' "$n" ;;
    esac
  done
}

# destroy's Secret sweep: this VM's three Secrets by name, plus any other
# harness-labelled Secret whose name this VM owns. Every failure is counted and
# printed (TM-0766): a refused delete must not read as a clean teardown.
delete_harness_secrets() {
  local out names
  if ! names="$(owned_names secret -l tockmox.com/harness=executed-docs)"; then
    SECRET_DELETE_ERRORS=$((SECRET_DELETE_ERRORS + 1))
    echo "  secret list FAILED (label tockmox.com/harness=executed-docs)" >&2
    names=""
  fi
  # shellcheck disable=SC2086
  if ! out="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete secret \
                "${VM_NAME}-cloudinit" "${VM_NAME}-kubeconfig" "${VM_NAME}-boot" $names \
                --ignore-not-found 2>&1)"; then
    SECRET_DELETE_ERRORS=$((SECRET_DELETE_ERRORS + 1))
    echo "  secret delete FAILED:" >&2
    printf '    %s\n' "$out" >&2
  elif [ -n "$out" ]; then
    printf '  %s\n' "$out" >&2
  fi
}

# Delete every KIND this VM owns. Quiet when there is nothing.
delete_owned() {
  local kind="$1"; shift
  local names
  names="$(owned_names "$kind" "$@")" || return 1
  [ -n "$names" ] || return 0
  # shellcheck disable=SC2086
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete "$kind" $names --ignore-not-found --wait=true
}

destroy() {
  # This VM, and only what this VM owns (see "WHAT A TEARDOWN MAY TOUCH").
  #
  # Secrets FIRST. They carry the credentials, they are instant to delete, and
  # the VM delete below can block for a minute or more ... so doing the slow
  # thing first is how a cut-short teardown leaves a token behind.
  # ---- refuse to "tear down" a cluster that has no VMs to tear down ---------
  # Every assertion below counts objects and treats 0 as success. On a cluster
  # with no KubeVirt, `kubectl get vm` ERRORS, the count is 0, and the whole
  # teardown prints PASS having deleted nothing ... which is exactly what
  # happened on 2026-09-04 when a caller had KUBECONFIG pointed at the guest
  # rather than the hypervisor. See run.sh, which hands destroy the substrate
  # credential.
  if ! kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" api-resources --api-group=kubevirt.io 2>/dev/null | grep '\bvirtualmachines\b' >/dev/null; then
    echo "REFUSING: this cluster has no kubevirt.io/virtualmachines resource." >&2
    echo "          KUBECONFIG is almost certainly pointed at the GUEST rather" >&2
    echo "          than the hypervisor. Tearing down here would delete nothing" >&2
    echo "          and report PASS." >&2
    exit 2
  fi
  SECRET_DELETE_ERRORS=0
  echo "clearing ${VM_NAME}'s secrets in ${NS}" >&2
  delete_harness_secrets
  # Snapshots BEFORE the VM: a snapshot pins storage holding a full copy of the
  # guest disk, and it outlives its source VM by design.
  echo "removing ${VM_NAME}'s snapshots and restores in ${NS}" >&2
  delete_owned vmrestore 2>/dev/null || true
  delete_owned vmsnapshot 2>/dev/null || true
  echo "destroying VM ${NS}/${VM_NAME}" >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete vm "$VM_NAME" --ignore-not-found --wait=true || true
  delete_owned datavolume 2>/dev/null || true
  # The guest writes its kubeconfig and boot Secrets outbound, and a guest that
  # was still booting may have written one after the first sweep.
  delete_harness_secrets
  # The NodePort Service that published the guest API, plus any other Service
  # this VM owns. A port allocation on every substrate node is a real cost.
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete svc "$API_SVC" --ignore-not-found 2>/dev/null || true
  delete_owned svc -l tockmox.com/harness=executed-docs 2>/dev/null || true
  # The MicroOS lane's beacons and the uninstall ConfigMap: evidence, not
  # credentials, but this run's, so they die with it.
  delete_owned configmap -l tockmox.com/harness=executed-docs 2>/dev/null || true
  rm -f "$KUBECONFIG_OUT" "${KUBECONFIG_OUT}.tmp" "$SSH_KEY" "${SSH_KEY}.pub"
  # Assert the teardown actually tore down. "delete returned 0" is not evidence.
  local vmleft svcleft secleft snapleft others snaperrf
  snaperrf="$(mktemp)"
  if ! vmleft="$(owned_names vm)"; then
    echo "RESULT:   FAIL ... could not query VMs, and an unanswered query is not a zero" >&2; exit 1
  fi
  echo "ARTEFACT: virtualmachines owned by ${VM_NAME} remaining in ${NS}"
  echo "EXPECTED: 0"
  echo "ACTUAL:   $(printf '%s' "$vmleft" | grep -c .)"
  [ -z "$vmleft" ] || { echo "RESULT:   FAIL ... teardown left state behind" >&2; exit 1; }
  if ! svcleft="$(owned_names svc)"; then
    echo "RESULT:   FAIL ... could not query Services" >&2; exit 1
  fi
  echo "ARTEFACT: services owned by ${VM_NAME} remaining in ${NS}"
  echo "EXPECTED: 0"
  echo "ACTUAL:   $(printf '%s' "$svcleft" | grep -c .)"
  [ -z "$svcleft" ] || { echo "RESULT:   FAIL ... teardown left a Service behind" >&2; exit 1; }
  # Secrets are the one leak that POISONS the next run (TM-0766): a surviving
  # ${VM_NAME}-kubeconfig is read by the next create as its own.
  echo "ARTEFACT: secrets owned by ${VM_NAME} remaining in ${NS}"
  echo "EXPECTED: 0"
  if ! secleft="$(owned_names secret)"; then
    echo "ACTUAL:   not counted"
    echo "RESULT:   FAIL ... could not query secrets, and an unanswered query is not a zero" >&2
    exit 1
  fi
  echo "ACTUAL:   $(printf '%s' "$secleft" | grep -c .)"
  [ -z "$secleft" ] || { echo "RESULT:   FAIL ... teardown left secrets behind: $(printf '%s' "$secleft" | tr '\n' ' ')" >&2; exit 1; }
  if [ "$SECRET_DELETE_ERRORS" -ne 0 ]; then
    echo "RESULT:   FAIL ... ${SECRET_DELETE_ERRORS} secret delete(s) returned an error (printed above)" >&2
    exit 1
  fi
  # The snapshot query can be REFUSED (the harness credential may not list
  # virtualmachinesnapshots; TM-0432). A refusal is "not counted", never a zero.
  echo "ARTEFACT: snapshots owned by ${VM_NAME} remaining in ${NS}"
  echo "EXPECTED: 0"
  if snapleft="$(owned_names vmsnapshot 2>"$snaperrf")"; then
    echo "ACTUAL:   $(printf '%s' "$snapleft" | grep -c .)"
    [ -z "$snapleft" ] || { echo "RESULT:   FAIL ... teardown left a snapshot holding guest-disk storage" >&2; rm -f "$snaperrf"; exit 1; }
  else
    case "$(cat "$snaperrf")" in
      *[Ff]orbidden*|*"cannot list"*)
        echo "ACTUAL:   not counted ... the credential cannot list virtualmachinesnapshots in ${NS}" ;;
      *)
        echo "ACTUAL:   not counted ... $(cat "$snaperrf")"
        rm -f "$snaperrf"
        echo "RESULT:   FAIL ... could not query snapshots, and an unanswered query is not a zero" >&2
        exit 1 ;;
    esac
  fi
  rm -f "$snaperrf"
  # Say what was LEFT ALONE, so a reader can see the scope held.
  others="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm -o custom-columns=:metadata.name --no-headers 2>/dev/null | awk 'NF{print $1}' | tr '\n' ' ')"
  [ -n "$others" ] && echo "  left alone (not ${VM_NAME}'s): ${others}"
  echo "RESULT:   PASS"
}

# reset: the old namespace-wide sweep, for the deliberate case only. Every VM,
# DataVolume, snapshot and restore in NS, and every harness-labelled Secret,
# Service and ConfigMap ... whoever made them. Refuses without the explicit
# confirmation argument, and prints what it is about to delete first.
reset_namespace() {
  if [ "${1:-}" != "--every-vm-in-${NS}" ]; then
    echo "REFUSING: reset deletes EVERY VM in ${NS}, including ones this run did not create." >&2
    echo "          VMs there now: $(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm -o custom-columns=:metadata.name --no-headers 2>/dev/null | tr '\n' ' ')" >&2
    echo "          To tear down one VM: TOCKMOX_TEST_VM=<name> $0 destroy" >&2
    echo "          To really reset:     $0 reset --every-vm-in-${NS}" >&2
    exit 2
  fi
  echo "resetting ${NS}: every VM, DataVolume, snapshot and restore; every harness Secret, Service and ConfigMap" >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm -o custom-columns=:metadata.name --no-headers 2>/dev/null | sed 's/^/  vm: /' >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete vmrestore --all --wait=true 2>/dev/null || true
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete vmsnapshot --all --wait=true 2>/dev/null || true
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete vm --all --wait=true || true
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete datavolume --all --wait=true 2>/dev/null || true
  for kind in secret svc configmap; do
    kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete "$kind" -l tockmox.com/harness=executed-docs --ignore-not-found || true
  done
  local left; left="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "ARTEFACT: virtualmachines remaining in ${NS}"; echo "EXPECTED: 0"; echo "ACTUAL:   ${left}"
  [ "$left" = "0" ] || { echo "RESULT:   FAIL" >&2; exit 1; }
  echo "RESULT:   PASS"
}

# sweep PREFIX MINUTES: destroy, one at a time and each by its own name, every
# VM whose name starts with PREFIX and that is older than MINUTES. For a
# scheduled caller that names its VMs with a prefix only it uses (the nightly
# workflow uses `ed-`), so it can clear what an earlier, killed run of ITSELF
# left behind without touching anyone else's VM.
sweep_prefix() {
  local prefix="${1:-}" mins="${2:-}"
  case "$prefix" in
    ""|?|??) echo "REFUSING: sweep needs a prefix of 3 or more characters, got '${prefix}'" >&2; exit 2 ;;
  esac
  case "$mins" in ''|*[!0-9]*) echo "REFUSING: sweep needs an age in minutes, got '${mins}'" >&2; exit 2 ;; esac
  local now n ts age rc=0
  now="$(date -u +%s)"
  while IFS=' ' read -r n ts; do
    [ -n "$n" ] || continue
    case "$n" in "$prefix"*) ;; *) continue ;; esac
    age=$(( (now - $(python3 -c 'import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$ts")) / 60 ))
    if [ "$age" -lt "$mins" ]; then
      echo "  sweep: ${n} is ${age} min old, younger than ${mins}; left alone" >&2
      continue
    fi
    echo "  sweep: ${n} is ${age} min old; destroying it by name" >&2
    ( VM_NAME="$n"; API_SVC="${n}-api"; KUBECONFIG_OUT="${WORKDIR}/${n}.kubeconfig"; SSH_KEY="${WORKDIR}/${n}.id_ed25519"; destroy ) || rc=1
  done < <(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm \
             -o custom-columns=:metadata.name,:metadata.creationTimestamp --no-headers 2>/dev/null)
  return $rc
}

# ---- the snapshot ladder ---------------------------------------------------
# WHY THIS EXISTS. Rebuilding a throwaway from `create` costs a full k3s install
# every time, and the expensive rung is the one you rebuild most: bare k3s, with
# nothing of Tockmox on it yet. A ladder of checkpoints lets an iterative test
# restore to the NEAREST good rung instead of starting over. The rungs the
# harness expects, by convention rather than enforcement:
#
#   s0   bare k3s, immediately after create          ... the expensive one
#   s1   after the documented prerequisites
#   s2   after a completed install
#
# THE VM IS STOPPED FOR EVERY SNAPSHOT, AND THAT IS THE WHOLE POINT.
# KubeVirt will happily snapshot a running guest, and for a k3s server that is a
# trap: etcd's write-ahead log and its data files are snapshotted at slightly
# different instants, so the checkpoint can contain a torn database that mounts,
# boots, and then misbehaves in ways that look like product defects. A
# checkpoint you cannot trust is worse than no checkpoint, because it sends you
# to debug the wrong thing. Stopping costs about a minute; a false finding costs
# an evening. If you ever add an online mode, it needs the guest agent and a
# filesystem freeze, and it still would not make etcd consistent.
vm_running_state() {
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vm "$VM_NAME" -o jsonpath='{.status.printableStatus}' 2>/dev/null || true
}

vm_stop() {
  echo "  stopping ${VM_NAME} (a snapshot of a running k3s node can tear etcd)" >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" patch vm "$VM_NAME" --type merge -p '{"spec":{"running":false}}' >/dev/null
  local deadline; deadline=$(( $(date +%s) + ${TOCKMOX_STOP_TIMEOUT:-300} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # Assert on the VMI being GONE, not on the VM's printable status. The VM
    # object reports Stopped while the VMI is still terminating, and a snapshot
    # taken in that window races the very shutdown it is waiting for.
    if [ -z "$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vmi "$VM_NAME" -o name 2>/dev/null)" ]; then
      echo "  ${VM_NAME} is stopped" >&2; return 0
    fi
    sleep 5
  done
  echo "TIMEOUT: ${VM_NAME} did not stop." >&2; return 1
}

vm_start() {
  echo "  starting ${VM_NAME}" >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" patch vm "$VM_NAME" --type merge -p '{"spec":{"running":true}}' >/dev/null
  local deadline; deadline=$(( $(date +%s) + ${TOCKMOX_START_TIMEOUT:-600} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vmi "$VM_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; then
      echo "  ${VM_NAME} is running" >&2; return 0
    fi
    sleep 5
  done
  echo "TIMEOUT: ${VM_NAME} did not start." >&2; return 1
}

snapshot() {
  local rung="${1:-}"
  [ -n "$rung" ] || { echo "usage: $0 snapshot RUNG   (s0|s1|s2|any label)" >&2; exit 2; }
  local snap="${VM_NAME}-${rung}"
  local was; was="$(vm_running_state)"
  [ -n "$was" ] || { echo "REFUSING: ${NS}/${VM_NAME} does not exist." >&2; exit 1; }

  if [ "$was" = "Running" ]; then vm_stop || exit 1; fi

  echo "taking snapshot ${NS}/${snap}" >&2
  # `|| true` is not decoration. Under `set -e` a rejected apply exits the
  # script HERE, before the restart below, and leaves the guest powered off
  # with no explanation ... which is how a failed snapshot turns into a broken
  # test node. The admission webhook rejects outright when KubeVirt's Snapshot
  # feature gate is disabled, and that is a normal condition on a substrate
  # that registers the CRDs without enabling the gate, so it must be survivable.
  local applied=1
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" apply -f - >/dev/null <<YAML || applied=0
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: ${snap}
  namespace: ${NS}
  labels:
    tockmox.com/harness: executed-docs
    tockmox.com/blast-radius: disposable
    tockmox.com/rung: "${rung}"
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${VM_NAME}
YAML

  local deadline ready; deadline=$(( $(date +%s) + ${TOCKMOX_SNAPSHOT_TIMEOUT:-900} ))
  ready=""
  if [ "$applied" = "1" ]; then
    while [ "$(date +%s)" -lt "$deadline" ]; do
      ready="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vmsnapshot "$snap" -o jsonpath='{.status.readyToUse}' 2>/dev/null || true)"
      [ "$ready" = "true" ] && break
      sleep 5
    done
  else
    # Name the most likely cause rather than leaving a bare rejection. The CRDs
    # being present is NOT evidence the feature is on: `kubectl api-resources`
    # lists VirtualMachineSnapshot whether or not the gate is enabled, so the
    # capability check that looks convincing is the one that misleads.
    echo "  the snapshot was REJECTED. If the message mentions the snapshot feature gate," >&2
    echo "  KubeVirt has the CRDs registered but the gate off, and no snapshot can" >&2
    echo "  succeed until the substrate enables it. That is a substrate change, not a" >&2
    echo "  harness one." >&2
  fi

  # Restart BEFORE asserting, so a failed snapshot does not also leave the guest
  # powered off. The assertion still decides the exit code.
  if [ "$was" = "Running" ]; then vm_start || true; fi

  echo "ARTEFACT: snapshot ${NS}/${snap} readyToUse"
  echo "EXPECTED: true"
  echo "ACTUAL:   ${ready:-<absent>}"
  [ "$ready" = "true" ] || { echo "RESULT:   FAIL ... snapshot is not usable" >&2; exit 1; }
  echo "RESULT:   PASS"
}

restore() {
  local rung="${1:-}"
  [ -n "$rung" ] || { echo "usage: $0 restore RUNG" >&2; exit 2; }
  local snap="${VM_NAME}-${rung}"
  local rname="${VM_NAME}-restore-${rung}"
  [ "$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vmsnapshot "$snap" -o jsonpath='{.status.readyToUse}' 2>/dev/null)" = "true" ] \
    || { echo "REFUSING: snapshot ${NS}/${snap} is absent or not readyToUse." >&2; exit 1; }

  # A restore REQUIRES the target stopped ... KubeVirt rejects it otherwise, and
  # the rejection is a status condition rather than a non-zero exit, so this
  # stop is what keeps the failure from being silent.
  vm_stop || exit 1

  # A restore object is named and one-shot: reusing a name against a second
  # attempt fails as already-satisfied. Clear the previous one for this rung.
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" delete vmrestore "$rname" --ignore-not-found >/dev/null 2>&1 || true
  echo "restoring ${NS}/${VM_NAME} from ${snap}" >&2
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" apply -f - >/dev/null <<YAML
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineRestore
metadata:
  name: ${rname}
  namespace: ${NS}
  labels:
    tockmox.com/harness: executed-docs
    tockmox.com/blast-radius: disposable
spec:
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${VM_NAME}
  virtualMachineSnapshotName: ${snap}
YAML

  local deadline done_; deadline=$(( $(date +%s) + ${TOCKMOX_RESTORE_TIMEOUT:-900} ))
  done_=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    done_="$(kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vmrestore "$rname" -o jsonpath='{.status.complete}' 2>/dev/null || true)"
    [ "$done_" = "true" ] && break
    sleep 5
  done

  echo "ARTEFACT: restore ${NS}/${rname} complete"
  echo "EXPECTED: true"
  echo "ACTUAL:   ${done_:-<absent>}"
  [ "$done_" = "true" ] || { echo "RESULT:   FAIL ... restore did not complete" >&2; exit 1; }
  vm_start || exit 1
  echo "RESULT:   PASS"
}

snapshots() {
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$NS" get vmsnapshot -o custom-columns=\
'RUNG:.metadata.labels.tockmox\.com/rung,NAME:.metadata.name,READY:.status.readyToUse,CREATED:.metadata.creationTimestamp' \
    2>/dev/null || true
}

# TM-0797: refuse before any verb that reaches the hypervisor. `kubeconfig` only
# prints a path and calls nothing.
case "${1:-}" in
  kubeconfig) ;;
  *) : "${TOCKMOX_SUBSTRATE_CONTEXT:?TOCKMOX_SUBSTRATE_CONTEXT is empty: export the kubectl context of the hypervisor cluster that hosts the throwaway VM}" ;;
esac

case "${1:-}" in
  create)  create ;;
  exec)    shift; node_exec "$*" ;;
  reboot)  reboot ;;
  destroy) destroy ;;
  reset)   shift; reset_namespace "${1:-}" ;;
  sweep)   shift; sweep_prefix "${1:-}" "${2:-}" ;;
  snapshot)  shift; snapshot "${1:-}" ;;
  restore)   shift; restore "${1:-}" ;;
  snapshots) snapshots ;;
  ip)      vm_ip; echo ;;
  kubeconfig) printf '%s\n' "$KUBECONFIG_OUT" ;;
  await)   await_guest ;;
  uninstall-proof) uninstall_proof ;;
  evidence) evidence ;;
  *) echo "usage: $0 {create|await|exec CMD|reboot|destroy|reset --every-vm-in-NS|sweep PREFIX MINUTES|snapshot RUNG|restore RUNG|snapshots|ip|kubeconfig|uninstall-proof|evidence}" >&2; exit 2 ;;
esac

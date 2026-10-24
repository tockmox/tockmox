---
okf_version: "0.2"
type: HowTo
title: "Deploying into virtual machines"
description: "The hypervisor settings that break Tockmox when left at their defaults, and the per-platform walkthroughs for Harvester, OpenShift Virtualization, vSphere and Synology VMM."
tags: [virtual-machines, harvester, vsphere, openshift, synology, hypervisor]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Deploying into virtual machines

**Tockmox runs the same on a VM as on metal, so this page does not repeat the
build.** [Prepare a fresh cluster](fresh-install.md) owns the k3s commands, the
join sequence, the storage packages and the node-loss proof, and it owns them
for virtual machines exactly as for physical ones. What this page owns is the
layer underneath: the handful of hypervisor settings that, left at their
defaults, break Tockmox with error messages that point somewhere else.

**Do this page first.** Two of the four settings below are expensive to find
late: a cloned VM's `machine-id` has to be unique **before** it joins the
cluster, and vSphere's `disk.EnableUUID` needs a **power cycle** rather than a
reboot, so it wants setting before first boot. The other two can be corrected on
a running node and are still cheaper to get right now than to diagnose later,
because all four fail with error messages that name the wrong component.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| Administrative access to the **hypervisor**, not just to a VM on it | Every setting on this page is changed on the host, the virtual switch or the VM definition. None of them can be fixed from inside the guest | You can open the port group or VM network settings and save an edit to them |
| Host capacity for the shape you picked | The VM allocations in [size the VMs](#size-the-vms) are on top of what the hypervisor keeps for itself | Free host RAM is at least the sum of the VM allocations you are about to make |
| A flash-backed datastore for the VM disks | etcd and Prometheus are both latency-sensitive, and a slow virtual disk presents as a network fault rather than as a disk one | The datastore or storage pool backing the VMs is SSD or NVMe |
| A network the VMs can be attached to that reaches your LAN | MetalLB advertises into it, and every node has to be on the same layer-2 segment as the address pool | A test VM on that network gets an address inside your `lanCIDR` from `ip -4 addr show` |
| The base OS image you will install | Step 1 of [prepare a fresh cluster](fresh-install.md#1-choose-the-node-os) decides which; cloud images usually lack the storage packages | You have the ISO or cloud image, and know whether it is the immutable one |
| Everything in [prepare a fresh cluster § before you begin](fresh-install.md#before-you-begin) | You continue onto that page as soon as the VMs exist | Run its checks there, not here |

**Estimate, not a measurement: 30 to 60 minutes** of hypervisor work before you
reach step 1 of [prepare a fresh cluster](fresh-install.md), most of it template
preparation and waiting for a base image to install.

## Where each step happens

Three places are involved and the page moves between them. Command blocks carry
the last two in bold **in the prose immediately above the block**, where a copy
button cannot strip it; the first has no commands, because it is settings rather
than a shell:

| Where | What happens there |
|---|---|
| **The hypervisor** | Every setting in [the four that bite](#the-four-settings-that-actually-bite) and in the per-platform sections. Changed in the host's UI or CLI, never from inside a guest |
| **NODE** | Inside a Tockmox VM, over SSH or at its console. This is where the identity regeneration and the clock check run |
| **WORKSTATION** | Your own machine, against the cluster's kubeconfig. Every success condition that needs a cluster |

## What this page owns, and what it does not

| You want to | Go to |
|---|---|
| Know which hypervisor settings break Tockmox | [The four settings that actually bite](#the-four-settings-that-actually-bite), below. **Required**, all platforms |
| Size the VMs | [Size the VMs](#size-the-vms), below, then [sizing](sizing.md) for the tiers behind the numbers |
| Find the settings on your platform | [Harvester](#suse-harvester), [OpenShift Virtualization](#red-hat-openshift-virtualization), [vSphere](#vmware-vsphere-and-esxi), [Synology VMM](#synology-virtual-machine-manager) |
| Install k3s, join nodes, install ArgoCD | [Prepare a fresh cluster](fresh-install.md). Not this page |
| Install the storage packages | [Prepare a fresh cluster § 2](fresh-install.md#2-install-the-storage-packages-on-every-node). Not this page |
| Prove the cluster survives losing a node | [Prepare a fresh cluster § 4f](fresh-install.md#4f-prove-the-cluster-survives-a-node-loss--multi-node-only). This page adds only the hypervisor-side way to pull the plug |
| Set replica counts and the address pool | [Storage](../administration/storage.md#longhorn-replica-count) and [load balancing](../administration/load-balancing.md#the-address-pool-needs-a-decision-before-you-start). Not this page |

## Size the VMs

**Required.** The tiers, and how the numbers were produced, are in
[sizing](sizing.md). What is added here is the hypervisor overhead, which is
mostly a warning about what to spend on:

| Shape | VMs | vCPU each | RAM each | Disk each |
|---|---|---|---|---|
| **Single node** | 1 | 8 | 24 GB | 250 GB |
| **Multi-node** (recommended) | 3 servers, plus any workers you add | 8 | 32 GB | 500 GB |

The shape decision itself is
[prepare a fresh cluster § 3](fresh-install.md#3-choose-your-cluster-shape),
including why two nodes is never the answer and why anything past three joins as
an agent rather than as a fourth etcd member.

**Size workers for what you intend to run on them**, not from the table above.
Three servers is the resilience shape; a worker is capacity, and the row that
fits it is whatever the workload needs.

**vCPU is rarely the constraint.** The reference deployment is recorded in
[sizing § reference](sizing.md#reference) as idling at about 1.07 cores. Memory
and disk are what run out.

**Thin provisioning is fine; a slow datastore is not.** Back the VMs with SSD or
NVMe. On a spinning datastore etcd starts missing heartbeats, and the symptom
looks like a network problem rather than a storage one. This is the single most
common way a VM deployment feels broken while every component reports healthy.

> **Unverified.** The etcd-on-spinning-disk failure description is a belief held
> from etcd's documented latency sensitivity, not a measurement taken on a
> Tockmox cluster. Nobody has deliberately built one on a spinning datastore and
> written down what it looked like.

## The four settings that actually bite

These are hypervisor-agnostic. **All four are Required.** The per-platform
sections below say where each one lives on your hypervisor.

### 1. Layer 2 must let MetalLB answer for an IP it does not own

MetalLB in L2 mode replies to ARP for an address that is not the VM's own.
Most virtual switches drop that by default as anti-spoofing. The load-balancer
IP then never answers and every diagnostic points at MetalLB, which is
behaving correctly.

You need the VM's port group or network to permit **MAC spoofing / forged
transmits**. Promiscuous mode is usually also required.

**How you know it is wrong:** the `Service` gets an `EXTERNAL-IP`, MetalLB's
logs look healthy, and nothing on the LAN can reach it. The full anatomy,
including the different failure that looks identical, is in
[load balancing § layer 2 has to permit it](../administration/load-balancing.md#layer-2-has-to-permit-it).

**Success condition:** this one cannot be proved until MetalLB exists, which is
during [installation](install.md). Set it now, and verify then, from a machine
on the LAN that is not the hypervisor host:

**WORKSTATION** ... after the platform layer is up

```bash
kubectl get svc -A | grep LoadBalancer
```

**YOU SUPPLY:** `LOADBALANCER_IP`, which is the `EXTERNAL-IP` that command
prints. It is exported on the first line below rather than typed into the URL,
so the address you read is the address you request.

**The request is a second host, which is why it is a second block.** Run it from
**another machine on the LAN**, not the hypervisor host and not a cluster node.
Both of those can answer locally and pass a test that the LAN would fail, which
is the whole thing this check exists to catch. Your own **WORKSTATION** is the
right machine if it is on that LAN and is neither of those two.

```bash
export LOADBALANCER_IP=YOUR_LOADBALANCER_IP
curl -sS -o /dev/null -w '%{http_code}\n' "http://$LOADBALANCER_IP/"
```

Any HTTP status code is a pass here; the test is that something answered at all.

### 2. Cloned VMs share identities that must be unique

**Conditional. This applies if** your nodes came from a template or a clone
rather than from separate OS installs. Test it before you join anything:

**WORKSTATION**

```bash
for h in tockmox-1 tockmox-2 tockmox-3; do
  printf '%-12s %s\n' "$h" "$(ssh "$h" cat /etc/machine-id)"
done
```

**YOU SUPPLY:** your own node hostnames in place of `tockmox-1` through
`tockmox-3`. Three identical values means this section applies and you must fix
it now, before Longhorn is confused. Three different values means skip it.

This is the single biggest multi-node problem on a hypervisor and it is silent.
A VM cloned from a template carries the template's `/etc/machine-id`, and often
its disk UUIDs:

- **Longhorn identifies disks by UUID.** Two nodes reporting the same disk UUID
  means replicas will not schedule where you expect, and the error talks about
  scheduling rather than about duplication.
- systemd, DHCP identity and some CNI paths key off `machine-id`. A carried
  `machine-id` also means a carried DHCP client identity, so two nodes can
  contend for one lease.

**On every clone, before joining it to the cluster:**

**YOU SUPPLY:** the hostname on the `hostnamectl` line. `tockmox-2` below is an
example, and it has to be **unique per node** ... pasting this block unchanged
onto three clones trades one duplicate identity for another.

**NODE**

```bash
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo systemd-machine-id-setup
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo hostnamectl set-hostname tockmox-2
sudo reboot
```

**Success condition:** re-run the `for` loop above. Three different
`machine-id` values, and `hostnamectl` on each node reports the hostname you
set. That check is also the first of the three in
[prepare a fresh cluster § before you install](fresh-install.md#before-you-install-on-every-node),
so passing here means you arrive there with one item already done.

**Doing it once, in the template, is better than doing it three times.** Every
hypervisor section below names where its cloud-init or customisation hook goes,
so a clone never boots with a duplicate identity in the first place.

### 3. Longhorn needs packages the base image usually lacks

`open-iscsi`, an NFS client and a running `iscsid` are required on every node
before storage works. **The commands, including the immutable-OS variants, are in
[prepare a fresh cluster § install the storage packages](fresh-install.md#2-install-the-storage-packages-on-every-node)**,
and the check-and-fix form for a cluster you already run is in
[prepare a cluster you already have § check 4](existing-cluster.md#check-4-storage-packages-on-every-node).
They live in exactly one place so the pages cannot drift apart.

Two things are worth saying here rather than there. This is **not** a VM concern
... it applies equally to bare metal, and it is listed among the hypervisor
settings only because cloud images are the most common place to meet a base
image that lacks them. And missing `iscsid` produces volumes stuck in
`attaching` with a CSI error that names the volume, not the missing daemon.

**Success condition:** the one on that page, run on every node.

### 4. Time must already be synchronised

etcd and TLS both fail badly on drift, and VM clocks drift more than physical
ones, especially after a snapshot restore or a suspend. Confirm NTP is running
and synchronised on every node before installing anything:

**NODE**

```bash
timedatectl status | grep -E 'synchronized|NTP service'
```

**Success condition:** `System clock synchronized: yes` and
`NTP service: active`, on every node. Anything else is a stop.

**A VM-specific trap that is not on the metal page:** a suspended or
snapshot-restored VM resumes with a stale clock and may take minutes to
converge. If you snapshot a node, re-run this check after every restore rather
than assuming the sync survived. On a disconnected site, where the source is
yours to build, see [time synchronisation](time-sync.md).

## Find your hypervisor

| Platform | Section | The setting most often missed |
|---|---|---|
| SUSE Harvester | [below](#suse-harvester) | CPU model left emulated |
| Red Hat OpenShift Virtualization | [below](#red-hat-openshift-virtualization) | `masquerade` network binding |
| VMware vSphere and ESXi | [below](#vmware-vsphere-and-esxi) | Port group security, all three fields |
| Synology VMM | [below](#synology-virtual-machine-manager) | VM disk not on an SSD pool |
| QNAP, Asustor and similar | [with Synology](#synology-virtual-machine-manager) | Same shape, none documented from a clean install |

OpenShift Virtualization appears here as the hypervisor under your VMs. Tockmox
installed onto an OpenShift cluster itself is not covered: no
security-context-constraints profile ships and no such install is documented.

## SUSE Harvester

Harvester is KubeVirt on top of k3s, so your Tockmox nodes are KubeVirt VMs.

**Networking.** Create a VM Network (Networks, then VM Networks) on the VLAN you
want, backed by a cluster network. Attach the VM to that rather than to the
default management network. Harvester bridges VM networks, so ARP for a
MetalLB address passes without extra flags ... this is the platform where
setting 1 is usually satisfied for free. Verify it anyway, with the check in
[setting 1](#1-layer-2-must-let-metallb-answer-for-an-ip-it-does-not-own).

**Disks.** Add the root disk as `virtio`. Harvester's own storage is Longhorn,
so you are running Longhorn inside a VM whose disk is a Longhorn volume. That
works and is what the reference dev/test rig does, but understand the layering
before you reason about a performance number: replication at both levels means
writes land more times than you may intend.

**Cloud-init.** Harvester's user-data field is the cleanest place to do the
`machine-id` regeneration from [setting 2](#2-cloned-vms-share-identities-that-must-be-unique)
and the package installs from
[prepare a fresh cluster § 2](fresh-install.md#2-install-the-storage-packages-on-every-node),
so a cloned template never boots with a duplicate identity in the first place.

**CPU.** Set the CPU model to `host-passthrough` if the option is offered.
Default emulated models cost real throughput on container image decompression.

## Red Hat OpenShift Virtualization

Also KubeVirt, so the concepts match Harvester with different names.

**This section is about OpenShift as the hypervisor.** Your Tockmox nodes are
VMs that OpenShift Virtualization runs, and Kubernetes inside those VMs is the
cluster Tockmox installs into. It does not cover installing Tockmox onto an
OpenShift cluster itself: no security-context-constraints profile ships, and no
install onto OpenShift is documented.

**Network binding is the setting that matters.** The default `masquerade`
binding NATs the VM behind the pod network, which breaks MetalLB L2 outright:
the VM cannot answer ARP for an address on your LAN because it is not on your
LAN.

Use a **bridge** binding on a `NetworkAttachmentDefinition` backed by a
`NodeNetworkConfigurationPolicy` (NMState) that owns a real interface. In the
VM spec:

```yaml
spec:
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: lan
              bridge: {}          # NOT masquerade
      networks:
        - name: lan
          multus:
            networkName: tockmox-lan     # YOU SUPPLY: your NAD's name
```

**Disks.** Provision root disks as `DataVolume`s on a block-mode StorageClass
where you have one. Filesystem-mode PVCs put a disk image on a filesystem on a
volume, and the extra layer is felt by etcd first.

**Guest tooling.** Install `qemu-guest-agent` in the VM so OpenShift reports
IPs and can quiesce cleanly.

**A note on nesting.** You are running Kubernetes inside VMs managed by
Kubernetes. Everything works, but when you debug, be explicit about which
cluster a `kubectl` is pointing at. Name your kubeconfig contexts something
that says which is which ... `default` and `local` will mislead you at the
worst moment.

## VMware vSphere and ESXi

**Port group settings, and this is the one people miss.** On the port group
(or distributed port group) carrying the Tockmox VMs, set:

| Setting | Value | Why |
|---|---|---|
| **Promiscuous mode** | Accept | MetalLB L2 and some CNI paths |
| **MAC address changes** | Accept | MetalLB answers for an address that is not the vNIC's |
| **Forged transmits** | Accept | Same reason as MAC address changes |

All three default to Reject on a distributed switch. Leave them and the
load-balancer IP will be assigned, look healthy, and answer nothing.

**`disk.EnableUUID` must be TRUE.** VM Options, then Advanced, then
Configuration Parameters: add `disk.EnableUUID = TRUE`. Without it the guest
does not see a stable disk serial, and anything identifying disks by UUID ...
Longhorn included ... behaves unpredictably. **Set it before first boot if you
can; it needs a power cycle, not a reboot.**

**Success condition**, inside the guest, before you install k3s:

**NODE**

```bash
lsblk -o NAME,SERIAL,WWN
```

The root disk has a non-empty serial or WWN. An empty column means
`disk.EnableUUID` did not take, and a reboot will not fix it.

**Adapters.** VMXNET3 for the NIC and Paravirtual (PVSCSI) for the disk
controller. The defaults (E1000e, LSI Logic) work and cost you throughput and
CPU on exactly the workloads that are already the bottleneck.

**Do not use vSphere snapshots as your backup story.** A snapshot of a running
node is crash-consistent at best, and restoring one node of three into a
cluster whose etcd has moved on is a genuinely bad afternoon. Tockmox's backup
path exists for this; see [backup-restore](../operations/backup-restore.md).

**Cloning.** If you deploy the nodes from a template,
[setting 2](#2-cloned-vms-share-identities-that-must-be-unique) is mandatory.
vSphere's guest customisation will handle hostname and network but will not
regenerate `machine-id` on most Linux images.

## Synology Virtual Machine Manager

The smallest hypervisor on this page, and the one where the hardware sets the
limit before the hypervisor does. Which NAS units make sense as hosts at all,
and what tier to expect from them, is in
[hardware platforms](hardware-platforms.md#nas-units-with-a-hypervisor); this
section is the settings.

**x86 models only.** VMM exists on the Plus, XS and RS lines. ARM models do
not offer it, and would fail the architecture requirement anyway.

**Memory.** DSM keeps its share. Leave it about 4 GB and give the VM the
rest: a 32 GB unit hosts a reference-shape VM, a 16 GB unit hosts the minimal
tier's 12 GB with nothing spare. Do not allocate the full installed RAM to
the VM; DSM under memory pressure takes its storage services with it, which
are the disks your VM is on.

**Disk.** The VM's disk must live on an SSD storage pool. An SSD cache in
front of spinning disks is better than nothing and is not the same thing;
etcd's sync latency goes to the pool eventually. A unit with no SSD at all
is the wrong host, and the failure mode is the one named in
[size the VMs](#size-the-vms): heartbeat misses that look like network problems.

**Adapters.** VirtIO for both NIC and disk. The emulated fallbacks work and
cost throughput exactly where the platform is already tight.

**Network.** Attach the VM to a bridged vSwitch network. Bridging generally
lets MetalLB's L2 answers pass, so setting 1 is usually satisfied without
extra settings ... the same position as Harvester. Verify anyway, with the
check in
[setting 1](#1-layer-2-must-let-metallb-answer-for-an-ip-it-does-not-own),
from another machine on the LAN rather than from the NAS.

**Snapshots are not backups.** The vSphere note applies unchanged: a snapshot
of a running node is crash-consistent at best. Tockmox's backup path exists
for this, and if this NAS is also where those backups land, read the
one-power-supply warning in
[hardware platforms](hardware-platforms.md#nas-units-with-a-hypervisor).

**QNAP Virtualization Station, Asustor and similar** are the same shape:
x86 models only, VirtIO adapters, SSD-backed VM disk, verify the L2
behaviour rather than assuming it. None of these platforms has been used for
a documented clean install yet; if you run one, the defect list is a welcome
contribution (see [what to record](#what-to-record-while-you-do-this) below).

## Build the cluster

**Required.** With the four settings applied and the VMs provisioned, the build
is [prepare a fresh cluster](fresh-install.md), start to finish, with no
VM-specific substitutions. Nothing on that page changes because the machine is
virtual.

Two things are worth carrying with you:

- **Use the same base image for every node**, and pin the same
  `INSTALL_K3S_VERSION` across all of them. A template that was patched between
  two clones is a version skew you did not choose.
- **A static address or a DHCP reservation, per node.** A node that changes
  address mid-cluster is a bad first experience, and on a hypervisor it is more
  likely, because a rebuilt VM presents a new MAC. Carrying the MAC forward does
  not by itself carry the lease when the DHCP client identity is derived from
  `machine-id`, which
  [setting 2](#2-cloned-vms-share-identities-that-must-be-unique) has just
  regenerated.

**After the cluster is up, three site values want revisiting**, and all three
are owned elsewhere:

| Value | Where it is decided |
|---|---|
| Longhorn replica count, and `replicaSoftAntiAffinity` | [storage § Longhorn replica count](../administration/storage.md#longhorn-replica-count) |
| Which workloads sit on the replicated class and which on the node-local one | [storage § the principle](../administration/storage.md#the-principle-replicate-at-exactly-one-layer) |
| `addressPool.range`, and the layer-2 requirement across every node | [load balancing § the address pool](../administration/load-balancing.md#the-address-pool-needs-a-decision-before-you-start) |

You set them during [installation](install.md), in your site values.

**Success condition:** the one on
[prepare a fresh cluster § 4e](fresh-install.md#4e-finish-every-node--both-shapes),
run on every node. It asserts four things at once, and a VM that got any of the
settings above wrong fails it there rather than several pages later.

### Prove it survives losing a node

**Conditional. Run this if** you built more than one node:

**WORKSTATION**

```bash
kubectl get nodes --no-headers | wc -l
```

A count above 1 means this applies.

The procedure is
[prepare a fresh cluster § 4f](fresh-install.md#4f-prove-the-cluster-survives-a-node-loss--multi-node-only).
The only VM-specific part is how you pull the plug: use the hypervisor's own
**power off** or **force off**, not a guest shutdown and not a pause. A pause is
not a node loss, it is a clock jump, and it tests
[setting 4](#4-time-must-already-be-synchronised) instead.

**If you run this again later, with workloads on the cluster**, the outcome is
deliberately asymmetric: replicated volumes come back on another node,
node-local ones do not and should not. That is the storage policy working rather
than a failure, and it is written up in
[storage § losing a node](../administration/storage.md#losing-a-node-and-the-asymmetry-that-is-the-policy-working).

## What to record while you do this

**Optional, and the highest-value optional thing on this page.** What you get:
your install becomes a set of documentation defects with reproduction steps.
What you lose by skipping it: a green cluster and no evidence about the docs.

If you are running this as the first clean install, the defect list is the
deliverable, not a working cluster. A green install that you did not write
anything down about has told you almost nothing.

Worth capturing as you go:

- every command you ran that is **not** in the docs, and why you needed it
- every place the docs said something that turned out not to be true
- the wall-clock time from empty VM to a console you can log into
- anything that failed and then worked on a retry, which usually means an
  ordering assumption rather than a flake
- the exact text of any error you had to search for

An install that needs three undocumented commands is not a failed install. It
is three documentation defects with precise reproduction steps, which is worth
more than a green run.

## What is not certified here

**No hypervisor on this page has a recorded clean install of Tockmox from an
empty VM to a working console.** The four settings are causes that have been met
and diagnosed; the per-platform sections are where those causes live on each
product. Neither of those is the same claim as "this page has been executed as
written", and reading a page cannot establish that it has. The
[testing standard](../testing-standard.md) says which paths are covered.

Specifically unverified, and marked as such where they appear: the
etcd-on-slow-storage failure description, and the MetalLB speaker-election
requirement across nodes. **Harvester is the only platform here with a Tockmox
deployment behind the text**, and that is the reference dev/test rig rather than
a run of this page. OpenShift Virtualization, vSphere and Synology VMM are
written from their vendors' own settings and from the four causes, with no
recorded install on any of them.

**No date is claimed for any per-platform setting**, because none was recorded
when the settings were written down. Treat them as current-as-of-reading and
check them against your hypervisor's own documentation, which is where they came
from.

## Next

**Continue at [prepare a fresh cluster](fresh-install.md)**, which is the build
itself: node OS, storage packages, k3s, the joins, ArgoCD and sealed-secrets.
Nothing on it changes because your machines are virtual.

Then [installation](install.md), where the three site values in
[build the cluster](#build-the-cluster) are actually set.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

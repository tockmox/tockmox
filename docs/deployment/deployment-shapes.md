---
okf_version: "0.2"
type: Reference
title: "Deployment shapes"
description: "Which ways of deploying Tockmox a release gate runs, which are documented but never run by one, and which are neither, in one table."
tags: [deployment, shapes, gated, support, prerequisites]
status: stable
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [operator, machine]
---

# Deployment shapes

**One shape is gated: a single node running openSUSE MicroOS with k3s, as a
virtual machine on SUSE Harvester, on x86_64.** Every release gate to date has
run there and nowhere else. Every other way of deploying Tockmox is either
documented without ever being run by a gate, or neither documented nor run.

This page is the one place that says which is which. Every install page that
names a deployment shape links here, and each names the row of the table that
shape sits in. A shape that reads as supported anywhere in these docs and is
not in the first row of the table is a defect in the page that says so.

## The three rows

| Row | What it means | What you can rely on |
|---|---|---|
| **Gated** | A release gate runs this shape against the exact commit that becomes the tag, and a failure stops the release. The gate report names the shape it ran on | A defect on this shape is a Tockmox defect that the release process is built to catch |
| **Documented, not gated** | Pages describe how to deploy this shape and the steps are written from the failures the project has met. No release gate runs it | The instructions are expected to work. Nothing re-proves them at each release, so a step that has rotted is found by the reader |
| **Neither** | No page gives instructions for this shape, or a page says outright that it is untested or unsupported. No gate runs it | Nothing. It may work. If it does, that is not a result this project has produced |

"Gated" does not mean "certified for production" and does not mean "load
tested". It means that one specific, named thing is exercised before every
tag. The release gate and its evidence are described in
[RELEASING](../../RELEASING.md) and
[operator gates](../development/releasing-operator-gates.md).

## The table

The rows below are in order: the gated shape, then the documented ones, then
the ones with neither. The **Row** column is the label other pages quote.

| Row | Shape | What backs it | Read |
|---|---|---|---|
| **Gated** | **Single node, openSUSE MicroOS, k3s, a KubeVirt virtual machine on SUSE Harvester, x86_64**, sized as the [reference tier](sizing.md#reference) (8 cores, 24 GB) | The lab greenfield install and the upgrade from the previous release, run on this shape against the release commit before every tag, on one lab. The latest gate report is attached to each Release | [Prepare a fresh cluster](fresh-install.md) with the one-node shape and the MicroOS blocks, and [the Harvester section](virtual-machines.md#suse-harvester) |
| **Documented, not gated** | **Three-node k3s with embedded etcd, the [HA tier](sizing.md#ha)**, and workers added beside the three | Procedure and node-loss proof written in [fresh install](fresh-install.md#3-choose-your-cluster-shape). The maintainer's own production cluster runs the charts on three control-plane nodes among six, which is use rather than a gate. No release gate installs or upgrades more than one node | [Prepare a fresh cluster](fresh-install.md), the three-node shape, then [the API endpoint](../administration/api-endpoint.md) |
| **Documented, not gated** | **Single node on a conventional Linux** (Debian, Ubuntu, RHEL or Rocky, SLES or Leap), or on bare metal such as a mini PC | Package steps per OS in [fresh install](fresh-install.md#2-install-the-storage-packages-on-every-node). The [executed-docs harness](../testing-standard.md) runs preparation paths on an Ubuntu guest, which exercises a page and is not a release gate. Only MicroOS has been run as the platform the project is developed against | [Prepare a fresh cluster](fresh-install.md), [hardware platforms](hardware-platforms.md) |
| **Documented, not gated** | **A Kubernetes cluster you already run**, 1.30 or newer | Six checks in [existing cluster](existing-cluster.md). The page says the checks have not been executed against a cluster the project does not control | [Prepare a cluster you already have](existing-cluster.md) |
| **Documented, not gated** | **Other hypervisors under the nodes:** OpenShift Virtualization, VMware vSphere and ESXi, Synology VMM, and QNAP and Asustor by the same pattern | Per-platform settings in [virtual machines](virtual-machines.md), written from each vendor's documentation and from four causes met elsewhere. The page records no install on any of them | [Deploying into virtual machines](virtual-machines.md) |
| **Documented, not gated** | **A substituted component:** RKE2, Flatcar, Leap Micro, Calico and the other entries the register marks **documented** | The [alternatives register](../alternatives.md), whose own tiers are *tested*, *documented* and *unsupported*. Its *documented* is this row. Its *unsupported* is the row below | [Alternatives register](../alternatives.md) |
| **Neither** | **Proxmox and other KVM-based hypervisors** | Not separately documented. The four hypervisor settings in [virtual machines](virtual-machines.md#the-four-settings-that-actually-bite) are expected to decide the outcome there, and no install has been recorded | [Hardware platforms](hardware-platforms.md#enterprise-hypervisors) |
| **Neither** | **Tockmox installed onto an OpenShift cluster itself**, as opposed to onto VMs that OpenShift Virtualization runs | No security-context-constraints profile ships and no install is documented | [Deploying into virtual machines](virtual-machines.md#red-hat-openshift-virtualization) |
| **Neither** | **Managed cloud Kubernetes, and cloud virtual machines** | Nothing checks where a machine is, so an instance that meets the floor may work. It is not documented, and MetalLB's layer 2 mode does not work on most clouds | [Hardware platforms](hardware-platforms.md#what-this-page-leaves-out-on-purpose) |
| **Neither** | **arm64**, a Mac running the platform in a Linux VM, and appliance ecosystems | Stated on [hardware platforms](hardware-platforms.md#cpu-architecture) as untested and unclaimed | [Hardware platforms](hardware-platforms.md) |
| **Neither** | **Other node operating systems and distributions the register marks unsupported:** Talos Linux, Fedora CoreOS, Ubuntu Core, kubeadm and upstream Kubernetes assembled by hand | The [alternatives register](../alternatives.md) gives no instructions and no gate coverage for them. The Talos and Flatcar iSCSI notes in [existing cluster](existing-cluster.md#check-4-storage-packages-on-every-node) are marked not yet exercised | [Alternatives register](../alternatives.md) |

## Modes that cut across the shapes

These are choices made on top of a shape, not shapes. Each takes the row of the
shape underneath it.

| Mode | Where it sits |
|---|---|
| **Air-gapped install** | [Air-gapped installs](airgap.md). Each release repeats the disconnected install on the gated shape or says in the release notes that it was skipped. On any other shape it takes that shape's row |
| **Profiles** (minimal, reference, household-sso, observability-off) | [Profiles](profiles.md). A profile changes what is deployed, not where. The gate installs the shipped defaults. Another profile on the gated shape is documented, not gated |
| **The AI plane's inference host** | Not part of any shape on this page. Models run on hardware the platform points at, sized separately in [the AI plane](../usage/ai-plane.md) |

## Which row is your plan

| If your plan is | Your row | What to do about it |
|---|---|---|
| One MicroOS node as a Harvester VM | Gated | Follow the pages as written |
| Three nodes, or any node count above one | Documented, not gated | Follow [fresh install](fresh-install.md) and run its node-loss proof on your cluster before trusting it. Plan the API endpoint |
| A different node OS, bare metal, another hypervisor, or a cluster you already run | Documented, not gated | Follow the page. Report the step that did not work, since nothing at the release would have |
| Proxmox, a cloud, arm64 or OpenShift itself | Neither | Treat it as an experiment. [CONTRIBUTING](../../CONTRIBUTING.md) welcomes the defect list |

## How a shape moves to the gated row

A shape moves when a release gate installs it and the gate report names it.
Reading a page does not move it, and neither does one person's successful
install. The multi-node shape is the next candidate: when a three-node
embedded-etcd install is part of the release gate, its row moves to the first
line of the table and this page says so in the same commit.

A shape moves the other way when its gate stops running. A row that reads
*Gated* on a page that is older than the last gate report is a claim to check
against that report.

## What is not certified here

**The table is a statement about the project's own gate coverage, not a
compatibility list.** [Hardware platforms](hardware-platforms.md) says there is
no compatibility list and no certification programme, and nothing here changes
that.

- **The gated row is one lab.** One node, one hypervisor, one site. It proves
  that shape installs and upgrades there. It says nothing about scheduling
  across nodes, failover, or any other storage backend.
- **"Documented, not gated" is a judgement from reading and from field
  failures.** It is not a measurement of how often those instructions work.
- **The maintainer's production cluster is evidence of use, not of a gate.**
  It is listed because a reader deciding on three nodes will ask, and it is not
  counted in the first row.
- **The pages that make shape claims were checked for a link to this page, not
  for the truth of every sentence beside the link.** The check is a page-level
  rule in `tools/doc-claims.txt`: a page that names one of these shapes and
  does not link here fails the docs gate. Whether a passage carries the right
  row is a review judgement.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

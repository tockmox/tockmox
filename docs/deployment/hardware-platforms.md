---
okf_version: "0.2"
type: Reference
title: "Hardware platforms"
description: "Which classes of machine people run Tockmox on, what each is good for, and where the edges are."
tags: [hardware, platforms, mini-pc, nas, deployment, sizing]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Hardware platforms

[Sizing](sizing.md) says how much hardware each tier needs. This page says
which hardware people run it on: the classes of machine, what each is good
for, and where the edges are.

**There is no compatibility list and no certification program.** The floor is
a spec, not a device: an x86_64 machine that meets a tier in
[sizing](sizing.md) and runs a conformant Kubernetes. Everything named below
is an example of a class, not a promise about a model.

One reminder before any of it: **models do not run on these machines.** The
AI plane points at an OpenAI-compatible endpoint on hardware sized for
inference ... see [the AI plane](../usage/ai-plane.md) and
[sizing](sizing.md#sizing-the-ai-plane-separately). Every machine on this
page is sized for the platform, not for models.

## CPU architecture

Tockmox is developed and tested on **x86_64**. Every observed number in these
docs was produced on x86_64.

arm64 is **untested and unclaimed**. The pieces are closer than you might
expect ... nothing in the charts pins an architecture, and most of the
upstream images publish arm64 manifests ... but most is not all, nobody has
validated a full render and deploy, and an untested claim is worse than no
claim. If you run the experiment (a Raspberry Pi 5 with 16 GB and NVMe
storage is the obvious candidate, sitting exactly at the minimal tier's
floor), the defect list is a contribution we would welcome. See
[CONTRIBUTING](../../CONTRIBUTING.md).

## Mini PCs

The NUC class: Intel NUCs and their descendants (the line moved to ASUS in
2023), Minisforum, Beelink and the rest of the category. Bare-metal k3s, no
hypervisor tax, NVMe on board, and current models take 64 GB of RAM or more.

A recent mini PC with 32 GB clears the reference tier with headroom; 64 GB
covers the resilient tier. This is the shape the platform is happiest on,
and three of them are the smallest sensible HA build.

The bottom of the category is a different machine. N-series and Celeron
models with soldered 8 or 16 GB are minimal-tier hardware: they run the
platform, and [what that tier does not do](sizing.md#minimal) applies in
full.

## Used office PCs

The one-litre corporate desktops that come off lease by the pallet: Dell
OptiPlex Micro, HP EliteDesk and ProDesk Mini, Lenovo ThinkCentre Tiny. Two
or three generations old, they cost less than a new N-series mini PC and
outrun it, they take 32 to 64 GB of ordinary SODIMMs, and most have an NVMe
slot.

Two things to check on the exact configuration before buying: that the NVMe
slot exists (some low-end SKUs are SATA-only, and
[sizing](sizing.md#reference) is blunt about spinning disk), and the RAM
ceiling of that generation. Otherwise the mini-PC guidance applies
unchanged. This is likely the cheapest path to the resilient tier, and
three of them the cheapest sensible path to HA.

## NAS units with a hypervisor

x86 NAS models from Synology (the Plus, XS and RS lines), QNAP, Asustor and
similar can host Tockmox in a Linux VM under the vendor's hypervisor:
Virtual Machine Manager on Synology, Virtualization Station on QNAP. The VM
lane is the supported shape ... do not attempt k3s inside the vendor's
container layer. Per-hypervisor settings are in
[virtual machines](virtual-machines.md#synology-virtual-machine-manager).

Set expectations by the hardware, not the badge:

- **RAM is the ceiling.** The NAS OS keeps a share. A 32 GB unit hosts a
  reference-tier VM; a 16 GB unit leaves roughly the minimal tier's 12 GB
  floor and nothing spare.
- **Spinning disks are the deal-breaker.** etcd and Prometheus on an
  all-HDD pool produce failures that look like network problems. The VM
  disk needs an SSD pool; a box with no SSD at all is the wrong host.
- **ARM NAS models are out entirely.** See the architecture section above.

What a NAS host is good for: the minimal profile on hardware you already
own and already keep powered. What it is not: a growth path ... when you
outgrow it, the move is to one of the classes above, not a bigger NAS.

One rule worth stating because this hardware invites breaking it: if the
NAS is also your backup target, Tockmox-on-the-NAS puts the platform and
its backups behind one power supply. The resilient tier's requirement that
backups survive the machine (see [sizing](sizing.md#resilient)) means a NAS
can host the platform or hold its backups, not both.

## Enterprise hypervisors

Harvester, OpenShift Virtualization and vSphere have full walkthroughs in
[virtual machines](virtual-machines.md), including the four hypervisor
defaults that break the install. Proxmox and other KVM-based platforms are
not separately documented, but the same four settings decide the outcome
and the walkthroughs transfer.

## What this page leaves out, on purpose

- **Cloud VMs.** Tockmox installs on any cloud instance that meets the
  floor, and nothing checks where the machine is. It is not documented as a
  platform because the point of the project is AI on hardware you control;
  renting that hardware from a hyperscaler is a different decision than the
  one this project serves. If you do it anyway, know that MetalLB's L2 mode
  does not work on most clouds ... the load-balancer story becomes your
  cloud's, and wiring it is yours.
- **Macs.** Apple silicon appears in this stack as the inference host (see
  [the AI plane](../usage/ai-plane.md)), not the platform host. A Linux VM
  on the same Mac that serves models can run the platform; it is untested,
  and it ties the platform's uptime to the machine most likely to be
  rebooted.
- **Appliance ecosystems** (umbrelOS, CasaOS and similar). Different
  packaging model, different promises. No integration exists or is planned,
  and this page saying so is the documentation.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "Prerequisites"
description: "Signpost: what Tockmox needs before installing, and which of the two preparation paths applies to you."
tags: [prerequisites, deployment, signpost]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Prerequisites

Tockmox needs three things installed and four values decided. Everything else it
installs itself.

**Three things:** a Kubernetes cluster, ArgoCD 2.6 or newer, and sealed-secrets
with your own key. A thing is a prerequisite here only if it either **cannot
install itself** or **must exist before the GitOps loop can read your
repository** ... which is why cert-manager, MetalLB, storage and ingress are
not on the list. They are wave-2 charts. The argument is in
[ArgoCD § why it is a prerequisite](../administration/argocd.md#why-it-is-a-prerequisite).

**Four values:** your LAN's CIDR, a free address range for load balancing, an
internal DNS zone, and where the AI plane points. The charts cannot guess any of
them and the first two fail the render.

## Which path is yours

| Your situation | Go to |
|---|---|
| **Machines, but no Kubernetes yet** | **[Prepare a fresh cluster](fresh-install.md)** ... the recommended path. It chooses k3s and the settings Tockmox expects, and marks the seven things only you can supply |
| **A Kubernetes cluster already running** | **[Prepare a cluster you already have](existing-cluster.md)** ... six checks, each stating the condition that triggers it |

Both finish at [installation](install.md).

## What you do NOT need

- **cert-manager, MetalLB, storage, ingress** ... Tockmox installs these.
- **A public domain** ... internal hostnames need not resolve publicly.
- **Internet access at runtime.** Needed to *fetch* images unless you mirror
  them. Not needed to keep running. See [air-gapped](airgap.md).
- **A container registry** ... see [registry](registry.md) for why Tockmox does
  not ship one and what to stand up instead.

## Sizing and hardware

| If you are | Read |
|---|---|
| Sizing all four tiers with measured numbers | [sizing](sizing.md) |
| Deciding what machine to buy or reuse | [hardware platforms](hardware-platforms.md) |
| Installing into VMs on any hypervisor | [virtual machines](virtual-machines.md) |
| Building the cluster itself, one node or four | [prepare a fresh cluster](fresh-install.md) |

## On equipment, rather than values

Beyond the cluster, a working deployment leans on things around it: LAN DNS
serving the `internalDomain` zone, a firewall, backup storage, a UPS, and for
the AI plane an inference host. Tockmox names no vendor ... the requirement is
the *function*. Worked configuration for each is in
[external integrations](../administration/external-integrations.md).

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

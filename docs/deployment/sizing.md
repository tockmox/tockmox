---
okf_version: "0.2"
type: Reference
title: "Hardware sizing"
description: "Four tiers with measured numbers, from one small box to a cluster you can lose a node from."
tags: [sizing, hardware, tiers, memory, disk, high-availability]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Hardware sizing

Four tiers, from the smallest thing worth running to something you can lose a
node from. Every number here is either **observed** on the reference deployment
or **projected** from observed numbers, and each is labelled which.

**Read the tier names literally.** One box with a tested restore is a good
answer and it is not high availability. Tockmox will not tell you otherwise.

**One thing that scales with people rather than hardware, and this is the page
where you are counting people.** Open WebUI's branding licence stops being
permissive above **50 users** — above that, its terms restrict changing or
removing its branding. Nothing on this page changes because of it and Tockmox
does not enforce it; it is simply the threshold most likely to catch a reader
sizing for a department rather than a household. The full disclosure, with the
other components that carry non-OSI or source-available terms, is in
[third-party licenses](../third-party-licenses.md).

## The tiers at a glance

| | Nodes | CPU | RAM | Disk (per node) | Survives |
|---|---|---|---|---|---|
| **Minimal** | 1 | 4 cores | 12 GB | 100 GB SSD | a process crash |
| **Reference** | 1 | 8 cores | 24 GB | 250 GB SSD | a process crash; a rebuild, from backups |
| **Resilient** | 1 + offsite backups | 8 cores | 32 GB | 500 GB SSD | losing the box, with a restore you have rehearsed |
| **HA** | 3 | 8 cores each | 32 GB each | 500 GB SSD each | losing a node, live |

**Which tiers a release gate runs.** The Reference tier on one MicroOS node as a
Harvester virtual machine is the gated shape. The other single-node tiers are
the same software on other hardware, and the HA tier is three nodes that no
release gate installs: both are **documented, not gated**, per
[deployment shapes](deployment-shapes.md).

CPU is rarely the constraint. The reference deployment idles at **1.07 of 8
cores, about 13%**, observed. Memory and disk are what run out.

## Minimal

Runs `profiles/minimal.yaml`: no log aggregation, no replicated storage, no
identity provider, seven days of metrics. See [profiles](profiles.md).

| | |
|---|---|
| **CPU** | 4 cores. 2 will boot and will be unpleasant during image pulls and Prometheus compaction |
| **RAM** | **12 GB.** Tockmox projects at ~5.5 GB; k3s, containerd and Argo CD want ~2 GB; the rest is headroom you will use |
| **Disk** | **100 GB SSD.** Roughly 6 GB of container images, ~15 GB of volumes, the rest for growth and the OS |
| **Storage class** | Whatever your distribution provides. `local-path` on k3s |

**What this tier does not do.** A rescheduled pod finds an empty volume. There
is no log history to debug yesterday with. Losing the disk loses everything
except what your database backups already sent elsewhere.

It is a genuinely useful tier: it runs the AI plane, the metrics stack, the
policy layer and the backup path. It is the right answer for evaluating
Tockmox, and for a homelab that treats the box as replaceable.

## Reference

The defaults, `profiles/reference.yaml`. This is what the numbers in this
project are measured against.

| | |
|---|---|
| **CPU** | 8 cores. Observed: 1.07 cores at idle |
| **RAM** | **24 GB.** Observed: Tockmox itself ~7.8 GB across ~60 containers; the reference node sits at 16 GB of 23.5 GB used, 67%, with Argo CD, Garage and other non-Tockmox workloads alongside |
| **Disk** | **250 GB SSD.** ~6.4 GB of images observed on the node; 30 days of Prometheus and Loki is the term that grows |
| **Storage class** | Longhorn, named on every claim Tockmox creates. Not marked default: `local-path` stays the cluster default on k3s, and [install § then un-default k3s's StorageClass](install.md#then-un-default-k3ss-storageclass) says when that changes |

**The single largest consumers, observed:** Prometheus 1.5 GB, LiteLLM 1.1 GB,
Open WebUI 0.7 GB, Authentik 1.0 GB across three pods, Longhorn 0.7 GB across
roughly fifteen containers.

**Open WebUI's image alone is 1.8 GB.** It is the largest single pull and it
surprises people planning disk against pod memory.

**NVMe, not spinning disk.** Prometheus and etcd are both latency-sensitive and
both will make a slow disk everyone's problem.

## Resilient

The same software as Reference. What changes is where the backups go and
whether you have ever restored one.

| | |
|---|---|
| **Nodes** | Still 1. This tier is not about redundancy |
| **RAM** | **32 GB.** Headroom for a restore running beside the thing it is restoring |
| **Disk** | **500 GB SSD**, plus a backup target **not on this machine** |
| **Backup target** | A NAS, another box, or object storage that survives the cluster |

**This is the tier most homelabs should aim at, and the difference from
Reference is not hardware.** It is:

1. Database backups configured to an object store, with `retentionPolicy` set.
2. That object store **not on the same machine**. Garage in-cluster is fine for
   demonstrating the mechanism and is a copy, not a backup.
3. A restore you have actually run. See
   [backup-restore](../operations/backup-restore.md#a-drill-that-actually-destroyed-something),
   which documents one where the source cluster was deleted first.

A box you can rebuild in an afternoon from backups you have tested beats a
second box you have never failed over to.

## HA

**Documented, not gated.** No release gate installs or upgrades three nodes
([deployment shapes](deployment-shapes.md)). Everything below is written from the
procedure and from a production cluster, and a three-node release test would move
this row.

| | |
|---|---|
| **Nodes** | **3.** Not 2 |
| **CPU / RAM** | 8 cores, 32 GB each |
| **Disk** | 500 GB SSD each |
| **Longhorn** | `defaultClassReplicaCount: 3`, and turn `replicaSoftAntiAffinity` **off** |
| **CNPG** | `instances: 3` per database |
| **Networking** | MetalLB across all three. An API-server endpoint that outlives one node ... **you supply this, Tockmox does not install it**, see [the API endpoint](../administration/api-endpoint.md) |

**Three, because quorum.** k3s's embedded etcd needs a majority to elect a
leader. Two nodes tolerate zero failures for the control plane: lose one and
the survivor has no majority. Two nodes are strictly worse than one, because
you have doubled the hardware that can fail without buying any tolerance.

**Turn off the single-node accommodation.** The platform ships
`replicaSoftAntiAffinity: true`, which exists so a one-node cluster does not
leave every Longhorn volume Degraded forever. On three nodes it lets all three
replicas land on one host, which quietly removes the property you bought the
nodes for. Set it false.

**Quorum protects the cluster, not your route to it.** Three etcd members
survive losing one node; a kubeconfig naming that node does not. Unless the API
has an endpoint that outlives a single machine, this tier still has one box
whose loss takes `kubectl`, your GitOps CLI and CI with it, while the workloads
carry on unharmed. **That endpoint is yours to supply** ...
[the API endpoint](../administration/api-endpoint.md).

**What HA still does not give you.** Node redundancy, not site redundancy. A
power event, a bad upgrade applied to all three, or a mistaken `kubectl delete`
takes the cluster regardless. **HA and backups are different controls for
different failures, and HA is the one people mistake for both.** Everything in
the Resilient tier still applies.

## Sizing the AI plane separately

The model gateway and console are ~1.9 GB and modest CPU. **The models are
not.** Tockmox does not ship models and does not size for them: the AI plane
expects an OpenAI-compatible endpoint you point it at, whether that is a
workstation, an Apple-silicon box, or a GPU server.

If you enable in-cluster Ollama, size for the model you intend to load, add it
on top of every figure on this page, and put it on a node with the accelerator.

## How these numbers were produced

- **Observed**: `kubectl top` across all namespaces and the node, on the
  reference deployment, 2026-08-15. A single-node lab under no load.
- **Projected**: the observed reference figure minus the observed usage of
  components a profile removes. Arithmetic on real numbers, not a measurement
  of that configuration.
- **Not a production capacity model.** Prometheus grows with your series count,
  Loki with your log volume, and neither was under realistic load here. Watch
  your own deployment and resize against that.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: Reference
title: "Load balancing and the address pool"
description: "Why exactly one LoadBalancer controller may run, what happens when k3s ServiceLB and MetalLB both do, and how to choose the address range MetalLB hands out."
tags: [metallb, servicelb, loadbalancer, networking, k3s, addresspool]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Load balancing and the address pool

Tockmox's platform layer installs **MetalLB** and gives Traefik a
`type: LoadBalancer` Service. That address is the one every console hostname
resolves to, so the two decisions on this page ... which controller owns
`LoadBalancer` Services, and which addresses it may hand out ... decide whether
anything on the cluster is reachable at all.

The procedures are in
[prepare a fresh cluster](../deployment/fresh-install.md) and
[prepare a cluster you already have](../deployment/existing-cluster.md). This
page is the reasoning behind them. Only one deployment shape is gated; the
others, including a cluster you already run, are **documented, not gated** per
[deployment shapes](../deployment/deployment-shapes.md).

## Exactly one controller may own LoadBalancer Services

A `LoadBalancer` Service is claimed by whichever controller sees it first.
Kubernetes has no arbitration for this and reports no conflict. Two controllers
is not a degraded configuration, it is a race, and the loser is silent.

**k3s ships ServiceLB (klipper) enabled by default.** Installing Tockmox on
stock k3s therefore lands two controllers on the same job. In practice
ServiceLB claims Traefik's Service first and MetalLB never assigns an address:

```console
$ kubectl -n tockmox-platform get svc tockmox-platform-traefik
NAME                       TYPE           EXTERNAL-IP   PORT(S)
tockmox-platform-traefik   LoadBalancer   <pending>     80:32669/TCP,443:30088/TCP

$ kubectl -n kube-system get pods | grep svclb
svclb-tockmox-platform-traefik-1039f2ba-qgh6p   2/2   Running
```

`<pending>` is the tell, and an `svclb-` pod in `kube-system` is the cause.

### The failure names the wrong component

Observed on a clean install 2026-08-18. Nothing serves the LoadBalancer
address, so every console hostname resolves to an IP with nothing behind it.
The first thing to actually fail is a component that fetches OIDC discovery
**server-side**: Argo Workflows crash-looped with

```
Get "https://auth.int.example.com/.../openid-configuration":
dial tcp 192.0.2.10:443: connect: no route to host
```

which names Authentik, the URL and the address, and not the reason. Nothing in
that message points at ServiceLB. This is the shape worth internalising: a
LoadBalancer that was never assigned surfaces as whatever tries to talk to it
first, which is rarely the thing that is broken.

## Choosing which controller to keep

Both are legitimate. Pick one and turn the other off.

| Keep | Turn off | Choose this when |
|---|---|---|
| MetalLB (the Tockmox default) | ServiceLB, with `--disable servicelb` on k3s | You want a real address pool, addresses that survive node changes, and the behaviour the rest of these docs describe |
| ServiceLB | MetalLB, with `apps.metallb.enabled: false` in your site values | You are on k3s, you are happy with node-IP-based publishing, and you do not want a second controller |

The rest of the documentation assumes MetalLB.

### Disabling ServiceLB at install time is durable

Set it when k3s is installed, either in `/etc/rancher/k3s/config.yaml` or on the
install command. The complete command, and the config-file form for a cluster
that already exists, are in
[prepare a fresh cluster § install k3s](../deployment/fresh-install.md#4-install-k3s)
for a new cluster, or
[prepare a cluster you already have § check 2](../deployment/existing-cluster.md#check-2-exactly-one-loadbalancer-controller)
for one that already runs.

### Disabling it on a running cluster

Unlike the [StorageClass un-default](storage.md#if-you-do-want-longhorn-as-your-cluster-default),
this one **is** durable: it is a k3s server flag rather than an annotation on an
object k3s re-asserts, so it survives a restart.

## Layer 2 has to permit it

MetalLB in layer-2 mode answers ARP for an address the node does not own. Any
network that filters on that ... most hypervisor virtual switches, some managed
switches ... drops the answer, and the symptom is an `EXTERNAL-IP` that is
assigned and does not respond. That is a different failure from the one above
and it looks similar.

The per-hypervisor settings are in
[virtual machines § Layer 2 must let MetalLB answer for an IP it does not own](../deployment/virtual-machines.md#1-layer-2-must-let-metallb-answer-for-an-ip-it-does-not-own).

## The address pool needs a decision before you start

`addressPool.range` is one of the values the platform layer refuses to render
without. It has two hard requirements:

- **Inside `global.lanCIDR`.** Addresses outside the LAN the nodes sit on are
  not reachable by anything.
- **Outside your DHCP scope.** A range your router will never hand to something
  else. Reserving a block at the top of the subnet is the usual approach.

Getting the second one wrong produces address conflicts that present as
intermittent network faults, days later, on machines that have nothing to do
with the cluster. It is worth confirming against the router's own configuration
rather than against memory.

Traefik takes the first address in the pool, and that is the address every
`*.internalDomain` name should resolve to. The range accepts a single entry, or
a list when an address already in service has to be carried across.

**On a multi-node cluster the pool carries a third requirement: every node has
to sit on the same layer-2 segment as the range.** In L2 mode MetalLB elects one
speaker per address, and the elected speaker can be any node in the cluster. A
pool that only some of the nodes can answer for works until the election moves,
and then stops ... which reads as an intermittent fault rather than as a
configuration error, because nothing changed at the moment it broke. This is the
constraint that decides how nodes are attached to networks on a hypervisor; the
per-platform settings are in
[virtual machines](../deployment/virtual-machines.md).

> **Unverified.** The speaker-election behaviour is MetalLB's documented layer-2
> model, read from upstream documentation rather than measured on a Tockmox
> cluster with a node removed. The requirement is stated as a belief until a
> failed election has been observed and written down.

## Related

- [Prerequisites](../deployment/prerequisites.md) ... the checks to run before installing
- [External integrations](external-integrations.md) ... DNS, firewall and the equipment around the cluster
- [Troubleshooting](../operations/troubleshooting.md) ... symptoms and their causes

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "The Kubernetes API endpoint"
description: "Give the API server a name that outlives any one node, why a multi-node cluster needs one to be worth its extra hardware, and the SAN trap that breaks it on exactly the day it matters."
tags: [api-server, kubeconfig, high-availability, kube-vip, tls-san, k3s, networking]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [operator]
---

# The Kubernetes API endpoint

**Tockmox does not install anything on this page.** The API endpoint is
Kubernetes' own front door, not a Tockmox component, and it is settled before
Tockmox exists on the cluster. This page is here because a multi-node cluster
that never answers the question keeps a single point of failure it paid three
machines to remove.

**This page is about the HA tier, which is documented, not gated.** No release
gate installs three nodes ([deployment shapes](../deployment/deployment-shapes.md)).

**Single-node clusters can stop reading.** There is nothing to fail over to,
the node's own name is the honest answer, and
[sizing](../deployment/sizing.md) is clear that one box is not high
availability.

## The problem, stated once

Every k3s server serves the API on its own address, with its own certificate.
Nothing in Kubernetes hands you a single name that survives losing a node ...
you supply one, or you do not have one.

**Without one, a three-server cluster still has a single point of failure, and
it is the one you look through.** Lose the node your kubeconfig names and etcd
holds quorum perfectly, the workloads keep running, and you cannot see any of
it. `kubectl` fails, and so does everything riding a kubeconfig: your GitOps
CLI, CI, any agent or MCP with cluster access.

**That failure is easy to misread as a cluster fault**, because the symptom is
total and the cluster is fine. If you are working through
[prepare a fresh cluster § 4f](../deployment/fresh-install.md#4f-prove-the-cluster-survives-a-node-loss--multi-node-only)
and the API stops answering when you pull the plug, check which address your
kubeconfig holds **before** concluding anything about etcd.

## Before you begin

| What you need | Why |
|---|---|
| A decision from the table below | It changes what goes in `--tls-san`, and that is the part with a cost attached |
| If you choose a VIP: one free IP, outside your DHCP scope **and** outside MetalLB's range | Two things handing out the same address is an outage that presents as intermittent, days later |
| A DNS name you control, resolving from inside the cluster | The same requirement [identity](identity.md#dns-one-requirement-worth-knowing) states for the console hostnames |

## Choose the endpoint

**YOU SUPPLY:** which of these three. All are legitimate; only the first is
free.

| Answer | What it costs | Choose it when |
|---|---|---|
| **A node's name** | Nothing now. A manual re-point during an outage, at the moment you least want to be editing a kubeconfig | Evaluating, or a single node, or you accept that losing one machine costs you visibility until you edit a file |
| **A floating VIP** (recommended for multi-node) | One IP, a DNS record, and a small controller you run | You built three servers to survive losing one. This is the only answer that makes that true for the operator as well as the workloads |
| **A load balancer you already own** | Nothing new, if it exists | You already run one in front of other services. Point it at all three servers on 6443, health-check the port |

**Use a DNS name whatever you choose.** A name in front of an address costs
nothing today and is the difference between re-pointing one DNS record and
re-issuing certificates later. Hand out kubeconfigs that name it and nothing
else ... a node IP that escapes into a kubeconfig, a CI secret or a runbook
outlives every intention to clean it up.

## Put the name in the certificate, on every server

**Required, and this is the step that is expensive to skip.** The API server's
certificate must carry every name and address a client might use, or TLS
verification fails against a name it does not list.

Put it in `/etc/rancher/k3s/config.yaml`, **not** in the installer's
`INSTALL_K3S_EXEC` flags:

```yaml
# EVERY SERVER NODE, before k3s first starts
tls-san:
  - tockmox.your.domain
  - <VIP or load-balancer address, if you have one>
```

**Why the config file rather than the flag.** k3s's installer **preserves**
`/etc/rancher/k3s/config.yaml` and **rewrites** the systemd environment file
that installer flags land in. A later re-run, an upgrade, or a repair that
re-invokes the installer without the original flags therefore silently drops
them. A cluster where that happened to the *join* configuration lost a node for
twenty minutes and reported it as `Unknown`, which reads as a node fault.

**Every server needs it, not just the first, and this is the trap.** Whichever
node holds the VIP is serving the API, and that can be any of them. A server
missing the SANs behaves perfectly ... until the day it takes the address, at
which point clients start failing TLS verification and it presents as a cluster
problem rather than a one-line gap in one file.

**Success condition**, on every server:

```bash
sudo grep -A3 '^tls-san:' /etc/rancher/k3s/config.yaml
openssl s_client -connect <this node>:6443 </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
```

The file lists your names, **and** the served certificate does too. The second
command is the one that matters: the file is intent, the certificate is fact,
and they diverge whenever k3s has not restarted since the edit.

### Adding this later is a restart, not a rebuild

**Retrofitting onto a running cluster is supported and cheap.** Edit
`config.yaml` on each server and restart k3s ... k3s regenerates the serving
certificate on start from the SANs it finds. Roll the servers one at a time
and confirm each is back before the next.

This is worth knowing precisely because it changes the decision: **not deciding
now does not paint you into a rebuild.** It costs a rolling restart later, and
the certificate follows.

The one thing that is genuinely not retrofittable is `--cluster-init`, and that
is a separate decision made at
[prepare a fresh cluster § 3](../deployment/fresh-install.md#3-choose-your-cluster-shape).

## If you chose a VIP

**Optional. Skip this if you chose a node name or an existing load balancer.**

The reference implementation is **kube-vip in control-plane mode**, run as a
DaemonSet on the server nodes. One instance holds the address, elected by a
lease; when that node goes, another takes the address and re-announces it.

**Tockmox does not ship it and does not manage it.** Deploy it the way you
deploy your own platform components, before any kubeconfig leaves the cluster.

Three settings decide whether it works:

| Setting | Value | Why |
|---|---|---|
| `cp_enable` | `true` | The control-plane VIP. This is the job you want |
| `svc_enable` | **`false`** | See the collision below. This is not optional |
| interface | leave unset unless every node names its NIC identically | Auto-detecting the default-route interface is what makes one manifest work across mixed hardware |

**`svc_enable: false`, and this one bites hard.** kube-vip does two unrelated
jobs, and the second one is handing out addresses for `type: LoadBalancer`
Services. **Tockmox's platform layer installs MetalLB to do exactly that.**
Turning both on is the same two-controllers-one-job race that
[load balancing](load-balancing.md) describes for k3s's ServiceLB, with the
same silent loser and the same confusing symptom: some unrelated component
cannot reach an address.

One owner per job. MetalLB owns Services; kube-vip owns the control plane and
nothing else.

**Success condition:**

```bash
kubectl get nodes
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-vip -o wide
```

`kubectl` answers **through the VIP name**, and an instance is Running on every
server node. A VIP that answers while one server has no instance is a VIP with
fewer places to fail over to than you think.

### Prove it, while nothing is running on the cluster

**Required if you built a VIP.** An untested failover is a belief.

In one terminal:

```bash
while true; do
  kubectl get nodes --request-timeout=2s >/dev/null 2>&1 \
    && echo "$(date +%T) ok" || echo "$(date +%T) FAIL"
  sleep 1
done
```

In another, find the node holding the address and take it out:

```bash
kubectl -n kube-system get lease plndr-cp-lock \
  -o jsonpath='{.spec.holderIdentity}'
```

Power that node off, hard.

**Success condition:** a short run of `FAIL` lines at most, then steady `ok`,
without you touching the kubeconfig. Sustained `FAIL` means the address did not
move ... check that an instance is Running on the surviving servers, and that
each of them carries the SANs.

**This is the same event as
[fresh cluster § 4f](../deployment/fresh-install.md#4f-prove-the-cluster-survives-a-node-loss--multi-node-only)**,
seen from the operator's side rather than the cluster's. Run them as one test:
§4f asserts the cluster survived, this asserts you can still see it.

## Break glass

Keep one per-node kubeconfig aside, pointed at a server's own address rather
than the shared name. Copy `/etc/rancher/k3s/k3s.yaml` from any server, replace
`127.0.0.1` with that node's address, and **save it under a different filename**
so it never overwrites your everyday one.

It is what you use when the shared name is the thing that is broken, which is
the one failure a VIP adds that a node name does not have.

## What is not certified here

The mechanism on this page is run in production by the maintainer, including
the failover test as written. **It has not been executed as part of a Tockmox
release gate**, and Tockmox installs none of it ... see the
[testing standard](../testing-standard.md) for what that distinction means and
which paths are covered.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

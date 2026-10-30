---
okf_version: "0.2"
type: HowTo
title: "Prepare a cluster you already have"
description: "Six checks to run against an existing Kubernetes cluster before installing Tockmox, each with the condition that triggers it and how to tell it passed."
tags: [deployment, kubernetes, existing-cluster, preflight, checks]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Prepare a cluster you already have

**This page is checks, not steps.** It cannot assume what is already running on
your cluster, so each section states a condition first and a fix second. Run all
six; most will pass in seconds.

**Building a cluster from scratch?** [Prepare a fresh cluster](fresh-install.md)
is shorter, makes the choices for you, and has no conditions in it. Prefer that
path if you have the option.

Both paths finish in the same place: [installation](install.md).

**Shape: documented, not gated.** A cluster you already run is not the shape a
release gate installs onto. The gate builds its own single-node MicroOS cluster,
so these checks stand in for knowledge of your cluster that the project does not
have. [Deployment shapes](deployment-shapes.md) has the row.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| Cluster-admin on the cluster | Every check below reads cluster-scoped objects; three of them write | `kubectl auth can-i '*' '*' --all-namespaces` |
| Root or sudo on every node | Storage packages, and on k3s the server flags | `sudo -n true` on each |
| A workstation with `kubectl`, `helm` and `git` | The installer writes a *site repository*; without git, ArgoCD has nothing to read | `kubectl version --client && helm version && git --version` |
| A clone of the Tockmox source tree | [Installation](install.md) runs `./install/tockmox-install.sh` from its root | `ls install/tockmox-install.sh` |
| A LAN address range you can reserve | MetalLB hands these out, and it must sit outside your DHCP scope | Your router's DHCP scope |
| An internal DNS zone you control | Console hostnames live under it and must resolve from **inside** the cluster | `dig +short SOA <your-zone> @<your LAN resolver>` |

**Estimate, not a measurement: 30 to 60 minutes**, more if check 2 or 4 fails
and you have to touch every node.

## What Tockmox needs from your cluster

| Requirement | Why it matters |
|---|---|
| Kubernetes 1.30 or newer | 1.33+ comfortable |
| 4 cores / 12 GB minimum per the [sizing tiers](sizing.md) | That is the Minimal tier, and it is headroom for Tockmox on top of whatever your cluster already runs |
| **Exactly one** LoadBalancer controller | Two is a race with a silent loser (check 2) |
| **Exactly one** default StorageClass, resolved deliberately | Two resolves by timestamp accident (check 3) |
| iSCSI initiator and NFS client on every node | Longhorn does not start without them (check 4) |
| ArgoCD 2.6+, installed out of band | It cannot bootstrap or self-manage (check 5) |
| sealed-secrets with your own key | Must exist before the first SealedSecret syncs (check 6) |

## Check 1: version and node readiness

```bash
kubectl version
kubectl get nodes
```

**Passes when** the server is 1.30 or newer and every node reports `Ready`.

## Check 2: exactly one LoadBalancer controller

Tockmox's platform layer installs **MetalLB** and gives Traefik a
`type: LoadBalancer` Service. If something else already claims those Services,
MetalLB never assigns an address and the first visible failure is an unrelated
component that cannot reach a host ... commonly an error naming Authentik, which
has nothing to do with the cause.

Two reads, and together they answer one question: is anything already answering
for LoadBalancer Services?

```bash
kubectl get svc --all-namespaces --field-selector spec.type=LoadBalancer
kubectl get pods -n kube-system | grep -i -E 'svclb|metallb|kube-vip|purelb'
```

**Passes when** either no LoadBalancer controller is running, or exactly one is
and you intend to keep it.

**If your cluster is k3s**, ServiceLB (klipper) is on by default and this check
fails. Write the flag to the config file rather than the unit, so a k3s upgrade
cannot drop it. The file is `/etc/rancher/k3s/config.yaml`, and it has to carry
this on **every server node**, not only the first:

```yaml
disable:
  - servicelb
```

Then restart k3s, again on every server node:

```bash
sudo systemctl restart k3s
```

**If you already run MetalLB, kube-vip or PureLB and want to keep it**, turn
Tockmox's MetalLB off instead, in your site values:

```yaml
apps:
  metallb:
    enabled: false
```

The decision table, the full failure anatomy and the layer-2 requirement are in
[load balancing](../administration/load-balancing.md#exactly-one-controller-may-own-loadbalancer-services).

**Confirmed later**, once the platform layer has synced: Traefik's Service shows
a real `EXTERNAL-IP` rather than `<pending>`.

## Check 3: the default StorageClass

```bash
kubectl get storageclass
```

**Passes when** exactly one class is marked `(default)`. Whatever it is, it stays
that way ... **Tockmox does not touch your cluster default.** It names the class
it wants on every claim it creates, and `global.storageClass` is what you set to
say which one. Longhorn's class is created but not marked default.

So on this page the check is about **your** cluster being in a sane state before
you start, not about a collision Tockmox is going to cause. Zero defaults is
worth fixing for your own sake; two is worth fixing because Kubernetes resolves
it by creation timestamp, which is an accident rather than a decision.

**The rest of this check applies only if you set
`longhorn.persistence.defaultClass: true`**, choosing to hand your cluster-wide
default to Longhorn. On k3s that collides with the `local-path` default it ships,
and it needs one extra step because the un-default does not survive a restart on
its own. Run this on **every** k3s server node, not only the first ... a server
that never got the file re-asserts the addon on its next start:

```bash
sudo touch /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip
```

k3s stops reconciling that addon and leaves the existing class alone, which is
what you want ... the storage policy and `profiles/minimal.yaml` both need
`local-path` to keep existing. **Un-default it, never delete it.** You apply the
patch itself during
[install § Phase 3](install.md#then-un-default-k3ss-storageclass), when you
actually have two.

**If you want to keep your own class as default**, un-default Longhorn instead:

```yaml
longhorn:
  persistence:
    defaultClass: false
global:
  storageClass: <your class>
```

The measurement behind all of this, and what the `.skip` file costs you, are in
[storage](../administration/storage.md#if-you-do-want-longhorn-as-your-cluster-default).

## Check 4: storage packages on every node

Longhorn needs an iSCSI initiator and an NFS client present before it starts.
Without `iscsiadm`, `longhorn-manager` fatal-crashes and volumes sit in
`attaching` behind a CSI error that names the volume, not the missing daemon.

Run this on **every** node, servers and agents alike:

```bash
systemctl is-active iscsid && command -v iscsiadm
```

**Passes when** every node prints `active` and a path.

**If it fails on a conventional distribution**, run the one line that matches
your package manager. They are three alternatives rather than a sequence, and
the distribution family each belongs to is named above it rather than beside it.

On **Debian and Ubuntu**:

```bash
sudo apt-get install -y open-iscsi nfs-common cryptsetup
```

On **RHEL and Rocky**:

```bash
sudo dnf install -y iscsi-initiator-utils nfs-utils cryptsetup
```

On **SLES and openSUSE Leap**:

```bash
sudo zypper install -y open-iscsi nfs-client cryptsetup
```

Then, whichever you ran: `sudo systemctl enable --now iscsid`.

**If it fails on an immutable OS**, this is not a package install and the
commands above will not work:

| OS | Mechanism | Status |
|---|---|---|
| openSUSE MicroOS / SLE Micro | `sudo transactional-update --non-interactive pkg install open-iscsi nfs-client cryptsetup`, then reboot | **Verified.** The platform Tockmox is developed and run on, with k3s v1.36.x through 2026-09-01 |
| Talos | `open-iscsi` ships as a system extension; add it to the machine image rather than to a running node | Not yet exercised. See [testing standard](../testing-standard.md) |
| Flatcar | The iSCSI daemon is in the base image; enable it with `sudo systemctl enable --now iscsid` | Not yet exercised |

On MicroOS, note that `transactional-update pkg install` is **atomic and fails
quietly** ... one unresolvable package name rolls the whole batch back with no
obvious error. The reboot is the install; nothing changes on the running system
until you boot into the new snapshot. k3s additionally needs shared mount
propagation, or the kubelet cannot see the CSI socket. Test it with
`findmnt -o TARGET,PROPAGATION /` on each node; where `/` is not `shared`, the
`MountFlags=shared` drop-in on `k3s.service` fixes it. The full sequence is on
[prepare a fresh cluster](fresh-install.md#4-install-k3s).

## Check 5: ArgoCD

```bash
kubectl -n argocd get deployment argocd-server
kubectl -n argocd get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**Passes when** ArgoCD 2.6 or newer is running, installed out of band, and is
**not managing itself.**

- **If ArgoCD is absent**, install it. The command and the version-pinning step
  are on [prepare a fresh cluster § install ArgoCD](fresh-install.md#6-install-argocd).
- **If it is older than 2.6**, upgrade it. The generated Applications are
  multi-source, and older ArgoCD cannot parse that ... the failure reads as a
  malformed Application, not a version problem.
- **If it manages itself** ... points at a repository containing its own
  manifests ... unwind that before going further. It is a known failure mode:
  the controller deletes itself partway through an upgrade with nothing left
  running to finish. See
  [ArgoCD § why it is a prerequisite](../administration/argocd.md#why-it-is-a-prerequisite).
- **If it is in a namespace other than `argocd`**, say so in your site values:
  `argocd.namespace: <yours>`.

**If your site repository will be private**, ArgoCD needs a read-only credential
**before** the first sync. Without one, every Application goes to `Unknown` with
a `ComparisonError` that does not distinguish a missing credential from a wrong
URL from a bad revision, on all nine layers at once. Mint the token now; the
Secret is applied at
[install § Phase 2](install.md#phase-2--publish-it). Shape and traps:
[ArgoCD § a missing repository credential](../administration/argocd.md#a-missing-repository-credential-names-nothing-useful).

## Check 6: sealed-secrets

```bash
kubectl -n kube-system get deployment sealed-secrets \
  -o jsonpath='{.status.readyReplicas}'
```

**Passes when** it prints `1` **and** you hold an off-cluster backup of the
controller's private key.

- **If it is absent**, install it from the OCI reference with a pinned version.
  The command is on
  [prepare a fresh cluster § install sealed-secrets](fresh-install.md#7-install-sealed-secrets-with-your-own-key).
- **If it is present but you have never backed the key up**, do that before
  anything else. Losing it makes every sealed secret you have committed
  permanently unreadable, not merely inconvenient. The export command and the
  three properties worth engineering are in
  [secrets](../administration/secrets.md#back-up-the-controller-key-now).
- **If it came from `charts.bitnami.com/bitnami`**, check the controller
  version. Measured 2026-08-15 that source was several releases back (0.31.0
  against 0.38.4 on OCI). See
  [secrets § where the controller chart comes from](../administration/secrets.md#where-the-controller-chart-comes-from-and-why-it-matters).

## The four values

Identical on both paths, so there is one copy rather than two that drift:
[prepare a fresh cluster § decide the four values](fresh-install.md#8-decide-the-four-values).
The exhaustive reference for every key is
[configuration](../administration/configuration.md).

## What is not certified here

**Shape.** An existing cluster is **documented, not gated** ([deployment
shapes](deployment-shapes.md)): no release gate installs Tockmox onto a cluster it
did not build.

These checks are written from the failures this project has hit. **They have not
been executed as written against a cluster this project does not control**,
which is the case this page exists for. The
[testing standard](../testing-standard.md) records which documented paths are
covered by an executing gate and which are not yet.

## Next

Six checks passed and four values written down. Continue at
[installation](install.md).

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

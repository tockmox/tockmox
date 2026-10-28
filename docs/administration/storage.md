---
okf_version: "0.2"
type: Reference
title: "Storage"
description: "Which volumes are replicated, which are node-local and why, the Longhorn replica count rule, and the two-default-StorageClass problem on k3s."
tags: [storage, longhorn, local-path, storageclass, k3s, replication]
status: stable
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [operator]
---

# Storage

Tockmox ships replicated storage and uses it for most things, and deliberately
does not use it for a few. This page is the reasoning, because the choice is not
obvious and the wrong version of it is expensive in a way nothing reports.

## The principle: replicate at exactly one layer

Ask one question of every volume: **does the application already keep another
copy of this data, or can the data be rebuilt?**

If the answer is no, the volume is the only copy and it has to be replicated.
If the answer is yes, replicating the volume underneath buys nothing. It costs
two to three times the disk, and it puts a synchronous network write in front of
every commit on a path that was already hot.

Both answers are correct storage designs. Applying either one everywhere is not.

## What that comes to

| Workload | Class | Why |
|---|---|---|
| Open WebUI | replicated | One copy, not re-derivable, small |
| Grafana | replicated | Dashboards and sqlite state, one copy |
| ntfy | replicated | Message store, one copy |
| Alertmanager | replicated | Silences and the notification log. Small, and losing them re-fires everything you had already resolved |
| Authentik's database, 1 instance | replicated | One instance, so nothing else holds a copy. A CNPG cluster from 0.9.0 (`identity.database`), and the bundled StatefulSet on an install that keeps it |
| Authentik's database, 3 instances | local | Postgres is already streaming to its own replicas (CNPG only; the class follows `identity.database.instances` the same way as the model gateway's) |
| The model gateway's database, 1 instance | replicated | Same reason |
| The model gateway's database, 3 instances | local | Postgres is already streaming to its own replicas |
| Prometheus TSDB | local | High-churn, append-only, re-derivable, and you restore it from a backup rather than from a replica |
| Loki chunks | local | Loki's durability story is an object store, not a replicated block device |
| Garage, replication_factor 1 | replicated | One node holds the only copy, so the volume is it |
| Garage, replication_factor 3 | local | Garage replicates across nodes itself |

Garage ships as part of the `dataProtection` capability, and its data volume
follows the same derivation the model gateway's database follows: the class
tracks whether anything else is keeping a copy. Its metadata volume is always
replicated, because it is small, hot, and the only copy at any factor.

## The two values keys

```yaml
global:
  storageClass: "longhorn"        # the volume is the only copy
  localStorageClass: "local-path" # the application has its own, or it rebuilds
```

Empty means "use the cluster default" for either one, which quietly undoes the
policy rather than announcing it. Name both.

`local-path` is k3s's own provisioner. [Prerequisites](../deployment/prerequisites.md)
tells you to **un-default** it rather than delete it, and this is the second
reason for that instruction: half the policy needs the class to still exist.

**Node-local means node-local.** A rescheduled pod finds an empty volume and
Prometheus starts a fresh TSDB. That is the trade, stated plainly: at this size,
metric history is worth less than the write path it would cost to replicate.
Do not point `localStorageClass` at anything whose loss you would mind.

## Tockmox does not set your cluster default

**`storageclass.kubernetes.io/is-default-class` is a cluster-wide singleton, and
it belongs to whoever owns the cluster.** Tockmox names the class it wants on
every claim it creates and leaves the default alone. Longhorn's StorageClass is
created; it is simply not marked default. On stock k3s that means `local-path`
stays your default and you end up with **one**, which is the state everything
else on this page assumes.

**This changed on 2026-09-04, and the reason is worth keeping.** The platform
layer used to mark Longhorn's class default, because shipping replicated storage
that nothing uses is worse than not shipping it (that was the state through
0.1.0-dev, and it was found again on the reference lab on 2026-08-15 with
Longhorn running healthy and completely unused). At the time there was no key
to name a class with, so claiming the default was the only mechanism that
reached every claim.

There is a key now. `global.storageClass` is threaded into every claim the
product creates ... eight of them, verified by rendering ... and the platform
preflight **refuses to install** when Longhorn is on and nothing has named a
class, so the silent fall-through that motivated the old behaviour cannot come
back. Claiming a cluster-wide singleton was solving a problem that a named class
and a fail-closed guard solve better, and it was doing so at the cost of
redirecting every class-less claim in the cluster ... including workloads that
have nothing to do with Tockmox ... onto replicated storage nobody asked for.

### If you DO want Longhorn as your cluster default

A legitimate choice on a cluster you built for this, and not one on a cluster you
were handed. Set:

```yaml
# site/values/platform.yaml, in your site repository
longhorn:
  persistence:
    defaultClass: true
```

**That brings back the two-defaults problem, and the rest of this section is
about living with it.** k3s already ships `local-path` as default, so you now
have two. Kubernetes does not reject that: it picks the **most recently
created** class, which is Longhorn's, which is the one you wanted ... by
accident of timestamp rather than by anything you configured. Recreate the
`local-path` object later and the accident reverses.

The durable fix is a `.skip` file during cluster preparation
([fresh cluster](../deployment/fresh-install.md#5-stop-k3s-re-asserting-its-storageclass-default),
[existing cluster](../deployment/existing-cluster.md#check-3-the-default-storageclass);
the shape rows are in [deployment shapes](../deployment/deployment-shapes.md)),
plus the patch at
[install § Phase 3](../deployment/install.md#then-un-default-k3ss-storageclass).
The rest of this section is what that patch does and does not buy you. **On a
stock install none of it applies**, because there is only one default.

### The patch does not survive a k3s restart

**Measured 2026-09-01 on k3s `v1.36.4+k3s1`.** After the documented patch,
`local-path` reports `default=false`. After `systemctl restart k3s`, it reports
`default=true` again.

k3s re-applies its own packaged addon manifest,
`/var/lib/rancher/k3s/server/manifests/local-storage.yaml`, which ships
`is-default-class: "true"`. The annotation is applied state fighting desired
state, and desired state wins on every restart, k3s upgrade, kured cycle or node
rebuild.

> This page previously carried a dated verification saying the addon controller
> does **not** revert it. That claim was checked on 2026-08-15, was true of the
> cluster it was checked on, and is not true here. It is corrected rather than
> quietly removed, because a reader who acted on it believes they are protected
> and is not.

**How bad this is, measured rather than assumed.** The severity turned on
whether the addon controller replaces the object or patches it in place. It
patches in place: on the run above, `local-path` kept its original
`creationTimestamp` (four seconds after the *first* k3s start, with the restarted
process four minutes later) and its `resourceVersion` advanced rather than
resetting. So `local-path` stays the *older* class, Longhorn's stays newer, and
class-less PVCs still bind to Longhorn.

That makes this a correctness problem rather than a data-loss one. What you
actually have after any restart is two defaults resolving your way by timestamp
accident. Anything that reorders those timestamps ... a chart reinstall
sequence, an upgrade that recreates the `local-path` object ... removes the
accidental protection with no warning and nothing to alert on.

### Making it durable: skip the addon, then patch

**This is the recommended procedure.** k3s stops re-asserting a packaged
component's manifest if a `.skip` file sits beside it, and an already-deployed
addon is left exactly as it is ... which is precisely the outcome Tockmox needs.
The `local-path` StorageClass and its provisioner keep existing, because the
storage policy and `profiles/minimal.yaml` both need them, and k3s stops
touching the object so the annotation stays where you put it.

**The order is the opposite of the k3s documentation's own example, and it
matters.** Their example creates the `.skip` file *before* the first start, so
the addon never deploys at all. Do that here and you have no `local-path` class,
which breaks the minimal profile. Let it deploy first, then skip it.

Two steps, and they do not run in the same place:

1. `sudo touch ...local-storage.yaml.skip` runs on *every k3s server node*, and
   only after `local-path` has already deployed.
2. `kubectl patch storageclass local-path` runs once, from anywhere.

```bash
sudo touch /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip

kubectl patch storageclass local-path -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

**Three costs, stated rather than discovered:**

- **The class and its provisioner become unmanaged.** k3s will not upgrade them
  again. For a StorageClass and a small provisioner Deployment that is a low
  price, but it is an orphan the cluster now carries and nothing will tell you
  it has aged.
- **The file must exist on every server node, and k3s does not sync it.** The
  k3s documentation is explicit that keeping AddOn files in step across servers
  is your responsibility. A server node added later needs the file too, or it
  re-asserts the annotation on its next start.
- **A node rebuild loses it**, because it is a file on disk rather than cluster
  state. Put it in whatever builds your nodes.

> **Verified on a Tockmox install, 2026-09-04**, single-node k3s
> `v1.36.4+k3s1`, charts `0.6.0`, all layers `Synced`/`Healthy`. Before the
> procedure: `local-path` and `longhorn` both `is-default-class: "true"`, two
> defaults. After the two steps above: `local-path` `false`, one default
> (`longhorn`). **After `systemctl restart k3s`: still `false`.** After a full
> node reboot: **still `false`**, `local-path` still present, its provisioner
> back up, one default.
>
> The StorageClass `resourceVersion` did not move across either restart, so **no
> write landed on the object** ... contrast the 09-01 measurement above, where
> the annotation flipped back. That is what the reading supports; it does not by
> itself separate "the apply never ran" from "an apply ran and changed nothing".
>
> Worth knowing what the `.skip` file does and does not stop: on the reboot k3s
> **rewrote every packaged manifest to disk**, including `local-storage.yaml`,
> and left the annotation alone. It suppresses the apply, not the write, so
> finding a fresh `local-storage.yaml` on disk is expected and is not a sign the
> file stopped working.
>
> **Still unverified**, and each of these is a case a reader may be in:
> a k3s **upgrade** rather than a restart; any **multi-node** cluster, since the
> run was one server node and "the file must exist on every server node" cannot
> fail there; and the **preparation-time ordering** that
> [fresh cluster](../deployment/fresh-install.md#5-stop-k3s-re-asserting-its-storageclass-default)
> and [existing cluster](../deployment/existing-cluster.md#check-3-the-default-storageclass)
> tell you to use. This run started from two defaults, which is the
> [install § Phase 3](../deployment/install.md#then-un-default-k3ss-storageclass)
> ordering ... `.skip` created after Longhorn's class already existed, not
> before.

### Why the other candidates lose

| Option | Verdict |
|---|---|
| **Re-apply the patch after every restart** | Works, and turns a prerequisite into an operational chore with nothing enforcing it. Fine as a stopgap, not as the documented answer |
| **Drive the annotation from your own GitOps repo** | A reasonable second choice. It does not stop the revert, it heals it: k3s re-asserts on start, ArgoCD puts it back on its next sync, and there is a window in between where you have two defaults again. Harmless in practice, because the timestamp still favours Longhorn, but it is a repair loop rather than a fix |
| **Edit `local-storage.yaml` in place** | Does not work. k3s rewrites packaged-component manifests to disk on every start, deliberately |
| **`--disable local-storage`** | Does not do what you want. Disabled AddOns are *actively uninstalled* and the source file deleted, so you lose the class entirely ... see below |

The `.skip` mechanism, the rewrite-on-start behaviour and the uninstall semantics
of `--disable` are all documented in
[Managing Packaged Components](https://docs.k3s.io/installation/packaged-components)
(k3s, retrieved 2026-09-01).

### Do NOT reach for `disable: local-storage` unless you are sure

It removes the provisioner entirely, which breaks two things:
`profiles/minimal.yaml` names `local-path` as its storage class, and any volume
already on local-path loses the provisioner that manages it. Deleting such a
claim then leaves the directory behind on the node.

Disable it only on a cluster running the reference profile with nothing left on
local-path.

**This project shipped the wrong advice once, and the record belongs here.** An
earlier revision of [virtual machines](../deployment/virtual-machines.md) put
`--disable local-storage` on the k3s install line as though it were a
recommended flag. It was wrong for both reasons above: it strands any volume
already on local-path, and it breaks `profiles/minimal.yaml`, which names
`local-path` as its storage class. Two default StorageClasses is still a real
problem ... k3s picks the newest, so a reinstall changes behaviour without
changing config ... but the fix is to un-default `local-path` rather than to
remove it, and the durable form of that fix is
[making it durable](#making-it-durable-skip-the-addon-then-patch) above.

### Keeping `local-path` as the default is a legitimate choice

It is fine to evaluate with and wrong to depend on, being node-local: a
rescheduled pod finds an empty volume. If you want it, un-default Longhorn
instead of local-path:

```yaml
longhorn:
  persistence:
    defaultClass: false
global:
  storageClass: longhorn     # set it explicitly so the preflight knows you chose
```

### If you run your own CSI

Set `longhorn.persistence.defaultClass: false`, keep exactly one default per
cluster, and name your class in `global.storageClass`. Tockmox does not require
Longhorn and does not require any particular class.

```yaml
longhorn:
  persistence:
    defaultClass: false
global:
  storageClass: <your-replicated-class>   # from `kubectl get storageclass`
  localStorageClass: <your-local-class>   # may be the same class
```

You can also decline the storage components entirely; that is the
`apps.longhorn` switch, and [capabilities](capabilities.md) covers what a
decline removes.

### The preflight that refuses to render, and what it is protecting

**The platform layer refuses to render one combination:** `apps.longhorn`
enabled, Longhorn **not** marked as the cluster default StorageClass, and
`global.storageClass` empty. The render stops with an error that names all three
conditions and offers the three ways out.

It is worth being precise about what that guard does and does not assert. It
does not require Longhorn, and it does not require any particular class. **It
requires that somebody chose.** `global.storageClass: local-path` satisfies it
and is a legitimate answer if you mean it.

The guard exists because the alternative failed silently. Longhorn shipped, ran
healthy, and nothing used it: every database Tockmox created landed on
node-local, single-copy, snapshot-less disk while replicated storage sat idle
beside it, and every signal was green throughout. That was the state the
reference deployment was found in on 2026-08-15, which is the date the error
message itself cites.

**Verified 2026-09-01 against the 0.6.0 tree** by rendering the platform layer
with `longhorn.persistence.defaultClass=false` and no `global.storageClass`, and
observing the render fail rather than succeed. That is a check on the guard, not
on a running cluster.

### Check what you actually ended up with

This is the failure that looks like nothing, so confirm rather than assume:

```console
$ kubectl get storageclass
NAME                 PROVISIONER            ...
local-path           rancher.io/local-path
longhorn (default)   driver.longhorn.io
```

Exactly one `(default)`, and it is the one you meant. Re-run this after any k3s
restart or node rebuild until whichever durable option you picked is in place.

## Longhorn replica count

```yaml
longhorn:
  persistence:
    defaultClassReplicaCount: 1
  defaultSettings:
    defaultReplicaCount: 1
    replicaSoftAntiAffinity: true
```

**One replica on one node, three on three or more. Two is never right.**

Two replicas with `replicaSoftAntiAffinity: true` on a single node is the
combination worth naming, because it looks careful and is not: soft anti-affinity
permits both copies on the same disk, so you pay double the space and double the
write amplification for two copies that fail together.

Replication protects against losing a node or a disk. With one of each there is
nothing for a second replica to survive; what protects a single-node deployment
is the backup path, and that one is drilled. See
[backup and restore](../operations/backup-restore.md).

At three or more nodes, raise the counts to 3 **and turn
`replicaSoftAntiAffinity` off in the same change.** Leaving it on lets all three
replicas land on one host, which silently removes the property the extra nodes
were bought for. Two nodes is not a halfway house: it tolerates zero
control-plane failures, so it is strictly worse than one. The tiers are in
[sizing](../deployment/sizing.md).

## Draining a node takes its replicas with it

Replica count is a claim about how many nodes may be absent at once, and a drain
is a deliberate absence. Draining a node that holds the **only** replica of a
volume does exactly what you asked and leaves the workload with nothing to
attach to, which is why the node-maintenance procedure in
[day-2 § take a node out for maintenance](../operations/day-2.md#take-a-node-out-for-maintenance)
opens with a replica check rather than with `kubectl drain`.

The two shapes this matters in:

- **One replica**, by count or because the others are unhealthy. Draining is a
  planned outage of that volume. Either accept it inside a maintenance window,
  or wait for the replica count to be satisfied elsewhere first.
- **Three replicas with `replicaSoftAntiAffinity: true`.** The count says three
  nodes, the placement does not enforce it, so all three can sit on the host you
  are about to drain. This is the same trap as
  [Longhorn replica count](#longhorn-replica-count), surfacing at drain time
  rather than at install time.

Two ways to look, and they answer different questions. The first is what
Longhorn thinks right now:

```bash
kubectl -n tockmox-platform get volumes.longhorn.io
```

The second is what the alert rules are already watching, which needs no command
from you: `longhorn_volume_robustness`, shipped by the platform layer.

The platform layer ships alerts on `longhorn_volume_robustness` for both
`degraded` and `faulted`, so a cluster with monitoring up has already told you
if a volume is short of replicas. See
[monitoring](../operations/monitoring.md#what-tockmox-itself-alerts-on).

> **Unverified against a live drain.** The replica-count reasoning is Longhorn's
> documented placement model and the alert expressions are in
> `charts/tockmox-platform/templates/platform-alerts.yaml`. Nobody has recorded
> a drain of a single-replica node on a Tockmox cluster and written down what it
> looked like. Treat the failure description as a belief until it is.

## Losing a node, and the asymmetry that is the policy working

A drain is a deliberate absence. A node that goes away without one ... a power
cut, a failed hypervisor host, or the hard power-off you do on purpose to prove
a cluster survives it ... produces an outcome that looks half-broken and is not:

- **Workloads on a replicated volume come back on another node.** Longhorn has
  another replica to attach to.
- **Workloads on the node-local class do not come back, and should not.** There
  is no second copy. A pod that rescheduled elsewhere and found an empty volume
  would be a worse outcome than one that stays `Pending` until its node returns.

That asymmetry is
[the principle](#the-principle-replicate-at-exactly-one-layer) doing its job.
Read both lists before concluding something failed:

```bash
kubectl get pods -A -o wide | grep -v Running
kubectl -n tockmox-platform get volumes.longhorn.io
```

**When the node comes back, `Ready` is not the finish line.** The load-bearing
part is Longhorn rebuilding the replicas that were on it, which takes
substantially longer than the node takes to rejoin. The volumes listing above is
where you watch that, and `longhorn_volume_robustness` is where the shipped
alerts watch it for you.

> **Unverified.** This describes Longhorn's documented attach behaviour and the
> intent of the storage policy. No node-loss event on a Tockmox cluster has been
> recorded with the per-workload outcome written down, so treat the description
> as a belief rather than a measurement. The commands are safe either way: both
> are reads.

## Uninstalling Longhorn, and what it leaves behind

The procedure is [uninstalling Tockmox](../operations/uninstall.md). Three
things about it belong here rather than there, because they are properties of
how Longhorn is deployed rather than steps in a sequence.

**The uninstall interlock is a setting, and its refusal names a namespace this
cluster does not have.** Longhorn will not uninstall until
`deleting-confirmation-flag` is `true`, and the refusal reads:

```
cannot uninstall Longhorn because deleting-confirmation-flag is set to `false`.
Please set it to `true` using Longhorn UI or
kubectl -n longhorn-system edit settings.longhorn.io deleting-confirmation-flag
```

Tockmox installs Longhorn into **`tockmox-platform`**, not `longhorn-system`.
That message is upstream's and cannot be changed from here, so it sends you to a
namespace that does not exist on a Tockmox cluster. Substitute the namespace and
the command works. The interlock itself is worth having: it is the only thing
standing between a mistyped `delete` and every replicated volume on the cluster.

**Longhorn's admission webhook configurations are cluster-scoped and outlive the
namespace that served them.** Deleting `tockmox-platform` removes the
`longhorn-admission-webhook` Service while the `MutatingWebhookConfiguration`
and the `ValidatingWebhookConfiguration` survive it, after which every write to
every `longhorn.io` resource is rejected ... including the write that would clear
the finalizer blocking the delete. The anatomy and the escape are in
[troubleshooting](../operations/troubleshooting.md#an-orphaned-admission-webhook-rejects-the-write-that-would-free-the-resource).

**The `longhorn` and `longhorn-static` StorageClasses survive the namespace
too, and one of them is still marked `(default)`.** A class-less PVC created
after that point binds to a provisioner that no longer exists and waits forever.
Deleting the two classes is part of the uninstall sweep, and doing so leaves the
cluster with **no default StorageClass at all**, because
[install § Phase 3](../deployment/install.md#then-un-default-k3ss-storageclass)
un-defaulted `local-path` and the `.skip` file stops k3s putting the annotation
back. Whoever uninstalls has to decide which class is default next.

> **A belief, not a measurement.** The zero-defaults outcome follows from what
> the documented install does to `local-path` and from the `.skip` behaviour
> measured above. It was not observed on the 2026-08-18 uninstall run, which
> predates the `.skip` step. Read `kubectl get storageclass` after the sweep
> rather than trusting this paragraph.

## The shipped object store, and what one copy covers

`apps.garage` runs a **single** Garage node in the platform namespace, plus a
bootstrap Job that does the parts no manifest can express: assigning a cluster
layout, creating the bucket, minting an access key, and handing the credentials
to the namespaces that need them. Verified end to end on 2026-08-15: layout
applied, health went 503 to 200, bucket created, key granted, and an S3 PUT and
GET round-tripped with the bucket then reporting one object.

**It is one copy, in the cluster it protects.** That covers a dropped table, a
bad migration, a corrupted database, and a restore you rehearse. It does not
cover losing the cluster or the machine under it, and raising
`replicationFactor` on a single node does not change that ... it cannot,
because there is nowhere else to put a copy. The chart says so in its own
comment rather than claiming a higher factor and leaving every write degraded.

So: keep it if the failure you are insuring against is a database-level one,
which is most of them. Point the endpoint at something off this machine the
moment you have somewhere to point it.

**The circular dependency to refuse.** The shipped Garage runs IN the cluster,
so pointing your Kubernetes distribution's own state backup (etcd snapshots on
k3s) at it means the backup of the cluster dies with the cluster. In-cluster S3
is acceptable for database backups while you are getting started, because a
database-level mistake leaves the cluster standing. It is never acceptable for
the substrate. The full four-plane picture is in
[backup and restore § the whole-cluster story](../operations/backup-restore.md#7-the-whole-cluster-story-in-one-place).

**Volume backups have the same problem.** A `longhorn-backup` VolumeSnapshot
uploads to Longhorn's BackupTarget, and out of the box that is this same
in-cluster Garage, so it does not survive losing the cluster or Longhorn. Set
`longhorn.defaultBackupStore.backupTarget` to an NFS export or an external S3
instead; [backup and restore](../operations/backup-restore.md#longhorn-backups-into-the-shipped-garage-are-circular)
has the values.

The same Garage can also serve static sites, including Tockmox's own
documentation; see [serving documentation and static sites](serving-static-sites.md).

**Block size (`garage.blockSize`).** Garage splits every object into blocks, and
its upload cost grows with the number of blocks in an object (upstream issues
#1366 and #662), so a store that holds large backups can be slowed by the small
default. The value is empty by default, which renders no `block_size` line and
leaves Garage on its own default, 1MiB in the v2.4.1 configuration reference
(taken from upstream's documentation, not measured on this chart). Set it as a
string with units, for example `"10MiB"`; upstream suggests around that size for
large files over fast links. If you raise it, keep the multipart part size of
whatever writes to this store (the barman-cloud plugin, Tempo) a multiple of it.

Changing it on a store that already holds data has a cost, and it is not a
migration. Only objects uploaded **after** the change use the new size; what is
stored keeps its old blocks and stays readable. Identical content uploaded
before and after no longer deduplicates, so the store can use more space than
necessary until the old objects are uploaded again, and uploading them again is
the rewrite. The change also alters the config checksum on the Garage pod, so
the single pod restarts once and backups see a brief S3 outage. Not tested here:
what a running store does with a changed value, and whether a byte count
written as a string is accepted (the upstream reference shows `"1M"` and
`"10MiB"`).

## Changing the policy does not move anything

A StorageClass is chosen when a claim is created and never again. Everything
already bound stays where it is, including databases. Moving a CNPG database is a
backup and a restore into a new cluster, which is a drilled procedure. Moving
Prometheus is deleting the claim and losing the history.

Neither is urgent, and neither happens by itself. If you want a volume moved, it
is a deliberate act with a maintenance window.

## What enforces this

`tools/check-storage-policy.sh`, in CI. It renders every layer and asserts that
nothing which should be replicated sits on the local class, and that everything
which should be local does. Claims whose class is DERIVED from configuration ...
the model gateway's database and Garage ... are reported rather than fixed to
one answer, because a fixed expectation would be wrong half the time.

It also fails on a claim it does not recognise. That is intentional: a new
volume with no recorded decision behind it is exactly how every claim in this
repo ended up on `local-path` for weeks while Longhorn ran healthy and unused.
Adding a workload means adding its row.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "Uninstall Tockmox"
description: "Remove Tockmox from a cluster in the one order that finishes, including the finalizers, webhooks and cluster-scoped objects that outlive the layers and break the next install."
tags: [uninstall, removal, finalizers, webhooks, longhorn, cleanup, destructive]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Uninstall Tockmox

**This destroys data, and the order is not a suggestion.** Several steps are
unrecoverable in place if you do them in the wrong sequence.

Removing Tockmox is not the reverse of installing it. Deleting the ArgoCD
Applications leaves most of the platform running, three of the nine layers stop
mid-deletion and wait forever, and enough survives at cluster scope to break the
*next* install. Why that is true of Kubernetes operators generally, and of the
five Tockmox ships in particular, is in
[architecture](../architecture.md#cluster-scoped-state-outlives-the-layer-that-installed-it).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| **Cluster-admin on the cluster you are emptying**, and a kubeconfig pointed at it | Every step either deletes a cluster-scoped object or patches a finalizer | `kubectl auth can-i delete validatingwebhookconfigurations` prints `yes` |
| **Certainty about which cluster this is** | There is no undo. Every command below names its cluster through `KUBE_CONTEXT`, so the name you export is the cluster that gets emptied | [Name the cluster](#name-the-cluster) prints the API server it resolves to. Read it, do not remember it |
| **`kubectl` and `jq`** | Step 6 reads the namespace's status conditions, which `kubectl` prints as raw JSON | `kubectl version --client && jq --version` |
| **A backup of anything you want to keep, already off this cluster** | See the table below. The shipped object store is inside the cluster and step 3 deletes it | The check below |
| **The sealed-secrets controller key, backed up somewhere that is not this cluster** | Every SealedSecret in your site repository is encrypted to it. Losing it makes them permanently unreadable, including on a cluster you rebuild tomorrow. It is not Tockmox's and Tockmox will not put it back | `grep -c 'tls.key' YOUR_KEY_BACKUP_FILE` prints at least 1. Minting and storing it: [secrets](../administration/secrets.md#back-up-the-controller-key-now) |
| **A decision about ArgoCD** | Tockmox does not own it, it is a prerequisite. Keep it unless you are done with the cluster entirely | [ArgoCD](../administration/argocd.md#why-it-is-a-prerequisite) |

**Estimate, not a measurement: 30 to 60 minutes**, most of it waiting for
namespaces to finish terminating.

### Name the cluster

**YOU SUPPLY:** the kubeconfig context of the cluster you are emptying. Export it,
then read back the API server it resolves to:

**WORKSTATION**

```bash
export KUBE_CONTEXT=YOUR_KUBE_CONTEXT
kubectl config view --minify --context="$KUBE_CONTEXT" \
  -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

**Success:** one URL, and it is the cluster you mean to destroy. Every block
below that reaches a cluster starts with a guard line, so a block pasted into a
shell that has not run this one stops with a message instead of running against
whatever context happens to be current:

```
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
```

`kubectl --context=` with an empty value does not error: it falls back to your
current context. The guard is what turns an emptied variable into a stop rather
than a deletion on the wrong cluster.

### What is irreversibly lost

**YOU SUPPLY:** the decision on every row. There is no partial uninstall that
keeps the data.

| What goes | Where it lives now | The only thing that brings it back |
|---|---|---|
| Longhorn volumes and every replica | `tockmox-platform` | A Longhorn backup on a target that is not this cluster |
| The model gateway's Postgres | `tockmox-ai`, CloudNativePG | A Barman archive in an object store that is not this cluster |
| Authentik's identity database: users, groups, applications, OAuth clients | `tockmox-authentik` | The nightly `pg_dump`, if you moved a copy off-cluster. Seven-day window |
| Grafana state, including dashboards edited in the UI | `tockmox-monitoring` | Nothing. Dashboards provisioned from git come back on reinstall; hand edits do not |
| Prometheus TSDB and Loki chunks | node-local volumes | Nothing. These are node-local by storage policy and were never replicated |
| Alertmanager silences and its notification log | `tockmox-monitoring` | Nothing. Every alert you had already silenced or resolved re-fires on the next install |
| Everything in the shipped object store, **including backups written to it** | `tockmox-platform`, Garage | A copy somewhere that is not this cluster |

**The last row is the one that catches people.** The shipped Garage runs *in*
this cluster, so a backup whose only copy lives there dies in step 3 along with
everything it was protecting. That circular dependency is written up in
[backup and restore](backup-restore.md#7-the-whole-cluster-story-in-one-place),
and the full list of what wants backing up is
[§ 6 of the same page](backup-restore.md#6-what-else-wants-backing-up).

**The check to run before anything else.** List every claim this uninstall
destroys:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get pvc -A --sort-by=.metadata.namespace \
  -o custom-columns='NAMESPACE:.metadata.namespace,CLAIM:.metadata.name,SIZE:.spec.resources.requests.storage,CLASS:.spec.storageClassName'
```

**Success condition:** every row is either backed up somewhere that is not this
cluster, or is something you have decided to lose. That is the whole test, and
it is the last point at which it can be passed.

## Where each command runs

Two hosts are involved. Every command block below is one of these, and only
step 7c is a node:

| Marked | Runs on |
|---|---|
| **WORKSTATION** | Your own machine, against the kubeconfig for the cluster you are emptying. Everything unless marked otherwise |
| **NODE** | A k3s **server** node, over SSH or at its console. Step 7c only |

## The order, and what each step is holding up

| Step | Marked | Why it sits here |
|---|---|---|
| [1. Delete the ArgoCD Applications](#1-delete-the-argocd-applications) | Required | A surviving Application with `selfHeal` recreates everything the later steps delete. Deleting `tockmox-platform` also runs Longhorn's uninstaller hook, which must fail (the flag is still `false`) |
| [2. Delete the workload namespaces](#2-delete-the-workload-namespaces) | Required | They will stall. That is expected, and step 3 is the reason |
| [3. Delete the object store's PVCs](#3-delete-the-object-stores-pvcs) | Conditional | Two PVCs in a *different* namespace are what every namespace in step 2 is waiting on |
| [3b. Delete released volumes](#3b-delete-released-volumes-the-longhorn-storageclass-retains-them-tm-0789) | Conditional | A `Retain` StorageClass leaves the volume behind after its claim goes, and step 4 refuses to continue while any volume is listed |
| [4. Clear Longhorn's interlock, then delete the platform namespace](#4-clear-longhorns-uninstall-interlock-then-delete-the-platform-namespace) | Required | The interlock patch is a write to a `longhorn.io` resource, so it has to happen while the webhook still answers |
| [5. Delete Longhorn's webhook configurations, then its finalizers](#5-delete-longhorns-webhook-configurations-then-its-finalizers) | Required | Reverse those two and the finalizer patch is rejected by a webhook whose Service you just deleted |
| [6. Clear whatever finalizer the namespace names](#6-clear-whatever-finalizer-the-namespace-names) | Conditional | Only if `tockmox-platform` is still there after step 5 |
| [7. Sweep the cluster-scoped leftovers](#7-sweep-the-cluster-scoped-leftovers) | Required | Namespaced deletion never touched these, and they break the next install |
| [8. Confirm](#8-confirm) | Required | Three of the sweeps in step 7 are decisions, and a half-made decision looks exactly like a finished one. The second check there derives its kinds from the API server rather than naming them |
| [9. Removing k3s itself](#9-removing-k3s-itself--optional-and-the-reboot-a-transactional-os-may-need) | Optional | Only if you are tearing the node down rather than reinstalling onto it. On a transactional OS the uninstaller may not be finished when it exits, and whether it is depends on how k3s was installed |

## 1. Delete the ArgoCD Applications

**Required.**

Start with the three roots:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n argocd delete application tockmox-root site-apps site-secrets
```

**This does not cascade.** Observed 2026-08-18: root-app and site-apps deleted
cleanly and all nine layer Applications kept running, healthy and untouched.
Stopping here removes three objects and nothing else.

`site-secrets` is the Application that applies the SealedSecrets in your site
repository. Deleting it with `prune` on removes the SealedSecret objects and,
with them, the Secrets the controller derived. **That is a credential
deletion**, and the layers still running will start reporting
`CreateContainerConfigError` as pods restart. Nothing is lost that cannot be
re-applied from your site repository ... the sealed files are still committed
there ... provided the controller's private key still exists. If it does not,
they are undecryptable and every credential has to be minted again.

**Before the next command, confirm Longhorn's interlock is still closed.**
Deleting `tockmox-platform` runs Longhorn's own uninstaller as a pre-delete hook
(see below), and that uninstaller is stopped only by
`deleting-confirmation-flag` being `false`. Step 4 is where this page sets it to
`true`. If you read ahead, or are re-running this page after a failure, it may
already be `true` ... and then the hook will succeed and uninstall Longhorn with
every volume attached and every workload namespace still up:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform get settings.longhorn.io deleting-confirmation-flag \
  -o jsonpath='{.value}{"\n"}'
```

Prints `false`. **If it prints `true`, set it back before continuing:**
`kubectl -n tockmox-platform patch settings.longhorn.io deleting-confirmation-flag --type=merge -p '{"value":"false"}'`.
(That the hook succeeds on `true` is reasoned from the failed Job's log rather
than tested, because testing it destroys the cluster in the wrong order.)

Delete the layers in reverse wave order, so dependents go before what they
depend on:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n argocd delete application \
  tockmox-ai tockmox-devops tockmox-selfcheck \
  tockmox-identity \
  tockmox-observability tockmox-exporters \
  tockmox-platform tockmox-policy tockmox-crds
```

**Deleting `tockmox-platform` fires a Longhorn pre-delete hook, and it fails
here on purpose.** That Application is the only one that carries a finalizer
(`pre-delete-finalizer.argocd.argoproj.io`), and the Longhorn subchart ships an
uninstaller Job as a pre-delete hook. The chart does not switch that hook off
today, so you will see all of this, measured on the 0.6.0 release candidate walk
of 2026-09-13:

- The command returns exit code 0, either after a pause of about a minute (62
  seconds on that walk, the hook running first) or almost at once (1 second on
  the 0.7.1-rc2 gate, 2026-10-04, where ArgoCD dropped the Application and the
  hook ran just after). Either is expected; neither tells you how the hook went.
- A Job named `longhorn-uninstall` appears in `tockmox-platform` and fails with
  "cannot uninstall Longhorn because deleting-confirmation-flag is set to
  false". That is Longhorn's interlock doing its job, not a fault to chase.
- ArgoCD removes its finalizer over the failed hook, so **the command succeeds
  even though the hook did not**. Exit code 0 is not evidence the hook behaved.
- The failed Job and its two `Error` pods stay behind. They are removed below.

The failed Job does not re-run when step 4 sets the flag to `true` (watched for
45 seconds after the patch: no new pod). Disabling the hook from the chart is the
better long-term fix and is a chart change, not a docs one.

**If** `kubectl -n argocd get application cnpg-barman-plugin` returns an
Application rather than `NotFound`, delete that one too:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n argocd delete application cnpg-barman-plugin
```

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n argocd get applications
```

None of the names above is listed. **That alone does not cover the Longhorn hook**,
because ArgoCD reports the Application gone even when its hook failed. Read the
Job's own state, then remove it:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform get job longhorn-uninstall \
  -o jsonpath='{.status.conditions[*].type}{"\n"}'
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform delete job longhorn-uninstall --ignore-not-found
```

The first line must print `Failed` (on the measured run, `FailureTarget Failed`).
**If it prints `Complete`, stop:** the uninstaller ran to the end, which means
the flag was `true` at the time. Longhorn is already gone or going, and the
volume check at step 4 is the next thing to read. `NotFound` is also acceptable
and means this chart or ArgoCD version did not run the hook.

Anything still in the Applications list is yours rather than
Tockmox's, and it is worth a decision now: an Application with `selfHeal` that
manages anything in a `tockmox-*` namespace will put back what the next steps
delete, and the recreation looks like the deletion silently failing.

## 2. Delete the workload namespaces

**Required.** `tockmox-platform` is deliberately not in this list.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" delete namespace --wait=false \
  tockmox-ai tockmox-devops tockmox-monitoring \
  tockmox-authentik tockmox-selfcheck tockmox-diagnostic
```

**`--wait=false` is not optional here.** `kubectl delete` waits for the object
to be gone by default, and none of these will be gone until step 3. Without the
flag the command sits there and you cannot run the step that unblocks it.

**Leave `tockmox-platform` until step 4.** It holds Longhorn, and every other
namespace's volumes need Longhorn's CSI driver alive in order to detach. Delete
it early and the others can never finish.

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get namespace | grep '^tockmox-'
```

The six report `Terminating` and `tockmox-platform` reports `Active`.
**`Terminating` is the expected state at this point, not a failure.** A
namespace that has already gone is fine too; it had nothing on a Longhorn
volume.

**Your site's own applications are not on this page.** Step 1 deletes
`site-apps` without cascading, so whatever your site deployed keeps running, and
a namespace the platform layer created for it (`garage.createCredentialsNamespaces`,
marked so ArgoCD never deletes it) stays too. None of the checks on this page looks
for them. On the 0.7.1-rc2 gate the worked-example site's `news` namespace, with its
Miniflux Deployment and CloudNativePG database, was still running after step 8.
Remove each one the way
[removing an application](../administration/removing-an-application.md) describes,
or delete its namespace, before step 7e takes the CloudNativePG CRDs away from a
database that is still running.

## 3. Delete the object store's PVCs

**Conditional. Run this if** the following returns a StatefulSet rather than
`NotFound`:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform get statefulset tockmox-garage
```

Garage ships with the `dataProtection` capability, so a cluster that never
enabled it has nothing to delete here and its namespaces from step 2 should
already be finishing.

Observed 2026-08-18: `tockmox-ai`, `tockmox-devops`, `tockmox-monitoring` and an
unrelated application namespace all sat `Terminating` indefinitely, and the
blocker in every case was **two PersistentVolumeClaims in a different
namespace** ... Garage's, in `tockmox-platform`. Nothing in any of the four
namespaces named them.

Delete the StatefulSet first, or it recreates its pod every thirty seconds while
you work:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform delete statefulset tockmox-garage
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform delete pvc data-tockmox-garage-0 meta-tockmox-garage-0
```

If the second command does not return, the Garage pod has not finished going
yet and PVC protection is holding the claims. Ctrl-C is safe: the deletion
continues server-side.

**Success condition**, allowing ninety seconds:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get namespace | grep '^tockmox-'
```

`tockmox-platform` alone, still `Active`. All four namespaces released within
ninety seconds of those two PVCs going on the 2026-08-18 run; on the 0.7.1-rc2
gate two of them took just under two minutes. If one is still
`Terminating` several minutes later, ask it what it is holding rather than
guessing: [troubleshooting](troubleshooting.md#a-namespace-is-stuck-terminating).

## 3b. Delete released volumes: the Longhorn StorageClass retains them (TM-0789)

**Conditional. Run this if** the Longhorn StorageClass on this cluster has
`reclaimPolicy: Retain`, which is the default from 0.7.1. A cluster installed
from an earlier release has `Delete`, nothing is left behind, and the listing
below prints nothing.

With `Retain`, deleting a PersistentVolumeClaim does **not** delete the volume.
The PersistentVolume goes to `Released` and the Longhorn volume behind it keeps
every byte. That is the point of the policy, and the consequence for this page is
that the PVCs deleted by steps 2 and 3 left their data behind. Step 4's first
check will list those volumes, and it tells you to stop. Delete them here,
deliberately, one by one.

List the released volumes:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get pv --no-headers \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name' \
  | awk '$2 == "Released" && $3 ~ /^longhorn/'
```

**YOU SUPPLY:** the decision on every row. This is the last point where the data
exists, and deleting the volume ends it. A row you want to keep can be left
alone, but then step 4 stops at its volume check and the namespace cannot go
until you have decided.

For each row you have decided to lose, delete the Longhorn volume first and the
PersistentVolume second. The Longhorn volume has the same name as its
PersistentVolume. **YOU SUPPLY:** `PV_NAME`, from the `NAME` column above:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform delete volumes.longhorn.io PV_NAME
kubectl --context="$KUBE_CONTEXT" delete pv PV_NAME
```

Deleting only the PersistentVolume is not enough under `Retain`: the object goes
and the Longhorn volume stays. On the 0.7.1-rc2 gate, deleting the Longhorn
volume removed its PersistentVolume as well, so the second command printed
`NotFound` for every row. That is the outcome you want, not an error; run it
anyway, because a version that leaves the PersistentVolume behind needs it.

**Success condition:** the `awk` listing above prints nothing, and
`kubectl -n tockmox-platform get volumes.longhorn.io` prints
`No resources found in tockmox-platform namespace.`

## 4. Clear Longhorn's uninstall interlock, then delete the platform namespace

**Required.**

**Confirm no volumes are left first.** The interlock exists for a good reason
and this is the check it stands in for:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform get volumes.longhorn.io
```

Expect `No resources found in tockmox-platform namespace.` **If any volume is
listed, stop.** Either it is a volume that
[step 3b](#3b-delete-released-volumes-the-longhorn-storageclass-retains-them-tm-0789)
exists to clear, or something above did not finish. Clearing the flag now
destroys a volume that still has a claim on it.

Longhorn will otherwise refuse to uninstall, and its refusal sends you to
`longhorn-system`, a namespace this cluster does not have: Tockmox installs
Longhorn into `tockmox-platform`. The message is upstream's and the full note is
in [storage](../administration/storage.md#uninstalling-longhorn-and-what-it-leaves-behind).

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform patch settings.longhorn.io deleting-confirmation-flag \
  --type=merge -p '{"value":"true"}'
```

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform get settings.longhorn.io deleting-confirmation-flag \
  -o jsonpath='{.value}{"\n"}'
```

Prints `true`. **This write has to happen before the namespace goes**, because
it is a write to a `longhorn.io` resource and step 5 is entirely about what
happens to those once the namespace's webhook Service is gone.

Then:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" delete namespace tockmox-platform --wait=false
```

**Success condition:** `kubectl get namespace tockmox-platform` reports
`Terminating`. It will not finish here, and step 5 is why.

## 5. Delete Longhorn's webhook configurations, then its finalizers

**Required, and the order inside this step is the whole point.**

Deleting the namespace removed the Longhorn admission webhook's **Service**. Its
`MutatingWebhookConfiguration` and `ValidatingWebhookConfiguration` are
cluster-scoped and survived it, so every write to every `longhorn.io` resource
now fails ... including the write that clears the finalizer that is blocking the
deletion. It is a closed loop. The verbatim error, the anatomy and the knock-on
are in
[troubleshooting](troubleshooting.md#an-orphaned-admission-webhook-rejects-the-write-that-would-free-the-resource).

Break the loop first:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" delete mutatingwebhookconfiguration longhorn-webhook-mutator
kubectl --context="$KUBE_CONTEXT" delete validatingwebhookconfiguration longhorn-webhook-validator
```

Then clear the orphaned finalizers. The controller that would normally remove
them has already been deleted, so nothing else will:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
for kind in $(kubectl --context="$KUBE_CONTEXT" api-resources --api-group=longhorn.io -o name); do
  for n in $(kubectl --context="$KUBE_CONTEXT" -n tockmox-platform get "$kind" -o name 2>/dev/null); do
    kubectl --context="$KUBE_CONTEXT" -n tockmox-platform patch "$n" --type=merge \
      -p '{"metadata":{"finalizers":null}}'
  done
done
```

The loop ranges the whole API group on purpose. Observed still holding
finalizers on 2026-08-18: the `Node`, the `BackupTarget`, the `EngineImage`,
`Volume`s and `volumeattachments.longhorn.io`. That list is one run's snapshot
rather than a specification, which is why the loop does not name them.

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get namespace tockmox-platform
```

Either `NotFound`, in which case skip to step 7, or still `Terminating`, in
which case continue to step 6. **What must not appear is a
`failed calling webhook` error from the patch loop.** If one does, a webhook
configuration is still present:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get mutatingwebhookconfiguration,validatingwebhookconfiguration \
  | grep -i longhorn
```

Delete what that names, then re-run the loop.

**Conditional knock-on, run this if** the next command lists anything:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get pod -A | grep '^tockmox-' | grep Terminating
```

Once the Volume finalizers are gone, a pod that still had a Longhorn volume
mounted can wedge `Terminating` forever, because the kubelet is waiting for an
unmount confirmation from a CSI plugin that has just been dismantled. Its
namespace then reports pods as its only remaining content. There is nothing left
to shut down cleanly, so force them. **YOU SUPPLY:** the namespace and pod name,
both from the output above:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n NAMESPACE_FROM_THE_COMMAND_ABOVE \
  delete pod POD_NAME_FROM_THE_COMMAND_ABOVE --force --grace-period=0
```

**Success condition:** that `grep` returns nothing.

## 6. Clear whatever finalizer the namespace names

**Conditional. Run this if** `kubectl get namespace tockmox-platform` still
returns a namespace after step 5. If it returns `NotFound`, skip to step 7.

Ask the namespace rather than guessing. It names the resource type and the exact
finalizer:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get namespace tockmox-platform -o jsonpath='{.status.conditions}' | jq
```

Observed 2026-08-18:

```
NamespaceContentRemaining:    "Some resources are remaining: services. has 1 resource instances"
NamespaceFinalizersRemaining: "Some content in the namespace has finalizers remaining:
                               cnpg.io/cleanupPlugin in 1 resource instances"
```

Same shape as step 5, different operator: a `Service` pinned by CloudNativePG's
`cnpg.io/cleanupPlugin` finalizer, with the CNPG operator already deleted.
**YOU SUPPLY:** the resource the conditions name. On that run it was
`service/barman-cloud`:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-platform patch service/barman-cloud --type=merge \
  -p '{"metadata":{"finalizers":null}}'
```

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get namespace tockmox-platform
```

`Error from server (NotFound)`. The namespace disappeared immediately after that
patch on the 2026-08-18 run. If it is still there, re-read the conditions: they
name the *next* blocker, and clearing one at a time is the method. On that run
three successive guesses about the cause were wrong before the conditions were
read. Other shapes this takes:
[troubleshooting](troubleshooting.md#a-namespace-is-stuck-terminating).

## 7. Sweep the cluster-scoped leftovers

**Required.** Namespaced deletion did not touch any of these, and several are
actively harmful rather than merely untidy. Why they exist at all:
[architecture](../architecture.md#cluster-scoped-state-outlives-the-layer-that-installed-it).

### 7a. Webhook configurations pointing at services that no longer exist

**Required.** Any attempt to create a matching resource fails until these are
gone, so a reinstall fails at its first MetalLB or CNPG object, with an error
naming the new install rather than the old one.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" delete validatingwebhookconfiguration --ignore-not-found \
  cnpg-validating-webhook-configuration \
  metallb-webhook-configuration \
  tockmox-observability-kube-admission \
  tockmox-platform-cert-manager-webhook

kubectl --context="$KUBE_CONTEXT" delete mutatingwebhookconfiguration --ignore-not-found \
  cnpg-mutating-webhook-configuration \
  tockmox-observability-kube-admission \
  tockmox-platform-cert-manager-webhook
```

`--ignore-not-found` rather than redirecting stderr: a name that was never there
is expected, an RBAC refusal is not, and `2>/dev/null` hides both equally well.

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get validatingwebhookconfiguration,mutatingwebhookconfiguration \
  | grep -Ei 'longhorn|cnpg|metallb|cert-manager|kube-admission' \
  || echo "no orphan webhooks: correct"
```

Prints `no orphan webhooks: correct`.

### 7b. StorageClasses whose provisioner is gone

**Required**, and it leaves you a decision. Observed 2026-08-18 after the
namespace was deleted: `longhorn` still present and still marked `(default)`. A
class-less PVC created afterwards binds to a provisioner that no longer exists
and waits forever.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" delete storageclass --ignore-not-found longhorn longhorn-static
kubectl --context="$KUBE_CONTEXT" get storageclass
```

**YOU SUPPLY:** which class is default now. On a stock install this is easy ...
Tockmox never took your default, so removing Longhorn's two classes leaves
whatever you had, normally `local-path`, still default.

**If this site set `longhorn.persistence.defaultClass: true`**, installation did
take it, and `local-path` was un-defaulted by hand at
[install § Phase 3](../deployment/install.md#then-un-default-k3ss-storageclass).
Removing Longhorn's classes then leaves the cluster with **no default at all**,
which is its own silent failure. **If** the listing shows no `(default)` and you
want `local-path` back:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" patch storageclass local-path -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

**Success condition:** `kubectl get storageclass` shows exactly one `(default)`
and it is the one you meant. Zero is a valid answer only if you meant it.

### 7c. Return the storage addon to k3s

**Optional, and k3s only. NODE.** Cluster preparation put a `.skip` file beside
k3s's packaged `local-storage` addon so k3s would stop re-asserting the
StorageClass default. Leaving the file behind means the class and its
provisioner stay unmanaged, and k3s will never upgrade them again.

**If** you are keeping this cluster and want k3s to own that addon again, run
both lines on **every** k3s server node. A server that keeps the file goes on
refusing to reconcile the addon, and the cluster then disagrees with itself
about who owns `local-path`:

```bash
sudo rm -f /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip
sudo systemctl restart k3s
```

That makes the patch in 7b redundant rather than wrong: k3s re-applies its own
manifest, which ships `is-default-class: "true"`.

**Success condition, from the WORKSTATION:** `kubectl get storageclass` shows
`local-path` as `(default)` after the restart.

**Run once, on one node.** On the 0.7.1-rc2 gate (2026-10-04, k3s
`v1.36.4+k3s1`, single server) both lines ran on the node after steps 1 to 7b:
k3s came back in under 30 seconds, `local-path` was the one `(default)` class,
and it carried k3s's `objectset.rio.cattle.io/hash` label again, so k3s owns it.
A multi-server cluster has not been tried. Read `kubectl get storageclass`
after the restart rather than assuming.

### 7d. Tockmox's RBAC admission guardrails

**Optional, and a deliberate decision either way.** Four Tockmox-authored
ValidatingAdmissionPolicies outlive the policy layer that installed them, and
each one carries its own binding, which is a second object that outlives it too.
They go on acting, including through your next install. **On a stock install
only `deny-privileged-rbac` refuses a violation**; the other three record and
warn, which is a different thing and is easy to misread as protection:

| Policy | Acts on | `validationActions` on a stock install | Set by |
|---|---|---|---|
| `deny-privileged-rbac` | A ClusterRoleBinding to `cluster-admin` that is not in `rbacGuardrails.clusterAdminAllowlist` | `["Deny"]` ... refuses | `rbacGuardrails.denyPrivilegedRbac.validationActions` |
| `deny-privileged-rolebinding` | A RoleBinding referencing the `cluster-admin` or `admin` ClusterRole | `["Audit","Warn"]` ... records a violation, does not refuse it | `rbacGuardrails.denyPrivilegedRolebinding.validationActions` |
| `deny-rbac-aggregation-injection` | A ClusterRole carrying an `rbac.authorization.k8s.io/aggregate-to-*` label that is not allowlisted | `["Audit","Warn"]` ... records a violation, does not refuse it | `rbacGuardrails.denyAggregationInjection.validationActions` |
| `deny-wildcard-clusterrole` | A ClusterRole granting `*/*/*` | `["Audit","Warn"]` ... records a violation, does not refuse it | `rbacGuardrails.denyWildcardClusterrole.validationActions` |

**Measured 2026-09-04** on a stock install, charts `0.6.0`. **These are the
shipped values, not a property of your cluster.** All four are site-settable and
the chart's comments invite you to raise them, so on a cluster you did not just
install, read the bindings rather than this table:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get validatingadmissionpolicybinding \
  -o custom-columns=NAME:.metadata.name,ACTIONS:.spec.validationActions
```

Two things this table does not say, both of which matter here:

- **`enabled` is not enforcement.** `denyAggregationInjection.enabled` is `true`
  by default, and it decides whether that policy **exists**, not whether it
  refuses. It ships enabled and auditing. Read `validationActions`, never
  `enabled`, when you want to know what a policy does to a request.
- **`Audit,Warn` still refuses on an evaluation error.**
  `deny-privileged-rolebinding` and `deny-rbac-aggregation-injection` inherit
  `failurePolicy` from `rbacGuardrails.denyPrivilegedRbac.failurePolicy`, which
  is `Fail`. A CEL expression that errors rather than returning false rejects
  the request whatever `validationActions` says. Only
  `deny-wildcard-clusterrole` ships `failurePolicy: Ignore` and therefore
  genuinely cannot block anything ... which is why raising it takes **two**
  keys, `rbacGuardrails.denyWildcardClusterrole.validationActions` **and**
  `.failurePolicy`. Raising the actions alone leaves the error case open.

Both of those `denyWildcardClusterrole` keys are new in this release. Before it
they were literals in the template, so a site that set them saw no error and no
effect ... `rbacGuardrails` accepts unknown keys, and silently ignored them.

**`deny-privileged-rbac` is the one you will hit**, because minting a throwaway
cluster-admin binding to unstick something is exactly the move it exists to
refuse, and it refuses it. That is the guardrail working correctly, and it is
worth knowing that the obvious break-glass move is blocked by the product you
are in the middle of removing. The error, and the allowlist alternative, are in
[troubleshooting](troubleshooting.md#it-also-refuses-your-break-glass-clusterrolebinding-including-mid-uninstall).

Remove it deliberately, last, once you no longer need what it protects:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" delete validatingadmissionpolicybinding --ignore-not-found deny-privileged-rbac
kubectl --context="$KUBE_CONTEXT" delete validatingadmissionpolicy --ignore-not-found deny-privileged-rbac
```

The other three do not block break-glass, and they survive the uninstall just
the same. Remove them together, or leave them together, but **know which you
chose** ... step 8 checks the count against your decision:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" delete validatingadmissionpolicybinding --ignore-not-found \
  deny-privileged-rolebinding deny-rbac-aggregation-injection deny-wildcard-clusterrole
kubectl --context="$KUBE_CONTEXT" delete validatingadmissionpolicy --ignore-not-found \
  deny-privileged-rolebinding deny-rbac-aggregation-injection deny-wildcard-clusterrole
```

**Success condition:** `kubectl get validatingadmissionpolicy | grep '^deny-'`
returns the number you decided on, which is four, three or none.

### 7e. CRDs

**Optional, and the step to be slow about.** Deleting a CRD deletes every object
of that kind cluster-wide, in every namespace, including ones that are not
Tockmox's.

**The set is derived, not listed.** A list of vendors ages against the next
subchart. A CRD carries no ArgoCD tracking annotation to select on, so the
listing instead removes what is not Tockmox's to remove: k3s's own CRDs,
ArgoCD's three and sealed-secrets' one. Everything that remains is a CRD that
something installed, and you decide each group.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get crd -o name | sed 's|.*/||' \
  | grep -vE '\.(k3s|helm)\.cattle\.io$|^(applications|applicationsets|appprojects)\.argoproj\.io$|^sealedsecrets\.bitnami\.com$' \
  | sort -t. -k2
```

Append `| sed 's/^[^.]*\.//' | sort | uniq -c` to see it as a count per API
group. The `grep -v` assumes k3s; on another distribution add that
distribution's own groups to it before you read the result.

**What a Tockmox install puts there**, from rendering the charts with
`helm template --include-crds`. This table is a guide to recognising the
groups, not a list to delete from; the listing above is the truth about your
cluster:

| API group | Installed by | Shared with other workloads? |
|---|---|---|
| `monitoring.coreos.com` | `tockmox-crds`, prometheus-operator | Often. Anything else shipping a ServiceMonitor or PrometheusRule loses it |
| `monitoring.grafana.com` | `tockmox-observability`, Grafana Alloy (`PodLogs`) | Only if something else uses Alloy's PodLogs |
| `longhorn.io` | `tockmox-platform`, Longhorn | Longhorn's own volume and node records. Leave them until step 4 is done and no volume you want remains |
| `postgresql.cnpg.io`, `barmancloud.cnpg.io` | `tockmox-platform`, CloudNativePG and the Barman Cloud plugin | A `Cluster` or `Backup` of yours is deleted with them |
| `cert-manager.io`, `acme.cert-manager.io` | `tockmox-platform`, cert-manager | A Certificate or Issuer of yours is deleted with them |
| `metallb.io` | `tockmox-platform`, MetalLB | Your address pools go with them |
| `traefik.io`, `hub.traefik.io` | `tockmox-platform`, Traefik | An IngressRoute of yours is deleted with them |
| `snapshot.storage.k8s.io`, `groupsnapshot.storage.k8s.io` | `tockmox-platform`, the snapshot controller | A CSI driver other than Longhorn would use these too. The chart annotates them to be kept on purpose |
| `argoproj.io` (Workflows kinds) | `tockmox-devops`, Argo Workflows | Not rendered by `helm template`: the subchart applies its full CRDs from a pre-install Job. ArgoCD's own three `argoproj.io` CRDs are excluded by the listing above and stay |

**YOU SUPPLY:** which groups you delete. Delete only what you are certain
nothing else uses. When you have decided, delete one group at a time, so a
mistake costs one group:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get crd -o name | grep -E '\.longhorn\.io$' | xargs -r kubectl --context="$KUBE_CONTEXT" delete --ignore-not-found
```

Substitute the group you decided on for `longhorn\.io`.

**Success condition:** every CRD the listing still prints is one you decided to
keep, and you can say why for each.

### 7f. Everything else ArgoCD installed cluster-wide: RBAC, the IngressClass, PriorityClasses, ClusterIssuers, the CSIDriver

**Required, and run it last in step 7** so the decisions you made in 7d and 7e
are respected ... it skips those two kinds on purpose.

**Namespaced deletion never touches a cluster-scoped object, and steps 1 to
7e do not either**, so run this step ... only `helm install` noticed on the
run that found this, because ArgoCD applies server-side and would have
adopted every leftover object silently
([history](#history-step-7f-and-the-derived-check)).

**The set is derived, not listed.** Every object ArgoCD applied on Tockmox's
behalf carries the `argocd.argoproj.io/tracking-id` annotation, prefixed with
the Application that owns it (`tockmox-platform:`, `tockmox-policy:`,
`site-apps:`). The block walks every cluster-scoped kind the API server knows,
which is what a hand-written list of kinds cannot do: the first version of step
8 named eight kinds and passed while residue sat in the ones it did not name.

**Read the list before you delete it.** First the listing:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
for k in $(kubectl --context="$KUBE_CONTEXT" api-resources --namespaced=false --verbs=list,delete -o name | sort -u); do
  case "$k" in namespaces|customresourcedefinitions.*|validatingadmissionpolic*) continue;; esac
  kubectl --context="$KUBE_CONTEXT" get "$k" --ignore-not-found --no-headers \
    -o custom-columns='NAME:.metadata.name,TRACKED:.metadata.annotations.argocd\.argoproj\.io/tracking-id' \
  | awk -v k="$k" '$2 ~ /^(tockmox|site)-/ {print k, $1}'
done
```

**The `case` line skips the same three kinds the sweep below skips**, so the
listing and the sweep answer the same question; without it the listing reports
namespaces the sweep deliberately leaves to steps 2 to 6, and this step's
success condition can never be reached
([history](#history-step-7f-and-the-derived-check)).

Every line names an object Tockmox's Applications created. On a live install
this prints around ninety lines across ClusterRoles, ClusterRoleBindings,
ClusterIssuers, webhook configurations, the IngressClass, PriorityClasses and
the VolumeSnapshotClass; after steps 1 to 7e most of it is still there. **If
a line names something you recognise as yours and not Tockmox's, stop** ... it
means one of your own Applications uses a `tockmox-` or `site-` name, and the
prefix match below would take it.

Then the sweep. It skips CRDs, admission policies and namespaces, because 7e
and 7d are your decisions and steps 2 to 6 own the namespaces:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
for k in $(kubectl --context="$KUBE_CONTEXT" api-resources --namespaced=false --verbs=list,delete -o name | sort -u); do
  case "$k" in namespaces|customresourcedefinitions.*|validatingadmissionpolic*) continue;; esac
  kubectl --context="$KUBE_CONTEXT" get "$k" --ignore-not-found --no-headers \
    -o custom-columns='NAME:.metadata.name,TRACKED:.metadata.annotations.argocd\.argoproj\.io/tracking-id' \
  | awk '$2 ~ /^(tockmox|site)-/ {print $1}' \
  | xargs -r -n 20 kubectl --context="$KUBE_CONTEXT" delete "$k" --ignore-not-found
done
kubectl --context="$KUBE_CONTEXT" delete csidriver --ignore-not-found driver.longhorn.io
```

The CSIDriver is named by hand because Longhorn's manager creates it at runtime
rather than ArgoCD applying it, so it carries no tracking annotation. It is the
one object in this step that the derivation cannot see, and it is stated here
so the next runtime-created object is looked for rather than assumed absent.

**Success condition:** the listing block above prints nothing.

**Your own applications are NOT removed by this page, and the check in step 8
cannot see them.** `site-apps` is deleted in step 1 and deletion does not
cascade, so every namespace, workload and volume your site declared keeps
running. Measured on the reference lab 2026-09-13: after this page was followed
end to end, a site-declared namespace was still `Active` with a Deployment, a
database and a bound PersistentVolume in it. Step 8 greps `^tockmox-`, so it
reports a clean cluster regardless. List what your own site declared and decide
each one:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get namespace -o name | grep -v 'kube-\|default\|argocd'
kubectl --context="$KUBE_CONTEXT" get pv -o custom-columns='NAME:.metadata.name,CLAIM:.spec.claimRef.namespace'
```

Anything listed is yours, and removing it is your call rather than this page's.

**If you are removing ArgoCD as well, `helm uninstall` it; do not delete its
namespace.** ArgoCD's own three ClusterRoles and ClusterRoleBindings are
helm-owned and cluster-scoped, so `kubectl delete namespace argocd` leaves them
behind and the next `helm install argocd` refuses with `invalid ownership
metadata`. Measured 2026-09-12: the objects it refused over were dated
2026-09-02, two uninstalls earlier. ArgoCD and sealed-secrets are prerequisites
you installed, not Tockmox's, which is why this page does not remove them and
why their objects do not carry the tracking annotation the sweep matches.

## 8. Confirm

**Required.** Steps 7c, 7d and 7e are decisions rather than commands, and a
half-made decision looks exactly like a finished one.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get namespace | grep '^tockmox-' || echo "no tockmox namespaces: correct"
kubectl --context="$KUBE_CONTEXT" -n argocd get applications
kubectl --context="$KUBE_CONTEXT" get storageclass
kubectl --context="$KUBE_CONTEXT" get validatingwebhookconfiguration,mutatingwebhookconfiguration \
  | grep -Ei 'longhorn|cnpg|metallb|cert-manager|kube-admission' \
  || echo "no orphan webhooks: correct"
kubectl --context="$KUBE_CONTEXT" get validatingadmissionpolicy | grep '^deny-' || echo "no deny- policies"
```

Line by line:

| Command | What it should say |
|---|---|
| namespaces | `no tockmox namespaces: correct` |
| applications | No `tockmox-*`, no `site-apps` and no `site-secrets`. Anything listed is yours |
| storageclass | No `longhorn` or `longhorn-static`, and exactly one `(default)` unless you deliberately left none |
| webhooks | `no orphan webhooks: correct` |
| admission policies | The count you chose in 7d: four, three, or `no deny- policies`. **Any other number means 7d was half-done** |

The last line is on the checklist because 7d removes the policies in two
deliberate commands, and either can be skipped. A confirmation that does not
look for them lets you finish believing the cluster is clean while Tockmox is
still enforcing on it.

**Then the check that does not depend on anyone having thought of the kind.**
The block above names what it looks for; this one asks the API server for
every cluster-scoped kind and prints whatever is not the distribution's own
([history](#history-step-7f-and-the-derived-check)):

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
for k in $(kubectl --context="$KUBE_CONTEXT" api-resources --namespaced=false --verbs=list -o name | sort -u); do
  out="$(kubectl --context="$KUBE_CONTEXT" get "$k" -l '!kubernetes.io/bootstrapping,!objectset.rio.cattle.io/hash' --no-headers --ignore-not-found)"
  [ -n "$out" ] && { printf '== %s\n' "$k"; printf '%s\n' "$out"; }
done
```

**Read it; do not count it.** The selector removes what k3s labels as its own
(`kubernetes.io/bootstrapping` on the RBAC it ships,
`objectset.rio.cattle.io/hash` on its packaged addons). What remains on a clean
k3s cluster is the API server's own furniture: its four CRDs and four
namespaces, the `apiservices` and flow-control defaults, the two `system-*`
PriorityClasses, the node and its `csinode`, the service CIDR and its IPs,
`local-path` if you left it ... plus ArgoCD's and sealed-secrets' RBAC if you
kept those prerequisites. **Anything carrying `tockmox`, `longhorn`, `cnpg`,
`cert-manager`, `metallb`, `traefik` or `argo-workflows` in its name is a miss**,
and the step to go back to is 7f. On a distribution other than k3s the
furniture differs and the selector may remove less; the test is the same,
because it is about what you recognise rather than what a list expected.

The `2>/dev/null` is deliberate here and only here: the loop walks kinds a
read-only kubeconfig may not be allowed to list, and a refusal on one of those
is noise in a confirmation, where in the sweeps above it would be a missed
deletion. If the whole loop prints nothing, that is not a clean cluster ... it
is a credential that cannot list anything, and the CRDs and namespaces would
have printed.

**Reinstalling? Run this block before you start**, not after the next install
fails. A leftover webhook or a default StorageClass with no provisioner produces
failures whose messages point at the new install rather than at the old one.

## 9. Removing k3s itself ... optional, and the reboot a transactional OS may need

Everything above removes Tockmox and leaves the cluster running. If you are
going further and tearing the node down, which is what a
teardown-and-greenfield reinstall does, k3s ships its own uninstaller and this
page does not duplicate it. One property of that uninstaller belongs here,
because it bites precisely the reader who is about to reinstall.

**On a transactional operating system, `k3s-uninstall.sh` may not be finished
when it exits ... and whether it is depends on how k3s was installed.** The
uninstaller ends by removing the `k3s-selinux` RPM through
`transactional-update`. Whether that does anything depends on whether the RPM
was ever installed, and on openSUSE MicroOS
[fresh-install section 4a](../deployment/fresh-install.md#4a-the-first-server--both-shapes-on-node-1)
deliberately skips it.

**If `k3s-selinux` WAS installed** ... a conventional distribution, or a MicroOS
node installed without `INSTALL_K3S_SKIP_SELINUX_RPM=true` ... the removal
happens in a **new Btrfs snapshot that only becomes active on reboot**. The
uninstaller's last two lines then read, verbatim from a real teardown on
2026-09-15:

```
New default snapshot is #19 (/.snapshots/19/snapshot).
Please reboot your machine to activate the changes and avoid data loss.
```

**"Avoid data loss" is aimed at you, and it is not boilerplate.** The running
system is still the old snapshot. Anything written to it after the update
staged a new one can be discarded when you boot into that new one. So an
operator who runs the uninstaller and immediately reinstalls is installing into
a snapshot that is about to be replaced, and the install disappears at the next
reboot with nothing having reported an error. **Reboot before you reinstall.**

**If you followed section 4a's MicroOS block, it was NOT installed**, because
that block sets `INSTALL_K3S_SKIP_SELINUX_RPM=true`. There is nothing to remove,
so `transactional-update` opens a snapshot, finds no work, and throws it away.
The uninstaller ends like this instead, verbatim from a real teardown on
2026-09-17:

```
'k3s-selinux' not found in package names. Trying capabilities.
Nothing to do.
Application returned with exit status 104.
Removing snapshot #3...
Discarding snapshot 3.
transactional-update finished
```

Nothing was staged, so nothing needs activating, and **no reboot is required
before you reinstall**. Exit status 104 is zypper reporting that it had nothing
to do; it is not a failure.

**Read the last few lines rather than assuming which case you are in.**
`Discarding snapshot N` and `New default snapshot is #N` are the two outcomes,
they are unambiguous, and they are the whole difference.

**Some of the confirmations below are only meaningful after a reboot, and only
in the first case.** `rpm -q k3s-selinux` reads *installed* before that reboot
and *not installed* after, from the same correct teardown ... so reading it
early tells you the teardown failed when it did not. Where the RPM was never
installed there is no such window: it reads *not installed* throughout.

**NODE** ... the node you tore down. MicroOS shapes only, and after the reboot
if one was staged.

```bash
sudo btrfs subvolume get-default /
rpm -q k3s-selinux || echo "k3s-selinux not installed: correct"
test -e /usr/local/bin/k3s || echo "k3s binary gone: correct"
test -e /etc/rancher/k3s || echo "/etc/rancher/k3s gone: correct"
test -z "$(ls -A /var/lib/rancher 2>/dev/null)" && echo "/var/lib/rancher empty: correct"
systemctl is-active k3s || echo "unit inactive: correct"
```

The five `test` and `rpm` lines print their `correct` line either way. All five
were observed in that state after the reboot on 2026-09-15, and again on
2026-09-17 on a node that never carried the RPM. A missing `correct` line is the
signal here, the same convention as step 8.

**The first line is the one that differs, and it is not a pass/fail check.**
`btrfs subvolume get-default /` reads as **whichever snapshot the node is
currently running**. Where the uninstaller staged one, that is the number it
named, after you reboot into it. Where it discarded one, it is whatever snapshot
you were already on ... on the 2026-09-17 teardown that was
`@/.snapshots/2/snapshot`, the snapshot
[section 2's package install](../deployment/fresh-install.md#2-install-the-storage-packages-on-every-node)
created. Read it to know where you are, not to decide whether the teardown
worked.

**None of this applies to a conventional distribution**, where the package
removal completes in place and the uninstaller's exit is the end of it.

## What is not certified here

**The sequence steps 1 to 6 describe was executed on a real cluster on
2026-08-18**, and every error message on this page is quoted verbatim from that
run. That is a claim about that run on that cluster, and it is the strongest
claim this page makes.

**It is not a claim that this page has been executed start to finish as
written.** Three things on it have never been run in this form:

- **Step 7b's re-default and step 7c's `.skip` removal.** Both postdate the
  2026-08-18 run and are derived from the k3s addon behaviour measured on
  2026-09-01, not observed during an uninstall.
- **The `--wait=false` and `--ignore-not-found` forms.** They are corrections to
  commands that hung or hid errors on the original page, and they are correct by
  construction rather than by execution.
- **Every conditional branch nobody took.** A cluster without Garage skips step
  3; a cluster whose `tockmox-platform` finished at step 5 skips step 6. Those
  branches are reasoned, not walked.

**Step 9 is transcribed from an execution, not from a run of step 9.** Added at
0.6.1 (TM-0624). The uninstaller's two output lines and all six post-reboot
facts were observed on a real MicroOS node on 2026-09-15, during the rc4
rebuild, and are quoted from that run rather than reconstructed. What was *not*
run is the confirmation block in the form printed above, as a block ... the
facts were checked individually that night. The reason it is written from the
recorded run rather than re-executed is that re-executing it means tearing down
a cluster to re-observe output already written down, which buys nothing the log
does not already carry.

**Step 7f and the derived check in step 8 come from a second run, 2026-09-12**,
on which steps 1 to 7e were followed as written and the page's own confirmation
reported clean while 34 ClusterRoleBindings, 42 ClusterRoles, a CSIDriver, an
IngressClass and a PriorityClass remained. The residue was removed that night
with the derived selector and the sweep re-run to an empty listing before the
next install proceeded. The listing block in 7f was then re-run on 2026-09-13
against a live install and printed 92 tracked objects, so it sees what it
claims to. **The delete loop in 7f, in the form printed on this page, has not
yet been executed end to end on a cluster** ... it is the listing with `xargs
kubectl delete` appended, and it is honest to say that the appended half is
correct by construction until the next uninstall walks it.

Documented procedures are verified by running them, not by reviewing them. The
[testing standard](../testing-standard.md) says which paths are covered and
which are not yet.

**Tockmox did not have this page until 2026-08-18.** Uninstalling had never been
performed end to end, so none of what is above was known. That is the honest
provenance of the whole document, and it is the reason the dated observations
are attributed to a single run rather than to the product.

## History and corrections

What the steps above used to say, and when it changed. Nothing here is needed to finish the page.

<a id="history-step-7f-and-the-derived-check"></a>

### Step 7f and the derived check

Measured 2026-09-12, after steps 1 to 7e had been followed end to end and
the confirmation in step 8 (as it then read) had reported a clean cluster: 34
ClusterRoleBindings, 42 ClusterRoles, the `driver.longhorn.io` CSIDriver, the
`tockmox-platform-traefik` IngressClass still marked default, and the
`longhorn-critical` PriorityClass were all still there, from cert-manager (nine
alone), Longhorn, MetalLB, Traefik, CNPG, Argo Workflows, Authentik, Grafana,
Loki, Prometheus, kube-state-metrics, barman-cloud and snapshot-controller;
some had survived two uninstalls. `helm install` refused to proceed over them
because helm checks ownership metadata, and nothing else in the stack does: a
chart that failed to render a ClusterRole, or rendered one with the wrong
rules, would have installed perfectly over the stale permissive copy, which is
precisely the class of defect a clean reinstall exists to catch. Step 7f and
the derived check in step 8 exist because of that run; the confirmation as it
then read enumerated eight kinds by hand and missed all five (TM-0536).

Found 2026-09-13 by running this page end to end: the sweep ran clean and the
listing block still printed `namespaces news`, because the listing lacked the
`case` line's namespace skip that the sweep already had, so the two blocks
were answering different questions. The `case` line was added to the listing
to match.

## Next

- Reinstalling on this cluster: [installation](../deployment/install.md), after
  step 8 comes back clean
- Removing one application rather than all of Tockmox:
  [day-2 § turn an application off](day-2.md#turn-an-application-off)
- Something above stuck in a way this page does not cover:
  [troubleshooting](troubleshooting.md)

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

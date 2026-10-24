---
okf_version: "0.2"
type: Reference
title: "Troubleshooting"
description: "A symptom index for a running Tockmox cluster: what you see, what causes it, the fix, and how you know the fix worked."
tags: [troubleshooting, symptoms, argocd, admission, storage, namespaces, sso]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Troubleshooting

**This page is an index, not a procedure.** You arrived with a symptom. Find it
in the table, go to that one section, and ignore the rest ... nothing here runs
in order.

Each entry states the case it covers as something you can confirm, the cause in
one paragraph with the full anatomy linked, the fix, and **how you know the fix
worked**. If your symptom is not listed,
[if none of these match](#if-none-of-these-match) is the general route.

## Symptom index

| What you see | Most likely cause | Go to |
|---|---|---|
| A sync error naming a namespace that does not exist | A layer targeted a namespace the policy layer never created | [namespaces "tockmox-x" not found](#namespaces-tockmox-x-not-found) |
| An RBAC error about listing secrets, from a ServiceAccount you did not create | An admission policy denied a `cluster-admin` binding, three layers back | [cannot list resource "secrets" is forbidden](#cannot-list-resource-secrets-is-forbidden) |
| Your own break-glass `cluster-admin` binding is refused | The same guardrail, which is cluster-scoped and outlives its layer | [It also refuses your break-glass ClusterRoleBinding](#it-also-refuses-your-break-glass-clusterrolebinding-including-mid-uninstall) |
| An Application sits `OutOfSync` and does not move | Repository access, a schema failure, or a missing namespace | [Application stuck OutOfSync](#application-stuck-outofsync) |
| A layer's `ComparisonError` names a chart archive it `could not download`, then says `(cached)` | One transient upstream fetch failure, cached, and a revision automated sync will not retry | [An upstream chart download failed once, and the failure is cached](#an-upstream-chart-download-failed-once-and-the-failure-is-cached) |
| You fixed what a sync failed on, everything else converged, and one Application still reads `Failed last sync attempt to [...]` | Automated sync will not retry a revision whose sync failed | [A failed sync stays pinned to its revision](#a-failed-sync-stays-pinned-to-its-revision) |
| A greenfield install stalls with Certificates that never issue | A resource was applied in the same sync as the webhook that validates it | [The first platform sync wedges](#the-first-platform-sync-wedges) |
| The first platform sync retries, and the controller log says `CRD is not established` | A known race on six snapshot CRDs. The assertion is false and it clears itself | [The first platform sync reports CRDs that are established](#the-first-platform-sync-reports-crds-that-are-established) |
| SSO login returns from the provider and dies, while local logins work | The console's own container does not trust your private CA | [SSO login dies at the token step](#sso-login-dies-at-the-token-step-with-a-certificate-verify-failure) |
| PersistentVolumeClaims never leave `Pending` | No default StorageClass, or two of them | [PersistentVolumeClaims stay Pending](#persistentvolumeclaims-stay-pending) |
| A change you made with `kubectl` came back | `selfHeal` did what it is for | [A change I made in the cluster reverted](#a-change-i-made-in-the-cluster-reverted) |
| The layer is healthy and the thing you wanted is absent | It ships off by default | [Everything renders but nothing appears](#everything-renders-but-nothing-appears) |
| A namespace sits in `Terminating` and stays there | A finalizer whose controller is already gone | [A namespace is stuck Terminating](#a-namespace-is-stuck-terminating) |
| Every write to a resource fails with `failed calling webhook` | An orphaned webhook configuration whose Service was deleted with its namespace | [An orphaned admission webhook rejects the write that would free the resource](#an-orphaned-admission-webhook-rejects-the-write-that-would-free-the-resource) |
| A pod or Job of yours is refused with `violates PodSecurity`, or a Deployment sits at zero replicas | The namespace enforces a Pod Security level the pod does not meet | [A pod is refused with violates PodSecurity](#a-pod-is-refused-with-violates-podsecurity) |
| None of the above | Unknown | [If none of these match](#if-none-of-these-match) |

## Before you begin

Every entry below assumes these three. They are worth having in hand rather than
discovering halfway.

| What you need | Why | How to check |
|---|---|---|
| `kubectl` pointed at the failing cluster | Every diagnosis here reads cluster state | `kubectl get nodes` lists your nodes |
| Read access to the `argocd` namespace | Most symptoms are read off an Application's status | `kubectl -n argocd get applications` returns a list rather than `forbidden` |
| Your **site repository**, with push access, exported as `SITE_REPO` | Several fixes below are a values edit, and a values edit only counts once it is pushed | `export SITE_REPO=YOUR_SITE_REPO_PATH`, then `git -C "$SITE_REPO" push --dry-run` succeeds |

**YOU SUPPLY:** your site repository clone path and the failing layer's name,
once each, in the block below. The values files named in the entries are
relative to the first; the Application for a layer is `tockmox-$LAYER`, and the
nine names are in [architecture](../architecture.md#the-nine-layers).

```bash
export SITE_REPO=YOUR_SITE_REPO_PATH
export LAYER=YOUR_FAILING_LAYER_NAME
echo "SITE_REPO: $SITE_REPO   LAYER: $LAYER"
```

Every block below that reads one of these starts with a guard line, so a block
pasted into a shell that has not run this one stops with a message instead of
addressing the wrong layer. A value that belongs to one entry alone ... a chart
name, a namespace, an operator ... is exported by that entry's own first block.

The two commands almost every entry starts from:

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

## `namespaces "tockmox-x" not found`

**You are in this case if** the operation message names a namespace:

```
Running: one or more synchronization tasks completed unsuccessfully,
reason: namespaces "tockmox-monitoring" not found, ...
```

**Cause.** A layer tried to create resources in a namespace that does not exist
yet. `CreateNamespace=true` only creates an Application's *destination*
namespace, not namespaces its resources happen to target. Namespace creation for
the whole product belongs to `tockmox-policy`, at sync wave 1.

**Diagnose:**

```bash
kubectl -n argocd get application tockmox-policy \
  -o jsonpath='{.status.sync.status}{"\n"}'
kubectl get ns -l app.kubernetes.io/part-of=tockmox
```

**Fix**, and which one applies depends on what those two printed:

- **Policy is not `Synced`.** Fix policy first. Nothing downstream can succeed
  until it has run, and the wave ordering that makes that true is in
  [architecture § sync waves](../architecture.md#sync-waves).
- **Policy is `Synced` and the namespace is still missing.** It is not in
  `namespaces.create` in your policy values. Add it, commit, push.

**How you know it worked.** **YOU SUPPLY:** the namespace the error named.

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
export NAMESPACE=YOUR_NAMESPACE_FROM_THE_ERROR
kubectl get ns "$NAMESPACE"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status}{"\n"}'
```

The namespace exists, and the failing layer reaches `Synced` and `Healthy`. A
namespace that exists while the layer stays `OutOfSync` means the sync has not
been retried yet ... force one, per
[day-2 § force a sync now](day-2.md#force-a-sync-now).

> Found on a clean cluster. An existing deployment cannot surface this, because
> the namespaces are already there ... which is why the release gate deploys to
> a fresh cluster.

## `cannot list resource "secrets"` is forbidden

**You are in this case if** the error names a ServiceAccount you never created,
usually `helm-<something>`:

```
Error: list: failed to list: secrets is forbidden:
User "system:serviceaccount:kube-system:helm-argocd" cannot list resource
"secrets" in API group "" in the namespace "argocd"
```

**Cause, and it is three layers from the symptom.** Tockmox ships a
ValidatingAdmissionPolicy, `deny-privileged-rbac`, that denies any
ClusterRoleBinding to `cluster-admin` not on an allowlist. k3s's HelmChart
controller creates exactly such a binding, named `helm-<chart>`. The binding is
denied silently, the ServiceAccount gets no permissions, and the failure
surfaces later as an unrelated RBAC error. **Nothing in the message mentions the
policy.** That is a known ergonomics defect; why the policy is kept anyway is in
[architecture § the cluster-admin guardrail denies without saying so](../architecture.md#the-cluster-admin-guardrail-denies-without-saying-so).

**Diagnose.** A binding that is missing is a binding that was denied: admission
refused it, so it was never created and nothing deleted it afterwards.

```bash
export CHART=YOUR_CHART_FROM_THE_ERROR
kubectl get clusterrolebinding "helm-$CHART"
kubectl get validatingadmissionpolicy deny-privileged-rbac
```

The binding absent **and** the policy present is the confirmation. **YOU
SUPPLY:** `CHART`, which is the second half of the ServiceAccount name in your
error message.

**Fix.** Add the binding name to the allowlist, deliberately, then commit and
push:

```yaml
# site/values/policy.yaml, in your site repository
rbacGuardrails:
  clusterAdminAllowlist:
    - cluster-admin
    - longhorn-support-bundle
    - helm-argocd
```

Adding a name here grants cluster-admin. Add the one name from your error, not a
pattern, and not a list copied from somewhere else.

**How you know it worked:**

```bash
: "${CHART:?export CHART first, see the diagnose block above}"
kubectl get clusterrolebinding "helm-$CHART"
```

The binding now exists. **The original operation has to be retried**, because
admission denied it once and nothing re-attempts on its own: re-run whatever
produced the error and confirm it no longer reports `forbidden`.

### It also refuses your break-glass ClusterRoleBinding, including mid-uninstall

The four RBAC guardrail policies are **cluster-scoped**, so they outlive the
`tockmox-policy` layer that installed them and go on acting after that layer is
gone. On a stock install `deny-privileged-rbac` is the one of the four set to
refuse rather than audit ([uninstall § 7d](uninstall.md#7d-tockmoxs-rbac-admission-guardrails)
has the table and how to read it off a live cluster). Minting a throwaway
cluster-admin binding to unstick something is exactly the move it exists to
refuse, and it refuses it. Observed 2026-08-18, during an uninstall:

```
ValidatingAdmissionPolicy 'deny-privileged-rbac' with binding 'deny-privileged-rbac'
denied request: ClusterRoleBinding 'nsfix-admin' grants cluster-admin and is not in
rbacGuardrails.clusterAdminAllowlist.
```

That is the guardrail working correctly, and it is worth knowing in advance that
the obvious break-glass move is refused by the product you may be in the middle
of removing. Allowlist the binding, as above, or remove the policy deliberately
and last: [uninstalling](uninstall.md#7-sweep-the-cluster-scoped-leftovers).

**How you know it worked:** `kubectl auth can-i '*' '*' --as=<THE_SUBJECT>`
answers `yes` for the subject you bound. If the binding was refused, that command
answers `no` and the ClusterRoleBinding is absent from `kubectl get
clusterrolebinding`.

## Application stuck `OutOfSync`

**You are in this case if** the Application has not moved for longer than your
reconciliation interval. Run the two commands from
[before you begin](#before-you-begin) first ... the message is the whole
diagnosis here.

| Message contains | Meaning | Where the fix is |
|---|---|---|
| `ComparisonError` naming `source 1 of 2` and `helm dependency build` or `could not download https://...` | An upstream chart fetch failed **once** while the repo-server built the layer's dependencies, and ArgoCD is now serving the cached failure | [An upstream chart download failed once, and the failure is cached](#an-upstream-chart-download-failed-once-and-the-failure-is-cached) |
| `ComparisonError` naming `authentication required` or `repository not found` | ArgoCD cannot reach or authenticate to a repository | [ArgoCD § a missing repository credential names nothing useful](../administration/argocd.md#a-missing-repository-credential-names-nothing-useful) |
| `rpc error ... repository not found` | Site repository URL wrong, or still `PLACEHOLDER_SITE_REPO_URL` | The `repoURL` in your Applications, and the page above |
| `values don't meet the specifications of the schema` | A required value is missing or the wrong type | [configuration](../administration/configuration.md) |
| `namespaces "x" not found` | A namespace the policy layer did not create | [namespaces "tockmox-x" not found](#namespaces-tockmox-x-not-found) |
| `Failed last sync attempt to [...]`, as a `SyncError` condition | The last sync of this revision failed, and automated sync will not try it again | [A failed sync stays pinned to its revision](#a-failed-sync-stays-pinned-to-its-revision) |
| The operation phase is `Running` and stays there | The sync itself is wedged | [The first platform sync wedges](#the-first-platform-sync-wedges) |

**Conditional, and worth ruling out before assuming a defect:** if your push
touched more than one layer, a layer can be legitimately behind rather than
stuck. Test it with
[day-2 § check which revision each layer is running](day-2.md#check-which-revision-each-layer-is-running).

**How you know it worked**, whichever row applied:

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status}{"\n"}'
```

`SYNC=Synced HEALTH=Healthy`. `Synced` on its own is not enough here: a layer
can apply cleanly and still hold a workload that never becomes ready.

## An upstream chart download failed once, and the failure is cached

**You are in this case if** a layer reports `ComparisonError` whose message
names `source 1 of 2`, `helm dependency build` and a URL it `could not
download` ... an upstream chart archive on GitHub releases or a chart
repository ... and, after the retries run out, the same message with
`Manifest generation error (cached)` in front of it. Health can still read
`Healthy` for a layer that was already running.

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

**Cause.** Every layer's chart declares upstream dependencies, and the
repo-server fetches them from the internet on every fresh manifest generation.
One transient failure there ... a `504 Gateway Time-out` from GitHub, measured
on a greenfield install 2026-09-14, lasting longer than the sync's retry window
... does three things in sequence: the sync operation fails after its retries,
ArgoCD **caches the generation error** and serves it on every later comparison
without fetching again, and automated sync **will not retry a revision whose
sync failed**. So the layer stays wedged after the upstream has long recovered.
That last step is not specific to chart downloads:
[a failed sync stays pinned to its revision](#a-failed-sync-stays-pinned-to-its-revision)
whatever it failed on.
Nothing about the site or the charts is wrong, and the credential page the
generic `ComparisonError` row points at does not apply: the message names
`source 1 of 2`, which is the Tockmox repository, and the URL it names is a
chart archive, not a git remote.

**Fix.** Two steps, in this order. First clear the cached error with a hard
refresh, which makes the repo-server fetch again:

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd annotate application "tockmox-$LAYER" \
  argocd.argoproj.io/refresh=hard --overwrite
```

Wait until the `ComparisonError` condition is gone from the read above (about
a minute; the annotation is removed once consumed). Then start one manual sync,
because the automated one will not retry this revision:

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd patch application "tockmox-$LAYER" --type merge \
  -p '{"operation":{"initiatedBy":{"username":"operator"},"sync":{}}}'
```

**How you know it worked:**

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status} OP={.status.operationState.phase}{"\n"}'
```

`SYNC=Synced`, and `OP` moves from `Running` to `Succeeded`. Measured: the
patch above took the platform layer from `OutOfSync` to `Synced` within a
minute of the refresh, on the same revision that had failed five times.

**If the refresh brings the same error back**, the upstream is still down or
unreachable from your cluster, and the fix is not here: test the URL the
message names from inside the cluster, and read
[install with no internet access](../deployment/airgap.md) if it is your
boundary rather than their outage.

## A failed sync stays pinned to its revision

**You are in this case if** you fixed what a sync failed on, the other
Applications converged, and one Application stays exactly where it was, with a
`SyncError` condition that starts `Failed last sync attempt to [<commit>]`. The
application-controller log names it for that Application:

```
Skipping auto-sync: failed previous sync attempt to [02feeea] and will not retry for [02feeea]
```

**YOU SUPPLY:** the Application's name. For a layer it is `tockmox-$LAYER`; the
site repository's own are `site-secrets` and `site-apps`.

```bash
export APP=YOUR_APPLICATION_NAME
kubectl -n argocd get application "$APP" \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
kubectl -n argocd logs sts/argocd-application-controller \
  | grep 'will not retry' | grep -F "$APP" | tail -n 3
```

The first command prints the `SyncError` condition. The second prints the log
line, if the log has not rolled past it.

**Cause.** Automated sync makes one attempt per combination of commit and
parameters, and does not attempt a sync again when the previous attempt against
the same commit failed
([Argo CD, automated sync policy](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)).
The attempt includes its own retries, so `retried 5 times` in the message is
that one attempt running out. Fixing the cause changes the cluster, not the
revision, and a refresh or a hard refresh re-compares without starting a sync.
**So an operator who fixes the cause and watches the board sees no change and
concludes the fix did not work.** The measured case: `site-secrets` failed on
`namespaces "tockmox-devops" not found`, because a missing repository
credential had stopped the layers that create those namespaces. Supplying the
credential converged every layer within one refresh cycle and left
`site-secrets` where it was.

**Fix.** Fix the cause first, then use one of these two. Either one starts a
new attempt.

- **A new commit.** Automated sync treats a new commit as a new attempt. Every
  Application the installer generates sources your site repository, so a commit
  there is seen within one polling interval. An empty commit is enough, unless
  the Application sets the `argocd.argoproj.io/manifest-generate-paths`
  annotation; the generated ones do not.

  ```bash
  : "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
  git -C "$SITE_REPO" commit --allow-empty -m "retry a failed sync" && git -C "$SITE_REPO" push
  ```

- **One manual sync** of that Application. It starts immediately and leaves no
  commit behind. With the `argocd` CLI: `argocd app sync "$APP"`.

  ```bash
  : "${APP:?export APP first, see the first block of this entry}"
  kubectl -n argocd patch application "$APP" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"operator"},"sync":{}}}'
  ```

> **For `site-secrets`, a manual sync gives up the wave-1 ordering.**
> `site-secrets` syncs at wave 1 so that credentials land before the workloads
> that mount them, and
> [install 3b](../deployment/install.md#3b-confirm-your-sealed-secrets-landed)
> rests on that. A hand-synced `site-secrets` delivers after those workloads
> have started, and they pass through `CreateContainerConfigError` until it
> lands. Which consumers wait and which start without their Secret is in
> [Secrets § until they exist](../administration/secrets.md#until-they-exist).
> A new commit does not restore the ordering either, because the workloads are
> already running by then. If the install exists to demonstrate the ordering,
> as a release gate does, roll back and re-run on a clean cluster instead.

**How you know it worked:**

```bash
: "${APP:?export APP first, see the first block of this entry}"
kubectl -n argocd get application "$APP" \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status} OP={.status.operationState.phase}{"\n"}'
```

`SYNC=Synced`, `OP=Succeeded`, and the first block of this entry no longer
prints a `SyncError` condition.

## The first platform sync wedges

**Fixed as of 0.5.0**, whose release-gate install converged with no
intervention: every cert-manager.io resource the platform layer ships now
applies at a later sync wave than the webhook that validates it. **This entry
stays because the failure shape is general** ... any resource applied in the same
sync as its own admission webhook can hit it, including workloads you add
yourself ... and because the recovery is not obvious.

> **Not this one if your controller log says `CRD is not established`.** That is
> a different failure with a different remedy, and the remedy here ... terminate
> and resync ... does not apply to it. See
> [the first platform sync reports CRDs that are established](#the-first-platform-sync-reports-crds-that-are-established).

**You are in this case if**, on a greenfield install, an Application sits
`OutOfSync / Progressing` while a webhook-validated resource it names does not
exist in the cluster at all:

```bash
kubectl -n argocd get application tockmox-platform \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl get certificates -A
kubectl get issuers,clusterissuers -A
```

Typically: Certificates that never issue, while an Issuer or another
webhook-validated resource shows `OutOfSync` and does not exist in the cluster.

**Cause.** The resource was applied while the webhook that validates it was still
starting in the same sync. The apply is rejected, downstream health can then
never arrive, and automated sync will not retry a revision whose sync failed, so
it does not self-heal out of this one. The mechanism, and how to keep resources
of your own out of it, is in
[ArgoCD § a resource applied in the same sync as its own admission webhook](../administration/argocd.md#a-resource-applied-in-the-same-sync-as-its-own-admission-webhook).

**Fix.** Terminate the stuck operation and start one manual sync. The webhooks
are up by then, everything applies, and the layer converges with no further
attention. Terminate first:

```bash
kubectl -n argocd patch application tockmox-platform --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'
```

**Wait for the operation to report `Failed`, then start the sync.** The two are
separate blocks rather than one, because the second has nothing to act on until
the first has finished unwinding.

```bash
kubectl -n argocd patch application tockmox-platform --type merge \
  -p '{"operation":{"initiatedBy":{"username":"operator"},"sync":{"prune":true}}}'
```

With the `argocd` CLI: `argocd app terminate-op tockmox-platform`, then
`argocd app sync tockmox-platform`.

**How you know it worked:**

```bash
kubectl -n argocd get application tockmox-platform \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status}{"\n"}'
kubectl get clusterissuers
kubectl get certificates -A
```

`SYNC=Synced HEALTH=Healthy`, and the resource that was missing now exists.
**A resource that is present but not ready is a different problem** ... this fix
is complete when the previously absent object has been created, because the
wedge is about it never reaching the cluster at all.

## The first platform sync reports CRDs that are established

**This is a known open defect and it has not been diagnosed.** What follows is
what has been measured, and the most useful thing on this page is the last
sentence of the fix: wait.

**You are in this case if** the platform layer's first sync retries and the
application-controller log carries `CRD is not established` against any of these
six:

```
volumesnapshots.snapshot.storage.k8s.io
volumesnapshotcontents.snapshot.storage.k8s.io
volumesnapshotclasses.snapshot.storage.k8s.io
volumegroupsnapshots.groupsnapshot.storage.k8s.io
volumegroupsnapshotcontents.groupsnapshot.storage.k8s.io
volumegroupsnapshotclasses.groupsnapshot.storage.k8s.io
```

**The assertion is false, and that is measured rather than suspected.** Read the
CRDs live at the moment the log says otherwise and every one reports
`Established: True`. On a reference install the transition was stamped **one
second** after the CRD was created, `reason: InitialNamesAccepted`, no naming
conflict and no second owner. The controller sampled inside that window and
carried the sample forward. **The CRDs are not slow. The health check saw them
before they existed and did not look again.**

**What it costs while it lasts.** ArgoCD does not advance past a sync wave whose
tasks failed, so everything the platform layer applies at wave 3 or later waits:
the `tockmox-ca` ClusterIssuer and its Certificate, the barman-cloud plugin set,
the Longhorn VolumeSnapshotClass, the MetalLB address pool and L2Advertisement,
and the Traefik Service. The layer reads `OutOfSync` or `Progressing` and those
objects are simply absent.

**Diagnose ... and the object will not tell you.** A succeeded operation
overwrites the failing attempt's `syncResult` in place, so once the layer goes
green the Application reads clean and the string appears nowhere in it. The
controller log is the only surface that carries this:

```bash
kubectl -n argocd logs sts/argocd-application-controller \
  | grep -c 'CRD is not established'
```

The controller is a **StatefulSet**; `deploy/` returns NotFound. The log also
rolls, so on a busy cluster the lines may already be gone.

**Fix: wait.** Every install measured since 2026-09-11 has cleared this by
itself, with no operator action, in a single sync operation. Do **not** terminate
the operation. The terminate-and-resync in
[the entry above](#the-first-platform-sync-wedges) is the remedy for the
admission-webhook wedge and is not a remedy for this one ... on the one occasion
it was applied here it left no trace in the object and the operation appears to
have finished on its own regardless.

**If it does not clear**, you are in the shape this defect was first found in:
one install, on 2026-09-10, retried for eighteen minutes and stranded those
objects until a later sync applied them. That is one occurrence against every
subsequent run self-clearing, and the difference has not been explained.
Capture the controller log and
[open an issue](https://github.com/tockmox/tockmox/issues) with it ... a capture
of a run that did **not** clear is the single most useful thing anyone can send
about this.

### What is not certified here

**The mechanism is unknown.** Render instability and CRD object size were both
checked and ruled out by measurement. Why the sample is taken inside the
establishment window, and why some runs retry far more than others, is not
established, and this page deliberately does not guess. Nothing here should be
read as a bound on how long it takes or how often it happens: the occurrence
counts measured on self-clearing runs ranged from 15 to 28 within a single
operation, across four installs.

## SSO login dies at the token step with a certificate verify failure

**You are in this case if** federated login fails while local break-glass
accounts still work:

```
URLError [SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate
```

**Cause.** `global.certIssuer` is set, so the consoles are on HTTPS behind a
private CA, and the container performing the OIDC token exchange does not trust
that CA. Grafana, Open WebUI and the Argo Workflows server each do that exchange
**server side**, from inside their own container, so a browser that trusts the
CA changes nothing for them.

**The tell that sends people the wrong way.** Local break-glass accounts keep
working throughout, so every console reports healthy and only federated users
are locked out. Login gets as far as the provider, comes back, and dies at the
token step.

**Diagnose:**

```bash
kubectl -n tockmox-monitoring get deployment tockmox-observability-grafana \
  -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="SSL_CERT_FILE")]}{.value}{"\n"}{end}'
kubectl -n tockmox-ai get statefulset tockmox-ai-open-webui \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'
```

The first prints `/etc/tockmox/ca/ca.crt`; the second includes
`tockmox-trust-bundle`. An empty result from either is the fault.

**Fix.** The shipped charts wire this by default, so an empty result means a
site override replaced a list-valued subchart key rather than adding to it.
Restore the key and let the render-time preflight confirm it:
[TLS and trust ... trust inside the cluster](../administration/tls-and-trust.md#trust-inside-the-cluster).

**How you know it worked:** re-run both diagnose commands and get the two
expected values, **and** complete one federated login to each console. The
config check alone is not the test ... it proves the CA is mounted, not that the
token exchange now verifies.

**Conditional follow-up. Run this if** your fix also changed `sso.clientId`,
`sso.adminGroup` or `sso.userGroup`: those do not roll the pods on their own, so
the consoles keep the old value until you restart them. See
[day-2 § restart the consoles after an SSO change](day-2.md#restart-the-consoles-after-an-sso-change).

## PersistentVolumeClaims stay `Pending`

**You are in this case if** claims are pending and the StorageClass list explains
why:

```bash
kubectl get pvc -A | grep Pending
kubectl get storageclass
```

**Cause.** Almost always the cluster has no **default StorageClass**, or it has
two, in which case which one wins is decided by creation timestamp rather than by
anything you configured. Keep exactly one. The installer warns about both; a
cluster that gained Tockmox some other way will not have been warned.

**A stock install does not produce two defaults.** Tockmox names the class on
every claim it creates and does not mark a cluster default, so if you are seeing
two, either your cluster already had one and something else added a second, or
this site sets `longhorn.persistence.defaultClass: true`. In that second case it
is a recurring condition rather than a one-time mistake, because k3s re-asserts
its own `local-path` default on restart. The measurement, the durable fix, and
the three alternatives that lose are in
[storage § if you DO want Longhorn as your cluster default](../administration/storage.md#if-you-do-want-longhorn-as-your-cluster-default).

**Fix.** Get to exactly one default, per that page. Nothing needs deleting
afterwards ... a claim binds as soon as a class can satisfy it.

**How you know it worked:**

```bash
kubectl get storageclass
kubectl get pvc -A | grep Pending || echo "no pending claims: correct"
```

Exactly one class marked `(default)` and it is the one you meant, and no claim
left pending. Re-run the check after any k3s restart, per
[storage § check what you actually ended up with](../administration/storage.md#check-what-you-actually-ended-up-with),
until the durable fix is in place.

## A change I made in the cluster reverted

**You are in this case if** you edited a live object and it came back. Working
as designed: ArgoCD's `selfHeal` reverts manual edits.

**Fix.** Make the change in your site repository instead ...
[day-2 § change a configuration value](day-2.md#change-a-configuration-value).
How much you are allowed to change, and by which rung, is
[customising](../administration/customising.md).

**How you know it worked:** force a sync, then re-read the object. Surviving one
reconciliation is the test, because a change that lasts only until the next one
has not been made.

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd patch application "tockmox-$LAYER" \
  --type merge -p '{"operation":{"sync":{}}}'
```

Then re-read the object you changed.

**The two exceptions**, which you do edit by hand and which nothing puts back:
your ArgoCD install, and the operator-created Secrets. See
[architecture § why an edit made in the cluster does not stick](../architecture.md#why-an-edit-made-in-the-cluster-does-not-stick).

## Everything renders but nothing appears

**You are in this case if** the layer is healthy and the thing you expected is
not in its resource list:

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\n"}{end}'
```

**Cause.** Several applications ship off by default, deliberately:

| Off by default | Why |
|---|---|
| A registry | Not shipped as of 0.1.0. A prerequisite rather than a component; see [registry](../deployment/registry.md) |
| Ollama | Pulling multi-gigabyte model images during a first install, unasked, is rude |
| SNMP exporter | Useless without your device list |
| smartctl exporter | Meaningless on virtual or cloud disks |

That is not the whole list. The `tockmox-devops` layer, the LiteLLM model
gateway, and four NetworkPolicy bundles that would guard nothing on a stock
install are also off. The complete set, with the reasoning, is in
[architecture § deliberately not shipped, deliberately off](../architecture.md#deliberately-not-shipped-deliberately-off).

**Fix.** Turn it on in your site repository, then commit and push:

```yaml
# site/values/exporters.yaml, in your site repository
apps:
  snmp:
    enabled: true
```

**How you know it worked.** **YOU SUPPLY:** the name of the thing you enabled,
which is the key you set `enabled: true` on.

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
export ENABLED_THING=YOUR_ENABLED_APP_NAME
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\n"}{end}' \
  | grep -i "$ENABLED_THING"
```

The resource list now names it, and the layer is `Synced` and `Healthy`. **The
resource list is the test, not `kubectl get`** ... a workload can exist from an
earlier install while the layer has stopped rendering it.

## A namespace is stuck `Terminating`

**You are in this case if** a namespace has been `Terminating` for longer than a
minute. Ask the namespace rather than guessing ... it names the exact resource
type and the exact finalizer. **YOU SUPPLY:** the stuck namespace.

```bash
export NAMESPACE=YOUR_STUCK_NAMESPACE
kubectl get ns "$NAMESPACE" -o jsonpath='{.status.conditions}' | jq
```

Two conditions carry the answer. `NamespaceContentRemaining` names what is
left; `NamespaceFinalizersRemaining` names the finalizer holding it. A real
example, after the CloudNativePG operator had already been deleted:

```
NamespaceContentRemaining:    "Some resources are remaining: services. has 1 resource instances"
NamespaceFinalizersRemaining: "Some content in the namespace has finalizers remaining:
                               cnpg.io/cleanupPlugin in 1 resource instances"
```

**Cause.** The shape is almost always the same: a controller owns a finalizer,
the controller was deleted first, and nothing is left to remove it.

**Read the conditions rather than working through candidates.** They name the
resource type and the exact finalizer every time. On the 2026-08-18 run they
were right after three successive guesses about the cause had been wrong, which
is the whole argument for asking the object instead of reasoning about it.

**One blocker is not in the namespace you are looking at.** Also on 2026-08-18,
four namespaces sat `Terminating` indefinitely on two PersistentVolumeClaims
belonging to Garage, in `tockmox-platform`. All four released within ninety
seconds of those two PVCs going. A namespace whose volumes are provisioned by a
CSI driver living somewhere else cannot finish until that driver can detach
them, so the namespace holding the storage layer is the last one to delete, not
the first.

**Fix, and the order matters.** Clearing the finalizer is a one-line patch, but
**check the webhook first**. **YOU SUPPLY:** the operator named by the finalizer
the conditions printed above.

```bash
export OPERATOR=YOUR_OPERATOR_NAME
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o name | grep -i "$OPERATOR"
```

If the resource belongs to an operator whose admission webhook Service is also
gone, the patch itself will be rejected, and you have to delete the orphaned
webhook configuration before anything else will work ... which is
[the next entry](#an-orphaned-admission-webhook-rejects-the-write-that-would-free-the-resource).

Full sequence, including the Longhorn and CNPG cases and the cluster-scoped
leftovers that break the next install: [uninstalling](uninstall.md).

**How you know it worked:**

```bash
: "${NAMESPACE:?export NAMESPACE first, see the first block in this entry}"
kubectl get ns "$NAMESPACE" || echo "namespace gone: correct"
```

The namespace is absent. **A namespace that is gone while its cluster-scoped
leftovers remain is only half done** ... CRDs, webhook configurations and
ClusterRoles outlive the namespace and break the next install.
[Uninstalling § sweep the cluster-scoped leftovers](uninstall.md#7-sweep-the-cluster-scoped-leftovers)
is the list to clear.

## An orphaned admission webhook rejects the write that would free the resource

**This is a closed loop, and it reads as a Longhorn problem when it is a webhook
lifecycle problem.** It is the trap behind most namespaces that will not finish.

**You are in this case if** a write fails naming a webhook whose Service does not
exist:

```
Internal error occurred: failed calling webhook "mutator.longhorn.io":
failed to call webhook: Post "https://longhorn-admission-webhook.tockmox-platform.svc:9502/...":
service "longhorn-admission-webhook" not found
```

**Cause.** An operator's `MutatingWebhookConfiguration` and
`ValidatingWebhookConfiguration` are **cluster-scoped**. The Service they point
at is **namespaced**. Delete the namespace and the Service goes while the
configurations stay, after which every write to every resource they intercept
fails. Observed 2026-08-18, after `tockmox-platform` was deleted.

That includes the write that clears the finalizer that is blocking the deletion.
You cannot finish the delete without patching the resource, and you cannot patch
the resource until the webhook configurations are gone.

**Fix: delete the webhook configurations first, then clear the finalizers.**
Doing it the other way round is what produces the loop:

```bash
kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator
```

The finalizers left behind then have to be cleared by hand, because the
controller that would normally remove them has already been deleted and nothing
else will. Observed still holding finalizers at that point: the `Node`, the
`BackupTarget`, the `EngineImage`, `Volume`s, and
`volumeattachments.longhorn.io`. Range the whole API group rather than naming
them, since the list is a snapshot of one run:

```bash
for kind in $(kubectl api-resources --api-group=longhorn.io -o name); do
  for n in $(kubectl -n tockmox-platform get "$kind" -o name 2>/dev/null); do
    kubectl -n tockmox-platform patch "$n" --type=merge \
      -p '{"metadata":{"finalizers":null}}'
  done
done
```

> The same two deletes and the same loop appear in sequence at
> [uninstalling § step 5](uninstall.md#5-delete-longhorns-webhook-configurations-then-its-finalizers),
> because a reader partway through an uninstall must not have to leave the page
> to finish it. They are a pair: change one and change the other.

**The knock-on to expect.** Once the Volume finalizers are gone, any pod that
still had a Longhorn volume mounted can wedge `Terminating` forever, because the
kubelet is waiting for an unmount confirmation from a CSI plugin that has just
been dismantled. The namespace then reports pods as its only remaining content.
Force-delete them; there is nothing left to shut down cleanly.

**How you know it worked:**

```bash
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration \
  -o name | grep -i longhorn || echo "no longhorn webhooks left: correct"
kubectl -n tockmox-platform get all 2>/dev/null || echo "namespace gone: correct"
```

Neither webhook configuration remains, and the write that was failing now
succeeds. **The webhook delete is not the finish line** ... the finalizers it
unblocked still have to be cleared, and the namespace is only done when it is
absent.

## A pod is refused with `violates PodSecurity`

**The case.** From 0.7.0 the `tockmox-authentik`, `tockmox-selfcheck`,
`tockmox-devops`, `tockmox-diagnostic` and `tockmox-ai` namespaces carry a
`pod-security.kubernetes.io/enforce` label. A pod that fails that level is
refused at creation. If you create it directly you get the error at once; if a
Deployment or Job creates it, the Deployment sits at zero replicas and the
reason is in the ReplicaSet or Job events, not on the Deployment.

```bash
: "${NS:?export NS first, the namespace the pod should run in}"
kubectl get namespace "$NS" -o jsonpath='{.metadata.labels}{"\n"}'
kubectl -n "$NS" get events --field-selector reason=FailedCreate
```

The first command shows the `enforce` level. The second shows the refusal,
which reads like `violates PodSecurity "baseline:latest": privileged`. It names
the fields, so the message is the diagnosis.

**Cause.** The label is doing what it is for. `baseline` refuses privileged
containers, host namespaces, `hostPath` volumes and added capabilities outside a
short list. `restricted` additionally requires `runAsNonRoot`, no privilege
escalation, all capabilities dropped and a seccomp profile. Anything running
before the upgrade keeps running; the refusal lands on the next restart, rollout
or scale-up, which can be days later.

**Fix, in order of preference.** Make the pod meet the level, using the fields
the error names. If it cannot, lower that one namespace deliberately in your
site repository, then commit and push:

```yaml
# site/values/policy.yaml, in your site repository
podSecurity:
  enforce:
    devops: ""        # no enforce label; warn and audit stay at restricted
```

The keys are the ones under `namespaces` in the policy layer (`ai`, `authentik`,
`devops`, `diagnostic_identity`, `selfcheck`), not the namespace names. An empty
string removes the label; `baseline` keeps the milder refusal. Do not lower
`authentik` to admit a pod of yours: put your pod in a namespace of its own.

**How you know it worked:**

```bash
: "${NS:?export NS first, the namespace the pod should run in}"
kubectl get namespace "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}'
```

prints the level you chose, or nothing for an empty string, and the pod is then
created. **Not proven here:** that a violating pod is refused on a live
cluster. The rendered labels and the measured levels are gated
([architecture § Pod Security](../architecture.md#pod-security-which-namespaces-refuse-a-pod-and-why-the-others-cannot));
the admission itself has not been observed.

## If none of these match

In this order, because each step narrows what the next one has to consider:

1. **Read the Application, not the pods.** The two commands in
   [before you begin](#before-you-begin) say whether this is a GitOps problem or
   a workload problem. They are different investigations, and starting in the
   wrong one costs the most time.
2. **Confirm the layer is on the commit you think it is**, with
   [day-2 § check which revision each layer is running](day-2.md#check-which-revision-each-layer-is-running).
   A layer running last week's values explains a great many symptoms.
3. **Read the events in the failing namespace.** They name admission denials and
   scheduling failures that no Application status carries:
   `kubectl -n <NAMESPACE> get events --sort-by=.lastTimestamp | tail -30`.
4. **Check whether monitoring already knows.** The platform and observability
   layers ship alerts on storage robustness and on the monitoring stack's own
   liveness, so the answer may already be on a dashboard. See
   [monitoring](monitoring.md).
5. **Then** [get help](#getting-help), with the output of steps 1 and 3.

## Getting help

- [Open an issue](https://github.com/tockmox/tockmox/issues). Include the output
  of both commands in [before you begin](#before-you-begin), your Tockmox
  version, and which entries above you already ruled out
- [SUPPORT.md](../../SUPPORT.md) for what to expect
- Security issues: [SECURITY.md](../../SECURITY.md), never a public issue

**Redact before you paste.** An Application status can carry your site
repository URL, and events can carry hostnames from your `internalDomain`.

## What is not certified here

**Reading this page does not establish that any fix on it works.** A documented
procedure is verified by running it ... see the
[testing standard](../testing-standard.md) for which paths are covered and which
are not yet.

What each entry rests on differs, and the difference matters when a fix does not
behave as described:

| Entry | What it rests on |
|---|---|
| [namespaces "tockmox-x" not found](#namespaces-tockmox-x-not-found) | Found on a clean cluster, as the note in that section records. An existing deployment cannot surface it |
| [The first platform sync wedges](#the-first-platform-sync-wedges) | The 0.5.0 release-gate install, which converged with no intervention. The recovery commands come from the runs that needed them |
| [PersistentVolumeClaims stay Pending](#persistentvolumeclaims-stay-pending) | The k3s restart behaviour was measured 2026-09-01 on `v1.36.4+k3s1`; see [storage § the patch does not survive a k3s restart](../administration/storage.md#the-patch-does-not-survive-a-k3s-restart) |
| The break-glass refusal, the namespace-Terminating notes, and the orphaned-webhook loop | An uninstall run on 2026-08-18. The transcripts quoted are from that run; the commands have not been re-executed since |
| [A pod is refused with violates PodSecurity](#a-pod-is-refused-with-violates-podsecurity) | The enforce levels are gated against a render of every shipped pod. The refusal itself and the escape edit have not been run on a cluster |
| Every other entry | Read from the charts and from recorded incidents in this tree. The causes trace to shipped resources; the fixes have not each been re-executed for this page |

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

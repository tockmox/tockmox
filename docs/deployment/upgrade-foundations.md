---
okf_version: "0.2"
type: HowTo
title: "Upgrade ArgoCD and k3s"
description: "Upgrade the two things Tockmox runs on and does not ship: ArgoCD, connected and air-gapped, and k3s itself. Who does it, in what order relative to a Tockmox revision bump, and the version range the repository records."
tags: [upgrade, argocd, k3s, airgap, prerequisites, system-upgrade-controller]
status: stable
generated:
  by: hand
  at: 2026-10-10
tockmox:
  classification: public
  audience: [operator]
---

# Upgrade ArgoCD and k3s

**Two things sit under every layer, and Tockmox ships neither.** ArgoCD applies
all nine layers. k3s is the cluster they run on. You installed both before
Tockmox existed on the cluster ([prepare a fresh cluster](fresh-install.md)), you
own both, and
[upgrading to a new release](upgrade.md) does not touch either. This page is the
other half: when and how to move them.

**You do these upgrades, not Tockmox.** ArgoCD must not manage itself
([ArgoCD § why it is a prerequisite](../administration/argocd.md#why-it-is-a-prerequisite)),
and no Tockmox chart renders a k3s or ArgoCD upgrade. Nothing here changes on
its own schedule. Whoever owns the cluster owns the calendar.

**What has been run.** The connected Helm route for ArgoCD (sections 1 to 4)
was executed as printed on 2026-10-10 against a single-node lab cluster running
all nine layers: argo-cd chart 10.9.1 (ArgoCD v3.5.3) to 10.10.2 (v3.5.4), every
layer's revision unchanged and `Synced`/`Healthy` afterwards. The air-gapped
route, the raw-manifest route and the k3s procedure have not been executed; see
[what is not certified here](#what-is-not-certified-here).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| The cluster `Synced` and `Healthy` first | Upgrading a red cluster means you cannot tell the upgrade from the fault that was already there | [Upgrade step 0](upgrade.md#0-write-down-what-you-are-on-now) prints every layer's revision and status; all rows `Synced` and `Healthy` |
| Helm 3.14 or newer (Helm 4 also works) | The ArgoCD upgrade below uses `--reset-then-reuse-values`, which arrived in 3.14 | `helm version` |
| For ArgoCD: the install route you used | The Helm route and the raw-manifest route upgrade differently | `helm --kube-context="$KUBE_CONTEXT" -n argocd list` lists a release named `argocd` if you used Helm, and prints nothing if you did not |
| For k3s: a login on every node, and a window | A k3s upgrade restarts the API server on each server node in turn | You can `ssh` to each node and `sudo` |
| About an hour for ArgoCD, and an hour per node for k3s | Most of it is waiting for rollouts | |

## Where each command runs

| Marked | Runs on |
|---|---|
| **WORKSTATION** | Your own machine, against the cluster's kubeconfig. Needs `KUBE_CONTEXT` exported |
| **NODE** | A cluster node, over SSH, with `sudo` |
| **CONNECTED** | A machine outside the air-gap boundary with internet access. Never a cluster node |
| **WORKSTATION ... INSIDE THE BOUNDARY** | Your workstation, with the uplink cut if you can |

Export the context once for every **WORKSTATION** block below:

**WORKSTATION**

```bash
export KUBE_CONTEXT=YOUR_KUBE_CONTEXT
kubectl --context="$KUBE_CONTEXT" get nodes
```

**Success condition:** the nodes list prints and every node reports `Ready`.

## Order relative to a Tockmox revision bump

**Do ArgoCD first, as its own change, and let the cluster settle before you move
`targetRevision`.** k3s is independent of the bump and follows its own rules
([below](#upgrade-k3s)); never in the same window as either of the others.

| Situation | Order |
|---|---|
| The release you are moving to raises the ArgoCD floor, or its release notes name an ArgoCD version | ArgoCD first. The bump is not optional until it is done |
| Your ArgoCD is older than the floor in [the version table](#the-version-range-this-repository-records) | ArgoCD first, and stop here. The generated Applications cannot be parsed below the floor |
| Your ArgoCD is at or above the floor and the release says nothing about it | Either order works. Prefer ArgoCD first, on a calm day, and the bump after it |
| A Tockmox bump is half done (layers on mixed revisions) | Finish it or [roll it back](upgrade.md#roll-back) first. Do not start an ArgoCD upgrade on top of it |

**Why ArgoCD goes first.** Three reasons, none of them about convenience:

1. **The bump is carried out by ArgoCD.** Changing `targetRevision` hands the
   reconciler a different set of manifests for every layer at once, and
   `prune: true` deletes what the new release stops declaring
   ([upgrade](upgrade.md)). You want the thing doing that work known-good before
   it does it, not changed in the same hour.
2. **The rollback also runs through ArgoCD.** Rolling back a bad release is a
   revision edit that ArgoCD then applies
   ([upgrade § roll back](upgrade.md#roll-back)). If ArgoCD is the thing that
   just changed, a failed release leaves you unsure whether the rollback tool is
   itself sound.
3. **One change per window gives a failure one cause.** If a layer goes
   `Degraded` after both moved at once, the release and the controller are both
   suspects. Done separately, ArgoCD is exonerated by a clean `Synced` and
   `Healthy` table before the bump starts.

**Why not the reverse, bump first.** A release can lean on newer ArgoCD
behaviour than the floor requires, and the failure reads as a malformed
Application rather than as a version problem
([ArgoCD § the 2.6 floor](../administration/argocd.md#the-26-floor-is-a-floor-not-a-suggestion)).
That is a worse place to discover it than before the bump.

## The version range this repository records

Every version statement on this page comes from a file in this repository,
named in the right-hand column. **The repository records floors and measured
points. It does not record a tested ceiling for either component.**

| Statement | Value | Where it comes from |
|---|---|---|
| ArgoCD minimum (app version, not chart version) | 2.6 | [ArgoCD § the 2.6 floor](../administration/argocd.md#the-26-floor-is-a-floor-not-a-suggestion); [prerequisites](prerequisites.md) |
| ArgoCD most recently measured against | argo-cd chart 10.7.2, ArgoCD v3.5.2, 2026-09-04 (the metrics wiring); argo-cd chart 10.10.2, ArgoCD v3.5.4, 2026-10-10 (this page's connected upgrade, from 10.9.1 / v3.5.3, with all nine layers running) | `charts/tockmox-observability/templates/argocd-monitoring.yaml`, the comment above the ServiceMonitor rows; [what is not certified here](#what-is-not-certified-here) |
| ArgoCD ceiling | none recorded | Absence from the files above, `docs/administration/argocd.md` and `RELEASING.md` |
| Kubernetes minimum | 1.30, "1.33+ comfortable" | [existing cluster § what Tockmox needs](existing-cluster.md#what-tockmox-needs-from-your-cluster) |
| k3s version the platform claim was measured on | `v1.36.4+k3s1` | [fresh install § 4](fresh-install.md#set-these-on-each-node-before-you-start), the `K3S_VERSION` pin |
| k3s ceiling | none recorded: "A newer k3s is fine; record which one you used" | [fresh install § 4](fresh-install.md#set-these-on-each-node-before-you-start) |
| k3s versions listed in the images this release mirrors | none | `images.txt` carries workload images only; neither ArgoCD nor k3s is in it |

**What that means for the policy.** Stay at or above the floor. Prefer a version
at or near the measured point. Move one upstream minor at a time, because a skipped
minor is a skipped set of upgrade notes (upstream says so for both products, and
the links are below). When you move past the measured point, write down what you
moved to; that record is yours to keep, and a release's notes tell you if it
learned anything.

## Upgrade ArgoCD

### 1. Record what you are on, and back up its objects ... Required

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
helm --kube-context="$KUBE_CONTEXT" -n argocd list
kubectl --context="$KUBE_CONTEXT" -n argocd get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**Success condition:** `helm list` shows the `argocd` release with a chart
version and an `APP VERSION`, and the second command prints the server image
tag. Save both outputs somewhere outside the cluster; they are your rollback
target.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
kubectl --context="$KUBE_CONTEXT" -n argocd get applications.argoproj.io,appprojects.argoproj.io \
  -o yaml > argocd-objects-backup.yaml
wc -l argocd-objects-backup.yaml
```

**Success condition:** the file is not empty. It holds the Applications Tockmox
generated and any AppProjects. Your site repository already holds the source of
truth for the Applications, so this file is a convenience for comparing before
and after, not the only copy.

**The repository credential is separate and is a secret.** ArgoCD reads your site
repository through a Secret in its namespace
([ArgoCD § a missing repository credential](../administration/argocd.md#a-missing-repository-credential-names-nothing-useful)),
which cannot be sealed and committed. A Helm upgrade leaves that Secret alone
because the chart did not create it. If you want a copy before you start, export
it, encrypt it, and keep it off the cluster. Do not leave it unencrypted in a
working directory.

### 2. Read the upstream notes for every minor you cross ... Required

Pick the target chart version the way the install page does, so the chart
version and the app version are shown to you rather than assumed. **The chart
number and the ArgoCD number are different numbers**; the floor is on the app
version
([fresh install § 6](fresh-install.md#6-install-argocd)).

**WORKSTATION**

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm search repo argo/argo-cd --versions | sed -n '1,5p'
export ARGOCD_CHART_VERSION="$(helm search repo argo/argo-cd --versions \
  | awk 'NR==2 {print $2}')"
helm search repo argo/argo-cd --version "$ARGOCD_CHART_VERSION"
```

**Confirm before continuing:** the last line reprints the one chart version you
are about to install, with its `APP VERSION`. If you are not on the previous
minor of that app version already, do not jump. Set `ARGOCD_CHART_VERSION` by
hand to a chart that carries the next minor above yours, upgrade to it, and
repeat this section.

Then read, for **each** minor between your app version and the target:

- ArgoCD's own upgrade notes, which are written per minor and list the changes
  that need a workaround:
  [operator manual, upgrading](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/).
  Upstream's guidance is to check the notes for every intermediate minor, not
  just the last.
- The argo-helm chart's own upgrade notes for each chart major you cross, in the
  chart's README in the [argo-helm repository](https://github.com/argoproj/argo-helm).

**Success condition:** you can name every action those notes ask for between
your version and the target, or say there are none.

### 3. Upgrade ... Required

The Helm route. **It reuses the values you installed with**, including the six
metrics flags from the install block
([fresh install § 6](fresh-install.md#6-install-argocd)), and re-applies the
chart's new defaults beneath them.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
: "${ARGOCD_CHART_VERSION:?run the block in section 2 first}"
helm upgrade argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --kube-context="$KUBE_CONTEXT" \
  --namespace argocd \
  --reset-then-reuse-values
kubectl --context="$KUBE_CONTEXT" -n argocd rollout status \
  deployment/argocd-server --timeout=300s
```

**Conditional: if you installed from the raw manifest** (`helm list` printed
nothing), upgrade the same way you installed. A client-side apply cannot
succeed against a current upstream manifest, so use the server-side form
([ArgoCD § if you install from the raw manifest anyway](../administration/argocd.md#if-you-install-from-the-raw-manifest-anyway)),
pinned to the tag you chose rather than `stable`, and apply the whole manifest,
not only the image. That route is not tested here for upgrades, and the
repository documents Helm as its only tested route.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
: "${ARGOCD_VERSION:?export ARGOCD_VERSION, for example the tag you chose in section 2}"
kubectl --context="$KUBE_CONTEXT" apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
```

### 4. Prove it ... Required

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
kubectl --context="$KUBE_CONTEXT" -n argocd get pods
kubectl --context="$KUBE_CONTEXT" get crd applicationsets.argoproj.io
kubectl --context="$KUBE_CONTEXT" -n argocd get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl --context="$KUBE_CONTEXT" -n argocd get svc | grep metrics
kubectl --context="$KUBE_CONTEXT" -n argocd get applications -o \
  custom-columns='LAYER:.metadata.name,REVISION:.spec.sources[0].targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

**Success condition**, all five:

1. Every ArgoCD pod is `Running` and fully `Ready`. Pods from finished Jobs show
   `Completed` and are expected.
2. The ApplicationSet CRD exists.
3. The server image tag is the version you chose, and at least `v2.6`.
4. Three `metrics` Services are listed. They prove the metrics settings survived;
   without them the ArgoCD dashboard reads "No data" and
   `TockmoxArgoCDMetricsAbsent` stays silent by design
   ([ArgoCD § its metrics are off until you turn them on](../administration/argocd.md#its-metrics-are-off-until-you-turn-them-on)).
5. Every layer's revision column is **unchanged from before the upgrade**, and
   every row reads `Synced` and `Healthy`. This is the check that matters. The
   only thing that moved is the controller.

**For a minute or two `Unknown` is normal** while the repo-server comes back.
A layer still `Unknown` with a `ComparisonError` after five minutes is the
repository-credential failure
([ArgoCD § when ArgoCD cannot read the repository](../administration/argocd.md#when-argocd-cannot-read-the-repository-and-what-alerts)),
not a Tockmox fault.

### Roll back ArgoCD

**Conditional. Do this if** section 4 failed and the upstream notes do not
explain it.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
helm --kube-context="$KUBE_CONTEXT" -n argocd history argocd
```

Read the revision number from the saved output of section 1, then run
`helm rollback argocd REVISION_NUMBER --kube-context="$KUBE_CONTEXT" -n argocd`.
Then run section 4 again. **Helm does not necessarily revert CRDs**, and a CRD
that a newer ArgoCD widened can stay widened. If the older controller then
misbehaves, that is why, and the upstream notes for the minor you left say what
state it needs.

## Upgrade ArgoCD at an air-gapped site (Dark Site)

**The procedure is the one above with three differences: the chart and its images
come across the boundary first, you upgrade from the local archive, and nobody
upstream can notice a skipped minor for you.** The air-gap page documents the
Helm archive route only
([air-gapped § 4](airgap.md#4-carry-in-the-three-prerequisites--required)); the
raw-manifest route has no air-gapped procedure here.

**ArgoCD does not stop needing your git servers.** It reads two repositories on
every reconcile
([air-gapped § 5](airgap.md#5-serve-both-git-repositories-inside-the-boundary--required)).
An ArgoCD upgrade changes neither repository. Leave both alone, and do not move
`targetRevision` in the same window.

### Carry in the chart and its images ... Required

Do the connected side first. Pick the chart version with section 2 above, one
minor at a time, and **carry the upstream upgrade notes for every minor you
cross across the boundary with it**: they live upstream, not in the chart
archive, and a site with no uplink cannot read them later.

**CONNECTED**

```bash
: "${ARGOCD_CHART_VERSION:?choose it with section 2 first}"
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm pull argo/argo-cd --version "$ARGOCD_CHART_VERSION"
ls -l "argo-cd-${ARGOCD_CHART_VERSION}.tgz"
```

**Success condition:** the archive exists. It crosses the boundary with the
notes; nothing else is needed from the chart repository.

Then list the images that archive renders, using the same extractor the
repository's own image list is built with
(`tools/lib/extract-images.sh`, run from your Tockmox checkout), and with the
install-time metrics settings, so the list matches what will deploy:

**CONNECTED**

```bash
: "${ARGOCD_CHART_VERSION:?choose it with section 2 first}"
. tools/lib/extract-images.sh
helm template argocd "./argo-cd-${ARGOCD_CHART_VERSION}.tgz" --namespace argocd \
  --set controller.metrics.enabled=true \
  --set server.metrics.enabled=true \
  --set repoServer.metrics.enabled=true \
  | extract_images > argocd-images.txt
cat argocd-images.txt
```

**Success condition:** the file lists the ArgoCD image and the images of the
other ArgoCD components, one per line. The air-gap page says plainly that this
list is not a promise: check it against what the pods ask for after the
upgrade rather than trusting it
([air-gapped § 4](airgap.md#4-carry-in-the-three-prerequisites--required)).
ArgoCD's images are not in the repository's `images.txt`.

Mirror them with the tool that mirrors the rest, pointed at this file, then
verify from inside the boundary:

**CONNECTED**

```bash
export MIRROR=YOUR_REGISTRY_HOST/mirror
./tools/mirror-images.sh --registry "$MIRROR" --images argocd-images.txt --dry-run
./tools/mirror-images.sh --registry "$MIRROR" --images argocd-images.txt
```

**WORKSTATION ... INSIDE THE BOUNDARY**

```bash
export MIRROR=YOUR_REGISTRY_HOST/mirror
./tools/mirror-images.sh --registry "$MIRROR" --images argocd-images.txt --verify
```

**Success condition:** `--verify` reports every entry present and exits 0, the
same condition the air-gap page uses for the main list
([air-gapped § 2](airgap.md#2-mirror-the-images--required)). A node pulls through the
containerd mirror you already configured, so no per-chart wiring is needed. If
you used `global.imageRegistry` as the fallback instead, that setting does not
reach images in a chart you carried in; see
[air-gapped § `global.imageRegistry` is the fallback](airgap.md#globalimageregistry-is-the-fallback).

### Upgrade from the archive ... Required

**WORKSTATION ... INSIDE THE BOUNDARY**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
: "${ARGOCD_CHART_VERSION:?set it to the version of the archive you carried in}"
helm upgrade argocd "./argo-cd-${ARGOCD_CHART_VERSION}.tgz" \
  --kube-context="$KUBE_CONTEXT" \
  --namespace argocd \
  --reset-then-reuse-values
kubectl --context="$KUBE_CONTEXT" -n argocd rollout status \
  deployment/argocd-server --timeout=300s
```

Then run [section 4](#4-prove-it--required) unchanged. Its success condition is
the same; only where the chart came from differs. Pods stuck in
`ImagePullBackOff` mean an image the extractor missed: read the image name from
`kubectl -n argocd describe pod`, mirror that one, and rerun the verify.

**Keep a record of the version you are on.** At a connected site a skipped minor
is visible upstream. Here it is invisible, so write the chart version and app
version into your own change record each time, and cross one minor at a time
using the notes you carried in.

## Upgrade k3s

### Verdict on system-upgrade-controller: document the manual path, do not adopt it

Tockmox evaluated `system-upgrade-controller` (the Rancher controller that
upgrades k3s nodes from a `Plan` resource) as the way to upgrade k3s. **Verdict:
document, do not adopt.** The manual path below is the documented one, the
controller remains your choice to run, and Tockmox neither installs it nor
requires it. The reasons:

- **It does not enforce what matters most.** The k3s documentation states that
  the controller does not enforce the Kubernetes version skew policy, that a
  plan must not skip intermediate minors, and that it "will not protect against
  unsupported changes" ([k3s: automated upgrades](https://docs.k3s.io/upgrades/automated)).
  Automation that leaves the one rule you must follow to the plan author adds a
  moving part without removing the risk.
- **It runs with host-level privilege.** Per the same page its upgrade Jobs use
  host IPC, network and PID namespaces and mount the host root. A cluster-wide
  controller that needs that is a decision for the cluster owner, not a default
  a platform should make on your behalf.
- **The air-gap story is absent.** The same page does not cover air-gapped
  installs, and an air-gapped site would have to mirror the controller, its
  upgrade image and every k3s release it targets with no procedure here to
  check it.
- **Tockmox's own install already pins the version by hand.** The fresh-install
  page exports `K3S_VERSION` per node and installs with it
  ([fresh install § 4](fresh-install.md#set-these-on-each-node-before-you-start)).
  The same pin is the upgrade lever, and it keeps every node on one version
  deliberately.
- **No evidence either way.** Nothing in this repository records the controller
  being run against a Tockmox cluster, so adopting it would be a claim with
  nothing behind it.

**The decision is reversible.** A site that runs the controller already, or
wants to, can: the manual rules below still apply to its plans (servers first,
one minor at a time, drain first), and the Longhorn and k3s-addon cautions
below apply identically. Reopen this verdict only with a run on a throwaway
cluster as evidence.

### The procedure ... Required

Follow the k3s documentation's manual upgrade procedure
([k3s: manual upgrades](https://docs.k3s.io/upgrades/manual)). Three rules from
it, stated here because they are the ones that break a Tockmox cluster:

1. **Do not skip a Kubernetes minor.** k3s versions carry the Kubernetes minor,
   so `v1.36.x` to `v1.38.x` is two steps, not one.
2. **Upgrade server nodes first, one at a time, then agents.** On the
   three-server shape, wait for the node to be `Ready` before the next.
3. **Re-run the installer with the same configuration you used originally**,
   changing only the version. That means the same `INSTALL_K3S_EXEC` flags the
   install page gave, so a changed flag is a decision rather than an accident.

Per node, with the Tockmox-specific parts:

1. **Read the Longhorn state before you touch a node.** Draining a node can
   take the only replica of a volume with it
   ([day-2 § take a node out for maintenance](../operations/day-2.md#take-a-node-out-for-maintenance)
   and
   [storage § draining a node takes its replicas with it](../administration/storage.md#draining-a-node-takes-its-replicas-with-it)).
   Do not continue on a volume that is not at its full replica count.
2. **Drain it**, with the day-2 procedure.
3. **Run the k3s install block for that node's role** from
   [fresh install § 4](fresh-install.md#4-install-k3s), with `K3S_VERSION` set to
   the new version. For the first server that is block 4a.
4. **Uncordon it** and run the success condition below before the next node.

**NODE**

```bash
: "${K3S_VERSION:?export K3S_VERSION to the NEW version first}"
sudo /usr/local/bin/k3s --version
```

**Success condition**, after each node: `sudo /usr/local/bin/k3s --version` prints the new
version, and from your workstation `kubectl get nodes` reports that node `Ready`
at the new version in its `VERSION` column, with the others unchanged. After the
last node, every node shows the same version.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
kubectl --context="$KUBE_CONTEXT" get nodes
kubectl --context="$KUBE_CONTEXT" -n argocd get applications -o \
  custom-columns='LAYER:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

**Success condition:** all nodes on one version and `Ready`, and every layer
`Synced` and `Healthy`, as before.

### What a k3s upgrade re-does that you set by hand

**The StorageClass default can come back.** If you un-defaulted `local-path`
with the patch alone, it is re-asserted on every k3s restart and upgrade
([storage § the patch does not survive a k3s restart](../administration/storage.md#the-patch-does-not-survive-a-k3s-restart)).
The durable form is the `.skip` file, which must be on every server node
([fresh install § 5](fresh-install.md#5-stop-k3s-re-asserting-its-storageclass-default)).
After a k3s upgrade, check there is exactly one default:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Where each command runs}"
kubectl --context="$KUBE_CONTEXT" get storageclass
```

**Success condition:** exactly one class is marked `(default)`.

**Air-gapped sites** need the new k3s binary and the images k3s itself pulls
(its packaged components) inside the boundary before the node is touched. This
repository has no procedure for carrying a k3s release in; the k3s documentation
describes it for its own air-gap install, and that procedure has not been
tested against a Tockmox cluster. Treat that as a gap to close on a throwaway
cluster before you need it.

## What is not certified here

- **The connected Helm route was run once, by hand, not by the harness.**
  2026-10-10, single-node lab cluster (k3s v1.36.4+k3s1) with all nine layers
  and the site's Applications in place: sections 1 to 4 pasted as printed,
  argo-cd chart 10.9.1 (v3.5.3) to 10.10.2 (v3.5.4), in one step that crossed
  no ArgoCD minor. Sections 1 and 2 printed what they promise; the upgrade kept
  the three metrics Services; every layer kept its revision and was re-read
  `Synced` and `Healthy` after the new controller had reconciled every one of
  them (all twelve Applications within 15 minutes of the upgrade). Two blocks
  changed because of that run: section 2's `| head -5` became `sed -n '1,5p'`
  (under `set -o pipefail`, as a script runs it, `head` closing the pipe killed
  the block), and section 3's `wait --for=condition=available` became
  `rollout status` (and the same in the air-gapped upgrade block) (the old Deployment was still available, so the wait
  returned at once and section 4 then read new pods still starting). The
  executed-documentation harness does not cover this page.
- **The air-gapped ArgoCD upgrade was not run.** Its commands are composed from
  blocks that are executed elsewhere in this repository (the install, the
  mirror tool and its `--verify`, the image extractor) and from Helm's
  documented `upgrade` behaviour.
- **The raw-manifest route was not run.** The repository documents Helm as its
  only tested route.
- **The air-gapped k3s upgrade has no procedure here.** See above.
- **No ceiling is recorded** for ArgoCD or k3s, and the "measured" points in the
  version table are single measurements on one date, not a compatibility matrix.
- **`--reset-then-reuse-values` depends on how you installed.** It keeps values
  you passed with `--set` or `-f` at install time. If you changed the release
  by other means, read `helm -n argocd get values argocd` before the upgrade and
  confirm the metrics settings are in it.

## Next

[Upgrading to a new release](upgrade.md) is the Tockmox half of this, to run
after the foundations are settled. Routine work on a running cluster is
[day-2 operations](../operations/day-2.md). The reasoning for ArgoCD staying
outside Tockmox is [ArgoCD](../administration/argocd.md).

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

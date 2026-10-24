---
okf_version: "0.2"
type: HowTo
title: "Day-2 operations"
description: "The routine tasks on a running Tockmox cluster: change a value, force a sync, take a node out for maintenance, turn an application off, and add your own workloads."
tags: [operations, day-2, gitops, argocd, node-maintenance, sync, cronjobs]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Day-2 operations

**These are independent tasks, not a procedure.** Nothing on this page runs in
order and nothing here is a prerequisite for anything else. Find your task in
[which task do you need](#which-task-do-you-need), do that one, stop.

The one thing worth reading before you need it is [the one rule](#the-one-rule),
because it decides where every change on this page is made.

## Before you begin

Shared by every task on this page. Anything a single task needs on top of this
is stated in that task, as a test you can run.

| What you need | Why | How to check |
|---|---|---|
| `kubectl` pointed at the cluster | Every task here reads or writes cluster state | `kubectl get nodes` lists your nodes |
| A clone of your **site repository**, with push access, exported as `SITE_REPO` | This is where changes are made. A change made anywhere else is undone, see [the one rule](#the-one-rule) | After the export below, `git -C "$SITE_REPO" push --dry-run` succeeds |
| Every layer already settled | Starting from a red cluster means you cannot tell your change from a failure that was already there | [The readiness bar](../deployment/install.md#the-readiness-bar), run twice, printing nothing both times |
| The name of the layer you are changing | Values are per-layer, and the wrong file is a change that renders and does nothing | `ls "$SITE_REPO/site/values/"` lists `global.yaml` and one file per layer |

**YOU SUPPLY:** the path to your site repository clone and the name of the layer
you are changing, once each. The path is the clone **on this machine**, not the
repository URL. Both are exported rather than substituted into every block, so
each block below is pasteable as printed:

```bash
export SITE_REPO=YOUR_SITE_REPO_PATH
export LAYER=YOUR_LAYER_NAME
test -f "$SITE_REPO/bootstrap/root.yaml" && echo "SITE_REPO: $SITE_REPO  LAYER: $LAYER"
```

Every block that reads one of these starts with a guard line, so a block pasted
into a shell that has not run this one stops with a message instead of running
against your home directory or the wrong layer. The nine layer names are
tabulated in [architecture](../architecture.md#the-nine-layers); the Application
for a layer is `tockmox-$LAYER`.

## The one rule

**The repository is the truth.** Every change goes through your site repository.
`kubectl edit` is reverted by ArgoCD's `selfHeal`, usually within minutes, and
that is the mechanism working rather than a race you lost.

Why the trade is worth making, and the two things on a Tockmox cluster it does
**not** cover, are in
[architecture § why an edit made in the cluster does not stick](../architecture.md#why-an-edit-made-in-the-cluster-does-not-stick).

## Which task do you need

| You want to | Task | Applies |
|---|---|---|
| Change any shipped setting | [Change a configuration value](#change-a-configuration-value) | Required, for every change |
| Not wait for the next poll | [Force a sync now](#force-a-sync-now) | Optional |
| Know whether one push landed on every layer | [Check which revision each layer is running](#check-which-revision-each-layer-is-running) | Conditional |
| Fix logins that broke after an SSO edit | [Restart the consoles after an SSO change](#restart-the-consoles-after-an-sso-change) | Conditional |
| Reboot, patch or replace a node | [Take a node out for maintenance](#take-a-node-out-for-maintenance) | Conditional |
| Tell Tockmox's objects from your own | [Find what Tockmox manages](#find-what-tockmox-manages) | Optional |
| Switch a shipped application off | [Turn an application off](#turn-an-application-off) | Conditional |
| Run something of your own here | [Add your own workloads](#add-your-own-workloads) | Optional |
| Stop scheduled jobs firing at the wrong hour | [Set the schedule timezone](#set-the-schedule-timezone) | Required, once |
| Remove Tockmox altogether | [uninstalling](uninstall.md) | Not this page |

## Change a configuration value

**Required.** This is how every other change on this page is actually made. The
file named below is one example: `global.yaml`, or any other layer's file under
`site/values/`, is edited exactly the same way.

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
cd "$SITE_REPO"
$EDITOR site/values/observability.yaml
git commit -am "raise Loki retention to 90d"
git push
```

ArgoCD applies it on its next reconciliation. Tockmox does not set that interval
... it belongs to your ArgoCD install, which Tockmox never touches. If you need
the number, it is the `timeout.reconciliation` key in the `argocd-cm` ConfigMap,
and an absent key means your chart's own default is in force:

```bash
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'
```

> **Unverified.** The key name and the "absent means default" behaviour are
> upstream ArgoCD configuration, read from documentation rather than measured on
> a Tockmox cluster for this page. The command is safe to run either way: it
> reads a ConfigMap.

**Success condition:**

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status}{"\n"}'
```

Real output from a healthy layer:

```
SYNC=Synced HEALTH=Healthy
```

**Both fields matter and they fail differently.** `Synced` alone means ArgoCD
applied your commit; it says nothing about whether the workload came up.
`Healthy` alone, with `OutOfSync` beside it, means the running thing is fine and
your change is not in it. If it does not reach both, go to
[troubleshooting § application stuck OutOfSync](troubleshooting.md#application-stuck-outofsync).

## Force a sync now

**Optional.** What you get: the change lands in seconds rather than at the next
poll. What you lose by skipping it: only time. Nothing else on this page depends
on it.

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd patch application "tockmox-$LAYER" \
  --type merge -p '{"operation":{"sync":{}}}'
```

**Success condition:**

```bash
kubectl -n argocd get applications -w
```

The layer leaves `OutOfSync`, then settles on `Synced` and `Healthy`. Interrupt
the watch once it does.

## Check which revision each layer is running

**Conditional. Run this if** your commit changed more than one layer's values:

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
git -C "$SITE_REPO" show --name-only --format= HEAD -- site/values/ \
  | grep -c 'site/values/'
```

A count greater than 1 means this task applies to you. A count of 1, or 0, means
skip it.

**Why it exists:** sync waves order the first rollout only. After that each layer
polls independently, so for a few minutes one layer can be running your commit
while another is still on the previous one ... and **both report `Synced`**,
correctly, because each is synced to the revision it last resolved. The full
anatomy, including a dated case where it bit, is in
[ArgoCD § synced does not mean every layer is on the same commit](../administration/argocd.md#synced-does-not-mean-every-layer-is-on-the-same-commit).

Compare revisions rather than statuses:

```bash
for a in $(kubectl -n argocd get applications -o name | cut -d/ -f2); do
  printf '%-24s %s\n' "$a" \
    "$(kubectl -n argocd get application "$a" -o jsonpath='{.status.sync.revisions[0]}' | cut -c1-12)"
done
```

If they disagree and you want them aligned now rather than at the next poll:

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd annotate application "tockmox-$LAYER" \
  argocd.argoproj.io/refresh=hard --overwrite
```

**Success condition:** every layer your commit touched prints the same
12-character revision, and it is the commit you pushed:

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
git -C "$SITE_REPO" rev-parse --short=12 HEAD
```

Layers your commit did **not** touch may legitimately sit on an older revision.
The test is agreement among the layers you changed, not agreement across all
nine.

## Restart the consoles after an SSO change

**Conditional. Run this if** your commit changed `sso.clientId`, `sso.adminGroup`
or `sso.userGroup`:

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
git -C "$SITE_REPO" diff HEAD~1 HEAD -- site/values/ \
  | grep -E 'clientId|adminGroup|userGroup' || echo "no SSO keys changed: skip this task"
```

Any matching line means this task applies.

**Why GitOps will not do it for you.** Grafana and Open WebUI read their OIDC
configuration from a Secret through `envFrom`, and Kubernetes does not restart a
pod when an `envFrom` source changes. The layer reports `Synced` and `Healthy`
and the consoles keep the old value, so the first symptom is failed logins that
name Authentik rather than the console holding the stale client ID. The upstream
gap behind it is in
[identity § changing sso.clientId or a group name needs a restart you have to ask for](../administration/identity.md#changing-ssoclientid-or-a-group-name-needs-a-restart-you-have-to-ask-for).

```bash
kubectl -n tockmox-ai rollout restart statefulset/tockmox-ai-open-webui
kubectl -n tockmox-monitoring rollout restart deployment/tockmox-observability-grafana
```

Two cases that do **not** need this, so you do not do it out of habit:

- **`global.certIssuer` and `global.internalDomain`.** A value derived from both
  rides in the pod spec, so changing either rolls the pods on its own.
- **The Argo Workflows server.** Its OIDC settings are plain pod-spec values, so
  any change to them already rolls it.

**Success condition**, and the second half is the one that counts:

```bash
kubectl -n tockmox-ai rollout status statefulset/tockmox-ai-open-webui --timeout=300s
kubectl -n tockmox-monitoring rollout status deployment/tockmox-observability-grafana --timeout=300s
```

Both report a completed rollout, **and** a fresh SSO login to each console
succeeds. A completed rollout only proves new pods started; only the login
proves they started with the new client ID.

> **Sourced, not measured here.** This requirement is stated by
> `charts/tockmox-common/templates/_helpers.tpl` and by
> [tls-and-trust § changing SSO settings later](../administration/tls-and-trust.md#changing-sso-settings-later),
> against the charts in this tree at v0.6.0. It has not been re-executed against
> a live cluster for this page.

## Take a node out for maintenance

**Conditional. Run the storage check first**, and read its answer before you
drain anything:

```bash
kubectl -n tockmox-platform get volumes.longhorn.io
```

A volume that is not at its full replica count, or whose replicas all sit on the
node you are about to drain, turns this task into a planned outage for that
volume. Draining a node holding the only replica does exactly what you asked.
The two shapes this takes, and the anti-affinity setting that causes the second
one, are in
[storage § draining a node takes its replicas with it](../administration/storage.md#draining-a-node-takes-its-replicas-with-it).

Otherwise this is cordon, drain, work, uncordon, with nothing Tockmox-specific
in it.

**YOU SUPPLY:** the node name. `kubectl get nodes` lists them.

```bash
export NODE=YOUR_NODE_NAME
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

**Do your work on the node now.** The uncordon is a separate block for that
reason ... pasted together with the drain, it would hand the node back to the
scheduler before you had touched it.

```bash
: "${NODE:?export NODE first, see the block above}"
kubectl uncordon "$NODE"
```

**Success condition**, in three parts, because the middle one is the only real
check:

```bash
: "${NODE:?export NODE first, see the block above}"
kubectl get node "$NODE"
kubectl get pods -A -o wide --field-selector "spec.nodeName=$NODE"
```

- After the cordon: the node reports `Ready,SchedulingDisabled`.
- After the drain: the pod list holds DaemonSet pods and nothing else. **A drain
  that returns quickly with workload pods still listed has not finished**, and
  the usual reason is a PodDisruptionBudget it is still waiting on.
- After the uncordon: the node reports `Ready`, with no `SchedulingDisabled`.

## Find what Tockmox manages

**Optional.** Useful on a cluster running your workloads alongside Tockmox's,
and before any bulk operation.

```bash
kubectl get all,networkpolicy,ns -A -l app.kubernetes.io/part-of=tockmox
kubectl get all -A -l tockmox.com/layer=policy
```

**Success condition:** the first lists objects across the `tockmox-` namespaces;
the second lists only the policy layer's. Either returning nothing means the
label selector is wrong or that layer is not installed ... it does not mean the
objects are absent, so check with `kubectl -n argocd get applications` before
concluding anything from an empty result.

What the two labels are for is in
[architecture § labels, and the reserved namespace prefix](../architecture.md#labels-and-the-reserved-namespace-prefix).

## Turn an application off

**Conditional. Run this if** the layer is currently rendering something you do
not want:

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\n"}{end}'
```

**Check for volumes before you push, if the thing is stateful.** With
`prune: true`, Argo removes the resources on the next sync, and that includes
PersistentVolumeClaims the chart declared:

```bash
kubectl get pvc -A -l app.kubernetes.io/part-of=tockmox
```

Then make the change the way every change is made:

```yaml
# site/values/<LAYER>.yaml, in your site repository
apps:
  thing_you_do_not_want:
    enabled: false
```

Commit and push, as in
[change a configuration value](#change-a-configuration-value).

**Success condition:**

```bash
: "${LAYER:?export LAYER first, see Before you begin}"
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\n"}{end}' \
  | grep -i 'thing_you_do_not_want' || echo "no longer rendered: correct"
```

Prints the "no longer rendered" line, and the layer is `Synced` and `Healthy`.
The resource list is the test rather than `kubectl get`, because a resource can
linger briefly after it stops being rendered.

**Removing Tockmox entirely is a different job**, and not one to improvise: see
[uninstalling](uninstall.md). Deleting the root Application does not cascade,
several namespaces stall on volumes held in a *different* namespace, and
admission webhooks outlive the namespaces that served them.

## Add your own workloads

**Optional.** Tockmox does not need to know about them.

They go in your site repository under `apps/`, as ordinary Argo Applications.

**Do not use the `tockmox-` namespace prefix.** It is reserved so that "shipped
by Tockmox" and "yours" stay machine-distinguishable. Nothing enforces this
today; it is a convention that keeps upgrades and uninstalls predictable, and
breaking it mostly hurts you. The reasoning, and the two labels that make the
distinction work, are in
[architecture § labels, and the reserved namespace prefix](../architecture.md#labels-and-the-reserved-namespace-prefix).

**Success condition.** **YOU SUPPLY:** the names you gave your own Application
and its namespace.

```bash
export OWN_APP=YOUR_APPLICATION_NAME
export OWN_NAMESPACE=YOUR_APPLICATION_NAMESPACE
kubectl -n argocd get application "$OWN_APP"
kubectl get ns "$OWN_NAMESPACE"
```

The Application reports `Synced` and `Healthy`, and the namespace name does not
begin with `tockmox-`.

## Set the schedule timezone

**Required, once**, and it is the easiest thing on this page to skip. The
default is `UTC`, which is a real answer for some people and a 3am page for
everyone else.

```yaml
# site/values/global.yaml, in your site repository
global:
  timezone: "America/Chicago"     # an IANA zone name, yours
```

**YOU SUPPLY:** the zone. `timedatectl show -p Timezone --value` on a node
prints the one that machine is using, which is usually the answer you want.

Three shipped CronJobs set `.spec.timeZone` from this value: the selfcheck
heartbeat, the AI layer's restore drill, and the identity layer's database
backup. The full key reference is in
[configuration](../administration/configuration.md).

**Success condition:**

```bash
kubectl get cronjobs -A -l app.kubernetes.io/part-of=tockmox \
  -o custom-columns=NAME:.metadata.name,SCHEDULE:.spec.schedule,TZ:.spec.timeZone
```

Every row's TZ column is your zone. A row reading `<none>` is a CronJob that
does not take the value, not a failed change.

## What is not certified here

**No task on this page has been executed start to finish and recorded as
written.** A page is not certified by reading it ... see the
[testing standard](../testing-standard.md) for which paths are covered.

Two claims here carry a source rather than a measurement, and both say so at the
point of use: the ArgoCD reconciliation-interval key, which is read from upstream
documentation, and the SSO restart requirement, which is read from the charts in
this tree at v0.6.0. The dated observation behind
[check which revision each layer is running](#check-which-revision-each-layer-is-running)
lives on
[ArgoCD § synced does not mean every layer is on the same commit](../administration/argocd.md#synced-does-not-mean-every-layer-is-on-the-same-commit)
with its date attached.

Everything else on this page is a command and the output it should produce. A
command that prints what this page says it prints has confirmed that step, not
that the task achieved what you wanted.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

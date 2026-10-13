---
okf_version: "0.2"
type: HowTo
title: "Change what Tockmox ships"
description: "The four-rung ladder for changing shipped behaviour, from values through extension points and Kustomize patches to disabling a component outright."
tags: [customising, values, extension-points, kustomize, argocd, upgrades]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Change what Tockmox ships

Four ways to change what Tockmox ships. **Reach for the lowest rung that
works** ... each rung up costs more at upgrade time, and the cost is paid later
than the change is made.

| Rung | Use it for | Upgrade cost |
|---|---|---|
| [1. Values](#rung-1--values) | Anything a chart already exposes | None. You are using a supported interface |
| [2. Extension points](#rung-2--extension-points) | Adding a dashboard, an alert rule, a NetworkPolicy | None. Your file lives in your repository |
| [3. Kustomize patch](#rung-3--kustomize-patch) | Modifying a shipped resource that is not exposed | Fails loudly when the base moves. You fix it at upgrade time |
| [4. Disable and replace](#rung-4--disable-and-replace) | Replacing a component entirely | You now own the replacement |

The shape of the same decision as a diagram, plus why rung 3 is designed to
break noisily, is in
[architecture § the customisation ladder](../architecture.md#the-customisation-ladder).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| Your **site repository**, cloned and writable, exported as `SITE_REPO` | Every rung below is a commit to it. Nothing here is a `kubectl` change | After the export below, `git -C "$SITE_REPO" status` reports a clean tree on your branch |
| `helm` on your workstation | Rungs 1 and 4 are verified by rendering before you push | `helm version --short` |
| `kubectl` against the target cluster | Rung 2's success conditions are read from the cluster | `kubectl get nodes` lists your nodes |
| The **component names for the layer you are changing** | They are chart keys, not names you can guess, and a wrong one fails silently. See the trap below | `grep -A40 '^apps:' charts/tockmox-<layer>/values.yaml` |
| The **Tockmox tag your site repository is pinned to** | Rung 3 needs it by name | `grep -rn 'ref=' "$SITE_REPO"`, or read `targetRevision` from any Application |

**YOU SUPPLY:** the path to your site repository clone, once, exported so that
every block below is pasteable as printed. It is the clone **on this machine**,
not the repository URL. Each block that reads it starts with a guard line, so a
block pasted before this one stops with a message:

```bash
export SITE_REPO=YOUR_SITE_REPO_PATH
test -f "$SITE_REPO/bootstrap/root.yaml" && echo "SITE_REPO: $SITE_REPO"
```

**A misspelt key is the failure mode this page has to warn about twice.** The
`apps` block accepts any key shaped like an object, so `apps.open_webui` lints
clean, renders clean, and does nothing at all, while the real key is
`apps.openWebui`. Verified 2026-09-01 against the 0.6.0 tree: the AI layer
renders 8 objects at baseline, 8 with `apps.open_webui.enabled=false`, and 0
with `apps.openWebui.enabled=false`. Read the component name out of the chart
before you set it, and check the render afterwards.

**What the schema does catch, since 2026-09-04, is a typo one level down.**
`apps.<component>` must now be an object whose only key is `enabled`, on every
layer, so `apps.openWebui.enabld: false` fails at lint with the offending
property named. The component name itself is still free-form ... it has to be,
because the set of components changes with every layer and release ... so the
paragraph above still describes a real hole. The difference is that only one of
the two spellings is now silent.

## Rung 1 ... values

**Required reading before rungs 2 to 4.** If a chart already exposes what you
want, stop here.

Anything a chart exposes, including anything an upstream chart exposes under its
own key. Free upgrades forever, because you are using a supported interface.

```yaml
# site/values/observability.yaml ... keep logs 30 days instead of 7
loki:
  loki:
    limits_config:
      retention_period: 720h
```

**Success condition:** render the layer and read the value back, before you
push.

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
helm template t charts/tockmox-observability \
  --set global.internalDomain=example.internal \
  --set global.lanCIDR=192.168.1.0/24 \
  -f "$SITE_REPO/site/values/observability.yaml" \
  | grep retention_period
```

The output is `retention_period: 720h`. If it is `168h`, your file is not being
read or your key path is wrong, and no amount of committing will change that.
Measured 2026-09-01 against the 0.6.0 tree: `168h` without the override, `720h`
with it.

**Grep for the key itself, not for its neighbourhood.** The rendered Loki config
is emitted with its keys sorted, so `retention_period` does not sit next to
`limits_config` and a context grep around the block heading will miss it and
look like a failed override.

**Conditional: if you are changing Loki retention specifically**, retention also
needs the compactor, which the shipped values already enable. Loki deletes
nothing without it, whatever `retention_period` says. Confirm in the same render
rather than assuming, because it is a value and your file could have overridden
it:

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
helm template t charts/tockmox-observability \
  --set global.internalDomain=example.internal \
  --set global.lanCIDR=192.168.1.0/24 \
  -f "$SITE_REPO/site/values/observability.yaml" \
  | grep retention_enabled
```

Prints `retention_enabled: true`.

The full surface is in [configuration](configuration.md).

## Rung 2 ... extension points

**Optional.** Deliberate seams where you drop a file in **your** repository and
Tockmox picks it up. No patching, no conflicts, survives every upgrade. What you
get by using one instead of rung 3: your addition is never in conflict with
ours, because it is a separate object rather than a modification of one.

### Grafana dashboards

Any ConfigMap labelled `grafana_dashboard: "1"` is discovered, in **any**
namespace ... the sidecar is configured with `searchNamespace: ALL`.

```yaml
# apps/my-dashboard.yaml in your site repo
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: tockmox-monitoring
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    { "title": "My Dashboard", ... }
```

**Success condition**, two steps, because the first can pass while the second
fails:

```bash
kubectl get configmap -A -l grafana_dashboard=1 | grep my-dashboard
kubectl -n <monitoring namespace> logs deploy/tockmox-observability-grafana \
  -c grafana-sc-dashboard | tail -20
```

The ConfigMap is listed, **and** the sidecar log names your file as written. A
ConfigMap that exists but never appears in that log has the label wrong or is
malformed JSON, and Grafana will simply not show it with no error anywhere in
the UI.

**Replacing one of ours is believed to work by shipping a dashboard with the
same UID**, on the reasoning that the sidecar writes both files and Grafana
imports by UID with last write winning. **That is written as a belief, not a
measurement**: nothing in this repository pins the order in which two ConfigMaps
are written, so "yours is last" is not a property anything guarantees. If you
depend on it, verify it on your own cluster, and prefer a distinct UID if you
can.

### Alert rules

Add a PrometheusRule in your own namespace.

**To silence one of ours, use Alertmanager inhibition rather than editing our
rule.** What that buys you: your silence survives upgrades, because it is not a
modification of a shipped object. Editing the shipped rule puts you on rung 3
for something rung 2 already covers.

**Success condition.** **YOU SUPPLY:** the `metadata.name` you gave the rule in
the file you just committed.

```bash
export RULE_NAME=YOUR_RULE_NAME
kubectl get prometheusrule -A | grep "$RULE_NAME"
```

Your rule is listed. Then confirm Prometheus loaded it: its `/rules` page, or
`kubectl -n <monitoring namespace> port-forward svc/<prometheus svc> 9090:9090`
and read `localhost:9090/rules`. A PrometheusRule the operator rejected exists
in Kubernetes and does nothing.

### NetworkPolicies

Add your own. Policies are additive in Kubernetes, so adding one never removes
ours, and there is no conflict to resolve.

**Success condition:** `kubectl get networkpolicy -n <namespace>` lists both
yours and the shipped ones.

## Rung 3 ... Kustomize patch

**Conditional: use this only when the change is not exposed as a value and not
covered by an extension point.** Check rungs 1 and 2 first, in that order.

```yaml
# apps/kustomization.yaml in your site repo
resources:
  - github.com/tockmox/tockmox//charts/tockmox-policy?ref=YOUR_TOCKMOX_TAG
patches:
  - path: my-patch.yaml
    target:
      kind: NetworkPolicy
      name: default-deny-ingress
```

**YOU SUPPLY:** `YOUR_TOCKMOX_TAG`, the tag your site repository is already
pinned to. It is the `targetRevision` on your Applications, and the released
tags are listed at
[github.com/tockmox/tockmox/releases](https://github.com/tockmox/tockmox/releases).
Pin a tag, never a branch. You upgrade by bumping it, in the same commit as
every other `ref` you have.

**Success condition:** build it locally before you push.

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
kustomize build "$SITE_REPO/apps"
```

The build succeeds **and** the output contains your modification. A build that
succeeds while your patch matched nothing is the case to watch for: grep the
output for the change itself, not just for exit code zero.

**Patches fail loudly when the base moves underneath them.** That is the design,
and the reasoning is in
[architecture § the customisation ladder](../architecture.md#the-customisation-ladder).
The short version: a patch that silently stops applying leaves you believing a
change is in effect when it is not, and you find out during an incident.

## Rung 4 ... disable and replace

**Conditional: use this when you are replacing a component outright**, not when
you want to change how it behaves.

```yaml
apps:
  openWebui:
    enabled: false
```

Then ship your own. Every application is individually disableable precisely so
that disagreeing with one choice does not cost you the platform.

**YOU SUPPLY:** the component key, read out of that layer's `values.yaml`. It is
`openWebui`, not `open_webui`, and the wrong spelling does nothing silently.

**Success condition:** render before you push, and compare the object count.

```bash
helm template t charts/tockmox-ai \
  --set global.internalDomain=example.internal --set global.lanCIDR=192.168.1.0/24 \
  | grep -c '^kind:'
helm template t charts/tockmox-ai \
  --set global.internalDomain=example.internal --set global.lanCIDR=192.168.1.0/24 \
  --set apps.openWebui.enabled=false | grep -c '^kind:'
```

The second number is **lower** than the first. Measured 2026-09-01 against the
0.6.0 tree, it is 8 and then 0. If the two numbers are equal, your key is wrong
and nothing has been disabled. **If both are `0`, helm did not render at all**
... read the line above the count ([history](#history-the-render-and-compare-block)).

**To decline a whole functional story rather than one component**, use
[capabilities](capabilities.md) instead. Turning off one component of a
capability whose other components are still running is a coherence error, and
the render says so.

## When you are on rung 3 or 4 repeatedly

That is a values gap, and it is our bug. Please
[open an issue](https://github.com/tockmox/tockmox/issues) describing what you
had to patch. Exposing it as a value is usually a small change and it removes
your maintenance burden permanently.

## The thing that does not work

**Editing resources in the cluster by hand.** An edit like this one is reverted:

```bash
kubectl edit networkpolicy default-deny-ingress -n tockmox-ai
```

ArgoCD's `selfHeal` reverts it. That is the mechanism working rather than a race
you lost, and the reasoning is in
[architecture § why an edit made in the cluster does not stick](../architecture.md#why-an-edit-made-in-the-cluster-does-not-stick).
`selfHeal` is a deployment-wide setting (`argocd.selfHeal` in your
`tockmox.yaml`), not a per-resource one.

**Conditional: for an emergency change only**, either commit it to your site
repo, or disable auto-sync temporarily:

```bash
kubectl -n argocd patch application tockmox-policy --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

**Success condition:**

```bash
kubectl -n argocd get application tockmox-policy \
  -o jsonpath='{.spec.syncPolicy.automated}'
```

Prints nothing. Your manual edit now survives.

**Then put it back.** Leaving auto-sync off is how clusters drift from their
repositories, so treat it as a stopwatch, not a setting. Re-enabling is a
`--type merge` patch setting `automated` back, or a resync from the ArgoCD UI;
confirm with the same `jsonpath` command, which should then print an object.

## What is not certified here

The two render measurements on this page were executed on 2026-09-01 against the
0.6.0 tree with Helm v3.16.3. **Nothing else on this page has been executed as
written**: the success conditions describe what to look for, and the
cluster-side ones in particular have not been walked end to end on a fresh
deployment as part of publishing this page.

The dashboard-replacement claim in rung 2 is explicitly a belief and is labelled
as one. See the [testing standard](../testing-standard.md) for which paths are
covered by a real deploy.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

## History and corrections

What this page used to say, and when it changed. Nothing here is needed to follow the page.

<a id="history-the-render-and-compare-block"></a>

### The render-and-compare block

Until 2026-09-14 this block held the two `--set` flags in a `$BASE` variable
expanded unquoted; zsh, the shell macOS ships, does not word-split that, helm
received one unknown flag, both counts read `0`, and the sentence beside the
block blamed the key. Measured by pasting the block into zsh (8 and 0 under
bash, 0 and 0 under zsh). `tools/check-pasteable-blocks.sh` RULE 6 refuses the
next one.

---
okf_version: "0.2"
type: HowTo
title: "Guard the Tockmox namespaces"
description: "Turn on the admission policy that refuses anything but GitOps and the platform creating objects in the namespaces Tockmox manages, read what it would have refused, and promote it from Warn to Deny."
tags: [namespace-guard, admission, validatingadmissionpolicy, gitops, security, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [operator]
---

# Guard the Tockmox namespaces

Anyone who can `create` in a namespace Tockmox manages can put an object next to
the platform's own: a Secret an operator will read, a Service that shadows a
platform one, a ConfigMap a controller trusts. The namespace guard is one
admission policy that refuses that, unless the requester is GitOps or the
platform itself.

> **Experimental since 0.9.0, off by default, and Warn when you turn it on.** The
> policy knows the identities Tockmox ships and Argo CD. It cannot know the
> controllers your cluster adds, so the first job is to find out which ones it
> would have refused. Nothing is blocked until you say so.

## What it refuses, and what it admits

The policy matches `CREATE` of any namespaced object in a namespace labelled
`tockmox.com/managed-by: tockmox`, which is every namespace the policy layer
creates. It admits only:

| Requester | Why |
|---|---|
| ServiceAccounts of the namespaces the chart derives from `namespaces` | the platform's own operators and workloads: every namespace in `namespaces.create`, plus where Traefik, the CNPG operator, Longhorn and kured run |
| ServiceAccounts of `namespaces.argocd` | Argo CD applies the charts and your site repository |
| ServiceAccounts of `kube-system` | built-in controllers, the k3s Helm controller, sealed-secrets as [fresh-install](../deployment/fresh-install.md) installs it |
| `system:` identities that are not ServiceAccounts, except `system:anonymous` | kubelets, the scheduler, the controller manager, the API server |
| the group `system:masters` | break-glass administration |
| whatever you add under `namespaceGuard` | see [Let a legitimate caller through](#let-a-legitimate-caller-through) |

The exemption is by derived name and not by prefix: a ServiceAccount in a
namespace called `tockmox-evil` is refused, because nothing derived the name.
Renaming a namespace in `namespaces` moves the exemption with it.

**Not covered, on purpose.** Subresources (`pods/exec`, `serviceaccounts/token`),
`UPDATE` and `DELETE` (RBAC owns those), cluster-scoped objects, and any
namespace without the label, including a namespace you create yourself.

## Turn it on, in Warn

In the site repository's policy values file (`site/values/policy.yaml`):

```yaml
apps:
  namespace_guard:
    enabled: true
```

That is all. `namespaceGuard.validationActions` ships as `["Audit", "Warn"]` and
`failurePolicy` as `Ignore`, so a request is never blocked and an evaluation
error never blocks one either. Commit, let Argo CD sync the policy layer, and
check that the policy and its binding exist:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context="$KUBE_CONTEXT" get validatingadmissionpolicy,validatingadmissionpolicybinding tockmox-namespace-guard
```

**Success condition:** both objects are listed, and the binding's `validationActions`
read `["Audit","Warn"]`.

## Read what it would have refused

Leave it in Warn for at least a week that includes your backup and restore drills,
upgrades and any scheduled job that writes into a Tockmox namespace. Two places
show what it would have refused.

The API server counts every evaluation. In Prometheus:

```text
sum by (policy, enforcement_action) (increase(apiserver_validating_admission_policy_check_total{policy="tockmox-namespace-guard"}[7d]))
```

A series with `enforcement_action="warn"` is a request the guard would have
refused. The count says how many; the caller is in the second place. A `Warn`
action returns the policy's message to the client, so the Argo CD sync message
or the `kubectl` warning names it: *"... system:serviceaccount:NAMESPACE:NAME may
not create KIND in NAMESPACE"*.

**Success condition:** the query reads `0` for `enforcement_action="warn"` after the
exemptions below are in place and a week has passed.

## Let a legitimate caller through

For each caller the soak named, decide whether it belongs in a Tockmox
namespace. A vulnerability scanner that writes a report next to every workload
does; a person's `kubectl create` does not, and the answer for that one is to
put the object in Git, or in a namespace of your own. For the ones that belong,
in `site/values/policy.yaml`:

```yaml
namespaceGuard:
  extraExemptServiceAccountNamespaces: [trivy-system]
  extraExemptUsers: []
  extraExemptGroups: []
```

`extraExemptServiceAccountNamespaces` admits every ServiceAccount of the
namespace with exactly that name. `extraExemptUsers` admits one exact username, for example
`system:serviceaccount:restore-drill:drill`. `extraExemptGroups` admits a group.
Write the reason beside each entry in the site repository; the policy keeps no
record of it.

## Promote to Deny

Promote when the week above ended with the query at `0`. In the same file:

```yaml
namespaceGuard:
  validationActions: ["Deny"]
```

Commit and sync. From then on a request that was only a warning is refused with
the same message. Watch the next scheduled run of everything that writes into a
Tockmox namespace, and the next Argo CD sync of every layer. Leave
`failurePolicy` at `Ignore` unless an evaluation error should also refuse a
request.

## Roll back, or turn it off

To go back to observing, set `validationActions` to `["Audit", "Warn"]` again.
Nothing else changes. To remove the guard, set `apps.namespace_guard.enabled` to
`false`; Argo CD removes the policy and its binding when pruning is on for the
policy layer's Application, and otherwise leaves them for you to delete.

## Check the exemption list

In the source tree, `tools/check-namespace-guard.sh` renders every layer, takes
the guard's expression and evaluates it against every ServiceAccount the charts
ship, so a layer that starts running a controller in a new namespace fails
there and not on the first Deny. It also evaluates the refusals above and the
extras. It evaluates the expression with an independent CEL implementation, not
with an API server; the lab run on a real cluster is a separate check.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

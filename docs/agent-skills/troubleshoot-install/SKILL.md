---
okf_version: "0.2"
type: HowTo
title: "Skill: troubleshoot an install"
description: "How an agent triages a failing Tockmox install: what to collect first, the failures whose errors name the wrong component, and where to stop and hand back."
tags: [agents, skills, troubleshooting, argocd, admission, diagnosis, machine]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [machine, operator]
---

# Skill: troubleshoot an install

**Use this when** something has failed and the operator wants help finding out
what. The defining property of this platform's failure modes is that **the error
usually names the wrong component**, so reasoning from the message alone sends
you somewhere plausible and wrong.

**The canonical index is
[troubleshooting](../../operations/troubleshooting.md).** It is an index, not a
procedure: find the symptom, go to that one entry, ignore the rest. This skill
is how to use it, not a second copy of it.

## Collect before you theorise

Two commands settle whether this is a GitOps problem or a workload problem, and
those are different investigations. Starting in the wrong one costs the most
time.

The layer name is set once, on the first line, so that both reads are certain to
be about the same Application. Two commands naming the layer separately are two
chances to name different layers, and the second read then quietly describes
something the first did not:

```bash
export LAYER=YOUR_LAYER
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
kubectl -n argocd get application "tockmox-$LAYER" \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

The nine layer names are in
[architecture § the nine layers](../../architecture.md#the-nine-layers). Get the
operator to paste the real output rather than describing it ... a paraphrased
error has usually already lost the distinguishing detail.

**Ask for the phase they were in.** A failure during Phase 3 with Phase 2.5
skipped is a different problem from the same symptom on a running cluster, and
the symptom does not distinguish them.

## Read the Application, not the pods, first

A pod in a bad state is often downstream of a layer that never applied, or of a
Secret that does not exist. Working up from the pod means re-deriving that.

**`Synced` is not the same as working.** A layer can apply cleanly and hold a
workload that never becomes ready.

**`Synced` with everything green and one workload stuck is almost always Phase
2.5.** Tockmox generates no credentials, and nothing renders them, so nothing
can fail at sync time when they are missing. The workload waits in
`CreateContainerConfigError` naming the Secret it wants. This is designed
behaviour ...
[secrets § ArgoCD reports Synced anyway](../../administration/secrets.md#argocd-reports-synced-anyway-and-that-is-designed).

## The failures that name the wrong thing

Recognise these by shape. Each has a full entry in
[troubleshooting](../../operations/troubleshooting.md); go there for the fix and
its success condition.

| Shape | What it actually is |
|---|---|
| An RBAC error about listing secrets, from a ServiceAccount nobody created (usually `helm-<something>`) | An admission policy denied a `cluster-admin` ClusterRoleBinding, three layers back. Nothing in the message mentions the policy |
| Every layer `Unknown` with `ComparisonError`, all at once | One repository reference. A missing credential, a wrong URL and a bad revision are indistinguishable here. Do not debug nine layers |
| A repository Secret that exists and is never read | The `argocd.argoproj.io/secret-type=repository` label is missing. Looks exactly like having no credential |
| `namespaces "tockmox-x" not found` | A layer ran before `tockmox-policy`, which creates every namespace at wave 1. Only surfaces on a clean cluster |
| Greenfield install stalls, Certificates never issue, the resource is absent from the cluster entirely | A resource applied in the same sync as the webhook that validates it. **The shipped cert-manager instance of this was fixed in 0.5.0** ... check the version before assuming it. The shape is general and still reachable by resources the operator adds. Automated sync will not retry a revision whose sync failed, so it does not self-heal out |
| PVCs stay `Pending` | No default StorageClass, or two. On k3s this recurs after every restart unless the `.skip` file is in place |
| SSO returns from the provider and dies; local break-glass logins still work | The console's own container does not trust the private CA. The token exchange is server-side, so a browser that trusts the CA changes nothing |
| A change made with `kubectl` came back | `selfHeal`. Working as designed. The change belongs in the site repository |
| A namespace sits `Terminating` | A finalizer whose controller is already gone. **Ask the namespace** ... its conditions name the resource type and the exact finalizer |
| Every write to a resource fails with `failed calling webhook` | An orphaned cluster-scoped webhook configuration whose namespaced Service was deleted with its namespace. This is a closed loop |
| The layer is healthy and the thing they wanted is absent | It ships off by default. Several things do, deliberately |

## Two habits that beat reasoning

**Ask the object.** A namespace stuck `Terminating` names its own blocker in
`.status.conditions` ... `NamespaceContentRemaining` and
`NamespaceFinalizersRemaining`. On the run recorded in the docs, the conditions
were right after three successive guesses about the cause had been wrong. Do the
same for events: `kubectl -n <NAMESPACE> get events --sort-by=.lastTimestamp |
tail -30` names admission denials and scheduling failures that no Application
status carries.

**Confirm the layer is on the commit they think it is.** A layer running last
week's values explains a great many symptoms and takes one command to rule out:
[day-2 § check which revision each layer is running](../../operations/day-2.md#check-which-revision-each-layer-is-running).

**One blocker is often not in the namespace being looked at.** Namespaces whose
volumes are provisioned by a CSI driver living elsewhere cannot finish until
that driver can detach them, so the namespace holding the storage layer deletes
last, not first.

## Order matters in exactly one place, and getting it backwards is a loop

If a resource belongs to an operator whose admission webhook Service is also
gone, **the patch that would clear the finalizer is itself rejected by the
orphaned webhook**. Delete the webhook configurations first, then clear the
finalizers. The other order cannot complete.

Check for it before proposing any finalizer patch. **YOU SUPPLY:** `OPERATOR`,
the name of the operator whose resource is stuck ... `longhorn`, `cnpg`,
`cert-manager` and `metallb` are the four this platform ships:

```bash
export OPERATOR=YOUR_OPERATOR_NAME
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o name | grep -i "$OPERATOR"
```

## Where you stop

**Everything from here is the operator's to run, not yours.**

Deleting webhook configurations, clearing finalizers, force-deleting pods,
terminating a stuck sync operation, patching a StorageClass annotation,
allowlisting a `cluster-admin` binding. Every one is documented because it is
sometimes necessary, and every one is how a cluster gets wedged past recovery.

Propose the exact command, say what it does and what it cannot be undone from,
and let them run it.

**Allowlisting a `cluster-admin` binding grants cluster-admin.** Add the one name
from their error. Never a pattern, and never a list copied from somewhere else.

## Verify the fix on the artifact

Every entry in the troubleshooting page ends with a "how you know it worked", and
they are deliberately not "the command exited zero".

- A namespace that is gone while its cluster-scoped leftovers remain is half
  done. CRDs, webhook configurations and ClusterRoles outlive the namespace and
  break the next install.
- A change that survives one reconciliation is fixed. A change that has not been
  reconciled yet is not.
- The webhook delete is not the finish line ... the finalizers it unblocked still
  have to be cleared.
- For "everything renders but nothing appears", the Application's **resource
  list** is the test, not `kubectl get`. A workload can survive from an earlier
  install while the layer has stopped rendering it.

## If nothing matches

Work
[troubleshooting § if none of these match](../../operations/troubleshooting.md#if-none-of-these-match)
in order; each step narrows what the next has to consider. Then help them open a
good issue: both diagnostic commands' output, the Tockmox version, and which
entries they already ruled out.

**Redact before pasting.** An Application status carries the site repository
URL, and events carry hostnames from `internalDomain`. Offer to do this for
them; it is the kind of thing that gets forgotten at 1am.

Security issues go to [SECURITY.md](../../../SECURITY.md), never a public issue.

## What is not certified here

The troubleshooting page's own
[what is not certified here](../../operations/troubleshooting.md#what-is-not-certified-here)
table says what each entry rests on, and the answers differ: some come from
dated runs, some are read from the charts and have not been re-executed. When an
operator asks whether a fix is known to work, that table is the answer.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

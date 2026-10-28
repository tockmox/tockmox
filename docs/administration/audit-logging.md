---
okf_version: "0.2"
type: HowTo
title: "Turn on API audit logging"
description: "Switch on kube-apiserver audit recording on your nodes; collection into Loki already ships wired and needs no change."
tags: [audit, logging, security, loki, k3s, apiserver, evidence]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Turn on API audit logging

Who did what to the cluster's API, recorded, shipped to Loki, queryable in
Grafana. This is the first thing a security review of a sovereign platform asks
for, and it is the evidence trail any future just-in-time privilege model has
to stand on.

**Half of this is already done, and it is not the half you would guess.**

| Half | Owner | State |
|---|---|---|
| **Recording** | The kube-apiserver, which belongs to your Kubernetes distribution, below anything a Helm chart can reach | **Off. This page turns it on.** A host-side change, once per cluster |
| **Collection** | Tockmox | **Already wired.** The log pipeline tails `/var/log/kubernetes/audit.log` under the job label `kubernetes-audit`. A tail on a path that does not exist costs nothing, so the moment your api-server starts writing the file, entries arrive in Loki. No values change, no restart, nothing to enable |

That asymmetry is why this page is four short steps and no configuration.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| Root or sudo on **every server node** | The policy file and the api-server flags are host-side, and the flags are server-only | `sudo -n true` on each |
| A clone of the Tockmox source tree, or the policy file from it | Step 1 copies `install/audit-policy.yaml` | `ls install/audit-policy.yaml` |
| A running Tockmox observability layer | Step 4 asserts entries reached Loki, which is the only check that proves the whole path | `kubectl -n tockmox-monitoring get pods -l app.kubernetes.io/name=loki` |
| Disk headroom on each server node | The flags below cap the file at 100 MB per backup, 3 backups, 30 days | `df -h /var/log` |

**Estimate, not a measurement: 15 minutes** for a single node, plus a few
minutes per additional server node.

**Every command below runs on a NODE unless marked WORKSTATION.**

## What you will have at the end

An api-server writing metadata-level audit entries to
`/var/log/kubernetes/audit.log` on each server node, those entries arriving in
Loki under `{job="kubernetes-audit"}`, and no Tockmox values changed.

## 1. Put the policy on every server node ... Required

Tockmox ships the recommended policy at
[`install/audit-policy.yaml`](https://github.com/tockmox/tockmox/blob/main/install/audit-policy.yaml).
Its shape, and the reason for it:

- **Metadata level for everything that matters** ... who, what, when, without
  bodies.
- **Full request and response bodies only for RBAC and admission-policy
  mutations**, where the content of the change is the entire point.
- **Never secret payloads.** `secrets`, `configmaps` and `sealedsecrets` are
  pinned to metadata, because an audit log containing secret data is a second
  copy of every credential with a longer retention than the credential.
- **`get`, `list` and `watch` on events, endpoints and leases are dropped
  entirely**, along with `system:kube-proxy` and `system:apiserver`. That is
  high-churn read noise nobody audits, and paying storage to ignore it is
  worse than not recording it.

On every server node:

```bash
sudo mkdir -p /var/lib/rancher/k3s/server/audit /var/log/kubernetes
sudo cp install/audit-policy.yaml \
  /var/lib/rancher/k3s/server/audit/policy.yaml
```

**YOU SUPPLY:** the path you copy *from*, if you are not sitting in the root of
a Tockmox clone.

**Success condition**, on every server node:

```bash
sudo test -f /var/lib/rancher/k3s/server/audit/policy.yaml && \
  sudo grep -c '^  - level:' /var/lib/rancher/k3s/server/audit/policy.yaml
```

The file exists and the count is `6`, one per rule in the shipped policy. A
count of `0` means you copied something else.

## 2. Add the api-server flags ... Required

In `/etc/rancher/k3s/config.yaml` on **every server node**. k3s reads this file
at start; if you already have one, **merge these keys rather than replacing the
file**.

```yaml
kube-apiserver-arg:
  - audit-policy-file=/var/lib/rancher/k3s/server/audit/policy.yaml
  - audit-log-path=/var/log/kubernetes/audit.log
  - audit-log-maxage=30
  - audit-log-maxbackup=3
  - audit-log-maxsize=100
```

**The log path is under `/var/log` on purpose.** That is the mount the log
collector already has (`alloy.mounts.varlog`, in the observability layer's
values). Point it somewhere else and the api-server writes happily, Loki stays
empty, and you own the extra plumbing to connect them ... a failure that looks
like a collection bug and is a path choice.

**Success condition:** the file parses and contains the five arguments. On every
server node:

```bash
grep -c 'audit-' /etc/rancher/k3s/config.yaml
```

Prints `5`.

### On a distribution that is not k3s ... Conditional

**If** `ls /etc/rancher/k3s/` fails, you are not on k3s. The policy file and
the five flag values above are unchanged; only where you put the flags differs.
On a kubeadm cluster they are `--audit-*` flags on the api-server static Pod
manifest, and the policy file has to be inside a hostPath the api-server Pod
mounts. Tockmox does not document that path and has not tested it.

## 3. Restart k3s and confirm the file appears ... Required

On every server node, and on a multi-server cluster one node at a time:

```bash
sudo systemctl restart k3s
```

On a three-server cluster, restart one, wait for it to report `Ready`, then do
the next. Restarting all three at once takes the API away.

**Success condition ... three assertions, because the first two pass while the
third is broken.** On every server node:

```bash
sudo systemctl is-active k3s
sudo ls -l /var/log/kubernetes/audit.log
sudo tail -n 1 /var/log/kubernetes/audit.log | head -c 200
```

k3s prints `active`, the file exists with a non-zero size, and the last line is
JSON beginning `{"kind":"Event"`. **If k3s is active and the file does not
exist**, the api-server rejected an argument and fell back: check
`sudo journalctl -u k3s -n 50` for a line naming `audit-policy-file`. A
mistyped path there does not stop k3s from starting.

Run the same check on a **workstation** to confirm the cluster is healthy
before moving on:

**WORKSTATION**

```bash
kubectl get nodes
```

## 4. Confirm entries reach Loki ... Required

This is the step that proves the whole path, and it is the one that fails when
everything else looks right.

In Grafana, Explore against the Loki datasource:

```logql
{job="kubernetes-audit"}
```

**Success condition:** lines appear, within about a minute of the restart. If
the log file is growing on the node and this query returns nothing, the
collector is the problem rather than the api-server:

**WORKSTATION**

```bash
kubectl -n tockmox-node-agents get pods -l app.kubernetes.io/name=alloy
kubectl -n tockmox-node-agents logs -l app.kubernetes.io/name=alloy --tail=50
```

**A silent difference worth knowing:** an empty result and a result you have no
permission to see look the same in Explore. Confirm you are querying as a user
whose Grafana role can read the Loki datasource before concluding the pipeline
is broken.

## Reading it

Useful first queries, once entries are arriving:

```logql
# Everything except reads
{job="kubernetes-audit"} | json | verb != "get"

# Human and controller activity, dropping the api-server's own traffic
{job="kubernetes-audit"} | json | user_username != "system:apiserver"

# Mutations only
{job="kubernetes-audit"} | json | verb =~ "create|delete|patch"

# Who touched secrets. Metadata only: the policy guarantees the payloads
# are not in the log
{job="kubernetes-audit"} | json | objectRef_resource = "secrets"
```

Loki's `json` parser flattens nested fields with an underscore, which is why
the field is `user_username` rather than `user.username`.

## What this is not

- **Not tamper-proof storage.** The file rotates on the node, and Loki
  retention is finite: the shipped default is `retention_period: 168h` in
  `charts/tockmox-observability/values.yaml` at the 0.6.0 tree, so seven days
  unless your site values raise it. An auditor asking for a year needs a
  destination outside this cluster.
- **Not a SIEM.** There is no correlation, no detection content, no case
  management. It is a queryable record.
- **Not enabled for you**, and that one is physics rather than scope: the
  api-server writes the file, and the api-server belongs to your distribution.

This page plus one config block is the entire distance from zero to queryable,
which is the trade being made.

## What is not certified here

The claims about what ships were checked against the 0.6.0 tree on 2026-09-01:
`install/audit-policy.yaml` exists and carries six rules matching the shape
described above, and the observability layer's Alloy config does declare a
`local.file_match` on `/var/log/kubernetes/audit.log` forwarding under
`job = "kubernetes-audit"` with `mounts.varlog` true.

**Nothing here is a claim that this procedure has been executed end to end on
a cluster for this release.** The success conditions above are what to check;
they are not evidence that anyone has checked them. The
[testing standard](../testing-standard.md) says which paths are covered.

The non-k3s section is explicitly untested and says so at the point of use.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

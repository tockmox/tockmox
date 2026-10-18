---
okf_version: "0.2"
type: HowTo
title: "CIS benchmark scan with kube-bench"
description: "An opt-in weekly kube-bench CronJob for k3s, the privileged namespace it needs, how to run it once and read the result, what it cannot see from inside a container, and a place to record what you found."
tags: [security, cis, kube-bench, posture, k3s, pod-security, operations]
status: stable
generated:
  by: hand
  at: 2026-09-29
tockmox:
  classification: public
  audience: [operator]
---

# CIS benchmark scan with kube-bench

**Tockmox can run kube-bench against a control-plane node once a week and leave
the report in the cluster. It is off by default, and this page states plainly
what it has and has not established.** kube-bench checks a node against the CIS
Kubernetes benchmark: file permissions on the credentials k3s writes, the flags
the API server and kubelet run with, and a set of policy items a person has to
judge.

**Two runs have been made on one lab node.** The in-container run is not a
posture. The host run is the one to read: 56 PASS, 5 FAIL, 55 WARN and 14 INFO,
with the five FAILs dealt with under [the host run](#the-host-run-and-what-each-fail-means).
On a lab k3s
node on 2026-09-30, a Job created from the CronJob completed in 7 seconds and
reported 33 PASS, 26 FAIL, 57 WARN and 14 INFO (see [the record](#the-record-you-keep)).
The container has no `journalctl`, so the checks that read the k3s journal did
not run and reported `[FAIL]` or "audit test did not run"; the run also could not
detect the Kubernetes version and assumed a default. Read those 26 FAILs as
unconfirmed; step 3 was done on the host, and 21 of them were the container not
seeing the host. What a run reports on your cluster is yours to record. The reasoning is in
[what is not certified here](#what-is-not-certified-here).

## Read this first

Four things decide whether the report means what it appears to mean:

1. **Inside a container, about half of the automated k3s checks cannot run as
   written.** On k3s the API server, scheduler, controller manager and kubelet
   are one process, so the benchmark finds their flags by running
   `journalctl -u k3s` on the host. The kube-bench image is Alpine with no
   `journalctl`. Counted from the v0.16.0 `k3s-cis-1.9` files, **53 of the 97
   automated checks call it** (130 checks in all; 33 are manual and never
   automated). What a missing or empty answer looks like is a `[FAIL]`: on a
   Linux host that has `journalctl` but no k3s log, the same benchmark
   reported `[FAIL]` for the anonymous-auth and authorization-mode checks, and
   exited 0 (see [what is not certified here](#what-is-not-certified-here)). So
   **a `[FAIL]` from the CronJob is not evidence of a weakness until you have
   confirmed it on the host**, and a `[PASS]` is only as good as the file it
   read. The host route in [step 3](#3-confirm-the-fails-on-the-host--recommended)
   exists for exactly this.
2. **The benchmark is the nearest one, not a match.** kube-bench v0.16.0's
   newest k3s benchmark is `k3s-cis-1.9`, which its own table lists for k3s
   v1.27 to v1.29. The reference platform runs a newer k3s. Items that changed
   between those releases are checked against the wrong expectation.
3. **It scans one node.** The pod lands on a control-plane node and reads that
   node's files and processes. A three-server cluster is three scans, and the
   agent nodes' files are not read at all.
4. **A completed Job means the scanner ran, not that the cluster passed.**
   kube-bench exits 0 whatever it found. The Job goes red only when the scan
   itself failed: it could not be scheduled, was refused admission, or hit its
   deadline.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| The **policy** and **selfcheck** layers deployed | The policy layer creates the namespace and its network policy; the selfcheck layer creates the CronJob | `kubectl -n argocd get applications tockmox-policy tockmox-selfcheck` shows both `Synced` |
| A **k3s** control-plane node labelled `node-role.kubernetes.io/control-plane=true` | The pod is scheduled with that node selector | `kubectl get nodes -l node-role.kubernetes.io/control-plane=true` lists at least one node |
| Permission for a namespace that admits `privileged` pods | The Job uses `hostPID` and `hostPath` (see [where it runs](#where-it-runs-and-why-that-namespace)) | You control the cluster's Pod Security configuration, and no policy engine forbids host mounts |
| Your site repository, with push access | Turning it on is a values change, and a change made anywhere else is reverted | `git push --dry-run`, run inside your site repository checkout, succeeds |

**Where each command runs:** **WORKSTATION** (with `kubectl` and your site
repository) and, for step 3, **NODE** (a control-plane node, over SSH).

## Where it runs, and why that namespace

kube-bench has to see the host's process table and read the files k3s keeps its
credentials and TLS in. In Kubernetes terms that is `hostPID: true` and
read-only `hostPath` volumes. **The Pod Security Standards refuse both at the
baseline level**, so a namespace that admits this Job has to admit
`privileged`, the loosest level, and nothing tighter will do.

Tockmox does not loosen `tockmox-selfcheck` to fit. The scan gets a namespace of
its own, **`tockmox-kube-bench`**, created by the policy layer only when the scan
is on, and labelled `pod-security.kubernetes.io/enforce: privileged` (with
`warn` and `audit` at `restricted`, as on every Tockmox namespace, so each run
records that the scanner exceeds restricted). Nothing else lives there, so the loosening is as
small as it can be and the heartbeat and blackbox exporter in
`tockmox-selfcheck` keep the `restricted` enforcement they carry from 0.7.0.

What the pod is and is not:

- It **runs as root**, because the credentials it inspects are root's and mode
  0600, and it is the only pod in this repository that does. It is **not**
  `privileged`: every capability is dropped, privilege escalation is off, the
  root filesystem is read-only and the seccomp profile is the runtime default.
- It mounts only the host paths in `kubeBench.hostMounts` and
  `kubeBench.extraHostMounts`, **all read-only**. The defaults are
  `/var/lib/rancher/k3s`, `/etc/rancher/k3s` and `/var/lib/cni`. Upstream's
  generic job mounts more (`/etc/systemd`, `/lib/systemd`, `/usr/bin` and
  others) for a kubeadm layout that k3s does not have; they are left out on
  purpose, so a check that reads one of them reads the container's own copy and
  says nothing about the node. The k3s paths were chosen from the paths the
  `k3s-cis-1.9` files name, not from a run.
- It has **no ServiceAccount token** and, in its namespace, a default-deny
  NetworkPolicy in both directions. The scan needs no network.
- **A cluster-wide admission control can still refuse it.** A namespace label
  overrides a cluster default, but it does not stop Kyverno, Gatekeeper, or a
  Pod Security exemption list that removes the namespace. If the Job never
  starts, `kubectl -n tockmox-kube-bench get events` names the refusal.

## 1. Turn it on ... Optional

Optional, and off by default. What you get is a weekly report in the cluster
that you have to read; what you lose by not doing it is nothing the platform
depends on. If you decline it, nothing on this page applies.

It takes **two keys, one in each layer**, because the layers are separate
Helm releases and neither can create the other's objects. The policy layer
owns the namespace and the network policy; the selfcheck layer owns the
CronJob. Turning on only one is safe and visible: with only the selfcheck key
the sync fails because the namespace does not exist; with only the policy key
you have a privileged namespace with nothing in it.

**YOU SUPPLY:** nothing site-specific. In your site repository, in
`site/values/policy.yaml`:

```yaml
apps:
  kube_bench:
    enabled: true
```

and in `site/values/selfcheck.yaml`:

```yaml
apps:
  kube_bench:
    enabled: true
```

The other settings are under `kubeBench:` in `charts/tockmox-selfcheck/values.yaml`,
each with the reason for its default. The ones you may want to change:
`schedule` (weekly, Sunday 03:23 in your `global.timezone`), `benchmark` (the
name must exist in the image; a name it does not contain fails the Job),
`targets` (empty runs all five: master, etcd, controlplane, node, policies),
`nodeSelector` and `tolerations`, and `extraHostMounts` for a k3s with a custom
`--data-dir`. If you rename the namespace, set `namespaces.kube_bench` to the
same value in both files.

Commit and push. ArgoCD applies both.

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get namespace tockmox-kube-bench --show-labels
kubectl --context "$KUBE_CONTEXT" -n tockmox-kube-bench get cronjob,networkpolicy
```

The namespace exists and its labels include `pod-security.kubernetes.io/enforce=privileged`.
The second command lists the `tockmox-kube-bench` CronJob and a `default-deny-all`
NetworkPolicy. A missing namespace with a failed `tockmox-selfcheck` sync means
you turned on the selfcheck key without the policy key.

**Air-gapped:** the image `docker.io/aquasec/kube-bench:v0.16.0` is in
`images.txt`, so mirroring the list mirrors it
([air-gap § mirror the images](../deployment/airgap.md#2-mirror-the-images--required)).
It is pinned by tag, not by digest.

## 2. Run one now instead of waiting a week ... Required

Do this once when you turn it on, to see the scan run before you rely on the
schedule.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" -n tockmox-kube-bench create job --from=cronjob/tockmox-kube-bench kube-bench-manual-1
kubectl --context "$KUBE_CONTEXT" -n tockmox-kube-bench wait --for=condition=complete job/kube-bench-manual-1 --timeout=600s
kubectl --context "$KUBE_CONTEXT" -n tockmox-kube-bench logs job/kube-bench-manual-1 | grep -E '^[0-9]+ checks (PASS|FAIL|WARN|INFO)'
```

**Success condition:** the `wait` returns, and the last command prints one
four-line summary per target that ran (`N checks PASS`, `N checks FAIL`,
`N checks WARN`, `N checks INFO`). If `wait` times out, the scan did not
complete: read
`kubectl -n tockmox-kube-bench describe job kube-bench-manual-1` and
`kubectl -n tockmox-kube-bench get events`. The usual causes are a namespace
that does not admit the pod, no node matching the selector, or a host path that
does not exist on the node.

The summary counts are **not a verdict** (see [read this first](#read-this-first)).
They are the starting point for step 3.

The report is the pod's log. It stays for as long as the finished Job does
(three successful and three failed Jobs by default, so about three weeks of
weekly runs). The observability layer's Alloy may also collect it into Loki,
which would keep it longer; that was not checked for this namespace.
**Nothing turns the counts into metrics, and no alert is attached to them.**

## 3. Confirm the FAILs on the host ... Recommended

**Recommended, because the container cannot see most of what the k3s benchmark
asks about.** Take the list of `[FAIL]` lines from the Job and run the same
benchmark on the control-plane node itself, where `journalctl` and the real
process table are present:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" -n tockmox-kube-bench logs job/kube-bench-manual-1 | grep -E '^\[FAIL\]' > kube-bench-container-fails.txt
wc -l < kube-bench-container-fails.txt
```

**NODE** ... a control-plane node. `kube-bench` is a single static binary
published on its releases page, and the tarball carries the `cfg` directory the
benchmark files live in. **YOU SUPPLY:** the architecture (`amd64` or `arm64`)
and a way to get the file onto the node (a site with no uplink carries it in
like any other artifact, and should check it against the release's
`kube-bench_0.16.0_checksums.txt`).

```bash
export KB_ARCH=YOUR_ARCH
tar xzf "kube-bench_0.16.0_linux_${KB_ARCH}.tar.gz"
sudo ./kube-bench run --benchmark k3s-cis-1.9 --config-dir "$PWD/cfg" --config "$PWD/cfg/config.yaml" > kube-bench-host.txt
grep -E '^[0-9]+ checks (PASS|FAIL|WARN|INFO)' kube-bench-host.txt
grep -E '^\[FAIL\]' kube-bench-host.txt
```

**Before you read 5.1.3 and 5.1.6, check the node has `jq`** (`command -v jq`).
Both audits pipe through it; without it they fail on every role and every pod
and measure nothing ([why](#the-host-run-and-what-each-fail-means)). A static
`jq` binary from its release page, checked against the published checksum and
put on `PATH` for this one run, is enough.

**Success condition:** the host run prints its own summary. A `[FAIL]` that
appears in both runs is a finding to act on. A `[FAIL]` only in the container's
list was the container not seeing what the host sees. **This comparison is the
procedure.** It was done twice on the lab node, and the result is in
[the host run](#the-host-run-and-what-each-fail-means).

## 4. Fix it or waive it, and write down which ... Required

Every `[FAIL]` that survives step 3 is one of two things, and each needs a
sentence in [the record](#the-record-you-keep): **fixed** (say where: a k3s
config change, a site value, a file mode on the node) or **waived** (say why the
risk is accepted, and what would end the waiver). A scan nobody reads and a
waiver nobody wrote down look the same to whoever audits the cluster next.

Several items are answered elsewhere in this documentation, and the report will
raise them:

| The benchmark asks about | Where Tockmox states its position |
|---|---|
| Encryption of Secrets at rest | [Prepare a fresh cluster](../deployment/fresh-install.md) installs k3s with `--secrets-encryption` |
| API audit logging | [Audit logging](../administration/audit-logging.md) |
| Pod Security | Labelled `warn` and `audit`, not enforced, and this scan's own namespace is the one that deliberately admits `privileged`. See the policy layer's README (`charts/tockmox-policy/README.md`) and [architecture](../architecture.md) |
| NetworkPolicy | The policy layer, [architecture § the nine layers](../architecture.md#the-nine-layers) |
| Kernel and kubelet hardening flags | Not stated by Tockmox. They are k3s configuration on the node, outside the charts |

Do not edit the cluster to make a check pass. A change made with `kubectl` is
reverted by ArgoCD, and a change to the node is the node's own configuration
management, not this repository's
([day-2 § the one rule](day-2.md#the-one-rule)).

## The record you keep

Fill this in from your own runs and keep it in your site repository. The rows
below are the lab runs made so far; they are here to show what the counts
look like, not as a baseline for your cluster.

| Date | Cluster, k3s version | kube-bench, benchmark | Target | PASS | FAIL | WARN | INFO | Where the FAILs are dealt with |
|---|---|---|---|---|---|---|---|---|
| 2026-09-30 | Lab, single node, v1.36.4+k3s1 | v0.16.0, in-container, **`journalctl` missing** | master | 17 | 21 | 12 | 9 | Not confirmed on the host |
| 2026-09-30 | same | same | etcd | 0 | 0 | 7 | 0 | Not confirmed on the host |
| 2026-09-30 | same | same | controlplane | 0 | 0 | 5 | 0 | Not confirmed on the host |
| 2026-09-30 | same | same | node | 16 | 1 | 2 | 5 | Not confirmed on the host |
| 2026-09-30 | same | same | policies | 0 | 4 | 31 | 0 | Not confirmed on the host |
| 2026-09-30 | same | same | **total** | **33** | **26** | **57** | **14** | In-container run with the `journalctl` caveat: not a posture |
| 2026-10-03 | Lab, single node, v1.36.4+k3s1 (MicroOS) | v0.16.0, **on the host**, `k3s-cis-1.9` | all five targets | 56 | 5 | 55 | 14 | 1.1.20, 1.2.26 below; 5.1.3 and 5.1.6 did not measure (no `jq` on the host) |
| 2026-10-04 | Same node, 0.7.1-rc2 installed | v0.16.0, **on the host**, `k3s-cis-1.9`, a static `jq` on `PATH` | all five targets | 56 | 5 | 55 | 14 | the same five ids; what each one now lists is below |

Where the 26 in-container FAILs sit, counted from the lab log: 1 in 1.1 (file
permissions), 14 in 1.2 (API server flags), 4 in 1.3 (controller manager), 2 in
1.4 (scheduler), 1 in 4.2 (kubelet) and 4 in 5.1 (RBAC policies). Of those, the
20 in 1.2 to 1.4 are the group that reads the k3s journal; the 1.2.1
(anonymous-auth) and authorization-mode checks among them are ones k3s is
expected to satisfy (INFERRED, not confirmed on the host). The other 6 are not
explained by the missing journal and need the host comparison like any other.

And for each `[FAIL]` that stays: the check number, `fixed` or `waived`, the
reason, the date, and the condition that ends a waiver.

## The host run, and what each FAIL means

**Route.** On 2026-10-03 at 19:36 UTC, on the lab node (single node, k3s
v1.36.4+k3s1, MicroOS), a privileged pod with `hostPID` and the host's root
filesystem mounted entered PID 1's namespaces with `nsenter` and ran kube-bench
v0.16.0 with `--benchmark k3s-cis-1.9`, the command in
[step 3](#3-confirm-the-fails-on-the-host--recommended). The tarball was checked
against the release's checksums file. `journalctl` was present on the host. The
pod was removed afterwards. This was a rehearsal install, not the install the
release was gated on.

**Result: 56 PASS, 5 FAIL, 55 WARN, 14 INFO.** Against the in-container run's 33
PASS and 26 FAIL, 21 FAILs were the container not seeing the host: the 20 in
1.2 to 1.4 that read the journal, and 4.2, which no longer fails. The 1.2.1
(anonymous-auth) and authorization-mode checks pass on the host, as
[the in-container record](#the-record-you-keep) expected. Five FAILs remain:

| Check | What it wants | Why it fails here | Position |
|---|---|---|---|
| 1.1.20 | PKI certificate files (`.crt`) at mode 600 or stricter | All 13 files in `/var/lib/rancher/k3s/server/tls/` read `644` (2026-10-04) | **Operator remedy, not done by Tockmox** |
| 1.2.26 | `--etcd-cafile` set on the API server | On this node k3s runs on its SQLite datastore through kine: the API server's flags are `--etcd-servers=unix://kine.sock` and no CA, because there is no etcd to verify | **Accepted** |
| 5.1.3 | No wildcards in Roles and ClusterRoles, except the ones k3s exempts | Eight roles listed, named below | **Deferred, per role** |
| 5.1.5 | Default service accounts not used | Only namespaces the charts do not create are listed | **Fixed in 0.7.1 for every chart-created namespace** |
| 5.1.6 | Tokens mounted only where needed | Vendored pods that call the API, the three Tockmox pods that need a token, and the cluster's own components | **Fixed in 0.7.1 for Tockmox's own pods; the rest listed below** |

**The host has no `jq`, and two of these checks need it.** The audits for 5.1.3
and 5.1.6 pipe through `jq`. On a host without it (MicroOS ships none) every
line reads `jq: command not found` and every role and pod is scored
non-compliant, so both checks FAIL whatever the cluster holds. The 2026-10-03
run measured nothing for those two. Put a static `jq` on `PATH` for the run (the
2026-10-04 run used the `jq-linux-amd64` 1.7.1 release binary, checked against
its published `sha256sum.txt`) and read the two checks' detail with `--json`.

**1.1.20, operator remedy.** The file permissions of what k3s writes under
`/var/lib/rancher/k3s` are the node's configuration, not this repository's (see
[step 4](#4-fix-it-or-waive-it-and-write-down-which--required)), so Tockmox
neither changes them nor can. The benchmark's own remediation is
`chmod -R 600 /var/lib/rancher/k3s/server/tls/*.crt`, run on the control-plane
node. The files are certificates and the private keys have their own check
(1.1.21), which passes, so the exposure the check guards against is small. If
you apply the remedy, read the modes again after the next k3s restart and after
a certificate rotation, because whether k3s writes them back at 644 has not been
checked. Record it as `fixed` with the date, or `waived` with that reason.

**1.2.26, accepted.** The benchmark's own remediation text says that by default
k3s provides the etcd certificate authority file itself and that the flag should
be absent unless you supplied your own CA. Read off the node on 2026-10-04 (the
audit's own command, `journalctl -m -u k3s | grep 'Running kube-apiserver'`):
the API server runs with `--etcd-servers=unix://kine.sock`, and
`/var/lib/rancher/k3s/server/db/` holds `state.db`. A single server started
without `--cluster-init` keeps its state in SQLite behind kine, a local socket
with no certificate to check, so the flag has nothing to point at. The waiver
ends if you start k3s with `--cluster-init` (embedded etcd), run external etcd,
or pass your own `etcd-cafile`: run the check again then, because it measures
something real there.

**5.1.3, deferred, role by role.** The benchmark exempts a list of k3s roles
(`k3s-cloud-controller-manager`, `local-path-provisioner-role`, `cluster-admin`
and several `system:controller:*` roles) and flags the rest. With `jq` present,
the 2026-10-04 run flagged eight:

| Role | Where it comes from | Position |
|---|---|---|
| `tockmox-argo-admin` (Role, `tockmox-devops`) | Tockmox: admins of Argo Workflows | Deferred: the wildcard is the verbs on the Argo Workflows kinds; narrowing them is a product change with its own test |
| `tockmox-diagnostic-readonly` (ClusterRole) | Tockmox: the read-only diagnostic identity | Deferred: read the rule that carries the `*` before deciding; the role grants no write verb |
| `longhorn` (Role) and `longhorn-role` (ClusterRole) | Vendored Longhorn | Upstream's RBAC; Tockmox does not rewrite it |
| `tockmox-platform-metallb-pod-lister` (Role) and `tockmox-platform-metallb:speaker` (ClusterRole) | Vendored MetalLB | Upstream's RBAC |
| `argocd-application-controller`, `argocd-server` (ClusterRoles) | ArgoCD, a prerequisite | Not Tockmox's; ArgoCD's controller needs `*` on `*` by design |

None is fixed or waived yet. The two Tockmox rows are the ones this repository
can change.

**5.1.5 and 5.1.6, changed in 0.7.1.** Tockmox's own pods now each run as a
service account of their own, with the token mount off unless the pod calls the
Kubernetes API (the restore drill and the Garage bootstrap Jobs do, and say so
in their templates), and every namespace the charts create renders its `default`
service account with the token mount off. Namespaces the charts do not create
(`kube-system`, `longhorn-system`, `cert-manager`, `argocd` and the like) and
pods from vendored charts that expose no setting for it are untouched, so these
two checks still FAIL there. The host re-run on 0.7.1-rc2 (2026-10-04, with
`jq`): **5.1.5** lists only `argocd`, `default`, `kube-node-lease`, `kube-public`
and a lab harness namespace; every namespace the charts create is compliant.
**5.1.6** lists ArgoCD, k3s and sealed-secrets pods (prerequisites), vendored
pods that call the API (Longhorn, cert-manager, CloudNativePG and its database
pods, MetalLB, kured, the snapshot controller, Traefik, Alloy, Grafana, Loki,
kube-state-metrics, the Prometheus operator, Alertmanager and Prometheus, Argo
Workflows, the Authentik worker, the blackbox exporter), and the three Tockmox
pods that keep a token by design (the restore drill and the two Garage Jobs). No
other Tockmox pod is on it.

**After an upgrade, restart what still holds a token.** A pod's token mount is
fixed when the pod is created. Pods that run as `default` in a chart-created
namespace and that the upgrade did not restart keep the token they started with,
and 5.1.6 lists them until they restart: on the 0.7.1-rc2 upgrade test those
were LiteLLM, the Open WebUI redis and a site application. The token is bound to
no role, so it grants nothing; restart them to clear the finding.

## Turning it off

Remove the two keys (or set both `enabled` to `false`) and push. The CronJob and
the namespace with its network policy are removed by the next sync; finished
Jobs are removed with the CronJob. A Job you created by hand in step 2 is owned
by the CronJob and goes with it.

## What is not certified here

**Executed:** on 2026-09-29, on a Linux VM that is not a k3s node, the
kube-bench v0.16.0 binary (linux arm64, from its release tarball) was run with
`--benchmark k3s-cis-1.9` against that tarball's own `cfg`. It exited 0 while
reporting 31 `[FAIL]` for the master target; it printed a warning that it could
not find `kubectl` or `kubelet` even though `--benchmark` was named; and its
`[FAIL]` lines included 1.2.1 (anonymous-auth) and 1.2.6 to 1.2.8
(authorization mode), on a host with `journalctl` but no k3s log. That
establishes the shape of the output and that a check whose evidence is absent
reports `[FAIL]`. It says **nothing** about any k3s cluster, and the counts are
not a posture.

**Counted, not run:** "53 of 97 automated checks call `journalctl`, of 130" was
counted by parsing the five files under `cfg/k3s-cis-1.9` in the v0.16.0
release, checking each check's `audit` and `audit_config`, on 2026-09-29.

**Rendered, not run:** the CronJob, namespace and NetworkPolicy render, lint,
and pass the repository's gates (ghost-policy, netpol-selector, capability and
schema). Nothing was applied to a cluster.

**Inferred, not observed:**

- That the Alpine image has no `journalctl`, read from its Dockerfile (`bash`,
  `findutils`, `gcompat`, `jq`, `kubectl`, `openssl`, `procps`), not from a pod.
- That the journal-dependent checks report `[FAIL]` inside the container the
  way they did on the host without a k3s log.
- That a root user with every capability dropped can read the mode-0600 files
  under `/var/lib/rancher/k3s` (owner access needs none) and that
  `readOnlyRootFilesystem` with an empty `/tmp` is enough for the scanner.
- That `kubectl`'s attempt to detect the version fails fast with no token and no
  route, rather than waiting for a timeout.
- That `kubectl create job --from=cronjob/...` works under ArgoCD without being
  pruned.
- That the three host paths are the right minimum for k3s, and that a path
  missing on the node fails pod start rather than mounting an empty directory.

**The benchmark does not match the platform:** no k3s benchmark in v0.16.0
targets the k3s version the reference platform runs. Whether the newer
`k3s-cis-1.10` files on the project's main branch (not in any release as of
2026-09-29) fit better is not something this change tested, and using them would
mean an image built from main.

**The task behind this page** asks for the posture measured on the lab, with
pass, warn and fail counts and every FAIL fixed or waived. The counts are in the
record, from host runs on one node. **It is not fully done:** 1.1.20 and 5.1.3
have no recorded fix or waiver of your own, 1.2.26 is accepted for a node on
k3s's SQLite datastore only, and the host runs are one node.

## Next

- [Audit logging](../administration/audit-logging.md) ... one of the items the
  scan will raise
- [Day-2](day-2.md) ... where a fix to the cluster belongs
- [Monitoring](monitoring.md) ... what is watched, and what is not
- [Install with no internet access](../deployment/airgap.md) ... mirroring the
  scanner's image

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

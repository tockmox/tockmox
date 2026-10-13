---
okf_version: "0.2"
type: HowTo
title: "Security Posture Probe"
description: "Install the experimental posture-probe add-on, read what it found, and know exactly what its read-only role and its network policy allow it to do."
tags: [posture-probe, add-on, security, networkpolicy, rbac, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-08
tockmox:
  classification: public
  audience: [operator]
---

# Security Posture Probe

The Security Posture Probe answers one question with evidence: **does what the
cluster actually enforces match what you declared it should?** For every row
you declare ("the AI namespace cannot reach the platform namespace", "the
diagnostic account cannot list Secrets") it reports three columns:

| Column | What it is |
|---|---|
| intent | what you declared: allow or deny |
| config | what the NetworkPolicies say, evaluated from the objects themselves |
| observed | what a pod in the source namespace actually reached, by a connect-only test |

A row where intent says deny and the cluster allowed it is **drift**, and the
report says why: **config** (the policies never expressed your intent, which a
config scanner reading your intent could also find) or **enforcement** (the
policies deny it and the cluster allowed it anyway, which no config scanner can
see). The run's exit code is a gate you can wire into change control.

> **Experimental in 0.8.0, and off by default.** It is an add-on: a separate
> chart under `addons/posture-probe/` that you install on its own. It is not one
> of the nine layers, nothing in the platform depends on it, and its values keys
> may change before they are marked stable.

## What it may do, by construction

The probe observes and reports. Its safety is the role it runs under, not a
promise about its code.

**The differential Job's identity** (`posture-probe`, in the add-on's own
namespace) holds exactly this, and nothing else:

| Verb | On | Where |
|---|---|---|
| get, list | namespaces | cluster-wide, for their labels |
| get, list | pods, networkpolicies | the declared namespaces only |
| create | selfsubjectaccessreviews | the authorization oracle: a create there returns a verdict and changes nothing |

No update, patch, delete or deletecollection anywhere. No Secrets, no
`pods/exec`, `pods/attach` or `pods/log`, no impersonate, escalate or bind, no
wildcard. At the start of every run the Job asks the oracle whether it holds any
write on the kinds that matter, in every declared namespace and cluster-wide,
and refuses to run (exit 1) if the answer is ever yes. `tools/check-posture-probe.sh`
refuses a render that adds any of them.

**The collectors** run in each measured namespace as that namespace's `default`
ServiceAccount, under that namespace's own NetworkPolicies: the vantage of an
ordinary workload there. They open a TCP connection to each declared endpoint
and close it. No byte is sent after the handshake and nothing is authenticated
against. They test only the endpoints the chart declares; they never scan or
sweep. An identity vantage runs as a named ServiceAccount and asks the
authorization oracle what that account may do; it never performs any of it.

**It waits until its own pod is policed.** A new pod is not covered by the
namespace's NetworkPolicies the instant it starts: on k3s's embedded policy
controller a lab measured about a second in which egress default-deny did not
hold and allow rules naming the pod did not hold either. A reading from that
window describes neither your policy nor its enforcement. So each collector
measures in rounds and reports only once every **control** reads what it must
(by default, each of the namespace's own declared egress and API-egress deny
rows must read denied) and every reading has held for `settle.stableRounds`
rounds spanning `settle.minSpanSeconds`. A collector that has not settled by
`settle.maxSeconds` reports nothing it read, and its rows make the run exit 1. An identity vantage opens no connection, so it has nothing to settle: the
namespace's controls apply to the network collector beside it, not to it.
A deny row that is genuinely not enforced therefore surfaces as "could not
settle" for that namespace, with the control named in the report's
`run.notSettled`, rather than as a clean run.

**Visible by design.** Every run is a set of named Jobs, and the review calls
land in the API audit log. If your monitoring does not notice a burst of
connection attempts and access reviews, that silence is itself a finding.

**The report is sensitive.** A map of what can reach what is an attacker's
shopping list. It is written only to the add-on's own volume, readable only by
whoever can run a pod in the add-on's namespace; the Job's log carries counts,
never findings. Collectors hand their results over in the pod's termination
message, not its log, and their finished pods are removed once the differential
has read them. Restrict the add-on's namespace to the people who review posture.

## Build the image

The probe ships as source, like every Tockmox image. Build it from the add-on's
Dockerfile and push it to the registry your cluster pulls from:

```text
docker build -t registry.example.com/tockmox/posture-probe:0.1.0 addons/posture-probe
docker push registry.example.com/tockmox/posture-probe:0.1.0
```

The image is the Python standard library on `python:3.12-alpine` and nothing
else: no package is installed at build time and nothing is fetched at run time.
It runs as user 65534 with a read-only root filesystem.

## Install it

Give it its own namespace and its own values file. As an Argo CD Application in
your site repository:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: posture-probe
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: tockmox-posture
  sources:
    - repoURL: https://github.com/tockmox/tockmox.git
      targetRevision: v0.8.0
      path: addons/posture-probe/chart
      helm:
        valueFiles:
          - $site/site/values/posture-probe.yaml
    - repoURL: https://git.example.com/you/your-site.git
      targetRevision: main
      ref: site
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

The second source is your site repository, as in the layer Applications the
installer writes; the values file is `site/values/posture-probe.yaml` there and
is the add-on's alone. The chart creates objects in every measured
namespace (a CronJob, a ConfigMap, a Role and RoleBinding, and the stand-in
listener), so the Application's project must be allowed to deploy there.

The values that matter:

```yaml
enabled: true
image: registry.example.com/tockmox/posture-probe:0.1.0
networkPolicy:
  apiServer: [{cidr: 192.0.2.10/32, port: 6443}]
schedule: "41 3 * * *"
```

`networkPolicy.apiServer` is where the differential may reach the Kubernetes
API; it falls back to `global.lanCIDR` on 6443 when that is set. When it is one
`/32`, it is also the address the config column uses for the API-egress rows;
otherwise set `targets.kubeApi.policyIp`, or those rows say `n/a` in the config
column rather than guessing.

The default intent, `intent.preset: tockmox-reference`, is 63 rows derived from
the policy layer's own stated design, across the seven Tockmox namespaces it
measures by default. A preset row that names a namespace you do not measure (a
capability you declined, say) is dropped and counted in the report as
`run.presetRowsDropped`. Add rows of your own under `intent.rows`; one of yours
that names a namespace, target or identity this release does not measure fails
the render rather than reading "could not run" on every run.

### What it renders

| Where | What |
|---|---|
| the add-on's namespace | the differential CronJob, its ServiceAccount, the report volume, the config ConfigMap, a default-deny NetworkPolicy and the differential's egress policy |
| each measured namespace | a collector CronJob, its endpoints ConfigMap, a read Role and RoleBinding for the differential, and (with `standins.enabled`) a stand-in listener Deployment and Service |
| each identity vantage's namespace | an identity collector CronJob |
| cluster | one ClusterRole and binding: namespaces get/list, and the access-review create |

The stand-ins serve an empty directory on `targets.standinPort` so every
namespace-to-namespace row has a known listener: a refused connection to a known
listener is a policy reject, and to an unknown port it proves nothing. No
NetworkPolicy the add-on ships selects a collector or a stand-in, because one
would change what is being measured.

## Run it now

The CronJobs run on `schedule`. To run once, as your own identity, and copy the
report out:

```text
addons/posture-probe/run-now.sh --context <your-context> --out ./posture-reports
```

It creates one Job from each CronJob under a single run id, waits for the
differential, prints its log (counts only) and its exit code, and with `--out`
copies the report through a short-lived reader pod using `exec`, so the report
never passes through a container log.

## Read the result

| Exit code | Meaning |
|---|---|
| 0 | clean: no drift, and every declared row was observed |
| 1 | could not run: an error, a write-capable identity, or any declared row with no usable observation |
| 2 | drift: at least one row where the cluster allowed what you declared it should deny |

A drift run is a failed Job, so the Kubernetes job-failure alert you already
have fires on it. A probe that never ran cannot read as clean: an unobserved row
is exit 1, never 0. Rows where the intent is allow and the cluster denied it are
reported as `unintended-deny` and do not set the exit code.

## The report contract

The report and the exit code are a published, versioned interface, so a gate
runner or another tool can depend on them:

- **Schema:** `addons/posture-probe/schema/report-v0.schema.json`, identified as
  `urn:tockmox:posture-probe:report:v0`. Every report carries `schemaVersion`
  and `schema`.
- **Versioning:** within `v0`, fields and enum values are only added, never
  removed, renamed, retyped or repurposed. Anything else is `v1`, published as a
  new file beside this one. Ignore fields you do not know.
- **Exit code:** the process exit code and `summary.gateExit` are always equal,
  and take only the three values above.

The differential Job validates every report against that schema before it
stores it and exits 1 rather than store one the schema rejects. To check a
report you hold:

```text
docker run --rm -v "$PWD/posture-reports:/r:ro" registry.example.com/tockmox/posture-probe:0.1.0 validate /r/report-<run-id>.json
```

The same engine runs over files, for CI: `posture-probe gate OBSERVED INTENT`
prints the report and exits with the gate code.

## What it may reach

| From | To | Why |
|---|---|---|
| the differential | DNS in `kube-system`, and `networkPolicy.apiServer` | its reads and the access reviews; nothing else, and nothing reaches it |
| a collector | the declared endpoints only | the measurement itself, under the measured namespace's own policies |
| a stand-in | nothing it initiates | it only listens |

The default endpoints are each measured namespace's stand-in, `1.1.1.1:443` as
the internet egress test (set `targets.internet.host` to another address, or
empty to drop it and the rows that name it) and the in-cluster API Service.

## Uninstalling

Remove the Application. The report volume is kept on purpose (deleting evidence
is your decision): delete the `posture-probe-reports` claim in the add-on's
namespace when you mean to.

## What is not certified here

- **Proven on a throwaway cluster, as a prototype.** The engine, the collector
  and the 63-row intent were run on 2026-10-04 against a disposable single-node
  k3s cluster carrying the policy layer: reachability accuracy held on 3 of 3
  controls, a real drift into the platform namespace was found that a widely
  used configuration scanner passed, and the gate went red on injected drift
  and green on revert. This add-on packaging of it (the CronJobs, the
  termination-message handover, the in-cluster write check) has been rendered,
  validated and unit-tested against a fake API; whether a lab run proves it end
  to end is stated in the release notes of the version you install.
- **The settling window is measured on one controller.** About one second, on
  k3s's embedded kube-router, on one lab. Other network plugins may program
  policy faster or slower; the stability rule waits out what it observes, and
  `settle.maxSeconds` bounds how long.
- **CNI-dependent rows say so.** Whether an `ipBlock` matches a pod address is
  left to the network plugin by the Kubernetes specification; a row decided
  that way carries a note. A service mesh in the path is not modelled.
- **Declared rows only.** A path no row names is not measured, and only the
  stand-in port and the declared targets are tested; a policy that opens
  another port leaves the gate green.
- **Not continuous monitoring and not intrusion detection.** It is a scheduled
  Job that measures and reports.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

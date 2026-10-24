---
okf_version: "0.2"
type: Reference
title: "ArgoCD, and why Tockmox does not manage it"
description: "Why ArgoCD is a prerequisite rather than a component, what the 2.6 floor is for, why the raw-manifest install needs server-side apply, and what a missing repository credential looks like."
tags: [argocd, gitops, prerequisites, multi-source, credentials]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# ArgoCD, and why Tockmox does not manage it

ArgoCD is the one component Tockmox depends on completely and installs not at
all. This page is the reasoning behind that, and the traps in the parts you
therefore own.

The install procedure is in
[prepare a fresh cluster § install ArgoCD](../deployment/fresh-install.md#6-install-argocd),
or, for a cluster you already run,
[prepare a cluster you already have § check 5](../deployment/existing-cluster.md#check-5-argocd).

## Why it is a prerequisite

Two properties, and a thing qualifies as a Tockmox prerequisite if it has
either:

- **It cannot install itself.** ArgoCD is what applies everything else. There is
  no earlier loop to apply ArgoCD.
- **It must exist before the GitOps loop can read your repository.** Nothing
  Tockmox ships is visible to the cluster until something is watching the site
  repository.

Self-managing ArgoCD ... pointing it at a repository that contains its own
manifests ... is a known failure mode rather than a clever one. The controller
deletes itself partway through an upgrade and there is nothing left running to
finish the job. Install it out of band and leave it alone.

That test is also why cert-manager, MetalLB, storage and ingress are **not**
prerequisites here, though other platforms treat them as such. They install
themselves fine and nothing needs them before the first sync, so Tockmox ships
them as wave-2 charts. It is the difference between a three-step manual path
and a seven-step one. The wave ordering is in
[architecture § sync waves](../architecture.md#sync-waves).

## The 2.6 floor is a floor, not a suggestion

The generated Applications are **multi-source**: your values repository rides
alongside the Tockmox charts via a `$site` ref, and ArgoCD composes them at sync
time. Older ArgoCD cannot parse that, and it does not say so ... the failure
reads as a malformed Application rather than as a version problem.

Any current stable release qualifies. The floor exists to rule out the versions
where multi-source did not exist, not to pin a specific one.

> **Unverified against a live cluster.** 2.6 is recorded as the version that
> introduced multi-source Applications. It has not been re-checked against a
> 2.5 install, and nobody deploying today is likely to hit it. Treat it as the
> documented floor rather than as a measured boundary.

## Why Helm is the only documented route

Upstream publishes both a Helm chart and a raw `install.yaml`. Tockmox documents
the chart and only the chart. Three reasons, none of them about security ... the
manifest installs the same objects and is upstream's own supported path:

1. **A second documented path is a second path to test.** The
   [testing standard](../testing-standard.md) says both branches of any
   documented choice get executed. The route people happen to use is exercised
   by use; the one beside it rots silently, and it is the one a stranger picks.
2. **It already happened here.** The raw-manifest command these docs carried
   could not succeed against a current upstream manifest, and nobody noticed,
   because everyone who mattered was using Helm. See below.
3. **The configuration guidance is chart-shaped.** Everything on this page about
   metrics is written as chart values. A manifest reader gets advice that does
   not apply to them, which is the "which of these applies to me" failure the
   [documentation standard](../documentation-standard.md) exists to stop.

Helm is also what the rest of Tockmox is. An ArgoCD installed by chart and
pinned to a version is the same shape as every layer it will go on to manage.

## If you install from the raw manifest anyway

It is a legitimate thing to do and these docs do not test it. One trap is worth
carrying, because the obvious command is broken.

Measured 2026-09-01 on a greenfield cluster, running the previously documented
command verbatim:

```
networkpolicy.networking.k8s.io/argocd-repo-server-network-policy created
networkpolicy.networking.k8s.io/argocd-server-network-policy created
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

Client-side `kubectl apply` records the entire object in the
`kubectl.kubernetes.io/last-applied-configuration` annotation, and annotations
are capped at 262144 bytes. ArgoCD's ApplicationSet CRD is well past that.

**This is not environmental.** A client-side apply cannot succeed against a
current upstream ArgoCD manifest, on any cluster. Server-side apply does not
write the annotation, which is the whole fix:

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

`--force-conflicts` is only needed when an earlier client-side attempt already
created some of the objects ... which is exactly the state anyone who hit the
error above is in.

**Success condition:** `applicationsets.argoproj.io` reports
`Established=True`, and carries **no**
`kubectl.kubernetes.io/last-applied-configuration` annotation.

```bash
kubectl get crd applicationsets.argoproj.io \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
```

The second half is the one worth checking, and it is not decoration: that
annotation is the thing the client-side apply was trying to write, and it is
what overflowed the 262144-byte limit. Its absence is *why* the server-side form
fits where the other one cannot, so checking for it tests the mechanism rather
than just the outcome.

> **Verified against a live cluster, 2026-09-02.** Both halves of this section
> now run in the executed-documentation harness
> (`tests/executed-docs/paths/P02-argocd-server-side-recovery.sh`): the failure
> above was reproduced from the published text, and this recovery command then
> completed and satisfied both conditions. **This admonition previously said the
> corrected command had not been re-run.** That is no longer true, and a stale
> "unverified" marker is its own defect ... it teaches readers to distrust the
> parts of a page that are in fact the best-tested.

## Its metrics are off until you turn them on

**The argo-cd chart ships all three metrics services disabled**, so a stock
install exposes nothing for Prometheus to scrape. Measured on a clean cluster
2026-08-30: `ns/argocd` carries `argocd-server`, `argocd-repo-server`,
`argocd-redis` and `argocd-applicationset-controller`, and not one metrics
endpoint.

That matters more here than it would for most components, because ArgoCD is
what reconciles every layer of this product. When it stops, every other signal
stays green ... the workloads it last applied keep running, so the cluster looks
healthy right up until a failed sync matters.

Tockmox cannot turn this on for you, by the same reasoning that makes ArgoCD a
prerequisite in the first place: it never touches your ArgoCD. Set it on your
own install:

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false      # Tockmox renders the ServiceMonitors
server:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false
repoServer:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false
```

Leave the chart's own `serviceMonitor.enabled` **off** and let Tockmox render
them instead, so they carry Tockmox's labels and land in the monitoring
namespace with everything else.

The Tockmox side needs nothing from you: `apps.argocdMonitoring` follows
`capabilities.observability` (TM-0739), so with observability on it is on. The
only value you may need is where your ArgoCD lives:

```yaml
# tockmox-observability
argocd:
  namespace: argocd        # only if yours is somewhere else
```

That one key renders three ServiceMonitors, the ArgoCD dashboard **and** the
sync-state alert rules together. **If you installed ArgoCD by
[the fresh-install block](../deployment/fresh-install.md#6-install-argocd), its
metrics are already on.** If you installed it some other way and did not turn
them on, the monitors select nothing and the board reads "No data" until you do;
`TockmoxArgoCDMetricsAbsent` deliberately stays silent in that state (it fires
only while ArgoCD's metrics Services exist and no series arrive), so you are
told by the empty board and not by a false alert. Set
`apps.argocdMonitoring.enabled: false` to drop all of it. If you would rather
the chart create its own monitors, set its `serviceMonitor.enabled: true` and
set `apps.argocdMonitoring.enabled: false` ... you will have the scrape and not
the board or the alerts.

The dashboard side of this is in
[monitoring § dashboards](../operations/monitoring.md#dashboards-what-ships-honestly).

## Synced does not mean every layer is on the same commit

Sync waves order the **first** rollout. After that each layer is an independent
Application polling the repository on its own schedule, so for a few minutes
after a push one layer can be running new code while another is still on the
previous commit. Every one of them reports `Synced`, because each is correctly
synced to the revision it last resolved. The status is true and the inference
people draw from it is not.

This matters when a single commit changes two layers that depend on each other.
**Observed 2026-08-14** on the maintainer's cluster: a commit that enabled
Harbor in the devops layer *and* added the NetworkPolicies guarding it in the
policy layer landed devops-first, so Harbor was running before the policies that
guard it existed. Both Applications said `Synced` throughout.

The honest framing: this is a property of GitOps with independent Applications,
not a defect Tockmox can fix in a chart. Sync waves are an ordering constraint
on a *single* reconciliation, not a distributed transaction across nine of them.
Two consequences for anyone operating this:

- **Plan cross-layer changes so the intermediate state is safe.** Either order
  can happen. If one order is unsafe, the change needs splitting into two
  commits with the safe one first.
- **Compare revisions rather than statuses** after any push that spans layers.
  The procedure is
  [day-2 § check which revision each layer is running](../operations/day-2.md#check-which-revision-each-layer-is-running).

## A resource applied in the same sync as its own admission webhook

**Fixed for the platform layer as of 0.5.0**, whose release-gate install
converged with no intervention: every cert-manager.io resource the platform
layer ships now applies at a later sync wave than the webhook that validates it.

The **shape** is general and worth keeping, because it applies to anything you
add yourself. A resource applied while the webhook that validates it is still
starting in the same sync is rejected at admission. Downstream health can then
never arrive, and ArgoCD's automated sync **will not retry a revision whose sync
failed**, so the Application does not self-heal out of it. The symptom is an
Application sitting `OutOfSync / Progressing` with an operation message naming
resources that never become healthy, while the resource itself does not exist in
the cluster at all.

Recovery is to terminate the stuck operation and start one manual sync: by then
the webhooks are up, everything applies, and the layer converges with no further
attention. The commands are in
[troubleshooting § the first platform sync wedges](../operations/troubleshooting.md#the-first-platform-sync-wedges).

Avoiding it in your own resources is a wave assignment: put the custom resource
at a later `argocd.argoproj.io/sync-wave` than the controller and webhook that
validate it. See [architecture § sync waves](../architecture.md#sync-waves).

### The Prometheus operator's webhook, and the rules it validates

The same shape applies to the observability layer, and on the 0.7.0 release
candidate it showed as a red number. The stack's admission webhook validates
every `PrometheusRule`. It ships with `failurePolicy: Ignore` and got its CA
bundle from a Helm post-install Job, which ArgoCD runs as a PostSync hook, after
the sync phase that applies the layer's own rules. On a fresh install each rule
therefore reached a webhook configuration with nothing behind it and was admitted
unvalidated, and the API server counted it:
`apiserver_admission_webhook_fail_open_count` read 66 for each of
`prometheusrulemutate.monitoring.coreos.com` and
`prometheusrulevalidate.monitoring.coreos.com`, and the Admission board's
"Webhook fail-open events" panel showed 66 in red on a healthy cluster.

What the layer does now, in `charts/tockmox-observability/values.yaml` under
`kube-prometheus-stack`, is ordering only. `failurePolicy` stays at the upstream
`Ignore`.

- The two webhook configurations and the CA-bundle Job are **PreSync hooks**, in
  that order, so the webhook has its CA before the sync phase begins.
- Every `PrometheusRule` the layer renders is **sync wave 1**, so it is applied
  only after the operator Deployment (wave 0) is healthy.

**What this does not cover.** Rules shipped by other layers can still be applied
before the webhook answers on a first install, and then fail open and are
counted: `tockmox-policy` (wave 1) and `tockmox-platform` (wave 2) apply before
the operator exists, and `tockmox-exporters` shares the observability layer's
wave. `tools/check-alert-rules.sh` lints every rule we write with promtool in CI.
Expect the fail-open counters on a fresh install to be no higher than twice the
number of rules those layers ship, not zero. A side effect of the ordering: rules
wait for every wave-0 resource of the layer to be healthy, not only the operator.

**Not certified.** Nothing configures ArgoCD's health assessment of
`Application` resources: upstream removed the built-in one in 1.8 and says to
restore it with a customization in `argocd-cm` if you orchestrate app-of-apps
with sync waves
([ArgoCD: resource health](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/)).
Without it the parent Application may not wait for a child layer to be healthy
before it starts the next wave. This page does not claim which behaviour your
ArgoCD has, nor that ArgoCD runs the hooks in the order above; the greenfield
reading of the two counters is the measurement.

## Pointing the generated Applications at your site repository

The installer writes `PLACEHOLDER_SITE_REPO_URL` into every generated
Application instead of a real URL, and you replace it by hand before the first
apply. The procedure is
[install § Phase 2](../deployment/install.md#phase-2--publish-it); the reasoning
is here.

**Why a placeholder rather than asking?** A tool that creates and pushes to
remote repositories on your behalf is a tool worth distrusting. You decide
where your configuration lives.

**Why `sh -c` rather than `sed -i` or `perl`.** `sed -i` takes an argument on
BSD and not on GNU, so a single command cannot satisfy both. Perl can, and the
walkthrough used to reach for it ... but perl is absent from common kubectl and
helm container images, which is exactly where an operator runs this from a jump
host. Writing through a temporary file uses only `sh`, `sed` and `mv`, which
are everywhere.

**How many files carry it.** One per generated Application, plus the root:
`bootstrap/root.yaml`, one `bootstrap/applications/tockmox-<layer>.yaml` per
enabled layer, and `bootstrap/applications/site-apps.yaml`. With all nine
layers on that is eleven, and fewer if you turned a layer off. The installer
counts the files it wrote and prints the number rather than asserting a
constant, because a hardcoded count is one disabled layer away from being
wrong, and a wrong count in a warning about a manual step is worse than no
count: the operator stops looking when they have fixed that many.

## A missing repository credential names nothing useful

ArgoCD clones your site repository on every sync, and your site repository holds
your values. Most people keep it private, which means ArgoCD needs a credential
before the first sync rather than after the first failure.

The failure is worth describing because it does not name its cause. Every
Application goes to `Unknown` with a `ComparisonError`, the message says the
repository is not accessible, and nothing in it distinguishes **no credential**
from **wrong URL** from **revision does not exist**. The generated Applications
are multi-source, so a missing credential on either source produces the same
three words on all nine layers at once.

A credential is a Secret in the ArgoCD namespace carrying one label:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: site-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/you/your-site
  username: git
  password: <a read-only token>
```

Deploy keys work too, with `sshPrivateKey` in place of `username` and
`password`, and an `ssh://` URL.

Three things about it are easy to get wrong:

- **Scope the token to that one repository, contents read-only.** ArgoCD never
  writes to it, so anything broader grants access nothing uses.
- **The `url` must match the `repoURL` in your Applications character for
  character.** A trailing `.git` on one side and not the other is a miss, and
  the resulting error is the same three words.
- **This Secret cannot be sealed and committed**, because it is what grants
  access to the repository the sealed secrets live in. Apply it by hand,
  alongside the sealed-secrets key. See [secrets](secrets.md).

## When ArgoCD cannot read the repository, and what alerts

The failure above is quiet after the first sync as well. A repository credential
that **expires** leaves every Application in `ComparisonError` with sync status
`Unknown`, while Health stays `Healthy`: the workloads Argo last applied keep
running. Nothing is being compared, so `selfHeal` has nothing to heal toward and
`prune` does not run, and a re-pin, a rotation or a fix you push never lands.
Measured on a lab install on 2026-09-17: nine Applications, two and a half days,
every health surface green, an expired fine-grained token the cause.

That is a different state from `OutOfSync`. `OutOfSync` means Argo read the
desired state and it differs, and with `selfHeal` on it acts. `Unknown` means it
could not read the desired state at all.

Tockmox ships an alert for the second one, `TockmoxArgoCDCannotCompare`, in
`tockmox-observability` (`templates/argocd-rules.yaml`):

| Alert | Severity | Fires when |
|---|---|---|
| `TockmoxArgoCDCannotCompare` | critical | an Application has read `sync_status="Unknown"` on `argocd_app_info` for 30 minutes, one alert per Application |
| `TockmoxArgoCDMetricsAbsent` | warning | ArgoCD's metrics Services exist (`kube_service_info`, from kube-state-metrics) but no `argocd_app_info` series has existed for 15 minutes, which means the first alert cannot fire |

The 30 minutes is deliberate: a refresh in flight or a repo-server restart reads
`Unknown` for seconds to minutes and clears. The rule keys on sync status and
never on health, which reads `Healthy` throughout this failure. It does not say
WHY the comparison failed; that is in the Application's
`status.conditions[].message`, and the three usual causes are in the section
above this one.

**It needs ArgoCD's metrics.** The rules render with
`apps.argocdMonitoring`, the same switch as the ArgoCD ServiceMonitors and the
board, and that switch follows `capabilities.observability` (on by default).
But ArgoCD's metrics are off in a stock argo-cd chart (see
[its metrics are off until you turn them on](#its-metrics-are-off-until-you-turn-them-on)),
and without them there is no series for a rule to read. An ArgoCD installed
without metrics gets neither alert, and `TockmoxArgoCDMetricsAbsent` does not
tell you so, because it fires only when the Services exist and the scrape
produces nothing; a rule that fired on "metrics are off" would be a false alert
on every such install. If kube-state-metrics is disabled that alert is silent
too. Such a site learns about an expired credential the way the lab did, until
it turns the metrics on.

What this has and has not been tested on: the expression is unit-tested against
the rendered rule (`tests/rules/argocd-sync.yaml`), both for firing on `Unknown`
and for staying silent on `OutOfSync`, a short blip and a healthy Application.
A broken credential on a live cluster producing an ntfy notification inside the
30 minutes has not been observed yet.

## A static file server fools the git CLI and not the repo-server

This one only bites people serving git repositories internally, which is the
normal shape for a disconnected site. The obvious cheap way to serve bare
repositories is a static HTTP file server. That serves git's **dumb**
protocol, and the git CLI clones from it perfectly, so your own verification
passes:

```console
$ git ls-remote http://git.int.example.com/tockmox.git
0370196c82ccb73029b767b9cb743093316fc2c6	HEAD
```

ArgoCD's repo-server uses go-git, which requires the **smart** protocol, and
fails:

```
ComparisonError: failed to load target state: failed to generate manifest for
source 1 of 2: rpc error: code = Unknown desc = failed to list refs: unexpected EOF
```

That error names neither git nor the protocol, so anyone debugging it goes
looking at the network or at the repository contents. **Serve the smart
protocol.** `git daemon` over `git://` is the smallest thing that works;
`git-http-backend` behind any web server also works. A `file://` path to a bare
repository is also accepted and resolves normally.

Two notes if you are building the git server inside the cluster:

- `alpine/git` ships neither `git-daemon` nor `git-http-backend`. The ArgoCD
  image has both under `/usr/lib/git-core/` and is already on the node, which
  makes it the air-gap-safe choice.
- A bare repository created as root is refused by a server running as another
  uid with `detected dubious ownership`. Set `safe.directory`.

## Related

- [Prerequisites](../deployment/prerequisites.md) ... what to install before Tockmox
- [Installation](../deployment/install.md) ... where the credential is actually applied
- [Architecture](../architecture.md) ... the nine layers and the sync waves
- [Install with no internet access](../deployment/airgap.md) ... the procedure that hits the smart-protocol trap above

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

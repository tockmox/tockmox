<!-- tockmox:banner:begin -->
<div align="center">

<img src="../../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# tockmox-policy

**Sync wave 1** · **Implemented** ... 72 resources

Namespaces, NetworkPolicies, RBAC admission guardrails, PriorityClasses, and the read-only diagnostic identity.

## Why this layer is first

Policy creates the namespaces every other layer deploys into. On an existing
cluster the ordering does not matter because the namespaces are there already;
on a fresh one, getting it backwards fails the sync.

## What it contains

| | |
|---|---|
| Namespaces | Seven, created from `namespaces.create` |
| NetworkPolicies | 43 over seven namespaces |
| Pod Security | `warn` and `audit` at `restricted` on all seven namespaces, and **`enforce` on five** (`ai` and `devops` and `diagnostic_identity` at `baseline`, `authentik` and `selfcheck` at `restricted`). `monitoring` and `platform` carry no enforce label because pods in them need host access by design. Levels are values: `podSecurity`. See the note below |
| ValidatingAdmissionPolicies | 4, plus 4 bindings. One refuses on a stock install (cluster-admin ClusterRoleBindings); the other three audit and warn |
| PriorityClasses | 3 |
| Diagnostic identity | Read-only ServiceAccount and ClusterRole, network-isolated |
| Traefik Middleware | Security headers |

## Adopting into an existing cluster

Namespace defaults carry the reserved `tockmox-` prefix. Override them to your
existing names rather than renaming your namespaces ... a namespace rename
deletes and recreates everything inside it.

```yaml
namespaces:
  ai: ai
  monitoring: monitoring
```

## Which namespaces are guarded

| Flag | Namespace | Default | Covers |
|---|---|---|---|
| `apps.ai_namespace` | `namespaces.ai` | on | Open WebUI and its backing store |
| `apps.monitoring_netpol` | `namespaces.monitoring` | on | The observability and exporters layers |
| `apps.authentik_netpol` | `namespaces.authentik` | on | Authentik and its database |
| `apps.devops_netpol` | `namespaces.devops` | **on** | Argo Workflows ... see below |
| `apps.diagnostic_identity` | `namespaces.diagnostic_identity` | on | The read-only agent identity |
| `apps.platform_netpol` | `namespaces.platform` | on | Traefik, cert-manager, MetalLB, Longhorn, CNPG |
| `apps.selfcheck_netpol` | `namespaces.selfcheck` | on | The heartbeat and its alert rules |
| `apps.kube_bench` | `namespaces.kube_bench` | off | The opt-in CIS scan's namespace (`enforce: privileged`) and its default-deny policy. Pair with `apps.kube_bench` in `tockmox-selfcheck`, which owns the CronJob |

### Pod Security: enforced on five namespaces, not on two

Until 0.7.0 this layer labelled every namespace `restricted` for `warn` and
`audit` and set no `enforce`, so a violating pod printed a warning and ran. From
0.7.0 `enforce` is a values key, `podSecurity.enforce`, with one entry per
namespace key in `namespaces.create`. `["Deny"]` enforces; `["Audit","Warn"]`
observes without blocking ... the same distinction as the admission policies.

Measured against this chart: 7 namespaces carry the warn label, and
5 namespaces carry an enforce label. Which five, and the level each was measured to pass, is
in [architecture § Pod Security](../../docs/architecture.md#pod-security-which-namespaces-refuse-a-pod-and-why-the-others-cannot).
The reason for each namespace's level, including the two that carry none
(Longhorn is privileged by necessity; node agents need `hostPath` and host
namespaces), sits beside the key in `values.yaml`.

`tools/check-pod-security.sh` renders every layer, evaluates every pod template
against the Pod Security Standards, and fails if an enforce label is stricter
than the pods in that namespace pass. Not proven by it: admission on a live
cluster, the pods that operators create from custom resources, and any
workload you add. **Action if a pod of yours is refused:** meet the level, or
set that namespace's key to `""` or a lower level under `podSecurity.enforce`
([troubleshooting](../../docs/operations/troubleshooting.md#a-pod-is-refused-with-violates-podsecurity)).

**One opt-in exception.** With `apps.kube_bench` turned on (off by default), this
layer also creates `tockmox-kube-bench`, labelled `enforce: privileged`, with a
default-deny NetworkPolicy, one more of each than the stock counts above. It is
the namespace for the CIS benchmark scanner, which needs `hostPID` and `hostPath`
and so cannot run in anything stricter. It changes no other namespace's level;
it is the label saying honestly what that one namespace admits. The counts above
are for a stock install. Read [CIS benchmark scan with kube-bench](../../docs/operations/kube-bench.md).

Every namespace this layer creates now carries a bundle. The platform and
selfcheck bundles are new since v0.5.0, whose CHANGELOG published both
namespaces as carrying no NetworkPolicies.

## Policy bundles that guard nothing on a stock install

Four bundles ship off by default. Each targets a namespace no shipped workload
lands in, so with them on, their NetworkPolicies select no pod:

| Flag | Guards | Namespace key |
|---|---|---|
| `apps.forgejo_netpol` | A Forgejo you installed yourself: default-deny, Traefik on 3000, git-SSH on 22, Prometheus scrape | `namespaces.forgejo` |
| `apps.tailscale_netpol` | A Tailscale operator or subnet router you installed yourself: ingress-only default-deny, intra-namespace, Prometheus scrape | `namespaces.tailscale` |
| `apps.syslog_ingest_netpol` | A second Alloy release named `syslog-ingest` listening on 1514, admitting `global.lanCIDR` | `namespaces.monitoring` |
| `apps.harbor_netpol` | A **standalone** Harbor you installed yourself, as its own release in its own namespace. **Not the Harbor this repo ships** ... see below | `namespaces.harbor` |

The reasoning behind each rule is kept in the template comments, because
rederiving "why is it safe to default-deny the namespace that bridges off-LAN
access" is the expensive part. Deleting the rules would throw that away; leaving
them enabled was dishonest. Off plus documented is the third option.

To turn one on, set the namespace key to where your workload runs, add that key
to `namespaces.create` if you want this chart to create it, and set the flag:

```yaml
namespaces:
  create: [ai, monitoring, platform, authentik, diagnostic_identity, selfcheck, devops, forgejo]
  forgejo: forgejo
apps:
  forgejo_netpol: { enabled: true }
```

Enabling a bundle while its namespace name is blank fails the render with a
message naming the flag, rather than emitting policies into nowhere.

### The Harbor case, and how it was closed

`apps.harbor_netpol` shipped **on** for months and never guarded Harbor. Harbor
is a subchart of `tockmox-devops`, and Helm installs subchart resources into
their release's namespace, which the installer sets to `namespaces.devops`.
Rendering `tockmox-devops` with Harbor enabled put zero resources in
`tockmox-harbor`. Four policies, an empty namespace, and a `kubectl get netpol`
that looked correct. (Harbor has since been dropped from core entirely ... see
docs/deployment/registry.md ... but the gate this produced is why the bundle
below exists.)

The fix is `apps.devops_netpol`, on by default: a default-deny ingress for
`namespaces.devops` with three allows, written for what is actually in that
namespace rather than for a Harbor in isolation.

| Policy | Admits | Doing work today |
|---|---|---|
| `default-deny-ingress` | nothing | yes |
| `allow-intra-namespace` | the whole devops namespace | yes ... Harbor's seven-component mesh, the Argo server to the workflow controller, and daemoned workflow steps |
| `allow-from-traefik` | the Traefik pod | yes ... `harbor.<internalDomain>` and `workflows.<internalDomain>`, including node image pulls that route through the Harbor ingress |
| `allow-prometheus-scrape` | the Prometheus pod | no ... Harbor's metrics and the Argo controller's are both off upstream. It ships so enabling either is a values change, not a policy change |

Egress is untouched, deliberately. Harbor's proxy cache has to reach upstream
registries, trivy fetches a vulnerability database, and the workflow controller
talks to the API server and your artifact store.

`apps.harbor_netpol` stays, off, as the bundle for a Harbor you installed
yourself as its own release. It no longer claims the shipped one. Its template
refuses to render if `namespaces.harbor` is set equal to `namespaces.devops`,
which would stack a second default-deny on a namespace that already has one,
with an allow set that never heard of Argo Workflows.

`tockmox-platform` and `tockmox-selfcheck` now carry bundles of their own, new
since v0.5.0. No namespace this layer creates is uncovered.

### The regression gate

`tools/check-no-ghost-policies.sh` renders every layer into the destination
namespace the installer assigns it, then fails if any namespace holding a
NetworkPolicy holds no workload. It runs in CI. It has no allowlist on purpose:
needing one means a fifth bundle is about to ship guarding nothing.

## Known issue

`deny-privileged-rbac` denies the ClusterRoleBinding that k3s's HelmChart
controller creates, and the resulting error mentions neither. See
[troubleshooting](../../docs/operations/troubleshooting.md).

## Values

Globals are documented once in
[docs/administration/configuration.md](../../docs/administration/configuration.md).
This chart's own values are in `values.yaml`, and `values.schema.json`
rejects bad input at lint and at sync.

## Installing on its own

Every layer is an independent Argo Application, so you can take this one alone:

```bash
# once per clone: register chart repos and fetch dependencies
./tools/helm-deps.sh

helm template t charts/tockmox-policy \
  -f your-site/site/values/global.yaml \
  -f your-site/site/values/policy.yaml
```

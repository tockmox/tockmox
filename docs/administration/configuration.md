---
okf_version: "0.2"
type: Reference
title: "Configuration values"
description: "Every value Tockmox asks you to supply, what it does, whether it is required, and what happens if you leave it empty."
tags: [configuration, values, reference, globals, namespaces, ingress, schema]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Configuration values

**This is a lookup page, not a procedure.** It answers "what is this key, must
I set it, and what breaks if I do not". If you are installing for the first
time, [installation](../deployment/install.md) walks the four values you cannot
skip; come back here when you want the rest.

## Find your value

| You are looking for | Section |
|---|---|
| The base hostname, the LAN CIDR, the storage class, the timezone | [Globals](#globals) |
| Which of those you cannot skip, and why | [Why those three are required](#why-those-three-are-required) |
| Console hostnames, which UIs are exposed, TLS | [Hostnames and TLS](#hostnames-and-tls) |
| Namespace names, and adopting into an existing cluster | [Namespaces](#namespaces) |
| Turning a single component on or off | [Per-app toggles](#per-app-toggles) |
| Turning off a whole functional story | [Capabilities](capabilities.md) |
| Which keys are a contract and which are internal wiring | [The values contract](values-contract.md) |
| What happens when you type a key wrong | [Schema validation](#schema-validation) |

## Where configuration lives

```
your-site-repo/
  site/values/global.yaml     read by every layer
  site/values/<layer>.yaml    per-layer overrides, wins over global
```

Both files are passed to every chart, global first. Later files win.

## Pre-1.0 stability

[Semantic Versioning](https://semver.org/) treats major version zero as
explicitly unstable: anything may change at any time, and the public interface
is not to be considered stable. That applies to every value on this page.

The values interface is **declared, and tiered rather than frozen whole**. Every
Tockmox key carries `stable`, `provisional` or `experimental` in its schema, and
the tier is what tells you how much to build on it. Three things follow, and they
are the whole of what an operator has to do about it:

| Do this | Why |
|---|---|
| **Pin a tag, never a branch** | A branch moves under you, and an upgrade you did not choose is the failure mode GitOps exists to remove |
| **Read [CHANGELOG.md](../../CHANGELOG.md) before every upgrade** | Changes to `stable` keys are called out at the top of the release section; the other tiers are named further down |
| **Check the tier before you build on a key** | `jq -r '.properties\|to_entries[]\|select(.value["x-tockmox-stability"])\|.value["x-tockmox-stability"]+"\t"+.key' charts/<layer>/values.schema.json`. A `provisional` or `experimental` key is expected to move before 1.0 |

What is already true, and what is not yet: the schemas close their root object,
so a misspelt top-level key is rejected at lint. `global` is still open, so a
misspelt key *inside* `global` is still accepted silently. It is one of the
open blocks rather than the only one; the list is in
[the values contract](values-contract.md), and it is a known hole. The measurements behind both statements, and the
reason `global` cannot be closed, are in
[the values contract § what the schemas now enforce](values-contract.md#what-the-schemas-now-enforce).

Committing that a `stable` key does not move without a signal is a prerequisite
for 1.0, not a follow-up to it. Declaring the interface was the first half and is
done; tiering it says which keys the commitment covers; holding those tiers
across releases is the part still owed, and it is a gate rather than a promise
about anyone's discipline.

> **This section was wrong for longer than it should have been.** Until
> 2026-09-01 it said there was no contract document, that four of the nine
> schemas were byte-identical, that none of them closed the root object, and
> that Tockmox was at v0.1.0. All four had stopped being true, the first three
> when the values contract landed, and the page went on asserting them while the
> README four clicks away described the current state correctly. An external
> reviewer found the version number; checking the rest of the section against
> the tree found the other three. Prose does not get regenerated the way a
> version footer does, which is the whole lesson.

## The rule that governs this page

**A value exists only if the operator must supply it.** If Tockmox can pick a
sane default, Tockmox picks it. This keeps the configuration surface small
enough to read in one sitting, and it is enforced at review: a pull request
adding a value has to justify why the project cannot decide.

If you find yourself needing something not listed here, that is a gap worth
[reporting](https://github.com/tockmox/tockmox/issues), not working around.

## Globals

| Value | Required | Default | What it does |
|---|---|---|---|
| `global.internalDomain` | **yes** | none | Base for internal hostnames. `grafana.<this>` |
| `global.lanCIDR` | **yes** | none | LAN/node network admitted by NetworkPolicies |
| `global.storageClass` | **conditional** | `""` | StorageClass for replicated PersistentVolumeClaims. Required when Longhorn is enabled and not marked default ... see [Storage](#storage) |
| `global.localStorageClass` | no | `local-path` | StorageClass for volumes the workload rebuilds by itself. Empty falls back to the cluster default, which undoes the storage policy without complaining |
| `global.certIssuer` | no | `""` | cert-manager issuer. Empty skips certificates |
| `global.clusterCIDR` | no | `10.42.0.0/16` | Pod network. k3s default |
| `global.serviceCIDR` | no | `10.43.0.0/16` | Service network. k3s default |
| `global.timezone` | no | `UTC` | IANA zone for scheduled jobs |
| `global.imageRegistry` | no | `""` | Mirror prefix. Empty pulls upstream |
| `global.namespaceLabels` | no | `{}` | Extra labels on every Namespace the policy and platform layers create, for an admission mutator keyed on namespace labels (for example `zarf.dev/agent: ignore`). A label the chart sets itself is refused at render |

`site.name` is installer-only and is not a chart value. Nothing derives from it
functionally; it labels generated files so you can tell deployments apart.

### Why those three are required

**`internalDomain`** ... every hostname derives from it. A default would be
wrong for everyone.

**`lanCIDR`** ... NetworkPolicies use it to admit traffic originating outside
the cluster: the diagnostic identity reaching the Kubernetes API, and the
kube-prometheus-stack admission webhook, which the API server calls from a node
address. The optional syslog bundle uses it too. Too narrow and the webhook
times out; too wide opens a hole. Both failure modes are bad and neither is
obvious, so Tockmox refuses to guess.

**`storageClass`** ... conditional rather than always required. Tockmox does not
require Longhorn and does not require any particular class. It requires that
somebody chose, because the combination it refuses used to fail quietly. See
below.

### Storage

Two keys, and they encode a policy rather than a preference: replicate at
exactly one layer. `global.storageClass` carries the volumes that are the only
copy; `global.localStorageClass` carries the ones the workload rebuilds. The
derivation, the per-volume table and the k3s two-defaults problem are all in
[storage](storage.md).

**What this page is responsible for is the guard.** The platform layer
**refuses to render** one combination: Longhorn enabled, Longhorn not marked as
the cluster default, and `global.storageClass` empty. The error names all three
conditions and offers the three ways out. `global.storageClass: local-path` is
one of them and is a legitimate answer if you mean it.

Everything else about storage ... what happens on k3s, what changing the default
does and does not migrate, and what to do if you run your own CSI ... is in
[storage](storage.md).

## Hostnames and TLS

Each layer with a UI ships an Ingress. Hostnames derive from `internalDomain`;
each is overridable per app.

| Hostname | UI | Default | Why |
|---|---|---|---|
| `grafana.<internalDomain>` | Grafana | on | Has its own login |
| `chat.<internalDomain>` | Open WebUI | on | Has its own login |
| `auth.<internalDomain>` | Authentik | on (with the identity layer) | Is the login |
| `workflows.<internalDomain>` | Argo Workflows | on | Behind SSO |
| `ntfy.<internalDomain>` | ntfy | on | Has its own authentication, and the web app is how a human subscribes to the alert topic |
| `prometheus.<internalDomain>` | Prometheus | **off** | Ships no authentication; behind Authentik when on |
| `alertmanager.<internalDomain>` | Alertmanager | **off** | Ships no authentication; behind Authentik when on |
| `longhorn.<internalDomain>` | Longhorn | **off** | Ships no authentication, and can delete volumes; behind Authentik when on |
| `traefik.<internalDomain>` | Traefik dashboard | **off** | Ships no authentication; behind Authentik when on |

The four that ship **off** are not a limitation to work around. An
unauthenticated admin surface is not a default. Reach them with
`kubectl port-forward`, or turn one on: its route then goes through Authentik's
forward-auth, and the console must be turned on in the identity layer too
(`sso.forwardAuth.apps.<console>`). [Identity, consoles behind
forward-auth](identity.md#consoles-behind-forward-auth) has the values and what
each half does. With the identity capability off, turning one on fails the
render rather than publishing a console nobody signs in to;
`ingress.apps.<console>.forwardAuth: false` is the explicit way to route it
without Authentik, for a site that puts its own authentication in front.

**The Traefik dashboard's route is its own, not the chart's.** The upstream
chart's dashboard route (`traefik.ingressRoute.dashboard.enabled`) matches
`PathPrefix(/dashboard)` and `PathPrefix(/api)` with no Host rule and no auth,
so it answers on every internal hostname that reaches Traefik and `/api` hands
out router and service configuration. It stays off.
`ingress.apps.traefik.enabled` in the platform layer renders a different one: a
Host-matched IngressRoute to `api@internal` for `/dashboard` and `/api` on
`traefik.<internalDomain>` only, behind Authentik, with its own certificate.

The port-forward path below stays as the break-glass whichever you choose, and
on purpose. **Unlike the other consoles, `kubectl port-forward` alone does not
reach the dashboard.**
`api.dashboard: true` without `api.insecure` makes the dashboard available to be
*routed* to `api@internal` and serves it on no entrypoint ... measured on a
stock install, Traefik v3.7.12: `/ping` on the traefik entrypoint answers `200`
while `/dashboard/` and `/api/overview` both return `404`. To get the
port-forward path the four consoles already have, turn on:

```yaml
# site/values/platform.yaml
traefik:
  api:
    insecure: true
```

```bash
kubectl -n <platform namespace> port-forward deploy/<release>-traefik 8080:8080
```

With that forward running, the dashboard is at
`http://127.0.0.1:8080/dashboard/`.

**`insecure` is the honest name for it**: it authenticates nobody who reaches
that entrypoint. What limits the blast radius is that the `traefik` entrypoint
(`:8080`) is **not** published in the LoadBalancer Service ... verified in the
render, which lists only `web:80` and `websecure:443` even with this on ... so
reaching it takes pod-network access or a port-forward, and the policy layer's
NetworkPolicies constrain the first. Leave it off on anything you did not build
to be poked at.

Keep this path even with the Authentik route on. **A console that tells you why
routing is broken should not be reachable only through the routing you are
trying to debug**, and an Authentik outage would otherwise lock you out of the
tool you would use to find it.

```yaml
# site/values/observability.yaml
ingress:
  className: ""             # empty = the cluster's default IngressClass
                            # (the shipped Traefik marks itself default)
  annotations: {}           # added to every Ingress this layer renders
  apps:
    grafana:
      enabled: true
      host: ""              # override the derived hostname entirely
```

An Ingress host override does not move the single-sign-on redirect URI. That
is registered by the identity layer from `sso.apps.<app>.host`; set both to the
same name (see [identity](identity.md#sso-values-that-follow-your-site)).

TLS follows `global.certIssuer`: set it and every Ingress carries the
cert-manager annotation and a `tls` block; empty serves plain HTTP. Point the
hostnames at Traefik's LoadBalancer IP in your DNS: one wildcard record for
`*.<internalDomain>` is the default, and per-host records the alternative
([external integrations § DNS](external-integrations.md#dns-reference-unbound-on-the-firewall)).

Set it to `tockmox-ca` to use the private CA the platform layer ships, or to
your own issuer if you have a real domain. Either way the certificate is only
half the job ... a CA nothing trusts produces HTTPS that every browser rejects.
See [TLS and trust](tls-and-trust.md), which also covers what moves when the
consoles change scheme, including Authentik's OIDC redirect URIs.

**DNS must answer from inside the cluster too.** With SSO on, each console's
server exchanges OAuth codes with `auth.<internalDomain>` directly ... a
hostname only your workstation resolves breaks the login at the token step.
Real LAN DNS covers both; see [identity](identity.md).

## Schema validation

Every chart ships `values.schema.json`. Bad input fails at lint and at sync, not
at runtime. A missing required value:

```console
$ helm lint charts/tockmox-policy --set global.timezone=UTC
==> Linting charts/tockmox-policy
[INFO] Chart.yaml: icon is recommended
[ERROR] values.yaml: - global.lanCIDR: String length must be greater than or equal to 1
- global.internalDomain: String length must be greater than or equal to 1

[ERROR] templates/: values don't meet the specifications of the schema(s) in the following chart(s):
tockmox-policy:
- global.internalDomain: String length must be greater than or equal to 1
- global.lanCIDR: String length must be greater than or equal to 1

Error: 1 chart(s) linted, 1 chart(s) failed
```

A value of the wrong type:

```console
$ helm lint charts/tockmox-policy \
    --set global.internalDomain=123 --set global.lanCIDR=192.168.1.0/24
[ERROR] values.yaml: - global.internalDomain: Invalid type. Expected: string, given: integer
```

**Transcripts above captured 2026-09-01 against the 0.6.0 tree with Helm
v3.16.3.** Helm does not guarantee the ordering of schema errors, so the two
lines in the first block may appear either way round.

CI asserts that the schema *rejects* bad input, not merely that it accepts good
input. A schema nobody proves fails closed is decoration. Which keys are covered
and which are not is in [the values contract](values-contract.md).

## Namespaces

Defaults carry the reserved `tockmox-` prefix, so a fresh install is
prefix-clean and Tockmox-managed objects are trivially distinguishable.

```yaml
namespaces:
  create: [ai, monitoring, platform, authentik,
           diagnostic_identity, selfcheck, devops]
  ai: tockmox-ai
  monitoring: tockmox-monitoring
  platform: tockmox-platform    # the whole platform layer: one release, one namespace
  # ...
```

**Adopting into an existing cluster?** Override the names; do not rename your
namespaces to match. Renaming a namespace in Kubernetes means deleting and
recreating everything inside it.

```yaml
namespaces:
  ai: ai
  monitoring: monitoring
```

`create` lists which of these the policy chart creates. `argocd` is referenced
but not created ... it is a prerequisite you own. The keys `traefik`,
`cnpg_system`, `longhorn_system` and `kured` name where NetworkPolicies expect
those components; on a stock install they all equal the platform namespace.

**The rule for what belongs in `create`:** a namespace is created when some
Tockmox layer actually deploys into it.

| Name | On `create`? | Because |
|---|---|---|
| `forgejo`, `tailscale` | no | Tockmox ships neither workload |
| `harbor` | no | No registry ships (measured 2026-10-10 on the 0.8.0 tree: no Harbor object in any layer's render with every app on, and no Harbor image in `images.txt`). A registry is a prerequisite, not a component, so `namespaces.harbor` describes a Harbor **you** ran. See [registry](../deployment/registry.md) |

All three names remain defined above, because the optional NetworkPolicy bundles
reference them. Add a key back to `create` if you install that workload
yourself. See
[external integrations](external-integrations.md#policy-bundles-for-workloads-tockmox-does-not-ship),
and point `namespaces.harbor` at wherever you installed a registry before
enabling the bundle.

`tools/check-no-ghost-policies.sh` enforces this rule in CI by rendering each
layer into its destination namespace and failing if a NetworkPolicy guards a
namespace with no workload in it.

Keys for a site that needs something beyond the defaults (each is empty or off
until you set it, and `tools/check-platform-seams.sh` renders them):

| Value | Layer | What it does |
|---|---|---|
| `garage.credentialsNamespaceLabels.<namespace>` | platform | Labels for one namespace named in `garage.createCredentialsNamespaces`, at least `pod-security.kubernetes.io/*`. Merged over `global.namespaceLabels` |
| `platformNetpol.extraPrometheusNamespaces` | policy | Namespaces besides `namespaces.monitoring` whose Prometheus may scrape the platform and devops namespaces |
| `platformNetpol.extraMonitoringClientNamespaces` | policy | Namespaces whose pods (a site's own Alloy, capacity jobs, publishers) may reach Prometheus, Loki and ntfy in the monitoring namespace. Renders `allow-from-site-clients` |
| `apps.etcdScrapeConfig.{enabled,targets,interval,scheme}` | observability | Scrape embedded etcd (k3s) through a ScrapeConfig with static `host:port` targets, because Argo CD 3.x never syncs the Endpoints object the stack would use. Also set `kube-prometheus-stack.kubeEtcd.enabled: false` |
| `ingress.apps.<app>.host` | ai, observability, identity, devops | Also read by the exporters layer, so the console probe checks the host you actually serve |

## Per-app toggles

Every application in every chart has its own switch:

```yaml
apps:
  harbor_netpol:
    enabled: true
```

**Component names are the chart's keys, not names you can guess.** `apps` accepts
any key that is an object with an optional `enabled`, so a misspelt component
name lints clean, renders clean, and changes nothing. Read the component names
out of the layer's own `values.yaml` before you set one. A switch that removes no
object is the same failure as no switch at all, and it looks identical from
outside.

Measured behaviour, not aspiration. The first `grep -c` prints `54`, the second
prints `58`:

```bash
helm template t charts/tockmox-policy \
  --set global.internalDomain=example.internal \
  --set global.lanCIDR=192.168.1.0/24 | grep -c '^kind:'

helm template t charts/tockmox-policy \
  --set global.internalDomain=example.internal \
  --set global.lanCIDR=192.168.1.0/24 \
  --set apps.harbor_netpol.enabled=true | grep -c '^kind:'
```

**Measured 2026-09-01 against the 0.6.0 tree with Helm v3.16.3.** Substitute your
own domain and CIDR; any syntactically valid pair renders the same count. The
load-bearing number is the **delta of 4**, which is the Harbor bundle. The
absolute counts move with every policy the layer gains and are re-derived per
release rather than enforced per commit.

To turn off a whole functional story rather than one component, use
[capabilities](capabilities.md). The interaction between the two switches, and
which one wins, is on that page.

## PriorityClasses

```yaml
priorityClasses:
  clusterCritical: tockmox-cluster-critical
  infrastructure: tockmox-infrastructure
  apps: tockmox-apps
```

Referenced by `priorityClassName` on shipped workloads, so renaming these is a
coordinated change across every chart. Override only when adopting into a
cluster that already has an equivalent scheme.

## What is not certified here

Every value, default and required/optional marking on this page was read out of
the shipped `values.yaml` and `values.schema.json` files on 2026-09-01, and the
two render measurements and the guard behaviour were executed against the 0.6.0
tree on that date.

**That is not the same as certifying that a deployment configured this way
behaves as described.** Reading a page cannot establish that, and neither can
reading the values files it was written from. The
[testing standard](../testing-standard.md) says which configurations are
exercised by a real deploy and which are not.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

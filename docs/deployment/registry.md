---
okf_version: "0.2"
type: Reference
title: "A container registry"
description: "Why Tockmox ships no registry today and no offline bundle, which registry is planned to ship and when, what `global.imageRegistry` does and does not reach, and how to run one yourself in the meantime."
tags: [registry, harbor, zot, airgap, images, imageregistry, proxy-cache, mirror]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# A container registry

**Tockmox does not ship one today.** A registry is an operator prerequisite in
this release: you supply it. One is planned as a shipped layer, and
[the choice is made](#what-is-planned-a-shipped-registry-layer). This page is
a reference: what you need in each situation, why the answer is what it is,
and what the one knob Tockmox exposes actually does. There is one short
procedure at the end, for running Harbor beside Tockmox ... one documented
option for a registry you supply, not the one Tockmox will ship.

## Do you need one

| Situation | What to do | Where |
|---|---|---|
| Connected install, no private registry | **Nothing.** Images pull from their upstreams | ... |
| Connected install, you want caching or rate-limit relief | **Optional.** Run a registry with a pull-through proxy cache | [the pull-through proxy cache](#the-pull-through-proxy-cache) |
| Air-gapped install | **Required.** Mirror every entry in `images.txt` into a registry your cluster can reach, then set `global.imageRegistry` | [install with no internet access](airgap.md) |

`global.imageRegistry` is the only knob Tockmox needs from you. **It does not
reach every image**, which is
[the section that matters most](#how-globalimageregistry-rewrites-an-image-reference)
if you are mirroring.

## Why it is a prerequisite and not a component

A registry is something you need **before** Tockmox installs, not a capability
Tockmox delivers. Source-only distribution means you build or mirror images
yourself, and an air-gapped site must already have somewhere to mirror **into**
before the first chart renders. A component that has to exist before the
platform can install is a prerequisite by definition.

Harbor shipped in the `devops` layer through 0.1.0-dev and was removed for that
reason, plus two practical ones:

- **It was the heaviest thing Tockmox carried.** 8 pods, 5 volumes totalling
  33Gi, and 9 of the 55 entries in `images.txt`. For an air-gap mirror list,
  image count is the expensive axis. Removing it took the list from 55 to 46
  at the time. Both are historical figures from that change; `images.txt`
  carries **45** entries at 0.7.0 and is the only number to mirror from.
- **Enabling it deployed it unguarded.** The layer's NetworkPolicy bundle
  targeted a `harbor` namespace, while Harbor as a subchart landed in the
  `devops` namespace, so the guard selected nothing. That was a documented
  known issue rather than a fixed one, and dropping the component deletes it
  rather than describing it. The bundle that replaced it, and the one that now
  guards the devops namespace, are in
  [external integrations § Harbor is the one to read twice](../administration/external-integrations.md#harbor-is-the-one-to-read-twice).

Nothing about this stops you running Harbor. It stops Tockmox pretending a
registry is one of its features.

## What is planned: a shipped registry layer

The prerequisite is not the end state. A registry is going to ship as a
Tockmox layer, and the choice was made on 2026-08-19 (ADR-0044): **zot**,
because one instance covers the three roles this page describes ... the
pull-through cache for a connected site, an on-disk store that *is* an OCI
image layout, so a disconnected site can be seeded by copying a directory in,
and an artifact store for charts, SBOMs and models under the same API. It is
Apache-2.0, a CNCF sandbox project, a single binary, with a first-party Helm
chart, and it speaks OIDC, which is how the identity layer would front it like
every other console.

**Timing.** It is targeted at the **1.1** release, the "supply line" slot,
and a pilot on the reference deployment comes before any chart work. The
Garage S3 backend gets verified before it is documented as supported, not
before. Nothing on this page changes until it ships: a registry stays
something you bring, `global.imageRegistry` stays the knob, and the
[air-gap page](airgap.md) keeps saying "mirror into a registry you run". When
it ships, this page is rewritten around it and the Harbor procedure below
becomes one alternative among several rather than the only worked example.

**What this means for you now.** If you are choosing a registry today, nothing
here says Harbor over zot or the reverse. Harbor is the example below because
it is the one the reference deployment ran through 0.1.0-dev and the one its
NetworkPolicy bundle was written against. zot works as a bring-your-own
registry too, and if you run it today you are on the path the product is
taking.

## Why there is no offline image bundle

Tockmox distributes **source, never binaries**. There is no single-artifact
offline installer, and we do not claim one. That is a deliberate trade rather
than an unfinished feature.

Bundling container images would make Tockmox a distributor of other people's
compiled software, and that pulls in the obligations of whatever licences those
images carry. The argument does not depend on any particular image: it is
enough that some of what a bundle would contain is strong copyleft. Grafana and
Loki, both referenced by the observability layer, are AGPL-3.0. **Referencing
an image in a manifest is not distributing it. Bundling it is.**

*(A previous version of this paragraph also named Forgejo. Tockmox does not
ship or reference Forgejo ... it appears nowhere in `images.txt` and is not a
dependency of any chart. Corrected 2026-09-01. The remaining examples were
checked against `images.txt` in the same pass.)*

The practical consequence is good for you: **you mirror what you actually
want**, from upstreams you choose, into a registry you control, on your
schedule. An operator building a bundle for their own deployment is not
conveying to a third party, so no obligation attaches to you either.

The cost lands on the operator of a disconnected site, as preparation across
five separate dependencies rather than one download. That preparation is
[install with no internet access](airgap.md).

## How `global.imageRegistry` rewrites an image reference

**It prepends your prefix to the repository *as the chart writes it*.** The
upstream host is dropped and the organization is kept, so
`docker.io/grafana/grafana:13.1.3` renders as `${REG}/grafana/grafana:13.1.3`,
not `${REG}/grafana:13.1.3`. Copying to the flattened name produces a mirror
full of images no manifest asks for. `tools/mirror-images.sh` encodes this path
handling; it is the part that bites if you roll your own.

**One reference is pinned by digest**, `prometheus-config-reloader`. A copy
that preserves digests lands it under a derived tag and the manifest's
`@sha256` reference still resolves. It is the only digest-pinned entry in
`images.txt` at the 0.6.0 tree.

**It is a convention, not a Helm feature**, so it works only in charts that
read it. The Tockmox-authored templates read it, and so do
kube-prometheus-stack, Loki and Longhorn. A parent chart cannot interpolate a
value into a subchart that never reads it, so each uncovered image means
finding that chart's own registry key, or covering it node-side ... which is
what the [proxy cache section](#the-pull-through-proxy-cache) is really about.

`tools/check-airgap.sh` holds the line with an exemption list that is a
**ratchet, not an excuse**: it carries **21 entries** (counted in
`tools/check-airgap.sh` at the 0.6.0 tree), and it fails the build both on any
image that joins the uncovered set and on any listed image that no longer needs
listing. The list can only shrink.

### Two image populations, and why they differ

Reconciled 2026-10-01 against the 0.7.0 tree by running the gate and diffing
its render against `images.txt`:

| Population | Count | What it is |
|---|---|---|
| `images.txt` | **45** | The runtime workload images. **This is what you mirror** |
| What `tools/check-airgap.sh` evaluates | **49** | Every distinct image reference in the rendered reference profile |

The 49 is the 45 plus four references: two `helm test` hook images from
upstream subcharts, neither a runtime dependency (`grafana/loki-helm-test` from
the observability layer, and a bare `busybox` from the litellm subchart's test
pods); `quay.io/prometheus/snmp-exporter`, which the gate renders because its
all-on overlay turns on the opt-in `hardwareTelemetry` capability, while
`images.txt` is generated with it off, as it ships; and the CloudNativePG
`postgres` image counted twice, because the charts spell its reference two ways
(`docker.io/library/postgres` and `library/postgres`). Against that 49 the gate
reported **27 redirected and 22 exempt** on 2026-10-01. (On 2026-08-27 the
same figures were 44, 46, 25 and 21.)

Coverage figures describe the 49, because that is the population
`global.imageRegistry` acts on. **Mirror from `images.txt`; read coverage from
the gate's own output**, which prints both numbers every run and is therefore
the version of these figures that cannot go stale.

### `helm test` is not air-gap capable, and that is deliberate

`helm install` works disconnected. `helm test` does not, and the reason is
worth stating so nobody reads a failed test as a failed install.

Two `helm test` Pods in the LiteLLM subchart hardcode `image: busybox` with no
tag, no values override, and nothing a parent chart can reach. `images.txt` is
generated with `--skip-tests` on purpose: including them would put an unpinned
`busybox:latest` in the mirror set, for a code path that only runs if you type
`helm test`, and it would be the only unpinned entry in the file. A
reproducible mirror set beat a complete one.

The consequence, stated plainly: **on a disconnected cluster, `helm test` will
fail to pull.** That is the test tooling, not your deployment. A node-side
mirror covers it if you populate those images yourself, and
`tools/mirror-images.sh --images FILE` takes an alternate list if you want
them.

## The pull-through proxy cache

A cluster pulls `docker.io/library/postgres` once, and every later pull on
every node is served locally. Worth doing on a metered link, behind a
rate-limited upstream, or on any cluster you rebuild more than once.

**Three pieces, and none of them is Helm configuration:**

| Piece | Lives where | Why no chart ships it |
|---|---|---|
| A **registry endpoint** per upstream. `docker.io`, `ghcr.io`, `quay.io` and `registry.k8s.io` cover every entry in `images.txt` | A row in the registry's own database | Created through the registry's API after its pods are up. A Job that writes to an application's API on every sync is a worse problem than the one it solves |
| A **proxy-cache project** bound to each endpoint | A row in the same database | Same reason |
| The **node-side containerd mirror** that sends pulls to the registry in the first place | A file on each node | It is not a Kubernetes object at all |

**Until all three exist nothing is cached.** Not partially, not for some
images: pulls go straight upstream exactly as before, because nothing has told
containerd otherwise. The step-by-step procedure, with a success condition for
each of the three, is in
[external integrations § the pull-through proxy cache](../administration/external-integrations.md#container-registry-the-pull-through-proxy-cache).

Once containerd mirrors through it, the registry is on the image-pull path for
the whole cluster, **including its own restart**. Cached layers keep serving
while it is down; anything not yet cached does not pull.

### A cache is not a mirror, and only one of them survives a cut uplink

Same node configuration, different contents:

| | Populated by | Disconnected install |
|---|---|---|
| **Proxy cache** | fetching from upstream on a miss | **fails.** A miss has nowhere to go |
| **Mirror** | you, in advance, by copying images in | **works** |

A registry serves both roles ... Harbor in the worked example below, zot once
Tockmox ships one; which role yours plays depends on whether you pushed the
images or let it fetch them. A node-side registry mirror rewrites pulls at
containerd rather than in the manifest, so it applies to every image regardless
of whether its chart has ever heard of `global.imageRegistry`. **That is why
it, rather than `global.imageRegistry`, is the mechanism that covers
everything** ... and why the exemption list above is a tidiness problem rather
than an air-gap blocker.

**A proxy cache that has never been tested disconnected can hide a broken
component for months.** With the uplink up, a failed cache fetch falls through
to upstream and everything looks healthy. The 2026-08-25 air-gap exercise
surfaced two such faults within minutes of the uplink being cut, both of which
had been live for roughly three months. If you run a cache, cut the uplink once
and see what breaks.

## Running Harbor alongside Tockmox

**Optional, and one worked example.** Harbor is one good answer, and running it beside Tockmox rather
than inside it costs you nothing except one more Helm release. What you get: a
registry you control, which can act as a cache, a mirror, or both. What you
lose by not running one: on a connected cluster, nothing but pull time. The
same shape ... a release out of band, a hostname, a StorageClass, then the
policy bundle ... applies to any registry you bring; only the values file is
Harbor's.

### Before you begin

| What you need | Why | How to check |
|---|---|---|
| A working Tockmox platform layer, with Traefik and an issuer | Harbor's ingress uses the shipped IngressClass and needs a certificate | `kubectl get ingressclass tockmox-platform-traefik` |
| A DNS record for Harbor's hostname, resolving from inside the cluster too | `externalURL` is baked into `docker login` instructions and OIDC redirects | [external integrations § DNS](../administration/external-integrations.md#dns-reference-unbound-on-the-firewall) |
| A StorageClass with room for the registry volume | The reference values below ask for 25Gi | `kubectl get storageclass` |
| `helm` on your workstation | One release, installed out of band | `helm version` |

### 1. Pick the chart version ... Required

**YOU SUPPLY:** the chart version. Pinning one from this page would be a value
that goes stale between releases, so read it from the repository instead:

```bash
helm repo add harbor https://helm.goharbor.io
helm repo update
helm search repo harbor/harbor --versions | head -5
```

**Success condition:** the output lists a chart version and an app version, and
they are different numbers. Reading the chart number as Harbor's own version is
the easy mistake.

### 2. Start from the reference values file ... Required

The repository carries the values file as
[`examples/registry/harbor-values.yaml`](https://github.com/tockmox/tockmox/blob/main/examples/registry/harbor-values.yaml),
so the page and the file cannot drift apart. Copy it and change the lines
marked `CHANGE ME`.

**YOU SUPPLY:** your hostname in place of `registry.int.example.com` (in
`externalURL` **and** in `expose.ingress.hosts.core`, which must agree), your
StorageClass if it is not `longhorn`, and your ClusterIssuer if it is not
`tockmox-ca`.

What the file decides for you, and why:

- **`externalURL` must equal the hostname you expose it on, scheme included.**
  Harbor bakes it into `docker login` instructions, OIDC redirects and the
  registry's own 307s, so a mismatch presents as a working UI attached to a
  registry nobody can push to.
- **Trivy is off.** It pulls its vulnerability database from the internet at
  startup and on a refresh interval; in a Dark Site it comes up and reports
  nothing useful. Turning it off drops a pod and a 5Gi volume, and scanning
  goes with it.
- **The bundled PostgreSQL is a StatefulSet, not the CloudNativePG operator the
  platform layer runs**, so it sits outside the backup story in
  [backup and restore](../operations/backup-restore.md). Point it at an
  instance you do back up with `database.type: external`.

**Success condition:** `helm template registry harbor/harbor --version
CHART_VERSION_FROM_STEP_1 -f harbor-values.yaml` renders without error, and
`grep EXT_ENDPOINT` in its output shows your hostname rather than the example
one. The chart has no values schema, so a misspelt key renders without error:
read the output, do not rely on the exit code.

### 3. Install it ... Required

```bash
helm install registry harbor/harbor \
  --version CHART_VERSION_FROM_STEP_1 \
  --namespace registry --create-namespace \
  -f harbor-values.yaml
```

**Success condition:**

```bash
kubectl -n registry get pods
curl -sSf https://registry.int.example.com/api/v2.0/systeminfo
```

Every pod `Running`, and the API returns JSON. The UI loading is not enough:
the `externalURL` mismatch above produces a working UI in front of a registry
nobody can push to, and only a push or an API call finds it.

### 4. Guard it ... Conditional

**If** `capabilities.networkPolicy` is on (it is, by default), the namespace
you just created has no policy in it, because Tockmox did not create it.

The policy layer ships a `harbor_netpol` bundle for exactly this case:
`apps.harbor_netpol`, default off, aimed at `namespaces.harbor`. Set
`namespaces.harbor` to wherever you installed it and enable the bundle. It
refuses to render if you point it at `namespaces.devops`, which already carries
a default-deny. Full instructions:
[external integrations § enabling one](../administration/external-integrations.md#enabling-one).

**Success condition:** `kubectl -n registry get networkpolicy` lists policies,
**and** `kubectl -n registry get pods` lists pods. Policies in an empty
namespace are the defect this bundle was rewritten to avoid.

## What is not certified here

The counts on this page were re-derived against the 0.7.0 tree on 2026-10-01:
`images.txt` holds 45 entries and one digest-pinned reference, and
`tools/check-airgap.sh` carries 22 exemptions. The 49/27/22 render figures are
from a gate run that day; the gate prints them fresh every time, so prefer its
output over this page.

**The Harbor reference values file was rendered, not installed.** On 2026-10-09
`examples/registry/harbor-values.yaml` was rendered with `helm template` against
`harbor/harbor` chart 1.19.2 (Harbor 2.15.2): 27 resources, all valid under
`kubeconform`. It was not installed on a cluster.

**No other procedure on this page has been executed as written for this release.**
The Harbor steps describe an upstream chart whose version you supply, and a
version this page deliberately does not pin. Documented procedures are verified
by running them, not by reviewing them ... the
[testing standard](../testing-standard.md) says which paths are covered.

The 2026-08-25 air-gap exercise is a single dated exercise, not a repeated
measurement.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

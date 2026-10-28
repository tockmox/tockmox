---
okf_version: "0.2"
type: HowTo
title: "Install with no internet access"
description: "The five things a disconnected install needs in place, in the order you do them, where each one changes the normal install flow, and how to update the install later from your own mirror."
tags: [airgap, deployment, offline, mirroring, images, helm, git]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Install with no internet access

**This is the normal install with six things done differently.** It is not a
separate procedure, and you should not read it as one. Do
[prepare a fresh cluster](fresh-install.md) and [installation](install.md) in
the usual order, and use this page for the six points where a disconnected site
diverges.

**Exercised end to end on 2026-08-25.** A full teardown, an uplink cut at the
route level for both IPv4 and IPv6, and a greenfield install from a freshly
generated site repository: all nine layers Synced and Healthy, 59 of 59 pods
Running, zero image pull failures, with `github.com`, `quay.io`, `ghcr.io` and
`registry-1.docker.io` unreachable throughout. That is one build on one date;
see [what is not certified here](#what-is-not-certified-here).

Tockmox distributes **source, never binaries**. There is no single-artifact
offline installer and we do not claim one. Why that is a deliberate trade, and
what it buys you, is in
[registry § why there is no offline image bundle](registry.md#why-there-is-no-offline-image-bundle).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| A **connected host** with `skopeo` (or `crane`), `helm` and `git` | Steps 2, 3 and 4 all run there. `skopeo` is multi-arch correct with no daemon; `docker` copies only the running machine's architecture | `command -v skopeo helm git` prints three paths |
| A **transfer path** from that host into the boundary | Every artifact below crosses it. A one-way diode is fine | You have moved a 1 GB file across it once, end to end |
| A **registry inside the boundary**, with push access | 44 images land in it and the cluster pulls from it | `curl -fsS https://REGISTRY_HOST/v2/ -o /dev/null && echo reachable`, run from a node |
| A **git server inside the boundary** speaking git's **smart** protocol | ArgoCD reads two repositories on every reconcile, not just at install | See the smart-protocol test below. A static file server passes `git clone` and fails ArgoCD |
| A **LAN time source** ([choosing one](time-sync.md#1-choose-the-time-source--required)) | Nothing on a disconnected network reaches `pool.ntp.org`, and clock drift breaks TLS and SSO with errors that name neither | `chronyd -Q -t 5 'server TIME_SOURCE_IP iburst'` reports an offset, or `ntpdate -q TIME_SOURCE_IP` answers |
| An **internal CA**, and the key material for it | Public ACME issuance needs internet. Renewal has to work offline forever | You can name the `ClusterIssuer` you will create and you hold its key. See [TLS and trust](../administration/tls-and-trust.md) |
| The **Tockmox source tree** at the tag you intend to install, on the connected host | `images.txt` and every tool below live in it | `git -C tockmox describe --tags && ls tockmox/images.txt tockmox/tools/mirror-images.sh` |

**The smart-protocol test**, against a candidate git server URL. A `git clone`
that works proves nothing here, because the git CLI also speaks the dumb
protocol and ArgoCD's repo-server does not:

**WORKSTATION** ... from inside the boundary, which is where ArgoCD reads it
from. **YOU SUPPLY:** the candidate git host.

```bash
export GIT_HOST=YOUR_GIT_HOST
curl -fsS "https://$GIT_HOST/tockmox.git/info/refs?service=git-upload-pack" | head -c 24
```

A smart server answers with a packet line beginning `001e# service=git-upload-pack`
or similar. A static file server answers with a directory listing, a 404, or
raw file bytes. Why the failure is worth catching now:
[ArgoCD § a static file server fools the git CLI and not the repo-server](../administration/argocd.md#a-static-file-server-fools-the-git-cli-and-not-the-repo-server).

**Estimate, not a measurement: half a day**, most of it the image copy and the
transfer. The copy is 44 images; the chart archives are about 4 MB.

## The registry prerequisite

**Tockmox does not ship a registry, and an air-gapped install needs one before
the first chart renders.** Harbor used to be part of the `devops` layer and is
not any more: it is a prerequisite you run, the same way ArgoCD and a git server
are. The reasoning is in
[registry § why it is a prerequisite and not a component](registry.md#why-it-is-a-prerequisite-and-not-a-component).

You need a registry that accepts pushes from the connected host, serves pulls to
every node, and is reachable at the hostname you will put in
`REGISTRY_HOST/mirror`. **Harbor is one documented option, not the only one**;
any OCI registry that does this works, and
[registry](registry.md) compares what the others offer.

If you choose Harbor, start from the reference values file
[`examples/registry/harbor-values.yaml`](https://github.com/tockmox/tockmox/blob/main/examples/registry/harbor-values.yaml)
and follow
[registry § running Harbor alongside Tockmox](registry.md#running-harbor-alongside-tockmox).
Three points are specific to a disconnected site:

- **Harbor's own images have to arrive first.** Nothing inside the boundary can
  pull them from Harbor before Harbor exists. Copy them across with `skopeo`
  into any registry the nodes can already reach, and point the chart's
  per-component `image.repository` keys at it. The values file says where.
- **Trivy stays off.** It fetches its vulnerability database from the internet
  and reports nothing useful without it. The reference file sets
  `trivy.enabled: false`, which also drops a pod and a 5Gi volume.
- **Serve it over TLS from your internal CA**, so the nodes can be told to trust
  it. The file asks cert-manager for `harbor-tls` from `tockmox-ca`; change the
  issuer name if yours differs.

**What was and was not tested.** The reference file was rendered with
`helm template` against upstream chart `harbor/harbor` 1.19.2 (Harbor 2.15.2) on
2026-10-09: it renders 27 resources, all valid under `kubeconform`, with the
hostname, ingress class, issuer, StorageClass and `trivy.enabled: false` landing
where intended. **It has not been installed on a cluster, and it has not been
used to mirror `images.txt` or to install Tockmox from the result.** Harbor's
chart carries no values schema, so a misspelt key renders without error:
re-render against the chart version you pin and read the output.

## Where each command runs

Four places are involved and this page switches between them. Every command
block says which:

| Marked | Runs on |
|---|---|
| **CONNECTED** | A host with internet access, outside the boundary. Never the cluster |
| **TRANSFER** | Whatever moves bytes across the boundary. Yours to operate |
| **WORKSTATION** | Your machine inside the boundary, with `kubectl`, `helm`, `git` and `kubeseal` |
| **NODE** | A cluster node, over SSH or at its console |

## What has to be reachable with no uplink

Five dependencies, not one. Miss any and the install stops, and only the first
has a tool shipped with it.

| # | Dependency | Size | What Tockmox ships for it | Step |
|---|---|---|---|---|
| 1 | Tockmox's own workload images | 44 | `images.txt` and `tools/mirror-images.sh` | [2](#2-mirror-the-images--required) |
| 2 | Upstream Helm subcharts | 18 dependencies across 14 repositories | `tools/helm-deps.sh` | [3](#3-vendor-the-upstream-helm-subcharts--required) |
| 3 | Prerequisites: ArgoCD, sealed-secrets, `kubeseal` | 2 charts and 1 binary | nothing | [4](#4-carry-in-the-three-prerequisites--required) |
| 4 | The Tockmox charts git repository | 1 repository | `tockmox.repoURL` points at your copy | [5](#5-serve-both-git-repositories-inside-the-boundary--required) |
| 5 | Your site git repository | 1 repository | [install](install.md) states the requirement | [5](#5-serve-both-git-repositories-inside-the-boundary--required) |

Counts re-read on 2026-10-04: `images.txt` carries 44 non-comment lines (its
header names the day `tools/gen-images.sh` generated it); the `Chart.yaml` files carry 19
non-local dependencies across 14 distinct upstream repositories. These move
with the tree.

**Row 3 is the one that stops you before you start.** Mirror all 44 images,
vendor every chart, host both git repositories internally, and you still cannot
begin, because the three things that must exist before Tockmox installs appear
in no mirroring artefact Tockmox ships. That is why it is step 4 here and last
in the table: the table is a dependency inventory, the steps are the order you
do them in.

## What changes, and where

Read this table before you read the steps. It is the whole difference between a
connected install and this one.

| Point in the normal flow | What a disconnected site does differently | Step |
|---|---|---|
| Before you touch a node | Stand up a LAN time source and point every node at it | [1](#1-point-every-node-at-a-lan-time-source--required) |
| Any time before the install, on a connected host | Mirror 44 images; vendor 19 chart archives; pull the two prerequisite charts and `kubeseal` | [2](#2-mirror-the-images--required), [3](#3-vendor-the-upstream-helm-subcharts--required), [4](#4-carry-in-the-three-prerequisites--required) |
| [fresh-install § 6 install ArgoCD](fresh-install.md#6-install-argocd) and [§ 7 sealed-secrets](fresh-install.md#7-install-sealed-secrets-with-your-own-key) | `helm install` from the carried-in archives instead of from a repository URL | [4](#4-carry-in-the-three-prerequisites--required) |
| [install § Phase 1 generate](install.md#phase-1--generate-your-site-repository) | Set `tockmox.repoURL` at your internal charts clone | [5](#5-serve-both-git-repositories-inside-the-boundary--required) |
| [install § Phase 2 publish it](install.md#phase-2--publish-it) | Push to your internal git server, not to GitHub. It must speak the smart protocol | [5](#5-serve-both-git-repositories-inside-the-boundary--required) |
| [install § Phase 2.5 mint your credentials](install.md#phase-25--mint-your-credentials) | `mint-secrets.sh --cert FILE`, sealing against a fetched certificate rather than a live controller | [4](#4-carry-in-the-three-prerequisites--required) |
| Every node, before Phase 3 | Point containerd at your mirror in `/etc/rancher/k3s/registries.yaml` and restart k3s. This is the primary mechanism | [2](#2-mirror-the-images--required) |
| Your site values, before Phase 3 | Set `global.certIssuer`. Set `global.imageRegistry` only on the fallback path, where you cannot configure the nodes | [2](#2-mirror-the-images--required), [6](#6-switch-the-certificate-issuer-to-your-internal-ca--required) |
| [install § Phase 3 apply](install.md#phase-3--apply) | Nothing. This step is unchanged | ... |
| After the platform layer is Healthy | Publish the product documentation from a directory built on a connected machine: `tools/publish-docs.sh --context CTX --site DIR`. The docs site shows a placeholder until you do | [7](#7-run-the-install--required) |
| Each later release | Mirror the new images, re-vendor the chart archives and carry the new tag inside first, then run the ordinary upgrade from inside | [8](#8-update-a-disconnected-install--required-at-every-release) |
| After the install, if you run `helm test` | It will fail to pull, by design. That is the test tooling, not your deployment | see [registry](registry.md#helm-test-is-not-air-gap-capable-and-that-is-deliberate) |

Everything else on [fresh-install](fresh-install.md) and [install](install.md)
is unchanged, including the four values you supply and the whole of Phase 3.

## 1. Point every node at a LAN time source ... Required

**Do this before k3s installs.** A certificate issued by a node five minutes
ahead is "not yet valid" everywhere else for five minutes, and the error blames
the certificate.

**YOU SUPPLY:** the time source. Most firewalls serve NTP (OPNsense and pfSense
included); a NAS can; a GPS-disciplined source is the fully-disconnected
answer. Point every node's `chrony` or `timesyncd` at that source **and nothing
else** ... a node still configured against public pools on an air-gapped network
holds its drift silently forever.

**NODE** ... every one of them. chrony shown; timesyncd is the same idea

```bash
sudo sed -i 's|^pool .*|server TIME_SOURCE_IP iburst|' /etc/chrony.conf
sudo systemctl restart chronyd
```

**Success condition ... run on EVERY NODE:**

**NODE**

```bash
chronyc tracking | grep -E 'Reference ID|System time'
timedatectl show -p NTPSynchronized
date -u
```

`Reference ID` names your source and not a public pool, `NTPSynchronized=yes`,
and `date -u` agrees across every node to within a second. **Compare the nodes
to each other, not to your watch** ... a whole site that is consistently wrong
by an hour installs fine; a site that disagrees internally does not.

The symptoms this prevents, and why none of them mention the clock:
[architecture § time is the external with no diagram box](../architecture.md#time-is-the-external-with-no-diagram-box-and-the-worst-symptoms).

**The long form is [time synchronisation for a disconnected site](time-sync.md).**
It covers how to choose a source when nothing has an upstream, a drop-in that
survives a package update, a source that serves the other nodes, how drift
presents and how to recover a cluster that already has it, and a verification
set that compares the nodes to each other. Read it before you decide what the
source is.

## 2. Mirror the images ... Required

Runs on the **CONNECTED** host, then crosses the boundary.

`images.txt` ships with every release, generated from the charts themselves
rather than hand-maintained, so it cannot drift from what actually deploys. It
is at the root of the source tree you already cloned:

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
wc -l < images.txt
grep -vcE '^[[:punct:]]|^$' images.txt
```

The first prints 47 lines: every image reference, plus a three-line header. The
second prints 44 image references, the number to mirror ... it drops the blank
lines and the header, whose lines open with a comment marker rather than with a
registry path.

**YOU SUPPLY:** your registry, in place of `REGISTRY_HOST/mirror`. It is the
same prefix the node-side mirror below rewrites pulls onto.

**See what it would do first.** The dry run copies nothing and names every
reference it would touch.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
./tools/mirror-images.sh --registry REGISTRY_HOST/mirror --dry-run
```

**Then do it**, with the same registry argument and `--dry-run` dropped. The two
are separate blocks deliberately: pasted together, the copy would start before
you had read what the dry run said.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
./tools/mirror-images.sh --registry REGISTRY_HOST/mirror
```

The script is idempotent: a destination already holding the same digest is
skipped, so re-running after a partial failure copies only what is missing, and
it exits non-zero naming anything that failed. Run it against a registry on the
connected side and then move the registry, or run it across a one-way transfer.

It also encodes the path handling that bites anyone rolling their own, because
`global.imageRegistry` keeps the organization and drops the upstream host:
[registry § how `global.imageRegistry` rewrites an image reference](registry.md#how-globalimageregistry-rewrites-an-image-reference).

**Success condition:**

**WORKSTATION** ... inside the boundary, with the uplink already cut if you can

```bash
./tools/mirror-images.sh --registry REGISTRY_HOST/mirror --verify
```

It prints `44 entries, 44 present, 0 missing` and exits 0. **Every entry, not a
catalogue count**: on 2026-08-24 a registry catalogue held 41 entries while 3
of the 44 then in the list were unresolvable, because a repository appears in the catalogue
as soon as one architecture variant lands. `--verify` asks for each entry's
manifest at the exact reference the chart will pull and exits 1 naming any
single miss. Then spot-check one image from the **node** itself, which is the
thing that will actually pull:

Pick the image from `images.txt` rather than from this page, so the test asks
for exactly the tag you mirrored. On the connected host,
`grep -m1 '/grafana/grafana:' images.txt | sed 's#^docker\.io/##'` prints the
Grafana entry with the upstream registry host stripped, which is the path it
has in your mirror.

**NODE** ... inside the boundary. **YOU SUPPLY:** your mirror registry host, and
the Grafana path that command printed. Use whichever one of these three the node
has; they are alternatives, not a sequence.

```bash
export MIRROR_REGISTRY=YOUR_MIRROR_REGISTRY_HOST
export IMAGE=YOUR_GRAFANA_IMAGE_PATH
sudo /usr/local/bin/k3s ctr images pull "$MIRROR_REGISTRY/mirror/$IMAGE"
skopeo inspect --raw "docker://$MIRROR_REGISTRY/mirror/$IMAGE" >/dev/null
crane manifest "$MIRROR_REGISTRY/mirror/$IMAGE" >/dev/null
```

A manifest comes back for an image you picked out of `images.txt`, fetched
**from inside the boundary**. **A `docker images` listing on the connected host
is not this test** ... it proves the copy started, not that the boundary side
can serve it.

### Then point the nodes at your mirror ... the primary mechanism

**Configure the node-side containerd mirror. This is the mechanism a
disconnected install relies on**, and it is the one the 2026-08-25 exercise
ran: `global.imageRegistry` was left **empty** and every image in the list (44 that day)
pulled through the mirror, with no per-chart wiring at all. A containerd mirror
rewrites the pull below the manifest, so it covers every image regardless of
whether the chart that ships it has ever heard of a Tockmox values key. On k3s
it is `/etc/rancher/k3s/registries.yaml` on **every node**, followed by a k3s
restart; the procedure, with its own success condition, is
[external integrations § point containerd at Harbor](../administration/external-integrations.md#3-point-containerd-at-harbor-on-every-node),
and the reason this rather than a values key is the real air-gap answer is
[registry § a cache is not a mirror](registry.md#a-cache-is-not-a-mirror-and-only-one-of-them-survives-a-cut-uplink).

The `rewrite` block in that file is what maps an upstream path onto the prefix
you mirrored into, so write it against the same `REGISTRY_HOST/mirror` you gave
`tools/mirror-images.sh` above.

### `global.imageRegistry` is the fallback

**Use it only if you cannot configure the node runtime**, which is the case on
a managed Kubernetes where you do not own the nodes. In your site values, once
[install § Phase 1](install.md#phase-1--generate-your-site-repository) has
generated them:

```yaml
# site/values/global.yaml
global:
  imageRegistry: REGISTRY_HOST/mirror
```

**`global.imageRegistry` does not reach every image, and that is a documented
limitation of the fallback rather than a defect queue.** It is a convention that
works only in charts that read it, and `tools/check-airgap.sh` carries
22 exemptions at the 0.8.0 tree, naming the images it does not reach: 21
upstream images, and the Tockmox UI's, which your site builds and names in full
in `tockmoxUi.image`, so there is nothing to redirect. The gate
stays, because a site on this path needs to know exactly which images to wire
by hand: for each one, override that chart's own registry key in your site
values. Which key, per chart, is
[registry § how `global.imageRegistry` rewrites an image reference](registry.md#how-globalimageregistry-rewrites-an-image-reference).
A site with the node-side mirror in place needs none of this and can leave the
key empty.

## 3. Vendor the upstream Helm subcharts ... Required

Runs on the **CONNECTED** host.

`.gitignore` excludes `charts/*/charts/` and `*.tgz`, so no dependency archives
are tracked. ArgoCD resolves them on every render, from these 14 repositories:

```
https://argoproj.github.io/argo-helm              https://kubereboot.github.io/charts
https://charts.goauthentik.io                     https://metallb.github.io/metallb
https://charts.jetstack.io                        https://piraeus.io/helm-charts/
https://charts.longhorn.io                        https://prometheus-community.github.io/helm-charts
https://grafana-community.github.io/helm-charts   https://traefik.github.io/charts
https://grafana.github.io/helm-charts             https://helm.openwebui.com
oci://ghcr.io/berriai                             oci://ghcr.io/cloudnative-pg/charts
```

**The first step is the one that is easy to miss.** `helm dependency build`
fails on the 7 layers that have upstream dependencies until every repository
above is registered locally, with an error that names the missing repositories
but not the fix:

```
Error: no repository definition for https://charts.jetstack.io, ...
Please add the missing repos via 'helm repo add'
```

`tools/helm-deps.sh` does exactly this. It derives the repository list from the
`Chart.yaml` files rather than hardcoding it, so it cannot drift when a
dependency is added:

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
./tools/helm-deps.sh
```

**Success condition.** The second line computes what the first should say, so
this check cannot rot when a dependency is added or removed.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
find charts -name '*.tgz' | wc -l
grep -hc 'repository:' charts/*/Chart.yaml | paste -sd+ - | bc

du -ch $(find charts -name '*.tgz') | tail -1
```

The two counts match. At the 0.6.0 tree on 2026-09-01 that number is **28**:
19 upstream archives plus each layer's copy of `tockmox-common`. **Roughly 4 MB
in total is a belief carried from the 2026-08-25 exercise**, not a figure
re-measured here; read the `du` line rather than trusting it.

Then either carry the archives inside and keep them beside the charts clone, or
mirror the 14 repositories into a chart repository you host and point
`Chart.yaml` at it. Carrying the archives is the smaller job and is what the
2026-08-25 exercise did.

## 4. Carry in the three prerequisites ... Required

Runs on the **CONNECTED** host, then the **WORKSTATION**.

[fresh-install](fresh-install.md) requires all of these **before Tockmox
installs at all**, and none of them appears in `images.txt`, because every entry
in that file is a Tockmox workload.

| Prerequisite | Normally fetched from | What has to cross the boundary |
|---|---|---|
| ArgoCD | the `argo/argo-cd` chart | the chart archive plus its images |
| sealed-secrets | `oci://registry-1.docker.io/bitnamicharts/sealed-secrets` | the chart archive plus its image |
| `kubeseal` CLI | GitHub Releases | one binary, onto your workstation |

**Pull the two charts as archives.**

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm pull argo/argo-cd --version CHART_VERSION_YOU_CHOSE
helm pull oci://registry-1.docker.io/bitnamicharts/sealed-secrets \
  --version CHART_VERSION_YOU_CHOSE
```

**YOU SUPPLY:** both chart versions.
[fresh-install § 6](fresh-install.md#6-install-argocd) and
[§ 7](fresh-install.md#7-install-sealed-secrets-with-your-own-key) tell you how
to read them, and which floors apply. Mirror each chart's images the same way
you mirrored the rest, then install from the local archives instead of a
repository name. The image list for a chart you carried in is whatever
`helm template` of that archive renders for the values you will install with;
that has not been run here for these two charts, so check the result against
what the pods ask for rather than trusting a list:

**WORKSTATION**

```bash
helm install argocd ./argo-cd-CHART_VERSION_YOU_CHOSE.tgz \
  --namespace argocd --create-namespace
helm install sealed-secrets ./sealed-secrets-CHART_VERSION_YOU_CHOSE.tgz \
  --namespace kube-system
```

**If you use `bootstrap-secrets`** (from 0.7.0) instead of installing
sealed-secrets by hand, it takes the archive and a mirror for the image:
`--chart ./sealed-secrets-2.20.0.tgz --image-registry YOUR_REGISTRY`. Pull chart
2.20.0 from `https://bitnami.github.io/sealed-secrets` (controller 0.40.0, image
`docker.io/bitnami/sealed-secrets-controller`), and mirror that one image the way
you mirrored the rest. Like ArgoCD's, it is not in `images.txt`. This path has
not been run in an air-gapped environment.

**Success condition:** the same ones
[fresh-install](fresh-install.md#6-install-argocd) gives for a connected
install. Nothing about the checks changes; only where the chart came from does.

### `kubeseal` seals offline, against a fetched certificate

**Conditional: if your workstation has no route to the sealed-secrets
controller.** Test it with
`kubectl -n kube-system get svc sealed-secrets`; if that answers, skip this and
use the normal path.

`kubeseal` is a workstation dependency, not a cluster one, and
`tools/mint-secrets.sh --cert FILE` seals against a fetched certificate instead
of a live controller, so you can mint every sealed secret with no cluster
contact:

**WORKSTATION** ... once, while you can still reach the controller, and from
inside your site repository: `mint-secrets.sh` writes into `secrets/` relative
to where it is invoked rather than to where it lives.

```bash
kubeseal --fetch-cert \
  --controller-name sealed-secrets \
  --controller-namespace kube-system \
  > pub-sealed-secrets.pem

./tools/mint-secrets.sh --cert pub-sealed-secrets.pem
```

The `--controller-*` flags name the same Service the check above probes.
`kubeseal`'s own default is `sealed-secrets-controller`, which no install these
docs describe ever creates, so `--fetch-cert` without them writes a zero-byte
`pub-sealed-secrets.pem` and every offline seal after it fails against an empty
certificate. Do not drop them.

**Success condition:** `ls secrets/*.sealed.yaml` lists files, and
`grep -c encryptedData secrets/*.sealed.yaml` is non-zero for each. A sealed
secret with no `encryptedData` block was not sealed.

This replaces the fetch inside
[install § Phase 2.5](install.md#phase-25--mint-your-credentials); everything
else about that phase, including when the secrets get applied, is unchanged.

## 5. Serve both git repositories inside the boundary ... Required

ArgoCD reads both of these on **every reconcile**, not only at install time. No
image mirror covers them, and a disconnected cluster that cannot reach them
cannot apply anything at all.

- **Your site repository.** [install § Phase 2](install.md#phase-2--publish-it)
  states this outright: ArgoCD reads your values over git, so the repository
  must be reachable from the cluster. Push to your internal server rather than
  to GitHub.
- **The Tockmox charts repository.** `tockmox.repoURL` is a first-class setting
  precisely so you can point it at an internal copy. The installer resolves the
  revision against whatever you name before generating anything, so a wrong
  value fails early and loudly rather than at sync time.

```yaml
# site/tockmox.yaml
tockmox:
  repoURL: git://GIT_HOST/tockmox.git
  revision: THE_TAG_YOU_CLONED
```

**Serve the smart protocol, and do not trust the git CLI to tell you whether you
do.** Standing up an internal git host as a static file server over bare
repositories is the cheap version, and it is the one that fails in a way your
own check cannot see: `git ls-remote` and `git clone` both succeed over the dumb
protocol, so your verification passes, and ArgoCD's repo-server (which needs the
smart protocol) then fails with `failed to list refs: unexpected EOF`.
`git daemon` over `git://` is the smallest thing
that works; `git-http-backend` behind any web server also works; ArgoCD also
accepts a `file://` path to a bare repository. A static HTTP file server serves
git's dumb protocol, which the git CLI clones from perfectly and ArgoCD's
repo-server cannot read at all. The failure names neither git nor the protocol:
[ArgoCD § a static file server fools the git CLI and not the repo-server](../administration/argocd.md#a-static-file-server-fools-the-git-cli-and-not-the-repo-server).
If you build the server inside the cluster, `alpine/git` ships neither
`git-daemon` nor `git-http-backend`; the ArgoCD image has both under
`/usr/lib/git-core/` and is already on the node, which makes it the choice that
needs nothing carried in (same section).

**Success condition**, run from inside the boundary, both repositories:

**WORKSTATION**

```bash
: "${GIT_HOST:?export GIT_HOST first, see the smart-protocol test above}"
curl -fsS "https://$GIT_HOST/tockmox.git/info/refs?service=git-upload-pack" | head -c 24
git ls-remote "git://$GIT_HOST/tockmox.git" HEAD
```

The first prints a packet line, not a directory listing. The second prints a
SHA. **Run the first one even though the second passes** ... the second passing
alone is the exact trap this step exists for.

## 6. Switch the certificate issuer to your internal CA ... Required

Public ACME issuance needs internet. A platform whose TLS expires after ninety
days disconnected is not disconnected-capable, so renewal has to work offline
indefinitely:

```yaml
# site/values/global.yaml
global:
  certIssuer: private-ca-issuer
```

**YOU SUPPLY:** the issuer name, which must match a `ClusterIssuer` or `Issuer`
you create. Standing up the CA and getting the cluster to trust it is
[TLS and trust](../administration/tls-and-trust.md).

**Success condition**, after the platform layer syncs:

**WORKSTATION**

```bash
kubectl get clusterissuer private-ca-issuer \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
kubectl get certificate -A -o wide
```

The issuer reports `True`, and every Certificate shows `READY=True` with a
`NOT AFTER` date. A Certificate stuck without a `READY` column value is
usually an issuer name that does not match.

## 7. Run the install ... Required

Nothing else is different. Go to [prepare a fresh cluster](fresh-install.md) if
you have not built the cluster yet, then [installation](install.md), and use
the [what changes, and where](#what-changes-and-where) table above as you go.

**The documentation site is one more step, and the only one that needs a
toolchain.** The product docs are not in any image (Tockmox publishes none,
ADR-0036); `tools/publish-docs.sh` builds them from your checkout and uploads them
through a pod made from `alpine/k8s`, an image you already mirrored for the
bootstrap Job. The build needs the pinned MkDocs packages in
`docs-site/requirements.txt`, which a dark site cannot `pip install`. So on a
connected machine, from the same checkout at the same tag, run
`tools/build-docs.sh DIR`, carry `DIR` across, and run
`tools/publish-docs.sh --context CTX --site DIR` from inside (the gates run on
the directory before anything is uploaded). Or mirror PyPI for those packages and
build inside. Until you do, the docs host shows a placeholder page. See
[Publishing the product documentation](../administration/serving-static-sites.md#publishing-the-product-documentation).
This path was run from behind a cut uplink on 2026-10-09 (single-node k3s
lab, uplink dropped at the guest's firewall with a packet meter on the uplink
interface): the publish from the carried directory and the fetch of the
published pages and their assets completed with zero packets leaving the
cluster; the only outbound attempts during the run were CoreDNS forwards to
the lab's own external resolver, which a dark site does not configure.

**Success condition:** the one [install](install.md) already gives, plus one
this page adds:

**WORKSTATION**

```bash
kubectl -n argocd get applications
kubectl get pods -A | grep -E 'ImagePullBackOff|ErrImagePull' \
  || echo "no image pull failures: correct"
```

All nine layers Synced and Healthy, and no pull failures anywhere. **A pull
failure here is almost always step 2, not the layer the error came from**: a
node whose `registries.yaml` was not written or not restarted into, an image
missing from the mirror, or, on the `global.imageRegistry` fallback path, an
image that key does not reach.

## 8. Update a disconnected install ... Required, at every release

**An update repeats the connected half of the install for the new tag, then runs
the ordinary upgrade from inside.** The mirror you built in steps 2 to 5 is the
thing you update: images, chart archives and the Tockmox git tag go in first,
and nothing in the boundary ever reaches the internet. This is the
mirror-once-then-update-from-your-mirror path that takes the place of a shipped
offline bundle, which
[registry](registry.md#why-there-is-no-offline-image-bundle) explains.

**Order is the whole procedure.** Everything the new release needs has to be
inside the boundary **before** the revision moves. Move the revision first and
ArgoCD reports `ComparisonError` for a tag it cannot find, or the pods report
`ImagePullBackOff` for an image the mirror lacks. Neither error says the mirror is
behind.

**Keep the old release inside the boundary until you accept the new one.**
[Rolling back](upgrade.md#roll-back) re-renders the old tag and pulls the old
images from your mirror. A mirror cleaned of the previous release cannot roll
back. `tools/mirror-images.sh` adds images and never removes one.

### Before you begin an update

| What you need | Why | How to check |
|---|---|---|
| The install from steps 1 to 7, still in place | Every sub-step reuses its registry, its git server and its transfer path | `kubectl -n argocd get applications` shows nine layers `Synced` and `Healthy` |
| A **connected host** with a clone of the Tockmox source tree and the tools from [before you begin](#before-you-begin) | Sub-steps 8.1 to 8.4 run there | `git -C "$TOCKMOX" status --short` prints nothing |
| The same clone path on the **workstation inside the boundary** | Sub-steps 8.5 to 8.7 run there. It is the clone that filled your internal git server | `git -C "$TOCKMOX" tag --list "$CURRENT_REVISION"` prints your current revision |
| The release notes read, from your current revision to the target | They name every action the update needs, and say when ArgoCD or k3s must move first | [upgrade § 1](upgrade.md#1-read-the-release-notes) |

**YOU SUPPLY:** the revision you run now and the one you are moving to. Set them
on each host you use, with the path to its clone of the source tree.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
export TOCKMOX=YOUR_TOCKMOX_CLONE_PATH
export CURRENT_REVISION=YOUR_CURRENT_REVISION
export TARGET_REVISION=YOUR_TARGET_REVISION
git -C "$TOCKMOX" fetch origin --tags
git -C "$TOCKMOX" tag --list "$CURRENT_REVISION" "$TARGET_REVISION"
```

**Success condition:** the last command prints both revisions. A missing line
is a tag the clone does not have, and every later command in this step would
quietly compare against nothing.

### 8.1 Verify the target tag ... Required

Do it on the connected host, before anything is mirrored from it. The signed tag
is the check that covers every release, and it is the last chance to look at
the source before it is carried in: [verifying what you
downloaded § 1](verify.md#1-verify-the-signed-tag), with `TAG` set to
`$TARGET_REVISION`.

**Success condition:** the one [verify](verify.md#1-verify-the-signed-tag) gives.

### 8.2 See what the new release asks for ... Required

Two lists decide the work: the images, and the chart archives.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
: "${TOCKMOX:?export TOCKMOX first, see the start of step 8}"
: "${CURRENT_REVISION:?export CURRENT_REVISION first, see the start of step 8}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see the start of step 8}"
git -C "$TOCKMOX" diff "$CURRENT_REVISION" "$TARGET_REVISION" -- images.txt \
  | grep -E '^[-+][a-z0-9]' || echo "images.txt unchanged"
git -C "$TOCKMOX" diff "$CURRENT_REVISION" "$TARGET_REVISION" -- 'charts/*/Chart.lock' \
  | grep -E '^[-+] *(name|version):' || echo "no dependency moved"
```

**Success condition:** you can say which images the mirror lacks. A line
starting `+` is an image the new release pulls and the mirror does not hold.
A line starting `-` is one the new release stops asking for: leave it, because
the rollback needs it. In the second list, each pair is a dependency archive
that changes version, which 8.4 replaces.

### 8.3 Mirror the new images ... Required

This is [step 2](#2-mirror-the-images--required) again, from the target tree.
`tools/mirror-images.sh` reads `images.txt` from where you run it, and it skips
every destination that already holds the same digest, so only what is missing
crosses.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
: "${TOCKMOX:?export TOCKMOX first, see the start of step 8}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see the start of step 8}"
cd "$TOCKMOX"
git checkout --detach "$TARGET_REVISION"
./tools/mirror-images.sh --registry REGISTRY_HOST/mirror --dry-run
```

Read the dry run, then run the same command without `--dry-run`, as in step 2.
The success condition for this sub-step is checked from inside the boundary in
8.6, because only the inside can say what a node will be able to pull.

If you use the [`global.imageRegistry` fallback](#globalimageregistry-is-the-fallback)
and not the node-side mirror, also read
`git -C "$TOCKMOX" diff "$CURRENT_REVISION" "$TARGET_REVISION" -- tools/check-airgap.sh`.
An image added to that script's exemption list is one the key does not reach,
and your site values have to wire it by hand.

### 8.4 Re-vendor the chart archives ... Required

This is [step 3](#3-vendor-the-upstream-helm-subcharts--required) again.
**Replace the archives; do not add to them.** Helm loads every archive in a
layer's `charts/` directory, so the old and the new version of one dependency
side by side fail the render with a schema error that blames your values. It
was seen on a dependency bump, and it is invisible in git because the directory
is ignored.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
: "${TOCKMOX:?export TOCKMOX first, see the start of step 8}"
cd "$TOCKMOX"
rm -rf charts/*/charts
./tools/helm-deps.sh
```

**Success condition:** the two counts in
[step 3](#3-vendor-the-upstream-helm-subcharts--required) match. Then carry the
archives inside the way you did the first time, replacing the old ones.

### 8.5 Carry the target tag inside ... Required

A git bundle carries exactly the commits between the two revisions, as one file
for whatever moves bytes across your boundary. It requires your current
revision to exist at the other end, which it does if the inside clone filled
your git server.

**CONNECTED** ... outside the boundary, never a cluster NODE

```bash
: "${TOCKMOX:?export TOCKMOX first, see the start of step 8}"
: "${CURRENT_REVISION:?export CURRENT_REVISION first, see the start of step 8}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see the start of step 8}"
git -C "$TOCKMOX" bundle create "$HOME/tockmox-$TARGET_REVISION.bundle" \
  "$CURRENT_REVISION..$TARGET_REVISION"
```

Move `tockmox-$TARGET_REVISION.bundle` across the boundary. On the inside, from
the clone that filled your git server:

**WORKSTATION** ... inside the boundary. **YOU SUPPLY:** the remote or URL of the
repository [step 5](#5-serve-both-git-repositories-inside-the-boundary--required)
serves, and the path the bundle landed at.

```bash
export TOCKMOX=YOUR_TOCKMOX_CLONE_PATH
export TARGET_REVISION=YOUR_TARGET_REVISION
export BUNDLE=YOUR_BUNDLE_PATH
export CHARTS_REMOTE=YOUR_INTERNAL_CHARTS_REMOTE
git -C "$TOCKMOX" bundle verify "$BUNDLE"
git -C "$TOCKMOX" fetch "$BUNDLE" "refs/tags/$TARGET_REVISION:refs/tags/$TARGET_REVISION"
git -C "$TOCKMOX" push "$CHARTS_REMOTE" "$TARGET_REVISION"
```

**Success condition:** `bundle verify` prints `is okay`, and the tag is now on the
server ArgoCD reads (8.6 checks that). `bundle verify` failing with `requires
this ref` means the inside clone does not hold your current revision; fix that
before going on.

### 8.6 Prove everything is inside ... Required

Both checks run from inside the boundary, and both name the thing that will
actually be asked for.

**WORKSTATION** ... inside the boundary

```bash
: "${TOCKMOX:?export TOCKMOX first, see the start of step 8}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see the start of step 8}"
: "${GIT_HOST:?export GIT_HOST first, see step 5}"
git ls-remote --tags "git://$GIT_HOST/tockmox.git" "$TARGET_REVISION"
cd "$TOCKMOX"
git checkout --detach "$TARGET_REVISION"
./tools/mirror-images.sh --registry REGISTRY_HOST/mirror --verify
grep -vcE '^[[:punct:]]|^$' images.txt
```

**Success condition:** the first command prints a SHA and the tag name. The
`--verify` line reads `N entries, N present, 0 missing`, and `N` equals the
last command's count, which is the new release's image count. If you serve the
charts over HTTP, also run the smart-protocol check in
[step 5](#5-serve-both-git-repositories-inside-the-boundary--required): a tag that
lists with `git ls-remote` can still be unreadable to ArgoCD's repo-server.

### 8.7 Run the upgrade ... Required

Now, and not before, run [upgrade to a new release](upgrade.md) from
[step 0](upgrade.md#0-write-down-what-you-are-on-now) through
[step 7](upgrade.md#7-confirm-the-workloads-actually-came-up), unchanged. Its
step 1 read of the notes and its step 2 backup apply here as they do on a
connected site.

Add one check to the end of step 7, from step 7 of this page:

**WORKSTATION**

```bash
kubectl get pods -A | grep -E 'ImagePullBackOff|ErrImagePull' \
  || echo "no image pull failures: correct"
```

**Success condition:** the "correct" line. A pull failure here is almost always
8.3 or the node-side mirror of [step 2](#2-mirror-the-images--required), not the
layer that reports it.

### 8.8 Republish the documentation ... Optional

**What you get:** the docs site inside the boundary matches the release you now
run. What you lose by skipping it: the site keeps serving the previous
release's pages. On a connected machine, from the same checkout at the target
tag, `tools/build-docs.sh DIR`; carry `DIR` across; then
`tools/publish-docs.sh --context CTX --site DIR` from inside, as in
[step 7](#7-run-the-install--required).

### 8.9 When the release moves ArgoCD or k3s ... Conditional

**Run this if** the release notes say a prerequisite floor moved. Do it before
8.7, one change per window: [upgrade ArgoCD and k3s](upgrade-foundations.md) has
the air-gapped ArgoCD route and the k3s note, and its own list of what has not
been run.

### 8.10 After you accept the release ... Optional

The previous release's images are now only a rollback target. The mirror tool
has no prune, so removing them is your registry's own retention or garbage
collection, and it is a decision to take after the rollback window you set
yourself, not a step of the update. Keep the previous release's bundle and
chart archives for the same reason.

## What is not certified here

The 2026-08-25 result at the top of this page is a measurement of **one
build on one date, on the reference lab**: a greenfield install with the uplink
cut at the route level. It is not a claim that this page has been executed
start to finish as written, and it is not a claim about any later build. The
counts in the tables above were read from the 0.6.0 tree on 2026-09-01, from
`images.txt`, the `Chart.yaml` files and `tools/check-airgap.sh`; they will move
with the tree, and the gates print their own totals every run.

**The update path in step 8 has not been run.** It is composed from the first
install's steps, the tools' documented behaviour and the upgrade page, and no
disconnected site has been taken from one release to the next with it. What was
run is narrower: the two `git diff` readings in 8.2 against real release tags in a
connected checkout, and the bundle commands in 8.5 against a scratch repository
rather than the Tockmox one. The order it insists on (everything inside before the
revision moves) and the failures it names for the wrong order are reasoned from
how ArgoCD resolves a revision and how a node pulls an image, not observed.

Two claims on this page are **beliefs rather than measurements**, because
nothing tests them:

- That the `helm pull` and local-archive install in step 4 is equivalent to the
  connected path. It follows from how Helm resolves a chart archive, and it was
  not separately exercised.
- That a `file://` bare repository is a sufficient answer for step 5. ArgoCD
  documents it; the 2026-08-25 exercise used `git daemon`.

Documented procedures are verified by running them, not by reviewing them. The
[testing standard](../testing-standard.md) says which paths are covered.

## Next

- [Prepare a fresh cluster](fresh-install.md) then [installation](install.md)
  ... the flow this page modifies
- [Upgrade to a new release](upgrade.md) ... what step 8 hands over to once the
  new release is inside the boundary
- [A container registry](registry.md) ... what to run as the mirror, and why
  there is no bundle
- [Time synchronisation](time-sync.md) ... step 1 in full: choosing the source,
  what drift looks like, and how to verify it
- [TLS and trust](../administration/tls-and-trust.md) ... standing up the
  internal CA step 6 needs
- [External integrations](../administration/external-integrations.md#3-point-containerd-at-harbor-on-every-node)
  ... the node-side containerd mirror

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

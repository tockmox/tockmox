---
okf_version: "0.2"
type: HowTo
title: "Skill: air-gap preparation"
description: "How an agent prepares a disconnected Tockmox install: the five dependencies that must be inside the boundary, the six points where the normal install diverges, and the two checks that catch a false pass."
tags: [agents, skills, airgap, offline, mirroring, registry, machine]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [machine, operator]
---

# Skill: air-gap preparation

**Use this when** an operator is installing with no internet access at the site.

**Say this first, because it changes how they plan:** this is the normal install
with six things done differently. It is not a separate procedure. They do
[prepare a fresh cluster](../../deployment/fresh-install.md) and
[install](../../deployment/install.md) in the usual order and use
[air-gapped](../../deployment/airgap.md) at the six points where a disconnected
site diverges. Everything else, including the whole of Phase 3, is unchanged.

**Say this second, because it sets expectations correctly:** Tockmox
distributes source, never binaries. **There is no single-artifact offline
installer and the project does not claim one.** If the operator is expecting a
bundle to copy across, tell them now rather than at the transfer.

## The five dependencies, and the one that stops them before they start

Miss any of these and the install stops. Row 3 is the only one with no tooling
behind it at all.

| # | What must be inside the boundary | What Tockmox ships for it |
|---|---|---|
| 1 | Every workload image | `images.txt` and `tools/mirror-images.sh` |
| 2 | Every upstream Helm subchart | `tools/helm-deps.sh` |
| 3 | **ArgoCD, sealed-secrets, and the `kubeseal` binary** | **nothing** |
| 4 | The Tockmox charts git repository | `tockmox.repoURL` points at their copy |
| 5 | Their own site git repository | the install page states the requirement |

**Row 3 is the one to raise first.** An operator can mirror every image, vendor
every chart, host both repositories internally, and still be unable to begin,
because the three things that must exist before Tockmox installs at all appear
in no mirroring artefact Tockmox ships.

**The inventory order and the step order are different, deliberately.** This
table is a dependency inventory ... it is third here. On the air-gap page it is
**step 4**, because the steps are the order the work happens in. Do not read the
step number as a priority; row 3 is the earliest thing to plan for and one of
the last things done.

**Derive the counts, do not quote them.** The page prints the commands and dates
its numbers; run them against the tree the operator actually has. The first line
counts the images to mirror, the second counts the vendored archives, the third
counts the dependencies those archives are supposed to cover:

```bash
grep -cE '^[[:alnum:]]' images.txt
find charts -name '*.tgz' | wc -l
grep -hc 'repository:' charts/*/Chart.yaml | paste -sd+ - | bc
```

`images.txt` carries a generated header, so the first line counts entries by
matching the ones that start with a name rather than by excluding the comment
lines. It returns exactly what the older `grep -vc '^#\|^$'` form returned,
verified against the shipped file, and it is written this way so the whole block
pastes into an interactive zsh, where the comment character is not a comment.

The second and third must match. That check is written so it cannot rot when a
dependency is added.

## What else the boundary needs, beyond artefacts

Four things that are not files and are easy to leave off a plan:

- **A registry inside the boundary**, with push access, reachable from a node.
- **A git server inside the boundary speaking git's smart protocol.** ArgoCD
  reads both repositories on **every reconcile**, not just at install.
- **A LAN time source.** Nothing on a disconnected network reaches
  `pool.ntp.org`, and clock drift breaks TLS and SSO with errors that name
  neither.
- **An internal CA and its key material.** Public ACME issuance needs internet,
  and renewal has to keep working offline indefinitely.

## The two checks that catch a false pass

Both exist because the obvious test passes while the real thing is broken. Run
them explicitly; do not accept the easier one as evidence.

**Smart protocol, not `git clone`.** The git CLI also speaks the dumb protocol
and ArgoCD's repo-server does not, so a static file server clones perfectly and
fails every sync.

```bash
export GIT_HOST=YOUR_GIT_HOST
curl -fsS "https://$GIT_HOST/tockmox.git/info/refs?service=git-upload-pack" | head -c 24
```

A smart server answers with a packet line. A static file server answers with a
directory listing, a 404, or raw bytes. **Run this even though `git ls-remote`
passes** ... `ls-remote` passing alone is the exact trap.

**Pull from inside the boundary, not from the connected host.** A `docker
images` listing on the connected side proves the copy started, not that the
boundary can serve it.

Run this from a cluster node, inside the boundary, with the uplink cut if that
is possible.

**YOU SUPPLY:** your mirror registry host. The image is **read out of
`images.txt` rather than hand-picked**, so the check cannot be run against an
image the manifest does not actually list.

```bash
export MIRROR_REGISTRY=YOUR_MIRROR_REGISTRY_HOST
IMAGE="$(grep -E '^[[:alnum:]]' images.txt | head -1)"
echo "checking $IMAGE"
skopeo inspect --raw "docker://$MIRROR_REGISTRY/mirror/$IMAGE" >/dev/null
```

**Repeat for an image from a different upstream.** A mirror can be complete for
one registry and empty for another. Change `head -1` to `sed -n '20p'`, or pipe
`grep -E '^[[:alnum:]]' images.txt` through `sort -u -t/ -k1,1` to take one
image per registry host.

## Time comes first, before k3s

Do this before the cluster is built. A certificate issued by a node five minutes
ahead is "not yet valid" everywhere else for five minutes, and the error blames
the certificate.

Point every node at the LAN source **and nothing else**. A node still configured
against public pools on a disconnected network holds its drift silently forever.

**Compare the nodes to each other, not to a watch.** A whole site consistently
wrong by an hour installs fine; a site that disagrees internally does not.

## `global.imageRegistry` is not the whole answer

It is a convention that works only in charts that read it, and
`tools/check-airgap.sh` carries a list of exemptions ... run it to see how many
against the current tree rather than quoting a number.

For images it does not reach, either override that chart's own registry key in
site values, or configure a **node-side containerd mirror**, which rewrites
pulls below the manifest and therefore covers everything regardless of what any
chart reads. On k3s that is `/etc/rancher/k3s/registries.yaml`.

**The containerd mirror is the real air-gap answer.** If the operator is
choosing one mechanism, that is the one. A pull-through cache is not a mirror,
and only one of the two survives a cut uplink.

## Sealing without a route to the controller

If the workstation cannot reach the sealed-secrets controller, `kubeseal` can
seal against a fetched certificate and `mint-secrets.sh --cert FILE` uses it.

**Do not drop the `--controller-name` and `--controller-namespace` flags.**
`kubeseal`'s own default names a controller no documented install ever creates,
so `--fetch-cert` without them writes a **zero-byte** certificate file and every
offline seal afterwards fails against it. Check the file is non-empty, and check
each sealed file has an `encryptedData` block ... a sealed secret without one was
not sealed.

## Two things that are expected to fail, and are not defects

- **`helm test` will fail to pull, by design.** That is the test tooling, not
  their deployment.
- **Nothing about Phase 3 changes.** If they are looking for an air-gap variant
  of the apply phase, there isn't one.

## Success condition

```bash
kubectl -n argocd get applications
kubectl get pods -A | grep -E 'ImagePullBackOff|ErrImagePull' \
  || echo "no image pull failures: correct"
```

All nine layers Synced and Healthy, and no pull failures anywhere. **A pull
failure here almost always names an image `global.imageRegistry` did not
reach**, which is the node-side mirror question rather than anything wrong in
the layer the error came from.

## What is proven, and what is believed

Be precise about this; a disconnected site cannot go and check.

The air-gap page records a full exercise on **2026-08-25**: a teardown, an
uplink cut at the route level for both IPv4 and IPv6, and a greenfield install
with all nine layers Synced and Healthy and zero image pull failures. **That is
one build on one date on the reference lab.** It is not a claim that the page
has been executed start to finish as written, and not a claim about any later
build.

Two things on that page are **beliefs, not measurements**, because nothing tests
them: that the `helm pull` and local-archive install of the prerequisites is
equivalent to the connected path, and that a `file://` bare repository is
sufficient for the git requirement. The 2026-08-25 exercise used `git daemon`.

Pass both of those on if the operator is planning around either.

## What this skill will not do

- Promise an offline bundle. There is not one.
- Accept `git clone` or `git ls-remote` as evidence that ArgoCD can read a
  repository.
- Accept a connected-side image listing as evidence the mirror works.
- Quote an image count, an archive count or an exemption count without running
  the command against the operator's tree.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

## History and corrections

What this page used to say, and when it changed. Nothing here is needed to follow the page.

<a id="history-the-registry-placeholder"></a>

### The registry placeholder

`MIRROR_REGISTRY` was written as a bare `REGISTRY_HOST` inside the command
until 2026-09-11. That spelling is the worst kind of placeholder: uppercase
without `YOUR_` and without brackets, so it reads as a value, pastes verbatim,
and fails with a DNS error naming a host nobody chose (TM-0484, RULE 4 of
`check-pasteable-blocks.sh`).

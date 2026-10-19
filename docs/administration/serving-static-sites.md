---
okf_version: "0.2"
type: HowTo
title: "Serving documentation and static sites from Garage"
description: "How the shipped Garage serves the product documentation at docs.<internalDomain> (published from your checkout by tools/publish-docs.sh, no image), and how to serve your own static sites from it with garage.web.sites."
tags: [garage, documentation, static-sites, web, ingress, airgap]
status: draft
generated:
  by: hand
  at: 2026-09-30
tockmox:
  classification: public
  audience: [operator]
---

# Serving documentation and static sites from Garage

The shipped [object store](storage.md#the-shipped-object-store-and-what-one-copy-covers)
also serves websites. Garage has a web endpoint on port 3902 that returns the
objects in a bucket as a static site. You list a site under `garage.web.sites`
and the chart makes the bucket, the key and the Ingress and, if you name a
content image, a CronJob that fills the bucket from it.

The chart serves the product's own documentation this way, on by default, at
`docs.<global.internalDomain>`. **Tockmox publishes no container image of the
documentation** (ADR-0036: the project ships source and build recipes, never
images or other compiled artifacts). So the docs bucket is not filled by the
cluster. You fill it, once after the install and again after each upgrade, by
running `tools/publish-docs.sh` from your checkout of this repository at the
tag you deployed. Until you do, the docs host shows a one-page placeholder that
names that command. [Publishing the product documentation](#publishing-the-product-documentation)
is the procedure.

**Read [What is not certified here](#what-is-not-certified-here) before relying
on this page**: it says which parts have been run on a cluster and which have not.

## What you get on a stock install

`apps.docs` follows the `dataProtection` capability, like `apps.garage`, and
`garage.web.sites` ships one entry, the site named `docs`. With both on, a stock
install renders:

- the Garage web endpoint (`[s3_web]` on `[::]:3902`), a `web` container port and
  a `web` port on the `tockmox-garage` Service;
- a bucket whose global alias is `docs.<global.internalDomain>`, with website
  access on, made by the `tockmox-garage-bootstrap` Job;
- a writer key for that bucket only, in the Secret `tockmox-garage-site-docs`,
  which `tools/publish-docs.sh` uses;
- a ConfigMap `tockmox-garage-docs-placeholder` holding a one-page placeholder,
  which the bootstrap Job uploads to the bucket **only when the bucket holds no
  object at all** (so it never overwrites published documentation, and a
  re-run of the bootstrap Job after an upgrade leaves the docs alone);
- an Ingress `garage-web-docs` for `docs.<global.internalDomain>` routed to the
  Service port 3902, and, when `global.certIssuer` is set, the Certificate that
  cert-manager issues for its `tls` block.

It renders **no sync CronJob and no image for the docs**, and no render names
`ghcr.io/tockmox/tockmox-docs`. Nothing in that list reaches the internet at run
time. To keep the object store and not serve the docs:

```yaml
apps:
  docs:
    enabled: false
```

Turning `apps.docs` on while `apps.garage` is off fails the render.

## Publishing the product documentation

```sh
git checkout v0.8.1            # the tag your site's tockmox.revision names
./tools/publish-docs.sh --context YOUR_KUBECONTEXT --config tockmox.yaml --wait 600
```

`--config` is the installer's config file, from which the script reads
`tockmox.revision`; `--revision REV` names it directly. The installer's last
step, `install/tockmox-install.sh publish-docs`, is the same command and only
warns (exit 0) when the documentation generator is absent, so an install never
fails over documentation. The installer itself applies nothing and does not
wait, so this is a step you run once the `tockmox-platform` Application is
Synced and Healthy, not one it runs for you.

What the script does, in order, and what it refuses:

1. **Builds** the site with `tools/build-docs.sh` from the checkout, or takes a
   directory you built elsewhere with `--site DIR`. The build needs the pinned
   MkDocs set (`docs-site/requirements.txt`, in a Python virtual environment).
   Without it the script exits 2 and changes nothing.
2. **Gates** the directory: `tools/check-docs-offline.sh` (no page fetches from
   the network) and `tools/check-docs-site-contents.sh` (only static web
   content: an allowlist of extensions, no executable, script, symbolic link or
   file that starts like an ELF, Mach-O or PE binary whatever its name), and
   refuses a directory without an `index.html`.
3. **Refuses a checkout that is not the revision the site deploys**: `git
   describe --tags --exact-match` (or the commit, for a revision given as one)
   must equal `tockmox.revision`. `--force` overrides it, for a rehearsal.
4. **Copies the site in through a short-lived pod** in `tockmox-platform`, made
   from the `alpine/k8s` image that `images.txt` lists (the image the bootstrap
   Job already uses, so an air-gapped site has mirrored it; `--registry HOST`
   prefixes it the way `global.imageRegistry` does). The pod has the restricted
   security context and the labels the chart's sync Job has, and the Secret
   `tockmox-garage-site-docs` as environment variables by `secretKeyRef`.
   The script checks that the Secret exists by name and never reads its data, so
   nothing secret is printed or copied to your workstation, and no S3 client,
   port-forward or credential is needed there. `kubectl cp` needs `tar` in the
   image.
5. **Runs the same guarded sync the chart's CronJob runs**: an index-less source
   is refused, every file is touched first (so a same-size edit is published),
   and `aws s3 sync --delete` makes the bucket match. It then writes the marker
   object `.tockmox-docs-version` (`{"ref":...,"commit":...,"tree_sha256":...}`)
   and reads it back through the bucket's web endpoint from inside the pod,
   checking that `/` is 200 and a missing page is 404. With `--url
   https://docs.int.example.com` it checks the same through the Ingress from your
   machine (`--curl-arg` passes options such as `--cacert`).
6. **Deletes the pod on every exit path** and says so. The pod also has a
   30-minute `activeDeadlineSeconds`, so a killed script cannot leave one behind.

Every `kubectl` call in the script names its cluster (`--context`), there is no
default, and `KUBECONFIG` is honoured. `tools/check-harness-context.sh` scans the
script for a bare call.

**Air-gapped sites** have one path with one difference. A dark site cannot `pip
install` the pinned generator, so build the directory on any connected machine
(same checkout, same tag), bring it across, and run
`./tools/publish-docs.sh --context CTX --site DIR`. The gates run on the directory
either way. Mirroring PyPI for `docs-site/requirements.txt` is the alternative
([air-gapped installs](../deployment/airgap.md)).

**An Argo-only operator** (no installer) runs the command by hand. **After an
upgrade** the docs are one command out of date until you run it again from the
checkout at the new tag; the marker object and the page
[upgrading](../deployment/upgrade.md) say how to read it. Stale documentation is
cosmetic: no data or function depends on it.

**To read what is published**, without a browser:

```sh
curl -fsS https://docs.int.example.com/.tockmox-docs-version
```

## How a request is served

Garage answers a web request from a bucket when website access is enabled on
that bucket and the `Host` header equals one of its **global aliases**, or is
`<bucket><root_domain>`. Every site this chart configures uses the first form:
the site host is the bucket alias. That is why `host` is at most 63 characters
(a bucket name limit) and why no host may end with the web root domain, which
defaults to `.web.<global.internalDomain>` and is set with `garage.web.rootDomain`.
The render fails on either.

Traefik forwards the original `Host`, so the Ingress needs nothing beyond the
host and the port.

## Serving your own sites

Each entry in `garage.web.sites` is one bucket. This is what a site would set
for three sites, using documentation names:

```yaml
garage:
  web:
    sites:
      # Restate the docs entry. Helm replaces a list instead of merging it, so a
      # list without an entry named docs drops the product documentation, and the
      # render fails while apps.docs is on. The name docs is reserved for the
      # product documentation: it takes no content.image and keeps writerKey.
      - name: docs
        host: ""
        index: index.html
        errorDocument: 404.html
        ingress: true
        writerKey: true
        content: {}
      # Filled from outside, for example by a CI job that publishes a wiki.
      - name: kb
        host: kb.int.example.com
        index: index.html
        errorDocument: 404.html
        ingress: true
        writerKey: true
      # Filled by an image you build and publish: its licence and your registry.
      - name: handbook
        host: handbook.int.example.com
        ingress: true
        content: {image: registry.example.com/team/handbook:1.4.0, path: /site}
```

| Field | Meaning |
|---|---|
| `name` | DNS label, at most 32 characters (a CronJob name may have 52 and `tockmox-garage-sync-` takes 20). Names the Ingress `garage-web-<name>`, the Secret `tockmox-garage-site-<name>` and the CronJob `tockmox-garage-sync-<name>`. `docs` is reserved for the product documentation. |
| `host` | The `Host` the site answers on and the bucket alias. Empty means `<name>.<global.internalDomain>`. |
| `index`, `errorDocument` | Website index and error objects. |
| `ingress` | Render an Ingress to port 3902. Without it the site is reachable only from inside the cluster. |
| `writerKey` | Mint a key with read and write on this one bucket into `tockmox-garage-site-<name>`. It holds `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `REGION`, `BUCKET` and `ENDPOINT`. Minted once, never overwritten. The `docs` site always gets one. |
| `content` | `image` syncs any image that holds the site under `path` (default `/site`) with a CronJob, and implies a writer key. Empty means someone else fills the bucket: a CI job, or for `docs` the operator running `tools/publish-docs.sh`. |

The web endpoint turns on by itself when any site is listed. `garage.web.enabled:
true` turns it on with none.

A sync run needs its content image to hold a POSIX shell with `cp`. It never
needs network tools, and the Job container that uploads is separate.

Publishing from outside works the same way as the sync does, with the
writer Secret's values: an S3 client pointed at `ENDPOINT`, path-style
addressing, region `REGION`, and `--delete` if the upload should remove pages
that no longer exist.

## Carried data: an existing Garage under this chart

The bootstrap Job reads before it writes. If the Garage volumes already hold a
bucket that answers to a site's host, the Job keeps that bucket and logs it; it
never recreates one. If website access is already on for the bucket, the index
and error documents already set stay as they are. A writer Secret that already
exists is never overwritten, and its key is not minted again. A grant that cannot
be made because the Secret names a key this Garage does not know is logged as a
warning and skipped, so the Job still finishes. What does fail the Job is a
site it cannot leave serving: a bucket it cannot find or create, or one whose
website flag it cannot turn on. A bucket that already holds any object, for
example documents an earlier install published, gets no placeholder. This has
been checked by running the rendered decision logic against stubbed admin calls,
not against a Garage.

## If a content image cannot be pulled

This applies to a site of your own with a `content.image` that is unpullable (a
typo, a private image with no pull secret). The `content` init container of its
`tockmox-garage-sync-<name>` run then cannot pull. An image that cannot be
pulled does not fail a Pod, so what ends the run is the Job's bound, not its
retry count: each run has `activeDeadlineSeconds: 900` and fails after 15
minutes (measured in the lab, 2026-09-30: `DeadlineExceeded` at 14 min 58 s).

**The failure stays in the namespace.** The sync is a CronJob, not an ArgoCD
hook, on purpose. A failed hook fails the platform Application's sync
operation; ArgoCD then retried it five times, re-syncing the whole application
each time, and the operation stayed `Running` for about 100 minutes before
ending `Failed`, blocking every other operation on the storage, network and
certificate layer. With the CronJob the Application is `Synced`, `Healthy` and
its operation `Succeeded` while the run fails, and the site simply answers with
an empty bucket. Nothing else is affected: the object store, the backups and
every other site keep working. The `content` container prints `cp: can't
preserve ownership of '/work/.'` on every run; it is harmless and the run still
exits 0 (seen on the lab, 2026-09-30).

**Changing any `garage.web` key restarts `tockmox-garage-0`.** On the lab
(2026-09-30) each change rolled the single Garage pod, and the object store is
unavailable while it restarts; the restart was not timed, and which keys cause
it was not tested one by one.
New content reaches a `content.image` site's bucket at the next run, or now with
`kubectl -n tockmox-platform create job --from=cronjob/tockmox-garage-sync-handbook sync-now`.

**One run at install, and why it is not a Job in the chart.** With
`garage.web.syncAtInstall: true` (the default) the last step of the
`tockmox-garage-bootstrap` Job runs
`kubectl create job tockmox-garage-sync-handbook-<chart version> --from=cronjob/tockmox-garage-sync-handbook`
for each `content.image` site, once the bucket and the writer Secret exist, and
does not wait for it. The
step is best effort: if it cannot create the Job, the bootstrap Job logs a
`WARN` and still succeeds, and the hourly run publishes instead. The name
carries the chart version with dots as hyphens, so an upgrade starts one run
for the new content and a second sync of the same version finds the name taken
and does nothing. A run started this way is a copy of the CronJob's
`jobTemplate`, so it has the same pod, security context and bounds; it is
removed a week after it finishes. A Job shipped as an ordinary manifest was
rejected because ArgoCD holds the PostSync bootstrap Job back until every other
resource is Healthy, and the Job would be waiting for a Secret that Job makes.
Set `syncAtInstall: false` to publish on the schedule only. The docs site has
no sync run: the placeholder is the only thing the bootstrap Job puts there.

## Who can read it

**The web endpoint is anonymous.** Anyone who can reach port 3902, or the Ingress
host, can read every object in a website-enabled bucket. The docs are public
documentation, so the docs Ingress ships without authentication. There is no
forward-auth in this chart. For a site that must not be public, leave `ingress`
false and put your own authenticating proxy in front of the Service port.

With `networkPolicy` on, the platform namespace's policy allows traffic between
its own pods, and the platform layer's Traefik runs in that namespace, so
Traefik reaches port 3902 without a rule of its own (measured on a lab cluster,
2026-09-30: `/` answered 200 and a missing page 404 through the Ingress). The
publish pod reaches Garage's S3 port 3900 the same way (measured). A site that moves Traefik to another namespace needs
an allow for port 3902 from it.

## Checking it

```sh
kubectl --context YOUR_KUBECONTEXT -n tockmox-platform get svc tockmox-garage -o jsonpath='{.spec.ports[*].name}'
kubectl --context YOUR_KUBECONTEXT -n tockmox-platform get secret tockmox-garage-site-docs
curl -fsS https://docs.int.example.com/ | head -c 200
curl -fsS https://docs.int.example.com/.tockmox-docs-version
```

The first should list `web`. On a fresh install the third returns the
placeholder page until `tools/publish-docs.sh` has run, and the documentation's
HTML after; the fourth returns the marker only after it has run. On a
disconnected cluster both must work with no request leaving the cluster.

## What is not certified here

- **The lab evidence is one single-node lab cluster** (2026-09-30): the
  placeholder appeared only when the bucket was empty, `tools/publish-docs.sh`
  published 111 files and the marker matched the checkout, and a second run that
  changed one page without changing its size updated it. The rest of this page
  was written from the chart source, `helm template` and the publish script's
  stub-kubectl self-test.
- The Garage v2 admin API shapes used for website access are taken from its
  documentation and not confirmed against every Garage version.
- Whether `kubectl cp` works against a given cluster depends on `tar` in the
  pod's image and on Pod Security admission of the pod; the script fails with
  the API server's message if either refuses. It worked on the lab cluster,
  whose platform namespace carries `warn` and `audit` at `restricted` and no
  `enforce` label, so a cluster that enforces `restricted` was not tried (the pod
  is built to satisfy it).
- That the published site contains no reference to the internet is a property of
  what you publish; `tools/check-docs-offline.sh` reads the built files, and
  `tools/check-airgap.sh` checks only the images the charts name.
- The tag check trusts `git` and the local tag. It is not a signature check;
  verify the tag itself ([RELEASING](../../RELEASING.md)).
- One node, one copy: a site served from here has the durability of the
  [shipped store](storage.md#the-shipped-object-store-and-what-one-copy-covers).

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

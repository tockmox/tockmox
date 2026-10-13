---
okf_version: "0.2"
type: HowTo
title: "Removing an application"
description: "Take an application you added under apps/ back out of a running Tockmox, including the four things the site-apps prune leaves behind: backups, site values, Authentik objects and the DNS record. Miniflux is the worked example."
tags: [site-apps, argocd, cloudnative-pg, authentik, backups, dns]
status: draft
generated:
  by: hand
  at: 2026-10-02
tockmox:
  classification: public
  audience: [operator]
---

# Removing an application

This is the other half of [adding an application](adding-an-application.md),
with the same worked example: Miniflux, in a namespace called `news`, with its
own database, a single sign-on registration and a hostname. Substitute your own
names; the order is the point (TM-0800).

`site-apps` syncs with `prune: true`, so deleting an app's files from `apps/`
deletes it from the cluster. **Four things survive that:** backups in the object
store, site values that name the app, the Authentik objects its blueprint
created, and the DNS record. Remove them in the order below so the data goes
last.

**Read [What is not certified here](#what-is-not-certified-here) first.** This
procedure has been written from the wiring on the adding page and has not yet
been run end to end on a cluster.

Set `KUBE_CONTEXT` as in [install](../deployment/install.md#set-these-once) and
confirm the server behind it before deleting anything:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Set these once}"
kubectl config view --minify --context="$KUBE_CONTEXT" \
  -o jsonpath='{.clusters[0].cluster.server}'; echo
```

## 1. Take a final backup

Deleting the namespace deletes the database volume. If you want the data, back
it up first and wait for the backup to read `completed`:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Set these once}"
kubectl --context="$KUBE_CONTEXT" apply -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: miniflux-db-final, namespace: news }
spec:
  cluster: { name: miniflux-db }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
YAML
kubectl --context="$KUBE_CONTEXT" -n news get backup miniflux-db-final \
  -o jsonpath='{.status.phase}'; echo
```

**Success condition:** the second command prints `completed`. Run it again
until it does; a backup that is still `started` has not finished writing to the
object store.

## 2. Remove the single sign-on registration

Authentik keeps a blueprint's objects after the blueprint is gone, and the
provider keeps accepting its client secret. Either set both entries in the
blueprint (the application and the `tockmox-miniflux` provider) to
`state: absent` and let it apply once, or delete the application and the
provider in the Authentik admin interface.

**Success condition:** the Authentik admin interface lists neither the
application nor the provider.

## 3. Remove the files and push

Do this in one commit:

- Delete the app's files from `apps/`: the manifests, the sealed `miniflux-oauth`
  Secret and the `miniflux-sso-blueprint` ConfigMap.
- In `site/values/identity.yaml`, drop `miniflux-sso-blueprint` from
  `authentik.blueprints.configMaps`. **Keep `tockmox-sso-blueprints`:** Helm
  replaces a list rather than merging it, so the shipped entry has to stay in
  the list you leave behind.
- In `site/values/platform.yaml`, drop `news` from `garage.credentialsNamespaces`
  if you added it there. The same list replaces, so keep the entries you did not
  add (the chart's own default names `tockmox-ai` and `tockmox-authentik`).
- Remove `MINIFLUX_CLIENT_SECRET` from the `tockmox-sso` Secret, then restart the
  Authentik worker after the sync, because it reads the Secret at pod start.

ArgoCD then prunes the namespace and everything in it.

## 4. Remove the DNS record

Delete `news.<internalDomain>` from your LAN DNS.

## 5. Delete the backups, when you are sure

Nothing above deletes the backup objects. When your retention allows it, delete
them from the bucket the app's `ObjectStore` named. **This cannot be undone**,
and it includes the final backup from step 1.

## 6. Check

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Set these once}"
kubectl --context="$KUBE_CONTEXT" get namespace news
kubectl --context="$KUBE_CONTEXT" -n argocd get application site-apps \
  -o jsonpath='{.status.sync.status} {.status.health.status}'; echo
```

**Success condition:** the first command answers `NotFound`, and `site-apps`
reports `Synced`. Its health depends on what else is left in `apps/`; an
application that is `Degraded` for a reason of its own is not this procedure's
doing.

Authentik lists neither the application nor the provider, and Prometheus no
longer shows the `miniflux` target or the `MinifluxDown` rule.

## What is not certified here

**This page has not been run against a cluster.** It is the removal counterpart
of the wiring on the adding page, written from that wiring. The steps that
depend on behaviour this repository does not itself pin are the ones to watch:
that an Authentik blueprint entry set to `state: absent` removes the provider as
well as the application, and that the restarted worker no longer holds the
removed client secret. If either does not hold on your install, delete the
objects in the admin interface, which is the other route step 2 offers.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

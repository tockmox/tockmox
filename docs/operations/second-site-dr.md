---
okf_version: "0.2"
type: HowTo
title: "Restore a site at a second location"
description: "Rebuild a lost Tockmox site at another location from its site repository, the escrowed sealed-secrets key, the CA and the off-site backups, in the order that works, and what that order does not bring back."
tags: [disaster-recovery, backup, restore, sealed-secrets, escrow, site-repository, cloudnative-pg, longhorn]
status: stable
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [operator]
---

# Restore a site at a second location

**A second site is a new cluster built from the things that outlive the first:
the site repository, the sealed-secrets key, the CA's key, and the backups held
off the lost site.** This page is
[the restore order](backup-restore.md#7-the-whole-cluster-story-in-one-place)
run at a different location, with each place that order needs a decision filled
in. It needs no connection between the two sites, and none exists.

**What this is not.** It is not failover. Nothing replicates to the second site,
nothing detects the first site's loss, and nothing switches traffic. It is a
rebuild from backups, and its data loss is whatever the newest backup of each
kind missed. Connecting two running Tockmox sites to each other is a different
idea that is not built.

**Nothing on this page has been run as one exercise.** Two of the five steps in
the restore order it follows have never been run at all. Read [what is not
certified here](#what-is-not-certified-here) before you rely on it, and run the
[readiness check](#before-the-disaster-the-readiness-check) today, while the
first site still exists.

## What survives, and what does not

Each row is a thing the second site needs and the single condition under which
it survives the loss of the first site.

| What | Survives site loss when | If it does not |
|---|---|---|
| **Configuration** (every Tockmox resource) | The site repository has a git remote that is not on the lost site and that the second site can reach | Nothing to restore from. GitOps is the manifest backup, and there is no other |
| **Secrets** | The sealed-secrets controller key was exported, encrypted, to somewhere off the lost site, and the identity that opens the export is kept apart from it ([escrow](sealed-secrets-key-escrow.md)) | Every SealedSecret in the repository is unreadable noise. The key cannot be regenerated |
| **The CA** | The CA's key is sealed into the site repository ([bring your own CA](../administration/bring-your-own-ca.md)), so the escrowed key brings it back | The second site mints a **new** CA with the same name and a different key. It works, and every machine that trusted the old CA now rejects every console until it trusts the new one |
| **Databases** (the model gateway's, Authentik's on CloudNativePG) | The object store they archive to is not on the lost site, and its credentials are sealed in the repository | The shipped Garage runs in the cluster. A database archived only to it is lost with the cluster |
| **Volumes** | A Longhorn backup of the volume exists on a BackupTarget off the lost site | The volume comes back empty |
| **The substrate** (OS, Kubernetes) | Never carried. It is rebuilt, not restored | Not applicable: the second site's nodes are new |

**Not carried by any of them,** so absent on the second site until it makes them
again: metrics and log history, Grafana changes made in its UI, Alertmanager
silences, the notification topic's history, the contents of the shipped object
store (the restore-drill register is an object in it, so its history is not carried either), and any volume with no Longhorn
backup. The last one is yours to check; the readiness check below counts the
backups that exist.

## Before the disaster: the readiness check

Everything on this page depends on what was true before the loss. The checks
below take minutes and each one names the failure it prevents. Run them from the
workstation you administer the **first** site from, today.

**Where each command runs:** every block on this page is **WORKSTATION**.

**YOU SUPPLY:** your site repository path, the first site's kube context, and the
escrow directory, exported once per shell.

**WORKSTATION**

```bash
export SITE_REPO=YOUR_SITE_REPO_PATH
export KUBE_CONTEXT=YOUR_SITE_A_CONTEXT
export ESCROW_DIR=YOUR_ESCROW_DIRECTORY
test -d "$SITE_REPO/secrets" && echo "site repository found"
```

**1. The site repository has a remote that is not on this site.**

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first}"
git -C "$SITE_REPO" remote get-url origin
git -C "$SITE_REPO" status --short --branch | head -1
```

**Success condition:** the address is a host that survives the loss of this site
(not a server in the cluster, not a machine in the same room), and the second
line shows the branch level with `origin`, with no `ahead`. A site repository
that exists only on the workstation is one disk failure from nothing.

**2. The sealed-secrets key export is newer than the newest sealing key.**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${ESCROW_DIR:?export ESCROW_DIR first}"
kubectl --context "$KUBE_CONTEXT" -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
ls -l "$ESCROW_DIR"
```

**Success condition:** the newest export in the directory is dated after the
newest `CREATED` above. An older export opens everything sealed before the last
renewal and nothing after it
([escrow § keep it current](sealed-secrets-key-escrow.md#5-keep-it-current-and-know-what-the-controller-does-with-several-keys--required)).

**3. The databases archive somewhere that survives, and are archiving.**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get objectstores.barmancloud.cnpg.io -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ENDPOINT:.spec.configuration.endpointURL,PATH:.spec.configuration.destinationPath
kubectl --context "$KUBE_CONTEXT" -n tockmox-ai get cluster.postgresql.cnpg.io tockmox-litellm-db \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'
kubectl --context "$KUBE_CONTEXT" -n tockmox-authentik get cluster.postgresql.cnpg.io tockmox-authentik-db \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'
```

**Success condition:** each store's endpoint is **not** the shipped Garage (a
name containing `garage` inside the cluster, or the cluster's own address), and
both clusters print `True`. A database that archives only to the Garage in its
own cluster is not protected against losing that cluster
([the circular dependency](backup-restore.md#7-the-whole-cluster-story-in-one-place)).
If your install keeps Authentik on the bundled PostgreSQL, the second command
for it does not apply; its protection is the nightly dump in
[backup-restore § 6](backup-restore.md#6-what-else-wants-backing-up), which
writes to the same shipped store.

**4. Longhorn backs up to a target that survives, and backups exist.**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" -n longhorn-system get backuptargets.longhorn.io default \
  -o jsonpath='{.spec.backupTargetURL}{"  available="}{.status.available}{"\n"}'
kubectl --context "$KUBE_CONTEXT" -n longhorn-system get backups.longhorn.io --no-headers | wc -l
```

**Success condition:** the target is an NFS or S3 address outside this site, it
reads `available=true`, and the count is not zero. Zero backups on a healthy
target means nothing has written to it yet.

**5. The CA is recoverable.**

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first}"
ls "$SITE_REPO/secrets" | grep -i -E 'ca-root|ca\.sealed' || echo "no sealed CA in the site repository"
```

**Success condition:** a sealed CA Secret is listed. The line `no sealed CA in the
site repository` is a decision rather than a fault: the second site will mint a
new CA, and every machine will re-trust it. If that is not acceptable, do
[bring your own CA](../administration/bring-your-own-ca.md#4-move-the-key-without-re-minting-it--required)
now. It cannot be done after the loss.

## Decide what the second site is

Four decisions, made before step 1, because each changes a file you commit.

| Decision | Recommended | Why |
|---|---|---|
| **The internal domain** | Keep `global.internalDomain` and repoint DNS at the second site | Every hostname, every certificate, every OIDC redirect URI registered in Authentik, every bookmark and every client configuration derives from it. A different domain is a migration of all of them, not a restore |
| **Addresses** | Set `addressPool.range` and `global.lanCIDR` for the second site's network | These describe the network, and the second site's is different. They are the values that cannot be carried over unchanged |
| **Node gateway addresses** | Re-derive them for the second site ([install § 1f](../deployment/install.md#1f-name-each-nodes-gateway-address-for-the-policy-layer)) | The policy layer admits the nodes' gateway addresses |
| **The first site** | Decide it is gone, or that it cannot write | Two sites writing to one object-store path, or answering for one domain, is worse than either being down. CloudNativePG refuses to archive into a path that holds another cluster's backups, and the guards below name the fix |

## 1. Build the second site's substrate ... Required

This is the one step with no Tockmox procedure of its own: it is
[the fresh cluster path](../deployment/fresh-install.md), run on the second
site's hardware, sized by [sizing](../deployment/sizing.md). If the first site ran
three servers, the second does not have to; a single node is a valid, smaller
site.

Do **not** install ArgoCD or Tockmox in this step. Stop when the cluster is
ready and has exactly one default StorageClass.

Point `KUBE_CONTEXT` at the **second** site now, and prove it is not the first:

**WORKSTATION**

```bash
export KUBE_CONTEXT=YOUR_SITE_B_CONTEXT
export SITE_B_SERVER=YOUR_SITE_B_API_SERVER_URL
test "$(kubectl config view --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}')" = "$SITE_B_SERVER" \
  && echo "context is the second site"
kubectl --context "$KUBE_CONTEXT" get nodes
kubectl --context "$KUBE_CONTEXT" get storageclass
```

**Success condition:** `context is the second site` prints, every node is
`Ready`, and exactly one StorageClass is marked `(default)`. If the first line
does not print, stop: every command below names `--context`, and this is the
check that it names the right one.

## 2. Install ArgoCD, then restore the sealed-secrets key before its controller ... Required

Install ArgoCD as [the install path](../deployment/install.md) does. Then,
**before** the sealed-secrets controller has ever started on this cluster, restore
the key into it. A controller that starts first generates a key of its own, and
every SealedSecret in the repository becomes unreadable.

**YOU SUPPLY:** the Tockmox checkout, the export file and the identity that opens
it. The procedure, what it refuses and why are in
[escrow § restore onto a rebuilt cluster](sealed-secrets-key-escrow.md#6-restore-onto-a-rebuilt-cluster--conditional).

**WORKSTATION**

```bash
export TOCKMOX=YOUR_TOCKMOX_CHECKOUT_PATH
export ESCROW_FILE=YOUR_EXPORT_FILE_PATH
: "${SITE_REPO:?export SITE_REPO first}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${ESCROW_DIR:?export ESCROW_DIR first}"
"$TOCKMOX/install/tockmox-install.sh" bootstrap-secrets --mode recover \
  --site "$SITE_REPO" --context "$KUBE_CONTEXT" \
  --key-backup "$ESCROW_FILE" \
  --age-identity "$ESCROW_DIR/escrow-identity.txt" \
  --dry-run
```

Remove `--dry-run` to run it for real. **Success condition:** the run ends with
`sealing key restored into` and `controller installed`, and the controller holds
the number of keys the export holds
([escrow step 3](sealed-secrets-key-escrow.md#3-prove-the-export-opens--required)
gives the count).

## 3. Set the second site's values, and tell the databases to recover ... Required

**This is the step the restore order does not say, and the order it happens in
matters.** The chart's databases bootstrap empty (`initdb`) unless told to
recover, and recovery runs once, at the cluster's first bootstrap. A cluster that
has already started empty does nothing about a recovery setting added later. So
the recovery settings go into the commit the second site first syncs from, before
`bootstrap/root.yaml` is applied.

In the site repository, for the second site:

```yaml
# site/values/global.yaml
global:
  internalDomain: YOUR_INTERNAL_DOMAIN
  lanCIDR: YOUR_SITE_B_LAN_CIDR
```

```yaml
# site/values/platform.yaml
addressPool:
  range: YOUR_SITE_B_ADDRESS_RANGE
```

The model gateway's database and Authentik's both recover from the store they
archived to, under the name they archived as, and write their own archive under
a **new** name. The switches are `modelGateway.database.recovery.enabled` in the
AI layer and `identity.database.recovery.enabled` in the identity layer, both
off by default:

```yaml
# site/values/ai.yaml
modelGateway:
  database:
    recovery:
      enabled: true
      objectStoreName: YOUR_OFFSITE_OBJECTSTORE_NAME
      serverName: tockmox-litellm-db
    backup:
      serverName: tockmox-litellm-db-r1
```

```yaml
# site/values/identity.yaml
identity:
  database:
    recovery:
      enabled: true
      objectStoreName: YOUR_OFFSITE_OBJECTSTORE_NAME
      serverName: tockmox-authentik-db
    backup:
      serverName: tockmox-authentik-db-r1
```

`serverName` under `recovery` is **the first site's** cluster name: the prefix
its backups were written under. `serverName` under `backup` is a **new** name,
because CloudNativePG refuses to archive into a path that already holds another
cluster's backups; the chart refuses to render a recovery that would, and says
which name to change. If your first site archived to a store you named, the
`ObjectStore` and its sealed credentials are already in the repository and arrive
with it.

If the identity database was on the bundled PostgreSQL instead, there is no
recovery switch: it comes back from the nightly dump
([backup-restore § 6](backup-restore.md#6-what-else-wants-backing-up)), by hand,
after the layer is up.

Commit these to the branch the second site syncs from.

**Success condition:**

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first}"
git -C "$SITE_REPO" grep -n -E 'recovery:|enabled: true|serverName' -- site/values/ai.yaml site/values/identity.yaml
git -C "$SITE_REPO" status --short | head
```

The recovery blocks and both `backup.serverName` lines are listed, and the
working tree is clean (the change is committed and pushed, because ArgoCD reads
the remote).

## 4. Give ArgoCD the repository and apply the root ... Required

Give ArgoCD its credential for the site repository
([install § 2c](../deployment/install.md#2c-give-argocd-a-credential--private-repositories-only)),
then apply the root Application, which is the install's second pass
([install § 3a](../deployment/install.md#3a-apply-the-root-application)).

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" apply -f "$SITE_REPO/bootstrap/root.yaml"
kubectl --context "$KUBE_CONTEXT" -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

**Success condition, in two parts.** The restored key opens the repository's
files:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get sealedsecret -A
kubectl --context "$KUBE_CONTEXT" -n kube-system logs deploy/sealed-secrets-controller | grep -i -E 'error|unseal' | tail
```

Every SealedSecret has a matching Secret, and the controller logs no unseal
error. An unseal error names a SealedSecret the exported key cannot open, which
is a stale export.

Then every layer reaches `Synced` and `Healthy`, which takes the install's own
time ([install § 3c](../deployment/install.md#3c-watch-the-waves)). **That is
not yet the success condition for the data.** A database that bootstrapped empty
reports healthy.

## 5. Prove the databases came back with their data ... Required

**Read the data, not the status.** `Cluster in healthy state` is what an empty
database reports too
([backup-restore § 5](backup-restore.md#5-restore-the-part-everyone-skips-until-it-matters--required)).

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" -n tockmox-ai get cluster.postgresql.cnpg.io tockmox-litellm-db \
  -o jsonpath='{.spec.bootstrap}{"\n"}'
kubectl --context "$KUBE_CONTEXT" -n tockmox-ai exec tockmox-litellm-db-1 -c postgres -- \
  psql -U postgres -d litellm -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
kubectl --context "$KUBE_CONTEXT" -n tockmox-authentik exec tockmox-authentik-db-1 -c postgres -- \
  psql -U postgres -d authentik -tAc "SELECT count(*) FROM authentik_core_user;"
```

**Success condition:** the first command shows a `recovery` bootstrap and not
`initdb`; the second prints a count in the dozens, not `0`; the third prints the
number of users the first site had. A user count you wrote down before the loss
is the stronger check, and the weekly drill's register records it
(`users=<n>` in the identity database's rows, [backup-restore § 5](backup-restore.md#the-scheduled-drill-repeats-this-weekly)).

**If a database shows `initdb`,** it started empty before the recovery setting
reached it. Recovery does nothing to a cluster that already exists. Delete the
`Cluster` and its volumes, let the layer recreate it, and check again. That
discards what the empty cluster wrote since it started, which is why step 3
comes first.

## 6. Restore the volumes ... Conditional

**Conditional: a volume you need has a Longhorn backup.** Volumes are the last of
the restore order's steps. Point Longhorn on the second site at the same
BackupTarget the first site used (the credentials Secret arrives sealed with the
repository, and the target is Longhorn's `default` BackupTarget, which the site
values name as `longhorn.defaultBackupStore.backupTarget`), then restore each
volume you need under its original claim name, through the shipped
`longhorn-backup` snapshot class, as the 2026-10-01 production migration did
([backup-restore § what is not certified](backup-restore.md#what-is-not-certified-here)).

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" -n longhorn-system get backuptargets.longhorn.io default \
  -o jsonpath='{.status.available}{"\n"}'
kubectl --context "$KUBE_CONTEXT" -n longhorn-system get backups.longhorn.io \
  -o custom-columns=NAME:.metadata.name,VOLUME:.status.volumeName,STATE:.status.state
```

**Success condition:** the target reads `true`, and the backups the first site
wrote are listed with state `Completed`.

**Not covered:** how to hold a workload back from creating an empty claim while
its volume is restored. A layer that syncs first creates its claims empty, and a
volume restored under the same name has to replace that claim. The production
migration restored volumes before any workload started; a root-driven site does
not give you that gap for free. The route this page expects, deleting the empty
claim and the pod that holds it and then restoring under the same name, has not
been run.

## 7. Cut over and close the loop ... Required

- **Point DNS at the second site's Traefik address**
  ([install § point DNS at Traefik's address](../deployment/install.md#point-dns-at-traefiks-address)).
  If the domain is unchanged, no client is reconfigured.
- **Trust.** If the CA key came back with the repository, nothing to do. If a
  new CA was minted, every machine you browse from must trust it
  ([TLS and trust](../administration/tls-and-trust.md#2-get-the-ca-out-of-the-cluster--conditional)),
  and an already-open browser tab will report a failed fetch rather than a
  certificate error.
- **Escrow the second site's key.** The restored controller holds the first
  site's keys and will renew its own on schedule. Export again
  ([escrow § export the key](sealed-secrets-key-escrow.md#2-export-the-key--required))
  into a new file, off this site.
- **Point backups at a fresh place.** The recovered databases archive under the
  new names from step 3. Confirm both read `ContinuousArchiving` `True` with the
  readiness check's third block, against the second site.
- **Decide the first site's fate** before anything powers it on: wipe it, or
  rebuild it as the new second site. Powering it back on unchanged puts two
  clusters on one domain, one object store and one set of credentials.

**Success condition:** a person signs in through Authentik at the unchanged
hostname with no certificate warning, and the data they had before the loss is
there. That is the check the card behind this page asked to be run once; it has
not been.

## What is not certified here

**This page has been written, not executed.** The execution of this runbook
against a throwaway second cluster is a lab exercise that has not been run, and
this page says nothing about how long it takes: **the recovery time is
unmeasured.** Until a run is dated here, treat every step as a plan.

What the evidence does and does not cover, by step:

| Step | Evidence |
|---|---|
| 1. Build the substrate | The fresh-install path is executed in part by the harness ([the inventory](../testing-standard.md)). Rebuilding a node and the Kubernetes distribution **as part of a restore** has never been run |
| 2. Restore the sealed-secrets key | Restored onto a fresh controller once, on a lab, 2026-10-04. The scheduled drill of that restore has not run. Reinstalling the controller on a rebuilt cluster with the key first has **never been run** |
| 3. The `recovery` values | They render, and the chart refuses the unsafe combinations. The chart's own comment records that they are **not exercised against a live CloudNativePG** in its gates |
| 4. Apply the root | The install path is executed. Applying it onto a cluster whose data is to be recovered is not |
| 5. Database recovery | The destroy-and-restore drill ran on a drill database (2026-08-15), the model gateway's database was restored in production (2026-10-01), and the weekly drill passes. The identity database on CloudNativePG is a render, **not yet a restore** ([backup-restore](backup-restore.md#what-is-not-certified-here)) |
| 6. Volumes | Every volume of one production cluster was restored from an off-cluster target in about 34 minutes (2026-10-01). Not restored onto a cluster the volumes did not come from, and not with the claim ordering above |
| 7. Cutover | Not run |
| The CA | Whether the supplied CA comes back with the repository and the second site issues from the same key is **not proven** ([bring your own CA](../administration/bring-your-own-ca.md#what-is-not-certified-here)) |

Three statements this page makes from reading rather than running: that the
chart's databases bootstrap empty when recovery is off, that a recovery setting
added after the first bootstrap does nothing, and that two sites sharing an
object-store path or a domain is worse than one being down.

The whole restore order, assembled from parts that were each run separately, is
a weaker claim than the order run once; this page will say otherwise when it has
been.

Documented procedures are verified by running them, not by reviewing them. The
[testing standard](../testing-standard.md) says which paths are covered.

## Next

- [Back up and restore](backup-restore.md) ... the five planes and the drills
- [Escrow the sealed-secrets key](sealed-secrets-key-escrow.md) ... the one
  backup that cannot be regenerated
- [Bring your own CA](../administration/bring-your-own-ca.md) ... keeping the CA
  through a rebuild
- [Upgrading](../deployment/upgrade.md) ... after a restore, the second site is
  an ordinary install at the release it restored to

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

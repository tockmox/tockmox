---
okf_version: "0.2"
type: HowTo
title: "Upgrade to a new release"
description: "Move a running cluster from one Tockmox tag to the next: what to back up first, how to move the revision, how to prove every layer landed, and how to roll back."
tags: [upgrade, release, argocd, rollback, gitops, versioning]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Upgrade to a new release

**The edit is one line. The blast radius is the whole cluster.** Changing
`targetRevision` hands ArgoCD a different set of manifests for every layer at
once, and `prune: true` means anything the new release stops declaring is
deleted rather than left behind.

That is why this page is a procedure with a backup step rather than a one-liner.
The one-liner still exists ... it is [step 5](#5-move-the-revision) ... and
everything around it is there so you can undo it.

**An upgrade never edits your site repository's `site/values/`.** The revision
points at the *Tockmox* repository. Your values, your `apps/` and your
`secrets/` are yours and stay where they are. That is not the same as saying
they stay correct: a release can need a value you have not set yet, and the
release notes say which.

**For 0.8.0, three values are required before you push the revision (one only on
a site that backs up a database of its own to the shipped object store, one only
on a site that copied a 0.7.x profile), and two Secrets are required unless you
turn the model gateway off:**

- **`platformNetpol.nodeOriginSources`, unless you have turned
  `apps.platform_netpol` off.** Optional in 0.7.x; from 0.8.0 the policy layer
  refuses to render without it (TM-0798), and `tockmox-policy` sits in
  `ComparisonError` until it is set. Generate it with
  `install/tockmox-install.sh --print-netpol-node-sources --context <yours>`
  and add the block to `site/values/policy.yaml`;
  [install § 1f](install.md#1f-name-each-nodes-gateway-address-for-the-policy-layer)
  has the commands. If your `global.lanCIDR` contains the pod network (a
  `10.0.0.0/8` LAN against k3s's `10.42.0.0/16`), narrow it in the same commit:
  the list refuses a lanCIDR that would re-admit every pod (TM-0790).
- **`platformNetpol.extraS3ClientNamespaces`, for every namespace of your own
  in `garage.credentialsNamespaces`.** Setting `nodeOriginSources` (above) drops
  the 0.7.x rule that admitted the whole pod network to the platform namespace.
  From then on the object store's S3 port admits only the AI and identity
  namespaces and the ones listed in `platformNetpol.extraS3ClientNamespaces` in
  `site/values/policy.yaml`. A database of your own that backs up to the shipped
  Garage from its own namespace (the namespace you added to
  `garage.credentialsNamespaces`, or to `createCredentialsNamespaces`, in
  `platform.yaml`) is otherwise refused, and nothing looks wrong: the Cluster
  reads healthy, and only its `ContinuousArchiving` condition goes `False`, with
  "Can't connect to cloud provider" in the barman plugin's log. List the same
  namespaces in both keys, in the same commit as `nodeOriginSources`.
  Run `install/tockmox-install.sh --lint` against your site repository: it names
  any namespace in the first key that is missing from the second. Measured on the 0.8.0-rc1 lab
  greenfield, where a Miniflux database in `news` stopped archiving.
- **`kube-prometheus-stack.grafana.persistence.storageClassName`, if you built
  your site by copying the `minimal` or `household-sso` profile from 0.7.x and
  your `global.storageClass` is not `longhorn`.** The 0.8.0 profiles carry
  `storageClassName: local-path` under `kube-prometheus-stack.grafana.persistence`;
  a copied 0.7.2 profile does not. From 0.8.0 `tockmox-observability`
  refuses to render that mismatch (TM-0146), and sits in `ComparisonError`
  naming the key until you set it to your `global.storageClass`. Measured on a
  lab upgrade that dropped the line. A site that set the literal itself is
  unaffected.
- **The model gateway is on by default from 0.8.0, and the console goes
  through it** (TM-0460; REQ-0004 AC-4.1). `apps.litellm` follows
  `capabilities.aiPlane` where it shipped `false`, and `open-webui` ships
  pointed at `http://<release>-litellm:4000/v1` on the key in
  `tockmox-openwebui-gateway`, which the AI layer's console-key Job now mints.
  What that needs from you depends on where the site is today:

  | Your 0.7.x site | Before the bump |
  |---|---|
  | Runs the gateway, console pointed at it (install.md's "Mint the console's model-gateway key" done) | Nothing. `tockmox-litellm`, `tockmox-litellm-db` and `tockmox-openwebui-gateway` exist; the Job finds the console's Secret, confirms the gateway still accepts its key, and exits (a key the gateway rejects is replaced and the console restarted on it). Keep `apps.litellm.enabled: true` in `global.yaml` (below) or drop it; both render the same |
  | Gateway off, console pointed at a model host directly in `ai.yaml` | Seal `tockmox-litellm` and `tockmox-litellm-db` (`mint-secrets.sh` mints both by default now) and commit them, or `tockmox-ai` goes Degraded on the sync with the proxy in `CreateContainerConfigError`. Your `openaiBaseApiUrl` wins, so the console keeps talking to the host directly, and the gateway runs beside it with an empty model list. **That re-opens AC-4.1 on your site**; move the host into `litellm.proxy_config.model_list` (plus `aiEgress.litellm.extraEgress` for a LAN host) and delete the console's `openaiBaseApiUrl` when you are ready, and the console-key Job mints the key on the next sync |
  | Gateway off, console at nothing | Same two Secrets, or turn the gateway off deliberately: `apps.litellm.enabled: false` in `site/values/global.yaml` (every layer reads it, so the exporters layer stops probing it) and `open-webui.enableOpenaiApi: false` in `ai.yaml`. The render refuses the first without the second, naming both |

  Nothing is minted for you on a cluster: the two Secrets are sealed files in
  your site repository, and the Job needs the master key one to run. The order
  is Secrets first, then the revision bump, in two commits if you want the
  first one proven (`kubectl -n tockmox-ai get secret tockmox-litellm`) before
  the second.

  On this path `mint-secrets.sh` also mints a third file,
  `tockmox-openwebui-bootstrap-admin` (TM-0859), that no row above asks for.
  It is harmless on a console that already has accounts: Open WebUI creates
  that administrator only while it has no accounts, so the Secret goes unused
  and your users keep theirs. The consequence is on the model list: with no
  bootstrap administrator,
  [install § let everyone in the console see the models](install.md#let-everyone-in-the-console-see-the-models)
  stops with a sign-in error, and until someone grants the models, a
  `tockmox-users` member sees an empty model picker while everything reads
  green. After the upgrade, sign in as a `tockmox-admins` member and make each
  model public under **Admin Settings ... Models**.
- **`apps.litellm.enabled` belongs in `site/values/global.yaml` (or
  `exporters.yaml`), whichever way you set it.** The exporters layer probes the
  gateway's console as its own values files say, and it does not read
  `ai.yaml`. Through 0.8.0's lab upgrade from 0.7.2, a site that set
  `apps.litellm.enabled: true` only in `ai.yaml` lost the gateway's uptime
  probe (TM-0910); with the gateway on by default that site is probed again
  with no edit. The case that now needs the global file is the other one: a
  site that turns the gateway off only in `ai.yaml` keeps a probe for a host
  nothing serves, and `TockmoxConsoleUnreachable` pages for it.

Upgrading a pre-public install to 0.7.0 needed these:

- **`aiEgress.litellm.extraEgress`, required if your model host is on the LAN,
  in another namespace or on a port other than 443.** The AI namespace is
  default-deny for egress from 0.7.0, and without the entry the gateway's
  requests to that host time out. A backup to your own S3 endpoint needs
  `aiEgress.cnpg.extraEgress` in the same way. (Found on the lab upgrade,
  2026-09-30: the site's model host on the LAN needed exactly one entry, its
  address and ports.) Both keys belong to the policy layer, so they go in
  `site/values/policy.yaml`, and each entry is a NetworkPolicy egress rule
  (`to` and `ports`), not `providerAllow`'s `{cidr, ports}`:

  ```yaml
  # site/values/policy.yaml
  aiEgress:
    litellm:
      extraEgress:
        - to: [{ipBlock: {cidr: 192.0.2.10/32}}]
          ports: [{protocol: TCP, port: 11434}]
  ```
- **`podSecurity`**, only if you run your own workloads in one of the five
  namespaces that now enforce a Pod Security level.
- **`platformNetpol.nodeOriginSources`** is optional hardening in 0.7.x.
  Leaving it empty keeps the previous behaviour there; from 0.8.0 it is
  required (above).
- Loki mirror lists, for air-gapped sites (see the [air-gap
  guide](airgap.md)).
- **Leave `garage.createCredentialsNamespaces` empty.** It is new in 0.7.0 and
  it is for a new site, whose namespace does not exist yet. On an existing
  install, moving a namespace you already run into it can delete that namespace
  and everything in it; see [below](#do-not-move-an-existing-namespace-into-garagecreatecredentialsnamespaces).

Read [step 1](#1-read-the-release-notes) before you push the revision, and make
these edits in the same commit as the bump.

**This page moves Tockmox. It does not move what Tockmox runs on.** ArgoCD and
k3s are yours to upgrade, in their own window and ahead of a revision bump; the
order and the procedures are in
[upgrading ArgoCD and k3s](upgrade-foundations.md).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| A clone of your **site repository**, with push access, exported as `SITE_REPO` | The revision lives in `bootstrap/applications/*.yaml` there. Every change on this page is a commit | After the export below, `git -C "$SITE_REPO" push --dry-run` succeeds |
| Every layer already `Synced` and `Healthy` | Upgrading a red cluster means you cannot tell the release from the fault that was already there | `kubectl -n argocd get applications` shows no `OutOfSync` and no `Degraded` |
| The revision you are on now, written down | This is the rollback target. Reading it off a broken cluster later is harder than writing it down now | [Step 0](#0-write-down-what-you-are-on-now) below prints it |
| A database backup you have restored at least once | An upgrade that deletes a PVC is recoverable only from a backup that works. An untested backup is not a backup | [backup and restore](../operations/backup-restore.md) has the drill |
| The release notes for every version between here and there | Breaking changes are per-release and do not accumulate into the latest one | [CHANGELOG.md](../../CHANGELOG.md) opens |
| The cluster's kubeconfig context, exported as `KUBE_CONTEXT` | Every success condition on this page reads cluster state, and every block names the cluster rather than trusting the current context | After the export below, the printed API server is the cluster you mean |

**YOU SUPPLY:** four values, once, exported so that every block below is
pasteable as printed. `KUBE_CONTEXT` is the kubeconfig context of the cluster
you are upgrading. `SITE_REPO` is the clone **on this machine**, not the URL.
`TARGET_REVISION` is the tag you are moving to and `CURRENT_REVISION` is the tag
you are on now. Tags come from the project's releases page, or from
`git ls-remote --tags` against the Tockmox repository. Neither revision is a
value this page can supply, because the right answer changes every release, and
[step 0](#0-write-down-what-you-are-on-now) is what prints the one you are on if
you do not already know it.

**WORKSTATION**

```bash
export KUBE_CONTEXT=YOUR_KUBE_CONTEXT
export SITE_REPO=YOUR_SITE_REPO_PATH
export CURRENT_REVISION=YOUR_CURRENT_REVISION
export TARGET_REVISION=YOUR_TARGET_REVISION
kubectl config view --minify --context="$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
test -f "$SITE_REPO/bootstrap/root.yaml" && echo "SITE_REPO: $SITE_REPO"
echo "moving from $CURRENT_REVISION to $TARGET_REVISION"
```

Every block that reads one of these starts with a guard line, so a block pasted
into a shell that has not run this one stops with a message rather than running
against your home directory, writing a record file named after an empty
revision, or addressing whatever cluster your current context happens to be
(`kubectl --context=` with an empty value falls back to it silently).

**Estimate, not a measurement: 20 to 40 minutes** for a patch release on a
healthy cluster, most of it waiting for layers to reconcile. A major bump takes
as long as its migration notes say.

## Where each command runs

| Marked | Runs on |
|---|---|
| **WORKSTATION ... SITE REPO** | Inside your clone of the site repository, on that same machine. These commands write files you then commit |
| **WORKSTATION** | Your own machine, against the cluster's kubeconfig |

**The marker sits in the prose immediately above each block, in bold, not inside
it.** A `#` line inside a block is the one piece of routing every "copy" control
strips, and on a stock macOS zsh it is not a comment either: `INTERACTIVE_COMMENTS`
is off in an interactive zsh, so a pasted `# SITE REPO` returns
`zsh: command not found: #`.

## Decide which kind of bump this is

It changes how much of this page applies.

| Bump | Example | What this page requires |
|---|---|---|
| **Patch** | `v0.1.0` to `v0.1.1` | Steps 0, 1, 5, 6, 7. Fixes only |
| **Minor** | `v0.1.0` to `v0.2.0` | All of the above plus steps 2 and 3. New capability, values compatible |
| **Major** | `v0.x` to `v1.0` | Every step, and the migration notes in the release section |

**While the major version is zero, that ladder is a statement of intent rather
than a guarantee.** [Semantic Versioning](https://semver.org/) treats major
version zero as explicitly unstable. Which values keys *are* public contract is
declared in [the values contract](../administration/values-contract.md) ... it
says which keys the version number covers, which it does not, what counts as a
breaking change, and what happens when an upstream chart moves something
underneath us. Read it, plus
[configuration § pre-1.0 stability](../administration/configuration.md#pre-10-stability),
before you plan an upgrade path around a values key. Where a tag comes from, and
what it has passed before it exists, is in
[architecture § revision channels](../architecture.md#revision-channels).

## 0. Write down what you are on now

**Required.** This is the rollback target, and the cheapest moment to capture it
is before anything moves.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n argocd get applications -o \
  custom-columns='LAYER:.metadata.name,REVISION:.spec.sources[0].targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

**Success condition:** every layer prints the **same** revision, and every row
reads `Synced` and `Healthy`. Save that output somewhere outside the cluster.

Layers on different revisions before you start is not a reason to stop, but it
means you are resuming a partial upgrade rather than starting a clean one, and
your rollback target is per-layer rather than one value. Anything not `Synced`
and `Healthy` is a reason to stop: fix it first, at
[troubleshooting](../operations/troubleshooting.md).

## 1. Read the release notes

**Required, for every bump including a patch.**

[CHANGELOG.md](../../CHANGELOG.md) puts breaking changes at the top of their
release section with the action required, rather than buried in a list. Read
**every** section between your current revision and the target, not just the
target's: breaking changes are per-release and do not accumulate forward.

**Success condition:** you can name, out loud, every action the notes ask for
between the two revisions, or say that there are none. If you cannot, you have
not finished this step.

**Optional, and it belongs here rather than later:** verify the tag itself
before you point a cluster at it. What you get is the signature and the
checksums on the source ArgoCD is about to render. What you lose by skipping it
is the only chance to check the artifact before it is live, since ArgoCD clones
the tag on its own. The procedure is
[verifying what you downloaded](verify.md).

## 2. Back up what a rollback will not bring back

**Required for a minor or major bump. Optional for a patch**, and cheap enough
that skipping it buys you very little.

Rollback is symmetrical where it can be, not absolutely. Tockmox itself ships
declarative manifests and no migrations of its own, so for most changes you
change the revision back and sync. **Four things break that symmetry**, and they
are why this step exists:

| What | Why a rollback does not undo it | What to do first |
|---|---|---|
| **A deleted PersistentVolumeClaim** | ArgoCD's `prune: true` deletes a PVC the new release stops declaring. Putting the declaration back creates an empty volume | Prove a database backup, and record the PVC list below |
| **A CRD schema change** | Removing a field from a CRD removes the data in it. Restoring the CRD does not restore the data | The release notes name these. Treat one as a major bump regardless of the version number |
| **A namespace rename** | Deleting a namespace deletes everything inside it. Tockmox never does this automatically, for exactly that reason | Nothing automatic. Follow the migration notes by hand |
| **A bundled application that migrates its own database schema** | Tockmox does not run these migrations, the applications do: LiteLLM in its migrations Job (see [below](#the-litellm-migrations-job-gets-a-new-name-on-upgrade-to-080)), and, on the upstream applications' own behaviour, Authentik, Open WebUI and Grafana (when it runs on its Postgres database) when a newer version starts. Pointing the revision back runs the older application against a schema the newer one already changed, and an older version cannot be relied on to read it | Restore the database backup you took before upgrading, then move the revision back. Read the release notes for any bump that moves one of these applications' versions, and do not expect the rollback alone to be enough |

**WORKSTATION** ... record what exists now, so you can diff it afterwards

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
: "${CURRENT_REVISION:?export CURRENT_REVISION first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" get pvc -A -o \
  custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase' \
  | tee ~/"tockmox-pvc-before-$CURRENT_REVISION.txt"
```

**Success condition:** the file exists, is non-empty, and lists a PVC for each
stateful workload you expect. **And** a database backup taken from this cluster
has been restored at least once, per
[backup and restore](../operations/backup-restore.md). A backup nobody has
restored is a claim, not a backup.

## 3. Check your customisations

**Conditional. Run this if** you use Kustomize patches, which is rung 3 of the
[customisation ladder](../administration/customising.md):

**WORKSTATION ... SITE REPO**

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
find "$SITE_REPO" -name 'kustomization.yaml' | head
```

Any output means this step applies. No output means skip it.

A patch whose base moved fails the sync. **That is deliberate**, and it is the
better of the two available failures: a patch that silently stops applying is
discovered at the worst possible moment, by the thing it was patching.

**Success condition:** for each kustomization you found, you have read the
release notes for changes to the files it patches, and either the base is
unchanged or you have updated the patch in the same commit as the revision bump.

## 4. Diff the render before you commit

**Optional.** What you get: you see what the new release changes before the
cluster does. What you lose by skipping it: nothing that steps 6 and 7 will not
catch afterwards, at the cost of catching it afterwards.

This needs a clone of the Tockmox repository at the target revision, which is a
separate checkout from your site repository:

**WORKSTATION** ... from a clone of the Tockmox repo checked out at `$TARGET_REVISION`

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
helm template t charts/tockmox-policy \
  -f "$SITE_REPO/site/values/global.yaml" \
  -f "$SITE_REPO/site/values/policy.yaml" > /tmp/new.yaml

kubectl --context="$KUBE_CONTEXT" get -f /tmp/new.yaml -o yaml > /tmp/current.yaml 2>/dev/null
diff /tmp/current.yaml /tmp/new.yaml
```

**Success condition:** `diff` runs and its output contains no deletion of an
object you rely on. `tockmox-policy` is one layer; repeat for any other layer
whose notes mention a change.

> **Unverified.** The `kubectl get -f` side of that diff reports live objects in
> the same order the template emits them only by coincidence, so the output is
> noisier than a real diff tool would produce. Treat it as a way to spot a
> missing object, not as a change list. Nobody has recorded this comparison
> being run across all nine layers on a real upgrade.

## 5. Move the revision

**Required.** This is the whole upgrade.

**WORKSTATION ... SITE REPO**

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
cd "$SITE_REPO"
grep -rn 'targetRevision' bootstrap/applications/
```

The lines naming `$CURRENT_REVISION` are the ones to change. **Leave the lines
reading `targetRevision: main` alone** ... those are the second source, which is
this repository, and they must keep tracking your default branch.

**WORKSTATION ... SITE REPO**

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
: "${CURRENT_REVISION:?export CURRENT_REVISION first, see Before you begin}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see Before you begin}"
cd "$SITE_REPO"
sed -i.bak "s|targetRevision: $CURRENT_REVISION|targetRevision: $TARGET_REVISION|" \
  bootstrap/applications/*.yaml
rm -f bootstrap/applications/*.bak

git diff --stat
git commit -am "upgrade Tockmox to $TARGET_REVISION"
git push
```

**`sed -i.bak` rather than `sed -i`.** GNU sed and BSD sed disagree about
whether `-i` takes an argument, and the form above is the one that works on both
Linux and macOS.

**Double quotes around the `sed` expression, not single.** The two revisions are
shell variables now, and single quotes would hand `sed` the literal strings
`$CURRENT_REVISION` and `$TARGET_REVISION`, which match nothing and report
nothing.

**Success condition:** the diff touched only `targetRevision` lines, and only
the ones that named the old revision:

**WORKSTATION ... SITE REPO**

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
: "${CURRENT_REVISION:?export CURRENT_REVISION first, see Before you begin}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see Before you begin}"
cd "$SITE_REPO"
git show --stat HEAD
grep -rc "targetRevision: $TARGET_REVISION" bootstrap/applications/ | sort
grep -rn "targetRevision: $CURRENT_REVISION" bootstrap/applications/ \
  || echo "no old revision left: correct"
```

Every enabled layer's file carries the new revision, and the last command prints
the "correct" line rather than a match.

## 6. Confirm every layer landed on the new revision

**Required.** ArgoCD picks the commit up on its next reconciliation. Waiting is
normal; not landing is not.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n argocd get applications -o \
  custom-columns='LAYER:.metadata.name,REVISION:.spec.sources[0].targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

**Success condition:** every row shows `$TARGET_REVISION`, `Synced` and
`Healthy`. Compare it against the output you saved in
[step 0](#0-write-down-what-you-are-on-now); the only column that should have
changed is the revision.

**Two partial results, and they mean different things:**

- **Some layers on the new revision, some on the old, all `Synced`.** Each layer
  polls independently, so for a few minutes this is correct rather than broken.
  If it persists, force the laggards with
  [day-2 § check which revision each layer is running](../operations/day-2.md#check-which-revision-each-layer-is-running).
- **The revision is new and the sync status is not `Synced`.** The release is
  applied to the Application object and not to the cluster. Go to
  [troubleshooting § application stuck OutOfSync](../operations/troubleshooting.md#application-stuck-outofsync).

## 7. Confirm the workloads actually came up

**Required, and it is a different question from step 6.** `Synced` says ArgoCD
applied the manifests. It says nothing about whether the containers started.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
: "${CURRENT_REVISION:?export CURRENT_REVISION first, see Before you begin}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" get pods -A | grep -Ev 'Running|Completed' || echo "all pods settled"
kubectl --context="$KUBE_CONTEXT" get pvc -A -o \
  custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase' \
  > ~/"tockmox-pvc-after-$TARGET_REVISION.txt"
diff ~/"tockmox-pvc-before-$CURRENT_REVISION.txt" \
     ~/"tockmox-pvc-after-$TARGET_REVISION.txt" \
  || echo "PVC set changed: read the diff above against the release notes"
```

**Success condition**, all three:

- No pod outside `Running` or `Completed`, or the first command prints its
  "all pods settled" line.
- The PVC diff is empty, **or** every difference is one the release notes told
  you to expect. A PVC that disappeared and was not in the notes is a prune you
  did not intend, and [step 2](#2-back-up-what-a-rollback-will-not-bring-back)
  is why you can still recover it.
- The consoles you use load and you can log in. There is no substitute for
  opening one. `kubectl` cannot tell you that SSO still works, because the token
  exchange happens between the console and Authentik and not through the API
  server. If a login fails after an upgrade, start at
  [troubleshooting § SSO login dies at the token step](../operations/troubleshooting.md#sso-login-dies-at-the-token-step-with-a-certificate-verify-failure).

**If a StatefulSet pod is stuck on the old revision**, that is a known shape with
a known fix: [when a broken pod blocks its own fix](#when-a-broken-pod-blocks-its-own-fix).

### The LiteLLM migrations Job gets a new name on upgrade to 0.8.0

**Only if you run the model gateway (`apps.litellm`). Nothing to do if your
`tockmox-ai` Application prunes**, which the generated site repo's does.

From 0.8.0 the migrations Job is rendered by `tockmox-ai` itself and named after
its own pod template: `tockmox-ai-litellm-migrations-<10 hex>`. A change to the
template, including a LiteLLM image bump, is a new Job with a new name, so it can
no longer fail with `field is immutable` the way the 0.7.0 upgrade below did, and
a LiteLLM bump's schema migrations run on their own. On this upgrade ArgoCD
creates the new Job, the migration runs (on an unchanged schema it applies
nothing and exits), and the old `tockmox-ai-litellm-migrations` is pruned.

If you sync `tockmox-ai` by hand without prune, the old Job stays, `Completed`
and inert, and the Application shows it as needing a prune. Sync once with
prune, or delete it:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-ai delete job \
  tockmox-ai-litellm-migrations --ignore-not-found
```

**Success condition.** One migrations Job, `Complete`:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-ai get jobs \
  -l app.kubernetes.io/component=migrations
```

The same release runs the gateway and the Job as uid 1000 on a read-only root
filesystem (TM-0596), so the gateway restarts once on this sync. If you mount
[your own gateway hooks](../usage/ai-plane.md#load-your-own-gateway-hooks) and
one of them writes to the container filesystem, it now fails with `Read-only
file system`; write under `/scratch` instead.

### A Job's `ttlSecondsAfterFinished` does not change on an upgrade

**Only if you run the model gateway (`apps.litellm`), and only when upgrading
from 0.6.0-rc2 or earlier.**

`ttlSecondsAfterFinished` is immutable on an existing Job. The chart stopped
setting a TTL on the LiteLLM migrations Job, because a GitOps-managed Job with
ANY finite TTL churns forever: the TTL deletes it, ArgoCD sees an object in
desired state and absent from the cluster, `selfHeal` recreates it, it runs
again. Measured at twelve recreations in 55 minutes.

**The new chart cannot apply that change to a Job that already exists**, so on an
upgrade the fix is correct in the repo and inert on the cluster. Delete the Job
once; ArgoCD recreates it from the new manifest with no TTL.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-ai delete job \
  tockmox-ai-litellm-migrations --ignore-not-found
```

**Success condition.** After ArgoCD's next sync the Job exists again and the
field is gone.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-ai get job \
  tockmox-ai-litellm-migrations \
  -o jsonpath='{.spec.ttlSecondsAfterFinished}{"\n"}'
```

Prints an empty line. If it prints `120` the old Job is still there, or the
repo-server has not re-rendered yet.

**Read this from `events`, not from `get jobs`.** While it is churning the Job
exists for roughly thirty seconds in every three hundred, so a single `get`
lands in the gap nine times out of ten and reports the problem gone.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n tockmox-ai get events \
  --field-selector involvedObject.name=tockmox-ai-litellm-migrations \
  --sort-by=.lastTimestamp | tail -5
```

Repeated `SuccessfulCreate` lines on a ~300-second spacing are the churn. One
`SuccessfulCreate` followed by one `Completed`, and nothing after, is settled.

### The LiteLLM migrations Job must be deleted once on upgrade to 0.7.0

**Only if you run the model gateway (`apps.litellm`), and only when upgrading
from 0.6.2 or earlier.**

Upgrading from 0.6.2 straight to 0.8.0 or later does not need this step: the
0.8.0 Job has a new name, so the old one is pruned rather than patched (see
[the section above](#the-litellm-migrations-job-gets-a-new-name-on-upgrade-to-080)).
That path was not itself measured; the 0.7.2 to 0.8.0 upgrade was.

The 0.7.0 chart adds one optional volume (`tockmox-hooks`, for
[site LiteLLM hooks](../usage/ai-plane.md#load-your-own-gateway-hooks)) to the
migrations Job's pod template, even when you have no hooks. A Job's
`spec.template` is immutable once the Job exists, so ArgoCD reports
`field is immutable` on `tockmox-ai-litellm-migrations`, retries five times and
stops: the layer sits `OutOfSync` with the operation `Failed`. Nothing is lost;
the proxy keeps running. Measured on a lab upgrade from 0.6.2, 2026-09-30.

**The chart cannot do this for you.** The vendored litellm-helm 1.100.1 subchart
puts no parent-settable annotation on the Job's own metadata (its
`migrationJob.annotations` land on the pod template), so `Replace=true` cannot
be attached without forking a template. Its ArgoCD hook switch would make the
Job a PreSync hook, and that deadlocks against the database this same
Application creates (see the comment on `migrationJob` in
`charts/tockmox-ai/values.yaml`). What the repository does instead is refuse to
change the Job's shape silently: `tools/check-upgrade-safety.sh` fails when the
rendered pod template moves, until this step is revisited.

**Do the delete AFTER you push the new revision, not before.** With `selfHeal` on
(the default in the generated site repo), ArgoCD recreates a deleted Job from
the revision it currently has. Deleting before the push gets you the OLD
template back within about a second (measured 2026-09-30: recreated 1 s
later), and the sync that follows the push fails exactly as if you had done
nothing. Once ArgoCD has the new revision, the same recreation uses the NEW
template, so the delete works. The moment to delete is the first failure, and
that is also the cheapest procedure that is correct under `selfHeal`: it needs
no second commit and does not touch the Application's sync policy. (Pausing
`selfHeal` on `tockmox-ai` around the delete also works, but costs two commits
to the site repo and a wait for each.) The Job is idempotent; the new one runs
the migration again and exits.

After you have pushed the new revision (section 5), run the block below: it
waits for `tockmox-ai` to report the immutable-Job error, then deletes the Job.
ArgoCD polls the repository on an interval, so allow up to about five minutes
after the push before the first error appears. Measured on the lab, 2026-09-30:
4 m 53 s from the push to the first operation (an earlier push there was picked
up in about one minute). The block simply waits, so a slow pickup costs you
nothing but time.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
until kubectl --context="$KUBE_CONTEXT" -n argocd get application tockmox-ai \
  -o jsonpath='{.status.operationState.message}' | grep -q 'field is immutable'
do sleep 10; done
kubectl --context="$KUBE_CONTEXT" -n tockmox-ai delete job \
  tockmox-ai-litellm-migrations --ignore-not-found
```

The operation is still retrying at that point, so the next attempt creates the
Job from the new template and the Application goes `Synced` without another
command.

What you will see, as measured on the lab on 2026-09-30: the operation makes
five retries in the first 2 m 38 s, then waits about 2 m 40 s before one more
attempt, so it is still trying for a little over five minutes after the first
error. The wait loop above ends at the first poll that finds
`field is immutable` in the operation message. In the lab the message was still
there after the fifth retry, while the operation waited for its next attempt, so
the loop also ended when it was started late (seen once). In the lab the delete ran
after the fifth retry and the extra attempt, about 2 m 10 s later, created the
Job from the new template and the operation `Succeeded`. **Do not plan on that
extra attempt.** It was seen once, and what the operation does when nothing is
deleted at all (whether it ends `Failed`, and when) was not observed. Delete
promptly.

Timings for the whole layer, from the same run: the layer was `Synced` and
`Healthy` 10 m 46 s after the push, of which 4 m 53 s was ArgoCD noticing the
push and 2 m 9 s was waiting for that last attempt after the delete. The
"under three minutes" measured earlier is the case where the delete lands during
the fast retries. In the lab (2026-09-30) the
Job was recreated 10 seconds after the delete, the operation read `Succeeded`
4 seconds after that, and the whole upgrade of the layer finished under three
minutes after the push.

**If the operation already shows `Failed`** (you were away for more than five
minutes; this `patch operation` fallback is for a `Failed` operation only, not
for one that is still retrying), the delete alone does nothing: ArgoCD does not retry a Failed
operation by itself, and did not in the lab for the 60 seconds we watched.
Start a sync after the delete:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n argocd patch application tockmox-ai \
  --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

(`argocd app sync tockmox-ai` or the UI's Sync button do the same.) In the lab
this recreated the Job within a second and the layer was `Synced` and `Healthy`
in 41 seconds.

**Success condition.** `tockmox-ai` is `Synced` and `Healthy`, its operation
`Succeeded`, and the Job exists and shows `Complete`.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
kubectl --context="$KUBE_CONTEXT" -n argocd get application tockmox-ai \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}'
kubectl --context="$KUBE_CONTEXT" -n tockmox-ai get job \
  tockmox-ai-litellm-migrations \
  -o jsonpath='{.status.succeeded}{"\n"}'
```

Prints `Synced Healthy Succeeded`, then `1`.

### The Loki gateway on an upgrade to 0.7.0

**Only on a single-node cluster, and only if you take a chart older than this
fix.** The Loki chart's gateway Deployment defaulted to a required
`podAntiAffinity` on hostname and a `RollingUpdate` strategy that surges. On
one node the surge pod cannot schedule beside the old one, so the rollout never
finishes. In the same release the gateway Service's port was renamed
(`http-metrics` to `http`), so the old pod stops being an endpoint: the Service
had no endpoints for about 34 minutes in the first lab run, Alloy logged
`no retries left, dropping data`, and `tockmox-observability` went Degraded.

The chart now keeps `RollingUpdate` but sets `maxSurge: 0` and
`maxUnavailable: 1`, so the old pod is removed before the new one is scheduled,
and makes the anti-affinity *preferred* rather than required
(`charts/tockmox-observability/values.yaml`, `loki.gateway`). A single-node
upgrade completes and a multi-node install still spreads replicas. Both changes
are needed: setting `loki.gateway.affinity: null` alone is not enough, because
the old pod still carries the required rule and repels the new one.

**Why not `Recreate`.** The first fix for this used `strategy.type: Recreate`.
Applied over a live 0.6.2 Deployment it is rejected by the API server under
ArgoCD's ServerSideApply (`spec.strategy.rollingUpdate: Forbidden: may not be
specified when strategy type is 'Recreate'`), because the live object still
carries the `rollingUpdate` block it was defaulted with, and the chart cannot
send a `null` to clear it (Helm 3 drops the key before it renders). The
Deployment then never rolled, the renamed Service port had no endpoint, and
the gateway was down for 9 min 25 s until the Deployment was deleted by hand.
Changing only the two numbers of a `RollingUpdate` strategy is an ordinary
field update and applies cleanly. If you run the first fix (`Recreate`) and it
is stuck, delete the gateway Deployment by name once; ArgoCD recreates it.

**What you will see.** Measured on a lab cluster (2026-09-30), from a
Deployment staged in the 0.6.2 shape (25% surge, required anti-affinity,
old port name): no manual action, `tockmox-observability` operation
`Succeeded`, and the gateway Service answered nothing for about 38 seconds
(the old pod's shutdown plus the new pod's start, sampled once a second from a
pod in the namespace). Logs sent in that window are retried by Alloy for a
gap this short (INFERRED, not measured). A multi-node cluster with
`gateway.replicas` above 1 loses one gateway at a time instead of surging.
If you want surging back, set `loki.gateway.deploymentStrategy.rollingUpdate.maxSurge`
and restore the required rule in your own values.

The staged run approximated the 0.6.2 object with a test port name. The 0.7.0
release gate then ran the whole upgrade over a restored 0.6.2 install
(2026-10-01): `tockmox-observability` converged with no retry and no manual
step, and the Loki volume kept its ID. **Not measured:** whether log ingestion
paused while the gateway rolled on that run.

### Do not move an existing namespace into `garage.createCredentialsNamespaces`

**Only if you are tempted to set the key on an install that already runs the
application.** 0.7.0 adds `garage.createCredentialsNamespaces` to the platform
layer: a namespace named there is created by `tockmox-platform` early in the
install, so the object-store credentials can be copied into it before your
application syncs. Its comment in `charts/tockmox-platform/values.yaml` tells
you to delete the Namespace object from your application's own manifests,
because two Applications that both declare one Namespace fight over it.

On a new site that is right. **On an existing install it deletes the
namespace.** The Application that used to declare the Namespace prunes, so when
the Namespace leaves its manifests ArgoCD deletes it, and everything in it goes
with it, volumes included. Measured on a lab cluster (2026-10-01): a restored
0.6.2 install synced a site whose `news` Namespace manifest had been removed for
this key, and about 25 s after the API answered, `site-apps` pruned
Namespace/news and it went `Terminating` with Miniflux and its database inside.

**What to do:** nothing. Leave the key empty, which is its default, and keep the
Namespace in your application's manifests; the namespace already exists, so the
credentials reach it as they did on 0.6.2. The upgrade leg of the 0.7.0 release
gate did exactly that, and the namespace, its pods and their restart counts were
unchanged.

**If you want the platform layer to own a namespace you already run anyway,**
make the application stop pruning it first, in two separate syncs:

1. Add the annotation `argocd.argoproj.io/sync-options: Prune=false` to that
   Namespace in your application's manifests, push, and wait until the
   Application reads `Synced`.
2. Only then remove the Namespace from the manifests and add its name to
   `garage.createCredentialsNamespaces`, in one commit.

**Success condition:** after the second sync,
`kubectl --context="$KUBE_CONTEXT" get namespace <name>` prints `Active` and the
same `AGE` as before. **Not measured:** this two-sync handover itself; the lab
measured the failure and the leave-it-alone path, not the move.

### The docs need one command after an upgrade, and a site sync is a CronJob

**After the `tockmox-platform` Application is `Synced` and `Healthy` at the new
revision, publish the product documentation from a checkout at the new tag.** The
docs are not in a container image (Tockmox publishes none, ADR-0036) and no
Application carries them; `tools/publish-docs.sh` builds them from your checkout
and copies them into the docs bucket through a short-lived pod. Until you run
it, the docs site serves the previous version (or, on a cluster that never had
them, a one-page placeholder). Stale documentation is cosmetic: no data and no
function depends on it.

**WORKSTATION ... TOCKMOX CHECKOUT**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see Before you begin}"
git checkout "$TARGET_REVISION"
./tools/publish-docs.sh --context "$KUBE_CONTEXT" --config tockmox.yaml --wait 600
```

`tockmox.yaml` is the installer config your site was generated from (it names
`tockmox.revision`); without it, pass `--revision "$TARGET_REVISION"`. The script
refuses a checkout that is not that revision. **To see whether the docs are
current**, read the marker the last publish wrote and compare its `ref` with the
revision you run:

```sh
curl -fsS https://docs.int.example.com/.tockmox-docs-version
```

It prints `{"ref":...,"commit":...,"tree_sha256":...}`, and no such object
means the docs were never published (the placeholder is showing). The procedure,
what the script refuses, and the air-gapped variant (`--site DIR`) are in
[Publishing the product documentation](../administration/serving-static-sites.md#publishing-the-product-documentation).

**If you ran a 0.7.0 candidate that served the docs from an image**, nothing of
that remains to clean up except possibly an old Job: no Tockmox image was ever
published, so no cluster pulled one, and the key that named it
(`garage.web.docs.image`, `content.docs`) is gone. A values file that still sets
either is refused by the chart's schema; delete the key. If your install carried
a `tockmox-garage-sync-docs` CronJob or Job from a candidate, delete it by name
(`kubectl -n tockmox-platform delete cronjob tockmox-garage-sync-docs`); the
bucket and its contents stay.

The rest of this section applies to a site of your own with a `content.image`.
Each such site is filled by a CronJob, `tockmox-garage-sync-<name>`
(`garage.web.syncSchedule`, hourly at minute 23 by default). A sync whose image
cannot be pulled ends in `ImagePullBackOff`, which does not fail a Pod, so each
run fails only when its `activeDeadlineSeconds: 900` expires.

**That failure is not a sync failure.** In 0.7.0 candidates before this change
the sync was a PostSync hook Job. A failed hook fails the whole ArgoCD sync
operation, ArgoCD retried it five times with a full re-sync of the platform
Application each time, and the operation stayed `Running` for about 100 minutes
(03:38 to 05:18 UTC in the lab) before it ended `Failed`; no other operation on
`tockmox-platform` could start meanwhile. As a CronJob, the Application is
`Synced` and `Healthy` as soon as the CronJob exists, the operation `Succeeded`
in about a minute in the lab, and a run that cannot pull its image shows up as
a failed Job in `tockmox-platform` and nowhere in ArgoCD.

**Make sure your content image exists BEFORE you list the site.** Check that the
tag resolves first (`docker buildx imagetools inspect <image>:<tag>`). If it
does not, the site stays empty and every scheduled run, and the run started at
install, fails at its 15-minute deadline (lab, 2026-09-30: the Job pod sat in
`Init:ImagePullBackOff`).

Content reaches the bucket at the next scheduled run, not at sync time, with
one exception. The `tockmox-garage-bootstrap` Job also starts one run of each
such site's CronJob when it finishes (`garage.web.syncAtInstall`, on by
default), in a Job named `tockmox-garage-sync-<name>-<chart version>`, once per
chart version; you will see it in `tockmox-platform` after an upgrade if you have
a site with a content image. It is best effort and never fails the bootstrap
Job. To publish one now (shown for a site named `handbook`):

**WORKSTATION**

```sh
kubectl --context YOUR_KUBECONTEXT -n tockmox-platform create job \
  --from=cronjob/tockmox-garage-sync-handbook sync-now
```

**Changing any `garage.web` value restarts `tockmox-garage-0`.** On the lab
(2026-09-30) each change to those keys rolled the single Garage pod, and the
object store answers nothing while it restarts; the restart was not timed, and
which keys cause it was not tested one by one. Make those edits in a quiet moment, and
not in the same commit as a bump you are watching.

## Roll back

**Conditional. Do this if** step 6 or step 7 failed and the release notes do not
explain it.

Rollback is the same procedure with the two revisions swapped:

**WORKSTATION ... SITE REPO**

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
: "${CURRENT_REVISION:?export CURRENT_REVISION first, see Before you begin}"
: "${TARGET_REVISION:?export TARGET_REVISION first, see Before you begin}"
cd "$SITE_REPO"
sed -i.bak "s|targetRevision: $TARGET_REVISION|targetRevision: $CURRENT_REVISION|" \
  bootstrap/applications/*.yaml
rm -f bootstrap/applications/*.bak
git commit -am "roll back Tockmox to $CURRENT_REVISION"
git push
```

Prefer this over `git revert` of the upgrade commit only if other commits have
landed since; if the upgrade is the tip, a revert is equivalent and reads better
in the log.

**Success condition:** run [step 6](#6-confirm-every-layer-landed-on-the-new-revision)
again, reading `$CURRENT_REVISION` where it says `$TARGET_REVISION`. Every
layer back on the old revision, `Synced` and `Healthy`, and the PVC list back to
what [step 2](#2-back-up-what-a-rollback-will-not-bring-back) recorded.

**A rollback does not restore deleted data.** If the upgrade pruned a PVC or
narrowed a CRD, the revision going back does not bring the contents back. The
same holds when a bundled application migrated its database schema. That
is a restore, from [backup and restore](../operations/backup-restore.md), and it
is a separate procedure.

## Upgrade one layer at a time

**Optional, and a migration tactic rather than a resting state.** What you get:
a smaller blast radius per commit during a major bump. What you lose: you are
running a combination nobody tested.

Each layer is an independent Application, so the revisions can differ. The
angle brackets below stand for the two literal tags, written out: this is a file
on disk that ArgoCD reads, not a shell, so it holds no `$TARGET_REVISION`.

```yaml
# bootstrap/applications/tockmox-policy.yaml
    - repoURL: https://github.com/tockmox/tockmox.git
      targetRevision: <TARGET_REVISION>

# bootstrap/applications/tockmox-platform.yaml ... held
    - repoURL: https://github.com/tockmox/tockmox.git
      targetRevision: <CURRENT_REVISION>
```

**Mixing releases is supported and is not tested across arbitrary
combinations.** Sync waves order the first rollout only, so a held layer is not
protected from a moved one; they are simply two Applications with different
sources. Finish the migration rather than settling here.

**Success condition:** [step 6](#6-confirm-every-layer-landed-on-the-new-revision),
accepting a deliberate disagreement in the revision column. Every row must still
read `Synced` and `Healthy`, and you must be able to say which revision each
layer is meant to be on and why.

## When a broken pod blocks its own fix

**Conditional. Run this if** a StatefulSet pod is still on the old revision
after step 6 said the layer is `Synced`:

**WORKSTATION.** The first two lines are yours to fill in, once, and the two
blocks further down read them back.

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
export NAMESPACE=YOUR_NAMESPACE
export STATEFULSET_NAME=YOUR_STATEFULSET_NAME
kubectl --context="$KUBE_CONTEXT" -n "$NAMESPACE" get statefulset "$STATEFULSET_NAME" -o \
  jsonpath='CURRENT={.status.currentRevision} UPDATE={.status.updateRevision}{"\n"}'
```

Two different values, with the pod not being replaced, means this applies.

StatefulSets in this platform (the chat console among them) run with
`podManagementPolicy: OrderedReady`, which will not replace pod-0 during a
rolling update until pod-0 is Ready. If the pod is crash-looping ... the exact
situation an upgrade is meant to fix ... the update that fixes it can never
proceed on its own. **Observed on a live cluster 2026-08-18:** generation and
`updateRevision` advanced, the pod stayed on the old revision with the restart
count climbing.

The resolution is one command and it does not fight GitOps, because the
desired state already IS the new revision; the controller just cannot get
there:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
: "${NAMESPACE:?export NAMESPACE first, see the first block in this section}"
: "${STATEFULSET_NAME:?export STATEFULSET_NAME first, see the first block in this section}"
kubectl --context="$KUBE_CONTEXT" -n "$NAMESPACE" delete pod "$STATEFULSET_NAME-0"
```

**YOU SUPPLY:** the namespace and the StatefulSet name, both from the
`kubectl get statefulset -A` listing. They are exported on the first two lines
of the first block in this section, and every block after it reads them back
behind a guard, so a `delete pod` pasted into a fresh shell stops with a message
rather than resolving to a pod named `-0` in your current namespace.

**Success condition:** the two revisions above converge, and the pod is
`Running` on the new one:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Before you begin}"
: "${NAMESPACE:?export NAMESPACE first, see the first block in this section}"
: "${STATEFULSET_NAME:?export STATEFULSET_NAME first, see the first block in this section}"
kubectl --context="$KUBE_CONTEXT" -n "$NAMESPACE" get statefulset "$STATEFULSET_NAME" -o \
  jsonpath='CURRENT={.status.currentRevision} UPDATE={.status.updateRevision}{"\n"}'
kubectl --context="$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$STATEFULSET_NAME"
```

`CURRENT` equals `UPDATE`, and the pod shows `Running` with a restart count that
has stopped climbing. If the pod recreates and crash-loops again, the upgrade
did not contain the fix you thought it did, and this was never the problem.

## What is not certified here

**No release-to-release upgrade of a Tockmox cluster has been executed against
this page as written.** What is verified is narrower and worth stating exactly:

- **Every release passes a deploy proof on a cluster that has never been touched
  by hand before it gets a tag.** That is a claim about a fresh install of the
  new version, not about the transition from the previous one. The mechanism is
  in [architecture § revision channels](../architecture.md#revision-channels).
- **The StatefulSet block was observed on a live cluster on 2026-08-18**, and
  that date and scope are stated where the claim appears.
- Everything else on this page ... the prune behaviour, the PVC diff, the
  rollback symmetry ... is derived from how the Applications are generated and
  from ArgoCD's documented behaviour. Reading a page cannot establish that it
  works; see the [testing standard](../testing-standard.md).

## Next

Ongoing changes are [day-2 operations](../operations/day-2.md), which uses the
same site repository and the same success conditions.

If the upgrade did not go the way this page describes, that is a documentation
defect worth reporting, and the useful form of the report is the command you ran
and the output you got rather than a summary of it.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "Rebuilding from the off-site copy"
description: "What the built-in forge keeps off the cluster (the off-site copy, the nightly forge dump, the recovery kit), the alerts that watch them, what a rebuild can lose, and the two commands: rebuild a lost cluster, or repair only its forge."
tags: [forge, recovery, rebuild, backup, off-site, recovery-kit]
status: stable
generated:
  by: hand
  at: 2026-11-04
tockmox:
  classification: public
  audience: [operator]
---

# Rebuilding from the off-site copy

**A site on the built-in forge can be rebuilt with one command, from two things
you keep off the cluster: the off-site copy and the recovery kit.** This page says
what each holds, what watches them, what a rebuild can still lose, and how to run
the rebuild and the smaller forge repair. What the forge is:
[the built-in site forge](site-forge.md). Setting the copy up:
[install § publish to the built-in forge](../deployment/install.md#publish-to-the-built-in-forge).

## What is kept off the cluster

| What | When | Where | What it holds |
|---|---|---|---|
| **The off-site copy** | Within about a minute of every merge | The destination you gave `bootstrap-forge`: an S3-compatible bucket (a git bundle, plus a pointer to the latest) or a git remote the forge mirrors `main` to | The site repository's full history on `main` |
| **The forge dump** | Every night at 21:15, the cluster's time zone, and once at install | The same destination | Every pull request, review, review comment and issue comment, as the forge returned them, and the repository's own record |
| **The recovery kit** | Written by `bootstrap-forge`, and again by every rebuild and repair | Wherever you put it: **not** the cluster, and not the off-site destination | The forge's own secrets (its `app.ini`, which a restore needs), the forge administrator's credential, and your sealing-key backup, in one encrypted file |

**Keep the kit apart from the copy.** One leaked bucket credential should not hand
over both the history and the keys that open it. The kit is encrypted to the age
key or passphrase you chose, and cannot hold what opens it.

**A bucket with versioning or object lock keeps every earlier copy**, so a
rewritten history is visible and recoverable. On a git remote, protect `main` from
force pushes: the forge's mirror then fails to rewrite it, and the lag alert
below fires.

**What the dump does not hold:** the forge's branch rule, its teams and its
sign-in. Reading them needs the forge's administrator, which the nightly job does
not hold, and it does not need them: the rebuild and the repair create all three
again from the installer's options. **So the installer owns those settings.**
Change them by re-running it with new options, never in the forge's own pages,
where a rebuild or a repair would put them back.

## What watches them

| Alert | Fires when |
|---|---|
| `TockmoxSiteRepositoryCopyBehind` | The off-site copy's latest commit has differed from the forge's for more than 15 minutes |
| `TockmoxSiteRepositoryNoOffsiteCopy` | The site has no off-site copy at all. It persists, and you can snooze or dismiss it like any other alert |
| `TockmoxSiteRebuildDrillOverdue` | The last [rebuild drill](#rehearse-the-rebuild-the-drill) failed, or passed more than 92 days ago, or the site is older than 92 days and has never had one. The daily `tockmox-forge-drill-check` job reads the drill's record from the destination; its log says which |

Both go wherever the site's other alerts go. A failed copy or dump job also leaves
a failed Job, which the platform's failed-Job alert reports.

## What a rebuild can lose

**A rebuild can lose the commits made since the last off-site copy (up to the 15
minutes the copy may fall behind before its alert fires), any change made by hand
to the forge's own settings, and the review history written since the last forge
dump (up to a day of it).** The review history in the dump comes back in a
different shape: each pull request returns as one closed issue labelled
`restored-from-dump`, holding its description, its reviews and its comments in
order, with who wrote each and when. They are a record to read, not pull requests
to reopen, and a rerun skips an issue already there. The dump itself stays
readable in the destination, as the JSON the forge returned. Running workloads and
their data volumes are the business of
[backup and restore](../operations/backup-restore.md), as before.

## Set these once

**YOU SUPPLY:** where the off-site copy is, as you gave it to `bootstrap-forge`,
and what opens the recovery kit. They are exported once here, so every block
below is pasteable as printed.

**WORKSTATION**

```bash
export TOCKMOX=YOUR_TOCKMOX_CLONE_PATH
export S3_ENDPOINT=YOUR_S3_ENDPOINT
export S3_BUCKET=YOUR_BUCKET
export S3_CREDENTIALS="$HOME/tockmox-backup/offsite-credentials"
export KIT="$HOME/tockmox-backup/tockmox-recovery-kit.tar.age"
export AGE_IDENTITY=YOUR_AGE_IDENTITY_FILE
export AGE_PUBLIC_KEY=YOUR_AGE_PUBLIC_KEY
ls "$TOCKMOX/install/tockmox-install.sh" "$KIT" "$S3_CREDENTIALS" "$AGE_IDENTITY"
```

**Success condition:** `ls` lists all four files. `S3_CREDENTIALS` holds two
lines, the access key id and then the secret key. **On a git-remote copy**, in
every block below replace the three `--offsite-s3-*` flags with
`--offsite-git URL --offsite-git-credentials FILE`, plus `--offsite-git-ca FILE`
if the remote's certificate is from your own CA. **For a passphrase kit**,
replace `--age-identity "$AGE_IDENTITY"` with `--passphrase-file FILE`.

## Check the copy and the kit, without a cluster

**Do this now and then, and before you need it.** `--dry-run` fetches the copy and
checks it (its SHA-256, `git bundle verify`, the commit the pointer names, that the
tree is a built-in-forge site), opens the kit and checks it, names the copy's age,
and touches no cluster.

**WORKSTATION**

```bash
: "${TOCKMOX:?export TOCKMOX first, see Set these once}"
: "${S3_ENDPOINT:?export S3_ENDPOINT first, see Set these once}"
: "${KIT:?export KIT first, see Set these once}"
"$TOCKMOX/install/tockmox-install.sh" --restore-from offsite \
  --offsite-s3-endpoint "$S3_ENDPOINT" --offsite-s3-bucket "$S3_BUCKET" \
  --offsite-s3-credentials "$S3_CREDENTIALS" \
  --kit "$KIT" --age-identity "$AGE_IDENTITY" \
  --kit-out "$HOME/tockmox-backup/tockmox-recovery-kit-new.tar.age" \
  --site-out ./tockmox-site-restored \
  --dry-run
```

**Success condition:** it reports the copy's `main` (commit, subject, age and
commit count) and `kit opened`, and changes nothing. A copy older than
`--max-age-hours` (default 24) is called out by its age. **Every refusal comes
here, before any cluster is touched:** a wrong passphrase, a corrupt or tampered
bundle, a checksum that does not match, or a site generated for another forge.

## Rebuild a lost cluster

**When:** the cluster is gone, and you have a new one with ArgoCD installed and
nothing else (prepare it as in [prepare a fresh cluster](../deployment/fresh-install.md),
up to and including ArgoCD).

The same command as the check above, with `--context` and without `--dry-run`. It
opens the kit, restores your sealing key **before** the sealed-secrets controller
starts (so every sealed file in the copy still opens), installs the forge and seeds
it from the copy, creates the branch rule, teams and sign-in again, restores the
review history from the latest forge dump, and applies the root Application. Every Application already names the forge's in-cluster address,
which is the same on every cluster, so no URL is rewritten.

**WORKSTATION**

```bash
: "${TOCKMOX:?export TOCKMOX first, see Set these once}"
: "${S3_ENDPOINT:?export S3_ENDPOINT first, see Set these once}"
: "${KIT:?export KIT first, see Set these once}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first: the NEW cluster's context}"
"$TOCKMOX/install/tockmox-install.sh" --restore-from offsite \
  --offsite-s3-endpoint "$S3_ENDPOINT" --offsite-s3-bucket "$S3_BUCKET" \
  --offsite-s3-credentials "$S3_CREDENTIALS" \
  --kit "$KIT" --age-identity "$AGE_IDENTITY" \
  --kit-out "$HOME/tockmox-backup/tockmox-recovery-kit-new.tar.age" \
  --site-out ./tockmox-site-restored \
  --context "$KUBE_CONTEXT"
```

**Success condition:** it ends with `rebuilt from the copy at <commit> (<age>)`,
and ArgoCD syncs the layers from the new forge
([install § watch the waves](../deployment/install.md#3c-watch-the-waves)).
**It writes a new recovery kit** (`--kit-out`): the new forge has new secrets, so
the old kit no longer opens it. Keep the new one as you kept the old, and set the
off-site copy up for the new forge, which the rebuild does with the same flags.
Once `tockmox-identity` is `Healthy`, connect the forge's sign-in as on a fresh
install ([install § connect the built-in forge's sign-in](../deployment/install.md#connect-the-built-in-forges-sign-in)).

**A copy carried in on media** (a disconnected site, or a bucket you cannot reach):
`--restore-from file:PATH` in place of `offsite` and the destination flags. The
file is checked against `PATH.sha256` beside it, or the `--sha256 HEX` you give,
and refused if it does not match. Bring the forge dump on the same media and name
it with `--dump FILE`; it is checked the same way, against `FILE.sha256` or
`--dump-sha256 HEX`.

**The forge dump is checked before anything touches the cluster**, beside the copy:
its checksum, its own counts, and that it is the dump of this site's repository.
A dump that fails a check stops the rebuild with nothing installed. With no dump
at the destination, the rebuild warns and goes on without the review history.
`--no-review-history` skips the dump on purpose. The repair below restores the
review history the same way.

## Repair only the forge

**When:** the cluster runs and the forge does not, because its volume or the node
it sat on was lost. ArgoCD shows `ComparisonError` on every layer, and your apps
keep running.

`repair-forge` reinstalls **only** the forge, seeds it from the copy and gives
ArgoCD its read credential again. Nothing else is touched, and ArgoCD reads the
same commit it read before. It needs no kit to open, because the cluster still
holds your sealing key; it writes a new kit, so give it your current sealing-key
backup to fold in.

**WORKSTATION**

```bash
: "${TOCKMOX:?export TOCKMOX first, see Set these once}"
: "${S3_ENDPOINT:?export S3_ENDPOINT first, see Set these once}"
: "${AGE_PUBLIC_KEY:?export AGE_PUBLIC_KEY first, see Set these once}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
"$TOCKMOX/install/tockmox-install.sh" repair-forge \
  --offsite-s3-endpoint "$S3_ENDPOINT" --offsite-s3-bucket "$S3_BUCKET" \
  --offsite-s3-credentials "$S3_CREDENTIALS" \
  --kit-out "$HOME/tockmox-backup/tockmox-recovery-kit-new.tar.age" --age-recipient "$AGE_PUBLIC_KEY" \
  --sealing-key-backup "$HOME/tockmox-backup/sealed-secrets-key.enc" \
  --context "$KUBE_CONTEXT"
```

**Success condition:** it ends with `the forge was repaired from the copy at
<commit> (<age>)`, after checking that every Application reads the same revision
and health against the new forge as before. **It refuses a forge that answers and
already holds the copy's commit** (there is nothing to repair; `--force` overrides
that), and it refuses when the forge is down but its volume is intact, which is a
restart, not a repair.

## Rehearse the rebuild: the drill

**Once a quarter, on a throwaway cluster.** The drill is the rebuild above, run for
real from the latest off-site copy and your real recovery kit, onto a cluster you
then throw away. Before the rebuild it proves the three refusals on the same copy
and kit, each as a dry run that touches no cluster: a stale copy is named as
stale, a corrupt bundle is refused, a wrong passphrase stops before anything is
installed. It then rebuilds, waits for every Application to be `Synced` and
`Healthy`, and writes its result next to the copy (`drill/latest` in the bucket,
or the `forge-drill` branch on a git remote). The site's daily
`tockmox-forge-drill-check` job reads that record, and
`TockmoxSiteRebuildDrillOverdue` fires when the drill failed or is due.

**The throwaway forge only reads the destination.** The drill rebuilds with
`--no-offsite-setup`, so the second forge never writes to the site's copy.
Delete the throwaway cluster when the drill ends.

**WORKSTATION**

```bash
: "${TOCKMOX:?export TOCKMOX first, see Set these once}"
: "${S3_ENDPOINT:?export S3_ENDPOINT first, see Set these once}"
: "${KIT:?export KIT first, see Set these once}"
: "${DRILL_CONTEXT:?export DRILL_CONTEXT first: a THROWAWAY cluster with Argo CD and nothing else}"
"$TOCKMOX/install/tockmox-install.sh" rebuild-drill --restore-from offsite \
  --offsite-s3-endpoint "$S3_ENDPOINT" --offsite-s3-bucket "$S3_BUCKET" \
  --offsite-s3-credentials "$S3_CREDENTIALS" \
  --kit "$KIT" --age-identity "$AGE_IDENTITY" \
  --kit-out "$(mktemp -d)/drill-kit.tar.age" \
  --site-out "$(mktemp -d)/tockmox-site-drill" \
  --context "$DRILL_CONTEXT"
```

**Success condition:** it ends with `rebuild drill PASSED in <seconds> s from
<commit>; refusals proven: stale,corrupt,passphrase` and `record written to ...
and read back`. A drill that fails writes its record too, with the reason, so the
alert fires a day later instead of nobody knowing. The kit this run writes belongs
to the throwaway forge; it is not your site's kit, so it goes to a temporary
directory. `--drill-wait-minutes N` (default 45) is how long it waits for the
Applications.

## What is not certified here

- The rebuild has been proven on lab clusters with virtual clusters standing in
  for a lost one: a destroyed cluster came back `Synced` and `Healthy` at the
  copy's commit with every sealed file opening to its original value. It has not
  yet been run as a physical rebuild.
- The wrong-passphrase refusal was proven on the lab. The corrupt-bundle,
  tampered-file and stale-copy refusals are proven by the installer's tests, with
  real bundles and kits, not yet on the lab.
- The rebuild drill's refusals and its record are proven by the installer's tests
  with real bundles and kits; its rebuild and its wait for the Applications have
  not yet been run on the lab. Scheduling it is yours: the drill-check job and its
  alert only say when one is due. The disconnected variant, a copy carried in on
  media with the uplink cut, is not part of the drill yet.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

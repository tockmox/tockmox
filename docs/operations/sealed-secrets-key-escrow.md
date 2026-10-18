---
okf_version: "0.2"
type: HowTo
title: "Escrow the sealed-secrets key"
description: "Export the sealed-secrets controller's private key encrypted, keep it off the cluster, keep it current across key renewals, restore it to a rebuilt cluster with bootstrap-secrets, and drill the restore."
tags: [secrets, sealed-secrets, escrow, backup, restore, age, disaster-recovery]
status: stable
generated:
  by: hand
  at: 2026-09-29
tockmox:
  classification: public
  audience: [operator]
---

# Escrow the sealed-secrets key

**The controller's private key is the one thing in a Tockmox deployment that a
rebuild cannot regenerate.** Your site repository holds every SealedSecret, and
every one of them is encrypted to that key. Lose the key and the files in git
are noise: nothing reads them, and no amount of care with the repository fixes
it. This page is how to keep a copy that survives losing the cluster, keep that
copy current, and prove it opens.

It is the procedure behind
[secrets § back up the controller key](../administration/secrets.md#back-up-the-controller-key-now),
which says why. It uses `install/tockmox-install.sh bootstrap-secrets` for the
export and the restore, so the flags below are that subcommand's, read from
`install/bootstrap-secrets.sh`. The subcommand is introduced in
[installation § the bootstrap route](../deployment/install.md#the-bootstrap-route-bootstrap-secrets).

**Nothing on this page has been run against a cluster.** The one thing that was
executed is the `age` round trip in step 1, on a laptop, with a dummy file. Read
[what is not certified here](#what-is-not-certified-here) before you rely on the
restore.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| A running cluster with the sealed-secrets controller, and `kubectl` pointed at it | Step 2 reads the key out of it | `kubectl -n kube-system get deploy` lists `sealed-secrets-controller` (the bootstrap route) or `sealed-secrets` (the manual route) |
| Your generated **site repository** and a checkout of the Tockmox source | The subcommand seals into the site repository and refuses to run without one | The check under the exports below prints `site and installer found` |
| `age` on the workstation (`age` and `age-keygen`) | The preferred encryption. `--passphrase-file` with `openssl` is the alternative and is covered where it differs | `command -v age age-keygen` prints two paths |
| `kubeseal` and `kubectl` | The subcommand needs them | `command -v kubeseal kubectl` prints two paths |
| Two places to keep things, off this cluster and apart from each other | The encrypted export and the identity that opens it must not live together | You can name both places before you start step 1 |

**Where each command runs:** every block below is **WORKSTATION**, the machine
you administer the cluster from. Nothing here runs on a node.

**YOU SUPPLY:** three paths and a context. Export them once. The directory for
the export has to be outside your site repository, and the subcommand refuses
one inside it.

**WORKSTATION**

```bash
export SITE_REPO=YOUR_SITE_REPO_PATH
export TOCKMOX=YOUR_TOCKMOX_CHECKOUT_PATH
export KUBE_CONTEXT=YOUR_KUBE_CONTEXT
export ESCROW_DIR=YOUR_ESCROW_DIRECTORY
test -d "$SITE_REPO/secrets" && test -x "$TOCKMOX/install/tockmox-install.sh" && echo "site and installer found"
```

## 1. Make the escrow key, once ... Required

The export is encrypted to an `age` public key. The matching **identity** (the
private half) is what opens the export later, so it is the real secret of this
whole arrangement, and the export is only as safe as the identity is.

Make the pair on a machine you trust, and treat the identity file as the thing
you are escrowing:

**WORKSTATION**

```bash
: "${ESCROW_DIR:?export ESCROW_DIR first}"
umask 077
age-keygen -o "$ESCROW_DIR/escrow-identity.txt"
```

`age-keygen` prints `Public key: age1...` on the terminal and writes the
identity to the file. The public key is the value you give `--age-recipient`
from now on, and it is safe to write down anywhere.

**WORKSTATION**

```bash
export AGE_PUBLIC_KEY=YOUR_AGE_PUBLIC_KEY
```

**Success condition:**

**WORKSTATION**

```bash
: "${ESCROW_DIR:?export ESCROW_DIR first}"
: "${AGE_PUBLIC_KEY:?export AGE_PUBLIC_KEY first}"
stat -c %a "$ESCROW_DIR/escrow-identity.txt" 2>/dev/null || stat -f %Lp "$ESCROW_DIR/escrow-identity.txt"
printf 'roundtrip\n' | age -r "$AGE_PUBLIC_KEY" | age -d -i "$ESCROW_DIR/escrow-identity.txt"
```

The first line prints `600` and the second prints `roundtrip`. If the second
prints an error, the public key you exported is not the one this identity file
holds, and nothing you encrypt to it will open.

**Do not put the identity anywhere that needs the cluster to reach it.** A copy
held only in a password manager you sign in to through the cluster's own single
sign-on is a copy that disappears in the same outage. It is the mistake this
arrangement is easiest to make and least able to survive.

**A team.** `--age-recipient` takes one public key. If several people should be
able to open the export, either make the recipient a key whose identity your
escrow process holds, or re-encrypt the finished export to more recipients
afterwards with `age -d -i IDENTITY FILE | age -r KEY1 -r KEY2 > NEWFILE`. The
second route puts the plaintext key on a pipe rather than a file, and needs the
identity present. The installer does neither for you.

## 2. Export the key ... Required

The subcommand writes the export for you: a short YAML document per key Secret
(name, label, `tls.crt`, `tls.key`, no `uid` or `resourceVersion`), preceded by
a marker line `# tockmox-sealed-secrets-key-backup v1`, all encrypted before it
touches a file. It never writes the key in the clear, refuses to write inside
your site repository, and warns if the destination is in a git working tree
(the file is encrypted, but do not commit it).

For a **new** cluster the export happens as part of the install, with
`--mode new` and the same two flags, and there is nothing further to do now.
For a cluster that **already has a controller**, which is every cluster you are
reading this page about after day one, use `--mode reuse`. It adopts the running
controller (it prints which one it found and makes you type `NAMESPACE/NAME` to
confirm), installs nothing, and never generates a second key.

Two behaviours to know before you run it:

- `--backup-out` **is never overwritten.** If the file exists the run keeps it,
  says so, and exports nothing. That protects your only good copy, and it means
  every export needs a new path. The command below puts the date in the name.
- `--mode reuse` also runs `tools/mint-secrets.sh` afterwards, which mints
  **only what is missing** and leaves every existing sealed file byte-identical.
  On a complete site that is nothing. If the summary lists something under
  `NOT MINTED`, that is a credential your site lacks, unrelated to the export.
- Every mode that is not a `--dry-run`, `--mode reuse` included, also writes the
  controller's **public** certificate to
  `secrets/sealed-secrets-cert.pem` in your site, if that file is not already
  there (on a lab re-run it was the only new file). It is a certificate, not a
  key, and is safe to commit; `tools/mint-secrets.sh` uses it to seal. Commit it
  with the rest of `secrets/`. ArgoCD ignores it: on the 0.7.1-rc2 gate the
  file sat in `secrets/` and `site-secrets` synced Healthy beside it.

**WORKSTATION** ... first as a dry run, which shows the plan and changes
nothing:

```bash
: "${SITE_REPO:?export SITE_REPO first}"
: "${TOCKMOX:?export TOCKMOX first}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${ESCROW_DIR:?export ESCROW_DIR first}"
: "${AGE_PUBLIC_KEY:?export AGE_PUBLIC_KEY first}"
"$TOCKMOX/install/tockmox-install.sh" bootstrap-secrets --mode reuse \
  --site "$SITE_REPO" --context "$KUBE_CONTEXT" \
  --backup-out "$ESCROW_DIR/sealed-secrets-key-$(date -u +%Y-%m-%d).age" \
  --age-recipient "$AGE_PUBLIC_KEY" \
  --dry-run
```

Then run it for real by removing `--dry-run`. It asks you to type the context
name, the API server address it printed, and the controller to adopt. For an
unattended run, `--no-prompt` with `--yes-context`, `--yes-server` and
`--yes-adopt NAMESPACE/NAME` each has to equal what the script shows; a value
that does not match is a refusal, not a blanket yes.

**A passphrase instead of age.** Replace `--age-recipient` with
`--passphrase-file FILE` (the first line of FILE is the passphrase), or omit
both at a terminal and `openssl` asks. This is AES-256 with PBKDF2 at 600000
iterations. It works, and it is symmetric: whoever can open it can also write
one, and the passphrase is now what you escrow. Age is preferred because the
public half is safe to leave anywhere.

**Success condition:** the run ends with `encrypted key backup written:` and a
path, and its summary line `key backup` names that path with `age` and a key
count. Then do step 3, because the script cannot check the one thing that
matters when the encryption is age.

## 3. Prove the export opens ... Required

With `--age-recipient` the script prints `NOT VERIFIED: age cannot open its own
output without your identity`. That is accurate: only you hold the identity, so
only you can close the loop, and you do it now, not in an emergency. (With
`--passphrase-file` the script decrypts its own output and reports `backup
decrypts and holds N key(s) of N`, so this step is already done.)

**WORKSTATION**

```bash
: "${ESCROW_DIR:?export ESCROW_DIR first}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
export ESCROW_FILE=YOUR_EXPORT_FILE_PATH
age -d -i "$ESCROW_DIR/escrow-identity.txt" "$ESCROW_FILE" | head -1
age -d -i "$ESCROW_DIR/escrow-identity.txt" "$ESCROW_FILE" | grep -c 'tls.key'
kubectl --context "$KUBE_CONTEXT" -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l
```

**Success condition:** the first line is exactly
`# tockmox-sealed-secrets-key-backup v1`, and the last two numbers are equal.
The first is the number of keys in the export, the second the number in the
cluster. If the controller is not in `kube-system`, use the namespace the
installer reported. A lower count in the export means the export is stale (see
[step 5](#5-keep-it-current-and-know-what-the-controller-does-with-several-keys--required)).

If the first line is missing, `--mode recover` will refuse the file. A backup
made by hand with `kubectl get -o yaml` is not this format.

## 4. Store it off the cluster ... Required

[The secrets page](../administration/secrets.md#back-up-the-controller-key-now)
gives three properties worth engineering rather than hoping for: at least one
copy off the network entirely, re-export after key renewal, and prove it once.
This page adds the rules that only matter once there are two artifacts:

- **The export and the identity are held apart.** Someone holding both holds
  every secret in the deployment. Someone holding one holds noise. Do not put
  them in the same folder, the same password manager entry or the same person's
  laptop for convenience.
- **The identity gets more copies than the export.** The export is replaceable
  after each renewal; the identity is not, and it is small. Two places that fail
  independently is the minimum.
- **Not in your site repository, and not anywhere the cluster is the only path
  to.** The subcommand enforces the first. The second is yours.
- **The k3s etcd snapshot is a second copy of this key, whether you meant it to
  be or not.** The controller keeps its key as ordinary Kubernetes Secrets, and
  a snapshot includes them. With k3s secrets encryption on
  ([fresh cluster](../deployment/fresh-install.md)) they are encrypted inside
  the snapshot; without it, an off-cluster snapshot carries the key in the
  clear. Protect the snapshot destination as you protect the escrow, or do not
  count the snapshot as a separate protection. The
  [whole-cluster story](backup-restore.md#7-the-whole-cluster-story-in-one-place)
  puts the snapshot in its own plane.

## 5. Keep it current, and know what the controller does with several keys ... Required

**What the controller does.** Per the upstream project's documentation (read on
2026-09-29, see [what is not certified here](#what-is-not-certified-here)): it
creates a new sealing key by default every 30 days, appends it to the set it
holds, seals new secrets to the newest one, and can unseal with any key still
labelled `sealedsecrets.bitnami.com/sealed-secrets-key: active`. It never
deletes an old key on its own. `kubeseal --fetch-cert` (and therefore
`mint-secrets.sh`) always fetches the newest certificate. The interval is the
controller's `--key-renew-period`; the installer sets nothing, so the default
applies.

**What that does to your escrow.** An export taken in January opens everything
sealed to a January key and **nothing sealed after the next renewal**. The
cluster and the escrow drift apart on a schedule, silently. Two rules follow:

- **Re-export after every renewal**, into a new file (step 2 makes the date part
  of the name). The old exports stay valid for what they cover, so keep the last
  two or three rather than replacing them.
- **The moment to check is before you commit newly sealed files**, because those
  are the ones an old export cannot open.

Find the renewal dates, and compare with the date of your newest export:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
```

**Success condition:** your newest export is dated after the newest `CREATED`
value in that list. If it is not, run step 2 again.

**Tockmox ships no alert for a stale escrow.** Nothing watches this, and the
cluster cannot know what is in a file on your desk. The honest substitute is a
calendar entry at the renewal interval, or a scheduled task of your own that
runs the comparison above and the count in step 3. A check that exists only as
your intention to remember is the shape this project keeps warning about.

**Renewal is not rotation.** A new sealing key does not make old committed files
safe: anyone who had the old private key can still open them. If you believe a
key or an escrow file was exposed, the order is: renew early (upstream: pass
`--key-cutoff-time` to the controller), then rotate the underlying secret
values, re-seal, and commit
([secrets § rotation](../administration/secrets.md#rotation)). Treat an
identity that leaked together with an export as an exposure of every secret in
the deployment.

**Retiring an old key** is not needed for anything on this page. If you ever
want to, upstream's `kubeseal --re-encrypt` moves a SealedSecret onto the newest
key first, and relabelling a key to anything but `active` needs a controller
restart to take effect. Do neither in a hurry.

## 6. Restore onto a rebuilt cluster ... Conditional

**Conditional: the cluster is gone and you are rebuilding it.** Test it: no
sealed-secrets controller answers and no sealing key Secret exists.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get deploy -A -l app.kubernetes.io/name=sealed-secrets
kubectl --context "$KUBE_CONTEXT" get secret -A -l sealedsecrets.bitnami.com/sealed-secrets-key
```

Both should report `No resources found`. Anything else changes the answer; read
the refusals below.

Rebuild the cluster and get ArgoCD onto it as your install does
([install](../deployment/install.md)). Then, before you apply
`bootstrap/root.yaml` (so the `site-secrets` Application has a key to work
with), restore. `--mode recover` puts the key into the cluster **before the
controller starts**, then installs the controller, so the files already in your
site repository keep opening.

**YOU SUPPLY:** the export file and the identity that opens it.

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first}"
: "${TOCKMOX:?export TOCKMOX first}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${ESCROW_DIR:?export ESCROW_DIR first}"
: "${ESCROW_FILE:?export ESCROW_FILE first, the export to restore}"
"$TOCKMOX/install/tockmox-install.sh" bootstrap-secrets --mode recover \
  --site "$SITE_REPO" --context "$KUBE_CONTEXT" \
  --key-backup "$ESCROW_FILE" \
  --age-identity "$ESCROW_DIR/escrow-identity.txt" \
  --dry-run
```

Remove `--dry-run` to run it. For an export made with a passphrase, give
`--passphrase-file FILE` in place of `--age-identity`.

What it refuses, and why each is a refusal and not a guess:

- **A controller is already running.** `recover` cannot restore into a running
  controller, which would need a restart and a decision about which key is
  active. If that controller is the right one, use `--mode reuse`. If it is not,
  remove it yourself and run again.
- **No controller, but sealing key Secrets already exist.** Something ran here
  and left keys. Delete them yourself if they are stale; the script will not
  choose.
- **A file that does not decrypt to a Tockmox export.** A wrong identity, a
  wrong passphrase, or a file this script did not write. Nothing was installed.
- **A site that renames the namespaces credentials live in.** A SealedSecret is
  bound to its namespace, so the script refuses rather than seal to the wrong
  place.

**Success condition.** The run ends with `sealing key restored into` and the
controller's namespace, then `controller installed`. Then confirm the controller
holds every key you exported, and that the files in git open:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l
kubectl --context "$KUBE_CONTEXT" get sealedsecret -A
kubectl --context "$KUBE_CONTEXT" -n kube-system logs deploy/sealed-secrets-controller | grep -i -E 'error|unseal' | tail
```

The first number equals the key count in the export (step 3). After ArgoCD syncs
`site-secrets`, every SealedSecret has a matching Secret in its namespace. The
third command prints nothing you did not expect: an unseal error naming a
SealedSecret means the key that sealed it is not in the export, which is step
5's failure showing up late. On a good restore the controller logs `SealedSecret
unsealed successfully` once per file (read on the 0.7.1-rc2 gate); the wording of
a failure has not been read off a live controller.

**If a controller is already running and you cannot remove it.** Upstream's own
restore is to put the key Secrets back and restart the controller. That is a
manual path this page has not exercised: decrypt the export to a file, remove
the marker line, `kubectl apply` it, restart the controller pod, and delete the
decrypted file. The plaintext key sits on your disk for that time, which is
exactly what the subcommand avoids, so use `recover` when you can.

**If the cluster is gone and so is the controller, but you need one secret
now.** With the key exported and decrypted to a file, upstream's `kubeseal
--recovery-unseal --recovery-private-key FILE` opens a SealedSecret with no
cluster at all. Same plaintext-on-disk cost, same caveat: not exercised here.

## 7. Drill the restore ... Required, and on a schedule

A key backup that has never decrypted anything is a hope with a filename. The
drill restores it into a scratch cluster and makes one real SealedSecret from
your site repository open. Do it once after you first export, then on a
schedule. **Quarterly** is this page's suggestion, chosen because it is often
enough to catch a lost identity and rare enough to be done; it is not a measured
figure.

You need a **scratch cluster** you can throw away (kind, k3d, or a disposable
k3s VM) and its context. **Never use the production context here.** The
subcommand makes you type the context name and the API server address before it
writes anything, and you should read both.

**YOU SUPPLY:** the scratch context, and the export and identity from step 3.

**WORKSTATION**

```bash
export SCRATCH_CONTEXT=YOUR_SCRATCH_CONTEXT
test "$SCRATCH_CONTEXT" != "$KUBE_CONTEXT" && echo "scratch differs from production"
```

The line must print `scratch differs from production`. If it prints nothing,
stop.

**a. Restore into the scratch cluster, against a copy of the site repository**
(the subcommand writes into the site directory, and a drill should not touch the
real one):

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first}"
: "${TOCKMOX:?export TOCKMOX first}"
: "${SCRATCH_CONTEXT:?export SCRATCH_CONTEXT first}"
: "${ESCROW_DIR:?export ESCROW_DIR first}"
: "${ESCROW_FILE:?export ESCROW_FILE first}"
export DRILL_SITE="$(mktemp -d)/site"
cp -R "$SITE_REPO" "$DRILL_SITE"
"$TOCKMOX/install/tockmox-install.sh" bootstrap-secrets --mode recover \
  --site "$DRILL_SITE" --context "$SCRATCH_CONTEXT" \
  --key-backup "$ESCROW_FILE" \
  --age-identity "$ESCROW_DIR/escrow-identity.txt"
```

**b. Apply one real SealedSecret from your repository to the scratch cluster.**
Pick a file, create its namespace, apply it, and wait for the Secret:

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first}"
: "${SCRATCH_CONTEXT:?export SCRATCH_CONTEXT first}"
export SEALED_FILE="$(ls "$SITE_REPO"/secrets/*.sealed.yaml | head -1)"
export SEALED_NS="$(awk '/^  namespace:/{print $2; exit}' "$SEALED_FILE")"
kubectl --context "$SCRATCH_CONTEXT" create namespace "$SEALED_NS"
export SEALED_NAME="$(kubectl --context "$SCRATCH_CONTEXT" apply -f "$SEALED_FILE" -o jsonpath='{.metadata.name}')"
for i in $(seq 1 30); do
  kubectl --context "$SCRATCH_CONTEXT" -n "$SEALED_NS" get secret "$SEALED_NAME" -o name 2>/dev/null && break
  sleep 2
done
```

**c. Compare, without printing the secret.** The same Secret in production and
in the scratch cluster should hold identical data; a hash of each shows that
without either value appearing on your screen:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${SCRATCH_CONTEXT:?export SCRATCH_CONTEXT first}"
: "${SEALED_NS:?run step b first}"
: "${SEALED_NAME:?run step b first}"
kubectl --context "$KUBE_CONTEXT" -n "$SEALED_NS" get secret "$SEALED_NAME" -o jsonpath='{.data}' | sha256sum
kubectl --context "$SCRATCH_CONTEXT" -n "$SEALED_NS" get secret "$SEALED_NAME" -o jsonpath='{.data}' | sha256sum
```

**Success condition:** the two hashes are identical. A Secret that never
appeared in step b, or two different hashes, means the drill failed and so would
a real restore. Find out why now: the usual cause is an export older than the
key that sealed that file (step 5).

**d. Make it able to fail.** A comparison that has never shown a difference
proves little. On a second scratch cluster, or the same one after deleting the
controller and its key Secrets, install a controller with a **fresh** key
(`--mode new`) and apply the same file. The Secret must **not** appear, and the
controller log must show an unseal error for it. If it appears, the drill is not
testing what you think and its green result is worthless.

**e. Tear the scratch cluster down** and remove `$DRILL_SITE`. Write down the
date and the export file's name somewhere your team will find it. The date of
the last successful drill is the fact that matters.

## What is not certified here

**Executed on a cluster** (the 0.7.1-rc2 gate, 2026-10-04, a single-node lab
k3s v1.36.4+k3s1, controller 0.40.0, age v1.2.1): step 1; step 2 with `--mode
reuse` against a running controller (1 key exported, every sealed file left
byte-identical, the public certificate written); step 3 (marker line present, 1
key in the export and 1 in the cluster); then the controller removed with
`helm uninstall` and its key Secret deleted, so step 6's test held, and step 6
with `--mode recover` (`--dry-run` first): the key restored, a new controller
installed, and the eleven SealedSecrets in the site, sealed weeks earlier to the
old key, all opened once ArgoCD applied `site-secrets`. That is the restore
proven on a fresh controller.

**Not executed:** step 5's renewal and several-keys behaviour, step 7's drill
on a scratch cluster, the manual restore into a running controller, `kubeseal
--recovery-unseal`, and the passphrase route. The `bootstrap-secrets` tests in
`tests/installer/` still run against shims
([secrets § what is not certified here](../administration/secrets.md#what-is-not-certified-here)).

**Taken from upstream, not observed:** the 30-day renewal, "newest key seals,
any active key unseals", "old keys are never deleted", the `--key-renew-period`
and `--key-cutoff-time` flags, the `active` label semantics and the restart
requirement all come from the sealed-secrets project's README as read on
2026-09-29. Nothing here read them off a running controller, and the controller
version the installer pins (0.40.0) is not one that reading was checked against.

**Not provided by this page or the installer:** an alert on a stale escrow,
multi-recipient handling for a team (step 1 says how to do it by hand), and a
way to export the key without also running the credential-minting step (step 2
says what `--mode reuse` does beside it).

**Not proven:** the controller's wording for a failed unseal, the SealedSecret
file layout that step 7b reads its namespace from, and `kubectl apply -o
jsonpath` on a SealedSecret. Each is a reasonable expectation from how
`kubeseal` writes files and how `kubectl` treats custom resources, and none has
been run.

## Next

- [Secrets](../administration/secrets.md) ... what the Secrets are, and why the
  key matters
- [Installation § the bootstrap route](../deployment/install.md#the-bootstrap-route-bootstrap-secrets)
  ... `bootstrap-secrets` in the install flow
- [Backup and restore § the whole-cluster story](backup-restore.md#7-the-whole-cluster-story-in-one-place)
  ... where the key sits among the five planes
- [Install with no internet access](../deployment/airgap.md) ... carrying the
  controller chart and image in

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

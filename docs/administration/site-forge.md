---
okf_version: "0.2"
type: Reference
title: "The built-in site forge"
description: "The git forge Tockmox installs beside ArgoCD to hold your site repository: why it is a prerequisite and not a layer, who can approve a change, where its settings live, how it is kept safe, and what it does not claim."
tags: [forge, forgejo, gitops, argocd, site-repository, approvals]
status: stable
generated:
  by: hand
  at: 2026-11-04
tockmox:
  classification: public
  audience: [operator]
---

# The built-in site forge

**Tockmox installs its own git forge beside ArgoCD, keeps your site repository in
it, and copies it off-site.** You need no account on GitHub or any other website,
there is no repository URL to copy and no token to type, and if the cluster is
lost the installer rebuilds it from the off-site copy. It is the installer's
default from 0.9.0 (`site.forge: built-in`), and it is supported. Bringing your own
forge (`site.forge: external`) stays supported too:
[install § bring your own forge](../deployment/install.md#bring-your-own-forge).

This page explains what the forge is and how it behaves. The steps that install it
are [install § publish to the built-in forge](../deployment/install.md#publish-to-the-built-in-forge),
and the steps that rebuild from it are
[rebuilding from the off-site copy](site-forge-recovery.md).

## What it replaces

On your own forge, the install asks for one outside account, a repository you
create there, a read-only token, a push, a placeholder replaced in thirteen files,
and a credential handed to ArgoCD by hand, where a missing label and an empty
paste both end in the same `ComparisonError` on every layer
([install § 2a to 2c](../deployment/install.md#bring-your-own-forge)). On the
built-in forge, one command (`tockmox-install.sh bootstrap-forge`) does all of it,
and none of the credentials it creates is ever shown to you.

## A prerequisite, not a layer

**The forge holds the repository ArgoCD reads, so it has to exist before ArgoCD
can read anything.** That is Tockmox's own test for a prerequisite
([ArgoCD](argocd.md)), so the installer installs the forge out of band, beside
ArgoCD and sealed-secrets, and ArgoCD never syncs the forge from the repository
the forge holds. A broken sync cannot take the forge down, and fixing the forge
never needs the forge.

What gets installed:

| Part | What it is |
|---|---|
| The forge | Forgejo on its long-term-support line, pinned by each Tockmox release, one replica with SQLite, in namespace `tockmox-forge`, as the Helm release `tockmox-forge` |
| The repository | `tockmox/site`, private, holding your site as `main` |
| Its address | `http://tockmox-forge-http.tockmox-forge.svc.cluster.local:3000/tockmox/site.git`, which every Application names. It is the same on every site and after every rebuild, and nothing outside the cluster resolves it, so there is no DNS, TLS or CA step for it |
| The fence | A NetworkPolicy admitting ArgoCD's repo-server, the console's actions service, the model watcher and the forge's own copy jobs, and nothing else. A browser reaches the forge through Traefik at `forge.<your internal domain>`, unless it was installed with `--no-sign-in` |
| Machine users | `tockmox-argocd` reads; `tockmox-changes` opens changes and cannot approve them; `tockmox-offsite` reads `main` for the off-site copy. Their tokens are minted in the cluster and live only in Secrets |

## Who can approve a change

**`main` takes no direct pushes, and nothing merges without one approval from the
`approvers` team.** A rejected review blocks the merge, and an approval goes stale
when the change under it moves. The forge enforces this, not the console, so a
stolen bot credential cannot merge: the bot that opens changes cannot approve its
own.

- **Approvers are your console's admin group.** People sign in to the forge
  through Authentik and are registered the first time they do; Forgejo's group
  mapping puts members of the admin group (`tockmox-admins` by default) in
  `approvers`. The forge's own password sign-in is switched off.
- **Nobody becomes the forge's administrator by signing in.** The administrator can
  merge past the branch rule (Forgejo has no way to stop that), so it stays one
  credential, in one Secret in the forge's namespace and in the recovery kit. No
  service holds it.
- **Taking someone out of the admin group** takes them out of `approvers` only at
  their next forge sign-in, which the default access rule then refuses, so remove
  them from the team by hand as well ([identity](identity.md)).
- **Approve in the forge's own pages, or in the console.** Changes the console
  and the model watcher open wait in the forge for an approver; with the console's
  Platform › Changes page on, they wait there too ([Approving in the
  console](#approving-in-the-console)). Either way the forge's rule decides.

## Changing your site

**Every change to `main` is a pull request an approver approves.** The branch
rule refuses a direct push, from anyone. So where another page says to commit
and push to your site repository, on the built-in forge you push a branch and
open a pull request instead, and someone in the admin group approves it; it
merges, and ArgoCD applies it within minutes.

**Clone the site from the forge once.** The site directory the installer wrote
on your workstation has no remote: `bootstrap-forge` pushed it through a
port-forward it does not keep. Sign in to the forge at
`https://forge.<your internal domain>` (through Authentik; your workstation must
trust the platform's CA, [TLS and trust](tls-and-trust.md)), and make a personal
access token under your user's settings, with read and write access to
repositories. Git asks for your forge user name and that token.

**YOU SUPPLY:** your internal domain.

**WORKSTATION**

```bash
export INTERNAL_DOMAIN=YOUR_INTERNAL_DOMAIN
git clone "https://forge.$INTERNAL_DOMAIN/tockmox/site.git" "$HOME/tockmox-site-forge"
export SITE_REPO="$HOME/tockmox-site-forge"
git -C "$SITE_REPO" log --oneline -1
```

**Success condition:** the last line names the forge's latest commit. Every
other page reads `SITE_REPO`, so from now on its blocks act on this clone.

**For each change,** start a branch from the latest `main` before you edit:

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first, see Changing your site}"
git -C "$SITE_REPO" switch main && git -C "$SITE_REPO" pull --ff-only
git -C "$SITE_REPO" switch -c "change-$(date +%Y%m%d-%H%M%S)"
```

Then make the change as the other page says, and where its block ends with
`git push`, push the branch instead:

**WORKSTATION**

```bash
: "${SITE_REPO:?export SITE_REPO first, see Changing your site}"
git -C "$SITE_REPO" push -u origin HEAD
```

The forge answers with a link to open the pull request. Open it, and an approver
approves it in the forge. Changes that the model watcher and the console open
arrive the same way, as pull requests from the change bot, waiting for an
approver, here or on the console's Platform › Changes page.

These steps are Forgejo's own, and Tockmox's tests do not yet run them end to
end; the branch rule they meet is tested on the lab.

### Approving in the console

**Platform › Changes lists every change waiting on `main`,** from the console,
the model watcher and other bots: a plain-language summary, its checks, and the
exact diff behind a fold, with **Approve and apply** and **Decline**. Recently
applied changes are listed below with **Revert**.

- **Approving goes through the forge as you, not as the console.** Your browser
  visits the forge's sign-in (Authentik's, so with a live session you see no
  prompt; the first time, the forge asks you once to allow the Tockmox console),
  then Authentik for a fresh sign-in, and comes back. The console's actions
  service exchanges the forge's answer for a token that is yours, approves
  exactly the commit you were shown, and merges. The merge is a merge commit
  whose message ends in an `Approved-by:` line naming you, so who approved
  travels with the history and every off-site copy. Your token is used for that
  one approval and kept nowhere; the forge expires it within ten minutes.
- **The forge decides, not the console.** Someone outside `approvers` who
  approves here is refused by the branch rule, and the page says so. A change
  that moved after you opened it is refused before anything is done.
- **The person who asked for a change does not approve it.** Every change the
  console opens, and every revert, records who asked for it
  (`Tockmox-Requested-By:`, their Authentik username), so the person is never
  hidden behind the change bot, and the merge commit carries `Requested-by:`
  beside `Approved-by:`. If you asked for a change, **Approve and apply** is
  refused and names who else in `approvers` can approve it. The one exception is
  a site where you are the only member of `approvers`: refusing would leave the
  change with no one to approve it, so the approval goes through, the merge
  commit ends in `Self-approved: sole approver`, and Recently applied shows the
  change with a **Self-approved** badge. Adding a second approver ends the
  exception by itself. `tockmoxUi.actions.changes.selfApproval: never` refuses
  even then; the default is `sole-approver-only`. When the console cannot read
  who is in `approvers`, it refuses rather than guess. The forge's own pages do
  not apply this rule, because the change bot, not you, is the change's author
  there; approve in the console for it to hold.
- **Decline** closes the change, as you, with your reason as a comment.
  **Revert** opens the opposite change, as the change bot: every file the change
  touched, back as it was. It waits for an approval like any change. A file
  that changed again since is not reverted here; revert that one by hand.
- **No service holds an admin credential.** The actions service has the change
  bot's token (which cannot approve) and the console's OAuth2 client, which acts
  only as the person who signs in. The console itself holds no forge credential.
- **While the forge does not answer**, the page reads **Changes paused** and
  offers nothing. Argo CD keeps running what is already applied.

### Opening a change from a page

**A page that renders a change can open it for you.** The models and
inference-node pages offer **Open as a change** beside **Download it**, and
**Platform › Identity** offers **Make an administrator**, which adds a name to
`sso.adminUsers`, and **Platform › Capabilities** offers **Turn on** and **Turn
off** for each capability. The confirm page shows the exact edit to the file on `main`
before anything is opened; confirming opens it as the change bot, and it waits
on Platform › Changes for an approval like any other. Nothing is applied until
an administrator approves it.

- **Only what the page set changes.** The console edits the keys the change
  names (`modelLifecycle`, `inferenceNodes` and the gateway's rolling
  annotation; `sso.adminUsers`; or one `capabilities.<name>.enabled`) and leaves every other line of the file as it
  was, comments included. A file it cannot edit that way (YAML anchors, a key
  written on one line in flow style, tabs) is refused with "edit it by hand",
  never edited approximately.
- **A change merged but not applied yet is never undone.** The models and nodes
  pages are drawn from what Argo CD applied, so the change names the site commit
  Argo CD last applied for the AI layer. If the file has changed on `main` since,
  the confirm page refuses and asks you to wait for the sync.
- **Asking twice opens one change.** The same edit asked for again answers with
  the change already open.
- **A capability is switched in the file every layer reads,** `global.yaml`.
  If a layer's own values file also sets that capability, the console refuses
  and names the file: that layer reads its own file after `global.yaml`, so the
  change would say one thing while the site did another. Single sign-on is never
  turned off from the console, because the console signs in through it and that
  change would lock out whoever approves it; set it by hand if you mean it.
- **Which files.** The models and nodes changes go to the file the model
  watcher writes (`modelLifecycle.watch.pullRequests.valuesPath`), or
  `site/values/ai.yaml` when that is unset; administrators go to
  `site/values/identity.yaml`; capabilities go to `site/values/global.yaml`.
  `tockmoxUi.actions.changes.modelsFile` and `identityFile` set the first two.
- **Not yet from a page:** a change that also needs a hand edit (a hosted model's
  entry in a gateway's `model_list`, or enrolling a node, which adds the node's
  own file). Those pages offer **Download it** only.

**It is on wherever the console is,** on a site whose forge is built in: the
installer writes `siteForge: built-in` into `global.yaml`, and the AI layer reads
it. `bootstrap-forge` writes the two Secrets the page needs into the AI layer's
namespace: `tockmox-forge-actions-bot` (the bot's token) and
`tockmox-forge-console-oauth` (the console's OAuth2 application, which sends
people back to `tockmox.<your internal domain>`; `--console-host` if yours is
another). To turn the page off, set `tockmoxUi.actions.changes.enabled: false`
in the AI layer's values, in the `tockmoxUi` block you already have.

The approval round trip through the forge's sign-in is tested against a stand-in
forge that models what was measured on Forgejo 15.0.11; it has not yet been run
end to end on a lab site.

## Where its settings live

**The installer owns the forge's settings: the branch rule, the teams and the
sign-in.** `bootstrap-forge` creates all three from its options on every install,
and the rebuild and the forge repair create them again the same way, then read the
branch rule back to check it took. To change one (the admin group, the forge's
address, sign-in on or off), re-run the installer with the new option. **A change
made by hand in the forge's own pages is not kept:** the nightly forge dump does
not carry these settings, so a rebuild or a repair puts them back to what the
installer's options say.

## How it is kept safe

The forge keeps three things off the cluster, and a rebuild needs all of them that
you set up:

- **The off-site copy** of `main`, within about a minute of every merge, to an
  S3-compatible bucket (as a git bundle) or a git remote. Optional; without one the
  console carries a persistent **No off-site copy** warning.
- **The nightly forge dump**, at 21:15 in the cluster's time zone, to the same
  place: every pull request, review and comment, and the repository's own record,
  which git does not carry.
- **The recovery kit**, one encrypted file the installer hands you: the forge's
  own secrets and your sealing-key backup. Keep it apart from the off-site copy.

What each holds, the alerts that watch them, and what a rebuild can still lose are
on [rebuilding from the off-site copy](site-forge-recovery.md).

**Platform › Site history** shows all of it in one place: where the history
lives and `main`'s last change, whether the off-site copy holds it (**Matches**,
**Copy pending** for the first 15 minutes after a change, **Behind**, or **No
off-site copy**, in the same words as the alerts), and whether the last rebuild
drill passed or is overdue. Below that are the recently applied changes, each
with **Revert**. From the page:

- **Copy now** runs the copy job once, as its schedule would; **Check the drill
  now** does the same for the daily drill check.
- **Download a copy** makes a git bundle of `main` now, the way the copy job
  does, and gives you `site.bundle` and `site.bundle.sha256`. Keep the two
  together: `tockmox-install.sh --restore-from file:site.bundle` checks one
  against the other before it uses the copy, which is how a disconnected site is
  rebuilt from media. The copy is not signed yet; its SHA-256 is the check.

The page is on wherever Platform › Changes is.

**While the forge is down and the cluster is fine,** running apps keep running.
ArgoCD reports `Unknown` with a `ComparisonError` and applies nothing new until the
forge answers again; `tockmox-install.sh repair-forge` brings it back from the copy
without touching anything else.

## On a disconnected site

The forge's image is in the air-gap image set with an SBOM, and `bootstrap-forge`
can also push your internal copy of the Tockmox charts repository into the forge,
so a site with no route to GitHub reads both its charts and its values from inside
the cluster: [install with no internet access](../deployment/airgap.md).

## Move to my own forge

**When you would rather keep the site on a forge of your own** (GitHub, GitLab,
your own Forgejo). The move takes the whole history, every branch and tag, not a
snapshot, and Argo CD changes source in one change that an approver merges, like
every other change to the site.

**YOU SUPPLY:** an **empty** repository there (no README, no licence, no branch),
its https address, and a file with two lines, a user and a token that can push to
it. Give a second file with a read-only token as `--read-credentials` if you can:
that one is the token Argo CD keeps.

**WORKSTATION**

```bash
: "${TOCKMOX:?export TOCKMOX first: your Tockmox clone}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first: the site's cluster}"
OWN_FORGE_URL=YOUR_EMPTY_REPOSITORY_URL
"$TOCKMOX/install/tockmox-install.sh" move-forge --context "$KUBE_CONTEXT" \
  --to "$OWN_FORGE_URL" --credentials "$HOME/tockmox-backup/own-forge-push"
```

It refuses a repository that is not empty, pushes every branch and tag and reads
`main` back, gives Argo CD a read credential for the new repository, and opens
one change on the built-in forge that names the new repository wherever the site
named the forge. **Approve it in Platform › Changes.** The command waits for that
(`--approval-wait-minutes`, default 60). Then it pushes the merged `main` to
the new repository, applies the root Application from it, and **archives** the
built-in forge's repository: read-only, nothing deleted.

**Success condition:** it ends with `the built-in forge's repository is
archived`, and Argo CD's Applications read the new address
(`kubectl -n argocd get applications -o wide`). If you approve later, run the same
command with `--finish`. Then, in `tockmox.yaml`, set `site.forge: external` with
the new repository, so the installer does not generate a built-in-forge site
again. The forge and its off-site copy job stay installed until you remove them.

## What it does not claim

- **It does not make the cluster its own backup.** The off-site copy and the
  recovery kit are what make a rebuild possible. A site without a copy cannot be
  rebuilt from one, and its No off-site copy warning says so each time it comes
  back. Running workloads and their data volumes are the business of
  [backup and restore](../operations/backup-restore.md), as before.
- **It detects tampering by someone who already owns the cluster; it does not
  prevent it.** Such a person holds the forge's administrator. A bucket with
  versioning or object lock keeps every earlier copy, and a git remote that refuses
  force pushes keeps the history, so a rewrite is visible and recoverable.
- **It is not highly available.** The forge runs one replica, on the storage class
  you give `bootstrap-forge` (the cluster's default otherwise, which on a stock
  k3s is a disk on one node). Losing that node is a forge repair from the copy, not
  a cluster rebuild.
- **It is not a code-hosting product.** It holds the site repository and, on a
  disconnected site, the charts repository. Your own applications' source code
  belongs elsewhere.
- **It has been run end to end on single-node k3s lab clusters only.** Nothing here
  has been run against a multi-node cluster.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

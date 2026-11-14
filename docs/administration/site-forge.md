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
| Machine users | `tockmox-argocd` reads; `tockmox-changes` opens changes and cannot approve them; `tockmox-offsite` reads `main` for the off-site copy; `tockmox-approver-watch` reads the approvers team and the open pull requests, for [the approvers watcher](#the-approvers-watcher). Their tokens are minted in the cluster and live only in Secrets |

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
  them from the team by hand as well ([identity](identity.md)). If you forget, the
  [approvers watcher](#the-approvers-watcher) raises an alert.
- **Approve in the forge's own pages, or in the console.** Changes the console
  and the model watcher open wait in the forge for an approver; with the console's
  Platform › Changes page on, they wait there too ([Approving in the
  console](#approving-in-the-console)). Either way the forge's rule decides.

## The approvers watcher

The forge updates a person's teams only when they sign in, so someone taken out of
the admin group (or deactivated) can keep approving changes to the site until you
remove them from `approvers` yourself. The watcher tells you when that has
happened. It detects and alerts. It cannot change the team, and nothing in the
cluster holds a credential that can: you remove the person, as the forge's admin.

`bootstrap-forge` installs it on any site with sign-in, as the Deployment
`tockmox-forge-approver-watch` in the forge's namespace. Every minute it reads
who is in the `approvers` team and who is an active member of the admin group, and
publishes the difference as metrics, one series per person. It also lists the open
pull requests that carry a standing approval from each such person. It uses the
image the move job already uses, runs as a non-root user with a read-only root
filesystem, and has no Kubernetes permissions.

It holds two credentials, in a Secret in the forge's namespace, and each can read
and nothing else:

| Credential | What it can do | What it cannot do |
|---|---|---|
| A token for the forge user `tockmox-approver-watch`, scoped `read:organization` and `read:repository` | List the `approvers` team and read the organisation's repositories, including the site repository's open pull requests and their reviews | Merge, approve, comment, push, change the branch rule or any team, add anyone to the organisation: the forge refuses this token every write. The user is in the Owners team and no other, never in `approvers` (see below) |
| A token for the Authentik service account `tockmox-forge-approver-watch` | View the admin group and its members | Change any group or user, or see anything else. The identity layer's blueprint gives its role one permission, view on that one group |

Why the forge user is in Owners: the forge shows who is in a team only to that
team's members and the organisation's owners, and the watcher must never be an
approver. So the account could change the organisation, and the token is what
stops it: its two read scopes are refused on every write, which the lab run checks.
Nobody can sign in as the account. Its password is made at install and never
kept, and the forge has no password sign-in. If you ever doubt the token, revoke
it in the forge as the site administrator and run `bootstrap-forge` again for a
new one.

Both tokens are made by `bootstrap-forge`. The forge token exists once, in the
watcher's Secret. The Authentik token is one value in two Secrets, the watcher's
and the identity layer's (`tockmox-forge-approver-watch` in the identity
namespace), because Authentik's blueprint reads it from there. A re-run keeps a
forge token that still works and an Authentik token that already exists, and
replaces only what is missing or rejected.

The same run writes two switches into your site's values before it pushes them:
`siteForge.approverWatch` in `observability.yaml`, which renders the two alerts and
the scrape, and `sso.apps.forge.approverWatch` in `identity.yaml`, which makes the
Authentik account. A value you have already set there, true or false, is left
alone. If a file has no `siteForge` or `sso.apps.forge` block to attach to, the
run says so and you add the line by hand. **If tockmox-identity is already running,
restart the Authentik worker once** after the first run: it reads the token when it
starts and does not re-apply a blueprint whose file has not changed.

The watcher's pod is fenced. It accepts connections only from Prometheus, on its
metrics port, and opens connections only to the forge, to Authentik's server and
to DNS. The run adds one NetworkPolicy in Authentik's namespace that admits that
one pod to the server, because that namespace otherwise admits only Traefik and
Prometheus.

Two alerts read it:

- **TockmoxForgeApproverOutsideGroup** (critical, one per person). That person is
  in the forge's `approvers` team but is no longer an active member of the admin
  group, so their approval still counts toward merging a change to the site. The
  alert names the open pull requests their approval stands on. Remove them from the
  team in the forge, as the forge's admin, and dismiss or decline those approvals;
  it stops once the team matches the group again. A deactivated account counts as
  removed.
- **TockmoxForgeApproversCheckDown** (warning, after 15 minutes). The watcher has
  not made a clean check, or Prometheus is not scraping it. While it is down, a
  removal would not be noticed. The watcher judges nobody on a read it could not
  complete: if Authentik errors, or answers with an admin group that has no active
  member while the `approvers` team still has people, it reports "not clean" and
  raises this alert, never the first one. A new site, with nobody in either yet,
  reads clean. Its log names the read that
  failed: `kubectl -n tockmox-forge logs deploy/tockmox-forge-approver-watch`.

A site installed with `--no-sign-in` has no admin group to compare with, so it has
no watcher and neither alert.

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
`sso.adminUsers`, **Platform › Capabilities** offers **Turn on** and **Turn
off** for each capability and for Platform Management, **Platform › Overview**
offers **Give to a role** for scheduled work with no owner, and **Platform ›
Updates** offers **Open the upgrade as a change**. The confirm page shows the exact edit to the file on `main`
before anything is opened; confirming opens it as the change bot, and it waits
on Platform › Changes for an approval like any other. Nothing is applied until
an administrator approves it.

- **Only what the page set changes.** The console edits the keys the change
  names (`modelLifecycle`, `inferenceNodes` and the gateway's rolling
  annotation; `sso.adminUsers`; one `capabilities.<name>.enabled`; or, in the
  AI layer's `site/values/ai.yaml`, `tockmoxUi.config.features.platform.enabled`
  or one `features.platform.assign` entry) and leaves every other line of the file as it
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
- **An upgrade moves every layer, and only the revision.** The change sets
  `targetRevision` from the running release to the target in every file under
  `bootstrap/applications` that names it, and leaves the lines reading
  `targetRevision: main` alone, as
  [step 5 of the upgrade guide](../deployment/upgrade.md#5-move-the-revision)
  does by hand. It is offered only when the release feed is verified, the
  preflight is green and no release on the way lists a breaking change (that
  edit goes in the same commit, so make it by hand). A layer on a third release
  is refused and named. The change's description carries the preflight and the
  checks only a person can make; do them before you approve.
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

## Move a running site in

**When your site already runs from a repository on a forge of your own** (GitHub,
GitLab, your own Forgejo) and you want it in the built-in forge. One command moves
it: the whole history comes across, every `repoURL` that names your repository
names the forge's in-cluster address in **one** commit, the built-in forge's
values are turned on, Argo CD is cut over, and your old repository becomes the
off-site copy. It is the inverse of [Move to my own forge](#move-to-my-own-forge).

**YOU SUPPLY:**

- a checkout of the site repository at exactly the revision Argo CD is synced to,
  with nothing uncommitted. The command works on a copy and never changes it.
- the repository's https address, and a file with two lines, a user and a token
  that can **push** to it: the forge's push mirror sends `main` there after every
  change, so that token must be allowed to push `main` directly (a branch rule or
  ruleset bypass). Pass `--no-offsite-copy` instead to leave the old repository as it is.
- what `bootstrap-forge` asks for (the recovery kit and its encryption), after `--`.

**WORKSTATION**

```bash
: "${TOCKMOX:?export TOCKMOX first: your Tockmox clone}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first: the site's cluster}"
SITE_DIR=YOUR_SITE_CHECKOUT
SITE_REPO_URL=YOUR_SITE_REPOSITORY_HTTPS_URL
AGE_RECIPIENT=YOUR_AGE_PUBLIC_KEY
"$TOCKMOX/install/tockmox-install.sh" move-in-forge --context "$KUBE_CONTEXT" \
  --site "$SITE_DIR" --from "$SITE_REPO_URL" \
  --from-credentials "$HOME/tockmox-backup/site-repo-push" --dry-run \
  -- --kit-out "$HOME/tockmox-backup/recovery-kit.tar.age" --age-recipient "$AGE_RECIPIENT" \
     --sealing-key-backup "$HOME/tockmox-backup/sealed-secrets.key.enc"
```

The dry run makes every check and shows the migration commit's files. Run it
again without `--dry-run` to move; it asks you to type the context name.

**It refuses, before it writes anything:** uncommitted or untracked changes in
the checkout; a checkout that is not the revision Argo CD is synced to; a root
Application that reads another repository (your repository in its ssh spelling,
`git@host:owner/repo.git`, is the same repository); an Application that is not
Synced and Healthy (name one you accept as it is with `--accept-unsettled`); and
a built-in forge that already holds another site's history.

**In order, once the checks pass:** a copy of Argo CD's credential for the old
repository is kept beside it, so Argo CD can read it at every moment of the
cutover; `bootstrap-forge` installs the forge and pushes the history plus the
migration commit; the root Application is applied from the forge; then the
command waits (`--wait-seconds`, default 900) until every Application reads the
forge, Synced and Healthy, each still managing every resource it managed before.
Then the credential copy is removed, and only then does `bootstrap-forge` run
once more to make your old repository the off-site copy, which pushes the
migration commit there. Until that moment the old repository is exactly what
Argo CD read before the move.

**Success condition:** it ends with `every Application reads the built-in forge,
Synced and Healthy, and nothing was pruned`. Run it again: it says `Nothing to
do`. Set `site.forge: built-in` in your `tockmox.yaml` before you run the
installer again.

**If the cutover does not settle,** nothing is undone for you. The command
prints what is wrong and the one command that points Argo CD back at your old
repository: your checkout's own `bootstrap/root.yaml`, which it never changed.
Or fix the cause and run the move again: it carries on from what the forge
holds, with the same migration commit.

**Two things change for you.** The built-in forge runs no CI: workflows on your
old repository no longer gate a change, and they see each change only when the
mirror pushes it there, after it is applied. And the forge's push mirror always
force-pushes, so block force-pushes and direct pushes to the old repository's
`main` for everyone but the token you gave: a rewrite is then refused and the
copy-behind alert fires.

## Move to my own forge

**When you would rather keep the site on a forge of your own** (GitHub, GitLab,
your own Forgejo). The move takes the whole history, every branch and tag, not a
snapshot, and Argo CD changes source in one change that an approver merges, like
every other change to the site.

**YOU SUPPLY:** an **empty** repository there (no README, no licence, no branch),
its https address, and a file with two lines, a user and a token that can push to
it. Give a second file with a read-only token as `--read-credentials` if you can:
that one is the token Argo CD keeps.

### From the console

On **Status › Site repository**, an administrator opens the drawer and picks
**"Move to my own forge…"**. It is there when the built-in forge's change actions
are on (`tockmoxUi.actions.moveForge`, on with them; `enabled: false` turns it
off). Each step asks for a fresh sign-in, and runs the same move as the command
below, in a Job inside the cluster.

1. **Check the target.** Type the empty repository's https address, then a user
   and a token that can push to it. Nothing is pushed. The page shows the branches,
   tags and `main` that will move and how many files the change rewrites, or the
   refusal in the move's own words.
2. **Start the move**, within ten minutes of a clean check. Give a read-only
   credential for Argo CD if you have one. The history is pushed, Argo CD gets its
   read credential, and the change opens on Platform › Changes. You asked for it,
   so an approver other than you merges it (the sole-approver exception applies).
3. **Finish the move**, from the same page once the change is merged: `main`
   pushed again, the root Application re-applied from the target, and the built-in
   repository archived. Finish needs the push credential again.

**Where the credential goes.** It is never on a page, in a cookie, in a log line or
in Activity. When you confirm, it goes to the console's actions service, which
keeps it once, for ten minutes. It is then written into one Secret,
`tockmox-forge-move-request`, which belongs to the run's Job and is deleted when
the run ends. Argo CD's read credential ends where the command leaves it,
`argocd/tockmox-site-repo-own`.

**What the Job may do.** `bootstrap-forge` installs the suspended CronJob
`tockmox-forge-move` with a ServiceAccount that can:

- read the forge's admin Secret;
- write Argo CD's one repository Secret;
- patch the one root Application.

An admission policy admits a move Job from the console only as that template
wrote it: its image, script, arguments and volumes. A target on a private CA
the site does not trust is refused; move it with the command instead.

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

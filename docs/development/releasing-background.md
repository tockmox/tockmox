---
okf_version: "0.2"
type: Reference
title: "Releasing background"
description: "The history and reasoning behind each RELEASING.md section, kept out of the checklist so the checklist stays short."
tags: [release, history, rationale, maintainer]
status: stable
generated:
  by: hand
  at: 2026-10-03
tockmox:
  classification: public
  audience: [contributor, machine]
---

# Releasing background

The history and reasoning behind [RELEASING.md](../../RELEASING.md), section by section, moved here so the checklist stays short. Where this page and the checklist differ, the checklist is authoritative. The patch bar and the operator gates have their own pages: [the patch bar](releasing-patch-bar.md) and [operator gates](releasing-operator-gates.md). Phrases such as "above" and "below" refer to the order of sections in RELEASING.md.

## A version bump is five edits, not one

The maintainer's checklist. Written after the 0.5.0 release, whose first
version-bump commit failed CI by treating the bump as one edit; every step
here exists because skipping it has already cost something.

5. `VERSION=` in `install/tockmox-install.sh`. **This one was missing from
   the list until 2026-09-01**, so it read `0.1.0` through 0.5.0 and through
   most of the 0.6.0 cycle. It is not decorative: every file the installer
   generates is stamped with it, and it is the default offered for
   `tockmox.revision`, so the installer's own suggestion was a tag that could
   not resolve. CI now compares it against `tockmox-common`.

Also version-shaped and NOT generated, so check them by hand at every bump:
`install/tockmox.yaml.example`'s `revision:` and the `targetRevision` in
`docs/deployment/profiles.md`. The example config shipped `main` with a
thirteen-line explanation that no tag existed yet for thirteen days after
0.5.0 was tagged (TM-0270). Prose does not get stamped.

**And a sixth, which breaks BY CONSTRUCTION every time you fix the two above:
`tools/doc-claims.txt`.** One of its entries guards
`install/tockmox.yaml.example` with a `claim:` of the literal text
`revision: vX.Y.Z`. That field is how the registry proves it is still attached
to the sentence it checks, so it pins the version on purpose ... and the moment
you bump the page, the registry detaches and `check-doc-claims.sh` reports
`CLAIM GONE`. Found at 0.6.1, where the first four edits were right and this one
failed the gate.

Read the refusal rather than pattern-matching it: `CLAIM GONE` and a failing
count are different findings. A count means the tree moved and a page is now
lying. `CLAIM GONE` means the sentence moved and the registry has lost its grip
on it, which is why the gate's own message says not to delete the entry without
reading what replaced the sentence. At a version bump it is almost always the
benign case, and "almost always" is exactly when a reader stops checking.

## The release gate

Nothing reaches a tag without a **teardown-and-greenfield install of the
exact tagged content** passing on a clean cluster: all layers Synced and
Healthy, backup completed, restore drill PASS in the register (an object in
the `tockmox-drill-register` bucket), alert delivered to the notification topic. Assert on artifacts, not exit codes ...
name a count or a specific row. The 0.5.0 gate run is the model: it caught a
DNS-record omission and a first-sync race that no amount of rendering would
have found.

While walking the gate install, remember the operator steps the docs
require, because a gate walker who skips one reads its symptom as a defect:
mint the console's model-gateway key once the gateway is running (install.md;
until then the AI layer stays `Progressing` with Open WebUI in
`CreateContainerConfigError`), and subscribe a device to the notification
topic (install.md), without which the alert row can only be read at the
topic. **Leave `local-path` as the cluster default:** fresh-install.md keeps it
default on purpose, and this paragraph told gate walkers to de-default it until
2026-09-29. The first-platform-sync race that once needed a
terminate-and-resync is closed (TM-0492): a first sync that needs a hand is
now a gate failure, and ArgoCD's own automatic retry inside the operation is
recorded in the gate report, not failed.

## The one gate CI cannot run

`tools/check-blueprint-discovery.sh` asserts that Authentik **discovered and
applied** every blueprint the identity layer ships, against the running
instance the gate install just created. It is the only script in `tools/`
that needs a live cluster, and that is the whole point of it: CI parses every
rendered blueprint and proves they are well-formed YAML, which proves nothing
about whether they apply against an EMPTY Authentik. That failure ... a
blueprint referencing a group, brand or application a fresh install does not
have ... exists only on greenfield, which is exactly what this gate walks.

With no `-f` it renders against `ci/values.yaml`, which is not a site; a site
that disables an app blueprint is correctly missing it, and the gate can only
know that from the site's values.

It needs no Authentik credentials (status is read through `ak shell`, which
is Django rather than the API), so it does **not** require a bootstrapped
instance and does not compete with leaving `/setup` untouched for a
screenshot.

**Both absence and error status are failure modes, and the gate checks
both.** The script was built on the premise that one invalid blueprint blocks
the discovery pass for all of them, so the casualties are absent rather than
errored. The 2026-09-02 poison run on Authentik 2026.5.6 disproved that: the
poisoned blueprint registered as `status=error` on its own, the shipped five
imported fine, and the first shape of the gate exited 0 while printing the
failure as a footnote. So the script now asserts the expected set is PRESENT,
then that each member is `successful`, and then that **no** blueprint on the
instance, shipped or foreign, sits in a non-successful state. A timeout is a
failure rather than a pass. Presence checking is still right; it is no longer
sufficient.

## Release branching, and the tagging invariant

**The real invariant, stated once so nothing below has to imply it twice: CI
runs green on the exact commit that gets tagged. Not a parent, not a child.**
Everything in this section is mechanics in service of that one sentence.

Through 0.6.0 this repository tagged whatever commit `main` sat on after the
last rc, while "Before the tag" below required commits made *after* that rc
(the CHANGELOG retitle, README version-shaped content, the ROADMAP stamp) and
the run sheet for the same release tagged the rc's own commit, unchanged.
Both cannot be true of one commit at once. 0.6.0 shipped by tagging a tree two
commits past its last gated commit ("Gate evidence must be re-run when the
tree changes", below, states what covered that gap and what it left uncovered
rather than pretending it did not happen). That is the contradiction this
section closes, not a pattern to repeat.

**A release is cut on its own branch, `release-X.Y`.** (This line read "From
0.7.0" until 2026-09-17 and "From 0.6.1" until 2026-09-28. 0.6.1 did not use the
branch; the orientation section below says what it did instead.)

- Cut `release-X.Y` once an rc is imminent, not at the start of the cycle. The
  five-edit version bump happens on that branch.
- Every `vX.Y.Z-rcN` and the final `vX.Y.Z` live on `release-X.Y`, never
  tagged directly off the development line.
- The final tag sits on the commit named in the gate report: whichever commit
  the last full CI run actually covered. If a "before the tag" edit lands
  after that run, CI runs again on the new commit before the tag moves, full
  stop ... an edit is never "small enough" to skip the re-run.
- A patch (`vX.Y.Z+1`) is cut from `release-X.Y`, not from wherever
  development has since moved. Which direction the fix travels afterward is
  set by the orientation below.

## Orientation: `main` is the development trunk (option B)

**Ruled 2026-09-17 (TM-0654): option B.** `main` is where development
happens; `release-X.Y` is cut from it when a candidate is ready; a patch fix
lands on `main` first and is cherry-picked back to `release-X.Y`. **The 0.6.1
cut did NOT exercise this, and this paragraph said it would.** A local
`release-0.6` branch was created on 2026-09-17 at a commit already on `main`
and never pushed; every 0.6.1 candidate (`-rc1` through `-rc5`) is tagged on a
`main` commit, and the final tag goes on the last candidate's commit. Every change on `main` since `v0.6.0` was either 0.6.1 scope or
docs, tests and tooling; the patch bar's entry condition held at each candidate
with its one recorded exception; and each candidate was tagged on a commit whose
own CI run was green, which is the invariant above. The branch mechanic is therefore still
unexercised; its first real test is the first release that needs a patch cut
from a line `main` has moved past. (This sentence said "the 0.6.1 cut is the
first exercise" until 2026-09-28. Corrected to what happened rather than left
as a plan the release contradicted.) The table below is kept so the reasons
stay readable next to the mechanics; both options share every mechanic
above and differ only in what `main` means and which direction a fix
travels.

| | **A. `main` is the latest release** | **B. `main` is the development trunk** |
|---|---|---|
| A clone of `main` gets | Shipped code, always | Whatever is being built for the next release |
| Development happens on | Its own long-lived branch (e.g. `0.7.0`) | `main` itself |
| `release-X.Y` is branched from | The development branch, when a candidate is ready | `main`, when a candidate is ready |
| A patch fix is written on | `release-X.Y`, then **forward-ported** to the development branch | `main`, then **back-ported** (cherry-picked) to `release-X.Y` |
| Skipping that port produces | A **regression**: the next release re-ships a bug the patch already fixed | A **gap**: the old release misses a fix `main` already has, visible and non-regressive |
| Precedent | GitFlow's `main`/`develop` split | Kubernetes, Helm, Prometheus, Grafana, cert-manager, ArgoCD |

Every place in this document that says "the development line" means
`main`. Two consequences of option A that this ruling avoids, recorded so
the reasoning survives: a Renovate configuration with no `baseBranchPatterns`
targets `main`, which under A is a frozen release line; and the
`[Unreleased]` compare link in `CHANGELOG.md` already reads `main` as the
trunk.

## Gate evidence must be re-run when the tree changes

A signed gate report describes a specific commit. **Any commit between the one
the gate ran against and the one that gets tagged either re-runs the gates it
could affect, or is named in the release notes as untested.** "The gate
passed" is a claim about the commit it ran on, not about the tag, and the two
are only the same claim when nothing landed in between.

0.6.0 shipped exactly two such commits (`GATE-REPORT-v0.6.0.md`, "Changed
after the gate ran"), and both are worth reading as the model:

1. A CHANGELOG-only edit. No product content, nothing to re-run.
2. A values-file edit disabling a piece of third-party telemetry. This one
   **was** re-run: the full static gate suite, both lint matrices, every
   gate's selftest, the values-tier drift check, the SBOM check and the docs
   stamp check all passed against the final tree, and the rendered manifest
   was read to confirm the value actually reached the template. **What it was
   not re-run against is the cluster**: the gate install itself was not
   repeated, so nothing in that second pass confirms cluster-observed
   behaviour. The report says so under "WHAT WAS NOT TESTED" instead of
   folding the change silently into "the gate passed".

Repeat that shape: name what changed, name which gates reran, and say plainly
which kind of evidence ... static or cluster ... still rests on the earlier
run.

## Which checks run per RC, and which run once at the tag

| **`tockmox-site-template` drift check** | **Yes** | Two halves, and only one is automated: the template's own `pin-consistency` workflow proves its nine `targetRevision` pins and README agree with each other; the diff of the template against what `install/tockmox-install.sh` generates is still a manual step on the rc, and nothing in either repository runs it when an rc is cut. A third, narrower assertion runs when any `v*` tag (rc included) is pushed: `.github/workflows/release-tag.yaml` runs `tools/site-pin-at-tag.sh`, which fails when the template's `main` does not pin the tag just pushed (TM-0534) |

The two bolded rows never ran before 0.6.0's last three hours. Moving them
into the per-RC column is the actual fix: a check run once, immediately
before the tag, has no runway left to act on what it finds. The site-template
drift check found a p1, adopter-facing defect in a public repository that
shipping had to carry as a Known Issue for want of time to choose a fix
(TM-0675) ... exactly the outcome running it earlier exists to prevent.

## An rc tag silently disarms the values-tier drift gate

`tools/check-values-tiers.sh` takes its baseline from
`git describe --tags --abbrev=0`, which returns the nearest tag reachable from
`HEAD`. **The moment `vX.Y.Z-rc1` is tagged, that is the baseline** ... so a
drift re-run between the rc tag and the final tag compares the candidate
against itself. Every stable key matches, because it is the same tree. The gate
reports PASSED and has measured nothing.

The default has since changed to the newest final `v*` tag by version order, so
an rc no longer does this by itself. It still happens once the final tag of the
release being cut exists, and the explicit baseline below remains the rule.

This is the failure the gate was written to refuse, arriving through the door
the gate reads its own baseline from, and it is invisible: the only tell is the
`baseline:` line in the output, which reads `vX.Y.Z-rc1` where it should read
the previous release.

**So from the first rc of a cycle onward, pass the previous release explicitly:**

(The command is in RELEASING.md under this heading.)

Read the `baseline:` line every time rather than the exit code. A drift run
whose baseline is any tag from the release being cut is not a result.

The same caution applies to anything else deriving a version from
`git describe`. Kubernetes shipped a release where an rc tag and a release tag
landed on one commit and every subsequent build derived the wrong version from
it; the lesson is not that two tags on a commit is wrong ... promoting an rc to
a final on the *same commit* is the normal pattern, and is what makes "what was
proven is what shipped" literally rather than approximately true ... but that
tooling reading `git describe` must be told which tag it means during the
window when both exist.

## The release text is written last, from the run sheet

**Ruled 2026-09-29 (TM-0792).** The release gate is where most of what the
release notes have to say is learned, so the notes cannot be final before it.
Every release so far has needed a text commit after its last test: 0.6.2 needed
one between rc1 and rc2 and another after the gate on rc2, and each time it was
handled as an exception. It is the normal order, so it is written down as one.

**What a text-only commit has to re-prove.** A commit is text-only when
`git diff --stat <gated commit> <candidate>` lists nothing but `CHANGELOG.md`,
`ROADMAP.md` and `RELEASING.md` (and README lines that are only
version-shaped). For such a commit:

- **Required:** a green `ci` push run on that exact commit (the tagging
  invariant above), and `tools/release-preflight.sh` on it.
- **Not required:** the lab gate and `executed-docs`. Nothing either of them
  exercises changed, and `executed-docs` is path-filtered to `docs/**`,
  `tests/executed-docs/**` and its own workflow file, so it would not even
  trigger. The gate report
  names the commit under "Changed after the gate ran", the shape the section
  above describes.
- **Anything else in the diff is not text-only.** A change under `docs/**`
  re-runs `executed-docs` on the exact commit; anything under `charts/`,
  `install/` or `tools/` re-runs whatever it can affect, per "Gate evidence
  must be re-run when the tree changes".

## The tag

Signed (`-s`), because `docs/deployment/verify.md` tells users to check the
signature and a doc that overpromises is a bug.

## No image is published (and where the documentation comes from)

**A release publishes no container image.** ADR-0036 says the repository
distributes source, never compiled artifacts or container images, and that holds
for the documentation too. There is nothing to build and push at the tag.

The workflow that did, `docs-image.yaml`, was on main from 2026-09-30 and was
deleted with `images/tockmox-docs/` (TM-0808). Do not bring either back. A `v*`
tag must not start a build that pushes to a registry, and
`tools/check-no-published-images.sh` (in `tools/check-all.sh` and in CI) fails
the build if any workflow under `.github/workflows/` does. It looks for registry
pushes, a `packages: write` permission and registry logins; read its header for
the exact list, and note that it reads workflow text only, so it cannot see a
push made by a script a workflow calls.

If a `ghcr.io/tockmox/tockmox-docs` tag was ever pushed (this repository has no record of one; as far as
it knows, none was), delete it from the
package settings before the release is announced.

**The documentation reaches an operator's cluster from their own checkout, not
from the release.** The operator checks out the tag, runs `tools/build-docs.sh`
and `tools/publish-docs.sh --context CTX`, and the script copies the built site
into the docs bucket through a short-lived pod (design: TM-0805,
`product/docs-delivery-without-an-image-design-2026-09-30.md`; procedure:
[serving static sites](../administration/serving-static-sites.md#publishing-the-product-documentation)).
The release therefore has three obligations and no artifact:

- the tag is signed, because the operator's trust in the docs they build is their
  trust in the checkout (the script compares the checkout with the site's
  `tockmox.revision` and does nothing about a signature);
- the pinned MkDocs set in `docs-site/requirements.txt` still builds the site
  (`tools/check-all.sh` runs `tools/build-docs.sh` through the offline and
  site-contents gates, and skips them where the toolchain is absent, so run the
  full suite once with the docs venv on `PATH` before the tag);
- the release lab pass runs `tools/publish-docs.sh` from the tag against the lab
  and records the marker and the `/` 200 and missing-page 404 through the Ingress.

What this does not prove: a pull or publish of anything by a release. The
publish script has been run against one single-node lab cluster (the TM-0807
report), not on a dark site and not on an installer-generated cluster.

## The GitHub Release is a second step, and nothing prompts for it

The tag and the Release are different objects. Pushing the tag publishes
nothing readable; the Release is layered on afterward, and a missed one
never needs a re-tag ... it can be created or edited against an existing tag
at any time:

(The command is in RELEASING.md under this heading.)

(For the newest release the section runs to EOF; drop the trailing range
pattern.) The Release body IS the changelog section ... it is written to
serve as one, so paste nothing else.

**Then confirm the README release badge picked up the tag** ... with the
caveat that **the badge cannot render while this repository is private**.
shields.io reads the releases API unauthenticated, gets nothing, and falls
back; the LINK still resolves to the new release, which is the half worth
checking until the repository goes public. Do not chase a broken image that
is a property of the repository's visibility rather than of the release.

## Post the Announcement, from 0.6.0 onward

**A release nobody is told about is a tag.** The Release page is a record;
the Announcement is the thing that reaches a person who is not watching the
repository.

(The command is in RELEASING.md under this heading.)

Post the Announcement (Discussions → Announcements) with a link to the Release
and a short summary in your own words. **Not the changelog again** ... that is already the
Release body, and pasting it twice teaches readers the announcement carries
nothing new. What belongs here and nowhere else:

- **who should upgrade and who should not**, in a sentence
- **anything a reader must do by hand**, and the Known Issues they will meet
- **what was not tested** ... the gate report says it, and the announcement is
  where somebody actually reads it

**`gh release create --discussion-category Announcements` opens the
Announcement for you and links the two objects**, so on a release where the
summary is ready first, that is one step rather than two. `gh release edit`
carries no such flag: once the Release exists without one, the Announcement is
a separate object created against the repository, not against the Release.

## Checksums, from 0.6.0 onward

`docs/deployment/verify.md` has promised since before the first tag that
"every release publishes a `SHA256SUMS`". Through v0.5.0 this procedure
produced none, so the promise was false for the only release that existed.
It is a step now rather than a sentence:

(The command is in RELEASING.md under this heading.)

**Attach the archive, do not rely on GitHub's auto-generated tarball.**
GitHub's generated source archives are not guaranteed byte-stable over time,
so a checksum taken against one can stop matching without anything being
wrong. `git archive` from the tag is deterministic for a given git version and
is the object the checksum describes. `verify.md` says the same thing to the
reader from the other side.

The archive is a convenience for people who do not want a git clone. The
signed tag remains the stronger verification path, and `verify.md` says so.

## The gate report, from 0.6.0 onward

**SSH, not GPG, and the namespace is `file`.** This project signs with an SSH
key throughout ... `.gitsigners` is an allowed-signers file and there is no GPG
anywhere in the chain. The namespace has to differ from git's `git`, because
that is what stops a signature over one kind of object being replayed as
another; `verify.md` § 4 fails a reader who passes the wrong one, deliberately.

**Reuse the tag key rather than minting a second one.** The public half is
already published in `.gitsigners` and in `SECURITY.md`, so a reader who has
verified the tag already holds everything needed to verify the report, and no
new key distribution problem is created.

**What the signature is for, stated so nobody oversells it downstream:** it
makes the report attributable and tamper-evident. **It does not make the report
true.** A signed claim about a gate run is still a claim, which is why the
"what was not tested" section is part of the signed bytes.

## Close the release's own tracking, from 0.6.1 onward

**The last step of a release was missing from this document entirely until
2026-09-17.** At 0.6.0 the cut card sat unstarted while the signed `v0.6.0` tag
existed, and the release milestone stayed open with the release shipped.
Neither was anybody's oversight: **no step asked for it.** The failure is
silent, which is what earns it a numbered step here — the artefact ships, the
board still shows the release in flight, and the next planning pass reads an
open milestone as remaining work.

1. **Close the cut item** the moment the Release page has been read and
   verified. That is when its definition of done first becomes testable, and
   any later is how it gets forgotten.

2. **Test the release milestone's definition of done clause by clause**, then
   close it — or record exactly which clause does not hold and why it is not
   closing. **A waived clause is not a met clause.** That milestone is what a
   later reader treats as proof the release met its bar, and this is the only
   moment anybody reads the bar word for word, so it is also the moment a bar
   that has gone stale surfaces. At 0.6.0 one clause had been wrong for two
   weeks, a backlog sweep had already flagged it, and it still took this step to
   force the decision.

3. **Sweep the milestone's open children** before closing it: each one closes,
   moves to the next release, or is detached with a reason. Six were open at
   0.6.0's close-out, and two of those turned out already fixed in the tree with
   nobody having looked.

4. **Write the ledger rows.** The tracking tooling prints that it does not write
   ledgers, and that line is easy to walk past.

This applies to every release, patches included. The mechanics of *where* the
tracking lives are maintainer-side and deliberately not named here; the
obligation is.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

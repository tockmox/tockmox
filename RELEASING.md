# Releasing

The maintainer's checklist. Each step exists because skipping it has cost
something; the history is in [releasing background](docs/development/releasing-background.md).

## A version bump is five edits, not one

1. `version:` in all ten `Chart.yaml` (nine layers + `tockmox-common`).
2. The `tockmox-common` **dependency pin** in every layer's `dependencies:`
   block. `helm dependency build` refuses a lock whose pinned version no longer
   exists.
3. `helm dependency update` in every layer, to regenerate the nine
   `Chart.lock` digests.
4. `tools/gen-sbom.sh`. The SBOM embeds the chart version and CI fails when it
   goes stale.
5. `VERSION=` in `install/tockmox-install.sh`. Every file the installer
   generates is stamped with it, and it is the default offered for
   `tockmox.revision`. CI compares it against `tockmox-common`.

Then `tools/stamp-docs.sh`, which rewrites every docs footer from Chart.yaml
and refuses to run if the ten charts disagree.

Version-shaped and not generated, so check by hand at every bump:
`install/tockmox.yaml.example`'s `revision:` and the `targetRevision` in
`docs/deployment/profiles.md`. Prose does not get stamped.

A sixth, which breaks by construction when you fix the two above:
`tools/doc-claims.txt`. One entry guards `install/tockmox.yaml.example` with the
literal claim `revision: vX.Y.Z`, so bumping the page detaches the entry and
`check-doc-claims.sh` reports `CLAIM GONE`.

Read the refusal. `CLAIM GONE` means the sentence moved and the registry lost
its grip on it; a failing count means the tree moved and a page is now wrong.
Do not delete the entry without reading what replaced the sentence. At a
version bump it is almost always the benign case.

## The release gate

Nothing reaches a tag without a **teardown-and-greenfield install of the exact
tagged content** passing on a clean cluster: all layers Synced and Healthy,
backup completed, restore drill PASS in the register, alert delivered to the
notification topic. Assert on artifacts, not exit codes ... name a count or a
specific row.

Operator steps the docs require. A gate walker who skips one reads its symptom
as a defect:

- Mint the console's model-gateway key once the gateway is running (install.md).
  Until then the AI layer stays `Progressing` with Open WebUI in
  `CreateContainerConfigError`.
- Subscribe a device to the notification topic (install.md). Without it the
  alert row can only be read at the topic.
- **Leave `local-path` as the cluster default.** fresh-install.md keeps it
  default on purpose.

A first sync that needs a hand is a gate failure (TM-0492). ArgoCD's own
automatic retry inside the operation is recorded in the gate report, not failed.

### The one gate CI cannot run

`tools/check-blueprint-discovery.sh` asserts that Authentik **discovered and
applied** every blueprint the identity layer ships, against the instance the
gate install just created. It is the only script in `tools/` that needs a live
cluster. CI proves the blueprints are well-formed YAML; it cannot prove they
apply against an empty Authentik.

Run it during the gate install, after the identity layer goes Healthy, from the
tree the install came from, with the site's values files in install order
(globals first, then the layer's file):

```bash
./tools/check-blueprint-discovery.sh \
  -f SITE/site/values/global.yaml \
  -f SITE/site/values/identity.yaml
```

With no `-f` it renders against `ci/values.yaml`, which is not a site; a site
that disables an app blueprint is correctly missing it.

It needs no Authentik credentials (status is read through `ak shell`), so it
does not require a bootstrapped instance and leaves `/setup` untouched for a
screenshot.

It checks that the expected set is present, that each member is `successful`,
and that **no** blueprint on the instance, shipped or foreign, is in a
non-successful state. Absence and error status are both failure modes. A
timeout is a failure.

Prove the gate can fail at least once per release where the blueprints
changed:

```bash
./tools/check-blueprint-discovery.sh --poison   # then follow its instructions
```

A gate never observed refusing is indistinguishable from one that cannot.

## The patch bar

The gate above is the bar for a minor release. Ruled 2026-09-17, before 0.6.1
used it: **a patch is proved by what it changed, not by re-proving the
product.** Full text: [the patch bar](docs/development/releasing-patch-bar.md).

### Entry condition: what a patch may not contain

A release qualifies only if it carries **no chart logic change, no ordering
change, and no new image**. None of:

- a change under `charts/*/templates/`
- a change to a `sync-wave` or Argo hook annotation, or to the order
  Applications are applied in
- a change to an image reference, in a values file or in `images.txt`
- a change to a values default that alters a rendered resource's behaviour

A dashboard JSON, an alert rule's text, a documentation page and a generated
site file are outside the list. **A patch that touches any item above takes the
greenfield.** Quote the git pathspec as `'charts/*/templates/*'` (TM-0756).

The list reads template source, not rendered output, and a version bump alone
changes `helm.sh/chart` on every resource, which Kubernetes refuses on an
immutable field (a Job's `spec.template`, a workload's `spec.selector`;
TM-0753). **`tools/check-immutable-fields.sh` reads the rendered output
(TM-0754):** run it with `BASELINE_REF`; a hit handled elsewhere goes in
`tools/immutable-fields-allow.txt` with its reason, and anything else is a
template change recorded against the entry condition in the release notes.

### The proofs a patch does require

Each is scoped to something the release changed and names an artefact, not an
exit code.

1. The behaviour change, observed reconciling. Not reviewed, not rendered.
2. Documentation fixes executed as printed, on the operating system they
   describe. A fix that transcribes a recorded execution cites that log, and
   the notes say transcribed.
3. A rendered screenshot for anything that changes what a dashboard displays.
4. The upgrade: panel proofs and screenshots taken on an existing install
   upgraded to the candidate, with what converged and what did not recorded.
   Snapshot the nodes first and record the snapshot's identifier in the gate
   report.

### Explicitly not run for a patch

The N-row acceptance sweep, Phase D, Phase E, and the soak. The outside-eyes
pass is already minor-releases-only (per-RC table below).

### The gate report still gets written and signed

"From 0.6.0 onward" in the gate-report section below means every release,
patches included. A patch's report is shorter, not absent: the proofs above
with their observed values, and a **what was NOT tested** section naming the
greenfield, Phase D, Phase E, the soak and the N-row sweep as skipped.

### The version bump belongs to the branch, not to the trunk

A patch's fixes land on `main` first and are cherry-picked back, but the
five-edit version bump happens only on `release-X.Y`.

### How bars are written here

A release bar names **a property to hold, not a number to beat** (TM-0157).

The per-RC checks table and the upgrade leg's standing assertions are also kept
as data in `tools/release-bars.yaml`. `tools/check-release-bars.sh` fails when
the two disagree, so a row changed here is changed there in the same commit.

## The patch train

How a patch is cut once `X.Y.0` has shipped and `main` has moved on. It runs
the patch bar above; it does not lower it. Written before the first train ran
on the `0.8` line and corrected as trains run.

### What feeds a train

- **Fixes** land on `main` first and are cherry-picked to `release-X.Y` by
  pull request, as the orientation below says. A fix enters a train only with
  its own proof: a check that was observed red before the fix and green after.
- **Dependency updates** are the exception to "main first". Renovate targets
  the current line by exact name (`baseBranchPatterns` in `renovate.json5`) and
  opens PRs against it directly, because once `main` is the next minor its
  dependency commits stop applying to the line. On the line a patch update opens
  on its own, a minor waits for a dashboard tick (the tick is the nomination),
  a major is never proposed, workflow pins are off, and everything waits seven
  days, the AI plane included; `main` keeps the AI plane's no-soak rule for
  dogfooding. Security alerts jump the queue on both. Read the effective config
  in the Renovate log once per line: an inherited setting has overridden the
  file before.
- **Nomination is the PR.** Approving it at the cutoff puts it on the train.
  Nothing nominated is dropped by the train on its own; an item that fails is
  carded and rolls to the next cutoff.

### The night: build and prove a candidate

1. Branch `train/X.Y.Z` from `release-X.Y`, merge the nominated PRs onto it,
   recording each merged head's SHA, and open it as a PR against `release-X.Y`
   so `ci` and `policy-gate` run on its head. Per-PR green is admission, not
   proof. The PR is never merged with the button; step 3 of the morning
   fast-forwards the line to it.
2. The five-edit version bump, on the train branch. Idempotent, and the number
   is reused if the candidate goes unsigned and folds into the next train.
3. The static gates, on the train head: `check-all.sh`, `ci`, `policy-gate`,
   `executed-docs` (dispatched with its `ref` input, since it does not run on
   a train branch push), `tools/release-preflight.sh`, the immutable-field
   check and the values-tier drift check with `BASELINE_REF` set to the
   previous final tag (read the `baseline:` line),
   `tools/site-template-diff.sh` and `tools/check-airgap.sh`. A SKIP is not
   green; exit code 2 is BLOCKED.
4. The lab, against that exact SHA:
   - the **upgrade leg** from the previous final tag, carrying
     [the standing assertions](#the-upgrade-legs-standing-assertions), on a
     restore of the lab snapshot taken of the previous release;
   - the same leg **from `X.Y.0`** when that is a different tag, or the gate
     report lists "upgrading across a skipped patch" under NOT tested;
   - the **greenfield** whenever the entry condition above fails, which any
     image change does, so nearly every dependency-driven patch takes it.
   A product failure stops the train and the packet names it; an
   infrastructure error gets one re-run on a fresh restore. Nothing is reverted
   out of the candidate automatically: a single-item revert would have dropped a
   good fix on 0.8.1, where the one failure was a memory limit fixed forward.
5. The paperwork, drafted from the run sheet and left unsigned: the gate report,
   the CHANGELOG section (see the cost block below), the `tockmox-site-template`
   re-pin PR, and the lab snapshot of the candidate that the next train's
   upgrade leg restores. The release text may land as one
   text-only commit on the train branch under the rule in "The release text is
   written last", with its own green `ci` run.

The night ends READY or NOT READY. NOT READY costs the morning nothing: the
cause is carded, the items roll forward, and any decision waits for the next
cutoff.

### The morning: one script, in this order

1. **Verify.** Your own git derives the head of `train/X.Y.Z`; the script does
   not take a SHA from the packet. The head is the SHA the lab tested, or
   differs from it by one text-only commit that `ci` ran green on. It refuses
   any diff in the train that touches `.gitsigners`, `SECURITY.md`,
   `docs/deployment/verify.md`, `.github/**`, `renovate.json5` or the release
   tools.
2. Merge the `tockmox-site-template` re-pin PR
   ([the re-pin window](#the-re-pin-window) opens here; the tag closes it).
3. Fast-forward `release-X.Y` to the train head and push. The line never
   carries content the lab did not test.
4. Create and sign the tag on that commit ("The tag" below), and push it.
5. Sign the gate report and generate `SHA256SUMS` (both sections below).
6. Publish the drafted Release with `--verify-tag`, so an unsigned tag cannot be
   created by the Release step.

Then the post-tag steps as for any release: the `CHANGELOG.md` port to `main`,
the Announcement when there is an operator action or a new Known Issue, and
"Close the release's own tracking". Note the minutes and hand actions the
morning took; they are the measure of whether the train is paying for itself.

### Cadence, skips, and security

- **Target, not a commitment:** one train every two weeks, the first a week
  after `X.Y.0`. The cadence is published, as a target, once three trains have
  run; until then it is this sentence.
- **Skip rule.** Churn that is only dependency updates cuts at most monthly. A
  train cuts when it carries a fix, a security-relevant bump, or a fix to a
  published Known Issue. A skip writes a ledger row, never silence. Two
  candidates in a row left unsigned drop the cadence to monthly.
- **Security fixes ship out of band**, not on the next train. An embargoed
  vulnerability is worked in the private advisory fork and never on a public
  train branch; SECURITY.md states the support window.
- **A line ends at the next minor's final tag.** `release-X.Y` receives no train
  after `vX.(Y+1).0` exists.

### Checklist rows the train adds

- **At the next minor's final tag, flip the Renovate release branch name**: in
  `renovate.json5`, `baseBranchPatterns` and every `matchBaseBranches` name the
  new line (`release-X.(Y+1)`), in the same change that tags. A pattern is not
  a substitute; the exact name is what ends the old line's PRs.
- **Every patch release's notes carry a "what taking this patch costs" block**,
  computed from the diff between the previous final tag and the candidate, not
  written from memory:
  - **hand actions**: every step an operator must take beyond changing the
    nine `targetRevision` pins, or "none";
  - **rollback class**: a revision swap, or a restore of a named application's
    database, in which case the pre-upgrade backup is required and the notes
    say so (`docs/deployment/upgrade.md`, step 2);
  - **images delta**: what `images.txt` and the SBOM gained, lost or moved;
  - **contract delta**: values tiers and immutable fields that moved, or
    "none";
  - **air-gap line, dated**: re-proved on the date, or skipped and stated.

## Release branching, and the tagging invariant

**The invariant: CI runs green on the exact commit that gets tagged. Not a
parent, not a child.** Everything in this section is mechanics in service of
that sentence.

**A release is cut on its own branch, `release-X.Y`.** 0.6.1 did not use the
branch (see the orientation below).

- Cut `release-X.Y` once an rc is imminent, not at the start of the cycle. The
  five-edit version bump happens on that branch.
- Every `vX.Y.Z-rcN` and the final `vX.Y.Z` live on `release-X.Y`, never tagged
  directly off the development line.
- The final tag sits on the commit named in the gate report: whichever commit
  the last full CI run covered. If a "before the tag" edit lands after that
  run, CI runs again on the new commit before the tag moves. An edit is never
  small enough to skip the re-run.
- A patch (`vX.Y.Z+1`) is cut from `release-X.Y`, not from wherever development
  has since moved.

### Orientation: `main` is the development trunk (option B)

**Ruled 2026-09-17 (TM-0654): option B.** `main` is where development happens;
`release-X.Y` is cut from it when a candidate is ready; a patch fix lands on
`main` first and is cherry-picked back to `release-X.Y`. Skipping the port
leaves a gap (the old release misses a fix `main` has), visible and
non-regressive. Dependency updates are the one exception: Renovate opens them
against the line directly ([the patch train](#the-patch-train)). "The
development line" anywhere in this document means `main`.

The 0.6.1 cut did not exercise the branch. A local `release-0.6` was created
on 2026-09-17 and never pushed; `-rc1` through `-rc5` and the final tag are on
`main` commits, each with a green CI run on its own commit, and the patch bar's
entry condition held at each (one recorded exception). The branch mechanic is
still unexercised; its first real test is the first release that needs a patch
cut from a line `main` has moved past. The option A/B comparison table and the
reasons for B are in [releasing background](docs/development/releasing-background.md#orientation-main-is-the-development-trunk-option-b).

### Gate evidence must be re-run when the tree changes

A signed gate report describes a specific commit. **Any commit between the one
the gate ran against and the one that gets tagged either re-runs the gates it
could affect, or is named in the release notes as untested.**

Name what changed, name which gates reran, and say plainly which kind of
evidence (static or cluster) still rests on the earlier run. The 0.6.0 gate
report ("Changed after the gate ran") is the model; see
[releasing background](docs/development/releasing-background.md#gate-evidence-must-be-re-run-when-the-tree-changes).

### Which checks run per RC, and which run once at the tag

| Check | Per RC | At the tag only |
|---|---|---|
| Full CI (`ci.yaml`) | Every rc push | ... |
| `tools/release-preflight.sh` | Once prose is expected final | Again, on the exact commit being tagged |
| Greenfield gate on the lab | At least on the rc the tag is cut from | Not repeated if the tagged commit does not differ from that rc's gated commit |
| **`tockmox-site-template` drift check** | **Yes** | Two halves, one automated: the template's `pin-consistency` workflow proves its nine `targetRevision` pins and README agree; the diff of the template against what `install/tockmox-install.sh` generates is `tools/site-template-diff.sh <template checkout>` on the rc (TM-0621), which fails on any difference not recorded in `tools/site-template-divergences.txt`. When any `v*` tag (rc included) is pushed, `.github/workflows/release-tag.yaml` runs `tools/site-pin-at-tag.sh`, which fails when the template's `main` does not pin the tag just pushed (TM-0534) |
| **Version-shaped-prose sweep** (`grep -rn 'v0\.'` across `install/`, `docs/`, `README.md`) | **Yes** | ... |
| **Values-tier drift** (`tools/check-values-tiers.sh --drift-only`) | **Yes, but pass `BASELINE_REF`**, see below | Again at the tag, same override |
| **Upgrade leg** (TM-0281) | **Required** once per cycle, on the rc the tag is cut from, carrying [the standing assertions](#the-upgrade-legs-standing-assertions) | Not repeated if the tagged commit is that rc's commit |
| **Immutable-field check** (`tools/check-immutable-fields.sh`, pass `BASELINE_REF`; [the patch bar](#entry-condition-what-a-patch-may-not-contain)) | **Yes**, on every rc whose chart version differs from the baseline | Not repeated if the tagged commit is that rc's commit |
| Air-gap re-proof | ... | Once per release, or explicitly skipped in the notes |
| `SHA256SUMS`, signed gate report | ... | Generated from the tag |
| Outside-eyes pass (minor releases) | **Once, on the last rc** (TM-0685): the rc is what the final tag will be, so findings can still land in the release | Not run again on the final tag |

The two bolded rows (site-template drift, version-shaped-prose sweep) belong in
the per-RC column: a check run once, just before the tag, has no runway left to
act on what it finds (TM-0675).

#### The re-pin window

The template is re-pinned and merged **before** the tag is pushed, because
preflight check 5 and the per-RC column above want the re-pin verified while it
can still be fixed. That order is accepted (TM-0738), and it has a consequence
that is stated here rather than discovered: from the merge of the re-pin until
the tag exists, the public `tockmox-site-template` names a `targetRevision` that
does not resolve, and anyone who clones it in that time gets Applications
ArgoCD cannot read. The window opens at every rc as well as at every final tag.

Its expected length is **hours**: the time from the merged re-pin to the tag push,
which is the time the last gate takes (the 0.6.1 window was hours). It is not a
state to leave overnight. If a gate fails after the re-pin is merged, either fix
and tag the same day or revert the re-pin.

Preflight check 5 now reports it. After the pins agree it asks the Tockmox
repository the template points at (`git ls-remote`) whether the tag exists and
prints one of three states: `RESOLVES`; `WINDOW OPEN`, meaning the remote
answered and has no such tag (expected before the tag, so it warns and does not
fail); or `CANNOT CONFIRM`, meaning the remote could not be asked (a private
repository, no network), which is never reported as a pass. Run check 5 again
after the tag is pushed and expect `RESOLVES`.

#### The upgrade leg's standing assertions

The upgrade leg installs (or restores) the previous release with a site that
sets real values, seeds data, bumps the site's pins to the candidate, and reads
the result. Release-specific rows (a recreated StorageClass, a CRD replacement)
are added per release; these rows are on every leg, before and after the push:

| Assertion | Read | Red if |
|---|---|---|
| Starting state is the recorded previous release | every layer's synced revision, before the push | any layer not on the previous tag, or an autosync before the leg was ready |
| The upgrade is the documented edits only | the site diff, plus every other action taken | any step not in the CHANGELOG or `docs/deployment/upgrade.md` |
| Convergence | time from push to every Application Synced/Healthy, retryCount per layer | a layer not Synced/Healthy, or `field is immutable` in any condition |
| Data survived | probe row counts and checksums in each database; PVC name, uid and volume | any count, checksum, uid or volume differs |
| **Exactly one default StorageClass** | count of StorageClasses annotated `storageclass.kubernetes.io/is-default-class: "true"`, before and after | 0 or more than 1 after the upgrade |
| **A secret sealed under the previous release still decrypts** | a SealedSecret sealed with the previous release's controller certificate before the push; after convergence, its Secret exists and its `Synced` condition is True | no Secret, or `no key could decrypt secret` |
| **Per-volume used bytes** | used bytes per PVC (`kubelet_volume_stats_used_bytes`, or `df` from a pod mounting the claim where Prometheus is off), before and after | a volume that fell sharply or to near zero: a claim can keep its uid and still come back empty |
| **`stable` values keys survive** | the previous release's site values, setting at least one `stable` key per layer it configures, render and sync on the candidate with no edit beyond the documented ones; `BASELINE_REF=<previous tag> tools/check-values-tiers.sh --drift-only` | a `stable` key renamed, dropped, retyped or rejected by the schema, or a layer that needs an undocumented values edit |

The last four were added after the 0.7.0 leg, which carried none of them
(TM-0846). A row that cannot be read on the leg goes in the gate report as
UNVERIFIED with the reason, never as PASS.

#### An rc tag silently disarms the values-tier drift gate

`tools/check-values-tiers.sh` and `tools/check-immutable-fields.sh` default
their baseline to the newest final `v*` tag by version order, as the
`render-diff` job in CI does, and use a release candidate tag only when no
final release exists. They no longer ask `git describe --tags --abbrev=0`,
which returned the candidate itself as soon as `vX.Y.Z-rc1` was tagged (a drift
re-run then compared the candidate against itself and reported PASSED having
measured nothing) and, on `main`, an older release than the newest one, because
releases are tagged on `release-X.Y` branches that never merge back. The same
thing still happens once the final tag of the release being cut exists. The
only tell is the `baseline:` line.

**From the first rc of a cycle onward, pass the previous release explicitly:**

```bash
BASELINE_REF=v0.6.0 ./tools/check-values-tiers.sh --drift-only
```

Read the `baseline:` line every time, not the exit code. A drift run whose
baseline is any tag from the release being cut is not a result.

The same applies to anything else deriving a version from `git describe`:
tooling must be told which tag it means while both an rc and the final exist.
Promoting an rc to a final on the same commit is the normal pattern.

## The release text is written last, from the run sheet

**Ruled 2026-09-29 (TM-0792).** The gate is where most of what the notes say is
learned, so a text commit after the last test is the normal order. Draft these
into the run sheet while the gate runs, and write the CHANGELOG from it
afterwards, not from memory:

- the route the greenfield took (a fresh k3s, or a reinstall after the
  documented uninstall), stated as what ran;
- measured timings, restarts and retries, with the unit of what was measured
  (a database restart and the layer's `Degraded` window are two numbers);
- every new Known Issue the run found, and every existing claim it re-verified,
  narrowed or disproved;
- what was deliberately not tested;
- for a patch, the "what taking this patch costs" block
  ([the patch train](#checklist-rows-the-train-adds)).

**One text commit, not a series**; each extra commit is another CI run before
the tag can move. A commit is text-only when
`git diff --stat <gated commit> <candidate>` lists nothing but `CHANGELOG.md`,
`ROADMAP.md` and `RELEASING.md` (and README lines that are only
version-shaped). A text-only commit requires a green `ci` push run on that exact
commit and `tools/release-preflight.sh` on it. It does not require the lab gate
or `executed-docs` (path-filtered to `docs/**`, `tests/executed-docs/**` and its
own workflow file); the gate report names it under "Changed after the gate
ran". Anything else in the diff is not text-only: a change under `docs/**`
re-runs `executed-docs` on the exact commit, and anything under `charts/`,
`install/` or `tools/` re-runs whatever it can affect.

After a tag cut from `release-X.Y`, `main`'s `CHANGELOG.md` gains the `[X.Y.Z]`
section as it shipped, and `[Unreleased]` drops the entries that shipped in it.

## Before the tag

These edits land on `release-X.Y`, and **each one is followed by another green
CI run before the tag moves**: edit, run, confirm green, then tag on that exact
commit.

- CHANGELOG: retitle the release section with the version and date. Releases
  describe what ships, not the development journey; a fix for something never
  released folds into its feature's description or disappears.
- README: anything version-shaped (the upgrade example, the releases section)
  tells the truth about this tag.
- `ROADMAP.md`: re-read every item against the tree; move anything this tag
  shipped, correct anything the task surface contradicts, and bump
  `Last reviewed`.
- Read the `render-diff` job's summary on the release PR: every layer rendered
  at the previous tag and at the candidate against
  `ci/values-site-minimal.yaml`, diffed. A field a resource lost or a default
  it gained is a values key that moved, and belongs in the release notes under
  the action required. The same report against a real site's files:
  `./tools/render-diff.sh vPREV HEAD -f SITE/site/values/global.yaml -f SITE/site/values/LAYER.yaml`.
  A clean diff does not prove the upgrade applies; only an upgrade run against
  a real deployment does.
- `tools/check-upgrade-safety.sh`, `tools/check-harness-context.sh` (and its
  `--selftest`), `tools/check-lan-cidr-overlap.sh` and
  `tools/check-garage-block-size.sh` run in `check-all.sh`, not in `ci.yaml`
  (adding a `ci.yaml` gate moves the pinned gate count). Run `check-all.sh` on
  the tag commit, under the Helm major version operators use: a render gate has
  already disagreed between Helm 3 and Helm 4 (a parent's `null` does not
  delete a subchart default under Helm 4).
- The repository variable `TOCKMOX_SUBSTRATE_CONTEXT` is set (Settings,
  Secrets and variables, Actions, Variables): the kubectl context of the
  Harvester rig in the runner's kubeconfig. Every kubectl and helm call under
  `tests/executed-docs/` names its cluster from it and refuses when it is
  empty, so without it the nightly `paths` job refuses in its preflight and
  `freshness` goes red after its stale window.
- No internal tracker ids ship: `grep -cE 'TM-[0-9]{4}' CHANGELOG.md` prints
  0 and `git grep -nE 'HL-[0-9]{4}'` prints nothing. Strip the id and keep the
  sentence true without it; CONTRIBUTING.md says where `TM-` ids may stay.

## The tag

Tag on `release-X.Y`, at the commit that just passed CI:

```bash
git tag -s vX.Y.Z -m "Tockmox X.Y.Z"
git push origin vX.Y.Z
```

Signed (`-s`), because `docs/deployment/verify.md` tells users to check the
signature.

**A release PR and its main port can merge back to back.** The `paths` job of
`executed-docs` runs on every push to `main` and `release-*`, and every such
run builds the one VM `tockmox-test/k3s-test-01` on the devtest rig. The job
sits in the concurrency group `executed-docs-tockmox-test` with
`cancel-in-progress: false`, so two push runs execute one after the other, not
together. Two things follow. A run that waits shows `pending` (the rc4 pair,
merged 14 s apart, behaved this way), and GitHub keeps only one pending run
per group, so a third push cancels the older pending run: read `executed-docs`
on the TAG commit, and re-run it if it reads cancelled. A run can also fail
alone for lack of rig capacity (the rc3 release run, Longhorn
ReplicaSchedulingFailure at 1733 of 1832 GiB); that is a capacity failure, not
a collision, and a re-run once space is free is the remedy.

## No image is published (and where the documentation comes from)

**A release publishes no container image.** ADR-0036: the repository
distributes source, never compiled artifacts or container images, the
documentation included. Nothing is built and pushed at the tag.

`docs-image.yaml` was on main from 2026-09-30 and was deleted with
`images/tockmox-docs/` (TM-0808). Do not bring either back. A `v*` tag must not
start a build that pushes to a registry, and `tools/check-no-published-images.sh`
(in `tools/check-all.sh` and in CI) fails the build if any workflow under
`.github/workflows/` does. It looks for registry pushes, a `packages: write`
permission and registry logins (its header has the exact list), and reads
workflow text only, so it cannot see a push made by a script a workflow calls.

Before the tag, confirm the tree is clean of it:

```bash
ls .github/workflows                       # ci.yaml and executed-docs.yaml; no docs-image
./tools/check-no-published-images.sh       # ends "no workflow publishes an image"
```

If a `ghcr.io/tockmox/tockmox-docs` tag was ever pushed (this repository has no
record of one), delete it from the package settings before the release is
announced.

**The documentation reaches an operator's cluster from their own checkout**
(`tools/build-docs.sh`, then `tools/publish-docs.sh --context CTX`; procedure:
[serving static sites](docs/administration/serving-static-sites.md#publishing-the-product-documentation)).
The release has three obligations and no artifact:

- the tag is signed (the script compares the checkout with the site's
  `tockmox.revision` and does nothing about a signature);
- the pinned MkDocs set in `docs-site/requirements.txt` still builds the site.
  `tools/check-all.sh` skips the offline and site-contents gates where the
  toolchain is absent, so run the full suite once with the docs venv on `PATH`;
- the release lab pass runs `tools/publish-docs.sh` from the tag against the lab
  and records the marker and the `/` 200 and missing-page 404 through the Ingress.

Not proven: the publish script has run against one single-node lab cluster (the
TM-0807 report), not on a dark site or an installer-generated cluster. Design:
TM-0805, `product/docs-delivery-without-an-image-design-2026-09-30.md`.

## The GitHub Release is a second step, and nothing prompts for it

The tag and the Release are different objects. Pushing the tag publishes
nothing readable. A missed Release never needs a re-tag; create or edit it
against the existing tag at any time:

```bash
NOTES=$(mktemp)
sed -n '/^## \[X.Y.Z\]/,/^## \[/p' CHANGELOG.md | sed '1d;$d' > "$NOTES"
gh release create vX.Y.Z --title "Tockmox X.Y.Z" --notes-file "$NOTES" --verify-tag
```

For the newest release the section runs to EOF; drop the trailing range
pattern. The Release body is the changelog section; paste nothing else.

Then confirm the README release badge picked up the tag. The badge cannot
render while this repository is private (shields.io reads the releases API
unauthenticated); the link still resolves to the new release, which is the half
worth checking until the repository goes public.

## Post the Announcement, from 0.6.0 onward

A release nobody is told about is a tag. The Release page is a record; the
Announcement reaches a person who is not watching the repository.

```bash
gh api repos/:owner/:repo --jq '.has_discussions'   # false: enable it in Settings first
gh release view vX.Y.Z --json url --jq .url
```

Post the Announcement (Discussions, Announcements) with a link to the Release
and a short summary in your own words. Not the changelog again. A patch cut by
[the patch train](#the-patch-train) posts one when it carries an operator action
or a new Known Issue; for a dependency-only patch with neither, the Release
page and its cost block are the announcement. It carries:

- who should upgrade and who should not, in a sentence
- anything a reader must do by hand, and the Known Issues they will meet
- what was not tested (the gate report says it; the announcement is where
  somebody reads it)

`gh release create --discussion-category Announcements` opens the Announcement
and links the two objects in one step. `gh release edit` has no such flag: once
the Release exists without one, the Announcement is a separate object created
against the repository.

## Checksums, from 0.6.0 onward

`docs/deployment/verify.md` promises that every release publishes a
`SHA256SUMS`:

```bash
TAG=vX.Y.Z
git archive --format=tar.gz --prefix="tockmox-${TAG#v}/" -o "tockmox-${TAG#v}.tar.gz" "$TAG"
sha256sum "tockmox-${TAG#v}.tar.gz" > SHA256SUMS
gh release upload "$TAG" "tockmox-${TAG#v}.tar.gz" SHA256SUMS
```

Attach the archive; do not rely on GitHub's auto-generated tarball, which is
not guaranteed byte-stable. `git archive` from the tag is deterministic for a
given git version. The archive is a convenience; the signed tag remains the
stronger verification path, as `verify.md` says.

## The gate report, from 0.6.0 onward

The gate runs on equipment nobody outside this repository can see, so its
result is published as a signed artifact. Generate the report from the run
sheet: cluster shape, tag, date, **every asserted artifact with its observed
value**, and a section naming what was NOT tested. Sign it with the key that
signs the tags:

```bash
TAG=vX.Y.Z
REPORT=GATE-REPORT-${TAG}.md
SIGNING_KEY=YOUR_TAG_SIGNING_KEY

# Confirm it is the key .gitsigners vouches for BEFORE signing. Signing with
# the wrong key produces a .sig that verifies against nothing, and the first
# person to notice is a reader following verify.md § 4.
diff <(ssh-keygen -y -f "$SIGNING_KEY" | awk '{print $1" "$2}') \
     <(awk '{print $2" "$3}' .gitsigners) && echo "key matches .gitsigners"

ssh-keygen -Y sign -f "$SIGNING_KEY" -n file "$REPORT"
gh release upload "$TAG" "$REPORT" "${REPORT}.sig"
```

- **SSH, not GPG, and the namespace is `file`.** `.gitsigners` is an
  allowed-signers file; there is no GPG in the chain. The namespace differs
  from git's `git` so a signature over one kind of object cannot be replayed as
  another; `verify.md` § 4 fails a reader who passes the wrong one.
- **Reuse the tag key.** Its public half is already in `.gitsigners` and
  `SECURITY.md`.
- The signature makes the report attributable and tamper-evident. It does not
  make the report true, which is why "what was not tested" is part of the
  signed bytes.

## Close the release's own tracking, from 0.6.1 onward

No step asked for this until 2026-09-17, and the failure is silent: the
artefact ships while the board still shows the release in flight.

1. **Close the cut item** as soon as the Release page has been read and
   verified.
2. **Test the release milestone's definition of done clause by clause**, then
   close it, or record which clause does not hold and why it is not closing. A
   waived clause is not a met clause.
3. **Sweep the milestone's open children** before closing it: each one closes,
   moves to the next release, or is detached with a reason.
4. **Write the ledger rows.** The tracking tooling prints that it does not
   write ledgers.

This applies to every release, patches included. Where the tracking lives is
maintainer-side and deliberately not named here.

## Operator gates that run outside CI

Five steps run on the maintainer's equipment or against a second repository
and leave no trace in a workflow log. What each proves, and where its evidence
lands, is in [operator gates](docs/development/releasing-operator-gates.md).

- **Greenfield release gate on the lab cluster** ("The release gate" above).
  Evidence: the signed gate report attached to the Release alongside
  `images.txt`. It does not yet walk an upgrade from the preceding tag
  ([ROADMAP.md](ROADMAP.md)).
  [`tests/executed-docs/INVENTORY.md`](tests/executed-docs/INVENTORY.md) row C2
  records the one script in it CI cannot run.
- **Air-gap re-proof.** Each release repeats the disconnected install or says in
  the notes it was skipped. Evidence: the dated result at the top of
  [`airgap.md`](docs/deployment/airgap.md); `INVENTORY.md` row A7 records why the
  harness does not duplicate it.
- **`tockmox-site-template` re-pin.** Nine `targetRevision: vX.Y.Z` lines in
  `bootstrap/applications/*.yaml` and one "Pinned to" line in the README of
  [`tockmox/tockmox-site-template`](https://github.com/tockmox/tockmox-site-template),
  re-pinned by hand. The tag push runs `tools/site-pin-at-tag.sh`
  (`release-tag.yaml`, TM-0534) and goes red if the template's `main` does not
  pin that tag; it is an alarm, not a gate. The re-pin merges before the tag, so
  the template names an unresolvable ref for hours at every release
  ([the re-pin window](#the-re-pin-window)); preflight check 5 reports whether
  the ref resolves. Evidence: the template's history, and
  `grep -h 'targetRevision:' bootstrap/applications/*.yaml | sort | uniq -c`
  reading nine lines on the new tag and **eleven** on `main` (ten before 0.6.1;
  the extra line is the single-source `site-secrets` Application).
- **SHA256SUMS** ("Checksums" above). Evidence: the archive and `SHA256SUMS`
  present on the Release page, confirmed by viewing it.
- **Outside-eyes pass, minor releases only, advisory.** An external model reads
  the **last release candidate's tag** cold as five prospective adopters, once,
  and not the final tag. It never blocks a tag. Evidence: a maintainer-held
  scoreboard outside this repository. Re-derive every flagged item against the
  tree before it becomes a tracked defect.

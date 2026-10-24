---
okf_version: "0.2"
type: Reference
title: "The patch bar"
description: "The full text of the patch bar: entry condition, immutable-field detail, the proofs a patch requires and why bars are written as properties."
tags: [release, patch, gate, maintainer]
status: stable
generated:
  by: hand
  at: 2026-10-03
tockmox:
  classification: public
  audience: [contributor, machine]
---

# The patch bar

The full text behind the patch-bar sections of [RELEASING.md](../../RELEASING.md). The checklist there is authoritative; this page keeps the reasoning and the detail.

The gate above is the right bar for a minor release, and through 0.6.0 it was
the only bar this document had — so every patch either re-ran a full greenfield
or improvised one. 0.6.1 is the first patch, so the question arrived whether or
not it was answered. Ruled 2026-09-17 and written here **before 0.6.1 used it**,
rather than produced by its precedent.

**A patch is proved by what it changed, not by re-proving the product.**

### Entry condition: what a patch may not contain

A release qualifies for this bar only if it carries **no chart logic change, no
ordering change, and no new image**. Precisely, none of:

- a change under `charts/*/templates/`
- a change to a `sync-wave` or Argo hook annotation, or to the order
  Applications are applied in
- a change to an image reference, in a values file or in `images.txt`
- a change to a values default that alters a rendered resource's behaviour

Reading the first item with git, quote the pathspec so the shell does not
expand it, but write `'charts/*/templates/*'`, not `'charts/*/templates/'`.
The read once ran as the latter: a quoted pathspec containing a wildcard is
wildmatched against the WHOLE path rather than given directory-prefix
treatment, so a pattern ending in `templates/` only matches a path that ENDS
in `templates/`, which no file path does, and the read returned empty for
every commit range it was ever run against (TM-0756).

A dashboard JSON, an alert rule's text, a documentation page and a generated
site file are outside that list. A dashboard change instead carries the rendered
screenshot below, because what dashboards get wrong is a presentation defect
that no rendered manifest shows.

This half of the bar is the useful half: it decides scope at the top of the
release instead of arguing about proof at the bottom. **A patch that touches any
item above is not a patch for gate purposes, and takes the greenfield.**

**The entry condition reads template source, not rendered output.** An
unchanged `charts/*/templates/` does not mean an unchanged rendered chart.
`helm.sh/chart` is rendered from `Chart.yaml`'s version by the shared label
helper in `tockmox-common`, so a version bump alone changes that label on every
resource that carries it, including the labels inside a pod template
(`spec.template`).

**Kubernetes refuses that change on a field that is immutable.** Jobs are the
case that has bitten: `Job.spec.template` is immutable, so a Job left in the
cluster by the previous release cannot take the new label in place, and the
sync fails on upgrade while a fresh install, which never had the old Job,
passes. On 0.6.1-rc1 this stopped `tockmox-platform` converging on an upgraded
install, with no template file changed and every item in the list above
reading clean (TM-0753, fixed in `ec6ddbb` by putting the chart version in the
Job's name). The same class includes `spec.selector` on a Deployment,
DaemonSet or StatefulSet, and a StatefulSet's `serviceName` and
`volumeClaimTemplates`.

**`tools/check-immutable-fields.sh` reads the rendered output (TM-0754).** It
renders every layer chart at the baseline tag and at the candidate, with each
side's own `ci/values.yaml` and the all-on overlay, and names any object present
at both whose immutable field differs: a Job's `spec.template`, a Deployment,
DaemonSet or StatefulSet `spec.selector`, a StatefulSet's `serviceName`,
`volumeClaimTemplates` and `podManagementPolicy`, a Service's `clusterIP`, a
PersistentVolumeClaim's class, access modes and volume. A Job is safe when its
name changes with the version, or when it is an Argo CD or Helm hook with
`hook-delete-policy: BeforeHookCreation`, which deletes it before creating the
new one. A rendered diff that touches only mutable fields is green: a version
bump rewrites `helm.sh/chart` everywhere, and the check says how large the diff
was rather than refusing it. Pass `BASELINE_REF` as for the values-tier check,
because `git describe --tags` lies once an rc exists. A hit that is handled
elsewhere goes in `tools/immutable-fields-allow.txt` with its reason; anything
else is a template change, recorded against the entry condition in the release
notes rather than passed through quietly. The per-RC table below carries the
check as its own row. It sees only the kinds listed above, and only with the CI
values: a site that switches on more must run it with `--values`.

### The proofs a patch does require

Each is scoped to something the release changed, and each names an artefact
rather than an exit code.

1. **The behaviour change, observed reconciling.** Not reviewed, not rendered.
   For 0.6.1 that is the site template's `site-secrets` Application applying a
   committed SealedSecret into a real Secret.

2. **Documentation fixes read on the operating system they describe.** These are
   instructions that were already wrong once, so the failure mode is *wrong
   again in a new way*, and review structurally cannot catch that. Execute them
   as printed, on that OS.

   **Where a fix transcribes an execution already recorded** — a doc change
   whose entire content is output somebody captured — that log is the proof,
   cited by name, and the release notes say transcribed rather than re-executed.
   Do not tear a cluster down to re-observe output already written down.

3. **A rendered screenshot for anything that changes what a dashboard
   displays.** A panel defect is visible only on the rendered board. Two
   releases paid for that lesson before it was written here.

4. **The upgrade, because that is how a patch reaches anybody.** Every existing
   operator takes a patch by changing one `targetRevision` and syncing;
   greenfield is the path each operator walks once. So take the panel proofs and
   the screenshots on an **existing install upgraded to the candidate**, not on
   a fresh one, and record what converged and what did not. It is also the
   cheapest honest way to stop [ROADMAP.md](../../ROADMAP.md) listing an executed
   release-to-release upgrade under Next.

   **Snapshot the nodes before the upgrade leg.** On virtualised lab hardware
   the pre-upgrade state is one API object away from being reusable, and that
   changes what the leg is worth: the upgrade becomes repeatable rather than
   single-shot, a failed convergence is recoverable instead of terminal, and the
   greenfield option survives the experiment. A single-shot upgrade run also
   produces a single-shot claim — if the leg cannot be replayed from the same
   starting state, nobody can distinguish a correct ordering from a lucky one.
   Record the snapshot's identifier in the gate report alongside the observed
   values, because that is what makes the run reproducible by somebody else.

### Explicitly not run for a patch

The N-row acceptance sweep, Phase D, Phase E, and the soak. Stated plainly,
because a bar that lists only its inclusions gets read as an abbreviation of the
full gate rather than as a different gate. The outside-eyes pass is already
minor-releases-only, per the per-RC table below.

### The gate report still gets written and signed

"From 0.6.0 onward" in the gate-report section below means every release,
patches included. A patch's report is shorter, not absent: the proofs above with
their observed values, and a **what was NOT tested** section naming the
greenfield, Phase D, Phase E, the soak and the N-row sweep as deliberately
skipped under this bar. A reader of the Release can then tell which bar the tag
was held to, which is the entire reason the report is signed.

### The version bump belongs to the branch, not to the trunk

Under the orientation below, a patch's fixes land on `main` first and are
cherry-picked back — but **the five-edit version bump happens only on
`release-X.Y`**. `main` is heading for the next minor release, and a patch
version stamped there is a false statement about the trunk.

### How bars are written here

A release bar names **a property to hold, not a number to beat.** TM-0157's
fourth clause asked for "a named number lower than 21" against a list
`tools/check-airgap.sh` itself calls a documented limitation expected to
persist. The gate passed and the target did not, and the clause had to be
amended at close-out rather than met. Write the property.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

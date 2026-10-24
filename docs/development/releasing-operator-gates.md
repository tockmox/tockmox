---
okf_version: "0.2"
type: Reference
title: "Operator gates"
description: "The five release steps that run outside CI, what each proves and where its evidence lands."
tags: [release, operator, gate, maintainer]
status: stable
generated:
  by: hand
  at: 2026-10-03
tockmox:
  classification: public
  audience: [contributor, machine]
---

# Operator gates

The full text behind "Operator gates that run outside CI" in [RELEASING.md](../../RELEASING.md). Section names below refer to that file.

CI proves that the tree renders, validates and reads consistently. Five
steps in the release procedure run on the maintainer's own equipment or
against a second repository, and none of them leaves a trace in a workflow
log. Each is listed here with what it proves and where its evidence lands, so
a reader of a release can tell which claims rest on a green badge and which
rest on a run somebody performed by hand.

**Greenfield release gate on the lab cluster.** The gate described under
"The release gate" above runs on the maintainer's lab cluster, not in CI. The
cluster is torn down and rebuilt from the operating system up, and the
candidate is installed from nothing. It proves that the exact tagged content
installs, backs up, restores and alerts against a real cluster. **It does not
yet walk an upgrade from the preceding tag.** "Change one line in your site
repository and sync" is the path every existing operator takes and greenfield
is the path each takes once, so the upgrade walk belongs in this gate; no
release candidate has run it, and [ROADMAP.md](../../ROADMAP.md) lists an executed
release-to-release upgrade under Next rather than claiming it here.
Evidence: a signed gate report generated from the run sheet and attached to
the GitHub Release alongside `images.txt`, naming the cluster shape, the tag,
each asserted artefact with its observed value, and a "what was NOT tested"
section. [`tests/executed-docs/INVENTORY.md`](../../tests/executed-docs/INVENTORY.md)
row C2 records the one script in this gate that CI cannot run.

**Air-gap re-proof.** [`docs/deployment/airgap.md`](../deployment/airgap.md)
states the date on which a disconnected greenfield install last succeeded.
That is a claim with a date on it: each release either repeats the exercise
(uplink cut, images served from a local mirror, the charts repository and the
site repository served from internal git, subcharts vendored, prerequisites
staged) or says in the release notes that the run was skipped, so the page
never asserts a proof that was not repeated. It proves that all five
dependencies the page enumerates are reachable with no uplink, not only the
images. Evidence: the dated result at the top of `airgap.md`, updated when
the run repeats. `INVENTORY.md` row A7 records why the executed-docs harness
does not duplicate this run.

**`tockmox-site-template` re-pin.**
[`tockmox/tockmox-site-template`](https://github.com/tockmox/tockmox-site-template)
carries no tags and pins the release by hand: nine `targetRevision: vX.Y.Z`
lines in `bootstrap/applications/*.yaml` (the Tockmox source of each
two-source Application; the operator's own site source stays on `main`) and
one "Pinned to" line in its README. Re-pinning proves that an evaluator who
follows the template installs this release rather than the previous one.
Nothing in either repository's CI notices when this step is skipped *before*
the tag, which is why it is listed; since TM-0534 the tag push itself runs
`tools/site-pin-at-tag.sh` (workflow `release-tag.yaml`) and goes red if the
template's `main` does not pin that exact tag, rc or final. It is an alarm, not
a gate: the tag already exists when it fires, so the cure is to merge the
re-pin and re-run the job. Evidence: the template repository's own history, and
`grep -h 'targetRevision:' bootstrap/applications/*.yaml | sort | uniq -c`
reading nine lines on the new tag and **eleven** on `main`.

**The `main` count moved from ten to eleven at 0.6.1** (TM-0675 / TM-0698),
when the template gained the `site-secrets` Application that
`install/tockmox-install.sh` had been generating since 2026-09-12 and the
template had never carried. It is single-source against the operator's own
repository, so it adds a `main` line and no pin. The template's own
`check-pin-consistency.sh` is unaffected: it filters `main` out before counting,
which is why the pin count in the per-RC table above is still nine.

**SHA256SUMS.** The steps under "Checksums, from 0.6.0 onward" above. It
proves the promise [`docs/deployment/verify.md`](../deployment/verify.md)
makes: that a checksum exists and describes a deterministic archive rather
than a regenerated one. Evidence: the archive and `SHA256SUMS` present as
assets on the GitHub Release page, confirmed by viewing the page rather than
by the upload command exiting cleanly.

**Outside-eyes pass, minor releases only, advisory.** Once, against the last
release candidate's tag and not the final tag, an external model reads that tag
in a fresh conversation and evaluates it as five different prospective
adopters, one at a time, returning a decision for each. Running on the rc is the
point: the rc is what the final tag will be, so a finding can still land in the
release. It is a documentation-and-claims review, never a test: it does not block
a tag and does not substitute for any gate above. It proves whether the
published surface, read cold, supports the claims it makes. Evidence: a maintainer-held scoreboard outside this repository, one
row per release. Every flagged item is re-derived against the tree before it
becomes a tracked defect; on the first run a third of them were stale or
wrong.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

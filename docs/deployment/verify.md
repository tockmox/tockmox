---
okf_version: "0.2"
type: HowTo
title: "Verify what you downloaded"
description: "Check a Tockmox release before you render it: verify the signed tag, check the archive checksum, and read the deployment SBOM."
tags: [verification, signing, sbom, checksums, supply-chain, releases]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Verify what you downloaded

Tockmox distributes **source**: charts, an installer, documentation. There is no
binary artifact, so verifying a release means verifying the source you are about
to render and apply, which is both simpler and stronger than verifying a build
somebody claims came from it.

**Do the signed tag first.** It is the strongest check, it works offline, and it
is the one that covers every release. The other two answer different questions.

| Check | Answers | Required? |
|---|---|---|
| [1. Signed tag](#1-verify-the-signed-tag) | Did the maintainer publish this exact tree | **Required** |
| [2. Checksum](#2-check-the-archive-checksum) | Did this archive arrive intact | **Conditional**: only if you downloaded a release archive rather than cloning |
| [3. SBOM](#3-read-the-deployment-sbom) | What will this deployment pull | **Optional**: for review and policy, not for authenticity |
| [4. Gate report](#4-verify-the-gate-report) | What the maintainer ran against this tag, and what they did not | **Optional**: 0.6.0 and later |

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| `git` 2.34 or newer | SSH signature verification (`gpg.ssh.allowedSignersFile`) landed in 2.34 | `git --version` |
| A clone of the repository, or the release archive | Step 1 needs the git objects; step 2 needs the archive | `git -C <clone> rev-parse --is-inside-work-tree` prints `true` |
| `sha256sum` or `shasum` | Step 2 only | `command -v sha256sum \|\| command -v shasum` |
| `python3` | Step 3 only, to read the SBOM | `python3 --version` |
| `ssh-keygen` from OpenSSH 8.1 or newer | Step 4 only. `ssh-keygen -Y sign` / `-Y verify` appeared in 8.1 | `ssh -V` |
| **No network access at all** | Every check here is offline by design, which is the point for the air-gapped deployments this platform exists for | Nothing to check. This is a property, not a prerequisite |

**Estimate, not a measurement: under five minutes** for all four.

### Set these once

**Required before step 1.** Two values are used by more than one block below,
and step 1 needs both. They are exported once, here, rather than substituted by
hand at each call site, so that every block further down pastes exactly as
printed. This is the same pattern
[install § set these once](install.md#set-these-once) and
[day 2 operations](../operations/day-2.md#before-you-begin) use.

**YOU SUPPLY:** both of them.

| Variable | Where it comes from |
|---|---|
| `TOCKMOX` | The path to your clone of the Tockmox source tree. The same variable [install](install.md#set-these-once) uses, so it carries forward |
| `TAG` | The tag you intend to deploy. Released tags are listed at [github.com/tockmox/tockmox/releases](https://github.com/tockmox/tockmox/releases), and `git tag --list` shows the ones your clone already has |

```bash
export TOCKMOX=YOUR_TOCKMOX_CLONE_PATH
export TAG=YOUR_TAG

ls "$TOCKMOX/.gitsigners"
echo "verifying $TAG in $TOCKMOX"
```

**Success condition:** the allowed signers file exists in the clone you named,
and the tag echoed back is the one you meant. The two conditional blocks in
[step 2](#2-check-the-archive-checksum) export their own values instead, because
most readers skip that step entirely and a page-level export for a branch nobody
took is noise.

## What exists today, honestly

**Every tag is SSH-signed and verifies against the in-repo allowed-signers
file.** What carries an archive checksum is the part that changed:

| | |
|---|---|
| `v0.8.0` (the first public release) and later | `SHA256SUMS` on the release page, per [RELEASING.md](../../RELEASING.md) |
| pre-releases (`-rcN`) | whether a given one carries a checksum is a fact about that release, not about this page. Read its release page |

**Every release carries a gate report too**, signed with the same key as the
tag; pre-releases do not get one.

## 1. Verify the signed tag

**Required.** This is the check that establishes the tree is the maintainer's.

**YOU SUPPLY:** nothing new here. `TOCKMOX` and `TAG` are the two you exported
in [set these once](#set-these-once), and they are not re-typed at this call
site ... a tag typed a second time is a tag that can be typed differently, and
verifying the wrong one passes just as cleanly as verifying the right one.

The allowed signers file ships **in the repository** at
[`.gitsigners`](../../.gitsigners), and verification is entirely offline: no
external service, no transparency log to reach.

```bash
: "${TOCKMOX:?export TOCKMOX first, see Set these once}"
: "${TAG:?export TAG first, see Set these once}"
cd "$TOCKMOX"
git config gpg.ssh.allowedSignersFile .gitsigners
git verify-tag "$TAG"
```

**Success condition:** the command exits **zero**, and prints one line that names
the signer **by identity**:

```
Good "git" signature for jeff@maaks.com with ED25519 key SHA256:EWYdV82fKSzUvXc5RPMuUH35J/CiQmBm7egYCDEmGDY
```

**Read that line for `for jeff@maaks.com`, not for the word "Good".** This is the
trap on this page. When the allowed-signers file is missing, empty or wrong, git
still prints a line beginning `Good "git" signature` ... it just drops the
`for <identity>` and adds a second line:

```
Good "git" signature with ED25519 key SHA256:EWYdV82fKSzUvXc5RPMuUH35J/CiQmBm7egYCDEmGDY
No principal matched.
```

That is a **failure**. It exits 1, and it means git checked the signature's
internal consistency and could not tie the key to anybody. A reader skimming for
"Good" passes a check that did not pass. Verified on 2026-09-01 with git 2.34.1
against the 0.5.0 tag: exit 0 with a correct `.gitsigners`, exit 1 and
`No principal matched.` with a wrong one.

If you would rather not read output at all, let the exit code decide:

```bash
: "${TAG:?export TAG first, see Set these once}"
git verify-tag "$TAG" && echo VERIFIED || echo "NOT VERIFIED"
```

A tag carrying no signature at all reports `error: no signature found` and exits
1. That is a different problem and a worse one.

**Then compare that fingerprint against a second source.** A passing
`git verify-tag` proves the tag was signed by the key in `.gitsigners`. It does
not prove that key belongs to anyone in particular, and `.gitsigners` travels in
the same repository as the tag it vouches for. The same fingerprint is published
in [SECURITY.md](../../SECURITY.md); if the two ever disagree, stop.

## 2. Check the archive checksum

**Conditional: do this only if you downloaded a release archive.** If you cloned
and verified the tag, step 1 already covers the tree and this adds nothing.

Every release has a `SHA256SUMS` file attached by the release procedure,
covering the release archive, produced by the steps in
[RELEASING.md](../../RELEASING.md).

**YOU SUPPLY:** `ARCHIVE_DIR`, the directory holding both the archive you
downloaded and the `SHA256SUMS` file that came with it. It is exported here
rather than in [set these once](#set-these-once) because this whole step is
conditional and a reader who cloned never needs it.

```bash
export ARCHIVE_DIR=YOUR_ARCHIVE_DIR
cd "$ARCHIVE_DIR"
sha256sum -c SHA256SUMS
```

**Success condition:** every line ends in `OK`, and the command exits zero.
`sha256sum` prints `FAILED` loudly for a mismatch, but a file listed in
`SHA256SUMS` and absent from the directory is reported separately as
`No such file or directory` and is just as much a failure.

**One caveat, learned from other projects rather than repeated here:** GitHub's
auto-generated source tarballs are not guaranteed byte-stable across time. The
checksum published with a release is authoritative for the archive **attached to
that release**, not for a tarball regenerated later. When in doubt, clone at the
tag and compare trees. This is why the release procedure attaches a
`git archive` output rather than relying on the generated one.

## 3. Read the deployment SBOM

**Optional.** This answers "what will this pull", which is a review and policy
question, not an authenticity one. Nothing here proves the tree is genuine;
step 1 does that.

`sbom.cdx.json` at the repository root is a CycloneDX 1.5 inventory of what a
default install comprises: every container image a deployment pulls and every
upstream Helm chart each layer wraps, with pinned versions.

```bash
python3 -c "import json; b=json.load(open('sbom.cdx.json')); \
  print(len(b['components']), 'components for', \
  b['metadata']['component']['name'], b['metadata']['component']['version'])"
```

**Success condition:** a component count and a name and version that match the
tag you verified in step 1. Read on 2026-09-01 against the 0.6.0 tree this
prints `63 components for tockmox 0.6.0`. **The count moves every release; the
check is that the version matches your tag**, not that the number matches this
page.

**The SBOM is deliberately timestamp-free**, so a byte-identical tree produces a
byte-identical SBOM and its hash is meaningful.

**CI verifies it on every commit rather than regenerating it:** the pipeline runs
`tools/gen-sbom.sh` and then `git diff --exit-code -- sbom.cdx.json`, so a tree
whose charts moved without the SBOM moving fails the build. The committed file
is the artifact; CI's job is to refuse a stale one
([history](#history-two-sentences-that-rotted)).

**Scope, stated precisely:** this is the **aggregation-level** SBOM ... which
images, which charts, which versions. The package-level contents of each image
are the upstream projects' to attest, and several publish their own SBOMs;
restating them here would assert knowledge this repository does not have. The
human-readable companion, with licenses and their caveats, is
[third-party licenses](../third-party-licenses.md).

## 4. Verify the gate report

**Optional, and it answers a question the other three cannot: what the
maintainer actually ran against this tag, and what they did not.**

From **0.6.0 onward** the release page carries `GATE-REPORT-<tag>.md` and a
detached signature `GATE-REPORT-<tag>.md.sig`. The report names the cluster it
was measured on, every gate and acceptance row with its **observed value**, and
a section headed "WHAT WAS NOT TESTED" listing what the release does not claim.

**Do [step 1](#1-verify-the-signed-tag) first, and this is not a suggestion.**
The gate report verifies against the same `.gitsigners` in the same tree, so its
signature is only worth as much as your confidence in that file ... which is
exactly what the tag signature establishes. Verifying the report against an
unverified tree proves the two files agree with each other and nothing more.

**YOU SUPPLY:** `GATE_REPORT`, the path to the report you downloaded from the
release page. Its signature is expected beside it as `<report>.sig`, which is
how both files are attached. It is exported here rather than in
[set these once](#set-these-once) because this step is optional and most
readers stop after step 1.

```bash
: "${TOCKMOX:?export TOCKMOX first, see Set these once}"
export GATE_REPORT=YOUR_GATE_REPORT_PATH
cd "$TOCKMOX"
ssh-keygen -Y verify -f .gitsigners -I jeff@maaks.com -n file \
  -s "${GATE_REPORT}.sig" < "$GATE_REPORT"
```

**Success condition: the output contains the word `for` and an identity.**

```
Good "file" signature for jeff@maaks.com with ED25519 key SHA256:EWYdV82f...
```

**This is the same tell as step 1, and the trap is worth naming because it is a
different command.** `ssh-keygen -Y verify` is strict ... a missing allowed
signers file, a key that is not in it, or an identity that does not match all
exit non-zero and print `Could not verify signature`. Measured, all three.
**What does not is `ssh-keygen -Y check-novalidate`**, which validates the
signature's *shape* against no trust root at all, exits zero, and prints

```
Good "file" signature with ED25519 key SHA256:...
```

`with`, not `for`, and no identity. **That line means a signature by somebody.**
If you reach for `check-novalidate` because `verify` is failing, you have
replaced the check with a weaker one rather than fixing it.

**The namespace has to be `file`.** Signatures carry the namespace they were
made under, and the tag's is `git`. Passing `-n git` here fails with `namespace
does not match`, which is the mechanism working: a namespace exists precisely so
a signature over one kind of thing cannot be replayed as another.

**What this proves, and what it does not.** It proves the maintainer signed
**that report**, with the same key that signs the tags, and that its bytes have
not changed. **It does not prove the gate passed** ... the report is a claim
about a run, signed by the person who ran it, and a signature never makes a
claim true. Its value is that the claim is attributable and tamper-evident, and
that its "what was not tested" section is signed too, so the limits travel with
the results.

**Pre-releases carry no gate report.**

## Why this and not cosign or sigstore

Nothing here precludes them. Sigstore's strengths are keyless signing for
**built** artifacts and transparency logs; a source-only project's verifiable
object is the git tree, and git's own SSH signing verifies it offline with no
external service, which matters for the air-gapped deployments this platform
exists for.

If Tockmox ever ships a built artifact ... an installer image, a bundle ... it
gets cosign treatment and this page gets a section.

## History and corrections

What this page used to say, and when it changed. Nothing here is needed to follow the page.

<a id="history-two-sentences-that-rotted"></a>

### Two sentences that rotted

The tag section used to COUNT the tags, and the count rotted twice: it said
"one tag cut" until 2026-09-01, when there were two; it then said "two" and
listed `v0.6.0-rc1`, while `v0.6.0-rc2` had been cut on 2026-09-09 and a third
followed. Corrected 2026-09-12 by removing the count rather than updating it,
because a sentence that states how many tags exist is wrong again at the next
tag and nothing regenerates it. The SBOM paragraph said CI regenerates the
file rather than verifying it until 2026-08-19, which would have mattered to
anyone who assumed a regenerated file needed no review.

## What is not certified here

Every claim on this page about the repository was read or executed against the
0.6.0 tree on 2026-09-01: the two tags and their dates, both signatures against
`.gitsigners`, the fingerprint matching SECURITY.md, the SBOM's spec version and
component count, and the CI step that refuses a stale SBOM.

**Two things on this page were not verified and cannot be from here.** What a
given GitHub release actually has attached to it is a fact about that release
page, not about this tree. And a passing signature proves who signed, never that
the signed content is free of defects.

Whether the deployment these artifacts describe installs correctly is a separate
question entirely; see the [testing standard](../testing-standard.md).

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

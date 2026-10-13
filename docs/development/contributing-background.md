---
okf_version: "0.2"
type: Reference
title: "Contributing background"
description: "The reasoning and history behind CONTRIBUTING.md's gate, shell, style and DCO rules, kept out of the contributor checklist."
tags: [contributing, style, dco, rationale]
status: stable
generated:
  by: hand
  at: 2026-10-03
tockmox:
  classification: public
  audience: [contributor, machine]
---

# Contributing background

The reasoning behind [CONTRIBUTING.md](../../CONTRIBUTING.md), moved here so that file stays short. Where the two differ, CONTRIBUTING.md is authoritative.

## Practical requirements

It runs every gate that does not need a live cluster, names each one as it goes,
and tells you plainly which it skipped and why. It needs `helm`, `python3` and
`jq`, and it refuses to start if any of those is missing rather than running
a partial suite ... several gates cannot tell "the tree is wrong" from "the tool
is absent", and they report the first when they mean the second. One of them
emitted eleven confident, specific, entirely fictional findings that way.

## Shell requirement

**Some gates need bash 4.0+. macOS ships bash 3.2.57 as `/bin/bash`.**

`tools/check-capabilities.sh` and `tools/check-trust-wiring.sh` use associative
arrays (`declare -A`, bash 4.0+). On bash 3.2 they now **refuse with exit 2 and
a message naming the version they found**. That guard is not cosmetic: before it
existed, `check-trust-wiring.sh` printed an `unbound variable` error, skipped
every check, and **exited 0** on a stock Mac — reporting green while examining
nothing, which is the exact failure these gates exist to catch.

## Linting by hand

**The `-f ci/values.yaml` is required, not optional.** A bare `helm lint` fails
every chart on `global.internalDomain` being empty ... that is the schema doing
its job and it tells you nothing about your change. The second pass with the
all-on overlay renders the paths the defaults never touch (backups, hardware
telemetry, the consoles' ingresses); a lint-breaking defect once shipped
invisibly because nothing rendered them.

Two rules this project keeps re-learning, now part of the release gate:

1. **Validate from a clean clone with an empty Helm cache.** Cached repos,
   pre-registered repositories, vendored tarballs and existing namespaces all
   make a broken change pass locally. Nothing but a clean clone proves
   anything about a new user.
2. **Re-run validation after your last edit, not before it.** Validating and
   then "just" changing one more thing is how a green local run becomes a red
   CI run. Also note `helm template` normalises output that `helm lint`
   rejects, so lint is the one that has to pass.

## Documentation style

Two of the three style rules are mechanical and enforced in CI by
`./tools/check-docs-style.sh` (emoji, and voice); the third (punctuation) is
deliberately not. Run the check before you push; it takes under a second and
tells you the line. These are narrower than the standard and do not replace it.

The reason is mechanical rather than aesthetic. An emoji's accessible name
describes how it looks, not what it means, and a repository README has no way
to override that. A screen reader announces "white heavy check mark" where you
meant "supported", and "link" where you meant "release notes for v1.12.0".
GitHub's own documentation style guide bans emoji in tables for this reason and
requires a symbol's accessible name to state its meaning.

So the check refuses an emoji in a heading, in a table row, inside link text,
or alone on a line. It accepts one as a Mermaid node icon next to a text label,
as decoration on a line that already has words, and anywhere inside a fenced
code block, because a transcript of another program's output is quoted rather
than written.

**Punctuation is a review comment, not a build failure.** Em-dashes are fine
here ... use them where they read well and don't lean on them. They were gated
until 2026-08-18 and no longer are, on the reasoning that failing a pull
request over a dash teaches contributors to resent the same check that catches
the accessibility problem.

That isn't ceremony. The project has to stand on its own without the founder's
personality welded into its claims, so any personal writing is attributed,
excisable, and asserts nothing ... delete either block and every claim,
instruction and promise in the repo still holds. Unmarked first-person prose
drifting into the reference docs is the failure this prevents, and it happens
one reasonable exception at a time. If you think a third belongs somewhere,
open an issue rather than a pull request; it's a brand decision, not an
editorial one.

## Sign your commits (DCO)

**What signing off means.** It is a statement about provenance, not a
formality. By signing off you certify the four clauses in the DCO: that you
wrote the change, or that it derives from work you have the right to submit
under a compatible open source license, or that someone who could certify that
handed it to you; and that you understand the contribution and the sign-off,
including the name and email address in it, become a permanent public record.

**Where this fails, and why the name will mislead you.** The DCO check runs in
the CI job named **`ci / secrets`**. That job does two unrelated things ...
gitleaks, and this check ... because it is the only one that checks out with
`fetch-depth: 0`, and verifying sign-offs needs history. So **a red
`ci / secrets` is more often a missing sign-off than a leaked credential**, and
looking for a leak first is the wrong instinct. Open the job log and read which
step failed before assuming anything.

This is written down because it cost a full pull-request cycle once, to someone
who knew the repository well.

**Why a DCO and not a CLA.** A DCO is a lightweight per-commit assertion of
provenance: you keep your copyright, and the license under which the work
enters the project is the license already in the repository. A CLA is a signed
grant of rights to the project owner, and its practical effect is to allow
relicensing later. That is a business decision this project has not made, so
asking contributors to enable it in advance would be asking for more than the
project needs.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

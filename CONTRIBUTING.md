<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Contributing

One maintainer. Read [SUPPORT.md](SUPPORT.md) for what to expect in return and
[GOVERNANCE.md](GOVERNANCE.md) for who decides.

## What this project wants right now

The project is early and the design is still moving. **A well-argued issue is
worth more right now than a pull request, and is far more likely to change the
software.** A patch has to fit the design, and the design is argued in public:
the principles below, [GOVERNANCE.md](GOVERNANCE.md), and the issues and
discussions where earlier decisions were made. If the constraint that stops your
patch is not written down in one of those, that is a documentation gap worth
raising, and the maintainer states the decision and the reason in the thread. An
issue or a discussion says what you needed and why, which a diff cannot.

**Send a pull request without asking for:**

- Typos, broken links and documentation corrections. Merged fast.
- A small bug fix where the bug is obvious and the fix is contained.

**Open an issue first for anything else** ... new capabilities, structural
changes, dependency swaps, anything touching the values interface. If we agree
on the approach, a pull request is welcome. For a design question, or a change
too large to review as a diff, open a
[discussion](https://github.com/tockmox/tockmox/discussions) titled as a
proposal, as [GOVERNANCE.md](GOVERNANCE.md#proposing-something-larger-than-a-pull-request)
sets out. An issue works too if you prefer one.

**The most valuable report:**

> "I had to patch or fork something because Tockmox would not let me configure
> it."

That is a values-interface gap, a bug in the project. Exposing the value is
usually small and it removes your upgrade burden. These get priority over
features.

## The contribution I cannot produce myself

There is one reference deployment, on one person's hardware. If you swap a
component (ingress controller, storage layer, identity provider, a model host I
have never run), tell me what it took: what you changed, what fought you, what
the values interface would not let you express. If you run it on hardware I do
not have (a different mini PC, a hypervisor, arm64), tell me whether it worked;
a failure is more useful than a success.

Send it as an issue, a discussion or a docs pull request. Prose is fine. Reports
like this are how [hardware platforms](docs/deployment/hardware-platforms.md)
and the customising ladder grow past one setup.

## Principles that govern review

- **A value exists only if the operator must supply it.** If the project can
  pick a sane default, it does. The configuration surface is a cost.
- **Nothing is asserted that is not tested.** "Backups work" is not a claim; "a
  restore drill ran on Tuesday and verified" is.
- **Absence renders not-green.** A check that stops running must not read as
  healthy. Staleness is a failure.
- **Deterministic first.** Routine operation never invokes a model.
- **No site-specific content.** No hostnames, IPs, node names or references to
  any deployment. If a value differs between installations, it is a value.
  `tools/check-no-site-specifics.sh` catches the generic shapes; a maintainer's
  own identifiers live in a private rules file (`TOCKMOX_SITE_PATTERNS_FILE`),
  never in the tree.

## Practical requirements

Every pull request must pass CI, which runs 40 gates. Run them yourself first:

```bash
./tools/check-all.sh
```

It runs every gate that does not need a live cluster, names each as it goes
and says which it skipped and why. It needs `helm` (v4.3.1, see below), `python3` with the PyYAML
module (`python3 -m pip install pyyaml`, or your package manager's
`python3-yaml`), and `jq`, and refuses to start if one is missing, because several gates cannot tell "the tree
is wrong" from "the tool is absent".

CI also runs, and `check-all.sh` names as skipped:

- `gitleaks` across the full history (needs a full clone and the binary)
- `kubeconform` over the rendered output (needs the binary)
- the DCO sign-off check, per commit against what your branch adds
- the release-time render diff between the previous tag and the candidate

**What none of these prove.** The gates are static analysis plus hermetic
tests that execute code against fakes (the installer's suite, the UI's unit
tests): whether the tree is internally consistent and the programs behave in
isolation, never whether the documented instructions work when run on a
cluster. The [testing standard](docs/testing-standard.md) sets out the boundary,
the rule that every documented path is executed or excepted in writing, and the
harness that executes them.

### Toolchain, and the smallest check for a documentation-only change

**Use Helm v4.3.1.** That is the version CI pins (`HELM_VERSION` in
`.github/workflows/ci.yaml`, repeated in `portability-macos.yaml` and
`policy-gate.yaml`), so it is the one a green run on your machine predicts.
Helm 3 and Helm 4 have disagreed on a render before (a parent's `null` does not
delete a subchart default under Helm 4), and this project has not verified its
checks on Helm 3. Some pages under `docs/` quote measurements taken with Helm
v3.16; those are dated records, not the toolchain to install.

If your change touches only Markdown (a page under `docs/` or a root file), you
do not need a cluster, Helm or chart dependencies for the checks that read
prose. These need bash and `python3`:

```bash
./tools/check-docs-style.sh
./tools/check-docs-links.sh
./tools/check-frontmatter.sh
./tools/check-pasteable-blocks.sh
```

Run them after your last edit. They are the same scripts CI runs in the steps
named "docs links resolve", "frontmatter contract holds over the docs bundle",
"documented commands paste as-is" and "documentation style (no meaning-carrying
emoji)". A fifth,
`./tools/check-doc-claims.sh`, checks the counts a page states against the tree
and needs a Helm render first: run `./tools/helm-deps.sh` and
`./tools/render-counts.sh`, which need Helm v4.3.1 and network access to the
chart repositories. Without them it says it ran partially and exits non-zero.
If you cannot run it, say so in the pull request and the maintainer will.
Anything else you change, such as a chart, a value or a script, belongs under
`./tools/check-all.sh`.

### What a fork cannot do, and who supplies the live evidence

CI runs on your pull request without secrets and never on the maintainer's
self-hosted runner, because that runner must not execute fork code. Three
consequences:

- **The workflows the maintainer dispatches are not yours to dispatch.**
  `workflow_dispatch` on the maintainer's workflows (`executed-docs.yaml`,
  `portability-macos.yaml`, `release-tag.yaml`) needs write access to this
  repository. `gh workflow run` run from a fork targets your fork's copy of a
  workflow, with Actions enabled there; it does not run the maintainer's.
- **Repository secrets do not reach a fork's pull request.** The one visible
  effect is `tools/check-no-site-specifics.sh`, which runs its generic rules
  for you and the maintainer's private rules on the maintainer's own runs.
- **The self-hosted runner is not available.** The documented-procedure paths in
  `tests/executed-docs/`, and the clean-cluster install the release gate
  requires, run on a labelled self-hosted runner against a live cluster, on a
  schedule and on pushes to `main` and `release-*` branches.

What you owe is the evidence you can produce: the commands you ran and what
they printed, in the pull request's Evidence section, or a plain statement that
you did not run something. What the maintainer supplies after review is the
rest: the `executed-docs` run against a live cluster for a change to a
documented procedure, `portability-macos` when a gate's shell changed, and the
release-time gates. If your change needs one of those, the pull request says
which, and a pull request is not held for a run you had no way to start.

### `TM-` and `HL-` identifiers

`TM-` ids appear in comments, commit messages and `tests/executed-docs/`, never
in CHANGELOG.md; `HL-` ids appear nowhere. Both are the maintainer's internal
trackers and do not resolve publicly. Every reference
is written so the surrounding sentence stands without it; one that does not is a
documentation defect worth an issue.

### Shell requirement

**Some gates need bash 4.0+.** macOS ships bash 3.2.57 as `/bin/bash`.
`tools/check-capabilities.sh` and `tools/check-trust-wiring.sh` use associative
arrays (`declare -A`) and refuse with exit 2, naming the version found, on bash
3.2. Everything else in `tools/`, including `helm-deps.sh`, runs under 3.2. On
macOS:

```bash
brew install bash
/opt/homebrew/bin/bash tools/check-capabilities.sh
```

Which runs where: `check-all.yaml` runs `check-all.sh` on Linux (bash 5, GNU
userland) on every pull request and every push to `main` and `release-*`, so
every gate in it is checked per pull request, including the ones `ci.yaml` has
no step for. `portability-macos.yaml` runs the same script on a macOS runner
(Homebrew bash, BSD `sed`, `grep` and `wc`) weekly and on demand, not on pull
requests. A gate that passes only with GNU
tools fails there within a week. If you change a gate's shell, run `check-all.sh`
on a Mac, or say so in the pull request and the maintainer will run
`portability-macos.yaml` for you: a fork cannot dispatch that workflow here
([what a fork cannot do](#what-a-fork-cannot-do-and-who-supplies-the-live-evidence)).

`./tools/check-all.sh` runs the gates in parallel, as many at once as you have CPUs; set
`CHECK_ALL_JOBS=1` to run them one at a time with live output when you are chasing one.

`./tools/check-all.sh` handles the dependency step and both lint passes. By
hand:

```bash
# once per clone
./tools/helm-deps.sh

for c in charts/tockmox-*; do
  [ "$c" = "charts/tockmox-common" ] && continue
  helm lint "$c" -f ci/values.yaml
  helm lint "$c" -f ci/values.yaml -f ci/values-all-on.yaml
done
```

**`-f ci/values.yaml` is required.** A bare `helm lint` fails every chart on
`global.internalDomain` being empty, which says nothing about your change. The
all-on overlay renders the paths the defaults never touch (backups, hardware
telemetry, the consoles' ingresses).

1. **Validate from a clean clone with an empty Helm cache.** Cached repos,
   vendored tarballs and existing namespaces make a broken change pass locally.
2. **Re-run validation after your last edit, not before it.** `helm template`
   normalises output that `helm lint` rejects, so lint is the one that has to
   pass.

## Adding a value

1. Add it to the chart's `values.yaml` **with a comment explaining what breaks
   if it is wrong**, not just what it is.
2. Add it to `values.schema.json`. Required only if there is no safe default.
3. Document it in `docs/administration/configuration.md`.
4. Use it in a template. A value nothing reads is worse than no value.

## Adding a chart template

- Include `{{- include "tockmox.labels" . | nindent 4 }}` in every resource's
  labels. Users need to tell ours from theirs.
- Gate it on `.Values.apps.<name>.enabled`. Everything is disableable.
- Escape Prometheus templating: `{{ "{{ $labels.x }}" }}`. Helm otherwise tries
  to evaluate `$labels` and fails the render.
- Namespaces come from `.Values.namespaces.*`, never hardcoded.

## Documentation style

Structure and procedure rules are in the
[documentation standard](docs/documentation-standard.md). Read it before
writing or restructuring a page under `docs/`. Pages under `docs/` also carry
OKF frontmatter, checked by `./tools/check-frontmatter.sh`
([the contract](docs/frontmatter-contract.md)).

`./tools/check-docs-style.sh` enforces two rules in CI (emoji, and voice); run
it before you push. Punctuation is a review comment, not a gate. These are
narrower than the standard and do not replace it.

**No emoji that carries meaning.** Deleting it must change nothing. A screen
reader announces an emoji's appearance, not its meaning. The check refuses an
emoji in a heading, a table row, link text, or alone on a line, and accepts one
as a Mermaid node icon beside a text label, as decoration on a line with words,
and inside any fenced block.

```markdown
Refused:  | 1.12 | ✅ |              the glyph is the whole cell
Refused:  See [🔗](...) for notes.   the glyph is the whole link
Accepted: | 1.12 | Supported |
Accepted: A["🧠 Inference host"]     in a mermaid fence, next to a label
```

**Punctuation is a review comment.** Em-dashes are fine; do not lean on them.
They were gated until 2026-08-18.

**One voice, with two marked exceptions.** The docs speak as the project. Two
places carry the maintainer's first-person register, under the exact heading
`A note from Jeff Maaks, maintainer`, and there is never a third. The check
enforces the heading, the two permitted files and the cap, and refuses first
person ("I", "me", "my") in running prose anywhere else (since 2026-09-04). The
reader's voice is fine: a question, a symptom heading, a quoted report. If the
check flags a sentence that is the reader speaking, quote it. This file is the
one page outside the rule. A third exception is a brand decision; open an issue.

If the check blocks something it should not, say so in the issue rather than
working around it. The reasoning behind each rule is in
[contributing background](docs/development/contributing-background.md).

## Commit messages

Conventional-ish, no strict enforcement. Explain **why** in the body; the diff
shows what.

```
fix(policy): create every namespace the layer references

Greenfield sync failed with "namespaces tockmox-monitoring not found".
CreateNamespace=true only creates the destination namespace.
```

## Licensing

Code is Apache-2.0, documentation CC BY 4.0. Source files carry an SPDX
identifier.

## Sign your commits (DCO)

This project uses the [Developer Certificate of Origin](https://developercertificate.org/)
version 1.1 (full text: [DCO](DCO)). Every commit must carry a `Signed-off-by`
line. Signing off certifies the four DCO clauses: you wrote the change, or it
derives from work you may submit under a compatible open source license, or
someone who could certify that handed it to you; and the contribution and the
sign-off, including your name and email, become a permanent public record.

Renovate's dependency PRs are the one exception: a bot cannot certify the DCO,
so CI skips the check for commits Renovate authors in a PR Renovate opened, and
for the one commit `renovate-regen.yaml` adds there holding the regenerated
`images.txt` and `sbom.cdx.json` (that commit may touch nothing else). A
commit you add to a Renovate branch still needs your sign-off.

```bash
git commit -s -m "fix(policy): create every namespace the layer references"
```

That appends one line from your `user.name` and `user.email`:

```
Signed-off-by: Jane Developer <jane@example.com>
```

Use a real name and a reachable address. Forgot on the last commit:
`git commit --amend -s`. For a branch: `git rebase --signoff main` and
force-push. A missing sign-off is the one review comment that is not a
judgment call.

**A red `ci / secrets` is more often a missing sign-off than a leaked
credential.** The DCO check runs in that job, with gitleaks, because it is the
only job that checks out with `fetch-depth: 0`. Read which step failed before
assuming anything.

A DCO and not a CLA: you keep your copyright and the repository's license
applies. A CLA grants rights to the project owner, which allows relicensing; this
project has not made that decision and does not ask for more than it needs.

## Code of conduct

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies. Reports go to
**conduct@tockmox.com**.

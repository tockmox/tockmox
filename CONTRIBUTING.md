<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Contributing

One maintainer. Read [SUPPORT.md](SUPPORT.md) for what to expect in return and
[GOVERNANCE.md](GOVERNANCE.md) for who decides.

## What this project wants right now

The project is early and the design is still moving. **A well-argued issue is
worth more right now than a pull request, and is far more likely to change the
software.** A patch has to fit a design only the maintainer can see; an issue
says what you needed and why, which a diff cannot.

**Send a pull request without asking for:**

- Typos, broken links and documentation corrections. Merged fast.
- A small bug fix where the bug is obvious and the fix is contained.

**Open an issue first for anything else** ... new capabilities, structural
changes, dependency swaps, anything touching the values interface. If we agree
on the approach, a pull request is welcome.

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
and says which it skipped and why. It needs `helm`, `python3` with the PyYAML
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

CI runs the gates on Linux with bash 5, and `portability-macos.yaml` runs
`check-all.sh` on a macOS runner (Homebrew bash, BSD `sed`, `grep` and `wc`)
weekly and on demand, not on pull requests. A gate that passes only with GNU
tools fails there within a week; if you change a gate's shell, trigger it by
hand (`gh workflow run portability-macos.yaml`) or run `check-all.sh` on a Mac.

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
so CI skips the check for commits Renovate authors in a PR Renovate opened. A
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

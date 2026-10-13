---
okf_version: "0.2"
type: Reference
title: "Testing standard"
description: "What Tockmox's automated checks must prove, the difference between checking the tree and executing the instructions, and the rule that every documented path is exercised or excepted in writing."
tags: [testing, standard, ci, quality, coverage, verification]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [contributor, machine]
---

# Testing standard

**A gate proves one thing. The useful question is always what it does not
prove.**

This project runs 39 CI gates. Thirty-eight are static analysis of the repository:
lint, render, schema, selector matching, link resolution, frontmatter, SBOM,
secret scanning, sign-off, alert-rule tests, the Tockmox UI's unit tests with every
upstream mocked, a render diff against the previous release. They are good gates and they are not enough, because
none of them executes a documented procedure against a running cluster.

**Do not number the gates in prose.** An ordinal here is a claim about a
position in `ci.yaml` that moves whenever a step is inserted anywhere above it,
and `doc-claims.txt` cannot pin it because it is a spelled-out word rather than
a digit. This paragraph said "the thirty-second" while the step was the
twenty-second, and had been wrong for some time before anyone noticed
(2026-09-12). Name the gate instead.

The installer gate, added 2026-09-10, is the first that runs a Tockmox program
rather than reading the tree: `tests/installer` drives
`install/tockmox-install.sh` through both of its routes and asserts on the site
repository it produces. It is hermetic ... it stubs `git` and `kubectl` and
reaches no cluster ... so it closes a narrower gap than the harness below. It is
mentioned here because it is the counterexample to the sentence above, and a
paragraph about what every gate does must not quietly acquire an exception.

That gap is not theoretical. In one evening of following
`docs/deployment/prerequisites.md` by hand, two defects surfaced that no
existing gate could catch: the documented ArgoCD install command **cannot
succeed** on any cluster, and a dated claim about StorageClass defaults
surviving a restart is **false**. The repository was internally consistent about
both.

## The governing rule

> **Automated tests exercise every path a reader is told to take. Exceptions are
> written down with a reason.**

Two halves, and the second is what makes the first honest. An untested path that
is *recorded* as untested is a known risk. An untested path that is simply
absent from the inventory is invisible, and invisible is how both defects above
survived.

## What "path" means, and what it does not

**A path is a procedure the documentation instructs a reader to execute.**

**A path is not a configuration combination.** Eight tri-state capabilities is
6561 renders before profiles enter the picture. Combinatorial coverage is not
achievable, and claiming it makes the rule unenforceable, which is worse than
not having one.

Where the docs offer alternatives as **equal options, each is a path.** This is
not pedantry: the ArgoCD defect existed precisely because the Helm route was
exercised by use while the raw-manifest route beside it was never run. The
untested one is the one a stranger picks, because it is listed first.

## Two kinds of check, and the boundary between them

| | **Static check** | **Executed check** |
|---|---|---|
| Asks | Is the tree internally consistent? | Do the instructions work? |
| Operates on | Files in the repository | A running system |
| Runs | Per-commit, hermetic, fast | On its own cadence, against a real cluster |
| Can prove | This chart renders; this link resolves; this schema rejects bad input | This command succeeds; this claim about runtime behaviour holds |
| Cannot prove | That any of it works | Nothing about files it did not touch |

**Static analysis of an artefact never validates a procedure against it.** A
repository can be flawlessly consistent about a command that exceeds a
Kubernetes annotation size limit and cannot run anywhere.

Both kinds are required. The failure mode is believing the first kind covers the
second because there is a lot of it.

## Rules

### 1. Assert on the artefact, not the exit code

A step that exits zero having examined nothing is worse than a failing step: it
converts an absence of testing into a claim of coverage. This project has
shipped exactly that ... a gate that used bash 4 syntax, hit an unbound variable
on macOS bash 3.2, skipped every check and exited 0. It now refuses with exit 2
and names the version it found.

Every assertion names the artefact it reads and the value it expects.

The executed-documentation harness applies this rule to its own results. A
path's outcome is one of `PASS`, `PRODUCT_FAIL`, `BLOCKED`, `INFRA_ERROR`,
`SKIPPED` or `ABORTED`; the documented command's exit code is recorded as
evidence and does not decide the outcome; and `PASS` cannot be declared unless
the execute phase completed. The section "What an outcome means" in
`tests/executed-docs/README.md` defines each outcome.

### 2. Coverage is measured against documented claims

Not against lines, not against gate count. The unit is **a thing we told someone
is true**. Counting gates measures effort; counting unasserted claims measures
risk.

The characteristic deliverable is therefore not a test suite but an
**inventory**: every documented path, mapped to the evidence for it or to a
written exception.

### 3. Exceptions are written, with a reason

An exception states what is not tested, why not, and what would change that.
"Requires x86 hardware we do not have in CI" is a reason. "Hard" is not.

### 4. State what each gate does not prove

Alongside what it checks. A reader of the CI configuration should be able to
tell, without running anything, which claims in the docs have no gate behind
them.

### 5. Environment parity travels with the claim

A pass on a different architecture, OS family or version than the target is
evidence **with a caveat attached**, and the caveat is part of the result.

Concretely: the static gates run hermetically in a sandbox on arm64. The
reference deployment is x86 on openSUSE MicroOS. An immutable OS differs from a
conventional one in ways that have already bitten ... a package install only
takes effect after a reboot, so the k3s installer enables the service and does
not start it. A green arm64 run says nothing about that.

### 6. Test sizes decide cadence, and cadence is stated

What matters is hermeticity and runtime, not a pyramid shape.

- **Hermetic and fast** ... per-commit. No network, no cluster, no shared state.
- **Needs a real cluster** ... its own cadence, nightly or pre-release, on its
  own runner. **Say which.** A check that is expensive and therefore quietly
  never runs is worse than one that does not exist, because it appears in the
  inventory.

### 7. A flaky gate is worse than a missing one

It trains everyone to disbelieve red, which disables every other gate at the
same time. A gate that cannot be made reliable is removed and recorded as an
exception, not left to erode trust in the suite.

### 8. Validation means someone performs the task

Reading a procedure is not validating it (ISO/IEC/IEEE 82079-1). Where "someone"
is automation, it must execute the documented commands **verbatim** ... not a
tidied equivalent that happens to work. A harness that quietly fixes the command
is testing the harness.

### 9. A gate does not count as coverage until it has been shown to fail

A gate observed only ever passing has not demonstrated that it evaluates
anything: "green" and "not evaluating" look identical from outside the gate.
A gate earns its place in the inventory once someone has made it go red on
purpose ... mutate the input it protects, or inject the condition it claims
to catch ... and watched it fail, or exit with a distinct code for
"cannot run" rather than a silent pass. **Record the date that demonstration
happened.** A gate with no recorded red is listed as unproven, next to the
gates it sits beside in the inventory, not trusted alongside them by default.

This project has produced a check that cannot go red often enough that the
failure has a small, recognisable shape, worth naming so the next one is
caught before it ships rather than after:

- **A skipped job reads as success.** A step conditioned out, or never
  registered with the runner, reports nothing rather than failing, and
  "nothing ran" renders exactly as green as "ran and passed".
- **A swallowed failure (`|| true` or the like) absorbs the one failure it was
  written to tolerate, and every other failure the same command could ever
  produce along with it.**
- **An exit code stands in for an outcome nobody inspected.** A script that
  exits zero having examined none of its intended targets is indistinguishable,
  from the runner's side, from one that examined all of them and found nothing
  wrong.
- **An assertion is satisfied by an artefact a previous, unrelated path left
  behind**, so the check reads a real file and still proves nothing about the
  path that was supposed to produce it this run.
- **A regex is written before the pattern it is meant to catch exists**, and
  never gains a case that would make it match, so every run is a true negative
  against a rule nothing has yet tried to violate.

The demonstration this rule asks for is exactly what a `--selftest` mode gives
a gate in this repository, and exactly why CI runs the selftest before
trusting the gate it guards: proving the gate still refuses is what makes "it
found nothing" mean something. A gate is not exempt from this rule for being
new; it is unproven until its red run is recorded.

## The executed-documentation harness

The shape this project uses:

1. **Stand up a throwaway single-node cluster.** Ephemeral, created per run,
   destroyed after. State that leaks between runs makes results unrepeatable.
2. **Run the documented commands verbatim**, taken from the published page.
3. **Assert on artefacts** ... the CRD is established, the Service has an
   external IP, exactly one StorageClass is default.
4. **Assert the claims, not only the commands.** Where a page says a change
   survives a restart, the harness restarts and re-checks. That single assertion
   would have caught one of the two defects above.
5. **Destroy the cluster.**

A path is covered when this harness executes it and asserts on its stated
success conditions ... the ones the
[documentation standard](documentation-standard.md) requires every step to
carry. The two standards meet exactly there: **a procedure with no stated
success condition cannot be tested**, so an untestable page is a documentation
defect before it is a testing gap.

## What this standard does not cover

- **Security review and threat modelling** ... a different discipline, owned
  separately.
- **The release decision** ... this standard produces evidence; it does not
  decide what ships.
- **The words of any procedure** ... when execution finds a defect, the fix is a
  documentation change, made by whoever owns the page.

## Grounding

ISO/IEC/IEEE 82079-1:2019, validation clause. Informative: *Software Engineering
at Google* on test sizes, hermeticity and the cost of flakiness; Humble and
Farley, *Continuous Delivery*; Forsgren, Humble and Kim, *Accelerate*; Morris,
*Infrastructure as Code*, on ephemeral test environments; the OpenSSF Scorecard
CI-Tests check.

**No normative software-testing standard is claimed.** ISO/IEC/IEEE 29119 is the
obvious candidate and is deliberately not cited: it is contested within the
practice it standardises, and claiming adherence to a standard this project does
not follow in detail would be exactly the unbacked claim this document exists to
prevent.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

# The installer's own test tier

Three questions, three places. This is the third.

| Question | Where it is answered |
|---|---|
| Is the tree internally consistent? | `ci.yaml`, static analysis |
| Do the instructions work? | [`tests/executed-docs`](../executed-docs/README.md), against a live cluster |
| **Does the installer, as a program, behave?** | **here** |

Hermetic. No network, no cluster, no shared state, about two seconds. Per-commit
cadence, per [testing-standard](../../docs/testing-standard.md) rule 6.

## Running it

```bash
bash tests/installer/run.sh

# keep the work directory to inspect the generated site repositories
TOCKMOX_KEEP_WORK=1 bash tests/installer/run.sh
```

## Why it exists

Two defects, both found on 2026-09-10, both in
`install/tockmox-install.sh`, and neither reachable by any static gate.

**The interactive path could not complete.** A variable used as the storage-class
prompt's default was assigned *below* the prompt that read it. Under
`set -u` that is fatal, so a default run took eleven answers and then died on the
twelfth question with `DEF_SC: unbound variable`, having written nothing.
`README.md`'s quickstart
lists the interactive route **first**, so the first command the project
advertises was the broken one. It survived because the interactive path had
never been run by anything: every proof run this project has ever made used
`--config`.

That is the shape testing-standard warns about in as many words ... *where
alternatives are offered as equals, both are paths, and the untested one is the
one a stranger picks, because it is listed first.* The rule was written down and
the case it describes was live in the tree.

**`--no-cluster` did not skip the cluster preflight.** It set a message string,
and the checks were skipped only when `kubectl` was *missing* or the cluster
*unreachable*. So on a workstation whose kubeconfig pointed at any reachable
cluster, `--no-cluster` ran every check anyway and died on `namespace argocd not
found`. A merged kubeconfig usually has a current context and it is usually not
the cluster you are about to build, so this is the common case. The flag
contradicted its own `--help` and the paragraph of comment directly above it.

## What it asserts, and what it refuses to

Assertions use the executed-docs vocabulary ... `ARTEFACT`, `READ`, `EXPECTED`,
`ACTUAL`, `RESULT` ... sourced from
[`../executed-docs/lib/assert.sh`](../executed-docs/lib/assert.sh). One
assertion vocabulary across the project beats a second one tuned to this tier,
and it carries the rule that matters for free: there is no `assert_succeeds`,
and a run that asserts nothing is a failure rather than a pass.

| Group | What it holds |
|---|---|
| `I1` | A default interactive run, driven under a pty, writes a complete site repository naming the values that were typed ... and the derived storage-class default resolves rather than exploding. |
| `I2` | Interactive and `--config` are offered as equal routes, so the same answers must produce a **byte-identical** site repository. |
| `I3` | `--no-cluster` does not consult a cluster, including one that answers. |
| `I4` | Refusals name the setting and the value. The unreachable-cluster refusal names `--no-cluster`, so the escape is discoverable from the failure. |
| `I5` | A second run over the same output changes nothing. `TM-0277`'s definition of done already assumed this; nothing tested it. |
| `B1` to `B12` | `bootstrap-secrets` (TM-0277), in `bootstrap-secrets-tests.sh`, against shims in `lib/shims/` (`kubectl`, `helm`, `kubeseal`, `age`, `docker`, `openssl`). First run, second run rewrites no sealed file, half-pair refusal, failure mid-run leaves no plaintext or partial files, wrong context/server/adopted controller refused, adoption creates no key, `recover` restores before install, backup encryption, and the interactive prompts under a pty. Never a real cluster; the live greenfield run has not happened. |

It deliberately does **not** prove that the generated site is correct against the
charts (the `charts` job renders it), that the prompts ask the right questions,
or anything about the four steps after the installer, which are
[`install.md`](../../docs/deployment/install.md)'s territory. A fixture is not an
operator: nothing here is evidence that a human understands any prompt.

## Driving a pty, and why

`install/tockmox-install.sh` reads answers with `read -r ans </dev/tty`. That is
the right call ... it keeps prompts working when stdin is a pipe ... and the cost
is that `printf '...' | installer` cannot drive it. `lib/pty-drive.py` allocates
a pseudo-terminal, writes every answer up front and lets the line discipline
hand them over one `read` at a time. Stdlib Python only, because a test of a
bootstrap installer that first requires installing a test runtime repeats the
mistake the installer's own header refuses to make.

Answers live in [`fixtures/interactive-answers.txt`](fixtures/interactive-answers.txt),
one per line, blank meaning *accept the default*. The blanks are the point: the
defaults are where derived values live, and a derived value is what broke.
`run.sh` asserts the fixture's answer count against the installer's prompt count
separately, so a shifted fixture reports itself rather than surfacing as a
confusing validation error about the wrong setting.

## Hermeticity, concretely

`git` is stubbed to fail. The installer resolves `tockmox.revision` against the
remote and *warns* when it cannot reach it ... a documented degradation for
air-gapped operators ... so stubbing it exercises that branch and makes the run
offline and deterministic in one move. Without the stub the result would depend
on whether the runner can reach GitHub and on whether the tag under test has
been cut yet, which is two sources of flake, and a flaky gate is worse than a
missing one.

`kubectl` is stubbed **per test**, not globally, because two of the groups above
are about what happens when a cluster is or is not reachable.

## Adding a case

1. Write the assertion from the behaviour the installer's `--help`, its header
   comment, or a documented page *promises*. Both defects above were gaps
   between a promise and the code, and both were findable by reading for
   testability rather than by running anything.
2. Name the artefact you read. If the only thing you can read is an exit code,
   the case is not ready: read the thing the command was supposed to create.
3. **Prove the case by mutation.** Revert the fix, run the suite, confirm it goes
   red *on that assertion and not on others*. Both fixes above were proved this
   way before the gate was wired. A case that has never been seen to fail is an
   untested line pretending to be a safety net ... this project has shipped one
   of those already, in the executed-docs selftest.

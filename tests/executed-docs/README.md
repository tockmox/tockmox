# The executed-documentation harness

`ci.yaml` runs 40 gates. All but one are static analysis of this repository
(the exception is [`tests/installer`](../installer/README.md), which runs the
installer and no cluster). This directory is the other question: **do the
instructions work?**

[`docs/testing-standard.md`](../../docs/testing-standard.md) is the standard
this implements. [`INVENTORY.md`](INVENTORY.md) is the coverage statement, and
it is the file to read if you want an honest answer rather than a build badge.

## Running it

```bash
# hermetic, no cluster, about a second
bash tests/executed-docs/selftest.sh

# the real thing: needs a KUBECONFIG scoped to tockmox-test on the Harvester rig,
# and the NAME of that rig's context (see "Every call names its cluster" below)
TOCKMOX_SUBSTRATE_CONTEXT=harvester-rig \
  TOCKMOX_DOCS_REF=v0.6.0-rc1 bash tests/executed-docs/run.sh

# one path, cluster left standing to poke at
TOCKMOX_SUBSTRATE_CONTEXT=harvester-rig \
  TOCKMOX_DOCS_REF=main TOCKMOX_KEEP_CLUSTER=1 bash tests/executed-docs/run.sh P03

# from a seat with a per-command time cap: one logical run over many calls.
# Exit 75 means "call again"; the state dir remembers groups, paths, counters.
TOCKMOX_SUBSTRATE_CONTEXT=harvester-rig \
  TOCKMOX_DOCS_REF=main TOCKMOX_RUN_RESUME=/tmp/rs TOCKMOX_RUN_BUDGET=40 \
  TOCKMOX_RUN_REBUILD_BUDGET=15 bash tests/executed-docs/run.sh
```

## Every call names its cluster

Every `kubectl` and `helm` call in this directory (and in
`.github/workflows/executed-docs.yaml`, which drives it) carries an explicit
`--context` or `--kube-context`, taken from a variable that is refused when
empty. A bare call would target whichever context the caller's shell happens to
have current, and this harness creates and deletes VMs, Secrets and namespaces
(TM-0797; the standing rule after INC-2026-09-29-01).

| Variable | Names | Who supplies it |
|---|---|---|
| `TOCKMOX_SUBSTRATE_CONTEXT` | the hypervisor cluster that hosts the throwaway VM | you, always. `run.sh` refuses without it. Not needed with `TOCKMOX_EXISTING_KUBECONFIG` (no VM is made or destroyed) |
| `KUBE_CONTEXT` | the cluster under test | `run.sh` reads it from the kubeconfig it just had the provisioner write (one cluster in it). With `TOCKMOX_EXISTING_KUBECONFIG` you supply it, because a file the run did not write proves nothing about which of its contexts you mean |

`--context=` with an empty value does not error: kubectl falls back to the
current context. So the guard is a refusal (`${VAR:?...}`), not a default, and
`tools/check-harness-context.sh` fails the build on a bare call, a literal
context, or a context variable with no refusal. It reads text: it cannot tell
that the context you named is the right cluster, only that one is named. The
`kubectl config` calls that edit or read a kubeconfig FILE and reach no cluster
are marked `ctx-exempt` with the reason on the line.

The workflow reads `TOCKMOX_SUBSTRATE_CONTEXT` from the repository variable of
the same name. Until that variable is set the `paths` job refuses in its
preflight, by design, and the `freshness` job goes red after its stale window.

**WORKSTATION blocks run in zsh, pasted.** `lib/zsh-paste.py` feeds a block
to an interactive zsh on a pseudo-terminal as a bracketed paste followed by
Enter, answers `read -rs` prompts through the pty, and carries the block's
exports back out. That is the only faithful way to run a block through the
shell the docs name as supported: `zsh -c` keeps comments and skips history
expansion, and `zsh < file` lets `read` swallow the next block line. Three
install-page defects found on 2026-09-14 (`git init` defaulting to `master`,
an unquoted multi-word `$VAR`, and the `read -p` class before it) were
invisible from bash. `P09` uses it for every block; `TOCKMOX_WS_SHELL=bash`
falls back, and the log says so.

## The four ideas it is built on

**1. The command is read out of the page, never retyped.** `lib/extract-block.sh`
pulls the bytes of a fenced block out of a documentation page at a git ref, and
the path script runs those bytes. There is no copy of any documented command in
this directory. That is the mechanical form of standard rule 8: a harness that
quietly fixes the command is testing the harness. It also means a run names the
ref and the SHA256 of each block it executed, so a page edit shows up as a
changed fingerprint rather than as silent divergence between the docs and the
test.

**2. Assertions name an artefact and an expected value.** `lib/assert.sh` has no
`assert_succeeds` and no exit-code assertion, on purpose. Every assertion prints
ARTEFACT, READ, EXPECTED, ACTUAL, RESULT. `assert_summary` refuses a path that
made zero assertions, because a step that exits zero having examined nothing is
worse than a failing one: it converts an absence of testing into a claim of
coverage.

**3. Claims are tested, not only commands.** `P03` patches a StorageClass,
**reboots the node**, and reads the annotation again. That single re-read is what
TM-0287 needed and did not have. Every command on that page exited zero and the
page was still wrong.

**4. Each gate states what it does not prove.** `does_not_prove` and
`parity_caveat` are functions rather than comments, so the caveats land in the
run log where somebody reading a green result actually sees them. A pass on
Ubuntu/arm64-driven tooling is not a pass on x86 MicroOS, and the run says so
every time.

## What an outcome means

Every path ends by declaring exactly one of six outcomes. The model is defined
in `lib/assert.sh` (the "outcome model" block, `OUTCOME_VALID` and
`path_outcome`); this table restates it and does not extend it.

| Outcome | Meaning |
|---|---|
| `PASS` | The target ran and its acceptance criteria were satisfied |
| `PRODUCT_FAIL` | The target ran and the documented claim was falsified. Blocks a release |
| `BLOCKED` | A declared environmental constraint prevented execution |
| `INFRA_ERROR` | The runner, a dependency, a registry, an API or the harness failed |
| `SKIPPED` | The profile excludes this claim, by reviewed rule |
| `ABORTED` | The path started and never reached a trustworthy terminal state |

**The documented command's exit code is data, not the outcome.** A path calls
`execute_begin` before the command and `execute_end` with its raw exit status
after. The status is written to the log as evidence. It does not choose the
outcome. A documented `${VAR:?...}` guard that fires correctly exits 127 under
`bash -c`, the same code as command-not-found, so reading the code alone gets
that case wrong.

**`PASS` requires a completed execute phase.** `path_outcome PASS` is refused
unless `execute_begin` and `execute_end` both ran, and it is also refused when
the command exited nonzero, unless the path declared beforehand, with
`execute_expect_nonzero`, that a nonzero exit is the correct behaviour. A
refused `PASS` is logged as `ABORTED`, writes no receipt, and returns nonzero.
The reason: assertions can pass on state an earlier path left on the cluster,
so all-green assertions do not show that this run produced what they read.

`path_finish` maps the assertion summary onto the model: no assertions made is
`ABORTED`, a failed assertion is `PRODUCT_FAIL`, and all passing is `PASS`
subject to the rule above. A path with an environmental constraint declares
`BLOCKED` or `INFRA_ERROR` itself. Each declared outcome also writes a receipt
file. `run.sh` reports any path that exits without one, other than a declared
absence (exit 3), as `UNCONVERTED` and refuses success for the run, so a path
that never adopted the model cannot count as green.

## Layout

```
lib/extract-block.sh   verbatim block extraction from a page at a ref
lib/assert.sh          artefact assertions, xfail, does_not_prove, parity_caveat
lib/zsh-paste.py       paste a block into an interactive zsh on a pty (the workstation shell)
provision/             create / exec / reboot / destroy a throwaway k3s VM
paths/P*.sh            one documented path each, in dependency order
run.sh                 provision, run selected paths, report, tear down
selftest.sh            hermetic proof of the machinery above
INVENTORY.md           every documented path, mapped to evidence or an exception
```

## Cadence, stated

| Job | Cadence | Why |
|---|---|---|
| `selftest` | per-commit | hermetic, no network, no cluster, about a second |
| `paths` | nightly 07:00 UTC, plus `workflow_dispatch`, on the `tockmox-devtest` runner | needs a real cluster and about twenty minutes |

Standard rule 6 says a check that is expensive and therefore quietly never runs
is worse than one that does not exist, because it appears in the inventory. Two
ways that happens here, both worth watching:

- **No runner carries the `tockmox-devtest` label.** The job queues forever, and
  a queued job is not a red job.
- **GitHub disables a scheduled workflow after 60 days of repository
  inactivity.** It stops running and nothing goes red.

Both are caught by the hosted **`freshness`** job, which fails when the last
successful run of this workflow is more than three days old. Nightly cadence, so
that is two consecutive misses plus slack.

**This section used to say the `paths` job's own preflight step caught the
first one. It cannot, and the correction is worth keeping visible.** That
preflight runs inside a job whose `runs-on` is `[self-hosted, tockmox-devtest]`:
with no such runner the job never starts, so the preflight never executes. The
mitigation was inside the thing whose absence it was supposed to detect. An
outside reviewer found it in 2026-09-03 while the live run sat queued, doing
exactly what the paragraph said could not happen silently. The preflight is
still there and still worth having ... it catches a runner that exists but is
missing `kubectl`, or pointed at the wrong cluster. It just cannot catch a
runner that is not there.

## Blast radius

Everything happens in one disposable namespace, `tockmox-test` by default, on a
KubeVirt-capable cluster. `provision/throwaway-cluster.sh` refuses to start if
it is pointed anywhere else.

**Teardown deletes only what it created** (TM-0587). Everything the harness
makes on the substrate is named after the VM (`$TOCKMOX_TEST_VM`, or
`$TOCKMOX_TEST_VM-...`), and `destroy` deletes that VM and only the objects named
after it, then prints the VMs it left alone. The namespace is shared: the
nightly workflow, a person and an agent can each have a throwaway there, and
until 2026-10-06 a teardown took everyone's. The nightly names its VM
`ed-<run id>-<attempt>` and its teardown also runs `sweep ed- 120`, which
destroys, one by one, its own earlier VMs older than two hours. The
namespace-wide reset still exists for the deliberate case, and asks for it by
name: `throwaway-cluster.sh reset --every-vm-in-tockmox-test`.

A KubeVirt cluster usually also hosts machines that are not disposable. The
namespace rule is the boundary that keeps this harness away from them, because a
rule scoped to a class survives someone adding a new machine and a deny list of
names does not. `TOCKMOX_PROTECTED_VMS` is a space-separated second net for
naming specific machines anyway.

## Substrate and credentials

The harness needs a `KUBECONFIG` whose context can create and delete
VirtualMachines **in that one namespace and nowhere else** ... a ServiceAccount
with a namespaced Role, no ClusterRole. It holds no other credential.

The only credential it mints is a per-run SSH key, used for the procedures the
documentation itself locates on the node (`sudo touch ...` on a k3s server).
Public half injected by cloud-init, private half deleted with the cluster, never
a stored secret. Without it, node-local procedures could only be approximated
from the cluster side, and approximating is the thing this harness exists not to
do. A path that needs the node and cannot reach it records an **exception**, not
a failure ... a topology that blocks inbound SSH says nothing about whether the
documented procedure works, and reporting it as red would be a false accusation
against the page.

**Direction matters more than it looks.** On a segmented lab network, the
harness reaching *into* the guest is the fragile direction and the guest
reaching *out* to the API that created it is the sturdy one. That is why
`TOCKMOX_HANDOFF` defaults to `secret`: provisioning is not the thing under
test, and a run that cannot retrieve a kubeconfig produces no evidence at all.

| Variable | Default | What it is |
|---|---|---|
| `TOCKMOX_DOCS_REF` | *(required)* | git ref whose documentation is under test |
| `TOCKMOX_TEST_NAMESPACE` | `tockmox-test` | where the throwaway VM lives |
| `TOCKMOX_DISPOSABLE_NAMESPACE` | `tockmox-test` | the namespace the provisioner will consent to operate in |
| `TOCKMOX_PROTECTED_VMS` | *(empty)* | space-separated machine names to refuse outright |
| `TOCKMOX_VM_IMAGE_ID` | `tockmox-test/ubuntu-2204-cloud` | boot image in the substrate's image store |
| `TOCKMOX_VM_NETWORK` | `pod` | network attachment for the VM. `pod` is KubeVirt's masquerade binding: the guest NATs out to the substrate API (so the `secret` handoff works from any harness host) and is reached only through the NodePort `create` publishes. A host that can route to the lab segment may override with a Multus NAD, e.g. `export TOCKMOX_VM_NETWORK=NAMESPACE/SEGMENT` ... measured 2026-09-04, a guest there has WAN but no route back to the management network, so the handoff never lands |
| `TOCKMOX_VM_STORAGECLASS` | `harvester-longhorn-r1` | class for the VM's boot disk |
| `TOCKMOX_HANDOFF` | `secret` | how the guest's kubeconfig comes back: `secret` (guest writes it outbound, no inbound path needed) or `http` (guest serves it once, no credential in the guest) |
| `TOCKMOX_KEEP_CLUSTER` | `0` | `1` leaves the cluster standing for inspection |
| `TOCKMOX_EXPECTED_DEFAULT_COUNT` | `0` | expected count of default StorageClasses after P03 un-defaults `local-path` (1 once a platform layer is installed) |
| `TOCKMOX_P08_EXPECTED_DEFAULT_COUNT` | `1` | what P08 expects `existing-cluster.md` Check 3 to find: `local-path` on a stock k3s throwaway. Set `0` when P03 has run first |

## Adding a path

1. Find the section heading and the block number on the page. Do not copy the
   command.
2. Copy the closest `paths/P*.sh`, change the `PAGE` and `SECTION`, and write
   the assertions from **the page's own stated success conditions**. Record
   whether it states any with `record_success_conditions <page>` from
   `lib/assert.sh`, which accepts both phrasings rule 4 of the documentation
   standard names ("Success condition" and "Passes when") ... never a bare
   grep for one of them. If the page has none, stop: a procedure with no stated
   success condition cannot be tested, and that is a documentation defect
   before it is a testing gap. Hand it to `documentation-steward`.
3. Write `does_not_prove` honestly. It is the part a reader of a green run
   needs most.
4. Add a row to `INVENTORY.md`. A path script without an inventory row is not
   coverage, because nobody can find it.
5. If the section is one the per-commit canary should watch, add a `check` line
   to the `selftest` job in `.github/workflows/executed-docs.yaml`.

## A note on the exec bit

CI's first gate refuses a `tools/` script committed `100644`, because a file
that cannot execute fails with "Permission denied" before it checks anything.
The scripts here are invoked as `bash path/to/script.sh` for exactly that
reason, so they work either way ... but set the bit anyway when adding one:

```bash
git update-index --chmod=+x tests/executed-docs/paths/P0N-whatever.sh
```

# Roadmap

## How to read this

This roadmap describes current intent. It is not a set of release commitments,
and it carries no dates.

- **In progress** ... implementation or design work has started.
- **Next** ... intended after the current work. No promised release.
- **Exploring** ... the problem looks worth solving. Not a commitment to build
  anything, and the shape may change entirely.

This is not the whole backlog. It is what Tockmox has deliberately chosen to
state publicly, kept short enough that every item here can be explained.

Priorities change. When an item changes direction or is dropped, this page says
so with a date rather than quietly losing the entry.

Reviewed at every release, and whenever anything on it stops being true.
**Last reviewed: 2026-10-19**, at 0.8.1, a patch: no item changes direction,
and the upgrade from 0.8.0 was measured end to end (data checksums, volumes and
sealed secrets read before and after). At 0.8.0, the first public release, and
since 0.6.1:
documentation served from the cluster shipped in 0.7.0 and leaves Exploring; the
model gateway runs non-root on a read-only root filesystem in 0.8.0; egress is
contained for the whole AI namespace, not only the chat console; an upgrade
across a breaking change has been executed end to end; and the maintainer's
private extensions are named under Exploring.

## The one thing worth knowing about this list

Most of what follows is about evidence rather than features.

Tockmox documents a great deal and has proven less of it. That gap is the
project's own assessment, it is stated on the pages where it applies, and
`tests/executed-docs/INVENTORY.md` is the coverage boundary rather than a
summary. Closing it is the current direction.

If you are evaluating Tockmox, that ordering is the useful thing to know: the
mechanisms mostly exist, and what is thin is the published evidence that they
work when a stranger runs them.

## In progress

**The published known-issues lists, closed rather than carried.** Every
release's CHANGELOG section names what is known to be wrong with it. The
direction is each entry closed or given a mechanism, because a known-issues list
that only grows is a list nobody believes.

**Documentation that executes.** A harness runs documented procedures against a
live cluster and asserts on what the page says will happen. It has already found
defects that review did not, including a documented command that could not work
as printed. **How many paths have executed, and which, is stated in
`tests/executed-docs/INVENTORY.md` and deliberately not restated here**, because
a number in prose tracking a list elsewhere goes stale. The inventory lists every
documented path enumerated so far, marks each executed, staged, excepted in writing, or
open, and records the pages not yet enumerated as a single open row. Most are
still open.

## Next

**The documented install path, executed by machine and published.**
The install page has been run start to finish verbatim by machine, every
workstation block in one interactive session against a throwaway cluster, and
the fresh-install page has been run the same way on openSUSE MicroOS, the
operating system this project recommends, across the reboot the page prescribes.
Those runs found four defects no review had. The executed-docs `paths` job now
runs documented paths on a throwaway Ubuntu cluster in CI, on every change to
the docs or the harness and nightly, and has been shown to fail on a
deliberately broken page. The README publishes one measured first install
(a scripted `household-sso` run, 11m22s to first chat).

**What is still ahead is the half that makes it evidence for a stranger**: the
MicroOS runs in CI, on a schedule, with the transcript and timings published
from every run rather than one.

**An executed upgrade, release to release.**
Every release gate now includes an upgrade leg: the previous release installed
with a site that sets real values and seeds data, the documented edits applied,
and convergence and data read back (RELEASING.md lists the standing
assertions). An upgrade across a breaking change has also been executed end to
end, once, on a cluster installed at the earlier release. What is still not
measured is the part that matters most to someone deciding whether to build on
this: data integrity while something is writing, a multi-node topology, and an
upgrade walked by CI rather than by the maintainer's gate. The rollback has
known limits that `docs/deployment/upgrade.md` states. Until the rest is
measured and published, building on Tockmox means accepting that risk.

**The disconnected install, from a dated exercise to a repeating gate.**
On 2026-08-25 a greenfield install ran with the uplink cut at the route level
for both IPv4 and IPv6: all nine layers healthy, 59 of 59 pods running, zero
image pull failures. That is one build on one date, and `docs/deployment/airgap.md`
says so. Two things follow: a re-proof against the current tree, so the claim is
dated rather than ageing, and then the same exercise as a gate that runs on a
schedule rather than when someone remembers.

**A release lock: the resolved digest of every container the release gate
actually ran.** A signed source tag proves which chart text was released, not
which bytes executed, because 43 of the 44 runtime images are addressed by tag.
The intent is a lock file generated from the greenfield gate install at each
tag ... every running container's resolved digest, including the images that
controllers pull on their own and no template names ... published beside the
image list and checked against it in CI. Regenerated at each release and not
between, because the lock is a statement about a tag.

**Pod Security enforced where a namespace can take it.** Five of the seven
namespaces the policy layer creates carry `enforce` (a values key,
`podSecurity.enforce`, with a per-namespace escape), set no higher than a gate
measures the rendered pods to pass. `tockmox-monitoring` and `tockmox-platform`
do not, because node agents and Longhorn need host access by design. The model
gateway runs non-root on a read-only root filesystem since 0.8.0. Still ahead:
observing a violating pod actually refused on a live cluster.

**Image references pinned by digest, checked against the release lock.** Of the
44 runtime images, one is currently digest-pinned; `docs/deployment/registry.md`
states that scope, and the SBOM carries it. The lock above comes first because
it answers the question a reviewer actually asks ... which bytes ran ... so that
each pin can be checked against it rather than trusted.

**Egress containment beyond the AI namespace.**
Ingress default-deny is complete across all seven namespaces the policy layer
creates. Egress is contained for the whole AI namespace (the chat console, the
model gateway, its database and anything else there) and for the read-only
diagnostic identity, and open for identity, monitoring, the platform
controllers and the devops workloads. `docs/usage/what-you-get.md` states the whole shape,
including the ingress rules that are broader than they read. Closing the gap
means adversarial tests that assert every allowed and denied path on the
supported CNI, not policies that apply cleanly and permit everything.

## Exploring

**Certificate trust: one mechanism instead of per-console wiring.**
Today each console gets its trust bundle through its own wiring. Whether to
adopt trust-manager instead is a build-or-adopt question with real trade-offs on
both sides, and it is not settled.

**The maintainer's private extensions.** These run on the maintainer's own
installation today and are not in this repository. Each lands in Tockmox when it
is ready to be supported here; until then, nothing about them is a commitment.

- **Context Analyzer.** Captures every model call that passes through the model
  gateway and shows what composed each context window (system prompt, tool
  definitions, conversation history, injected content, tool results and the
  completion) with token counts and cost per call.
- **Tockmox Interface.** A chat and context workspace over your own document
  corpus, as an alternative to the bundled chat console.

## Deliberately not on this list

**There is no Docker Compose edition and none is planned.** It would cost
most of what makes Tockmox what it is. Kubernetes is a prerequisite and
operator skill is required, and it is better to say that once here than to
leave people to discover it.

## Proposing something

Feature proposals go to [Discussions](https://github.com/tockmox/tockmox/discussions).
An open thread there means the problem has been heard, not that it is planned.
What Tockmox intends to work on appears on this page; other pages describe
gaps where they apply, and a gap named on a page is not a promise to close it.

The most useful thing you can send is the problem rather than the feature: what
you are running, what stopped you, what constraint made it hard, and what you
are doing instead today. And if you had to patch or fork Tockmox because it
would not let you configure something, say so in an issue rather than here.
That is a gap in the values interface, and it is treated as a bug.

---
okf_version: "0.2"
type: Reference
title: "Project status"
description: "The longer form of what README.md summarises: the pre-1.0 position, what the claims rest on, the component choices, the agent grounding, the release table and the README badge notes."
tags: [status, pre-1.0, releases, readme, rationale]
status: stable
generated:
  by: hand
  at: 2026-10-03
tockmox:
  classification: public
  audience: [operator, contributor]
---

# Project status

The longer form of what [README.md](../README.md) summarises. Where the two differ, the README is authoritative for the current release.

## What Tockmox is

A Kubernetes platform for running your own AI stack and your own observability
on hardware you control, with no dependency on a vendor's cloud staying up,
staying affordable, or staying interested in you.

Almost nobody assembles production-grade private AI alone — not because the
parts are missing, but because wiring them together is a different job from
using them. 82% of container users surveyed by the CNCF run Kubernetes in
production, and 97% of respondents to its Argo CD survey run Argo CD in
production; the components are proven, and
[why-tockmox](why-tockmox.md#sources) names where those figures come from.
The assembly has stayed the province of teams and budgets.

Tockmox is that assembly, built to the discipline a production environment
earns rather than the discipline a demo needs: default-deny ingress, single
sign-on, backups that prove they restore, guards that fail loudly rather than
starting insecure. Every component ships under a licence you can read, and the
two that are source-available rather than open source are named on the
[licences page](third-party-licenses.md). Nothing here is a piece you
cannot read, replace, or keep.

It's built around three properties.

**It keeps working when the internet doesn't.** Every component runs locally.
Losing your uplink degrades capability, not availability.

**Upgrades can't overwrite your configuration.** Your settings live in a
separate repository from the platform, so an upgrade physically can't touch
them. It's the `/usr` versus `/etc` split Linux distributions settled on
decades ago, expressed in GitOps terms.

**Every claim here names its evidence, and says what kind it is.** Three kinds,
and the difference matters: claims about *rendered artifacts* are gated on every
commit by CI; claims about *operational behaviour* rest on named, dated runs on
real clusters; and the documented procedures that have not been executed
verbatim say so on the page. `tests/executed-docs/INVENTORY.md` is the coverage
boundary and it is deliberately readable ... it names what is still open.
Anything not yet built says so rather than being implied.

### The boundary, before the argument

**It installs** nine layers on a cluster you already have: namespaces and
network policy, ingress and TLS and storage, replicated block storage and
Postgres, single sign-on, metrics and logs and dashboards and alerting, a chat
console and a model gateway (bundled, and off by default — the console ships
pointed at nothing on purpose), and a heartbeat that proves the alerting is
alive.
[What you get](usage/what-you-get.md) itemises all of it.

**It does not install** Kubernetes, ArgoCD, sealed-secrets, or a model. The
first three are prerequisites and
[there is a reason the list is that short](deployment/prerequisites.md).
The fourth is deliberate: the chat console ships pointed at nothing, and you
aim it at hardware you own, a frontier API, or both.

**You operate it.** Tockmox assumes an operator who is comfortable with
Kubernetes, Helm and GitOps. That operator can be one person with a mini PC
under a desk, a household or small shop that would rather own its stack than
rent it, a team whose most valuable data is the data that shouldn't leave the
building, or a research group that needs the whole thing under its own control.
It is not a one-click desktop application and does not pretend to be.

The pattern is the same from a closet to a campus and scales in both directions
without changing shape ... which is a claim about the architecture, not about a
support model that one maintainer and one reference deployment cannot yet back.

The argument in full, made to a skeptic, is
[Why Tockmox?](why-tockmox.md).

## For early adopters (pre-1.0)

This is an unreleased project. Here's what that costs you. This section goes
away at 1.0.

> [!IMPORTANT]
> **The values interface is declared, and tiered rather than frozen whole.**
> [Semantic Versioning](https://semver.org/) treats major version zero as
> explicitly unstable, and a blanket "anything may move" was accurate and
> useless: some of these keys are wired through six of the nine layers and have not moved
> since the schemas were closed, and some are extension points with no shipped
> consumer. So every Tockmox key now carries a tier in its schema ...
> `stable`, `provisional` or `experimental` ... and a `stable` key does not move
> without a minor bump and a migration note at the top of the release notes.
> Read the tiers from the tree rather than from prose; the `jq` is in
> [values-contract.md](administration/values-contract.md), which also says
> which keys are internal wiring and which classes are excluded from every tier.
> Pin a tag rather than a branch, and read [CHANGELOG.md](../CHANGELOG.md) before
> every upgrade. Holding those tiers through 1.0 is the prerequisite; declaring
> them was the first half.

**What's solid.** All nine layers deploy, proven by teardown-and-greenfield
installs of the tagged content — including a rehearsal that tore the nine
layers down to bare k3s, reinstalled from the site repository, and restored one
database from backup beside the live one, with the restored data verified row
by row. The whole-cluster sequence has not yet been run as one exercise;
[backup and restore](operations/backup-restore.md#what-is-not-certified-here)
says exactly which steps have and have not. Guards fail loudly rather than starting insecure, every
application is individually disableable, and CI asserts on rendered artifacts:
that schemas *reject* bad input, and that no NetworkPolicy guards an empty
namespace. That backups restore is proven differently ... by the rehearsal
above and by a weekly drill that destroys a database and restores it, which is
evidence from a running cluster rather than a static gate.

**It runs in production.** The maintainer's own homelab runs Tockmox, not a
fork of it: since 2026-10-02 all nine layers on that six-node cluster, which a
household uses every day, come from Tockmox's own charts (0.8.0 since its first
release candidate) through a site repository, the same arrangement the
installer builds for you. It got there by
migrating a running cluster in place: every volume restored from backup, and
the nine in the hash scope matching a whole-tree hash taken before the move.
[Architecture § revision channels](architecture.md#revision-channels) says
what that does and does not make true.

**What's thin.** The glue, not the platform — site-specific alert rules beyond
the self-check set, and a few dashboards that wait on their scrapes (nine
Tockmox-authored boards ship; ArgoCD's follows when its metrics config lands).
All additive, none of it blocking an install.

**What you're signing up for.** One maintainer, best-effort response, no SLA.
Read [SUPPORT.md](../SUPPORT.md) before you depend on this for something that
mustn't break. Plan on being your own first line of support; the documentation
exists to make that realistic.

**What helps most.** Tell us where the configuration surface failed you. "I had
to patch or fork something because Tockmox wouldn't let me configure it" is the
single most valuable report this project can get, because it's a bug we can
close permanently. See [CONTRIBUTING.md](../CONTRIBUTING.md).

## What you get

A working stack, not a parts list. One sign-on reaches the three consoles wired
to it ... Grafana, Open WebUI and Argo Workflows ... with local logins kept as
break-glass. The model-gateway database proves it restores on a schedule
instead of sitting there untested; Longhorn volumes have been restored from
backup once, in production, and Authentik's bundled database is backed up but
not yet drilled, which
[backup and restore](operations/backup-restore.md) sets out row by row.
Silent failures page you, and a heartbeat proves the alerting itself is alive.
Default-deny **ingress** covers every namespace the platform creates, with no
exceptions left to discover in production ... and the word "ingress" is doing
real work there: egress is contained for the chat console and (after 0.6.2) the AI namespace, and open elsewhere,
which [what you get](usage/what-you-get.md#network-containment) states in
full rather than leaving you to read the policies. Every application turns off
individually, every UI hostname derives from one value, and TLS follows
another.

**The AI plane needs one decision from you: which models.** Open WebUI ships
pointed at nothing, with no cloud backend wired in and a CI check that keeps it
that way — that is a promise about what Tockmox ships, not a limit on what you
configure. Point it at a model host on your own hardware, at any
OpenAI-compatible endpoint including the frontier providers, or at the bundled
LiteLLM gateway and route to both: local for the work that fits, frontier for
the work that earns it, with one place to set policy and read the audit trail.
Two values, in [the AI plane](usage/ai-plane.md).

Sending a request outside your network means the conversation goes with it, and
the egress rules have to be opened to allow it. That is a deliberate decision
with a different compliance shape from keeping inference local, and Tockmox
makes you make it rather than making it for you.

The gateway is on by default since 0.8.0 and the console goes through it
(TM-0460, REQ-0004): its master key is minted with the other credentials, and
the console's own key is minted by a Job once the gateway answers. The model
list still ships empty, because a model endpoint is an address on your
network.

Underneath, nine charts deploy on six sync waves — `crds`, then `policy`, then
`platform`, then `observability` with `exporters`, then `identity`, and finally
`devops`, `ai` and `selfcheck` together. The full layer-by-layer inventory —
what ships in each, what's deliberately off by default, and how the guards fail
loudly rather than starting insecure — is in
[Architecture: the nine layers](architecture.md#the-nine-layers).

## Opinionated, not closed

Every component here is a choice, and the choices are stated rather than
hidden: Traefik for ingress, Longhorn for storage, Authentik for identity, Open
WebUI and LiteLLM for the AI plane. They were picked because they work together
under production discipline, and running them as a set is the path that gets
tested.

Disagreeing with one should not cost you the platform. Each capability declines
individually, and a declined capability can keep the parts of it you still want
— turn off the bundled Prometheus and Tockmox still renders its ServiceMonitors
and alert rules for the one you already run. That is the difference between an
opinion and a lock-in.

Where a swap is not clean, the docs say so rather than letting you find out:
turning Longhorn off while `global.storageClass` still names it makes the
platform layer refuse to render, on purpose.

## Bring your own agent

A lot of people installing this have a coding agent open already. Point it at
the clone and it stops guessing.

The repository carries [`AGENTS.md`](../AGENTS.md) at its root — the model-neutral
[convention](https://agents.md), not any one vendor's file — plus five
task-shaped skills in [`docs/agent-skills/`](agent-skills/README.md): a
guided install, troubleshooting a failed one, editing values safely, air-gap
preparation, and deploying your own application on the platform.

What that buys you is narrow and worth stating precisely. An agent reasoning
from general Kubernetes knowledge is confidently wrong about this platform in
specific, repeatable ways: it will patch a live object that `selfHeal` reverts,
set a value on the wrong layer where it is silently accepted, look for a
component in its upstream project's namespace instead of its layer's, or read
`Synced` as "working" when nine layers go green while workloads wait on
credentials nobody minted. **The grounding closes those gaps and does not make
your agent an expert.** It stops a dozen specific mistakes that cost an
afternoon each.

**Tockmox ships no agent and needs none.** Nothing here is a prerequisite,
nothing executes, and no part of installing or running the platform depends on
one — that independence is
[deliberate](architecture.md#why-deterministic-self-monitoring). This is
documentation with a machine as the intended reader.

**The first thing worth asking it is whether to install at all.**
[Working with a coding agent](usage/working-with-an-agent.md#prompts-worth-starting-with)
carries a list of prompts worth starting with, and the first one asks your agent
to weigh Tockmox against your situation and name the reasons it might not fit.
Your agent knows your hardware and your constraints; this repository knows
Tockmox; fit is the answer neither can give alone.

Two things worth knowing before you start, both covered in
[working with a coding agent](usage/working-with-an-agent.md): an agent
helping with **your** deployment will want your site values, your hostnames and
your `kubectl` output, and if it runs against a hosted model all of that leaves
your network — the same decision [the AI plane](usage/ai-plane.md) makes
you make about inference, and yours to make on purpose. And this is **not** the
AI plane: that runs on your cluster and is what the platform exists to serve. A
coding agent is a tool of yours pointed at a git checkout. Nothing connects them.

## Releases

Releases follow [Semantic Versioning](https://semver.org/). A minor release
ships only after a teardown-and-greenfield install of its exact content passes
on a clean cluster; a patch that changes no chart logic is proved by what it
changed, on an existing install upgraded to it ([the patch bar](../RELEASING.md#the-patch-bar)).
Each release's gate report says which bar it met. **The latest release is the
supported one.**

**0.8.0 is the first public release.** Earlier versions were built and run in
a private repository and are not published, so there is no supported upgrade
from them; [CHANGELOG.md](../CHANGELOG.md) starts at 0.8.0.

Supporting exactly one release is a deliberate limit of a one-maintainer
project, not an oversight ... see the boundary above. Until 1.0, treat every tag as capable of moving the values
interface, and read [CHANGELOG.md](../CHANGELOG.md) before upgrading.

## README badges

The Release badge is back at 0.8.0, the first public release. It was removed
while the repository was private: shields.io queries the GitHub API
anonymously, so it could not see the releases and rendered the literal text
`release: repo not found`, an error badge beside four working ones (verified
2026-09-17 by loading the URL). If it ever shows that text again, the
repository's visibility or name has changed, not the badge.

The GitHub Actions `badge.svg` badges above are unaffected by visibility and
render correctly today; only the shields.io API-backed one breaks.

The Executed docs badge is scoped to `event=schedule` on purpose. That is the
nightly run against a live cluster, and it is the one that can go quiet without
anything going red ... `executed-docs.yaml`'s own header names two ways that
happens: no runner carrying the `tockmox-devtest` label (a queued job is not a
failed job) and GitHub disabling a scheduled workflow after 60 days of
repository inactivity. A stale badge is a visible symptom of both. It NARROWS
that blind spot and does not close it: a queued job still renders whatever the
last completed run said.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "Working with a coding agent"
description: "How to point a coding agent you already use at this repository, what it becomes good at, what it stays bad at, and what leaves your network when you do it."
tags: [agents, tooling, operator, privacy, boundaries]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [operator, contributor]
---

# Working with a coding agent

A lot of people installing this will have a coding agent open already. This
page is about making that agent useful here, and about being clear on what it
costs you.

**Tockmox ships no agent and needs none.** Nothing on this page is a
prerequisite. The platform installs, runs, recovers and self-monitors with no
agent involved, deliberately ...
[architecture § why deterministic self-monitoring](../architecture.md#why-deterministic-self-monitoring).
If you would rather not use one, every procedure here is written for a person
and always will be.

## Do this

Clone the repository and point your agent at the clone. That is the whole
setup.

The repository carries [`AGENTS.md`](../../AGENTS.md) at its root, following
the model-neutral [`AGENTS.md`](https://agents.md) convention, and a
`CLAUDE.md` beside it that points at the same file for tools that look for that
name. Most agents read one or the other without being told. If yours reads
neither, tell it to start with `AGENTS.md`.

Five task-shaped procedures live in
[`docs/agent-skills/`](../agent-skills/README.md): a guided install,
troubleshooting a failed one, editing values safely, air-gap preparation, and
deploying your own application on the platform. An agent should load the one
that matches what you are doing rather than all five.

Nothing in either place executes. They are documentation with a machine as the
intended reader.

## Prompts worth starting with

No special syntax, and nothing here is required. These are the questions this
repository is organised to answer, and opening with one of them is faster than
describing from scratch what you want.

**Before you install**

- *"Read AGENTS.md and docs/why-tockmox.md, then tell me whether Tockmox fits my
  situation, including the reasons it might not. Ask me only for what you need
  and don't already know."* This is the one worth running first. The repository
  can describe Tockmox; only your agent knows your hardware, your cluster and
  your constraints, and fit is the answer neither can give alone.
- *"What does Tockmox install, what does it deliberately not install, and which
  prerequisites am I missing?"*
- *"What is the smallest useful deployment, and what does it give up?"*
- *"Read ROADMAP.md and SUPPORT.md and tell me what I would be signing up for."*

**Installing**

- *"Load docs/agent-skills/guided-install and walk me through it. Ask me for the
  values you need rather than guessing them."*
- *"Here is my `tockmox.yaml`. What will it produce, and what did I get wrong?"*
- *"The install is stuck at <symptom>. Load the troubleshoot-install skill."*

**Running it**

- *"I want to change <X>. Which rung of the customisation ladder is that, and
  what goes in my site repository rather than in the platform?"*
- *"Read what the platform is telling me: what is firing, what has restarted,
  and which of those actually matters."*
- *"What am I relying on here that has not been proven?"* The answer comes from
  the "What is not certified here" sections and from
  `tests/executed-docs/INVENTORY.md`, and it is a fair question to ask of any
  page in this repository.

**The one worth asking twice:** *"Show me where the documentation says that."*
An answer with no citation is a guess, and these pages are written so that the
citation exists.

## Pointing an agent at a running deployment

Reading the repository and reading your cluster are different acts with
different costs, and it is worth being deliberate about the second.

**What the platform provides.** The policy layer ships a
[read-only diagnostic identity](what-you-get.md#the-diagnostic-identity-since-it-is-the-interesting-one)
whose ClusterRole grants `get`, `list` and `watch` and nothing else, which
cannot read Secret contents, and whose NetworkPolicies allow no path to the
internet. Tockmox ships the cage rather than the occupant.

**What it does not do today.** That identity is set by the execution path and is
not assumable, so it is not the credential you hand to a coding agent running on
your laptop. An agent outside the cluster uses whatever kubeconfig you give it,
and **the containment does not travel with it**: your laptop's egress is your
laptop's egress, and a read-only kubeconfig prevents writes, not disclosure.

**So the honest guidance is narrow.** Give an agent the narrowest context that
answers the question in front of you, prefer pasting the specific output over
handing over cluster-wide read, and assume that anything it reads about your
deployment is something it may repeat. Everything in
[what leaves your network](#what-leaves-your-network) applies here and applies
harder, because an agent with cluster access is enumerating rather than reading
what you chose to paste.

**And the option worth remembering:** the platform you are installing can serve
the model that helps you operate it. Nothing about a grounded agent requires a
hosted one.

## What this actually buys you

An agent reasoning from general Kubernetes knowledge will be confidently wrong
about this platform in specific, repeatable ways. The grounding exists to close
exactly those gaps. A grounded agent knows, without being told:

- that your configuration lives in **your** repository, so the answer to a
  customisation question is a value in your site repo and never a patch to
  these charts
- that a `kubectl edit` against a live object is reverted by `selfHeal`, so a
  fix that appears to work has not worked
- that the values namespace is **shared across all nine layers**, so a key set
  on the wrong layer is accepted and silently does nothing
- that a component switched on while its capability is off fails the render on
  purpose, and that unset and `false` are different states
- that every component lives in **its layer's** namespace, not the namespace its
  upstream project conventionally uses
- that an RBAC error about listing secrets is usually an admission policy three
  layers away, and that the message will never say so
- that `ArgoCD reports Synced` while workloads wait on credentials that were
  never minted, and that this is designed rather than broken
- that `git clone` working does not mean ArgoCD can read a repository

That list is the honest measure of the feature. It is not that the agent
becomes an expert; it is that it stops making a dozen specific mistakes that
cost an afternoon each.

## What it stays bad at

Stated so you calibrate rather than find out.

**It cannot tell you whether something works.** It can tell you what the
documentation says, and the documentation is careful to distinguish a
measurement from a belief. Most pages carry a "What is not certified here"
section, the grounding tells the agent to read it, and
[the testing standard](../testing-standard.md) records which documented paths an
executing gate actually covers. Ask "is this proven?" and expect a page
reference, not a yes.

**It will quote a stale number if you let it.** Nearly every count in these
docs is a dated measurement with the command that produced it printed alongside.
The grounding tells the agent to run the command instead of quoting the page. If
you get a bare number with no command, treat it as unverified.

**It has never seen your cluster.** The reference deployment behind this project
is one person's hardware with one set of choices, which is the honest limit of
what any of this has been tested against.

**It should not be running your destructive commands.** Clearing finalizers,
deleting webhook configurations, force-deleting pods and allowlisting a
`cluster-admin` binding are all documented because they are sometimes necessary,
and all of them are how a cluster gets wedged past recovery. The grounding tells
the agent to propose and explain them and leave the running to you. That
instruction is not an enforcement mechanism ... it is a request, and your agent's
own permissions are what actually decide. Set them accordingly.

## What leaves your network

This deserves a plain answer from a project that argues for owning your AI.

**If your agent runs against a hosted model, then whatever it reads goes to that
provider.** For this repository that means the documentation, which is public
already. **But an agent helping with your deployment does not stay in this
repository.** It will want your site values, your `internalDomain`, your LAN
CIDR, your address pool, your `kubectl` output, and the Application statuses and
events you paste in when something breaks. Those describe your network. An
ArgoCD status carries your site repository URL; events carry your hostnames.

That is not an argument against using one. It is the same decision
[the AI plane](ai-plane.md) makes you make about inference: sending a request
outside your network means the content goes with it, and it has a different
compliance shape from keeping it local. **The decision is yours, and Tockmox's
job is to make sure you are making it on purpose.**

Three practical consequences:

- **Redact before you paste**, especially at 1am. Hostnames, repository URLs and
  addresses are the usual leaks.
- **Never paste a credential**, sealed or otherwise, and never ask an agent to
  generate one. Credentials come from `tools/mint-secrets.sh` and go into
  SealedSecrets, which is the one place they are safe to commit.
- **A local model can read these files too.** The grounding is model-neutral and
  the documentation bundle is roughly a hundred thousand words of plain
  markdown. If you are running a model on your own hardware, nothing about this
  requires you to reach outside your network at all.

## This is not the AI plane

Two different things, and conflating them causes real confusion.

| | Where it runs | What it is for |
|---|---|---|
| **A coding agent reading this repo** | Wherever you run it. Tockmox has no idea it exists | Helping *you* install and operate the platform |
| **[The AI plane](ai-plane.md)** | On your cluster, as part of the platform | The private AI console and model gateway the platform exists to serve |

The AI plane is a capability you can decline, and it ships pointed at nothing
until you name a model host. A coding agent is a tool of yours that happens to
be pointed at a git checkout. Nothing connects them.

## When it gets something wrong

It will. The failure mode to watch for is an agent that is fluent and wrong,
because fluent and wrong reads exactly like fluent and right.

**The page wins.** If an agent tells you something that disagrees with a page
under `docs/`, believe the page. If a **skill** under
[`docs/agent-skills/`](../agent-skills/README.md) disagrees with the page it
cites, that skill is a bug in this repository and worth reporting ... a skill
that sends you down a path the documentation no longer describes is worse than
no skill, because it is believed.

**Ask for the source.** Every claim in the grounding traces to a page, and the
grounding tells the agent to cite it. An answer with no citation is a guess.

[Open an issue](https://github.com/tockmox/tockmox/issues) when you find one.
[CONTRIBUTING.md](../../CONTRIBUTING.md) says why a well-argued issue is worth
more to this project right now than a pull request, and that applies here too:
"the agent confidently told me X, and the docs say Y" is a useful report.

## For contributors

The same grounding covers changing this repository, not just deploying from it.
`AGENTS.md` carries the gate list, the rule that `tools/helm-deps.sh` runs
before anything else renders, and the six gates that have a `--selftest` mode.

**Run the whole gate suite rather than the subset you reasoned was affected**,
and enumerate the gates from `tools/check-*.sh` rather than from a list in
prose. Expect `tools/check-doc-claims.sh` in particular: it asserts countable
claims the documentation makes about this tree, so adding a page with commands
in it can move a number some other page states.

## What is not certified here

**This page describes an integration that has no test.** Nothing in CI points an
agent at this repository and checks the answers, and there is no gate that would
fail if the grounding drifted away from the pages it cites. The documentation
gates prove the links resolve, the frontmatter is valid and the countable claims
still hold; **they prove nothing about whether an agent reading these files
gives good answers.**

The `docs/agent-skills/` pages are recorded as **OPEN** in
[the executed-docs inventory](https://github.com/tockmox/tockmox/blob/main/tests/executed-docs/INVENTORY.md):
they carry commands, no gate executes them, and they were counted in that
inventory's denominator rather than exempted from it so the gap stays visible.

The claims about what a grounded agent "knows", above, are claims about **what
the grounding says**, verified against the pages it cites by a review pass on
2026-09-02. They are not measurements of any agent's behaviour.

## Next

- [`AGENTS.md`](../../AGENTS.md) ... the grounding itself. Worth reading even if
  you never use an agent; the "sharp edges" section is a good list of what
  surprises people
- [Agent skills](../agent-skills/README.md) ... the five procedures
- [The AI plane](ai-plane.md) ... the different thing, running on your cluster

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

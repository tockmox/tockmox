---
okf_version: "0.2"
type: Reference
title: "Agent skills"
description: "Index of the five task-shaped procedures a coding agent loads to help an operator install, troubleshoot, configure, air-gap or extend Tockmox."
tags: [agents, skills, index, machine, navigation]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [machine, operator, contributor]
---

# Agent skills

Five task-shaped procedures, written for a coding agent as the reader. An
operator points whatever agent they use at a clone of this repository; the agent
reads [`AGENTS.md`](../../AGENTS.md) for the ground rules, then loads the one
skill below that matches what the operator is doing.

**If you are the operator rather than the agent**, the page written for you is
[working with a coding agent](../usage/working-with-an-agent.md) ... what this
buys you, what it stays bad at, and what leaves your network when you use it.

**Load one, not five.** Each skill is self-contained and routes into the
documentation bundle for detail. Loading all five wastes context and produces
answers that blend procedures which are deliberately different from each other.

| Skill | Load it when |
|---|---|
| [Guided install](guided-install/SKILL.md) | Walking an operator from prerequisites to a signed-in console |
| [Troubleshoot an install](troubleshoot-install/SKILL.md) | Something failed, and the error names the wrong component |
| [Edit values safely](edit-values-safely/SKILL.md) | Changing configuration without breaking the upgrade path |
| [Air-gap preparation](airgap-prep/SKILL.md) | Installing with no internet access |
| [Deploy an application](deploy-an-application/SKILL.md) | Putting the operator's own workload on the platform |

## What these are, and what they are not

**These are documentation with a machine as the reader.** They carry no code, no
runtime and no model. Nothing in this directory executes, and nothing in Tockmox
loads it. The platform installs, runs, recovers and self-monitors with no agent
involved at all, which is a deliberate property and not an omission ...
[architecture § why deterministic self-monitoring](../architecture.md#why-deterministic-self-monitoring).

**Tockmox does not ship an agent.** If an agent helped you install this, it was
an agent you brought, running wherever you run it. That distinction matters
enough to state plainly here rather than leave to a release note: a platform
whose argument is that you own your AI should not quietly make a vendor's
assistant a prerequisite for operating it. Nothing here is a prerequisite for
anything.

**Every one of these is grounded in the published documentation bundle** and
nothing else. `docs/` is CC BY 4.0 and world-readable by construction, so a
skill can route into any of it without an audience question arising. Where a
skill states a fact, the page it came from is linked, and where a page says a
procedure has not been executed, the skill says so too rather than smoothing it
over.

## The rules every skill inherits

Restated in short form; the full version is in
[`AGENTS.md`](../../AGENTS.md#read-this-first-before-you-act).

1. Derive numbers from the tree, do not quote them from a page.
2. Read the "What is not certified here" section of any page you rely on.
3. Never invent a value. Four settings have no defaults on purpose.
4. Changes go in the operator's site repository, never into the cluster and
   never into this repository.
5. Assert on the artifact. A clean result and an absent result look identical.
6. Propose destructive commands; do not run them.

## If a skill is wrong

A skill that sends an operator down a path the documentation no longer
describes is worse than no skill, because it is believed. If one of these
disagrees with the page it cites, the page wins and the skill is a bug ...
[open an issue](https://github.com/tockmox/tockmox/issues), and see
[CONTRIBUTING.md](../../CONTRIBUTING.md) for why that is the most valuable thing
you can send.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

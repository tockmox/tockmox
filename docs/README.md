---
okf_version: "0.2"
type: Reference
title: "Tockmox documentation"
description: "Home of the published Tockmox documentation, organized around what you are trying to do and how deep you need to go."
tags: [index, documentation, navigation]
status: stable
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [operator, contributor]
---

# Tockmox documentation

Tockmox documentation is organized around two questions:

1. What are you trying to do?
2. How deep do you need to go?

If this is your first visit, use the task table below. If you already know the platform, jump directly to [Deployment](deployment/README.md), [Administration](administration/README.md), [Operations](operations/README.md), [Usage](usage/README.md) or [Reference](#reference).

## What are you trying to do?

| I want to… | Start here |
|---|---|
| Decide whether Tockmox is for me | [Why Tockmox?](why-tockmox.md) |
| Understand how the system works | [Architecture](architecture.md) |
| Install Tockmox | [Prerequisites](deployment/prerequisites.md) |
| See which deployment shapes a release gate runs | [Deployment shapes](deployment/deployment-shapes.md) |
| Build a new cluster for it | [Prepare a fresh cluster](deployment/fresh-install.md) |
| Install it on an existing cluster | [Prepare a cluster you already have](deployment/existing-cluster.md) |
| Finish a new installation | [Install Tockmox](deployment/install.md) |
| Sign in and send my first message | [Sign in for the first time](usage/getting-started.md) |
| See exactly what Tockmox provides | [What you get](usage/what-you-get.md) |
| Configure models and the AI plane | [The AI plane](usage/ai-plane.md) |
| Change how Tockmox is configured | [Administration](administration/README.md) |
| Operate a running installation | [Operations](operations/README.md) |
| Fix something broken | [Troubleshooting](operations/troubleshooting.md) |
| Upgrade Tockmox | [Upgrade to a new release](deployment/upgrade.md) |
| Run without internet access | [Air-gapped operation](deployment/airgap.md) |
| Back up and prove I can restore | [Backup and restore](operations/backup-restore.md) |
| Add my own application | [Adding an application](administration/adding-an-application.md) |
| Use a coding agent with the repository | [Working with a coding agent](usage/working-with-an-agent.md) |
| Contribute to Tockmox | [CONTRIBUTING.md](../CONTRIBUTING.md) |

## New installation path

For most people, the shortest path through the documentation is:

[Prerequisites](deployment/prerequisites.md)

↓

[Prepare a fresh cluster](deployment/fresh-install.md) or [prepare your existing cluster](deployment/existing-cluster.md)
(only [one deployment shape](deployment/deployment-shapes.md) is run by a release gate)

↓

[Install Tockmox](deployment/install.md)

↓

[Sign in for the first time](usage/getting-started.md)

↓

[Configure your model](usage/ai-plane.md)

↓

Read [Day-2 operations](operations/day-2.md)

The individual guides contain the checks and success conditions. Do not skip ahead when a guide tells you the order matters.

## Documentation by area

### Deployment

Everything from choosing hardware through installation and upgrades.

Start: [Deployment index](deployment/README.md)

Use this section for:

- prerequisites;
- hardware and sizing;
- fresh and existing clusters;
- virtual machines;
- profiles;
- installation;
- disconnected environments;
- verification;
- upgrades.

### Using Tockmox

The path from a healthy installation to actually using the platform.

Start: [Usage index](usage/README.md)

Use this section for:

- first sign-in;
- the capability inventory;
- chat and model routing;
- working with a coding agent.

### Administration

Configuration and intentional change.

Start: [Administration index](administration/README.md)

Use this section for:

- configuration values and compatibility;
- capabilities;
- secrets;
- identity and TLS;
- storage and networking;
- external integrations;
- customization;
- adding and removing applications;
- experimental inference and platform-management features.

### Operations

Keeping a running installation healthy and recoverable.

Start: [Operations index](operations/README.md)

Use this section for:

- routine Day-2 work;
- monitoring and alerting;
- troubleshooting;
- backup and restore;
- sealed-secrets key escrow;
- security scans;
- uninstalling.

## Understand the design

| Page | Read it when… |
|---|---|
| [Why Tockmox?](why-tockmox.md) | You are deciding whether owning this infrastructure solves a problem you actually have |
| [Architecture](architecture.md) | You want to understand the repositories, layers, dependencies, trust boundaries and GitOps model |
| [Project status](project-status.md) | You want the detailed answer to "how mature is this?" |
| [About Tockmox](about.md) | You want the project's origin, maintainer story and the gnome |

## Reference

Reference pages answer a specific question rather than form a reading path.

| Page | Use it for |
|---|---|
| [Values](values.md) | The complete values surface |
| [Frontend posture](frontend-posture.md) | Open WebUI's role, boundaries and license posture |
| [Alternatives register](alternatives.md) | Why each default component was chosen and which alternatives were considered |
| [Third-party licenses](third-party-licenses.md) | Licenses and important upstream caveats |

## Working on Tockmox

Contributor-facing documentation is intentionally separate from operator documentation.

Start with [CONTRIBUTING.md](../CONTRIBUTING.md).

The [development documentation](development/contributing-background.md) contains the background behind release gates, contribution rules, testing and documentation conventions. Coding agents should start with [AGENTS.md](../AGENTS.md) and [Working with a coding agent](usage/working-with-an-agent.md).

## How to read these docs

Commands and captured output are intended to be executable evidence, not pseudocode.

Where a procedure has a success condition, use it. Completing the command is not the same as proving the result.

Where a claim has not been executed exactly as documented, the page says so. Where something is experimental or not yet built, the page says that too.

If documentation describes a capability that does not exist, or claims evidence that cannot be found, treat that as a documentation bug.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

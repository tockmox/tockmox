---
okf_version: "0.2"
type: Reference
title: "Tockmox documentation"
description: "Index of the published Tockmox documentation bundle, grouped by deployment, administration, operations, usage and reference."
tags: [index, documentation, navigation]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator, contributor]
---

# Tockmox documentation

These pages take you from an empty cluster to a private AI stack you sign in
to, monitor, back up, prove you can restore, and extend without losing your
changes at the next upgrade.

Each of the four main sections has its own index with a reading order:
[deployment](deployment/README.md), [administration](administration/README.md),
[operations](operations/README.md) and [usage](usage/README.md).

## Start here

| Page | For |
|---|---|
| [Why Tockmox?](why-tockmox.md) | The argument, made to a skeptic. Start here if you are deciding whether this is for you |
| [Architecture](architecture.md) | How the pieces fit and why. Fifteen minutes, and it explains the shape of everything else |
| [Prerequisites](deployment/prerequisites.md) | Start here if you have decided and want it running |

## Deployment

| Page | For |
|---|---|
| [Prerequisites](deployment/prerequisites.md) | What you need before you start, what you deliberately do not, and which of the two preparation paths is yours |
| [Prepare a fresh cluster](deployment/fresh-install.md) | The recommended path: build a k3s cluster with the settings Tockmox expects, nothing left to decide |
| [Prepare a cluster you already have](deployment/existing-cluster.md) | Six checks to run against an existing cluster, each with the condition that triggers it |
| [Hardware platforms](deployment/hardware-platforms.md) | What to run it on: mini PCs, used office PCs, NAS units, and what is left out on purpose |
| [Sizing](deployment/sizing.md) | Four tiers with measured numbers, from one small box to HA |
| [Profiles](deployment/profiles.md) | Wanting less than the full stack, supported |
| [Installation](deployment/install.md) | The full walkthrough |
| [Virtual machines](deployment/virtual-machines.md) | The four hypervisor settings that break Tockmox, and where they live on Harvester, OpenShift Virtualization, vSphere and Synology VMM |
| [Registry](deployment/registry.md) | Why Tockmox does not ship one, and what to stand up instead |
| [Verifying](deployment/verify.md) | The SBOM, checksums, and the tag-signing contract |
| [Upgrading](deployment/upgrade.md) | Moving between releases |
| [Upgrading ArgoCD and k3s](deployment/upgrade-foundations.md) | What sits under the layers: when to upgrade each relative to a release bump, connected and air-gapped, and why system-upgrade-controller is documented rather than adopted |
| [Air-gapped](deployment/airgap.md) | Installing without internet access |
| [Time synchronisation](deployment/time-sync.md) | Choosing and configuring a time source when nothing can reach a public pool, what clock drift looks like, and how to verify the nodes agree |

## Administration

| Page | For |
|---|---|
| [Configuration](administration/configuration.md) | Every value, what it does, whether it is required |
| [ArgoCD](administration/argocd.md) | Why it is a prerequisite rather than a component, the install traps, and what a missing repository credential looks like |
| [Load balancing](administration/load-balancing.md) | Why exactly one LoadBalancer controller may run, and how to choose the address pool |
| [Secrets](administration/secrets.md) | Sealing secrets, rotating them, what never leaves your cluster |
| [Identity](administration/identity.md) | Single sign-on and access |
| [Customising](administration/customising.md) | The four-rung ladder, with worked examples |
| [Capabilities](administration/capabilities.md) | Functional stories you can decline, and how to decline them |
| [The values contract](administration/values-contract.md) | Which keys are promises, what breaks a major version |
| [Storage](administration/storage.md) | Which volumes are replicated, which are not, and why |
| [TLS and trust](administration/tls-and-trust.md) | The private CA, per-OS trust, and trust inside the cluster |
| [Audit logging](administration/audit-logging.md) | Who did what to the API: one host-side flag, collection already wired |
| [External integrations](administration/external-integrations.md) | DNS, firewall, inference hosts and the other equipment around the cluster |
| [Inference nodes](administration/inference-nodes.md) | Experimental: record the machines that serve models off-cluster once, and let the chart derive the gateway's routes to them |
| [Model lifecycle](administration/model-lifecycle.md) | Experimental: why a new model needs two approvals, and the separate eval gateway candidates run on |
| [The Tockmox UI](administration/tockmox-ui.md) | Experimental: the admin console for nodes and models, built from source, and exactly what its network policy lets it reach |
| [Security Posture Probe](administration/posture-probe.md) | Experimental add-on: measures whether what the cluster enforces matches what you declared, from a role that holds no write verb, and gates on the difference |
| [Adding an application](administration/adding-an-application.md) | Putting your own workload on the platform |
| [Removing an application](administration/removing-an-application.md) | Taking one back out, including the backups, site values, Authentik objects and DNS record that outlive the prune |

## Working with a coding agent

| Page | For |
|---|---|
| [Working with a coding agent](usage/working-with-an-agent.md) | **Start here.** What pointing an agent at this repository buys you, what it stays bad at, and what leaves your network when you do it |
| [Agent skills](agent-skills/README.md) | Five task-shaped procedures a coding agent loads to help you install, troubleshoot, configure, air-gap or extend Tockmox. The ground rules are in [AGENTS.md](../AGENTS.md) at the repository root |

Tockmox does not ship an agent, and nothing here is a prerequisite for anything.
These pages exist so that an agent you already use can be useful about this
platform instead of confident about it.

## Contributing to these docs

| Page | For |
|---|---|
| [Frontmatter contract](frontmatter-contract.md) | What metadata every page here carries, and why the boundary is `docs/` |
| [Releasing background](development/releasing-background.md) | The history and reasoning behind each RELEASING.md section |
| [The patch bar](development/releasing-patch-bar.md) | Full text of the patch release bar and its immutable-field check |
| [Operator gates](development/releasing-operator-gates.md) | The release steps that run outside CI, what each proves and where its evidence lands |
| [Contributing background](development/contributing-background.md) | The reasoning behind CONTRIBUTING.md's gate, shell, style and DCO rules |
| [Agents reference](development/agents-reference.md) | The full text behind AGENTS.md: sharp edges, fit assessment, directory table |
| [Project status](project-status.md) | The longer form of the README: pre-1.0 position, evidence, release table, badge notes |

## Operations

| Page | For |
|---|---|
| [Day-2](operations/day-2.md) | Routine work: scaling, node maintenance, updates |
| [Backup and restore](operations/backup-restore.md) | How backups are proven rather than assumed |
| [Escrow the sealed-secrets key](operations/sealed-secrets-key-escrow.md) | Exporting the controller key encrypted, keeping it off the cluster and current, restoring it to a rebuilt cluster, and drilling that |
| [CIS benchmark scan (kube-bench)](operations/kube-bench.md) | An opt-in weekly scan of a control-plane node, what it can and cannot see on k3s, and how to read a run |
| [Troubleshooting](operations/troubleshooting.md) | Symptoms, causes, fixes |
| [Monitoring](operations/monitoring.md) | What is watched and what pages you |
| [Uninstalling](operations/uninstall.md) | Removing Tockmox, and the things that stall it |

## Usage

| Page | For |
|---|---|
| [Getting started](usage/getting-started.md) | Your first hour: trust the CA, bootstrap Authentik, sign in, send a message |
| [What you get](usage/what-you-get.md) | The capabilities, plainly described |
| [The AI plane](usage/ai-plane.md) | Running models locally |
| [Working with a coding agent](usage/working-with-an-agent.md) | Pointing an agent you already use at this repository: what it buys you, what leaves your network, and what it stays bad at |

## Reference

| Page | For |
|---|---|
| [Values](values.md) | The full values surface |
| [Frontend posture](frontend-posture.md) | Why Open WebUI is a swappable convenience, which capabilities terminate at the gateway, and its licence terms at the shipped version |
| [Alternatives register](alternatives.md) | The default and the alternatives for each part of the stack, their licence class and Tockmox's support tier, what this release ships, and the products deliberately absent, with a dated scan |
| [Third-party licenses](third-party-licenses.md) | What the platform deploys, under whose license, and the caveats worth knowing (AGPL set, Open WebUI, Redis, open-core boundaries) |

## Conventions in these docs

Command output is **real**, captured from a running cluster. Where a value is
site-specific it is shown as `int.example.com` or similar; where it is genuine
output it is left as captured.

Anything not yet built says so. If you find a page describing something that
does not exist, that is a bug worth reporting.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

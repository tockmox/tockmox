---
okf_version: "0.2"
type: Reference
title: "About Tockmox"
description: "The project's homelab origin, why it is built this way, who maintains it, why the name, and the standard the project tries to hold."
tags: [about, origin, maintainer, name, evidence]
status: stable
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [operator, contributor]
---

# About Tockmox

Tockmox started as a homelab.

Not a demo homelab and not a miniature enterprise environment built for screenshots: the infrastructure its maintainer actually wanted in order to do local, sovereign AI development and experimentation.

The AI work needed a surprising amount around it. Identity. Storage. Certificates. Monitoring. Alerting. Backups. Network policy. A way to change configuration without slowly turning a cluster into an undocumented collection of hand edits.

Eventually the scaffolding became a project of its own.

That project is Tockmox.

## What it really is

Tockmox is the platform extracted from the maintainer's live environment and turned into something another operator can install from released charts.

The reference deployment runs those same charts through a site repository structured like the one the installer generates. The point is not that the maintainer owns an unusually elaborate homelab. The point is that the public artifact and the environment used every day are meant to remain the same thing.

There are still private site-specific applications around it. Those are not quietly treated as product capabilities. When something matures into a general capability, it can move into Tockmox. Until then, it remains a site extension.

That boundary matters.

## Why it is built this way

The platform was going to hold data its operator cared about: personal documents, writing, conversations and other material that should not casually become somebody else's copy.

So "it's only a homelab" was never accepted as a reason to omit the operational controls that would be expected in a serious environment.

Tockmox therefore borrows heavily from enterprise platform practice:

- declared configuration rather than hand-managed state;
- identity in front of user-facing services;
- network policy;
- observable infrastructure;
- alerts that reach a person;
- backups paired with restore tests;
- documented upgrade paths;
- explicit trust boundaries;
- release gates;
- and evidence attached to operational claims.

That does not make every Tockmox installation an enterprise system, and it is not a compliance claim.

It describes the engineering discipline the project tries to apply.

## Who maintains it

Tockmox is maintained by Jeff Maaks, a Solutions Architect whose work has crossed software development, databases, networking, storage, security, Kubernetes, DevSecOps, professional services, product management and technology leadership.

That breadth explains some of the project's personality: Tockmox treats the AI model as one component of a larger operational system rather than as the whole product.

It also creates an important limitation.

Tockmox is currently a one-maintainer project. There is no support desk hiding behind the repository and no implied SLA. Support is best effort, and the project documentation is deliberately explicit about what has been tested, what has only been designed, and what has not yet been proven.

Read [SUPPORT.md](../SUPPORT.md) before depending on Tockmox for something that must not break.

## Why the name?

Tockmox was Jeff's main character in World of Warcraft for years: a gnome mage who also happened to be an engineer.

When the game eventually stopped being part of daily life, the character never entirely disappeared.

So the gnome got another job.

The Tockmox mascot carries a wrench in one hand and a little green fire in the other: engineering and magic.

That is also where the project's tagline comes from:

> Magic is just well-documented engineering.

A platform that signs you in everywhere, reconciles its own configuration, watches itself and tells you when something has gone wrong can look like magic from the outside.

It isn't.

Someone had to engineer it, operate it, test the recovery path and write down how it works.

Tockmox is the gnome who wrote the documentation.

## The standard the project tries to hold

A useful claim should be narrow enough to test.

If Tockmox says something restores, there should be a restore behind the statement. If a procedure has not been executed exactly as written, the documentation should not quietly imply that it has. If something is experimental, it should say experimental. If a capability does not exist yet, the page describing it should say so.

That standard will never make the project perfect.

It does make mistakes easier to find.

If you find a claim that is broader than its evidence, or documentation describing something the release does not actually do, that is a bug worth reporting.

## Where next?

- [Why Tockmox?](why-tockmox.md) — the argument for owning the platform.
- [Architecture](architecture.md) — how it is put together.
- [Project status](project-status.md) — what is proven today and what is not.
- [Get started](deployment/prerequisites.md) — if you have already decided to try it.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

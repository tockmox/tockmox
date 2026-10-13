<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Tockmox trademark policy

"Tockmox", the Tockmox wordmark, the Tockmox gear-medallion mark (the
Tockmox gnome mascot inside a copper gear ring), and the Tockmox mascot
character are trademarks of Tockmox LLC ("the marks").

The open-source licenses covering this repository ... Apache-2.0 for code
and configuration, CC BY 4.0 for documentation ... grant copyright
permissions only. Neither license grants any right to use the marks.
Apache-2.0 states this explicitly in section 6; CC BY 4.0 in section
2(b)(2).

## What you may do without asking

- Use "Tockmox" nominatively: to truthfully state that your deployment,
  product, or article uses, builds on, or is compatible with Tockmox.
- Keep the marks intact in unmodified copies of this repository.
- Use the marks in community discussion, reviews, tutorials, and
  commentary about the project.

## What requires permission

- Using the marks (or confusingly similar names or logos) in the name of
  a fork, derived distribution, product, service, company, or domain
  name.
- Using the marks in a way that states or implies sponsorship,
  endorsement, or official status.
- Modifying the marks or combining them with your own branding.

If you distribute a modified version of this software, call it something
else and state that it is derived from Tockmox.

## The reserved namespace is part of the marks

Every component Tockmox ships carries a reserved Kubernetes prefix:
`tockmox-` (namespaces such as `tockmox-ai`, Helm release names, labels and
the resource names derived from them) and `tx-` (reserved as the short form
for the same purpose; no shipped object carries it at the 0.6.0 tree, and it
is reserved so that one can). The prefixes exist so that Tockmox-managed
objects are distinguishable from everything else in a cluster, including your
own additions, which is the mechanism that keeps an upgrade from touching what
you built. See
[configuration § namespaces](docs/administration/configuration.md#namespaces).

**The reserved prefixes are licensed under neither Apache-2.0 nor CC BY 4.0.**
They are treated as part of the marks:

- **You may** run Tockmox as shipped, with its objects under the reserved
  prefixes. That is the intended use.
- **You may** override the namespace names in your site values, as the
  configuration page describes for adopting into an existing cluster.
- **You must not** ship your own components, add-ons or a modified
  distribution under the reserved prefixes, or name your own objects so that
  they read as Tockmox-shipped. Put your additions under your own prefix.
- **You must not** present a fork or derived distribution under the Tockmox
  name or prefixes. Rename it, and rename the prefixes its objects carry, so
  that a cluster running your distribution does not look like one running
  Tockmox.

## Forks, and quality control

The value of a mark is that it tells the reader what they are getting. So the
project keeps control over what the marks are attached to:

- A fork that has not been modified may keep the marks intact, and may say it
  is Tockmox.
- A fork that has been modified in any way that changes what is deployed, how
  it is configured, or what it claims, may not be presented as Tockmox and may
  not carry the marks except nominatively ("derived from Tockmox").
- The project does not review, certify or endorse forks. A statement that a
  fork is "compatible with", "based on" or "derived from" Tockmox is a
  statement by the fork's author, not by the project, and must read that way.
- Permission to use the marks, where granted, may be withdrawn if the use
  misleads about origin, quality or endorsement.

## Add-ons

Tockmox Add-ons are standalone-capable tools published under the `tockmox`
GitHub organization that also drop into a Tockmox deployment. They inherit
this policy in full, with two specifics:

- An add-on published by the project ships Tockmox-branded, with a neutral or
  custom branding option. Running it under its shipped branding, standalone
  or inside Tockmox, is intended use.
- **A forked or modified distribution of an add-on must not identify with the
  Tockmox marks.** Rename it, remove the marks from its shipped branding, and
  say it is derived from the add-on, exactly as for the platform itself.

## Contact

Questions and permission requests: open an issue in this repository or
contact the maintainer.

<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Governance

Tockmox is governed by a single maintainer. That is a legitimate model for a
project this size, and it is written down here because an undeclared model is
not: a contributor is entitled to know who decides, on what basis, and what
happens if that person stops.

Nothing below describes a body that does not exist. There is no steering
committee, no vote, and no separate enforcement team.

## Who decides

One maintainer holds final say on scope, design, releases, and what merges.
The role is currently held by one person, who is also the copyright holder of
the original work and the owner of the marks described in
[TRADEMARKS.md](TRADEMARKS.md).

The maintainer also receives Code of Conduct reports at the address in
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). The structural limit is worth
stating: a report about the maintainer has no internal appeal, because there is
no second party to appeal to.

## How a decision is made and recorded

1. **It starts in the open.** Anything beyond a typo begins as an issue or a
   discussion, per [CONTRIBUTING.md](CONTRIBUTING.md). The reasoning belongs in
   that thread.
2. **The maintainer decides in the thread**, and states the reason. "No" with a
   reason is a usable answer; "no" without one is not, and is a fair thing to
   push back on.
3. **The record is the repository.** There is no separate decision log. A
   decision that changes behavior lands in the commit message body, which
   explains why, and in [CHANGELOG.md](CHANGELOG.md) if it is user-visible. A
   decision to reject something stays in the closed issue, which is why issues
   are closed rather than deleted.

Design principles that govern review are listed in
[CONTRIBUTING.md](CONTRIBUTING.md). They are the standard a change is argued
against, and they are the thing to argue against if you think a decision is
wrong.

## Roles

Nobody has walked this path yet. It is written down so that the first person
who wants to is not negotiating it from scratch.

**User.** Runs Tockmox. Files issues, asks questions, reports what broke. No
obligations.

**Contributor.** Has landed at least one pull request, with a DCO sign-off.
No special access; the contribution is the whole of it.

**Committer.** Holds write access to the repository. The bar is a track record
rather than a count: several merged changes, sound review comments on other
people's work, and a demonstrated instinct for the project's principles,
particularly that a value exists only if the operator must supply it. Committers
merge their own work and other people's, and they inherit the release gate,
which means validating from a clean clone. The maintainer offers the role; there
is no application, and asking is not held against anyone.

**Maintainer.** Holds final say. Adding a second maintainer is the single
highest-value change this project's governance could make, and it is available
to any committer who wants it and has earned it. See the next section for what
it would take.

## If the maintainer stops

**The bus factor is one.** If the maintainer stops, for any reason, this
project stops moving. There is no succession plan in force and no organization
standing behind it. Anyone evaluating Tockmox for something that must keep
working should plan on that basis, alongside what
[SUPPORT.md](SUPPORT.md) says about staffing.

The licenses are chosen so that this is survivable. Apache-2.0 for code and
configuration, CC BY 4.0 for documentation: both permit anyone to fork and
continue without permission from anyone. That is the actual continuity
guarantee, and it is the reason the project ships source rather than only
artifacts.

A successor, or a fork, would need:

- **The repository.** Public, and complete: the charts render from a clean
  clone with no private inputs.
- **A different name.** The marks are not licensed with the code, so a fork
  ships under its own name and states that it derives from Tockmox. See
  [TRADEMARKS.md](TRADEMARKS.md).
- **Their own infrastructure.** The domains, the package and container
  registries, and the `security@` and `support@` addresses belong to the
  maintainer, not to the license. A fork stands up its own.
- **A cluster to validate against.** The release gate is a clean-clone render
  plus a greenfield install. A fork that skips this inherits a class of bug
  that only a greenfield cluster surfaces.

Nothing in this section requires the maintainer's cooperation. That is the
point of it.

## Proposing something larger than a pull request

A change that adds a layer chart, alters the values interface across charts,
changes the security posture, or takes on a new upstream dependency is too
large to review as a diff. For those, open a discussion titled as a proposal,
covering:

1. **The problem**, stated as something that is currently painful or
   impossible, with the workaround you are using now.
2. **Why it belongs in Tockmox** rather than in your own layer on top. The
   values interface exists precisely so that most things do not need to be
   upstream.
3. **What already exists.** If an upstream project or an existing chart solves
   this, say so and explain why adopting it does not work. Building what could
   be adopted is the more common mistake.
4. **The blast radius.** What breaks for an existing deployment on upgrade, and
   what the operator has to do about it.
5. **How it will be validated.** An assertion nothing tests does not ship.

Expect discussion before code, and expect the answer to be no more often than
yes. Scope refused early is cheaper for both sides than scope reverted late.

## Changing this document

By pull request, like anything else. A change to how decisions are made is
itself a decision the maintainer makes, and it is recorded the same way.

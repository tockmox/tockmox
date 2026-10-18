---
okf_version: "0.2"
type: HowTo
title: "Skill: edit values safely"
description: "How an agent changes Tockmox configuration without breaking the upgrade path: which keys are promises, why a typo can be silent, and the render check that proves a switch did something."
tags: [agents, skills, values, configuration, capabilities, schema, machine]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [machine, operator]
---

# Skill: edit values safely

**Use this when** an operator wants to change configuration. The values
interface is the sharpest surface in this repository, and it has two properties
that make careless edits expensive: **some mistakes are completely silent**, and
**some keys are promises while others are not.**

Three pages own the detail. Route into them rather than reasoning:
[configuration](../../administration/configuration.md) for what a value does,
[the values contract](../../administration/values-contract.md) for whether it is
a promise, and [capabilities](../../administration/capabilities.md) for turning
whole functional stories off.

## The first rule: derive, do not quote

Every count on those pages is a dated measurement printed alongside the command
that produced it. **Run the command.** The contract page says so about itself:
its lists are its most rot-prone part, and it records having said "all 36
top-level keys" for a stretch while both lists had gone stale by seven keys.

Answer "is this key mine to set, and is it a promise" from the tree:

```bash
jq -r --arg k "modelGateway" \
  'input_filename + "  " + (.properties[$k].description // "NOT IN THIS SCHEMA")' \
  charts/*/values.schema.json
```

One line per layer. `Not this layer's key` means the layer accepts and ignores
it. `passed through unchanged` means it is the upstream chart's interface, not
Tockmox's. Anything else is a Tockmox key and is covered by the version number.

## Where the edit goes

**The operator's site repository. Never this repository, and never the
cluster.**

- Editing `charts/`, `ci/` or `profiles/` to solve a configuration problem is a
  fork, and it hands the operator an upgrade burden forever.
- A live `kubectl edit` is reverted by `selfHeal`. It appears to work and has
  not.

If a change genuinely cannot be expressed through values, that is a
values-interface gap, and this project treats it as a bug with priority over
features. Say so and point at [CONTRIBUTING.md](../../../CONTRIBUTING.md); it
names that report as the single most valuable thing to send.

## The four ways an edit fails silently

Every one of these lints clean, renders clean, and does nothing.

**A key set on the wrong layer.** The values namespace is shared across all nine
layers, not nine separate namespaces ... one profile file is passed to every
layer, so each layer's schema enumerates every other layer's top-level keys and
ignores them. Setting `addressPool` on the selfcheck layer is accepted. Setting
a key that exists **nowhere** is refused, which is the case that used to be
silent too.

**A typo under `global`.** `global` is open, because vendored charts read keys
nobody here controls and the contract page records why enumerating them cannot
work. So `global.internalDomian` is accepted and ignored, and the install then
derives every hostname from an empty domain. The required-field check catches
the missing value, not the typo. **Read `global` twice.**

**A typo under any other open block.** The schema root is closed, but `global`
is not the only block inside it that stays open: `apps` is open on every layer,
and each layer's pass-through dependency blocks are too. Find out which, on the
layer you are editing, rather than assuming the closed root protects you:

```bash
jq -r '.properties | to_entries[] | select(.value.additionalProperties != false) | .key' \
  charts/<the layer>/values.schema.json
```

**A misspelt component under `apps`.** Component names are the chart's keys, not
names that can be guessed ... read them out of that layer's own `values.yaml`
before setting one. And the shape is unconstrained on most layers, not only the
name: `apps.kubePrometheusStack: false` written as a bare boolean rather than
`{enabled: false}` validates and does nothing.

**A key a `values.yaml` defines and no template reads.** The schemas enumerate
what a layer *accepts*, not what it *uses*. A dead key is accepted and does
nothing. If a key is not described in the schema and not documented on a page,
treat it as absent rather than as undocumented.

By contrast, `capabilities` **is** closed and enumerates its eight names, so a
typo there is refused outright. That asymmetry is deliberate: nothing upstream
reads that block, so an unrecognised name is always a typo. It is the one block
you can rely on to catch you.

## Prove the edit did something

**This is the whole skill in one habit.** A switch that removes no object is
identical, from outside, to no switch at all.

```bash
SITE=<their-site-repo>/site/values/global.yaml

helm template t charts/tockmox-platform -f "$SITE" | grep -c '^kind:'
helm template t charts/tockmox-platform -f "$SITE" \
  --set capabilities.dataProtection.enabled=false | grep -c '^kind:'
```

The second number must be lower. **If the two are equal, the switch did
nothing** ... check the spelling, and check that no component under that
capability is pinned to an explicit `true`.

Use the operator's real site values. A layer will not render from bare defaults:
the platform layer needs `addressPool.range`, the policy layer needs
`global.lanCIDR`. And do not substitute `ci/values.yaml` for a site file when
reasoning about a real deployment ... it is a render fixture, not a site, and it
produces cross-layer answers that do not hold.

**Run `./tools/helm-deps.sh` first** if the tree has never rendered. Nothing
resolves until the dependencies do, and the error names the missing repositories
but not the fix.

## Capabilities and components: the tri-state

Eight capabilities, each a functional story that spans whatever components and
layers it takes. Each component also keeps its own switch, and the three states
are distinct:

```yaml
apps:
  garage: {}                # unset: follow the capability
  snapshotController:
    enabled: false          # off, even though dataProtection is on
  barmanPlugin:
    enabled: true           # on, even if dataProtection is off
```

**Unset is not the same as false.** A component never mentioned follows the
capability; a component named means what was said. That is why the shipped
values leave these as `{}` rather than `null`.

| `apps.<x>.enabled` | capability | result |
|---|---|---|
| unset | on | on |
| unset | off | off |
| `true` | off | **the render fails.** Nothing deploys until the contradiction is resolved |
| `false` | on | off |

**Switching a component on while its capability is off fails the render on
purpose.** An object store nothing backs up to is worse than either choice made
cleanly. If a render errors after a capability edit, read the error before
assuming a defect ... it is probably the coherence guard.

**The case this exists for:** an operator who already runs Prometheus and wants
Tockmox's ServiceMonitors for their own collector. **Decline the component, not
the capability.** Leave `observability` on and turn off
`apps.kubePrometheusStack`. Declining the capability and pinning
`apps.serviceMonitors.enabled: true` also renders (the monitors, for your
operator). Declining the capability with no monitors wanted needs
`profiles/observability-off.yaml`: platform and identity refuse to render
without it.

## Is this key safe to depend on

Ask the schema, then check the contract's named exceptions.

**Covered by the version number:** top-level keys not named after a chart
dependency, all the way down to their leaves. Removing or renaming one, changing
its type, or changing a default in a way that changes what deploys, is a major
version.

**Not the contract, though it is Tockmox's:** blocks named after a chart
dependency. What is promised is that the block exists, is named after the
dependency, and reaches that chart unmodified. The keys inside belong to a
project with its own release cadence. **But a default Tockmox ships inside such a
block is a promise** ... `open-webui.openaiBaseApiUrl` naming the gateway is
covered; `open-webui.image.repository` is not, because Tockmox does not set it.

**Explicitly not covered**, so do not build on them: rendered object names, the
order layers install in, anything inside a pass-through block Tockmox does not
set, `global` typo rejection, and the named exceptions the contract page
tabulates.

If the operator is depending on something not on that list and not obviously
Tockmox's, tell them to ask before building on it. The contract page's own words:
that is a cheaper conversation than a major version.

## Two mechanical traps

**Lists replace, they do not merge.** Adding a blueprint ConfigMap, or any list
entry, means restating the shipped entries alongside theirs. Dropping the
shipped one is how a change that looked purely additive breaks SSO.

**Some settings do not roll the pods.** `sso.clientId`, `sso.adminGroup` and
`sso.userGroup` are read at pod start, so the consoles keep the old value until
restarted ...
[day-2 § restart the consoles after an SSO change](../../operations/day-2.md#restart-the-consoles-after-an-sso-change).

## Before you hand it back

- Render both ways and show the delta, not the assertion.
- Name which layer's values file the key belongs in.
- Say whether the key is contract, pass-through, or a named exception.
- Remind them the change is not live until it is committed and pushed ... ArgoCD
  reads their values over git, so an uncommitted edit has changed nothing.
- If they reached for a Kustomize patch or a disable-and-replace, say so out
  loud. Rungs 3 and 4 of
  [the customisation ladder](../../architecture.md#the-customisation-ladder)
  are legitimate, and doing it often means a values gap worth reporting.

## What this skill will not do

- Edit `charts/`, `ci/` or `profiles/` on the operator's behalf.
- Quote a key count, an object count or a key list from a page without running
  the command that produces it.
- Promise stability for a key the schema does not describe.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

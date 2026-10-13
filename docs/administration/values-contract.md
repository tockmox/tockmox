---
okf_version: "0.2"
type: Reference
title: "The values contract"
description: "Which values keys are covered by the version number, which are not, and what counts as a breaking change."
tags: [values, contract, schema, semver, breaking-changes, helm]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# The values contract

Semantic versioning only means something over a declared interface. Tockmox
ships close to a thousand key lines across the nine layers' `values.yaml` files,
and through 0.x there was no statement about which of them were promises, so
"the values interface may change" was accurate and useless.

This page is the declaration. It says which keys are covered by the version
number, which are not, what counts as a breaking change, and what happens when
an upstream chart moves something underneath us.

## Answer it for one key, from the tree

Every statement on this page is derivable from the schemas, and the schemas ship
with the source. **Prefer these commands to the lists below**, which are a dated
snapshot and this page's most rot-prone part. Run them from the root of a
checkout; they need `jq` and nothing else.

**Is this key mine to set, and is it a promise?**

```bash
jq -r --arg k "modelGateway" \
  'input_filename + "  " + (.properties[$k].description // "NOT IN THIS SCHEMA")' \
  charts/*/values.schema.json
```

Substitute your key for `modelGateway`. One line per layer. A description
reading `Not this layer's key` means the layer accepts and ignores it; one
reading `passed through unchanged` means it is the upstream chart's interface,
not Tockmox's; anything else is a Tockmox key and is covered below.

**Every top-level key, with who owns it:**

```bash
jq -r '.properties | to_entries[] | .key + "\t" + (.value.description // "")' \
  charts/*/values.schema.json |
  grep -v "$(printf '\t')Not this layer" | sort -u
```

**How many keys each schema enumerates:**

```bash
jq '.properties | length' charts/*/values.schema.json | sort | uniq -c
```

**Measured 2026-10-07 on the unreleased 0.8.0 tree**, that last command prints `47` for
seven layers and `48` for two: `tockmox-identity` also carries `databaseBackup`
and `tockmox-observability` also carries `argocd`. The union across all nine is
**49**. It read `42`, `43` and `44` on 2026-09-29, and the AI plane's
experimental `inferenceNodes`, `modelLifecycle` and `tockmoxUi` are the last
three added (every layer but `tockmox-ai` declares them as not its key). The count is deliberately not uniform, and a page that quotes a single
number for it is wrong the moment a layer gains a key ... which is why the
command is here and the number is dated.

> **This page said "all 36 top-level keys" until 2026-09-01.** That was the sum
> of the two lists below on the day they were written, and both lists had since
> gone stale by seven keys. The number was never re-measured because nothing
> made it fail. Count it, do not quote it.

## The three kinds of key

Every top-level key in every layer is exactly one of these, and you can tell
which by looking at its name.

### 1. Tockmox keys ... the contract

**The rule:** a top-level key that is not named after a chart dependency is
ours. `jq` says so directly ... its schema description does not end in "passed
through unchanged".

Twenty-four of them (`platformNetpol` and `podSecurity` were added 2026-09-29; the count was measured 2026-09-04 on `main` and moved by those two keys):

`global`, `namespaces`, `apps`, `capabilities`, `ingress`, `sso`,
`notifications`, `modelGateway`, `brand`, `certIssuer`, `addressPool`,
`aiEgress`, `diagnosticIdentity`, `platformNetpol`, `podSecurity`,
`rbacGuardrails`,
`priorityClasses`, `alertmanagerURL`, `heartbeat`, `staleAfterSeconds`,
`garage`, `probes`, `databaseBackup`, `argocd`.

> **`aiDatabase` was on this list until 2026-09-04.** It was declared in all
> nine schemas, defaulted in the policy layer, documented in
> [the AI plane](../usage/ai-plane.md) as the gateway's database key, and read
> by no template anywhere. Its comment asserted a cross-chart invariant that
> neither side implemented: the CNPG NetworkPolicies select by
> `cnpg.io/podRole`, not by cluster name, and the ai layer's key is
> `modelGateway.database.name`, not `modelGateway.database.clusterName`. The
> key is gone and the doc points at `modelGateway.database`.

These are ours. They are covered by the version number, all the way down to
their leaves, with the exceptions listed below. If one of these changes in a way
that changes what you get, that is a major version.

### 2. Blocks named after a chart dependency ... pass-through

**The rule:** the block's name matches a `dependencies[].name` (or its `alias`)
in that layer's `Chart.yaml`. Regenerate the list with:

```bash
grep -hE '^[[:space:]]*(- name|alias):' charts/*/Chart.yaml | \
  sed 's/.*: *//' | tr -d '"' | sort -u
```

That prints dependency names and aliases together, so an aliased dependency
appears twice. The **block** is always the alias.

Twenty blocks, measured 2026-09-01 on the 0.6.0 tree:

`open-webui`, `litellm`, `kube-prometheus-stack`, `loki`, `alloy`, `authentik`,
`argo-workflows`, `cert-manager`, `metallb`, `traefik`, `longhorn`,
`cloudnative-pg`, `plugin-barman-cloud`, `snapshot-controller`, `kured`,
`prometheus-operator-crds`, `prometheus-blackbox-exporter`,
`prometheus-snmp-exporter`, `prometheus-smartctl-exporter`, `tockmox-common`.

`litellm` is an alias: the dependency is `litellm-helm` and the block is
`litellm`. `tockmox-common` is the library chart and has no values interface at
all; the block exists so a site that sets one is not surprised by a schema
rejection.

These are not Tockmox's interface. They are the upstream chart's, and Helm merges
whatever you put there into that chart.

**What Tockmox promises about them:** that the block exists, that it is named
after the dependency, and that what you write there reaches that chart
unmodified. That is all, and it is all anybody can promise: the keys inside
belong to a project with its own release cadence.

**What Tockmox promises about the defaults it ships inside them:** those defaults
are a Tockmox decision and are covered like any other. `open-webui.openaiBaseApiUrl`
naming this release's gateway is a promise (and changing it from empty in 0.8.0
cost a Breaking entry, TM-0460). `open-webui.image.repository` is not, because
Tockmox does not set it.

Upstream chart versions are pinned in each layer's `Chart.yaml` and moved
deliberately. A dependency bump that moves a key you were setting is called out
by name in the release notes; see [what an upstream move costs](#what-an-upstream-move-costs).

### 3. Keys belonging to another layer ... accepted and ignored

Here is a fact about this interface that is easy to miss: **the values namespace
is shared across all nine layers, not nine separate namespaces.**

`ci/values.yaml` and `profiles/reference.yaml` are single files passed to every
layer. So `tockmox-selfcheck` receives `addressPool`, which belongs to the
platform layer, and has to accept it. Each layer's schema therefore lists every
other layer's top-level keys and ignores them, and says so in the key's
description ... which is what makes the first command in this page's opening
section able to answer the question at all.

This is a consequence of the profile design rather than an accident, and it has
one cost worth stating: setting a key on the wrong layer is silent. Setting a key
that exists nowhere is not, which is the case that used to be silent too.

## What the schemas now enforce

Every layer's `values.schema.json` closes its root: `additionalProperties: false`,
with every top-level key enumerated and attributed. **Count them rather than
trusting a number in prose** ... `jq '.properties | length'
charts/*/values.schema.json`, and see
[the measurement above](#answer-it-for-one-key-from-the-tree) for what it printed
on 2026-09-01.

```console
$ helm lint charts/tockmox-ai -f my-values.yaml
[ERROR] values.yaml: - (root): Additional property opnWebui is not allowed
```

Before this, that typo installed a chart with the default configuration and told
you nothing.

**A misspelt component name under `apps` is caught too**, since 0.8.0 (TM-0404).
Every layer's `apps` accepts the component names that some layer declares and
nothing else, so `apps.open_webui` and `apps.openwebui` fail the render the way
`opnWebui` does:

```console
$ helm lint charts/tockmox-ai -f my-values.yaml --set apps.open_webui.enabled=true
[ERROR] values.yaml: - at '/sso': invalid propertyName 'open_webui'
  - at '': value must be one of 'addressPool', 'ai_cnpg_netpol', ...
```

**Trust the quoted name, not the path in front of it.** Helm 4.3.0 labels this
error with an unrelated block, and a different one on each run: four runs of the
command above named `/sso`, `/capabilities`, `/capabilities` and `/modelGateway`.
The key to fix is the one in quotes after `invalid propertyName`, and the list
after it is every name the layer accepts.

The list is every layer's names, not only the layer's own, because a profile is
one file passed to all nine layers (see
[keys belonging to another layer](#3-keys-belonging-to-another-layer--accepted-and-ignored)).
The cost is the same as at the root: a real component set on the wrong layer is
still silent. `tools/check-values-typos.sh` regenerates the list and fails the
build when a layer adds a component without it.

### A closed root closes the root, not the blocks under it

**What the closed root catches is an unknown top-level key.** One level down,
each block's own `additionalProperties` decides, and most Tockmox blocks are
declared open. `global` is the clearest case and is discussed below, but **it is
not the only one**, and this page said it was until 2026-09-03. List the open
blocks for a layer from the tree rather than from this page:

```bash
jq -r '.properties | to_entries[]
       | select(.value.additionalProperties == true) | .key' \
  charts/tockmox-platform/values.schema.json
```

Measured 2026-09-03 on the 0.6.0 tree, that prints fifteen blocks on the
platform layer: `global`, `ingress`, `addressPool`, `apps`, `cert-manager`,
`certIssuer`, `cloudnative-pg`, `kured`, `longhorn`, `metallb`,
`tockmox-common`, `traefik`, `garage`, `plugin-barman-cloud`,
`snapshot-controller`. Every layer prints between four and fifteen. Only
`capabilities` and `probes` (and `databaseBackup` and `argocd` where they exist)
are closed all the way down.

The pass-through blocks being open is expected; the reason is in
[the second kind of key](#2-blocks-named-after-a-chart-dependency--pass-through).
**The ones worth knowing about are the Tockmox keys.** `addressPool` and
`certIssuer` are contract keys, and a typo inside either is accepted and does
nothing, exactly the way a `global` typo is. The closed root does not protect
them. (Keys that belong to another layer carry no schema at all rather than an
open one, so the command above does not list them;
[the third kind of key](#3-keys-belonging-to-another-layer--accepted-and-ignored)
covers those.)

### `global` stays open, and this is measured rather than lazy

`global` is the block that has to stay open, because Helm gives every subchart
the whole `global` map and the vendored charts read keys we do not control:
`imagePullSecrets`, `clusterDomain`, `postgresql`, `cattle`, and around fifty
others.

Enumerating them was the first attempt. It does not work, and the reason is worth
recording: several charts pass `.Values.global` **as an object** into shared
helpers, which then index it dynamically:

```
{{ include "common.images.image" ( dict "imageRoot" .Values.path.to.the.image "global" .Values.global ) }}
```

No static analysis of the templates can enumerate what that reaches, so a closed
`global` would reject legitimate values, and every dependency bump would be a new
chance to reject a different one. The honest position is that `global` is a
shared namespace by Helm's design, so Tockmox declares its own keys there and
does not gatekeep anyone else's.

**Consequence:** `global.internalDomian` is accepted and ignored, and the install
then derives every hostname from an empty domain. The required-field check
catches the missing value, not the typo. Read `global` twice.

**Which `global` keys are declared** is the schema's `global.properties`, and it
is shorter than `values.yaml` suggests:

```bash
jq -r '.properties.global.properties | keys[]' charts/tockmox-policy/values.schema.json
```

A key present in a `values.yaml` but absent from that list is accepted by the
open block and is not part of this contract.

## What counts as a breaking change

The list below is about **`stable` keys**. A `provisional` key doing any of these
is a minor named in the release notes; an `experimental` key doing any of them is
not news. While the major version is zero, "major" here means the strongest
signal available: a minor bump carrying a migration note at the top.

Major. Requires a migration note in the release, at the top, with the action
required:

- Removing or renaming a `stable` Tockmox key.
- Changing a `stable` key's type, or narrowing what it accepts.
- Changing a `stable` key's default in a way that changes what gets deployed:
  flipping an `apps.*.enabled`, changing a namespace name, changing a storage
  class, changing a hostname prefix. Image reference leaves are excluded ... see
  [the exclusions](#exclusions-that-apply-wherever-they-appear).
- Changing which object a key affects, even if the key's name and type are the
  same.
- Adding a required key with no default.
- Tightening a schema so that values which validated yesterday do not today.

Minor. Safe to take on a running deployment, in the release notes but not at
the top:

- Adding a Tockmox key whose default preserves the current behaviour.
- Adding an `apps.*` entry that defaults to off.
- Adding a render-time guard that only fails on a configuration that was already
  producing the wrong result. These are called out individually, because a guard
  is a breaking change for anyone whose configuration is the one being caught,
  and that is the point of it.
- Bumping an upstream dependency within its own compatible range.

Patch:

- Documentation, comments, CI gates, and upstream patch bumps that move nothing
  in the values interface.

## What an upstream move costs

An upstream chart's major version can rename anything inside its block. Tockmox
cannot prevent that and will not pretend to absorb it.

The rule: **a dependency bump that moves a key Tockmox ships a default for is a
Tockmox major.** A bump that moves a key Tockmox does not set is a Tockmox minor,
named in the release notes, with the upstream migration linked.

The distinction is whether the repo was making a promise about that key. If
`values.yaml` sets it, we were.

## Deprecation

A Tockmox key being removed is announced one minor version before it goes, and
for that minor version both the old and the new key work, with the old one
producing a rendered warning where a warning is possible. Where it is not
possible, the release note is the only warning and the removal waits a full
minor cycle regardless.

Nothing is removed in a patch release.

## Not every Tockmox key carries the same promise

"Declared but not frozen" was true of the interface taken whole, and it was
coarser than the tree. Some of these keys are wired through six layers and have
not moved since the schemas were first closed; others are extension points with
no shipped consumer. Promising the same thing about both understates the first
and overstates the second.

So each Tockmox key carries a tier, in the schema, next to its description:

| Tier | What it promises | What a change costs |
|---|---|---|
| `stable` | Covered by the version number, to its leaves, minus the exclusions below | A minor bump plus a migration note at the top of the release section |
| `provisional` | Declared and documented, expected to move | A minor bump, named in the release notes, not at the top |
| `experimental` | May move or vanish | Anything, any release |

While the major version is zero, "a minor bump plus a migration note" is what a
breaking change looks like ... [SemVer](https://semver.org/) reserves the major
signal for 1.0, and this is the strongest signal available before then. A
`stable` key is not frozen in the sense of never moving. It is a key that will
not move quietly.

**A tier applies to a key and everything under it, unless something under it says
otherwise.** `certIssuer` is `provisional`, and `certIssuer.selfSigned.name` is
`stable` inside it, because that name is what every layer's `global.certIssuer`
addresses and the render fails without it.

**Read the tiers from the tree, not from this page.** The first query lists every
Tockmox key on one layer with its tier; the second lists everything promised as
`stable`, across all nine layers:

```bash
jq -r '.properties | to_entries[]
       | select(.value["x-tockmox-stability"])
       | .value["x-tockmox-stability"] + "\t" + .key' \
  charts/tockmox-platform/values.schema.json | sort

jq -r '.properties | to_entries[]
       | select(.value["x-tockmox-stability"] == "stable") | .key' \
  charts/*/values.schema.json | sort -u
```

A key with no tier is not this layer's key, or it is inside a pass-through block,
or it is undeclared ... and in all three cases it is outside this contract.

**Every key that is not `stable` carries a ruling.** `x-tockmox-stability-ruled`
is the date its tier was last decided and `x-tockmox-stability-rerule` is the
release by which it is decided again: promoted, kept with a later re-rule, or
removed. A `provisional` key is therefore a choice somebody made on a date, not a
key nobody has looked at. `tools/check-values-tiers.sh` refuses a non-stable key
missing either field, and refuses a re-rule release that is not later than the
newest release in `CHANGELOG.md`, so a ruling cannot quietly lapse. To read them:

```bash
jq -r '.properties | to_entries[]
       | select(.value["x-tockmox-stability"] // "stable" | . != "stable")
       | [.key, .value["x-tockmox-stability"],
          .value["x-tockmox-stability-ruled"], .value["x-tockmox-stability-rerule"]]
       | @tsv' \
  charts/*/values.schema.json | sort -u
```

The gate reads top-level keys only. A non-stable key nested inside a block
(`modelGateway.policyGate`) carries its parent's ruling.

### Exclusions that apply wherever they appear

Two classes are excluded from every tier above, including `stable`:

**Image reference leaves.** Any leaf holding a container image reference ... a key
named `image`, ending in `Image`, or `imageName` ... is not contract. What *is*
contract is that the key exists and that setting it works. The tags move on
Renovate's cadence and pinning the version number to them would make the version
number mean the image set rather than the interface. `global.imageRegistry` is
the deliberate exception and stays contract: air-gapped installs are addressed
through it.

**`apps.*` entries for a component you have not enabled.** Adding a new component
off by default is a minor. Turning an existing one on or off is not.

If you are relying on something with no tier and not obviously ours, ask before
you build on it. That is a cheaper conversation than a migration note.

## Before 1.0 there is no downstream ABI

The values contract is the only interface Tockmox promises. Before 1.0 there is
no application binary interface for a downstream application: **an application
you build on top of Tockmox may depend only on keys tiered `stable`.** Service
names, Secret keys, labels, authentication endpoints and the other integration
points that [adding an application](adding-an-application.md) teaches are
documented as the way to wire an app today, and they are not promised beyond the
values contract. They can move in a minor release without a migration note.

Listing those integration points with a tier each, and a gate that catches
drift, is planned for 0.9.0. Until it lands, treat anything not reached through a
`stable` key as something to re-check at every upgrade.

## What is still not covered

Stated so nobody has to find out:

- **Rendered object names.** Deployment, Service and Secret names are not part of
  this contract, though in practice they move rarely. If you are addressing one
  from outside the chart, say so in an issue and it can be promoted.
- **The order layers install in.** Sync waves are an implementation detail of the
  bootstrap and will move.
- **Anything inside a pass-through block that Tockmox does not set.**
- **Typo rejection inside any open block**, `global` for the reason above and
  every other block the `jq` in
  [a closed root closes the root](#a-closed-root-closes-the-root-not-the-blocks-under-it)
  lists, `addressPool` and `certIssuer` included.
- **A key that a `values.yaml` defines and no template reads.** The schemas
  enumerate what a layer *accepts*, not what it *uses*, so a dead key is
  accepted and silently does nothing. `global` being open means a dead key
  there is not even enumerated. If a key is not described in the schema and not
  documented on a page, treat it as absent rather than as undocumented.

## What is not certified here

The counts and the schema descriptions on this page were read from the 0.6.0
tree on 2026-09-01. **They are not a claim that the contract has been tested by
attempting a breaking change against a running deployment.** The commands above
are the check; the prose is a snapshot of what they printed.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

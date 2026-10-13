---
okf_version: "0.2"
type: Reference
title: "Capabilities"
description: "The eight functional stories a Tockmox deployment can decline, what each one owns, and how the capability switch resolves against a component switch."
tags: [capabilities, values, profiles, layers, tri-state, networkpolicy]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Capabilities

Tockmox is a base platform plus **eight capabilities you can decline**.

A **capability** is a functional story, not a piece of software. "Protect my
data" is a capability. Garage, the Barman Cloud plugin and the CSI snapshot
controller are three components that story happens to need, and choosing them
one at a time makes you answer the same question three times without ever naming
it.

So each capability is one switch, spanning whatever components it takes and
whichever layers they live in.

| I want to | Go to |
|---|---|
| See what the eight are and what each owns | [What ships](#what-ships) |
| Turn one off | [Turning one off](#turning-one-off) |
| Keep one component while declining its capability | [Overriding one component](#overriding-one-component) |
| Understand why an error refused my combination | [The combination that fails on purpose](#the-combination-that-fails-on-purpose) |
| Extend this, or add a component to a capability | [How it works](#how-it-works-for-people-extending-it) |
| Turn off a single component with no capability involved | [configuration § per-app toggles](configuration.md#per-app-toggles) |

## Why you would turn one off

Three honest reasons, and they are the reason this exists:

- **You already have it.** You run Velero, or Datadog, or Okta, or your storage
  vendor's snapshot tooling. Tockmox shipping a second one is not a feature.
- **You prefer something else.** Nothing here is the only answer, and a platform
  that makes its own choices unremovable is not sovereign in any sense worth the
  word.
- **You do not want it.** A lab, an evaluation, a machine that holds nothing you
  would miss. Shipping less is a legitimate answer and the profiles exist for it.

## What ships

| Capability | What it means | Components | Default |
|---|---|---|---|
| `observability` | What is this platform doing right now: metrics, logs, and the rules that read them | kube-prometheus-stack, Loki, Alloy, the blackbox exporter, the Prometheus operator CRDs, and every ServiceMonitor / PodMonitor / PrometheusRule this repo writes | on |
| `notifications` | Alerts that reach a person, and proof the path still works when nothing is wrong | ntfy, Apprise, the alert bridge, the heartbeat CronJob, the notification rules | on |
| `identity` | One sign-in across every console | Authentik, the SSO env Secrets, the blueprints, the brand config | on |
| `aiPlane` | A private AI console and the model gateway in front of it | Open WebUI, LiteLLM, their ingresses and database | on |
| `dataProtection` | Backups that go somewhere, and the plumbing underneath them | Garage, the Barman Cloud plugin, the CSI snapshot controller, and the docs site Garage serves (`apps.docs`, [serving static sites](serving-static-sites.md)) | on |
| `hardwareTelemetry` | Telemetry from physical hardware | the SMART exporter, the SNMP exporter | **off** |
| `workflowAutomation` | Jobs on a schedule or an event, with a console to watch them | Argo Workflows, its ingress and SSO RBAC | on |
| `networkPolicy` | Default-deny **ingress** between namespaces, plus egress containment for the chat console and, after 0.6.2, the AI namespace | every NetworkPolicy this repo ships | on |

`hardwareTelemetry` is the one that ships off, because the reference deployment
is a virtual machine: there is no physical disk to ask and no switch to poll,
and an exporter that scrapes nothing still alerts on its own absence.

The SNMP and smartctl exporters are therefore a **Capability**, not an Add-on.
They ship in this repository as part of the `tockmox-exporters` layer, and
`hardwareTelemetry` is the one switch for both. An add-on is different: a
separate chart under `addons/` that you install on its own, as with the
[posture probe](posture-probe.md). Turning `hardwareTelemetry` on adds the
exporters to the layer you already run; there is nothing else to install.

## Turning one off

**Required:** the capability name, spelled exactly as the table above spells it.
The block is closed, so a typo is refused rather than ignored ... see
[the capabilities block is closed](#the-capabilities-block-is-closed).

Set it in your site values, in the file every layer reads:

```yaml
# site/values/global.yaml
capabilities:
  dataProtection:
    enabled: false
```

That removes every component it owns, across every layer.

**Success condition:** render the affected layers and confirm the object count
drops. Reading the table below is not the check; running this is.

**YOU SUPPLY:** `SITE_REPO`, the path to your site repository clone, exported
once. It is the clone **on this machine**, not the repository URL. `SITE` is
then derived from it. A layer will not render from bare defaults ... the
platform layer needs `addressPool.range`, the policy layer needs
`global.lanCIDR`, and so on. Use the file your deployment actually uses.

```bash
export SITE_REPO=YOUR_SITE_REPO_PATH
test -f "$SITE_REPO/bootstrap/root.yaml" && echo "SITE_REPO: $SITE_REPO"
```

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
SITE="$SITE_REPO/site/values/global.yaml"

helm template t charts/tockmox-platform -f "$SITE" | grep -c '^kind:'
helm template t charts/tockmox-platform -f "$SITE" \
  --set capabilities.dataProtection.enabled=false | grep -c '^kind:'
```

The second number is lower. Measured 2026-09-01 against the 0.6.0 tree using
`ci/values.yaml` in place of a site file, the platform layer goes from 218
objects to 178.

**If the two numbers are equal, the switch did nothing**, which is the failure
this whole design exists to make visible: check your spelling, and check that no
component under that capability is pinned to an explicit `true` in your own
values. If instead the second command **errors**, read the error ... it is
probably the coherence guard telling you a component you pinned on belongs to
the capability you just declined.

### What a decline costs, measured

One capability at a time, on the reference profile:

| Declined | Objects removed | Layers affected |
|---|---|---|
| `observability` | 167 | crds, platform, identity, observability, exporters, selfcheck |
| `dataProtection` | 42 | platform, identity |
| `workflowAutomation` | 31 | devops |
| `networkPolicy` | 33 | policy |
| `identity` | 29 | identity |
| `aiPlane` | 16 | ai |
| `notifications` | 15 | observability, selfcheck |
| `hardwareTelemetry` (turned **on**) | 10 | exporters |

**Re-derived 2026-09-15 for the 0.6.0 release, by running
`tools/check-capabilities.sh` against this tree with Helm v3.16.3,
`ci/values.yaml` standing in for a site.** Six of the eight reproduced the
2026-09-07 figures exactly. Two moved, both because this release changed what
renders:

- **`workflowAutomation`, 33 to 31.** Argo Workflows now runs with
  `singleNamespace: true`, so four of its cluster-scoped RBAC objects became
  namespaced ones: ClusterRole 8 to 4 and ClusterRoleBinding 5 to 3, against
  Role 3 to 5 and RoleBinding 3 to 5. Measured by rendering the layer both ways
  rather than inferred from the change. The capability still removes the whole
  devops layer; the layer is two objects smaller.
- **`observability`, 165 to 167.** The observability layer itself gained two
  objects this release ... the same re-derivation the release notes record as
  156 to 158 ... and both sit inside the capability. That the total moved by
  exactly two is measured; that these are the same two is inference, not a
  decomposition.

**Re-derived 2026-10-08** against the 0.8.0 tree with Helm v4.3.0, after
TM-0460: `aiPlane` reads 28 (24 on the same tree the day before; the
console-key Job and its ServiceAccount, Role and RoleBinding are the four new
objects under it),
`networkPolicy` 42 (the Job's API egress rule), `observability` 194,
`dataProtection` 55, `workflowAutomation` 35, `identity` 32, `notifications`
19. The 0.6.0 figures stay in the table as the last per-release derivation;
the table is refreshed on the release, per the paragraph below.

**Re-derived 2026-09-07** against the 0.6.0 tree with Helm v3.16.1: seven of the
eight figures reproduced the 2026-09-01 measurement exactly, and `networkPolicy`
moved from 32 to 33 because `ci/values.yaml` now pairs `apps.ai_cnpg_netpol`
with `apps.litellm` (the rule that lets the CNPG operator reach the model
gateway's database), so one more policy renders under that capability. The 32
was correct for the values it was measured against; this is the table doing what
the paragraph below says it does.

**What CI asserts, and what it does not.** `tools/check-capabilities.sh` proves
each switch removes a non-zero number of objects, because a capability whose
switch removes nothing is decoration: the render succeeds, this page still
promises you can decline it, and nothing changes. That check has no opinion
about the specific numbers above, so **the table is re-derived per release
rather than enforced per commit**. Read it as a measurement with a date and a
version on it, not as a contract.

## The block is identical in all nine layers

The values namespace is shared across layers, so one profile file sets a
capability once and every layer that owns part of it reads the same answer. That
only works if the nine copies agree, so CI compares them byte for byte. Confirmed
passing on 2026-09-01 against the 0.6.0 tree.

## Overriding one component

**Optional, and it is the reason the tri-state exists.** Each component still
has its own switch, and the three states are distinct:

```yaml
apps:
  garage: {}                # unset: follow the capability
  snapshotController:
    enabled: false          # off, even though dataProtection is on
  barmanPlugin:
    enabled: true           # on, even if dataProtection is off
```

**Unset is not the same as false.** A component you never mention follows the
capability; a component you name means what you said. That is why the shipped
values leave these keys as `{}` rather than setting them to `null`: a null
condition path makes Helm warn on every render, and the schemas require an
object there.

**YOU SUPPLY:** the component key, read out of that layer's `values.yaml`. Unlike
`capabilities`, the `apps` block is **not** closed, so a misspelt component name
is accepted and does nothing. See
[configuration § per-app toggles](configuration.md#per-app-toggles) for the
worked example and the render check that catches it.

### The case this design exists for: you already run Prometheus

You want Tockmox's ServiceMonitors, PodMonitors and PrometheusRules rendered for
**your** operator to collect, and no second Prometheus beside the one you
already run. Without a component override this would have been a fork.

**Decline the component, not the capability.** Leave `observability` on and turn
off the piece you are replacing:

```yaml
# site/values/observability.yaml
apps:
  kubePrometheusStack:
    enabled: false
  # leave serviceMonitors unset: it follows the capability, which is on
```

**Success condition:** the render still contains monitors and no longer contains
a Prometheus.

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
SITE="$SITE_REPO/site/values/observability.yaml"

helm template t charts/tockmox-observability -f "$SITE" \
  --set apps.kubePrometheusStack.enabled=false \
  | grep -E '^kind: (ServiceMonitor|PrometheusRule|Prometheus|Alertmanager)$' \
  | sort | uniq -c
```

`ServiceMonitor` and `PrometheusRule` appear; `Prometheus` and `Alertmanager` do
not. Measured 2026-09-01 against the 0.6.0 tree with `ci/values.yaml` standing in
for a site file: 45 objects, of which 2 ServiceMonitors and 1 PrometheusRule,
and no Prometheus or Alertmanager.

**Or decline the capability and keep the monitors.** If the cluster already has
a Prometheus operator and you want Tockmox's monitors and rules rendered for it,
decline the capability and pin the component:

```yaml
capabilities:
  observability:
    enabled: false
apps:
  serviceMonitors:
    enabled: true
```

That renders in every layer; the coherence guard below does not apply to
`serviceMonitors`, because the component is the point and the capability is what
you declined. It was refused until 2026-10-03, which contradicted the capability
text in every layer's values (TM-0825). You bring the operator and its CRDs:
`tockmox-crds` still renders nothing with the capability off. The monitors
vendored subcharts write (cert-manager, MetalLB, Traefik, Longhorn, CNPG, kured,
the snapshot controller, authentik) stay on, which is what you want here.
`tools/check-capability-monitors.sh` asserts the route renders in all nine layers.

**Declining the capability and wanting no monitors at all** is a different
answer, and it needs `profiles/observability-off.yaml`. The capability stops the
monitors Tockmox's own templates write; a vendored subchart's values cannot read
the capability, so its monitor has to be switched off in the subchart's own key.
The platform and identity layers therefore refuse to render with the capability
off and a subchart monitor switch still on, naming each switch and this profile.
See [profiles](../deployment/profiles.md).

### The combination that fails on purpose

Switching a component **on** while its capability is **off** fails the render:

```
apps.garage.enabled is true but the dataProtection capability is off. That
leaves a component running with nothing around it to make it useful...
```

An object store nothing backs up to, or a snapshot controller nothing schedules
against, is worse than either choice made cleanly. The alternative would be to
quietly switch the capability back on, which would mean a thing you declined
returning because of one key.

CI observes this guard failing for **each owned component except one**,
individually, rather than testing one and assuming the rest. The exception is
`serviceMonitors`, the bring-your-own-operator route above, which CI observes
*rendering* instead.

### The opposite mistake, which also fails

A capability that is on with nothing underneath it:

```
capabilities.hardwareTelemetry is on, but nothing is set up to collect from the
exporters it deploys, so they would run and be scraped by no one.
```

`hardwareTelemetry` is satisfied by `observability` **or** by
`apps.serviceMonitors.enabled: true`, because the second one means something does
collect from them. Requiring the capability outright would have rejected a
configuration that works.

The second half of that "or" is reachable across a whole deployment: with
`observability` off and `apps.serviceMonitors.enabled: true`, no layer refuses
(the observability layer used to, and no longer does; TM-0825).

## How it works, for people extending it

Two mechanisms, one rule, and they agree because they were checked against each
other rather than assumed to match.

**Chart dependencies** use Helm's condition fallback list:

```yaml
condition: apps.snapshotController.enabled,capabilities.dataProtection.enabled
```

That comma is a fallback, not an `and`: Helm uses the first path that resolves to
a boolean. An absent component key therefore falls through to the capability.

**Tockmox-authored templates** call a helper, because a template cannot use a
chart condition:

```
{{- if include "tockmox.appEnabled" (dict "ctx" $ "app" "garage") }}
```

`tockmox.appEnabled` looks the component up in `tockmox.capabilityOwners`, which
is the single ownership map, and resolves the tri-state through it. Components
absent from that map are core and resolve to their own key.

**Nothing reads `.Values.apps.<x>.enabled` directly for an owned component.**
That rule is not stylistic. Making the defaults absent so capabilities could own
them turned twenty-one such reads into `nil`, which is falsy, and every ingress,
SSO Secret and blueprint belonging to an owned component stopped rendering. The
charts linted, templated and installed. Nothing said less.

Both mechanisms produce the same four outcomes:

| `apps.<x>.enabled` | capability | result |
|---|---|---|
| unset | on | on |
| unset | off | off |
| `true` | off | on, and the coherence guard fails the render |
| `false` | on | off |

An `and` between the two flags would not do this. It makes declining a capability
override a deliberate opt-in, which is backwards.

**Adding a component?** It must be owned by a capability or declared core, in
the ownership manifest, or `tools/check-capabilities.sh` fails until someone
makes that decision. On 2026-09-01 that manifest covered 42 components, 29 of
them owned, and the manifest and the chart's ownership map were identical.

## Capabilities are not layers

Worth stating because the two are easy to conflate.

| | What it is | How many | Set where |
|---|---|---|---|
| **Layer** | Install order and blast radius. Each is a Helm release, synced in waves | nine | Not a value. It is the chart you are configuring |
| **Capability** | What the deployment does. One can span several layers | eight | `capabilities.<name>.enabled`, a top-level key every layer reads |
| **Profile** | A named bundle of decisions for a whole deployment shape | see [profiles](../deployment/profiles.md) | A values file, for example `profiles/minimal.yaml` |

A capability spanning several layers is precisely why its switch cannot live
inside any single chart's `apps` block. A capability is a decision; a profile is
a bundle of decisions.

## The `capabilities` block is closed

Unlike `global`, which stays open because vendored charts read keys we do not
control, `capabilities` enumerates its eight names and rejects anything else:

```console
$ helm template . --set capabilities.observabilty.enabled=false
Error: capabilities: Additional property observabilty is not allowed
```

Nothing upstream reads this block, so an unrecognised name here is always a
typo. An ignored typo means a capability you believed you had declined is still
running, which is the failure this closes. **Verified 2026-09-01:** all nine
schemas set `additionalProperties: false` on `capabilities` and enumerate the
same eight names.

## What is not certified here

Every measurement on this page was produced on 2026-09-01 by rendering the 0.6.0
tree with Helm v3.16.3, via `tools/check-capabilities.sh`. **A render is not a
deployment.** These numbers say what Helm produces, not what a cluster does with
it: that a capability removes 42 objects from the render is not a claim that
declining it leaves a healthy cluster.

Which capability combinations are exercised by a real deploy is in the
[testing standard](../testing-standard.md).

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "Install a profile"
description: "Deploy less than the full stack: pick one of the shipped profiles, pass it to every layer, and prove it removed what you expected."
tags: [deployment, profiles, minimal, reference, capabilities, sizing]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Install a profile

Tockmox's defaults describe a reference deployment: a homelab that wants the
whole thing. Not everyone does. **A profile is a values file that wants less**,
without hand-editing nine values files and discovering which combinations do not
work.

**One thing is yours to decide:** which of the shipped profiles you want. It
is marked **YOU SUPPLY** at the point you need it. Everything else is a line to
add and a command to run.

**Already installed?** A profile is just another values file. Adding one to a
running deployment is the same edit and the same sync, and the removals take
effect the way any other values change does.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| A checkout of the Tockmox source tree | The profiles live in `profiles/`, and the render check below needs the charts | `ls profiles/minimal.yaml profiles/reference.yaml` |
| Your site repository, checked out and committable, exported as `SITE_REPO` | The change is one line per layer in your bootstrap Applications; two render checks read its values files | `export SITE_REPO=YOUR_SITE_REPO_PATH`, then `git -C "$SITE_REPO" status` |
| `helm` on your workstation | The success condition is a render, not a reading | `helm version` |
| The name of a StorageClass your cluster already has | Only if you choose `minimal`, which turns Longhorn off. Step 3 tests for this | `kubectl get storageclass` |

**Estimate, not a measurement: 10 minutes**, plus however long ArgoCD takes to
remove what you declined.

## What you will have at the end

Every layer reading the same profile file, an object count you have measured
rather than assumed, and a written-down list of what you gave up.

## 1. Choose a profile ... Required

**YOU SUPPLY:** which one. This is the only branch on the page.

| Profile | Choose it when | What it is |
|---|---|---|
| `reference.yaml` | You want the whole platform and would rather the defaults be written down than inherited | Everything on, stated explicitly |
| `minimal.yaml` | You want the AI plane and the platform under it, and do not want log aggregation, replicated storage, or an identity provider | The smallest deployment that is still Tockmox |
| `household-sso.yaml` | One node, a few people, and you want each of them to sign in once | `minimal.yaml` with Authentik and single sign-on put back. Measured on a running single-node cluster (0.8.0 lab, 2026-10-06): every layer Synced and Healthy, and a browser signed in through Authentik and got a streamed reply from a model host on the network, through the gateway (TM-0276). A household user sees no model until an administrator grants it ([identity](../administration/identity.md)) |
| `observability-off.yaml` | You already monitor the cluster elsewhere, or want neither Prometheus nor Loki, and the cluster has no Prometheus operator CRDs | Declines the observability capability and turns off every vendored subchart's own monitor switch. **Add it after another profile; it does not replace one.** Without it, the platform and identity layers refuse to render with the capability off. Measured on a cluster with no Prometheus operator CRDs (0.7.1-rc2 gate): every layer synced. **Your own site applications must leave their monitors out too**: a ServiceMonitor in `apps/` stops `site-apps` with "could not find monitoring.coreos.com/ServiceMonitor" (TM-0825) |

**None of them is a fork, and none is a separate product.** Each is a file in
`profiles/`, each sets keys you could set yourself, and reading one tells you
exactly what it does. "Most of `minimal` but keep Authentik" is now
`household-sso.yaml`; for any other shape, write your own file: that is the
supported outcome, not a workaround.

**Profiles and capabilities are two different tools.** A
[capability](../administration/capabilities.md) is one switch for a functional
story spanning several layers. A profile is a file that sets whichever switches,
component toggles and upstream values a particular shape needs. `minimal.yaml`
uses component-level `apps.*` keys rather than capability switches, because it
turns off some of a capability's components and keeps others.

**Success condition:** you can name the file you are about to pass, and it
exists:

```bash
ls -l profiles/minimal.yaml
```

## 2. Pass it to every layer ... Required

The profile goes in the `valueFiles` list of **every** layer Application, after
your globals and before your per-layer overrides, so a per-layer file can still
win. **How you get the file there is a choice**, and it is a choice because of
how ArgoCD resolves a `$name` prefix: the name must be declared by a source with
a `ref` field, and the Applications `tockmox-install.sh` generates declare
exactly one, `ref: site`, pointing at your site repository.

| Option | Do this | Choose it when |
|---|---|---|
| **Copy the profile into your site repo** (fewest moving parts) | Copy `profiles/minimal.yaml` to `site/values/profile.yaml` and reference it as `$site/site/values/profile.yaml` | You want the shape the installer already generates, with no new source |
| **Reference it from the Tockmox repo** | Add a third source carrying `ref: tockmox`, then reference `$tockmox/profiles/minimal.yaml` | You want the profile pinned to the Tockmox tag rather than copied and forgotten |

The copy route, in a generated Application:

```yaml
sources:
  - repoURL: https://github.com/tockmox/tockmox.git
    targetRevision: v0.8.1
    path: charts/tockmox-ai
    helm:
      valueFiles:
        - $site/site/values/global.yaml
        - $site/site/values/profile.yaml     # <-- here
        - $site/site/values/ai.yaml
  - repoURL: YOUR_SITE_REPO_URL
    targetRevision: main
    ref: site
```

The reference route needs the extra source, in the same shape as `ref: site`:

```yaml
sources:
  - repoURL: https://github.com/tockmox/tockmox.git
    targetRevision: v0.8.1
    path: charts/tockmox-ai
    helm:
      valueFiles:
        - $site/site/values/global.yaml
        - $tockmox/profiles/minimal.yaml     # <-- here
        - $site/site/values/ai.yaml
  - repoURL: YOUR_SITE_REPO_URL
    targetRevision: main
    ref: site
  - repoURL: https://github.com/tockmox/tockmox.git
    targetRevision: v0.8.1
    ref: tockmox                             # <-- and this
```

**`YOUR_SITE_REPO_URL` is not a value.** It is whatever your generated
Applications already carry in the `ref: site` source; copy it from there rather
than typing it.

One file covers all nine layers. Each chart reads the keys it recognises and
ignores the rest ... the values namespace is shared across the layers, which is
what makes a single file work. Why that is so, and what it costs, is in
[the values contract](../administration/values-contract.md#3-keys-belonging-to-another-layer--accepted-and-ignored).

**Every layer, not the ones you think are affected.** A profile that reaches
eight of nine layers leaves the ninth rendering the reference deployment, and
nothing reports that as wrong.

**Success condition:** count the layer Applications and count the profile
references. The two numbers match:

Both greps read **your site repository**, not the Tockmox checkout, which is why
they are anchored on `$SITE_REPO` rather than on the directory you happen to be
standing in:

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
grep -l 'path: charts/tockmox-' "$SITE_REPO"/bootstrap/applications/*.yaml | wc -l
grep -lE 'values/profile\.yaml|profiles/minimal\.yaml' \
  "$SITE_REPO"/bootstrap/applications/*.yaml | wc -l
```

**If the second number is lower, ArgoCD will still report every Application
Synced**, because a layer rendering the reference deployment is a valid render.
The count is the only thing that catches it before the object count does.

## 3. Name a StorageClass ... Conditional

**If** `helm template` refuses to render the platform layer with a message about
`global.storageClass`, do this. The test:

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
helm template t charts/tockmox-platform \
  -f "$SITE_REPO/site/values/global.yaml" \
  -f profiles/minimal.yaml >/dev/null && echo "renders: nothing to do"
```

`minimal.yaml` turns Longhorn off and already sets `global.storageClass:
local-path`, which is k3s's own provisioner. **If your cluster's provisioner has
a different name, set yours** in your site globals, which are read before the
profile:

```yaml
# site/values/global.yaml
global:
  storageClass: <A CLASS FROM kubectl get storageclass>
```

**Why the render refuses instead of installing.** Turning Longhorn off while
`global.storageClass` still names `longhorn` would leave every
PersistentVolumeClaim `Pending` with nothing in the cluster explaining why. The
platform layer fails the render instead, which is the one incoherent combination
a profile can catch. Everything else in the tables below is a trade you are
making knowingly.

**Success condition:** the command above prints `renders: nothing to do`.

## 4. Prove it removed something ... Required

Reading the tables below is not the check. Running this is:

```bash
: "${SITE_REPO:?export SITE_REPO first, see Before you begin}"
SITE="$SITE_REPO/site/values/global.yaml"

helm template t charts/tockmox-platform -f "$SITE" | grep -c '^kind:'
helm template t charts/tockmox-platform -f "$SITE" \
  -f profiles/minimal.yaml | grep -c '^kind:'
```

**Success condition:** the second number is lower than the first. **If they are
equal, the profile is not being read** ... check the path in `valueFiles`
resolves against the source you named it under, and check that nothing in your
per-layer file pins a component back on.

Repeat for whichever layers you care about. The same technique, applied to a
single capability rather than a profile, is in
[capabilities § turning one off](../administration/capabilities.md#turning-one-off).

## What reference and minimal cost and save

**Measured on the render, from a clean clone, 2026-08-15.** Not re-derived
since; treat as a measurement with a date on it rather than a current fact.

| | reference | minimal | delta |
|---|---|---|---|
| Kubernetes resources | 451 | 352 | **-99** |
| Containers | 102 | 75 | **-27** |
| Distinct images | 46 | 31 | **-15** |

Distinct images counts every image reference in the render: the mirror list
`images.txt` plus two upstream `helm test` hook images. **`images.txt` carried
44 entries when checked on 2026-09-01**, which is what makes the reference row
46. Mirror from `images.txt` itself, not from this row:

```bash
HASH=$(printf '\043')
grep -vc "^[[:space:]]*$HASH" images.txt
```

**The first line builds a comment character rather than typing one**, and that
is the point: `images.txt` carries a three-line header this count has to skip,
so the pattern genuinely needs a `#` ... but a literal `#` anywhere inside a
`bash` block is refused by
[`tools/check-pasteable-blocks.sh`](../../tools/check-pasteable-blocks.sh),
because an interactive macOS zsh does not treat it as a comment. `printf '\043'`
is the POSIX octal escape for it. Both forms return **44** against the
`images.txt` in the 0.6.0 tree, checked 2026-09-11.

The image count is the one to care about for an air-gapped site: fifteen fewer
images to mirror, verify and carry.

**Memory, projected rather than measured.** The reference figure below is
observed on a running one-node cluster; the minimal figure subtracts the
observed usage of the components the profile removes. It is arithmetic on real
numbers, not a measurement of a minimal deployment, and it is stated that way
on purpose.

| | Memory |
|---|---|
| reference, **observed** | ~9.8Gi across ~65 running containers |
| minimal, **projected** | ~7.5Gi |
| saving | ~2.3Gi, about a quarter |

Neither is a production sizing guide. Both are a lab under no load. Prometheus
alone was 1.5Gi when measured and grows with your series count; plan against
your own observation. The four tiers, and the hardware behind each, are in
[sizing](sizing.md).

The bigger saving is one the table cannot show. Loki's chunks and Prometheus's
TSDB are the two components whose disk use grows without bound, and `minimal`
removes one entirely and cuts the other's retention from 30 days to 7.

## What `minimal` takes away

Each of these is a real loss, and the profile says so in its own comments too.

| Removed | Key it sets | Consequence |
|---|---|---|
| Loki, Alloy | `apps.loki`, `apps.alloy` | No log aggregation. `kubectl logs` still works; nothing retains logs after a pod dies |
| Longhorn | `apps.longhorn` | No replicated storage. A rescheduled pod finds an empty volume. `global.storageClass` must name your cluster's provisioner |
| Authentik, SSO | `apps.authentik`, `sso.enabled` | Every console uses its own local login. Break-glass accounts become the accounts |
| Metric history | `kube-prometheus-stack.prometheus.prometheusSpec.retention` and `.scrapeInterval` | 7 days instead of 30, scraped every 60s instead of 30s. Half the resolution |

Read `profiles/minimal.yaml` for the full set. Most of the file is comments
explaining the trade, which is deliberate: a profile you cannot read is a fork
you did not know you took.

## What neither profile touches

The floor. The policy layer, the CloudNativePG operator and the backup path,
cert-manager and the TLS on-ramp, Traefik, Prometheus and Grafana, the
self-check spine, and the AI plane, the model gateway included.

**The model gateway is on in every profile since 0.8.0** (TM-0460, ruled
2026-10-08): `apps.litellm` follows `capabilities.aiPlane`, the console goes
through it on a key the chart mints, and neither profile sets it. It costs the
proxy and a one-instance CloudNativePG, about 0.5Gi, which the projected
figures above do not separate out (the ~1.9Gi AI-plane line below is the whole
plane). A profile that kept the gateway off would make "required" true for
the reference deployment only, which is the sentence the ruling closed.

**A Tockmox that cannot prove a restore is not Tockmox**, so nothing a profile
does removes the backup machinery. Alerting stays for the same reason: it is
the evidence half of the self-check spine, and it delivers through ntfy or
Apprise whether or not you keep Loki.

## Going further, and where to stop ... Optional

The next two things worth reaching for, with what they return and what they
cost. **The memory figures are the same projection as the table above and were
not re-derived.**

| Change | Key | Returns | What you lose |
|---|---|---|---|
| Turn the AI plane off | `capabilities.aiPlane.enabled: false`, the whole story at once; or `apps.openWebui.enabled: false` and `apps.litellm.enabled: false` together, in `global.yaml` (turning the gateway off alone also needs `open-webui.enableOpenaiApi: false`, because the console's shipped default points at it; [the AI plane](../usage/ai-plane.md#running-without-the-gateway)) | ~1.9Gi | The AI plane. On an AI platform |
| Turn Grafana off | `kube-prometheus-stack.grafana.enabled: false` | ~0.6Gi | Metrics collected, nothing to look at them with |

**Grafana's switch is a pass-through key, not a Tockmox one.** Grafana is a
subchart of `kube-prometheus-stack`, so the key belongs to that chart's
interface and is covered by
[the pass-through rule](../administration/values-contract.md#2-blocks-named-after-a-chart-dependency--pass-through)
rather than by Tockmox's version number ([history](#history-two-keys-this-page-named-wrongly)).

Both changes are deliberately comments in `minimal.yaml` rather than settings.
They are below the line where this stops being a useful platform, and a profile
that crosses that line should be yours to write rather than ours to bless.

## History and corrections

What this page used to say, and when it changed. Nothing here is needed to follow the page.

<a id="history-two-keys-this-page-named-wrongly"></a>

### Two keys this page named wrongly

Until 2026-09-01 the profile snippet showed `$tockmox/profiles/minimal.yaml`
with no `ref: tockmox` source, and so did the header comment in
`profiles/minimal.yaml`; nothing in the tree declares that ref (checked
2026-09-01 on the 0.6.0 tree, `ref:` appears only as `ref: site`), so an
Application copied from the old snippet had a value file ArgoCD could not
resolve. The same pass found this page naming an `apps.grafana` key that
exists in no layer; Grafana's switch is a pass-through key on
`kube-prometheus-stack`.

## What is not certified here

A profile is a starting point that is known to render and known to be coherent.
**It is not a claim that the result suits you**, and it is not a claim that this
page has been executed start to finish as written. The render guard in step 3 is
the honest limit of what a profile can check for you.

The render and image counts above carry their measurement date. Documented
procedures are verified by running them, not by reviewing them ... the
[testing standard](../testing-standard.md) says which paths are covered and
which are not yet.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

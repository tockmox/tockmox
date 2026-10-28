<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Add-ons

An add-on is a chart that lives beside the nine layers and is installed on its
own. It is not a layer: nothing in the platform depends on it, RELEASING.md's
version bump does not touch it, and a failed run of an add-on never changes a
running service.

**This is a first-party contract.** It describes what the add-ons Tockmox itself
ships promise, and it is checked by a gate. It is not an interface for writing
your own: the extension point stays internal (TM-0329 closed on that), and no
third-party add-on is promised until someone asks for one. If that changes, the
third-party contract is a separate piece of work with its own review of what an
outside add-on may not do.

| Add-on | Stability | What |
|---|---|---|
| [`posture-probe/`](posture-probe/README.md) | experimental | measures whether what the cluster enforces matches what you declared |

## The manifest

Every directory under `addons/` carries an `addon.yaml`. It is the one place the
add-on's promises are written as data, so a gate can hold the add-on to them and
a console can read them without parsing prose. The format is version 1; a field
the format does not name is refused, so a typo is an error and not a silent
omission. [`posture-probe/addon.yaml`](posture-probe/addon.yaml) is the first
instance and the worked example.

| Field | Says | Checked against |
|---|---|---|
| `manifestVersion`, `owner` | the format version (1) and who ships the add-on (`first-party`) | the gate |
| `name`, `chart.version`, `stability` | identity; equal to the directory, `Chart.yaml` and its `tockmox.com/stability` annotation | `Chart.yaml` |
| `docs` | the page an operator reads | the file existing |
| `settings` | the settings schema (below) and that the add-on is off by default | `values.schema.json`, `values.yaml`, an empty default render |
| `adminUi` | `code: none`, `exposes: none` (below) | the tree and the enabled render |
| `operations` | the operations contract (below) | the enabled render, where a render can say |
| `render.set` | the values that switch the add-on on for a CI render | the gate's own `helm template` |

## The settings schema

The chart's `values.schema.json` is the add-on's whole settings surface. It is
closed (`additionalProperties: false`), so a mistyped key is refused instead of
ignored. **Every top-level key is ruled the way a layer's key is**: it carries
`x-tockmox-stability` (`experimental`, `provisional` or `stable`), and any key
that is not `stable` carries `x-tockmox-stability-ruled` (the date its tier was
decided) and `x-tockmox-stability-rerule` (the release by which it is decided
again). `tools/check-values-tiers.sh` reads `addons/*/chart/values.schema.json`
beside `charts/*/values.schema.json` and refuses an add-on key with no tier, no
ruling, or an overdue re-rule, and, once a key is `stable`, a move that the
release notes do not announce. The tiers mean what
[the values contract](../docs/administration/values-contract.md) says they mean.

## No code in the admin origin

An add-on contributes data: its settings schema, its report, its objects in the
cluster. It never contributes code that the admin console would load or run, and
it never adds a route to the cluster. In practice:

- the add-on tree holds no script, page, stylesheet, WebAssembly module or SVG
  (`.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.tsx`, `.html`, `.htm`, `.css`, `.wasm`,
  `.svg`, `.vue`);
- the enabled render holds no Ingress, IngressRoute, HTTPRoute or other
  Gateway-API route, and no Service of type LoadBalancer or NodePort;
- a console that shows an add-on renders it from the settings schema with its own
  components. Code that arrived from an add-on does not run with the console's
  session.

The reason is the trust boundary. The admin origin holds the operator's session;
code from anywhere else running there is a way past every control around it.

## The operations contract

What an operator can rely on, in the `operations` block. Each line is a claim the
gate checks against the render where a render can check it; the rest is held by
the add-on's own gate, named in `access.safetyGate`.

| Field | Contract |
|---|---|
| `install` | `mode: standalone-application`: its own Argo CD Application or `helm install`, never a layer. Its own `namespace`, a DNS label. `needs` lists what must be present first, empty when nothing |
| `access` | `kubernetesApi` is `none` or `read-only`. Read-only means no verb outside get, list and watch, plus create on `selfsubjectaccessreviews` and `selfsubjectrulesreviews` (they return a verdict and change nothing). Read-only access names a `safetyGate` that exists on disk |
| `containment` | `touchesRunningServices: false`; `egress` is `none` or `declared-endpoints-only` |
| `data` | every PersistentVolumeClaim the add-on renders, with `sensitive` and `backedUp`. A claim that renders and is not declared is refused, and so is a declared claim that does not render |
| `observability` | what the add-on gives the platform: `metrics` (`none` or `servicemonitor`), `alerts` (`none` or `prometheusrule`), `logs`. Claiming none and rendering a ServiceMonitor or PrometheusRule is refused, and so is the reverse |
| `upgrade` | `versioning: own-chart-version`; `path` is `replace-chart-version` or `documented-migration` |
| `removal` | the page that says how, and `leaves`: everything removal keeps behind, each declared in `data` |
| `support` | `experimental` exactly when `stability` is `experimental` |

An add-on is off until enabled: `enabled: false` in `values.yaml`,
`settings.defaultEnabled: false`, and an empty default render.

## How this is enforced

| Gate | Holds |
|---|---|
| `tools/check-addon-manifest.sh` | the manifest, its agreement with the chart, off by default, no code in the admin origin, the operations contract against the render. `--selftest` plants one violation per rule and requires red |
| `tools/check-values-tiers.sh` | every settings key is tiered and ruled; a stable key does not move unannounced. `--selftest` includes a planted unruled key under an add-on |
| the add-on's own gate (for `posture-probe`, `tools/check-posture-probe.sh`) | whatever its `safetyGate` promises, for example the exact verbs of a read-only role |

## Adding an add-on

1. Create `addons/<name>/` with `chart/` (a `Chart.yaml` annotated
   `tockmox.com/addon: "true"` and `tockmox.com/stability`, a closed
   `values.schema.json` with every key tiered and ruled, a `values.yaml` with
   `enabled: false`).
2. Write `addons/<name>/addon.yaml` from the posture probe's.
3. Write the operator page and name it in `docs`.
4. Run `./tools/check-addon-manifest.sh` and `./tools/check-values-tiers.sh`.

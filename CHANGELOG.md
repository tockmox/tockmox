# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [semantic](https://semver.org/spec/v2.0.0.html).

Breaking changes come first in their release, in their own section, each with
the action required beneath it. Entries are bullets: what changed and what it
costs you, with the reasoning in the documentation rather than here.

## [Unreleased]

### Breaking

- **Breaking: Authentik runs on CloudNativePG on a fresh install, and an
  install on the bundled PostgreSQL must choose before it upgrades.** The
  identity layer now renders Authentik's database as a CloudNativePG cluster,
  `tockmox-authentik-db` (PostgreSQL 18), with WAL archived to the shipped
  object store under `cnpg/authentik`, a nightly base backup kept 30 days, a
  weekly restore drill that checks Authentik's users came back, and
  `TockmoxIdentityDatabaseUnbacked` when its backups are off
  (`identity.database`, on by default). The vendored chart's bundled
  PostgreSQL (`authentik.postgresql.enabled`) is now off by default, and the
  nightly `pg_dump` bridge renders only while it is on. It needs a new Secret,
  `tockmox-authentik-db`, which `tools/mint-secrets.sh` writes on a fresh
  install. **Action, for an install that runs the bundled server:** add
  `identity.database.enabled: false` and `authentik.postgresql.enabled: true` to
  `site/values/identity.yaml` in the same commit as the bump, which renders the
  0.8 shape unchanged. Without them the identity sync fails before anything is
  applied, on a PreSync guard that finds the bundled server's volume, rather
  than starting Authentik on an empty database. Moving the data across later is
  `docs/deployment/upgrade.md`, "Move Authentik's database to CloudNativePG",
  **not yet proven on a populated install** (planned for 0.9.1); the new
  Secret's command for an install minted before 0.9.0 is in
  `docs/administration/secrets.md`. A site that brought its own PostgreSQL sets
  `identity.database.enabled: false` and keeps its host.

### Added

- **Platform Management shows the agents' cases.** With
  `features.platform.specialistsUrl` set to a specialist host (and
  `secrets.platformSpecialistsToken` for its read-only caller), `/platform/cases`
  lists every incident, problem, change and known error the Service Desk holds:
  what each waits on (you, an agent, a linked record), since when, and which
  agents worked it; each role's page lists its pending and recently closed
  cases, and a case page shows every step with no model-written text. The role
  catalog gains a generated `specialists` field
  (`tools/gen-platform-specialists.py`) and `/platform/specialists` shows which
  are built and which the host serves. Off unless the URL is set. See
  `docs/administration/platform-management.md`, "Cases".
- **Every mlx-lm instance on an AI node serves only its own model.** The toolkit
  now starts `mlx_lm.server` under a request guard: a request naming another
  model is answered 404 and one naming adapters or a draft model 400, with
  nothing loaded, and `/v1/models` lists only the instance's id. The new
  `engines.mlx-lm.maxOutputTokens` caps what one request can generate (mlx-lm
  otherwise lets a request's `max_tokens` replace `--max-tokens`). The instances
  restart once on the first converge. The guard wraps internal mlx-lm handlers,
  so it runs only on a release the toolkit tested it on (0.32.2); pinning
  another release stops the converge. See `docs/administration/ai-nodes.md`,
  "The mlx-lm request guard".
- **AI nodes can run mlx-lm with a vetted toolkit patch.** `engines.mlx-lm.patches`
  names patches the toolkit ships for exactly the pinned release; each change
  starts from a clean reinstall and restarts the instances once, and a name with
  no patch for the pinned version stops the converge. The first,
  `batch-decode-eval-cache` for 0.32.2, stops batched engines dying at Metal's
  resource limit under sustained load. See `docs/administration/ai-nodes.md`,
  "Engine patches".
- **Prometheus, Alertmanager, Longhorn and the Traefik dashboard can be routed
  behind Authentik (forward-auth).** Each is still off by default. Turning one on
  takes two values: `sso.forwardAuth.apps.<console>.enabled` in the identity
  layer (a per-console proxy provider, tile and group binding, `admin` by
  default) and `ingress.apps.<console>.enabled` in the layer that serves it. The
  Traefik dashboard gets its own Host-matched route (`ingress.apps.traefik`,
  platform layer); the port-forward break-glass stays. A route turned on with
  the identity capability off fails the render; `forwardAuth: false` routes it
  without Authentik. Once any console is on, the identity layer owns the embedded
  outpost's provider list: name your own proxy providers in
  `sso.forwardAuth.keepProviders` or they are detached. See
  `docs/administration/identity.md`, "Consoles behind forward-auth".
- **The Tockmox UI can be registered by the identity layer** with
  `sso.apps.tockmoxUi.enabled: true` (off by default): a blueprint with the
  invalidation flow that makes Sign out end the Authentik session and the
  post-logout redirect URI. It needs `TOCKMOX_UI_CLIENT_SECRET` in a new
  `tockmox-sso-tockmox-ui` Secret in the Authentik namespace first, or every SSO
  blueprint stops applying; `tools/mint-secrets.sh --with-tockmox-ui` writes it.
  `docs/administration/tockmox-ui.md` has the order and the command for an
  install minted before 0.9.0.
- **An Argo CD portal tile, off by default** (`sso.links.argocd`), and a recipe
  for giving Argo CD a hostname and Authentik sign-in in
  `docs/administration/argocd.md`.
- **Signing out is documented per console** in
  `docs/administration/identity.md`: signing out of Authentik does not sign you
  out of the consoles, and the page says what does.

- **AI nodes can be managed from git (experimental).** `ai-node/` is
  `tockmox-ai-node`: a bootstrap script and a converger that keep an
  Apple-silicon Mac's engines, firewall, memory ceiling and model store at what
  the site repo says. Desired state is generated from `inferenceNodes` and
  `modelLifecycle` into `ai-nodes/<id>/desired.yaml`
  (`python -m app.ai_nodes render`, with a stale check for CI). The node pulls,
  verifies commit signatures against signers pinned at bootstrap (warn first,
  then enforce) and has no listening control port. Linux nodes are not
  supported yet. See `docs/administration/ai-nodes.md`.
- **The Tockmox UI can enroll a Mac and show its convergence.** Adding an Apple
  silicon node offers "Enroll for GitOps": the bootstrap one-liner, the
  inventory change with `management: {enrolled: true}`, and the node's
  `ai-node.yaml`. Enrolled nodes get Convergence and Readiness panels read from
  Prometheus (a node that has not reported reads Unknown) and three alerts.
  Import-only nodes are unchanged. New engine ids `omlx` and `vllm-mlx`; M5
  hardware presets.
- **Model lifecycle: the Models page now recommends candidates per alias class
  for a node,** with the memory arithmetic shown (exact weights and cache from
  the watcher's new `sizes` section, or an estimate it labels), and never
  admits anything itself. Moving a model between nodes is a re-placement that
  no longer retires it, a brand-new alias is promoted on absolute bars,
  verdicts hash the result files they cite and CI recomputes the hashes, and
  the PR opener can open evidence PRs under `evals/`. New: `watch.sizes`,
  `recommend`, `resultsDir`. The watcher makes two more Hugging Face requests
  per model.
- **A NOC overview board, `Tockmox / Overview`.** One page for whether the
  platform is working, how full it is, and what AI costs: a verdict that needs
  Alertmanager's Watchdog (Unknown, never green, when the alert pipeline is
  down), alerts, GitOps, scrape and probe health, nodes, restore-drill age,
  capacity, certificate expiry, the share of AI requests served locally,
  frontier spend, gateway errors and latency, key budget, and restricted
  traffic served off-site. Absent metrics read grey, not 0. Generated by
  `tools/gen-dashboard-overview.py`. See `docs/operations/monitoring.md`.
- **Platform Management (experimental, off by default).** A read-only page in
  the Tockmox UI, `/platform`, that shows the platform's operations as roles
  named after ITIL 4 practices (a Platform Manager leading Incident, Capacity,
  Continuity and others), the scheduled work each owns and the numbers each
  watches. Absent data reads Unknown, never healthy; work no role owns is
  listed. Turn it on with `tockmoxUi.config.features.platform.enabled`; it adds
  one Kubernetes permission (list on Argo CronWorkflows), and nothing when off.
  A site can replace the catalog (`tockmoxUi.platformCatalog.configMap`) and
  connect an agent ledger (`ledgerUrl`, `secrets.platformLedgerToken`). Tockmox
  still ships no agent. See `docs/administration/platform-management.md`.
- **The kured reboot gate has a printed answer and a check.**
  `docs/operations/monitoring.md` gives the `alertFilterRegexp` to use, built
  from one `block` or `pass` decision per alert Tockmox authors
  (`tools/kured-gate.txt`). `tools/check-kured-gate.sh` fails the build when an
  alert has no decision, when a decision names an alert that is gone, or when the
  printed regexp drifts. Defaults are unchanged: the gate stays off until a site
  sets `prometheusUrl` and the regexp.
- **Two CloudNativePG alerts.** `TockmoxCNPGInstancesNotReady` fires when a
  cluster has fewer ready instances than it asks for, including when none is
  ready. `TockmoxCNPGScrapeTargetAbsent` fires when a cluster exists and has
  no Prometheus scrape target. A hibernated cluster fires the first.
  kube-state-metrics gains `tockmox_cnpg_cluster_desired_instances`. The first
  is a `block` in the kured reboot gate.
- **Loki's single replica is documented, with a way past it.** Loki stays one
  pod on a local volume by default, and the Loki chart already refuses a second
  replica on the filesystem. `ci/values-loki-ha.yaml` is three replicas on an
  object store such as the shipped Garage, and `tools/check-loki-ha.sh` renders
  it. No lab run has shown it surviving a node loss yet. See
  `docs/operations/monitoring.md`.

- **A deployment-shape table says which shape a release gate runs.**
  [`docs/deployment/deployment-shapes.md`](docs/deployment/deployment-shapes.md)
  sorts every way of running Tockmox into three rows: **gated** (one shape, a
  single node on openSUSE MicroOS with k3s as a virtual machine on SUSE
  Harvester, x86_64), **documented, not gated** (the three-node HA tier, a
  single conventional Linux node, an existing cluster, the other hypervisors)
  and **neither** (Proxmox/KVM, Tockmox on OpenShift itself, managed cloud,
  arm64). Every install page that names a shape now links to it, and
  `tools/doc-claims.txt` fails when a page that names one does not. Pages that
  called Proxmox or a cloud "supported" or "tested" no longer do. The platform
  chart's README listed components it does not contain (kube-vip, CoreDNS
  tuning) and omitted ones it does; it now lists what the chart renders.
  Nothing to do on upgrade.

- **Bring your own certificate authority is a documented path.**
  [`bring-your-own-ca.md`](docs/administration/bring-your-own-ca.md) seals an
  operator's CA key into the site repository, applies a ClusterIssuer named
  `site-ca`, points `global.certIssuer` at it and proves the result, with no
  chart change. It says what a rebuilt cluster does to the chart's own CA
  (mints a new one, so every trusting machine must re-trust) and why a supplied
  CA avoids that. The procedure has not been run by the executed-docs harness
  or by hand; the page says so under "What is not certified here".
- **A second-site disaster-recovery runbook, and an inventory of every
  executable path the docs instruct.**
  [`second-site-dr.md`](docs/operations/second-site-dr.md) rebuilds Tockmox on a
  second site from the object store and the escrowed sealed-secrets key, using
  the databases' recovery switches (`modelGateway.database.recovery.*`,
  `identity.database.recovery.*`), with a readiness check to run before the
  disaster and a section on what is not certified. It has not been executed on a
  second cluster.
  [`tests/executed-docs/INVENTORY.md`](tests/executed-docs/INVENTORY.md) now has
  one row for each of the 42 pages that carry bash blocks (462 blocks): 10 are
  partly executed, 2 are written exceptions, 30 are open, none is executed end to
  end.
  Nothing to do on upgrade.

- **An alert pack for components the product ships: logs, the metrics volume,
  and (opt-in) the model gateway.** One `PrometheusRule`,
  `tockmox-alert-pack`, in the observability layer, ported from rules a running
  site had already proven. `TockmoxLokiNotIngesting` fires when no log line has
  reached Loki for 15 minutes, by rate or by the series being gone; it measures
  the pipeline and not a pod, so a Loki pod restarting cannot reset it.
  `TockmoxLokiIngestionCollapsed` catches the partial break (under a tenth of
  the 6-hour baseline for 30 minutes). `TockmoxPrometheusTSDBVolumeTroughRising`
  fires when the 3-day minimum fill of the Prometheus volume is above 82%
  (`alertPack.prometheusTsdb.troughThreshold`): a metrics volume ramps and is cut
  back by retention, so an instantaneous "90% full" never fires and a rising
  trough is the leak. The model-gateway group (`TockmoxLiteLLMDown`,
  `TockmoxLiteLLMMetricsAbsent`, `TockmoxLiteLLMHighErrorRate`,
  `TockmoxLiteLLMHighLatencyP95`) is off until `alertPack.litellm.enabled`,
  because it reads the gateway's `/metrics`, which nothing scrapes by default;
  switched on without the scrape, `TockmoxLiteLLMMetricsAbsent` fires instead of
  the rules sitting quiet. Every rule is classified in `tools/kured-gate.txt`
  and has a both-directions case under `tests/rules/`.

- **The Security Posture Probe's promises are written as data, and a gate holds
  them.** `addons/posture-probe/addon.yaml` is the first-party add-on manifest:
  that the add-on is off by default, ships no code the admin console would run
  and adds no route to the cluster, what its Kubernetes access is (read-only,
  and the safety gate that proves it), what it leaves behind when removed, and
  what it gives the platform (nothing to scrape or alert on). The format is in
  `addons/README.md`; it is a first-party contract, not an interface for writing
  your own. `tools/check-addon-manifest.sh` checks the manifest against the
  chart and its render, and refuses a field the format does not name.
- **Add-on settings keys carry a stability tier and a dated ruling, like a
  layer's.** `tools/check-values-tiers.sh` now reads
  `addons/*/chart/values.schema.json` beside the layers' schemas, so a posture
  probe key with no tier, no ruling or an overdue re-rule is refused, and a
  `stable` one does not move unannounced. All the probe's keys are marked
  `experimental`, which they already were in prose.

- **The five things a disconnected install needs are declared in one file.**
  `tools/airgap-manifest.yaml` names the five dependencies that
  `docs/deployment/airgap.md` lists: the images, the upstream Helm subcharts,
  the three prerequisites, the Tockmox charts repository and your site
  repository. The table at the top of that page is now generated from it
  (`tools/check-airgap-manifest.sh --write`), with the image and dependency
  counts read from `images.txt` and the `Chart.yaml` files.
  `tools/check-airgap-manifest.sh` reports what the manifest names that the tree
  or the page lacks: a tool that does not exist, a step heading that moved, a
  prerequisite its step never mentions. It reads the repository and nothing
  else, and it is a list, not an offline bundle.
- **The executed-docs throwaway cluster can run with the registry mirror as its
  only registry.** `TOCKMOX_REGISTRY_MODE=nofallback` writes the mirror as the
  sole endpoint for docker.io, quay.io, ghcr.io and registry.k8s.io, tells k3s
  not to append the upstream endpoint, and points the registries' names at an
  unroutable address while one firewall rule counts every attempt to reach it
  (`TOCKMOX_UPSTREAM_DENY=edge` leaves that denying and counting to the network's
  own firewall instead, for a segment that already logs it).
  `throwaway-cluster.sh mirror-proof` prints `PASS` only when the node is
  configured that way and the counter is zero. The default (`cache`, upstream as
  the mirror's fallback) is unchanged, byte for byte, and supports "pulls are
  cached" and nothing more. No provision has been run in the new mode yet.

- **A namespace guard, off by default (experimental).** `apps.namespace_guard.enabled`
  adds one `ValidatingAdmissionPolicy`, `tockmox-namespace-guard`, that refuses a
  `CREATE` in a namespace the policy layer manages unless the requester is Argo
  CD, `kube-system`, a ServiceAccount of a namespace the chart itself creates or
  names (derived from `namespaces`, so a renamed namespace moves with it), a
  `system:` identity that is not a ServiceAccount (not `system:anonymous`), or
  `system:masters`. A site adds a legitimate caller under `namespaceGuard`
  (`extraExemptServiceAccountNamespaces`, `extraExemptUsers`,
  `extraExemptGroups`). It ships in Warn (`["Audit", "Warn"]`, `failurePolicy:
  Ignore`): nothing is refused until a site reads what it would have refused and
  sets `namespaceGuard.validationActions` to `["Deny"]`. `tools/check-namespace-guard.sh`
  evaluates the expression against every ServiceAccount the nine layers ship.
  See `docs/administration/namespace-guard.md`.

### Changed

- **LiteLLM updates wait three days before Renovate opens them on `main`, and a
  new gate refuses the compromised 1.107.0 image digests.** LiteLLM's release
  pipeline was hijacked on 2026-10-21 and v1.107.0 shipped a credential
  stealer. The AI-plane rule no longer takes LiteLLM (`litellm-helm` and the
  `ghcr.io/berriai/litellm-database` image) as it lands: it carries a three-day
  `minimumReleaseAge` there, so a release the vendor pulls is gone before a PR
  exists. Open WebUI keeps the no-soak rule, and the release line keeps its
  seven days. `tools/check-litellm-compromise.sh`, a `tools/check-all.sh` gate,
  fails when a known-bad digest (the list is `tools/litellm-bad-digests.txt`,
  with the full digests and the two 12-hex prefixes the vendor published for
  `litellm-database` and `litellm-non_root`) appears in `images.txt` or in any
  file outside the docs, and when a LiteLLM image is named at exactly the
  `1.107.0` or `v1.107.0` tag (images.txt pins LiteLLM by tag, so a bump to the
  bad version names no digest; `1.107.1` and pre-releases are untouched). Cost: a LiteLLM fix on `main` reaches
  a PR three days later than before, and a security alert still jumps the queue.

- **The LiteLLM migrations Job is LiteLLM's own, as an Argo CD `Sync` hook, and
  a version change takes a database backup first.** `tockmox-ai` no longer
  renders its own hash-named copy of the Job: the vendored `litellm-helm` renders
  `tockmox-ai-litellm-migrations` with `argocd.argoproj.io/hook: Sync` and
  `hook-delete-policy: BeforeHookCreation`, so a LiteLLM image bump re-runs the
  migrations without `field is immutable`, and the render refuses
  `litellm.migrationJob.enabled: false` and the subchart's own hook switches.
  A new `PreSync` hook, `tockmox-pre-upgrade-backup`, compares the running
  LiteLLM version (and Open WebUI's, when `modelGateway.upgradeBackup.openWebuiClusterName`
  names a CNPG Cluster) with the version being applied; if it differs it creates a
  CloudNativePG `Backup`, waits for `completed`, and fails the sync with nothing of
  the new version applied if it does not. A first install and an unchanged version
  do nothing. `modelGateway.upgradeBackup.enabled: false` removes it. **Action:**
  none with Argo CD, which prunes the old hash-named Job; with a sync that does not
  prune, delete it (`docs/deployment/upgrade.md`, "The LiteLLM migrations Job
  becomes an Argo CD hook"). A plain `helm upgrade` has no hook machinery: the Job
  is an ordinary fixed-name object there and must be deleted before a LiteLLM
  image bump.

- **`tools/helm-deps.sh` works with no network when the tree already carries
  its subcharts.** When every layer's Chart.lock matches its Chart.yaml and
  every upstream archive is already in `charts/*/charts` at the locked version,
  it contacts no repository and only rebuilds `tockmox-common` from source; so
  `tools/check-all.sh` runs inside an airgap or a sandbox with no egress.
  Anything less (a missing archive, another version, a stale lock) takes the
  online path as before, and `HELM_DEPS_ONLINE=1` forces it. Self-test:
  `tools/helm-deps.sh --selftest`, now a gate in `check-all.sh`.
- **`tools/check-kubeconform.sh` (and the posture-probe gate's kubeconform
  step) validate offline against a local schema copy.** `KUBECONFORM_SCHEMA_DIR` names a directory laid out like
  kubernetes-json-schema (`master-standalone-strict/<kind>[-<group>]-<version>.json`);
  a kind it does not hold is skipped as an unpublished schema is online, and a
  run that validates nothing still fails. Without it, every fetch fails offline
  and reads as an error.
- **The documentation site's body text is Source Sans 3 as well,** so the
  whole site reads in the UI family; the previous body face's font files are
  removed.
- **The Tockmox UI, and the documentation site's headings, use Source Sans 3;
  the display face stays in the wordmark.** Pages follow one standard:
  problems first with healthy groups folded to a count, one answer at the top
  of a page, tables for sets and one status vocabulary (OK, Warning, Problem,
  Unknown). The tokens, stylesheet, page shell, status macros and fonts are
  now a shared kit in `ui-kit/` that the UI serves its own copy of
  (`ui-kit/README.md`); the UI's tests fail if that copy is edited in place.
  Fonts stay self-hosted. Nothing to do on upgrade.
- **Links are white and underlined, and buttons carry white text.** A primary
  button is white on a darker green (5.4:1) that darkens on hover; a secondary
  button is white on black with a grey border; the focus ring is white. Green
  is kept for the primary action and the OK state. The same change reaches the
  documentation site's links and buttons.
- **Every pull request runs `tools/check-all.sh` on Linux.** A new
  `check-all` workflow runs the whole local suite per pull request and on every
  push to `main` and `release-*`, so the gates `ci.yaml` has no step for are
  checked before merge rather than weekly. `portability-macos` stays weekly and
  on demand. The AI-node render gate now reports skipped, not failed, when the
  Python it is given cannot import the renderer.
- **Grafana files the boards in folders.** Tockmox's boards go in `Tockmox`,
  upstream's in `Kubernetes`, anything unannotated stays in General (the
  sidecar's `grafana_folder` annotation). Upgrading moves existing boards with
  their UIDs unchanged, so links and stars survive. Your own boards can name a
  folder with the same annotation. If you set Grafana's
  `default_home_dashboard_path` to a Tockmox board's file, the file is now under
  `/tmp/dashboards/Tockmox/`; update the path or the home page falls back to
  Grafana's default.

- **The air-gap runbook now covers updating, and the rollback section says
  which case you are in.**
  [`airgap.md`](docs/deployment/airgap.md) has a new step 8: mirror the images
  once, then update every later release from your own mirror (ADR-0036, the
  REQ-0004 amendment), with a git bundle for the chart repository, a check that
  nothing is pulled from outside, and a note on when the previous release's
  images can go. The step is written from the procedure and has not been run on
  a disconnected install.
  [`upgrade.md`](docs/deployment/upgrade.md) already said rollback is symmetric
  where it can be and not absolutely; its Roll back section opened with "the
  same procedure with the two revisions swapped". It now opens with a four-row
  table that says which case you are in before you swap. The bundled
  applications that migrate their own database schema (Open WebUI, LiteLLM,
  Authentik, Grafana) and pruned volumes are the exceptions. The chained
  rollback has not been run end to end, and the page says so.
  Nothing to do on upgrade.

- **An Open WebUI or LiteLLM bump no longer needs a site edit.** Open WebUI's
  trust-bundle initContainer learns whether a CA is coming from a new ConfigMap,
  `tockmox-ai-trust-env`, that renders whether or not SSO is on (`true` when
  `global.certIssuer` is set; `modelGateway.trustBundle.expectCA` overrides it), so
  a site with SSO off no longer restates the container, and its image, to set
  `TOCKMOX_EXPECT_CA`. A `build-ca-bundle` initContainer a site adds to LiteLLM
  may name its image `{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}`
  and then follows every bump; the render now refuses one that names any other
  image. **Action, if your site restates either container:** delete the Open WebUI
  `extraInitContainers` and `image.tag`, and give LiteLLM's `build-ca-bundle` the
  expression above and drop `litellm.image.tag`
  (`docs/administration/tls-and-trust.md`, "Trust inside the cluster").

- **The node agents run in a namespace of their own, and the monitoring namespace
  now enforces Pod Security `baseline`.** node-exporter, Alloy's log DaemonSet and
  the SMART exporter read the host (host network, host PID, `hostPath`, a
  privileged container), which no `securityContext` can make acceptable to a
  stricter level, so they moved out of `tockmox-monitoring` into
  `tockmox-node-agents` (new, `enforce: privileged`, ingress default-deny,
  `allow-from-prometheus`). What stays in `tockmox-monitoring` (Grafana, Loki, the
  blackbox and SNMP exporters) is checked against `baseline` and enforced there.
  Alloy pushes to Loki across namespaces, so a NetworkPolicy
  (`allow-from-node-agents`) admits exactly that and the push URL now names the
  Loki gateway's namespace. The name is `namespaces.node_agents` (policy layer),
  `namespaces.nodeAgents` (observability and exporters layers) and a literal
  `namespaceOverride` handed to node-exporter and Alloy; the observability
  preflight refuses a mismatch by name. **Action:** the first sync replaces the
  three DaemonSets (a few minutes without node metrics and logs). A dashboard or
  rule that selects these pods by `namespace="tockmox-monitoring"` needs the new
  name. A site that keeps its own layout sets the two `namespaceOverride` values to
  `""` and `podSecurity.enforce.monitoring: ""` in the policy layer, and sets
  `namespaces.nodeAgents: tockmox-monitoring` in the exporters layer, which
  restores the 0.8 placement. Not yet observed on a live cluster.
- **The SMART exporter is rendered by `tockmox-exporters` instead of vendored.**
  The `prometheus-smartctl-exporter` subchart (0.17.1) could not take a namespace
  of its own and bound its ServiceAccount to a PodSecurityPolicy role, which no
  supported Kubernetes has. The template keeps the subchart's value keys
  (`prometheus-smartctl-exporter.*`), so a site's overrides keep their meaning; an
  `extraInstances` item's own `config` now wins over `common.config`, where the
  subchart let the common block overwrite it. The cost is that Renovate no longer
  tracks the subchart and an upstream template change must be carried by hand.

- **Open WebUI 0.12.4 and LiteLLM (litellm-helm) 1.106.5.** Open WebUI 0.12.4 carries
  security fixes upstream says it will publish advisories for after CVE assignment; update
  promptly. Open WebUI's `LICENSE` at `v0.12.4` is byte-identical to `v0.12.3`, so the
  licence terms in `docs/frontend-posture.md` stand. The image pin moved to the `v0.12.4`
  tag, which upstream publishes as the same digest as `0.12.4`.

### Fixed

- **`tools/check-all.sh` names a gate that never returns instead of hanging
  with it.** A tree that already lacked Grafana's memory limit sent the
  memory-limit gate's selftest into a regular expression that backtracked
  without end, so a parallel run sat at 100% of one CPU until something outside
  killed it, and the report named no gate. The expression now matches each
  indented line one way only, and in parallel mode every gate runs under
  `CHECK_ALL_GATE_TIMEOUT` (seconds, default 1200, 0 for no limit). A gate past
  it is stopped with everything it started and reported as a failure marked
  `TIMEOUT after N s`.

- **The Argo CD sign-in recipe works on a site that uses the shipped private CA.**
  `docs/administration/argocd.md` ("A hostname and a portal tile") left out two
  things a lab run of it needed or Argo CD documents: `rootCA` in `oidc.config`,
  without which Argo CD's server refuses the Authentik provider with
  `x509: certificate signed by unknown authority`, and the
  `app.kubernetes.io/part-of: argocd` label on the client-secret Secret. The
  section now has a success condition naming the URL a reader should reach, and
  its "What is not certified here" says what was executed (lab, 2026-10-28).
- **The macOS per-user CA trust command is verified.** `tls-and-trust.md`'s
  verification table now records the 2026-10-28 run (keychain, `verify-cert`,
  Chrome with no warning) and says the EV and Certificate Transparency lines
  `verify-cert` prints are expected for a private CA. The machine-wide macOS,
  Linux and Windows commands stay "Not executed".

- **An mlx-lm engine that stops generating is noticed and restarted.** When
  mlx-lm's generation thread dies the process stays up, `/v1/models` keeps
  answering 200 and every completion fails until someone restarts it. The
  inference-node Probe now asks mlx-lm for `/health` (503 in that state), and
  enrolled AI nodes run an engine watch every minute that restarts such an
  engine and counts it (`tockmox_ai_node_engine_restarts_total`).
  `TockmoxAiNodeEngineRestarting` warns when it happens twice in six hours.

- **The Authentik board reads your Authentik wherever it runs.** "Workers up"
  and the memory and CPU panels selected `namespace="authentik"` and read 0 on
  any install that runs it elsewhere (Tockmox's own default is
  `tockmox-authentik`). They now select the server and worker by scrape job and
  container. "RSS" is now "Memory (working set)", read from the kubelet.
- **AI nodes: SSH is keys-only once the administrator has a key.** The drop-in
  limited who may log in but left password and keyboard-interactive logins on.
  It now turns both off, and only when the administrator's
  `~/.ssh/authorized_keys` holds a public key, so it cannot lock the
  administrator out.
- **AI nodes: a power setting the Mac does not have no longer changes on every
  converge.** `pmset` accepts `autopoweroff` on an M5 Ultra Mac Studio and never
  reports it back, so the node never converged with nothing to change. Only keys
  the machine reports are held.
- **AI nodes: Remote Login is detected on macOS 27.** The check read `netstat`,
  which lists no sockets at all when started from an Ansible task on macOS
  27.0.1, so every converge failed with "nothing is listening on port 22" and
  the readiness fact `remote_login` read 0 on a node that was listening. It now
  asks `lsof` as root.
- **AI nodes: models stored with Hugging Face's Xet backend verify.** `hf`
  names a Xet-backed file's cache blob by its Xet hash, not its SHA-256, so the
  helper refused correct downloads. For such a blob it now reads the Hub's record
  of the file at the pinned commit and requires the blob's name to be the listed
  Xet hash and the content's SHA-256 to be the listed LFS SHA-256; an unreachable
  Hub refuses rather than trusts. Gated repositories need the `hf-token` secret
  for this check as for the download.
- **AI nodes: the firewall's timed rollback and the converge job's self-reload work
  on macOS 27.** Both were started with `launchctl submit`, which on macOS 27.0.1
  returns 0 and starts nothing `launchctl` can see, so the first converge on a
  real Mac stopped before loading the allowlist (safely: pf untouched, no engine
  started). They are now one-shot jobs bootstrapped from their own plists and
  checked with `launchctl print` before the rules load.
- **The model size estimate no longer over-sizes MXFP4 models 2.4x and MLX
  4-bit and 8-bit models by up to a fifth.** The quant markers are matched in
  the right order and the overhead factor is gone; it is still labelled an
  estimate.
- **The manual Mac setup steps bring up the firewall before the engine
  listens.**

- **Forward-auth consoles send a signed-out browser to the Authentik login, and
  the Traefik dashboard answers.** Both defects were found on the 0.9.0
  clean-install lab leg (the maintainers' lab, 2026-10-28) and passed every render gate.
  An unauthenticated request to Prometheus, Alertmanager or Longhorn was refused
  and then redirected to `http://localhost/application/o/authorize/...`, because
  the embedded outpost is created with a blank `authentik_host` and nothing set
  it. The identity layer's outpost entry now sets `authentik_host` to the auth
  host's origin (`https://auth.<internalDomain>/`). It replaces the field whole,
  like the provider list, so a value you set by hand on the embedded outpost is
  replaced at the next apply. `https://traefik.<internalDomain>/dashboard/`
  answered `404`: an IngressRoute cannot attach the identity layer's Middleware
  by its `@kubernetescrd` name while Traefik's `allowCrossNamespace` is off,
  which is its default and the platform layer's. The platform layer now renders
  `traefik-dashboard-forward-auth` beside the route, with the same spec;
  `ingress.forwardAuth.address` overrides where it asks, for a site that moved
  the identity layer. `tools/check-forward-auth.sh` now fails on a blank or
  wrong outpost host (F6) and on any IngressRoute in any chart that reaches
  across a namespace while `allowCrossNamespace` is off (F7). Nothing to change
  on upgrade.

- **A restore drill that fails early now says why in its register row.** When the
  drill's `kubectl apply` was refused, or the scratch Cluster never became Ready,
  the row read `FAIL` with nothing to explain it, and a drill that fails in seconds
  is gone before its log is collected. The model gateway's and Authentik's drills
  now write `apply refused: <the API server's message>` or `cluster never became
  Ready (phase: <phase>): <the wait's message>`, on one line, cut at 240
  characters (`docs/operations/backup-restore.md`, "Reading a row").

## [0.8.2] ... 2026-10-25

A patch release: two fixes to how the identity layer applies Authentik
blueprints, one of which closes a 0.8.1 known issue, and documentation that now
states what a patch on the 0.8 line may contain. It is the first release cut by
the patch train described in RELEASING.md. To upgrade from 0.8.1, change the
nine `targetRevision` pins to `v0.8.2` and push. Nothing else is required.

### What taking this patch costs

- **Hand actions:** none beyond the nine `targetRevision` pins.
- **Rollback:** a revision swap, for every layer. No bundled application and no
  database schema moved since 0.8.1, so going back needs no database restore.
  Upgrading directly from 0.8.0 also crosses 0.8.1's application updates
  (Authentik, LiteLLM, Open WebUI), which roll back only by restoring their
  databases: take the pre-upgrade backup that
  [upgrade.md](docs/deployment/upgrade.md) describes.
- **Images:** no change. `images.txt` lists the same 44 images as 0.8.1, and
  the SBOM differs only in the Tockmox version it names.
- **Contract:** no `stable` values key moved, and no immutable field differs
  between the 0.8.1 and 0.8.2 renders. The identity chart's defaults gain a
  liveness probe, a `postStart` hook and a rollout strategy for the Authentik
  worker (under Fixed).
- **Air-gap:** the static image-redirect check passed on 2026-10-24. An
  air-gapped install was not exercised for this release.

### Fixed

- **A changed Authentik blueprint is now applied even when Authentik's file
  watcher has died.** The watcher can stop without a trace, after which a
  blueprint synced by Argo CD was mounted in the worker and never applied, with
  everything green. The worker now records a hash of `/blueprints/mounted` at
  start and its liveness probe compares it, so a change restarts the worker's
  container (one restart, a `Liveness probe failed` event saying why, about a
  minute or two after the sync) and the restart applies the file. It covers
  blueprints a site mounts through `authentik.blueprints.configMaps` and
  `.secrets`. A site that replaces `authentik.worker.livenessProbe` has to keep
  the hash comparison, and a blueprint mounted outside `/blueprints/mounted`
  still needs a restart or a restart controller.
- **A blueprint added by an upgrade is no longer missed.** During the rollout
  the new worker queued its discovery pass and the old worker, which does not
  have the file yet, took it and found nothing; the blueprint then stayed
  absent until the hourly discovery. The Authentik worker now rolls with
  `maxSurge: 0` and `maxUnavailable: 100%`, so the old worker is stopped first.
  The cost is a gap of one worker start, tens of seconds, with no worker: queued
  background work waits and logins are unaffected. It is not `type: Recreate`
  because Argo CD's ServerSideApply cannot switch a live Deployment to it. This
  was a 0.8.1 known issue. On the upgrade from 0.8.0, which adds the ntfy portal
  tile, every identity blueprint had been applied when read, under five minutes
  after Argo CD read the new pins; on 0.8.1 the tile took 36 minutes.

### Security

- The documentation build's pinned `certifi` is 2026.10.19, which removes the
  compromised emSign intermediate certificates
  ([GHSA-6q48-6c7w-9gw2](https://github.com/advisories/GHSA-6q48-6c7w-9gw2)).
  It applies to building the documentation site from source. No chart and no
  image changes.

### Changed

- **SECURITY.md states the support window for a release line**: the current
  `release-X.Y` line receives patch releases until the next minor's final tag,
  and a security fix may ship ahead of the normal cadence.
  [upgrade.md](docs/deployment/upgrade.md) now says that a patch may update
  bundled applications, and that the pre-upgrade backup is required whenever a
  patch's notes name an application that migrates its database.
- The Tockmox UI page gives the sign-in alert's real timing: it fires about six
  minutes after the first failed sign-in.

### How this release was tested

- **Upgrade from 0.8.1**, on a single-node k3s lab running 0.8.1 with a
  5,001-row checksum table in each of its two CloudNativePG databases: the nine
  revision pins and nothing else. Every layer had synced 73 seconds after Argo
  CD read the new pins, and all were Healthy at the next read, under three
  minutes after, with no retries and no hand action. Both checksums read
  byte-identical afterwards, every volume claim stayed bound to the same volume,
  every sealed secret still decrypted, no Longhorn volume shrank, the identity
  PostgreSQL did not restart, and every identity blueprint was applied. The
  Authentik worker rolled with no surge, as the fix above intends.
- **Upgrade from 0.8.0, skipping 0.8.1**, from a recorded 0.8.0 install with its
  own checksum tables: every layer had synced 96 seconds after Argo CD read the
  pins and all were Healthy at the next read, about four minutes after, with no
  retries and no hand action. Authentik, LiteLLM and Open WebUI moved to their
  0.8.1 versions with no restarts, the LiteLLM migration Job completed, the
  identity PostgreSQL stayed up, a
  secret sealed under 0.8.0 still decrypted, both checksums were unchanged, and
  every blueprint, including the new ntfy tile's, was applied.
- **Fresh install** of the candidate, on the same lab holding only k3s, Argo CD
  and Sealed Secrets: one `root.yaml` applied, every Application Synced and
  Healthy in under eight minutes with no hand action (Argo CD's own retries
  only). On that install: an on-demand database backup, a restore drill that
  restored the database from the object store into a scratch cluster and found
  99 tables, every identity blueprint applied, and a test alert delivered to the
  ntfy server.
- The static checks on the candidate, including the comparison of the 0.8.1 and
  0.8.2 renders for immutable fields (193 objects, none flagged) and the values
  contract against 0.8.1 (62 stable keys, none moved).

### Known issues

- LiteLLM's database migration Job still logs a `Read-only file system` error
  from `prisma generate` after the migrations have applied; the Job completes.

### Not tested for this release

- An air-gapped install.
- An alert reaching a phone: the test alert was read on the ntfy server, not on
  a subscribed client.
- A rollback from 0.8.2 to 0.8.1.
- Anything multi-node: the lab is a single node.

## [0.8.1] ... 2026-10-19

A patch release: fixes found since 0.8.0, the dependency updates that waited for
it, and one memory limit an upgrade proved too small. To upgrade from 0.8.0,
change the nine `targetRevision` pins to `v0.8.1` and push. Nothing else is
required.

### Fixed

- **The LiteLLM proxy no longer crash-loops when it starts before its
  database**, as it did on an upgrade or a reboot that restarted both: it now
  waits in an init container until the database answers. A site that sets its
  own `litellm.extraInitContainers` replaces that list and has to restate the
  wait to keep it.
- **Moving an application's access from `users` to `admin` now removes the
  user-group binding.** Before, users kept access after the move.
- **The identity layer's bundled PostgreSQL has a 512Mi memory limit** (was
  224Mi). On the upgrade from 0.8.0 the old limit was reached and the database
  was restarted once mid-upgrade; it recovered with every migration applied,
  but the limit had been sized from an idle day.
- **The Security Posture Probe add-on reaches `deployed` (and Healthy under Argo
  CD) on its first sync**, on a StorageClass that waits for a first consumer
  such as k3s's `local-path`. This was a 0.8.0 known issue.
- **ntfy has a tile on the sign-in portal** (`links.ntfy`, `access: users` by
  default). ntfy keeps its own sign-in.

### Changed

- Open WebUI 0.12.3 and LiteLLM 1.105.1 (the LiteLLM release fixes lost and
  double-counted spend-log rows). Open WebUI's websocket redis is pinned to
  7.4.11-alpine instead of its 2025 default.
- Authentik 2026.8.4. Its bundled PostgreSQL moved its default image from
  `17.11-bookworm` to `17.11-trixie`; Tockmox keeps `17.11-bookworm` for 0.8.x,
  because the change of operating system changes the collation library under an
  existing database.
- argo-workflows 2.0.13, kube-prometheus-stack 92.8.0, Loki 18.16.0, Traefik
  41.7.1, snapshot-controller 5.4.0 (external-snapshotter v8.7.0), ntfy v2.30.0.
  `images.txt` and the SBOM list them, and CI now fails when `images.txt` is
  stale.

### How this release was tested

- **Upgrade from 0.8.0**, on a single-node k3s lab: a fresh install of 0.8.0,
  then the nine revision pins and nothing else. All layers Synced and Healthy 89
  seconds after Argo CD read the new pins, with no retries and no hand action. A
  5,001-row checksum table in each of two CloudNativePG databases read
  byte-identical before and after, every volume claim stayed bound to the same
  volume, a secret sealed under 0.8.0 still decrypted, the LiteLLM proxy did
  not restart, and the identity PostgreSQL stayed up (it peaked at 288 MiB).
  The first candidate ran the same upgrade and found the memory limit above.
- **Fresh install** of the candidate, on the same lab holding only k3s, Argo CD
  and Sealed Secrets: one `root.yaml` applied, every Application Synced and
  Healthy with no hand action (Argo CD's own retries only). On that install: an
  on-demand database backup, a restore drill that restored the database from the
  object store into a scratch cluster and found 99 tables, every identity
  blueprint applied, and a test alert delivered to the ntfy server.
- The Security Posture Probe add-on, installed both with `helm --wait` and as
  the documented Argo CD Application, on `local-path`.

### Known issues

- On an upgrade, a portal tile that is new in the release (in 0.8.1, the ntfy
  tile) can take up to an hour to appear: during the rolling update its
  blueprint can be picked up by an Authentik worker that does not have the file
  yet, and Authentik applies it again at its next hourly discovery. A fresh
  install is not affected.
- LiteLLM's database migration Job still logs a `Read-only file system` error
  from `prisma generate` after the migrations have applied; the Job completes.

### Not tested for this release

- An air-gapped install.
- An alert reaching a phone: the test alert was read on the ntfy server, not on
  a subscribed client.
- A rollback from 0.8.1 to 0.8.0.

## [0.8.0] ... 2026-10-12

The first public release of Tockmox. Earlier versions were built and run in a
private repository and were never published, so there is nothing to upgrade
from: start with [install.md](docs/deployment/install.md), or the
[Quickstart](README.md#quickstart).

What it is: a Kubernetes platform for running your own AI on hardware you
control, delivered as Helm charts and reconciled by Argo CD from your own site
repository.

- **AI**: a chat console (Open WebUI) and a model gateway (LiteLLM) in front of
  your own models. An optional policy gate keeps each class of request off
  the endpoints it may not reach.
- **Identity**: one sign-in for every console (Authentik).
- **Observability**: metrics, logs, dashboards and alerts that reach a phone
  (Prometheus, Alertmanager, Grafana, Loki, Alloy, ntfy), with a heartbeat that
  proves the alert path is alive.
- **Platform**: storage, databases, ingress, certificates and patching
  (Longhorn, CloudNativePG, Garage, Traefik, MetalLB, cert-manager, kured), with
  database backups and a scheduled restore drill that proves they restore.
- **Policy**: default-deny networking and admission guardrails.
- **DevOps**: Argo Workflows behind single sign-on (optional).
- **Tockmox UI** (experimental): one page that says whether the platform is
  healthy and where every console is.

Every component turns off on its own, and the licence of each is in
[third-party-licenses.md](docs/third-party-licenses.md). What has been proven,
on what hardware, and what has not: [project-status.md](docs/project-status.md).

### How this release was tested

- **Fresh install**, on a single-node k3s lab that held only k3s, Argo CD and
  Sealed Secrets: one `root.yaml` applied, every layer Synced and Healthy with
  no hand action (Argo CD's own sync retries only). On that install: a backup of
  each database, a restore drill that restored the newest backup into a scratch
  cluster and found 99 tables, a test alert delivered to a subscribed ntfy
  client, a chat answered through the model gateway and found in its spend log,
  sign-up closed with the bootstrap administrator signing in, and these docs
  published from the release candidate's tag.
- **Upgrade from the last private release (0.7.2)**, on the same lab: the nine
  revision pins and the one new required value, nothing else. All layers Synced
  and Healthy about 8 minutes after the push. A 5,001-row checksum table in each
  of two CloudNativePG databases read byte-identical before and after, every
  volume claim stayed bound to the same volume, and a secret sealed under 0.7.2
  still decrypted.
- **A six-node site** ran the release candidate, through a rolling reboot of
  every node, with no container killed for memory.

### Known issues

- The Security Posture Probe add-on (experimental) keeps its reports on a volume
  that binds only when its first run starts. On a StorageClass that waits for a
  first consumer, as k3s's `local-path` does, `helm install --wait` times out
  and the release reads `failed` although every object is created; under Argo
  CD the add-on shows Progressing until its first run. Install it without
  `--wait`, or run it once with `run-now.sh`.
- LiteLLM's database migration Job logs a `Read-only file system` error from
  `prisma generate` after the migrations have applied. LiteLLM treats that step
  as optional and the Job completes; the message is not a failure.

### Not tested for this release

- An air-gapped install. The documented route is unchanged, but it was not
  re-run against this release.
- The restore drill's first *scheduled* run: on the test install the drill was
  started by hand from its own schedule's template, because the install came up
  after that week's slot.
- The Security Posture Probe under Argo CD (installed with Helm only), and the
  experimental features (the Tockmox UI aside) beyond confirming they stay off
  by default.

[Unreleased]: https://github.com/tockmox/tockmox/compare/v0.8.2...main
[0.8.2]: https://github.com/tockmox/tockmox/releases/tag/v0.8.2
[0.8.1]: https://github.com/tockmox/tockmox/releases/tag/v0.8.1
[0.8.0]: https://github.com/tockmox/tockmox/releases/tag/v0.8.0

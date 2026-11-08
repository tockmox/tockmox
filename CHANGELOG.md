# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [semantic](https://semver.org/spec/v2.0.0.html).

Breaking changes come first in their release, in their own section, each with
the action required beneath it. Entries are bullets: what changed and what it
costs you, with the reasoning in the documentation rather than here.

## [0.8.4] ... 2026-11-08

A patch release of dependency updates for the monitoring stack, the
notification server and the object store, with internal tracker references
removed from the shipped files. To upgrade from 0.8.3, change the nine
`targetRevision` pins to `v0.8.4` and push. Nothing else is required.

### What taking this patch costs

- **Hand actions:** none beyond the nine `targetRevision` pins.
- **Rollback:** a revision swap for every layer, with three components whose
  rollback was not measured. ntfy moves from v2.30.0 to v2.36.0: on the way it
  migrates its message cache to a newer schema (v2.31.1) and, at v2.36.0, zeroes
  the user table's daily-usage columns. Grafana moves from 13.2.4 to 13.3.0
  and may migrate its own database on first start. Garage moves from v2.4.1 to
  v2.5.0. None of the three was rolled back for this release. If their state
  matters to you, take the pre-upgrade backup that
  [upgrade.md](docs/deployment/upgrade.md) describes before you change the pins.
- **Images:** eight references in `images.txt` move, listed under Component
  versions; the count stays at 44, and the SBOM changes only in those versions
  and the Tockmox version it names.
- **Contract:** no `stable` values key moved, and no immutable field differs
  between the 0.8.3 and 0.8.4 renders.
- **Air-gap:** the static image-redirect check passed on 2026-11-07. An
  air-gapped install was not exercised for this release.

### Security

- **ntfy v2.36.0** carries the security fixes of the ntfy releases since
  v2.30.0: a build on Go 1.27.3 with the Go 1.27.2 security fixes, a
  subscription limited to 150 topics with duplicates ignored, every
  subscription of a user ended when their access to a topic is reset or the
  user is deleted, and Matrix push gateway requests refused unless their push
  key names a valid topic.

### Component versions

- kube-prometheus-stack chart 92.8.0 -> 92.17.0: Grafana 13.2.4 -> 13.3.0
  (`docker.io/grafana/grafana`, distroless), Alertmanager v0.34.1 -> v0.34.2,
  prometheus-operator v0.94.1 -> v0.94.2 and its config reloader v0.94.0 ->
  v0.94.2 (still pinned by digest)
- alloy chart 1.13.1 -> 1.15.0 (`docker.io/grafana/alloy` v1.20.1 -> v1.21.3)
- loki chart 18.16.0 -> 18.17.1 (Loki itself stays 3.7.8)
- prometheus-snmp-exporter chart 9.18.1 -> 9.19.0
- prometheus-smartctl-exporter chart 0.17.1 -> 0.19.0
- argo-workflows chart 2.0.14 -> 2.0.15 (Argo Workflows itself stays v4.1.6)
- `binwiederhier/ntfy` v2.30.0 -> v2.36.0
- `dxflrs/garage` v2.4.1 -> v2.5.0
- `ghcr.io/jkroepke/access-log-exporter` 0.5.0 -> 0.5.1
- Documentation build: mkdocs-material 9.7.7 -> 9.8.0, platformdirs 4.13.5 ->
  4.14.2
- Tockmox's own components (the Tockmox UI, the Security Posture Probe) did not
  change.

### Changed

- The shipped files no longer carry the project's internal tracker
  references. Comments in the chart templates, values files, tools and
  documentation now say what they meant to say without pointing at a tracker
  outside this repository. The CHANGELOG keeps its history as written, and
  `tools/check-no-site-specifics.sh` refuses a new reference anywhere else.
  What this changes in a rendered install is text only: the alert bridge's
  embedded script (docstrings) and several dashboard panel descriptions. Two
  hook Jobs, the gateway-key mint and the object-store credentials, take a new
  name because their name hashes the template text, so each runs once more on
  upgrade. Both re-run on the measured upgrade without a hand action (the
  layers they belong to reached Healthy), and both completed on the fresh
  install.

### How this release was tested

- **Upgrade from 0.8.3**, on a single-node k3s lab restored to the state
  recorded at 0.8.3's release, with a 5,001-row checksum table in each of its
  two CloudNativePG databases: the nine revision pins and nothing else. Every
  Application was Synced and Healthy on the candidate within four minutes of
  the pins merging, with no hand action. Both
  checksums read byte-identical afterwards, every volume claim stayed bound to
  the same volume, every sealed secret still decrypted and no volume shrank.
  All eight moved images ran with no restarts. On the upgraded install, a test
  alert went from Alertmanager v0.34.2 through the alert bridge to ntfy v2.36.0,
  Grafana 13.3.0 reported its database healthy, and an on-demand database
  backup completed to Garage v2.5.0.
- **Fresh install** of the candidate, on the same lab holding only k3s, Argo CD
  and Sealed Secrets: one `root.yaml` applied, every Application Synced and
  Healthy within nine minutes with no hand action. On that install: continuous
  archiving on both CloudNativePG clusters, an on-demand database backup, a
  restore drill that restored the database from the object store into a scratch
  cluster and found 99 tables, every identity blueprint applied, and a test
  alert delivered to the ntfy server.
- The static checks on the candidate, including the comparison of the 0.8.3 and
  0.8.4 renders for immutable fields (193 objects, none flagged), the values
  contract against 0.8.3 (62 stable keys, none moved), the alert-rule unit
  tests, and the documented installation paths run against a live cluster.

### Known issues

- LiteLLM's database migration Job still logs a `Read-only file system` error
  from `prisma generate` after the migrations have applied; the Job completes.

### Not tested for this release

- Upgrading from 0.8.0, 0.8.1 or 0.8.2 straight to 0.8.4.
- A rollback from 0.8.4 to 0.8.3, including the ntfy, Grafana and Garage
  rollbacks named above.
- An air-gapped install.
- An alert reaching a phone: the test alerts were read on the ntfy server, not
  on a subscribed client.
- Anything multi-node: the lab is a single node.

## [0.8.3] ... 2026-11-02

A patch release of dependency updates, carried for the cert-manager security
fix. To upgrade from 0.8.2, change the nine `targetRevision` pins to `v0.8.3`
and push. Nothing else is required.

### What taking this patch costs

- **Hand actions:** none beyond the nine `targetRevision` pins.
- **Rollback:** a revision swap, for every layer. Authentik moves from 2026.8.4
  to 2026.8.5 and applies no database migration (its `django_migrations` table
  held the same 777 rows before and after the upgrade), and no other bundled
  application with a database moved. Upgrading directly from 0.8.0 also crosses
  0.8.1's application updates (Authentik, LiteLLM, Open WebUI), which roll back
  only by restoring their databases: take the pre-upgrade backup that
  [upgrade.md](docs/deployment/upgrade.md) describes.
- **Images:** eight references in `images.txt` move, listed under Component
  versions; the count stays at 44, and the SBOM changes only in those versions
  and the Tockmox version it names.
- **Contract:** no `stable` values key moved, and no immutable field differs
  between the 0.8.2 and 0.8.3 renders.
- **Air-gap:** the static image-redirect check passed on 2026-11-02. An
  air-gapped install was not exercised for this release.

### Security

- **cert-manager v1.21.3** removes trust in the compromised eMudhra CA (the
  "emSign ECC Root CA - G3" root is gone from its images, and Go 1.26.10 makes
  `crypto/x509` refuse chains through the compromised intermediates). It also
  stops the controller copying a private key from a Secret the Certificate does
  not own: the next private key is now always written under a generated name.
  An ACME renewal loop is fixed, and Go and dependencies are updated for
  reported vulnerabilities. Upstream says all users should upgrade.
- Authentik 2026.8.5 carries the same certificate-related dependency update,
  with four small fixes of its own.
- The documentation build's pinned `certifi` and `Markdown` move to their
  latest patches; the `Markdown` patch sanitizes attribute names in two
  extensions. This applies to building the documentation site from source.

### Component versions

- authentik (chart and `ghcr.io/goauthentik/server`) 2026.8.4 -> 2026.8.5
- cert-manager (chart and the four `quay.io/jetstack/cert-manager-*` images)
  v1.21.2 -> v1.21.3
- argo-workflows chart 2.0.13 -> 2.0.14 (`quay.io/argoproj/argocli` and
  `workflow-controller` v4.1.5 -> v4.1.6)
- prometheus-blackbox-exporter chart 11.20.0 -> 11.20.2
  (`quay.io/prometheus/blackbox-exporter` v0.29.0 -> v0.29.1)
- prometheus-operator-crds chart 32.0.1 -> 32.0.2
- `caronc/apprise` 2.0.1 -> 2.0.2 (off by default)
- Documentation build: certifi 2026.10.19 -> 2026.10.23, Markdown 3.11.1 ->
  3.11.2, platformdirs 4.13.0 -> 4.13.5
- Tockmox's own components (the Tockmox UI, the Security Posture Probe) did not
  change.

### Changed

- RELEASING.md requires a Component versions list in every release's notes,
  as in this section.

### How this release was tested

- **Upgrade from 0.8.2**, on a single-node k3s lab restored to the state
  recorded at 0.8.2's release, with a 5,001-row checksum table in each of its
  two CloudNativePG databases: the nine revision pins and nothing else. All nine
  layers were Synced and Healthy on the candidate within about 80 seconds of
  Argo CD reading the new pins, with no retries and no hand action. Both
  checksums read byte-identical afterwards, every volume claim stayed bound to
  the same volume, every sealed secret still decrypted, no Longhorn volume
  shrank, the identity PostgreSQL did not restart, and every identity blueprint
  was applied. All eight moved images ran with no restarts, and a certificate
  forced to re-issue on cert-manager v1.21.3 was Ready again in five seconds.
- **Fresh install** of the candidate, on the same lab holding only k3s, Argo CD
  and Sealed Secrets: one `root.yaml` applied, every Application Synced and
  Healthy five minutes later with no hand action (Argo CD's own retries only).
  On that install: an on-demand database backup, a restore drill that restored
  the database from the object store into a scratch cluster and found 99
  tables, every identity blueprint applied, and a test alert delivered to the
  ntfy server.
- The static checks on the candidate, including the comparison of the 0.8.2 and
  0.8.3 renders for immutable fields (193 objects, none flagged), the values
  contract against 0.8.2 (62 stable keys, none moved), and the documented
  installation paths run against a live cluster.

### Known issues

- LiteLLM's database migration Job still logs a `Read-only file system` error
  from `prisma generate` after the migrations have applied; the Job completes.

### Not tested for this release

- Upgrading from 0.8.0 or 0.8.1 straight to 0.8.3. 0.8.2 measured the upgrade
  from 0.8.0, and this patch changes no chart template and applied no Authentik
  migration on the measured upgrade, but that path was not run for this
  release.
- An air-gapped install.
- An alert reaching a phone: the test alert was read on the ntfy server, not on
  a subscribed client.
- A rollback from 0.8.3 to 0.8.2.
- Anything multi-node: the lab is a single node.

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
[0.8.4]: https://github.com/tockmox/tockmox/releases/tag/v0.8.4
[0.8.3]: https://github.com/tockmox/tockmox/releases/tag/v0.8.3
[0.8.2]: https://github.com/tockmox/tockmox/releases/tag/v0.8.2
[0.8.1]: https://github.com/tockmox/tockmox/releases/tag/v0.8.1
[0.8.0]: https://github.com/tockmox/tockmox/releases/tag/v0.8.0

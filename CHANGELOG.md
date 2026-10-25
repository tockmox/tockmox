# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [semantic](https://semver.org/spec/v2.0.0.html).

Breaking changes come first in their release, in their own section, each with
the action required beneath it. Entries are bullets: what changed and what it
costs you, with the reasoning in the documentation rather than here.

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

---
okf_version: "0.2"
type: HowTo
title: "The Tockmox UI"
description: "Run the Tockmox admin console in the AI layer: build its image from source, turn it on, know exactly what its network policy lets it reach, and read its provisional status API."
tags: [tockmox-ui, ai-plane, inference, model-lifecycle, networkpolicy, status-api, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-07
tockmox:
  classification: public
  audience: [operator]
---

# The Tockmox UI

The Tockmox UI is the admin console for [inference nodes](inference-nodes.md)
and [model lifecycle](model-lifecycle.md). It shows each node's health, imports
an existing gateway's routes, proposes and promotes models, and generates the
values change for each of those. **It never changes anything itself**: every
action ends in YAML that an admin commits.

> **Experimental in 0.8.0, and off by default.** The values keys may change
> before they are marked stable.

## Build the image

The UI ships as source, not as a published image: for 0.8.0 your site builds it
and pushes it to the registry your cluster pulls from, and the chart runs
whatever `tockmoxUi.image` names. The source is the `tockmox-ui/` directory of
this repository, at the same tag as the charts you deploy. The build runs from
the repository root, because the image carries that tag's `CHANGELOG.md` as the
release notes it shows. From a checkout of the tag, with your registry in place
of `registry.example.com`:

```text
docker build -f tockmox-ui/Dockerfile -t registry.example.com/tockmox/tockmox-ui:0.8.0 .
docker push registry.example.com/tockmox/tockmox-ui:0.8.0
```

Tag the image with the Tockmox version it was built from, so the image and the
charts move together and the running version the UI reports is the one you
deployed. Any OCI builder that reads a Dockerfile works (`podman build`,
`buildah bud`, a CI job in your own forge); nothing in the build reaches a
Tockmox service. The build does fetch the Python packages in
`tockmox-ui/requirements.txt` from your package index, so a dark site needs a
mirror of that index or an image built on a connected machine and carried in.

The image is built on `python:3.14-alpine`. It was `python:3.12-slim` until
0.8.0-rc1, and that base scanned 44 High findings in Debian packages with no fix
available, so a registry that refuses images with High findings (Harbor's
"prevent vulnerable images") refused it. The image carries no pip either: pip
vendors its own urllib3, msgpack and setuptools, and on the first 0.8.0-rc1
build those scanned 4 High that pip's copies had not caught up with, so the
Dockerfile removes pip once the requirements are installed (the UI installs
nothing at run time) and applies the base's pending Alpine fixes. Scan what you
build; the findings move with the base image and the day you build, not with
Tockmox.

The image runs as user 65534 with a read-only root filesystem. The Dockerfile
makes the copied tree world-readable, so a checkout with tight file modes still
produces an image that can read its own code.

The model watcher runs in this same image: name it in
`modelLifecycle.watch.image` too when you turn the watcher on, and move both
together on upgrade.

A Tockmox-published, signed image is planned for a later release; until then
the image is yours, and so is scanning it.

## Turn it on

```yaml
tockmoxUi:
  enabled: true
  image: registry.example.com/tockmox/tockmox-ui:0.8.0
  config:
    site: {name: My Tockmox, domain: int.example.com}
    oidc:
      issuer: https://auth.int.example.com/application/o/tockmox-ui
      clientId: tockmox-ui
      redirectUrl: https://tockmox.int.example.com/auth/callback
```

`config` is the UI's own configuration (site, roles, the console tiles, OIDC,
features). The chart fills in the rest: the Prometheus and Alertmanager
addresses, the paths it mounts the secrets at, and the `inferenceNodes` and
`modelLifecycle` blocks, so the UI reads the same values the gateway renders
from.

**The console tiles default to what this release turns on.** With `config.apps`
unset, the chart renders one tile per console: Chat and the model gateway from
the AI layer's own switches and hosts, Grafana, ntfy and Workflows from the
capability switches every layer shares, each at its derived
`<name>.<internalDomain>` host and with the shipped group mapping (Chat for
everyone, Grafana for `tockmox-users` and admins, the rest for admins). The AI
layer cannot see another layer's per-app override or renamed host, so a site
that has either sets `config.apps` itself; set, the list is exactly yours.
Every app needs `id`, `name`, `url`, and optionally `icon`, `description` and
`groups` (`["*"]` is every signed-in user).

**Documentation links.** The home page links the documentation site the
platform layer publishes at `docs.<internalDomain>` (`config.site.docsUrl`
overrides it), and the same docs in the source repository at the running
release (`config.site.docsRepoUrl`, default `https://github.com/tockmox/tockmox`),
which still opens when the platform is down or powered off.

**The footer names the running Tockmox release**, read from the layers' Argo CD
revision like the version page, and, for admins with the update check on, a
"New version available" pill. On a commit rather than a tag it says so. It is reached at `tockmox.<internalDomain>` unless you set
`tockmoxUi.ingress.host`, or turn the Ingress off with
`tockmoxUi.ingress.enabled: false`.

**Which Applications are the Tockmox layers** decides the running version the
UI reports. Unset, `config.tockmoxRepo` means the Applications whose first
source path is `charts/tockmox-<layer>`, whichever repository serves them, so a
site that mirrors the product tree ([airgap](../deployment/airgap.md), section
5) reads its version like one on github.com. Set
`config.tockmoxRepo: https://forge.example/tockmox/tockmox` to match on one
repository URL instead; with it set, a layer served from anywhere else reads
"Version unknown" and the reason names the URL it was looking for.

Create two Secrets in the AI namespace first:

| Secret | Key | What |
|---|---|---|
| `tockmox-ui-session` | `secret` | 32 characters or more; signs the session cookie |
| `tockmox-sso-tockmox-ui` | `client-secret` | the OIDC client secret, when `config.oidc.issuer` is set |

The names can be changed under `tockmoxUi.secrets`. Mint both from your site
repository, sealed, with
`tools/mint-secrets.sh --context <yours> --only tockmoxui` (or add
`--with-tockmox-ui` to a full run). It writes `secrets/tockmox-ui-session.sealed.yaml`
and `secrets/sso-tockmox-ui.sealed.yaml`; commit them with the values change.

### Register the UI with Authentik

The identity layer's blueprints register Grafana, Open WebUI and Argo
Workflows. They do not register the UI, so until you do, sign-in ends at
Authentik with an unknown client. Register it the way
[adding an application](adding-an-application.md#5-single-sign-on) describes,
with these values:

| Field | Value |
|---|---|
| Provider type | OAuth2/OpenID, confidential client |
| Client ID | `tockmox-ui` (the `config.oidc.clientId` above) |
| Client secret | the `client-secret` of `tockmox-sso-tockmox-ui`, read back once it is in the cluster: `kubectl --context <yours> -n tockmox-ai get secret tockmox-sso-tockmox-ui -o jsonpath='{.data.client-secret}' \| base64 -d` |
| Redirect URI | `https://tockmox.<internalDomain>/auth/callback` (strict), the `config.oidc.redirectUrl` above |
| Grant types | `authorization_code` and `refresh_token` |
| Scopes | `openid`, `email`, `profile` |
| Application slug | `tockmox-ui`, so the issuer is `https://auth.<internalDomain>/application/o/tockmox-ui/` |
| Binding | the admin group (`tockmox-admins`), unless users are meant to see it |
| Invalidation flow | `default-invalidation-flow`, so **Sign out** ends the Authentik session too |
| Post-logout redirect URI | `https://tockmox.<internalDomain>/` (strict, type **Logout**), the same string as `config.oidc.postLogoutRedirectUrl`, so Sign out lands back on the UI's sign-in |

**Sign out ends the Authentik session only with the right invalidation flow.**
Sign out sends the browser to the issuer's `end_session_endpoint`. What that
ends is the provider's invalidation flow: `default-invalidation-flow` ends the
Authentik session and signs the user out of every application (Authentik
2025.10 and later); `default-provider-invalidation-flow`, the default for a new
provider, ends only this application's, and the next visit signs straight back
in. To keep Sign out local, set `config.oidc.endSession: false`.

**Coming back to the UI after Sign out.** Set `config.oidc.postLogoutRedirectUrl`
to the UI's address and register the same string with the provider as a
redirect URI of type **Logout** (in a blueprint, a `redirect_uris` entry with
`redirect_uri_type: logout`). Sign out then ends the Authentik session and
returns the browser to the UI, which starts a fresh sign-in. The match is exact:
`https://tockmox.<internalDomain>/` and `https://tockmox.<internalDomain>` are
different strings, and the UI sends the value exactly as written. Authentik
honours a post-logout address only with an `id_token_hint`, so the UI keeps the
ID token from sign-in in its own cookie for that one purpose; a session that
predates the upgrade has none, and its first Sign out lands on Authentik's page
instead. Set the value only once the URI is registered: an unregistered one
makes Authentik refuse the logout, and the Authentik session survives. Unset,
Sign out ends on Authentik's own sign-in page. If the issuer cannot be reached,
Sign out still ends the UI's session and logs that it could not end Authentik's.

**Set the grant types explicitly.** A provider registered through the ORM or API
with the other fields filled and `Grant types` left empty accepts nothing, and
every sign-in ends at Authentik with `invalid_request: The request is otherwise
malformed`. Nothing in that message names the cause; Authentik's server log says
`Invalid grant_type for provider: authorization_code`. If you see that error,
the provider's grant types are empty (measured on a lab install, 2026-10-09).

The UI gives the admin role to members of `tockmox-admins`
(`config.roles.adminGroup` changes it).

### Trusting the Tockmox CA

The UI does its OIDC token exchange itself, from inside its pod, so with
`global.certIssuer` set (the default, `tockmox-ca`) it must trust the CA that
signed `auth.<internalDomain>`. The chart does that the way it does for Open
WebUI: a `tockmox-trust-bundle` initContainer, on the UI's own image, writes that
image's public roots plus the CA from the UI's own certificate Secret
(`tockmox-ui-tls`), and `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` point at the
result. Public HTTPS (the update feed, the watcher's sources) keeps working,
because the bundle is the image's store with the CA added, not the CA alone.
With `certIssuer` set the initContainer waits up to five minutes for
cert-manager to issue the certificate, then exits so kubelet retries. Without
it, every sign-in answered 503, "The identity provider did not answer" (0.8.0
lab rehearsal).

## What it may reach

The pod carries `tockmox.com/isolated`, so the policy layer's namespace-wide
allows skip it, ingress and egress alike, and its own NetworkPolicy is the whole
of what it may do. It reaches nothing in its own namespace: not the model
gateway, not Open WebUI.

**In:** Traefik's pods, on 8080; Prometheus, on the metrics port 9464 (see
[Its own failures](#its-own-failures-logs-metrics-alerts)). Nothing else in the
cluster reaches it.

**Out:**

| To | When |
|---|---|
| DNS in `kube-system` | always |
| the Kubernetes API, on 6443 | always: `tockmoxUi.networkPolicy.apiServer`, or `global.lanCIDR` when that is empty |
| Prometheus and Alertmanager | always; the policy layer's `allow-from-tockmox-ui` admits it at the monitoring namespace's end |
| Traefik's pods | always (the OIDC issuer is served through it; but see [When sign-in is unavailable](#when-sign-in-is-unavailable) if the issuer's name resolves to a LoadBalancer address) |
| `inferenceNodes.probe.allowedCidrs` | **only when that list is set** (the probe is off by default) |
| HTTPS to the internet, except private ranges | **only when `config.updateCheck.enabled` with an `https://` feed** (a feed mounted from a ConfigMap needs none) |
| `tockmoxUi.networkPolicy.extraEgress` | whatever you add |

With probing and the update check off, the UI cannot reach an inference node or
the internet at all, and the render check holds that.

**Kubernetes authority:** get and list on nodes, and on Argo CD applications in
their namespace. No Secrets and no writes. The Role and RoleBinding live in the
Argo CD namespace, so the Application that installs the AI layer must be allowed
to create them there.

### When sign-in is unavailable

`/login` answers 503 "Sign-in is unavailable ... The identity provider did not
answer" when the UI cannot fetch the issuer's discovery document. The pod log
says why, on a line like:

```
WARNING:     tockmox_ui sign-in discovery failed: ConnectError: [Errno 111] Connection refused
```

`kubectl -n <ai namespace> logs deploy/tockmox-ui | grep sign-in` finds it, and
`TockmoxUISignInFailing` fires about six minutes after the first failure. The
alert goes pending at the first rule evaluation that sees the failed attempt,
which is at most 90 seconds away (the chart scrapes every 30 seconds and
evaluates the rule every minute), and it fires once it has been pending for its
`for: 5m`, so never later than 6 minutes 30 seconds. Measured on a 0.8.1 lab
install on 2026-10-20: pending 58 seconds after the first failed sign-in,
firing 5 minutes 58 seconds after it. Your notification arrives after that, by
whatever grouping delay your Alertmanager route sets.

**Connection refused, with the issuer behind a LoadBalancer address.** The
policy admits Traefik's *pods*. If the issuer's hostname resolves to the
LoadBalancer address in front of Traefik (a VIP from MetalLB, kube-vip or
k3s's servicelb), the connection leaves the pod addressed to that VIP, and the
NetworkPolicy is evaluated against the VIP, before it is translated to a
Traefik pod. A pod-selector rule never matches it. Allow the address itself
(homelab, 2026-10-11; Open WebUI hit the same thing on the same cluster):

```yaml
tockmoxUi:
  networkPolicy:
    extraEgress:
      - to:
          - ipBlock: {cidr: 10.0.0.50/32}   # the address the issuer's name resolves to
        ports:
          - {protocol: TCP, port: 443}
```

A CoreDNS override that points the issuer's name at Traefik's ClusterIP Service
avoids the VIP instead, and is the better fix where the cluster's DNS is yours
to change.

**Certificate verify failed.** The trust bundle above. The log line names
`CERTIFICATE_VERIFY_FAILED`.

## The update check

Off by default: with `config.updateCheck.enabled` unset the UI makes no request
outside your cluster. On, it reads one signed file about once a day, compares
the newest stable release in it with the running one, and shows the result on
the version page and in the footer. It sends nothing about your site.

```yaml
tockmoxUi:
  config:
    updateCheck:
      enabled: true
      feedUrl: https://<where the feed is published>/releases.json
      publicKeys: ["<base64 Ed25519 public key>"]
```

The feed is `{"schema": 1, "expires": <unix seconds>, "releases": [{"version",
"date", "notes", "notesUrl", "minUpgradeFrom", "breaking": [...], "security"}]}`
and `releases.json.sig` beside it is a base64 Ed25519 signature over the exact
bytes. A feed that does not verify, has expired, or has another shape
contributes nothing to the page. **The project does not publish a feed yet**;
until it does, the check is for a feed you sign yourself.

**A feed from a ConfigMap**, for an air-gapped site or a test: put
`releases.json` and `releases.json.sig` in a ConfigMap in the AI namespace, set
`tockmoxUi.updateFeed.configMap` to its name and `feedUrl` to
`file:///feed/releases.json`. The NetworkPolicy then opens no HTTPS at all.

## Its own failures: logs, metrics, alerts

Every failure the UI catches is logged at WARNING on logger `tockmox_ui` (the
stage or source, the exception class and its message; never a token, cookie or
claim) and counted:

| Metric | Labels | What |
|---|---|---|
| `tockmox_ui_oidc_failures_total` | `stage`: `discovery`, `token` | a sign-in step that failed |
| `tockmox_ui_source_failures_total` | `source`: the status source's name | a read of a status source that failed |

Every series exists at 0 from the pod's start, so `increase()` sees the first
failure. The counters are served at `/metrics` on port 9464
(`TOCKMOX_UI_METRICS_PORT`), **not** on the app port: the Ingress routes the
whole app port to the UI's host, and `/metrics` there would be readable without
signing in. The NetworkPolicy admits Prometheus to 9464 and nothing else.

With the observability capability's `serviceMonitors` on, the chart adds a
ServiceMonitor and two alerts:

| Alert | Fires when |
|---|---|
| `TockmoxUISignInFailing` | any sign-in step failed in the last 15 minutes (for 5m), labelled by `stage` |
| `TockmoxUIUnreachable` | Prometheus has had no healthy scrape of the UI for 10 minutes: the pod is gone or not Ready, or its policy no longer admits Prometheus |

Source failures are counted but not alerted: the UI reads a source only when a
page asks for it, so their rate measures page views as much as health. The
status page and `/api/v1/status` already show a failing source as `unknown`.

## The capabilities page

`/capabilities` (admins) lists each capability, one switch for a whole story
such as single sign-on or backups, with two facts beside it:

- **Set to**: the switch as the AI layer resolves it from your site values. A
  site may set `capabilities` in one layer's values file only, so this is the AI
  layer's view.
- **Deployed**: whether Argo CD reports the owning layer running the
  capability's own workload (Authentik's server, the Prometheus, ntfy or the
  alert bridge, Open WebUI or the gateway, Garage, the hardware exporters, the
  Argo Workflows controller, the policy layer's NetworkPolicies), read from the
  Applications' `status.resources`. No permission beyond the Applications the
  UI already reads.

A row where the two disagree is marked. A layer with no Application, or one
Argo CD has not reconciled recently, reads **Unknown**, never "Not deployed".
The page changes nothing: to turn a capability on or off, set
`capabilities.<name>.enabled` in your site values and commit it.

**Heartbeats are not alerts.** `Watchdog` (Prometheus to Alertmanager) and
`TockmoxHeartbeat` (the self-check to its off-cluster dead-man's switch) fire
all the time on purpose. The status page shows each as **Alive** and never as a
row in "Alerts firing", and neither counts toward the verdict.

## The status API (provisional)

`GET /api/v1/status` answers what the home and status pages show, as JSON, for
a script or a dashboard that wants the platform verdict without scraping a page.
It is **provisional**: its shape is declared here and may change in a minor
release, named in the release notes. It is the first and only route of a core
read-only API the Admin UI reads from (ruled 2026-10-03, surfaces council); a
later release gives it a separate deployable and its own values keys.

**Who can call it:** a signed-in platform administrator (a member of
`config.roles.adminGroup`), with the same session cookie the pages use. There
is no token, no API key and no other credential. Anonymous answers 401, a
signed-in user outside the admin group 403, both as JSON, neither as a redirect
to the sign-in page. To call it from a script, sign in once in a browser and
reuse that session cookie; the cookie is `HttpOnly`, `SameSite=Lax` and bound to
the UI's host.

**There is no write verb.** `POST`, `PUT`, `PATCH` and `DELETE` on anything
under `/api/` answer 405 with `Allow: GET, HEAD`, whoever asks and before any
sign-in check. The UI holds no git credential and no write authority on the
cluster, so there is nothing a write could reach.

**Absence is not green.** The API reads the same sources, through the same
short cache, as the pages, and keeps their rule: a source that did not answer
this time reads `unknown` with its reason, and the list it would have filled
(`applications`, `nodes`, `alerts`, `inferenceNodes`) is `null`, never `[]`.
Argo CD Application CRs keep their last sync and health when the application
controller stops (found in the lab, 2026-10-05), so every application must carry
a `status.reconciledAt` newer than `sources.kubernetes.argocdStaleSeconds`
(default 600) or its `state` is `unknown` whatever its `sync` and `health` say,
and `version.state` is `unknown` while any Tockmox layer is stale.

**Keep `argocdStaleSeconds` above Argo CD's own refresh period, or a healthy
install warns.** `reconciledAt` moves only when Argo CD reconciles an
application, which is every `timeout.reconciliation` (120s in the `argo-cd`
chart 10.1.x, plus up to `timeout.reconciliation.jitter`, 60s, so up to three
minutes between two moves). A threshold below that reads a healthy application
as stale between refreshes: the lab warned "N applications not reconciled" at
60, and at 150 one layer still read stale once. The default, 600, clears the
chart's defaults several times over. If you raise `timeout.reconciliation`
(`kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'`
prints it), raise this with it.

The response, schema `tockmox-status/1`:

| Field | Type | What |
|---|---|---|
| `schema` | string | `tockmox-status/1`; a breaking change to this shape bumps the number |
| `provisional` | boolean | `true` until the API is promoted |
| `generatedAt` | string | when this answer was built, RFC 3339 UTC |
| `ui.version` | string | the UI's own version |
| `verdict` | string | `ok`, `warning`, `critical` or `unknown`: critical beats unknown beats warning beats ok, and `ok` needs every source to have answered healthy |
| `sources` | object | one entry per source the verdict is made of (`apps`, `nodes`, `prometheus`, `alertmanager`, and `inference_nodes` when nodes are configured), each `{name, state, reason, fetchedAt, lastOkAt}`; `fetchedAt` is `null` when the source did not answer this time |
| `applications` | array or `null` | every Argo CD Application in the Argo CD namespace, each `{name, tockmoxLayer, repo, revision, sync, health, reconciledAt, state, reason}`; `state` applies the staleness rule above, then `Degraded` or `Missing` is `critical`, `OutOfSync`, `Progressing` or `Suspended` is `warning`, `Synced` and `Healthy` is `ok` |
| `version` | object | the running Tockmox version as the version page derives it: `state` is `single` (with `version`), `mixed` (with `revisions`), `floating` (with `ref`) or `unknown` (with `reason`) |
| `nodes` | array or `null` | Kubernetes nodes, each `{name, ready, version}` |
| `alerts` | array or `null` | the alerts firing in Alertmanager, heartbeat included, each `{name, severity, namespace, summary, startsAt}`; an empty list without the heartbeat makes `sources.alertmanager` `unknown` |
| `inferenceNodes` | array or `null` | with `inferenceNodes.nodes` set, each node's `{id, state, reason, checks: [{what, state, reason}], memory}` as the nodes page reads them from Prometheus; `null` when none is configured |
| `capabilities` | array | added in 0.8.0-rc2 (TM-1017): each capability's `{key, configured, deployed, agree, evidence}` as the [capabilities page](#the-capabilities-page) shows it; `configured` is `on`, `off` or `null`, `deployed` is `on`, `off` or `unknown` |

Every `state` is one of `ok`, `warning`, `critical`, `unknown`. A healthy
single-node install answers, cut down:

```text
{"schema": "tockmox-status/1", "provisional": true, "generatedAt": "2026-10-08T21:14:03Z",
 "ui": {"version": "0.0.1-proto"}, "verdict": "ok",
 "sources": {"apps": {"name": "Argo CD applications", "state": "ok", "reason": "4 synced and healthy",
                      "fetchedAt": "2026-10-08T21:14:03Z", "lastOkAt": "2026-10-08T21:14:03Z"}, ...},
 "applications": [{"name": "tockmox-ai", "tockmoxLayer": true, "repo": "https://github.com/tockmox/tockmox",
                   "revision": "v0.8.0", "sync": "Synced", "health": "Healthy",
                   "reconciledAt": "2026-10-08T21:13:41Z", "state": "ok", "reason": ""}, ...],
 "version": {"state": "single", "version": "v0.8.0"},
 "nodes": [{"name": "node-1", "ready": "Ready", "version": "v1.36.5+k3s1"}],
 "alerts": [{"name": "Watchdog", "severity": "none", "namespace": "", "summary": "", "startsAt": "..."}],
 "inferenceNodes": null}
```

A stopped Argo CD controller answers the same `sync` and `health` for every
application, with `state: "unknown"`, `sources.apps.reason` saying it has
stopped reconciling, `verdict: "unknown"` and no `version.version`. That case is
held by `tockmox-ui/tests/test_status_api.py`, which also proves the 401, the
403 and the 405s. The API has not yet been called on a lab install.

## The watcher's report

With `modelLifecycle.watch.enabled`, the UI mounts the watcher's report volume
read-only and shows what is newer upstream. The watcher itself is a separate
CronJob with its own, narrower policy; [model lifecycle](model-lifecycle.md)
covers it.

## Upgrading

The UI keeps no state of its own: no database, nothing written in the pod, and a
session is a signed cookie. What survives an upgrade is yours and is not touched
by it:

| State | Where | On upgrade |
|---|---|---|
| the session signing key | Secret `tockmox-ui-session` (or `tockmoxUi.secrets.session`) | kept; signed-in users stay signed in. Rotate it to sign everyone out |
| the OIDC client secret | Secret `tockmox-sso-tockmox-ui` (or `tockmoxUi.secrets.oidcClient`) | kept |
| the UI's configuration | `tockmoxUi.config` in your site values, rendered into a ConfigMap | re-rendered from your values; a change restarts the pod |
| the watcher's report | volume `tockmox-model-watch-report`, when `modelLifecycle.watch.enabled` | kept while the watcher stays enabled; it is re-derived on the watcher's next run if lost |

So an upgrade of the UI is: build the image from the new tag, push it, and set
`tockmoxUi.image` to it in the same commit that moves the charts' revision. The
chart does not pin or check the image tag, so a UI built from an older tag keeps
running against newer charts until you change it, and reports the older
version. Rolling back is the same commit reverted.

One exception: charts from 0.8.0-rc1 on scrape the UI's metrics port, which an
image built from an earlier revision does not open, so with an older image
`TockmoxUIUnreachable` fires after ten minutes. Rebuild the image with the
charts.

Turning the watcher off lets Argo CD prune its report volume; turning it on
again starts from an empty report.

## What is not certified here

- **One lab, one node.** The chart, the image built from this directory and the
  network policy were run on a single-node k3s lab on 2026-10-07 (17 of 17
  checks, policy enforced). A multi-node cluster has not run it. The 2026-10-08
  rehearsal (greenfield and an upgrade from 0.7.2) found sign-in failing on the
  Tockmox CA, Prometheus and Alertmanager refused at the monitoring namespace,
  and the UI reaching the model gateway; the trust bundle, the monitoring allow
  and the isolated-pod exclusion above are the fixes, proven by render. Their
  lab re-proof is pending.
- **The report volume on more than one node.** The watcher writes the report
  volume and the UI mounts it read-only. With the default
  `modelLifecycle.watch.report.accessModes: [ReadWriteOnce]` the volume attaches
  to one node, so with both on the chart requires the watcher onto the UI pod's
  node and rolls the UI with `maxSurge: 0`, so the old pod releases the volume
  before the new one starts. Not `Recreate`: Kubernetes refuses that change on a
  running Deployment under server-side apply, and the AI layer stays OutOfSync
  (0.8.0 lab rehearsal). Derived from the chart; not yet run on
  a multi-node cluster. With `ReadWriteMany` neither is forced;
  `ReadWriteOncePod` is refused, because two pods use the volume.
- **An upgrade from one built image to the next** has not been run end to end;
  the table above is derived from the chart and the application's source, not
  measured.
- **The build's dependencies are version ranges**, not pins, so two builds of
  one tag can differ in their Python packages.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

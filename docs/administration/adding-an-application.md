# Adding an application ... the full wiring, worked end to end

This page adds a real application to a running Tockmox and wires it into
everything the platform offers: its own namespace and network policy, a
managed PostgreSQL with backups, an ingress hostname, single sign-on,
Prometheus metrics, and a Grafana dashboard. The example is
[Miniflux](https://miniflux.app) ... a small RSS reader chosen because it
exercises every integration point (native OIDC, /metrics, needs a database)
while staying one container. Substitute your app; the shape is the point.

Everything here lives in **your site repository** under `apps/`. The
installer generates a `site-apps` Application that syncs that directory, so
`git push` is the deploy button. Nothing below touches the Tockmox charts.
To take an app back out, see [removing an application](removing-an-application.md).

## 0. The rules that keep upgrades free

Before 1.0 the only promise is the
[values contract](values-contract.md#before-10-there-is-no-downstream-abi): the
service names, Secret shapes and endpoints below are the supported wiring today,
not a frozen interface.

- Namespace: pick your own (`news` here). The `tockmox-` prefix is reserved.
- Reference platform services by their documented names
  (`tockmox-garage.tockmox-platform.svc`, `auth.<internalDomain>`); never patch
  platform objects from your app. Every component in a layer lands in THAT
  LAYER'S namespace, not in the namespace its upstream project conventionally
  uses ... so it is `tockmox-platform`, never `garage` or `cert-manager`. If you
  installed a layer somewhere other than the default, substitute accordingly.
- Secrets are operator-created (sealed in your site repo), never plaintext
  in manifests.

## 1. Namespace + network policy

Site namespaces get NO policy from Tockmox ... bring your own, using the same
recipe the guarded namespaces use (default-deny ingress, then explicit
allows):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: news
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: news }
spec: { podSelector: {}, policyTypes: [Ingress] }
---
# intra-namespace (app -> its database)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-intra-namespace, namespace: news }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: news }
---
# Traefik -> the UI (Traefik lives in the platform namespace)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-from-traefik, namespace: news }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: tockmox-platform }
          podSelector:
            matchLabels: { app.kubernetes.io/name: traefik }
---
# Prometheus -> /metrics
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-prometheus-scrape, namespace: news }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: tockmox-monitoring }
          podSelector:
            matchLabels: { app.kubernetes.io/name: prometheus }
---
# CNPG operator -> your database pods (skip if no database)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-cnpg-operator, namespace: news }
spec:
  podSelector:
    matchLabels: { cnpg.io/cluster: miniflux-db }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: tockmox-platform }
      ports:
        - { protocol: TCP, port: 8000 }
        - { protocol: TCP, port: 5432 }
```

## 2. A managed database (CNPG), with backups from day one

The platform ships the CloudNativePG operator; a database is one CR. Wire
backups in the same commit ... see
[backup-restore](../operations/backup-restore.md) for the ObjectStore CR and
where the S3 credentials come from.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: miniflux-db, namespace: news }
spec:
  instances: 1              # 3 on a multi-node cluster
  storage: { size: 2Gi }
  bootstrap:
    initdb: { database: miniflux, owner: miniflux }
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      enabled: true
      isWALArchiver: true
      parameters: { barmanObjectName: miniflux-db-store }
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata: { name: miniflux-db-nightly, namespace: news }
spec:
  schedule: "0 0 3 * * *"
  backupOwnerReference: self
  cluster: { name: miniflux-db }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
```

CNPG mints `miniflux-db-app` with a ready-made connection `uri` key ... your
app never sees a hand-managed database password.

## 3. The application, consuming everything by reference

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: miniflux, namespace: news }
spec:
  replicas: 1
  selector: { matchLabels: { app.kubernetes.io/name: miniflux } }
  template:
    metadata: { labels: { app.kubernetes.io/name: miniflux } }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: miniflux
          image: miniflux/miniflux:2.3.3
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
            readOnlyRootFilesystem: true
          ports: [{ name: http, containerPort: 8080 }]
          env:
            - name: DATABASE_URL
              valueFrom: { secretKeyRef: { name: miniflux-db-app, key: uri } }
            - { name: RUN_MIGRATIONS, value: "1" }
            - { name: BASE_URL, value: "http://news.int.example.com/" }
            # local break-glass admin, from a secret you sealed
            - { name: CREATE_ADMIN, value: "1" }
            - name: ADMIN_USERNAME
              valueFrom: { secretKeyRef: { name: miniflux-oauth, key: admin-username } }
            - name: ADMIN_PASSWORD
              valueFrom: { secretKeyRef: { name: miniflux-oauth, key: admin-password } }
            # single sign-on (section 5)
            - { name: OAUTH2_PROVIDER, value: "oidc" }
            - { name: OAUTH2_CLIENT_ID, value: "tockmox-miniflux" }
            - name: OAUTH2_CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: miniflux-oauth, key: client-secret } }
            - { name: OAUTH2_OIDC_DISCOVERY_ENDPOINT, value: "http://auth.int.example.com/application/o/tockmox-miniflux/" }
            - { name: OAUTH2_REDIRECT_URL, value: "http://news.int.example.com/oauth2/oidc/callback" }
            - { name: OAUTH2_USER_CREATION, value: "1" }
            # metrics (section 6)
            - { name: METRICS_COLLECTOR, value: "1" }
            - { name: METRICS_ALLOWED_NETWORKS, value: "10.42.0.0/16" }
          readinessProbe:
            httpGet: { path: /healthcheck, port: http }
---
apiVersion: v1
kind: Service
metadata:
  name: miniflux
  namespace: news
  labels: { app.kubernetes.io/name: miniflux }
spec:
  selector: { app.kubernetes.io/name: miniflux }
  ports: [{ name: http, port: 80, targetPort: http }]
```

## 4. The way in ... Ingress + DNS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: miniflux, namespace: news }
spec:
  rules:
    - host: news.int.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: miniflux, port: { number: 80 } } }
```

No `ingressClassName` ... the shipped Traefik is the cluster default. Add
`news.<internalDomain>` to your LAN DNS (it must resolve from workstations
AND from inside the cluster; the OIDC discovery fetch is server-side).
With a certIssuer, add the cert-manager annotation and a `tls` block exactly
as the shipped ingresses do.

## 5. Single sign-on

Two ways to register the app with Authentik. Same result; pick by taste.

**Quick (admin UI or API):** Authentik admin interface ->
Applications -> Providers -> create an OAuth2/OpenID provider:
confidential client, client ID `tockmox-miniflux`, your generated client
secret, redirect URI `http://news.<internalDomain>/oauth2/oidc/callback`,
the default authorization + invalidation flows, the self-signed signing key,
the openid/email/profile scope mappings ... **and explicit grant types
`authorization_code` + `refresh_token`** (a provider created without them
rejects every login). Then create an Application wrapping the provider.

**Declarative (blueprint in your site repo):** ship a ConfigMap blueprint in
the identity namespace using the exact schema of the shipped
`tockmox-sso-blueprints` (copy an entry; change ids, redirect URI, and the
`!Env` key). Add your key to the `tockmox-sso` Secret so `!Env` resolves,
and add your ConfigMap to the identity chart's blueprint list in site
values ... **lists replace rather than merge in Helm, so restate the shipped
entry**:

```yaml
# site/values/identity.yaml
authentik:
  blueprints:
    configMaps:
      - tockmox-sso-blueprints   # restate the shipped one
      - miniflux-sso-blueprint   # yours
```

Restart the Authentik worker after adding the Secret key (envFrom is read at
pod start), and check Blueprints in the admin UI shows yours `successful`.

Users need no per-app setup: anyone in `tockmox-admins` or `tockmox-users`
signs in; `OAUTH2_USER_CREATION=1` provisions their Miniflux account on
first login.

## 6. Metrics + a dashboard

**Skip this section if your site declines observability**
(`profiles/observability-off.yaml`). That cluster has no ServiceMonitor kind,
and a ServiceMonitor in `apps/` stops `site-apps` from syncing with "could not
find monitoring.coreos.com/ServiceMonitor" (seen on the 0.7.1-rc2 gate). Leave
the object out, and `METRICS_COLLECTOR` with it if nothing will scrape it.

Prometheus discovers any ServiceMonitor in any namespace (deliberate):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: miniflux
  namespace: news
  labels: { app.kubernetes.io/name: miniflux }
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: miniflux }
  endpoints:
    - { port: http, path: /metrics, interval: 30s }
```

Target appears in Prometheus within a scrape interval. For a dashboard, use
the documented extension point: any ConfigMap labelled
`grafana_dashboard: "1"` in any namespace is discovered by Grafana.

## 7. Alerts

A PrometheusRule in your namespace joins the same discovery:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: miniflux
  namespace: news
  labels: { prometheus: kube-prometheus-stack, role: alert-rules }
spec:
  groups:
    - name: miniflux
      rules:
        - alert: MinifluxDown
          expr: absent(up{job="miniflux"} == 1)
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "Miniflux target has disappeared"
```

## Variant: card-only applications

Not everything you want in the Authentik library speaks OIDC. A static site,
an appliance UI, a wiki you have not wired up yet ... any of these can still
get a launch tile: create an Application **without a provider**. It renders
as a card with a launch URL and nothing else.

Visibility is controlled per-card by binding a group policy to the
Application. Bound to `tockmox-admins`, the card appears only for admins;
unbound, it appears for everyone. Declaratively, that is three blueprint
entries:

```yaml
- model: authentik_core.application
  state: present
  id: app-admin-docs
  identifiers:
    slug: admin-docs
  attrs:
    name: Admin Documentation
    meta_launch_url: "http://admin-docs.int.example.com/"
- model: authentik_policies.policybinding
  state: present
  identifiers:
    target: !KeyOf app-admin-docs
    order: 0
  attrs:
    group: !Find [authentik_core.group, [name, tockmox-admins]]
    enabled: true
```

The shipped app blueprints bind the same way, with one difference worth
copying: they restate the group in the same blueprint (`authentik_core.group`,
`state: present`, an `id:`) and bind with `!KeyOf` instead of `!Find`. A
`!Find` resolves against whatever exists when the blueprint applies, and on a
first boot that can be nothing ... a binding with no group puts the blueprint
in `error`, and one blueprint in `error` poisons discovery for all of them.
`tools/check-sso-bindings.sh` holds the shipped set to that rule.

Two things to know. Group-membership changes take up to the policy-cache
TTL to show in the library; force it with
`POST /api/v3/policies/all/cache_clear/` if you need it now. And **hiding
the card does not protect the destination** ... the target is exactly as
reachable as its own authentication makes it. For a card-only app that
must actually be restricted, put forward-auth in front of its hostname; a
provider-less Application is a menu entry, not a lock.

## The checklist

| Wiring | Mechanism | Proof |
|---|---|---|
| Namespace + netpol | your manifests, deny-by-default recipe | app reachable ONLY via Traefik |
| Database | CNPG `Cluster` CR | `miniflux-db-app` secret; cluster `healthy` |
| Backups | `ObjectStore` + `plugins:` + `ScheduledBackup` | on-demand `Backup` completes; objects in the bucket |
| Ingress | plain Ingress, default class | hostname serves through Traefik |
| SSO | Authentik provider + app (UI or blueprint) | group member signs in, account auto-created |
| Metrics | ServiceMonitor | target `up` in Prometheus |
| Alerts | PrometheusRule | rule visible in Prometheus |
| Dashboard | labelled ConfigMap | appears in Grafana |

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

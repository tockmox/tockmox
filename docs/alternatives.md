---
okf_version: "0.2"
type: Reference
title: "Alternatives register"
description: "For each part of the Tockmox stack, the default, the alternatives that were considered, their licence class, when to prefer them and what support Tockmox gives, plus the products deliberately absent and why."
tags: [alternatives, licensing, bom, support-tier, open-core, register]
status: stable
generated:
  by: hand
  at: 2026-10-09
tockmox:
  classification: public
  audience: [operator]
---

# Alternatives register

**Last scanned: 2026-10-06.** Third-party licence and feature-tier statements on
this page were re-read on that date against each project's own licence file,
documentation or pricing page. The component scan the register is built on dates
from 2026-09-19. The next scan is due at the next quarterly sweep (see
[Keeping this page current](#keeping-this-page-current)).

Every Tockmox component is a choice, and most of them have a defensible
alternative. This register exists so you can make those choices deliberately
rather than discovering the constraint after you have deployed.

## How to read this

**Support tier** says what you get from Tockmox, not how good the software is:

| Tier | What it means |
|---|---|
| **tested** | Runs in the Tockmox reference implementation and is exercised by the release gate. If it breaks, it is a Tockmox defect. |
| **documented** | The substitution is written down and expected to work. It is not exercised by the gate. Defects in the alternative are yours, but the instructions are not. |
| **unsupported** | Known to work for somebody. No instructions, no gate coverage, no help. Listed so you know it exists and what it costs. |

**Licence class** is a screen, not legal advice, and it is the reason several
otherwise-good options are absent:

| Class | Meaning for a Tockmox deployment |
|---|---|
| **permissive** | Apache-2.0, MIT, BSD, the PostgreSQL License, and MPL-2.0. MPL-2.0 is file-level copyleft: it matters only if you modify the licensed files and redistribute them. |
| **copyleft (aggregated)** | AGPL or GPL, deployed as an unmodified upstream service by a chart. Fine as shipped; **patching the source changes the analysis.** |
| **copyleft (linked)** | AGPL or GPL in something loaded into another process (a Postgres extension, a library). Unresolved for Tockmox, so not shipped. |
| **non-OSI** | An otherwise-permissive licence with an added restriction (branding, field of use, user count, revenue threshold). Legal to run, **constrains what you may do with it.** Disclosed where shipped. |
| **gated** | Access-control basics such as SSO, RBAC, permissions or audit are listed by the vendor under a paid tier. Not shipped as a Tockmox default. Listed to explain an absence. |

**One standing rule behind most of the exclusions below.** Tockmox will not make
a component the default if signing in to it, or controlling who can do what in
it, requires somebody to buy a licence. A platform whose access-control story
depends on a third party's commercial tier is not a sovereign platform. That rule
has cost this project several technically excellent options, and the register
names them rather than pretending they were not considered.

**What this page does and does not claim.**

- Statements about a third party's licence or paid tier say what the licence or
  the vendor's page says, "as of" the scan date, and link or name the source
  where the statement is specific. Vendors change tiers: check the vendor's page
  before you rely on one.
- Statements about footprint, behaviour and fit (pod counts, memory floors, what
  an alternative lacks) are observations from the 2026-09-19 component scan.
  They were not part of the licence review and may have moved.
- Licence classes for Calico and Traefik were not re-read on 2026-10-06 (the
  licence file could not be fetched at the path tried). Foundation-tier labels
  (CNCF Sandbox, Incubating, Graduated) were not checked and are not stated here.
- Where this page and a vendor's own page disagree, the vendor's page is right
  and this page has a defect worth reporting.

## What ships in this release

The register names a default for each part of the stack. Not every default is
something this release ships. **The "tested" tier applies only to defaults marked
"ships" below**; for the others, the default is the stack's intended choice and
the alternatives are compared against it.

| Part | Default named in this register | In this release |
|---|---|---|
| Kubernetes | k3s | You build it; [fresh-install](deployment/fresh-install.md) sets it up |
| Node operating system | openSUSE MicroOS | The reference deployment's OS; you supply it |
| CNI | flannel with k3s's embedded network-policy controller | Part of k3s |
| Ingress, load balancer, certificates | Traefik, MetalLB, cert-manager | Ship in the platform layer |
| API endpoint address | kube-vip | Documented in [api-endpoint](administration/api-endpoint.md); not shipped |
| trust-manager | trust-manager | Not shipped |
| Block storage | Longhorn | Ships |
| Database storage class | TopoLVM | Not shipped; databases use `local-path` today, see [storage](administration/storage.md) |
| Object storage | Garage | Ships |
| PostgreSQL operator | CloudNativePG | Ships |
| Identity | Authentik | Ships |
| Secrets | Sealed Secrets | A prerequisite you install |
| Container registry | zot | Not shipped; a registry is a prerequisite, see [registry](deployment/registry.md) |
| GitOps | Argo CD | A prerequisite you install |
| Workflows | Argo Workflows | Ships |
| Dependency updates | Renovate (self-hosted) | Not shipped |
| Metrics, logs, alerting | Prometheus stack, Loki, Alloy, Grafana, Alertmanager, ntfy | Ship |
| Traces, OpenTelemetry collector | Tempo, OpenTelemetry Collector | Not shipped |
| AI gateway and console | LiteLLM, Open WebUI | Ship |
| Retrieval, document conversion | PostgreSQL with pgvector, Docling | Not shipped |
| Web search | SearXNG | Not shipped, and not planned as an add-on |
| Model serving | `mlx-lm.server` and `llama-server` on Apple Silicon | Off-cluster; see [inference nodes](administration/inference-nodes.md) |

---

## Substrate

### Kubernetes distribution

**Default: k3s** ... permissive (Apache-2.0)

k3s removes no API group, sets no feature gates, and passes every flag through
to each control-plane component, so nothing upstream Kubernetes can do is
unavailable. Its defaults include `anonymous-auth=false`, `profiling=false` and
`NodeRestriction` pre-enabled.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **RKE2** | permissive | **You need FIPS 140-2/140-3.** k3s has no FIPS story at any version; RKE2 does, across the control plane and the runtime. Also restores per-component logging, control-plane pods, and standard control-plane metrics ports. Same vendor, largely config-compatible. | documented |
| **kubeadm / upstream** | permissive | An existing standard-Kubernetes estate you must match. You hand-assemble etcd, CNI, load balancing, ingress, DNS, metrics-server and image mirroring, then own the upgrade choreography. | unsupported |
| **Talos Linux** | permissive (Talos is MPL-2.0) | You want an API-managed immutable OS and accept upstream Kubernetes. Its operational satellites are BSL 1.1: Omni's Additional Use Grant covers non-production use and home labs and excludes environments the licensee depends on; `discovery-service` carries "Additional Use Grant: None" with a Change Date of 2030-10-05 to MPL-2.0. | unsupported |

**Known limitation, stated plainly.** Tockmox has **no FIPS story**. Neither k3s
nor openSUSE MicroOS provides FIPS-validated cryptography, so a FIPS requirement
reopens both layers together. If that is a procurement gate for you, run the
charts on RKE2 and a FIPS-capable node OS. The charts are distribution-portable;
this is a substrate decision, not a Tockmox one.

### Node operating system

**Default: openSUSE MicroOS** (with `transactional-update` and kured) ... permissive

Immutable, transactional, automatic rollback on a bad update.
`REBOOT_METHOD=kured` is a documented upstream value, not a community
arrangement.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **Flatcar Container Linux** | permissive | You want an **LTS channel** rather than a rolling release. Flatcar's repository is Apache-2.0; the OS image aggregates many component licences. Preserves both k3s and kured, and offers k3s as a versioned atomic `sysext` overlay ... a single `.raw` to mirror for air-gap. | documented |
| **Leap Micro 6.x** | permissive | You want MicroOS's exact model on a slower cadence. Same `transactional-update`, same kured, same reboot method. A config change, not a migration. | documented |
| **Fedora CoreOS** | permissive | Existing Fedora/RHEL operational knowledge. The air-gap update path is more work. | unsupported |
| **Ubuntu Core** | mixed | **Not recommended.** Canonical's [Enterprise Store](https://canonical.com/blog/canonical-announces-the-enterprise-store) is included in Ubuntu Pro, which Canonical describes as free for personal use on up to 5 machines. Canonical documents an offline mode for the Enterprise Store; Tockmox has not evaluated that route for a Dark Site. | unsupported |

### Networking, ingress, certificates

**Defaults: flannel with k3s's embedded network-policy controller; Traefik;
MetalLB with kube-vip; cert-manager with trust-manager.** See
[What ships in this release](#what-ships-in-this-release) for which of these
the charts deploy.

| Component | Alternative | Class | When to prefer | Tier |
|---|---|---|---|---|
| CNI | **Calico** | permissive | **You need network-policy audit evidence.** The embedded controller enforces policy correctly but produces no denied-connection metric, and its drop logging does not cover empty-`podSelector` (default-deny) policies. Calico's flow-log UI (Whisker, a tech preview) is [installed by default in new Calico Open Source 3.30+](https://docs.tigera.io/calico/latest/observability/enable-whisker), and Calico does not require replacing kube-proxy. | documented |
| CNI | **Cilium** | permissive | L7 or identity-aware policy, mTLS, CNI-native Gateway API, or eBPF observability. Note `kubeProxyReplacement=true` is a hard prerequisite for its load-balancing, ingress and Gateway features, so it cannot be adopted incrementally, and it adds roughly 14 pods against the default's zero. | unsupported |
| Ingress | **Envoy Gateway** | permissive (Apache-2.0) | **You need inference-aware routing** (Gateway API Inference Extension, `InferencePool`, KV-cache-aware routing to model servers). That ecosystem has consolidated on Envoy's `ext_proc`, which Traefik does not implement. Envoy Gateway [documents OIDC authentication through `SecurityPolicy`](https://gateway.envoyproxy.io/docs/tasks/security/oidc/); Traefik's docs mark the OIDC, JWT and Client Credentials middlewares as Traefik Hub API Gateway features. Costs roughly 800Mi of requests for a single Gateway against Traefik's one pod. **It can run alongside Traefik on a separate GatewayClass** ... you do not have to move the whole edge. | documented |
| Ingress | ingress-nginx | n/a | **Do not.** The Kubernetes project [announced](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) that best-effort maintenance would continue until March 2026, and afterwards there would be no further releases or bugfixes. Its named successor, InGate, was retired and its repository archived on 2026-06-30. | n/a |
| Service LB | k3s ServiceLB (Klipper) | permissive | Single-node or throwaway clusters only. It is not a load balancer ... it binds hostPorts and writes node IPs into the Service status. No virtual IP, global port collisions, and topology is managed by node labels rather than CRs. | unsupported |
| Certificates | **step-ca**, **OpenBao PKI** | permissive | You need a CA that outlives the cluster, SSH certificates, or device attestation. Otherwise short `duration` and `renewBefore` on cert-manager Certificates gets you most of the rotation benefit at zero additional pods. | unsupported |

---

## Data plane

### Block storage

**Default: Longhorn, v1 engine, replica count 3** ... permissive

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **Longhorn v2 (SPDK) engine** | permissive | **10GbE or better, and headroom to spare.** It costs one dedicated CPU core and 2 GiB of hugepages per storage node before a single volume exists, and requires kernel 6.7+ with `vfio_pci` / `uio_pci_generic` / `nvme-tcp`. On a 2.5GbE fabric the replicated-write ceiling (~145 MB/s) makes the benefit largely unrealizable. It also does not support `dataLocality: strict-local` and, as of 1.13, still does not support engine live upgrade. | documented |
| **OpenEBS Replicated PV (Mayastor)** | permissive | You are already an OpenEBS shop. Same SPDK host tax as Longhorn v2, without Longhorn's conservative v1 fallback. | unsupported |
| **Rook-Ceph** | permissive | Large clusters, object plus block plus file from one system, a team to operate it. Wrong shape for a small on-prem deployment: high memory floor and recovery storms on modest fabrics. | unsupported |
| **local-path only** | permissive | A single-node deployment, or one where every stateful workload replicates at the application layer. You lose snapshots, resize, clone, and any automatic recovery from node loss. | documented |
| Piraeus / LINSTOR, Cozystack Blockstor | permissive | **Not recommended for Tockmox.** Both are DRBD-backed, and DRBD is an out-of-tree kernel module built per kernel ... a support surface a source-only platform for solo operators should not carry. | n/a |

### Database storage class

**Default for PostgreSQL: local NVMe through TopoLVM, not the replicated class**
... permissive. This release does not ship TopoLVM; see
[What ships in this release](#what-ships-in-this-release).

The reasoning is CloudNativePG's own guidance, and it holds whichever local
class you use. A three-instance Postgres cluster on a replica-count-3 block
store writes every page nine times across the fabric, because Postgres is
already replicating. Use local storage under the database and let Postgres do
the replication, with pod anti-affinity and WAL archiving to object storage.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **OpenEBS LocalPV-LVM** | permissive | A genuine peer to TopoLVM. It now supports snapshot **restore** as well as create. It still lacks PVC-to-PVC clone, restore to a larger target, and resize of a volume that has snapshots. | documented |
| **OpenEBS LocalPV-ZFS** | permissive | Technically the strongest local option. **Not recommended on an immutable or rolling-release node OS**, because ZFS is an out-of-tree module built per kernel. | unsupported |
| Replicated class under the database | permissive | Only if you run a **single** Postgres instance and want the storage layer to provide the resilience. Do not combine storage replication with Postgres replication. | documented |

### Object storage

**Default: Garage** ... copyleft (aggregated, AGPL-3.0)

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **SeaweedFS** | permissive (Apache-2.0) | **You need object lock, versioning, or conditional writes.** Garage cannot provide these. Also the answer if AGPL is unacceptable in your organisation. SeaweedFS's README lists self-healing storage and EC vacuum and repair under its Enterprise Edition. The open-source edition includes a manual `ec.scrub` checksum check; the scheduled background scrubber with auto-repair is Enterprise. | documented |
| **Ceph RGW** | permissive | You already run Ceph. Otherwise the operational floor is far above what a small deployment should spend on object storage. | unsupported |
| MinIO | n/a | **Do not.** The upstream repository shows "archived by the owner on Apr 25, 2026. It is now read-only", and its README says MinIO is now distributed as source code only, with no pre-compiled binary releases. Community forks exist; none has a maintainer base worth depending on. | n/a |

**Known limitation.** Garage has no object lock, no versioning and no conditional
writes. Any workload requiring an immutable backup tier, S3-based distributed
locking, or table formats such as Iceberg or Delta needs a different store.

### Databases

**Default: CloudNativePG** ... permissive (Apache-2.0 code, CC BY 4.0 docs)

Chosen for its licence, its small per-pod footprint and images that mirror
cleanly.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **Percona Operator for PostgreSQL** | permissive | You want pgBackRest with a **PVC-backed local repository**, giving point-in-time recovery with no object store at all. Percona's [telemetry page](https://docs.percona.com/percona-operator-for-postgresql/2.0/telemetry.html) (for operator 2.0) says "Telemetry is enabled by default" (`DISABLE_TELEMETRY: "false"`); check the version you deploy, disable it explicitly, and verify it, before any sovereign deployment. Runs 7+ pods per database cluster. | unsupported |
| **Zalando postgres-operator** | permissive (MIT) | Existing Spilo/Patroni operational knowledge. | unsupported |
| **StackGres** | not re-read | Its licence was not re-read on 2026-10-06; check it before use. **Fails on footprint**: mandatory sidecars add a ~576Mi floor *per Postgres pod* with no disable flag, and there is no air-gap install guide. | unsupported |
| Crunchy PGO / CPK | permissive source (Apache-2.0), **separate image terms** | **Not used.** The operator source is Apache-2.0. Container images from the Crunchy Data Developer Portal are under Crunchy Data Developer Program terms, and some older image versions return "no longer available". The install manifests were not at the paths the repository README names when checked on 2026-10-06. Read the Developer Program terms before mirroring the images. | n/a |

---

## Platform services

### Identity

**Default: Authentik** ... permissive core (MIT) with a proprietary
`enterprise/` directory

**The boundary, stated explicitly, because you should not have to discover it.**
authentik's [pricing page](https://goauthentik.io/pricing/) lists OIDC, SAML,
LDAP, SCIM, RADIUS, Kerberos and Proxy as supported. authentik's
[enterprise features page](https://docs.goauthentik.io/enterprise/enterprise-features)
lists, as Enterprise features: privileged access management, non-human agent
accounts, Google Workspace and Entra directory sync, client-certificate and mTLS
authentication, RADIUS EAP-TLS, scheduled offboarding, CSV export, enhanced audit
logging with before-and-after diffs, and a FIPS-compliant deployment mode. The
last two matter if you are in a regulated environment. Tockmox enables no
Enterprise feature.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **Keycloak** | permissive (Apache-2.0) | You want an identity provider under one permissive licence. Keycloak documents the Operator (OLM or kubectl) and an [experimental Operator Helm chart](https://www.keycloak.org/operator/installation) published as an OCI artifact. Costs: heavier per-pod, and **no forward-auth outpost**, so services without native OIDC need oauth2-proxy or Authelia in addition. | documented |
| **Zitadel** | copyleft (aggregated, AGPL-3.0) | You want the lowest operational footprint ... a single Go binary. Its LICENSING.md carves out proto/, apps/docs and apps/login from the AGPL-3.0 core. No LDAP-as-provider, no forward-auth equivalent. | unsupported |
| **Authelia** | permissive | As a **forward-auth portal only**, alongside a real IdP. Its own OIDC provider is still in open beta and it has no SAML. | unsupported |
| Kanidm, Pocket ID, Ory | permissive | Narrower than the platform needs (no SAML, or headless toolkits requiring you to build the login UI). | unsupported |

**Migration note, since this is the least portable component in the stack.**
Authentik blueprints have no conversion tooling to any other IdP, so flows and
policies are hand-rewritten. OIDC *client* configuration is portable by protocol;
the flow logic is not.

### Secrets

**Default: Sealed Secrets** ... permissive

Per-cluster encryption key, encrypted secrets committed to Git, nothing external
to reach. The right shape for per-site deployments and for Dark Site operation.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **SOPS + age** | permissive (SOPS is MPL) | You want the absolute lowest operational tax: no controller, no CRD, no running pod. You give up in-cluster automatic re-encryption and per-namespace crypto scope. | documented |
| **OpenBao** | permissive (MPL-2.0) | You need **more than encrypted secrets in Git** ... dynamic database credentials, a Transit engine, an SSH CA, or PKI. Air-gapped auto-unseal is supported by static, PKCS#11 or transit seals, with no cloud KMS. Costs 3 pods and 3 PVCs minimum, and only the latest release line is maintained, forcing a minor upgrade roughly every five months. | unsupported |
| **External Secrets Operator** | permissive | You already have an external secret store. **It does not fit a Dark Site on its own** ... it pulls from somewhere, and in a disconnected deployment that somewhere has to be OpenBao, which is two components to replace one. | unsupported |
| HashiCorp Vault | BSL 1.1 | Not usable under Tockmox's licence screen. Vault 1.14.8 and earlier are MPL-2.0; later releases are BSL 1.1 (Licensor: IBM). | n/a |
| Infisical | open core (MIT core, `ee/` directory) | Not shipped. Infisical's [self-hosting documentation](https://infisical.com/docs/self-hosting/ee) says the enterprise instance requires outbound connectivity to validate licences, and also documents an offline licence key. | n/a |

**Operational note that matters more than the tool choice:** whatever you pick,
the encryption key's escrow is the real control. Tockmox documents an offline
escrow procedure whose definition of done is a **successful canary decryption on
an offline machine**, not the existence of a backup file. An escrow never
restored from is not an escrow.

### Container registry

**Planned default: zot** ... permissive. **Not shipped in this release**: a
registry is a prerequisite you supply (see [registry](deployment/registry.md),
which also records the planned timing and a worked Harbor example). The tier
column below describes the alternative against that planned default.

Single binary, OCI-native on-disk layout (so an air-gap seed is a directory you
drop in place), multi-upstream on-demand pull-through in one instance, and the
OCI referrers API for attaching signatures and SBOMs.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **Harbor** | permissive (Apache-2.0) | **You need a pull-time vulnerability gate** ... blocking image pulls by severity threshold, with expiring allowlists, treating unscanned images as violations. zot scans but does not gate. Also the answer for per-project storage quotas and scoped robot accounts. Costs 7 pods and 5 volumes; the portal and jobservice cannot be disabled. | documented |
| **CNCF Distribution** | permissive | A plain private registry with no proxy requirements. **It can mirror only one upstream registry per instance**, has no user model, no RBAC and no UI, and its garbage collection requires read-only mode. | documented |
| **k3s embedded Spegel** | permissive (MIT) | **As a complement, not a replacement.** Peer-to-peer image sharing between nodes at zero pods, with air-gap-imported images pinned against kubelet garbage collection. It is read-only, has no storage of its own, and a cold cluster advertises nothing ... so it does not remove the need for a pull-through cache. | documented |
| Project Quay | permissive | A large existing Quay estate. Reserves 8Gi of guaranteed memory per replica and installs only via OLM, with no maintained Helm chart. | unsupported |

**Known limitation, stated because an adopter will assume otherwise.** zot
performs vulnerability scanning but **does not block pulls on the result**. If
your policy is "vulnerable images must not run", that belongs in an admission
policy (Kyverno `ImageValidatingPolicy`), not the registry ... or use Harbor.

### GitOps, workflows, CI

**Defaults: Argo CD; Argo Workflows; Renovate (self-hosted).** Argo CD is a
prerequisite and Renovate is not shipped; see
[What ships in this release](#what-ships-in-this-release).

| Component | Alternative | Class | When to prefer | Tier |
|---|---|---|---|---|
| GitOps | **Flux** | permissive (Apache-2.0); its operator is AGPL-3.0 | A materially lighter footprint (four controllers at 64Mi each) and a **CRD that declaratively upgrades the GitOps controllers themselves from a mirrored OCI artifact** ... an answer to "who upgrades the GitOps engine at a disconnected site". Argo CD has no equivalent. The operator's [web UI](https://fluxoperator.dev/web-ui/) documents OpenID Connect and Kubernetes RBAC policies, in an AGPL-3.0 repository. | documented |
| GitOps | Argo CD "Core" mode | permissive | **Not recommended.** It removes the API, the RBAC model and **OIDC entirely**, which breaks single sign-on. | n/a |
| Node upgrades | **system-upgrade-controller** | permissive | The k3s project's own answer, with a first-party openSUSE MicroOS example that cooperates with `transactional-update` rather than fighting it. **Pin `version:` and drop `channel:`** ... the channel poll is the only outbound call in the path. | documented |
| Node upgrades | Ansible | permissive | A push-based break-glass path from outside the cluster. Lowest concept count. Keep it documented even if you automate. | documented |
| Workflows | **Kubernetes CronJob + Indexed Job** | n/a | Your scheduled work is *"nightly, for each of N known targets, do X"*. Zero additional pods, zero CRDs. **You lose a dependency graph, a fan-in primitive, and dynamic fan-out** ... `completions` is fixed at creation, so a job that *discovers* its work list cannot fan out over it without you writing a controller. | documented |
| Workflows | Tekton | permissive | An existing Tekton estate. No native cron and four always-on deployments. Tekton's [install docs](https://tekton.dev/docs/installation/pipelines/) describe release manifests and the Operator. | unsupported |
| Workflows | Kestra, Windmill | gated / non-OSI | **Not shipped.** See [What is deliberately absent](#what-is-deliberately-absent). | n/a |
| CI | **Woodpecker CI** | permissive | A lighter, more Kubernetes-native CI than forge-embedded Actions, at two pods. Note it has **no direct OIDC connector** ... it delegates authentication to the forge, so single sign-on is transitive. | documented |
| CI | Drone | Apache-2.0 Community Edition | **Not shipped.** See [What is deliberately absent](#what-is-deliberately-absent). | n/a |
| Dependency updates | updatecli | permissive | A complement, not a replacement ... a single declarative Go binary with no hidden network calls, useful for updates the general-purpose tool's managers do not cover. | unsupported |

**Honest note on Renovate and air gaps.** A dependency updater's job is learning
about new upstream versions, so it is definitionally useless with zero
reachability. Tockmox's guidance is "no SaaS dependency, mirror-fed", not
"air-gapped": use the full image with `binarySource=global` so no toolchains are
fetched at runtime, host presets on your own forge, and point package lookups at
your mirror. In a true Dark Site, turn it off and update on the connected side.

---

## Observability

**Defaults: Prometheus (kube-prometheus-stack); Loki; Alloy; Grafana;
Alertmanager; ntfy.** Tempo and the OpenTelemetry Collector are the intended
trace path and are not shipped in this release.

| Component | Alternative | Class | When to prefer | Tier |
|---|---|---|---|---|
| Metrics | **VictoriaMetrics** | permissive | **Memory-constrained nodes.** Its operator natively reconciles ServiceMonitor, PodMonitor, PrometheusRule, Probe and ScrapeConfig, so existing monitors keep working, and its query language is PromQL-compatible. VictoriaMetrics [lists](https://docs.victoriametrics.com/victoriametrics/enterprise/) downsampling and multiple retentions under its Enterprise features, which matters if you want tiered retention on small disks. | documented |
| Metrics | Mimir, Thanos | copyleft (aggregated, Mimir AGPL-3.0) / permissive (Thanos, Apache-2.0) | Multi-cluster or global query across many Prometheus instances. Both *increase* footprint at single-cluster scale. | unsupported |
| Logs | **VictoriaLogs** | permissive | **Memory-constrained nodes.** Accepts the Loki push protocol, so collection is unchanged, and has an officially signed Grafana datasource. **There is no Loki-compatible query endpoint**, so every log panel and log-based alert is hand-translated. | documented |
| Traces | **Jaeger v2** | permissive | You want a permissively licensed trace store, or vendor neutrality by construction (it is built on the OpenTelemetry Collector). You lose TraceQL and Grafana-native trace correlation. | unsupported |
| Collection | **OpenTelemetry Collector** | permissive | Vendor neutrality as a hard requirement. **The interface is OTLP either way**, which is what keeps this swappable. | documented |
| Dashboards | **Perses** | permissive | You want no AGPL component in the stack, and dashboards as Kubernetes CRDs. Pre-1.0, and **it has no alerting**. | unsupported |
| Alerting transport | Email / Slack / webhook via Alertmanager | n/a | Anything Alertmanager can reach. The default push target is chosen for a single operator with a phone, not because it is the only option. | documented |
| All-in-one | OpenObserve, SigNoz, Coroot | see below | **None is shipped.** See [What is deliberately absent](#what-is-deliberately-absent). Coroot is Apache-2.0 and is reasonable as an **adopter-installed add-on**, with the caveat that its pricing page lists SSO in the paid tiers. | n/a |

**Why redaction matters here.** Tockmox's trace design routes spans through a
collector hop so span attributes can be scrubbed before they reach a trace store,
because spans from a model gateway can carry prompt content. A trace store
that lists sensitive-data redaction as an Enterprise feature, as OpenObserve does
(see below), would leave that scrubbing to a paid tier.

---

## AI plane

**Defaults: LiteLLM (gateway); Open WebUI (console).** Retrieval on PostgreSQL
with pgvector and Docling for document conversion are the intended retrieval
path and are not shipped in this release. SearXNG is not shipped and is not
planned as an add-on.

### The swappability boundary

**Every product capability terminates at the gateway, never inside the console.**
Scoped API keys, single sign-on, budgets, model access policy, retrieval
endpoints, embeddings and reranking all live at or behind LiteLLM. That is what
makes the console replaceable, and it is a rule rather than a description. See
[Frontend posture](frontend-posture.md).

### Gateway

**Default: LiteLLM** ... permissive core (MIT) with a separately licensed
`enterprise/` directory

**Disclosure.** LiteLLM's
[enterprise page](https://docs.litellm.ai/docs/proxy/enterprise) lists JWT
authentication, audit logs with a retention policy, IP address-based access
control lists, key rotations, and role-based access control and organizations as
Enterprise features. Its [admin-UI SSO page](https://docs.litellm.ai/docs/proxy/admin_ui_sso)
says that from v1.76.0 SSO is free for up to 5 users, and beyond that an
enterprise licence is required; the enterprise page does not carry that note, so
check the version you run. The same documentation lists virtual keys, spend
tracking, budgets and Prometheus metrics in the open-source feature set. Tockmox
enables no Enterprise feature.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **Envoy AI Gateway** | permissive (Apache-2.0) | A gateway on the Envoy data plane. Tetrate sells commercial products around it. At the 2026-09-19 scan it had no spend or budget store and no rerank endpoint (not re-checked on 2026-10-06), so Tockmox capabilities that depend on those would need another home. | unsupported |
| **llama-swap** | permissive | A single-user local deployment with no policy requirements. It swaps local models on demand; it is not a policy boundary. Reasonable *behind* the gateway. | unsupported |
| Kong AI Gateway, Portkey | see below | Not shipped. Kong's [OpenID Connect plugin](https://developer.konghq.com/plugins/openid-connect/) is listed as Enterprise-only. Portkey's gateway README describes an Enterprise private-deployment tier and says its core enterprise gateway is merging into open source with its 2.0 release. | n/a |

**Sizing note.** Budget **4 GiB for the gateway pod**. That is upstream's stated
floor, not a recommendation, and it is driven by the database client's memory
behaviour. Pin the autoscaler's maximum replicas low; the chart default would
exhaust a database connection pool.

### Console

**Default: Open WebUI** ... **non-OSI**

**Disclosure, and read this before you brand a deployment.** Open WebUI ships
under a bespoke licence: BSD-3 plus a clause covering its branding. The
licence's clause 4 refers to deployments that do not exceed fifty (50) users
within any rolling thirty (30) day period, and the project's
[licence page](https://docs.openwebui.com/license/) says "50 or fewer users in a
30-day period". Altering or removing the branding outside that exemption needs
written permission or an enterprise licence. The licence text and the code both
reference the branding: `backend/open_webui/env.py` appends " (Open WebUI)" to a
changed `WEBUI_NAME`. Read the licence itself; see also
[Third-party licenses](third-party-licenses.md).

Tockmox includes it for convenience, declares it swappable, and terminates every
platform capability at the gateway rather than inside it, specifically so this
constraint never becomes structural.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **LibreChat** | permissive (MIT) | **You need to white-label.** The MIT licence has no branding clause. Costs an additional database; its search component is optional. | documented |
| AnythingLLM | permissive | Simple single-user deployments. No real OIDC at the 2026-09-19 scan. | unsupported |
| Lobe Chat, Dify | non-OSI | **Not shipped.** Lobe Chat is Apache-2.0 plus a commercial-licence requirement for derivative works. Dify is Apache-2.0 plus multi-tenant and logo/copyright conditions on the web frontend. | n/a |

### Model serving

**Default on Apple Silicon: `mlx-lm.server` for chat, `llama-server` for
embeddings and reranking.** Permissive (both MIT).

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **llama.cpp `llama-server`** alone | permissive (MIT) | Non-Apple hardware, or a single serving binary for everything. | documented |
| **vLLM** | permissive (Apache-2.0) | NVIDIA GPUs and real concurrency. Not viable on Apple Silicon. | documented |
| **Frontier API behind the gateway** | n/a | Capability the local tier cannot supply. **This is the escalation path, not the default** ... the platform is designed so losing it degrades escalation and never the core. | documented |
| LM Studio | proprietary | LM Studio's [app terms](https://lmstudio.ai/app-terms) prohibit redistribution, so it is not an option for a packaged platform. | n/a |

**Embedding and reranking models are a named dependency, not a default.** An
embedding model change forces a full corpus re-index, so the model should be
pinned rather than inherited from whatever the serving runtime happens to
prefer. **Several widely recommended alternatives carry non-commercial
licences** ... check the model card, not the repository, before substituting.

### Retrieval

**Intended default: PostgreSQL with pgvector, hybrid retrieval fusing dense
vectors with native full-text search by reciprocal rank fusion, and a reranking
pass.** Permissive. Not shipped in this release.

At the corpus sizes Tockmox targets, exact vector search is fast and complete;
the lexical arm exists to buy **precision on exact tokens** ... resource names,
addresses, flag names, error strings ... which is where dense embeddings are
weak.

| Alternative | Class | When to prefer | Tier |
|---|---|---|---|
| **`pg_textsearch`** (Tiger Data) | permissive (PostgreSQL License) | **A corpus large enough that ranking quality measurably matters**, roughly tens of thousands of documents and up. Requires PostgreSQL 18+, Kubernetes 1.35+, a recent containerd, and a PostgreSQL extension image you build. It has **no term positions, so no phrase queries**. | documented |
| ParadeDB `pg_search` | **copyleft (linked)** | **Not shipped.** ParadeDB's LICENSE is the GNU Affero General Public License. It would be loaded into the PostgreSQL server process, and Tockmox has not resolved how the AGPL applies to that, so it does not ship it. | n/a |
| **A dedicated retrieval platform** (RAGFlow and similar) | varies | You need many source connectors with incremental sync, and you have the hardware. Expect a fixed footprint in the tens of gigabytes regardless of corpus size, and check whether permissions and single sign-on are in the free tier of the one you pick. | unsupported |

**Design note.** The intended design builds retrieval on the database the
platform already runs and backs up rather than adopting a platform, because at
these corpus sizes an adopted platform's base footprint *is* the footprint. That
trade reverses at scale, which is what the first row above is for.

---

## What is deliberately absent

Components that would otherwise fit, excluded on the standing rule that a
platform default must not require a commercial licence to sign in to or to
control access within. **Each entry says what the vendor's own page lists as
Enterprise or paid, as of 2026-10-06. It is not a characterisation of the
product.** Vendors change their tiers; check the vendor's page.

| Component | Category | As of 2026-10-06, the vendor lists |
|---|---|---|
| **Onyx** | Retrieval | Role-based access control, custom groups and document access control as Enterprise Edition features ([access controls](https://docs.onyx.app)). |
| **OpenObserve** | Observability | SSO, RBAC and sensitive data redaction as Enterprise features. Enterprise is free up to 50 GB/day of ingestion. The repository is AGPL-3.0. |
| **SigNoz** | Observability | Repository licensed MIT Expat, with an `ee/` directory "licensed under ee/LICENSE". This register did not establish which features that directory holds. |
| **Coroot** | Observability | Repository licensed Apache-2.0. The pricing page lists SSO and RBAC in the Standard tier. |
| **Kestra** | Workflows | SSO, LDAP, SCIM, RBAC and multi-tenancy under its Enterprise platform. The open-source edition is Apache-2.0, and the vendor describes basic authentication as "suitable for one-person projects or small teams with shared credentials". |
| **Windmill** | Workflows | A licence that includes the text "not to sell, resell, serve as a managed service, modify or wrap under any form without an explicit agreement", and a Community Edition SSO limit of 10 users. |
| **Drone** | CI | A Community Edition under the Apache License and an Enterprise Edition under a Non-Commercial License. Whether a prebuilt Community Edition image is currently published was not verified. |
| **Gitea** | Git forge | Audit Log and SAML among its Enterprise-only features ([docs](https://docs.gitea.com/enterprise)). The repository is MIT. |
| **HashiCorp Vault** | Secrets | Releases from 1.15.0 on under BSL 1.1 (Licensor: IBM). Vault 1.14.8 and earlier are MPL-2.0. |
| **Infisical** | Secrets | An `ee/` directory under its own licence, online licence validation that needs outbound connectivity, and an offline licence key. |
| **Crunchy PGO** | Databases | Operator source under Apache-2.0, and container images under Crunchy Data Developer Program terms. |
| **Morphik** | Retrieval | BSL 1.1 with a use grant that refers to "total gross revenue ... less than US $2000 per month". |
| **LM Studio** | Model serving | Terms that prohibit redistribution of the software. |
| **Lobe Chat, Dify** | Console | Lobe Chat: Apache-2.0 plus a commercial-licence requirement for derivative works. Dify: Apache-2.0 plus multi-tenant and logo/copyright conditions on the web frontend. |

**This list is not a judgement about software quality.** Several of these are
excellent and several would be the right choice for a deployment with different
constraints. They are absent because Tockmox's premise is that you own the
platform, and a default whose access control you must rent is not one you own.

---

## Keeping this page current

- **Owner and cadence.** The maintainers review this page on a quarterly sweep.
  The sweep re-fetches every source named above, updates the "Last scanned" date
  at the top, and cuts any third-party statement it cannot re-confirm rather
  than carrying it forward.
- **Licence claims are read from the licence file** in the project's repository,
  never from a summary. Feature-tier claims are read from the vendor's own
  documentation or pricing page and phrased as what that page lists.
- **Public wording about other people's software is dated, sourced, and phrased
  as what the licence says rather than what Tockmox thinks it means.** If you
  find a statement here that the vendor's page contradicts, open an issue.
- **A component does not become a Tockmox default without an entry here.**

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

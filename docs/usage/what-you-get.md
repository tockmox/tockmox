---
okf_version: "0.2"
type: Reference
title: "What you get"
description: "An honest inventory of what a Tockmox install actually deploys, and what is named but not built yet."
tags: [inventory, layers, scope, network-containment, diagnostic-identity]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# What you get

Honest inventory. Anything not built says so. Counts are from
`helm template` with the CI values and are re-checked whenever this page
changes.

## Today ... nine layers, 600 rendered resources

Counts describe the revision you are reading, not the last tag. The release
this page ships with is stamped in the footer.

| Layer | Resources | The headline |
|---|---|---|
| crds | 10 | Cross-layer CRDs (prometheus-operator), wave 0 so nothing races its definitions |
| policy | 75 | Namespaces, 43 NetworkPolicies (default-deny in every namespace this layer creates), RBAC admission guardrails, PriorityClasses, the diagnostic identity |
| platform | 234 | Traefik, MetalLB, cert-manager, Longhorn, CloudNativePG, kured, snapshot-controller |
| observability | 171 | kube-prometheus-stack, Loki, Alloy ... persisted, bounded retention, resource requests |
| exporters | 7 | blackbox / SNMP / smartctl, separate so wrong-for-your-hardware is one flag |
| identity | 32 | Authentik. Its credentials come from operator-created Secrets, so the pods wait with a config error until you supply them |
| devops | 35 | Argo Workflows (client auth, not authenticate-nobody). No registry: see [registry](../deployment/registry.md) |
| ai | 31 | Open WebUI with **no cloud backend**, enforced by a CI check, routed through the LiteLLM model gateway on a key the chart mints and a CronJob checks (since 0.8.0). The gateway's model list ships empty: see "the one decision" below |
| selfcheck | 5 | Alert rules for silent failures, plus a heartbeat that proves alerting works |

Deployed end to end on a wiped single-node k3s cluster. The nine layers above
are nine ArgoCD Applications; `kubectl -n argocd get applications` shows
**twelve**, because the root Application that creates them, your own
`site-apps`, and `site-secrets` (which applies the SealedSecrets in your site
repository) are Applications too. Pod count, measured 2026-08-18: 47 healthy.
That figure is a live-cluster measurement rather than a render, so it carries
its date. The resource counts above are a render, and they are checked rather
than re-typed: CI writes every layer's count to `build/render-counts.tsv` and
`tools/doc-claims.txt` fails the build when a row here disagrees (TM-0533).
Until 0.8.0 this sentence said they were "re-derived every release", while
every row had drifted and the total read 528 against a render of 578.

**The way in:** Grafana at `grafana.<internalDomain>`, Open WebUI at
`chat.<internalDomain>`, Authentik at `auth.<internalDomain>`, Argo Workflows
at `workflows.<internalDomain>`. TLS when `global.certIssuer` is set. Full
table in [configuration](../administration/configuration.md).

<a id="the-one-decision-a-default-install-leaves-you"></a>

**The one decision a default install leaves you:** the AI plane ships with no
model. Since 0.8.0 the model gateway is on and Open WebUI goes through it on a
key the chart mints (TM-0460), but the gateway's model list ships empty, so a
first install reaches `chat.<internalDomain>`, signs you in, and shows an
empty model list. That is deliberate rather than an oversight: a model
endpoint is an address on your network, and there is no honest default for
one. Name a model host in the gateway's `litellm.proxy_config.model_list`, one
value, in [the AI plane](ai-plane.md). Through 0.7.x the gateway itself shipped
off and pointing the console at it was a documented extra step; that is gone.

**One identity for the three consoles wired to it:** the identity layer wires
Grafana, Open WebUI and Argo Workflows into Authentik via shipped blueprints ... two groups (`tockmox-admins`,
`tockmox-users`) decide who may reach each app and which role they land in, a
user in neither group is refused before any console sees the login, and local
logins remain as break-glass. See [identity](../administration/identity.md).

## Not yet built

A git forge (no stable upstream chart at the version Tockmox targets ... it
will arrive Tockmox-authored) and a RAG index for the AI plane.

**Corrected 2026-09-03.** This list also carried the three Grafana boards that
know Tockmox's own shapes ... the drill register, the storage contract, the
alert-delivery path. All three shipped on 2026-08-19 and this page did not
follow. **Nine Tockmox-authored boards** ship: Traefik, cert-manager, MetalLB,
Authentik and Admission & Policy, plus Drill Register, Storage Contract, Alert
Delivery and Argo Workflows ... alongside upstream's kubernetes-mixin set. See
[monitoring](../operations/monitoring.md), which has been right about this all
along. A tenth, ArgoCD's, ships with `apps.argocdMonitoring` (on with observability),
and reads "No data" on an ArgoCD installed without metrics.

Two items formerly on this list shipped on 2026-08-19: **scheduled restore
drills** (weekly, PASS/FAIL register, freshness-alerted, on by default with
backups ... [backup-restore](../operations/backup-restore.md)) and **CSI
volume snapshots** (the control plane arrives with `dataProtection` and the
platform ships the `longhorn-snapshot` class).

Air-gapped install **has** now been exercised end to end. On 2026-08-25 a
teardown, a route-level uplink cut for both IPv4 and IPv6, and a greenfield
install from a freshly generated site repository brought all nine layers Synced
and Healthy with zero image pull failures. What that exercise cost, and the
five dependencies `airgap.md` had to grow to cover, is in
[airgap](../deployment/airgap.md). One live caveat: litellm's `helm test` hook
names a bare `busybox`, so `helm test` will not pass disconnected even though
the install does.

The policy layer carries NetworkPolicy bundles for three of those absent
workloads ... Forgejo, a Tailscale subnet router, and a syslog receiver ... plus
one for a standalone Harbor, which is now the only kind. All four are off by default, because a policy whose
`podSelector` matches nothing is scaffolding rather than security. Turn one on
when you install the workload yourself; see
[external integrations](../administration/external-integrations.md#policy-bundles-for-workloads-tockmox-does-not-ship).

**The default-deny rollout is complete.** Earlier, unpublished versions of this
page named the platform and selfcheck namespaces as honest gaps carrying no
NetworkPolicies at all. Both
now have bundles: every one of the seven namespaces the policy layer creates
carries a default-deny policy, and 33 more open the paths that have to be open,
plus the AI namespace's egress default-deny ... 43 NetworkPolicies in total. Six of the seven deny ingress; the one in
`tockmox-diagnostic` denies egress as well, because a read-only identity has
nothing it needs to call out to. A gap this page confessed and then closed is worth saying out loud
rather than quietly deleting.

If you run a registry, it lands in a namespace of your choosing and is yours to
guard ... the policy layer ships an `apps.harbor_netpol` bundle, off by default,
for exactly that. See [registry](../deployment/registry.md).

### Network containment

Say the whole shape of it, because "default-deny networking" is two claims and
only one of them is finished.

**Ingress: default-deny, complete.** All seven namespaces the policy layer
creates carry a `default-deny-ingress` policy. Nothing reaches a pod here
unless a rule opens the path.

**Egress: contained for the chat console and the AI namespace, open elsewhere.**
Two things carry `policyTypes: Egress` over workloads. The Open WebUI bundle is
deliberately narrower than its namespace, for the reason
[the AI plane](ai-plane.md) gives: Open WebUI is the pod that holds private
data, renders untrusted model output, and can make outbound requests, which is
ADR-0007's trifecta in one place. Since 0.7.0 (TM-0273) the
rest of the AI namespace is default-deny for egress too, so the model gateway,
which holds provider keys, can reach DNS, its own namespace and its database,
its provider on TCP 443 (never the cluster, the LAN or link-local ranges), and
nothing else; its database's pods reach the Kubernetes API and the object
store's S3 port. Authentik, Prometheus, Loki, the platform controllers and the
devops workloads still have unrestricted egress. **Measured on one
single-node lab cluster (kube-router, 2026-09-30):**
`tests/executed-docs/netpol-adversary.sh` with `TOCKMOX_EXPECT_AI_EGRESS_DENY=1`
ran 15 assertions, 14 passed and 0 failed, including egress denial from the AI
namespace; the one expected failure is the monitoring namespace reaching the
internet, which is open by design. On the same cluster, with the model host on
the LAN listed in `aiEgress.litellm.extraEgress`, the rendered rule was exactly
that host's address on the listed ports and a completion through the gateway
returned 200. **Not measured:** a model host in another namespace, a multi-node
cluster, or another CNI.

**Consequences worth knowing before you rely on this:**

- A compromised pod in a guarded namespace outside the AI namespace can reach
  the network. Containment here is a smaller claim than isolation.
- `allow-from-node-network` in the platform namespace admits the whole
  `lanCIDR` to every platform pod on every port, and until 0.8.0 it also
  admitted, **by default, the whole `clusterCIDR`**. It has to reach node addresses ... the kube-apiserver's
  webhook calls arrive from a node address that no selector can match, and
  MetalLB SNATs clients to a node IP ... but `clusterCIDR` is also the range
  every pod's own address comes from. On k3s's embedded policy controller an
  ordinary pod in namespace `default` was measured reaching the object store's
  admin port (HTTP 200) and S3 port (403) through this rule, which opened the
  platform namespace to every pod in the cluster. Since 0.8.0
  `platformNetpol.nodeOriginSources` (a /31 per node, printed by
  `install/tockmox-install.sh --print-netpol-node-sources`) is required and the
  `clusterCIDR` block is never rendered; Prometheus scraping and database
  backups have their own rules, scoped to metrics ports and to the S3 port. A
  node you add later must be added to the list. See
  [the platform namespace's node-network rule](../administration/external-integrations.md#narrowing-the-default-network-rules).
- The diagnostic identity's "API server" rule is, by default, the whole
  `serviceCIDR` and `lanCIDR` on 443 and 6443, so "no path to the internet" is
  true for direct egress and false through an HTTPS forwarder on the LAN. Set
  `diagnosticIdentity.apiServerCIDRs` and it is exactly the API endpoint.
- **A new pod is unpoliced for about its first second.** On k3s's embedded
  policy controller (kube-router), measured on one single-node lab on
  2026-10-08: three of three fresh pods in an egress-denied namespace reached
  `https://1.1.1.1` at once (`t+0` HTTP 301), and were refused from about one
  second on (`t+1` through `t+20`: no connection). Allow rules naming a new pod
  lag the same way, which is why some install steps sleep before their first
  request. So egress default-deny bounds a workload from about its first
  second, not its first packet: code that runs at container start can send a
  little before the rules hold. Not measured on another CNI or a multi-node
  cluster.
- Three workloads run on `hostNetwork` (MetalLB speaker, kured, node-exporter)
  and NetworkPolicy does not apply to them at all. That is the API's behaviour,
  not an oversight, and it is stated here rather than left in a template
  comment.

Not done: a baseline policy for namespaces you create yourself
(`adding-an-application.md` gives the recipe and nothing applies it), egress
control for the other five guarded namespaces, and a live run of the
adversarial harness against these changes.

## The diagnostic identity, since it is the interesting one

An identity an automated agent can run as, which is read-only **by
construction** rather than by policy:

- ClusterRole grants `get`, `list`, `watch`. Nothing else. A write attempt
  fails at admission, not at the caller's discretion.
- Cannot read Secret contents. Read-only still should not mean read-everything.
- NetworkPolicies allow egress to DNS, the API server, and local telemetry.
  **No path to the internet** for direct egress; with
  `diagnosticIdentity.apiServerCIDRs` unset the "API server" rule is the whole
  service and LAN ranges on 443/6443, which an HTTPS forwarder on the LAN can
  answer. Set the key to close that.
- Not human-wearable: the identity is set by the execution path, not assumable.

The interesting part is what it enables. Tockmox ships the **cage**, not the
occupant. Point your own agent at it and it inherits a containment envelope
that is public, auditable, and testable.

## What Tockmox will not do

- **Phone home.** No telemetry, no analytics, no licence check. The ingress controller's
  version check and usage beacon are both off by default (`traefik.global.checkNewVersion`
  and `traefik.global.sendAnonymousUsage`); a site can set either back to `true`.
  The same goes for Grafana's update check, usage reporting and news feed, Loki's and
  Alloy's usage reporting, Longhorn's upgrade checker, and authentik's update check and
  startup analytics; `tools/check-cloud-egress.sh` asserts each is off in the render.
- **Require an account.** Nothing to sign up for.
- **Hold your secrets.** Sealed to your cluster's key.
- **Stop working offline.** Degrades capability, not availability.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

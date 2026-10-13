---
okf_version: "0.2"
type: HowTo
title: "Skill: deploy an application"
description: "How an agent puts an operator's own workload on Tockmox and wires it into namespace policy, a managed database, ingress, single sign-on, metrics and alerts without forking the platform."
tags: [agents, skills, applications, gitops, networkpolicy, sso, cnpg, machine]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [machine, operator]
---

# Skill: deploy an application

**Use this when** an operator wants to run their own workload on the platform
and have it use what the platform already provides: a database with backups, an
ingress hostname, single sign-on, metrics, alerts and a dashboard.

**The canonical walkthrough is
[adding an application](../../administration/adding-an-application.md).** It
works one real example end to end. Route into it rather than reconstructing the
manifests from memory ... the shapes there are the ones that work, and several
of them are not what a general Kubernetes instinct produces.

## Where everything goes

**Their site repository, under `apps/`.** The installer generates a `site-apps`
Application that syncs that directory, so `git push` is the deploy button.
Nothing about adding an application touches the Tockmox charts, and a change
that seems to require touching them is the wrong shape.

## The rules that keep their upgrades free

Get these right first; the rest is ordinary Kubernetes.

**Pick their own namespace. The `tockmox-` prefix is reserved.**

**Reference platform services by their documented names, and never patch a
platform object from their app.** The name that catches people:
**every component lands in its layer's namespace, not the namespace its upstream
project conventionally uses.** It is `tockmox-garage.tockmox-platform.svc`,
never a `garage` namespace, and `cert-manager` lives in `tockmox-platform` too.
If a layer was installed somewhere other than the default, substitute
accordingly.

**Secrets are operator-created and sealed into the site repository.** Never
plaintext in a manifest, and never a credential in a values file.

## Site namespaces get no NetworkPolicy from Tockmox

This surprises people, and quietly. The `networkPolicy` capability covers
namespaces Tockmox authors; **an operator's own namespace starts with nothing.**

They bring their own, using the same recipe the guarded namespaces use:
default-deny ingress, then explicit allows for each thing that must reach in.
The walkthrough has all five as working manifests:

- intra-namespace, so the app can reach its own database
- from Traefik, which lives in the platform namespace, for the UI
- from Prometheus, in the monitoring namespace, for `/metrics`
- from the CNPG operator to the database pods, on its two ports
- and the default-deny that makes the rest mean anything

**Assert on reachability, not on the policy applying.** A NetworkPolicy that
selects no pod applies cleanly and protects nothing, and it reads as protection
to whoever audits the cluster next. The proof is that the app is reachable
**only** via Traefik.

## A database is one custom resource, and backups go in the same commit

The platform ships the CloudNativePG operator, so a managed PostgreSQL is a
`Cluster` CR. CNPG mints a Secret with a ready-made connection `uri` key, so
the app never sees a hand-managed password ... consume it with a `secretKeyRef`
rather than assembling a connection string.

**Wire the backup in the same change, not later.** The walkthrough's example
carries the Barman Cloud plugin and a `ScheduledBackup` alongside the `Cluster`,
and [backup and restore](../../operations/backup-restore.md) has the ObjectStore
CR and where the S3 credentials come from.

**Instance count follows the cluster.** One instance on a single node, three on
a multi-node cluster. This is the same trap as the Longhorn replica counts: the
shipped example is right for one node and silently wrong for three.

## Ingress, and the DNS detail that breaks SSO

No `ingressClassName` ... the shipped Traefik is the cluster default.

Their hostname has to resolve **from inside the cluster as well as from
workstations**, because the OIDC discovery fetch is server-side. A DNS check run
from the operator's laptop passes while login still fails. This is the same
shape as the install-time DNS check, and it catches people twice.

With a `certIssuer` set, add the cert-manager annotation and a `tls` block
exactly as the shipped ingresses do.

## Single sign-on: two routes, one trap each

**Through the admin UI or API** is quicker. The trap: a provider created without
explicit grant types `authorization_code` and `refresh_token` **rejects every
login**. Nothing about the provider looks wrong.

**Declaratively, as a blueprint in their site repository**, is reproducible.
Two traps:

- **Lists replace, they do not merge.** Adding their ConfigMap to the identity
  chart's blueprint list means restating the shipped `tockmox-sso-blueprints`
  entry alongside it. Dropping it is how SSO breaks after a change that looked
  purely additive.
- **`envFrom` is read at pod start.** After adding their key to the `tockmox-sso`
  Secret so `!Env` resolves, the Authentik worker has to be restarted. Then
  check Blueprints in the admin UI reports theirs `successful` ... that is the
  artifact, not the apply.

Users need no per-app setup on the Tockmox side: anyone in `tockmox-admins` or
`tockmox-users` can sign in. **Whether an account is created for them on first
login is the application's own setting, not something the platform does** ... in
the worked example it is `OAUTH2_USER_CREATION=1` on the Miniflux Deployment.
Find the equivalent in their app, or expect first-time logins to be rejected by
an app that has no account for them.

## Metrics, dashboards and alerts are discovery-based

Prometheus discovers any `ServiceMonitor` in any namespace, deliberately. So a
`ServiceMonitor` in their namespace is the whole wiring, and a `PrometheusRule`
joins the same discovery. Grafana discovers any ConfigMap labelled
`grafana_dashboard: "1"` in any namespace.

**The proof is the target appearing `up` in Prometheus and the rule being
visible there**, not the object existing. An alert rule that loads and cannot
fire is a failure this project has hit before and now writes gates against.

## The card-only variant, and its honest limit

Not everything an operator wants in the Authentik library speaks OIDC. An
Application created **without a provider** renders as a launch tile and nothing
else, and visibility is controlled per-card by binding a group policy.

**Say the limit plainly, because it is a security misunderstanding waiting to
happen: hiding the card does not protect the destination.** A provider-less
Application is a menu entry, not a lock, and the target is exactly as reachable
as its own authentication makes it. If it must actually be restricted, put
forward-auth in front of its hostname.

Group-membership changes also take up to the policy-cache TTL to appear.

## Before you hand it back

Walk their checklist, and for each row name the **proof**, not the manifest:

| Wiring | Proof |
|---|---|
| Namespace and netpol | reachable only via Traefik |
| Database | the CNPG-minted app Secret exists; the cluster is healthy |
| Backups | an on-demand backup completes and objects land in the bucket |
| Ingress | the hostname serves through Traefik |
| SSO | a group member signs in and their account is created |
| Metrics | the target is `up` in Prometheus |
| Alerts | the rule is visible in Prometheus |
| Dashboard | it appears in Grafana |

And remind them: it is not deployed until it is committed and pushed. `site-apps`
syncs the directory from git, so an uncommitted manifest has changed nothing.

## What this skill will not do

- Put their workload in a `tockmox-` namespace.
- Write a credential anywhere but a SealedSecret.
- Modify a platform object, or anything under `charts/`, to make their app fit.
  If the platform genuinely will not let them express something, that is a
  values-interface gap worth reporting as an issue.
- Report a wiring step as done because the manifest applied.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

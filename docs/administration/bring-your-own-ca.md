---
okf_version: "0.2"
type: HowTo
title: "Bring your own certificate authority"
description: "Install Tockmox with an operator-supplied CA instead of the chart's own: name the issuer, put the CA key Secret where cert-manager reads it, move an existing key without re-minting it, and know what you now trust."
tags: [tls, trust, certificates, private-ca, cert-manager, sealed-secrets, disaster-recovery]
status: stable
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [operator]
---

# Bring your own certificate authority

**Tockmox can sign its console certificates with a CA you supply, and the
chart's own CA is the other choice.** This page is the supplied-CA path from end
to end: which issuer name to set, where the CA's key has to live and why, how to
move a key that already exists without making a new one, and what the choice
means for trust, backups and a rebuilt cluster.

[TLS and trust](tls-and-trust.md) is the page for the default: the chart mints
`tockmox-ca`, you trust it once on each machine you browse from. This page
starts where its option table says "your own ACME or corporate issuer" and the
sentence stops.

**Nothing on this page has been executed against a cluster.** The facts about
where the Secret lives and what the chart renders are read from the chart and
pinned by the docs claims gate; the procedures are not run. Read [what is not certified here](#what-is-not-certified-here) before you
rely on the move in [step 4](#4-move-the-key-without-re-minting-it--required).

## Which CA is yours to choose

| | The chart's CA | A CA you supply |
|---|---|---|
| **What it is** | `tockmox-ca`, minted by cert-manager inside the cluster the first time the platform layer syncs | A key pair you already hold (a corporate or lab CA), or the chart's own key pair adopted as yours |
| **Where the key lives** | In the cluster only: the Secret `tockmox-ca-root` | Outside the cluster, with a copy in the cluster that you place |
| **A rebuilt cluster** | Mints a **new** CA with the same name and a different key. Every machine that trusted the old one now rejects every console | Gets the **same** CA back through the ordinary recovery, if the key is sealed into your site repository |
| **Who must trust it** | Each machine you browse from, once ([TLS and trust](tls-and-trust.md#3-choose-the-trust-scope--required)) | Nothing new if the CA is already trusted where you work; the same step otherwise |
| **What you run** | Nothing | A CA: its expiry, its access control and its backup |

**The honest summary of the trade.** The chart's CA costs you nothing until the
cluster is lost, and then it costs you a re-trust on every machine. A supplied CA
moves that cost to day one: you hold and protect a key. Choose the chart's CA
for an evaluation or a site you can afford to re-trust. Choose your own when the
site has a disaster-recovery plan, a CA it already runs, or more than a handful
of machines.

### Why not let the chart's CA sign everything

A fair question, raised against this page: the chart's CA could also sign
certificates for services outside the cluster, by issuing them in the cluster and
copying the Secrets out, which would leave one CA to trust instead of two. It is
possible, and the trade is the one in the table:

- **The key then lives only in the cluster.** Escrow and restore couple to the
  cluster: the CA is as lost as the cluster is, and a rebuild re-mints it. The
  [incident](#what-a-rebuild-does-to-the-chart-ca) is one the project has already
  had once.
- **Off-cluster renewals depend on the cluster.** A certificate on a machine that
  is up while the cluster is down cannot renew.
- **The reverse arrangement does not have either problem.** A supplied CA signs
  the cluster's certificates and anything else, and the cluster is one of its
  clients.

This page documents the supplied CA. It does not rule on the first arrangement;
it states what it costs.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| A CA certificate and its private key, as PEM files | The issuer signs with the key; clients trust the certificate | `openssl x509 -in YOUR_CA_CERT -noout -subject` prints a subject, [step 2](#2-check-the-ca-material-before-you-place-it--required) runs the rest |
| The key is not passphrase-protected | cert-manager reads the Secret as it is and cannot prompt | Step 2 prints `unencrypted` |
| `tockmox-platform` synced, or about to be | It carries cert-manager, and the Secret has to land beside it | `kubectl get deploy -A -l app.kubernetes.io/name=cert-manager` lists the controller |
| Your site repository, checked out, with `secrets/sealed-secrets-cert.pem` present | Step 3 seals into it. The certificate is public and is written when the installer runs | `ls "$SITE_REPO/secrets/sealed-secrets-cert.pem"` |
| `kubectl` and `kubeseal` | Step 3 builds and seals the Secret | `command -v kubectl kubeseal` prints two paths |
| The sealed-secrets key escrowed | Your CA key will be sealed to it, so the escrow is now also the CA's backup | [Escrow the sealed-secrets key](../operations/sealed-secrets-key-escrow.md) |

**Where each command runs:** every block below is **WORKSTATION**, the machine
you administer the cluster from.

**YOU SUPPLY:** the paths to the CA certificate and key, your site repository,
and your kube context. Export them once per shell.

**WORKSTATION**

```bash
export CA_CERT=YOUR_CA_CERT_PATH
export CA_KEY=YOUR_CA_KEY_PATH
export SITE_REPO=YOUR_SITE_REPO_PATH
export KUBE_CONTEXT=YOUR_KUBE_CONTEXT
test -r "$CA_CERT" && test -r "$CA_KEY" && test -d "$SITE_REPO/secrets" && echo "inputs found"
```

## 1. Know where the Secret has to live ... Required

**The CA's key pair is a Secret in the namespace cert-manager runs in, and no
other.** A `ClusterIssuer` of type `ca` is cluster-scoped, so it has no namespace
of its own to look in. cert-manager reads its Secret from one place, its cluster
resource namespace. The upstream chart the platform layer ships sets that to the
namespace cert-manager itself runs in, which is the platform layer's release
namespace: `tockmox-platform` unless you renamed it.

Name any other namespace and the issuer reports `secret "..." not found` while
the Secret sits in plain view somewhere else. That error names the Secret and
not the namespace, which is why it takes so long to read correctly.

The chart's own CA is placed the same way, and deliberately cannot be moved: its
`Certificate` is rendered with `namespace: {{ .Release.Namespace }}`, with a
comment saying so.
`certIssuer.selfSigned.caSecretName` defaults to `tockmox-ca-root`. A CA you supply follows the same rule for the same reason.

Find the namespace on your cluster rather than assuming it:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get pods -A \
  -l app.kubernetes.io/name=cert-manager,app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].metadata.namespace}{"\n"}'
```

**Success condition:** it prints one namespace, normally `tockmox-platform`.
Export it for the steps below. The labels are the upstream chart's; if the
command prints nothing, find the controller with `kubectl get deploy -A | grep
cert-manager` and read its `--cluster-resource-namespace` argument.

**WORKSTATION**

```bash
export PLATFORM_NS=YOUR_PLATFORM_NAMESPACE
```

## 2. Check the CA material before you place it ... Required

A wrong key here fails late and obscurely, at the first certificate request,
with an error that names cert-manager. Four checks first, each on the files you
are about to seal.

**WORKSTATION**

```bash
: "${CA_CERT:?export CA_CERT first}"
: "${CA_KEY:?export CA_KEY first}"
openssl x509 -in "$CA_CERT" -noout -subject -enddate -fingerprint -sha256
openssl x509 -in "$CA_CERT" -noout -text | grep -E 'CA:TRUE|Certificate Sign'
test "$(openssl x509 -in "$CA_CERT" -noout -pubkey | openssl sha256)" = \
  "$(openssl pkey -in "$CA_KEY" -pubout | openssl sha256)" && echo "key matches certificate"
grep -q 'ENCRYPTED' "$CA_KEY" && echo "ENCRYPTED: remove the passphrase first" || echo "unencrypted"
```

**Success condition:** the subject and an end date in the future print, then a
fingerprint; the next two lines show `CA:TRUE` and `Certificate Sign`; then `key
matches certificate`; then `unencrypted`. **Record the fingerprint outside the
cluster.** It is how you prove, after every move below, that the CA is the one
you started with.

Three notes on what these checks do not settle:

- **An intermediate is not a root.** If your CA certificate is itself signed by
  another CA, put the chain in the certificate file, the intermediate first. How
  cert-manager presents that chain in the certificates it issues is
  believed, not checked here; [step 5](#5-prove-it-worked--required) verifies the
  chain of an issued certificate, which is the check that settles it.
- **A root key does not belong in a cluster.** If the CA you hold is an offline
  root, mint a subordinate CA from it for Tockmox and place that. See [what you
  now trust](#what-you-now-trust).
- **The end date is the date your consoles stop being trustworthy.** The issuer
  signs until it expires and does not rotate itself. Put the date in a calendar.

## 3. Seal the key into your site repository ... Required

The key goes to the cluster the way every other credential does: sealed to the
controller's key, committed, applied by the `site-secrets` Application. That
puts it in the same recovery path as everything else, which is the point: a
rebuilt cluster that restores the sealed-secrets key restores the CA with no
extra step.

**WORKSTATION**

```bash
: "${CA_CERT:?export CA_CERT first}"
: "${CA_KEY:?export CA_KEY first}"
: "${SITE_REPO:?export SITE_REPO first}"
: "${PLATFORM_NS:?export PLATFORM_NS first, see step 1}"
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" create secret tls site-ca-root \
  --namespace "$PLATFORM_NS" \
  --cert="$CA_CERT" --key="$CA_KEY" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --cert "$SITE_REPO/secrets/sealed-secrets-cert.pem" \
> "$SITE_REPO/secrets/site-ca-root.sealed.yaml"
grep -c '^kind: SealedSecret' "$SITE_REPO/secrets/site-ca-root.sealed.yaml"
```

**Success condition:** the last line prints `1`. Check the file, not the exit
code: the redirect creates the file before `kubeseal` runs, so a failed seal
leaves a zero-byte file that looks minted
([secrets § sealing one](secrets.md#sealing-one)). `kubectl create secret tls`
also refuses a key that does not match its certificate, which is a second check
on step 2.

`--cert` seals against the controller's public certificate in your site
repository, so the seal needs no cluster and cannot reach the wrong one by way of
your current kube context ([secrets § sealing one](secrets.md#sealing-one) seals
against the live controller instead; both are valid, and this one is safe to run
when the cluster is the thing you are rebuilding). The plaintext key is never
written to a new file: it goes from the file you already hold into a pipe. **The name `site-ca-root` is yours to choose,** and it
is deliberately not `tockmox-ca-root`, so the chart's Secret and yours can never
be confused or collide.

Do not commit yet. The issuer in step 4 and the values change belong in the same
commit.

## 4. Move the key without re-minting it ... Required

**Why this step exists.** A new key is a new CA, even under the same name. Every
machine that trusted the old one rejects the new one, and every certificate
issued by the old one stops chaining the next time it is renewed. The point of
moving the key, rather than generating another, is that the CA's fingerprint
does not change and nobody has to re-trust anything.

There are three starting points. They differ only in where the key and
certificate files come from; steps 2 and 3 are the same.

| You are | Get the files from |
|---|---|
| **Bringing a CA you already run** (corporate or lab) | Wherever that CA's key is held. Step 2 onward as written |
| **Adopting the chart's CA** on a running install, so that it survives a rebuild | The cluster: read `tockmox-ca-root` out and seal it as `site-ca-root`, below |
| **Moving a CA between clusters** | The old cluster's Secret, read out the same way, before you tear it down |

**To adopt a CA already in a cluster,** read the Secret out of the cluster it is
in and pipe it straight to the seal, with no file in between. The Secret is
re-created under your name and in the same namespace; the key bytes are not
touched.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${SITE_REPO:?export SITE_REPO first}"
: "${PLATFORM_NS:?export PLATFORM_NS first, see step 1}"
kubectl --context "$KUBE_CONTEXT" -n "$PLATFORM_NS" get secret tockmox-ca-root -o json \
| python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"site-ca-root","namespace":sys.argv[1]},"type":"kubernetes.io/tls","data":{"tls.crt":d["data"]["tls.crt"],"tls.key":d["data"]["tls.key"]}}))' "$PLATFORM_NS" \
| kubeseal --format yaml --cert "$SITE_REPO/secrets/sealed-secrets-cert.pem" \
> "$SITE_REPO/secrets/site-ca-root.sealed.yaml"
grep -c '^kind: SealedSecret' "$SITE_REPO/secrets/site-ca-root.sealed.yaml"
```

**Success condition:** the last line prints `1`, and the fingerprint of the
certificate you sealed equals the one you recorded:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${PLATFORM_NS:?export PLATFORM_NS first, see step 1}"
kubectl --context "$KUBE_CONTEXT" -n "$PLATFORM_NS" get secret tockmox-ca-root \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
```

Now the issuer, which is a manifest in your site repository, and the two values
that switch to it. The issuer goes under `apps/`, which the `site-apps`
Application syncs after every Tockmox layer:

```yaml
# apps/site-ca-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: site-ca
spec:
  ca:
    secretName: site-ca-root
```

```yaml
# site/values/platform.yaml
certIssuer:
  selfSigned:
    enabled: false
```

```yaml
# site/values/global.yaml
global:
  certIssuer: site-ca
```

**Set both values in the same commit as the issuer.** The chart refuses to render
when `global.certIssuer` still names `tockmox-ca` while `selfSigned.enabled` is
false, because nothing would create that issuer, and it says so. That guard is
the reason for the single commit: either value alone is a failed sync.

Every layer reads only the issuer's **name**, so nothing else changes. Commit
`secrets/site-ca-root.sealed.yaml`, `apps/site-ca-issuer.yaml` and the two values
files, and let ArgoCD sync.

**What happens next, by case.**

- **You adopted the chart's own key.** Every console certificate is re-issued by
  the new issuer from the same key. The CA's fingerprint does not change, so no
  machine re-trusts anything. This is the expected result, and it is not yet
  measured: see [what is not certified here](#what-is-not-certified-here).
- **You brought a different CA.** Every console certificate is re-issued from a
  different CA. Each machine you browse from must trust the new CA
  ([TLS and trust, step 4](tls-and-trust.md#4-install-the-ca-on-this-machine--conditional)),
  and the consoles roll to pick up the new in-cluster trust
  ([day-2 ... restart the consoles after an SSO change](../operations/day-2.md#restart-the-consoles-after-an-sso-change)).
  Do the trust step before the commit if you can: a machine that has not trusted
  the new CA sees a certificate error, not a degraded page.
- **A fresh install.** Nothing to migrate. Put `secrets/site-ca-root.sealed.yaml`,
  the issuer and the two values in the site repository before the first sync, and
  the platform layer never renders the chart's CA.

The scheme does not change (the issuer was already set, so consoles were already
`https://`), so the OIDC redirect URIs in the
[TLS and trust](tls-and-trust.md#1-point-globalcertissuer-at-an-issuer--required)
warning do not move.

**If the issuer reports `secret "site-ca-root" not found`,** the Secret is in a
different namespace from cert-manager's. Go back to step 1 and compare. If it
reports the Secret absent and the namespace is right, the sealed Secret has not
been applied yet: check `kubectl -n argocd get application site-secrets`.

## 5. Prove it worked ... Required

Assert on a certificate that was issued, not on the issuer's `Ready` condition.
`Ready` says cert-manager could read a key; it does not say the certificates
chain to the CA you meant.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get clusterissuer site-ca \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl --context "$KUBE_CONTEXT" get certificate -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,ISSUER:.spec.issuerRef.name
```

The first prints `True`. Every row of the second reads `True` and names
`site-ca`. A certificate still on `tockmox-ca` was not re-issued: it is either
still pending or its Ingress annotation did not change.

Now compare one issued certificate to the CA. Take a TLS Secret name and its
namespace from the Ingress listing in
[TLS and trust, step 1](tls-and-trust.md#1-point-globalcertissuer-at-an-issuer--required):

**WORKSTATION**

```bash
export TLS_SECRET=YOUR_TLS_SECRET_NAME
export TLS_NS=YOUR_TLS_SECRET_NAMESPACE
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
: "${CA_CERT:?export CA_CERT first}"
kubectl --context "$KUBE_CONTEXT" -n "$TLS_NS" get secret "$TLS_SECRET" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
kubectl --context "$KUBE_CONTEXT" -n "$TLS_NS" get secret "$TLS_SECRET" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > issued.crt
openssl verify -CAfile "$CA_CERT" issued.crt
```

**Success condition:** the fingerprint equals the one you recorded in step 2, and
`openssl verify` prints `issued.crt: OK`. A fingerprint that differs means the
certificate chains to a different CA; an empty `ca.crt` means the in-cluster
trust wiring ([TLS and trust, trust inside the
cluster](tls-and-trust.md#trust-inside-the-cluster)) has nothing to mount, and
the SSO token exchange will fail the way that section describes.

If `ca.crt` is empty or the chain does not verify and your CA is an
intermediate, the certificate file is missing its chain. Add it, in the order
step 2 gives, and re-seal.

**Only one CA issuer should exist.** If `selfSigned.enabled` was left on, the
cluster has two:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get clusterissuer \
  -o custom-columns=NAME:.metadata.name,CA:.spec.ca.secretName
```

**Success condition:** one row with a secret name, `site-ca` with `site-ca-root`.
A `tockmox-ca` row means the chart is still minting its own.

## What you now trust

Whoever can read the CA's key can issue a certificate for any hostname your
clients accept. That sentence is true of the chart's CA too; what changes is how
much that key is worth.

| Exposure | What it means |
|---|---|
| **Anyone who can read Secrets in the platform namespace** | Can read the key. In a default install that is cluster-admin, and anything that can read etcd or a snapshot of it |
| **The site repository plus the escrow identity** | Together open the sealed copy. This is the same pairing that opens every other secret in the deployment ([escrow](../operations/sealed-secrets-key-escrow.md#4-store-it-off-the-cluster--required)), and it now includes the CA |
| **Every machine that trusts the CA** | Accepts a certificate for any name the CA signs, including names that have nothing to do with Tockmox. A CA you already trust everywhere is trusted everywhere with this key |
| **The calendar** | The issuer does not rotate. When the CA expires, so does every console certificate it signed, on that day |

What to do about it:

- **Use a subordinate CA, not your root.** Keep a root offline and place an
  intermediate that signs only for this site. A leak then costs one intermediate,
  not every certificate your organisation trusts.
- **Constrain the names.** An X.509 name constraint limits an intermediate to
  your internal domain, so a leaked key cannot mint a certificate for someone
  else's. How strictly each client enforces it differs; check the clients you
  care about before relying on it.
- **Treat the escrow as the CA's backup,** and the escrow identity as its
  access control. A CA key sealed into the repository is only as recoverable as
  the sealed-secrets key.
- **Do not reuse a long-lived root as the chart's issuer without thinking about
  what the cluster can do with it.** The chart's own CA is ten years and
  Tockmox-only by construction. Yours may be neither.

### What a rebuild does to the chart CA

On the chart's own CA, a rebuilt cluster mints a fresh `tockmox-ca-root`. The
project met this on 2026-09-16: a rebuild produced a CA with the same subject
(`Tockmox local CA`) and a different key, and a browser that had trusted the old
one came back with `NET::ERR_CERT_AUTHORITY_INVALID` five hours into a working
install. An already-open tab made it worse: the console blamed itself ("Failed
to fetch") for a trust failure one layer below it. Nothing in the cluster was
unhealthy.

That is the case a supplied CA, or the chart's key adopted in step 4, closes:
the key comes back with the site repository, so the rebuilt cluster issues from
the same CA. [Restore a site at a second location](../operations/second-site-dr.md)
uses this.

### Going back to the chart's CA

Set `certIssuer.selfSigned.enabled` back to `true` and `global.certIssuer` to
`tockmox-ca` in one commit, and remove `apps/site-ca-issuer.yaml`. **If the chart's
`tockmox-ca-root` Secret is gone, that mints a new CA,** which is the rebuild
case above: every machine re-trusts. Remove `secrets/site-ca-root.sealed.yaml`
only once nothing issues from it.

## What is not certified here

**This page has not been executed against a cluster, and the executed-docs
harness has no path for it: that is not proven.** The harness runs nine paths and
none of them places an operator-supplied CA, so the second half of the card behind
this page, "the executed-docs harness runs that path green on a fresh cluster", is
open.

What is read from the chart rather than run:

- The Secret's namespace, its default name `tockmox-ca-root`, and the guard that
  refuses `global.certIssuer: tockmox-ca` with the chart's CA disabled. The claims
  registry pins the first two to the chart, so a change to either turns the docs
  gate red.
- That a `ClusterIssuer` of type `ca` reads its Secret from cert-manager's
  cluster resource namespace is the upstream design as the chart's own template
  comment records it; it was not re-measured for this page.

What is believed:

- That adopting the chart's key (step 4) leaves the CA's fingerprint unchanged and
  re-issues every console certificate from it without a client re-trust.
- That cert-manager re-issues a Certificate whose issuer changed, so that no
  console is left on the retired issuer.
- That the `site-apps` Application can apply a cluster-scoped `ClusterIssuer`.
- That an intermediate's chain reaches the issued certificate and `ca.crt` in the
  order step 2 gives.
- What the chart's own CA does at its renewal: whether the key is kept depends on
  cert-manager's rotation policy for the pinned version, which this page has not
  read. Do not rely on a renewed chart CA keeping its key.

Documented procedures are verified by running them, not by reviewing them. The
[testing standard](../testing-standard.md) says which paths are covered.

## Next

- [TLS and trust](tls-and-trust.md) ... trusting the CA on each machine, and the
  in-cluster trust the charts ship
- [Escrow the sealed-secrets key](../operations/sealed-secrets-key-escrow.md) ...
  the backup that now also covers your CA
- [Restore a site at a second location](../operations/second-site-dr.md) ... the
  case this page exists for
- [Secrets](secrets.md) ... sealing, and why the plaintext never touches disk

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "TLS and trust"
description: "Turn on HTTPS for every console, get the private CA out of the cluster, and install it on each machine you browse from."
tags: [tls, trust, certificates, private-ca, cert-manager, oidc]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# TLS and trust

**Two jobs, and they fail in different ways.** Nothing serves HTTPS until you
point `global.certIssuer` at an issuer. Nothing *validates* until the
certificate authority behind that issuer is trusted by the machine you browse
from.

A console with no issuer serves plain HTTP. A console with an issuer whose CA is
untrusted serves HTTPS that every browser rejects, which looks worse than HTTP
and is not.

**Four things are yours to decide**, each marked **YOU SUPPLY:** at the point
you need it: which issuer, the namespace your platform layer runs in, per-user
or machine-wide trust, and the operating system of every machine you browse
from. Your `global.internalDomain` is exported once, in
[before you begin](#before-you-begin), rather than substituted into each block,
so that every block below pastes exactly as printed. Everything else is a
command to run in order.

There is a third trust store nobody thinks about, inside the cluster. It ships
wired and you only have to prove it: [trust inside the
cluster](#trust-inside-the-cluster).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| A Tockmox install with `tockmox-platform` synced | That layer renders the CA and both ClusterIssuers | `kubectl get clusterissuer` lists `tockmox-ca` and `tockmox-ca-bootstrap` |
| `kubectl` able to read Secrets in the platform namespace | Step 2 extracts the CA's public half from one | `kubectl auth can-i get secrets -n tockmox-platform` prints `yes` |
| `openssl` on your workstation | Step 2 checks what you extracted before you trust it | `openssl version` |
| Your site repository, checked out and committable | Step 1 is a values change and it goes through GitOps | `export SITE_REPO=YOUR_SITE_REPO_PATH`, then `git -C "$SITE_REPO" status` |
| Console hostnames that resolve from your workstation | Every check on this page dials one by name | `kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}'`, then `dig +short` one of them |
| Administrator or sudo rights on each machine you will trust the CA on | Two of the three trust scopes need elevation | `sudo -n true` on Linux and macOS; an elevated PowerShell on Windows |

**Estimate, not a measurement: 15 minutes on the cluster side**, plus roughly 5
minutes on each machine you browse from.

**YOU SUPPLY:** your `global.internalDomain`, exported once so that the checks
further down are pasteable as printed. Export it again in every shell you paste
into: a machine you browse from is usually a different machine from the one you
run `kubectl` on, and always a different shell.

**WORKSTATION and CLIENT ... once per shell**

```bash
export INTERNAL_DOMAIN=YOUR_INTERNAL_DOMAIN
echo "consoles resolve under: $INTERNAL_DOMAIN"
```

Every block that reads it starts with a guard line, so a block pasted into a
shell that has not run this one stops with a message rather than dialling a
hostname with nothing after the first dot.

## Where each command runs

Two kinds of host are involved and the page switches between them. Every command
block below says which:

| Marked | Runs on |
|---|---|
| **WORKSTATION** | Your own machine, against the cluster kubeconfig. Steps 1 and 2, and the in-cluster checks |
| **CLIENT** | Every machine you browse a console from. Steps 3, 4 and 5, once per machine. Often the same physical machine as WORKSTATION, and it is still a separate pass |

**The marker sits in the prose immediately above each block, in bold, not inside
it.** A `#` line inside a block is the one piece of routing every "copy" control
strips, and on a stock macOS zsh it is not a comment either: `INTERACTIVE_COMMENTS`
is off in an interactive zsh, so a pasted `# CLIENT` returns
`zsh: command not found: #`. Because a CLIENT pass can run on the same machine
as the WORKSTATION pass, the CLIENT marker names both.

## What you will have at the end

Every console on `https://`, one certificate authority installed on each machine
you browse from, and a `curl` that verifies the chain rather than a browser that
stopped complaining.

The in-cluster half is already done for you by the shipped charts.
[Trust inside the cluster](#trust-inside-the-cluster) proves it rather than
performing it.

<a id="what-ships"></a>
<a id="turning-it-on"></a>

## 1. Point `global.certIssuer` at an issuer ... Required

**YOU SUPPLY:** which issuer. This is the only branch on the page.

| Option | Choose it when | What you set |
|---|---|---|
| **The shipped private CA** (recommended for a LAN install) | You have no public domain, no outbound access, or no wish to run ACME. Needs no internet, no DNS delegation and no ACME account, which is the point on a platform expected to run disconnected | `global.certIssuer: tockmox-ca` |
| **Your own ACME or corporate issuer** | You have a real domain and outbound access, or an existing CA you already trust everywhere | `certIssuer.selfSigned.enabled: false`, create your own `ClusterIssuer`, and point `global.certIssuer` at its name |
| **Nothing** | You are still evaluating | Leave `global.certIssuer` empty. Every console serves plain HTTP |

**If you chose your own issuer, steps 2 to 5 do not apply to you.** Every layer
reads only the issuer's name, so nothing else changes. Skip to [trust inside the
cluster](#trust-inside-the-cluster), which still does apply.

With `certIssuer.selfSigned.enabled` true, which is the default, the platform
layer renders three objects:

| Object | Name | What it does |
|---|---|---|
| `ClusterIssuer` | `tockmox-ca-bootstrap` | Signs the CA below. Nothing else |
| `Certificate` | `tockmox-ca-ca` | The CA itself. Writes its key pair to the Secret `tockmox-ca-root`, which step 2 reads |
| `ClusterIssuer` | `tockmox-ca` | Signs every console certificate, reading `tockmox-ca-root` |

**Point `global.certIssuer` at `tockmox-ca`, not at the bootstrap issuer.** The
bootstrap issuer would work, and it would sign each console with an unrelated
key: one trust-store exception per console, and another one at every renewal,
because the renewed certificate shares nothing with the one it replaced. The CA
exists so there is exactly one thing to trust and it survives renewals.

**This is not a public CA.** Browsers reject it until you finish step 4.

```yaml
# site/values/global.yaml
global:
  certIssuer: tockmox-ca
```

Commit and let ArgoCD sync.

**Success condition ... WORKSTATION**, both commands:

```bash
kubectl get clusterissuer tockmox-ca \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'

kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\t"}{.spec.tls[*].secretName}{"\n"}{end}'
```

The first prints `True`. The second lists every console hostname with a TLS
Secret name beside it; a hostname with an empty second column is an Ingress that
did not pick up the issuer. On a first install `tockmox-ca` sits `NotReady` for
a few seconds while the CA Certificate writes its Secret, and Certificates that
are `Pending` during that window are waiting correctly, not broken.

**Two things move with the scheme, and one of them breaks logins:**

- **Bookmarks and any scripts that hardcode `http://`.** They will not redirect
  if the Ingress is serving only TLS.
- **OIDC redirect URIs.** The identity layer derives its scheme from
  `global.certIssuer`, so Authentik's registered redirect URIs change with it.
  Change both in the same commit or single sign-on breaks on the scheme
  mismatch, which presents as a login loop rather than a certificate error.

<a id="getting-the-ca-out-of-the-cluster"></a>

## 2. Get the CA out of the cluster ... Conditional

**If** step 1 left `global.certIssuer` set to `tockmox-ca`, do this. Otherwise
skip to [trust inside the cluster](#trust-inside-the-cluster).

**YOU SUPPLY:** the namespace your platform layer is installed in. The default
is `tockmox-platform`; if you overrode `namespaces.platform`, this finds it:

**WORKSTATION**

```bash
kubectl get secret -A --field-selector metadata.name=tockmox-ca-root \
  -o jsonpath='{.items[0].metadata.namespace}{"\n"}'
```

Then extract the CA's public half:

**WORKSTATION**

```bash
kubectl -n tockmox-platform get secret tockmox-ca-root \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > tockmox-ca.crt
```

PowerShell, for the same extraction:

**WORKSTATION**

```powershell
$b64 = kubectl -n tockmox-platform get secret tockmox-ca-root -o jsonpath='{.data.ca\.crt}'
[IO.File]::WriteAllBytes("tockmox-ca.crt", [Convert]::FromBase64String($b64))
```

Check what you extracted before you trust it. You are about to tell a machine to
accept anything this key signs:

**WORKSTATION**

```bash
openssl x509 -in tockmox-ca.crt -noout -subject -dates -fingerprint -sha256
```

**Success condition:** the subject is `CN = Tockmox local CA`, the validity
window is ten years, and a SHA-256 fingerprint prints.

**Record that fingerprint somewhere outside the cluster.** It is how you confirm
on every other machine that you are installing the same CA, and how you
recognise it later in a trust store full of names you do not remember approving.

Copy `tockmox-ca.crt` to every machine you will browse a console from.

<a id="trusting-it"></a>

## 3. Choose the trust scope ... Required

**YOU SUPPLY:** per-user or machine-wide, once per machine. The difference
matters more than the commands do.

| Scope | What it affects | Choose it when |
|---|---|---|
| **Per-user** (the default here) | One account on one machine | A shared machine. A private CA minted by one cluster has no business being authoritative for every account on it |
| **Machine-wide** | Every user and every service on the host, including things that are not your browser | A single-user workstation, or a server that has to call the consoles. Know that is what you chose |

Uninstall commands are given beside every install command below. A CA you cannot
confidently remove is a CA you should not install.

## 4. Install the CA on this machine ... Conditional

**Find your row, run that section, and skip the rest.**

| This machine runs | Go to | Note |
|---|---|---|
| Debian, Ubuntu, or a derivative | [Linux](#linux) | Machine-wide only; no per-user system bundle exists |
| Fedora, RHEL, Rocky, Alma | [Linux](#linux) | Machine-wide only |
| Chrome or Chromium on Linux | [Linux](#linux), the NSS block | Per-user. Needed **in addition** to the system bundle |
| macOS | [macOS](#macos) | Both scopes available |
| Windows | [Windows](#windows) | Both scopes available |
| Firefox, on any of the above | [Firefox](#firefox-every-platform) | Needed **in addition** to the operating system's store |

The verification commands below are given so you can tell success from silence.
None of the per-OS install commands has been executed by Tockmox: see
[verification status](#verification-status).

### Linux

**If** this machine runs Linux. Linux has no per-user equivalent of the system
CA bundle, so the documented path is machine-wide. That asymmetry is real, not
an oversight.

**Debian, Ubuntu:**

**CLIENT**, a separate pass from WORKSTATION

```bash
sudo cp tockmox-ca.crt /usr/local/share/ca-certificates/tockmox-ca.crt
sudo update-ca-certificates
```

The `.crt` extension is required. Files with any other extension are ignored
silently, which is the most common way this step appears to succeed and does
not.

Remove:

**CLIENT**, a separate pass from WORKSTATION

```bash
sudo rm /usr/local/share/ca-certificates/tockmox-ca.crt
sudo update-ca-certificates --fresh
```

**Fedora, RHEL, Rocky, Alma:**

**CLIENT**, a separate pass from WORKSTATION

```bash
sudo cp tockmox-ca.crt /etc/pki/ca-trust/source/anchors/tockmox-ca.crt
sudo update-ca-trust
```

Remove:

**CLIENT**, a separate pass from WORKSTATION

```bash
sudo rm /etc/pki/ca-trust/source/anchors/tockmox-ca.crt
sudo update-ca-trust
```

**Success condition, either family.** `curl` on Linux reads the system bundle
you just updated, so this is a real test of the store rather than of the file.
The block dials `grafana.` under your domain; any other console hostname from
step 1 tests the same store just as well.

**CLIENT**, a separate pass from WORKSTATION

```bash
: "${INTERNAL_DOMAIN:?export INTERNAL_DOMAIN first, see Before you begin}"
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' \
  "https://grafana.$INTERNAL_DOMAIN/"
```

Prints `200 0`. See [step 5](#checking-it-worked) for what the other outcomes
mean.

**Chrome and Chromium on Linux** read their own NSS database rather than the
system bundle, so the check above passes while the browser still warns. This one
is per-user:

**CLIENT**, a separate pass from WORKSTATION

```bash
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "Tockmox local CA" -i tockmox-ca.crt
```

Remove:

**CLIENT**, a separate pass from WORKSTATION

```bash
certutil -d sql:$HOME/.pki/nssdb -D -n "Tockmox local CA"
```

**Success condition:** `certutil -d sql:$HOME/.pki/nssdb -L` lists
`Tockmox local CA`, **and** a console loads in Chrome with no warning. `curl`
cannot test this store, so the browser is the only complete check.

### macOS

**If** this machine runs macOS.

**Per-user**, into the login keychain. Prompts for your password:

**CLIENT**, a separate pass from WORKSTATION

```bash
security add-trusted-cert -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" tockmox-ca.crt
```

Remove:

**CLIENT**, a separate pass from WORKSTATION

```bash
security delete-certificate -c "Tockmox local CA" \
  "$HOME/Library/Keychains/login.keychain-db"
```

**Machine-wide**, into the System keychain. The `-d` flag is what makes it
system-wide; do not add it unless that is what you intend:

**CLIENT**, a separate pass from WORKSTATION

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain tockmox-ca.crt
```

Remove:

**CLIENT**, a separate pass from WORKSTATION

```bash
sudo security delete-certificate -c "Tockmox local CA" /Library/Keychains/System.keychain
```

**Success condition**, both halves:

**CLIENT**, a separate pass from WORKSTATION

```bash
security verify-cert -c tockmox-ca.crt -p ssl
```

Reports the certificate as verified, which is the keychain's own trust
evaluation rather than a check that the file exists. Then open a console in
Safari or Chrome, which use the keychain, and confirm there is no warning.

**Do not treat a command-line `curl` on macOS as the test.** Which trust store
a given `curl` build consults depends on how it was built, and a Homebrew
`curl` reads an OpenSSL bundle rather than the keychain. Believed, not measured
here.

Firefox does not use the keychain; see [Firefox](#firefox-every-platform).

### Windows

**If** this machine runs Windows.

**Per-user.** PowerShell, no elevation. Windows shows a confirmation dialog
before adding a root, which is the operating system doing its job:

**CLIENT**, a separate pass from WORKSTATION

```powershell
Import-Certificate -FilePath .\tockmox-ca.crt -CertStoreLocation Cert:\CurrentUser\Root
```

Remove:

**CLIENT**, a separate pass from WORKSTATION

```powershell
certutil -user -delstore Root "Tockmox local CA"
```

**Machine-wide.** Requires an elevated prompt, and the `-user` flag is what its
absence changes:

**CLIENT**, elevated, a separate pass from WORKSTATION

```powershell
certutil -addstore Root .\tockmox-ca.crt
```

Remove:

**CLIENT**, elevated, a separate pass from WORKSTATION

```powershell
certutil -delstore Root "Tockmox local CA"
```

**Success condition.** The line dials `grafana.` under your domain; substitute
your `global.internalDomain` for `YOUR_INTERNAL_DOMAIN`, and any other console
hostname from step 1 if you prefer. This is the one place on the page that is
still a hand substitution, because the export block in
[before you begin](#before-you-begin) is a POSIX shell form and a Windows CLIENT
has no reason to have run it.

**CLIENT**, a separate pass from WORKSTATION

```powershell
(Invoke-WebRequest -Uri https://grafana.YOUR_INTERNAL_DOMAIN/ -UseBasicParsing).StatusCode
```

Prints `200`. This goes through Schannel and the Windows certificate store, so
it tests the store you just wrote to. Edge and Chrome use that same store.
Firefox does not.

### Firefox, every platform

**If** you browse a console with Firefox, on any operating system. Firefox ships
its own root store and ignores the operating system's on all three platforms, so
this is needed in addition to whatever you did above.

Settings, Privacy and Security, Certificates, View Certificates, Authorities,
Import. Select `tockmox-ca.crt` and tick "Trust this CA to identify websites."

**Success condition:** a console loads in Firefox with no warning, and the
certificate viewer shows the chain ending at `Tockmox local CA`. There is no
command-line equivalent; Firefox's store is only reachable from Firefox.

<a id="checking-it-worked"></a>

## 5. Prove it worked ... Required

Assert on the connection, not on the absence of a warning in one browser. The
block dials `grafana.` under your domain; substitute any other console hostname
from step 1 if that one is not the console you care about.

**CLIENT**, a separate pass from WORKSTATION

```bash
: "${INTERNAL_DOMAIN:?export INTERNAL_DOMAIN first, see Before you begin}"
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' \
  "https://grafana.$INTERNAL_DOMAIN/"
```

| What you get | What it means |
|---|---|
| `200 0` | The chain verified against a store the system already trusts. Done |
| A non-zero second field | The verification result, and it names the reason |
| `curl` exit code 60 | The CA is not trusted by the store `curl` is using. Usually the install went to a different store than the one you tested from |
| A DNS or connection error | Not a trust problem. The hostname does not resolve, or nothing is listening |

Repeat once per machine and per browser family, because each one you added is a
separate store.

### Clicking through the browser warning is not a workaround

A browser's click-through certificate exception covers the page. **It does not
extend to WebSockets**, and the chat console delivers model responses over one.
So a session where you accepted the warning looks like a working install and is
not.

**Observed on a fresh install 2026-08-19**, with the CA deliberately untrusted:
sign-on works, the model list loads, you send a message, and the reply cursor
blinks forever. The completion is real ... the gateway logs 200, spend is
tracked, the chat is even titled server-side ... but the `wss://` handshake dies
on the untrusted CA with **no error in the browser console, no failed request in
the network panel, and nothing in the server log**.

Every HTTP request succeeding while every response hangs is this, and nothing
anywhere names the certificate as the cause. Install the CA properly rather than
clicking through, which is why step 4 comes before you use anything.

<a id="what-tockmox-does-about-it"></a>
<a id="go-consoles-grafana-the-argo-workflows-server"></a>
<a id="the-python-console-open-webui"></a>
<a id="why-the-two-are-not-unified"></a>
<a id="one-detail-both-share"></a>
<a id="if-you-add-your-own-console"></a>

## Trust inside the cluster

**Required, and the shipped charts already do it.** Everything above is about
the machine in front of you. It is half the problem.

Grafana, Open WebUI and the Argo Workflows server all perform the OIDC token
exchange **themselves, server side**, against
`https://auth.` under your internal domain. Your browser trusting the CA does nothing
for them: their containers have their own trust stores, and a private CA is in
none of them.

This is what that failure looks like, and it reads like something else entirely.
Login gets as far as the provider, comes back, and dies at the token step:

```
URLError [SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate
```

Local break-glass accounts keep working throughout, so every console reports
healthy and only federated users are locked out. The symptom entry is in
[troubleshooting](../operations/troubleshooting.md#sso-login-dies-at-the-token-step-with-a-certificate-verify-failure).

The charts ship the wiring, so there is nothing here to run. What each console
gets:

| Console | Runtime | Shape the charts ship |
|---|---|---|
| Grafana | Go | `ca.crt` mounted from the console's own certificate Secret, with `SSL_CERT_FILE` pointed at it |
| Argo Workflows server | Go | The same |
| Open WebUI | Python | An initContainer on Open WebUI's own image concatenates that image's CA store with the Tockmox CA; `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` both point at the result |

**The mechanism differs because the runtimes differ, and that was measured
rather than chosen.** Go unions `SSL_CERT_FILE` with the default certificate
directories; Python's `requests` and `httpx` treat it as the entire store. The
measurement tables, the 77-minute distroless outage that settled the question,
and what to do for a console you add yourself are in
[architecture ... in-cluster trust](../architecture.md#in-cluster-trust-and-why-the-mechanism-differs-by-runtime).

**Success condition ... WORKSTATION:**

```bash
kubectl -n tockmox-monitoring get deployment tockmox-observability-grafana \
  -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="SSL_CERT_FILE")]}{.value}{"\n"}{end}'

kubectl -n tockmox-ai get statefulset tockmox-ai-open-webui \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'
```

The first prints `/etc/tockmox/ca/ca.crt`. The second includes
`tockmox-trust-bundle`. An empty result from either is the fault, and it means a
site override replaced a list-valued subchart key rather than adding to it.

From a checkout of the Tockmox source tree, `./tools/check-trust-wiring.sh`
asserts the same shapes on the rendered artifact, and fails a Go console that
grows an initContainer as well as a Python one that loses it. **Run it with
bash 4 or newer.** Measured against bash 3.2.57 on macOS, 2026-08-31: it printed
an error, examined nothing, and exited 0. The script now guards against that,
and the guard is the reason to check which bash you invoked it with.

**The complete check is a federated login**, end to end, in a browser. The
mechanism is verified and the walk-through is not: see
[verification status](#verification-status).

<a id="changing-sso-settings-later"></a>

## Changing SSO settings later

Some SSO changes roll the consoles and some do not, and the ones that do not
leave a healthy-looking cluster serving a stale client ID. Changing
`global.certIssuer`, which is what this page asks you to do, is one of the ones
that **does** roll them.

The procedure, the two exceptions and the success condition are in
[day-2 ... restart the consoles after an SSO change](../operations/day-2.md#restart-the-consoles-after-an-sso-change).
Why `envFrom` cannot do it for you is in
[identity](identity.md#changing-ssoclientid-or-a-group-name-needs-a-restart-you-have-to-ask-for).

<a id="verification-status"></a>

## Verification status

Stated per the evidence class, because these procedures differ by platform and
Tockmox has not run all of them.

| Step | Evidence |
|---|---|
| The CA issues working certificates | **Verified on a cluster, 2026-08-15.** An annotated Ingress received a certificate in about five seconds, Traefik served it, and a client given the CA got HTTP 200 with `ssl_verify_result` 0 |
| A client with no trust is refused | **Verified, 2026-08-15.** `curl` exit 60 |
| The extracted CA is a valid ten-year CA | **Verified, 2026-08-15.** `CA:TRUE`, `Certificate Sign`, ten-year window |
| The CA works as a trust anchor from a hashed store | **Verified, 2026-08-15**, via `openssl verify -CApath` |
| The Linux, macOS and Windows install commands, and their success conditions | **Not executed by Tockmox.** Written against vendor documentation and the behaviour above, not run on each platform |
| Which trust store a macOS `curl` consults | **Unverified.** Stated as a belief on this page, which is why the macOS success condition is `security verify-cert` and a browser |
| The in-cluster trust bundle is built and used | **Verified on a cluster, 2026-08-15.** A pod carrying the shipped spec, in `tockmox-ai`, with the real certificate Secret: 142 certificates from the image plus 1 from the CA, and `urllib`, `httpx`, `requests` and `aiohttp` all verified the Authentik discovery document; the token endpoint answered 405 to a GET, which is reached rather than blocked |
| Go binaries honour the same bundle | **Verified on a cluster, 2026-08-15.** With the bundle unset a Go client got `x509: certificate signed by unknown authority`; with it set the same call reached the server and failed at the HTTP layer instead, and a public host still verified |
| Go reads SSL_CERT_FILE as an ADDITION to the system store | **Verified on a cluster, 2026-08-15.** CA alone: internal verified and a public host still verified. Missing file: public still verified |
| Python reads it as a REPLACEMENT | **Verified in the Open WebUI image, 2026-08-15.** CA alone broke httpx and requests against a public host; the concatenated bundle did not |
| The Python construct cannot run on a distroless image | **Observed in production on the lab, 2026-08-15.** The Argo server sat in Init:CrashLoopBackOff for 77 minutes; argocli has no /bin/sh |
| Grafana and Argo Workflows browser login end to end | **Verified on a greenfield install, 2026-09-10, re-confirmed 2026-09-13.** On the 0.6.0-rc2 greenfield a `tockmox-admins` member and a `tockmox-users` member each completed an SSO browser login to Grafana, Open WebUI and Argo Workflows; the rc3 acceptance run repeated it on 2026-09-13. Note what the run needed first: a greenfield Authentik carries three principals and no human ones, because the `tockmox-groups` blueprint creates the groups and nothing creates users ... so both accounts have to be created and assigned before any login can be attempted |

If one of these is wrong on your machine, that is worth an issue. The scope
defaults are chosen so that a wrong command fails to install rather than
installing more broadly than you asked.

## What is not certified here

The cluster-side rows above are measurements. **They are not a claim that this
page has been executed start to finish as written**, and the per-OS trust
installs in step 4 have not been run by Tockmox on any of the three platforms.

Documented procedures are verified by running them, not by reviewing them. The
[testing standard](../testing-standard.md) says which paths are covered and
which are not yet.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "Secrets"
description: "Sealing secrets to your own cluster key, where the sealed-secrets controller chart comes from, backing up the key, and the Secrets the platform expects you to create."
tags: [secrets, sealed-secrets, bitnami, rotation, backup]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Secrets

Tockmox never holds your secrets. It ships templates; you seal your own.

> **From 0.7.0 the installer can do the whole sequence:**
> `install/tockmox-install.sh bootstrap-secrets` installs or adopts the
> sealed-secrets controller, exports its key encrypted, and runs
> `mint-secrets.sh`. It is described in
> [installation § Phase 2.5](../deployment/install.md#the-bootstrap-route-bootstrap-secrets),
> and this page keeps the reference detail for both routes.
>
> **There is a script for all of this: `./tools/mint-secrets.sh`.** It mints
> every credential below, seals each to your cluster's key, writes them to
> `secrets/`, and keeps the four cross-namespace pairs in step. It refuses to
> overwrite, so it is safe to re-run after a partial attempt.
>
> Read the rest of this page anyway if you want to know what each Secret is
> for, or if you are minting one by hand. But do not paste ten blocks at 1am
> when one command does it correctly. This is the longest manual step in the
> install and the one most likely to go wrong quietly.

## How sealed secrets work

A SealedSecret is encrypted **to your cluster's public key**. Only the
controller running in your cluster can decrypt it. That is what makes it safe
to commit to git ... including a private repo you later make public, though we
would not recommend testing that.

```
your plaintext ──seal──▶ SealedSecret ──commit──▶ git ──sync──▶ controller ──▶ Secret
                  ▲                                                  │
                  └────────── your cluster's public key       private key never leaves
```

## Sealing one

```bash
kubectl create secret generic my-secret \
  --namespace tockmox-ai \
  --from-literal=api-key='...' \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
  > secrets/my-secret.sealed.yaml
```

**Success condition:** `grep -c '^kind: SealedSecret' secrets/my-secret.sealed.yaml`
prints `1`. Check the file, not the command. The `>` redirect creates
`secrets/my-secret.sealed.yaml` **before** `kubeseal` runs, so a failed seal
leaves a zero-byte file sitting there looking minted. Commit that and the gap
surfaces days later as a pod stuck in `CreateContainerConfigError`, naming
neither the secret nor the seal.

**Those two `--controller-*` flags are not optional.** `kubeseal` defaults to a
controller Service named `sealed-secrets-controller`, and the install these docs
give you ([fresh cluster § install
sealed-secrets](../deployment/fresh-install.md#7-install-sealed-secrets-with-your-own-key))
names its Helm release `sealed-secrets`, which is what the chart names the
Service after. The default therefore never matches. If you installed the chart
under a different release name or namespace, put **your** names here; the values
above are the ones the documented install produces.

Commit the `.sealed.yaml`. Never commit the intermediate. The site template's
`.gitignore` blocks `secrets/*.plain.yaml` as a backstop, but the real defence
is the pipe above ... the plaintext never touches disk.

### Keep kubeseal at the controller's version

The controller was installed at whatever chart version the cluster preparation
page derived on the day, so it moves on its own. `kubeseal` on your
workstation was installed whenever it was, and nothing on either side checks
the other. On the reference lab on 2026-09-12 the pair read `kubeseal
v0.39.1` against `sealed-secrets-controller:0.40.0`, caught only because
someone looked before sealing.

**What a mismatch costs is silent at seal time.** `kubeseal` fetches the
controller's public certificate and encrypts to it; a client that cannot
understand the controller's response, or writes a `SealedSecret` schema the
controller does not read, still produces a file, and `grep -c '^kind:
SealedSecret'` still prints `1`. The failure arrives days later as a pod in
`CreateContainerConfigError`, which is the same symptom as a Secret that was
never sealed at all. **Not measured:** whether `0.39` against `0.40`
specifically breaks. The wire format is generally stable across minors and no
test was run either way. The claim here is narrower: the docs used to make no
statement, offer no check, and the failure they would be guarding against does
not announce itself. Match major and minor, and read both before the first
seal:

```bash
kubeseal --version
kubectl -n kube-system get deploy sealed-secrets \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

[Installation](../deployment/install.md#tools-this-page-needs-and-preparation-did-not-install)
runs this as part of its tool check, before any credential is minted.

## Where the controller chart comes from, and why it matters

The install command is in
[prepare a fresh cluster § install sealed-secrets](../deployment/fresh-install.md#7-install-sealed-secrets-with-your-own-key).
Which source you install it from is not a preference, it is a version gap.

Measured 2026-08-15:

| Source | Chart | Controller |
|---|---|---|
| `oci://registry-1.docker.io/bitnamicharts/sealed-secrets` | 2.19.1 | **0.38.4** |
| `https://charts.bitnami.com/bitnami` | 2.5.19 | 0.31.0 |
| `https://bitnami-labs.github.io/sealed-secrets` | 404 | ... |

The third answers 404 to `helm repo add`; the second resolves but is frozen
several releases back, which matters more here than it would elsewhere: this
controller holds the key every sealed secret in your site repository is
encrypted to ([history](#history-the-sealed-secrets-chart-source)).

Bitnami has been changing what its public catalogue carries. **Pin the chart
version you install**, and mirror it if this deployment matters to you ...
[air-gapped installation](../deployment/airgap.md) covers mirroring properly.

## Back up the controller key. Now.

Losing it makes every sealed secret you have committed permanently unreadable.
Not inconvenient ... unreadable.

**The full procedure, with the encryption, the storage rules, the renewal
cadence, the restore and a drill, is
[escrow the sealed-secrets key](../operations/sealed-secrets-key-escrow.md).**
What follows is the short version and the reasoning.

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-BACKUP.yaml
```

Store it somewhere that is not the cluster it protects. A password manager, an
encrypted volume, a safe. This file is equivalent to every secret in your
deployment, so treat it that way. Three properties worth engineering rather
than hoping for:

- **At least one copy off the network entirely.** A backup that lives only in
  a networked service shares fate with whatever compromises or outlives that
  service. An encrypted USB key in a drawer is unfashionable and works.
- **Re-export after key renewal.** The controller mints a new sealing key
  every 30 days by default and keeps the old ones; the label selector above
  captures all of them, but only as of the day you ran it. A backup from
  January cannot decrypt a secret sealed in March. Re-export on a schedule, or
  after any rotation.
- **Prove it once.** Restore the backup into a scratch cluster (kind is
  enough), install the controller, and watch one SealedSecret from your site
  repo actually unseal. A key backup that has never decrypted anything is a
  hope with a filename. This is the same principle the restore drills apply to
  databases, pointed at the one object that can never be regenerated.

**Restoring after a cluster rebuild:** apply the backup before the controller
starts, and your existing SealedSecrets decrypt as if nothing happened. Without
it you re-seal everything from original sources, assuming you still have them.

### What `bootstrap-secrets` does with the key

The subcommand does the export above for you, with three differences worth
knowing. The export is a small YAML document (name, label, `tls.crt`, `tls.key`
of each key Secret, no `uid` or `resourceVersion`) so that a create accepts it
in any namespace, and it is encrypted before it touches a file: with `age`
(`--age-recipient`) or with `openssl` AES-256 and PBKDF2 (`--passphrase-file`).
It refuses to write the key in the clear. It will not write inside your site
repository. And `--mode recover` restores it **before** the controller
starts, which is the order the paragraph above requires.

A backup made by `kubectl get -o yaml` by hand is not this format and
`--mode recover` refuses it with a reason. Who holds the age identity, where the
off-site copy lives, how often to re-export, and how to drill the restore are on
[escrow the sealed-secrets key](../operations/sealed-secrets-key-escrow.md).

## Rotation

Sealed secrets do not rotate themselves. Rotating means re-sealing with a new
value and committing.

Worth putting a calendar reminder against anything long-lived. An unrotated
credential is not an emergency; an unrotated credential nobody remembers exists
is.

**Minting only some of them.** `--only LIST` takes `authentik`, `sso`, `grafana`,
`ntfy`, `litellm` or `apprise`, comma separated, and mints just those groups; a
group is its whole set of files, so `sso` is `sso.sealed.yaml` and its three
per-console halves together. The pair check runs only for the groups you name,
and an unknown name is refused before anything is written. A site that already
holds the rest and needs only the SSO client secrets passes `--only sso` instead
of minting everything into a scratch directory and deleting most of it.

**Rotating with the script.** `mint-secrets.sh` refuses to overwrite, so
re-running it after a partial run mints only what is missing. Rotating therefore
means deleting the file you want rotated and running it again ... **and if that
file is half of a pair, the script tells you which other file has to go with
it**, because rotating one side alone is the failure it exists to prevent. The
four pairs are listed at the top of the script.

## Secrets the platform expects you to create

Tockmox generates no credentials ... a password the platform invented is a
password that rotates on the next render and that you cannot audit. Each of
these is a Secret you create (and seal into your site repo), named where the
values file points:

| Secret | Namespace | Keys | Consumed by |
|---|---|---|---|
| `tockmox-grafana-admin` | `tockmox-monitoring` | `admin-user`, `admin-password` | Grafana local login (break-glass) |
| `tockmox-openwebui-bootstrap-admin` | `tockmox-ai` | `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`, `WEBUI_ADMIN_NAME` | Open WebUI's bootstrap administrator, created at startup only while it has no accounts, so the first SSO login cannot become the console's admin (TM-0859). Optional; `mint-secrets.sh` mints it with an address under `.invalid` that no Authentik user can hold. The console's break-glass login: read the password with `kubectl -n tockmox-ai get secret tockmox-openwebui-bootstrap-admin -o jsonpath='{.data.WEBUI_ADMIN_PASSWORD}'` and decode it |
| `tockmox-authentik` | `tockmox-authentik` | `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRESQL__PASSWORD` | Authentik server + worker |
| `tockmox-authentik-postgres` | `tockmox-authentik` | `password`, `postgres-password` | Authentik's bundled PostgreSQL. `password` must EQUAL `AUTHENTIK_POSTGRESQL__PASSWORD` above ... the database and the server must agree |
| `tockmox-sso` | `tockmox-authentik` | `GRAFANA_CLIENT_SECRET`, `OPENWEBUI_CLIENT_SECRET`, `ARGO_CLIENT_SECRET` | The shipped SSO blueprints (via `!Env`) |
| `tockmox-sso-grafana` | `tockmox-monitoring` | `client-secret` | Grafana OIDC. Same value as `GRAFANA_CLIENT_SECRET` |
| `tockmox-sso-openwebui` | `tockmox-ai` | `client-secret` | Open WebUI OIDC. Same value as `OPENWEBUI_CLIENT_SECRET` |
| `tockmox-sso-argo` | `tockmox-devops` | `client-id` (= `tockmox-argo`), `client-secret` | Argo Workflows SSO. Same value as `ARGO_CLIENT_SECRET` |
| `tockmox-ntfy-auth` | `tockmox-monitoring` | `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`, `NTFY_AUTH_TOKENS`, `NTFY_BRIDGE_TOKEN` | ntfy users, ACL and publish token. Without it ntfy is `deny-all` with no users and **no alert reaches anybody** |
| `tockmox-apprise-config` | `tockmox-monitoring` | `tockmox` | Apprise destination URLs, newline-separated, each as `tockmox=<url>`. Only needed with `notifications.apprise.enabled` |
| `tockmox-litellm` | `tockmox-ai` | `masterkey` | The model gateway's admin key. Needed with the model gateway, which is on by default since 0.8.0 (`apps.litellm` follows `capabilities.aiPlane`); `mint-secrets.sh` mints it by default, `--without-litellm` opts out |
| `tockmox-litellm-db` | `tockmox-ai` | `username`, `password` (type `kubernetes.io/basic-auth`) | The model gateway's database. CloudNativePG bootstraps the owner from this same Secret, so one object holds the credential. `username` must EQUAL `modelGateway.database.owner` |
| `tockmox-openwebui-gateway` | `tockmox-ai` | `api-key` | The console's virtual key for the gateway. **Not yours to mint**: a Job in the AI layer creates it once the gateway answers (`modelGateway.consoleKey`, since 0.8.0). Listed here because the console waits on it, and because the manual fallback below writes the same object |

**`openssl rand -base64` has two hazards, and both bite downstream rather than
here.**

1. **Its alphabet.** It emits `/` and `+`. **Mint the model-gateway database
   password with `openssl rand -hex 32`, not `-base64`** ... LiteLLM substitutes
   it into a connection string, and a `/` or a `+` produces a URL that parses as
   something other than what you wrote. The failure is an authentication error
   that names neither the character nor the encoding.
2. **It wraps at 64 columns.** Any length above 48 bytes puts a newline *inside*
   the value, and command substitution strips only the trailing one. **Pipe
   through `| tr -d '\n'` wherever the length exceeds 48**, as the
   `AUTHENTIK_SECRET_KEY` block below does. Authentik authenticates its embedded
   outpost with that key; HTTP header values may not contain control characters,
   so a wrapped key leaves the outpost failing every few seconds, at `warn`, for
   the life of the install, with nothing else visibly wrong. `openssl rand -hex`
   never wraps at any length and sidesteps both hazards.

One block mints the lot ... each shared value is generated once and lands on
both sides of its pair:

```bash
AK_PG=$(openssl rand -base64 24); SSO_GRAF=$(openssl rand -base64 32)
SSO_OWUI=$(openssl rand -base64 32); SSO_ARGO=$(openssl rand -base64 32)
seal() {
  kubeseal --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system
}

kubectl -n tockmox-monitoring create secret generic tockmox-grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | seal > secrets/grafana-admin.sealed.yaml

kubectl -n tockmox-authentik create secret generic tockmox-authentik \
  --from-literal=AUTHENTIK_SECRET_KEY="$(openssl rand -base64 60 | tr -d '\n')" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$AK_PG" \
  --dry-run=client -o yaml | seal > secrets/authentik.sealed.yaml

kubectl -n tockmox-authentik create secret generic tockmox-authentik-postgres \
  --from-literal=password="$AK_PG" \
  --from-literal=postgres-password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | seal > secrets/authentik-postgres.sealed.yaml

kubectl -n tockmox-authentik create secret generic tockmox-sso \
  --from-literal=GRAFANA_CLIENT_SECRET="$SSO_GRAF" \
  --from-literal=OPENWEBUI_CLIENT_SECRET="$SSO_OWUI" \
  --from-literal=ARGO_CLIENT_SECRET="$SSO_ARGO" \
  --dry-run=client -o yaml | seal > secrets/sso.sealed.yaml

kubectl -n tockmox-monitoring create secret generic tockmox-sso-grafana \
  --from-literal=client-secret="$SSO_GRAF" \
  --dry-run=client -o yaml | seal > secrets/sso-grafana.sealed.yaml

kubectl -n tockmox-ai create secret generic tockmox-sso-openwebui \
  --from-literal=client-secret="$SSO_OWUI" \
  --dry-run=client -o yaml | seal > secrets/sso-openwebui.sealed.yaml

kubectl -n tockmox-devops create secret generic tockmox-sso-argo \
  --from-literal=client-id=tockmox-argo \
  --from-literal=client-secret="$SSO_ARGO" \
  --dry-run=client -o yaml | seal > secrets/sso-argo.sealed.yaml
```

**Success condition:** `grep -c '^kind: SealedSecret' secrets/*.sealed.yaml`
prints `1` for every file. A zero-byte file here is the failure described under
[Sealing one](#sealing-one) ... `kubeseal` could not reach the controller, and
the shell reported success anyway. Check before you commit, because these nine
files are the credentials the whole platform starts against.

### Notifications

ntfy is deliberately `deny-all`, so this Secret is what makes alerting able to
reach anybody. It is separate from the block above because two of its values
cannot be generated with `openssl`: ntfy wants a bcrypt password hash and a
token in its own `tk_` format, and both come from the ntfy binary.

The block below runs the ntfy image **only to mint those credentials**. Nothing
is deployed by it.

**`tools/mint-secrets.sh` does all of this for you and no longer needs a local
container runtime.** It uses docker, podman or nerdctl when one is on PATH, and
otherwise runs the same image **as a throwaway pod on the cluster you are
already sealing against**. That matters because macOS ships none of the three,
so the machine most installs are driven from could not mint the one Secret
without which no alert reaches anybody. Verified end to end on 2026-09-11 with
no runtime present: both bcrypt hashes and the `tk_` token came back correct.
Do the block below by hand only if you want to, or if you sealed with `--cert`
and there is no cluster to borrow.

**If you do run it by hand and have no local runtime**, substitute this for the
`docker run` calls ... same image, same arguments, borrowed from the cluster:

```bash
ntfy_run() {
  kubectl -n default run "ntfy-mint-$$" --rm -i --restart=Never \
    --image=binwiederhier/ntfy:v2.27.0 --command -- ntfy "$@" 2>/dev/null
}
```

**Extract the hash by PATTERN, not by taking the last field.** `kubectl run
--rm` prints the pod's deletion on stdout after the command's own output, so a
last-field read returns two lines and puts the word `namespace` inside your
Secret. A bcrypt hash has an unambiguous shape; match it:

```bash
printf '%s\n%s\n' "$PW" "$PW" | ntfy_run user hash \
  | grep -oE '\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{53}' | head -1
```

The `hash` helper exists because `ntfy user hash` **prompts, twice**, and reads a
terminal rather than a pipe. Feeding it one line gets you `password cannot be
empty`; feeding it the password twice works, and the hash is the last field of
its output, because both prompts land on the same line as the answer.

Set `YOU_PASS` to something you can type ... you will be typing it on a phone.

```bash
NTFY=binwiederhier/ntfy:v2.27.0

hash() { printf '%s\n%s\n' "$1" "$1" \
         | docker run --rm -i "$NTFY" user hash | awk '{print $NF}'; }

YOU_PASS='choose-something-you-can-type'
YOU_HASH=$(hash "$YOU_PASS")
BRIDGE_HASH=$(hash "$(openssl rand -base64 18)")
BRIDGE_TOKEN=$(docker run --rm "$NTFY" token generate)

kubectl -n tockmox-monitoring create secret generic tockmox-ntfy-auth \
  --from-literal=NTFY_AUTH_USERS="you:${YOU_HASH}:user,alertbridge:${BRIDGE_HASH}:user" \
  --from-literal=NTFY_AUTH_ACCESS="alertbridge:alerts:wo,you:alerts:rw" \
  --from-literal=NTFY_AUTH_TOKENS="alertbridge:${BRIDGE_TOKEN}:alert bridge" \
  --from-literal=NTFY_BRIDGE_TOKEN="${BRIDGE_TOKEN}" \
  --dry-run=client -o yaml | seal > secrets/ntfy-auth.sealed.yaml
```

**Both users are `user`, not `admin`, and ntfy will not start otherwise.** It refuses
to start if an admin also carries an ACL entry:

```
invalid auth-access: you:alerts:rw, user you is not a regular user,
only regular users can have ACL entries
```

An admin already has full access, so an ACL row for one is a contradiction
rather than a redundancy. Since receiving alerts needs no administrative
rights, the least-privilege reading and the only working reading agree: keep
both accounts regular and let the ACL say what each may do. Add an admin later
only if you need one to manage ntfy itself.

A bcrypt hash contains `$`. ntfy's own documentation tells you to double it to
`$$` ... that is a **docker-compose** rule, because compose interpolates. A
Kubernetes Secret does not interpolate anything, so put the hash in exactly as
`ntfy user hash` printed it. Doubling it here produces a hash that silently
never matches.

Note the shape of the ACL: the bridge gets `wo`, write-only on one topic. It
publishes alerts; it has no business reading them back, and a leaked bridge
token should not hand anybody your alert history. `you` gets `rw` so the phone
app can subscribe.

Verified end to end on ntfy v2.27.0: anonymous publish `403`, bridge token
publish `200`, that same token reading the topic `403`, and that same token
publishing to any other topic `403`.

Adding Apprise later:

```bash
kubectl -n tockmox-monitoring create secret generic tockmox-apprise-config \
  --from-literal=tockmox="$(printf '%s\n' \
      'tockmox=ntfy://tockmox-ntfy.tockmox-monitoring.svc/alerts' \
      'tockmox=mailto://user:pass@smtp.example.com')" \
  --dry-run=client -o yaml | seal > secrets/apprise-config.sealed.yaml
```

Keep the `ntfy://` line when you add email or Slack, or turning on fan-out
quietly costs you the phone path. **Every line starts `tockmox=`** (the tag the
bridge notifies; the config is locked, so an untagged line is never sent to).
A Secret made before 0.8.0-rc2 has bare URLs: re-create it with the prefix.

### Until they exist

A consumer whose Secret is missing waits with a visible
`CreateContainerConfigError` naming exactly what is absent. Two are gentler on
purpose: the SSO client secrets are referenced `optional`, so consoles stay on
local login until they appear; and `tockmox-ntfy-auth` is `optional` so ntfy
starts and `TockmoxNotificationSinkDown` fires ... a missing Secret should show up
on the dashboard rather than as a pod that will not start.

### ArgoCD reports Synced anyway, and that is designed

**What it looks like if you skip minting entirely.** Every dependent workload
sits in `CreateContainerConfigError`, naming the Secret it wants, indefinitely.
Observed on a clean install 2026-08-18: nine layers reported Synced while
LiteLLM, its migration Job, its CNPG initdb Job, Open WebUI, both Authentik
pods and Grafana all waited. **Argo says Synced because the manifests are
correct.** The gap is a credential, not a manifest, and Argo cannot see it.

That is the designed behaviour rather than a bug ... a render cannot prove a
Secret exists, so the failure is deliberately deferred to the pod, where the
message names the missing object. It only reads as a mystery if nobody told you
this step existed ([history](#history-the-secrets-step-itself)).

<a id="the-consoles-model-gateway-key-is-a-post-install-step"></a>

## The console's model-gateway key is minted after the first sync

`mint-secrets.sh` creates every credential that can exist before the cluster
does. **One cannot.** Open WebUI authenticates to the model gateway with a
LiteLLM *virtual key*, and a virtual key can only be issued by LiteLLM, which
has to be running first. So `tockmox-openwebui-gateway` in `tockmox-ai` is
minted after the first sync, and until it exists the console alone stays in
`CreateContainerConfigError` with:

```
secret "tockmox-openwebui-gateway" not found
```

**Since 0.8.0 the chart does the minting** (TM-0460 ruling B1). The AI layer
renders a Job, `<release>-gateway-key-<hash>`, that waits for the gateway's
readiness endpoint, calls `POST /key/generate` with the master key, and creates
the Secret. It holds the master key for that one request. Its Role is `get`
and `update` on that one Secret name, `create` on Secrets, and `delete` on the
console's pod names: RBAC can scope get, update and delete by name and cannot
scope a create, so the script is the guard that writes only that name, and
nothing in the Role can list, read or delete any other Secret. When the Secret
already exists the Job sends its key to the gateway and leaves a key the
gateway accepts alone, so a re-sync never rotates a working key; a key the
gateway rejects (401, the shape of a gateway turned off and on again) is
replaced in place and the console's pods restarted on it. Between syncs a
CronJob checks the key the same way and `TockmoxConsoleKeyRejected` fires on
a rejection
([ai-plane § when the gateway rejects the console's key](../usage/ai-plane.md#when-the-gateway-rejects-the-consoles-key)).
To rotate by hand,
delete the Secret and the next sync's Job (or a
`kubectl delete job` and a sync) mints a new one, and the old key stays valid
in LiteLLM until you revoke it there. `modelGateway.consoleKey.enabled: false`
keeps the step manual; the commands are in
[install § confirm the console's model-gateway key](../deployment/install.md#mint-the-consoles-model-gateway-key).

**Why a separate key rather than the master.** The master key can mint and list
other keys. Putting it in a console would make the gateway a pass-through with
extra steps, and give anyone who compromised the console the ability to issue
themselves more access. Verified on a fresh install 2026-08-18, using the
console's key:

| Request | Result |
|---|---|
| `GET /v1/models` | **200** ... it can see the six models |
| `POST /key/generate` | **401** ... it cannot mint keys |
| `GET /key/list` | **403** ... it cannot enumerate them |

That is the scoping doing its job. If your console key returns 200 to any of
the last two, it is the master key and you should revoke it.

## History and corrections

What this page used to say, and when it changed. Nothing here is needed to follow the page.

<a id="history-the-sealed-secrets-chart-source"></a>

### The sealed-secrets chart source

The GitHub Pages source is what these docs recommended until 2026-08-15;
`helm repo add` fails against it outright. The OCI reference replaced it after
the three sources were measured side by side (2026-08-15: 0.38.4 against 0.31.0
against a 404).

<a id="history-the-secrets-step-itself"></a>

### The secrets step itself

Until 2026-08-18 no page said that the operator creates these Secrets, so
the deferred failure read as a mystery: seven workloads waited on a
credential while Argo reported Synced. The step, the script and this page date
from that install.

## What is not certified here

The following are true of `bootstrap-secrets` as of the commit that added it.

- **Measured:** the script's own logic and the shape of the calls it makes, with
  `kubectl`, `helm`, `kubeseal`, `age` and `docker` replaced by shims
  (`tests/installer/`, groups B1 to B12). That includes: a second run rewriting no
  sealed file, no plaintext credential in any file a run leaves behind (raw or
  base64) including after a forced failure, a wrong context, server or adopted
  controller being refused, and a half-present matched pair being refused.
- **Measured, chart source:** `https://bitnami.github.io/sealed-secrets` answers
  200 for `index.yaml` (2026-09-29), and chart 2.20.0 renders a Deployment with
  image `docker.io/bitnami/sealed-secrets-controller:0.40.0` and a Service named
  by `fullnameOverride`. The older `bitnami-labs.github.io` address in the table
  above still answers 404.
- **Not measured:** any of it against a live cluster. That the real controller
  serves its certificate by the time the script asks, that a key backup made by
  the go-template restores under a real `kubectl`, that real `kubeseal` accepts
  the manifests, and that ArgoCD then delivers them. A greenfield install with no
  manual step has not been run.
- **Not measured:** that the `site-secrets` Application's `retry` block is enough
  when its wave races the policy layer's namespaces. The wave was not moved.
- **Naming difference:** this route installs the controller as
  `sealed-secrets-controller` (kubeseal's own default, so a hand-run `kubeseal`
  needs no flags). The manual route above installs `sealed-secrets`. Both are
  supported; commands on this page that name `sealed-secrets` apply to the
  manual route.
- **Air-gapped:** the chart and the image are carried in like ArgoCD's and
  are not listed in `images.txt`
  ([air-gapped § 4](../deployment/airgap.md#4-carry-in-the-three-prerequisites--required)).

## What Tockmox will never ask for

- Credentials in `tockmox.yaml`. Look at the example ... there are none.
- Secrets in Helm values. Values files are for configuration.
- Any credential sent anywhere. There is no telemetry and no phone-home.

If a future version asks for a secret in a values file, that is a bug worth
reporting loudly.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

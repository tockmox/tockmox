---
okf_version: "0.2"
type: HowTo
title: "Skill: guided install"
description: "How an agent walks an operator from prerequisites to a signed-in console, what to ask before each phase, and the checks that catch a failure while it is still cheap."
tags: [agents, skills, installation, deployment, walkthrough, machine]
status: stable
generated:
  by: hand
  at: 2026-09-02
tockmox:
  classification: public
  audience: [machine, operator]
---

# Skill: guided install

**Use this when** an operator is installing Tockmox and wants company through
it. Your job is to keep them on the documented path, ask for the things only
they can supply, and catch a failure at the phase that created it rather than
three phases later.

**The canonical procedure is [install](../../deployment/install.md).** This
skill does not restate it and must not be used in place of it. Read the page for
the phase you are in and work from that page's own success conditions.

## What you are aiming at

An operator who ends with: [the readiness bar](../../deployment/install.md#the-readiness-bar)
satisfied twice, Traefik holding a real address, exactly one default
StorageClass, credentials sealed into their site repository, and a console they
have signed in to.

**Do not restate the bar here.** Three surfaces stated it three different ways
and all three were false on a correct install (TM-0496). This one was the
strictest: it named `site-apps`, which is the operator's OWN content, so an
agent following it would report a working install as not ready.

**Say this at the start, because it prevents an alarmed message later:** when
every layer goes green, nothing will work yet. Tockmox ships no accounts.
[Getting started](../../usage/getting-started.md) is the separate path from a
green ArgoCD to a usable console, and it begins by bootstrapping Authentik.

## Ask these before anything else

Do not proceed on assumptions for any of them, and do not offer a plausible
default for the four values ... a wrong guess is worse than a question.

| Ask | Why it changes what you do |
|---|---|
| Do you have a Kubernetes cluster already, or machines with no cluster | Picks the preparation page: [fresh-install](../../deployment/fresh-install.md) or [existing-cluster](../../deployment/existing-cluster.md) |
| How many nodes | At three or more, the Longhorn replica counts must be raised and soft anti-affinity turned off, in the same change. At one or two the shipped defaults are right |
| Physical or virtual | Virtual means reading [virtual machines](../../deployment/virtual-machines.md) **before** phase 1. Four hypervisor defaults break Tockmox with errors naming the wrong component |
| Will the site repository be private | Decides whether a read-only token and the ArgoCD repository Secret are needed |
| Do you have internet access at the site | If no, switch to the [air-gap preparation](../airgap-prep/SKILL.md) skill first. It is the same install with six things done differently, not a separate procedure |
| Your internal DNS zone, LAN CIDR, and a free address range | Three settings with no defaults, where a wrong guess is worse than a question. Ask; never invent. The installer also wants a `site.name`, but that one only labels generated files and nothing derives from it |
| Where the AI plane should point, if anywhere | Optional, and "nowhere" is the shipped state and a fine answer while evaluating |

## The shape of the walk

Three phases with no branch between them, plus a 2.5 that is easy to skip and
expensive to skip. Confirm each phase's own success condition on the page before
moving on.

1. **Confirm the handoff.** One block of five reads and no writes, on
   [install § confirm the handoff](../../deployment/install.md#confirm-the-handoff-in-one-block).
   If any line disagrees, go back to the preparation page. **Do not continue and
   plan to fix it later**; every one of those failures gets worse three phases
   on and none of them names itself when it does.
2. **Phase 1, generate the site repository.** The installer writes a second
   repository and applies nothing to the cluster. Prefer the config-file route
   over interactive, because only the config file gets the `--dry-run` preflight
   ... and that preflight resolves the Tockmox revision against the remote, which
   is the one wrong value that is accepted by every schema and surfaces three
   phases later as nine layers that cannot find their source.
3. **Phase 2, publish it.** The repository must be reachable **from the
   cluster**, not merely from the operator's workstation. Then replace
   `PLACEHOLDER_SITE_REPO_URL`, matching the URL character for character
   including a trailing `.git`.
4. **Phase 2.5, mint credentials.** Run `mint-secrets.sh` from **inside the site
   repository**; it writes to `./secrets` relative to where it is invoked, not
   where it lives. Naming the kubectl context is not optional and has no
   default. Commit the sealed secrets, and do not apply them yet.
5. **Phase 3, apply.** `kubectl apply -f bootstrap/root.yaml` is the only thing
   applied by hand. Watch the waves. Apply the sealed secrets as soon as the
   policy layer is `Synced`. Then MetalLB gives Traefik a real address, which is
   the one state preparation left open on purpose.

   **`local-path` stays the default StorageClass, and do not tell an operator
   otherwise.** Tockmox names the class on every claim it creates and never
   takes your cluster default; un-defaulting applies only if the operator
   deliberately sets `longhorn.persistence.defaultClass: true`
   ([history](#history-the-default-storageclass-claim)).
6. **After the first sync.** DNS at Traefik's address, in the resolver **the
   cluster uses** as well as the operator's. Then confirm the console's
   model-gateway key was minted (a Job in the AI layer does it since 0.8.0;
   the manual block is the fallback). Then verify what Tockmox authored.

## Where operators actually lose time

Raise each of these before it happens rather than diagnosing it after.

**`kubeseal` and `openssl` are not installed by either preparation page.**
Discovering `kubeseal` missing at Phase 2.5, after the site repository is
already pushed, is the most common avoidable stall. Check for them during the
tools block, before Phase 1.

**Without a container runtime, the ntfy credential is skipped, and until it
exists no alert reaches anybody.** The script says so ... it prints the Secret
under `NOT MINTED` with the reason. What makes it easy to miss is that the run
otherwise succeeds and the operator reads the `MINTED` list and stops. **Read
all three lists back to them**, not just the successful one.

**Sealing against the wrong cluster produces no error you will see.** The
SealedSecret applies cleanly and no `Secret` ever appears. That is why the
success condition for Phase 3c is that the controller produced a real `Secret`
from at least one of them, not that the apply succeeded.

**Two default StorageClasses is not rejected.** Kubernetes picks the most
recently created one, which happens to be the right one, by accident of
timestamp. On k3s the fix needs the `.skip` file on **every server node** or the
next restart undoes it.

**The DNS check that passes while SSO still fails** is querying the
workstation's resolver instead of the cluster's. The token exchange is
server-side.

**A missing repository credential and a wrong URL and a bad revision produce the
same three unhelpful words**, on all nine layers at once. If every layer goes
`Unknown` with a `ComparisonError`, do not debug nine layers ... debug the one
repository reference.

## How you know it worked

Use the page's success conditions, not your own. Two that matter most:

```bash
kubectl -n argocd get applications
kubectl get storageclass
```

[The readiness bar](../../deployment/install.md#the-readiness-bar) prints
nothing, twice, at least three minutes apart; and exactly one class marked
`(default)`, and it is `longhorn`.

**`Synced` alone is not enough.** A layer can apply cleanly and still hold a
workload that never becomes ready ... which on a first install usually means
Phase 2.5 was skipped or incomplete, and the workload is sitting in
`CreateContainerConfigError` naming the Secret it wants.

## What this skill will not do

- **It will not run destructive commands.** Propose, explain, and let the
  operator run them.
- **It will not invent a CIDR, a domain, an address range or a deployment name.**
- **It will not tell the operator the procedure is proven.** The install page's
  own [what is not certified here](../../deployment/install.md#what-is-not-certified-here)
  says it has not been executed start to finish in its current form, and carries
  dated observations from specific earlier runs. Pass that on if they ask.
- **It will not substitute for reading the page.** Route them to the section;
  work from it together.

## If it fails

Switch to the [troubleshoot an install](../troubleshoot-install/SKILL.md) skill.
Most first-install failures are one of six shapes, and
[install § if something fails](../../deployment/install.md#if-something-fails)
maps each to its entry in
[troubleshooting](../../operations/troubleshooting.md).

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

## History and corrections

What this page used to say, and when it changed. Nothing here is needed to follow the page.

<a id="history-the-default-storageclass-claim"></a>

### The default StorageClass claim

This step claimed `local-path` stops being the default until 2026-09-12;
the install page says the opposite twice, and the change was recorded as
breaking. TM-0499 fixed the same sentence in `install.md`'s diagram
text; this was a fifth copy, found by grepping the CLAIM rather than the paths
that card named.

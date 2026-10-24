---
okf_version: "0.2"
type: Reference
title: "Agents reference"
description: "The full text behind AGENTS.md: the reasoning for each sharp edge, the fit-assessment guidance, the directory table and the verification notes."
tags: [agents, grounding, rationale, contributor]
status: stable
generated:
  by: hand
  at: 2026-10-03
tockmox:
  classification: public
  audience: [contributor, machine]
---

# Agents reference

The full text behind [AGENTS.md](../../AGENTS.md), moved here so that file stays short. Where the two differ, AGENTS.md is authoritative.

## Answering "is this for me?"

Most operators reach this repository before they have decided anything, and the
first question is some form of "what is this, and does it fit my situation?" It
is the one question the documentation cannot finish on its own. This repository
knows
Tockmox. You know the operator. Fit lives where the two meet, and that is why
this section exists rather than a page.

**Reason from what you already know about the operator.** Their hardware, their
cluster, what they already run, what their data is allowed to do, how much
operational appetite they have. Say which of those facts drove your conclusion,
so they can correct the ones you got wrong. Ask only for what would materially
change the answer. A fixed questionnaire wastes the context you are holding.

**Do not echo internal addresses, hostnames, repository URLs or other deployment
details back to the operator unless the answer needs them.** They add nothing to
a fit assessment, and if you are running against a hosted model, each one you
repeat travels.
[Working with a coding agent § what leaves your network](../usage/working-with-an-agent.md#what-leaves-your-network)
is the operator-facing half of this; this paragraph is yours.

**Read these, and not more than these:**
[why-tockmox](../why-tockmox.md),
[what you get](../usage/what-you-get.md),
[prerequisites](../deployment/prerequisites.md),
[ROADMAP.md](../../ROADMAP.md) and [SUPPORT.md](../../SUPPORT.md). The last two are not an
appendix. They carry what is thin, what is unproven, and what one maintainer can
actually promise, and an assessment that skips them is not an assessment.

**Name at least one reason not to install.** Every operator has one, and a fit
answer containing none is a brochure. The material is already written: the
prerequisite list, the Kubernetes and GitOps skill the project assumes, the
pre-1.0 values interface, the one-maintainer support boundary, and the "What is
not certified here" section on nearly every page. An operator who cannot argue
with your recommendation cannot trust it either.

**Never state how long an install takes.** Nobody has measured it, this project
included, and a plausible duration is the same class of error as a plausible
CIDR: confident, unfalsifiable at the point of use, and expensive later. Say it
has not been measured.

**Keep the three kinds of claim apart**, per rule 2 above. "The documentation
says", "a dated run measured", and "nothing has tested this" are three different
statements, and this repository separates them on purpose. Do not collapse them
to make an answer read more cleanly.

**Watch for the failure mode this section creates.** An operator whose setup
happens to match Tockmox's assumptions will get a glowing answer, and a glowing
answer is the easiest kind to produce and the least useful kind to receive. If
the fit is genuinely strong, say what evidence makes it strong and say what
would have to be true for it to be wrong.

## The sharp edges

These are the things an agent gets wrong by reasoning from general Kubernetes
knowledge. Every one of them is a case where the obvious answer is confidently
wrong and the failure names something else.

**The values namespace is shared across all nine layers, not nine namespaces.**
One profile file is passed to every layer, so each layer's schema enumerates
every other layer's top-level keys and ignores them. Consequence: **setting a
key on the wrong layer is silent.** Setting a key that exists nowhere is not.
[values contract § keys belonging to another layer](../administration/values-contract.md#3-keys-belonging-to-another-layer--accepted-and-ignored).

**The root of each layer's schema is closed; many blocks inside it are not.**
`capabilities` is closed and enumerates its eight names, so a typo there is
refused. `global` is open by necessity, because vendored charts read keys nobody
here controls ... so `global.internalDomian` passes validation and the install
then derives every hostname from an empty domain. **And `global` is not the only
open block**: `apps` is open on every layer, and each layer leaves its
pass-through dependency blocks open too. Confirm before promising a typo will be
caught:

Confirm with the `jq` command in AGENTS.md under "The sharp edges" before promising a typo will be caught.

Read `global` twice, and read anything else that command prints twice as well.
[values contract § `global` stays open](../administration/values-contract.md#global-stays-open-and-this-is-measured-rather-than-lazy).

**`apps.*` is a tri-state, and unset is not the same as false.** A component you
never mention follows its capability; a component you name means what you said.
Switching a component **on** while its capability is **off** fails the render on
purpose. `apps` is not a closed block either, so a misspelt component name lints
clean, renders clean, and changes nothing.
[capabilities § overriding one component](../administration/capabilities.md#overriding-one-component).

**Every component lands in its layer's namespace, not the namespace its upstream
project conventionally uses.** It is `tockmox-platform`, never `garage` or
`cert-manager`. Addressing a platform service by its upstream-conventional
namespace is a very common wrong guess.
[adding an application § the rules that keep upgrades free](../administration/adding-an-application.md#0-the-rules-that-keep-upgrades-free).

**Lists in Helm values replace, they do not merge.** Adding a blueprint ConfigMap
or any other list entry means restating the shipped entries alongside yours.
Dropping the shipped one is how SSO stops working after a change that looked
additive.

**A `cluster-admin` ClusterRoleBinding is denied by an admission policy, and the
denial names nothing useful.** `deny-privileged-rbac` refuses any binding to
`cluster-admin` not on an allowlist. The symptom arrives later as an unrelated
RBAC error about listing secrets, from a ServiceAccount nobody created. It also
refuses the operator's break-glass binding, including mid-uninstall.
[troubleshooting § cannot list resource "secrets" is forbidden](../operations/troubleshooting.md#cannot-list-resource-secrets-is-forbidden).

**`ArgoCD reports Synced` while workloads wait on Secrets that do not exist.**
Tockmox generates no credentials, and nothing renders them, so nothing can fail
at sync time when they are missing. Every layer goes green and a workload sits
in `CreateContainerConfigError`. This is designed, not broken.
[secrets § ArgoCD reports Synced anyway](../administration/secrets.md#argocd-reports-synced-anyway-and-that-is-designed).

**k3s re-asserts its own `local-path` StorageClass default on restart.** Patching
the annotation is not durable on its own; the `.skip` file is, and it goes in
*after* `local-path` has deployed. Two default StorageClasses is not rejected by
Kubernetes ... it picks by creation timestamp, which means the right one wins by
accident. **A stock install no longer creates that state**: Tockmox names the
class on every claim and does not mark a cluster default, so this applies only
when a site sets `longhorn.persistence.defaultClass: true`.
[storage § if you DO want Longhorn as your cluster default](../administration/storage.md#if-you-do-want-longhorn-as-your-cluster-default).

**A private CA has to be trusted inside the container, not just in the browser.**
SSO token exchange happens server-side from inside Grafana, Open WebUI and the
Argo Workflows server. Local break-glass logins keep working throughout, so
every console reports healthy and only federated users are locked out.
[troubleshooting § SSO login dies at the token step](../operations/troubleshooting.md#sso-login-dies-at-the-token-step-with-a-certificate-verify-failure).

**`git clone` working does not mean ArgoCD can read the repository.** The git
CLI speaks the dumb protocol; ArgoCD's repo-server does not. A static file
server passes a clone and fails every sync. This bites air-gapped sites in
particular.
[air-gapped § serve both git repositories inside the boundary](../deployment/airgap.md#5-serve-both-git-repositories-inside-the-boundary--required).

**The node-side containerd mirror is the primary air-gap mechanism;
`global.imageRegistry` is the fallback.** The values key is a convention that
works only in charts that read it, and `tools/check-airgap.sh` carries
exemptions naming the images it does not reach ... run it to see how many at
the current tree. A node-side containerd mirror covers everything, because it
rewrites below the manifest, and the 2026-08-25 air-gap install ran with the
key empty.
[air-gapped § then point the nodes at your mirror](../deployment/airgap.md#then-point-the-nodes-at-your-mirror--the-primary-mechanism).

**Deleting a namespace can orphan a cluster-scoped admission webhook, and the
orphan then rejects the write that would free the resource.** Webhook
configurations are cluster-scoped; the Services they point at are namespaced.
Delete the webhook configurations first, then clear finalizers. The other order
is a closed loop.
[troubleshooting § an orphaned admission webhook](../operations/troubleshooting.md#an-orphaned-admission-webhook-rejects-the-write-that-would-free-the-resource).

## The repository, by directory

| Path | What is in it |
|---|---|
| `charts/` | Nine layer charts plus `tockmox-common`, the library chart. Each layer's `values.yaml` is the list of component keys, and its `values.schema.json` is the enumerated, attributed key surface |
| `install/` | `tockmox-install.sh`, the site-repository generator, `tockmox.yaml.example`, and `audit-policy.yaml` |
| `bootstrap/` | A README explaining the three hand-installed prerequisites and the bootstrap flow. **`bootstrap/root-applications.yaml` here is a superseded tombstone and says so in its first line ... do not apply it, and do not read it as the bootstrap.** The real bootstrap artefacts are generated by `install/tockmox-install.sh` into the operator's site repository, because they have to reference a git repository only they can create |
| `profiles/` | `minimal.yaml` and `reference.yaml`, named bundles of decisions |
| `ci/` | Values files CI renders against. **`ci/values.yaml` is not a site** ... it is a render fixture, and reasoning about a real deployment from it produces cross-layer answers that do not hold |
| `tools/` | Every gate (`check-*.sh`), the shared `lib/`, and the operator-facing scripts: `mint-secrets.sh`, `mirror-images.sh`, `helm-deps.sh`, `gen-images.sh`, `gen-sbom.sh`, `stamp-docs.sh`. Enumerate rather than trusting a list |
| `tests/` | `executed-docs/`, the harness that runs documented commands verbatim out of a page and asserts on artefacts. Its `INVENTORY.md` is the answer to "what is actually covered?" ... not a build badge |
| `docs/` | The published documentation bundle, CC BY 4.0. OKF v0.2 frontmatter on all but one page; `./tools/check-frontmatter.sh` names the exception, currently `administration/adding-an-application.md` |
| `images.txt` | Every workload image, generated from the charts by `tools/gen-images.sh` so it cannot drift from what deploys |

## Verifying your own work

**Enumerate them; do not work from a list in prose.** A list here is a snapshot
and this repository adds gates:

Two things about the order. **`./tools/helm-deps.sh` runs first or everything
after it fails**, with an error that names the missing chart repositories and
not the fix. And `helm lint charts/*` is worth running before the gates, because
a render failure explains most gate failures downstream of it.

**Many gates have a `--selftest` mode**, which proves the gate still refuses what
it claims to refuse. Run the selftest yourself if you touch one of those gates.

**Do not trust a list here, and do not trust a count here.** Both go stale on the
exact commit least likely to make anyone re-read this paragraph ... the one that
adds a gate. This sentence named six by hand and was years of commits behind by
2026-09-13. No number is given now, deliberately. Ask the tree:

The loop rather than `grep -l -- --selftest tools/*.sh`, and the difference is
not pedantry: the bare grep also lists scripts that merely MENTION the flag
(`mirror-images.sh`, `release-preflight.sh` today), so it over-reports. This
form asks the question actually being asked ... which gates accept it.

**That command is the corrected one.** The version printed here until 2026-09-13
was `grep -l -i 'self.test' tools/*.sh`, which matches `self-test` but NOT
`selftest`, because `.` demands a character between the two words. It returned
**zero files** while thirteen gates had the mode. A paragraph that tells you to
verify rather than trust it, and then hands you a command that finds nothing, is
worse than one that just goes stale: it reads as confirmation.

**`check-doc-claims.sh` is the one to expect.** It asserts countable claims the
documentation makes about this tree, and adding documentation with commands in
it can move a count some other page states. If it goes red, fix the page whose
number is now wrong ... deleting the assertion to get green is the gate working
and being ignored, and the file says so about itself.

Run the whole suite rather than the subset you reasoned was affected. The gates
are cheap and the reasoning is where the mistakes are.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

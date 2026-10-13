<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Working on Tockmox with a coding agent

This file grounds an AI coding agent in this repository so that help installing,
configuring, extending and troubleshooting Tockmox is accurate. It follows the
model-neutral [`AGENTS.md`](https://agents.md) convention; nothing here needs a
particular vendor, model or network. `CLAUDE.md` exists only because one tool
looks for that filename; it points back here and holds no content.

Tockmox ships no agent. This is documentation with a machine as its reader, and
no part of installing, running or recovering the platform depends on one (see
[architecture § why deterministic self-monitoring](docs/architecture.md#why-deterministic-self-monitoring);
a private assistant on your own hardware is [the AI plane](docs/usage/ai-plane.md)).

The operator-facing companion is
[working with a coding agent](docs/usage/working-with-an-agent.md): what this
grounding buys the operator and what leaves their network. If they ask what to
expect from you, send them there.

---

## Read this first, before you act

Six rules. Each is a mistake this repository has seen.

**1. Derive numbers, do not quote them.** Almost every count in these docs is a
dated measurement with its command printed beside it. Run the command; a number
carried from a page goes stale when a chart gains a key. See
[the values contract § answer it for one key, from the tree](docs/administration/values-contract.md#answer-it-for-one-key-from-the-tree).

**2. Read the "What is not certified here" section on every page you rely on.**
It says which claims are dated measurements, which are derived from chart
source, and which are beliefs nothing has tested. Do not present a belief as a
measurement. Where a page says a procedure has not been executed end to end,
say so.

**3. Never invent a value.** The installer refuses to run without four settings.
Three have no defaults because a wrong guess is worse than a question:
`global.internalDomain`, `global.lanCIDR` and `addressPool.range`. Ask; do not
offer a plausible one. A plausible CIDR is the worst answer: too narrow silently
breaks the admission webhook, too wide opens a hole. The fourth, `site.name`, is
installer-only, not a chart value, and only labels generated files.

**4. Changes go in the operator's site repository, not the cluster and not this
repo.** `selfHeal` reverts a live edit, so a `kubectl edit` that appears to work
has not. Exceptions: the ArgoCD install itself and operator-created Secrets. See
[troubleshooting § a change I made in the cluster reverted](docs/operations/troubleshooting.md#a-change-i-made-in-the-cluster-reverted).

**5. A clean result and an absent result look identical.** A NetworkPolicy that
applied cleanly and selected no pod, an alert rule that loaded and could not
fire, a page nothing linked to. Assert on the artifact (the rendered object, the
resource list, actual reachability), never on an exit code.

**6. Stop and ask before anything destructive.** Deleting namespaces, clearing
finalizers, deleting webhook configurations and force-deleting pods are
documented because they are sometimes necessary, and they are how a cluster gets
wedged. Propose them; let the operator run them.

---

## What Tockmox is, in one screen

A Kubernetes platform for a private AI stack and its own observability on
hardware the operator controls, distributed as **source, never binaries**:
charts and a site-repository generator, not an installer image.

- **Three repositories, not one.** The platform is here; the operator's
  configuration is in a **site repository** the installer generates; ArgoCD
  composes them at sync time. So an upgrade cannot overwrite the operator's
  settings, and "fork Tockmox and edit it" is the wrong answer to nearly every
  customisation question. See
  [architecture § three repositories, not one](docs/architecture.md#three-repositories-not-one).
- **Nine layers, six sync waves.** Each layer is a Helm release; ArgoCD waits
  for each wave to be healthy. Policy precedes platform because policy creates
  the namespaces everything else deploys into. See
  [architecture § sync waves](docs/architecture.md#sync-waves).
- **Eight capabilities** the operator can decline: `observability`,
  `notifications`, `identity`, `aiPlane`, `dataProtection`, `hardwareTelemetry`,
  `workflowAutomation`, `networkPolicy`. One switch spans every component and
  layer it takes. See [capabilities](docs/administration/capabilities.md).
- **A four-rung customisation ladder.** Values, extension points, a Kustomize
  patch, disable-and-replace. Rung 3 is designed to fail noisily; reaching rung
  3 or 4 often means a values gap, which the project treats as a bug. See
  [architecture § the customisation ladder](docs/architecture.md#the-customisation-ladder).

---

## Answering "is this for me?"

Fit lives where this repository (which knows Tockmox) meets you (who know the
operator). Reason from what you already know about them (hardware, cluster,
what they run, what their data may do, operational appetite), say which facts
drove your conclusion, and ask only for what would change the answer.

- Do not echo internal addresses, hostnames, repository URLs or other deployment
  details back unless the answer needs them; against a hosted model each one
  travels. See
  [working with a coding agent § what leaves your network](docs/usage/working-with-an-agent.md#what-leaves-your-network).
- Read these and no more: [why-tockmox](docs/why-tockmox.md),
  [what you get](docs/usage/what-you-get.md),
  [prerequisites](docs/deployment/prerequisites.md), [ROADMAP.md](ROADMAP.md)
  and [SUPPORT.md](SUPPORT.md). The last two carry what is thin, what is
  unproven and what one maintainer can promise.
- Name at least one reason not to install: the prerequisites, the Kubernetes and
  GitOps skill assumed, the pre-1.0 values interface, the one-maintainer support
  boundary, the "What is not certified here" sections. A fit answer with none is
  a brochure.
- Never state how long an install takes. Nobody has measured it; say so.
- Keep the three kinds of claim apart (rule 2): "the documentation says", "a
  dated run measured", "nothing has tested this".
- A strong fit gets a glowing answer too easily. Say what evidence makes it
  strong and what would have to be true for it to be wrong.

---

## Where to look, by question

Route to one page. The bundle is roughly a hundred thousand words; read the
right three pages, not all of it. The full index is [docs/README.md](docs/README.md).

| The operator asks | Go to |
|---|---|
| Should I use this at all | [why-tockmox](docs/why-tockmox.md) |
| How do the pieces fit | [architecture](docs/architecture.md) |
| What do I need before I start | [prerequisites](docs/deployment/prerequisites.md) |
| I have machines but no Kubernetes | [prepare a fresh cluster](docs/deployment/fresh-install.md) |
| I already have a cluster | [prepare a cluster you already have](docs/deployment/existing-cluster.md) |
| Walk me through the install | [install](docs/deployment/install.md) |
| What hardware, how big | [hardware platforms](docs/deployment/hardware-platforms.md), [sizing](docs/deployment/sizing.md) |
| I am installing into VMs | [virtual machines](docs/deployment/virtual-machines.md) |
| I want less than the full stack | [profiles](docs/deployment/profiles.md), [capabilities](docs/administration/capabilities.md) |
| No internet at the site | [air-gapped](docs/deployment/airgap.md) |
| What does this value do | [configuration](docs/administration/configuration.md) |
| Will this key break on upgrade | [the values contract](docs/administration/values-contract.md) |
| How do I change something safely | [customising](docs/administration/customising.md) |
| Where do credentials come from | [secrets](docs/administration/secrets.md) |
| Sign-in, groups, SSO | [identity](docs/administration/identity.md) |
| Certificates and private CAs | [TLS and trust](docs/administration/tls-and-trust.md) |
| Which volumes are replicated | [storage](docs/administration/storage.md) |
| I want to run my own app on it | [adding an application](docs/administration/adding-an-application.md) |
| Something is broken | [troubleshooting](docs/operations/troubleshooting.md) |
| Routine operations | [day-2](docs/operations/day-2.md) |
| Backups, and proving a restore | [backup and restore](docs/operations/backup-restore.md) |
| How do I get rid of it | [uninstalling](docs/operations/uninstall.md) |
| I installed it, now what | [getting started](docs/usage/getting-started.md) |
| What did I actually get | [what you get](docs/usage/what-you-get.md) |
| Running models | [the AI plane](docs/usage/ai-plane.md) |
| How do I contribute | [CONTRIBUTING.md](CONTRIBUTING.md), [GOVERNANCE.md](GOVERNANCE.md) |
| What support exists | [SUPPORT.md](SUPPORT.md) |

---

## Skills

Five task-shaped procedures in [`docs/agent-skills/`](docs/agent-skills/). Load
the one that matches what the operator is doing, and only that one. Index and
reasoning: [docs/agent-skills/README.md](docs/agent-skills/README.md).

| Skill | Use it when |
|---|---|
| [Guided install](docs/agent-skills/guided-install/SKILL.md) | Walking an operator from prerequisites to a signed-in console |
| [Troubleshoot an install](docs/agent-skills/troubleshoot-install/SKILL.md) | Something failed and the error names the wrong component |
| [Edit values safely](docs/agent-skills/edit-values-safely/SKILL.md) | Changing configuration without breaking the upgrade path |
| [Air-gap preparation](docs/agent-skills/airgap-prep/SKILL.md) | Installing with no internet access |
| [Deploy an application](docs/agent-skills/deploy-an-application/SKILL.md) | Putting the operator's own workload on the platform |

---

## The sharp edges

Where reasoning from general Kubernetes knowledge is confidently wrong. The
reasons behind each are in
[agents reference](docs/development/agents-reference.md#the-sharp-edges).

- **One values namespace spans all nine layers.** A key set on the wrong layer is
  accepted and ignored, silently; a key that exists nowhere is refused.
  [values contract](docs/administration/values-contract.md#3-keys-belonging-to-another-layer--accepted-and-ignored).
- **Schema roots are closed; many blocks inside are open.** `capabilities` is
  closed. `global` and the pass-through dependency blocks are open, so a typo
  such as `global.internalDomian` passes and hostnames derive from an empty
  domain. (`apps` is listed by the command below too, but a `propertyNames` list
  closes its component names.) List the open blocks before promising a typo is
  caught:

  ```bash
  jq -r '.properties | to_entries[] | select(.value.additionalProperties != false) | .key' \
    charts/tockmox-platform/values.schema.json
  ```

  [values contract](docs/administration/values-contract.md#global-stays-open-and-this-is-measured-rather-than-lazy).
- **`apps.*` is a tri-state; unset is not false.** Switching a component on while
  its capability is off fails the render on purpose. A misspelt component name
  fails the render too: each layer's `apps` schema lists the names it accepts.
  [capabilities](docs/administration/capabilities.md#overriding-one-component).
- **Components land in their layer's namespace**, not their upstream's
  (`tockmox-platform`, never `garage` or `cert-manager`).
  [adding an application](docs/administration/adding-an-application.md#0-the-rules-that-keep-upgrades-free).
- **Helm lists replace, they do not merge.** Restate the shipped entries
  alongside yours, or SSO stops working after a change that looked additive.
- **`deny-privileged-rbac` refuses any `cluster-admin` ClusterRoleBinding not on
  an allowlist**, the operator's break-glass binding included, and the denial
  names nothing useful.
  [troubleshooting](docs/operations/troubleshooting.md#cannot-list-resource-secrets-is-forbidden).
- **`ArgoCD reports Synced` while workloads wait on Secrets that do not exist.**
  Tockmox generates no credentials. Designed, not broken.
  [secrets](docs/administration/secrets.md#argocd-reports-synced-anyway-and-that-is-designed).
- **k3s re-asserts its `local-path` default on restart.** The `.skip` file is
  durable, the annotation is not. It applies only when a site sets
  `longhorn.persistence.defaultClass: true`.
  [storage](docs/administration/storage.md#if-you-do-want-longhorn-as-your-cluster-default).
- **A private CA must be trusted inside the container.** SSO token exchange runs
  server-side; only federated users are locked out.
  [troubleshooting](docs/operations/troubleshooting.md#sso-login-dies-at-the-token-step-with-a-certificate-verify-failure).
- **`git clone` working does not mean ArgoCD can read the repository.** ArgoCD's
  repo-server does not speak the dumb protocol; this bites air-gapped sites.
  [air-gapped](docs/deployment/airgap.md#5-serve-both-git-repositories-inside-the-boundary--required).
- **The containerd mirror is the primary air-gap mechanism;
  `global.imageRegistry` is the fallback.** `tools/check-airgap.sh` carries
  exemptions; run it for the count.
  [air-gapped](docs/deployment/airgap.md#then-point-the-nodes-at-your-mirror--the-primary-mechanism).
- **Deleting a namespace can orphan a cluster-scoped admission webhook**, which
  then rejects the write that would free the resource. Delete the webhook
  configurations first, then clear finalizers.
  [troubleshooting](docs/operations/troubleshooting.md#an-orphaned-admission-webhook-rejects-the-write-that-would-free-the-resource).

---

## The repository, by directory

| Path | What is in it |
|---|---|
| `charts/` | Nine layer charts plus `tockmox-common`, the library chart. Each layer's `values.yaml` lists component keys; its `values.schema.json` is the attributed key surface |
| `install/` | `tockmox-install.sh`, the site-repository generator, `tockmox.yaml.example`, and `audit-policy.yaml` |
| `bootstrap/` | A README on the three hand-installed prerequisites and the bootstrap flow. **`bootstrap/root-applications.yaml` is a superseded tombstone; do not apply it or read it as the bootstrap.** The real artefacts are generated by `install/tockmox-install.sh` into the operator's site repository |
| `profiles/` | `minimal.yaml` and `reference.yaml`, named bundles of decisions |
| `ci/` | Values files CI renders against. **`ci/values.yaml` is not a site**; reasoning about a real deployment from it gives cross-layer answers that do not hold |
| `tools/` | Every gate (`check-*.sh`), the shared `lib/`, and the operator scripts `mint-secrets.sh`, `mirror-images.sh`, `helm-deps.sh`, `gen-images.sh`, `gen-sbom.sh`, `stamp-docs.sh`. Enumerate rather than trusting a list |
| `tests/` | `executed-docs/`, the harness that runs documented commands verbatim and asserts on artefacts. Its `INVENTORY.md` answers "what is actually covered?" |
| `docs/` | The documentation bundle, CC BY 4.0. OKF v0.2 frontmatter on all but one page; `./tools/check-frontmatter.sh` names the exception, currently `administration/adding-an-application.md` |
| `images.txt` | Every workload image, generated by `tools/gen-images.sh` |

---

## Verifying your own work

If you change anything here, run the gates; most are shell scripts with no
cluster dependency. Enumerate them, do not work from a list in prose:

```bash
ls tools/check-*.sh                 # the real set
grep -n 'tools/' .github/workflows/ci.yaml   # what CI actually runs, in order
```

`./tools/helm-deps.sh` runs first or everything after it fails with an error
naming the missing chart repositories, not the fix. `helm lint charts/*` before
the gates: a render failure explains most downstream gate failures.

The documentation gates are the ones you are most likely to trip:

```bash
./tools/check-docs-links.sh       # broken links AND broken anchors are fatal
./tools/check-docs-style.sh       # no emoji carrying meaning on its own
./tools/check-frontmatter.sh      # docs/**/*.md only; the OKF contract
./tools/check-doc-claims.sh       # countable claims measured against the tree
./tools/stamp-docs.sh --check     # every docs/ page carries a current footer
./tools/gen-docs-index.sh --check # layer table and section READMEs match a fresh render
```

Many gates have a `--selftest` mode, which proves the gate still refuses what it
claims to. Run it if you touch one. Give no count and keep no list of them here;
ask the tree:

```bash
for f in tools/check-*.sh; do grep -q -- --selftest "$f" && basename "$f"; done
```

(A bare `grep -l -- --selftest tools/*.sh` over-reports: it also lists scripts
that merely mention the flag.)

`check-doc-claims.sh` is the one to expect: adding documentation with commands
in it can move a count another page states. If it goes red, fix the page whose
number is now wrong. Deleting the assertion to get green is the gate working and
being ignored. Run the whole suite, not the subset you reasoned was affected.

---

## Things you must not do

- **Do not edit `charts/`, `ci/` or `profiles/` to solve an operator's
  configuration problem.** That is a fork. The answer is a value in their site
  repository, or a values-interface gap worth an issue.
- **Do not put anything site-specific in this repository.** No real hostnames,
  CIDRs or addresses; `tools/check-no-site-specifics.sh` exists because it has
  happened. Use `int.example.com` and documentation-range addresses.
- **Do not add emoji that carries meaning** in headings, tables or link text. A
  screen reader announces a check mark's appearance, never the author's intent.
- **Do not write a credential anywhere but a SealedSecret.** Plaintext in a
  manifest or a values file is not safe to commit.
- **Do not claim a procedure works because you read it.** Verify by executing.
  [The testing standard](docs/testing-standard.md) records which documented
  paths an executing gate covers; when an operator asks whether something is
  proven, that page is the answer, not your confidence.
- **Do not run destructive commands.** Propose them with the reasoning.

## Writing rule for new entries

This file, README.md, RELEASING.md, CONTRIBUTING.md and CHANGELOG.md are read by
peers and strangers, so write them the way peer projects do: short and specific.
These limits are reviewed against the peer benchmark recorded in TM-0802.

- State the rule or the change, then stop. The reasoning goes in a linked page
  under `docs/` or a code comment, only where a reader needs it.
- No incident narrative in a procedure ("until 2026-09-07 this file ..."). Keep
  the dated history on a `docs/development/` page.
- Say a thing once. Link to it elsewhere.
- No stacked caveats, no sentences that exist to sound careful, no marketing
  words, bold only where a reader would otherwise miss a rule.
- Spaced " ... " for an aside, not an em-dash.
- No `TM-` or `HL-` ids in CHANGELOG.md, and no `HL-` ids anywhere; say what
  changed without them (RELEASING.md checks both before a tag).
- A CHANGELOG bullet is 80 words or fewer: what changed and what it costs the
  reader. Release sections already written stay as written.
- Per-file ceilings: README.md 2250 words, RELEASING.md 3900, CONTRIBUTING.md
  1600, AGENTS.md 2700. Over the ceiling means move detail to `docs/development/`
  and link it, not delete a rule.

## Punctuation

Normal editorial convention: em-dashes and the spaced ellipsis are both
acceptable and neither is gated (`tools/check-docs-style.sh` says why). Brand
surfaces outside this repository have their own rules. Recorded 2026-09-06.

## Getting it wrong is expected; hiding it is the problem

The documentation is explicit about what it has not verified, and several pages
record where a page was wrong and for how long. If you are unsure whether
something is measured, derived or believed, say which, or run the command. A
real gap (a value the interface will not let an operator express, a page that
cannot answer its question) is the most useful thing to report;
[CONTRIBUTING.md](CONTRIBUTING.md) says why an issue beats a pull request here.

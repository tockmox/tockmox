---
okf_version: "0.2"
type: HowTo
title: "Model lifecycle and the eval gateway"
description: "Why a new model, local or hosted, is unusable until a person approves it twice, why that needs a second gateway rather than an access group, and how to run the eval gateway the chart ships."
tags: [ai-plane, litellm, model-gateway, evaluation, networkpolicy, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-07
tockmox:
  classification: public
  audience: [operator]
---

# Model lifecycle and the eval gateway

Models change faster than anything else on the platform. A model gets a new
revision, a better quantisation appears, the family moves on, and a hosted model
you depend on is retired. Agents need models that behave the same tomorrow as
today, so Tockmox puts every new model through **two approvals** before an agent
can call it.

> **Experimental in 0.8.0, and off by default.** This release ships the values
> keys, the eval gateway, the upstream watcher and its PR opener, and the
> [Tockmox UI](tockmox-ui.md) that generates the approval changes. The eval
> runner that writes verdict records is not part of this release; until it is,
> verdicts are files you write and commit yourself.

## The rules

1. **A new model is unusable until a person approves it, local or hosted.**
2. **First approval, admit it for evaluation.** It goes onto the **eval gateway**
   only, as `<alias>-next`, beside the live `<alias>` it competes for. The
   production gateway, which is what agents and users call, never has it.
3. **Second approval, promote it.** After `modelLifecycle.promotion.requiredPasses`
   passing comparisons against the current model (3 by default), the alias on the
   production gateway moves to it. A failed comparison resets the count.
4. **Nothing changes by itself.** Each approval is a commit to your site repo.

## Why a second gateway

Keeping candidates in the one gateway behind an access group fails open. Measured
on LiteLLM 1.100.3:

- a virtual key with **no** model list, or an **empty** one, can call every
  model the gateway has, including one in an access group it was never given;
- `litellm_settings.default_key_generate_params` applies only when a key is
  minted, so keys made before it stay open, and setting a key's list back to
  empty later reopens it;
- tags do not fence a model from a key either.

What held for every key, the master key included, was the candidate not being in
the production gateway at all. So it is not: a candidate is served by a second,
small LiteLLM, and network policy decides who reaches that one.

## Turning on the eval gateway

```yaml
modelLifecycle:
  evalGateway:
    enabled: true
    allowedClients:                     # NetworkPolicy peers; EMPTY MEANS NOBODY
      - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: evals}}
        podSelector: {matchLabels: {app.kubernetes.io/name: eval-runner}}
    masterkeySecretName: tockmox-litellm-eval   # a Secret you create
    masterkeySecretKey: masterkey
    environmentSecrets: []              # node tokens and provider keys, see below
```

Mint its master key from your site repository with
`tools/mint-secrets.sh --context <yours> --only evalgateway` (or add
`--with-eval-gateway` to a full run). It writes `secrets/litellm-eval.sealed.yaml`,
the Secret `tockmox-litellm-eval` in the AI namespace with key `masterkey`;
commit it with the values change. The eval runner calls the gateway with that
key.

It renders, in the AI namespace:

- **`tockmox-litellm-eval-config`**, a ConfigMap holding every `-next` route
  from [inference nodes](inference-nodes.md), the live route each one is
  compared against, and every hosted catalog entry at stage `candidate`;
- **`tockmox-litellm-eval`**, a one-replica Deployment of the same LiteLLM image
  the production gateway runs, with no database, no admin UI, and no Kubernetes
  service-account token. It serves the master key only; the network policy is
  the fence;
- a Service on port 4000;
- a **NetworkPolicy** that selects only this pod and admits only
  `allowedClients`, on 4000. It applies whether or not the policy layer is on.

The pod carries the label `tockmox.com/isolated: "true"`, and the policy layer's
namespace-wide allows (intra-namespace, from Traefik, the Prometheus scrape)
skip pods with that label. Without that, the namespace-wide allow would admit
every pod in the namespace, because NetworkPolicies add up: no policy can narrow
what another one admits.

**Who belongs in `allowedClients`:** the eval runner, and the evaluation front
end of anyone who grades by hand. Not the general chat front end, and not agent
workloads: anything that can reach the eval gateway can use a candidate.

**Where it may send.** The policy layer's `allow-egress-litellm` selects the
eval gateway as well as the production gateway, so the eval gateway reaches
exactly what the production gateway does: hosted providers through
`aiEgress.litellm.providerAllow`, and your inference nodes through the
`aiEgress.litellm.extraEgress` entries you already wrote for them (in
`site/values/policy.yaml`, one NetworkPolicy egress rule per node, for example
`- to: [{ipBlock: {cidr: 192.0.2.10/32}}]` with
`ports: [{protocol: TCP, port: 11434}]`). Nothing
extra to set. Before 0.8.0's lab rehearsal it had no egress at all, and every
candidate answered "Connection error". Like the UI and the watcher, it reaches
nothing else in its own namespace: the policy layer's intra-namespace egress
allow skips pods labelled `tockmox.com/isolated`.

### Keys the eval gateway needs

It reads keys from the environment, like the production gateway:

- a node endpoint with `auth.secretRef` reads `NODE_KEY_<SECRET>`, as on the
  [inference nodes](inference-nodes.md) page;
- a hosted candidate reads the provider's key from
  `modelLifecycle.frontier.providers.<provider>.keyEnv`, or
  `<PROVIDER>_API_KEY` when that is not set.

List the Secrets holding them under `environmentSecrets`. Every key in each
Secret becomes an environment variable.

## The catalog

One entry per model, under `modelLifecycle.catalog`:

```yaml
modelLifecycle:
  catalog:
    - id: example-27b
      model: mlx-community/Example-27B-4bit     # the id the gateway routes use
      source: {kind: huggingface, ref: mlx-community/Example-27B-4bit, revision: <commit sha>}
      adopted: "2026-10-07"                     # already in service when catalogued
    - id: hosted-new
      model: anthropic/example-model-9
      stage: candidate
      source: {kind: hosted, ref: anthropic/example-model-9}
```

- **`stage`** is `candidate` (admitted, on the eval gateway only), `promoted`,
  or `retired`. Absent means `promoted`.
- **`adopted`** is how a model that was already serving enters the catalog,
  written once. Every later change to its alias goes through an evaluation.
- **`source.kind`** is `huggingface`, `ollama` or `hosted`. A `hosted` entry's
  `ref` is `provider/model`; the chart refuses a hosted candidate without both
  halves.
- **`track`** is what the [watcher](#the-watcher) looks upstream for, a list
  of `revision` (a new commit of the pinned `source.revision`; Ollama: a new
  digest), `quants` (another quantisation of `baseModel` from a trusted
  publisher), `successors` (a newer model of the same family and size) and
  `deprecation` (a hosted model's retirement date). **An entry with no
  `track` is not watched**: the report lists it as a gap, and the UI shows it
  under "Not watched". The schema refuses any other value, as the UI does.
- **`baseModel`** is the Hugging Face repo a quantisation is a quantisation of,
  for example `Qwen/Qwen3.8-27B` for `mlx-community/Qwen3.8-27B-4bit`. `quants`
  needs it: without it the watcher has nothing to search for and reports the
  entry as a gap rather than as current. `successors` reads the family and
  size from it when it is set, and from `model` when it is not.
- **`family`**, **`quant`** and **`sizeGiB`** are optional descriptions the UI
  shows and sizes placements with.

A catalog entry the watcher can act on looks like this:

```yaml
    - id: example-27b
      model: mlx-community/Example-27B-4bit
      baseModel: example-org/Example-27B
      quant: 4bit
      source: {kind: huggingface, ref: mlx-community/Example-27B-4bit, revision: <commit sha>}
      track: [revision, quants, successors]
      adopted: "2026-10-07"
```

**A hosted candidate is served untagged.** Data-class tags on the production
gateway decide which requests may leave the site, and choosing them is part of
promoting the model. A promoted hosted model is an ordinary hand-written entry in
`litellm.proxy_config.model_list`, with the tags you chose.

## Promoting

Promotion is a single commit that does three things together:

- moves the live alias, for a node route by pointing `<alias>` at the
  candidate's model, for a hosted model by adding its production entry;
- removes `<alias>-next`, which takes the candidate off the eval gateway;
- marks the catalog entry `promoted` and retires the old model if nothing else
  uses it.

Because the routes change, the commit also updates the
`tockmox.com/node-routes` annotation, which rolls the production gateway
([inference nodes](inference-nodes.md), "The two rolling annotations").

`promotion.requiredPasses` (default 3) and the optional
`promotion.requiredPassesByClass`, a per-workload-class override, are read by the
tools that check the evaluation record. **The chart does not enforce them in
this release**: a commit that moves an alias renders whether or not the
comparisons happened. Until those tools ship, the bar is a review rule for
whoever merges the commit.

## Moving an existing gateway over

If the production gateway already serves `-next` comparison routes to everyone,
turning this on moves them to the eval gateway. Anyone who was testing a
candidate through the production gateway needs a front end listed in
`allowedClients` instead.

Check every virtual key on the production gateway while you are there. A key
with an empty or missing model list can call every model the gateway serves, and
the eval gateway does not change that for the models that stay in production.

New keys can be given a default list, as defense in depth rather than a fence.
LiteLLM applies it only when a key is minted, so keys that already exist keep
what they have, and a key later updated to an empty list reaches everything
again (measured on LiteLLM 1.100.3). With `inferenceNodes.render` on, the chart
writes it for you and checks it:

```yaml
modelLifecycle:
  productionKeys:
    defaultModels: [local-chat]       # what a key minted without a list may call
```

The render refuses an empty list and `all-proxy-models` (both mean every model),
a name that is not a model or access group on the production gateway (so a
`-next` candidate cannot be named), and the same setting written by hand in
`litellm.proxy_config` as well. It changes the gateway config, so the
`tockmox.com/gateway-config` annotation changes too; the render prints the
value.

## The watcher

The watcher is the one part of Tockmox that reaches the internet on its own. It
reads Hugging Face, the Ollama registry, OpenRouter, and the Anthropic and
OpenAI model lists for what is newer than your catalog, writes a report, and
changes nothing. With `pullRequests` on, its PR opener turns the report into
**one pull request at a time** on your site repo: an admit PR for a new
candidate, and a promotion PR once the verdict records reach
`promotion.requiredPasses`. Merging the admit PR is the first approval; merging
the promotion PR is the second.

It runs in the Tockmox UI image, which you build ([the Tockmox UI](tockmox-ui.md)):

```yaml
modelLifecycle:
  watch:
    enabled: true
    image: registry.example.com/tockmox/tockmox-ui:0.8.0
    schedule: "17 6 * * *"
    providers:
      openrouter: {allow: ["anthropic/*", "openai/*"]}
    pullRequests:
      enabled: true
      forge: github                       # or forgejo (with secrets.forgeToken)
      repo: you/your-site-repo
      valuesPath: site/values/models.yaml # a file holding only modelLifecycle and inferenceNodes
      githubApp: {appId: 123456}          # its key in the Secret secrets.githubAppKey (key private-key.pem)
```

It renders one CronJob with **no Kubernetes credentials** and a NetworkPolicy of
its own: no ingress at all; egress to DNS, and to HTTPS on the internet with
every private, shared, link-local and loopback range excepted, so it reaches the
upstream hosts and GitHub but not the cluster, your LAN or a cloud metadata
address. That includes its own namespace: the pod carries
`tockmox.com/isolated`, and the policy layer's intra-namespace egress allow skips
it (in 0.8.0's lab rehearsal, before that exclusion, the watcher's pod answered
200 from the model gateway). NetworkPolicy cannot name hosts; the watcher's own host allowlist
narrows it further. An in-cluster forge such as Forgejo goes under
`modelLifecycle.watch.egress.extra`. The report lands on a small volume the UI
mounts read-only.

The render refuses the watcher with no image, pull requests to GitHub with
neither an App nor a token, and pull requests to Forgejo with no token Secret.
Leave it off on an air-gapped site.

## The build on the node

Git holds the build each model is pinned to (`source.revision`); the node holds
the one it actually serves, and nothing stops someone pulling a different one
by hand. The UI's `/models` page compares the two, under "Builds on the
nodes", for every catalogued Ollama or Hugging Face model with a pinned
revision that a route serves:

| Engine | What the node reports | Read from |
|---|---|---|
| Ollama | the model's manifest digest, which equals the registry's `ollama-content-digest` the watcher pins | `GET /api/tags` |
| llama-server | the Hugging Face commit in its model path, when the model was loaded from a Hugging Face cache (`.../snapshots/<commit>/...`) | `GET /props` and `GET /v1/models` |
| mlx-lm, vLLM, the others | nothing: they do not report which build they loaded | not asked |

A route that holds the pinned build reads **Holds the pinned build**; a
different one is **Drift**, listed as a finding at the top of the section, with
the node's build and the pin. Anything the UI cannot tell reads **Unknown** with
the reason (the node was not asked yet, did not list the model, listed it
without a digest, runs an engine that reports no build, or refused the
request), never current. A short pin (seven or more hex characters) matches the
full digest it starts.

Reading a node is a request to it, so it rides the probe's fences
([inference nodes](inference-nodes.md)): nothing is read with
`inferenceNodes.probe.allowedCidrs` empty, and only an address inside that range
is asked, over fixed GET paths, following no redirect. The check runs when an
admin presses "Check the nodes now"; a page load never reaches a node. The
result lives in the UI's memory, and a check older than an hour reads Unknown
again. The watcher does not make this comparison: its policy keeps it off the
LAN by design.

## What it does not do

The chart does not update models, pull weights onto nodes, or run evaluations;
it counts their results only through the UI and the PR opener. It renders the gateways your values describe, and refuses
the configurations listed on the [inference nodes](inference-nodes.md) page.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: HowTo
title: "Model lifecycle and the eval gateway"
description: "Why a new model, local or hosted, is unusable until a person approves it twice, why that needs a second gateway rather than an access group, how to run the eval gateway the chart ships, and how the UI recommends candidates, sizes them and records the evidence."
tags: [ai-plane, litellm, model-gateway, evaluation, networkpolicy, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-21
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

Tockmox does not pick your models. It proposes candidates, shows the arithmetic
for whether each fits the node, and makes the evaluation and the change easy to
review. What runs in production is the result of two approvals that a person
gives, on evidence the evaluation produced.

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
   independent passing comparisons against the current model (1 by default), the
   alias on the production gateway moves to it. A failed comparison resets the
   count. A candidate that fails is **rejected**, which is a commit too.
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
  `retired`, or `rejected` (a build that failed its evaluation or was reverted,
  with `rejection: {reason, date}`: nothing may route it, on either gateway, and
  the watcher offers the model again only at another revision). Absent means
  `promoted`.
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
- marks the catalog entry `promoted` and records the comparisons that justified
  it (see "Three kinds of change" for what happens to the old model).

Because the routes change, the commit also updates the
`tockmox.com/node-routes` annotation, which rolls the production gateway
([inference nodes](inference-nodes.md), "The two rolling annotations").

`promotion.requiredPasses` (default 1) and the optional
`promotion.requiredPassesByClass`, a per-workload-class override, are read by the
tools that check the evaluation record. **They count independent evidence**: a
passing verdict counts once per evidence key (the candidate's revision, the eval
set and its sha256, the sampling settings, the engine and the node), so three
reruns of one frozen set count once. Repetition inside a run is the eval set's
`epochs`. To require more than one, vary something real: a second set version, a
second seed regime, a second node. **The chart does not enforce them in
this release**: a commit that moves an alias renders whether or not the
comparisons happened. The UI refuses to start on values where an alias moved
without them, and `python -m app.verdict_check` (see "Evidence") checks the
files in CI. Without those checks, the bar is a review rule for whoever merges
the commit.

### Three kinds of change

The Models page and the PR opener handle three cases. They differ in what the
alias is compared against and in what happens to the old model.

| Case | Made by | Compared against | Class and passes | The old model |
|---|---|---|---|---|
| **A different model replaces the incumbent** | admitting a candidate, or Recommend | the model the alias serves now | the class you name; `requiredPasses` (1) unless the class has its own number | retired when no other alias routes it; kept, with a note, when one does. The route it had is recorded as `promotion.previous`, for a revert |
| **A brand-new alias, no incumbent** | Recommend, for a class with no live alias | nothing: absolute bars | the class you name; `requiredPasses` | there is none |
| **The same model on another node** (a re-placement) | Recommend, for a model already serving the alias elsewhere | the same model where it runs now | class `perf`; 1 pass by default | **never retired**: it is the model the new route serves |

**A brand-new alias.** `local-agent-next` is the only route, on the eval gateway,
and no `local-agent` exists until the promotion creates it. With no incumbent
there is no "not worse than" clause. The eval runner judges the candidate on
absolute bars: the smoke test passes (finish reason `stop`, one tool call
parses, one JSON response, streaming usage, a verbatim canary), the fit is
`fits` with a measured peak inside usable memory and no swap growth, the
gateway-plane latency bars hold (p95 first token within 5 s, p95 complete answer
within 60 s at the alias's observed concurrency), and the class's own criterion
where it has one. Only verdicts that name no incumbent count toward the
promotion; a comparison against some other model does not.

**A re-placement.** Moving the model an alias serves from one node to another
changes where the alias runs, not what answers. The change is `<alias>-next` on
the new node, the live route untouched. A re-placement's verdicts are class
`perf`, must carry `placement: {from_node, to_node}` naming the very move, and
need 1 passing comparison by default. A `perf` verdict for one move says nothing
about another, so a verdict that names a different move, or none, does not
count. Promotion repoints the alias, records `promotion.placement` (from and to,
node and endpoint) on the catalog entry, and **does not retire the model**: the
entry stays `promoted`, and the note lists any alias that still routes the model
on the old node so its files are left there.

The default of 1 applies only to a re-placement. A `perf` verdict is not a
quality verdict, so it never moves an alias to a different model: that still
needs `requiredPasses`. An operator's own `requiredPassesByClass.perf` always
wins over the default, in either direction.

The gate (`check_promotions`) accepts a re-placement record when it names a move
between two different places and the place it moved to is where the alias routes
now. A record that no longer matches the route (the alias moved again without a
new evaluation) is a gate failure.

### Reject and revert

Both are commits you review, like every other change here, and nothing reverts
on its own. In this release the alias page of the Tockmox UI
(`/models/a/<alias>`) renders the revert change for you to review and commit,
and each comparison has its own page (`/models/v/<run>`). A reject button, the
PR opener's reject and revert lanes and the production health watch that would
propose a revert are not built yet; reject is a function in `app/models.py`.

| Change | When | What it does |
|---|---|---|
| **Reject** (`models.reject`) | the evidence says Worse, the known-bad control kept passing, or you dismiss the candidate | removes `<alias>-next`, so the node frees the memory; marks the entry `rejected` with the reason, the date and the revision |
| **Revert** (`models.revert`) | a promoted build misbehaves in production | points `<alias>` back at `promotion.previous`, the route it had before (node, endpoint, params, model info); marks the demoted build `rejected` with the reason; promotes the previous model again |

A revert of a promotion made before `promotion.previous` was recorded, or of a
brand-new alias, is refused by name: route the alias by hand through the change
it needs. If the promotion marked the old model `retired` and its files have
since left the node, put them back before the revert merges; the change says so.
An Inconclusive result opens nothing: it asks for more evidence.

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

### What the watcher reads for fit

The watcher also reads what the UI needs to say whether a model fits a node. The
UI has no internet access, so this is the only place those numbers can come
from. For every catalogued Hugging Face model, every Hugging Face candidate in
the report and every model named under `modelLifecycle.recommend.seeds`, at most
`modelLifecycle.watch.sizes.maxRepos` (default 80) per run:

- `GET /api/models/<repo>/revision/<sha>?blobs=true`, the file sizes at the
  pinned revision (a repo with no pinned revision is read at its current build,
  and the report records which commit that was);
- `GET /<repo>/resolve/<sha>/config.json`, for the layer count, the key-value
  heads and head size, and the expert count.

It writes them to the report's `sizes` section: weights bytes, files counted,
the cache bytes per token, any fixed per-sequence state, the weights format, the
licence, and the model card's self-reported results. A repo it could not size (a gated repo needs a token the watcher
does not hold) is
listed under `sizeGaps` with the reason, and the figure is left out, never
written as zero. A sizing gap does not turn the report amber: the model is still
watched.

It uses the same client as the rest of the watcher: the fixed host list, GET and
HEAD only, no credential sent, every answer size-capped. It follows no redirect,
with one named exception: Hugging Face answers `resolve/<sha>/config.json` with
a 307 to `/api/resolve-cache/...` on the same host, and the watcher follows that
one hop, only to an `https` URL on the host it asked, under that path. A redirect
to any other host, a CDN included, is a gap. Setting `watch.sizes.enabled` to `false`
turns the duty off.

For GGUF repos with several quantisations the watcher sizes only the one the
catalog entry's `quant` names, and sizes nothing when it names none: the sum of
every quantisation is not a file anyone loads.

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

## Evidence: result twins, verdicts and the hashes CI recomputes

An evaluation leaves two kinds of file in the site repo, both written by the eval
runner and read by the UI and by CI through one module (`app/results.py` and
`app/models.py`), so the three can never disagree about what a result is.

**A result twin** (`capability-result/1`, under `evals/results/<node>/`) is one
measurement leg. It records the date, the node, the model id, revision and
quantisation, the engine and its version, the plane it was measured on (`engine`
for the engine alone, `gateway` for the path through LiteLLM, which then names its
route), the workload class, the metrics (each a name, value, unit and sample count,
optionally with a concurrency), the peak resident memory and the context and
slots it was measured at, tokens per joule when power was read, the versions of
everything it ran on (macOS, chip, memory, wired limit), and a pointer to the
methodology file. A number with no method beside it is not a result, so the pointer
is required and must stay under `evals/`. A twin is written once and never
edited: a re-measurement is a new dated file. The reader refuses what it could
misread: a non-finite number, a missing unit, a missing engine version (a result
without one cannot be told stale), a gateway leg that names no route, a file over
1 MiB.

**A comparative verdict** (`comparative-verdict/1`, under `evals/verdicts/`) is one
run's decision. Its `results` list is `[{path, sha256}]`: the twins the verdict
rests on, each with the hash of the file as it was when the verdict was written.
The first form of the schema listed bare paths, which hashed nothing, so an
edited twin could not be seen. That form is still accepted for one release, with a
warning; new evidence must use the hashed form.

CI recomputes every hash:

```
python -m app.verdict_check SITE_VALUES.yaml SITE_REPO_ROOT
```

For every verdict file a promotion cites, and for every other verdict file under
`modelLifecycle.verdictsRepoPath` (cited yet or not, since an edit before the
promotion PR is the cheap time to catch it), it checks that each twin exists in
the repo, hashes to the recorded `sha256`, parses as a `capability-result/1`, and
is about the candidate or the incumbent. A twin edited after the verdict, a twin
missing, and a hash nobody computed each fail the check. A path that leaves the
repo, symlinks included, is refused rather than hashed. The command prints
warnings for bare-path entries and exits 1 on any problem.

### Evidence pull requests

The PR opener has a third kind besides admit and promote. `python -m
app.pr_opener evidence CONFIG.yaml DIR [--apply]` takes a directory laid out like
the repo (`evals/results/...`, `evals/verdicts/...`) and opens one pull request
that **adds** those files. It is deliberately narrow:

- it only adds: a file that already exists with different contents is refused
  (identical contents are skipped), and every file is created with a `PUT` that
  carries no `sha`, so an existing path cannot be overwritten even if it appeared
  after the plan was made;
- every path must be a plain relative path under `evals/` ending `.json` or
  `.md`; anything else, including `..`, an absolute path, and the values file, is
  refused, and so is a symlink in the directory;
- a file over 1 MiB, more than 200 files, or more than 8 MiB in total is refused;
- a verdict must be named `<run_id>.json`, must use the hashed `results` form, and
  every twin it cites must be in the same PR or already in the repo with that
  hash; a twin must sit at the path its own fields give it;
- it never reads or writes `site/values/models.yaml`, and it does not wait on or
  block an admit or promote PR: they touch different files, so the one-PR-at-a-time
  lane belongs to the values file alone.

Without `--apply` it prints what it would open and writes nothing.

## Fit, with the arithmetic shown

The first version of the fit check compared weights, estimated from the model
name, to a fraction of the node's memory. Fit v2 (`app/fit.py`) plans what a
route will actually occupy, and shows the sum:

```
total = (weights + KV cache + fixed state) x (1 + engine overhead)
KV cache = (KV bytes per token x context + sliding-window cap) x slots
```

- **Weights** are the exact bytes of the weight files at the pinned revision, from
  the watcher's `sizes`.
- **KV bytes per token** is `2 x full-attention layers x KV heads x head dimension
  x 2 bytes` (an f16 or bf16 cache), read from `config.json`. Only layers whose
  cache grows with context are counted. A hybrid model with a few full-attention
  layers among linear-attention or state-space ones costs a fraction of a dense
  model's cache at long context; a sliding-window layer is capped at its window;
  multi-head latent attention caches the latent, not the heads. Recurrent layers
  add a fixed per-sequence state.
- **Context and slots** are per route: an Ollama route's `num_ctx`, or the route's
  `modelInfo.max_input_tokens`, times the slots the class needs.
- **Engine overhead** is a constant 10% of weights plus cache (activation, compile
  and allocator buffers). Calibrate it per engine with
  `modelLifecycle.recommend.nodes.<id>.overhead`.
- **Usable memory** is the node's measured wired limit when one is known (read from
  the newest result twin that recorded `environment.wired_limit_mb`, or from live
  metrics), else a figure you set (`wiredLimitGiB`), else the node type's planning
  fraction (75% of a Mac's unified memory).

Every figure carries its provenance, best first: **measured** (a result twin's
peak resident memory, used only for a plan that asks for no more context and slots
than the measurement used), **exact** (file sizes and `config.json`), **estimate**
(from the model name). The state is `fits`, `tight` (above 85% of usable, or above
70% when the cache could not be sized), `over`, or `unknown`, and it is judged
beside what is already routed on the node, with the whole sum written out. A model
whose size is not known is `unknown`, never `fits`.

The arithmetic is a plan, not a guarantee. Quantised caches (`-ctk q8_0`,
`--kv-bits`) are smaller than the f16 assumption, and prompt-processing buffers
vary by engine; the measured peak from an evaluation replaces the plan when it
exists.

## Recommend for a node

`/models/recommend?node=<id>` (admin only; linked from the Models page) lists, for
each alias class, a shortlist of three or four candidates worth evaluating on that
node. It is a hypothesis generator. It never admits anything and writes nothing:
**Admit for evaluation** renders the same change the Models page renders for a
candidate, to review, download and commit, and the model then goes through both
approvals like any other.

- **Where candidates come from.** Catalog entries that are not retired, the
  watcher's quant and successor candidates, and the models you name under
  `modelLifecycle.recommend.seeds`. There is no open-ended discovery: a model that
  no one named is not on the list.
- **Classes.** `router`, `fast`, `classify`, `agent`, `medium`, `large`, `embed`
  and `rerank` by default, each with a context, a slot count and a size band in
  billions of parameters (for example `agent`: 64k tokens x 4 slots, 14 to 70B). A
  class maps to the live alias named `<class>` or ending `-<class>`; with none, a
  model admitted there becomes a new alias judged on absolute bars.
- **Ranking.** Licence-compliant models first, then fit (`fits`, `tight`,
  `unknown`, `over`), then predicted decode speed, then the smaller model.
  Predicted single-stream decode is `bandwidth x eta / bytes read per token`, with
  eta 0.70 for a dense model and 0.35 for a mixture of experts, and bandwidth from
  the node's chip (published peak figures; override with `bandwidthGBps`). An
  MoE model reads only its active experts, so it needs an active-parameter figure
  (from the name, as in `80B-A3B`); without one it gets no prediction rather than
  a wrong one. The prediction ignores cache reads, so it is optimistic at long
  context. It is a prior to rank by and is labelled predicted on the page.
- **Flags.** A licence that is not on the allow list (`apache-2.0` and `mit` by
  default), unknown, or admitted by a site exception; known issues, as data you can
  edit (the default list carries one: 4-bit mixture-of-experts models have drifted
  on tool calls under mlx-lm, for the `agent` class); a gated repo; a mixture of
  experts; a format the node's engines cannot load. Public benchmark figures, and
  the self-reported results on a model card, are shown as **hints**, labelled as
  such: they say something about a model in general, not about your workload on
  your node.
- **What a button does.** For a class with a live alias and a different model, a
  `-next` comparison against it. For a class with no live alias, a brand-new alias
  on absolute bars. For the model already serving the alias on another node, a
  re-placement. Each sets the route's context limit for the class on the target
  engine. A model whose licence is outside the allow list, whose revision is not
  pinned, that does not fit, or that no endpoint on the node can load has no
  button, and the row says why. The action is taken from the server's own list when
  the button is pressed, never from the form.

```yaml
modelLifecycle:
  resultsDir: /evals/results            # a mount of the site's evals/results, for measured peaks
  recommend:
    shortlistSize: 4
    licenceAllow: [apache-2.0, mit]
    licenceExceptions:                  # a decision on record: a model, and why
      - model: example-org/Example-Next
        reason: legal reviewed the weights licence on 2026-10-01
    seeds:
      - {ref: example-org/Example-32B, revision: <commit sha>}
    classes:
      agent: {context: 131072}          # a partial override keeps the rest
      rerank: null                      # null removes a default class
    knownIssues:                        # replaces the default list; [] empties it
      - id: example-issue
        severity: warn                  # warn | hint
        match: {model: "(?i)example", quantBitsMax: 4, engine: mlx-lm, moe: true, classes: [agent]}
        text: what to watch for, and where it was reported
    benchmarkHints:
      - {match: "Example", text: "ranks well on a public leaderboard", source: example.com/board}
    nodes:
      alpha: {bandwidthGBps: 800, wiredLimitGiB: 200, overhead: {mlx-lm: 0.12}}
```

A misspelt key, an exception with no reason and a bad pattern are refused with the
key named. A licence exception belongs to the site: no model is excepted by
default, and none is written into the code.

## What is not certified here

The Recommend list and the fit figures narrow the field. They do not certify
anything.

- A shortlist is not a quality ranking. Fit and predicted speed say whether a
  model could run on the node and roughly how fast, not whether it is good at your
  work. That is what the evaluation measures, and it is the only thing that moves
  an alias.
- A predicted speed is a prior from memory bandwidth, not a benchmark, and a fit
  is a plan from file sizes and a config file, not a measurement. Where a figure is
  an estimate, the page says so.
- Public benchmark figures and model-card results are self-reported hints.
- The known-issue list is a short, editable set of reports, not a safety review. An
  empty flag column is not a clean bill.
- A licence check compares one id to an allow list. It is not legal advice; a
  site exception records a decision a person made.
- The watcher reads Hugging Face as it is at that moment. A model card or a config
  can change; the pinned revision is what is read, and what a node must pull.

## What it does not do

The chart does not update models, pull weights onto nodes, or run evaluations;
it counts their results only through the UI and the PR opener. Tockmox does not
pick your models: it proposes candidates, and makes the evaluation and the change
easy to review. It renders the gateways your values describe, and refuses
the configurations listed on the [inference nodes](inference-nodes.md) page.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

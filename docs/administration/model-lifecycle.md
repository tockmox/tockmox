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
  `promoted`. A hosted generation that left the list carries
  `retirement: {reason, date}`.
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

**A hosted candidate is tagged `open` on the eval gateway, and nothing more.**
The eval gateway filters by tag, so only public eval data reaches it (see "The
data-class rails" below). Data-class tags on the production gateway decide which
requests may leave the site, and choosing them is part of promoting the model. A promoted hosted model is an ordinary hand-written entry in
`litellm.proxy_config.model_list`, with the tags you chose.

### Keeping several frontier generations

A hosted model costs nothing until it is called, so a family can keep more than
one generation on the production gateway. Each generation has its own pinned
alias, and the family has one floating alias:

- **A generation alias is pinned.** `claude-sonnet-5-5` is the model name with
  the provider dropped, and it always serves `anthropic/claude-sonnet-5-5`. It
  never moves. An agent you tuned against that generation calls it by name and
  is never changed underneath.
- **The family alias floats.** `claude-sonnet` follows the current generation.
  Only a promotion moves it. Callers that use the family alias get the newer
  model when you merge that promotion, and not before.
- **`keepGenerations` says how many.** `modelLifecycle.frontier.keepGenerations`
  is a whole number of 1 or more, and defaults to 3. It counts the pinned
  generations of one family. The schema refuses 0.

```yaml
modelLifecycle:
  frontier:
    keepGenerations: 3
```

Promote a hosted candidate under its family alias (the Models page offers it
by default). The change it renders adds the pinned alias, points the family
alias at the same model, and leaves every other entry as it is. The family
alias is the only existing entry whose model changes. The family is the model
name without the provider or the version: `claude-sonnet-5-5` and
`claude-sonnet-4-5` are `claude-sonnet`, `gpt-5.1` is `gpt`, and
`gemini-2.5-pro` is `gemini-pro`. A name this cannot read is its own family and
is promoted as a single alias.

A generation leaves in one of two ways, and both are a change you review and
commit. Nothing is removed on its own:

1. **Its provider retires it.** The watcher's countdown shows on the Inbox row
   and on the alias page. Both offer the retire change, which removes the pinned
   entry and marks the catalog entry `retired` with the reason and the date.
   The UI refuses to retire the generation the family alias points at, because
   that would leave the family alias calling a model that is gone. It says which
   generation to promote first.
2. **It falls off the list.** When a promotion would leave the family with more
   than `keepGenerations` pinned generations, the same change also removes the
   oldest one (by the version in its name, never the one being promoted) and
   marks its catalog entry `retired` with the reason `fell off keepGenerations`
   and the date. The change says so in its notes.

The UI cannot see who calls a generation by name. Before you merge a change
that removes one, move the callers pinned to it to a newer generation, or their
requests will fail.

Price and spend per generation are not shown yet; the alias page says "not
recorded yet" rather than estimating.

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
on its own. The alias page of the Tockmox UI (`/models/a/<alias>`) renders the
revert change, and each comparison page (`/models/v/<run>`) has a **Reject**
button for a Fail, Worse or Tradeoff verdict: it asks for a reason, renders
`models.reject`'s change and writes nothing. The PR opener has a lane for each
(`python -m app.pr_opener reject CONFIG ALIAS-next --reason WHY [--apply]` and
`revert CONFIG ALIAS --reason WHY [--apply]`): the same lane as admit and
promote, so only one model-lifecycle PR is open at a time, and a refusal is
`models.reject`'s or `models.revert`'s own sentence. The production health watch
([below](#watching-a-promoted-model)) proposes the revert when a promoted build
does worse than what it replaced.

| Change | When | What it does |
|---|---|---|
| **Reject** (`models.reject`) | the evidence says Worse, the known-bad control kept passing, or you dismiss the candidate | removes `<alias>-next`, so the node frees the memory; marks the entry `rejected` with the reason, the date and the revision |
| **Revert** (`models.revert`) | a promoted build misbehaves in production | points `<alias>` back at `promotion.previous`, the route it had before (node, endpoint, params, model info); marks the demoted build `rejected` with the reason; promotes the previous model again |

A revert of a promotion made before `promotion.previous` was recorded, or of a
brand-new alias, is refused by name: route the alias by hand through the change
it needs. If the promotion marked the old model `retired` and its files have
since left the node, put them back before the revert merges; the change says so.
An Inconclusive result opens nothing: it asks for more evidence.

### Watching a promoted model

A promotion is judged on an evaluation, and an evaluation is a sample. The health
watch (off by default) looks at the real traffic afterwards. Every 15 minutes a
small CronJob in the Tockmox UI image reads Prometheus and compares each promoted
alias with what it served before its promotion (`promotion.previous`). A breach
renders the revert change above as a pull request through the same bot as the
admit and promote PRs, and sends an ntfy message. It reverts nothing itself and
merges nothing.

```yaml
modelLifecycle:
  healthWatch:
    enabled: true
    # image: defaults to tockmoxUi.image, the same build
    soakDays: 14
    rules:
      errorRateRatio: 2.0          # the error rate above 2x the baseline ...
      p95Ratio: 1.5                # ... or p95 latency above 1.5x ...
      toolParseFailureRatio: 2.0   # ... or tool-call parse failures above 2x
      minRequests: 50
      forMinutes: 30               # ... held for 30 minutes
      likeHours: true
    pullRequests: true             # the revert PR, with watch.pullRequests and watch.secrets
    notify:
      ntfyUrl: http://tockmox-ntfy.tockmox-monitoring.svc
      topicSecret: tockmox-health-watch-ntfy   # optional keys: token, topic (default topic: alerts)
    autoRevert: {}                 # {<alias>: true}; off for every alias
```

**What it reads.** The gateway's own metrics, for the alias as callers name it
(`requested_model`): the non-2xx share of
`litellm_proxy_total_requests_metric_total` and the 95th percentile of
`litellm_request_total_latency_metric_bucket`. These are the series the alert pack
already uses, so the gateway needs its `prometheus` callback and a scrape. Because
the alias is the history, the previous model's behaviour is simply the alias
before the promotion; there is no per-model series to join. When
`promotion.promotedAt` is not recorded (nothing writes it yet), the promotion time
is the first hour in which the `model` label on the alias's latency histogram names
the promoted model.

**Two signals are not judged yet, and the status says so rather than skipping them
silently.** Tool-call parse failures need a counter at the gateway hook, and none
exists: the policy gate exports only its decisions and its audit failures. A site
that adds a hook counter of tool-call responses with unparseable arguments, and one
of tool-using responses, both labelled `requested_model`, names them in
`rules.toolParseMetrics` and they are judged like the error rate. Thumbs are not
exposed by the console to Prometheus. Both show as `unknown` and neither passes nor
fails an alias.

**Like hours.** A busy hour is not like a quiet one: errors and latency often rise
with load. Each reading is a trailing window (`windowMinutes`, 60) and its baseline
is the same window at the same time of day on each of the `baselineDays` (7) before
the promotion, pooled. A model that is slower at 14:00 than at 03:00 is not worse
for it. Set `likeHours: false` for a flat comparison over every window before the
promotion, which will call an ordinary daily peak a breach.

**Provisional baselines.** An alias with no history before the promotion (a new
alias, or Prometheus retention shorter than the promotion) is judged against its own
first 24 hours, at times of day within an hour of the reading. Nothing is judged
until those 24 hours are over, and every line says "provisional".

**The states.** Each promoted alias gets one, with reasons, in the job log (`kubectl
logs` of the last job) and in the PR body:

| State | Meaning | What happens |
|---|---|---|
| `ok` | judged and inside the limits, or past `soakDays` | nothing |
| `breach` | a signal over its ratio, with at least `minRequests` in the window and in its baseline, at every reading for `forMinutes` | the revert PR and the ntfy message |
| `inconclusive` | a signal cannot be trusted this run: Prometheus did not answer, the series has a hole, or the limit was crossed but has not yet held for `forMinutes` | nothing. It pauses and tries again |
| `insufficient-data` | too few requests, no baseline yet, no promotion time, or no `promotion.previous` | nothing. It never breaches |

One inconclusive signal pauses the alias even when another signal is over its
limit. A breach opens no PR while another model-lifecycle PR is open (the opener
takes one at a time); the ntfy message says so and the next run tries again. A
revert the change cannot make (the previous model was itself rejected, the demoted
build serves another alias) is reported by `models.revert`'s own refusal.

**autoRevert.** `autoRevert: {<alias>: true}` marks that alias's revert PR for your
own auto-merge: the title ends `[auto-merge requested]`, the commit carries
`Tockmox-Auto-Merge: requested`, and on GitHub the PR is labelled
`tockmox/auto-merge`. Tockmox ships no automation that acts on the mark and the
watch has no merge call; what merges it is a rule you write. It is off for every
alias, and an inconclusive alias is never marked.

**What it needs.** The pod has no service-account token. Its NetworkPolicy allows
DNS, Prometheus, ntfy when set, and (with `pullRequests`) HTTPS to the forge. The
monitoring namespace's own policy admits only the Tockmox UI to Prometheus, so the
policy layer must also admit `app.kubernetes.io/name: tockmox-health-watch`, or
every alias reads as inconclusive. `pullRequests` is refused at render unless the
watcher's opener has a way to authenticate (`watch.pullRequests.githubApp` or
`watch.secrets.forgeToken`).

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
OpenAI model lists for what is newer than your catalog, reads LiteLLM's price map
for the list price of each hosted model ([Frontier cost](#frontier-cost)), writes
a report, and changes nothing. With `pullRequests` on, its PR opener turns the report into
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

`image` may be left empty: the watcher then runs in the UI's image
(`tockmoxUi.image`), so moving the UI to a new build moves the watcher with it.
The render refuses the watcher when neither is set, pull requests to GitHub with
neither an App nor a token, and pull requests to Forgejo with no token Secret.
Leave it off on an air-gapped site.

### What the watcher reads for prices

Providers publish no price API, so the watcher reads the one dated, recorded
source the gateway itself prices spend with: LiteLLM's price map, a single JSON
file at
`https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`.
It is one GET per run, to a host the watcher's allowlist now names
(`raw.githubusercontent.com`, the sixth). The chart's NetworkPolicy already
allows HTTPS to the internet, so no policy changes. The answer is capped at 16 MiB
(the file is about 3 MB), and a redirect is not followed.

For every hosted model the catalog or the gateway names, the watcher looks the id up
in the map: the exact `provider/model` key, then LiteLLM's `gemini/` prefix for a
`google/` id, then the unprefixed key (`claude-sonnet-5-5`, `gpt-5.1`), which counts
only when its own `litellm_provider` is that provider. It converts dollars per token
to dollars per 1M tokens and writes `prices` and `priceSource` to the report:

```json
"prices": {"anthropic/claude-sonnet-5-5": {"inPer1M": 3.0, "outPer1M": 15.0,
           "source": "LiteLLM price map", "readAt": "2026-10-30"}},
"priceSource": {"ok": true, "reason": "", "readAt": "2026-10-30"}
```

A model the map does not price is left out, and the page reads it as unknown. The
base rate is the figure: a higher rate past some context length is not read. When a
run cannot read the map, `priceSource` says why, and each model keeps its last good
price under its **original** date, marked `stale`, so the page says "last read
2026-10-20" and never shows an old price as today's. A price failure does not turn the
report's candidates Unknown. Set `modelLifecycle.watch.prices.enabled` to `false` to
make no request to that host; prices then read unknown unless the site states them.

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

## The Models page

The Models page (`/models`) is where the section starts. It answers the
questions an operator asks, in this order, and sends the detail to the pages
that own it. It is read only: every action renders a change for you to commit.

**Needs you.** One strip at the top, exceptions only, each row with one action.
A row appears for: candidates waiting in the [Inbox](#the-inbox-the-candidate-page-and-the-budget)
(*Review*), a hosted model its provider is retiring, with the countdown (*Evaluate
the replacement*, or *Open the alias* when the report names no replacement), a
`-next` candidate short of its passing count (*See the count*), one that has
enough and is ready to promote (*Promote*), an evaluation in progress with the leg
it is on (*Watch*), a node serving a build the catalog does not pin (*See the
drift*), a malformed `modelLifecycle.inbox` and a promotion gate that fails. When
nothing needs you the strip is not drawn at all.

**Local models.** One card per inference node: the node id (a link to its
page), its type, the memory planned on it against its total, and a table with
one row per deployment: alias, model, pinned build, engine and port, context,
slots, max output, thinking and state. A `-next` candidate sits under the alias
it competes for, marked as a candidate. The state is *Serving* or *Candidate
-next*, with a short line for the build check (*Holds the pinned build*, *Serves
another build*, *Build unknown* or *Build not checked*) that links to the node's
page, where the check lives.

**Frontier models.** Hosted models grouped by provider, then by family. A family
is the model id with its version removed, so `anthropic/claude-sonnet-5-5` and
`anthropic/claude-sonnet-5` sit together under `claude-sonnet`. When no part of a
name reads as a version, the family is the model id itself. Each row shows the
stage (promoted, candidate, or not in the catalog), the retirement countdown when
the watcher has one, and the gateway alias that routes it. The row also shows the
list price, spend and calls, described under [Frontier cost](#frontier-cost).

**Catalog and upstream sources.** Each folds to one line at the foot of the page
and opens on demand: the catalog with its promotion gate, and the watcher's
sources with when they last answered. The catalog line opens by itself when the
gate fails.

### Tunings

Every deployment shows the settings its route applies. **Context** is the
largest prompt the route accepts (`modelInfo.max_input_tokens`, or `num_ctx`
for Ollama). **Slots** is how many requests the engine serves at once; Tockmox
keeps no slot count per route, so it reads "engine default, not reported".
**Max output** is the most tokens one answer may have (`max_tokens`).
**Thinking** is whether the model reasons before it answers
(`chat_template_kwargs.enable_thinking`, On or Off).

A value the route states is shown as it is. When the route does not state it,
the page shows what the engine does by default, labelled as a default, and hovering
it says what that is. When Tockmox does not know the engine's default it says
"engine default, not reported" and guesses nothing. Any other route parameter is
under "More settings" on the node page.

## The Inbox, the candidate page and the budget

Three admin pages under Models turn the watcher's report and the eval runner's
status files into something you decide from. Each is read only: every button
renders a change for you to commit.

**Inbox** (`/models/inbox`). One scannable row per candidate in the watcher's
report. Each row shows the reason tag (*New revision*, *Other quant*,
*Successor*, *Hosted, new* or *Hosted, retiring*), the model id with one plain
sentence under it, the best fit, the size and one primary action. The best fit
is the node where the candidate fits best: fits beats tight beats over, and a
tie goes to the faster predicted speed, shown as "node, fits, about N tok/s".
The speed is predicted from memory bandwidth, not measured. A candidate nobody
has sized reads "not sized yet", never fits, and a hosted one reads "hosted, no
node". The primary action is **Evaluate**, which renders the existing admit
change. When the report records an open admit PR, **Review PR #N** replaces
Evaluate, and a retiring hosted model keeps its own action ("Evaluate the
replacement"). A small menu on each row holds **Snooze 30 days**, **Dismiss**
and the upstream page; both render a change to `modelLifecycle.inbox`.

Open a row to see the rest: the fit on each node (the same fit v2 arithmetic as
Recommend, with the model's memory and the context and slots it was planned
at), a licence chip against `modelLifecycle.recommend`'s allow list, the model
card's self-reported results under a label that says they are a hint and not a
measurement, and the state of the admit PR. A hosted row explains there that
the eval gateway gives it public eval sets only. The rows and the menu are plain
HTML, so they work from the keyboard and without JavaScript.

The chips at the top filter the list: *All*, *Local*, *Frontier*, *Snoozed* and
*Dismissed*, each with its count. *Snoozed* and *Dismissed* list the hidden
candidates, with the date a snooze ends, and carry no actions. The filter is the
`show` query parameter (`/models/inbox?show=frontier`). The entries look like
this:

```yaml
modelLifecycle:
  inbox:
    snoozed:   [{id: "quant:example-org/Example-30B-4bit", until: "2026-11-29"}]
    dismissed: [{id: "successor:example-org/Example-3-27B", date: "2026-10-30"}]
```

The ids are the report's candidate ids. A snoozed candidate comes back on its
date; a dismissed one stays hidden until the watcher finds a different candidate
(a new revision has a new id). The watcher and the PR opener skip both lists as
well, so a hidden candidate is not in the next report and is not opened as a PR.
The hidden ones are in the *Snoozed* and *Dismissed* views. A row links an open
admit PR when the report records one: the opener writes `pr` onto the candidate
after it opens the admit PR, and the watcher carries it forward while the
candidate is still found. Source health is one quiet line at the foot of the
page: which upstreams answered in the watcher's last report and how long ago, or
which one did not answer. A report that is missing, old or from a partial run is
shown as Unknown on that line, and an empty Inbox is then not called clean.

**Hosted retirement.** A hosted model its provider is retiring shows "retires in
N days" (or "retired on DATE" once past) on its Inbox row, on the Models
catalog and on the alias page of a gateway alias that routes to it. The date
comes from the provider's listing. A provider's API does not name a replacement,
so name it yourself under the watcher's provider settings:

```yaml
modelLifecycle:
  watch:
    providers:
      openrouter:
        allow: ["anthropic/*"]
        replacements: {"anthropic/example-old-3": "anthropic/example-model-9"}
```

The card then offers the replacement as a hosted candidate. Evaluate admits it
to the eval gateway, where the data-class rails let it see public eval sets
only, and the card says so.

**Candidate** (`/models/c/<alias>`). The plan for an evaluation of
`<alias>-next`: the alias it competes for, the incumbent, the legs (the latest
run's, else the runner's defaults), the estimated wall time when a run has one,
and the quiet-window rule it waits for. Below it, the latest run from the
runner's `run-status/1` files, drawn as connected stages with an arrow between
each: Control, Smoke, Perf, Prefill, Tool calls, Quality, then Verdict. Each
stage shows its state (queued, running, done, failed or skipped) and, once
done, its key number as the runner recorded it (smoke checks passed, decode
tokens per second at the lowest concurrency, time to first token at the longest
context, and so on); a stage with no recorded number shows the leg's summary
instead. The Verdict stage shows the runner's label once the run is done, and
partial numbers sit under a banner that says nothing here tells which model is
better until the verdict. The five runs before it list with their date, state
and the reason each ended. **Re-run** appears when the latest run is done or
failed, and renders a change that adds its run id to
`modelLifecycle.runner.rerun`; the runner's next pass queues a new run for the
same combination, and a rerun of one frozen set counts once toward promotion.
There is no Re-run while a run is queued, waiting or running. An aborted run
shows its reason. A run that says running but has not been written for an hour
is shown as Unknown. The files are read from `modelLifecycle.statusDir`
(default `/var/lib/tockmox/evals`); mount the runner's status volume read
only into the UI pod. A missing directory is Unknown, not an empty list.

**Budget** (`/models/budget`). Per alias, requests over the window of
`modelLifecycle.demandQuery`, each alias's share, and the share served by your
own nodes. For hosted aliases, a cost when one is known:

```yaml
modelLifecycle:
  budget:
    spendQuery: 'sum by (model_group) (increase(litellm_spend_metric_total[7d]))'  # measured USD per alias or model
    usdPerRequest: {big-hosted-chat: 0.012}                                         # your estimate, shown as an estimate
```

A measured figure beats an estimate. With neither, or when Prometheus does not
answer, the figure reads Unknown. It is never 0. A local route has no per-request
charge here; what it costs is the node, which this page does not price.

New values keys: `modelLifecycle.inbox.snoozed`, `modelLifecycle.inbox.dismissed`,
`modelLifecycle.statusDir`, `modelLifecycle.budget.spendQuery`,
`modelLifecycle.budget.usdPerRequest` and
`modelLifecycle.watch.providers.<provider>.replacements`. `modelLifecycle` is an
experimental block, so they need no chart change.

### Frontier cost

On the Models page each hosted model shows its list price, what the gateway spent
on it, and how often it was called. Each figure says where it came from, and a
figure nobody has reads **unknown**, with the reason on hover. It is never 0 and
never an estimate passed off as a fact.

- **Price per 1M tokens, in / out.** The provider's list price with the day it was
  read. It comes from the watcher's report ("LiteLLM price map, read 2026-10-30";
  "last read 2026-10-20" when the latest read failed and an earlier price is kept),
  or from your values, which win ("set by this site", with your date). The footer
  under the table names the sources. It is the list price, not what you paid:
  discounts, caching and batch rates are not in it, and it is not multiplied into
  the spend figure.
- **Spend and Calls.** Spend is `modelLifecycle.budget.spendQuery` and calls is
  `modelLifecycle.demandQuery`, both read from Prometheus. Each header names the
  window the query itself covers, read from its `[7d]`: a 7-day query reads
  "Spend (7 d)", a `[30d]` query reads "Spend (30 d)". Nothing is relabelled
  "this month". Set `[30d]` in both queries to see 30 days. A series is matched to
  a model by the gateway aliases that route to it, then by the model id with or
  without its provider. A model with no series, or a query that did not answer,
  reads unknown.

```yaml
modelLifecycle:
  frontier:
    prices:                                   # optional: wins over the price map
      anthropic/claude-sonnet-5-5: {inPer1M: 3.0, outPer1M: 15.0, date: "2026-10-30"}
  demandQuery: 'sum by (model_group) (increase(litellm_deployment_success_responses_total[30d]))'
  budget:
    spendQuery: 'sum by (model_group) (increase(litellm_spend_metric_total[30d]))'
    spendByCallerQuery: 'sum by (api_key_alias, model) (increase(litellm_spend_metric_total[30d]))'   # optional
```

`frontier.prices` takes a number of dollars (zero or more) for `inPer1M` and
`outPer1M` and the day you read the price (`date`, quoted, `YYYY-MM-DD`), nothing
else. A negative price, a missing date or an extra key is refused when the chart
renders and when the UI starts. A change the UI generates keeps your prices.

`budget.spendByCallerQuery` is optional. Each series must carry the model and who
called: LiteLLM's `litellm_spend_metric` labels spend with `model` and with the
key and team labels (`api_key_alias`, `team_alias`, `team`, `user`, `end_user`,
`hashed_api_key`), and the first one a series has names the caller. Check the labels
your gateway version exposes. When it is set, each family row on the Models page
opens a table of the five callers that spent most on that family, over the window the
query names. Without it there is no table. A caller with no label at all is listed
as "no key alias or team", because the spend is real and has no name.

### -next routes carry the live alias's tags

A candidate admitted for evaluation is a node route, so it is written with
`model_info.endpoint_tier: local` and the live alias's `tags`. Without them the
policy gate reads the deployment as off-site, and with tag filtering on, an
untagged deployment serves no data class.

## The build on the node

Git holds the build each model is pinned to (`source.revision`); the node holds
the one it actually serves, and nothing stops someone pulling a different one
by hand. The UI compares the two on the node's page (`/nodes/<id>`), under
"Builds on this node", for every catalogued Ollama or Hugging Face model with a
pinned revision that a route serves. The Models page shows each deployment's
build state in one short line that links there, and a drift is a row in its
Needs-you strip:

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
admin presses "Check builds on the nodes" on a node's page; a page load never
reaches a node. The
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
edited: a re-measurement is a new file. A twin the eval runner writes names its
run (`run`, the run id) and carries it at the end of its file name, so two runs of
one build on one day (a re-run after a route fix, say) never share a name; a twin
without `run` keeps the name `<date>-<model>-<engine>-[<kind>-]<plane>.json`. A run
id is used once: a run whose id already has a verdict is refused before any leg
runs. The reader refuses what it could
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

### The data-class rails

Every eval set names its class (`classification`: public, internal, confidential
or restricted), and a row (`cases.jsonl`) may name a higher one; a set or row
without a valid class is refused. Two checks then keep eval data where it may go:

- **The runner** takes the highest class in the set and refuses to send anything
  above public to a route the eval gateway does not report as local
  (`model_info.endpoint_tier`). A route the gateway says nothing about counts as
  not local. It tags every request with the class: `open` for public, `internal`,
  and `restricted` for confidential and restricted.
- **The eval gateway** filters by tag (`router_settings.enable_tag_filtering`).
  A node route is local unless it says otherwise and serves every class
  (`restricted`, `internal`, `open`) unless it sets its own tags; an external route
  or a hosted candidate serves `open` alone, and the chart refuses to render an
  external eval route tagged for more.

So a hosted candidate is evaluated on public sets only. Grades are deterministic
(there is no judge on this path), so no eval data reaches a judge model. An
untagged request is not fenced by the gateway; the runner never sends one, and
the eval gateway admits only `modelLifecycle.evalGateway.allowedClients`.

### What the eval runner measures

`python -m app.runner run` writes one twin per leg and one verdict. Besides control,
smoke, perf and quality it has three legs that exist because a model can answer well
and still be wrong for the job:

- **Prefill** (`kind: prefill`). Time to first token at several context lengths,
  `--prefill-contexts` (default `4096,16384,32768,65536`), `--prefill-requests`
  streamed requests per length (default 3, one at a time, `max_tokens` 16). The
  prompt is filler sized at four characters per token, an estimate the twin says so
  about; where the engine reports `prompt_tokens` that count is recorded beside it
  (`prompt_tokens_at_<ctx>`). Each prompt opens with a fresh nonce, so a prefix cache
  cannot answer it. A length over the route's maximum input (the request's
  `max_input_tokens`, or `--max-input-tokens`) is skipped, not sent, and the twin
  names the reason. Metrics are `ttft_ms_at_<ctx>`, each with its `n`.
- **Tool-call reliability** (`kind: tool_reliability`). Runs for a set whose cases
  offer tools, and always for class `agent` (a built-in six-prompt battery when the
  set has none). `--tool-reliability-calls` calls (default 100, 0 turns it off) cycle
  through the tool-bearing cases at temperature 0.7, each with its own seed, so the
  figure is variance and not one draw. `parse_failure_rate` counts arguments that are
  not a JSON object and calls printed into the reply text (`<tool_call>`,
  `[TOOL_CALLS]`, a `{"name", "arguments"}` object); `wrong_tool_rate` counts a
  different, unoffered or missing tool where one was expected;
  `schema_violation_rate` counts arguments that break the tool's own schema. A
  parse-failure rate above the set's `tool_parse_bar` (default 0.02) fails the verdict
  whatever the quality, and the verdict's criterion says why. The other two rates are
  recorded for the reader and do not fail a run alone. The twin names the engine and,
  when the request carries `chat_template`, the chat template.
- **Speed.** A set or request may carry `speed_criterion: {decode_tok_s_min_ratio: 0.5}`
  (candidate over incumbent). The incumbent's perf leg then runs too, and a quality
  pass that decodes slower than that ratio is labelled `tradeoff`: verdict
  `inconclusive`, never counted toward a promotion, never a reset. It is for a person
  to weigh. Every verdict from this runner carries a one-line `summary`, for example
  `Better on quality (+0.12 pass rate), 4.3x slower decode, tool parse 0.0%`.

Every new field is optional and, when present, checked: a malformed `summary`,
`speed`, `speed_criterion` or `tool_reliability` in a verdict, or a bad
`tool_parse_bar` or `speed_criterion` in a set, is refused; older verdicts read as before.

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

### Shipped eval sets

The UI image carries two public, synthetic sets under `tockmox-ui/app/evalsets/<class>/<version>/`, each a
directory of `set.yaml` and `cases.jsonl` in the `eval-set/1` format. `large/v1` is a general-purpose bar for a
large local model: 13 verbatim-copy cases (numbers, curly quotes, tabs, indentation, backslashes), 10 JSON
extractions checked against a schema with the expected values pinned, 12 word problems graded on a final
`Answer: <number>` line, 8 format-constraint cases and 5 short reasoning cases. `agent/v1` has 48 cases against 17
home and office tool schemas: 36 must make exactly one call to the right tool with the right arguments, and 12 must
be answered without a tool. Both have 48 cases (so neither is a screening set), a bar of 0.85, a margin and
minimum effect of 0.05, and one epoch, and every passage and tool is written for the set. A set's identity is the
hash of its two files, so editing a case is a new version: copy the directory to `v2`, never change `v1` after a
verdict names it. The tests (`tests/test_shipped_evalsets.py`) hold each set to the known-bad control and to
hand-written right and wrong replies, so a grader loosened by mistake turns the suite red. A site adds its own
sets beside these; keep them `public` or `internal`, since the runner refuses a set classified above `internal`.
## Running evaluations on a schedule

The eval runner (`python -m app.runner run`) measures one candidate against what an
alias serves now. This section is about starting it for you. Turn it on with
`modelLifecycle.runner.enabled` (off by default). A CronJob, the scheduler, wakes
every `schedule` (15 minutes), decides what is worth measuring, and starts at most
one Job per node.

**What it measures.** Every `<alias>-next` route that the eval gateway serves and
whose catalog entry is at stage `candidate` is an admitted candidate: merging the
admit PR was your consent to evaluate it. It is measured once per combination of
the alias, the candidate's model and revision, the eval set and its sha256, the
engine and its version, the node, and the `-next` route's `provider` and `params`
(as a digest; a route with neither has none). A run that finished (`done` or
`failed`) for that combination is not started again by itself; change one of
them, or list the run id in `runner.rerun`, to measure again (a listed id whose
combination already has a newer finished run is left alone, so the list can stay
until you tidy it). So fixing a route's
settings (turning thinking off, raising `max_tokens`) measures the candidate again
on the next pass, without touching the status files. A run that was `aborted`,
because the node stopped answering, is tried again. The request it runs is built
from the route and the catalog: the candidate is what `-next` serves, the
incumbent is what the live alias serves, and with no live alias the comparison is
judged on the absolute bars.

**A model that only thinks.** A reasoning model behind a route that leaves its
thinking on (Qwen3.x on mlx-lm does by default) can spend every token of
`max_tokens` reasoning and answer nothing: the reply comes back with
`finish_reason: length`, empty content and the reasoning beside it. Graded, that
reads as a model that got every case wrong, so the runner does not grade it. When
a smoke check fails and any smoke reply was cut that way, or when at least half
the quality answers were, the run stops `failed`, writes no verdict, and its
`reason` says how many replies came back empty and whether the engine returned
reasoning. The fix is on the route, for example:

```yaml
- alias: local-large-next
  provider: openai
  params:
    max_tokens: 8192
    extra_body:
      chat_template_kwargs:
        enable_thinking: false
```

and the changed route is measured again on the next pass. A few cut answers
among many are graded as wrong answers, as before.

**Which eval set.** The workload class of the alias decides it: the class a profile
(`modelLifecycle.profiles.<id>.classes`) gives the alias, else the `promotion.class`
on a catalog entry, else the alias's own name when it is `local-<class>` (or
`<class>`) and the product ships a set for that class, so a first `local-large-next`
candidate on a site with no profile is judged as `large`. The runner takes the highest version the product ships for that
class (`tockmox-ui/app/evalsets/<class>/<version>/`) or your own, from the ConfigMap
named in `runner.extraSetsConfigMap` (keys `<class>__<version>__set.yaml` and
`<class>__<version>__cases.jsonl`); at the same version yours wins. An alias with no
class, or a class with no set, waits with that sentence as its reason.

**Which candidates.** Every admitted `<alias>-next` candidate, in alias order, one
run at a time per node. `runner.aliases` narrows that to the live aliases you list
(`[local-large]` schedules only `local-large-next`), which is how a first run on a
new site measures one candidate before the others queue behind it.

**When it starts.** Only in a quiet window. The scheduler asks Prometheus how many
requests reached the node's live aliases through the production gateway in the last
`quietWindow.minutes` (the gateway's `litellm_proxy_total_requests_metric`, per
requested model; the eval gateway does not export it, so its own traffic never
counts), to the node's live aliases in `inferenceNodes.routes` plus any listed in
`runner.nodes.<id>.productionAliases` (a production alias your hand-written
`model_list` puts on the node while `inferenceNodes.render` is off). More than
`quietWindow.maxProductionRequests` (0 by default) and the run waits. The node's health URL must also answer 2xx: the engine's own health path
(`/health` for mlx-lm, `/api/version` for Ollama, `/v1/models` otherwise) or
`runner.nodes.<id>.healthUrl`. A Prometheus that does not answer counts as "cannot
tell", and waits too. Waiting is not an error: the run shows state `waiting` with
the reason ("node busy: 3 production requests in the last 10 min"), and starts on a
later pass. Two runs for one node run one after the other; the second shows `queued`.

**After an engine upgrade.** Tell the runner what the node runs now with
`runner.nodes.<id>.engineVersion` (and `engine` if it differs from the endpoint's).
When that differs from the engine in the last finished run of the build an alias
serves on that node, the scheduler re-measures that build, smoke and perf only,
with trigger `engine-upgrade`. It decides nothing: no verdict, no label, no
promotion. If smoke checks that passed before now fail, or the 95th percentile
latency rose by more than 25% or decode throughput fell by more than 20% at the same
concurrency, the run's `reason` says which figures, with both numbers. The eval
gateway serves a live alias only while a `-next` route sits beside it, so an upgrade
re-evaluation for any other alias waits and says so.

**What you see.** One file per run, `<statusDir>/runs/<run_id>.json`
(`run-status/1`), on a small volume the Tockmox UI mounts read-only. It names the
alias, class, candidate, incumbent, node, engine, eval set, trigger and state
(`queued`, `waiting`, `running`, `done`, `aborted`, `failed`), the planned legs and
where each is, and, once there is one, the verdict path and label. A status never
names a winner; the verdict does. The evidence the Job writes (result twins,
verdict, methodology) is under `<statusDir>/site/` laid out like the site repo, and
the UI reads verdicts and results from there unless you set
`modelLifecycle.verdictsDir` or `resultsDir`. With
`modelLifecycle.runner.evidence.pullRequests: true` the Job then opens the evidence
pull request with the watcher's settings and secrets (`modelLifecycle.watch
.pullRequests` and `watch.secrets`; see "Evidence pull requests").

**What it needs.**

- `modelLifecycle.evalGateway.enabled`, and a peer in `evalGateway.allowedClients`
  that selects the Job pods, which carry `tockmox.com/eval-client: "true"`:

  ```yaml
  modelLifecycle:
    evalGateway:
      allowedClients:
        - podSelector: {matchLabels: {tockmox.com/eval-client: "true"}}
  ```

  An empty list admits nobody, and the chart refuses to render the runner with one.
- The Tockmox UI image. It ships as source, so you build it. `runner.image` empty
  means `tockmoxUi.image`, and that is what you want: **the runner must run the UI
  image built from the same commit as this chart**, because the Job arguments, the
  eval-set layout and the status files are agreed between the two. Bumping only one
  of them is how the scheduler ends up passing a flag the runner does not know.
- Endpoints and any `healthUrl` named by IPv4 address. The runner's NetworkPolicy
  can admit an address and a port, not a host name, and the chart refuses a name.
- Storage: the status volume (`runner.status`, 1Gi) is written by the scheduler and
  the Job pods and read by the UI. ReadWriteOnce attaches to one node, so with the UI
  on the chart requires the scheduler and the Jobs onto the UI pod's node and rolls
  the UI without a surge; ReadWriteMany needs neither. With the UI off, use
  ReadWriteMany.

**What it can reach.** The scheduler is the only pod with a Kubernetes token, and
the token is limited to creating, reading, listing, watching and deleting Jobs and
reading Pods in this namespace. The Job pods have no token. Each has a NetworkPolicy
and carries `tockmox.com/isolated`. The scheduler reaches DNS, the Kubernetes API
(`tockmoxUi.networkPolicy.apiServer`, else `global.lanCIDR` on 6443), Prometheus in
the monitoring namespace, and the nodes' endpoints. A Job reaches DNS, the eval
gateway Service on 4000 and the nodes' endpoints, and, only with
`evidence.pullRequests`, HTTPS to the internet outside every private range. A
`prometheusUrl` of your own that is a host name needs a NetworkPolicy of yours.

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
  context. It is a prior to rank by and is labelled predicted on the page, shown as a
  whole-number range ("about 110 to 140 tokens/s"), never a decimal, until a perf
  twin has measured the model on the node and the measured figure replaces it.
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

---
okf_version: "0.2"
type: HowTo
title: "Inference nodes"
description: "Record the machines that serve models outside the cluster (a Mac Studio, a DGX Spark, a workstation) once, and let the chart derive the model gateway's routes to them instead of hand-writing each one."
tags: [ai-plane, litellm, inference, model-gateway, mlx, ollama, vllm, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-07
tockmox:
  classification: public
  audience: [operator]
---

# Inference nodes

Most of the hardware that is good at running models is not a Kubernetes node: a
Mac Studio, a DGX Spark, a workstation with an RTX card. Tockmox calls these
**inference nodes**. The [external integrations](external-integrations.md) page
covers setting one up on the network. This page covers telling the model gateway
about it.

> **Experimental in 0.8.0, and off by default.** The values keys below may change
> before they are marked stable; an upgrade that changes them says so in the
> release notes. With `inferenceNodes.render.enabled: false` (the default) the
> chart renders exactly what it rendered before.

## What it replaces

Without it, every route to a node is a hand-written `litellm.proxy_config.model_list`
entry, and the node's address, port, engine and API path are repeated in each
one. A node that moves, or an engine that changes its API path, means editing
every entry that names it, and nothing checks that they agree.

With it, a node is written once, under `inferenceNodes.nodes`, and each route is
one line naming the node, the endpoint and the model. The chart derives the
gateway entry: the provider prefix and the API path for that engine and kind of
model, the `api_base`, and the key reference. Hand-written entries for hosted
providers stay where they are, first in the list and unchanged.

## Turning it on

The chart now renders the gateway's whole `config.yaml`, so the LiteLLM subchart
must stop rendering its own and mount this one instead:

```yaml
inferenceNodes:
  render:
    enabled: true
litellm:
  proxyConfigMap:
    create: false
    name: tockmox-litellm-config
```

The render refuses, with a sentence naming the cause, when:

- `litellm.proxyConfigMap.create` is still true, or names another ConfigMap.
  The derived routes would land in a ConfigMap nothing mounts.
- `litellm.redis.enabled` is set. The subchart injects its Redis settings into a
  config it renders itself, and this chart does not repeat that yet. A single
  gateway replica does not use Redis.
- a derived alias is also a hand-written `model_list` entry. LiteLLM
  load-balances one name across every entry that carries it, so one route's
  traffic would reach the other's backend.
- either rolling annotation (below) is missing or stale.

### The two rolling annotations

LiteLLM reads `config.yaml` once, at start-up, and the subchart can only hash a
ConfigMap it renders itself. So a change to the routes would otherwise load on
the next unrelated restart, days later, and look like it had worked. Two pod
annotations roll the gateway instead, each with one writer:

| Annotation | Hash of | Who writes it |
|---|---|---|
| `tockmox.com/node-routes` | the derived routes | whoever changes `inferenceNodes`, in the same commit |
| `tockmox.com/gateway-config` | `litellm.proxy_config` as written by hand | whoever edits that block, in the same commit |

You do not compute either hash. Render with the new values and the refusal
prints the value to set:

```yaml
litellm:
  podAnnotations:
    tockmox.com/node-routes: "<the value the render printed>"
    tockmox.com/gateway-config: "<the value the render printed>"
```

`podAnnotations` is a map, so Helm merges it across values files: keep these
two beside whatever else your site sets there.

## Values reference

```yaml
inferenceNodes:
  render:
    enabled: true
    configMapName: tockmox-litellm-config   # must equal litellm.proxyConfigMap.name
  nodes:
    - id: studio                            # lowercase letters, digits, dashes
      name: Mac Studio
      type: apple-silicon-mac
      address: 192.0.2.10
      endpoints:
        - id: mlx-lm-8080
          engine: mlx-lm                    # see "Engines"
          url: http://192.0.2.10:8080       # no path: the engine's path is added
        - id: vllm-8000
          engine: vllm
          url: http://192.0.2.10:8000
          auth: {secretRef: studio-key}     # optional; a Secret name, never a token
  routes:
    - alias: local-chat                     # what users and agents ask for
      node: studio
      endpoint: mlx-lm-8080
      model: mlx-community/Example-27B-4bit # the id the engine knows it by
      kind: chat                            # chat | embedding | rerank
      params: {}                            # extra litellm_params, passed through
      modelInfo: {}                         # extra model_info, passed through
```

- **`params`** may set anything LiteLLM accepts except `model` and `api_base`,
  which are derived from the node; the render refuses either. An Ollama route
  must set `num_ctx` here (see [Context length](#context-length)) and can set
  `keep_alive`.
- **A route that names a node or endpoint that does not exist** is refused,
  naming the route.
- **A kind the engine does not serve through the gateway** (a rerank route on
  an engine with no rerank API) is refused.
- **Each derived entry carries `model_info.tockmox_node`**, so the gateway's own
  metrics and logs say which machine served a request.

**Node types:** `apple-silicon-mac`, `nvidia-dgx-spark`, `nvidia-gpu-linux`,
`amd-strix-halo`, `openai-compatible`. Other hardware types are added on
demand. The type is the hardware
profile the [Tockmox UI](tockmox-ui.md) sizes placements with; leave it out and
it is `openai-compatible`, the generic profile. Any other value is refused by
the render: the UI refuses it at start, and before 0.8.0's lab rehearsal the
chart rendered it and the UI went into CrashLoopBackOff on `workstation`.

**Engines:** `ollama`, `mlx-lm`, `llama-server`, `vllm`, `sglang`, `lm-studio`,
`nim`, `tgi`, `exo`, `openai-compatible`. Use `openai-compatible` for an engine
that is not listed and serves the OpenAI API; the render refuses any other name,
for the same reason as the type.

**The gateways need a path to the node.** The AI namespace is default-deny for
egress, so each node's address and engine ports go in the policy layer's
`aiEgress.litellm.extraEgress` (an [upgrade](../deployment/upgrade.md) from
0.6.x names it too). The production gateway and the
[eval gateway](model-lifecycle.md) share that rule, so one entry serves both.
The key is read by the policy layer, so it goes in `site/values/policy.yaml`,
not `ai.yaml`, and each entry is a NetworkPolicy egress rule as the API server
takes it (`to` and `ports`), not the `{cidr, ports}` shape `providerAllow`
uses; the render refuses the wrong shape:

```yaml
# site/values/policy.yaml
aiEgress:
  litellm:
    extraEgress:
      - to: [{ipBlock: {cidr: 192.0.2.10/32}}]      # the node, by address
        ports: [{protocol: TCP, port: 11434}]       # one per engine port
```

## Context length

How many tokens a model holds in context decides most of the memory it uses
beyond its weights: the KV cache grows with every token of context the engine
reserves. Pin the context on every route, and never let an engine choose it.

**Ollama chooses a large one when no one says.** A request with no `num_ctx`
gets Ollama's default, which current Ollama sizes from the GPU memory it sees
(Ollama's `docs/context-length.mdx`):

| GPU memory | Default context |
|---|---|
| under 24 GiB | 4k tokens |
| 24 to 48 GiB | 32k tokens |
| 48 GiB or more | 256k tokens |

**The KV cache per token** is layers × KV heads × head dimension × 2 (keys and
values) × bytes per value, all from the model's `config.json`. Qwen3-Coder-30B-A3B
gives `num_hidden_layers: 48`, `num_key_value_heads: 4` and `head_dim: 128`, so
at f16 (2 bytes) that is 96 KiB a token. At 262,144 tokens the cache is 24 GiB,
more than the model's 19 GiB of Q4_K_M weights. On a 64 GiB Mac that is the
difference between fitting and swapping.

**So every route to an Ollama endpoint sets `params.num_ctx`,** and the render
refuses one that does not, naming the route, the node and the endpoint. The
gateway passes it to Ollama as `options.num_ctx` on each request:

```yaml
inferenceNodes:
  routes:
    - alias: local-coder
      node: studio
      endpoint: ollama-11434
      model: "example-coder:30b"
      params: {num_ctx: 32768, keep_alive: -1}
```

- **Set `OLLAMA_CONTEXT_LENGTH` on the node as well,** to the smallest context
  any route uses. It is the default for a request that reaches Ollama without
  going through the gateway, so nothing can load a model at 256k by accident.
- **Use one value per model.** Two routes to the same model with different
  `num_ctx` make Ollama reload it whenever the caller switches.
- **A change the Tockmox UI writes sets `num_ctx: 16384` on each Ollama route it
  proposes.** That is the floor the reference lab runs. Edit it to the context
  you want before you commit the change.

**Other engines take the context at start-up, not per request,** so the chart
has nothing to check and adds no key for it:

- **llama-server:** pass `-c` on the node's command line. Its default, 0, means
  the model's full trained context.
- **vLLM:** pass `--max-model-len`.
- **mlx-lm:** its server has no context setting. Cap the prompt at the gateway
  instead: put `max_input_tokens` in the route's `modelInfo` and set LiteLLM's
  `router_settings.enable_pre_call_checks: true`, which refuses a request longer
  than that before it reaches the node. Tockmox has not measured this cap.

## Engines that need a token

Ollama and mlx-lm have no login of their own, so anyone who can reach their port
can use them. Restrict the port to the gateway's addresses with the host's
firewall ([external integrations](external-integrations.md) has the rules).
Engines that take a bearer token (llama-server, vLLM, SGLang, LM Studio) should
have one as well.

For an endpoint with `auth.secretRef: studio-key`, the derived entry reads its
key from the environment variable `NODE_KEY_STUDIO_KEY`: the Secret name in
capitals, with anything that is not a letter or digit turned into `_`. Create a
Secret whose key **is** that variable name, and give it to the gateway:

```yaml
litellm:
  environmentSecrets: [tockmox-node-keys]   # holds NODE_KEY_STUDIO_KEY
```

A route that sets `params.api_key` itself keeps its own.

**An endpoint with no token still gets a key.** LiteLLM's OpenAI provider refuses
to send a request without one ("The api_key client option must be set"), even to
a server that checks none. So a route on the OpenAI provider (mlx-lm, vLLM,
llama-server and the other OpenAI-compatible engines) to an endpoint with no
`auth.secretRef` is given the placeholder `api_key: no-auth`, which the engine
ignores. Ollama routes need none and get none.

## Monitoring the nodes

With `inferenceNodes.monitoring.enabled`, and the observability layer's
service monitors on, the AI layer renders two objects for the Prometheus that
layer ships:

- a **ScrapeConfig**, `tockmox-inference-nodes`, with one target per exporter a
  node lists under `metrics`, at `<address>:<port>`;
- a **Probe**, `tockmox-inference-nodes`, with one blackbox target per engine
  endpoint: `<url>/api/version` for Ollama, `<url>/v1/models` for everything
  else.

```yaml
inferenceNodes:
  monitoring:
    enabled: true
  nodes:
    - id: studio
      address: 192.0.2.10
      metrics: {node_exporter: 9100, macmon: 9101}
      endpoints:
        - {id: mlx-lm-8080, engine: mlx-lm, url: "http://192.0.2.10:8080"}
```

Neither object rewrites the `instance` label, and that is deliberate: the
Tockmox UI reads a node's health from Prometheus and matches an exporter by
`<address>:<port>` and an endpoint by a probe whose `instance` starts with its
URL. A measurement with no series reads as **Unknown**, never as healthy.

The probe goes through the exporters layer's blackbox exporter, with its
`http_inference` module, which accepts 401 and HTTP/1.0. An engine that wants a
bearer token answers 401 to a probe that has none, and that still shows it is
up; a probe never carries a node's token. HTTP/1.0 is for mlx-lm, whose server
is Python's `http.server` and answers `HTTP/1.0 200 OK`: the consoles' module,
`http_console`, refuses that version, and under it every mlx-lm node read down
while it served completions (0.8.0 lab rehearsal). If the exporters layer is not installed under the
release name `tockmox-exporters`, set `inferenceNodes.monitoring.blackboxProber`
to its Service as `host:port`, with no scheme.

You still install the exporters on the node and open their ports to the
cluster in the node's firewall; [external integrations](external-integrations.md)
has the steps.

## Candidate routes and the eval gateway

A route whose alias ends in `-next` is a **candidate**: a model being compared
against the one its base alias serves today. It is never rendered into the
production gateway's config. It goes to the separate eval gateway instead,
described in [model lifecycle](model-lifecycle.md), and with that off it goes
nowhere.

## What it does not do

The chart does not contact a node; Prometheus does, when monitoring is on. It does not install engines, pull models,
check that the model exists on the node, or manage the node's operating system
or firewall. A typo in a model id renders cleanly and fails at the first
request, as a hand-written entry would.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.2 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

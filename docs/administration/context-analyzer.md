---
okf_version: "0.2"
type: HowTo
title: "The Context Analyzer add-on"
description: "Turn on the Context Analyzer in the AI layer: what the chart renders, the four things a site supplies, how the gateway hook loads, and what the render refuses."
tags: [context-analyzer, add-on, ai-plane, litellm, hooks, networkpolicy, experimental]
status: draft
generated:
  by: hand
  at: 2026-11-17
tockmox:
  classification: public
  audience: [operator]
---

# The Context Analyzer add-on

The Context Analyzer records what each request through the model gateway
carried (its context, its class, the route that served it) so an operator can
see how the gateway is used. It is an add-on: **off by default**, and the AI
layer renders nothing for it until you turn it on. It is experimental.

## What turning it on renders

`apps.contextAnalyzer.enabled: true` (it belongs to the `aiPlane` capability,
so declining that capability with this set is refused) renders, in the AI
namespace:

| Object | Name | What it is for |
|---|---|---|
| Deployment and Service | `tockmox-context-analyzer` | the Analyzer, on port 8000 |
| CNPG Cluster | `tockmox-context-analyzer-db` | its database; the storage class follows the [storage policy](storage.md) |
| NetworkPolicy | `tockmox-context-analyzer` | only the gateway's pods and Prometheus reach it |
| ServiceMonitor | `tockmox-context-analyzer` | the scrape, with the bearer token `/metrics` requires |
| PrometheusRule | `tockmox-context-analyzer` | the alert rules from the Analyzer's source |
| ConfigMap | `tockmox-context-analyzer-dashboard` | the dashboard, in Grafana's Tockmox folder |

The scrape, the rules and the dashboard follow `apps.serviceMonitors` like the
rest of the layer's monitoring. The pod is labelled `tockmox.com/isolated`, so
the policy layer's namespace-wide allows do not widen its own policy.

The hook needs no new volume on the gateway. Its files join the gateway's hooks
ConfigMap (`tockmox-litellm-hooks`, mounted at `/etc/litellm/hooks`): a loader,
`tockmox_context_analyzer.py`, its settings, and the Analyzer's four modules.
The loader reads the modules by file path, so it works with the stock LiteLLM
image whatever its version. With the [policy gate](../usage/ai-plane.md#the-policy-gate)
on, the hook runs in Tockmox mode and reads each request's class from the gate;
with the gate off, neither is set, because Tockmox mode without a class source
fails every call closed.

## What the site supplies

Tockmox publishes no image and no package for the Analyzer, so four things come
from the site. The render refuses with a sentence naming each one that is
missing.

1. **The image**, built from the Context Analyzer source:

   ```yaml
   contextAnalyzer:
     image: registry.example.com/site/context-analyzer:0.3.0
   ```

2. **The source files**, file name to text, from the same source tree. The four
   modules come from `src/context_analyzer/`, the rules from `deploy/` and the
   dashboard from `grafana/`. With Helm directly:

   ```bash
   helm upgrade --install tockmox-ai charts/tockmox-ai -n tockmox-ai -f site-ai.yaml \
     --set-file 'contextAnalyzer.source.compat\.py=../context-analyzer/src/context_analyzer/compat.py' \
     --set-file 'contextAnalyzer.source.segmentation\.py=../context-analyzer/src/context_analyzer/segmentation.py' \
     --set-file 'contextAnalyzer.source.actuation\.py=../context-analyzer/src/context_analyzer/actuation.py' \
     --set-file 'contextAnalyzer.source.hooks\.py=../context-analyzer/src/context_analyzer/hooks.py' \
     --set-file 'contextAnalyzer.source.prometheus-alerts\.yaml=../context-analyzer/deploy/prometheus-alerts.yaml' \
     --set-file 'contextAnalyzer.source.context-analyzer-dashboard\.json=../context-analyzer/grafana/context-analyzer-dashboard.json'
   ```

   Under Argo CD, commit the same six files as a values file in the site
   repository, under `contextAnalyzer.source`. Build the image and the files
   from the same commit.

3. **The token Secret**, with keys `CTXA_TOKEN` (the bearer token the hook
   sends and `/metrics` checks) and `CTXA_HASH_SALT`, named in
   `contextAnalyzer.tokenSecret` (default `tockmox-ctxa`) and
   listed in the gateway's environment:

   ```bash
   kubectl -n tockmox-ai create secret generic tockmox-ctxa \
     --from-literal=CTXA_TOKEN="$(openssl rand -hex 32)" \
     --from-literal=CTXA_HASH_SALT="$(openssl rand -hex 32)"
   ```

   ```yaml
   litellm:
     environmentSecrets: [tockmox-ctxa]
   ```

4. **The callback**, after the policy gate's when the gate is on:

   ```yaml
   litellm:
     proxy_config:
       litellm_settings:
         callbacks:
           - hooks.tockmox_gate.tockmox_gate
           - hooks.tockmox_context_analyzer.analyzer_hook
   ```

## What the render refuses

- the add-on on with the model gateway off, or under a declined `aiPlane`;
- no image, or any of the six source files missing;
- the callback not registered, or registered before the policy gate's;
- the token Secret not in `litellm.environmentSecrets`;
- the callback left registered with the add-on off (the proxy would fail at
  start-up on an import error);
- a site hook file with one of the add-on's file names.

`tests/context-analyzer/render.sh` holds one case for each.

## Not in this release

There is no Ingress for the Analyzer's own interface yet; reach it with
`kubectl -n tockmox-ai port-forward svc/tockmox-context-analyzer 8000`. It
has not yet been proved on a cluster; until it has, treat it as a preview.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

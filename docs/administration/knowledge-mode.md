---
okf_version: "0.2"
type: HowTo
title: "Knowledge mode: the console's own document Q&A, configured the Tockmox way"
description: "How to turn on Open WebUI's Knowledge feature with local embeddings through the gateway and Knowledge bases kept in sync with git, what it refuses to render and why, the boundary it does and does not give you, and how it restores."
tags: [ai-plane, open-webui, knowledge, rag, retrieval, oikb, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-29
tockmox:
  classification: public
  audience: [operator]
---

# Knowledge mode

**Knowledge mode is the quick way to chat with your documents.** One values
block configures Open WebUI's own Knowledge feature so that every document is
embedded by a model on your site, through the gateway, and (optionally) keeps a
Knowledge base in step with a git repository. It is off by default and
experimental in this release.

It is **console state**. It leaves with the console, nothing else in Tockmox
depends on it, and it holds **public or internal material only**. That is the
one named exception to [the frontend posture](../frontend-posture.md): Tockmox
configures a console feature for you, and does not build on it.

| I want to | Go to |
|---|---|
| Know whether this is the right tool | [What it is and is not](#what-it-is-and-is-not) |
| Turn it on | [Turn it on](#turn-it-on) |
| Keep a Knowledge base in sync with git | [Sync from git](#sync-from-git) |
| Know why a render was refused | [What the chart refuses](#what-the-chart-refuses) |
| Restore it | [Restore](#restore) |

## What it is and is not

What you get: a user types `#` and a Knowledge base's name in a chat, asks a
question, and the answer carries the console's numbered source chips. Hybrid
search (vector plus keyword) is on, retrieved chunks can be reranked by a local
model, and a file removed from the source leaves the index (file retention is
off).

What it is not:

- **Not a confidentiality boundary.** Access is a grant per Knowledge base,
  enforced by the console alone. On a shared console that is a convenience
  boundary. Restricted material belongs in its own index, or on a console only
  one person uses. The chart refuses a sync source classified above
  `internal`.
- **Not a capability the rest of Tockmox can call.** Agents and other clients
  cannot query a Knowledge base. Retrieval that other clients use is a separate
  service, planned and not shipped ([alternatives](../alternatives.md)).

## Turn it on

You need the gateway on (`apps.litellm`), the console pointed at it (the
shipped default), and an **embedding model on a local route**: a route derived
from one of your [inference nodes](inference-nodes.md), or a hand-written
`litellm.proxy_config.model_list` entry with `model_info.endpoint_tier: local`.

**1. Name the models** in `site/values/ai.yaml`:

```yaml
knowledge:
  enabled: true
  embeddingModel: local-embed       # a gateway alias on a local route
  embeddingDimensions: 1024         # what that model emits
  rerankModel: local-rerank         # optional: a local rerank alias
```

**2. Give the console a key for those models.** The console's own gateway key
is not reused: Open WebUI sends embedding requests with its own key setting, so
mint one scoped to the embedding and rerank aliases and store it in a Secret the
console reads (`tockmox-ai-knowledge-key`, an optional reference the chart
already carries):

```sh
# from a pod that can reach the gateway, with the master key in $MASTER
curl -s http://<release>-litellm:4000/key/generate \
  -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -d '{"key_alias":"open-webui-knowledge","models":["local-embed","local-rerank"],
       "object_permission":{"mcp_servers":["no-mcp-servers"]}}'

kubectl --context <cluster> -n <ai namespace> create secret generic tockmox-ai-knowledge-key \
  --from-literal=RAG_OPENAI_API_KEY=sk-... \
  --from-literal=RAG_EXTERNAL_RERANKER_API_KEY=sk-...
```

The `object_permission` line is what the [key policy](../usage/ai-plane.md)
asks of a new key when it is on; it is harmless when it is off. The console
reads the Secret when it starts, so restart it once after creating the Secret.
Until the Secret exists the gateway answers embedding requests with 401: nothing
is embedded, and nothing leaves.

**3. Sync**, and create a Knowledge base in the console (Workspace, Knowledge)
to upload into by hand, or follow [Sync from git](#sync-from-git).

### What the chart sets

| Setting | Value | Why |
|---|---|---|
| `RAG_EMBEDDING_ENGINE`, `RAG_OPENAI_API_BASE_URL`, `RAG_EMBEDDING_MODEL` | `openai`, this release's gateway, your alias | **The URL is set explicitly.** In Open WebUI 0.12.4 an unset `RAG_OPENAI_API_BASE_URL` is `https://api.openai.com/v1`, not the console's gateway, because `config.py` resets `OPENAI_API_BASE_URL` to that address after reading it. |
| `ENABLE_RAG_HYBRID_SEARCH`, `RAG_TOP_K`, `RAG_TOP_K_RERANKER` | `true`, 8, 8 | `hybridSearch`, `topK` |
| `RAG_RERANKING_ENGINE`, `RAG_RERANKING_MODEL`, `RAG_EXTERNAL_RERANKER_URL` | `external`, your alias, the gateway's `/v1/rerank` | only with `rerankModel`; the console's built-in reranker downloads its model from Hugging Face, which a Dark Site cannot do |
| `ENABLE_KNOWLEDGE_FILE_RETENTION` | `false` | a file removed from the source leaves the index |
| `BYPASS_RETRIEVAL_ACCESS_CONTROL` | `false` | asserted, not assumed |
| `CONTENT_EXTRACTION_ENGINE`, `DOCLING_SERVER_URL` | `docling`, `doclingUrl` | only when you run Docling for PDF and Office files; Markdown needs none |
| `VECTOR_DB` | `chroma` (default) or `pgvector` | see [Restore](#restore) |
| `ENABLE_API_KEYS`, `ENABLE_API_KEYS_ENDPOINT_RESTRICTIONS`, `API_KEYS_ALLOWED_ENDPOINTS` | `true`, `true`, `/api/v1/knowledge,/api/v1/files` | only with `sync.enabled`: the sync daemon signs in with an Open WebUI API key, and every API key on the console is limited to the Knowledge and file endpoints |

The chart sets these as environment, and the console runs with
`ENABLE_PERSISTENT_CONFIG=False`, so a change in the admin panel does not
outlive a restart: the values file is the record.

**What has been run, and what has not.** Open WebUI's reranker request,
through LiteLLM 1.106.6 and a route rendered from an inference node, reaches the
node's `/rerank` and comes back in the shape Open WebUI reads (checked with a
stand-in that answers like llama-server). Not yet run: a real llama-server
behind it, a live console, and the sync user procedure below.

## Sync from git

`knowledge.sync` runs [oikb](https://github.com/open-webui/oikb) (MIT, the Open
WebUI project's sync daemon) beside a git-sync container per source. git-sync
checks the repository out into a scratch volume; oikb reads that directory and
uploads only what changed. oikb never sees a forge credential, works with any
forge git-sync can clone, and the commit is the source of truth.

**1. A sync user.** In the console, create a local user that is not an admin
(Admin, Users, add a user), put it in a group that may create API keys (Admin,
Groups, the group's permissions), sign in as it once, create an API key
(Settings, Account), and store it:

```sh
kubectl --context <cluster> -n <ai namespace> create secret generic tockmox-knowledge-sync \
  --from-literal=api-key=sk-...
```

A non-admin key that leaks reaches that user's Knowledge bases and nothing
else, and the endpoint restriction above keeps it off chats and models.

**2. A Knowledge base per source**, created by the sync user (Workspace,
Knowledge), shared with the groups that should read it. Its id is in the
address bar.

**3. The images.** oikb publishes `ghcr.io/open-webui/oikb`, tagged `latest`;
mirror it (or build it from its Dockerfile) and pin the digest, as you do for
every image ([airgap](../deployment/airgap.md)). git-sync is
`registry.k8s.io/git-sync/git-sync`.

**4. The values:**

```yaml
knowledge:
  sync:
    enabled: true
    image: registry.example/oikb@sha256:...
    gitSyncImage: registry.example/git-sync@sha256:...
    sourceEgress:                     # who git-sync may reach: your forge, nothing else
      - to: [{ipBlock: {cidr: 10.0.0.20/32}}]
        ports: [{port: 443, protocol: TCP}]
    sources:
      - name: handbook
        repo: https://forge.example/acme/handbook.git
        ref: main
        path: docs
        knowledgeId: 7f3c...
        classification: internal      # public or internal; anything else is refused
```

The sync pod takes no connections (its NetworkPolicy admits nobody), reaches
the console and the hosts in `sourceEgress` only, runs with no service account
token, a read-only root and no capabilities, and oikb mounts the checkout
read-only. A private repository needs git-sync credentials, which this release
does not template: use a public or in-cluster read-only mirror, or extend the
Deployment in your site layer.

## What the chart refuses

Each refusal stops the render with a sentence naming the value, because each
guards a failure that is otherwise quiet.

| Refused | Because |
|---|---|
| A sync source classified `confidential` or `restricted` | a shared console's Knowledge grant is a convenience boundary |
| An embedding or rerank alias that is not on the production gateway, or not on a local route | every document would leave the site to be embedded or reranked |
| `vectorStore: pgvector` when the console is not on CloudNativePG | records and vectors would restore from two places at two points in time |
| A source with no `knowledgeId`, or two sources writing one Knowledge base | each sync would delete what the other added |
| Sync with no `sourceEgress` | git-sync could not reach the source, or would need an open egress rule to |
| Knowledge mode with the gateway off | it embeds through the gateway or not at all |

`tests/knowledge/render.sh` renders each refusal from a passing fixture with one
value changed, so a refusal that stops firing turns that test red.

## Restore

- **Default (Chroma).** Chat records, uploaded files and vectors are on the
  console's volume, one restore unit: restore the volume.
- **pgvector**, only when the console is on CloudNativePG
  (`modelGateway.upgradeBackup.openWebuiClusterName`): records, grants and
  vectors are in one database and restore from one base backup. The chart leaves
  the `vector` extension to the cluster (`PGVECTOR_CREATE_EXTENSION=false`).
- **Synced Knowledge bases** come back from git either way: restore the
  console, and the next sync uploads whatever is missing.

## Further reading

- [Frontend posture](../frontend-posture.md): why this is the one console
  feature Tockmox configures
- [The AI plane](../usage/ai-plane.md): the gateway, the key policy and the
  policy gate
- [Inference nodes](inference-nodes.md): local routes for the embedding and
  rerank models

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

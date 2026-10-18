---
okf_version: "0.2"
type: Reference
title: "Frontend posture: the console is a convenience, the gateway is the boundary"
description: "Why Open WebUI ships as a swappable reference console, which capabilities terminate outside it, its licence terms at the shipped version, and the replacement candidate Tockmox tracks."
tags: [ai-plane, open-webui, frontend, licensing, swappability, posture]
status: stable
generated:
  by: hand
  at: 2026-10-07
tockmox:
  classification: public
  audience: [operator]
---

# Frontend posture

**Open WebUI ships as the reference chat console, and Tockmox treats it as
replaceable.** Nothing Tockmox ships as a product capability depends on it.
Swap it for another console and the platform underneath keeps working.

| I want to | Go to |
|---|---|
| Know what I can rely on and what I cannot | [The four points](#the-four-points) |
| Check what stays behind if I replace the console | [What lives where](#what-lives-where) |
| Know the licence terms before a large deployment | [Licence](#3-the-licence-is-not-open-source) |
| Know what would replace it, and when | [Replacement candidate](#4-a-replacement-is-tracked-not-adopted) |

## The four points

### 1. Included for convenience, not relied on

The `tockmox-ai` layer vendors the upstream Open WebUI chart as a dependency,
switched by `apps.openWebui.enabled` (`charts/tockmox-ai/Chart.yaml`). Whether
it stays in the product is decided around 1.0. Until then, no change adds
coupling to Open WebUI-specific features. The console is held at its upstream
image, unmodified (`charts/tockmox-ai/values.yaml`, `open-webui:` block).

### 2. The boundary is the gateway, identity and the database

Every capability Tockmox ships terminates outside the console:

| Capability | Where it terminates | Checked against |
|---|---|---|
| Model access, scoped keys, revocation, request log | LiteLLM, the model gateway | `charts/tockmox-ai/values.yaml` (the console is pointed at the gateway with a virtual key in `tockmox-openwebui-gateway`) |
| Routing policy and the audit line | LiteLLM's policy gate (`modelGateway.policyGate`) | [The AI plane](usage/ai-plane.md) |
| Sign-in (OIDC) | Authentik | `charts/tockmox-ai/values.yaml` (`OAUTH_CLIENT_SECRET` from `tockmox-sso-openwebui`), [Identity](administration/identity.md) |
| Gateway keys and spend state | The gateway's Postgres database | [The AI plane](usage/ai-plane.md) (backups of the gateway database) |
| Document retrieval (RAG) and private search | Planned as separate services, not console features; neither ships today | [The AI plane](usage/ai-plane.md#intended-components) |

**The exception you control.** The console can also be pointed straight at a
model host. That is supported, but it skips the gateway, so there is no
per-console key, no revocation, no request log and no policy gate
(`charts/tockmox-ai/values.yaml`, the `NO CLOUD BACKEND BY DEFAULT` note). Use
the gateway path if you want the boundary to hold.

#### What lives where

Replacing the console takes these with it, because they are the console's own
state:

- chat history and the console's own user table, on its data volume
  (`open-webui.persistence` in `charts/tockmox-ai/values.yaml`)
- files a user uploads into a chat, and any document index Open WebUI builds
  from them. That is upstream behaviour Tockmox neither configures nor relies on:
  the chart sets no retrieval or vector-store variable for it
  (`charts/tockmox-ai/values.yaml`, `extraEnvVars`)

Model configuration does **not** go with it: the console reads its settings from
the chart, not from its own database (`ENABLE_PERSISTENT_CONFIG=False` in
`charts/tockmox-ai/values.yaml`).

### 3. The licence is not open source

The Open WebUI version this release ships is `0.12.3`
(`ghcr.io/open-webui/open-webui:0.12.3`, `charts/tockmox-ai/values.yaml`). Its
`LICENSE` at the
[`v0.12.3` tag](https://github.com/open-webui/open-webui/blob/v0.12.3/LICENSE),
checked 2026-10-17 (byte-identical to `v0.12.0`, checked 2026-10-11, and
unchanged from `v0.11.3`, checked 2026-10-07), is
BSD-3-Clause with an added branding clause:

- You may not alter, remove, obscure or replace the "Open WebUI" branding.
- That restriction does not apply if no more than 50 end users use the
  deployment in any rolling 30-day period, if you have prior written
  permission from the copyright holder, or if you hold an enterprise licence
  that permits it.
- Altering the branding outside those exceptions is a material breach of the
  licence.

Tockmox ships the console with its branding intact. If your deployment will go
above 50 users and you want to change how the console looks, the obligation is
yours, not Tockmox's, and Tockmox cannot waive it. The wider licence table is
in [Third-party licenses](third-party-licenses.md).

### 4. A replacement is tracked, not adopted

The candidate is [LibreChat](https://github.com/danny-avila/LibreChat), under
the MIT licence (its `LICENSE` on `main`, checked 2026-10-07). Nothing migrates
until one of two triggers fires:

- LibreChat's role-based access control matures enough to replace the
  console's own, or
- a deployment needs a white-label console that Open WebUI's branding clause
  does not allow.

Either trigger opens a decision, recorded before any migration starts. The
boundary in point 2 is what keeps that migration small: only the console moves.

## Further reading

- [The AI plane](usage/ai-plane.md): pointing the console at the gateway, and
  what the policy gate does and does not enforce
- [Third-party licenses](third-party-licenses.md)
- [Architecture](architecture.md)

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

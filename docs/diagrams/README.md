---
okf_version: "0.2"
type: Reference
title: "Diagrams"
description: "The visual vocabulary of the Tockmox architecture diagrams, where each one is used, and how to regenerate them from source."
tags: [diagrams, svg, documentation, accessibility]
status: draft
generated:
  by: hand
  at: 2026-10-27
tockmox:
  classification: public
  audience: [contributor]
---

# Diagrams

The architecture diagrams are SVG files generated from one Python script, so a
change to a diagram is a reviewable change to source, never an edited image.

| File | What it is for |
|---|---|
| `source/gen_diagrams.py` | The generator. Standard library only, no network. Every label is written in it |
| `rendered/*.svg` | Its output. Committed, so GitHub and the documentation site show it without a build step |

## Regenerate

From the repository root, `python3 docs/diagrams/source/gen_diagrams.py`
rewrites `rendered/`. With `--check` it changes nothing and exits non-zero when
a committed SVG differs from a fresh render, or when the layer stack's waves
disagree with `tockmox.com/sync-wave` in `charts/*/Chart.yaml`. The check is not
wired into CI yet.

## What each diagram shows, and where it is used

| Diagram | Shows | Used on |
|---|---|---|
| `platform-overview.svg` | The AI plane inside your control boundary, the platform around it, the foundation you provide, and the frontier route outside | [README](../../README.md), [architecture](../architecture.md) |
| `gitops-model.svg` | Product repository, site repository, Argo CD and the cluster, and who owns which | [architecture](../architecture.md) |
| `layer-stack.svg` | The nine layers in their six sync waves, and which can be declined | [architecture](../architecture.md) |
| `ai-request-path.svg` | Where a chat request goes, what is blocked, and where data leaves your network | [README](../../README.md), [the AI plane](../usage/ai-plane.md) |
| `install-journey.svg` | Prepare, generate, bootstrap, reconcile, configure, use, and the side branches only some sites need | [deployment index](../deployment/README.md) |

## Visual vocabulary

| Element | Means |
|---|---|
| Solid outline around a region | A trust or ownership boundary |
| Dashed box | Optional, off by default, or outside your control |
| Solid arrow | Normal flow |
| Dashed arrow | Optional or configured flow, which exists only once you set it up |
| Green | Local, yours, and the proven path |
| Amber | Optional, or an explicit choice you make |
| Red ring | Data crosses a boundary and leaves your network |
| Red cross | A path that policy blocks |
| Blue | GitOps and control |
| Neutral | An ordinary internal component |

Colour never carries meaning on its own: every coloured element also has a
label, a line style or a legend entry.

## Rules for a diagram

- **Labels come from the current documentation**, and the page each diagram
  illustrates is named beside its function in the generator. A label that page
  does not support is a bug.
- **A diagram never shows a capability the docs do not claim**, and shows the
  boundary in the same picture as the claim.
- **Every SVG carries `<title>` and `<desc>`**, every embedding carries real alt
  text, and the page that embeds a technical diagram carries a text equivalent
  in prose.
- **No external fetch.** The system font stack, no web fonts, no linked images.
  The documentation site's offline gate reads SVGs too.
- **An explicit background**, so the diagram reads the same in GitHub's light
  and dark modes and on the documentation site.
- **Embed with Markdown image syntax** on pages under `docs/`. The documentation
  site copies an image only when a page links it that way.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

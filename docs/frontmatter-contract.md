---
okf_version: "0.2"
type: Reference
title: "Frontmatter contract"
description: "What metadata every page under docs/ carries, why docs/ is the boundary, and where the flattened form is produced."
tags: [frontmatter, okf, metadata, contract]
status: stable
generated:
  by: hand
  at: 2026-08-25
tockmox:
  classification: public
  audience: [contributor, machine]
---

# Frontmatter contract

**The corpus is `docs/**/*.md` and nothing else**, because `docs/` is the OKF
bundle. That is the whole boundary rule; everything below follows from it.

Tockmox adopted the [Open Knowledge Format](https://raw.githubusercontent.com/GoogleCloudPlatform/knowledge-catalog/main/okf/SPEC.md)
(OKF), Apache-2.0, and this bundle targets **v0.2**.

> Cite the raw `SPEC.md` above, pinned. The polished site at `okf.md` is
> unofficial and has been stale since v0.1; it is the first thing a searching
> agent finds and it will tell you the wrong version.

## Why `docs/` and not the whole tree

Two existing gates disagree about what "the docs" means, deliberately:

| Gate | Corpus |
|---|---|
| `tools/stamp-docs.sh` | `docs/**/*.md` |
| `tools/check-docs-style.sh` | every tracked markdown file |

The table carries no page counts on purpose. `tools/stamp-docs.sh --check`
prints how many pages it stamps, and `tools/check-all.sh` runs it, so the
script is the authority and a number copied here would only drift.

This contract matches `stamp-docs.sh` exactly rather than inventing a third
population. The reasoning is already written in that script's own comment: the
top-level README is the project's front page and is hand-composed, and LICENSE,
NOTICE and the community files are legal texts that must not grow generated
furniture.

Scoping the bundle to `docs/` also gives `okf_version` somewhere to mean
something. OKF conformance is a claim about a **bundle**, not about every file
in a repository that happens to contain one.

**The cosmetic cost, stated rather than discovered.** This repository has no
mkdocs config, so **GitHub is a real rendering surface**, and GitHub renders a
frontmatter block as a table at the top of the page. Thirty-four pages gain
that table. That is the price of machine-readable metadata here, and it is why
the block is kept short.

**A third population exists and must not become a fourth boundary.** The
published user docs site copies a *subset* of `docs/` and carries neither
`docs/assets` nor the repository root. Any future tooling scopes to `docs/` or
states plainly why it does not.

## The block

Upstream OKF keys first. Tockmox extensions go under `tockmox:` and nowhere
else.

```yaml
---
okf_version: "0.2"
type: Reference
title: "Air-gapped installation"
description: "One sentence. What the page is for, not what it contains."
tags: [airgap, deployment, mirror]
status: stable
generated:
  by: hand
  at: 2026-08-25
tockmox:
  classification: public
  audience: [operator]
---
```

| Key | Required | Notes |
|---|---|---|
| `okf_version` | yes | Quoted string. `"0.2"` for this bundle |
| `type` | yes | OKF resource type. Most pages here are `Reference` or `HowTo` |
| `title` | yes | Human title. Does not have to match the H1, and usually should |
| `description` | yes | One sentence, no trailing period needed. This is what a retrieval layer shows |
| `tags` | yes | Flat list of lowercase scalars. No nesting |
| `status` | yes | `draft`, `stable` or `deprecated`. Upstream v0.2 key |
| `generated.by` | yes | What produced the page. `hand` for authored pages, the tool name for generated ones |
| `generated.at` | yes | ISO date. **v0.2 supersedes the v0.1 `timestamp` key** |
| `tockmox.classification` | yes | ADR-0018 label. Every page in this bundle is `public` |
| `tockmox.audience` | no | Flat list. `operator`, `contributor`, `machine` |
| `sources` | no | v0.2 list, replacing a body `## Sources` heading. Research pages only |

**`classification` is not decoration.** ADR-0032 makes it the key that decides
which corpus a document belongs to, so an ingest allow-list filters on it. A
page without it cannot be placed. Everything in a published bundle is `public`;
the key still has to be present, because "absent" and "public" must not be the
same thing to a filter.

**Do not duplicate an upstream key into `tockmox:`.** `status` is upstream, so
there is no `tockmox.status`. Anything OKF already names wins.

## Nested to author, flat to ingest

**Nested `tockmox:` is the authoring form. Flattened `tockmox_*` scalars are
produced at ingest, never written by hand.**

Both exist because they solve different problems and neither one solves both:

- **Nested survives generator churn.** It is the same pattern Hugo uses for
  `params:` and Docusaurus for `sidebar_custom_props`: one namespaced map that
  a static-site generator will never collide with.
- **Flat scalars survive retrieval.** Vector-store metadata filters want flat
  scalars. LangChain's frontmatter-aware loader calls `str()` on anything that
  is not `str`, `int` or `float`, so a nested map arrives as the literal string
  `"{'classification': 'public'}"` and cannot be filtered on at all.

The flattening is about forty lines and runs in the ingest path. Measured
across a 298-file corpus: 0 parse failures, 23 distinct flat keys produced,
zero non-scalar leaks.

Ingest also **prepends** the metadata to the embedded text and strips the
frontmatter block, so the block stops being chunk noise. Prefix placement beats
suffix on structured, repetitive corpora, which is exactly what a docs tree is.

## Shape rules that keep the gate simple

The permitted shape is deliberately small, so validating it does not need a
full YAML engine or a new CI dependency:

- One block, at the very top of the file, delimited by `---` on its own line.
- Scalars, flat lists of scalars, and **one** level of nesting under
  `generated:` and `tockmox:`. Nothing deeper.
- No multi-line strings, no anchors, no aliases.
- Quote anything containing `:` or starting with a digit.

## Links stay file-relative

OKF section 6.1 recommends bundle-relative absolute links. **Do not follow it
here.** Upstream commit `4c40ef10` moved the reference agent, the viewer and
every checked-in bundle to file-relative links because `/`-prefixed links 404
on GitHub, and the v0.2 spec text was never updated to match. Emit
file-relative.

## Coexistence with the footer stamp

`tools/stamp-docs.sh` rewrites a marker block at the **bottom** of every page in
this same corpus. The two do not interact: frontmatter is above the first line
of content, the stamp is below the last. Neither tool should ever need to know
about the other, and if one starts rewriting the other's territory that is a
bug rather than a feature.

## What the gate checks, and what it does not

`tools/check-frontmatter.sh` validates every page under `docs/` that HAS a
block, and reports coverage for those that do not.

It fails on: a malformed block, a missing required key, an unknown top-level
key, a `tockmox:` key that duplicates an upstream one, nesting deeper than one
level, and a coverage count below the floor recorded in the script.

It does not fail on a page that has no frontmatter yet, until the floor is
raised. **The floor only goes up.** That is the same ratchet
`tools/check-airgap.sh` uses, for the same reason: a gate that goes red on the
day it lands teaches people to disable it.

**Migration state, 2026-09-01: 25 of 41 pages carry a block.** The floor in
`tools/check-frontmatter.sh` is 25 to match. Raise it as pages are migrated; a
count in prose is exactly the kind of claim that rots, so trust the gate's own
output over this sentence.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

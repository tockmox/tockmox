---
okf_version: "0.2"
type: Reference
title: "Feature pages"
description: "How to let a feature contribute pages to the Tockmox UI by serving JSON page documents that the console draws with its own components."
tags: [tockmox-ui, feature-pages, extension, experimental]
status: draft
generated:
  by: hand
  at: 2026-11-05
tockmox:
  classification: public
  audience: [operator, developer]
---

# Feature pages

A feature listed under the console's `features.<id>` config may contribute pages. The console fetches each page as a JSON page document from the feature's own read API and draws it with the console's own components. The feature ships data only: no HTML, script, style, or template from the feature runs in the console's origin, and the console refuses any document that does not match the format exactly.

Feature pages are experimental. The config keys, the document format, and the limits can change between releases.

This is the first slice of the console's feature contributions. The other contribution kinds in the UI spec (stack parts, health inputs, settings, and retiring a Home tile) are not drawn yet.

## Turn it on

Add the feature to the UI's config. With the Helm chart, the same keys go under `tockmoxUi.config.features.<id>`.

```yaml
features:
  delivery:                         # feature id: lowercase letters, digits, hyphens (max 32)
    enabled: true
    name: Delivery                  # section label and rail heading
    adminOnly: true                 # default true; false lets signed-in members see it too
    origin: private                 # optional; the only value is private
    apiUrl: http://pages.example.svc:8080/s/example
    tokenFile: /etc/tockmox-ui/features/delivery/token
    contributes:
      section: true                 # its own top-bar section after Platform, OR:
      # rail: {section: platform, group: Delivery}
      pages:                        # 1 to 12 pages
        - {id: flow, title: Flow}
        - {id: board, title: Board}
```

| Key | Required | Meaning |
|---|---|---|
| `enabled` | yes | Turns the feature's pages on or off. |
| `name` | no | The section label and rail heading. Defaults to the feature id. |
| `adminOnly` | no | Defaults to `true`. Set `false` to let signed-in members see the pages. |
| `origin` | no | The only value is `private`. See [Release markers](#release-markers). |
| `apiUrl` | when enabled | Base address of the read API. |
| `tokenFile` | no | Absolute path to a file holding a bearer token. |
| `contributes.section` | one of two | `true` gives the feature its own top-bar section. |
| `contributes.rail` | one of two | `{section, group}` puts the pages in the AI or Platform rail under `group`. Admins only: a feature with `adminOnly: false` takes `section: true`, because members have no AI or Platform section. |
| `contributes.pages` | yes | The page list: an `id` (lowercase slug) and a `title` for each. |

Turning the feature off (`enabled: false`) removes its pages. They return 404 and are absent from navigation. They are not shown as locked.

### Start-up checks

The UI refuses to start if the config is wrong, so a typo fails the deploy and not a page view. It refuses on any of these:

- an unknown key under `contributes`
- both `section` and `rail`, or neither
- a `rail.section` other than `ai` or `platform`, or a `rail` on a feature with `adminOnly: false`
- a third feature with `section: true`
- a page id that is not a slug, or that appears twice
- `enabled` with no `apiUrl`
- on a feature with pages, an `origin` other than `private`, or a relative `tokenFile`
- an application with the id `f` while any feature has pages, because the console then owns `/f/`

A feature without `contributes` is not affected by any of these checks.

### Token and egress with the Helm chart

The chart does not mount a token file for a feature in this release. Until it does, a read API reached from the chart's console either takes no token or uses a file the console already has. Keep such an API on the cluster network and limit who can reach it with its own NetworkPolicy.

The console's NetworkPolicy allows only the addresses it knows. The read API belongs to your site, so add its address to `tockmoxUi.networkPolicy.extraEgress`. Without that entry the fetch fails and the page reads as Unknown with an unreachable reason.

## Where the pages appear

| Setting | Result |
|---|---|
| `contributes.section: true` | A top-bar section after Platform. At most two features may do this. |
| `contributes.rail` | The pages are listed in the AI or Platform rail under the given group heading. |

Each page has the address `/f/<feature id>/<page id>`. The address `/f/<feature id>` redirects (303) to the feature's first page. "Help for this page" on a feature page links to this document.

With `adminOnly: true`, only administrators see the section, the rail items, and the pages. With `adminOnly: false`, any signed-in member does.

### Release markers

`origin: private` shows the word "Private" beside the section label, on every rail item, and in the page heading. The marker is a word, in copper trim, so it never relies on colour alone. It marks a maintainer's own extension that is not part of the open-source project. An open-source install never sets it.

## Writing a read API

### The request

The console sends one request per page:

```
GET <apiUrl>/pages/<page id>
Accept: application/json
Accept-Encoding: identity
Authorization: Bearer <token>
```

The `Authorization` header is sent only when a token is configured. The request uses the console's source timeout (`sources.timeoutSeconds`) for each read and for the whole answer, does not follow redirects, refuses a compressed answer, and reads at most 1,000 kB. Answers are cached for 30 seconds per page; the page's age and staleness are worked out when it is drawn, not when it was fetched.

### The response

Answer `200` with a JSON document in the `tockmox.page/v1` format. Any other status is a failure. Unknown keys anywhere in the document are refused.

Top-level keys:

| Key | Required | Meaning |
|---|---|---|
| `format` | yes | Must be `"tockmox.page/v1"`. |
| `title` | yes | Page title, up to 120 characters. |
| `lede` | no | Introductory text, up to 600 characters. |
| `generated_at` | yes | UTC time in the form `2026-11-05T06:00:00Z`. |
| `source` | yes | Up to 80 characters. Shown as "From `<source>`, generated `<age>`". |
| `stale_after_s` | no | Number of seconds. An older document shows a Stale badge and says to read it as of its own time. |
| `blocks` | yes | Up to 40 blocks. |

### Block types

| Block | Keys |
|---|---|
| `stats` | `title?`, `items` (1 to 12): `label`, `value` (number, text, or `null` shown as a dash), `unit?`, `note?`, `state?`, `delta?`, `better?` |
| `chart` | `title`, `kind` (`line` or `bar`), `unit?`, `x` (1 to 104 labels), `series` (1 to 6): `name`, `values`, `describe?` |
| `table` | `title?`, `caption?`, `columns` (1 to 12; a string or `{label, align}`), `rows` (up to 500, one cell per column) |
| `lanes` | `title?`, `lanes` (1 to 8): `label`, `state?`, `empty?`, `items` (up to 200): `text`, `href?`, `meta?`, `tag?`, `state?` |
| `note` | `title?`, `text`, `state?` |

A `state` is one of `ok`, `warning`, `critical`, `unknown`, or `neutral`. The `better` key is `up` or `down` and says whether a rise is good. The `delta` then reads in words as better or worse, with an arrow, for example "+5 vs last week". A table cell is text, a number, or `{text, href?, state?, mono?, note?}`. A cell with a `state` shows a status badge carrying its text. A lane item's `tag` is a short id shown in monospace.

### A complete minimal example

```json
{
  "format": "tockmox.page/v1",
  "title": "Delivery flow",
  "lede": "Open changes and recent deploys for the example service.",
  "generated_at": "2026-11-05T06:00:00Z",
  "source": "pages.example.svc",
  "stale_after_s": 3600,
  "blocks": [
    {
      "type": "stats",
      "title": "This week",
      "items": [
        {"label": "Open changes", "value": 14, "unit": "changes",
         "state": "warning", "delta": 5, "better": "down"},
        {"label": "Last deploy", "value": "passed", "state": "ok",
         "note": "Rolled out to all regions."}
      ]
    },
    {
      "type": "chart",
      "title": "Deploys per day",
      "kind": "bar",
      "unit": "deploys",
      "x": ["Mon", "Tue", "Wed", "Thu"],
      "series": [
        {"name": "example-api", "values": [3, 5, null, 4]}
      ],
      "describe": "Deploys rose on Tuesday. Wednesday has no data."
    },
    {
      "type": "table",
      "title": "Recent deploys",
      "caption": "The last three deploys, newest first.",
      "columns": ["Change", {"label": "Minutes", "align": "end"}, "Result"],
      "rows": [
        [{"text": "CH-121", "mono": true, "href": "/f/delivery/board"},
         12,
         {"text": "passed", "state": "ok"}],
        [{"text": "CH-119", "mono": true, "href": "https://example.com/changes/119"},
         31,
         {"text": "rolled back", "state": "critical", "note": "Health check failed."}]
      ]
    },
    {
      "type": "lanes",
      "title": "Board",
      "lanes": [
        {"label": "In review", "state": "warning",
         "items": [
           {"text": "Add retry to export", "href": "https://example.com/changes/118",
            "meta": "opened 2 days ago", "tag": "CH-118", "state": "neutral"}
         ]},
        {"label": "Blocked", "empty": "Nothing is blocked.", "items": []}
      ]
    },
    {
      "type": "note",
      "title": "Reading this page",
      "text": "Counts cover the example service only.",
      "state": "neutral"
    }
  ]
}
```

### Rules

- Text is always text. The console escapes every string, and there is no markup.
- A link (`href`) is either an `https://` or `http://` address with a named host (not an IP address), or a console path starting with `/`. A link may not include `user@`, a leading `//host`, backslashes, or spaces.
- A table cell with a `state` carries no link: give the link its own column.
- Any other link, such as `javascript:` or `data:`, refuses the whole document.
- Numbers must be finite and no larger than 10^15 either way. `NaN`, infinity, and `true` or `false` are not numbers.
- Every block names its kind in `type`: `stats`, `chart`, `table`, `lanes` or `note`.
- A chart `series` has one value per `x` label. A `null` value is drawn as a gap and never as zero.
- A table row has one cell per column.
- A chart is drawn as SVG that screen readers skip. A hidden text alternative carries every value, and the legend shows each series' latest value. Use `describe` to add a summary.

## When a page cannot be drawn

Every failure reads as Unknown, with the reason in words. A failed fetch never shows as an empty page.

| Cause | What the page says |
|---|---|
| HTTP status is not 200 (this includes redirects, which are not followed) | Unknown, with the status as the reason. |
| Response is not JSON | Unknown, with a reason that the answer is not JSON. |
| Response is larger than 1,000 kB, or compressed | Unknown, with a reason that says which. |
| Read API is unreachable, or the whole answer takes longer than the timeout | Unknown, with an unreachable or too-slow reason. |
| Token file is missing or unreadable | Unknown, with a reason that the token file cannot be read. |
| Document is not in the format | Unknown. The reason names the path of the first problem, for example `page.blocks[3].rows[0][0].href is not a link this page may carry`. |
| Document is older than `stale_after_s` | The page is drawn with a Stale badge and says to read it as of its generation time. |
| Feature is turned off | The page is absent and its address returns 404. |

## Security model

The console never does the following with a document:

- run script, or load HTML, style, or templates from the feature
- treat any string as markup
- follow a link scheme other than `https:`, `http:`, or a console path
- follow a redirect from the read API
- read more than 1,000 kB from one answer
- draw a document that has an unknown key or a value outside the format

The read API token is sent only to the feature's own `apiUrl`. Keep it in a Secret, and give the read API read-only access to whatever it reports on.

Visibility follows `adminOnly`. By default only administrators see the feature's section, rail items, and pages. Setting `adminOnly: false` shows the page content to every signed-in member, so check that a document holds nothing members should not read.

## Limits

| Item | Limit |
|---|---|
| Feature id | Lowercase letters, digits, hyphens; up to 32 characters |
| Features with `section: true` | 2 |
| Pages per feature | 1 to 12 |
| Page title in config | 1 to 40 characters |
| Document title | 120 characters |
| `lede` | 600 characters |
| `source` | 80 characters |
| Blocks per page | 40 |
| Stats items | 1 to 12 |
| Stat `label` | 60 characters |
| Stat text `value` | 40 characters |
| Stat `note` | 160 characters |
| Chart `x` labels | 1 to 104, each up to 20 characters |
| Chart series | 1 to 6 |
| Chart `describe` | 600 characters |
| Table columns | 1 to 12 |
| Table rows | 500 |
| Lanes | 1 to 8 |
| Items per lane | 200 |
| Note `text` | 2000 characters |
| Response size | 1,000 kB |
| Any number | 10^15 either way |
| Cache time | 30 seconds per page |
| Fetch timeout | `sources.timeoutSeconds` |
| Redirects followed | 0 |

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

<!-- SPDX-License-Identifier: Apache-2.0 -->
# tockmox-ui-kit

The shared UI standard for every Tockmox app surface: the design tokens, one stylesheet, the page
shell and the status macros, and the fonts they load. Each app serves its own pinned copy, so no app
depends on another at runtime and nothing is fetched from another origin (Dark Site).

| Path | What it is |
|---|---|
| `static/tockmox-tokens.css` | Brand tokens v2.1 (palette, `--tx-font-ui`). Load first. |
| `static/kit.css` | Type (Source Sans 3, 14px base), the shell (top bar, underline tab row, footer), panels, controls, the status badges, the source line, folds, tables, stat tiles. Load second; the app's own stylesheet adds to it. |
| `static/fonts/` | Source Sans 3 400/600/700 and JetBrains Mono 400, latin woff2, each with its SIL Open Font License. `kit.css` loads them by relative URL. |
| `templates/kit/shell.html` | The page frame. An app's base template extends it and fills `title`, `head`, `brand`, `site`, `nav`, `who`, `main` and `foot`. It reads `kit_static` (where the app serves the kit's `static/`), `asset_v`, `site_name` and `home_href`. |
| `templates/kit/macros.html` | `state_icon`, `state_word`, `badge`, `source_line`, `fold_summary`: one status language (shape, word and colour, never colour alone) and one source-line format. |
| `tools/ui_kit.py` | `vendor` copies the kit into an app and records each file's sha256 in `ui-kit.json`; `check` proves the copy is unedited and, given `--source`, current. |
| `tools/contrast_report.py` | WCAG ratios for every pair the kit's components use, dark and light. Apps keep their own report for the pairs they add. |

## Page rules the kit is built for

Exceptions first, and healthy groups fold to a count. One answer at the top of a page, then the
evidence. Tables for sets; cards only for things you open. One action zone per page and one per row.
One state vocabulary: OK, Warning, Problem, Unknown. Identifiers truncated, never URLs printed under
a link. One density: 14px text, 36px rows, 16px panel padding. Chat is not boxes.

## Using it in an app

```sh
python3 ui-kit/tools/ui_kit.py vendor --static <app>/static/kit --templates <app>/templates/kit
python3 ui-kit/tools/ui_kit.py check  --static <app>/static/kit --templates <app>/templates/kit
```

Change the kit here, bump `VERSION`, and re-vendor; never edit a vendored copy in place (the check
fails on it). The Tockmox UI (`tockmox-ui/`) vendors it into `app/static/kit` and
`app/templates/kit`, and its test suite runs both the check and the contrast report.

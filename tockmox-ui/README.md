<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Tockmox UI source

The admin console the AI layer runs when `tockmoxUi.enabled` is set. Experimental
in 0.8.0. Tockmox publishes no image: you build this directory and name the
result in `tockmoxUi.image`. Everything an operator needs is in
[docs/administration/tockmox-ui.md](../docs/administration/tockmox-ui.md).

| Path | What |
|---|---|
| `Dockerfile` | the build recipe, run from the repository root; the image runs as 65534 with a read-only root filesystem |
| `app/` | the FastAPI application; there is deliberately no route that writes to the cluster, to git or to a node |
| `app/static/kit/`, `app/templates/kit/` | the vendored [UI kit](../ui-kit/README.md): tokens, `kit.css`, the page shell and status macros, and the fonts (Source Sans 3 and JetBrains Mono, each with its SIL Open Font License). Re-vendor with `ui-kit/tools/ui_kit.py`; the tests fail on a copy edited in place |
| `app/static/brand/` | the lockups, favicon and mascot; the display face is outlined in the lockup SVG, so no font file ships for it |
| (repository) `CHANGELOG.md` | copied in at build time so the release notes of the tag you built render with no network |
| `requirements.txt` | the Python dependencies the build installs |
| `config.example.yaml` | the shape of the config the chart renders; not read by a real install |

`tests/` holds its unit tests (FastAPI's TestClient, every upstream mocked);
`tools/check-tockmox-ui-tests.sh` runs them, in CI and in `check-all.sh`. The lab
harness is not in this directory; the release notes of the version you build say
what was proven on a cluster, and where.

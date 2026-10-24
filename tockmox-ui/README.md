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
| `app/static/brand/fonts/` | Source Sans 3 (the UI face since 2026-10-23, TM-1127) and JetBrains Mono, each with its SIL Open Font License beside it. Inknut Antiqua and Nunito Sans woff2 remain until the operator removes them: the UI no longer references them (the wordmark is outlined paths in the lockup SVG) |
| (repository) `CHANGELOG.md` | copied in at build time so the release notes of the tag you built render with no network |
| `requirements.txt` | the Python dependencies the build installs |
| `config.example.yaml` | the shape of the config the chart renders; not read by a real install |

`tests/` holds its unit tests (FastAPI's TestClient, every upstream mocked);
`tools/check-tockmox-ui-tests.sh` runs them, in CI and in `check-all.sh`. The lab
harness is not in this directory; the release notes of the version you build say
what was proven on a cluster, and where.

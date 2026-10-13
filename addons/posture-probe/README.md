<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Security Posture Probe add-on

Experimental in 0.8.0 and off by default. The documentation is
[docs/administration/posture-probe.md](../../docs/administration/posture-probe.md).

| Path | What |
|---|---|
| `chart/` | the Helm chart; install it on its own, it is not a layer |
| `Dockerfile`, `posture_probe/` | the image the site builds; stdlib only |
| `schema/report-v0.schema.json` | the published report contract |
| `run-now.sh` | run once as your own identity and copy the report out |
| `tests/` | unit tests; `tools/check-posture-probe.sh` runs them with the render checks |

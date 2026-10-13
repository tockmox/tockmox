#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Asserts exactly which images `global.imageRegistry` redirects, and holds that
# set steady ... the FALLBACK air-gap mechanism, not the primary one.
#
# WHICH MECHANISM IS PRIMARY. A node-side containerd mirror
# (`/etc/rancher/k3s/registries.yaml` on k3s) rewrites every pull below the
# manifest, so it covers every image regardless of what any chart reads. The
# 2026-08-25 greenfield air-gap install ran with `global.imageRegistry` EMPTY
# and pulled all 44 images through the node mirror. docs/deployment/airgap.md
# §2 leads with the node mirror for that reason and presents the values key as
# the fallback for sites that cannot configure the node runtime.
#
# WHAT THIS GATE MEASURES, first measured 2026-08-15. Setting
# `global.imageRegistry` redirected 4 images and left 21 pointing at docker.io,
# ghcr.io, quay.io and registry.k8s.io. The key works exactly as written ... the
# `tockmox.image` helper honours it ... but that helper is only reachable from
# Tockmox-authored templates, and every vendored subchart resolves its own image
# through its own key, with a different path per chart. A site on the fallback
# path has to wire each of those keys by hand, and it can only do that if the
# list of images the key does not reach is exact and current. That is what the
# exemption list below is for.
#
# WHY AN EXEMPTION LIST RATHER THAN A FAILING BUILD. The entries are a
# DOCUMENTED LIMITATION of the fallback, not a burn-down backlog: with the node
# mirror as the primary mechanism there is no plan to chase fifteen upstream
# charts' registry keys, and the list is expected to persist. What the gate
# guarantees is that the documented set is the true set.
#
# The list below is therefore a RATCHET in both directions: every entry is a
# known gap, recorded with the chart that owns it, and the gate fails on
# anything NOT on the list, so a new component cannot quietly join the set the
# docs describe. It also fails on an entry that is no longer needed, so a chart
# that starts honouring the key cannot stay listed and hide a later regression.
# If the list ever empties, delete it and this paragraph.
set -euo pipefail

cd "$(dirname "$0")/.."
# The image extractor, shared with gen-images.sh. Sourced rather than copied:
# the two used to carry the pipeline twice and the copies had drifted apart on a
# GNU-only regex (TM-0646). Prove it with `bash tools/lib/extract-images.sh --selftest`.
. "$(dirname "$0")/lib/extract-images.sh"
SENTINEL="airgap-check.invalid"
VALUES="${VALUES:-ci/values.yaml}"
# THE ALL-ON OVERLAY IS PART OF THE SCOPE, added 2026-09-13. `ci/values.yaml`
# deliberately enables apprise and litellm so their images land in the
# inventory, but leaves capabilities.hardwareTelemetry off, as it ships. The
# result: snmp-exporter and smartctl-exporter never rendered, so they were
# absent from the EXEMPT list below ... and this gate's whole promise is that
# "the documented set is the true set", which airgap.md §2 tells a
# fallback-path site to wire by hand. Two images it must wire were missing from
# the list for as long as the capability has existed. A gate whose render omits
# a shipped capability is describing a product nobody installs.
VALUES_OVERLAY="${VALUES_OVERLAY:-ci/values-all-on.yaml}"
LAYERS=(crds platform policy identity observability exporters ai devops selfcheck)

# ---------------------------------------------------------------------------
# KNOWN NOT REDIRECTED by `global.imageRegistry`, as of 2026-08-15. Each line:
# the image, and the chart whose own registry key a fallback-path site has to
# wire for it. Keep this EXACT; it is what airgap.md §2 tells that site to
# expect.
#
# ONE ENTRY IS NOT AN UPSTREAM IMAGE. registry.example/tockmox/tockmox-ui is
# the CI stand-in (ci/values-all-on.yaml) for the Tockmox UI's image, which
# the site builds and names IN FULL in tockmoxUi.image, already in its own
# registry (tockmox-ui.md, "Build the image"). Redirecting a reference the site
# wrote would be wrong, so the chart does not; the gate first saw the UI when
# the all-on overlay turned it on (TM-1013).
# ---------------------------------------------------------------------------
EXEMPT="
busybox
docker.io/grafana/alloy
docker.io/traefik
ghcr.io/berriai/litellm-database
ghcr.io/cloudnative-pg/cloudnative-pg
ghcr.io/cloudnative-pg/plugin-barman-cloud
ghcr.io/goauthentik/server
ghcr.io/kubereboot/kured
ghcr.io/open-webui/open-webui
quay.io/argoproj/argocli
quay.io/argoproj/workflow-controller
quay.io/jetstack/cert-manager-cainjector
quay.io/jetstack/cert-manager-controller
quay.io/jetstack/cert-manager-startupapicheck
quay.io/jetstack/cert-manager-webhook
quay.io/metallb/controller
quay.io/metallb/speaker
quay.io/prometheus-operator/prometheus-config-reloader
quay.io/prometheus/snmp-exporter
redis
registry.example/tockmox/tockmox-ui
registry.k8s.io/sig-storage/snapshot-controller
"

fail=0
echo "== rendering every layer with global.imageRegistry=$SENTINEL =="
ALL=$(for l in "${LAYERS[@]}"; do
  out=$(helm template t "charts/tockmox-$l" -f "$VALUES" \
        ${VALUES_OVERLAY:+-f "$VALUES_OVERLAY"} \
        --set "global.imageRegistry=$SENTINEL" 2>&1) || {
    echo "RENDER FAILED for tockmox-$l" >&2; echo "$out" | head -3 >&2; exit 1; }
  printf '%s\n' "$out"
done | extract_images)

[ -z "$ALL" ] && { echo "no images rendered at all, which cannot be right" >&2; exit 1; }

TOTAL=$(printf '%s\n' "$ALL" | grep -c .)
REDIRECTED=$(printf '%s\n' "$ALL" | grep -c "^$SENTINEL" || true)
echo "  $TOTAL distinct images, $REDIRECTED redirected"

# STRIP BOTH QUOTE CHARACTERS, not just double.
#
# A values file that sets a templated image inside a LIST ... which is what
# `extraInitContainers` requires, because those subcharts render it as
# `tpl (toYaml .)` ... makes toYaml serialise the value, and toYaml quotes any
# string holding `{{`, `|` or `"`. It chooses SINGLE quotes. `tpl` then runs
# over that text, so the quotes survive into the manifest as ordinary YAML
# delimiters and Kubernetes reads the image correctly.
#
# Until 2026-09-15 this extraction handled `"` only, so such an image arrived
# here as `'airgap-check.invalid/library/busybox`, failed the `^$SENTINEL`
# test on the leading quote alone, and was reported as ignoring
# global.imageRegistry when it had honoured it. A gate that goes red on a
# correct tree teaches people to ignore it (TM-0630), and this one had no
# single-quoted image to trip on until the Grafana and Argo `wait-for-ca`
# containers arrived (TM-0632).

# strip tag and digest so the list survives a version bump
strip() { sed -E 's/@sha256:[0-9a-f]+$//; s/:[^:\/]+$//'; }

LEAKED=$(printf '%s\n' "$ALL" | grep -v "^$SENTINEL" | strip | sort -u)
EXPECTED=$(printf '%s\n' "$EXEMPT" | sed '/^$/d' | sort -u)

echo
echo "== images ignoring global.imageRegistry =="
NEW=$(comm -23 <(printf '%s\n' "$LEAKED") <(printf '%s\n' "$EXPECTED"))
GONE=$(comm -13 <(printf '%s\n' "$LEAKED") <(printf '%s\n' "$EXPECTED"))

if [ -n "$NEW" ]; then
  fail=1
  echo "  FAIL  new images that do not honour global.imageRegistry:"
  printf '%s\n' "$NEW" | sed 's/^/          /'
  echo "        Wire that chart's own registry key, or add it to EXEMPT in"
  echo "        $(basename "$0") with the chart that owns it. Adding to the list is a"
  echo "        decision to widen what the global.imageRegistry fallback path"
  echo "        does not reach (airgap.md §2), so make it deliberately."
else
  echo "  no new gaps"
fi

if [ -n "$GONE" ]; then
  fail=1
  echo "  FAIL  listed as not-redirected but now redirected (or gone):"
  printf '%s\n' "$GONE" | sed 's/^/          /'
  echo "        Remove these from EXEMPT. A stale exemption hides the next regression."
fi

echo
echo "  exemptions remaining: $(printf '%s\n' "$EXPECTED" | grep -c .)"
[ "$fail" -eq 0 ] && echo "air-gap redirect gate OK" || echo "air-gap redirect gate FAILED"
exit "$fail"

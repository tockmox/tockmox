#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that the model gateway uses LiteLLM's
# bundled price map on an air-gapped site and keeps the live fetch elsewhere.
#
#   ./tools/check-litellm-price-map.sh
#
# WHY THIS IS A GATE. LiteLLM fetches its model price map from
# raw.githubusercontent.com when it starts, unless LITELLM_LOCAL_MODEL_COST_MAP
# is "True". On a site with no route out that fetch is a denied connection on
# every start and restart, and nothing in `helm lint` shows it. The subchart
# writes its env lists without `tpl`, so the value cannot be decided at render
# time inside the Deployment: the Deployment names an optional key in the
# ConfigMap `tockmox-litellm-airgap-env`, and the parent chart renders that
# ConfigMap only when `global.imageRegistry` is set. This checks the variable
# each container would actually get, resolved the way the kubelet resolves it
# (an optional reference to a missing ConfigMap sets nothing).
#
# WHAT IT PROVES: with global.imageRegistry empty, neither the LiteLLM proxy nor
# its migrations Job gets LITELLM_LOCAL_MODEL_COST_MAP; with it set, both get
# "True"; and a site that replaces litellm.extraEnvVars without the entry is
# refused by name while global.imageRegistry is set.
#
# WHAT IT DOES NOT PROVE: that LiteLLM is the only caller of
# raw.githubusercontent.com on a cut site, or that a running proxy makes no
# fetch. That needs an air-gap run, and is not run here.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-litellm-price-map: helm not on PATH" >&2; echo "SKIPPED: helm is not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-litellm-price-map: python3 PyYAML missing" >&2; echo "SKIPPED: python3 has no PyYAML" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CHART=charts/tockmox-ai
BASE=ci/values.yaml
MIRROR=registry.example/mirror

helm template t "$CHART" -f "$BASE" > "$tmp/connected.yaml"
helm template t "$CHART" -f "$BASE" --set "global.imageRegistry=$MIRROR" > "$tmp/airgap.yaml"

rc=0
python3 - "$tmp/connected.yaml" "$tmp/airgap.yaml" <<'PY' || rc=1
import sys, yaml

VAR = "LITELLM_LOCAL_MODEL_COST_MAP"

def docs(path):
    for chunk in open(path).read().split("\n---\n"):
        try:
            d = yaml.safe_load(chunk)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("kind"):
            yield d

def litellm_containers(ds):
    """(label, container) for the proxy Deployment and the migrations Job."""
    out = []
    for d in ds:
        if d["kind"] not in ("Deployment", "Job"):
            continue
        for c in d["spec"]["template"]["spec"].get("containers", []):
            if "berriai/litellm" in c.get("image", ""):
                out.append(("%s/%s" % (d["kind"], d["metadata"]["name"]), c))
    return out

def effective_env(container, configmaps):
    """The environment the kubelet would build: in order, last wins; an
    optional key from a missing ConfigMap or key sets nothing."""
    env = {}
    for e in container.get("env") or []:
        if "value" in e:
            env[e["name"]] = str(e["value"])
            continue
        ref = (e.get("valueFrom") or {}).get("configMapKeyRef")
        if ref is None:
            continue  # secretKeyRef, fieldRef: not what this gate reads
        data = (configmaps.get(ref["name"]) or {}).get("data") or {}
        if ref["key"] in data:
            env[e["name"]] = str(data[ref["key"]])
        elif not ref.get("optional"):
            env[e["name"]] = "<unresolvable: %s/%s>" % (ref["name"], ref["key"])
    return env

bad = 0
def fail(msg):
    global bad
    print("FAIL " + msg); bad += 1
def ok(msg):
    print("  ok " + msg)

for label, path, want in (("connected", sys.argv[1], None), ("air-gapped", sys.argv[2], "True")):
    ds = list(docs(path))
    cms = {d["metadata"]["name"]: d for d in ds if d["kind"] == "ConfigMap"}
    found = litellm_containers(ds)
    if len(found) < 2:
        fail("%s render: expected the LiteLLM Deployment and migrations Job, found %r (is apps.litellm on in ci/values.yaml?)"
             % (label, [f[0] for f in found]))
        continue
    for name, c in found:
        got = effective_env(c, cms).get(VAR)
        if got != want:
            fail("%s render: %s gets %s=%r, want %r" % (label, name, VAR, got, want))
        else:
            ok("%s render: %s %s" % (label, name, "has no %s" % VAR if want is None else "gets %s=%s" % (VAR, want)))

sys.exit(1 if bad else 0)
PY

# -------------------------------------------------- refusal, by its message
out=""
if out=$(helm template t "$CHART" -f "$BASE" --set "global.imageRegistry=$MIRROR" \
      --set 'litellm.extraEnvVars[0].name=OTHER' --set 'litellm.extraEnvVars[0].value=x' 2>&1); then
  echo "FAIL refusal (site replaces litellm.extraEnvVars on an air-gapped site): the render succeeded"; rc=1
elif printf '%s' "$out" | grep -- 'litellm.extraEnvVars does not carry LITELLM_LOCAL_MODEL_COST_MAP' >/dev/null; then
  echo "  ok refusal (site replaces litellm.extraEnvVars on an air-gapped site)"
else
  echo "FAIL refusal (site replaces litellm.extraEnvVars on an air-gapped site): failed, but not with the expected message"; rc=1
  printf '%s\n' "$out" | head -5 | sed 's/^/     got: /'
fi

if [ "$rc" -eq 0 ]; then echo "check-litellm-price-map: ok"; else echo "check-litellm-price-map: FAILED"; fi
exit "$rc"

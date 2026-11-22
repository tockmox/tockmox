#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that every LiteLLM container that can run
# Prisma has Prisma's telemetry off, on every site.
#
#   ./tools/check-litellm-telemetry.sh
#
# WHY THIS IS A GATE. LiteLLM runs the Prisma CLI for its schema migrations (the
# subchart's migrations Job) and at proxy start. Prisma sends a version check
# and usage data to checkpoint.prisma.io unless CHECKPOINT_DISABLE is set. A
# self-hosted install should not call a vendor by default, and on a site with no
# route out the call is a denied connection on every migration. The value comes
# from `litellm.envVars` in charts/tockmox-ai/values.yaml, and nothing in
# `helm lint` notices if it is dropped or a site's values knock it out.
#
# WHAT IT PROVES: in every render below, every container in a Deployment, Job,
# StatefulSet or CronJob that runs a berriai/litellm image (the proxy Deployment
# and the migrations Job in the shipped values) gets CHECKPOINT_DISABLE="1",
# resolved the way the kubelet resolves `env` (in order, last wins). The renders:
# the CI values (a connected site), global.imageRegistry set, global.airGapped
# true and false, and a site that adds its own litellm.envVars entry (Helm merges
# that map, so the shipped key must survive it). The setting is unconditional,
# so all of them must agree.
#
# WHAT IT DOES NOT PROVE: that nothing else in the install calls
# checkpoint.prisma.io, or that a running migration makes no call. That needs
# an air-gap run, and is not run here.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-litellm-telemetry: helm not on PATH" >&2; echo "SKIPPED: helm is not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-litellm-telemetry: python3 PyYAML missing" >&2; echo "SKIPPED: python3 has no PyYAML" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CHART=charts/tockmox-ai
BASE=ci/values.yaml

helm template t "$CHART" -f "$BASE" > "$tmp/connected.yaml"
helm template t "$CHART" -f "$BASE" --set "global.imageRegistry=registry.example/mirror" > "$tmp/mirror.yaml"
helm template t "$CHART" -f "$BASE" --set "global.airGapped=true" > "$tmp/airgapped.yaml"
helm template t "$CHART" -f "$BASE" --set "global.airGapped=false" > "$tmp/not-airgapped.yaml"
helm template t "$CHART" -f "$BASE" --set "litellm.envVars.SITE_OWN_VAR=x" > "$tmp/site-envvars.yaml"

python3 - "$tmp" <<'PY'
import os, sys, yaml

VAR, WANT = "CHECKPOINT_DISABLE", "1"
RENDERS = (
    ("connected", "connected.yaml"),
    ("global.imageRegistry set", "mirror.yaml"),
    ("global.airGapped=true", "airgapped.yaml"),
    ("global.airGapped=false", "not-airgapped.yaml"),
    ("site adds its own litellm.envVars", "site-envvars.yaml"),
)

def docs(path):
    for chunk in open(path).read().split("\n---\n"):
        try:
            d = yaml.safe_load(chunk)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("kind"):
            yield d

def pod_spec(d):
    k = d["kind"]
    if k in ("Deployment", "Job", "StatefulSet", "DaemonSet"):
        return d["spec"]["template"]["spec"]
    if k == "CronJob":
        return d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None

def litellm_containers(ds):
    """(label, workload, container) for every container on a LiteLLM image."""
    out = []
    for d in ds:
        spec = pod_spec(d)
        if not spec:
            continue
        for role in ("initContainers", "containers"):
            for c in spec.get(role) or []:
                if "berriai/litellm" in c.get("image", ""):
                    out.append(("%s/%s %s" % (d["kind"], d["metadata"]["name"], c["name"]), d, c))
    return out

def effective(container):
    env = {}
    for e in container.get("env") or []:
        if "value" in e:
            env[e["name"]] = str(e["value"])
        else:
            env[e["name"]] = "<reference>"
    return env.get(VAR)

bad = 0
def fail(msg):
    global bad
    print("FAIL " + msg); bad += 1
def ok(msg):
    print("  ok " + msg)

for label, fname in RENDERS:
    found = litellm_containers(docs(os.path.join(sys.argv[1], fname)))
    kinds = {(d["kind"], d["metadata"]["name"].endswith("-migrations")) for _, d, _ in found}
    if ("Deployment", False) not in kinds or ("Job", True) not in kinds:
        fail("%s render: expected the LiteLLM proxy Deployment and its migrations Job, found %r (is apps.litellm on in ci/values.yaml?)"
             % (label, [f[0] for f in found]))
        continue
    for name, _, c in found:
        got = effective(c)
        if got != WANT:
            fail("%s render: %s gets %s=%r, want %r" % (label, name, VAR, got, WANT))
        else:
            ok("%s render: %s gets %s=%s" % (label, name, VAR, WANT))

if bad:
    print("check-litellm-telemetry: FAILED")
    sys.exit(1)
print("check-litellm-telemetry: ok")
PY

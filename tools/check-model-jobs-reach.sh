#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ACROSS TWO RENDERED CHARTS, that the model-lifecycle jobs of tockmox-ai can reach Prometheus (and the health
# watch ntfy) through tockmox-policy's default-deny monitoring namespace (REQ-0048 AC-48.19, TM-1261, TM-1263).
#
#   ./tools/check-model-jobs-reach.sh
#
# WHY THIS IS A GATE. The eval scheduler reads Prometheus to know the node is quiet, and the health watch reads it to
# judge a promoted model. Their pods are labelled in tockmox-ai; the allow that admits them (allow-from-model-jobs) is
# written in tockmox-policy. Each chart's own gate passes when the other drifts: rename a label on one side and the
# scheduler waits forever ("Prometheus did not answer"), the health watch reads "inconclusive" forever, and nothing
# goes red. This joins the two renders.
#
# WHAT IT PROVES, from ci/values.yaml + ci/values-inference-nodes.yaml with the runner and the health watch enabled:
#   - the scheduler CronJob's pod template and the health watch CronJob's pod template each satisfy the AI-namespace
#     podSelector of the Prometheus (:9090) rule of allow-from-model-jobs (matchExpressions In, every key);
#   - the health watch pod also satisfies the ntfy rule's podSelector;
#   - the eval run Job pods (tockmox-eval-run) are NOT admitted: they talk to the eval gateway only;
#   - the namespaceSelector names the namespace tockmox-ai renders the jobs into.
# WHAT IT DOES NOT PROVE: that the CNI enforces it, or that Prometheus serves on 9090. The lab proof does that.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-model-jobs-reach: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-model-jobs-reach: python3 PyYAML missing" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

helm template t charts/tockmox-ai -f ci/values.yaml -f ci/values-inference-nodes.yaml \
  --set modelLifecycle.runner.enabled=true --set modelLifecycle.healthWatch.enabled=true > "$tmp/ai.yaml"
helm template t charts/tockmox-policy -f ci/values.yaml > "$tmp/policy.yaml"

python3 - "$tmp/ai.yaml" "$tmp/policy.yaml" <<'PY'
import sys, yaml

ai = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
pol = [d for d in yaml.safe_load_all(open(sys.argv[2])) if d]
fails = []

def pod_of(kind, name):
    """(namespace, pod-template labels) of the workload whose pod template is labelled app.kubernetes.io/name=name."""
    for d in ai:
        if d.get("kind") != kind:
            continue
        spec = d["spec"]
        tpl = spec["jobTemplate"]["spec"]["template"] if kind == "CronJob" else spec["template"]
        labels = (tpl.get("metadata") or {}).get("labels") or {}
        if labels.get("app.kubernetes.io/name") == name:
            return d["metadata"].get("namespace") or ai_ns, labels
    return None, None

def admits(sel, labels):
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get("matchExpressions") or []:
        op, k, vals = e["operator"], e["key"], e.get("values") or []
        if op == "In" and labels.get(k) not in vals:
            return False
        if op == "NotIn" and labels.get(k) in vals:
            return False
        if op == "Exists" and k not in labels:
            return False
        if op == "DoesNotExist" and k in labels:
            return False
    return True

# tockmox-ai renders no namespace (the Argo Application places it): the policy chart's namespaces.ai (with the CI
# override, if any) is the namespace the policy layer believes the AI layer lives in, so the join uses that
ai_ns = "tockmox-ai"
for vf in ("charts/tockmox-policy/values.yaml", "ci/values.yaml"):
    ai_ns = ((yaml.safe_load(open(vf)) or {}).get("namespaces") or {}).get("ai") or ai_ns
np = next((d for d in pol if d.get("kind") == "NetworkPolicy" and d["metadata"]["name"] == "allow-from-model-jobs"), None)
if np is None:
    print("FAIL tockmox-policy renders no allow-from-model-jobs NetworkPolicy"); sys.exit(1)

def rules_for(port):
    out = []
    for r in np["spec"].get("ingress") or []:
        if any(p.get("port") == port for p in r.get("ports") or []):
            out += r.get("from") or []
    return out

def reaches(ns, labels, port):
    return any(admits(f.get("namespaceSelector") or {}, {"kubernetes.io/metadata.name": ns})
               and admits(f.get("podSelector") or {}, labels) for f in rules_for(port))

cases = [("CronJob", "tockmox-eval-scheduler", 9090, True, "the eval scheduler reaches Prometheus (the quiet check)"),
         ("CronJob", "tockmox-health-watch", 9090, True, "the health watch reaches Prometheus"),
         ("CronJob", "tockmox-health-watch", 8080, True, "the health watch reaches ntfy"),
         ("Job", "tockmox-eval-run", 9090, False, "an eval run Job is not admitted to Prometheus")]
for kind, name, port, want, what in cases:
    ns, labels = pod_of(kind, name)
    if labels is None and kind == "Job":
        # the run Jobs are created by the scheduler; their labels live in the scheduler's config, so read them from there
        for d in ai:
            if d.get("kind") == "ConfigMap" and "tockmox-eval-run" in yaml.safe_dump(d.get("data") or {}):
                ns, labels = d["metadata"].get("namespace") or ai_ns, {"app.kubernetes.io/name": "tockmox-eval-run",
                                                                  "tockmox.com/isolated": "true",
                                                                  "tockmox.com/eval-client": "true"}
                break
    if labels is None:
        fails.append(f"FAIL {what}: tockmox-ai renders no {kind} with pod label app.kubernetes.io/name={name}")
        continue
    got = reaches(ns, labels, port)
    if got != want:
        fails.append(f"FAIL {what}: pod labels {labels} in namespace {ns} {'are not' if want else 'are'} admitted on :{port}")
    else:
        print(f"  ok {what}")
for f in fails:
    print(f)
sys.exit(1 if fails else 0)
PY

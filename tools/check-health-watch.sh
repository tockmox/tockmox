#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, the production health watch of tockmox-ai (REQ-0048 AC-48.19, TM-1263).
#
#   ./tools/check-health-watch.sh
#
# WHY THIS IS A GATE. The watch is the only thing that can notice a promoted model doing worse than the one it
# replaced, and its failure modes are quiet: a pod that cannot reach Prometheus reads as "inconclusive" forever, a
# pod with a service-account token is cluster authority for a job that needs none, and an egress rule wider than
# the config says is a hole nobody sees. The Python side is proved by tockmox-ui/tests/test_health_watch.py; this
# proves what the chart hands it.
#
# WHAT IT PROVES, from ci/values.yaml + ci/values-inference-nodes.yaml:
#   - the default render has none of it;
#   - enabled, it is one CronJob every 15 minutes in the Tockmox UI image (tockmoxUi.image by default,
#     healthWatch.image when named), with no service-account token and the isolated label;
#   - its config carries the rules, the soak window and the Prometheus URL, and autoRevert is empty (off for every alias);
#   - its NetworkPolicy allows DNS and Prometheus only, then ntfy when set (an in-cluster Service URL opens that
#     namespace's ntfy pods, any other host opens public HTTPS) and the forge only when pullRequests is on;
#   - the bot token and the ntfy secret reach it as environment, the GitHub App key as a read-only mount;
#   - five wrong configurations are refused with a sentence naming the cause.
# WHAT IT DOES NOT PROVE: that Prometheus admits the pod (tockmox-policy's monitoring allow names the UI), that
# the gateway exports the metrics, or that ntfy delivers. The lab proof does that.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-health-watch: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-health-watch: python3 PyYAML missing" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
AI=charts/tockmox-ai
BASE=(-f ci/values.yaml -f ci/values-inference-nodes.yaml)
HW=(--set modelLifecycle.healthWatch.enabled=true)

render() { helm template t "$AI" "${BASE[@]}" "$@"; }
render > "$tmp/default.yaml"
render "${HW[@]}" > "$tmp/on.yaml"
render "${HW[@]}" --set modelLifecycle.healthWatch.image=registry.example/health:1 > "$tmp/image.yaml"
render "${HW[@]}" --set modelLifecycle.healthWatch.pullRequests=true --set modelLifecycle.watch.secrets.forgeToken=bot-token \
  --set modelLifecycle.healthWatch.notify.ntfyUrl=http://tockmox-ntfy.tockmox-monitoring.svc \
  --set modelLifecycle.healthWatch.notify.topicSecret=ntfy-secret \
  --set modelLifecycle.healthWatch.autoRevert.local-medium=true > "$tmp/full.yaml"
render "${HW[@]}" --set modelLifecycle.healthWatch.notify.ntfyUrl=https://ntfy.example.org:8443 \
  --set modelLifecycle.healthWatch.prometheusUrl=http://prom.example.org:9090 > "$tmp/external.yaml"

refuse() {  # name, expected substring, extra helm args...
  local name="$1" want="$2"; shift 2
  if out=$(render "$@" 2>&1); then
    echo "FAIL refused case rendered: $name"; return 1
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    echo "FAIL $name: refused, but without naming the cause ($want)"; echo "$out" | tail -2; return 1
  fi
  echo "  ok refused: $name"
}

rc=0
refuse "no image anywhere (the UI off and healthWatch.image empty)" "healthWatch.image is empty and the Tockmox UI is off or has no tockmoxUi.image" \
  "${HW[@]}" --set tockmoxUi.enabled=false || rc=1
# the watcher's own opener is turned off in these three, so its guard does not answer for the health watch's
NOPR=(--set modelLifecycle.watch.pullRequests.enabled=false)
refuse "pull requests with no way for the opener to authenticate" "modelLifecycle.healthWatch.pullRequests is on, but the model watcher's opener has no way to authenticate" \
  "${HW[@]}" "${NOPR[@]}" --set modelLifecycle.healthWatch.pullRequests=true --set modelLifecycle.watch.pullRequests.githubApp=null || rc=1
refuse "pull requests on a Forgejo forge with no token Secret" "modelLifecycle.healthWatch.pullRequests is on for a Forgejo forge" \
  "${HW[@]}" "${NOPR[@]}" --set modelLifecycle.healthWatch.pullRequests=true --set modelLifecycle.watch.pullRequests.forge=forgejo || rc=1
refuse "pull requests with no repo to open them on" "repo or valuesPath is empty" \
  "${HW[@]}" "${NOPR[@]}" --set modelLifecycle.healthWatch.pullRequests=true --set modelLifecycle.watch.pullRequests.repo= || rc=1
refuse "a schedule that is not a cron expression" "schedule" \
  "${HW[@]}" --set modelLifecycle.healthWatch.schedule=x || rc=1

python3 - "$tmp/default.yaml" "$tmp/on.yaml" "$tmp/image.yaml" "$tmp/full.yaml" "$tmp/external.yaml" <<'PY' || rc=1
import sys, yaml

def docs(path):
    return [d for d in yaml.safe_load_all(open(path)) if isinstance(d, dict) and d.get("kind")]

def find(ds, kind, name="tockmox-health-watch"):
    return next((d for d in ds if d["kind"] == kind and d["metadata"]["name"] == name), None)

bad = 0
def check(cond, msg):
    global bad
    print(("  ok " if cond else "FAIL ") + msg)
    bad += (not cond)

default, on, image, full, external = (docs(p) for p in sys.argv[1:6])
UI_IMAGE = find(on, "Deployment", "tockmox-ui")["spec"]["template"]["spec"]["containers"][0]["image"]

check(not any(d["metadata"]["name"] == "tockmox-health-watch" for d in default), "the default render has no health watch")

cj = find(on, "CronJob")
pod = cj["spec"]["jobTemplate"]["spec"]["template"]
spec, c = pod["spec"], pod["spec"]["containers"][0]
check(cj["spec"]["schedule"] == "*/15 * * * *" and cj["spec"]["concurrencyPolicy"] == "Forbid", "one CronJob every 15 minutes, never two at once")
check(c["image"] == UI_IMAGE, "the image falls back to tockmoxUi.image")
check(find(image, "CronJob")["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["image"] == "registry.example/health:1",
      "healthWatch.image wins when named")
check(spec["automountServiceAccountToken"] is False and find(on, "ServiceAccount")["automountServiceAccountToken"] is False,
      "no service-account token")
check(pod["metadata"]["labels"].get("tockmox.com/isolated") == "true", "the pod is isolated from the namespace-wide allows")
check(c["command"][:3] == ["python", "-m", "app.health_watch"] and c["securityContext"]["readOnlyRootFilesystem"] is True
      and "volumes" in spec and [v["name"] for v in spec["volumes"]] == ["config"], "the UI image's module, read-only root, only its config mounted")
check("env" not in c, "no secret reaches it when no ntfy or bot is configured")

cfg = yaml.safe_load(find(on, "ConfigMap")["data"]["config.yaml"])
h = cfg["modelLifecycle"]["healthWatch"]
check(h["enabled"] is True and h["soakDays"] == 14 and h["rules"]["errorRateRatio"] == 2.0 and h["rules"]["likeHours"] is True
      and h["rules"]["minRequests"] == 50 and h["rules"]["forMinutes"] == 30, "the config carries the rules and the soak window")
check(h["autoRevert"] == {}, "autoRevert is empty: off for every alias")
check(h["prometheusUrl"].endswith(".svc:9090") and "image" not in h and "schedule" not in h, "the Prometheus URL is resolved; chart-only keys are not in the config")
check("catalog" in cfg["modelLifecycle"] and "routes" in cfg["inferenceNodes"], "the catalog and the routes are in the config (which aliases are promoted)")

def egress(ds):
    return find(ds, "NetworkPolicy")["spec"]["egress"]

def peers(ds):
    out = []
    for r in egress(ds):
        for t in r["to"]:
            ns = (t.get("namespaceSelector") or {}).get("matchLabels", {}).get("kubernetes.io/metadata.name")
            pod = (t.get("podSelector") or {}).get("matchLabels", {}).get("app.kubernetes.io/name")
            out.append((ns, pod, "ipBlock" in t, [p["port"] for p in r["ports"]]))
    return out

np_on = find(on, "NetworkPolicy")["spec"]
check(np_on["ingress"] == [] and set(np_on["policyTypes"]) == {"Ingress", "Egress"}, "no ingress")
check(peers(on) == [("kube-system", None, False, [53, 53]), ("tockmox-monitoring", "prometheus", False, [9090])],
      "default egress: DNS and Prometheus, nothing else")
pf = peers(full)
check(("tockmox-monitoring", "tockmox-ntfy", False, [80]) in pf, "an in-cluster ntfy URL opens that namespace's ntfy pods on its port")
check(sum(1 for p in pf if p[2]) == 1, "pull requests open public HTTPS once")
ipb = [r for r in egress(full) if any("ipBlock" in t for t in r["to"])][0]
check("10.0.0.0/8" in ipb["to"][0]["ipBlock"]["except"] and "169.254.0.0/16" in ipb["to"][0]["ipBlock"]["except"], "public HTTPS excludes the private, link-local and metadata ranges")
ex = peers(external)
check(not any(p[1] == "tockmox-ntfy" for p in ex) and sum(1 for p in ex if p[2]) == 1 and [443, 8443] == [p[3] for p in ex if p[2]][0],
      "an external ntfy host opens public HTTPS on its port, and a custom Prometheus URL drops the Prometheus rule")
check(not any(p[1] == "prometheus" for p in ex), "a prometheusUrl elsewhere opens nothing to the monitoring namespace (egress.extra does)")

fc = find(full, "CronJob")["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
env = {e["name"]: e["valueFrom"]["secretKeyRef"] for e in fc["env"]}
check(env["TOCKMOX_BOT_TOKEN"] == {"name": "bot-token", "key": "token"}, "the watcher's bot token Secret reaches it")
check(env["NTFY_TOKEN"]["name"] == "ntfy-secret" and env["NTFY_TOKEN"]["optional"] is True and env["NTFY_TOPIC"]["key"] == "topic", "the ntfy Secret reaches it, keys optional")
fcfg = yaml.safe_load(find(full, "ConfigMap")["data"]["config.yaml"])["modelLifecycle"]
check(fcfg["healthWatch"]["autoRevert"] == {"local-medium": True} and fcfg["healthWatch"]["pullRequests"] is True, "autoRevert and pullRequests are carried only when set")
check(fcfg["healthWatch"]["notify"] == {"ntfyUrl": "http://tockmox-ntfy.tockmox-monitoring.svc"}, "the config names the ntfy URL and never the Secret")
check(fcfg["watch"]["pullRequests"]["tokenEnv"] == "TOCKMOX_BOT_TOKEN", "the opener config is the watcher's, pointed at the mounted token")

raise SystemExit(1 if bad else 0)
PY
[ "$rc" -eq 0 ] && echo "check-health-watch: PASSED" || echo "check-health-watch: FAILED"
exit "$rc"

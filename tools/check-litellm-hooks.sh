#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that a site can load its own LiteLLM
# callbacks (a pre-call policy gate and a logging hook) through documented
# values only (TM-0787).
#
#   ./tools/check-litellm-hooks.sh
#
# WHY THIS IS A GATE. The seam is three values in three places (the files, the
# mount, the callback list) and every wrong combination renders cleanly. A
# mount at the wrong path, or a callback naming a file that is not there,
# produces a proxy that starts without the hook or fails at startup on an
# import error; neither shows in `helm lint`. So this checks the rendered
# objects, not an exit code.
#
# WHAT IT PROVES: the hook ConfigMap exists and holds both example files; the
# LiteLLM Deployment mounts it at /etc/litellm/hooks; the rendered LiteLLM
# config lists both callbacks; and each callback, resolved the way LiteLLM's
# get_instance_fn resolves it (relative to the directory of the config file),
# lands on a file the mount provides. It also proves the default render carries
# no hook ConfigMap and no `hooks.` callback, and that three wrong site
# configurations are refused with a sentence that names the cause.
#
# WHAT IT DOES NOT PROVE: that a real LiteLLM loads the example hooks, or that a
# completion passes through them. That needs a running proxy and is not run here.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-litellm-hooks: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-litellm-hooks: python3 PyYAML missing" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CHART=charts/tockmox-ai
BASE=ci/values.yaml
FIX=ci/values-litellm-hooks.yaml

helm template t "$CHART" -f "$BASE" > "$tmp/default.yaml"
helm template t "$CHART" -f "$BASE" -f "$FIX" > "$tmp/hooks.yaml"

rc=0
python3 - "$tmp/default.yaml" "$tmp/hooks.yaml" <<'PY' || rc=1
import os, sys, yaml

def docs(path):
    for chunk in open(path).read().split("\n---\n"):
        try:
            d = yaml.safe_load(chunk)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("kind"):
            yield d

def litellm_deployment(ds):
    for d in ds:
        if d["kind"] != "Deployment":
            continue
        for c in d["spec"]["template"]["spec"]["containers"]:
            if "litellm" in c.get("image", ""):
                return d, c
    return None, None

def litellm_config(ds):
    for d in ds:
        if d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-litellm-config"):
            return yaml.safe_load(d["data"]["config.yaml"])
    return None

bad = 0
def fail(msg):
    global bad
    print("FAIL " + msg); bad += 1
def ok(msg):
    print("  ok " + msg)

# ------------------------------------------------------------ default render
default = list(docs(sys.argv[1]))
if any(d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-litellm-hooks" for d in default):
    fail("default render carries the hook ConfigMap; hooks must be opt-in")
else:
    ok("default render: no hook ConfigMap")
cfg = litellm_config(default)
if cfg is None:
    fail("default render: no LiteLLM config ConfigMap found (is apps.litellm on in ci/values.yaml?)")
else:
    cbs = (cfg.get("litellm_settings") or {}).get("callbacks") or []
    if any(str(c).startswith("hooks.") for c in cbs):
        fail("default render registers a hooks.* callback: %r" % cbs)
    else:
        ok("default render: no hooks.* callback registered")

# --------------------------------------------------------------- hooks render
ds = list(docs(sys.argv[2]))
cms = [d for d in ds if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tockmox-litellm-hooks"]
if len(cms) != 1:
    fail("expected exactly one ConfigMap tockmox-litellm-hooks, found %d" % len(cms))
    files = {}
else:
    files = cms[0].get("data") or {}
    want = {"example_gate.py", "example_log.py"}
    if set(files) != want:
        fail("hook ConfigMap keys %r != %r" % (sorted(files), sorted(want)))
    elif "async_pre_call_hook" not in files["example_gate.py"] or "async_log_success_event" not in files["example_log.py"]:
        fail("hook ConfigMap content does not carry the example hook bodies")
    else:
        ok("ConfigMap tockmox-litellm-hooks holds example_gate.py (pre-call) and example_log.py (logging)")

dep, main = litellm_deployment(ds)
if dep is None:
    fail("no LiteLLM Deployment in the hooks render")
    sys.exit(1)
spec = dep["spec"]["template"]["spec"]
vols = {v["name"]: v for v in spec.get("volumes", [])}
v = vols.get("tockmox-hooks")
if not v or (v.get("configMap") or {}).get("name") != "tockmox-litellm-hooks":
    fail("Deployment has no volume tockmox-hooks backed by ConfigMap tockmox-litellm-hooks")
else:
    ok("Deployment volume tockmox-hooks -> ConfigMap tockmox-litellm-hooks")
mounts = {m["name"]: m for m in main.get("volumeMounts", [])}
mp = (mounts.get("tockmox-hooks") or {}).get("mountPath")
if mp != "/etc/litellm/hooks":
    fail("container mounts tockmox-hooks at %r, want /etc/litellm/hooks" % mp)
else:
    ok("container mounts tockmox-hooks at /etc/litellm/hooks")

# The config file's path decides where callbacks are resolved from.
args = main.get("args") or []
cfgpath = args[args.index("--config") + 1] if "--config" in args else None
if cfgpath != "/etc/litellm/config.yaml":
    fail("LiteLLM --config is %r; the hooks mount assumes /etc/litellm/config.yaml" % cfgpath)
cfg = litellm_config(ds)
cbs = ((cfg or {}).get("litellm_settings") or {}).get("callbacks") or []
if cbs != ["hooks.example_gate.gate", "hooks.example_log.logger"]:
    fail("rendered LiteLLM config callbacks are %r" % cbs)
else:
    ok("rendered LiteLLM config lists callbacks %s" % ", ".join(cbs))

# The logging example must be visible at the proxy's default log level. A
# logger with no handler drops INFO under LITELLM_LOG=INFO, so an example that
# logs at info reads as a hook that never fired (0.7.0 lab pass, F5).
_lg = files.get("example_log.py", "")
if "log.warning(" not in _lg or "log.info(" in _lg or "log.debug(" in _lg:
    fail("example_log.py must log with log.warning (info/debug are dropped at LITELLM_LOG=INFO)")
else:
    ok("example_log.py logs at WARNING, visible at the default log level")

# Resolve each callback as get_instance_fn does: dirname(config)/<module path>.py
for cb in cbs:
    module = cb.rsplit(".", 1)[0]
    target = os.path.join(os.path.dirname(cfgpath), *module.split(".")) + ".py"
    prefix = mp.rstrip("/") + "/"
    provided = target.startswith(prefix) and target[len(prefix):] in files
    if not provided:
        fail("callback %s resolves to %s, which the mount does not provide" % (cb, target))
    else:
        ok("callback %s resolves to %s, provided by the mount" % (cb, target))

sys.exit(1 if bad else 0)
PY

# -------------------------------------------------- refusals, by their message
# Each wrong site configuration must be refused, and by the sentence that names
# the cause (an unrelated failure would also exit non-zero and prove nothing).
expect_refusal() {
  local label="$1" needle="$2"; shift 2
  local out
  if out=$(helm template t "$CHART" -f "$BASE" -f "$FIX" "$@" 2>&1); then
    echo "FAIL refusal ($label): the render succeeded"; rc=1
  elif printf '%s' "$out" | grep -q -- "$needle"; then
    echo "  ok refusal ($label)"
  else
    echo "FAIL refusal ($label): failed, but not with the expected message"; rc=1
  fi
}
expect_refusal "site replaces litellm.volumes" 'has no `tockmox-hooks` volume' \
  --set 'litellm.volumes[0].name=other' --set 'litellm.volumes[0].emptyDir={}'
expect_refusal "site drops litellm.volumeMounts" 'does not mount `tockmox-hooks`' \
  --set 'litellm.volumeMounts=null'
expect_refusal "site restates tockmox-hooks but drops tockmox-scratch (TM-1005)" 'has no `tockmox-scratch` volume' \
  --set 'litellm.volumes[0].name=tockmox-hooks' --set 'litellm.volumes[0].configMap.name=tockmox-litellm-hooks'
expect_refusal "site mounts tockmox-hooks but not /scratch (TM-1005)" 'does not mount `tockmox-scratch` at /scratch' \
  --set 'litellm.volumeMounts[0].name=tockmox-hooks' --set 'litellm.volumeMounts[0].mountPath=/etc/litellm/hooks'
expect_refusal "callback names a missing file" 'has no key "nope.py"' \
  --set 'litellm.proxy_config.litellm_settings.callbacks[2]=hooks.nope.x'
expect_refusal "files set, nothing registered" 'no callback under `hooks.` is registered' \
  --set 'litellm.proxy_config.litellm_settings.callbacks=null'

if [ "$rc" -eq 0 ]; then echo "check-litellm-hooks: ok"; else echo "check-litellm-hooks: FAILED"; fi
exit "$rc"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that every console doing a server-side OIDC
# exchange gets a trust bundle, and that the bundle is built from its own image.
#
#   ./tools/check-trust-wiring.sh
#
# WHY THIS IS A GATE AND NOT A COMMENT. Turning TLS on for the first time
# (2026-08-15) broke SSO everywhere at once: the consoles verify the provider's
# certificate from inside their own containers, and no container trusted the
# Tockmox CA. Nothing in the repo said so, every chart rendered, every schema
# passed, and local break-glass login kept working, so the consoles looked up.
#
# THE MECHANISM DEPENDS ON THE RUNTIME, and that is measured rather than
# stylistic. Both halves were established on a cluster on 2026-08-15:
#
#   Go      SSL_CERT_FILE is UNIONED with the default certificate directories,
#           so mounting the CA alone yields the CA plus every public root. No
#           initContainer, nothing to concatenate. Grafana and the Argo server.
#
#   Python  `requests` and `httpx` treat the file as the ENTIRE trust store, so
#           a CA-only file silently drops every public root. They need a
#           concatenation, which needs a shell, which needs an initContainer
#           running the application's own image. Open WebUI.
#
# The distinction is not cosmetic: shipping the Python construct on the Argo
# server put it in Init:CrashLoopBackOff for 77 minutes, because argocli is
# distroless and has no /bin/sh. So this gate checks each console against the
# shape its runtime actually requires.
#
# Things checked, each of which has already been wrong once:
#
#   1. the wiring is present    ... the render-time preflight guards cover a
#      site that drops it, but not a chart edit that removes it from the
#      shipped defaults. This does.
#
#   2. TOCKMOX_SSO_ENV_REVISION resolved to a HASH and not to literal template
#      text. That variable exists because `envFrom` does not roll a pod, and it
#      only works because open-webui and grafana run `tpl` over env values. If
#      an upstream chart stops doing that, the value arrives as the string
#      "{{ include ... }}", which is constant, silently useless, and identical
#      in every render. Nothing else would notice.
set -euo pipefail

# SHELL GUARD -- bash 4.0+ required. THIS SCRIPT IS THE REASON THE GUARD EXISTS.
#
# Measured on a stock Mac 2026-08-31 (TM-0245), against bash 3.2.57:
#
#   $ /bin/bash ./tools/check-trust-wiring.sh; echo "exit=$?"
#   ./tools/check-trust-wiring.sh: line 59: tockmox: unbound variable
#   exit=0
#
# It printed an error, skipped every check, and reported success. `declare -A`
# is bash 4.0+; under 3.2 the compound assignment arithmetic-evaluates the
# subscript, and `set -euo pipefail` does not catch it. So this gate has been
# reporting green on the maintainer's laptop while examining nothing -- the
# precise failure this repo writes gates to prevent, occurring in a gate.
#
# CI is unaffected (Linux, bash 5). What was false is local verification.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "check-trust-wiring: needs bash 4.0+ for associative arrays; found ${BASH_VERSION:-unknown}." >&2
  echo "  macOS ships bash 3.2 as /bin/bash. Install a newer one and run it explicitly:" >&2
  echo "    brew install bash && /opt/homebrew/bin/bash tools/check-trust-wiring.sh" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

VALUES=${VALUES:-ci/values.yaml}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Layers whose pods perform their own OIDC token exchange, and the container
# name to compare the initContainer's image against.
# The blackbox exporter is here for a reason worth stating: it is not an OIDC
# console, it is a CLIENT that verifies the consoles' certificates. It was
# missed exactly because this list read as "things that log people in", and the
# result was five Probes reporting 0 with "certificate signed by unknown
# authority" and a critical alert ten minutes from firing. The question this
# gate asks is "does this pod verify a Tockmox certificate", and the prober does.
declare -A EXPECT=(
  [tockmox-ai]=open-webui
  [tockmox-observability]=grafana
  [tockmox-devops]=argo-server
  [tockmox-exporters]=blackbox-exporter
)

fail=0
for layer in "${!EXPECT[@]}"; do
  helm template t "charts/$layer" -f "$VALUES" > "$tmp/$layer.yaml"
done

python3 - "$tmp" "${!EXPECT[@]}" <<'PY'
import sys, os, yaml
tmp = sys.argv[1]
layers = sys.argv[2:]
# component -> (container name, runtime). The runtime decides which shape is
# correct; see the header.
expect = {"tockmox-ai":            ("open-webui",       "python"),
          "tockmox-observability": ("grafana",          "go"),
          "tockmox-devops":        ("argo-server",      "go"),
          "tockmox-exporters":     ("blackbox-exporter","go")}
rc = 0

def docs(path):
    for chunk in open(path).read().split("\n---\n"):
        try:
            d = yaml.safe_load(chunk)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("kind"):
            yield d

for layer in layers:
    app, runtime = expect[layer]
    found = False
    for d in docs(os.path.join(tmp, layer + ".yaml")):
        spec = (d.get("spec") or {}).get("template", {}).get("spec")
        if not isinstance(spec, dict):
            continue
        mains = [c for c in spec.get("containers", []) if c.get("name") == app]
        if not mains:
            continue
        found = True
        main = mains[0]
        bad = []
        if runtime == "python":
            inits = [c for c in (spec.get("initContainers") or []) if c.get("name") == "tockmox-trust-bundle"]
            if not inits:
                print(f"FAIL {layer}/{app}: no tockmox-trust-bundle initContainer. A Python runtime "
                      "needs the CA concatenated onto the image's own store, because requests and "
                      "httpx use the file as the whole trust store.")
                rc = 1; bad.append(1)
            else:
                init = inits[0]
                if init.get("image") != main.get("image"):
                    print(f"FAIL {layer}/{app}: initContainer image {init.get('image')!r} != application image {main.get('image')!r}")
                    rc = 1; bad.append(1)
            vols = {v["name"] for v in (spec.get("volumes") or [])}
            for need in ("tockmox-trust", "tockmox-ca"):
                if need not in vols:
                    print(f"FAIL {layer}/{app}: volume {need} missing")
                    rc = 1; bad.append(1)
            mounts = {m["name"]: m.get("mountPath") for m in (main.get("volumeMounts") or [])}
            if mounts.get("tockmox-trust") != "/etc/tockmox/trust":
                print(f"FAIL {layer}/{app}: application does not mount tockmox-trust at /etc/tockmox/trust")
                rc = 1; bad.append(1)
            want_ssl = "/etc/tockmox/trust/ca-bundle.crt"
        else:
            # Go: no initContainer, and one shipping here would be a regression
            # rather than belt and braces. On a distroless image it cannot even
            # start.
            if any(c.get("name") == "tockmox-trust-bundle" for c in (spec.get("initContainers") or [])):
                print(f"FAIL {layer}/{app}: has a tockmox-trust-bundle initContainer, which a Go "
                      "runtime does not need and a distroless image cannot run. Mount the CA and "
                      "set SSL_CERT_FILE instead.")
                rc = 1; bad.append(1)
            vols = {v["name"] for v in (spec.get("volumes") or [])}
            if "tockmox-ca" not in vols:
                print(f"FAIL {layer}/{app}: volume tockmox-ca missing")
                rc = 1; bad.append(1)
            mounts = {m["name"]: m.get("mountPath") for m in (main.get("volumeMounts") or [])}
            if mounts.get("tockmox-ca") != "/etc/tockmox/ca":
                print(f"FAIL {layer}/{app}: application does not mount tockmox-ca at /etc/tockmox/ca")
                rc = 1; bad.append(1)
            want_ssl = "/etc/tockmox/ca/ca.crt"

        env = {e["name"]: e.get("value") for e in (main.get("env") or []) if "name" in e}
        if env.get("SSL_CERT_FILE") != want_ssl:
            print(f"FAIL {layer}/{app}: SSL_CERT_FILE is {env.get('SSL_CERT_FILE')!r}, expected {want_ssl!r}")
            rc = 1; bad.append(1)
        if runtime == "python" and env.get("REQUESTS_CA_BUNDLE") != want_ssl:
            print(f"FAIL {layer}/{app}: REQUESTS_CA_BUNDLE is {env.get('REQUESTS_CA_BUNDLE')!r} "
                  "(python `requests` ignores SSL_CERT_FILE)")
            rc = 1; bad.append(1)

        # The rollout trigger, where one applies.
        if app in ("open-webui", "grafana"):
            rev = env.get("TOCKMOX_SSO_ENV_REVISION")
            if rev is None:
                print(f"FAIL {layer}/{app}: TOCKMOX_SSO_ENV_REVISION absent; a re-rendered "
                      "sso-env Secret will not roll this pod")
                rc = 1; bad.append(1)
            elif "{{" in str(rev) or len(str(rev)) != 16:
                print(f"FAIL {layer}/{app}: TOCKMOX_SSO_ENV_REVISION is {rev!r}, not a 16-character "
                      "hash. The upstream chart has stopped running tpl over env values, so the "
                      "rollout trigger is now a constant.")
                rc = 1; bad.append(1)
        if not bad:
            print(f"ok   {layer}/{app:<12} {runtime:<7} SSL_CERT_FILE={want_ssl} "
                  f"revision={env.get('TOCKMOX_SSO_ENV_REVISION', 'n/a')}")
    if not found:
        print(f"FAIL {layer}: no workload with a container named {app}")
        rc = 1
sys.exit(rc)
PY

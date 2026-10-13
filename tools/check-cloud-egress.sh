#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# What can the RENDERED tree reach? (TM-0671)
#
#   ./tools/check-cloud-egress.sh             the gate
#   ./tools/check-cloud-egress.sh --selftest  prove it can go red
#
# The project's claim is that your data does not leave your hardware. The gate
# that used to stand behind it grepped three vendor hostnames in `value:`
# position, so it could not see a hostname that lives in a binary (Grafana's
# update check, Open WebUI's version check, both found by looking at a screen,
# not by CI), nor any host it had not been told about.
#
# THIS DOES TWO THINGS, both in tools/lib/egress_scan.py where the lists live:
#   1. every URL in rendered config (env, args, ConfigMap, Secret, spec) must be
#      inside the cluster, on a placeholder domain, or in a short commented
#      ALLOW list with a reason; an ALLOW entry no render contains is stale.
#   2. every phone-home audited so far is either OFF at its source or listed as
#      KNOWN_ON with a reason, asserted in both directions. (KNOWN_ON is empty
#      since 0.7.1; the mechanism stays and is proven by --selftest.)
# Rendered with the shipped defaults and again with ci/values-all-on.yaml.
#
# SCOPE, stated so it is not over-read: the second list is what has been
# audited, not everything that could phone home, and the script prints what is
# NOT audited. It reads renders, so it says nothing about whether a call
# succeeds or whether the network would block it.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-cloud-egress: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-cloud-egress: python3 PyYAML missing" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
r="$tmp/render"; mkdir -p "$r"

for c in charts/tockmox-*; do
  l=${c#charts/tockmox-}; [ "$l" = common ] && continue
  helm template "tockmox-$l" "$c" -f ci/values.yaml > "$r/$l.yaml" 2>"$tmp/err" \
    || { echo "check-cloud-egress: tockmox-$l did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
  helm template "tockmox-$l" "$c" -f ci/values.yaml -f ci/values-all-on.yaml > "$r/$l.allon.yaml" 2>"$tmp/err" \
    || { echo "check-cloud-egress: tockmox-$l (all-on) did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
done

if [ "${1:-}" != "--selftest" ]; then
  python3 tools/lib/egress_scan.py "$r" && echo && echo "check-cloud-egress: clean" \
    || { echo; echo "check-cloud-egress: FAILED" >&2; exit 1; }
  exit 0
fi

# --- selftest: each mutation must turn the scan red; the untouched copy green ---
fail=0
expect_red() {   # <label> <dir> <grep-for>
  if out=$(python3 tools/lib/egress_scan.py "$2" 2>&1); then echo "selftest FAIL  $1: scan stayed GREEN"; fail=1
  elif grep -q "$3" <<<"$out"; then echo "selftest ok    $1: RED on '$3'"
  else echo "selftest FAIL  $1: red, but not for the expected reason"; echo "$out" | grep FAIL | head -3; fail=1; fi
}
fresh() { rm -rf "$tmp/m"; cp -R "$r" "$tmp/m"; }
# Portable in-place edit (TM-0996). BSD sed on macOS reads a bare -i's next
# argument as a backup suffix, so `sed -i 's/x/y/' f` dies there with "invalid
# command code". Write and move instead, the way install/tockmox-install.sh does.
sedi() { local e="$1" f rc=0; shift; for f in "$@"; do if sed "$e" "$f" > "$f.sedi"; then mv "$f.sedi" "$f"; else rm -f "$f.sedi"; rc=1; fi; done; return $rc; }
fresh
python3 tools/lib/egress_scan.py "$tmp/m" >/dev/null && echo "selftest ok    the unmutated renders are GREEN" \
  || { echo "selftest FAIL  the unmutated renders are not green"; fail=1; }
fresh; sedi 's#^\([[:space:]]*\)value: "http://tockmox-ntfy.tockmox-monitoring.svc"#\1value: "https://telemetry.vendor-example.io/v1"#' "$tmp/m/observability.yaml"
grep -q 'telemetry.vendor-example.io' "$tmp/m/observability.yaml" || { echo "selftest FAIL  fixture edit 1 did not apply"; fail=1; }
expect_red "an unlisted external host in an env value" "$tmp/m" 'telemetry.vendor-example.io is not inside'
# Default render only: the all-on copy still has the switch, which is the point.
fresh; sedi 's/check_for_updates = false/check_for_updates = true/' "$tmp/m/observability.yaml"
expect_red "Grafana update check turned back on" "$tmp/m" 'Grafana update check: expected OFF'
fresh; sedi 's/--global.checkNewVersion=false/--global.checkNewVersion=true/' "$tmp/m/platform.yaml"
expect_red "Traefik version check turned back on" "$tmp/m" 'Traefik new-version check: expected OFF'
fresh; sedi '/^[[:space:]]*- --disable-reporting$/d' "$tmp/m/observability.yaml" "$tmp/m/observability.allon.yaml"
expect_red "Alloy usage reporting turned back on" "$tmp/m" 'Alloy usage reporting: expected OFF'
fresh; sedi 's/^\([[:space:]]*\)reporting_enabled: false/\1reporting_enabled: true/' "$tmp/m/observability.yaml"
expect_red "Loki usage reporting turned back on" "$tmp/m" 'Loki anonymous usage reporting: expected OFF'
fresh; sedi 's/^\([[:space:]]*\)upgrade-checker: false/\1upgrade-checker: true/' "$tmp/m/platform.yaml"
expect_red "Longhorn upgrade checker turned back on" "$tmp/m" 'Longhorn upgrade checker: expected OFF'
fresh; sedi 's/\(AUTHENTIK_DISABLE_UPDATE_CHECK: \)"dHJ1ZQ=="/\1"ZmFsc2U="/' "$tmp/m/identity.yaml"
expect_red "authentik update check turned back on" "$tmp/m" 'authentik update check: expected OFF'
fresh; sedi 's/\(AUTHENTIK_DISABLE_STARTUP_ANALYTICS: \)"dHJ1ZQ=="/\1"ZmFsc2U="/' "$tmp/m/identity.yaml"
expect_red "authentik startup analytics turned back on" "$tmp/m" 'authentik startup analytics: expected OFF'
# The KNOWN_ON list is empty, so its mechanism is proven with a synthetic entry:
# one whose off-switch IS present must go red ("move it to OFF"), one whose
# off-switch is absent must stay green.
fresh
if KO=$(python3 - "$tmp/m" <<'PY' 2>&1
import importlib.util, sys
sp = importlib.util.spec_from_file_location("egress_scan", "tools/lib/egress_scan.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
m.SWITCHES = [("synthetic present", "observability", "KNOWN_ON", r"--disable-reporting", "x", "n")]
sys.exit(m.main(sys.argv[1], ""))
PY
); then echo "selftest FAIL  a KNOWN_ON entry whose switch is present: scan stayed GREEN"; fail=1
elif grep -q 'listed KNOWN_ON but the off-switch is now in' <<<"$KO"; then echo "selftest ok    a KNOWN_ON entry whose switch is present: RED"
else echo "selftest FAIL  KNOWN_ON mechanism: red for the wrong reason"; fail=1; fi
if python3 - "$tmp/m" >/dev/null 2>&1 <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("egress_scan", "tools/lib/egress_scan.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
m.SWITCHES = [("synthetic absent", "observability", "KNOWN_ON", r"--no-such-switch-anywhere", "x", "n")]
sys.exit(m.main(sys.argv[1], ""))
PY
then echo "selftest ok    a KNOWN_ON entry whose switch is absent: GREEN"; else echo "selftest FAIL  a KNOWN_ON entry whose switch is absent went red"; fail=1; fi
fresh; sedi 's#http://www.w3.org/#http://www.example.com/#g' "$tmp/m/ai.yaml" "$tmp/m/ai.allon.yaml" "$tmp/m/platform.yaml" "$tmp/m/platform.allon.yaml" "$tmp/m/identity.yaml" "$tmp/m/identity.allon.yaml" "$tmp/m/observability.yaml" "$tmp/m/observability.allon.yaml" 2>/dev/null || true
expect_red "an ALLOW entry no render contains (stale)" "$tmp/m" 'ALLOW lists www.w3.org'
exit $fail

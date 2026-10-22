#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# With capabilities.observability off, no layer may render a ServiceMonitor,
# PodMonitor, PrometheusRule, ScrapeConfig or Probe, and the layers that cannot
# promise that on their own must refuse instead (TM-0825).
#
#   ./tools/check-capability-monitors.sh             the gate
#   ./tools/check-capability-monitors.sh --selftest  prove it can go red
#
# WHY THIS EXISTS. tockmox-crds renders no Prometheus-operator CRDs when the
# capability is off, yet policy, platform and identity kept rendering objects of
# those kinds, so on a cluster without the operator Argo rejected the layer on
# an unknown kind. check-capabilities.sh could not see it: it counts objects
# changing between on and off, and a layer that loses one object of fourteen
# still "changes".
#
# The two sources of monitors have different seams. Our own templates read the
# capability. A vendored subchart's values are static YAML and cannot, so its
# monitor has exactly one seam: the subchart's own switch. profiles/observability-off.yaml
# flips every one of them, and tockmox-platform and tockmox-identity refuse to
# render when the capability is off and any of those switches is still on.
#
# FOUR ASSERTIONS
#
#   A  A layer with NO subchart monitor switch (every layer but platform and
#      identity) renders zero monitor kinds with the capability off and nothing
#      else set.
#   R  REFUSAL. Platform and identity with the capability off and WITHOUT the
#      profile fail the render, and the message names the profile and every
#      switch the profile turns off in that layer. The switches are read from
#      the profile and from the layer's Chart.yaml dependencies, so a switch
#      added to the profile is demanded of the message automatically.
#   B  PROFILE. Capability off plus the profile: zero monitor kinds in all nine
#      layers, with and without ci/values-all-on.yaml.
#   D  BRING YOUR OWN OPERATOR. Capability off plus apps.serviceMonitors.enabled:
#      true renders in all nine layers (no coherence refusal, no R refusal), and
#      monitors DO render in the layers that have them, so D is not passing on an
#      empty extraction.
#   C  NOT VACUOUS. With the capability on, monitors DO render.
#
# Each assertion has a mutation in --selftest that must turn it red.
set -euo pipefail
cd "$(dirname "$0")/.."
LAYERS="crds platform policy identity observability exporters ai devops selfcheck"
KINDS='ServiceMonitor|PodMonitor|PrometheusRule|ScrapeConfig|Probe'
PROFILE_DEFAULT=profiles/observability-off.yaml
command -v helm >/dev/null 2>&1 || { echo "check-capability-monitors: helm not on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-capability-monitors: python3 not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-capability-monitors: python3 PyYAML missing" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# monitors <render-file>  ->  "<origin> <kind> <name>" per object. origin is `own`
# for a template of the tockmox-<layer> chart itself, `subchart:<name>` otherwise.
monitors() {
  python3 - "$1" "$KINDS" <<'PY'
import sys, re
kinds = set(sys.argv[2].split("|"))
for raw in open(sys.argv[1]).read().split("\n---"):
    m = re.search(r"^# Source: (\S+)", raw, re.M)
    k = re.search(r"^kind: (\S+)", raw, re.M)
    n = re.search(r"^  name: (\S+)", raw, re.M)
    if not (m and k and k.group(1) in kinds):
        continue
    parts = m.group(1).split("/")          # <chart>/templates/x  or <chart>/charts/<sub>/templates/x
    origin = "own" if parts[1] == "templates" else "subchart:" + parts[2]
    print(origin, k.group(1), n.group(1) if n else "?")
PY
}

# switches <profile> <chart-dir>  ->  the dotted path of every switch the
# profile sets in a subchart this chart depends on (everything but `capabilities`).
switches() {
  python3 - "$1" "$2/Chart.yaml" <<'PY'
import sys, yaml
prof = yaml.safe_load(open(sys.argv[1])) or {}
deps = {d["name"] for d in (yaml.safe_load(open(sys.argv[2])).get("dependencies") or [])}
def leaves(d, path):
    for k, v in d.items():
        if isinstance(v, dict): yield from leaves(v, path + [k])
        else: yield ".".join(path + [k])
for top, sub in prof.items():
    if top in deps and isinstance(sub, dict):
        for p in leaves(sub, [top]): print(p)
PY
}

# try_render <layer> <chart-dir> <out> [helm args]: returns helm's exit status,
# stdout in <out>, stderr in <out>.err. Never exits the script.
try_render() { local layer=$1 dir=$2 out=$3; shift 3
  helm template "tockmox-$layer" "$dir" -f ci/values.yaml "$@" > "$out" 2>"$out.err"; }

OFF=(--set capabilities.observability.enabled=false)
ALLON=(-f ci/values-all-on.yaml --set capabilities.observability.enabled=false --set capabilities.hardwareTelemetry.enabled=false)
BYO=(--set capabilities.observability.enabled=false --set apps.serviceMonitors.enabled=true)
BYO_ALLON=(-f ci/values-all-on.yaml --set capabilities.observability.enabled=false --set capabilities.hardwareTelemetry.enabled=false --set apps.serviceMonitors.enabled=true)

# gate_layer <layer> [chart-dir] [profile]: print findings for A, R and B and
# return their number.
gate_layer() {
  local l=$1 dir=${2:-charts/tockmox-$1} prof=${3:-$PROFILE_DEFAULT} n=0 line pass sw
  local exp; exp=$(switches "$prof" "$dir")
  # A / R: the capability off, no profile.
  if [ -z "$exp" ]; then
    if ! try_render "$l" "$dir" "$tmp/a-$l.yaml" "${OFF[@]}"; then
      echo "  FAIL  A  tockmox-$l does not render with the capability off"; sed 's/^/        /' "$tmp/a-$l.yaml.err" | head -3; n=$((n+1))
    else
      while read -r line; do
        echo "  FAIL  A  tockmox-$l renders ${line#* } (origin: ${line%% *}) with the capability off"; n=$((n+1))
      done < <(monitors "$tmp/a-$l.yaml")
    fi
  else
    if try_render "$l" "$dir" "$tmp/a-$l.yaml" "${OFF[@]}"; then
      echo "  FAIL  R  tockmox-$l rendered with the capability off and no profile, but has subchart monitor switches still on"; n=$((n+1))
    else
      if ! grep -q "$prof" "$tmp/a-$l.yaml.err"; then
        echo "  FAIL  R  tockmox-$l refused, but the message does not name $prof"; n=$((n+1)); fi
      for sw in $exp; do
        grep -qF "$sw" "$tmp/a-$l.yaml.err" || { echo "  FAIL  R  tockmox-$l refused, but the message does not name the switch $sw"; n=$((n+1)); }
      done
      echo "  refuses  tockmox-$l without the profile, naming $(wc -w <<<"$exp" | tr -d ' ') switch(es)" >> "$tmp/refused"
    fi
  fi
  # B: the capability off and the profile.
  for pass in plain allon; do
    if [ "$pass" = plain ]; then try_render "$l" "$dir" "$tmp/b-$l.yaml" "${OFF[@]}" -f "$prof"
    else try_render "$l" "$dir" "$tmp/b-$l.yaml" "${ALLON[@]}" -f "$prof"; fi || {
      echo "  FAIL  B  tockmox-$l ($pass) does not render with the capability off and the profile applied"; sed 's/^/        /' "$tmp/b-$l.yaml.err" | head -3; n=$((n+1)); continue; }
    while read -r line; do
      echo "  FAIL  B  tockmox-$l ($pass) still renders ${line#* } with the capability off and the profile applied (origin: ${line%% *})"; n=$((n+1))
    done < <(monitors "$tmp/b-$l.yaml")
  done
  return $n
}

# byo_layer <layer> [chart-dir]: assertion D. Prints "<count>" of monitor
# objects on the last stdout line via $tmp/byo-count; returns the finding count.
byo_layer() {
  local l=$1 dir=${2:-charts/tockmox-$1} n=0 pass c
  for pass in plain allon; do
    if [ "$pass" = plain ]; then try_render "$l" "$dir" "$tmp/d-$l.yaml" "${BYO[@]}"
    else try_render "$l" "$dir" "$tmp/d-$l.yaml" "${BYO_ALLON[@]}"; fi || {
      echo "  FAIL  D  tockmox-$l ($pass) does not render with the capability off and apps.serviceMonitors.enabled: true"; sed 's/^/        /' "$tmp/d-$l.yaml.err" | head -3; n=$((n+1)); continue; }
    c=$(monitors "$tmp/d-$l.yaml" | wc -l | tr -d ' ')
    [ "$pass" = plain ] && echo "$l $c" >> "$tmp/byo-count"
  done
  return $n
}

# byo_nonvacuous: the layers that own monitors must render some on this route.
byo_nonvacuous() {
  local n=0 l c
  for l in platform identity policy observability selfcheck; do
    c=$(awk -v l="$l" '$1==l{print $2}' "$tmp/byo-count")
    if [ "${c:-0}" -eq 0 ]; then echo "  FAIL  D  tockmox-$l renders no monitor object on the bring-your-own-operator route (the route renders nothing, or the extraction finds nothing)"; n=$((n+1)); fi
  done
  return $n
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  red() { # red <label> <rc> <output> <pattern>
    if [ "$2" -gt 0 ] && grep -q "$4" <<<"$3"; then echo "selftest ok   $1 goes RED ($2 finding)"
    else echo "selftest FAIL $1 did NOT go red (rc=$2)"; echo "$3" | head -5; fail=1; fi; }
  # 1. The extractor sees each kind and classifies origin (synthetic fixture).
  cat > "$tmp/fx.yaml" <<'FX'
---
# Source: tockmox-x/templates/a.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ours
---
# Source: tockmox-x/charts/sub/templates/b.yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: theirs
---
# Source: tockmox-x/templates/c.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: not-a-monitor
FX
  got=$(monitors "$tmp/fx.yaml" | tr '\n' ';')
  [ "$got" = "own ServiceMonitor ours;subchart:sub Probe theirs;" ] \
    && echo "selftest ok   extractor classifies own vs subchart and skips other kinds" \
    || { echo "selftest FAIL extractor: $got"; fail=1; }
  # mutate_copy <layer> <file-in-templates> <python replace expr: old> <new>
  mutate() { # mutate <layer> <dest-dir> <template> <old> <new>
    rm -rf "$2"; cp -R "charts/tockmox-$1" "$2"
    python3 - "$2/templates/$3" "$4" "$5" <<'PY'
import sys
p, old, new = sys.argv[1:4]; s = open(p).read()
assert old in s, "selftest: %r not found in %s; update the selftest" % (old, p)
open(p, "w").write(s.replace(old, new, 1))
PY
  }
  # Controls: the same layers copied the same way, untouched, must be green. A failed render is also a
  # finding under A, B, R and D, so a chart that will not render where it was copied to (its
  # file://../tockmox-common dependency left behind) would otherwise read below as a mutation going red.
  : > "$tmp/refused"; : > "$tmp/byo-count"
  for l in policy platform identity; do
    rm -rf "$tmp/c-$l"; cp -R "charts/tockmox-$l" "$tmp/c-$l"
    if gate_layer "$l" "$tmp/c-$l" >"$tmp/c.out" 2>&1 && byo_layer "$l" "$tmp/c-$l" >>"$tmp/c.out" 2>&1; then
      echo "selftest ok   control: an untouched copy of tockmox-$l is green where it is copied to"
    else
      echo "selftest FAIL control: an untouched copy of tockmox-$l is not green, so a red below could be the copy"; head -5 "$tmp/c.out"; fail=1
    fi
  done
  GATE='{{- if include "tockmox.capabilityEnabled" (dict "ctx" $ "capability" "observability" "app" "serviceMonitors") }}'
  # 2. A: policy with its rule gate removed renders a PrometheusRule with the capability off.
  mutate policy "$tmp/m-policy" rbac-guardrails.yaml "$GATE" '{{- if true }}'
  out=$(gate_layer policy "$tmp/m-policy") && rc=0 || rc=$?
  red "A  policy with its monitor gate removed" "$rc" "$out" 'FAIL  A  tockmox-policy renders '
  red "B  policy with its monitor gate removed, profile applied" "$rc" "$out" 'FAIL  B  tockmox-policy (plain) still renders '
  # 3. B: a profile that leaves one subchart switch on. It must fail on B (the
  # layer refuses with the profile applied) and nowhere be silently accepted.
  python3 - "$PROFILE_DEFAULT" "$tmp/prof-mut.yaml" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = "cert-manager:\n  prometheus:\n    servicemonitor:\n      enabled: false"
assert old in s
open(sys.argv[2], "w").write(s.replace(old, old.replace("false", "true"), 1))
PY
  out=$(gate_layer platform charts/tockmox-platform "$tmp/prof-mut.yaml") && rc=0 || rc=$?
  red "B  profile missing one subchart switch" "$rc" "$out" 'FAIL  B'
  red "B  profile missing one subchart switch (named in the refusal)" "$rc" "$out" 'still on: cert-manager.prometheus.servicemonitor.enabled'
  # 4. R: platform with the refusal switched off must go red; so must identity.
  REF='{{- if and (not $obsOn) (not $byo) -}}'
  mutate platform "$tmp/m-platform" preflight.yaml "$REF" '{{- if false -}}'
  out=$(gate_layer platform "$tmp/m-platform") && rc=0 || rc=$?
  red "R  platform with the refusal removed" "$rc" "$out" 'FAIL  R  tockmox-platform rendered with the capability off'
  mutate identity "$tmp/m-identity" preflight.yaml "$REF" '{{- if false -}}'
  out=$(gate_layer identity "$tmp/m-identity") && rc=0 || rc=$?
  red "R  identity with the refusal removed" "$rc" "$out" 'FAIL  R  tockmox-identity rendered with the capability off'
  # 5. R: the refusal still fires but no longer names the profile.
  mutate platform "$tmp/m-platform2" preflight.yaml 'pass profiles/observability-off.yaml to this layer' 'pass the right profile to this layer'
  out=$(gate_layer platform "$tmp/m-platform2") && rc=0 || rc=$?
  red "R  refusal message that does not name the profile" "$rc" "$out" 'FAIL  R  tockmox-platform refused, but the message does not name profiles/observability-off.yaml'
  # 6. D: the refusal fires on the bring-your-own route (the $byo exemption removed).
  mutate platform "$tmp/m-platform3" preflight.yaml "$REF" '{{- if not $obsOn -}}'
  : > "$tmp/byo-count"; out=$(byo_layer platform "$tmp/m-platform3") && rc=0 || rc=$?
  red "D  refusal that ignores apps.serviceMonitors" "$rc" "$out" 'FAIL  D'
  red "D  refusal that ignores apps.serviceMonitors (by the refusal's own message)" "$rc" "$out" 'vendored subchart monitor switch'
  # 7. D: the coherence guard back in the policy preflight refuses the route.
  python3 - "$tmp/m-policy2" <<'PY'
import sys, shutil
d = sys.argv[1]; shutil.copytree("charts/tockmox-policy", d, dirs_exist_ok=True)
p = d + "/templates/preflight.yaml"; s = open(p).read()
s += '\n{{- include "tockmox.capabilityCoherent" (dict "ctx" $ "capability" "observability" "apps" (list "serviceMonitors")) -}}\n'
open(p, "w").write(s)
PY
  : > "$tmp/byo-count"; out=$(byo_layer policy "$tmp/m-policy2") && rc=0 || rc=$?
  red "D  coherence guard on serviceMonitors back in policy" "$rc" "$out" 'FAIL  D'
  red "D  coherence guard on serviceMonitors back in policy (by its own message)" "$rc" "$out" 'apps.serviceMonitors.enabled is true but the observability capability is off'
  # 8. D non-vacuous: an empty count for platform is a finding.
  printf 'platform 0\nidentity 2\npolicy 1\nobservability 3\nselfcheck 1\n' > "$tmp/byo-count"
  out=$(byo_nonvacuous) && rc=0 || rc=$?
  red "D  route that renders no platform monitor" "$rc" "$out" 'FAIL  D  tockmox-platform renders no monitor object'
  # 9. The untouched tree is green on every assertion.
  : > "$tmp/refused"; : > "$tmp/byo-count"; bad=""
  for l in platform identity policy; do gate_layer "$l" >"$tmp/g.out" 2>&1 || bad="$bad $l(gate)"; byo_layer "$l" >>"$tmp/g.out" 2>&1 || bad="$bad $l(byo)"; done
  if [ -z "$bad" ]; then echo "selftest ok   restored tree is green (platform, identity, policy)"
  else echo "selftest FAIL restored tree is not green:$bad"; cat "$tmp/g.out"; fail=1; fi
  exit $fail
fi

: > "$tmp/refused"; : > "$tmp/byo-count"; total=0
echo "=== A, R and B: capability off, per layer ==="
for l in $LAYERS; do
  if out=$(gate_layer "$l"); then rc=0; else rc=$?; fi
  [ -n "$out" ] && echo "$out"
  total=$((total + rc))
done
echo
echo "=== R: layers that refuse the half-off state (capability off, profile not passed) ==="
sort "$tmp/refused"
echo
echo "=== D: bring your own operator (capability off, apps.serviceMonitors.enabled: true) ==="
for l in $LAYERS; do
  if out=$(byo_layer "$l"); then rc=0; else rc=$?; fi
  [ -n "$out" ] && echo "$out"
  total=$((total + rc))
done
awk '{printf "  tockmox-%s renders %s monitor object(s)\n", $1, $2}' "$tmp/byo-count"
if out=$(byo_nonvacuous); then :; else total=$((total + $?)); echo "$out"; fi
echo
echo "=== C: not vacuous (capability on) ==="
on=0
for l in platform identity policy; do
  try_render "$l" "charts/tockmox-$l" "$tmp/on-$l.yaml" || { echo "check-capability-monitors: tockmox-$l did not render" >&2; sed 's/^/  /' "$tmp/on-$l.yaml.err" >&2; exit 1; }
  c=$(monitors "$tmp/on-$l.yaml" | wc -l); echo "  tockmox-$l renders $c monitor object(s) with the capability on"; on=$((on + c))
done
[ "$on" -gt 0 ] || { echo "  FAIL  C  nothing renders with the capability on; the extractor finds nothing"; total=$((total+1)); }
echo
if [ "$total" -eq 0 ]; then echo "check-capability-monitors: clean"; else echo "check-capability-monitors: FAILED ($total finding(s))" >&2; exit 1; fi

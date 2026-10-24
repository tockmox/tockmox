#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Asserts that the capability framework does what the documentation says.
#
# WHY THIS EXISTS RATHER THAN A README PARAGRAPH. A capability is a promise that
# one key removes a whole functional story. That promise is invisible when it
# breaks: a component whose default is an explicit `true` keeps rendering after
# you decline the capability that supposedly owns it, and nothing complains. The
# render succeeds, the resource count barely moves, and the switch is decoration.
#
# That is not hypothetical. Every one of these checks was written against a real
# defect found while building the map on 2026-08-15:
#
#   hardwareTelemetry shipped `enabled: true` with both of its components
#   explicitly `false`, so the capability claimed a story it did not deliver.
#
#   ai_namespace, monitoring_netpol, authentik_netpol and devops_netpol all
#   defaulted to explicit `true`, which beats the tri-state, so declining
#   networkPolicy left every one of them rendering.
#
#   notifications.enabled defaulted to `true`, so its capability removed exactly
#   one object out of fourteen.
#
# CHECK 1  the capabilities block is byte-identical in all nine layers
# CHECK 2  every capability measurably changes the render in BOTH directions
# CHECK 3  component-on-with-capability-off fails the render, per capability
# CHECK 4  every apps.* key is owned by a capability or declared core, here
#
# Check 4 is the one that catches tomorrow's mistake: a new component added
# without a decision about which story it belongs to fails until someone makes
# that decision. Same reasoning as tools/check-storage-policy.sh, which exists
# because every volume in this repo sat on the wrong class for weeks.
set -euo pipefail

# SHELL GUARD -- bash 4.0+ required, and this refuses rather than lies.
#
# This gate uses `declare -A` (associative arrays), which arrived in bash 4.0.
# macOS still ships bash 3.2.57 as /bin/bash, where the compound assignment
# below arithmetic-evaluates the subscript, prints
#
#   check-capabilities.sh: line NN: kubePrometheusStack: unbound variable
#
# and -- this is the part that matters -- `set -euo pipefail` does NOT stop the
# script. Its sibling check-trust-wiring.sh has the same construct and was
# measured EXITING 0 on a stock Mac while examining nothing at all (TM-0245,
# 2026-08-31). A gate that fails is self-announcing. A gate that passes wrongly
# is not, and this repo's whole argument for gates is that a control fed by an
# unconnected wire looks identical to a control that works.
#
# So: refuse loudly, name the version found, and name the fix. CI is unaffected
# (Linux, bash 5). What this protects is LOCAL verification, which is exactly
# the verification a maintainer reaches for before pushing.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "check-capabilities: needs bash 4.0+ for associative arrays; found ${BASH_VERSION:-unknown}." >&2
  echo "  macOS ships bash 3.2 as /bin/bash. Install a newer one and run it explicitly:" >&2
  echo "    brew install bash && /opt/homebrew/bin/bash tools/check-capabilities.sh" >&2
  exit 2
fi

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
VALUES="${VALUES:-ci/values.yaml}"
# shellcheck source=tools/lib/tool-runs.sh
. tools/lib/tool-runs.sh

# --selftest: the helm partition below must hold for a helm that is on PATH
# and cannot run, not only for one that is absent. Runs this script end to end
# on a HERMETIC PATH (a fixture dir, then /usr/bin:/bin) so the machine's own
# helm can neither shadow nor be shadowed by the fixture.
if [ "${1:-}" = "--selftest" ]; then
  set +e
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/broken" "$tmp/empty"
  printf '\177ELF not a program for this machine\n' > "$tmp/broken/helm"; chmod +x "$tmp/broken/helm"
  fails=0
  probe() {
    local label="$1" dir="$2" why="$3" out rc
    out=$(PATH="$tmp/$dir:/usr/bin:/bin" "$BASH" "$SELF" 2>&1); rc=$?
    if [ "$rc" -ne 2 ] || ! grep -qF -- "$why" <<<"$out" || grep -qE '^  FAIL  |capability framework FAILED' <<<"$out"; then
      echo "  SELFTEST FAIL: '$label' wanted exit 2 naming '$why' and no finding, got exit $rc:"
      sed 's/^/            /' <<<"$out" | tail -n 25; fails=1
    else
      echo "  selftest ok: $label"
    fi
  }
  probe "a helm that is on PATH and cannot run skips the render checks, accusing nothing" broken "cannot run"
  probe "no helm skips the render checks, accusing nothing"                               empty  "not on PATH"
  [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
  echo "selftest FAILED"; exit 1
fi
LAYERS=(crds platform policy identity observability exporters ai devops selfcheck)
fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

# --------------------------------------------------------------------------
# The ownership manifest. THIS IS THE SOURCE OF TRUTH for check 4, and adding a
# component means adding it here, which is the point.
# --------------------------------------------------------------------------
declare -A OWNER=(
  [kubePrometheusStack]=observability [loki]=observability [alloy]=observability
  [blackbox]=observability [prometheusOperatorCrds]=observability
  [serviceMonitors]=observability [dashboards]=observability
  # K8. Owned by observability like its siblings, and follows it by default
  # since TM-0739 (it was shipped off before: ArgoCD is a PREREQUISITE, and the
  # argo-cd chart ships its metrics services disabled). Exercised in the OFF
  # direction like the rest.
  [argocdMonitoring]=observability
  [authentik]=identity
  [openWebui]=aiPlane [litellm]=aiPlane
  [garage]=dataProtection [docs]=dataProtection [barmanPlugin]=dataProtection
  [snapshotController]=dataProtection
  [snmp]=hardwareTelemetry [smartctl]=hardwareTelemetry
  [argoWorkflows]=workflowAutomation
  [ai_namespace]=networkPolicy [ai_cnpg_netpol]=networkPolicy
  [ai_openwebui_egress]=networkPolicy [authentik_netpol]=networkPolicy
  [devops_netpol]=networkPolicy [forgejo_netpol]=networkPolicy
  [harbor_netpol]=networkPolicy [monitoring_netpol]=networkPolicy
  [platform_netpol]=networkPolicy [selfcheck_netpol]=networkPolicy
  [syslog_ingest_netpol]=networkPolicy [tailscale_netpol]=networkPolicy
)
# Core: the substrate. Declining these is not a capability decision, it is a
# decision to run something other than Tockmox, so they stay plain app switches.
CORE=(certManager metallb traefik longhorn cnpg kured addressPool
      diagnostic_identity platform_policies traefik_headers rbac_guardrails
      healthRules heartbeat
      # kube_bench is not substrate, and it is not a capability either: it is an
      # opt-in scanner that is OFF by default and needs host access, and no
      # functional story owns it. It sits here because this list is what
      # "declared" means to check 4, and because a capability would be the wrong
      # promise (declining nothing removes nothing).
      kube_bench
      # etcdScrapeConfig is a site seam, not a story: OFF by default,
      # because its targets are the site's own control-plane addresses, and
      # declining observability already removes it (it renders only with the
      # serviceMonitors component).
      etcdScrapeConfig)

# Capabilities whose shipped default is OFF. They are exercised in the ON
# direction, because "declining it removes nothing" is true and uninformative.
DEFAULT_OFF=(hardwareTelemetry)

# Components that are deliberately NOT refused when on under a declined
# capability (check 3 asserts they RENDER instead). `serviceMonitors` is the
# "run your own Prometheus operator" route the capability text documents:
# decline the capability, pin the component, and Tockmox renders its monitors
# for the operator you already have (TM-0825).
BYO=(serviceMonitors)

# `|| true` is required, not sloppy: check 3 renders configurations that MUST
# fail, and under `set -e` a non-zero command substitution ends the script. The
# first run of this gate reported nothing for check 3 and exited 0, which is the
# worst possible outcome for a check ... silence read as success.
# DEPENDENCY ASSERTED BEFORE THE FIRST RENDER, and this is not boilerplate.
# On 2026-09-03 this gate ran with no helm on PATH. Every render returned the
# same empty string, so every capability looked like a switch that removed no
# object, and the gate emitted ELEVEN specific, confident, wrong findings ...
# eight "capabilities.X=false changes nothing" plus three under check 3 ...
# describing a design defect that does not exist. The only clue was a
# `helm: command not found` on an unrelated line.
#
# The `|| true` below stays: check 3 deliberately renders configurations that
# MUST fail, and under `set -e` a non-zero command substitution would end the
# script (that produced silence-read-as-success once already, see the note
# above it). The `|| true` was never the bug. Not knowing whether helm existed
# was the bug, and it belongs here, once, before anything renders.
#
# PARTITION, NOT REFUSE (TM-0713, 2026-09-17). The refusal above was right
# about checks 2 and 3 and wrong about the rest: checks 1, 4 and 5, and the
# manifest half of 3, read values files and templates with awk and never call
# helm, yet a missing helm stopped them too. So without helm the render checks
# are SKIPPED BY NAME and never run (the premise above stands), the others run,
# both counts print, and the exit is 1 on a finding and 2 otherwise. Exit 2 is
# the repository's "skipped" and is never a pass; it was exit 1 here before,
# which check-all.sh never saw because it refuses to start without helm.
#
# A HELM THAT CANNOT RUN IS NO HELM (2026-10-16). `command -v` passed a helm
# built for another architecture; render() then returned the same exec error
# for both sides of every comparison, and every capability was reported as a
# switch that does nothing. Whether helm EXECUTES is now the test
# (tools/lib/tool-runs.sh), and either failure takes the same partition.
HAVE_HELM=1; nrun=0; nskip=0
HELM_WHY="$(tool_why helm)"
skip() { printf '  SKIPPED  %s\n' "$*"; nskip=$((nskip + 1)); }
if [ "$(tool_state helm)" != ok ]; then
  HAVE_HELM=0
  echo "PARTIAL RUN: $HELM_WHY."
  echo
  echo "Check 2 and the coherence half of check 3 compare helm renders; without"
  echo "a working helm they would compare like to like and report every capability as a"
  echo "switch that does nothing, a page of findings about a defect that is not"
  echo "there. They are SKIPPED, by name, below. Checks 1, 4 and 5 and the"
  echo "manifest half of 3 need no helm and run as usual. This run cannot pass."
  echo
  echo "Install helm: https://helm.sh/docs/intro/install/"
  echo
fi

render() { helm template t "charts/tockmox-$1" -f "$VALUES" "${@:2}" 2>&1 || true; }
count()  { grep -c '^kind:' <<<"$1" || true; }
# Keys under the `apps:` block ONLY. Grepping the whole file for `^  <name>:`
# was wrong in a way that read as a pass: `authentik` and `openWebui` also
# appear under `namespaces` and `aiEgress` in the policy layer, so check 3
# asserted that the policy chart guards components it has never heard of, and
# reported the absence of that guard as a defect.
appkeys() {
  awk '/^apps:/{f=1;next}
       f && /^  [a-zA-Z_][a-zA-Z_0-9]*:/{ s=$0; sub(/:.*/,"",s); gsub(/ /,"",s); print s; next }
       f && /^[^ ]/{exit}' "charts/tockmox-$1/values.yaml"
}

# --------------------------------------------------------------------------
echo "== 1. the capabilities block is identical across layers =="
ref=""; refname=""
for l in "${LAYERS[@]}"; do
  # Stop at the first column-0 line that is not `capabilities:` itself. Testing
  # for /^[a-zA-Z]/ was not enough: the block is followed by a `# ----` banner in
  # some layers and not others, so the comparison failed on the NEXT section's
  # header rather than on any real drift.
  blk=$(awk '/^capabilities:/{f=1} f{ if (/^[^ ]/ && !/^capabilities:/) exit; print }' \
        "charts/tockmox-$l/values.yaml" | sed -e :a -e '/^\s*$/{$d;N;ba' -e '}')
  [ -z "$blk" ] && { bad "tockmox-$l has no capabilities block"; continue; }
  if [ -z "$ref" ]; then ref="$blk"; refname="$l"; continue; fi
  if [ "$blk" != "$ref" ]; then
    bad "tockmox-$l capabilities block differs from tockmox-$refname"
    # `|| true`: diff exits 1 on the very difference being reported, and under
    # set -e with pipefail that ended the gate here, so one finding in check 1
    # hid checks 2 to 5 (found 2026-09-23 proving TM-0713). Still exit 1.
    diff <(echo "$ref") <(echo "$blk") | head -12 | sed 's/^/        /' || true
  fi
done
# `next` after printing, and a COPY for the gsub. Both matter: gsub rewrites $0,
# so without the copy the exit rule below re-tested the stripped name, saw a
# letter in column 1, and stopped after the first capability. The check then
# passed while examining one eighth of the map.
CAPS=$(awk '/^capabilities:/{f=1;next}
            f && /^  [a-zA-Z]+:/{ s=$0; gsub(/[ :]/,"",s); print s; next }
            f && /^[^ ]/{exit}' "charts/tockmox-$refname/values.yaml")
note "$(wc -w <<<"$CAPS" | tr -d ' ') capabilities: $(tr '\n' ' ' <<<"$CAPS")"
nrun=$((nrun + 1))

# --------------------------------------------------------------------------
echo "== 2. every capability changes the render =="
if [ "$HAVE_HELM" -eq 0 ]; then
  skip "check 2 (every capability changes the render): needs helm"
else
  declare -A BASE
  for l in "${LAYERS[@]}"; do
    out=$(render "$l"); BASE[$l]=$(count "$out")
    [ -z "$out" ] && bad "tockmox-$l rendered nothing at baseline"
  done
  for cap in $CAPS; do
    flip=false; for d in "${DEFAULT_OFF[@]}"; do [ "$d" = "$cap" ] && flip=true; done
    $flip && set_to=true || set_to=false
    delta=0; where=""
    for l in "${LAYERS[@]}"; do
      # Unset every component this capability owns before flipping it. Otherwise
      # the test measures the values file rather than the capability: ci/values.yaml
      # pins apps.litellm.enabled: true, so declining aiPlane tripped the coherence
      # guard and the capability could never be exercised at all.
      clear=(); for c in "${!OWNER[@]}"; do
        # `apps.X.enabled=null` rather than `apps.X=null`: the schemas require an
        # object there, and the shared values namespace means one layer's null key
        # is validated by all nine.
        [ "${OWNER[$c]}" = "$cap" ] && clear+=(--set "apps.$c.enabled=null")
      done
      # Declining observability also needs the profile that turns off the
      # vendored subchart monitor switches: platform and identity REFUSE the
      # half-off state (TM-0825), so without it they could never be measured.
      prof=(); [ "$cap" = observability ] && [ "$set_to" = false ] && prof=(-f profiles/observability-off.yaml)
      out=$(render "$l" --set "capabilities.$cap.enabled=$set_to" ${clear[@]+"${clear[@]}"} ${prof[@]+"${prof[@]}"})
      if grep -q '^Error' <<<"$out"; then
        bad "capabilities.$cap=$set_to fails to render tockmox-$l"
        sed -n '1,3p' <<<"$out" | sed 's/^/        /'
        continue
      fi
      d=$(( ${BASE[$l]} - $(count "$out") )); d=${d#-}
      [ "$d" -ne 0 ] && { delta=$((delta+d)); where="$where $l:$d"; }
    done
    if [ "$delta" -eq 0 ]; then
      bad "capabilities.$cap=$set_to changes nothing. A switch that removes no object is decoration; either a component defaults to an explicit true and beats the tri-state, or nothing is wired to it."
    else
      note "$(printf '%-20s' "$cap") ->$set_to  ${delta} objects  [${where# }]"
    fi
  done
  nrun=$((nrun + 1))
fi

# --------------------------------------------------------------------------
echo "== 3. component-on with capability-off fails the render =="
for comp in "${!OWNER[@]}"; do
  cap="${OWNER[$comp]}"; seen=false
  # Neutralise every OTHER app this capability owns before forcing the one
  # under test on, exactly as check 2 does. Without it this check only ever
  # worked by template order: the coherence guard is a helm `fail`, which
  # aborts on the FIRST incoherent app it meets, so any app the base values
  # already force on under $cap (ci/values.yaml carries several) preempts the
  # message for the app under test, and the grep below reads a render that
  # DID fail as "did not fail". Found 2026-09-07 when ci/values gained
  # apps.ai_cnpg_netpol=true and all ten sibling networkPolicy apps went red at
  # once. The app under test is excluded from the clear and set LAST, so the
  # trailing --set is the one helm keeps.
  clear=(); for c in "${!OWNER[@]}"; do
    [ "${OWNER[$c]}" = "$cap" ] && [ "$c" != "$comp" ] && clear+=(--set "apps.$c.enabled=null")
  done
  for l in "${LAYERS[@]}"; do
    appkeys "$l" | grep -x "$comp" >/dev/null || continue
    seen=true
    # The render half needs helm and is skipped without it (reported once,
    # below); the manifest half above and after this loop does not.
    [ "$HAVE_HELM" -eq 1 ] || continue
    # ${clear[@]+...}: an EMPTY array expands to nothing under set -u on bash
    # 4.0-4.3 (single-component capabilities such as identity hit this); the
    # bare "${clear[@]}" form aborts there with "unbound variable".
    out=$(render "$l" --set "capabilities.$cap.enabled=false" ${clear[@]+"${clear[@]}"} --set "apps.$comp.enabled=true")
    # BYO components are the documented exception (TM-0825): the component is
    # the point and the capability is what the site declined, so the render
    # MUST succeed. Asserting the opposite direction keeps the exemption from
    # becoming a hole: a guard that comes back is red here.
    byo=false; for b in "${BYO[@]}"; do [ "$b" = "$comp" ] && byo=true; done
    if $byo; then
      grep -q '^Error' <<<"$out" && bad "tockmox-$l: apps.$comp=true with capabilities.$cap=false is the documented bring-your-own route and must render, but failed"
      continue
    fi
    if ! grep -q "apps.$comp.enabled is true but the $cap capability is off" <<<"$out"; then
      bad "tockmox-$l: apps.$comp=true with capabilities.$cap=false did not fail the render"
    fi
  done
  $seen || bad "apps.$comp is in the ownership manifest but no layer declares it"
done
nrun=$((nrun + 1))
if [ "$HAVE_HELM" -eq 1 ]; then
  note "${#OWNER[@]} owned components, coherence guard observed failing for each except the ${#BYO[@]} bring-your-own (${BYO[*]}), observed rendering"
else
  note "${#OWNER[@]} owned components, each declared by a layer (manifest half)"
  skip "check 3, coherence half (component-on with capability-off fails the render): needs helm"
fi

# --------------------------------------------------------------------------
echo "== 4. every apps.* key is owned or declared core =="
for l in "${LAYERS[@]}"; do
  keys=$(appkeys "$l")
  for k in $keys; do
    [ -n "${OWNER[$k]:-}" ] && continue
    core=false; for c in "${CORE[@]}"; do [ "$c" = "$k" ] && core=true; done
    $core || bad "tockmox-$l: apps.$k is neither owned by a capability nor declared core in $(basename "$0"). Decide which functional story it belongs to and add it to OWNER, or add it to CORE if it is substrate."
  done
done
note "manifest covers $(( ${#OWNER[@]} + ${#CORE[@]} )) components"
nrun=$((nrun + 1))

# --------------------------------------------------------------------------
echo "== 5. this manifest agrees with the chart's ownership map =="
chart=$(awk '/define "tockmox.capabilityOwners"/{f=1;next} f&&/{{- end -}}/{exit} f&&/:/{gsub(/ /,"");print}' \
        charts/tockmox-common/templates/_capabilities.tpl | sort)
mine=$(for k in "${!OWNER[@]}"; do echo "$k:${OWNER[$k]}"; done | sort)
if [ "$chart" != "$mine" ]; then
  bad "the ownership manifest in this script and tockmox.capabilityOwners disagree"
  diff <(echo "$chart") <(echo "$mine") | sed 's/^/        /' || true
else
  note "$(wc -l <<<"$chart" | tr -d ' ') entries, identical in both places"
fi
nrun=$((nrun + 1))

echo
if [ "$nskip" -gt 0 ]; then
  echo "$nrun check(s) run, $nskip skipped (named above; check 3 is in both, its"
  echo "manifest half ran): $HELM_WHY"
  if [ "$fail" -eq 0 ]; then
    echo "capability framework INCOMPLETE ... nothing run failed; exit 2, not a pass"
    exit 2
  fi
fi
[ "$fail" -eq 0 ] && echo "capability framework OK" || echo "capability framework FAILED"
exit "$fail"

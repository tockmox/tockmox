#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2016  # the selftest's sed expressions name template variables ($why, $h) and must stay literal
#
# THE RESILIENT PROFILE REFUSES TO PRESENT ITSELF AS RESILIENT (TM-0597).
#
#   ./tools/check-resilient-profile.sh              run every assertion
#   ./tools/check-resilient-profile.sh --selftest   mutate the guard and the alarm; each assertion must go red
#
# WHY THIS EXISTS. profiles/resilient.yaml sets global.resilience.profile. The
# two layers that have a database backup then refuse to render until the backup
# endpoint is outside the cluster, and render a two-alert drill alarm that does
# not depend on the drill itself rendering. A refusal that nothing exercises is
# decoration: a guard that stopped firing would render a profile called
# resilient with its backups inside the cluster, green everywhere, and say
# nothing. So this renders both layers and asserts on the OUTCOME:
#
#   A  the profile with no target of its own (the shipped endpoint is the
#      Garage inside the cluster) REFUSES, and the message names the reason
#   B  each in-cluster form REFUSES, naming its own reason
#   C  a real off-cluster endpoint RENDERS, and both alerts are in the render
#   D  backups off under the claim REFUSES
#   E  the drill disabled under the claim RENDERS, the alarm is in it, and the
#      drill CronJob is not: the case that read green before this alarm
#   F  without the claim nothing changes: no refusal, no alert
#   G  the bundled Authentik server's pg_dump bridge is held to the same rule
#   H  a misspelt claim is refused, by the schema and, with the schema off, by
#      the template
#
# C and E PIN THE ENDPOINT TEST'S LIMITS TOO: an IP address renders, because the
# test reads a name and never resolves one. docs/deployment/profiles.md says so,
# and if this check ever goes red on that line the page has to change with it.
#
# NOT CHECKED: that the alert FIRES. That is tests/rules/resilient-profile.yaml,
# run by tools/check-alert-rules.sh against the rules these renders carry. And
# not checked on a cluster at all: see PR / docs "What is not certified here".
#
# EXIT 2 is skipped, not passed, as everywhere in this directory.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=tools/lib/tool-runs.sh
. tools/lib/tool-runs.sh
for t in helm python3; do
  if [ "$(tool_state "$t")" != ok ]; then echo "check-resilient-profile: SKIPPED ... $(tool_why "$t")" >&2; exit 2; fi
done
python3 -I -c 'import yaml' 2>/dev/null || { echo "check-resilient-profile: SKIPPED ... python3 -I has no PyYAML" >&2; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0; NCHK=0
ok()   { NCHK=$((NCHK + 1)); echo "  ok    $*"; }
bad()  { NCHK=$((NCHK + 1)); FAILS=$((FAILS + 1)); echo "  FAIL  $*"; }

# shellcheck disable=SC2034  # read through ${!k} below
KEY_ai="modelGateway.database.backup.objectStore.endpoint"
# shellcheck disable=SC2034  # read through ${!k} below
KEY_identity="identity.database.backup.objectStore.endpoint"
ALERTS="TockmoxResilientDrillAbsent TockmoxResilientNoPassingDrill"

# hr LAYER OUTFILE [helm args...]  ->  helm template of the layer under ci/values.yaml; stderr to OUTFILE.err
hr() {
  hr_layer="$1"; hr_out="$2"; shift 2
  helm template t "$ROOT/charts/tockmox-$hr_layer" -f "$ROOT/ci/values.yaml" "$@" > "$hr_out" 2> "$hr_out.err"
}
PROFILE=(-f "$ROOT/profiles/resilient.yaml")

# refuses LAYER LABEL FIXED REGEX [helm args...]   non-zero exit AND the reason on stderr:
# FIXED is a literal that must appear (the key and value named), REGEX the reason's words.
refuses() {
  rf_layer="$1"; rf_label="$2"; rf_fixed="$3"; rf_re="$4"; shift 4
  rf_out="$T/rf.$NCHK.yaml"
  if hr "$rf_layer" "$rf_out" "$@"; then bad "$rf_layer: $rf_label ... RENDERED, wanted a refusal"; return; fi
  if grep -Fq -- "$rf_fixed" "$rf_out.err" && grep -Eq -- "$rf_re" "$rf_out.err"; then ok "$rf_layer: $rf_label ... refused, naming the reason"
  else bad "$rf_layer: $rf_label ... refused for another reason: $(head -c 240 "$rf_out.err")"; fi
}
# renders LAYER LABEL OUTVAR [helm args...]   exit 0; the path of the render goes in the variable OUTVAR
renders() {
  rn_layer="$1"; rn_label="$2"; rn_var="$3"; shift 3
  rn_out="$T/rn.$NCHK.yaml"
  if hr "$rn_layer" "$rn_out" "$@"; then ok "$rn_layer: $rn_label ... renders"; eval "$rn_var=\$rn_out"
  else bad "$rn_layer: $rn_label ... REFUSED, wanted a render: $(head -c 240 "$rn_out.err")"; eval "$rn_var="; fi
}
has_alerts() { # FILE LABEL
  for a in $ALERTS; do
    if grep -q "alert: $a\$" "$1"; then ok "$2 ... carries $a"; else bad "$2 ... does NOT carry $a"; fi
  done
}
no_alerts() { # FILE LABEL
  if grep -q "TockmoxResilient" "$1"; then bad "$2 ... carries a resilient alert it should not"; else ok "$2 ... carries no resilient alert"; fi
}
drill_cronjob() { # FILE  -> prints the number of CronJobs named *-db-drill
  python3 -I - "$1" <<'PY'
import sys, yaml
n = 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(d, dict) and d.get("kind") == "CronJob" and d["metadata"]["name"].endswith("-db-drill"):
        n += 1
print(n)
PY
}

# expect_n LABEL WANT GOT  -> ok or bad (no A && B || C)
expect_n() {
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (found $3, wanted $2)"; fi
}

check_A() {
  for L in ai identity; do
    k="KEY_$L"
    refuses "$L" "A the profile with no target of its own" "global.resilience.profile is resilient, but ${!k} is \"http://tockmox-garage" "not an off-cluster target" "${PROFILE[@]}"
  done
}
check_B() {
  for L in ai identity; do
    k="KEY_$L"
    while IFS='|' read -r ep why; do
      refuses "$L" "B endpoint [$ep]" "${!k} is \"$ep\", which is not an off-cluster target" "$why" "${PROFILE[@]}" --set "${!k}=$ep"
    done <<'LIST'
http://garage.tockmox-platform.svc:3900|Kubernetes Service name \(\.svc\)
http://garage.tockmox-platform.svc.cluster.local:3900|Kubernetes Service name \(\.svc\)
http://nas.example.cluster.local:9000|inside the cluster's DNS \(\.cluster\.local\)
http://minio:9000|bare name
http://minio.tockmox-platform:9000|is a Service in namespace
HTTP://Garage.tockmox-platform.SVC:3900|Kubernetes Service name \(\.svc\)
http://localhost:9000|loopback address
http://127.0.0.1:9000|loopback address
http://[::1]:9000|loopback address
http://[0:0:0:0:0:0:0:1]:9000|loopback address
http://[::ffff:127.0.0.1]:9000|loopback address
http://127.1.2.3:9000|loopback address
http://0.0.0.0:3900|unspecified address
http://[::]:3900|unspecified address
http://garage.tockmox-platform.svc.k8s.internal:3900|Kubernetes Service name \(\.svc\)
LIST
    refuses "$L" "B endpoint empty" "${!k} is empty" "REQUIRES an off-cluster object-store target" "${PROFILE[@]}" --set "${!k}="
  done
}
check_C() {
  for L in ai identity; do
    k="KEY_$L"
    for ep in https://s3.eu-west-1.amazonaws.com s3.offsite.example.net https://user:pw@s3.offsite.example.net:443/b http://192.168.1.50:9000 https://s3.svc.example.com http://[2001:db8::1]:9000; do
      renders "$L" "C endpoint [$ep]" OUT "${PROFILE[@]}" --set "${!k}=$ep"
    done
    renders "$L" "C the site's supplied target" OUT "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-$L.yaml"
    [ -n "$OUT" ] && has_alerts "$OUT" "$L: C the claim with a target"
  done
}
check_D() {
  refuses ai "D backups off under the claim" "model gateway's database backups are off" "A resilient install is backed up" "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-ai.yaml" --set modelGateway.database.backup.enabled=false
  refuses identity "D backups off under the claim" "identity database's backups are off" "A resilient install is backed up" "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-identity.yaml" --set identity.database.backup.enabled=false
}
check_E() {
  renders ai "E drill disabled under the claim" OUT "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-ai.yaml" --set modelGateway.database.backup.restoreDrill.enabled=false
  if [ -n "$OUT" ]; then
    has_alerts "$OUT" "ai: E drill disabled"
    expect_n "ai: E drill disabled ... no drill CronJob renders (this is the case that read green)" 0 "$(drill_cronjob "$OUT")"
  fi
  renders identity "E drill disabled under the claim" OUT "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-identity.yaml" --set identity.database.backup.restoreDrill.enabled=false
  if [ -n "$OUT" ]; then
    has_alerts "$OUT" "identity: E drill disabled"
    expect_n "identity: E drill disabled ... no drill CronJob renders" 0 "$(drill_cronjob "$OUT")"
  fi
  renders ai "E drill enabled (control)" OUT "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-ai.yaml"
  if [ -n "$OUT" ]; then expect_n "ai: E control ... the drill CronJob renders, so the disabled case above removed it" 1 "$(drill_cronjob "$OUT")"; fi
}
check_F() {
  for L in ai identity; do
    renders "$L" "F no claim" OUT --set capabilities.observability.enabled=true
    [ -n "$OUT" ] && no_alerts "$OUT" "$L: F no claim"
    renders "$L" "F empty claim" OUT --set global.resilience.profile=
    [ -n "$OUT" ] && no_alerts "$OUT" "$L: F empty claim"
  done
}
check_G() {
  B=(--set identity.database.enabled=false --set authentik.postgresql.enabled=true)
  refuses identity "G bundled server, shipped dump endpoint" "but databaseBackup.endpoint is \"http://tockmox-garage" "not an off-cluster target" "${PROFILE[@]}" "${B[@]}"
  refuses identity "G bundled server, dump off" "the pg_dump bridge) is off" "A resilient install is backed up" "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-identity.yaml" "${B[@]}" --set databaseBackup.enabled=false
  renders identity "G bundled server, off-cluster dump" OUT "${PROFILE[@]}" -f "$ROOT/ci/values-profile-resilient-tockmox-identity.yaml" "${B[@]}"
  [ -n "$OUT" ] && has_alerts "$OUT" "identity: G bundled server (no drill exists, the alarm says so)"
}
check_H() {
  refuses ai "H misspelt claim, schema on" "global/resilience/profile" "must be one of" --set global.resilience.profile=resilent
  refuses ai "H misspelt claim, schema off" "global.resilience.profile is \"resilent\"" "only value it takes" --skip-schema-validation --set global.resilience.profile=resilent
  refuses identity "H misspelt claim, schema off" "global.resilience.profile is \"resilent\"" "only value it takes" --skip-schema-validation --set global.resilience.profile=resilent
}

run_all() { check_A; check_B; check_C; check_D; check_E; check_F; check_G; check_H; }

if [ "${1:-}" = "--selftest" ]; then
  # A mutated copy of the charts, one mutation per assertion. Each mutation
  # runs ONLY the check it must break and must leave FAILS non-zero.
  M="$T/mut"; sf=0
  sedi() { local e="$1" f; shift; for f in "$@"; do sed "$e" "$f" > "$f.sedi" && mv "$f.sedi" "$f"; done; }
  fresh() {
    rm -rf "$M"; mkdir -p "$M"; cp -R "$ROOT/charts" "$ROOT/ci" "$ROOT/profiles" "$M/"
  }
  repack() {
    mkdir -p "$T/pkg"; rm -f "$T/pkg"/*.tgz
    helm package "$M/charts/tockmox-common" -d "$T/pkg" >/dev/null 2>&1 || return 1
    for tgz in "$M"/charts/*/charts/tockmox-common-*.tgz; do cp "$T/pkg"/tockmox-common-*.tgz "$tgz"; done
  }
  # mutation LABEL CHECK_FN SED_EXPR FILE...
  mutation() {
    mu_label="$1"; mu_fn="$2"; mu_expr="$3"; shift 3
    fresh
    mu_before=""; mu_files=()
    for f in "$@"; do mu_before="$mu_before$(cksum < "$M/$f")"; mu_files+=("$M/$f"); done
    sedi "$mu_expr" "${mu_files[@]}"
    mu_after=""; for f in "$@"; do mu_after="$mu_after$(cksum < "$M/$f")"; done
    if [ "$mu_before" = "$mu_after" ]; then echo "selftest FAIL: mutation '$mu_label' changed nothing, so it proves nothing"; sf=1; return; fi
    repack || { echo "selftest FAIL: could not repackage the mutated library chart"; sf=1; return; }
    ROOT="$M"; FAILS=0; NCHK=0
    "$mu_fn" > "$T/mut.out" 2>&1
    ROOT="$OLDROOT"
    if [ "$FAILS" -gt 0 ]; then echo "selftest ok: $mu_label goes red ($FAILS assertion(s) failed)"
    else echo "selftest FAIL: $mu_label stayed green"; sf=1; fi
  }
  OLDROOT="$ROOT"
  COMMON=charts/tockmox-common/templates/_resilience.tpl
  mutation "the refusal removed from the endpoint guard (A)" check_A 's/{{- if eq \$why "unset" -}}/{{- if false -}}/; s/{{- else if \$why -}}/{{- else if false -}}/' "$COMMON"
  mutation "the .svc rule removed from the endpoint test (B)" check_B 's/(hasSuffix "\.svc" \$h)/false/; s/(regexMatch "^\[a-z0-9-\]+[^)]*svc[^)]*" \$h)/false/' "$COMMON"
  mutation "the alarm renamed away in the AI layer (C)" check_C 's/alert: TockmoxResilientNoPassingDrill/alert: TockmoxResilientNoPassing/' charts/tockmox-ai/templates/resilience-alerts.yaml
  mutation "the alarm renamed away in the identity layer (C)" check_C 's/alert: TockmoxResilientDrillAbsent/alert: TockmoxResilientAbsent/' charts/tockmox-identity/templates/resilience-alerts.yaml
  mutation "the backups-off refusal removed from the AI guard (D)" check_D 's/{{- if not (include "tockmox-ai.dbBackupEnabled" .) -}}/{{- if false -}}/' charts/tockmox-ai/templates/resilience-guard.yaml
  mutation "the alarm tied to the drill being enabled (E)" check_E 's/(include "tockmox.appEnabled" (dict "ctx" . "app" "litellm")) }}/(include "tockmox.appEnabled" (dict "ctx" . "app" "litellm")) .Values.modelGateway.database.backup.restoreDrill.enabled }}/' charts/tockmox-ai/templates/resilience-alerts.yaml
  mutation "the claim always true (F)" check_F 's/{{- if eq \$p "resilient" -}}true/{{- if true -}}true/' "$COMMON"
  mutation "the bundled-server endpoint left unchecked (G)" check_G 's/{{- include "tockmox.resilience.requireOffClusterTarget" (dict "ctx" . "key" "databaseBackup.endpoint" "value" \$br.endpoint) -}}//' charts/tockmox-identity/templates/resilience-guard.yaml
  if [ "$sf" -eq 0 ]; then echo "selftest PASSED"; exit 0; fi
  echo "selftest FAILED"; exit 1
fi

echo "=== the resilient profile (TM-0597) ==="
run_all
echo
if [ "$FAILS" -eq 0 ]; then echo "check-resilient-profile: clean ($NCHK assertions)"; exit 0; fi
echo "check-resilient-profile: FAILED ($FAILS of $NCHK)" >&2; exit 1

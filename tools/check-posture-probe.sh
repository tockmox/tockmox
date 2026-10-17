#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE SECURITY POSTURE PROBE ADD-ON STAYS OBSERVE-ONLY (TM-0874, TM-0882).
#
#   ./tools/check-posture-probe.sh              the gate
#   ./tools/check-posture-probe.sh --selftest   prove it goes red on every mutation, and green untouched
#
# WHY. The probe's safety contract is structural: the role it runs under holds
# no write verb, so it cannot change the cluster even if its code were wrong
# (DESIGN threat model s1, in the add-on's docs). A contract nobody checks is a
# comment. A `patch` added to a Role for a convenience, a `secrets` read added
# "to show names", a NetworkPolicy dropped into a measured namespace to make a
# run pass: each is a one-line diff that helm lint, the schema and kubeconform
# all accept.
#
# WHAT IT ASSERTS, on the RENDERED add-on (addons/posture-probe/chart), and on
# the code beside it:
#   1. off by default: the default render is empty.
#   2. enabled, it renders; kubeconform -strict passes when kubeconform is on PATH
#      (said, not skipped silently, when it is not).
#   3. RBAC (tests/scan_render.py): every verb is get/list/watch, except create on
#      the two self-review oracles; no wildcard, subresource, secrets, logs, exec,
#      nonResourceURL, aggregation or resourceNames; reads only namespaces
#      (cluster) and pods/networkpolicies (declared namespaces); every binding
#      names a role this chart renders and only the probe's own account.
#   4. NetworkPolicy only in the add-on's namespace, no ingress, egress only DNS
#      and named API addresses; every pod restricted with a memory limit;
#      collectors keep their output out of logs and settle before measuring
#      (a new pod is not policed at once); reach collectors run as the
#      namespace default account; every rbac intent row is a question the
#      collector actually asks; the report claim is mounted by something that runs
#      at install (a claim only a CronJob mounts stays Pending on a
#      WaitForFirstConsumer StorageClass, which fails `helm --wait` and Argo health).
#   5. every top-level values key is `x-tockmox-stability: experimental`, and
#      values.yaml declares no key the schema does not.
#   6. the render refuses: no image, a measured release namespace, a row naming an
#      unknown target, a row with a dimension its target is not measured on.
#   7. the add-on's unit tests: engine, schema + gate exit-code contract (TM-0882),
#      termination transport, the differential against a fake API.
#
# WHAT IT DOES NOT PROVE. That the role is enough to run (the lab run proves
# that), that a CNI enforces what the policies say (that is what the probe
# itself measures), or anything about a cluster. It reads a render and runs
# unit tests.
set -uo pipefail
cd "$(dirname "$0")/.."

ADDON=addons/posture-probe
CHART=$ADDON/chart
REL_NS=tockmox-posture
command -v helm >/dev/null 2>&1 || { echo "check-posture-probe: helm missing" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-posture-probe: python3 missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-posture-probe: python3 PyYAML missing" >&2; exit 2; }

ON=(--set enabled=true --set image=registry.example.com/tockmox/posture-probe:0.1.0
    --set 'networkPolicy.apiServer[0].cidr=192.0.2.10/32')

# check CHARTDIR : all assertions; prints findings, returns non-zero on any.
check() {
  local chart="$1" rc=0 tmp out
  tmp=$(mktemp -d)
  out=$(helm template t "$chart" -n "$REL_NS" 2>&1) || { echo "  FAIL default render failed: $(echo "$out" | tail -1)"; rm -rf "$tmp"; return 1; }
  if printf '%s\n' "$out" | grep -q '^kind:'; then echo "  FAIL the default render is not empty: the add-on must be off until enabled"; rc=1
  else echo "  ok off by default: the default render holds no object"; fi
  if ! helm template t "$chart" -n "$REL_NS" "${ON[@]}" > "$tmp/on.yaml" 2> "$tmp/on.err"; then
    echo "  FAIL the enabled render failed: $(tail -1 "$tmp/on.err")"; rm -rf "$tmp"; return 1
  fi
  if command -v kubeconform >/dev/null 2>&1; then
    if kubeconform -strict -summary -ignore-missing-schemas "$tmp/on.yaml" > "$tmp/kc" 2>&1; then echo "  ok kubeconform -strict: $(tail -1 "$tmp/kc")"
    else echo "  FAIL kubeconform -strict:"; sed 's/^/    /' "$tmp/kc" | head -10; rc=1; fi
  else
    echo "  NOTE kubeconform not on PATH: the strict schema check of this render did NOT run"
  fi
  python3 "$ADDON/tests/scan_render.py" "$tmp/on.yaml" "$REL_NS" || rc=1
  python3 - "$chart" <<'PY' || rc=1
import json, sys, yaml
c = sys.argv[1]
s = json.load(open(c + "/values.schema.json")); v = yaml.safe_load(open(c + "/values.yaml"))
errs = []
if s.get("additionalProperties") is not False: errs.append("the values schema root is open: a misspelt key would pass")
for k, p in s["properties"].items():
    if p.get("x-tockmox-stability") != "experimental":
        errs.append("values key %s is %r, not experimental (0.8.0 ships the add-on experimental)" % (k, p.get("x-tockmox-stability")))
for k in v:
    if k not in s["properties"]: errs.append("values.yaml key %s is not in the schema" % k)
if v.get("enabled") is not False: errs.append("enabled does not default to false")
for e in errs: print("  FAIL " + e)
if not errs: print("  ok %d top-level values keys, every one experimental; enabled defaults to false" % len(s["properties"]))
sys.exit(1 if errs else 0)
PY
  refuse() { # refuse LABEL MESSAGE ARGS...
    local label="$1" msg="$2"; shift 2; local o
    if o=$(helm template t "$chart" -n "$REL_NS" "${ON[@]}" "$@" 2>&1); then echo "  FAIL rendered anyway: $label"; return 1; fi
    if printf '%s' "$o" | grep -qF "$msg"; then echo "  ok refused: $label"; else echo "  FAIL refused, but not for the stated reason: $label"; return 1; fi
  }
  refuse "enabled with no image" "image is empty" --set image= || rc=1
  refuse "installed into a measured namespace" "is also a measured namespace" -n tockmox-ai || rc=1
  refuse "a site row naming an undeclared target" "which this release does not declare" \
    --set 'intent.rows[0].subject=tockmox-ai->nowhere' --set 'intent.rows[0].dimension=ns-to-ns' --set 'intent.rows[0].intent=deny' || rc=1
  refuse "a row whose dimension its target is not measured on" "could never be observed" \
    --set 'intent.rows[0].subject=tockmox-ai->tockmox-platform' --set 'intent.rows[0].dimension=egress' --set 'intent.rows[0].intent=deny' || rc=1
  refuse "no API address for the differential's policy" "networkPolicy.apiServer is empty" --set 'networkPolicy.apiServer=null' || rc=1
  if o=$(helm template t "$chart" -n "$REL_NS" "${ON[@]}" --set 'namespaces={tockmox-platform,tockmox-monitoring}' --set 'identityVantages=null' 2>&1) \
     && printf '%s' "$o" | grep -q 'presetRowsDropped\\":[1-9]'; then echo "  ok preset rows for namespaces a site does not measure are dropped and counted, not failed"
  else echo "  FAIL the preset does not narrow to the measured namespaces (a declined capability would break the render)"; rc=1; fi
  rm -rf "$tmp"
  return $rc
}

unit() { # unit ADDONDIR
  local o
  if o=$(cd "$1" && python3 -m unittest discover -s tests 2>&1); then echo "  ok unit tests: $(printf '%s\n' "$o" | grep -E '^Ran ')"
  else echo "  FAIL unit tests:"; printf '%s\n' "$o" | grep -E 'FAIL:|ERROR:|AssertionError|^Ran|^FAILED' | head -12 | sed 's/^/    /'; return 1; fi
}

if [ "${1:-}" != "--selftest" ]; then
  rc=0
  check "$CHART" || rc=1
  unit "$ADDON" || rc=1
  [ "$rc" -eq 0 ] && echo "check-posture-probe: ok" || echo "check-posture-probe: FAILED"
  exit "$rc"
fi

# --- selftest: every mutation must turn the gate red for its own reason; the untouched copy green ---
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; fail=0
fresh() { rm -rf "$work/a"; mkdir -p "$work/a"; cp -R "$ADDON/." "$work/a/"; }
fresh
if o=$(check "$work/a/chart" 2>&1) && unit "$work/a" >/dev/null 2>&1; then echo "selftest ok    the unmutated add-on is GREEN"
else echo "selftest FAIL  the unmutated add-on is not green"; printf '%s\n' "$o" | grep FAIL | head -5; fail=1; fi

# mutate LABEL FILE PYEXPR EXPECTED [unit]
mutate() {
  fresh
  python3 - "$work/a/$2" "$3" <<'PY'
import re, sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read(); n = eval(expr)
assert n != s, "mutation did not change " + p
open(p, "w").write(n)
PY
  local o
  if [ "${5:-}" = unit ]; then o=$(unit "$work/a" 2>&1) && { echo "selftest FAIL  $1: unit tests stayed GREEN"; fail=1; return; }
  else o=$(check "$work/a/chart" 2>&1) && { echo "selftest FAIL  $1: gate stayed GREEN"; fail=1; return; }; fi
  if printf '%s' "$o" | grep -qF "$4"; then echo "selftest ok    $1: RED on '$4'"
  else echo "selftest FAIL  $1: red, but not for the expected reason"; printf '%s\n' "$o" | grep -E 'FAIL' | head -3; fail=1; fi
}
R=chart/templates/rbac.yaml
mutate "a write verb on the namespaced Role"        $R "s.replace('resources: [networkpolicies], verbs: [get, list]','resources: [networkpolicies], verbs: [get, list, patch]')" "WRITE verb(s) ['patch']"
mutate "delete on namespaces"                       $R "s.replace('resources: [namespaces], verbs: [get, list]','resources: [namespaces], verbs: [get, list, delete]')" "WRITE verb(s) ['delete']"
mutate "a wildcard verb"                            $R "s.replace('resources: [pods], verbs: [get, list]','resources: [pods], verbs: [\"*\"]')" "uses a wildcard"
mutate "secrets added to the read set"              $R "s.replace('resources: [pods], verbs','resources: [pods, secrets], verbs')" "which the probe must never touch"
mutate "pods/exec granted"                          $R "s.replace('resources: [pods], verbs: [get, list]','resources: [pods, pods/exec], verbs: [get, list, create]')" "must never touch"
mutate "update on the review oracle"                $R "s.replace('resources: [selfsubjectaccessreviews], verbs: [create]','resources: [selfsubjectaccessreviews], verbs: [create, update]')" "only create is a read there"
mutate "the binding moved to cluster-admin"         $R "s.replace('kind: ClusterRole, name: posture-probe-read-namespaces }','kind: ClusterRole, name: cluster-admin }')" "which this chart does not render"
mutate "a deployments read slipped in"              $R "s.replace('resources: [pods], verbs','resources: [pods, configmaps], verbs')" "outside the declared read set"
mutate "a NetworkPolicy dropped into a measured namespace" chart/templates/networkpolicy.yaml "s.replace('  name: posture-probe-differential\n  namespace: {{ .Release.Namespace }}','  name: posture-probe-differential\n  namespace: tockmox-ai')" "sits in a MEASURED namespace"
mutate "egress opened to everything"                chart/templates/networkpolicy.yaml "s.replace('- ipBlock: { cidr: {{ .cidr | quote }} }','- ipBlock: { cidr: \"0.0.0.0/0\" }')" "allows egress to 0.0.0.0/0"
mutate "collector output allowed into logs"         chart/templates/collectors.yaml "s.replace('terminationMessagePolicy: File','terminationMessagePolicy: FallbackToLogsOnError')" "must use terminationMessagePolicy File"
mutate "the reach collector given an account"       chart/templates/collectors.yaml "s.replace('\"sa\" \"\" \"file\"','\"sa\" \"posture-probe\" \"file\"')" "must run as the namespace's default account"
mutate "collectors measure without settling"  chart/templates/collectors.yaml "s.replace('                - { name: PROBE_SETTLE, value: /etc/probe/settle.json }\n','')" "measures inside the window"
mutate "the settle loop reports its first round" posture_probe/blackbox.py "s.replace('if streak >= cfg[\"stableRounds\"] and time.monotonic() - streak_t0 >= cfg[\"minSpanSeconds\"]:','if True:')" "test_default_reports_the_settled_state_not_the_first_second" unit
mutate "an unsettled collector's readings are kept" posture_probe/blackbox.py "s.replace('        return report, []\n','        pass\n',1).replace('            return [], {\"settled\": False, \"rounds\": rounds,','            return res, {\"settled\": False, \"rounds\": rounds,')" "test_a_control_that_never_holds_is_could_not_settle" unit
mutate "the report claim loses its install-time consumer" chart/templates/differential.yaml "re.sub(r'(?s)# Binds the report claim.*?(?=---\\napiVersion: batch/v1\\nkind: CronJob)','',s)" "has no consumer that runs at install"
mutate "a container may escalate"                   chart/templates/_helpers.tpl "s.replace('allowPrivilegeEscalation: false','allowPrivilegeEscalation: true')" "is not restricted"
mutate "the add-on on by default"                   chart/values.yaml "s.replace('enabled: false','enabled: true',1)" "FAIL default render failed"
mutate "a values key promoted to stable"            chart/values.schema.json "s.replace('\"experimental\"','\"stable\"',1)" "not experimental"
mutate "an rbac row the collector never asks"       chart/files/intent-tockmox-reference.json "s.replace('rbac:list nodes @*','rbac:list configmaps @*')" "never asks the oracle"
mutate "the image check removed"                    chart/templates/_helpers.tpl "s.replace('{{- if not \$v.image -}}','{{- if false -}}')" "FAIL rendered anyway: enabled with no image"
mutate "the schema accepts gateExit 3 (TM-0882)"    schema/report-v0.schema.json "s.replace('\"enum\": [\n            0,\n            1,\n            2\n          ]','\"enum\": [0, 1, 2, 3]')" "test_schema_is_versioned_and_states_the_contract" unit
mutate "unobserved rows read as clean"              posture_probe/differential.py "s.replace('    elif n(\"unknown\"):\n        gate = GATE_ERROR','    elif False:\n        gate = GATE_ERROR')" "test_unobserved_is_1_not_clean" unit
mutate "the differential skips its write check"     posture_probe/aggregate.py "s.replace('    bad = write_violations(cl, namespaces)','    bad = []')" "test_write_capable_identity_refuses_before_reading_anything" unit
mutate "identity vantages given network controls (N2)" posture_probe/blackbox.py "s.replace('    if not endpoints:\n','    if False:\n',1)" "test_an_identity_vantage_ignores_its_namespaces_network_controls" unit
[ "$fail" -eq 0 ] && echo "selftest ok    every mutation turned the gate red" || exit 1

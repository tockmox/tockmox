#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail if Tockmox renders a ClusterRole carrying an rbac.authorization.k8s.io/
# aggregate-to-* label that Tockmox's own deny-rbac-aggregation-injection policy
# does not allowlist.
#
# WHY THIS EXISTS. On a stock install, 2026-09-11 (TM-0505), the application
# controller logged six admission warnings against ClusterRoles Tockmox had just
# created itself:
#
#   tockmox-platform-cert-manager-view / -edit / -cluster-view
#   tockmox-devops-argo-workflows-view / -edit / -admin
#
# each saying "Add it to rbacGuardrails.aggregationAllowlist if that is
# intended." That is the product telling the operator to vouch for objects the
# product ships. Nothing was blocked, because denyAggregationInjection defaults
# to ["Audit","Warn"] ... but the values file invites tightening it to ["Deny"],
# and on that day a stock install would have failed with six denials from two
# shipped layers. A guardrail whose first act is to flag its own vendor is a
# guardrail operators learn to ignore.
#
# The six are allowlisted now. This gate exists so the SEVENTH cannot arrive
# quietly: adopting any subchart that ships an aggregated ClusterRole re-opens
# the defect with no visible signal, since the warning only appears at install
# time in a log nobody re-reads.
#
# TWO THINGS THIS GATE DOES DELIBERATELY
#
# 1. IT RENDERS WITH THE REAL RELEASE NAMES. Aggregated ClusterRole names are
#    release-prefixed, so `helm template t charts/tockmox-platform` produces
#    `t-cert-manager-view` ... a name that never exists on any cluster, and
#    would make this gate compare a fiction against the allowlist and pass while
#    the real install warns. The installer hardcodes each layer's Application
#    name as `tockmox-<layer>` (install/tockmox-install.sh, the LAYERS_ON loop),
#    and the Application name is the Helm release name, so `tockmox-<layer>` is
#    what ships. That is what this renders with. If the installer ever makes the
#    release name site-configurable, this gate and the allowlist both become
#    wrong and a label-based exemption is the replacement.
#
# 2. IT READS THE ALLOWLIST OUT OF THE RENDERED POLICY, not out of values.yaml.
#    The values key only matters if it reaches the ValidatingAdmissionPolicy's
#    `allowlist` CEL variable. Checking the values file would pass a tree where
#    the template stopped interpolating it ... configured and inert, which is a
#    shape this project has shipped before.
set -euo pipefail
cd "$(dirname "$0")/.."

# A gate that cannot render must REFUSE, never report clean.
command -v helm >/dev/null 2>&1 || { echo "check-rbac-aggregation-allowlist: REFUSING ... helm is not on PATH; cannot render, will not guess" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-rbac-aggregation-allowlist: REFUSING ... python3 is not on PATH" >&2; exit 2; }

scan() {
  # $1 = workdir holding <release>.yaml per layer, plus policy.yaml for the
  # rendered guardrail. Both are required; either missing is a refusal.
  python3 - "$1" <<'PY'
import sys, os, json, yaml

work = sys.argv[1]

# Some upstream subcharts emit the YAML 1.1 `=` (value) key, which PyYAML's
# SafeLoader has no constructor for. It is irrelevant to us, so accept it rather
# than let one subchart abort the whole scan.
yaml.SafeLoader.add_constructor(
    'tag:yaml.org,2002:value', lambda loader, node: loader.construct_scalar(node))

def documents(path):
    with open(path) as fh:
        for d in yaml.safe_load_all(fh):
            if isinstance(d, dict):
                yield d

AGG = 'rbac.authorization.k8s.io/aggregate-to-'

# ---- what the charts actually produce -------------------------------------
rendered = []       # (layer, clusterrole name)
empty_renders = []
for fn in sorted(os.listdir(work)):
    if not fn.endswith('.yaml') or fn == 'policy.yaml':
        continue
    path = os.path.join(work, fn)
    layer = fn[:-5]
    if os.path.getsize(path) == 0:
        empty_renders.append(layer)
        continue
    for d in documents(path):
        if d.get('kind') != 'ClusterRole':
            continue
        labels = (d.get('metadata') or {}).get('labels') or {}
        if any(str(k).startswith(AGG) for k in labels):
            rendered.append((layer, (d.get('metadata') or {}).get('name')))

# ---- what the shipped policy actually permits ------------------------------
policy_path = os.path.join(work, 'policy.yaml')
if not os.path.exists(policy_path) or os.path.getsize(policy_path) == 0:
    print("RENDER PRODUCED NOTHING for the policy layer; refusing to call this clean")
    sys.exit(1)

allowlist = None
for d in documents(policy_path):
    if d.get('kind') != 'ValidatingAdmissionPolicy':
        continue
    if (d.get('metadata') or {}).get('name') != 'deny-rbac-aggregation-injection':
        continue
    for var in (d.get('spec') or {}).get('variables') or []:
        if var.get('name') == 'allowlist':
            try:
                allowlist = set(json.loads(var.get('expression') or ''))
            except (ValueError, TypeError):
                print("THE POLICY'S allowlist VARIABLE IS NOT A PARSEABLE LIST:")
                print("  " + repr(var.get('expression')))
                print("  the template interpolated something this gate cannot read, so it")
                print("  cannot tell whether the shipped ClusterRoles are covered")
                sys.exit(1)

if allowlist is None:
    # The policy is off (denyAggregationInjection.enabled: false) or the
    # variable was renamed. Either way, say which rather than report clean.
    print("  deny-rbac-aggregation-injection did not render an `allowlist` variable")
    print("  in this pass; nothing to enforce here. If the policy is enabled, this")
    print("  is a template regression, not a clean result.")
    if rendered:
        print(f"  ({len(rendered)} aggregate-labelled ClusterRole(s) rendered and were NOT checked)")
    sys.exit(1)

if empty_renders:
    print("RENDER PRODUCED NOTHING for: " + ", ".join(empty_renders))
    print("  an empty render is a broken render, not a layer with no objects")
    sys.exit(1)

missing = [(l, n) for (l, n) in rendered if n not in allowlist]
if missing:
    print("AGGREGATE-LABELLED ClusterRoles TOCKMOX SHIPS BUT DOES NOT ALLOWLIST:")
    for layer, name in missing:
        print(f"  {name}   (from {layer})")
    sys.exit(1)

if rendered:
    print(f"  all {len(rendered)} aggregate-labelled ClusterRole(s) Tockmox renders are allowlisted")
else:
    print("  no aggregate-labelled ClusterRole rendered in this pass")
PY
}

# The release name each layer gets on a real install. Keep in step with the
# LAYERS_ON loop in install/tockmox-install.sh, which writes
# `metadata.name: tockmox-<layer>` into every generated Application.
render_ns() {
  case "$1" in
    tockmox-ai)                              echo tockmox-ai ;;
    tockmox-observability|tockmox-exporters) echo tockmox-monitoring ;;
    tockmox-platform)                        echo tockmox-platform ;;
    tockmox-identity)                        echo tockmox-authentik ;;
    tockmox-devops)                          echo tockmox-devops ;;
    tockmox-selfcheck)                       echo tockmox-selfcheck ;;
    *)                                       echo argocd ;;
  esac
}

pass() {
  local label="$1"; shift
  local work; work=$(mktemp -d)
  for c in charts/tockmox-*; do
    local n; n=$(basename "$c")
    [ "$n" = "tockmox-common" ] && continue
    local ns; ns=$(render_ns "$n")
    # Release name == chart name == what the installer generates. See note 1.
    helm template "$n" "$c" -n "$ns" -f ci/values.yaml "$@" > "$work/$n.yaml"
  done
  cp "$work/tockmox-policy.yaml" "$work/policy.yaml"
  rm -f "$work/tockmox-policy.yaml"
  echo "== pass: $label"
  local rc=0
  scan "$work" || rc=$?
  rm -rf "$work"
  echo
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0

  policy_doc() {
    cat <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-rbac-aggregation-injection
spec:
  variables:
    - name: allowlist
      expression: '$1'
EOF
  }

  # Direction 1: an un-allowlisted aggregated ClusterRole MUST trip the scan.
  bad=$(mktemp -d)
  policy_doc '["system:aggregate-to-view"]' > "$bad/policy.yaml"
  cat > "$bad/tockmox-platform.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tockmox-platform-newthing-view
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules: []
EOF
  if scan "$bad" >/dev/null 2>&1; then
    echo "check-rbac-aggregation-allowlist: SELFTEST FAILED ... an un-allowlisted aggregated ClusterRole passed"
    fail=1
  fi
  rm -rf "$bad"

  # Direction 2: the same ClusterRole, allowlisted, MUST pass.
  good=$(mktemp -d)
  policy_doc '["tockmox-platform-newthing-view"]' > "$good/policy.yaml"
  cat > "$good/tockmox-platform.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tockmox-platform-newthing-view
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules: []
EOF
  if ! scan "$good" >/dev/null 2>&1; then
    echo "check-rbac-aggregation-allowlist: SELFTEST FAILED ... an allowlisted ClusterRole was called missing"
    fail=1
  fi
  rm -rf "$good"

  # Direction 3: a ClusterRole with NO aggregate label is not this gate's
  # business and must not be demanded in the allowlist.
  plain=$(mktemp -d)
  policy_doc '["system:aggregate-to-view"]' > "$plain/policy.yaml"
  cat > "$plain/tockmox-platform.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tockmox-platform-ordinary-role
rules: []
EOF
  if ! scan "$plain" >/dev/null 2>&1; then
    echo "check-rbac-aggregation-allowlist: SELFTEST FAILED ... an unlabelled ClusterRole was demanded in the allowlist"
    fail=1
  fi
  rm -rf "$plain"

  # Direction 4: a rendered tree with the policy MISSING must refuse, not pass.
  # This is the configured-and-inert case the header argues about.
  inert=$(mktemp -d)
  cat > "$inert/policy.yaml" <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-rbac-aggregation-injection
spec:
  variables:
    - name: aggregates
      expression: 'true'
EOF
  cat > "$inert/tockmox-platform.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tockmox-platform-newthing-view
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules: []
EOF
  if scan "$inert" >/dev/null 2>&1; then
    echo "check-rbac-aggregation-allowlist: SELFTEST FAILED ... a policy with no allowlist variable read as clean"
    fail=1
  fi
  rm -rf "$inert"

  if [ "$fail" -ne 0 ]; then exit 1; fi
  echo "check-rbac-aggregation-allowlist: selftest passes (un-allowlisted trips; allowlisted passes; unlabelled ignored; missing variable refuses)"
  exit 0
fi

rc=0
pass "ci values (defaults + ci enables)" || rc=1
pass "all-on overlay" -f ci/values-all-on.yaml || rc=1

if [ "$rc" -ne 0 ]; then
  echo "Tockmox renders an aggregated ClusterRole its own guardrail does not permit."
  echo "On a stock install that prints an admission warning naming a Tockmox object"
  echo "and telling the operator to allowlist it. If denyAggregationInjection is ever"
  echo "moved to [\"Deny\"], it becomes an install failure instead."
  echo
  echo "Add the name to rbacGuardrails.aggregationAllowlist in"
  echo "charts/tockmox-policy/values.yaml, beside the other tockmox-* entries."
  exit 1
fi
echo "check-rbac-aggregation-allowlist: clean"

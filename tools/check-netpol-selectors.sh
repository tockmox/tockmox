#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail if any rendered NetworkPolicy carries a selector whose label VALUE is
# empty. An empty podSelector `{}` is valid Kubernetes and means "all pods";
# a matchLabels entry whose value renders to `""` is a different animal: it
# matches NOTHING, applies cleanly, reports Synced, and reads as protection.
#
# WHY THIS EXISTS. Found live on 2026-08-18: an ingress allow-rule whose
# namespaceSelector was
#
#   matchLabels:
#     kubernetes.io/metadata.name: ""
#
# because a site-supplied namespace name rendered empty. Every namespace
# carries that label set to its own name, so the empty string matched no
# namespace and the policy granted zero access. Failing closed was the lucky
# direction ... an egress allow or a default-deny exemption with the same
# defect fails open or strands a workload. The sibling rule six lines up was
# correct, which is what made the empty one look plausible on review.
#
# Same family as the ghost-policy gate (a policy that LOOKS like protection
# and is not), one level down: that gate asks "does anything live where this
# policy points", this one asks "can this selector ever match at all".
#
# Render-time, two passes: the CI defaults, then the all-on overlay
# (ci/values-all-on.yaml) so selectors that only render on non-default paths
# get checked too. The overlay exists because both this tool's first draft
# and the ghost gate once claimed a second pass they did not render. No
# allowlist, deliberately.
set -euo pipefail
cd "$(dirname "$0")/.."

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
    helm template t "$c" -n "$(render_ns "$n")" -f ci/values.yaml "$@" > "$work/$n.yaml"
  done
  echo "== pass: $label"
  local rc=0
  python3 - "$work" <<'PY' || rc=$?
import sys, os, yaml

work = sys.argv[1]
bad = []

def walk_selector(sel, where, doc_id):
    if not isinstance(sel, dict):
        return
    for key, val in (sel.get('matchLabels') or {}).items():
        if val is None or str(val) == '':
            bad.append(f"{doc_id}: {where}.matchLabels[{key!r}] renders empty ... matches nothing")
    for expr in (sel.get('matchExpressions') or []):
        vals = expr.get('values') or []
        if any(v is None or str(v) == '' for v in vals):
            bad.append(f"{doc_id}: {where}.matchExpressions[{expr.get('key')!r}] contains an empty value")

def documents(path):
    # Split the stream ourselves and parse per-document. The CRD layer's
    # render is enormous and one unparseable non-NetworkPolicy document must
    # not take down the check; an unparseable document that CLAIMS to be a
    # NetworkPolicy absolutely must.
    with open(path) as fh:
        text = fh.read()
    for chunk in text.split('\n---'):
        if 'kind:' not in chunk:
            continue
        try:
            yield yaml.safe_load(chunk)
        except yaml.YAMLError:
            if 'NetworkPolicy' in chunk:
                raise
            continue

for f in sorted(os.listdir(work)):
    if not f.endswith('.yaml'):
        continue
    if True:
        for doc in documents(os.path.join(work, f)):
            if not isinstance(doc, dict) or doc.get('kind') != 'NetworkPolicy':
                continue
            name = doc.get('metadata', {}).get('name', '?')
            doc_id = f"{f.removesuffix('.yaml')}/{name}"
            spec = doc.get('spec', {}) or {}
            walk_selector(spec.get('podSelector'), 'spec.podSelector', doc_id)
            for direction in ('ingress', 'egress'):
                for i, rule in enumerate(spec.get(direction) or []):
                    peers = rule.get('from' if direction == 'ingress' else 'to') or []
                    for j, peer in enumerate(peers):
                        for sk in ('podSelector', 'namespaceSelector'):
                            if sk in (peer or {}):
                                walk_selector(peer[sk], f"{direction}[{i}].{sk}", doc_id)

if bad:
    print("SELECTORS THAT CAN NEVER MATCH:")
    for b in bad:
        print(f"  {b}")
    sys.exit(1)
print("  all rendered NetworkPolicy selectors are satisfiable")
PY
  rm -rf "$work"
  echo
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  work=$(mktemp -d)
  cat > "$work/selftest.yaml" <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: broken-on-purpose
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ""
EOF
  if python3 - "$work" <<'PY'
import sys, os, yaml
work = sys.argv[1]
for f in os.listdir(work):
    with open(os.path.join(work, f)) as fh:
        for doc in yaml.safe_load_all(fh):
            if doc and doc.get('kind') == 'NetworkPolicy':
                for rule in doc.get('spec', {}).get('ingress') or []:
                    for peer in rule.get('from') or []:
                        ml = (peer.get('namespaceSelector') or {}).get('matchLabels') or {}
                        if any(str(v) == '' for v in ml.values()):
                            sys.exit(1)
sys.exit(0)
PY
  then
    echo "check-netpol-selectors: SELFTEST FAILED ... the broken fixture passed"
    rm -rf "$work"; exit 1
  fi
  rm -rf "$work"
  echo "check-netpol-selectors: selftest passes (the broken fixture trips)"
  exit 0
fi

rc=0
pass "ci values (defaults + ci enables)" || rc=1
pass "all-on overlay" -f ci/values-all-on.yaml || rc=1

if [ "$rc" -ne 0 ]; then
  echo "A selector with an empty label value matches nothing while reading as"
  echo "protection. Almost always a site value that rendered empty: require it"
  echo "with a preflight fail, or gate the rule on the value being set."
  exit 1
fi
echo "check-netpol-selectors: clean"

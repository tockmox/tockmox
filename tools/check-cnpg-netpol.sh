#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail if a rendered CNPG Cluster (a PostgreSQL database) has no NetworkPolicy
# in its namespace that both SELECTS its instance pods and applies to Ingress.
#
# WHY THIS EXISTS. A CNPG Cluster is a database. With no ingress policy over it,
# anything on the pod network can open :5432, and the object still renders,
# applies, and reports healthy ... the same "looks like coverage, is not" shape
# the ghost-policy and empty-selector gates already refuse, one rung further in.
# Those gates ask "does anything live where this policy points" and "can this
# selector match at all". Neither asks the inverse: does a database that DID
# render have a policy pointing AT it. Found by inspection 2026-09-06 (TM-0224):
# ci/values.yaml turns apps.litellm on (so the model gateway's CNPG Cluster
# renders) without apps.ai_cnpg_netpol (its ingress policy), so the CI render
# shipped an unprotected database. The two flags are meant to be turned on
# together; nothing enforced it.
#
# WHAT COUNTS AS PROTECTION. CNPG stamps every instance pod of every cluster it
# manages with `cnpg.io/podRole: instance` and `cnpg.io/cluster: <name>`, plus
# anything in the Cluster's spec.inheritedMetadata.labels. A NetworkPolicy
# protects the cluster when it is in the same namespace, applies to Ingress
# (policyTypes contains Ingress, or an `ingress:` block is present, or ... the
# Kubernetes default ... neither ingress nor egress nor policyTypes is set, a
# deny-all), and its podSelector either is empty (all pods) or is a subset of
# that known instance-pod label set. A podSelector on `cnpg.io/podRole:
# instance` is the correct, cluster-agnostic form (it covers a second cluster a
# restore drill creates in the same namespace); a podSelector naming one
# cluster by `cnpg.io/cluster` protects only that cluster and is accepted for
# the cluster it names.
#
# Two render passes, like the sibling selector gates: CI defaults, then the
# all-on overlay, so a Cluster that only renders on a non-default path is
# checked too.
set -euo pipefail
cd "$(dirname "$0")/.."

# A gate that cannot render must REFUSE, never report clean: `pass()` runs
# under `|| rc=1`, which switches `set -e` off inside it, so a missing helm
# would write nine empty files, find zero Clusters, and print "clean"
# (found by a zero-context review 2026-09-07).
command -v helm >/dev/null 2>&1 || { echo "check-cnpg-netpol: REFUSING ... helm is not on PATH; cannot render, will not guess" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-cnpg-netpol: REFUSING ... python3 is not on PATH" >&2; exit 2; }

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

scan() {
  # $1 = workdir of rendered per-layer YAML files, each named <layer>.yaml and
  # each carrying its render namespace as a comment on the first line.
  python3 - "$1" <<'PY'
import sys, os, yaml

work = sys.argv[1]
clusters = []   # (ns, name, known_pod_labels: dict)
policies  = []  # (ns, podSelector: dict|None, ingress: bool)

def effective_ns(doc, fallback):
    return (doc.get('metadata', {}) or {}).get('namespace') or fallback

def documents(path):
    # Parse per-document so one unparseable non-target doc (the CRD layer's
    # render is enormous) cannot take the check down, while an unparseable doc
    # that claims to be a Cluster or a NetworkPolicy still must.
    with open(path) as fh:
        text = fh.read()
    ns_hint = None
    first = text.split('\n', 1)[0]
    if first.startswith('# render-ns:'):
        ns_hint = first.split(':', 1)[1].strip()
    for chunk in text.split('\n---'):
        if 'kind:' not in chunk:
            continue
        try:
            yield yaml.safe_load(chunk), ns_hint
        except yaml.YAMLError:
            if 'kind: Cluster' in chunk or 'NetworkPolicy' in chunk:
                raise
            continue

empty_renders = []
for f in sorted(os.listdir(work)):
    if not f.endswith('.yaml'):
        continue
    with open(os.path.join(work, f)) as fh:
        if 'kind:' not in fh.read():
            empty_renders.append(f.removesuffix('.yaml'))
            continue
    for doc, ns_hint in documents(os.path.join(work, f)):
        if not isinstance(doc, dict):
            continue
        api = str(doc.get('apiVersion', ''))
        kind = doc.get('kind')
        ns = effective_ns(doc, ns_hint)
        if api.startswith('postgresql.cnpg.io/') and kind == 'Cluster':
            name = (doc.get('metadata', {}) or {}).get('name', '?')
            known = {'cnpg.io/podRole': 'instance', 'cnpg.io/cluster': name}
            inh = (((doc.get('spec', {}) or {}).get('inheritedMetadata', {}) or {})
                   .get('labels', {}) or {})
            for k, v in inh.items():
                known[k] = str(v)
            clusters.append((ns, name, known))
        elif kind == 'NetworkPolicy':
            spec = doc.get('spec', {}) or {}
            has_ingress = ('Ingress' in (spec.get('policyTypes') or [])
                           or 'ingress' in spec
                           or ('policyTypes' not in spec and 'egress' not in spec))
            policies.append((ns, spec.get('podSelector'), has_ingress))

def selects(podsel, known):
    # Empty or absent podSelector means all pods -> selects everything.
    if not podsel:
        return True
    ml = podsel.get('matchLabels') or {}
    me = podsel.get('matchExpressions') or []
    for k, v in ml.items():
        if str(known.get(k)) != str(v):
            return False
    for expr in me:
        key, op = expr.get('key'), expr.get('operator')
        vals = [str(x) for x in (expr.get('values') or [])]
        if op == 'Exists' and key not in known:
            return False
        if op == 'DoesNotExist' and key in known:
            return False
        if op == 'In' and str(known.get(key)) not in vals:
            return False
        if op == 'NotIn' and str(known.get(key)) in vals:
            return False
    return True

unprotected = []
for ns, name, known in clusters:
    ok = any(pns == ns and ing and selects(sel, known)
             for (pns, sel, ing) in policies)
    if not ok:
        unprotected.append(f"{ns}/{name}")

if empty_renders:
    print("RENDER PRODUCED NOTHING for: " + ", ".join(empty_renders))
    print("  an empty render is a broken render, not a layer with no objects; refusing to call this clean")
    sys.exit(1)
if unprotected:
    print("CNPG CLUSTERS WITH NO SELECTING INGRESS NetworkPolicy:")
    for u in unprotected:
        print(f"  {u}")
    sys.exit(1)
if clusters:
    print(f"  all {len(clusters)} rendered CNPG Cluster(s) carry a selecting ingress NetworkPolicy")
else:
    print("  no CNPG Cluster rendered in this pass")
PY
}

pass() {
  local label="$1"; shift
  local work; work=$(mktemp -d)
  for c in charts/tockmox-*; do
    local n; n=$(basename "$c")
    [ "$n" = "tockmox-common" ] && continue
    local ns; ns=$(render_ns "$n")
    { echo "# render-ns: $ns"; helm template t "$c" -n "$ns" -f ci/values.yaml "$@"; } > "$work/$n.yaml"
  done
  echo "== pass: $label"
  local rc=0
  scan "$work" || rc=$?
  rm -rf "$work"
  echo
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0

  # Direction 1: an unprotected Cluster MUST trip the scan.
  bad=$(mktemp -d)
  cat > "$bad/x.yaml" <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: naked-db
  namespace: tockmox-ai
spec:
  instances: 1
EOF
  if scan "$bad" >/dev/null 2>&1; then
    echo "check-cnpg-netpol: SELFTEST FAILED ... an unprotected CNPG Cluster passed"
    fail=1
  fi
  rm -rf "$bad"

  # Direction 2: the same Cluster WITH a selecting ingress policy MUST pass,
  # and a policy that selects it but is EGRESS-ONLY must NOT count as ingress
  # protection.
  good=$(mktemp -d)
  cat > "$good/x.yaml" <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: covered-db
  namespace: tockmox-ai
spec:
  instances: 1
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-cnpg-operator
  namespace: tockmox-ai
spec:
  podSelector:
    matchLabels:
      cnpg.io/podRole: instance
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-only-does-not-count
  namespace: tockmox-ai
spec:
  podSelector:
    matchLabels:
      cnpg.io/podRole: instance
  policyTypes: [Egress]
  egress:
    - {}
EOF
  if ! scan "$good" >/dev/null 2>&1; then
    echo "check-cnpg-netpol: SELFTEST FAILED ... a protected CNPG Cluster was called unprotected"
    fail=1
  fi
  rm -rf "$good"

  # Direction 3: an egress-only policy over an otherwise-naked Cluster must FAIL
  # (proving the ingress requirement, not just the selector).
  egress=$(mktemp -d)
  cat > "$egress/x.yaml" <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: egress-guarded-db, namespace: tockmox-ai }
spec: { instances: 1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: e, namespace: tockmox-ai }
spec:
  podSelector: { matchLabels: { cnpg.io/podRole: instance } }
  policyTypes: [Egress]
  egress: [ {} ]
EOF
  if scan "$egress" >/dev/null 2>&1; then
    echo "check-cnpg-netpol: SELFTEST FAILED ... an egress-only policy read as ingress protection"
    fail=1
  fi
  rm -rf "$egress"

  if [ "$fail" -ne 0 ]; then exit 1; fi
  echo "check-cnpg-netpol: selftest passes (naked trips; ingress-covered passes; egress-only trips)"
  exit 0
fi

rc=0
pass "ci values (defaults + ci enables)" || rc=1
pass "all-on overlay" -f ci/values-all-on.yaml || rc=1

if [ "$rc" -ne 0 ]; then
  echo "A CNPG Cluster is a database. One that renders with no ingress NetworkPolicy"
  echo "selecting it is reachable by anything on the pod network. Enable the policy"
  echo "that pairs with the database (in tockmox-ai, apps.ai_cnpg_netpol pairs with"
  echo "apps.litellm), or add a policy whose podSelector matches cnpg.io/podRole:"
  echo "instance in the database's namespace."
  exit 1
fi
echo "check-cnpg-netpol: clean"

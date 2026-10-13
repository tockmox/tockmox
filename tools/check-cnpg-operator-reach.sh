#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail if a rendered CNPG Cluster has no NetworkPolicy that lets the CNPG
# OPERATOR reach its instance pods on :8000 (the instance-manager status port).
#
# WHY THIS IS A DIFFERENT GATE FROM check-cnpg-netpol.sh. That one proves a
# database is not EXPOSED: some ingress policy selects it. A namespace-wide
# default-deny-ingress satisfies it, and rightly so. But a database behind a
# default-deny that the operator cannot reach does not WORK: the operator polls
# every instance's :8000 for status, and when that is denied the Cluster sits
# in
#
#     Instance Status Extraction Error: HTTP communication issue
#
# forever, with a phaseReason that names NetworkPolicy and is easy to read past.
# charts/tockmox-policy/templates/ai-default-deny.yaml records that exact
# failure being found by running the restore drill, not by reading the file.
# "Not exposed" and "reachable by its own operator" are two claims, and the
# second one is the one an operator finds out about at 2am.
#
# WHAT COUNTS. For each `postgresql.cnpg.io Cluster`, a same-namespace
# NetworkPolicy that applies to Ingress, whose podSelector selects the instance
# pods (`cnpg.io/podRole: instance`, `cnpg.io/cluster: <name>`,
# inheritedMetadata labels, or empty = all pods), and which carries at least one
# ingress rule with BOTH a `from` admitting the operator's namespace (a
# namespaceSelector on `kubernetes.io/metadata.name` equal to the policy
# chart's `namespaces.cnpg_system`, or an empty namespaceSelector, and NOT
# narrowed in the same peer by a podSelector ... both selectors in one peer
# must match the same pod, and the operator pod's labels are not known here)
# AND admits TCP 8000 (a listed port, an endPort range covering it, or no
# `ports:` key at all, which means every port). 5432 is reported but not
# required: the operator's status probe is :8000, and that is the one whose
# absence is silent.
#
# FAIL-CLOSED, stated: a NAMED port (`port: status`) cannot be resolved at
# render time and reads as not matching. That can red a correct tree; it
# cannot pass an unreachable one, which is the direction this gate protects.
#
# The operator namespace is read from charts/tockmox-policy/values.yaml
# (`namespaces.cnpg_system`), overridable with TOCKMOX_CNPG_OPERATOR_NS.
#
# Two render passes, like the sibling gates: CI defaults, then the all-on
# overlay.
set -euo pipefail
cd "$(dirname "$0")/.."

# A gate that cannot render must REFUSE, never report clean. `pass()` is
# invoked as `pass ... || rc=1`, which switches `set -e` off inside it, so a
# missing helm would otherwise write nine empty files, find zero Clusters, and
# print "clean" (measured by a zero-context review 2026-09-07). Same trap
# check-all.sh and check-capabilities.sh are written about.
command -v helm >/dev/null 2>&1 || { echo "check-cnpg-operator-reach: REFUSING ... helm is not on PATH; cannot render, will not guess" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-cnpg-operator-reach: REFUSING ... python3 is not on PATH" >&2; exit 2; }

OPERATOR_NS="${TOCKMOX_CNPG_OPERATOR_NS:-$(python3 -c "import yaml;print(yaml.safe_load(open('charts/tockmox-policy/values.yaml'))['namespaces']['cnpg_system'])")}"

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

scan() { # $1 = workdir, $2 = operator namespace
  python3 - "$1" "$2" <<'PY'
import sys, os, yaml

work, op_ns = sys.argv[1], sys.argv[2]
clusters, policies = [], []

def effective_ns(doc, fallback):
    return (doc.get('metadata', {}) or {}).get('namespace') or fallback

def documents(path):
    with open(path) as fh:
        text = fh.read()
    hint = None
    first = text.split('\n', 1)[0]
    if first.startswith('# render-ns:'):
        hint = first.split(':', 1)[1].strip()
    for chunk in text.split('\n---'):
        if 'kind:' not in chunk:
            continue
        try:
            yield yaml.safe_load(chunk), hint
        except yaml.YAMLError:
            if 'kind: Cluster' in chunk or 'NetworkPolicy' in chunk:
                raise
            continue

empty_renders = []
for f in sorted(os.listdir(work)):
    if not f.endswith('.yaml'):
        continue
    # An empty render is a broken render, not a layer with nothing in it: every
    # installable layer emits objects. Silence here must be an error.
    with open(os.path.join(work, f)) as fh:
        if 'kind:' not in fh.read():
            empty_renders.append(f.removesuffix('.yaml'))
            continue
    for doc, hint in documents(os.path.join(work, f)):
        if not isinstance(doc, dict):
            continue
        api, kind = str(doc.get('apiVersion', '')), doc.get('kind')
        ns = effective_ns(doc, hint)
        if api.startswith('postgresql.cnpg.io/') and kind == 'Cluster':
            name = (doc.get('metadata', {}) or {}).get('name', '?')
            known = {'cnpg.io/podRole': 'instance', 'cnpg.io/cluster': name}
            for k, v in ((((doc.get('spec', {}) or {}).get('inheritedMetadata', {}) or {}).get('labels', {}) or {})).items():
                known[k] = str(v)
            clusters.append((ns, name, known))
        elif kind == 'NetworkPolicy':
            spec = doc.get('spec', {}) or {}
            ing = ('Ingress' in (spec.get('policyTypes') or []) or 'ingress' in spec
                   or ('policyTypes' not in spec and 'egress' not in spec))
            policies.append((ns, (doc.get('metadata', {}) or {}).get('name', '?'),
                             spec.get('podSelector'), ing, spec.get('ingress') or []))

def selects(podsel, known):
    if not podsel:
        return True
    for k, v in (podsel.get('matchLabels') or {}).items():
        if str(known.get(k)) != str(v):
            return False
    for e in (podsel.get('matchExpressions') or []):
        key, op, vals = e.get('key'), e.get('operator'), [str(x) for x in (e.get('values') or [])]
        if op == 'Exists' and key not in known: return False
        if op == 'DoesNotExist' and key in known: return False
        if op == 'In' and str(known.get(key)) not in vals: return False
        if op == 'NotIn' and str(known.get(key)) in vals: return False
    return True

def admits_operator(rule):
    # A rule with NO `from` at all admits every source (Kubernetes semantics);
    # so does a rule that is an empty dict.
    if 'from' not in rule or rule.get('from') is None:
        return True
    # A `from` peer admits the operator ns if its namespaceSelector is empty
    # (all namespaces) or names op_ns on kubernetes.io/metadata.name ... AND
    # the same peer does not also narrow by podSelector to something that is
    # not the operator. In one peer both selectors must match the SAME pod, so
    # a peer with a non-empty podSelector cannot be shown here to admit the
    # operator (we do not know the operator pod's labels), and is refused.
    # A false "admits" is the direction that ships an unreachable database.
    for peer in (rule.get('from') or []):
        nsel = peer.get('namespaceSelector')
        psel = peer.get('podSelector')
        if nsel is None:
            continue
        if psel:  # non-empty podSelector narrows the peer: cannot decide, refuse
            continue
        if not nsel:
            return True
        ml = nsel.get('matchLabels') or {}
        if str(ml.get('kubernetes.io/metadata.name')) == op_ns:
            return True
        for e in (nsel.get('matchExpressions') or []):
            if e.get('key') == 'kubernetes.io/metadata.name' and e.get('operator') == 'In' \
               and op_ns in [str(x) for x in (e.get('values') or [])]:
                return True
    return False

def admits_port(rule, proto, port):
    # No `ports:` key means ALL ports (Kubernetes semantics). Otherwise match
    # protocol (default TCP) and either the exact port or an endPort range.
    # Named ports cannot be resolved at render time and are reported as not
    # matching; that is fail-closed and stated in the header.
    if 'ports' not in rule or rule.get('ports') is None:
        return True
    for p in rule.get('ports') or []:
        if str(p.get('protocol', 'TCP')).upper() != proto:
            continue
        lo = p.get('port')
        if lo is None:
            return True           # protocol-only entry: every port of that protocol
        try:
            lo_i = int(lo)
        except (TypeError, ValueError):
            continue              # named port: cannot resolve here
        hi_i = lo_i
        if p.get('endPort') is not None:
            try:
                hi_i = int(p['endPort'])
            except (TypeError, ValueError):
                hi_i = lo_i
        if lo_i <= port <= hi_i:
            return True
    return False

unreachable = []
for ns, name, known in clusters:
    ok8000, has5432, via = False, False, None
    for pns, pname, sel, ing, rules in policies:
        if pns != ns or not ing or not selects(sel, known):
            continue
        for rule in rules:
            if not admits_operator(rule):
                continue
            if admits_port(rule, 'TCP', 8000):
                ok8000, via = True, pname
                # 5432 is reported only when the SAME policy that grants 8000
                # also grants it, so the note cannot credit a different policy.
                if admits_port(rule, 'TCP', 5432):
                    has5432 = True
    if not ok8000:
        unreachable.append(f"{ns}/{name}")
    else:
        note = "" if has5432 else " (5432 not admitted from the operator ns ... bootstrap/switchover paths may fail)"
        print(f"  {ns}/{name}: operator reach on :8000 via {via}{note}")

if empty_renders:
    print("RENDER PRODUCED NOTHING for: " + ", ".join(empty_renders))
    print("  an empty render is a broken render, not a layer with no objects; refusing to call this clean")
    sys.exit(1)
if unreachable:
    print(f"CNPG CLUSTERS THE OPERATOR (ns {op_ns}) CANNOT REACH ON :8000:")
    for u in unreachable:
        print(f"  {u}")
    sys.exit(1)
if not clusters:
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
  echo "== pass: $label (operator ns: $OPERATOR_NS)"
  local rc=0
  scan "$work" "$OPERATOR_NS" || rc=$?
  rm -rf "$work"
  echo
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  mk() { local d; d=$(mktemp -d); cat > "$d/x.yaml"; echo "$d"; }
  # 1. Cluster behind a default-deny-ingress ONLY -> not exposed, but operator
  #    cannot reach it -> MUST trip. (This is exactly what check-cnpg-netpol
  #    accepts and this gate refuses; the two gates are meant to disagree here.)
  d=$(mk <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: sealed-db, namespace: tockmox-ai }
spec: { instances: 1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: tockmox-ai }
spec: { podSelector: {}, policyTypes: [Ingress] }
EOF
)
  if scan "$d" op-ns >/dev/null 2>&1; then echo "check-cnpg-operator-reach: SELFTEST FAILED ... a default-deny-only Cluster passed"; fail=1; fi
  rm -rf "$d"
  # 2. Cluster with the shipped allow-cnpg-operator shape -> MUST pass.
  d=$(mk <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: reachable-db, namespace: tockmox-ai }
spec: { instances: 1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-cnpg-operator, namespace: tockmox-ai }
spec:
  podSelector: { matchLabels: { cnpg.io/podRole: instance } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: op-ns } }
      ports: [ { protocol: TCP, port: 8000 }, { protocol: TCP, port: 5432 } ]
EOF
)
  if ! scan "$d" op-ns >/dev/null 2>&1; then echo "check-cnpg-operator-reach: SELFTEST FAILED ... the shipped shape was called unreachable"; fail=1; fi
  rm -rf "$d"
  # 3. Same rule but from the WRONG namespace -> MUST trip (the from matters).
  d=$(mk <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: wrong-ns-db, namespace: tockmox-ai }
spec: { instances: 1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-from-elsewhere, namespace: tockmox-ai }
spec:
  podSelector: { matchLabels: { cnpg.io/podRole: instance } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: not-the-operator } }
      ports: [ { protocol: TCP, port: 8000 } ]
EOF
)
  if scan "$d" op-ns >/dev/null 2>&1; then echo "check-cnpg-operator-reach: SELFTEST FAILED ... a rule from the wrong namespace passed"; fail=1; fi
  rm -rf "$d"
  # 4. Right namespace, wrong port (5432 only, no 8000) -> MUST trip.
  d=$(mk <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: no-8000-db, namespace: tockmox-ai }
spec: { instances: 1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-pg-only, namespace: tockmox-ai }
spec:
  podSelector: { matchLabels: { cnpg.io/podRole: instance } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: op-ns } }
      ports: [ { protocol: TCP, port: 5432 } ]
EOF
)
  if scan "$d" op-ns >/dev/null 2>&1; then echo "check-cnpg-operator-reach: SELFTEST FAILED ... a rule without :8000 passed"; fail=1; fi
  rm -rf "$d"
  # 5. Right namespace AND :8000, but the SAME peer also carries a podSelector
  #    naming something that is not the operator. Both selectors in one peer
  #    must match the same pod, so this admits nothing we can prove -> MUST
  #    trip. (A zero-context review found the first draft counting this as
  #    reachable, 2026-09-07.)
  d=$(mk <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: narrow-peer-db, namespace: tockmox-ai }
spec: { instances: 1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-not-the-operator, namespace: tockmox-ai }
spec:
  podSelector: { matchLabels: { cnpg.io/podRole: instance } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: op-ns } }
          podSelector: { matchLabels: { app: totally-not-the-operator } }
      ports: [ { protocol: TCP, port: 8000 } ]
EOF
)
  if scan "$d" op-ns >/dev/null 2>&1; then echo "check-cnpg-operator-reach: SELFTEST FAILED ... a peer narrowed by podSelector passed"; fail=1; fi
  rm -rf "$d"
  # 6. A rule with NO ports key admits all ports -> MUST pass (fail-closed
  #    would send a maintainer chasing a non-bug).
  d=$(mk <<'EOF'
# render-ns: tockmox-ai
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: all-ports-db, namespace: tockmox-ai }
spec: { instances: 1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-operator-all-ports, namespace: tockmox-ai }
spec:
  podSelector: { matchLabels: { cnpg.io/podRole: instance } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: op-ns } }
EOF
)
  if ! scan "$d" op-ns >/dev/null 2>&1; then echo "check-cnpg-operator-reach: SELFTEST FAILED ... a no-ports (all ports) rule was called unreachable"; fail=1; fi
  rm -rf "$d"
  [ "$fail" -eq 0 ] || exit 1
  echo "check-cnpg-operator-reach: selftest passes (deny-only trips; shipped shape passes; wrong-ns trips; no-8000 trips; podSelector-narrowed peer trips; no-ports rule passes)"
  exit 0
fi

rc=0
pass "ci values (defaults + ci enables)" || rc=1
pass "all-on overlay" -f ci/values-all-on.yaml || rc=1

if [ "$rc" -ne 0 ]; then
  echo "A CNPG Cluster its operator cannot reach on :8000 renders, applies and"
  echo "reports Synced, then sits in 'Instance Status Extraction Error' forever."
  echo "In tockmox-ai that is apps.ai_cnpg_netpol, which pairs with apps.litellm"
  echo "and is off by default: turn both on together, as the template says."
  exit 1
fi
echo "check-cnpg-operator-reach: clean"

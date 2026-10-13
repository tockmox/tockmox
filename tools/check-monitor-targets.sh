#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Every ServiceMonitor and PodMonitor the layers render selects something the
# layers render (TM-1025).
#
#   ./tools/check-monitor-targets.sh             render every layer and check
#   ./tools/check-monitor-targets.sh --selftest  prove it goes red
#
# WHY. A monitor whose selector matches nothing is not an error anywhere:
# Prometheus Operator generates a scrape job with no targets, Prometheus is
# healthy, and the only symptom is a series that never exists. For an alert
# written as absent(up == 1) that symptom is a permanent false alarm; for every
# other alert on that target it is permanent silence. The Tockmox UI shipped in
# 0.8.0-rc1 that way: its Service had no app.kubernetes.io/name label, the
# ServiceMonitor selected on it, and TockmoxUIUnreachable fired on a healthy pod
# on the reference site while the sign-in failure alert could never fire.
#
# WHAT IS CHECKED, on `helm template` of each layer with ci/values.yaml and
# ci/values-all-on.yaml, each layer in a namespace named after itself:
#   ServiceMonitor  a rendered Service in a namespace the monitor reads
#                   (its own, namespaceSelector.matchNames, or any), whose labels
#                   satisfy spec.selector, and which has every port the
#                   endpoints name.
#   PodMonitor      a rendered Deployment, StatefulSet or DaemonSet in such a
#                   namespace whose pod template labels satisfy spec.selector and
#                   whose containers declare every port the endpoints name.
# A monitor for something the layers do not render (the API server, the
# kubelet, Argo CD's own Services, pods an operator creates) is listed below
# with its reason. A listed monitor that now finds a target, or that no longer
# renders, is reported so the entry gets removed.
#
# NECESSARY, NOT SUFFICIENT: a matched target can still be unreachable (a
# NetworkPolicy, a wrong port number). It proves the wiring exists, not that a
# scrape succeeds; `up` on a live site does that.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-monitor-targets: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-monitor-targets: python3 PyYAML missing" >&2; exit 2; }

# <layer> <kind> <name>   # reason
EXTERNAL='
tockmox-observability ServiceMonitor t-kube-prometheus-stack-apiserver      # the API server Service default/kubernetes, created by Kubernetes
tockmox-observability ServiceMonitor t-kube-prometheus-stack-kubelet        # kube-system/<release>-kubelet, created by the Prometheus Operator
tockmox-observability ServiceMonitor tockmox-argocd-application-controller  # Argo CD metrics Services, from the Argo CD install, not a layer
tockmox-observability ServiceMonitor tockmox-argocd-server                  # same
tockmox-observability ServiceMonitor tockmox-argocd-repo-server             # same
'

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

cat > "$T/check.py" <<'PY'
import sys, os, yaml
try: L = yaml.CSafeLoader
except AttributeError: L = yaml.SafeLoader
external = set()
for line in sys.argv[1].splitlines():
    f = line.split("#")[0].split()
    if len(f) == 3: external.add(tuple(f))
docs = []
for path in sys.argv[2:]:
    layer = os.path.basename(path).rsplit(".", 1)[0]
    for d in yaml.load_all(open(path), Loader=L):
        if isinstance(d, dict) and d.get("kind"): docs.append((layer, d))
def ns(layer, d): return (d.get("metadata") or {}).get("namespace") or layer
def match(sel, labels):
    labels = labels or {}
    if not sel.get("matchLabels") and not sel.get("matchExpressions"): return True
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v: return False
    for e in sel.get("matchExpressions") or []:
        k, op, vals = e["key"], e["operator"], e.get("values") or []
        if op == "In" and labels.get(k) not in vals: return False
        if op == "NotIn" and labels.get(k) in vals: return False
        if op == "Exists" and k not in labels: return False
        if op == "DoesNotExist" and k in labels: return False
    return True
def readable(layer, d):
    nsel = (d.get("spec") or {}).get("namespaceSelector") or {}
    if nsel.get("any"): return None
    if nsel.get("matchNames"): return set(nsel["matchNames"])
    return {ns(layer, d)}
WORK = ("Deployment", "StatefulSet", "DaemonSet")
fails, seen, n = [], set(), 0
for layer, d in docs:
    kind = d["kind"]
    if kind not in ("ServiceMonitor", "PodMonitor"): continue
    n += 1
    name = d["metadata"]["name"]; key = (layer, kind, name); seen.add(key)
    sp = d.get("spec") or {}; sel = sp.get("selector") or {}; allowed = readable(layer, d)
    eps = sp.get("endpoints") if kind == "ServiceMonitor" else sp.get("podMetricsEndpoints")
    want = [e["port"] for e in eps or [] if isinstance(e.get("port"), str)]
    hits = []
    for l2, o in docs:
        if allowed is not None and ns(l2, o) not in allowed: continue
        if kind == "ServiceMonitor" and o["kind"] == "Service":
            if not match(sel, (o.get("metadata") or {}).get("labels")): continue
            names = {p.get("name") for p in (o.get("spec") or {}).get("ports") or []}
        elif kind == "PodMonitor" and o["kind"] in WORK:
            tpl = ((o.get("spec") or {}).get("template") or {})
            if not match(sel, (tpl.get("metadata") or {}).get("labels")): continue
            names = {p.get("name") for c in (tpl.get("spec") or {}).get("containers") or [] for p in c.get("ports") or []}
        else:
            continue
        if all(p in names for p in want): hits.append(o["metadata"]["name"])
    if key in external:
        if hits: print("  note: %s %s %s is listed as external but now selects %s; remove the entry" % (layer, kind, name, ", ".join(hits)))
        else: print("  external %s %s/%s" % (kind, ns(layer, d), name))
        continue
    if hits: print("  ok   %s %s/%s -> %s" % (kind, ns(layer, d), name, ", ".join(sorted(set(hits)))))
    else: fails.append("FAIL %s %s %s/%s selects nothing the layers render (selector %s, ports %s, namespaces %s)" % (layer, kind, ns(layer, d), name, sel, want or "-", sorted(allowed) if allowed else "any"))
for e in sorted(external - seen): print("  note: external entry renders no monitor, remove it: %s" % " ".join(e))
for f in fails: print(f)
print("check-monitor-targets: %d monitor(s), %d with no target" % (n, len(fails)))
sys.exit(1 if fails else 0)
PY

render() { # chart-dir out-dir
  local c="$1" o="$2"; mkdir -p "$o"
  for d in "$c"/tockmox-*; do
    local n; n=$(basename "$d"); case "$n" in tockmox-common|tockmox-crds) continue ;; esac
    helm template t "$d" -f ci/values.yaml -f ci/values-all-on.yaml --namespace "$n" > "$o/$n.yaml" 2> "$o/$n.err" \
      || { echo "check-monitor-targets: helm template failed for $n: $(head -c 300 "$o/$n.err")" >&2; return 2; }
  done
}

if [ "${1:-}" = "--selftest" ]; then
  render charts "$T/good" || exit 2
  python3 "$T/check.py" "$EXTERNAL" "$T"/good/*.yaml > "$T/out" || { cat "$T/out"; echo "selftest FAIL: the tree itself is red"; exit 1; }
  bad=0
  # M1: the 0.8.0-rc1 defect, the UI Service without the label its ServiceMonitor selects.
  mkdir -p "$T/m1"; cp "$T"/good/*.yaml "$T/m1/"
  python3 - "$T/m1/tockmox-ai.yaml" <<'PY2'
import sys, re
p = sys.argv[1]; s = open(p).read()
blocks = s.split("\n---\n"); out = []
for b in blocks:
    if re.search(r"^kind: Service$", b, re.M) and re.search(r"^  name: tockmox-ui$", b, re.M):
        b = b.replace("    app.kubernetes.io/name: tockmox-ui\nspec:", "spec:", 1)
    out.append(b)
open(p, "w").write("\n---\n".join(out))
PY2
  if python3 "$T/check.py" "$EXTERNAL" "$T"/m1/*.yaml > "$T/o1"; then echo "selftest FAIL: M1 the UI Service without its label passed"; bad=1
  elif grep -q 'FAIL tockmox-ai ServiceMonitor tockmox-ai/tockmox-ui selects nothing' "$T/o1"; then echo "selftest ok: M1 the UI Service without the label its ServiceMonitor selects goes red, naming it"
  else echo "selftest FAIL: M1 wrong output"; cat "$T/o1"; bad=1; fi
  # M2: the endpoint names a port the Service does not have.
  mkdir -p "$T/m2"; cp "$T"/good/*.yaml "$T/m2/"
  sed 's/    - { name: metrics, port: 9464, targetPort: metrics }/    - { name: metricz, port: 9464, targetPort: metrics }/' "$T/good/tockmox-ai.yaml" > "$T/m2/tockmox-ai.yaml"
  cmp -s "$T/good/tockmox-ai.yaml" "$T/m2/tockmox-ai.yaml" && { echo "selftest FAIL: M2 mutation did not apply"; bad=1; }
  if python3 "$T/check.py" "$EXTERNAL" "$T"/m2/*.yaml > "$T/o2"; then echo "selftest FAIL: M2 a missing port passed"; bad=1; else echo "selftest ok: M2 a ServiceMonitor port the Service does not declare goes red"; fi
  # M3: a PodMonitor whose selector no pod template carries.
  mkdir -p "$T/m3"; cp "$T"/good/*.yaml "$T/m3/"
  python3 - "$T/m3/tockmox-platform.yaml" <<'PY3' || { echo "selftest FAIL: M3 setup"; bad=1; }
import sys, re
p = sys.argv[1]; s = open(p).read(); out = []; done = 0
for b in s.split("\n---\n"):
    if re.search(r"^kind: PodMonitor$", b, re.M):
        # the selector's copy (six spaces), not the PodMonitor's own metadata label
        b = b.replace("      app.kubernetes.io/name: cloudnative-pg\n", "      app.kubernetes.io/name: cloudnative-pgx\n", 1); done += 1
    out.append(b)
open(p, "w").write("\n---\n".join(out)); sys.exit(0 if done else 1)
PY3
  if python3 "$T/check.py" "$EXTERNAL" "$T"/m3/*.yaml > "$T/o3"; then echo "selftest FAIL: M3 an unmatched PodMonitor passed"; bad=1; else echo "selftest ok: M3 a PodMonitor no pod template matches goes red"; fi
  # M4: an external entry that has started matching is reported.
  python3 "$T/check.py" "$EXTERNAL
tockmox-ai ServiceMonitor tockmox-ui # wrong" "$T"/good/*.yaml > "$T/o4"
  if grep -q 'listed as external but now selects tockmox-ui' "$T/o4"; then echo "selftest ok: M4 a stale external entry is reported"; else echo "selftest FAIL: M4 stale external entry not reported"; bad=1; fi
  [ "$bad" = 0 ] && echo "check-monitor-targets selftest: ok" || echo "check-monitor-targets selftest: FAILED"
  exit "$bad"
fi

render charts "$T/r" || exit 2
python3 "$T/check.py" "$EXTERNAL" "$T"/r/*.yaml

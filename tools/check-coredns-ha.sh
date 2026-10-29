#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED OBJECTS, what the opt-in CoreDNS high availability
# (apps.corednsHa, tockmox-platform) is allowed to write into kube-system.
#
#   ./tools/check-coredns-ha.sh              the cases below
#   ./tools/check-coredns-ha.sh --selftest   prove each assertion can go red
#   COREDNS_HA_CHART=DIR ./tools/check-coredns-ha.sh   assert on another copy of the chart
#
#   stock render       no HorizontalPodAutoscaler and no PodDisruptionBudget in
#                      kube-system, and none named tockmox-coredns-ha anywhere
#                      (kube-system holds other objects on a stock render, the
#                      cert-manager leader-election Roles; only the CoreDNS-HA
#                      pair is asserted absent)
#   switch on          the render gains exactly two objects over the stock render
#                      and loses none, and they are the HPA and the PDB, both in
#                      kube-system: the HPA scales
#                      Deployment coredns with minReplicas equal to the floor
#                      (read at the default and at 3, so the value is wired and
#                      not a constant), the PDB has maxUnavailable 1 and selects
#                      k8s-app: kube-dns. No Deployment, ConfigMap or Service
#                      appears: the distro's Deployment is never taken over.
#   floor 1 or 0       refused, and the refusal NAMES the reason. The error text
#                      is read, not the exit code: `helm template` exits 1 for
#                      every failure, and a case that broke for another reason
#                      (a missing value, a schema error) must not read as
#                      "refused".
#   floor 1, switch off  renders exactly the stock render: off means off.
#   ceiling < floor, empty Deployment name, empty pod labels   each refused by name.
#   the other eight layers  render with the keys set: the values namespace is one
#                      namespace, a profile goes to every layer, and each layer's
#                      schema must name the key to accept it.
#
# The scan must reach the corpus it claims: the stock render is required to
# parse to a large number of objects and to contain the cert-manager Roles in
# kube-system, so a render that silently came back empty cannot pass.
#
# NOT PROVEN: that the autoscaler holds the floor across a k3s restart, that a
# drain on a cluster with several schedulable nodes keeps DNS up, and that the
# names and labels in the defaults are the ones a given k3s release uses. Those
# need a cluster; this gate proves the shape the chart renders and the refusals.
# shellcheck disable=SC2016  # the mutations' search strings are Helm template text, matched literally, not shell variables
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
command -v helm >/dev/null 2>&1 || { echo "check-coredns-ha: helm not on PATH" >&2; exit 2; }
# Probed the way the checks run (-I, isolated).
python3 -I -c 'import yaml' 2>/dev/null || { echo "check-coredns-ha: python3 -I (isolated) has no PyYAML" >&2; exit 2; }

if [ "${1:-}" = "--selftest" ]; then
  # Each mutation of the chart must turn the check red; the unmutated copy must
  # be green. A check that cannot go red is not a check. The mutations are made
  # on a COPY of the chart, never on the tree.
  st="$(mktemp -d "${TMPDIR:-/tmp}/coredns-ha-st.XXXXXX")"; trap 'rm -rf "$st"' EXIT
  rc=0
  fresh() { rm -rf "$st/c"; mkdir -p "$st/c"; cp -R charts "$st/c/charts"; }
  run() { COREDNS_HA_CHART="$st/c/charts/tockmox-platform" bash tools/check-coredns-ha.sh >"$st/out" 2>&1; }
  fresh
  if run; then echo "  ok   unmutated copy: green"; else echo "  FAIL unmutated copy should be green"; cat "$st/out"; rc=1; fi
  mutate() { # file-in-chart, python replace pair (old, new): must change the file
    python3 -I - "$st/c/charts/$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
t = open(p).read()
if old not in t:
    print("mutation target not found: " + old); sys.exit(3)
open(p, "w").write(t.replace(old, new, 1))
PY
  }
  expect_red() { # name, file, old, new
    fresh
    if ! mutate "$2" "$3" "$4"; then echo "  FAIL mutation '$1' did not apply"; rc=1; return; fi
    if run; then echo "  FAIL mutation '$1' stayed green"; rc=1; else echo "  ok   mutation '$1': red"; fi
  }
  expect_red "the budget allows two unavailable"  tockmox-platform/templates/coredns-ha.yaml 'spec:
  maxUnavailable: 1' 'spec:
  maxUnavailable: 2'
  expect_red "the budget selects another label"   tockmox-platform/templates/coredns-ha.yaml 'matchLabels:' 'matchLabels:
      extra: label'
  expect_red "the HPA floor is a constant"        tockmox-platform/templates/coredns-ha.yaml 'minReplicas: {{ $c.minReplicas }}' 'minReplicas: 2'
  expect_red "the HPA targets another Deployment" tockmox-platform/templates/coredns-ha.yaml 'name: {{ $c.deployment }}' 'name: coredns-other'
  expect_red "the objects render with the switch off" tockmox-platform/templates/coredns-ha.yaml '{{- if include "tockmox.appEnabled" (dict "ctx" $ "app" "corednsHa") }}' '{{- if true }}'
  expect_red "the chart renders the Deployment too" tockmox-platform/templates/coredns-ha.yaml '{{- end }}
' '---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
spec:
  replicas: 1
  selector: { matchLabels: { x: y } }
  template: { metadata: { labels: { x: y } }, spec: { containers: [ { name: c, image: i } ] } }
{{- end }}
'
  expect_red "the floor guard is gone"            tockmox-platform/templates/preflight.yaml 'lt (int ($c.minReplicas | default 0)) 2' 'lt (int ($c.minReplicas | default 0)) 0'
  expect_red "the ceiling guard is gone"          tockmox-platform/templates/preflight.yaml 'lt (int ($c.maxReplicas | default 0)) (int $c.minReplicas)' 'lt 1 0'
  expect_red "the empty-selector guard is gone"   tockmox-platform/templates/preflight.yaml '{{- if not $c.podLabels -}}' '{{- if false -}}'
  expect_red "the empty-name guard is gone"       tockmox-platform/templates/preflight.yaml '{{- if not $c.deployment -}}' '{{- if false -}}'
  expect_red "another layer rejects the keys"    tockmox-policy/values.schema.json '"corednsHa": {' '"corednsHaGone": {'
  expect_red "the refusal loses its reason"       tockmox-platform/templates/preflight.yaml 'needs a floor of at least 2' 'needs something'
  exit "$rc"
fi

chart="${COREDNS_HA_CHART:-charts/tockmox-platform}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/coredns-ha.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n       %s\n' "$1" "$2"; fail=1; }
echo "helm: $(helm version --short 2>/dev/null)"

render() { # out-file, extra helm args...
  local o="$1"; shift
  helm template t "$chart" -f ci/values.yaml "$@" > "$o" 2>"$o.err"
}

# objects FILE: prints every object as "kind/namespace/name", sorted, then a line
# "DOCS <n>" with the number of parsed objects.
objects() {
  python3 -I - "$1" <<'PY'
import sys, yaml
n = 0; out = []
for d in yaml.load_all(open(sys.argv[1]), Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader)):
    if not isinstance(d, dict) or not d.get("kind"): continue
    n += 1
    m = d.get("metadata") or {}
    out.append("%s/%s/%s" % (d["kind"], m.get("namespace", "-"), m.get("name")))
for o in sorted(out): print(o)
print("DOCS %d" % n)
PY
}

# pair FILE: prints the CoreDNS-HA HPA and PDB facts as tab-separated fields,
# or MISSING.
pair() {
  python3 -I - "$1" <<'PY'
import sys, yaml
hpa = pdb = None; extra = []
for d in yaml.load_all(open(sys.argv[1]), Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader)):
    if not isinstance(d, dict): continue
    m = d.get("metadata") or {}
    if m.get("name") != "tockmox-coredns-ha": continue
    if d["kind"] == "HorizontalPodAutoscaler": hpa = d
    elif d["kind"] == "PodDisruptionBudget": pdb = d
    else: extra.append(d["kind"])
if not hpa or not pdb or extra:
    print("MISSING\t%s\t%s\t%s" % (bool(hpa), bool(pdb), ",".join(extra))); sys.exit(0)
s = hpa["spec"]; t = s["scaleTargetRef"]
sel = pdb["spec"].get("selector", {}).get("matchLabels", {})
print("\t".join(str(x) for x in (
    hpa["metadata"].get("namespace"), pdb["metadata"].get("namespace"),
    t["kind"] + "/" + t["name"], s["minReplicas"], s["maxReplicas"],
    pdb["spec"].get("maxUnavailable"), ",".join("%s=%s" % kv for kv in sorted(sel.items())))))
PY
}

# ---- (a) the stock render writes no CoreDNS-HA object ----
render "$tmp/stock.yaml" || true
if [ ! -s "$tmp/stock.yaml" ]; then
  bad "stock render" "the chart did not render: $(head -c 200 "$tmp/stock.yaml.err")"
  echo "check-coredns-ha: FAIL" >&2; exit 1
fi
objects "$tmp/stock.yaml" > "$tmp/stock.ks"
docs=$(sed -n 's/^DOCS //p' "$tmp/stock.ks")
nks=$(grep -c '^Role/kube-system/' "$tmp/stock.ks")
if [ "${docs:-0}" -gt 100 ] && [ "$nks" -gt 0 ]; then
  ok "stock render parsed ($docs objects, the $nks cert-manager Roles in kube-system among them)"
else
  bad "stock render reaches the corpus" "objects=$docs roles-in-kube-system=$nks: a scan that sees nothing proves nothing"
fi
if grep -Eq '^(HorizontalPodAutoscaler|PodDisruptionBudget)/kube-system/' "$tmp/stock.ks" || [ "$(pair "$tmp/stock.yaml" | cut -f1)" != MISSING ] \
   || grep -q 'name: tockmox-coredns-ha' "$tmp/stock.yaml"; then
  bad "stock render has no CoreDNS-HA object" "$(grep -E '^(HorizontalPodAutoscaler|PodDisruptionBudget)/kube-system/' "$tmp/stock.ks" | tr '\n' ' ')"
else
  ok "stock render: no HPA and no PDB in kube-system, no tockmox-coredns-ha anywhere"
fi

# ---- (b) switched on: exactly the HPA and the PDB, in kube-system, with the floor ----
for floor in default 3; do
  if [ "$floor" = default ]; then
    render "$tmp/on.yaml" --set apps.corednsHa.enabled=true; want_min=2
  else
    render "$tmp/on.yaml" --set apps.corednsHa.enabled=true --set corednsHa.minReplicas=3 --set corednsHa.maxReplicas=5; want_min=3
  fi
  if [ ! -s "$tmp/on.yaml" ]; then bad "switch on ($floor floor) renders" "$(head -c 200 "$tmp/on.yaml.err")"; continue; fi
  objects "$tmp/on.yaml" > "$tmp/on.ks"
  added=$(diff <(grep -v '^DOCS' "$tmp/stock.ks") <(grep -v '^DOCS' "$tmp/on.ks") | grep '^[<>]' | sort | tr '\n' ' ')
  if [ "$added" = "> HorizontalPodAutoscaler/kube-system/tockmox-coredns-ha > PodDisruptionBudget/kube-system/tockmox-coredns-ha " ]; then
    ok "switch on ($floor floor): the render gains exactly the HPA and the PDB, both in kube-system, and loses nothing"
  else
    bad "switch on ($floor floor): the render gains exactly the HPA and the PDB" "difference: ${added:-none}"
  fi
  IFS=$'\t' read -r hns pns tgt mn mx mu sel < <(pair "$tmp/on.yaml")
  if [ "$hns" = kube-system ] && [ "$pns" = kube-system ] && [ "$tgt" = Deployment/coredns ] && [ "$mn" = "$want_min" ] \
     && [ "$mu" = 1 ] && [ "$sel" = "k8s-app=kube-dns" ]; then
    ok "switch on ($floor floor): HPA scales Deployment/coredns with minReplicas $mn (max $mx), PDB maxUnavailable $mu selects $sel"
  else
    bad "switch on ($floor floor): the pair is right" "hpa-ns=$hns pdb-ns=$pns target=$tgt min=$mn(want $want_min) max=$mx maxUnavailable=$mu selector=$sel"
  fi
done

# ---- (c) a floor under 2 is refused, by name ----
for floor in 1 0; do
  render "$tmp/f.yaml" --set apps.corednsHa.enabled=true --set corednsHa.minReplicas=$floor
  if [ ! -s "$tmp/f.yaml" ] && grep -q "needs a floor of at least 2" "$tmp/f.yaml.err" && grep -q "corednsHa.minReplicas is $floor" "$tmp/f.yaml.err"; then
    ok "floor $floor is refused, and the error names the reason"
  else
    bad "floor $floor is refused by name" "rendered=$([ -s "$tmp/f.yaml" ] && echo yes || echo no) stderr: $(head -c 240 "$tmp/f.yaml.err")"
  fi
done
render "$tmp/off1.yaml" --set corednsHa.minReplicas=1
if [ -s "$tmp/off1.yaml" ] && cmp -s "$tmp/off1.yaml" "$tmp/stock.yaml"; then
  ok "floor 1 with the switch off renders exactly the stock render"
else
  bad "floor 1 with the switch off renders exactly the stock render" "$(head -c 200 "$tmp/off1.yaml.err")"
fi

# ---- (d) the other values that render clean and do nothing are refused too ----
refused() { # label, expected-fragment, helm args...
  local label="$1" frag="$2"; shift 2
  render "$tmp/r.yaml" --set apps.corednsHa.enabled=true "$@"
  if [ ! -s "$tmp/r.yaml" ] && grep -q "$frag" "$tmp/r.yaml.err"; then ok "$label is refused, and the error says why"
  else bad "$label is refused by name" "rendered=$([ -s "$tmp/r.yaml" ] && echo yes || echo no) stderr: $(head -c 240 "$tmp/r.yaml.err")"; fi
}
refused "a ceiling below the floor" "is below corednsHa.minReplicas" --set corednsHa.maxReplicas=1
refused "an empty Deployment name"  "corednsHa.deployment is empty"  --set corednsHa.deployment=
refused "an empty pod selector"     "corednsHa.podLabels is empty"   --set corednsHa.podLabels=null

# ---- (e) the keys are one values namespace: every other layer accepts them ----
# A profile is one file passed to all nine layers, and each layer's schema closes
# its root. A layer whose schema lacks `corednsHa` would reject a site's values
# file on that layer, and nothing else in the tree would notice.
layers=0
for c in "$(dirname "$chart")"/tockmox-*; do
  n="$(basename "$c")"
  case "$n" in tockmox-common|tockmox-platform) continue ;; esac
  layers=$((layers + 1))
  if helm template t "$c" -f ci/values.yaml --set apps.corednsHa.enabled=true --set corednsHa.minReplicas=3 >/dev/null 2>"$tmp/l.err"; then
    :
  else
    bad "$n accepts the corednsHa keys" "$(head -c 240 "$tmp/l.err")"
  fi
done
if [ "$layers" -ge 8 ]; then ok "the other $layers layers accept apps.corednsHa and the corednsHa block, and ignore them"
else bad "the other layers were reached" "only $layers layers found beside the platform chart"; fi

[ "$fail" -eq 0 ] || { echo "check-coredns-ha: FAIL" >&2; exit 1; }
echo "check-coredns-ha: ok"

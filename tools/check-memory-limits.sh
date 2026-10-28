#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that every container Tockmox ships under
# the all-on overlay carries a memory limit, or is on the residue list with the
# reason it does not (TM-0595).
#
#   ./tools/check-memory-limits.sh              the gate
#   ./tools/check-memory-limits.sh --selftest   prove it goes red, and green
#
# WHY. On 2026-09-13 a Grafana memory limit that was too low presented as a
# 502 from the gateway (TM-0553), and the same investigation counted 15 of 64
# running containers with any memory limit at all. A container with no limit
# is not safe either: one leak takes the node's memory, and every pod on that
# node pays for it. So the default is a limit sized from a measurement, and the
# exceptions are written down.
#
# WHAT IT ASSERTS. Every container and initContainer in every pod template
# (Deployment, StatefulSet, DaemonSet, Job, CronJob, Pod) that the layer charts
# render with ci/values.yaml + ci/values-all-on.yaml either
#   1. sets resources.limits.memory, or
#   2. is listed in tools/memory-limits-residue.txt with a `# no-limit:` reason.
# And, so the list cannot rot, every residue entry must still render AND still
# have no limit.
#
# THE PODS AN OPERATOR CREATES ARE NOT IN THE RENDER. The CNPG Cluster's
# postgres pod, and the Prometheus and Alertmanager StatefulSets, appear in no
# `helm template` output; only their custom resources do. So for those three
# kinds the gate asserts the custom resource instead: spec.resources.limits.memory
# must be set. That is the closest thing to the pod this gate can see, and it
# is not the pod: the operator decides what it renders from it. The residue is a RATCHET, the trivy floor pattern turned
# around: it only shrinks, and it is never asserted to be zero. Vendored
# subchart containers ARE counted here, unlike check-sa-tokens.sh, because an
# unlimited subchart container exhausts a node exactly as well as ours.
#
# WHAT IT DOES NOT PROVE. That a limit is RIGHT. A limit is a claim about a
# peak, and only a live install under load can test that claim (TM-0553's
# Grafana rule: below 80% of the limit after a session, zero restarts). It does
# not see pods an operator creates with no custom resource in the render
# (Longhorn's instance-managers, the restore drill's throwaway Cluster).
#
# Exit 2 (skipped) when helm or PyYAML is absent.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-memory-limits: helm missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-memory-limits: python3 PyYAML missing" >&2; exit 2; }
RESIDUE="${MEMORY_LIMITS_RESIDUE:-tools/memory-limits-residue.txt}"
[ -f "$RESIDUE" ] || { echo "check-memory-limits: $RESIDUE missing" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

render() {  # render <dir>
  local d="$1" c l; mkdir -p "$d"
  for c in charts/tockmox-*; do
    l=${c#charts/tockmox-}; [ "$l" = common ] && continue; [ "$l" = crds ] && continue
    [ -f "$c/Chart.yaml" ] || continue
    helm template t "$c" -f ci/values.yaml -f ci/values-all-on.yaml > "$d/$l.yaml" 2>"$tmp/err" \
      || { echo "check-memory-limits: $l (all-on) did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
  done
}

cat > "$tmp/scan.py" <<'PY'
import sys, glob, re, yaml
d, residue_file = sys.argv[1], sys.argv[2]
FLOOR = 50   # fewer containers than this means the scan is not looking at the render
res, errs = {}, []
for n, ln in enumerate(open(residue_file), 1):
    s = ln.strip()
    if not s or s.startswith('#'): continue
    body, _, why = s.partition('# no-limit:')
    f = body.split()
    if len(f) != 4: errs.append('%s:%d: want <layer> <Kind> <name> <container>, got %r' % (residue_file, n, body.strip())); continue
    if not why.strip(): errs.append('%s:%d: %s has no `# no-limit:` reason' % (residue_file, n, ' '.join(f)))
    if tuple(f) in res: errs.append('%s:%d: %s is listed twice' % (residue_file, n, ' '.join(f)))
    res[tuple(f)] = why.strip()
CRS = {('postgresql.cnpg.io', 'Cluster'), ('monitoring.coreos.com', 'Prometheus'), ('monitoring.coreos.com', 'Alertmanager')}
crs = 0
def pod(o):
    k, sp = o.get('kind'), o.get('spec') or {}
    if k == 'Pod': return sp
    if k == 'CronJob': return sp['jobTemplate']['spec']['template'].get('spec') or {}
    if k in ('Deployment', 'StatefulSet', 'DaemonSet', 'Job'): return sp['template'].get('spec') or {}
    return None
total, unlimited = 0, set()
for f in sorted(glob.glob(d + '/*.yaml')):
    layer = f.split('/')[-1][:-5]
    for o in yaml.safe_load_all(open(f)):
        if not o: continue
        if ((o.get('apiVersion') or '').split('/')[0], o.get('kind')) in CRS:
            crs += 1
            if not (((o.get('spec') or {}).get('resources') or {}).get('limits') or {}).get('memory'):
                errs.append('%s %s %s sets no spec.resources.limits.memory, so the pods its operator creates have none' % (layer, o['kind'], o['metadata']['name']))
            continue
        spec = pod(o)
        if spec is None: continue
        for c in (spec.get('initContainers') or []) + (spec.get('containers') or []):
            total += 1
            if not ((c.get('resources') or {}).get('limits') or {}).get('memory'):
                unlimited.add((layer, o['kind'], o['metadata']['name'], c['name']))
for k in sorted(unlimited - set(res)):
    errs.append('%s %s %s container %s has no memory limit and is not in the residue: set one from a measurement, or list it with a `# no-limit:` reason' % k)
for k in sorted(set(res) - unlimited):
    errs.append('residue entry "%s" carries a limit now or no longer renders: remove it (the residue only shrinks)' % ' '.join(k))
print('  %d containers rendered under the all-on overlay, %d with a memory limit, %d without' % (total, total - len(unlimited), len(unlimited)))
print('  residue: %d entries in %s' % (len(res), residue_file))
print('  %d operator custom resources (CNPG Cluster, Prometheus, Alertmanager) checked for spec.resources.limits.memory' % crs)
if crs < 3: errs.append('only %d operator custom resources found: expected the LiteLLM Cluster, Prometheus and Alertmanager' % crs)
if total < FLOOR: errs.append('only %d containers found: the scan is not looking at the render' % total)
for e in errs: print('::error::' + e)
sys.exit(1 if errs else 0)
PY

if [ "${1:-}" != "--selftest" ]; then
  render "$tmp/r"
  python3 "$tmp/scan.py" "$tmp/r" "$RESIDUE" && echo "check-memory-limits: ok"
  exit $?
fi

# --- selftest: each mutation must turn the scan red for its own reason; the untouched copy green ---
render "$tmp/r"; fail=0
python3 "$tmp/scan.py" "$tmp/r" "$RESIDUE" >/dev/null && echo "selftest ok    the unmutated render is GREEN" \
  || { echo "selftest FAIL  the unmutated render is not green"; fail=1; }
mutate() {  # mutate <label> <render file|residue|all> <python expr over text s> <expected message>
  rm -rf "$tmp/m"; cp -R "$tmp/r" "$tmp/m"; cp "$RESIDUE" "$tmp/res.txt"
  local target="$tmp/m/$2"; [ "$2" = residue ] && target="$tmp/res.txt"
  [ "$2" = all ] && target="$tmp/m"
  python3 - "$target" "$3" <<'PY'
import sys, re, os, glob
p, expr = sys.argv[1], sys.argv[2]
for f in (sorted(glob.glob(os.path.join(p, '*.yaml'))) if os.path.isdir(p) else [p]):
    s = open(f).read(); n = eval(expr)
    assert n != s, 'mutation did not change the input'
    open(f, 'w').write(n)
PY
  local out; out=$(python3 "$tmp/scan.py" "$tmp/m" "$tmp/res.txt" 2>&1) && { echo "selftest FAIL  $1: scan stayed GREEN"; fail=1; return; }
  if grep -q "$4" <<<"$out"; then echo "selftest ok    $1: RED on '$4'"; else echo "selftest FAIL  $1: red, but not for the expected reason"; echo "$out" | grep error | head -3 || true; fail=1; fi
}
# A limited container loses its limit (the TM-0553 container itself).
mutate "grafana loses its memory limit" observability.yaml "re.sub(r'(\n +- name: grafana\n(?: {10,}.*\n)*? +limits:\n +memory: )1536Mi', r'\1null', s, 1)" "t-grafana container grafana has no memory limit"
# A new subchart container arrives with no limit.
mutate "a new unlimited container appears" ai.yaml "s + '---\napiVersion: apps/v1\nkind: Deployment\nmetadata: {name: t-new}\nspec:\n  template:\n    spec:\n      containers: [{name: c, image: x}]\n'" "t-new container c has no memory limit"
# A residue container gains a limit, and the entry stays: the ratchet must ask for its removal.
mutate "a residue container gains a limit" platform.yaml "s.replace('      - name: longhorn-ui\n', '      - name: longhorn-ui\n        resources: {limits: {memory: 64Mi}}\n', 1)" "carries a limit now"
# An entry whose object no longer renders.
mutate "a residue entry names nothing" residue "s + 'platform Deployment t-gone gone  # no-limit: test\n'" "no longer renders"
# An entry with no reason.
mutate "a residue entry loses its reason" residue "re.sub(r'(longhorn-ui\s+)# no-limit:[^\n]*', r'\1', s, 1)" "no-limit:\` reason"
# The LiteLLM database's Cluster loses its limit: the pod is not in the render, the CR is.
mutate "the CNPG Cluster loses its memory limit" ai.yaml "re.sub(r'(kind: Cluster\n(?:.*\n)*?  resources:\n    limits:\n      memory: )320Mi', r'\1null', s, 1)" "Cluster tockmox-litellm-db sets no spec.resources"
# The scan sees nothing (an empty render must not pass as coverage). Every layer is emptied: emptying one left
# the other layers above FLOOR once they rendered 50 containers between them, and the case went red for the
# wrong reason (the residue entries of the emptied layer) instead of the floor it exists to prove.
mutate "the render is empty" all "''" "the scan is not looking at the render"
[ "$fail" -eq 0 ] && echo "selftest ok    every mutation turned the gate red" || exit 1

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that every CronJob Tockmox ships says what
# happens to a slot it missed while the cluster was down.
#
#   ./tools/check-cronjob-catchup.sh              the gate
#   ./tools/check-cronjob-catchup.sh --selftest   prove it goes red, and green
#
# WHY. With no startingDeadlineSeconds, the CronJob controller runs a missed
# slot as soon as it syncs. After a restore from a snapshot (the clock jumps
# past a slot) or a power cycle across one, that is at boot, before the
# services the Job needs answer. Measured on a reference install: the
# console-key check, the restore drills and the Authentik dump each fired into
# a cold cluster, failed, and held their Argo CD Application Degraded until the
# next slot succeeded, up to a week for a weekly drill. 0.8.5 set a deadline on
# those; four more CronJobs had none. A deadline is a decision about each job,
# so this gate does not pick one: it refuses a CronJob that has not made it.
#
# WHAT IT ASSERTS. Every CronJob labelled tockmox.com/managed-by=tockmox in
#   1. each layer rendered with ci/values.yaml + ci/values-all-on.yaml, and
#   2. the AI layer rendered with its model jobs on (ci/values-inference-nodes.yaml,
#      the health watch and the eval scheduler: they are off in the overlay),
# sets spec.startingDeadlineSeconds to an integer of at least 10 (the
# controller checks about every 10 s, so a smaller deadline can skip every
# slot). And the scan must see the CronJobs named in REQUIRED below, so a
# render that quietly lost them cannot read green.
#
# WHAT IT DOES NOT PROVE. That a deadline is RIGHT for its job, or that a
# restore skips the slot: only a cold restore on a real cluster shows that.
# Vendored subchart CronJobs are counted and named, not asserted: their fields
# are upstream's. The CronJob the installer writes for the built-in forge is not
# a chart render and is not seen here.
#
# Exit 2 (skipped) when helm or PyYAML is absent.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-cronjob-catchup: helm missing" >&2; echo "SKIPPED: helm is not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-cronjob-catchup: python3 PyYAML missing" >&2; echo "SKIPPED: python3 has no PyYAML" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

render() {  # render <dir>
  local d="$1" c l; mkdir -p "$d"
  for c in charts/tockmox-*; do
    l=${c#charts/tockmox-}; [ "$l" = common ] && continue; [ "$l" = crds ] && continue
    [ -f "$c/Chart.yaml" ] || continue
    helm template t "$c" -f ci/values.yaml -f ci/values-all-on.yaml > "$d/$l.yaml" 2>"$tmp/err" \
      || { echo "check-cronjob-catchup: $l (all-on) did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
  done
  helm template t charts/tockmox-ai -f ci/values.yaml -f ci/values-inference-nodes.yaml \
    --set modelLifecycle.runner.enabled=true --set modelLifecycle.healthWatch.enabled=true \
    > "$d/ai-model-jobs.yaml" 2>"$tmp/err" \
    || { echo "check-cronjob-catchup: ai with the model jobs on did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
}

cat > "$tmp/scan.py" <<'PY'
import sys, glob, yaml
d = sys.argv[1]
REQUIRED = {'tockmox-console-key-check', 'tockmox-heartbeat', 'tockmox-health-watch', 'tockmox-model-watch'}
MIN = 10
errs, owned, vendored = [], {}, set()
for f in sorted(glob.glob(d + '/*.yaml')):
    render = f.split('/')[-1][:-5]
    for o in yaml.safe_load_all(open(f)):
        if not o or o.get('kind') != 'CronJob':
            continue
        md = o.get('metadata') or {}
        name = md.get('name')
        if (md.get('labels') or {}).get('tockmox.com/managed-by') != 'tockmox':
            vendored.add('%s/%s' % (render, name))
            continue
        owned.setdefault(name, []).append(render)
        v = (o.get('spec') or {}).get('startingDeadlineSeconds')
        if v is None:
            errs.append('%s: CronJob %s sets no startingDeadlineSeconds, so after a restore or a power cycle it runs its missed slot at boot: set one, with the reason beside it' % (render, name))
        elif isinstance(v, bool) or not isinstance(v, int):
            errs.append('%s: CronJob %s startingDeadlineSeconds is %r, not an integer' % (render, name, v))
        elif v < MIN:
            errs.append('%s: CronJob %s startingDeadlineSeconds is %d, under %d s: the controller can miss every slot' % (render, name, v, MIN))
for n in sorted(REQUIRED - set(owned)):
    errs.append('CronJob %s is not in the render: the scan is not looking at what ships, or it was renamed (update REQUIRED)' % n)
print('  %d Tockmox CronJobs checked: %s' % (len(owned), ', '.join(sorted(owned))))
print('  %d vendored CronJobs not asserted%s' % (len(vendored), (': ' + ', '.join(sorted(vendored))) if vendored else ''))
for e in errs:
    print('::error::' + e)
sys.exit(1 if errs else 0)
PY

if [ "${1:-}" != "--selftest" ]; then
  render "$tmp/r"
  python3 "$tmp/scan.py" "$tmp/r" && echo "check-cronjob-catchup: ok"
  exit $?
fi

# --- selftest: each mutation must turn the scan red for its own reason; the untouched copy green ---
cat > "$tmp/mutate.py" <<'PY'
import sys, glob, os, yaml
src, dst, what = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(dst, exist_ok=True)
for f in sorted(glob.glob(src + '/*.yaml')):
    docs = [o for o in yaml.safe_load_all(open(f)) if o]
    out = []
    for o in docs:
        name = (o.get('metadata') or {}).get('name')
        if o.get('kind') == 'CronJob':
            sp = o.setdefault('spec', {})
            if what == 'drop' and name == 'tockmox-heartbeat':
                sp.pop('startingDeadlineSeconds', None)
            if what == 'drop-model' and name == 'tockmox-model-watch':
                sp.pop('startingDeadlineSeconds', None)
            if what == 'tiny' and name == 'tockmox-console-key-check':
                sp['startingDeadlineSeconds'] = 5
            if what == 'string' and name == 'tockmox-health-watch':
                sp['startingDeadlineSeconds'] = '120'
            if what == 'remove' and name == 'tockmox-heartbeat':
                continue
        out.append(o)
    if what == 'new' and f.endswith('/selfcheck.yaml'):
        out.append({'apiVersion': 'batch/v1', 'kind': 'CronJob',
                    'metadata': {'name': 'tockmox-planted', 'labels': {'tockmox.com/managed-by': 'tockmox'}},
                    'spec': {'schedule': '*/15 * * * *', 'jobTemplate': {'spec': {}}}})
    with open(os.path.join(dst, os.path.basename(f)), 'w') as fh:
        yaml.safe_dump_all(out, fh)
PY

render "$tmp/r"; fail=0
if python3 "$tmp/scan.py" "$tmp/r" >/dev/null; then echo "selftest ok    the unmutated render is GREEN"
else echo "selftest FAIL  the unmutated render is red" >&2; python3 "$tmp/scan.py" "$tmp/r" >&2 || true; fail=1; fi
check() {  # check <mutation> <text the error must carry> <description>
  local m="$1" want="$2" desc="$3" out
  python3 "$tmp/mutate.py" "$tmp/r" "$tmp/m-$m" "$m"
  if out=$(python3 "$tmp/scan.py" "$tmp/m-$m" 2>&1); then
    echo "selftest FAIL  $desc: the gate stayed GREEN" >&2; fail=1
  elif grep -F -- "$want" >/dev/null <<<"$out"; then
    echo "selftest ok    $desc: RED"
  else
    echo "selftest FAIL  $desc: red, but not for this reason (wanted: $want)" >&2; printf '%s\n' "$out" >&2; fail=1
  fi
}
check drop       'CronJob tockmox-heartbeat sets no startingDeadlineSeconds' "the heartbeat loses its deadline"
check drop-model 'CronJob tockmox-model-watch sets no startingDeadlineSeconds' "the model watcher (model-jobs render) loses its deadline"
check tiny       'tockmox-console-key-check startingDeadlineSeconds is 5'      "a deadline under 10 s"
check string     'tockmox-health-watch startingDeadlineSeconds is '"'"'120'"'"', not an integer' "a deadline that is a string"
check new        'CronJob tockmox-planted sets no startingDeadlineSeconds'     "a new CronJob with no deadline"
check remove     'CronJob tockmox-heartbeat is not in the render'               "a required CronJob vanishes from the render"
[ "$fail" -eq 0 ] && echo "check-cronjob-catchup --selftest: ok"
exit "$fail"

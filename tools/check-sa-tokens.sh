#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that no pod Tockmox owns runs as a
# namespace's `default` ServiceAccount or mounts an API token it does not need
# (TM-0759: kube-bench CIS 5.1.5 and 5.1.6 failed on the lab host).
#
#   ./tools/check-sa-tokens.sh              the gate
#   ./tools/check-sa-tokens.sh --selftest   prove it goes red, and green
#
# WHAT IT ASSERTS, for every pod template a Tockmox template renders (a
# Deployment, StatefulSet, DaemonSet, Job, CronJob or Pod carrying the label
# tockmox.com/managed-by=tockmox, on the object or on its pod template):
#   1. spec.serviceAccountName is set and is not `default`;
#   2. that ServiceAccount is rendered in the same layer (no dangling name);
#   3. spec.automountServiceAccountToken is set EXPLICITLY (never left to the
#      account's default), except the IMPLICIT list below;
#   4. a `true` is only allowed when it is on the ALLOW list below, each entry
#      with the reason the pod calls the Kubernetes API. An ALLOW entry that no
#      render contains, or whose pod is no longer `true`, fails too, so the
#      list cannot rot.
#   5. every Namespace a Tockmox chart creates also renders a ServiceAccount
#      `default` in it with automountServiceAccountToken: false (CIS 5.1.5), and
#      no RoleBinding or ClusterRoleBinding in a Tockmox render names a
#      ServiceAccount called `default` (so losing its token costs nothing).
# Rendered three ways: the CI defaults, the all-on overlay, and the operator
# site fixture that gives the platform layer a garage-web sync CronJob (the one
# pod the other two never render). Pods from vendored subcharts are NOT asserted
# (their charts own them); the run prints how many it left alone, and the
# waivers are in the TM-0759 report and the values comments.
#
# WHAT IT DOES NOT PROVE. That a pod really needs no API access (read the
# container's script), or what a live cluster's default ServiceAccounts hold:
# kube-bench 5.1.5 also looks at each namespace's `default` account itself.
# Exit 2 (skipped) when helm or PyYAML is absent.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-sa-tokens: helm missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-sa-tokens: python3 PyYAML missing" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ALLOW LIST: <Kind> <name glob> # why this pod keeps a token. One per line.
cat > "$tmp/allow.txt" <<'ALLOW'
CronJob tockmox-litellm-db-drill   # restore drill: kubectl creates and deletes the drill Cluster, reads and patches the register ConfigMap (Role in restore-drill.yaml)
CronJob tockmox-authentik-db-drill # identity restore drill (TM-0788): the same script and Role as the model gateway's, in the identity namespace (charts/tockmox-identity/templates/restore-drill.yaml)
Job     tockmox-authentik-db-upgrade-guard # identity upgrade guard (TM-0788): lists PersistentVolumeClaims in its namespace before a sync and nothing else (list-only Role in authentik-db-upgrade-guard.yaml)
Job     tockmox-garage-bootstrap   # bootstrap Job: kubectl reads and creates Secrets, patches the Longhorn BackupTarget, starts sync Jobs from CronJobs
Deployment tockmox-ui              # the Tockmox UI: get/list nodes, and Argo CD applications in their namespace (ClusterRole tockmox-ui-read, Role tockmox-ui-read-applications in tockmox-ui.yaml); first rendered here when the all-on overlay turned it on (TM-1013)
Job     tockmox-pre-upgrade-backup # pre-upgrade backup hook (TM-1054): kubectl reads the Deployment or StatefulSet image, creates a CNPG Backup and reads its phase (Role in upgrade-backup.yaml)
Job     t-gateway-key-*            # console-key Job (TM-0460): kubectl gets, creates or replaces the console's virtual-key Secret and restarts the console's pods on a replaced key (Role in gateway-key.yaml); named after its pod template like the migrations Job
ALLOW

# IMPLICIT: pods that need the token but may leave the field unset, because writing
# it would change the pod template of a Job that cannot be recreated (immutable).
# VENDORED pods Tockmox pins to an account of its own with no token, through the
# subchart's values. Not Tockmox-labelled, so the owned-pod scan above does not
# see them; listed here so a values edit cannot quietly put them back on the
# namespace's `default` account (where "no token" would again depend on sync order).
cat > "$tmp/pinned.txt" <<'PIN'
Deployment t-authentik-server   # serves HTTP, never calls the API (the worker holds the outpost RBAC); on the rc2 greenfield it was created one second before the policy layer turned default's token off, and kept one
PIN

cat > "$tmp/implicit.txt" <<'IMPL'
Job tockmox-garage-credentials-* # named after its own pod template (TM-1022). Needs the API (kubectl creates Secrets), so it keeps the default mount.
IMPL

render() {  # render <dir>
  local d="$1" c l; mkdir -p "$d"
  for c in charts/tockmox-*; do
    l=${c#charts/tockmox-}; [ "$l" = common ] && continue; [ "$l" = crds ] && continue
    helm template t "$c" -f ci/values.yaml > "$d/$l.yaml" 2>"$tmp/err" \
      || { echo "check-sa-tokens: $l did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
    helm template t "$c" -f ci/values.yaml -f ci/values-all-on.yaml > "$d/$l.allon.yaml" 2>"$tmp/err" \
      || { echo "check-sa-tokens: $l (all-on) did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
  done
  # The platform layer with a sync CronJob (same fixture as check-upgrade-safety.sh F3).
  cat > "$tmp/site.yaml" <<'YAML'
garage:
  credentialsNamespaces: [tockmox-ai, tockmox-authentik, news]
  createCredentialsNamespaces: [news]
  web:
    sites:
      - name: docs
        host: ""
        index: index.html
        errorDocument: 404.html
        ingress: true
        writerKey: true
        content: {}
      - name: handbook
        host: handbook.int.example.com
        ingress: true
        content: {image: registry.example.com/team/handbook:1.4.0, path: /site}
YAML
  helm template t charts/tockmox-platform -f ci/values.yaml -f "$tmp/site.yaml" > "$d/platform.site.yaml" 2>"$tmp/err" \
    || { echo "check-sa-tokens: platform site fixture did not render" >&2; sed 's/^/  /' "$tmp/err" >&2; exit 1; }
}

cat > "$tmp/scan.py" <<'PY'
import sys, glob, fnmatch, yaml
d, allow_file, impl_file, pin_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def lst(f):
    r = []
    for ln in open(f):
        ln = ln.split('#', 1)[0].split()
        if len(ln) == 2: r.append((ln[0], ln[1]))
    return r
allow, impl, pins = lst(allow_file), lst(impl_file), lst(pin_file)
used_impl, used_pin = set(), set()
OWN = 'tockmox.com/managed-by'
def pod_of(o):
    k = o.get('kind'); sp = o.get('spec') or {}
    if k == 'Pod': return o, o.get('spec')
    if k == 'CronJob': t = sp['jobTemplate']['spec']['template']
    elif k in ('Deployment', 'StatefulSet', 'DaemonSet', 'Job'): t = sp['template']
    else: return None, None
    return t, t.get('spec')
errs, owned, left, used, nsd = [], 0, 0, set(), 0
for f in sorted(glob.glob(d + '/*.yaml')):
    docs = [x for x in yaml.safe_load_all(open(f)) if x]
    sas = {(x['metadata'].get('namespace') or '', x['metadata']['name']) for x in docs if x.get('kind') == 'ServiceAccount'}
    sanames = {n for _, n in sas}
    defaults = {x['metadata'].get('namespace'): x for x in docs if x.get('kind') == 'ServiceAccount' and x['metadata']['name'] == 'default'}
    for o in docs:
        if o.get('kind') == 'Namespace' and (o['metadata'].get('labels') or {}).get(OWN) == 'tockmox':
            nsn = o['metadata']['name']; nsd += 1
            dsa = defaults.get(nsn)
            if dsa is None: errs.append('Namespace %s (%s) has no ServiceAccount default rendered with it' % (nsn, f.split('/')[-1]))
            elif dsa.get('automountServiceAccountToken') is not False: errs.append('ServiceAccount default in %s does not set automountServiceAccountToken: false' % nsn)
        if o.get('kind') in ('RoleBinding', 'ClusterRoleBinding'):
            for sj in o.get('subjects') or []:
                if sj.get('kind') == 'ServiceAccount' and sj.get('name') == 'default':
                    errs.append('%s %s binds the ServiceAccount default: its token would be needed (%s)' % (o['kind'], o['metadata']['name'], f.split('/')[-1]))
        t, spec = pod_of(o)
        if spec is None: continue
        labels = dict((o['metadata'].get('labels') or {})); labels.update((t.get('metadata') or {}).get('labels') or {})
        if labels.get(OWN) != 'tockmox':
            left += 1
            k = o['kind']; n = o['metadata']['name']
            for a in [a for a in pins if a[0] == k and fnmatch.fnmatch(n, a[1])]:
                used_pin.add(a); where = '%s %s (%s, pinned vendored)' % (k, n, f.split('/')[-1])
                sa = spec.get('serviceAccountName')
                if not sa or sa == 'default': errs.append('%s runs as the namespace default ServiceAccount (serviceAccountName=%r)' % (where, sa))
                elif sa not in sanames: errs.append('%s names ServiceAccount %s, which this layer does not render' % (where, sa))
                elif not any(x.get('kind') == 'ServiceAccount' and x['metadata']['name'] == sa and x.get('automountServiceAccountToken') is False for x in docs):
                    errs.append('%s: ServiceAccount %s does not set automountServiceAccountToken: false' % (where, sa))
                elif not any(x.get('kind') == 'ServiceAccount' and x['metadata']['name'] == sa and 'Prune=false' in ((x['metadata'].get('annotations') or {}).get('argocd.argoproj.io/sync-options') or '') for x in docs):
                    errs.append('%s: ServiceAccount %s can be pruned, and a rollback would leave the Deployment naming it' % (where, sa))
                if spec.get('automountServiceAccountToken') is not False: errs.append('%s does not set automountServiceAccountToken: false on the pod' % where)
            continue
        owned += 1; k = o['kind']; n = o['metadata']['name']; where = '%s %s (%s)' % (k, n, f.split('/')[-1])
        sa = spec.get('serviceAccountName')
        if not sa or sa == 'default': errs.append('%s runs as the namespace default ServiceAccount (serviceAccountName=%r)' % (where, sa))
        elif sa not in sanames: errs.append('%s names ServiceAccount %s, which this layer does not render' % (where, sa))
        am = spec.get('automountServiceAccountToken')
        ih = [a for a in impl if a[0] == k and fnmatch.fnmatch(n, a[1])]
        for a in ih: used_impl.add(a)
        if am is None and ih: continue
        if ih: errs.append('%s is on the IMPLICIT list but sets the field: remove the entry' % where)
        if not isinstance(am, bool): errs.append('%s does not set automountServiceAccountToken explicitly' % where); continue
        hit = [a for a in allow if a[0] == k and fnmatch.fnmatch(n, a[1])]
        for a in hit: used.add(a)
        if am and not hit: errs.append('%s mounts a token and is not on the ALLOW list' % where)
        if hit and not am: errs.append('%s is on the ALLOW list but no longer mounts a token: remove the entry' % where)
for a in impl:
    if a not in used_impl: errs.append('IMPLICIT entry "%s %s" matches no rendered pod: remove it' % a)
for a in allow:
    if a not in used: errs.append('ALLOW entry "%s %s" matches no rendered pod: remove it' % a)
for a in pins:
    if a not in used_pin: errs.append('PINNED entry "%s %s" matches no rendered pod: remove it' % a)
print('  %d chart-created namespaces carry a default ServiceAccount with no token;' % nsd)
print('  %d Tockmox-owned pod templates checked, %d vendored-subchart pod templates left to their charts' % (owned, left))
if nsd < 8: errs.append('only %d chart-created namespaces found' % nsd)
if owned < 12: errs.append('only %d owned pod templates found: the scan is not looking at the render' % owned)
for e in errs: print('::error::' + e)
sys.exit(1 if errs else 0)
PY

if [ "${1:-}" != "--selftest" ]; then
  render "$tmp/r"
  python3 "$tmp/scan.py" "$tmp/r" "$tmp/allow.txt" "$tmp/implicit.txt" "$tmp/pinned.txt" && echo "check-sa-tokens: ok"
  exit $?
fi

# --- selftest: each mutation of the render must turn the scan red; the untouched copy green ---
render "$tmp/r"; fail=0
python3 "$tmp/scan.py" "$tmp/r" "$tmp/allow.txt" "$tmp/implicit.txt" "$tmp/pinned.txt" >/dev/null && echo "selftest ok    the unmutated render is GREEN" \
  || { echo "selftest FAIL  the unmutated render is not green"; fail=1; }
mutate() {  # mutate <label> <file> <python expr over text s> <expected message>
  rm -rf "$tmp/m"; cp -R "$tmp/r" "$tmp/m"
  python3 - "$tmp/m/$2" "$3" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
import re
s = open(p).read(); n = eval(expr)
assert n != s, 'mutation did not change the render'
open(p, 'w').write(n)
PY
  local out; out=$(python3 "$tmp/scan.py" "$tmp/m" "$tmp/allow.txt" "$tmp/implicit.txt" "$tmp/pinned.txt" 2>&1) && { echo "selftest FAIL  $1: scan stayed GREEN"; fail=1; return; }
  if grep -q "$4" <<<"$out"; then echo "selftest ok    $1: RED on '$4'"; else echo "selftest FAIL  $1: red, but not for the expected reason"; echo "$out" | grep error | head -3 || true; fail=1; fi
}
mutate "brand back on the default account" identity.yaml "s.replace('serviceAccountName: tockmox-brand','serviceAccountName: default')" "namespace default ServiceAccount"
mutate "ntfy loses its ServiceAccount name" observability.allon.yaml "re.sub(' *serviceAccountName: tockmox-ntfy\n','',s,1)" "namespace default ServiceAccount"
mutate "heartbeat names a ServiceAccount nobody renders" selfcheck.allon.yaml "s.replace('serviceAccountName: tockmox-heartbeat','serviceAccountName: tockmox-heartbeat-x')" "does not render"
mutate "alert-bridge leaves the token to the default" observability.allon.yaml "s.replace('serviceAccountName: tockmox-alert-bridge\n      automountServiceAccountToken: false\n','serviceAccountName: tockmox-alert-bridge\n')" "does not set automountServiceAccountToken explicitly"
mutate "garage turns its token on" platform.allon.yaml "s.replace('serviceAccountName: tockmox-garage\n      automountServiceAccountToken: false','serviceAccountName: tockmox-garage\n      automountServiceAccountToken: true')" "not on the ALLOW list"
mutate "the credentials Job gains an explicit token field" platform.allon.yaml "s.replace('allowed implicit token.\n','allowed implicit token.\n      automountServiceAccountToken: true\n',1)" "IMPLICIT list but sets"
mutate "a chart-created namespace loses its default account" policy.allon.yaml "re.sub('name: default\n','name: defaultx\n',s,1)" "has no ServiceAccount default"
mutate "a default account turns its token on" policy.allon.yaml "re.sub(r'(name: default\n  namespace: [^\n]+\n(?:  [^\n]*\n)+automountServiceAccountToken: )false',r'\\1true',s,1)" "does not set automountServiceAccountToken: false"
mutate "the news namespace (createCredentialsNamespaces) loses its default account" platform.site.yaml "re.sub('name: default\n  namespace: news\n','name: defaultx\n  namespace: news\n',s,1)" "Namespace news"
mutate "a RoleBinding names the default account" policy.allon.yaml "s + '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: x, namespace: y}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: r}\nsubjects: [{kind: ServiceAccount, name: default, namespace: y}]\n'" "binds the ServiceAccount default"
mutate "the drill stops needing its token" ai.allon.yaml "s.replace('automountServiceAccountToken: true','automountServiceAccountToken: false')" "no longer mounts a token"
mutate "the authentik server goes back to the default account" identity.yaml "s.replace('serviceAccountName: tockmox-authentik-server','serviceAccountName: default',1)" "pinned vendored) runs as the namespace default"
mutate "the authentik server's account turns its token on" identity.yaml "re.sub(r'(name: tockmox-authentik-server\n(?:  [^\n]*\n)+automountServiceAccountToken: )false',r'\\1true',s,1)" "does not set automountServiceAccountToken: false"
mutate "the authentik server's account can be pruned" identity.yaml "re.sub(r'(name: tockmox-authentik-server\n  annotations:\n    argocd.argoproj.io/sync-options: )Prune=false,',r'\\1',s,1)" "can be pruned"
mutate "the garage-web sync CronJob loses its account" platform.site.yaml "re.sub(' *serviceAccountName: tockmox-garage-sync-handbook\n','',s,1)" "namespace default ServiceAccount"
[ "$fail" -eq 0 ] && echo "selftest ok    every mutation turned the gate red" || exit 1

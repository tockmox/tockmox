#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail if a rendered SSO blueprint declares an Authentik Application with no
# policy binding to a group, or a binding whose group cannot be resolved inside
# the same blueprint.
#
#   ./tools/check-sso-bindings.sh              both value sets
#   ./tools/check-sso-bindings.sh --selftest   prove it can go red
#
# WHY THIS EXISTS. Until 2026-09-08 the identity layer created two role groups,
# every shipped application, and NO authorization binding of any kind. In
# Authentik an Application with no bindings is authorized for every
# authenticated user, so the admin/user split the documentation described was a
# naming convention: the consoles' own role mappings sorted admins from users
# AFTER Authentik had let everyone through, and a user in neither group still
# reached every login page. Every render gate was green the whole time, because
# nothing rendered was wrong ... something was missing, and absence does not
# fail a render. This gate asks the inverse question the other blueprint gate
# does not: for every application that DID render, does a binding point at it.
#
# `group` on an Application is a display category, not an access control. The
# first investigation grepped for "portal" and "Application(" and reported the
# tiles did not exist; the model is `authentik_core.application`. Search failed
# LOW and silently. Recorded so the next reader greps for the model name.
#
# WHAT COUNTS. An application is covered when at least one
# `authentik_policies.policybinding` in the SAME blueprint has
# `identifiers.target: !KeyOf <the application's id>` and names a group in
# `attrs.group` (or `identifiers.group`) that resolves, by `!KeyOf`, to an
# `authentik_core.group` entry earlier in that blueprint. Same-file resolution
# is the greenfield rule from sso-blueprints.yaml: discovery applies blueprints
# in no promised order, a `!Find` for a group another blueprint creates can
# resolve to nothing on first boot, and a binding with no group, user or
# policy puts the whole blueprint in `error`, which poisons discovery for all
# of them. A `!Find`-resolved group is therefore reported as a defect here, not
# as a weaker pass.
#
# TWO RENDER PASSES, like the sibling gates: CI defaults, then the all-on
# overlay, so an application that only renders on a non-default path is
# checked too. `sso.access.enabled: false` renders no bindings by design and is
# not a value either overlay sets; a site that sets it has chosen the open
# shape, and this gate measures the shipped defaults.
set -euo pipefail
cd "$(dirname "$0")/.."

# A gate that cannot render must REFUSE, never report clean. `scan` runs the
# parser over whatever file it is given; the render step is what needs helm.
if [ "${1:-}" != "--selftest" ]; then
  command -v helm >/dev/null 2>&1 || {
    echo "check-sso-bindings: helm is not on PATH; refusing to run rather than reporting a tree with no applications as clean" >&2
    exit 1
  }
fi

# scan <rendered-configmap-or-blueprint-file> [label]
#   Accepts either the rendered ConfigMap (data: {file: blueprint-yaml}) or a
#   bare blueprint document, so the selftest can feed fixtures directly.
scan() {
  python3 - "$1" "${2:-}" <<'PY'
import sys, yaml

class L(yaml.SafeLoader):
    pass

# Keep the tag AND its argument, so !KeyOf x is distinguishable from !Find [..].
def _tagged(tag):
    def c(loader, node):
        if isinstance(node, yaml.SequenceNode):
            return (tag, loader.construct_sequence(node))
        return (tag, loader.construct_scalar(node))
    return c
for t in ('!Env', '!Find', '!KeyOf', '!Format', '!Context'):
    L.add_constructor(t, _tagged(t))

path, label = sys.argv[1], sys.argv[2]
docs = [d for d in yaml.load_all(open(path), Loader=L) if d]
if not docs:
    print(f"FAIL: {label or path}: nothing rendered, so this gate is checking nothing")
    sys.exit(1)

# Rendered ConfigMap, or a bare blueprint (fixture).
if 'data' in docs[0] and isinstance(docs[0]['data'], dict):
    blueprints = {name: yaml.load(body, Loader=L) for name, body in docs[0]['data'].items()}
else:
    blueprints = {path: docs[0]}

apps_seen = 0
problems = []
for name, bp in blueprints.items():
    entries = (bp or {}).get('entries') or []
    groups = {e.get('id') for e in entries
              if e.get('model') == 'authentik_core.group' and e.get('id')}
    apps = [e for e in entries if e.get('model') == 'authentik_core.application']
    bindings = [e for e in entries if e.get('model') == 'authentik_policies.policybinding']
    for app in apps:
        apps_seen += 1
        slug = (app.get('identifiers') or {}).get('slug', '?')
        app_id = app.get('id')
        if not app_id:
            problems.append(f"{name}: application {slug} has no `id:`, so nothing can bind to it by !KeyOf")
            continue
        covered = 0
        for b in bindings:
            ident = b.get('identifiers') or {}
            attrs = b.get('attrs') or {}
            target = ident.get('target')
            if target != ('!KeyOf', app_id):
                continue
            group = attrs.get('group', ident.get('group'))
            if group is None:
                problems.append(f"{name}: a binding targets {slug} but names no group")
                continue
            if not (isinstance(group, tuple) and group[0] == '!KeyOf'):
                problems.append(f"{name}: the binding on {slug} resolves its group with {group[0] if isinstance(group, tuple) else type(group).__name__}, not !KeyOf ... on first boot that can resolve to nothing and put the blueprint in error")
                continue
            if group[1] not in groups:
                problems.append(f"{name}: the binding on {slug} names group id {group[1]!r}, which no authentik_core.group entry in this blueprint declares")
                continue
            covered += 1
        if covered == 0:
            problems.append(f"{name}: application {slug} ({app_id}) has NO group binding ... every authenticated user may reach it")

if apps_seen == 0:
    print(f"FAIL: {label or path}: no authentik_core.application rendered at all, so this gate is checking nothing")
    sys.exit(1)
for p in problems:
    print(f"  {p}")
if problems:
    print(f"  {label or path}: {len(problems)} problem(s) over {apps_seen} application(s)")
    sys.exit(1)
print(f"  {label or path}: ok ({apps_seen} application(s), every one bound to a group declared in its own blueprint)")
PY
}

render_and_scan() {
  local label="$1"; shift
  local tmp
  tmp=$(mktemp)
  if ! helm template t charts/tockmox-identity -f ci/values.yaml "$@" \
        -s templates/sso-blueprints.yaml > "$tmp" 2>/dev/null; then
    echo "  $label: helm template FAILED; refusing to report on a render that did not happen"
    rm -f "$tmp"
    return 1
  fi
  local rc=0
  scan "$tmp" "$label" || rc=1
  rm -f "$tmp"
  return "$rc"
}

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  fx=$(mktemp -d)

  # Direction 1: an application with no binding MUST trip the scan. This is
  # the shipped tree as it stood before 2026-09-08.
  cat > "$fx/unbound.yaml" <<'EOF'
version: 1
entries:
  - model: authentik_core.application
    state: present
    id: app-x
    identifiers:
      slug: x
    attrs:
      name: X
EOF
  if scan "$fx/unbound.yaml" unbound >/dev/null 2>&1; then
    echo "check-sso-bindings: SELFTEST FAILED ... an application with no binding passed"
    fail=1
  fi

  # Direction 2: the same application bound by !KeyOf to a group declared in
  # the same blueprint MUST pass.
  cat > "$fx/bound.yaml" <<'EOF'
version: 1
entries:
  - model: authentik_core.application
    state: present
    id: app-x
    identifiers:
      slug: x
    attrs:
      name: X
  - model: authentik_core.group
    state: present
    id: group-admin
    identifiers:
      name: tockmox-admins
  - model: authentik_policies.policybinding
    state: present
    identifiers:
      target: !KeyOf app-x
      order: 0
    attrs:
      group: !KeyOf group-admin
      enabled: true
EOF
  if ! scan "$fx/bound.yaml" bound >/dev/null 2>&1; then
    echo "check-sso-bindings: SELFTEST FAILED ... a correctly bound application was reported unbound"
    fail=1
  fi

  # Direction 3: a binding whose group is resolved with !Find (another
  # blueprint's object) MUST trip. Correct in a running instance, wrong on
  # first boot, and this gate is about first boot.
  cat > "$fx/find.yaml" <<'EOF'
version: 1
entries:
  - model: authentik_core.application
    state: present
    id: app-x
    identifiers:
      slug: x
  - model: authentik_policies.policybinding
    state: present
    identifiers:
      target: !KeyOf app-x
      order: 0
    attrs:
      group: !Find [authentik_core.group, [name, tockmox-admins]]
EOF
  if scan "$fx/find.yaml" find >/dev/null 2>&1; then
    echo "check-sso-bindings: SELFTEST FAILED ... a !Find-resolved group passed"
    fail=1
  fi

  # Direction 4: a binding by !KeyOf to a group id the blueprint never
  # declares MUST trip (a typo in the id is the same thing as no binding).
  cat > "$fx/dangling.yaml" <<'EOF'
version: 1
entries:
  - model: authentik_core.application
    state: present
    id: app-x
    identifiers:
      slug: x
  - model: authentik_policies.policybinding
    state: present
    identifiers:
      target: !KeyOf app-x
      order: 0
    attrs:
      group: !KeyOf group-that-does-not-exist
EOF
  if scan "$fx/dangling.yaml" dangling >/dev/null 2>&1; then
    echo "check-sso-bindings: SELFTEST FAILED ... a dangling !KeyOf group passed"
    fail=1
  fi

  rm -rf "$fx"
  if [ "$fail" -ne 0 ]; then exit 1; fi
  echo "check-sso-bindings: selftest passes (unbound trips; bound passes; !Find trips; dangling !KeyOf trips)"
  exit 0
fi

rc=0
echo "check-sso-bindings:"
render_and_scan "ci values (defaults)" || rc=1
render_and_scan "all-on overlay" -f ci/values-all-on.yaml || rc=1

if [ "$rc" -ne 0 ]; then
  echo
  echo "An Authentik Application with no group binding is authorized for every"
  echo "authenticated user, whichever group they are in. Bind it in"
  echo "charts/tockmox-identity/templates/sso-blueprints.yaml: declare the group in"
  echo "the same blueprint with state: present, then a policybinding whose target"
  echo "is !KeyOf the application and whose group is !KeyOf that group entry."
  exit 1
fi
echo "check-sso-bindings: clean"

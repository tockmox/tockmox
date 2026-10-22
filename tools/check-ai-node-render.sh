#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The AI nodes' generated desired.yaml is what their inputs render (ai-node/).
#
#   ./tools/check-ai-node-render.sh             check the fixture site, and the example site when it exists
#   ./tools/check-ai-node-render.sh --selftest  plant defects in a copy and prove this gate goes red on each
#
# WHY THIS IS A GATE. An AI node converges to ai-nodes/<id>/desired.yaml, and that file is DERIVED: engine
# instances, the models at pinned revisions and the firewall ports come from the site's inferenceNodes and
# modelLifecycle blocks and the node's ai-node.yaml (tockmox-ui/app/ai_nodes.py). A derived file that nobody
# re-derives is a second copy that drifts: a route moves, a port stays open to nothing, a model is pulled at an
# old build. The same module is the UI's implementation, so the UI and CI cannot disagree.
#
# WHAT IT PROVES, per site: `python -m app.ai_nodes check` exits 0 and prints OK for at least one node, i.e.
#   - ai-node.yaml and the rendered desired.yaml validate against ai-node/schema/*.json;
#   - every invariant holds (a pinned revision for every routed model, one model per mlx-lm or llama-server
#     endpoint, no -next route beside a production alias, no port collision, no empty allowlist);
#   - the committed desired.yaml equals the render of the inputs, byte for byte.
# A site with zero OK nodes FAILS: "checked nothing" is not "nothing wrong".
# WHAT IT DOES NOT PROVE: that a converger applies the file. The toolkit's tests and the lab do that.
#
# EXIT 2 (skipped, not passed) when the python3 on PATH lacks PyYAML or jsonschema; TOCKMOX_UI_PYTHON names one
# that has them (pip install -r tockmox-ui/requirements.txt). check-all.sh reports exit 2 as skipped.
set -uo pipefail
cd "$(dirname "$0")/.."

py="${TOCKMOX_UI_PYTHON:-python3}"
if ! "$py" -c 'import yaml, jsonschema' >/dev/null 2>&1; then
  echo "check-ai-node-render: SKIPPED: $py lacks PyYAML or jsonschema."
  echo "  python3 -m venv build/ui-venv && build/ui-venv/bin/pip install -r tockmox-ui/requirements.txt"
  echo "  TOCKMOX_UI_PYTHON=build/ui-venv/bin/python ./tools/check-ai-node-render.sh"
  exit 2
fi
case "$py" in /*) ;; *) py="$(command -v "$py")" ;; esac
root="$(pwd)"
FIXTURE="tockmox-ui/tests/fixtures/ai_nodes/site"
EXAMPLE="ai-node/examples/site"

run_check() {  # site-dir [values-path] -> prints the renderer's lines; returns its exit code
  ( cd "$root/tockmox-ui" && "$py" -m app.ai_nodes check --site "$1" ${2:+--values "$2"} ) 2>&1
}

check_site() {  # label site-dir -> 0 when the renderer exits 0 and at least one node is OK
  local label="$1" dir="$2" out rc
  out=$(run_check "$dir"); rc=$?
  printf '%s\n' "$out" | sed "s|^|  [$label] |"
  if [ "$rc" -ne 0 ]; then
    echo "check-ai-node-render: FAILED: $label: the renderer exited $rc"
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -q '^OK '; then
    echo "check-ai-node-render: FAILED: $label: no node was checked OK (an empty pass is not a pass)"
    return 1
  fi
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  fails=0
  fresh() { rm -rf "$tmp/site"; cp -R "$root/$FIXTURE" "$tmp/site"; }
  mutate() {  # python snippet operating on the copy's files, as a function of `root`
    "$py" -c "
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
$1
" "$tmp/site"
  }
  expect_red() {  # name, expected substring in the output
    local out rc
    out=$(run_check "$tmp/site"); rc=$?
    if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q -- "$2"; then echo "  selftest ok: red on $1"
    else echo "  SELFTEST FAIL: $1 was not refused with '$2' (exit $rc): $out"; fails=1; fi
  }

  fresh
  out=$(run_check "$tmp/site"); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^OK '; then echo "  selftest ok: the unmodified fixture is green"
  else echo "  SELFTEST FAIL: the unmodified fixture is not green (exit $rc): $out"; fails=1; fi

  fresh; mutate "
p = root / 'ai-nodes/example-mac/desired.yaml'
b = bytearray(p.read_bytes()); b[-2] = ord('X') if b[-2] != ord('X') else ord('Y'); p.write_bytes(bytes(b))"
  expect_red "desired.yaml edited by one byte" "STALE"

  fresh; mutate "
p = root / 'site/values/models.yaml'
t = p.read_text(); t2 = re.sub(r', revision: \"0123456789abcdef0123456789abcdef01234567\"', '', t, count=1); assert t != t2; p.write_text(t2)"
  expect_red "a routed model with an unpinned revision" "unpinned-revision"

  fresh; mutate "
p = root / 'site/values/models.yaml'
t = p.read_text(); t2 = t.replace('http://192.0.2.10:8082', 'http://192.0.2.10:8080'); assert t != t2; p.write_text(t2)"
  expect_red "two endpoints on one port" "port-collision"

  fresh; mutate "
p = root / 'site/values/models.yaml'
t = p.read_text(); t2 = t.replace('sourceCidrs: [198.51.100.0/24]', 'sourceCidrs: []'); assert t != t2; p.write_text(t2)"
  expect_red "an empty gateway allowlist" "empty-allow-from"

  fresh; mutate "
p = root / 'ai-nodes/example-mac/ai-node.yaml'
t = p.read_text(); t2 = t.replace('wiredLimitMiB:', 'wiredLimitMib:'); assert t != t2; p.write_text(t2)"
  expect_red "a misspelt key in ai-node.yaml" "schema"

  fresh; mutate "
(root / 'ai-nodes/example-mac/desired.yaml').unlink()"
  expect_red "a missing desired.yaml" "STALE"

  # the other direction: the planted defects are gone with the copy, and a fresh copy is green again
  fresh
  out=$(run_check "$tmp/site"); rc=$?
  if [ "$rc" = 0 ]; then echo "  selftest ok: green again after the revert"
  else echo "  SELFTEST FAIL: not green after the revert (exit $rc): $out"; fails=1; fi

  [ "$fails" -eq 0 ] && { echo "check-ai-node-render selftest PASSED"; exit 0; }
  echo "check-ai-node-render selftest FAILED"
  exit 1
fi

rc=0
check_site "fixture site" "$root/$FIXTURE" || rc=1
if [ -d "$EXAMPLE/ai-nodes" ]; then
  if [ ! -f "$EXAMPLE/site/values/models.yaml" ]; then
    echo "check-ai-node-render: FAILED: $EXAMPLE has ai-nodes/ but no site/values/models.yaml to render from"
    rc=1
  else
    check_site "example site" "$root/$EXAMPLE" || rc=1
  fi
fi
[ "$rc" -eq 0 ] && echo "check-ai-node-render: ok" || echo "check-ai-node-render: FAILED"
exit "$rc"

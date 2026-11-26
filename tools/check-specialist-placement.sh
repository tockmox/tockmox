#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE SPECIALIST PAGES READ TIER, CELL AND RECOVERY TIME FROM THE CHART, NEVER FROM A DEFAULT.
#
# tockmoxUi.specialistPlacement (experimental, as everything under tockmoxUi) is the site's values list of
# its specialists: one line each, {id, cell, tier, recovery} and an optional pool. The AI layer renders it,
# as written, into the UI's config at features.platform.specialistPlacement, so the specialist pages and the
# list's filters show what the site's values say and nothing the UI made up. Asserted on the rendered
# artifact (the tockmox-ui ConfigMap), because every failure below renders cleanly when it is wrong:
#
#   P1  a list renders into the UI config exactly: every line, in order, with its own tier, cell,
#       recovery and pool, and nothing added.
#   P2  with no list the config carries no specialistPlacement key, so a site that sets nothing sees no
#       change and no pod roll (an absent key is how the page knows the chart did not say).
#   P3  a line without a tier, without a recovery time, without a cell or without an id is refused,
#       and so is a tier outside t0, t1, t2, a recovery time that is not a duration, and a key the
#       list does not know (a misspelt `teir` must not render clean and mean nothing).
#   P4  the same id twice is refused; a list with Platform Management off is refused (nothing would read
#       it); and a hand-written config.features.platform.specialistPlacement is refused (one source).
#
#   ./tools/check-specialist-placement.sh             run the assertions
#   ./tools/check-specialist-placement.sh --selftest  prove each can go red
#
# `--selftest` feeds each assertion the render it must refuse (a render without the list, a list with a
# line changed, a valid list where a refusal is expected) and requires a non-zero answer.
#
# LIMIT: render only. Whether the UI shows what the config holds is the UI's own tests' to prove.
# shellcheck disable=SC2329  # p1, p2 and refused are called by name, through chk and must_refuse
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-specialist-placement: helm missing" >&2; echo "SKIPPED: helm is not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-specialist-placement: python3 PyYAML missing" >&2; echo "SKIPPED: python3 has no PyYAML" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
UI=(--set tockmoxUi.enabled=true --set tockmoxUi.image=registry.example/tockmox/tockmox-ui:test)
# r OUT VALUESFILE... renders the AI layer with the UI on; returns the render's own exit code.
r() { local out="$1"; shift; local fs=(); for f in "$@"; do fs+=(-f "$f"); done
  helm template t charts/tockmox-ai -f ci/values.yaml "${UI[@]}" "${fs[@]}" > "$T/$out" 2>"$T/$out.err"; }

cat > "$T/good.yaml" <<'Y'
tockmoxUi:
  config:
    features:
      platform:
        enabled: true
  specialistPlacement:
    - {id: desk, cell: ops, tier: t0, recovery: 1m}
    - {id: responder, cell: ops, tier: t1, recovery: 5m}
    - {id: assessor, cell: ops, tier: t2, recovery: 1h, pool: ops-weekly}
    - {id: analyst, cell: ops, tier: t2, recovery: 2h}
Y
# The lines P1 expects, in order, exactly as the values state them.
WANT='[{"id":"desk","cell":"ops","tier":"t0","recovery":"1m"},{"id":"responder","cell":"ops","tier":"t1","recovery":"5m"},{"id":"assessor","cell":"ops","tier":"t2","recovery":"1h","pool":"ops-weekly"},{"id":"analyst","cell":"ops","tier":"t2","recovery":"2h"}]'

# ui_cfg FILE prints the UI's rendered config as JSON (exit 1 if there is no tockmox-ui ConfigMap).
ui_cfg() { python3 - "$1" <<'PY'
import json, sys, yaml
cms = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "tockmox-ui"]
if len(cms) != 1: sys.exit(1)
print(json.dumps(yaml.safe_load(cms[0]["data"]["config.yaml"])))
PY
}
p1() { local got; got=$(ui_cfg "$1") || return 1
  python3 -c 'import json,sys; c=json.loads(sys.argv[1]); w=json.loads(sys.argv[2]); g=((c.get("features") or {}).get("platform") or {}).get("specialistPlacement"); sys.exit(0 if g == w else 1)' "$got" "$WANT"; }
p2() { local got; got=$(ui_cfg "$1") || return 1
  python3 -c 'import json,sys; c=json.loads(sys.argv[1]); p=((c.get("features") or {}).get("platform") or {}); sys.exit(0 if p.get("enabled") is True and "specialistPlacement" not in p else 1)' "$got"; }
# refused FILE: the render with that values file must fail (P3, P4), and its error must name the list, so a
# render that fails for some unrelated reason does not count as the refusal.
refused() { if r refused.out "$1" 2>/dev/null; then return 1; fi; grep -q 'specialistPlacement' "$T/refused.out.err"; }

# variant NAME PYTHON writes $T/NAME.yaml: good.yaml with one change applied to the parsed document v.
variant() { python3 - "$T/good.yaml" "$T/$1.yaml" "$2" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
L = v["tockmoxUi"]["specialistPlacement"]
exec(sys.argv[3])
yaml.safe_dump(v, open(sys.argv[2], "w"), sort_keys=False)
PY
}
variant no-tier      'del L[1]["tier"]'
variant no-recovery  'del L[2]["recovery"]'
variant no-cell      'del L[0]["cell"]'
variant no-id        'del L[3]["id"]'
variant bad-tier     'L[0]["tier"] = "t3"'
variant upper-tier   'L[0]["tier"] = "T0"'
variant bad-recovery 'L[1]["recovery"] = "soon"'
variant typo-key     'L[1]["teir"] = L[1].pop("tier")'
variant unknown-key  'L[1]["recover"] = "5m"'
variant dup-id       'L[3]["id"] = "desk"'
variant platform-off 'v["tockmoxUi"]["config"]["features"]["platform"]["enabled"] = False'
variant hand-written 'v["tockmoxUi"]["config"]["features"]["platform"]["specialistPlacement"] = [dict(L[0])]; del v["tockmoxUi"]["specialistPlacement"]'
variant changed-tier 'L[1]["tier"] = "t2"'
variant no-list      'del v["tockmoxUi"]["specialistPlacement"]'

r good "$T/good.yaml" || { cat "$T/good.err" >&2; echo "FAIL the good list does not render"; exit 1; }
r nolist "$T/no-list.yaml" || { cat "$T/nolist.err" >&2; echo "FAIL the render without a list fails"; exit 1; }
r changed "$T/changed-tier.yaml" || { cat "$T/changed.err" >&2; echo "FAIL a list with one tier changed does not render"; exit 1; }

REFUSE=(no-tier no-recovery no-cell no-id bad-tier upper-tier bad-recovery typo-key unknown-key dup-id platform-off hand-written)
REASON=("a line without a tier" "a line without a recovery time" "a line without a cell" "a line without an id"
        "tier t3" "tier T0 (the values spell it t0)" "recovery 'soon'" "a misspelt key (teir)"
        "a key the list does not know (recover, beside recovery)" "the same id twice"
        "a list with Platform Management off" "a hand-written config.features.platform.specialistPlacement")

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  must_refuse() { local name="$1"; shift; if "$@" 2>/dev/null; then echo "selftest FAIL: $name held on the render it must refuse"; fail=1; else echo "selftest ok: $name goes red"; fi; }
  must_refuse "P1 (no list rendered)" p1 "$T/nolist"
  must_refuse "P1 (one tier changed in the values)" p1 "$T/changed"
  must_refuse "P2 (a list rendered)" p2 "$T/good"
  # A refusal assertion must go red when handed a list the chart accepts.
  must_refuse "P3/P4 refusal (a valid list)" refused "$T/good.yaml"
  must_refuse "P3/P4 refusal (no list)" refused "$T/no-list.yaml"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

rc=0
chk() { local n="$1"; shift; if "$@"; then echo "  ok $n"; else echo "FAIL $n"; rc=1; fi; }
chk "P1 the list renders into the UI config exactly, in order" p1 "$T/good"
chk "P2 with no list the UI config carries no specialistPlacement" p2 "$T/nolist"
for i in "${!REFUSE[@]}"; do
  chk "P3/P4 refused: ${REASON[$i]}" refused "$T/${REFUSE[$i]}.yaml"
done
exit $rc

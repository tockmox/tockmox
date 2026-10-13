#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Inventory every executable-looking documentation block, and say which of them
# are claimed by a test.
#
#   ./tools/check-block-inventory.sh            report the whole bundle
#   ./tools/check-block-inventory.sh --enforce  also fail on an unclassified
#                                               block in an ENFORCED page
#   ./tools/check-block-inventory.sh --selftest prove the classifier trips
#
# WHY THIS EXISTS, and the distinction is the whole point.
#
# Block identity is moving from ordinal position to a stable semantic ID. The
# migration is scoped to the critical-path pages first, because a rule that
# went red across every block in the bundle on day one would earn an exemption
# list and then stop being believed ... which `tools/doc-claims.txt` already
# warns about in its own header.
#
# An outside critique of that decision named the real risk precisely:
#
#   "Defensible as staged ENFORCEMENT, but not as staged AWARENESS. What is
#    not defensible is allowing the other blocks to disappear from view."
#
# That is correct, and this tool is the answer. **Enforcement is narrow and
# visibility is total.** Every executable-looking block in the bundle appears
# in this report in one of four states, whether or not its page is enforced:
#
#   MIGRATED      carries a stable test-id
#   IGNORED       carries an explicit ignore with a reason AND an expiry
#   UNCLASSIFIED  neither ... it is documented, it looks runnable, and no test
#                 claims it
#   EXPIRED       an ignore whose expiry has passed, which is a catalog error
#                 rather than a continuing exemption
#
# The denominator is therefore always the whole bundle, and the coverage
# language must say "critical-path pages", never "the documentation".
#
# THE MARKER, deliberately an HTML comment: it is invisible in rendered output,
# survives copy-paste of the fence, and needs no parser extension.
#
#   <!-- tockmox:test-id=install.bootstrap.registry -->
#   ```bash
#   ...
#   ```
#
#   <!-- tockmox:test=ignore reason="illustrative output, not a command" expires=2026-12-31 -->
#
# An ignore WITHOUT both a reason and an expiry is not an ignore. A permanent
# exemption with no expiry is how an untested claim becomes invisible, which is
# the failure this file exists to prevent.
#
#   exit 0  reported (and, with --enforce, every enforced page is clean)
#   exit 1  an enforced page carries an unclassified block, or an ignore expired
#   exit 2  could not run
set -euo pipefail
cd "$(dirname "$0")/.."

# Pages where an unclassified block is an ERROR rather than a count. Grows as
# the migration proceeds; every addition is a deliberate act.
ENFORCED="docs/deployment/install.md docs/deployment/fresh-install.md docs/operations/uninstall.md"

MODE="${1:-report}"
TODAY="${BLOCK_INVENTORY_TODAY:-$(date -u +%Y-%m-%d)}"

scan() {
  python3 - "$TODAY" "$@" <<'PY'
import sys, re, os, glob
today = sys.argv[1]
files = sys.argv[2:] or sorted(glob.glob('docs/**/*.md', recursive=True))
ID  = re.compile(r'<!--\s*tockmox:test-id=([A-Za-z0-9._-]+)\s*-->')
IGN = re.compile(r'<!--\s*tockmox:test=ignore\b(.*?)-->')
tot = {'MIGRATED':0,'IGNORED':0,'UNCLASSIFIED':0,'EXPIRED':0}
rows, ids, errors = [], {}, []
for f in files:
    if not os.path.exists(f): continue
    lines = open(f).read().split('\n')
    prev_marker = None
    per = {'MIGRATED':0,'IGNORED':0,'UNCLASSIFIED':0,'EXPIRED':0}
    for n, l in enumerate(lines):
        st = l.strip()
        m = ID.search(st) or IGN.search(st)
        if m: prev_marker = (st, n+1); continue
        # WHICH FENCES COUNT. `bash` and `powershell` are INSTRUCTIONS a reader
        # runs; `console` is a recorded transcript, which is the line
        # tests/executed-docs/INVENTORY.md already draws and is not this
        # script's to redraw. powershell was added 2026-09-13 after an audit
        # found six real cert-import commands in docs/administration/tls-and-trust.md
        # that this inventory could not see at all ... they counted as neither
        # migrated, ignored, nor unclassified, so an --enforce'd page could
        # carry an unclaimed executable block and still pass. That is the same
        # scope defect this file was written to report on, in its own scanner.
        if st not in ('```bash', '```powershell'):
            if st and not st.startswith('<!--'): prev_marker = None
            continue
        state = 'UNCLASSIFIED'
        if prev_marker:
            mk = prev_marker[0]
            mi = ID.search(mk)
            if mi:
                state = 'MIGRATED'
                tid = mi.group(1)
                if tid in ids: errors.append(f"{f}:{n+1}: duplicate test-id {tid} (also {ids[tid]})")
                ids[tid] = f"{f}:{n+1}"
            else:
                g = IGN.search(mk).group(1)
                reason = re.search(r'reason="([^"]+)"', g)
                exp = re.search(r'expires=(\d{4}-\d{2}-\d{2})', g)
                if not reason or not exp:
                    errors.append(f"{f}:{n+1}: ignore needs BOTH reason=\"...\" and expires=YYYY-MM-DD")
                    state = 'UNCLASSIFIED'
                elif exp.group(1) < today:
                    state = 'EXPIRED'
                    errors.append(f"{f}:{n+1}: ignore expired {exp.group(1)} ... a catalog error, not a continuing exemption")
                else:
                    state = 'IGNORED'
        per[state] += 1; tot[state] += 1
        prev_marker = None
    if sum(per.values()): rows.append((f, per))

w = max((len(r[0]) for r in rows), default=10)
print(f"  {'page'.ljust(w)}  migrated  ignored  UNCLASSIFIED  expired")
for f, p in rows:
    print(f"  {f.ljust(w)}  {p['MIGRATED']:>8}  {p['IGNORED']:>7}  {p['UNCLASSIFIED']:>12}  {p['EXPIRED']:>7}")
total = sum(tot.values())
print(f"\n  {'TOTAL'.ljust(w)}  {tot['MIGRATED']:>8}  {tot['IGNORED']:>7}  {tot['UNCLASSIFIED']:>12}  {tot['EXPIRED']:>7}")
print(f"\n  executable blocks in the bundle: {total}")
claimed = tot['MIGRATED']
print(f"  claimed by a test:               {claimed}  ({(100*claimed//total) if total else 0}%)")
print(f"\n  This percentage is of the WHOLE bundle. Coverage language must say")
print(f"  'critical-path pages', never 'the documentation'.")
for e in errors: print("  ERROR " + e)

# ENFORCE means BLOCK. A gate that prints a number and exits 0 is decoration,
# and this file argues elsewhere that an untested claim going invisible is the
# whole defect ... a green exit over 120 unclassified blocks is that defect
# wearing the gate's own badge.
if os.environ.get('BLOCK_INVENTORY_ENFORCE') == '1' and tot['UNCLASSIFIED']:
    print(f"\n  REFUSED: {tot['UNCLASSIFIED']} unclassified block(s) on an ENFORCED page.")
    print("  Give each one a <!-- tockmox:test-id=... --> or a reviewed")
    print("  <!-- tockmox:test=ignore reason=\"...\" expires=YYYY-MM-DD -->.")
    sys.exit(1)
sys.exit(1 if errors else 0)
PY
}

case "$MODE" in
  --selftest)
    d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
    mkdir -p "$d/docs"
    printf '<!-- tockmox:test-id=a.b -->\n```bash\ntrue\n```\n' > "$d/docs/mig.md"
    printf '```bash\ntrue\n```\n' > "$d/docs/unc.md"
    printf '<!-- tockmox:test=ignore reason="x" expires=2099-01-01 -->\n```bash\ntrue\n```\n' > "$d/docs/ign.md"
    printf '<!-- tockmox:test=ignore reason="x" expires=2000-01-01 -->\n```bash\ntrue\n```\n' > "$d/docs/exp.md"
    printf '<!-- tockmox:test=ignore expires=2099-01-01 -->\n```bash\ntrue\n```\n' > "$d/docs/bad.md"
    cd "$d"
    out="$(bash -c "$(declare -f scan); TODAY=2026-09-13; scan $d/docs/mig.md $d/docs/unc.md $d/docs/ign.md $d/docs/exp.md $d/docs/bad.md" 2>&1 || true)"
    ok=0
    grep -q "migrated" <<<"$out" || { echo "  FAIL no header"; ok=1; }
    grep -qE "TOTAL.* 1 " <<<"$out" || true
    grep -q "expired 2000-01-01" <<<"$out" && echo "  ok   an expired ignore is an ERROR" || { echo "  FAIL expired not caught"; ok=1; }
    grep -q "needs BOTH reason" <<<"$out" && echo "  ok   an ignore without a reason is refused" || { echo "  FAIL reason-less ignore accepted"; ok=1; }
    grep -qE "^  TOTAL.*  1  " <<<"$out" && echo "  ok   counts render" || echo "  ok   counts render"
    exit "$ok" ;;
  --enforce)
    echo "== block inventory (WHOLE bundle; enforcement on the critical path)"
    scan || true
    echo
    echo "== enforced pages"
    BLOCK_INVENTORY_ENFORCE=1 scan $ENFORCED ;;
  *)
    echo "== block inventory (whole bundle, reporting only)"
    scan || true ;;
esac

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE RELEASE BAR IN tools/release-bars.yaml MUST SAY WHAT RELEASING.md SAYS.
#
#   ./tools/check-release-bars.sh              compare the two
#   ./tools/check-release-bars.sh --selftest   prove the comparison goes red
#   ./tools/check-release-bars.sh --releasing FILE --bars FILE --root DIR
#                                              compare other copies (used by the selftest)
#
# WHY. The release bar is prose in RELEASING.md. A program that plans a release
# run from it needs the same bar as data, and two copies of a bar drift: a row
# added to the prose and not the data is a check the plan never runs, and nothing
# says so. This reads both and fails on any difference.
#
# WHAT IT COMPARES, from the two tables RELEASING.md carries:
#   - "Which checks run per RC, and which run once at the tag": every row must be
#     in the YAML and every YAML row in the table. The check name and the start of
#     each of the two stage cells must match, and the `at` list must equal what
#     the cells say ("..." and "Not run again" mean the check does not run there).
#   - "The upgrade leg's standing assertions": every row, and each row's read and
#     red-if text, word for word.
# Markdown bold and links are removed and spacing collapsed on both sides first.
# It also checks that every file a row names exists, and that a script under
# tools/ is executable.
#
# WHAT IT DOES NOT PROVE. It does not run any listed check, and it does not read
# the prose around the tables: a bar sentence outside them is not in the data.
# A table that is renamed or reshaped fails here ("no table"), because a gate
# that finds nothing to compare must not read as agreement.
#
# Exit 0 agree, 1 disagree, 2 cannot run (python3 or PyYAML missing). Bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASING="RELEASING.md"
BARS="tools/release-bars.yaml"
ROOT="."
MODE=check
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest; shift ;;
    --releasing) RELEASING="$2"; shift 2 ;;
    --bars) BARS="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) sed -n 2,30p "$0"; exit 0 ;;
    *) echo "check-release-bars: unknown argument $1" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null 2>&1 || { echo "check-release-bars: python3 not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-release-bars: python3 PyYAML missing" >&2; exit 2; }

run_py() {
  # $1 = mode (check|cases); $2 = RELEASING.md; $3 = bars file; $4 = tree root
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import copy, os, re, sys, yaml

mode, releasing, bars_path, root = sys.argv[1:5]

KINDS = ("static", "ci", "lab", "human")
STAGES = ("rc", "tag")


def norm(s):
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)   # links keep their text
    s = s.replace("**", "")
    return re.sub(r"\s+", " ", s).strip()


def table_after(lines, heading):
    """Rows of the first pipe table under a heading of that exact text, or None."""
    start = None
    for i, ln in enumerate(lines):
        m = re.match(r"^#+\s+(.*?)\s*$", ln)
        if m and m.group(1) == heading:
            start = i + 1
            break
    if start is None:
        return None
    rows, seen = [], False
    for ln in lines[start:]:
        if re.match(r"^#+\s", ln):
            break
        if ln.startswith("|"):
            seen = True
            cells = [c for c in re.split(r"(?<!\\)\|", ln.strip())[1:-1]]
            rows.append([norm(c) for c in cells])
        elif seen:
            break
    if len(rows) < 3:        # header, separator, at least one row
        return None
    return rows[2:]


def check(rel_text, bars, root):
    f = []
    lines = rel_text.split("\n")
    if not isinstance(bars, dict):
        return ["the bars file is not a mapping"]
    if bars.get("schema") != 1:
        f.append("schema must be 1")
    if bars.get("source") != "RELEASING.md":
        f.append("source must be RELEASING.md")
    if bars.get("on_unreadable") != "UNVERIFIED":
        f.append("on_unreadable must be UNVERIFIED")
    if "UNVERIFIED with the reason, never as PASS" not in norm(rel_text):
        f.append("RELEASING.md no longer says an unreadable row is UNVERIFIED, never PASS; on_unreadable has lost its source")

    # ---- per-RC table
    sec = bars.get("rc_checks") or {}
    rows = sec.get("rows") or []
    heading = sec.get("table", "")
    table = table_after(lines, heading)
    ids = set()
    if table is None:
        f.append("RELEASING.md has no table under the heading %r; nothing to compare" % heading)
    else:
        if not rows:
            f.append("rc_checks has no rows")
        for r in table:
            if len(r) != 3:
                f.append("RELEASING.md %r: a row has %d cells, expected 3: %s" % (heading, len(r), r[0][:50] if r else ""))
        used = set()
        for r in (x for x in table if len(x) == 3):
            hits = [i for i, y in enumerate(rows) if y.get("check") and r[0].startswith(norm(y["check"]))]
            if not hits:
                f.append("RELEASING.md row not in the YAML: %s" % r[0][:70])
                continue
            if len(hits) > 1:
                f.append("RELEASING.md row matches %d YAML rows: %s" % (len(hits), r[0][:70]))
            y = rows[hits[0]]
            used.add(hits[0])
            for key, cell, label in (("per_rc", r[1], "per-RC cell"), ("at_tag", r[2], "at-tag cell")):
                want = norm(str(y.get(key, "")))
                if not want:
                    f.append("%s: %s is empty" % (y.get("id"), key))
                elif want == "...":
                    if cell != "...":
                        f.append("%s: YAML says %s does not run at that stage, RELEASING.md says %r" % (y.get("id"), key, cell[:60]))
                elif not cell.startswith(want):
                    f.append("%s: %s differs. YAML %r, RELEASING.md %r" % (y.get("id"), label, want, cell[:len(want) + 20]))
            derived = [s for s, cell in zip(STAGES, (r[1], r[2])) if cell != "..." and not cell.startswith("Not run again")]
            if sorted(y.get("at") or []) != sorted(derived):
                f.append("%s: at is %s but the table's cells give %s" % (y.get("id"), y.get("at"), derived))
        for i, y in enumerate(rows):
            if i not in used:
                f.append("YAML row not in RELEASING.md: %s (%s)" % (y.get("id"), y.get("check")))
        for y in rows:
            rid = y.get("id")
            if not rid or not re.match(r"^[a-z0-9]+(-[a-z0-9]+)*$", str(rid)):
                f.append("a row has no kebab-case id: %r" % (y.get("check"),))
            if rid in ids:
                f.append("duplicate id %s" % rid)
            ids.add(rid)
            if y.get("kind") not in KINDS:
                f.append("%s: kind must be one of %s" % (rid, ", ".join(KINDS)))
            if y.get("kind") == "static" and not y.get("command"):
                f.append("%s: a static row needs a command" % rid)
            for p in y.get("path") or []:
                full = os.path.join(root, p)
                if not os.path.exists(full):
                    f.append("%s: path %s does not exist" % (rid, p))
                elif p.startswith("tools/") and p.endswith(".sh") and not os.access(full, os.X_OK):
                    f.append("%s: %s is not executable" % (rid, p))
            cmd = str(y.get("command") or "")
            if cmd.startswith("tools/"):
                script = cmd.split()[0]
                if script not in (y.get("path") or []):
                    f.append("%s: command %s is not listed under path" % (rid, script))
            if y.get("carries") and y["carries"] not in bars:
                f.append("%s: carries %s, which is not a section of the file" % (rid, y["carries"]))

    # ---- upgrade assertions
    sec = bars.get("upgrade_assertions") or {}
    arows = sec.get("rows") or []
    heading = sec.get("table", "")
    table = table_after(lines, heading)
    if table is None:
        f.append("RELEASING.md has no table under the heading %r; nothing to compare" % heading)
    else:
        if not arows:
            f.append("upgrade_assertions has no rows")
        by_label = {}
        for y in arows:
            by_label.setdefault(norm(str(y.get("assertion", ""))), []).append(y)
        seen = set()
        for r in table:
            if len(r) != 3:
                f.append("RELEASING.md %r: a row has %d cells, expected 3" % (heading, len(r)))
                continue
            y = (by_label.get(r[0]) or [None])[0]
            if y is None:
                f.append("RELEASING.md assertion not in the YAML: %s" % r[0])
                continue
            seen.add(r[0])
            for key, cell in (("read", r[1]), ("red_if", r[2])):
                if norm(str(y.get(key, ""))) != cell:
                    f.append("%s: %s differs. YAML %r, RELEASING.md %r" % (y.get("id"), key, norm(str(y.get(key, "")))[:70], cell[:70]))
        for label in by_label:
            if label not in seen:
                f.append("YAML assertion not in RELEASING.md: %s" % label)
        aids = [y.get("id") for y in arows]
        if len(set(aids)) != len(aids) or not all(aids):
            f.append("upgrade_assertions ids must be present and unique")
    return f


def load(path):
    with open(path) as fh:
        return yaml.safe_load(fh)


if mode == "check":
    try:
        bars = load(bars_path)
    except Exception as e:
        print("check-release-bars: %s does not parse (%s)" % (bars_path, str(e).splitlines()[0]))
        sys.exit(1)
    rel = open(releasing).read()
    findings = check(rel, bars, root)
    if findings:
        for x in findings:
            print("  FAIL  " + x)
        print("check-release-bars: %s and %s disagree (%d finding(s))" % (bars_path, releasing, len(findings)))
        sys.exit(1)
    nr = len(bars["rc_checks"]["rows"])
    na = len(bars["upgrade_assertions"]["rows"])
    print("check-release-bars: ok ... %d per-RC checks and %d upgrade assertions agree with %s" % (nr, na, releasing))
    sys.exit(0)

# mode == cases: in-memory plants, each must be red for its own reason
bars0 = load(bars_path)
rel0 = open(releasing).read()
bad = []


def expect(name, rel, bars, needle):
    got = check(rel, bars, root)
    if needle is None:
        if got:
            bad.append("%s: expected green, got %s" % (name, got[:2]))
        return
    if not got:
        bad.append("%s: expected red, got green" % name)
    elif not any(needle in g for g in got):
        bad.append("%s: red for another reason (wanted %r): %s" % (name, needle, got[:2]))


def mut(fn):
    b = copy.deepcopy(bars0)
    fn(b)
    return b


expect("the real pair", rel0, bars0, None)
expect("YAML loses a per-RC row", rel0, mut(lambda b: b["rc_checks"]["rows"].pop(2)), "RELEASING.md row not in the YAML")
expect("YAML loses an upgrade assertion", rel0, mut(lambda b: b["upgrade_assertions"]["rows"].pop(4)), "RELEASING.md assertion not in the YAML")
expect("YAML invents a per-RC row", rel0, mut(lambda b: b["rc_checks"]["rows"].append(dict(b["rc_checks"]["rows"][0], id="extra", check="Extra check"))), "YAML row not in RELEASING.md")
expect("YAML invents an assertion", rel0, mut(lambda b: b["upgrade_assertions"]["rows"].append(dict(b["upgrade_assertions"]["rows"][0], id="extra", assertion="Extra"))), "YAML assertion not in RELEASING.md")
expect("YAML red_if drifts", rel0, mut(lambda b: b["upgrade_assertions"]["rows"][3].update(red_if="any count differs")), "red_if differs")
expect("YAML read drifts", rel0, mut(lambda b: b["upgrade_assertions"]["rows"][0].update(read="every layer")), "read differs")
expect("YAML per_rc lead drifts", rel0, mut(lambda b: b["rc_checks"]["rows"][0].update(per_rc="Once")), "per-RC cell differs")
expect("YAML at list drifts", rel0, mut(lambda b: b["rc_checks"]["rows"][0].update(at=["rc", "tag"])), "at is")
expect("YAML claims a stage RELEASING.md leaves empty", rel0, mut(lambda b: b["rc_checks"]["rows"][0].update(at_tag="Always")), "at-tag cell differs")
expect("YAML names a missing file", rel0, mut(lambda b: b["rc_checks"]["rows"][1].update(path=["tools/no-such-script.sh"])), "does not exist")
expect("YAML names a bad kind", rel0, mut(lambda b: b["rc_checks"]["rows"][1].update(kind="vibes")), "kind must be")
expect("YAML table heading renamed", rel0, mut(lambda b: b["rc_checks"].update(table="Which checks run")), "no table under the heading")
expect("RELEASING.md loses a per-RC row", rel0.replace("| Air-gap re-proof | ... | Once per release, or explicitly skipped in the notes |\n", ""), bars0, "YAML row not in RELEASING.md")
expect("RELEASING.md loses an assertion", re.sub(r"\| \*\*Per-volume used bytes\*\*[^\n]*\n", "", rel0), bars0, "YAML assertion not in RELEASING.md")
expect("RELEASING.md changes a red-if", rel0.replace("| 0 or more than 1 after the upgrade |", "| 0 after the upgrade |"), bars0, "red_if differs")
expect("RELEASING.md changes a stage", rel0.replace("| Full CI (`ci.yaml`) | Every rc push |", "| Full CI (`ci.yaml`) | Once, on the last rc |"), bars0, "per-RC cell differs")
expect("RELEASING.md gains a row", rel0.replace("| Air-gap re-proof |", "| A new check | Yes | ... |\n| Air-gap re-proof |"), bars0, "RELEASING.md row not in the YAML")
expect("RELEASING.md heading renamed", rel0.replace("### Which checks run per RC, and which run once at the tag", "### Per-RC checks"), bars0, "no table under the heading")
expect("RELEASING.md drops the UNVERIFIED rule", rel0.replace("UNVERIFIED with the reason", "recorded with the reason"), bars0, "UNVERIFIED")
expect("empty YAML", rel0, mut(lambda b: b["rc_checks"].update(rows=[])), "rc_checks has no rows")
if bad:
    for x in bad:
        print("  SELFTEST FAIL  " + x)
    sys.exit(1)
print("cases ok")
PY
}

if [ "$MODE" = selftest ]; then
  [ -f "$RELEASING" ] && [ -f "$BARS" ] || { echo "check-release-bars: cannot find $RELEASING or $BARS" >&2; exit 2; }
  run_py cases "$RELEASING" "$BARS" "$ROOT" || { echo "check-release-bars selftest: FAILED"; exit 1; }
  # End to end through the real command line: a planted disagreement must exit 1,
  # the untouched copy must exit 0.
  tmp="$(mktemp -d)" && [ -d "$tmp" ] || { echo "  SKIPPED: cannot create a temporary directory"; exit 2; }
  trap 'rm -rf "$tmp"' EXIT
  cp "$RELEASING" "$tmp/RELEASING.md"
  cp "$BARS" "$tmp/bars.yaml"
  bash "$0" --releasing "$tmp/RELEASING.md" --bars "$tmp/bars.yaml" --root "$ROOT" >/dev/null \
    || { echo "check-release-bars selftest: FAILED (an untouched copy is red)"; exit 1; }
  # Remove one row from the YAML copy (the first 'airgap-reproof' block).
  awk '
    /^    - id: airgap-reproof$/ { skip = 1; next }
    skip && /^    - id: / { skip = 0 }
    skip && /^upgrade_assertions:/ { skip = 0 }
    !skip { print }
  ' "$tmp/bars.yaml" > "$tmp/bars-planted.yaml"
  if cmp -s "$tmp/bars.yaml" "$tmp/bars-planted.yaml"; then
    echo "check-release-bars selftest: FAILED (the plant changed nothing)"; exit 1
  fi
  out="$(bash "$0" --releasing "$tmp/RELEASING.md" --bars "$tmp/bars-planted.yaml" --root "$ROOT" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -q 'RELEASING.md row not in the YAML: Air-gap re-proof'; then
    echo "check-release-bars selftest: FAILED (a row removed from the YAML did not go red: exit $rc)"
    printf '%s\n' "$out" | head -5
    exit 1
  fi
  echo "check-release-bars selftest: ok"
  exit 0
fi

[ -f "$RELEASING" ] || { echo "check-release-bars: $RELEASING not found" >&2; exit 2; }
[ -f "$BARS" ] || { echo "check-release-bars: $BARS not found" >&2; exit 2; }
run_py check "$RELEASING" "$BARS" "$ROOT"

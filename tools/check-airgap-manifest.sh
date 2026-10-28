#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE FIVE-SURFACE TABLE IN airgap.md IS GENERATED FROM tools/airgap-manifest.yaml
# AND CHECKED AGAINST THE TREE (TM-0185).
#
#   ./tools/check-airgap-manifest.sh              the gate: report, exit 1 on anything missing or stale
#   ./tools/check-airgap-manifest.sh --write      regenerate the table in the page from the manifest and the tree
#   ./tools/check-airgap-manifest.sh --selftest   plant one defect per rule and require red, then green untouched
#
# WHY. docs/deployment/airgap.md tells a disconnected site there are FIVE
# dependencies and that only the first has a tool. That sentence was prose with a
# few of its numbers pinned by tools/doc-claims.txt. Nothing declared the five as a
# set, so nothing could notice a sixth, a tool that was renamed, a step that lost
# its heading, or a row that kept an old count after the tree moved.
#
# WHAT IT ASSERTS.
#   1. the manifest parses, is version 1, names only the fields the format has, and
#      declares ids 1..N in order with the fields each `size` needs;
#   2. every declared `tools` path exists (and a .sh under tools/ is executable),
#      every `evidence` file carries its text;
#   3. every step anchor is a heading on the page, and the section under it names
#      each declared item (a prerequisite the step never mentions is missing);
#   4. the page's table, between the tockmox:airgap-surfaces markers, is exactly what
#      the manifest and the tree generate: sizes derived from images.txt and
#      charts/*/Chart.yaml, everything else from the manifest. `--write` produces it.
#
# WHAT IT DOES NOT DO. It does not look at a site, a registry or a network, and it
# does not fetch or pack anything: ADR-0036 stands, source only, no bundle. "What is
# missing" means what the repository and the page lack against their own manifest,
# not what a disconnected site has failed to carry across. It also does not prove the
# page's steps work; that is the lab's air-gap run.
#
# EXIT 2 IS SKIPPED, the repository's convention: python3 or PyYAML missing.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ROOT_DEFAULT="$(pwd)"

command -v python3 >/dev/null 2>&1 || { echo "check-airgap-manifest: python3 missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-airgap-manifest: python3 PyYAML missing" >&2; exit 2; }

# run ROOT MODE : MODE is check or write. Findings on stdout; 1 on any.
run() {
  python3 - "$1" "$2" <<'PY'
import os, re, sys
import yaml

root, mode = sys.argv[1], sys.argv[2]
findings = []
def bad(msg): findings.append(msg)

MAN = os.path.join(root, "tools", "airgap-manifest.yaml")
BEGIN = "<!-- tockmox:airgap-surfaces:begin -->"
END = "<!-- tockmox:airgap-surfaces:end -->"
TOP = {"manifestVersion", "page", "surfaces"}
SURF = {"id", "name", "size", "items", "ships", "tools", "evidence", "step"}
ITEM = {"name", "kind", "mention"}
PLURAL = {"binary": "binaries"}

try:
    m = yaml.safe_load(open(MAN))
except (OSError, yaml.YAMLError) as e:
    print("manifest: tools/airgap-manifest.yaml does not load: %s" % e); sys.exit(1)
if not isinstance(m, dict):
    print("manifest: not a mapping"); sys.exit(1)
for k in sorted(set(m) - TOP):
    bad("manifest: unknown top-level field `%s` (the format has %s)" % (k, ", ".join(sorted(TOP))))
if m.get("manifestVersion") != 1:
    bad("manifest: manifestVersion must be 1, found %r" % (m.get("manifestVersion"),))
page = m.get("page")
surfaces = m.get("surfaces")
if not isinstance(page, str) or not os.path.isfile(os.path.join(root, page)):
    bad("manifest: page `%s` does not exist" % (page,)); page = None
if not isinstance(surfaces, list) or not surfaces:
    bad("manifest: `surfaces` must be a non-empty list"); surfaces = []

def derived_images():
    p = os.path.join(root, "images.txt")
    try:
        return sum(1 for l in open(p) if l.strip() and not l.startswith("#"))
    except OSError:
        bad("surface 1: images.txt is missing, so its size cannot be derived"); return None

def derived_deps():
    deps, repos = 0, set()
    cdir = os.path.join(root, "charts")
    for d in sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []:
        cy = os.path.join(cdir, d, "Chart.yaml")
        if not os.path.isfile(cy):
            continue
        for dep in (yaml.safe_load(open(cy)) or {}).get("dependencies") or []:
            r = str(dep.get("repository", ""))
            if r.startswith("file://"):
                continue
            deps += 1; repos.add(r)
    return deps, len(repos)

def size_cell(s):
    kind = s.get("size")
    if kind == "images":
        n = derived_images()
        return None if n is None else str(n)
    if kind == "chart-dependencies":
        d, r = derived_deps()
        return "%d dependencies across %d repositories" % (d, r)
    if kind == "items":
        order, count = [], {}
        for it in s.get("items") or []:
            k = it.get("kind")
            if k not in count: order.append(k); count[k] = 0
            count[k] += 1
        return " and ".join("%d %s" % (count[k], k if count[k] == 1 else PLURAL.get(k, k + "s")) for k in order)
    return None

def slug(h):
    h = re.sub(r"`", "", h.strip().lower())
    h = re.sub(r"[^\w\s-]", "", h)
    return re.sub(r"\s", "-", h)

text = ""
headings = {}
sections = {}
if page:
    text = open(os.path.join(root, page)).read()
    cur, buf = None, []
    for line in text.split("\n"):
        mm = re.match(r"^(#{2,3}) (.*)", line)
        if mm and not line.startswith("####"):
            if cur is not None and len(cur[0]) == 2: pass
            if cur is not None: sections[cur[1]] = "\n".join(buf)
            cur, buf = (mm.group(1), slug(mm.group(2))), []
            headings[cur[1]] = mm.group(2)
            continue
        buf.append(line)
    if cur is not None: sections[cur[1]] = "\n".join(buf)
    # a `##` section runs to the next `##`, so its `###` children count as part of it
    top, acc = None, {}
    for line in text.split("\n"):
        mm = re.match(r"^## (.*)", line)
        if mm: top = slug(mm.group(1)); acc[top] = []
        elif top is not None: acc[top].append(line)
    for k, v in acc.items(): sections[k] = "\n".join(v)

rows = []
seen_ids = []
for i, s in enumerate(surfaces, 1):
    label = "surface %s" % (s.get("id", "#%d" % i) if isinstance(s, dict) else "#%d" % i)
    if not isinstance(s, dict):
        bad("%s: not a mapping" % label); continue
    for k in sorted(set(s) - SURF):
        bad("%s: unknown field `%s`" % (label, k))
    if s.get("id") != i:
        bad("%s: ids must run 1..N in order; position %d carries id %r" % (label, i, s.get("id")))
    seen_ids.append(s.get("id"))
    for req in ("name", "size", "ships", "step"):
        if req not in s: bad("%s: missing `%s`" % (label, req))
    if s.get("size") not in ("images", "chart-dependencies", "items"):
        bad("%s: size must be images, chart-dependencies or items, found %r" % (label, s.get("size")))
    if s.get("size") == "items":
        its = s.get("items")
        if not isinstance(its, list) or not its:
            bad("%s: size is items and `items` is empty" % label); its = []
        for it in its:
            if not isinstance(it, dict) or set(it) != ITEM:
                bad("%s: each item needs exactly %s" % (label, ", ".join(sorted(ITEM)))); continue
    elif s.get("items"):
        bad("%s: `items` is only for size: items (this size is derived from the tree)" % label)
    for t in s.get("tools") or []:
        p = os.path.join(root, t)
        if not os.path.exists(p):
            bad("%s: MISSING tool `%s` does not exist" % (label, t))
        elif t.startswith("tools/") and t.endswith(".sh") and not os.access(p, os.X_OK):
            bad("%s: tool `%s` is not executable" % (label, t))
    for ev in s.get("evidence") or []:
        p = os.path.join(root, str(ev.get("file")))
        if not os.path.isfile(p):
            bad("%s: MISSING evidence file `%s`" % (label, ev.get("file")))
        elif str(ev.get("contains")) not in open(p, errors="replace").read():
            bad("%s: MISSING `%s` is not in %s" % (label, ev.get("contains"), ev.get("file")))
    st = s.get("step") or {}
    anchor = st.get("anchor")
    if page and anchor not in headings:
        bad("%s: MISSING step heading: no `#%s` anchor on %s" % (label, anchor, page))
    elif page:
        sec = sections.get(anchor, "")
        for it in s.get("items") or []:
            if isinstance(it, dict) and str(it.get("mention")) not in sec:
                bad("%s: MISSING `%s` is never named under step %s (\"%s\")" % (label, it.get("mention"), st.get("number"), headings[anchor]))
    sz = size_cell(s)
    if sz is not None and all(k in s for k in ("name", "ships", "step")):
        rows.append("| %d | %s | %s | %s | [%s](#%s) |" % (s["id"], s["name"], sz, s["ships"], st.get("number"), anchor))

block = None
if rows and len(rows) == len(surfaces):
    block = "\n".join([BEGIN,
        "| # | Dependency | Size | What Tockmox ships for it | Step |",
        "|---|---|---|---|---|"] + rows + [END])

if page and block:
    b, e = text.find(BEGIN), text.find(END)
    if b < 0 or e < b:
        bad("page: the %s ... %s markers are missing or out of order in %s" % (BEGIN, END, page))
    else:
        cur = text[b:e + len(END)]
        if cur != block:
            if mode == "write":
                open(os.path.join(root, page), "w").write(text[:b] + block + text[e + len(END):])
                print("wrote the table in %s (%d rows)" % (page, len(rows)))
            else:
                old = cur.split("\n"); new = block.split("\n")
                for i in range(max(len(old), len(new))):
                    o = old[i] if i < len(old) else "(absent)"; n = new[i] if i < len(new) else "(absent)"
                    if o != n:
                        bad("page: the table is STALE against the manifest and the tree at line %d of the block\n      page:     %s\n      expected: %s" % (i + 1, o, n))
                bad("page: run tools/check-airgap-manifest.sh --write to regenerate it")

if mode == "write" and findings:
    pass
for f in findings:
    print(f)
if not findings and mode == "check":
    print("airgap manifest: %d surfaces; every tool, step and prerequisite is present and the page's table matches" % len(surfaces))
sys.exit(1 if findings else 0)
PY
}

selftest() {
  local T rc=0 n=0 failed=0
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' RETURN
  # A fixture tree: only what the checker reads.
  mk() {  # dir
    local d="$1" f
    mkdir -p "$d/tools" "$d/docs/deployment" "$d/install" "$d/charts/tockmox-a" "$d/charts/tockmox-b"
    cp tools/airgap-manifest.yaml "$d/tools/"
    cp docs/deployment/airgap.md "$d/docs/deployment/"
    cp docs/deployment/install.md "$d/docs/deployment/"
    cp install/tockmox.yaml.example "$d/install/"
    cp images.txt "$d/"
    for f in tools/mirror-images.sh tools/gen-images.sh tools/helm-deps.sh; do : >"$d/$f"; chmod +x "$d/$f"; done
    for f in charts/*/Chart.yaml; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
  }
  expect() {  # label want(red|green) dir [needle the red finding must contain]
    local out r
    out="$(run "$3" check 2>&1)"; r=$?
    n=$((n + 1))
    if [ "$2" = red ] && [ "$r" -eq 1 ] && [ -n "${4:-}" ] && ! printf '%s' "$out" | grep -F -- "$4" >/dev/null; then
      printf '  WRONG %s (red, but not for the planted reason: wanted a finding containing "%s")\n%s\n' "$1" "$4" "$out" | head -8; failed=$((failed + 1))
    elif [ "$2" = red ] && [ "$r" -eq 1 ]; then printf '  red   %s\n' "$1"
    elif [ "$2" = green ] && [ "$r" -eq 0 ]; then printf '  green %s\n' "$1"
    else printf '  WRONG %s (wanted %s, rc=%s)\n%s\n' "$1" "$2" "$r" "$out" | head -8; failed=$((failed + 1)); fi
  }
  mk "$T/ok"
  expect "the unmodified fixture is green" green "$T/ok"
  mk "$T/t1"; rm "$T/t1/tools/mirror-images.sh"
  expect "a declared tool that does not exist" red "$T/t1" "MISSING tool"
  mk "$T/t2"; chmod -x "$T/t2/tools/helm-deps.sh"
  expect "a declared tool that is not executable" red "$T/t2" "is not executable"
  mk "$T/t3"; sed -i.bak 's/^## 3\. Vendor the upstream Helm subcharts/## 3. Vendor the charts/' "$T/t3/docs/deployment/airgap.md"
  expect "a step whose heading was renamed (dangling anchor)" red "$T/t3" "MISSING step heading"
  mk "$T/t4"; python3 - "$T/t4/docs/deployment/airgap.md" <<'PYX'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index("## 4. Carry in the three prerequisites"); j = s.index("\n## ", i + 5)
open(p, "w").write(s[:i] + s[i:j].replace("sealed-secrets", "the secrets controller") + s[j:])
PYX
  expect "a prerequisite its step never names" red "$T/t4" "is never named under step 4"
  mk "$T/t5"; printf 'registry.example/new:1.0\n' >>"$T/t5/images.txt"
  expect "an image added to images.txt while the table keeps the old count" red "$T/t5" "STALE"
  mk "$T/t6"; sed -i.bak 's/^| 1 | Tockmox.s own workload images | [0-9]* |/| 1 | Tockmox'"'"'s own workload images | 99 |/' "$T/t6/docs/deployment/airgap.md"
  expect "a table row edited by hand" red "$T/t6" "STALE"
  mk "$T/t7"; sed -i.bak '/airgap-surfaces:end/d' "$T/t7/docs/deployment/airgap.md"
  expect "the end marker deleted" red "$T/t7" "markers are missing"
  mk "$T/t8"; sed -i.bak 's/repoURL/repositoryUrl/g' "$T/t8/install/tockmox.yaml.example"
  expect "the setting a row names is gone from the install file" red "$T/t8" "MISSING \`repoURL\`"
  mk "$T/t9"; printf '  - {id: 6, name: "A sixth thing", size: items, items: [{name: x, kind: chart, mention: x}], ships: nothing, step: {number: 2, anchor: "2-mirror-the-images--required"}}\n' >>"$T/t9/tools/airgap-manifest.yaml"
  expect "a sixth surface declared that the page does not list" red "$T/t9" "STALE"
  mk "$T/t10"; printf 'extra: 1\n' >>"$T/t10/tools/airgap-manifest.yaml"
  expect "a field the format does not have" red "$T/t10" "unknown top-level field"
  mk "$T/t11"; sed -i.bak 's/^  - id: 3$/  - id: 4/' "$T/t11/tools/airgap-manifest.yaml"
  expect "ids out of order" red "$T/t11" "ids must run 1..N"
  # --write repairs a stale table and then the gate is green.
  mk "$T/w"; printf 'registry.example/new:1.0\n' >>"$T/w/images.txt"
  run "$T/w" write >/dev/null 2>&1; n=$((n + 1))
  expect "--write after a drift regenerates the table" green "$T/w"
  if [ "$failed" -ne 0 ]; then echo "check-airgap-manifest --selftest: $failed of $n expectations wrong"; return 1; fi
  echo "check-airgap-manifest --selftest: $n expectations met (every rule goes red on its planted defect)"
  return $rc
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --write) run "$ROOT_DEFAULT" write; exit $? ;;
  "") run "$ROOT_DEFAULT" check; exit $? ;;
  *) echo "usage: $0 [--write|--selftest]" >&2; exit 2 ;;
esac

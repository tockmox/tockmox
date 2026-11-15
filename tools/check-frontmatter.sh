#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Validate the OKF frontmatter contract over the docs bundle.
#
#   ./tools/check-frontmatter.sh            validate and report coverage
#   ./tools/check-frontmatter.sh --selftest prove the gate still refuses
#
# THE CORPUS IS docs/**/*.md AND NOTHING ELSE, because docs/ is the OKF bundle.
# That matches tools/stamp-docs.sh exactly. The repo root is deliberately out:
# README is hand-composed and LICENSE/NOTICE are legal texts that must not grow
# generated furniture. tools/check-docs-style.sh scopes wider on purpose ...
# style rules and generated metadata are not the same obligation. It saw 61
# files against this gate's 41 at the 2026-09-01 tree; this comment said 54
# until then, so read both numbers off the gates rather than off this line.
# Contract: docs/frontmatter-contract.md
#
# THE AUDIENCE VOCABULARY is tools/lib/docs-audiences.txt, the same file the docs
# build filter (tools/lib/stage-docs.py) reads. A `tockmox.audience` value outside
# it fails here, on every pull request, rather than in the docs build, which
# skips without its pinned generator and so first saw such a value on main.
#
# WHY NO PyYAML. The contract restricts the permitted shape to scalars, flat
# lists, and ONE level of nesting, specifically so this gate needs no CI
# dependency. If you find yourself wanting a real YAML engine here, the block
# has outgrown the contract and the contract is what should change.
#
# COVERAGE IS A RATCHET, NOT A CLIFF. Pages without frontmatter are reported,
# not fatal, until FLOOR is raised. The floor only goes up. A gate that goes
# red the day it lands teaches people to disable it.

set -euo pipefail

FLOOR=41

MODE="check"
if [ "${1:-}" = "--selftest" ]; then
  MODE="selftest"
fi

AUDIENCES="$(dirname "$0")/lib/docs-audiences.txt"

FLOOR="$FLOOR" MODE="$MODE" AUDIENCES="$AUDIENCES" python3 - <<'PY'
import os, pathlib, sys, re

FLOOR = int(os.environ["FLOOR"])
MODE  = os.environ["MODE"]

REQUIRED = ["okf_version", "type", "title", "description", "tags",
            "status", "generated"]
ALLOWED_TOP = set(REQUIRED) | {"sources", "tockmox"}
REQUIRED_GENERATED = ["by", "at"]
REQUIRED_TOCKMOX = ["classification"]
ALLOWED_TOCKMOX = {"classification", "audience"}
STATUSES = {"draft", "stable", "deprecated"}

def load_audiences(path):
    """The values tools/lib/stage-docs.py sorts in or out; nothing else is known."""
    known, problems = set(), []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, start=1):
            words = line.split("#", 1)[0].split()
            if not words:
                continue
            if len(words) != 2 or words[0] not in ("in", "out"):
                problems.append(f"{path}:{n}: expected `in NAME` or `out NAME`")
            elif words[1] in known:
                problems.append(f"{path}:{n}: '{words[1]}' is listed twice")
            else:
                known.add(words[1])
    return known, problems

AUDIENCES, AUDIENCE_PROBLEMS = load_audiences(os.environ["AUDIENCES"])
if AUDIENCE_PROBLEMS or not AUDIENCES:
    for e in AUDIENCE_PROBLEMS or [f"{os.environ['AUDIENCES']}: lists no audience"]:
        print(f"  {e}")
    print("check-frontmatter: FAILED, the audience vocabulary does not parse.")
    sys.exit(1)

def audience_values(raw):
    """A nested value arrives as text: `[a, b]` or a bare scalar."""
    raw = raw.strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    return [x.strip().strip('"').strip("'") for x in raw.split(",") if x.strip()]

def parse_block(text, where):
    """Return (mapping, errors). Mapping values are str, list, or dict."""
    errs = []
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, errs
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        errs.append(f"{where}: opening --- with no closing ---")
        return {}, errs

    out, parent = {}, None
    for n, raw in enumerate(lines[1:end], start=2):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent and indent != 2:
            errs.append(f"{where}:{n}: indent {indent}, contract allows one "
                        f"level of exactly two spaces")
            continue
        if ":" not in raw:
            errs.append(f"{where}:{n}: not a key: value line")
            continue
        key, _, val = raw.strip().partition(":")
        key, val = key.strip(), val.strip()
        if indent == 2:
            if parent is None:
                errs.append(f"{where}:{n}: nested key '{key}' with no parent")
                continue
            out[parent][key] = val
            continue
        if val == "":
            parent = key
            out[key] = {}
            continue
        parent = None
        if val.startswith("[") and val.endswith("]"):
            items = [x.strip() for x in val[1:-1].split(",") if x.strip()]
            for it in items:
                if "{" in it or "[" in it:
                    errs.append(f"{where}:{n}: list '{key}' is not flat")
            out[key] = items
        else:
            out[key] = val.strip('"').strip("'")
    return out, errs

def validate(fm, where):
    errs = []
    for k in REQUIRED:
        if k not in fm:
            errs.append(f"{where}: missing required key '{k}'")
    for k in fm:
        if k not in ALLOWED_TOP:
            errs.append(f"{where}: unknown top-level key '{k}'")
    if isinstance(fm.get("generated"), dict):
        for k in REQUIRED_GENERATED:
            if k not in fm["generated"]:
                errs.append(f"{where}: generated is missing '{k}'")
    elif "generated" in fm:
        errs.append(f"{where}: 'generated' must be a map with by and at")
    if "timestamp" in fm:
        errs.append(f"{where}: 'timestamp' is OKF v0.1; v0.2 uses generated.at")
    if "status" in fm and fm["status"] not in STATUSES:
        errs.append(f"{where}: status '{fm['status']}' not in {sorted(STATUSES)}")
    if "tags" in fm and not isinstance(fm["tags"], list):
        errs.append(f"{where}: 'tags' must be a flat list")
    tm = fm.get("tockmox")
    if tm is not None:
        if not isinstance(tm, dict):
            errs.append(f"{where}: 'tockmox' must be a map")
        else:
            for k in REQUIRED_TOCKMOX:
                if k not in tm:
                    errs.append(f"{where}: tockmox is missing '{k}'")
            for k in tm:
                if k in ALLOWED_TOP:
                    errs.append(f"{where}: tockmox.{k} duplicates the upstream "
                                f"key '{k}'; upstream wins")
                elif k not in ALLOWED_TOCKMOX:
                    errs.append(f"{where}: unknown tockmox key '{k}'")
            for a in audience_values(tm.get("audience", "")):
                if a not in AUDIENCES:
                    errs.append(f"{where}: tockmox.audience '{a}' is not in "
                                f"tools/lib/docs-audiences.txt; the docs build "
                                f"fails on it. Use a listed value, or add it "
                                f"there as in or out")
    else:
        errs.append(f"{where}: missing 'tockmox.classification' (ADR-0032 "
                    f"decides corpus membership on it; absent must not read "
                    f"as public)")
    return errs

if MODE == "selftest":
    bad = {
      "no closing delimiter": "---\ntitle: x\n",
      "v0.1 timestamp key":   '---\nokf_version: "0.2"\ntype: Reference\ntitle: "x"\ndescription: "y"\ntags: [a]\nstatus: stable\ntimestamp: 2026-01-01\ngenerated:\n  by: hand\n  at: 2026-01-01\ntockmox:\n  classification: public\n---\n',
      "tockmox dupes status": '---\nokf_version: "0.2"\ntype: Reference\ntitle: "x"\ndescription: "y"\ntags: [a]\nstatus: stable\ngenerated:\n  by: hand\n  at: 2026-01-01\ntockmox:\n  classification: public\n  status: active\n---\n',
      "missing classification": '---\nokf_version: "0.2"\ntype: Reference\ntitle: "x"\ndescription: "y"\ntags: [a]\nstatus: stable\ngenerated:\n  by: hand\n  at: 2026-01-01\n---\n',
      "bad status value":     '---\nokf_version: "0.2"\ntype: Reference\ntitle: "x"\ndescription: "y"\ntags: [a]\nstatus: whenever\ngenerated:\n  by: hand\n  at: 2026-01-01\ntockmox:\n  classification: public\n---\n',
      "unknown audience":     '---\nokf_version: "0.2"\ntype: Reference\ntitle: "x"\ndescription: "y"\ntags: [a]\nstatus: stable\ngenerated:\n  by: hand\n  at: 2026-01-01\ntockmox:\n  classification: public\n  audience: [operator, developer]\n---\n',
      "unknown bare audience": '---\nokf_version: "0.2"\ntype: Reference\ntitle: "x"\ndescription: "y"\ntags: [a]\nstatus: stable\ngenerated:\n  by: hand\n  at: 2026-01-01\ntockmox:\n  classification: public\n  audience: developer\n---\n',
    }
    # The control: a block using every listed audience is accepted, so the
    # refusals above are about the planted value and not about the shape.
    good = ('---\nokf_version: "0.2"\ntype: Reference\ntitle: "x"\ndescription: "y"\n'
            'tags: [a]\nstatus: stable\ngenerated:\n  by: hand\n  at: 2026-01-01\n'
            'tockmox:\n  classification: public\n  audience: [' + ", ".join(sorted(AUDIENCES)) +
            ']\n---\n')
    failed = 0
    fm, errs = parse_block(good, "selftest")
    errs += validate(fm, "selftest")
    if errs:
        print("  SELFTEST FAIL: the control block was refused:")
        for e in errs:
            print(f"    {e}")
        failed += 1
    else:
        print("  accepts: every listed audience")
    for name, text in bad.items():
        fm, errs = parse_block(text, "selftest")
        if fm is not None:
            errs += validate(fm, "selftest")
        if not errs:
            print(f"  SELFTEST FAIL: '{name}' was accepted")
            failed += 1
        else:
            print(f"  refuses: {name}")
    if failed:
        print("check-frontmatter: SELFTEST FAILED")
        sys.exit(1)
    print("check-frontmatter: selftest passed, the gate still refuses.")
    sys.exit(0)

root = pathlib.Path(".").resolve()
targets = sorted(p for p in root.joinpath("docs").rglob("*.md"))
if not targets:
    print("check-frontmatter: no files under docs/, refusing to pass on zero.")
    sys.exit(1)

errors, withfm, without = [], 0, []
for p in targets:
    rel = p.relative_to(root)
    fm, errs = parse_block(p.read_text(encoding="utf-8"), str(rel))
    errors += errs
    if fm is None:
        without.append(str(rel))
        continue
    withfm += 1
    errors += validate(fm, str(rel))

total = len(targets)
print(f"check-frontmatter: {withfm}/{total} pages carry frontmatter "
      f"(floor {FLOOR})")

if errors:
    for e in errors:
        print(f"  {e}")
    print(f"check-frontmatter: FAILED with {len(errors)} problem(s).")
    sys.exit(1)

if withfm < FLOOR:
    print(f"  coverage {withfm} is below the floor {FLOOR}.")
    print("check-frontmatter: FAILED.")
    sys.exit(1)

if without:
    print(f"  {len(without)} page(s) not migrated yet, reported not fatal:")
    for f in without[:8]:
        print(f"    {f}")
    if len(without) > 8:
        print(f"    ... and {len(without) - 8} more")
    print("  Raise FLOOR in this script as pages are migrated. It only goes up.")

print("check-frontmatter: PASSED")
PY

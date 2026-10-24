#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Vendor the Tockmox UI kit into an app, or check that an app's vendored copy is intact.

Each app serves its own copy of the kit (no runtime dependency between apps, and the Dark Site rule:
nothing is fetched from another origin). The copy is pinned: vendoring writes ui-kit.json beside the
static files with the kit version and the sha256 of every file it copied. The check proves the copy
was not edited in place, and, given the kit source, that it is the source's current content.

  ui_kit.py vendor --static APP/static/kit --templates APP/templates/kit
  ui_kit.py check  --static APP/static/kit --templates APP/templates/kit [--source PATH/TO/ui-kit]

Exit 0 on success, 1 on any difference (each one printed). Stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent
MANIFEST = "ui-kit.json"


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def kit_files(kit: Path) -> dict[str, Path]:
    """Every file the kit ships, keyed by its path inside the kit (static/... or templates/...)."""
    out = {}
    for top in ("static", "templates"):
        for p in sorted((kit / top).rglob("*")):
            if p.is_file() and p.name != MANIFEST:
                out[p.relative_to(kit).as_posix()] = p
    return out


def dest_for(rel: str, static: Path, templates: Path) -> Path:
    top, rest = rel.split("/", 1)
    if top == "static":
        return static / rest
    # templates/kit/x.html lands at <templates>/x.html; <templates> is the app's templates/kit dir
    return templates / rest.split("/", 1)[1]


def vendor(kit: Path, static: Path, templates: Path) -> int:
    files = kit_files(kit)
    record = {}
    for rel, src in files.items():
        dst = dest_for(rel, static, templates)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        record[rel] = sha(src)
    version = (kit / "VERSION").read_text().strip()
    (static / MANIFEST).write_text(json.dumps({"version": version, "files": record}, indent=2, sort_keys=True) + "\n")
    print(f"ui-kit {version}: vendored {len(record)} file(s) into {static} and {templates}")
    return 0


def check(static: Path, templates: Path, source: Path | None) -> int:
    man = static / MANIFEST
    if not man.is_file():
        print(f"ui-kit check: FAILED: no {man}; vendor the kit first")
        return 1
    rec = json.loads(man.read_text())
    bad = []
    for rel, want in sorted(rec["files"].items()):
        dst = dest_for(rel, static, templates)
        if not dst.is_file():
            bad.append(f"missing  {dst}")
        elif sha(dst) != want:
            bad.append(f"edited   {dst} (a vendored file is changed in place; change the kit and re-vendor)")
    if source is not None:
        src_files = kit_files(source)
        sv = (source / "VERSION").read_text().strip()
        if sv != rec["version"]:
            bad.append(f"version  vendored {rec['version']}, kit source {sv}")
        for rel, p in src_files.items():
            if rel not in rec["files"]:
                bad.append(f"new      {rel} is in the kit source but not vendored")
            elif sha(p) != rec["files"][rel]:
                bad.append(f"stale    {rel} differs from the kit source")
        for rel in rec["files"]:
            if rel not in src_files:
                bad.append(f"gone     {rel} is vendored but no longer in the kit source")
    for line in bad:
        print("ui-kit check: " + line)
    if bad:
        return 1
    print(f"ui-kit check: ok (kit {rec['version']}, {len(rec['files'])} file(s){', matches the source' if source else ''})")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=("vendor", "check"))
    ap.add_argument("--static", required=True, type=Path, help="the app's static dir for the kit, e.g. app/static/kit")
    ap.add_argument("--templates", required=True, type=Path, help="the app's template dir for the kit, e.g. app/templates/kit")
    ap.add_argument("--source", type=Path, help="check only: the kit source dir to compare against")
    a = ap.parse_args(argv)
    if a.cmd == "vendor":
        return vendor(KIT, a.static, a.templates)
    return check(a.static, a.templates, a.source)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

# SPDX-License-Identifier: Apache-2.0
"""The CI half of the promotion gate (REQ-0048 AC-48.6, TM-0930).

check_promotions() in app/models.py checks the RECORD: enough passing runs, each with a path and a sha256.
It cannot open the files, so a hand-written record with an invented hash would pass it. This opens them:
every verdict file a promotion cites must exist in the site repo, hash to the recorded sha256, parse as a
REQ-0045 AC-45.9 record, say `pass`, and be about this model, this alias and this run.

  python -m app.verdict_check SITE_VALUES.yaml SITE_REPO_ROOT

Exit 0 when every cited file checks out, 1 with one line per problem otherwise. Reads files only.
"""
from __future__ import annotations

import hashlib
import os
import sys

import yaml

from . import models as ml


def check(values: dict, root: str) -> list[str]:
    lc_raw = (values or {}).get("modelLifecycle") or {}
    lc = ml.parse(lc_raw)
    problems = []
    root_real = os.path.realpath(root)
    for e in lc.catalog:
        p = e.promotion or {}
        ev = p.get("evidence")
        if not ev:
            continue
        if not isinstance(ev, list):
            problems.append(f"{e.id}: promotion evidence is not a list of verdict files")
            continue
        aliases = [p["alias"]] if p.get("alias") else list(p.get("aliases") or [])
        for x in ev:
            path = str((x or {}).get("path", ""))
            where = f"{e.id}: {path or '(no path)'}"
            full = os.path.realpath(os.path.join(root_real, path))
            if not path or os.path.isabs(path) or not full.startswith(root_real + os.sep):
                problems.append(f"{where}: the path must be relative and inside the site repo")
                continue
            if not os.path.isfile(full):
                problems.append(f"{where}: not committed")
                continue
            with open(full, "rb") as fh:
                raw = fh.read()
            if hashlib.sha256(raw).hexdigest() != str(x.get("sha256", "")):
                problems.append(f"{where}: sha256 does not match the promotion record")
                continue
            try:
                v = ml.parse_verdict(raw.decode("utf-8"), path)
            except (UnicodeDecodeError, ml.LifecycleError) as err:
                problems.append(f"{where}: not a verdict record ({err})")
                continue
            if v.verdict != "pass":
                problems.append(f"{where}: the file says {v.verdict}, the record says pass")
            if v.candidate.get("model") != e.model:
                problems.append(f"{where}: the file is about {v.candidate.get('model')}, not {e.model}")
            if aliases and v.alias not in aliases:
                problems.append(f"{where}: the file decides {v.alias}, not {', '.join(aliases)}")
            if str(x.get("runId", "")) != v.run_id:
                problems.append(f"{where}: the file is run {v.run_id}, the record says {x.get('runId')}")
            if p.get("class") and v.klass != p["class"]:
                problems.append(f"{where}: the file is class {v.klass}, the record says {p['class']}")
    return problems


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if len(argv) != 2:
        print("usage: python -m app.verdict_check SITE_VALUES.yaml SITE_REPO_ROOT", file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8") as fh:
        values = yaml.safe_load(fh) or {}
    try:
        problems = check(values, argv[1])
    except ml.LifecycleError as err:
        print(f"modelLifecycle: {err}")
        return 1
    for p in problems:
        print(p)
    if not problems:
        n = sum(len((e.get("promotion") or {}).get("evidence") or []) for e in ((values.get("modelLifecycle") or {}).get("catalog") or []))
        print(f"ok: {n} cited verdict file(s) match their records")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

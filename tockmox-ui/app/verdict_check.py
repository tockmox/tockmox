# SPDX-License-Identifier: Apache-2.0
"""The CI half of the promotion gate (REQ-0048 AC-48.6, TM-0930).

check_promotions() in app/models.py checks the RECORD: enough passing runs, each with a path and a sha256.
It cannot open the files, so a hand-written record with an invented hash would pass it. This opens them:
every verdict file a promotion cites must exist in the site repo, hash to the recorded sha256, parse as a
REQ-0045 AC-45.9 record, say `pass`, and be about this model, this alias and this run.

It also opens what a verdict RESTS ON. A verdict's results[] is a list of {path, sha256}: the perf, smoke and quality
twins (app/results.py) behind it. Every one must exist in the site repo and hash to the recorded sha256, so a twin
edited after the verdict was written turns this red. That is checked for every verdict file under the verdicts
directory (modelLifecycle.verdictsRepoPath, default evals/verdicts), cited by a promotion yet or not: an edit made
before the promotion PR is the cheap time to catch it. A bare-path results[] entry (the first form, which hashed
nothing) is accepted for one release and printed as a warning.

  python -m app.verdict_check SITE_VALUES.yaml SITE_REPO_ROOT

Exit 0 when everything checks out, 1 with one line per problem otherwise. Reads files only.
"""
from __future__ import annotations

import hashlib
import os
import sys

import yaml

from . import models as ml
from . import results as rs


def _read_inside(root_real: str, rel: str):
    """(bytes, "") of a repo-relative file, or (None, why). Refuses a path that leaves the repo, symlinks included."""
    full = os.path.realpath(os.path.join(root_real, rel))
    if not rel or os.path.isabs(rel) or not full.startswith(root_real + os.sep):
        return None, "the path must be relative and inside the site repo"
    if not os.path.isfile(full):
        return None, "not committed"
    with open(full, "rb") as fh:
        return fh.read(), ""


def check_results(v, root_real: str, where: str, problems: list, warnings: list) -> None:
    """Every twin a verdict cites exists, hashes to what the verdict recorded, and (when it is a capability-result/1)
    is well formed and about the candidate or the incumbent."""
    for w in v.warnings:
        warnings.append(f"{where}: {w}")
    for x in v.results:
        loc = f"{where}: result {x['path']}"
        raw, why = _read_inside(root_real, x["path"])
        if raw is None:
            problems.append(f"{loc}: {why}")
            continue
        if not x["sha256"]:
            continue                                  # legacy form: already warned, nothing to compare
        if hashlib.sha256(raw).hexdigest() != x["sha256"]:
            problems.append(f"{loc}: sha256 does not match the verdict (the file was changed after the verdict was written)")
            continue
        text = raw.decode("utf-8", "replace")
        if '"capability-result/1"' in text[:4096]:
            try:
                r = rs.parse(text, x["path"])
            except rs.ResultError as err:
                problems.append(f"{loc}: not a valid capability-result/1 ({err})")
                continue
            ours = {v.candidate.get("model"), v.incumbent.get("model")} - {None, ""}
            if r.model not in ours:
                problems.append(f"{loc}: the result is about {r.model}, not {' or '.join(sorted(ours))}")


def check_all(values: dict, root: str) -> tuple[list[str], list[str]]:
    """(problems, warnings). See the module doc."""
    lc_raw = (values or {}).get("modelLifecycle") or {}
    lc = ml.parse(lc_raw)
    problems, warnings = [], []
    root_real = os.path.realpath(root)
    checked = set()
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
            raw, why = _read_inside(root_real, path)
            if raw is None:
                problems.append(f"{where}: {why}")
                continue
            if hashlib.sha256(raw).hexdigest() != str(x.get("sha256", "")):
                problems.append(f"{where}: sha256 does not match the promotion record")
                continue
            try:
                v = ml.parse_verdict(raw.decode("utf-8"), path)
            except (UnicodeDecodeError, ml.LifecycleError) as err:
                problems.append(f"{where}: not a verdict record ({err})")
                continue
            checked.add(path)
            if v.verdict != "pass":
                problems.append(f"{where}: the file says {v.verdict}, the record says pass")
            if v.candidate.get("model") != e.model:
                problems.append(f"{where}: the file is about {v.candidate.get('model')}, not {e.model}")
            if aliases and v.alias not in aliases:
                problems.append(f"{where}: the file decides {v.alias}, not {', '.join(aliases)}")
            if str(x.get("runId", "")) != v.run_id:
                problems.append(f"{where}: the file is run {v.run_id}, the record says {x.get('runId')}")
            klass = x.get("class", p.get("class"))
            if klass and v.klass != klass:
                problems.append(f"{where}: the file is class {v.klass}, the record says {klass}")
            pl = p.get("placement")
            if pl and v.candidate.get("model") == v.incumbent.get("model"):
                if v.placement != {"from_node": pl.get("from_node"), "to_node": pl.get("to_node")}:
                    problems.append(f"{where}: the file does not name the move the record says ({pl.get('from_node')} to {pl.get('to_node')})")
            check_results(v, root_real, where, problems, warnings)
    # every other verdict file: what it rests on must still hash to what it says
    vdir = str(lc_raw.get("verdictsRepoPath", "evals/verdicts")).strip("/")
    base = os.path.join(root_real, vdir)
    if os.path.isdir(base) and os.path.realpath(base).startswith(root_real + os.sep):
        for fn in sorted(os.listdir(base)):
            rel = f"{vdir}/{fn}"
            if not fn.endswith(".json") or rel in checked:
                continue
            raw, why = _read_inside(root_real, rel)
            if raw is None:
                problems.append(f"{rel}: {why}")
                continue
            try:
                v = ml.parse_verdict(raw.decode("utf-8"), rel)
            except (UnicodeDecodeError, ml.LifecycleError) as err:
                problems.append(f"{rel}: not a verdict record ({err}): a verdict that cannot be read could be the fail that resets a count")
                continue
            check_results(v, root_real, rel, problems, warnings)
    return problems, warnings


def check(values: dict, root: str) -> list[str]:
    return check_all(values, root)[0]


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if len(argv) != 2:
        print("usage: python -m app.verdict_check SITE_VALUES.yaml SITE_REPO_ROOT", file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8") as fh:
        values = yaml.safe_load(fh) or {}
    try:
        problems, warnings = check_all(values, argv[1])
    except ml.LifecycleError as err:
        print(f"modelLifecycle: {err}")
        return 1
    for w in warnings:
        print(f"warning: {w}")
    for p in problems:
        print(p)
    if not problems:
        n = sum(len((e.get("promotion") or {}).get("evidence") or []) for e in ((values.get("modelLifecycle") or {}).get("catalog") or []))
        print(f"ok: {n} cited verdict file(s) match their records")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

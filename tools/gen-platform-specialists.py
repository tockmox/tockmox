#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Write the /platform catalog's specialists field from the specialist roles file.

  python3 tools/gen-platform-specialists.py ROLES.yaml [CATALOG.yaml]          rewrite the catalog in place
  python3 tools/gen-platform-specialists.py --check ROLES.yaml [CATALOG.yaml]  exit 1 if the catalog is not what
                                                                              ROLES.yaml would make it (drift)

ROLES.yaml is roles/platform-roles.yaml from the specialists repository: which specialists (the agents that do the
work) serve each accountable role, and how built each one is. The catalog stays the source for what the page shows
(R28: "the UI catalog stays primary for display"); this script owns exactly two keys per role and one at the top:

  agentRole:   the role's id in the roles file (the Service Desk names roles by it), matched by role title
  specialists: [{id, state}] with state built | specced | proposed, in the roles file's order
  specialistsSource: {file, sha256} at the top: the canonical sha256 of the roles file this was generated from, the
               same hash the specialist host publishes at /v1/index, so the page can say when its copy is older

Every other line, comment and order in the catalog is left exactly as it was. A role title in the roles file that
names no catalog role, or a catalog role the roles file does not name, is an error: the two lists are one roster.
Stdlib plus PyYAML, macOS and Linux.
"""
import hashlib
import json
import os
import re
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CATALOG = os.path.join(HERE, os.pardir, "tockmox-ui", "app", "platform_catalog.yaml")
MARK = "# generated: tools/gen-platform-specialists.py"
STATES = ("built", "specced", "proposed")
ID_LINE = re.compile(r"^(?P<ind>\s*)(?P<dash>- )?id: (?P<id>[a-z0-9][a-z0-9-]*)\s*$")
OWNED = re.compile(r"^\s*(agentRole|specialists):")
TOP_OWNED = re.compile(r"^specialistsSource:")


class GenError(ValueError):
    pass


def roles_sha(doc):
    """The specialist index's hash: sha256 of canonical JSON (tools/specialist_render.py canon)."""
    text = json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _flow(specs):
    return "[" + ", ".join("{id: %s, state: %s}" % (s["id"], s["state"]) for s in specs) + "]"


def generate(roles_text, catalog_text):
    roles = yaml.safe_load(roles_text)
    cat = yaml.safe_load(catalog_text)
    if not (isinstance(roles, dict) and isinstance(roles.get("roles"), list)):
        raise GenError("the roles file has no roles list")
    by_title = {}
    for r in roles["roles"]:
        specs = []
        for s in r.get("specialists") or []:
            sid, st = str((s or {}).get("id", "")), (s or {}).get("state")
            if not re.fullmatch(r"[a-z][a-z0-9-]{1,47}", sid) or st not in STATES:
                raise GenError(f"roles file: {r.get('id')}: specialist {s!r} needs an id and a state in {STATES}")
            specs.append({"id": sid, "state": st})
        by_title[str(r.get("title"))] = {"role": str(r["id"]), "specialists": specs}
    names = {}
    for t in cat.get("teams") or []:
        for a in [t["lead"]] + list(t.get("members") or []):
            if not (isinstance(a, dict) and a.get("id") and a.get("name")):
                raise GenError(f"a catalog role needs an id and a name: {a!r}"[:200])
            names[a["id"]] = a["name"]
    missing = sorted(set(by_title) - set(names.values()))
    extra = sorted(n for n in names.values() if n not in by_title)
    if missing or extra:
        raise GenError("the roles file and the catalog are not one roster: "
                       + "; ".join(x for x in (f"no catalog role titled {', '.join(missing)}" if missing else "",
                                               f"no roles-file role titled {', '.join(extra)}" if extra else "") if x))
    want = {aid: by_title[name] for aid, name in names.items()}

    lines = catalog_text.splitlines(keepends=True)
    out, i, done = [], 0, set()
    while i < len(lines):
        line = lines[i]
        if TOP_OWNED.match(line):
            i += 1
            continue
        m = ID_LINE.match(line)
        out.append(line)
        i += 1
        if line.startswith("version:") and "_top" not in done:
            out.append(f"specialistsSource: {{file: roles/platform-roles.yaml, sha256: {roles_sha(roles)}}}   {MARK}\n")
            done.add("_top")
        if not m or m.group("id") not in want or m.group("id") in done:
            continue
        ind = m.group("ind") + ("  " if m.group("dash") else "")
        # the role's own keys follow at `ind`; drop what this script wrote before, keep everything else
        # a team can share an id with a role ("change"): the role is the block whose name line is the role's title
        nm = re.match(r"^\s*name:\s*(.+?)\s*$", lines[i]) if i < len(lines) else None
        if nm and lines[i].startswith(ind + "name:") and yaml.safe_load(nm.group(1)) == names[m.group("id")]:
            out.append(lines[i])
            i += 1
            while i < len(lines) and lines[i].startswith(ind) and OWNED.match(lines[i]) \
                    and not lines[i].startswith(ind + " "):
                i += 1
            w = want[m.group("id")]
            out.append(f"{ind}agentRole: {w['role']}   {MARK}\n")
            out.append(f"{ind}specialists: {_flow(w['specialists'])}\n")
            done.add(m.group("id"))
    left = sorted(set(want) - done)
    if left:
        raise GenError(f"could not place the field for {', '.join(left)}: each role's id line must be followed by its name line")
    if "_top" not in done:
        raise GenError("the catalog has no top-level version line to put specialistsSource after")
    text = "".join(out)
    check = yaml.safe_load(text)          # what was written must read back as the catalog plus the new keys
    for t in check["teams"]:
        for a in [t["lead"]] + list(t.get("members") or []):
            if a.get("agentRole") != want[a["id"]]["role"] or a.get("specialists") != want[a["id"]]["specialists"]:
                raise GenError(f"{a['id']}: the written field does not read back as generated")
    return text


def main(argv):
    args = [a for a in argv[1:] if a != "--check"]
    if not args or len(args) > 2:
        print(__doc__)
        return 2
    roles_path = args[0]
    cat_path = args[1] if len(args) == 2 else DEFAULT_CATALOG
    with open(roles_path, encoding="utf-8") as fh:
        roles_text = fh.read()
    with open(cat_path, encoding="utf-8") as fh:
        cur = fh.read()
    try:
        new = generate(roles_text, cur)
    except GenError as e:
        print(f"refused: {e}")
        return 1
    if "--check" in argv:
        if new != cur:
            print(f"stale: {cat_path} is not what {roles_path} makes it; run tools/gen-platform-specialists.py {roles_path}")
            return 1
        print("ok: the catalog's specialists field matches the roles file")
        return 0
    if new != cur:
        with open(cat_path, "w", encoding="utf-8") as fh:
            fh.write(new)
        print(f"wrote {cat_path}")
    else:
        print("unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

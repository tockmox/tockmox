# SPDX-License-Identifier: Apache-2.0
"""The blueprint entries the docs give a reader to paste bind every application they create, in the shipped shape
(tools/check-sso-bindings.sh): each binding is identified by application and group, and its group is an
`authentik_core.group` entry in the same block, reached with !KeyOf. A block that creates an application and no
binding is the gap these pages used to leave."""
import os
import re

import pytest
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAGES = ["docs/administration/argocd.md", "docs/administration/adding-an-application.md"]


class L(yaml.SafeLoader):
    pass


for _t in ("!Env", "!Find", "!KeyOf", "!Format", "!Context"):
    L.add_constructor(_t, lambda loader, node, t=_t: (t, loader.construct_sequence(node) if isinstance(node, yaml.SequenceNode) else loader.construct_scalar(node)))


def blocks(page):
    text = open(os.path.join(ROOT, page)).read()
    return [b for b in re.findall(r"```yaml\n(.*?)```", text, re.S) if "authentik_policies.policybinding" in b
            or "authentik_core.application" in b]


def entries(block):
    doc = yaml.load(block, Loader=L)
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
        return [e for body in doc["data"].values() for e in (yaml.load(body, Loader=L) or {}).get("entries") or []]
    return []


def problems(es):
    out = []
    groups = {e.get("id") for e in es if e.get("model") == "authentik_core.group"}
    apps = {e.get("id") for e in es if e.get("model") == "authentik_core.application"}
    binds = [e for e in es if e.get("model") == "authentik_policies.policybinding"]
    for b in binds:
        ids = b.get("identifiers") or {}
        if set(ids) != {"target", "group"}:
            out.append(f"binding identified by {sorted(ids)}, not target and group")
        if ids.get("group", (None, None))[0] != "!KeyOf" or ids["group"][1] not in groups:
            out.append(f"binding group {ids.get('group')} is not a group entry in the same block")
    for a in apps:
        if not any((b.get("identifiers") or {}).get("target") == ("!KeyOf", a) and b.get("state") == "present" for b in binds):
            out.append(f"application {a} has no present binding")
    return out


@pytest.mark.parametrize("page", PAGES)
def test_every_pasteable_blueprint_block_binds_what_it_creates(page):
    bs = blocks(page)
    assert bs, f"{page} has no blueprint block"
    for b in bs:
        es = entries(b)
        assert es, b[:80]
        assert problems(es) == [], b[:200]


def test_the_check_goes_red_on_an_unbound_application_and_an_order_identifier():
    app = {"model": "authentik_core.application", "id": "app-x", "identifiers": {"slug": "x"}}
    assert problems([app]) == ["application app-x has no present binding"]
    grp = {"model": "authentik_core.group", "id": "g", "identifiers": {"name": "tockmox-admins"}}
    by_order = {"model": "authentik_policies.policybinding", "state": "present",
                "identifiers": {"target": ("!KeyOf", "app-x"), "order": 0}}
    assert problems([app, grp, by_order])
    find = {"model": "authentik_policies.policybinding", "state": "present",
            "identifiers": {"target": ("!KeyOf", "app-x"), "group": ("!Find", ["authentik_core.group", ["name", "x"]])}}
    assert problems([app, grp, find])

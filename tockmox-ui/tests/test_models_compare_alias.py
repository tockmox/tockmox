# SPDX-License-Identifier: Apache-2.0
"""The Compare page (/models/v/<runId>) and the Alias page (/models/a/<alias>) with its revert: read only, every action
renders a change for a person to commit."""
import html

from app import models as ml
from app import nodes as nm
from tests.models_support import (inventory_doc, lifecycle_doc, models_client, sha, verdict_record)

OLD, NEW = "example-org/Example-27B-4bit", "example-org/Example-30B-4bit"
REV = "4" * 40
TWIN = {"path": "evals/results/beta/chat-2026-10-07.json", "sha256": sha("twin")}

FULL = {"label": "better", "n": 40, "discordant": {"b": 12, "c": 2}, "method": "sign-test+bootstrap", "interval": [0.1, 0.4],
        "margin": 0.05, "min_effect": 0.05, "screening": False, "control": {"passed": False, "cases": 5},
        "engine": {"id": "mlx-lm", "version": "0.32.2", "flags": ""}, "node": "beta", "sampling": {"temperature": 0.2, "seed": 7},
        "eval_set": {"id": "chat-set", "version": "v1", "sha256": "e" * 64}}


def write(tmp_path, *records):
    d = tmp_path / "verdicts"
    d.mkdir(exist_ok=True)
    for i, t in enumerate(records):
        (d / f"{i:03d}.json").write_text(t)
    return str(d)


def client(tmp_path, *records, lifecycle=None, inventory=None, groups=None):
    vdir = write(tmp_path, *records)
    return models_client(tmp_path, lifecycle=lifecycle, inventory=inventory, groups=groups,
                         extra=lambda doc: doc["modelLifecycle"].update(verdictsDir=vdir))


def rec(run="r1", extras=None, verdict="pass", **kw):
    return verdict_record(NEW, "local-medium", verdict=verdict, run=run, incumbent=OLD, results=[TWIN], extras=extras, **kw)


def test_a_better_verdict_shows_the_label_counts_and_interval(tmp_path):
    c, u = client(tmp_path, rec(extras=FULL))
    r = c.get("/models/v/r1")
    t = html.unescape(r.text)
    assert r.status_code == 200
    assert "Better" in t and "local-medium" in t and NEW in t and f"against <code>{OLD}</code>" in t
    for needle in (">40<", ">12<", ">2<", ">26<", "sign-test+bootstrap", "+0.100 to +0.400", "margin 0.050, min effect 0.050",
                   "0.01294", "mlx-lm 0.32.2", "beta", "temperature 0.2", "e" * 64, TWIN["path"], TWIN["sha256"]):
        assert needle in t, needle
    assert "Failed as it should" in t and "Screening" not in t
    assert "Counted" in t and "one of the passing comparisons" in t


def test_a_screening_verdict_shows_the_banner(tmp_path):
    ex = {**FULL, "label": "same", "n": 12, "discordant": {"b": 3, "c": 2}, "screening": True}
    c, u = client(tmp_path, rec(extras=ex))
    t = c.get("/models/v/r1").text
    assert "fewer than 30 cases, cannot say Better" in t and "Same" in t


def test_a_verdict_without_extras_renders_with_not_recorded(tmp_path):
    c, u = client(tmp_path, rec())
    r = c.get("/models/v/r1")
    assert r.status_code == 200
    t = r.text
    assert t.count("not recorded") >= 6 and "Pass" in t
    assert "no known-bad control" in t                      # the missing control is an exception, not a blank
    assert "fewer than 30 cases" not in t


def test_a_verdict_that_did_not_count_says_why(tmp_path):
    ex = {**FULL, "control": {"passed": True, "cases": 5}}
    c, u = client(tmp_path, rec("r1", extras=ex), rec("r2", extras={**FULL, "sampling": {"seed": 8}}))
    t = c.get("/models/v/r1").text
    assert "Not counted" in t and "known-bad control passed too" in t and "The known-bad control passed too" in t
    assert "Counted" in c.get("/models/v/r2").text
    # the same evidence twice counts once: r3 repeats r2's build, set, sampling, engine and node
    c, u = client(tmp_path, rec("r2", extras={**FULL, "sampling": {"seed": 8}}), rec("r3", extras={**FULL, "sampling": {"seed": 8}}),
                  rec("r4", verdict="fail", extras={"label": "worse"}))
    assert "the same evidence twice, counted once" in c.get("/models/v/r3").text
    assert "Not counted" in c.get("/models/v/r4").text


def test_an_unknown_run_id_is_a_404_page(tmp_path):
    c, u = client(tmp_path, rec())
    r = c.get("/models/v/nope")
    assert r.status_code == 404 and "Not found" in r.text and "no comparison with that run id" in r.text
    c2, u2 = models_client(tmp_path)                        # no verdict directory at all
    assert c2.get("/models/v/r1").status_code == 404


def promoted_world():
    lc = ml.parse({**lifecycle_doc(), "catalog": lifecycle_doc()["catalog"] + [
        {"id": "example-30b", "model": NEW, "stage": "candidate", "sizeGiB": 17.0,
         "source": {"kind": "huggingface", "ref": NEW, "revision": REV}}]})
    inv = nm.parse_inventory(inventory_doc())
    inv.routes.append(nm.Route("local-medium-next", "alpha", "mlx-lm-8080", NEW, "chat", "", {}, {}, 17.0))
    vs = [ml.parse_verdict(rec(f"p{i}"), f"evals/verdicts/{i}.json") for i in range(3)]
    new_lc, new_inv, _ = ml.promote("local-medium-next", vs, lc, inv)
    return ml.to_doc(new_lc), nm.inventory_to_doc(new_inv)


def test_the_alias_page_with_a_previous_route_offers_the_revert(tmp_path):
    lcd, invd = promoted_world()
    c, u = client(tmp_path, lifecycle=lcd, inventory=invd)
    r = c.get("/models/a/local-medium")
    t = r.text
    assert r.status_code == 200 and NEW in t and "Promotion record" in t and "What it served before" in t
    assert f'<code>{OLD}</code>' in t and 'action="/models/a/local-medium/revert"' in t and 'name="reason"' in t
    assert f'name="csrf" value="{u.csrf}"' in t
    assert 'href="/models/v/p0"' in t                       # the evidence links to its comparison


def test_the_alias_page_without_a_previous_route_says_why(tmp_path):
    c, u = client(tmp_path)
    t = html.unescape(c.get("/models/a/local-medium").text)
    assert 'action="/models/a/local-medium/revert"' not in t
    assert "Unavailable" in t and "no promotion for local-medium on record" in t
    assert c.get("/models/a/nope").status_code == 404
    assert c.get("/models/a/local-medium-next").status_code == 404


def test_a_revert_renders_the_change(tmp_path):
    lcd, invd = promoted_world()
    c, u = client(tmp_path, lifecycle=lcd, inventory=invd)
    r = c.post("/models/a/local-medium/revert", data={"csrf": u.csrf, "reason": "tool calls broke"})
    assert r.status_code == 200
    t = html.unescape(r.text)
    assert "Revert local-medium" in t and "Nothing has changed yet" in t
    assert f"local-medium goes back to {OLD}" in t and f"{NEW} is marked rejected: tool calls broke" in t
    assert f"model: {OLD}" in t.split("What the production gateway will get")[1]
    assert "stage: rejected" in t.split("The values blocks")[1]
    y = c.post("/models/a/local-medium/revert", data={"csrf": u.csrf, "reason": "tool calls broke", "fmt": "yaml"})
    assert y.headers["content-type"].startswith("application/yaml") and "rejected" in y.text


def test_a_revert_without_a_reason_shows_the_error_on_the_page(tmp_path):
    lcd, invd = promoted_world()
    c, u = client(tmp_path, lifecycle=lcd, inventory=invd)
    r = c.post("/models/a/local-medium/revert", data={"csrf": u.csrf, "reason": "   "})
    assert r.status_code == 400 and "Not reverted" in r.text and "say why" in r.text and 'name="reason"' in r.text
    r = c.post("/models/a/local-medium/revert", data={"csrf": "wrong", "reason": "x"})
    assert r.status_code == 400
    # no previous route: the refusal renders, never a 500
    (tmp_path / "b").mkdir()
    c2, u2 = client(tmp_path / "b")
    r = c2.post("/models/a/local-medium/revert", data={"csrf": u2.csrf, "reason": "x"})
    assert r.status_code == 400 and "Not reverted" in r.text
    assert c2.post("/models/a/nope/revert", data={"csrf": u2.csrf, "reason": "x"}).status_code == 404


def test_a_non_admin_is_refused(tmp_path):
    c, u = client(tmp_path, rec(), groups=["tockmox-users"])
    assert c.get("/models/v/r1").status_code == 403
    assert c.get("/models/a/local-medium").status_code == 403
    assert c.post("/models/a/local-medium/revert", data={"csrf": u.csrf, "reason": "x"}).status_code == 403


def test_existing_pages_link_to_the_new_ones(tmp_path):
    lcd, invd = promoted_world()
    c, u = client(tmp_path, lifecycle=lcd, inventory=invd)
    assert 'href="/models/a/local-medium"' in c.get("/models").text
    assert 'href="/models/v/p0"' in c.get("/models/m/example-30b").text

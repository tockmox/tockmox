# SPDX-License-Identifier: Apache-2.0
"""The feature registry, the contributions beyond pages, and the release markers (app/registry.py, app/features.yaml,
app/feature_pages.py; specs/tockmox-ui/SPEC.md sections 9 and 10 in the planning repo).

  registry     app/features.yaml loads; a key it does not name, a stability it does not know, a since that is not a
               release version are refused when the console starts
  contributes  stack, health, help and retireTile parse; a field the format does not name is refused; a health input
               with no stack part is refused; the add-on manifest's example block (addons/README.md) parses here too
  on and off   a feature's stack part, its help page and its retired tile are there while it is on and gone when it is
               off, not greyed out; a firing health alert lands on its part and turns the health pill red
  markers      Preview shows on an untagged build for an item whose release is not in the bundled CHANGELOG, and never
               on a tagged build; Private comes from origin: private on a feature or an app; one word per item
  experimental Platform > Capabilities lists experimental features in their own section with the word Experimental and
               their on or off state; a stable one stays in Console features; the word shows on the feature's own
               pages; an unknown stability is refused

Run from tockmox-ui/: python -m pytest tests/test_feature_registry.py
"""
import re
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config as cfgmod  # noqa: E402
from app import feature_pages as fp  # noqa: E402
from app import registry as rg  # noqa: E402
from tests.test_feature_pages import Api, client, feature, main_html, rail, top, world  # noqa: E402,F401

UNTAGGED = "# Changelog\n\n## [Unreleased]\n\n- new\n\n## [0.8.6] ... 2026-11-17\n\n- fix\n"
TAGGED = "# Changelog\n\n## [0.9.0] ... 2026-12-08\n\n- new\n\n## [0.8.6] ... 2026-11-17\n\n- fix\n"


# ---------------------------------------------------------------- the registry

def test_the_shipped_registry_loads_and_names_the_console_features():
    r = rg.load()
    assert set(r.features) >= {"platform", "posture", "scanning", "agents"}
    assert all(e.stability in rg.STABILITY for e in r.features.values())
    assert r.get("platform").name == "Platform Management"


@pytest.mark.parametrize("doc, words", [
    ({"version": 2, "features": {}}, "version must be 1"),
    ({"version": 1, "features": {}, "extra": 1}, "extra is not a key"),
    ({"version": 1, "features": {"x": {"name": "X", "stability": "stable", "colour": "red"}}}, "colour is not a key"),
    ({"version": 1, "features": {"x": {"name": "X", "stability": "beta"}}}, "stability must be one of"),
    ({"version": 1, "features": {"x": {"name": "X", "stability": "stable", "since": "0.9"}}}, "since must be a release version"),
    ({"version": 1, "features": {"Bad_Id": {"name": "X", "stability": "stable"}}}, "lowercase letters"),
    ({"version": 1, "features": {}, "tiles": {"chat": {"since": "0.9.0", "colour": 1}}}, "takes since only"),
])
def test_the_registry_refuses_what_it_does_not_name(doc, words):
    with pytest.raises(rg.RegistryError, match=re.escape(words)):
        rg.parse(doc)


# ---------------------------------------------------------------- the build and the markers

def test_a_build_is_tagged_when_its_changelog_opens_on_a_release():
    from app.notes import parse_changelog
    assert rg.Build.from_notes(parse_changelog(TAGGED)).tagged
    b = rg.Build.from_notes(parse_changelog(UNTAGGED))
    assert not b.tagged and b.released == frozenset({"0.8.6"})
    assert not rg.Build.from_notes({}).tagged                        # no CHANGELOG never claims to be a release


def test_preview_shows_only_on_an_untagged_build_for_an_unreleased_item():
    from app.notes import parse_changelog
    untagged, tagged = rg.Build.from_notes(parse_changelog(UNTAGGED)), rg.Build.from_notes(parse_changelog(TAGGED))
    assert untagged.preview("0.9.0") and not untagged.preview("0.8.6") and not untagged.preview(None)
    assert not tagged.preview("0.9.0") and not tagged.preview("0.10.0")    # never on a tagged build


def test_one_word_per_item_private_then_preview_then_experimental():
    from app.notes import parse_changelog
    b = rg.Build.from_notes(parse_changelog(UNTAGGED))
    assert rg.marker(origin="private", since="0.9.0", stability="experimental", build=b) == "Private"
    assert rg.marker(since="0.9.0", stability="experimental", build=b) == "Preview"
    assert rg.marker(since="0.8.6", stability="experimental", build=b) == "Experimental"
    assert rg.marker(since="0.8.6", stability="stable", build=b) is None


# ---------------------------------------------------------------- contributes beyond pages

def test_stack_health_help_and_retire_parse():
    c = fp.parse_contributes("x", {"stack": {"band": "platform", "part": " Delivery ", "namespaces": ["site-x"],
                                             "alerts": ["DeliveryDown"]},
                                   "health": {"alerts": ["DeliveryLate*"]},
                                   "help": "docs/administration/feature-pages.md", "retireTile": "chat"})
    assert c.pages == () and not c.section and c.rail_section is None
    assert c.stack == fp.StackPart("platform", "Delivery", ("site-x",), ("DeliveryDown", "DeliveryLate*"))
    assert (c.help, c.retire_tile) == ("administration/feature-pages.md", "chat")


@pytest.mark.parametrize("raw, words", [
    ({"stack": {"band": "platform", "part": "P", "alerts": ["A"]}, "script": "x.js"}, "script is not a contribution"),
    ({"health": {"alerts": ["A"]}}, "health needs a stack part"),
    ({"stack": {"band": "platform", "part": "P"}}, "would only ever read Unknown"),
    ({"stack": {"band": "platform", "part": "P", "alerts": ["A"], "goto": {}}}, "stack takes band, part"),
    ({"help": "https://example.com/x.md"}, "help must be a docs/*.md page"),
    ({"help": "docs/../etc/passwd.md"}, "help must be a docs/*.md page"),
    ({"retireTile": "Chat Tile"}, "retireTile must be the id"),
    ({}, "names no contribution"),
])
def test_contributions_refuse_what_the_format_does_not_name(raw, words):
    with pytest.raises(ValueError, match=re.escape(words)):
        fp.parse_contributes("x", raw)


def test_the_add_on_manifest_example_is_a_block_the_console_parses():
    """addons/README.md's adminUi.contributes example is held by tools/check-addon-manifest.sh; the console must read
    the same shape, or the two formats have drifted."""
    readme = (Path(__file__).resolve().parents[2] / "addons" / "README.md").read_text()
    block = next(b for b in re.findall(r"```yaml\n(.*?)```", readme, re.S) if "contributes:" in b)
    c = fp.parse_contributes("posture-probe", yaml.safe_load(block)["adminUi"]["contributes"])
    assert c.rail_section == "platform" and c.stack is not None and c.help and c.retire_tile


# ---------------------------------------------------------------- on and off, through the console

def other(**over):
    f = {"enabled": True, "name": "Delivery checks",
         "contributes": {"stack": {"band": "platform", "part": "Delivery checks", "alerts": ["DeliveryDown"]},
                         "health": {"alerts": ["DeliveryLate"]},
                         "help": "docs/administration/feature-pages.md", "retireTile": "chat"}}
    f.update(over)
    return f


def test_a_stack_part_is_on_status_while_the_feature_is_on_and_gone_when_off(tmp_path, world):
    c = client(tmp_path, world, feats={"checks": other()})
    r = c.get("/status/feature-checks")
    assert r.status_code == 200 and "Delivery checks" in r.text
    off = client(tmp_path, world, feats={"checks": other(enabled=False)})
    assert off.get("/status/feature-checks").status_code == 404
    assert "Delivery checks" not in off.get("/status").text


def test_a_firing_health_input_lands_on_the_part_and_turns_the_pill_red(tmp_path, world):
    world.alerts = world.alerts + [{"labels": {"alertname": "DeliveryLate", "severity": "critical"}, "annotations": {}}]
    c = client(tmp_path, world, feats={"checks": other()})
    assert "DeliveryLate" in main_html(c.get("/status/feature-checks").text)
    assert re.search(r'class="hpill st-critical"', c.get("/").text)
    off = client(tmp_path, world, feats={"checks": other(enabled=False)})
    assert off.get("/status/feature-checks").status_code == 404           # off: no part, no say in the pill


def test_a_retired_tile_leaves_home_while_the_feature_is_on(tmp_path, world):
    on = client(tmp_path, world, feats={"checks": other()}).get("/").text
    assert 'href="/chat/"' not in on and 'href="/grafana/"' in on
    off = client(tmp_path, world, feats={"checks": other(enabled=False)}).get("/").text
    assert 'href="/chat/"' in off


def test_a_feature_names_its_own_help_page_for_its_pages(tmp_path, world):
    from app import nav
    assert nav.help_for("/f/checks/x", fp.help_pages([cfgmod.Feature("checks", "C", True)],
                                                     {"checks": fp.parse_contributes("checks", other()["contributes"])})) \
        == "administration/feature-pages.md"
    assert nav.help_for("/f/checks/x", {}) == "administration/feature-pages.md"    # the generic page otherwise
    f = feature(contributes={"section": True, "pages": [{"id": "flow", "title": "Flow"}],
                             "help": "docs/administration/posture-probe.md"})
    t = client(tmp_path, world, feats={"delivery": f}).get("/f/delivery/flow").text
    assert "posture-probe" in t


# ---------------------------------------------------------------- Preview and Private, through the console

def reg_file(tmp_path, since="0.9.0", tiles=None):
    p = tmp_path / "features.yaml"
    doc = yaml.safe_load(Path(rg.DEFAULT_REGISTRY).read_text())
    doc["features"]["delivery"] = {"name": "Delivery", "stability": "stable", "since": since}
    doc["tiles"] = tiles or {}
    p.write_text(yaml.safe_dump(doc))
    return str(p)


def preview_client(tmp_path, world, changelog, feats=None, tiles=None, apps_origin=None):
    from fastapi.testclient import TestClient
    from app.auth import Sessions
    from app.main import Transports, create_app
    import httpx
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["sources"]["kubernetes"].update({"url": "https://kube.test", "tokenFile": "/nonexistent", "caFile": "/nonexistent"})
    doc["sources"]["timeoutSeconds"] = 1
    if apps_origin:
        for a in doc["apps"]:
            if a["id"] in apps_origin:
                a["origin"] = apps_origin[a["id"]]
    f = feature()
    f.pop("origin")
    doc["features"] = dict(doc["features"], **(feats or {"delivery": f}))
    s = cfgmod.parse(doc)
    (tmp_path / "CHANGELOG.md").write_text(changelog)
    api = Api()
    tp = Transports(kube=httpx.MockTransport(world.handler("kube")), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")), features=httpx.MockTransport(api.handler))
    c = TestClient(create_app(s, tp, notes_path=str(tmp_path / "CHANGELOG.md"), registry_path=reg_file(tmp_path, tiles=tiles)),
                   follow_redirects=False)
    sess = Sessions(s.session_secret, 3600, s.admin_group, False)
    c.cookies.set(sess.session_cookie, sess.issue("a", "Someone", ["tockmox-admins"]))
    return c


def test_preview_marks_an_unreleased_feature_on_an_untagged_build(tmp_path, world):
    t = preview_client(tmp_path, world, UNTAGGED).get("/f/delivery/flow").text
    assert re.search(r'Delivery<span class="fmark"[^>]*>Preview</span>', top(t))
    assert re.search(r'Flow<span class="fmark"[^>]*>Preview</span>', rail(t))
    assert re.search(r'<span class="fmark"[^>]*>Preview</span>', main_html(t))


def test_preview_never_shows_on_a_tagged_build(tmp_path, world):
    t = preview_client(tmp_path, world, TAGGED).get("/f/delivery/flow").text
    assert ">Preview<" not in t


def test_tiles_carry_private_from_the_app_and_preview_from_the_registry(tmp_path, world):
    t = preview_client(tmp_path, world, UNTAGGED, tiles={"grafana": {"since": "0.9.0"}},
                       apps_origin={"chat": "private"}).get("/").text
    assert re.search(r'Chat<span class="fmark"[^>]*>Private</span>', t)
    assert re.search(r'Grafana<span class="fmark"[^>]*>Preview</span>', t)
    assert not re.search(r'Storage<span class="fmark"', t)
    tagged = preview_client(tmp_path, world, TAGGED, tiles={"grafana": {"since": "0.9.0"}}).get("/").text
    assert ">Preview<" not in tagged


def test_an_app_origin_other_than_private_is_refused(tmp_path, world):
    with pytest.raises(cfgmod.ConfigError, match="only marker an app may carry is private"):
        preview_client(tmp_path, world, UNTAGGED, apps_origin={"chat": "site"})


# ---------------------------------------------------------------- Experimental on Platform > Capabilities

def section(t, h2_id):
    m = re.search(rf'<h2 id="{h2_id}">.*?</table>', t, re.S)
    return m.group(0) if m else ""


def test_experimental_features_get_their_own_section_with_the_word_and_their_state(tmp_path, world):
    x = feature(stability="experimental")
    x.pop("origin")
    st = feature(name="Steady", stability="stable", contributes={"rail": {"section": "platform", "group": "Steady"},
                                                                    "pages": [{"id": "flow", "title": "Steady flow"}]})
    st.pop("origin")
    t = client(tmp_path, world, feats={"delivery": x, "steady": st}).get("/capabilities").text
    xs, cf = section(t, "experimental"), section(t, "console-features")
    assert "Delivery" in xs and '>Experimental</span>' in xs and "On" in xs
    assert "still maturing" in t
    assert "Platform Management" in xs and "Off" in xs        # the registry's experimental features, on or off
    assert "Steady" in cf and "Steady" not in xs and '>Experimental</span>' not in cf


def test_the_experimental_word_shows_on_the_features_own_pages(tmp_path, world):
    x = feature(stability="experimental")
    x.pop("origin")
    t = client(tmp_path, world, feats={"delivery": x}).get("/f/delivery/flow").text
    assert re.search(r'Delivery<span class="fmark"[^>]*>Experimental</span>', top(t))
    assert re.search(r'Flow<span class="fmark"[^>]*>Experimental</span>', rail(t))


def test_a_stable_feature_carries_no_word(tmp_path, world):
    s = feature(stability="stable")
    s.pop("origin")
    t = client(tmp_path, world, feats={"delivery": s}).get("/f/delivery/flow").text
    assert 'class="fmark"' not in top(t) + rail(t)


def test_an_unknown_stability_is_refused(tmp_path, world):
    with pytest.raises(cfgmod.ConfigError, match="stability must be one of"):
        client(tmp_path, world, feats={"delivery": feature(stability="beta")})

# SPDX-License-Identifier: Apache-2.0
"""TM-1014 and TM-1017: the fixes from the 0.8.0 testing pass on the reference site (2026-10-11).

  footer        the RUNNING Tockmox version, not the UI's own build number; a pill when newer exists
  heartbeat     TockmoxHeartbeat is an always-firing heartbeat: Alive, never a firing row
  status page   links Grafana directly
  home          the documentation, on the platform and on GitHub at the running release
  sign out      ends the identity provider's session (RP-initiated logout), never fails locally
  capabilities  what each capability is set to, and whether its layer deploys it

Run from tockmox-ui/: python -m pytest tests
"""
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import capabilities as capmod  # noqa: E402
from app import config  # noqa: E402
from tests.test_status_api import World, admin, app_obj, make_client  # noqa: E402,F401


@pytest.fixture
def world():
    w = World()
    w.apps = [app_obj("tockmox-platform", rev="v0.8.0", path="charts/tockmox-platform"),
              app_obj("tockmox-observability", rev="v0.8.0", path="charts/tockmox-observability"),
              app_obj("tockmox-ai", rev="v0.8.0", path="charts/tockmox-ai")]
    return w


def with_resources(w, name, resources):
    for a in w.apps:
        if a["metadata"]["name"] == name:
            a["status"]["resources"] = [{"kind": k, "name": n} for k, n in resources]


# ------------------------------------------------------------ footer

def test_footer_names_the_running_release_not_the_ui_build(tmp_path, world):
    r = admin(tmp_path, world).get("/")
    assert r.status_code == 200
    foot = r.text.split('<footer class="foot">', 1)[1]
    assert "Tockmox 0.8.0" in foot or "Tockmox v0.8.0" in foot
    assert "0.0.1-proto" not in foot


def test_footer_says_not_a_release_on_a_commit(tmp_path, world):
    for a in world.apps:
        a["spec"]["source"]["targetRevision"] = "e0614aebba454c77be43112b53e1adb4743793cc"
    foot = admin(tmp_path, world).get("/").text.split('<footer class="foot">', 1)[1]
    assert "e0614aebba45" in foot and "not a release" in foot


def test_footer_shows_no_version_to_the_signed_out(tmp_path, world):
    r = make_client(tmp_path, world).get("/recovery")
    assert r.status_code == 200
    assert not any(p == "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications" for _, _, p in world.requests)


# ------------------------------------------------------------ heartbeat

def test_tockmox_heartbeat_is_alive_not_a_firing_row(tmp_path, world):
    world.alerts = [{"labels": {"alertname": "Watchdog", "severity": "none"}, "annotations": {}},
                    {"labels": {"alertname": "TockmoxHeartbeat", "severity": "none"}, "annotations": {"summary": "self-check heartbeat"}},
                    {"labels": {"alertname": "KubePodNotReady", "severity": "warning"}, "annotations": {"summary": "x"}}]
    t = admin(tmp_path, world).get("/status").text
    rows = t.split("<tbody>")[-1]
    assert "TockmoxHeartbeat" not in rows.split("</tbody>")[0].replace("Alive", "")  # not a row in the firing table
    assert "<code>TockmoxHeartbeat</code> is firing, as it always should" in t
    assert "KubePodNotReady" in t
    assert "Active, not silenced, not inhibited: 1" in t


def test_the_alertmanager_verdict_ignores_tockmox_heartbeat(tmp_path, world):
    from app.sources import AlertmanagerSource, OK
    src = AlertmanagerSource("http://am", 1)
    st, why = src.evaluate([{"name": "Watchdog", "severity": "none"}, {"name": "TockmoxHeartbeat", "severity": "none"}])
    assert st == OK, why


# ------------------------------------------------------------ status page and home

def test_status_links_grafana_directly(tmp_path, world):
    t = admin(tmp_path, world).get("/status").text
    assert 'open <a href="https://grafana.int.example.com/"' in t
    assert "from <a href=\"/\">your apps</a>" not in t


def test_home_links_the_docs_on_the_platform_and_on_github_at_the_release(tmp_path, world):
    c = admin(tmp_path, world, tweak=lambda d: d["site"].update({"docsUrl": "https://docs.int.example.com"}))
    t = c.get("/").text
    assert 'href="https://docs.int.example.com/"' in t
    assert 'href="https://github.com/tockmox/tockmox/tree/v0.8.0/docs"' in t


def test_github_docs_fall_back_to_main_off_a_release(tmp_path, world):
    for a in world.apps:
        a["spec"]["source"]["targetRevision"] = "main"
    t = admin(tmp_path, world).get("/").text
    assert 'href="https://github.com/tockmox/tockmox/tree/main/docs"' in t


# ------------------------------------------------------------ sign out

def _oidc(end_session=True, down=False):
    def h(req: httpx.Request):
        if down:
            raise httpx.ConnectError("refused", request=req)
        d = {"issuer": "https://auth.int.example.com/application/o/tockmox-ui",
             "authorization_endpoint": "https://auth.int.example.com/application/o/authorize/",
             "token_endpoint": "https://auth.int.example.com/application/o/token/",
             "jwks_uri": "https://auth.int.example.com/application/o/tockmox-ui/jwks/"}
        if end_session:
            d["end_session_endpoint"] = "https://auth.int.example.com/application/o/tockmox-ui/end-session/"
        return httpx.Response(200, json=d)
    return httpx.MockTransport(h)


def _signed_in_with_oidc(tmp_path, world, transport, tweak=None):
    c = admin(tmp_path, world, tweak=tweak)
    c.app.state.oidc.transport = transport
    return c


def _csrf(c):
    t = c.get("/").text
    return t.split('name="csrf" value="', 1)[1].split('"', 1)[0]


def test_sign_out_ends_the_identity_providers_session(tmp_path, world):
    c = _signed_in_with_oidc(tmp_path, world, _oidc())
    r = c.post("/logout", data={"csrf": _csrf(c)})
    assert r.status_code == 303
    assert r.headers["location"].startswith("https://auth.int.example.com/application/o/tockmox-ui/end-session/?client_id=tockmox-ui")
    assert "post_logout_redirect_uri" not in r.headers["location"]
    assert c.get("/").status_code == 302          # and the local session is gone


def test_sign_out_names_the_return_page_only_when_configured(tmp_path, world):
    c = _signed_in_with_oidc(tmp_path, world, _oidc(), tweak=lambda d: d["oidc"].update(
        {"postLogoutRedirectUrl": "https://tockmox.int.example.com/"}))
    c.cookies.set("tockmox_ui_idt", "eyJ.hint.sig")
    r = c.post("/logout", data={"csrf": _csrf(c)})
    loc = r.headers["location"]
    assert "post_logout_redirect_uri=https%3A%2F%2Ftockmox.int.example.com" in loc
    assert "id_token_hint=eyJ.hint.sig" in loc
    assert 'tockmox_ui_idt=""' in r.headers.get("set-cookie", "") or "tockmox_ui_idt=;" in r.headers.get("set-cookie", "")


def test_sign_out_sends_no_return_page_without_the_hint(tmp_path, world):
    # Authentik refuses a post_logout_redirect_uri without id_token_hint, and refusing ends nothing:
    # with no stored token the UI asks only for the logout, which Authentik honours.
    c = _signed_in_with_oidc(tmp_path, world, _oidc(), tweak=lambda d: d["oidc"].update(
        {"postLogoutRedirectUrl": "https://tockmox.int.example.com/"}))
    r = c.post("/logout", data={"csrf": _csrf(c)})
    assert r.status_code == 303
    assert "post_logout_redirect_uri" not in r.headers["location"] and "id_token_hint" not in r.headers["location"]


def test_sign_out_form_may_redirect_to_the_issuer(tmp_path, world):
    # form-action governs a form's redirect too: 'self' alone made Sign out do nothing (round 2).
    csp = admin(tmp_path, world).get("/").headers["content-security-policy"]
    assert "form-action 'self' https://auth.int.example.com;" in csp
    assert "default-src 'self';" in csp and "frame-ancestors 'none'" in csp


def test_sign_out_kept_local_keeps_form_action_self(tmp_path, world):
    csp = admin(tmp_path, world, tweak=lambda d: d["oidc"].update({"endSession": False})).get("/").headers["content-security-policy"]
    assert "form-action 'self';" in csp


def test_sign_out_still_works_locally_when_the_issuer_is_down(tmp_path, world):
    c = _signed_in_with_oidc(tmp_path, world, _oidc(down=True))
    r = c.post("/logout", data={"csrf": _csrf(c)})
    assert r.status_code == 200 and "You are signed out" in r.text
    assert c.get("/").status_code == 302


def test_sign_out_can_be_kept_local(tmp_path, world):
    c = _signed_in_with_oidc(tmp_path, world, _oidc(), tweak=lambda d: d["oidc"].update({"endSession": False}))
    r = c.post("/logout", data={"csrf": _csrf(c)})
    assert r.status_code == 200 and "You are signed out" in r.text


# ------------------------------------------------------------ capabilities (TM-1017)

CONF = {"identity": True, "observability": True, "notifications": True, "aiPlane": True,
        "dataProtection": True, "hardwareTelemetry": False, "workflowAutomation": True, "networkPolicy": True}


def test_capabilities_page_shows_set_and_deployed(tmp_path, world):
    with_resources(world, "tockmox-observability", [("Prometheus", "tockmox-observability-kube-prometheus"),
                                                    ("Deployment", "tockmox-ntfy")])
    with_resources(world, "tockmox-ai", [("StatefulSet", "tockmox-ai-open-webui")])
    with_resources(world, "tockmox-platform", [("Deployment", "tockmox-platform-traefik")])   # no garage
    c = admin(tmp_path, world, tweak=lambda d: d.update({"capabilities": CONF}))
    t = c.get("/capabilities").text
    rows = {r["key"]: r for r in c.get("/api/v1/status").json()["capabilities"]}
    assert rows["observability"]["deployed"] == "on" and rows["observability"]["agree"]
    assert rows["notifications"]["deployed"] == "on"
    assert rows["aiPlane"]["deployed"] == "on"
    # set on, layer present, marker absent: deployed off, and the page says they disagree
    assert rows["dataProtection"] == {**rows["dataProtection"], "configured": "on", "deployed": "off", "agree": False}
    assert "Disagrees" in t
    # no Application deploys charts/tockmox-identity: unknown, never "off"
    assert rows["identity"]["deployed"] == "unknown" and rows["identity"]["agree"]


def test_capabilities_are_unknown_when_argo_cd_is_down(tmp_path, world):
    world.down.add("kube")
    c = admin(tmp_path, world, tweak=lambda d: d.update({"capabilities": CONF}))
    assert c.get("/capabilities").status_code == 200
    assert {r["deployed"] for r in capmod.evaluate(CONF, None, set())} == {"unknown"}


def test_capabilities_page_is_for_admins(tmp_path, world):
    assert make_client(tmp_path, world, groups=["tockmox-users"]).get("/capabilities").status_code == 403


def test_capabilities_config_must_be_booleans():
    with pytest.raises(config.ConfigError):
        config._parse_capabilities({"identity": "yes"})
    assert config._parse_capabilities(None) == ()


# ------------------------------------------------------------ 0.8.0 testing, round 2 (2026-10-11 19:42)

def test_app_tiles_open_the_short_link_they_show(tmp_path, world):
    t = admin(tmp_path, world).get("/").text
    assert '<a class="app" href="/grafana/"' in t and "tockmox.int.example.com/grafana" in t
    assert 'href="https://grafana.int.example.com/"' not in t
    r = admin(tmp_path, world).get("/grafana/")
    assert r.status_code == 302 and r.headers["location"] == "https://grafana.int.example.com/"


def test_inference_nodes_tab_is_named_in_full(tmp_path, world):
    t = admin(tmp_path, world).get("/").text
    assert ">Inference Nodes</a>" in t and ">Nodes</a>" not in t


NOTES = """# Changelog

## [Unreleased]

The first public release.

- **AI**: chat and a gateway.

[Unreleased]: https://github.com/tockmox/tockmox/commits/main
"""


def test_release_notes_show_on_a_build_that_tracks_a_commit(tmp_path, world):
    for a in world.apps:
        a["spec"]["source"]["targetRevision"] = "0244662843d5949446176f4efd60ab7aac231430"
    (tmp_path / "CHANGELOG.md").write_text(NOTES)
    from tests.test_status_api import make_client
    t = make_client(tmp_path, world, groups=["tockmox-admins"], notes_path=str(tmp_path / "CHANGELOG.md")).get("/version").text
    assert "Release notes this build carries" in t and "The first public release." in t
    assert "<strong>AI</strong>" in t and "commits/main" not in t
    assert "No notes bundled" not in t


def test_release_notes_on_a_tag_still_come_from_that_tag(tmp_path, world):
    (tmp_path / "CHANGELOG.md").write_text(NOTES.replace("[Unreleased]", "[0.8.0] ... 2026-10-20", 1))
    from tests.test_status_api import make_client
    t = make_client(tmp_path, world, groups=["tockmox-admins"], notes_path=str(tmp_path / "CHANGELOG.md")).get("/version").text
    assert "Release notes for 0.8.0 (2026-10-20)" in t


def test_sign_in_keeps_the_id_token_and_sign_out_hands_it_back(tmp_path, world):
    """End to end against a mock issuer: the callback stores the raw ID token, and Sign out sends
    it as id_token_hint with the configured return page, so Authentik both ends its session and
    sends the browser back to the UI (round 2: 'it should just take you to the UI's sign-on page')."""
    import json as _json
    import time as _time
    from urllib.parse import parse_qs, urlsplit

    import jwt as _jwt
    from cryptography.hazmat.primitives.asymmetric import rsa
    from jwt.algorithms import RSAAlgorithm

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = _json.loads(RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update({"kid": "k1", "alg": "RS256", "use": "sig"})
    iss = "https://auth.int.example.com/application/o/tockmox-ui/"
    box = {}

    def h(req: httpx.Request):
        u = str(req.url)
        if u.endswith("/.well-known/openid-configuration"):
            return httpx.Response(200, json={
                "issuer": iss, "authorization_endpoint": "https://auth.int.example.com/application/o/authorize/",
                "token_endpoint": "https://auth.int.example.com/application/o/token/",
                "jwks_uri": "https://auth.int.example.com/application/o/tockmox-ui/jwks/",
                "end_session_endpoint": "https://auth.int.example.com/application/o/tockmox-ui/end-session/"})
        if u.endswith("/jwks/"):
            return httpx.Response(200, json={"keys": [jwk]})
        if u.endswith("/token/"):
            now = int(_time.time())
            box["idt"] = _jwt.encode({"iss": iss, "aud": "tockmox-ui", "sub": "u1", "iat": now, "exp": now + 300,
                                      "nonce": box["nonce"], "name": "Jeff", "groups": ["tockmox-admins"]},
                                     key, algorithm="RS256", headers={"kid": "k1"})
            return httpx.Response(200, json={"id_token": box["idt"], "access_token": "at", "token_type": "Bearer"})
        return httpx.Response(404)

    from tests.test_status_api import make_client
    c = make_client(tmp_path, world, tweak=lambda d: d["oidc"].update(
        {"issuer": iss.rstrip("/"), "postLogoutRedirectUrl": "https://tockmox.int.example.com/"}))
    c.app.state.oidc.transport = httpx.MockTransport(h)
    c.app.state.oidc.issuer = iss.rstrip("/")
    r = c.get("/login?next=/")
    q = parse_qs(urlsplit(r.headers["location"]).query)
    box["nonce"] = q["nonce"][0]
    r = c.get("/auth/callback", params={"code": "abc", "state": q["state"][0]})
    assert r.status_code == 302, r.text
    assert c.cookies.get("tockmox_ui_idt") == box["idt"]
    r = c.post("/logout", data={"csrf": _csrf(c)})
    loc = parse_qs(urlsplit(r.headers["location"]).query)
    assert loc["id_token_hint"] == [box["idt"]]
    assert loc["post_logout_redirect_uri"] == ["https://tockmox.int.example.com/"]


def test_update_check_on_a_commit_says_the_feed_verified_and_what_is_newest(tmp_path, world):
    import base64 as _b64
    import json as _json
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    for a in world.apps:
        a["spec"]["source"]["targetRevision"] = "0244662843d5949446176f4efd60ab7aac231430"
    k = Ed25519PrivateKey.generate()
    pub = _b64.b64encode(k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
    body = _json.dumps({"schema": 1, "expires": 4102444800,
                        "releases": [{"version": "0.8.0", "date": "2026-10-20", "notes": "First public release."}]}).encode()
    (tmp_path / "releases.json").write_bytes(body)
    (tmp_path / "releases.json.sig").write_bytes(_b64.b64encode(k.sign(body)))
    c = admin(tmp_path, world, tweak=lambda d: d.update({"updateCheck": {
        "enabled": True, "feedUrl": f"file://{tmp_path}/releases.json", "publicKeys": [pub]}}))
    t = c.get("/version").text
    assert "Feed verified" in t and "Tockmox <strong>0.8.0</strong>" in t and "nothing to compare" in t
    assert "Up to date" not in t

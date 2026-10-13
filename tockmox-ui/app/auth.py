# SPDX-License-Identifier: Apache-2.0
"""OIDC login (authorization code + PKCE + state + nonce) and the session cookie.

The session is a signed, expiring cookie carrying sub, name and groups. No
server-side store, so the UI stays stateless and an upgrade only has to keep
one Secret (the signing key) for sessions to survive (surface bar, upgrade leg).
"""
from __future__ import annotations

import base64
import hashlib
import secrets
import time
from dataclasses import dataclass
from urllib.parse import urlencode

import httpx
import jwt

from . import telemetry
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

SESSION_COOKIE = "__Host-tockmox_ui"
LOGIN_COOKIE = "__Host-tockmox_ui_login"
DEV_SESSION_COOKIE = "tockmox_ui"          # used only when secure_cookies is false (local http tests)
DEV_LOGIN_COOKIE = "tockmox_ui_login"
# The raw ID token, kept only to hand back as id_token_hint on sign-out. Authentik accepts a
# post_logout_redirect_uri only with that hint, so without it Sign out cannot return the browser
# here. Not signed by us: it is the issuer's own signed JWT, and it is never read back as identity.
IDT_COOKIE = "__Host-tockmox_ui_idt"
DEV_IDT_COOKIE = "tockmox_ui_idt"
IDT_MAX_BYTES = 3800                       # a larger token is not stored; sign-out then sends no hint


@dataclass(frozen=True)
class User:
    sub: str
    name: str
    groups: frozenset
    csrf: str
    is_admin: bool
    sid: str = ""


class Sessions:
    def __init__(self, secret: str, max_age: int, admin_group: str, secure: bool):
        self.s = URLSafeTimedSerializer(secret, salt="tockmox-ui-session")
        self.l = URLSafeTimedSerializer(secret, salt="tockmox-ui-login")
        self.max_age, self.admin_group, self.secure = max_age, admin_group, secure
        self.session_cookie = SESSION_COOKIE if secure else DEV_SESSION_COOKIE
        self.login_cookie = LOGIN_COOKIE if secure else DEV_LOGIN_COOKIE
        self.idt_cookie = IDT_COOKIE if secure else DEV_IDT_COOKIE

    def issue(self, sub: str, name: str, groups) -> str:
        return self.s.dumps({"sub": sub, "name": name, "groups": sorted(set(groups)),
                             "csrf": secrets.token_urlsafe(24), "sid": secrets.token_urlsafe(16),
                             "iat": int(time.time())})

    def read(self, token: str | None) -> User | None:
        if not token:
            return None
        try:
            d = self.s.loads(token, max_age=self.max_age)
        except (BadSignature, SignatureExpired):
            return None
        g = frozenset(d.get("groups") or [])
        return User(d["sub"], d.get("name") or d["sub"], g, d["csrf"], self.admin_group in g, d.get("sid", ""))

    def cookie_args(self) -> dict:
        return {"httponly": True, "secure": self.secure, "samesite": "lax", "path": "/"}


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


class OIDC:
    def __init__(self, issuer: str, client_id: str, client_secret: str, redirect_url: str,
                 timeout: float = 5.0, transport: httpx.BaseTransport | None = None,
                 scopes: str = "openid profile email"):
        self.issuer, self.client_id, self.client_secret = issuer, client_id, client_secret
        self.redirect_url, self.timeout, self.transport = redirect_url, timeout, transport
        # Authentik carries `groups` in the profile scope mapping the Tockmox chart binds;
        # asking for a scope the provider does not define can fail the whole request.
        self.scopes = scopes
        self._disc = None
        self._disc_t = 0.0
        self._jwks = None

    def _client(self):
        return httpx.Client(timeout=self.timeout, transport=self.transport)

    def discovery(self, fresh: bool = False) -> dict:
        # "fresh" means at most 10s old: enough to notice an IdP outage at /login without
        # every anonymous hit fanning out to the IdP (fresh-eyes review, finding 9).
        age = time.time() - self._disc_t
        if self._disc is None or age > 3600 or (fresh and age > 10):
            with self._client() as c:
                r = c.get(self.issuer + "/.well-known/openid-configuration")
                r.raise_for_status()
                d = r.json()
            if d.get("issuer", "").rstrip("/") != self.issuer:
                raise ValueError("issuer mismatch in discovery document")
            self._disc, self._disc_t = d, time.time()
            self._jwks = None
        return self._disc

    def begin(self) -> tuple[str, dict]:
        # Fresh, not cached: a cached discovery document sends the browser to an IdP
        # that is down, where it meets the proxy's bare 503 instead of our recovery
        # page. Found in the lab (TM-0901, 2026-10-05, run D10).
        d = self.discovery(fresh=True)
        verifier = _b64(secrets.token_bytes(32))
        st = {"state": secrets.token_urlsafe(24), "nonce": secrets.token_urlsafe(24), "verifier": verifier}
        q = {"response_type": "code", "client_id": self.client_id, "redirect_uri": self.redirect_url,
             "scope": self.scopes, "state": st["state"], "nonce": st["nonce"],
             "code_challenge": _b64(hashlib.sha256(verifier.encode()).digest()),
             "code_challenge_method": "S256"}
        return d["authorization_endpoint"] + "?" + urlencode(q), st

    def end_session_url(self, post_logout_redirect: str = "", id_token_hint: str = "") -> str | None:
        """Where to send the browser to end the issuer's session (OIDC RP-initiated logout), or
        None when the issuer names no end_session_endpoint or cannot be reached. Never raises:
        signing out must always succeed locally.

        post_logout_redirect_uri goes only WITH an id_token_hint: OIDC RP-Initiated Logout 1.0
        lets the issuer require the hint for it, and Authentik does (it refuses the whole request
        otherwise, so a redirect sent without the hint would leave the user signed IN there)."""
        try:
            ep = self.discovery().get("end_session_endpoint")
        except Exception as e:  # noqa: BLE001
            # Logged, not counted: TockmoxUISignInFailing is about signing IN.
            telemetry.log.warning("sign-out could not reach the issuer, signed out locally only: %s: %s",
                                  type(e).__name__, e)
            return None
        if not ep or not str(ep).startswith(("https://", "http://")):
            return None
        q = {"client_id": self.client_id}
        if id_token_hint:
            q["id_token_hint"] = id_token_hint
            if post_logout_redirect:
                q["post_logout_redirect_uri"] = post_logout_redirect
        return ep + ("&" if "?" in ep else "?") + urlencode(q)

    def _key_for(self, token: str):
        d = self.discovery()
        if self._jwks is None:
            with self._client() as c:
                r = c.get(d["jwks_uri"])
                r.raise_for_status()
                self._jwks = r.json()
        kid = jwt.get_unverified_header(token).get("kid")
        keys = self._jwks.get("keys", [])
        if kid is None and len(keys) != 1:
            raise ValueError("token names no key and the JWKS holds more than one")
        for k in keys:
            if kid is None or k.get("kid") == kid:
                return jwt.PyJWK(k).key
        self._jwks = None
        raise ValueError("no signing key for token")

    def finish(self, code: str, state: dict) -> dict:
        d = self.discovery()
        with self._client() as c:
            r = c.post(d["token_endpoint"], data={
                "grant_type": "authorization_code", "code": code, "redirect_uri": self.redirect_url,
                "code_verifier": state["verifier"], "client_id": self.client_id,
                "client_secret": self.client_secret})
            r.raise_for_status()
            tok = r.json()
        idt = tok["id_token"]
        claims = jwt.decode(idt, self._key_for(idt), algorithms=["RS256", "ES256", "EdDSA"],
                            audience=self.client_id, issuer=d["issuer"],
                            options={"require": ["exp", "iat", "sub", "aud", "iss"]})
        if claims.get("nonce") != state["nonce"]:
            raise ValueError("nonce mismatch")
        aud = claims.get("aud")
        if isinstance(aud, list) and len(aud) > 1 and claims.get("azp") != self.client_id:
            raise ValueError("azp does not name this client")
        groups = claims.get("groups")
        if groups is None and tok.get("access_token") and d.get("userinfo_endpoint"):
            with self._client() as c:
                u = c.get(d["userinfo_endpoint"], headers={"Authorization": "Bearer " + tok["access_token"]})
                if u.status_code == 200 and u.json().get("sub") == claims["sub"]:
                    groups = u.json().get("groups")
        claims["groups"] = [g for g in (groups or []) if isinstance(g, str)]
        claims["_id_token"] = idt                 # for id_token_hint at sign-out; never a claim
        return claims

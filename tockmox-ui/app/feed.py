# SPDX-License-Identifier: Apache-2.0
"""The opt-in update check: one signed static file, nothing identifying sent.

Privacy contract (DESIGN-2026-10-04-tockmox-ui.md §6):
  * nothing runs unless updateCheck.enabled is true (default false);
  * one GET for the feed, one for its signature; fixed User-Agent, no query
    string, no cookies, no instance id, no running version;
  * the comparison happens here, never on the server;
  * an unverified feed contributes NOTHING to the page, not even a version string.
"""
from __future__ import annotations

import base64
import json
import re
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

USER_AGENT = "tockmox-ui"
_SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")


def parse_version(v):
    if not isinstance(v, str):
        return None
    m = _SEMVER.match(v.strip())
    if not m:
        return None
    pre = m.group(4)
    pre_key = (1,) if pre is None else (0,) + tuple(
        (0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), pre_key)


def newer(a: str, b: str) -> bool:
    """True if a is strictly newer than b. Unparseable versions are never newer."""
    pa, pb = parse_version(a), parse_version(b)
    return bool(pa and pb and pa > pb)


def bump_kind(current: str, target: str) -> str:
    pc, pt = parse_version(current), parse_version(target)
    if not (pc and pt):
        return "unknown"
    if pt[0] != pc[0]:
        return "major"
    if pt[1] != pc[1]:
        return "minor"
    return "patch"


def verify(feed: bytes, sig_b64: bytes, public_keys) -> bool:
    try:
        sig = base64.b64decode(sig_b64.strip(), validate=True)
    except Exception:  # noqa: BLE001
        return False
    for k in public_keys:
        try:
            Ed25519PublicKey.from_public_bytes(base64.b64decode(k, validate=True)).verify(sig, feed)
            return True
        except (InvalidSignature, ValueError):
            continue
    return False


@dataclass
class FeedState:
    enabled: bool
    checked_at: float | None = None
    verified: bool = False
    error: str = ""
    releases: list = field(default_factory=list)

    def latest(self):
        rel = [r for r in self.releases if parse_version(r.get("version", ""))]
        rel = [r for r in rel if not (parse_version(r["version"])[3] != (1,))]  # stable only
        return max(rel, key=lambda r: parse_version(r["version"]), default=None)

    def release(self, version: str):
        pv = parse_version(version)
        for r in self.releases:
            if pv and parse_version(r.get("version", "")) == pv:
                return r
        return None

    def between(self, current: str, target: str):
        """Releases in (current, target], oldest first: every set of breaking notes on the way."""
        out = [r for r in self.releases
               if newer(r.get("version", ""), current) and not newer(r.get("version", ""), target)]
        return sorted(out, key=lambda r: parse_version(r["version"]))


def _clean(r):
    """Keep only well-typed entries: a signed feed is trusted for authorship, not for shape."""
    if not isinstance(r, dict) or not parse_version(r.get("version")):
        return None
    out = {"version": r["version"]}
    for k in ("date", "notes", "notesUrl", "minUpgradeFrom"):
        if isinstance(r.get(k), str):
            out[k] = r[k]
    if out.get("minUpgradeFrom") and not parse_version(out["minUpgradeFrom"]):
        del out["minUpgradeFrom"]
    out["breaking"] = [b for b in r.get("breaking") or [] if isinstance(b, str)] if isinstance(r.get("breaking"), list) else []
    out["security"] = r.get("security") is True
    return out


class UpdateChecker:
    def __init__(self, enabled: bool, feed_url: str, public_keys, interval_s: int = 86400,
                 timeout: float = 5.0, transport: httpx.BaseTransport | None = None):
        self.enabled, self.feed_url, self.keys = enabled, feed_url, tuple(public_keys)
        self.interval, self.timeout, self.transport = interval_s, timeout, transport
        self.state = FeedState(enabled=enabled)

    def _get(self, url: str) -> bytes:
        parts = urlsplit(url)
        if parts.scheme == "file":
            with open(parts.path, "rb") as fh:
                return fh.read()
        if parts.scheme != "https" or parts.query or parts.fragment:
            raise ValueError("feed URL must be https without a query")
        with httpx.Client(timeout=self.timeout, transport=self.transport, follow_redirects=False,
                          headers={"User-Agent": USER_AGENT, "Accept": "application/json"}) as c:
            r = c.get(url)
            r.raise_for_status()
            return r.content

    RETRY_AFTER_FAILURE_S = 3600

    def check(self, force: bool = False, now=time.time) -> FeedState:
        if not self.enabled:
            return self.state                          # no I/O, ever
        s = self.state
        wait = self.interval if (s.verified or not s.error) else min(self.interval, self.RETRY_AFTER_FAILURE_S)
        if not force and s.checked_at and now() - s.checked_at < wait:
            return s
        new = FeedState(enabled=True, checked_at=now())
        try:
            body = self._get(self.feed_url)
            sig = self._get(self.feed_url + ".sig")
            if not verify(body, sig, self.keys):
                new.error = "the update feed could not be verified"
            else:
                doc = json.loads(body)
                exp = doc.get("expires")
                if doc.get("schema") != 1 or not isinstance(doc.get("releases"), list):
                    new.error = "the update feed has an unknown format"
                elif exp is not None and (not isinstance(exp, (int, float)) or exp < now()):
                    # a replayed old feed can hide a newer release; producers set expires (TM-0900)
                    new.error = "the update feed has expired"
                else:
                    new.verified = True
                    new.releases = [_clean(r) for r in doc["releases"] if _clean(r)]
        except Exception as e:  # noqa: BLE001
            new.error = f"the update feed could not be fetched ({type(e).__name__})"
        if new.error and s.verified:
            # keep showing what we last verified, and say the latest check failed
            new.releases, new.verified = s.releases, True
        self.state = new
        return new

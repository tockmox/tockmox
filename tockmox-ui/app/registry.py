# SPDX-License-Identifier: Apache-2.0
"""The first-party feature registry (app/features.yaml) and the release markers it feeds.

specs/tockmox-ui/SPEC.md sections 9 and 10 (Tockmox planning repo). The registry is data shipped in the UI image: what
each first-party feature is called, how mature it is (stability), the release that first ships it (since), and what it
adds to the console when it is on (contributes). A site's features.<id> config switches a feature on and may name its
own contributes; the registry supplies the rest.

Release markers are words, one per item (SPEC section 10):

  Private       the maintainer's own extension (origin: private on the feature or the app entry)
  Preview       in Tockmox on main, not in a tagged release yet: the item's `since` is not a release in the CHANGELOG
                this image bundles. Never on a tagged build: an image whose bundled CHANGELOG opens on a release, not
                on [Unreleased], is a tagged build, and every item in it is in that release
  Experimental  shipped, still maturing (stability: experimental). Not a release marker; it shows where neither of the
                two above does

Pure functions and one small loader, so the tests reach every rule without a server.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

import yaml

DEFAULT_REGISTRY = os.path.join(os.path.dirname(__file__), "features.yaml")
STABILITY = ("experimental", "provisional", "stable")
_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
_VERSION = re.compile(r"\d+\.\d+\.\d+")
_ENTRY_KEYS = {"name", "stability", "since", "contributes", "about"}


class RegistryError(ValueError):
    """features.yaml says something the console will not start with; the message names the key."""


@dataclass(frozen=True)
class Entry:
    id: str
    name: str
    stability: str
    since: str | None = None
    contributes: dict | None = None
    about: str = ""


@dataclass(frozen=True)
class Registry:
    features: dict = field(default_factory=dict)       # id -> Entry
    tiles: dict = field(default_factory=dict)          # app id -> since

    def get(self, fid: str) -> Entry | None:
        return self.features.get(fid)


def _since(v, where: str) -> str | None:
    if v is None:
        return None
    if not isinstance(v, str) or not _VERSION.fullmatch(v):
        raise RegistryError(f"{where}.since must be a release version x.y.z")
    return v


def parse(doc) -> Registry:
    if not isinstance(doc, dict) or doc.get("version") != 1:
        raise RegistryError("features registry: version must be 1")
    extra = set(doc) - {"version", "features", "tiles"}
    if extra:
        raise RegistryError(f"features registry: {', '.join(sorted(extra))} is not a key this version reads")
    feats = {}
    raw_f = doc.get("features") or {}
    if not isinstance(raw_f, dict):
        raise RegistryError("features registry: features must be a mapping")
    for fid, raw in raw_f.items():
        where = f"features registry: {fid}"
        if not isinstance(fid, str) or not _ID.fullmatch(fid):
            raise RegistryError(f"{where}: an id is lowercase letters, digits and hyphens")
        if not isinstance(raw, dict):
            raise RegistryError(f"{where} must be a mapping")
        extra = set(raw) - _ENTRY_KEYS
        if extra:
            raise RegistryError(f"{where}: {', '.join(sorted(extra))} is not a key this version reads")
        name = raw.get("name")
        if not isinstance(name, str) or not name.strip() or len(name) > 40:
            raise RegistryError(f"{where}.name must be 1 to 40 characters")
        st = raw.get("stability")
        if st not in STABILITY:
            raise RegistryError(f"{where}.stability must be one of {', '.join(STABILITY)}")
        c = raw.get("contributes")
        if c is not None and not isinstance(c, dict):
            raise RegistryError(f"{where}.contributes must be a mapping")
        about = raw.get("about", "")
        if not isinstance(about, str) or len(about) > 300:
            raise RegistryError(f"{where}.about must be text of at most 300 characters")
        feats[fid] = Entry(id=fid, name=name.strip(), stability=st, since=_since(raw.get("since"), where), contributes=c,
                           about=about.strip())
    tiles = {}
    raw_t = doc.get("tiles") or {}
    if not isinstance(raw_t, dict):
        raise RegistryError("features registry: tiles must be a mapping of app id to {since}")
    for tid, raw in raw_t.items():
        where = f"features registry: tiles.{tid}"
        if not isinstance(raw, dict) or set(raw) - {"since"} or "since" not in raw:
            raise RegistryError(f"{where} takes since only")
        tiles[str(tid)] = _since(raw["since"], where)
    return Registry(features=feats, tiles=tiles)


def load(path: str | None = None) -> Registry:
    with open(path or DEFAULT_REGISTRY, encoding="utf-8") as fh:
        return parse(yaml.safe_load(fh) or {})


# ---------------------------------------------------------------- the build, from the CHANGELOG it bundles

@dataclass(frozen=True)
class Build:
    """What this image's bundled CHANGELOG says about the build: tagged or not, and the releases it contains."""
    tagged: bool
    released: frozenset

    @classmethod
    def from_notes(cls, by_version: dict) -> "Build":
        """`by_version` is ReleaseNotes.by_version: sections in file order, keyed by version or "Unreleased".
        No CHANGELOG at all reads as untagged with nothing released: a build that cannot say what it is never
        claims to be a release."""
        keys = list(by_version or {})
        released = frozenset(k for k in keys if _VERSION.fullmatch(k))
        tagged = bool(keys) and _VERSION.fullmatch(keys[0]) is not None
        return cls(tagged=tagged, released=released)

    def preview(self, since: str | None) -> bool:
        """True when an item first shipping in `since` is not yet in a release this build carries. Never on a
        tagged build; never for an item with no `since` (it shipped before the registry tracked it)."""
        if self.tagged or since is None:
            return False
        return since not in self.released


MARKER_TITLES = {
    "Private": "The maintainer's own extension, not in the open-source project",
    "Preview": "In Tockmox on main, not in a tagged release yet",
    "Experimental": "Shipped, and still maturing: its behaviour and settings may change between releases",
}


def marker_title(word: str | None) -> str:
    """The hover text that says what a marker means, for the templates."""
    return MARKER_TITLES.get(word or "", "")


def marker(*, origin: str | None = None, since: str | None = None, stability: str | None = None,
           build: Build | None = None) -> str | None:
    """The one word an item carries, or None: Private, else Preview, else Experimental."""
    if origin == "private":
        return "Private"
    if build is not None and build.preview(since):
        return "Preview"
    if stability == "experimental":
        return "Experimental"
    return None


__all__ = ["Registry", "Entry", "RegistryError", "Build", "parse", "load", "marker", "marker_title", "MARKER_TITLES", "STABILITY", "DEFAULT_REGISTRY"]

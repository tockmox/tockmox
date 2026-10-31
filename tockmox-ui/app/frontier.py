# SPDX-License-Identifier: Apache-2.0
"""Frontier generations (TM-1297, rulings D1 and D2 of 2026-10-30).

A hosted family keeps several generations at once. Each generation is served under a PINNED alias that never moves
(`claude-sonnet-5-5` is always anthropic/claude-sonnet-5-5), and the family has one FLOATING alias (`claude-sonnet`) that
follows the current generation and is moved only by a promotion PR. How many generations a family keeps is
`modelLifecycle.frontier.keepGenerations` (default 3). A generation leaves only when its provider retires it (the
watcher's countdown, then a retire change) or when it falls off the end of that list through a promotion, and never
silently: both are changes a person reviews and commits.

This module is pure: names, ordering and the read-only view of a gateway's model_list. The changes themselves are built
in app/models.py (promote_hosted, retire_generation), which uses these helpers.

    claude-sonnet-5-5   -> family claude-sonnet, version (5, 5)
    claude-sonnet-5     -> family claude-sonnet, version (5,)
    gemini-2.5-pro      -> family gemini-pro,    version (2, 5)
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# A provider's dated snapshot suffix: claude-sonnet-4-5-20250929, gpt-5-2025-08-07. It is part of the pinned alias (the
# alias names the model exactly) but not of the family and not of the version.
_SNAPSHOT = re.compile(r"-(?:\d{8}|\d{4}-\d{2}-\d{2})$")
# stem (words), then a version (digits joined by - or .), then optional trailing words: claude-sonnet-5-5, gemini-2.5-pro.
# The stem is lazy so that "claude-3-5-sonnet" reads as stem "claude", version 3-5, rest "-sonnet".
_NAME = re.compile(r"^(?P<stem>[A-Za-z][A-Za-z]*(?:-[A-Za-z][A-Za-z]*)*?)-(?P<ver>\d{1,3}(?:[.-]\d{1,3})*)(?P<rest>(?:-[A-Za-z][A-Za-z]*)*)$")


def model_name(model_id: str) -> str:
    """The model's name with the provider dropped: 'anthropic/claude-sonnet-5-5' -> 'claude-sonnet-5-5'. Only the last
    path segment is kept, so a router's 'openrouter/anthropic/claude-sonnet-5-5' gives the same name."""
    return str(model_id or "").strip().rsplit("/", 1)[-1]


def generation_alias(model_id: str) -> str:
    """The pinned alias for a hosted model: its name without the provider. It never moves, so a tuned agent can call it
    by name. 'anthropic/claude-sonnet-5-5' -> 'claude-sonnet-5-5'."""
    return model_name(model_id)


def _parse(model_id: str):
    name = model_name(model_id)
    snap = _SNAPSHOT.search(name)
    m = _NAME.match(name[: snap.start()] if snap else name)
    if not m:
        return None
    ver = tuple(int(x) for x in re.split(r"[.-]", m.group("ver")))
    while len(ver) > 1 and ver[-1] == 0:            # 5.0 is generation 5
        ver = ver[:-1]
    return m.group("stem"), ver, m.group("rest")


def family_of(model_id: str) -> str:
    """The family alias for a hosted model: the provider and the version dropped, any words after the version kept.

        claude-sonnet-5-5 -> claude-sonnet     claude-opus-5 -> claude-opus     gpt-5.1 -> gpt
        gemini-2.5-pro -> gemini-pro           claude-3-5-sonnet-20241022 -> claude-sonnet

    When the name has no version in it that this can read (gpt-4o, o3, claude-sonnet), the family is the model name
    itself: it has no generations to float over, and nothing is guessed."""
    p = _parse(model_id)
    return (p[0] + p[2]) if p else model_name(model_id)


def version_of(model_id: str) -> tuple:
    """The generation's version numbers: claude-sonnet-5-5 -> (5, 5); claude-sonnet-5 -> (5,); () when none is readable."""
    p = _parse(model_id)
    return p[1] if p else ()


def has_family(model_id: str) -> bool:
    """True when the model belongs to a family whose alias differs from its own pinned alias."""
    return family_of(model_id) != generation_alias(model_id)


def generation_key(model_id: str, adopted: str = "") -> tuple:
    """Sort key, larger is newer: the version numbers (5-5 beats 5 beats 4-5), then the catalog's adopted date, then the
    snapshot date in the name, then the name, so the order is total and never depends on the input order."""
    snap = _SNAPSHOT.search(model_name(model_id))
    return (version_of(model_id), adopted or "", snap.group(0) if snap else "", model_name(model_id))


def newest_first(items, model=lambda x: x, adopted=lambda x: ""):
    """`items` ordered newest generation first. `model(item)` gives the provider/model id, `adopted(item)` the catalog's
    adopted date ("" when none)."""
    return sorted(items, key=lambda x: generation_key(model(x), adopted(x)), reverse=True)


# ---------------------------------------------------------------- the gateway, read as generations

def hosted_model(entry: dict) -> str:
    """provider/model for a gateway entry that goes to a hosted provider (no api_base of ours), else ''. The same rule as
    budget.hosted_model."""
    lp = (entry or {}).get("litellm_params") or {}
    full = str(lp.get("model", ""))
    info = (entry or {}).get("model_info") or {}
    if "/" in full and not lp.get("api_base") and info.get("endpoint_tier", "external") != "local":
        return full
    return ""


def is_family_entry(entry: dict) -> bool:
    """A gateway entry that is a family's floating alias: it routes a hosted model whose family is the entry's own name."""
    h = hosted_model(entry)
    return bool(h) and has_family(h) and family_of(h) == str((entry or {}).get("model_name", ""))


def is_pinned_entry(entry: dict) -> bool:
    """A gateway entry that is a generation's pinned alias: named exactly as the hosted model it routes, in a family."""
    h = hosted_model(entry)
    return bool(h) and has_family(h) and generation_alias(h) == str((entry or {}).get("model_name", ""))


@dataclass
class Generation:
    alias: str                    # the pinned alias
    model: str                    # provider/model
    entry: dict                   # the gateway's own entry, untouched
    catalog: object = None        # the catalog Entry for the model, or None
    current: bool = False         # the family alias points here
    retire: dict | None = None    # the countdown (inbox.retire_map value) when the provider is retiring it
    status: str = "Kept"          # Current | Kept | Retiring


@dataclass
class FamilyView:
    family: str
    family_entry: dict | None
    target: str                   # provider/model the family alias points at ('' when it has no entry)
    generations: list = field(default_factory=list)       # newest first
    left: list = field(default_factory=list)              # catalog entries of this family that left (retired), newest first
    keep: int = 3

    @property
    def over(self) -> int:
        """How many pinned generations are beyond keepGenerations (0 when within)."""
        return max(0, len(self.generations) - self.keep)


def pinned_generations(gateway, family: str, lc=None) -> list[Generation]:
    """The pinned generation entries of `family` in the gateway's model_list, newest first. `lc` (a models.Lifecycle)
    supplies each model's catalog entry, whose adopted date breaks a tie between two readings of the same version."""
    out = []
    for g in gateway or ():
        if isinstance(g, dict) and is_pinned_entry(g) and family_of(hosted_model(g)) == family:
            h = hosted_model(g)
            out.append(Generation(str(g["model_name"]), h, g, lc.by_ref(h) if lc is not None else None))
    return newest_first(out, lambda x: x.model, lambda x: getattr(x.catalog, "adopted", "") or "")


def family_view(gateway, lc, family: str, retire_map=None, retire_for=None) -> FamilyView | None:
    """The floating alias `family` and the generations kept under it, or None when `family` is not a family alias in this
    gateway. `retire_map` and `retire_for` are inbox.retire_map's result and inbox.retire_for, to attach each generation's
    countdown."""
    entries = [g for g in (gateway or ()) if isinstance(g, dict)]
    fam = next((g for g in entries if g.get("model_name") == family and is_family_entry(g)), None)
    if fam is None:
        return None
    target = hosted_model(fam)
    gens = pinned_generations(entries, family, lc)
    for g in gens:
        g.current = g.model == target
        g.retire = retire_for(retire_map, g.model) if retire_map and retire_for else None
        g.status = "Current" if g.current else "Retiring" if g.retire else "Kept"
    left = [e for e in lc.catalog if e.source.kind == "hosted" and e.stage == "retired" and family_of(e.source.ref) == family
            and has_family(e.source.ref)]
    left = newest_first(left, lambda e: e.source.ref, lambda e: e.adopted)
    return FamilyView(family, fam, target, gens, left, lc.keep_generations)


# ---------------------------------------------------------------- display grouping for the Models page (TM-1296)
# family_of above is the one family rule; these group hosted models by provider, then family, for /models.

_VERSION = re.compile(r"^v?\d+(\.\d+)*$")           # 5  4.5  v2  20250929
PROVIDER_NAMES = {"anthropic": "Anthropic", "openai": "OpenAI", "google": "Google", "gemini": "Google", "mistral": "Mistral AI",
                  "xai": "xAI", "cohere": "Cohere", "meta": "Meta", "deepseek": "DeepSeek"}


def _tail(model_id: str) -> str:
    return str(model_id or "").rsplit("/", 1)[-1]


def provider_of(model_id: str) -> str:
    head, sep, _rest = str(model_id or "").partition("/")
    return head if sep and head else "other"


def version_key(model_id: str) -> tuple:
    """The numbers in a model id, for newest-first ordering: claude-sonnet-5-5 -> (5, 5), gpt-5.1 -> (5, 1)."""
    nums: list[int] = []
    for p in _tail(model_id).split("-"):
        if _VERSION.match(p):
            nums += [int(x) for x in p.lstrip("v").split(".")]
    return tuple(nums)


def provider_name(provider: str) -> str:
    return PROVIDER_NAMES.get(provider.lower(), provider)


def frontier_groups(lc, gateway_hosted: dict, retire_of) -> list[dict]:
    """Every hosted model the page knows, grouped. `lc` is the Lifecycle: hosted catalog entries that are promoted, or candidates
    (retired and rejected ones are in the catalog fold, not here). `gateway_hosted` is {"provider/model": [gateway aliases]} for the
    production gateway's own hosted routes: a model the catalog does not know still shows, as not in the catalog. `retire_of(*ids)`
    returns the countdown dict (with "badge") for a model id, or None.

    A row: {id, model, entry, stage, aliases, retire}. What the model costs is frontier_cost.costs_for (TM-1298), keyed by `id`."""
    rows: dict[str, dict] = {}
    for e in lc.catalog:
        if e.source.kind != "hosted" or e.stage not in ("promoted", "candidate"):
            continue
        ref = e.source.ref or e.model
        rows[ref] = {"id": ref, "model": e.model, "entry": e, "stage": e.stage, "aliases": list(gateway_hosted.get(ref, [])),
                     "retire": retire_of(e.model, ref)}
    for ref, aliases in gateway_hosted.items():
        if ref in rows or any(r["model"] == ref for r in rows.values()):
            continue
        rows[ref] = {"id": ref, "model": ref, "entry": None, "stage": "uncatalogued", "aliases": list(aliases), "retire": retire_of(ref)}
    by_provider: dict[str, dict[str, list]] = {}
    for r in rows.values():
        by_provider.setdefault(provider_of(r["id"]), {}).setdefault(family_of(r["id"]), []).append(r)
    out = []
    for prov in sorted(by_provider):
        fams = []
        for fam in sorted(by_provider[prov]):
            members = sorted(by_provider[prov][fam], key=lambda r: (version_key(r["id"]), r["id"]), reverse=True)
            fams.append({"family": fam, "rows": members})
        out.append({"provider": prov, "name": provider_name(prov), "families": fams,
                    "count": sum(len(f["rows"]) for f in fams)})
    return out

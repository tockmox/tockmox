# SPDX-License-Identifier: Apache-2.0
"""List prices for hosted models (TM-1298), read by the watcher from LiteLLM's price map.

Providers publish no price API. The one dated, recorded source the gateway itself prices spend with is LiteLLM's
model_prices_and_context_window.json: a single JSON object keyed by model id, with input_cost_per_token and
output_cost_per_token (US dollars per token) among its fields. Some keys carry a provider prefix ("gemini/gemini-2.5-pro"),
some do not ("claude-sonnet-5-5", "gpt-5.1"), so a catalog id "provider/model" is looked up in a fixed order and an unprefixed
key counts only when its own litellm_provider is that provider: a price for another provider's model of the same name is
no price.

  lookup(price_map, model_id)                       -> {"inPer1M", "outPer1M"} or None
  collect(price_map, model_ids, read_at)            -> {model_id: {inPer1M, outPer1M, source, readAt}}
  carry(fresh, previous, wanted, ok)                -> prices with the last good value kept for a failed read, marked stale

The label is exactly "LiteLLM price map", without a version number: the file is read from the main branch, and the date it was
read is the only version the page can honestly name. Pure: the watcher does the fetching.
"""
from __future__ import annotations

import math

PRICE_MAP_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
SOURCE_LABEL = "LiteLLM price map"
MAX_MAP_BYTES = 16 << 20            # the map was 3.2 MB in 2026-10 and grows; the watcher's usual 4 MiB cap would one day refuse it

# catalog provider -> the litellm_provider values an unprefixed key may carry for it
_PROVIDERS = {"anthropic": {"anthropic"}, "openai": {"openai", "text-completion-openai"}, "google": {"gemini"}, "gemini": {"gemini"},
              "mistral": {"mistral"}, "xai": {"xai"}, "deepseek": {"deepseek"}, "cohere": {"cohere", "cohere_chat"}}
# catalog provider -> the prefix LiteLLM's keys use for it, when that is not the same word
_PREFIX = {"google": "gemini"}


def _per_1m(v) -> float | None:
    """USD per token -> USD per 1M tokens. None unless v is a finite number of zero or more (a bool is not a number)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0:
        return None
    return round(v * 1_000_000, 6)


def lookup(price_map: dict, model_id: str) -> dict | None:
    """The base list price of "provider/model" per 1M tokens in and out, or None when the map has no usable entry. Tiered rates
    (a higher price past some context length) are not read: the base rate is the figure, and the docs say so."""
    provider, _sep, model = str(model_id or "").partition("/")
    if not (provider and model) or not isinstance(price_map, dict):
        return None
    want = _PROVIDERS.get(provider.lower(), {provider.lower()})
    low = {str(k).lower(): k for k in price_map}
    candidates = [(model_id, False), (f"{_PREFIX[provider.lower()]}/{model}" if provider.lower() in _PREFIX else "", False), (model, True)]
    for key, needs_provider in candidates:
        real = low.get(key.lower()) if key else None
        entry = price_map.get(real) if real is not None else None
        if not isinstance(entry, dict):
            continue
        if needs_provider and str(entry.get("litellm_provider", "")).lower() not in want:
            continue
        i, o = _per_1m(entry.get("input_cost_per_token")), _per_1m(entry.get("output_cost_per_token"))
        if i is not None and o is not None:
            return {"inPer1M": i, "outPer1M": o}
    return None


def collect(price_map: dict, model_ids, read_at: str) -> dict:
    """{model id: {inPer1M, outPer1M, source, readAt}} for every id the map prices; an id it does not price is absent."""
    out = {}
    for mid in model_ids:
        p = lookup(price_map, mid)
        if p:
            out[mid] = {**p, "source": SOURCE_LABEL, "readAt": read_at}
    return out


def carry(fresh: dict, previous: dict | None, wanted, ok: bool) -> dict:
    """The prices to record. After a read that worked, exactly what it found. After one that failed, the last good value for each
    wanted model, with its ORIGINAL read date and stale=True, so the page says "last read <date>" and never shows an old figure as
    today's. `previous` is the previous report's `prices` section."""
    if ok:
        return dict(fresh)
    out = dict(fresh)
    for mid in wanted:
        old = (previous or {}).get(mid)
        if mid not in out and isinstance(old, dict) and isinstance(old.get("readAt"), str):
            out[mid] = {**{k: old[k] for k in ("inPer1M", "outPer1M", "source", "readAt") if k in old}, "stale": True}
    return out

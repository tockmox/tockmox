# SPDX-License-Identifier: Apache-2.0
"""What a hosted model costs (TM-1298): its list price, what the gateway spent on it, and how often it was called.

Jeff's rulings (2026-10-30): a price comes from a dated, recorded source and spend from the gateway's own spend data; never an
estimate passed off as a fact. A figure nobody has reads "unknown", with the reason on hover, and is never 0 or a guess.

  costs_for(lc, report, spend, demand, models, spend_query=, demand_query=)   {model id: Cost}
  top_callers(caller_spend, keys, limit=5)                                    TopCallers: who spent most on a model or family
  price_footer(costs)                                                         the one line naming where the prices came from

The Models page (the Frontier section) uses these, and the alias page is wired to the same three calls: pass
`models={"anthropic/claude-sonnet-5-5": ["frontier-chat"]}` for the model an alias routes to and read the Cost back by its id.

Where each figure comes from:
  price   the site's own `modelLifecycle.frontier.prices` ("set by this site", with the day the site gave), else the watcher's
          report: LiteLLM's price map with the day it was read ("LiteLLM price map"; "last read <day>" when the last read failed
          and an earlier value is kept). The site's price wins.
  spend   `modelLifecycle.budget.spendQuery`, over the window the query itself names (Prometheus, USD).
  calls   `modelLifecycle.demandQuery`, over the window that query names (requests).
A spend or calls figure is matched to a model by the gateway aliases that route to it, then by the model id with and without its
provider: the same keys the Budget page uses.

The price is the provider's LIST price. It is not what was paid (discounts, caching, batch rates), and is not multiplied into a
spend figure: spend is whatever the gateway recorded. Pure: the sources are read by the caller and passed in.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from . import budget as bg
from . import prices as pr

SITE_LABEL = "set by this site"
NO_LABEL = ("", "None", "none", "null", "<none>")
# the labels LiteLLM puts on litellm_spend_metric that name WHO called, in the order a person would want them
CALLER_LABELS = ("api_key_alias", "team_alias", "team", "user", "end_user", "hashed_api_key")
MODEL_LABELS = ("model", "model_group", "requested_model")


def price_text(v: float) -> str:
    """$3.00, $0.25, $0.075, $1,250.00: at least two decimals, at most four."""
    s = f"{v:,.4f}".rstrip("0")
    head, _dot, tail = s.partition(".")
    return f"${head}.{tail.ljust(2, '0')}"


def calls_text(n: float) -> str:
    return f"{n:,.0f}"


@dataclass(frozen=True)
class Cost:
    """Everything the pages show for one hosted model. A field that is None is unknown, and `reasons[name]` says why."""
    model: str
    price_in: float | None = None           # list price, USD per 1M tokens in
    price_out: float | None = None
    price_source: str = ""                  # "LiteLLM price map" | "set by this site" | ""
    price_date: str = ""                    # the day the price was read (the site's own date for a site price)
    price_stale: bool = False               # the last read failed: this is the last good value, from price_date
    spend: float | None = None              # USD over spend_window, from the gateway's spend data
    spend_window: str = ""                  # "7 d", from the spend query
    calls: float | None = None
    calls_window: str = ""
    reasons: dict = field(default_factory=dict)   # "price" | "spend" | "calls" -> why that figure is unknown

    @property
    def price_known(self) -> bool:
        return self.price_in is not None and self.price_out is not None

    @property
    def price_text(self) -> str:
        return f"{price_text(self.price_in)} / {price_text(self.price_out)}" if self.price_known else "unknown"

    @property
    def price_note(self) -> str:
        """Where the price came from and when: "LiteLLM price map, read 2026-10-30", "... last read 2026-10-20", "set by this site, 2026-10-30"."""
        if not self.price_known:
            return ""
        if self.price_source == SITE_LABEL:
            return f"{SITE_LABEL}, {self.price_date}"
        return f"{self.price_source}, {'last read' if self.price_stale else 'read'} {self.price_date}"

    @property
    def spend_text(self) -> str:
        return bg.money(self.spend) if self.spend is not None else "unknown"

    @property
    def calls_text(self) -> str:
        return calls_text(self.calls) if self.calls is not None else "unknown"


def model_keys(model: str, aliases) -> list:
    """The labels a spend or call series may carry for a model: its gateway aliases, the model without its provider, the full id."""
    under = model.split("/", 1)[1] if "/" in model else model
    return list(dict.fromkeys([*aliases, under, model]))


def _sum(data: dict, keys) -> float | None:
    hit = [k for k in keys if k in data]
    return sum(data[k] for k in hit) if hit else None


def _price(model: str, site: dict, report) -> tuple[dict, str]:
    """({fields of Cost}, "") for a known price, ({}, why) for an unknown one."""
    if model in site:
        p = site[model]
        return {"price_in": p["inPer1M"], "price_out": p["outPer1M"], "price_source": SITE_LABEL, "price_date": p["date"]}, ""
    if report is None:
        return {}, ("no watcher report is available (modelLifecycle.reportFile is not set, or it cannot be read), so the LiteLLM "
                    "price map was not read, and the site has set no price (modelLifecycle.frontier.prices)")
    p = (report.prices or {}).get(model)
    if p:
        return {"price_in": p["inPer1M"], "price_out": p["outPer1M"], "price_source": pr.SOURCE_LABEL, "price_date": p["readAt"],
                "price_stale": bool(p.get("stale"))}, ""
    src = report.price_source or {}
    if not src:
        return {}, ("the watcher did not read prices (modelLifecycle.watch.prices.enabled is false, or the watcher is older), "
                    "and the site has set no price (modelLifecycle.frontier.prices)")
    if not src.get("ok"):
        return {}, f"the LiteLLM price map could not be read ({src.get('reason') or 'no reason given'}) and no earlier price is recorded"
    return {}, "the LiteLLM price map has no price for this model"


def _reading(reading, query: str, what: str, setting: str):
    """(data, window, why-not): data is None when the figure cannot be had."""
    window = bg.window_text(query)
    if reading is None:
        return None, window, f"no {what} query is configured ({setting})"
    if reading.state == "unknown" or not reading.data:
        return None, window, f"the {what} query did not answer, or returned nothing" + (f" ({reading.reason})" if reading.reason else "")
    return dict(reading.data), window, ""


def costs_for(lc, report, spend, demand, models: dict, *, spend_query: str = "", demand_query: str = "") -> dict:
    """{model id: Cost} for `models` ({"provider/model": [gateway aliases that route to it]}).

    lc       the Lifecycle (its frontier_prices are the site's own prices)
    report   the watcher's models.Report, or None when no report is configured
    spend    a sources.Reading of the spend query ({alias or model: USD}), or None when modelLifecycle.budget.spendQuery is not set
    demand   a sources.Reading of the demand query ({alias: requests}), or None
    A Reading that is Unknown is not used: it would pass last good data off as today's figure."""
    site = dict(getattr(lc, "frontier_prices", None) or {})
    sdata, swin, swhy = _reading(spend, spend_query, "spend", "modelLifecycle.budget.spendQuery")
    ddata, dwin, dwhy = _reading(demand, demand_query, "request", "modelLifecycle.demandQuery")
    out = {}
    for model, aliases in models.items():
        fields, why_price = _price(model, site, report)
        reasons = {}
        if why_price:
            reasons["price"] = why_price
        keys = model_keys(model, aliases)
        spent = _sum(sdata, keys) if sdata is not None else None
        if spent is None:
            reasons["spend"] = swhy or "no series for this model or its aliases in the spend query: never called, or not counted"
        n = _sum(ddata, keys) if ddata is not None else None
        if n is None:
            reasons["calls"] = dwhy or "no series for this model or its aliases in the request query: never called, or not counted"
        out[model] = Cost(model, spend=spent, spend_window=swin, calls=n, calls_window=dwin, reasons=reasons, **fields)
    return out


def price_footer(costs: dict) -> str:
    """The line under the table: where the prices came from, and the day. "Prices: LiteLLM price map, read 2026-10-30; set by this
    site for 1 model." With none known: "Prices: unknown." and the reason the first model gives."""
    known = [c for c in costs.values() if c.price_known]
    if not known:
        why = next((c.reasons["price"] for c in costs.values() if c.reasons.get("price")), "")
        return "Prices: unknown" + (f". {why[0].upper() + why[1:]}." if why else ".")
    parts = []
    fresh = sorted({c.price_date for c in known if c.price_source == pr.SOURCE_LABEL and not c.price_stale})
    stale = sorted({c.price_date for c in known if c.price_source == pr.SOURCE_LABEL and c.price_stale})
    if fresh:
        parts.append(f"{pr.SOURCE_LABEL}, read {fresh[-1]}")
    if stale:
        parts.append(f"{pr.SOURCE_LABEL}, last read {stale[-1]} ({sum(1 for c in known if c.price_stale)} model(s), the latest read failed)")
    mine = [c for c in known if c.price_source == SITE_LABEL]
    if mine:
        parts.append(f"{SITE_LABEL} for {len(mine)} model{'s' if len(mine) != 1 else ''}")
    unknown = len(costs) - len(known)
    line = "Prices: " + "; ".join(parts)
    return line + (f"; unknown for {unknown} model{'s' if unknown != 1 else ''}" if unknown else "") + "."


# ---------------------------------------------------------------- top callers

@dataclass(frozen=True)
class TopCallers:
    """Who spent most on a model or family. `callers` is [{caller, label, usd, text}], biggest first; empty means unknown and
    `reason` says why (not configured, no answer, or nothing for these models)."""
    callers: tuple = ()
    window: str = ""
    reason: str = ""


def _clean(v) -> str:
    return "" if v is None or str(v).strip() in NO_LABEL else str(v).strip()


def top_callers(caller_spend, keys, *, limit: int = 5, query: str = "") -> TopCallers:
    """The top `limit` callers by cost for the models whose gateway aliases, model ids or provider-less ids are in `keys`.

    caller_spend  a sources.Reading of modelLifecycle.budget.spendByCallerQuery, or None when it is not set. Its data is a list of
                  {"labels": {...}, "value": USD}. A series is a caller's spend on one model when its model label (model,
                  model_group, requested_model) is in `keys`; its caller is the first non-empty of api_key_alias, team_alias,
                  team, user, end_user, hashed_api_key. Series of one caller are added. A caller with no label at all is listed
                  as "no key alias or team": real spend, no name.
    query         that query's text, for the window in the column header."""
    window = bg.window_text(query)
    if caller_spend is None:
        return TopCallers((), window, "no caller query is configured (modelLifecycle.budget.spendByCallerQuery)")
    if caller_spend.state == "unknown" or not caller_spend.data:
        return TopCallers((), window, "the caller spend query did not answer, or returned nothing"
                          + (f" ({caller_spend.reason})" if caller_spend.reason else ""))
    want = set(keys)
    by: dict = {}
    for row in caller_spend.data:
        lab = row.get("labels") or {}
        if not any(lab.get(m) in want for m in MODEL_LABELS):
            continue
        who, via = next(((_clean(lab.get(k)), k) for k in CALLER_LABELS if _clean(lab.get(k))), ("no key alias or team", ""))
        cur = by.setdefault(who, [0.0, via])
        cur[0] += float(row.get("value") or 0)
    ranked = sorted(((who, v[0], v[1]) for who, v in by.items() if v[0] > 0), key=lambda t: (-t[1], t[0]))[:limit]
    if not ranked:
        return TopCallers((), window, "the caller spend query has no spend for these models in the window")
    return TopCallers(tuple({"caller": who, "label": via, "usd": usd, "text": bg.money(usd)} for who, usd, via in ranked), window, "")

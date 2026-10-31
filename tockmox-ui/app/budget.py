# SPDX-License-Identifier: Apache-2.0
"""The Budget page's numbers (TM-1258): per alias, requests over the demand query's window, the local share of traffic, and for
hosted aliases an estimated cost. Pure: the sources are read by the caller and passed in.

Every figure carries where it came from, and a figure nobody has is Unknown, never 0: an alias with no series in the window may
have had no traffic or may not be counted at all, and the page cannot tell which. Local routes carry no per-request charge here;
what they cost is the node, which this page does not price.

    modelLifecycle:
      demandQuery: 'sum by (model_group) (increase(litellm_deployment_success_responses_total[7d]))'   # requests (already read by Profiles)
      budget:
        spendQuery: 'sum by (model_group) (increase(litellm_spend_metric_total[7d]))'   # optional: measured USD per alias or model
        usdPerRequest: {big-hosted-chat: 0.012}                                         # optional: an operator's estimate per alias
        spendByCallerQuery: 'sum by (api_key_alias, model) (increase(litellm_spend_metric_total[7d]))'   # optional (TM-1298): top callers by cost
"""
from __future__ import annotations

import re

from . import nodes as nm
from .sources import DemandSource

WINDOW = re.compile(r"\[(\d+[smhdw])\]")


class SpendSource(DemandSource):
    """USD per alias (or per model) over a window, from the operator's own query. Off until modelLifecycle.budget.spendQuery is set."""
    name = "Gateway spend"

    def evaluate(self, d):
        if not d:
            return "unknown", "the spend query returned no series: is the gateway's Prometheus spend metric on?"
        return "ok", f"{len(d)} series"


class CallerSpendSource(DemandSource):
    """USD per caller and model over a window (TM-1298), from the operator's own query: a series per (caller label, model label).
    Unlike the other two it keeps every label, because which caller spent on which model is the answer. Off until
    modelLifecycle.budget.spendByCallerQuery is set."""
    name = "Gateway spend by caller"

    def fetch(self):
        doc = self._get("/api/v1/query", {"query": self.query})
        if doc.get("status") != "success":
            raise ValueError("query failed")
        return [{"labels": {str(k): str(v) for k, v in r["metric"].items()}, "value": float(r["value"][1])} for r in doc["data"]["result"]]

    def evaluate(self, d):
        if not d:
            return "unknown", "the caller spend query returned no series: is the gateway's Prometheus spend metric on, and does it carry the key or team label?"
        return "ok", f"{len(d)} series"


def window_of(query: str) -> str:
    m = WINDOW.search(query or "")
    return m.group(1) if m else ""


_UNITS = {"s": "s", "m": "min", "h": "h", "d": "d", "w": "w"}


def window_text(query: str) -> str:
    """The window a query covers, for a column header: "[7d]" -> "7 d", "[30d]" -> "30 d"; "" when the query names none."""
    w = window_of(query)
    return f"{w[:-1]} {_UNITS[w[-1]]}" if w else ""


def parse_budget(raw) -> tuple[dict, list]:
    """(settings, problems) from modelLifecycle.budget. A malformed entry is reported and ignored, so one typo does not hide the page."""
    problems, out = [], {"spendQuery": "", "spendByCallerQuery": "", "usdPerRequest": {}}
    if raw in (None, {}):
        return out, problems
    if not isinstance(raw, dict):
        return out, ["modelLifecycle.budget must be a mapping (spendQuery, spendByCallerQuery, usdPerRequest)"]
    for key in ("spendQuery", "spendByCallerQuery"):
        q = raw.get(key, "")
        if isinstance(q, str):
            out[key] = q.strip()
        else:
            problems.append(f"modelLifecycle.budget.{key} must be a PromQL string")
    prices = raw.get("usdPerRequest") or {}
    if not isinstance(prices, dict):
        problems.append("modelLifecycle.budget.usdPerRequest must map an alias to a number")
        prices = {}
    for k, v in prices.items():
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0:
            out["usdPerRequest"][str(k)] = float(v)
        else:
            problems.append(f"modelLifecycle.budget.usdPerRequest.{k} must be a number of dollars, zero or more")
    return out, problems


def hosted_model(entry) -> str:
    """provider/model for a gateway entry that goes to a hosted provider (no api_base of ours), else ""."""
    lp = entry.get("litellm_params") or {}
    full = str(lp.get("model", ""))
    info = entry.get("model_info") or {}
    if "/" in full and not lp.get("api_base") and info.get("endpoint_tier", "external") != "local":
        return full
    return ""


def money(v: float) -> str:
    return "under $0.01" if 0 < v < 0.01 else f"${v:,.2f}"


def build(demand, spend, inv, gateway, settings: dict) -> dict:
    """demand / spend: a sources.Reading (or None when the source is not set up). Returns {rows, local_share, ...} for the template."""
    # a reading that is Unknown keeps its last good data for display elsewhere; here it would pass for today's figure, so it is not used
    req_known = demand is not None and demand.state != "unknown"
    req = dict(demand.data or {}) if req_known else {}
    spent = dict(spend.data or {}) if spend is not None and spend.state != "unknown" and spend.data else {}
    live = [r for r in inv.routes if not r.alias.endswith(nm.NEXT)]
    hosted = {}
    for m in gateway:
        if isinstance(m, dict) and str(m.get("model_name", "")):
            h = hosted_model(m)
            if h and m["model_name"] not in {r.alias for r in live}:
                hosted[str(m["model_name"])] = h
    aliases = [(r.alias, "local", r.model) for r in live] + [(a, "hosted", m) for a, m in hosted.items()]
    known = {a for a, _k, _m in aliases}
    aliases += [(a, "other", "") for a in sorted(req) if a not in known and not a.endswith(nm.NEXT)]
    prices = settings.get("usdPerRequest") or {}
    rows = []
    for alias, kind, model in aliases:
        n = req.get(alias) if req_known else None
        cost = {"state": "na", "usd": None, "text": ""}
        if kind == "hosted":
            under = model.split("/", 1)[1] if "/" in model else model
            key = next((k for k in (alias, under, model) if k in spent), None)
            if key is not None:
                cost = {"state": "measured", "usd": spent[key], "text": money(spent[key]), "how": f"measured: the spend query's series {key!r}"}
            elif alias in prices and n is not None:
                cost = {"state": "estimate", "usd": n * prices[alias], "text": money(n * prices[alias]),
                        "how": f"estimate: {n:,.0f} requests x ${prices[alias]:g} per request, as the operator set"}
            else:
                why = ("no spend query is configured (modelLifecycle.budget.spendQuery)" if spend is None
                       else "the spend query did not answer, or returned nothing" if not spent
                       else "no spend series for this alias or model")
                if alias in prices and n is None:
                    why = "a price is set but the request count is Unknown"
                cost = {"state": "unknown", "usd": None, "text": "Unknown", "how": why}
        rows.append({"alias": alias, "kind": kind, "model": model, "requests": n,
                     "requests_text": f"{n:,.0f}" if n is not None else "Unknown",
                     "requests_why": "" if n is not None else "no series for this alias in the window (never called, or not counted)",
                     "cost": cost})
    counted = [r for r in rows if r["kind"] in ("local", "hosted") and r["requests"] is not None]
    unknown = [r for r in rows if r["kind"] in ("local", "hosted") and r["requests"] is None]
    total = sum(r["requests"] for r in counted)
    loc = sum(r["requests"] for r in counted if r["kind"] == "local")
    share = (loc / total) if counted and total > 0 else None
    for r in rows:
        r["share"] = (r["requests"] / total) if (r["requests"] is not None and r["kind"] in ("local", "hosted") and total > 0) else None
    costs = [r["cost"]["usd"] for r in rows if r["kind"] == "hosted" and r["cost"]["usd"] is not None]
    unk_cost = [r for r in rows if r["kind"] == "hosted" and r["cost"]["state"] == "unknown"]
    return {"rows": rows, "total_requests": total if counted else None, "local_requests": loc if counted else None, "local_share": share,
            "unknown_aliases": [r["alias"] for r in unknown], "hosted_cost": sum(costs) if costs else None, "hosted_cost_text": money(sum(costs)) if costs else "Unknown",
            "hosted_cost_partial": bool(costs) and bool(unk_cost), "hosted_unknown": [r["alias"] for r in unk_cost]}

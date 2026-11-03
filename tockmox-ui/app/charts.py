# SPDX-License-Identifier: Apache-2.0
"""Trend panels from the data Grafana graphs, drawn here as server-side SVG.

specs/tockmox-ui/SPEC.md section 6 (planning repo). Native panels, not iframes: DECISION-2026-10-04 call 4
(server-side reads plus links out) and DESIGN-2026-10-11-tockmox-ui-embedded-grafana (allow_embedding turns
off Grafana's clickjacking protection, and an expired Grafana session cannot finish its sign-in inside a
frame). So no CSP, NetworkPolicy or Grafana change: the UI already reads Prometheus.

Each panel's PromQL lives once, in panels.yaml; tools/gen-dashboard-status.py writes the same expressions
into the Tockmox / Status board. A failed or empty range query reads Unknown with its source line, never a
flat zero (ABSENCE IS NOT GREEN). One cached query per panel per minute, at a coarse step.
"""
from __future__ import annotations

import math
import os
import re
import time
from dataclasses import dataclass, field

import httpx
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PANELS = os.path.join(HERE, "panels.yaml")

OK, WARN, CRIT, UNKNOWN = "ok", "warning", "critical", "unknown"
UNITS = ("percent", "count", "days", "seconds", "usd", "ratio")
PAGES = ("status", "ai-nodes", "ai-models", "platform", "part")
_DUR = re.compile(r"^([0-9]+)([mhd])$")
_NS = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
MAX_SERIES = 6


class PanelError(ValueError):
    pass


def seconds(d: str) -> int:
    m = _DUR.match(str(d))
    if not m:
        raise PanelError(f"duration {d!r} is not like 15m, 2h or 7d")
    return int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)]


@dataclass(frozen=True)
class Panel:
    id: str
    page: str
    title: str
    expr: str
    unit: str
    range: str
    step: str
    describe: str
    legend: str = ""
    warn: float | None = None
    crit: float | None = None
    below: bool = False
    board: str = ""


def parse(doc: dict) -> dict[str, Panel]:
    if not isinstance(doc, dict) or doc.get("version") != 1:
        raise PanelError("panels: version must be 1")
    out: dict[str, Panel] = {}
    for i, raw in enumerate(doc.get("panels") or ()):
        where = f"panels[{i}]"
        if not isinstance(raw, dict):
            raise PanelError(f"{where}: a panel is a mapping")
        extra = set(raw) - {"id", "page", "title", "expr", "unit", "range", "step", "describe", "legend",
                            "warn", "crit", "below", "board"}
        if extra:
            raise PanelError(f"{where}: unknown keys {sorted(extra)}")
        for k in ("id", "page", "title", "expr", "unit", "range", "step", "describe"):
            if not raw.get(k):
                raise PanelError(f"{where}: {k} is required")
        pid = str(raw["id"])
        if pid in out:
            raise PanelError(f"{where}: id {pid!r} is used twice")
        if raw["page"] not in PAGES:
            raise PanelError(f"{where} ({pid}): page must be one of {PAGES}")
        if raw["unit"] not in UNITS:
            raise PanelError(f"{where} ({pid}): unit must be one of {UNITS}")
        seconds(raw["range"]), seconds(raw["step"])
        if "{namespaces}" in raw["expr"] and raw["page"] != "part":
            raise PanelError(f"{where} ({pid}): only a part panel may use {{namespaces}}")
        out[pid] = Panel(id=pid, page=raw["page"], title=str(raw["title"]), expr=str(raw["expr"]).strip(),
                         unit=raw["unit"], range=str(raw["range"]), step=str(raw["step"]),
                         describe=str(raw["describe"]), legend=str(raw.get("legend") or ""),
                         warn=None if raw.get("warn") is None else float(raw["warn"]),
                         crit=None if raw.get("crit") is None else float(raw["crit"]),
                         below=bool(raw.get("below")), board=str(raw.get("board") or ""))
    return out


def load(path: str | None = None) -> dict[str, Panel]:
    with open(path or DEFAULT_PANELS, encoding="utf-8") as fh:
        return parse(yaml.safe_load(fh) or {})


def bind(panel: Panel, namespaces=()) -> str:
    """The expression with {namespaces} filled from DNS labels only. Returns "" (the caller reads Unknown) when
    there is none, or when any is not a DNS label: a panel over part of a part's namespaces would read OK for
    the part it could not see."""
    if "{namespaces}" not in panel.expr:
        return panel.expr
    ns = list(namespaces or ())
    if not ns or not all(_NS.match(n or "") for n in ns):
        return ""
    return panel.expr.replace("{namespaces}", "|".join(ns))


# ------------------------------------------------------------ reading

@dataclass
class Series:
    name: str
    points: list            # [(t, value)], NaN dropped


@dataclass
class PanelView:
    panel: Panel
    state: str = UNKNOWN
    series: list = field(default_factory=list)
    reason: str = ""
    last: float | None = None
    low: float | None = None
    high: float | None = None
    fetched_at: float | None = None
    hidden: int = 0                 # series beyond MAX_SERIES, not drawn (the headline still counts them)
    href: str = ""
    svg: dict = field(default_factory=dict)

    @property
    def id(self):
        return self.panel.id


class RangeReader:
    """Prometheus /api/v1/query_range with a small cache. The UI's Prometheus URL and transport; nothing new."""

    def __init__(self, url: str, timeout: float, transport=None, ttl: float = 60.0, clock=time.time):
        self.url, self.timeout, self.transport, self.ttl, self.clock = url.rstrip("/"), timeout, transport, ttl, clock
        self._cache: dict = {}

    FAIL_TTL = 20.0     # a down Prometheus is asked again after this, not once per panel per page view

    def query(self, expr: str, range_s: int, step_s: int):
        now = self.clock()
        key = (expr, range_s, step_s)
        hit = self._cache.get(key)
        if hit and now - hit[0] < (self.ttl if not isinstance(hit[1], Exception) else self.FAIL_TTL):
            if isinstance(hit[1], Exception):
                raise hit[1]
            return hit[1]
        down = self._cache.get(("__down__",))
        if down and now - down[0] < self.FAIL_TTL:
            raise down[1]                              # one failure answers for every panel for a moment
        end = math.floor(now / 60) * 60                # the current minute: "now" is at most a minute old
        try:
            with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport) as c:
                r = c.get("/api/v1/query_range", params={"query": expr, "start": end - range_s, "end": end, "step": step_s})
                r.raise_for_status()
                doc = r.json()
        except (httpx.TimeoutException, httpx.TransportError) as e:
            self._cache[("__down__",)] = (now, e)
            raise
        except httpx.HTTPError as e:
            self._cache[key] = (now, e)
            raise
        if doc.get("status") != "success":
            raise ValueError("query failed")
        out = (doc["data"]["result"], now, end)
        self._cache[key] = (now, out)
        if len(self._cache) > 256:
            for k in sorted(self._cache, key=lambda k: self._cache[k][0])[:64]:
                self._cache.pop(k, None)
        return out


def _state(p: Panel, v: float | None) -> str:
    if v is None:
        return UNKNOWN
    if p.below:
        if p.crit is not None and v < p.crit:
            return CRIT
        if p.warn is not None and v < p.warn:
            return WARN
        return OK
    if p.crit is not None and p.warn is not None and p.crit == p.warn:
        # a count where any is a problem: critical series decide in read(); here, any is a warning
        return WARN if v >= p.warn else OK
    if p.crit is not None and v >= p.crit:
        return CRIT
    if p.warn is not None and v >= p.warn:
        return WARN
    return OK


def read(reader: RangeReader | None, p: Panel, namespaces=(), board_url: str = "") -> PanelView:
    v = PanelView(panel=p, href=board_url)
    if reader is None or not reader.url:
        v.reason = "Prometheus is not configured"
        return v
    expr = bind(p, namespaces)
    if not expr:
        v.reason = "this part names no namespace this panel can read"
        return v
    try:
        result, fetched, end = reader.query(expr, seconds(p.range), seconds(p.step))
    except httpx.TimeoutException:
        v.reason = "Prometheus timed out"
        return v
    except httpx.HTTPError as e:
        v.reason = f"Prometheus did not answer ({type(e).__name__})"
        return v
    except (ValueError, KeyError, TypeError):
        v.reason = "Prometheus gave an unusable answer"
        return v
    v.fetched_at = fetched
    for r in result:
        pts = []
        for t, val in r.get("values") or ():
            try:
                f = float(val)
            except (TypeError, ValueError):
                continue
            if math.isfinite(f):
                pts.append((float(t), f))
        if pts:
            name = (r.get("metric") or {}).get(p.legend, "") if p.legend else ""
            v.series.append(Series(name=name or p.title, points=pts))
    if not v.series:
        v.reason = "no data in this window"
        return v
    allv = [y for s in v.series for _, y in s.points]
    v.low, v.high = min(allv), max(allv)
    newest = max(s.points[-1][0] for s in v.series)
    stale_after = 2 * seconds(p.step) + 60
    current = [s for s in v.series if end - s.points[-1][0] <= stale_after]
    lasts = [s.points[-1][1] for s in current]
    # The headline: the worst current series (the lowest when low is bad); the sum for alert counts by severity.
    if not current:
        v.last = None
    elif p.legend == "severity":
        v.last = sum(lasts)
    else:
        v.last = min(lasts) if p.below else max(lasts)
    if v.last is None:
        age = int(end - newest)
        v.reason = f"the last sample is {age // 3600}h old" if age >= 3600 else f"the last sample is {age // 60}m old"
        v.state = UNKNOWN
    else:
        v.state = _state(p, v.last)
        if p.legend == "severity" and v.state != OK:
            crit = sum(s.points[-1][1] for s in current if s.name == "critical")
            v.state = CRIT if crit > 0 else WARN
    # Draw at most MAX_SERIES, worst first, so the one that set the headline is always drawn.
    if len(v.series) > MAX_SERIES:
        v.hidden = len(v.series) - MAX_SERIES
        v.series = sorted(v.series, key=lambda s: s.points[-1][1], reverse=not p.below)[:MAX_SERIES]
    v.svg = draw(v)
    return v


# ------------------------------------------------------------ drawing

W, H, PAD = 240, 56, 3


def draw(v: PanelView) -> dict:
    """The polylines for one panel, in a fixed 240 x 56 viewBox, plus the threshold line when there is one.
    Pure geometry; the template writes the <svg>, so no markup is built from data here."""
    pts = [p for s in v.series for p in s.points]
    t0, t1 = min(t for t, _ in pts), max(t for t, _ in pts)
    lo, hi = v.low, v.high
    thr = v.panel.warn
    if thr is not None:
        lo, hi = min(lo, thr), max(hi, thr)
    if v.panel.unit == "percent":
        lo, hi = min(lo, 0.0), max(hi, 100.0)        # a percent is always drawn on 0 to 100: no zoomed-in panic
    elif v.panel.unit in ("count", "usd", "days", "seconds"):
        lo = min(lo, 0.0)
    if hi - lo < 1e-9:
        lo, hi = lo - 1, hi + 1
    span_t = max(t1 - t0, 1.0)

    def xy(t, y):
        return (round(PAD + (t - t0) / span_t * (W - 2 * PAD), 1), round(H - PAD - (y - lo) / (hi - lo) * (H - 2 * PAD), 1))

    lines = []
    for i, s in enumerate(v.series):
        coords = [xy(t, y) for t, y in s.points]
        lines.append({"name": s.name, "n": i, "d": " ".join(f"{x},{y}" for x, y in coords),
                      "last": coords[-1], "value": s.points[-1][1], "dot": len(coords) == 1})
    out = {"w": W, "h": H, "lines": lines}
    if thr is not None:
        out["thr_y"] = xy(t0, thr)[1]
    return out


def fmt(v: float | None, unit: str) -> str:
    if v is None:
        return "–"
    if unit == "percent":
        return f"{v:.0f}%" if abs(v) >= 10 else f"{v:.1f}%"
    if unit == "days":
        return f"{v:.0f} d" if abs(v) >= 10 else f"{v:.1f} d"
    if unit == "seconds":
        return f"{v:.0f} s" if abs(v) >= 10 else f"{v:.1f} s"
    if unit == "usd":
        return f"${v:,.2f}"
    if unit == "ratio":
        return f"{v:.2f}"
    return f"{v:,.0f}" if abs(v) >= 1 or v == 0 else f"{v:.2f}"


def alt(v: PanelView) -> str:
    """The text alternative: the sentence from panels.yaml, then the numbers a sighted reader gets."""
    word = {OK: "OK", WARN: "Warning", CRIT: "Problem", UNKNOWN: "Unknown"}[v.state]
    if v.state == UNKNOWN and v.last is None:
        tail = f" History: low {fmt(v.low, v.panel.unit)}, high {fmt(v.high, v.panel.unit)}." if v.series else ""
        return f"{word}: {v.reason}. {v.panel.describe}{tail}"
    u = v.panel.unit
    bits = [f"now {fmt(v.last, u)}", f"low {fmt(v.low, u)}", f"high {fmt(v.high, u)}"]
    if len(v.series) > 1:
        bits.append("; ".join(f"{s.name} {fmt(s.points[-1][1], u)}" for s in v.series))
    if v.hidden:
        bits.append(f"and {v.hidden} more not drawn")
    return f"{word}: " + ", ".join(bits) + f". {v.panel.describe}"


def board_href(grafana_url: str, panel: Panel, index: int | None = None) -> str:
    """The panel's own board, or its panel on Tockmox / Status. '' when Grafana is not configured."""
    if not grafana_url:
        return ""
    base = grafana_url.rstrip("/")
    if panel.board:
        return f"{base}/d/{panel.board}"
    return f"{base}/d/tockmox-status" + (f"?viewPanel={index}" if index else "")

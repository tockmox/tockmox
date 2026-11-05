# SPDX-License-Identifier: Apache-2.0
"""Feature pages: a feature's pages drawn by the console from page documents its own read API serves.

specs/tockmox-ui/SPEC.md section 9 (Tockmox planning repo), "Contributions are data": a feature contributes where
its pages go and serves what they say as JSON in one small format; the console draws every block with its own
components. Nothing a feature ships runs in the admin origin: no HTML, no script, no style, no template, and a link
that is not http(s) or a console path is refused. docs/administration/feature-pages.md is the operator's view and
the format's reference.

Three parts, each a pure function or a small object, so the tests reach every rule without a server:

  parse_contributes  features.<id>.contributes from the site values, checked at start-up (ConfigError on a key the
                     format does not name, so a typo fails the deploy, not a page view)
  validate           one page document -> (page, None) or (None, "the first thing wrong, with its path")
  PageSource         GET <apiUrl>/pages/<page id> with the feature's bearer token; cached briefly; every failure is
                     a reason string the page shows as Unknown, never an exception and never an empty page that
                     reads as "nothing to see"
"""
from __future__ import annotations

import calendar
import json
import math
import re
import threading
import time
from dataclasses import dataclass, field

import httpx

FORMAT = "tockmox.page/v1"
PAGE_ID_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")      # always .fullmatch: "$" would accept a trailing newline
SECTIONS_FOR_RAIL = ("ai", "platform")       # a rail contribution goes into an existing section's rail
MAX_SECTIONS = 2                             # SPEC section 9: at most two contributed sections in the top bar
MAX_PAGES = 12
STATES = ("ok", "warning", "critical", "unknown")
TONES = STATES + ("neutral",)

# Limits on one document. A document past any of them is refused whole, with the limit named: a page that drew the
# first 500 rows of 5000 would look complete.
MAX_BYTES = 1_000_000
MAX_BLOCKS = 40
MAX_TEXT = 600
MAX_TITLE = 120
MAX_ROWS = 500
MAX_COLS = 12
MAX_LANES = 8
MAX_LANE_ITEMS = 200
MAX_STATS = 12
MAX_SERIES = 6
MAX_POINTS = 104
MAX_ABS = 1e15                               # a bigger number is a mistake, and 10**400 would overflow the chart maths


class PageError(ValueError):
    """A document the console will not draw. The message names the path of the first thing wrong."""


# ---------------------------------------------------------------- contributes (site values, start-up)

@dataclass(frozen=True)
class PageRef:
    id: str
    title: str


@dataclass(frozen=True)
class Contribution:
    section: bool                       # its own top-bar section, labelled with the feature's name
    rail_section: str | None            # or: pages in an existing section's rail ...
    rail_group: str | None              # ... under this group heading
    pages: tuple[PageRef, ...]


def parse_contributes(fid: str, raw, admin_only: bool = True) -> Contribution:
    """features.<fid>.contributes -> Contribution, or ConfigError-shaped ValueError naming the key."""
    where = f"features.{fid}.contributes"
    if not isinstance(raw, dict):
        raise ValueError(f"{where} must be a mapping")
    extra = set(raw) - {"section", "rail", "pages"}
    if extra:
        raise ValueError(f"{where}: {', '.join(sorted(extra))} is not a contribution this version draws "
                         "(section, rail, pages)")
    section = raw.get("section", False)
    if not isinstance(section, bool):
        raise ValueError(f"{where}.section must be true or false")
    rail = raw.get("rail")
    rail_section = rail_group = None
    if rail is not None:
        if not isinstance(rail, dict) or set(rail) - {"section", "group"}:
            raise ValueError(f"{where}.rail takes section and group only")
        rail_section, rail_group = rail.get("section"), rail.get("group")
        if rail_section not in SECTIONS_FOR_RAIL:
            raise ValueError(f"{where}.rail.section must be one of {', '.join(SECTIONS_FOR_RAIL)}")
        if not isinstance(rail_group, str) or not rail_group.strip() or len(rail_group) > 40:
            raise ValueError(f"{where}.rail.group must be a heading of 1 to 40 characters")
        if not admin_only:
            # members have no AI or Platform section to put a rail in; such a page would be reachable by URL only
            raise ValueError(f"{where}.rail: pages in the AI or Platform rail are for admins; "
                             "a feature open to members (adminOnly: false) takes section: true")
    if section == bool(rail is not None):
        raise ValueError(f"{where}: name exactly one place for the pages, section: true or a rail")
    pages = raw.get("pages")
    if not isinstance(pages, list) or not pages or len(pages) > MAX_PAGES:
        raise ValueError(f"{where}.pages must list 1 to {MAX_PAGES} pages")
    refs, seen = [], set()
    for i, p in enumerate(pages):
        if not isinstance(p, dict) or set(p) - {"id", "title"}:
            raise ValueError(f"{where}.pages[{i}] takes id and title only")
        pid, title = p.get("id"), p.get("title")
        if not isinstance(pid, str) or not PAGE_ID_RE.fullmatch(pid):
            raise ValueError(f"{where}.pages[{i}].id must be lowercase letters, digits and hyphens")
        if pid in seen:
            raise ValueError(f"{where}.pages[{i}].id {pid!r} is listed twice")
        if not isinstance(title, str) or not title.strip() or len(title) > 40:
            raise ValueError(f"{where}.pages[{i}].title must be 1 to 40 characters")
        seen.add(pid)
        refs.append(PageRef(pid, title.strip()))
    return Contribution(section=section, rail_section=rail_section,
                        rail_group=rail_group.strip() if rail_group else None, pages=tuple(refs))


# ---------------------------------------------------------------- the document format

def _check_keys(obj, allowed, path):
    if not isinstance(obj, dict):
        raise PageError(f"{path} must be an object")
    extra = set(obj) - set(allowed)
    if extra:
        raise PageError(f"{path}.{sorted(extra)[0]} is not in {FORMAT}")


def _text(v, path, limit=MAX_TEXT, required=True):
    if v is None and not required:
        return None
    if not isinstance(v, str) or (required and not v.strip()):
        raise PageError(f"{path} must be text")
    if len(v) > limit:
        raise PageError(f"{path} is over {limit} characters")
    return v


def _num(v, path, required=True):
    if v is None and not required:
        return None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or (isinstance(v, float) and not math.isfinite(v)):
        raise PageError(f"{path} must be a finite number")
    if abs(v) > MAX_ABS:
        raise PageError(f"{path} is too large a number to draw")
    return v


def _state(v, path, tones=STATES):
    if v is None:
        return None
    if v not in tones:
        raise PageError(f"{path} must be one of {', '.join(tones)}")
    return v


def safe_href(v, path):
    """A link the page may carry: http(s) to a named host, or a console path. Never javascript:, data:, a
    protocol-relative //host or a backslash trick."""
    if v is None:
        return None
    if not isinstance(v, str) or len(v) > 2000 or any(c in v for c in "\\\x00\r\n\t "):
        raise PageError(f"{path} is not a link this page may carry")
    if v.startswith("/") and not v.startswith("//"):
        return v
    m = re.match(r"^https?://([^/?#]*)(?:[/?#]|$)", v, re.IGNORECASE)    # the whole authority: no user@ trick
    host = m.group(1) if m else ""
    # a named host, not an IP: one unambiguous pattern, then a letter check (no nested quantifiers to backtrack on)
    if m and re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]{1,5})?", host) and any(c.isalpha() for c in host.split(":")[0]):
        return v
    raise PageError(f"{path} is not a link this page may carry (https://, http:// or a console path only)")


def _cell(c, path):
    if isinstance(c, bool):
        raise PageError(f"{path} must be text, a number or a cell object")
    if isinstance(c, (int, float)):
        return {"text": fmt_num(_num(c, path)), "num": True}
    if isinstance(c, str):
        return {"text": _text(c, path, required=False) or ""}
    _check_keys(c, ("text", "href", "state", "mono", "note"), path)
    if c.get("state") is not None and c.get("href") is not None:
        raise PageError(f"{path} has a state and a link; a status cell carries no link")
    if not isinstance(c.get("mono", False), bool):
        raise PageError(f"{path}.mono must be true or false")
    out = {"text": _text(c.get("text"), path + ".text", required=False) or "",
           "href": safe_href(c.get("href"), path + ".href"),
           "state": _state(c.get("state"), path + ".state", TONES),
           "mono": bool(c.get("mono", False)),
           "note": _text(c.get("note"), path + ".note", required=False)}
    return out


def fmt_num(v) -> str:
    if v is None:
        return "–"
    if isinstance(v, int) or float(v).is_integer():
        return f"{int(v):,}"
    return f"{v:,.1f}" if abs(v) >= 10 else f"{v:,.2f}"


def _stats(b, path):
    _check_keys(b, ("type", "title", "items"), path)
    items = b.get("items")
    if not isinstance(items, list) or not items or len(items) > MAX_STATS:
        raise PageError(f"{path}.items must list 1 to {MAX_STATS} figures")
    out = []
    for i, it in enumerate(items):
        p = f"{path}.items[{i}]"
        _check_keys(it, ("label", "value", "unit", "note", "state", "delta", "better"), p)
        val = it.get("value")
        if val is None:
            shown = "–"
        elif isinstance(val, str):
            shown = _text(val, p + ".value", 40)
        else:
            shown = fmt_num(_num(val, p + ".value"))
        unit = _text(it.get("unit"), p + ".unit", 20, required=False)
        delta = _num(it.get("delta"), p + ".delta", required=False)
        better = it.get("better")
        if better not in (None, "up", "down"):
            raise PageError(f"{p}.better must be up or down")
        trend = None
        if delta is not None and delta != 0 and better:
            trend = "good" if (delta > 0) == (better == "up") else "bad"
        out.append({"label": _text(it.get("label"), p + ".label", 60), "value": shown, "unit": unit,
                    "note": _text(it.get("note"), p + ".note", 160, required=False),
                    "state": _state(it.get("state"), p + ".state", TONES),
                    "delta": None if delta is None else (("+" if delta > 0 else "") + fmt_num(delta)),
                    "trend": trend})
    return {"type": "stats", "title": _text(b.get("title"), path + ".title", MAX_TITLE, required=False), "items": out}


W, H, PAD = 600, 180, 8


def chart_geometry(kind, x, series):
    """The marks for one chart in a fixed 600 x 180 viewBox: polylines for a line chart, rects for a bar chart
    (grouped when there are several series). Pure geometry; the template writes the <svg>, so no markup is built
    from data. A null value is a gap, never a zero."""
    vals = [v for s in series for v in s["values"] if v is not None]
    hi = max(vals) if vals else 1.0
    lo = min(0.0, min(vals)) if vals else 0.0
    if hi - lo < 1e-9:
        hi = lo + 1
    n = len(x)

    def y(v):
        return round(H - PAD - (v - lo) / (hi - lo) * (H - 2 * PAD), 1)

    out = {"w": W, "h": H, "kind": kind, "lines": [], "bars": [], "zero": y(0.0), "hi": hi,
           "top": {"y": y(hi), "t": fmt_num(hi)}}     # one scale mark: the top value, on a faint rule
    if kind == "line":
        step = (W - 2 * PAD) / max(n - 1, 1)
        for si, s in enumerate(series):
            segs, cur = [], []
            for i, v in enumerate(s["values"]):
                if v is None:
                    if cur:
                        segs.append(cur)
                    cur = []
                    continue
                cur.append(f"{round(PAD + i * step, 1)},{y(v)}")
            if cur:
                segs.append(cur)
            out["lines"].append({"n": si, "segs": [" ".join(sg) for sg in segs],
                                 "dots": [s2[0] for s2 in segs if len(s2) == 1]})
    else:
        slot = (W - 2 * PAD) / max(n, 1)
        k = max(len(series), 1)
        bw = max(slot * 0.8 / k, 1.0)
        for si, s in enumerate(series):
            for i, v in enumerate(s["values"]):
                if v is None:
                    continue
                top, base = y(max(v, 0.0)), y(min(v, 0.0))
                out["bars"].append({"n": si, "x": round(PAD + i * slot + slot * 0.1 + si * bw, 1),
                                    "y": top, "w": round(bw - 1, 1), "h": max(round(base - top, 1), 0.5)})
    # x labels: every label when few, else about eight evenly spaced, always the last
    every = max(1, math.ceil(n / 8))
    centre = (lambda i: PAD + i * ((W - 2 * PAD) / max(n - 1, 1))) if kind == "line" else \
             (lambda i: PAD + (i + 0.5) * ((W - 2 * PAD) / max(n, 1)))
    out["xlabels"] = [{"x": round(centre(i), 1), "t": x[i]} for i in range(n) if i % every == 0 or i == n - 1]
    return out


def _chart(b, path):
    _check_keys(b, ("type", "title", "kind", "unit", "x", "series", "describe"), path)
    kind = b.get("kind", "line")
    if kind not in ("line", "bar"):
        raise PageError(f"{path}.kind must be line or bar")
    x = b.get("x")
    if not isinstance(x, list) or not x or len(x) > MAX_POINTS:
        raise PageError(f"{path}.x must list 1 to {MAX_POINTS} labels")
    x = [_text(t, f"{path}.x[{i}]", 20) for i, t in enumerate(x)]
    series = b.get("series")
    if not isinstance(series, list) or not series or len(series) > MAX_SERIES:
        raise PageError(f"{path}.series must list 1 to {MAX_SERIES} series")
    out_s = []
    for i, s in enumerate(series):
        p = f"{path}.series[{i}]"
        _check_keys(s, ("name", "values"), p)
        vals = s.get("values")
        if not isinstance(vals, list) or len(vals) != len(x):
            raise PageError(f"{p}.values must have one value per x label ({len(x)})")
        out_s.append({"name": _text(s.get("name"), p + ".name", 40),
                      "values": [_num(v, f"{p}.values[{j}]", required=False) for j, v in enumerate(vals)]})
    unit = _text(b.get("unit"), path + ".unit", 20, required=False)
    title = _text(b.get("title"), path + ".title", MAX_TITLE)
    describe = _text(b.get("describe"), path + ".describe", MAX_TEXT, required=False)
    # the text alternative carries every number a sighted reader gets from the marks
    alt_rows = [f"{s['name']}: " + ", ".join(f"{x[j]} {fmt_num(v)}" for j, v in enumerate(s["values"]) if v is not None)
                for s in out_s]
    return {"type": "chart", "title": title, "kind": kind, "unit": unit, "x": x, "series": out_s,
            "describe": describe, "alt": (describe + " " if describe else "") + "; ".join(alt_rows) + ".",
            "svg": chart_geometry(kind, x, out_s),
            "last": [{"name": s["name"], "value": fmt_num(next((v for v in reversed(s["values"]) if v is not None), None))}
                     for s in out_s]}


def _table(b, path):
    _check_keys(b, ("type", "title", "caption", "columns", "rows"), path)
    cols = b.get("columns")
    if not isinstance(cols, list) or not cols or len(cols) > MAX_COLS:
        raise PageError(f"{path}.columns must list 1 to {MAX_COLS} columns")
    out_c = []
    for i, c in enumerate(cols):
        p = f"{path}.columns[{i}]"
        if isinstance(c, str):
            c = {"label": c}
        _check_keys(c, ("label", "align"), p)
        if c.get("align") not in (None, "start", "end"):
            raise PageError(f"{p}.align must be start or end")
        out_c.append({"label": _text(c.get("label"), p + ".label", 40), "align": c.get("align") or "start"})
    rows = b.get("rows")
    if not isinstance(rows, list) or len(rows) > MAX_ROWS:
        raise PageError(f"{path}.rows must list at most {MAX_ROWS} rows")
    out_r = []
    for i, r in enumerate(rows):
        p = f"{path}.rows[{i}]"
        if not isinstance(r, list) or len(r) != len(out_c):
            raise PageError(f"{p} must have one cell per column ({len(out_c)})")
        out_r.append([_cell(c, f"{p}[{j}]") for j, c in enumerate(r)])
    return {"type": "table", "title": _text(b.get("title"), path + ".title", MAX_TITLE, required=False),
            "caption": _text(b.get("caption"), path + ".caption", required=False), "columns": out_c, "rows": out_r}


def _lanes(b, path):
    _check_keys(b, ("type", "title", "lanes"), path)
    lanes = b.get("lanes")
    if not isinstance(lanes, list) or not lanes or len(lanes) > MAX_LANES:
        raise PageError(f"{path}.lanes must list 1 to {MAX_LANES} lanes")
    out = []
    for i, ln in enumerate(lanes):
        p = f"{path}.lanes[{i}]"
        _check_keys(ln, ("label", "state", "items", "empty"), p)
        items = ln.get("items")
        if not isinstance(items, list) or len(items) > MAX_LANE_ITEMS:
            raise PageError(f"{p}.items must list at most {MAX_LANE_ITEMS} items")
        its = []
        for j, it in enumerate(items):
            q = f"{p}.items[{j}]"
            _check_keys(it, ("text", "href", "meta", "state", "tag"), q)
            its.append({"text": _text(it.get("text"), q + ".text"), "href": safe_href(it.get("href"), q + ".href"),
                        "meta": _text(it.get("meta"), q + ".meta", 160, required=False),
                        "tag": _text(it.get("tag"), q + ".tag", 24, required=False),
                        "state": _state(it.get("state"), q + ".state", TONES)})
        out.append({"label": _text(ln.get("label"), p + ".label", 40), "state": _state(ln.get("state"), p + ".state", TONES),
                    "items": its, "empty": _text(ln.get("empty"), p + ".empty", 120, required=False)})
    return {"type": "lanes", "title": _text(b.get("title"), path + ".title", MAX_TITLE, required=False), "lanes": out}


def _note(b, path):
    _check_keys(b, ("type", "title", "text", "state"), path)
    return {"type": "note", "title": _text(b.get("title"), path + ".title", MAX_TITLE, required=False),
            "text": _text(b.get("text"), path + ".text", 2000), "state": _state(b.get("state"), path + ".state", TONES)}


BLOCKS = {"stats": _stats, "chart": _chart, "table": _table, "lanes": _lanes, "note": _note}


def _iso(v, path):
    if not isinstance(v, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", v):
        raise PageError(f"{path} must be a UTC time like 2026-11-05T06:00:00Z")
    try:
        return float(calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        raise PageError(f"{path} is not a real date and time") from None


def validate(doc, now: float | None = None) -> dict:
    """One page document -> the page the template draws. Raises PageError naming the first thing wrong."""
    _check_keys(doc, ("format", "title", "lede", "generated_at", "source", "stale_after_s", "blocks"), "page")
    if doc.get("format") != FORMAT:
        raise PageError(f"page.format must be {FORMAT!r}")
    gen = _iso(doc.get("generated_at"), "page.generated_at")
    stale_after = _num(doc.get("stale_after_s"), "page.stale_after_s", required=False)
    blocks = doc.get("blocks")
    if not isinstance(blocks, list) or len(blocks) > MAX_BLOCKS:
        raise PageError(f"page.blocks must list at most {MAX_BLOCKS} blocks")
    out = []
    for i, b in enumerate(blocks):
        p = f"page.blocks[{i}]"
        t = b.get("type") if isinstance(b, dict) else None
        if t not in BLOCKS:
            raise PageError(f"{p}.type {t!r} is not a block in {FORMAT} ({', '.join(BLOCKS)})")
        out.append(BLOCKS[t](b, p))
    pg = {"title": _text(doc.get("title"), "page.title", MAX_TITLE),
          "lede": _text(doc.get("lede"), "page.lede", required=False),
          "source": _text(doc.get("source"), "page.source", 80),
          "generated_at": gen, "stale_after_s": stale_after, "blocks": out}
    return dict(pg, **freshness(pg, now))


def freshness(pg: dict, now: float | None = None) -> dict:
    """Age and staleness as of NOW, not as of the fetch: a cached reading must not freeze "generated 2 minutes ago"."""
    now = time.time() if now is None else now
    age = max(0.0, now - pg["generated_at"])
    return {"age_s": age, "stale": pg.get("stale_after_s") is not None and age > pg["stale_after_s"]}


# ---------------------------------------------------------------- fetching

@dataclass
class PageReading:
    page: dict | None = None
    reason: str = ""                   # why there is no page, in words the page shows
    fetched_at: float | None = None


@dataclass
class PageSource:
    """One feature's page documents. GET <api_url>/pages/<id>, bearer token from token_file when set."""
    api_url: str
    timeout: float = 5.0
    token_file: str = ""
    transport: object = None
    ttl: float = 30.0
    clock: object = time.time
    _cache: dict = field(default_factory=dict)
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def read(self, page_id: str) -> PageReading:
        if not isinstance(page_id, str) or not PAGE_ID_RE.fullmatch(page_id):
            return PageReading(reason="not a page id")
        now = self.clock()
        with self._lock:
            hit = self._cache.get(page_id)
            if hit and now - hit[0] < self.ttl:
                return hit[1]
        try:
            rd = self._fetch(page_id, now)
        except Exception as e:  # noqa: BLE001 - the module's promise: a reason, never an exception
            rd = PageReading(reason=f"the page could not be read ({type(e).__name__})")
        with self._lock:
            self._cache[page_id] = (now, rd)
        return rd

    def _fetch(self, page_id, now) -> PageReading:
        if not self.api_url:
            return PageReading(reason="the feature has no apiUrl")
        headers = {"Accept": "application/json", "Accept-Encoding": "identity"}
        if self.token_file:
            try:
                with open(self.token_file, encoding="utf-8") as fh:
                    headers["Authorization"] = "Bearer " + fh.read().strip()
            except OSError:
                return PageReading(reason="its token file cannot be read")
        try:
            with httpx.Client(base_url=self.api_url.rstrip("/") + "/", timeout=self.timeout,
                              transport=self.transport, headers=headers, follow_redirects=False) as c:
                with c.stream("GET", f"pages/{page_id}") as r:
                    if r.status_code != 200:
                        return PageReading(reason=f"its read API answered HTTP {r.status_code}")
                    ctype = r.headers.get("content-type", "")
                    if "json" not in ctype:
                        return PageReading(reason="its read API did not answer JSON")
                    if r.headers.get("content-encoding", "identity").lower() not in ("", "identity"):
                        return PageReading(reason="its read API answered compressed, which this console does not read")
                    # the timeout above is per read; this bounds the whole answer, so a server that drips a byte
                    # every few seconds cannot hold a worker for longer than one timeout
                    deadline = time.monotonic() + self.timeout
                    body = b""
                    for chunk in r.iter_bytes():      # identity only (checked above), so no decompression happens here
                        body += chunk
                        if len(body) > MAX_BYTES:
                            return PageReading(reason=f"the page is over {MAX_BYTES // 1000} kB, so it was not drawn")
                        if time.monotonic() > deadline:
                            return PageReading(reason="its read API took too long to answer")
        except httpx.HTTPError as e:
            return PageReading(reason=f"its read API did not answer ({type(e).__name__})")
        try:
            doc = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, RecursionError):
            return PageReading(reason="its read API answered something that is not JSON")
        try:
            return PageReading(page=validate(doc, now), fetched_at=now)
        except PageError as e:
            return PageReading(reason=f"the page is not in the format this console draws: {e}")


def registry(features, apps=()) -> dict:
    """{feature id: Contribution} for every feature whose values name `contributes`, checked when the app starts, so
    a typo fails the deploy and not a page view. A feature without `contributes` is not looked at."""
    from .config import ConfigError
    out = {}
    for f in features:
        raw = f.options.get("contributes")
        if raw is None:
            continue
        if not PAGE_ID_RE.fullmatch(str(f.id)):
            raise ConfigError(f"features.{f.id}: a feature with pages needs an id of lowercase letters, digits and hyphens")
        try:
            c = parse_contributes(f.id, raw, f.admin_only)
        except ValueError as e:
            raise ConfigError(str(e)) from None
        if f.enabled and not f.options.get("apiUrl"):
            raise ConfigError(f"features.{f.id}: a feature with pages needs apiUrl, the read API that serves them")
        if f.options.get("origin") not in (None, "private"):
            raise ConfigError(f"features.{f.id}.origin: the only marker a feature may carry is private")
        tf = f.options.get("tokenFile")
        if tf is not None and not str(tf).startswith("/"):
            raise ConfigError(f"features.{f.id}.tokenFile must be an absolute path")
        out[f.id] = c
    on = [f for f in features if f.enabled and f.id in out]
    sections = [f.id for f in on if out[f.id].section]
    if len(sections) > MAX_SECTIONS:
        raise ConfigError(f"features: at most two features may add a section to the top bar ({', '.join(sections)})")
    # /f/ is a route only while a feature has pages, so "f" is reserved only then (as "platform" is in config.py)
    if on and any(getattr(a, "id", None) == "f" for a in apps):
        raise ConfigError("app id 'f' is reserved by the UI while a feature has pages (features.<id>.contributes)")
    return out


def sources_for(features, reg: dict, timeout: float, transport=None) -> dict:
    """{feature id: PageSource} for every enabled feature that contributes pages."""
    return {f.id: PageSource(str(f.options.get("apiUrl", "")), timeout, str(f.options.get("tokenFile", "") or ""), transport)
            for f in features if f.enabled and f.id in reg}


def age_words(sec: float) -> str:
    sec = int(sec)
    if sec < 120:
        return "just now"
    if sec < 3600:
        return f"{sec // 60} minutes ago"
    if sec < 172800:
        return f"{sec // 3600} hours ago"
    return f"{sec // 86400} days ago"


__all__ = ["FORMAT", "PageError", "Contribution", "PageRef", "parse_contributes", "validate", "PageSource",
           "PageReading", "registry", "sources_for", "safe_href", "chart_geometry", "age_words", "fmt_num",
           "MAX_SECTIONS"]

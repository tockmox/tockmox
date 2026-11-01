# SPDX-License-Identifier: Apache-2.0
"""Status as the stack it is: bands, parts, and which part each signal is about (TM-1305).

specs/tockmox-ui/SPEC.md section 5 (Tockmox planning repo). The sources say things in their own
units: an Argo CD application, an alert, a scrape target, a node. A reader thinks in parts: "the
Forgejo backup is failing", not "four sources disagree". This module maps every signal onto one part
of the stack declared in stack.yaml (DATA, read the header there for the rules) and states each part
once, so four signals about one backup count once everywhere: the pill, Home, Status.

Pure functions over the readings the routes already hold; no I/O except loading the YAML.
ABSENCE IS NOT GREEN: a part that nothing reports on, or whose sources did not answer, is Unknown.
"""
from __future__ import annotations

import fnmatch
import os
import re
from dataclasses import dataclass, field, replace

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_STACK = os.path.join(HERE, "stack.yaml")

OK, WARN, CRIT, UNKNOWN = "ok", "warning", "critical", "unknown"
# Worst first. A real problem outranks "could not tell", which outranks a warning: the same order as
# the page verdict (main.verdict).
_ORDER = (CRIT, UNKNOWN, WARN, OK)
RANK = {s: i for i, s in enumerate(_ORDER)}

# Which reading a part's declaration depends on. A part with none of these reads Unknown.
_SOURCE_KEYS = {"apps": "apps", "nodes": "nodes", "inference_nodes": "inference_nodes", "prometheus": "prometheus"}
LAYER_PATH = re.compile(r"^charts/tockmox-([a-z]+)$")
# install/tockmox-install.sh ALL_LAYERS
LAYERS = ("crds", "policy", "platform", "observability", "exporters", "identity", "devops", "ai", "selfcheck")


class StackError(ValueError):
    pass


@dataclass(frozen=True)
class Part:
    id: str
    name: str
    band: str = ""
    layer: str = ""                       # the Tockmox layer whose Argo CD application is this part's signal
    apps: tuple = ()                      # Argo CD application name globs
    alerts: tuple = ()                    # alertname globs
    namespaces: tuple = ()
    jobs: tuple = ()                      # scrape job globs
    source: str = ""                      # a whole reading: apps | nodes | inference_nodes | prometheus
    when: tuple = ()                      # ((layer, kind, name regex), ...): ANY deployed shows the part
    goto: tuple = ()                      # ((kind, value), ...): app | grafana
    runbook: str = ""
    about: str = ""
    site: bool = False                    # a site app, not part of Tockmox
    auto: bool = False                    # made by the mapper (a band's layer part, Unplaced, a site app)


@dataclass(frozen=True)
class Band:
    id: str
    name: str
    sub: str = ""
    wave: str = ""
    layers: tuple = ()
    namespaces: tuple = ()
    parts: tuple = ()
    site_apps: bool = False


@dataclass(frozen=True)
class Stack:
    bands: tuple
    side: tuple


# ------------------------------------------------------------ loading

def _t(v) -> tuple:
    if v is None:
        return ()
    if isinstance(v, (list, tuple)):
        return tuple(str(x) for x in v)
    if isinstance(v, dict):
        raise StackError(f"expected a list of strings, got a mapping: {v!r}")
    return (str(v),)


_PART_KEYS = {"id", "name", "layer", "apps", "alerts", "namespaces", "jobs", "source", "when", "goto", "runbook", "about"}
_BAND_KEYS = {"id", "name", "sub", "wave", "layers", "namespaces", "parts", "site_apps"}
_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")


def _part(raw: dict, band: str, where: str) -> Part:
    if not isinstance(raw, dict):
        raise StackError(f"{where}: a part is a mapping")
    extra = set(raw) - _PART_KEYS
    if extra:
        raise StackError(f"{where}: unknown keys {sorted(extra)}")
    pid = str(raw.get("id", ""))
    if not _ID.match(pid):
        raise StackError(f"{where}: id {pid!r} must be lowercase letters, digits and dashes")
    src = str(raw.get("source", "") or "")
    if src and src not in _SOURCE_KEYS:
        raise StackError(f"{where} ({pid}): source must be one of {sorted(_SOURCE_KEYS)}")
    when = []
    for w in _list(raw.get("when"), f"{where} ({pid}).when"):
        if not isinstance(w, (list, tuple)) or len(w) != 3:
            raise StackError(f"{where} ({pid}): each `when` entry is [layer, kind, name regex]")
        try:
            re.compile(str(w[2]))
        except re.error as e:
            raise StackError(f"{where} ({pid}): bad regex {w[2]!r}: {e}") from e
        when.append((str(w[0]), str(w[1]), str(w[2])))
    goto = raw.get("goto") or {}
    if not isinstance(goto, dict) or set(goto) - {"app", "grafana"}:
        raise StackError(f"{where} ({pid}): goto takes app and grafana")
    rb = str(raw.get("runbook", "") or "")
    if rb and (rb.startswith("/") or ".." in rb or not rb.endswith(".md")):
        raise StackError(f"{where} ({pid}): runbook is a docs page relative to docs/, ending .md")
    return Part(id=pid, name=str(raw.get("name") or pid), band=band, layer=str(raw.get("layer", "") or ""),
                apps=_t(raw.get("apps")), alerts=_t(raw.get("alerts")), namespaces=_t(raw.get("namespaces")),
                jobs=_t(raw.get("jobs")), source=src, when=tuple(when),
                goto=tuple((k, str(goto[k])) for k in ("app", "grafana") if goto.get(k)),
                runbook=rb, about=str(raw.get("about", "") or ""))


def _band(raw: dict, where: str) -> Band:
    if not isinstance(raw, dict):
        raise StackError(f"{where}: a band is a mapping")
    extra = set(raw) - _BAND_KEYS
    if extra:
        raise StackError(f"{where}: unknown keys {sorted(extra)}")
    bid = str(raw.get("id", ""))
    if not _ID.match(bid):
        raise StackError(f"{where}: id {bid!r} must be lowercase letters, digits and dashes")
    parts = tuple(_part(p, bid, f"{where}.parts[{i}]") for i, p in enumerate(_list(raw.get("parts"), f"{where}.parts")))
    return Band(id=bid, name=str(raw.get("name") or bid), sub=str(raw.get("sub", "") or ""),
                wave=str(raw.get("wave", "") if raw.get("wave") is not None else ""),
                layers=_t(raw.get("layers")), namespaces=_t(raw.get("namespaces")), parts=parts,
                site_apps=bool(raw.get("site_apps")))


def _list(v, where: str):
    if v is None:
        return ()
    if not isinstance(v, (list, tuple)):
        raise StackError(f"{where} must be a list")
    return v


def parse(doc: dict, site: dict | None = None) -> Stack:
    """The shipped stack, extended by the site's `stack:` (parts added to a band by id, a part with an
    existing id replacing it; new bands placed under the site apps)."""
    if not isinstance(doc, dict) or doc.get("version") != 1:
        raise StackError("stack: version must be 1")
    bands = [_band(b, f"bands[{i}]") for i, b in enumerate(_list(doc.get("bands"), "bands"))]
    side = [_part(p, "", f"side[{i}]") for i, p in enumerate(_list(doc.get("side"), "side"))]
    if site:
        if not isinstance(site, dict) or set(site) - {"bands", "side"}:
            raise StackError("site stack: takes bands and side")
        by_id = {b.id: i for i, b in enumerate(bands)}
        insert_at = next((i + 1 for i, b in enumerate(bands) if b.site_apps), 0)
        for j, raw in enumerate(_list(site.get("bands"), "site bands")):
            sb = _band(raw, f"site bands[{j}]")
            if sb.id in by_id:
                cur = bands[by_id[sb.id]]
                parts = {p.id: p for p in cur.parts}
                for p in sb.parts:
                    parts[p.id] = p
                bands[by_id[sb.id]] = replace(cur, parts=tuple(parts.values()),
                                              namespaces=cur.namespaces + tuple(n for n in sb.namespaces if n not in cur.namespaces))
            else:
                bands.insert(insert_at, sb)
                insert_at += 1
                by_id = {b.id: i for i, b in enumerate(bands)}
        side_by = {p.id: p for p in side}
        for j, raw in enumerate(_list(site.get("side"), "site side")):
            p = _part(raw, "", f"site side[{j}]")
            side_by[p.id] = p
        side = list(side_by.values())
    seen: set = set()
    for p in side + [p for b in bands for p in b.parts]:
        if p.id in seen or p.id == "unplaced":
            raise StackError(f"stack: part id {p.id!r} is used twice (or reserved)")
        seen.add(p.id)
    return Stack(bands=tuple(bands), side=tuple(side))


def load(path: str | None = None, site: dict | None = None) -> Stack:
    with open(path or DEFAULT_STACK, encoding="utf-8") as fh:
        return parse(yaml.safe_load(fh) or {}, site)


# ------------------------------------------------------------ placing signals

def _glob(name: str, pats) -> bool:
    return any(fnmatch.fnmatchcase(name, p) for p in pats)


def layer_of(app: dict) -> str | None:
    """The Tockmox layer an application deploys (its first source path is charts/tockmox-<layer>),
    the rule the capabilities page uses, so a mirror or air-gapped forge reads the same."""
    m = LAYER_PATH.match(str(app.get("path", "")).strip("/"))
    if m:
        return m.group(1)
    # An application with no path (a Helm repository source, a test double) is a layer when it bears a
    # layer's name exactly; any other tockmox-* name stays a site app.
    m = re.match(r"^tockmox-([a-z]+)$", str(app.get("name", "")))
    return m.group(1) if m and m.group(1) in LAYERS else None


def site_groups(names) -> dict:
    """Site application name -> the part it belongs to: an app whose name extends another app's name
    with a dash joins it (forgejo-backup under forgejo); everything else is its own part."""
    names = sorted(set(names))
    out = {}
    for n in names:
        best = n
        for m in names:
            if m != n and n.startswith(m + "-") and len(m) < len(best):
                best = m
        out[n] = best
    return out


def _title(name: str) -> str:
    return name.replace("-", " ").replace("_", " ").strip().capitalize() or name


@dataclass
class PartView:
    part: Part
    state: str = UNKNOWN
    signals: list = field(default_factory=list)   # every signal placed here, ok ones too
    reason: str = ""                               # why Unknown, when it is
    count: str = ""                                # "6/6", or the number of things wrong when more than one
    deps: tuple = ()                               # reading keys this part depends on
    band_name: str = ""

    @property
    def wrong(self):
        """What is wrong, worst first (review, TM-1305): the List row and the drawer lead with it."""
        return sorted((s for s in self.signals if s["state"] != OK), key=lambda s: RANK.get(s["state"], 1))

    @property
    def id(self):
        return self.part.id


@dataclass
class BandView:
    band: Band
    parts: list
    state: str = OK


@dataclass
class Placed:
    bands: list           # BandView, top to bottom; Unplaced first when it holds anything
    side: list            # PartView
    by_id: dict           # part id -> PartView

    def all(self):
        return self.side + [p for b in self.bands for p in b.parts]

    def counts(self) -> dict:
        c = {CRIT: 0, WARN: 0, UNKNOWN: 0, OK: 0}
        for p in self.all():
            c[p.state] = c.get(p.state, 0) + 1
        return c

    def ranked(self):
        """Every part, worst first, then by name: the List view."""
        return sorted(self.all(), key=lambda p: (RANK[p.state], p.part.name.lower()))

    def state(self) -> str:
        states = [p.state for p in self.all()]
        return next((s for s in _ORDER if s in states), UNKNOWN)


def _sig(source, state, what, detail="", since="", href=None):
    return {"source": source, "state": state, "what": what, "detail": detail, "since": since, "href": href}


def place(stack: Stack, readings: dict, pipeline=(), stale_apps=(), since=lambda iso: "") -> Placed:
    """Every signal in `readings` on exactly one part; each part's state from its own signals."""
    pipeline, stale_apps = set(pipeline or ()), set(stale_apps or ())
    ar = readings.get("apps")
    apps = list(ar.data or []) if ar is not None and ar.data else []
    apps_known = ar is not None and ar.fetched_at is not None
    layer_apps: dict[str, list] = {}
    for a in apps:
        lay = layer_of(a)
        if lay:
            layer_apps.setdefault(lay, []).append(a)

    def deployed(when) -> bool:
        if not when or not apps_known:
            return True            # nothing to judge, or cannot tell: show it
        for lay, kind, rx in when:
            for a in layer_apps.get(lay, ()):
                if any(k == kind and re.search(rx, n) for k, n in (a.get("resources") or ())):
                    return True
        return False

    # Which bands and parts this install has.
    present_layers = set(layer_apps)
    bands: list[tuple[Band, list[Part]]] = []
    for b in stack.bands:
        if b.site_apps:
            bands.append((b, []))
            continue
        if b.layers and apps_known and not (set(b.layers) & present_layers):
            continue                # the install does not deploy this band at all
        parts = [p for p in b.parts if deployed(p.when)
                 and not (p.source and p.source != "apps" and p.source not in readings)]
        claimed = {p.layer for p in parts if p.layer}
        for lay in b.layers:
            if lay not in claimed and (lay in present_layers or not apps_known):
                parts.append(Part(id=f"layer-{lay}", name=f"tockmox-{lay}", band=b.id, layer=lay, auto=True,
                                  about=f"The {lay} layer as Argo CD reports it"))
        bands.append((b, parts))
    side = list(stack.side)

    # Site apps: every application that is no Tockmox layer and that no part claims.
    declared = side + [p for _, ps in bands for p in ps]
    unclaimed = [a for a in apps if not layer_of(a) and not any(_glob(a["name"], p.apps) for p in declared)]
    groups = site_groups(a["name"] for a in unclaimed)
    site_band = next((b for b, _ in bands if b.site_apps), None)
    site_parts: dict[str, Part] = {}
    for a in unclaimed:
        g = groups[a["name"]]
        if g not in site_parts:
            site_parts[g] = Part(id=f"site-{g}", name=_title(g), band=site_band.id if site_band else "", site=True,
                                 auto=True, apps=(), about="Site app, not part of Tockmox")
        p = site_parts[g]
        ns = (a.get("namespace"),) if a.get("namespace") and a.get("namespace") not in p.namespaces else ()
        site_parts[g] = replace(p, apps=p.apps + (a["name"],), namespaces=p.namespaces + ns)
    if site_band is not None:
        bands = [(b, list(site_parts.values()) if b.site_apps else ps) for b, ps in bands]
    elif site_parts:
        side.extend(site_parts.values())      # a stack with no site band still shows them

    views: dict[str, PartView] = {}
    order: list[Part] = side + [p for _, ps in bands for p in ps]
    for p in order:
        views[p.id] = PartView(part=p)
    unplaced = PartView(part=Part(id="unplaced", name="Unplaced", auto=True,
                                  about="Signals no part of the stack claims. Add a rule to stack.yaml to place them."))
    band_of_part = {p.id: b for b, ps in bands for p in ps}
    layer_part = {}
    for b, ps in bands:
        for p in ps:
            if p.layer and p.layer not in layer_part:
                layer_part[p.layer] = p.id
    ns_part: dict[str, str] = {}
    for p in order:
        for n in p.namespaces:
            ns_part.setdefault(n, p.id)
    ns_band: dict[str, str] = {}
    for b, ps in bands:
        home = next((p.id for p in ps if p.auto and p.layer), None) or next((layer_part.get(l) for l in b.layers if layer_part.get(l)), None)
        for n in b.namespaces:
            if home:
                ns_band.setdefault(n, home)

    def put(pid, sig):
        (views.get(pid) or unplaced).signals.append(sig)

    # Argo CD applications.
    for a in apps:
        name = a["name"]
        stale = name in stale_apps
        sync, health = a.get("sync", ""), a.get("health", "")
        if stale:
            st = WARN
        elif health in ("Degraded", "Missing"):
            st = CRIT
        elif health in ("Unknown", "") or sync in ("Unknown", ""):
            st = UNKNOWN
        elif sync == "OutOfSync" or health in ("Progressing", "Suspended"):
            st = WARN
        else:
            st = OK
        detail = f"{sync or '?'} · {health or '?'}" + (" · not reconciled recently, last known" if stale else "")
        sig = _sig("apps", st, f"{name} application", detail)
        pid = next((p.id for p in order if _glob(name, p.apps)), None)
        if pid is None and layer_of(a):
            pid = layer_part.get(layer_of(a))
        put(pid, sig)

    # Alerts.
    am = readings.get("alertmanager")
    for x in (am.data or []) if am is not None else []:
        n = x.get("name", "?")
        sev = x.get("severity", "")
        if n in pipeline or sev in ("info", "none"):
            continue
        sig = _sig("alertmanager", CRIT if sev == "critical" else WARN, n, x.get("summary", ""), since(x.get("startsAt", "")))
        comp = x.get("component") or ""
        pid = comp if comp in views else None
        pid = pid or next((p.id for p in order if _glob(n, p.alerts)), None)
        ns = x.get("namespace") or ""
        pid = pid or (ns_part.get(ns) if ns else None) or (ns_band.get(ns) if ns else None)
        put(pid, sig)

    # Scrape targets: up ones count for the part that owns the reading, down ones go to their part.
    pr = readings.get("prometheus")
    targets = list(pr.data or []) if pr is not None and pr.data else []
    for t in targets:
        if t.get("up"):
            continue
        sig = _sig("prometheus", WARN, f"{t.get('job', '?')} scrape target", f"{t.get('instance', '')} is not answering scrapes")
        ns = t.get("namespace") or ""
        pid = next((p.id for p in order if _glob(t.get("job", ""), p.jobs)), None)
        pid = pid or (ns_part.get(ns) if ns else None) or (ns_band.get(ns) if ns else None)
        if pid is None:
            pid = next((p.id for p in order if p.source == "prometheus"), None)
        put(pid, sig)

    # Nodes and inference nodes: whole readings.
    nr = readings.get("nodes")
    nodes = list(nr.data or []) if nr is not None and nr.data else []
    node_part = next((p.id for p in order if p.source == "nodes"), None)
    for n in nodes:
        if n.get("ready") == "Ready":
            continue
        put(node_part, _sig("nodes", CRIT if n.get("ready") == "NotReady" else UNKNOWN, f"{n.get('name', '?')} node",
                            f"{n.get('ready') or 'Unknown'} · kubelet {n.get('version') or '?'}"))
    ir = readings.get("inference_nodes")
    inodes = list(ir.data or []) if ir is not None and ir.data else []
    inode_part = next((p.id for p in order if p.source == "inference_nodes"), None)
    for x in inodes:
        if x.get("state") == "ok":
            continue
        st = x.get("state") if x.get("state") in RANK else UNKNOWN      # an unknown word never crashes the page
        put(inode_part, _sig("inference_nodes", st, x.get("name") or x.get("id", "?"),
                             x.get("why", ""), href=f"/nodes/{x.get('id', '')}"))

    # Each part's state.
    for v in list(views.values()):
        p = v.part
        deps = set()
        if p.source:
            deps.add(_SOURCE_KEYS[p.source])
        if p.layer or p.apps or p.site:
            deps.add("apps")
        if p.alerts or p.namespaces:
            deps.add("alertmanager")
        if p.jobs:
            deps.add("prometheus")
        # Every declared dependency counts, read or not (review, TM-1305): a source this UI does not read is
        # silent, never a pass. Only the ones it reads are listed in the drawer.
        v.deps = tuple(sorted(d for d in deps if readings.get(d) is not None))
        bad = v.wrong
        silent_why = []
        for d in sorted(deps):
            r = readings.get(d)
            if r is None:
                silent_why.append(f"{d}: not read by this UI")
            elif r.state == UNKNOWN:
                silent_why.append(f"{r.source}: {r.reason or 'did not answer'}")
            elif p.source and _SOURCE_KEYS[p.source] == d and not r.data:
                silent_why.append(f"{r.source}: the reading is empty")
        states = {x["state"] for x in bad}
        if silent_why:
            states.add(UNKNOWN)
            v.reason = "; ".join(silent_why)
        if not deps:
            v.state, v.reason = UNKNOWN, "Nothing reports on this part."
        elif states:
            v.state = next(s for s in _ORDER if s in states)
        elif (p.layer or p.apps) and not p.source and not p.alerts and not p.namespaces and not v.signals:
            v.state, v.reason = UNKNOWN, "No Argo CD application matches this part."
        else:
            v.state = OK
        # The number on the chip.
        if p.source == "nodes" and nodes:
            v.count = f"{sum(1 for n in nodes if n.get('ready') == 'Ready')}/{len(nodes)}"
        elif p.source == "inference_nodes" and inodes:
            v.count = f"{sum(1 for x in inodes if x.get('state') == 'ok')}/{len(inodes)}"
        elif p.source == "prometheus" and targets:
            v.count = f"{sum(1 for t in targets if t.get('up'))}/{len(targets)}"
        elif p.source == "apps" and apps:
            v.count = f"{sum(1 for a in apps if a.get('sync') == 'Synced')}/{len(apps)} synced"
        elif len(bad) > 1:
            v.count = str(len(bad))

    if unplaced.signals:
        unplaced.deps = tuple(sorted({x["source"] for x in unplaced.signals if readings.get(x["source"]) is not None}))
        unplaced.state = next(s for s in _ORDER if any(x["state"] == s for x in unplaced.signals))
        if len(unplaced.signals) > 1:
            unplaced.count = str(len(unplaced.signals))
    for p in side:
        views[p.id].band_name = "Beside every band"
    unplaced.band_name = "Unplaced"
    out_bands = []
    if unplaced.signals:
        out_bands.append(BandView(band=Band(id="unplaced", name="Unplaced", sub="no part claims these"), parts=[unplaced],
                                  state=unplaced.state))
    for b, ps in bands:
        pv = [views[p.id] for p in ps]
        if not pv:
            continue
        for v in pv:
            v.band_name = b.name
        st = next((s for s in _ORDER if any(x.state == s for x in pv)), OK)
        out_bands.append(BandView(band=b, parts=pv, state=st))
    by_id = dict(views)
    if unplaced.signals:
        by_id["unplaced"] = unplaced
    shown = {p.id for b in out_bands for p in b.parts} | {p.id for p in side}
    by_id = {k: v for k, v in by_id.items() if k in shown}
    return Placed(bands=out_bands, side=[views[p.id] for p in side], by_id=by_id)


# ------------------------------------------------------------ words

def _n(k: int, one: str, many: str) -> str:
    return f"{k} {one if k == 1 else many}"


def summary(placed: Placed) -> str:
    """'3 parts need a look: 1 problem, 2 warnings. 34 parts are OK.'"""
    c = placed.counts()
    bits = []
    if c[CRIT]:
        bits.append(_n(c[CRIT], "problem", "problems"))
    if c[WARN]:
        bits.append(_n(c[WARN], "warning", "warnings"))
    if c[UNKNOWN]:
        bits.append(f"{c[UNKNOWN]} unknown")
    need = c[CRIT] + c[WARN] + c[UNKNOWN]
    ok = _n(c[OK], "part is OK", "parts are OK") + "."
    if not need:
        return "Every part is OK: " + _n(c[OK], "part", "parts") + "."
    return _n(need, "part needs a look", "parts need a look") + ": " + ", ".join(bits) + ". " + ok


def pill(placed: Placed) -> dict:
    """The health pill on every admin page: parts, not signals."""
    c = placed.counts()
    parts = []
    if c[CRIT]:
        parts.append(_n(c[CRIT], "problem", "problems"))
    if c[WARN]:
        parts.append(_n(c[WARN], "warning", "warnings"))
    if c[UNKNOWN]:
        parts.append(f"{c[UNKNOWN]} unknown")
    if not parts:
        parts = ["All healthy"]
    st = placed.state()
    return {"state": st, "parts": parts, "label": ", ".join(parts) + ". Open Status."}


def problem_parts(placed: Placed) -> list:
    """The parts that need a look, worst first (Home's chips, TM-1307)."""
    out = [p for p in placed.all() if p.state != OK]
    return sorted(out, key=lambda p: (RANK[p.state], p.part.name.lower()))

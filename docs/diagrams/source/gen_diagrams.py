#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate the Tockmox architecture diagrams as SVG (docs/diagrams/README.md).

    python3 docs/diagrams/source/gen_diagrams.py            write docs/diagrams/rendered/*.svg
    python3 docs/diagrams/source/gen_diagrams.py --check    fail when a committed SVG differs
                                                             from a fresh render, or when the
                                                             layer stack disagrees with the charts

Standard library only, so it runs anywhere python3 does and needs no network.
Every label is written here from the current documentation; the page each
diagram illustrates is named beside its function, and a label that page does
not support is a bug. The layer stack reads each chart's sync wave from
charts/*/Chart.yaml and refuses to render when its own rows disagree.

Visual vocabulary (docs/diagrams/README.md has the full legend):
  solid boundary   a trust or ownership boundary
  dashed box       optional, off by default, or outside your control
  solid arrow      normal flow;  dashed arrow  optional or configured flow
  green            local, yours, proven path;  amber  optional or explicit choice
  red              only where data crosses the boundary, or a path that is blocked
  blue             GitOps and control
"""
import argparse
import pathlib
import re
import sys
from xml.sax.saxutils import escape

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE.parent / "rendered"

FONT = ("-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, "
        "'Helvetica Neue', Helvetica, Arial, sans-serif")
INK, INK2, MUTED = "#1F2A24", "#4A5550", "#6B756F"
BG, CARD_EDGE = "#FBFBF8", "#D3D8D2"
PAL = {
    "neutral": ("#FFFFFF", "#7C8781", INK),
    "green": ("#E9F6EC", "#2F8F45", "#17572A"),
    "amber": ("#FFF5E0", "#B7790F", "#6E4A06"),
    "red": ("#FDECEC", "#C62828", "#8E1B1B"),
    "blue": ("#E8F0FB", "#2F67B0", "#1B417A"),
    "ink": ("#F1F3F0", INK, INK),
}


class Svg:
    def __init__(self, w, h, title, desc):
        self.w, self.h, self.title, self.desc = w, h, title, desc
        self.items = []

    def add(self, s):
        self.items.append(s)

    # ---- primitives -------------------------------------------------------
    def rect(self, x, y, w, h, kind="neutral", dashed=False, rx=10, sw=1.6, fill=None):
        f, st, _ = PAL[kind]
        da = ' stroke-dasharray="7 5"' if dashed else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
                 f'fill="{fill or f}" stroke="{st}" stroke-width="{sw}"{da}/>')

    def boundary(self, x, y, w, h, label, kind="ink", dashed=False, sub=None):
        _, st, tc = PAL[kind]
        da = ' stroke-dasharray="9 6"' if dashed else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="none" '
                 f'stroke="{st}" stroke-width="2.4"{da}/>')
        lw = len(label) * 8.9 + 24
        self.add(f'<rect x="{x + 18}" y="{y - 11}" width="{lw}" height="22" rx="4" fill="{BG}"/>')
        self.text(x + 28, y + 5, label, 12.5, "700", color=tc, spacing=1.2)
        if sub:
            self.text(x + 28, y + 24, sub, 11.5, color=MUTED)

    def text(self, x, y, s, size=13, weight="400", anchor="start", color=INK,
             italic=False, spacing=None):
        st = ' font-style="italic"' if italic else ""
        ls = f' letter-spacing="{spacing}"' if spacing else ""
        self.add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" '
                 f'text-anchor="{anchor}" fill="{color}"{st}{ls}>{escape(s)}</text>')

    def lines(self, x, y, rows, size=12.5, lh=None, anchor="start", color=INK2, weight="400"):
        lh = lh or size * 1.35
        for i, r in enumerate(rows):
            self.text(x, y + i * lh, r, size, weight, anchor, color)

    def box(self, x, y, w, h, title, rows=(), kind="neutral", dashed=False, tsize=14,
            rsize=12, center=True, tag=None):
        self.rect(x, y, w, h, kind, dashed)
        tc = PAL[kind][2]
        cx = x + w / 2 if center else x + 14
        anchor = "middle" if center else "start"
        n = len(rows)
        block = tsize + n * rsize * 1.35
        ty = y + (h - block) / 2 + tsize * 0.85
        self.text(cx, ty, title, tsize, "700", anchor, tc)
        self.lines(cx, ty + tsize * 0.55 + rsize * 1.05, list(rows), rsize, anchor=anchor)
        if tag:
            self.tag(x + w - 8, y + 8, tag[0], tag[1])

    def tag(self, xr, y, label, kind):
        f, st, tc = PAL[kind]
        w = len(label) * 6.3 + 14
        self.add(f'<rect x="{xr - w}" y="{y}" width="{w}" height="18" rx="9" fill="{f}" '
                 f'stroke="{st}" stroke-width="1"/>')
        self.text(xr - w / 2, y + 13, label, 10.5, "600", "middle", tc)

    def person(self, cx, cy, label, kind="ink"):
        _, st, tc = PAL[kind]
        self.add(f'<circle cx="{cx}" cy="{cy - 14}" r="9" fill="none" stroke="{st}" stroke-width="2"/>')
        self.add(f'<path d="M {cx - 15} {cy + 16} Q {cx - 15} {cy - 2} {cx} {cy - 2} '
                 f'Q {cx + 15} {cy - 2} {cx + 15} {cy + 16}" fill="none" stroke="{st}" stroke-width="2"/>')
        self.text(cx, cy + 34, label, 12.5, "600", "middle", tc)

    def cloud(self, x, y, w, h, kind="amber", dashed=True):
        f, st, _ = PAL[kind]
        da = ' stroke-dasharray="7 5"' if dashed else ""
        r = h / 2.6
        d = (f"M {x + r} {y + h} "
             f"A {r} {r} 0 0 1 {x + r * 0.7} {y + h * 0.42} "
             f"A {r * 1.05} {r * 1.05} 0 0 1 {x + w * 0.42} {y + h * 0.12} "
             f"A {r * 1.1} {r * 1.1} 0 0 1 {x + w - r * 0.8} {y + h * 0.36} "
             f"A {r * 0.95} {r * 0.95} 0 0 1 {x + w - r * 0.6} {y + h} Z")
        self.add(f'<path d="{d}" fill="{f}" stroke="{st}" stroke-width="1.8"{da}/>')

    def arrow(self, pts, kind="neutral", dashed=False, label=None, lpos=None,
              lanchor="middle", lsize=11.5, head=True, sw=1.8):
        st = PAL[kind][1] if kind != "neutral" else "#5E6963"
        da = ' stroke-dasharray="7 5"' if dashed else ""
        d = "M " + " L ".join(f"{x} {y}" for x, y in pts)
        mk = f' marker-end="url(#ah-{kind})"' if head else ""
        self.add(f'<path d="{d}" fill="none" stroke="{st}" stroke-width="{sw}"{da}{mk}/>')
        if label:
            if lpos is None:
                (x1, y1), (x2, y2) = pts[0], pts[-1]
                lpos = ((x1 + x2) / 2, (y1 + y2) / 2 - 7)
            for i, part in enumerate(label if isinstance(label, (list, tuple)) else [label]):
                self.text(lpos[0], lpos[1] + i * lsize * 1.3, part, lsize, "500", lanchor,
                          PAL[kind][2] if kind != "neutral" else INK2)

    def crossing(self, x, y, label_rows, side="right", dy=4):
        """The red mark where data crosses a trust boundary."""
        _, st, tc = PAL["red"]
        self.add(f'<circle cx="{x}" cy="{y}" r="7" fill="#FFFFFF" stroke="{st}" stroke-width="2.6"/>')
        self.add(f'<circle cx="{x}" cy="{y}" r="2.6" fill="{st}"/>')
        ax = x + 14 if side == "right" else x - 14
        an = "start" if side == "right" else "end"
        self.lines(ax, y + dy, label_rows, 11.5, anchor=an, color=tc, weight="600")

    def blocked(self, x1, y1, x2, y2, label_rows, lx, ly, anchor="start"):
        _, st, tc = PAL["red"]
        self.add(f'<path d="M {x1} {y1} L {x2} {y2}" stroke="{st}" stroke-width="1.8" '
                 f'stroke-dasharray="3 4" fill="none"/>')
        for dx, dy in ((-6, -6), (6, 6)), ((-6, 6), (6, -6)):
            self.add(f'<path d="M {x2 + dx[0]} {y2 + dx[1]} L {x2 + dy[0]} {y2 + dy[1]}" '
                     f'stroke="{st}" stroke-width="2.6" stroke-linecap="round"/>')
        self.lines(lx, ly, label_rows, 11.5, anchor=anchor, color=tc, weight="600")

    def legend(self, x, y, entries, title="Legend", w=230):
        h = 34 + len(entries) * 22
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="#FFFFFF" '
                 f'stroke="{CARD_EDGE}" stroke-width="1.2"/>')
        self.text(x + 12, y + 20, title, 11.5, "700", color=INK2, spacing=1)
        for i, (sym, kind, label) in enumerate(entries):
            yy = y + 38 + i * 22
            f, st, _ = PAL[kind]
            if sym == "box":
                self.add(f'<rect x="{x + 12}" y="{yy - 10}" width="26" height="14" rx="3" fill="{f}" stroke="{st}" stroke-width="1.4"/>')
            elif sym == "dbox":
                self.add(f'<rect x="{x + 12}" y="{yy - 10}" width="26" height="14" rx="3" fill="{f}" stroke="{st}" stroke-width="1.4" stroke-dasharray="4 3"/>')
            elif sym == "bound":
                self.add(f'<rect x="{x + 12}" y="{yy - 10}" width="26" height="14" rx="3" fill="none" stroke="{st}" stroke-width="2.2"/>')
            elif sym in ("arrow", "darrow"):
                c = st if kind != "neutral" else "#5E6963"
                da = ' stroke-dasharray="5 3"' if sym == "darrow" else ""
                self.add(f'<path d="M {x + 12} {yy - 3} L {x + 34} {yy - 3}" stroke="{c}" stroke-width="1.8"{da} marker-end="url(#ah-{kind})"/>')
            elif sym == "cross":
                self.add(f'<circle cx="{x + 25}" cy="{yy - 3}" r="6" fill="#FFFFFF" stroke="{st}" stroke-width="2.4"/>')
                self.add(f'<circle cx="{x + 25}" cy="{yy - 3}" r="2.2" fill="{st}"/>')
            elif sym == "block":
                self.add(f'<path d="M {x + 19} {yy - 9} L {x + 31} {yy + 3} M {x + 19} {yy + 3} L {x + 31} {yy - 9}" stroke="{st}" stroke-width="2.4" stroke-linecap="round"/>')
            self.text(x + 46, yy + 1, label, 11.5, color=INK2)

    # ---- output -----------------------------------------------------------
    def render(self):
        defs = []
        for k in PAL:
            c = PAL[k][1] if k != "neutral" else "#5E6963"
            defs.append(f'<marker id="ah-{k}" viewBox="0 0 10 10" refX="9" refY="5" '
                        f'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                        f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{c}"/></marker>')
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                f'viewBox="0 0 {self.w} {self.h}" role="img" aria-labelledby="t d" '
                f'font-family="{escape(FONT)}">\n'
                f'<title id="t">{escape(self.title)}</title>\n'
                f'<desc id="d">{escape(self.desc)}</desc>\n'
                f'<defs>{"".join(defs)}</defs>\n'
                f'<rect x="1" y="1" width="{self.w - 2}" height="{self.h - 2}" rx="14" '
                f'fill="{BG}" stroke="{CARD_EDGE}" stroke-width="1.5"/>\n')
        return head + "\n".join(self.items) + "\n</svg>\n"


def header(svg, title, sub):
    svg.text(32, 42, title, 21, "700", color=INK)
    svg.text(32, 64, sub, 13, color=MUTED)


# ---------------------------------------------------------------------------
# 1. Platform at a glance ... README.md, docs/architecture.md
#    Sources: README "What is Tockmox?" table, docs/usage/what-you-get.md,
#    docs/usage/ai-plane.md, docs/deployment/prerequisites.md.
# ---------------------------------------------------------------------------
def platform_overview():
    s = Svg(1040, 660, "Tockmox at a glance",
            "Inside a solid boundary for your hardware and your network: a person signs in "
            "through single sign-on to the chat console, which sends every request through the "
            "model gateway to a model host you run, in the cluster or on your network. Around "
            "the AI plane sit identity, policy, storage and certificates, observability with "
            "alerts to a phone, backups with a weekly restore drill for the gateway database, and "
            "a self-check heartbeat. Underneath is the foundation you provide: Kubernetes, Argo CD "
            "and sealed-secrets, reconciling everything from your site repository. Outside the "
            "boundary, a frontier provider is reachable only through the gateway and only if you "
            "configure it; a request sent there takes the conversation with it. The boundary "
            "describes ownership, not an air-gap guarantee.")
    header(s, "Tockmox at a glance",
           "Local first. A frontier model is a route you add, not a default.")
    s.boundary(30, 96, 760, 534, "YOUR HARDWARE / YOUR CONTROL",
               sub="Everything inside this line runs on machines you control")
    # AI plane
    s.text(56, 150, "THE AI PLANE", 11.5, "700", color=PAL["green"][2], spacing=1.2)
    s.person(84, 196, "You")
    s.box(140, 160, 170, 74, "Private chat", ["Open WebUI"], "green")
    s.box(360, 160, 180, 74, "Model gateway", ["LiteLLM · holds the keys"], "green")
    s.box(590, 160, 176, 74, "Local models", ["in the cluster, or on", "your network"], "green", rsize=11.5)
    s.arrow([(106, 197), (136, 197)], "green")
    s.arrow([(310, 197), (356, 197)], "green")
    s.arrow([(540, 197), (586, 197)], "green")
    s.text(333, 254, "every request goes through the gateway", 11.5, "500", "middle", PAL["green"][2])
    # platform tiles
    s.text(56, 296, "PLATFORM", 11.5, "700", color=INK2, spacing=1.2)
    tiles = [
        ("Identity", ["single sign-on", "Authentik"]),
        ("Policy", ["network policy", "admission guardrails"]),
        ("Storage", ["Longhorn · CloudNativePG", "certificates · ingress"]),
        ("Observability", ["Grafana · Prometheus · Loki", "alerts to your phone"]),
        ("Recovery", ["backups, and a weekly restore", "drill for the gateway database"]),
        ("Self-check", ["a heartbeat that proves", "the alerting is alive"]),
    ]
    for i, (t, r) in enumerate(tiles):
        col, row = i % 3, i // 3
        s.box(56 + col * 240, 310 + row * 92, 224, 78, t, r, "neutral", tsize=13.5, rsize=11.5)
    # foundation
    s.rect(56, 508, 708, 92, "blue", rx=10)
    s.text(410, 540, "Kubernetes + GitOps", 16, "700", "middle", PAL["blue"][2])
    s.text(410, 562, "Argo CD reconciles all nine layers from your own site repository",
           12.5, "400", "middle", INK2)
    s.text(410, 584, "You provide Kubernetes, Argo CD and sealed-secrets; Tockmox installs the nine layers",
           12, "400", "middle", INK2)
    # frontier, outside
    s.cloud(830, 158, 186, 104, "amber")
    s.text(923, 210, "Frontier models", 13.5, "700", "middle", PAL["amber"][2])
    s.text(923, 229, "explicit choice", 11.5, "400", "middle", INK2)
    s.arrow([(540, 178), (566, 178), (566, 128), (790, 128), (900, 128), (900, 162)], "amber",
            dashed=True, head=True)
    s.crossing(790, 128, ["data leaves your network"], side="right", dy=-12)
    s.lines(830, 286, ["Only through the gateway,", "only if you add one to the", "model list. HTTPS 443."],
            11.5, color=PAL["amber"][2], weight="500")
    s.legend(812, 352, [
        ("bound", "ink", "your control boundary"),
        ("box", "green", "local: runs on your hardware"),
        ("dbox", "amber", "optional, your explicit choice"),
        ("cross", "red", "data crosses the boundary"),
        ("box", "blue", "GitOps and control"),
        ("box", "neutral", "platform capability"),
    ], w=210)
    return s


# ---------------------------------------------------------------------------
# 2. The GitOps model ... docs/architecture.md § three repositories, not one
#    Sources: architecture.md, deployment/upgrade.md § 5, operations/day-2.md.
# ---------------------------------------------------------------------------
def gitops_model():
    s = Svg(1040, 640, "Tockmox's GitOps model: product repository, site repository, cluster",
            "Tockmox owns the product repository, tockmox/tockmox, which holds the charts, "
            "defaults, values schema and docs, and the site template you start from once. You own "
            "your site repository, holding your values, sealed secrets and your own applications, "
            "and naming the release it tracks in targetRevision. Argo CD, which you also own and "
            "run, composes the chart from the product repository with the values from yours as one "
            "multi-source Application and syncs the result into your cluster. An upgrade changes "
            "targetRevision; a configuration change is a commit. A kubectl edit to a field the "
            "repository declares is reverted at the next reconcile; a field the repository does "
            "not declare is not.")
    header(s, "Three repositories, one cluster",
           "Tockmox supplies the charts. You supply the values. Argo CD composes them at sync time.")
    # Tockmox side
    s.boundary(30, 100, 330, 300, "TOCKMOX OWNS THIS", kind="ink")
    s.box(54, 256, 282, 112, "Tockmox product repo", ["tockmox/tockmox · public",
          "charts · defaults · templates", "versions, released as tags"], "neutral", rsize=12)
    s.box(54, 132, 282, 100, "Site template", ["tockmox/tockmox-site-template",
          "a scaffold, used once", "or: tockmox-install.sh"], "neutral", dashed=True, rsize=12)
    # Your side
    s.boundary(400, 100, 610, 510, "YOU OWN THIS", kind="ink")
    s.box(430, 132, 300, 132, "Your site repo", ["private · yours", "values · sealed secrets",
          "applications · site config", "targetRevision: the tag you track"], "neutral", rsize=12)
    s.box(560, 330, 300, 86, "Argo CD", ["one multi-source Application", "per layer"], "blue")
    s.box(560, 480, 300, 100, "Your cluster", ["the nine Tockmox layers", "and your own applications"],
          "green")
    s.arrow([(336, 182), (426, 182)], "neutral", dashed=True)
    s.arrow([(336, 312), (610, 312), (610, 326)], "blue",
            label="chart, at the tag you pin", lpos=(470, 302))
    s.arrow([(730, 198), (790, 198), (790, 326)], "blue",
            label=["values, secrets,", "your apps"], lpos=(800, 250), lanchor="start")
    s.arrow([(710, 416), (710, 476)], "blue", label="sync", lpos=(722, 452), lanchor="start")
    # notes column
    s.text(54, 448, "TWO CHANGES, ONE PLACE", 11.5, "700", color=INK2, spacing=1.2)
    s.lines(54, 472, ["Upgrade: change targetRevision", "in your site repository."], 12.5, color=INK)
    s.lines(54, 520, ["Configure: commit to your", "site repository."], 12.5, color=INK)
    s.lines(54, 568, ["An upgrade cannot edit a file", "Tockmox does not own."], 12.5, color=PAL["green"][2],
            weight="600")
    # drift loop
    s.rect(886, 448, 108, 132, "amber", dashed=True, rx=8)
    s.lines(940, 470, ["kubectl edit", "temporary state"], 12, anchor="middle", color=PAL["amber"][2],
            weight="700")
    s.lines(940, 512, ["declared state", "wins at the next", "reconcile; an added", "field is not reverted"],
            10.5, anchor="middle", color=INK2)
    s.arrow([(886, 514), (864, 514)], "amber", dashed=True)
    return s


# ---------------------------------------------------------------------------
# 3. The nine layers ... docs/architecture.md § sync waves
#    The wave of every row is checked against charts/*/Chart.yaml.
# ---------------------------------------------------------------------------
LAYER_ROWS = [  # wave, layer, short description, declinable label, dashed
    (0, "crds", ["every CRD, first"], "required", False),
    (1, "policy", ["namespaces · default-deny networking", "RBAC admission guardrails"], "required", False),
    (2, "platform", ["storage · load balancing · ingress", "certificates · databases"], "partly declinable", False),
    (3, "observability", ["metrics · logs · dashboards", "alerting to a phone"], "declinable", False),
    (3, "exporters", ["hardware and network", "telemetry"], "declinable", False),
    (4, "identity", ["single sign-on", "Authentik"], "declinable", False),
    (5, "devops", ["workflows", "off by default"], "declinable", True),
    (5, "ai", ["chat console", "and model gateway"], "declinable", False),
    (5, "selfcheck", ["heartbeat · alerts when", "monitoring goes quiet"], "declinable", False),
]


def chart_waves():
    out = {}
    for cy in sorted(ROOT.glob("charts/tockmox-*/Chart.yaml")):
        t = cy.read_text()
        n = re.search(r"^name:\s*(\S+)", t, re.M)
        w = re.search(r'tockmox\.com/sync-wave:\s*"?(\d+)"?', t)
        if n and n.group(1) != "tockmox-common" and w:
            out[n.group(1).removeprefix("tockmox-")] = int(w.group(1))
    return out


def layer_stack():
    waves = chart_waves()
    mine = {name: wave for wave, name, *_ in LAYER_ROWS}
    if waves and waves != mine:
        raise SystemExit(f"gen_diagrams: layer stack disagrees with charts/: charts {waves}, diagram {mine}")
    s = Svg(1040, 650, "The nine Tockmox layers in six sync waves",
            "Bottom to top. Wave 0: crds, every CRD first, required. Wave 1: policy, namespaces, "
            "default-deny networking and RBAC admission guardrails, required. Wave 2: platform, "
            "storage, load balancing, ingress, certificates and databases, partly declinable. "
            "Wave 3: observability, metrics, logs, dashboards and alerting, beside exporters, "
            "hardware and network telemetry. Wave 4: identity, single sign-on through Authentik. "
            "Wave 5: devops, workflows, off by default; ai, the chat console and model gateway; "
            "selfcheck, the heartbeat. Argo CD waits for each wave to report healthy before "
            "starting the next. Every layer from wave 3 up can be declined. The arrows show the order "
            "of the waves; they do not enumerate every component dependency.")
    header(s, "Nine layers, six waves",
           "Argo CD deploys a wave only after the one below it reports healthy.")
    rows = {}
    for r in LAYER_ROWS:
        rows.setdefault(r[0], []).append(r)
    base_y, rh, gap = 516, 74, 10
    x0, x1 = 150, 1010
    for wave in range(6):
        y = base_y - wave * (rh + gap)
        s.text(40, y + 34, f"WAVE {wave}", 13, "700", color=PAL["blue"][2], spacing=1)
        if wave < 5:
            s.arrow([(70, y - 2), (70, y - gap - 6)], "blue", sw=1.6)
        items = rows[wave]
        n = len(items)
        w = (x1 - x0 - (n - 1) * 14) / n
        for i, (_, name, desc, dec, dashed) in enumerate(items):
            x = x0 + i * (w + 14)
            kind = "amber" if dashed else ("ink" if dec == "required" else "neutral")
            s.rect(x, y, w, rh, kind, dashed)
            s.text(x + 14, y + 26, name, 15, "700", color=PAL[kind][2])
            s.lines(x + 14, y + 46, desc, 11.5, color=INK2)
            tk = {"required": "ink", "partly declinable": "amber", "declinable": "green"}[dec]
            s.tag(x + w - 8, y + 8, dec, tk)
    s.text(40, 626, "Wave numbers are read from each chart's Chart.yaml when this diagram is generated.",
           11.5, color=MUTED)
    return s


# ---------------------------------------------------------------------------
# 4. The AI request path ... docs/usage/ai-plane.md, README.md
#    Sources: ai-plane.md § what ships today, § the egress bundle,
#    § the namespace egress default-deny, § the egress question.
# ---------------------------------------------------------------------------
def ai_request_path():
    s = Svg(1040, 640, "Where a chat request goes in Tockmox",
            "Inside your network and your cluster, the browser reaches the chat console through "
            "ingress and single sign-on. The console holds only a scoped key; its egress is limited "
            "to DNS, the AI namespace and the ingress controller, so it cannot reach a model host "
            "or the internet directly. Every request goes through the model gateway, which holds "
            "the provider credentials and whose model list ships empty. From the gateway: an "
            "optional in-cluster Ollama, off by default; a model host on your network, reachable "
            "once you add an egress entry for it; or, crossing the boundary on HTTPS port 443, a "
            "frontier provider, only if you add one to the model list. Local inference does not by "
            "itself make an installation air-gapped.")
    header(s, "Where a request goes",
           "The route you configure decides where the conversation goes. Nothing routes until you name a model.")
    s.boundary(30, 100, 770, 510, "YOUR NETWORK")
    s.boundary(170, 150, 600, 310, "YOUR CLUSTER", sub="AI namespace: egress denied by default")
    s.person(90, 260, "Browser")
    s.box(196, 220, 150, 86, "Ingress + SSO", ["Traefik · Authentik"], "neutral", tsize=13.5, rsize=11.5)
    s.box(372, 210, 170, 106, "Chat console", ["Open WebUI", "holds a scoped key", "only"], "green",
          rsize=11.5)
    s.box(580, 210, 170, 106, "Model gateway", ["LiteLLM", "holds provider keys", "model list ships empty"],
          "green", rsize=11.5)
    s.arrow([(114, 262), (192, 262)], "neutral")
    s.arrow([(346, 262), (368, 262)], "neutral")
    s.arrow([(542, 262), (576, 262)], "green")
    s.blocked(420, 316, 420, 372, ["the console cannot reach a model", "host or the internet directly"],
              406, 368, anchor="end")
    s.box(580, 360, 170, 76, "Ollama", ["in the cluster", "optional, off by default"], "amber", dashed=True,
          tsize=13.5, rsize=11.5)
    s.arrow([(665, 316), (665, 356)], "amber", dashed=True)
    s.box(400, 500, 230, 82, "Model host on your network", ["a Mac, a GPU box, any", "OpenAI-compatible endpoint"],
          "green", tsize=13.5, rsize=11.5)
    s.arrow([(750, 300), (786, 300), (786, 540), (634, 540)], "green", dashed=True)
    s.lines(650, 488, ["one egress entry for", "its address and port"], 11.5, color=PAL["green"][2],
            weight="500")
    # frontier
    s.cloud(840, 196, 180, 104, "amber")
    s.text(930, 248, "Frontier provider", 13.5, "700", "middle", PAL["amber"][2])
    s.text(930, 267, "outside your control", 11.5, "400", "middle", INK2)
    s.arrow([(750, 236), (836, 236)], "amber", dashed=True)
    s.crossing(800, 236, [], side="right")
    s.lines(840, 328, ["HTTPS 443, only if you add a", "provider to the model list.",
                       "The conversation goes with it."], 11.5, color=PAL["red"][2], weight="600")
    s.legend(830, 420, [
        ("bound", "ink", "trust boundary"),
        ("arrow", "green", "local path"),
        ("darrow", "amber", "only once you configure it"),
        ("cross", "red", "data leaves your network"),
        ("block", "red", "blocked by policy"),
    ], w=196)
    return s


# ---------------------------------------------------------------------------
# 5. The installation journey ... docs/deployment/README.md
#    Sources: deployment/prerequisites.md, install.md (phases), usage/getting-started.md.
# ---------------------------------------------------------------------------
def install_journey():
    s = Svg(1040, 640, "The Tockmox installation journey",
            "Six stages. Prepare: the prerequisites (Kubernetes, Argo CD 2.6 or newer, sealed-secrets "
            "with your own key, four values decided) on a fresh cluster or one you already have. "
            "Generate: the installer writes your site repository and values. Bootstrap: publish it "
            "to git, mint your credentials, apply the root Application. Reconcile: Argo CD brings "
            "the nine layers up in six waves until they are healthy. Configure: trust the CA, "
            "bootstrap Authentik, make your own user, and name a model route. Use: the first chat. "
            "Virtual machines, a registry of your own, and air-gap with time sync are side "
            "branches for the sites that need them. This is a navigation overview, not the "
            "installation procedure.")
    header(s, "From nothing to a first chat",
           "Each stage is a page, or a phase of one. Dashed boxes apply only to some sites.")

    def stage(x, y, label):
        s.text(x, y, label, 12, "700", color=PAL["blue"][2], spacing=1.4)

    W, H = 290, 132
    xs = [40, 375, 710]
    top, bot = 124, 330
    cards = [
        (xs[0], top, "PREPARE", "Your cluster", ["Kubernetes · Argo CD 2.6+", "sealed-secrets, your own key",
                                                  "fresh, or one you already have"], "neutral",
         "prerequisites.md · fresh-install.md · existing-cluster.md"),
        (xs[1], top, "GENERATE", "Your site repository", ["tockmox-install.sh writes it", "your values, from your answers",
                                                          "it applies nothing"], "neutral", "install.md · phase 1"),
        (xs[2], top, "BOOTSTRAP", "Publish and apply", ["push it to git", "mint your credentials",
                                                        "apply the root Application"], "neutral",
         "install.md · phases 2, 2.5 and 3"),
        (xs[2], bot, "RECONCILE", "Argo CD syncs", ["nine layers in six waves", "until every one is healthy",
                                                    "then settle: readiness, DNS"], "blue", "install.md · after the first sync"),
        (xs[1], bot, "CONFIGURE", "Identity and a model", ["trust the CA · Authentik", "make your own user",
                                                           "name a model route"], "neutral",
         "getting-started.md · ai-plane.md"),
        (xs[0], bot, "USE", "First chat", ["sign in through SSO", "send a message"], "green",
         "getting-started.md"),
    ]
    for x, y, st, title, rows, kind, page in cards:
        stage(x, y - 12, st)
        s.box(x, y, W, H, title, rows, kind, tsize=15, rsize=12.5)
        s.text(x + W / 2, y + H + 18, page, 11, color=MUTED, anchor="middle")
    mid = top + H / 2
    s.arrow([(xs[0] + W, mid), (xs[1] - 4, mid)], "neutral")
    s.arrow([(xs[1] + W, mid), (xs[2] - 4, mid)], "neutral")
    s.arrow([(xs[2] + W / 2, top + H + 26), (xs[2] + W / 2, bot - 22)], "blue")
    mid2 = bot + H / 2
    s.arrow([(xs[2], mid2), (xs[1] + W + 4, mid2)], "neutral")
    s.arrow([(xs[1], mid2), (xs[0] + W + 4, mid2)], "green")
    stage(40, 528, "ONLY IF YOUR SITE NEEDS THEM")
    side = [("Virtual machines", "hypervisor settings"), ("A registry of your own", "mirror the images"),
            ("No internet access", "air-gap · time sync")]
    for i, (a, b) in enumerate(side):
        x = 40 + i * 226
        s.box(x, 540, 210, 70, a, [b], "amber", dashed=True, tsize=13.5, rsize=12)
    s.legend(760, 506, [
        ("box", "neutral", "a page or a phase"),
        ("dbox", "amber", "only for some sites"),
        ("box", "blue", "GitOps does this part"),
        ("box", "green", "the goal"),
    ], w=240)
    return s

# ---------------------------------------------------------------------------
# 6. Identity and trust ... docs/administration/identity.md § the shape
#    Sources: identity.md (the shape, groups, forward-auth, break-glass, tiles),
#    tls-and-trust.md, usage/getting-started.md steps 1 to 4.
# ---------------------------------------------------------------------------
def identity_flow():
    s = Svg(1040, 660, "Identity and trust in Tockmox",
            "Your browser runs on a machine whose trust store holds the Tockmox private CA. It "
            "reaches the consoles over HTTPS through the Traefik ingress, with certificates "
            "cert-manager issues from that CA. Authentik is the OIDC provider for three shipped "
            "consoles, Grafana, Open WebUI and Argo Workflows, which exchange the token from "
            "inside their own containers and so need the CA in the cluster too. Two groups, "
            "tockmox-admins and tockmox-users, decide who reaches each console and in which role; "
            "a user in neither group is refused by Authentik. Prometheus, Alertmanager, Longhorn "
            "and the Traefik dashboard have no sign-in of their own and can be put behind "
            "Authentik's forward-auth, off by default. Each OIDC console keeps a local break-glass "
            "login outside the group model. Forgejo is planned, not shipped, and ntfy is a "
            "portal link with no single sign-on.")
    header(s, "Who gets in, and how",
           "One identity provider, two groups, and a break-glass door on every console.")
    s.boundary(140, 100, 870, 530, "YOUR CLUSTER")
    s.person(70, 300, "You")
    s.lines(70, 362, ["the Tockmox CA", "in this machine's", "trust store"], 11, anchor="middle",
            color=PAL["green"][2], weight="600")
    s.box(166, 256, 150, 92, "Ingress", ["Traefik · HTTPS", "private-CA certificates"], "neutral",
          tsize=13.5, rsize=11)
    s.arrow([(94, 302), (162, 302)], "green", label="https://", lpos=(114, 292), lsize=11)
    s.box(352, 236, 196, 132, "Authentik", ["OIDC provider", "groups:", "tockmox-admins", "tockmox-users"],
          "green", tsize=15, rsize=11.5)
    s.arrow([(316, 302), (348, 302)], "green")
    s.blocked(500, 368, 500, 404, ["a user in neither group", "is refused here"], 500, 430, anchor="middle")
    consoles = [("Grafana", "Admin or Viewer"), ("Open WebUI", "admin or user"),
                ("Argo Workflows", "full or read-only")]
    for i, (n, r) in enumerate(consoles):
        y = 150 + i * 92
        s.box(612, y, 200, 72, n, [r], "green", tsize=13.5, rsize=11.5)
        s.arrow([(548, 302), (580, 302), (580, y + 36), (608, y + 36)], "green")
    s.text(580, 140, "OIDC", 11.5, "600", "middle", PAL["green"][2])
    s.rect(842, 150, 152, 236, "amber", dashed=True, rx=10)
    s.lines(918, 176, ["Break-glass", "local logins"], 13, anchor="middle", color=PAL["amber"][2], weight="700")
    s.lines(918, 222, ["Grafana local admin", "Open WebUI email", "Argo client token", "",
                       "outside the group", "model: no review", "of who holds one"], 11, anchor="middle",
            color=INK2)
    for i in range(3):
        y = 186 + i * 92
        s.arrow([(838, y), (816, y)], "amber", dashed=True)
    s.rect(612, 430, 200, 76, "neutral", rx=10)
    s.lines(712, 454, ["In-cluster trust"], 13, anchor="middle", color=INK, weight="700")
    s.lines(712, 474, ["each console exchanges the token", "from inside its container: CA again"], 11,
            anchor="middle", color=INK2)
    s.arrow([(712, 426), (712, 410)], "neutral", head=True)
    s.box(352, 470, 230, 96, "Forward-auth", ["Prometheus · Alertmanager", "Longhorn · Traefik dashboard",
          "off by default"], "amber", dashed=True, tsize=13.5, rsize=11)
    s.arrow([(400, 368), (400, 466)], "amber", dashed=True)
    s.box(842, 430, 152, 60, "Forgejo", ["planned, not shipped"], "neutral", dashed=True, tsize=13, rsize=11)
    s.box(842, 506, 152, 60, "ntfy", ["a portal link, no SSO"], "neutral", dashed=True, tsize=13, rsize=11)
    s.legend(156, 470, [
        ("bound", "ink", "trust boundary"),
        ("arrow", "green", "single sign-on path"),
        ("darrow", "amber", "optional or break-glass"),
        ("block", "red", "refused"),
    ], w=190)
    return s


# ---------------------------------------------------------------------------
# 7. Network containment ... docs/usage/what-you-get.md § network containment
#    Every boundary below is stated on that page; nothing beyond it is drawn.
# ---------------------------------------------------------------------------
def network_containment():
    s = Svg(1040, 640, "Tockmox network containment: what is denied, and where",
            "All seven namespaces the policy layer creates deny ingress by default. Egress is "
            "default-deny in two of them: the AI namespace, where the model gateway may reach DNS, "
            "its own namespace, its database and TCP 443 outside the cluster, service and LAN "
            "ranges, and a LAN model host only once it is listed; and the diagnostic namespace, "
            "which may reach DNS, the API server and local telemetry. Egress is open in the other "
            "five: platform, monitoring, Authentik, devops and selfcheck. Namespaces you create "
            "get no policy from Tockmox. Three hostNetwork workloads, the MetalLB speaker, kured "
            "and node-exporter, are outside NetworkPolicy altogether. Measured on one single-node "
            "lab with kube-router; not measured on another CNI or a multi-node cluster.")
    header(s, "What the network policy covers, and what it does not",
           "Ingress is denied everywhere Tockmox creates a namespace. Egress, in two places.")
    s.boundary(30, 100, 980, 380, "NAMESPACES THE POLICY LAYER CREATES",
               sub="Every one denies ingress by default; only rules that name a path open it")
    s.text(56, 160, "EGRESS DENIED BY DEFAULT", 11.5, "700", color=PAL["green"][2], spacing=1.2)
    s.box(56, 172, 300, 132, "tockmox-ai", ["the gateway may reach DNS, its", "namespace, its database, and",
          "TCP 443 outside cluster and LAN", "a LAN model host once listed"], "green", tsize=14, rsize=11.5)
    s.box(376, 172, 250, 132, "tockmox-diagnostic", ["the read-only identity may", "reach DNS, the API server",
          "and local telemetry"], "green", tsize=14, rsize=11.5)
    s.text(56, 342, "EGRESS OPEN", 11.5, "700", color=INK2, spacing=1.2)
    open_ns = ["tockmox-platform", "tockmox-monitoring", "tockmox-authentik", "tockmox-devops",
               "tockmox-selfcheck"]
    for i, n in enumerate(open_ns):
        s.box(56 + i * 188, 354, 172, 60, n, ["ingress denied"], "neutral", tsize=12.5, rsize=11)
    s.lines(56, 440, ["A compromised pod here can reach the network: containment is a smaller claim than isolation."],
            11.5, color=INK2)
    s.rect(660, 172, 326, 132, "neutral", rx=10, fill="#FFFFFF")
    s.lines(676, 196, ["Edges the page states"], 12.5, color=INK, weight="700")
    s.lines(676, 216, ["· a new pod is unpoliced for about its first", "  second (measured on kube-router)",
                       "· the platform namespace admits your LAN", "· diagnostic's API rule is the service and LAN",
                       "  ranges on 443/6443 until apiServerCIDRs is set", "· AI egress measured on one single-node lab"],
            10.5, color=INK2, lh=14.5)
    # outside the boundary
    s.rect(30, 506, 470, 104, "neutral", dashed=True, rx=14)
    s.lines(50, 532, ["NAMESPACES YOU CREATE"], 11.5, color=INK2, weight="700")
    s.lines(50, 560, ["No policy from Tockmox. adding-an-application.md", "gives the recipe; nothing applies it for you."],
            12.5, color=INK)
    s.rect(530, 506, 480, 104, "red", rx=14, fill="#FFF8F8")
    s.lines(550, 532, ["OUTSIDE NETWORKPOLICY ENTIRELY"], 11.5, color=PAL["red"][2], weight="700")
    s.lines(550, 560, ["hostNetwork workloads: the MetalLB speaker,", "kured and node-exporter. That is the API's",
                       "behaviour, not an oversight."], 12.5, color=INK)
    return s


# ---------------------------------------------------------------------------
# 8. The alert path ... docs/operations/monitoring.md § how an alert reaches you
#    Sources: monitoring.md, charts/tockmox-selfcheck (heartbeat, TockmoxSelfCheckStale),
#    charts/tockmox-observability values (Watchdog to a null receiver).
# ---------------------------------------------------------------------------
def alert_path():
    s = Svg(1040, 660, "How a Tockmox alert reaches a person, and how the path watches itself",
            "Workloads expose metrics that Prometheus scrapes, and pod logs go through Alloy to "
            "Loki; Grafana shows both. Prometheus evaluates the alert rules and sends firing "
            "alerts to Alertmanager, which posts them to the alert bridge, which publishes them to "
            "ntfy, where a subscribed phone receives them. Apprise, off by default, can fan out to "
            "email or chat. On iOS, lock-screen notifications need an optional relay through "
            "ntfy.sh, off by default, through which a wakeup and the topic name leave your network. "
            "Every 15 minutes the self-check heartbeat posts an alert to Alertmanager that travels "
            "the same path; if it stops succeeding, TockmoxSelfCheckStale fires. The bridge "
            "publishes its own delivery health as metrics, and three alerts render a dead "
            "notification path on a dashboard. Alertmanager's always-firing Watchdog goes to a "
            "null receiver, not to the phone.")
    header(s, "How an alert reaches a person",
           "And how the path proves it still works when nothing is wrong.")
    s.boundary(30, 100, 820, 530, "YOUR CLUSTER")
    s.box(56, 140, 150, 64, "Workloads", ["metrics endpoints"], "neutral", tsize=13.5, rsize=11)
    s.box(56, 230, 150, 64, "Pod logs", ["every node"], "neutral", tsize=13.5, rsize=11)
    s.box(250, 140, 150, 64, "Prometheus", ["rules evaluated"], "neutral", tsize=13.5, rsize=11)
    s.box(250, 230, 150, 64, "Alloy → Loki", ["logs stored"], "neutral", tsize=13.5, rsize=11)
    s.box(250, 320, 150, 64, "Grafana", ["dashboards"], "neutral", tsize=13.5, rsize=11)
    s.arrow([(206, 172), (246, 172)], "neutral")
    s.arrow([(206, 262), (246, 262)], "neutral")
    s.arrow([(325, 294), (325, 316)], "neutral")
    s.arrow([(400, 172), (420, 172), (420, 352), (404, 352)], "neutral")
    s.box(450, 140, 150, 64, "Alertmanager", ["routes alerts"], "green", tsize=13.5, rsize=11)
    s.box(450, 240, 150, 64, "Alert bridge", ["two replicas"], "green", tsize=13.5, rsize=11)
    s.box(650, 240, 170, 64, "ntfy", ["one replica · deny-all", "until you add its Secret"], "green",
          tsize=13.5, rsize=11)
    s.arrow([(400, 160), (446, 160)], "green", label="firing", lpos=(423, 152), lsize=10.5)
    s.arrow([(525, 204), (525, 236)], "green")
    s.arrow([(600, 272), (646, 272)], "green")
    s.person(940, 266, "Your phone")
    s.arrow([(820, 272), (914, 272)], "green", label="subscribed", lpos=(885, 262), lsize=11)
    s.box(450, 336, 150, 60, "Apprise", ["email, chat · off"], "amber", dashed=True, tsize=13, rsize=11)
    s.arrow([(525, 304), (525, 332)], "amber", dashed=True)
    s.cloud(872, 336, 150, 84, "amber")
    s.text(947, 380, "ntfy.sh relay", 12.5, "700", "middle", PAL["amber"][2])
    s.text(947, 398, "iOS only · off", 11, "400", "middle", INK2)
    s.arrow([(760, 304), (760, 372), (874, 372)], "amber", dashed=True)
    s.crossing(850, 372, [], side="right")
    s.lines(947, 436, ["a wakeup and the topic", "name leave your network"], 11, anchor="middle",
            color=PAL["red"][2], weight="600")
    # heartbeat
    s.rect(56, 430, 360, 170, "green", rx=10, fill="#F4FBF5")
    s.lines(74, 456, ["THE SELF-CHECK"], 11.5, color=PAL["green"][2], weight="700")
    s.lines(74, 480, ["A heartbeat CronJob posts an alert to", "Alertmanager every 15 minutes. It",
                      "travels the whole path to the phone.", "",
                      "If it stops succeeding, Prometheus", "fires TockmoxSelfCheckStale: the",
                      "monitoring plane itself is down."], 11.5, color=INK)
    s.arrow([(416, 470), (436, 470), (436, 190), (446, 190)], "green", dashed=False)
    s.rect(450, 430, 370, 170, "blue", rx=10, fill="#F3F7FD")
    s.lines(468, 456, ["WATCHING THE WATCHER"], 11.5, color=PAL["blue"][2], weight="700")
    s.lines(468, 480, ["The bridge publishes its own delivery", "health as metrics. Three alerts render",
                       "a dead notification path on a", "dashboard, which survives it.", "",
                       "Alertmanager's Watchdog goes to a null", "receiver, never to the phone."], 11.5,
            color=INK)
    s.legend(866, 480, [
        ("arrow", "green", "the delivery path"),
        ("darrow", "amber", "off by default"),
        ("cross", "red", "leaves your network"),
    ], w=166)
    return s


# ---------------------------------------------------------------------------
# 9. Recovery evidence ... docs/operations/backup-restore.md § what is not certified here
#    Every filled dot is a dated run that page (or the escrow page) records.
# ---------------------------------------------------------------------------
RECOVERY_ROWS = [
    ("Model-gateway database", "CloudNativePG to S3",
     ("●", "on by default from 0.7.1"), ("●", "2026-08-19 rehearsal, 2026-10-01 in prod"), ("●", "weekly drill, alerted")),
    ("Longhorn volumes", "incl. the chat console's",
     ("●", "to the BackupTarget"), ("●", "2026-10-01 all 19 in prod, 2026-10-10 lab"), ("○", "not scheduled")),
    ("Authentik's bundled Postgres", "nightly pg_dump",
     ("●", "byte-verified upload"), ("●", "2026-10-10, lab, login after"), ("○", "not scheduled")),
    ("Sealed-secrets controller key", "escrow, off the cluster",
     ("●", "you export it"), ("●", "2026-10-04, fresh controller, lab"), ("○", "drill not yet run")),
    ("The whole cluster", "rebuild and restore, as one",
     ("○", "assembled from the rows"), ("○", "never run as one exercise"), ("○", "not claimed")),
]


def recovery_evidence():
    s = Svg(1040, 600, "Tockmox recovery evidence, row by row",
            "Model-gateway database: backed up by default from 0.7.1, restored on dated runs on "
            "2026-08-19 and in production on 2026-10-01, and drilled weekly. Longhorn volumes, including the chat "
            "console's: backed up to the BackupTarget, restored in production on 2026-10-01 and "
            "drilled once on a lab on 2026-10-10, with no scheduled drill. Authentik's bundled "
            "Postgres: a nightly dump, restored once on a lab on 2026-10-10 with a login "
            "afterwards, with no scheduled drill. The sealed-secrets controller key: exported by "
            "you, restored onto a fresh controller on a lab on 2026-10-04, its drill not yet run. "
            "The whole cluster: never rebuilt and restored as one exercise. Filled dots are what the "
            "backup pages record as shipped or as a dated run; hollow dots are not claimed.")
    header(s, "What has actually been restored",
           "A filled dot is something the backup pages record as shipped or as a dated run. A hollow dot is not claimed.")
    cols = [("BACKED UP", 380), ("RESTORED, DATED", 580), ("DRILLED ON A SCHEDULE", 820)]
    for label, x in cols:
        s.text(x, 112, label, 11.5, "700", color=INK2, spacing=1.2)
    for i, (name, sub, *cells) in enumerate(RECOVERY_ROWS):
        y = 128 + i * 82
        last = i == len(RECOVERY_ROWS) - 1
        s.rect(30, y, 980, 70, "red" if last else "neutral", rx=10, fill="#FFF8F8" if last else "#FFFFFF")
        s.text(50, y + 30, name, 14, "700", color=INK)
        s.text(50, y + 50, sub, 11.5, color=INK2)
        for (sym, note), (_, x) in zip(cells, cols):
            filled = sym == "●"
            st = PAL["green"][1] if filled else "#8A938E"
            s.add(f'<circle cx="{x + 8}" cy="{y + 26}" r="8" fill="{st if filled else "#FFFFFF"}" '
                  f'stroke="{st}" stroke-width="2"/>')
            s.text(x + 24, y + 31, "yes" if filled else "no", 12.5, "700",
                   color=PAL["green"][2] if filled else INK2)
            s.text(x, y + 54, note, 11, color=INK2)
    s.lines(30, 556, ["The shipped object store runs inside the cluster it protects, so a backup kept only there",
                      "does not survive losing the cluster. Point backups off the cluster for data you care about."],
            11.5, color=INK2)
    return s


# ---------------------------------------------------------------------------
# 10. The customisation ladder ... docs/administration/customising.md
# ---------------------------------------------------------------------------
def customisation_ladder():
    s = Svg(1040, 600, "The Tockmox customisation ladder",
            "Four rungs, from the bottom. Rung 1, values: anything a chart exposes, no upgrade cost "
            "on a key tiered stable. Rung 2, extension points: a dashboard, an alert rule or a "
            "NetworkPolicy dropped into your repository, no upgrade cost. Rung 3, a Kustomize "
            "patch: a shipped resource that is not exposed; it fails loudly when the base moves "
            "and you fix it at upgrade time. Rung 4, disable and replace: you own the replacement. "
            "Reach for the lowest rung that works. Needing rung 3 or 4 repeatedly is a values gap "
            "worth an issue. Editing resources in the cluster by hand is not a rung: it is reverted.")
    header(s, "Change what Tockmox ships",
           "Start at the bottom. Move up only when the rung below cannot express what you need.")
    rungs = [
        ("1  Values", "anything a chart already exposes", "none on a key tiered stable", "green"),
        ("2  Extension points", "a dashboard, an alert rule, a NetworkPolicy in your repo", "none: a separate object of yours", "green"),
        ("3  Kustomize patch", "a shipped resource that is not exposed", "fails loudly when the base moves", "amber"),
        ("4  Disable and replace", "replacing a component outright", "you own the replacement", "amber"),
    ]
    for i, (t, use, cost, kind) in enumerate(rungs):
        y = 470 - i * 96
        x = 120 + i * 40
        w = 620 - i * 40
        s.rect(x, y, w, 76, kind, rx=10)
        s.text(x + 18, y + 30, t, 15, "700", color=PAL[kind][2])
        s.text(x + 18, y + 54, use, 12, color=INK2)
        s.text(x + w + 16, y + 34, "Upgrade cost", 11, "700", color=MUTED)
        s.text(x + w + 16, y + 52, cost, 12, color=INK)
    s.arrow([(70, 540), (70, 196)], "blue", sw=2)
    s.add(f'<text x="58" y="370" font-size="11.5" font-weight="700" fill="{PAL["blue"][2]}" '
          f'text-anchor="middle" transform="rotate(-90 58 370)" letter-spacing="1.2">MORE OF IT IS YOURS AT UPGRADE</text>')
    s.lines(320, 150, ["On rung 3 or 4 repeatedly? That is a values gap, and an issue worth opening."],
            12, color=PAL["amber"][2], weight="600")
    s.blocked(860, 120, 860, 160, ["kubectl edit in the cluster", "is not a rung: it is reverted"], 846, 112,
              anchor="end")
    return s


DIAGRAMS = {
    "platform-overview": platform_overview,
    "gitops-model": gitops_model,
    "layer-stack": layer_stack,
    "ai-request-path": ai_request_path,
    "install-journey": install_journey,
    "identity-flow": identity_flow,
    "network-containment": network_containment,
    "alert-path": alert_path,
    "recovery-evidence": recovery_evidence,
    "customisation-ladder": customisation_ladder,
}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args(argv)
    names = a.names or list(DIAGRAMS)
    stale = []
    for n in names:
        svg = DIAGRAMS[n]().render()
        path = OUT / f"{n}.svg"
        if a.check:
            if not path.exists() or path.read_text() != svg:
                stale.append(n)
        else:
            OUT.mkdir(parents=True, exist_ok=True)
            path.write_text(svg)
    if a.check:
        if stale:
            print("gen_diagrams: stale or missing: " + ", ".join(stale)
                  + ". Run python3 docs/diagrams/source/gen_diagrams.py", file=sys.stderr)
            return 1
        print(f"gen_diagrams: {len(names)} diagrams match a fresh render")
        return 0
    print(f"gen_diagrams: wrote {len(names)} diagrams to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

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
            "configure it; a request sent there takes the conversation with it.")
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
            "starting the next. Every layer from wave 3 up can be declined.")
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
            "frontier provider, only if you add one to the model list.")
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
            "branches for the sites that need them.")
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


DIAGRAMS = {
    "platform-overview": platform_overview,
    "gitops-model": gitops_model,
    "layer-stack": layer_stack,
    "ai-request-path": ai_request_path,
    "install-journey": install_journey,
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

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate the docs index surfaces from repo metadata (TM-0228).

Two surfaces, both written BETWEEN MARKER COMMENTS so the prose around them
stays hand-written:

  1. the layer table in docs/architecture.md
       <!-- tockmox:layers:begin --> ... <!-- tockmox:layers:end -->
     Layer name and sync wave come from tockmox.com/sync-wave in each
     charts/*/Chart.yaml. The installer (install/tockmox-install.sh, the wave()
     function) reproduces the same mapping independently; this tool reads both
     and refuses to run when they disagree. The outcome-worded third column and
     the Declinable column are editorial and live in LAYERS below, because
     neither can be derived from a chart. The set of layers is still checked
     against charts/, so a tenth chart fails here until it has a row.

  2. a page table in each of docs/{deployment,administration,operations,usage}/
     README.md
       <!-- tockmox:section-index:begin --> ... <!-- tockmox:section-index:end -->
     Title and one-line description come from each page's frontmatter (H1 and
     the first sentence of description when there is no frontmatter). Reading
     order comes from tools/docs-index-order.txt. A page in the section that the
     order file does not list, or a listed page that does not exist, is an error.

     GROUPS (2026-10-27). A section may split its pages into groups, so an index
     routes by what the reader is doing rather than implying one long reading
     order. In the order file, a line `group: Title :: blurb` starts a group
     whose pages are a set (no step numbers), and `steps: Title :: blurb` starts
     one whose pages are read in order (numbered from 1 within the group). The
     blurb is optional. Each group renders as a `### Title` heading, the blurb,
     and its own table. A section with no group lines renders exactly as before:
     one numbered table. A section that uses groups must put every page in one,
     and a group with no pages is an error.

Modes: (none) write; --check fail when a committed surface differs from a fresh
render; --selftest prove the checks can fail. --root DIR points at another tree
(the red-proof runs against a copy of the charts).
"""
import argparse
import difflib
import pathlib
import re
import sys

# name -> (what it gives you, declinable). Outcome first, then the components and
# addresses that make the outcome concrete. This is the ONE place the layer
# table is written (TM-0840): docs/architecture.md used to carry a second,
# hand-kept table of the same nine layers, and the two disagreed within a week
# (this one said "Registry, git" for a layer that ships neither). policy is
# "No" by ruling (2026-08-30): apps.platform_netpol.enabled=false exists, but
# an escape hatch is not declining the layer. Counts do not belong in a cell;
# the render-counts pins on usage/what-you-get.md own them.
LAYERS = [
    ("crds", "Every CRD, first: the prometheus-operator CRDs the other layers need", "No"),
    ("policy", "Namespaces, default-deny networking, RBAC admission guardrails, PriorityClasses, a read-only diagnostic identity", "No"),
    ("platform", "Storage, load balancing, ingress, certificates: cert-manager with a private CA, MetalLB with an address pool, Traefik, Longhorn, CloudNativePG, the shipped object store, kured", "Partly"),
    ("observability", "Metrics, logs, dashboards, alerting: kube-prometheus-stack, Loki, Alloy, Grafana at `grafana.<yourdomain>`, and alerts that reach a phone through ntfy at `ntfy.<yourdomain>`, behind an Alertmanager bridge that alerts on its own delivery failures", "Yes"),
    ("exporters", "Hardware and network telemetry: blackbox on; SNMP and smartctl are the `hardwareTelemetry` [capability](administration/capabilities.md) (a Capability, not an Add-on), off by default", "Yes"),
    ("identity", "Single sign-on across every console: Authentik at `auth.<yourdomain>`. Credentials come from operator-created Secrets; the pods wait with a config error naming any that is missing", "Yes"),
    ("devops", "Workflows: Argo Workflows at `workflows.<yourdomain>`, with client auth rather than the upstream authenticate-nobody default. Off by default", "Yes"),
    ("ai", "Chat interface and model gateway: Open WebUI at `chat.<yourdomain>`, GitOps-authoritative config, no cloud backend, shipped pointed at no model. A LiteLLM model gateway at `llm.<yourdomain>` with a proven backup-and-restore-drill path, on by default since 0.8.0 with the console routed through it; naming a model host is [the one decision a default install leaves you](usage/what-you-get.md#the-one-decision-a-default-install-leaves-you)", "Yes"),
    ("selfcheck", "Proves the platform's own guarantees: a heartbeat CronJob and the alerts that fire when monitoring itself goes quiet. Never invokes a model", "Yes"),
]

SECTIONS = ["deployment", "administration", "operations", "usage"]

LB, LE = "<!-- tockmox:layers:begin -->", "<!-- tockmox:layers:end -->"
SB, SE = "<!-- tockmox:section-index:begin -->", "<!-- tockmox:section-index:end -->"
NOTE = ("<!-- Generated by tools/gen-docs-index.sh from {src}. "
        "Edit that, not this block. -->")


class Fail(Exception):
    pass


def chart_waves(root):
    out = {}
    for cy in sorted(root.glob("charts/tockmox-*/Chart.yaml")):
        text = cy.read_text()
        name = re.search(r"^name:\s*(\S+)", text, re.M)
        wave = re.search(r'^\s+tockmox\.com/sync-wave:\s*"?(\d+)"?\s*$', text, re.M)
        if name and name.group(1) == "tockmox-common":
            continue  # the shared library chart is not a layer
        if not name or not wave:
            raise Fail(f"{cy}: no name or no tockmox.com/sync-wave annotation")
        layer = name.group(1)
        out[layer.removeprefix("tockmox-")] = int(wave.group(1))
    return out


def installer_waves(root, layers):
    src = (root / "install/tockmox-install.sh").read_text()
    m = re.search(r"wave\(\) \{ case \"\$1\" in(.*?)esac; \}", src, re.S)
    if not m:
        raise Fail("install/tockmox-install.sh: wave() function not found "
                   "(moved or reshaped? teach tools/lib/gen_docs_index.py)")
    explicit, default = {}, None
    for pat, num in re.findall(r"([\w|*]+)\)\s*echo\s+(\d+)", m.group(1)):
        if pat == "*":
            default = int(num)
        else:
            for n in pat.split("|"):
                explicit[n] = int(num)
    if default is None:
        raise Fail("install/tockmox-install.sh: wave() has no default arm")
    return {l: explicit.get(l, default) for l in layers}


def layer_table(root):
    charts = chart_waves(root)
    names = [n for n, _, _ in LAYERS]
    if set(charts) != set(names):
        raise Fail("charts/ and LAYERS disagree: only in charts/ "
                   f"{sorted(set(charts) - set(names))}, only in LAYERS "
                   f"{sorted(set(names) - set(charts))}")
    inst = installer_waves(root, names)
    bad = [(n, charts[n], inst[n]) for n in names if charts[n] != inst[n]]
    if bad:
        raise Fail("Chart.yaml sync-wave and the installer wave() disagree: "
                   + "; ".join(f"{n} chart={c} installer={i}" for n, c, i in bad))
    rows = ["| Layer | Wave | What it gives you | Declinable |", "|---|---|---|---|"]
    for n, what, dec in LAYERS:
        rows.append(f"| `{n}` | {charts[n]} | {what} | {dec} |")
    src = "charts/*/Chart.yaml (sync-wave), checked against install/tockmox-install.sh"
    return "\n".join([LB, NOTE.format(src=src), ""] + rows + ["", LE])


def frontmatter(text):
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    fm = {}
    for line in text[4:end].split("\n"):
        m = re.match(r'(title|description):\s*"(.*)"\s*$', line)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm


def first_sentence(s):
    m = re.search(r"(?<=[a-z0-9)`])\.(?=\s+[A-Z])", s)
    return s[:m.start()] if m else s.rstrip(".")


def page_info(path):
    text = path.read_text()
    fm = frontmatter(text)
    h1 = re.search(r"^# (.+)$", text, re.M)
    h1 = h1.group(1).strip() if h1 else path.stem
    if fm.get("title"):
        title, desc = fm["title"], first_sentence(fm.get("description", ""))
    else:
        # No frontmatter: the H1 may carry "Title ... subtitle".
        title, _, desc = h1.partition(" ... ")
    return title, desc.strip()


GROUP = re.compile(r"^(group|steps):\s*(.+?)\s*(?:::\s*(.*?)\s*)?$")


def read_order(root):
    """Return (order, groups). order: section -> [stem, ...] in file order.
    groups: section -> [(kind, title, blurb, [stem, ...]), ...], empty when the
    section uses no group lines."""
    order, groups, cur = {}, {}, None
    for n, line in enumerate((root / "tools/docs-index-order.txt").read_text().split("\n"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1]
            order.setdefault(cur, [])
            groups.setdefault(cur, [])
            continue
        if cur is None:
            raise Fail(f"docs-index-order.txt:{n}: page or group before any [section]")
        g = GROUP.match(line)
        if g:
            groups[cur].append((g.group(1), g.group(2), g.group(3) or "", []))
            continue
        if groups[cur]:
            groups[cur][-1][3].append(line)
        order[cur].append(line)
    for sec, gs in groups.items():
        if not gs:
            continue
        ungrouped = len(order[sec]) - sum(len(g[3]) for g in gs)
        if ungrouped:
            raise Fail(f"docs-index-order.txt [{sec}] uses groups, and {ungrouped} "
                       f"page(s) come before the first group line")
        for kind, title, _, stems in gs:
            if not stems:
                raise Fail(f"docs-index-order.txt [{sec}] group \"{title}\" lists no pages")
    return order, groups


def section_table(root, section, order, groups=None):
    d = root / "docs" / section
    pages = sorted(p.stem for p in d.glob("*.md") if p.name != "README.md")
    listed = order.get(section, [])
    if len(set(listed)) != len(listed):
        raise Fail(f"docs-index-order.txt [{section}] lists a page twice")
    if set(pages) != set(listed):
        raise Fail(f"docs/{section}/ and docs-index-order.txt disagree: not in the "
                   f"order file {sorted(set(pages) - set(listed))}, in the order "
                   f"file but no such page {sorted(set(listed) - set(pages))}")
    src = f"each page's frontmatter, ordered by tools/docs-index-order.txt"
    gs = (groups or {}).get(section) or []
    if not gs:
        rows = ["| Read | Page | What it covers |", "|---|---|---|"]
        for i, stem in enumerate(listed, 1):
            title, desc = page_info(d / f"{stem}.md")
            rows.append(f"| {i} | [{title}]({stem}.md) | {desc} |")
        return "\n".join([SB, NOTE.format(src=src), ""] + rows + ["", SE])
    out = [SB, NOTE.format(src=src)]
    for kind, gtitle, blurb, stems in gs:
        out += ["", f"### {gtitle}", ""]
        if blurb:
            out += [blurb, ""]
        if kind == "steps":
            out += ["| Step | Page | What it covers |", "|---|---|---|"]
        else:
            out += ["| Page | What it covers |", "|---|---|"]
        for i, stem in enumerate(stems, 1):
            title, desc = page_info(d / f"{stem}.md")
            if kind == "steps":
                out.append(f"| {i} | [{title}]({stem}.md) | {desc} |")
            else:
                out.append(f"| [{title}]({stem}.md) | {desc} |")
    return "\n".join(out + ["", SE])


def splice(text, begin, end, block, where):
    pat = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
    if len(pat.findall(text)) != 1:
        raise Fail(f"{where}: expected exactly one {begin} ... {end} pair")
    return pat.sub(lambda _: block, text, count=1)


def surfaces(root):
    """Return {path: new full text} for every generated surface."""
    out = {}
    arch = root / "docs/architecture.md"
    out[arch] = splice(arch.read_text(), LB, LE, layer_table(root), str(arch))
    order, groups = read_order(root)
    extra = set(order) - set(SECTIONS)
    if extra:
        raise Fail(f"docs-index-order.txt has unknown sections {sorted(extra)}")
    for s in SECTIONS:
        rd = root / "docs" / s / "README.md"
        if not rd.exists():
            raise Fail(f"{rd} missing: create it with a {SB} ... {SE} pair")
        out[rd] = splice(rd.read_text(), SB, SE, section_table(root, s, order, groups), str(rd))
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    root = pathlib.Path(a.root).resolve()
    if a.selftest:
        return selftest(root)
    try:
        new = surfaces(root)
    except Fail as e:
        print(f"gen-docs-index: ERROR: {e}", file=sys.stderr)
        return 1
    stale = [p for p, t in new.items() if p.read_text() != t]
    if a.check:
        for p in stale:
            print(f"gen-docs-index: {p.relative_to(root)} disagrees with a fresh render:",
                  file=sys.stderr)
            sys.stderr.writelines(difflib.unified_diff(
                p.read_text().splitlines(True), new[p].splitlines(True),
                "committed", "fresh", n=1))
        if stale:
            print("gen-docs-index: run ./tools/gen-docs-index.sh and commit the result",
                  file=sys.stderr)
            return 1
        print(f"gen-docs-index: {len(new)} surfaces match a fresh render")
        return 0
    for p in stale:
        p.write_text(new[p])
    print(f"gen-docs-index: {len(new)} surfaces, {len(stale)} rewritten")
    return 0


def selftest(root):
    """Each mutation must be refused; the unmutated tree must pass."""
    import shutil
    import tempfile
    base = surfaces(root)
    if any(p.read_text() != t for p, t in base.items()):
        print("selftest: tree is not current; run the generator first", file=sys.stderr)
        return 1
    cases = []
    with tempfile.TemporaryDirectory() as td:
        def fresh():
            t = pathlib.Path(td) / f"t{len(cases)}"
            shutil.copytree(root / "charts", t / "charts",
                            ignore=shutil.ignore_patterns("*.tgz", "templates"))
            for rel in ("install", "docs", "tools"):
                shutil.copytree(root / rel, t / rel,
                                ignore=shutil.ignore_patterns("*.tgz", "assets"))
            return t

        def expect_red(label, fn, want):
            t = fresh()
            fn(t)
            try:
                new = surfaces(t)
            except Fail as e:
                ok = want in str(e)
                cases.append((label, ok, str(e)[:90]))
                return
            red = any(p.read_text() != x for p, x in new.items())
            cases.append((label, red and want == "STALE", "stale" if red else "no change seen"))

        expect_red("sync-wave flipped in a chart",
                   lambda t: (lambda f: f.write_text(re.sub(r'(sync-wave: ")3', r"\g<1>2", f.read_text(), count=1)))(
                       t / "charts/tockmox-exporters/Chart.yaml"), "disagree")
        expect_red("installer wave() flipped",
                   lambda t: (lambda f: f.write_text(f.read_text().replace(
                       "observability|exporters) echo 3", "observability|exporters) echo 4")))(
                       t / "install/tockmox-install.sh"), "disagree")
        expect_red("committed table hand-edited",
                   lambda t: (lambda f: f.write_text(f.read_text().replace("| Yes |", "| No |", 1)))(
                       t / "docs/architecture.md"), "STALE")
        def add_unlisted_page(t):
            (t / "docs/usage/extra.md").write_text("# Extra\n")

        expect_red("page missing from the order file", add_unlisted_page, "not in the")

        def empty_group(t):
            f = t / "tools/docs-index-order.txt"
            f.write_text(f.read_text().replace("[usage]\n", "[usage]\ngroup: Nothing here\n", 1))

        expect_red("a group that lists no pages", empty_group, "lists no pages")

        def page_before_group(t):
            # A section with a page listed ahead of its first group line. The
            # usage section is rewritten whole so the case does not depend on
            # how the committed order file groups it.
            f = t / "tools/docs-index-order.txt"
            head, _, tail = f.read_text().partition("[usage]\n")
            pages = [l for l in tail.split("\n")
                     if l.strip() and not l.startswith("#") and not GROUP.match(l.strip())]
            f.write_text(head + "[usage]\n" + pages[0] + "\ngroup: Rest\n"
                         + "\n".join(pages[1:]) + "\n")

        expect_red("a page before the first group line of a grouped section", page_before_group,
                   "before the first group line")
    bad = [c for c in cases if not c[1]]
    for label, ok, why in cases:
        print(f"selftest: {'red as required' if ok else 'NOT RED'}: {label} ({why})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

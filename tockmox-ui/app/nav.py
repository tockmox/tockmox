# SPDX-License-Identifier: Apache-2.0
"""The console's sections, each section's rail, the health pill and "Help for this page" (TM-1304).

specs/tockmox-ui/SPEC.md, sections 2 and 3 (Tockmox planning repo): four sections in the top bar
(Home, Status, AI, Platform), a left rail for the pages inside a section, and utilities on the right.
URLs did not move; a section is a grouping of the routes that already exist, so every bookmark keeps
working. Pure functions, no I/O: the templates call them with what the route already read."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Item:
    label: str
    href: str
    prefixes: tuple[str, ...] = ()   # paths that light this item up; the longest matching prefix wins
    count: int | None = None

    def matches(self, path: str) -> int:
        """Length of the longest prefix of `path` this item claims, 0 for none. Exact href counts too."""
        best = len(self.href) if path == self.href else 0
        for p in self.prefixes:
            if path == p or (p.endswith("/") and path.startswith(p)) or path.startswith(p + "/"):
                best = max(best, len(p))
        return best


@dataclass(frozen=True)
class Group:
    heading: str
    items: tuple[Item, ...] = field(default_factory=tuple)


def section_of(path: str) -> str | None:
    """Which top-bar section a path belongs to; None for pages outside every section (About, Recovery)."""
    if path == "/":
        return "home"
    if path == "/status" or path.startswith("/status/"):
        return "status"
    if path.startswith(("/models", "/nodes")):
        return "ai"
    if path.startswith(("/platform", "/capabilities", "/upgrade", "/version", "/tabs/")):
        return "platform"
    return None


def platform_home(platform_on: bool) -> str:
    """Where the Platform section opens: the operations overview when Platform Management is on,
    else Capabilities, the page every install has."""
    return "/platform" if platform_on else "/capabilities"


def sections(is_admin: bool, platform_on: bool, user_tabs=()) -> list[Item]:
    """The top bar. Admins get the four sections; everyone else gets Home plus any first-party feature a
    non-admin may open (absent, not locked: a section a user cannot open is not shown)."""
    out = [Item("Home", "/")]
    if is_admin:
        out += [Item("Status", "/status"), Item("AI", "/models", ("/models", "/nodes")),
                Item("Platform", platform_home(platform_on),
                     ("/platform", "/capabilities", "/upgrade", "/version", "/tabs"))]
    else:
        out += [Item(t.name, f"/tabs/{t.id}") for t in user_tabs if not getattr(t, "admin_only", True)]
    return out


def current(items, path: str):
    """The item a path belongs to: the one claiming the longest prefix, or None."""
    best, score = None, 0
    for it in items:
        m = it.matches(path)
        if m > score:
            best, score = it, m
    return best


def rail(section: str | None, is_admin: bool, platform_on: bool, admin_tabs=(), inbox_count: int | None = None) -> list[Group]:
    """The page list on the left of a section, or [] when the section has one page (Home, Status)."""
    if not is_admin:
        return []
    if section == "ai":
        return [
            Group("Models", (
                Item("Models", "/models", ("/models/a/", "/models/c/", "/models/v/", "/models/m/", "/models/compare",
                                           "/models/evaluate", "/models/promote", "/models/promote-hosted",
                                           "/models/propose", "/models/recommend")),
                Item("Inbox", "/models/inbox", count=inbox_count),
                Item("Budget", "/models/budget"),
                Item("Profiles", "/models/profiles"),
            )),
            Group("Hardware", (Item("Inference nodes", "/nodes", ("/nodes",)),)),
        ]
    if section == "platform":
        groups = []
        if platform_on:
            groups.append(Group("Operations", (
                Item("Overview", "/platform", ("/platform/agents/",)),
                Item("Cases", "/platform/cases", ("/platform/cases/",)),
                Item("Schedule", "/platform/schedule"),
                Item("Specialists", "/platform/specialists"),
            )))
        conf = [Item("Capabilities", "/capabilities")]
        conf += [Item(t.name, f"/tabs/{t.id}") for t in admin_tabs]
        conf.append(Item("Updates", "/platform/updates", ("/upgrade", "/version")))
        groups.append(Group("Configuration", tuple(conf)))
        return groups
    return []


def rail_current(groups, path: str):
    return current([i for g in groups for i in g.items], path)


# ------------------------------------------------------------ the health pill

def health(verdict: str, problem_rows: list[dict]) -> dict:
    """The pill on every admin page: the worst state and the counts, in words (the accessible name too).
    Counts are rows today; TM-1305 makes them parts (four signals about one backup count once)."""
    crit = sum(1 for p in problem_rows if p.get("state") == "critical")
    warn = sum(1 for p in problem_rows if p.get("state") == "warning")
    unk = sum(1 for p in problem_rows if p.get("state") == "unknown")
    parts = []
    if crit:
        parts.append(f"{crit} problem" + ("" if crit == 1 else "s"))
    if warn:
        parts.append(f"{warn} warning" + ("" if warn == 1 else "s"))
    if unk:
        parts.append(f"{unk} unknown")
    if not parts:
        # No row to count: say what the verdict says, so the words never contradict the colour (review, TM-1304).
        parts = [{"ok": "All healthy", "warning": "Warning", "critical": "Problem"}.get(verdict, "Status unknown")]
    return {"state": verdict, "parts": parts, "label": ", ".join(parts) + ". Open Status."}


# ------------------------------------------------------------ Help for this page

# Route prefix -> docs page (relative to docs/). Drafted by a local model (local-medium on the M5) from the
# route list and the docs index, then corrected by review (5 of 24 entries). A route with no entry hides
# the menu item rather than linking to the docs home. tests/test_shell.py proves every target exists.
HELP_MAP: dict[str, str] = {
    "/": "administration/tockmox-ui.md",
    "/status": "administration/tockmox-ui.md",
    "/models": "administration/model-lifecycle.md",
    "/nodes": "administration/inference-nodes.md",
    "/capabilities": "administration/capabilities.md",
    "/platform": "administration/platform-management.md",
    "/platform/updates": "deployment/upgrade.md",
    "/upgrade": "deployment/upgrade.md",
    "/tabs/posture": "administration/posture-probe.md",
    "/about": "administration/tockmox-ui.md",
    "/recovery": "operations/troubleshooting.md",
}


def help_for(path: str) -> str | None:
    """The docs page for a path: the longest matching prefix in HELP_MAP, or None."""
    if path in HELP_MAP:
        return HELP_MAP[path]
    best, score = None, 0
    for p, doc in HELP_MAP.items():
        if p != "/" and path.startswith(p.rstrip("/") + "/") and len(p) > score:
            best, score = doc, len(p)
    return best


def docs_href(docs_url: str, docs_repo_link: str, page: str) -> str:
    """A docs page on the site's own docs server when it has one (docs-site/mkdocs.yml sets
    use_directory_urls: false, so a page is <dir>/<name>.html), else on the source repository at the
    running release."""
    if docs_url:
        return docs_url.rstrip("/") + "/" + page[:-3] + ".html"
    return docs_repo_link.rstrip("/") + "/" + page

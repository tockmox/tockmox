#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert that the BUILT documentation site makes no network request at view time.
#
#   ./tools/check-docs-offline.sh                build the site, then check it
#   ./tools/check-docs-offline.sh --site DIR     check an already-built site
#   ./tools/check-docs-offline.sh --selftest [--site DIR]
#                                                prove the gate goes red
#
# Exit 0 pass, 1 fail, 2 skipped (the pinned generator is absent, so there is
# nothing to build; the same convention as every gate here, see check-all.sh).
# `--site` never needs the generator, and neither does `--selftest`.
#
# WHY THIS READS THE SITE AND NOT docs-site/mkdocs.yml (TM-0215). MkDocs themes
# fetch Google Fonts at page load. A Dark Site that renders a docs page and
# silently reaches for fonts.googleapis.com has broken the claim the whole
# feature exists to support, and `font: false` in the config only proves the
# author asked. The site is what the operator opens, so the site is what gets
# read. A theme upgrade, a plugin, a raw <script> pasted into a page or an image
# hotlinked from a CDN all change the site without touching the config.
#
# WHAT COUNTS. A reference that a browser FETCHES on its own, whose value is an
# http(s) URL or a protocol-relative one (//host/...):
#
#   <link href>            any rel: stylesheet, icon, preload, preconnect,
#                          dns-prefetch, manifest. A hint is a request.
#   <script src>  <img src|srcset>  <iframe src>  <source src|srcset>
#   <video|audio src>  <video poster>  <embed src>  <object data>  <input src>
#   <base href>            re-roots every relative reference on the page
#   <meta http-equiv=refresh content="0; url=...">
#   CSS @import and url(...)   in .css files, <style> blocks, and style=""
#   attributes, and inside .svg files (href / xlink:href and their CSS)
#
# WHAT DOES NOT. A plain <a href> to another site: a link is not a fetch and
# does not break the air-gap claim, it just does not open offline. The build
# rewrites links to pages outside the offline set into exactly these (see
# tools/lib/stage-docs.py), so failing on them would fail on the design.
#
# ONE ARTIFACT-LEVEL ASSERTION BEYOND THE LIST: no page may contain a mermaid
# element. Material's bundled script loads mermaid from unpkg.com the first time
# it finds one, and that URL sits inside minified JavaScript where no reference
# scan can tell a live call from a dead string. The config does not enable the
# fence; this proves no page acquired one. External hosts named inside the JS
# bundles are listed as INFO and do not fail the gate.
#
# A CLEAN RESULT AND AN ABSENT RESULT LOOK IDENTICAL, so the gate also fails if it
# found no pages or checked no references at all: an empty directory must not
# pass. The self-test injects each reference form into a copy of a small
# fixture site (and into a copy of a real one when given `--site`) and requires
# the gate to go red on every one, and to stay green when only an <a href> is
# added.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=check; SITE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest ;;
    --site) SITE="${2:?--site needs a directory}"; shift ;;
    *) echo "usage: $0 [--site DIR] [--selftest]" >&2; exit 64 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: python3 not found" >&2; exit 2; }

if [ "$MODE" = check ] && [ -z "$SITE" ]; then
  SITE="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-docs-site.XXXXXX")"
  trap 'rm -rf "$SITE"' EXIT
  rc=0
  bash tools/build-docs.sh "$SITE" >/dev/null 2>"$SITE.err" || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "SKIPPED: the pinned documentation generator is not installed:"
    sed 's/^/  /' "$SITE.err"; rm -f "$SITE.err"
    exit 2
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL: the docs build itself failed (exit $rc):"; sed 's/^/  /' "$SITE.err"; rm -f "$SITE.err"
    exit 1
  fi
  rm -f "$SITE.err"
fi

exec python3 - "$MODE" "$SITE" <<'PY'
import os, re, shutil, sys, tempfile
from html.parser import HTMLParser

MODE, SITE = sys.argv[1], sys.argv[2]

EXT = re.compile(r"^\s*(?:https?:)?//", re.I)
CSS_URL = re.compile(r"url\(\s*(?:\"([^\"]*)\"|'([^']*)'|([^)\"'\s][^)]*?))\s*\)", re.I)
CSS_IMPORT = re.compile(r"@import\s+(?:url\(\s*)?(?:\"([^\"]*)\"|'([^']*)'|([^)\s;\"']+))", re.I)
CSS_COMMENT = re.compile(r"/\*.*?\*/", re.S)
REFRESH = re.compile(r"url\s*=\s*['\"]?\s*([^'\";]+)", re.I)
URL_ATTRS = {
    "link": ("href",), "script": ("src",), "img": ("src", "srcset"),
    "iframe": ("src",), "source": ("src", "srcset"), "video": ("src", "poster"),
    "audio": ("src",), "embed": ("src",), "object": ("data",), "input": ("src",),
    "base": ("href",), "track": ("src",), "image": ("href", "xlink:href"),
    "use": ("href", "xlink:href"),
}


def is_ext(v):
    return bool(v) and bool(EXT.match(v))


def srcset_urls(v):
    return [p.strip().split()[0] for p in v.split(",") if p.strip()]


def scan_css(text):
    """Yield (kind, url) for every external fetch reference in CSS text."""
    text = CSS_COMMENT.sub("", text)
    for m in CSS_IMPORT.finditer(text):
        u = next(g for g in m.groups() if g is not None)
        if is_ext(u):
            yield "css @import", u
    for m in CSS_URL.finditer(text):
        u = next(g for g in m.groups() if g is not None)
        if is_ext(u):
            yield "css url()", u


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path, self.hits, self.checked = path, [], 0
        self.mermaid = False
        self._in = None
        self._buf = []
        self._script_type = ""

    def _hit(self, kind, url):
        self.hits.append((self.path, self.getpos()[0], kind, url))

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        for name in URL_ATTRS.get(tag, ()):
            if name in a:
                self.checked += 1
                vals = srcset_urls(a[name]) if name == "srcset" else [a[name]]
                for v in vals:
                    if is_ext(v):
                        self._hit("<%s %s>" % (tag, name), v.strip())
        if tag == "meta" and a.get("http-equiv", "").strip().lower() == "refresh":
            self.checked += 1
            m = REFRESH.search(a.get("content", ""))
            if m and is_ext(m.group(1)):
                self._hit("<meta http-equiv=refresh>", m.group(1).strip())
        if "style" in a:
            self.checked += 1
            for k, u in scan_css(a["style"]):
                self._hit("style attribute " + k, u)
        cls = a.get("class", "").split()
        if "mermaid" in cls or tag == "mermaid":
            self.mermaid = True
        if tag in ("style", "script"):
            self._in, self._buf = tag, []
            self._script_type = a.get("type", "").lower()

    def handle_data(self, data):
        if self._in:
            self._buf.append(data)

    def handle_endtag(self, tag):
        if tag == self._in:
            body = "".join(self._buf)
            self.checked += 1
            if tag == "style":
                for k, u in scan_css(body):
                    self._hit("<style> " + k, u)
            elif self._script_type in ("", "text/javascript", "module"):
                # Inline script: an external URL literal is a fetch waiting to happen.
                for m in re.finditer(r"""["'`]\s*((?:https?:)?//[^"'`\s]+)""", body):
                    self._hit("inline <script> URL literal", m.group(1))
            self._in = None


def scan_site(root):
    hits, pages, sheets, checked, js_hosts, mermaid = [], 0, 0, 0, set(), []
    for dp, dn, fn in os.walk(root):
        dn.sort()
        for f in sorted(fn):
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root)
            low = f.lower()
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if low.endswith((".html", ".htm")):
                pages += 1
                pg = Page(rel)
                pg.feed(text); pg.close()
                hits += pg.hits; checked += pg.checked
                if pg.mermaid:
                    mermaid.append(rel)
            elif low.endswith(".css"):
                sheets += 1; checked += 1
                for k, u in scan_css(text):
                    hits.append((rel, 0, k, u))
            elif low.endswith(".svg"):
                checked += 1
                for m in re.finditer(r"""(?:xlink:)?href\s*=\s*["']([^"']*)["']""", text):
                    if is_ext(m.group(1)):
                        hits.append((rel, 0, "svg href", m.group(1)))
                for k, u in scan_css(text):
                    hits.append((rel, 0, "svg " + k, u))
            elif low.endswith(".js"):
                for m in re.finditer(r"https?://([A-Za-z0-9.-]+)", text):
                    js_hosts.add(m.group(1))
    return hits, pages, sheets, checked, js_hosts, mermaid


def report(root, quiet=False):
    hits, pages, sheets, checked, js_hosts, mermaid = scan_site(root)
    problems = []
    if pages == 0:
        problems.append("no HTML pages found under %s; an empty site must not pass" % root)
    if checked == 0:
        problems.append("checked zero references; the scan is not looking at anything")
    for rel in mermaid:
        problems.append("%s contains a mermaid element (Material would load mermaid from unpkg.com)" % rel)
    for rel, line, kind, url in hits:
        problems.append("%s%s: %s -> %s" % (rel, (":%d" % line) if line else "", kind, url))
    if not quiet:
        print("scanned %d HTML pages, %d stylesheets; %d reference sites examined" % (pages, sheets, checked))
        if js_hosts:
            print("INFO  hosts named inside JavaScript (not scanned as fetches; the mermaid assertion "
                  "covers the one that matters): " + ", ".join(sorted(js_hosts)))
        for p in problems[:60]:
            print("  FAIL  " + p)
        if len(problems) > 60:
            print("  ... and %d more" % (len(problems) - 60))
        print("FAIL: %d problem(s)" % len(problems) if problems else
              "PASS: no page, stylesheet or SVG in the built site references an external host")
    return not problems


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


CLEAN_HTML = """<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="assets/a.css"><link rel="icon" href="assets/i.svg">
<script src="assets/a.js"></script></head><body>
<img src="assets/i.svg" srcset="assets/i.svg 1x, assets/i.svg 2x">
<a href="https://example.org/upstream.md">a plain link</a></body></html>"""


def fixture(root):
    write(os.path.join(root, "index.html"), CLEAN_HTML)
    write(os.path.join(root, "assets/a.css"), "@import url('b.css');\n.x{background:url(i.svg)}\n")
    write(os.path.join(root, "assets/b.css"), "/* url(https://commented.example) is not a fetch */ .y{color:red}\n")
    write(os.path.join(root, "assets/a.js"), "var x=1;\n")
    write(os.path.join(root, "assets/i.svg"), "<svg xmlns='http://www.w3.org/2000/svg'></svg>")


INJECT = [
    ("stylesheet link (Google Fonts)", "index.html", "</head>", '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Roboto"></head>'),
    ("preconnect hint", "index.html", "</head>", '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin></head>'),
    ("dns-prefetch, protocol-relative", "index.html", "</head>", '<link rel="dns-prefetch" href="//fonts.googleapis.com"></head>'),
    ("script src, protocol-relative", "index.html", "</head>", '<script src="//cdn.example.net/x.js"></script></head>'),
    ("script src, upper-case scheme", "index.html", "</head>", '<script src="HTTPS://cdn.example.net/x.js"></script></head>'),
    ("img src", "index.html", "</body>", '<img src="http://images.example.net/x.png"></body>'),
    ("img srcset", "index.html", "</body>", '<img srcset="a.png 1x, https://images.example.net/x.png 2x"></body>'),
    ("iframe src", "index.html", "</body>", '<iframe src="https://embed.example.net/"></iframe></body>'),
    ("source src", "index.html", "</body>", '<video><source src="https://media.example.net/v.mp4"></video></body>'),
    ("meta refresh", "index.html", "</head>", '<meta http-equiv="refresh" content="0; url=https://elsewhere.example.net/"></head>'),
    ("inline <style> @import", "index.html", "</head>", '<style>@import "https://fonts.example.net/f.css";</style></head>'),
    ("style attribute url()", "index.html", "</body>", '<div style="background:url(//img.example.net/b.png)"></div></body>'),
    ("mermaid element", "index.html", "</body>", '<pre class="mermaid">graph TD; A-->B</pre></body>'),
    ("CSS @import url()", "assets/a.css", "@import url('b.css');", "@import url('https://fonts.example.net/f.css');"),
    ("CSS @import string", "assets/a.css", "@import url('b.css');", '@import "//fonts.example.net/f.css";'),
    ("CSS font-face url()", "assets/b.css", ".y{color:red}", "@font-face{font-family:F;src:url(https://fonts.gstatic.example/f.woff2)}"),
    ("SVG href", "assets/i.svg", "</svg>", "<image href='https://img.example.net/x.png'/></svg>"),
    # The remaining forms the header promises to catch. Each is the only thing its case adds, so a
    # form dropped from URL_ATTRS, or the <style> and inline-script scans, stays green no longer.
    ("source srcset", "index.html", "</body>", '<picture><source srcset="https://images.example.net/x.webp 1x"></picture></body>'),
    ("video src", "index.html", "</body>", '<video src="https://media.example.net/v.mp4"></video></body>'),
    ("video poster", "index.html", "</body>", '<video poster="https://media.example.net/p.png"></video></body>'),
    ("audio src", "index.html", "</body>", '<audio src="https://media.example.net/a.mp3"></audio></body>'),
    ("embed src", "index.html", "</body>", '<embed src="https://embed.example.net/x.swf"></body>'),
    ("object data", "index.html", "</body>", '<object data="https://embed.example.net/x.pdf"></object></body>'),
    ("input src", "index.html", "</body>", '<input type="image" src="https://img.example.net/b.png"></body>'),
    ("track src", "index.html", "</body>", '<video><track src="https://captions.example.net/c.vtt"></video></body>'),
    ("base href", "index.html", "</head>", '<base href="https://elsewhere.example.net/"></head>'),
    ("svg use href in a page", "index.html", "</body>", '<svg><use href="https://sprites.example.net/s.svg#i"></use></svg></body>'),
    ("svg use xlink:href in a page", "index.html", "</body>", '<svg><use xlink:href="https://sprites.example.net/s.svg#i"></use></svg></body>'),
    ("svg image href in a page", "index.html", "</body>", '<svg><image href="https://img.example.net/x.png"></image></svg></body>'),
    ("svg image xlink:href in a page", "index.html", "</body>", '<svg><image xlink:href="https://img.example.net/x.png"></image></svg></body>'),
    ("inline <style> url(), unquoted", "index.html", "</head>", '<style>.z{background:url(https://img.example.net/b.png)}</style></head>'),
    ("inline <script> URL literal", "index.html", "</body>", '<script>var u = "https://cdn.example.net/x.js";</script></body>'),
]


def selftest(real):
    bad = 0
    tmp = tempfile.mkdtemp(prefix="docs-offline-selftest.")
    try:
        base = os.path.join(tmp, "clean"); fixture(base)
        print("-- control: the clean fixture must pass")
        if not report(base, quiet=True):
            print("  SELFTEST FAIL: the clean fixture was rejected"); bad += 1
        else:
            print("  ok")
        ctl = os.path.join(tmp, "anchor"); shutil.copytree(base, ctl)
        p = os.path.join(ctl, "index.html"); s = open(p).read()
        open(p, "w").write(s.replace("</body>", '<a href="https://elsewhere.example.net/x">x</a></body>'))
        print("-- control: an added plain <a href> must still pass")
        if not report(ctl, quiet=True):
            print("  SELFTEST FAIL: a plain anchor was rejected"); bad += 1
        else:
            print("  ok")
        print("-- each injected reference must turn the gate red")
        for i, (name, rel, anchor, repl) in enumerate(INJECT):
            d = os.path.join(tmp, "m%d" % i); shutil.copytree(base, d)
            p = os.path.join(d, rel); s = open(p).read()
            if anchor not in s:
                print("  SELFTEST BROKEN: anchor for %r not in fixture" % name); bad += 1; continue
            open(p, "w").write(s.replace(anchor, repl, 1))
            if report(d, quiet=True):
                print("  SELFTEST FAIL: %s stayed green" % name); bad += 1
            else:
                print("  red, as required: %s" % name)
        print("-- an empty directory must not pass")
        e = os.path.join(tmp, "empty"); os.makedirs(e)
        if report(e, quiet=True):
            print("  SELFTEST FAIL: an empty site passed"); bad += 1
        else:
            print("  red, as required")
        print("-- a site with no pages, and a page with nothing to check, must not pass either")
        for name, rel, text in (("only-css", "assets/a.css", ".x{}"), ("bare-page", "index.html", "<!doctype html><title>x</title>")):
            write(os.path.join(tmp, name, rel), text)
            if report(os.path.join(tmp, name), quiet=True):
                print("  SELFTEST FAIL: %s passed" % name); bad += 1
            else:
                print("  red, as required: %s" % name)
        if real:
            print("-- the real site, mutated in a copy")
            d = os.path.join(tmp, "real"); shutil.copytree(real, d)
            if not report(d, quiet=True):
                print("  NOTE: the real site is already red; run without --selftest to see why")
            else:
                p = os.path.join(d, "index.html"); s = open(p).read()
                open(p, "w").write(s.replace("</head>", '<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Roboto"></head>', 1))
                if report(d, quiet=True):
                    print("  SELFTEST FAIL: the real site stayed green with Google Fonts injected"); bad += 1
                else:
                    print("  red, as required: Google Fonts stylesheet injected into a copy of the real index.html")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST FAILED (%d)" % bad if bad else "SELFTEST PASSED")
    return bad == 0


if MODE == "selftest":
    sys.exit(0 if selftest(SITE or None) else 1)
sys.exit(0 if report(SITE) else 1)
PY

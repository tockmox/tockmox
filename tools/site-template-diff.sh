#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# COMPARE tockmox-site-template WITH WHAT THE INSTALLER GENERATES (TM-0621).
#
#   tools/site-template-diff.sh <path to a tockmox-site-template checkout>
#
# Generates a site with install/tockmox-install.sh --no-cluster from a config
# built out of the template's OWN values (domain, LAN, pool, storage classes,
# the release it pins), so the two should differ only where the template means
# to, and then compares:
#
#   files         present in one and not the other
#   YAML files    by parsed content, so comments and key order do not count;
#                 PLACEHOLDER_SITE_REPO_URL against the generated site's URL is
#                 the one value difference allowed everywhere
#   .gitignore    every pattern the installer writes must be in the template
#                 (the template may ignore more)
#   prose         skipped, as listed
#
# Every difference not recorded in tools/site-template-divergences.txt is
# printed and fails the run. Run it at each release, before the template
# re-pin (RELEASING.md), against the tree about to be tagged.
set -uo pipefail
TPL="${1:?usage: $0 <tockmox-site-template checkout>}"
TPL="$(cd "$TPL" 2>/dev/null && pwd)" || { echo "site-template-diff: no such directory: $1"; exit 2; }
cd "$(dirname "$0")/.."
[ -f "$TPL/site/values/global.yaml" ] || { echo "site-template-diff: $TPL is not a site template checkout"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "site-template-diff: python3 PyYAML missing"; exit 2; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
python3 - "$TPL" "$work" <<'PY' || exit 2
import sys, yaml, glob, re
tpl, work = sys.argv[1:3]
g = (yaml.safe_load(open(f"{tpl}/site/values/global.yaml")) or {}).get("global") or {}
plat = yaml.safe_load(open(f"{tpl}/site/values/platform.yaml")) or {}
rev = None
for f in glob.glob(f"{tpl}/bootstrap/applications/tockmox-*.yaml"):
    for src in (yaml.safe_load(open(f)) or {}).get("spec", {}).get("sources", []):
        if src.get("path", "").startswith("charts/"):
            rev = src.get("targetRevision")
layers = sorted(re.sub(r".*/tockmox-(.*)\.yaml", r"\1", f) for f in glob.glob(f"{tpl}/bootstrap/applications/tockmox-*.yaml"))
cfg = {
  "site": {"name": "template-compare", "path": f"{work}/site"},
  "tockmox": {"revision": rev or "main", "repoURL": "https://github.com/tockmox/tockmox.git"},
  "global": {k: g.get(k, "") for k in ("internalDomain", "certIssuer", "lanCIDR", "clusterCIDR", "serviceCIDR", "timezone", "imageRegistry", "storageClass", "localStorageClass")},
  "addressPool": {"range": (plat.get("addressPool") or {}).get("range", "")},
  "layers": {l: (l in layers) for l in ("crds", "policy", "platform", "observability", "exporters", "identity", "devops", "ai", "selfcheck")},
  "argocd": {"namespace": "argocd", "autoSync": True, "selfHeal": True},
}
open(f"{work}/cfg.yaml", "w").write(yaml.safe_dump(cfg, sort_keys=False))
print(f"template pins {rev}; generating with the installer in this tree")
PY
bash install/tockmox-install.sh --config "$work/cfg.yaml" --no-cluster > "$work/install.log" 2>&1 \
  || { echo "site-template-diff: the installer failed"; tail -20 "$work/install.log"; exit 2; }

python3 - "$TPL" "$work/site" tools/site-template-divergences.txt <<'PY'
import os, sys, yaml
tpl, gen, rec = sys.argv[1:4]
allowed = {"only-template": set(), "only-generated": set(), "prose": set()}
for line in open(rec):
    line = line.strip()
    if line and not line.startswith("#"):
        kind, path = line.split(None, 1)
        allowed.setdefault(kind, set()).add(path)
def files(root):
    out = set()
    for d, _, fs in os.walk(root):
        if "/.git" in d + "/" and "/.github" not in d: continue
        for f in fs:
            p = os.path.relpath(os.path.join(d, f), root)
            if not p.startswith(".git/"): out.add(p)
    return out
T, G = files(tpl), files(gen)
problems = []
for p in sorted(T - G):
    if p not in allowed["only-template"]: problems.append(f"only in the template: {p}")
for p in sorted(G - T):
    if p not in allowed["only-generated"]: problems.append(f"only in a generated site: {p}")
for kind in ("only-template", "only-generated"):
    for p in sorted(allowed[kind]):
        if (kind == "only-template" and p not in T - G) or (kind == "only-generated" and p not in G - T):
            problems.append(f"recorded as {kind} but no longer is: {p} (update the record)")
GEN_URL = None
def norm(v):
    if isinstance(v, dict): return {k: norm(x) for k, x in v.items()}
    if isinstance(v, list): return [norm(x) for x in v]
    if isinstance(v, str) and v in ("PLACEHOLDER_SITE_REPO_URL",): return "<SITE_REPO>"
    return v
def diff(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b), key=str):
            if k not in a: out.append(f"{path}.{k}: only in the template ({b[k]!r})"[:220])
            elif k not in b: out.append(f"{path}.{k}: only in a generated site ({a[k]!r})"[:220])
            else: out += diff(a[k], b[k], f"{path}.{k}")
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        out = []
        for i, (x, y) in enumerate(zip(a, b)): out += diff(x, y, f"{path}[{i}]")
        return out
    return [] if a == b else [f"{path}: generated {a!r}, template {b!r}"[:220]]
for p in sorted(T & G):
    if p in allowed["prose"]: continue
    if p.endswith((".yaml", ".yml")):
        a = [norm(d) for d in yaml.safe_load_all(open(os.path.join(gen, p)))]
        b = [norm(d) for d in yaml.safe_load_all(open(os.path.join(tpl, p)))]
        # the generated site's own repoURL is whatever the installer wrote
        a = [norm(yaml.safe_load(yaml.safe_dump(d).replace("PLACEHOLDER_SITE_REPO_URL", "<SITE_REPO>"))) for d in a]
        for line in diff(a, b): problems.append(f"{p}: {line}")
    elif os.path.basename(p) == ".gitignore":
        pats = lambda f: {l.strip() for l in open(f) if l.strip() and not l.lstrip().startswith("#")}
        missing = sorted(pats(os.path.join(gen, p)) - pats(os.path.join(tpl, p)))
        for m in missing: problems.append(f"{p}: the installer ignores {m!r} and the template does not")
    else:
        if open(os.path.join(gen, p), "rb").read() != open(os.path.join(tpl, p), "rb").read():
            problems.append(f"{p}: differs, and is not YAML, a .gitignore or recorded prose")
if problems:
    print("site-template-diff: UNRECORDED DIFFERENCES")
    for x in problems: print("  " + x)
    sys.exit(1)
print(f"site-template-diff: no unrecorded difference ({len(T & G)} shared files compared)")
PY

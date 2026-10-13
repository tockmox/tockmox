#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Generate the deployment SBOM: sbom.cdx.json (CycloneDX 1.5) at the repo root.
#
# WHAT THIS SBOM IS, PRECISELY. Tockmox distributes source ... charts, an
# installer, documentation ... and no binaries, so a conventional "scan the
# artifact" SBOM of this repository would list a shell script and some YAML
# and prove nothing anyone asks about. What a deployer and a regulator both
# actually want enumerated is what an INSTALL comprises: the container images
# a default deployment pulls and the upstream Helm charts each layer wraps.
# That is exactly what this file contains, and nothing else:
#
#   - one component per image in images.txt (regenerate it first if charts
#     changed: tools/gen-images.sh)
#   - one component per upstream chart dependency, with its pinned version
#   - the licenses as registered in docs/third-party-licenses.md is the
#     human-readable companion; this file is the machine-readable one
#
# What it does NOT contain: the transitive package contents of each image.
# Those SBOMs belong to the upstream projects that build the images; several
# publish them. Restating them here would assert knowledge this repository
# does not have.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import json, re, os, sys, hashlib, datetime

images = []
with open('images.txt') as fh:
    for line in fh:
        line = line.strip()
        if line and not line.startswith('#'):
            images.append(line)

charts = []
for layer in sorted(os.listdir('charts')):
    cy = os.path.join('charts', layer, 'Chart.yaml')
    if not os.path.exists(cy):
        continue
    name = ver = None
    deps = []
    dep = {}
    in_deps = False
    for raw in open(cy):
        line = raw.rstrip('\n')
        if line.startswith('name:'):
            name = line.split(':', 1)[1].strip()
        elif line.startswith('version:') and not in_deps:
            ver = line.split(':', 1)[1].strip().strip('"')
        elif line.startswith('dependencies:'):
            in_deps = True
        elif in_deps and re.match(r'\s+- name:', line):
            if dep.get('name'):
                deps.append(dep)
            dep = {'name': line.split(':', 1)[1].strip()}
        elif in_deps and re.match(r'\s+version:', line) and dep is not None:
            dep['version'] = line.split(':', 1)[1].strip().strip('"')
        elif in_deps and re.match(r'\s+repository:', line) and dep is not None:
            dep['repository'] = line.split(':', 1)[1].strip().strip('"')
    if dep.get('name'):
        deps.append(dep)
    charts.append({'name': name, 'version': ver, 'deps': deps})

root_version = next((c['version'] for c in charts if c['name'] == 'tockmox-platform'), '0.0.0')

components = []
for img in sorted(set(images)):
    ref = img
    digest = None
    if '@sha256:' in ref:
        ref, digest = ref.split('@', 1)
    tag = None
    if ':' in ref.rsplit('/', 1)[-1]:
        base, tag = ref.rsplit(':', 1)
    else:
        base = ref
    name = base.rsplit('/', 1)[-1]
    purl = f"pkg:oci/{name}"
    if digest:
        purl += f"@{digest}"
    quals = []
    if '/' in base:
        quals.append("repository_url=" + base)
    if tag:
        quals.append("tag=" + tag)
    if quals:
        purl += "?" + "&".join(quals)
    components.append({
        "type": "container",
        "name": base,
        "version": digest or tag or "latest",
        "purl": purl,
    })

for c in charts:
    for d in c['deps']:
        if d['name'].startswith('tockmox-'):
            continue
        components.append({
            "type": "application",
            "name": d['name'],
            "version": d.get('version', ''),
            "purl": f"pkg:generic/helm/{d['name']}@{d.get('version','')}",
            "description": f"Helm chart dependency of {c['name']}",
        })

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "version": 1,
    "metadata": {
        # No timestamp, deliberately: the SBOM is a function of the tree, and
        # a byte-identical tree must produce a byte-identical SBOM or its
        # checksum is noise.
        "component": {
            "type": "application",
            "name": "tockmox",
            "version": root_version,
            "licenses": [{"license": {"id": "Apache-2.0"}}],
        },
    },
    "components": components,
}

# --check compares and REFUSES; it never writes. Added 2026-09-13.
#
# `tools/check-all.sh` has called `gen-sbom.sh --check` for the gate it labels
# "the committed SBOM matches the tree" since that gate was written. This script
# had no argument parsing at all, so `--check` was ignored: every run
# REGENERATED sbom.cdx.json in place and exited 0. A committed SBOM listing zero
# components against a tree with sixty-three was silently corrected on disk and
# reported as a pass. The gate could not fail, and worse, it destroyed the
# evidence of the mismatch it existed to find.
#
# ci.yaml got this right by accident of shape ... it runs the generator and then
# `git diff --exit-code`, two steps. This is that second step, in the one place
# a contributor is told to run before pushing.
rendered = json.dumps(bom, indent=2, sort_keys=True) + '\n'

if '--check' in sys.argv[1:]:
    try:
        with open('sbom.cdx.json') as fh:
            committed = fh.read()
    except FileNotFoundError:
        print("check-sbom: sbom.cdx.json is MISSING. Run tools/gen-sbom.sh to write it.")
        sys.exit(1)
    if committed != rendered:
        print("check-sbom: the committed sbom.cdx.json does NOT match the tree.")
        print("            Nothing was written. Run tools/gen-sbom.sh and commit the result.")
        import difflib
        diff = list(difflib.unified_diff(
            committed.splitlines(), rendered.splitlines(),
            fromfile='sbom.cdx.json (committed)', tofile='rendered from the tree',
            lineterm='', n=1))
        for line in diff[:40]:
            print("  " + line)
        if len(diff) > 40:
            print(f"  ... {len(diff) - 40} more diff line(s)")
        sys.exit(1)
    print(f"sbom.cdx.json matches the tree: {len(components)} components")
    sys.exit(0)

with open('sbom.cdx.json', 'w') as fh:
    fh.write(rendered)

print(f"sbom.cdx.json: {len(components)} components "
      f"({sum(1 for x in components if x['type']=='container')} images, "
      f"{sum(1 for x in components if x['type']=='application')} charts) "
      f"for tockmox {root_version}")
PY

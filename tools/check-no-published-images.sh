#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# No workflow may publish a container image or any other OCI artifact.
# ADR-0036, TM-0098, TM-0805.
#
#   ./tools/check-no-published-images.sh              scan the workflows
#   ./tools/check-no-published-images.sh --selftest   prove the scan goes red
#   ./tools/check-no-published-images.sh --dir DIR    scan DIR instead (used by the selftest)
#
# WHY. ADR-0036: the repository distributes source, never compiled artifacts or
# container images. The docs image workflow (docs-image.yaml, TM-0215, deleted by
# TM-0808) pushed ghcr.io/tockmox/tockmox-docs on every `v*` tag, and nobody
# noticed that it broke the ADR until the day before the first tag that would
# have run it. The docs now reach a cluster through tools/publish-docs.sh.
# Publishing an image also conveys whatever copyleft software sits in its layers
# (TM-0098). TM-0098's close condition is "a check confirms no workflow pushes an
# image"; this is that check.
#
# WHAT IT SCANS. Every .github/workflows/*.yaml and *.yml, and every composite
# action under .github/actions/. It does NOT scan .github/workflows-disabled/,
# which GitHub Actions never runs.
#
# WHAT IT FLAGS, per step, after full-line comments are dropped:
#   - a `uses:` of docker/build-push-action whose `push` input is anything but a
#     literal false (an expression is treated as possibly true), or that sets
#     `outputs: type=registry`
#   - a `uses:` of docker/login-action or redhat-actions/push-to-registry, or an
#     actions/attest* step with push-to-registry
#   - in a `run:` script: docker push, docker login, docker build/buildx/bake
#     with --push, docker buildx imagetools create, buildah push, podman push,
#     podman/buildah login, skopeo copy, crane push/copy/append, oras push,
#     ko publish, ko build --push, helm push, helm registry login, cosign
#     attach / copy
#   - `packages: write` (or `write-all`) in any `permissions` block, workflow or
#     job level, which is what pushing to ghcr.io needs
#
# WHAT THIS DOES NOT PROVE. It reads workflow text. A push made by a script the
# workflow merely calls (`./release.sh`), by a tool under a name this list does
# not know, or with a token minted some other way, is not seen. It is blind to a
# workflow in another repository. It also cannot tell a command from the same
# words inside an echo. It proves that today no workflow file says any of the
# above; the selftest proves each pattern goes red on a fixture, that a fixture
# that only builds stays green, and that the workflow this gate exists because of
# would have gone red.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=".github/workflows"
MODE=scan
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest; shift ;;
    --dir) DIR="$2"; shift 2 ;;
    -h|--help) sed -n 2,45p "$0"; exit 0 ;;
    *) echo "check-no-published-images: unknown argument $1" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null 2>&1 || { echo "check-no-published-images: python3 not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-no-published-images: python3 PyYAML missing" >&2; exit 2; }

scan() {
  # $1 = workflows dir; $2 = composite actions dir (may be absent)
  python3 - "$1" "${2:-}" <<'PY'
import glob, os, re, sys, yaml

wfdir, actdir = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(wfdir, "*.yaml")) + glob.glob(os.path.join(wfdir, "*.yml")))
if actdir and os.path.isdir(actdir):
    files += sorted(glob.glob(os.path.join(actdir, "**", "action.y*ml"), recursive=True))
if not files:
    print("check-no-published-images: no workflow files under %s; a scan of nothing proves nothing" % wfdir)
    sys.exit(2)

RUN_PATTERNS = [
    ("docker push",                 r"\bdocker\s+(image\s+)?push\b"),
    ("docker login",                r"\bdocker\s+login\b"),
    ("docker build/buildx/bake --push", r"\bdocker\s+(buildx\s+)?(build|bake)\b[^\n]*--push\b"),
    ("docker buildx output type=registry", r"\bdocker\s+(buildx\s+)?(build|bake)\b[^\n]*type=registry"),
    ("docker buildx imagetools create", r"\bimagetools\s+create\b"),
    ("buildah push",                r"\bbuildah\s+push\b"),
    ("podman push",                 r"\bpodman\s+push\b"),
    ("podman/buildah login",        r"\b(podman|buildah)\s+login\b"),
    ("skopeo copy",                 r"\bskopeo\s+copy\b"),
    ("crane push/copy/append",      r"\bcrane\s+(push|copy|cp|append)\b"),
    ("oras push",                   r"\boras\s+push\b"),
    ("ko publish",                  r"\bko\s+publish\b"),
    ("ko build --push",             r"\bko\s+build\b[^\n]*--push\b"),
    ("helm push",                   r"\bhelm\s+push\b"),
    ("helm registry login",         r"\bhelm\s+registry\s+login\b"),
    ("cosign attach/copy",          r"\bcosign\s+(attach|copy)\b"),
]
USES_ALWAYS = ["docker/login-action", "redhat-actions/push-to-registry"]

findings = []
steps_seen = 0

def not_literal_false(v):
    if isinstance(v, bool): return v
    if v is None: return False
    return str(v).strip().lower() not in ("false", "0", "no", "off", "")

def check_perms(where, perms):
    if perms == "write-all":
        findings.append((where, "permissions: write-all (includes packages: write)"))
    elif isinstance(perms, dict) and str(perms.get("packages", "")).lower() == "write":
        findings.append((where, "permissions: packages: write"))

def strip_comments(script):
    out = []
    for ln in script.splitlines():
        if ln.lstrip().startswith("#"): continue
        out.append(re.sub(r"\s#\s.*$", "", ln))
    return "\n".join(out)

for f in files:
    try:
        doc = yaml.safe_load(open(f))
    except Exception as e:
        findings.append((f, "does not parse as YAML (%s); an unparsed file is an unscanned file" % str(e).splitlines()[0])); continue
    if not isinstance(doc, dict):
        findings.append((f, "is not a YAML mapping")); continue
    check_perms(f + " (workflow level)", doc.get("permissions"))
    jobs = doc.get("jobs") or {}
    stepsets = []
    for jn, job in (jobs.items() if isinstance(jobs, dict) else []):
        if not isinstance(job, dict): continue
        check_perms("%s job %s" % (f, jn), job.get("permissions"))
        stepsets.append(("%s job %s" % (f, jn), job.get("steps") or []))
    runs = doc.get("runs")
    if isinstance(runs, dict) and runs.get("using") == "composite":
        stepsets.append((f + " (composite action)", runs.get("steps") or []))
    for where, steps in stepsets:
        for i, st in enumerate(steps, 1):
            if not isinstance(st, dict): continue
            steps_seen += 1
            label = "%s step %d (%s)" % (where, i, st.get("name", st.get("uses", "run")))
            uses = str(st.get("uses", "")).split("@")[0].lower()
            w = st.get("with") or {}
            if uses == "docker/build-push-action":
                if "push" in w and not_literal_false(w["push"]):
                    findings.append((label, "docker/build-push-action with push: %r" % (w["push"],)))
                elif "type=registry" in str(w.get("outputs", "")):
                    findings.append((label, "docker/build-push-action outputs type=registry"))
            elif uses in USES_ALWAYS:
                findings.append((label, "uses %s (a registry login or push action)" % uses))
            elif uses.startswith("actions/attest") and not_literal_false(w.get("push-to-registry", False)):
                findings.append((label, "%s with push-to-registry" % uses))
            run = st.get("run")
            if isinstance(run, str):
                text = strip_comments(run)
                for name, pat in RUN_PATTERNS:
                    if re.search(pat, text, re.I):
                        findings.append((label, "run script: %s" % name))

for where, why in findings:
    print("FAIL %s: %s" % (where, why))
if findings:
    print("check-no-published-images: FAILED (%d finding(s)). ADR-0036: Tockmox publishes no container images." % len(findings))
    sys.exit(1)
print("  scanned %d workflow/action file(s), %d step(s)" % (len(files), steps_seen))
print("check-no-published-images: ok, no workflow publishes an image")
PY
}

if [ "$MODE" = scan ]; then
  scan "$DIR" ".github/actions"
  exit $?
fi

# ------------------------------------------------------------------ selftest
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mk() { mkdir -p "$tmp/$1"; cat > "$tmp/$1/w.yaml"; }
expect_red() {  # fixture dir name, fragment the finding must contain
  local out rc=0
  out=$(scan "$tmp/$1" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || { echo "selftest FAIL: $1 did not go red (exit $rc): $out"; exit 1; }
  printf '%s' "$out" | grep -q -- "$2" || { echo "selftest FAIL: $1 went red on the wrong finding: $out"; exit 1; }
  echo "selftest ok: $1 goes red ($2)"
}

mk clean <<'YAML'
name: clean
on: pull_request
permissions:
  contents: read
  packages: read
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: build only
        uses: docker/build-push-action@v6
        with:
          push: false
          tags: example.invalid/x:1
      - name: comments only
        run: |
          # docker push is forbidden here
          docker build -t example.invalid/x:1 .
YAML
out=$(scan "$tmp/clean" 2>&1) || { echo "selftest FAIL: the clean fixture went red: $out"; exit 1; }
printf '%s' "$out" | grep -q 'scanned 1 workflow/action file(s), 3 step(s)' \
  || { echo "selftest FAIL: the clean fixture went green without being read: $out"; exit 1; }
echo "selftest ok: a workflow that builds without pushing, reads packages and mentions push in a comment stays green (and was read)"

mk bp <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/build-push-action@v6
        with:
          push: true
YAML
expect_red bp "docker/build-push-action with push"
mk bpexpr <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/build-push-action@v6
        with:
          push: ${{ github.event_name == 'push' }}
YAML
expect_red bpexpr "docker/build-push-action with push"
mk bpreg <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/build-push-action@v6
        with:
          outputs: type=registry,name=example.invalid/x
YAML
expect_red bpreg "type=registry"
mk login <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
YAML
expect_red login "registry login or push action"
mk perm <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - run: echo hi
YAML
expect_red perm "packages: write"
mk permall <<'YAML'
name: x
on: push
permissions: write-all
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
expect_red permall "write-all"
i=0
while IFS='|' read -r cmd frag; do
  i=$((i + 1))
  mkdir -p "$tmp/r$i"
  printf 'name: x\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          %s\n' "$cmd" > "$tmp/r$i/w.yaml"
  expect_red "r$i" "$frag"
done <<'CASES'
docker push example.invalid/x:1|run script: docker push
docker login -u u -p p example.invalid|run script: docker login
docker buildx build --platform linux/amd64 -t example.invalid/x:1 --push .|--push
docker buildx imagetools create -t example.invalid/x:2 example.invalid/x:1|imagetools create
buildah push example.invalid/x:1 docker://example.invalid/x:1|buildah push
podman push example.invalid/x:1|podman push
skopeo copy dir:out docker://example.invalid/x:1|skopeo copy
crane push image.tar example.invalid/x:1|crane push
oras push example.invalid/x:1 file.txt|oras push
ko publish ./cmd/x|ko publish
helm push chart.tgz oci://example.invalid/charts|helm push
helm registry login example.invalid -u u|helm registry login
cosign attach sbom --sbom s.json example.invalid/x:1|cosign attach
CASES

# The regression this gate exists because of, rebuilt as a fixture now that the
# real workflow is deleted (TM-0808): a tag-triggered build-and-push to ghcr.io
# with the token permission it needs.
mkdir -p "$tmp/real"
cat > "$tmp/real/docs-image.yaml" <<'YAML'
name: docs-image
on:
  push:
    tags: ['v*']
permissions:
  contents: read
  packages: write
jobs:
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: ghcr.io/example/docs:latest
YAML
expect_red real "packages: write"
mkdir -p "$tmp/empty"; rc=0; scan "$tmp/empty" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "selftest FAIL: an empty directory exited $rc, want 2 (skipped, never a pass)"; exit 1; }
echo "selftest ok: a directory with no workflow files is exit 2, not a pass"
echo "selftest: all legs ok"

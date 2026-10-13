#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Render every layer chart at two points and refuse a change to a field that
# Kubernetes will not let an existing object take (TM-0754).
#
#   tools/check-immutable-fields.sh                       baseline tag vs the working tree
#   tools/check-immutable-fields.sh --base REF [--head REF]
#   tools/check-immutable-fields.sh --base-dir A --head-dir B   two directories holding charts/ and ci/
#   tools/check-immutable-fields.sh --perturb-images      the tree vs itself with every image tag changed
#   tools/check-immutable-fields.sh --selftest            prove it goes red, and green
#
# Options:  --repo DIR   git repository the REFs come from (default: here)
#           --layers "tockmox-platform tockmox-ai"   only these layers
#           --values FILE ...   render both sides with these value files instead
#                               of each side's own ci/values.yaml (+ all-on overlay)
# Environment: BASELINE_REF (as check-values-tiers.sh: `git describe --tags`
#           lies once an rc exists), IMMUTABLE_DEPS_DIR (extra *.tgz subcharts).
#
# WHY RENDERED OUTPUT. "No template file changed" does not mean "no rendered
# manifest changed": `helm.sh/chart` is rendered from Chart.yaml's version, so a
# version bump alone rewrites a label inside every pod template. On a Job, whose
# spec.template is immutable, that is refused at upgrade (v0.6.1-rc1, TM-0753)
# while a fresh install passes. The patch bar's entry condition reads template
# SOURCE and could not see it. This reads the rendered artifact.
#
# WHAT IT FLAGS (an object present at both points, with the field different):
#   Job                              spec.template, spec.selector  ... unless the
#       Job is an Argo CD hook (argocd.argoproj.io/hook) or a Helm hook whose
#       hook-delete-policy includes BeforeHookCreation: that policy deletes the
#       old Job before the new one is created. An Argo CD hook with NO
#       hook-delete-policy gets that policy by Argo's default (TM-1031). A Job whose NAME changes is a
#       different object and is not compared (the TM-0753 fix: the chart version
#       is in the name).
#   Deployment, DaemonSet, StatefulSet   spec.selector
#   StatefulSet                      spec.serviceName, spec.volumeClaimTemplates,
#                                    spec.podManagementPolicy
#   Service                          spec.clusterIP (when both sides set one)
#   PersistentVolumeClaim            spec.storageClassName, accessModes, volumeName
# It does NOT refuse a rendered diff as such: a version bump rewrites labels
# everywhere, and refusing every bump would get the check turned off. A diff
# that touches only mutable fields (labels on a Deployment's pod template, an
# image, a ConfigMap) is green, and the summary says how large it was.
#
# --perturb-images (TM-1022). The baseline-tag run cannot see a dependency bump
# INSIDE one version: a site that follows a branch (the homelab) moves between
# two heads with the same chart version, and a Job named after the version
# keeps its name while Renovate changes its image. On 2026-10-11 that stranded
# the homelab's platform sync (`tockmox-garage-credentials-0-8-0`, alpine/k8s
# 1.36.2 to 1.37.1). This mode renders the tree twice, the second time with
# every `image: repo:tag` and `...Image: repo:tag` in the layer charts' values
# and ci/ values rewritten to a different tag, and applies the same rules: a
# Job that survives with its name must not have a changed template. A Job named
# after its own pod template (sha256) passes by construction.
#
# AN ALLOW LIST, tools/immutable-fields-allow.txt (HEAD tree), for a hit that is
# handled elsewhere: `<layer> <Kind> <name> <field> # reason`. Allowed hits are
# still printed. Entries that match nothing are printed too, so they get removed.
#
# LIMITS. Only the kinds above. Values: each side's own ci/values.yaml and
# ci/values-all-on.yaml, which is a CI fixture and not a site; a site that sets
# more (a StatefulSet from a subchart switched on) must run it with `--values`.
# Subcharts come from this tree's vendored charts/*/charts (or IMMUTABLE_DEPS_DIR)
# by name and version; when the exact version is missing the nearest vendored one
# is used and the run says so, so after tools/helm-deps.sh that never happens. The
# CRD layer is skipped (CRDs only; some schemas do not load with PyYAML).
# NECESSARY, NOT SUFFICIENT: it proves the immutable fields are unchanged between
# two renders, not that the live objects equal either render.
#
# Exit: 0 ok or skipped (no baseline tag), 1 a flagged field, 2 cannot run.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
self="$ROOT/tools/check-immutable-fields.sh"
LAYERS_DEFAULT=""
PERTURB=0; BASE=""; HEADREF="worktree"; REPO="$ROOT"; BASEDIR=""; HEADDIR=""; LAYERS=""; VALUES=(); ALLOW="$ROOT/tools/immutable-fields-allow.txt"; SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE=${2:?}; shift 2 ;;
    --head) HEADREF=${2:?}; shift 2 ;;
    --repo) REPO=${2:?}; shift 2 ;;
    --base-dir) BASEDIR=${2:?}; shift 2 ;;
    --head-dir) HEADDIR=${2:?}; shift 2 ;;
    --layers) LAYERS=${2:?}; shift 2 ;;
    --values) VALUES+=("${2:?}"); shift 2 ;;
    --allow) ALLOW=${2:?}; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    --perturb-images) PERTURB=1; shift ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "check-immutable-fields: unknown argument $1" >&2; exit 2 ;;
  esac
done
export PATH="$HOME/bin:$PATH"
command -v helm >/dev/null 2>&1 || { echo "check-immutable-fields: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-immutable-fields: python3 PyYAML missing" >&2; exit 2; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# ------------------------------------------------------------------ comparison
cat > "$work/cmp.py" <<'PY'
import sys, re, yaml, json
try: Loader = yaml.CSafeLoader
except AttributeError: Loader = yaml.SafeLoader
KINDS = ("Job", "Deployment", "DaemonSet", "StatefulSet", "Service", "PersistentVolumeClaim")
KRE = re.compile(r"^kind:\s*(%s)\s*$" % "|".join(KINDS), re.M)
def load(path):
    out = {}
    for chunk in re.split(r"^---\s*$", open(path).read(), flags=re.M):
        if not KRE.search(chunk): continue
        try: d = yaml.load(chunk, Loader=Loader)
        except yaml.YAMLError: continue
        if not isinstance(d, dict) or d.get("kind") not in KINDS: continue
        md = d.get("metadata") or {}
        out[(d["kind"], md.get("namespace") or "", md.get("name"))] = d
    return out
def get(d, path):
    for p in path.split("."):
        if not isinstance(d, dict): return None
        d = d.get(p)
    return d
def leaves(a, b, p=""):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            yield from leaves(a.get(k), b.get(k), p + ("." if p else "") + str(k))
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)): yield from leaves(x, y, "%s[%d]" % (p, i))
    elif a != b:
        yield "%s: %s -> %s" % (p, json.dumps(a)[:60], json.dumps(b)[:60])
def delete_before_create(d):
    ann = (d.get("metadata") or {}).get("annotations") or {}
    if "argocd.argoproj.io/hook" in ann:
        # No delete policy at all is Argo CD's documented default, BeforeHookCreation
        # ("if no deletion policy is specified, Argo CD will automatically assume
        # BeforeHookCreation", Sync Phases and Waves): the Job is replaced, never
        # patched (TM-1031, kube-prometheus-stack's admission-patch Job). An explicit
        # policy is read as written, so HookSucceeded alone stays flagged.
        if "argocd.argoproj.io/hook-delete-policy" not in ann:
            return True
        return "BeforeHookCreation" in str(ann.get("argocd.argoproj.io/hook-delete-policy", ""))
    if "helm.sh/hook" in ann:
        return "before-hook-creation" in str(ann.get("helm.sh/hook-delete-policy", ""))
    return False
RULES = {
 "Job": ["spec.template", "spec.selector"],
 "Deployment": ["spec.selector"], "DaemonSet": ["spec.selector"],
 "StatefulSet": ["spec.selector", "spec.serviceName", "spec.volumeClaimTemplates", "spec.podManagementPolicy"],
 "Service": ["spec.clusterIP"],
 "PersistentVolumeClaim": ["spec.storageClassName", "spec.accessModes", "spec.volumeName"],
}
allow = []
if sys.argv[1] != "-":
    for l in open(sys.argv[1]):
        l = l.split("#")[0].split()
        if len(l) == 4: allow.append(tuple(l))
used = set(); found = set(); allowed = set(); compared = 0; changed = 0
for spec in sys.argv[2:]:
    layer, vs, oldp, newp = spec.split("|")
    old, new = load(oldp), load(newp)
    for key, n in sorted(new.items()):
        o = old.get(key)
        if o is None: continue
        compared += 1
        if o != n: changed += 1
        kind, ns, name = key
        for field in RULES[kind]:
            a, b = get(o, field), get(n, field)
            if kind == "Service" and not (a and b): continue
            if kind == "PersistentVolumeClaim" and not (a and b): continue
            if a == b: continue
            if kind == "Job" and field == "spec.template" and delete_before_create(n): continue
            detail = "; ".join(list(leaves(a, b))[:3]) or "differs"
            msg = "%s %s %s/%s: %s changes (%s)" % (layer, kind, ns or "-", name, field, detail)
            hit = [e for e in allow if e[0] == layer and e[1] == kind and e[2] == name and e[3] in (field, "*")]
            if hit: used.add(hit[0]); allowed.add(msg)
            else: found.add(msg)
for m in sorted(found): print("FAIL " + m)
for m in sorted(allowed): print("  allowed " + m)
for e in allow:
    if e not in used: print("  note: allow entry matched nothing, remove it: " + " ".join(e))
print("STATS %d %d %d" % (compared, changed, len(found)))
sys.exit(1 if found else 0)
PY

# ------------------------------------------------------------------ one pair of trees
stage_ref() { # name ref -> $work/name holding charts/ and ci/
  local d="$work/$1"; mkdir -p "$d"
  if [ "$2" = worktree ]; then
    (cd "$ROOT" && tar -c --exclude='charts/*/charts' --exclude='charts/*/tmpcharts-*' charts ci) | tar -x -C "$d"
  else
    git --no-optional-locks -C "$REPO" archive "$2" charts ci | tar -x -C "$d" || return 1
  fi
}
stage_dir() { mkdir -p "$work/$1"; (cd "$2" && tar -c --exclude='charts/*/charts' --exclude='charts/*/tmpcharts-*' charts ci) | tar -x -C "$work/$1"; }
warns=0
fill_deps() { # name: package tockmox-common from this side and vendor every dependency
  local d="$work/$1"
  mkdir -p "$work/pkg-$1"
  helm package "$d/charts/tockmox-common" -d "$work/pkg-$1" >/dev/null 2>&1 || { echo "check-immutable-fields: cannot package tockmox-common for $1" >&2; return 2; }
  python3 - "$d" "$work/pkg-$1" "$ROOT" "${IMMUTABLE_DEPS_DIR:-}" <<'PY' || return 2
import sys, os, glob, shutil, yaml
d, pkg, root, extra = sys.argv[1:5]
pool = glob.glob(root + "/charts/*/charts/*.tgz") + (glob.glob(extra + "/*.tgz") if extra else [])
bad = 0
for ch in sorted(glob.glob(d + "/charts/tockmox-*")):
    if os.path.basename(ch) == "tockmox-common": continue
    src = ch + "/Chart.lock" if os.path.exists(ch + "/Chart.lock") else ch + "/Chart.yaml"
    deps = (yaml.safe_load(open(src)) or {}).get("dependencies") or []
    os.makedirs(ch + "/charts", exist_ok=True)
    for dep in deps:
        n, v, repo = dep["name"], str(dep["version"]), dep.get("repository", "")
        if repo.startswith("file://"):
            shutil.copy(glob.glob(pkg + "/tockmox-common-*.tgz")[0], ch + "/charts/"); continue
        exact = [p for p in pool if os.path.basename(p) == "%s-%s.tgz" % (n, v)]
        near = [p for p in pool if os.path.basename(p).rsplit("-", 1)[0] == n]
        pick = (exact or near or [None])[0]
        if not pick:
            print("check-immutable-fields: no vendored subchart %s %s for %s; run tools/helm-deps.sh or set IMMUTABLE_DEPS_DIR" % (n, v, os.path.basename(ch)), file=sys.stderr); bad = 1; continue
        if not exact:
            print("  warn: %s wants %s %s, using vendored %s" % (os.path.basename(ch), n, v, os.path.basename(pick)), file=sys.stderr)
        shutil.copy(pick, ch + "/charts/")
sys.exit(2 if bad else 0)
PY
}
render_one() { # side layer vs
  local d="$work/$1" out="$work/out/$1"; mkdir -p "$out"
  local vf=()
  if [ ${#VALUES[@]} -gt 0 ]; then [ "$3" = defaults ] && vf=($(printf -- '-f %s ' "${VALUES[@]}")) || return 0
  else vf=(-f "$d/ci/values.yaml"); if [ "$3" = all-on ]; then [ -f "$d/ci/values-all-on.yaml" ] || return 0; vf+=(-f "$d/ci/values-all-on.yaml"); fi; fi
  helm template t "$d/charts/$2" "${vf[@]}" > "$out/$2.$3.yaml" 2> "$out/$2.$3.err" || echo "ERR $1 $2 $3" >> "$work/render-errors"
}
export -f render_one; export work; export -f fill_deps 2>/dev/null || true

run_pair() { # base-name head-name
  local layers=""
  for c in "$work/$2"/charts/tockmox-*; do
    n=$(basename "$c"); case "$n" in tockmox-common|tockmox-crds) continue ;; esac
    [ -n "$LAYERS" ] && ! printf ' %s ' $LAYERS | grep -q " $n " && continue
    if [ -d "$work/$1/charts/$n" ]; then layers="$layers $n"; else echo "  note: $n is new in the head tree; nothing live to conflict with"; fi
  done
  [ -n "$layers" ] || { echo "check-immutable-fields: no layer chart to compare" >&2; return 2; }
  : > "$work/render-errors"
  local jobs=""
  for n in $layers; do for vs in defaults all-on; do for s in $1 $2; do jobs="$jobs $s,$n,$vs"; done; done; done
  printf '%s\n' $jobs | tr ',' ' ' | xargs -P "${JOBS:-4}" -L1 bash -c 'render_one "$0" "$1" "$2"'
  if [ -s "$work/render-errors" ]; then
    while read -r _ s n vs; do echo "check-immutable-fields: helm template failed: side=$s layer=$n values=$vs: $(head -c 300 "$work/out/$s/$n.$vs.err")" >&2; done < "$work/render-errors"
    return 2
  fi
  local specs=() dl=0
  for n in $layers; do for vs in defaults all-on; do
    [ -f "$work/out/$1/$n.$vs.yaml" ] && [ -f "$work/out/$2/$n.$vs.yaml" ] || continue
    specs+=("$n|$vs|$work/out/$1/$n.$vs.yaml|$work/out/$2/$n.$vs.yaml")
    dl=$((dl + $(diff "$work/out/$1/$n.$vs.yaml" "$work/out/$2/$n.$vs.yaml" | grep -c '^[<>]')))
  done; done
  local allowarg="-"; [ -f "$ALLOW" ] && allowarg="$ALLOW"
  local out; out=$(python3 "$work/cmp.py" "$allowarg" "${specs[@]}"); local rc=$?
  printf '%s\n' "$out" | grep -v '^STATS '
  read -r _ compared changed nfound <<< "$(printf '%s\n' "$out" | grep '^STATS ')"
  echo "  compared $compared Jobs, workloads, Services and PVCs present at both points across $(echo $layers | wc -w | tr -d ' ') layers x ${#specs[@]} renders; $changed differ in some field; the rendered diff is $dl changed lines; $nfound immutable field change(s) flagged"
  return $rc
}

prepare() { # name source(ref|dir:PATH)
  case "$2" in dir:*) stage_dir "$1" "${2#dir:}" ;; *) stage_ref "$1" "$2" ;; esac || { echo "check-immutable-fields: cannot read $2" >&2; return 2; }
  fill_deps "$1"
}

perturb_images() { # name: rewrite every image tag in the staged side's values (TM-1022)
  python3 - "$work/$1" <<'PY2'
import sys, re, glob
d = sys.argv[1]
rx = re.compile(r'^(\s*-?\s*[A-Za-z]*[Ii]mage:\s*["\']?)([^\s"\'#{}]+/[^\s"\'#{}]*:[^\s"\'#{}]+|[^\s"\'#{}/]+:[^\s"\'#{}]+)(["\']?)', re.M)
# Trust-bundle initContainers must run the SAME image as the subchart container
# they serve (tockmox.trustBundleImageCheck refuses a mismatch), and that image
# comes from the subchart, so these move only with a subchart (and the chart's
# Chart.lock) and are left alone here.
SKIP = {"ghcr.io/open-webui/open-webui", "ghcr.io/berriai/litellm-database", "ghcr.io/berriai/litellm"}
n = 0
for f in sorted(glob.glob(d + "/charts/tockmox-*/values.yaml") + glob.glob(d + "/ci/*.yaml")):
    s = open(f).read()
    s2, k = rx.subn(lambda m: m.group(0) if m.group(2).rsplit(":", 1)[0] in SKIP else m.group(1) + m.group(2) + "-perturbed" + m.group(3), s)
    k = s2.count("-perturbed") - s.count("-perturbed")
    if k: open(f, "w").write(s2); n += k
print("  perturbed %d image references" % n)
sys.exit(0 if n else 2)
PY2
}

# ------------------------------------------------------------------ selftest
if [ "$SELFTEST" = 1 ]; then
  fx="$work/fx"; mkdir -p "$fx"
  ok() { echo "selftest ok: $1"; }
  die() { echo "selftest FAIL: $1"; exit 1; }
  job() { # name label hookpolicy -> a rendered Job
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: %s\n  namespace: ns\n  labels: {helm.sh/chart: other}\n%s\nspec:\n  template:\n    metadata:\n      labels: {helm.sh/chart: %s}\n    spec: {restartPolicy: Never}\n' "$1" "$3" "$2"; }
  pair() { printf '%s\n' "$2" > "$fx/$1.old.yaml"; printf '%s\n' "$3" > "$fx/$1.new.yaml"; }
  run() { python3 "$work/cmp.py" "${3:--}" "L|defaults|$fx/$1.old.yaml|$fx/$1.new.yaml" 2>&1; }
  expect_red()   { local out; out=$(run "$1" "" "${3:-}") && die "$2 passed"; printf '%s' "$out" | grep -q "$4" || die "$2: wrong output: $out"; ok "$2"; }
  expect_green() { local out; out=$(run "$1" "" "${3:-}") || die "$2 failed: $out"; ok "$2"; }
  ANN='  annotations: {argocd.argoproj.io/hook: PostSync, argocd.argoproj.io/hook-delete-policy: BeforeHookCreation}'
  pair j1 "$(job creds tockmox-platform-0.6.0 '')" "$(job creds tockmox-platform-0.6.1 '')"
  expect_red j1 "a Job whose pod-template helm.sh/chart label moves is flagged, by name" "" 'FAIL L Job ns/creds: spec.template changes (.*helm.sh/chart.*0.6.0.*0.6.1'
  pair j2 "$(job creds-0-6-0 tockmox-platform-0.6.0 '')" "$(job creds-0-6-1 tockmox-platform-0.6.1 '')"
  expect_green j2 "a Job renamed with the version is a different object and passes"
  pair j3 "$(job boot tockmox-platform-0.6.0 "$ANN")" "$(job boot tockmox-platform-0.6.1 "$ANN")"
  expect_green j3 "an Argo hook with hook-delete-policy BeforeHookCreation passes"
  BAD='  annotations: {argocd.argoproj.io/hook: PostSync, argocd.argoproj.io/hook-delete-policy: HookSucceeded}'
  pair j4 "$(job boot tockmox-platform-0.6.0 "$BAD")" "$(job boot tockmox-platform-0.6.1 "$BAD")"
  expect_red j4 "an Argo hook with only HookSucceeded is flagged (it stays after a failure)" "" 'FAIL L Job ns/boot'
  NOPOL='  annotations: {argocd.argoproj.io/hook: PreSync}'
  pair j4b "$(job patch tockmox-platform-0.6.0 "$NOPOL")" "$(job patch tockmox-platform-0.6.1 "$NOPOL")"
  expect_green j4b "an Argo hook with no delete policy passes (Argo's default is BeforeHookCreation, TM-1031)"
  pair j5 "$(job creds tockmox-platform-0.6.0 '')" "$(job creds tockmox-platform-0.6.0 '' | sed 's/helm.sh\/chart: other/helm.sh\/chart: moved/')"
  expect_green j5 "a Job whose metadata label moves but whose pod template does not passes"
  dep() { printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: web, namespace: ns}\nspec:\n  selector: {matchLabels: {app: %s}}\n  template:\n    metadata: {labels: {app: %s, helm.sh/chart: %s}}\n' "$1" "$1" "$2"; }
  pair d1 "$(dep web c-1)" "$(dep web c-2)"
  expect_green d1 "a Deployment whose pod-template label moves, selector unchanged, passes"
  pair d2 "$(dep web c-1)" "$(dep web2 c-1)"
  expect_red d2 "a Deployment whose spec.selector changes is flagged" "" 'FAIL L Deployment ns/web: spec.selector changes'
  sts() { printf 'apiVersion: apps/v1\nkind: StatefulSet\nmetadata: {name: db, namespace: ns}\nspec:\n  replicas: %s\n  serviceName: %s\n  selector: {matchLabels: {a: b}}\n  volumeClaimTemplates:\n    - metadata: {name: data, labels: {helm.sh/chart: %s}}\n' "$1" "$2" "$3"; }
  pair s1 "$(sts 1 db c-1)" "$(sts 3 db c-1)"
  expect_green s1 "a StatefulSet replica change passes"
  pair s2 "$(sts 1 db c-1)" "$(sts 1 db-headless c-1)"
  expect_red s2 "a StatefulSet serviceName change is flagged" "" 'spec.serviceName changes'
  pair s3 "$(sts 1 db c-1)" "$(sts 1 db c-2)"
  expect_red s3 "a StatefulSet volumeClaimTemplates change (even a label) is flagged" "" 'spec.volumeClaimTemplates changes'
  pair a1 "$(job creds tockmox-platform-0.6.0 '')" "$(job creds tockmox-platform-0.6.1 '')"
  printf 'L Job creds spec.template # selftest\n' > "$fx/allow.txt"
  out=$(run a1 "" "$fx/allow.txt") || die "an allow-listed hit failed"; printf '%s' "$out" | grep -q 'allowed L Job ns/creds' || die "allowed hit not printed"; ok "an allow-listed hit passes and is still printed"
  printf 'L Job other spec.template\n' > "$fx/allow2.txt"
  out=$(run j2 "" "$fx/allow2.txt"); printf '%s' "$out" | grep -q 'matched nothing' || die "stale allow entry not reported"; ok "an allow entry that matches nothing is reported"
  # Real renders: a version bump of the real platform chart, with and without the TM-0753 fix.
  command -v helm >/dev/null || die "helm"
  ver=$(awk '$1=="version:"{print $2; exit}' charts/tockmox-platform/Chart.yaml)
  mk() { stage_dir "$1" "$ROOT"; }
  bump() { for f in "$work/$1"/charts/tockmox-platform/Chart.yaml "$work/$1"/charts/tockmox-common/Chart.yaml; do sed "s/^version: $ver\$/version: 9.9.9/; s/^\(  *version: \)$ver\$/\19.9.9/; s/^\(  *version: \)\"$ver\"\$/\1\"9.9.9\"/" "$f" > "$f.n" && mv "$f.n" "$f"; done; }
  stage_dir sa "$ROOT"; stage_dir sb "$ROOT"; bump sb
  fill_deps sa 2>/dev/null; fill_deps sb 2>/dev/null
  out=$(bash "$self" --base-dir "$work/sa" --head-dir "$work/sb" --layers tockmox-platform 2>&1) || die "the real platform chart, version-bumped, was flagged: $out"
  printf '%s' "$out" | grep -Eq 'the rendered diff is [1-9][0-9]* changed lines; 0 immutable' || die "green bump did not show a non-empty rendered diff: $out"
  ok "the real platform chart bumped $ver -> 9.9.9 has a non-empty rendered diff and no immutable-field change (TM-0753 fix in place)"
  for s in sa sb; do f="$work/$s/charts/tockmox-platform/templates/garage-bootstrap.yaml"; sed 's/^  name: {{ \$credName }}$/  name: {{ $name }}-credentials/' "$f" > "$f.n" && mv "$f.n" "$f"; done
  out=$(bash "$self" --base-dir "$work/sa" --head-dir "$work/sb" --layers tockmox-platform 2>&1) && die "the pre-TM-0753 Job name passed: $out"
  printf '%s' "$out" | grep -Eq 'FAIL tockmox-platform Job .*-credentials: spec.template changes .*helm.sh/chart' || die "wrong output: $out"
  ok "the same bump with the version taken out of the credentials Job's name is flagged, naming that Job"
  # --perturb-images (TM-1022): the fixed tree passes; the credentials Job named for the version again fails, naming it.
  pt="$work/pt"; mkdir -p "$pt"; (cd "$ROOT" && tar -c charts ci tools) | tar -x -C "$pt"
  out=$(bash "$pt/tools/check-immutable-fields.sh" --perturb-images 2>&1) || die "--perturb-images failed on this tree: $out"
  printf '%s' "$out" | grep -Eq 'perturbed [1-9][0-9]* image references' || die "--perturb-images changed nothing: $out"
  ok "--perturb-images: every image tag changed, no surviving Job keeps its name with a changed template"
  f="$pt/charts/tockmox-platform/templates/garage-bootstrap.yaml"
  sed 's/^{{- \$credName := printf "%s-credentials-%s" \$name (\$credPod | sha256sum | trunc 10) -}}$/{{- $credName := printf "%s-credentials-%s" $name (.Chart.Version | replace "." "-") -}}/' "$f" > "$f.n" && mv "$f.n" "$f"
  grep -q 'Chart.Version | replace' "$f" || die "selftest could not put the version-only name back"
  out=$(bash "$pt/tools/check-immutable-fields.sh" --perturb-images 2>&1) && die "--perturb-images passed a version-named Job: $out"
  printf '%s' "$out" | grep -Eq 'FAIL tockmox-platform Job .*/tockmox-garage-credentials-[0-9-]*: spec.template changes .*image' || die "wrong output: $out"
  ok "--perturb-images flags the credentials Job named for the version only, as on the homelab 2026-10-11"
  echo "check-immutable-fields selftest: ok"
  exit 0
fi

# ------------------------------------------------------------------ run
t0=$(date +%s)
if [ "$PERTURB" = 1 ]; then
  echo "check-immutable-fields: the tree vs itself with every image tag changed (TM-1022)"
  prepare base "dir:$ROOT" 2> "$work/dep-warn.txt" || { cat "$work/dep-warn.txt" >&2; exit 2; }
  prepare head "dir:$ROOT" 2>> "$work/dep-warn.txt" || { cat "$work/dep-warn.txt" >&2; exit 2; }
  perturb_images head || { echo "check-immutable-fields: found no image reference to perturb" >&2; exit 2; }
  sort -u "$work/dep-warn.txt"
  run_pair base head; rc=$?
  echo "check-immutable-fields: $([ $rc = 0 ] && echo ok || echo FAILED) ($(( $(date +%s) - t0 ))s)"
  exit $rc
fi
if [ -n "$BASEDIR" ] || [ -n "$HEADDIR" ]; then
  [ -n "$BASEDIR" ] && [ -n "$HEADDIR" ] || { echo "check-immutable-fields: --base-dir and --head-dir go together" >&2; exit 2; }
  bsrc="dir:$BASEDIR"; hsrc="dir:$HEADDIR"; label="$BASEDIR vs $HEADDIR"
else
  if [ -z "$BASE" ]; then BASE=${BASELINE_REF:-$(git --no-optional-locks -C "$REPO" describe --tags --abbrev=0 2>/dev/null || true)}; fi
  if [ -z "$BASE" ] || ! git --no-optional-locks -C "$REPO" rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1; then
    echo "check-immutable-fields: SKIPPED, no baseline ref (${BASE:-none}); fetch tags or set BASELINE_REF. Not a pass: nothing was compared."
    exit 0
  fi
  bsrc="$BASE"; hsrc="$HEADREF"; label="$BASE vs $HEADREF"
fi
echo "check-immutable-fields: $label"
prepare base "$bsrc" 2> "$work/dep-warn.txt" || { cat "$work/dep-warn.txt" >&2; exit 2; }
prepare head "$hsrc" 2>> "$work/dep-warn.txt" || { cat "$work/dep-warn.txt" >&2; exit 2; }
sort -u "$work/dep-warn.txt"
run_pair base head; rc=$?
echo "check-immutable-fields: $([ $rc = 0 ] && echo ok || echo FAILED) ($(( $(date +%s) - t0 ))s)"
exit $rc

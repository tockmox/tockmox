#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, three properties that stop an upgrade from
# 0.6.x wedging a layer. Each was found by the 0.7.0 lab pass on a real
# upgrade, and each renders cleanly when it is wrong.
#
#   ./tools/check-upgrade-safety.sh            run the assertions
#   ./tools/check-upgrade-safety.sh --selftest prove they can go red
#
# F1  The LiteLLM migrations Job cannot wedge an upgrade. A Job's pod template
#     is immutable once the Job exists, so a Job that keeps its name across a
#     template change fails with 'field is immutable' and Argo stops retrying
#     (0.7.0 lab pass). Since TM-0596 (2026-10-06) tockmox-ai owns the Job and
#     names it after a hash of its pod template. Asserted on the render:
#     exactly one migrations Job, named <release>-litellm-migrations-<10 hex>;
#     its name MOVES when the pod template moves (a pod label, a LiteLLM image
#     tag) and does NOT move on a value that does not reach the Job (the proxy's
#     replica count), so it neither wedges nor reruns the migration needlessly;
#     and turning the subchart's own Job back on refuses to render.
#     `--selftest` proves it goes red on a static name.
# F1b The owned Job's pod spec is the vendored subchart's, value for value. The
#     vendored litellm-helm chart is rendered on its own with the same values
#     and its own Job switched on, and the two pod specs are compared. An
#     upstream change to its Job on a LiteLLM bump goes red here and is ported
#     into charts/tockmox-ai/templates/_litellm-migrations.tpl.
#     `--selftest` proves it goes red on a drifted template.
# F2  The Loki gateway must be able to roll on ONE node AND apply over a live
#     0.6.2 Deployment: it must not surge (maxSurge 0, or strategy Recreate),
#     must carry no REQUIRED podAntiAffinity, and must not be a strategy TYPE
#     change to Recreate (that is rejected by the API server under ServerSideApply
#     when the live object has a rollingUpdate block: measured 2026-09-30).
# F3  The site sync must not be able to fail the platform sync operation: it is
#     a CronJob with no ArgoCD hook annotation (a failed PostSync hook fails
#     the operation, and ArgoCD then retries a full re-sync five times), and
#     each run must be able to FAIL: activeDeadlineSeconds and backoffLimit both
#     set and bounded. Rendered on an OPERATOR FIXTURE (the shipped `docs`
#     entry plus a site of the operator's own with a `content.image`), because
#     the product docs have no sync Job since TM-0808 (no published image,
#     ADR-0036) and a default render holds no sync CronJob at all: without the
#     fixture this check would find nothing and go red on "no CronJob", or
#     worse, be edited to accept nothing. `--selftest` proves it goes red on a
#     changed policy.
# F3b The docs site is also published ONCE at install, without a hook and
#     without a bare Job in the sync: the bootstrap PostSync Job (best effort,
#     never fatal) starts a Job from each sync CronJob, named with the chart
#     version. Asserted on the render: SYNC_JOBS names a rendered CronJob, the
#     Job name carries the chart version and fits 63 characters, the script
#     creates it inside a non-fatal `if`, and the Role can get exactly those
#     CronJobs and create Jobs. Also rendered on the operator fixture (see F3).
#     `--selftest` proves it goes red with the toggle off.
# F3d A default install serves the docs with no image: the docs Ingress, the
#     docs bucket (a bootstrap SITES line with a writer key and the placeholder
#     flag) and the placeholder ConfigMap, mounted into the bootstrap Job, are
#     rendered; no docs sync CronJob, no bootstrap SYNC_JOBS entry and no
#     `tockmox-docs` anywhere in the platform render. An operator-supplied site
#     (its own `content.image`) still gets its own sync CronJob and none for the
#     docs. With `apps.docs.enabled=false` none of the docs objects remain.
#     `--selftest` proves it goes red when the default render gains a sync
#     CronJob and when the placeholder is missing.
# F4  Every PrometheusRule the observability layer renders is applied only after
#     the prometheus-operator admission webhook can answer (fail-open fix,
#     v0.7.0-rc1 greenfield 2026-09-30: fail_open_count 66 on a healthy install).
#     Asserted on the render: the two webhook configurations and the caBundle
#     patch Job are ArgoCD PreSync hooks in the order configurations then Job,
#     and the Job is not left a Helm post-install hook (which ArgoCD runs as
#     PostSync, after the rules); every PrometheusRule is sync wave 1 or later
#     and none is a hook; the operator Deployment is wave 0; and every
#     failurePolicy is still the upstream Ignore (ordering only, ruled
#     2026-09-30: a change to Fail is a decision, not drift). Rules shipped by
#     OTHER layers are not covered and this does not claim them. NECESSARY, NOT SUFFICIENT: it proves the annotations are rendered,
#     not that ArgoCD orders the phases as documented; the greenfield fail_open
#     counters are the proof. `--selftest` proves it goes red with the rule
#     waves removed, with the webhook configurations not hooks, with the patch
#     Job back in PostSync, and with failurePolicy Fail.
# F5  No Ingress waits for an address that a later wave of the SAME ArgoCD
#     Application would grant (v0.7.0-rc2 greenfield, 2026-10-01: the platform
#     sync hung for good on the docs Ingress in wave 0, because ArgoCD calls an
#     Ingress Healthy only once it has a load-balancer address, and the Traefik
#     LoadBalancer Service that gives it one is wave 7). Asserted on every
#     layer's render (shipped defaults, then every application enabled): within
#     a layer, each Ingress has a sync-wave greater than the highest wave of any
#     LoadBalancer Service the layer renders; and a layer with an Ingress and no
#     LoadBalancer Service has an EARLIER layer (Chart.yaml tockmox.com/sync-wave)
#     that renders one. LIMIT: this does not model whatever else ArgoCD waits
#     on, and it trusts that a LoadBalancer Service gets an address; it only
#     proves the ordering is not circular. `--selftest` proves it goes red with
#     the Ingress waves removed.
# F6  No layer applies an object into a namespace that does not exist yet
#     (the same greenfield: Role and RoleBinding `tockmox-garage-bootstrap` in
#     `news` failed with `namespaces "news" not found`; the namespace was
#     created only by the site's app manifests, a later layer). An existing
#     cluster hides this class of bug. Asserted on every layer's render: each
#     object with an explicit metadata.namespace targets a namespace that is the
#     layer's own destination (the installer's CreateNamespace), a Namespace the
#     layer itself renders, a Namespace rendered by a layer with a LOWER
#     Chart.yaml sync-wave, or a built-in (argocd, kube-system, kube-public,
#     kube-node-lease, default). Also: no Namespace is rendered by two layers
#     (two Applications owning one Namespace fight over its tracking label).
#     LIMIT: renders use the shipped test values, not a site's; a site that adds
#     a namespace must also pass this check against its own values, which is the
#     operator's to run. `--selftest` proves both legs go red.
# F3c A site name is at most 32 characters: the sync CronJob is
#     `tockmox-garage-sync-<name>` and a CronJob name may have 52. Asserted on
#     the render: a 32 character name gives a 52 character CronJob and a one-shot
#     Job within 63; a 33 character name is refused.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-upgrade-safety: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-upgrade-safety: python3 PyYAML missing" >&2; exit 2; }

UPGRADE=docs/deployment/upgrade.md
AI_CHART=charts/tockmox-ai
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# F1/F1b mutations run against a mutated COPY of the ai chart.
case "${1:-}" in
  --mutate-static-name|--mutate-drift)
    cp -R "$AI_CHART" "$tmp/ai-chart"; AI_CHART="$tmp/ai-chart"
    if [ "$1" = "--mutate-static-name" ]; then
      sed -i.bak 's/-migrations-{{ $pod | sha256sum | trunc 10 }}/-migrations/' "$AI_CHART/templates/litellm-migrations-job.yaml"
    else
      sed -i.bak 's/^        - name: DISABLE_SCHEMA_UPDATE$/        - name: SELFTEST_DRIFT\n          value: "x"\n        - name: DISABLE_SCHEMA_UPDATE/' "$AI_CHART/templates/_litellm-migrations.tpl"
    fi
    rm -f "$AI_CHART"/templates/*.bak ;;
esac

# Print the migrations Job names in the ai render (one per line), or NOJOB.
job_names() {
  helm template t "$AI_CHART" -f ci/values.yaml "$@" > "$tmp/ai.yaml"
  python3 - "$tmp/ai.yaml" <<'PY'
import sys, yaml
n = [d["metadata"]["name"] for d in yaml.safe_load_all(open(sys.argv[1]))
     if d and d.get("kind") == "Job" and "-litellm-migrations" in d["metadata"]["name"]]
print("\n".join(n) if n else "NOJOB")
PY
}

if [ "${1:-}" = "--selftest" ]; then
  out=$(bash tools/check-upgrade-safety.sh --mutate-static-name 2>&1) && { echo "selftest FAIL: F1 passed with a migrations Job name that ignores its pod template"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1: ' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1 assertion goes red when the migrations Job keeps one name across template changes"
  out=$(bash tools/check-upgrade-safety.sh --mutate-drift 2>&1) && { echo "selftest FAIL: F1b passed with a pod spec that differs from the subchart's"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1b: ' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1b assertion goes red when the owned Job drifts from the subchart's"
  out=$(bash tools/check-upgrade-safety.sh --mutate-sync 2>&1) && { echo "selftest FAIL: F3b passed with garage.web.syncAtInstall off"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F3b' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F3b assertion goes red when the install-time sync is off"
  out=$(bash tools/check-upgrade-safety.sh --mutate-cron 2>&1) && { echo "selftest FAIL: F3 passed with concurrencyPolicy Allow"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F3: .*concurrencyPolicy' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F3 assertion goes red when a sync CronJob allows concurrent runs"
  out=$(bash tools/check-upgrade-safety.sh --mutate-default 2>&1) && { echo "selftest FAIL: F3d passed with a sync CronJob in the default render"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F3d: a default render has sync CronJob' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F3d assertion goes red when the default render has a docs-side sync CronJob"
  out=$(bash tools/check-upgrade-safety.sh --mutate-placeholder 2>&1) && { echo "selftest FAIL: F3d passed with the docs site off (no placeholder)"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F3d: .*placeholder' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F3d assertion goes red when the placeholder page is not rendered"
  out=$(bash tools/check-upgrade-safety.sh --mutate-rulewave 2>&1) && { echo "selftest FAIL: F4 passed with the PrometheusRule waves removed"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F4: .*sync-wave' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F4 assertion goes red when a PrometheusRule has no sync wave"
  out=$(bash tools/check-upgrade-safety.sh --mutate-webhookphase 2>&1) && { echo "selftest FAIL: F4 passed with the webhook configurations not hooks"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F4: .*is not an ArgoCD PreSync hook' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F4 assertion goes red when a webhook configuration is not a PreSync hook"
  out=$(bash tools/check-upgrade-safety.sh --mutate-failpolicy 2>&1) && { echo "selftest FAIL: F4 passed with failurePolicy Fail"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F4: .*failurePolicy' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F4 assertion goes red when failurePolicy is changed from the upstream Ignore"
  out=$(bash tools/check-upgrade-safety.sh --mutate-patchphase 2>&1) && { echo "selftest FAIL: F4 passed with the patch Job in PostSync"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F4: .*patch Job' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F4 assertion goes red when the caBundle patch Job is left in PostSync"
  out=$(bash tools/check-upgrade-safety.sh --mutate-ingresswave 2>&1) && { echo "selftest FAIL: F5 passed with the Ingress waves removed"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F5: .*Ingress' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F5 assertion goes red when an Ingress shares a wave with, or precedes, the LoadBalancer Service"
  out=$(bash tools/check-upgrade-safety.sh --mutate-ns-missing 2>&1) && { echo "selftest FAIL: F6 passed with a copy target nobody creates"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F6: .*does not exist' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F6 assertion goes red when a namespaced object targets a namespace no earlier layer creates"
  out=$(bash tools/check-upgrade-safety.sh --mutate-ns-twice 2>&1) && { echo "selftest FAIL: F6 passed with a Namespace owned by two layers"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F6: .*two layers' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F6 assertion goes red when two layers both render one Namespace"
  exit 0
fi

rc=0
bad() { echo "FAIL $*"; rc=1; }
good() { echo "  ok $*"; }

# ---------------------------------------------------------------- F1
base=$(job_names)
if [ "$base" = "NOJOB" ]; then
  bad "F1: no litellm migrations Job in the render of $AI_CHART with ci/values.yaml"
elif [ "$(printf '%s\n' "$base" | wc -l | tr -d ' ')" != "1" ]; then
  bad "F1: more than one migrations Job renders ($(echo $base)); two Jobs would migrate one database"
elif ! printf '%s' "$base" | grep -Ex 't-litellm-migrations-[0-9a-f]{10}' >/dev/null; then
  bad "F1: the migrations Job is '$base', not named after its pod template (t-litellm-migrations-<10 hex>). A Job keeping one name across a template change fails with 'field is immutable' on every existing site"
else
  good "F1: one migrations Job, named after its pod template ($base)"
  for m in 'litellm.podLabels.selftest=x' 'litellm.image.tag=9.9.9'; do
    got=$(job_names --set "$m")
    if [ "$got" = "$base" ]; then bad "F1: --set $m changes the Job's pod template but not its name; that upgrade would wedge on 'field is immutable'"
    else good "F1: a pod-template change ($m) gives a new Job ($got)"; fi
  done
  got=$(job_names --set 'litellm.replicaCount=3')
  if [ "$got" != "$base" ]; then bad "F1: --set litellm.replicaCount=3 does not reach the Job, yet renamed it ($got); the migration would rerun on unrelated changes"
  else good "F1: a value that does not reach the Job leaves its name alone"; fi
fi
if helm template t "$AI_CHART" -f ci/values.yaml --set litellm.migrationJob.enabled=true >/dev/null 2>"$tmp/guard.err"; then
  bad "F1: litellm.migrationJob.enabled=true renders; it must refuse (the subchart's own Job would run beside the owned one)"
elif grep -q 'two Jobs would migrate one database' "$tmp/guard.err"; then
  good "F1: the subchart's own Job refuses to render beside the owned one"
else
  bad "F1: litellm.migrationJob.enabled=true failed, but not with the guard's message: $(head -3 "$tmp/guard.err")"
fi

# ---------------------------------------------------------------- F1b
sub_tgz=$(ls "$AI_CHART"/charts/litellm-helm-*.tgz 2>/dev/null | head -1)
if [ -z "$sub_tgz" ]; then
  bad "F1b: no vendored litellm-helm tarball under $AI_CHART/charts (run tools/helm-deps.sh)"
else
  python3 - "$AI_CHART/values.yaml" ci/values.yaml "$tmp/sub-values.yaml" <<'PY'
import sys, yaml
def merge(a, b):
    for k, v in (b or {}).items():
        a[k] = merge(a.get(k) or {}, v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return a
v = merge(yaml.safe_load(open(sys.argv[1])).get("litellm", {}) or {},
          (yaml.safe_load(open(sys.argv[2])) or {}).get("litellm", {}))
v.setdefault("migrationJob", {})["enabled"] = True
yaml.safe_dump(v, open(sys.argv[3], "w"))
PY
  helm template t "$sub_tgz" -f "$tmp/sub-values.yaml" > "$tmp/sub.yaml"
  helm template t "$AI_CHART" -f ci/values.yaml > "$tmp/ai.yaml"
  python3 - "$tmp/sub.yaml" "$tmp/ai.yaml" <<'PY' || rc=1
import sys, yaml, difflib, json
def job(f, owned):
    for d in yaml.safe_load_all(open(f)):
        if d and d.get("kind") == "Job":
            n = d["metadata"]["name"]
            if (owned and n.startswith("t-litellm-migrations-")) or (not owned and n == "t-litellm-migrations"):
                return d["spec"]["template"]
up, own = job(sys.argv[1], False), job(sys.argv[2], True)
if up is None or own is None:
    print("FAIL F1b: could not find both Jobs (upstream %s, owned %s)" % (up is not None, own is not None)); sys.exit(1)
for t in (up, own):
    t.get("metadata", {}).pop("annotations", None)   # upstream emits an empty map as null
    t.get("metadata", {}).get("labels", {}).pop("helm.sh/chart", None)   # the alias renames the chart: litellm vs litellm-helm
if up != own:
    a = json.dumps(up, indent=1, sort_keys=True).splitlines(); b = json.dumps(own, indent=1, sort_keys=True).splitlines()
    print("FAIL F1b: the owned migrations Job's pod template differs from the vendored subchart's; port the upstream change into charts/tockmox-ai/templates/_litellm-migrations.tpl")
    print("\n".join(list(difflib.unified_diff(a, b, "subchart", "owned", lineterm=""))[:40])); sys.exit(1)
print("  ok F1b: the owned migrations Job's pod template equals the vendored subchart's")
PY
fi

# ---------------------------------------------------------------- F2
helm template t charts/tockmox-observability -f ci/values.yaml > "$tmp/obs.yaml"
python3 - "$tmp/obs.yaml" <<'PY' || rc=1
import sys, yaml
found = False; bad = 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "Deployment" or not d["metadata"]["name"].endswith("-loki-gateway"):
        continue
    found = True
    strat = d["spec"].get("strategy") or {}
    st = strat.get("type")
    ru = strat.get("rollingUpdate") or {}
    surge = ru.get("maxSurge")
    no_surge = st == "Recreate" or (st == "RollingUpdate" and str(surge) == "0")
    aff = (d["spec"]["template"]["spec"].get("affinity") or {}).get("podAntiAffinity") or {}
    if st == "Recreate":
        print("FAIL F2: Loki gateway strategy type is Recreate. Switching a live Deployment to Recreate is rejected under ServerSideApply ('rollingUpdate: may not be specified when strategy type is Recreate'); keep RollingUpdate with maxSurge 0"); bad += 1
    elif not no_surge:
        print("FAIL F2: Loki gateway strategy is %r maxSurge=%r, want RollingUpdate with maxSurge 0 (a surge pod cannot schedule beside the old one on a single node)" % (st, surge)); bad += 1
    else:
        print("  ok F2: Loki gateway rolls without a surge pod (RollingUpdate, maxSurge %s, maxUnavailable %s)" % (surge, ru.get("maxUnavailable")))
    if aff.get("requiredDuringSchedulingIgnoredDuringExecution"):
        print("FAIL F2: Loki gateway carries a REQUIRED podAntiAffinity; on one node the old pod repels the new one"); bad += 1
    else:
        print("  ok F2: Loki gateway has no required podAntiAffinity")
    if not aff.get("preferredDuringSchedulingIgnoredDuringExecution"):
        print("FAIL F2: Loki gateway lost its preferred anti-affinity; replicas would stop spreading"); bad += 1
    else:
        print("  ok F2: Loki gateway keeps a preferred anti-affinity")
if not found:
    print("FAIL F2: no Loki gateway Deployment in the render"); bad += 1
sys.exit(1 if bad else 0)
PY

# ---------------------------------------------------------------- F3
# The operator fixture: the shipped docs entry (Helm replaces a list, so it is
# restated) and a site of the operator's own with a content.image. That second
# site is the only thing in the chart that still has a sync CronJob.
cat > "$tmp/site-fixture.yaml" <<YAML
garage:
  web:
    sites:
      - name: docs
        host: ""
        index: index.html
        errorDocument: 404.html
        ingress: true
        writerKey: true
        content: {}
      - name: handbook
        host: handbook.int.example.com
        ingress: true
        content: {image: registry.example.com/team/handbook:1.4.0, path: /site}
YAML
helm template t charts/tockmox-platform -f ci/values.yaml -f "$tmp/site-fixture.yaml" > "$tmp/plat.yaml"
# No `sed -i`: BSD sed on macOS reads the next word as a backup suffix (Jeff's Mac failed here).
if [ "${1:-}" = "--mutate-cron" ]; then
  sed 's/concurrencyPolicy: Forbid/concurrencyPolicy: Allow/' "$tmp/plat.yaml" > "$tmp/plat.mut" && mv "$tmp/plat.mut" "$tmp/plat.yaml"
fi
python3 - "$tmp/plat.yaml" <<'PY' || rc=1
import sys, yaml
n = 0; bad = 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or "-sync-" not in (d.get("metadata") or {}).get("name", ""):
        continue
    if d.get("kind") == "Job":
        print("FAIL F3: %s is a bare Job. A site sync must be a CronJob: as an ArgoCD hook or a sync-time Job its failure fails the platform sync operation" % d["metadata"]["name"]); bad += 1; n += 1
        continue
    if d.get("kind") != "CronJob":
        continue
    n += 1
    name = d["metadata"]["name"]
    ann = list((d["metadata"].get("annotations") or {}).keys()) + list((d["spec"]["jobTemplate"]["metadata"].get("annotations") or {}).keys() if d["spec"]["jobTemplate"].get("metadata") else [])
    hook = [a for a in ann if a.startswith("argocd.argoproj.io/hook")]
    if hook:
        print("FAIL F3: %s carries %s; a hook that fails fails the platform sync operation" % (name, hook)); bad += 1; continue
    s = d["spec"]["jobTemplate"]["spec"]
    ads, bl = s.get("activeDeadlineSeconds"), s.get("backoffLimit")
    if not isinstance(ads, int) or not (0 < ads <= 3600):
        print("FAIL F3: %s activeDeadlineSeconds is %r, want 1..3600 (an unpullable image never fails a Pod, so only the deadline ends a run)" % (name, ads)); bad += 1
    elif not isinstance(bl, int) or bl > 6:
        print("FAIL F3: %s backoffLimit is %r, want an integer <= 6" % (name, bl)); bad += 1
    elif d["spec"].get("concurrencyPolicy") != "Forbid":
        print("FAIL F3: %s concurrencyPolicy is %r, want Forbid" % (name, d["spec"].get("concurrencyPolicy"))); bad += 1
    else:
        print("  ok F3: %s (CronJob, no ArgoCD hook) activeDeadlineSeconds=%d backoffLimit=%d" % (name, ads, bl))
if n == 0:
    print("FAIL F3: no site sync CronJob rendered from ci/values.yaml with the operator content.image fixture"); bad += 1
sys.exit(1 if bad else 0)
PY

# ---------------------------------------------------------------- F3b
extra=(-f "$tmp/site-fixture.yaml")
[ "${1:-}" = "--mutate-sync" ] && extra+=(--set garage.web.syncAtInstall=false)
helm template t charts/tockmox-platform -f ci/values.yaml ${extra[@]+"${extra[@]}"} > "$tmp/plat2.yaml"
CHARTVER=$(awk '$1=="version:"{print $2; exit}' charts/tockmox-platform/Chart.yaml)
python3 - "$tmp/plat2.yaml" "$CHARTVER" <<'PY' || rc=1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
ver = sys.argv[2].replace(".", "-").replace("+", "-")
bad = 0
def fail(m):
    global bad; print("FAIL F3b: " + m); bad += 1
cron = {d["metadata"]["name"] for d in docs if d.get("kind") == "CronJob" and "-sync-" in d["metadata"]["name"]}
boot = [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"] == "tockmox-garage-bootstrap"]
if not cron: fail("no site sync CronJob rendered")
if len(boot) != 1: fail("bootstrap Job not rendered"); sys.exit(1)
c = boot[0]["spec"]["template"]["spec"]["containers"][0]
env = {e["name"]: e.get("value", "") for e in c["env"]}
script = "\n".join(c["args"])
pairs = [l.split() for l in env.get("SYNC_JOBS", "").splitlines() if l.strip()]
if not pairs:
    fail("bootstrap Job has no SYNC_JOBS: the docs site is empty until the first CronJob tick")
for cj, job in pairs:
    if cj not in cron: fail("SYNC_JOBS names %s, which is not a rendered sync CronJob" % cj)
    if not job.endswith("-" + ver): fail("one-shot Job %s does not end in the chart version -%s: an upgrade would find the old name taken" % (job, ver))
    if len(job) > 63: fail("one-shot Job name %s is %d characters, over 63" % (job, len(job)))
if pairs:
    if 'create job "$jobname" --from="cronjob/$cj"' not in script: fail("bootstrap script does not create the Job from the CronJob")
    if "if out=$(kubectl" not in script or "WARN: could not start" not in script: fail("the create is not inside a non-fatal if: a failure here would fail the PostSync hook")
    role = [d for d in docs if d.get("kind") == "Role" and d["metadata"]["name"] == "tockmox-garage-bootstrap" and d["metadata"].get("namespace") == boot[0]["metadata"]["namespace"]]
    rules = role[0]["rules"] if role else []
    getcj = [r for r in rules if r.get("resources") == ["cronjobs"] and r.get("verbs") == ["get"]]
    mkjob = [r for r in rules if r.get("resources") == ["jobs"] and r.get("verbs") == ["create"]]
    if not getcj or set(getcj[0].get("resourceNames", [])) != {p[0] for p in pairs}: fail("Role cannot get exactly the sync CronJobs by name")
    if not mkjob: fail("Role cannot create Jobs")
for d in docs:
    if d.get("kind") == "Job" and "-sync-" in d["metadata"]["name"]:
        fail("%s is a rendered Job: the install-time run is created by the bootstrap Job, not shipped as a manifest" % d["metadata"]["name"])
if not bad:
    print("  ok F3b: bootstrap creates %s from %s (non-fatal, Role scoped)" % ([p[1] for p in pairs], [p[0] for p in pairs]))
sys.exit(1 if bad else 0)
PY

# ---------------------------------------------------------------- F3c
# A site name is capped at 32 characters because the sync CronJob is
# `tockmox-garage-sync-<name>` (20 + name) and a CronJob name may have 52. Assert
# on the artifact: a 32 character name renders, with a CronJob of exactly 52
# characters and a one-shot Job name within 63; a 33 character name is refused.
site32=$(printf 'a%.0s' $(seq 1 32)); site33="${site32}b"
sites_values() { cat <<YAML
garage:
  web:
    sites:
      - name: docs
        host: ""
        index: index.html
        errorDocument: 404.html
        ingress: true
        writerKey: true
        content: {}
      - name: $1
        ingress: false
        writerKey: true
        content: {image: registry.example.com/team/site:1.0.0, path: /site}
YAML
}
sites_values "$site32" > "$tmp/site32.yaml"; sites_values "$site33" > "$tmp/site33.yaml"
if ! helm template t charts/tockmox-platform -f ci/values.yaml -f "$tmp/site32.yaml" > "$tmp/plat32.yaml" 2> "$tmp/plat32.err"; then
  bad "F3c: a 32 character site name no longer renders: $(head -c 300 "$tmp/plat32.err")"
else
  python3 - "$tmp/plat32.yaml" "$site32" <<'PY' || rc=1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cj = [d["metadata"]["name"] for d in docs if d.get("kind") == "CronJob" and d["metadata"]["name"].endswith("-sync-" + sys.argv[2])]
boot = [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"] == "tockmox-garage-bootstrap"][0]
env = {e["name"]: e.get("value", "") for e in boot["spec"]["template"]["spec"]["containers"][0]["env"]}
jobs = [l.split()[1] for l in env.get("SYNC_JOBS", "").splitlines() if l.split() and l.split()[0] in cj]
bad = 0
if len(cj) != 1: print("FAIL F3c: expected one sync CronJob for the 32 character site, got %r" % cj); sys.exit(1)
if len(cj[0]) > 52: print("FAIL F3c: CronJob %s is %d characters, over the 52 a CronJob name may have" % (cj[0], len(cj[0]))); bad += 1
if len(jobs) != 1 or len(jobs[0]) > 63: print("FAIL F3c: one-shot Job name %r is missing or over 63" % jobs); bad += 1
if not bad: print("  ok F3c: a 32 character site name gives CronJob %s (%d, limit 52) and Job %s (%d, limit 63)" % (cj[0], len(cj[0]), jobs[0], len(jobs[0])))
sys.exit(1 if bad else 0)
PY
fi
if helm template t charts/tockmox-platform -f ci/values.yaml -f "$tmp/site33.yaml" > /dev/null 2> "$tmp/plat33.err"; then
  bad "F3c: a 33 character site name renders; the CronJob name would be 53 characters and the API server refuses it at apply"
elif ! grep -Eq 'at most 32 characters|maxLength: got 33, want 32' "$tmp/plat33.err"; then
  bad "F3c: a 33 character site name failed, but not on the 32 character limit: $(head -c 300 "$tmp/plat33.err")"
else
  good "F3c: a 33 character site name is refused at render on the 32 character limit (schema maxLength, and the template check behind it)"
fi

# ---------------------------------------------------------------- F3d
# The docs site is on by default and carries no image (ADR-0036): the operator
# publishes it with tools/publish-docs.sh and the bucket starts with a
# placeholder page. Assert on the artifact. The default render has the docs
# Ingress, a bootstrap SITES line for docs with a writer key and the placeholder
# flag, the placeholder ConfigMap mounted into the bootstrap Job, and NO sync
# CronJob, no SYNC_JOBS line and no `tockmox-docs` string. The operator fixture
# (F3) yields exactly its own CronJob. apps.docs.enabled=false removes every
# docs object. --mutate-default renders the fixture as if it were the default,
# so the no-CronJob leg goes red; --mutate-placeholder renders the docs-off
# variant as if it were the default, so the placeholder leg goes red.
dflt_file="$tmp/plat-default.yaml"
helm template t charts/tockmox-platform -f ci/values.yaml > "$dflt_file"
off_file="$tmp/plat-off.yaml"
helm template t charts/tockmox-platform -f ci/values.yaml --set apps.docs.enabled=false > "$off_file"
[ "${1:-}" = "--mutate-default" ] && dflt_file="$tmp/plat.yaml"
[ "${1:-}" = "--mutate-placeholder" ] && dflt_file="$off_file"
python3 - "$dflt_file" "$tmp/plat.yaml" "$off_file" <<'PY' || rc=1
import sys, yaml
bad = 0
def fail(m):
    global bad; print("FAIL F3d: " + m); bad += 1
def load(p): return [d for d in yaml.safe_load_all(open(p)) if d]
def crons(docs): return sorted(d["metadata"]["name"] for d in docs if d.get("kind") == "CronJob" and "-sync-" in d["metadata"]["name"])
def boot(docs):
    b = [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"] == "tockmox-garage-bootstrap"]
    if len(b) != 1: fail("bootstrap Job not rendered"); return None
    return b[0]["spec"]["template"]["spec"]
def env(spec): return {e["name"]: e.get("value", "") for e in spec["containers"][0]["env"]}
def has(docs, kind, name): return any(d.get("kind") == kind and d["metadata"]["name"] == name for d in docs)
dflt, fixture, off = load(sys.argv[1]), load(sys.argv[2]), load(sys.argv[3])
if crons(dflt): fail("a default render has sync CronJob(s) %s; the product docs are published by tools/publish-docs.sh, never synced from an image" % crons(dflt))
b = boot(dflt)
if b is not None:
    sj = [l for l in env(b).get("SYNC_JOBS", "").splitlines() if l.strip()]
    if sj: fail("a default render's bootstrap Job would start %r" % sj)
    lines = [l.split() for l in env(b).get("SITES", "").splitlines() if l.strip()]
    docs_line = [l for l in lines if l and l[0] == "docs"]
    if len(docs_line) != 1 or len(docs_line[0]) != 6 or docs_line[0][4] != "true" or docs_line[0][5] != "true":
        fail("the default bootstrap SITES has no docs line with a writer key and the placeholder flag (got %r); without it the docs bucket has no placeholder page" % docs_line)
    if not has(dflt, "ConfigMap", "tockmox-garage-docs-placeholder"):
        fail("the default render has no placeholder ConfigMap: a fresh install's docs Ingress would answer 404")
    vols = [v for v in b.get("volumes", []) if v.get("name") == "placeholder" and (v.get("configMap") or {}).get("name") == "tockmox-garage-docs-placeholder"]
    mnts = [m for m in b["containers"][0].get("volumeMounts", []) if m.get("name") == "placeholder" and m.get("mountPath") == "/placeholder"]
    if not vols or not mnts: fail("the bootstrap Job does not mount the placeholder ConfigMap at /placeholder")
    if "placeholder/index.html" not in "\n".join(b["containers"][0]["args"]): fail("the bootstrap script never reads the placeholder page")
if not has(dflt, "Ingress", "garage-web-docs"): fail("the default render has no docs Ingress")
if "tockmox-docs" in open(sys.argv[1]).read(): fail("the default render still names tockmox-docs")
if crons(fixture) != ["tockmox-garage-sync-handbook"]:
    fail("an operator-supplied site must yield exactly its own sync CronJob, got %r" % crons(fixture))
fb = boot(fixture)
if fb is not None:
    sj = [l for l in env(fb).get("SYNC_JOBS", "").splitlines() if l.strip()]
    if len(sj) != 1 or not sj[0].startswith("tockmox-garage-sync-handbook "):
        fail("the operator-supplied site's install-time run is %r" % sj)
for kind, name in (("Ingress", "garage-web-docs"), ("ConfigMap", "tockmox-garage-docs-placeholder")):
    if has(off, kind, name): fail("apps.docs.enabled=false still renders %s %s" % (kind, name))
if not bad: print("  ok F3d: the default render has the docs Ingress, a docs bucket line with a writer key and the placeholder mounted, and no docs sync, SYNC_JOBS entry or tockmox-docs string; an operator-supplied site still gets its own CronJob; docs off removes the docs objects")
sys.exit(1 if bad else 0)
PY

# ---------------------------------------------------------------- F4
# The observability render with the stack on (ci/values.yaml). Each --mutate-*
# flag renders with one load-bearing value removed, so the matching leg goes red.
f4_args=()
case "${1:-}" in
  --mutate-rulewave)    f4_args=(--set 'kube-prometheus-stack.defaultRules.annotations=null') ;;
  --mutate-failpolicy)  f4_args=(--set 'kube-prometheus-stack.prometheusOperator.admissionWebhooks.failurePolicy=Fail') ;;
  --mutate-webhookphase) f4_args=(--set 'kube-prometheus-stack.prometheusOperator.admissionWebhooks.mutatingWebhookConfiguration.annotations=null') ;;
  --mutate-patchphase)  f4_args=(--set 'kube-prometheus-stack.prometheusOperator.admissionWebhooks.patch.annotations=null') ;;
esac
helm template t charts/tockmox-observability -f ci/values.yaml ${f4_args[@]+"${f4_args[@]}"} > "$tmp/obs-f4.yaml"
python3 - "$tmp/obs-f4.yaml" <<'PY' || rc=1
import sys, yaml
bad = 0
def fail(m):
    global bad; print("FAIL F4: " + m); bad += 1
WAVE = "argocd.argoproj.io/sync-wave"; HOOK = "argocd.argoproj.io/hook"
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if isinstance(d, dict)]
def ann(d): return (d.get("metadata") or {}).get("annotations") or {}
def wave(d):
    try: return int(ann(d).get(WAVE, "0"))
    except ValueError: return None
rules = [d for d in docs if d.get("kind") == "PrometheusRule"]
hooks = [d for d in docs if d.get("kind") in ("MutatingWebhookConfiguration", "ValidatingWebhookConfiguration") and d["metadata"]["name"].endswith("-admission")]
jobs = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"].endswith(("-admission-create", "-admission-patch"))}
ops = [d for d in docs if d.get("kind") == "Deployment" and (d["metadata"].get("labels") or {}).get("app") == "kube-prometheus-stack-operator"]
if not rules: fail("the observability render has no PrometheusRule, so this check would pass on nothing")
if len(hooks) != 2: fail("expected a MutatingWebhookConfiguration and a ValidatingWebhookConfiguration named *-admission, found %d" % len(hooks))
if len(jobs) != 2: fail("expected the admission create and patch Jobs, found %s" % sorted(jobs))
if len(ops) != 1: fail("expected one operator Deployment, found %d" % len(ops))
if not bad:
    for r in rules:
        w = wave(r)
        if w is None or w < 1: fail("PrometheusRule %s has no sync-wave of 1 or later (%r), so ArgoCD may apply it before the operator that serves its webhook is healthy" % (r["metadata"]["name"], ann(r).get(WAVE)))
        if HOOK in ann(r): fail("PrometheusRule %s is an ArgoCD hook; hooks are not pruned and are recreated on every sync" % r["metadata"]["name"])
    whw = []
    for h in hooks:
        for w in h["webhooks"]:
            if w.get("failurePolicy") != "Ignore": fail("webhook %s has failurePolicy %r; this fix is ordering only and leaves the upstream Ignore (changing it is a separate decision)" % (w["name"], w.get("failurePolicy")))
        if ann(h).get(HOOK) != "PreSync": fail("%s %s is not an ArgoCD PreSync hook (%r): its caBundle would only be patched after the sync phase that applies the rules" % (h["kind"], h["metadata"]["name"], ann(h).get(HOOK)))
        whw.append(wave(h))
    patch = [j for n, j in jobs.items() if n.endswith("-admission-patch")]
    if patch:
        pj = patch[0]
        if ann(pj).get(HOOK) != "PreSync": fail("the caBundle patch Job is not an ArgoCD PreSync hook (%r): a Helm post-install hook runs as PostSync, after the rules" % ann(pj).get(HOOK))
        elif whw and (wave(pj) is None or wave(pj) <= max(whw)): fail("the caBundle patch Job (wave %r) does not run after the webhook configurations (wave %r): it patches an object that does not exist yet" % (wave(pj), max(whw)))
        args = " ".join(pj["spec"]["template"]["spec"]["containers"][0].get("args", []))
        if "--patch-failure-policy=Fail" in args: fail("the patch Job would set the webhook failurePolicy to Fail; this fix is ordering only and leaves the upstream default: %s" % args)
    cj = [j for n, j in jobs.items() if n.endswith("-admission-create")]
    if cj and ann(cj[0]).get(HOOK) not in (None, "PreSync"): fail("the certificate Job is hook %r; the webhook needs its secret before the operator starts" % ann(cj[0]).get(HOOK))
    w0 = wave(ops[0])
    if w0 is None or w0 >= 1: fail("the operator Deployment is wave %r; the rules are wave 1 and must come after it" % w0)
if not bad: print("  ok F4: %d PrometheusRules are sync wave 1 or later and none is a hook; both webhook configurations are PreSync hooks with the upstream failurePolicy Ignore; the caBundle patch Job is a PreSync hook after them and does not change it; the operator Deployment is wave 0" % len(rules))
sys.exit(1 if bad else 0)
PY

# ---------------------------------------------------------------- F5, F6
# Every layer, rendered into the destination namespace the installer assigns it
# (must match dest_ns() in install/tockmox-install.sh, like
# tools/check-no-ghost-policies.sh), in two passes. Each --mutate-* flag breaks
# one thing so the matching leg goes red.
f56_dest() {
  case "$1" in
    tockmox-ai)                              echo tockmox-ai ;;
    tockmox-observability|tockmox-exporters) echo tockmox-monitoring ;;
    tockmox-platform)                        echo tockmox-platform ;;
    tockmox-identity)                        echo tockmox-authentik ;;
    tockmox-devops)                          echo tockmox-devops ;;
    tockmox-selfcheck)                       echo tockmox-selfcheck ;;
    *)                                       echo argocd ;;
  esac
}
f56_extra=()
case "${1:-}" in
  --mutate-ns-missing) f56_extra=(--set 'garage.credentialsNamespaces={tockmox-ai,tockmox-authentik,news}') ;;
  --mutate-ns-twice)   f56_extra=(--set 'garage.createCredentialsNamespaces={tockmox-ai}') ;;
esac
# The other legs' --mutate-* runs do not touch what F5/F6 look at, so they skip it
# (sixteen renders each, and --selftest runs this script once per leg).
case "${1:-}" in ""|--mutate-ingresswave|--mutate-ns-missing|--mutate-ns-twice) f56_passes="defaults all-on" ;; *) f56_passes="" ;; esac
for pass in $f56_passes; do
  w56="$tmp/f56-$pass"; mkdir -p "$w56"
  vf=(-f ci/values.yaml); [ "$pass" = all-on ] && vf=(-f ci/values.yaml -f ci/values-all-on.yaml)
  for c in charts/tockmox-*; do
    n=$(basename "$c"); [ "$n" = "tockmox-common" ] && continue
    # The CRD layer is cluster-scoped CustomResourceDefinitions only (and some
    # of their schemas hold a bare `=` that PyYAML cannot load); it has nothing
    # for either check to look at.
    [ "$n" = "tockmox-crds" ] && continue
    extra=(); [ "$n" = "tockmox-platform" ] && extra=(${f56_extra[@]+"${f56_extra[@]}"})
    helm template t "$c" -n "$(f56_dest "$n")" "${vf[@]}" ${extra[@]+"${extra[@]}"} > "$w56/$n.yaml"
    printf '%s\n' "$(f56_dest "$n")" > "$w56/$n.ns"
    awk '/tockmox.com\/sync-wave:/{gsub(/"/,"",$2); print $2}' "$c/Chart.yaml" > "$w56/$n.wave"
  done
  python3 - "$w56" "$pass" "${1:-}" <<'PY' || rc=1
import sys, os, glob, yaml
d, label, mutate = sys.argv[1], sys.argv[2], sys.argv[3]
bad = 0
def fail(m):
    global bad; print("FAIL %s [%s]" % (m, label)); bad += 1
WAVE = "argocd.argoproj.io/sync-wave"
BUILTIN = {"argocd", "kube-system", "kube-public", "kube-node-lease", "default"}
layers = {}
for f in sorted(glob.glob(d + "/*.yaml")):
    n = os.path.basename(f)[:-5]
    docs = [x for x in yaml.safe_load_all(open(f)) if isinstance(x, dict) and x.get("kind")]
    layers[n] = dict(docs=docs, ns=open(d + "/" + n + ".ns").read().strip(), wave=int(open(d + "/" + n + ".wave").read().strip()))
def md(o): return o.get("metadata") or {}
def wave(o):
    try: return int((md(o).get("annotations") or {}).get(WAVE, "0"))
    except ValueError: return None
# ---- F5
ing_total = lb_total = 0
lb_layers = {n: max(wave(o) for o in L["docs"] if o["kind"] == "Service" and (o.get("spec") or {}).get("type") == "LoadBalancer")
             for n, L in layers.items() if any(o["kind"] == "Service" and (o.get("spec") or {}).get("type") == "LoadBalancer" for o in L["docs"])}
lb_total = len(lb_layers)
for n, L in layers.items():
    ings = [o for o in L["docs"] if o["kind"] == "Ingress"]
    ing_total += len(ings)
    for o in ings:
        w = wave(o)
        if mutate == "--mutate-ingresswave": w = 0
        if n in lb_layers:
            if w is None or w <= lb_layers[n]:
                fail("F5: Ingress %s in %s is sync-wave %r but the LoadBalancer Service that gives it an address is wave %d: ArgoCD waits for the address before it starts the later wave" % (md(o)["name"], n, w, lb_layers[n]))
        elif not any(lb_layers and m != n and layers[m]["wave"] < L["wave"] for m in lb_layers):
            fail("F5: Ingress %s in %s, and no earlier layer renders a LoadBalancer Service to give it an address" % (md(o)["name"], n))
if label == "all-on" and (ing_total < 2 or not lb_total): fail("F5: the all-on render has %d Ingress and %d layers with a LoadBalancer Service, so this check would pass on nothing" % (ing_total, lb_total))
# ---- F6
owner = {}
for n, L in layers.items():
    for o in L["docs"]:
        if o["kind"] == "Namespace":
            owner.setdefault(md(o)["name"], set()).add(n)
for ns, who in sorted(owner.items()):
    if len(who) > 1: fail("F6: Namespace %s is rendered by two layers (%s); one layer must own it" % (ns, ", ".join(sorted(who))))
checked = 0
for n, L in layers.items():
    ok = set(BUILTIN) | {L["ns"]}
    ok |= {ns for ns, who in owner.items() if n in who}
    ok |= {ns for ns, who in owner.items() if any(layers[m]["wave"] < L["wave"] for m in who)}
    seen = set()
    for o in L["docs"]:
        t = md(o).get("namespace")
        if not t or o["kind"] == "Namespace": continue
        checked += 1
        if t not in ok and (t, o["kind"]) not in seen:
            seen.add((t, o["kind"]))
            fail("F6: %s %s in layer %s targets namespace %s, which does not exist at that point: no Namespace for it is rendered by this layer or by a layer with an earlier sync-wave, and it is not this layer's destination (%s)" % (o["kind"], md(o).get("name"), n, t, L["ns"]))
if not bad: print("  ok F5/F6 [%s]: every Ingress is a later sync-wave than its layer's LoadBalancer Service (or its layer comes after the layer that has one); %d explicitly namespaced objects all target a namespace that exists by then; no Namespace has two owners" % (label, checked))
sys.exit(1 if bad else 0)
PY
done

if [ "$rc" -eq 0 ]; then echo "check-upgrade-safety: ok"; else echo "check-upgrade-safety: FAILED"; fi
exit "$rc"

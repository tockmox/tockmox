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
#     (0.7.0 lab pass). Since TM-1196 (0.9.0) the Job is litellm-helm's own,
#     run as an Argo CD Sync hook with delete policy BeforeHookCreation, which
#     deletes the previous Job before creating the next, so the template is
#     never patched. Asserted on the render: exactly one migrations Job, named
#     <release>-litellm-migrations (no hash: Tockmox renders no Job of its
#     own, and neither template file is back in the chart); its OWN metadata
#     carries argocd.argoproj.io/hook: Sync and hook-delete-policy:
#     BeforeHookCreation, no Helm hook, and its pod template carries neither;
#     the CNPG Cluster it waits on is in the same sync wave; a LiteLLM image
#     bump keeps the name and the hook and changes the image (the migration
#     reruns with no operator step); and each setting that would turn this into
#     a PreSync deadlock, an ordinary Job or no migration at all refuses to
#     render (migrationJob.enabled false, either subchart hook switch on, a
#     hook annotation that is not Sync, a delete policy that is not
#     BeforeHookCreation). `--selftest` proves it goes red on a PreSync hook, a
#     hash-named Job, a missing hook, split sync waves and a guard that no
#     longer refuses.
# F1b The seam F1 relies on is still upstream's. The vendored litellm-helm chart
#     is rendered on its own with the same values: migrationJob.jobAnnotations
#     must land on the Job's own metadata and not on its pod template. A
#     litellm-helm bump that moves or drops the seam goes red here, instead of
#     rendering a Job with no hook that wedges the next image bump.
#     `--selftest` proves it goes red on a subchart that drops the seam.
# F7  A LiteLLM or Open WebUI version change is preceded by a backup of its
#     database, and a failed backup stops the upgrade (TM-1054). Asserted on the
#     render: the hook is a PreSync hook (and a Helm pre-install/pre-upgrade
#     hook), its ServiceAccount, Role and RoleBinding are PreSync hooks in an
#     earlier wave, the Role can read the named Clusters and workloads and
#     create and read Backups and nothing else, and the migrations Job is a
#     Sync hook, which Argo runs AFTER every PreSync hook: that is the ordering
#     the card asks for. The script is then EXTRACTED AND RUN against a stub
#     kubectl: no Cluster or no workload yet (a first install) passes with no
#     Backup; the same version passes with no Backup; a changed version creates
#     one Backup of the right Cluster and exits 0 only after the phase reaches
#     completed; a failed Backup, a Backup that never completes, a refused
#     create, an API that cannot be asked and a running image that cannot be
#     read each exit 1; with Open WebUI's Cluster named, only the application
#     whose version changed is backed up. `--selftest` proves each leg goes red.
#     LIMIT: no cluster. That CNPG's barman-cloud plugin completes a Backup
#     created this way, and that a failed PreSync hook stops an Argo sync before
#     anything is applied, are the lab's to prove (the run sheet's forced-failure
#     leg of TM-1054).
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
# shellcheck disable=SC2016  # the mutations' sed patterns match Helm and script text literally, not shell variables
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-upgrade-safety: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-upgrade-safety: python3 PyYAML missing" >&2; exit 2; }

UPGRADE=docs/deployment/upgrade.md
AI_CHART=charts/tockmox-ai
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# F1/F1b mutations. The render ones edit the RENDERED text (BSD sed has no
# portable -i, so they go through a temp file); the guard one edits a COPY of the
# ai chart; the seam one swaps in a vendored subchart that drops jobAnnotations.
MUT=""
SUB_TGZ_OVERRIDE=""
case "${1:-}" in
  --mutate-presync|--mutate-hashname|--mutate-nohook|--mutate-wave|--mutate-ub-*)
    MUT="${1#--mutate-}" ;;
  --mutate-guard)
    cp -R "$AI_CHART" "$tmp/ai-chart"; AI_CHART="$tmp/ai-chart"
    # Remove the migrationJob.enabled refusal: the F1 refusal assertion must then go red.
    sed -i.bak '/^{{- if not \$mj.enabled -}}$/,/^{{- end -}}$/d' "$AI_CHART/templates/preflight.yaml"
    rm -f "$AI_CHART"/templates/*.bak ;;
  --mutate-seam)
    mkdir -p "$tmp/seam"
    tar xzf "$AI_CHART"/charts/litellm-helm-*.tgz -C "$tmp/seam"
    # The subchart drops jobAnnotations from the Job's metadata.
    sed -i.bak '/with .Values.migrationJob.jobAnnotations/,/^    {{- end }}$/d' "$tmp/seam/litellm-helm/templates/migrations-job.yaml"
    rm -f "$tmp/seam/litellm-helm/templates/"*.bak
    # Rendered as a directory, not re-packed: macOS tar adds AppleDouble ._ entries that helm refuses to load.
    SUB_TGZ_OVERRIDE="$tmp/seam/litellm-helm" ;;
esac

# Render the ai layer to $tmp/ai.yaml, with the F1 render mutation applied when one is asked for.
render_ai() {
  helm template t "$AI_CHART" -f ci/values.yaml "$@" > "$tmp/ai.yaml"
  case "$MUT" in
    presync)  sed 's#argocd.argoproj.io/hook: Sync#argocd.argoproj.io/hook: PreSync#' "$tmp/ai.yaml" > "$tmp/ai.mut" ;;
    hashname) sed 's#name: t-litellm-migrations$#name: t-litellm-migrations-0123456789#' "$tmp/ai.yaml" > "$tmp/ai.mut" ;;
    nohook)   grep -v 'argocd.argoproj.io/hook' "$tmp/ai.yaml" > "$tmp/ai.mut" || true ;;
    wave)     sed 's#^  name: tockmox-litellm-db$#  name: tockmox-litellm-db\n  annotations: {argocd.argoproj.io/sync-wave: "-1"}#' "$tmp/ai.yaml" > "$tmp/ai.mut" ;;
    *) return 0 ;;
  esac
  mv "$tmp/ai.mut" "$tmp/ai.yaml"
}

# One line per migrations Job in the render: "<name> <hook> <delete-policy> <helm-hook> <pod-template-argocd-annotations> <image>".
migration_jobs() {
  render_ai "$@"
  python3 - "$tmp/ai.yaml" <<'PY'
import sys, yaml
out = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "Job" and "-litellm-migrations" in d["metadata"]["name"]:
        a = d["metadata"].get("annotations") or {}
        pa = (d["spec"]["template"]["metadata"].get("annotations") or {})
        helm = ",".join(sorted(k for k in a if k.startswith("helm.sh/"))) or "-"
        podarg = ",".join(sorted(k for k in pa if k.startswith("argocd.argoproj.io/"))) or "-"
        img = d["spec"]["template"]["spec"]["containers"][0]["image"]
        out.append("%s %s %s %s %s %s" % (d["metadata"]["name"], a.get("argocd.argoproj.io/hook", "-"),
                   a.get("argocd.argoproj.io/hook-delete-policy", "-"), helm, podarg, img))
print("\n".join(out) if out else "NOJOB")
PY
}

if [ "${1:-}" = "--selftest" ]; then
  out=$(bash tools/check-upgrade-safety.sh --mutate-presync 2>&1) && { echo "selftest FAIL: F1 passed with the migrations Job as a PreSync hook"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1: .*not a Sync hook' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1 assertion goes red when the migrations Job is a PreSync hook (the CNPG deadlock)"
  out=$(bash tools/check-upgrade-safety.sh --mutate-hashname 2>&1) && { echo "selftest FAIL: F1 passed with a hash-named Job"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1: .*named after a hash' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1 assertion goes red when the migrations Job is hash-named again"
  out=$(bash tools/check-upgrade-safety.sh --mutate-nohook 2>&1) && { echo "selftest FAIL: F1 passed with the hook annotations gone"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1: .*not a Sync hook' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1 assertion goes red when the Job carries no hook (it would wedge on the next image bump)"
  out=$(bash tools/check-upgrade-safety.sh --mutate-wave 2>&1) && { echo "selftest FAIL: F1 passed with the CNPG Cluster in an earlier wave than the Job"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1: .*sync wave' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1 assertion goes red when the Cluster and the Job are not in one wave"
  out=$(bash tools/check-upgrade-safety.sh --mutate-guard 2>&1) && { echo "selftest FAIL: F1 passed with the migrationJob.enabled refusal removed"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1: .*enabled=false (no migration at all) renders' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1 assertion goes red when a render with no migrations Job is accepted"
  out=$(bash tools/check-upgrade-safety.sh --mutate-seam 2>&1) && { echo "selftest FAIL: F1b passed with a subchart that drops jobAnnotations"; exit 1; }
  printf '%s' "$out" | grep 'FAIL F1b: ' >/dev/null || { echo "selftest FAIL: wrong message: $out"; exit 1; }
  echo "selftest ok: the F1b assertion goes red when the subchart no longer puts jobAnnotations on the Job"
  for ub in "ub-hooksync:F7: .*is not a PreSync hook" "ub-rolesecrets:F7: .*Role" "ub-nowait:F7: .*completed" "ub-failok:F7: .*failed Backup" \
            "ub-alwaysbackup:F7: .*no version change" "ub-failopen-cluster:F7: .*cannot be asked" "ub-failopen-workload:F7: .*cannot be asked" \
            "ub-unknownimage:F7: .*cannot be read" "ub-wrongcluster:F7: .*wrong Cluster" "ub-createfail:F7: .*refused"; do
    name="${ub%%:*}"; want="${ub#*:}"
    out=$(bash tools/check-upgrade-safety.sh "--mutate-$name" 2>&1) && { echo "selftest FAIL: F7 passed on the $name mutant"; exit 1; }
    printf '%s' "$out" | grep -E "FAIL $want" >/dev/null || { echo "selftest FAIL: $name: wrong message: $out"; exit 1; }
    echo "selftest ok: the F7 assertions go red on the $name mutant"
  done
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
for f in templates/litellm-migrations-job.yaml templates/_litellm-migrations.tpl; do
  [ ! -e "$AI_CHART/$f" ] || bad "F1: $AI_CHART/$f is back. Since TM-1196 the migrations Job is the subchart's own, as a Sync hook; a Tockmox-owned Job beside it would migrate one database twice"
done
base=$(migration_jobs)
if [ "$base" = "NOJOB" ]; then
  bad "F1: no litellm migrations Job in the render of $AI_CHART with ci/values.yaml"
elif [ "$(printf '%s\n' "$base" | wc -l | tr -d ' ')" != "1" ]; then
  bad "F1: more than one migrations Job renders ($(echo "$base" | tr '\n' ';')); two Jobs would migrate one database"
else
  # read, not `set --`: the positional parameters carry the --mutate-* switch the later checks read.
  read -r name hook policy helmhook podarg _ <<<"$base"
  if printf '%s' "$name" | grep -E -- '-migrations-[0-9a-f]{6,}$' >/dev/null; then
    bad "F1: the migrations Job is '$name', named after a hash. Tockmox no longer renders its own Job; the subchart's is t-litellm-migrations and the hook, not a name, is what keeps it from wedging"
  elif [ "$name" != "t-litellm-migrations" ]; then
    bad "F1: the migrations Job is '$name', want t-litellm-migrations (the subchart's own)"
  elif [ "$hook" != "Sync" ]; then
    bad "F1: the migrations Job's hook is '$hook', not a Sync hook. PreSync deadlocks against the CNPG Cluster this Application creates in the sync phase; no hook is an ordinary Job that fails on 'field is immutable' at the next LiteLLM image bump"
  elif [ "$policy" != "BeforeHookCreation" ]; then
    bad "F1: the migrations Job's hook-delete-policy is '$policy', want BeforeHookCreation (the previous Job must be deleted before the next is created)"
  elif [ "$helmhook" != "-" ]; then
    bad "F1: the migrations Job carries Helm hook annotations ($helmhook); Argo would map them to PreSync"
  elif [ "$podarg" != "-" ]; then
    bad "F1: the hook annotations are on the Job's pod template ($podarg), not on the Job's own metadata"
  else
    good "F1: one migrations Job, the subchart's own ($name), a Sync hook with BeforeHookCreation on its own metadata"
    # The Job and the Cluster it waits on are one wave, so the Job's retry budget covers the bootstrap.
    python3 - "$tmp/ai.yaml" <<'PY' || rc=1
import sys, yaml
w = {}
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d: continue
    k = d.get("kind"); n = d["metadata"]["name"]
    if (k == "Job" and n == "t-litellm-migrations") or (k == "Cluster" and n == "tockmox-litellm-db"):
        w[k] = str((d["metadata"].get("annotations") or {}).get("argocd.argoproj.io/sync-wave", "0"))
if set(w) != {"Job", "Cluster"}:
    print("FAIL F1: could not find both the migrations Job and the CNPG Cluster (%s)" % sorted(w)); sys.exit(1)
if w["Job"] != w["Cluster"]:
    print("FAIL F1: the migrations Job is in sync wave %s and the CNPG Cluster in sync wave %s; the Job's retry budget only covers the database's bootstrap when they are applied together" % (w["Job"], w["Cluster"])); sys.exit(1)
print("  ok F1: the migrations Job and the CNPG Cluster share sync wave %s" % w["Job"])
PY
    # A LiteLLM image bump mid-life: same Job name, same hook, the new image. The hook reruns the migration.
    got=$(migration_jobs --set litellm.image.tag=9.9.9)
    read -r gname ghook gpolicy _ _ gimage <<<"$got"
    if [ "$gname" = "$name" ] && [ "$ghook" = "Sync" ] && [ "$gpolicy" = "BeforeHookCreation" ] && [ "${gimage##*:}" = "9.9.9" ]; then
      good "F1: a LiteLLM image bump keeps the Job's name and hook and moves its image to 9.9.9 (BeforeHookCreation reruns it)"
    else
      bad "F1: --set litellm.image.tag=9.9.9 gives '$got'; want $name, Sync, BeforeHookCreation and the 9.9.9 image"
    fi
  fi
fi
# Each setting that would turn the hook into a deadlock, an ordinary Job or no migration refuses to render.
refuses() { # label, expected message fragment, helm args...
  local label="$1" frag="$2"; shift 2
  if helm template t "$AI_CHART" -f ci/values.yaml "$@" >/dev/null 2>"$tmp/guard.err"; then
    bad "F1: $label renders; it must refuse"
  elif grep -F -- "$frag" "$tmp/guard.err" >/dev/null; then
    good "F1: $label refuses to render"
  else
    bad "F1: $label failed, but not with the guard's message: $(head -3 "$tmp/guard.err")"
  fi
}
refuses "litellm.migrationJob.enabled=false (no migration at all)" "nothing runs LiteLLM's schema migrations" --set litellm.migrationJob.enabled=false
refuses "litellm.migrationJob.hooks.argocd.enabled=true (PreSync deadlock)" "deadlocks with the Job retrying" --set litellm.migrationJob.hooks.argocd.enabled=true
refuses "litellm.migrationJob.hooks.helm.enabled=true (mapped to PreSync)" "deadlocks with the Job retrying" --set litellm.migrationJob.hooks.helm.enabled=true
refuses "a PreSync hook annotation" 'is "PreSync", not Sync' --set-string 'litellm.migrationJob.jobAnnotations.argocd\.argoproj\.io/hook=PreSync'
refuses "a delete policy other than BeforeHookCreation" "not BeforeHookCreation" --set-string 'litellm.migrationJob.jobAnnotations.argocd\.argoproj\.io/hook-delete-policy=HookSucceeded'
# And the other direction: turning the whole gateway off renders no migrations Job and does not trip the guards.
if render_ai --set apps.litellm.enabled=false --set capabilities.aiPlane.enabled=false 2>"$tmp/off.err"; then
  if grep -q -- 'litellm-migrations' "$tmp/ai.yaml"; then bad "F1: with the gateway off a migrations Job still renders"
  else good "F1: with the gateway off no migrations Job renders and no guard trips"; fi
else
  bad "F1: the gateway off fails to render: $(head -3 "$tmp/off.err")"
fi

# ---------------------------------------------------------------- F1b
sub_tgz="${SUB_TGZ_OVERRIDE:-$(ls "$AI_CHART"/charts/litellm-helm-*.tgz 2>/dev/null | head -1)}"
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
yaml.safe_dump(v, open(sys.argv[3], "w"))
PY
  helm template t "$sub_tgz" -f "$tmp/sub-values.yaml" > "$tmp/sub.yaml"
  python3 - "$tmp/sub.yaml" <<'PY' || rc=1
import sys, yaml
jobs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Job" and d["metadata"]["name"] == "t-litellm-migrations"]
if len(jobs) != 1:
    print("FAIL F1b: the vendored subchart renders %d migrations Jobs with the shipped values, want 1" % len(jobs)); sys.exit(1)
j = jobs[0]
a = j["metadata"].get("annotations") or {}
pa = j["spec"]["template"]["metadata"].get("annotations") or {}
for k, v in (("argocd.argoproj.io/hook", "Sync"), ("argocd.argoproj.io/hook-delete-policy", "BeforeHookCreation")):
    if a.get(k) != v:
        print("FAIL F1b: the vendored litellm-helm does not put migrationJob.jobAnnotations[%s]=%s on the Job's own metadata (got %r). Upstream moved or dropped the seam TM-1196 relies on (BerriAI/litellm#42242); a Job with no hook wedges on 'field is immutable' at the next image bump" % (k, v, a.get(k))); sys.exit(1)
    if k in pa:
        print("FAIL F1b: %s is on the Job's pod template as well as its metadata" % k); sys.exit(1)
print("  ok F1b: the vendored litellm-helm puts migrationJob.jobAnnotations on the Job's own metadata, not its pod template")
PY
fi

# The F1/F1b mutants have nothing to say about the rest; stop here instead of rendering every layer again.
case "$MUT" in presync|hashname|nohook|wave) exit "$rc" ;; esac
[ "${1:-}" != "--mutate-seam" ] && [ "${1:-}" != "--mutate-guard" ] || exit "$rc"

# ---------------------------------------------------------------- F7
# The pre-upgrade backup hook (TM-1054): its render, then its script run against a stub kubectl.
helm template t "$AI_CHART" -f ci/values.yaml --set modelGateway.upgradeBackup.openWebuiClusterName=open-webui-db > "$tmp/ub.yaml"
case "$MUT" in
  ub-hooksync)   sed 's#argocd.argoproj.io/hook: PreSync#argocd.argoproj.io/hook: Sync#' "$tmp/ub.yaml" > "$tmp/ub.mut" && mv "$tmp/ub.mut" "$tmp/ub.yaml" ;;
  ub-rolesecrets) sed 's#resources: \["backups"\]#resources: ["backups", "secrets"]#' "$tmp/ub.yaml" > "$tmp/ub.mut" && mv "$tmp/ub.mut" "$tmp/ub.yaml" ;;
esac
python3 - "$tmp/ub.yaml" "$tmp/ub.sh" <<'PY' || rc=1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
names = "tockmox-pre-upgrade-backup"
bad = 0
def fail(msg):
    global bad
    print("FAIL F7: " + msg); bad += 1
for kind in ("ServiceAccount", "Role", "RoleBinding", "Job"):
    d = by.get((kind, names))
    if d is None:
        fail("%s %s is not rendered" % (kind, names)); continue
    a = d["metadata"].get("annotations") or {}
    if a.get("argocd.argoproj.io/hook") != "PreSync":
        fail("%s %s is not a PreSync hook (%r): the backup would be taken in the sync phase, beside the migration it is meant to precede" % (kind, names, a.get("argocd.argoproj.io/hook")))
    if a.get("helm.sh/hook") != "pre-install,pre-upgrade":
        fail("%s %s is not a Helm pre-install/pre-upgrade hook (%r)" % (kind, names, a.get("helm.sh/hook")))
    if a.get("argocd.argoproj.io/hook-delete-policy") != "BeforeHookCreation":
        fail("%s %s does not delete its previous run before creating the next" % (kind, names))
    want_wave = "0" if kind == "Job" else "-1"
    if a.get("argocd.argoproj.io/sync-wave") != want_wave:
        fail("%s %s is in sync wave %r, want %s (identity before the Job that runs as it)" % (kind, names, a.get("argocd.argoproj.io/sync-wave"), want_wave))
role = by.get(("Role", names))
if role:
    rules = {}
    for r in role["rules"]:
        for g in r["apiGroups"]:
            for res in r["resources"]:
                rules.setdefault((g, res), set()).update(r["verbs"])
    allowed = {("postgresql.cnpg.io", "clusters"): {"get"}, ("postgresql.cnpg.io", "backups"): {"get", "create"},
               ("apps", "deployments"): {"get"}, ("apps", "statefulsets"): {"get"}}
    for k, v in rules.items():
        if k not in allowed or not v <= allowed[k]:
            fail("Role %s grants %s on %s/%s; it may only read the named Clusters and workloads and create and read Backups" % (names, sorted(v), k[0], k[1]))
    for k in (("postgresql.cnpg.io", "clusters"), ("postgresql.cnpg.io", "backups"), ("apps", "deployments"), ("apps", "statefulsets")):
        if k not in rules:
            fail("Role %s grants nothing on %s/%s" % (names, k[0], k[1]))
    for r in role["rules"]:
        if r["resources"] in (["clusters"], ["deployments"], ["statefulsets"]) and not r.get("resourceNames"):
            fail("Role %s reads %s without resourceNames; scope it to the named objects" % (names, r["resources"][0]))
job = by.get(("Job", names))
if job:
    pod = job["spec"]["template"]
    if (pod["metadata"]["labels"].get("app.kubernetes.io/name")) != "tockmox-restore-drill":
        fail("the pod lacks the label the policy layer's allow-egress-restore-drill selects, so it cannot reach the API")
    c = pod["spec"]["containers"][0]
    open(sys.argv[2], "w").write(c["args"][0])
    if (c.get("resources") or {}).get("limits", {}).get("memory") is None:
        fail("the container has no memory limit")
mig = by.get(("Job", "t-litellm-migrations"))
if mig is None or (mig["metadata"].get("annotations") or {}).get("argocd.argoproj.io/hook") != "Sync":
    fail("the LiteLLM migrations Job is not a Sync hook, so Argo does not order it after the PreSync backup")
if not bad:
    print("  ok F7: the backup Job, its ServiceAccount, Role (read the named Clusters and workloads, create and read Backups, nothing else) and RoleBinding are PreSync hooks, ahead of the migrations Job, which is a Sync hook")
sys.exit(1 if bad else 0)
PY
# Off, and refusing, in the places it must be.
if helm template t "$AI_CHART" -f ci/values.yaml --set modelGateway.upgradeBackup.enabled=false | grep 'tockmox-pre-upgrade-backup' >/dev/null; then bad "F7: modelGateway.upgradeBackup.enabled=false still renders the hook"; else good "F7: modelGateway.upgradeBackup.enabled=false removes the hook"; fi
if helm template t "$AI_CHART" -f ci/values.yaml --set capabilities.dataProtection.enabled=false | grep 'tockmox-pre-upgrade-backup' >/dev/null; then bad "F7: with data protection declined (no backups to take) the hook still renders"; else good "F7: with data protection declined there is no hook (and no Backup it could take)"; fi
if helm template t "$AI_CHART" -f ci/values.yaml --set capabilities.dataProtection.enabled=false --set modelGateway.upgradeBackup.enabled=true >/dev/null 2>"$tmp/ub.err"; then bad "F7: upgradeBackup.enabled=true with nothing to back up renders; it must refuse"
elif grep -F 'there is no database to back up' "$tmp/ub.err" >/dev/null; then good "F7: upgradeBackup.enabled=true with nothing to back up refuses to render"
else bad "F7: upgradeBackup.enabled=true with nothing to back up failed, but not with the guard's message: $(head -3 "$tmp/ub.err")"; fi

# The script, run. Each scenario gets its own directory, a kubectl stub, and a clock that jumps.
if [ -s "$tmp/ub.sh" ]; then
  # Ablate the script for the mutants that test it. Written without sed -i (BSD).
  case "$MUT" in
    ub-nowait)             sed 's#case "\$PHASE" in#case "completed" in#' "$tmp/ub.sh" > "$tmp/ub.mut" ;;
    ub-failok)             sed 's#^ *failed)#failedX)#' "$tmp/ub.sh" > "$tmp/ub.mut" ;;
    ub-alwaysbackup)       sed 's#if \[ "\$HAVE" = "\$WANT" \]; then#if false; then#' "$tmp/ub.sh" > "$tmp/ub.mut" ;;
    ub-failopen-cluster)   sed 's#|| fail_blind "\$LABEL: cannot read Cluster#|| echo "$LABEL: cannot read Cluster#' "$tmp/ub.sh" > "$tmp/ub.mut" ;;
    ub-failopen-workload)  sed 's#|| fail_blind "\$LABEL: cannot read \$KIND#|| echo "$LABEL: cannot read $KIND#' "$tmp/ub.sh" > "$tmp/ub.mut" ;;
    ub-unknownimage)       grep -v 'none of its containers runs an image named' "$tmp/ub.sh" > "$tmp/ub.mut" || true ;;
    ub-wrongcluster)       sed 's#name: \$cluster#name: "tockmox-authentik-db"#; s#cluster: {name: \$cluster}#cluster: {name: "tockmox-authentik-db"}#' "$tmp/ub.sh" > "$tmp/ub.mut" ;;
    ub-createfail)         sed '/the Backup was refused/s#exit 1; }$#:; }#' "$tmp/ub.sh" > "$tmp/ub.mut" ;;
    *) cp "$tmp/ub.sh" "$tmp/ub.mut" ;;
  esac
  mkdir -p "$tmp/ubbin"
  cat > "$tmp/ubbin/kubectl" <<'SH'
#!/bin/sh
# Stub for F7. Files in $STUB_DIR steer it: cluster.<name> (the Cluster exists), workload.<name>.json (the
# Deployment or StatefulSet), phases (one Backup phase per line, the last repeats), fail.cluster, fail.workload,
# refuse.create. It records the Backup the script creates in created.json and counts phase reads in polls.
a="$*"; prev=""; name=""
for x in "$@"; do
  case "$prev" in cluster.postgresql.cnpg.io|backup.postgresql.cnpg.io|Deployment|StatefulSet) name="$x" ;; esac
  prev="$x"
done
case "$a" in
  *" create -f -"*)
    if [ -e "$STUB_DIR/refuse.create" ]; then cat > /dev/null; echo 'Error from server (Forbidden): backups.postgresql.cnpg.io is forbidden' >&2; exit 1; fi
    cat > "$STUB_DIR/created.json"
    echo "backup.postgresql.cnpg.io/created" ;;
  *"get cluster.postgresql.cnpg.io"*)
    if [ -e "$STUB_DIR/fail.cluster" ]; then echo 'The connection to the server was refused' >&2; exit 1; fi
    [ ! -e "$STUB_DIR/cluster.$name" ] || echo "cluster.postgresql.cnpg.io/$name" ;;
  *"get Deployment"*|*"get StatefulSet"*)
    if [ -e "$STUB_DIR/fail.workload" ]; then echo 'The connection to the server was refused' >&2; exit 1; fi
    [ ! -e "$STUB_DIR/workload.$name.json" ] || cat "$STUB_DIR/workload.$name.json" ;;
  *"get backup.postgresql.cnpg.io"*"status.phase"*)
    n=$(cat "$STUB_DIR/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_DIR/polls"
    l=$(wc -l < "$STUB_DIR/phases"); [ "$n" -le "$l" ] || n=$l
    sed -n "${n}p" "$STUB_DIR/phases" ;;
  *"status.backupId"*) echo 20261027T000000 ;;
  *"status.error"*) echo 'barman-cloud: the object store is unreachable' ;;
esac
exit 0
SH
  cat > "$tmp/ubbin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$tmp/ubbin/date" <<'SH'
#!/bin/sh
# The wall clock jumps 100 seconds per read: a Backup that never completes meets the 900s timeout after nine polls, and a slow one still gets its third poll.
case "$*" in
  *"+%s"*) n=$(cat "$STUB_DIR/clock" 2>/dev/null || echo 1000); echo $((n + 100)) > "$STUB_DIR/clock"; echo "$n" ;;
  *) exec /bin/date "$@" ;;
esac
SH
  chmod +x "$tmp/ubbin/kubectl" "$tmp/ubbin/sleep" "$tmp/ubbin/date"
  # scenario <name> <phases> [files to create: cluster.X workload=NAME:IMAGE ...]
  ubrun() {
    local d="$tmp/ub.$1" phases="$2"; shift 2
    rm -rf "$d"; mkdir -p "$d"
    # shellcheck disable=SC2086  # $phases is a space-separated list; each word is one line of the file
    printf '%s\n' $phases > "$d/phases"
    for f in "$@"; do
      case "$f" in
        workload=*) w="${f#workload=}"; wname="${w%%=*}"; wimg="${w#*=}"
                    jq -n --arg i "$wimg" '{spec:{template:{spec:{containers:[{name:"x",image:"busybox:1"},{name:"app",image:$i}]}}}}' > "$d/workload.$wname.json" ;;
        *) : > "$d/$f" ;;
      esac
    done
    # The exit status is the datum; errexit must not end the gate on a script that rightly exits 1.
    STUB_DIR="$d" PATH="$tmp/ubbin:$PATH" sh "$tmp/ub.mut" > "$d/out" 2>&1 && echo 0 > "$d/rc" || echo $? > "$d/rc"
  }
  ubcheck() { # name, expected rc, text that must be in the output, "created" or "none" (is a Backup created)
    local d="$tmp/ub.$1" rcw="$2" text="$3" made="$4" label="$5" ok=1
    [ "$(cat "$d/rc")" = "$rcw" ] || { bad "F7: $label: exit $(cat "$d/rc"), want $rcw: $(tail -3 "$d/out" | tr '\n' ' ')"; ok=0; }
    grep -F -- "$text" "$d/out" >/dev/null || { bad "F7: $label: the output lacks '$text': $(tail -3 "$d/out" | tr '\n' ' ')"; ok=0; }
    if [ "$made" = created ] && [ ! -s "$d/created.json" ]; then bad "F7: $label: no Backup was created"; ok=0; fi
    if [ "$made" = none ] && [ -e "$d/created.json" ]; then bad "F7: $label: a Backup was created that must not be"; ok=0; fi
    [ "$ok" = 1 ] || return 1
  }
  C=tockmox-litellm-db; WL=t-litellm; OW=open-webui-db; OWL=t-open-webui
  LITNEW=$(grep "^backup_if_changing 'litellm'" "$tmp/ub.sh" | sed "s/.* '\([^']*\)'\$/\1/")
  OWNEW=$(grep "^backup_if_changing 'open-webui'" "$tmp/ub.sh" | sed "s/.* '\([^']*\)'\$/\1/")
  if [ -z "$LITNEW" ] || [ -z "$OWNEW" ]; then bad "F7: could not read the versions this render runs from the script"; fi
  LITIMG="ghcr.io/berriai/litellm-database:$LITNEW"; LITOLD="ghcr.io/berriai/litellm-database:0.0.1"
  OWIMG="ghcr.io/open-webui/open-webui:$OWNEW";     OWOLD="ghcr.io/open-webui/open-webui:0.0.1"
  ubrun s1 "completed" ;                                                 ubcheck s1 0 "no Cluster $C yet" none "a first install (no Cluster)"
  ubrun s2 "completed" "cluster.$C" ;                                    ubcheck s2 0 "no Deployment $WL yet" none "a Cluster but no workload yet"
  ubrun s3 "completed" "cluster.$C" "workload=$WL=$LITIMG" "cluster.$OW" "workload=$OWL=$OWIMG" ; ubcheck s3 0 "no version change, no backup" none "the same versions"
  ubrun s4 "running running completed" "cluster.$C" "workload=$WL=$LITOLD" "cluster.$OW" "workload=$OWL=$OWIMG"
  ubcheck s4 0 "completed (backupId 20261027T000000)" created "a changed LiteLLM version"
  if [ -s "$tmp/ub.s4/created.json" ]; then
    python3 - "$tmp/ub.s4/created.json" "$C" "$LITNEW" <<'PY' || bad "F7: the Backup created for a changed LiteLLM version is not a plugin Backup of $C (the wrong Cluster, or no barman-cloud plugin)"
import sys, json
b = json.load(open(sys.argv[1]))
assert b["kind"] == "Backup" and b["spec"]["cluster"]["name"] == sys.argv[2], b
assert b["spec"]["method"] == "plugin" and b["spec"]["pluginConfiguration"]["name"] == "barman-cloud.cloudnative-pg.io", b
assert b["metadata"]["annotations"]["tockmox.com/to-version"] == sys.argv[3] and b["metadata"]["annotations"]["tockmox.com/from-version"] == "0.0.1", b
assert len(b["metadata"]["name"]) <= 63 and b["metadata"]["name"].startswith(sys.argv[2] + "-pre-"), b["metadata"]["name"]
PY
    [ "$(cat "$tmp/ub.s4/polls")" = 3 ] || bad "F7: the script read the Backup's phase $(cat "$tmp/ub.s4/polls") times, want 3 (running, running, completed): it did not wait for completed"
  fi
  ubrun s5 "running failed" "cluster.$C" "workload=$WL=$LITOLD" ;        ubcheck s5 1 "FAILED: barman-cloud: the object store is unreachable" created "a failed Backup"
  grep -F 'keeps running' "$tmp/ub.s5/out" >/dev/null || bad "F7: a failed Backup does not say the old version keeps running"
  ubrun s6 "running" "cluster.$C" "workload=$WL=$LITOLD" ;               ubcheck s6 1 "still 'running' after 900s" created "a Backup that never completes"
  ubrun s7 "completed" "cluster.$C" "workload=$WL=$LITOLD" "refuse.create" ; ubcheck s7 1 "the Backup was refused" none "a refused create"
  ubrun s8 "completed" "cluster.$C" "workload=$WL=$LITOLD" "fail.cluster" ; ubcheck s8 1 "cannot read Cluster" none "an API that cannot be asked about the Cluster"
  ubrun s9 "completed" "cluster.$C" "workload=$WL=$LITOLD" "fail.workload" ; ubcheck s9 1 "cannot read Deployment" none "an API that cannot be asked about the workload"
  ubrun s10 "completed" "cluster.$C" "workload=$WL=registry.example.com/team/other-image:1" ; ubcheck s10 1 "cannot be read" none "a running image that cannot be read"
  # Open WebUI named: only the application whose version changed is backed up, and it is backed up in ITS Cluster.
  ubrun s11 "completed" "cluster.$C" "workload=$WL=$LITIMG" "cluster.$OW" "workload=$OWL=$OWOLD" ; ubcheck s11 0 "open-webui: 0.0.1 -> $OWNEW" created "a changed Open WebUI version"
  if [ -s "$tmp/ub.s11/created.json" ]; then
    python3 - "$tmp/ub.s11/created.json" "$OW" <<'PY' || bad "F7: a changed Open WebUI version did not back up Open WebUI's Cluster ($OW), the wrong Cluster was backed up"
import sys, json
b = json.load(open(sys.argv[1]))
assert b["spec"]["cluster"]["name"] == sys.argv[2], b
PY
  fi
  grep -F 'litellm: ' "$tmp/ub.s11/out" | grep -F 'no version change' >/dev/null || bad "F7: with only Open WebUI changed the output does not show LiteLLM left alone"
else
  bad "F7: the backup Job's script could not be extracted from the render"
fi
case "$MUT" in ub-*) exit "$rc" ;; esac
[ "$rc" != 0 ] || good "F7: the backup script, run against a stub kubectl, backs up only on a version change, waits for completed, and refuses on a failed Backup, a timeout, a refused create and an API it cannot read"

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

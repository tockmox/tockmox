#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Publish the product documentation from THIS CHECKOUT into the docs bucket of a
# cluster. TM-0807, TM-0805, ADR-0036.
#
#   ./tools/publish-docs.sh --context CTX [--site DIR] [--config FILE | --revision REV]
#                           [--force] [--wait SECONDS] [--url URL [--curl-arg ARG]...]
#                           [--namespace NS] [--site-name NAME] [--registry HOST]
#                           [--image REF] [--timeout SECONDS]
#   ./tools/publish-docs.sh --selftest
#
# Exit 0 published, 1 refused or failed, 2 skipped (no --site and the pinned
# documentation generator is absent; nothing was changed), 64 usage.
#
# WHY THIS EXISTS. Tockmox publishes no container image and no compiled artifact
# (ADR-0036), so the documentation cannot arrive as one. The operator builds it
# from the checkout they deploy (tools/build-docs.sh) and this script copies the
# result into the bucket that the platform chart's `docs` site serves. Design:
# product/docs-delivery-without-an-image-design-2026-09-30.md.
#
# WHAT IT DOES, in order. Every step that can refuse does so before the cluster
# is touched, except the last two.
#   1. Builds the site (or takes --site DIR, which needs no generator: a dark
#      site builds it on any connected machine and brings the directory).
#   2. Runs tools/check-docs-offline.sh and tools/check-docs-site-contents.sh on
#      the directory, and refuses an empty or index-less one.
#   3. Refuses when the checkout is not the revision the site deploys: the
#      exact tag (or the commit) must equal tockmox.revision from --config, or
#      --revision REV. --force overrides it, for a rehearsal.
#   4. Checks the writer Secret exists (by name only; it is never read here).
#   5. Creates a short-lived pod in the platform namespace from the alpine/k8s
#      image listed in images.txt (the image the chart's bootstrap Job already
#      uses, so an air-gapped site already mirrors it), copies the site in with
#      `kubectl cp`, and runs, in the pod, the same guarded `aws s3 sync
#      --delete` the chart's sync CronJob runs for an operator-supplied site.
#      The pod gets the sync Job's securityContext and labels, and the writer
#      Secret as environment variables by secretKeyRef, so nothing secret is
#      read, printed or copied to this workstation.
#   6. Writes a marker object `.tockmox-docs-version` ({ref, commit,
#      tree_sha256}) and reads it back through the bucket's web endpoint from
#      inside the pod; with --url, also through the Ingress from here.
#   7. Deletes the pod on every exit path (a trap), and says so.
#
# The two guards in the pod are the ones the CronJob has and for the same
# reasons. An index-less source is refused, because `sync --delete` of an
# incomplete directory empties the bucket. Every file is touched first, because
# `aws s3 sync` skips a same-size file that is not newer than the stored object
# and a reproducible docs build stamps every file with one fixed old time:
# without the touch, an edit that keeps a page's byte length is never published.
#
# EVERY kubectl CALL NAMES ITS CLUSTER. There is no default context and no
# wrapper function: each line carries --context "$CONTEXT", and CONTEXT is
# refused when empty. tools/check-harness-context.sh scans this file for that.
# KUBECONFIG is honoured as kubectl honours it.
#
# WHAT THIS DOES NOT PROVE. The pod spec passes the platform namespace's Pod
# Security level only as far as the sync Job's own spec does (it is a copy of
# it); the lab run recorded in the TM-0807 report is the observation. The
# marker proves what the script uploaded, not that a browser renders it. The
# tag check trusts `git` and the local tag; it is not a signature check (verify
# the tag yourself: RELEASING.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() { sed -n '4,12p' "$0" | sed 's/^# \{0,1\}//'; }

CONTEXT=""; SITE=""; CONFIG=""; REVISION=""; FORCE=false; WAIT=0; URL=""
NS="tockmox-platform"; SITE_NAME="docs"; REGISTRY=""; IMAGE=""; TIMEOUT=180
SELFTEST=false
CURL_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --context)   CONTEXT="${2:?--context needs a name}"; shift 2 ;;
    --site)      SITE="${2:?--site needs a directory}"; shift 2 ;;
    --config)    CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --revision)  REVISION="${2:?--revision needs a tag or commit}"; shift 2 ;;
    --force)     FORCE=true; shift ;;
    --wait)      WAIT="${2:?--wait needs seconds}"; shift 2 ;;
    --url)       URL="${2:?--url needs a base URL}"; shift 2 ;;
    --curl-arg)  CURL_ARGS+=("${2:?--curl-arg needs an argument}"); shift 2 ;;
    --namespace) NS="${2:?--namespace needs a name}"; shift 2 ;;
    --site-name) SITE_NAME="${2:?--site-name needs a name}"; shift 2 ;;
    --registry)  REGISTRY="${2:?--registry needs a host}"; shift 2 ;;
    --image)     IMAGE="${2:?--image needs a reference}"; shift 2 ;;
    --timeout)   TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --selftest)  SELFTEST=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "publish-docs: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1
  else shasum -a 256 < "$1" | cut -d' ' -f1; fi
}
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}
tree_sha256() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(sha256_file "$f")" "$f"
    done ) | sha256_stdin
}
# tockmox.revision from an installer config: `tockmox:` at the top level, then
# `  revision: VALUE`. Line-oriented on purpose, like the installer's own reader.
config_revision() {
  awk '
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    /^tockmox:[ \t]*$/ { inblk=1; next }
    /^[^ \t]/ { inblk=0 }
    inblk && /^[ \t]+revision:/ {
      v=$0; sub(/^[ \t]+revision:[ \t]*/,"",v); sub(/[ \t]+#.*$/,"",v)
      gsub(/^"|"$/,"",v); gsub(/^'"'"'|'"'"'$/,"",v); print v; exit
    }' "$1"
}
safe_json_str() { printf '%s' "$1" | tr -c 'A-Za-z0-9._/+:-' '_'; }

# The pod script. Quoted heredoc: nothing in it is expanded here. It runs in the
# pod with BUCKET, ENDPOINT, INDEX, MARKER and the AWS_* variables in its
# environment.
POD_SCRIPT=$(cat <<'POD'
set -euo pipefail
say() { echo "[$(date -u +%H:%M:%S)] $*"; }
printf '[default]\ns3 =\n  addressing_style = path\n' > "$AWS_CONFIG_FILE"
[ -f "/work/$INDEX" ] || { say "FATAL: /work/$INDEX is missing. Refusing to sync: --delete of an incomplete source would empty the site."; exit 1; }
printf '%s\n' "$MARKER" > /work/.tockmox-docs-version
find /work -type f -exec touch {} +
i=0
until aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 30 ] && { say "FATAL: the bucket $BUCKET does not answer with this key after 2 minutes (is the object store up, and was the key granted?)"; exit 1; }
  sleep 4
done
say "syncing $(find /work -type f | wc -l | tr -d ' ') file(s) to s3://$BUCKET with --delete"
aws s3 sync /work "s3://$BUCKET" --delete --only-show-errors --endpoint-url "$ENDPOINT"
WEB="${ENDPOINT%:3900}:3902"
got=$(curl -fsS --max-time 15 -H "Host: $BUCKET" "$WEB/.tockmox-docs-version") || { say "FATAL: the web endpoint does not serve the marker"; exit 1; }
[ "$got" = "$MARKER" ] || { say "FATAL: the marker served is not the marker uploaded"; exit 1; }
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $BUCKET" "$WEB/")
[ "$c" = 200 ] || { say "FATAL: / answers $c, want 200"; exit 1; }
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $BUCKET" "$WEB/tockmox-publish-probe-404")
[ "$c" = 404 ] || { say "FATAL: a missing page answers $c, want 404"; exit 1; }
say "DONE. $BUCKET serves the marker; / is 200 and a missing page is 404 through the web endpoint"
POD
)

if $SELFTEST; then
  exec bash "$ROOT/tools/lib/publish-docs-selftest.sh" "$ROOT"
fi

[ -n "$CONTEXT" ] || { echo "publish-docs: --context is required. There is no default: a bare kubectl targets whatever cluster this shell happens to point at." >&2; usage >&2; exit 64; }
: "${CONTEXT:?--context is required}"
command -v kubectl >/dev/null 2>&1 || { echo "publish-docs: kubectl not found" >&2; exit 1; }
case "$WAIT$TIMEOUT" in *[!0-9]*) echo "publish-docs: --wait and --timeout take whole seconds" >&2; exit 64 ;; esac
[ -z "$CONFIG" ] || [ -f "$CONFIG" ] || { echo "publish-docs: $CONFIG is not a file" >&2; exit 64; }
if [ -n "$CONFIG" ] && [ -z "$REVISION" ]; then REVISION="$(config_revision "$CONFIG")"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-publish-docs.XXXXXX")"
POD=""
cleanup() {
  rc=$?
  if [ -n "$POD" ]; then
    kubectl --context "${CONTEXT:?}" -n "$NS" delete pod "$POD" --ignore-not-found --grace-period=5 --wait=true --timeout=90s >/dev/null 2>&1 || true
    left="$(kubectl --context "${CONTEXT:?}" -n "$NS" get pod "$POD" --ignore-not-found -o name 2>/dev/null || true)"
    if [ -z "$left" ]; then echo "pod $POD removed"; else echo "WARNING: pod $POD is still there; delete it: kubectl --context $CONTEXT -n $NS delete pod $POD" >&2; fi
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

# ---- 1. the site ------------------------------------------------------------
if [ -z "$SITE" ]; then
  SITE="$TMP/site"
  rc=0
  bash tools/build-docs.sh "$SITE" >"$TMP/build.out" 2>"$TMP/build.err" || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "SKIPPED: the pinned documentation generator is not installed, so nothing was built or published:"
    sed 's/^/  /' "$TMP/build.err"
    echo "  Build it where you can, then publish the directory:"
    echo "    python3 -m venv .venv-docs && . .venv-docs/bin/activate && pip install -r docs-site/requirements.txt"
    echo "    ./tools/publish-docs.sh --context $CONTEXT"
    echo "  or, for a directory built elsewhere:  ./tools/publish-docs.sh --context $CONTEXT --site DIR"
    exit 2
  elif [ "$rc" -ne 0 ]; then
    echo "publish-docs: the docs build failed (exit $rc):" >&2; sed 's/^/  /' "$TMP/build.err" >&2; exit 1
  fi
  tail -n 1 "$TMP/build.out"
fi
[ -d "$SITE" ] || { echo "publish-docs: $SITE is not a directory" >&2; exit 1; }

# ---- 2. the gates, and the index ---------------------------------------------
[ -s "$SITE/index.html" ] || { echo "publish-docs: REFUSED. $SITE/index.html is missing or empty; publishing it with --delete would empty the site." >&2; exit 1; }
bash tools/check-docs-offline.sh --site "$SITE" >"$TMP/offline.out" 2>&1 || { cat "$TMP/offline.out" >&2; echo "publish-docs: REFUSED. The site would fetch from the network (tools/check-docs-offline.sh)." >&2; exit 1; }
bash tools/check-docs-site-contents.sh --site "$SITE" >"$TMP/contents.out" 2>&1 || { cat "$TMP/contents.out" >&2; echo "publish-docs: REFUSED. The directory holds something that is not static web content (tools/check-docs-site-contents.sh)." >&2; exit 1; }
echo "gates: no external fetches, static content only ($(find "$SITE" -type f | wc -l | tr -d ' ') files)"

# ---- 3. the checkout is the revision the site deploys ------------------------
# PUBLISH_DOCS_DESCRIBE and PUBLISH_DOCS_HEAD replace the two git answers; the
# self-test uses them, nothing else should.
if [ -n "${PUBLISH_DOCS_DESCRIBE+set}" ]; then TAG="$PUBLISH_DOCS_DESCRIBE"; else TAG="$(git describe --tags --exact-match 2>/dev/null || true)"; fi
if [ -n "${PUBLISH_DOCS_HEAD+set}" ]; then HEAD_SHA="$PUBLISH_DOCS_HEAD"; else HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"; fi
DIRTY=""
if [ -z "${PUBLISH_DOCS_HEAD+set}" ] && [ -n "$HEAD_SHA" ] && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then DIRTY="-dirty"; fi
if [ -n "$REVISION" ]; then
  match=false
  [ -n "$TAG" ] && [ "$REVISION" = "$TAG" ] && match=true
  if [ -n "$HEAD_SHA" ] && [ "${#REVISION}" -ge 7 ]; then
    case "$HEAD_SHA" in "$REVISION"*) match=true ;; esac
  fi
  if $match; then
    echo "revision: this checkout is $REVISION${DIRTY:+ (with uncommitted changes)}"
  elif $FORCE; then
    echo "revision: WARNING. this checkout is ${TAG:-no exact tag}${HEAD_SHA:+ at ${HEAD_SHA%"${HEAD_SHA#???????}"}}, the site deploys $REVISION. Continuing because of --force." >&2
  else
    echo "publish-docs: REFUSED. The site deploys tockmox.revision '$REVISION' but this checkout is ${TAG:-not on an exact tag}${HEAD_SHA:+ (HEAD ${HEAD_SHA%"${HEAD_SHA#???????}"})}." >&2
    echo "  Check out that revision first (git checkout $REVISION), or pass --force to publish these docs anyway." >&2
    exit 1
  fi
else
  echo "revision: no --config or --revision given, so the checkout is not compared with the site's tockmox.revision"
fi
M_REF="$(safe_json_str "${TAG:-untagged}")"
M_COMMIT="$(safe_json_str "${HEAD_SHA:-unknown}${DIRTY}")"
M_TREE="$(tree_sha256 "$SITE")"
MARKER="{\"ref\":\"$M_REF\",\"commit\":\"$M_COMMIT\",\"tree_sha256\":\"$M_TREE\"}"

# ---- 4. the writer Secret exists (by name; its data is never read) -----------
SECRET="tockmox-garage-site-$SITE_NAME"
waited=0
until kubectl --context "$CONTEXT" -n "$NS" get secret "$SECRET" -o name >/dev/null 2>&1; do
  if [ "$waited" -ge "$WAIT" ]; then
    echo "publish-docs: Secret $SECRET not found in namespace $NS of context $CONTEXT." >&2
    echo "  The platform layer creates it when its Garage bootstrap Job has run. Is tockmox-platform Synced and Healthy, is apps.docs on, and is $NS the right namespace? (--wait SECONDS keeps trying.)" >&2
    exit 1
  fi
  sleep 5; waited=$((waited + 5))
done

# ---- 5. the pod --------------------------------------------------------------
if [ -z "$IMAGE" ]; then
  IMAGE="$(grep -E '^alpine/k8s:' images.txt | head -n 1 || true)"
  [ -n "$IMAGE" ] || { echo "publish-docs: no alpine/k8s image in images.txt; pass --image" >&2; exit 1; }
  [ -z "$REGISTRY" ] || IMAGE="${REGISTRY%/}/$IMAGE"
fi
POD="tockmox-publish-docs-$(date -u +%H%M%S)-$$"
DEADLINE=1800
cat > "$TMP/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  labels:
    app.kubernetes.io/name: tockmox-publish-docs
    app.kubernetes.io/part-of: tockmox
    tockmox.com/managed-by: tockmox
    tockmox.com/layer: platform
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  activeDeadlineSeconds: $DEADLINE
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: publish
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: ["sleep", "$DEADLINE"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources:
        requests: { cpu: 50m, memory: 128Mi }
        limits:   { memory: 256Mi }
      env:
        - { name: HOME, value: /tmp }
        - { name: AWS_CONFIG_FILE, value: /tmp/aws-config }
        - { name: INDEX, value: index.html }
        - { name: MARKER, value: '$MARKER' }
        - { name: AWS_REQUEST_CHECKSUM_CALCULATION, value: when_required }
        - { name: AWS_RESPONSE_CHECKSUM_VALIDATION, value: when_required }
        - { name: BUCKET, valueFrom: { secretKeyRef: { name: $SECRET, key: BUCKET } } }
        - { name: ENDPOINT, valueFrom: { secretKeyRef: { name: $SECRET, key: ENDPOINT } } }
        - { name: AWS_DEFAULT_REGION, valueFrom: { secretKeyRef: { name: $SECRET, key: REGION } } }
        - { name: AWS_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: $SECRET, key: ACCESS_KEY_ID } } }
        - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: $SECRET, key: ACCESS_SECRET_KEY } } }
      volumeMounts:
        - { name: work, mountPath: /work }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: work
      emptyDir: {}
    - name: tmp
      emptyDir: {}
YAML
echo "creating pod $POD in $NS ($IMAGE)"
# POD is set before the create on purpose: a create that half-succeeds is still
# cleaned up by the trap.
kubectl --context "$CONTEXT" -n "$NS" create -f "$TMP/pod.yaml" >/dev/null
kubectl --context "$CONTEXT" -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout="${TIMEOUT}s" >/dev/null || {
  echo "publish-docs: the pod did not become Ready in ${TIMEOUT}s. Its state:" >&2
  kubectl --context "$CONTEXT" -n "$NS" get pod "$POD" -o wide >&2 || true
  exit 1
}
kubectl --context "$CONTEXT" -n "$NS" cp "$SITE/." "$NS/$POD:/work" -c publish >/dev/null
kubectl --context "$CONTEXT" -n "$NS" exec "$POD" -c publish -- bash -c "$POD_SCRIPT"

# ---- 6. through the Ingress, from here, when asked ---------------------------
if [ -n "$URL" ]; then
  command -v curl >/dev/null 2>&1 || { echo "publish-docs: --url needs curl" >&2; exit 1; }
  base="${URL%/}"
  got="$(curl -fsS --max-time 20 ${CURL_ARGS[@]+"${CURL_ARGS[@]}"} "$base/.tockmox-docs-version")" || { echo "publish-docs: $base did not serve the marker" >&2; exit 1; }
  [ "$got" = "$MARKER" ] || { echo "publish-docs: $base serves a different marker than was uploaded" >&2; exit 1; }
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 ${CURL_ARGS[@]+"${CURL_ARGS[@]}"} "$base/")"
  [ "$c" = 200 ] || { echo "publish-docs: $base/ answers $c, want 200" >&2; exit 1; }
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 ${CURL_ARGS[@]+"${CURL_ARGS[@]}"} "$base/tockmox-publish-probe-404")"
  [ "$c" = 404 ] || { echo "publish-docs: a missing page at $base answers $c, want 404" >&2; exit 1; }
  echo "ingress: $base serves the marker, / is 200, a missing page is 404"
fi
echo "published: $MARKER"

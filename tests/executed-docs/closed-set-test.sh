#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for lib/closed-set.sh, the air-gap lane's image list. No network: helm and curl are stand-ins on PATH
# that record what they were asked and answer from fixtures, and the tree is a fixture except in case 7. One PASS or
# FAIL line per case; exit 1 on any FAIL.
#
#   1. the list carries every section (images.txt, k3s's own, Argo CD with its redis, sealed-secrets, the harness's
#      two), a short name counts as Docker Hub's, and an image two sections name is printed once
#   2. the two charts are rendered at the pinned versions, never "newest": no search, no repo add, no show
#   3. an override of either version is what is asked, and a version that is not X.Y.Z is refused before any render
#   4. k3s-images.txt is read for the K3S_VERSION fresh-install.md pins, with its + encoded
#   5. a failed read or render, an empty section and a missing K3S_VERSION each stop the run with nothing printed
#   6. an image from a registry the harness does not mirror stops the run and is named
#   7. with no --tree, the tree is the one the script sits in
#
# What it does not show: that the pinned charts still render the images named here (the fixtures stand in for
# them), or that a guest pulls nothing outside the list. The lane's mirror-proof and edge counter are that proof.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CS="${HERE}/lib/closed-set.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/cs-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS+1)); }

mkdir -p "$W/bin" "$W/tree/docs/deployment" "$W/tree/tests/executed-docs/provision"
cat > "$W/bin/helm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CS_W/helm.log"
[ -f "$CS_W/helm-fail" ] && { echo "Error: stand-in render failure" >&2; exit 1; }
case "$*" in
  "template argocd "*)
    cat <<'Y'
        image: quay.io/argoproj/argocd:v3.6.1
          image: quay.io/argoproj/argocd:v3.6.1
        image: ghcr.io/dexidp/dex:v2.46.1
        image: ecr-public.aws.com/docker/library/redis:8.6.4-alpine
Y
    [ -f "$CS_W/argocd-extra" ] && cat "$CS_W/argocd-extra"
    exit 0 ;;
  "template sealed-secrets "*)
    [ -f "$CS_W/ss-empty" ] && { echo "kind: Service"; exit 0; }
    echo '          image: "docker.io/bitnami/sealed-secrets-controller:0.41.2"'
    exit 0 ;;
esac
echo "stand-in helm: not expected: $*" >&2; exit 9
STUB
cat > "$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CS_W/curl.log"
[ -f "$CS_W/curl-fail" ] && { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
printf '%s\n' docker.io/rancher/mirrored-pause:3.10.2 docker.io/rancher/mirrored-coredns-coredns:1.14.6 \
  rancher/klipper-lb:v0.4.17
STUB
chmod +x "$W/bin/helm" "$W/bin/curl"
printf '# the product\nquay.io/prometheus/prometheus:v3.0.0\npython:3.14-slim\n\ncode.forgejo.org/forgejo/forgejo:15.0.11-rootless\n' \
  > "$W/tree/images.txt"
FI_GOOD='export K3S_VERSION=v1.36.4+k3s1'
fi_good() { printf 'intro\n%s\n%s\n%s\n' '```bash' "$FI_GOOD" '```' > "$W/tree/docs/deployment/fresh-install.md"; }
fi_good
# shellcheck disable=SC2016  # the fixture holds a literal ${...}, as the real file does
printf 'IMAGE="${TOCKMOX_GIT_IMAGE:-alpine:3.20}"\nkubectl run probe --image=alpine/git:latest --command -- true\nkubectl run x --image=docker.io/rancher/mirrored-pause:3.10.2 -- y\n' \
  > "$W/tree/tests/executed-docs/provision/site-repo-server.sh"

export CS_W="$W"
run() {  # run [args...]: OUT, ERR, RC; the logs start empty
  : > "$W/helm.log"; : > "$W/curl.log"
  OUT="$(PATH="$W/bin:$PATH" bash "$CS" "$@" 2>"$W/err")"; RC=$?; ERR="$(cat "$W/err")"
}
has() { printf '%s\n' "$OUT" | grep -xF -- "$1" >/dev/null; }
count() { printf '%s\n' "$OUT" | grep -cxF -- "$1"; }

# ---- 1 ----
run --tree "$W/tree"
if [ "$RC" = 0 ] && has quay.io/prometheus/prometheus:v3.0.0 && has python:3.14-slim \
   && has docker.io/rancher/mirrored-coredns-coredns:1.14.6 && has rancher/klipper-lb:v0.4.17 \
   && has quay.io/argoproj/argocd:v3.6.1 && has ghcr.io/dexidp/dex:v2.46.1 \
   && has ecr-public.aws.com/docker/library/redis:8.6.4-alpine \
   && has docker.io/bitnami/sealed-secrets-controller:0.41.2 && has alpine:3.20 && has alpine/git:latest; then
  pass "1: every section is in the list, Argo CD's redis and the short names included"
else fail "1: rc=$RC err=$ERR out=$(printf '%s' "$OUT" | tr '\n' ' ')"; fi
if [ "$RC" = 0 ] && [ "$(count quay.io/argoproj/argocd:v3.6.1)" = 1 ] && [ "$(count docker.io/rancher/mirrored-pause:3.10.2)" = 1 ]; then
  pass "1: an image named twice (in one render, or in two sections) is printed once"
else fail "1: duplicates: argocd=$(count quay.io/argoproj/argocd:v3.6.1) pause=$(count docker.io/rancher/mirrored-pause:3.10.2)"; fi
for h in '# images.txt' '# k3s v1.36.4+k3s1: k3s-images.txt' '# Argo CD chart 10.17.1, rendered with fresh-install.md'"'"'s values' \
         '# sealed-secrets chart 2.22.0'; do
  has "$h" || missing="${missing:-}[$h]"
done
if [ -z "${missing:-}" ]; then pass "1: each section names where it came from and at which version"
else fail "1: section header(s) missing: ${missing}"; fi

# ---- 2 ----
if grep -q -- '^template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.17.1 ' "$W/helm.log" \
   && grep -q -- '^template sealed-secrets oci://registry-1.docker.io/bitnamicharts/sealed-secrets --version 2.22.0 ' "$W/helm.log" \
   && [ "$(wc -l < "$W/helm.log")" = 2 ]; then
  pass "2: both charts are rendered at the pinned versions, and nothing else is asked of helm"
else fail "2: helm was asked: $(tr '\n' '|' < "$W/helm.log")"; fi

# ---- 3 ----
TOCKMOX_ARGOCD_CHART_VERSION=9.9.9 TOCKMOX_SEALED_SECRETS_CHART_VERSION=1.2.3 run --tree "$W/tree"
if [ "$RC" = 0 ] && grep -q -- 'argo-cd .*--version 9.9.9 ' "$W/helm.log" && grep -q -- 'sealed-secrets --version 1.2.3 ' "$W/helm.log"; then
  pass "3: an override of either version is the version rendered"
else fail "3: override: rc=$RC helm=$(tr '\n' '|' < "$W/helm.log")"; fi
TOCKMOX_ARGOCD_CHART_VERSION=latest run --tree "$W/tree"
if [ "$RC" = 2 ] && [ -z "$OUT" ] && [ ! -s "$W/helm.log" ]; then pass "3: a version that is not X.Y.Z is refused before any render"
else fail "3: 'latest': rc=$RC helm=$(tr '\n' '|' < "$W/helm.log") out=$OUT"; fi

# ---- 4 ----
run --tree "$W/tree"
if grep -qF 'https://github.com/k3s-io/k3s/releases/download/v1.36.4%2Bk3s1/k3s-images.txt' "$W/curl.log"; then
  pass "4: k3s-images.txt is read for fresh-install.md's K3S_VERSION, with + encoded"
else fail "4: curl was asked: $(tr '\n' '|' < "$W/curl.log")"; fi

# ---- 5 ----
stops() {  # stops NAME WHY : the last run stopped with nothing on stdout, saying WHY
  if [ "$RC" = 1 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep "STOP: $2" >/dev/null; then pass "5: $1 stops the run with nothing printed"
  else fail "5: $1: rc=$RC err=$ERR out=$(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"; fi
}
: > "$W/curl-fail"; run --tree "$W/tree"; rm -f "$W/curl-fail"; stops "a failed read of k3s-images.txt" "could not read k3s-images.txt"
: > "$W/helm-fail"; run --tree "$W/tree"; rm -f "$W/helm-fail"; stops "a failed render" "could not render argo-cd"
: > "$W/ss-empty"; run --tree "$W/tree"; rm -f "$W/ss-empty"; stops "a render with no image in it" "section 4 came back empty"
printf 'no pin here\n' > "$W/tree/docs/deployment/fresh-install.md"; run --tree "$W/tree"
fi_good; stops "a fresh-install.md with no K3S_VERSION" "no K3S_VERSION"

# ---- 6 ----
echo '        image: mcr.microsoft.com/oss/kubernetes/pause:3.9' > "$W/argocd-extra"; run --tree "$W/tree"; rm -f "$W/argocd-extra"
if [ "$RC" = 1 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep 'does not mirror.*mcr.microsoft.com/oss/kubernetes/pause:3.9' >/dev/null; then
  pass "6: an image from an unmirrored registry stops the run and is named"
else fail "6: unmirrored: rc=$RC err=$ERR"; fi

# ---- 7 ----
run
first="$(grep -vE '^#|^$' "${HERE}/../../images.txt" | head -1)"
if [ "$RC" = 0 ] && [ -n "$first" ] && has "$first"; then pass "7: with no --tree, the list starts from this tree's images.txt"
else fail "7: default tree: rc=$RC err=$ERR first=$first"; fi

[ "$FAILS" -eq 0 ]

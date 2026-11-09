#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# closed-set.sh: the closed image set an air-gapped run needs in its mirror, one image per line, for
# tools/mirror-images.sh --images.
#
#   closed-set.sh [--tree DIR] > closed-set.txt
#
# WHY MORE THAN images.txt. In nofallback mode (provision/profiles/registry-mirror.sh) the guest is mirror-only from
# the moment it boots, so every image it pulls before the product has to be in the mirror too:
#   - k3s's own system images, from the k3s release's k3s-images.txt for the K3S_VERSION fresh-install.md pins;
#   - Argo CD and sealed-secrets (fresh-install.md sections 6 and 7), rendered at the chart versions below;
#   - the harness's git server and its clone probe (provision/site-repo-server.sh).
# images.txt is the product's set and comes first.
#
# PINNED, NOT NEWEST. fresh-install.md picks the newest Argo CD and sealed-secrets charts on the day a reader runs it.
# A release gate whose input moves under it is not repeatable, so the lane renders the versions pinned here, and a
# bump is a reviewed change. Override for one run with TOCKMOX_ARGOCD_CHART_VERSION and
# TOCKMOX_SEALED_SECRETS_CHART_VERSION.
#
# EVERY IMAGE COMES FROM A MIRRORED REGISTRY, OR THE LIST IS REFUSED. An image from a registry that is not in
# MIRROR_UPSTREAMS would be pulled directly, which on a real air gap is a failed pull and on the lab is a miss the
# counter catches late. So the script stops and names it instead of printing a list that cannot be served.
# Argo CD's redis is why ecr-public.aws.com is one of the six.
#
# Needs helm and curl, and the network: it renders two charts and reads one file from the k3s release. Run it on the
# connected side. Exit 0 with the list on stdout; 2 refused input; 1 anything it could not read or render.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "${HERE}/../../.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE="${2:?--tree needs a directory}"; shift 2 ;;
    *) echo "closed-set: unknown argument: $1" >&2; exit 2 ;;
  esac
done

ARGOCD_CHART_VERSION="${TOCKMOX_ARGOCD_CHART_VERSION:-10.17.1}"
SEALED_SECRETS_CHART_VERSION="${TOCKMOX_SEALED_SECRETS_CHART_VERSION:-2.22.0}"
ARGOCD_REPO="https://argoproj.github.io/argo-helm"
SEALED_SECRETS_CHART="oci://registry-1.docker.io/bitnamicharts/sealed-secrets"
for v in "$ARGOCD_CHART_VERSION" "$SEALED_SECRETS_CHART_VERSION"; do
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "closed-set: a chart version is X.Y.Z, not '$v'" >&2; exit 2; }
done

# shellcheck source=/dev/null  # registry-mirror.sh, beside this directory
. "${HERE}/../provision/profiles/registry-mirror.sh"

FI="$TREE/docs/deployment/fresh-install.md"
SRS="$TREE/tests/executed-docs/provision/site-repo-server.sh"
for f in "$TREE/images.txt" "$FI" "$SRS"; do
  [ -r "$f" ] || { echo "closed-set: STOP: cannot read $f" >&2; exit 1; }
done
K3S="$(sed -n 's/^export K3S_VERSION=\(v[0-9][^[:space:]]*\)[[:space:]]*$/\1/p' "$FI" | head -1)"
[ -n "$K3S" ] || { echo "closed-set: STOP: no K3S_VERSION in $FI" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/closed-set.XXXXXX")"; trap 'rm -rf "$W"' EXIT
images() { sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' | sort -u; }
# Each section is written to its own file first, so a failure in any of them stops the run before anything prints.
grep -vE '^#|^$' "$TREE/images.txt" > "$W/1"
curl -fsSL "https://github.com/k3s-io/k3s/releases/download/${K3S//+/%2B}/k3s-images.txt" | grep -vE '^#|^$' > "$W/2" \
  || { echo "closed-set: STOP: could not read k3s-images.txt for ${K3S}" >&2; exit 1; }
# The values are fresh-install.md section 6's: the metrics flags add no image, but the render is the page's render.
# ctx-exempt-begin: helm template renders on this machine and reaches no cluster
helm template argocd argo-cd --repo "$ARGOCD_REPO" --version "$ARGOCD_CHART_VERSION" --namespace argocd \
  --set controller.metrics.enabled=true --set server.metrics.enabled=true --set repoServer.metrics.enabled=true \
  > "$W/argocd.yaml" || { echo "closed-set: STOP: could not render argo-cd ${ARGOCD_CHART_VERSION}" >&2; exit 1; }
images < "$W/argocd.yaml" > "$W/3"
helm template sealed-secrets "$SEALED_SECRETS_CHART" --version "$SEALED_SECRETS_CHART_VERSION" --namespace kube-system \
  > "$W/ss.yaml" || { echo "closed-set: STOP: could not render sealed-secrets ${SEALED_SECRETS_CHART_VERSION}" >&2; exit 1; }
# ctx-exempt-end
images < "$W/ss.yaml" > "$W/4"
# shellcheck disable=SC2016  # the pattern matches a literal ${...} in the file
{ sed -n 's/^IMAGE="\${TOCKMOX_GIT_IMAGE:-\([^}]*\)}"$/\1/p' "$SRS"
  grep -o -- '--image=[^ ]*' "$SRS" | sed 's/--image=//' | sort -u; } > "$W/5"
for s in 1 2 3 4 5; do
  [ -s "$W/$s" ] || { echo "closed-set: STOP: section $s came back empty (see the comment above each in this script)" >&2; exit 1; }
done

# registry_of IMAGE : the registry an image is pulled from; a first element with no dot, colon or localhost is
# Docker Hub's, which is how containerd reads a short name.
registry_of() {
  local first="${1%%/*}"
  case "$1" in */*) ;; *) echo docker.io; return ;; esac
  case "$first" in *.*|*:*|localhost) echo "$first" ;; *) echo docker.io ;; esac
}
bad=""
for s in 1 2 3 4 5; do
  while IFS= read -r img; do
    r="$(registry_of "$img")"
    case " $MIRROR_UPSTREAMS " in *" $r "*) ;; *) bad="${bad} ${img}" ;; esac
  done < "$W/$s"
done
if [ -n "$bad" ]; then
  echo "closed-set: STOP: from a registry the harness does not mirror (MIRROR_UPSTREAMS: ${MIRROR_UPSTREAMS}):${bad}" >&2
  exit 1
fi

# An image two sections name (a chart and images.txt can share one) is printed once, in the first section that has it.
: > "$W/seen"
emit() { local l; while IFS= read -r l; do grep -qxF -- "$l" "$W/seen" || { echo "$l"; echo "$l" >> "$W/seen"; }; done < "$1"; }
echo "# closed set, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# images.txt"
emit "$W/1"
echo "# k3s ${K3S}: k3s-images.txt"
emit "$W/2"
echo "# Argo CD chart ${ARGOCD_CHART_VERSION}, rendered with fresh-install.md's values"
emit "$W/3"
echo "# sealed-secrets chart ${SEALED_SECRETS_CHART_VERSION}"
emit "$W/4"
echo "# the harness's git server and its clone probe (provision/site-repo-server.sh)"
emit "$W/5"

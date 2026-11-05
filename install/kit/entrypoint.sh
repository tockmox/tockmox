#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The install kit's entrypoint. It sets up paths and trust, then hands every argument to
# install/tockmox-install.sh unchanged, so the kit and a native clone run one program.
#
# Two verbs belong to the kit itself and no other:
#
#   kit-check   every tool the installer needs is present, and the pinned ones are at their pins
#   shell       a bash shell inside the kit, for the commands the install pages give you
#
# Anything this file grows beyond paths, trust and those two verbs is a second installer. Put it in the
# installer instead, where the native route gets it too.
set -euo pipefail

# The three TOCKMOX_KIT_* paths are for tests/installer; the image never sets them.
ROOT="${TOCKMOX_KIT_ROOT:-/opt/tockmox}"
mkdir -p "${HOME:-/tmp/home}"

# A CA you mounted at /kit/ca.pem (the launcher's --ca-file): your proxy's, or the private CA your
# forge or registry is served with. Added to the system bundle for every tool, never replacing it.
KIT_CA="${TOCKMOX_KIT_CA:-/kit/ca.pem}"; SYS_BUNDLE="${TOCKMOX_KIT_SYS_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
if [[ -s "$KIT_CA" ]]; then
  cat "$SYS_BUNDLE" "$KIT_CA" > "${TMPDIR:-/tmp}/kit-ca-bundle.pem"
  export SSL_CERT_FILE="${TMPDIR:-/tmp}/kit-ca-bundle.pem"
  export CURL_CA_BUNDLE="$SSL_CERT_FILE" GIT_SSL_CAINFO="$SSL_CERT_FILE" REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
fi

# No kubeconfig mounted: say nothing here and let kubectl report it where a step needs one.
[[ -e "${KUBECONFIG:-/kube/config}" ]] || unset KUBECONFIG

kit_check() {
  local fail=0 t have
  # Presence first, with command -v: a version pipeline passes when the tool is missing.
  for t in bash git curl openssl python3 age tar awk sed grep diff find kubectl helm kubeseal; do
    if command -v "$t" >/dev/null 2>&1; then printf '  ok    %-9s %s\n' "$t" "$(command -v "$t")"
    else printf '  FAIL  %-9s not in the kit\n' "$t"; fail=1; fi
  done
  # The GNU tools, not BusyBox's: forge-restore.sh parses diff's normal output, which BusyBox's diff
  # does not print, so a BusyBox tool here is a silent behaviour change rather than a missing one.
  for t in tar awk sed grep diff find; do
    command -v "$t" >/dev/null 2>&1 || continue
    have="$("$t" --version 2>&1 | head -n 1 || true)"
    case "$have" in *GNU*) ;; *) echo "  FAIL  $t is not the GNU one"; fail=1 ;; esac
  done
  have="$(helm version --short 2>/dev/null | sed -n 's/^\(v[0-9][0-9.]*\).*/\1/p')"
  if [[ "$have" == "$TOCKMOX_KIT_HELM" ]]; then echo "  ok    helm $have"; else echo "  FAIL  helm ${have:-?}, pinned $TOCKMOX_KIT_HELM"; fail=1; fi
  have="$(kubectl version --client 2>/dev/null | sed -n 's/^Client Version: \(v[0-9][0-9.]*\).*/\1/p')"
  if [[ "$have" == "$TOCKMOX_KIT_KUBECTL" ]]; then echo "  ok    kubectl $have"; else echo "  FAIL  kubectl ${have:-?}, pinned $TOCKMOX_KIT_KUBECTL"; fail=1; fi
  have="$(kubeseal --version 2>/dev/null | sed -n 's/^kubeseal version: v\{0,1\}\([0-9][0-9.]*\).*/\1/p')"
  if [[ "$have" == "$TOCKMOX_KIT_KUBESEAL" ]]; then echo "  ok    kubeseal $have"; else echo "  FAIL  kubeseal ${have:-?}, pinned $TOCKMOX_KIT_KUBESEAL"; fail=1; fi
  have="$(bash -c 'echo "${BASH_VERSINFO[0]}"')"
  if [[ "$have" -ge 4 ]]; then echo "  ok    bash $BASH_VERSION"; else echo "  FAIL  bash $BASH_VERSION, 4 or newer needed"; fail=1; fi
  echo "  info  installer $(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/install/tockmox-install.sh"), running as uid $(id -u)"
  if [[ -n "${SSL_CERT_FILE:-}" ]]; then echo "  info  extra CA: $KIT_CA added to the trust bundle"; fi
  if [[ -n "${KUBECONFIG:-}" ]]; then echo "  info  kubeconfig: $KUBECONFIG (current context: $(kubectl config current-context 2>/dev/null || echo none))"
  else echo "  info  kubeconfig: none mounted"; fi
  return "$fail"
}

case "${1:-}" in
  kit-check) kit_check ;;
  shell) shift; cd /work 2>/dev/null || true; PATH="$ROOT/install:$ROOT/tools:$PATH" exec bash "$@" ;;
  *) exec bash "$ROOT/install/tockmox-install.sh" "$@" ;;
esac

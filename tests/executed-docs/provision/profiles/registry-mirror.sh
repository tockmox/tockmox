#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The registry-mirror pieces of the throwaway cluster, in one place that both
# provisioner lanes (the Ubuntu lane in throwaway-cluster.sh and the MicroOS
# profile) read, and that tests/executed-docs/mirror-mode-test.sh runs without a
# cluster. Sourced; defines functions and constants only.
#
# TWO MODES. TOCKMOX_REGISTRY_MODE:
#
#   cache       (default) The mirror is tried first and the upstream is the
#               fallback. That supports "pulls are cached" and nothing more: a
#               run that is missing an image from the mirror looks identical to a
#               run whose image set is closed, because the fallback repairs the
#               miss with exactly the thing an air gap forbids (it was written
#               this way on purpose, to survive a mirror outage).
#
#   nofallback  The mirror is the ONLY registry. Three things, each closing a
#               different way a miss could be repaired quietly:
#                 1. registries.yaml names the mirror and no upstream endpoint;
#                 2. k3s starts with `disable-default-registry-endpoint: true`,
#                    because containerd appends each registry's own endpoint as a
#                    last resort even when registries.yaml leaves it out;
#                 3. the upstream registries' front-door names resolve to an
#                    unroutable documentation address (RFC 5737, 192.0.2.1) and
#                    the host rejects, and COUNTS, every connection attempt to
#                    it. A miss then fails loudly, and the counter is the
#                    measurement behind "zero upstream connections".
#
# WHERE THE COUNTER LIVES. TOCKMOX_UPSTREAM_DENY, in nofallback mode only:
#
#   node   (default) layer 3 above: the NODE rejects and counts. The attempt never
#          leaves the guest, so an edge firewall that logs denies sees nothing.
#   edge   layer 3 is not installed: registries.yaml and the k3s drop-in still make
#          the mirror the only registry, but the upstream names resolve as they
#          would and the denying and counting is the NETWORK's job (a segment whose
#          firewall blocks and logs). Use it when that firewall is the counter, so
#          that a positive control (a request the guest makes and the firewall
#          refuses) reaches the firewall and is seen there. `mirror-proof` then
#          checks the two files only and says the counter is not on the node.

# A MIRROR WITH A PATH. TOCKMOX_REGISTRY_MIRROR is host[:port], or host[:port]/PREFIX
# when the images live under a path on the registry (a Harbor project, which is
# what tools/mirror-images.sh --registry HOST/PREFIX fills). containerd asks the
# endpoint for the repository path alone, so a prefix needs a `rewrite` on every
# mirror, the block docs/deployment/airgap.md tells a disconnected site to write:
# without it the pulls reach the registry and ask for repositories that are not
# there. With no prefix the file is what it always was.

# WHAT THIS CAN AND CANNOT SHOW. The counter sees attempts to the front-door
# names (docker.io, registry-1.docker.io, auth.docker.io, the CDN hosts the
# registries redirect blobs to, quay.io, ghcr.io, registry.k8s.io,
# code.forgejo.org, where the built-in forge's image lives, and
# ecr-public.aws.com, where Argo CD's redis lives; its blobs redirect to a
# CloudFront name that is not listed). A redirect to
# a host not on the list, by address or by a name nobody enumerated, is not seen;
# the mirror's own upstream (a pull-through cache fetching on its side) is the
# mirror's business and is not seen either; and it is the NODE's pulls that are
# denied (containerd resolves through the node's /etc/hosts), not a pod that
# opens its own connection to a registry. The rules are per boot: a node that
# reboots mid-run counts from zero again. `mirror-proof` reports all of this. A
# provision under this mode completing with a counter of zero is a LAB result,
# not something this file or its test proves.
#
# TWO MORE LIMITS ON A ZERO. The provisioner still downloads k3s itself (get.k3s.io
# and the k3s binary are not denied), so a zero shows the NODE's image pulls did not
# reach an upstream registry, not that the provision made no outbound connection.
# And the mirror has to be a closed set: a pull-through cache fetches from upstream
# on a miss, from its own side, which nothing here can see.

# A MIRROR BEHIND A PRIVATE CA. TOCKMOX_REGISTRY_CA is a file on the machine that runs
# the harness: the PEM certificate of the CA that signed the mirror's certificate. A
# mirror inside a boundary is normally served from the site's own CA, which no node
# trusts out of the box. containerd then fails every pull at TLS (unknown CA) and,
# with no upstream to fall back to, retries for ever while every pod sits in
# ContainerCreating: in nofallback mode that surfaced as P04 timing out, with no line
# anywhere naming the certificate. Cache mode hides it, because the fallback repairs
# each failed pull from upstream. Given a CA, both lanes write it to MIRROR_CA_PATH on
# the node before k3s first starts, and registries.yaml gains a `configs` entry for
# the mirror's host naming that file as its `tls.ca_file` (k3s's registries.yaml
# schema; the block docs/deployment/airgap.md tells a site to write). Unset, nothing
# is written and registries.yaml is what it always was: a mirror whose certificate
# the node already trusts needs nothing.
#
# THE ROUND TRIP. Before anything installs, `create` asks the node for one TLS round
# trip to https://HOST/v2/ (verified against MIRROR_CA_PATH when a CA was given, the
# node's own trust store otherwise) and stops, with curl's error, unless the
# registry answers 200 or 401. It runs whenever a CA is given and on every nofallback
# run; `throwaway-cluster.sh mirror-tls` runs it on its own. It shows the node can
# verify the mirror; that containerd pulls through it is still the provision's to show.

MIRROR_UPSTREAMS="docker.io quay.io ghcr.io registry.k8s.io code.forgejo.org ecr-public.aws.com"
MIRROR_DENY_ADDR="192.0.2.1"
MIRROR_DENY_NAMES="docker.io registry-1.docker.io index.docker.io auth.docker.io production.cloudflare.docker.com quay.io cdn.quay.io cdn01.quay.io cdn02.quay.io cdn03.quay.io ghcr.io pkg-containers.githubusercontent.com registry.k8s.io code.forgejo.org ecr-public.aws.com"
MIRROR_DENY_CHAIN="TOCKMOX_UPSTREAM_DENY"
# A drop-in, not an edit of config.yaml: the Ubuntu lane writes its own
# config.yaml and the MicroOS lane runs the documented install, which may write
# one too. k3s merges config.yaml.d/*.yaml over it, so the same file serves both.
MIRROR_K3S_DROPIN="/etc/rancher/k3s/config.yaml.d/10-tockmox-registry-nofallback.yaml"
# Where the mirror's CA lands on the node, and what registries.yaml's tls.ca_file names.
# Beside registries.yaml, the path airgap.md uses.
# shellcheck disable=SC2034  # read by throwaway-cluster.sh, microos.sh and the test
MIRROR_CA_PATH="/etc/rancher/k3s/registry-ca.crt"
# Per-boot, because the rules and the counter live in the kernel and a reboot
# empties them. cloud-init runs per-boot scripts in name order.
# shellcheck disable=SC2034  # read by throwaway-cluster.sh, microos.sh and the test
MIRROR_DENY_PERBOOT="/var/lib/cloud/scripts/per-boot/10-tockmox-upstream-deny.sh"

# mirror_host MIRROR : the host[:port] part. mirror_prefix MIRROR : the path after it, or nothing.
mirror_host() { printf '%s' "${1%%/*}"; }
mirror_prefix() { case "$1" in */*) printf '%s' "${1#*/}" ;; esac; }

# mirror_mode_check MIRROR MODE [DENY] : 0 when the combination is usable, else 2 with the reason.
# DENY is node (default) or edge; it only matters in nofallback mode.
mirror_mode_check() {
  local mirror="$1" mode="$2" deny="${3:-node}" n
  case "$deny" in
    node|edge) ;;
    *) echo "REFUSING: TOCKMOX_UPSTREAM_DENY=${deny} is not node or edge." >&2; return 2 ;;
  esac
  case "$mode" in
    cache) return 0 ;;
    nofallback)
      if [ -z "$mirror" ]; then
        echo "REFUSING: TOCKMOX_REGISTRY_MODE=nofallback needs TOCKMOX_REGISTRY_MIRROR. With no mirror every pull would" >&2
        echo "          have nowhere to go, and a run that cannot pull proves nothing about an air gap." >&2
        return 2
      fi
      case "$mirror" in
        *://*|*" "*) echo "REFUSING: TOCKMOX_REGISTRY_MIRROR is a host[:port], optionally /PREFIX, not a URL: ${mirror}" >&2; return 2 ;;
      esac
      case "$mirror" in
        */|*//*) echo "REFUSING: the prefix in TOCKMOX_REGISTRY_MIRROR has an empty path element: ${mirror}" >&2; return 2 ;;
      esac
      case "/$(mirror_prefix "$mirror")" in
        *[!a-z0-9._/-]*) echo "REFUSING: the prefix in TOCKMOX_REGISTRY_MIRROR is not a registry path (lower case, digits, . _ - /): ${mirror}" >&2; return 2 ;;
      esac
      for n in $MIRROR_DENY_NAMES; do
        if [ "$(mirror_host "$mirror")" = "$n" ]; then
          echo "REFUSING: the mirror ${mirror} is one of the upstream names nofallback denies. Name a mirror of your own." >&2
          return 2
        fi
      done
      return 0 ;;
    *)
      echo "REFUSING: TOCKMOX_REGISTRY_MODE=${mode} is not cache or nofallback." >&2
      return 2 ;;
  esac
}

# mirror_ca_check MIRROR CAFILE : 0 when CAFILE is empty, or is a readable PEM certificate
# and there is a mirror to trust it for; else 2 with the reason. The file is copied
# into the guest's cloud-init, which is readable from the substrate, so a file that
# holds a private key is refused rather than copied.
mirror_ca_check() {
  local mirror="$1" ca="${2:-}"
  [ -n "$ca" ] || return 0
  if [ -z "$mirror" ]; then
    echo "REFUSING: TOCKMOX_REGISTRY_CA is set and TOCKMOX_REGISTRY_MIRROR is not: there is no mirror to trust it for." >&2
    return 2
  fi
  if [ ! -r "$ca" ] || [ ! -s "$ca" ]; then
    echo "REFUSING: TOCKMOX_REGISTRY_CA names no readable, non-empty file: ${ca}" >&2
    return 2
  fi
  if grep -q -- 'PRIVATE KEY-----' "$ca"; then
    echo "REFUSING: TOCKMOX_REGISTRY_CA holds a private key: ${ca}. Give the CA's certificate alone; it is copied into the guest." >&2
    return 2
  fi
  if ! grep -q -- '^-----BEGIN CERTIFICATE-----' "$ca"; then
    echo "REFUSING: TOCKMOX_REGISTRY_CA is not a PEM certificate (no BEGIN CERTIFICATE line): ${ca}" >&2
    return 2
  fi
  return 0
}

# mirror_registries_yaml MIRROR MODE [CA_PATH] : the text of /etc/rancher/k3s/registries.yaml.
# CA_PATH is where the mirror's CA is on the NODE (MIRROR_CA_PATH); empty, the file is
# byte for byte what it was before CAs existed.
mirror_registries_yaml() {
  local mirror="$1" mode="$2" ca="${3:-}" up host prefix
  host="$(mirror_host "$mirror")"; prefix="$(mirror_prefix "$mirror")"
  echo "mirrors:"
  for up in $MIRROR_UPSTREAMS; do
    echo "  ${up}:"
    echo "    endpoint:"
    echo "      - \"https://${host}\""
    # The upstream is the fallback in cache mode, and absent in nofallback.
    [ "$mode" = "nofallback" ] || echo "      - \"https://${up}\""
    if [ -n "$prefix" ]; then
      echo "    rewrite:"
      echo "      \"(.*)\": \"${prefix}/\$1\""
    fi
  done
  # k3s keys `configs` by the endpoint's host[:port], not by the registry it mirrors.
  if [ -n "$ca" ]; then
    echo "configs:"
    echo "  \"${host}\":"
    echo "    tls:"
    echo "      ca_file: \"${ca}\""
  fi
}

# mirror_tls_check_script MIRROR [CA_PATH] : the guest script for THE ROUND TRIP above.
# With CA_PATH, curl trusts that file alone (--cacert), so a PASS shows the file placed
# on the node is the CA that signed the mirror's certificate; without it, the node's
# own trust store. Exits 0 and prints `mirror-tls: PASS` only on HTTP 200 or 401
# (a registry that wants a login still completed TLS); anything else is a FAIL that
# carries curl's own error.
mirror_tls_check_script() {
  local host ca="${2:-}" opt="" trust="the node's own trust store"
  host="$(mirror_host "$1")"
  if [ -n "$ca" ]; then opt="--cacert '${ca}' "; trust="${ca}"; fi
  cat <<EOF
#!/bin/sh
set -u
err=\$(mktemp)
code=\$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 ${opt}'https://${host}/v2/' 2>"\$err")
case "\$code" in
  200|401)
    echo "mirror-tls: PASS https://${host}/v2/ answered \$code over TLS verified against ${trust}"
    rm -f "\$err"; exit 0 ;;
esac
echo "mirror-tls: FAIL no TLS round trip to https://${host}/v2/ (HTTP \${code:-none}), verified against ${trust}"
sed 's/^/  /' "\$err"
rm -f "\$err"
exit 1
EOF
}

# mirror_k3s_dropin MODE : the text of $MIRROR_K3S_DROPIN (nothing in cache mode,
# where the file is not written at all).
mirror_k3s_dropin() {
  [ "$1" = "nofallback" ] || return 0
  echo "disable-default-registry-endpoint: true"
}

# mirror_deny_script : the guest script that blackholes and counts upstream
# registry traffic. Run as root, before k3s starts. Prints the script.
mirror_deny_script() {
  cat <<EOF
#!/bin/sh
# nofallback mode: the upstream registries are unreachable on purpose.
# Their names resolve to ${MIRROR_DENY_ADDR} (RFC 5737, never routed), the host rejects
# connections to it, and one rule counts every attempt. \`throwaway-cluster.sh
# mirror-proof\` reads the counter.
set -eu
for h in ${MIRROR_DENY_NAMES}; do
  grep -q " \$h\\\$" /etc/hosts 2>/dev/null || echo "${MIRROR_DENY_ADDR} \$h" >> /etc/hosts
done
iptables -N ${MIRROR_DENY_CHAIN} 2>/dev/null || true
iptables -F ${MIRROR_DENY_CHAIN}
iptables -A ${MIRROR_DENY_CHAIN} -p tcp -j REJECT --reject-with tcp-reset
iptables -A ${MIRROR_DENY_CHAIN} -j REJECT
iptables -C OUTPUT -d ${MIRROR_DENY_ADDR} -j ${MIRROR_DENY_CHAIN} 2>/dev/null || iptables -I OUTPUT 1 -d ${MIRROR_DENY_ADDR} -j ${MIRROR_DENY_CHAIN}
echo "tockmox: upstream registries denied (${MIRROR_DENY_ADDR}), attempts counted in ${MIRROR_DENY_CHAIN}"
EOF
}

# The node-counter half of mirror_proof_script, as guest shell text. A function of its own so
# that no heredoc sits inside a $( ), which bash 3.2 (macOS) parses badly.
_mirror_proof_node_counter() {
  cat <<EOF
pk=\$(iptables -nvxL ${MIRROR_DENY_CHAIN} 2>/dev/null | awk 'NR>2 {p += \$1} END {print p + 0}')
if iptables -nL ${MIRROR_DENY_CHAIN} >/dev/null 2>&1; then
  echo "  upstream attempts since boot: \$pk packet(s) rejected (0 required)"
  [ "\$pk" -eq 0 ] || rc=1
else
  echo "  FAIL the deny chain ${MIRROR_DENY_CHAIN} is absent: upstream egress was not denied on this boot"; rc=1
fi
EOF
}

# mirror_proof_script MIRROR [DENY] : the script `mirror-proof` runs on the guest. It
# reports what the guest is configured to do and what it was seen to attempt, and
# exits 0 only when the configuration is the nofallback one and (deny=node) the
# counter is 0. With deny=edge it checks the two files and says where the counter is.
mirror_proof_script() {
  local mirror="$1" deny="${2:-node}" up ups="" counter prefix rewrite="" nup=0
  prefix="$(mirror_prefix "$mirror")"
  for up in $MIRROR_UPSTREAMS; do nup=$((nup + 1)); done
  if [ -n "$prefix" ]; then
    rewrite="rw=\$(grep -cF '\"(.*)\": \"${prefix}/\$1\"' \"\$reg\" || true)
  echo \"  registries.yaml: \$rw rewrite(s) onto ${prefix}/ (${nup} required, one per registry)\"
  [ \"\$rw\" -eq ${nup} ] || { echo \"  FAIL the mirror has a prefix and not every registry rewrites onto it\"; rc=1; }"
  fi
  for up in $MIRROR_UPSTREAMS; do ups="${ups} ${up}"; done
  if [ "$deny" = "edge" ]; then
    counter='note=" (configuration only: the counter is not on this node)"
echo "  upstream attempts: not counted on this node (upstream-deny=edge); read the counter where the network denies"'
  else
    counter="$(_mirror_proof_node_counter)"
  fi
  cat <<EOF
#!/bin/sh
set -u
rc=0
note=""
echo "mirror-proof: mirror=${mirror} mode=nofallback upstream-deny=${deny}"
reg=/etc/rancher/k3s/registries.yaml
if [ -r "\$reg" ]; then
  n=\$(grep -c 'https://' "\$reg" || true)
  bad=0
  for u in${ups}; do
    if grep -q "https://\$u\\"" "\$reg"; then bad=\$((bad + 1)); echo "  FAIL registries.yaml still names the upstream https://\$u as an endpoint"; fi
  done
  echo "  registries.yaml: \$n endpoint line(s), \$bad naming an upstream"
  [ "\$bad" -eq 0 ] || rc=1
${rewrite}
else
  echo "  FAIL registries.yaml is not readable"; rc=1
fi
if grep -q '^disable-default-registry-endpoint: true' ${MIRROR_K3S_DROPIN} 2>/dev/null; then
  echo "  k3s config: disable-default-registry-endpoint is true"
else
  echo "  FAIL ${MIRROR_K3S_DROPIN} does not disable the default registry endpoint"; rc=1
fi
${counter}
if [ "\$rc" -eq 0 ]; then echo "mirror-proof: PASS\$note"; else echo "mirror-proof: FAIL"; fi
exit \$rc
EOF
}

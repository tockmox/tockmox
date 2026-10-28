#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic contract test for the registry-mirror modes. TM-0575. No cluster, no
# network, no root: kubectl, curl and sleep are stubs, iptables is a stub that
# records its arguments, and the provisioner and the MicroOS profile run
# unmodified against them (the same stub shape as handoff-secret-test.sh).
#
# WHAT IT HOLDS THE PROVISIONER TO. TOCKMOX_REGISTRY_MODE is `cache` (the
# default, unchanged: the upstream is the mirror's fallback) or `nofallback` (the
# mirror is the only registry and upstream traffic is denied and counted). Six
# clauses, each proved to go red by tests/executed-docs/selftest.sh's neighbours
# in the PR that added this file:
#
#   1. the mode check refuses an unknown mode, a nofallback run with no mirror,
#      a mirror that is itself an upstream name, and a URL where a host belongs
#   2. cache mode is byte-for-byte what the harness wrote before the modes existed
#   3. nofallback names no upstream endpoint, in either lane, and writes the k3s
#      drop-in and the per-boot deny script in both; cache writes neither
#   4. the deny script blackholes every denied name and counts, and is idempotent
#   5. the guest's `mirror-proof` is PASS only when configured AND the counter is
#      zero, and FAIL for each way either can be false
#   6. `create` refuses a bad mode before any VM is applied, and `mirror-proof`
#      refuses to read a cache-mode cluster
#
# WHAT IT DOES NOT SHOW, and no hermetic test can: that a real guest honours
# `disable-default-registry-endpoint`, that containerd resolves the denied names
# through /etc/hosts, or that a provision completes with a counter of zero. Those
# are lab clauses (runsheet: the nofallback provision), read from `mirror-proof`.
#
#   ./tests/executed-docs/mirror-mode-test.sh
#   TC=/path/to/throwaway-cluster.sh ./tests/executed-docs/mirror-mode-test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
LIB="$(dirname "$TC")/profiles/registry-mirror.sh"
PROFILE="$(dirname "$TC")/profiles/microos.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

VM=k3s-test-01
M=mirror.example.test
REAL_SLEEP="$(command -v sleep)"
REAL_PY="$(command -v python3 || true)"
BIN="${TMP}/bin"
mkdir -p "$BIN"

cat >"${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
ST="$STUB_STATE"
printf '%s\n' "$*" >>"$ST/log"
# Every invocation, verbatim, so a case can assert that each one named a cluster
# (TM-0797). `log` above also carries non-call lines the cases grep for.
printf '%s\n' "$*" >>"$ST/calls"
a=()
while [ $# -gt 0 ]; do
  case "$1" in -n|--context) shift 2 ;; --context=*) shift ;; *) a+=("$1"); shift ;; esac
done
set -- "${a[@]}"
j="$*"
forbid() { echo "Error from server (Forbidden): secrets is forbidden: User \"stub\" cannot delete resource \"secrets\"" >&2; exit 1; }
notfound() { echo "Error from server (NotFound): secrets \"$1\" not found" >&2; exit 1; }
del_one() {
  if [ -f "$ST/secrets/$1" ]; then
    [ -f "$ST/sticky" ] || rm -f "$ST/secrets/$1"
    echo "secret \"$1\" deleted"
  fi
}
case "$j" in
  "get virtualmachines.kubevirt.io -o name") exit 0 ;;
  "auth can-i"*) echo yes ;;
  *"jsonpath={.clusters[0].cluster.server}") printf 'https://api.invalid:6443' ;;
  *"jsonpath={.users[0].user.token}")
    # A JWT-shaped ServiceAccount token for tockmox-test (TM-0849 reads its
    # subject); $ST/token overrides it for the refusal cases.
    if [ -f "$ST/token" ]; then cat "$ST/token"
    else printf 'eyJhbGciOiJub25lIn0.%s.sig' "$(printf '{"sub":"system:serviceaccount:tockmox-test:tockmox-test-agent"}' | base64 | tr -d '=\n' | tr '+/' '-_')"; fi ;;
  "config view -o jsonpath={.clusters[0].name}") printf 'default' ;;
  "config current-context") printf 'default' ;;
  "config unset"*|"config set-cluster"*) exit 0 ;;
  "get virtualmachineimages.harvesterhci.io"*storageClassName*) printf 'stub-image-class' ;;
  "get virtualmachineimages.harvesterhci.io"*progress*) printf '100' ;;
  "delete secret -l "*)
    [ -f "$ST/deny-delete" ] && forbid
    for f in "$ST"/secrets/*; do [ -f "$f" ] && del_one "${f##*/}"; done; exit 0 ;;
  "delete secret "*)
    [ -f "$ST/deny-delete" ] && forbid
    shift 2
    for n in "$@"; do case "$n" in -*) ;; *) del_one "$n" ;; esac; done; exit 0 ;;
  "create secret generic "*)
    for x in "$@"; do case "$x" in --from-file=userdata=*) cp "${x#--from-file=userdata=}" "$ST/userdata"; cp "$ST/userdata" "$ST/secrets/$4" ;; esac; done ;;
  "label secret "*) exit 0 ;;
  "get secret "*" -o name")
    [ -f "$ST/secrets/$3" ] && { echo "secret/$3"; exit 0; }; notfound "$3" ;;
  "get secret "*"jsonpath={.data.kubeconfig}")
    [ -f "$ST/secrets/$3" ] || notfound "$3"
    grep -q STALE-GUEST "$ST/secrets/$3" && echo "READ-STALE $3" >>"$ST/log"
    base64 <"$ST/secrets/$3" | tr -d '\n' ;;
  "get secret "*"jsonpath={.data.ip}") notfound "$3" ;;
  "get secret -l "*|"get secret"|"get secret --no-headers"|"get secret -o "*)
    for f in "$ST"/secrets/*; do [ -f "$f" ] && echo "${f##*/}   Opaque   1   1m"; done; exit 0 ;;
  "apply -f -"|"apply -f - "*)
    k="$(sed -n 's/^kind: //p' | head -1)"
    stale=no; [ -f "$ST/secrets/k3s-test-01-kubeconfig" ] && stale=yes
    echo "APPLY ${k} stale-present=${stale}" >>"$ST/log"
    [ "$k" = VirtualMachine ] && echo "virtualmachine.kubevirt.io/k3s-test-01 created" ; exit 0 ;;
  "get svc "*nodePort*) printf '30001' ;;
  "get nodes"*) echo "error: You must be logged in to the server (the server has asked for the client to provide credentials)"; exit 1 ;;
  "api-resources --api-group=kubevirt.io") echo "virtualmachines  vm  kubevirt.io/v1  true  VirtualMachine" ;;
  "get pod "*|"get vmi "*|"get vm "*|"get svc "*|"get vmsnapshot "*|"get vm"|"get svc"|"get vmsnapshot") exit 0 ;;
  "delete "*) exit 0 ;;
  *) echo "STUB-UNHANDLED ${j}" >>"$ST/log"; exit 0 ;;
esac
STUB
# Nothing in these cases may reach the network.
printf '#!/bin/sh\necho "curl stub: no network in this test" >&2\nexit 7\n' >"${BIN}/curl"
# The node: `mirror-proof` pipes its script to `ssh ... sudo -n bash -s`; keep it, answer as a node would.
# shellcheck disable=SC2016  # the stub reads $STUB_STATE when it runs, not when it is written
printf '#!/bin/sh\ncat >"$STUB_STATE/ssh-script"\necho "ssh stub: script kept"\n' >"${BIN}/ssh"
# The provisioner's loops sleep 3 to 15 seconds between polls.
printf '#!/bin/sh\nexec %s 0.05\n' "$REAL_SLEEP" >"${BIN}/sleep"
# create validates the cloud-config with PyYAML when python3 has it; where it
# does not (a stock Mac), that check is skipped here rather than refusing.
cat >"${BIN}/python3" <<PY
#!/bin/sh
if [ -n "${REAL_PY}" ] && "${REAL_PY}" -c 'import yaml' 2>/dev/null; then exec "${REAL_PY}" "\$@"; fi
exit 0
PY
chmod +x "${BIN}"/*

new_state() { rm -rf "$1"; mkdir -p "$1/secrets"; : >"$1/log"; }
run_tc() {  # state-dir verb [extra env as VAR=val ...] -> $OUT, $RC
  local st="$1" verb="$2"; shift 2
  OUT="$(env STUB_STATE="$st" PATH="${BIN}:${PATH}" KUBECONFIG="${TMP}/substrate.kubeconfig" \
         TOCKMOX_SUBSTRATE_CONTEXT="stub-substrate" \
         TOCKMOX_WORKDIR="$st/wd" TOCKMOX_K3S_VERSION=v0.0.0-stub TOCKMOX_K3S_TIMEOUT=2 \
         TOCKMOX_TEST_VM="$VM" TMPDIR="$st" "$@" bash "$TC" "$verb" 2>&1)"
  RC=$?
}
vm_applied() { grep -c '^APPLY VirtualMachine' "$1/log" || true; }

# ---- clause 1: the mode check ----------------------------------------------
if [ ! -f "$LIB" ]; then
  bad "registry-mirror.sh is present" "not found at ${LIB}"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
# shellcheck source=/dev/null
. "$LIB"

chk() {  # label expect-rc mirror mode needle
  local o rc
  o="$(mirror_mode_check "$3" "$4" 2>&1)"; rc=$?
  if [ "$rc" -eq "$2" ] && { [ -z "${5:-}" ] || printf '%s' "$o" | grep -F -- "$5" >/dev/null; }; then ok "mode check: $1"
  else bad "mode check: $1" "rc=${rc} (want $2): ${o}"; fi
}
chk "cache with a mirror is usable" 0 "$M" cache
chk "cache with no mirror is usable (the harness's long-standing default)" 0 "" cache
chk "nofallback with a mirror is usable" 0 "$M:5000" nofallback
chk "nofallback with no mirror is refused" 2 "" nofallback "needs TOCKMOX_REGISTRY_MIRROR"
chk "an unknown mode is refused" 2 "$M" strict "is not cache or nofallback"
chk "nofallback with a mirror that is an upstream name is refused" 2 "docker.io" nofallback "upstream names"
chk "nofallback with a URL for a mirror is refused" 2 "https://$M" nofallback "host[:port]"
chk "nofallback with a path for a mirror is refused" 2 "$M/proxy" nofallback "host[:port]"
chk3() {  # label expect-rc mirror mode deny needle
  local o rc
  o="$(mirror_mode_check "$3" "$4" "$5" 2>&1)"; rc=$?
  if [ "$rc" -eq "$2" ] && { [ -z "${6:-}" ] || printf '%s' "$o" | grep -e "$6" >/dev/null; }; then ok "$1"
  else bad "$1" "rc=${rc} (want $2): ${o}"; fi
}
chk3 "nofallback with the denial at the edge is usable" 0 "$M" nofallback edge
chk3 "nofallback with the denial on the node is usable" 0 "$M" nofallback node
chk3 "an unknown denial place is refused" 2 "$M" nofallback Edge "is not node or edge"
chk3 "an unknown denial place is refused in cache mode too (a typo is never silently dropped)" 2 "$M" cache egde "is not node or edge"

# ---- clause 2 and 3: what each mode writes ---------------------------------
GOLD_CACHE=$(cat <<GOLD
mirrors:
  docker.io:
    endpoint:
      - "https://${M}"
      - "https://docker.io"
  quay.io:
    endpoint:
      - "https://${M}"
      - "https://quay.io"
  ghcr.io:
    endpoint:
      - "https://${M}"
      - "https://ghcr.io"
  registry.k8s.io:
    endpoint:
      - "https://${M}"
      - "https://registry.k8s.io"
GOLD
)
GOLD_NOFB=$(cat <<GOLD
mirrors:
  docker.io:
    endpoint:
      - "https://${M}"
  quay.io:
    endpoint:
      - "https://${M}"
  ghcr.io:
    endpoint:
      - "https://${M}"
  registry.k8s.io:
    endpoint:
      - "https://${M}"
GOLD
)
if [ "$(mirror_registries_yaml "$M" cache)" = "$GOLD_CACHE" ]; then
  ok "cache mode writes the registries.yaml the harness has always written (mirror first, upstream fallback)"
else bad "cache mode writes the registries.yaml the harness has always written" "$(mirror_registries_yaml "$M" cache)"; fi
if [ "$(mirror_registries_yaml "$M" nofallback)" = "$GOLD_NOFB" ]; then
  ok "nofallback writes the mirror as the only endpoint of all four registries"
else bad "nofallback writes the mirror as the only endpoint of all four registries" "$(mirror_registries_yaml "$M" nofallback)"; fi
if [ -z "$(mirror_k3s_dropin cache)" ] && [ "$(mirror_k3s_dropin nofallback)" = "disable-default-registry-endpoint: true" ]; then
  ok "the k3s drop-in disables the default registry endpoint in nofallback and is empty in cache"
else bad "the k3s drop-in disables the default registry endpoint in nofallback and is empty in cache" "cache=[$(mirror_k3s_dropin cache)] nofallback=[$(mirror_k3s_dropin nofallback)]"; fi

# ---- the Ubuntu lane, through create ---------------------------------------
# Decode a write_files entry out of the generated Ubuntu cloud-config.
ud_file() {  # userdata path -> content with the 6-space indent removed
  awk -v p="  - path: $2" '$0 == p {f=1; next}
       f && /^    content: \|$/ {c=1; next}
       f && c && /^      / {sub(/^      /, ""); print; next}
       f && c {exit}' "$1"
}
ud_has() { grep -qx "  - path: $2" "$1"; }

S="${TMP}/ub-cache"; new_state "$S"
run_tc "$S" create TOCKMOX_REGISTRY_MIRROR="$M"
UB_CACHE="$S/userdata"
if [ "$(vm_applied "$S")" -ge 1 ] && [ "$(ud_file "$UB_CACHE" /etc/rancher/k3s/registries.yaml)" = "$GOLD_CACHE" ] \
   && ! ud_has "$UB_CACHE" "$MIRROR_K3S_DROPIN" && ! ud_has "$UB_CACHE" "$MIRROR_DENY_PERBOOT" \
   && ! grep -q 'upstream-deny' "$UB_CACHE" && printf '%s' "$OUT" | grep 'registry mode: cache' >/dev/null; then
  ok "ubuntu lane, default mode: registries.yaml unchanged, no drop-in, no deny script, the transcript says cache"
else bad "ubuntu lane, default mode: registries.yaml unchanged, no drop-in, no deny script" "rc=${RC}, applied=$(vm_applied "$S"): $(printf '%s' "$OUT" | tail -3)"; fi

S="${TMP}/ub-nofb"; new_state "$S"
run_tc "$S" create TOCKMOX_REGISTRY_MIRROR="$M" TOCKMOX_REGISTRY_MODE=nofallback
UB_NOFB="$S/userdata"
if [ "$(vm_applied "$S")" -ge 1 ] && [ "$(ud_file "$UB_NOFB" /etc/rancher/k3s/registries.yaml)" = "$GOLD_NOFB" ]; then
  ok "ubuntu lane, nofallback: registries.yaml names the mirror and no upstream"
else bad "ubuntu lane, nofallback: registries.yaml names the mirror and no upstream" "rc=${RC}, applied=$(vm_applied "$S"): $(ud_file "$UB_NOFB" /etc/rancher/k3s/registries.yaml | head -6 | tr '\n' ' ')"; fi
if [ "$(ud_file "$UB_NOFB" "$MIRROR_K3S_DROPIN")" = "disable-default-registry-endpoint: true" ]; then
  ok "ubuntu lane, nofallback: the k3s drop-in disables the default registry endpoint"
else bad "ubuntu lane, nofallback: the k3s drop-in disables the default registry endpoint" "$(ud_file "$UB_NOFB" "$MIRROR_K3S_DROPIN")"; fi
if [ "$(ud_file "$UB_NOFB" "$MIRROR_DENY_PERBOOT")" = "$(mirror_deny_script)" ]; then
  ok "ubuntu lane, nofallback: the per-boot deny script is the lib's, byte for byte"
else bad "ubuntu lane, nofallback: the per-boot deny script is the lib's, byte for byte" "differs"; fi
# The deny script must run before k3s is installed, or the first pulls are uncounted.
d_line="$(grep -n 'upstream-deny.sh' "$UB_NOFB" | grep -v 'path:' | head -1 | cut -d: -f1)"
k_line="$(grep -n 'get.k3s.io | ' "$UB_NOFB" | head -1 | cut -d: -f1)"
if [ -n "$d_line" ] && [ -n "$k_line" ] && [ "$d_line" -lt "$k_line" ]; then
  ok "ubuntu lane, nofallback: the deny script is run before the k3s install"
else bad "ubuntu lane, nofallback: the deny script is run before the k3s install" "deny at line [${d_line}], k3s install at line [${k_line}]"; fi

# The denial at the edge (TOCKMOX_UPSTREAM_DENY=edge): the mirror is still the only registry,
# but nothing on the node rewrites or counts the upstream names, so the firewall sees them.
S="${TMP}/ub-edge"; new_state "$S"
run_tc "$S" create TOCKMOX_REGISTRY_MIRROR="$M" TOCKMOX_REGISTRY_MODE=nofallback TOCKMOX_UPSTREAM_DENY=edge
UB_EDGE="$S/userdata"
if [ "$(vm_applied "$S")" -ge 1 ] && [ "$(ud_file "$UB_EDGE" /etc/rancher/k3s/registries.yaml)" = "$GOLD_NOFB" ] \
   && [ "$(ud_file "$UB_EDGE" "$MIRROR_K3S_DROPIN")" = "disable-default-registry-endpoint: true" ]; then
  ok "ubuntu lane, nofallback with the denial at the edge: same registries.yaml and drop-in"
else bad "ubuntu lane, nofallback with the denial at the edge: same registries.yaml and drop-in" "rc=${RC}, applied=$(vm_applied "$S")"; fi
if ! ud_has "$UB_EDGE" "$MIRROR_DENY_PERBOOT" && ! grep -q 'upstream-deny' "$UB_EDGE" && ! grep -q '192\.0\.2\.1' "$UB_EDGE" \
   && printf '%s' "$OUT" | grep "upstream-deny=edge" >/dev/null; then
  ok "ubuntu lane, nofallback with the denial at the edge: no hosts remap, no deny script, no iptables rule; the transcript says so"
else bad "ubuntu lane, nofallback with the denial at the edge: no hosts remap, no deny script, no iptables rule" "$(grep -n 'upstream-deny\|192.0.2.1' "$UB_EDGE" | head -3)"; fi
# The verb sends the guest the proof for the place the denial is, not another one.
run_tc "$S" mirror-proof TOCKMOX_REGISTRY_MIRROR="$M" TOCKMOX_REGISTRY_MODE=nofallback TOCKMOX_UPSTREAM_DENY=edge TOCKMOX_VM_ADDRESS=192.0.2.77 TOCKMOX_VM_GUEST_ADDRESS=10.99.0.5/24
if [ "$RC" -eq 0 ] && grep -q 'upstream-deny=edge' "$S/ssh-script" 2>/dev/null && ! grep -q 'iptables' "$S/ssh-script"; then
  ok "mirror-proof, denial at the edge: the guest is sent the files-only proof"
else bad "mirror-proof, denial at the edge: the guest is sent the files-only proof" "rc=${RC}: $(printf '%s' "$OUT" | tail -2); script: $(head -3 "$S/ssh-script" 2>&1 | tr '\n' ' ')"; fi
run_tc "$S" mirror-proof TOCKMOX_REGISTRY_MIRROR="$M" TOCKMOX_REGISTRY_MODE=nofallback TOCKMOX_VM_ADDRESS=192.0.2.77 TOCKMOX_VM_GUEST_ADDRESS=10.99.0.5/24
if [ "$RC" -eq 0 ] && grep -q 'upstream-deny=node' "$S/ssh-script" 2>/dev/null && grep -q 'iptables' "$S/ssh-script"; then
  ok "mirror-proof, default denial place: the guest is sent the proof that reads the counter"
else bad "mirror-proof, default denial place: the guest is sent the proof that reads the counter" "rc=${RC}: $(printf '%s' "$OUT" | tail -2)"; fi
S="${TMP}/ub-baddeny"; new_state "$S"
run_tc "$S" create TOCKMOX_REGISTRY_MIRROR="$M" TOCKMOX_REGISTRY_MODE=nofallback TOCKMOX_UPSTREAM_DENY=firewall
if [ "$RC" -eq 2 ] && [ "$(vm_applied "$S")" -eq 0 ] && printf '%s' "$OUT" | grep 'is not node or edge' >/dev/null; then
  ok "create refuses a denial place it does not know before it changes anything"
else bad "create refuses a denial place it does not know before it changes anything" "rc=${RC}, applied=$(vm_applied "$S"): $(printf '%s' "$OUT" | tail -2)"; fi

# ---- clause 6: refusals ----------------------------------------------------
S="${TMP}/ub-nomirror"; new_state "$S"
run_tc "$S" create TOCKMOX_REGISTRY_MODE=nofallback
if [ "$RC" -eq 2 ] && [ "$(vm_applied "$S")" -eq 0 ] && [ "$(grep -vc 'config view' "$S/calls")" -eq 0 ] && printf '%s' "$OUT" | grep 'needs TOCKMOX_REGISTRY_MIRROR' >/dev/null; then
  ok "create refuses nofallback with no mirror before it changes anything on the substrate"
else bad "create refuses nofallback with no mirror before it changes anything on the substrate" "rc=${RC}, applied=$(vm_applied "$S"), calls=$(grep -vc 'config view' "$S/calls" 2>/dev/null): $(printf '%s' "$OUT" | tail -2)"; fi
S="${TMP}/ub-badmode"; new_state "$S"
run_tc "$S" create TOCKMOX_REGISTRY_MIRROR="$M" TOCKMOX_REGISTRY_MODE=Nofallback
if [ "$RC" -eq 2 ] && [ "$(vm_applied "$S")" -eq 0 ] && printf '%s' "$OUT" | grep 'is not cache or nofallback' >/dev/null; then
  ok "create refuses a mode it does not know (a misspelling is not cache)"
else bad "create refuses a mode it does not know (a misspelling is not cache)" "rc=${RC}, applied=$(vm_applied "$S"): $(printf '%s' "$OUT" | tail -2)"; fi
S="${TMP}/proof-cache"; new_state "$S"
run_tc "$S" mirror-proof TOCKMOX_REGISTRY_MIRROR="$M"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep 'mirror-proof reads a nofallback run' >/dev/null; then
  ok "mirror-proof refuses to read a cache-mode cluster"
else bad "mirror-proof refuses to read a cache-mode cluster" "rc=${RC}: $(printf '%s' "$OUT" | tail -2)"; fi

# ---- the MicroOS lane ------------------------------------------------------
mx_files() {  # mode [deny] -> decoded write_files dir in $TMP/mx-$mode[-$deny], the document beside it as .yaml
  local mode="$1" deny="${2:-}" tag="$1${2:+-$2}" od="${TMP}/mx-$1${2:+-$2}.out"
  mkdir -p "$od/blocks"; printf '#!/bin/sh\necho block\n' >"$od/blocks/01.sh"; printf 'x\ty\n' >"$od/PROVENANCE.tsv"
  # shellcheck source=/dev/null
  ( . "$PROFILE" && { [ -z "$deny" ] || export MX_UPSTREAM_DENY="$deny"; } && MX_OUTDIR="$od" MX_PREFIX=t-01 MX_API=https://api.invalid MX_NS=tockmox-test \
      MX_TOKEN=x MX_CA_B64="" MX_USER=tockmox MX_PUBKEY="ssh-ed25519 AAAA test" \
      MX_HOSTNAME=t-01 MX_MIRROR="$M" MX_MIRROR_MODE="$mode" microos_cloud_config "${TMP}/mx-$tag.yaml" ) >/dev/null 2>&1 || return 1
  "${REAL_PY:-python3}" - "${TMP}/mx-$tag.yaml" "${TMP}/mx-$tag" <<'PY'
import base64, json, pathlib, sys
d = json.loads(open(sys.argv[1]).read().split("\n", 1)[1])
out = pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
for f in d["write_files"]:
    p = out / f["path"].lstrip("/")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(base64.b64decode(f["content"]))
    p.chmod(int(f["permissions"], 8))
PY
}
if mx_files cache && mx_files nofallback; then
  C="${TMP}/mx-cache"; N="${TMP}/mx-nofallback"; R=etc/rancher/k3s/registries.yaml
  if [ "$(cat "$C/$R")" = "$GOLD_CACHE" ] && [ ! -e "$C/${MIRROR_K3S_DROPIN#/}" ] && [ ! -e "$C/${MIRROR_DENY_PERBOOT#/}" ]; then
    ok "microos lane, default mode: registries.yaml unchanged, no drop-in, no deny script"
  else bad "microos lane, default mode: registries.yaml unchanged, no drop-in, no deny script" "$(head -5 "$C/$R" 2>&1 | tr '\n' ' ')"; fi
  if [ "$(cat "$N/$R")" = "$GOLD_NOFB" ] && [ "$(cat "$N/${MIRROR_K3S_DROPIN#/}")" = "disable-default-registry-endpoint: true" ] \
     && [ "$(cat "$N/${MIRROR_DENY_PERBOOT#/}")" = "$(mirror_deny_script)" ] && [ -x "$N/${MIRROR_DENY_PERBOOT#/}" ]; then
    ok "microos lane, nofallback: the same registries.yaml, drop-in and deny script as the Ubuntu lane"
  else bad "microos lane, nofallback: the same registries.yaml, drop-in and deny script as the Ubuntu lane" "$(head -5 "$N/$R" 2>&1 | tr '\n' ' ')"; fi
  # The deny script must sort before the harness driver's per-boot hook (50-).
  if [ "$(basename "$MIRROR_DENY_PERBOOT")" \< "50-tockmox-harness.sh" ]; then
    ok "microos lane: the deny script sorts before the driver's per-boot hook"
  else bad "microos lane: the deny script sorts before the driver's per-boot hook" "$(basename "$MIRROR_DENY_PERBOOT")"; fi
else
  bad "the MicroOS cloud-config builds in both modes" "see ${TMP}/mx-*.yaml"
fi
if mx_files nofallback edge; then
  E="${TMP}/mx-nofallback-edge"; R=etc/rancher/k3s/registries.yaml
  if [ "$(cat "$E/$R")" = "$GOLD_NOFB" ] && [ "$(cat "$E/${MIRROR_K3S_DROPIN#/}")" = "disable-default-registry-endpoint: true" ] \
     && [ ! -e "$E/${MIRROR_DENY_PERBOOT#/}" ]; then
    ok "microos lane, nofallback with the denial at the edge: registries.yaml and drop-in, no deny script"
  else bad "microos lane, nofallback with the denial at the edge: registries.yaml and drop-in, no deny script" "$(find "$E" -type f | head -8 | tr '\n' ' ')"; fi
else bad "microos lane, nofallback with the denial at the edge: the cloud-config builds" "see ${TMP}/mx-nofallback-edge.yaml"; fi
# shellcheck source=/dev/null
if ! ( . "$PROFILE" && MX_OUTDIR="${TMP}/mx-cache.out" MX_PREFIX=t-01 MX_API=x MX_NS=x MX_TOKEN=x MX_USER=x MX_PUBKEY=x MX_HOSTNAME=x \
       MX_MIRROR="$M" MX_MIRROR_MODE=nofallback MX_UPSTREAM_DENY=firewall microos_cloud_config "${TMP}/mx-baddeny.yaml" ) >/dev/null 2>&1; then
  ok "microos lane: an unknown denial place is refused"
else bad "microos lane: an unknown denial place is refused" "the build succeeded"; fi
# A caller that never heard of modes (MX_MIRROR_MODE unset) gets cache, as before.
# shellcheck source=/dev/null
if ( . "$PROFILE" && MX_OUTDIR="${TMP}/mx-cache.out" MX_PREFIX=t-01 MX_API=x MX_NS=x MX_TOKEN=x MX_USER=x MX_PUBKEY=x MX_HOSTNAME=x MX_CA_B64="" \
       MX_MIRROR="$M" microos_cloud_config "${TMP}/mx-unset.yaml" ) >/dev/null 2>&1 \
   && "${REAL_PY:-python3}" - "${TMP}/mx-unset.yaml" <<'PY'
import base64, json, sys
d = json.loads(open(sys.argv[1]).read().split("\n", 1)[1])
f = {x["path"]: base64.b64decode(x["content"]).decode() for x in d["write_files"]}
assert "https://docker.io" in f["/etc/rancher/k3s/registries.yaml"]
assert not any("nofallback" in p or "upstream-deny" in p for p in f), sorted(f)
PY
then ok "microos lane: MX_MIRROR_MODE unset means cache"
else bad "microos lane: MX_MIRROR_MODE unset means cache" "see ${TMP}/mx-unset.yaml"; fi
# shellcheck source=/dev/null
if ( . "$PROFILE" && MX_OUTDIR="${TMP}/mx-cache.out" MX_PREFIX=t-01 MX_API=x MX_NS=x MX_TOKEN=x MX_USER=x MX_PUBKEY=x MX_HOSTNAME=x \
       MX_MIRROR="" MX_MIRROR_MODE=nofallback microos_cloud_config "${TMP}/mx-none.yaml" ) >/dev/null 2>&1; then
  ok "microos lane: no mirror means no registry files whatever the mode says"
else bad "microos lane: no mirror means no registry files whatever the mode says" "the build failed"; fi
# shellcheck source=/dev/null
if ! ( . "$PROFILE" && MX_OUTDIR="${TMP}/mx-cache.out" MX_PREFIX=t-01 MX_API=x MX_NS=x MX_TOKEN=x MX_USER=x MX_PUBKEY=x MX_HOSTNAME=x \
       MX_MIRROR="$M" MX_MIRROR_MODE=bogus microos_cloud_config "${TMP}/mx-bogus.yaml" ) >/dev/null 2>&1; then
  ok "microos lane: an unknown mode is refused"
else bad "microos lane: an unknown mode is refused" "the build succeeded"; fi

# ---- clause 4: the deny script, run against stubs --------------------------
G="${TMP}/guest"; mkdir -p "$G/bin"
: >"$G/hosts"; : >"$G/ipt.log"
cat >"$G/bin/iptables" <<'IPT'
#!/bin/sh
echo "$*" >>"$IPT_LOG"
# -C (check) reports the rule absent the first time and present afterwards.
case "$1" in
  -C) grep -q '^-I OUTPUT' "$IPT_LOG" && exit 0; exit 1 ;;
  -nvxL) cat "$IPT_COUNTERS" 2>/dev/null; exit 0 ;;
  -nL) [ -f "$IPT_CHAIN_ABSENT" ] && exit 1; exit 0 ;;
esac
exit 0
IPT
chmod +x "$G/bin/iptables"
mirror_deny_script | sed "s#/etc/hosts#$G/hosts#g" >"$G/deny.sh"
run_deny() { IPT_LOG="$G/ipt.log" PATH="$G/bin:${PATH}" sh "$G/deny.sh" >/dev/null 2>&1; }
run_deny; RC1=$?
sorted1="$(sort "$G/hosts" | tr '\n' '|')"
run_deny; RC2=$?
missing=""
for n in $MIRROR_DENY_NAMES; do grep -qx "$MIRROR_DENY_ADDR $n" "$G/hosts" || missing="$missing $n"; done
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ -z "$missing" ]; then
  ok "deny script: every denied name resolves to the unroutable address"
else bad "deny script: every denied name resolves to the unroutable address" "rc=${RC1}/${RC2}, missing:${missing}"; fi
if [ "$(sort "$G/hosts" | tr '\n' '|')" = "$sorted1" ] && [ "$(wc -l <"$G/hosts")" -eq "$(echo "$MIRROR_DENY_NAMES" | wc -w)" ]; then
  ok "deny script: running it twice adds no second hosts line"
else bad "deny script: running it twice adds no second hosts line" "$(wc -l <"$G/hosts") lines"; fi
if grep -q "^-A ${MIRROR_DENY_CHAIN} -j REJECT" "$G/ipt.log" && grep -q "^-I OUTPUT 1 -d ${MIRROR_DENY_ADDR} -j ${MIRROR_DENY_CHAIN}" "$G/ipt.log" \
   && [ "$(grep -c '^-I OUTPUT' "$G/ipt.log")" -eq 1 ]; then
  ok "deny script: rejects and counts in its own chain, hooked into OUTPUT once"
else bad "deny script: rejects and counts in its own chain, hooked into OUTPUT once" "$(tr '\n' ';' <"$G/ipt.log")"; fi
if mirror_deny_script | sh -n 2>/dev/null; then ok "deny script: parses as POSIX sh"; else bad "deny script: parses as POSIX sh" ""; fi

# ---- clause 5: the guest's proof, run against stubs ------------------------
mkdir -p "$G/etc/k3s"
proof_run() {  # registries-file dropin-content-or-empty counters -> $OUT $RC
  printf '%s\n' "$1" >"$G/etc/k3s/registries.yaml"
  if [ -n "$2" ]; then printf '%s\n' "$2" >"$G/etc/k3s/dropin.yaml"; else rm -f "$G/etc/k3s/dropin.yaml"; fi
  printf '%s\n' "$3" >"$G/counters"
  mirror_proof_script "$M" "${PROOF_DENY:-node}" \
    | sed -e "s#/etc/rancher/k3s/registries.yaml#$G/etc/k3s/registries.yaml#" -e "s#$MIRROR_K3S_DROPIN#$G/etc/k3s/dropin.yaml#g" >"$G/proof.sh"
  OUT="$(IPT_LOG="$G/ipt2.log" IPT_COUNTERS="$G/counters" IPT_CHAIN_ABSENT="$G/absent" PATH="$G/bin:${PATH}" sh "$G/proof.sh" 2>&1)"
  RC=$?
}
GOODCOUNT=$'Chain TOCKMOX_UPSTREAM_DENY (1 references)\n    pkts      bytes target     prot opt in     out     source               destination\n       0        0 REJECT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0\n       0        0 REJECT     all  --  *      *       0.0.0.0/0            0.0.0.0/0'
rm -f "$G/absent"
proof_run "$GOLD_NOFB" "disable-default-registry-endpoint: true" "$GOODCOUNT"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep 'mirror-proof: PASS' >/dev/null && printf '%s' "$OUT" | grep '0 packet' >/dev/null; then
  ok "mirror-proof: PASS for a nofallback node whose counter is zero"
else bad "mirror-proof: PASS for a nofallback node whose counter is zero" "rc=${RC}: ${OUT}"; fi
proof_run "$GOLD_NOFB" "disable-default-registry-endpoint: true" "${GOODCOUNT/       0        0 REJECT     tcp/       3      180 REJECT     tcp}"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep '3 packet' >/dev/null; then
  ok "mirror-proof: FAIL when anything reached the denied address"
else bad "mirror-proof: FAIL when anything reached the denied address" "rc=${RC}: ${OUT}"; fi
proof_run "$GOLD_CACHE" "disable-default-registry-endpoint: true" "$GOODCOUNT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep 'still names the upstream' >/dev/null; then
  ok "mirror-proof: FAIL when registries.yaml still names an upstream"
else bad "mirror-proof: FAIL when registries.yaml still names an upstream" "rc=${RC}: ${OUT}"; fi
proof_run "$GOLD_NOFB" "" "$GOODCOUNT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep 'does not disable the default registry endpoint' >/dev/null; then
  ok "mirror-proof: FAIL when the k3s drop-in is missing"
else bad "mirror-proof: FAIL when the k3s drop-in is missing" "rc=${RC}: ${OUT}"; fi
: >"$G/absent"
proof_run "$GOLD_NOFB" "disable-default-registry-endpoint: true" "$GOODCOUNT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep 'deny chain .* is absent' >/dev/null; then
  ok "mirror-proof: FAIL when the deny chain is absent (a zero counter there is not a zero)"
else bad "mirror-proof: FAIL when the deny chain is absent" "rc=${RC}: ${OUT}"; fi
rm -f "$G/absent"
# The denial at the edge: the script checks the two files, does not look for a chain or a counter,
# and says the counter is elsewhere. A PASS there is not a zero.
: >"$G/absent"
PROOF_DENY=edge proof_run "$GOLD_NOFB" "disable-default-registry-endpoint: true" "$GOODCOUNT"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep 'mirror-proof: PASS (configuration only' >/dev/null \
   && printf '%s' "$OUT" | grep 'not counted on this node' >/dev/null && ! printf '%s' "$OUT" | grep 'packet' >/dev/null; then
  ok "mirror-proof, denial at the edge: PASS on the two files alone, and it says the counter is not here"
else bad "mirror-proof, denial at the edge: PASS on the two files alone, and it says the counter is not here" "rc=${RC}: ${OUT}"; fi
PROOF_DENY=edge proof_run "$GOLD_CACHE" "disable-default-registry-endpoint: true" "$GOODCOUNT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep 'still names the upstream' >/dev/null; then
  ok "mirror-proof, denial at the edge: FAIL when registries.yaml still names an upstream"
else bad "mirror-proof, denial at the edge: FAIL when registries.yaml still names an upstream" "rc=${RC}: ${OUT}"; fi
PROOF_DENY=edge proof_run "$GOLD_NOFB" "" "$GOODCOUNT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep 'does not disable the default registry endpoint' >/dev/null; then
  ok "mirror-proof, denial at the edge: FAIL when the k3s drop-in is missing"
else bad "mirror-proof, denial at the edge: FAIL when the k3s drop-in is missing" "rc=${RC}: ${OUT}"; fi
rm -f "$G/absent"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

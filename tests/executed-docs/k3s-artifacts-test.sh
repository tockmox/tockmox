#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for TOCKMOX_K3S_ARTIFACTS_URL in provision/throwaway-cluster.sh: k3s from inside the boundary.
# No cluster, no network: kubectl and curl are stubs, and the provisioner runs unmodified against them (the same
# stub shape as mirror-mode-test.sh). One `ok` or `FAIL` line per case; exit 1 on any FAIL.
#
#   1. unset, the guest installs k3s from get.k3s.io and the beacon probes it, as before the variable existed
#   2. set, nothing in the cloud-config names get.k3s.io: the guest runs k3s-from-inside.sh with the server
#      arguments the documentation prescribes, and the beacon says it skipped the WAN probe and probes the URL
#   3. the guest script, run against stubs, fetches VERSION/k3s and VERSION/install.sh from the URL and runs the
#      script with INSTALL_K3S_SKIP_DOWNLOAD=true; a binary of another version, or a failed fetch, stops it
#   4. a URL that is not http(s), or holds a character a URL in a guest script must not, is refused before any
#      VM is applied, and so is the variable on the MicroOS lane
#
# What it does not show: that a real guest reaches the URL, or that the k3s install script honours
# INSTALL_K3S_SKIP_DOWNLOAD. Those are lab clauses, read from the beacon and the console.
#
#   ./tests/executed-docs/k3s-artifacts-test.sh
#   TC=/path/to/throwaway-cluster.sh ./tests/executed-docs/k3s-artifacts-test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

VM=k3s-test-01
V=v1.36.4+k3s1
U=https://artifacts.example.test/k3s
REAL_SLEEP="$(command -v sleep)"
REAL_PY="$(command -v python3 || true)"
BIN="${TMP}/bin"
mkdir -p "$BIN"

cat >"${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
ST="$STUB_STATE"
printf '%s\n' "$*" >>"$ST/log"
# Every invocation, verbatim, so a case can assert that each one named a cluster
#. `log` above also carries non-call lines the cases grep for.
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
    # A JWT-shaped ServiceAccount token for tockmox-test (the script reads its
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
# The provisioner's loops sleep 3 to 15 seconds between polls.
printf '#!/bin/sh\nexec %s 0.05\n' "$REAL_SLEEP" >"${BIN}/sleep"
# create validates the cloud-config with PyYAML when python3 has it; where it does not, that check is skipped here.
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
         TOCKMOX_WORKDIR="$st/wd" TOCKMOX_K3S_VERSION="$V" TOCKMOX_K3S_TIMEOUT=2 \
         TOCKMOX_CAPACITY_CHECK=skip TOCKMOX_TEST_VM="$VM" TMPDIR="$st" "$@" bash "$TC" "$verb" 2>&1)"
  RC=$?
}
vm_applied() { grep -c '^APPLY VirtualMachine' "$1/log" || true; }
ud_file() {  # userdata path -> content with the 6-space indent removed
  awk -v p="  - path: $2" '$0 == p {f=1; next}
       f && /^    content: \|$/ {c=1; next}
       f && c && /^      / {sub(/^      /, ""); print; next}
       f && c {exit}' "$1"
}
runcmd_k3s() { grep -E '^  - \[ sh, -c, ".*(get\.k3s\.io|k3s-from-inside)' "$1"; }
ARGS_RE='server --disable traefik --disable servicelb --write-kubeconfig-mode 644 --token [0-9a-f]{48}'

# ---- 1: unset is what it was ----------------------------------------------
S="${TMP}/unset"; new_state "$S"
run_tc "$S" create
UD="$S/userdata"
if [ "$(vm_applied "$S")" -ge 1 ] \
   && runcmd_k3s "$UD" | grep -Ex "  - \[ sh, -c, \"curl -sfL https://get\.k3s\.io \| INSTALL_K3S_VERSION=v1\.36\.4\+k3s1 sh -s - ${ARGS_RE}\" \]" >/dev/null \
   && [ "$(runcmd_k3s "$UD" | wc -l)" -eq 1 ] && ! grep -q 'k3s-from-inside' "$UD" \
   && ! printf '%s' "$OUT" | grep 'TOCKMOX_K3S_ARTIFACTS_URL' >/dev/null; then
  ok "unset: the guest installs from get.k3s.io, and nothing mentions an artifacts URL"
else bad "unset: the guest installs from get.k3s.io" "rc=${RC}: $(runcmd_k3s "$UD" 2>&1 | head -2)"; fi
if ud_file "$UD" /usr/local/bin/beacon.sh | grep -F "https://get.k3s.io 2>&1)" >/dev/null \
   && ! ud_file "$UD" /usr/local/bin/beacon.sh | grep 'skipped' >/dev/null; then
  ok "unset: the beacon probes get.k3s.io"
else bad "unset: the beacon probes get.k3s.io" "$(ud_file "$UD" /usr/local/bin/beacon.sh | grep -i wan)"; fi

# ---- 2: set, nothing names get.k3s.io ---------------------------------------
S="${TMP}/set"; new_state "$S"
run_tc "$S" create TOCKMOX_K3S_ARTIFACTS_URL="${U}/"
UD="$S/userdata"
if [ "$(vm_applied "$S")" -ge 1 ] && ! grep -q 'get\.k3s\.io' "$UD" \
   && runcmd_k3s "$UD" | grep -Ex "  - \[ sh, -c, \"/usr/local/bin/k3s-from-inside\.sh ${ARGS_RE}\" \]" >/dev/null \
   && printf '%s' "$OUT" | grep -F "k3s from ${U}/${V} (TOCKMOX_K3S_ARTIFACTS_URL)" >/dev/null; then
  ok "set: the guest runs k3s-from-inside.sh with the documented server arguments, and get.k3s.io appears nowhere"
else bad "set: the guest runs k3s-from-inside.sh" "rc=${RC}, get.k3s.io lines=$(grep -c 'get\.k3s\.io' "$UD"): $(runcmd_k3s "$UD" 2>&1 | head -2)"; fi
B="$(ud_file "$UD" /usr/local/bin/beacon.sh)"
if printf '%s' "$B" | grep 'wan probe skipped' >/dev/null && printf '%s' "$B" | grep -F "'${U}/${V}/install.sh'" >/dev/null; then
  ok "set: the beacon says it skipped the WAN probe and probes the artifacts URL instead (trailing slash dropped)"
else bad "set: the beacon says it skipped the WAN probe" "$(printf '%s' "$B" | grep -iE 'wan|artifacts')"; fi
if grep -qx '    permissions: "0700"' "$UD" && ! ud_file "$UD" /usr/local/bin/k3s-from-inside.sh | grep -- '--token' >/dev/null; then
  ok "set: the guest script is 0700 and the token reaches it only on the command line"
else bad "set: the guest script is 0700 and holds no token" "$(grep -n 'permissions' "$UD" | tr '\n' ' ')"; fi

# ---- 3: the guest script, run against stubs --------------------------------
G="${TMP}/guest"; mkdir -p "$G/bin" "$G/run" "$G/usr"
ud_file "$UD" /usr/local/bin/k3s-from-inside.sh \
  | sed -e "s#/usr/local/bin/k3s#$G/usr/k3s#g" -e "s#/run/#$G/run/#g" >"$G/k3s-from-inside.sh"
# curl -fsSL -o FILE URL: write what the URL names, from $G/serve, or fail as curl -f does.
cat >"$G/bin/curl" <<'C'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
echo "$url" >>"$GUEST/curl.log"
f="$GUEST/serve/${url##*/}"
[ -f "$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$f" "$out"
C
chmod +x "$G/bin/curl"
serve() {  # serve VERSION-THE-BINARY-REPORTS
  rm -rf "$G/serve" "$G/usr/k3s" "$G/run/k3s-install.sh"; mkdir -p "$G/serve"; : >"$G/curl.log"
  printf '#!/bin/sh\necho "k3s version %s (stubhash)"\n' "$1" >"$G/serve/k3s"
  # shellcheck disable=SC2016  # the stub install script expands these when it runs
  printf '#!/bin/sh\necho "install skip=${INSTALL_K3S_SKIP_DOWNLOAD:-} version=${INSTALL_K3S_VERSION:-} args=$*" >"$GUEST/installed"\n' >"$G/serve/install.sh"
}
run_guest() { rm -f "$G/installed"; GOUT="$(GUEST="$G" PATH="$G/bin:$PATH" sh "$G/k3s-from-inside.sh" server --disable traefik --token abc 2>&1)"; GRC=$?; }
serve "$V"; run_guest
if [ "$GRC" -eq 0 ] && grep -qxF "${U}/${V}/k3s" "$G/curl.log" && grep -qxF "${U}/${V}/install.sh" "$G/curl.log" \
   && grep -qxF "install skip=true version=${V} args=server --disable traefik --token abc" "$G/installed" 2>/dev/null; then
  ok "guest: fetches VERSION/k3s and VERSION/install.sh from the URL and installs with INSTALL_K3S_SKIP_DOWNLOAD=true"
else bad "guest: fetches from the URL and installs with the download skipped" "rc=${GRC}: ${GOUT} | $(cat "$G/installed" 2>&1)"; fi
serve "v1.35.9+k3s1"; run_guest
if [ "$GRC" -ne 0 ] && [ ! -e "$G/installed" ] && [ ! -e "$G/usr/k3s" ] && printf '%s' "$GOUT" | grep "is not ${V}" >/dev/null; then
  ok "guest: a binary of another version is removed and the install never runs"
else bad "guest: a binary of another version stops the install" "rc=${GRC}: ${GOUT}"; fi
serve "$V"; rm -f "$G/serve/install.sh"; run_guest
if [ "$GRC" -ne 0 ] && [ ! -e "$G/installed" ] && printf '%s' "$GOUT" | grep 'FAILED to fetch' >/dev/null; then
  ok "guest: a failed fetch stops it and says which file"
else bad "guest: a failed fetch stops it" "rc=${GRC}: ${GOUT}"; fi

# ---- 4: refusals -----------------------------------------------------------
refused() {  # label url needle [extra env...]
  local label="$1" url="$2" needle="$3"; shift 3
  S="${TMP}/refuse"; new_state "$S"
  run_tc "$S" create TOCKMOX_K3S_ARTIFACTS_URL="$url" "$@"
  if [ "$RC" -eq 2 ] && [ "$(vm_applied "$S")" -eq 0 ] && printf '%s' "$OUT" | grep -F -- "$needle" >/dev/null; then ok "refused: $label"
  else bad "refused: $label" "rc=${RC}, applied=$(vm_applied "$S"): $(printf '%s' "$OUT" | tail -2)"; fi
}
refused "a URL that is not http(s)" "artifacts.example.test/k3s" "is an http(s) URL"
refused "a scheme with nothing after it" "https://" "is an http(s) URL"
refused "a quote in the URL" "https://a.example.test/k3s'x" "may hold only"
refused "a space in the URL" "https://a.example.test/k 3s" "may hold only"
# shellcheck disable=SC2016  # the literal $(id) is the point: it must be refused, not run
refused "a command substitution in the URL" 'https://a.example.test/$(id)' "may hold only"
refused "the variable on the MicroOS lane" "$U" "is for the Ubuntu lane" \
  TOCKMOX_VM_IMAGE_ID=tockmox-test/opensuse-microos TOCKMOX_DOCS_REF=main

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

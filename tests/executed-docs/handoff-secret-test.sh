#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic contract test for the guest kubeconfig handoff Secret. TM-0766.
# No cluster, no network: kubectl, curl and ip are stubs over a directory of
# files, and the provisioner runs unmodified against them.
#
# WHAT IT HOLDS THE PROVISIONER TO. On 2026-09-28 a failed create's teardown
# left k3s-test-01-kubeconfig behind; the next create polled it, took a dead
# guest's client certificate as its own, and spent twenty minutes on 401. The
# new guest's POST got 409, which the handoff counted as success, so nothing
# ever replaced the stale copy. Three clauses, each proved to go red:
#
#   1. create never waits on a pre-existing ${VM_NAME}-kubeconfig: it deletes
#      it before building anything, and refuses when it cannot prove it gone
#   2. the guest handoff (Ubuntu and MicroOS lanes) does not treat 409 as
#      delivered: it replaces the Secret, and fails when the replace is refused
#   3. destroy counts harness Secrets left behind and does not swallow a
#      failed Secret delete
#
#   ./tests/executed-docs/handoff-secret-test.sh
#   TC=/path/to/throwaway-cluster.sh ./tests/executed-docs/handoff-secret-test.sh
#
# TC exists so the same cases can be pointed at an older copy of the
# provisioner to show they go red there. The MicroOS profile is read from
# beside it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
PROFILE="$(dirname "$TC")/profiles/microos.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

VM=k3s-test-01
REAL_SLEEP="$(command -v sleep)"
REAL_PY="$(command -v python3 || true)"
BIN="${TMP}/bin"
mkdir -p "$BIN"

# ---- the fake substrate ----------------------------------------------------
# One file per Secret under $STUB_STATE/secrets; every Secret counts as
# harness-labelled, which is what the real ones are. Two switches turn the
# failure modes on: deny-delete (every Secret delete is Forbidden) and sticky
# (a Secret delete reports success and the Secret survives).
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

new_state() {  # dir -> fresh fake namespace
  rm -rf "$1"; mkdir -p "$1/secrets"; : >"$1/log"
}
seed_stale() {  # dir: what the 2026-09-28 run found, left by the previous guest
  printf 'apiVersion: v1\nclusters:\n- cluster:\n    certificate-authority-data: STALE-GUEST\n    server: https://192.0.2.99:6443\n  name: default\n' \
    >"$1/secrets/${VM}-kubeconfig"
  printf 'stage: STALE-GUEST\n' >"$1/secrets/${VM}-boot"
}
secrets_left() {  # state-dir -> names of Secrets still present
  local f
  for f in "$1"/secrets/*; do [ -e "$f" ] && printf '%s ' "${f##*/}"; done
  return 0
}
run_tc() {  # state-dir verb -> stdout+stderr in $OUT, rc in $RC
  # SUBSTRATE_CTX="" runs the verb with the required context empty (TM-0797).
  OUT="$(STUB_STATE="$1" PATH="${BIN}:${PATH}" KUBECONFIG="${TMP}/substrate.kubeconfig" \
         TOCKMOX_SUBSTRATE_CONTEXT="${SUBSTRATE_CTX-stub-substrate}" \
         TOCKMOX_WORKDIR="$1/wd" TOCKMOX_K3S_VERSION=v0.0.0-stub TOCKMOX_K3S_TIMEOUT=2 \
         TOCKMOX_TEST_VM="$VM" TMPDIR="$1" bash "$TC" "$2" 2>&1)"
  RC=$?
}

# ---- clause 1: create and a stale handoff Secret ---------------------------
S="${TMP}/create-replace"; new_state "$S"; seed_stale "$S"
run_tc "$S" create
if ! grep -q '^APPLY VirtualMachine' "$S/log"; then
  bad "create with a stale kubeconfig Secret removes it, then provisions" "no VirtualMachine was applied (rc=${RC}): $(printf '%s' "$OUT" | tail -3)"
elif grep -q 'READ-STALE' "$S/log" || grep -q '^APPLY VirtualMachine stale-present=yes' "$S/log" \
     || [ -f "$S/secrets/${VM}-boot" ]; then
  bad "create with a stale kubeconfig Secret removes it, then provisions" \
      "the stale Secret survived into provisioning: $(grep -E 'READ-STALE|^APPLY VirtualMachine' "$S/log" | head -3 | tr '\n' ' ')"
else
  ok "create with a stale kubeconfig Secret removes it, then provisions"
fi
USERDATA="$S/userdata"

S="${TMP}/create-deny"; new_state "$S"; seed_stale "$S"; : >"$S/deny-delete"
run_tc "$S" create
if [ "$RC" -eq 2 ] && ! grep -q '^APPLY VirtualMachine' "$S/log" \
   && printf '%s' "$OUT" | grep -q "REFUSING.*${VM}-kubeconfig"; then
  ok "create refuses, before any VM, when the stale Secret cannot be deleted"
else
  bad "create refuses, before any VM, when the stale Secret cannot be deleted" \
      "rc=${RC}; $(grep -c '^APPLY VirtualMachine' "$S/log") VM apply(s); $(grep -m1 READ-STALE "$S/log")"
fi

S="${TMP}/create-sticky"; new_state "$S"; seed_stale "$S"; : >"$S/sticky"
run_tc "$S" create
if [ "$RC" -eq 2 ] && ! grep -q '^APPLY VirtualMachine' "$S/log" \
   && printf '%s' "$OUT" | grep -q "still exists"; then
  ok "create refuses when a delete returns 0 but the stale Secret is still there"
else
  bad "create refuses when a delete returns 0 but the stale Secret is still there" \
      "rc=${RC}; $(grep -c '^APPLY VirtualMachine' "$S/log") VM apply(s)"
fi

# ---- clause 2: the guest's side of the handoff -----------------------------
# The guest scripts run unmodified except for where they read and write files:
# /run and k3s.yaml are rewritten to a scratch dir, and PATH carries stubs for
# curl (answering from CURL_POST / CURL_PUT) and ip.
G="${TMP}/guest"; mkdir -p "$G/bin" "$G/run"
printf 'apiVersion: v1\nclusters:\n- cluster:\n    certificate-authority-data: THIS-GUEST\n    server: https://127.0.0.1:6443\n' >"$G/k3s.yaml"
printf '#!/bin/sh\necho "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' >"$G/bin/ip"
cat >"$G/bin/curl" <<'CURL'
#!/bin/sh
m=GET; url=""
while [ $# -gt 0 ]; do
  case "$1" in -X) m="$2"; shift 2 ;; https://*|http://*) url="$1"; shift ;; *) shift ;; esac
done
echo "$m $url" >>"$CURL_LOG"
case "$m" in POST) printf '%s' "$CURL_POST" ;; PUT) printf '%s' "${CURL_PUT:-000}" ;; *) printf 000 ;; esac
CURL
printf '#!/bin/sh\nexit 0\n' >"$G/bin/sleep"
chmod +x "$G/bin"/*

guest_run() {  # script post-code put-code -> $OUT $RC, curl calls in $G/curl.log
  : >"$G/curl.log"
  OUT="$(CURL_LOG="$G/curl.log" CURL_POST="$2" CURL_PUT="$3" PATH="$G/bin:${PATH}" sh "$1" 2>&1)"
  RC=$?
}
guest_cases() {  # label script
  guest_run "$2" 201 ""
  if [ "$RC" -eq 0 ] && ! grep -q '^PUT' "$G/curl.log"; then ok "$1 handoff: 201 is delivered, nothing replaced"
  else bad "$1 handoff: 201 is delivered, nothing replaced" "rc=${RC}; $(tr '\n' ' ' <"$G/curl.log")"; fi

  guest_run "$2" 409 200
  if [ "$RC" -eq 0 ] && grep -q "^PUT .*/secrets/${VM}-kubeconfig$" "$G/curl.log"; then
    ok "$1 handoff: 409 replaces the stale Secret with this guest's copy"
  else bad "$1 handoff: 409 replaces the stale Secret with this guest's copy" "rc=${RC}; calls: $(tr '\n' ' ' <"$G/curl.log")"; fi

  guest_run "$2" 409 403
  if [ "$RC" -ne 0 ]; then ok "$1 handoff: 409 with the replace refused is a failure, not a success"
  else bad "$1 handoff: 409 with the replace refused is a failure, not a success" "rc=0; calls: $(tr '\n' ' ' <"$G/curl.log")"; fi
}

# Ubuntu lane: handoff.sh as create wrote it into the cloud-init Secret above.
if [ -s "$USERDATA" ]; then
  awk '/^  - path: \/usr\/local\/bin\/handoff.sh$/ {f=1; next}
       f && /^    content: \|$/ {c=1; next}
       f && c && /^      / {sub(/^      /, ""); print; next}
       f && c {exit}' "$USERDATA" \
    | sed -e "s#/etc/rancher/k3s/k3s.yaml#$G/k3s.yaml#g" -e "s#/run/#$G/run/#g" >"$G/ubuntu-handoff.sh"
  if grep -q 'secrets' "$G/ubuntu-handoff.sh"; then
    guest_cases "ubuntu" "$G/ubuntu-handoff.sh"
  else
    bad "ubuntu handoff.sh extracted from the generated cloud-config" "no handoff script in ${USERDATA}"
  fi
else
  bad "ubuntu handoff.sh extracted from the generated cloud-config" "create wrote no cloud-init Secret"
fi

# MicroOS lane: the profile's handoff script, as the guest's driver runs it.
if [ -f "$PROFILE" ]; then
  mkdir -p "$G/h"
  printf 'PREFIX=%s\nBEACON_API=https://api.invalid:6443\nBEACON_NS=tockmox-test\n' "$VM" >"$G/h/env"
  printf 'stub-token' >"$G/h/beacon.token"
  # shellcheck source=provision/profiles/microos.sh
  ( . "$PROFILE" && microos_handoff ) \
    | sed -e "s#^H=/var/lib/tockmox-harness#H=$G/h#" -e '/^export PATH=/d' \
          -e "s#/etc/rancher/k3s/k3s.yaml#$G/k3s.yaml#g" -e "s#/run/#$G/run/#g" >"$G/microos-handoff.sh"
  # The MicroOS script is bash; guest_run uses sh, so run it through bash.
  sed -i.bak '1s#.*#\#!/usr/bin/env bash#' "$G/microos-handoff.sh"
  guest_run_bash() { : >"$G/curl.log"; OUT="$(CURL_LOG="$G/curl.log" CURL_POST="$2" CURL_PUT="$3" PATH="$G/bin:${PATH}" bash "$1" 2>&1)"; RC=$?; }
  guest_run() { guest_run_bash "$@"; }
  guest_cases "microos" "$G/microos-handoff.sh"
else
  bad "the microos profile is present" "not found at ${PROFILE}"
fi

# ---- clause 3: destroy and the harness Secrets -----------------------------
S="${TMP}/destroy-clean"; new_state "$S"; seed_stale "$S"; : >"$S/secrets/${VM}-cloudinit"
run_tc "$S" destroy
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'ARTEFACT: secrets owned by' \
   && [ -z "$(secrets_left "$S")" ]; then
  ok "destroy removes harness Secrets and counts them to zero"
else
  bad "destroy removes harness Secrets and counts them to zero" "rc=${RC}; left: $(secrets_left "$S"); secrets ARTEFACT: $(printf '%s' "$OUT" | grep -c 'ARTEFACT: secrets')"
fi

# TM-0587: destroy is scoped to its own VM. Another VM's Secrets in the same
# namespace (a person's, an agent's, an earlier run's) must survive it.
S="${TMP}/destroy-scoped"; new_state "$S"; seed_stale "$S"; : >"$S/secrets/${VM}-cloudinit"
: >"$S/secrets/someone-else-01-kubeconfig"; : >"$S/secrets/someone-else-01-cloudinit"
run_tc "$S" destroy
left="$(secrets_left "$S" | tr '\n' ' ')"
if [ "$RC" -eq 0 ] && printf '%s' "$left" | grep -q 'someone-else-01-kubeconfig' \
   && printf '%s' "$left" | grep -q 'someone-else-01-cloudinit' && ! printf '%s' "$left" | grep -q "${VM}-"; then
  ok "destroy removes its own VM's Secrets and leaves another VM's alone"
else
  bad "destroy removes its own VM's Secrets and leaves another VM's alone" "rc=${RC}; left: ${left}"
fi

# reset is the namespace-wide sweep and refuses without its confirmation.
S="${TMP}/reset-unconfirmed"; new_state "$S"; : >"$S/secrets/someone-else-01-kubeconfig"
run_tc "$S" reset
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'REFUSING: reset deletes EVERY VM' \
   && [ -n "$(secrets_left "$S")" ]; then
  ok "reset refuses without --every-vm-in-<namespace> and deletes nothing"
else
  bad "reset refuses without --every-vm-in-<namespace> and deletes nothing" "rc=${RC}; left: $(secrets_left "$S")"
fi

S="${TMP}/destroy-deny"; new_state "$S"; seed_stale "$S"; : >"$S/deny-delete"
run_tc "$S" destroy
if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q 'RESULT:   PASS' \
   && printf '%s' "$OUT" | grep -q 'Forbidden'; then
  ok "destroy fails, and shows the error, when a Secret delete is refused"
else
  bad "destroy fails, and shows the error, when a Secret delete is refused" "rc=${RC}; $(printf '%s' "$OUT" | grep RESULT | tr '\n' ' ')"
fi

S="${TMP}/destroy-sticky"; new_state "$S"; seed_stale "$S"; : >"$S/sticky"
run_tc "$S" destroy
if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q 'RESULT:   PASS'; then
  ok "destroy fails when harness Secrets survive a delete that returned 0"
else
  bad "destroy fails when harness Secrets survive a delete that returned 0" "rc=${RC}; $(printf '%s' "$OUT" | grep RESULT | tr '\n' ' ')"
fi

# ---- TM-0797: every call names a cluster, and an empty name is refused ------
# The stub records each invocation. Every one must carry --context; `config`
# subcommands that only read or edit the guest's kubeconfig FILE are the
# recorded exemption (they cannot take a cluster).
ctxless() {  # calls-file -> the calls that named no cluster
  grep -vE -- '--context[= ]' "$1" | grep -vE '^config (view|unset|set-cluster|current-context)' || true
}
for S in "${TMP}/create-replace" "${TMP}/destroy-clean"; do
  n="$(basename "$S")"
  bare="$(ctxless "$S/calls")"
  if [ -s "$S/calls" ] && [ -z "$bare" ] \
     && grep -q -- '--context[= ]stub-substrate' "$S/calls" \
     && ! grep -qE -- '--context(=| )(-|$)' "$S/calls"; then
    ok "${n}: every kubectl call named a context, the hypervisor ones the required substrate context"
  else
    bad "${n}: every kubectl call named a context, the hypervisor ones the required substrate context" \
        "$(printf '%s' "$bare" | head -3 | tr '\n' '|')"
  fi
done

# TM-0849: the secret handoff copies the token into the guest, so anything but a
# ServiceAccount of the disposable namespace is refused before any VM exists.
jwt() { printf 'eyJhbGciOiJub25lIn0.%s.sig' "$(printf '{"sub":"%s"}' "$1" | base64 | tr -d '=\n' | tr '+/' '-_')"; }
for case_ in "admin:$(jwt 'system:admin')" "other-ns:$(jwt 'system:serviceaccount:default:harvester-admin')" "opaque:not-a-jwt-token"; do
  n="${case_%%:*}"; tok="${case_#*:}"
  S="${TMP}/tok-${n}"; new_state "$S"; printf '%s' "$tok" > "$S/token"
  run_tc "$S" create
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'copies this kubeconfig.s token into the guest' \
     && ! grep -q 'apply' "$S/calls" && [ ! -f "$S/userdata" ]; then
    ok "secret handoff refuses a ${n} token before any VM or cloud-init exists"
  else
    bad "secret handoff refuses a ${n} token before any VM or cloud-init exists" "rc=$RC $(printf '%s' "$OUT" | tail -2 | tr '\n' '|')"
  fi
done

for verb in create destroy exec; do
  S="${TMP}/noctx-${verb}"; new_state "$S"
  SUBSTRATE_CTX="" run_tc "$S" "$verb"
  if [ "$RC" -ne 0 ] && [ ! -s "$S/calls" ] && printf '%s' "$OUT" | grep -q 'TOCKMOX_SUBSTRATE_CONTEXT'; then
    ok "${verb} with an empty substrate context refuses before any kubectl call"
  else
    bad "${verb} with an empty substrate context refuses before any kubectl call" \
        "rc=${RC}; $(wc -l <"$S/calls" 2>/dev/null | tr -d ' ') call(s) made; $(printf '%s' "$OUT" | tail -1)"
  fi
done

if grep -h 'STUB-UNHANDLED' "$TMP"/*/log 2>/dev/null | grep -q .; then
  printf 'note: calls the kubectl stub did not model:\n'; grep -h 'STUB-UNHANDLED' "$TMP"/*/log | sort -u | sed 's/^/  /'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

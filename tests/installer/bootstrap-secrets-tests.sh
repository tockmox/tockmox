#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups B1-B10: install/bootstrap-secrets.sh (TM-0277).
#
# HERMETIC. kubectl, helm, kubeseal, docker, age and openssl are SHIMS in
# lib/shims/, put in front of PATH for these runs only. The fake cluster is a
# directory. Nothing here reaches a network or a real cluster, and nothing here
# is evidence that the real controller, the real chart, real kubeseal or real
# ArgoCD behave the way the shims do. That is what the live greenfield run on
# the lab cluster is for, and it has not happened.
#
# WHAT MAKES THE PLAINTEXT ASSERTIONS MEAN SOMETHING. The openssl shim replaces
# ONLY `rand`, returning values that carry a known marker; the fake kubeseal
# never writes a value, only a hash of it. So a marker found anywhere in what a
# run left behind is a real leak, not an artefact of the fake. The sweep covers
# every file a run wrote (the site, the backup, the temp dir, the captured
# stdout and stderr, the call log) and excludes exactly two things: the
# INPUT files the test wrote itself, and the fake cluster's own storage, which
# legitimately holds the controller key, as a cluster does.
#
# Each block below was proved by mutation before it was trusted (see
# TM-0277's REPORT.md): break the behaviour, watch THAT block go red.

SHIMS="$HERE/lib/shims"
BS="$WORK/bootstrap"; mkdir -p "$BS"
REAL_OPENSSL="$(command -v openssl)"
KEY_MARKER_HEADER="# tockmox-sealed-secrets-key-backup v1"

# --------------------------------------------------------------- helpers
bs_case() {  # name  ->  a fresh work directory with a generated site inside
  CASE="$1"; D="$BS/$1"; BS_N=0
  rm -rf "$D"; mkdir -p "$D/state" "$D/tmp" "$D/inputs" "$D/out" "$D/backup"
  cp -R "$SITE_C/tockmox-site" "$D/site"
  : > "$D/state/calls.log"
  printf 'BACKUPPASSMARKER-1\n' > "$D/inputs/pass"
  printf 'NTFYPASSMARKER-1\n'   > "$D/inputs/ntfy"
}
# bs_run <args...>: runs the subcommand in $D, the calls log is per run.
BS_STATUS=0
bs_run() {
  BS_N=$((BS_N + 1))
  [ "$BS_N" -eq 1 ] || { cp "$D/state/calls.log" "$D/state/calls.$((BS_N - 1)).log"; : > "$D/state/calls.log"; }
  set +e
  ( cd "$D" && env PATH="$SHIMS:$PATH" FAKE_STATE="$D/state" REAL_OPENSSL="$REAL_OPENSSL" \
      TMPDIR="$D/tmp" NO_COLOR=1 ${FAKE_ENV:-} \
      bash "$INSTALLER" bootstrap-secrets "$@" ) >"$D/out/run$BS_N.stdout" 2>"$D/out/run$BS_N.stderr"
  BS_STATUS=$?
  set -e
}
# The flags almost every run shares: never a terminal, always a matching
# confirmation, a short wait so a broken wait fails fast.
bs_common() { printf '%s\n' --site "$D/site" --yes-context lab-test --yes-server https://192.0.2.10:6443 --no-prompt --wait-seconds 3; }
bs_common_args() { BS_COMMON=(--site "$D/site" --yes-context lab-test --yes-server https://192.0.2.10:6443 --no-prompt --wait-seconds 3); }
bs_calls() { grep -cE "$1" "$D/state/calls.log" || true; }
bs_out() { cat "$D/out/run$BS_N.stdout" "$D/out/run$BS_N.stderr"; }
bs_err() { cat "$D/out/run$BS_N.stderr"; }
bs_sealed() { ls "$D/site/secrets" | grep -c '\.sealed\.yaml$' || true; }
bs_sealed_sum() { ( cd "$D/site/secrets" && cat ./*.sealed.yaml 2>/dev/null | cksum ); }
bs_hash() {  # file key -> the hash the fake kubeseal recorded for that value
  awk -v k="$2:" '$1==k {n=split($2,a,"."); print a[n]}' "$D/site/secrets/$1"
}
bs_expected() { grep -oE '[a-z0-9-]+\.sealed\.yaml' "$REPO_ROOT/tools/mint-secrets.sh" | sort -u; }
bs_actual()   { ls "$D/site/secrets" | grep '\.sealed\.yaml$' | sort -u; }
# A cluster WRITE or read of cluster state. `kubectl config ...` is a local
# kubeconfig read and is deliberately not counted.
BS_CLUSTER_CALLS='^(helm|kubeseal) |^kubectl .*(get|create|apply|rollout)( |$)'
# Every marker, everywhere a run could have left one ... in the clear AND base64
# encoded. The second matters more than it looks: the Secret manifest a leak
# would write is `data:` base64, so a sweep for the raw marker alone passes a
# file that holds every credential. base64 depends on the byte offset, so the
# marker is encoded at all three alignments and the unstable edge characters
# are dropped from each needle.
bs_needles() {  # marker -> raw, then three base64 needles, one per line
  local m="$1" pad out h
  printf '%s\n' "$m"
  for pad in "" "x" "xx"; do
    out="$(printf '%s%s' "$pad" "$m" | "$REAL_OPENSSL" base64 -A)"
    case "${#pad}" in 0) h=0 ;; 1) h=2 ;; 2) h=3 ;; esac
    printf '%s\n' "${out:$h:$(( ${#out} - h - 4 ))}"
  done
}
bs_leaks() {  # marker -> number of files under the case dir holding it in any form
  bs_needles "$1" > "$D/needles.txt"   # outside every swept directory's inputs? no: swept, but holds only the MARKER
  grep -rlF -f "$D/needles.txt" "$D" --exclude-dir=inputs --exclude-dir=cluster --exclude=needles.txt 2>/dev/null | wc -l | tr -d ' '
}
bs_leftovers() {
  { find "$D/tmp" -type f; find "$D/site/secrets" -name '.mint.*'; find "$D/backup" -name '*.tmp.*'; } 2>/dev/null | wc -l | tr -d ' '
}
FULL_FLAGS=(--with-litellm --with-apprise --with-tockmox-ui --with-eval-gateway)

# ===================================================================== B1
path_begin "B1" "bootstrap-secrets, mode new: a first run seals every credential"
parity_caveat \
  "Every cluster tool is a shim: this proves the script's own logic and the shape of its calls." \
  "It is NOT evidence that the real chart installs, that real kubeseal accepts these manifests," \
  "or that ArgoCD delivers the result. The live greenfield run has not happened."
does_not_prove \
  "that the encrypted key backup restores on a real controller (only that it round-trips through openssl)" \
  "that the go-template export renders under a real kubectl against real Secrets" \
  "that a sealed file from this path decrypts in a cluster" \
  "the interactive context prompt (a terminal is needed; every run here uses --yes-context)"

bs_case first; bs_common_args
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"

assert_artifact \
  "the run reports success in its own words, not by exit status alone" \
  "bs_out | grep -c '^  .*[0-9]* sealed file(s) in '" \
  "1"
assert_artifact \
  "a first run seals exactly the files mint-secrets.sh knows how to make (16)" \
  "diff <(bs_expected) <(bs_actual) >/dev/null && bs_actual | wc -l | tr -d ' '" \
  "16"
assert_artifact \
  "authentik/authentik-postgres carry ONE value (sealed hashes equal)" \
  "[ \"\$(bs_hash authentik.sealed.yaml AUTHENTIK_POSTGRESQL__PASSWORD)\" = \"\$(bs_hash authentik-postgres.sealed.yaml password)\" ] && [ -n \"\$(bs_hash authentik.sealed.yaml AUTHENTIK_POSTGRESQL__PASSWORD)\" ] && echo matched" \
  "matched"
assert_artifact \
  "sso holds the same three values its three consoles hold" \
  "[ \"\$(bs_hash sso.sealed.yaml GRAFANA_CLIENT_SECRET)\" = \"\$(bs_hash sso-grafana.sealed.yaml client-secret)\" ] && [ \"\$(bs_hash sso.sealed.yaml OPENWEBUI_CLIENT_SECRET)\" = \"\$(bs_hash sso-openwebui.sealed.yaml client-secret)\" ] && [ \"\$(bs_hash sso.sealed.yaml ARGO_CLIENT_SECRET)\" = \"\$(bs_hash sso-argo.sealed.yaml client-secret)\" ] && echo matched" \
  "matched"
assert_artifact \
  "the controller is installed once, at the pinned chart and image" \
  "grep '^helm upgrade' '$D/state/calls.log' | grep -o -- '--version 2.20.0\\|image.tag=0.40.0\\|fullnameOverride=sealed-secrets-controller' | sort | tr '\\n' ' '" \
  "--version 2.20.0 fullnameOverride=sealed-secrets-controller image.tag=0.40.0 "
assert_artifact \
  "exactly one install call" \
  "bs_calls '^helm upgrade --install'" \
  "1"
assert_artifact \
  "the public certificate is kept with the site" \
  "grep -c FAKECERT '$D/site/secrets/sealed-secrets-cert.pem'" \
  "1"
assert_artifact \
  "the key backup is openssl ciphertext (Salted__ magic), not YAML" \
  "head -c 8 '$D/backup/key.enc'" \
  "Salted__"
assert_artifact \
  "and it decrypts, with an independent openssl, to a Tockmox key backup" \
  "'$REAL_OPENSSL' enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass file:'$D/inputs/pass' -in '$D/backup/key.enc' | head -1" \
  "$KEY_MARKER_HEADER"
assert_artifact \
  "the backup was exported BEFORE the first credential was sealed" \
  "awk '/go-template/ && !e {e=NR} /^kubeseal sealed/ && !s {s=NR} END {print (e && s && e < s) ? \"backup first\" : \"WRONG ORDER e=\" e \" s=\" s}' '$D/state/calls.log'" \
  "backup first"
assert_artifact \
  "the seeded generator was used (positive control for the sweeps below)" \
  "[ \"\$(cat '$D/state/rand.count')\" -ge 10 ] && echo seeded" \
  "seeded"
assert_artifact \
  "no generated credential value appears in anything the run wrote or printed" \
  "bs_leaks SECRETMARKER" \
  "0"
assert_artifact \
  "the ntfy password appears nowhere but the file the test gave it" \
  "bs_leaks NTFYPASSMARKER" \
  "0"
assert_artifact \
  "the backup passphrase appears nowhere but the file the test gave it" \
  "bs_leaks BACKUPPASSMARKER" \
  "0"
assert_artifact \
  "the controller's private key appears nowhere outside the (fake) cluster: not in the backup, the site, stdout or the call log" \
  "bs_leaks KEYMARKER" \
  "0"
assert_artifact \
  "no temp file, staging directory or partial backup is left behind" \
  "bs_leftovers" \
  "0"

# ===================================================================== B2
path_begin "B2" "bootstrap-secrets: the same command again changes nothing"
BEFORE_SUM="$(bs_sealed_sum)"; BACKUP_SUM="$(cksum < "$D/backup/key.enc")"; CERT_SUM="$(cksum < "$D/site/secrets/sealed-secrets-cert.pem")"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "the second run reports the resume, not a fresh install" \
  "bs_out | grep -c 'resuming: helm release'" \
  "1"
assert_artifact \
  "every sealed file is byte-identical after the second run" \
  "[ \"\$(bs_sealed_sum)\" = '$BEFORE_SUM' ] && echo identical" \
  "identical"
assert_artifact \
  "no value was generated at all (openssl rand invoked 0 times this run)" \
  "bs_calls '^openssl rand'" \
  "0"
assert_artifact \
  "nothing was sealed (kubeseal sealed 0 times this run)" \
  "bs_calls '^kubeseal sealed'" \
  "0"
assert_artifact \
  "the controller was not touched (no helm install or upgrade)" \
  "bs_calls '^helm upgrade'" \
  "0"
assert_artifact \
  "the existing key backup was kept, not overwritten" \
  "[ \"\$(cksum < '$D/backup/key.enc')\" = '$BACKUP_SUM' ] && echo kept" \
  "kept"
assert_artifact \
  "the saved certificate is unchanged" \
  "[ \"\$(cksum < '$D/site/secrets/sealed-secrets-cert.pem')\" = '$CERT_SUM' ] && echo kept" \
  "kept"
assert_artifact \
  "mint-secrets says it minted nothing" \
  "bs_out | grep -c '^MINTED (0)'" \
  "1"
assert_artifact \
  "still no credential value anywhere after two runs" \
  "bs_leaks SECRETMARKER" \
  "0"

# ===================================================================== B3
path_begin "B3" "bootstrap-secrets: a half-present matched pair is refused, before anything else"
rm -f "$D/site/secrets/authentik-postgres.sealed.yaml"
BEFORE_SUM="$(bs_sealed_sum)"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "the refusal names the file that exists and the one that does not" \
  "bs_err | grep -c 'REFUSING: authentik.sealed.yaml exists and authentik-postgres.sealed.yaml does not'" \
  "1"
assert_artifact \
  "it says what to do, and that the choice rotates the pair" \
  "bs_err | grep -c 'ROTATES the pair'" \
  "1"
assert_artifact \
  "nothing was regenerated (openssl rand invoked 0 times)" \
  "bs_calls '^openssl rand'" \
  "0"
assert_artifact \
  "no file was created or changed" \
  "[ \"\$(bs_sealed_sum)\" = '$BEFORE_SUM' ] && [ \"\$(bs_sealed)\" = 15 ] && echo untouched" \
  "untouched"
assert_artifact \
  "the cluster was not contacted: no helm, no kubeseal, no get/create/apply" \
  "bs_calls '$BS_CLUSTER_CALLS'" \
  "0"
# The other half, deleted from the OTHER side: sso alone missing.
cp "$D/site/secrets/authentik.sealed.yaml" "$D/inputs/keep"   # (sealed ciphertext; not a secret)
rm -f "$D/site/secrets/authentik.sealed.yaml"                # now BOTH authentik halves are gone
rm -f "$D/site/secrets/sso.sealed.yaml"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "sso.sealed.yaml missing while its three consoles' halves exist is refused, once per pair" \
  "bs_err | grep -c 'REFUSING: sso-.*exists and sso.sealed.yaml does not'" \
  "3"
# The advice works: delete the consoles' halves too and the pair is rotated whole.
OLD_AK="$(bs_hash authentik-postgres.sealed.yaml password 2>/dev/null || true)"
rm -f "$D/site/secrets/sso-grafana.sealed.yaml" "$D/site/secrets/sso-openwebui.sealed.yaml" "$D/site/secrets/sso-argo.sealed.yaml"
OLD_GRAF_SEALED_BEFORE="$(bs_hash sso-grafana.sealed.yaml client-secret 2>/dev/null || true)"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "after deleting a whole pair, the re-run completes all 16 again" \
  "diff <(bs_expected) <(bs_actual) >/dev/null && bs_actual | wc -l | tr -d ' '" \
  "16"
assert_artifact \
  "and the re-minted pair is matched again, on a NEW value" \
  "n=\$(bs_hash authentik.sealed.yaml AUTHENTIK_POSTGRESQL__PASSWORD); [ \"\$n\" = \"\$(bs_hash authentik-postgres.sealed.yaml password)\" ] && [ \"\$n\" != '$OLD_AK' ] && [ \"\$(bs_hash sso.sealed.yaml GRAFANA_CLIENT_SECRET)\" = \"\$(bs_hash sso-grafana.sealed.yaml client-secret)\" ] && echo rotated-matched" \
  "rotated-matched"
assert_artifact \
  "the files the operator did NOT delete were not regenerated (ntfy is still the first run's)" \
  "bs_calls '^kubeseal sealed .*ntfy'" \
  "0"

# ===================================================================== B4
path_begin "B4" "bootstrap-secrets: a failure mid-run leaves nothing half-paired, and the retry completes"
bs_case failmid; bs_common_args
FAKE_ENV="FAKE_KUBESEAL_FAIL_AT=4"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
FAKE_ENV=""
assert_artifact \
  "the run says sealing failed" \
  "bs_err | grep -c 'sealing .* failed'" \
  "1"
assert_artifact \
  "the fourth seal failed, so NO sealed file was committed (not the first three)" \
  "bs_sealed" \
  "0"
assert_artifact \
  "the staging directory and every temp file were removed on the failure path" \
  "bs_leftovers" \
  "0"
assert_artifact \
  "no plaintext on the failure path either" \
  "bs_leaks SECRETMARKER" \
  "0"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "the identical command, re-run, resumes the controller it installed and completes all 16" \
  "diff <(bs_expected) <(bs_actual) >/dev/null && bs_actual | wc -l | tr -d ' '" \
  "16"
assert_artifact \
  "and did not install the controller a second time" \
  "bs_calls '^helm upgrade'" \
  "0"

# ===================================================================== B5
path_begin "B5" "bootstrap-secrets: a context that does not match is refused before any cluster contact"
bs_case ctx; bs_common_args
bs_run --mode new --site "$D/site" --yes-context some-other-cluster --yes-server https://192.0.2.10:6443 --no-prompt --wait-seconds 3 \
  --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass"
assert_artifact \
  "the refusal names both contexts" \
  "bs_err | grep -c \"does not match the context in use, 'lab-test'\""  \
  "1"
assert_artifact \
  "no cluster read or write of any kind was attempted" \
  "bs_calls '$BS_CLUSTER_CALLS'" \
  "0"
assert_artifact \
  "no credential was generated, sealed or written, and no backup exists" \
  "[ \"\$(bs_sealed)\" = 0 ] && [ ! -e '$D/backup/key.enc' ] && echo nothing" \
  "nothing"
bs_run --mode new --site "$D/site" --no-prompt --wait-seconds 3 \
  --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass"
assert_artifact \
  "with no --yes-context and no terminal it refuses, and says how to confirm" \
  "bs_err | grep -c \"Re-run with --yes-context 'lab-test'\"" \
  "1"
assert_artifact \
  "still no cluster contact" \
  "bs_calls '$BS_CLUSTER_CALLS'" \
  "0"

assert_artifact \
  "a matching --yes-context WITHOUT --yes-server is refused, and the server is named" \
  "( bs_run --mode new --site '$D/site' --yes-context lab-test --no-prompt --backup-out '$D/backup/key.enc' --passphrase-file '$D/inputs/pass'; bs_err | grep -c \"Re-run with --yes-server 'https://192.0.2.10:6443'\" )" \
  "1"
assert_artifact \
  "a wrong --yes-server (right context name, different cluster) is refused" \
  "( bs_run --mode new --site '$D/site' --yes-context lab-test --yes-server https://198.51.100.7:6443 --no-prompt --backup-out '$D/backup/key.enc' --passphrase-file '$D/inputs/pass'; bs_err | grep -c \"does not match the API server in use, 'https://192.0.2.10:6443'\" )" \
  "1"
assert_artifact \
  "an EMPTY --context is refused, not defaulted to the current context (an unset variable expands to this)" \
  "( bs_run --mode new \"\${BS_COMMON[@]}\" --context '' --backup-out '$D/backup/key.enc' --passphrase-file '$D/inputs/pass'; bs_err | grep -c 'was given empty' )" \
  "1"
assert_artifact \
  "an empty --context as the LAST argument (no value at all) is refused the same way" \
  "( bs_run --mode new \"\${BS_COMMON[@]}\" --backup-out '$D/backup/key.enc' --passphrase-file '$D/inputs/pass' --context; bs_err | grep -c 'was given empty' )" \
  "1"
assert_artifact \
  "an empty --yes-context is refused, not treated as absent" \
  "( bs_run --mode new --site '$D/site' --yes-context '' --yes-server https://192.0.2.10:6443 --no-prompt --backup-out '$D/backup/key.enc' --passphrase-file '$D/inputs/pass'; bs_err | grep -c 'yes-context was given empty' )" \
  "1"
assert_artifact \
  "none of those refusals touched a cluster" \
  "bs_calls '$BS_CLUSTER_CALLS'" \
  "0"

# ===================================================================== B6
path_begin "B6" "bootstrap-secrets: an existing controller in another namespace is detected, reused and never reinstalled"
bs_case othernamespace; bs_common_args
mkdir -p "$D/state/cluster/keys/platform-secrets" "$D/state/cluster/ns"
printf 'platform-secrets sealed-ctl\n' > "$D/state/cluster/controller"
: > "$D/state/cluster/ns/platform-secrets"
printf 'crt=FAKECRT-preseeded\nkey=KEYMARKER-preseeded\n' > "$D/state/cluster/keys/platform-secrets/sealed-secrets-key-old"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass"
assert_artifact \
  "--mode new refuses when a controller already runs, and points at --mode reuse" \
  "bs_err | grep -c 'would install a second one'" \
  "1"
assert_artifact \
  "and installed nothing" \
  "bs_calls '^helm upgrade'" \
  "0"
# ADOPTION IS CONFIRMED. Three refusals first, each with the fake cluster's key
# store fingerprinted before and after: nothing may be created, and the certificate
# is not even fetched.
KEYS_BEFORE="$(find "$D/state/cluster/keys" -type f | sort | xargs cksum)"
bs_run --mode reuse "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass"
assert_artifact \
  "--mode reuse without --yes-adopt refuses, names the controller, and shows how to confirm" \
  "bs_err | grep -c \"Re-run with --yes-adopt 'platform-secrets/sealed-ctl'\"" \
  "1"
assert_artifact \
  "and it printed which controller it found, its image and its key count before refusing" \
  "bs_out | grep -cE 'controller  platform-secrets/sealed-ctl|image       docker.io/bitnami/sealed-secrets-controller:0.40.0|keys        1 sealing key'" \
  "3"
bs_run --mode reuse "${BS_COMMON[@]}" --yes-adopt kube-system/some-other --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass"
assert_artifact \
  "--yes-adopt naming a different controller is refused" \
  "bs_err | grep -c \"does not match the controller found, 'platform-secrets/sealed-ctl'\"" \
  "1"
assert_artifact \
  "neither refusal fetched a certificate, sealed, installed or wrote a file" \
  "bs_calls '^(kubeseal|helm) '; [ \"\$(bs_sealed)\" = 0 ] && [ ! -e '$D/backup/key.enc' ] && echo nothing" \
  "0
nothing"
bs_run --mode reuse "${BS_COMMON[@]}" --yes-adopt platform-secrets/sealed-ctl --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "adoption generated no second key: the key store is byte-for-byte what it was" \
  "[ \"\$(find '$D/state/cluster/keys' -type f | sort | xargs cksum)\" = '$KEYS_BEFORE' ] && echo unchanged" \
  "unchanged"
assert_artifact \
  "--mode reuse finds it by label and says where" \
  "bs_out | grep -c 'reusing platform-secrets/sealed-ctl'" \
  "1"
assert_artifact \
  "the certificate was fetched from THAT namespace and name" \
  "grep '^kubeseal --fetch-cert' '$D/state/calls.log' | grep -c -- '--controller-name sealed-ctl --controller-namespace platform-secrets'" \
  "1"
assert_artifact \
  "helm was never invoked at all: nothing was installed, upgraded or listed" \
  "bs_calls '^helm '" \
  "0"
assert_artifact \
  "all 16 credentials were sealed against the reused controller's certificate" \
  "diff <(bs_expected) <(bs_actual) >/dev/null && bs_actual | wc -l | tr -d ' '" \
  "16"
assert_artifact \
  "the reused controller's key was exported encrypted (and not readable in the backup)" \
  "[ \"\$(head -c 8 '$D/backup/key.enc')\" = Salted__ ] && grep -c KEYMARKER '$D/backup/key.enc' || true" \
  "0"
assert_artifact \
  "explicit names that match nothing are refused rather than assumed" \
  "( bs_run --mode reuse \"\${BS_COMMON[@]}\" --yes-adopt kube-system/nope --controller-namespace kube-system --controller-name nope --i-have-a-key-backup; bs_err | grep -c 'no deployment nope in namespace kube-system' )" \
  "1"
assert_artifact \
  "with the controller gone but its key left behind, --mode reuse refuses rather than guess" \
  "( rm -f '$D/state/cluster/controller'; bs_run --mode reuse \"\${BS_COMMON[@]}\" --i-have-a-key-backup; bs_err | grep -c 'left its key' )" \
  "1"
assert_artifact \
  "--mode new in that state refuses too: a second key beside the leftover is the unrecoverable case" \
  "( bs_run --mode new \"\${BS_COMMON[@]}\" --i-have-a-key-backup; bs_err | grep -c 'sealing key Secret(s) exist' ; bs_calls '^helm upgrade' )" \
  "1
0"
assert_artifact \
  "in a cluster with no controller and no key, --mode reuse refuses and names the other modes" \
  "( rm -rf '$D/state/cluster/keys'; bs_run --mode reuse \"\${BS_COMMON[@]}\" --i-have-a-key-backup; bs_err | grep -c 'use --mode new' )" \
  "1"

# ===================================================================== B7
path_begin "B7" "bootstrap-secrets, mode recover: the key is restored BEFORE the controller starts"
bs_case recover; bs_common_args
# The site (with its sealed files) and the backup come from the FIRST case: this
# is a rebuilt cluster, and the files already in git must still open.
rm -rf "$D/site"; cp -R "$BS/first/site" "$D/site"
cp "$BS/first/inputs/pass" "$D/inputs/pass"
ORIG_KEY="$(sed -n 's/^key=//p' "$BS/first/state/cluster/keys/kube-system/"* | head -1)"
SUM_BEFORE="$(bs_sealed_sum)"
printf 'WRONGPASS\n' > "$D/inputs/wrong"
bs_run --mode recover "${BS_COMMON[@]}" --key-backup "$BS/first/backup/key.enc" --passphrase-file "$D/inputs/wrong"
assert_artifact \
  "a wrong passphrase is refused with a reason" \
  "bs_err | grep -c 'did not decrypt to a Tockmox key backup'" \
  "1"
assert_artifact \
  "and the controller was not installed" \
  "bs_calls '^helm '" \
  "0"
bs_run --mode recover "${BS_COMMON[@]}" --key-backup "$BS/first/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  "${FULL_FLAGS[@]}" --ntfy-password-file "$D/inputs/ntfy"
assert_artifact \
  "the key from the old cluster is now in the new one, unchanged" \
  "[ \"\$(sed -n 's/^key=//p' '$D/state/cluster/keys/kube-system/'* | head -1)\" = '$ORIG_KEY' ] && echo restored" \
  "restored"
assert_artifact \
  "the key was created BEFORE the controller install (the order is the point)" \
  "awk '/^kubectl .*create -f -/ && !c {c=NR} /^helm upgrade/ && !h {h=NR} END {print (c && h && c < h) ? \"restore first\" : \"WRONG ORDER c=\" c \" h=\" h}' '$D/state/calls.log'" \
  "restore first"
assert_artifact \
  "the controller did not generate a second key over the restored one" \
  "ls '$D/state/cluster/keys/kube-system' | wc -l | tr -d ' '" \
  "1"
assert_artifact \
  "the files already in the site repository were left byte-identical" \
  "[ \"\$(cd '$D/site/secrets' && cat \$(ls ./*.sealed.yaml | sort) | cksum)\" = \"\$(cd '$BS/first/site/secrets' && cat \$(ls ./*.sealed.yaml | sort) | cksum)\" ] && echo identical" \
  "identical"
assert_artifact \
  "and nothing was regenerated for them" \
  "bs_calls '^openssl rand'" \
  "0"
assert_artifact \
  "no key material outside the fake cluster and the (encrypted) input backup" \
  "bs_leaks KEYMARKER" \
  "0"

# ===================================================================== B8
path_begin "B8" "bootstrap-secrets: no way to encrypt the key backup means no backup, and no cluster change"
bs_case noenc; bs_common_args
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc"
assert_artifact \
  "without a passphrase file or an age recipient it refuses rather than write plaintext" \
  "bs_err | grep -c 'no way to encrypt the key backup'" \
  "1"
assert_artifact \
  "nothing was written where the backup would go" \
  "ls '$D/backup' | wc -l | tr -d ' '" \
  "0"
assert_artifact \
  "and the cluster was never contacted" \
  "bs_calls '$BS_CLUSTER_CALLS'" \
  "0"
bs_run --mode new "${BS_COMMON[@]}" --passphrase-file "$D/inputs/pass"
assert_artifact \
  "no --backup-out and no declaration is refused, with the reason" \
  "bs_err | grep -c \"a backup of the controller's private key is required\"" \
  "1"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/site/key.enc" --passphrase-file "$D/inputs/pass"
assert_artifact \
  "a backup destination inside the site repository is refused" \
  "bs_err | grep -c 'inside the site repository'" \
  "1"
bs_run --mode new "${BS_COMMON[@]}" --i-have-a-key-backup --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "--i-have-a-key-backup proceeds and states in the summary that this run wrote none" \
  "bs_out | grep -c 'NOT WRITTEN BY THIS RUN'" \
  "1"
assert_artifact \
  "and it really wrote none: no export call was made" \
  "bs_calls 'go-template'" \
  "0"

# ===================================================================== B9
path_begin "B9" "bootstrap-secrets: refusals that need no cluster, and --dry-run"
bs_case misc; bs_common_args
bs_run "${BS_COMMON[@]}"
assert_artifact \
  "--mode is required, and the message names all three" \
  "bs_err | grep -c 'new .*a fresh cluster'" \
  "1"
bs_run --mode new "${BS_COMMON[@]}" --dry-run --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" "${FULL_FLAGS[@]}" --ntfy-password-file "$D/inputs/ntfy"
assert_artifact \
  "--dry-run prints the plan" \
  "bs_out | grep -c 'Plan (dry run, nothing changed)'" \
  "1"
assert_artifact \
  "--dry-run installs, creates, seals and applies nothing" \
  "bs_calls '^helm |^kubeseal |^kubectl .*(create|apply)( |\$)|go-template'" \
  "0"
assert_artifact \
  "--dry-run writes no sealed file, no backup and no certificate" \
  "[ \"\$(bs_sealed)\" = 0 ] && [ ! -e '$D/backup/key.enc' ] && [ ! -e '$D/site/secrets/sealed-secrets-cert.pem' ] && echo nothing" \
  "nothing"
printf 'namespaces:\n  ai: custom-ai\napps: {}\n' > "$D/site/site/values/policy.yaml"
bs_run --mode new "${BS_COMMON[@]}" --i-have-a-key-backup
assert_artifact \
  "a site that renames the credentials' namespaces is refused, naming the key" \
  "bs_err | grep -c 'ai: custom-ai'" \
  "1"
assert_artifact \
  "and that refusal touched no cluster" \
  "bs_calls '$BS_CLUSTER_CALLS'" \
  "0"

# ===================================================================== B9b
path_begin "B9b" "bootstrap-secrets: the ntfy password, against a dollar sign and bcrypt's 72-byte limit (TM-0631)"
does_not_prove \
  "what a real ntfy does with the resulting hash (the shim derives a fake one from the password)" \
  "the interactive prompt's re-ask on a long password (needs a terminal; the logic is the same function)"
bs_case ntfy-dollar; bs_common_args
printf 'pa$$w0rd$HOME$1\n' > "$D/inputs/ntfy"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy"
assert_artifact \
  "a password with dollar signs seals the ntfy Secret, and is not expanded on the way" \
  "[ \"\$BS_STATUS\" = 0 ] && [ -e '$D/site/secrets/ntfy-auth.sealed.yaml' ] && echo sealed" \
  "sealed"
bs_case ntfy-long; bs_common_args
python3 -c 'print("a" * 73)' > "$D/inputs/ntfy"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy"
assert_artifact \
  "a 73-byte password is refused, naming bcrypt's 72-byte limit" \
  "bs_err | grep -c 'is 73 bytes; ntfy hashes it with bcrypt, which cannot take more than 72'" \
  "1"
assert_artifact \
  "and the refusal comes before any cluster change (bootstrap-secrets runs mint-secrets --dry-run as a preflight, and the check runs there too)" \
  "bs_calls '$BS_CLUSTER_CALLS'" \
  "0"
bs_case ntfy-multibyte; bs_common_args
python3 -c 'print("\u00e9" * 40)' > "$D/inputs/ntfy"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy"
assert_artifact \
  "forty two-byte characters are 80 bytes, and are refused as such" \
  "bs_err | grep -c 'is 80 bytes'" \
  "1"

# ===================================================================== B10
path_begin "B10" "bootstrap-secrets: the age branch (against a FAKE age: invocation shape only)"
bs_case agecase; bs_common_args
printf 'fake-age-identity\n' > "$D/inputs/identity"
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.age" --age-recipient age1fakerecipient \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "the export is piped through age -r with the given recipient" \
  "bs_calls '^age -r age1fakerecipient\$'" \
  "1"
assert_artifact \
  "the file is age-shaped, and holds no readable key" \
  "head -c 21 '$D/backup/key.age'; echo; grep -c KEYMARKER '$D/backup/key.age' || true" \
  "age-encryption.org/v1
0"
assert_artifact \
  "it says plainly that age output cannot be verified without the identity" \
  "bs_out | grep -c 'NOT VERIFIED'" \
  "1"
bs_case agerecover; bs_common_args
rm -rf "$D/site"; cp -R "$BS/agecase/site" "$D/site"
printf 'fake-age-identity\n' > "$D/inputs/identity"
bs_run --mode recover "${BS_COMMON[@]}" --key-backup "$BS/agecase/backup/key.age" --age-identity "$D/inputs/identity" \
  --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "recover decrypts with age -d -i and restores the key before installing" \
  "bs_calls '^age -d -i '; awk '/^kubectl .*create -f -/ && !c {c=NR} /^helm upgrade/ && !h {h=NR} END {print (c && h && c < h) ? \"restore first\" : \"WRONG ORDER\"}' '$D/state/calls.log'" \
  "1
restore first"

# ===================================================================== B13
path_begin "B13" "bootstrap-secrets: the model gateway's credentials are minted by default, and --without-litellm leaves them out (TM-0460)"
parity_caveat \
  "Same shims as B1: this proves which files the script asks kubeseal for, not that a cluster accepts them."
bs_case gwdefault; bs_common_args
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy"
assert_artifact \
  "with NO credential flag the run seals the gateway's master key and database credential" \
  "ls '$D/site/secrets' | grep -cE '^litellm(-db)?\\.sealed\\.yaml$'" \
  "2"
assert_artifact \
  "and the gateway's two files are not reported NOT MINTED" \
  "bs_out | grep -c 'tockmox-litellm and tockmox-litellm-db ... not requested'" \
  "0"
bs_case gwoff; bs_common_args
bs_run --mode new "${BS_COMMON[@]}" --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" \
  --ntfy-password-file "$D/inputs/ntfy" --without-litellm
assert_artifact \
  "--without-litellm seals neither gateway file" \
  "ls '$D/site/secrets' | grep -cE '^litellm(-db)?\\.sealed\\.yaml$'" \
  "0"
assert_artifact \
  "and says so under NOT MINTED, naming the flag" \
  "bs_out | grep -c 'tockmox-litellm and tockmox-litellm-db ... not requested (--without-litellm)'" \
  "1"

# ===================================================================== B11
path_begin "B11" "bootstrap-secrets: an adopted controller (found by image, not label) is used twice and rotates nothing"
parity_caveat \
  "The controller and its labels are a fake: this proves the detection logic and the calls made." \
  "It is NOT evidence about how any real install labels its Deployment."
bs_case adopt; bs_common_args
mkdir -p "$D/state/cluster/keys/sealed-secrets" "$D/state/cluster/ns"
printf 'sealed-secrets sealed-secrets-controller unlabeled\n' > "$D/state/cluster/controller"
: > "$D/state/cluster/ns/sealed-secrets"
printf 'crt=FAKECRT-homelab\nkey=KEYMARKER-homelab\n' > "$D/state/cluster/keys/sealed-secrets/sealed-secrets-keyabcde"
KEYS_BEFORE="$(find "$D/state/cluster/keys" -type f | sort | xargs cksum)"
bs_run --mode reuse "${BS_COMMON[@]}" --yes-adopt sealed-secrets/sealed-secrets-controller \
  --backup-out "$D/backup/key.enc" --passphrase-file "$D/inputs/pass" --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "a controller with NO app.kubernetes.io/name label is still found (by its image) and adopted" \
  "bs_out | grep -c 'reusing sealed-secrets/sealed-secrets-controller'" \
  "1"
assert_artifact \
  "all 16 credentials were sealed and no key was created, changed or removed" \
  "bs_actual | wc -l | tr -d ' '; [ \"\$(find '$D/state/cluster/keys' -type f | sort | xargs cksum)\" = '$KEYS_BEFORE' ] && echo keys-unchanged" \
  "16
keys-unchanged"
assert_artifact \
  "nothing was installed and nothing was created in the cluster" \
  "bs_calls '^helm |^kubectl .*create '" \
  "0"
FIRST_SUM="$(bs_sealed_sum)"
bs_run --mode reuse "${BS_COMMON[@]}" --yes-adopt sealed-secrets/sealed-secrets-controller \
  --backup-out "$D/backup/key2.enc" --passphrase-file "$D/inputs/pass" --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}"
assert_artifact \
  "the second adopting run leaves every sealed file byte-identical" \
  "[ \"\$(bs_sealed_sum)\" = '$FIRST_SUM' ] && echo identical" \
  "identical"
assert_artifact \
  "and lists all 16 as kept existing, by name, rather than reporting success" \
  "bs_out | sed -n '/^ALREADY PRESENT/,\$p' | grep -c '\\.sealed\\.yaml'" \
  "16"
assert_artifact \
  "no credential was generated or sealed on the second run" \
  "bs_calls '^openssl rand|^kubeseal sealed'" \
  "0"

# ===================================================================== B12
path_begin "B12" "bootstrap-secrets: the interactive confirmations, driven through a real pseudo-terminal"
parity_caveat \
  "The terminal is a pty and the cluster is a fake. This proves the prompts ask what they say and" \
  "refuse a wrong answer; it does not prove a human reads them."
bs_pty() {  # answers-file, then the subcommand's args. Output in $D/out/pty.txt
  local ans="$1"; shift
  set +e
  ( cd "$D" && env PATH="$SHIMS:$PATH" FAKE_STATE="$D/state" REAL_OPENSSL="$REAL_OPENSSL" TMPDIR="$D/tmp" NO_COLOR=1 \
      python3 "$DRIVE" --answers "$ans" --timeout 60 -- bash "$INSTALLER" bootstrap-secrets "$@" ) > "$D/out/pty.txt" 2>&1
  BS_STATUS=$?
  set -e
}
bs_case ptyrun
mkdir -p "$D/state/cluster/keys/sealed-secrets" "$D/state/cluster/ns"
printf 'sealed-secrets sealed-secrets-controller\n' > "$D/state/cluster/controller"
printf 'crt=FAKECRT-pty\nkey=KEYMARKER-pty\n' > "$D/state/cluster/keys/sealed-secrets/sealed-secrets-keyabcde"
PTY_ARGS=(--mode reuse --site "$D/site" --wait-seconds 3 --i-have-a-key-backup --ntfy-password-file "$D/inputs/ntfy" "${FULL_FLAGS[@]}")
printf '%s\n' lab-test https://198.51.100.7:6443 > "$D/inputs/ans-wrong-server"
bs_pty "$D/inputs/ans-wrong-server" "${PTY_ARGS[@]}"
assert_artifact \
  "typing the right context and the WRONG server is refused, and nothing was contacted past config reads" \
  "grep -c 'not confirmed. Nothing was touched.' '$D/out/pty.txt'; bs_calls '$BS_CLUSTER_CALLS'" \
  "1
0"
printf '%s\n' lab-test https://192.0.2.10:6443 wrong/controller > "$D/inputs/ans-wrong-adopt"
bs_pty "$D/inputs/ans-wrong-adopt" "${PTY_ARGS[@]}"
assert_artifact \
  "right cluster, wrong controller typed at the adoption prompt: refused before any sealing" \
  "grep -c 'not confirmed. Nothing was installed or sealed.' '$D/out/pty.txt'; bs_calls '^kubeseal '; bs_sealed" \
  "1
0
0"
printf '%s\n' lab-test https://192.0.2.10:6443 sealed-secrets/sealed-secrets-controller > "$D/inputs/ans-right"
bs_pty "$D/inputs/ans-right" "${PTY_ARGS[@]}"
assert_artifact \
  "all three typed correctly: the run proceeds and seals all 16 against the adopted controller" \
  "bs_actual | wc -l | tr -d ' '" \
  "16"

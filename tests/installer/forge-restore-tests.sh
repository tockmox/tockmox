#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups R1-R12: install/forge-restore.sh, reached as
# `tockmox-install.sh --restore-from ...` and `tockmox-install.sh repair-forge`.
#
# HERMETIC. Every case is a refusal, or a dry run, and each one comes before any
# contact with a cluster: the assertion that matters is that the shims' call log
# holds no kubectl or helm call at all. The copy and the kit are REAL: a site
# repository committed and bundled with git, its SHA-256 written the way the off-site
# job writes it, and a kit encrypted with openssl the way bootstrap-forge writes it,
# carrying a sealing key backup encrypted the way bootstrap-secrets writes one. The
# path that installs and seeds a forge was run on a lab cluster; a
# shim that answered a forge would only prove that the shim agrees with the script.

RS="$WORK/restore"; mkdir -p "$RS"
# run.sh puts a failing `git` stub first on PATH for the generator's tests; these cases
# need the real one (the copy is a real bundle), so they take the stub back off.
RS_PATH="${PATH//$STUB:/}"
RS_URL="http://tockmox-forge-http.tockmox-forge.svc.cluster.local:3000/tockmox/site.git"
RS_SEAL_MARKER="# tockmox-sealed-secrets-key-backup v1"
RS_KIT_MARKER="# tockmox-recovery-kit v1"

rs_enc() { "$REAL_OPENSSL" enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:$1"; }
rs_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# rs_case NAME [external] [AGE_EPOCH] -> $D with inputs/{pass,wrongpass}, a bundle and its .sha256, and a kit
rs_case() {
  D="$RS/$1"; rm -rf "$D"; mkdir -p "$D/state" "$D/tmp" "$D/inputs" "$D/out" "$D/kits" "$D/media"
  cp -R "$SITE_C/tockmox-site" "$D/site"
  if [ "${2:-built-in}" = built-in ]; then
    grep -rl PLACEHOLDER_SITE_REPO_URL "$D/site" | while IFS= read -r f; do
      sed "s|PLACEHOLDER_SITE_REPO_URL|$RS_URL|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  fi
  when="${3:-$(date +%s)}"
  ( export PATH="$RS_PATH"; cd "$D/site" && git init -q -b main && git add -A \
      && GIT_AUTHOR_DATE="@$when +0000" GIT_COMMITTER_DATE="@$when +0000" \
         git -c user.name=t -c user.email=t@example.invalid commit -q -m "test site" )
  PATH="$RS_PATH" git -C "$D/site" bundle create "$D/media/site.bundle" HEAD refs/heads/main >/dev/null 2>&1
  printf '%s  site.bundle\n' "$(rs_sha "$D/media/site.bundle")" > "$D/media/site.bundle.sha256"
  printf 'KITPASS-%s\n' "$1" > "$D/inputs/pass"
  printf 'NOT-THE-PASS\n' > "$D/inputs/wrongpass"
  printf '%s\napiVersion: v1\nkind: Secret\n' "$RS_SEAL_MARKER" | rs_enc "$D/inputs/pass" > "$D/inputs/seal.enc"
  { printf '%s\ncreated: 20261102T000000Z\nsite: tockmox-site\nrepository: %s\n' "$RS_KIT_MARKER" "$RS_URL"
    printf '=== app.ini\n[security]\nSECRET_KEY = x\n=== forge-admin\ntockmox-admin\npw\n'
    printf '=== sealed-secrets.key.enc (base64)\n'; base64 < "$D/inputs/seal.enc"
    printf '=== end\n'; } | rs_enc "$D/inputs/pass" > "$D/kits/old.kit"
  : > "$D/state/calls.log"
}
RS_STATUS=0
rs_run() {
  set +e
  ( cd "$D" && env PATH="$SHIMS:$RS_PATH" FAKE_STATE="$D/state" REAL_OPENSSL="$REAL_OPENSSL" \
      TMPDIR="$D/tmp" NO_COLOR=1 bash "$INSTALLER" "$@" ) >"$D/out/stdout" 2>"$D/out/stderr"
  RS_STATUS=$?
  set -e
}
rs_err() { cat "$D/out/stderr"; }
rs_cluster_calls() { grep -cE '^(kubectl|helm) ' "$D/state/calls.log" || true; }
RS_KIT=(--kit kits/old.kit --passphrase-file inputs/pass --kit-out kits/new.kit)

# R1. A rebuild needs the kit: it carries the sealing key every SealedSecret needs.
rs_case r1
rs_run --restore-from file:media/site.bundle --kit-out kits/new.kit --passphrase-file inputs/pass --dry-run
assert_artifact "R1 a rebuild without --kit is refused, naming the sealing key" \
  "echo $RS_STATUS; rs_err | grep -c -- '--kit FILE is required'" "$(printf '1\n1')"

# R2. A copy carried in on media is checked against its SHA-256: a changed byte stops it.
rs_case r2
printf 'x' >> "$D/media/site.bundle"
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --dry-run
assert_artifact "R2 a tampered file copy is refused on its SHA-256" \
  "echo $RS_STATUS; rs_err | grep -c 'corrupt or was changed. Nothing was installed'" "$(printf '1\n1')"
assert_artifact "R2 ... before any kubectl or helm call" "rs_cluster_calls" "0"

# R3. A corrupt bundle whose checksum was recomputed still fails git's own check.
rs_case r3
# Cut off its last 100 bytes: the header survives (so `git bundle verify` alone would
# pass, measured) and the pack's objects and trailer do not.
head -c "$(( $(wc -c < "$D/media/site.bundle") - 100 ))" "$D/media/site.bundle" > "$D/media/cut.bundle"
printf '%s  site.bundle\n' "$(rs_sha "$D/media/cut.bundle")" > "$D/media/cut.bundle.sha256"
rs_run --restore-from file:media/cut.bundle "${RS_KIT[@]}" --dry-run
assert_artifact "R3 a cut-short bundle is refused (git reads every object, not only the header)" \
  "echo $RS_STATUS; rs_err | grep -c 'git does not accept the copy as a bundle'" "$(printf '1\n1')"

# R4. A copy with no checksum beside it, and none given, is not trusted.
rs_case r4; rm -f "$D/media/site.bundle.sha256"
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --dry-run
assert_artifact "R4 a file copy with no checksum is refused" \
  "echo $RS_STATUS; rs_err | grep -c 'not trusted unchecked'" "$(printf '1\n1')"

# R5. The wrong passphrase stops the run before anything is installed.
rs_case r5
rs_run --restore-from file:media/site.bundle --kit kits/old.kit --passphrase-file inputs/wrongpass --kit-out kits/new.kit --dry-run
assert_artifact "R5 a wrong kit passphrase is refused" \
  "echo $RS_STATUS; rs_err | grep -c 'the kit did not open whole'" "$(printf '1\n1')"
assert_artifact "R5 ... before any kubectl or helm call, and no new kit" \
  "rs_cluster_calls; [ -e '$D/kits/new.kit' ] && echo kit || echo no-kit" "$(printf '0\nno-kit')"

# R6. The kit opens but its sealing key backup does not open with the key given.
rs_case r6
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --key-passphrase-file inputs/wrongpass --dry-run
assert_artifact "R6 a sealing key backup that does not open is refused" \
  "echo $RS_STATUS; rs_err | grep -c 'sealing key backup does not open'" "$(printf '1\n1')"

# R7. A copy of a site generated for another forge is not a built-in-forge site.
rs_case r7 external
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --dry-run
assert_artifact "R7 a copy that does not name the built-in forge is refused" \
  "echo $RS_STATUS; rs_err | grep -c 'does not name the built-in forge'" "$(printf '1\n1')"

# R8. A good copy and kit: the dry run checks both, names the copy's age, writes nothing.
rs_case r8
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --site-out ./restored --dry-run
assert_artifact "R8 a dry run checks the copy and the kit and plans the rebuild" \
  "echo $RS_STATUS; grep -c 'file copy matches its SHA-256' '$D/out/stdout'; grep -c 'kit opened' '$D/out/stdout'; grep -c 'Plan (dry run, nothing changed)' '$D/out/stdout'" \
  "$(printf '0\n1\n1\n1')"
assert_artifact "R8 ... names the copy's age and says what is not restored" \
  "grep -c \"the copy's main: .* min old\" '$D/out/stdout'; grep -c 'review comments and the forge' '$D/out/stdout'" "$(printf '1\n1')"
assert_artifact "R8 ... with no kubectl or helm call and no new kit" \
  "rs_cluster_calls; [ -e '$D/kits/new.kit' ] && echo kit || echo no-kit" "$(printf '0\nno-kit')"

# R9. An old copy is named with its age and called out.
rs_case r9 built-in "$(( $(date +%s) - 3 * 86400 ))"
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --site-out ./restored --dry-run
assert_artifact "R9 a three-day-old copy is named with its age and called out" \
  "echo $RS_STATUS; grep -c '(3 days old;' '$D/out/stdout'; grep -c 'older than --max-age-hours 24' '$D/out/stdout' '$D/out/stderr' | awk -F: '{s+=\$2} END {print s}'" \
  "$(printf '0\n1\n1')"

# R10. --site-out is never written over: it may be the operator's working copy.
rs_case r10; mkdir -p "$D/restored"
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --site-out ./restored --dry-run
assert_artifact "R10 an existing --site-out is refused" \
  "echo $RS_STATUS; rs_err | grep -c 'already exists'" "$(printf '1\n1')"

# R11. repair-forge needs no old kit, but always writes a new one.
rs_case r11
rs_run repair-forge --restore-from file:media/site.bundle --passphrase-file inputs/pass --no-sealing-key-backup --dry-run
assert_artifact "R11 repair-forge without --kit-out is refused (the new forge has new secrets)" \
  "echo $RS_STATUS; rs_err | grep -c -- '--kit-out FILE is required'" "$(printf '1\n1')"
rs_case r11b
rs_run repair-forge --restore-from file:media/site.bundle --kit-out kits/new.kit --passphrase-file inputs/pass --no-sealing-key-backup --dry-run
assert_artifact "R11 repair-forge's dry run plans a forge-only reinstall, touching no cluster" \
  "echo $RS_STATUS; grep -c 'nothing else is touched' '$D/out/stdout'; rs_cluster_calls" "$(printf '0\n1\n0')"

# R12. --restore-from offsite with no destination named has nowhere to read from.
rs_case r12
rs_run --restore-from offsite "${RS_KIT[@]}" --dry-run
assert_artifact "R12 --restore-from offsite without a destination is refused" \
  "echo $RS_STATUS; rs_err | grep -c 'needs the destination the off-site job wrote to'" "$(printf '1\n1')"


# R13. The new kit never overwrites a kit: not an existing file, not the one being restored from.
rs_case r13; : > "$D/kits/new.kit"
rs_run --restore-from file:media/site.bundle "${RS_KIT[@]}" --dry-run
assert_artifact "R13 an existing --kit-out is refused (it may be the only kit)" \
  "echo $RS_STATUS; rs_err | grep -c 'Refusing to overwrite a recovery kit'" "$(printf '1\n1')"
rs_case r13b
rs_run --restore-from file:media/site.bundle --kit kits/old.kit --passphrase-file inputs/pass --kit-out kits/old.kit --dry-run
assert_artifact "R13 --kit-out naming the kit being restored from is refused" \
  "echo $RS_STATUS; rs_err | grep -c -E 'already exists|names the kit this run is restoring from'" "$(printf '1\n1')"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups F1-F10: install/bootstrap-forge.sh (TM-1335).
#
# HERMETIC, and deliberately narrow: every case here is a REFUSAL, and the
# assertion that matters in each is that the refusal came before any write to a
# cluster (no `create`, `apply`, `label` or `helm` in the shim's call log). The
# shims are bootstrap-secrets' (lib/shims/), which answer the read-only calls the
# forge script makes before it writes anything and fail loudly on anything else.
#
# WHAT THIS IS NOT. Nothing here installs a forge, talks to its API or pushes a
# site. That path was run for real on 2026-10-31 against a lab k3s cluster in throwaway
# namespaces (TM-1335's Log: install, repository, users, teams, tokens, push,
# the rule on main read back, ArgoCD's credential cloning main from inside the
# cluster, the kit opened with its passphrase and refused with a wrong one, and a
# second run adopting everything). A shim that answered the forge API would prove
# only that the shim agrees with the script.

FS="$WORK/forge"; mkdir -p "$FS"
FORGE_URL="http://tockmox-forge-http.tockmox-forge.svc.cluster.local:3000/tockmox/site.git"

fs_case() {  # name [built-in|external]  ->  $D with a site and inputs
  D="$FS/$1"; rm -rf "$D"; mkdir -p "$D/state" "$D/tmp" "$D/inputs" "$D/out" "$D/kits"
  cp -R "$SITE_C/tockmox-site" "$D/site"
  if [ "${2:-built-in}" = built-in ]; then
    # What site.forge: built-in writes: the in-cluster address where the placeholder was.
    grep -rl PLACEHOLDER_SITE_REPO_URL "$D/site" | while IFS= read -r f; do
      sed "s|PLACEHOLDER_SITE_REPO_URL|$FORGE_URL|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  fi
  : > "$D/state/calls.log"
  printf 'KITPASSMARKER-1\n' > "$D/inputs/pass"
  printf 'not a real backup\n' > "$D/inputs/seal.enc"
}
FS_STATUS=0
fs_run() {
  set +e
  ( cd "$D" && env PATH="$SHIMS:$PATH" FAKE_STATE="$D/state" REAL_OPENSSL="$REAL_OPENSSL" \
      TMPDIR="$D/tmp" NO_COLOR=1 bash "$INSTALLER" bootstrap-forge "$@" ) >"$D/out/stdout" 2>"$D/out/stderr"
  FS_STATUS=$?
  set -e
}
fs_err() { cat "$D/out/stderr"; }
fs_writes() { grep -cE '^(kubectl .*(create|apply|label|delete|exec|port-forward)|helm )' "$D/state/calls.log" || true; }
FS_OK=(--yes-context lab-test --yes-server https://192.0.2.10:6443 --no-prompt)

# F1. A site generated for an external forge is refused: ArgoCD would read a
# placeholder, and this script would build a repository nothing points at.
fs_case f1 external
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}"
assert_artifact "F1 an external-forge site is refused, naming the placeholder" \
  "echo $FS_STATUS; fs_err | grep -c 'generated for an external forge'" "$(printf '1\n1')"
assert_artifact "F1 ... and nothing was written to the cluster" "fs_writes" "0"

# F2. No kit, no run: the kit is what makes a rebuild possible.
fs_case f2
fs_run --site "$D/site" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}"
assert_artifact "F2 --kit-out is required" "echo $FS_STATUS; fs_err | grep -c -- '--kit-out FILE is required'" "$(printf '1\n1')"

# F3. A kit inside the site repository would be pushed to the forge it exists to rebuild.
fs_case f3
fs_run --site "$D/site" --kit-out "$D/site/kit.enc" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}"
assert_artifact "F3 a kit inside the site repository is refused" "echo $FS_STATUS; fs_err | grep -c 'inside the site repository'" "$(printf '1\n1')"

# F4. No way to encrypt, no kit: there is no plaintext path.
fs_case f4
fs_run --site "$D/site" --kit-out "$D/kits/k" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}"
assert_artifact "F4 no age recipient and no passphrase file is refused" "echo $FS_STATUS; fs_err | grep -c 'no way to encrypt the recovery kit'" "$(printf '1\n1')"

# F5. The sealing-key backup is required unless its absence is stated.
fs_case f5
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" "${FS_OK[@]}"
assert_artifact "F5 a missing --sealing-key-backup is refused" "echo $FS_STATUS; fs_err | grep -c -- '--sealing-key-backup FILE is required'" "$(printf '1\n1')"

# F6. An existing kit is never overwritten: it may be the only copy.
fs_case f6; printf 'older kit\n' > "$D/kits/k"
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}"
assert_artifact "F6 an existing kit file is refused and left as it was" \
  "echo $FS_STATUS; fs_err | grep -c 'already exists'; cat '$D/kits/k'" "$(printf '1\n1\nolder kit')"

# F7. An empty --context is what an unset shell variable produces; never fall back.
fs_case f7
fs_run --site "$D/site" --context "" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}"
assert_artifact "F7 an empty --context is refused" "echo $FS_STATUS; fs_err | grep -c -- '--context was given empty'" "$(printf '1\n1')"

# F8. A confirmation that does not match is not a confirmation.
fs_case f8
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" \
  --yes-context some-other-cluster --yes-server https://192.0.2.10:6443 --no-prompt
assert_artifact "F8 a mismatched --yes-context is refused" "echo $FS_STATUS; fs_err | grep -c 'does not match the context in use'" "$(printf '1\n1')"
assert_artifact "F8 ... before any write to the cluster" "fs_writes" "0"

# F9. --no-prompt without the two confirmations refuses rather than guessing.
fs_case f9
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" --no-prompt
assert_artifact "F9 --no-prompt without --yes-context is refused" "echo $FS_STATUS; fs_err | grep -c 'cannot be confirmed'" "$(printf '1\n1')"

# F10. A dry run plans and touches nothing, and writes no kit.
fs_case f10
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" --dry-run "${FS_OK[@]}"
assert_artifact "F10 a dry run exits clean with a plan" "echo $FS_STATUS; grep -c 'Plan (dry run, nothing changed)' '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "F10 ... writes nothing to the cluster and no kit" "fs_writes; [ -e '$D/kits/k' ] && echo kit || echo no-kit" "$(printf '0\nno-kit')"

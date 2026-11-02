#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups F1-F24: install/bootstrap-forge.sh (TM-1335, TM-1337, TM-1336).
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

# F11. The generator, site.forge: built-in: every Application names the forge,
# nothing carries the placeholder, and the observability layer gets the off-site
# copy's alerts (TM-1337). The external route gets none of that.
FG="$FS/gen-built-in"; mkdir -p "$FG"
sed 's|^  name: ci-interactive|  name: ci-interactive\n  forge: built-in|' "$PARITY_CFG" > "$FG/tockmox.yaml"
run_config "$FG" --config tockmox.yaml --no-cluster
cp "$WORK/cfg-out.txt" "$FG/cfg-out.txt"
assert_artifact "F11 site.forge: built-in generates cleanly" "echo $CONFIG_STATUS" "0"
assert_artifact "F11 ... with no placeholder left anywhere" \
  "{ grep -rl PLACEHOLDER_SITE_REPO_URL '$FG/tockmox-site' || true; } | wc -l | tr -d ' '" "0"
assert_artifact "F11 ... root.yaml names the forge's in-cluster address" \
  "grep -c '$FORGE_URL' '$FG/tockmox-site/bootstrap/root.yaml'" "1"
assert_artifact "F11 ... and the observability layer turns on the off-site copy's alerts" \
  "python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))[\"siteForge\"][\"enabled\"])' '$FG/tockmox-site/site/values/observability.yaml'" "True"
assert_artifact "F11 the external route carries no siteForge key" \
  "grep -c '^siteForge:' '$SITE_C/tockmox-site/site/values/observability.yaml' || true" "0"
assert_artifact "F11 ... the identity layer turns on the forge's sign-in (TM-1336)" \
  "python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))[\"sso\"][\"apps\"][\"forge\"][\"enabled\"])' '$FG/tockmox-site/site/values/identity.yaml'" "True"
assert_artifact "F11 ... and its next steps end with connecting it" \
  "grep -c 'bootstrap-forge --site .* --connect-sign-in' '$FG/cfg-out.txt'" "1"
assert_artifact "F11 the external route does not turn the forge's sign-in on" \
  "grep -c 'forge:' '$SITE_C/tockmox-site/site/values/identity.yaml' || true" "0"

# F12-F16. The off-site copy's flags are refused before any cluster write.
os_run() { fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}" "$@"; }
fs_case f12; printf 'GKexample\nsecretexample\n' > "$D/inputs/s3"; printf 'bot\ntoken\n' > "$D/inputs/git"
os_run --offsite-s3-endpoint https://s3.example.com --offsite-s3-bucket site-copy --offsite-s3-credentials "$D/inputs/s3" \
  --offsite-git https://git.example.com/me/site.git --offsite-git-credentials "$D/inputs/git"
assert_artifact "F12 two off-site destinations at once are refused" \
  "echo $FS_STATUS; fs_err | grep -c 'not both'" "$(printf '1\n1')"
assert_artifact "F12 ... before any write to the cluster" "fs_writes" "0"

fs_case f13; printf 'GKexample\nsecretexample\n' > "$D/site/s3-creds"
os_run --offsite-s3-endpoint https://s3.example.com --offsite-s3-bucket site-copy --offsite-s3-credentials "$D/site/s3-creds"
assert_artifact "F13 a credentials file inside the site repository is refused (it would be pushed)" \
  "echo $FS_STATUS; fs_err | grep -c 'inside the site repository'" "$(printf '1\n1')"

fs_case f14; printf 'GKexample\n' > "$D/inputs/s3"
os_run --offsite-s3-endpoint https://s3.example.com --offsite-s3-bucket site-copy --offsite-s3-credentials "$D/inputs/s3"
assert_artifact "F14 a one-line credentials file is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'must have two lines'" "$(printf '1\n1')"

fs_case f15; printf 'bot\ntoken\n' > "$D/inputs/git"
os_run --offsite-git 'https://bot:token@git.example.com/me/site.git' --offsite-git-credentials "$D/inputs/git"
assert_artifact "F15 a git URL carrying credentials is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'no credentials in it'" "$(printf '1\n1')"

fs_case f16; printf 'GKexample\nsecretexample\n' > "$D/inputs/s3"
os_run --offsite-s3-endpoint https://s3.example.com/path --offsite-s3-bucket site-copy --offsite-s3-credentials "$D/inputs/s3"
assert_artifact "F16 an endpoint with a path is refused (the bucket is its own flag)" \
  "echo $FS_STATUS; fs_err | grep -c 'with no path'" "$(printf '1\n1')"

# F17. A dry run with a destination plans the copy and writes nothing.
fs_case f17; printf 'GKexample\nsecretexample\n' > "$D/inputs/s3"
os_run --offsite-s3-endpoint https://s3.example.com --offsite-s3-bucket site-copy --offsite-s3-prefix lab/site \
  --offsite-s3-credentials "$D/inputs/s3" --dry-run
assert_artifact "F17 a dry run names the off-site copy it would make" \
  "echo $FS_STATUS; grep -c 'off-site copy (bucket) to https://s3.example.com/site-copy/lab/site' '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "F17 ... and writes nothing to the cluster" "fs_writes" "0"

# F18-F23. Sign-in through Authentik (TM-1336). Everything it needs comes from the
# site, so a contradiction or a missing domain is refused before the cluster is touched.
fs_case f18
fs_run --site "$D/site" --connect-sign-in --no-sign-in "${FS_OK[@]}"
assert_artifact "F18 --connect-sign-in with --no-sign-in is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'contradict each other'" "$(printf '1\n1')"
assert_artifact "F18 ... before any write to the cluster" "fs_writes" "0"

fs_case f19; rm -f "$D/site/bootstrap/applications/tockmox-identity.yaml"
fs_run --site "$D/site" --connect-sign-in "${FS_OK[@]}"
assert_artifact "F19 --connect-sign-in on a site without the identity layer is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'no Authentik to connect the forge to'" "$(printf '1\n1')"

fs_case f20
sed 's/^  internalDomain: .*/  internalDomain: ""/' "$D/site/site/values/global.yaml" > "$D/g" && mv "$D/g" "$D/site/site/values/global.yaml"
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}"
assert_artifact "F20 sign-in with no internalDomain is refused, naming the key" \
  "echo $FS_STATUS; fs_err | grep -c 'global.internalDomain is empty'" "$(printf '1\n1')"
assert_artifact "F20 ... before any write to the cluster" "fs_writes" "0"

fs_case f21
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" --forge-host 'forge;rm' "${FS_OK[@]}"
assert_artifact "F21 a forge host that is not a host name is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'is not a host name'" "$(printf '1\n1')"
fs_case f21b
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" --admin-group 'admins"}' "${FS_OK[@]}"
assert_artifact "F21 an admin group that could break the forge's group map is refused" \
  "echo $FS_STATUS; fs_err | grep -c -- '--admin-group must be'" "$(printf '1\n1')"

# F22. A dry run names the browser address, Authentik and the mapping, and writes nothing.
fs_case f22
DOM="$(sed -n 's/^  internalDomain: *//p' "$D/site/site/values/global.yaml" | tr -d '"')"
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" --dry-run "${FS_OK[@]}"
assert_artifact "F22 a dry run derives forge.<internalDomain> and maps the admin group to approvers" \
  "echo $FS_STATUS; grep -c \"sign-in .*forge.$DOM/ through Authentik at auth.$DOM; tockmox-admins -> team approvers\" '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "F22 ... warns that this site's identity values do not turn the forge on" \
  "grep -c 'does not turn on sso.apps.forge' '$D/out/stderr' '$D/out/stdout' | awk -F: '{s+=\$2} END {print s}'" "1"
assert_artifact "F22 ... and writes nothing to the cluster" "fs_writes" "0"
fs_case f22b
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" --no-sign-in --dry-run "${FS_OK[@]}"
assert_artifact "F22 --no-sign-in plans a forge that answers only in the cluster" \
  "echo $FS_STATUS; grep -c 'sign-in     none (--no-sign-in)' '$D/out/stdout'" "$(printf '0\n1')"

# F23. --connect-sign-in needs neither the kit nor its encryption: a dry run plans it.
fs_case f23
fs_run --site "$D/site" --connect-sign-in --dry-run "${FS_OK[@]}"
assert_artifact "F23 --connect-sign-in plans without a kit" \
  "echo $FS_STATUS; grep -c \"add or update the forge's sign-in source 'authentik'\" '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "F23 ... and writes nothing to the cluster" "fs_writes" "0"

# F24. --no-sign-in on a site whose identity values turn the forge's application on:
# its blueprint would read a client secret nobody wrote, and Authentik would apply none
# of its blueprints. Refused, naming the key, before the cluster is touched.
fs_case f24
printf 'sso:\n  apps:\n    forge:\n      enabled: true\n' >> "$D/site/site/values/identity.yaml"
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" --no-sign-in "${FS_OK[@]}"
assert_artifact "F24 --no-sign-in with sso.apps.forge on is refused, naming the key" \
  "echo $FS_STATUS; fs_err | grep -c 'Set sso.apps.forge.enabled: false'" "$(printf '1\n1')"
assert_artifact "F24 ... before any write to the cluster" "fs_writes" "0"

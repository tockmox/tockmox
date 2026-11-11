#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups F1-F35: install/bootstrap-forge.sh.
#
# HERMETIC, and deliberately narrow: every case here is a REFUSAL, and the
# assertion that matters in each is that the refusal came before any write to a
# cluster (no `create`, `apply`, `label` or `helm` in the shim's call log). The
# shims are bootstrap-secrets' (lib/shims/), which answer the read-only calls the
# forge script makes before it writes anything and fail loudly on anything else.
#
# WHAT THIS IS NOT. Nothing here installs a forge, talks to its API or pushes a
# site. That path was run for real on 2026-10-31 against a lab k3s cluster in throwaway
# namespaces (install, repository, users, teams, tokens, push,
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
  # Shaped like bootstrap-secrets' export (age output), which bootstrap-forge now checks
  # for; the payload is not a real key, and nothing here decrypts it.
  printf 'age-encryption.org/v1\nnot a real backup\n' > "$D/inputs/seal.enc"
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

# F6b. A sealing-key backup that is not bootstrap-secrets' encrypted export would make a
# kit no rebuild can open the key from. The usual one is the plain YAML that
# fresh-install.md 7 has the reader write: refused before anything, and no kit written.
fs_case f6b
printf 'apiVersion: v1\nitems:\n- apiVersion: v1\n  data:\n    tls.key: AAAA\n' > "$D/inputs/seal-yaml"
fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal-yaml" "${FS_OK[@]}"
assert_artifact "F6b a plain YAML key export is refused as --sealing-key-backup, naming the fix" \
  "echo $FS_STATUS; fs_err | grep -c 'is not bootstrap-secrets. encrypted key export'; fs_err | grep -c 'bootstrap-secrets --mode reuse'" "$(printf '1\n1\n1')"
assert_artifact "F6b ... no kit was written and nothing was written to the cluster" \
  "test -e '$D/kits/k' && echo kit || echo none; fs_writes" "$(printf 'none\n0')"
for magic in 'age-encryption.org/v1' '-----BEGIN AGE ENCRYPTED FILE-----' 'Salted__'; do
  fs_case f6b-ok; printf '%s\nx\n' "$magic" > "$D/inputs/seal-ok"
  fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal-ok" --dry-run "${FS_OK[@]}"
  assert_artifact "F6b an encrypted export ($magic) passes the check" \
    "fs_err | grep -c 'is not bootstrap-secrets. encrypted key export' || true" "0"
done

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
# copy's alerts. The external route gets none of that.
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
assert_artifact "F11 ... the identity layer turns on the forge's sign-in" \
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
assert_artifact "F17 ... and says the nightly forge dump goes to the same place" \
  "grep -c 'nightly forge dump of pull requests, reviews and comments to the same place' '$D/out/stdout'" "1"

# F18-F23. Sign-in through Authentik. Everything it needs comes from the
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

# F25-F30. The Tockmox charts repository, for a site with no route to GitHub:
# --charts-repo and --charts-tag are checked before the cluster is touched. A real
# (tiny) git repository is built with the real git, so the tag and the file at the
# tag are read the way the installer reads them.
# run.sh stubs git to always fail (offline determinism); these cases need the real one,
# so the stub's directory is taken off PATH for the calls below and only for them.
REAL_PATH="${PATH//$STUB:/}"
mk_charts() {  # DIR [with-chart|without-chart]  -> repo at DIR, tag v9.9.9 on its one commit
  local d="$1"; mkdir -p "$d/charts/tockmox-platform"
  if [ "${2:-with-chart}" = with-chart ]; then
    printf 'apiVersion: v2\nname: tockmox-platform\nversion: 9.9.9\n' > "$d/charts/tockmox-platform/Chart.yaml"
  else
    printf 'nothing here\n' > "$d/README"
  fi
  ( cd "$d" && export PATH="$REAL_PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null && git init -q -b main . \
      && git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m seed && git tag v9.9.9 )
}
ch_run() { PATH="$REAL_PATH" fs_run --site "$D/site" --kit-out "$D/kits/k" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" "${FS_OK[@]}" "$@"; }

fs_case f25; mk_charts "$D/charts-src"
ch_run --charts-repo "$D/charts-src"
assert_artifact "F25 --charts-repo without --charts-tag is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'go together'" "$(printf '1\n1')"
assert_artifact "F25 ... before any write to the cluster" "fs_writes" "0"

fs_case f26; mk_charts "$D/charts-src"
ch_run --charts-repo "$D/charts-src" --charts-tag v0.0.0
assert_artifact "F26 a tag that is not in the checkout is refused, naming it" \
  "echo $FS_STATUS; fs_err | grep -c \"no tag 'v0.0.0'\"" "$(printf '1\n1')"
assert_artifact "F26 ... before any write to the cluster" "fs_writes" "0"

fs_case f27; mk_charts "$D/charts-src" without-chart
ch_run --charts-repo "$D/charts-src" --charts-tag v9.9.9
assert_artifact "F27 a checkout that is not the Tockmox charts repository is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'not the Tockmox charts repository'" "$(printf '1\n1')"
assert_artifact "F27 ... before any write to the cluster" "fs_writes" "0"

fs_case f28; mkdir -p "$D/not-git"
ch_run --charts-repo "$D/not-git" --charts-tag v9.9.9
assert_artifact "F28 a directory that is not a git checkout is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'is not a git checkout'" "$(printf '1\n1')"

fs_case f29; mk_charts "$D/charts-src"
ch_run --charts-repo "$D/charts-src" --charts-tag 'v9 9'
assert_artifact "F29 a tag that is not a tag name is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'is not a tag name'" "$(printf '1\n1')"

fs_case f30; mk_charts "$D/charts-src"
ch_run --charts-repo "$D/charts-src" --charts-tag v9.9.9 --dry-run
assert_artifact "F30 a dry run with a good checkout exits clean and names the charts repository and tag" \
  "echo $FS_STATUS; grep -c 'create tockmox/charts (read by' '$D/out/stdout'; grep -c 'push tag v9.9.9 and main' '$D/out/stdout'" "$(printf '0\n1\n1')"
assert_artifact "F30 ... and writes nothing to the cluster" "fs_writes" "0"

# F31-F35. --offsite-git-ca: a git remote on a private CA (and a private address).
# Refusals before any write, and the dry run's plan naming the trust and the one host
# allowed. What the chart then mounts is proven on the lab, not here (see the header).
printf -- '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n' > "$FS/ca.pem"
fs_case f31; printf 'bot\ntoken\n' > "$D/inputs/git"
os_run --offsite-git https://git.example.internal/lab/site.git --offsite-git-credentials "$D/inputs/git" --offsite-git-ca "$D/inputs/no-such-ca.pem"
assert_artifact "F31 an unreadable --offsite-git-ca is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'cannot read --offsite-git-ca'" "$(printf '1\n1')"
assert_artifact "F31 ... before any write to the cluster" "fs_writes" "0"

fs_case f32; printf 'bot\ntoken\n' > "$D/inputs/git"; printf 'not a certificate\n' > "$D/inputs/ca.txt"
os_run --offsite-git https://git.example.internal/lab/site.git --offsite-git-credentials "$D/inputs/git" --offsite-git-ca "$D/inputs/ca.txt"
assert_artifact "F32 a CA file with no PEM certificate is refused" \
  "echo $FS_STATUS; fs_err | grep -c 'holds no PEM certificate'" "$(printf '1\n1')"
assert_artifact "F32 ... before any write to the cluster" "fs_writes" "0"

fs_case f33
os_run --offsite-git-ca "$FS/ca.pem"
assert_artifact "F33 a CA with no git remote is refused (it names the missing URL)" \
  "echo $FS_STATUS; fs_err | grep -c 'must be an https URL'" "$(printf '1\n1')"

fs_case f34; printf 'GKexample\nsecretexample\n' > "$D/inputs/s3"
os_run --offsite-s3-endpoint https://s3.example.com --offsite-s3-bucket site-copy --offsite-s3-credentials "$D/inputs/s3" --offsite-git-ca "$FS/ca.pem"
assert_artifact "F34 --offsite-git-ca beside a bucket is refused as two destinations" \
  "echo $FS_STATUS; fs_err | grep -c 'not both'" "$(printf '1\n1')"

fs_case f35; printf 'bot\ntoken\n' > "$D/inputs/git"
os_run --offsite-git https://git.example.internal:8443/lab/site.git --offsite-git-credentials "$D/inputs/git" --offsite-git-ca "$FS/ca.pem" --dry-run
assert_artifact "F35 a dry run plans the trust and allows the remote's host alone, without its port" \
  "echo $FS_STATUS; grep -c 'for git.example.internal in the forge.s push mirror and the copy job; the forge allows git.example.internal alone' '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "F35 ... and writes nothing to the cluster" "fs_writes" "0"

# F36-F47. The approvers watcher, run for real. Everything above is a refusal; these cases run the whole
# installer against a stand-in cluster (lib/shims-run/kubectl and helm, lib/fake-kubectl.py) and a stand-in
# forge (lib/forge-stub.py with ADMIN=1), and read back WHAT WAS MADE: the forge user and its one token with
# its scopes, the two Secrets, the ConfigMap, the Deployment, the two NetworkPolicies and the site values.
# The stand-in forge enforces a token the way the forge does (scope for the route, and the user must be able
# to see the thing), so "the token can read the team and nothing else" is exercised, not asserted.
#
# WHAT THIS DOES NOT PROVE: that a real Forgejo 15 answers a read:organization token the way the stand-in
# does, that Authentik lets the service account list its group, that the NetworkPolicies are enforced by a
# real CNI, or that the PodMonitor is scraped. Those are lab items (docs/administration/site-forge.md).
RUN_SHIMS="$HERE/lib/shims-run"
FKUBE="$HERE/lib/fake-kubectl.py"
WATCHER="tockmox-approver-watch"
WNAME="tockmox-forge-approver-watch"     # the Deployment, and the Secrets' name in both namespaces
fk_case() {  # name [with-identity]  ->  $D, a built-in-forge site whose values turn the forge on, an empty cluster
  fs_case "$1"
  [ "${2:-with-identity}" = with-identity ] && printf 'sso:\n  apps:\n    forge:\n      enabled: true\n' >> "$D/site/site/values/identity.yaml"
  printf '\nsiteForge:\n  enabled: true\n' >> "$D/site/site/values/observability.yaml"
  mkdir -p "$D/state/objs/_ns"; : > "$D/state/objs/_ns/argocd"
}
fk_run() {
  set +e
  ( cd "$D" && env PATH="$RUN_SHIMS:$REAL_PATH" FAKE_STATE="$D/state" TMPDIR="$D/tmp" NO_COLOR=1 \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$INSTALLER" bootstrap-forge \
      --site "$D/site" --kit-out "$D/kits/k$FK_N" --passphrase-file "$D/inputs/pass" --sealing-key-backup "$D/inputs/seal.enc" \
      "${FS_OK[@]}" "$@" ) >"$D/out/stdout" 2>"$D/out/stderr"
  FS_STATUS=$?
  set -e
  FK_N=$((FK_N + 1))
}
FK_N=1
fk_get()  { FAKE_STATE="$D/state" python3 "$FKUBE" @get "$@"; }                    # NS KIND NAME PATH
fk_obj()  { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$D/state/objs/$1/$2/$3.json" "$4"; }
fk_forge() { python3 -c 'import json,sys; st=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$D/state/forge/forge.json" "$1"; }
fk_git() { PATH="$REAL_PATH" git --git-dir "$D/state/forge/tockmox/site.git" "$@"; }   # the run.sh git stub always fails
fk_cluster() { { find "$D/state/objs" -type f ! -path '*/_ns/*' 2>/dev/null || true; } | wc -l | tr -d ' '; }
fk_watch_sum() {  # one checksum over everything the watcher is made of, to compare two runs
  { for f in "tockmox-forge/Secret/$WNAME" "tockmox-authentik/Secret/$WNAME" "tockmox-forge/ConfigMap/$WNAME-script" \
             "tockmox-forge/Deployment/$WNAME" "tockmox-forge/NetworkPolicy/$WNAME" "tockmox-authentik/NetworkPolicy/$WNAME" \
             "tockmox-forge/ServiceAccount/$WNAME"; do
      cat "$D/state/objs/$f.json"; echo
    done
    fk_forge "st['tokens']['$WATCHER']"
    cat "$D/site/site/values/observability.yaml" "$D/site/site/values/identity.yaml"
  } | cksum
}
FKNS=tockmox-forge; FKID=tockmox-authentik

# F36. A dry run plans the watcher, with its user, its one token's scopes and both Secrets, and touches nothing:
# no cluster object, no change to the site's values.
fk_case f36
fk_run --dry-run
assert_artifact "F36 a dry run names the watcher's user, token scopes, Secrets and Deployment" \
  "echo $FS_STATUS; grep -c \"the approvers watcher: forge user $WATCHER (team readers, one token: read:organization, read:repository)\" '$D/out/stdout'; grep -c 'Secret tockmox-forge-approver-watch in tockmox-forge and tockmox-forge-approver-watch in tockmox-authentik, Deployment tockmox-forge-approver-watch' '$D/out/stdout'" "$(printf '0\n1\n1')"
assert_artifact "F36 ... writes nothing to the cluster, makes no object and leaves the site's values alone" \
  "fs_writes; fk_cluster; cat '$D/site/site/values/observability.yaml' '$D/site/site/values/identity.yaml' | grep -c approverWatch || true" "$(printf '0\n0\n0')"
fk_case f36b without-identity
fk_run --dry-run --no-sign-in
assert_artifact "F36 with --no-sign-in the plan says there is no watcher, and why" \
  "echo $FS_STATUS; grep -c 'no approvers watcher (--no-sign-in' '$D/out/stdout'; grep -c 'the approvers watcher:' '$D/out/stdout' || true" "$(printf '0\n1\n0')"

# F37. The run itself.
fk_case f37
fk_run
assert_artifact "F37 the run finishes" "echo $FS_STATUS; grep -c 'Done' '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "F37 the watcher's forge user exists and is not a forge admin" \
  "fk_forge \"'$WATCHER' in st['users'] and not st['users']['$WATCHER']['is_admin']\"" "True"
assert_artifact "F37 it has exactly ONE token, scoped read:organization and read:repository and nothing else" \
  "fk_forge \"[sorted(v['scopes']) for v in st['tokens']['$WATCHER'].values()]\"" "[['read:organization', 'read:repository']]"
assert_artifact "F37 it is in the readers team only: not Owners, not approvers, not the change team" \
  "fk_forge \"sorted(t['name'] for t in st['teams'].values() if '$WATCHER' in t['members'])\"" "['readers']"
assert_artifact "F37 the readers team holds read, not write, and Owners holds only the admin" \
  "fk_forge \"sorted((t['name'], t['permission']) for t in st['teams'].values() if t['name'] in ('readers','Owners'))\"" "[('Owners', 'owner'), ('readers', 'read')]"
assert_artifact "F37 the forge Secret holds the token the forge issued, and an Authentik token of 48 characters" \
  "t=\$(fk_get $FKNS Secret $WNAME data/forge-token); a=\$(fk_get $FKNS Secret $WNAME data/authentik-token); [ \"\$t\" = \"\$(fk_forge \"list(st['tokens']['$WATCHER'].values())[0]['sha1']\")\" ] && echo token-matches; echo \${#a}" "$(printf 'token-matches\n48')"
assert_artifact "F37 the identity Secret holds the SAME Authentik token under the name the blueprint reads" \
  "[ \"\$(fk_get $FKID Secret $WNAME data/FORGE_APPROVER_WATCH_TOKEN)\" = \"\$(fk_get $FKNS Secret $WNAME data/authentik-token)\" ] && echo same" "same"
assert_artifact "F37 the ConfigMap carries install/forge-approver-watch.py exactly" \
  "fk_get $FKNS ConfigMap $WNAME-script data/forge-approver-watch.py | cmp - '$REPO_ROOT/install/forge-approver-watch.py' && echo identical" "identical"
assert_artifact "F37 the Deployment runs it in the move job's pinned image, non-root, with a read-only root filesystem and limits" \
  "fk_obj $FKNS Deployment $WNAME \"[d['spec']['template']['spec']['containers'][0]['image'], d['spec']['template']['spec']['securityContext']['runAsNonRoot'], d['spec']['template']['spec']['containers'][0]['securityContext']['readOnlyRootFilesystem'], d['spec']['template']['spec']['containers'][0]['securityContext']['allowPrivilegeEscalation'], sorted(d['spec']['template']['spec']['containers'][0]['resources']['limits']), sorted(d['spec']['template']['spec']['containers'][0]['resources']['requests'])]\"" \
  "['alpine/k8s:1.37.2', True, True, False, ['cpu', 'memory'], ['cpu', 'memory']]"
assert_artifact "F37 ... mounts the script and the one Secret, with no Kubernetes token and no credential in its environment" \
  "fk_obj $FKNS Deployment $WNAME \"[sorted(v['name'] for v in d['spec']['template']['spec']['volumes']), d['spec']['template']['spec']['automountServiceAccountToken']]\"; grep -c \"\$(fk_get $FKNS Secret $WNAME data/forge-token)\" '$D/state/objs/$FKNS/Deployment/$WNAME.json' || true" \
  "$(printf "[['credentials', 'script', 'tmp'], False]\n0")"
assert_artifact "F37 the ServiceAccount has no Role or binding" \
  "find '$D/state/objs' -path '*Role*' -name '$WNAME*' | wc -l | tr -d ' '" "0"
assert_artifact "F37 its NetworkPolicy is a default-deny pair: Prometheus in, only the forge, Authentik and DNS out" \
  "fk_obj $FKNS NetworkPolicy $WNAME \"[d['spec']['policyTypes'], [p['port'] for r in d['spec']['ingress'] for p in r['ports']], sorted(p['port'] for r in d['spec']['egress'] for p in r['ports']), [r['from'][0]['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'] for r in d['spec']['ingress']]]\"" \
  "[['Ingress', 'Egress'], [9470], [53, 53, 3000, 9000], ['tockmox-monitoring']]"
assert_artifact "F37 Authentik admits that one pod to its server on 9000, and nobody else new" \
  "fk_obj $FKID NetworkPolicy $WNAME \"[d['spec']['policyTypes'], d['spec']['ingress'][0]['from'][0]['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'], d['spec']['ingress'][0]['from'][0]['podSelector']['matchLabels'], len(d['spec']['ingress']), d['spec']['ingress'][0]['ports'][0]['port']]\"" \
  "[['Ingress'], 'tockmox-forge', {'app.kubernetes.io/name': 'tockmox-forge-approver-watch'}, 1, 9000]"
assert_artifact "F37 the site's values turn on both switches" \
  "python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))[\"siteForge\"][\"approverWatch\"], yaml.safe_load(open(sys.argv[2]))[\"sso\"][\"apps\"][\"forge\"][\"approverWatch\"])' '$D/site/site/values/observability.yaml' '$D/site/site/values/identity.yaml'" "True True"
assert_artifact "F37 ... and the forge's main, which ArgoCD reads, carries them" \
  "fk_git show main:site/values/observability.yaml | grep -c 'approverWatch: true'; fk_git show main:site/values/identity.yaml | grep -c 'approverWatch: true'" "$(printf '1\n1')"
assert_artifact "F37 the Deployment's pod carries the label, and names the metrics port, that the observability chart's PodMonitor selects" \
  "fk_obj $FKNS Deployment $WNAME \"sorted(d['spec']['template']['metadata']['labels'].items()), d['spec']['template']['spec']['containers'][0]['ports'][0]['name']\"" \
  "([('app.kubernetes.io/name', 'tockmox-forge-approver-watch')], 'metrics')"
assert_artifact "F37 ... and the chart's PodMonitor selects exactly that label, on that port, in the forge's namespace" \
  "helm template t '$REPO_ROOT/charts/tockmox-observability' -f '$REPO_ROOT/ci/values.yaml' -f '$REPO_ROOT/ci/values-all-on.yaml' 2>/dev/null | awk '/^kind: PodMonitor/ {f=1} /^---/ {f=0} f' | grep -E 'tockmox-forge-approver-watch|port: metrics|matchNames' | sed 's/^ *//' | tr '\n' '|'" \
  "name: tockmox-forge-approver-watch|matchNames: [\"tockmox-forge\"]|app.kubernetes.io/name: \"tockmox-forge-approver-watch\"|- port: metrics|"

# F38. A re-run on the finished install changes nothing the watcher is made of, keeps its token and mints none.
fk_watch_sum > "$D/sum1"
fk_run
fk_watch_sum > "$D/sum2"
assert_artifact "F38 a re-run succeeds and says the watcher's token still works" \
  "echo $FS_STATUS; grep -c \"the approvers watcher's forge token still works; kept\" '$D/out/stdout'" "$(printf '0\n1')"
assert_artifact "F38 ... and changes nothing: the Secrets, ConfigMap, Deployment, policies, token and the site's values are byte-identical" \
  "cmp '$D/sum1' '$D/sum2' && echo unchanged" "unchanged"
assert_artifact "F38 ... the watcher still has exactly one token" \
  "fk_forge \"len(st['tokens']['$WATCHER'])\"" "1"

# F39. A token the forge no longer accepts is replaced, and the old one is gone: still exactly one.
OLD="$(fk_forge "list(st['tokens']['$WATCHER'].values())[0]['sha1']")"
python3 - "$D/state/forge/forge.json" "$WATCHER" <<'PY'
import json, sys
p, u = sys.argv[1], sys.argv[2]
st = json.load(open(p))
for rec in st["tokens"][u].values():
    rec["sha1"] = "revoked." + rec["sha1"]          # what the Secret holds is now a token the forge does not know
json.dump(st, open(p, "w"))
PY
fk_run
assert_artifact "F39 a token the forge rejects is replaced by a new one in the Secret, and only one token remains" \
  "echo $FS_STATUS; [ \"\$(fk_get $FKNS Secret $WNAME data/forge-token)\" = \"\$(fk_forge \"list(st['tokens']['$WATCHER'].values())[0]['sha1']\")\" ] && echo secret-follows; fk_forge \"len(st['tokens']['$WATCHER'])\"; grep -c 'forge token still works' '$D/out/stdout' || true" \
  "$(printf '0\nsecret-follows\n1\n0')"
[ -n "$OLD" ]

# F40. The Authentik token is kept from either namespace: lose the forge-side Secret and the run puts the
# identity layer's value back, so Authentik and the watcher never disagree.
AK="$(fk_get $FKID Secret $WNAME data/FORGE_APPROVER_WATCH_TOKEN)"
rm -f "$D/state/objs/$FKNS/Secret/$WNAME.json"
fk_run
assert_artifact "F40 with the watcher's own Secret lost, the identity layer's Authentik token is kept and restored" \
  "echo $FS_STATUS; [ \"\$(fk_get $FKNS Secret $WNAME data/authentik-token)\" = '$AK' ] && echo restored; [ \"\$(fk_get $FKID Secret $WNAME data/FORGE_APPROVER_WATCH_TOKEN)\" = '$AK' ] && echo unchanged" \
  "$(printf '0\nrestored\nunchanged')"

# F41. Without sign-in there is no admin group to compare with: no user, no token, no Deployment, no policy,
# and the observability switch stays off, so the alerts that read the watcher do not fire for want of one.
fk_case f41 without-identity
fk_run --no-sign-in
assert_artifact "F41 --no-sign-in installs no watcher" \
  "echo $FS_STATUS; fk_forge \"'$WATCHER' in st['users'] or '$WATCHER' in st['tokens']\"; ls '$D/state/objs/$FKNS/Deployment' 2>/dev/null | grep -c approver || true; grep -c approverWatch '$D/site/site/values/observability.yaml' || true" \
  "$(printf '0\nFalse\n0\n0')"

# F42. A value the operator already set is theirs: a false stays false. And with no siteForge block to
# attach to, the run says what to add by hand and does not invent one.
fk_case f42
python3 - "$D/site/site/values/observability.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("siteForge:\n  enabled: true\n", "siteForge:\n  enabled: true\n  approverWatch: false\n")
open(p, "w").write(s)
PY
fk_run
assert_artifact "F42 an approverWatch: false the operator wrote is left false" \
  "echo $FS_STATUS; grep -c 'approverWatch: false' '$D/site/site/values/observability.yaml'; grep -c 'approverWatch: true' '$D/site/site/values/observability.yaml' || true" "$(printf '0\n1\n0')"
fk_case f42b
python3 - "$D/site/site/values/observability.yaml" <<'PY'
import sys
p = sys.argv[1]
open(p, "w").write(open(p).read().replace("\nsiteForge:\n  enabled: true\n", "\n"))
PY
fk_run
assert_artifact "F42 with no siteForge block the run finishes, adds none, and says what to add by hand" \
  "echo $FS_STATUS; grep -c 'siteForge' '$D/site/site/values/observability.yaml' || true; grep -c 'has no siteForge block with enabled: true' '$D/out/stderr' '$D/out/stdout' | awk -F: '{s+=\$2} END {print s}'" "$(printf '0\n0\n1')"

# F43. The template refuses what would make a wrong Deployment.
assert_artifact "F43 the watcher template refuses a missing image, a bad namespace and a bad checksum" \
  "bash '$REPO_ROOT/install/forge-approver-watch-template.sh' --namespace tockmox-forge >/dev/null 2>&1; echo \$?; bash '$REPO_ROOT/install/forge-approver-watch-template.sh' --namespace 'Bad_NS' --image a/b:1 >/dev/null 2>&1; echo \$?; bash '$REPO_ROOT/install/forge-approver-watch-template.sh' --namespace x --image a/b:1 --script-sha 'a;b' >/dev/null 2>&1; echo \$?" \
  "$(printf '2\n2\n2')"

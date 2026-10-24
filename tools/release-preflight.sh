#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# RELEASE PREFLIGHT: the deterministic half of RELEASING.md, asserted on the
# tree rather than remembered.
#
# RELEASING.md says a version bump is five edits, not one, and lists four
# prose files that carry a version-shaped value nothing regenerates. Every one
# of those has already shipped wrong at least once: the installer read 0.1.0
# through 0.5.0, the example config shipped `main` for thirteen days after the
# tag, a docs page opened "Tockmox is at v0.1.0" under a footer stamped v0.6.0,
# and the site template pinned the previous release while claiming the new one.
# None of it broke a build. All of it was a checklist item somebody read past.
#
# This script takes the version about to be tagged and asserts, in order:
#
#   1. versions     the five bump locations agree on X.Y.Z: every Chart.yaml
#                   `version:`, every layer's tockmox-common dependency pin,
#                   every Chart.lock's tockmox-common entry (the artefact of
#                   `helm dependency update`), the SBOM's root component, and
#                   `VERSION=` in install/tockmox-install.sh ... plus the
#                   generated docs footers, which are the sixth thing that
#                   quietly names a version
#   2. prose        the four hand-maintained files name vX.Y.Z where they name
#                   a tag at all (install/tockmox.yaml.example `revision:`,
#                   docs/deployment/profiles.md `targetRevision:`,
#                   docs/administration/configuration.md "Tockmox is at v",
#                   docs/administration/customising.md `?ref=`), and every
#                   other `vN.N.N` in install/, docs/ and README.md that is not
#                   the target is LISTED for a human to read, because
#                   RELEASING.md says "read every hit" and some hits are
#                   deliberate history
#   3. changelog    the top-most `## [` section of CHANGELOG.md is [X.Y.Z],
#                   which is the same reading rule tools/check-values-tiers.sh
#                   uses; `[Unreleased]` here means the rename has not happened
#                   (run the drift gate first, then rename, then re-run this)
#   4. checksums    if a SHA256SUMS exists at the root or in dist/, it names
#                   tockmox-X.Y.Z.tar.gz and every file it lists verifies;
#                   absent, the check is reported SKIP because the file is
#                   generated from the tag and cannot exist before it
#   5. site pin     if tockmox-site-template is checked out beside this repo,
#                   in $HOME/src, or at $TOCKMOX_SITE_TEMPLATE: exactly one
#                   `targetRevision: vX.Y.Z` per layer chart, every other
#                   `targetRevision:` still `main` (the operator's own repo,
#                   which a blanket sed would break), and the README's
#                   "Pinned to" line names the tag; then REPORTS, without
#                   failing, whether that tag resolves on the Tockmox
#                   repository the template points at (TM-0738). Three states:
#                   RESOLVES, WINDOW OPEN (the remote answered and has no such
#                   tag: expected, because the re-pin precedes the tag) and
#                   CANNOT CONFIRM (private repository, no network, no git).
#                   Only RESOLVES means the ref exists; the other two WARN.
#
# It STOPS AT THE FIRST FAIL. A release with a split version has nothing to
# gain from also learning its changelog heading is wrong; fix the first thing
# and run it again. WARN lines never stop it and are printed for reading.
#
# WHY THIS IS NOT check-*.sh AND IS NOT IN check-all.sh. AGENTS.md tells a
# contributor to enumerate the gates with `ls tools/check-*.sh`, and check-all.sh
# is that list executed. Every one of those runs on every pull request against
# the working tree with no arguments. This script needs a target version and is
# only meaningful in the hour before a tag; under the check-* name it would
# either fail every PR or be taught to skip, and a gate that usually skips is
# the shape of every decorative gate this directory has retired. The name is the
# scope.
#
# Usage:
#   tools/release-preflight.sh X.Y.Z            run the five checks
#   tools/release-preflight.sh --selftest       prove each check still refuses
#   tools/release-preflight.sh X.Y.Z --selftest same as --selftest
#
# Environment:
#   TOCKMOX_SITE_TEMPLATE   path to the site template checkout (check 5)
#   TOCKMOX_PIN_REMOTE      repository URL check 5 asks for the tag, instead of
#                           the repoURL the template's own pin names (tests,
#                           mirrors, a private fork)

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PROSE_FILES="install/tockmox.yaml.example docs/deployment/profiles.md docs/administration/configuration.md docs/administration/customising.md"
SEMVER_RE='^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*(-[0-9A-Za-z.]+)?$'
# a version-shaped token in prose: v0.6.0, v0.6.0-rc1
VTOKEN_RE='v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*(-[0-9A-Za-z.]*)?'

warns=0
warn() { echo "  WARN  $*"; warns=$((warns + 1)); }
fail() { echo "  FAIL  $*"; return 1; }

# --------------------------------------------------------------------------
# layer_charts ROOT
#
# The layer chart directories: charts/tockmox-* minus the library chart. The
# count is derived from the tree, never written down, because the site
# template check needs "one pin per layer" and a literal 9 would go stale the
# day a tenth layer lands.
# --------------------------------------------------------------------------
layer_charts() {
  for lc_d in "$1"/charts/tockmox-*; do
    [ -f "$lc_d/Chart.yaml" ] || continue
    [ "$(basename "$lc_d")" = "tockmox-common" ] && continue
    echo "$lc_d"
  done
}

# dep_version FILE  ... the version pinned for tockmox-common in a Chart.yaml
# or Chart.lock dependencies block (the first version: after the name line)
dep_version() {
  awk '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*tockmox-common[[:space:]]*$/ { want = 1; next }
    want && /^[[:space:]]*-[[:space:]]*name:/ { want = 0 }
    want && /^[[:space:]]*version:/ { sub(/^[[:space:]]*version:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; exit }
  ' "$1"
}

# --------------------------------------------------------------------------
# check_versions ROOT VER
# --------------------------------------------------------------------------
check_versions() {
  cv_root="$1"; cv_ver="$2"; cv_bad=0; cv_n=0

  for cv_f in "$cv_root"/charts/*/Chart.yaml; do
    [ -f "$cv_f" ] || continue
    cv_n=$((cv_n + 1))
    cv_got=$(awk '/^version:/ {print $2; exit}' "$cv_f" | tr -d '"')
    [ "$cv_got" = "$cv_ver" ] || { echo "        Chart.yaml version: $cv_got  ${cv_f#"$cv_root"/}"; cv_bad=1; }
  done
  [ "$cv_n" -gt 0 ] || { fail "no charts/*/Chart.yaml under $cv_root"; return 1; }
  echo "        $cv_n Chart.yaml files read"

  cv_layers=0
  for cv_d in $(layer_charts "$cv_root"); do
    cv_layers=$((cv_layers + 1))
    cv_got=$(dep_version "$cv_d/Chart.yaml")
    [ "$cv_got" = "$cv_ver" ] || { echo "        tockmox-common pin: ${cv_got:-<none>}  ${cv_d#"$cv_root"/}/Chart.yaml"; cv_bad=1; }
    if [ -f "$cv_d/Chart.lock" ]; then
      cv_got=$(dep_version "$cv_d/Chart.lock")
      [ "$cv_got" = "$cv_ver" ] || { echo "        Chart.lock tockmox-common: ${cv_got:-<none>}  ${cv_d#"$cv_root"/}/Chart.lock  (helm dependency update not run)"; cv_bad=1; }
    else
      echo "        no Chart.lock in ${cv_d#"$cv_root"/}  (helm dependency update not run)"; cv_bad=1
    fi
  done
  [ "$cv_layers" -gt 0 ] || { fail "no layer charts found"; return 1; }
  echo "        $cv_layers layer charts, dependency pins and locks read"

  if [ -f "$cv_root/sbom.cdx.json" ]; then
    cv_got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("metadata",{}).get("component",{}).get("version",""))' "$cv_root/sbom.cdx.json" 2>/dev/null)
    [ "$cv_got" = "$cv_ver" ] || { echo "        sbom.cdx.json metadata.component.version: ${cv_got:-<unreadable>}  (tools/gen-sbom.sh not run)"; cv_bad=1; }
  else
    echo "        no sbom.cdx.json  (tools/gen-sbom.sh not run)"; cv_bad=1
  fi

  if [ -f "$cv_root/install/tockmox-install.sh" ]; then
    cv_got=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$cv_root/install/tockmox-install.sh")
    [ "$cv_got" = "$cv_ver" ] || { echo "        install/tockmox-install.sh VERSION=\"${cv_got}\"  (the fifth edit)"; cv_bad=1; }
  else
    echo "        no install/tockmox-install.sh"; cv_bad=1
  fi

  # The generated footers. stamp-docs.sh --check owns this in CI; it is
  # repeated here because a release run that has not re-stamped is the same
  # defect as a split chart version, seen from the reader's side.
  if [ -d "$cv_root/docs" ]; then
    cv_stamps=$(grep -rn '<sub>Tockmox v' "$cv_root/docs" --include='*.md' 2>/dev/null)
    cv_total=$(printf '%s\n' "$cv_stamps" | grep -c '<sub>Tockmox v' || true)
    cv_wrong=$(printf '%s\n' "$cv_stamps" | grep '<sub>Tockmox v' | grep -v "<sub>Tockmox v$cv_ver " || true)
    if [ -n "$cv_wrong" ]; then
      printf '%s\n' "$cv_wrong" | sed "s|^$cv_root/||; s/^/        footer: /" | head -5
      echo "        ($(printf '%s\n' "$cv_wrong" | wc -l | tr -d ' ') footer(s) not on v$cv_ver of $cv_total; run tools/stamp-docs.sh)"
      cv_bad=1
    else
      echo "        $cv_total docs footers stamped v$cv_ver"
    fi
  fi

  [ "$cv_bad" -eq 0 ] || { fail "the bump locations do not agree on $cv_ver"; return 1; }
  return 0
}

# --------------------------------------------------------------------------
# check_prose ROOT VER
# --------------------------------------------------------------------------
check_prose() {
  cp_root="$1"; cp_ver="$2"; cp_bad=0

  # Anchored fields: these FAIL, because each is the value an operator copies.
  cp_f="$cp_root/install/tockmox.yaml.example"
  if [ -f "$cp_f" ]; then
    cp_got=$(awk '/^[[:space:]]*revision:/ {print $2; exit}' "$cp_f" | tr -d '"')
    [ "$cp_got" = "v$cp_ver" ] || { echo "        install/tockmox.yaml.example revision: ${cp_got:-<none>}"; cp_bad=1; }
  else
    echo "        missing install/tockmox.yaml.example"; cp_bad=1
  fi

  cp_f="$cp_root/docs/deployment/profiles.md"
  if [ -f "$cp_f" ]; then
    cp_hits=$(grep -n 'targetRevision:' "$cp_f" | grep -E "$VTOKEN_RE" | grep -v "targetRevision: v$cp_ver\b" || true)
    [ -z "$cp_hits" ] || { printf '%s\n' "$cp_hits" | sed 's/^/        docs\/deployment\/profiles.md:/'; cp_bad=1; }
  else
    echo "        missing docs/deployment/profiles.md"; cp_bad=1
  fi

  cp_f="$cp_root/docs/administration/configuration.md"
  if [ -f "$cp_f" ]; then
    cp_hits=$(grep -n 'Tockmox is at v' "$cp_f" | grep -v "Tockmox is at v$cp_ver\b" || true)
    [ -z "$cp_hits" ] || { printf '%s\n' "$cp_hits" | sed 's/^/        docs\/administration\/configuration.md:/'; cp_bad=1; }
  else
    echo "        missing docs/administration/configuration.md"; cp_bad=1
  fi

  cp_f="$cp_root/docs/administration/customising.md"
  if [ -f "$cp_f" ]; then
    cp_hits=$(grep -n '?ref=' "$cp_f" | grep -E "\?ref=$VTOKEN_RE" | grep -v "?ref=v$cp_ver\b" || true)
    [ -z "$cp_hits" ] || { printf '%s\n' "$cp_hits" | sed 's/^/        docs\/administration\/customising.md:/'; cp_bad=1; }
  else
    echo "        missing docs/administration/customising.md"; cp_bad=1
  fi

  # The read-every-hit list. Footers are excluded (check 1 owns them) and so is
  # docs/deployment/upgrade.md, whose illustrative version pairs are deliberate
  # per the release procedure. Everything else is printed, not judged. The
  # token is restricted to the target's MAJOR line (the release procedure's own
  # `grep -rn 'v0\.'`), or Helm v3.16.3 and Traefik v3.7.12 flood the list.
  cp_major="${cp_ver%%.*}"
  cp_sweep_re="v${cp_major}\.[0-9][0-9]*\.[0-9][0-9]*(-[0-9A-Za-z.]*)?"
  cp_sweep=$(cd "$cp_root" && grep -rnE "$cp_sweep_re" install/ docs/ README.md 2>/dev/null \
               | grep -v '<sub>Tockmox v' \
               | grep -v '^docs/deployment/upgrade.md:' \
               | grep -vE "v$cp_ver([^0-9A-Za-z.-]|$)" \
               | grep -vE "v$cp_ver\$" || true)
  if [ -n "$cp_sweep" ]; then
    cp_n=$(printf '%s\n' "$cp_sweep" | wc -l | tr -d ' ')
    warn "$cp_n line(s) name a version other than v$cp_ver; read each one (RELEASING.md):"
    printf '%s\n' "$cp_sweep" | awk -F: '{print $1}' | sort | uniq -c | sed 's/^/          /'
    for cp_pf in $PROSE_FILES; do
      printf '%s\n' "$cp_sweep" | grep "^$cp_pf:" | cut -c1-160 | sed 's/^/          /'
    done
  else
    echo "        no version token other than v$cp_ver in install/, docs/, README.md (upgrade.md excluded)"
  fi

  [ "$cp_bad" -eq 0 ] || { fail "a hand-maintained prose value does not name v$cp_ver"; return 1; }
  return 0
}

# --------------------------------------------------------------------------
# check_changelog ROOT VER
# --------------------------------------------------------------------------
check_changelog() {
  cc_root="$1"; cc_ver="$2"
  cc_f="$cc_root/CHANGELOG.md"
  [ -f "$cc_f" ] || { fail "no CHANGELOG.md"; return 1; }
  cc_head=$(grep -m1 '^## \[' "$cc_f" || true)
  [ -n "$cc_head" ] || { fail "CHANGELOG.md has no '## [' heading"; return 1; }
  cc_name=$(printf '%s\n' "$cc_head" | sed 's/^## \[\([^]]*\)\].*/\1/')
  echo "        top-most section: $cc_head"
  if [ "$cc_name" = "Unreleased" ]; then
    fail "CHANGELOG.md still opens with [Unreleased]; rename it to [$cc_ver] ... AFTER tools/check-values-tiers.sh --drift-only has run green (it reads the same top-most section, so run it, rename, then run this again)"
    return 1
  fi
  [ "$cc_name" = "$cc_ver" ] || { fail "top-most CHANGELOG section is [$cc_name], not [$cc_ver]"; return 1; }
  printf '%s\n' "$cc_head" | grep -E '[0-9]{4}-[0-9]{2}-[0-9]{2}' >/dev/null \
    || warn "the [$cc_ver] heading carries no date; released sections read '## [X.Y.Z] ... YYYY-MM-DD'"
  grep -q "^\[$cc_ver\]:" "$cc_f" \
    || warn "no link-reference definition '[$cc_ver]: ...' at the foot of CHANGELOG.md"
  return 0
}

# --------------------------------------------------------------------------
# check_sums ROOT VER
# --------------------------------------------------------------------------
sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then echo "sha256sum"; return; fi
  if command -v shasum >/dev/null 2>&1; then echo "shasum -a 256"; return; fi
  echo ""
}

check_sums() {
  cs_root="$1"; cs_ver="$2"; cs_file=""
  for cs_c in "$cs_root/SHA256SUMS" "$cs_root/dist/SHA256SUMS"; do
    [ -f "$cs_c" ] && { cs_file="$cs_c"; break; }
  done
  if [ -z "$cs_file" ]; then
    echo "        no SHA256SUMS at the root or in dist/; it is generated from the tag (RELEASING.md, Checksums)"
    return 2
  fi
  echo "        ${cs_file#"$cs_root"/}"
  grep -q "tockmox-$cs_ver\.tar\.gz" "$cs_file" \
    || { fail "SHA256SUMS does not list tockmox-$cs_ver.tar.gz (a stale file from the previous release?)"; return 1; }
  cs_tool=$(sha_tool)
  [ -n "$cs_tool" ] || { fail "neither sha256sum nor shasum is on PATH"; return 1; }
  cs_out=$(cd "$(dirname "$cs_file")" && $cs_tool -c "$(basename "$cs_file")" 2>&1); cs_rc=$?
  printf '%s\n' "$cs_out" | sed 's/^/        /'
  [ "$cs_rc" -eq 0 ] || { fail "a file listed in SHA256SUMS is missing or does not verify"; return 1; }
  return 0
}

# --------------------------------------------------------------------------
# check_site_template DIR VER NLAYERS
#
# Two counts, both asserted, because the first passes while the second is
# wrong: N lines pinned to the release, and every remaining targetRevision on
# `main`. Each layer Application has two sources (the Tockmox charts and the
# operator's site repo); a SITE-ONLY Application has one, pointed at the
# operator's repo and never at a release.
#
# The `main` count is therefore N + however many site-only Applications the
# template ships, and that number is NOT hard-coded ... it derives from
# ST_SITE_ONLY below. It was `N + 1` until 0.6.1, when the template gained
# site-secrets.yaml (TM-0698) and this check refused a correctly re-pinned
# tree: it wanted 10 `main` lines against 11, and demanded a release pin in
# site-secrets.yaml, which must never carry one. Adding a site-only
# Application is now ONE edit, to the list.
# --------------------------------------------------------------------------
# Applications that sync the OPERATOR'S own repository rather than Tockmox's.
# Single-source, so they carry `main` and must never carry a release pin.
ST_SITE_ONLY="site-apps.yaml site-secrets.yaml"

check_site_template() {
  st_dir="$1"; st_ver="$2"; st_n="$3"; st_bad=0
  st_apps="$st_dir/bootstrap/applications"
  [ -d "$st_apps" ] || { fail "$st_apps is not a directory"; return 1; }
  # Counted from the tree, not from the length of ST_SITE_ONLY: a template that
  # ships only site-apps.yaml is valid, and one that ships both is valid. This
  # check is about PIN DISCIPLINE ... every Tockmox source on the release, every
  # operator source on main ... not about which files the template ought to
  # contain. The template's own pin-consistency workflow owns its inventory.
  st_site_n=0
  for st_f in "$st_apps"/*.yaml; do
    case " $ST_SITE_ONLY " in *" $(basename "$st_f") "*) st_site_n=$((st_site_n + 1)) ;; esac
  done
  st_all=$(cat "$st_apps"/*.yaml 2>/dev/null | grep 'targetRevision:' | sed 's/^[[:space:]]*//' | sort | uniq -c)
  printf '%s\n' "$st_all" | sed 's/^/        /'
  st_pinned=$(cat "$st_apps"/*.yaml 2>/dev/null | grep -c "targetRevision: v$st_ver\$" || true)
  st_main=$(cat "$st_apps"/*.yaml 2>/dev/null | grep -c 'targetRevision: main$' || true)
  st_total=$(cat "$st_apps"/*.yaml 2>/dev/null | grep -c 'targetRevision:' || true)
  [ "$st_pinned" -eq "$st_n" ] \
    || { echo "        $st_pinned line(s) on targetRevision: v$st_ver, want $st_n (one per layer chart)"; st_bad=1; }
  [ "$st_main" -eq $((st_n + st_site_n)) ] \
    || { echo "        $st_main line(s) on targetRevision: main, want $((st_n + st_site_n)) = $st_n layer(s) + $st_site_n site-only (the operator's own repo; a blanket sed breaks these)"; st_bad=1; }
  [ "$((st_pinned + st_main))" -eq "$st_total" ] \
    || { echo "        $((st_total - st_pinned - st_main)) targetRevision line(s) on neither v$st_ver nor main"; st_bad=1; }
  # One pin per FILE as well as N in total, so two pins in one file and none
  # in another cannot sum to the right number.
  for st_f in "$st_apps"/*.yaml; do
    st_b=$(basename "$st_f")
    st_c=$(grep -c "targetRevision: v$st_ver\$" "$st_f" || true)
    case " $ST_SITE_ONLY " in
      *" $st_b "*)
        [ "$st_c" -eq 0 ] \
          || { echo "        $st_b carries a release pin and must not: it syncs YOUR repository"; st_bad=1; } ;;
      *)
        [ "$st_c" -eq 1 ] \
          || { echo "        $st_b has $st_c release pin(s), want 1"; st_bad=1; } ;;
    esac
  done
  if [ -f "$st_dir/README.md" ]; then
    grep -q "Pinned to \*\*v$st_ver\*\*" "$st_dir/README.md" \
      || { echo "        README.md: $(grep -m1 'Pinned to' "$st_dir/README.md" || echo '<no Pinned to line>')  want: Pinned to **v$st_ver**"; st_bad=1; }
  else
    echo "        no README.md in the site template"; st_bad=1
  fi
  [ "$st_bad" -eq 0 ] || { fail "tockmox-site-template is not pinned to v$st_ver"; return 1; }
  # Consistent pins say the template AGREES with the release, not that the ref
  # exists. Say which, without failing: see pin_resolution.
  pin_resolution "$st_dir" "$st_ver"; st_res=$?
  case "$st_res" in
    0) ;;
    1) warn "the pin is consistent but v$st_ver is not a tag yet (re-pin window open; close it by tagging)" ;;
    *) warn "the pin is consistent; whether v$st_ver resolves could NOT be confirmed from here" ;;
  esac
  return 0
}

# --------------------------------------------------------------------------
# template_pin_remote DIR VER ... the repoURL of the source the release pin sits
# on, i.e. the Tockmox repository the template tells ArgoCD to fetch. The
# operator's own source (PLACEHOLDER, targetRevision main) is never the one.
# TOCKMOX_PIN_REMOTE overrides it.
# --------------------------------------------------------------------------
template_pin_remote() {
  [ -n "${TOCKMOX_PIN_REMOTE:-}" ] && { printf '%s\n' "$TOCKMOX_PIN_REMOTE"; return 0; }
  cat "$1"/bootstrap/applications/*.yaml 2>/dev/null | awk -v want="targetRevision: v$2" '
    /repoURL:/ { u = $0; sub(/.*repoURL:[[:space:]]*/, "", u); gsub(/["'"'"']/, "", u) }
    { l = $0; sub(/^[[:space:]]*/, "", l) }
    l == want { print u; exit }'
}

# --------------------------------------------------------------------------
# pin_resolution DIR VER ... does v$VER exist as a tag on the remote the template
# names? Exit codes, deliberately distinct because the three states mean three
# different things to the person reading them:
#
#   0  RESOLVES        git ls-remote found refs/tags/vVER. The only state that
#                      says the ref exists.
#   1  WINDOW OPEN     the remote ANSWERED and has no such tag. Expected between
#                      the re-pin and the tag (RELEASING.md, "The re-pin window"),
#                      because the re-pin is merged before the tag is cut. It is
#                      reported, not failed: failing it would make check 5
#                      unpassable at the only moment it runs.
#   3  CANNOT CONFIRM  ls-remote did not answer: a private repository (no
#                      credentials, and prompting is off), no network, no git, a
#                      timeout, or no repoURL to ask. NEVER reported as a pass.
#
# `--exit-code` makes git say "answered, nothing matched" (2) apart from
# "did not answer" (128 and friends); that split is the whole point.
# --------------------------------------------------------------------------
pin_resolution() {
  pr_dir="$1"; pr_ver="$2"
  pr_url=$(template_pin_remote "$pr_dir" "$pr_ver")
  if [ -z "$pr_url" ]; then
    echo "        CANNOT CONFIRM  no repoURL found beside the v$pr_ver pin in the template"; return 3
  fi
  command -v git >/dev/null 2>&1 || { echo "        CANNOT CONFIRM  git is not on PATH ($pr_url)"; return 3; }
  pr_to=""; command -v timeout >/dev/null 2>&1 && pr_to="timeout 30"
  pr_out=$(GIT_TERMINAL_PROMPT=0 $pr_to git ls-remote --exit-code --tags "$pr_url" "refs/tags/v$pr_ver" 2>&1); pr_rc=$?
  case "$pr_rc" in
    0) echo "        RESOLVES        v$pr_ver exists as a tag on $pr_url"; return 0 ;;
    2) echo "        WINDOW OPEN     $pr_url answered and has no tag v$pr_ver: until it is tagged, a clone of the public template names a ref that does not resolve"; return 1 ;;
    *) echo "        CANNOT CONFIRM  could not ask $pr_url (private repository, no network or a timeout; git exit $pr_rc). The ref may or may not exist"
       printf '%s\n' "$pr_out" | sed -n '1,2p' | sed 's/^/                        /'
       return 3 ;;
  esac
}

find_site_template() {
  for fs_c in "${TOCKMOX_SITE_TEMPLATE:-}" "$HOME/src/tockmox-site-template" "$ROOT/../tockmox-site-template"; do
    [ -n "$fs_c" ] && [ -d "$fs_c/bootstrap/applications" ] && { (cd "$fs_c" && pwd); return 0; }
  done
  return 1
}

# ==========================================================================
# selftest: fixtures only, never the real tree
# ==========================================================================
selftest() {
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  fails=0
  V=1.2.3

  mkrepo() { # mkrepo DIR VERSION  ... two layers + common, consistent at VERSION
    mk_d="$1"; mk_v="$2"
    for mk_l in tockmox-common tockmox-platform tockmox-policy; do
      mkdir -p "$mk_d/charts/$mk_l"
      printf 'apiVersion: v2\nname: %s\nversion: %s\n' "$mk_l" "$mk_v" > "$mk_d/charts/$mk_l/Chart.yaml"
      if [ "$mk_l" != "tockmox-common" ]; then
        printf 'dependencies:\n  - name: tockmox-common\n    version: %s\n    repository: "file://../tockmox-common"\n  - name: upstream\n    version: 9.9.9\n' "$mk_v" >> "$mk_d/charts/$mk_l/Chart.yaml"
        printf 'dependencies:\n- name: tockmox-common\n  repository: file://../tockmox-common\n  version: %s\n- name: upstream\n  version: 9.9.9\n' "$mk_v" > "$mk_d/charts/$mk_l/Chart.lock"
      fi
    done
    printf '{"metadata":{"component":{"name":"tockmox","version":"%s"}}}\n' "$mk_v" > "$mk_d/sbom.cdx.json"
    mkdir -p "$mk_d/install" "$mk_d/docs/deployment" "$mk_d/docs/administration"
    printf '#!/bin/sh\nVERSION="%s"\n' "$mk_v" > "$mk_d/install/tockmox-install.sh"
    printf 'tockmox:\n  revision: v%s\n' "$mk_v" > "$mk_d/install/tockmox.yaml.example"
    printf '    targetRevision: v%s\n    targetRevision: v%s\n\n<sub>Tockmox v%s &middot; footer</sub>\n' "$mk_v" "$mk_v" "$mk_v" > "$mk_d/docs/deployment/profiles.md"
    printf 'Tockmox is at v%s.\n\n<sub>Tockmox v%s &middot; footer</sub>\n' "$mk_v" "$mk_v" > "$mk_d/docs/administration/configuration.md"
    printf '  - github.com/tockmox/tockmox//charts/tockmox-policy?ref=YOUR_TOCKMOX_TAG\n\n<sub>Tockmox v%s &middot; footer</sub>\n' "$mk_v" > "$mk_d/docs/administration/customising.md"
    printf '| Patch | `v0.1.0` to `v0.1.1` |\n' > "$mk_d/docs/deployment/upgrade.md"
    printf '# Tockmox\n' > "$mk_d/README.md"
    printf '# Changelog\n\n## [%s] ... 2026-01-01\n\nShips.\n\n## [0.1.0] ... 2025-01-01\n\n[%s]: https://example/%s\n' "$mk_v" "$mk_v" "$mk_v" > "$mk_d/CHANGELOG.md"
  }

  mksite() { # mksite DIR VERSION NLAYERS
    ms_d="$1"; ms_v="$2"; ms_n="$3"
    mkdir -p "$ms_d/bootstrap/applications"
    ms_i=0
    while [ "$ms_i" -lt "$ms_n" ]; do
      printf 'sources:\n  - repoURL: https://github.com/tockmox/tockmox\n    targetRevision: v%s\n  - repoURL: PLACEHOLDER\n    targetRevision: main\n' "$ms_v" > "$ms_d/bootstrap/applications/layer-$ms_i.yaml"
      ms_i=$((ms_i + 1))
    done
    printf 'source:\n  targetRevision: main\n' > "$ms_d/bootstrap/applications/site-apps.yaml"
    printf '# Site\n\nPinned to **v%s**.\n' "$ms_v" > "$ms_d/README.md"
  }

  probe() { # probe LABEL pass|fail|skip COMMAND...
    p_label="$1"; p_want="$2"; shift 2
    p_out=$("$@" 2>&1); p_rc=$?
    p_ok=0
    case "$p_want" in
      pass) [ "$p_rc" -eq 0 ] && p_ok=1 ;;
      fail) [ "$p_rc" -ne 0 ] && [ "$p_rc" -ne 2 ] && p_ok=1 ;;
      skip) [ "$p_rc" -eq 2 ] && p_ok=1 ;;
    esac
    if [ "$p_ok" -eq 1 ]; then
      echo "  ok  $p_label"
    else
      echo "  SELFTEST FAIL: '$p_label' wanted $p_want, got rc=$p_rc:"
      printf '%s\n' "$p_out" | sed 's/^/            /'; fails=1
    fi
  }

  good="$tmp/good"; mkrepo "$good" "$V"

  echo "selftest: versions"
  probe "a consistent bump is accepted" pass check_versions "$good" "$V"
  probe "the target version is what is compared, not internal agreement" fail check_versions "$good" "1.2.4"
  r="$tmp/chart"; mkrepo "$r" "$V"; sed -i.bak "s/^version: $V/version: 1.2.2/" "$r/charts/tockmox-policy/Chart.yaml"
  probe "one Chart.yaml behind is refused" fail check_versions "$r" "$V"
  r="$tmp/pin"; mkrepo "$r" "$V"; sed -i.bak "s/    version: $V/    version: 1.2.2/" "$r/charts/tockmox-policy/Chart.yaml"
  probe "a stale tockmox-common dependency pin is refused" fail check_versions "$r" "$V"
  r="$tmp/lock"; mkrepo "$r" "$V"; sed -i.bak "s/  version: $V/  version: 1.2.2/" "$r/charts/tockmox-platform/Chart.lock"
  probe "a Chart.lock not regenerated is refused" fail check_versions "$r" "$V"
  r="$tmp/nolock"; mkrepo "$r" "$V"; rm "$r/charts/tockmox-platform/Chart.lock"
  probe "a missing Chart.lock is refused" fail check_versions "$r" "$V"
  r="$tmp/sbom"; mkrepo "$r" "$V"; printf '{"metadata":{"component":{"version":"1.2.2"}}}\n' > "$r/sbom.cdx.json"
  probe "a stale SBOM is refused" fail check_versions "$r" "$V"
  r="$tmp/inst"; mkrepo "$r" "$V"; printf '#!/bin/sh\nVERSION="0.1.0"\n' > "$r/install/tockmox-install.sh"
  probe "the installer left at 0.1.0 is refused (the fifth edit)" fail check_versions "$r" "$V"
  r="$tmp/stamp"; mkrepo "$r" "$V"; printf '<sub>Tockmox v1.2.2 &middot; footer</sub>\n' >> "$r/docs/deployment/profiles.md"
  probe "an unstamped docs footer is refused" fail check_versions "$r" "$V"

  echo "selftest: prose"
  probe "prose naming the target is accepted" pass check_prose "$good" "$V"
  r="$tmp/rev"; mkrepo "$r" "$V"; printf 'tockmox:\n  revision: main\n' > "$r/install/tockmox.yaml.example"
  probe "tockmox.yaml.example revision: main is refused" fail check_prose "$r" "$V"
  r="$tmp/prof"; mkrepo "$r" "$V"; sed -i.bak '1s/.*/    targetRevision: v1.2.2/' "$r/docs/deployment/profiles.md"
  probe "one stale targetRevision in profiles.md is refused" fail check_prose "$r" "$V"
  r="$tmp/conf"; mkrepo "$r" "$V"; sed -i.bak '1s/.*/Tockmox is at v0.1.0./' "$r/docs/administration/configuration.md"
  probe "configuration.md opening on an old version is refused" fail check_prose "$r" "$V"
  r="$tmp/cust"; mkrepo "$r" "$V"; sed -i.bak 's/?ref=YOUR_TOCKMOX_TAG/?ref=v1.2.2/' "$r/docs/administration/customising.md"
  probe "customising.md ?ref= naming an old tag is refused" fail check_prose "$r" "$V"
  r="$tmp/hist"; mkrepo "$r" "$V"; printf 'Through v1.2.2 this shipped off.\n' >> "$r/docs/administration/configuration.md"
  probe "a historical mention elsewhere in the file is a WARN, not a refusal" pass check_prose "$r" "$V"
  p_out=$(check_prose "$r" "$V" 2>&1)
  case "$p_out" in *"WARN"*"configuration.md"*) echo "  ok  and the historical mention is listed for reading" ;;
    *) echo "  SELFTEST FAIL: the historical mention was not listed"; printf '%s\n' "$p_out" | sed 's/^/            /'; fails=1 ;; esac

  echo "selftest: changelog"
  probe "top-most section [$V] is accepted" pass check_changelog "$good" "$V"
  r="$tmp/unrel"; mkrepo "$r" "$V"; sed -i.bak "s/^## \[$V\] ... 2026-01-01/## [Unreleased]/" "$r/CHANGELOG.md"
  probe "an un-renamed [Unreleased] is refused" fail check_changelog "$r" "$V"
  r="$tmp/older"; mkrepo "$r" "$V"; sed -i.bak "s/^## \[$V\]/## [1.2.2]/" "$r/CHANGELOG.md"
  probe "a top-most section naming another version is refused" fail check_changelog "$r" "$V"
  r="$tmp/deep"; mkrepo "$r" "$V"; printf '# Changelog\n\n## [Unreleased]\n\n## [%s] ... 2026-01-01\n' "$V" > "$r/CHANGELOG.md"
  probe "the target section below [Unreleased] does not count" fail check_changelog "$r" "$V"
  r="$tmp/nolog"; mkrepo "$r" "$V"; rm "$r/CHANGELOG.md"
  probe "no CHANGELOG.md is refused" fail check_changelog "$r" "$V"

  echo "selftest: checksums"
  probe "no SHA256SUMS is a SKIP" skip check_sums "$good" "$V"
  if [ -n "$(sha_tool)" ]; then
    r="$tmp/sums"; mkrepo "$r" "$V"; printf 'archive\n' > "$r/tockmox-$V.tar.gz"
    (cd "$r" && $(sha_tool) "tockmox-$V.tar.gz" > SHA256SUMS)
    probe "a SHA256SUMS that verifies is accepted" pass check_sums "$r" "$V"
    printf 'changed\n' > "$r/tockmox-$V.tar.gz"
    probe "an archive that no longer matches is refused" fail check_sums "$r" "$V"
    rm "$r/tockmox-$V.tar.gz"
    probe "an archive listed but absent is refused" fail check_sums "$r" "$V"
    r="$tmp/oldsums"; mkrepo "$r" "$V"; printf 'old\n' > "$r/tockmox-1.2.2.tar.gz"
    (cd "$r" && $(sha_tool) "tockmox-1.2.2.tar.gz" > SHA256SUMS)
    probe "a SHA256SUMS for the previous release is refused even though it verifies" fail check_sums "$r" "$V"
  else
    echo "  (no sha256sum/shasum on PATH; checksum probes not run)"
  fi

  echo "selftest: site template"
  # check_site_template now asks a remote whether the pin resolves. The selftest
  # must never depend on the network or on github.com, so it points the question
  # at local fixture repositories: one that HAS the tag, one that does not.
  if command -v git >/dev/null 2>&1; then
    rtag="$tmp/remote-tagged"; rnone="$tmp/remote-untagged"
    for rr in "$rtag" "$rnone"; do
      git init -q "$rr" && (cd "$rr" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x)
    done
    (cd "$rtag" && git tag "v$V")
    export TOCKMOX_PIN_REMOTE="$rtag"
  fi
  s="$tmp/site"; mksite "$s" "$V" 2
  probe "a correctly re-pinned template is accepted" pass check_site_template "$s" "$V" 2
  s="$tmp/site2"; mksite "$s" "$V" 2
  printf 'source:\n  targetRevision: main\n' > "$s/bootstrap/applications/site-secrets.yaml"
  probe "a SECOND site-only Application is accepted, count derived not literal" pass check_site_template "$s" "$V" 2
  s="$tmp/site2pin"; mksite "$s" "$V" 2
  printf 'sources:\n  - targetRevision: v%s\n  - targetRevision: main\n' "$V" > "$s/bootstrap/applications/site-secrets.yaml"
  probe "a site-only Application carrying a release pin is refused" fail check_site_template "$s" "$V" 2
  s="$tmp/site-old"; mksite "$s" "1.2.2" 2
  probe "the previous release's pins are refused" fail check_site_template "$s" "$V" 2
  s="$tmp/site-sed"; mksite "$s" "$V" 2; sed -i.bak "s/targetRevision: main/targetRevision: v$V/" "$s"/bootstrap/applications/*.yaml; rm -f "$s"/bootstrap/applications/*.bak
  probe "a blanket sed that pinned the site repo lines is refused" fail check_site_template "$s" "$V" 2
  s="$tmp/site-readme"; mksite "$s" "$V" 2; printf 'Pinned to **v1.2.2**.\n' > "$s/README.md"
  probe "a README still saying the previous pin is refused" fail check_site_template "$s" "$V" 2
  s="$tmp/site-half"; mksite "$s" "$V" 2; sed -i.bak "s/targetRevision: v$V/targetRevision: v1.2.2/" "$s/bootstrap/applications/layer-1.yaml"
  probe "one layer left behind is refused" fail check_site_template "$s" "$V" 2
  s="$tmp/site-count"; mksite "$s" "$V" 3
  probe "the pin count is derived from the layer count, not a literal" fail check_site_template "$s" "$V" 2

  if command -v git >/dev/null 2>&1; then
    echo "selftest: does the pinned ref resolve (TM-0738)"
    probe_rc() { # probe_rc LABEL WANT_RC COMMAND...  ... exact exit code, the three states differ
      pr_label="$1"; pr_want="$2"; shift 2
      pr_o=$("$@" 2>&1); pr_c=$?
      if [ "$pr_c" -eq "$pr_want" ]; then echo "  ok  $pr_label"
      else echo "  SELFTEST FAIL: '$pr_label' wanted rc=$pr_want, got rc=$pr_c:"; printf '%s\n' "$pr_o" | sed 's/^/            /'; fails=1; fi
    }
    probe_out() { # probe_out LABEL REGEX COMMAND...  ... the state NAME is printed, not only the code
      po_label="$1"; po_re="$2"; shift 2
      po_o=$("$@" 2>&1)
      if printf '%s\n' "$po_o" | grep -E "$po_re" >/dev/null; then echo "  ok  $po_label"
      else echo "  SELFTEST FAIL: '$po_label' wanted /$po_re/:"; printf '%s\n' "$po_o" | sed 's/^/            /'; fails=1; fi
    }
    s="$tmp/site-res"; mksite "$s" "$V" 2
    TOCKMOX_PIN_REMOTE="$rtag"  probe_rc  "a remote that has the tag RESOLVES (0)" 0 pin_resolution "$s" "$V"
    TOCKMOX_PIN_REMOTE="$rtag"  probe_out "...and says RESOLVES, not WINDOW OPEN" 'RESOLVES ' pin_resolution "$s" "$V"
    TOCKMOX_PIN_REMOTE="$rnone" probe_rc  "a remote that answers without the tag is WINDOW OPEN (1)" 1 pin_resolution "$s" "$V"
    TOCKMOX_PIN_REMOTE="$rnone" probe_out "...and says WINDOW OPEN" 'WINDOW OPEN' pin_resolution "$s" "$V"
    TOCKMOX_PIN_REMOTE="$tmp/no-such-repo" probe_rc  "a remote that does not answer is CANNOT CONFIRM (3), not a pass" 3 pin_resolution "$s" "$V"
    TOCKMOX_PIN_REMOTE="$tmp/no-such-repo" probe_out "...and says CANNOT CONFIRM" 'CANNOT CONFIRM' pin_resolution "$s" "$V"
    # a prefix of the tag must not count: v1.2.3 is not v1.2.30 and not v1.2.3-rc1
    (cd "$rnone" && git tag "v${V}-rc1")
    TOCKMOX_PIN_REMOTE="$rnone" probe_rc  "an rc tag does not make the final tag resolve (1)" 1 pin_resolution "$s" "$V"
    # with no override the URL is read from the template's own pin
    s2="$tmp/site-url"; mksite "$s2" "$V" 2
    sed -i.bak "s#repoURL: https://github.com/tockmox/tockmox#repoURL: $rtag#" "$s2"/bootstrap/applications/layer-*.yaml
    (unset TOCKMOX_PIN_REMOTE; probe_rc "the remote comes from the repoURL beside the release pin (0)" 0 pin_resolution "$s2" "$V")
    s3="$tmp/site-nourl"; mksite "$s3" "$V" 2; sed -i.bak '/repoURL: https/d' "$s3"/bootstrap/applications/layer-*.yaml
    (unset TOCKMOX_PIN_REMOTE; probe_rc "no repoURL beside the pin is CANNOT CONFIRM (3)" 3 pin_resolution "$s3" "$V")
    # the check as a whole: consistent pins + unresolved ref still PASSES but warns
    w0=$warns
    TOCKMOX_PIN_REMOTE="$rnone" probe "a consistent pin on an unresolvable ref passes check 5 but WARNS" pass check_site_template "$s" "$V" 2
    TOCKMOX_PIN_REMOTE="$rnone" check_site_template "$s" "$V" 2 >/dev/null 2>&1   # in this shell, so the counter moves
    [ "$warns" -gt "$w0" ] && echo "  ok  the unresolved ref raised a WARN" || { echo "  SELFTEST FAIL: no WARN raised for an unresolved ref"; fails=1; }
  fi

  if [ "$fails" -eq 0 ]; then
    echo "release-preflight --selftest: PASSED"; exit 0
  fi
  echo "release-preflight --selftest: FAILED"; exit 1
}

# ==========================================================================
# entry
# ==========================================================================
case "${1:-}" in
  --selftest) selftest ;;
  ""|-h|--help)
    echo "usage: tools/release-preflight.sh X.Y.Z [--selftest]"
    echo "       tools/release-preflight.sh --selftest"
    exit 1 ;;
esac
[ "${2:-}" = "--selftest" ] && selftest

VER="${1#v}"
printf '%s\n' "$VER" | grep -E "$SEMVER_RE" >/dev/null || {
  echo "release-preflight: \"$1\" is not a version (want X.Y.Z or X.Y.Z-rcN, with or without a leading v)"
  exit 1
}
command -v python3 >/dev/null 2>&1 || { echo "release-preflight: python3 is required (reads sbom.cdx.json)"; exit 1; }

echo "release preflight for v$VER"
echo "repository: $ROOT"

passed=0; skipped=0
run_check() { # run_check NAME FUNCTION ARGS...
  rc_name="$1"; shift
  printf '\n== %s ==\n' "$rc_name"
  "$@"; rc_rc=$?
  case "$rc_rc" in
    0) echo "  PASS  $rc_name"; passed=$((passed + 1)) ;;
    2) echo "  SKIP  $rc_name"; skipped=$((skipped + 1)) ;;
    *) echo
       echo "release-preflight: FAILED at \"$rc_name\"; later checks did not run."
       exit 1 ;;
  esac
}

run_check "1. the bump locations agree on $VER" check_versions "$ROOT" "$VER"
run_check "2. hand-maintained prose names v$VER" check_prose "$ROOT" "$VER"
run_check "3. CHANGELOG top-most section is [$VER]" check_changelog "$ROOT" "$VER"
run_check "4. SHA256SUMS names and verifies the archive" check_sums "$ROOT" "$VER"

nlayers=$(layer_charts "$ROOT" | wc -l | tr -d ' ')
if site=$(find_site_template); then
  echo
  echo "site template: $site"
  run_check "5. tockmox-site-template pinned to v$VER ($nlayers layers)" check_site_template "$site" "$VER" "$nlayers"
else
  printf '\n== 5. tockmox-site-template pinned to v%s ==\n' "$VER"
  echo "        not found beside this repo, in \$HOME/src, or at \$TOCKMOX_SITE_TEMPLATE"
  echo "        the re-pin is unverified, and it is the step the release procedure exists to not forget"
  echo "  SKIP  5. tockmox-site-template"
  skipped=$((skipped + 1))
fi

echo
echo "release-preflight v$VER: PASSED ($passed passed, $skipped skipped, $warns warning(s) to read)"
[ "$skipped" -eq 0 ] || echo "a SKIP is an unasserted step, not a green one; see the lines above"
exit 0

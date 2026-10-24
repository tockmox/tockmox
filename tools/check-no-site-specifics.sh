#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# NO SITE SPECIFICS IN THE PUBLISHED TREE.
#
# CONTRIBUTING.md tells contributors: no hostnames, no IPs, no node names. Until
# 2026-08-19 nothing enforced it, and the tree had drifted ... five references to
# a maintainer node name across four charts, and one real LoadBalancer address
# inside a quoted error message in the prerequisites doc. Every one arrived in a
# comment explaining where a defect was observed, which is exactly the honest
# writing this project wants and exactly how the leak happens.
#
# WHY THIS IS A GATE RATHER THAN A GREP IN A RUNBOOK. The publish model keeps
# the repository's real history rather than squashing it, so what ships is what
# is in the tree, checked at every commit rather than audited once at release.
# A manual grep in a markdown file is a control fed by an unconnected wire: it
# refuses nothing, because nobody runs it.
#
# WHAT THIS IS NOT. It is not a secret scanner ... gitleaks covers that, in its
# own job, over full history. Nothing this catches is a credential. The exposure
# class is "an internal topology is described in public", which is a positioning
# and reconnaissance cost, not a compromise.
#
# Usage:
#   tools/check-no-site-specifics.sh            check the tree
#   tools/check-no-site-specifics.sh --selftest prove the patterns actually fire
set -uo pipefail

cd "$(dirname "$0")/.."

# Scanned paths: everything that ships. Deliberately excludes .git, and excludes
# this file (it necessarily contains the patterns it hunts for).
#
# THE SCAN SET IS DERIVED, NOT LISTED. TM-0319, closed 2026-09-02.
#
# This was an allow list until today, and that was the defect. A top-level entry
# added after the list was written went unscanned and nothing said so: the gate
# passed, loudly, having looked at none of it. That is exactly how `tests/`
# arrived on 2026-09-02 carrying node names and LAN addresses through a green
# run of this check. Adding `tests` fixed the instance; the next new directory
# escaped the same way.
#
# So the default is inverted. `git ls-files` IS the set of things that ship, so
# new content is scanned BY DEFAULT and skipping something is a deliberate,
# reviewable act ... an entry in SCAN_EXCLUDE below, with a reason.
#
# The stated objection to doing this was that it "would newly fail the build on
# files nobody has reviewed against these patterns". MEASURED before changing
# it, rather than inherited: the eleven top-level entries the allow list was
# missing (.github, .gitsigners, images.txt, renovate.json5, sbom.cdx.json,
# CODE_OF_CONDUCT.md, DCO, LICENSE, LICENSE-docs, TRADEMARKS.md, .gitignore)
# produce ZERO findings across all four rules. The objection cost nothing to
# retire and would have cost a recurrence to keep.
#
# NOTHING IS EXCLUDED TODAY, on purpose. An exclude list that starts empty is
# one where every future entry has to be argued for.
SCAN_EXCLUDE=""

# Each rule is `label|regex`. Keep them narrow: a pattern that fires on
# legitimate documentation teaches people to add exemptions, and an exemption
# list nobody trusts is worse than no gate.
#
# example.com, example.org and the RFC 5737 documentation ranges are the
# sanctioned stand-ins and are never matched.
# WHY THIS DOES NOT MATCH RFC1918 GENERALLY. `192.168.1.0/24` is the canonical
# example of a home LAN and appears in this repository as exactly that: an
# example lanCIDR, MetalLB range or NFS target. 10.42/10.43 are k3s's own
# cluster and service CIDR defaults. Flagging those would fire on correct
# documentation, and a gate that cries wolf gets an exemption list, then gets
# ignored, then refuses nothing.
#
# THE PUBLIC RULES ARE GENERIC; A SITE'S OWN RULES ARE PRIVATE. The identifiers
# worth keeping out of this tree (a maintainer's node names, internal domain and
# LAN ranges) are exactly the ones that must not be written INTO it, and a
# scanner that publishes its own match list publishes the topology it guards.
# So the rules below catch the shape of an internal hostname, and a site adds its
# real ones from a file that never enters the repository:
#   TOCKMOX_SITE_PATTERNS_FILE   path to a `label|regex` file (one rule per line,
#                                # comments allowed); a path that does not exist
#                                makes this check REFUSE rather than pass
#   ~/.config/tockmox/site-patterns   read when the variable is unset and it exists
# CI writes the file from a repository secret when the secret is set; a fork's
# pull request runs the public rules only, and says so.
#
# WHY THE HOSTNAME RULE REQUIRES A SUBDOMAIN. A published contact address
# (`someone@<domain>`) is not a site specific; `grafana.int.<domain>` is. A label,
# `int` and a dot separate the two, and the selftest asserts both halves.
RULES="
internal git host|git\.int\.
internal hostname|[A-Za-z0-9_-]+\.int\.[A-Za-z0-9-]+\.[A-Za-z]{2,}
"
PATTERNS_FILE="${TOCKMOX_SITE_PATTERNS_FILE:-}"
if [ -z "$PATTERNS_FILE" ] && [ -f "${HOME:-/nonexistent}/.config/tockmox/site-patterns" ]; then
  PATTERNS_FILE="$HOME/.config/tockmox/site-patterns"
fi
load_site_rules() { # file -> appends its rules to RULES; refuses a named file that is absent
  [ -n "$1" ] || return 0
  if [ ! -r "$1" ]; then
    echo "check-no-site-specifics: REFUSING ... TOCKMOX_SITE_PATTERNS_FILE names '$1', which"
    echo "  cannot be read. A site rule set that silently failed to load would pass"
    echo "  having checked for nothing it was asked to."
    exit 2
  fi
  extra=$(grep -vE '^[[:space:]]*(#|$)' "$1" | grep '|' || true)
  RULES="$RULES
$extra"
  SITE_RULES_N=$(printf '%s\n' "$extra" | grep -c '|' || true)
}
SITE_RULES_N=0

scan() {
  target_paths="$1"
  found=0
  printf '%s\n' "$RULES" | while IFS='|' read -r label regex; do
    [ -z "${label:-}" ] && continue
    # -I skips binary, --exclude keeps this script out of its own results.
    hits=$(grep -rInE "$regex" $target_paths \
             --exclude=check-no-site-specifics.sh \
             2>/dev/null | grep -viE "example\.(com|org)|192\.0\.2\.|198\.51\.100\.|203\.0\.113\." || true)
    if [ -n "$hits" ]; then
      echo "  FAIL  $label"
      printf '%s\n' "$hits" | sed 's/^/          /'
      found=1
    fi
  done
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  # A gate that has never been observed to refuse anything is indistinguishable
  # from a gate that cannot refuse. Build a tree that MUST fail and assert it
  # does, per rule, before trusting a pass on the real tree.
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/docs"
  fails=0

  # probe() runs this script's own scan(), so it exercises RULES and the
  # exemption filter as shipped. It used to grep with copies of the two
  # regexes, which kept passing with a rule deleted or the filter removed.
  probe() {
    name="$1"; content="$2"; label="$3"
    printf '%s\n' "$content" > "$tmp/docs/probe.md"
    out=$(cd "$tmp" && scan docs)
    if grep -q "FAIL  $label" <<<"$out"; then
      echo "  selftest ok: $name"
    else
      echo "  SELFTEST FAIL: rule '$label' did not fire on: $content"
      fails=1
    fi
  }

  probe "git host"       "clone from git.int.example-internal"   "internal git host"
  probe "internal host"  "see grafana.int.acme-lab.net for details" "internal hostname"

  # A SITE RULE FILE IS LOADED, and a named file that is missing REFUSES. Uses a
  # synthetic pattern, never a real site's: the point is the loading path.
  printf '# synthetic\nselftest node name|acme-node-[0-9]\n' > "$tmp/site-patterns"
  printf 'observed on acme-node-7 today\n' > "$tmp/docs/probe.md"
  # The copy goes in tools/ because the script changes to its parent directory.
  ( cd "$tmp" && git init -q . && git add -A ) >/dev/null 2>&1
  mkdir -p "$tmp/tools"; cp "$0" "$tmp/tools/check.sh"
  out=$(TOCKMOX_SITE_PATTERNS_FILE="$tmp/site-patterns" bash "$tmp/tools/check.sh" 2>&1); rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep 'FAIL  selftest node name' >/dev/null; then
    echo "  selftest ok: a site rule file is loaded and its rule fires"
  else
    echo "  SELFTEST FAIL: a rule from TOCKMOX_SITE_PATTERNS_FILE did not fire (exit $rc): $out"; fails=1
  fi
  # Exit 2 is also what a copy in the wrong place returns ("git tracked no files
  # here"), so the code alone cannot tell the two refusals apart. Require this
  # rule's own words, which name the missing file.
  out=$(TOCKMOX_SITE_PATTERNS_FILE="$tmp/absent" bash "$tmp/tools/check.sh" 2>&1); rc=$?
  if [ "$rc" = 2 ] && grep -qF "names '$tmp/absent'" <<<"$out"; then
    echo "  selftest ok: a named but missing site rule file refuses (exit 2)"
  else
    echo "  SELFTEST FAIL: a missing site rule file was not refused by that rule (exit $rc; wanted 2 and a message naming the file): $out"; fails=1
  fi
  rm -rf "$tmp/.git" "$tmp/tools" "$tmp/site-patterns"

  # The other direction, and it is the half that keeps the gate believed: the
  # sanctioned stand-ins and the legitimate generic examples must NOT fire.
  # A gate that flags correct documentation gets an exemption list, then gets
  # ignored. This asserts it does not.
  cat > "$tmp/docs/probe.md" <<'PROBE'
reach https://auth.int.example.com at 192.0.2.10
lanCIDR: 192.168.1.0/24
range: 192.168.1.200-192.168.1.220
clusterCIDR: 10.42.0.0/16
serviceCIDR: 10.43.0.0/16
report a vulnerability to security@example.org
Signed-off-by: A Contributor <contributor@example.net>
PROBE
  clean_out=$(cd "$tmp" && scan docs)
  if [ -n "$clean_out" ]; then
    echo "  SELFTEST FAIL: a legitimate example was flagged:"
    printf '%s\n' "$clean_out" | sed 's/^/            /'
    fails=1
  else
    echo "  selftest ok: example.com, 192.0.2.x, 192.168.x and the k3s CIDRs are not flagged"
  fi

  # THE CLASS ASSERTION, and it is the one this gate did not have.
  #
  # Every probe above tests a RULE. None of them tests the SCAN SET, which is
  # where the real defect lived: the rules were correct and simply never looked
  # at `tests/`. So build a throwaway repository with a top-level directory this
  # script has never heard of, put a node name in it, and assert the gate
  # REFUSES. A rules-only selftest passes just as happily on a gate that scans
  # one file.
  if command -v git >/dev/null 2>&1; then
    newdir=$(mktemp -d)
    (
      cd "$newdir" || exit 1
      git init -q . 2>/dev/null
      git config user.email selftest@example.com 2>/dev/null
      git config user.name selftest 2>/dev/null
      mkdir -p a-directory-invented-for-this-selftest
      printf 'clone from git.int.example-internal\n' > a-directory-invented-for-this-selftest/note.md
      git add -A 2>/dev/null
    ) >/dev/null 2>&1
    # In tools/, because the script changes to its parent directory. It used to be
    # copied to the top, so it changed to the PARENT of the throwaway repo, found no
    # repository, refused with exit 2, and this assertion counted the refusal as a
    # pass: it had never tested the scan set. Exit 1 and the rule's own label now.
    mkdir -p "$newdir/tools"; cp "$0" "$newdir/tools/check-no-site-specifics.sh"
    out=$(cd "$newdir" && TOCKMOX_SITE_PATTERNS_FILE= HOME=/nonexistent bash tools/check-no-site-specifics.sh 2>&1); rc=$?
    if [ "$rc" = 1 ] && printf '%s' "$out" | grep 'FAIL  internal git host' >/dev/null; then
      echo "  selftest ok: a top-level directory this script never heard of is scanned"
    else
      echo "  SELFTEST FAIL: a NEW top-level directory carrying an internal host was not refused"
      echo "                 by the rule (exit $rc). The scan set is not derived from the tracked tree."
      fails=1
    fi
    rm -rf "$newdir"
  else
    echo "  SELFTEST FAIL: git absent, so the scan-set assertion could not run."
    echo "                 Refusing to report a pass for a check that did not execute."
    fails=1
  fi

  [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
  echo "selftest FAILED"
  exit 1
fi

# Derive the scan set from what actually ships. REFUSE rather than narrow: a
# gate that quietly falls back to a shorter list is the failure this change
# exists to remove, and "exit 0 having examined nothing" is the one outcome
# these tools are not allowed to produce (testing-standard rule 1).
if ! command -v git >/dev/null 2>&1; then
  echo "check-no-site-specifics: REFUSING ... git is not on PATH, so the scan set"
  echo "  cannot be derived from the tracked tree. Run this in a checkout."
  exit 2
fi
tracked=$(git --no-optional-locks ls-files 2>/dev/null | awk -F/ '{print $1}' | sort -u)
if [ -z "$tracked" ]; then
  echo "check-no-site-specifics: REFUSING ... git tracked no files here. A pass"
  echo "  from an empty scan set would be a claim of coverage, not coverage."
  exit 2
fi

existing=""
for p in $tracked; do
  skip=0
  for x in $SCAN_EXCLUDE; do [ "$p" = "$x" ] && skip=1; done
  [ "$skip" -eq 1 ] && continue
  [ -e "$p" ] && existing="$existing $p"
done
if [ -z "$existing" ]; then
  echo "check-no-site-specifics: REFUSING ... every tracked entry was excluded."
  exit 2
fi
load_site_rules "$PATTERNS_FILE"
if [ "$SITE_RULES_N" -gt 0 ]; then
  echo "site rules: $SITE_RULES_N loaded from $PATTERNS_FILE (not printed)"
else
  echo "site rules: none loaded (set TOCKMOX_SITE_PATTERNS_FILE); generic rules only"
fi
echo "checking for site specifics across:$existing"

report=$(scan "$existing")
if [ -n "$report" ]; then
  echo "$report"
  echo
  echo "check-no-site-specifics: FAILED"
  echo "CONTRIBUTING.md: no hostnames, no IPs, no node names in the published tree."
  echo "Use example.com / example.org and the RFC 5737 ranges (192.0.2.0/24,"
  echo "198.51.100.0/24, 203.0.113.0/24) instead. Keep the evidence and the date;"
  echo "it is only the identifier that has to go."
  exit 1
fi

echo "check-no-site-specifics: PASSED"

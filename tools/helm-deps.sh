#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fetch chart dependencies for every layer.
#
#   ./tools/helm-deps.sh            fetch, or check what is vendored, then check the bytes
#   ./tools/helm-deps.sh --record   the same, and record a new or bumped subchart in subcharts.sha256
#   ./tools/helm-deps.sh --selftest
#
# Run this once per clone before `helm template`, `helm lint` or `helm install`.
#
# WHY THIS EXISTS: `helm dependency build` needs every dependency's repository
# registered in the local helm config, even when Chart.lock is present. A fresh
# clone on a machine that has never added those repos fails with
#
#   Error: no repository definition for https://... Please add the missing
#   repos via 'helm repo add'
#
# ...which is easy to miss on a workstation that added them months ago and
# guaranteed on a CI runner. The repo list is DERIVED from the Chart.yaml files
# rather than hardcoded, so adding a dependency never requires remembering to
# add a repo here too.
#
# SHELL REQUIREMENT: none beyond POSIX-ish bash. This script is deliberately
# bash 3.2 clean, because macOS still ships bash 3.2.57 as /bin/bash and
# RELEASING.md tells the maintainer to run THIS script during a version bump.
# A release tool that only works on the CI runner is not a release tool. That
# is why the repo list is read with a `while read` loop rather than `mapfile`,
# which is bash 4.0+ and fails with "mapfile: command not found".
set -euo pipefail
cd "$(dirname "$0")/.."

# --selftest runs tools/test-helm-deps.sh: the offline path below is taken only
# when it is safe, and never reaches the network when it is.
RECORD=0
case "${1:-}" in
  --selftest) exec bash tools/test-helm-deps.sh ;;
  --record) RECORD=1 ;;
  "") ;;
  *) echo "usage: $0 [--record | --selftest]" >&2; exit 2 ;;
esac

# THE SUBCHART BYTE LOCK. Chart.lock pins each upstream subchart by name and
# version; its `digest:` hashes the dependency list, not the archives. So a
# chart repository, its CDN or a lapsed domain could serve other bytes under a
# version the lock already names, and both paths below would take them.
# subcharts.sha256 records one sha256 per upstream archive, committed beside
# Chart.lock, so the bytes are under the signed tag. Every run ends with
# verify_sums: an archive whose bytes differ from its line is refused, on the
# offline path and after a download alike, and is never re-recorded. An archive
# with no line (a new or bumped dependency) is refused unless --record, which
# adds its line and drops lines no Chart.lock pins. --record never changes the
# hash of a name and version already recorded: new bytes under an old version
# are a reason to stop and find out why, not to re-record.
# tools/check-subchart-sums.sh holds the file to every Chart.lock.
SUMS=subcharts.sha256
sha256_of() {  # <file> -> lowercase hex
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Attempts per network-touching helm call, including the first.
HELM_DEPS_RETRIES="${HELM_DEPS_RETRIES:-3}"

_retry_log="$(mktemp)"
_sums_new="$(mktemp)"
_sums_old="$(mktemp)"
trap 'rm -f "$_retry_log" "$_sums_new" "$_sums_old"' EXIT

# retry LABEL COMMAND... -- run COMMAND, retrying on failure with backoff.
#
# WHY THIS EXISTS. On the v0.6.0-rc1 bump PR, one subchart download
# returned a 504 from a GitHub release asset. `helm dependency build` exited 1,
# this script died under `set -e`, `charts/*/charts/` was never populated, and
# every later CI step failed on missing dependencies. The cost was not the
# outage -- the re-run took ten seconds. The cost was that a transient fetch
# presented as `capability framework FAILED`, which reads exactly like a real
# defect in the tree on a release PR, and burned most of an hour and four wrong
# hypotheses before anyone read the log from the top.
#
# So this does two things, and the second matters more than the first:
#   1. absorbs a transient failure, and
#   2. SAYS SO on stderr, and prints the underlying error when it finally
#      gives up -- so a 504 announces itself as a 504 instead of arriving
#      disguised as a coherence-guard regression.
retry() {
  local label="$1"; shift
  local attempt=1 delay=2
  while :; do
    if "$@" >"$_retry_log" 2>&1; then
      [ "$attempt" -gt 1 ] && echo "  ${label}: succeeded on attempt ${attempt}" >&2
      return 0
    fi
    if [ "$attempt" -ge "$HELM_DEPS_RETRIES" ]; then
      echo "  ${label}: failed after ${attempt} attempt(s); last error:" >&2
      sed 's/^/    /' "$_retry_log" | tail -5 >&2
      return 1
    fi
    echo "  ${label}: attempt ${attempt} failed, retrying in ${delay}s" >&2
    sed 's/^/    /' "$_retry_log" | tail -2 >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# OFFLINE PATH (D5). A tree that already carries every upstream
# subchart needs no network: a sandbox with no egress (the QA lane's test pod),
# or an airgapped site that carried the archives inside (docs/deployment/
# airgap.md, step 3). There `helm repo add` can only fail, and check-all.sh
# runs this script first, so every gate failed for a reason that was not the
# tree. The offline path is taken only when, for every layer:
#   - Chart.lock exists and names the same dependencies as Chart.yaml (a lock
#     that no longer matches needs the network to re-resolve, so it goes the
#     online way and says so), and
#   - every non-file:// dependency's archive, <name>-<version>.tgz exactly as
#     Chart.lock pins it, is already in the layer's charts/.
# Then the only work is the local file:// dependencies (tockmox-common), which
# `helm package` rebuilds from source with no network, so a template edit in
# tockmox-common is never judged against a stale copy.
# HELM_DEPS_ONLINE=1 forces the online path (a dependency bump).
lock_deps() {  # <chart dir> -> "name<TAB>repository<TAB>version" per Chart.lock dependency
  awk '
    /^dependencies:/ {d=1; next}
    d && /^[^ -]/ {d=0}
    d && /^- name: /        {if (n!="") print n "\t" r "\t" v; n=$3; r=""; v=""; next}
    d && /^  repository: /  {r=$2; next}
    d && /^  version: /     {v=$2; next}
    END {if (n!="") print n "\t" r "\t" v}
  ' "$1/Chart.lock" | tr -d '"'
}
yaml_dep_names() {  # <chart dir> -> sorted dependency names in Chart.yaml
  awk '
    /^dependencies:/ {d=1; next}
    d && /^[^ -]/ {d=0}
    d && /^[ ]*- name: / {sub(/^[ ]*- name: */, ""); gsub(/"/, ""); print}
  ' "$1/Chart.yaml" | sort
}
offline_ok() {
  local c why=""
  for c in charts/tockmox-*; do
    [ "$c" = "charts/tockmox-common" ] && continue
    [ -f "$c/Chart.yaml" ] || continue
    grep -q '^dependencies:' "$c/Chart.yaml" || continue
    if [ ! -f "$c/Chart.lock" ]; then why="$c has no Chart.lock"; break; fi
    if [ "$(yaml_dep_names "$c")" != "$(lock_deps "$c" | cut -f1 | sort)" ]; then
      why="$c: Chart.lock does not name the dependencies Chart.yaml does"; break
    fi
    while IFS="$(printf '\t')" read -r n r v; do
      case "$r" in file://*) continue ;; esac
      [ -f "$c/charts/$n-$v.tgz" ] || { why="$c/charts/$n-$v.tgz is not in the tree"; break; }
    done <<LOCK
$(lock_deps "$c")
LOCK
    [ -z "$why" ] || break
  done
  [ -z "$why" ] && return 0
  echo "online: $why" >&2
  return 1
}
# verify_sums: every upstream archive a Chart.lock pins, against subcharts.sha256.
verify_sums() {
  local c p h actual bad=0 n_ok=0 n_new=0 n_drop=0
  if [ ! -f "$SUMS" ] && [ "$RECORD" != 1 ]; then
    echo "REFUSED: $SUMS does not exist, so no subchart archive can be checked. Record it with: HELM_DEPS_ONLINE=1 $0 --record" >&2
    return 1
  fi
  if [ -f "$SUMS" ]; then cat "$SUMS" > "$_sums_old"; else : > "$_sums_old"; fi
  : > "$_sums_new"
  for c in charts/tockmox-*; do
    [ -f "$c/Chart.lock" ] || continue
    while IFS="$(printf '\t')" read -r n r v; do
      [ -n "$n" ] || continue
      case "$r" in file://*) continue ;; esac
      p="$c/charts/$n-$v.tgz"
      if [ ! -f "$p" ]; then
        echo "  REFUSED: $p is not in the tree after the dependency step" >&2; bad=1; continue
      fi
      actual="$(sha256_of "$p")"
      h="$(awk -v p="$p" '$2 == p {print $1; exit}' "$_sums_old")"
      if [ -z "$h" ]; then
        if [ "$RECORD" = 1 ]; then
          printf '%s  %s\n' "$actual" "$p" >> "$_sums_new"
          echo "  recorded: $p $actual"
          n_new=$((n_new + 1))
        else
          echo "  REFUSED: $p has no line in $SUMS. A new or bumped subchart is recorded with: $0 --record" >&2
          bad=1
        fi
      elif [ "$h" != "$actual" ]; then
        echo "  REFUSED: $p does not match $SUMS: expected $h, found $actual. It was not replaced and is not re-recorded. Find out why the bytes changed under the same version before anything renders from it; then delete it and run this again." >&2
        bad=1
      else
        printf '%s  %s\n' "$h" "$p" >> "$_sums_new"
        n_ok=$((n_ok + 1))
      fi
    done <<LOCK
$(lock_deps "$c")
LOCK
  done
  [ "$bad" = 0 ] || return 1
  n_drop=$(( $(grep -c . "$_sums_old" || true) - n_ok ))
  if [ "$RECORD" = 1 ]; then
    LC_ALL=C sort -k2,2 "$_sums_new" > "$SUMS"
    [ "$n_drop" -gt 0 ] && echo "  dropped $n_drop line(s) no Chart.lock pins"
    echo "subchart bytes: $n_ok matched, $n_new recorded in $SUMS (commit it)"
  else
    [ "$n_drop" -gt 0 ] && echo "  note: $n_drop line(s) in $SUMS name an archive no Chart.lock pins; tools/check-subchart-sums.sh fails on them, and --record drops them" >&2
    echo "subchart bytes: $n_ok archive(s) match $SUMS"
  fi
  return 0
}

if [ "${HELM_DEPS_ONLINE:-0}" != 1 ] && offline_ok; then
  echo "offline: every upstream subchart is already in charts/*/charts (Chart.lock versions); no repository is contacted"
  for c in charts/tockmox-*; do
    [ -f "$c/Chart.lock" ] || continue
    while IFS="$(printf '\t')" read -r n r v; do
      case "$r" in file://*) ;; *) continue ;; esac
      helm package "$c/${r#file://}" -d "$c/charts" >/dev/null \
        || { echo "  $c: could not package its local dependency $n from ${r#file://}" >&2; exit 1; }
    done <<LOCK
$(lock_deps "$c")
LOCK
    printf '  %-34s %s\n' "$c" "ok (offline)"
  done
  verify_sums || exit 1
  echo "done"
  exit 0
fi

# bash 3.2 clean: `mapfile -t repos < <(...)` would be the modern spelling and
# does not exist before bash 4.0. IFS/newline discipline here is what keeps a
# URL containing spaces (there are none today) from splitting into two repos.
repos=()
while IFS= read -r _url; do
  [ -n "$_url" ] && repos+=("$_url")
done <<EOF
$(grep -h 'repository:' charts/*/Chart.yaml \
    | sed -E 's/.*repository:[[:space:]]*"?([^"]+)"?.*/\1/' \
    | grep -E '^https?://' | sort -u)
EOF

echo "registering ${#repos[@]} chart repositories"
for url in "${repos[@]}"; do
  # deterministic name from the host, so re-runs are idempotent
  name="tockmox-$(printf '%s' "$url" | sed -E 's#https?://##; s#[/.]#-#g')"
  retry "helm repo add $name" helm repo add "$name" "$url" || {
    echo "  FAILED to add $url" >&2; exit 1; }
  printf '  %s\n' "$url"
done
retry "helm repo update" helm repo update

echo "building dependencies"
for c in charts/tockmox-*; do
  [ "$c" = "charts/tockmox-common" ] && continue
  # `build` honours Chart.lock and is the reproducible path. It REFUSES a lock
  # that no longer matches Chart.yaml, which is exactly what happens after a
  # dependency is added, removed or renamed. Fall back to `update`, which
  # re-resolves and rewrites the lock, then say so ... a silently regenerated
  # lockfile should be visible in the diff, not a surprise.
  #
  # THE RETRY BELONGS INSIDE `build`, NOT AROUND THE WHOLE if/elif, and that
  # placement is the point rather than a detail. Without it, a transient 504 on
  # `build` falls straight through to `update`, which rewrites Chart.lock --
  # so a network blip would silently regenerate a lockfile that was correct.
  # Retrying `build` to exhaustion first means the fallback only ever fires for
  # the reason it was written for: a lock that genuinely no longer matches.
  #
  # Status is printed AFTER the call rather than as a leading `printf` without
  # a newline, so retry notices land on their own lines instead of being spliced
  # into a half-written status column.
  if retry "$c deps" helm dependency build "$c"; then
    printf '  %-34s %s\n' "$c" "ok"
  elif helm dependency update "$c" >/dev/null 2>&1; then
    printf '  %-34s %s\n' "$c" "ok (Chart.lock regenerated ... commit it)"
  else
    printf '  %-34s %s\n' "$c" "FAILED"
    helm dependency update "$c" 2>&1 | tail -3
    exit 1
  fi
done
verify_sums || exit 1
echo "done"

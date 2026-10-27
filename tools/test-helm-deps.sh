#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Selftest for tools/helm-deps.sh's offline path (HL-0675, D5).
#
#   bash tools/test-helm-deps.sh        (or: tools/helm-deps.sh --selftest)
#
# Builds a throwaway tree with one layer that depends on tockmox-common
# (file://) and on one upstream chart, puts a helm on PATH that FAILS every
# repository or dependency call (no network) and passes `package` and
# `version` through to the real helm, and checks five things:
#   1. everything vendored: exit 0, no repository is contacted, and
#      tockmox-common is rebuilt from source (a stale copy is replaced);
#   2. one upstream archive missing: the online path, which fails here;
#   3. Chart.yaml names a dependency Chart.lock does not: the online path;
#   4. HELM_DEPS_ONLINE=1: the online path even when everything is vendored;
#   5. a vendored archive at a version other than Chart.lock's: the online path.
#
# Exit: 0 all pass, 1 a case failed, 2 cannot run (no helm). Bash 3.2 clean.
set -u

REAL_HELM="$(command -v helm || true)"
if [ -z "$REAL_HELM" ]; then
  echo "test-helm-deps: SKIPPED, helm is not on PATH"
  exit 2
fi
SRC="$(cd "$(dirname "$0")" && pwd)/helm-deps.sh"
T="$(mktemp -d)" || { echo "test-helm-deps: cannot make a temp dir" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }

# A helm that has no network: repository and dependency calls fail.
mkdir -p "$T/bin"
cat > "$T/bin/helm" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "\$HELM_STUB_LOG"
case "\$1" in
  repo|dependency) echo "Error: network is unreachable (stub)" >&2; exit 1 ;;
  *) exec "$REAL_HELM" "\$@" ;;
esac
EOF
chmod +x "$T/bin/helm"

chart() {  # <dir> <name> <version>
  mkdir -p "$1/templates"
  printf 'apiVersion: v2\nname: %s\nversion: %s\ntype: application\n' "$2" "$3" > "$1/Chart.yaml"
}

# fresh <root>: one layer, tockmox-x, vendored and consistent.
fresh() {
  local r="$1"
  rm -rf "$r"; mkdir -p "$r/tools" "$r/charts"
  cp "$SRC" "$r/tools/helm-deps.sh"
  chart "$r/charts/tockmox-common" tockmox-common 0.1.0
  printf '{{- define "common.marker" -}}%s{{- end -}}\n' "${2:-new}" > "$r/charts/tockmox-common/templates/_m.tpl"
  chart "$r/charts/tockmox-x" tockmox-x 0.1.0
  cat >> "$r/charts/tockmox-x/Chart.yaml" <<'Y'
dependencies:
  - name: tockmox-common
    version: 0.1.0
    repository: "file://../tockmox-common"
  - name: upstream
    version: "~1.0.0"
    repository: "https://charts.example.invalid"
    condition: upstream.enabled
Y
  cat > "$r/charts/tockmox-x/Chart.lock" <<'Y'
dependencies:
- name: tockmox-common
  repository: file://../tockmox-common
  version: 0.1.0
- name: upstream
  repository: https://charts.example.invalid
  version: 1.0.2
digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
generated: "2026-10-27T00:00:00Z"
Y
  mkdir -p "$r/charts/tockmox-x/charts" "$T/up"
  chart "$T/up/upstream" upstream 1.0.2
  "$REAL_HELM" package "$T/up/upstream" -d "$r/charts/tockmox-x/charts" >/dev/null
  # a STALE tockmox-common copy: built from a source without today's marker
  rm -rf "$T/old"; mkdir -p "$T/old"
  chart "$T/old/tockmox-common" tockmox-common 0.1.0
  "$REAL_HELM" package "$T/old/tockmox-common" -d "$r/charts/tockmox-x/charts" >/dev/null
}

run() {  # <root> [env...] -> sets out, rc; HELM_STUB_LOG is $T/log
  local r="$1"; shift
  : > "$T/log"
  out="$(cd "$r" && env PATH="$T/bin:$PATH" HELM_STUB_LOG="$T/log" HELM_DEPS_RETRIES=1 "$@" bash tools/helm-deps.sh 2>&1)"
  rc=$?
}

# 1. everything vendored
fresh "$T/r1" new
run "$T/r1"
if [ "$rc" = 0 ] && ! grep -qE '^(repo|dependency) ' "$T/log"; then
  ok "everything vendored: exit 0 and no repository or dependency call"
else
  no "everything vendored: rc=$rc, helm calls: $(tr '\n' ';' < "$T/log")"
fi
if tar -xzf "$T/r1/charts/tockmox-x/charts/tockmox-common-0.1.0.tgz" -O 2>/dev/null | grep -q 'common.marker'; then
  ok "the local dependency is rebuilt from source, replacing the stale copy"
else
  no "tockmox-common-0.1.0.tgz is still the stale copy"
fi
echo "$out" | grep -q '^offline:' && ok "it says it took the offline path" || no "no 'offline:' line: $out"

# 2. an upstream archive missing
fresh "$T/r2" new
rm -f "$T/r2/charts/tockmox-x/charts/upstream-1.0.2.tgz"
run "$T/r2"
if [ "$rc" != 0 ] && grep -q '^repo add' "$T/log" && echo "$out" | grep -q 'online: .*upstream-1.0.2.tgz is not in the tree'; then
  ok "a missing upstream archive goes online, and says which"
else
  no "missing archive: rc=$rc, out: $(echo "$out" | head -3 | tr '\n' ';')"
fi

# 3. Chart.yaml names a dependency the lock does not
fresh "$T/r3" new
cat >> "$T/r3/charts/tockmox-x/Chart.yaml" <<'Y'
  - name: newcomer
    version: 2.0.0
    repository: "https://charts.example.invalid"
Y
run "$T/r3"
if [ "$rc" != 0 ] && grep -q '^repo add' "$T/log" && echo "$out" | grep -q 'online: .*does not name the dependencies'; then
  ok "a lock that no longer matches Chart.yaml goes online"
else
  no "stale lock: rc=$rc, out: $(echo "$out" | head -3 | tr '\n' ';')"
fi

# 4. forced online
fresh "$T/r4" new
run "$T/r4" HELM_DEPS_ONLINE=1
if [ "$rc" != 0 ] && grep -q '^repo add' "$T/log"; then
  ok "HELM_DEPS_ONLINE=1 takes the online path"
else
  no "HELM_DEPS_ONLINE=1: rc=$rc, helm calls: $(tr '\n' ';' < "$T/log")"
fi

# 5. a vendored archive at another version than the lock pins
fresh "$T/r5" new
mv "$T/r5/charts/tockmox-x/charts/upstream-1.0.2.tgz" "$T/r5/charts/tockmox-x/charts/upstream-1.0.1.tgz"
run "$T/r5"
if [ "$rc" != 0 ] && grep -q '^repo add' "$T/log"; then
  ok "an archive at another version than Chart.lock pins goes online"
else
  no "wrong version: rc=$rc, out: $(echo "$out" | head -3 | tr '\n' ';')"
fi

[ "$fail" = 0 ] && echo "test-helm-deps: all passed" || echo "test-helm-deps: FAILED"
exit "$fail"

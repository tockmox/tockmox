#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# `site-repo-server.sh push` serves exactly the tree of the directory it was given, or nothing.
#
# On 2026-11-16 a push from macOS served a product tree with 631 extra `._*` files (bsdtar packs an
# AppleDouble file for every file carrying an xattr; the pod's `git add -A` committed them). A chart
# that globs `dashboards/*.json` read them, an upgrade leg ran on a tree that was not the candidate,
# and the push still said "published and clone-verified".
#
# Hermetic: no cluster, no network. A stub kubectl plays the pod. `cp` lands the tarball in a scratch
# "pod"; `exec ... sh -c SCRIPT` runs the pod's script locally with its /tmp and /repos moved into the
# scratch directory. The clone probe (a `kubectl run`) is stubbed to succeed: it is not under test.
#
#   A. a directory holding `._x.json` files and a .gitignored file: the push serves the directory's
#      tree, which has neither, and says the tree it served.
#   B. the bytes that reach the pod differ from the directory (the stub adds a file in transit): the
#      push refuses, names both trees, and publishes nothing.
#   C. a tag push serves the same tree under the tag.
#   D. TOCKMOX_SERVE_FORCE_ADD names ignored subchart archives: the push serves them, the served tree is
#      the directory's tree with exactly those files added, and it says how many it served.
#   E. TOCKMOX_SERVE_FORCE_ADD names files the directory does not hold: the push refuses and publishes
#      nothing; and a pathspec carrying shell characters is refused before anything is sent.
#   F. push-ref serves a tag of a git repository as committed, so a tag whose commit carries the vendored
#      subchart archives (install/charts-vendored-tag.sh, the air-gap lane's path) is served with them and with
#      nothing else; a tag the repository does not hold is refused and nothing is published.
#
#   ./tests/executed-docs/site-repo-push-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRS="${HERE}/provision/site-repo-server.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

command -v git >/dev/null 2>&1 || { printf 'FAIL git is on PATH\n     this test needs git\n'; exit 1; }

POD_ROOT="${TMP}/pod"
mkdir -p "${TMP}/bin" "${POD_ROOT}/tmp" "${POD_ROOT}/repos" "${POD_ROOT}/home"
# The stub. It reads the pod's script from its arguments, so it is a fake of the CALLS push makes,
# not of push itself. SRS_TEST_TAMPER=1 adds one file to the tarball between cp and exec.
cat > "${TMP}/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -u
args=("$@")
verb=""
for a in "${args[@]}"; do
  case "$a" in cp|exec|run|delete|logs|get|apply|wait) verb="$a"; break ;; esac
done
case "$verb" in
  cp)
    n=${#args[@]}; src="${args[$((n-2))]}"; dst="${args[$((n-1))]}"
    dst="${POD_ROOT}${dst#*:}"
    cp "$src" "$dst" || exit 1
    if [ "${SRS_TEST_TAMPER:-0}" = 1 ]; then
      t="$(mktemp -d)"; tar xzf "$dst" -C "$t"; echo tampered > "$t/extra-in-transit.txt"
      ( cd "$t" && tar czf "$dst" . ); rm -rf "$t"
    fi
    ;;
  exec)
    script="${args[$((${#args[@]}-1))]}"
    script="$(printf '%s' "$script" | sed -e "s#/tmp/#${POD_ROOT}/tmp/#g" -e "s#/repos#${POD_ROOT}/repos#g")"
    HOME="${POD_ROOT}/home" GIT_CONFIG_NOSYSTEM=1 sh -c "$script"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${TMP}/bin/kubectl"
export PATH="${TMP}/bin:${PATH}" POD_ROOT KUBE_CONTEXT=test-context TMPDIR="${TMP}"

# The directory under test: two real files, a .gitignore and the file it ignores, and AppleDouble
# files at the top and one level down, as bsdtar would make them.
DIR="${TMP}/site"
mkdir -p "${DIR}/dashboards"
printf 'apiVersion: v1\n' > "${DIR}/root.yaml"
printf '{"title":"x"}\n' > "${DIR}/dashboards/x.json"
printf 'build/\n' > "${DIR}/.gitignore"
mkdir -p "${DIR}/build"; printf 'local only\n' > "${DIR}/build/out.txt"
printf '\0\5\26\7AppleDouble' > "${DIR}/._root.yaml"
printf '\0\5\26\7AppleDouble' > "${DIR}/dashboards/._x.json"

want="$(cd "${DIR}" && mkdir -p "${TMP}/ref" && cp -R . "${TMP}/ref/" && cd "${TMP}/ref" \
        && rm -f ._root.yaml dashboards/._x.json && rm -rf build && git init -q . \
        && git add -A && git write-tree)"
[ -n "$want" ] || { printf 'FAIL computing the expected tree\n'; exit 1; }

# ------------------------------------------------------------------------------- A
out="$(bash "$SRS" push "$DIR" site 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  bad "A: push of a directory with ._ files succeeds" "rc=$rc: $(printf '%s' "$out" | tail -3)"
else
  served="$(git --git-dir="${POD_ROOT}/repos/site.git" rev-parse 'main^{tree}' 2>/dev/null)"
  if [ "$served" = "$want" ]; then ok "A: the served tree is the directory's tree, without ._ files or ignored files"
  else bad "A: the served tree is the directory's tree" "served ${served:-none}, want ${want}"; fi
  if git --git-dir="${POD_ROOT}/repos/site.git" ls-tree -r --name-only main | grep '\._' >/dev/null; then
    bad "A: no ._ path is served" "$(git --git-dir="${POD_ROOT}/repos/site.git" ls-tree -r --name-only main | grep '\._' | head -3)"
  else ok "A: no ._ path is served"; fi
  case "$out" in *"tree ${want}"*) ok "A: push names the tree it served" ;;
    *) bad "A: push names the tree it served" "$(printf '%s' "$out" | tail -2)" ;; esac
fi

# ------------------------------------------------------------------------------- B
rm -rf "${POD_ROOT}/repos/site.git"
out="$(SRS_TEST_TAMPER=1 bash "$SRS" push "$DIR" site 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "B: push refuses when the pod would serve another tree" "rc=0: $(printf '%s' "$out" | tail -2)"
else
  case "$out" in
    *"REFUSING"*"${want}"*) ok "B: push refuses and names the tree it was given" ;;
    *) bad "B: push refuses and names the tree it was given" "$(printf '%s' "$out" | tail -3)" ;;
  esac
  if [ -e "${POD_ROOT}/repos/site.git" ]; then bad "B: nothing is published" "${POD_ROOT}/repos/site.git exists"
  else ok "B: nothing is published"; fi
fi

# ------------------------------------------------------------------------------- C
out="$(bash "$SRS" push "$DIR" tockmox v9.9.9 2>&1)"; rc=$?
served="$(git --git-dir="${POD_ROOT}/repos/tockmox.git" rev-parse 'v9.9.9^{tree}' 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$served" = "$want" ]; then ok "C: a tag push serves the directory's tree under the tag"
else bad "C: a tag push serves the directory's tree under the tag" "rc=$rc, served ${served:-none}: $(printf '%s' "$out" | tail -2)"; fi

# ------------------------------------------------------------------------------- D
# The air-gap lane's case: .gitignore excludes charts/*/charts/ and *.tgz, tools/helm-deps.sh vendors the
# archives there, and the guest's Argo CD can only render without a chart repository if they are served.
CDIR="${TMP}/charts-tree"
mkdir -p "${CDIR}/charts/layer/charts"
printf 'apiVersion: v2\nname: layer\n' > "${CDIR}/charts/layer/Chart.yaml"
printf 'charts/*/charts/\n*.tgz\n' > "${CDIR}/.gitignore"
printf 'archive-a' > "${CDIR}/charts/layer/charts/a-1.0.0.tgz"
printf 'archive-b' > "${CDIR}/charts/layer/charts/b-2.0.0.tgz"
cwant="$(mkdir -p "${TMP}/cref" && cp -R "${CDIR}/." "${TMP}/cref/" && cd "${TMP}/cref" && git init -q . \
         && git add -A && git add -f -- 'charts/*/charts/*.tgz' && git write-tree)"
out="$(TOCKMOX_SERVE_FORCE_ADD='charts/*/charts/*.tgz' bash "$SRS" push "$CDIR" forced 2>&1)"; rc=$?
served="$(git --git-dir="${POD_ROOT}/repos/forced.git" rev-parse 'main^{tree}' 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$served" = "$cwant" ]; then ok "D: the ignored archives named by TOCKMOX_SERVE_FORCE_ADD are served, and nothing else changes"
else bad "D: the ignored archives named by TOCKMOX_SERVE_FORCE_ADD are served" "rc=$rc, served ${served:-none}, want ${cwant}: $(printf '%s' "$out" | tail -2)"; fi
case "$out" in *"2 file(s) matching charts/*/charts/*.tgz"*) ok "D: push says how many ignored files it served" ;;
  *) bad "D: push says how many ignored files it served" "$(printf '%s' "$out" | tail -2)" ;; esac
plain="$(bash "$SRS" push "$CDIR" plain 2>&1 >/dev/null; git --git-dir="${POD_ROOT}/repos/plain.git" ls-tree -r --name-only main 2>/dev/null | grep -c '\.tgz$')"
if [ "${plain##*$'\n'}" = 0 ]; then ok "D: without TOCKMOX_SERVE_FORCE_ADD the archives are not served"
else bad "D: without TOCKMOX_SERVE_FORCE_ADD the archives are not served" "served ${plain##*$'\n'} .tgz file(s)"; fi

# ------------------------------------------------------------------------------- E
out="$(TOCKMOX_SERVE_FORCE_ADD='vendor/*.tgz' bash "$SRS" push "$CDIR" none 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "${POD_ROOT}/repos/none.git" ]; then ok "E: a pathspec that names nothing in the directory is refused and nothing is published"
else bad "E: a pathspec that names nothing is refused" "rc=$rc: $(printf '%s' "$out" | tail -2)"; fi
out="$(TOCKMOX_SERVE_FORCE_ADD="x';touch ${TMP}/PWNED;'" bash "$SRS" push "$CDIR" inj 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "${TMP}/PWNED" ] && [ ! -e "${POD_ROOT}/repos/inj.git" ]; then ok "E: a pathspec carrying shell characters is refused before anything is sent"
else bad "E: a pathspec carrying shell characters is refused" "rc=$rc, PWNED $( [ -e "${TMP}/PWNED" ] && echo exists || echo absent ): $(printf '%s' "$out" | tail -2)"; fi

# ------------------------------------------------------------------------------- F
RDIR="${TMP}/ref-repo"
mkdir -p "${RDIR}/charts/layer/charts"
printf 'apiVersion: v2\nname: layer\n' > "${RDIR}/charts/layer/Chart.yaml"
printf 'charts/*/charts/\n*.tgz\n' > "${RDIR}/.gitignore"
( cd "${RDIR}" && git init -q -b main . && git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m release \
    && git tag v1 && printf 'archive-a' > charts/layer/charts/a-1.0.0.tgz && printf 'archive-b' > charts/layer/charts/b-2.0.0.tgz \
    && git add -f charts/layer/charts/a-1.0.0.tgz charts/layer/charts/b-2.0.0.tgz \
    && git -c user.name=t -c user.email=t@example.com commit -q -m vendored && git tag v1-vendored && git checkout -q v1 ) >/dev/null 2>&1
rwant="$(git -C "${RDIR}" rev-parse 'v1-vendored^{tree}')"
out="$(bash "$SRS" push-ref "$RDIR" tockmox-ref v1-vendored 2>&1)"; rc=$?
served="$(git --git-dir="${POD_ROOT}/repos/tockmox-ref.git" rev-parse 'v1-vendored^{tree}' 2>/dev/null)"
ntgz="$(git --git-dir="${POD_ROOT}/repos/tockmox-ref.git" ls-tree -r --name-only v1-vendored 2>/dev/null | grep -c '\.tgz$')"
if [ "$rc" -eq 0 ] && [ -n "$rwant" ] && [ "$served" = "$rwant" ] && [ "$ntgz" = 2 ]; then
  ok "F: push-ref serves the tag as committed, the vendored archives with it"
else bad "F: push-ref serves the tag as committed" "rc=$rc, served ${served:-none}, want ${rwant}, ${ntgz} .tgz: $(printf '%s' "$out" | tail -2)"; fi
case "$out" in *"tree ${rwant}"*) ok "F: push-ref names the tree it served" ;;
  *) bad "F: push-ref names the tree it served" "$(printf '%s' "$out" | tail -2)" ;; esac
out="$(bash "$SRS" push-ref "$RDIR" tockmox-none v9-vendored 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "${POD_ROOT}/repos/tockmox-none.git" ]; then ok "F: push-ref of a tag the repository does not hold is refused and nothing is published"
else bad "F: push-ref of a missing tag is refused" "rc=$rc: $(printf '%s' "$out" | tail -2)"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

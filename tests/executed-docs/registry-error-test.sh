#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# A registry refusal is INFRA_ERROR, never "the documented section is gone", and a path reports
# the block's real exit status.
#
# Found on a lane run (2026-11-25): the chart fetch in P05 was answered by Docker Hub's anonymous
# pull limit (HTTP 429, "toomanyrequests"). helm printed one Error line and nothing on stdout, so
# the version parse came up empty, P05 exited 3 ("EXCEPTION ... change in the OCI registry's
# output shape") and run.sh said the section was gone at this ref. B7 read the same refusal as
# "MISSING: version=[]". Separately P05 took `RC1=$?` after `rm -f`, so "block 1 exited N" always
# said 0.
#
# Hermetic: a scratch git repository holds a fixture page; a stub helm answers the 429 text or a
# version. No cluster, no network.
#
#   ./tests/executed-docs/registry-error-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

FXREPO="${TMP}/repo"; ED="${FXREPO}/tests/executed-docs"
mkdir -p "${ED}/paths" "${FXREPO}/docs/deployment" "${TMP}/bin"
cp "${HERE}/paths/P05-sealed-secrets-install.sh" "${HERE}/paths/B7-helm-show-chart-sealed-secrets.sh" "${ED}/paths/"
cp -R "${HERE}/lib" "${ED}/lib"

# The fixture page: the section both paths read, with the command block 1 carries on the real page.
# Only block 1 is reached by the cases below.
{
  printf '%s\n' '## 7. Install sealed-secrets, with your own key' '' '```bash' \
    'helm show chart oci://registry-1.docker.io/bitnamicharts/sealed-secrets | grep -E '"'"'^(version|appVersion):'"'"'' \
    '```' '' '```bash' 'helm install sealed-secrets oci://registry-1.docker.io/bitnamicharts/sealed-secrets --namespace kube-system' '```' '' \
    '```bash' 'kubectl -n kube-system get deployment sealed-secrets -o jsonpath='"'"'{.status.readyReplicas}'"'"'; echo readyReplicas' '```' '' \
    '```bash' 'kubectl -n kube-system get secret -o yaml > sealed-secrets-key-BACKUP.yaml' '```'
} > "${FXREPO}/docs/deployment/fresh-install.md"
printf '%s\n' '## 7. Something else' '' 'No code here.' > "${FXREPO}/docs/deployment/other.md"
if ! { git -C "$FXREPO" init -q && git -C "$FXREPO" add -A \
    && git -C "$FXREPO" -c user.name=fixture -c user.email=fixture@example.com commit -q -m fixture; }; then
  bad "the scratch repository" "git init/commit failed"
fi

# A helm that answers by mode: 429 (the registry refusal on stderr, nothing on stdout), a version,
# or noise (exit 0, prints nothing a parse can use, and no error).
cat > "${TMP}/bin/helm" <<'SH'
#!/usr/bin/env bash
case "${FAKE_HELM:-version}" in
  429) echo 'Error: failed to perform "FetchReference" on source: GET "https://registry-1.docker.io/v2/bitnamicharts/sealed-secrets/manifests/2.22.0": response status code 429: toomanyrequests: You have reached your unauthenticated pull rate limit.' >&2; exit 1 ;;
  version) printf 'apiVersion: v2\nappVersion: 0.41.2\nname: sealed-secrets\nversion: 2.22.0\n' ;;
  noise) printf 'apiVersion: v2\nname: sealed-secrets\n' ;;
esac
SH
chmod 755 "${TMP}/bin/helm"

run_path() { # <path file> <helm mode> [env assignments...]  -> output in RUN_OUT, status in RUN_RC
  local p="$1" mode="$2"; shift 2
  RUN_OUT="$( cd "$FXREPO" && env PATH="${TMP}/bin:${PATH}" FAKE_HELM="$mode" TOCKMOX_DOCS_REF=HEAD KUBE_CONTEXT=fixture \
      OUTCOME_RECEIPT_DIR="${TMP}/receipts-$$-${RANDOM}" ASSERT_REPORT= "$@" bash "${ED}/paths/${p}" 2>&1 )"
  RUN_RC=$?
}
tail_of() { printf '%s' "$RUN_OUT" | tail -4 | tr '\n' ' '; }

# ---- P05 --------------------------------------------------------------------------------------
run_path P05-sealed-secrets-install.sh 429
if [ "$RUN_RC" -eq 5 ] && grep -q -- '^OUTCOME:  INFRA_ERROR' <<<"$RUN_OUT"; then
  ok "P05: a registry 429 in block 1 is INFRA_ERROR, exit 5"
else bad "P05: a registry 429 in block 1 is INFRA_ERROR, exit 5" "rc=${RUN_RC}; $(tail_of)"; fi
if grep -q -- '^OUTCOME:  INFRA_ERROR.*toomanyrequests' <<<"$RUN_OUT"; then
  ok "P05: the INFRA_ERROR reason quotes the registry's own error"
else bad "P05: the INFRA_ERROR reason quotes the registry's own error" "$(tail_of)"; fi
if ! grep -q -- 'change in the OCI registry' <<<"$RUN_OUT" && ! grep -q -- 'carries no' <<<"$RUN_OUT"; then
  ok "P05: a 429 does not print the output-shape or section-gone EXCEPTION"
else bad "P05: a 429 does not print the output-shape or section-gone EXCEPTION" "$(tail_of)"; fi
if grep -q -- 'block 1 exited 1;' <<<"$RUN_OUT"; then
  ok "P05: 'block 1 exited N' reports the block's real status (1), not rm's 0"
else bad "P05: 'block 1 exited N' reports the block's real status" "$(printf '%s' "$RUN_OUT" | grep -m1 'block 1 exited' || echo 'no such line')"; fi

# helm said nothing at all: no version, no error line. That is a change in what the command prints, and stays exit 3.
run_path P05-sealed-secrets-install.sh noise
if [ "$RUN_RC" -eq 3 ] && grep -q -- 'could not parse a chart version' <<<"$RUN_OUT" && ! grep -q -- 'INFRA_ERROR' <<<"$RUN_OUT"; then
  ok "P05: output with no version and no registry error is still the exit-3 shape EXCEPTION"
else bad "P05: output with no version and no registry error is still exit 3" "rc=${RUN_RC}; $(tail_of)"; fi

# A genuinely missing section stays "not a documented path" (exit 3), whatever helm would say.
run_path P05-sealed-secrets-install.sh 429 TOCKMOX_P05_SECTION='## 99. A section that is not there'
if [ "$RUN_RC" -eq 3 ] && grep -q -- 'carries no' <<<"$RUN_OUT" && ! grep -q -- 'INFRA_ERROR' <<<"$RUN_OUT"; then
  ok "P05: a genuinely missing doc section is still exit 3, 'carries no ... section'"
else bad "P05: a genuinely missing doc section is still exit 3" "rc=${RUN_RC}; $(tail_of)"; fi

# ---- B7 ---------------------------------------------------------------------------------------
run_path B7-helm-show-chart-sealed-secrets.sh 429
if [ "$RUN_RC" -eq 5 ] && grep -q -- '^OUTCOME:  INFRA_ERROR.*toomanyrequests' <<<"$RUN_OUT"; then
  ok "B7: a registry 429 is INFRA_ERROR, exit 5, with the registry's error quoted"
else bad "B7: a registry 429 is INFRA_ERROR, exit 5" "rc=${RUN_RC}; $(tail_of)"; fi
if ! grep -q -- 'MISSING: version=' <<<"$RUN_OUT"; then
  ok "B7: a 429 is not read as 'MISSING: version=[]'"
else bad "B7: a 429 is not read as 'MISSING: version=[]'" "$(tail_of)"; fi

run_path B7-helm-show-chart-sealed-secrets.sh version
if [ "$RUN_RC" -eq 0 ] && grep -q -- '^OUTCOME:  PASS' <<<"$RUN_OUT"; then
  ok "B7: a stub that answers a version still PASSES (the control)"
else bad "B7: a stub that answers a version still PASSES" "rc=${RUN_RC}; $(tail_of)"; fi

run_path B7-helm-show-chart-sealed-secrets.sh noise
if [ "$RUN_RC" -ne 5 ] && ! grep -q -- 'INFRA_ERROR' <<<"$RUN_OUT" && grep -q -- 'MISSING: version=' <<<"$RUN_OUT"; then
  ok "B7: no version and no registry error is still a failed assertion, not INFRA_ERROR"
else bad "B7: no version and no registry error is still a failed assertion" "rc=${RUN_RC}; $(tail_of)"; fi

run_path B7-helm-show-chart-sealed-secrets.sh 429 TOCKMOX_B7_SECTION='## 99. A section that is not there'
if [ "$RUN_RC" -eq 3 ] && grep -q -- 'carries no' <<<"$RUN_OUT" && ! grep -q -- 'INFRA_ERROR' <<<"$RUN_OUT"; then
  ok "B7: a genuinely missing doc section is still exit 3"
else bad "B7: a genuinely missing doc section is still exit 3" "rc=${RUN_RC}; $(tail_of)"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

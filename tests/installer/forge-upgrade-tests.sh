#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups U1-U7: install/forge-upgrade.sh, reached as
# `tockmox-install.sh upgrade-forge`.
#
# HERMETIC, on stubs of its own (below): kubectl and helm that answer only the calls
# the upgrade makes, from FU_* settings, and log every call. The order is what is
# tested: no upgrade before a fresh copy has succeeded, no "done" before the forge
# answers at the pinned version. The upgrade itself, Forgejo migrating its data from
# the previous pin, is the lab's to prove.

FU="$WORK/forge-upgrade"; mkdir -p "$FU/bin"
FU_PIN="$(sed -n 's/^FORGE_IMAGE_TAG_DEFAULT="\([^"]*\)"$/\1/p' "$REPO_ROOT/install/bootstrap-forge.sh")"
FU_PIN_CHART="$(sed -n 's/^CHART_VERSION_DEFAULT="\([^"]*\)"$/\1/p' "$REPO_ROOT/install/bootstrap-forge.sh")"

cat > "$FU/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$FU_LOG"
a=" $* "
case "$a" in
  *" config view "*) echo "https://192.0.2.10:6443"; exit 0 ;;
  *" get deploy tockmox-forge "*) echo "code.forgejo.org/forgejo/forgejo:${FU_IMAGE:?}"; exit 0 ;;
  *" get cronjob tockmox-forge-offsite "*) [ "${FU_CRON:-yes}" = yes ]; exit $? ;;
  *" create job "*) exit 0 ;;
  *" wait --for=condition=complete "*) [ "${FU_JOB:-ok}" = ok ]; exit $? ;;
  *" logs job/"*) [ "${FU_JOB:-ok}" = ok ] && echo "copied: main 0123456789ab to b/latest" || echo "upload of bundle failed: HTTP 403"; exit 0 ;;
  *" rollout status "*) exit 0 ;;
  *" exec deploy/tockmox-forge "*) printf '{"version":"%s"}\n' "${FU_ANSWER:?}"; exit 0 ;;
esac
echo "kubectl stub: unhandled: $*" >&2; exit 99
STUB
cat > "$FU/bin/helm" <<'STUB'
#!/usr/bin/env bash
printf 'helm %s\n' "$*" >> "$FU_LOG"
case " $* " in
  *" status tockmox-forge "*) [ "${FU_RELEASE:-yes}" = yes ]; exit $? ;;
  *" upgrade tockmox-forge "*) exit "${FU_HELM_RC:-0}" ;;
esac
echo "helm stub: unhandled: $*" >&2; exit 99
STUB
chmod +x "$FU/bin/kubectl" "$FU/bin/helm"

FU_STATUS=0
# fu_run NAME [ENV=VAL ...] -- ARGS...: one case in its own directory, with the stubs first on PATH.
fu_run() {
  local name="$1"; shift
  D="$FU/$name"; rm -rf "$D"; mkdir -p "$D"; : > "$D/calls.log"
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  set +e
  env PATH="$FU/bin:$PATH" FU_LOG="$D/calls.log" NO_COLOR=1 "${envs[@]}" \
    bash "$INSTALLER" upgrade-forge "$@" >"$D/stdout" 2>"$D/stderr" </dev/null
  FU_STATUS=$?
  set -e
}
fu_calls() { grep -c "$1" "$D/calls.log" || true; }

path_begin "U1" "upgrade-forge needs a named context and a confirmation, and touches nothing without them"
fu_run u1 FU_IMAGE=15.0.1 FU_ANSWER=x --
assert_artifact "no --context is refused, naming why" \
  "echo $FU_STATUS; grep -c 'never falls back to the current context' '$D/stderr'" "$(printf '1\n1')"
fu_run u1b FU_IMAGE=15.0.1 FU_ANSWER=x -- --context lab --no-prompt
assert_artifact "--no-prompt without --yes-context is refused" \
  "echo $FU_STATUS; grep -c 'pass --yes-context lab' '$D/stderr'" "$(printf '1\n1')"
assert_artifact "... before any helm call" "fu_calls '^helm'" "0"

path_begin "U2" "a forge already at the pin is left alone"
fu_run u2 FU_IMAGE="$FU_PIN" FU_ANSWER=x -- --context lab --yes-context lab
assert_artifact "it exits 0 and says there is nothing to do" \
  "echo $FU_STATUS; grep -c 'already runs the pinned Forgejo' '$D/stdout'" "$(printf '0\n1')"
assert_artifact "no copy and no upgrade were started" "fu_calls 'create job'; fu_calls 'helm .*upgrade'" "$(printf '0\n0')"

path_begin "U3" "no off-site copy means no upgrade, unless --without-copy says the risk is accepted"
fu_run u3 FU_IMAGE=15.0.1 FU_CRON=no FU_ANSWER="$FU_PIN" -- --context lab --yes-context lab
assert_artifact "a site with no copy is refused before the upgrade" \
  "echo $FU_STATUS; grep -c 'has no off-site copy' '$D/stderr'; fu_calls 'helm .*upgrade'" "$(printf '1\n1\n0')"
fu_run u3b FU_IMAGE=15.0.1 FU_CRON=no FU_ANSWER="$FU_PIN" -- --context lab --yes-context lab --without-copy
assert_artifact "with --without-copy it upgrades, and says what that costs" \
  "echo $FU_STATUS; grep -c 'has nothing to be repaired from' '$D/stdout'; fu_calls 'helm .*upgrade'" "$(printf '0\n1\n1')"

path_begin "U4" "a copy that fails stops the upgrade before helm runs"
fu_run u4 FU_IMAGE=15.0.1 FU_JOB=fail FU_ANSWER="$FU_PIN" -- --context lab --yes-context lab
assert_artifact "the failed copy is named, with its last log line, and nothing is upgraded" \
  "echo $FU_STATUS; grep -c 'upload of bundle failed: HTTP 403' '$D/stderr'; fu_calls 'helm .*upgrade'" "$(printf '1\n1\n0')"

path_begin "U5" "the upgrade: copy first, then the pinned chart and image with the release's own values, then the answer"
fu_run u5 FU_IMAGE=15.0.1 FU_ANSWER="$FU_PIN" -- --context lab --yes-context lab
assert_artifact "it exits 0 and says the forge answers at the pin" \
  "echo $FU_STATUS; grep -c \"answers as Forgejo $FU_PIN (was 15.0.1)\" '$D/stdout'" "$(printf '0\n1')"
assert_artifact "the copy job ran before the upgrade" \
  "awk '/create job/{c=NR} /helm .*upgrade/{u=NR} END{print (c && u && c < u) ? \"copy-first\" : \"WRONG ORDER\"}' '$D/calls.log'" "copy-first"
assert_artifact "helm upgraded to the pinned chart and image and kept the release's values" \
  "grep -c -- \"upgrade tockmox-forge .* --version $FU_PIN_CHART .*--reuse-values --set image.tag=$FU_PIN\" '$D/calls.log'" "1"

path_begin "U6" "a forge that answers at another version is not called upgraded, and the repair is named"
fu_run u6 FU_IMAGE=15.0.1 FU_ANSWER=15.0.1 -- --context lab --yes-context lab
assert_artifact "it exits 1, says what the forge answers as, and gives the repair-forge command" \
  "echo $FU_STATUS; grep -c \"answers as '15.0.1', not Forgejo $FU_PIN\" '$D/stderr'; grep -c 'repair-forge --context lab' '$D/stderr'" "$(printf '1\n1\n1')"
fu_run u6b FU_IMAGE=15.0.1 FU_ANSWER="$FU_PIN" FU_HELM_RC=1 -- --context lab --yes-context lab
assert_artifact "a helm upgrade that fails says not to move the Tockmox pin" \
  "echo $FU_STATUS; grep -c 'Do not move the Tockmox pin' '$D/stderr'" "$(printf '1\n1')"

path_begin "U7" "--dry-run says the plan and changes nothing"
fu_run u7 FU_IMAGE=14.0.3 FU_ANSWER=x -- --context lab --dry-run
assert_artifact "it names the major upgrade and the helm command, and runs neither a copy nor an upgrade" \
  "echo $FU_STATUS; grep -c 'MAJOR upgrade' '$D/stdout'; grep -c 'would run: helm upgrade' '$D/stdout'; fu_calls 'create job'; fu_calls 'helm .*upgrade'" \
  "$(printf '0\n1\n1\n0\n0')"

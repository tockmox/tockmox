# SPDX-License-Identifier: Apache-2.0
#
# ONE answer to "can this gate use TOOL", sourced by the gates that partition
# on a missing tool (check-doc-claims.sh, check-capabilities.sh,
# check-alert-rules.sh, render-counts.sh).
#
# WHY NOT `command -v`. It answers "is a file called TOOL on PATH". A binary
# built for another architecture, a script whose interpreter is gone, or a
# broken install passes it, and the gate then runs every step with a tool that
# fails on each call. Where a step sends the tool's stderr to /dev/null and
# counts lines, the failure reads as 0; where it captures `2>&1 || true`, two
# identical error messages compare equal. Either way the gate reported a
# finding about the product that was really a finding about the machine.
#
#   tool_state TOOL   prints one word and returns 0:
#                       ok      on PATH and a cheap call succeeds
#                       absent  not on PATH
#                       broken  on PATH but the cheap call fails
#   tool_runs TOOL    returns 0 when the cheap call succeeds
#
# Each probe is the cheapest call that needs no network and no cluster, and
# only its exit status is read. Bash 3.2 compatible: this is sourced by gates
# that run under macOS /bin/bash.
#
#   bash tools/lib/tool-runs.sh --selftest

tool_runs() {
  case "$1" in
    helm)     helm version >/dev/null 2>&1 ;;
    promtool) promtool --version >/dev/null 2>&1 ;;
    kubeconform) kubeconform -v >/dev/null 2>&1 ;;
    kubectl)  kubectl version --client >/dev/null 2>&1 ;;
    jq)       jq --version >/dev/null 2>&1 ;;
    yq)       yq --version >/dev/null 2>&1 ;;
    python3)  python3 -c 'pass' >/dev/null 2>&1 ;;
    awk)      awk 'BEGIN { exit 0 }' >/dev/null 2>&1 ;;
    find)     find . -maxdepth 0 >/dev/null 2>&1 ;;
    xargs)    printf x | xargs echo >/dev/null 2>&1 ;;
    *)        return 0 ;;
  esac
}

tool_state() {
  if ! command -v "$1" >/dev/null 2>&1; then echo absent
  elif tool_runs "$1"; then echo ok
  else echo broken
  fi
}

# One line naming what is wrong with a tool that is not ok, for a gate's report.
tool_why() {
  case "$(tool_state "$1")" in
    absent) echo "$1 is not on PATH" ;;
    broken) echo "$1 is on PATH but cannot run (wrong architecture, missing interpreter, broken install)" ;;
    *)      echo "$1 runs" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then
  # Each case runs in a subshell with a HERMETIC PATH: the fixture directory,
  # then /usr/bin:/bin. Prepending to the caller's PATH is not enough, because
  # `command -v` skips a file that is not executable and then finds the
  # machine's own helm further along.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/empty" "$tmp/broken" "$tmp/noexec" "$tmp/good" "$tmp/fails"
  printf '\177ELF not a program for this machine\n' > "$tmp/broken/helm"; chmod +x "$tmp/broken/helm"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/noexec/helm"; chmod -x "$tmp/noexec/helm"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/good/helm"; chmod +x "$tmp/good/helm"
  printf '#!/bin/sh\nexit 3\n' > "$tmp/fails/helm"; chmod +x "$tmp/fails/helm"
  fails=0
  probe() {
    local label="$1" dir="$2" want="$3" got
    got="$(PATH="$tmp/$dir:/usr/bin:/bin" tool_state helm)"
    # "notok": whichever of absent or broken this bash's `command -v` reports
    # for a file that exists without the execute bit, never ok.
    if [ "$got" = "$want" ] || { [ "$want" = notok ] && [ "$got" != ok ]; }; then
      echo "  selftest ok: $label ($got)"
    else echo "  SELFTEST FAIL: $label: wanted $want, got $got"; fails=1; fi
  }
  # /usr/bin and /bin must not carry a helm of their own, or the absent case
  # measures the machine instead of the fixture.
  if [ -e /usr/bin/helm ] || [ -e /bin/helm ]; then
    echo "  selftest: a helm in /usr/bin or /bin makes the fixtures unreadable; refusing"; exit 2
  fi
  probe "no helm anywhere is absent"                         empty  absent
  probe "a helm for another architecture is broken, not ok"  broken broken
  probe "a helm that is not executable is not ok"            noexec notok
  probe "a helm whose version call fails is broken"          fails  broken
  probe "a helm that runs is ok"                             good   ok
  [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
  echo "selftest FAILED"; exit 1
fi

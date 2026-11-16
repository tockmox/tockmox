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
#   tool_shim TOOL    prints mise, asdf or pyenv when TOOL on PATH is that
#                     version manager's shim, nothing otherwise
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

# Which version manager's shim TOOL resolves to on PATH: mise, asdf or pyenv,
# or nothing for a real binary or an absent tool. A shim is a stand-in that
# picks the real tool from the directory it runs in and the PATH it is handed,
# so it can work in this checkout and fail in a fixture directory or on a
# hermetic PATH: it finds no pin there, or finds a selftest's stub ahead of the
# real tool and runs into it again ("shim fallback recursion"). check-all.sh
# names any it finds before the gates run.
tool_shim() {
  local p t
  p="$(command -v "$1" 2>/dev/null)" || return 0
  case "$p" in
    */mise/shims/*|*/rtx/shims/*)     echo mise;  return 0 ;;
    */.asdf/shims/*|*/asdf/shims/*)   echo asdf;  return 0 ;;
    */.pyenv/shims/*|*/pyenv/shims/*) echo pyenv; return 0 ;;
  esac
  # mise also links a shim to its own binary by name, wherever the link sits.
  if [ -L "$p" ]; then
    t="$(readlink "$p")"
    case "${t##*/}" in mise|rtx) echo mise ;; esac
  fi
  return 0
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
  # tool_shim: a version manager's shim is named by its manager, a real binary
  # and an absent tool by nothing. Same hermetic PATH as above.
  mkdir -p "$tmp/m/mise/shims" "$tmp/a/.asdf/shims" "$tmp/p/.pyenv/shims" "$tmp/l/bin" "$tmp/l/link"
  for f in "$tmp/m/mise/shims/helm" "$tmp/a/.asdf/shims/helm" "$tmp/p/.pyenv/shims/helm" "$tmp/l/bin/mise"; do
    printf '#!/bin/sh\nexit 0\n' > "$f"; chmod +x "$f"
  done
  ln -s "$tmp/l/bin/mise" "$tmp/l/link/helm"
  shimprobe() {
    local label="$1" dir="$2" want="$3" got
    got="$(PATH="$dir:/usr/bin:/bin" tool_shim helm)"
    if [ "$got" = "$want" ]; then echo "  selftest ok: $label (${got:-no shim})"
    else echo "  SELFTEST FAIL: $label: wanted '$want', got '$got'"; fails=1; fi
  }
  shimprobe "a helm in a mise shims directory is a mise shim"       "$tmp/m/mise/shims"   mise
  shimprobe "a helm in an asdf shims directory is an asdf shim"     "$tmp/a/.asdf/shims"  asdf
  shimprobe "a helm in a pyenv shims directory is a pyenv shim"     "$tmp/p/.pyenv/shims" pyenv
  shimprobe "a helm linked to a mise binary elsewhere is a mise shim" "$tmp/l/link"       mise
  shimprobe "a helm that is its own program is no shim"             "$tmp/good"           ""
  shimprobe "no helm at all is no shim"                             "$tmp/empty"          ""
  [ "$fails" -eq 0 ] && { echo "selftest PASSED"; exit 0; }
  echo "selftest FAILED"; exit 1
fi

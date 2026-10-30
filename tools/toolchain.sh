#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE TOOLCHAIN IN mise.toml, HELD TO.
#
#   tools/toolchain.sh --check      the tools on PATH match mise.toml (check-all.sh runs this first)
#   tools/toolchain.sh --drift      every copy of a pin says what mise.toml says
#   tools/toolchain.sh --pins       KEY=VALUE lines for a workflow (HELM_VERSION=v4.3.1 ...)
#   tools/toolchain.sh --selftest   both checks go red on a planted mismatch, and green on a match
#
# WHY. A render test passed in one environment with Helm 3.16 and failed on a maintainer's Mac and in CI with
# Helm 4.3.1. Nothing said the two runs used different tools, so the green run read as evidence about the tree.
# A gate result means something only next to the toolchain that produced it, and this is the check that the
# toolchain is the one CI uses before any gate runs.
#
# --check. helm and python3 must be present and must match (check-all.sh cannot run without them).
# kubeconform, shellcheck and gitleaks are checked when they are on PATH: a different version is a failure,
# an absent one is reported and left to its gate, which says SKIPPED. Python is held to its pinned MAJOR.MINOR
# as a floor (same major, this minor or newer), because CI runners ship their own python3; the packages the
# gates import are pinned exactly in tools/requirements-gates.txt. bash 4.0 or newer is reported, not
# required: two gates refuse on 3.2 by themselves (see CONTRIBUTING.md).
#
# --drift. A pin is copied only where a checksum sits beside it: the env blocks of ci.yaml (helm, kubeconform,
# gitleaks) and check-all.yaml (shellcheck), so a version bump and its checksum move in one diff. Every other
# workflow reads the pins from this script's --pins. CONTRIBUTING.md names the Helm version in prose, and
# each of those mentions is checked too.
#
# Exit: 0 match, 1 mismatch or a missing required tool, 2 cannot run (no mise.toml).
# macOS bash 3.2 and BSD userland.
set -uo pipefail
ROOT="${TOOLCHAIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MISE="$ROOT/mise.toml"

pin() {  # pin <tool>: the version mise.toml's [tools] table gives it, without quotes; empty when absent
  awk -v k="$1" '
    /^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[tools\][[:space:]]*$/); next }
    s && $1 == k && $2 == "=" { v = $3; gsub(/"/, "", v); print v; exit }
  ' "$MISE"
}

installed() {  # installed <tool>: the version on PATH, normalised to X.Y.Z (python3: X.Y); empty when absent
  case "$1" in
    helm)        command -v helm >/dev/null 2>&1 || return 0
                 helm version --short 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -n 1 ;;
    kubeconform) command -v kubeconform >/dev/null 2>&1 || return 0
                 kubeconform -v 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -n 1 ;;
    shellcheck)  command -v shellcheck >/dev/null 2>&1 || return 0
                 shellcheck --version 2>/dev/null | sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' | head -n 1 ;;
    gitleaks)    command -v gitleaks >/dev/null 2>&1 || return 0
                 gitleaks version 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -n 1 ;;
    python3)     command -v python3 >/dev/null 2>&1 || return 0
                 python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null ;;
  esac
}

python_ok() {  # python_ok <have X.Y> <want X.Y>: same major, minor at least the pinned one
  local hm hn wm wn
  hm="${1%%.*}"; hn="${1#*.}"; wm="${2%%.*}"; wn="${2#*.}"
  [ "$hm" = "$wm" ] && [ "$hn" -ge "$wn" ] 2>/dev/null
}

do_check() {
  local fail=0 t want have
  [ -r "$MISE" ] || { echo "toolchain: no mise.toml at $MISE; cannot check"; return 2; }
  echo "toolchain (mise.toml):"
  for t in helm python3 kubeconform shellcheck gitleaks; do
    if [ "$t" = python3 ]; then want="$(pin python)"; else want="$(pin "$t")"; fi
    have="$(installed "$t")"
    if [ -z "$want" ]; then
      echo "  FAIL     $t: mise.toml pins no version"; fail=1; continue
    fi
    if [ -z "$have" ]; then
      case "$t" in
        helm|python3) printf '  FAIL     %-12s absent, mise.toml pins %s\n' "$t" "$want"; fail=1 ;;
        *)            printf '  absent   %-12s (mise.toml pins %s; its gate reports SKIPPED)\n' "$t" "$want" ;;
      esac
      continue
    fi
    if [ "$t" = python3 ]; then
      if python_ok "$have" "$want"; then printf '  ok       %-12s %s (pinned %s, held as a floor)\n' "$t" "$have" "$want"
      else printf '  FAIL     %-12s %s, mise.toml pins %s\n' "$t" "$have" "$want"; fail=1; fi
    elif [ "$have" = "$want" ]; then
      printf '  ok       %-12s %s\n' "$t" "$have"
    else
      printf '  FAIL     %-12s %s on PATH (%s), mise.toml pins %s\n' "$t" "$have" "$(command -v "$t")" "$want"; fail=1
    fi
  done
  local bv; bv="$(bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)"
  case "$bv" in
    [4-9].*|[1-9][0-9].*) printf '  ok       %-12s %s\n' bash "$bv" ;;
    *) printf '  note     %-12s %s: two gates refuse below 4.0 (CONTRIBUTING.md, "Shell requirement")\n' bash "${bv:-unknown}" ;;
  esac
  if [ "$fail" -ne 0 ]; then
    echo
    echo "The tools above are not the ones CI runs, so a gate result here would not predict CI."
    echo "Install the pinned versions: tools/dev-env.sh (or \`mise install\`), then run the gates through"
    echo "\`mise exec -- ./tools/check-all.sh\` or with mise activated in your shell."
  fi
  return "$fail"
}

wf_env() {  # wf_env <workflow file> <KEY>: the quoted value of KEY in the file's env block
  sed -n "s/^  $2: \"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

do_drift() {
  local fail=0 wf="$ROOT/.github/workflows" got want line
  [ -r "$MISE" ] || { echo "toolchain: no mise.toml at $MISE; cannot check"; return 2; }
  same() {  # same <label> <got> <want>
    if [ -z "$2" ]; then echo "  FAIL  $1: not found"; fail=1
    elif [ "$2" = "$3" ]; then echo "  ok    $1 = $2"
    else echo "  FAIL  $1 = $2, mise.toml says $3"; fail=1; fi
  }
  same "ci.yaml HELM_VERSION"               "$(wf_env "$wf/ci.yaml" HELM_VERSION)"               "v$(pin helm)"
  same "ci.yaml KUBECONFORM_VERSION"        "$(wf_env "$wf/ci.yaml" KUBECONFORM_VERSION)"        "$(pin kubeconform)"
  same "ci.yaml GITLEAKS_VERSION"           "$(wf_env "$wf/ci.yaml" GITLEAKS_VERSION)"           "$(pin gitleaks)"
  same "check-all.yaml SHELLCHECK_VERSION"  "$(wf_env "$wf/check-all.yaml" SHELLCHECK_VERSION)"  "$(pin shellcheck)"
  # No other workflow may carry its own copy: it reads --pins instead.
  for f in "$wf"/*.yaml; do
    case "$(basename "$f")" in ci.yaml|check-all.yaml) continue ;; esac
    for k in HELM_VERSION KUBECONFORM_VERSION GITLEAKS_VERSION SHELLCHECK_VERSION; do
      got="$(wf_env "$f" "$k")"
      [ -z "$got" ] || { echo "  FAIL  $(basename "$f") carries its own $k ($got); read it from tools/toolchain.sh --pins"; fail=1; }
    done
  done
  # CONTRIBUTING.md names the Helm version in prose. Every mention must be the pinned one.
  want="v$(pin helm)"
  if [ -r "$ROOT/CONTRIBUTING.md" ]; then
    local n=0
    while IFS= read -r line; do
      n=$((n + 1))
      got="$(printf '%s\n' "$line" | sed -n 's/.*\([Hh]elm[^0-9]\{0,12\}\)\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\2/p')"
      [ -n "$got" ] || continue
      if [ "$got" = "$want" ]; then :; else echo "  FAIL  CONTRIBUTING.md line $n names Helm $got, mise.toml says $want"; fail=1; fi
    done < "$ROOT/CONTRIBUTING.md"
    [ "$fail" -ne 0 ] || echo "  ok    CONTRIBUTING.md names Helm $want wherever it names a version"
  fi
  return "$fail"
}

do_pins() {
  [ -r "$MISE" ] || { echo "toolchain: no mise.toml at $MISE" >&2; return 2; }
  local v
  for kv in "HELM_VERSION helm v" "KUBECONFORM_VERSION kubeconform " "SHELLCHECK_VERSION shellcheck " \
            "GITLEAKS_VERSION gitleaks " "PYTHON_VERSION python "; do
    # shellcheck disable=SC2086  # splitting the triple into $1 $2 $3 is the point
    set -- $kv
    v="$(pin "$2")"
    [ -n "$v" ] || { echo "toolchain: mise.toml pins no $2" >&2; return 1; }
    printf '%s=%s%s\n' "$1" "${3:-}" "$v"
  done
}

do_selftest() {
  local fails=0 rc
  T="$(mktemp -d)"; trap 'rm -rf "${T:-/nonexistent}"' EXIT   # global: the trap runs after this function returns
  mkdir -p "$T/repo/.github/workflows" "$T/bin"
  cp "$MISE" "$T/repo/mise.toml"
  cp "$ROOT/.github/workflows/"*.yaml "$T/repo/.github/workflows/"
  cp "$ROOT/CONTRIBUTING.md" "$T/repo/CONTRIBUTING.md"
  # Fake tools that print exactly what the real ones print, at the pinned versions.
  local H K S G P
  H="$(pin helm)"; K="$(pin kubeconform)"; S="$(pin shellcheck)"; G="$(pin gitleaks)"; P="$(pin python)"
  fake() { printf '#!/bin/sh\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
  fake helm        "echo 'v$H+gc0d08d0'"
  fake kubeconform "echo 'v$K'"
  fake shellcheck  "printf 'ShellCheck - shell script analysis tool\nversion: $S\nlicense: GPL\n'"
  fake gitleaks    "echo '$G'"
  fake python3     "case \"\$*\" in *version_info*) echo '$P' ;; *) exit 1 ;; esac"
  run() { (export TOOLCHAIN_ROOT="$T/repo" PATH="$T/bin:/usr/bin:/bin"; bash "$0" "$@") >"$T/out" 2>&1; }
  expect() {  # expect <rc> <label> <args...>
    local want="$1" label="$2"; shift 2
    run "$@"; rc=$?
    if [ "$rc" = "$want" ]; then echo "  ok    $label"; else echo "  FAIL  $label (exit $rc, wanted $want)"; sed 's/^/        /' "$T/out"; fails=1; fi
  }
  expect 0 "--check passes with every tool at its pin" --check
  expect 0 "--drift passes on the tree as it is" --drift
  fake helm "echo 'v3.16.3+gcfd0749'"
  expect 1 "--check goes red on Helm 3.16.3 (the 2026-10-29 shape)" --check
  fake helm "echo 'v$H+gc0d08d0'"
  rm "$T/bin/helm"
  expect 1 "--check goes red with no helm at all" --check
  fake helm "echo 'v$H+gc0d08d0'"
  rm "$T/bin/kubeconform"
  expect 0 "--check reports an absent kubeconform without failing" --check
  fake kubeconform "echo 'v0.0.1'"
  expect 1 "--check goes red on a kubeconform that is present and different" --check
  fake kubeconform "echo 'v$K'"
  fake python3 "case \"\$*\" in *version_info*) echo '2.7' ;; *) exit 1 ;; esac"
  expect 1 "--check goes red on a python3 of another major version" --check
  fake python3 "case \"\$*\" in *version_info*) echo '$P' ;; *) exit 1 ;; esac"
  sed 's/^  HELM_VERSION: "[^"]*"/  HELM_VERSION: "v3.16.3"/' "$ROOT/.github/workflows/ci.yaml" > "$T/repo/.github/workflows/ci.yaml"
  expect 1 "--drift goes red on ci.yaml's helm moving without mise.toml" --drift
  cp "$ROOT/.github/workflows/ci.yaml" "$T/repo/.github/workflows/ci.yaml"
  printf 'env:\n  HELM_VERSION: "v%s"\n' "$H" > "$T/repo/.github/workflows/zz-extra.yaml"
  expect 1 "--drift goes red on a third workflow carrying its own copy, even an equal one" --drift
  rm "$T/repo/.github/workflows/zz-extra.yaml"
  printf '\nInstall Helm v3.16.3 first.\n' >> "$T/repo/CONTRIBUTING.md"
  expect 1 "--drift goes red on CONTRIBUTING.md naming another Helm" --drift
  cp "$ROOT/CONTRIBUTING.md" "$T/repo/CONTRIBUTING.md"
  expect 0 "--drift is green again once every copy is restored" --drift
  run --pins
  if grep "^HELM_VERSION=v$H\$" "$T/out" >/dev/null && grep "^PYTHON_VERSION=$P\$" "$T/out" >/dev/null; then
    echo "  ok    --pins prints HELM_VERSION=v$H and PYTHON_VERSION=$P"
  else echo "  FAIL  --pins output:"; sed 's/^/        /' "$T/out"; fails=1; fi
  [ "$fails" -eq 0 ] && echo "toolchain selftest: ok"
  return "$fails"
}

case "${1:-}" in
  --check)    do_check ;;
  --drift)    do_drift ;;
  --pins)     do_pins ;;
  --selftest) do_selftest ;;
  *) echo "usage: $0 --check | --drift | --pins | --selftest" >&2; exit 2 ;;
esac

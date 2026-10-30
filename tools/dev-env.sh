#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# A WORKING COPY THAT RUNS THE GATES THE WAY CI DOES.
#
#   tools/dev-env.sh                  install the pinned tools and the gates' Python packages, then check them
#   eval "$(tools/dev-env.sh --env)"  put them first on PATH in this shell (after a run without --env)
#
# What it sets up, all under build/ (ignored by git, never committed):
#
#   build/toolchain/bin   helm, kubeconform, shellcheck and gitleaks at the versions mise.toml pins. With mise
#                         on PATH this is `mise install` instead, and mise.lock carries the checksums. Without
#                         mise, on Linux x86_64 only, each release asset is downloaded and checked against the
#                         SHA-256 the workflows pin beside it (helm against the checksum file its project
#                         publishes next to the asset), and nothing unverified is installed.
#   build/gates-venv      the Python packages the gates import, from tools/requirements-gates.txt with
#                         --require-hashes: exactly those, at exactly those versions, and nothing else, so a
#                         package that happens to be installed on one machine cannot make a step pass there
#                         and fail in CI.
#   charts/*/charts/      the vendored subcharts (tools/helm-deps.sh), which every render gate needs.
#
# Then tools/toolchain.sh --check, and it exits non-zero on a mismatch.
#
# It needs a git checkout, not an unpacked archive. Several gates judge `git ls-files` (what ships), and a change
# made in an archive has no base blob ids to apply against a moved main. `git clone` the repository instead.
#
# macOS bash 3.2 and BSD userland. Needs curl, tar and python3 (3.12 or newer).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="$ROOT/build/toolchain/bin"
VENV="$ROOT/build/gates-venv"
PY=""

if [ "${1:-}" = "--env" ]; then
  [ -x "$VENV/bin/python" ] || { echo "echo 'dev-env: run tools/dev-env.sh first' >&2; false"; exit 0; }
  # shellcheck disable=SC2016  # $PATH is meant literally: the caller's shell expands it
  printf 'export PATH="%s:%s/bin:$PATH" TOCKMOX_UI_PYTHON="%s/bin/python"\n' "$BIN" "$VENV" "$VENV"
  exit 0
fi
[ -z "${1:-}" ] || { echo "usage: $0 [--env]" >&2; exit 2; }

if ! git --no-optional-locks -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "dev-env: $ROOT is not a git checkout. Clone the repository instead of unpacking an archive:"
  echo "  git clone https://github.com/tockmox/tockmox.git"
  exit 1
fi

wf_env() { sed -n "s/^  $2: \"\([^\"]*\)\".*/\1/p" "$ROOT/.github/workflows/$1" | head -n 1; }
pins="$(bash tools/toolchain.sh --pins)"
pinv() { printf '%s\n' "$pins" | sed -n "s/^$1=//p"; }

# ---------------------------------------------------------------------------------------------------- the tools
if command -v mise >/dev/null 2>&1; then
  echo "dev-env: mise install (mise.toml; checksums from mise.lock where it has them)"
  mise install
  mkdir -p "$BIN"
  for t in helm kubeconform shellcheck gitleaks; do
    p="$(mise which "$t" 2>/dev/null)" || { echo "dev-env: mise installed no $t"; exit 1; }
    ln -sf "$p" "$BIN/$t"
  done
  # The venv below is built from mise's Python, so a Mac whose python3 is the system 3.9 still gets the pinned one.
  PY="$(mise which python3 2>/dev/null || mise which python 2>/dev/null || true)"
else
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) ;;
    *) echo "dev-env: without mise, this script installs only on Linux x86_64."
       echo "  Install mise (https://mise.jdx.dev; on macOS: brew install mise), then run this again."
       exit 1 ;;
  esac
  mkdir -p "$BIN"
  DL="$(mktemp -d)"; trap 'rm -rf "$DL"' EXIT
  have_at() {  # have_at <tool> <text its version output must contain> <args...>
    local t="$1" want="$2"; shift 2
    [ -x "$BIN/$t" ] && "$BIN/$t" "$@" 2>/dev/null | grep -F "$want" >/dev/null
  }
  # Every download is written to a file and checked with `sha256sum -c` before anything reads it
  # (tools/check-action-pins.sh, P2). A mismatch stops the script under set -e, with nothing installed.

  v="$(pinv HELM_VERSION)"; a="helm-$v-linux-amd64.tar.gz"
  if have_at helm "$v+" version --short; then echo "dev-env: helm $v already in build/toolchain/bin"; else
    curl -fsSL -o "$DL/$a" "https://get.helm.sh/$a"
    curl -fsSL -o "$DL/$a.sha256sum" "https://get.helm.sh/$a.sha256sum"
    (cd "$DL" && sha256sum -c "$a.sha256sum")
    tar -xzf "$DL/$a" -C "$DL" linux-amd64/helm && install -m 755 "$DL/linux-amd64/helm" "$BIN/helm"
    echo "dev-env: helm $v installed (verified against get.helm.sh's published checksum)"
  fi

  v="$(pinv KUBECONFORM_VERSION)"
  if have_at kubeconform "$v" -v; then echo "dev-env: kubeconform $v already in build/toolchain/bin"; else
    curl -fsSL -o "$DL/kubeconform.tar.gz" "https://github.com/yannh/kubeconform/releases/download/v$v/kubeconform-linux-amd64.tar.gz"
    echo "$(wf_env ci.yaml KUBECONFORM_SHA256)  $DL/kubeconform.tar.gz" | sha256sum -c -
    tar -xzf "$DL/kubeconform.tar.gz" -C "$DL" kubeconform && install -m 755 "$DL/kubeconform" "$BIN/kubeconform"
    echo "dev-env: kubeconform $v installed (verified against ci.yaml's KUBECONFORM_SHA256)"
  fi

  v="$(pinv SHELLCHECK_VERSION)"
  if have_at shellcheck "version: $v" --version; then echo "dev-env: shellcheck $v already in build/toolchain/bin"; else
    curl -fsSL -o "$DL/shellcheck.tar.xz" "https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.linux.x86_64.tar.xz"
    echo "$(wf_env check-all.yaml SHELLCHECK_SHA256)  $DL/shellcheck.tar.xz" | sha256sum -c -
    tar -xJf "$DL/shellcheck.tar.xz" -C "$DL" && install -m 755 "$DL/shellcheck-v$v/shellcheck" "$BIN/shellcheck"
    echo "dev-env: shellcheck $v installed (verified against check-all.yaml's SHELLCHECK_SHA256)"
  fi

  v="$(pinv GITLEAKS_VERSION)"
  if have_at gitleaks "$v" version; then echo "dev-env: gitleaks $v already in build/toolchain/bin"; else
    curl -fsSL -o "$DL/gitleaks.tar.gz" "https://github.com/gitleaks/gitleaks/releases/download/v$v/gitleaks_${v}_linux_x64.tar.gz"
    echo "$(wf_env ci.yaml GITLEAKS_SHA256)  $DL/gitleaks.tar.gz" | sha256sum -c -
    tar -xzf "$DL/gitleaks.tar.gz" -C "$DL" gitleaks && install -m 755 "$DL/gitleaks" "$BIN/gitleaks"
    echo "dev-env: gitleaks $v installed (verified against ci.yaml's GITLEAKS_SHA256)"
  fi
fi

# ------------------------------------------------------------------------------------------- the Python packages
PY="${PY:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "dev-env: $PY is not on PATH"; exit 1; }
rm -rf "$VENV"
"$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install -q --disable-pip-version-check --require-hashes -r tools/requirements-gates.txt
echo "dev-env: build/gates-venv from tools/requirements-gates.txt ($("$VENV/bin/python" --version 2>&1))"

# ------------------------------------------------------------------------------------- subcharts, then the check
PATH="$BIN:$VENV/bin:$PATH"; export PATH
bash tools/helm-deps.sh >/dev/null
echo "dev-env: vendored subcharts in place (tools/helm-deps.sh)"
echo
bash tools/toolchain.sh --check
echo
echo "Ready. Put these first on PATH in your shell with:"
echo "  eval \"\$(tools/dev-env.sh --env)\""

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by mise (mise.toml's [env] _.source) each time a shell with mise activated enters this tree or one of
# its worktrees. Not meant to be run by hand.
#
# mise.toml puts build/gates-venv/bin first on PATH. This file finishes the job: with the venv present it exports
# VIRTUAL_ENV, so the shell is in the gates' venv exactly as if it had been activated; without it, it prints ONE
# line pointing at tools/dev-env.sh, which builds the venv from tools/requirements-gates.txt with hashes.
#
# Why not mise's own `_.python.venv` directive: with `create = false` and no venv, mise warns on several lines
# and points at a bare `python -m venv`, which would build a venv without the hashed packages; with `create = true`
# it builds one itself, also without them. Either way the venv would not be the one CI uses.
_tockmox_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -x "$_tockmox_root/build/gates-venv/bin/python" ]; then
  export VIRTUAL_ENV="$_tockmox_root/build/gates-venv"
else
  echo "tockmox: no build/gates-venv in $_tockmox_root yet; run tools/dev-env.sh there once" >&2
fi
unset _tockmox_root

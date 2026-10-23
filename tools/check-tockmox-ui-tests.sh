#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the Tockmox UI's own test suite, tockmox-ui/tests/ (TM-0975).
#
#   ./tools/check-tockmox-ui-tests.sh
#
# WHY THIS IS A GATE. tockmox-ui/ ships as source (TM-0902) and its tests ran
# only on whichever laptop wrote them until this landed. They are unit tests
# through FastAPI's TestClient with every upstream mocked (the Kubernetes API,
# Prometheus, Alertmanager, an inference node): no cluster and no network, so
# they belong beside the static gates.
#
# WHAT IT PROVES: every test under tockmox-ui/tests/ passes against the tree.
# What each test proves is in its own docstring.
#
# EXIT 2 (skipped, not passed) when the UI's Python dependencies are not
# importable from the python3 on PATH and no venv is named. Point TOCKMOX_UI_PYTHON
# at an interpreter that has `pip install -r tockmox-ui/requirements.txt pytest`
# installed; ci.yaml makes one. check-all.sh reports exit 2 as skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

py="${TOCKMOX_UI_PYTHON:-python3}"
if ! "$py" -c 'import fastapi, httpx, jwt, itsdangerous, yaml, pytest' >/dev/null 2>&1; then
  echo "check-tockmox-ui-tests: SKIPPED: $py lacks the UI's dependencies or pytest."
  echo "  python3 -m venv build/ui-venv && build/ui-venv/bin/pip install -r tockmox-ui/requirements.txt pytest"
  echo "  TOCKMOX_UI_PYTHON=build/ui-venv/bin/python ./tools/check-tockmox-ui-tests.sh"
  exit 2
fi
# A relative path (build/ui-venv/bin/python) is made absolute before the cd below; a bare command name
# (python3, the default) is left for PATH to find.
case "$py" in /*) ;; */*) py="$(pwd)/$py" ;; esac
n=$(find tockmox-ui/tests -name 'test_*.py' | wc -l | tr -d ' ')
if [ "$n" -eq 0 ]; then
  echo "check-tockmox-ui-tests: FAILED: no test files under tockmox-ui/tests/"
  exit 1
fi
cd tockmox-ui
"$py" -m pytest tests -q -p no:cacheprovider
echo "check-tockmox-ui-tests: ok ($n test file(s))"

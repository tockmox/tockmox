#!/bin/bash -eu
# SPDX-License-Identifier: Apache-2.0
#
# Runs inside the ClusterFuzzLite build image: package each tockmox-ui/fuzz/*_fuzzer.py into
# $OUT with PyInstaller (compile_python_fuzzer ships in the base image). --paths lets the
# targets' `from app import ...` resolve at build time.
n=0
for fuzzer in "$SRC"/tockmox/tockmox-ui/fuzz/*_fuzzer.py; do
  compile_python_fuzzer "$fuzzer" --paths "$SRC/tockmox/tockmox-ui"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "build.sh: no fuzz targets found" >&2; exit 1; }

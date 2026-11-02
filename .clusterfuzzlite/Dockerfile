# SPDX-License-Identifier: Apache-2.0
#
# The ClusterFuzzLite build image (.github/workflows/fuzz.yaml). It is built and run on the
# CI runner only and never pushed. The base carries Python, atheris and PyInstaller; the fuzz
# targets import only the standard library and the module under test, so nothing else is
# installed. Digest-pinned like every other base; Renovate moves the digest.
FROM gcr.io/oss-fuzz-base/base-builder-python:v1@sha256:21f6fab17ace4dc76e1c56de91ee95d3d03da021df94b41056ba036f6c6f55e9
COPY . $SRC/tockmox
WORKDIR $SRC/tockmox
COPY .clusterfuzzlite/build.sh $SRC/

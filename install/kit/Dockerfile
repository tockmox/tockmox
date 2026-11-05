# SPDX-License-Identifier: Apache-2.0
#
# THE INSTALL KIT: every tool the installer needs, at the versions this tag was tested with, in one
# image you build yourself. Optional. The installer still runs natively from a clone; this is a second
# way to launch the SAME scripts, never a second installer. docs/deployment/install-kit.md is the page.
#
# Build it from the tag you intend to install (the context is the REPOSITORY ROOT; no clone needed):
#
#   docker build -t tockmox-kit -f install/kit/Dockerfile https://github.com/tockmox/tockmox.git#<tag>
#
# Tockmox publishes no image (ADR-0036: source, not binaries), so the image is built on your machine
# from this file. Any OCI runtime that builds a Dockerfile works: Docker, Podman, nerdctl.
#
# Behind a TLS-intercepting proxy, hand the build your proxy's CA as a build secret. It is used for the
# downloads below and is not left in the image:
#
#   docker build --secret id=ca,src=/path/to/proxy-ca.pem -t tockmox-kit -f install/kit/Dockerfile .
#
# Every downloaded binary is checked against the SHA-256 written beside its version here, and a mismatch
# stops the build with nothing installed. helm's version must equal mise.toml's pin, kubeseal's must equal
# the controller bootstrap-secrets.sh installs, and kubectl's minor must equal the k3s the fresh-install
# page pins: tools/toolchain.sh --drift holds all three.
#
# Alpine, not Debian slim, for the reason tockmox-ui/Dockerfile records: a scanner that refuses High
# findings refused the Debian base. The base is pinned by digest (the multi-arch index) as well as by tag.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

ARG TARGETARCH
ARG HELM_VERSION="v4.3.1"
ARG HELM_SHA256_AMD64="0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b"
ARG HELM_SHA256_ARM64="8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88"
ARG KUBECTL_VERSION="v1.36.4"
ARG KUBECTL_SHA256_AMD64="8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a"
ARG KUBECTL_SHA256_ARM64="0ecf44450ee6063bf19dd166a103ee6df4a9034455c2abce626e6eea657d73fb"
ARG KUBESEAL_VERSION="0.40.0"
ARG KUBESEAL_SHA256_AMD64="9314c35916646e9d59c8f06b1314574b4e79c4d76f079433607ed7b697bb5eb7"
ARG KUBESEAL_SHA256_ARM64="d82f01e9226d194ca7ebc13e3619edefd596b5b433582bcec3d5a8e8b1a03123"

# One layer, so the build CA and the downloads never exist in any layer of the image.
# GNU coreutils, diffutils, sed, grep, gawk, tar and findutils, not BusyBox's: the scripts are written for macOS's BSD
# tools and for Linux CI's GNU ones, and BusyBox is neither.
RUN --mount=type=secret,id=ca,required=false \
    set -eu; \
    BUNDLE=/etc/ssl/certs/ca-certificates.crt; \
    if [ -s /run/secrets/ca ]; then \
      cp "$BUNDLE" /tmp/bundle.orig; cat /run/secrets/ca >> "$BUNDLE"; \
      cat "$BUNDLE" > /tmp/build-ca.pem; \
    else cp "$BUNDLE" /tmp/build-ca.pem; fi; \
    export SSL_CERT_FILE=/tmp/build-ca.pem CURL_CA_BUNDLE=/tmp/build-ca.pem; \
    apk upgrade --no-cache; \
    apk add --no-cache age bash ca-certificates coreutils curl diffutils findutils gawk git grep openssl python3 sed tar; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then case "$(apk --print-arch)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac; fi; \
    case "$arch" in \
      amd64) h="$HELM_SHA256_AMD64"; k="$KUBECTL_SHA256_AMD64"; s="$KUBESEAL_SHA256_AMD64" ;; \
      arm64) h="$HELM_SHA256_ARM64"; k="$KUBECTL_SHA256_ARM64"; s="$KUBESEAL_SHA256_ARM64" ;; \
      *) echo "install kit: no pinned checksums for architecture '${arch:-unknown}' (amd64 and arm64 only)" >&2; exit 1 ;; \
    esac; \
    d="$(mktemp -d)"; cd "$d"; \
    curl -fsSL -o helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"; \
    echo "$h  helm.tgz" | sha256sum -c -; \
    tar -xzf helm.tgz "linux-${arch}/helm"; install -m 0755 "linux-${arch}/helm" /usr/local/bin/helm; \
    curl -fsSL -o kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
    echo "$k  kubectl" | sha256sum -c -; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    curl -fsSL -o kubeseal.tgz "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${arch}.tar.gz"; \
    echo "$s  kubeseal.tgz" | sha256sum -c -; \
    tar -xzf kubeseal.tgz kubeseal; install -m 0755 kubeseal /usr/local/bin/kubeseal; \
    cd /; rm -rf "$d" /tmp/build-ca.pem; \
    if [ -f /tmp/bundle.orig ]; then mv /tmp/bundle.orig "$BUNDLE"; fi; \
    update-ca-certificates >/dev/null 2>&1 || true

# The tree of the tag you built from. Dockerfile.dockerignore beside this file decides what is sent.
COPY . /opt/tockmox
# COPY keeps the build context's modes, and a checkout on a synced or umask-077 filesystem is 0600
# (tockmox-ui/Dockerfile met this on 2026-10-07). Readable by everyone, owned by root, changed by no one.
RUN chmod -R a+rX /opt/tockmox

# What the kit reports about itself (`kit-check`), so a version question has one answer.
ENV TOCKMOX_KIT_HELM="${HELM_VERSION}" \
    TOCKMOX_KIT_KUBECTL="${KUBECTL_VERSION}" \
    TOCKMOX_KIT_KUBESEAL="${KUBESEAL_VERSION}" \
    KUBECONFIG=/kube/config \
    HOME=/tmp/home \
    TMPDIR=/tmp

# Any uid works: everything the tools write goes under /tmp (HOME is inside it) or into /work, which is
# your directory. The launcher runs the container as YOUR uid, so what lands in /work is yours.
USER 65534:65534
WORKDIR /work
# Through bash, not by its mode: a tree whose files arrived without the exec bit (a synced drive, a
# repository host that dropped it) would otherwise build an image that cannot start.
ENTRYPOINT ["bash", "/opt/tockmox/install/kit/entrypoint.sh"]
CMD ["--help"]

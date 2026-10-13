# SPDX-License-Identifier: Apache-2.0
# Security Posture Probe image. Tockmox distributes source, never images
# (ADR-0036): the site builds this and names it in the chart's `image` value.
#
#   docker build -t <your-registry>/tockmox/posture-probe:0.1.0 addons/posture-probe
#
# Stdlib only. Nothing is installed at build time beyond the base image and
# nothing is fetched at run time, so the image is the whole supply chain and a
# dark site mirrors one base image. Alpine for the same reason the other
# Tockmox-built images use it: a smaller base with fewer unused packages for a
# scanner to flag.
FROM python:3.14-alpine
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY posture_probe ./posture_probe
COPY schema ./schema
# COPY keeps the build context's file modes, and a checkout with a tight umask is
# 0600: the image would start and fail to read its own code as 65534 (the same
# defect the Tockmox UI image hit in its first lab run). Readable by all, owned
# by root, writable by nobody.
RUN chmod -R a+rX,go-w /srv
USER 65534:65534
ENTRYPOINT ["python3", "-m", "posture_probe"]
CMD ["--help"]

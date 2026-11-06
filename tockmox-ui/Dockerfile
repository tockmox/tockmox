# SPDX-License-Identifier: Apache-2.0
# Tockmox UI. Tockmox publishes no image (ADR-0036); for 0.8.0 the site builds
# this one (PA-S-5) and names it in the AI layer's tockmoxUi.image:
#
#   docker build -f tockmox-ui/Dockerfile -t <your-registry>/tockmox/tockmox-ui:<tag> .
#
# The context is the REPOSITORY ROOT, so the release notes the UI shows are the
# CHANGELOG.md of the tag you build, not a copy that can fall behind it.
#
# docs/administration/tockmox-ui.md has the build, the push and the upgrade.
# Alpine, not slim: python:3.12-slim scanned 44 unfixed High (Debian trixie base packages, none
# fixable), and a registry that blocks pulls at High (Harbor's prevent_vul, a common setting) refuses the image.
# The UI's packages ship musllinux wheels, except PyYAML, which has no cp315 wheel yet and installs from its
# sdist. /etc/ssl/certs/ca-certificates.crt, which the chart's trust-bundle initContainer reads, is present.
# The base is pinned by digest (the multi-arch index) as well as by tag; Renovate moves both together.
FROM python:3.15-alpine@sha256:20a82dbc2783112ddb91d1534603f802d222a3e63e593cd002eb2ac534e70211
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY tockmox-ui/requirements.txt .
# Install the requirements, then remove pip and the bundled pip wheel: the app installs nothing at run time,
# and pip VENDORS its own urllib3, msgpack and setuptools (pip/_vendor/vendor.txt). On python:3.14-alpine
# (pip 26.2.1) those scanned 4 High (urllib3 2.7.0 twice, msgpack 1.1.2, setuptools 70.3.0; fixed upstream,
# not in pip's copies), and a registry that refuses High refused the image (the reference site's
# first rc1 build, 2026-10-11). `apk upgrade` takes the base's pending Alpine fixes (zlib, Medium, that day).
# requirements.txt is a lockfile compiled from requirements.in with a hash for every file, so pip installs
# exactly the versions it names and refuses any file whose hash it does not list; --no-deps because the
# lockfile already names every dependency.
# git: tockmox-actions (the same image) makes Site history's "Download a copy", a git bundle of the site's main,
# the way the off-site copy job does (app/forge.py, Forge.bundle). The console itself never runs it.
RUN apk upgrade --no-cache \
 && apk add --no-cache git \
 && pip install --no-cache-dir --require-hashes --no-deps -r requirements.txt \
 && pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.*/ensurepip
COPY tockmox-ui/app ./app
# The ai-node schemas sit beside app/ so app/ai_nodes.py finds them at ../ai-node/schema (the renderer's check and the enroll flow).
COPY ai-node/schema ./ai-node/schema
COPY CHANGELOG.md ./notes/CHANGELOG.md
# COPY keeps the files' modes from the build context, and a checkout on a synced or umask-077 filesystem is 0600:
# the image then starts and cannot read its own code as 65534 (lab, 2026-10-07). Readable by all, owned by root.
RUN chmod -R a+rX /srv
USER 65534:65534
EXPOSE 8080
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips", "*"]

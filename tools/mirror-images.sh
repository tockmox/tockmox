#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Mirror every image in images.txt into your own registry, for air-gapped
# installs. Run on a machine that can reach both the internet and your
# registry (or run it internet-side and move the registry across).
#
#   ./tools/mirror-images.sh --registry harbor.int.example.com/mirror
#   ./tools/mirror-images.sh --registry ... --dry-run       # print, do nothing
#   ./tools/mirror-images.sh --registry ... --images FILE   # not images.txt
#   ./tools/mirror-images.sh --registry ... --verify        # assert every entry resolves
#   ./tools/mirror-images.sh --selftest                     # prove --verify can fail
#
# --verify IS THE SUCCESS CONDITION, and a catalogue count is not. On
# 2026-08-24 a registry listed 41 repositories while 3 of 44 images were
# unresolvable, because a repository appears in the catalogue as soon as ONE
# architecture variant lands. So --verify asks the registry for every entry's
# manifest at the exact reference the chart will pull (`skopeo inspect --raw`,
# or `crane manifest`), one entry at a time, and exits non-zero if any single
# one is missing ... even when its repository exists. It reads only; nothing is
# copied. Run it from inside the boundary, with the uplink cut if you can.
#
# WHY A TOOL AND NOT A SNIPPET. The docs carried an inline loop for this, and
# the loop's one subtle part ... path handling ... is exactly the part people
# get wrong. `global.imageRegistry` prepends your prefix to the repository AS
# THE CHART WRITES IT: the upstream host is dropped but the organization is
# kept, so `docker.io/grafana/grafana:13.1.3` must land at
# `${REG}/grafana/grafana:13.1.3` and NOT `${REG}/grafana:13.1.3`. A mirror
# built with flattened names is full of images no manifest asks for, and the
# failure appears later as ImagePullBackOff on the one disconnected cluster
# where you cannot just pull. Digest-pinned references are safe here because
# copies preserve digests; they land under a derived tag and the manifest's
# @sha256 reference resolves against the blob, not the tag.
#
# Prefers skopeo (multi-arch correct, no daemon); falls back to crane, then
# docker (single-arch: warns, since a mirror built on amd64 with docker will
# not serve an arm64 node).
#
# Idempotent: a destination that already holds the same digest is skipped, so
# re-running after a partial failure copies only what is missing.
set -u

REG=""
IMAGES="images.txt"
DRY=0
VERIFY=0
SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REG="$2"; shift 2 ;;
    --images)   IMAGES="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --verify)   VERIFY=1; shift ;;
    --selftest) SELFTEST=1; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# --selftest: prove --verify goes red on a single miss, hermetically. A stub
# skopeo on PATH answers `inspect --raw` from a fixed set of "present"
# references; everything else is a miss. No network, no registry.
# ---------------------------------------------------------------------------
if [ "$SELFTEST" = 1 ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin"
  cat > "$T/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
# stub: `skopeo inspect --raw docker://REF` succeeds only for REFs listed in
# $STUB_PRESENT (one per line). Anything else is "manifest unknown".
eval "ref=\${$#}"; ref="${ref#docker://}"   # last argument; bash 3.2 safe
if grep -qxF "$ref" "$STUB_PRESENT"; then
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json"}\n'
else
  echo "FATA[0000] Error parsing image name \"docker://$ref\": reading manifest: manifest unknown" >&2
  exit 1
fi
STUB
  chmod +x "$T/bin/skopeo"
  printf 'docker.io/grafana/grafana:1.0\nbusybox:1.36\nghcr.io/org/app@sha256:%s\n' \
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$T/images.txt"
  # Present set: exactly what --verify should ask for, per the dest_path rule.
  printf 'reg.test/m/grafana/grafana:1.0\nreg.test/m/busybox:1.36\nreg.test/m/org/app:sha256-0123456789ab\n' > "$T/present.txt"
  pass=0; fail=0
  ok()  { pass=$((pass+1)); echo "ok   $1"; }
  bad() { fail=$((fail+1)); echo "FAIL $1"; }

  out="$(STUB_PRESENT="$T/present.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/images.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '3 present, 0 missing'; then ok "all present: exit 0, counts 3/0"
  else bad "all present: expected exit 0 and '3 present, 0 missing', got rc=$rc: $out"; fi

  grep -v busybox "$T/present.txt" > "$T/present2.txt"
  out="$(STUB_PRESENT="$T/present2.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/images.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'MISSING     busybox:1.36' && printf '%s' "$out" | grep -q '2 present, 1 missing'; then ok "one miss: exit 1, names it, counts 2/1"
  else bad "one miss: expected exit 1 naming busybox:1.36, got rc=$rc: $out"; fi

  : > "$T/present3.txt"
  out="$(STUB_PRESENT="$T/present3.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/images.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '0 present, 3 missing'; then ok "empty mirror: exit 1, counts 0/3"
  else bad "empty mirror: expected exit 1 and 0/3, got rc=$rc: $out"; fi

  : > "$T/none.txt"
  out="$(STUB_PRESENT="$T/present.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/none.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "an empty images file refuses rather than passing vacuously"
  else bad "empty images file passed: $out"; fi

  echo; echo "mirror-images --selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]; exit $?
fi

[ -n "$REG" ] || { echo "ERROR: --registry is required (e.g. --registry harbor.example.com/mirror)" >&2; exit 2; }
[ -f "$IMAGES" ] || { echo "ERROR: $IMAGES not found. Run from the repo root, or pass --images." >&2; exit 2; }

TOOL=""
if command -v skopeo >/dev/null 2>&1; then TOOL=skopeo
elif command -v crane >/dev/null 2>&1; then TOOL=crane
elif command -v docker >/dev/null 2>&1; then
  TOOL=docker
  echo "WARN: using docker, which copies only THIS machine's architecture." >&2
  echo "      A multi-arch cluster needs skopeo or crane." >&2
fi
if [ -z "$TOOL" ] && [ "$DRY" != 1 ]; then
  echo "ERROR: need skopeo, crane, or docker on PATH (--dry-run works without)." >&2; exit 2
fi
if [ "$VERIFY" = 1 ] && [ "$TOOL" = docker ]; then
  echo "ERROR: --verify needs skopeo or crane. docker cannot read a manifest without pulling it." >&2; exit 2
fi

# The path rule global.imageRegistry actually applies: drop the registry host
# if the first path element looks like one (contains a dot or a colon), keep
# everything else including the organization.
dest_path() {
  img="$1"
  first="${img%%/*}"
  if [ "$first" = "$img" ]; then
    printf '%s' "$img"                       # bare name: no host, no org
  elif printf '%s' "$first" | grep -q '[.:]'; then
    printf '%s' "${img#*/}"                  # first element is a host: strip it
  else
    printf '%s' "$img"                       # org/name on implied docker.io
  fi
}

src_digest() {
  case "$TOOL" in
    skopeo) skopeo inspect --format '{{.Digest}}' "docker://$1" 2>/dev/null ;;
    crane)  crane digest "$1" 2>/dev/null ;;
    docker) echo "" ;;                       # docker path skips the check
  esac
}

dst_digest() {
  case "$TOOL" in
    skopeo) skopeo inspect --format '{{.Digest}}' "docker://$1" 2>/dev/null ;;
    crane)  crane digest "$1" 2>/dev/null ;;
    docker) echo "unknown" ;;
  esac
}

copy_image() {
  case "$TOOL" in
    skopeo) skopeo copy --all --preserve-digests "docker://$1" "docker://$2" ;;
    crane)  crane copy "$1" "$2" ;;
    docker) docker pull "$1" && docker tag "$1" "$2" && docker push "$2" ;;
  esac
}

# The manifest at the exact reference, read-only. Empty output is a miss, even
# on exit 0: an empty manifest is not a manifest.
raw_manifest() {
  case "$TOOL" in
    skopeo) skopeo inspect --raw "docker://$1" 2>/dev/null ;;
    crane)  crane manifest "$1" 2>/dev/null ;;
  esac
}

COPIED=0; SKIPPED=0; FAILED=0; FAILED_LIST=""
PRESENT=0; MISSING=0; MISSING_LIST=""; ENTRIES=0
while IFS= read -r img; do
  case "$img" in ''|'#'*) continue ;; esac

  path=$(dest_path "$img")
  case "$img" in
    *@sha256:*)
      # Digest-pinned source: land it under a derived tag. The copy preserves
      # the digest, so the chart's @sha256 reference resolves in your mirror.
      d="${img##*@sha256:}"
      base="${path%%@*}"
      # Strip any tag riding alongside the digest (name:tag@sha256:...); the
      # host is already stripped, so a colon here can only be a tag separator.
      case "$base" in *:*) base="${base%:*}" ;; esac
      dest="${REG}/${base}:sha256-$(printf '%s' "$d" | cut -c1-12)"
      ;;
    *) dest="${REG}/${path}" ;;
  esac

  ENTRIES=$((ENTRIES + 1))
  if [ "$DRY" = 1 ]; then
    echo "would copy  $img"
    echo "        ->  $dest"
    continue
  fi

  if [ "$VERIFY" = 1 ]; then
    m="$(raw_manifest "$dest")"
    if [ -n "$m" ]; then
      echo "present     $dest"
      PRESENT=$((PRESENT + 1))
    else
      echo "MISSING     $img" >&2
      echo "        at  $dest" >&2
      MISSING=$((MISSING + 1))
      MISSING_LIST="${MISSING_LIST}  ${img}  ->  ${dest}
"
    fi
    continue
  fi

  s=$(src_digest "$img"); t=$(dst_digest "$dest")
  if [ -n "$s" ] && [ "$s" = "$t" ]; then
    echo "up to date  $dest"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "copying     $img"
  echo "        ->  $dest"
  if copy_image "$img" "$dest"; then
    COPIED=$((COPIED + 1))
  else
    echo "FAILED      $img" >&2
    FAILED=$((FAILED + 1))
    FAILED_LIST="${FAILED_LIST}  ${img}
"
  fi
done < "$IMAGES"

[ "$DRY" = 1 ] && exit 0

if [ "$ENTRIES" -eq 0 ]; then
  echo "ERROR: $IMAGES carries no image entries. A gate that examines nothing must not pass." >&2
  exit 2
fi

if [ "$VERIFY" = 1 ]; then
  echo
  echo "mirror-images --verify: ${ENTRIES} entries, ${PRESENT} present, ${MISSING} missing at ${REG}"
  if [ "$MISSING" -gt 0 ]; then
    echo "missing:" >&2
    printf '%s' "$MISSING_LIST" >&2
    echo "A repository that exists is not an image that resolves. Re-run the mirror" >&2
    echo "for these, then re-run --verify. Do not read a catalogue count instead." >&2
    exit 1
  fi
  echo "Every entry resolves at the target prefix. That is the success condition,"
  echo "not a repository count."
  exit 0
fi

echo
echo "mirror-images: ${COPIED} copied, ${SKIPPED} already current, ${FAILED} failed"
if [ "$FAILED" -gt 0 ]; then
  echo "failed:" >&2
  printf '%s' "$FAILED_LIST" >&2
  echo "Re-run after fixing; images already mirrored are skipped." >&2
  exit 1
fi
echo "Next: from inside the boundary, ./tools/mirror-images.sh --registry ${REG} --verify"
echo "Then point every node's containerd at ${REG} (docs/deployment/airgap.md section 2)."
echo "global.imageRegistry is the fallback for sites that cannot configure the nodes;"
echo "airgap.md lists the images that key does NOT redirect."

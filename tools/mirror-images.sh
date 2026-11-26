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
#   ./tools/mirror-images.sh --registry ... --verify        # assert every entry resolves, at its digest
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
# --verify ALSO COMPARES DIGESTS, for every entry that records one
# (NAME@sha256:... or NAME:TAG@sha256:...). It hashes the manifest each
# destination holds and refuses one whose SHA-256 is not the recorded digest,
# naming both. Presence alone cannot see a tag that upstream re-pushed and that
# was copied by tag, or a mirror refreshed from a source that no longer serves
# the pinned bytes. An entry with a tag and no digest records nothing to compare
# against, so for it --verify can assert only that the manifest is there.
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
# @sha256 reference resolves against the blob, not the tag. A reference that
# carries a tag beside its digest (NAME:TAG@sha256:...) also lands under that
# tag, because some charts pull it by the tag alone; --verify asks for both.
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

# sha256_stdin: the SHA-256 of stdin as bare hex (sha256sum on Linux, shasum on macOS).
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# ---------------------------------------------------------------------------
# --selftest: prove --verify goes red on a single miss, and on a manifest whose
# bytes are not the recorded digest, hermetically. A stub skopeo on PATH
# answers `inspect --raw` from a fixed set of "present" references, with the
# bytes of one fixed manifest (or, for a reference marked `other`, of a
# different one); everything else is a miss. No network, no registry.
# ---------------------------------------------------------------------------
if [ "$SELFTEST" = 1 ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin"
  cat > "$T/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
# stub: `skopeo inspect --raw docker://REF` succeeds only for REFs listed in
# $STUB_PRESENT (one per line), printing the bytes of $STUB_MANIFEST, or of
# $STUB_MANIFEST.other for a line `REF other`. Anything else is "manifest unknown".
eval "ref=\${$#}"; ref="${ref#docker://}"   # last argument; bash 3.2 safe
if kind="$(awk -v r="$ref" '$1 == r { print $2; f = 1 } END { exit !f }' "$STUB_PRESENT")"; then
  if [ "$kind" = other ]; then cat "$STUB_MANIFEST.other"; else cat "$STUB_MANIFEST"; fi
else
  echo "FATA[0000] Error parsing image name \"docker://$ref\": reading manifest: manifest unknown" >&2
  exit 1
fi
STUB
  chmod +x "$T/bin/skopeo"
  # The stub's manifest, and its real digest: a digest-pinned entry that names
  # it is what a correct mirror holds. The .other manifest is a re-pushed tag.
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json"}\n' > "$T/manifest.json"
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}\n' > "$T/manifest.json.other"
  export STUB_MANIFEST="$T/manifest.json"
  DG="$(sha256_stdin < "$T/manifest.json")"; DG12="$(printf '%s' "$DG" | cut -c1-12)"
  OTHER="$(sha256_stdin < "$T/manifest.json.other")"; OTHER12="$(printf '%s' "$OTHER" | cut -c1-12)"
  printf 'docker.io/grafana/grafana:1.0\nbusybox:1.36\nghcr.io/org/app@sha256:%s\n' "$DG" > "$T/images.txt"
  # Present set: exactly what --verify should ask for, per the dest_path rule,
  # plus library/ for the Docker Hub official image (the path containerd asks for).
  printf 'reg.test/m/grafana/grafana:1.0\nreg.test/m/busybox:1.36\nreg.test/m/library/busybox:1.36\nreg.test/m/org/app:sha256-%s\n' "$DG12" > "$T/present.txt"
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

  grep -v '/library/busybox' "$T/present.txt" > "$T/present4.txt"
  out="$(STUB_PRESENT="$T/present4.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/images.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'at  reg.test/m/library/busybox:1.36' && printf '%s' "$out" | grep -q '2 present, 1 missing'; then ok "an official image missing under library/ (where containerd asks): exit 1, names that path"
  else bad "library/ miss: expected exit 1 naming reg.test/m/library/busybox:1.36, got rc=$rc: $out"; fi

  printf 'docker.io/traefik:v3\ndocker.io/library/postgres:17\nquay.io/solo:1\n' > "$T/official.txt"
  out="$(bash "$SELF" --registry reg.test/m --images "$T/official.txt" --dry-run 2>&1)"
  if printf '%s' "$out" | grep -qx '        ->  reg.test/m/library/traefik:v3' && ! printf '%s' "$out" | grep -q 'library/library' \
     && ! printf '%s' "$out" | grep -q 'library/solo'; then ok "dry run: docker.io/NAME also lands under library/; library/ is not doubled; other registries are left alone"
  else bad "dry run library/ handling: $out"; fi

  : > "$T/present3.txt"
  out="$(STUB_PRESENT="$T/present3.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/images.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '0 present, 3 missing'; then ok "empty mirror: exit 1, counts 0/3"
  else bad "empty mirror: expected exit 1 and 0/3, got rc=$rc: $out"; fi

  : > "$T/none.txt"
  out="$(STUB_PRESENT="$T/present.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/none.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q 'carries no image entries' <<<"$out"; then ok "an empty images file refuses (exit 2, saying so) rather than passing vacuously"
  else bad "empty images file: expected exit 2 and the no-entries message, got rc=$rc: $out"; fi

  # The copy path, for a reference carrying both a tag and a digest. This stub
  # skopeo refuses such a reference as the real one does, finds nothing at any
  # destination, and logs every copy it accepts as "SRC DST".
  mkdir -p "$T/copybin"
  cat > "$T/copybin/skopeo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = copy ] || exit 1          # inspect: nothing is there yet
eval "src=\${$(($# - 1))}"; eval "dst=\${$#}"
for r in "$src" "$dst"; do
  n="${r#docker://}"; n="${n%%@*}"; n="${n##*/}"
  case "$r" in *@sha256:*) case "$n" in *:*)
    echo "Error: invalid source name $r: Docker references with both a tag and digest are currently not supported" >&2; exit 1 ;;
  esac ;; esac
done
echo "${src#docker://} ${dst#docker://}" >> "$STUB_LOG"
STUB
  chmod +x "$T/copybin/skopeo"
  dg="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  printf 'quay.io/org/reloader:v1.2@sha256:%s\nlocalhost:5000/org/app:v3@sha256:%s\n' "$dg" "$dg" > "$T/tagdigest.txt"
  : > "$T/copy.log"
  out="$(STUB_LOG="$T/copy.log" PATH="$T/copybin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/tagdigest.txt" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '4 copied, 0 already current, 0 failed' \
     && grep -qxF "quay.io/org/reloader@sha256:$dg reg.test/m/org/reloader:sha256-0123456789ab" "$T/copy.log" \
     && grep -qxF "localhost:5000/org/app@sha256:$dg reg.test/m/org/app:sha256-0123456789ab" "$T/copy.log"; then
    ok "a tag-plus-digest reference copies by digest to the derived tag --verify asks for (a registry port is kept)"
  else bad "tag-plus-digest copy: expected exit 0, 4 copied, by digest to the derived tag; got rc=$rc: $out; log: $(cat "$T/copy.log")"; fi

  # The same entries land under their own tag too, by digest, since a pull by
  # the tag alone (a chart that drops the digest, or a node's registry rewrite
  # of that pull) asks the mirror for NAME:TAG.
  if grep -qxF "quay.io/org/reloader@sha256:$dg reg.test/m/org/reloader:v1.2" "$T/copy.log" \
     && grep -qxF "localhost:5000/org/app@sha256:$dg reg.test/m/org/app:v3" "$T/copy.log"; then
    ok "a tag-plus-digest reference also lands under its own tag, copied by digest"
  else bad "tag-plus-digest copy by tag: expected copies to reg.test/m/org/reloader:v1.2 and reg.test/m/org/app:v3; log: $(cat "$T/copy.log")"; fi

  # --verify asks for the tag form as well: a mirror holding only the derived
  # tag is a miss, named at the tag.
  printf 'quay.io/org/reloader:v1.2@sha256:%s\n' "$DG" > "$T/td-verify.txt"
  printf 'reg.test/m/org/reloader:sha256-%s\n' "$DG12" > "$T/td-derived.txt"
  out="$(STUB_PRESENT="$T/td-derived.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/td-verify.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'at  reg.test/m/org/reloader:v1.2' && printf '%s' "$out" | grep -q '0 present, 1 missing'; then
    ok "--verify: a tag-plus-digest entry held only under its derived tag is a miss, named at the tag"
  else bad "tag-plus-digest verify: expected exit 1 naming reg.test/m/org/reloader:v1.2, got rc=$rc: $out"; fi
  printf 'reg.test/m/org/reloader:v1.2\n' >> "$T/td-derived.txt"
  out="$(STUB_PRESENT="$T/td-derived.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/td-verify.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '1 present, 0 missing'; then
    ok "--verify: the same entry held under both its derived tag and its own tag is present"
  else bad "tag-plus-digest verify, both held: expected exit 0 and 1/0, got rc=$rc: $out"; fi

  # --verify compares what the mirror holds with the digest the entry records.
  # A planted wrong digest: the mirror holds the stub's manifest under both
  # names the entry asks for, but the entry records another digest. Red, and
  # the line names both digests.
  printf 'quay.io/org/reloader:v1.2@sha256:%s\n' "$OTHER" > "$T/td-wrong.txt"
  printf 'reg.test/m/org/reloader:sha256-%s\nreg.test/m/org/reloader:v1.2\n' "$OTHER12" > "$T/td-wrong-present.txt"
  out="$(STUB_PRESENT="$T/td-wrong-present.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/td-wrong.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "WRONG DIGEST quay.io/org/reloader:v1.2@sha256:$OTHER" \
     && printf '%s' "$out" | grep -q "holds  sha256:$DG" && printf '%s' "$out" | grep -q '0 present, 0 missing, 1 at another digest'; then
    ok "--verify: a mirror holding other bytes than the recorded digest is red, naming both digests"
  else bad "planted wrong digest: expected exit 1, WRONG DIGEST and 0/0/1, got rc=$rc: $out"; fi

  # The tag form re-pointed: the derived tag holds the recorded digest, but the
  # entry's own tag holds a different manifest (a tag copied after upstream
  # re-pushed it). Red, named at the tag; the same mirror with the tag holding
  # the recorded bytes is green and says so per destination.
  printf 'reg.test/m/org/reloader:sha256-%s\nreg.test/m/org/reloader:v1.2 other\n' "$DG12" > "$T/td-moved.txt"
  out="$(STUB_PRESENT="$T/td-moved.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/td-verify.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'at  reg.test/m/org/reloader:v1.2' \
     && printf '%s' "$out" | grep -q "holds  sha256:$OTHER" && printf '%s' "$out" | grep -q '0 present, 0 missing, 1 at another digest'; then
    ok "--verify: an entry whose own tag holds other bytes is red, named at the tag"
  else bad "re-pointed tag: expected exit 1 naming reg.test/m/org/reloader:v1.2 and the digest it holds, got rc=$rc: $out"; fi
  out="$(STUB_PRESENT="$T/td-derived.txt" PATH="$T/bin:$PATH" bash "$SELF" --registry reg.test/m --images "$T/td-verify.txt" --verify 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c "^verified    .* sha256:$DG\$")" = 2 ] \
     && printf '%s' "$out" | grep -q '1 present, 0 missing, 0 at another digest'; then
    ok "--verify: the recorded digest at both names is green, each destination verified by digest"
  else bad "recorded digest held: expected exit 0 and two verified lines, got rc=$rc: $out"; fi

  # A Docker Hub official image with a tag and a digest: both forms, each also under library/.
  printf 'busybox:1.36@sha256:%s\n' "$dg" > "$T/td-official.txt"
  out="$(bash "$SELF" --registry reg.test/m --images "$T/td-official.txt" --dry-run 2>&1)"
  if [ "$(printf '%s\n' "$out" | grep -c '^        ->  ')" = 4 ] \
     && printf '%s' "$out" | grep -qx '        ->  reg.test/m/busybox:1.36' \
     && printf '%s' "$out" | grep -qx '        ->  reg.test/m/library/busybox:1.36' \
     && printf '%s' "$out" | grep -qx '        ->  reg.test/m/library/busybox:sha256-0123456789ab'; then
    ok "dry run: an official tag-plus-digest image lands under its tag and its derived tag, each also under library/"
  else bad "official tag-plus-digest dry run: expected four destinations, got: $out"; fi

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

# docker_official IMG : true for a Docker Hub official image, the ones containerd
# names library/NAME: a bare name, or docker.io/NAME with no organization.
docker_official() {
  case "$1" in
    */*) ;;
    *) return 0 ;;
  esac
  case "${1%%/*}" in
    docker.io|index.docker.io|registry-1.docker.io)
      case "${1#*/}" in */*) return 1 ;; *) return 0 ;; esac ;;
  esac
  return 1
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

# manifest_digest REF : sha256:HEX of the manifest bytes held at REF, which is
# the digest a pull by digest asks for; empty when nothing is there. The bytes
# go through a file, not $(...), which would drop a trailing newline and change
# the hash.
manifest_digest() {
  raw_manifest "$1" > "$MTMP" || true
  [ -s "$MTMP" ] || return 0
  printf 'sha256:%s' "$(sha256_stdin < "$MTMP")"
}
if [ "$VERIFY" = 1 ]; then MTMP="$(mktemp)"; trap 'rm -f "$MTMP"' EXIT; fi

COPIED=0; SKIPPED=0; FAILED=0; FAILED_LIST=""
PRESENT=0; MISSING=0; MISSING_LIST=""; ENTRIES=0; WRONG=0; WRONG_LIST=""
while IFS= read -r img; do
  case "$img" in ''|'#'*) continue ;; esac

  path=$(dest_path "$img")
  src="$img"
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
      # Read the source by digest alone. skopeo refuses a reference carrying
      # both a tag and a digest ("Docker references with both a tag and digest
      # are currently not supported"), and the digest is what the chart pulls.
      # Only the last path element can carry the tag; a colon before it is a
      # registry port.
      name="${img%%@*}"; last="${name##*/}"
      tag=""
      case "$last" in *:*) tag="${last##*:}"; name="${name%:*}" ;; esac
      src="${name}@sha256:${d}"
      # A tag beside the digest is a name something may pull by: a chart that
      # renders the tag alone, or a node's registry rewrite of that pull. Land
      # the same digest under it too, so the tag resolves in the mirror.
      if [ -n "$tag" ]; then dest="$dest ${REG}/${base}:${tag}"; fi
      ;;
    *) dest="${REG}/${path}" ;;
  esac

  # Docker Hub's official images (a bare name, or docker.io/NAME) live under
  # library/ as far as containerd is concerned: a node whose registries.yaml
  # rewrites docker.io pulls onto this prefix asks for PREFIX/library/NAME, while
  # global.imageRegistry asks for PREFIX/NAME. Land both, so either mechanism
  # finds the image; --verify asks for both.
  dests="$dest"
  if docker_official "$img"; then
    for d in $dest; do dests="$dests ${REG}/library/${d#"${REG}"/}"; done
  fi

  ENTRIES=$((ENTRIES + 1))
  if [ "$DRY" = 1 ]; then
    echo "would copy  $img"
    for d in $dests; do echo "        ->  $d"; done
    continue
  fi

  if [ "$VERIFY" = 1 ]; then
    # The digest this entry records, if any: every destination must hold it.
    want=""
    case "$img" in *@sha256:*) want="sha256:${img##*@sha256:}" ;; esac
    all=1; same=1
    for d in $dests; do
      got="$(manifest_digest "$d")"
      if [ -z "$got" ]; then
        all=0
        echo "MISSING     $img" >&2
        echo "        at  $d" >&2
        MISSING_LIST="${MISSING_LIST}  ${img}  ->  ${d}
"
      elif [ -n "$want" ] && [ "$got" != "$want" ]; then
        same=0
        echo "WRONG DIGEST $img" >&2
        echo "        at  $d" >&2
        echo "     holds  $got" >&2
        WRONG_LIST="${WRONG_LIST}  ${img}  ->  ${d}  holds ${got}
"
      elif [ -n "$want" ]; then
        echo "verified    $d  $got"
      else
        echo "present     $d"
      fi
    done
    if [ "$all" = 0 ]; then MISSING=$((MISSING + 1))
    elif [ "$same" = 0 ]; then WRONG=$((WRONG + 1))
    else PRESENT=$((PRESENT + 1)); fi
    continue
  fi

  for d in $dests; do
    s=$(src_digest "$src"); t=$(dst_digest "$d")
    if [ -n "$s" ] && [ "$s" = "$t" ]; then
      echo "up to date  $d"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    echo "copying     $img"
    echo "        ->  $d"
    if copy_image "$src" "$d"; then
      COPIED=$((COPIED + 1))
    else
      echo "FAILED      $img" >&2
      FAILED=$((FAILED + 1))
      FAILED_LIST="${FAILED_LIST}  ${img}  ->  ${d}
"
    fi
  done
done < "$IMAGES"

[ "$DRY" = 1 ] && exit 0

if [ "$ENTRIES" -eq 0 ]; then
  echo "ERROR: $IMAGES carries no image entries. A gate that examines nothing must not pass." >&2
  exit 2
fi

if [ "$VERIFY" = 1 ]; then
  echo
  echo "mirror-images --verify: ${ENTRIES} entries, ${PRESENT} present, ${MISSING} missing, ${WRONG} at another digest at ${REG}"
  if [ "$MISSING" -gt 0 ]; then
    echo "missing:" >&2
    printf '%s' "$MISSING_LIST" >&2
    echo "A repository that exists is not an image that resolves. Re-run the mirror" >&2
    echo "for these, then re-run --verify. Do not read a catalogue count instead." >&2
  fi
  if [ "$WRONG" -gt 0 ]; then
    echo "at another digest:" >&2
    printf '%s' "$WRONG_LIST" >&2
    echo "The mirror holds other bytes than images.txt records. Do not re-tag to make" >&2
    echo "this pass: find out which side moved, then mirror the recorded digest." >&2
  fi
  if [ "$MISSING" -gt 0 ] || [ "$WRONG" -gt 0 ]; then exit 1; fi
  echo "Every entry resolves at the target prefix, and every recorded digest is the"
  echo "one the mirror holds. That is the success condition, not a repository count."
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

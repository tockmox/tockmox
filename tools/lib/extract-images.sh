# SPDX-License-Identifier: Apache-2.0
#
# ONE image extractor, sourced by tools/check-airgap.sh and tools/gen-images.sh.
#
# WHY THIS FILE EXISTS. Until 2026-09-16 the two tools carried the pipeline
# twice, and the copies had drifted:
#
#   check-airgap.sh   grep -oE '^[[:space:]]*image:[[:space:]]*.+'
#   gen-images.sh     grep -oE '^\s*image:\s*.+'
#
# **`\s` is a GNU extension.** BSD `grep -E`, which is the grep on macOS and
# therefore the grep on the workstation this repository is developed from, does
# not honour it. So the gate that CHECKS the mirror list and the generator that
# WRITES it were not reading the same manifests, and the difference was
# invisible on Linux CI. TM-0646's clause is "extracts identically in both",
# and two copies cannot be made identical by testing them ... only by being one
# copy.
#
# THE QUOTE RULE, which is the defect TM-0646 was raised for. `toYaml`
# single-quotes a templated image inside a list and `tpl` runs afterwards, so
# the quotes reach the rendered manifest:
#
#   image: 'airgap-check.invalid/library/busybox'
#
# Stripping only `"` left the leading apostrophe on the value. check-airgap.sh
# then reported a correct tree as leaking a registry (the `^$SENTINEL` test
# fails on `'airgap...`), and gen-images.sh wrote `'airgap...` into images.txt
# ... a mirror-list entry no registry can pull, in the one file an air-gapped
# site cannot correct from the network.

# extract_images
#   Reads rendered Kubernetes manifests on stdin, writes one image reference per
#   line on stdout, sorted and deduplicated.
#
#   POSIX bracket expressions only: no `\s`, no `\d`, nothing that needs GNU.
#
#   `|| true` ON THE GREP, deliberately. grep exits 1 when nothing matches, and
#   under the `set -euo pipefail` both callers use that aborts the script at the
#   assignment, with no message. Both callers ALREADY assert non-empty straight
#   afterwards, and check-airgap.sh's version of that assertion ... "no images
#   rendered at all, which cannot be right" ... is a far better thing for an
#   operator to read than a silent exit. Emptiness is the caller's question to
#   ask, not this function's to die on.
extract_images() {
  { grep -oE '^[[:space:]]*image:[[:space:]]*.+' || true; } \
    | awk '{print $2}' \
    | tr -d "\"'" \
    | sed '/^$/d' \
    | sort -u
}

# extract_images_selftest
#   Proves the extractor on the three quoting forms TM-0646 names, plus the
#   shapes that have actually bitten. Needs no helm and no cluster, so it runs
#   wherever CI runs ... which matters, because the defect it guards was found
#   by a gate going red on a correct tree, not by a test.
extract_images_selftest() {
  local fails=0 got want
  _ei_case() { # name expected-output input
    local name="$1" want="$2" input="$3" got
    got=$(printf '%s\n' "$input" | extract_images)
    if [ "$got" = "$want" ]; then
      echo "  ok   $name"
    else
      echo "  FAIL $name"
      echo "        want: $(printf '%s' "$want" | tr '\n' '|')"
      echo "        got:  $(printf '%s' "$got"  | tr '\n' '|')"
      fails=$((fails + 1))
    fi
  }

  # The three forms TM-0646's DoD names, each yielding the SAME reference.
  _ei_case "bare"           "reg.example/busybox:1.37" \
                            "        image: reg.example/busybox:1.37"
  _ei_case "double-quoted"  "reg.example/busybox:1.37" \
                            '        image: "reg.example/busybox:1.37"'
  _ei_case "single-quoted"  "reg.example/busybox:1.37" \
                            "        image: 'reg.example/busybox:1.37'"

  # THE TM-0646 CASE ITSELF: a templated image inside a values list, which
  # toYaml single-quotes. The sentinel must survive at the START of the value,
  # because check-airgap.sh tests `^$SENTINEL`.
  got=$(printf "%s\n" "      - name: wait-for-ca
        image: 'airgap-check.invalid/library/busybox:1.37'" | extract_images)
  if [ "${got#airgap-check.invalid}" != "$got" ]; then
    echo "  ok   templated list image starts with the sentinel, not a quote"
  else
    echo "  FAIL templated list image: got '$got'"; fails=$((fails + 1))
  fi

  # A digest-pinned reference must survive intact ... check-airgap.sh strips the
  # digest itself, downstream of here.
  _ei_case "digest pin" "reg.example/x@sha256:abc123" \
                        "  image: reg.example/x@sha256:abc123"

  # Sorted and deduplicated, across mixed quoting. This is the case that catches
  # a "simplification" to `uniq` without `sort`.
  _ei_case "dedup across quoting forms" "$(printf 'a/one:1\nb/two:2')" \
           "  image: b/two:2
  image: 'a/one:1'
  image: \"b/two:2\""

  # Must NOT match: a key that merely ends in `image`, or an image reference in
  # a comment or an annotation value. `^[[:space:]]*image:` is anchored for this
  # reason and the anchor is easy to lose.
  _ei_case "imagePullPolicy is not an image" "" \
           "        imagePullPolicy: IfNotPresent"
  _ei_case "a nested key ending in Image is not an image" "" \
           "        sidecarImage: reg.example/nope:1"

  if [ "$fails" -eq 0 ]; then echo "extract_images: all checks passed"; return 0; fi
  echo "extract_images: $fails failure(s)" >&2; return 1
}

# Runnable directly: `bash tools/lib/extract-images.sh --selftest`. Sourcing it
# defines the functions and runs nothing, which is what the two tools want.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --selftest) extract_images_selftest; exit $? ;;
    *) echo "usage: bash tools/lib/extract-images.sh --selftest" >&2; exit 2 ;;
  esac
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ConfigMap, what garage.blockSize does (TM-0782).
#
#   ./tools/check-garage-block-size.sh
#
#   unset        the garage.toml carries NO block_size line, so Garage keeps its
#                own default and the render is what it was before the key existed
#   "10MiB"      exactly one `block_size = "10MiB"` line, ABOVE the first [table]
#                header (a top-level key that lands after a table belongs to that
#                table in TOML, and Garage would ignore or reject it), and the
#                pod template's config checksum changes so the pod rolls
#   malformed    the schema refuses it, naming garage/blockSize, instead of
#                letting Garage crash-loop on its own parse error
#
# Reads the artifact, never an exit code: `helm template` exits 1 on any failure,
# and a case that failed for the wrong reason must not read as "refused".
#
# NOT PROVEN: that Garage v2.4.1 accepts the string forms the schema allows (the
# upstream reference shows "1M" and "10MiB"; a bare byte-count string is
# inferred), or what a running store does with a changed value.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null 2>&1 || { echo "check-garage-block-size: helm not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-garage-block-size: python3 PyYAML missing" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/garage-bs.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n       %s\n' "$1" "$2"; fail=1; }
echo "helm: $(helm version --short 2>/dev/null)"

render() { # out-file, extra helm args...
  local o="$1"; shift
  helm template t charts/tockmox-platform -f ci/values.yaml -f ci/values-all-on.yaml "$@" > "$o" 2>"$o.err"
}
# print the garage.toml of the tockmox-garage-config ConfigMap
toml_of() {
  python3 - "$1" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "tockmox-garage-config":
        print(d["data"]["garage.toml"]); sys.exit(0)
print("NOCONFIGMAP"); sys.exit(3)
PY
}
# print the StatefulSet pod-template checksum/config annotation
sum_of() {
  python3 - "$1" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "StatefulSet" and d["metadata"]["name"] == "tockmox-garage":
        print(d["spec"]["template"]["metadata"]["annotations"]["checksum/config"]); sys.exit(0)
print("NOSTS"); sys.exit(3)
PY
}

render "$tmp/unset.yaml"
render "$tmp/set.yaml" --set-string garage.blockSize=10MiB
toml_of "$tmp/unset.yaml" > "$tmp/unset.toml"; rc1=$?
toml_of "$tmp/set.yaml"   > "$tmp/set.toml";   rc2=$?
if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
  bad "the garage ConfigMap renders in both cases" "unset rc=$rc1, set rc=$rc2; $(head -2 "$tmp/unset.yaml.err" "$tmp/set.yaml.err" 2>/dev/null | cut -c1-200)"
else
  n="$(grep -c '^[[:space:]]*block_size' "$tmp/unset.toml")"
  [ "$n" = 0 ] && ok "unset: garage.toml carries no block_size line" \
    || bad "unset: garage.toml must carry no block_size line" "found $n"

  n="$(grep -c '^block_size = "10MiB"$' "$tmp/set.toml")"
  [ "$n" = 1 ] && ok 'set to 10MiB: exactly one block_size = "10MiB" line' \
    || bad 'set to 10MiB: expected exactly one block_size = "10MiB" line' "found $n"

  bs="$(grep -n '^block_size' "$tmp/set.toml" | head -1 | cut -d: -f1)"
  tbl="$(grep -n '^\[' "$tmp/set.toml" | head -1 | cut -d: -f1)"
  if [ -n "$bs" ] && [ -n "$tbl" ] && [ "$bs" -lt "$tbl" ]; then
    ok "set: block_size (line $bs) is above the first [table] header (line $tbl), so it is a top-level key"
  else
    bad "set: block_size must sit above the first [table] header" "block_size line=${bs:-none}, first table line=${tbl:-none}"
  fi

  # Everything else in the file must be byte-identical to the unset render once
  # the block_size stanza is removed: the key changes one thing.
  python3 - "$tmp/unset.toml" "$tmp/set.toml" <<'PY' && ok "set: the rest of garage.toml is unchanged" || bad "set: garage.toml differs beyond the block_size stanza" "see diff"
import sys, re
a = open(sys.argv[1]).read()
b = open(sys.argv[2]).read()
b2 = re.sub(r'\n# garage\.blockSize \(TM-0782\)[^\n]*\n#[^\n]*\nblock_size = "[^"]*"\n', '', b)
sys.exit(0 if a == b2 else 1)
PY

  s1="$(sum_of "$tmp/unset.yaml")"; s2="$(sum_of "$tmp/set.yaml")"
  if [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" != "$s2" ] && [ "$s1" != NOSTS ] && [ "$s2" != NOSTS ]; then
    ok "set: the pod template's checksum/config changes, so the pod rolls onto the new file"
  else
    bad "set: checksum/config must change" "unset=$s1 set=$s2"
  fi
fi

for v in abc "10 MiB" "-1" "10MiBs"; do
  helm template t charts/tockmox-platform -f ci/values.yaml --set-string "garage.blockSize=$v" > "$tmp/bad.yaml" 2> "$tmp/bad.err"
  if grep -q "/garage/blockSize" "$tmp/bad.err"; then ok "schema refuses garage.blockSize='$v', naming the key"
  else bad "schema must refuse garage.blockSize='$v'" "$(head -3 "$tmp/bad.err" | cut -c1-200)"; fi
done
for v in 10MiB 10M 1048576 1GiB; do
  helm template t charts/tockmox-platform -f ci/values.yaml --set-string "garage.blockSize=$v" > "$tmp/good.yaml" 2> "$tmp/good.err"
  if grep -q "/garage/blockSize" "$tmp/good.err"; then bad "schema must accept garage.blockSize='$v'" "$(head -3 "$tmp/good.err" | cut -c1-200)"
  else ok "schema accepts garage.blockSize='$v'"; fi
done

[ "$fail" -eq 0 ] && echo "PASS: garage.blockSize renders as documented" || echo "FAIL: see above"
exit "$fail"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACTS, what Loki's replica count is allowed to be
# (TM-0778).
#
#   ./tools/check-loki-ha.sh              the three cases below
#   ./tools/check-loki-ha.sh --selftest   prove each assertion can go red
#   LOKI_HA_VALUES=FILE ./tools/check-loki-ha.sh   assert on another values file
#
#   shipped default       one Loki replica, chunks and index on the filesystem
#   filesystem, 2 pods    refused by the Loki chart, naming the object store
#                         (read from the error text, not from an exit code:
#                         `helm template` exits 1 for every failure, and a case
#                         that broke for the wrong reason must not read as
#                         "refused")
#   ci/values-loki-ha.yaml  three replicas, replication_factor 3, and the
#                         object store (s3) named by the schema, the chunk and
#                         index storage AND the compactor, in the rendered config
#
# NOT PROVEN: that three replicas ingest and query through a node going away.
# That needs a lab run; this gate proves the documented values are a shape the
# chart will render, and that the shape the docs warn against is still refused.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# Probed before --selftest too: without helm or PyYAML every run below exits 2,
# and the selftest would read that as the unmutated file going red.
command -v helm >/dev/null 2>&1 || { echo "check-loki-ha: helm not on PATH" >&2; exit 2; }
# Probe the way the checks below run (-I, isolated); see check-kured-gate.sh.
python3 -I -c 'import yaml' 2>/dev/null || { echo "check-loki-ha: python3 -I (isolated) has no PyYAML" >&2; exit 2; }
if [ "${1:-}" = "--selftest" ]; then
  # Each mutation of the HA values must turn the check red; the unmutated file
  # must be green. A check that cannot go red is not a check.
  st="$(mktemp -d "${TMPDIR:-/tmp}/loki-ha-st.XXXXXX")"; trap 'rm -rf "$st"' EXIT
  rc=0
  run() { LOKI_HA_VALUES="$1" bash tools/check-loki-ha.sh >"$st/out" 2>&1; }
  if run ci/values-loki-ha.yaml; then echo "  ok   unmutated values: green"
  else echo "  FAIL unmutated values should be green"; cat "$st/out"; rc=1; fi
  mutate() { # name, python expression over d
    python3 -I - "$1" "$2" "$st/m.yaml" <<'PY'
import sys, yaml
name, expr, out = sys.argv[1:4]
d = yaml.safe_load(open("ci/values-loki-ha.yaml"))
L = d["loki"]["loki"]
exec(expr)
yaml.safe_dump(d, open(out, "w"))
PY
  }
  expect_red() { # name, python statement
    mutate "$1" "$2"
    if run "$st/m.yaml"; then echo "  FAIL mutation '$1' stayed green"; rc=1; else echo "  ok   mutation '$1': red"; fi
  }
  expect_red "one replica"        'd["loki"]["singleBinary"]["replicas"] = 1'
  expect_red "schema on filesystem" 'L["schemaConfig"]["configs"][0]["object_store"] = "filesystem"'
  expect_red "compactor on filesystem" 'L["compactor"]["delete_request_store"] = "filesystem"'
  expect_red "replication factor 1" 'L["commonConfig"]["replication_factor"] = 1'
  expect_red "filesystem storage" 'L["storage"] = {"type": "filesystem", "bucketNames": L["storage"]["bucketNames"]}'
  exit "$rc"
fi


tmp="$(mktemp -d "${TMPDIR:-/tmp}/loki-ha.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
ha_values="ci/values-loki-ha.yaml"

render() { # out-file, values-file-or-empty, extra helm args...
  local o="$1" v="$2"; shift 2
  local f=(); [ -n "$v" ] && f=(-f "$v")
  helm template t charts/tockmox-observability -f ci/values.yaml -f ci/values-all-on.yaml "${f[@]}" "$@" > "$o" 2>"$o.err"
}

# prints: replicas, object_store values, replication_factor, delete_request_store (tab-separated)
facts() {
  python3 -I - "$1" <<'PY'
import sys, yaml
reps = None; cfg = None
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d: continue
    if d.get("kind") == "StatefulSet" and d["metadata"]["name"].endswith("-loki"):
        reps = d["spec"]["replicas"]
    if d.get("kind") in ("ConfigMap", "Secret") and "config.yaml" in (d.get("data") or {}) | (d.get("stringData") or {}):
        text = (d.get("data") or {}).get("config.yaml") or (d.get("stringData") or {}).get("config.yaml")
        if "schema_config" in text:
            cfg = yaml.safe_load(text.replace("${", "__ENV_").replace("}", "__"))
if reps is None or cfg is None:
    print("MISSING\tMISSING\tMISSING\tMISSING"); sys.exit(0)
stores = sorted({c["object_store"] for c in cfg["schema_config"]["configs"]})
print("\t".join(str(x) for x in (
    reps, ",".join(stores), (cfg.get("common") or {}).get("replication_factor"),
    (cfg.get("compactor") or {}).get("delete_request_store"))))
PY
}

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n       %s\n' "$1" "$2"; fail=1; }
echo "helm: $(helm version --short 2>/dev/null)"

# ---- the shipped default ----
render "$tmp/def.yaml" ""
IFS=$'\t' read -r reps stores rf drs < <(facts "$tmp/def.yaml")
if [ "$reps" = 1 ] && [ "$stores" = filesystem ] && [ "$drs" = filesystem ]; then
  ok "default: 1 replica on the filesystem (replicas=$reps stores=$stores)"
else
  bad "default: 1 replica on the filesystem" "replicas=$reps stores=$stores delete_request_store=$drs"
fi

# ---- the shape the docs warn against ----
render "$tmp/fs2.yaml" "" --set loki.singleBinary.replicas=2
if grep -q "object storage" "$tmp/fs2.yaml.err" && [ ! -s "$tmp/fs2.yaml" ]; then
  ok "filesystem with 2 replicas is refused, and the error names object storage"
else
  bad "filesystem with 2 replicas is refused" "stderr: $(head -c 200 "$tmp/fs2.yaml.err")"
fi

# ---- the documented HA shape ----
ha="${LOKI_HA_VALUES:-$ha_values}"
render "$tmp/ha.yaml" "$ha"
if [ -s "$tmp/ha.yaml" ]; then
  IFS=$'\t' read -r reps stores rf drs < <(facts "$tmp/ha.yaml")
else
  reps="render-failed"; stores="-"; rf="-"; drs="-"
fi
if [ "$reps" != "render-failed" ] && [ "$reps" -gt 1 ] 2>/dev/null && [ "$stores" = s3 ] && [ "$drs" = s3 ] && [ "$rf" = "$reps" ]; then
  ok "HA values: $reps replicas, replication_factor $rf, schema and compactor on s3"
else
  bad "HA values render a multi-replica Loki on an object store" "replicas=$reps stores=$stores delete_request_store=$drs replication_factor=$rf $(head -c 160 "$tmp/ha.yaml.err" 2>/dev/null)"
fi

[ "$fail" -eq 0 ] || { echo "check-loki-ha: FAIL" >&2; exit 1; }
echo "check-loki-ha: ok"

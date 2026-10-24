#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert the storage policy ON THE RENDERED ARTIFACT.
#
#   ./tools/check-storage-policy.sh
#
# THE POLICY: replicate at exactly one layer. A workload that keeps its own
# copies, or whose data can be re-derived, gets `global.localStorageClass`.
# Everything else gets `global.storageClass`, NAMED ... not inherited.
#
# CHANGED 2026-09-04. This header used to end "...or no class at all and
# therefore the cluster default, which the platform layer makes Longhorn", and
# the check below deliberately accepted an unnamed claim because "both are
# correct and the second is the shipped design". Neither sentence is true now:
# the platform layer no longer marks a cluster default, because
# `is-default-class` is a cluster-wide singleton that belongs to whoever owns
# the cluster. An unnamed claim therefore inherits whatever was already there,
# which on k3s is node-local `local-path`. Unnamed is now a FAIL.
#
# WHY A GATE. Every claim in this repo was on `local-path` for weeks while
# Longhorn ran healthy and unused, because nothing named a class and nothing
# checked. That was invisible in the values, invisible in `helm lint`, and
# invisible on a green cluster. The classes are now named in five different
# places ... two of them literals, because the Loki and Grafana charts do not
# run `tpl` over the key ... so the way this regresses is one of them being
# edited without the others.
#
# The check is deliberately blunt: nothing that should be replicated may sit on
# the local class, everything that should be local must, and a claim that should
# be replicated must NAME its class rather than inherit one. The empty string is
# rejected separately from an absent key, because they mean opposite things and
# only one of them is a mistake here.
set -euo pipefail
cd "$(dirname "$0")/.."

VALUES=${VALUES:-ci/values.yaml}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for c in charts/tockmox-*; do
  [ "$c" = "charts/tockmox-common" ] && continue
  helm template t "$c" -f "$VALUES"
done > "$tmp/all.yaml"

LOCAL_CLASS=$(grep -E '^  localStorageClass:' charts/tockmox-observability/values.yaml \
  | head -1 | sed -E 's/.*: *"?([^"]*)"?.*/\1/')
export LOCAL_CLASS

python3 - "$tmp/all.yaml" <<'PY'
import sys, os, yaml

local_class = os.environ["LOCAL_CLASS"]

# Claims whose data the APPLICATION already protects, or that can be rebuilt.
# Matched on the claim or owner name; substring, because release prefixes vary.
MUST_BE_LOCAL = {
    "prometheus": "TSDB: high-churn, append-only, re-derivable, restored from backup rather than a replica",
    "loki":       "chunks: Loki's durability story is an object store, not a replicated block device",
}
# Everything else must NOT be on the local class. Named here only so the report
# is readable and a new claim shows up as unrecognised rather than silently ok.
# Claims whose class is DERIVED from how the workload is configured, so a fixed
# expectation here would be wrong half the time. Both are guarded in their
# templates instead: the class tracks whether anything else is keeping a copy.
DERIVED = {
    "cnpg":   "CNPG: replicated at one instance, local at three, because Postgres streams to its own replicas",
    "garage": "Garage: replicated at replication_factor 1, local at 3 or more, because Garage replicates across nodes itself",
}
MUST_BE_REPLICATED = {
    "open-webui":  "the console's own data: single copy, not re-derivable",
    "grafana":     "dashboards and sqlite state: single copy, not re-derivable",
    "ntfy":        "message store: single copy",
    "alertmanager":"silences and the notification log: small, single copy, and losing them re-fires everything already resolved",
    "postgresql":  "Authentik's database: one instance, so nothing else holds a copy",
}

claims = []   # (name, class, kind)
def add(name, spec, kind):
    claims.append((name, spec.get("storageClassName", spec.get("storageClass")), kind))

for chunk in open(sys.argv[1]).read().split("\n---\n"):
    try:
        d = yaml.safe_load(chunk)
    except Exception:
        continue
    if not isinstance(d, dict) or not d.get("kind"):
        continue
    k, n = d["kind"], (d.get("metadata") or {}).get("name", "?")
    if k == "PersistentVolumeClaim":
        add(n, d.get("spec", {}), k)
    for t in (d.get("spec", {}).get("volumeClaimTemplates") or []):
        add(f"{(t.get('metadata') or {}).get('name','?')} ({n})", t.get("spec", {}), k)
    if k in ("Prometheus", "Alertmanager"):
        add(n, ((d.get("spec", {}).get("storage") or {}).get("volumeClaimTemplate") or {}).get("spec", {}), k)
    if k == "Cluster" and "postgresql" in d.get("apiVersion", ""):
        inst = d["spec"].get("instances", 1)
        add(f"{n} (CNPG, instances={inst})", d["spec"].get("storage", {}), k)

rc = 0
seen = 0
for name, cls, kind in claims:
    seen += 1
    low = name.lower()
    # REPLICATED IS CHECKED FIRST, and that ordering is not arbitrary. The
    # Alertmanager claim is named `...-kube-prometheus-stack-alertmanager`, so
    # matching the local set first classifies Alertmanager as the Prometheus
    # TSDB and demands the wrong class. The narrower rule wins.
    derived = next((r for k, r in DERIVED.items() if k in low), None)
    known_repl = next((r for k, r in MUST_BE_REPLICATED.items() if k in low), None)
    want_local = None if (known_repl or derived) else next((r for k, r in MUST_BE_LOCAL.items() if k in low), None)
    if derived:
        print(f"ok   {name:46s} {str(cls) if cls else '<cluster default>':12s} derived")
    elif want_local:
        if cls != local_class:
            print(f"FAIL {name}: class {cls!r}, expected the local class {local_class!r}\n"
                  f"     {want_local}")
            rc = 1
        else:
            print(f"ok   {name:46s} {str(cls):12s} local")
    elif known_repl:
        if cls == local_class:
            print(f"FAIL {name}: on the local class {local_class!r}, which is node-local and "
                  f"single-copy.\n     {known_repl}")
            rc = 1
        elif cls is None:
            # TIGHTENED 2026-09-04. This branch used to print `ok` with
            # `<cluster default>`, because the platform layer marked Longhorn
            # the cluster default and inheriting it was the shipped design.
            # That default-claiming is gone: `is-default-class` is a
            # cluster-wide singleton belonging to the admin, so Tockmox now
            # names what it wants and leaves it alone. An unnamed claim no
            # longer lands on Longhorn ... it lands on whatever the cluster
            # already had, which on k3s is node-local `local-path`.
            print(f"FAIL {name}: names no StorageClass, so it inherits the cluster default.\n"
                  f"     {known_repl}\n"
                  f"     Tockmox no longer marks a cluster default, so this claim would land on "
                  f"whatever the cluster already had ... on k3s that is node-local `local-path`. "
                  f"Name the class, or thread `global.storageClass` into it.")
            rc = 1
        elif str(cls).strip() == "":
            print(f"FAIL {name}: storageClassName is the EMPTY STRING, which is not "
                  f"'use the cluster default'. Kubernetes reads \"\" as 'use no class': dynamic "
                  f"provisioning is off and the claim binds only to a pre-existing classless PV, "
                  f"so it stays Pending with nothing in its events saying why. Omit the key to "
                  f"take the default, or name a class.")
            rc = 1
        else:
            print(f"ok   {name:46s} {str(cls):12s} replicated")
    else:
        print(f"FAIL {name}: unrecognised claim, class {cls!r}. Every claim this repo renders "
              f"needs a row in tools/check-storage-policy.sh saying which side of the policy it "
              f"is on. A new volume with no decision behind it is how the last one went wrong.")
        rc = 1

if seen == 0:
    print("FAIL: no claims rendered at all, which means this gate is checking nothing")
    rc = 1
sys.exit(rc)
PY

# SECOND PASS: EVERY PROFILE, EVERY LAYER (TM-0146).
#
# The pass above renders ci/values.yaml, whose globals happen to match every
# literal class in the charts, so it cannot see a literal that fails to follow
# a global. profiles/minimal.yaml and household-sso.yaml shipped that way until
# 0.8.0: global.storageClass `local-path`, Longhorn off, Grafana still asking
# for `longhorn`. Nothing rendered the profiles across the layers, so nothing
# noticed.
#
# The assertion is the contract itself, not the policy table: under the values
# in effect, every claim names global.storageClass or global.localStorageClass
# (whichever side of the policy it is on is the first pass's business). A
# layer that refuses to render under a profile is a failure here too, which is
# how the observability preflight's guard for the same mismatch shows up.
prc=0
for prof in profiles/*.yaml; do
  out="$tmp/$(basename "$prof" .yaml).yaml"; : > "$out"; rendered=1
  for c in charts/tockmox-*; do
    [ "$c" = "charts/tockmox-common" ] && continue
    if ! helm template t "$c" -f "$VALUES" -f "$prof" >> "$out" 2> "$tmp/err"; then
      echo "FAIL $prof: $(basename "$c") does not render: $(grep -m1 -o 'execution error.*' "$tmp/err" | cut -c1-240)"
      prc=1; rendered=0
    fi
    printf '\n---\n' >> "$out"
  done
  python3 - "$out" "$VALUES" "$prof" "$rendered" <<'PY' || prc=1
import sys, yaml
out, base, prof, rendered = sys.argv[1:5]
def g(f):
    return ((yaml.safe_load(open(f)) or {}).get("global") or {})
glob = {**g(base), **g(prof)}
# The observability chart's own default stands in when neither file sets it.
names = {glob.get("storageClass"), glob.get("localStorageClass") or "local-path"} - {None, ""}
rc = 0; seen = 0
for chunk in open(out).read().split("\n---\n"):
    try:
        d = yaml.safe_load(chunk)
    except Exception:
        continue
    if not isinstance(d, dict) or not d.get("kind"):
        continue
    k, n, sp = d["kind"], (d.get("metadata") or {}).get("name", "?"), d.get("spec") or {}
    found = []
    if k == "PersistentVolumeClaim":
        found.append((n, sp.get("storageClassName")))
    for t in sp.get("volumeClaimTemplates") or []:
        found.append((f"{(t.get('metadata') or {}).get('name','?')} ({n})", (t.get("spec") or {}).get("storageClassName")))
    if k in ("Prometheus", "Alertmanager"):
        found.append((n, (((sp.get("storage") or {}).get("volumeClaimTemplate") or {}).get("spec") or {}).get("storageClassName")))
    if k == "Cluster" and "postgresql" in d.get("apiVersion", ""):
        found.append((f"{n} (CNPG)", (sp.get("storage") or {}).get("storageClass")))
    for name, cls in found:
        seen += 1
        if cls not in names:
            print(f"FAIL {prof}: {name} asks for class {cls!r}, which this profile's globals do not name {sorted(names)}")
            rc = 1
if rendered != "1":
    print(f"FAIL {prof}: {seen} claims checked from the layers that rendered; the refusal above is the failure")
elif rc == 0:
    print(f"ok   {prof}: {seen} claims, every one on {sorted(names)}")
else:
    print(f"FAIL {prof}: see above")
sys.exit(rc)
PY
done

# -------------------------------------------- more than one Grafana (TM-0786, TM-1005)
# Two Grafana replicas need one database they share and no ReadWriteOnce volume.
# The observability preflight refuses the two wrong shapes by name, and must
# ACCEPT a site that runs Grafana on a database it manages itself in grafana.ini
# (the reference homelab's shape, which 0.8.0's first cut of the guard refused).
G=charts/tockmox-observability
g2=(--set kube-prometheus-stack.grafana.replicas=2)
if out=$(helm template t "$G" -f ci/values.yaml "${g2[@]}" --set kube-prometheus-stack.grafana.persistence.enabled=false 2>&1); then
  echo "FAIL grafana: two replicas on SQLite rendered"; prc=1
elif printf '%s' "$out" | grep 'grafana.ini names no shared database' >/dev/null; then
  echo "ok   grafana: two replicas on SQLite refused by name"
else echo "FAIL grafana: two replicas on SQLite failed, but not with the expected message"; prc=1; fi
if helm template t "$G" -f ci/values.yaml "${g2[@]}" --set kube-prometheus-stack.grafana.persistence.enabled=false \
     --set 'kube-prometheus-stack.grafana.grafana\.ini.database.type=postgres' >/dev/null 2>&1; then
  echo "ok   grafana: two replicas on a site-managed postgres (grafana.ini) render"
else echo "FAIL grafana: two replicas on a site-managed postgres were refused"; prc=1; fi
if out=$(helm template t "$G" -f ci/values.yaml "${g2[@]}" --set kube-prometheus-stack.grafana.persistence.enabled=true \
     --set 'kube-prometheus-stack.grafana.grafana\.ini.database.type=postgres' 2>&1); then
  echo "FAIL grafana: two replicas with persistence on rendered"; prc=1
elif printf '%s' "$out" | grep 'with persistence still on' >/dev/null; then
  echo "ok   grafana: two replicas with persistence on refused by name"
else echo "FAIL grafana: two replicas with persistence on failed, but not with the expected message"; prc=1; fi
[ "$prc" = 0 ] || exit 1

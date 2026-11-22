#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert, ON THE RENDERED ARTIFACT, that Grafana makes no plugin call to
# grafana.com on an air-gapped site, and keeps its upstream behaviour elsewhere.
#
#   ./tools/check-grafana-airgap.sh
#
# WHY THIS IS A GATE. Grafana checks grafana.com for plugin updates every ten
# minutes ([analytics] check_for_plugin_updates, default true) and, from
# Grafana 12 on, installs a built-in list of app plugins from grafana.com at
# start ([plugins] preinstall_disabled, default false). On a site with no route
# out both are denied connections, at start and every ten minutes after, and
# nothing in `helm lint` shows it. The observability chart writes both keys
# into grafana.ini through the Grafana subchart's `tpl`, decided by the same
# signal the model gateway reads: `global.airGapped` true, or
# `global.imageRegistry` set (the fallback path, air-gapped by construction).
#
# WHAT IT PROVES: with neither set (and with global.airGapped false), Grafana
# gets its own defaults for both keys (check_for_plugin_updates = true,
# preinstall_disabled = false; a key grafana.ini leaves out reads as its
# default, so a connected site behaves as it did before the keys); with
# global.airGapped true, with global.imageRegistry set, and with both, it
# carries check_for_plugin_updates = false and preinstall_disabled = true. In
# every case the ConfigMap is the one the Grafana Deployment mounts, nothing
# the render gives the Grafana container as environment overrides either key
# (GF_<SECTION>_<KEY> wins over grafana.ini: its env list, and the rendered
# ConfigMaps and Secrets its envFrom names), and the update check, usage
# reporting and news feed stay off as they ship.
#
# WHAT IT DOES NOT PROVE: that these are Grafana's only calls to grafana.com
# on a cut site (the plugin signing key is fetched every ten days unless
# [plugins] public_key_retrieval_disabled is set), or that a running Grafana
# makes no call. That needs an air-gap run, and is not run here.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-grafana-airgap: helm not on PATH" >&2; echo "SKIPPED: helm is not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-grafana-airgap: python3 PyYAML missing" >&2; echo "SKIPPED: python3 has no PyYAML" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CHART=charts/tockmox-observability
BASE=ci/values.yaml
MIRROR=registry.example/mirror

# label | helm arguments | check_for_plugin_updates | preinstall_disabled
CASES=(
  "connected|-|true|false"
  "connected, global.airGapped false|--set global.airGapped=false|true|false"
  "air-gapped (global.airGapped)|--set global.airGapped=true|false|true"
  "air-gapped (global.imageRegistry)|--set global.imageRegistry=$MIRROR|false|true"
  "air-gapped (both)|--set global.airGapped=true --set global.imageRegistry=$MIRROR|false|true"
)
args=()
i=0
for c in "${CASES[@]}"; do
  IFS='|' read -r label hargs upd pre <<<"$c"
  # shellcheck disable=SC2086  # hargs is a fixed list of words written above
  if [ "$hargs" = "-" ]; then
    helm template t "$CHART" -f "$BASE" > "$tmp/$i.yaml"
  else
    helm template t "$CHART" -f "$BASE" $hargs > "$tmp/$i.yaml"
  fi
  args+=("$label" "$tmp/$i.yaml" "$upd" "$pre")
  i=$((i+1))
done

rc=0
python3 - "${args[@]}" <<'PY' || rc=1
import configparser, sys, yaml

# (section, key, Grafana's own default when grafana.ini leaves it out), from
# conf/defaults.ini of the Grafana the subchart pins
WANTED = [("analytics", "check_for_plugin_updates", "true"),
          ("plugins", "preinstall_disabled", "false")]
SHIPPED_OFF = [("analytics", "check_for_updates", "false"),
               ("analytics", "reporting_enabled", "false"),
               ("news", "news_feed_enabled", "false")]

def docs(path):
    for chunk in open(path).read().split("\n---\n"):
        try:
            d = yaml.safe_load(chunk)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("kind"):
            yield d

def grafana(ds):
    """The Grafana Deployment, its grafana container, and the grafana.ini it mounts."""
    cms = {d["metadata"]["name"]: d for d in ds if d["kind"] == "ConfigMap"}
    for d in ds:
        if d["kind"] != "Deployment":
            continue
        spec = d["spec"]["template"]["spec"]
        for c in spec.get("containers", []):
            if c.get("name") == "grafana" and "grafana/grafana" in c.get("image", ""):
                mounted = [v["configMap"]["name"] for v in spec.get("volumes") or [] if "configMap" in v]
                inis = [n for n in mounted if "grafana.ini" in ((cms.get(n) or {}).get("data") or {})]
                return d["metadata"]["name"], c, inis, cms
    return None, None, [], cms

bad = 0
def fail(msg):
    global bad
    print("FAIL " + msg); bad += 1
def ok(msg):
    print("  ok " + msg)

a = sys.argv[1:]
for label, path, upd, pre in zip(a[0::4], a[1::4], a[2::4], a[3::4]):
    ds = list(docs(path))
    name, c, inis, cms = grafana(ds)
    if name is None:
        fail("%s render: no Grafana Deployment (is Grafana on in ci/values.yaml?)" % label); continue
    if len(inis) != 1:
        fail("%s render: Deployment/%s mounts %d ConfigMaps carrying grafana.ini, want 1: %r" % (label, name, len(inis), inis)); continue
    ini = configparser.ConfigParser(interpolation=None)
    ini.read_string(cms[inis[0]]["data"]["grafana.ini"])
    # every env name the render hands the container: its env list, and the keys
    # of each rendered ConfigMap or Secret its envFrom names (with any prefix)
    envnames = {e["name"]: "env" for e in c.get("env") or []}
    secs = {d["metadata"]["name"]: d for d in ds if d["kind"] == "Secret"}
    for ef in c.get("envFrom") or []:
        for kind, pool in (("configMapRef", cms), ("secretRef", secs)):
            ref = ef.get(kind)
            if ref is None:
                continue
            src = pool.get(ref["name"]) or {}
            for k in list((src.get("data") or {})) + list((src.get("stringData") or {})):
                envnames[ef.get("prefix", "") + k] = "%s %s" % (kind, ref["name"])
    for (sec, key, default), want in zip(WANTED, (upd, pre)):
        got = ini.get(sec, key, fallback=None)
        eff = default if got is None else got
        if eff != want:
            fail("%s render: ConfigMap/%s [%s] %s = %r (Grafana reads %r), want %r" % (label, inis[0], sec, key, got, eff, want))
        else:
            ok("%s render: [%s] %s = %s%s" % (label, sec, key, eff, " (Grafana's default)" if got is None else ""))
        gf = "GF_%s_%s" % (sec.upper(), key.upper())
        if gf in envnames:
            fail("%s render: the Grafana container gets %s from its %s, which overrides grafana.ini" % (label, gf, envnames[gf]))
    for sec, key, want in SHIPPED_OFF:
        got = ini.get(sec, key, fallback=None)
        if got != want:
            fail("%s render: [%s] %s = %r, shipped %r" % (label, sec, key, got, want))

sys.exit(1 if bad else 0)
PY

if [ "$rc" -eq 0 ]; then echo "check-grafana-airgap: ok"; else echo "check-grafana-airgap: FAILED"; fi
exit "$rc"
